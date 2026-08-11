//
//  TrackData.swift
//  GPXPointViewer
//
//  轨迹数据模型（全 SoA 布局）+ 构建流水线 + 向量化拾取。
//
//  数据流：
//    GPXParser（多核解析）
//      → GeoCompute.mercator（vForce 投影）
//      → GeoCompute.speedsKmh（vDSP/vForce 测速）
//      → RTC 单精度坐标（双精度中心 + float 偏移，规避 GPU 抖动）
//      → Colormap.colorize（LUT 着色）
//    产出的 rtcX/rtcY/colors 三个数组直接映射为 Metal 顶点缓冲（统一内存零拷贝）。
//

import Foundation
import Accelerate
import simd
import SwiftUI

// MARK: - 视图设置

enum ColorMode: String, CaseIterable, Identifiable {
    case speed = "速度"
    case elevation = "海拔"
    case time = "时间"
    case single = "单色"
    var id: String { rawValue }

    var colormap: Colormap {
        switch self {
        case .speed:     return .greenRed      // 慢 = 绿 → 快 = 红
        case .elevation: return .yellowBlue    // 低 = 黄 → 高 = 蓝
        case .time:      return .greenRed      // 早（出发）= 绿 → 晚（终点）= 红
        case .single:    return .greenRed      // 单色模式不使用
        }
    }
}

enum BaseMapStyle: String, CaseIterable, Identifiable {
    case standard = "标准"
    case imagery = "卫星"
    case hybrid = "混合"
    // 地球视角不再是独立模式：持续缩小自动无缝进入自绘地球，放大自动回平面
    var id: String { rawValue }
}

/// 地球视角的呈现风格
enum GlobeStyle: String, CaseIterable, Identifiable {
    case realistic = "写实"     // 纹理球体 + 原始点云
    case pixel = "像素"         // 点阵大陆/海洋 + 数据柱（计数→高度）+ 流星
    var id: String { rawValue }
}

/// 应用外观（设置面板三向开关；映射 NSApp.appearance）
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "白天"
    case dark = "夜间"
    var id: String { rawValue }
}

struct ViewSettings: Equatable {
    var colorMode: ColorMode = .single   // 默认单色显示
    var mapStyle: BaseMapStyle = .standard
    var pointSize: Double = 3.5          // 半径（pt）
    var opacity: Double = 0.9            // 点透明度
    var mapOpacity: Double = 1.0         // 底图不透明度（1 = 原样，越小越暗）
    var singleColor: Color = Color(red: 0.90, green: 0.16, blue: 0.16)   // 默认红色
    var showHalo: Bool = false           // 点白描边（密集点云建议关，默认关）
    var showTrackLine: Bool = false      // 需求就是"只要点"——默认关
    var lineColor: Color = Color(red: 1.0, green: 0.42, blue: 0.21)   // 轨迹线颜色（橙）
    var lineWidth: Double = 2.0          // 箭杆宽（pt）
    var lineOpacity: Double = 0.75
    var showArrows: Bool = true          // 线段渲染为方向箭头（早 → 晚）
    var lodEnabled: Bool = true          // 视口自适应降采样（缩小时自动抽稀，放大自动全量）
    var showStats: Bool = true
    var globeStyle: GlobeStyle = .realistic   // 地球视角风格
    var showPixelLabels: Bool = false         // 像素地球：地名默认关，手动打开后保持
    // 闲置展示（星球演示）：两种视角各自的触发等待秒数 + 总开关
    var idleGlobeSeconds: Double = 3.0        // 地球视角闲置等待（秒）
    var idleMapSeconds: Double = 5.0          // 平面地图闲置等待（秒）
    var idleDisabled: Bool = false            // 禁用闲置展示模式
    var appearance: AppearanceMode = .system  // 应用外观（白天/夜间/跟随系统）
}

// MARK: - 性能统计

struct PerfStats {
    var pointCount = 0
    var parseMs = 0.0
    var throughputMBs = 0.0
    var chunks = 1
    var cores = ProcessInfo.processInfo.activeProcessorCount
    var projectMs = 0.0
    var speedMs = 0.0
    var assembleMs = 0.0
    var colorMs = 0.0
    // 渲染期动态更新
    var encodeMs = 0.0
    var waitMs = 0.0             // nextDrawable 等待（GPU 反压指标）
    var gpuMs = 0.0
    var fps = 0.0                // 交互期帧率（EMA）
    var hoverMicros = 0.0
    var drawnPoints = 0          // 本帧上屏点数（LOD 后）
    var lodStride = 1

    static let buildConfig: String = {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }()
}

/// 比例尺信息（自绘比例尺条）
struct ScaleBarInfo: Equatable {
    var widthPt: CGFloat
    var label: String
}

// MARK: - 点详情（悬停/选中）

struct PointInfo: Equatable {
    var index: Int
    var lat: Double
    var lon: Double
    var ele: Double?
    var speedKmh: Double?
    var timeText: String?
    var screenPoint: CGPoint    // 视图坐标（pt，左上原点）
}

// MARK: - 轨迹数据

final class TrackData: Identifiable {
    let id = UUID()
    let name: String
    let count: Int

    // 原始 SoA
    let lat: [Double]
    let lon: [Double]
    let ele: [Double]
    let time: [Double]
    let speedKmh: [Double]
    /// 每点所属文件下标（重叠模式按文件着色/高亮；空 = 单一来源）
    let fileID: [UInt16]

    // 投影 SoA（双精度世界坐标 + RTC 单精度偏移）
    let mercX: [Double]
    let mercY: [Double]
    let center: SIMD2<Double>
    let rtcX: [Float]
    let rtcY: [Float]

    // 球面单位向量 SoA（自绘地球用）：Y 轴朝北极，Z 轴朝 (0°N, 0°E)
    let unitX: [Float]
    let unitY: [Float]
    let unitZ: [Float]
    // 海拔抬升（球半径倍数，夸张 ×~50：万米巡航 ≈ 0.08R，飞行轨迹在球侧面拱起）
    let liftF: [Float]

    let hasEle: Bool
    let hasTime: Bool
    let bbox: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)
    let mercBounds: (minX: Double, maxX: Double, minY: Double, maxY: Double)
    let totalMercLength: Double   // 轨迹折线总长（墨卡托单位）
    let medianSegMerc: Double     // 中位段长——LOD 密度估计用（对轨迹间"瞬移"段免疫）
    let timeRange: (min: Double, max: Double)?   // 有效时间范围（导出/筛选用）
    let isMultiSegment: Bool      // 多段/多日轨迹（断点多时禁用轨迹线）
    let timedCount: Int           // 有效时间点数（载入时已按时间重排，占据 [0, timedCount)）
    var isTimeSorted: Bool { timedCount > 0 }    // 时间筛选可用（子区间二分的前提）

    // 着色（可变：切换模式时只重算颜色，不重建几何）
    private(set) var colors: [UInt8]
    private(set) var colorRange: (lo: Double, hi: Double) = (0, 1)
    private(set) var effectiveMode: ColorMode = .single
    private(set) var colorVersion: Int = 0

    // 拾取临时缓冲（主线程使用）
    private var scratchA: [Float]
    private var scratchB: [Float]

    /// 后台预建的 GPU 顶点缓冲（build 末尾生成，setData 领养后清空）
    var gpuBuffers: TrackGPUBuffers?

    // MARK: 构建流水线

    static func build(parsed: ParsedTrack, preferredMode: ColorMode,
                      singleColor: SIMD4<UInt8> = SIMD4(10, 122, 255, 235),
                      overlayFileColors: [SIMD4<UInt8>]? = nil) -> (TrackData, PerfStats) {
        // 多轨迹备份文件常见时间乱序/缺失：先按时间稳定重排（NaN 排尾）。
        // 排序后时间筛选可用二分子区间，测速/箭头也回归正确时序。
        var parsed = parsed
        let timedCount = sortByTimeIfNeeded(&parsed)

        var stats = PerfStats()
        stats.pointCount = parsed.count
        stats.parseMs = parsed.parseSeconds * 1000
        stats.chunks = parsed.chunkCount
        if parsed.parseSeconds > 0, parsed.byteCount > 0 {
            stats.throughputMBs = Double(parsed.byteCount) / 1_048_576.0 / parsed.parseSeconds
        }

        let tick = { DispatchTime.now().uptimeNanoseconds }
        let n = parsed.count
        let hasTime = timedCount > 0   // 与 time.contains { $0.isFinite } 等价（重排已统计）

        // 四并发阶段：A 投影链 / B 测速 / C 球面向量 / D 抬升+经纬极值。
        // 各阶段只写 scratch 中互不相交的字段；parsed 只读共享。
        let t0 = tick()
        let scratch = BuildScratch()
        let src = parsed
        DispatchQueue.concurrentPerform(iterations: 4) { stage in
            switch stage {
            case 0:  buildStageProjection(src, into: scratch)
            case 1:  buildStageSpeed(src, hasTime: hasTime, into: scratch)
            case 2:  buildStageUnitVectors(src, into: scratch)
            default: buildStageLiftBounds(src, into: scratch)
            }
        }
        stats.projectMs = scratch.projectMs
        stats.speedMs = scratch.speedMs
        stats.assembleMs = Double(tick() - t0) / 1e6   // 四阶段并发总墙钟

        // 有效时间范围（已重排：有效时间在 [0, timedCount) 且非递减）
        let timeRange: (Double, Double)? = timedCount > 0
            ? (parsed.time[0], parsed.time[timedCount - 1])
            : nil

        let track = TrackData(
            name: parsed.name.isEmpty ? "未命名轨迹" : parsed.name,
            count: n,
            lat: parsed.lat, lon: parsed.lon, ele: parsed.ele, time: parsed.time,
            fileID: parsed.fileID,
            speedKmh: scratch.speeds,
            mercX: scratch.mx, mercY: scratch.my,
            center: SIMD2(scratch.cx, scratch.cy),
            rtcX: scratch.rtcX, rtcY: scratch.rtcY,
            unitX: scratch.unitX, unitY: scratch.unitY, unitZ: scratch.unitZ,
            liftF: scratch.liftF,
            hasEle: scratch.hasEle, hasTime: hasTime,
            bbox: scratch.bbox,
            mercBounds: scratch.mercBounds,
            totalMercLength: scratch.totalLen,
            medianSegMerc: scratch.medianSeg,
            timeRange: timeRange,
            isMultiSegment: scratch.breaks > 20,
            timedCount: timedCount
        )

        let t1 = tick()
        if let fc = overlayFileColors, !track.fileID.isEmpty {
            track.recolorByFile(fc)          // 重叠模式：按文件着色
        } else {
            track.recolor(preferred: preferredMode, singleColor: singleColor)
        }
        stats.colorMs = Double(tick() - t1) / 1e6

        // 在本线程（解析后台）预建 GPU 顶点缓冲，主线程 setData 零拷贝领养
        // ——顺带覆盖删除重建与压测路径
        track.gpuBuffers = MetalPointRenderer.buildBuffers(track: track)

        return (track, stats)
    }

    // MARK: build 并发阶段

    /// 四并发阶段的结果承接。各阶段写互不相交的字段，数据竞争在构造上不可能发生；
    /// 编译器无法证明，@unchecked Sendable 显式承担证明责任。
    private final class BuildScratch: @unchecked Sendable {
        // A 投影链
        var mx: [Double] = []; var my: [Double] = []
        var cx = 0.0, cy = 0.0
        var rtcX: [Float] = []; var rtcY: [Float] = []
        var mercBounds = (minX: 0.0, maxX: 0.0, minY: 0.0, maxY: 0.0)
        var totalLen = 0.0
        var medianSeg = 0.0
        var breaks = 0
        var projectMs = 0.0
        // B 测速
        var speeds: [Double] = []
        var speedMs = 0.0
        // C 球面向量
        var unitX: [Float] = []; var unitY: [Float] = []; var unitZ: [Float] = []
        // D 抬升 + 经纬极值
        var liftF: [Float] = []
        var hasEle = false
        var bbox = (minLat: 0.0, maxLat: 0.0, minLon: 0.0, maxLon: 0.0)
    }

    /// 阶段 A：墨卡托投影 → 中心/RTC → 投影界 → 段长统计 + 断点检测
    private static func buildStageProjection(_ p: ParsedTrack, into s: BuildScratch) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let n = p.count
        let (mx, my) = GeoCompute.mercator(lat: p.lat, lon: p.lon)
        s.projectMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6   // 口径不变：仅投影
        var cx = 0.0, cy = 0.0
        vDSP_meanvD(mx, 1, &cx, vDSP_Length(n))
        vDSP_meanvD(my, 1, &cy, vDSP_Length(n))
        s.cx = cx; s.cy = cy
        s.rtcX = GeoCompute.rtcFloats(mx, center: cx)
        s.rtcY = GeoCompute.rtcFloats(my, center: cy)
        var bMinX = 0.0, bMaxX = 0.0, bMinY = 0.0, bMaxY = 0.0
        vDSP_minvD(mx, 1, &bMinX, vDSP_Length(n))
        vDSP_maxvD(mx, 1, &bMaxX, vDSP_Length(n))
        vDSP_minvD(my, 1, &bMinY, vDSP_Length(n))
        vDSP_maxvD(my, 1, &bMaxY, vDSP_Length(n))
        s.mercBounds = (bMinX, bMaxX, bMinY, bMaxY)

        // 轨迹段长统计（vDSP：相邻差分 → 逐元素 hypot）
        // 总长会被轨迹间"瞬移"段灌水，LOD 用【中位段长】——典型采样间距，离群免疫
        if n >= 2 {
            let m2 = n - 1
            var dx = GeoCompute.uninitialized(m2)
            var dy = GeoCompute.uninitialized(m2)
            mx.withUnsafeBufferPointer { b in
                GeoCompute.subtract(b.baseAddress! + 1, b.baseAddress!, &dx, m2)
            }
            my.withUnsafeBufferPointer { b in
                GeoCompute.subtract(b.baseAddress! + 1, b.baseAddress!, &dy, m2)
            }
            var seg = GeoCompute.uninitialized(m2)
            vDSP_vdistD(dx, 1, dy, 1, &seg, 1, vDSP_Length(m2))
            var totalLen = 0.0
            vDSP_sveD(seg, 1, &totalLen, vDSP_Length(m2))
            s.totalLen = totalLen
            s.medianSeg = GeoCompute.medianSampled(seg)
            s.breaks = countBreaks(seg: seg, time: p.time)
        }
        s.mx = mx; s.my = my
    }

    /// 多段检测：时间断档 > 30 分钟 或 跳距 > 10 km 视为轨迹断点。
    /// 分块并行；只有 breaks > 20 有意义，各块数到 21 即提前停
    private static func countBreaks(seg: [Double], time: [Double]) -> Int {
        let m = seg.count
        guard m > 0 else { return 0 }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let chunks = max(1, min(cores, m / 262_144 + 1))
        var partial = [Int](repeating: 0, count: chunks)
        seg.withUnsafeBufferPointer { sp in
            time.withUnsafeBufferPointer { tp in
                let s = sp.baseAddress!, t = tp.baseAddress!
                partial.withUnsafeMutableBufferPointer { pb in
                    let pc = pb
                    DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                        var c = 0
                        for i in (m * ci / chunks)..<(m * (ci + 1) / chunks) {
                            let dt = t[i + 1] - t[i]
                            if (dt.isFinite && dt > 1800) || s[i] * 40_075_000.0 > 10_000 {
                                c += 1
                                if c > 20 { break }
                            }
                        }
                        pc[ci] = c
                    }
                }
            }
        }
        return partial.reduce(0, +)
    }

    /// 阶段 B：相邻点测速
    private static func buildStageSpeed(_ p: ParsedTrack, hasTime: Bool, into s: BuildScratch) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        s.speeds = hasTime
            ? GeoCompute.speedsKmh(lat: p.lat, lon: p.lon, time: p.time)
            : [Double](repeating: 0, count: p.count)
        s.speedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    /// 阶段 C：球面单位向量（自绘地球用）：vForce 批量 sincos + vDSP 逐元素乘，
    /// 双精度算完压成 float SoA，直接映射为 Metal 顶点缓冲。
    /// 保持载入时急切计算——闲置展示会自动进入地球视角
    private static func buildStageUnitVectors(_ p: ParsedTrack, into s: BuildScratch) {
        let n = p.count
        let deg2rad = Double.pi / 180
        var latR = GeoCompute.uninitialized(n)
        var lonR = GeoCompute.uninitialized(n)
        GeoCompute.scaleAdd(p.lat, scale: deg2rad, add: 0, &latR, n)
        GeoCompute.scaleAdd(p.lon, scale: deg2rad, add: 0, &lonR, n)
        var sinLat = GeoCompute.uninitialized(n)
        var cosLat = GeoCompute.uninitialized(n)
        var sinLon = GeoCompute.uninitialized(n)
        var cosLon = GeoCompute.uninitialized(n)
        var vvN = Int32(n)
        vvsincos(&sinLat, &cosLat, latR, &vvN)
        vvsincos(&sinLon, &cosLon, lonR, &vvN)
        var uxD = GeoCompute.uninitialized(n)
        var uzD = GeoCompute.uninitialized(n)
        vDSP_vmulD(cosLat, 1, sinLon, 1, &uxD, 1, vDSP_Length(n))
        vDSP_vmulD(cosLat, 1, cosLon, 1, &uzD, 1, vDSP_Length(n))
        s.unitX = GeoCompute.rtcFloats(uxD, center: 0)
        s.unitY = GeoCompute.rtcFloats(sinLat, center: 0)
        s.unitZ = GeoCompute.rtcFloats(uzD, center: 0)
    }

    /// 阶段 D：海拔 → 球面抬升（夸张系数 8e-6/米：10 km 巡航 ≈ 0.08 球半径），
    /// 分块并行直写 + hasEle 顺带归约（省一次独立全扫）；经纬极值
    private static func buildStageLiftBounds(_ p: ParsedTrack, into s: BuildScratch) {
        let n = p.count
        guard n > 0 else { return }
        var liftF = GeoCompute.uninitializedF(n)
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let chunks = max(1, min(cores, n / 262_144 + 1))
        var flags = [Bool](repeating: false, count: chunks)
        p.ele.withUnsafeBufferPointer { ep in
            liftF.withUnsafeMutableBufferPointer { lb in
                flags.withUnsafeMutableBufferPointer { fb in
                    let e = ep.baseAddress!, l = lb.baseAddress!, f = fb
                    DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                        var any = false
                        for i in (n * ci / chunks)..<(n * (ci + 1) / chunks) {
                            let v = e[i]
                            if v.isFinite {
                                any = true
                                l[i] = v > 0 ? Float(min(v, 20_000) * 8e-6) : 0
                            } else {
                                l[i] = 0
                            }
                        }
                        f[ci] = any
                    }
                }
            }
        }
        s.liftF = liftF
        s.hasEle = flags.contains(true)
        var minLat = 0.0, maxLat = 0.0, minLon = 0.0, maxLon = 0.0
        vDSP_minvD(p.lat, 1, &minLat, vDSP_Length(n))
        vDSP_maxvD(p.lat, 1, &maxLat, vDSP_Length(n))
        vDSP_minvD(p.lon, 1, &minLon, vDSP_Length(n))
        vDSP_maxvD(p.lon, 1, &maxLon, vDSP_Length(n))
        s.bbox = (minLat, maxLat, minLon, maxLon)
    }

    private init(name: String, count: Int,
                 lat: [Double], lon: [Double], ele: [Double], time: [Double],
                 fileID: [UInt16],
                 speedKmh: [Double], mercX: [Double], mercY: [Double],
                 center: SIMD2<Double>, rtcX: [Float], rtcY: [Float],
                 unitX: [Float], unitY: [Float], unitZ: [Float], liftF: [Float],
                 hasEle: Bool, hasTime: Bool,
                 bbox: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double),
                 mercBounds: (minX: Double, maxX: Double, minY: Double, maxY: Double),
                 totalMercLength: Double,
                 medianSegMerc: Double,
                 timeRange: (min: Double, max: Double)?,
                 isMultiSegment: Bool,
                 timedCount: Int) {
        self.name = name
        self.count = count
        self.lat = lat; self.lon = lon; self.ele = ele; self.time = time
        self.fileID = fileID
        self.speedKmh = speedKmh
        self.mercX = mercX; self.mercY = mercY
        self.center = center
        self.rtcX = rtcX; self.rtcY = rtcY
        self.unitX = unitX; self.unitY = unitY; self.unitZ = unitZ
        self.liftF = liftF
        self.hasEle = hasEle; self.hasTime = hasTime
        self.bbox = bbox
        self.mercBounds = mercBounds
        self.totalMercLength = totalMercLength
        self.medianSegMerc = medianSegMerc
        self.timeRange = timeRange
        self.isMultiSegment = isMultiSegment
        self.timedCount = timedCount
        self.colors = [UInt8](repeating: 255, count: count * 4)
        self.scratchA = [Float](repeating: 0, count: count)
        self.scratchB = [Float](repeating: 0, count: count)
    }

    // MARK: 着色

    /// 首选模式在数据不支持时自动降级：速度/时间 → 海拔 → 单色
    func resolveMode(_ preferred: ColorMode) -> ColorMode {
        switch preferred {
        case .speed, .time:
            if hasTime { return preferred }
            return hasEle ? .elevation : .single
        case .elevation:
            return hasEle ? .elevation : .single
        case .single:
            return .single
        }
    }

    func values(for mode: ColorMode) -> [Double]? {
        switch mode {
        case .speed:     return speedKmh
        case .elevation: return ele
        case .time:      return time
        case .single:    return nil
        }
    }

    /// 重算颜色（切换模式/换单色时调用），返回耗时 ms
    @discardableResult
    func recolor(preferred: ColorMode, singleColor: SIMD4<UInt8> = SIMD4(10, 122, 255, 235)) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let mode = resolveMode(preferred)
        effectiveMode = mode

        if let vals = values(for: mode) {
            let range = GeoCompute.robustRange(vals)
            colorRange = range
            let t = GeoCompute.normalized01(vals, lo: range.lo, hi: range.hi)
            colors = Colormap.colorize(t, map: mode.colormap, alpha: 235)
        } else {
            // 单色：用户自选颜色。memset_pattern4 单调用即达内存带宽，
            // 免去逐点写循环和先零填充再覆盖的双趟开销
            var c = [UInt8](unsafeUninitializedCapacity: count * 4) { _, initialized in
                initialized = count * 4
            }
            var pattern: [UInt8] = [singleColor.x, singleColor.y, singleColor.z, singleColor.w]
            c.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress {
                    memset_pattern4(base, &pattern, raw.count)
                }
            }
            colors = c
            colorRange = (0, 1)
        }
        colorVersion += 1
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    /// 重叠模式：按点归属文件着色（fileID 查表，UInt32 图案分块并行直写）。
    /// 返回耗时 ms
    @discardableResult
    func recolorByFile(_ fileColors: [SIMD4<UInt8>]) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard !fileID.isEmpty, !fileColors.isEmpty, count > 0 else { return 0 }
        let n = count
        let patterns: [UInt32] = fileColors.map {
            UInt32($0.x) | (UInt32($0.y) << 8) | (UInt32($0.z) << 16) | (UInt32($0.w) << 24)
        }
        var c = [UInt8](unsafeUninitializedCapacity: n * 4) { _, m in m = n * 4 }
        c.withUnsafeMutableBytes { raw in
            let p32 = raw.baseAddress!.assumingMemoryBound(to: UInt32.self)
            fileID.withUnsafeBufferPointer { fb in
                patterns.withUnsafeBufferPointer { pb in
                    let f = fb.baseAddress!, pat = pb.baseAddress!, m = pb.count
                    let cores = ProcessInfo.processInfo.activeProcessorCount
                    let chunks = n > 200_000 ? max(1, min(cores, n / 100_000)) : 1
                    DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                        for i in (n * ci / chunks)..<(n * (ci + 1) / chunks) {
                            p32[i] = pat[min(Int(f[i]), m - 1)]
                        }
                    }
                }
            }
        }
        colors = c
        effectiveMode = .single    // 图例按单色语义隐藏
        colorRange = (0, 1)
        colorVersion += 1
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    // MARK: 时间筛选（二分求索引子区间，O(log n)）

    /// 第一个 time[i] >= t 的下标（在有效时间前缀 [0, timedCount) 内二分）
    func lowerBound(time t: Double) -> Int {
        var lo = 0, hi = timedCount
        while lo < hi {
            let mid = (lo + hi) / 2
            if time[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// [start, end) 时间窗对应的索引区间
    func indexRange(forTimeRange r: (Double, Double)) -> (start: Int, len: Int) {
        guard timedCount > 0 else { return (0, count) }
        let lo = lowerBound(time: r.0)
        let hi = lowerBound(time: r.1)
        return (lo, max(0, hi - lo))
    }

    // MARK: 载入时按时间重排（静态流水线步骤）

    /// 时间乱序或有效时间混在 NaN 之后时，按时间重排（NaN 排尾）。
    /// 返回有效时间点数。已有序则零开销直接返回。
    /// 多文件合并（sortedRuns 非空）时优先走多路归并快路：
    /// 每个文件通常各自有序，免去全量 O(n log n) 单线程排序 + 随机 gather。
    private static func sortByTimeIfNeeded(_ p: inout ParsedTrack) -> Int {
        let n = p.count
        guard n > 0 else { return 0 }
        let runs = p.sortedRuns.filter { !$0.isEmpty }
        if runs.count > 1, let timed = mergeSortedRuns(&p, runs: runs) {
            return timed
        }
        return sortByTimeGlobal(&p)
    }

    /// 全局回退路径（单文件 / 压测 / 删除重建 / run 内部乱序）：
    /// O(n) 检查，需要时 vDSP 索引排序（NaN → +Inf 作键，排到尾部）
    private static func sortByTimeGlobal(_ p: inout ParsedTrack) -> Int {
        let n = p.count
        var timed = 0
        var needSort = false
        var prevFinite = -Double.infinity
        var seenNaN = false
        for t in p.time {
            if t.isFinite {
                timed += 1
                if seenNaN { needSort = true }        // 有效时间出现在缺失值之后
                if t < prevFinite { needSort = true } // 乱序
                prevFinite = t
            } else {
                seenNaN = true
            }
        }
        guard timed > 0, needSort else { return timed }

        var keys = GeoCompute.uninitialized(n)
        for i in 0..<n { keys[i] = p.time[i].isFinite ? p.time[i] : .infinity }
        var perm = [vDSP_Length](repeating: 0, count: n)
        for i in 0..<n { perm[i] = vDSP_Length(i) }
        vDSP_vsortiD(keys, &perm, nil, vDSP_Length(n), 1)

        func gathered(_ a: [Double]) -> [Double] {
            var out = GeoCompute.uninitialized(n)
            a.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    let s = src.baseAddress!
                    let d = dst.baseAddress!
                    for i in 0..<n { d[i] = s[Int(perm[i])] }
                }
            }
            return out
        }
        p.lat = gathered(p.lat)
        p.lon = gathered(p.lon)
        p.ele = gathered(p.ele)
        p.time = gathered(p.time)
        gatherFileID(&p) { perm[$0] }
        return timed
    }

    /// fileID 与坐标数组同步搬运（重叠模式的按文件归属）
    private static func gatherFileID(_ p: inout ParsedTrack, _ src: (Int) -> vDSP_Length) {
        guard !p.fileID.isEmpty else { return }
        let n = p.count
        var out = [UInt16](unsafeUninitializedCapacity: n) { _, c in c = n }
        p.fileID.withUnsafeBufferPointer { sb in
            out.withUnsafeMutableBufferPointer { db in
                let s = sb.baseAddress!, d = db.baseAddress!
                for i in 0..<n { d[i] = s[Int(src(i))] }
            }
        }
        p.fileID = out
    }

    // MARK: 多文件 runs 快速重排

    private struct RunInfo {
        var range: Range<Int>
        var timed: Int          // 有限时间前缀长度
        var first: Double       // 首个有限时间（无则 .nan）
        var last: Double        // 末个有限时间（无则 .nan）
        var clean: Bool         // 有限前缀非降、其后只有 NaN
    }

    /// 逐 run 并行体检：干净 = 有限时间构成非降前缀、其后全 NaN
    /// （即现有全局判定按 run 应用）
    private static func analyzeRuns(_ time: [Double], runs: [Range<Int>]) -> [RunInfo] {
        var infos = [RunInfo](repeating: RunInfo(range: 0..<0, timed: 0,
                                                 first: .nan, last: .nan, clean: true),
                              count: runs.count)
        time.withUnsafeBufferPointer { tb in
            let t = tb.baseAddress!
            infos.withUnsafeMutableBufferPointer { ib in
                let inf = ib
                DispatchQueue.concurrentPerform(iterations: runs.count) { ri in
                    let r = runs[ri]
                    var timed = 0
                    var first = Double.nan
                    var prev = -Double.infinity
                    var seenNaN = false
                    var clean = true
                    for i in r {
                        let v = t[i]
                        if v.isFinite {
                            if seenNaN || v < prev { clean = false; break }
                            if timed == 0 { first = v }
                            prev = v
                            timed += 1
                        } else {
                            seenNaN = true
                        }
                    }
                    inf[ri] = RunInfo(range: r, timed: timed, first: first,
                                      last: timed > 0 ? prev : .nan, clean: clean)
                }
            }
        }
        return infos
    }

    /// runs 各自内部有序时的快速重排。返回有效时间点数；nil = 需回退全局排序。
    /// 三级快路：0) 当前顺序已全局有序 → 零移动；
    /// 1) 时间段互不重叠 → 纯块 memcpy（顺序带宽）；
    /// 2) 重叠 → k 路小顶堆归并生成置换后搬运。
    private static func mergeSortedRuns(_ p: inout ParsedTrack, runs: [Range<Int>]) -> Int? {
        let n = p.count
        let infos = analyzeRuns(p.time, runs: runs)
        guard infos.allSatisfy({ $0.clean }) else { return nil }
        let totalTimed = infos.reduce(0) { $0 + $1.timed }
        guard totalTimed > 0 else { return 0 }   // 全无时间：无需重排

        // 快路 0：按当前顺序已满足"有限前缀非降 + NaN 全在尾部"→ 零数据移动
        var okInPlace = true
        var nanZone = false
        var prevLast = -Double.infinity
        for info in infos {
            if info.timed > 0 {
                if nanZone || info.first < prevLast { okInPlace = false; break }
                prevLast = info.last
                if info.timed < info.range.count { nanZone = true }   // 本 run 有 NaN 尾巴
            } else {
                nanZone = true
            }
        }
        if okInPlace { return totalTimed }

        // 有限前缀按首时间升序（并列保持原顺序）；NaN 段之后按原顺序拼尾
        let timedOrder = infos.enumerated()
            .filter { $0.element.timed > 0 }
            .sorted { a, b in
                a.element.first != b.element.first
                    ? a.element.first < b.element.first
                    : a.offset < b.offset
            }

        var disjoint = true
        for k in 1..<timedOrder.count where timedOrder[k].element.first < timedOrder[k - 1].element.last {
            disjoint = false
            break
        }

        if disjoint {
            // 快路 1：块级搬运表（有限前缀按时间序，NaN 段按原顺序拼尾）
            var moves: [(src: Range<Int>, dst: Int)] = []
            moves.reserveCapacity(infos.count * 2)
            var pos = 0
            for (_, info) in timedOrder {
                let src = info.range.lowerBound..<(info.range.lowerBound + info.timed)
                moves.append((src, pos))
                pos += src.count
            }
            for info in infos where info.timed < info.range.count {
                let src = (info.range.lowerBound + info.timed)..<info.range.upperBound
                moves.append((src, pos))
                pos += src.count
            }
            assert(pos == n)
            applyBlockMoves(&p, moves: moves)
            return totalTimed
        }

        // 快路 2：k 路小顶堆归并有限前缀 → 置换表；NaN 段按原顺序拼尾
        struct Head { var t: Double; var i: Int; var end: Int }
        var perm = [Int]()
        perm.reserveCapacity(n)
        p.time.withUnsafeBufferPointer { tb in
            let t = tb.baseAddress!
            var heap = timedOrder.map { (_, info) in
                Head(t: info.first, i: info.range.lowerBound,
                     end: info.range.lowerBound + info.timed)
            }   // timedOrder 已按 first 升序 → 数组天然满足堆序
            func siftDown(_ s: Int) {
                var parent = s
                while true {
                    let l = parent * 2 + 1, r = l + 1
                    var m = parent
                    if l < heap.count, heap[l].t < heap[m].t { m = l }
                    if r < heap.count, heap[r].t < heap[m].t { m = r }
                    if m == parent { return }
                    heap.swapAt(parent, m)
                    parent = m
                }
            }
            while !heap.isEmpty {
                let h = heap[0]
                perm.append(h.i)
                let next = h.i + 1
                if next < h.end {
                    heap[0].i = next
                    heap[0].t = t[next]
                } else {
                    heap[0] = heap[heap.count - 1]
                    heap.removeLast()
                }
                siftDown(0)
            }
        }
        for info in infos where info.timed < info.range.count {
            perm.append(contentsOf: (info.range.lowerBound + info.timed)..<info.range.upperBound)
        }
        assert(perm.count == n)
        applyPermutation(&p, perm: perm)
        return totalTimed
    }

    /// 4 数组并行块拷贝（moves 的目标区间互不重叠且覆盖全长）
    private static func applyBlockMoves(_ p: inout ParsedTrack,
                                        moves: [(src: Range<Int>, dst: Int)]) {
        let n = p.count
        var outLat = GeoCompute.uninitialized(n)
        var outLon = GeoCompute.uninitialized(n)
        var outEle = GeoCompute.uninitialized(n)
        var outTime = GeoCompute.uninitialized(n)
        func blockCopy(_ src: [Double], _ dst: inout [Double]) {
            src.withUnsafeBufferPointer { sb in
                dst.withUnsafeMutableBufferPointer { db in
                    let s = sb.baseAddress!, d = db.baseAddress!
                    for mv in moves {
                        memcpy(d + mv.dst, s + mv.src.lowerBound,
                               mv.src.count * MemoryLayout<Double>.stride)
                    }
                }
            }
        }
        DispatchQueue.concurrentPerform(iterations: 4) { k in
            switch k {
            case 0: blockCopy(p.lat, &outLat)
            case 1: blockCopy(p.lon, &outLon)
            case 2: blockCopy(p.ele, &outEle)
            default: blockCopy(p.time, &outTime)
            }
        }
        p.lat = outLat; p.lon = outLon; p.ele = outEle; p.time = outTime
        if !p.fileID.isEmpty {
            var outID = [UInt16](unsafeUninitializedCapacity: n) { _, c in c = n }
            p.fileID.withUnsafeBufferPointer { sb in
                outID.withUnsafeMutableBufferPointer { db in
                    let s = sb.baseAddress!, d = db.baseAddress!
                    for mv in moves {
                        memcpy(d + mv.dst, s + mv.src.lowerBound,
                               mv.src.count * MemoryLayout<UInt16>.stride)
                    }
                }
            }
            p.fileID = outID
        }
    }

    /// 4 数组并行按置换搬运
    private static func applyPermutation(_ p: inout ParsedTrack, perm: [Int]) {
        let n = p.count
        var outLat = GeoCompute.uninitialized(n)
        var outLon = GeoCompute.uninitialized(n)
        var outEle = GeoCompute.uninitialized(n)
        var outTime = GeoCompute.uninitialized(n)
        func gatherCopy(_ src: [Double], _ dst: inout [Double]) {
            src.withUnsafeBufferPointer { sb in
                dst.withUnsafeMutableBufferPointer { db in
                    perm.withUnsafeBufferPointer { pb in
                        let s = sb.baseAddress!, d = db.baseAddress!, pm = pb.baseAddress!
                        for i in 0..<n { d[i] = s[pm[i]] }
                    }
                }
            }
        }
        DispatchQueue.concurrentPerform(iterations: 4) { k in
            switch k {
            case 0: gatherCopy(p.lat, &outLat)
            case 1: gatherCopy(p.lon, &outLon)
            case 2: gatherCopy(p.ele, &outEle)
            default: gatherCopy(p.time, &outTime)
            }
        }
        p.lat = outLat; p.lon = outLon; p.ele = outEle; p.time = outTime
        gatherFileID(&p) { vDSP_Length(perm[$0]) }
    }

    // MARK: 拾取（vDSP 向量化最近邻，全量 argmin）

    /// 查询世界墨卡托坐标 (qx,qy) 的最近点。返回 (下标, 墨卡托距离)。
    /// stride > 1 时按 LOD 采样间隔跳步扫描（vDSP 原生支持跨步）；
    /// range 限定时间筛选后的可见子区间——只在"实际上屏的点"里找。
    func nearestPoint(mercX qx: Double, mercY qy: Double, stride: Int = 1,
                      range: (start: Int, len: Int)? = nil) -> (index: Int, mercDist: Double)? {
        guard count > 0 else { return nil }
        let rStart = max(0, min(range?.start ?? 0, count - 1))
        let rLen = max(0, min(range?.len ?? count, count - rStart))
        guard rLen > 0 else { return nil }
        let s = max(1, stride)
        let m = (rLen + s - 1) / s
        let fx = Float(qx - center.x)
        let fy = Float(qy - center.y)
        let n = vDSP_Length(m)

        var minVal: Float = 0
        var minIdx: vDSP_Length = 0

        scratchA.withUnsafeMutableBufferPointer { sa in
            scratchB.withUnsafeMutableBufferPointer { sb in
                let pa = sa.baseAddress!
                let pb = sb.baseAddress!
                rtcX.withUnsafeBufferPointer { px in
                    var neg = -fx
                    vDSP_vsadd(px.baseAddress! + rStart, s, &neg, pa, 1, n)   // dx（区间+跳步）
                }
                vDSP_vsq(pa, 1, pa, 1, n)                            // dx²（指针原地，合法）
                rtcY.withUnsafeBufferPointer { py in
                    var neg = -fy
                    vDSP_vsadd(py.baseAddress! + rStart, s, &neg, pb, 1, n)   // dy
                }
                vDSP_vsq(pb, 1, pb, 1, n)                            // dy²
                vDSP_vadd(pa, 1, pb, 1, pa, 1, n)                    // dx²+dy²
                vDSP_minvi(pa, 1, &minVal, &minIdx, n)
            }
        }
        return (min(rStart + Int(minIdx) * s, count - 1), Double(minVal.squareRoot()))
    }

    /// 地球视角拾取：查询球面单位向量 q 的最近点（弦距² argmin，vDSP 跨步）。
    /// q 来自光线-球体求交（协调器算好），跳步/区间语义与 nearestPoint 一致。
    func nearestOnGlobe(query q: SIMD3<Double>, stride: Int = 1,
                        range: (start: Int, len: Int)? = nil) -> (index: Int, chord: Double)? {
        guard count > 0 else { return nil }
        let rStart = max(0, min(range?.start ?? 0, count - 1))
        let rLen = max(0, min(range?.len ?? count, count - rStart))
        guard rLen > 0 else { return nil }
        let s = max(1, stride)
        let m = (rLen + s - 1) / s
        let n = vDSP_Length(m)
        var minVal: Float = 0
        var minIdx: vDSP_Length = 0

        scratchA.withUnsafeMutableBufferPointer { sa in
            scratchB.withUnsafeMutableBufferPointer { sb in
                let pa = sa.baseAddress!
                let pb = sb.baseAddress!
                unitX.withUnsafeBufferPointer { px in
                    var neg = -Float(q.x)
                    vDSP_vsadd(px.baseAddress! + rStart, s, &neg, pa, 1, n)   // dx
                }
                vDSP_vsq(pa, 1, pa, 1, n)                                     // dx²
                unitY.withUnsafeBufferPointer { py in
                    var neg = -Float(q.y)
                    vDSP_vsadd(py.baseAddress! + rStart, s, &neg, pb, 1, n)   // dy
                }
                vDSP_vsq(pb, 1, pb, 1, n)
                vDSP_vadd(pa, 1, pb, 1, pa, 1, n)                             // dx²+dy²
                unitZ.withUnsafeBufferPointer { pz in
                    var neg = -Float(q.z)
                    vDSP_vsadd(pz.baseAddress! + rStart, s, &neg, pb, 1, n)   // dz
                }
                vDSP_vsq(pb, 1, pb, 1, n)
                vDSP_vadd(pa, 1, pb, 1, pa, 1, n)                             // + dz²
                vDSP_minvi(pa, 1, &minVal, &minIdx, n)
            }
        }
        return (min(rStart + Int(minIdx) * s, count - 1), Double(minVal.squareRoot()))
    }

    // MARK: 套索圈选（点在多边形内，多核并行）

    /// 返回落在多边形（墨卡托坐标，自动首尾闭合）内的全部点下标。
    /// 包围盒预筛 + 射线法（even-odd）精判；分块并行，各线程写独立槽位。
    /// range 限定扫描的索引子区间（时间筛选下只圈可见点）。
    func indices(inPolygon poly: [SIMD2<Double>],
                 range: (start: Int, len: Int)? = nil) -> [Int32] {
        guard poly.count >= 3, count > 0 else { return [] }
        let rStart = max(0, min(range?.start ?? 0, count - 1))
        let rLen = max(0, min(range?.len ?? count, count - rStart))
        guard rLen > 0 else { return [] }
        var bMinX = poly[0].x, bMaxX = poly[0].x
        var bMinY = poly[0].y, bMaxY = poly[0].y
        for p in poly {
            bMinX = min(bMinX, p.x); bMaxX = max(bMaxX, p.x)
            bMinY = min(bMinY, p.y); bMaxY = max(bMaxY, p.y)
        }

        let n = rLen
        let chunks = max(1, min(ProcessInfo.processInfo.activeProcessorCount, n / 65_536 + 1))
        var parts = [[Int32]](repeating: [], count: chunks)

        mercX.withUnsafeBufferPointer { pxb in
            mercY.withUnsafeBufferPointer { pyb in
                parts.withUnsafeMutableBufferPointer { pp in
                    let box = SendableBox((px: pxb.baseAddress!, py: pyb.baseAddress!, slots: pp))
                    DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                        let v = box.value
                        let a = rStart + ci * n / chunks
                        let b = rStart + (ci + 1) * n / chunks
                        var local = [Int32]()
                        for i in a..<b {
                            let x = v.px[i]
                            guard x >= bMinX, x <= bMaxX else { continue }
                            let y = v.py[i]
                            guard y >= bMinY, y <= bMaxY else { continue }
                            // 射线法 even-odd
                            var inside = false
                            var j = poly.count - 1
                            for k in 0..<poly.count {
                                let pk = poly[k]
                                let pj = poly[j]
                                if (pk.y > y) != (pj.y > y),
                                   x < (pj.x - pk.x) * (y - pk.y) / (pj.y - pk.y) + pk.x {
                                    inside.toggle()
                                }
                                j = k
                            }
                            if inside { local.append(Int32(i)) }
                        }
                        v.slots[ci] = local
                    }
                }
            }
        }
        return parts.flatMap { $0 }
    }

    /// 地球视角套索圈选：把每个点用协调器同款透视投影到屏幕（pt），
    /// 先做地平线剔除（背面/掠射点绝不误选），再包围盒预筛 + 射线法精判。
    /// 含海拔抬升（与渲染同款）——圈飞行轨迹时按画出来的弧线命中。
    /// 多核分块并行；190 万点毫秒级。
    func indicesOnGlobe(inPolygon poly: [SIMD2<Double>],
                        yaw: Double, pitch: Double, dist: Double,
                        tanHalfFov: Double, viewW: Double, viewH: Double,
                        baseLift: Double = 0.004,
                        range: (start: Int, len: Int)? = nil) -> [Int32] {
        guard poly.count >= 3, count > 0, viewW > 1, viewH > 1, dist > 1.01 else { return [] }
        let rStart = max(0, min(range?.start ?? 0, count - 1))
        let rLen = max(0, min(range?.len ?? count, count - rStart))
        guard rLen > 0 else { return [] }

        var bMinX = poly[0].x, bMaxX = poly[0].x
        var bMinY = poly[0].y, bMaxY = poly[0].y
        for p in poly {
            bMinX = min(bMinX, p.x); bMaxX = max(bMaxX, p.x)
            bMinY = min(bMinY, p.y); bMaxY = max(bMaxY, p.y)
        }

        // 旋转矩阵 R = Rx(pitch)·Ry(yaw)（行主序展开，与 Metal 端矩阵一致）
        let cp = cos(pitch), sp = sin(pitch)
        let cy = cos(yaw), sy = sin(yaw)
        // Ry 行：(cy, 0, sy) / (0,1,0) / (-sy, 0, cy)；再左乘 Rx
        let r00 = cy,        r01 = 0.0,  r02 = sy
        let r10 = sp * sy,   r11 = cp,   r12 = -sp * cy
        let r20 = -cp * sy,  r21 = sp,   r22 = cp * cy
        let horizon = 1.0 / dist              // 可见半球边界：z_rot > 1/dist
        let aspect = viewW / viewH
        let fx = 1.0 / (tanHalfFov * aspect)
        let fy = 1.0 / tanHalfFov

        let n = rLen
        let chunks = max(1, min(ProcessInfo.processInfo.activeProcessorCount, n / 65_536 + 1))
        var parts = [[Int32]](repeating: [], count: chunks)

        unitX.withUnsafeBufferPointer { pxb in
            unitY.withUnsafeBufferPointer { pyb in
                unitZ.withUnsafeBufferPointer { pzb in
                liftF.withUnsafeBufferPointer { plb in
                    parts.withUnsafeMutableBufferPointer { pp in
                        let box = SendableBox((ux: pxb.baseAddress!, uy: pyb.baseAddress!,
                                               uz: pzb.baseAddress!, lf: plb.baseAddress!,
                                               slots: pp))
                        DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                            let v = box.value
                            let a = rStart + ci * n / chunks
                            let b = rStart + (ci + 1) * n / chunks
                            var local = [Int32]()
                            for i in a..<b {
                                // 与渲染同款：单位向量 × (1 + 基础抬升 + 海拔抬升)
                                let s = 1.0 + baseLift + Double(v.lf[i])
                                let x = Double(v.ux[i]) * s
                                let y = Double(v.uy[i]) * s
                                let z = Double(v.uz[i]) * s
                                // 旋转到视线坐标（球心原点）
                                let rz = r20 * x + r21 * y + r22 * z
                                guard rz > horizon * 0.985 else { continue }   // 地平线外：背面剔除
                                let rx = r00 * x + r01 * y + r02 * z
                                let ry = r10 * x + r11 * y + r12 * z
                                let invVz = 1.0 / (dist - rz)             // -视空间 z
                                let sx = (rx * fx * invVz + 1.0) * 0.5 * viewW
                                guard sx >= bMinX, sx <= bMaxX else { continue }
                                let sy2 = (1.0 - ry * fy * invVz) * 0.5 * viewH
                                guard sy2 >= bMinY, sy2 <= bMaxY else { continue }
                                var inside = false
                                var j = poly.count - 1
                                for k in 0..<poly.count {
                                    let pk = poly[k]
                                    let pj = poly[j]
                                    if (pk.y > sy2) != (pj.y > sy2),
                                       sx < (pj.x - pk.x) * (sy2 - pk.y) / (pj.y - pk.y) + pk.x {
                                        inside.toggle()
                                    }
                                    j = k
                                }
                                if inside { local.append(Int32(i)) }
                            }
                            v.slots[ci] = local
                        }
                    }
                }
                }
            }
        }
        return parts.flatMap { $0 }
    }

    // MARK: 格式化

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = .current
        return f
    }()
    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = .current
        return f
    }()

    func info(at i: Int, screenPoint: CGPoint) -> PointInfo {
        PointInfo(
            index: i,
            lat: lat[i], lon: lon[i],
            ele: ele[i].isFinite ? ele[i] : nil,
            speedKmh: hasTime ? speedKmh[i] : nil,
            timeText: time[i].isFinite
                ? TrackData.timeFormatter.string(from: Date(timeIntervalSince1970: time[i]))
                : nil,
            screenPoint: screenPoint
        )
    }

    /// 色标两端标签
    func legendLabels() -> (lo: String, hi: String, unit: String)? {
        switch effectiveMode {
        case .single:
            return nil
        case .speed:
            return (String(format: "%.0f", colorRange.lo), String(format: "%.0f", colorRange.hi), "km/h")
        case .elevation:
            return (String(format: "%.0f", colorRange.lo), String(format: "%.0f", colorRange.hi), "m")
        case .time:
            let lo = Date(timeIntervalSince1970: colorRange.lo)
            let hi = Date(timeIntervalSince1970: colorRange.hi)
            return (TrackData.hmFormatter.string(from: lo), TrackData.hmFormatter.string(from: hi), "时刻")
        }
    }
}

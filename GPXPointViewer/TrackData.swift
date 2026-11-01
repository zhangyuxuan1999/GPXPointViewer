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

    /// 界面显示用（rawValue 只当标识，不直接显示）
    var title: LocalizedStringKey {
        switch self {
        case .speed: return "速度"
        case .elevation: return "海拔"
        case .time: return "时间"
        case .single: return "单色"
        }
    }

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
    // 外部瓦片来源（MapSources.swift）：OSM 画隧道虚线/分向车道，是补点用的那条路；Apple 底图不画隧道
    case osm = "OpenStreetMap"
    case topo = "OpenTopoMap"
    case esri = "Esri 影像"
    // 地球视角不再是独立模式：持续缩小自动无缝进入自绘地球，放大自动回平面
    var id: String { rawValue }   // rawValue 是 PointMapView 渲染缓存键的一部分，也是偏好/钩子的稳定标识，保持不变

    /// 界面显示用（rawValue 只当标识，不直接显示）
    var title: LocalizedStringKey {
        switch self {
        case .standard: return "标准"
        case .imagery: return "卫星"
        case .hybrid: return "混合"
        case .osm: return "OpenStreetMap"
        case .topo: return "OpenTopoMap"
        case .esri: return "Esri 影像"
        }
    }
}

/// 地球视角的呈现风格
enum GlobeStyle: String, CaseIterable, Identifiable {
    case realistic = "写实"     // 纹理球体 + 原始点云
    case pixel = "像素"         // 点阵大陆/海洋 + 数据柱（计数→高度）+ 流星
    var id: String { rawValue }

    /// 界面显示用（rawValue 只当标识，不直接显示）
    var title: LocalizedStringKey {
        switch self {
        case .realistic: return "写实"
        case .pixel: return "像素"
        }
    }
}

/// 应用外观（设置面板三向开关；映射 NSApp.appearance）
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "白天"
    case dark = "夜间"
    var id: String { rawValue }   // rawValue 持久化在 UserDefaults 里，保持不变

    /// 界面显示用（rawValue 只当标识，不直接显示）
    var title: LocalizedStringKey {
        switch self {
        case .system: return "跟随系统"
        case .light: return "白天"
        case .dark: return "夜间"
        }
    }
}

struct ViewSettings: Equatable {
    var colorMode: ColorMode = .single   // 默认单色显示
    var mapStyle: BaseMapStyle = .standard
    var pointSize: Double = 1.0          // 半径（pt）；默认 1.0
    var opacity: Double = 0.9            // 点透明度
    var mapOpacity: Double = 0.5         // 底图不透明度（1 = 原样，越小越暗）
    var singleColor: Color = Color(red: 0.90, green: 0.16, blue: 0.16)   // 默认红色
    // 找不同：两侧"独有点"的高亮色（对比面板与独立差异窗口共用）
    var diffColorLeft: Color = Color(red: 1.0, green: 0.35, blue: 0.10)   // 橙
    var diffColorRight: Color = Color(red: 0.10, green: 0.55, blue: 1.0)  // 蓝
    var showHalo: Bool = false           // 点白描边（密集点云建议关，默认关）
    var showTrackLine: Bool = false      // 需求就是"只要点"——默认关
    var lineColor: Color = Color(red: 1.0, green: 0.42, blue: 0.21)   // 轨迹线颜色（橙）
    var lineWidth: Double = 2.0          // 箭杆宽（pt）
    var lineOpacity: Double = 0.75
    var showArrows: Bool = true          // 线段渲染为方向箭头（早 → 晚）
    var arrowEvery: Int = 1              // 箭头密度：1 = 每段，2 = 隔一段，3 = 隔两段
    var lodEnabled: Bool = true          // 视口自适应降采样（缩小时自动抽稀，放大自动全量）
    var showStats: Bool = true
    var globeStyle: GlobeStyle = .realistic   // 地球视角风格
    var showPixelLabels: Bool = false         // 像素地球：地名默认关，手动打开后保持
    // 闲置展示（星球演示）：两种视角各自的触发等待秒数 + 总开关
    var idleGlobeSeconds: Double = 3.0        // 地球视角闲置等待（秒）
    var idleMapSeconds: Double = 5.0          // 平面地图闲置等待（秒）
    var idleDisabled: Bool = false            // 禁用闲置展示模式
    var appearance: AppearanceMode = .system  // 应用外观（白天/夜间/跟随系统）
    var heatMap: Bool = false                 // 平面地图热力图（GPU 密度双 pass）
    var fogMap: Bool = false                  // 迷雾模式（世界迷雾观感；与热力互斥）
    var fogRadiusMeters: Double = 40          // 迷雾清除半径（米，滑杆可调）
    var heat3D: Bool = false                  // 热力图的 3D 柱状模式（自绘透视场景）
    var heat3DBlock: Int = 2                  // 3D 热力块边长（迷雾格数 k，面积 k²=1/4/9/…/36）
    var heat3DSmooth: Bool = true             // 3D 热力：true = 与邻块平滑衔接，false = 棱角方柱
    var fogSmooth: Bool = true                // 迷雾存档平滑边缘（对齐手机 App 扩散观感）；
                                              // 关闭 = 精确显示 .fwdb 原始格
}

/// 《世界迷雾》口径的探索统计结果
struct FogStats {
    var cells: Int          // 解锁格子数（2²²×2²² 世界网格）
    var km2: Double         // 探索面积（km²，格宽 9.5546m×cosφ 逐格累计）
    var level: Int          // 等级 = ⌊√(面积km² × 250)⌋
    var percent: Double     // 占地球表面（5.10072 亿 km²）百分比
    var nextLevelKm2: Double // 距下一级还需的面积
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
    var spatialMs = 0.0          // 莫顿序空间索引构建
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

/// 高频小状态各自成对象（见 TrackStore 顶部说明）：观察者只有对应的小视图
@MainActor final class RenderStatsState: ObservableObject {
    @Published var stats = PerfStats()
}
@MainActor final class HoverState: ObservableObject {
    @Published var info: PointInfo?
}
@MainActor final class ScaleBarState: ObservableObject {
    @Published var info: ScaleBarInfo?
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

// MARK: - 空间索引（莫顿 Z 序）

/// 世界墨卡托 [0,1)² 切成 2²⁴×2²⁴ 格（赤道 ≈2.4m），每点一个 48 位莫顿键。
/// 点按键排序后，任一四叉树节点（level 级格）在序列里是一个连续区段——
/// 视口矩形 → 若干 level 级格 → 二分出 ≤ 百来个区段，渲染只提交这些区段，
/// 拾取只扫这些区段。另预算每一级的"格首点"表（同一级格里的第一个点），
/// 渲染按缩放选一级、每格只画一个点：同一条路被反复经过几十次只画一遍，
/// 路线连续性保留（格边 ≈ 0.6×目标点距）。构建在载入后台（并行取键 +
/// LSD 基数排序 + 一趟差分扫描）
enum SpatialIndex {
    static let bits = 24
    static let keyBits = 48
    static let levels = bits + 1          // 0…24

    /// 32 位以内坐标的位展开（每位之间插一个 0）：标准 5 步掩码法
    @inline(__always)
    static func spread(_ v: UInt64) -> UInt64 {
        var x = v & 0xFFFF_FFFF
        x = (x | (x << 16)) & 0x0000_FFFF_0000_FFFF
        x = (x | (x << 8))  & 0x00FF_00FF_00FF_00FF
        x = (x | (x << 4))  & 0x0F0F_0F0F_0F0F_0F0F
        x = (x | (x << 2))  & 0x3333_3333_3333_3333
        x = (x | (x << 1))  & 0x5555_5555_5555_5555
        return x
    }

    @inline(__always)
    static func morton(_ ix: UInt64, _ iy: UInt64) -> UInt64 {
        spread(ix) | (spread(iy) << 1)
    }

    /// 索引产物
    struct Built {
        var order: [UInt32] = []          // 位置 k → 原始下标
        var keys: [UInt64] = []           // 位置 k 的键（有序）
        var firsts: [UInt32] = []         // 各级格首点位置表（按级拼接）
        var firstOffsets: [Int] = []      // firsts 中各级的起点（levels+1 项）
    }

    static func build(mercX: [Double], mercY: [Double]) -> Built {
        let n = mercX.count
        guard n > 0 else { return Built() }
        let scale = Double(1 << bits)
        let maxC = Double((1 << bits) - 1)
        var keys = [UInt64](unsafeUninitializedCapacity: n) { _, m in m = n }
        var idx = [UInt32](unsafeUninitializedCapacity: n) { _, m in m = n }
        keys.withUnsafeMutableBufferPointer { kb in
        idx.withUnsafeMutableBufferPointer { ib in
        mercX.withUnsafeBufferPointer { px in
        mercY.withUnsafeBufferPointer { py in
            let k = kb.baseAddress!, o = ib.baseAddress!
            let x = px.baseAddress!, y = py.baseAddress!
            let cores = ProcessInfo.processInfo.activeProcessorCount
            let chunks = n > 200_000 ? max(1, min(cores, n / 100_000)) : 1
            DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                for i in (n * ci / chunks)..<(n * (ci + 1) / chunks) {
                    let fx = min(maxC, max(0, (x[i] - x[i].rounded(.down)) * scale))
                    let fy = min(maxC, max(0, y[i] * scale))
                    k[i] = morton(UInt64(fx), UInt64(fy))
                    o[i] = UInt32(i)
                }
            }
        }}}}
        radixSort(keys: &keys, vals: &idx)

        // 各级格首点：k 与前一位置的键的公共前导位数 d（48 位内）→
        // 顶部 2L 位不同 ⇔ 2L > d ⇔ L ≥ d/2 + 1；k=0 属于所有级
        var counts = [Int](repeating: 0, count: levels + 1)
        var lmin = [UInt8](unsafeUninitializedCapacity: n) { _, m in m = n }
        keys.withUnsafeBufferPointer { kb in
            lmin[0] = 0
            for k in 1..<n {
                let x = kb[k] ^ kb[k - 1]
                let d = x == 0 ? keyBits : (x.leadingZeroBitCount - (64 - keyBits))
                lmin[k] = UInt8(min(levels, d / 2 + 1))   // == levels ⇒ 不是任何级的首点
            }
        }
        for k in 0..<n where Int(lmin[k]) < levels {
            for L in Int(lmin[k])..<levels { counts[L] += 1 }
        }
        var offsets = [Int](repeating: 0, count: levels + 1)
        for L in 0..<levels { offsets[L + 1] = offsets[L] + counts[L] }
        var firsts = [UInt32](unsafeUninitializedCapacity: offsets[levels]) { _, m in m = offsets[levels] }
        var cursor = offsets
        for k in 0..<n where Int(lmin[k]) < levels {
            for L in Int(lmin[k])..<levels {
                firsts[cursor[L]] = UInt32(k)
                cursor[L] += 1
            }
        }
        return Built(order: idx, keys: keys, firsts: firsts, firstOffsets: offsets)
    }

    /// LSD 基数排序（48 位键，3 趟 16 位），键值对同步搬运
    static func radixSort(keys: inout [UInt64], vals: inout [UInt32]) {
        let n = keys.count
        guard n > 1 else { return }
        var k2 = [UInt64](unsafeUninitializedCapacity: n) { _, m in m = n }
        var v2 = [UInt32](unsafeUninitializedCapacity: n) { _, m in m = n }
        var hist = [Int](repeating: 0, count: 65536)
        for pass in 0..<3 {
            let shift = UInt64(pass * 16)
            for i in 0..<65536 { hist[i] = 0 }
            keys.withUnsafeBufferPointer { kb in
                for i in 0..<n { hist[Int((kb[i] >> shift) & 0xFFFF)] += 1 }
            }
            var sum = 0
            for i in 0..<65536 { let c = hist[i]; hist[i] = sum; sum += c }
            keys.withUnsafeBufferPointer { kb in
            vals.withUnsafeBufferPointer { vb in
            k2.withUnsafeMutableBufferPointer { k2b in
            v2.withUnsafeMutableBufferPointer { v2b in
                for i in 0..<n {
                    let d = Int((kb[i] >> shift) & 0xFFFF)
                    let dst = hist[d]
                    hist[d] = dst + 1
                    k2b[dst] = kb[i]
                    v2b[dst] = vb[i]
                }
            }}}}
            swap(&keys, &k2)
            swap(&vals, &v2)
        }
        // 3 趟后结果在 keys/vals（奇数趟交换时也一致：swap 使 keys 始终指向最新）
    }

    /// 有序键数组中第一个 ≥ k 的位置
    @inline(__always)
    static func lowerBound(_ keys: UnsafeBufferPointer<UInt64>, _ k: UInt64) -> Int {
        var lo = 0, hi = keys.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if keys[mid] < k { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    @inline(__always)
    static func lowerBound(_ a: UnsafeBufferPointer<UInt32>, _ v: UInt32) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if a[mid] < v { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// 视口 [x0,x1]×[y0,y1]（世界墨卡托；x 可越过 0/1 经度环绕）→ 有序序列
    /// 里的连续区段列表（相邻合并，按位置升序）
    static func ranges(keys: [UInt64], x0: Double, y0: Double, x1: Double, y1: Double,
                       maxCellsAcross: Int) -> [Range<Int>] {
        merge(cellRanges(keys: keys, x0: x0, y0: y0, x1: x1, y1: y1,
                         maxCellsAcross: maxCellsAcross).cells)
    }

    /// 相邻/重叠区段合并
    static func merge(_ sorted: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        merged.reserveCapacity(sorted.count)
        for r in sorted {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// 逐格区段（未合并，按位置升序）+ 所用级别：级别取"跨视口格数 ≤
    /// maxCellsAcross"的最细一级，每格 = 序列里一个连续区段
    static func cellRanges(keys: [UInt64], x0: Double, y0: Double, x1: Double, y1: Double,
                           maxCellsAcross: Int) -> (cells: [Range<Int>], level: Int) {
        guard !keys.isEmpty, x1 > x0, y1 > y0 else { return ([], bits) }
        let span = max(x1 - x0, y1 - y0)
        var level = bits
        while level > 0, span * Double(1 << level) > Double(maxCellsAcross) { level -= 1 }
        let cells = Double(1 << level)
        let shift = UInt64(2 * (bits - level))          // level 级格 = 键的高 2·level 位
        let cellMax = Int(cells) - 1
        let iy0 = max(0, min(cellMax, Int((max(0, y0) * cells).rounded(.down))))
        let iy1 = max(0, min(cellMax, Int((min(1, y1) * cells).rounded(.down))))
        var xSpans: [(Int, Int)] = []
        if x1 - x0 >= 1 {
            xSpans.append((0, cellMax))
        } else {
            let fx0 = x0 - x0.rounded(.down)
            let fx1 = fx0 + (x1 - x0)
            if fx1 <= 1 {
                xSpans.append((Int((fx0 * cells).rounded(.down)), min(cellMax, Int((fx1 * cells).rounded(.down)))))
            } else {
                xSpans.append((Int((fx0 * cells).rounded(.down)), cellMax))
                xSpans.append((0, min(cellMax, Int(((fx1 - 1) * cells).rounded(.down)))))
            }
        }
        var out: [Range<Int>] = []
        keys.withUnsafeBufferPointer { kb in
            for (ax, bx) in xSpans {
                for iy in iy0...iy1 {
                    for ix in max(0, ax)...max(ax, bx) {
                        let kLo = morton(UInt64(ix), UInt64(iy)) << shift
                        let kHi = kLo &+ (UInt64(1) << shift)
                        let lo = lowerBound(kb, kLo)
                        let hi = shift >= 48 ? kb.count : lowerBound(kb, kHi)
                        if hi > lo { out.append(lo..<hi) }
                    }
                }
            }
        }
        out.sort { $0.lowerBound < $1.lowerBound }
        return (out, level)
    }
}

// MARK: - 轨迹数据

/// Indices of the time-normalized path. This view shares the immutable order storage.
struct TrackPathIndices: RandomAccessCollection {
    typealias Index = Int
    typealias Element = Int
    fileprivate let order: [UInt32]
    fileprivate let range: Range<Int>
    var startIndex: Int { 0 }
    var endIndex: Int { range.count }
    subscript(position: Int) -> Int {
        precondition(position >= 0 && position < endIndex)
        let p = range.lowerBound + position
        return order.isEmpty ? p : Int(order[p])
    }
}

struct TrackSegmentRange {
    let id: UInt32
    let range: Range<Int>
}

/// GPU ABI: four UInt32 values, 16-byte size and stride.
struct PathDrawRun {
    var begin: UInt32
    var end: UInt32
    var firstInstance: UInt32
    var instanceCount: UInt32
}
enum PathDrawKind { case line, fog }
struct PathDrawPlan {
    let runs: [PathDrawRun]
    let instanceCount: Int
    let stride: Int
}

/// A stable scatter groups the global time indices by source segment in O(n + segments).
/// The normal single-segment track keeps identity order/rank implicit.
struct TrackTopology {
    let count: Int
    let order: [UInt32]
    let rank: [UInt32]
    let segments: [TrackSegmentRange]
    private let labels: [UInt32]
    private let segmentLookup: [UInt32: Int]
    private(set) var lineRuns: [Range<Int>]
    private(set) var fogRuns: [Range<Int>]
    var isIdentity: Bool { order.isEmpty }

    init(segmentID: [UInt32], count: Int) {
        precondition(segmentID.isEmpty || segmentID.count == count, "segmentID must be empty or count long")
        precondition(count <= Int(UInt32.max))
        self.count = count
        labels = segmentID
        var ids: [UInt32] = []
        var lookup: [UInt32: Int] = [:]
        var counts: [Int] = []
        if segmentID.isEmpty || segmentID.dropFirst().allSatisfy({ $0 == segmentID.first }) {
            if count > 0 {
                let id = segmentID.first ?? 0
                ids = [id]; lookup = [id: 0]; counts = [count]
            }
        } else {
            for id in segmentID {
                if let k = lookup[id] { counts[k] += 1 }
                else { lookup[id] = ids.count; ids.append(id); counts.append(1) }
            }
        }
        var ranges: [TrackSegmentRange] = []
        var offset = 0
        for k in ids.indices {
            ranges.append(TrackSegmentRange(id: ids[k], range: offset..<(offset + counts[k])))
            offset += counts[k]
        }
        segments = ranges
        segmentLookup = lookup
        if ids.count <= 1 { order = []; rank = [] }
        else {
            var o = [UInt32](repeating: 0, count: count)
            var r = o
            var cursors = ranges.map { $0.range.lowerBound }
            for i in 0..<count {
                let k = lookup[segmentID[i]]!
                let p = cursors[k]
                o[p] = UInt32(i); r[i] = UInt32(p); cursors[k] += 1
            }
            order = o; rank = r
        }
        lineRuns = ranges.map { $0.range }
        fogRuns = lineRuns
    }

    func withRuns(line: [Range<Int>], fog: [Range<Int>]) -> TrackTopology {
        var result = self
        result.lineRuns = line; result.fogRuns = fog
        return result
    }
    @inline(__always) func segment(of globalIndex: Int) -> UInt32 {
        precondition(globalIndex >= 0 && globalIndex < count)
        return labels.isEmpty ? 0 : labels[globalIndex]
    }
    @inline(__always) func pathRank(of globalIndex: Int) -> Int {
        precondition(globalIndex >= 0 && globalIndex < count)
        return rank.isEmpty ? globalIndex : Int(rank[globalIndex])
    }
    @inline(__always) func globalIndex(atPathRank pathRank: Int) -> Int {
        precondition(pathRank >= 0 && pathRank < count)
        return order.isEmpty ? pathRank : Int(order[pathRank])
    }
    func segmentRange(of globalIndex: Int) -> Range<Int> {
        segments[segmentLookup[segment(of: globalIndex)]!].range
    }
    func adjacent(to globalIndex: Int, direction: Int, steps: Int = 1) -> Int? {
        guard globalIndex >= 0, globalIndex < count, steps >= 0,
              direction == -1 || direction == 1 else { return nil }
        let r = segmentRange(of: globalIndex)
        let p = pathRank(of: globalIndex)
        guard steps <= (direction < 0 ? p - r.lowerBound : r.upperBound - 1 - p) else { return nil }
        return self.globalIndex(atPathRank: p + direction * steps)
    }
    func indices(between a: Int, and b: Int, includeEnds: Bool = false) -> TrackPathIndices? {
        guard a >= 0, b >= 0, a < count, b < count, segment(of: a) == segment(of: b) else { return nil }
        let x = pathRank(of: a), y = pathRank(of: b)
        guard x <= y else { return nil }
        let lo = includeEnds ? x : min(x + 1, y)
        let hi = includeEnds ? y + 1 : y
        return TrackPathIndices(order: order, range: lo..<hi)
    }
    func innerCount(_ a: Int, _ b: Int) -> Int? {
        indices(between: a, and: b)?.count
    }
    /// Each path run is monotone in global time indices, so clipping takes two binary searches.
    func makeDrawRuns(kind: PathDrawKind, globalTimeRange: Range<Int>, stride: Int,
                      includeSoftBreaks: Bool = true) -> PathDrawPlan {
        let step = max(1, stride)
        let source = includeSoftBreaks ? (kind == .line ? lineRuns : fogRuns) : segments.map { $0.range }
        var runs: [PathDrawRun] = []
        runs.reserveCapacity(source.count)
        var instances = 0
        func lowerBound(_ value: Int, in r: Range<Int>) -> Int {
            if isIdentity { return min(r.upperBound, max(r.lowerBound, value)) }
            var lo = r.lowerBound, hi = r.upperBound
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if Int(order[mid]) < value { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        for r in source {
            let lo = lowerBound(globalTimeRange.lowerBound, in: r)
            let hi = lowerBound(globalTimeRange.upperBound, in: r)
            let length = hi - lo
            guard length > 0 else { continue }
            let n = length > 1 ? (length - 2) / step + 1 : (kind == .fog ? 1 : 0)
            guard n > 0 else { continue }
            runs.append(PathDrawRun(begin: UInt32(lo), end: UInt32(hi),
                                    firstInstance: UInt32(instances), instanceCount: UInt32(n)))
            instances += n
        }
        return PathDrawPlan(runs: runs, instanceCount: instances, stride: step)
    }
}

final class TrackData: Identifiable {
    let id = UUID()
    let name: String
    let count: Int
    let creator: String            // GPX creator（CSV 为空）：采样画像分辨专用记录仪/手机用
    let gpsAccuracy: Double?       // CSV 精度列中位数（米）；无则 nil

    // 原始 SoA
    let lat: [Double]
    let lon: [Double]
    let ele: [Double]
    let time: [Double]
    let speedKmh: [Double]
    let segmentID: [UInt32]
    let topology: TrackTopology
    /// 每点所属文件下标（重叠模式按文件着色/高亮；空 = 单一来源）
    let fileID: [UInt16]
    /// Global-indexed fog run tokens (equal only within one true connected path run).
    let fogBreakPrefix: [UInt32]

    // 投影 SoA（双精度世界坐标 + RTC 单精度偏移）
    let mercX: [Double]
    let mercY: [Double]
    /// 空间索引（莫顿序）：spatialOrder[k] = 第 k 个 Z 序位置对应的点下标，
    /// spatialKeys[k] = 该点的 48 位莫顿键（有序）。视口剔除/拾取按键区间二分；
    /// spatialFirsts = 各级格首点位置表（按级拼接，spatialFirstOffsets 定界）
    let spatialOrder: [UInt32]
    let spatialKeys: [UInt64]
    let spatialFirsts: [UInt32]
    let spatialFirstOffsets: [Int]
    let center: SIMD2<Double>
    let rtcX: [Float]
    let rtcY: [Float]
    let lineBreakPrefix: [UInt32]   // Global-indexed line run tokens (>30 min / >10 km soft breaks).

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
        let topology = TrackTopology(segmentID: parsed.segmentID, count: parsed.count)

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
            case 0:  buildStageProjection(src, topology: topology, into: scratch)
            case 1:  buildStageSpeed(src, topology: topology, hasTime: hasTime, into: scratch)
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

        // 空间索引：按时间排序的数组在放大后可见点散布全数组，渲染/拾取
        // 只能全量扫；莫顿序索引让视口剔除变成几十个连续区段
        let tS = tick()
        let sp = SpatialIndex.build(mercX: scratch.mx, mercY: scratch.my)
        stats.spatialMs = Double(tick() - tS) / 1e6

        let track = TrackData(
            name: parsed.name.isEmpty
                ? String(localized: "未命名轨迹",
                         comment: "Fallback track name when the file has no <name>; shown as the track title and written as the GPX <name> on export")
                : parsed.name,
            count: n,
            creator: parsed.creator, gpsAccuracy: parsed.accuracyMedian,
            lat: parsed.lat, lon: parsed.lon, ele: parsed.ele, time: parsed.time,
            fileID: parsed.fileID, segmentID: parsed.segmentID, topology: scratch.topology!,
            fogBreakPrefix: scratch.fogBreakPrefix,
            speedKmh: scratch.speeds,
            mercX: scratch.mx, mercY: scratch.my,
            spatialOrder: sp.order, spatialKeys: sp.keys,
            spatialFirsts: sp.firsts, spatialFirstOffsets: sp.firstOffsets,
            center: SIMD2(scratch.cx, scratch.cy),
            rtcX: scratch.rtcX, rtcY: scratch.rtcY, lineBreakPrefix: scratch.lineBreakPrefix,
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
        var topology: TrackTopology?
        var mx: [Double] = []; var my: [Double] = []
        var cx = 0.0, cy = 0.0
        var rtcX: [Float] = []; var rtcY: [Float] = []
        var mercBounds = (minX: 0.0, maxX: 0.0, minY: 0.0, maxY: 0.0)
        var totalLen = 0.0
        var medianSeg = 0.0
        var breaks = 0
        var lineBreakPrefix: [UInt32] = []   // Indexed by global time; token identifies a true line run.
        var projectMs = 0.0
        // B 测速
        var speeds: [Double] = []
        var speedMs = 0.0
        // C 球面向量
        var unitX: [Float] = []; var unitY: [Float] = []; var unitZ: [Float] = []
        // D 抬升 + 经纬极值 + 迷雾断点前缀和
        var liftF: [Float] = []
        var hasEle = false
        var bbox = (minLat: 0.0, maxLat: 0.0, minLon: 0.0, maxLon: 0.0)
        var fogBreakPrefix: [UInt32] = []
    }

    /// 阶段 A：墨卡托投影 → 中心/RTC → 投影界 → 段长统计 + 断点检测
    private static func buildStageProjection(_ p: ParsedTrack, topology: TrackTopology, into s: BuildScratch) {
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
        var identityLengths: [Double] = []
        if n >= 2 && topology.isIdentity {
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
            identityLengths = seg
        }
        // Real path adjacency, including interleaved source segments.
        var lineRuns: [Range<Int>] = [], fogRuns: [Range<Int>] = []
        var linePrefix = [UInt32](repeating: 0, count: n)
        var fogPrefix = linePrefix
        var lengths: [Double] = []
        if !topology.isIdentity { lengths.reserveCapacity(n - topology.segments.count) }
        var lineToken: UInt32 = 0, fogToken: UInt32 = 0
        let d = Double.pi / 180
        for segment in topology.segments {
            let r = segment.range
            var lineStart = r.lowerBound, fogStart = r.lowerBound
            if r.lowerBound > 0 { lineToken &+= 1; fogToken &+= 1 }
            for path in r {
                let i = topology.globalIndex(atPathRank: path)
                if path > r.lowerBound {
                    let j = topology.globalIndex(atPathRank: path - 1)
                    let length = topology.isIdentity ? identityLengths[path - 1] : hypot(mx[i] - mx[j], my[i] - my[j])
                    let dt = p.time[i] - p.time[j]
                    if !topology.isIdentity { lengths.append(length) }
                    if (dt.isFinite && dt > 1800) || length * 40_075_000 > 10_000 {
                        lineRuns.append(lineStart..<path); lineStart = path; lineToken &+= 1
                    }
                    let dy = (p.lat[i] - p.lat[j]) * 111_320
                    let dx = (p.lon[i] - p.lon[j]) * 111_320 * cos(p.lat[j] * d)
                    if (dt.isFinite && dt > 600) || dx * dx + dy * dy > 10_000 {
                        fogRuns.append(fogStart..<path); fogStart = path; fogToken &+= 1
                    }
                }
                linePrefix[i] = lineToken; fogPrefix[i] = fogToken
            }
            if !r.isEmpty { lineRuns.append(lineStart..<r.upperBound); fogRuns.append(fogStart..<r.upperBound) }
        }
        if !topology.isIdentity {
            s.totalLen = lengths.reduce(0, +)
            s.medianSeg = GeoCompute.medianSampled(lengths)
        }
        s.breaks = max(0, lineRuns.count - 1)
        s.lineBreakPrefix = linePrefix; s.fogBreakPrefix = fogPrefix
        s.topology = topology.withRuns(line: lineRuns, fog: fogRuns)
        s.mx = mx; s.my = my
    }

    /// 阶段 B：相邻点测速
    private static func buildStageSpeed(_ p: ParsedTrack, topology: TrackTopology, hasTime: Bool, into s: BuildScratch) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        s.speeds = hasTime
            ? GeoCompute.speedsKmh(lat: p.lat, lon: p.lon, time: p.time, pathOrder: topology.order, segmentRanges: topology.segments.map { $0.range })
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
        // Path break tokens are produced alongside the topology in projection stage A.
    }

    private init(name: String, count: Int, creator: String, gpsAccuracy: Double?,
                 lat: [Double], lon: [Double], ele: [Double], time: [Double],
                 fileID: [UInt16], segmentID: [UInt32], topology: TrackTopology, fogBreakPrefix: [UInt32],
                 speedKmh: [Double], mercX: [Double], mercY: [Double],
                 spatialOrder: [UInt32], spatialKeys: [UInt64],
                 spatialFirsts: [UInt32], spatialFirstOffsets: [Int],
                 center: SIMD2<Double>, rtcX: [Float], rtcY: [Float], lineBreakPrefix: [UInt32],
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
        self.creator = creator
        self.gpsAccuracy = gpsAccuracy
        self.lat = lat; self.lon = lon; self.ele = ele; self.time = time
        self.fileID = fileID
        self.segmentID = segmentID; self.topology = topology
        self.fogBreakPrefix = fogBreakPrefix
        self.speedKmh = speedKmh
        self.mercX = mercX; self.mercY = mercY
        self.spatialOrder = spatialOrder; self.spatialKeys = spatialKeys
        self.spatialFirsts = spatialFirsts; self.spatialFirstOffsets = spatialFirstOffsets
        self.center = center
        self.rtcX = rtcX; self.rtcY = rtcY
        self.lineBreakPrefix = lineBreakPrefix
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

    /// 找不同高亮：先整轨迹刷成半透明灰底，再把命中下标覆写成高亮色。
    /// 与 recolor 系出同门（memset_pattern4 铺底 + 稀疏覆写），返回耗时 ms
    @discardableResult
    func recolorDiffMask(indices: [Int32], hit: SIMD4<UInt8>,
                         dim: SIMD4<UInt8> = SIMD4(140, 140, 145, 60)) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard count > 0 else { return 0 }
        var c = [UInt8](unsafeUninitializedCapacity: count * 4) { _, m in m = count * 4 }
        var dimPat: [UInt8] = [dim.x, dim.y, dim.z, dim.w]
        let hitPat = UInt32(hit.x) | (UInt32(hit.y) << 8)
            | (UInt32(hit.z) << 16) | (UInt32(hit.w) << 24)
        c.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            memset_pattern4(base, &dimPat, raw.count)
            let p32 = base.assumingMemoryBound(to: UInt32.self)
            let n = count
            indices.withUnsafeBufferPointer { ib in
                let ip = ib.baseAddress!
                for k in 0..<ib.count {
                    let i = Int(ip[k])
                    if i >= 0, i < n { p32[i] = hitPat }
                }
            }
        }
        colors = c
        effectiveMode = .single
        colorRange = (0, 1)
        colorVersion += 1
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    // MARK: 《世界迷雾》口径的探索统计

    /// 世界 = 2²²×2²² 墨卡托格；相邻样本间沿直线光栅化解锁格子
    /// （与迷雾渲染同一套记录间隙判定：间隙处只解锁端点格）；
    /// 每格面积 = (9.5546m × cosφ)²；等级 = √(面积km²×250)（逆向文章实测公式）。
    /// 后台一次性计算（~百 ms 级），结果按轨迹缓存
    func computeFogStats() -> FogStats {
        let n = count
        guard n > 0 else { return FogStats(cells: 0, km2: 0, level: 0, percent: 0, nextLevelKm2: 0.004) }
        let keys = fogUnlockKeys()
        let grid = Double(1 << 22)
        let cellMask: UInt64 = (1 << 22) - 1
        // 逐格面积。公式用真实存档对账校准过（data/*.fwdb + 护照截图真值）：
        // 赤道格宽 = 2πa/2²²（WGS84 a=6378137），纬度按 64 格 tile 行中心取值
        // ——两个存档分别只差 +69ppb / +1.1ppb，等级与占比逐位吻合
        let baseW = 2.0 * Double.pi * 6_378_137.0 / grid
        var m2 = 0.0
        for k in keys {
            let yTile = Double((k & cellMask) & ~63) + 32.0   // tile 行中心
            let yMerc = yTile / grid
            let cosLat = 1.0 / cosh(Double.pi * (1.0 - 2.0 * yMerc))
            let w = baseW * cosLat
            m2 += w * w
        }
        let km2 = m2 / 1e6
        let level = Int(Double(max(0, (km2 * 250.0))).squareRoot())
        let next = 0.004 * Double((level + 1) * (level + 1)) - km2
        return FogStats(cells: keys.count, km2: km2, level: level,
                        percent: km2 / 510_072_000.0 * 100.0,
                        nextLevelKm2: max(0, next))
    }

    /// 《世界迷雾》口径的解锁格键（x<<22|y，排序去重）：每点自身格 + 连通段的直线光栅化。地区统计也用它
    func fogUnlockKeys() -> [UInt64] {
        let n = count
        guard n > 0 else { return [] }
        let grid = Double(1 << 22)

        // 1) 并行收集解锁格 key（x<<22|y）：每点自身格 + 连通段的直线光栅化
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let chunks = max(1, min(cores, n / 131_072 + 1))
        var parts = [[UInt64]](repeating: [], count: chunks)
        parts.withUnsafeMutableBufferPointer { pb in
            let out = pb
            mercX.withUnsafeBufferPointer { mxb in
                mercY.withUnsafeBufferPointer { myb in
                    fogBreakPrefix.withUnsafeBufferPointer { bpb in
                        let mx = mxb.baseAddress!, my = myb.baseAddress!
                        let bp = bpb.baseAddress!
                        DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                            var keys = [UInt64]()
                            keys.reserveCapacity(64_000)
                            let cell: (Int) -> (Int, Int) = { i in
                                let x = min(Int(mx[i] * grid), (1 << 22) - 1)
                                let y = min(Int(my[i] * grid), (1 << 22) - 1)
                                return (max(0, x), max(0, y))
                            }
                            let lo = n * ci / chunks, hi = n * (ci + 1) / chunks
                            for path in lo..<hi {
                                let i = self.topology.globalIndex(atPathRank: path)
                                let (x0, y0) = cell(i)
                                keys.append(UInt64(x0) << 22 | UInt64(y0))
                                // 连通段：整数 DDA（主轴步进 = 逆向文章的斜向解锁语义）
                                let next = path + 1 < n ? self.topology.globalIndex(atPathRank: path + 1) : i
                                if path + 1 < n, bp[next] == bp[i] {
                                    let (x1, y1) = cell(next)
                                    let dx = x1 - x0, dy = y1 - y0
                                    let steps = max(abs(dx), abs(dy))
                                    if steps > 1, steps < 4096 {
                                        let fx = Double(dx) / Double(steps)
                                        let fy = Double(dy) / Double(steps)
                                        for s in 1..<steps {
                                            let xs = x0 + Int((Double(s) * fx).rounded())
                                            let ys = y0 + Int((Double(s) * fy).rounded())
                                            keys.append(UInt64(xs) << 22 | UInt64(ys))
                                        }
                                    }
                                }
                            }
                            out[ci] = keys
                        }
                    }
                }
            }
        }
        var all = [UInt64]()
        all.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for p in parts { all.append(contentsOf: p) }
        // 2) 排序去重
        all.sort()
        var uniq = [UInt64](); uniq.reserveCapacity(all.count)
        var prev: UInt64 = .max
        for k in all where k != prev { prev = k; uniq.append(k) }
        return uniq
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
        // vDSP does not promise stability. Repair equal keys (including missing times).
        var begin = 0
        while begin < n {
            var end = begin + 1
            while end < n && keys[Int(perm[end])] == keys[Int(perm[begin])] { end += 1 }
            if end - begin > 1 { perm[begin..<end].sort() }
            begin = end
        }

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
        if !p.segmentID.isEmpty {
            let old = p.segmentID
            p.segmentID = (0..<p.count).map { old[Int(src($0))] }
        }
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
        for k in 1..<timedOrder.count where timedOrder[k].element.first <= timedOrder[k - 1].element.last {
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
                    if l < heap.count, heap[l].t < heap[m].t || (heap[l].t == heap[m].t && heap[l].i < heap[m].i) { m = l }
                    if r < heap.count, heap[r].t < heap[m].t || (heap[r].t == heap[m].t && heap[r].i < heap[m].i) { m = r }
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
        if !p.segmentID.isEmpty {
            let old = p.segmentID
            var out = [UInt32](repeating: 0, count: n)
            for mv in moves { out.replaceSubrange(mv.dst..<(mv.dst + mv.src.count), with: old[mv.src]) }
            p.segmentID = out
        }
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

    /// 空间索引拾取：只扫描光标附近格子里的点（全量 vDSP 扫 200 万点 ≈3ms/帧，
    /// 这里通常几百点）。半径 radiusMerc 内无点返回 nil；索引缺失返回 nil 由
    /// 调用方回退全量扫描
    func nearestPointSpatial(mercX qx: Double, mercY qy: Double, radiusMerc r: Double,
                             range: (start: Int, len: Int)? = nil) -> (index: Int, mercDist: Double)? {
        guard !spatialKeys.isEmpty, count > 0, r > 0 else { return nil }
        let rStart = max(0, min(range?.start ?? 0, count - 1))
        let rEnd = rStart + max(0, min(range?.len ?? count, count - rStart))
        guard rEnd > rStart else { return nil }
        let ranges = SpatialIndex.ranges(keys: spatialKeys,
                                         x0: qx - r, y0: qy - r, x1: qx + r, y1: qy + r,
                                         maxCellsAcross: 4)
        var best = -1
        var bestD2 = r * r
        mercX.withUnsafeBufferPointer { px in
        mercY.withUnsafeBufferPointer { py in
        spatialOrder.withUnsafeBufferPointer { po in
            for rg in ranges {   // 键 48 位、格 ≈2m：光标半径内通常只有几十点
                for k in rg {
                    let i = Int(po[k])
                    guard i >= rStart, i < rEnd else { continue }
                    let dx = px[i] - qx, dy = py[i] - qy
                    let d2 = dx * dx + dy * dy
                    if d2 < bestD2 { bestD2 = d2; best = i }
                }
            }
        }}}
        return best >= 0 ? (best, bestD2.squareRoot()) : nil
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

    // 中性数字格式：固定 POSIX 区域 + 公历，任何界面语言/日历设置下输出都一样
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = .current
        return f
    }()
    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
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
            let unit = String(localized: "时刻",
                              comment: "Color legend unit label in time color mode, after the HH:mm range (like km/h for speed); means time of day")
            return (TrackData.hmFormatter.string(from: lo), TrackData.hmFormatter.string(from: hi), unit)
        }
    }
}

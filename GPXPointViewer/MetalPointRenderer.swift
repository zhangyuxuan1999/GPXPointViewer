//
//  MetalPointRenderer.swift
//  GPXPointViewer
//
//  GPU 实例化渲染器：点云 + 方向箭头轨迹线。
//
//  性能设计（对应 M4 GPU / 统一内存）：
//  - 顶点数据用 .storageModeShared 缓冲：Apple Silicon 统一内存架构下
//    CPU 与 GPU 读同一块 DRAM。makeBuffer(bytes:) 本身有一次 memcpy，
//    因此缓冲随数据在后台线程预建（buildBuffers），主线程 setData 仅领养句柄；
//  - 点云：全部点一次实例化 drawPrimitives（1 个 draw call）；
//  - 轨迹箭头：线段与箭头各一次实例化提交，顶点着色器按 instance_id
//    经紧凑段内 draw-run 读取点位 SoA，方向/法线/箭头张角
//    在 GPU 上对全部线段并行计算 —— 零额外几何内存、零 CPU 每帧工作；
//  - 精度方案 RTC：CPU 用 double 折算每帧常量，顶点只存 float 偏移；
//  - presentsWithTransaction + waitUntilScheduled：与 MapKit 底图逐帧锁定。
//

import Foundation
import Metal
import MetalKit
import QuartzCore
import simd

/// 与 Shaders.metal 中 PointUniforms 逐字段对齐（size 64，align 8）
struct PointUniforms {
    var scale: SIMD2<Float>
    var offset: SIMD2<Float>
    var ndcPerPixel: SIMD2<Float>
    var radiusPx: Float
    var haloPx: Float
    var alpha: Float
    var mode: UInt32
    var stride: UInt32
    var count: UInt32
    var start: UInt32
    var rangeLen: UInt32
    var pixelMode: UInt32
    var flashFile: Int32 = -1     // 文件高亮闪烁：目标文件下标（-1 = 无）
    var flashStrength: Float = 0  // 闪烁强度 0…1
    // 空间剔除：useOrder=1 时实例经莫顿序置换表间接寻址，只提交视口区段
    var useOrder: UInt32 = 0
    var orderStart: UInt32 = 0
    var orderLen: UInt32 = 0
    var _pad2: UInt32 = 0
}

/// 与 Shaders.metal 中 LineUniforms 逐字段对齐（size 80，align 16）
struct LineUniforms {
    var scale: SIMD2<Float>
    var offset: SIMD2<Float>
    var viewportPx: SIMD2<Float>
    var useBreaks: UInt32       // 1 = 用断点前缀和缓冲剔除跨段直连（LOD 抽稀下也准确）
    var arrowEvery: UInt32      // 箭头密度：每 N 段一个箭头
    var color: SIMD4<Float>
    var widthPx: Float
    var headLenPx: Float
    var headWidthPx: Float
    var isHead: UInt32
    var stride: UInt32
    var count: UInt32
    var start: UInt32
    var rangeLen: UInt32
}

/// 与 Shaders.metal 中 HeatUniforms 逐字段对齐（16 B）
struct HeatUniforms {
    var gain: Float        // 密度→热度增益（已含 stride 归一化）
    var opacity: Float     // 图层整体透明度
    var pad1: Float = 0
    var pad2: Float = 0
}

/// 与 Shaders.metal 中 FogUniforms 逐字段对齐（48 B）
struct FogUniforms {
    var color: SIMD4<Float>    // rgb = 雾色，a = 雾整体不透明度
    var params: SIMD4<Float>   // x = RTC 中心墨卡托 y，y = 清除半径（米），
                               // z = 最小半径（累积纹理像素），w = 白冲刷强度
    var flags: SIMD4<UInt32>   // x = 文件可见位掩码（重叠模式勾选显隐），yzw 备用
}

/// 每帧渲染统计
struct FrameStats {
    var waitMs: Double     // nextDrawable 等待（GPU 反压）
    var encodeMs: Double   // 命令编码
    var gpuMs: Double
    var drawn: Int
    var stride: Int
    var fps: Double        // 交互期帧率 EMA（静止时归零）
}

/// 轨迹线绘制参数（全部为物理像素）
struct LineParams {
    var widthPx: Float
    var headLenPx: Float
    var headWidthPx: Float
    var color: SIMD4<Float>   // a = 线透明度
    var arrows: Bool
    var arrowEvery: UInt32 = 1
    var cullBreaks: Bool = true
    var fileMask: UInt32 = 0xFFFF_FFFF
}

/// 与 Shaders.metal 中 GlobeUniforms 逐字段对齐（size 224，align 16）
struct GlobeUniforms {
    var mvp: simd_float4x4
    var modelView: simd_float4x4
    var moonPosModel: SIMD4<Float>   // xyz = 月球位置（地固系），w = 月球半径
    var sunDirModel: SIMD4<Float>    // xyz = 太阳方向（模型系单位向量）
    var ndcPerPixel: SIMD2<Float>
    var projDiag: SIMD2<Float>       // 透视矩阵对角 (xs, ys)
    var radiusPx: Float
    var haloPx: Float
    var alpha: Float
    var pointLift: Float
    var stride: UInt32
    var count: UInt32
    var start: UInt32
    var rangeLen: UInt32
    var flags: UInt32                // bit0 高亮环，bit1 浅色外观
    var mapDim: Float                // 底图不透明度（作用于球面，与平面压暗语义一致）
    var flashFile: Int32          // 文件高亮闪烁：目标文件下标（-1 = 无）
    var flashStrength: Float      // 闪烁强度 0…1
    var fileMask: UInt32 = 0xFFFF_FFFF   // 迷雾模式文件显隐位掩码（仅 fogStyle 生效）
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
}

/// 与 Shaders.metal 中 MeteorUniforms 逐字段对齐（32 B）
struct MeteorUniforms {
    var p0: SIMD2<Float>
    var dir: SIMD2<Float>
    var lenNdc: Float
    var phase: Float
    var widthNdcY: Float
    var pad: Float
}

/// 与 Shaders.metal 中 StarData 逐字段对齐（32 B）
struct StarData {
    var a: SIMD4<Float>   // xyz 方向 + w 大小(px)
    var b: SIMD4<Float>   // rgb 色温 + a 亮度
}

/// 可见区域（[0,1] 世界墨卡托）+ 目标像素尺寸
struct CameraRect {
    var x0: Double
    var y0: Double
    var w: Double
    var h: Double
    var pxW: Double
    var pxH: Double
}

/// Published color buffers are immutable. A frame holds one complete version.
final class PointColorBuffers: @unchecked Sendable {
    let temporal: MTLBuffer
    let spatial: MTLBuffer?
    let version: UInt64
    typealias Allocator = (Int) -> MTLBuffer?

    init(temporal: MTLBuffer, spatial: MTLBuffer?, version: UInt64) {
        self.temporal = temporal; self.spatial = spatial; self.version = version
    }

    static func build(device: MTLDevice, colors: [UInt8], order: [UInt32],
                      version: UInt64, allocate: Allocator? = nil) -> PointColorBuffers? {
        guard !colors.isEmpty, colors.count % 4 == 0,
              order.isEmpty || (order.count == colors.count / 4 &&
                  order.allSatisfy({ Int($0) < colors.count / 4 })) else { return nil }
        let make = allocate ?? { device.makeBuffer(length: $0, options: .storageModeShared) }
        guard let temporal = make(colors.count), temporal.length >= colors.count else { return nil }
        var spatial: MTLBuffer?
        if !order.isEmpty {
            guard let buffer = make(colors.count), buffer.length >= colors.count else { return nil }
            spatial = buffer
        }
        colors.withUnsafeBufferPointer { source in
            _ = memcpy(temporal.contents(), source.baseAddress!, source.count)
            if let spatial {
                TrackGPUBuffers.permute32(
                    src: UnsafeRawPointer(source.baseAddress!).assumingMemoryBound(to: UInt32.self),
                    dst: spatial.contents().assumingMemoryBound(to: UInt32.self), order: order)
            }
        }
        return PointColorBuffers(temporal: temporal, spatial: spatial, version: version)
    }

    func retain(untilCompleted command: MTLCommandBuffer) {
        command.addCompletedHandler { [self] _ in withExtendedLifetime(self) {} }
    }
}

/// Shared Swift/Metal layout; no point indices are expanded on each frame.
struct PathUniforms {
    var runCount: UInt32
    var stride: UInt32
    var identityOrder: UInt32
    var fileMask: UInt32 = 0xFFFF_FFFF
}

/// A draw holds both immutable topology buffers until GPU completion, just as
/// PointColorBuffers holds one color version. Cache replacement never reuses memory.
final class PathGPUPlan: @unchecked Sendable {
    let plan: PathDrawPlan
    let runs: MTLBuffer?
    let order: MTLBuffer?
    let identity: Bool
    init?(device: MTLDevice, plan: PathDrawPlan, order: MTLBuffer?, identity: Bool) {
        assert(MemoryLayout<PathDrawRun>.size == 16 && MemoryLayout<PathDrawRun>.stride == 16)
        assert(MemoryLayout<PathUniforms>.stride == 16)
        self.plan = plan; self.order = order; self.identity = identity
        if plan.runs.isEmpty { runs = nil }
        else {
            guard let uploaded = plan.runs.withUnsafeBytes({ data in
                device.makeBuffer(bytes: data.baseAddress!, length: data.count, options: .storageModeShared)
            }) else { return nil }
            runs = uploaded
        }
    }
    func uniforms(fileMask: UInt32 = 0xFFFF_FFFF) -> PathUniforms {
        PathUniforms(runCount: UInt32(plan.runs.count), stride: UInt32(clamping: max(1,plan.stride)),
                     identityOrder: identity ? 1 : 0, fileMask: fileMask)
    }
    func retain(untilCompleted command: MTLCommandBuffer) {
        command.addCompletedHandler { [self] _ in withExtendedLifetime(self) {} }
    }
}

private struct PathDrawCacheKey: Equatable {
    let start: Int; let length: Int; let stride: Int; let softBreaks: Bool
}

/// 后台预建的顶点缓冲组（统一内存 shared）。
/// 在解析线程随 TrackData.build 生成，主线程 setData 直接领养——
/// 免去导入结束时主线程 28 B/点 的 makeBuffer(bytes:) 拷贝卡顿
final class TrackGPUBuffers {
    let x: MTLBuffer
    let y: MTLBuffer
    let ux: MTLBuffer
    let uy: MTLBuffer
    let uz: MTLBuffer
    let lift: MTLBuffer
    let color: MTLBuffer
    let fileID: MTLBuffer?    // 每点所属文件（单一来源时为 nil）
    let breakPrefix: MTLBuffer?   // 迷雾断点前缀和（记录间隙检测）
    let pathOrder: MTLBuffer? // normalized per-segment order, distinct from Morton order
    let order: MTLBuffer?     // 莫顿序置换表（视口剔除：位置 k → 原始下标）
    // 按莫顿序物理重排的位置/颜色副本：空间路径顺序读取，
    // 不经置换表随机 gather（gather 版在城市级反而比全量慢一倍）
    let sx: MTLBuffer?
    let sy: MTLBuffer?
    let scolor: MTLBuffer?
    let firsts: MTLBuffer?    // 各级格首点位置表（去重 LOD）

    /// 32 位元素按置换表重排（并行 gather），dst[k] = src[order[k]]
    static func permute32(src: UnsafePointer<UInt32>, dst: UnsafeMutablePointer<UInt32>,
                          order: [UInt32]) {
        let n = order.count
        order.withUnsafeBufferPointer { ob in
            let o = ob.baseAddress!
            let cores = ProcessInfo.processInfo.activeProcessorCount
            let chunks = n > 200_000 ? max(1, min(cores, n / 100_000)) : 1
            DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                for k in (n * ci / chunks)..<(n * (ci + 1) / chunks) {
                    dst[k] = src[Int(o[k])]
                }
            }
        }
    }

    static func permutedBuffer(device: MTLDevice, floats: [Float], order: [UInt32]) -> MTLBuffer? {
        guard floats.count == order.count, !order.isEmpty,
              let buf = device.makeBuffer(length: order.count * 4, options: .storageModeShared)
        else { return nil }
        floats.withUnsafeBufferPointer { fb in
            permute32(src: UnsafeRawPointer(fb.baseAddress!).assumingMemoryBound(to: UInt32.self),
                      dst: buf.contents().assumingMemoryBound(to: UInt32.self), order: order)
        }
        return buf
    }

    static func permutedBuffer(device: MTLDevice, colors: [UInt8], order: [UInt32]) -> MTLBuffer? {
        guard colors.count == order.count * 4, !order.isEmpty,
              let buf = device.makeBuffer(length: order.count * 4, options: .storageModeShared)
        else { return nil }
        colors.withUnsafeBufferPointer { cb in
            permute32(src: UnsafeRawPointer(cb.baseAddress!).assumingMemoryBound(to: UInt32.self),
                      dst: buf.contents().assumingMemoryBound(to: UInt32.self), order: order)
        }
        return buf
    }

    init?(device: MTLDevice, track: TrackData) {
        let n = track.count
        guard n > 0 else { return nil }
        pathOrder = track.topology.order.isEmpty ? nil : track.topology.order.withUnsafeBytes { data in
            device.makeBuffer(bytes:data.baseAddress!,length:data.count,options:.storageModeShared)
        }
        order = track.spatialOrder.isEmpty ? nil : track.spatialOrder.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!,
                              length: n * MemoryLayout<UInt32>.stride,
                              options: .storageModeShared)
        }
        sx = Self.permutedBuffer(device: device, floats: track.rtcX, order: track.spatialOrder)
        sy = Self.permutedBuffer(device: device, floats: track.rtcY, order: track.spatialOrder)
        scolor = Self.permutedBuffer(device: device, colors: track.colors, order: track.spatialOrder)
        firsts = track.spatialFirsts.isEmpty ? nil : track.spatialFirsts.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!,
                              length: $0.count * MemoryLayout<UInt32>.stride,
                              options: .storageModeShared)
        }
        func upload(_ a: [Float]) -> MTLBuffer? {
            a.withUnsafeBufferPointer {
                device.makeBuffer(bytes: $0.baseAddress!,
                                  length: n * MemoryLayout<Float>.stride,
                                  options: .storageModeShared)
            }
        }
        guard let bx = upload(track.rtcX), let by = upload(track.rtcY),
              let bux = upload(track.unitX), let buy = upload(track.unitY),
              let buz = upload(track.unitZ), let bl = upload(track.liftF),
              let bc = track.colors.withUnsafeBufferPointer({
                  device.makeBuffer(bytes: $0.baseAddress!, length: n * 4,
                                    options: .storageModeShared)
              })
        else { return nil }
        x = bx; y = by; ux = bux; uy = buy; uz = buz; lift = bl; color = bc
        fileID = track.fileID.isEmpty ? nil : track.fileID.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!,
                              length: n * MemoryLayout<UInt16>.stride,
                              options: .storageModeShared)
        }
        breakPrefix = track.fogBreakPrefix.isEmpty ? nil
            : track.fogBreakPrefix.withUnsafeBufferPointer {
                device.makeBuffer(bytes: $0.baseAddress!,
                                  length: n * MemoryLayout<UInt32>.stride,
                                  options: .storageModeShared)
            }
    }
}

/// DeepSeek 2026-11-01：屏幕空间分层 LOD。
/// 每层把相机范围按 2×2 屏幕像素切格；每格最多 K 点，不足全留。
struct PointLODLevel {
    let order: [UInt32]      // 本层保留的原始点下标（升序）
    let span: Double         // 本层目标相机 span（Mercator）
}

enum PointLODBuilder {
    static func build(track: TrackData, center: (x: Double, y: Double),
                      baseSpan: Double, levels: Int = 5, k: Int = 2,
                      cells: (Int, Int) = (480, 270)) -> [PointLODLevel] {
        let n = track.count
        guard n > 0, baseSpan > 0, levels > 0 else { return [] }
        var out: [PointLODLevel] = []
        for level in 0..<levels {
            // 层覆盖始终是整个 baseSpan 区域；层越细，格子越小、格数越多。
            let span = baseSpan * pow(2.0, -Double(level))
            let x0 = center.x - baseSpan / 2
            let y0 = center.y - baseSpan / 2
            let cols = max(1, Int((Double(cells.0) * baseSpan / span).rounded()))
            let rows = max(1, Int((Double(cells.1) * baseSpan / span).rounded()))
            var buckets: [Int: [Int]] = [:]
            for i in 0..<n {
                let x = track.mercX[i], y = track.mercY[i]
                guard x >= x0, x < x0 + baseSpan, y >= y0, y < y0 + baseSpan else { continue }
                let cx = min(cols - 1, max(0, Int((x - x0) / baseSpan * Double(cols))))
                let cy = min(rows - 1, max(0, Int((y - y0) / baseSpan * Double(rows))))
                buckets[cy * cols + cx, default: []].append(i)
            }
            var chosen: [UInt32] = []
            chosen.reserveCapacity(buckets.count * k)
            for (_, arr) in buckets {
                if arr.count <= k {
                    chosen.append(contentsOf: arr.map { UInt32($0) })
                } else {
                    for j in 0..<k {
                        chosen.append(UInt32(arr[j * arr.count / k]))
                    }
                }
            }
            // 轨迹兜底：同段内相邻保留点屏幕间距 >3px 时，把中间的点补回。
            // 只对连续轨迹（同 segment、时间间隔 <6h）生效，不跨航段/空白期。
            var chosenSet = Set(chosen)
            var last = -1
            var extra: [UInt32] = []
            for i in 0..<n where chosenSet.contains(UInt32(i)) {
                if last >= 0,
                   track.topology.segment(of: i) == track.topology.segment(of: last),
                   track.time[i] - track.time[last] < 6 * 3600 {
                    let dx = (track.mercX[i] - track.mercX[last]) * 960.0 / span
                    let dy = (track.mercY[i] - track.mercY[last]) * 960.0 / span
                    let gapPx = (dx * dx + dy * dy).squareRoot()
                    if gapPx > 3.0 {
                        // 只补到“每 3px 一个点”，不整段恢复全密度
                        let need = min(i - last - 1, max(0, Int(ceil(gapPx / 3.0)) - 1))
                        let seg = track.topology.segment(of: last)
                        if need > 0 {
                            for j in 1...need {
                                let idx = last + (i - last) * j / (need + 1)
                                if idx > last, idx < i, !chosenSet.contains(UInt32(idx)),
                                   track.topology.segment(of: idx) == seg {
                                    extra.append(UInt32(idx))
                                }
                            }
                        }
                    }
                }
                last = i
            }
            if !extra.isEmpty {
                chosenSet.formUnion(extra)
                chosen = chosenSet.sorted()
            }
            out.append(PointLODLevel(order: chosen, span: span))
        }
        return out
    }
}

final class MetalPointRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pointPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let lineIdentityPipeline: MTLRenderPipelineState
    private let suppliedLibrary: MTLLibrary?
    private var pathTopology: TrackTopology?
    private var pathOrderBuffer: MTLBuffer?
    private var linePathCache: (PathDrawCacheKey, PathGPUPlan)?
    private var fogPathCache: (PathDrawCacheKey, PathGPUPlan)?
    private(set) var pathPlanBuilds = 0
    private(set) var lastLineDrawCalls = 0
    private(set) var lastFogDrawCalls = 0

    private var bufX: MTLBuffer?
    private var bufY: MTLBuffer?
    private var bufBreak: MTLBuffer?      // 轨迹线断点前缀和
    private var colorBuffers: PointColorBuffers?
    // DeepSeek 2026-10-31：城市章节回放的“按区域揭示”缓冲（时间序，与点下标一致）
    private var revealAreaBuf: MTLBuffer?
    private var revealTimeBuf: MTLBuffer?
    private var revealCursorBuf: MTLBuffer?
    private var revealAreaCount = 0
    private var dummyUShort: MTLBuffer?
    private var bufUX: MTLBuffer?          // 球面单位向量 SoA（自绘地球用）
    private var bufUY: MTLBuffer?
    private var bufUZ: MTLBuffer?
    private(set) var pointCount = 0
    private var center = SIMD2<Double>(0.5, 0.5)

    // 自绘地球资产（懒加载：不进地球视角零成本）
    static let globeFovY: Float = 0.698               // 垂直视场 40°
    private var globeSpherePipeline: MTLRenderPipelineState?
    private var globePointPipeline: MTLRenderPipelineState?
    private var starPipeline: MTLRenderPipelineState?
    private var moonPipeline: MTLRenderPipelineState?
    private var orbitPipeline: MTLRenderPipelineState?
    private var sphereDepthState: MTLDepthStencilState?
    private var pointDepthState: MTLDepthStencilState?
    private var bgDepthState: MTLDepthStencilState?   // 星空：always + 不写
    private var sphereVB: MTLBuffer?
    private var sphereUVB: MTLBuffer?
    private var sphereIB: MTLBuffer?
    private var sphereIndexCount = 0
    private var bufLift: MTLBuffer?                   // 海拔抬升 SoA
    private var bufFileID: MTLBuffer?                 // 每点所属文件（重叠模式闪烁用）
    private var bufBreakPrefix: MTLBuffer?            // 迷雾断点前缀和
    private var bufOrder: MTLBuffer?                  // 莫顿序置换表（视口剔除）
    private var bufSX: MTLBuffer?                     // 莫顿序重排的位置/颜色副本
    private var lodLevels: [PointLODLevel] = []
    private var lodBuffers: [MTLBuffer] = []
    private var bufSY: MTLBuffer?
    private var bufFirsts: MTLBuffer?                 // 各级格首点位置表
    private var spatialKeys: [UInt64] = []            // 有序莫顿键（CPU 侧二分区段）
    private var spatialOrder: [UInt32] = []           // 置换表（换色时同步重排副本）
    private var spatialFirsts: [UInt32] = []          // 格首点表（CPU 侧二分子区间）
    private var spatialFirstOffsets: [Int] = []
    /// 置换表占位（useOrder = 0 时不会被读取）
    private lazy var dummyOrder: MTLBuffer? =
        device.makeBuffer(length: 4, options: .storageModeShared)
    /// fileID 缓冲的占位（着色器要求绑定存在；flashFile = -1 时不会被读取）
    private lazy var dummyFileID: MTLBuffer? =
        device.makeBuffer(length: 2, options: .storageModeShared)
    /// 断点前缀和的占位（全零 = 永不剪断；数据缺失时的兜底）
    private lazy var dummyBreakPrefix: MTLBuffer? =
        device.makeBuffer(length: 4, options: .storageModeShared)
    private var bufStars: MTLBuffer?
    private var starCount = 0
    private var earthTexDark: MTLTexture?
    private var earthTexLight: MTLTexture?
    private var moonTexture: MTLTexture?
    // 像素地球模式
    private var pixelDotPipeline: MTLRenderPipelineState?
    private var pixelCapPipeline: MTLRenderPipelineState?
    private var columnPipeline: MTLRenderPipelineState?
    private var pixelSpherePipeline: MTLRenderPipelineState?
    private var meteorPipeline: MTLRenderPipelineState?
    private var bufPixelTerrain: MTLBuffer?
    private var terrainCount = 0
    private var bufPixelCells: MTLBuffer?
    private var cellCount = 0
    // 流星（CPU 侧生灭，逐帧 setVertexBytes）
    private struct Meteor { var born: Double; var dur: Double
                            var p0: SIMD2<Float>; var dir: SIMD2<Float>
                            var travel: Float; var tail: Float }
    private var meteors: [Meteor] = []
    private var nextMeteorAt: Double = 0
    private var depthTex: MTLTexture?
    private var globeSetupFailed = false

    /// 每帧回调，主线程派发
    var onFrameStats: ((FrameStats) -> Void)?
    private var lastFrameTime: Double = 0
    private var fpsEMA: Double = 0

    /// 进程唯一 Metal 设备（Apple Silicon 单 GPU）：后台预建缓冲与渲染必须同设备
    static let sharedDevice: MTLDevice? = MTLCreateSystemDefaultDevice()

    /// 任意线程可调（MTLDevice 线程安全）：把轨迹 SoA 复制进 GPU 共享内存缓冲。
    /// 在解析线程随 TrackData.build 调用，主线程 setData 零拷贝领养
    /// 视口剔除总开关（离线基准 A/B 对照用；关闭 = 旧的全量时间序提交）
    nonisolated(unsafe) static var spatialCullingEnabled = true

    static func buildBuffers(track: TrackData) -> TrackGPUBuffers? {
        guard let dev = sharedDevice else { return nil }
        return TrackGPUBuffers(device: dev, track: track)
    }

    init?(library: MTLLibrary? = nil) {
        guard let dev = Self.sharedDevice,
              let q = dev.makeCommandQueue(),
              let lib = library ?? dev.makeDefaultLibrary(),
              let pointV = lib.makeFunction(name: "pointVertex"),
              let pointF = lib.makeFunction(name: "pointFragment"),
              let lineV = lib.makeFunction(name: "segmentVertex"),
              let lineF = lib.makeFunction(name: "segmentFragment") else { return nil }
        device = dev
        queue = q
        suppliedLibrary = library

        func makePipeline(_ v: MTLFunction, _ f: MTLFunction) -> MTLRenderPipelineState? {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = v
            desc.fragmentFunction = f
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].rgbBlendOperation = .add
            desc.colorAttachments[0].alphaBlendOperation = .add
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? dev.makeRenderPipelineState(descriptor: desc)
        }
        guard let pp = makePipeline(pointV, pointF),
              let lp = makePipeline(lineV, lineF) else { return nil }
        pointPipeline = pp
        linePipeline = lp
        lineIdentityPipeline = lib.makeFunction(name:"segmentIdentityVertex").flatMap { makePipeline($0,lineF) } ?? lp
    }

    // MARK: - 数据上传

    func setLODLevels(_ levels: [PointLODLevel]) {
        lodLevels = levels
        lodBuffers = levels.map { lv in
            let n = max(1, lv.order.count)
            return lv.order.withUnsafeBufferPointer {
                device.makeBuffer(bytes: $0.baseAddress!, length: n * MemoryLayout<UInt32>.stride,
                                  options: .storageModeShared)!
            }
        }
    }

    func clearLODLevels() { lodLevels = []; lodBuffers = [] }

    func setData(track: TrackData) {
        clearPlaybackReveal()
        clearLODLevels()
        pointCount = track.count
        center = track.center
        let n = track.count
        guard n > 0 else { clearData(); return }
        pathTopology = track.topology
        pathOrderBuffer = nil
        linePathCache = nil; fogPathCache = nil
        // 轨迹线断点前缀和（与点数等长；8 MB/200 万点）
        bufBreak = track.lineBreakPrefix.count == n ? track.lineBreakPrefix.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!, length: n * MemoryLayout<UInt32>.stride, options: .storageModeShared)
        } : nil
        if let g = track.gpuBuffers {
            pathOrderBuffer = g.pathOrder
            // 领养后台预建缓冲：主线程零 memcpy。
            // 交接安全：setData 与 draw 全在主线程，已提交的命令缓冲
            // 持有旧 MTLBuffer 至 GPU 完成，属性交换天然原子
            bufX = g.x; bufY = g.y
            bufUX = g.ux; bufUY = g.uy; bufUZ = g.uz
            bufLift = g.lift
            colorBuffers = PointColorBuffers(temporal: g.color, spatial: g.scolor, version: 0)
            bufFileID = g.fileID
            bufBreakPrefix = g.breakPrefix
            bufOrder = g.order
            bufSX = g.sx; bufSY = g.sy
            bufFirsts = g.firsts
            spatialKeys = track.spatialKeys
            spatialOrder = track.spatialOrder
            spatialFirsts = track.spatialFirsts
            spatialFirstOffsets = track.spatialFirstOffsets
            track.gpuBuffers = nil   // 一次性交接（再次 setData 走兜底拷贝）
            return
        }
        pathOrderBuffer = track.topology.order.isEmpty ? nil : track.topology.order.withUnsafeBytes { data in
            device.makeBuffer(bytes:data.baseAddress!,length:data.count,options:.storageModeShared)
        }
        spatialKeys = track.spatialKeys
        spatialOrder = track.spatialOrder
        spatialFirsts = track.spatialFirsts
        spatialFirstOffsets = track.spatialFirstOffsets
        bufFirsts = track.spatialFirsts.isEmpty ? nil : track.spatialFirsts.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!,
                              length: $0.count * MemoryLayout<UInt32>.stride,
                              options: .storageModeShared)
        }
        bufOrder = track.spatialOrder.isEmpty ? nil : track.spatialOrder.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!,
                              length: n * MemoryLayout<UInt32>.stride,
                              options: .storageModeShared)
        }
        bufSX = TrackGPUBuffers.permutedBuffer(device: device, floats: track.rtcX, order: track.spatialOrder)
        bufSY = TrackGPUBuffers.permutedBuffer(device: device, floats: track.rtcY, order: track.spatialOrder)
        // 兜底：无预建缓冲（无 Metal 设备构建、重复 setData 等）时当场拷贝
        func upload(_ a: [Float]) -> MTLBuffer? {
            a.withUnsafeBufferPointer {
                device.makeBuffer(bytes: $0.baseAddress!, length: n * MemoryLayout<Float>.stride, options: .storageModeShared)
            }
        }
        bufX = upload(track.rtcX)
        bufY = upload(track.rtcY)
        bufUX = upload(track.unitX)
        bufUY = upload(track.unitY)
        bufUZ = upload(track.unitZ)
        bufLift = upload(track.liftF)
        colorBuffers = PointColorBuffers.build(device: device, colors: track.colors,
                                               order: track.spatialOrder, version: 0)
        bufFileID = track.fileID.isEmpty ? nil : track.fileID.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!,
                              length: n * MemoryLayout<UInt16>.stride,
                              options: .storageModeShared)
        }
        bufBreakPrefix = track.fogBreakPrefix.isEmpty ? nil
            : track.fogBreakPrefix.withUnsafeBufferPointer {
                device.makeBuffer(bytes: $0.baseAddress!,
                                  length: n * MemoryLayout<UInt32>.stride,
                                  options: .storageModeShared)
            }
    }

    func clearData() {
        pointCount = 0
        pathTopology = nil; pathOrderBuffer = nil
        linePathCache = nil; fogPathCache = nil
        bufX = nil; bufY = nil; colorBuffers = nil; bufBreak = nil
        bufUX = nil; bufUY = nil; bufUZ = nil; bufLift = nil
        bufFileID = nil
        bufBreakPrefix = nil
        bufOrder = nil
        bufSX = nil; bufSY = nil
        bufFirsts = nil
        spatialKeys = []
        spatialOrder = []
        spatialFirsts = []
        spatialFirstOffsets = []
    }

    /// Build the complete next version before publishing; never mutate a
    /// submitted frame or TrackGPUBuffers shared with another renderer.
    func updateColors(_ colors: [UInt8], allocate: PointColorBuffers.Allocator? = nil) {
        guard let current = colorBuffers, pointCount > 0,
              colors.count == pointCount * 4,
              let next = PointColorBuffers.build(device: device, colors: colors,
                  order: spatialOrder, version: current.version &+ 1, allocate: allocate)
        else { return }
        colorBuffers = next
    }

    /// 城市章节回放：设置逐点区域/时间（一次）。渲染器不依赖规划类型，只收数组。
    func setPlaybackReveal(areas: [UInt16]?, times: [UInt32], areaCount: Int) {
        guard let areas, pointCount > 0, areas.count == pointCount,
              times.count == pointCount, areaCount > 0 else {
            clearPlaybackReveal()
            return
        }
        let n = pointCount
        revealAreaBuf = areas.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!, length: n * MemoryLayout<UInt16>.stride,
                              options: .storageModeShared)
        }
        revealTimeBuf = times.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!, length: n * MemoryLayout<UInt32>.stride,
                              options: .storageModeShared)
        }
        revealCursorBuf = device.makeBuffer(length: max(4, areaCount * MemoryLayout<UInt32>.stride),
                                            options: .storageModeShared)
        revealAreaCount = areaCount
        if let c = revealCursorBuf { memset(c.contents(), 0, c.length) }
    }

    func clearPlaybackReveal() {
        revealAreaBuf = nil; revealTimeBuf = nil; revealCursorBuf = nil
        revealAreaCount = 0
    }

    /// 每帧更新各区域的揭示游标（相对 epoch 的秒 +1）。
    func updatePlaybackCursors(_ cursors: [UInt32]) {
        guard let buf = revealCursorBuf, revealAreaCount > 0 else { return }
        let m = min(cursors.count, revealAreaCount)
        guard m > 0 else { return }
        cursors.withUnsafeBufferPointer {
            memcpy(buf.contents(), $0.baseAddress!, m * MemoryLayout<UInt32>.stride)
        }
    }

    /// Lightweight cached counters for the existing diagnostic/UI hook.
    var topologyDrawStats: [String: Int] {
        ["segments":pathTopology?.segments.count ?? 0,
         "lineRuns":linePathCache?.1.plan.runs.count ?? 0,
         "linePrimitives":linePathCache?.1.plan.instanceCount ?? 0,
         "fogRuns":fogPathCache?.1.plan.runs.count ?? 0,
         "fogPrimitives":fogPathCache?.1.plan.instanceCount ?? 0,
         "planBuilds":pathPlanBuilds,"lastLineDrawCalls":lastLineDrawCalls,"lastFogDrawCalls":lastFogDrawCalls]
    }

    private func pathPlan(kind: PathDrawKind, start: Int, length: Int,
                          stride: Int, softBreaks: Bool = true) -> PathGPUPlan? {
        guard let topology = pathTopology,
              topology.isIdentity || pathOrderBuffer != nil else { return nil }
        let lo = max(0,min(start,pointCount)), hi = max(lo,min(pointCount,lo + max(0,length)))
        let key = PathDrawCacheKey(start:lo,length:hi-lo,stride:max(1,stride),softBreaks:softBreaks)
        let previous: (PathDrawCacheKey,PathGPUPlan)?
        switch kind { case .line: previous = linePathCache; case .fog: previous = fogPathCache }
        if let previous, previous.0 == key { return previous.1 }
        let cpu = topology.makeDrawRuns(kind:kind, globalTimeRange:lo..<hi,
                                       stride:key.stride, includeSoftBreaks:softBreaks)
        guard let next = PathGPUPlan(device:device,plan:cpu,order:pathOrderBuffer,identity:topology.isIdentity) else { return nil }
        switch kind { case .line: linePathCache = (key,next); case .fog: fogPathCache = (key,next) }
        pathPlanBuilds += 1
        return next
    }

    @discardableResult
    private func encodeLinePaths(_ encoder: MTLRenderCommandEncoder, command: MTLCommandBuffer,
                                 x: MTLBuffer, y: MTLBuffer, scale: SIMD2<Float>, offset: SIMD2<Float>,
                                 viewport: SIMD2<Float>, params: LineParams,
                                 start: Int, length: Int, stride: Int) -> PathGPUPlan? {
        lastLineDrawCalls = 0
        guard let group = pathPlan(kind:.line,start:start,length:length,stride:stride,softBreaks:params.cullBreaks) else { return nil }
        guard group.plan.instanceCount > 0 else { return group }
        // Empty fileID means every point belongs to file 0; never index the
        // two-byte placeholder when a caller supplies a partial visibility mask.
        if bufFileID == nil && params.fileMask & 1 == 0 { return group }
        let fileMask: UInt32 = bufFileID == nil ? UInt32.max:params.fileMask
        group.retain(untilCompleted:command)
        var lu = LineUniforms(scale:scale,offset:offset,viewportPx:viewport,useBreaks:0,
            arrowEvery:max(1,params.arrowEvery),color:params.color,widthPx:params.widthPx,
            headLenPx:params.arrows ? params.headLenPx : 0,headWidthPx:params.headWidthPx,
            isHead:0,stride:UInt32(clamping:max(1,stride)),count:UInt32(pointCount),
            start:UInt32(start),rangeLen:UInt32(length))
        let identityFast = group.identity && group.plan.runs.count == 1
        if identityFast, let run = group.plan.runs.first {
            lu.start = run.begin; lu.rangeLen = run.end-run.begin
        }
        var path = group.uniforms(fileMask:fileMask)
        var mask = fileMask
        encoder.setRenderPipelineState(identityFast ? lineIdentityPipeline:linePipeline)
        encoder.setVertexBytes(&mask,length:MemoryLayout<UInt32>.stride,index:8)
        encoder.setVertexBuffer(x,offset:0,index:0); encoder.setVertexBuffer(y,offset:0,index:1)
        encoder.setVertexBuffer(bufBreak ?? dummyBreakPrefix,offset:0,index:3)
        encoder.setVertexBuffer(bufFileID ?? dummyFileID,offset:0,index:4)
        encoder.setVertexBuffer(group.order ?? dummyOrder,offset:0,index:5)
        encoder.setVertexBuffer(group.runs,offset:0,index:6)
        encoder.setVertexBytes(&path,length:MemoryLayout<PathUniforms>.stride,index:7)
        encoder.setVertexBytes(&lu,length:MemoryLayout<LineUniforms>.stride,index:2)
        encoder.setFragmentBytes(&lu,length:MemoryLayout<LineUniforms>.stride,index:0)
        encoder.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4,instanceCount:group.plan.instanceCount)
        lastLineDrawCalls += 1
        if params.arrows {
            lu.isHead = 1
            encoder.setVertexBytes(&lu,length:MemoryLayout<LineUniforms>.stride,index:2)
            encoder.setFragmentBytes(&lu,length:MemoryLayout<LineUniforms>.stride,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3,instanceCount:group.plan.instanceCount)
            lastLineDrawCalls += 1
        }
        return group
    }

    @discardableResult
    private func encodeFogPaths(_ encoder: MTLRenderCommandEncoder, command: MTLCommandBuffer,
                                pipeline: MTLRenderPipelineState, x: MTLBuffer, y: MTLBuffer,
                                uniforms: PointUniforms, fog: FogUniforms) -> PathGPUPlan? {
        lastFogDrawCalls = 0
        guard let group = pathPlan(kind:.fog,start:Int(uniforms.start),length:Int(uniforms.rangeLen),
                                   stride:Int(uniforms.stride)) else { return nil }
        guard group.plan.instanceCount > 0 else { return group }
        if bufFileID == nil && fog.flags.x & 1 == 0 { return group }
        group.retain(untilCompleted:command)
        var u = uniforms, f = fog
        if bufFileID == nil { f.flags.x = UInt32.max }
        var path = group.uniforms(fileMask:f.flags.x)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(x,offset:0,index:0); encoder.setVertexBuffer(y,offset:0,index:1)
        encoder.setVertexBytes(&u,length:MemoryLayout<PointUniforms>.stride,index:3)
        encoder.setVertexBytes(&f,length:MemoryLayout<FogUniforms>.stride,index:4)
        encoder.setVertexBuffer(bufBreakPrefix ?? dummyBreakPrefix,offset:0,index:5)
        encoder.setVertexBuffer(bufFileID ?? dummyFileID,offset:0,index:6)
        encoder.setVertexBuffer(group.order ?? dummyOrder,offset:0,index:7)
        encoder.setVertexBuffer(group.runs,offset:0,index:8)
        encoder.setVertexBytes(&path,length:MemoryLayout<PathUniforms>.stride,index:9)
        encoder.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4,instanceCount:group.plan.instanceCount)
        lastFogDrawCalls += 1
        return group
    }

    // MARK: - 平面热力图资产（懒加载：不开热力图零成本）

    private var heatAccumPipeline: MTLRenderPipelineState?
    private var heatColorPipeline: MTLRenderPipelineState?
    private var fogAccumPipeline: MTLRenderPipelineState?
    private var fogColorPipeline: MTLRenderPipelineState?
    private var fwdbCellPipeline: MTLRenderPipelineState?
    // .fwdb 存档的方格实例（协调器按视口缓存重建；相对批中心的墨卡托坐标）
    private var fogArchiveBuffer: MTLBuffer?
    private var fogArchiveCount = 0
    private var fogArchiveCenter = (x: 0.0, y: 0.0)

    /// 上传存档方格实例（[x, y, halfSize, coverage] × N）
    func setFogArchiveInstances(_ data: [Float], center: (x: Double, y: Double)) {
        fogArchiveCount = data.count / 4
        fogArchiveCenter = center
        fogArchiveBuffer = data.isEmpty ? nil : data.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!, length: data.count * 4,
                              options: .storageModeShared)
        }
    }
    private var heatTexture: MTLTexture?          // 热力/迷雾共用（两模式互斥）
    // 需要叠放次序的帧：视口内点按时间下标排序后的"可见表"（三帧环形缓冲，
    // 与飞行中的命令缓冲错开）。半透明点的 over 混合只能靠提交顺序还原，
    // 深度排序对半透明不成立（点 alpha 默认 235/255）
    private var visibleBufs: [MTLBuffer?] = [nil, nil, nil]
    private var visibleIdx = 0

    private func visibleBuffer(count: Int) -> MTLBuffer? {
        visibleIdx = (visibleIdx + 1) % visibleBufs.count
        let need = count * MemoryLayout<UInt32>.stride
        if let b = visibleBufs[visibleIdx], b.length >= need { return b }
        visibleBufs[visibleIdx] = device.makeBuffer(length: max(need * 2, 256 * 1024),
                                                    options: .storageModeShared)
        return visibleBufs[visibleIdx]
    }

    /// LSD 基数排序（32 位，两趟 16 位）；≤15 万元素约 0.3ms
    static func radixSort32(_ a: inout [UInt32]) {
        let n = a.count
        guard n > 1 else { return }
        var tmp = [UInt32](unsafeUninitializedCapacity: n) { _, m in m = n }
        var hist = [Int](repeating: 0, count: 65536)
        for pass in 0..<2 {
            let shift = UInt32(pass * 16)
            for i in 0..<65536 { hist[i] = 0 }
            for v in a { hist[Int((v >> shift) & 0xFFFF)] += 1 }
            var sum = 0
            for i in 0..<65536 { let c = hist[i]; hist[i] = sum; sum += c }
            a.withUnsafeBufferPointer { ab in
                tmp.withUnsafeMutableBufferPointer { tb in
                    for i in 0..<n {
                        let v = ab[i]
                        let d = Int((v >> shift) & 0xFFFF)
                        tb[hist[d]] = v
                        hist[d] += 1
                    }
                }
            }
            swap(&a, &tmp)
        }
    }
    private var heatSetupFailed = false

    /// 迷雾清除半径（米）：《世界迷雾》全球格子约 9.5m，走过的走廊取 ~4 格宽
    static let fogRadiusMeters = 40.0

    private func ensureHeatAssets() -> Bool {
        if heatAccumPipeline != nil { return true }
        guard !heatSetupFailed,
              let lib = suppliedLibrary ?? device.makeDefaultLibrary(),
              let av = lib.makeFunction(name: "heatAccumVertex"),
              let af = lib.makeFunction(name: "heatAccumFragment"),
              let qv = lib.makeFunction(name: "heatQuadVertex"),
              let qf = lib.makeFunction(name: "heatColorFragment"),
              let fav = lib.makeFunction(name: "fogSegVertex"),
              let faf = lib.makeFunction(name: "fogSegFragment"),
              let fcf = lib.makeFunction(name: "fogColorFragment"),
              let cwv = lib.makeFunction(name: "fwdbCellVertex"),
              let cwf = lib.makeFunction(name: "fwdbCellFragment") else {
            heatSetupFailed = true
            return false
        }
        // 累积：r16f + 加性混合
        let accum = MTLRenderPipelineDescriptor()
        accum.vertexFunction = av
        accum.fragmentFunction = af
        accum.colorAttachments[0].pixelFormat = .r16Float
        accum.colorAttachments[0].isBlendingEnabled = true
        accum.colorAttachments[0].rgbBlendOperation = .add
        accum.colorAttachments[0].alphaBlendOperation = .add
        accum.colorAttachments[0].sourceRGBBlendFactor = .one
        accum.colorAttachments[0].destinationRGBBlendFactor = .one
        accum.colorAttachments[0].sourceAlphaBlendFactor = .one
        accum.colorAttachments[0].destinationAlphaBlendFactor = .one
        // 合成：常规 alpha 混合到 bgra8
        let color = MTLRenderPipelineDescriptor()
        color.vertexFunction = qv
        color.fragmentFunction = qf
        color.colorAttachments[0].pixelFormat = .bgra8Unorm
        color.colorAttachments[0].isBlendingEnabled = true
        color.colorAttachments[0].rgbBlendOperation = .add
        color.colorAttachments[0].alphaBlendOperation = .add
        color.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        color.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.colorAttachments[0].sourceAlphaBlendFactor = .one
        color.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let ap = try? device.makeRenderPipelineState(descriptor: accum),
              let cp = try? device.makeRenderPipelineState(descriptor: color) else {
            heatSetupFailed = true
            return false
        }
        heatAccumPipeline = ap
        heatColorPipeline = cp
        // 迷雾：累积管线换成"轨迹线段胶囊"顶点/片元（走廊连续不断珠），
        // 合成管线换雾色片元；混合配置与热力一致
        accum.vertexFunction = fav
        accum.fragmentFunction = faf
        color.fragmentFunction = fcf
        guard let fap = try? device.makeRenderPipelineState(descriptor: accum),
              let fcp = try? device.makeRenderPipelineState(descriptor: color) else {
            heatSetupFailed = true
            return false
        }
        fogAccumPipeline = fap
        fogColorPipeline = fcp
        // .fwdb 方格实例（同一张 r16f 遮罩纹理，加性混合）
        accum.vertexFunction = cwv
        accum.fragmentFunction = cwf
        fwdbCellPipeline = try? device.makeRenderPipelineState(descriptor: accum)
        return true
    }

    /// 半分辨率密度纹理（尺寸变化时重建）
    private func ensureHeatTexture(w: Int, h: Int) -> MTLTexture? {
        if let t = heatTexture, t.width == w, t.height == h { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        heatTexture = device.makeTexture(descriptor: d)
        return heatTexture
    }

    /// 帧率 EMA（渲染间隔 < 0.5s 视为连续交互）
    private func tickFPS() {
        let nowT = CACurrentMediaTime()
        if lastFrameTime > 0, nowT - lastFrameTime < 0.5 {
            fpsEMA = fpsEMA * 0.7 + (1.0 / max(nowT - lastFrameTime, 1e-4)) * 0.3
        } else {
            fpsEMA = 0
        }
        lastFrameTime = nowT
    }

    // MARK: - 渲染一帧（平面地图覆盖层）

    func render(layer: CAMetalLayer, camera: CameraRect,
                pointSizePx: Double, opacity: Double, halo: Bool,
                line: LineParams?, highlight: Int?, lodStride: Int = 1,
                range: (start: Int, len: Int)? = nil,
                flashFile: Int32 = -1, flashStrength: Float = 0,
                heatMap: Bool = false, heatSegPx: Double = 0,
                fogMap: Bool = false,
                fogColor: SIMD4<Float> = SIMD4(0.11, 0.13, 0.12, 0.50),
                fogWash: Float = 0.16,
                fogRadiusMeters: Double = MetalPointRenderer.fogRadiusMeters,
                fogFileMask: UInt32 = 0xFFFF_FFFF,
                fogArchiveMode: Bool = false,
                fogArchiveSmooth: Bool = false,
                lodDedupe: Bool = false,
                orderSensitive: Bool = false,
                reveal: Bool = false,
                captureTo: ((MTLTexture) -> Void)? = nil) {
        guard camera.w > 0, camera.h > 0,
              layer.drawableSize.width > 1, layer.drawableSize.height > 1 else { return }

        tickFPS()

        let tWait0 = DispatchTime.now().uptimeNanoseconds
        guard let drawable = layer.nextDrawable(),
              let cmd = queue.makeCommandBuffer() else { return }
        let frameColors = colorBuffers
        frameColors?.retain(untilCompleted: cmd)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let waitMs = Double(t0 - tWait0) / 1e6   // GPU 排满时这里会被反压

        let rStart = max(0, min(range?.start ?? 0, max(pointCount - 1, 0)))
        let rLen = max(0, min(range?.len ?? pointCount, pointCount - rStart))
        let stride = UInt32(max(1, lodStride))
        let drawnPoints = rLen > 0 ? (rLen + Int(stride) - 1) / Int(stride) : 0

        // 视口剔除：莫顿序逐格区段。边距按本帧真正会"伸进视口"的东西取最大：
        // 点半径（闪烁放大 1.55×）+ 描边、热力核半径、迷雾清除半径 + 锚点间距
        //（线段从视口外锚点画进来，间距 ≈ 1.1×半径，再留余量）。时间筛选很窄时
        // 按时间序提交更省（区段不含时间过滤，着色器逐点剔除），两条路径按实例
        // 数取小；视口内没有点时区段为空 → 提交 0 个实例，绝不退回全量时间序
        let pointsPass = !heatMap && !fogMap
        // DeepSeek 2026-11-01：屏幕空间 LOD 选层（选择不粗于当前相机的层）
        var lodIndex = -1
        if pointsPass, !lodLevels.isEmpty {
            for (i, lv) in lodLevels.enumerated() where lv.span <= camera.w * 1.001 { lodIndex = i }
            if lodIndex < 0 { lodIndex = 0 }
        }
        var padPx = pointSizePx * 1.55 + (halo ? 1.1 : 0) + 2.0
        if heatMap { padPx = max(padPx, max(10.0, pointSizePx * 2.5)) }
        var fogPadMerc = 0.0
        if fogMap, !fogArchiveMode {
            let centerMercY = camera.y0 + camera.h / 2
            let lat = atan(sinh(.pi * (1 - 2 * centerMercY)))
            let fr = min(max(fogRadiusMeters, 5.0), 300.0)
            fogPadMerc = fr / (40_075_016.7 * max(cos(lat), 0.05)) * 3.5
        }
        let pad = max(camera.w * 0.02, padPx * camera.w / camera.pxW, fogPadMerc)
        var cellRanges: [Range<Int>] = []
        var spatialTotal = 0
        let indexReady = Self.spatialCullingEnabled && bufOrder != nil && !spatialKeys.isEmpty
            && bufSX != nil && bufSY != nil && frameColors?.spatial != nil
        if indexReady, rLen > 0 {
            cellRanges = SpatialIndex.cellRanges(
                keys: spatialKeys,
                x0: camera.x0 - pad, y0: camera.y0 - pad,
                x1: camera.x0 + camera.w + pad, y1: camera.y0 + camera.h + pad,
                maxCellsAcross: 24).cells
            spatialTotal = cellRanges.reduce(0) { $0 + $1.count }
        }
        let useSpatial = indexReady && rLen > 0 && spatialTotal <= rLen
        let spatialRanges = useSpatial ? SpatialIndex.merge(cellRanges) : []
        // 去重 LOD（点云）：按缩放选格级（格边 ≈ 0.6×目标点距），每格只画
        // 格首点——同一条路反复经过几十次只画一遍，连续性保留。只在：全区间
        //（格首点可能落在时间筛选/回放区间之外，那样整格会消失）、单一来源
        //（多文件时格首点属于哪个文件是任意的，文件闪烁/按文件着色会断续）、
        // 不要求叠放次序、点数 > 6 万、所需格不比最细级更细（街道级画全量）
        var dedupeDraws: [(start: Int, len: Int)] = []
        if useSpatial, pointsPass, lodDedupe, !orderSensitive, flashFile < 0,
           bufFileID == nil, pointCount > 60_000, bufFirsts != nil,
           rStart == 0, rLen == pointCount,
           spatialFirstOffsets.count == SpatialIndex.levels + 1 {
            let spacing = max(1.0, pointSizePx * 1.2)
            let want = log2(camera.pxW / camera.w / (0.6 * spacing))
            if want.isFinite, want <= Double(SpatialIndex.bits) + 0.5 {
                let level = max(0, min(SpatialIndex.bits, Int(want.rounded())))
                let off = spatialFirstOffsets[level], end = spatialFirstOffsets[level + 1]
                spatialFirsts.withUnsafeBufferPointer { fb in
                    let sub = UnsafeBufferPointer(rebasing: fb[off..<end])
                    for rg in spatialRanges {
                        let a = SpatialIndex.lowerBound(sub, UInt32(rg.lowerBound))
                        let b = SpatialIndex.lowerBound(sub, UInt32(rg.upperBound))
                        if b > a { dedupeDraws.append((off + a, b - a)) }
                    }
                }
            }
        }
        let useDedupe = !dedupeDraws.isEmpty
        let spatialInstances = spatialRanges.reduce(0) { $0 + ($1.count + Int(stride) - 1) / Int(stride) }
        // 需要叠放次序（时间/速度/海拔着色、回放、删除灰显、重叠模式）：把视口
        // 内的点收集起来按时间下标排序后提交（时间序抽稀子集 ∩ 视口），绑定
        // 时间序缓冲——与旧路径逐点同序、同混合结果，只是少了视口外的。视口内
        // 点过多时 CPU 排序不划算 → 时间序全量（永不劣于旧路径）
        var orderedList: [UInt32]? = nil
        if lodIndex >= 0, lodIndex < lodLevels.count { orderedList = lodLevels[lodIndex].order }
        if pointsPass, orderSensitive, useSpatial, spatialTotal <= 150_000 {
            var list = [UInt32]()
            list.reserveCapacity(spatialTotal)
            let rEnd = rStart + rLen
            let s = Int(stride)
            spatialOrder.withUnsafeBufferPointer { ob in
                for rg in spatialRanges {
                    for k in rg {
                        let pi = Int(ob[k])
                        if pi >= rStart, pi < rEnd, (pi - rStart) % s == 0 {
                            list.append(UInt32(pi))
                        }
                    }
                }
            }
            Self.radixSort32(&list)
            orderedList = list
        }
        let ordered = orderedList != nil
        var orderedBuf: MTLBuffer?
        if let list = orderedList, !list.isEmpty {
            if lodIndex >= 0, lodIndex < lodBuffers.count {
                orderedBuf = lodBuffers[lodIndex]
            } else if let buf = visibleBuffer(count: list.count) {
                list.withUnsafeBufferPointer {
                    _ = memcpy(buf.contents(), $0.baseAddress!, list.count * MemoryLayout<UInt32>.stride)
                }
                orderedBuf = buf
            }
        }
        let pointsSpatial = useSpatial && (!orderSensitive || ordered)
        var drawnActual: Int
        if pointsPass {
            drawnActual = ordered ? (orderedList?.count ?? 0)
                : (pointsSpatial ? (useDedupe ? dedupeDraws.reduce(0) { $0 + $1.len } : spatialInstances)
                                 : drawnPoints)
        } else {
            drawnActual = useSpatial ? spatialInstances : drawnPoints
        }

        // 相机推导（热力累积 pass 与主 pass 共用）：
        // 经度环绕——把 RTC 中心挪到离可见区中心最近的世界副本
        var cx = center.x
        let viewCx = camera.x0 + camera.w / 2
        while cx - viewCx > 0.5 { cx -= 1.0 }
        while viewCx - cx > 0.5 { cx += 1.0 }
        let uScale = SIMD2<Float>(Float(2.0 / camera.w), Float(-2.0 / camera.h))
        let uOffset = SIMD2<Float>(Float(2.0 * (cx - camera.x0) / camera.w - 1.0),
                                   Float(1.0 - 2.0 * (center.y - camera.y0) / camera.h))

        // --- 0) 热力累积 pass（主 pass 之前：点以高斯核加性撒入半分辨率密度纹理） ---
        var heatReady = false
        if heatMap, pointCount > 0, rLen > 0, ensureHeatAssets(),
           let accumPipe = heatAccumPipeline, let bx = bufX, let by = bufY {
            let hw = max(1, Int(camera.pxW) / 2)
            let hh = max(1, Int(camera.pxH) / 2)
            if let ht = ensureHeatTexture(w: hw, h: hh) {
                let hpass = MTLRenderPassDescriptor()
                hpass.colorAttachments[0].texture = ht
                hpass.colorAttachments[0].loadAction = .clear
                hpass.colorAttachments[0].storeAction = .store
                hpass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                if let henc = cmd.makeRenderCommandEncoder(descriptor: hpass) {
                    let kernelFull = max(10.0, pointSizePx * 2.5)   // 全分辨率核半径
                    var hu = PointUniforms(
                        scale: uScale,
                        offset: uOffset,
                        ndcPerPixel: SIMD2(Float(2.0 / Double(hw)), Float(2.0 / Double(hh))),
                        radiusPx: Float(kernelFull / 2),            // 半分辨率坐标
                        haloPx: 0, alpha: 1, mode: 0,
                        stride: stride,
                        count: UInt32(pointCount),
                        start: UInt32(rStart),
                        rangeLen: UInt32(max(rLen, 1)),
                        pixelMode: 0)
                    henc.setRenderPipelineState(accumPipe)
                    henc.setVertexBuffer(useSpatial ? bufSX! : bx, offset: 0, index: 0)
                    henc.setVertexBuffer(useSpatial ? bufSY! : by, offset: 0, index: 1)
                    henc.setVertexBuffer(bufOrder ?? dummyOrder, offset: 0, index: 7)
                    henc.setVertexBuffer(bufFirsts ?? dummyOrder, offset: 0, index: 8)
                    if useSpatial {
                        hu.useOrder = 1
                        for rg in spatialRanges {
                            hu.orderStart = UInt32(rg.lowerBound)
                            hu.orderLen = UInt32(rg.count)
                            henc.setVertexBytes(&hu, length: MemoryLayout<PointUniforms>.stride, index: 3)
                            henc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                                instanceCount: (rg.count + Int(stride) - 1) / Int(stride))
                        }
                    } else {
                        henc.setVertexBytes(&hu, length: MemoryLayout<PointUniforms>.stride, index: 3)
                        henc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                            instanceCount: drawnPoints)
                    }
                    henc.endEncoding()
                    heatReady = true
                }
            }
        }

        // --- 0b) 迷雾累积 pass（与热力互斥；撒入同一张半分辨率遮罩纹理） ---
        var fogReady = false
        let fogR = min(max(fogRadiusMeters, 5.0), 300.0)
        var fogU = FogUniforms(color: fogColor,
                               params: SIMD4(Float(center.y), Float(fogR),
                                             1.0, fogWash),
                               flags: SIMD4(fogFileMask, 0, 0, 0))
        // 0b-存档：.fwdb 方格实例直接写遮罩（一格不差；实例由协调器按视口缓存）
        if fogMap, fogArchiveMode, !heatReady, ensureHeatAssets(),
           let cellPipe = fwdbCellPipeline {
            let hw = max(1, Int(camera.pxW) / 2)
            let hh = max(1, Int(camera.pxH) / 2)
            if let ht = ensureHeatTexture(w: hw, h: hh) {
                var acx = fogArchiveCenter.x
                while acx - viewCx > 0.5 { acx -= 1.0 }
                while viewCx - acx > 0.5 { acx += 1.0 }
                let aOffset = SIMD2<Float>(Float(2.0 * (acx - camera.x0) / camera.w - 1.0),
                                           Float(1.0 - 2.0 * (fogArchiveCenter.y - camera.y0) / camera.h))
                let hpass = MTLRenderPassDescriptor()
                hpass.colorAttachments[0].texture = ht
                hpass.colorAttachments[0].loadAction = .clear
                hpass.colorAttachments[0].storeAction = .store
                hpass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                if let henc = cmd.makeRenderCommandEncoder(descriptor: hpass) {
                    // 视口内没有已探索格子（实例 0）也要走完：清空遮罩 → 全幅是雾
                    if let ab = fogArchiveBuffer, fogArchiveCount > 0 {
                        var hu = PointUniforms(
                            scale: uScale, offset: aOffset,
                            ndcPerPixel: SIMD2(Float(2.0 / Double(hw)), Float(2.0 / Double(hh))),
                            radiusPx: 0, haloPx: 0, alpha: 1,
                            mode: fogArchiveSmooth ? 1 : 0,
                            stride: 1, count: 1, start: 0, rangeLen: 1, pixelMode: 0)
                        henc.setRenderPipelineState(cellPipe)
                        henc.setVertexBuffer(ab, offset: 0, index: 0)
                        henc.setVertexBytes(&hu, length: MemoryLayout<PointUniforms>.stride, index: 3)
                        henc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                            instanceCount: fogArchiveCount)
                    }
                    drawnActual = (fogArchiveBuffer != nil) ? fogArchiveCount : 0   // 存档格实例数
                    henc.endEncoding()
                    fogReady = true
                }
            }
        }

        if fogMap, !heatReady, !fogReady, pointCount > 0, rLen > 0, ensureHeatAssets(),
           let accumPipe = fogAccumPipeline, let bx = bufX, let by = bufY {
            let hw = max(1, Int(camera.pxW) / 2)
            let hh = max(1, Int(camera.pxH) / 2)
            if let ht = ensureHeatTexture(w: hw, h: hh) {
                // 迷雾自己的抽稀：线段胶囊天然连续，步长只受"路径保真"约束——
                // 相邻绘制点间距 ≤ 0.6×屏幕有效半径（含最小像素钳制）。
                // 近看半径大 → 大步长省掉海量重叠；远看半径钳到 ~2px → 步长
                // 自动放大，绝不会退回全量（旧版在这里逐帧画全量点，GPU 90ms+）
                let centerMercY = camera.y0 + camera.h / 2
                let lat = atan(sinh(.pi * (1 - 2 * centerMercY)))
                let rPxFull = fogR / (40_075_016.7 * max(cos(lat), 0.05))
                             * camera.pxW / camera.w
                let effRadiusPx = max(2.0, rPxFull)          // 全分辨率像素
                var fstride = 1
                if heatSegPx > 1e-4 {
                    // 间距 ≈ 1.1×半径：胶囊相连不会断，转角偏差被走廊宽度吞掉
                    fstride = max(1, min(4096, Int(1.1 * effRadiusPx / heatSegPx)))
                }
                let hpass = MTLRenderPassDescriptor()
                hpass.colorAttachments[0].texture = ht
                hpass.colorAttachments[0].loadAction = .clear
                hpass.colorAttachments[0].storeAction = .store
                hpass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                if let henc = cmd.makeRenderCommandEncoder(descriptor: hpass) {
                    let hu = PointUniforms(
                        scale: uScale,
                        offset: uOffset,
                        ndcPerPixel: SIMD2(Float(2.0 / Double(hw)), Float(2.0 / Double(hh))),
                        radiusPx: 0, haloPx: 0, alpha: 1, mode: 0,
                        stride: UInt32(fstride),
                        count: UInt32(pointCount),
                        start: UInt32(rStart),
                        rangeLen: UInt32(max(rLen, 1)),
                        pixelMode: 0)
                    if let group = encodeFogPaths(henc, command:cmd, pipeline:accumPipe,
                                                  x:bx,y:by,uniforms:hu,fog:fogU) {
                        drawnActual = group.plan.instanceCount
                    }
                    henc.endEncoding()
                    fogReady = true
                }
            }
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        if fogReady, let colorPipe = fogColorPipeline, let ht = heatTexture {
            // 迷雾模式：全屏合成——未探索处画雾，走过区域挖透，边缘亮晕
            enc.setRenderPipelineState(colorPipe)
            enc.setFragmentTexture(ht, index: 0)
            enc.setFragmentBytes(&fogU, length: MemoryLayout<FogUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        } else if heatReady, let colorPipe = heatColorPipeline, let ht = heatTexture {
            // 热力模式：全屏色标合成替代点云/轨迹线。
            // 增益按"单次经过的线密度"归一化：核直径内的抽稀后点数 ≈ 核半径/绘制间距，
            // 让单程轨迹落在蓝绿段、反复经过的路线才升到红——语义与缩放/抽稀无关
            let kernelFull = max(10.0, pointSizePx * 2.5)
            let drawnSeg = max(0.25, heatSegPx * Double(stride))
            let singlePassDensity = max(0.6, kernelFull / drawnSeg)
            var hu = HeatUniforms(gain: Float(0.36 / singlePassDensity),
                                  opacity: Float(min(1.0, opacity + 0.1)))
            enc.setRenderPipelineState(colorPipe)
            enc.setFragmentTexture(ht, index: 0)
            enc.setFragmentBytes(&hu, length: MemoryLayout<HeatUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        } else if pointCount > 0, rLen > 0, let bx = bufX, let by = bufY, let bc = frameColors?.temporal {

            // --- 1) 方向箭头轨迹线（与点云同 stride/区间） ---
            if let lp = line {
                encodeLinePaths(enc,command:cmd,x:bx,y:by,scale:uScale,offset:uOffset,
                                viewport:SIMD2(Float(camera.pxW),Float(camera.pxH)),params:lp,
                                start:rStart,length:rLen,stride:Int(stride))
            }

            // --- 2) 点云（LOD 抽稀 + 时间筛选区间，一次实例化提交） ---
            var u = PointUniforms(
                scale: uScale,
                offset: uOffset,
                ndcPerPixel: SIMD2(Float(2.0 / camera.pxW), Float(2.0 / camera.pxH)),
                radiusPx: Float(pointSizePx),
                haloPx: (halo && pointSizePx >= 3.0) ? 1.1 : 0.0,
                alpha: Float(opacity),
                mode: 0,
                stride: stride,
                count: UInt32(pointCount),
                start: UInt32(rStart),
                rangeLen: UInt32(max(rLen, 1)),
                pixelMode: (reveal && revealAreaBuf != nil && revealCursorBuf != nil) ? 1 : 0,
                flashFile: flashFile,
                flashStrength: flashStrength)

            enc.setRenderPipelineState(pointPipeline)
            if let ab = revealAreaBuf, let tb = revealTimeBuf, let cb = revealCursorBuf {
                enc.setVertexBuffer(ab, offset: 0, index: 9)
                enc.setVertexBuffer(tb, offset: 0, index: 10)
                enc.setVertexBuffer(cb, offset: 0, index: 11)
            } else {
                if dummyUShort == nil { dummyUShort = device.makeBuffer(length: 2, options: .storageModeShared) }
                enc.setVertexBuffer(dummyUShort!, offset: 0, index: 9)
                enc.setVertexBuffer(dummyOrder, offset: 0, index: 10)
                enc.setVertexBuffer(dummyOrder, offset: 0, index: 11)
            }
            enc.setVertexBuffer(bufFileID ?? dummyFileID, offset: 0, index: 4)
            enc.setVertexBuffer(bufOrder ?? dummyOrder, offset: 0, index: 7)
            enc.setVertexBuffer(orderedBuf ?? bufFirsts ?? dummyOrder, offset: 0, index: 8)
            let permutedBound = pointsSpatial && !ordered
            if permutedBound {
                // 空间路径：绑定莫顿序重排副本（顺序读），区段循环提交
                enc.setVertexBuffer(bufSX!, offset: 0, index: 0)
                enc.setVertexBuffer(bufSY!, offset: 0, index: 1)
                enc.setVertexBuffer(frameColors?.spatial!, offset: 0, index: 2)
                u.useOrder = 1
            } else {
                enc.setVertexBuffer(bx, offset: 0, index: 0)
                enc.setVertexBuffer(by, offset: 0, index: 1)
                enc.setVertexBuffer(bc, offset: 0, index: 2)
            }
            // 提交：时间序可见表（需次序）/ 去重 LOD（格首点表子区间）/
            // 空间区段 / 时间序全量 四选一
            do {
                enc.setFragmentBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 0)
                if ordered {
                    let n = orderedList?.count ?? 0
                    if n > 0, orderedBuf != nil {
                        u.useOrder = 3
                        u.stride = 1
                        u.orderStart = 0
                        u.orderLen = UInt32(n)
                        enc.setVertexBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 3)
                        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                           instanceCount: n)
                        u.stride = stride
                    }
                } else if useDedupe {
                    u.useOrder = 2
                    u.stride = 1
                    for d in dedupeDraws {
                        u.orderStart = UInt32(d.start)
                        u.orderLen = UInt32(d.len)
                        enc.setVertexBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 3)
                        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                           instanceCount: d.len)
                    }
                    u.useOrder = 1
                    u.stride = stride
                } else if pointsSpatial {
                    for rg in spatialRanges {
                        u.orderStart = UInt32(rg.lowerBound)
                        u.orderLen = UInt32(rg.count)
                        enc.setVertexBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 3)
                        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                           instanceCount: (rg.count + Int(stride) - 1) / Int(stride))
                    }
                } else {
                    enc.setVertexBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 3)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                       instanceCount: drawnPoints)
                }
            }
            u.useOrder = 0
            if permutedBound {
                enc.setVertexBuffer(bx, offset: 0, index: 0)
                enc.setVertexBuffer(by, offset: 0, index: 1)
                enc.setVertexBuffer(bc, offset: 0, index: 2)
            }

            // --- 3) 悬停/选中高亮环（start=hi + stride=1 精确定位） ---
            if let hi = highlight, hi >= 0, hi < pointCount {
                u.mode = 1
                u.stride = 1
                u.start = UInt32(hi)
                u.rangeLen = 1
                u.pixelMode = 0
                u.flashFile = -1        // 高亮环不参与文件闪烁
                enc.setVertexBuffer(bx, offset: 0, index: 0)
                enc.setVertexBuffer(by, offset: 0, index: 1)
                enc.setVertexBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 3)
                enc.setVertexBuffer(bufFileID ?? dummyFileID, offset: 0, index: 4)
                enc.setFragmentBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: 1)
            }
        }
        enc.endEncoding()

        let encodeMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let base = FrameStats(waitMs: waitMs, encodeMs: encodeMs, gpuMs: 0,
                              drawn: drawnActual, stride: Int(stride), fps: fpsEMA)
        cmd.addCompletedHandler { [weak self] cb in
            var frame = base
            frame.gpuMs = max(0, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
            DispatchQueue.main.async { self?.onFrameStats?(frame) }
        }

        // 导出捕获：不上屏、不阻塞当前线程——GPU 完成回调（后台线程）里交出纹理；
        // 否则与底图逐帧锁定时走事务同步呈现，其余免等待由命令缓冲呈现
        if let captureTo {
            cmd.addCompletedHandler { _ in captureTo(drawable.texture) }
            cmd.commit()
        } else if layer.presentsWithTransaction {
            cmd.commit()
            cmd.waitUntilScheduled()
            drawable.present()
        } else {
            cmd.present(drawable)
            cmd.commit()
        }
    }

    // MARK: - 高清图片导出辅助

    /// 离屏渲染目标（framebufferOnly = false 允许回读）
    static func makeOffscreenLayer(device: MTLDevice, width: Int, height: Int) -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.presentsWithTransaction = false
        layer.drawableSize = CGSize(width: width, height: height)
        return layer
    }

    /// 回读 BGRA 纹理为 CGImage（sRGB，预乘 alpha）
    static func cgImage(from tex: MTLTexture) -> CGImage? {
        let w = tex.width, h = tex.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            tex.getBytes(raw.baseAddress!, bytesPerRow: w * 4,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo.byteOrder32Little.rawValue
                 | CGImageAlphaInfo.premultipliedFirst.rawValue
        return bytes.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: cs, bitmapInfo: info) else { return nil }
            return ctx.makeImage()
        }
    }

    // MARK: - 自绘地球

    /// 懒初始化地球资产：管线、深度状态、UV 球网格、地表纹理。
    /// 首次进入地球视角才付出这一次成本（网格 ~1.9 万顶点，纹理 4096×2048）。
    private func ensureGlobeAssets() -> Bool {
        if globeSpherePipeline != nil { return true }
        guard !globeSetupFailed else { return false }

        guard let lib = suppliedLibrary ?? device.makeDefaultLibrary(),
              let sv = lib.makeFunction(name: "globeSphereVertex"),
              let sf = lib.makeFunction(name: "globeSphereFragment"),
              let pv = lib.makeFunction(name: "globePointVertex"),
              let pf = lib.makeFunction(name: "globePointFragment"),
              let stv = lib.makeFunction(name: "starVertex"),
              let stf = lib.makeFunction(name: "starFragment"),
              let mv = lib.makeFunction(name: "moonVertex"),
              let mf = lib.makeFunction(name: "moonFragment"),
              let ov = lib.makeFunction(name: "orbitVertex"),
              let of = lib.makeFunction(name: "orbitFragment"),
              let pdv = lib.makeFunction(name: "pixelDotVertex"),
              let pcv = lib.makeFunction(name: "pixelCapVertex"),
              let pdf = lib.makeFunction(name: "pixelDotFragment"),
              let cv = lib.makeFunction(name: "columnVertex"),
              let cf = lib.makeFunction(name: "columnFragment"),
              let psf = lib.makeFunction(name: "pixelSphereFragment"),
              let mev = lib.makeFunction(name: "meteorVertex"),
              let mef = lib.makeFunction(name: "meteorFragment") else {
            globeSetupFailed = true
            return false
        }

        func makeGlobePipeline(_ v: MTLFunction, _ f: MTLFunction,
                               blend: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = v
            d.fragmentFunction = f
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.depthAttachmentPixelFormat = .depth32Float
            if blend {
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].rgbBlendOperation = .add
                d.colorAttachments[0].alphaBlendOperation = .add
                d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                d.colorAttachments[0].sourceAlphaBlendFactor = .one
                d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }

        guard let sp = makeGlobePipeline(sv, sf, blend: false),   // 球体不透明
              let pp = makeGlobePipeline(pv, pf, blend: true),
              let stp = makeGlobePipeline(stv, stf, blend: true),
              let mp = makeGlobePipeline(mv, mf, blend: true),
              let op = makeGlobePipeline(ov, of, blend: true) else {
            globeSetupFailed = true
            return false
        }
        globeSpherePipeline = sp
        globePointPipeline = pp
        starPipeline = stp
        moonPipeline = mp
        orbitPipeline = op
        pixelDotPipeline = makeGlobePipeline(pdv, pdf, blend: true)
        pixelCapPipeline = makeGlobePipeline(pcv, pdf, blend: true)
        columnPipeline = makeGlobePipeline(cv, cf, blend: true)
        pixelSpherePipeline = makeGlobePipeline(sv, psf, blend: false)   // 复用球体顶点函数
        meteorPipeline = makeGlobePipeline(mev, mef, blend: true)

        let sphereDS = MTLDepthStencilDescriptor()
        sphereDS.depthCompareFunction = .less
        sphereDS.isDepthWriteEnabled = true
        sphereDepthState = device.makeDepthStencilState(descriptor: sphereDS)
        let pointDS = MTLDepthStencilDescriptor()
        pointDS.depthCompareFunction = .lessEqual
        pointDS.isDepthWriteEnabled = false
        pointDepthState = device.makeDepthStencilState(descriptor: pointDS)
        let bgDS = MTLDepthStencilDescriptor()
        bgDS.depthCompareFunction = .always
        bgDS.isDepthWriteEnabled = false
        bgDepthState = device.makeDepthStencilState(descriptor: bgDS)

        buildSphereMesh()
        buildStars()

        if sphereDepthState == nil || pointDepthState == nil || bgDepthState == nil
            || sphereIB == nil || bufStars == nil {
            globeSpherePipeline = nil    // 保持"已就绪"判定与实际资产一致
            globePointPipeline = nil
            globeSetupFailed = true
            return false
        }
        return true
    }

    /// 星空：固定种子的确定性星表（模型系方向 → 随地球一起旋转）
    private func buildStars() {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func rnd() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float((seed >> 33) & 0xFF_FFFF) / Float(0xFF_FFFF)
        }
        var stars = [StarData]()
        stars.reserveCapacity(1100)
        for _ in 0..<1100 {
            let z = rnd() * 2 - 1
            let t = rnd() * 2 * Float.pi
            let rxy = sqrt(max(0, 1 - z * z))
            let dir = SIMD3<Float>(rxy * cos(t), z, rxy * sin(t))
            let size = 1.3 + pow(rnd(), 2.2) * 3.2        // 1.3~4.5 px，少数大星
            let bright = 0.35 + pow(rnd(), 1.6) * 0.65
            let warm = rnd() * 0.5
            let color = SIMD3<Float>(0.78, 0.85, 1.0) * (1 - warm)
                      + SIMD3<Float>(1.0, 0.93, 0.80) * warm
            stars.append(StarData(a: SIMD4(dir.x, dir.y, dir.z, size),
                                  b: SIMD4(color.x, color.y, color.z, bright)))
        }
        starCount = stars.count
        bufStars = stars.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!,
                              length: $0.count * MemoryLayout<StarData>.stride,
                              options: .storageModeShared)
        }
    }

    /// UV 球：96 纬带 × 192 经带，与等距圆柱纹理一一对应
    private func buildSphereMesh() {
        let R = 96, S = 192
        var pos = [Float](); pos.reserveCapacity((R + 1) * (S + 1) * 3)
        var uv = [Float](); uv.reserveCapacity((R + 1) * (S + 1) * 2)
        for r in 0...R {
            let v = Float(r) / Float(R)
            let lat = Float.pi / 2 - v * .pi          // v=0 → 北极
            let cl = cos(lat), sl = sin(lat)
            for s in 0...S {
                let uu = Float(s) / Float(S)
                let lon = -Float.pi + uu * 2 * .pi    // u=0 → 西经 180°
                pos.append(cl * sin(lon)); pos.append(sl); pos.append(cl * cos(lon))
                uv.append(uu); uv.append(v)
            }
        }
        var idx = [UInt32](); idx.reserveCapacity(R * S * 6)
        let W = UInt32(S + 1)
        for r in 0..<R {
            for s in 0..<S {
                let a = UInt32(r) * W + UInt32(s)
                let b = a + W
                idx.append(a); idx.append(b); idx.append(a + 1)
                idx.append(a + 1); idx.append(b); idx.append(b + 1)
            }
        }
        sphereVB = pos.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count * 4, options: .storageModeShared)
        }
        sphereUVB = uv.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count * 4, options: .storageModeShared)
        }
        sphereIB = idx.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count * 4, options: .storageModeShared)
        }
        sphereIndexCount = idx.count
    }

    /// 地表纹理（应用内置的 Natural Earth 风格化等距圆柱图，深/浅两套外观）
    /// 懒加载：首次用到某套外观才解码那一张
    private func earthTexture(dark: Bool) -> MTLTexture? {
        if dark, let t = earthTexDark { return t }
        if !dark, let t = earthTexLight { return t }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .generateMipmaps: true,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ]
        let name = dark ? "earth_texture" : "earth_texture_light"
        var tex: MTLTexture?
        if let url = Bundle.main.url(forResource: name, withExtension: "png") {
            tex = try? loader.newTexture(URL: url, options: options)
        }
        if tex == nil {
            // 兜底：纯色球（纹理缺失也不至于黑屏）
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                              width: 2, height: 2, mipmapped: false)
            td.usage = .shaderRead
            if let t = device.makeTexture(descriptor: td) {
                var px: [UInt8] = dark
                    ? [34, 22, 11, 255,  34, 22, 11, 255,  34, 22, 11, 255,  34, 22, 11, 255]
                    : [236, 217, 194, 255,  236, 217, 194, 255,  236, 217, 194, 255,  236, 217, 194, 255]
                px.withUnsafeMutableBytes {
                    t.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                              withBytes: $0.baseAddress!, bytesPerRow: 8)
                }
                tex = t
            }
        }
        if dark { earthTexDark = tex } else { earthTexLight = tex }
        return tex
    }

    /// 月面纹理（正面圆盘正交投影，真实月海布局）
    private func moonTex() -> MTLTexture? {
        if let t = moonTexture { return t }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .generateMipmaps: true,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ]
        if let url = Bundle.main.url(forResource: "moon_texture", withExtension: "png"),
           let tex = try? loader.newTexture(URL: url, options: options) {
            moonTexture = tex
            return tex
        }
        // 兜底：均匀灰
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                          width: 2, height: 2, mipmapped: false)
        td.usage = .shaderRead
        if let t = device.makeTexture(descriptor: td) {
            var px: [UInt8] = [200, 200, 205, 255,  200, 200, 205, 255,
                               200, 200, 205, 255,  200, 200, 205, 255]
            px.withUnsafeMutableBytes {
                t.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                          withBytes: $0.baseAddress!, bytesPerRow: 8)
            }
            moonTexture = t
        }
        return moonTexture
    }

    // MARK: 像素地球数据

    var hasPixelTerrain: Bool { bufPixelTerrain != nil }

    func setPixelTerrain(_ dots: [PixelDotData]) {
        terrainCount = dots.count
        guard !dots.isEmpty else { bufPixelTerrain = nil; return }
        bufPixelTerrain = dots.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!,
                              length: $0.count * MemoryLayout<PixelDotData>.stride,
                              options: .storageModeShared)
        }
    }

    func setPixelCells(_ cells: [PixelDotData]) {
        cellCount = cells.count
        guard !cells.isEmpty else { bufPixelCells = nil; return }
        bufPixelCells = cells.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!,
                              length: $0.count * MemoryLayout<PixelDotData>.stride,
                              options: .storageModeShared)
        }
    }

    /// 流星生灭：最多 2 条并存，间隔 2.5~7s 随机生成。
    /// 从画面外一侧进入、斜穿整幅画面、连尾迹一起完全飞出另一侧才消亡。
    private func updateMeteors(now: Double) {
        meteors.removeAll { now - $0.born > $0.dur }
        if now >= nextMeteorAt, meteors.count < 2 {
            var rng = SystemRandomNumberGenerator()
            let fromLeft = Bool.random(using: &rng)
            let start = SIMD2<Float>(fromLeft ? -1.35 : 1.35,
                                     Float.random(in: 0.1...1.30, using: &rng))
            let dir = simd_normalize(SIMD2<Float>(fromLeft ? 1 : -1,
                                                  Float.random(in: -0.85...(-0.35), using: &rng)))
            meteors.append(Meteor(
                born: now,
                dur: Double.random(in: 1.8...2.8, using: &rng),
                p0: start,
                dir: dir,
                travel: 4.8,                     // 保证头与尾都完全离场
                tail: Float.random(in: 0.45...0.70, using: &rng)))
            nextMeteorAt = now + Double.random(in: 2.5...7.0, using: &rng)
        }
    }

    private func ensureDepth(w: Int, h: Int) -> MTLTexture? {
        if let d = depthTex, d.width == w, d.height == h { return d }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                          width: w, height: h, mipmapped: false)
        td.usage = .renderTarget
        td.storageMode = .private
        depthTex = device.makeTexture(descriptor: td)
        return depthTex
    }

    // MARK: 天文（Schlyter 低精度历表，双套独立公式交叉验证过 ~0.2°）

    @inline(__always) private static func sinD(_ x: Double) -> Double { sin(x * .pi / 180) }
    @inline(__always) private static func cosD(_ x: Double) -> Double { cos(x * .pi / 180) }
    @inline(__always) private static func rev(_ x: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// 当前时刻的月球（地固模型系位置 + 轨道环采样）与太阳方向。
    /// 轨道半径压缩到 2.2 球半径（真实 60.3R 在视锥外），椭圆率/倾角/朝向保持真实；
    /// 月球位置对应真实星下点（RA/Dec + GMST → 地固经纬）。
    private static func astro(now: Date, orbitSamples: Int, anomalyOffsetDeg: Double = 0)
        -> (moonPos: SIMD3<Double>, moonDist: Double, sunDir: SIMD3<Double>, orbit: [Float]) {
        let jd = now.timeIntervalSince1970 / 86400.0 + 2440587.5
        let d = jd - 2451543.5
        // 太阳
        let ws = 282.9404 + 4.70935e-5 * d
        let Ms = rev(356.0470 + 0.9856002585 * d)
        let es = 0.016709 - 1.151e-9 * d
        let Es = Ms + (180 / .pi) * es * sinD(Ms) * (1 + es * cosD(Ms))
        let lonSun = rev(atan2(sqrt(1 - es * es) * sinD(Es), cosD(Es) - es) * 180 / .pi + ws)
        let Ls = rev(ws + Ms)
        // 月亮轨道根数
        let N = 125.1228 - 0.0529538083 * d
        let inc = 5.1454
        let w = 318.0634 + 0.1643573223 * d
        let a = 60.2666, ec = 0.054900
        let Mm = rev(115.3654 + 13.0649929509 * d)
        let obl = 23.4393 - 3.563e-7 * d
        let gmst = rev(280.46061837 + 360.98564736629 * (jd - 2451545.0))

        // 摄动后的黄道坐标（M 可扫掠：其余根数冻结 → 轨道环闭合）
        func moonEcl(_ M: Double) -> (lon: Double, lat: Double, r: Double) {
            var E = M + (180 / .pi) * ec * sinD(M) * (1 + ec * cosD(M))
            for _ in 0..<4 { E -= (E - (180 / .pi) * ec * sinD(E) - M) / (1 - ec * cosD(E)) }
            let x = a * (cosD(E) - ec)
            let y = a * sqrt(1 - ec * ec) * sinD(E)
            let v = atan2(y, x) * 180 / .pi
            let r0 = (x * x + y * y).squareRoot()
            let u1 = v + w
            let xh = cosD(N) * cosD(u1) - sinD(N) * sinD(u1) * cosD(inc)
            let yh = sinD(N) * cosD(u1) + cosD(N) * sinD(u1) * cosD(inc)
            let zh = sinD(u1) * sinD(inc)
            var lon = rev(atan2(yh, xh) * 180 / .pi)
            var lat = atan2(zh, (xh * xh + yh * yh).squareRoot()) * 180 / .pi
            let Lm = rev(N + w + M), D = rev(Lm - Ls), F = rev(Lm - N)
            lon += -1.274 * sinD(M - 2*D) + 0.658 * sinD(2*D) - 0.186 * sinD(Ms)
                 - 0.059 * sinD(2*M - 2*D) - 0.057 * sinD(M - 2*D + Ms)
                 + 0.053 * sinD(M + 2*D) + 0.046 * sinD(2*D - Ms) + 0.041 * sinD(M - Ms)
                 - 0.035 * sinD(D) - 0.031 * sinD(M + Ms)
                 - 0.015 * sinD(2*F - 2*D) + 0.011 * sinD(M - 4*D)
            lat += -0.173 * sinD(F - 2*D) - 0.055 * sinD(M - F - 2*D)
                 - 0.046 * sinD(M + F - 2*D) + 0.033 * sinD(F + 2*D) + 0.017 * sinD(2*M + F)
            let r = r0 - 0.58 * cosD(M - 2*D) - 0.46 * cosD(2*D)
            return (rev(lon), lat, r)
        }

        // 黄道 → 赤道 → 地固（GMST）→ 模型系（Y 朝北极，Z 朝 0°N 0°E）
        func earthFixed(lonEcl: Double, latEcl: Double) -> SIMD3<Double> {
            let xe = cosD(lonEcl) * cosD(latEcl)
            let ye = sinD(lonEcl) * cosD(latEcl)
            let ze = sinD(latEcl)
            let yq = ye * cosD(obl) - ze * sinD(obl)
            let zq = ye * sinD(obl) + ze * cosD(obl)
            let ra = rev(atan2(yq, xe) * 180 / .pi)
            let dec = atan2(zq, (xe * xe + yq * yq).squareRoot()) * 180 / .pi
            let lonEF = (ra - gmst) * Double.pi / 180
            let latEF = dec * Double.pi / 180
            return SIMD3(cos(latEF) * sin(lonEF), sin(latEF), cos(latEF) * cos(lonEF))
        }

        let (ml, mb, mr) = moonEcl(rev(Mm + anomalyOffsetDeg))
        let moonPos = earthFixed(lonEcl: ml, latEcl: mb) * (2.2 * mr / a)
        let sunDir = earthFixed(lonEcl: lonSun, latEcl: 0)
        var orbit = [Float]()
        orbit.reserveCapacity((orbitSamples + 1) * 3)
        for k in 0...orbitSamples {
            let (ol, ob, orr) = moonEcl(rev(Mm + Double(k) * 360.0 / Double(orbitSamples)))
            let p = earthFixed(lonEcl: ol, latEcl: ob) * (2.2 * orr / a)
            orbit.append(Float(p.x)); orbit.append(Float(p.y)); orbit.append(Float(p.z))
        }
        return (moonPos, mr, sunDir, orbit)
    }

    /// 渲染一帧自绘地球：星空 → 球体（写深度）→ 月球轨道 → 点云 → 月球 → 高亮环。
    /// 背面元素由深度测试自然遮蔽，CPU 端零剔除、零每帧几何工作。
    /// 背景清成透明：太空黑由下层压暗视图提供，平面 ↔ 地球过渡才能交叉淡化。
    func renderGlobe(layer: CAMetalLayer,
                     yaw: Float, pitch: Float, distance: Float,
                     pointSizePx: Double, opacity: Double, halo: Bool,
                     lodStride: Int, range: (start: Int, len: Int)? = nil,
                     highlight: Int? = nil, darkMode: Bool = true,
                     mapDim: Double = 1.0, demoAnomalyDeg: Double = 0,
                     pixelStyle: Bool = false, fogStyle: Bool = false,
                     flashFile: Int32 = -1, flashStrength: Float = 0,
                     fileMask: UInt32 = 0xFFFF_FFFF,
                     captureTo: ((MTLTexture) -> Void)? = nil) {
        let dw = Int(layer.drawableSize.width)
        let dh = Int(layer.drawableSize.height)
        guard dw > 1, dh > 1, ensureGlobeAssets(),
              let spherePipe = globeSpherePipeline, let pointPipe = globePointPipeline,
              let starPipe = starPipeline, let moonPipe = moonPipeline, let orbitPipe = orbitPipeline,
              let sphereDS = sphereDepthState, let pointDS = pointDepthState, let bgDS = bgDepthState,
              let vb = sphereVB, let uvb = sphereUVB, let ib = sphereIB, let stars = bufStars,
              let tex = earthTexture(dark: darkMode),
              let depth = ensureDepth(w: dw, h: dh) else { return }

        tickFPS()

        let tWait0 = DispatchTime.now().uptimeNanoseconds
        guard let drawable = layer.nextDrawable(),
              let cmd = queue.makeCommandBuffer() else { return }
        let frameColors = colorBuffers
        frameColors?.retain(untilCompleted: cmd)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let waitMs = Double(t0 - tWait0) / 1e6

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1.0
        pass.depthAttachment.storeAction = .dontCare

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        // 相机：模型旋转（pitch·yaw）+ 距离平移 + 透视投影。
        // 远平面涵盖月球轨道（2.2R + 月球半径），近平面尽量贴住球体保深度精度
        let model = Self.rotX(pitch) * Self.rotY(yaw)
        let view = Self.translate(0, 0, -distance)
        let near = max(0.02, distance - 2.6)
        let far = distance + 2.6
        let proj = Self.perspective(fovY: Self.globeFovY, aspect: Float(dw) / Float(dh),
                                    near: near, far: far)
        let mview = view * model

        // 真实月球/太阳（逐帧重算，微秒级；月球随真实时间缓慢移动）
        let sky = Self.astro(now: Date(), orbitSamples: 96, anomalyOffsetDeg: demoAnomalyDeg)
        // 近景淡出：贴近球面看轨迹时月球/轨道退场，不挡视线
        let skyFade = Float(max(0, min(1, (Double(distance) - 2.6) / 0.6)))

        var u = GlobeUniforms(
            mvp: proj * mview,
            modelView: mview,
            moonPosModel: SIMD4(Float(sky.moonPos.x), Float(sky.moonPos.y),
                                Float(sky.moonPos.z), 0.27),
            sunDirModel: SIMD4(Float(sky.sunDir.x), Float(sky.sunDir.y),
                               Float(sky.sunDir.z), skyFade),
            ndcPerPixel: SIMD2(Float(2.0 / Double(dw)), Float(2.0 / Double(dh))),
            projDiag: SIMD2(proj.columns.0.x, proj.columns.1.y),
            radiusPx: Float(pointSizePx),
            haloPx: (halo && pointSizePx >= 3.0) ? 1.1 : 0.0,
            alpha: Float(opacity),
            pointLift: 0.004,
            stride: UInt32(max(1, lodStride)),
            count: UInt32(max(pointCount, 1)),
            start: 0, rangeLen: 0,
            flags: (darkMode ? 0 : 2) | (fogStyle ? 4 : 0) | (bufFileID == nil ? 8 : 0),
            mapDim: Float(min(1, max(0.2, mapDim * (fogStyle ? 0.5 : 1.0)))),
            flashFile: flashFile, flashStrength: flashStrength,
            fileMask: fileMask)
        #if DEBUG
        assert(MemoryLayout<GlobeUniforms>.stride == 240, "GlobeUniforms 布局与 Metal 端不一致")
        assert(MemoryLayout<MeteorUniforms>.stride == 32, "MeteorUniforms 布局与 Metal 端不一致")
        #endif
        let lightBit: UInt32 = darkMode ? 0 : 2

        if pixelStyle {
            // 点阵尺寸随缩放：格距的屏幕投影 × 0.34（radiusPx/haloPx 复用为
            // 点阵直径 / 柱宽的载体——像素模式不画原始点云）
            let pxPerUnit = Double(dh) / 2 / (Double(tan(Self.globeFovY / 2)) * Double(max(distance - 1, 0.15)))
            let spacingPx = PixelGlobe.cellDeg * .pi / 180 * pxPerUnit
            u.radiusPx = Float(min(7.0, max(1.1, spacingPx * 0.34)))
            u.haloPx = Float(min(2.2, max(0.8, spacingPx * 0.14)))   // 数据竖线宽（细线）
            updateMeteors(now: CACurrentMediaTime())
        }

        // --- 0) 星空（最远深度，不写深度，被球体覆盖） ---
        enc.setRenderPipelineState(starPipe)
        enc.setDepthStencilState(bgDS)
        enc.setVertexBuffer(stars, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<GlobeUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                           instanceCount: starCount)

        // --- 0b) 流星（像素模式；背景层，被球身覆盖） ---
        if pixelStyle, let meteorPipe = meteorPipeline, !meteors.isEmpty {
            enc.setRenderPipelineState(meteorPipe)
            enc.setDepthStencilState(bgDS)
            let nowM = CACurrentMediaTime()
            for m in meteors {
                let phase = Float(min(1, max(0, (nowM - m.born) / m.dur)))
                var mu2 = MeteorUniforms(
                    p0: m.p0 + m.dir * m.travel * phase,   // 头部随时间飞行
                    dir: m.dir, lenNdc: m.tail,
                    phase: phase,
                    widthNdcY: 2.2 * Float(2.0 / Double(dh)), pad: 0)
                enc.setVertexBytes(&mu2, length: MemoryLayout<MeteorUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }

        // --- 1) 球体（写实：纹理球；像素：纯色球 + 大气边） ---
        enc.setRenderPipelineState(pixelStyle ? (pixelSpherePipeline ?? spherePipe) : spherePipe)
        enc.setDepthStencilState(sphereDS)
        enc.setVertexBuffer(vb, offset: 0, index: 0)
        enc.setVertexBuffer(uvb, offset: 0, index: 1)
        enc.setVertexBytes(&u, length: MemoryLayout<GlobeUniforms>.stride, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<GlobeUniforms>.stride, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: sphereIndexCount,
                                  indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)

        // --- 2) 月球轨道细线（测深度：绕到球后自然隐没；近景淡出） ---
        if skyFade > 0.01 {
            enc.setRenderPipelineState(orbitPipe)
            enc.setDepthStencilState(pointDS)
            sky.orbit.withUnsafeBufferPointer {
                enc.setVertexBytes($0.baseAddress!, length: $0.count * 4, index: 0)
            }
            enc.setVertexBytes(&u, length: MemoryLayout<GlobeUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<GlobeUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: sky.orbit.count / 3)
        }

        // --- 3a) 像素模式：地形点阵 + 数据柱 ---
        var drawnPoints = 0
        if pixelStyle {
            if let terrain = bufPixelTerrain, terrainCount > 0,
               let dotPipe = pixelDotPipeline {
                enc.setRenderPipelineState(dotPipe)
                enc.setDepthStencilState(pointDS)
                enc.setVertexBuffer(terrain, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<GlobeUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: terrainCount)
            }
            if let cells = bufPixelCells, cellCount > 0, let colPipe = columnPipeline {
                // 纯细竖线，无顶帽（用户指定）
                drawnPoints = cellCount
                enc.setRenderPipelineState(colPipe)
                enc.setDepthStencilState(pointDS)
                enc.setVertexBuffer(cells, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<GlobeUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: cellCount)
            }
        }

        // --- 3b) 写实模式：原始点云（单 draw call 实例化） ---
        let rStart = max(0, min(range?.start ?? 0, max(pointCount - 1, 0)))
        let rLen = max(0, min(range?.len ?? pointCount, pointCount - rStart))
        if !pixelStyle, pointCount > 0, rLen > 0,
           let ux = bufUX, let uy = bufUY, let uz = bufUZ, let bc = frameColors?.temporal, let bl = bufLift {
            let stride = max(1, lodStride)
            drawnPoints = (rLen + stride - 1) / stride
            u.start = UInt32(rStart)
            u.rangeLen = UInt32(rLen)
            enc.setRenderPipelineState(pointPipe)
            enc.setDepthStencilState(pointDS)
            enc.setVertexBuffer(ux, offset: 0, index: 0)
            enc.setVertexBuffer(uy, offset: 0, index: 1)
            enc.setVertexBuffer(uz, offset: 0, index: 2)
            enc.setVertexBuffer(bc, offset: 0, index: 3)
            enc.setVertexBuffer(bl, offset: 0, index: 4)
            enc.setVertexBytes(&u, length: MemoryLayout<GlobeUniforms>.stride, index: 5)
            enc.setVertexBuffer(bufFileID ?? dummyFileID, offset: 0, index: 6)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: drawnPoints)
        }

        // --- 4) 月球（真实位置 + 真实月相的球体冒充；近景淡出） ---
        if skyFade > 0.01, let mtex = moonTex() {
            enc.setRenderPipelineState(moonPipe)
            enc.setDepthStencilState(pointDS)
            enc.setFragmentTexture(mtex, index: 0)
            var mu = u
            mu.flags = lightBit
            enc.setVertexBytes(&mu, length: MemoryLayout<GlobeUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // --- 5) 悬停/选中高亮环（写实模式；start=hi + stride=1 精确定位） ---
        if !pixelStyle, pointCount > 0, let hi = highlight, hi >= 0, hi < pointCount,
           let ux = bufUX, let uy = bufUY, let uz = bufUZ, let bc = frameColors?.temporal, let bl = bufLift {
            u.start = UInt32(hi)
            u.stride = 1
            u.rangeLen = 1
            u.flags = 1 | lightBit
            enc.setRenderPipelineState(pointPipe)
            enc.setDepthStencilState(pointDS)
            enc.setVertexBuffer(ux, offset: 0, index: 0)
            enc.setVertexBuffer(uy, offset: 0, index: 1)
            enc.setVertexBuffer(uz, offset: 0, index: 2)
            enc.setVertexBuffer(bc, offset: 0, index: 3)
            enc.setVertexBuffer(bl, offset: 0, index: 4)
            enc.setVertexBytes(&u, length: MemoryLayout<GlobeUniforms>.stride, index: 5)
            enc.setVertexBuffer(bufFileID ?? dummyFileID, offset: 0, index: 6)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: 1)
        }
        enc.endEncoding()

        let encodeMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let base = FrameStats(waitMs: waitMs, encodeMs: encodeMs, gpuMs: 0,
                              drawn: drawnPoints, stride: max(1, lodStride), fps: fpsEMA)
        cmd.addCompletedHandler { [weak self] cb in
            var frame = base
            frame.gpuMs = max(0, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
            DispatchQueue.main.async { self?.onFrameStats?(frame) }
        }

        // 导出捕获：不上屏、不阻塞当前线程——GPU 完成回调（后台线程）里交出纹理；
        // 否则地球模式下地图隐藏时免事务呈现（省主线程 waitUntilScheduled）
        if let captureTo {
            cmd.addCompletedHandler { _ in captureTo(drawable.texture) }
            cmd.commit()
        } else if layer.presentsWithTransaction {
            cmd.commit()
            cmd.waitUntilScheduled()
            drawable.present()
        } else {
            cmd.present(drawable)
            cmd.commit()
        }
    }

    // MARK: - 3D 热力柱（自绘透视场景：地面贴图 + 实例化方柱，深度测试）

    private var heat3DPipeline: MTLRenderPipelineState?
    private var heat3DGroundPipeline: MTLRenderPipelineState?
    private var heat3DDepthState: MTLDepthStencilState?
    private var heat3DSetupFailed = false
    private var bufHeat3D: MTLBuffer?
    private(set) var heat3DCount = 0
    private var heat3DGroundTex: MTLTexture?
    private var heat3DGroundRect = SIMD4<Float>(-1.2, -1.2, 1.2, 1.2)

    /// 与 Shaders.metal 中 Heat3DUniforms 逐字段对齐（96 B）
    private struct Heat3DUniforms {
        var mvp: simd_float4x4
        var light: SIMD4<Float>    // xyz 方向光，w 环境
        var params: SIMD4<Float>   // x 平滑，y 地面亮度，z 备用，w 备用
    }

    private var heat3DChunks: [Heat3DChunk] = []
    private var heat3DBlockHalf: Float = 0

    func setHeat3D(scene: Heat3DScene?) {
        guard let sc = scene, !sc.instances.isEmpty else {
            heat3DCount = 0
            bufHeat3D = nil
            heat3DChunks = []
            return
        }
        heat3DCount = sc.count
        heat3DChunks = sc.chunks
        heat3DBlockHalf = sc.blockHalf
        bufHeat3D = sc.instances.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!, length: sc.instances.count * 4,
                              options: .storageModeShared)
        }
    }

    func setHeat3DGround(texture: MTLTexture?, rect: SIMD4<Float>) {
        heat3DGroundTex = texture
        heat3DGroundRect = rect
    }

    // 本地高清地面层：相机贴近时对当前脚下区域单独截图（整景快照放大后会糊）
    private var heat3DLocalTex: MTLTexture?
    private var heat3DLocalRect = SIMD4<Float>(0, 0, 0, 0)

    func setHeat3DLocalGround(texture: MTLTexture?, rect: SIMD4<Float>) {
        heat3DLocalTex = texture
        heat3DLocalRect = rect
    }

    /// 地面贴图未就绪时的纯色补位（跟随外观）
    private func fallbackGround(dark: Bool) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                          width: 1, height: 1, mipmapped: false)
        td.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: td) else { return nil }
        var px: [UInt8] = dark ? [46, 40, 34, 255] : [214, 219, 222, 255]   // BGRA
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                  withBytes: &px, bytesPerRow: 4)
        return t
    }
    private lazy var groundFallbackDark: MTLTexture? = fallbackGround(dark: true)
    private lazy var groundFallbackLight: MTLTexture? = fallbackGround(dark: false)

    private func ensureHeat3DAssets() -> Bool {
        if heat3DPipeline != nil { return true }
        if heat3DSetupFailed { return false }
        guard let lib = suppliedLibrary ?? device.makeDefaultLibrary(),
              let bv = lib.makeFunction(name: "heat3DBlockVertex"),
              let bf = lib.makeFunction(name: "heat3DBlockFragment"),
              let gv = lib.makeFunction(name: "heat3DGroundVertex"),
              let gf = lib.makeFunction(name: "heat3DGroundFragment") else {
            heat3DSetupFailed = true
            return false
        }
        func make(_ v: MTLFunction, _ f: MTLFunction) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = v
            d.fragmentFunction = f
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.depthAttachmentPixelFormat = .depth32Float
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        heat3DPipeline = make(bv, bf)
        heat3DGroundPipeline = make(gv, gf)
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled = true
        heat3DDepthState = device.makeDepthStencilState(descriptor: ds)
        if heat3DPipeline == nil || heat3DGroundPipeline == nil || heat3DDepthState == nil {
            heat3DSetupFailed = true
            return false
        }
        return true
    }

    /// 3D 热力柱场景：轨道相机（yaw/pitch/dist + 地面平移 target），
    /// 地面贴图（底图截图）+ 单 draw call 实例化方柱
    func renderHeat3D(layer: CAMetalLayer,
                      yaw: Float, pitch: Float, dist: Float,
                      target: SIMD2<Float>,
                      smooth: Bool, dark: Bool,
                      captureTo: ((MTLTexture) -> Void)? = nil) {
        let dw = Int(layer.drawableSize.width)
        let dh = Int(layer.drawableSize.height)
        guard dw > 1, dh > 1, ensureHeat3DAssets(),
              let blockPipe = heat3DPipeline, let groundPipe = heat3DGroundPipeline,
              let ds = heat3DDepthState,
              let depth = ensureDepth(w: dw, h: dh) else { return }

        tickFPS()
        let tWait0 = DispatchTime.now().uptimeNanoseconds
        guard let drawable = layer.nextDrawable(),
              let cmd = queue.makeCommandBuffer() else { return }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let waitMs = Double(t0 - tWait0) / 1e6

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = dark
            ? MTLClearColor(red: 0.055, green: 0.065, blue: 0.085, alpha: 1)
            : MTLClearColor(red: 0.88, green: 0.90, blue: 0.92, alpha: 1)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1.0
        pass.depthAttachment.storeAction = .dontCare
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        let view = Self.translate(0, 0, -dist)
                 * Self.rotX(pitch)
                 * Self.rotY(yaw)
                 * Self.translate(-target.x, 0, -target.y)
        // 近/远平面随距离缩放：大洲级数据聚焦到城市时 dist 可低至 1e-4
        let proj = Self.perspective(fovY: 0.72, aspect: Float(dw) / Float(dh),
                                    near: max(1e-5, dist * 0.05), far: dist * 40 + 8.0)
        var u = Heat3DUniforms(
            mvp: proj * view,
            light: SIMD4(0.37, 0.82, 0.44, 0.42),
            // z = 半屏像素 × 投影 y 缩放：顶点着色器估算块的屏幕尺寸做 LOD
            params: SIMD4(smooth ? 1 : 0, dark ? 0.92 : 1.0,
                          proj.columns.1.y * Float(dh) * 0.5, 0))

        // 兜底大地面（中性色，比主地面低半块）：拉远/平移视野里永远有地
        var baseRect = SIMD4<Float>(-9, -9, 9, 9)
        var bu = u
        bu.params.w = -max(1e-6, heat3DBlockHalf * 0.5)
        enc.setRenderPipelineState(groundPipe)
        enc.setDepthStencilState(ds)
        enc.setVertexBytes(&bu, length: MemoryLayout<Heat3DUniforms>.stride, index: 1)
        enc.setVertexBytes(&baseRect, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        enc.setFragmentBytes(&bu, length: MemoryLayout<Heat3DUniforms>.stride, index: 1)
        enc.setFragmentTexture(dark ? groundFallbackDark : groundFallbackLight, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // 地面（深度写入，方柱贴地不穿插）；本地高清层微抬叠加
        var rect = heat3DGroundRect
        enc.setVertexBytes(&u, length: MemoryLayout<Heat3DUniforms>.stride, index: 1)
        enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<Heat3DUniforms>.stride, index: 1)
        enc.setFragmentTexture(heat3DGroundTex
                               ?? (dark ? groundFallbackDark : groundFallbackLight), index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        if let lt = heat3DLocalTex, heat3DLocalRect.z > heat3DLocalRect.x {
            var lu = u
            // 抬升量随块尺度走：固定 0.0006 在大跨度场景会高过所有柱体，
            // 深度测试把整片柱子吞进地面（最矮柱 ≈ 数倍块半宽，0.15×半宽必在其下）
            lu.params.w = max(1e-7, heat3DBlockHalf * 0.15)
            var lrect = heat3DLocalRect
            enc.setVertexBytes(&lu, length: MemoryLayout<Heat3DUniforms>.stride, index: 1)
            enc.setVertexBytes(&lrect, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            enc.setFragmentBytes(&lu, length: MemoryLayout<Heat3DUniforms>.stride, index: 1)
            enc.setFragmentTexture(lt, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.setVertexBytes(&u, length: MemoryLayout<Heat3DUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Heat3DUniforms>.stride, index: 1)
        }

        // 方柱：逐 chunk 视锥剔除 + 分级绘制——视锥外整块跳过；
        // 块投影 <0.7px 的 chunk 只画顶面（6 顶点），近处画完整方柱（30 顶点）。
        // 百万块的大数据下顶点量降一个数量级，交互不掉帧
        var drawn = 0
        if let bb = bufHeat3D, heat3DCount > 0 {
            enc.setRenderPipelineState(blockPipe)
            enc.setVertexBuffer(bb, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Heat3DUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Heat3DUniforms>.stride, index: 1)
            let mvp = u.mvp
            let pxScale = u.params.z
            // 眼睛世界坐标（view = T(0,0,-d)·rotX(p)·rotY(y)·T(-t) 的逆推）
            let eye = SIMD3<Float>(target.x - dist * sin(yaw) * cos(pitch),
                                   dist * sin(pitch),
                                   target.y + dist * cos(yaw) * cos(pitch))
            for c in heat3DChunks {
                // AABB 8 角点裁剪空间测试（y ∈ [0, maxH]）
                var allL = true, allR = true, allB = true, allT = true, allN = true
                for ci in 0..<8 {
                    let px = (ci & 1) != 0 ? c.maxX : c.minX
                    let pz = (ci & 2) != 0 ? c.maxZ : c.minZ
                    let py = (ci & 4) != 0 ? c.maxH : 0
                    let cp = mvp * SIMD4<Float>(px, py, pz, 1)
                    let w = cp.w
                    if cp.x >= -w * 1.02 { allL = false }
                    if cp.x <=  w * 1.02 { allR = false }
                    if cp.y >= -w * 1.02 { allB = false }
                    if cp.y <=  w * 1.02 { allT = false }
                    if w > 0 { allN = false }
                }
                if allL || allR || allB || allT || allN { continue }
                // 几何级别按眼睛到 chunk AABB 最近点的距离：大洲级 chunk 的
                // 角点可能在数百 km 外，按角点算会把眼前的块也降级成悬空顶面
                let nx = min(max(eye.x, c.minX), c.maxX)
                let ny = min(max(eye.y, 0), c.maxH)
                let nz = min(max(eye.z, c.minZ), c.maxZ)
                let nearD = simd_distance(eye, SIMD3(nx, ny, nz))
                let pxHalf = heat3DBlockHalf * pxScale / max(nearD, 1e-6)
                let verts = pxHalf < 0.7 ? 12 : 36     // 顶面扇 12 / 全几何 36
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts,
                                   instanceCount: Int(c.count), baseInstance: Int(c.start))
                drawn += Int(c.count)
            }
        }
        enc.endEncoding()

        let encodeMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let base = FrameStats(waitMs: waitMs, encodeMs: encodeMs, gpuMs: 0,
                              drawn: drawn, stride: 1, fps: fpsEMA)
        cmd.addCompletedHandler { [weak self] cb in
            var frame = base
            frame.gpuMs = max(0, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
            DispatchQueue.main.async { self?.onFrameStats?(frame) }
        }
        if let captureTo {
            cmd.addCompletedHandler { _ in captureTo(drawable.texture) }
            cmd.commit()
        } else if layer.presentsWithTransaction {
            cmd.commit()
            cmd.waitUntilScheduled()
            drawable.present()
        } else {
            cmd.present(drawable)
            cmd.commit()
        }
    }

    // MARK: 矩阵工具（列主序，右手系，NDC 深度 [0,1]）

    private static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tan(fovY / 2)
        let xs = ys / aspect
        let zs = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, zs * near, 0)))
    }

    private static func rotX(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, c, s, 0),
            SIMD4<Float>(0, -s, c, 0),
            SIMD4<Float>(0, 0, 0, 1)))
    }

    private static func rotY(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1)))
    }

    private static func translate(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(x, y, z, 1)
        return m
    }
}

#if GPXPV_METAL_COLOR_TESTS
extension MetalPointRenderer {
    var testingColors: PointColorBuffers? { colorBuffers }
    func testingAdopt(_ group: PointColorBuffers, count: Int, order: [UInt32]) {
        colorBuffers = group; pointCount = count; spatialOrder = order
    }
}
#endif

#if GPXPV_SEGMENT_RENDER_TESTS
extension MetalPointRenderer {
    func testingPlan(kind: PathDrawKind, start: Int, length: Int, stride: Int,
                     softBreaks: Bool = true) -> PathGPUPlan? {
        pathPlan(kind:kind,start:start,length:length,stride:stride,softBreaks:softBreaks)
    }
    func testingRenderPaths(texture: MTLTexture, kind: PathDrawKind, start: Int, length: Int,
                            stride: Int, scale: SIMD2<Float>, offset: SIMD2<Float> = .zero,
                            fileMask: UInt32 = 0xFFFF_FFFF, radiusMeters: Float = 5,
                            centerMercY: Float = 0.5, softBreaks: Bool = true,
                            waitEvent: MTLSharedEvent? = nil) -> MTLCommandBuffer? {
        guard let command = queue.makeCommandBuffer(), let x = bufX, let y = bufY else { return nil }
        if let waitEvent { command.encodeWaitForEvent(waitEvent,value:1) }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture; pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor:pass) else { return nil }
        switch kind {
        case .line:
            let params = LineParams(widthPx:3,headLenPx:8,headWidthPx:6,color:SIMD4(1,1,1,1),
                                    arrows:false,cullBreaks:softBreaks,fileMask:fileMask)
            encodeLinePaths(encoder,command:command,x:x,y:y,scale:scale,offset:offset,
                viewport:SIMD2(Float(texture.width),Float(texture.height)),params:params,
                start:start,length:length,stride:stride)
        case .fog:
            guard ensureHeatAssets(), let pipeline = fogAccumPipeline else { encoder.endEncoding(); return nil }
            let u = PointUniforms(scale:scale,offset:offset,
                ndcPerPixel:SIMD2(2/Float(texture.width),2/Float(texture.height)),
                radiusPx:0,haloPx:0,alpha:1,mode:0,stride:UInt32(clamping:max(1,stride)),count:UInt32(pointCount),
                start:UInt32(start),rangeLen:UInt32(length),pixelMode:0)
            let f = FogUniforms(color:SIMD4(0,0,0,1),params:SIMD4(centerMercY,radiusMeters,1,0),flags:SIMD4(fileMask,0,0,0))
            encodeFogPaths(encoder,command:command,pipeline:pipeline,x:x,y:y,uniforms:u,fog:f)
        }
        encoder.endEncoding(); command.commit(); return command
    }
}
#endif

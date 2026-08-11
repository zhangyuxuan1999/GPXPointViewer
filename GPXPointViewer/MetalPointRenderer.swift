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
//    直接读点位 SoA 缓冲（第 i 段 = 点 i → 点 i+1），方向/法线/箭头张角
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
}

/// 与 Shaders.metal 中 LineUniforms 逐字段对齐（size 80，align 16）
struct LineUniforms {
    var scale: SIMD2<Float>
    var offset: SIMD2<Float>
    var viewportPx: SIMD2<Float>
    var _pad: SIMD2<Float>
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

    init?(device: MTLDevice, track: TrackData) {
        let n = track.count
        guard n > 0 else { return nil }
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
    }
}

final class MetalPointRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pointPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState

    private var bufX: MTLBuffer?
    private var bufY: MTLBuffer?
    private var bufColor: MTLBuffer?
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
    /// fileID 缓冲的占位（着色器要求绑定存在；flashFile = -1 时不会被读取）
    private lazy var dummyFileID: MTLBuffer? =
        device.makeBuffer(length: 2, options: .storageModeShared)
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
    static func buildBuffers(track: TrackData) -> TrackGPUBuffers? {
        guard let dev = sharedDevice else { return nil }
        return TrackGPUBuffers(device: dev, track: track)
    }

    init?() {
        guard let dev = Self.sharedDevice,
              let q = dev.makeCommandQueue(),
              let lib = dev.makeDefaultLibrary(),
              let pointV = lib.makeFunction(name: "pointVertex"),
              let pointF = lib.makeFunction(name: "pointFragment"),
              let lineV = lib.makeFunction(name: "segmentVertex"),
              let lineF = lib.makeFunction(name: "segmentFragment") else { return nil }
        device = dev
        queue = q

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
    }

    // MARK: - 数据上传

    func setData(track: TrackData) {
        pointCount = track.count
        center = track.center
        let n = track.count
        guard n > 0 else { clearData(); return }
        if let g = track.gpuBuffers {
            // 领养后台预建缓冲：主线程零 memcpy。
            // 交接安全：setData 与 draw 全在主线程，已提交的命令缓冲
            // 持有旧 MTLBuffer 至 GPU 完成，属性交换天然原子
            bufX = g.x; bufY = g.y
            bufUX = g.ux; bufUY = g.uy; bufUZ = g.uz
            bufLift = g.lift
            bufColor = g.color
            bufFileID = g.fileID
            track.gpuBuffers = nil   // 一次性交接（再次 setData 走兜底拷贝）
            return
        }
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
        bufColor = track.colors.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!, length: n * 4, options: .storageModeShared)
        }
        bufFileID = track.fileID.isEmpty ? nil : track.fileID.withUnsafeBufferPointer {
            device.makeBuffer(bytes: $0.baseAddress!,
                              length: n * MemoryLayout<UInt16>.stride,
                              options: .storageModeShared)
        }
    }

    func clearData() {
        pointCount = 0
        bufX = nil; bufY = nil; bufColor = nil
        bufUX = nil; bufUY = nil; bufUZ = nil; bufLift = nil
        bufFileID = nil
    }

    func updateColors(_ colors: [UInt8]) {
        guard let buf = bufColor, pointCount > 0, colors.count == pointCount * 4 else { return }
        colors.withUnsafeBufferPointer { src in
            _ = memcpy(buf.contents(), src.baseAddress!, src.count)
        }
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
                flashFile: Int32 = -1, flashStrength: Float = 0) {
        guard camera.w > 0, camera.h > 0,
              layer.drawableSize.width > 1, layer.drawableSize.height > 1 else { return }

        tickFPS()

        let tWait0 = DispatchTime.now().uptimeNanoseconds
        guard let drawable = layer.nextDrawable(),
              let cmd = queue.makeCommandBuffer() else { return }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let waitMs = Double(t0 - tWait0) / 1e6   // GPU 排满时这里会被反压

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        let rStart = max(0, min(range?.start ?? 0, max(pointCount - 1, 0)))
        let rLen = max(0, min(range?.len ?? pointCount, pointCount - rStart))
        let stride = UInt32(max(1, lodStride))
        let drawnPoints = rLen > 0 ? (rLen + Int(stride) - 1) / Int(stride) : 0

        if pointCount > 0, rLen > 0, let bx = bufX, let by = bufY, let bc = bufColor {
            // 经度环绕：把 RTC 中心挪到离可见区中心最近的世界副本
            var cx = center.x
            let viewCx = camera.x0 + camera.w / 2
            while cx - viewCx > 0.5 { cx -= 1.0 }
            while viewCx - cx > 0.5 { cx += 1.0 }

            let uScale = SIMD2<Float>(Float(2.0 / camera.w), Float(-2.0 / camera.h))
            let uOffset = SIMD2<Float>(Float(2.0 * (cx - camera.x0) / camera.w - 1.0),
                                       Float(1.0 - 2.0 * (center.y - camera.y0) / camera.h))

            // --- 1) 方向箭头轨迹线（与点云同 stride/区间） ---
            if let lp = line, drawnPoints >= 2 {
                var lu = LineUniforms(
                    scale: uScale,
                    offset: uOffset,
                    viewportPx: SIMD2(Float(camera.pxW), Float(camera.pxH)),
                    _pad: .zero,
                    color: lp.color,
                    widthPx: lp.widthPx,
                    headLenPx: lp.arrows ? lp.headLenPx : 0,
                    headWidthPx: lp.headWidthPx,
                    isHead: 0,
                    stride: stride,
                    count: UInt32(pointCount),
                    start: UInt32(rStart),
                    rangeLen: UInt32(rLen))

                enc.setRenderPipelineState(linePipeline)
                enc.setVertexBuffer(bx, offset: 0, index: 0)
                enc.setVertexBuffer(by, offset: 0, index: 1)
                enc.setVertexBytes(&lu, length: MemoryLayout<LineUniforms>.stride, index: 2)
                enc.setFragmentBytes(&lu, length: MemoryLayout<LineUniforms>.stride, index: 0)
                // 箭杆：一次实例化提交
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: drawnPoints - 1)
                if lp.arrows {
                    lu.isHead = 1
                    enc.setVertexBytes(&lu, length: MemoryLayout<LineUniforms>.stride, index: 2)
                    enc.setFragmentBytes(&lu, length: MemoryLayout<LineUniforms>.stride, index: 0)
                    // 箭头：一次实例化提交
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3,
                                       instanceCount: drawnPoints - 1)
                }
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
                pixelMode: 0,
                flashFile: flashFile,
                flashStrength: flashStrength)

            enc.setRenderPipelineState(pointPipeline)
            enc.setVertexBuffer(bx, offset: 0, index: 0)
            enc.setVertexBuffer(by, offset: 0, index: 1)
            enc.setVertexBuffer(bc, offset: 0, index: 2)
            enc.setVertexBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 3)
            enc.setVertexBuffer(bufFileID ?? dummyFileID, offset: 0, index: 4)
            enc.setFragmentBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: drawnPoints)

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
                              drawn: drawnPoints, stride: Int(stride), fps: fpsEMA)
        cmd.addCompletedHandler { [weak self] cb in
            var frame = base
            frame.gpuMs = max(0, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
            DispatchQueue.main.async { self?.onFrameStats?(frame) }
        }

        // 与底图逐帧锁定时走事务同步呈现；否则免等待直接由命令缓冲呈现
        if layer.presentsWithTransaction {
            cmd.commit()
            cmd.waitUntilScheduled()
            drawable.present()
        } else {
            cmd.present(drawable)
            cmd.commit()
        }
    }

    // MARK: - 自绘地球

    /// 懒初始化地球资产：管线、深度状态、UV 球网格、地表纹理。
    /// 首次进入地球视角才付出这一次成本（网格 ~1.9 万顶点，纹理 4096×2048）。
    private func ensureGlobeAssets() -> Bool {
        if globeSpherePipeline != nil { return true }
        guard !globeSetupFailed else { return false }

        guard let lib = device.makeDefaultLibrary(),
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
                     pixelStyle: Bool = false,
                     flashFile: Int32 = -1, flashStrength: Float = 0) {
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
            flags: darkMode ? 0 : 2,
            mapDim: Float(min(1, max(0.2, mapDim))),
            flashFile: flashFile, flashStrength: flashStrength)
        #if DEBUG
        assert(MemoryLayout<GlobeUniforms>.stride == 224, "GlobeUniforms 布局与 Metal 端不一致")
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
           let ux = bufUX, let uy = bufUY, let uz = bufUZ, let bc = bufColor, let bl = bufLift {
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
           let ux = bufUX, let uy = bufUY, let uz = bufUZ, let bc = bufColor, let bl = bufLift {
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

        // 地球模式下地图隐藏时免事务呈现（省主线程 waitUntilScheduled）
        if layer.presentsWithTransaction {
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

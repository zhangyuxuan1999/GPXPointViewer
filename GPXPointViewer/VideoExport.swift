//
//  VideoExport.swift
//  GPXPointViewer
//
//  时光机回放 → 视频文件（H.264 .mp4）。完全离屏、确定性逐帧渲染：
//    1. 按回放规划把时间线切成"场景"（驻留 = 簇取景、飞行 = 包络取景），
//       每场景取一张 MKMapSnapshotter 底图（并行预取，数字变焦复用）；
//    2. 逐帧：规划相机 → 底图裁剪缩放（就近选最清晰的场景快照，切换时
//       0.3s 交叉淡化）→ 独立渲染器离屏画点云/热力/迷雾揭示层 → 合成
//       时间轴丝带（日期 + 进度）→ 写入 AVAssetWriter 像素缓冲池。
//  与实时回放共用同一 PlaybackPlan——所见即所得。
//

import Foundation
import AVFoundation
import CoreText
import MapKit
import AppKit
import simd

struct VideoExportOptions {
    var pixelWidth: Int = 1920      // 1920 / 3840
    var fps: Int = 30
}

/// 主线程收集的导出配置快照（引擎全程后台，不回读可变状态）
struct VideoExportConfig: @unchecked Sendable {
    var plan: PlaybackPlan
    var track: TrackData?
    var archive: FogArchive?
    var url: URL
    var outW: Int
    var outH: Int
    var fps: Int
    var dark: Bool
    var mapStyle: BaseMapStyle
    var appearance: NSAppearance?
    var mapOpacity: Double
    var pointSizePx: Double         // 已含缩放因子
    var opacity: Double
    var halo: Bool
    var heatMap: Bool
    var fogMap: Bool
    var fogColor: SIMD4<Float>
    var fogWash: Float
    var fogRadiusMeters: Double
    var fogFileMask: UInt32
    var fogSmooth: Bool
    var medianSegMerc: Double
    var rangeStart: Int             // 时间筛选窗（回放在其内揭示）
    var rangeLen: Int
    var line: LineParams?           // 轨迹线样式（与实时回放一致，所见即所得）
}

enum VideoExportEngine {

    /// 调试钩子（离屏 harness 用）
    nonisolated(unsafe) static var debug: (@Sendable (String) -> Void)?

    private struct Scene {
        var x0: Double, y0: Double, x1: Double, y1: Double   // 归一化墨卡托
        var image: CGImage?
    }

    /// 全程后台执行；progress ∈ [0,1]；完成回调传出错误描述（nil = 成功）
    static func run(cfg: VideoExportConfig,
                    progress: @escaping @Sendable (Double) -> Void,
                    done: @escaping @Sendable (String?) -> Void) {
        // —— 1) 场景表 ——
        let aspect = Double(cfg.outH) / Double(cfg.outW)
        var scenes: [Scene] = []
        for seg in cfg.plan.segments {
            // 包络采样（驻留段的子相机同样会移动，统一取相机路径外接框）
            let samples = seg.from == seg.to ? 24 : 12
            var x0 = Double.infinity, x1 = -Double.infinity
            var y0 = Double.infinity, y1 = -Double.infinity
            for i in 0...samples {
                let p = seg.p0 + (seg.p1 - seg.p0) * Double(i) / Double(samples)
                let cam = cfg.plan.camera(at: p, aspect: aspect)
                x0 = min(x0, cam.cx - cam.span / 2); x1 = max(x1, cam.cx + cam.span / 2)
                y0 = min(y0, cam.cy - cam.span * aspect / 2)
                y1 = max(y1, cam.cy + cam.span * aspect / 2)
            }
            let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
            let span = max(x1 - x0, (y1 - y0) / aspect) * (seg.from == seg.to ? 1.25 : 1.15)
            scenes.append(scene(cx: cx, cy: cy, span: span, aspect: aspect))
            // 驻留段的子活动区各补一张贴身快照——包络快照数字变焦几十倍会糊，
            // 源选择按"包含相机的最小跨度"自动挑中它们
            if seg.from == seg.to {
                let subs = cfg.plan.clusters[seg.from].subs
                if !subs.isEmpty, subs.count <= 16 {
                    for sub in subs {
                        let pm = seg.p0 + (seg.p1 - seg.p0) * (sub.f0 + sub.f1) / 2
                        let cam = cfg.plan.camera(at: pm, aspect: aspect)
                        scenes.append(scene(cx: cam.cx, cy: cam.cy,
                                            span: cam.span * 1.45, aspect: aspect))
                    }
                }
            }
        }

        // —— 2) 并行预取快照（信号量限 4 并发）——
        let group = DispatchGroup()
        let sem = DispatchSemaphore(value: 4)
        let lock = NSLock()
        var fetched = 0
        for i in 0..<scenes.count {
            group.enter()
            sem.wait()
            let sc = scenes[i]
            let world = MKMapRect.world.size.width
            let opts = MKMapSnapshotter.Options()
            opts.mapRect = MKMapRect(x: sc.x0 * world, y: sc.y0 * world,
                                     width: (sc.x1 - sc.x0) * world,
                                     height: (sc.y1 - sc.y0) * world)
            // 快照尺寸按"点"请求，Retina 下返回 2x 像素——预算与质量都按 2x 计：
            // 质量下限 outW/2 点（≈ outW 像素），总驻留预算 ~500MB（像素 4B）
            let aspectSc = (sc.y1 - sc.y0) / (sc.x1 - sc.x0)
            let budgetW = (500_000_000.0 / 16.0 / Double(scenes.count) / aspectSc).squareRoot()
            let w = min(2400.0, Double(cfg.outW) * 0.75,
                        max(Double(cfg.outW) * 0.5, budgetW))
            opts.size = CGSize(width: w, height: w * aspectSc)
            opts.preferredConfiguration = cfg.mapStyle.appleConfiguration(elevation: .flat)   // 快照不画瓦片 overlay：外部底图退到 Apple 替代
            if let ap = cfg.appearance { opts.appearance = ap }
            MKMapSnapshotter(options: opts).start(with: .global(qos: .userInitiated)) { snapshot, _ in
                if let img = snapshot?.image {
                    var prop = CGRect(origin: .zero, size: img.size)
                    let cg = img.cgImage(forProposedRect: &prop, context: nil, hints: nil)
                    lock.lock()
                    scenes[i].image = cg
                    fetched += 1
                    let f = fetched
                    lock.unlock()
                    progress(0.18 * Double(f) / Double(scenes.count))
                } else {
                    lock.lock(); fetched += 1; lock.unlock()
                }
                sem.signal()
                group.leave()
            }
        }
        group.wait()
        debug?("场景 \(scenes.count) 个，快照成功 \(scenes.filter { $0.image != nil }.count) 个")

        // —— 3) 独立渲染器（与实时渲染零共享）——
        guard let renderer = MetalPointRenderer() else {
            done(String(localized: "Metal 渲染器初始化失败", comment: "Video export error detail, shown after 视频导出失败：: the offscreen Metal renderer could not be created")); return
        }
        if let track = cfg.track {
            renderer.setData(track: track)
            // DeepSeek 2026-10-31：城市章节回放的逐点区域数据（一次上传）
            if let cp = cfg.plan.cityPlan, let rv = PlaybackRevealData(track: track, plan: cp) {
                renderer.setPlaybackReveal(areas: rv.areaOfPoint, times: rv.times, areaCount: rv.areaCount)
            }
            // DeepSeek 2026-11-01：导出的单城回放同样启用屏幕空间 LOD
            if let cp = cfg.plan.cityPlan {
                var levels: [PointLODLevel] = []
                for c in cp.cities {
                    let base = max(c.x1 - c.x0, c.y1 - c.y0) * 1.15
                    levels += PointLODBuilder.build(track: track, center: (c.cx, c.cy),
                                                    baseSpan: max(base, 0.001), levels: 5)
                }
                renderer.setLODLevels(levels)
            }
        }
        let layer = MetalPointRenderer.makeOffscreenLayer(device: renderer.device,
                                                          width: cfg.outW, height: cfg.outH)

        // —— 4) AVAssetWriter ——
        try? FileManager.default.removeItem(at: cfg.url)
        guard let writer = try? AVAssetWriter(outputURL: cfg.url, fileType: .mp4) else {
            done(String(localized: "无法创建视频文件", comment: "Video export error detail, shown after 视频导出失败：: the MP4 file could not be created")); return
        }
        let bitrate = cfg.outW >= 3000 ? 42_000_000 : 14_000_000
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: cfg.outW,
            AVVideoHeightKey: cfg.outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: cfg.outW,
                kCVPixelBufferHeightKey as String: cfg.outH,
            ])
        guard writer.canAdd(input) else {
            done(String(localized: "视频编码器配置失败", comment: "Video export error detail, shown after 视频导出失败：: the H.264 encoder input could not be configured")); return
        }
        writer.add(input)
        guard writer.startWriting() else {
            let reason = writer.error?.localizedDescription
                ?? String(localized: "目标文件不可写", comment: "Video export error reason when the system gives none: the destination file is not writable")
            done(String(localized: "视频写入启动失败：\(reason)", comment: "Video export error detail, shown after 视频导出失败：: the video writer could not start; placeholder = system error description or 目标文件不可写"))
            return
        }
        writer.startSession(atSourceTime: .zero)

        // —— 5) 逐帧渲染合成 ——
        let totalFrames = max(1, Int(ceil(cfg.plan.duration * Double(cfg.fps))))
        var prevSource = -1
        var fadeFrom = -1
        var prevSwitch = -1.0
        var fwdbRect: (x0: Double, y0: Double, x1: Double, y1: Double)?
        var fwdbLevel = -1
        var fwdbGen = Int.max
        var frameErr: String?

        let dayFmt = DateFormatter()
        dayFmt.setLocalizedDateFormatFromTemplate("yMMMd HH:mm")

        for fi in 0...totalFrames {
            autoreleasepool {
            let p = min(cfg.plan.duration, Double(fi) / Double(cfg.fps))
            let cam = cfg.plan.camera(at: p, aspect: aspect)
            let dt = cfg.plan.dataTime(at: p)
            // DeepSeek 2026-10-31：每帧只更新区域游标；点云由 shader 按区域过滤
            if let cursors = cfg.plan.cursors(at: p) {
                renderer.updatePlaybackCursors(cursors)
            }
            let atEnd = p >= cfg.plan.duration - 1e-9

            // 揭示区间 / 存档代序
            var range = (start: cfg.rangeStart, len: cfg.rangeLen)
            var maxGen = Int.max
            if !atEnd {
                if let track = cfg.track, track.isTimeSorted {
                    let upto = track.indexRange(forTimeRange: (-1e18, dt))
                    range = (range.start, max(0, min(range.len, upto.start + upto.len - range.start)))
                } else if let a = cfg.archive {
                    maxGen = a.genUpTo(dt)
                }
            }

            let camera = CameraRect(x0: cam.cx - cam.span / 2,
                                    y0: cam.cy - cam.span * aspect / 2,
                                    w: cam.span, h: cam.span * aspect,
                                    pxW: Double(cfg.outW), pxH: Double(cfg.outH))

            // 存档实例（视口 + 代序变化才重建）
            if let a = cfg.archive {
                let cellPxHalf = camera.pxW / camera.w / Double(FogArchive.grid) / 2
                var level = 0
                if cellPxHalf < 0.75 { level = Int(ceil(log2(0.75 / cellPxHalf))) }
                level = max(0, min(level, a.levelKeys.count - 1))
                // 精确包含判定（与实时 ensureFwdbInstances 同语义）：视口越出
                // 上次收集矩形、级别或代序变化才重建——量化键在飞行升降段会
                // 整帧漏更新，画面闪整幅雾
                let genKey = maxGen >= a.genTimes.count - 1 ? Int.max : maxGen
                let stale = fwdbRect == nil || fwdbLevel != level || fwdbGen != genKey
                    || camera.x0 < fwdbRect!.x0 || camera.x0 + camera.w > fwdbRect!.x1
                    || camera.y0 < fwdbRect!.y0 || camera.y0 + camera.h > fwdbRect!.y1
                if stale {
                    let x0 = camera.x0 - camera.w, x1 = camera.x0 + camera.w * 2
                    let y0 = camera.y0 - camera.h, y1 = camera.y0 + camera.h * 2
                    var lv = level
                    var data = a.collectInstances(level: lv, x0: x0, y0: y0, x1: x1, y1: y1,
                                                  batchCenter: a.center, maxGen: maxGen)
                    while data.count > 350_000 * 4, lv < a.levelKeys.count - 1 {
                        lv += 1
                        data = a.collectInstances(level: lv, x0: x0, y0: y0, x1: x1, y1: y1,
                                                  batchCenter: a.center, maxGen: maxGen)
                    }
                    renderer.setFogArchiveInstances(data, center: a.center)
                    fwdbRect = (x0, y0, x1, y1)
                    fwdbLevel = level
                    fwdbGen = genKey
                }
            }

            // 覆盖层离屏渲染（GPU 完成信号量同步）
            final class Cap: @unchecked Sendable { var img: CGImage? }
            let cap = Cap()
            let gpuSem = DispatchSemaphore(value: 0)
            renderer.render(
                layer: layer, camera: camera,
                pointSizePx: cfg.pointSizePx,
                opacity: cfg.opacity, halo: cfg.halo,
                line: cfg.line, highlight: nil, lodStride: 1,
                range: range,
                heatMap: cfg.heatMap,
                heatSegPx: cfg.medianSegMerc * camera.pxW / camera.w,
                fogMap: cfg.fogMap || cfg.archive != nil,
                fogColor: cfg.fogColor, fogWash: cfg.fogWash,
                fogRadiusMeters: cfg.fogRadiusMeters,
                fogFileMask: cfg.fogFileMask,
                fogArchiveMode: cfg.archive != nil,
                fogArchiveSmooth: cfg.fogSmooth,
                lodDedupe: false,                     // 成片不去重（末帧不跳变）
                orderSensitive: true,                 // 回放揭示：新点在上
                reveal: cfg.plan.cityPlan != nil,     // 城市章节：按区域游标揭示
                captureTo: { tex in
                    cap.img = MetalPointRenderer.cgImage(from: tex)
                    gpuSem.signal()
                })
            // render() 的早退路径不会触达 captureTo——无超时等待会把偶发的
            // nextDrawable/编码失败放大成导出永久挂死
            if gpuSem.wait(timeout: .now() + 5) == .timedOut {
                frameErr = String(localized: "GPU 帧渲染超时", comment: "Video export error detail, shown after 视频导出失败：: rendering one frame on the GPU timed out")
                return
            }

            // 底图源选择（含快照的最小跨度场景；切换时 0.3s 交叉淡化）
            var best = -1
            var bestSpan = Double.infinity
            for (i, sc) in scenes.enumerated() where sc.image != nil {
                let eps = (sc.x1 - sc.x0) * 0.002
                if camera.x0 >= sc.x0 - eps, camera.x0 + camera.w <= sc.x1 + eps,
                   camera.y0 >= sc.y0 - eps, camera.y0 + camera.h <= sc.y1 + eps,
                   sc.x1 - sc.x0 < bestSpan {
                    bestSpan = sc.x1 - sc.x0
                    best = i
                }
            }
            if best != prevSource {
                fadeFrom = prevSource        // 旧源叠在上面淡出
                prevSwitch = p
                prevSource = best
                debug?("帧 \(fi): 源 \(fadeFrom) → \(best)")
            }
            let fade = min(1.0, (p - prevSwitch) / 0.3)

            // 像素缓冲合成
            guard let pool = adaptor.pixelBufferPool else {
                frameErr = String(localized: "像素缓冲池不可用", comment: "Video export error detail, shown after 视频导出失败：: the encoder's pixel buffer pool is unavailable"); return
            }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pixelBuffer = pb else {
                frameErr = String(localized: "像素缓冲分配失败", comment: "Video export error detail, shown after 视频导出失败：: a frame pixel buffer could not be allocated"); return
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                                width: cfg.outW, height: cfg.outH,
                                bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.interpolationQuality = .high
            ctx.setFillColor(cfg.dark ? CGColor(red: 0.09, green: 0.10, blue: 0.11, alpha: 1)
                                      : CGColor(red: 0.93, green: 0.93, blue: 0.92, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: cfg.outW, height: cfg.outH))

            func drawScene(_ idx: Int, alpha: CGFloat) {
                guard idx >= 0, idx < scenes.count, let img = scenes[idx].image else { return }
                let sc = scenes[idx]
                let sx = Double(img.width) / (sc.x1 - sc.x0)
                let sy = Double(img.height) / (sc.y1 - sc.y0)
                let crop = CGRect(x: (camera.x0 - sc.x0) * sx,
                                  y: (camera.y0 - sc.y0) * sy,
                                  width: camera.w * sx, height: camera.h * sy)
                // cropping(to:) 部分越界时返回交集——必须映射回对应的目标
                // 子矩形，整幅拉伸会在淡出期产生"橡皮筋"错位鬼影
                let inter = crop.intersection(CGRect(x: 0, y: 0,
                                                     width: img.width, height: img.height))
                guard !inter.isEmpty, inter.width >= 1, inter.height >= 1,
                      let piece = img.cropping(to: inter) else { return }
                let dsx = Double(cfg.outW) / crop.width
                let dsy = Double(cfg.outH) / crop.height
                let dx = (inter.minX - crop.minX) * dsx
                let dyTop = (inter.minY - crop.minY) * dsy      // 自顶向下偏移
                let dw = inter.width * dsx
                let dh = inter.height * dsy
                ctx.saveGState()
                ctx.setAlpha(alpha)
                // CG 原点在左下：目标 y 由顶向下偏移换算
                ctx.draw(piece, in: CGRect(x: dx, y: Double(cfg.outH) - dyTop - dh,
                                           width: dw, height: dh))
                ctx.restoreGState()
            }
            // 新源画满，旧源盖在上面按 (1-fade) 淡出——旧源裁剪越界时自然跳过
            drawScene(prevSource, alpha: 1)
            if fade < 1, fadeFrom >= 0, fadeFrom != prevSource {
                drawScene(fadeFrom, alpha: CGFloat(1 - fade))
            }
            // 底图压暗（与 App 内语义一致）
            if cfg.mapOpacity < 0.999 {
                ctx.setFillColor(CGColor(gray: 0, alpha: 1 - cfg.mapOpacity))
                ctx.fill(CGRect(x: 0, y: 0, width: cfg.outW, height: cfg.outH))
            }
            // 覆盖层
            if let ov = cap.img {
                ctx.draw(ov, in: CGRect(x: 0, y: 0, width: cfg.outW, height: cfg.outH))
            }
            // 时间轴丝带
            drawRibbon(ctx, w: cfg.outW, h: cfg.outH,
                       frac: cfg.plan.duration > 0 ? p / cfg.plan.duration : 1,
                       date: dayFmt.string(from: Date(timeIntervalSince1970: dt)))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            while !input.isReadyForMoreMediaData {
                if writer.status != .writing {
                    let reason = writer.error?.localizedDescription
                        ?? String(localized: "编码器停止", comment: "Video export error reason when the system gives none: the encoder stopped")
                    frameErr = String(localized: "视频写入中断：\(reason)", comment: "Video export error detail, shown after 视频导出失败：: writing was interrupted; placeholder = system error description or 编码器停止")
                    return
                }
                usleep(2000)
            }
            if !adaptor.append(pixelBuffer,
                               withPresentationTime: CMTime(value: CMTimeValue(fi),
                                                            timescale: CMTimeScale(cfg.fps)))
                || writer.status != .writing {
                let reason = writer.error?.localizedDescription
                    ?? String(localized: "磁盘或编码错误", comment: "Video export error reason when the system gives none: disk or encoding error")
                frameErr = String(localized: "视频写入失败：\(reason)", comment: "Video export error detail, shown after 视频导出失败：: appending a frame failed; placeholder = system error description or 磁盘或编码错误")
                return
            }
            if fi % 15 == 0 {
                progress(0.18 + 0.82 * Double(fi) / Double(totalFrames))
            }
            }
            if frameErr != nil { break }
        }

        input.markAsFinished()
        let finSem = DispatchSemaphore(value: 0)
        writer.finishWriting { finSem.signal() }
        finSem.wait()
        done(frameErr ?? (writer.status == .completed ? nil
                          : String(localized: "视频写入失败", comment: "Video export error detail, shown after 视频导出失败：: finishing the MP4 file failed")))
    }

    private static func scene(cx: Double, cy: Double, span: Double, aspect: Double) -> Scene {
        Scene(x0: cx - span / 2, y0: cy - span * aspect / 2,
              x1: cx + span / 2, y1: cy + span * aspect / 2, image: nil)
    }

    /// 底部时间轴丝带：渐变底 + 进度线 + 日期
    private static func drawRibbon(_ ctx: CGContext, w: Int, h: Int,
                                   frac: Double, date: String) {
        let rh = Double(h) * 0.052
        // CG 原点左下：丝带在 y ∈ [0, rh]
        let colors = [CGColor(gray: 0, alpha: 0.55), CGColor(gray: 0, alpha: 0.0)] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                 colors: colors, locations: [0, 1]) {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: Double(w), height: rh * 1.6))
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0),
                                   end: CGPoint(x: 0, y: rh * 1.6), options: [])
            ctx.restoreGState()
        }
        let margin = Double(w) * 0.03
        let barY = rh * 0.42
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.25))
        ctx.setLineWidth(rh * 0.07)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: margin, y: barY))
        ctx.addLine(to: CGPoint(x: Double(w) - margin, y: barY))
        ctx.strokePath()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.92))
        ctx.move(to: CGPoint(x: margin, y: barY))
        ctx.addLine(to: CGPoint(x: margin + (Double(w) - margin * 2) * frac, y: barY))
        ctx.strokePath()

        let fontSize = rh * 0.52
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attr = NSAttributedString(string: date, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 0.95),
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let tw = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: Double(w) - margin - tw, y: barY + rh * 0.28)
        CTLineDraw(line, ctx)
    }
}

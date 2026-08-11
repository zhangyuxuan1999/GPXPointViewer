//
//  PointMapView.swift
//  GPXPointViewer
//
//  MKMapView（Apple 地图底图）+ 压暗层 + 透明 CAMetalLayer 覆盖层（点云与箭头线）。
//
//  两个关键调度策略（治卡顿 + 治 "NSHostingView 重入布局" 警告）：
//  1. 重绘合并：地图 delegate、layout、设置变化都不直接渲染，而是
//     scheduleRedraw() 合并到本轮 runloop 的主队列尾部执行一次 ——
//     渲染永远发生在布局/SwiftUI 更新之外，且同一帧多个触发只画一次；
//     主队列块在 CA 提交观察者之前执行，配合 presentsWithTransaction
//     仍与底图逐帧锁定。
//  2. 悬停合并：mouseMoved 事件只记录坐标，拾取（vDSP argmin）每帧最多
//     跑一次 —— 500 万点时单次约 5ms，若每个鼠标事件都跑会拖死主线程。
//

import SwiftUI
import AppKit
import MapKit
import QuartzCore
import simd

// MARK: - 底图压暗层（穿透鼠标事件）

final class PassthroughDimView: NSView {
    override var isFlipped: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - 透明 Metal 覆盖层

final class MetalOverlayView: NSView {
    let metalLayer = CAMetalLayer()
    var onGeometryChange: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func makeBackingLayer() -> CALayer {
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.presentsWithTransaction = true
        return metalLayer
    }

    /// 鼠标事件全部穿透给下面的地图
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        syncDrawableSize()
        onGeometryChange?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableSize()
        onGeometryChange?()
    }

    func syncDrawableSize() {
        // 窗口未就绪/尺寸为零时不触碰 drawableSize（避免无效 setDrawableSize 日志）
        guard window != nil, bounds.width >= 1, bounds.height >= 1 else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
    }

    var backingScale: CGFloat { window?.backingScaleFactor ?? 2.0 }
}

// MARK: - 容器（地图 + 压暗层 + 覆盖层 + 鼠标跟踪）

/// 穿透事件的透明宿主（像素地球地名标签層）
final class LabelHostView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class MapContainerView: NSView {
    let mapView = MKMapView()
    let dimView = PassthroughDimView()
    let presentScrim = PassthroughDimView()   // 闲置展示：先把地图色调渐变到地球色调
    let overlay = MetalOverlayView()
    let labelHost = LabelHostView()
    var onMouseMoved: ((CGPoint) -> Void)?
    var onMouseExited: (() -> Void)?
    var onAppearanceChanged: (() -> Void)?

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(mapView)
        addSubview(dimView)
        addSubview(presentScrim)
        addSubview(overlay)
        labelHost.wantsLayer = true
        addSubview(labelHost)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        mapView.frame = bounds
        dimView.frame = bounds
        presentScrim.frame = bounds
        overlay.frame = bounds
        labelHost.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
        super.mouseExited(with: event)
    }
}

// MARK: - SwiftUI 封装

struct PointMapView: NSViewRepresentable {
    @ObservedObject var store: TrackStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> MapContainerView {
        let container = MapContainerView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        context.coordinator.attach(container)
        return container
    }

    func updateNSView(_ nsView: MapContainerView, context: Context) {
        context.coordinator.sync()
    }

    // MARK: 协调器

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        private let store: TrackStore
        private weak var container: MapContainerView?
        private var renderer: MetalPointRenderer?

        private var shownTrackID: UUID?
        private var shownColorVersion = -1
        private var shownSettings = ViewSettings()
        private var highlightIndex: Int?

        private var redrawScheduled = false
        private var pendingHover: CGPoint?
        private var hoverScheduled = false
        private var lastLodStride = 1        // 供拾取跳步复用
        private var shownDeleteMode = false
        private var shownStagedVersion = 0
        private var shownFilterKey = ""
        private var shownFlashVersion = 0
        private var shownLocateVersion = 0
        // 文件闪烁（GPU 端 fileID 过滤）：目标文件 + 结束时刻（淡入/停留/淡出）
        private var flashFileGPU: Int32 = -1
        private var flashUntil: Double = 0
        // 纱罩遮盖式快速换景进行中（noteActivity 期间不得把纱罩淡出）
        private var scrimCoverActive = false
        private var lassoPoints: [CGPoint] = []
        private var rightPanStartRect = MKMapRect()
        private var rightPanStartLoc = CGPoint.zero
        // 交互期 vsync 渲染循环（静止自动暂停）
        private var displayLink: CADisplayLink?
        private var lastInteraction: Double = 0

        // —— 自绘地球：与平面地图构成一个连续缩放空间 ——
        // 平面缩到"世界宽度贴住视口"的地板后继续缩小 → 无缝滑入地球；
        // 地球放大到与地板比例尺相合处 → 无缝滑回平面。无手动模式切换。
        // 手势约定：拖拽只旋转，滚轮/捏合只缩放，绝不混动。
        private var globeActive = false        // 语义模式（手势/拾取/相机路由）
        private var globeVisible = false       // 渲染开关（过渡淡出期间仍在画球）
        private var globeYaw: Float = 0        // 绕 Y 轴（经度），= -lonRad
        private var globePitch: Float = 0      // 绕 X 轴（纬度），= latRad
        private var globeDist: Float = 3.2     // 相机到球心距离（球半径 = 1）
        private var globePanGR: NSPanGestureRecognizer?
        private var floorOverscroll: Double = 0        // 缩放饱和处的继续缩小累积量
        private var transitionCooldown: Double = 0     // 防抖：过渡后短暂冷却
        private var lastMapDistance: Double = .greatestFiniteMagnitude   // 饱和检测：上次缩小事件时的相机高度
        private var globeReturnDist: Double = 1.6      // 放大到该球距 → 自动回平面（进入时按衔接比例算好）
        private var wheelMonitor: Any?
        private var magnifyMonitor: Any?
        private var mouseDownMonitor: Any?

        // 闲置动画：无操作达设置秒数（settings.idleGlobeSeconds / idleMapSeconds）
        // → 扶正 + 自转 + 月球沿轨道公转；settings.idleDisabled 可整体关闭
        private var lastActivity: Double = CACurrentMediaTime()
        private var idleAnim = false
        private var idleStart: Double = 0
        private var idleLastTime: Double = 0
        private var demoAnomaly: Double = 0      // 月球平近点角偏移（度，闲置演示推进）
        // 进入闲置前的视角快照：退出时渐变还原（位置/缩放/模式/地球风格）
        private var idleReturn: (wasGlobe: Bool, rect: MKMapRect,
                                 yaw: Float, pitch: Float, dist: Float,
                                 style: GlobeStyle, styleChanged: Bool)?
        // 球面视角的返回缓动（displayTick 驱动；手动旋转/缩放会取消）
        private var globeReturnAnim: (t0: Double, dur: Double,
                                      fromYaw: Float, fromPitch: Float, fromDist: Float,
                                      toYaw: Float, toPitch: Float, toDist: Float)?

        // 像素地球：聚合缓存（数据/筛选/删除后重建）+ 地名标签层
        private var pixelCellsDirty = true
        private var pixelLabels: [(city: GlobeCity, unit: SIMD3<Double>)] = []
        private var labelNodes: [(unit: SIMD3<Double>, text: CATextLayer, dot: CALayer)] = []

        /// 进入/返回阈值（屏幕可见的地面宽度，米）。
        /// 进入取 6500km（约一个大洲）：在 MapKit 自己的球体渲染（标准图的封顶、
        /// 卫星图的原生地球）出现之前就由自绘地球接管——平面墨卡托叠加层只在
        /// 平面渲染下成立。返回略小形成滞回，且保证任何底图/纬度都显示得出来。
        private static let groundEnter: Double = 6_500_000
        private static let groundReturn: Double = 5_600_000

        deinit {
            displayLink?.invalidate()
            if let m = wheelMonitor { NSEvent.removeMonitor(m) }
            if let m = magnifyMonitor { NSEvent.removeMonitor(m) }
            if let m = mouseDownMonitor { NSEvent.removeMonitor(m) }
        }

        init(store: TrackStore) {
            self.store = store
            super.init()
        }

        func attach(_ container: MapContainerView) {
            self.container = container
            let mapView = container.mapView

            mapView.delegate = self
            // realistic 高程：缩到头时 MapKit 切换成 3D 地球（地球视角的前提）
            mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
            mapView.isRotateEnabled = false      // 保持轴对齐，覆盖层矩阵最简
            mapView.isPitchEnabled = false
            mapView.showsZoomControls = true
            mapView.showsPitchControl = false

            if let r = MetalPointRenderer() {
                renderer = r
                container.overlay.metalLayer.device = r.device
                r.onFrameStats = { [weak self] frame in
                    self?.store.pushRenderStats(frame)
                }
            } else {
                store.errorMessage = "此设备不支持 Metal，无法渲染点云。"
            }

            container.overlay.onGeometryChange = { [weak self] in self?.scheduleRedraw() }
            container.onMouseMoved = { [weak self] p in self?.queueHover(at: p) }
            container.onMouseExited = { [weak self] in self?.clearHover() }
            container.onAppearanceChanged = { [weak self] in self?.scheduleRedraw() }   // 日/夜外观切换重绘地球
            // 导入/拖放/对话框等非鼠标活动也重置闲置计时（修复"拖入文件即待机"）
            store.onUserActivity = { [weak self] in self?.noteActivity() }

            // 点击拾取：挂在容器上（平面与地球两种视角都收得到）
            let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
            click.delegate = self
            container.addGestureRecognizer(click)

            // 框选删除的拖拽手势（仅删除模式下激活，见 gestureRecognizerShouldBegin）
            let pan = NSPanGestureRecognizer(target: self, action: #selector(handleSelectionPan(_:)))
            pan.delegate = self
            container.addGestureRecognizer(pan)

            // 删除模式下右键拖拽：平面 = 平移地图，地球 = 旋转地球
            let rightPan = NSPanGestureRecognizer(target: self, action: #selector(handleRightPan(_:)))
            rightPan.buttonMask = 0x2
            rightPan.delegate = self
            container.addGestureRecognizer(rightPan)

            // 地球拖拽旋转（非删除模式；缩放只走滚轮/捏合，绝不混动）
            let globePan = NSPanGestureRecognizer(target: self, action: #selector(handleGlobePan(_:)))
            globePan.delegate = self
            container.addGestureRecognizer(globePan)
            globePanGR = globePan

            // 滚轮/捏合监视器：一个连续缩放空间的关键。
            // 地图自己吃滚轮事件，容器根本收不到——本地事件监视器在派发前拦截：
            // 地球模式下滚轮直接驱动球距（返回 nil 吞掉事件）；
            // 平面模式越过进入比例尺 → 自动无缝切入地球。
            // 只拆出 Sendable 值进主线程闭包（NSEvent 本身不能跨隔离域）。
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                let dy = event.scrollingDeltaY
                let precise = event.hasPreciseScrollingDeltas
                let wid = event.window.map(ObjectIdentifier.init)
                let loc = event.locationInWindow
                let consumed = MainActor.assumeIsolated {
                    self.routeScroll(dy: dy, precise: precise, windowID: wid, locationInWindow: loc)
                }
                return consumed ? nil : event
            }
            magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
                guard let self else { return event }
                let mag = event.magnification
                let wid = event.window.map(ObjectIdentifier.init)
                let loc = event.locationInWindow
                let consumed = MainActor.assumeIsolated {
                    self.routeMagnify(magnification: mag, windowID: wid, locationInWindow: loc)
                }
                return consumed ? nil : event
            }
            // 按下即算活动：闲置展示平面阶段左键拖地图只发 mouseDragged（无
            // mouseMoved），MapKit delegate 又被 idleAnim 门控——按下监视器是
            // 唯一可靠的唤醒信号（只观察不消费事件）
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self else { return event }
                MainActor.assumeIsolated { self.noteActivity() }
                return event
            }

            scheduleIdleCheck()
        }

        // MARK: 状态同步（updateNSView 驱动，只做增量工作，不在此渲染）

        func sync() {
            guard let container else { return }

            // 1. 数据换代
            if store.track?.id != shownTrackID {
                shownTrackID = store.track?.id
                shownColorVersion = store.track?.colorVersion ?? -1
                highlightIndex = nil
                pixelCellsDirty = true
                if let track = store.track {
                    renderer?.setData(track: track)
                    if store.preserveNextCamera {
                        store.preserveNextCamera = false   // 删除/撤销：相机保持原位
                    } else {
                        // 相机动画放到布局周期之外
                        DispatchQueue.main.async { [weak self] in
                            guard let self, let t = self.store.track, t.id == self.shownTrackID,
                                  let mapView = self.container?.mapView else { return }
                            // 横跨大洲/全球的数据：平面 zoomToFit 必然拉到球体级高度，
                            // 直接以地球总览呈现；紧凑数据照常平面 zoomToFit
                            let wide = (t.bbox.maxLon - t.bbox.minLon) > 90
                                    || (t.bbox.maxLat - t.bbox.minLat) > 60
                            if wide {
                                self.enterGlobeOverview(for: t)
                            } else if self.globeActive {
                                self.switchToMap()
                                self.zoomToFit(t, in: mapView)
                            } else {
                                self.zoomToFit(t, in: mapView)
                            }
                        }
                    }
                } else {
                    renderer?.clearData()
                }
                scheduleRedraw()
            }

            // 删除模式：暂停地图平移，让左键拖拽变成手绘圈选（右键拖拽平移）
            if store.deleteMode != shownDeleteMode {
                shownDeleteMode = store.deleteMode
                container.mapView.isScrollEnabled = !store.deleteMode
                if !store.deleteMode, store.selectionPath != nil {
                    DispatchQueue.main.async { [weak self] in self?.store.selectionPath = nil }
                }
            }
            // 2. 只换了颜色
            else if let track = store.track, track.colorVersion != shownColorVersion {
                shownColorVersion = track.colorVersion
                renderer?.updateColors(store.stagedDisplayColors ?? track.colors)
                scheduleRedraw()
            }

            // 2b. 预删除灰显变化
            if store.stagedVersion != shownStagedVersion {
                shownStagedVersion = store.stagedVersion
                if let track = store.track {
                    renderer?.updateColors(store.stagedDisplayColors ?? track.colors)
                }
                scheduleRedraw()
            }

            // 2c. 时间筛选变化 → 重绘（可见区间是渲染 uniforms 的一部分；聚合作废）
            let filterKey = store.viewFilter.map { "\($0.start)|\($0.end)" } ?? ""
            if filterKey != shownFilterKey {
                shownFilterKey = filterKey
                pixelCellsDirty = true
                scheduleRedraw()
            }

            // 2d. 文件列表点击 → 该文件轨迹高亮闪烁（GPU 端 fileID 过滤）
            if store.flashVersion != shownFlashVersion {
                shownFlashVersion = store.flashVersion
                if let idx = store.flashFileIndex { triggerFileFlash(fileIndex: idx) }
            }

            // 2e. 定位到轨迹起点
            if store.locateVersion != shownLocateVersion {
                shownLocateVersion = store.locateVersion
                locateToStart()
            }

            // 3. 设置变化
            if store.settings != shownSettings {
                let old = shownSettings
                shownSettings = store.settings

                if old.mapStyle != store.settings.mapStyle {
                    switch store.settings.mapStyle {
                    case .standard:
                        container.mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
                    case .imagery:
                        container.mapView.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
                    case .hybrid:
                        container.mapView.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .realistic)
                    }
                }
                if old.mapOpacity != store.settings.mapOpacity, !globeVisible {
                    container.dimView.alphaValue = CGFloat(1.0 - store.settings.mapOpacity)
                }
                if old.globeStyle != store.settings.globeStyle {
                    pixelCellsDirty = true
                    interactionTick()          // 像素模式需要持续帧驱动流星
                }
                scheduleRedraw()
            }
        }

        /// 文件列表点击的高亮闪烁（GPU 端按 fileID 过滤）：目标文件透明度拉满 +
        /// 点放大约一半，其余文件保色、透明度大幅降低（不全透明）。
        /// 纯渲染参数级效果，不写任何缓冲——拖动/缩放后依然可靠触发
        private func triggerFileFlash(fileIndex: Int) {
            guard !store.deleteMode, let track = store.track, !track.fileID.isEmpty else { return }
            flashFileGPU = Int32(fileIndex)
            flashUntil = CACurrentMediaTime() + 1.1
            interactionTick()      // vsync 循环驱动淡入/淡出
            scheduleRedraw()
        }

        /// 当前帧的闪烁参数（淡入 0.12s → 停留 → 淡出 0.3s，smoothstep）
        private func currentFlash() -> (file: Int32, strength: Float) {
            guard flashFileGPU >= 0 else { return (-1, 0) }
            let now = CACurrentMediaTime()
            guard now < flashUntil else {
                flashFileGPU = -1
                return (-1, 0)
            }
            let remain = flashUntil - now
            let elapsed = 1.1 - remain
            let s: Double
            if elapsed < 0.12 { s = elapsed / 0.12 }
            else if remain < 0.30 { s = remain / 0.30 }
            else { s = 1 }
            return (flashFileGPU, Float(s * s * (3 - 2 * s)))
        }

        private func zoomToFit(_ track: TrackData, in mapView: MKMapView) {
            let p1 = MKMapPoint(CLLocationCoordinate2D(latitude: track.bbox.maxLat, longitude: track.bbox.minLon))
            let p2 = MKMapPoint(CLLocationCoordinate2D(latitude: track.bbox.minLat, longitude: track.bbox.maxLon))
            var rect = MKMapRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                                 width: max(1000, abs(p1.x - p2.x)), height: max(1000, abs(p1.y - p2.y)))
            rect = rect.insetBy(dx: -rect.size.width * 0.14, dy: -rect.size.height * 0.14)
            mapView.setVisibleMapRect(rect, animated: true)
        }

        // MARK: 覆盖层重绘
        //
        // 两条路径：
        // - scheduleRedraw：一次性变化（设置/数据/颜色），合并到 runloop 尾部画一次；
        // - interactionTick + displayLink：地图交互期间按 vsync 逐帧主动渲染
        //   （不依赖 delegate 节拍，帧率贴满显示器），静止 0.35s 自动暂停零功耗。

        func scheduleRedraw() {
            // vsync 循环已在跑：displayTick 每帧必渲染，这里再插帧只会翻倍 GPU 工作
            if let link = displayLink, !link.isPaused { return }
            guard !redrawScheduled else { return }
            redrawScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.redrawScheduled = false
                self.performRedraw()
            }
        }

        private func interactionTick() {
            lastInteraction = CACurrentMediaTime()
            if displayLink == nil, let overlay = container?.overlay {
                let link = overlay.displayLink(target: self, selector: #selector(displayTick))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            displayLink?.isPaused = false
        }

        @objc private func displayTick() {
            if idleAnim { stepIdleAnimation() }
            if globeReturnAnim != nil { stepGlobeReturn() }
            performRedraw()
            let pixelLive = globeVisible && store.settings.globeStyle == .pixel   // 流星需要持续帧
            if !idleAnim, globeReturnAnim == nil, !pixelLive,
               CACurrentMediaTime() >= flashUntil,          // 文件闪烁期间保持逐帧
               CACurrentMediaTime() - lastInteraction > 0.35 {
                displayLink?.isPaused = true
            }
        }

        // MARK: 闲置动画（扶正 + 自转 + 月球公转）

        /// 任何鼠标操作都会打断闲置动画并重置计时
        private func noteActivity() {
            lastActivity = CACurrentMediaTime()
            if idleAnim {
                idleAnim = false
                restoreFromIdle()   // 渐变回进入展示前的视角
                scheduleRedraw()
            }
            if store.presenting { store.presenting = false }   // 面板快速渐现
            // 遮盖式换景进行中由其自身管理纱罩，这里不得抢先淡出
            if !scrimCoverActive, let scrim = container?.presentScrim, scrim.alphaValue > 0.001 {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    scrim.animator().alphaValue = 0
                }
            }
        }

        /// 自续检查链（每 0.5s 一次；弱引用断链，无需手动清理）
        private func scheduleIdleCheck() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.idleCheck()
                self.scheduleIdleCheck()
            }
        }

        private func idleCheck() {
            guard !store.settings.idleDisabled,
                  !idleAnim, !store.deleteMode, !store.isLoading,
                  !store.showExportSheet, !store.showSettingsSheet,
                  store.executePrompt == nil,
                  store.errorMessage == nil,       // 错误弹窗阅读中不得进入展示
                  NSApp.modalWindow == nil,        // 打开/保存等模态面板期间同理
                  CACurrentMediaTime() >= transitionCooldown else { return }
            let need = globeActive ? store.settings.idleGlobeSeconds
                                   : store.settings.idleMapSeconds   // 地球/平面各自可配
            guard CACurrentMediaTime() - lastActivity > need else { return }
            idleAnim = true
            idleStart = CACurrentMediaTime()
            idleLastTime = idleStart
            store.presenting = true                     // 面板先快速渐隐
            if store.hover != nil { store.hover = nil }
            // 保存进入前的视角（含被展示强改前的地球风格），退出时渐变还原
            let prevStyle = store.settings.globeStyle
            var styleChanged = false
            if !globeActive {
                if store.settings.globeStyle != .pixel {
                    store.settings.globeStyle = .pixel  // 平面出发的展示固定像素风格
                    styleChanged = true
                }
                applyScrimBaseColor()   // 纱罩颜色 = 展示地球的球面基色
            }
            idleReturn = (wasGlobe: globeActive,
                          rect: container?.mapView.visibleMapRect ?? MKMapRect.world,
                          yaw: globeYaw, pitch: globePitch, dist: globeDist,
                          style: prevStyle, styleChanged: styleChanged)
            globeReturnAnim = nil
            interactionTick()          // 启动 vsync 循环；idleAnim 分支保持不暂停
        }

        /// 退出闲置展示：渐变回进入前的视角（位置/缩放/模式/地球风格）
        private func restoreFromIdle() {
            guard let saved = idleReturn else { return }
            idleReturn = nil
            if saved.styleChanged, store.settings.globeStyle != saved.style {
                store.settings.globeStyle = saved.style
            }
            if saved.wasGlobe {
                // 球面出发：相机缓动回原视角（0.8s smoothstep）
                globeReturnAnim = (CACurrentMediaTime(), 0.8,
                                   globeYaw, globePitch, globeDist,
                                   saved.yaw, saved.pitch, saved.dist)
                interactionTick()
            } else if globeActive {
                // 平面出发、展示已滑入地球：纱罩盖住 → 瞬时换景落位 → 揭开。
                // 全程无"地球+地图同框"、无大幅相机动画，比进入展示明显更快
                coveredReturnToMap(rect: saved.rect)
            } else {
                // 仍在平面拉远阶段：直接动画回原区域
                container?.mapView.setVisibleMapRect(saved.rect, animated: true)
            }
        }

        /// 纱罩遮盖式快速回平面（约 0.4s）：0.15s 盖住 → 遮盖下瞬时切平面
        /// 并直接落位 → 0.25s 揭开。闲置退出与地球视角"定位"共用
        private func coveredReturnToMap(rect: MKMapRect) {
            guard let container else { return }
            scrimCoverActive = true
            applyScrimBaseColor()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                container.presentScrim.animator().alphaValue = 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { [weak self] in
                guard let self, let container = self.container else { return }
                self.instantReturnToMap(rect: rect)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    container.presentScrim.animator().alphaValue = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                    self?.scrimCoverActive = false
                }
            }
        }

        /// 瞬时切回平面并落位（在纱罩遮盖下执行，无任何过渡动画）
        private func instantReturnToMap(rect: MKMapRect) {
            guard let container else { return }
            globeActive = false
            globeVisible = false
            floorOverscroll = 0
            lastMapDistance = .greatestFiniteMagnitude
            transitionCooldown = CACurrentMediaTime() + 0.6
            highlightIndex = nil
            let mapView = container.mapView
            mapView.isHidden = false
            mapView.isScrollEnabled = !store.deleteMode
            mapView.setVisibleMapRect(rect, animated: false)
            container.dimView.alphaValue = CGFloat(1.0 - store.settings.mapOpacity)
            setLabelsHidden(true)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.store.globeShowing { self.store.globeShowing = false }
                if self.store.presenting { self.store.presenting = false }
            }
            interactionTick()
            scheduleRedraw()
        }

        /// 纱罩底色 = 展示地球的球面基色（跟随系统外观）
        private func applyScrimBaseColor() {
            let dark = container?.effectiveAppearance
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            container?.presentScrim.layer?.backgroundColor = dark
                ? NSColor(calibratedRed: 0.043, green: 0.055, blue: 0.075, alpha: 1).cgColor
                : NSColor(calibratedRed: 0.886, green: 0.900, blue: 0.920, alpha: 1).cgColor
        }

        /// 定位到当前轨迹的起点（时间最早的点）：
        /// 平面 = MapKit 快速飞行动画；地球视角 = 纱罩遮盖式快速切回平面落位
        private func locateToStart() {
            guard let track = store.track, track.count > 0, let container else { return }
            let lat = track.lat[0], lon = track.lon[0]
            let cpt = MKMapPoint(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            let mpp = max(1e-9, MKMetersPerMapPointAtLatitude(lat))
            let b = container.bounds
            let w = 2600.0 / mpp                        // 视野宽约 2.6 km
            let h = w * Double(max(b.height, 1)) / Double(max(b.width, 1))
            let rect = MKMapRect(x: cpt.x - w / 2, y: cpt.y - h / 2, width: w, height: h)
            if globeActive {
                coveredReturnToMap(rect: rect)
            } else {
                container.mapView.setVisibleMapRect(rect, animated: true)
            }
        }

        /// 球面返回缓动的逐帧推进（displayTick 驱动）
        private func stepGlobeReturn() {
            guard let a = globeReturnAnim else { return }
            let t = min(1.0, (CACurrentMediaTime() - a.t0) / a.dur)
            let e = Float(t * t * (3 - 2 * t))          // smoothstep
            let dYaw = remainder(a.toYaw - a.fromYaw, 2 * Float.pi)
            globeYaw = remainder(a.fromYaw + dYaw * e, 2 * Float.pi)
            globePitch = a.fromPitch + (a.toPitch - a.fromPitch) * e
            globeDist = a.fromDist + (a.toDist - a.fromDist) * e
            if t >= 1 { globeReturnAnim = nil }
        }

        private func stepIdleAnimation() {
            let now = CACurrentMediaTime()
            let dt = min(0.1, max(0, now - idleLastTime))
            idleLastTime = now

            // 平面阶段时间轴：面板隐去（0.4s）→ 地图色调渐变到地球色调（1.1s）
            // → 色调到位后才开始持续拉远，直至无缝切入地球
            if !globeActive {
                guard let container, now - idleStart > 0.40 else { return }
                let colorT = min(1.0, (now - idleStart - 0.40) / 1.1)
                container.presentScrim.alphaValue = CGFloat(colorT) * 0.82
                guard now - idleStart > 1.60 else { return }
                let mapView = container.mapView
                let r0 = mapView.visibleMapRect
                let g = 1.0 + dt * 1.15
                let nw = r0.size.width * g
                let nh = r0.size.height * g
                mapView.setVisibleMapRect(
                    MKMapRect(x: r0.origin.x - (nw - r0.size.width) / 2,
                              y: r0.origin.y - (nh - r0.size.height) / 2,
                              width: nw, height: nh),
                    animated: false)
                // 越过进入比例尺，或 MapKit 封顶拉不动了 → 切入地球
                if mapGroundAcross() >= Self.groundEnter
                    || mapView.visibleMapRect.size.width <= r0.size.width * 1.0001 {
                    switchToGlobe()
                }
                return
            }

            // 球面阶段：扶正（地轴竖直）+ 真实方向自转 + 月球沿轨道公转，
            // 同时拉远到整条月球轨道恰好入画
            globePitch *= Float(exp(-dt * 2.0))
            globeYaw = remainder(globeYaw - Float(dt * 0.06), 2 * Float.pi)
            demoAnomaly = (demoAnomaly + dt * 4.0).truncatingRemainder(dividingBy: 360)
            let target = orbitFitDist()
            globeDist = Float(target + (Double(globeDist) - target) * exp(-dt * 0.8))
        }

        /// 整条月球轨道（2.2R + 远地点余量）恰好入画的球距
        private func orbitFitDist() -> Double {
            guard let container else { return 7 }
            let b = container.bounds
            guard b.width > 1, b.height > 1 else { return 7 }
            let tanH = Double(tan(MetalPointRenderer.globeFovY / 2))
            let ys = 1 / tanH
            let xs = ys / (Double(b.width) / Double(b.height))
            let reach = 2.2 * 1.08
            let d = max(reach * ys / 0.90, reach * xs / 0.90)
            return min(11.5, max(5.0, d))
        }

        private func performRedraw() {
            guard let container, let renderer else { return }
            let overlay = container.overlay

            // —— 自绘地球分支：完全不碰 MapKit ——
            if globeVisible {
                guard overlay.metalLayer.drawableSize.width > 1 else { return }
                // 地图已隐藏时无需与 MapKit 逐帧锁定：免事务呈现，省主线程等待
                overlay.metalLayer.presentsWithTransaction = !container.mapView.isHidden
                let pixel = store.settings.globeStyle == .pixel
                if pixel { rebuildPixelDataIfNeeded() }
                let scale = Double(overlay.backingScale)
                let range = store.visibleIndexRange()
                let stride = globeLodStride(visibleLen: range.len)
                lastLodStride = stride
                let dark = container.effectiveAppearance
                    .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let flash = currentFlash()
                renderer.renderGlobe(
                    layer: overlay.metalLayer,
                    yaw: globeYaw, pitch: globePitch, distance: globeDist,
                    pointSizePx: store.settings.pointSize * scale,
                    opacity: store.settings.opacity,
                    halo: store.settings.showHalo,
                    lodStride: stride,
                    range: range,
                    highlight: highlightIndex,
                    darkMode: dark,
                    mapDim: idleAnim ? 1.0 : store.settings.mapOpacity,   // 展示中地球满亮度
                    demoAnomalyDeg: demoAnomaly,
                    pixelStyle: pixel,
                    flashFile: flash.file,
                    flashStrength: flash.strength)
                updateLabels(pixel: pixel, dark: dark)
                return
            }

            if !container.labelHost.isHidden { container.labelHost.isHidden = true }
            let mapView = container.mapView
            let world = MKMapRect.world.size.width
            let r = mapView.visibleMapRect
            guard r.size.width > 0, r.size.height > 0 else { return }

            // 平面模式兜底：任何原因越过了进入比例尺（世界级 zoomToFit、MapKit
            // 卫星图自己转成 3D 地球…），立即无缝接管为自绘地球——平面墨卡托
            // 叠加层在球体渲染下必然与底图错位（点会"飘"出球外）
            if CACurrentMediaTime() >= transitionCooldown,
               mapGroundAcross() >= Self.groundEnter * 1.15
                || r.size.width >= world * 0.99
                || mapView.camera.centerCoordinateDistance > 16_000_000 {
                switchToGlobe()
                return
            }

            let camera = CameraRect(
                x0: r.origin.x / world,
                y0: r.origin.y / world,
                w: r.size.width / world,
                h: r.size.height / world,
                pxW: Double(overlay.metalLayer.drawableSize.width),
                pxH: Double(overlay.metalLayer.drawableSize.height))
            let scale = Double(overlay.backingScale)
            let range = store.visibleIndexRange()
            let stride = lodStride(camera: camera, visibleLen: range.len)
            lastLodStride = stride
            overlay.metalLayer.presentsWithTransaction = true   // 平面：与底图逐帧锁定
            let flash = currentFlash()

            renderer.render(
                layer: overlay.metalLayer,
                camera: camera,
                pointSizePx: store.settings.pointSize * scale,
                opacity: store.settings.opacity,
                halo: store.settings.showHalo,
                line: lineParams(scale: scale),
                highlight: highlightIndex,
                lodStride: stride,
                range: range,
                flashFile: flash.file,
                flashStrength: flash.strength)
            updateScaleBar()
        }

        // MARK: 自绘地球：连续缩放空间（自动进入/退出 + 手势 + 拾取 + LOD）

        /// 显示指定地面宽度（米）所需的球距：
        /// 屏幕中心 米/像素 相等 ⇒ d = 1 + H·ground/(2·tan(fov/2)·R·W)
        private func dFromGround(_ ground: Double) -> Double {
            guard let container else { return 1.8 }
            let b = container.bounds
            guard b.width > 1, b.height > 1 else { return 1.8 }
            let tanH = Double(tan(MetalPointRenderer.globeFovY / 2))
            return 1 + Double(b.height) * ground / (2 * tanH * 6_378_137.0 * Double(b.width))
        }

        /// 地图当前可见的地面宽度（米，按中心纬度换算——高纬下墨卡托膨胀已除掉）
        private func mapGroundAcross() -> Double {
            guard let container else { return 0 }
            let mapView = container.mapView
            return mapView.visibleMapRect.size.width
                * MKMetersPerMapPointAtLatitude(mapView.centerCoordinate.latitude)
        }

        /// 与地图当前比例尺严格衔接的球距（过渡瞬间中心内容大小完全一致）
        private func dMatchedToMap() -> Double {
            let ground = mapGroundAcross()
            guard ground > 1000 else { return 3.2 }
            return min(11.0, max(1.28, dFromGround(ground)))
        }

        /// 平面模式下的一次"继续缩小"意图。返回 true 表示已切入地球（事件应被吞掉）。
        /// 两条触发路径：
        /// 1. 可见地面宽 ≥ groundEnter —— 主路径，精确、与底图无关；
        /// 2. 缩放饱和 —— 相机高度在连续缩小事件下不再增长（MapKit 在当前
        ///    窗口/底图下封了顶，例如标准图只能缩到亚洲），累积一小段后接管。
        private func mapZoomOutIntent(_ amount: Double) -> Bool {
            guard let container, !store.deleteMode,
                  CACurrentMediaTime() >= transitionCooldown else { return false }
            let ground = mapGroundAcross()
            if ground >= Self.groundEnter {
                switchToGlobe()
                return true
            }
            let d0 = container.mapView.camera.centerCoordinateDistance
            if ground > 3_000_000, d0 <= lastMapDistance * 1.004 {
                floorOverscroll += amount
                if floorOverscroll > 25 {
                    switchToGlobe()
                    return true
                }
            } else {
                floorOverscroll = 0
            }
            lastMapDistance = d0
            return false
        }

        /// 滚轮路由（返回 true = 吞掉事件）：地球模式直接驱动球距；
        /// 平面模式越过进入比例尺 → 无缝切入地球
        private func routeScroll(dy: CGFloat, precise: Bool,
                                 windowID: ObjectIdentifier?, locationInWindow: NSPoint) -> Bool {
            guard let container, let window = container.window,
                  windowID == ObjectIdentifier(window) else { return false }
            let loc = container.convert(locationInWindow, from: nil)
            guard container.bounds.contains(loc) else { return false }
            noteActivity()   // 平面分支也算活动（globeZoomWheel 内部的调用只覆盖地球分支）

            if globeActive {
                globeZoomWheel(deltaY: dy, precise: precise)
                return true
            }
            let zoomOut = precise ? -Double(dy) : -Double(dy) * 10
            if zoomOut > 0 {
                if mapZoomOutIntent(zoomOut) { return true }
            } else if zoomOut < 0 {
                floorOverscroll = 0
                lastMapDistance = .greatestFiniteMagnitude
            }
            return false
        }

        /// 触控板捏合路由（语义同滚轮）
        private func routeMagnify(magnification: CGFloat,
                                  windowID: ObjectIdentifier?, locationInWindow: NSPoint) -> Bool {
            guard let container, let window = container.window,
                  windowID == ObjectIdentifier(window) else { return false }
            let loc = container.convert(locationInWindow, from: nil)
            guard container.bounds.contains(loc) else { return false }
            noteActivity()   // 同 routeScroll

            if globeActive {
                globeMagnify(magnification)
                return true
            }
            if magnification < 0 {
                if mapZoomOutIntent(Double(-magnification) * 300) { return true }
            } else if magnification > 0 {
                floorOverscroll = 0
                lastMapDistance = .greatestFiniteMagnitude
            }
            return false
        }

        /// 平面 → 地球：从地图当前比例尺解出严格衔接的球距（中心内容大小不变），
        /// 黑色压暗层淡入成太空（0.28s）
        private func switchToGlobe() {
            guard let container, !globeActive else { return }
            let c = container.mapView.centerCoordinate
            globeYaw = -Float(c.longitude * Double.pi / 180)
            globePitch = Float(max(-85, min(85, c.latitude)) * Double.pi / 180)
            let matched = dMatchedToMap()
            globeDist = Float(matched)
            // 回程阈值：不低于返回比例尺（滞回），也不高于进入比例尺（原路返回仍无缝）
            globeReturnDist = max(1.30, min(matched, dFromGround(Self.groundReturn)) * 0.97)
            globeActive = true
            globeVisible = true
            floorOverscroll = 0
            lastMapDistance = .greatestFiniteMagnitude
            transitionCooldown = CACurrentMediaTime() + 0.35
            highlightIndex = nil
            container.mapView.isScrollEnabled = false   // 淡出期间地图不再响应拖拽/缩放
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.store.hover != nil { self.store.hover = nil }
                if self.store.selected != nil { self.store.selected = nil }
                self.store.pushScaleBar(nil)   // 球面透视下单一比例尺无意义
                self.store.globeShowing = true // 悬浮风格控件显现
            }
            if store.settings.globeStyle == .pixel { pixelCellsDirty = true }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                container.dimView.animator().alphaValue = 1.0
            }
            if container.presentScrim.alphaValue > 0.001 {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.35
                    container.presentScrim.animator().alphaValue = 0
                }
            }
            // 淡出完成后隐藏地图（主队列延时，规避 @Sendable 完成回调的隔离限制）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                guard let self, self.globeActive else { return }
                self.container?.mapView.isHidden = true
            }
            interactionTick()
            scheduleRedraw()
        }

        /// 地球 → 平面：由当前球距解出应显示的地面宽度，把地图摆到严格衔接的
        /// 相机位（比例尺 + 中心都对齐），压暗层淡回原透明度，随后停画球体
        private func switchToMap() {
            guard let container, globeActive else { return }
            globeActive = false
            floorOverscroll = 0
            lastMapDistance = .greatestFiniteMagnitude
            transitionCooldown = CACurrentMediaTime() + 0.4
            highlightIndex = nil
            let mapView = container.mapView
            let b = container.bounds
            let lat = max(-85.0, min(85.0, Double(globePitch) * 180 / .pi))
            let lon = Double(-remainder(globeYaw, 2 * Float.pi)) * 180 / .pi
            mapView.isHidden = false
            mapView.isScrollEnabled = !store.deleteMode
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.store.globeShowing { self.store.globeShowing = false }
                if self.store.presenting { self.store.presenting = false }
            }
            setLabelsHidden(true)
            if b.width > 1, b.height > 1 {
                let tanH = Double(tan(MetalPointRenderer.globeFovY / 2))
                let ground = Double(globeDist - 1) * 2 * tanH * 6_378_137.0
                             * Double(b.width) / Double(b.height)
                let mpp = MKMetersPerMapPointAtLatitude(lat)
                let w = min(MKMapRect.world.size.width, ground / max(mpp, 1e-9))
                let h = w * Double(b.height) / Double(b.width)
                let cpt = MKMapPoint(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                mapView.setVisibleMapRect(
                    MKMapRect(x: cpt.x - w / 2, y: cpt.y - h / 2, width: w, height: h),
                    animated: false)
            } else {
                mapView.setCenter(CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                  animated: false)
            }
            let restDim = CGFloat(1.0 - store.settings.mapOpacity)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                container.dimView.animator().alphaValue = restDim
            }
            // 淡入完成后停画球体，切回平面点云
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.27) { [weak self] in
                guard let self, !self.globeActive else { return }
                self.globeVisible = false
                self.scheduleRedraw()
            }
            interactionTick()
            scheduleRedraw()
        }

        /// 新数据载入时地球转向数据中心
        private func aimGlobe(at track: TrackData) {
            let lat = (track.bbox.minLat + track.bbox.maxLat) / 2
            let lon = (track.bbox.minLon + track.bbox.maxLon) / 2
            globeYaw = -Float(lon * Double.pi / 180)
            globePitch = Float(max(-85, min(85, lat)) * Double.pi / 180)
            scheduleRedraw()
        }

        /// 拖拽旋转的共用增量（trackball 手感：拖过球投影半径 ≈ 转 1 弧度）
        private func applyGlobeRotation(dx: CGFloat, dy: CGFloat) {
            noteActivity()
            globeReturnAnim = nil   // 手动旋转接管，取消返回缓动
            guard let container else { return }
            let hPt = Float(container.bounds.height)
            guard hPt > 1 else { return }
            let projR = max(40, (hPt / 2) * tan(asin(min(1, 1 / globeDist)))
                                / tan(MetalPointRenderer.globeFovY / 2))
            let k = 1.0 / projR
            globeYaw = remainder(globeYaw + Float(dx) * k, 2 * Float.pi)
            globePitch = max(-1.55, min(1.55, globePitch + Float(dy) * k))
            interactionTick()
        }

        /// 拖拽 = 只旋转，大小绝不变（非删除模式的左键；删除模式下左键留给套索）
        @objc private func handleGlobePan(_ g: NSPanGestureRecognizer) {
            guard globeActive, let container else { return }
            switch g.state {
            case .began, .changed:
                let t = g.translation(in: container)
                g.setTranslation(.zero, in: container)
                applyGlobeRotation(dx: t.x, dy: t.y)
            default:
                break
            }
        }

        /// 滚轮 = 只缩放（对数步进）；放大穿过衔接比例尺 → 自动滑回平面
        private func globeZoomWheel(deltaY: CGFloat, precise: Bool) {
            noteActivity()
            globeReturnAnim = nil   // 手动缩放接管，取消返回缓动
            guard globeActive else { return }
            let s = precise ? 0.004 : 0.06
            globeDist = min(12.0, max(1.22, globeDist * Float(exp(-Double(deltaY) * s))))
            maybeReturnToMap()
            interactionTick()
        }

        /// 触控板捏合 = 缩放
        private func globeMagnify(_ m: CGFloat) {
            noteActivity()
            globeReturnAnim = nil   // 手动缩放接管，取消返回缓动
            guard globeActive else { return }
            let factor = Float(1.0 / max(0.2, 1.0 + Double(m)))
            globeDist = min(12.0, max(1.22, globeDist * factor))
            maybeReturnToMap()
            interactionTick()
        }

        /// 放大穿过回程阈值即自动回平面地图
        private func maybeReturnToMap() {
            guard globeActive, CACurrentMediaTime() >= transitionCooldown else { return }
            if Double(globeDist) <= globeReturnDist {
                switchToMap()
            }
        }

        /// 数据总览式进入地球（载入横跨大洲/全球的数据时）：
        /// 转向数据中心，拉到全球观感距离；回程阈值按可显示的返回比例尺重算
        private func enterGlobeOverview(for track: TrackData) {
            if !globeActive { switchToGlobe() }
            aimGlobe(at: track)
            globeDist = 3.2
            globeReturnDist = max(1.30, dFromGround(Self.groundReturn) * 0.97)
            scheduleRedraw()
        }

        // MARK: 像素地球（聚合重建 + 地名标签层）

        /// 地形点阵懒生成（首次进入像素模式一次）+ 数据聚合重建（数据/筛选变化时）
        private func rebuildPixelDataIfNeeded() {
            guard let renderer else { return }
            if !renderer.hasPixelTerrain {
                renderer.setPixelTerrain(PixelGlobe.terrainDots())
            }
            guard pixelCellsDirty else { return }
            pixelCellsDirty = false
            if let track = store.track {
                let (cells, counts) = PixelGlobe.aggregate(track: track,
                                                           range: store.visibleIndexRange())
                renderer.setPixelCells(cells)
                pixelLabels = PixelGlobe.labels(cells: cells, counts: counts)
            } else {
                renderer.setPixelCells([])
                pixelLabels = []
            }
            rebuildLabelNodes()
        }

        /// 重建标签图层（城市集合变化时）；逐帧只改位置/透明度
        private func rebuildLabelNodes() {
            guard let host = container?.labelHost.layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for n in labelNodes { n.text.removeFromSuperlayer(); n.dot.removeFromSuperlayer() }
            labelNodes.removeAll()
            let scale = container?.window?.backingScaleFactor ?? 2.0
            for item in pixelLabels {
                let text = CATextLayer()
                text.string = item.city.name
                text.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                text.fontSize = 11
                text.alignmentMode = .left
                text.contentsScale = scale
                text.shadowColor = NSColor.black.cgColor
                text.shadowOpacity = 0.8
                text.shadowRadius = 2
                text.shadowOffset = .zero
                let w = (item.city.name as NSString).size(
                    withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width
                text.frame = CGRect(x: 0, y: 0, width: w + 4, height: 15)
                let dot = CALayer()
                dot.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
                dot.cornerRadius = 2.5
                host.addSublayer(dot)
                host.addSublayer(text)
                labelNodes.append((item.unit, text, dot))
            }
            CATransaction.commit()
        }

        /// 逐帧标签定位：投影到屏幕，背面隐藏，靠近边缘淡出
        private func updateLabels(pixel: Bool, dark: Bool) {
            guard let container else { return }
            // globeActive 门控：切回平面的淡出期间（globeVisible 仍真）不得再显示
            let show = pixel && globeActive && store.settings.showPixelLabels && !labelNodes.isEmpty
            container.labelHost.isHidden = !show
            guard show else { return }
            let b = container.bounds
            let horizon = 1.0 / Double(globeDist)
            let fg = dark ? NSColor.white.cgColor
                          : NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
            let dotC = dark ? NSColor.white.cgColor
                            : NSColor(calibratedWhite: 0.10, alpha: 1).cgColor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for node in labelNodes {
                let pr = rotXd(Double(globePitch)) * (rotYd(Double(globeYaw)) * node.unit)
                guard pr.z > horizon + 0.03, let pt = globeProject(node.unit, bounds: b) else {
                    node.text.isHidden = true
                    node.dot.isHidden = true
                    continue
                }
                // 靠近地平线渐隐
                let fade = Float(min(1, (pr.z - horizon - 0.03) / 0.15))
                node.text.isHidden = false
                node.dot.isHidden = false
                node.text.opacity = fade
                node.dot.opacity = fade * 0.95
                node.text.foregroundColor = fg
                node.dot.backgroundColor = dotC
                node.dot.position = pt
                node.text.position = CGPoint(x: pt.x + 8 + node.text.bounds.width / 2,
                                             y: pt.y - 10)
            }
            CATransaction.commit()
        }

        private func setLabelsHidden(_ hidden: Bool) {
            container?.labelHost.isHidden = hidden
        }

        // MARK: 地球拾取（光线-球体求交 → vDSP 弦距最近邻 → 投影校验）

        private func rotXd(_ a: Double) -> simd_double3x3 {
            let c = cos(a), s = sin(a)
            return simd_double3x3(columns: (SIMD3<Double>(1, 0, 0),
                                            SIMD3<Double>(0, c, s),
                                            SIMD3<Double>(0, -s, c)))
        }

        private func rotYd(_ a: Double) -> simd_double3x3 {
            let c = cos(a), s = sin(a)
            return simd_double3x3(columns: (SIMD3<Double>(c, 0, -s),
                                            SIMD3<Double>(0, 1, 0),
                                            SIMD3<Double>(s, 0, c)))
        }

        /// 把球面单位向量（含抬升缩放）投到视图坐标（pt）。背面（地平线外）返回 nil。
        private func globeProject(_ u: SIMD3<Double>, liftScale: Double = 1.0,
                                  bounds b: CGRect) -> CGPoint? {
            let pr = (rotXd(Double(globePitch)) * (rotYd(Double(globeYaw)) * u)) * liftScale
            let dist = Double(globeDist)
            guard pr.z > (1.0 / dist) * 0.985 else { return nil }   // 地平线剔除
            let tanH = Double(tan(MetalPointRenderer.globeFovY / 2))
            let aspect = Double(b.width / b.height)
            let invVz = 1.0 / (dist - pr.z)
            let ndcX = pr.x * invVz / (tanH * aspect)
            let ndcY = pr.y * invVz / tanH
            return CGPoint(x: (ndcX + 1) / 2 * b.width,
                           y: (1 - ndcY) / 2 * b.height)
        }

        /// 地球模式命中测试：光标光线与球面求交得到查询向量，
        /// vDSP 在跳步/筛选子区间上做弦距 argmin，再投回屏幕按像素半径校验
        private func globeHitTest(at p: CGPoint) -> Int? {
            guard let container, let track = store.track, track.count > 0 else { return nil }
            let b = container.bounds
            guard b.width > 1, b.height > 1 else { return nil }
            let dist = Double(globeDist)
            let tanH = Double(tan(MetalPointRenderer.globeFovY / 2))
            let aspect = Double(b.width / b.height)
            let ndcX = Double(p.x / b.width) * 2 - 1
            let ndcY = 1 - Double(p.y / b.height) * 2
            let dir = simd_normalize(SIMD3<Double>(ndcX * tanH * aspect, ndcY * tanH, -1))
            let c = SIMD3<Double>(0, 0, -dist)
            let b2 = simd_dot(dir, c)
            let disc = b2 * b2 - (simd_dot(c, c) - 1)
            guard disc >= 0 else { return nil }                // 光标不在球上
            let t = b2 - disc.squareRoot()
            guard t > 0 else { return nil }
            let pRot = t * dir - c                             // 旋转后模型坐标（球心原点）
            // 逆旋转回数据坐标：u = Ry(-yaw)·Rx(-pitch)·pRot
            let q = rotYd(-Double(globeYaw)) * (rotXd(-Double(globePitch)) * pRot)

            let t0 = DispatchTime.now().uptimeNanoseconds
            guard let (idx, _) = track.nearestOnGlobe(query: q, stride: lastLodStride,
                                                      range: store.visibleIndexRange()) else { return nil }
            let micros = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e3
            store.pushHoverMicros(micros)

            let u = SIMD3<Double>(Double(track.unitX[idx]), Double(track.unitY[idx]),
                                  Double(track.unitZ[idx]))
            let lift = 1.0 + 0.004 + Double(track.liftF[idx])   // 与渲染同款抬升
            guard let sp = globeProject(u, liftScale: lift, bounds: b) else { return nil }
            let distPt = Double(hypot(sp.x - p.x, sp.y - p.y))
            let hitRadius = store.settings.pointSize + 6.0
            return distPt <= hitRadius ? idx : nil
        }

        /// 地球视角 LOD：沿用"中位段长"模型。
        /// 世界墨卡托宽 1 ↔ 赤道弧长 2π（球半径 1）；
        /// 屏幕像素/单位弧长 = (高/2) / (tan(fov/2)·相机到球面距离)。
        private func globeLodStride(visibleLen: Int) -> Int {
            guard store.settings.lodEnabled,
                  let track = store.track, visibleLen > 60_000,
                  track.medianSegMerc > 0, let container else { return 1 }
            let hPx = Double(container.overlay.metalLayer.drawableSize.height)
            guard hPx > 1 else { return 1 }
            let surf = Double(max(globeDist - 1, 0.05))
            let pxPerUnit = (hPx / 2) / (Double(tan(MetalPointRenderer.globeFovY / 2)) * surf)
            let segPx = track.medianSegMerc * 2 * .pi * pxPerUnit
            let targetPx = lodTargetPx()
            guard segPx < targetPx else { return 1 }
            var stride = Int((targetPx / segPx).rounded(.up))
            stride = min(stride, max(1, visibleLen / 20_000))
            return max(1, min(stride, 4096))
        }

        /// 自绘比例尺：1-2-5 取整，目标宽约 90pt
        private func updateScaleBar() {
            guard let container else { return }
            let mapView = container.mapView
            let boundsW = Double(container.bounds.width)
            guard boundsW > 1 else { return }
            let metersPerMapPoint = MKMetersPerMapPointAtLatitude(mapView.centerCoordinate.latitude)
            let metersAcross = mapView.visibleMapRect.size.width * metersPerMapPoint
            let metersPerPt = metersAcross / boundsW
            guard metersPerPt > 0, metersPerPt.isFinite else { return }
            let target = metersPerPt * 90
            let exp = pow(10.0, floor(log10(target)))
            let base = target / exp
            let nice: Double = base >= 5 ? 5 : (base >= 2 ? 2 : 1)
            let dist = nice * exp
            let widthPt = CGFloat(dist / metersPerPt)
            let label: String
            if dist >= 1000 {
                let km = dist / 1000
                label = km == km.rounded() ? String(format: "%.0f km", km) : String(format: "%.1f km", km)
            } else {
                label = String(format: "%.0f m", dist)
            }
            store.pushScaleBar(ScaleBarInfo(widthPt: widthPt, label: label))
        }

        // MARK: 手绘套索圈选

        @objc private func handleSelectionPan(_ g: NSPanGestureRecognizer) {
            noteActivity()
            guard let container, store.deleteMode, store.track != nil else { return }

            let p = g.location(in: container)
            switch g.state {
            case .began:
                lassoPoints = [p]
                store.selectionPath = lassoPoints
            case .changed:
                // 3pt 最小间距降采样，路径顶点数有界（PIP 成本可控）
                if let last = lassoPoints.last,
                   hypot(p.x - last.x, p.y - last.y) >= 3 {
                    lassoPoints.append(p)
                    store.selectionPath = lassoPoints
                }
            case .ended:
                let path = lassoPoints
                lassoPoints = []
                store.selectionPath = nil
                if path.count >= 3 {
                    selectLasso(path)     // 首尾自动连线闭合
                }
            case .cancelled, .failed:
                lassoPoints = []
                store.selectionPath = nil
            default:
                break
            }
        }

        /// 删除模式下的右键拖拽：平面 = 平移地图，地球 = 旋转地球
        @objc private func handleRightPan(_ g: NSPanGestureRecognizer) {
            guard let container, store.deleteMode else { return }
            if globeActive {
                switch g.state {
                case .began, .changed:
                    let t = g.translation(in: container)
                    g.setTranslation(.zero, in: container)
                    applyGlobeRotation(dx: t.x, dy: t.y)
                default:
                    break
                }
                return
            }
            let mapView = container.mapView
            switch g.state {
            case .began:
                rightPanStartRect = mapView.visibleMapRect
                rightPanStartLoc = g.location(in: container)
            case .changed:
                let loc = g.location(in: container)
                let b = container.bounds
                guard b.width > 0, b.height > 0 else { return }
                let dx = Double(loc.x - rightPanStartLoc.x) * rightPanStartRect.size.width / Double(b.width)
                let dy = Double(loc.y - rightPanStartLoc.y) * rightPanStartRect.size.height / Double(b.height)
                var r = rightPanStartRect
                r.origin.x -= dx
                r.origin.y -= dy
                mapView.visibleMapRect = r        // 触发 didChangeVisibleRegion → vsync 重绘
            default:
                break
            }
        }

        /// 手绘路径（视图坐标）→ 命中点集（首尾自动闭合，只做预删除标记）。
        /// 平面：反投影成墨卡托多边形做 PIP；
        /// 地球：屏幕空间 PIP + 地平线剔除（绝不误选球背面的点）。
        private func selectLasso(_ path: [CGPoint]) {
            guard let container, let track = store.track else { return }
            let bounds = container.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }

            if globeActive {
                let poly = path.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
                let hit = track.indicesOnGlobe(
                    inPolygon: poly,
                    yaw: Double(globeYaw), pitch: Double(globePitch),
                    dist: Double(globeDist),
                    tanHalfFov: Double(tan(MetalPointRenderer.globeFovY / 2)),
                    viewW: Double(bounds.width), viewH: Double(bounds.height),
                    range: store.visibleIndexRange())
                if !hit.isEmpty { store.stagePoints(hit) }
                return
            }

            let world = MKMapRect.world.size.width
            let r = container.mapView.visibleMapRect
            let poly = path.map { p in
                SIMD2<Double>(
                    r.origin.x / world + Double(p.x / bounds.width) * (r.size.width / world),
                    r.origin.y / world + Double(p.y / bounds.height) * (r.size.height / world))
            }
            let hit = track.indices(inPolygon: poly, range: store.visibleIndexRange())
            if !hit.isEmpty {
                store.stagePoints(hit)   // 只做预删除标记，不动真实数据
            }
        }

        /// 抽稀后的目标屏幕间距（物理像素）：随点半径自适应。
        /// 定值 0.75px 在默认点径（~14 物理像素）下意味着每个屏幕位置叠画
        /// 十几层，纯属重涂；间距放宽到 1.2×半径 时相邻点仍重叠 40%、
        /// 轨迹视觉上连续，实例数省一个数量级。点径调小时自动回落，保底 1px。
        private func lodTargetPx() -> Double {
            let radiusPx = store.settings.pointSize * Double(container?.overlay.backingScale ?? 2)
            return max(1.0, radiusPx * 1.2)
        }

        /// 视口自适应降采样（中位段长模型，随比例尺连续变化）。
        ///
        /// 抽稀率只取决于一个量：**典型相邻点在屏幕上的间距**（中位段长 × px/merc）。
        /// 间距远小于目标值说明点在屏幕上大量互相覆盖，画了也是重涂——
        ///   stride = ceil(目标间距 / 屏幕中位间距)
        /// 纯比例尺驱动：放大 → 间距变大 → stride 连续降到 1；与行政区尺度无关。
        /// 用中位数而非总长/均值：三年备份里成千上万条轨迹首尾拼接产生的
        /// "瞬移"长段会把总长灌水几个数量级，中位数对此免疫。
        private func lodStride(camera: CameraRect, visibleLen: Int) -> Int {
            guard store.settings.lodEnabled,
                  let track = store.track, visibleLen > 60_000,
                  track.medianSegMerc > 0 else { return 1 }
            let pxPerMerc = camera.pxW / camera.w
            let segPx = track.medianSegMerc * pxPerMerc     // 相邻点屏幕间距（物理像素）
            let targetPx = lodTargetPx()
            guard segPx < targetPx else { return 1 }
            var stride = Int((targetPx / segPx).rounded(.up))
            // 下限保护：至少保留 2 万点
            stride = min(stride, max(1, visibleLen / 20_000))
            return max(1, min(stride, 4096))
        }

        /// 轨迹线样式（SwiftUI Color → sRGB 分量，逐次重绘换算，开销可忽略）
        private func lineParams(scale: Double) -> LineParams? {
            let s = store.settings
            // 多段/多日轨迹：连线无意义且耗性能，强制禁用
            guard s.showTrackLine, store.track?.isMultiSegment != true else { return nil }
            let ns = NSColor(s.lineColor).usingColorSpace(.sRGB)
            let color = SIMD4<Float>(
                Float(min(max(ns?.redComponent ?? 1.0, 0), 1)),
                Float(min(max(ns?.greenComponent ?? 0.42, 0), 1)),
                Float(min(max(ns?.blueComponent ?? 0.21, 0), 1)),
                Float(s.lineOpacity))
            return LineParams(
                widthPx: Float(s.lineWidth * scale),
                headLenPx: Float((s.lineWidth * 2.5 + 6.0) * scale),
                headWidthPx: Float((s.lineWidth * 2.0 + 4.5) * scale),
                color: color,
                arrows: s.showArrows)
        }

        // MARK: MKMapViewDelegate

        nonisolated func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            MainActor.assumeIsolated {
                // 慢速拖拽只发 mouseDragged（不触发 mouseMoved），此回调是唯一信号。
                // 闲置动画自身也在推相机，必须用 idleAnim 门控防自打断
                if !idleAnim { noteActivity() }
                interactionTick()
            }
        }

        nonisolated func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            MainActor.assumeIsolated {
                if !idleAnim { noteActivity() }   // 同上
                interactionTick()
                scheduleRedraw()   // 最终停稳再补一帧
            }
        }

        // MARK: 拾取（合并到每帧一次）

        private func queueHover(at p: CGPoint) {
            noteActivity()
            pendingHover = p
            guard !hoverScheduled else { return }
            hoverScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hoverScheduled = false
                if let point = self.pendingHover {
                    self.processHover(at: point)
                }
            }
        }

        private func hitTest(at viewPoint: CGPoint) -> Int? {
            if globeActive {
                if store.settings.globeStyle == .pixel { return nil }   // 聚合视图无逐点拾取
                return globeHitTest(at: viewPoint)
            }
            guard let container, let track = store.track, track.count > 0 else { return nil }
            let bounds = container.bounds
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            let world = MKMapRect.world.size.width
            let r = container.mapView.visibleMapRect
            let mercW = r.size.width / world
            let mercH = r.size.height / world
            let qx = r.origin.x / world + Double(viewPoint.x / bounds.width) * mercW
            let qy = r.origin.y / world + Double(viewPoint.y / bounds.height) * mercH

            let t0 = DispatchTime.now().uptimeNanoseconds
            guard let (idx, mercDist) = track.nearestPoint(mercX: qx, mercY: qy,
                                                           stride: lastLodStride,
                                                           range: store.visibleIndexRange()) else { return nil }
            let micros = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e3
            store.pushHoverMicros(micros)

            let distPt = mercDist / mercW * Double(bounds.width)
            let hitRadius = store.settings.pointSize + 6.0
            return distPt <= hitRadius ? idx : nil
        }

        private func processHover(at p: CGPoint) {
            guard let track = store.track else { return }
            let hit = hitTest(at: p)
            let newHover = hit.map { track.info(at: $0, screenPoint: p) }
            if newHover != store.hover {
                store.hover = newHover     // 仅在变化时发布
            }
            let newHighlight = hit ?? store.selected?.index
            if newHighlight != highlightIndex {
                highlightIndex = newHighlight
                scheduleRedraw()
            }
        }

        private func clearHover() {
            pendingHover = nil
            if store.hover != nil { store.hover = nil }
            let newHighlight = store.selected?.index
            if newHighlight != highlightIndex {
                highlightIndex = newHighlight
                scheduleRedraw()
            }
        }

        @objc private func handleClick(_ g: NSClickGestureRecognizer) {
            noteActivity()
            guard let container, g.state == .ended, let track = store.track,
                  !store.deleteMode else { return }
            let p = g.location(in: container)
            if let idx = hitTest(at: p) {
                store.selected = track.info(at: idx, screenPoint: p)
                highlightIndex = idx
            } else {
                store.selected = nil
                highlightIndex = nil
            }
            scheduleRedraw()
        }

        // 与地图自身的拖拽/双击手势并存
        nonisolated func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                                           shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool {
            true
        }

        // 拖拽手势按模式分流：
        // - 地球旋转（左键）只在地球且非删除模式启动（删除模式左键留给套索）
        // - 圈选/右键手势只在删除模式启动（平面与地球都适用）
        nonisolated func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            MainActor.assumeIsolated {
                if gestureRecognizer === globePanGR {
                    return globeActive && !store.deleteMode
                }
                if gestureRecognizer is NSPanGestureRecognizer {
                    return store.deleteMode
                }
                return true
            }
        }
    }
}

// MARK: - 对比模式（两文件左右分屏，区域/设置完全同步）

/// 对比模式的单侧容器：地图 + 压暗层 + Metal 覆盖层（复用主视图的层类型）
final class ComparePaneView: NSView {
    let mapView = MKMapView()
    let dimView = PassthroughDimView()
    let overlay = MetalOverlayView()

    override var isFlipped: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(mapView)
        addSubview(dimView)
        addSubview(overlay)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        mapView.frame = bounds
        dimView.frame = bounds
        overlay.frame = bounds
    }
}

/// 左右分屏容器：两个 Pane + 1pt 分隔线，各占一半
final class CompareSplitView: NSView {
    let left = ComparePaneView()
    let right = ComparePaneView()
    private let divider = NSView()

    override var isFlipped: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(left)
        addSubview(right)
        addSubview(divider)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        let w = floor(bounds.width / 2)
        left.frame = CGRect(x: 0, y: 0, width: w, height: bounds.height)
        right.frame = CGRect(x: w + 1, y: 0, width: bounds.width - w - 1, height: bounds.height)
        divider.frame = CGRect(x: w, y: 0, width: 1, height: bounds.height)
    }
}

/// SwiftUI 封装：对比模式整体
struct CompareMapView: NSViewRepresentable {
    @ObservedObject var store: TrackStore

    func makeCoordinator() -> CompareCoordinator { CompareCoordinator(store: store) }

    func makeNSView(context: Context) -> CompareSplitView {
        let v = CompareSplitView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        context.coordinator.attach(v)
        return v
    }

    func updateNSView(_ nsView: CompareSplitView, context: Context) {
        context.coordinator.sync()
    }

    @MainActor
    final class CompareCoordinator: NSObject, MKMapViewDelegate {
        private let store: TrackStore
        private weak var split: CompareSplitView?
        private var rendererL: MetalPointRenderer?
        private var rendererR: MetalPointRenderer?
        private var shownTrackIDs: [UUID] = []      // [左, 右] 已上传的轨迹
        private var shownSettings = ViewSettings()
        private var syncing = false                  // 区域同步防回环
        private var redrawScheduled = false
        private var didInitialZoom = false

        init(store: TrackStore) {
            self.store = store
            super.init()
        }

        func attach(_ split: CompareSplitView) {
            self.split = split
            for pane in [split.left, split.right] {
                pane.mapView.delegate = self
                pane.mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
                pane.mapView.isRotateEnabled = false
                pane.mapView.isPitchEnabled = false
                pane.mapView.showsZoomControls = false
                pane.dimView.alphaValue = CGFloat(1.0 - store.settings.mapOpacity)
                pane.overlay.onGeometryChange = { [weak self] in self?.scheduleRedraw() }
            }
            applyMapStyle()
            rendererL = MetalPointRenderer()
            rendererR = MetalPointRenderer()
            if let r = rendererL { split.left.overlay.metalLayer.device = r.device }
            if let r = rendererR { split.right.overlay.metalLayer.device = r.device }
            shownSettings = store.settings
            sync()
        }

        /// 左右轨迹（compareSwap 决定 files[0] 在哪侧）
        private func sideTracks() -> (l: TrackData, r: TrackData)? {
            guard let ts = store.compareTracks, ts.count == 2 else { return nil }
            return store.compareSwap ? (ts[1], ts[0]) : (ts[0], ts[1])
        }

        func sync() {
            guard let split else { return }
            // 数据/交换变化 → 重新上传两侧缓冲
            if let (tl, tr) = sideTracks() {
                let ids = [tl.id, tr.id]
                if ids != shownTrackIDs {
                    shownTrackIDs = ids
                    rendererL?.setData(track: tl)
                    rendererR?.setData(track: tr)
                    if !didInitialZoom {
                        didInitialZoom = true
                        zoomToUnion(tl, tr)
                    }
                    scheduleRedraw()
                }
            } else if !shownTrackIDs.isEmpty {
                shownTrackIDs = []
                rendererL?.clearData()
                rendererR?.clearData()
                scheduleRedraw()
            }
            // 设置变化（点大小/透明、底图透明度、底图样式对两侧同时生效）
            if store.settings != shownSettings {
                let old = shownSettings
                shownSettings = store.settings
                if old.mapOpacity != store.settings.mapOpacity {
                    let dim = CGFloat(1.0 - store.settings.mapOpacity)
                    split.left.dimView.alphaValue = dim
                    split.right.dimView.alphaValue = dim
                }
                if old.mapStyle != store.settings.mapStyle { applyMapStyle() }
                scheduleRedraw()
            }
        }

        private func applyMapStyle() {
            guard let split else { return }
            for pane in [split.left, split.right] {
                switch store.settings.mapStyle {
                case .standard:
                    pane.mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
                case .imagery:
                    pane.mapView.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
                case .hybrid:
                    pane.mapView.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .flat)
                }
            }
        }

        /// 初始视野：两条轨迹外接框的并集
        private func zoomToUnion(_ a: TrackData, _ b: TrackData) {
            guard let split else { return }
            let minLat = min(a.bbox.minLat, b.bbox.minLat)
            let maxLat = max(a.bbox.maxLat, b.bbox.maxLat)
            let minLon = min(a.bbox.minLon, b.bbox.minLon)
            let maxLon = max(a.bbox.maxLon, b.bbox.maxLon)
            let p1 = MKMapPoint(CLLocationCoordinate2D(latitude: maxLat, longitude: minLon))
            let p2 = MKMapPoint(CLLocationCoordinate2D(latitude: minLat, longitude: maxLon))
            var rect = MKMapRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                                 width: max(1000, abs(p1.x - p2.x)),
                                 height: max(1000, abs(p1.y - p2.y)))
            rect = rect.insetBy(dx: -rect.size.width * 0.14, dy: -rect.size.height * 0.14)
            syncing = true
            split.left.mapView.setVisibleMapRect(rect, animated: false)
            split.right.mapView.setVisibleMapRect(rect, animated: false)
            syncing = false
        }

        // MARK: 区域双向同步（拖一边另一边跟随）

        nonisolated func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            MainActor.assumeIsolated { mirrorRegion(from: mapView) }
        }

        nonisolated func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            MainActor.assumeIsolated { mirrorRegion(from: mapView) }
        }

        private func mirrorRegion(from mapView: MKMapView) {
            guard let split, !syncing else { return }
            let other = mapView === split.left.mapView ? split.right.mapView : split.left.mapView
            syncing = true
            other.setVisibleMapRect(mapView.visibleMapRect, animated: false)
            syncing = false
            scheduleRedraw()
        }

        // MARK: 渲染（合并到 runloop 尾部，一次画两侧）

        private func scheduleRedraw() {
            guard !redrawScheduled else { return }
            redrawScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.redrawScheduled = false
                self.performRedraw()
            }
        }

        private func performRedraw() {
            guard let split, let (tl, tr) = sideTracks() else { return }
            renderSide(pane: split.left, renderer: rendererL, track: tl)
            renderSide(pane: split.right, renderer: rendererR, track: tr)
        }

        private func renderSide(pane: ComparePaneView, renderer: MetalPointRenderer?, track: TrackData) {
            guard let renderer else { return }
            let r = pane.mapView.visibleMapRect
            let world = MKMapRect.world.size.width
            guard r.size.width > 0, r.size.height > 0,
                  pane.overlay.metalLayer.drawableSize.width > 1 else { return }
            let camera = CameraRect(
                x0: r.origin.x / world,
                y0: r.origin.y / world,
                w: r.size.width / world,
                h: r.size.height / world,
                pxW: Double(pane.overlay.metalLayer.drawableSize.width),
                pxH: Double(pane.overlay.metalLayer.drawableSize.height))
            let scale = Double(pane.overlay.backingScale)
            // 与主视图同一套中位段长 LOD 模型（对比模式禁用轨迹线，只画点）
            let stride = compareLodStride(track: track, camera: camera, scale: scale)
            renderer.render(
                layer: pane.overlay.metalLayer,
                camera: camera,
                pointSizePx: store.settings.pointSize * scale,
                opacity: store.settings.opacity,
                halo: store.settings.showHalo,
                line: nil,
                highlight: nil,
                lodStride: stride,
                range: nil)
        }

        private func compareLodStride(track: TrackData, camera: CameraRect, scale: Double) -> Int {
            guard store.settings.lodEnabled, track.count > 60_000,
                  track.medianSegMerc > 0 else { return 1 }
            let pxPerMerc = camera.pxW / camera.w
            let segPx = track.medianSegMerc * pxPerMerc
            let radiusPx = store.settings.pointSize * scale
            let targetPx = max(1.0, radiusPx * 1.2)
            guard segPx < targetPx else { return 1 }
            var stride = Int((targetPx / segPx).rounded(.up))
            stride = min(stride, max(1, track.count / 20_000))
            return max(1, min(stride, 4096))
        }
    }
}

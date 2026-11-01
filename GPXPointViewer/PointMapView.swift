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
import MetalKit
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

/// 已经收到 willClose 的窗口。SwiftUI 会继续评估已关闭窗口的视图树：共享 store 切换对比模式时，
/// 关掉的窗口里会再造一个 PointMapView/协调器——它挂到的窗口早就关了，willClose 不会再来，
/// 必须在挂载时就识别出来直接拆掉
@MainActor
enum ClosedWindowRegistry {
    private final class Weak { weak var window: NSWindow?; init(_ w: NSWindow) { window = w } }
    private static var closed: [Weak] = []
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                closed.removeAll { $0.window == nil }
                if !closed.contains(where: { $0.window === w }) { closed.append(Weak(w)) }
            }
        }
    }

    static func isClosed(_ window: NSWindow) -> Bool {
        closed.contains { $0.window === window }
    }
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
    var onWindowChanged: ((NSWindow?) -> Void)?

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?(window)
    }

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
    let fillOverlay: FillOverlayState          // 本窗口的补点覆盖层投影（多窗口各自一份，命中测试只用自己的）

    func makeCoordinator() -> Coordinator { Coordinator(store: store, fillOverlay: fillOverlay) }

    /// 表示层被移除（对比模式切换）：显示链接持有协调器，deinit 不会跑——显式拆掉。
    /// WindowGroup 关窗不会走到这里（实测），关窗由协调器监听 NSWindow.willCloseNotification 处理
    static func dismantleNSView(_ nsView: MapContainerView, coordinator: Coordinator) {
        coordinator.teardown()
    }

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
        private let fillOverlay: FillOverlayState
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
        private var shownFillVersion = 0
        private var shownFillColorVersion = 0
        private var shownFillMode = false
        /// 批量草稿折线的地图点坐标缓存（按处 id；签名变了才重建）。屏幕投影只差一个线性变换，
        /// 比每帧对几千处逐顶点 MKMapView.convert 便宜几个量级
        private var batchMapPointCache: [String: (sig: Int, pts: [MKMapPoint])] = [:]
        private var shownFillFocusVersion = 0
        private var shownMapFocusVersion = 0
        private var shownFilterKey = ""
        private var shownFlashVersion = 0
        private var shownLocateVersion = 0
        private var shownRegionFocusVersion = 0
        private var regionOverlays: [MKOverlay] = []      // 地区统计：当前高亮的边界多边形
        private let baseMap = BaseMapApplier()            // 底图来源（Apple 配置 / 外部瓦片 overlay）
        private let tunnels = TunnelLayer(name: "main")   // 叠加 OSM 隧道
        private var shownFwdbVersion = 0
        private var shownFwdbZoomVersion = 0
        private var shownFogMask: UInt32 = .max
        // .fwdb 存档实例缓存：带 75% 边距的视口矩形 + 请求级别，越界/换级才重建
        private var fwdbCacheRect: (x0: Double, y0: Double, x1: Double, y1: Double)?
        private var fwdbCacheLevel = -1
        private var fwdbCacheGen = Int.max

        // 3D 热力柱：轨道相机 + 场景缓存
        private var shownHeat3D = false
        private var heat3DYaw: Float = 0.55
        private var heat3DPitch: Float = 0.95
        private var heat3DDist: Float = 3.2
        private var heat3DTarget = SIMD2<Float>(0, 0)
        private var heat3DSceneKey = ""
        private var heat3DScene: Heat3DScene?
        private var heat3DGroundKey = ""
        private var heat3DBuildGen = 0
        private var heat3DWantFocus = false
        private var heat3DMinDist: Float = 1e-4
        private var heat3DEntryMerc: (x: Double, y: Double, w: Double)?
        private var heat3DNorthAnim: (from: Float, start: Double)?
        private var shownHeat3DNorthPoke = 0

        // 时光机回放
        private var shownPlaybackID: ObjectIdentifier?
        private var shownPlaybackPoke = 0
        private var playbackLastTick: Double?
        private var playbackCameraDetached = false
        /// 城市章节回放：当前已绑定逐点区域数据的会话（DeepSeek 2026-10-31）
        private var shownPlaybackRevealID: ObjectIdentifier?
        private var shownPlaybackRevealVersion = -1
        // 时光机瓦片门控：相机落定但底图瓦片还在加载时，播放头原地等待
        //（"地图移动到位之后再画"包括瓦片渲染到位；上限防弱网卡死）
        private var mapTilesLoading = false
        private var playbackStallStart: Double?
        private var shownVideoExportVersion = 0
        private var heat3DLocalKey = ""
        private var heat3DLocalStamp = 0.0

        /// 3D 热力模式生效条件（对比/删除模式与无轨迹时不进入）
        var heat3DOn: Bool {
            store.settings.heatMap && store.settings.heat3D
                && store.track != nil && !store.deleteMode && !store.fillMode
                && store.playback == nil       // 回放期间不接管（关掉回放即生效）
        }
        private var shownImageExportVersion = 0
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
        private var fillDragMonitor: Any?
        private enum FillDrag { case vertex(Int), anchor(isA: Bool), midpoint(Int) }   // midpoint = 按在段中点上、尚未拖动
        private var fillDrag: FillDrag?               // 补点模式：正在拖的顶点/锚点
        private var fillDragMoved = false             // 本次拖动是否真的动过（动过才记一步历史）
        private var tornDown = false                  // 窗口已关闭：停掉一切定时/监视/渲染
        private var windowCloseObserver: NSObjectProtocol?

        /// 窗口关闭（或表示层被移除）：停显示链接、卸事件监视器、结束拖动、停闲置检查链。
        /// 关掉的窗口 SwiftUI 仍会继续调 updateNSView → sync()，所以 sync/redraw 也按 tornDown 短路
        func teardown() {
            guard !tornDown else { return }
            tornDown = true
            endFillDrag()
            // 正在闲置展示（⌘W 关窗没有鼠标按下，不会走 noteActivity）：共享的 presenting/地球风格要还回去，
            // 否则剩下的窗口面板一直隐着、风格被改成像素
            if idleAnim || idleReturn != nil {
                idleAnim = false
                if let saved = idleReturn {
                    idleReturn = nil
                    if saved.styleChanged, store.settings.globeStyle != saved.style {
                        store.settings.globeStyle = saved.style
                    }
                }
                if store.presenting { store.presenting = false }
            }
            displayLink?.invalidate()
            displayLink = nil
            for m in [wheelMonitor, magnifyMonitor, mouseDownMonitor, fillDragMonitor] {
                if let m { NSEvent.removeMonitor(m) }
            }
            wheelMonitor = nil; magnifyMonitor = nil; mouseDownMonitor = nil; fillDragMonitor = nil
            if let o = windowCloseObserver { NotificationCenter.default.removeObserver(o) }
            windowCloseObserver = nil
            container?.onWindowChanged = nil
            // 表示层被换掉时（切对比模式）不会再走 sync 的清空分支：这里排队清一次，补点模式外不留旧投影
            let overlay = fillOverlay
            let store = store
            DispatchQueue.main.async { if !store.fillMode { overlay.overlay = TrackStore.FillOverlay() } }
        }

        /// 容器换窗口：改监听新窗口的关闭通知（WindowGroup 关窗不调 dismantleNSView，这是唯一可靠的拆除时机）
        private func observeWindowClose(_ window: NSWindow?) {
            if let o = windowCloseObserver { NotificationCenter.default.removeObserver(o) }
            windowCloseObserver = nil
            guard let window, !tornDown else { return }
            ClosedWindowRegistry.start()
            if ClosedWindowRegistry.isClosed(window) {       // 挂到了一个早已关闭的窗口：直接拆
                teardown()
                return
            }
            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.teardown() }
            }
        }

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
            if let m = fillDragMonitor { NSEvent.removeMonitor(m) }
            if let o = windowCloseObserver { NotificationCenter.default.removeObserver(o) }
        }

        init(store: TrackStore, fillOverlay: FillOverlayState) {
            self.store = store
            self.fillOverlay = fillOverlay
            super.init()
        }

        func attach(_ container: MapContainerView) {
            self.container = container
            // 新建协调器（⌘N 新窗口 / 对比模式切回）：已有的地区高亮只重画，不再飞过去
            shownRegionFocusVersion = store.regionFocusVersion
            if store.regionSelection != nil { DispatchQueue.main.async { [weak self] in self?.applyRegionHighlight(fly: false) } }
            container.onWindowChanged = { [weak self] w in self?.observeWindowClose(w); self?.store.mainWindow = w }
            observeWindowClose(container.window)
            store.mainWindow = container.window
            shownMapFocusVersion = store.mapFocusVersion     // 新协调器不重放旧的「在主地图上看」
            store.mainMapRegion = { [weak self, weak container] in
                guard let self, let container, !self.globeActive else { return nil }
                let r = container.mapView.region
                let km = r.span.longitudeDelta * 111.32 * cos(r.center.latitude * .pi / 180)
                return (r.center.latitude, r.center.longitude, km)
            }
            if UITestHook.enabled {
                UITestHook.shared.surface = container
                UITestHook.shared.topologyStats = { [weak self] in self?.renderer?.topologyDrawStats ?? [:] }
                UITestHook.shared.projectNow = { [weak self] in
                    guard let self else { return }
                    guard self.store.fillMode else {                 // 与正式路径一致：退出后清空，不写回旧投影
                        UITestHook.shared.lastOverlay = TrackStore.FillOverlay()
                        self.fillOverlay.overlay = TrackStore.FillOverlay()
                        return
                    }
                    self.updateFillOverlay()
                    self.fillOverlay.overlay = UITestHook.shared.lastOverlay   // 同步写入，命中测试立刻可用
                }
                UITestHook.shared.debugInfo = { [weak self] in
                    guard let self, let c = self.container else { return "no container" }
                    let r = c.mapView.visibleMapRect
                    let occ = c.window?.occlusionState.contains(.visible) ?? false
                    return "globeActive=\(self.globeActive) heat3D=\(self.heat3DOn) idleAnim=\(self.idleAnim) presenting=\(self.store.presenting) "
                        + "tornDown=\(self.tornDown) linkPaused=\(self.displayLink?.isPaused ?? true) windowVisible=\(occ) "
                        + "window=\(c.window?.windowNumber ?? -1) frame=\(c.window?.frame ?? .zero) bounds=\(c.bounds) "
                        + "rect=\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.size.width))x\(Int(r.size.height)) "
                        + "dist=\(Int(c.mapView.camera.centerCoordinateDistance)) zoomRange=\(c.mapView.cameraZoomRange.maxCenterCoordinateDistance) "
                        + "shownFocus=\(self.shownFillFocusVersion)/\(self.store.fillFocusVersion) fillShown=\(self.shownFillMode)"
                }
            }
            let mapView = container.mapView

            mapView.delegate = self
            // realistic 高程：缩到头时 MapKit 切换成 3D 地球（地球视角的前提）；外部瓦片来源由 BaseMapApplier 退到平面
            baseMap.apply(store.settings.mapStyle, to: mapView, elevation: .realistic)
            tunnels.mapView = mapView
            tunnels.onChange = { [weak self] in
                guard let self else { return }
                let t = self.tunnels.statusText
                if self.store.tunnelStatus != t {
                    DispatchQueue.main.async { [weak self] in self?.store.tunnelStatus = t }   // 可能在视图更新（sync）中触发，推后发布
                }
            }
            tunnels.setEnabled(store.tunnelOverlay)
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
                store.errorMessage = String(localized: "此设备不支持 Metal，无法渲染点云。", comment: "Error alert at startup: this Mac does not support Metal, so the GPS point cloud cannot be drawn")
            }

            container.overlay.onGeometryChange = { [weak self] in self?.scheduleRedraw() }
            container.onMouseMoved = { [weak self] p in
                guard let self, !self.heat3DOn else { return }
                self.queueHover(at: p)
            }
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
                MainActor.assumeIsolated {
                    self.noteActivity()
                    // 时光机播放中任何按下即暂停（相机交还用户）。
                    // 底部 ~110pt 是回放时间轴条：按下先被这里置 false、按钮的
                    // toggle 在抬起时又翻回 true——暂停键永远按不下去，故排除
                    if let pb = self.store.playback, pb.clock.playing,
                       event.window === self.container?.window,
                       event.locationInWindow.y > 110 {
                        self.playbackCameraDetached = true
                        pb.clock.playing = false
                    }
                }
                return event
            }

            // 补点模式的顶点/锚点拖动与右键删顶点：在派发前拦截——按在顶点上的
            // 按下不交给地图（否则地图会跟着平移、点击手势会再加一个顶点）
            fillDragMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                let type = event.type
                let wid = event.window.map(ObjectIdentifier.init)
                let loc = event.locationInWindow
                let option = event.modifierFlags.contains(.option)
                let clicks = (type == .leftMouseDown || type == .rightMouseDown) ? event.clickCount : 1
                let consumed = MainActor.assumeIsolated {
                    self.routeFillMouse(type: type, windowID: wid, locationInWindow: loc, option: option, clickCount: clicks)
                }
                if UITestHook.enabled { UITestHook.log("monitor \(type.rawValue) at \(loc) consumed=\(consumed)") }
                return consumed ? nil : event
            }

            scheduleIdleCheck()
        }

        // MARK: 补点模式鼠标路由（顶点拖动 / 锚点拖动吸附轨迹点 / 右键删顶点）

        private static func nearestIndex(_ p: CGPoint, in pts: [CGPoint], within r: CGFloat) -> Int? {
            var best: Int?
            var bestD = r
            for (i, q) in pts.enumerated() {
                let d = hypot(q.x - p.x, q.y - p.y)
                if d.isFinite, d <= bestD { bestD = d; best = i }
            }
            return best
        }

        /// 点到线段距离（屏幕像素）
        private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let vx = b.x - a.x, vy = b.y - a.y
            let len2 = vx * vx + vy * vy
            let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * vx + (p.y - a.y) * vy) / len2)) : 0
            return hypot(a.x + vx * t - p.x, a.y + vy * t - p.y)
        }

        /// 结束拖动（模式退出、数据换代、抬起都走这里）
        private func endFillDrag() {
            guard fillDrag != nil else { return }
            fillDrag = nil
            fillDragMoved = false
            store.setFillDragging(false)
            scheduleRedraw()
        }

        /// 按下点上方是不是地图本身（SwiftUI 面板/按钮盖在地图上时，按下属于面板，不能被拦截）
        private func pressLandsOnMap(_ container: MapContainerView, window: NSWindow, locationInWindow: NSPoint) -> Bool {
            guard let cv = window.contentView else { return false }
            let pt = cv.superview?.convert(locationInWindow, from: nil) ?? locationInWindow
            guard let hit = cv.hitTest(pt) else {
                if UITestHook.enabled { UITestHook.log("  hitTest nil at \(pt) (cv \(type(of: cv)) frame \(cv.frame))") }
                return false
            }
            if UITestHook.enabled { UITestHook.log("  hit \(type(of: hit)) descendant=\(hit.isDescendant(of: container)) control=\(hit is NSControl)") }
            return hit.isDescendant(of: container) && !(hit is NSControl)
        }

        /// 返回 true = 事件已消费（不再交给地图/手势）
        private func routeFillMouse(type: NSEvent.EventType, windowID: ObjectIdentifier?,
                                    locationInWindow: NSPoint, option: Bool, clickCount: Int) -> Bool {
            // 抬起：无论处于什么模式都先结束拖动（拖动中按 Esc 退出补点也不能留下悬空状态）
            if type == .leftMouseUp {
                guard fillDrag != nil else { return false }
                endFillDrag()
                return true
            }
            // 圈选补点范围时左键拖拽归套索手势，不进顶点编辑
            guard store.fillMode, !store.fillRegionDrawing, let container, let window = container.window,
                  ObjectIdentifier(window) == windowID else {
                if UITestHook.enabled { UITestHook.log("  guard1 fillMode=\(store.fillMode) container=\(self.container != nil) windowMatch=\(self.container?.window.map { ObjectIdentifier($0) == windowID } ?? false)") }
                if fillDrag != nil, type == .leftMouseDragged { endFillDrag() }
                return false
            }
            let p = container.convert(locationInWindow, from: nil)
            switch type {
            case .leftMouseDown, .rightMouseDown:
                // 弹框/模态期间草稿不能再变（否则确认框里的数字就过期了）；⌥点击交给点击手势设锚点
                if UITestHook.enabled {
                    UITestHook.log("  down p=\(p) active=\(store.fillActive) globe=\(globeActive) drag=\(fillDrag != nil) opt=\(option) prompt=\(store.fillPrompt != nil) sheet=\(window.attachedSheet != nil) modal=\(NSApp.modalWindow != nil) inBounds=\(container.bounds.contains(p)) onMap=\(pressLandsOnMap(container, window: window, locationInWindow: locationInWindow))")
                }
                guard store.fillActive, !globeActive, fillDrag == nil, !option, !store.batchActive,
                      store.fillPrompt == nil, store.fillSimilarPrompt == nil,
                      window.attachedSheet == nil, NSApp.modalWindow == nil,
                      container.bounds.contains(p),
                      pressLandsOnMap(container, window: window, locationInWindow: locationInWindow) else { return false }
                let o = fillOverlay.overlay
                // 右键只认顶点（锚点没有右键动作，不参与竞争）
                if type == .rightMouseDown {
                    guard let i = Self.nearestIndex(p, in: o.vertices, within: 10) else { return false }
                    store.removeFillVertex(i)
                    noteActivity()
                    scheduleRedraw()
                    return true
                }
                // 左键：顶点 10px、锚点环 12px，谁更近算谁（过时出口点派生的顶点就挨在 B 旁边，
                // 不能总让顶点赢）；顶点在锚点 2px 内算平手时顶点赢，正好落在锚点上的顶点也抓得到
                var vertexBest: (drag: FillDrag, d: CGFloat)?
                if let i = Self.nearestIndex(p, in: o.vertices, within: 10) {
                    vertexBest = (.vertex(i), hypot(o.vertices[i].x - p.x, o.vertices[i].y - p.y))
                }
                let anchorBest: (drag: FillDrag, d: CGFloat)? = [(o.anchorA, true), (o.anchorB, false)]
                    .compactMap { pt, isA in pt.map { (FillDrag.anchor(isA: isA), hypot($0.x - p.x, $0.y - p.y)) } }
                    .filter { $0.1 <= 12 }
                    .min { $0.1 < $1.1 }
                var best: (drag: FillDrag, d: CGFloat)?
                switch (vertexBest, anchorBest) {
                case (nil, nil): best = nil
                case (let v?, nil): best = v
                case (nil, let a?): best = a
                case (let v?, let a?): best = a.d + 2 < v.d ? a : v
                }
                // 双击顶点 = 删除（和右键等价）
                if clickCount >= 2, case .vertex(let i)? = best?.drag {
                    store.removeFillVertex(i)
                    noteActivity()
                    scheduleRedraw()
                    return true
                }
                if best == nil, let k = Self.nearestIndex(p, in: o.midpoints, within: 9) {
                    best = (.midpoint(k), 0)            // 真拖动了才插入（单击/双击中点什么都不做）
                }
                guard let best else { return false }
                if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }   // 被吞掉的按下不会再走窗口聚焦
                fillDrag = best.drag
                fillDragMoved = false
                store.setFillDragging(true)
                noteActivity()
                scheduleRedraw()
                return true
            case .leftMouseDragged:
                guard let d = fillDrag else { return false }
                guard store.fillActive else { endFillDrag(); return false }
                switch d {
                case .midpoint(let k):
                    // 第一次拖动：在这一段上插入顶点（insert 已记历史），随后当普通顶点拖
                    let c = container.mapView.convert(p, toCoordinateFrom: container)
                    store.insertFillVertex(GeoCoord.mapToData(c), at: k)
                    guard store.fillVertices.indices.contains(k) else { endFillDrag(); return true }
                    fillDrag = .vertex(k)
                    fillDragMoved = true
                case .vertex(let i):
                    if !fillDragMoved { fillDragMoved = true; store.beginFillDrag() }   // 真动了才记一步
                    let c = container.mapView.convert(p, toCoordinateFrom: container)
                    store.moveFillVertex(i, to: GeoCoord.mapToData(c))
                case .anchor(let isA):
                    // 锚点只能是轨迹点：拖到哪个点附近就吸附到哪个点（保持 A < B）；第一次真改动前记一步历史
                    if let idx = hitTest(at: p) {
                        if !fillDragMoved {
                            if store.setFillAnchor(nearest: idx, side: isA, recordHistory: true) { fillDragMoved = true }
                        } else {
                            store.setFillAnchor(nearest: idx, side: isA, recordHistory: false)
                        }
                    }
                }
                scheduleRedraw()
                return true
            default:
                return false
            }
        }

        // MARK: 状态同步（updateNSView 驱动，只做增量工作，不在此渲染）

        func sync() {
            guard let container, !tornDown else { return }

            // 1. 数据换代
            if store.track?.id != shownTrackID {
                shownTrackID = store.track?.id
                endFillDrag()
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
                                  !self.heat3DOn,     // 3D 场景自会按新数据重建，不动地图相机
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
                // 3D 热力场景与数据同生命周期：换代即释放（实例缓冲 + 地面纹理）
                heat3DSceneKey = ""
                heat3DScene = nil
                if heat3DOn {
                    // 3D 开着换数据：旧局部坐标系的相机在新场景里是任意视点
                    // 且距离可能低于新 minDist——重新落位到新数据焦点
                    heat3DEntryMerc = nil
                    heat3DWantFocus = true
                }
                heat3DGroundKey = ""
                heat3DLocalKey = ""
                renderer?.setHeat3D(scene: nil)
                renderer?.setHeat3DGround(texture: nil, rect: SIMD4(-1.2, -1.2, 1.2, 1.2))
                renderer?.setHeat3DLocalGround(texture: nil, rect: SIMD4(0, 0, 0, 0))
                scheduleRedraw()
            }

            // 删除模式 / 补点范围圈选：暂停地图平移，让左键拖拽变成手绘圈选（右键拖拽平移）
            let lassoOn = store.deleteMode || store.fillRegionDrawing
            if lassoOn != shownDeleteMode {
                shownDeleteMode = lassoOn
                container.mapView.isScrollEnabled = !lassoOn
                if !lassoOn, store.selectionPath != nil {
                    DispatchQueue.main.async { [weak self] in self?.store.selectionPath = nil }
                }
            }
            // 2. 只换了颜色
            else if let track = store.track, track.colorVersion != shownColorVersion {
                shownColorVersion = track.colorVersion
                renderer?.updateColors(store.fillDisplayColors ?? store.stagedDisplayColors ?? track.colors)
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
            // 2b'. 补点：锚点/顶点变化 → 区间内待删点橙色高亮 + 重投影覆盖层
            if store.fillColorVersion != shownFillColorVersion {
                shownFillColorVersion = store.fillColorVersion
                if let track = store.track {
                    renderer?.updateColors(store.fillDisplayColors ?? store.stagedDisplayColors ?? track.colors)
                }
                scheduleRedraw()
            }
            if store.fillVersion != shownFillVersion {        // 覆盖层（锚点/顶点/批量线）变了：只重投影，不重传颜色
                shownFillVersion = store.fillVersion
                scheduleRedraw()
            }
            // 补点模式进出：限制最远相机距离，缩不到 MapKit 自带地球的尺度
            //（平面兜底切自绘地球在补点模式下已关闭，否则卫星/混合底图会错位）
            if store.fillMode != shownFillMode {
                shownFillMode = store.fillMode
                endFillDrag()
                if !store.fillMode {
                    // 不在视图更新里发布；排在已入队的投影之后清空
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.store.fillMode else { return }
                        self.fillOverlay.overlay = TrackStore.FillOverlay()
                    }
                }
                container.mapView.cameraZoomRange = store.fillMode
                    ? MKMapView.CameraZoomRange(maxCenterCoordinateDistance: 6_000_000)
                    : nil
            }
            if store.fillFocusVersion != shownFillFocusVersion {
                shownFillFocusVersion = store.fillFocusVersion
                if let w = container.window, store.mainWindow !== w { store.mainWindow = w }
                DispatchQueue.main.async { [weak self] in self?.focusFillGap() }
            }
            if store.mapFocusVersion != shownMapFocusVersion {
                shownMapFocusVersion = store.mapFocusVersion
                if let w = container.window, store.mainWindow !== w { store.mainWindow = w }
                DispatchQueue.main.async { [weak self] in self?.focusMapRequest() }
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

            // 2e. 定位到轨迹起点（相机动画放到布局周期之外）
            if store.locateVersion != shownLocateVersion {
                shownLocateVersion = store.locateVersion
                DispatchQueue.main.async { [weak self] in self?.locateToStart() }
            }

            // 2f. 地区统计：选中地区 → 边界高亮 +（可选）飞过去（相机动画放到布局周期之外）
            if store.regionFocusVersion != shownRegionFocusVersion {
                shownRegionFocusVersion = store.regionFocusVersion
                DispatchQueue.main.async { [weak self] in self?.applyRegionHighlight() }
            }

            // 2j. 时光机：会话启动/结束（回平面 + 起帧循环）；暂停时 scrub 应用帧
            let pbID = store.playback.map(ObjectIdentifier.init)
            if pbID != shownPlaybackID {
                shownPlaybackID = pbID
                if store.playback != nil {
                    if globeActive { switchToMap() }
                    applyPlaybackFrame()
                    interactionTick()
                }
                scheduleRedraw()
            }
            if store.playbackPoke != shownPlaybackPoke {
                shownPlaybackPoke = store.playbackPoke
                applyPlaybackFrame()
                interactionTick()      // 恢复播放/拖动进度都要重启帧循环
                scheduleRedraw()
            }

            // 2k. 回放视频导出（存盘模态框推到布局周期之外）
            if store.videoExportVersion != shownVideoExportVersion {
                shownVideoExportVersion = store.videoExportVersion
                if let opt = store.videoExportOptions {
                    DispatchQueue.main.async { [weak self] in
                        self?.performVideoExport(opt)
                    }
                }
            }

            // 2i. 3D 热力柱：进入/退出（隐藏底图走自绘透视场景）与场景重建
            if heat3DOn != shownHeat3D {
                shownHeat3D = heat3DOn
                if heat3DOn { enterHeat3D() } else { exitHeat3D() }
            }
            if heat3DOn {
                ensureHeat3DScene()
                if heat3DScene != nil { fetchHeat3DGround() }   // 底图样式/外观切换重截
            }
            if store.heat3DNorthPoke != shownHeat3DNorthPoke {
                shownHeat3DNorthPoke = store.heat3DNorthPoke
                if heat3DOn {
                    // 归一到 [-π,π] 后 0.35s 平滑转回北向（不跳变）
                    let twoPi = Float.pi * 2
                    let norm = heat3DYaw - (heat3DYaw / twoPi).rounded() * twoPi
                    heat3DYaw = norm
                    heat3DNorthAnim = (from: norm, start: CACurrentMediaTime())
                    interactionTick()
                }
            }

            // 2g. 迷雾存档数据/勾选换代：清实例缓存（不动相机）
            if store.fwdbVersion != shownFwdbVersion {
                shownFwdbVersion = store.fwdbVersion
                fwdbCacheRect = nil
                fwdbCacheLevel = -1
                renderer?.setFogArchiveInstances([], center: (0, 0))
                scheduleRedraw()
            }
            // 2g'. 仅导入时飞到存档范围（勾选切换不动相机）。zoom 版本由合并
            // 落地时递增，此刻 fogArchive 必是含新档的并集；相机动画推到布局周期外
            if store.fwdbZoomVersion != shownFwdbZoomVersion {
                shownFwdbZoomVersion = store.fwdbZoomVersion
                DispatchQueue.main.async { [weak self] in
                    guard let self, let archive = self.store.fogArchive else { return }
                    self.zoomToArchive(archive)
                }
            }
            // 2h. 迷雾模式文件显隐掩码变化 → 重绘
            if store.fogFileMask != shownFogMask {
                shownFogMask = store.fogFileMask
                scheduleRedraw()
            }

            // 2f. 高清图片导出（存盘模态框绝不能开在视图更新周期里，推到下一轮 runloop）
            if store.imageExportVersion != shownImageExportVersion {
                shownImageExportVersion = store.imageExportVersion
                if let opt = store.imageExportOptions {
                    DispatchQueue.main.async { [weak self] in
                        self?.performImageExport(opt)
                    }
                }
            }

            // 3. 设置变化
            if store.settings != shownSettings {
                let old = shownSettings
                shownSettings = store.settings

                if old.mapStyle != store.settings.mapStyle {
                    baseMap.apply(store.settings.mapStyle, to: container.mapView, elevation: .realistic)
                    tunnels.reattachIfNeeded()
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
            // 4. 隧道叠加层开关
            if tunnels.enabled != store.tunnelOverlay { tunnels.setEnabled(store.tunnelOverlay) }
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
            mapView.setVisibleMapRect(rect, animated: !UITestHook.noAnimation)
        }

        // MARK: 覆盖层重绘
        //
        // 两条路径：
        // - scheduleRedraw：一次性变化（设置/数据/颜色），合并到 runloop 尾部画一次；
        // - interactionTick + displayLink：地图交互期间按 vsync 逐帧主动渲染
        //   （不依赖 delegate 节拍，帧率贴满显示器），静止 0.35s 自动暂停零功耗。

        func scheduleRedraw() {
            guard !tornDown else { return }
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
                guard !tornDown else { return }
                let link = overlay.displayLink(target: self, selector: #selector(displayTick))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            displayLink?.isPaused = false
        }

        @objc private func displayTick() {
            if idleAnim { stepIdleAnimation() }
            if globeReturnAnim != nil { stepGlobeReturn() }
            if let na = heat3DNorthAnim {
                let u = min(1.0, (CACurrentMediaTime() - na.start) / 0.35)
                let e = Float(u * u * (3 - 2 * u))
                heat3DYaw = na.from * (1 - e)
                if u >= 1 { heat3DNorthAnim = nil }
                lastInteraction = CACurrentMediaTime()
            }
            // 时光机：推进播放头 + 应用规划相机（暂停时不动）
            if let pb = store.playback {
                let now = CACurrentMediaTime()
                if pb.clock.playing {
                    let dt = min(0.1, now - (playbackLastTick ?? now))
                    playbackLastTick = now
                    // 瓦片门控：飞行中不等（瓦片必然追不上），只在相机
                    // 落定的平台/驻留期等待底图就位，最多 2.5s
                    var gate = false
                    if mapTilesLoading, playbackCameraStatic(pb) {
                        if playbackStallStart == nil { playbackStallStart = now }
                        gate = now - (playbackStallStart ?? now) < 2.5
                    } else {
                        playbackStallStart = nil
                    }
                    if !gate {
                        pb.clock.head = min(pb.plan.duration, pb.clock.head + dt)
                        if pb.clock.head >= pb.plan.duration { pb.clock.playing = false }
                    }
                    applyPlaybackFrame()
                    lastInteraction = now          // 播放期间保持帧循环
                } else {
                    playbackLastTick = nil
                    playbackStallStart = nil    // 暂停残留旧时间戳会吞掉下次门控预算
                }
            } else {
                playbackCameraDetached = false
                playbackLastTick = nil
                playbackStallStart = nil
            }
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
            guard !tornDown else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.tornDown else { return }
                self.idleCheck()
                self.scheduleIdleCheck()
            }
        }

        private func idleCheck() {
            guard !store.settings.idleDisabled, !heat3DOn, store.playback == nil,
                  !idleAnim, !store.deleteMode, !store.fillMode, !store.isLoading,
                  !store.showExportSheet, !store.showSettingsSheet,
                  !store.showImageExportSheet,
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
                container?.mapView.setVisibleMapRect(saved.rect, animated: !UITestHook.noAnimation)
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

        // MARK: 高清图片导出

        /// 当前视图 → 4K/8K PNG。先问存盘位置，再离屏渲染：
        /// 平面 = MKMapSnapshotter 底图 + 点云图层合成（可选纯点云透明底/比例尺）；
        /// 地球 = 整幅自绘场景（透明太空可选，默认合成黑底）
        private func performImageExport(_ opt: ImageExportOptions) {
            guard let renderer, let container,
                  store.track != nil || store.fwdbActive else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            let base = store.track?.name ?? store.fogArchive?.name ?? "track"
            panel.nameFieldStringValue = "\(base)_\(globeActive ? "globe" : "map")_\(opt.pixelWidth)w.png"
            panel.message = String(localized: "选择图片导出位置", comment: "Save panel message when exporting the current map/globe view as a high-resolution PNG image")
            let res = panel.runModal()
            noteActivity()
            guard res == .OK, let url = panel.url else { return }

            let b = container.bounds
            guard b.width > 10, b.height > 10 else { return }
            let w = opt.pixelWidth
            let h = max(64, Int(Double(w) * Double(b.height) / Double(b.width)))
            let scaleFactor = Double(w) / Double(b.width)   // 点径随分辨率等比放大

            store.isLoading = true
            let pixelSize = "\(w)×\(h)"     // 先拼成 String：Int 进 String(localized:) 会按区域加千分位（3.840）
            store.loadingLabel = String(localized: "渲染 \(pixelSize) 图像…", comment: "Loading card while rendering a PNG image export; placeholder = output size in pixels, e.g. 3840×2160")
            store.loadingProgress = nil

            if globeActive {
                exportGlobeImage(w: w, h: h, scaleFactor: scaleFactor, opt: opt, to: url)
            } else {
                exportMapImage(w: w, h: h, scaleFactor: scaleFactor, opt: opt, to: url)
            }
        }

        private func finishImageExport(_ image: CGImage?, to url: URL) {
            defer {
                store.isLoading = false
                store.loadingLabel = ""
            }
            guard let image else {
                store.errorMessage = String(localized: "图片导出失败（渲染或合成出错）。", comment: "Error alert: PNG image export failed because rendering or compositing the image failed")
                return
            }
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                             "public.png" as CFString, 1, nil) else {
                store.errorMessage = String(localized: "图片导出失败（无法写入文件）。", comment: "Error alert: PNG image export failed because the file could not be written")
                return
            }
            CGImageDestinationAddImage(dest, image, nil)
            if CGImageDestinationFinalize(dest) {
                NSWorkspace.shared.activateFileViewerSelecting([url])   // 在访达中显示
            } else {
                store.errorMessage = String(localized: "图片导出失败（无法写入文件）。", comment: "Error alert: PNG image export failed because the file could not be written")
            }
        }

        /// 导出汇合盒：快照线程与 GPU 完成回调各写一个槽位，
        /// DispatchGroup 汇合后统一读取（组语义保证内存可见性）
        private final class ExportJoin: @unchecked Sendable {
            var points: CGImage?
            var base: CGImage?
        }

        /// 地球视角：整幅场景离屏一帧（stride=1 全量点）；
        /// GPU 完成回调在后台回读/合成，主线程只出编码，不再卡顿
        private func exportGlobeImage(w: Int, h: Int, scaleFactor: Double,
                                      opt: ImageExportOptions, to url: URL) {
            guard let renderer, let container else { finishImageExport(nil, to: url); return }
            let layer = MetalPointRenderer.makeOffscreenLayer(device: renderer.device,
                                                              width: w, height: h)
            let dark = container.effectiveAppearance
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let pixel = store.settings.globeStyle == .pixel
            let transparent = opt.transparentBackground
            renderer.renderGlobe(
                layer: layer,
                yaw: globeYaw, pitch: globePitch, distance: globeDist,
                pointSizePx: store.settings.pointSize * scaleFactor,
                opacity: store.settings.opacity,
                halo: store.settings.showHalo,
                lodStride: 1,
                range: store.visibleIndexRange(),
                highlight: nil,
                darkMode: dark,
                mapDim: store.settings.mapOpacity,
                demoAnomalyDeg: demoAnomaly,
                pixelStyle: pixel,
                fogStyle: store.settings.fogMap && !pixel,
                fileMask: store.fogFileMask,
                captureTo: { [weak self] tex in
                    // Metal 完成回调线程：回读 + 合成全在后台
                    let points = MetalPointRenderer.cgImage(from: tex)
                    let out = Self.composite(points: points, base: nil, dimAlpha: 0,
                                             background: transparent ? nil : .black,
                                             scaleBar: nil, w: w, h: h)
                    DispatchQueue.main.async { self?.finishImageExport(out, to: url) }
                })
        }

        /// 平面视图：底图快照（网络，最慢）与点云图层 GPU 渲染并行起跑，
        /// DispatchGroup 汇合后后台合成——主线程只出一次编码
        private func exportMapImage(w: Int, h: Int, scaleFactor: Double,
                                    opt: ImageExportOptions, to url: URL) {
            guard let renderer, let container else { finishImageExport(nil, to: url); return }
            let mapView = container.mapView
            let world = MKMapRect.world.size.width
            let r = mapView.visibleMapRect
            let camera = CameraRect(
                x0: r.origin.x / world, y0: r.origin.y / world,
                w: r.size.width / world, h: r.size.height / world,
                pxW: Double(w), pxH: Double(h))

            // 比例尺参数（主线程取好，后台绘制）
            var scaleBar: (text: String, px: Double)?
            if opt.includeScaleBar {
                let mpp = MKMetersPerMapPointAtLatitude(mapView.centerCoordinate.latitude)
                let metersPerPx = r.size.width * mpp / Double(w)
                let target = Double(w) / 8 * metersPerPx
                let pow10 = pow(10, floor(log10(max(target, 1))))
                let mant = target / pow10
                let niceMant: Double = mant >= 5 ? 5 : (mant >= 2 ? 2 : 1)
                let meters = niceMant * pow10
                let text = meters >= 1000 ? "\(Int(meters / 1000)) km" : "\(Int(meters)) m"
                scaleBar = (text, meters / metersPerPx)
            }

            let transparent = opt.transparentBackground
            let dim = transparent ? 0 : CGFloat(1.0 - store.settings.mapOpacity)
            let bar = transparent ? nil : scaleBar
            let join = ExportJoin()
            let group = DispatchGroup()

            // 1) 底图快照先起跑（网络往返为主）
            if !transparent {
                let so = MKMapSnapshotter.Options()
                so.mapRect = r
                so.size = CGSize(width: w, height: h)
                // 快照器不画瓦片 overlay：外部底图退到最接近的 Apple 底图（appleFallback）
                so.preferredConfiguration = store.settings.mapStyle.appleConfiguration(elevation: .flat)
                so.appearance = container.effectiveAppearance
                group.enter()
                MKMapSnapshotter(options: so).start(with: .global(qos: .userInitiated)) { snapshot, _ in
                    if let img = snapshot?.image {
                        var rect = CGRect(x: 0, y: 0, width: img.size.width, height: img.size.height)
                        join.base = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                    }
                    group.leave()
                }
            }

            // 2) 点云图层：主线程只出编码，GPU 完成回调（后台）回读
            let layer = MetalPointRenderer.makeOffscreenLayer(device: renderer.device,
                                                              width: w, height: h)
            let fwdbActive = store.fwdbActive
            if fwdbActive, store.fogArchive != nil {
                ensureFwdbInstances(camera: camera, force: true)  // 按导出分辨率重选级别
                fwdbCacheRect = nil            // 导出后回屏幕分辨率时重建
            }
            group.enter()
            renderer.render(
                layer: layer,
                camera: camera,
                pointSizePx: store.settings.pointSize * scaleFactor,
                opacity: store.settings.opacity,
                halo: store.settings.showHalo,
                line: lineParams(scale: scaleFactor),
                highlight: nil,
                lodStride: 1,
                range: store.visibleIndexRange(),
                heatMap: store.settings.heatMap,
                heatSegPx: (store.track?.medianSegMerc ?? 0) * camera.pxW / camera.w,
                fogMap: store.settings.fogMap || fwdbActive,
                fogColor: fogStyleForAppearance().color,
                fogWash: fogStyleForAppearance().wash,
                fogRadiusMeters: store.settings.fogRadiusMeters,
                fogFileMask: store.fogFileMask,
                fogArchiveMode: fwdbActive,
                fogArchiveSmooth: store.settings.fogSmooth,
                lodDedupe: false,                     // 高清导出画全量
                orderSensitive: store.settings.colorMode != .single
                    || store.displayMode == .overlay
                    || store.deleteMode || store.stagedCount > 0,   // 与屏幕叠放一致
                captureTo: { tex in
                    join.points = MetalPointRenderer.cgImage(from: tex)
                    group.leave()
                })

            group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
                let out = Self.composite(points: join.points, base: join.base, dimAlpha: dim,
                                         background: transparent ? nil : .white,
                                         scaleBar: bar, w: w, h: h)
                DispatchQueue.main.async { self?.finishImageExport(out, to: url) }
            }
        }

        /// 分层合成：背景色 → 底图 → 压暗 → 点云 → 比例尺
        nonisolated private static func composite(points: CGImage?, base: CGImage?,
                                                  dimAlpha: CGFloat, background: NSColor?,
                                                  scaleBar: (text: String, px: Double)?,
                                                  w: Int, h: Int) -> CGImage? {
            guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            let full = CGRect(x: 0, y: 0, width: w, height: h)
            if let bg = background?.usingColorSpace(.sRGB) {
                ctx.setFillColor(CGColor(red: bg.redComponent, green: bg.greenComponent,
                                         blue: bg.blueComponent, alpha: 1))
                ctx.fill(full)
            }
            if let base { ctx.draw(base, in: full) }
            if dimAlpha > 0.001 {
                ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: dimAlpha))
                ctx.fill(full)
            }
            if let points { ctx.draw(points, in: full) }
            if let bar = scaleBar {
                drawScaleBar(ctx, text: bar.text, barPx: bar.px, w: w, h: h)
            }
            return ctx.makeImage()
        }

        /// 左下角比例尺：半透明白底圆角条 + 黑色刻度线 + 文字
        nonisolated private static func drawScaleBar(_ ctx: CGContext, text: String,
                                                     barPx: Double, w: Int, h: Int) {
            let s = Double(w) / 1920.0                     // 随分辨率整体缩放
            let margin = 24 * s
            let padX = 12 * s, padY = 8 * s
            let fontSize = 14 * s
            let lineH = 3 * s

            let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            let attr: [NSAttributedString.Key: Any] = [.font: font,
                                                       .foregroundColor: NSColor.black]
            let label = NSAttributedString(string: text, attributes: attr)
            let textSize = label.size()

            let boxW = max(barPx, Double(textSize.width)) + padX * 2
            let boxH = Double(textSize.height) + lineH + padY * 2 + 4 * s
            let box = CGRect(x: margin, y: margin, width: boxW, height: boxH)

            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            NSColor(calibratedWhite: 1, alpha: 0.78).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6 * s, yRadius: 6 * s).fill()
            NSColor.black.setFill()
            NSBezierPath(rect: CGRect(x: box.minX + padX, y: box.minY + padY,
                                      width: barPx, height: lineH)).fill()
            label.draw(at: CGPoint(x: box.minX + padX,
                                   y: box.minY + padY + lineH + 3 * s))
            NSGraphicsContext.restoreGraphicsState()
        }

        /// 定位到当前轨迹的起点（时间最早的点）：
        /// 平面 = MapKit 快速飞行动画；地球视角 = 纱罩遮盖式快速切回平面落位
        /// 补点：相机飞到当前断档（两锚点外接框 + 余量，至少 1.2 km 视野）
        private func focusFillGap() {
            guard let track = store.track, let _ = container,
                  let a = store.fillAnchorA, let b = store.fillAnchorB,
                  a < track.count, b < track.count else { return }
            let pa = MKMapPoint(CLLocationCoordinate2D(latitude: track.lat[a], longitude: track.lon[a]))
            let pb = MKMapPoint(CLLocationCoordinate2D(latitude: track.lat[b], longitude: track.lon[b]))
            let mpp = max(1e-9, MKMetersPerMapPointAtLatitude(track.lat[a]))
            flyTo(MKMapRect(x: min(pa.x, pb.x), y: min(pa.y, pb.y),
                            width: max(abs(pa.x - pb.x), 1), height: max(abs(pa.y - pb.y), 1)),
                  minWidth: 1200.0 / mpp)
        }

        /// 修改记录「在主地图上看」：飞到请求的范围（同一套外扩/避让），主窗口置前但把键盘焦点还给修改记录窗口。不改模式
        private func focusMapRequest() {
            guard let r = store.mapFocusRequest, let container else { return }
            let win = container.window
            if let win {
                if win.isMiniaturized { win.deminiaturize(nil) }
                win.orderFront(nil)
            }
            let p1 = MKMapPoint(CLLocationCoordinate2D(latitude: r.maxLat, longitude: r.minLon))
            let p2 = MKMapPoint(CLLocationCoordinate2D(latitude: r.minLat, longitude: r.maxLon))
            let mpp = max(1e-9, MKMetersPerMapPointAtLatitude((r.minLat + r.maxLat) / 2))
            flyTo(MKMapRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                            width: max(abs(p2.x - p1.x), 1), height: max(abs(p2.y - p1.y), 1)),
                  minWidth: r.minSpanMeters / mpp)
            if let keep = r.keepKey, keep.isVisible, keep !== win { keep.makeKey() }
        }

        /// 取景：范围外扩 30%、宽度至少 minWidth（地图点），按未被遮挡区域的长宽比补齐，再带 edgePadding 飞过去
        private func flyTo(_ base: MKMapRect, minWidth minW: Double) {
            guard let container else { return }
            var rect = base.insetBy(dx: -base.size.width * 0.3, dy: -base.size.height * 0.3)
            if rect.size.width < minW {
                rect = rect.insetBy(dx: -(minW - rect.size.width) / 2, dy: 0)
            }
            // 批量补点窗口压在地图上时：把断档放到没被挡住的那块区域里（edgePadding），信息框不动；
            // 挡得太多（露出的不到 30%）就把批量窗口挪到屏幕右缘再算
            let insets = uncoveredInsets()
            let bounds = container.bounds
            let visW = max(1, Double(bounds.width) - Double(insets.left + insets.right))
            let visH = max(1, Double(bounds.height) - Double(insets.top + insets.bottom))
            let aspect = visH / visW
            let needH = rect.size.width * aspect
            if rect.size.height < needH {
                rect = rect.insetBy(dx: 0, dy: -(needH - rect.size.height) / 2)
            } else {
                let needW = rect.size.height / aspect
                rect = rect.insetBy(dx: -(needW - rect.size.width) / 2, dy: 0)
            }
            if globeActive { switchToMap() }
            container.mapView.setVisibleMapRect(rect, edgePadding: insets, animated: !UITestHook.noAnimation)
        }

        /// 飞到断档时的 edgePadding：避开「批量补点」窗口和主窗口自己的浮层（左侧面板、候选列表、操作条、性能面板）。
        /// 在所有遮挡物之外找面积最大的空矩形（枚举遮挡物边界组成的候选矩形），断档整体放进去
        private func uncoveredInsets() -> NSEdgeInsets {
            var insets = NSEdgeInsets()
            guard let container, let win = container.window else { return insets }
            if store.mainWindow !== win { store.mainWindow = win }
            let mapScreen = win.convertToScreen(container.convert(container.bounds, to: nil))
            var covers: [CGRect] = []
            if let batchWin = NSApp.window(scene: SceneID.batchFill), batchWin.isVisible, batchWin !== win {
                // 折叠中：按卡片的目标框算（窗口真正缩完有延迟）；展开的大表格挡住太多时挪到屏幕右缘
                var bf = store.batchCompact ? (store.batchCardTarget ?? batchWin.frame) : batchWin.frame
                var inter = mapScreen.intersection(bf)
                if !store.batchCompact, !inter.isNull, inter.width > 1, inter.height > 1,
                   (Self.strips(mapScreen, inter).map(Self.area).max() ?? 0) < 0.3 * Self.area(mapScreen),
                   let screen = win.screen ?? NSScreen.main {
                    bf.origin.x = max(screen.visibleFrame.minX, screen.visibleFrame.maxX - bf.width)
                    batchWin.setFrameOrigin(bf.origin)
                    inter = mapScreen.intersection(bf)
                }
                if !inter.isNull, inter.width > 1, inter.height > 1 { covers.append(inter) }
            }
            for p in store.uiPanelFrames {
                let local = container.isFlipped ? p : CGRect(x: p.minX, y: container.bounds.height - p.maxY, width: p.width, height: p.height)
                let sr = win.convertToScreen(container.convert(local, to: nil)).intersection(mapScreen)
                if !sr.isNull, sr.width > 1, sr.height > 1 { covers.append(sr) }
            }
            guard !covers.isEmpty else { return insets }
            let best = Self.largestFreeRect(in: mapScreen, avoiding: covers).insetBy(dx: 12, dy: 12)
            guard !best.isNull, best.width >= 200, best.height >= 200 else { return insets }
            insets.left = best.minX - mapScreen.minX
            insets.right = mapScreen.maxX - best.maxX
            insets.bottom = best.minY - mapScreen.minY      // 屏幕坐标 y 向上
            insets.top = mapScreen.maxY - best.maxY
            return insets
        }
        private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : max(0, r.width) * max(0, r.height) }
        private static func strips(_ m: CGRect, _ i: CGRect) -> [CGRect] { [
            CGRect(x: m.minX, y: m.minY, width: i.minX - m.minX, height: m.height),
            CGRect(x: i.maxX, y: m.minY, width: m.maxX - i.maxX, height: m.height),
            CGRect(x: m.minX, y: i.maxY, width: m.width, height: m.maxY - i.maxY),
            CGRect(x: m.minX, y: m.minY, width: m.width, height: i.minY - m.minY)] }
        /// 最大空矩形：候选边界只可能来自区域边与遮挡物边，枚举所有 (x1,x2,y1,y2) 组合，取不与任何遮挡物相交的最大者
        private static func largestFreeRect(in area: CGRect, avoiding covers: [CGRect]) -> CGRect {
            var xs: Set<CGFloat> = [area.minX, area.maxX], ys: Set<CGFloat> = [area.minY, area.maxY]
            for c in covers {
                let i = c.intersection(area)
                guard !i.isNull else { continue }
                xs.insert(i.minX); xs.insert(i.maxX); ys.insert(i.minY); ys.insert(i.maxY)
            }
            let xa = xs.sorted(), ya = ys.sorted()
            var best = CGRect.null, bestArea: CGFloat = 0
            for i in 0..<xa.count {
                for j in (i + 1)..<xa.count {
                    let w = xa[j] - xa[i]
                    guard w > 0 else { continue }
                    for k in 0..<ya.count {
                        for l in (k + 1)..<ya.count {
                            let h = ya[l] - ya[k]
                            guard h > 0, w * h > bestArea else { continue }
                            let r = CGRect(x: xa[i], y: ya[k], width: w, height: h)
                            if !covers.contains(where: { let x = $0.intersection(r); return !x.isNull && x.width > 0.5 && x.height > 0.5 }) {
                                best = r; bestArea = w * h
                            }
                        }
                    }
                }
            }
            return best
        }

        /// 补点覆盖层：锚点、顶点、预览折线投影到视图坐标（每次重绘，几十个点）
        private func updateFillOverlay() {
            guard store.fillMode, let container, let track = store.track else { return }
            var o = TrackStore.FillOverlay()
            let mv = container.mapView
            func proj(_ lat: Double, _ lon: Double) -> CGPoint {
                mv.convert(GeoCoord.dataToMap(CLLocationCoordinate2D(latitude: lat, longitude: lon)),
                           toPointTo: container)
            }
            // 来向/去向：锚点两侧各取 25 个真实轨迹点，画成带箭头的细线，一眼看出从哪来往哪去
            if let a = store.fillAnchorA, a < track.count {
                o.anchorA = proj(track.lat[a], track.lon[a])
                o.tA = track.time[a]
                var indices = [a]; var i = a
                for _ in 0..<25 { guard let prev = track.topology.adjacent(to: i, direction: -1) else { break }; indices.append(prev); i = prev }
                if indices.count > 1 { o.approach = indices.reversed().map { proj(track.lat[$0], track.lon[$0]) } }
            }
            if let b = store.fillAnchorB, b < track.count {
                o.anchorB = proj(track.lat[b], track.lon[b])
                o.tB = track.time[b]
                var indices = [b]; var i = b
                for _ in 0..<25 { guard let next = track.topology.adjacent(to: i, direction: 1), next < track.timedCount else { break }; indices.append(next); i = next }
                if indices.count > 1 { o.departure = indices.map { proj(track.lat[$0], track.lon[$0]) } }
            }
            o.vertices = store.fillVertices.map { proj($0.latitude, $0.longitude) }
            if case .vertex(let i)? = fillDrag { o.dragging = i }
            if store.fillActive, let ia = store.fillAnchorA, let ib = store.fillAnchorB {
                // 预览折线 = 锚点 A → 顶点 → 锚点 B（合成点在落地时才生成，折线即其走向）
                var pts: [CGPoint] = []
                if let a = o.anchorA { pts.append(a) }
                pts += o.vertices
                if let b = o.anchorB { pts.append(b) }
                o.preview = pts
                // 「显示补的点」：按当前点距沿折线插出来的合成点（落地时就是这些）
                if store.fillShowPoints, !store.batchActive { o.previewPoints = store.currentFillPoints().map { proj($0.lat, $0.lon) } }
                // 每段中点句柄：够长的段才给（太短拖不准，也挡住顶点）
                o.midpoints = (1..<max(1, pts.count)).map { k in
                    let a = pts[k - 1], b = pts[k]
                    return hypot(b.x - a.x, b.y - a.y) >= 40
                        ? CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                        : CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)   // ∞ = 这段没有句柄（命中测试落空；∞==∞ 不会打断 Equatable 去重）
                }
                // 两锚点之间的原始点（将被替换）：× 标记。正被顶点压住的不画（拖开后才露出，
                // 用户一看就知道"原地那个是将被替换的原始点"）。太多就不画（挪锚点夹进上百点时只靠粉色）
                if let inner = track.topology.indices(between: ia, and: ib), inner.count <= 300 {
                    let verts = o.vertices
                    o.inner = inner.map { proj(track.lat[$0], track.lon[$0]) }
                        .filter { q in !verts.contains { hypot($0.x - q.x, $0.y - q.y) < 1.5 } }
                }
            }
            // 批量预览：所有取到的草稿（A → 路网点 → B）；失败的画 A–B 红虚线；直线补的灰色；没勾选的淡化。
            // 视口外的不投影；缩得很小时只画 A–B 直连（省投影）
            if let st = store.batch, st.phase == .preview || st.phase == .landing || st.phase == .running {
                let vr = mv.region
                let latMin = vr.center.latitude - vr.span.latitudeDelta * 0.6, latMax = vr.center.latitude + vr.span.latitudeDelta * 0.6
                let lonMin = vr.center.longitude - vr.span.longitudeDelta * 0.6, lonMax = vr.center.longitude + vr.span.longitudeDelta * 0.6
                let coarse = mv.camera.centerCoordinateDistance > 300_000
                // 地图点 → 屏幕：可见 MKMapRect 到视图边界是线性的（不旋转不俯仰时）；用一个样本点和 convert 对账，
                // 差 >2 px 就退回逐点 convert
                let vmr = mv.visibleMapRect, bounds = container.bounds
                let sx = bounds.width / max(vmr.size.width, 1e-9), sy = bounds.height / max(vmr.size.height, 1e-9)
                let originPt = mv.convert(MKMapPoint(x: 0, y: 0).coordinate, toPointTo: container)   // 容器相对地图视图的偏移也一起算进去
                func projMP(_ p: MKMapPoint) -> CGPoint { CGPoint(x: (p.x - vmr.origin.x) * sx, y: (p.y - vmr.origin.y) * sy) }
                var linearOK = false
                if let probe = st.items.first {
                    let cc = GeoCoord.dataToMap(CLLocationCoordinate2D(latitude: probe.candidate.latA, longitude: probe.candidate.lonA))
                    let a = mv.convert(cc, toPointTo: container), b = projMP(MKMapPoint(cc))
                    linearOK = hypot(a.x - b.x, a.y - b.y) < 2
                }
                _ = originPt
                for item in st.items where item.kind != nil && item.kind != .skip && item.status != .skipped && item.status != .pending && !item.status.isNotTunnel {
                    let c = item.candidate
                    if item.landsDeleteOnly { continue }          // 只删点：没有路径可画
                    if let bb = item.bbox, bb.maxLat < latMin || bb.minLat > latMax || bb.maxLon < lonMin || bb.minLon > lonMax { continue }
                    if item.bbox == nil, c.latA < latMin || c.latA > latMax || c.lonA < lonMin || c.lonA > lonMax { continue }
                    if item.status == .running, item.draft == nil { continue }
                    let dA = item.useStraight ? nil : item.draft?.anchorA, dB = item.useStraight ? nil : item.draft?.anchorB
                    // 精确模式待选：两路各画一条（OSRM 实线 4、Valhalla 虚线 5，都是"待你选"蓝），缓存键 id / -id
                    if item.status.isConflict {
                        for x in item.crossDrafts {
                            let isO = x.source == .osrmCar
                            let key = item.id.description + (isO ? "|osrm" : "|valhalla")
                            let sig = (x.coords.count &* 31 &+ x.shiftA &* 131 &+ x.shiftB &* 17) &* 7 &+ (coarse ? 1_000_003 : 0) &+ (isO ? 11 : 13) &+ item.refetchCount &* 7919
                            let xm: [MKMapPoint]
                            if let cached = batchMapPointCache[key], cached.sig == sig { xm = cached.pts }
                            else {
                                var coords: [CLLocationCoordinate2D] = [x.anchorA ?? CLLocationCoordinate2D(latitude: c.latA, longitude: c.lonA)]
                                if !coarse { coords += x.coords }
                                coords.append(x.anchorB ?? CLLocationCoordinate2D(latitude: c.latB, longitude: c.lonB))
                                xm = coords.map { MKMapPoint(GeoCoord.dataToMap($0)) }
                                batchMapPointCache[key] = (sig, xm)
                            }
                            let xp: [CGPoint] = linearOK ? xm.map(projMP) : xm.map { mv.convert($0.coordinate, toPointTo: container) }
                            o.batchLines.append(.init(pts: xp, status: isO ? 4 : 5, selected: st.selectedID == item.id, included: false))
                        }
                        continue
                    }
                    var status = 2                                   // 2 = 失败/不落地
                    if item.useStraight { status = 3 }                // 3 = 直线
                    else if let d = item.draft { status = d.warnings.isEmpty ? 0 : 1 }
                    // 折线的地图点：按签名缓存
                    let srcTag = item.draft?.source == .valhallaCar ? 13 : 11       // 「改用另一条」后点数可能相同：来源也进签名
                    // 「重新获取这一处」后草稿可能点数/外推/来源都没变但坐标变了：重取次数也进签名
                    let sig = ((item.draft?.coords.count ?? -1) &* 31 &+ (item.useStraight ? 1 : 0)) &* 7 &+ (item.draft?.shiftA ?? 0) &* 131 &+ (item.draft?.shiftB ?? 0) &* 17 &+ (coarse ? 1_000_003 : 0) &+ srcTag &+ item.refetchCount &* 7919
                    let mps: [MKMapPoint]
                    if let cached = batchMapPointCache[item.id.description + "|selected"], cached.sig == sig { mps = cached.pts }
                    else {
                        var coords: [CLLocationCoordinate2D] = [dA ?? CLLocationCoordinate2D(latitude: c.latA, longitude: c.lonA)]
                        if !item.useStraight, !coarse, let d = item.draft { coords += d.coords }
                        coords.append(dB ?? CLLocationCoordinate2D(latitude: c.latB, longitude: c.lonB))
                        mps = coords.map { MKMapPoint(GeoCoord.dataToMap($0)) }
                        batchMapPointCache[item.id.description + "|selected"] = (sig, mps)
                    }
                    let pts: [CGPoint] = linearOK ? mps.map(projMP) : mps.map { mv.convert($0.coordinate, toPointTo: container) }
                    o.batchLines.append(.init(pts: pts, status: status, selected: st.selectedID == item.id, included: item.willLand))
                }
            } else if !batchMapPointCache.isEmpty {
                batchMapPointCache.removeAll()
            }
            if let st = store.batch, st.phase == .preview || st.phase == .landing || st.phase == .running {
                // 批量期间不进入顶点编辑：不画句柄，也不画单处草稿的橙线（草稿由批量线表示）
                o.vertices = []
                o.midpoints = []
                o.preview = []
            }
            if let poly = store.fillRegion, poly.count >= 3 { o.region = poly.map { proj($0.latitude, $0.longitude) } }
            o.regionInverted = store.fillRegionInvert
            if UITestHook.enabled { UITestHook.shared.lastOverlay = o }
            if o != fillOverlay.overlay {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.store.fillMode else { return }   // 退出后排队的旧投影不要再写回
                    self.fillOverlay.overlay = o
                }
            }
        }

        /// 行政区高亮：MKPolygon 覆盖层（洞按写入顺序归入紧挨着的外环），可选飞到地区范围
        /// （经度范围按环在圆上的最大空隙算，跨日界线的俄/美/斐济不会飞成整幅世界；太大的地区裁到 ≤5500 km 以免触发地球视角把覆盖层藏掉）
        private func applyRegionHighlight(fly: Bool? = nil) {
            guard let container else { return }
            let mapView = container.mapView
            if !regionOverlays.isEmpty { mapView.removeOverlays(regionOverlays); regionOverlays = [] }
            defer { UITestHook.shared.regionOverlayCount = regionOverlays.count }
            guard let id = store.regionSelection, let index = RegionIndex.shared, let r = index.region(id) else { return }
            var polys: [MKPolygon] = []
            for poly in index.polygons(of: id) where poly.outer.count >= 3 {
                let o = poly.outer.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let inner = poly.holes.filter { $0.count >= 3 }.map { h -> MKPolygon in
                    let c = h.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                    return MKPolygon(coordinates: c, count: c.count)
                }
                polys.append(MKPolygon(coordinates: o, count: o.count, interiorPolygons: inner))
            }
            regionOverlays = polys
            mapView.addOverlays(polys, level: .aboveLabels)
            guard fly ?? store.regionFly, let ext = index.lonExtent(of: id) else { return }
            var west = ext.west, span = ext.span
            var minLat = r.minLatDeg, maxLat = r.maxLatDeg
            let maxGround = 5_500_000.0                                   // 米；超过就裁到这个宽度（地球视角会藏掉 MapKit 覆盖层）
            let midLat = (minLat + maxLat) / 2
            let metersPerDeg = 111_320.0 * cos(midLat * .pi / 180)
            if span * metersPerDeg > maxGround {
                let c = west + span / 2
                span = maxGround / max(metersPerDeg, 1)
                west = c - span / 2
            }
            if (maxLat - minLat) * 111_320 > maxGround {
                let c = (minLat + maxLat) / 2, h = maxGround / 111_320 / 2
                minLat = c - h; maxLat = c + h
            }
            let world = MKMapSize.world.width
            let x0 = MKMapPoint(CLLocationCoordinate2D(latitude: 0, longitude: RegionIndex.normalizeLon(west))).x
            let w = span / 360 * world
            let yTop = MKMapPoint(CLLocationCoordinate2D(latitude: min(85, maxLat), longitude: 0)).y
            let yBot = MKMapPoint(CLLocationCoordinate2D(latitude: max(-85, minLat), longitude: 0)).y
            var rect = MKMapRect(x: x0, y: min(yTop, yBot), width: max(w, 1), height: max(abs(yBot - yTop), 1))
            rect = rect.insetBy(dx: -rect.size.width * 0.08, dy: -rect.size.height * 0.08)
            if globeActive {
                coveredReturnToMap(rect: rect)
            } else {
                mapView.setVisibleMapRect(rect, edgePadding: uncoveredInsets(), animated: !UITestHook.noAnimation)
            }
        }

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
                container.mapView.setVisibleMapRect(rect, animated: !UITestHook.noAnimation)
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

            // —— 3D 热力柱分支：自绘透视场景，完全不碰 MapKit ——
            if heat3DOn {
                guard overlay.metalLayer.drawableSize.width > 1 else { return }
                overlay.metalLayer.presentsWithTransaction = false
                if store.scaleBar != nil { store.scaleBar = nil }   // 平面比例尺在 3D 无意义
                let dark = container.effectiveAppearance
                    .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                updateHeat3DLocalGround()
                if abs(store.heat3DCam.yaw - heat3DYaw) > 0.005 {
                    store.heat3DCam.yaw = heat3DYaw
                }
                renderer.renderHeat3D(
                    layer: overlay.metalLayer,
                    yaw: heat3DYaw, pitch: heat3DPitch, dist: heat3DDist,
                    target: heat3DTarget,
                    smooth: store.settings.heat3DSmooth,
                    dark: dark)
                if !container.labelHost.isHidden { container.labelHost.isHidden = true }
                return
            }

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
                    // 迷雾模式的球面延续：暗化球面 + 白亮轨迹，过渡不再突兀
                    // （闲置展示与像素风格保持原样）
                    fogStyle: store.settings.fogMap && !pixel && !idleAnim,
                    flashFile: flash.file,
                    flashStrength: flash.strength,
                    fileMask: store.fogFileMask)
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
            if store.playback == nil, !store.fillMode,
               CACurrentMediaTime() >= transitionCooldown,
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
            var range = store.visibleIndexRange()
            let reveal = playbackReveal()
            if let upto = reveal.uptoIndex {
                range = (range.start, max(0, min(range.len, upto - range.start)))
            }
            // 城市章节回放：设置逐点区域数据（会话变化时一次），每帧更新游标
            if let pb = store.playback, pb.plan.cityPlan != nil {
                let id = ObjectIdentifier(pb)
                if shownPlaybackRevealID != id || shownPlaybackRevealVersion != pb.revealVersion {
                    if let rv = pb.reveal {
                        renderer.setPlaybackReveal(areas: rv.areaOfPoint, times: rv.times, areaCount: rv.areaCount)
                    } else {
                        renderer.clearPlaybackReveal()
                    }
                    shownPlaybackRevealID = id
                    shownPlaybackRevealVersion = pb.revealVersion
                }
                if let cursors = pb.plan.cursors(at: pb.clock.head) {
                    renderer.updatePlaybackCursors(cursors)
                }
            }
            let stride = lodStride(camera: camera, visibleLen: range.len)
            lastLodStride = stride
            overlay.metalLayer.presentsWithTransaction = true   // 平面：与底图逐帧锁定
            if store.fillMode { updateFillOverlay() }
            let flash = currentFlash()
            if store.fwdbActive, store.fogArchive != nil, !store.deleteMode {
                ensureFwdbInstances(camera: camera, maxGen: reveal.maxGen)
            }

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
                flashStrength: flash.strength,
                heatMap: store.settings.heatMap && !store.deleteMode && !store.fillMode,   // 删除/补点模式需要看见点
                heatSegPx: (store.track?.medianSegMerc ?? 0) * camera.pxW / camera.w,
                fogMap: (store.settings.fogMap || store.fwdbActive) && !store.deleteMode && !store.fillMode,
                fogColor: fogStyleForAppearance().color,
                fogWash: fogStyleForAppearance().wash,
                fogRadiusMeters: store.settings.fogRadiusMeters,
                fogFileMask: store.fogFileMask,
                fogArchiveMode: store.fwdbActive,
                fogArchiveSmooth: store.settings.fogSmooth,
                lodDedupe: store.settings.lodEnabled,
                // 时间/速度/海拔着色、重叠模式按文件着色、回放揭示、删除灰显都依赖"晚者在上"
                orderSensitive: store.settings.colorMode != .single
                    || store.displayMode == .overlay
                    || store.playback != nil || store.deleteMode || store.stagedCount > 0
                    || store.fillMode,
                reveal: store.playback?.plan.cityPlan != nil)
            updateScaleBar()
        }

        /// 迷雾配色跟随外观（对齐手机版世界迷雾：深色雾 + 清除区白亮冲刷）。
        /// 浅色外观雾轻一些保持底图可读；深色外观雾更重、冲刷更亮
        private func fogStyleForAppearance() -> (color: SIMD4<Float>, wash: Float) {
            let dark = container?.effectiveAppearance
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? (SIMD4(0.045, 0.060, 0.055, 0.62), 0.30)
                        : (SIMD4(0.110, 0.130, 0.120, 0.50), 0.16)
        }

        // MARK: 3D 热力柱：进入/退出与场景构建

        private func enterHeat3D() {
            guard let container else { return }
            // 记住当前地图视口：3D 场景就位后落在这里，而不是跳去全局最密集城市
            if !globeActive {
                let r = container.mapView.visibleMapRect
                let world = MKMapRect.world.size.width
                heat3DEntryMerc = (x: r.midX / world, y: r.midY / world,
                                   w: r.size.width / world)
            } else {
                heat3DEntryMerc = nil
                switchToMap()                     // 自绘地球先回平面（分支立即接管绘制）
            }
            container.mapView.isHidden = true
            container.dimView.isHidden = true
            container.labelHost.isHidden = true
            if heat3DSceneKey.isEmpty {
                // 首次进入才用默认视角；往返切换保留上次的 yaw/pitch，
                // 位置和缩放由入场落位从当前地图视口取（与退出写回构成恒等往返）
                heat3DYaw = 0.55
                heat3DPitch = 0.95
                heat3DDist = 3.2
                heat3DTarget = .zero
            }
            heat3DWantFocus = true      // 场景就位后落到当前视口/最密集区域
            ensureHeat3DScene()
            interactionTick()
        }

        private func exitHeat3D() {
            heat3DWantFocus = false      // 残留标志会在下次重建时瞬移相机
            guard let container else { return }
            // 3D 相机落点写回 2D 地图（0.72 与入场系数互逆），
            // 否则退出回到进入前的位置，2D/3D 往返地图会"跳"
            if let sc = heat3DScene, sc.scale > 0 {
                let world = MKMapRect.world.size.width
                let cxM = Double(heat3DTarget.x) / sc.scale + sc.centerX
                let cyM = Double(heat3DTarget.y) / sc.scale + sc.centerY
                let wM = Double(heat3DDist) / 0.72 / sc.scale
                let b = container.mapView.bounds
                let aspect = b.width > 1 ? Double(b.height / b.width) : 0.66
                let rect = MKMapRect(x: (cxM - wM / 2) * world,
                                     y: (cyM - wM * aspect / 2) * world,
                                     width: wM * world,
                                     height: wM * aspect * world)
                if rect.origin.x.isFinite, rect.size.width > 0 {
                    container.mapView.setVisibleMapRect(rect, animated: false)
                }
            }
            container.mapView.isHidden = false
            container.dimView.isHidden = false
            container.dimView.alphaValue = CGFloat(1.0 - store.settings.mapOpacity)
            overlayReset()
            scheduleRedraw()
        }

        private func overlayReset() {
            container?.overlay.metalLayer.presentsWithTransaction = true
        }

        /// 入场落位：落在进入时的地图视口（0.72 ≈ 视锥宽/距离系数），
        /// 无视口记录（从地球进入）则落到最密集区域
        private func applyHeat3DFocus(_ sc: Heat3DScene) {
            heat3DMinDist = max(sc.baseHalf * 6, 1e-5)
            if let e = heat3DEntryMerc {
                heat3DTarget = SIMD2(Float((e.x - sc.centerX) * sc.scale),
                                     Float((e.y - sc.centerY) * sc.scale))
                heat3DDist = min(4.5, max(heat3DMinDist, Float(e.w * sc.scale) * 0.72))
            } else {
                heat3DTarget = SIMD2(sc.focusX, sc.focusZ)
                heat3DDist = min(4.5, sc.focusDist)
            }
        }

        /// 场景缓存键 =（轨迹, 块大小, 时间筛选区间）；键变才后台重建。
        /// 地面贴图随场景范围 + 底图样式 + 外观异步截图
        private func ensureHeat3DScene() {
            guard let track = store.track, let renderer else { return }
            let range = store.visibleIndexRange()
            let k = max(1, min(300, store.settings.heat3DBlock))
            let smooth = store.settings.heat3DSmooth
            let key = "\(track.id)|\(k)|\(range.start)|\(range.len)|\(smooth)"
            guard key != heat3DSceneKey else {
                // 缓存命中（重进 3D）：不重建，但入场落位仍要执行
                if heat3DWantFocus, let sc = heat3DScene {
                    heat3DWantFocus = false
                    applyHeat3DFocus(sc)
                    scheduleRedraw()
                }
                return
            }
            heat3DSceneKey = key
            heat3DBuildGen &+= 1
            let gen = heat3DBuildGen
            Task.detached(priority: .userInitiated) { [weak self] in
                let scene = Heat3D.build(track: track, range: range, blockCells: k,
                                         smooth: smooth)
                guard let self else { return }
                await MainActor.run {
                    guard gen == self.heat3DBuildGen else { return }
                    let old = self.heat3DScene
                    self.heat3DScene = scene
                    renderer.setHeat3D(scene: scene)
                    renderer.setHeat3DLocalGround(texture: nil, rect: SIMD4(0, 0, 0, 0))
                    self.heat3DLocalKey = ""
                    if let sc = scene {
                        self.heat3DMinDist = max(sc.baseHalf * 6, 1e-5)
                        if self.heat3DWantFocus {
                            self.heat3DWantFocus = false
                            self.applyHeat3DFocus(sc)
                        } else if let old, old.scale > 0 {
                            // 换块大小/时间筛选重建：局部坐标系随新子集 bbox 改变，
                            // 相机经 旧局部 → 墨卡托 → 新局部 换算，视角保持在原地
                            let mx = Double(self.heat3DTarget.x) / old.scale + old.centerX
                            let my = Double(self.heat3DTarget.y) / old.scale + old.centerY
                            self.heat3DTarget = SIMD2(
                                Float((mx - sc.centerX) * sc.scale),
                                Float((my - sc.centerY) * sc.scale))
                            self.heat3DDist = min(4.5, max(self.heat3DMinDist,
                                self.heat3DDist * Float(sc.scale / old.scale)))
                        }
                    }
                    self.fetchHeat3DGround()
                    self.scheduleRedraw()
                }
            }
        }

        /// 地面底图截图（数据范围 + 边距；≤2048px，异步就位前用纯色补位）
        private func fetchHeat3DGround() {
            guard let container, let renderer, let scene = heat3DScene else { return }
            let dark = container.effectiveAppearance
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let key = "\(heat3DSceneKey)|\(store.settings.mapStyle.appleFallback.rawValue)|\(dark)"   // 快照只分 Apple 三种
            guard key != heat3DGroundKey else { return }
            heat3DGroundKey = key
            renderer.setHeat3DGround(texture: nil, rect: scene.groundRect)   // 先纯色
            let world = MKMapRect.world.size.width
            let r = scene.mercRect
            let opts = MKMapSnapshotter.Options()
            opts.mapRect = MKMapRect(x: r.x0 * world, y: r.y0 * world,
                                     width: (r.x1 - r.x0) * world,
                                     height: (r.y1 - r.y0) * world)
            let aspect = (r.x1 - r.x0) / max(1e-12, r.y1 - r.y0)
            let wpx = aspect >= 1 ? 2048.0 : 2048.0 * aspect
            opts.size = CGSize(width: wpx, height: wpx / aspect)
            opts.preferredConfiguration = store.settings.mapStyle.appleConfiguration(elevation: .flat)   // 快照不画瓦片 overlay
            opts.appearance = container.effectiveAppearance
            let rect = scene.groundRect
            let device = renderer.device
            MKMapSnapshotter(options: opts).start(with: .global(qos: .userInitiated)) { [weak self] snapshot, _ in
                var tex: MTLTexture?
                if let img = snapshot?.image {
                    var prop = CGRect(x: 0, y: 0, width: img.size.width, height: img.size.height)
                    if let cg = img.cgImage(forProposedRect: &prop, context: nil, hints: nil) {
                        let loader = MTKTextureLoader(device: device)
                        tex = try? loader.newTexture(cgImage: cg, options: [
                            .SRGB: false,
                            .origin: MTKTextureLoader.Origin.topLeft,
                            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                        ])
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard let tex else {
                        self.heat3DGroundKey = ""     // 失败回滚：下次 sync 重试
                        return
                    }
                    guard self.heat3DOn else { return }
                    renderer.setHeat3DGround(texture: tex, rect: rect)
                    self.scheduleRedraw()
                }
            }
        }

        // MARK: 时光机回放：相机应用与数据揭示

        /// 把规划相机写到地图（逐帧非动画；宽高比按视图适配）
        /// 当前播放头是否处于相机静止段（平台/驻留）：向前看 0.05s，
        /// 中心移动与跨度变化都可忽略才算静止——飞行段不受瓦片门控
        private func playbackCameraStatic(_ pb: PlaybackSession) -> Bool {
            guard let container else { return false }
            let b = container.bounds
            let aspect = b.width > 1 ? Double(b.height / b.width) : 0.66
            let a = pb.plan.camera(at: pb.clock.head, aspect: aspect)
            let t2 = min(pb.plan.duration, pb.clock.head + 0.05)
            let c = pb.plan.camera(at: t2, aspect: aspect)
            guard a.span > 0, c.span > 0 else { return false }
            let move = ((c.cx - a.cx) * (c.cx - a.cx)
                      + (c.cy - a.cy) * (c.cy - a.cy)).squareRoot()
            return abs(log(c.span / a.span)) < 0.002 && move < a.span * 0.002
        }

        private func applyPlaybackFrame() {
            guard !playbackCameraDetached else { return }
            guard let container, let pb = store.playback, !globeActive else { return }
            let b = container.bounds
            let aspect = b.width > 1 ? Double(b.height / b.width) : 0.66
            let cam = pb.plan.camera(at: pb.clock.head, aspect: aspect)
            let world = MKMapRect.world.size.width
            let w = cam.span * world
            let h = w * aspect
            let rect = MKMapRect(x: cam.cx * world - w / 2,
                                 y: cam.cy * world - h / 2,
                                 width: w, height: h)
            container.mapView.setVisibleMapRect(rect, animated: false)
        }

        /// 视频导出：存盘面板 → 配置快照 → 后台离屏引擎（进度走载入卡片）
        private func performVideoExport(_ opt: VideoExportOptions) {
            guard let container, let pb = store.playback, !store.videoExporting,
                  store.track != nil || store.fogArchive != nil else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
            let base = store.track?.name ?? store.fogArchive?.name ?? "playback"
            let timelapse = String(localized: "时光机", comment: "filename fragment: no / or :. Timelapse (playback video) part of the default export file name <track>_时光机_1920w.mp4")
            panel.nameFieldStringValue = "\(base)_\(timelapse)_\(opt.pixelWidth)w.mp4"
            panel.message = String(localized: "选择视频导出位置", comment: "Save panel message when exporting the Timelapse playback as an MP4 video")
            let res = panel.runModal()
            noteActivity()
            guard res == .OK, let url = panel.url else { return }
            pb.clock.playing = false
            let outW = opt.pixelWidth
            let outH = outW * 9 / 16
            let scaleFactor = Double(outW) / max(300, Double(container.bounds.width))
            let fogStyle = fogStyleForAppearance()
            let range = store.visibleIndexRange()
            let cfg = VideoExportConfig(
                plan: pb.plan,
                track: store.track,
                archive: store.fogArchive,
                url: url, outW: outW, outH: outH, fps: opt.fps,
                dark: container.effectiveAppearance
                    .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
                mapStyle: store.settings.mapStyle,
                appearance: container.effectiveAppearance,
                mapOpacity: store.settings.mapOpacity,
                pointSizePx: store.settings.pointSize * scaleFactor,
                opacity: store.settings.opacity,
                halo: store.settings.showHalo,
                heatMap: store.settings.heatMap && store.track != nil,
                fogMap: store.settings.fogMap,
                fogColor: fogStyle.color,
                fogWash: fogStyle.wash,
                fogRadiusMeters: store.settings.fogRadiusMeters,
                fogFileMask: store.fogFileMask,
                fogSmooth: store.settings.fogSmooth,
                medianSegMerc: store.track?.medianSegMerc ?? 0,
                rangeStart: range.start, rangeLen: range.len,
                line: lineParams(scale: scaleFactor))
            let exportOwner = store.videoExportBegan()
            let store = self.store
            Task.detached(priority: .userInitiated) {
                VideoExportEngine.run(
                    cfg: cfg,
                    progress: { p in store.videoExportProgress(p, owner: exportOwner) },
                    done: { err in
                        Task { @MainActor in
                            store.videoExportFinished(error: err, url: url, owner: exportOwner)
                        }
                    })
            }
        }

        /// 回放揭示：当前数据时间对应的（可见区间上界, 存档最大代序）。
        /// 播完（含手动拖到底）恢复全量（无时间尾巴也回来）
        private func playbackReveal() -> (uptoIndex: Int?, maxGen: Int) {
            guard let pb = store.playback else { return (nil, .max) }
            let head = pb.clock.head
            if head >= pb.plan.duration - 1e-6 { return (nil, .max) }
            // 城市章节：揭示由 shader 的区域游标完成，不能再按全局时间截断
            if pb.plan.cityPlan != nil { return (nil, .max) }
            let dt = pb.plan.dataTime(at: head)
            if let track = store.track, track.isTimeSorted {
                let upto = track.indexRange(forTimeRange: (-1e18, dt))
                return (upto.start + upto.len, .max)
            }
            if let archive = store.fogArchive {
                return (nil, archive.genUpTo(dt))
            }
            return (nil, .max)
        }

        /// 相机贴近时给脚下区域截高清地面（整景快照放大会糊）。
        /// 键按目标/距离量化去抖：静止后只截一次
        private func updateHeat3DLocalGround() {
            guard let container, let renderer, let scene = heat3DScene else { return }
            let sceneSpanLocal: Float = 2.0
            let footprint = min(sceneSpanLocal, heat3DDist * 1.6)
            guard footprint < sceneSpanLocal / 3 else { return }   // 拉远时整景快照够用
            let now = CACurrentMediaTime()
            let qx = (heat3DTarget.x / (footprint / 4)).rounded()
            let qz = (heat3DTarget.y / (footprint / 4)).rounded()
            let qd = (log2(max(0.001, footprint)) * 3).rounded()
            let dark = container.effectiveAppearance
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let key = "\(qx)|\(qz)|\(qd)|\(store.settings.mapStyle.appleFallback.rawValue)|\(dark)"
            guard key != heat3DLocalKey, now - heat3DLocalStamp > 0.35 else { return }
            heat3DLocalKey = key
            heat3DLocalStamp = now
            let S = scene.scale
            let mx0 = Double(heat3DTarget.x - footprint / 2) / S + scene.centerX
            let mx1 = Double(heat3DTarget.x + footprint / 2) / S + scene.centerX
            let mz0 = Double(heat3DTarget.y - footprint / 2) / S + scene.centerY
            let mz1 = Double(heat3DTarget.y + footprint / 2) / S + scene.centerY
            let world = MKMapRect.world.size.width
            let opts = MKMapSnapshotter.Options()
            opts.mapRect = MKMapRect(x: mx0 * world, y: mz0 * world,
                                     width: (mx1 - mx0) * world, height: (mz1 - mz0) * world)
            opts.size = CGSize(width: 2048, height: 2048)
            opts.preferredConfiguration = store.settings.mapStyle.appleConfiguration(elevation: .flat)   // 快照不画瓦片 overlay
            opts.appearance = container.effectiveAppearance
            let rect = SIMD4<Float>(heat3DTarget.x - footprint / 2, heat3DTarget.y - footprint / 2,
                                    heat3DTarget.x + footprint / 2, heat3DTarget.y + footprint / 2)
            let device = renderer.device
            MKMapSnapshotter(options: opts).start(with: .global(qos: .userInitiated)) { [weak self] snapshot, _ in
                guard let img = snapshot?.image else { return }
                var prop = CGRect(x: 0, y: 0, width: img.size.width, height: img.size.height)
                guard let cg = img.cgImage(forProposedRect: &prop, context: nil, hints: nil) else { return }
                let loader = MTKTextureLoader(device: device)
                let tex = try? loader.newTexture(cgImage: cg, options: [
                    .SRGB: false,
                    .origin: MTKTextureLoader.Origin.topLeft,
                    .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                ])
                guard let tex else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.heat3DOn else { return }
                    renderer.setHeat3DLocalGround(texture: tex, rect: rect)
                    self.scheduleRedraw()
                }
            }
        }

        /// 导入 .fwdb 后飞到存档覆盖范围（bbox 为归一化墨卡托）
        private func zoomToArchive(_ archive: FogArchive) {
            guard let mapView = container?.mapView else { return }
            let world = MKMapRect.world.size.width
            let b = archive.bbox
            var rect = MKMapRect(x: b.minX * world, y: b.minY * world,
                                 width: max(1000, (b.maxX - b.minX) * world),
                                 height: max(1000, (b.maxY - b.minY) * world))
            rect = rect.insetBy(dx: -rect.size.width * 0.14, dy: -rect.size.height * 0.14)
            if globeActive { switchToMap() }
            mapView.setVisibleMapRect(rect, animated: !UITestHook.noAnimation)
        }

        /// .fwdb 存档：按视口（含 75% 边距）从层级金字塔收集方格实例并上传 GPU。
        /// 视口仍在缓存矩形内且级别未变 → 零成本返回（平移/小幅缩放不重建）。
        /// 级别选择保证一个块 ≥ ~0.75 遮罩像素（着色器有 1px 盒滤波羽边，
        /// 亚像素块不漏画）：远看轨迹融成 1–2 物理点宽的平滑细线（对齐手机版
        /// 观感），近看自动细到原始格（一格不差）；实例数超 35 万自动升一级
        private func ensureFwdbInstances(camera: CameraRect, force: Bool = false,
                                         maxGen: Int = .max) {
            guard let archive = store.fogArchive, let renderer,
                  camera.pxW > 1, camera.w > 0 else { return }
            let x0 = camera.x0 - camera.w * 0.75, x1 = camera.x0 + camera.w * 1.75
            let y0 = camera.y0 - camera.h * 0.75, y1 = camera.y0 + camera.h * 1.75
            // 原始格在半分辨率遮罩上的像素宽 → 需要的聚合级别
            let cellPxHalf = camera.pxW / camera.w / Double(FogArchive.grid) / 2
            var level = 0
            if cellPxHalf < 0.75 { level = Int(ceil(log2(0.75 / cellPxHalf))) }
            level = max(0, min(level, archive.levelKeys.count - 1))
            // 迟滞带：缓存级别的块宽仍在 [0.68, 1.65]（级别 0 无上限）就沿用，
            // 避免缩放停在级别边界附近时逐帧翻转级别（重建 + 视觉脉冲）
            if !force, fwdbCacheLevel >= 0, fwdbCacheLevel != level,
               fwdbCacheLevel < archive.levelKeys.count {
                let cachedPx = cellPxHalf * Double(1 << fwdbCacheLevel)
                if cachedPx >= 0.68, fwdbCacheLevel == 0 || cachedPx <= 1.65 {
                    level = fwdbCacheLevel
                }
            }
            let genKey = maxGen >= archive.genTimes.count - 1 ? Int.max : maxGen
            if !force, let c = fwdbCacheRect, fwdbCacheLevel == level,
               fwdbCacheGen == genKey,
               camera.x0 >= c.x0, camera.x0 + camera.w <= c.x1,
               camera.y0 >= c.y0, camera.y0 + camera.h <= c.y1 { return }
            var lv = level
            var data = archive.collectInstances(level: lv, x0: x0, y0: y0, x1: x1, y1: y1,
                                                batchCenter: archive.center, maxGen: maxGen)
            while data.count > 350_000 * 4, lv < archive.levelKeys.count - 1 {
                lv += 1
                data = archive.collectInstances(level: lv, x0: x0, y0: y0, x1: x1, y1: y1,
                                                batchCenter: archive.center, maxGen: maxGen)
            }
            renderer.setFogArchiveInstances(data, center: archive.center)
            fwdbCacheRect = (x0, y0, x1, y1)
            fwdbCacheLevel = level        // 记请求级别（升级结果由同一请求确定性给出）
            fwdbCacheGen = genKey
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
            guard let container, !store.deleteMode, !store.fillMode,
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
            // DeepSeek 2026-11-01：回放中滚轮缩放不再暂停，改为保留用户视角
            if store.playback != nil { playbackCameraDetached = true }

            if heat3DOn {
                let sc = precise ? 0.004 : 0.06
                heat3DDist = min(4.5, max(heat3DMinDist,
                                          heat3DDist * Float(exp(-Double(dy) * sc))))
                interactionTick()
                return true
            }
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
            if let pb = store.playback, pb.clock.playing { pb.clock.playing = false }

            if heat3DOn {
                let factor = Float(1.0 / max(0.2, 1.0 + Double(magnification)))
                heat3DDist = min(4.5, max(heat3DMinDist, heat3DDist * factor))
                interactionTick()
                return true
            }
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
            if store.playback != nil { store.stopPlayback() }   // 回放不进球面
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
            guard globeActive || heat3DOn, let container else { return }
            switch g.state {
            case .began, .changed:
                let t = g.translation(in: container)
                g.setTranslation(.zero, in: container)
                if heat3DOn {
                    noteActivity()
                    heat3DNorthAnim = nil          // 手动旋转接管，取消指北动画
                    heat3DYaw += Float(t.x) * 0.008
                    heat3DPitch = min(1.45, max(0.12, heat3DPitch + Float(t.y) * 0.008))
                    interactionTick()
                } else {
                    applyGlobeRotation(dx: t.x, dy: t.y)
                }
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
        /// 拾取抽稀：候选点封顶 ~100 万。放大后 LOD stride 归 1 时，
        /// 600 万点的全量 argmin 每帧要数毫秒（鼠标移动期间掉帧的元凶）；
        /// 隔几个近邻取一个对悬停命中肉眼无差（命中半径远大于相邻点距）
        private func pickStride(visibleLen: Int) -> Int {
            max(lastLodStride, (visibleLen + 999_999) / 1_000_000)
        }

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
            let range = store.visibleIndexRange()
            guard let (idx, _) = track.nearestOnGlobe(query: q,
                                                      stride: pickStride(visibleLen: range.len),
                                                      range: range) else { return nil }
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
                label = km == km.rounded() ? "\(km.formatted(Fmt.f0)) km" : "\(km.formatted(Fmt.f1)) km"
            } else {
                label = "\(dist.formatted(Fmt.f0)) m"
            }
            store.pushScaleBar(ScaleBarInfo(widthPt: widthPt, label: label))
        }

        // MARK: 手绘套索圈选

        @objc private func handleSelectionPan(_ g: NSPanGestureRecognizer) {
            noteActivity()
            guard let container, store.deleteMode || store.fillRegionDrawing, store.track != nil else { return }

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
                if store.fillRegionDrawing {
                    // 补点范围：屏幕多边形 → 经纬度（平面地图；地球视角下不支持）
                    if path.count >= 3, !globeActive {
                        store.setFillRegion(path.map { container.mapView.convert($0, toCoordinateFrom: container) })
                    } else { store.setFillRegion(nil) }
                } else if path.count >= 3 {
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
            guard let container else { return }
            if heat3DOn, !store.deleteMode {
                switch g.state {
                case .began, .changed:
                    let t = g.translation(in: container)
                    g.setTranslation(.zero, in: container)
                    noteActivity()
                    // 屏幕位移 → 地面位移（随 yaw 旋转；幅度随距离缩放）
                    let k = heat3DDist * 0.0016
                    let dx = Float(t.x) * k, dz = Float(t.y) * k
                    let cy = cos(heat3DYaw), sy = sin(heat3DYaw)
                    heat3DTarget.x -= dx * cy - dz * sy
                    heat3DTarget.y -= dx * sy + dz * cy
                    // 平移钳在数据区外接框 +30%：拖不进空无一物的 limbo
                    let g = heat3DScene?.groundRect ?? SIMD4(-1.2, -1.2, 1.2, 1.2)
                    let mx = (g.z - g.x) * 0.15, mz = (g.w - g.y) * 0.15
                    heat3DTarget.x = min(g.z + mx, max(g.x - mx, heat3DTarget.x))
                    heat3DTarget.y = min(g.w + mz, max(g.y - mz, heat3DTarget.y))
                    interactionTick()
                default:
                    break
                }
                return
            }
            guard store.deleteMode else { return }
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
            // True topology runs retain every segment edge, including interleaved
            // files and dates; their soft/hard breaks are enforced by the renderer.
            guard s.showTrackLine, store.track != nil else { return nil }
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
                arrows: s.showArrows,
                arrowEvery: UInt32(max(1, min(3, s.arrowEvery))),
                cullBreaks: true, fileMask: store.fogFileMask)
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

        // 瓦片加载状态（时光机门控用）：加载中 = 底图还没"到位"
        nonisolated func mapViewWillStartLoadingMap(_ mapView: MKMapView) {
            MainActor.assumeIsolated { mapTilesLoading = true }
        }

        nonisolated func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
            MainActor.assumeIsolated { mapTilesLoading = false }
        }

        nonisolated func mapViewDidFailLoadingMap(_ mapView: MKMapView,
                                                  withError error: Error) {
            MainActor.assumeIsolated { mapTilesLoading = false }
        }

        nonisolated func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            MainActor.assumeIsolated {
                if !idleAnim { noteActivity() }   // 同上
                interactionTick()
                scheduleRedraw()   // 最终停稳再补一帧
                tunnels.viewChanged()   // 隧道层：停稳 600 ms 后按视野取数
            }
        }

        /// MapKit 覆盖层：外部瓦片底图、OSM 隧道折线、地区统计的边界高亮
        nonisolated func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let r = BaseMapApplier.renderer(for: overlay) { return r }
            if let r = TunnelLayer.renderer(for: overlay) { return r }
            if let poly = overlay as? MKPolygon {
                let r = MKPolygonRenderer(polygon: poly)
                r.strokeColor = NSColor.systemOrange
                r.fillColor = NSColor.systemOrange.withAlphaComponent(0.12)
                r.lineWidth = 2
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
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
            let range = store.visibleIndexRange()
            let hitRadius = store.settings.pointSize + 6.0
            // 空间索引：只扫光标附近格子（全量 vDSP 扫 200 万点 ≈3ms/帧）；
            // 无索引时回退全量跳步扫描
            let hit: (index: Int, mercDist: Double)?
            if !track.spatialKeys.isEmpty {
                hit = track.nearestPointSpatial(mercX: qx, mercY: qy,
                                                radiusMerc: hitRadius / Double(bounds.width) * mercW,
                                                range: range)
            } else {
                hit = track.nearestPoint(mercX: qx, mercY: qy,
                                         stride: pickStride(visibleLen: range.len),
                                         range: range)
            }
            let micros = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e3
            store.pushHoverMicros(micros)
            guard let (idx, mercDist) = hit else { return nil }

            let distPt = mercDist / mercW * Double(bounds.width)
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
                  !store.deleteMode, !heat3DOn else { return }
            let p = g.location(in: container)
            // 补点模式：单击地图不加顶点（加顶点 = 拖线段中点）；⌥点击轨迹点 = 把它设为更近的那个锚点
            if store.fillMode, !globeActive {
                guard store.fillActive else { return }
                if NSEvent.modifierFlags.contains(.option), let idx = hitTest(at: p) {
                    store.setFillAnchor(nearest: idx)
                    scheduleRedraw()
                }
                return
            }
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
                    return (globeActive || heat3DOn) && !store.deleteMode
                }
                if gestureRecognizer is NSPanGestureRecognizer {
                    // 右键拖拽：删除模式（圈选辅助）或 3D 热力（平移观察目标）
                    if (gestureRecognizer as? NSPanGestureRecognizer)?.buttonMask == 0x2 {
                        return store.deleteMode || heat3DOn || store.fillRegionDrawing
                    }
                    return store.deleteMode || store.fillRegionDrawing
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
        private var shownColorVersions: [Int] = []  // 找不同高亮/清除时只重传颜色
        private var shownSettings = ViewSettings()
        private var syncing = false                  // 区域同步防回环
        private var redrawScheduled = false
        private var didInitialZoom = false
        private let baseMaps = [BaseMapApplier(), BaseMapApplier()]   // 左 / 右底图来源

        init(store: TrackStore) {
            self.store = store
            super.init()
        }

        func attach(_ split: CompareSplitView) {
            self.split = split
            for pane in [split.left, split.right] {
                pane.mapView.delegate = self
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
                    shownColorVersions = [tl.colorVersion, tr.colorVersion]
                    rendererL?.setData(track: tl)
                    rendererR?.setData(track: tr)
                    if !didInitialZoom {
                        didInitialZoom = true
                        zoomToUnion(tl, tr)
                    }
                    scheduleRedraw()
                } else if [tl.colorVersion, tr.colorVersion] != shownColorVersions {
                    // 找不同高亮/清除/换色：几何不变，只重传颜色缓冲
                    shownColorVersions = [tl.colorVersion, tr.colorVersion]
                    rendererL?.updateColors(tl.colors)
                    rendererR?.updateColors(tr.colors)
                    scheduleRedraw()
                }
            } else if !shownTrackIDs.isEmpty {
                shownTrackIDs = []
                shownColorVersions = []
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
            for (i, pane) in [split.left, split.right].enumerated() {
                baseMaps[i].apply(store.settings.mapStyle, to: pane.mapView, elevation: .flat)
            }
        }

        nonisolated func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            BaseMapApplier.renderer(for: overlay) ?? MKOverlayRenderer(overlay: overlay)
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
                range: nil,
                // 找不同高亮时不去重：格首点可能是共同点（灰），会把同格的独有点丢掉
                lodDedupe: store.settings.lodEnabled && store.diffResult == nil,
                orderSensitive: store.settings.colorMode != .single || store.diffResult != nil)
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

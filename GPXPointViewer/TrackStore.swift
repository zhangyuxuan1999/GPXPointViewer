//
//  TrackStore.swift
//  GPXPointViewer
//
//  应用状态中心（@MainActor）。
//
//  警告治理：
//  - 所有来自控件绑定的设置修改统一走 updateSetting()，延迟到下一个 runloop
//    再发布，杜绝 "Publishing changes from within view updates" 运行时警告；
//  - 后台任务里先 guard let self 再回主线程，符合 Swift 6 的捕获规则。
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuartzCore

/// 显示模式：单文件（新文件替换旧的）/ 重叠（多文件同图不同色）/ 对比（两文件左右分屏）
enum DisplayMode: String, CaseIterable, Identifiable {
    case single = "单文件"
    case overlay = "重叠"
    case compare = "对比"
    var id: String { rawValue }
}

/// 已载入的单个 GPX 文件（重叠/对比模式的留底：关闭其他文件后据此重建显示轨迹）
struct LoadedFile: Identifiable {
    let id = UUID()
    var name: String
    var url: URL?
    var parsed: ParsedTrack
    var color: Color
}

@MainActor
final class TrackStore: ObservableObject {
    @Published var track: TrackData?
    @Published var stats = PerfStats()
    @Published var settings = ViewSettings()
    @Published var hover: PointInfo?
    @Published var selected: PointInfo?
    @Published var isLoading = false
    @Published var loadingLabel = ""
    @Published var loadingProgress: Double?          // 确定进度 0…1；nil = 不确定（转圈）
    @Published var errorMessage: String?
    @Published var scaleBar: ScaleBarInfo?
    @Published var showExportSheet = false
    @Published var showSettingsSheet = false
    /// 查看时间筛选：[start, end) Unix 秒；nil = 全部（要求数据时间有序）
    @Published var viewFilter: (start: Double, end: Double)?
    /// 查看筛选的形状（粒度+取值），导出面板预设"查哪段导哪段"用
    var viewFilterSpec: ViewFilterSpec?
    // 删除模式（预删除事务：套索圈选只暂存，执行删除时一次性落地）
    @Published var deleteMode = false
    @Published var selectionPath: [CGPoint]?         // 手绘套索路径（视图坐标）
    @Published var globeShowing = false              // 地球视角是否在屏（悬浮控件显隐）
    @Published var presenting = false                // 闲置展示模式（UI 面板淡出）
    @Published var stagedCount = 0
    @Published private(set) var stageSteps = 0       // 已圈选步数（多步撤销用）
    @Published var executePrompt: Int?               // 非 nil 时弹确认框
    @Published private(set) var stagedVersion = 0    // 预删除灰显版本号（协调器消费）
    private(set) var stagedDisplayColors: [UInt8]?   // 暂存点灰显后的颜色缓冲

    private(set) var currentFileURLs: [URL] = []
    var currentFileURL: URL? { currentFileURLs.first }   // 兼容旧用法（重新加载菜单等）
    private var lastStatsPush: Double = 0
    private var lastHoverPush: Double = 0
    private var lastScalePush: Double = 0
    private var stagedMask: [Bool] = []
    private var stagedHistory: [[Int32]] = []        // 每次圈选新增的点（撤销栈）
    /// 删除后保持相机不动（协调器消费一次）
    var preserveNextCamera = false

    /// 协调器注册的"用户活动"回调：导入/拖放/对话框等非鼠标事件
    /// 也要重置闲置计时（否则拖入文件刚解析完就进入闲置展示）
    var onUserActivity: (() -> Void)?
    func noteUserActivity() { onUserActivity?() }

    // MARK: - 多文件（单文件/重叠/对比）

    @Published var files: [LoadedFile] = []
    @Published var displayMode: DisplayMode = .single
    /// 文件列表点击 → 地图高亮闪烁（协调器消费版本号）
    @Published private(set) var flashVersion = 0
    private(set) var flashFileIndex: Int?
    /// 定位到轨迹起点（协调器消费版本号）
    @Published private(set) var locateVersion = 0

    /// 定位按钮：快速渐变到当前轨迹第一个点（时间最早）附近
    func requestLocate() {
        noteUserActivity()
        locateVersion &+= 1
    }

    /// 对比模式：两文件各自独立构建的轨迹（下标随 files 顺序；nil = 构建中）
    @Published var compareTracks: [TrackData]?
    /// 对比模式左右互换（false：files[0] 在左）
    @Published var compareSwap = false

    /// 重叠模式默认调色板（8 色循环，色相彼此远离）
    static let filePalette: [Color] = [
        Color(red: 0.90, green: 0.16, blue: 0.16),   // 红
        Color(red: 0.04, green: 0.48, blue: 1.00),   // 蓝
        Color(red: 0.17, green: 0.72, blue: 0.28),   // 绿
        Color(red: 1.00, green: 0.55, blue: 0.10),   // 橙
        Color(red: 0.62, green: 0.35, blue: 0.95),   // 紫
        Color(red: 0.10, green: 0.75, blue: 0.85),   // 青
        Color(red: 0.95, green: 0.30, blue: 0.70),   // 品红
        Color(red: 0.80, green: 0.68, blue: 0.10),   // 黄褐
    ]

    /// SwiftUI Color → RGBA（点色缓冲用，α 与单色模式一致取 235）
    nonisolated static func rgba(of color: Color) -> SIMD4<UInt8> {
        let ns = NSColor(color).usingColorSpace(.sRGB)
        let r = min(max(ns?.redComponent ?? 0.04, 0), 1)
        let g = min(max(ns?.greenComponent ?? 0.48, 0), 1)
        let b = min(max(ns?.blueComponent ?? 1.0, 0), 1)
        return SIMD4(UInt8((r * 255).rounded()),
                     UInt8((g * 255).rounded()),
                     UInt8((b * 255).rounded()),
                     235)
    }

    /// 当前可选的显示模式（对比仅两文件时可用）
    var availableModes: [DisplayMode] {
        files.count == 2 ? [.single, .overlay, .compare] : [.single, .overlay]
    }

    /// 手动切换显示模式（模式间跃迁语义见各分支）
    func switchDisplayMode(to mode: DisplayMode) {
        guard mode != displayMode else { return }
        noteUserActivity()
        switch mode {
        case .single:
            displayMode = .single
            if files.count > 1 {
                files = [files[files.count - 1]]   // 只保留最近导入的文件
                currentFileURLs = files.compactMap { $0.url }
                rebuildDisplayTrack()
            } else {
                recolorNow()                        // 恢复常规着色
            }
        case .overlay:
            displayMode = .overlay
            recolorOverlayNow()                     // 现有合并轨迹按文件重新着色
        case .compare:
            guard files.count == 2 else { return }
            displayMode = .compare
            buildCompareTracks()
        }
        if mode != .compare {
            compareTracks = nil
            compareSwap = false
        }
    }

    /// 对比模式：两文件各自独立 build（后台并行），完成后一次发布
    private func buildCompareTracks() {
        guard files.count == 2 else { return }
        compareTracks = nil
        isLoading = true
        loadingLabel = "构建对比视图…"
        loadingProgress = nil
        let parsedA = files[0].parsed
        let parsedB = files[1].parsed
        let nameA = files[0].name
        let nameB = files[1].name
        let mode = settings.colorMode
        let single = singleRGBA()
        Task.detached(priority: .userInitiated) { [weak self] in
            var pa = parsedA; pa.name = nameA
            var pb = parsedB; pb.name = nameB
            // 两条轨迹并行构建（build 内部各自还有阶段级并行）；
            // 两个槽位分线程各写其一，构造上无竞争
            final class Pair: @unchecked Sendable { var a: TrackData?; var b: TrackData? }
            let pair = Pair()
            DispatchQueue.concurrentPerform(iterations: 2) { k in
                if k == 0 {
                    pair.a = TrackData.build(parsed: pa, preferredMode: mode, singleColor: single).0
                } else {
                    pair.b = TrackData.build(parsed: pb, preferredMode: mode, singleColor: single).0
                }
            }
            guard let self, let a = pair.a, let b = pair.b else { return }
            await MainActor.run {
                guard self.displayMode == .compare, self.files.count == 2 else {
                    self.isLoading = false
                    self.loadingLabel = ""
                    return
                }
                self.noteUserActivity()
                self.compareTracks = [a, b]
                self.isLoading = false
                self.loadingLabel = ""
            }
        }
    }

    /// 关闭一个文件：对比中关闭 → 回单文件；重叠中照常重建
    func closeFile(_ id: UUID) {
        guard let idx = files.firstIndex(where: { $0.id == id }) else { return }
        noteUserActivity()
        files.remove(at: idx)
        if displayMode == .compare {
            displayMode = files.count >= 2 ? .overlay : .single   // 对比中关闭 → 回单文件
        }
        compareTracks = nil
        compareSwap = false
        currentFileURLs = files.compactMap { $0.url }
        if files.isEmpty {
            clearTrack()
        } else {
            rebuildDisplayTrack()
        }
    }

    /// 改某文件的点色（重叠模式立即生效，仅重写颜色缓冲，不重建几何）
    func setFileColor(_ id: UUID, _ color: Color) {
        guard let idx = files.firstIndex(where: { $0.id == id }) else { return }
        files[idx].color = color
        if displayMode == .overlay { recolorOverlayNow() }
    }

    /// 文件列表点击 → 请求地图高亮闪烁该文件的轨迹
    func flashFile(_ id: UUID) {
        guard let idx = files.firstIndex(where: { $0.id == id }) else { return }
        flashFileIndex = idx
        flashVersion &+= 1
    }

    /// 重叠模式：按文件颜色重写点色缓冲
    func recolorOverlayNow() {
        guard displayMode == .overlay, let track, !track.fileID.isEmpty, !files.isEmpty else { return }
        stats.colorMs = track.recolorByFile(files.map { Self.rgba(of: $0.color) })
    }

    /// 从 files 重建显示轨迹（合并 + fileID + 载入排序 + build，后台执行）
    private func rebuildDisplayTrack() {
        guard !files.isEmpty else { return }
        if !isLoading { isLoading = true }
        loadingLabel = "构建轨迹…"
        loadingProgress = nil
        let parseds = files.map { $0.parsed }
        let name = files.count == 1 ? files[0].name : "merge_\(files.count)"
        let overlayColors: [SIMD4<UInt8>]? = displayMode == .overlay
            ? files.map { Self.rgba(of: $0.color) } : nil
        let mode = settings.colorMode
        let single = singleRGBA()
        Task.detached(priority: .userInitiated) { [weak self] in
            var merged = GPXParser.mergeParsed(parseds)
            merged.name = name
            let (track, stats) = TrackData.build(parsed: merged, preferredMode: mode,
                                                 singleColor: single,
                                                 overlayFileColors: overlayColors)
            guard let self else { return }
            await MainActor.run { self.apply(track: track, stats: stats) }
        }
    }

    init() {
        #if DEBUG
        _ = GeoCompute.selfTestPassed   // vDSP 语义自检
        #endif
        // 载入闲置/外观设置（其余设置不持久化；clamp 防手改 plist 出界）
        let d = UserDefaults.standard
        if let v = d.object(forKey: IdleDefaultsKey.globeSeconds) as? Double {
            settings.idleGlobeSeconds = min(max(v, 1), 60)
        }
        if let v = d.object(forKey: IdleDefaultsKey.mapSeconds) as? Double {
            settings.idleMapSeconds = min(max(v, 1), 60)
        }
        settings.idleDisabled = d.bool(forKey: IdleDefaultsKey.disabled)
        if let raw = d.string(forKey: IdleDefaultsKey.appearance),
           let mode = AppearanceMode(rawValue: raw) {
            settings.appearance = mode
        }
        applyAppearance()
    }

    /// 外观三向开关 → NSApp.appearance（nil = 跟随系统）
    private func applyAppearance() {
        switch settings.appearance {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - 设置绑定（视图更新安全）

    /// 修改设置：跳出当前视图更新周期再发布
    func updateSetting<T: Equatable>(_ keyPath: WritableKeyPath<ViewSettings, T>, to value: T) {
        guard settings[keyPath: keyPath] != value else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settings[keyPath: keyPath] = value
            self.persistIdleSetting(for: keyPath)
        }
    }

    private enum IdleDefaultsKey {
        static let globeSeconds = "idleGlobeSeconds"
        static let mapSeconds   = "idleMapSeconds"
        static let disabled     = "idleDisabled"
        static let appearance   = "appearanceMode"
    }

    /// 只持久化闲置/外观这几个设置（ViewSettings 含 Color，整体编码不可行也无必要）；
    /// 外观修改顺带落地到 NSApp
    private func persistIdleSetting(for keyPath: AnyKeyPath) {
        let d = UserDefaults.standard
        switch keyPath {
        case \ViewSettings.idleGlobeSeconds: d.set(settings.idleGlobeSeconds, forKey: IdleDefaultsKey.globeSeconds)
        case \ViewSettings.idleMapSeconds:   d.set(settings.idleMapSeconds,   forKey: IdleDefaultsKey.mapSeconds)
        case \ViewSettings.idleDisabled:     d.set(settings.idleDisabled,     forKey: IdleDefaultsKey.disabled)
        case \ViewSettings.appearance:
            d.set(settings.appearance.rawValue, forKey: IdleDefaultsKey.appearance)
            applyAppearance()
        default: break
        }
    }

    /// 生成一个"延迟发布"的设置绑定，供滑块/开关/选择器使用
    func binding<T: Equatable>(_ keyPath: WritableKeyPath<ViewSettings, T>) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { self.updateSetting(keyPath, to: $0) }
        )
    }

    // MARK: - 打开文件

    func openPanel() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.xml]
        if let gpx = UTType(filenameExtension: "gpx") { types.insert(gpx, at: 0) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.message = "选择一个或多个 GPX 文件（多选将合并显示，可整体导出）"
        panel.prompt = "打开"
        let result = panel.runModal()
        noteUserActivity()   // 对话框期间主线程阻塞，关闭瞬间计时已过期（含取消）
        if result == .OK, !panel.urls.isEmpty {
            load(urls: panel.urls)
        }
    }

    /// 统一载入入口（单/多文件、各显示模式共用）：
    /// - 单文件模式：新文件替换当前文件；一次拖入 ≥2 个自动进入重叠模式；
    /// - 重叠模式：追加到现有文件（分批拖入合并显示）；
    /// - 对比模式：追加并自动转回重叠模式。
    /// 跨文件全局分块并行解析；损坏/无点文件跳过并提示，不中断整批。
    /// 多文件合并数据名为 merge_N —— 导出命名据此得到 merge_N_GPVexported.gpx。
    func load(urls: [URL]) {
        guard !isLoading, !urls.isEmpty else { return }
        noteUserActivity()   // 导入开始即活动；到 apply 之间由 isLoading 抑制闲置
        let appending = displayMode != .single && !files.isEmpty
        let secured = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        isLoading = true
        loadingLabel = urls.count == 1
            ? "解析 \(urls[0].lastPathComponent)…"
            : "解析 \(urls.count) 个文件…"
        loadingProgress = nil                        // Pass1 计数极快，起步先转圈
        // 进度回调（解析线程 → 主线程；parseMany 侧已节流到 ~10Hz）
        let progressSink: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            guard let self else { return }
            let p = Double(done) / Double(max(total, 1))
            Task { @MainActor in self.loadingProgress = p }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                for (u, ok) in secured where ok { u.stopAccessingSecurityScopedResource() }
            }
            // mmap 读取（元数据级开销）；读失败以空 Data 占位，与"文件里没有点"统一按跳过处理
            var datas: [Data] = []
            datas.reserveCapacity(urls.count)
            for url in urls {
                datas.append((try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data())
            }
            let (parsed, failed) = GPXParser.parseMany(files: datas, progress: progressSink)
            guard let self else { return }
            guard parsed.count > 0 else {
                await MainActor.run { self.fail(GPXParseError.noPoints) }
                return
            }
            // 按 sortedRuns（文件序、已剔除失败文件）切出每文件留底
            let failedSet = Set(failed)
            var newFiles: [(name: String, url: URL, parsed: ParsedTrack)] = []
            var runIdx = 0
            let perFileSeconds = parsed.parseSeconds / Double(max(1, parsed.sortedRuns.count))
            let perFileChunks = max(1, parsed.chunkCount / max(1, parsed.sortedRuns.count))
            for (i, url) in urls.enumerated() where !failedSet.contains(i) {
                guard runIdx < parsed.sortedRuns.count else { break }
                let name = url.deletingPathExtension().lastPathComponent
                var part = GPXParser.slice(parsed, range: parsed.sortedRuns[runIdx], name: name)
                part.byteCount = datas[i].count      // 每文件统计（性能面板聚合口径）
                part.parseSeconds = perFileSeconds
                part.chunkCount = perFileChunks
                newFiles.append((name, url, part))
                runIdx += 1
            }
            let failedNames = failed.map { urls[$0].lastPathComponent }
            let ready = newFiles
            await MainActor.run {
                self.ingest(newFiles: ready, appending: appending, failedNames: failedNames)
            }
        }
    }

    /// 兼容旧入口
    func load(url: URL) { load(urls: [url]) }

    /// 解析完成 → 更新 files/模式，并触发显示轨迹重建（主线程）
    private func ingest(newFiles: [(name: String, url: URL, parsed: ParsedTrack)],
                        appending: Bool, failedNames: [String]) {
        if !appending { files = [] }
        for nf in newFiles {
            let color = Self.filePalette[files.count % Self.filePalette.count]
            files.append(LoadedFile(name: nf.name, url: nf.url, parsed: nf.parsed, color: color))
        }
        // 模式跃迁：≥2 个文件 → 重叠（对比模式加文件也转重叠）；单文件保持/回到单文件
        displayMode = files.count >= 2 ? .overlay : .single
        compareTracks = nil
        compareSwap = false
        currentFileURLs = files.compactMap { $0.url }
        if !failedNames.isEmpty {
            errorMessage = "已跳过 \(failedNames.count) 个无法解析的文件：\n"
                + failedNames.joined(separator: "\n")
        }
        if files.isEmpty {
            fail(GPXParseError.noPoints)
        } else {
            rebuildDisplayTrack()
        }
    }

    // MARK: - 压力测试

    func runStress(count n: Int) {
        guard !isLoading else { return }
        files = []                       // 压测数据替换全部文件，回单文件语义
        displayMode = .single
        currentFileURLs = []
        isLoading = true
        loadingLabel = "并行生成 \(n.formatted()) 个点…"
        let mode = settings.colorMode
        let single = singleRGBA()

        Task.detached(priority: .userInitiated) { [weak self] in
            let parsed = StressTest.generate(count: n)
            let (track, stats) = TrackData.build(parsed: parsed, preferredMode: mode, singleColor: single)
            guard let self else { return }
            await MainActor.run { self.apply(track: track, stats: stats) }
        }
    }

    func reloadCurrentFile() {
        let urls = currentFileURLs
        guard !urls.isEmpty else { return }
        files = []                       // 整批重载（重叠模式按追加语义会重复，先清空）
        displayMode = .single
        load(urls: urls)
    }

    // MARK: - 着色

    /// 着色模式或单色颜色变化后调用（onChange 时机，已在视图更新之外）
    func recolorNow() {
        if displayMode == .overlay { recolorOverlayNow(); return }
        guard let track else { return }
        stats.colorMs = track.recolor(preferred: settings.colorMode, singleColor: singleRGBA())
    }

    private func singleRGBA() -> SIMD4<UInt8> {
        let ns = NSColor(settings.singleColor).usingColorSpace(.sRGB)
        let r = min(max(ns?.redComponent ?? 0.04, 0), 1)
        let g = min(max(ns?.greenComponent ?? 0.48, 0), 1)
        let b = min(max(ns?.blueComponent ?? 1.0, 0), 1)
        return SIMD4(UInt8((r * 255).rounded()),
                     UInt8((g * 255).rounded()),
                     UInt8((b * 255).rounded()),
                     235)
    }

    // MARK: - 内部

    private func apply(track: TrackData, stats newStats: PerfStats) {
        noteUserActivity()   // 核心修复：数据换代（导入/压测/删除完成）算作活动
        self.track = track
        self.stats = newStats
        self.hover = nil
        self.selected = nil
        self.isLoading = false
        self.loadingLabel = ""
        self.loadingProgress = nil
        self.viewFilter = nil
        self.viewFilterSpec = nil
        // 数据换代时预删除状态一律作废
        self.stagedMask = []
        self.stagedHistory = []
        self.stageSteps = 0
        self.stagedCount = 0
        self.stagedDisplayColors = nil
        self.stagedVersion &+= 1
        self.deleteMode = false
        self.executePrompt = nil
    }

    /// 清除当前已导入的文件，回到空状态
    func clearTrack() {
        discardStagedAndExit()
        track = nil
        stats = PerfStats()
        hover = nil
        selected = nil
        currentFileURLs = []
        scaleBar = nil
        viewFilter = nil
        viewFilterSpec = nil
        files = []
        displayMode = .single
        compareTracks = nil
        compareSwap = false
    }

    /// 当前可见索引区间（时间筛选后；无筛选 = 全量）
    func visibleIndexRange() -> (start: Int, len: Int) {
        guard let track else { return (0, 0) }
        guard let f = viewFilter, track.isTimeSorted else { return (0, track.count) }
        return track.indexRange(forTimeRange: (f.start, f.end))
    }

    private func fail(_ error: Error) {
        noteUserActivity()   // 错误弹窗即将出现，不能被闲置待机盖住
        isLoading = false
        loadingLabel = ""
        loadingProgress = nil
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - 渲染统计（节流 + 脱离更新周期发布）

    nonisolated func pushRenderStats(_ frame: FrameStats) {
        Task { @MainActor in
            let now = CACurrentMediaTime()
            guard now - self.lastStatsPush > 0.25 else { return }
            self.lastStatsPush = now
            self.stats.encodeMs = frame.encodeMs
            self.stats.waitMs = frame.waitMs
            self.stats.gpuMs = frame.gpuMs
            self.stats.fps = frame.fps
            self.stats.drawnPoints = frame.drawn
            self.stats.lodStride = frame.stride
        }
    }

    func pushHoverMicros(_ micros: Double) {
        let now = CACurrentMediaTime()
        guard now - lastHoverPush > 0.25 else { return }
        lastHoverPush = now
        stats.hoverMicros = micros
    }

    func pushScaleBar(_ info: ScaleBarInfo?) {
        guard scaleBar != info else { return }
        let now = CACurrentMediaTime()
        // 隐藏（nil）必须立即生效：进入地球前一帧刚更新过比例尺时，
        // 节流会把 nil 吞掉，导致球面上残留 "200 km"
        if info != nil {
            guard now - lastScalePush > 0.12 else { return }
        }
        lastScalePush = now
        scaleBar = info
    }

    // MARK: - 导出

    /// range 为 nil 时导出全部点；时间戳缺失的点仅在导出全部时包含
    func countPoints(in range: (Double, Double)?) -> Int {
        guard let track else { return 0 }
        guard let r = range else { return track.count }
        var c = 0
        for t in track.time where t >= r.0 && t < r.1 { c += 1 }   // NaN 比较为 false，自动排除
        return c
    }

    /// 数据时间跨度是否只有一天（此时导出无需时间选择，直接导出）
    var exportNeedsSheet: Bool {
        guard let track, let tr = track.timeRange else { return false }
        return !Calendar.current.isDate(Date(timeIntervalSince1970: tr.min),
                                        inSameDayAs: Date(timeIntervalSince1970: tr.max))
    }

    /// 导出命名：a → a_GPVexported；a_GPVexported → a_GPVexported_2；a_GPVexported_3 → a_GPVexported_4
    static func exportedFileName(from base: String) -> String {
        if let r = base.range(of: "_GPVexported(_[0-9]+)?$", options: .regularExpression) {
            let prefix = String(base[base.startIndex..<r.lowerBound])
            let parts = String(base[r]).dropFirst().split(separator: "_")   // ["GPVexported"] 或 ["GPVexported","3"]
            let n = parts.count >= 2 ? (Int(parts[1]) ?? 1) : 1
            return "\(prefix)_GPVexported_\(n + 1)"
        }
        return "\(base)_GPVexported"
    }

    func exportGPX(range: (Double, Double)?) {
        guard let track else { return }
        let exportName = Self.exportedFileName(from: track.name)
        let panel = NSSavePanel()
        var types: [UTType] = [.xml]
        if let gpx = UTType(filenameExtension: "gpx") { types = [gpx] }
        panel.allowedContentTypes = types
        panel.nameFieldStringValue = "\(exportName).gpx"
        panel.message = "选择导出位置"
        let panelResult = panel.runModal()
        noteUserActivity()   // 存盘对话框同 openPanel：关闭瞬间计时已过期
        guard panelResult == .OK, let url = panel.url else { return }

        isLoading = true
        loadingLabel = "并行导出 GPX…"
        Task.detached(priority: .userInitiated) { [weak self] in
            var indices = [Int32]()
            indices.reserveCapacity(track.count)
            if let r = range {
                for i in 0..<track.count {
                    let t = track.time[i]
                    if t >= r.0, t < r.1 { indices.append(Int32(i)) }
                }
            } else {
                for i in 0..<track.count { indices.append(Int32(i)) }
            }
            do {
                try GPXWriter.write(track: track, indices: indices, name: exportName, to: url)
                guard let self else { return }
                await MainActor.run {
                    self.noteUserActivity()   // 后台导出完成，计时基准已过期
                    self.isLoading = false
                    self.loadingLabel = ""
                }
            } catch {
                guard let self else { return }
                await MainActor.run {
                    self.noteUserActivity()
                    self.isLoading = false
                    self.loadingLabel = ""
                    self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    // MARK: - 预删除（暂存式框选删除事务）

    /// 进入删除模式：随后的圈选只做"预删除"标记（灰显），真实数据不动
    func enterDeleteMode() {
        // 重叠/对比模式禁用删除：跨文件删点后关闭文件会复活已删点，语义不成立
        guard let track, displayMode == .single else { return }
        stagedMask = [Bool](repeating: false, count: track.count)
        stagedHistory = []
        stageSteps = 0
        stagedCount = 0
        stagedDisplayColors = nil
        stagedVersion &+= 1
        deleteMode = true
    }

    /// 放弃本次预删除并退出（什么都不删）
    func discardStagedAndExit() {
        stagedMask = []
        stagedHistory = []
        stageSteps = 0
        stagedCount = 0
        stagedDisplayColors = nil
        stagedVersion &+= 1
        executePrompt = nil
        selectionPath = nil
        deleteMode = false
    }

    func toggleDeleteMode() {
        if deleteMode { discardStagedAndExit() } else { enterDeleteMode() }
    }

    /// 圈选追加预删除点（跨多次圈选去重）。每次圈选是一步，可多步撤销。
    func stagePoints(_ indices: [Int32]) {
        guard deleteMode, let track, stagedMask.count == track.count, !indices.isEmpty else { return }
        var added = [Int32]()
        added.reserveCapacity(indices.count)
        for i in indices {
            let k = Int(i)
            if !stagedMask[k] {
                stagedMask[k] = true
                added.append(i)
            }
        }
        guard !added.isEmpty else { return }
        stagedCount += added.count
        stagedHistory.append(added)
        stageSteps = stagedHistory.count
        rebuildStagedColors()
    }

    /// 撤销上一步圈选（可连续撤销到零，像 Word 一样）
    func undoStage() {
        guard deleteMode, let last = stagedHistory.popLast() else { return }
        for i in last {
            stagedMask[Int(i)] = false
        }
        stagedCount -= last.count
        stageSteps = stagedHistory.count
        rebuildStagedColors()
    }

    private func rebuildStagedColors() {
        guard let track else { return }
        if stagedCount > 0 {
            var colors = track.colors
            colors.withUnsafeMutableBufferPointer { buf in
                for k in 0..<stagedMask.count where stagedMask[k] {
                    let o = k * 4
                    buf[o] = 128; buf[o + 1] = 128; buf[o + 2] = 128; buf[o + 3] = 60
                }
            }
            stagedDisplayColors = colors
        } else {
            stagedDisplayColors = nil
        }
        stagedVersion &+= 1
    }

    /// 「执行删除」按钮 → 弹确认框
    func requestExecuteStaged() {
        guard stagedCount > 0 else { return }
        executePrompt = stagedCount
    }

    /// 确认框选"确认"：真删除，整批一次落地，并退出删除模式。
    /// （预删除阶段随时可逐步撤销；确认对话框是最终关口）
    func confirmExecuteStaged() {
        executePrompt = nil
        guard let current = track, stagedCount > 0 else {
            discardStagedAndExit()
            return
        }
        var indices = [Int32]()
        indices.reserveCapacity(stagedCount)
        for k in 0..<stagedMask.count where stagedMask[k] {
            indices.append(Int32(k))
        }
        stagedMask = []
        stagedHistory = []
        stageSteps = 0
        stagedCount = 0
        stagedDisplayColors = nil
        stagedVersion &+= 1
        deleteMode = false
        performDeletion(of: indices, from: current)
    }

    private func performDeletion(of toDelete: [Int32], from current: TrackData) {
        isLoading = true
        loadingLabel = "删除 \(toDelete.count.formatted()) 个点…"
        let mode = settings.colorMode
        let single = singleRGBA()

        Task.detached(priority: .userInitiated) { [weak self] in
            var keep = [Bool](repeating: true, count: current.count)
            for i in toDelete { keep[Int(i)] = false }
            let kept = current.count - toDelete.count
            var p = ParsedTrack()
            p.lat.reserveCapacity(kept)
            p.lon.reserveCapacity(kept)
            p.ele.reserveCapacity(kept)
            p.time.reserveCapacity(kept)
            for i in 0..<current.count where keep[i] {
                p.lat.append(current.lat[i])
                p.lon.append(current.lon[i])
                p.ele.append(current.ele[i])
                p.time.append(current.time[i])
            }
            p.name = current.name
            p.chunkCount = ProcessInfo.processInfo.activeProcessorCount
            let (newTrack, newStats) = TrackData.build(parsed: p, preferredMode: mode, singleColor: single)
            guard let self else { return }
            let keptParsed = p
            await MainActor.run {
                self.preserveNextCamera = true
                // 单文件留底同步为删除后的数据，防止之后重建/切模式复活已删点
                if self.files.count == 1 {
                    self.files[0].parsed = keptParsed
                }
                self.apply(track: newTrack, stats: newStats)
            }
        }
    }
}

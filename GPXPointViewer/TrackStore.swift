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
import CoreLocation
import UniformTypeIdentifiers
import QuartzCore

/// 显示模式：单文件（新文件替换旧的）/ 重叠（多文件同图不同色）/ 对比（两文件左右分屏）
enum DisplayMode: String, CaseIterable, Identifiable {
    case single = "单文件"
    case overlay = "重叠"
    case compare = "对比"
    var id: String { rawValue }

    /// 界面显示用（rawValue 只当标识，不直接显示）
    var title: LocalizedStringKey {
        switch self {
        case .single: return "单文件"
        case .overlay: return "重叠"
        case .compare: return "对比"
        }
    }
}

/// 高清图片导出选项
struct ImageExportOptions {
    var pixelWidth: Int              // 3840（4K）/ 7680（8K）
    var transparentBackground: Bool  // 平面 = 只导点云；地球 = 透明太空
    var includeScaleBar: Bool        // 仅平面且非透明背景时有效
}

/// 已载入的单个 GPX 文件（重叠/对比模式的留底：关闭其他文件后据此重建显示轨迹）
struct LoadedFile: Identifiable {
    let id = UUID()
    var name: String
    var url: URL?
    var parsed: ParsedTrack
    var color: Color
    var fogVisible: Bool = true   // 迷雾模式下该文件是否参与消雾（列表勾选）
}

/// 一个已导入的 .fwdb 迷雾存档（多存档可勾选显隐，渲染/统计用并集）
struct LoadedArchive: Identifiable {
    let id = UUID()
    var name: String
    var url: URL
    let archive: FogArchive
    var enabled: Bool = true
}

@MainActor
final class FillOverlayState: ObservableObject {
    @Published var overlay = TrackStore.FillOverlay()
}

@MainActor
final class Heat3DCamState: ObservableObject {
    @Published var yaw: Float = 0
}

@MainActor
final class TrackStore: ObservableObject {
    @Published var track: TrackData? {
        didSet { if oldValue?.id != track?.id { invalidateDataOperations() } }
    }
    /// 渲染统计、悬停、比例尺三样高频小状态各自成对象：只有观察它们的小视图重算，
    /// 整个 ContentView（两千行、所有浮层）不再因鼠标每动一下 / 每秒四次帧率刷新而重算
    let renderStats = RenderStatsState()
    let hoverState = HoverState()
    let scaleBarState = ScaleBarState()
    var stats: PerfStats {
        get { renderStats.stats }
        set { renderStats.stats = newValue }
    }
    @Published var settings = ViewSettings()
    var hover: PointInfo? {
        get { hoverState.info }
        set { if hoverState.info != newValue { hoverState.info = newValue } }
    }
    @Published var selected: PointInfo?
    @Published var isLoading = false
    @Published var loadingLabel = ""
    @Published var loadingProgress: Double?          // 确定进度 0…1；nil = 不确定（转圈）
    @Published var errorMessage: String?
    var scaleBar: ScaleBarInfo? {
        get { scaleBarState.info }
        set { if scaleBarState.info != newValue { scaleBarState.info = newValue } }
    }
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

    private var publicationClock = DataPublicationClock()
    private var editBaseline: ParsedTrack?
    /// Offline regression seam: delay publication without sleeping or changing workers.
    /// Nil in the app. Releasing a gate always revalidates document ownership.
    var publicationGate: ((DataPublicationToken, @escaping @MainActor () -> Void) -> Void)?

    private func invalidateDataOperations() {
        publicationClock.invalidate()
        isLoading = false; loadingLabel = ""; loadingProgress = nil
        reviewBuilding = false; reviewRebuildPending = false
        diffBusy = false
        candidatesRefreshing = false
        // These workers already carry request IDs/generations. Revoke those
        // owners here as well, so accepted input changes invalidate every lane.
        cancelRouteDraft()
        cancelTripMap()
        invalidateBatch()
    }
    private func beginDataOperation(source: TrackData? = nil) -> DataPublicationToken {
        invalidateDataOperations()
        return publicationClock.begin(fileIDs: files.map(\.id), sourceID: source?.id)
    }
    private func owns(_ token: DataPublicationToken) -> Bool {
        publicationClock.accepts(token, fileIDs: files.map(\.id), sourceID: track?.id)
    }
    private func publishData(_ token: DataPublicationToken, _ body: @escaping @MainActor () -> Void) {
        let commit: @MainActor () -> Void = { [weak self] in
            guard let self, self.owns(token) else { return }
            body()
        }
        if let gate = publicationGate { gate(token, commit) } else { commit() }
    }
    /// Confirmation sheets defer actual mutation to the next runloop. Capture
    /// the source now, not when that deferred block finally starts.
    private func enqueueEdit(_ action: @escaping @MainActor (TrackStore) -> Void) {
        guard let sourceID = track?.id else { return }
        let revision = publicationClock.revision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.track?.id == sourceID, self.publicationClock.revision == revision else { return }
            action(self)
        }
    }
    private func rememberEditBaseline(_ parsed: ParsedTrack) {
        if editBaseline == nil { editBaseline = parsed }
    }

    /// 协调器注册的"用户活动"回调：导入/拖放/对话框等非鼠标事件
    /// 也要重置闲置计时（否则拖入文件刚解析完就进入闲置展示）
    var onUserActivity: (() -> Void)?
    func noteUserActivity() { onUserActivity?() }

    // MARK: - 多文件（单文件/重叠/对比）

    @Published var files: [LoadedFile] = [] {
        didSet { if oldValue.map(\.id) != files.map(\.id) { invalidateDataOperations() } }
    }
    @Published var displayMode: DisplayMode = .single {
        didSet { if oldValue != displayMode { invalidateDataOperations() } }
    }
    /// 文件列表点击 → 地图高亮闪烁（协调器消费版本号）
    @Published private(set) var flashVersion = 0
    private(set) var flashFileIndex: Int?
    /// 定位到轨迹起点（协调器消费版本号）
    @Published private(set) var locateVersion = 0

    // MARK: - 迷雾统计（《世界迷雾》口径，按轨迹缓存）

    @Published var showFogStats = false
    @Published private(set) var fogStats: FogStats?
    private var fogStatsTrackID: UUID?

    // MARK: - 迷雾存档（.fwdb 直接作为数据源；支持多存档勾选显隐）

    @Published private(set) var fogArchiveFiles: [LoadedArchive] = []
    /// 勾选中存档的并集（渲染与统计对象；全部取消勾选时为 nil = 全幅是雾）
    @Published private(set) var fogArchive: FogArchive?
    @Published private(set) var fwdbVersion = 0       // 数据/勾选换代（协调器清实例缓存）
    @Published private(set) var fwdbZoomVersion = 0   // 仅导入时飞到存档范围
    private var fwdbMergeGen = 0                      // 合并任务代号（丢弃过期结果）
    private var fwdbZoomPending = false               // 导入后等新并集落地再飞相机

    /// 存档模式：以 .fwdb 为数据源（无 GPX 轨迹）
    var fwdbActive: Bool { !fogArchiveFiles.isEmpty && track == nil }

    /// 导入一个或多个 .fwdb 迷雾存档：替换 GPX 数据源，自动切到迷雾模式。
    /// 已在存档模式时追加（同路径替换旧档）；渲染与统计取勾选存档的格子并集。
    /// 解析全程后台（区块级并行 zlib 解码），主线程只做状态切换
    func loadFwdb(urls: [URL]) {
        guard !isLoading, !urls.isEmpty else { return }
        let token = beginDataOperation()
        noteUserActivity()
        routeCache.clear()   // 换数据源：路网结果缓存作废
        invalidateRegionReport()   // 同 load：换数据源的瞬间撤下旧报告
        isLoading = true
        loadingLabel = urls.count == 1
            ? String(localized: "解析迷雾存档…", comment: "Loading overlay while parsing one Fog of World archive (.fwdb)")
            : String(localized: "解析 \(urls.count) 个迷雾存档…", comment: "Loading overlay while parsing several Fog of World archives; %lld = number of archives")
        loadingProgress = nil
        let secured = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                for (u, ok) in secured where ok { u.stopAccessingSecurityScopedResource() }
            }
            var parsed: [(URL, FogArchive)] = []
            for url in urls {
                if let a = FogArchive.load(url: url) { parsed.append((url, a)) }
            }
            guard let self else { return }
            let ok = parsed
            await self.publishData(token) {
                self.isLoading = false
                self.loadingLabel = ""
                guard !ok.isEmpty else {
                    self.fail(GPXParseError.fwdbInvalid)
                    return
                }
                if !self.fwdbActive {
                    self.clearTrack()                // 存档替换 GPX 数据源
                }
                for (url, a) in ok {
                    let entry = LoadedArchive(name: url.deletingPathExtension().lastPathComponent,
                                              url: url, archive: a)
                    if let i = self.fogArchiveFiles.firstIndex(where: { $0.url.path == url.path }) {
                        self.fogArchiveFiles[i] = entry   // 同路径重拖 = 替换
                    } else {
                        self.fogArchiveFiles.append(entry)
                    }
                }
                self.fogStatsTrackID = nil
                self.showFogStats = true
                self.settings.heatMap = false   // 直接同步写：绕开 updateSetting 的
                self.settings.fogMap = true     // 延迟落地，避免与在途互斥写交错
                self.fwdbZoomPending = true          // 新并集落地时再飞（防飞向旧范围）
                if ok.count < urls.count {
                    let skipped = urls.count - ok.count
                    self.errorMessage = String(localized: "已跳过 \(skipped) 个无法解析的迷雾存档。", comment: "Error alert after importing Fog of World archives; %lld = number of archives that could not be parsed")
                }
                self.rebuildMergedArchive()
            }
        }
    }

    /// 勾选/取消一个存档的显示
    func toggleArchive(_ id: UUID) {
        guard let i = fogArchiveFiles.firstIndex(where: { $0.id == id }) else { return }
        noteUserActivity()
        fogArchiveFiles[i].enabled.toggle()
        rebuildMergedArchive()
    }

    /// 关闭（移除）一个存档；全空则退出存档模式。
    /// 仅剩一档时强制勾选：列表面板随 count>1 消失，留个未勾选档就没法再恢复了
    func closeArchive(_ id: UUID) {
        guard let i = fogArchiveFiles.firstIndex(where: { $0.id == id }) else { return }
        noteUserActivity()
        fogArchiveFiles.remove(at: i)
        if fogArchiveFiles.count == 1 { fogArchiveFiles[0].enabled = true }
        rebuildMergedArchive()
    }

    /// 后台重算勾选存档的并集（排序合并去重 + 金字塔重建，80 万格几十毫秒）
    private func rebuildMergedArchive() {
        let token = publicationClock.begin(.fogArchive, fileIDs: files.map(\.id))
        fwdbMergeGen &+= 1
        let gen = fwdbMergeGen
        let enabled = fogArchiveFiles.filter(\.enabled).map(\.archive)
        let name = fogArchiveFiles.count == 1 ? fogArchiveFiles[0].name
                                              : "merge_\(fogArchiveFiles.count)"
        fwdbMergePending = !enabled.isEmpty
        if enabled.isEmpty {
            fwdbZoomPending = false
            fogArchive = nil
            fogStats = fogArchiveFiles.isEmpty ? nil
                     : FogStats(cells: 0, km2: 0, level: 0, percent: 0, nextLevelKm2: 0.004)
            fwdbVersion &+= 1
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let merged = FogArchive.merged(name: name, enabled)
            guard let self else { return }
            await MainActor.run {
                guard self.owns(token), gen == self.fwdbMergeGen,                  // 已被更新合并/清空作废
                      !self.fogArchiveFiles.isEmpty else { return }
                self.fwdbMergePending = false
                self.fogArchive = merged
                self.fogStats = merged?.stats
                self.fwdbVersion &+= 1
                if self.fwdbZoomPending {
                    self.fwdbZoomPending = false
                    if merged != nil { self.fwdbZoomVersion &+= 1 }
                }
            }
        }
    }

    // MARK: - 底图透明度渐变（进迷雾时快速拉满，滑轨跟随平滑移动）

    private var mapOpacityAnimTimer: Timer?

    /// 以 ~60fps 步进 settings.mapOpacity 到目标值：绑定它的滑杆随动、
    /// 地图压暗层逐帧过渡，都不会"闪现"
    func animateMapOpacity(to target: Double, duration: Double = 0.35) {
        mapOpacityAnimTimer?.invalidate()
        let start = settings.mapOpacity
        guard abs(start - target) > 0.001 else { return }
        let t0 = CACurrentMediaTime()
        mapOpacityAnimTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0,
                                                   repeats: true) { [weak self] tm in
            Task { @MainActor in
                guard let self else { tm.invalidate(); return }
                let u = min(1.0, (CACurrentMediaTime() - t0) / duration)
                let sm = u * u * (3 - 2 * u)
                self.settings.mapOpacity = start + (target - start) * sm
                if u >= 1 { tm.invalidate() }
            }
        }
    }

    // MARK: - 3D 热力柱相机（罗盘单独观察，旋转时 60fps 更新不惊扰整棵视图树）

    let heat3DCam = Heat3DCamState()
    @Published private(set) var heat3DNorthPoke = 0

    /// 罗盘点击：平滑转回北向上
    func heat3DPointNorth() {
        noteUserActivity()
        heat3DNorthPoke &+= 1
    }

    // MARK: - 时光机回放

    @Published private(set) var playback: PlaybackSession?
    @Published private(set) var playbackPoke = 0    // 暂停时 scrub/时长变化触发重绘
    @Published var showVideoExportSheet = false     // 回放视频导出面板
    @Published private(set) var videoExportVersion = 0
    private(set) var videoExportOptions: VideoExportOptions?

    private(set) var videoExporting = false

    func requestVideoExport(_ options: VideoExportOptions) {
        guard !videoExporting else { return }    // 防重入：并发导出会互删输出文件
        noteUserActivity()
        videoExportOptions = options
        videoExportVersion &+= 1
    }

    private var videoExportOwner: UUID?
    func videoExportBegan() -> DataPublicationToken {
        let token = beginDataOperation(source: track)
        videoExportOwner = token.owner
        videoExporting = true
        isLoading = true
        loadingLabel = String(localized: "导出视频…", comment: "Loading overlay while a video is being exported")
        loadingProgress = 0
        return token
    }

    @discardableResult
    nonisolated func videoExportProgress(_ p: Double, owner token: DataPublicationToken) -> Task<Void, Never> {
        Task { @MainActor in
            guard self.owns(token), self.videoExportOwner == token.owner else { return }
            self.loadingProgress = p
        }
    }

    func videoExportFinished(error: String?, url: URL, owner token: DataPublicationToken) {
        guard videoExportOwner == token.owner else { return }
        videoExportOwner = nil
        videoExporting = false
        guard owns(token) else { return }
        isLoading = false
        loadingLabel = ""
        loadingProgress = nil
        noteUserActivity()
        if let error {
            errorMessage = String(localized: "视频导出失败：\(error)", comment: "Error alert; %@ = reason reported by the video exporter")
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// 有可回放的时间线（GPX 时间有序 / 存档区块时间 ≥2 个）
    var playbackAvailable: Bool {
        if track != nil { return track!.isTimeSorted && track!.timeRange != nil }
        if let a = fogArchive { return a.genTimes.count > 1 }
        return false
    }

    /// 启动时光机：后台规划（会话切分 → 活跃簇 → 相机路径 → 时间弯曲）后开播
    func startPlayback(duration: Double = 45) {
        guard playback == nil, !isLoading, !fillMode, !deleteMode else { return }
        // DeepSeek 2026-11-01：记住用户上次选的时长
        let chosen = UserDefaults.standard.object(forKey: "playbackDuration") as? Double ?? duration
        noteUserActivity()
        if settings.heat3D { settings.heat3D = false }   // 3D 热力与回放互斥
        if let track, track.isTimeSorted {
            let token = publicationClock.begin(.playback, fileIDs: files.map(\.id), sourceID: track.id)
            Task.detached(priority: .userInitiated) { [weak self] in
                let evs = PlaybackPlan.events(track: track)
                let plan = PlaybackPlan.buildCities(events: evs, duration: chosen)
                guard let self else { return }
                // DeepSeek 2026-11-01：LOD 建层放到后台规划阶段（约 183ms/650k 点）
                var lodLevels: [PointLODLevel] = []
                if let cp = plan?.cityPlan {
                    for c in cp.cities {
                        let base = max(c.x1 - c.x0, c.y1 - c.y0) * 1.15
                        lodLevels += PointLODBuilder.build(track: track, center: (c.cx, c.cy),
                                                           baseSpan: max(base, 0.001), levels: 5)
                    }
                }
                await MainActor.run {
                    guard self.owns(token) else { return }
                    guard let plan else {
                        self.errorMessage = String(localized: "数据时间跨度太短，无法回放。", comment: "Error alert: the track's time span is too short for the Timelapse playback")
                        return
                    }
                    guard !self.fillMode, !self.deleteMode else { return }   // 规划期间进了编辑模式
                    var adjusted = plan
                    let reveal = adjusted.cityPlan.flatMap { PlaybackRevealData(track: track, plan: $0) }
                    if let reveal {
                        self.refineCityQuantiles(&adjusted, track: track, reveal: reveal)
                    }
                    self.playback = PlaybackSession(
                        plan: adjusted, events: evs, isArchive: false,
                        reveal: reveal, lodLevels: lodLevels)
                }
            }
        } else if let archive = fogArchive {
            let evs = PlaybackPlan.events(archive: archive)
            guard let plan = PlaybackPlan.build(events: evs, duration: chosen) else {
                errorMessage = String(localized: "迷雾存档没有可用的时间线（区块时间戳单一）。", comment: "Error alert: the Fog of World archive has no usable timeline for playback (all blocks share one timestamp)")
                return
            }
            playback = PlaybackSession(plan: plan, events: evs, isArchive: true)
        }
    }

    func stopPlayback() {
        guard playback != nil else { return }
        noteUserActivity()
        playback = nil
        playbackPoke &+= 1
    }

    /// 调整总时长（重建规划，进度按比例保持）
    func setPlaybackDuration(_ d: Double) {
        // DeepSeek 2026-11-01：改时长后从头重播，并记住这个选项
        UserDefaults.standard.set(d, forKey: "playbackDuration")
        guard let pb = playback else { return }
        noteUserActivity()
        let plan = pb.isArchive
            ? PlaybackPlan.build(events: pb.events, duration: d)
            : PlaybackPlan.buildCities(events: pb.events, duration: d)
        guard let plan else { return }
        var adjusted = plan
        if !pb.isArchive, let track {
            let reveal = adjusted.cityPlan.flatMap { PlaybackRevealData(track: track, plan: $0) }
            if let reveal { refineCityQuantiles(&adjusted, track: track, reveal: reveal) }
            pb.reveal = reveal
            pb.revealVersion &+= 1
        }
        pb.plan = adjusted
        pb.clock.head = 0
        pb.clock.playing = true
        playbackPoke &+= 1
    }

    /// DeepSeek 2026-11-01：多城逐城用“真实点时间 + 活动间隔 + 新覆盖格子”建游标曲线。
    private func refineCityQuantiles(_ plan: inout PlaybackPlan, track: TrackData,
                                     reveal: PlaybackRevealData) {
        guard var cp = plan.cityPlan, !cp.cities.isEmpty, track.count > 1 else { return }
        var idxByArea = [[Int]](repeating: [], count: cp.cities.count)
        for p in 0..<track.count {
            let a = Int(reveal.areaOfPoint[p])
            if a >= 0 && a < cp.cities.count { idxByArea[a].append(p) }
        }
        var allQ = [[Double]](repeating: [], count: cp.cities.count)
        for ci in cp.cities.indices {
            var idx = idxByArea[ci]
            guard idx.count > 1 else { continue }
            idx.sort { track.time[$0] < track.time[$1] }
            // 按活动间隔（>30 分钟无点）切段
            let activityGap: Double = 30 * 60
            var ranges: [Range<Int>] = []
            var start = 0
            for k in 1..<idx.count where track.time[idx[k]] - track.time[idx[k - 1]] > activityGap {
                ranges.append(start..<k); start = k
            }
            ranges.append(start..<idx.count)
            let c = cp.cities[ci]
            let x0 = c.x0, x1 = max(c.x1, c.x0 + 1e-9)
            let y0 = c.y0, y1 = max(c.y1, c.y0 + 1e-9)
            let cols = 320, rows = 180
            var seen = Set<Int>()
            var segs: [(t0: Double, t1: Double, w: Double)] = []
            for r in ranges {
                let t0 = track.time[idx[r.lowerBound]]
                let t1 = track.time[idx[r.upperBound - 1]]
                var novel = 0.0
                for j in r {
                    let i = idx[j]
                    let cx = min(cols - 1, max(0, Int((track.mercX[i] - x0) / (x1 - x0) * Double(cols))))
                    let cy = min(rows - 1, max(0, Int((track.mercY[i] - y0) / (y1 - y0) * Double(rows))))
                    if seen.insert(cy * cols + cx).inserted { novel += 1 }
                }
                segs.append((t0, t1, novel))
            }
            var total = segs.reduce(0.0) { $0 + $1.w }
            if total < 1 { for i in segs.indices { segs[i].w = 1 }; total = Double(segs.count) }
            var q = [Double](repeating: segs[0].t0, count: 1024)
            var si = 0, cum = 0.0
            for k in 0...1023 {
                let target = total * Double(k) / 1023.0
                while si + 1 < segs.count && cum + segs[si].w < target { cum += segs[si].w; si += 1 }
                let f = segs[si].w > 0 ? min(1, max(0, (target - cum) / segs[si].w)) : 1
                q[k] = segs[si].t0 + (segs[si].t1 - segs[si].t0) * f
            }
            // 城市章节开头留 3% 的空场：镜头到位时城市必须是空的
            let holdCount = Int(Double(q.count) * 0.08)
            for k in 0..<holdCount { q[k] = segs[0].t0 - 1 }
            q[0] = segs[0].t0 - 1
            q[1023] = segs.last!.t1
            if let t0 = segs.first?.t0, let t1 = segs.last?.t1, t1 > t0 {
                let step = max(1.0, (t1 - t0) / Double(q.count) * 0.05)
                for k in 1..<q.count where q[k] <= q[k - 1] { q[k] = min(t1, q[k - 1] + step) }
            }
            allQ[ci] = q
        }
        cp.cityTimeAt = allQ
        plan.cityPlan = cp
    }

    /// 暂停状态下拖动时间轴后要求协调器立即应用帧
    func pokePlayback() {
        playbackPoke &+= 1
    }

    /// 迷雾模式下 GPX 文件显隐（重叠模式列表勾选；GPU 端按 fileID 位掩码过滤）
    func setFileFogVisible(_ id: UUID, _ visible: Bool) {
        guard let i = files.firstIndex(where: { $0.id == id }) else { return }
        noteUserActivity()
        files[i].fogVisible = visible
    }

    /// 文件可见位掩码（≤32 个文件）。仅重叠模式生效：单文件轨迹没有
    /// fileID 缓冲（GPU 端是 2 字节占位，读到的是垃圾位），必须全可见
    var fogFileMask: UInt32 {
        guard displayMode == .overlay, !files.isEmpty,
              track?.fileID.isEmpty == false else { return .max }
        var m: UInt32 = 0
        for (i, f) in files.enumerated() where f.fogVisible && i < 32 { m |= 1 << UInt32(i) }
        return m
    }

    /// 打开统计或数据换代后触发后台计算（同轨迹只算一次）
    func ensureFogStats() {
        guard fogArchiveFiles.isEmpty else { return }   // 存档统计已直接就位
        guard let track else { return }
        guard fogStatsTrackID != track.id else { return }
        let token = publicationClock.begin(.fogStats, fileIDs: files.map(\.id), sourceID: track.id)
        fogStatsTrackID = track.id
        fogStats = nil
        Task.detached(priority: .utility) { [weak self] in
            let stats = track.computeFogStats()
            guard let self else { return }
            await MainActor.run {
                if self.owns(token), self.track?.id == track.id { self.fogStats = stats }
            }
        }
    }

    // MARK: - 行政区统计（国家 / 省州 / 中国地级；对标《世界迷雾》行政区卡片）

    @Published private(set) var regionReport: RegionReport?
    @Published var regionsMode: RegionReport.Mode = .points {
        didSet { if regionsMode != oldValue { ensureRegionReport() } }
    }
    /// 用户（或等价的钩子）手动选过的口径：之后不再随显示模式自动切换（存档模式仍强制迷雾；离开存档后恢复这个选择）
    private(set) var regionsModeManualChoice: RegionReport.Mode?
    var regionsModeManual: Bool { regionsModeManualChoice != nil }
    @Published private(set) var regionSelection: UInt16?
    @Published private(set) var regionFocusVersion = 0     // 选中地区 → 边界高亮 + 飞过去（协调器消费）
    private(set) var regionFly = true
    private var regionReportKey = ""
    private var regionDataKey = ""          // key 里的数据源部分（只有它变了才清高亮）
    private var regionReportGen = 0
    private var regionTask: Task<Void, Never>?
    private var fwdbMergePending = false      // 存档合并在途（地区统计等它落地再算）

    /// 当前数据源能做哪些口径：GPX 轨迹 = 点 + 迷雾；.fwdb 存档 = 只有迷雾
    var regionModesAvailable: [RegionReport.Mode] { fwdbActive ? [.fog] : [.points, .fog] }

    /// 打开窗口 / 数据换代 / 切口径时触发后台计算（同一数据源 + 口径只算一次；窗口没开就不算）
    func ensureRegionReport() {
        guard let index = RegionIndex.shared, !index.isEmpty else { regionReport = nil; return }
        if fwdbActive, regionsMode != .fog { regionsMode = .fog; return }   // didSet 再进来
        let mode = regionsMode
        let dataKey: String
        if fwdbActive { dataKey = "fwdb|\(fwdbVersion)" }
        else if let t = track { dataKey = "track|\(t.id)" }
        else {
            regionReportKey = ""; regionDataKey = ""; regionReport = nil
            regionReportGen &+= 1                                           // 在途结果作废（清空后不能再冒出来）
            if regionSelection != nil { selectRegion(nil, fly: false) }
            return
        }
        if dataKey != regionDataKey {
            regionDataKey = dataKey
            if regionSelection != nil { selectRegion(nil, fly: false) }      // 换数据才清高亮；只换口径不清
        }
        // 存档合并还在路上（刚拖入 / 刚换勾选）：先不算空结果，等 fwdbVersion 落地再算
        if fwdbActive, fwdbMergePending {
            regionReportKey = ""; regionReport = nil; regionReportGen &+= 1; regionTask?.cancel()
            return
        }
        let key = dataKey + "|" + mode.rawValue
        guard key != regionReportKey else { return }
        regionReportKey = key
        regionReport = nil
        regionReportGen &+= 1
        regionTask?.cancel()
        let gen = regionReportGen
        let token = publicationClock.begin(.regions, fileIDs: files.map(\.id), sourceID: track?.id)
        let track = self.track
        let archiveKeys: [UInt64]? = fwdbActive ? (fogArchive?.levelKeys[0] ?? []) : nil
        regionTask = Task.detached(priority: .utility) { [weak self] in
            let report: RegionReport
            switch mode {
            case .points:
                guard let track else { return }
                report = RegionStatsBuilder.points(track: track, index: index)
            case .fog:
                let keys: [UInt64]
                if let archiveKeys { keys = archiveKeys } else if let track { keys = track.fogUnlockKeys() } else { return }
                report = RegionStatsBuilder.fog(keys: keys, index: index)
            }
            guard let self else { return }
            await MainActor.run {
                guard self.owns(token), self.regionReportGen == gen else { return }
                self.regionReport = report
            }
        }
    }

    /// 数据换代的瞬间就把旧报告撤下（不等窗口的 onChange 再算），在途任务作废
    private func invalidateRegionReport() {
        publicationClock.cancel(.regions)
        regionReportKey = ""; regionReportGen &+= 1; regionTask?.cancel()
        if regionReport != nil { regionReport = nil }
    }

    /// 窗口里的口径选择器 / 钩子 regionsmode：记为手动选过（存档模式下选点无效，仍是迷雾）
    func pickRegionsMode(_ m: RegionReport.Mode) {
        regionsModeManualChoice = m
        let want: RegionReport.Mode = fwdbActive ? .fog : m
        if regionsMode != want { regionsMode = want }
    }

    /// 按显示模式给默认口径（窗口打开、换数据、显示模式变化时调用）：存档只有迷雾；手动选过就用那个；否则迷雾模式 → 迷雾，查看点 → 点
    func autoRegionsMode() {
        let want: RegionReport.Mode
        if fwdbActive { want = .fog }
        else if let m = regionsModeManualChoice { want = m }
        else { want = settings.fogMap ? .fog : .points }
        if regionsMode != want { regionsMode = want }
    }

    /// 选中地区：地图画边界、（可选）飞到其外接框；nil = 清除高亮
    func selectRegion(_ id: UInt16?, fly: Bool = true) {
        noteUserActivity()
        regionSelection = id
        regionFly = fly
        regionFocusVersion &+= 1
    }

    // MARK: - 高清图片导出

    @Published var showImageExportSheet = false
    @Published private(set) var imageExportVersion = 0
    private(set) var imageExportOptions: ImageExportOptions?

    func requestImageExport(_ options: ImageExportOptions) {
        noteUserActivity()
        imageExportOptions = options
        imageExportVersion &+= 1
    }

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
        guard mode != displayMode, mode != .compare || files.count == 2 else { return }
        invalidateDataOperations()
        noteUserActivity()
        if fillMode { exitFillMode() }      // 补点只在单文件模式下成立
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
            clearDiff(recolorPanes: false)
            compareTracks = nil
            compareSwap = false
        }
    }

    /// 对比模式：两文件各自独立 build（后台并行），完成后一次发布
    private func buildCompareTracks() {
        guard files.count == 2 else { return }
        let token = beginDataOperation()
        clearDiff(recolorPanes: false)
        compareTracks = nil
        isLoading = true
        loadingLabel = String(localized: "构建对比视图…", comment: "Loading overlay while building the side-by-side compare view")
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
            await self.publishData(token) {
                guard self.displayMode == .compare else { return }
                for t in [a, b] { t.recolor(preferred: self.settings.colorMode, singleColor: self.singleRGBA()) }
                self.noteUserActivity()
                self.compareTracks = [a, b]
                self.isLoading = false
                self.loadingLabel = ""
            }
        }
    }

    // MARK: - 找不同（对比模式下两轨迹的多重集对称差）

    @Published var diffResult: DiffCompare.Result?   // nil = 未计算
    @Published var diffTrack: TrackData?             // 独立窗口的差异合成轨迹
    @Published var diffMatchTime = true {            // 匹配是否含时间（秒级）
        didSet { if oldValue != diffMatchTime { clearDiff() } }
    }
    @Published var diffBusy = false
    private var diffGen = 0

    /// 计算两文件（compareTracks 顺序，非显示交换顺序）的差异；
    /// 完成后高亮两侧面板并生成差异轨迹
    func computeDiff() {
        guard displayMode == .compare,
              let ts = compareTracks, ts.count == 2, !diffBusy else { return }
        noteUserActivity()
        diffBusy = true
        diffGen += 1
        let gen = diffGen
        let token = publicationClock.begin(.compareDiff, fileIDs: files.map(\.id), sourceID: track?.id)
        let a = ts[0], b = ts[1]
        let mt = diffMatchTime
        Task.detached(priority: .userInitiated) { [weak self] in
            let r = DiffCompare.diff(latL: a.lat, lonL: a.lon, timeL: a.time,
                                     latR: b.lat, lonR: b.lon, timeR: b.time,
                                     matchTime: mt)
            var dt: TrackData?
            if !r.leftOnly.isEmpty || !r.rightOnly.isEmpty {
                let parsed = DiffCompare.makeDiffParsed(
                    latL: a.lat, lonL: a.lon, eleL: a.ele, timeL: a.time,
                    latR: b.lat, lonR: b.lon, eleR: b.ele, timeR: b.time,
                    r: r, name: String(localized: "找不同", comment: "Find Differences: window title / name of the synthetic difference track"))
                dt = TrackData.build(parsed: parsed, preferredMode: .single).0
            }
            guard let self else { return }
            await MainActor.run {
                guard self.owns(token), gen == self.diffGen, self.displayMode == .compare else { return }
                self.diffResult = r
                self.diffTrack = dt
                self.applyDiffColors()
                self.diffBusy = false
            }
        }
    }

    /// 清除差异（退出对比/换数据/手动关闭）。恢复面板常规着色。
    /// 代号先递增再早退：在途的 computeDiff（结果还没发布）也必须作废
    func clearDiff(recolorPanes: Bool = true) {
        diffGen += 1
        diffBusy = false
        guard diffResult != nil || diffTrack != nil else { return }
        diffResult = nil
        diffTrack = nil
        if recolorPanes, displayMode == .compare, let ts = compareTracks, ts.count == 2 {
            let single = singleRGBA()
            for t in ts { t.recolor(preferred: settings.colorMode, singleColor: single) }
            objectWillChange.send()
        }
    }

    /// 差异配色应用：对比面板（独有点亮色 + 其余半透明灰）与差异轨迹
    /// （fileID 0/1 → 两侧色）。换色/交换左右时重刷
    func applyDiffColors() {
        guard let r = diffResult else { return }
        // 显示侧别：compareSwap 后 files[1] 在左边——左色跟随"显示在左"的那条
        let cA = rgba(compareSwap ? settings.diffColorRight : settings.diffColorLeft)
        let cB = rgba(compareSwap ? settings.diffColorLeft : settings.diffColorRight)
        if let ts = compareTracks, ts.count == 2 {
            ts[0].recolorDiffMask(indices: r.leftOnly, hit: cA)
            ts[1].recolorDiffMask(indices: r.rightOnly, hit: cB)
        }
        diffTrack?.recolorByFile([cA, cB])
        objectWillChange.send()
    }

    /// 交换对比左右（找不同颜色随显示侧别走）
    func toggleCompareSwap() {
        compareSwap.toggle()
        if diffResult != nil { applyDiffColors() }
    }

    private func rgba(_ color: Color) -> SIMD4<UInt8> {
        let ns = NSColor(color).usingColorSpace(.sRGB)
        return SIMD4(UInt8((min(max(ns?.redComponent ?? 1, 0), 1) * 255).rounded()),
                     UInt8((min(max(ns?.greenComponent ?? 0.4, 0), 1) * 255).rounded()),
                     UInt8((min(max(ns?.blueComponent ?? 0.1, 0), 1) * 255).rounded()),
                     235)
    }

    /// 关闭一个文件：对比中关闭 → 回单文件；重叠中照常重建
    func closeFile(_ id: UUID) {
        guard let idx = files.firstIndex(where: { $0.id == id }) else { return }
        noteUserActivity()
        files.remove(at: idx)
        if displayMode == .compare {
            displayMode = files.count >= 2 ? .overlay : .single   // 对比中关闭 → 回单文件
        }
        clearDiff(recolorPanes: false)
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
        let token = beginDataOperation()
        if !isLoading { isLoading = true }
        loadingLabel = String(localized: "构建轨迹…", comment: "Loading overlay while the displayed track is rebuilt")
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
            // 完整数据回放：不再做单城过滤（单城预览见 tag beijing-r19 / xian-r1）
#if ROME_PREVIEW
            var rome = ParsedTrack()
            rome.name = merged.name
            for i in merged.lat.indices
            where merged.lat[i] > 41.5 && merged.lat[i] < 42.2
               && merged.lon[i] > 12.0 && merged.lon[i] < 12.9 {
                rome.lat.append(merged.lat[i]); rome.lon.append(merged.lon[i])
                rome.ele.append(merged.ele[i]); rome.time.append(merged.time[i])
                if i < merged.fileID.count { rome.fileID.append(merged.fileID[i]) }
                if i < merged.segmentID.count { rome.segmentID.append(merged.segmentID[i]) }
            }
            merged = rome
#endif
            let (track, stats) = TrackData.build(parsed: merged, preferredMode: mode,
                                                 singleColor: single,
                                                 overlayFileColors: overlayColors)
            guard let self else { return }
            await self.publishData(token) { self.apply(track: track, stats: stats) }
        }
    }

    init(applyAppearance: Bool = true) {
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
        if let raw = d.string(forKey: IdleDefaultsKey.mapStyle), let s = BaseMapStyle(rawValue: raw) {
            settings.mapStyle = s          // 底图来源记住（外部瓦片来源切换成本高，下次打开仍用）
        }
        if applyAppearance { self.applyAppearance() }
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
        static let mapStyle     = "mapStyle"
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
        case \ViewSettings.mapStyle:
            d.set(settings.mapStyle.rawValue, forKey: IdleDefaultsKey.mapStyle)
            noteBaseMapChosen(settings.mapStyle)
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
        var types: [UTType] = [.xml, .commaSeparatedText]
        if let gpx = UTType(filenameExtension: "gpx") { types.insert(gpx, at: 0) }
        if let csv = UTType(filenameExtension: "csv") { types.append(csv) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true            // .fwdb 迷雾存档是目录
        panel.message = String(localized: "选择 GPX / CSV 文件（可多选合并）或一个 .fwdb 迷雾存档", comment: "Open panel message: pick GPX/CSV files (several are merged) or one .fwdb Fog of World archive folder")
        let result = panel.runModal()
        noteUserActivity()   // 对话框期间主线程阻塞，关闭瞬间计时已过期（含取消）
        if result == .OK, !panel.urls.isEmpty {
            let fws = panel.urls.filter { FogArchive.looksLikeArchive($0) }
            if !fws.isEmpty {
                loadFwdb(urls: fws)
            } else {
                load(urls: panel.urls.filter { !$0.hasDirectoryPath })
            }
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
        let token = beginDataOperation()
        noteUserActivity()   // 导入开始即活动；到 apply 之间由 isLoading 抑制闲置
        routeCache.clear()   // 换文件：路网结果缓存只对同一个打开的文件有效
        invalidateRegionReport()   // 解析一开始就撤下旧的地区报告（不等解析完），窗口转「计算中…」
        let appending = displayMode != .single && !files.isEmpty
        let secured = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        isLoading = true
        if urls.count == 1 {
            let fileName = urls[0].lastPathComponent
            loadingLabel = String(localized: "解析 \(fileName)…", comment: "Loading overlay while parsing one file; %@ = file name")
        } else {
            loadingLabel = String(localized: "解析 \(urls.count) 个文件…", comment: "Loading overlay while parsing several files; %lld = number of files")
        }
        loadingProgress = nil                        // Pass1 计数极快，起步先转圈
        // 进度回调（解析线程 → 主线程；parseMany 侧已节流到 ~10Hz）
        let progressSink: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            guard let self else { return }
            let p = Double(done) / Double(max(total, 1))
            Task { @MainActor in guard self.owns(token) else { return }; self.loadingProgress = p }
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
                await self.publishData(token) { self.fail(GPXParseError.noPoints) }
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
                // 来源/精度按文件自己的，不继承整批合并值（Garmin GPX 与手机 CSV 混合载入时画像才不会串）
                part.creator = i < parsed.perFileCreator.count ? parsed.perFileCreator[i] : ""
                part.accuracyMedian = i < parsed.perFileAccuracy.count ? parsed.perFileAccuracy[i] : nil
                part.byteCount = datas[i].count      // 每文件统计（性能面板聚合口径）
                part.parseSeconds = perFileSeconds
                part.chunkCount = perFileChunks
                newFiles.append((name, url, part))
                runIdx += 1
            }
            let failedNames = failed.map { urls[$0].lastPathComponent }
            let ready = newFiles
            await self.publishData(token) {
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
        clearDiff(recolorPanes: false)
        compareTracks = nil
        compareSwap = false
        currentFileURLs = files.compactMap { $0.url }
        if !failedNames.isEmpty {
            let skipped = failedNames.count
            let names = failedNames.joined(separator: "\n")
            errorMessage = String(localized: "已跳过 \(skipped) 个无法解析的文件：\n\(names)", comment: "Error alert after import; first placeholder = number of files that could not be parsed, second = their names, one per line")
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
        invalidateDataOperations()
        files = []                       // 压测数据替换全部文件，回单文件语义
        displayMode = .single
        currentFileURLs = []
        let token = beginDataOperation()
        isLoading = true
        let pointsText = n.formatted()
        loadingLabel = String(localized: "并行生成 \(pointsText) 个点…", comment: "Loading overlay of the stress test; %@ = number of points being generated (already formatted with grouping)")
        let mode = settings.colorMode
        let single = singleRGBA()

        Task.detached(priority: .userInitiated) { [weak self] in
            let parsed = StressTest.generate(count: n)
            let (track, stats) = TrackData.build(parsed: parsed, preferredMode: mode, singleColor: single)
            guard let self else { return }
            await self.publishData(token) { self.apply(track: track, stats: stats) }
        }
    }

    func reloadCurrentFile() {
        let urls = currentFileURLs
        guard !urls.isEmpty else { return }
        invalidateDataOperations()
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
        if fillMode {
            rebuildFillColors()            // 橙色高亮要基于新配色重建
            fillVersion &+= 1
        }
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
        track.recolor(preferred: settings.colorMode, singleColor: singleRGBA())
        self.track = track
        if displayMode == .overlay { recolorOverlayNow() }
        if regionSelection != nil { selectRegion(nil, fly: false) }   // 换数据：地区高亮不跟着旧数据留在地图上（不依赖统计窗口开着）
        invalidateRegionReport()
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
        // 补点落地自身经由 apply 换代，此时保留补点模式与记录；其它换代一律作废
        if let b = batch, b.trackID != track.id { invalidateBatch() }   // 兜底：轨迹换代一律作废
        if !self.fillApplying { fillSpacingManual = false; tripKindOverride = [:]; tripMap = [:]; cancelTripMap() }   // 换文件：手动点距、行程指定、地图证据不跨文件
        if !self.fillApplying && !self.keepChangeLog {
            // 换文件：本次会话的修改记录随旧轨迹作废（删除/还原走 keepChangeLog，记录跨重建保留）
            self.changes = []
            self.editBaseline = nil
            self.reviewSelection = nil
            self.reviewPlaces = [:]
            self.reviewFlags = [:]
        }
        self.reviewTrack = nil                   // 审阅合成轨迹随数据换代作废（窗口开着会按需重建）
        self.reviewTrackKey = ""
        if !self.fillApplying {
            invalidateBatch()                    // 换文件/重载：批次里的候选下标全部失效
            self.fillMode = false
            if !self.keepChangeLog { self.fills = [] }   // 删除点后补点清单（增量导出）仍然成立：按值记录，不按下标
            self.lastFill = nil
            self.fillUndo = nil
            self.fillCanUndo = false
            self.fillPrompt = nil
            self.fillSimilarPrompt = nil
            self.gapCandidates = []
            self.replayCount = 0; self.replayIndices = []; self.replayTrackID = nil
            self.resetFillDraft()
        }
        self.fogStats = nil
        self.fogStatsTrackID = nil
        self.playback = nil
        if !self.fogArchiveFiles.isEmpty || self.fogArchive != nil {
            self.fogArchiveFiles = []                // 新 GPX 数据替换迷雾存档
            self.fogArchive = nil
            self.fwdbMergeGen &+= 1                  // 作废在途合并，防过期结果复活存档
            self.fwdbVersion &+= 1
        }
        if self.showFogStats { self.ensureFogStats() }
    }

    /// 清除当前已导入的文件，回到空状态
    func clearTrack() {
        invalidateDataOperations()
        editBaseline = nil; changes = []; pendingLandingToast = nil
        discardStagedAndExit()
        exitFillMode()
        routeCache.clear()   // 文件关了：路网结果缓存随之清空
        fills = []
        lastFill = nil
        fillUndo = nil
        fillCanUndo = false
        track = nil
        if regionSelection != nil { selectRegion(nil, fly: false) }
        invalidateRegionReport()
        stats = PerfStats()
        hover = nil
        selected = nil
        currentFileURLs = []
        scaleBar = nil
        viewFilter = nil
        viewFilterSpec = nil
        files = []
        displayMode = .single
        clearDiff(recolorPanes: false)
        compareTracks = nil
        compareSwap = false
        fogStats = nil
        fogStatsTrackID = nil
        playback = nil
        if !fogArchiveFiles.isEmpty || fogArchive != nil {
            fogArchiveFiles = []
            fogArchive = nil
            fwdbMergeGen &+= 1                       // 作废在途合并
            fwdbVersion &+= 1
        }
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
            var s = self.renderStats.stats
            s.encodeMs = frame.encodeMs
            s.waitMs = frame.waitMs
            s.gpuMs = frame.gpuMs
            s.fps = frame.fps
            s.drawnPoints = frame.drawn
            s.lodStride = frame.stride
            self.renderStats.stats = s
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
        panel.message = String(localized: "选择导出位置", comment: "Save panel message when exporting GPX")
        let panelResult = panel.runModal()
        noteUserActivity()   // 存盘对话框同 openPanel：关闭瞬间计时已过期
        guard panelResult == .OK, let url = panel.url, self.track?.id == track.id else { return }

        let token = beginDataOperation(source: track)
        isLoading = true
        loadingLabel = String(localized: "并行导出 GPX…", comment: "Loading overlay while writing the exported GPX file")
        let synthetic: Set<GapFillExport.PointKey>? = fills.isEmpty ? nil : GapFillExport.syntheticKeys(fills)
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
                try GPXWriter.write(track: track, indices: indices, name: exportName, to: url,
                                    synthetic: synthetic)
                guard let self else { return }
                await MainActor.run {
                    guard self.owns(token) else { return }
                    self.noteUserActivity()   // 后台导出完成，计时基准已过期
                    self.isLoading = false
                    self.loadingLabel = ""
                }
            } catch {
                guard let self else { return }
                await MainActor.run {
                    guard self.owns(token) else { return }
                    self.noteUserActivity()
                    self.isLoading = false
                    self.loadingLabel = ""
                    self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    // MARK: - 补点（断档修补事务：选断档 → 点折线 → 预览 → 确认 → 落地重建）

    struct FillPrompt: Equatable {
        let insert: Int
        let remove: Int
        let message: String      // 解释区间内的点是什么、两种处理各意味着什么
        var keep: Int = 0        // 「替换」时仍保留的贴路真实点数
        var retimed: Int = 0     // 「替换」时保留位置、只改时间的过时出口点数（StaleRetime；不计入 insert）
        var insertKeep: Int = 0  // 「保留」时的合成点数（有改时计划时合成点铺满 A → B，与 insert 不同）
    }

    /// 区间内贴着折线（≤ max(半径,10) m）的真实点：手机数据隧道群之间的准点保留，飘的替换。
    /// 专用记录仪（Garmin）的区间内点是出口处时间戳过时的点，位置准时间错，一律替换 → 返回空
    /// deleteOnly：这次落地不插合成点（只删区间内的点）
    func keptInnerPoints(ia: Int, ib: Int, vertices: [CLLocationCoordinate2D], candidate: GapCandidate? = nil, deleteOnly: Bool = false) -> Set<Int> {
        guard let track, let inner = track.topology.indices(between: ia, and: ib), !inner.isEmpty else { return [] }
        if let c = candidate, c.kind == .jitter {
            // 有路径或直线要插点时乱跳点一律替换：回放点也贴在线上，"贴路"规则分不出真假；
            // 只删点（没有路径）时保留沿 A→B 单调推进、车速合理的那一路（两路定位交替时其中一路是真的）
            guard deleteOnly else { return [] }
            let opt = GapDetector.Options()
            // 车速上限参照簇的弦速与前后窗口速度里最大者（簇里夹着停站时弦速会很低，不能拿它卡住真实的行驶点）
            let ref = max(c.kmh, c.windowSpeedInKmh ?? 0, c.windowSpeedOutKmh ?? 0)
            let cap = c.kmh > opt.maxKmh ? opt.maxKmh : max(60, 1.5 * ref)
            return GapDetector.monotonicChain(track: track, ia: ia, ib: ib, capKmh: cap)
        }
        guard let p = profile(at: ia), p.kind != .deviceLogger,
              let a = fillAnchor(ia), let b = fillAnchor(ib) else { return [] }
        let tol = max(p.matchRadius, 10)
        let A = CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon)
        let poly = PortalDrift.Poly([A] + vertices + [CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)], frame: PortalDrift.Frame(origin: A))
        let f = PortalDrift.Frame(origin: A)
        var keep = Set<Int>()
        for k in inner where track.time[k] > a.time && track.time[k] < b.time {
            if poly.project(f.xy(CLLocationCoordinate2D(latitude: track.lat[k], longitude: track.lon[k]))).d <= tol { keep.insert(k) }
        }
        return keep
    }

    /// 协调器每次重绘投影到视图坐标，SwiftUI 覆盖层据此画锚点/顶点/预览折线
    struct FillOverlay: Equatable {
        var anchorA: CGPoint?
        var anchorB: CGPoint?
        var tA: Double?                 // 锚点时刻（标签 "A 入口 22:41:18"）
        var tB: Double?
        var vertices: [CGPoint] = []
        var preview: [CGPoint] = []     // A → 顶点 → B（行进方向）
        var previewPoints: [CGPoint] = []   // 「显示补的点」：按当前点距要插进去的合成点
        var approach: [CGPoint] = []    // 进入断档前的真实轨迹（…→A），画箭头示意从哪来
        var departure: [CGPoint] = []   // 离开断档后的真实轨迹（B→…），示意往哪去
        var midpoints: [CGPoint] = []   // 每段中点（拖它 = 在这段上新增顶点）；与 preview 段一一对应
        var inner: [CGPoint] = []       // 两锚点之间的原始点（将被替换），画 × 标记
        var dragging: Int?              // 正在拖的顶点下标（高亮）
        struct BatchLine: Equatable { var pts: [CGPoint]; var status: Int; var selected: Bool; var included: Bool }   // status 0 成功 1 警告 2 失败 3 直线 4 待审核主草稿(OSRM) 5 待审核另一路(Valhalla)
        var batchLines: [BatchLine] = [] // 批量预览：每处草稿
        var region: [CGPoint] = []       // 补点范围多边形（视图坐标）
        var regionInverted = false
    }

    @Published var fillMode = false
    @Published private(set) var gapCandidates: [GapCandidate] = [] { didSet { candidatesVersion &+= 1; invalidateClassifyCache() } }
    /// 回放点（GapDetector.replayFlags）：移动中坐标与几分钟前某点一字不差。数量给界面显示，下标留给一键清理
    @Published private(set) var replayCount = 0
    private var replayIndices: [Int32] = []
    private var replayTrackID: UUID?
    /// 「清理回放点」确认框：要删的点数（nil = 没弹）
    @Published var replayPrompt: Int? = nil
    /// 乱跳簇检测（默认开；关掉只影响候选列表与批量，回放点统计仍算）
    @Published var fillJitter = UserDefaults.standard.object(forKey: "fillJitter") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(fillJitter, forKey: "fillJitter")
            if fillMode, batch == nil, oldValue != fillJitter { resetFillDraft(); refreshGapCandidates(); fillVersion &+= 1 }
        }
    }
    private var candidatesVersion = 0
    /// 补点范围：手绘多边形（WGS-84）；nil = 不限。只补两端都落在范围内（反选后：范围外）的断档
    @Published private(set) var fillRegion: [CLLocationCoordinate2D]?
    @Published var fillRegionInvert = false
    @Published var fillRegionDrawing = false          // 正在圈选范围（左键拖拽画多边形）
    /// 只列当前时间筛选（日/自定义）内的断档
    @Published var fillFollowTimeFilter = true
    /// 批量：疑似铁路的也一律跳过（用户自己从 gpx.studio 导火车段）
    /// 只补公路（跳过铁路）。铁路现在也能补（只补判定为隧道的断档），所以默认关；换键名让老用户的旧值不再生效
    @Published var fillRoadOnly = UserDefaults.standard.object(forKey: "fillRoadOnly.v2") as? Bool ?? false {
        didSet { UserDefaults.standard.set(fillRoadOnly, forKey: "fillRoadOnly.v2") }
    }
    /// 合并隧道群（默认开）：相邻断档之间 ≤3 个点、≤90 s 就并成一处。切换时重新检测候选（批量进行中不可切）
    /// 精确模式：批量里每处公路断档同时请求 OSRM 与 Valhalla 并比对几何，一致才自动采用，不一致的等用户选（用时间换精度）
    @Published var fillCrossCheck = UserDefaults.standard.object(forKey: "fillCrossCheck") as? Bool ?? false {
        didSet { UserDefaults.standard.set(fillCrossCheck, forKey: "fillCrossCheck") }
    }
    @Published var fillMergeChains = UserDefaults.standard.object(forKey: "fillMergeChains") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(fillMergeChains, forKey: "fillMergeChains")
            if fillMode, batch == nil, oldValue != fillMergeChains { resetFillDraft(); refreshGapCandidates(); fillVersion &+= 1 }
        }
    }
    /// 行程（长停切分）与用户按行程指定的类别
    @Published private(set) var trips: [Trip] = [] { didSet { tripsBySegment = Dictionary(grouping: trips, by: \.segment).mapValues { $0.sorted { $0.pathRange.lowerBound < $1.pathRange.lowerBound } }; invalidateClassifyCache() } }
    private var tripsBySegment: [UInt32: [Trip]] = [:]
    @Published private(set) var tripKindOverride: [Int: BatchKind] = [:] { didSet { invalidateClassifyCache() } }
    /// 行程的地图证据（键 = 行程序号）；换文件清空
    @Published private(set) var tripMap: [Int: TripMapEvidence] = [:] { didSet { invalidateClassifyCache() } }
    @Published private(set) var tripMapRunning = false
    @Published private(set) var tripMapProgress: (done: Int, total: Int)? = nil
    /// 地图判断的当前阶段（公路距离逐点查完后是一次 Overpass 大查询，公共实例排队 30–60 s，要告诉用户没卡住）
    @Published private(set) var tripMapPhase = ""
    @Published private(set) var tripMapStarted: Date?        // 开始时刻（界面显示已等多久）
    private var tripMapTask: Task<Void, Never>?
    /// 行程按下标区间有序且互不重叠：二分找含 indexA 的那段（候选表几千处 × 行程几百段时线性扫太慢）
    func trip(for c: GapCandidate) -> Trip? {
        let list = tripsBySegment[c.segment] ?? []
        let rank = c.pathA ?? c.indexA
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid].pathRange.upperBound <= rank { lo = mid + 1 } else { hi = mid }
        }
        return lo < list.count && list[lo].contains(c) ? list[lo] : nil
    }
    /// 行程类别：用户指定 > 地图证据 > 速度分位数
    func tripKind(_ t: Trip) -> BatchKind? { tripKindOverride[t.index] ?? tripMap[t.index]?.verdict ?? t.autoKind }
    func tripReason(_ t: Trip) -> String {
        if let k = tripKindOverride[t.index] {
            let kind = k.label
            return String(localized: "你手选为\(kind)", comment: "Batch Gap Fill trip reason (tooltip); %@ = category the user picked (Road / Rail / Skip)")
        }
        if let e = tripMap[t.index] {
            guard e.verdict == nil else { return e.note }
            let note = e.note, speed = t.speedReason
            return String(localized: "\(note)；退回速度：\(speed)", comment: "Batch Gap Fill trip reason (tooltip) when the map check was inconclusive; first %@ = map evidence note, second %@ = speed-based reason used as fallback")
        }
        let speed = t.speedReason
        return String(localized: "还没用地图判断；速度：\(speed)", comment: "Batch Gap Fill trip reason (tooltip) before the map check ran; %@ = speed-based reason")
    }

    /// 用地图判断各行程（联网）：每段取 ≤6 个移动点，各查离最近公路（OSRM）、最近铁路（Overpass）的距离。
    /// 串行、限速；结果缓存到换文件。force = 已判过的也重判
    func resolveTripsByMap(force: Bool = false) {
        guard let track, !tripMapRunning else { return }
        // 只判含断档候选的段：全年手机数据几百段，没断档的段判了也用不上，Overpass 每批要排队 30–60 s
        let withGaps = Set(filteredGapCandidates.compactMap { trip(for: $0)?.index })
        let todo = trips.filter { withGaps.contains($0.index) && (force || tripMap[$0.index] == nil) }
        guard !todo.isEmpty else { return }
        let trackID = track.id
        let token = publicationClock.begin(.tripMap, fileIDs: files.map(\.id), sourceID: track.id)
        var plan: [(Trip, [Int])] = []
        for t in todo {
            let n = min(8, max(3, Int(t.km / 15)))
            let idx = TripSegmenter.samplePoints(track: track, trip: t, count: n)
            if !idx.isEmpty { plan.append((t, idx)) }
        }
        guard !plan.isEmpty else { return }
        let coords: [(Int, [(Int, CLLocationCoordinate2D)])] = plan.map { t, idx in
            (t.index, idx.map { ($0, CLLocationCoordinate2D(latitude: track.lat[$0], longitude: track.lon[$0])) })
        }
        // 只查铁路距离（判定依据）。以前先逐点问 OSRM 离公路多远：火车旁边总有辅路，0–20 m 没有区分力，
        // 却要白等 0.6 s × 几十个点；用户看着"卡住"。进度按 Overpass 批次（每批 ≤25 点、排队 30–60 s）
        let flat: [(Int, Int, CLLocationCoordinate2D)] = coords.flatMap { ti, pts in pts.map { (ti, $0.0, $0.1) } }
        let batches = (flat.count + 24) / 25
        tripMapRunning = true
        tripMapProgress = (0, batches)
        tripMapStarted = Date()
        let firstChunk = min(25, flat.count)
        tripMapPhase = String(localized: "第 1/\(batches) 批：问 Overpass 这 \(firstChunk) 个点 150 m 内有没有铁路（公共服务排队 30–60 秒）…", comment: "Map-check progress, first batch; first %lld = total number of batches, second %lld = points in this batch (at most 25)")
        tripMapTask = Task { [weak self] in
            var all: [Int: [TripMapEvidence.Sample]] = [:]
            for (ti, pts) in coords { all[ti] = pts.map { TripMapEvidence.Sample(index: $0.0, road: nil, rail: nil) } }
            var start = 0
            while start < flat.count, !Task.isCancelled {
                let chunk = Array(flat[start..<min(flat.count, start + 25)])
                let batchNo = start / 25 + 1
                await MainActor.run { [weak self] in
                    guard let self, self.owns(token), self.track?.id == trackID else { return }
                    self.tripMapProgress = (batchNo - 1, batches)
                    self.tripMapPhase = String(localized: "第 \(batchNo)/\(batches) 批：问 Overpass 这 \(chunk.count) 个点 150 m 内有没有铁路（公共服务排队 30–60 秒）…", comment: "Map-check progress; 1st %lld = current batch number, 2nd %lld = total number of batches, 3rd %lld = points in this batch (at most 25)")
                    if var st = self.batch { st.progressText = self.tripMapPhase; self.batch = st }
                }
                let rails = await RoadNetwork.nearestRailDistances(chunk.map { $0.2 })
                for (k, (ti, idx, _)) in chunk.enumerated() {
                    guard var samples = all[ti], let j = samples.firstIndex(where: { $0.index == idx }) else { continue }
                    samples[j].rail = k < rails.count ? rails[k] : nil
                    all[ti] = samples
                }
                let snapshot = all
                let touched = Set(chunk.map { $0.0 })
                await MainActor.run { [weak self] in
                    guard let self, self.owns(token), self.track?.id == trackID else { return }
                    // 这一批里有采样点的段才发布（一个段的点可能跨两批：部分答案也先亮出来）
                    for (ti, samples) in snapshot where touched.contains(ti) { self.tripMap[ti] = TripMapEvidence(samples: samples) }
                    self.tripMapProgress = (batchNo, batches)
                    if var st = self.batch { st.progressText = ""; self.batch = st }
                }
                start += 25
            }
            await MainActor.run { [weak self] in
                guard let self, self.owns(token) else { return }
                self.tripMapRunning = false
                self.tripMapProgress = nil
                self.tripMapPhase = ""
                self.tripMapStarted = nil
                self.tripMapTask = nil
                self.applyTripKindsToBatch()
                self.fillVersion &+= 1
            }
        }
    }
    func cancelTripMap() {
        publicationClock.cancel(.tripMap)
        tripMapTask?.cancel(); tripMapTask = nil
        tripMapRunning = false; tripMapProgress = nil; tripMapPhase = ""; tripMapStarted = nil
    }
    /// 地图证据到了以后，把分类阶段里没手动改过的条目按新判定更新
    private func applyTripKindsToBatch() {
        guard var st = batch, st.phase == .classify else { return }
        for i in st.items.indices where !st.items[i].userSet {
            let k = classify(st.items[i].candidate)
            st.items[i].kind = plannedKind(k, for: st.items[i].candidate)
        }
        batch = st
    }
    /// 断档分类：行程有把握（或用户指定）时按行程，否则按单处速度规则
    func classify(_ c: GapCandidate) -> BatchKind? {
        if classifyCacheVersion != classifyInputsVersion { classifyCache = [:]; classifyCacheVersion = classifyInputsVersion }
        if let hit = classifyCache[c.id] { return hit }
        let k: BatchKind?
        if let t = trip(for: c), let kk = tripKind(t) { k = kk } else { k = BatchClassifier.classify(c) }
        classifyCache[c.id] = k
        return k
    }
    func classifyReason(_ c: GapCandidate) -> String {
        guard let t = trip(for: c) else { return BatchClassifier.reason(c) }
        let tripNo = t.index + 1
        let reason = tripReason(t)
        guard tripKind(t) == nil else {
            return String(localized: "第 \(tripNo) 段：\(reason)", comment: "Batch Gap Fill gap classification reason (tooltip); %lld = trip number, %@ = trip reason")
        }
        let local = BatchClassifier.reason(c)
        return String(localized: "第 \(tripNo) 段：\(reason)\n单处：\(local)", comment: "Batch Gap Fill gap classification reason (tooltip) when the trip is undecided; 1st = trip number, 2nd = trip reason, 3rd = reason from this single gap's own speed rule")
    }
    /// 按行程指定类别（nil = 恢复自动）；分类阶段的批量条目同步更新
    func setTripKind(_ index: Int, _ kind: BatchKind?) {
        tripKindOverride[index] = kind
        if var st = batch, st.phase == .classify {
            for i in st.items.indices where st.items[i].tripIndex == index {
                let k = classify(st.items[i].candidate)
                st.items[i].kind = plannedKind(k, for: st.items[i].candidate)
                st.items[i].userSet = kind != nil
            }
            batch = st
        }
        fillVersion &+= 1
    }
    /// 列表与批量实际使用的候选：按范围、时间筛选过滤
    /// 过滤结果按输入版本缓存：视图 body 里每次重算都会读它，几千处候选 × 多边形判定不能每帧做一遍
    var filteredGapCandidates: [GapCandidate] {
        let key = candidateFilterKey
        if let cache = filteredCache, cache.key == key { return cache.value }
        let value = gapCandidates.filter { c in
            if fillFollowTimeFilter, let f = viewFilter, c.tA < f.start || c.tB > f.end { return false }
            if let poly = fillRegion, poly.count >= 3 {
                let inside = Self.polygonContains(poly, lat: c.latA, lon: c.lonA) && Self.polygonContains(poly, lat: c.latB, lon: c.lonB)
                if inside == fillRegionInvert { return false }
            }
            return true
        }
        filteredCache = (key, value)
        return value
    }
    private var filteredCache: (key: String, value: [GapCandidate])?
    private var candidateFilterKey: String {
        let f = (fillFollowTimeFilter ? viewFilter : nil).map { "\($0.start)|\($0.end)" } ?? "-"
        let r = fillRegion.map { poly in String(poly.count) + ":" + String(format: "%.6f,%.6f", poly[0].latitude, poly[0].longitude) } ?? "-"
        return "\(candidatesVersion)|\(f)|\(r)|\(fillRegionInvert)"
    }
    /// 分类缓存（行程指定 / 地图证据 / 行程表 / 候选表变了就整表作废）
    private var classifyCache: [GapID: BatchKind?] = [:]
    private var classifyCacheVersion = -1
    private var classifyInputsVersion = 0
    private func invalidateClassifyCache() { classifyInputsVersion &+= 1 }
    static func polygonContains(_ poly: [CLLocationCoordinate2D], lat: Double, lon: Double) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let yi = poly[i].latitude, xi = poly[i].longitude, yj = poly[j].latitude, xj = poly[j].longitude
            if (yi > lat) != (yj > lat), lon < (xj - xi) * (lat - yi) / (yj - yi) + xi { inside.toggle() }
            j = i
        }
        return inside
    }
    func setFillRegion(_ poly: [CLLocationCoordinate2D]?) {
        fillRegion = (poly?.count ?? 0) >= 3 ? poly : nil
        fillRegionDrawing = false
        fillVersion &+= 1
    }
    @Published private(set) var fillAnchorA: Int?            // 当前轨迹下标（落地后重取）
    @Published private(set) var fillAnchorB: Int?
    @Published private(set) var fillVertices: [CLLocationCoordinate2D] = []   // 数据坐标（WGS-84）
    @Published var fillPrompt: FillPrompt? { didSet { if fillPrompt == nil { applyPendingRouteDraftIfPossible() } } }
    @Published var fillSimilarPrompt: [GapCandidate]? { didSet { if fillSimilarPrompt == nil { applyPendingRouteDraftIfPossible() } } }
    @Published private(set) var fills: [GapFill] = []        // 本会话已落地的补点
    @Published private(set) var fillVersion = 0              // 锚点/顶点变化 → 重投影、重上色
    /// 只在区间内待删点的高亮颜色变化时递增（顶点拖动等只动覆盖层的变化不再让渲染器重传整条轨迹的颜色）
    @Published private(set) var fillColorVersion = 0
    @Published private(set) var fillFocusVersion = 0         // 选中断档 → 相机飞过去
    @Published var fillSpacingMeters = 15.0 {
        didSet { if !settingSpacingProgrammatically, fillSpacingMeters != oldValue { fillSpacingManual = true } }
    }
    /// 用户拖过间距滑块：之后不再按原始点距自动改；「跟随原始」按钮清掉
    @Published private(set) var fillSpacingManual = false
    /// 补点模式里把要插的合成点画出来（橙点；折线照旧）
    @Published var fillShowPoints = UserDefaults.standard.object(forKey: "fillShowPoints") as? Bool ?? false {
        didSet { UserDefaults.standard.set(fillShowPoints, forKey: "fillShowPoints"); fillVersion &+= 1 }
    }
    private var settingSpacingProgrammatically = false
    /// 当前断档两侧的原始移动步长/步时（给滑块旁显示；nil = 没选断档）
    @Published private(set) var fillLocalStep: (meters: Double, dt: Double)?
    /// 轨迹采样画像（专用记录仪 / 手机、中位步时步长、精度）：所有和点密度有关的门槛由它换算
    @Published private(set) var samplingProfile: SamplingProfile?
    /// 每处候选的成因（键 = tA）：采样稀疏 / 信号中断
    @Published private(set) var gapSampling: [GapID: LocalSampling] = [:]
    /// 当前锚点的成因（操作条显示）
    @Published private(set) var fillSampling: LocalSampling?
    @Published private(set) var fillCanUndo = false
    @Published private(set) var lastFill: GapFill?
    private var fillUndo: (parsed: ParsedTrack, fills: [GapFill], last: GapFill?, changes: [TrackChange])?
    private var fillApplying = false
    private(set) var fillDisplayColors: [UInt8]?             // 区间内现有点粉色高亮（与橙色折线/顶点区分）
    private(set) var fillCandidate: GapCandidate?            // 当前锚点来自的候选（解释区间内的点；锚点挪过就不再适用）
    /// 每个顶点的来源：nil = 用户画的；Int = 由区间内过时点派生（该点的轨迹下标）。与 fillVertices 等长
    @Published private(set) var fillVertexSources: [Int?] = []
    /// 编辑历史（⌘Z）：顶点、来源与当时的锚点一起记——挪锚点会裁掉派生顶点，撤销必须连锚点一起回去
    @Published private(set) var fillVertexHistory: [(coords: [CLLocationCoordinate2D], sources: [Int?], a: Int?, b: Int?, route: FillRouteInfo?)] = []
    var fillCanUndoVertex: Bool { !fillVertexHistory.isEmpty }
    var fillHasSeededVertices: Bool { fillVertexSources.contains { $0 != nil } }
    @Published private(set) var fillDragging = false         // 协调器正在拖顶点/锚点（期间禁止 ⌘Z）

    /// 路网草稿状态（界面必须标明来源）：nil = 纯手动描线
    struct FillRouteInfo: Equatable {
        let source: RouteSource
        let endpoint: String
        let vertexCount: Int
        let meters: Double
        let snapA: Double
        let snapB: Double
        var warnings: [String]
        var notes: [String] = []             // 判断依据：上下文/匹配用了哪些点、比较了哪些候选
        var edited: Bool                     // 取回后用户又手动改过（随历史快照一起撤销/恢复）
        var shiftA: Int = 0                  // 隧道口漂移：锚点往外挪了几个点
        var shiftB: Int = 0
        /// 落地前自检：取回草稿时按将落地的合成点评估；手动改过顶点后为 nil（已不是那条路线）
        var plausibility: FillPlausibility? = nil
    }
    @Published private(set) var fillRouteInfo: FillRouteInfo?
    /// 单处「交叉验证」取回的两份草稿：shown 已应用为顶点，other 可「换看」；agree = 几何一致
    struct FillCrossDrafts { var shown: RouteDraft; var other: RouteDraft; var ia: Int; var ib: Int; var agree: Bool }
    @Published private(set) var fillCrossDrafts: FillCrossDrafts?
    @Published private(set) var fillRouteBusy: RouteSource?  // 正在请求
    @Published private(set) var fillRouteProgress: String?   // 请求到哪一步（界面显示）
    /// 单处交叉验证时最近一条引擎细节进度（悬停提示用；fillRouteProgress 是两路合成的一行）
    @Published private(set) var fillRouteProgressDetail: String?
    /// 单处交叉验证两路各自的状态：0 取路中 1 有结果 2 没有结果（下标 0 = OSRM，1 = Valhalla）
    private(set) var fillCrossLegStatus: [Int] = [0, 0]

    /// 两路进度合成一行：「OSRM ✓ · Valhalla 取路中…」
    static func crossProgressLine(_ status: [Int]) -> String {
        ["OSRM", "Valhalla"].enumerated().map { k, name in
            switch status.indices.contains(k) ? status[k] : 0 {
            case 1: return name + " ✓"
            case 2: return String(localized: "\(name) 没有结果", comment: "Gap Fill bar, single-gap cross-check progress: this router returned no route. %@ = router name (OSRM / Valhalla, untranslated). Shown as part of one line like “OSRM ✓ · Valhalla no result”")
            default: return String(localized: "\(name) 取路中…", comment: "Gap Fill bar, single-gap cross-check progress: this router is still being requested. %@ = router name (OSRM / Valhalla, untranslated). Shown as part of one line like “OSRM ✓ · Valhalla fetching…”")
            }
        }.joined(separator: " · ")
    }
    private var fillRouteTask: Task<Void, Never>?
    private var fillRouteRequestID = 0                      // 取消/新请求都递增：旧任务的进度与收尾一律作废
    private var pendingRouteDraft: (RouteDraft, Int, Int)?  // 草稿到达时正在拖动/弹框：先挂起（连同请求时的锚点）

    /// 取消在途请求并清掉路网状态（换候选、重置草稿）
    private func cancelRouteDraft() {
        fillRouteRequestID &+= 1
        fillRouteTask?.cancel()
        fillRouteTask = nil
        fillRouteBusy = nil
        fillRouteProgress = nil
        fillRouteProgressDetail = nil
        fillRouteInfo = nil
        fillCrossDrafts = nil
        pendingRouteDraft = nil
    }

    /// 用户点「取消」：中断在途请求，草稿状态不变
    func cancelRouteRequest() {
        fillRouteRequestID &+= 1
        fillRouteTask?.cancel()
        fillRouteTask = nil
        fillRouteBusy = nil
        fillRouteProgress = nil
        fillRouteProgressDetail = nil
    }
    func setFillDragging(_ on: Bool) {
        if fillDragging != on { fillDragging = on }
        if !on { applyPendingRouteDraftIfPossible() }
    }

    /// 区间内的点仍是候选里的过时出口点（锚点没挪过、候选是 staleClock）→ 时钟落后秒数；否则 nil
    var fillInnerStaleLag: Double? {
        guard let c = fillCandidate, c.kind == .staleClock, let track, fillAnchorsMatchCandidate,
              c.indexB < track.timedCount, let prev = track.topology.adjacent(to: c.indexB, direction: -1) else { return nil }
        return max(0, track.time[c.indexB] - track.time[prev])
    }
    /// 用户自己画的顶点（不含由过时点派生的）
    var fillUserVertices: [CLLocationCoordinate2D] {
        zip(fillVertices, fillVertexSources).compactMap { $0.1 == nil ? $0.0 : nil }
    }

    var fillActive: Bool { fillAnchorA != nil && fillAnchorB != nil }
    var fillRemoveCount: Int {
        guard let a = fillAnchorA, let b = fillAnchorB else { return 0 }
        return track?.topology.innerCount(a, b) ?? 0
    }

    /// 进入补点模式：单文件、平面、非回放。候选断档按时间列出
    func enterFillMode() {
        guard track != nil, displayMode == .single, playback == nil, !deleteMode else { return }
        noteUserActivity()
        if settings.heat3D { settings.heat3D = false }   // 3D 热力下看不到点也点不了
        fillMode = true
        resetFillDraft()
        refreshGapCandidates()
    }

    func exitFillMode() {
        invalidateBatch()
        fillMode = false
        fillSpacingManual = false            // 手动点距只在这次补点会话内有效
        resetFillDraft()
        fillPrompt = nil
        fillSimilarPrompt = nil
        gapCandidates = []
    }

    func toggleFillMode() {
        if fillMode { exitFillMode() } else { enterFillMode() }
    }

    private func resetFillDraft() {
        fillAnchorA = nil
        fillAnchorB = nil
        fillVertices = []
        fillVertexSources = []
        fillVertexHistory = []
        fillDisplayColors = nil; fillColorVersion &+= 1
        fillCandidate = nil
        fillDragging = false
        fillLocalStep = nil
        fillSampling = nil
        cancelRouteDraft()
        fillVersion &+= 1
    }

    private func pushFillHistory() {
        fillVertexHistory.append((fillVertices, fillVertexSources, fillAnchorA, fillAnchorB, fillRouteInfo))
        if fillVertexHistory.count > 200 { fillVertexHistory.removeFirst() }
    }

    /// staleClock 候选在 (A, B) 内的过时出口点下标 → 派生顶点
    private func seededVertices(for g: GapCandidate, a: Int, b: Int) -> (coords: [CLLocationCoordinate2D], sources: [Int?]) {
        guard let track, g.kind == .staleClock else { return ([], []) }
        // 前 frozenA 个区间内点是 A 侧冻结外推假点（GapDetector.shiftFrozenChains），不当派生顶点
        guard let whole = track.topology.indices(between: g.indexA, and: g.indexB), let selected = track.topology.indices(between: a, and: b) else { return ([], []) }
        let lo = track.topology.pathRank(of: a), hi = track.topology.pathRank(of: b)
        let idx = whole.dropFirst(g.frozenA).filter { let rank = track.topology.pathRank(of: $0); return !selected.isEmpty && rank > lo && rank < hi }
        return (idx.map { CLLocationCoordinate2D(latitude: track.lat[$0], longitude: track.lon[$0]) }, idx.map { Optional($0) })
    }

    /// 候选检测的结果包（一次算完再整体发布，便于后台算）
    struct CandidateComputation {
        var profile: SamplingProfile
        var profiles: [UInt32: SamplingProfile]
        var cands: [GapCandidate]
        var sampling: [GapID: LocalSampling]
        var trips: [Trip]
        var replayIndices: [Int32]
    }
    private var candidateRefreshGeneration = 0
    private var segmentProfiles: [UInt32: SamplingProfile] = [:]
    private func profile(at index: Int) -> SamplingProfile? {
        guard let track, index >= 0, index < track.count else { return samplingProfile }
        return segmentProfiles[track.topology.segment(of: index)] ?? samplingProfile
    }
    private func shifted(_ index: Int, by delta: Int, track: TrackData) -> Int {
        guard delta != 0 else { return index }
        if let i = track.topology.adjacent(to: index, direction: delta > 0 ? 1 : -1, steps: abs(delta)), i < track.timedCount { return i }
        let range = track.topology.segmentRange(of: index)
        var rank = delta > 0 ? range.upperBound - 1 : range.lowerBound
        while rank >= range.lowerBound && rank < range.upperBound {
            let i = track.topology.globalIndex(atPathRank: rank)
            if i < track.timedCount { return i }
            rank -= 1
        }
        return index
    }
    /// 大文件的候选检测在后台进行中（界面提示；批量规划要等它结束）
    @Published private(set) var candidatesRefreshing = false

    private func refreshGapCandidates() {
        guard let track else { gapCandidates = []; samplingProfile = nil; replayCount = 0; replayIndices = []; replayTrackID = nil; return }
        candidateRefreshGeneration &+= 1
        let gen = candidateRefreshGeneration
        let token = publicationClock.begin(.candidates, fileIDs: files.map(\.id), sourceID: track.id)
        let jitterOn = fillJitter, mergeOn = fillMergeChains
        // 30 万点以内直接算（几十毫秒，调用方拿到的是同步结果）；更大的文件后台算——201 万点实测在主线程卡 6.3 s
        if track.count <= 300_000 {
            applyCandidates(Self.computeCandidates(track: track, jitter: jitterOn, merge: mergeOn), track: track)
            return
        }
        candidatesRefreshing = true
        gapCandidates = []
        Task.detached(priority: .userInitiated) { [weak self] in
            let r = Self.computeCandidates(track: track, jitter: jitterOn, merge: mergeOn)
            await MainActor.run {
                guard let self, self.owns(token), self.candidateRefreshGeneration == gen else { return }
                self.candidatesRefreshing = false
                guard self.track?.id == track.id else { return }
                self.applyCandidates(r, track: track)
            }
        }
    }
    private func applyCandidates(_ r: CandidateComputation, track: TrackData) {
        samplingProfile = r.profile
        replayIndices = r.replayIndices; replayCount = r.replayIndices.count; replayTrackID = track.id
        gapCandidates = r.cands
        segmentProfiles = r.profiles
        gapSampling = r.sampling
        trips = r.trips
    }
    nonisolated static func computeCandidates(track: TrackData, jitter jitterOn: Bool, merge mergeOn: Bool) -> CandidateComputation {
        let profile = SamplingProfile.compute(track: track, creator: track.creator, accuracy: track.gpsAccuracy)
        let profiles = SamplingProfile.bySegment(track: track, creator: track.creator, accuracy: track.gpsAccuracy)
        var opt = GapDetector.Options()
        opt.staleEnabled = profile.kind == .deviceLogger      // 过时时钟只在专用记录仪上找
        // A 侧冻结假点链前移（进隧道后锁死航向/步长的外推点并入区间；只对专用记录仪的 staleClock）
        var cands = GapDetector.shiftFrozenChains(track: track, candidates: GapDetector.detect(track: track, options: opt, profiles: profiles), profile: profile)
        // 回放点：数量给界面，下标留给一键清理；乱跳检测扫描时跳过它们
        let flags = GapDetector.replayFlags(track: track)
        var ri: [Int32] = []
        for (i, f) in flags.enumerated() where f { ri.append(Int32(i)) }
        if jitterOn {
            // 乱跳簇：与已有候选区间重叠的不要（过时时钟的空间跳变也是"大跳"，归 staleClock 处理）
            let jit = GapDetector.detectJitter(track: track, profile: profile, replay: ri.isEmpty ? nil : flags, options: opt, profiles: profiles)
            if !jit.isEmpty {
                // 与已有候选只部分重叠（不是整个包住）的乱跳簇不要；剩下的簇若整个包住某处候选就取代它
                //（簇里的那处空洞/过时跳变本来就是乱跳的一部分）。共用端点不算重叠
                func encloses(_ j: GapCandidate, _ c: GapCandidate) -> Bool { j.segment == c.segment && (j.pathA ?? j.indexA) <= (c.pathA ?? c.indexA) && (j.pathB ?? j.indexB) >= (c.pathB ?? c.indexB) }
                func overlaps(_ j: GapCandidate, _ c: GapCandidate) -> Bool { j.segment == c.segment && (j.pathA ?? j.indexA) < (c.pathB ?? c.indexB) && (j.pathB ?? j.indexB) > (c.pathA ?? c.indexA) }
                let survivors = jit.filter { j in !cands.contains { c in overlaps(j, c) && !encloses(j, c) } }
                let kept = cands.filter { c in !survivors.contains { encloses($0, c) } }
                cands = (kept + survivors).sorted { $0.indexA < $1.indexA }
            }
        }
        if mergeOn {
            // 只并「信号中断」的相邻处：采样稀疏的连续步之间是真实点，不能当假点删
            var nature: [GapID: GapNature] = [:]
            for c in cands { nature[c.id] = GapRouteInputs.localSampling(track, ia: c.indexA, ib: c.indexB, profile: profiles[c.segment] ?? profile).nature }
            cands = GapDetector.mergeChains(cands) { nature[$0.id] == .lossOfLock && nature[$1.id] == .lossOfLock }
        }
        var sampling: [GapID: LocalSampling] = [:]
        for c in cands { sampling[c.id] = GapRouteInputs.localSampling(track, ia: c.indexA, ib: c.indexB, profile: profiles[c.segment] ?? profile) }
        return CandidateComputation(profile: profile, profiles: profiles, cands: cands, sampling: sampling, trips: TripSegmenter.trips(track: track), replayIndices: ri)
    }

    /// 断档两侧（各 ≤12 步、不跨断档、速度 >1 m/s）的原始步长/步时中位数
    private func localMovingStep(_ ia: Int, _ ib: Int) -> (meters: Double, dt: Double)? {
        guard let track else { return nil }
        var ds: [Double] = [], dts: [Double] = []
        for (idx, forward) in [(ia, false), (ib, true)] {
            var k = idx
            for _ in 0..<12 {
                let prev = k
                guard let next = track.topology.adjacent(to: k, direction: forward ? 1 : -1), next < track.timedCount else { break }
                k = next
                if isBreak(prev, k) { break }
                let dt = abs(track.time[k] - track.time[prev])
                let d = GeoMath.haversine(track.lat[prev], track.lon[prev], track.lat[k], track.lon[k])
                if dt > 0, d / dt > 1 { ds.append(d); dts.append(dt) }
            }
        }
        guard ds.count >= 3 else { return nil }
        ds.sort(); dts.sort()
        return (ds[ds.count / 2], dts[dts.count / 2])
    }

    /// 选中断档后：显示原始点距；没手动拖过滑块就把间距设成原始点距本身（取整到 1 m；用户 2026-10-26 要求严格按原始轨迹，
    /// 不再 5 m 一档、不再夹到 15–60）。只夹到滑块范围 5–100 m（后台稀疏采样的手机轨迹几公里一个点，补隧道没意义）
    private func refreshSpacingSuggestion() {
        guard let ia = fillAnchorA, let ib = fillAnchorB else {
            if fillLocalStep != nil { fillLocalStep = nil }
            if fillSampling != nil { fillSampling = nil }
            return
        }
        let step = localMovingStep(ia, ib)
        if step?.meters != fillLocalStep?.meters || step?.dt != fillLocalStep?.dt { fillLocalStep = step }
        let sampling = track.map { GapRouteInputs.localSampling($0, ia: ia, ib: ib, profile: profile(at: ia)) }
        if sampling != fillSampling { fillSampling = sampling }
        // 两侧步数不够算不出局部点距时按整条轨迹的画像兜底（与 spacingFor 同口径），别留着上一个文件的值
        guard !fillSpacingManual, let meters = fillLocalStep?.meters ?? profile(at: ia)?.medianStep else { return }
        let suggested = min(100.0, max(5.0, meters.rounded()))
        if suggested != fillSpacingMeters {
            settingSpacingProgrammatically = true
            fillSpacingMeters = suggested
            settingSpacingProgrammatically = false
        }
    }

    /// 某处断档落地用的点距：用户拖过滑块就用滑块值；否则按这处两侧的原始步长本身（取整到 1 m，夹 5–100）。
    /// 「套用相似」与批量落地逐处算，不用上一次选中断档的值
    private func spacingFor(_ ia: Int, _ ib: Int) -> Double {
        if fillSpacingManual { return fillSpacingMeters }
        // 两侧步数不够时按整条轨迹的画像，不用上一次选中断档留下的值
        let meters = localMovingStep(ia, ib)?.meters ?? profile(at: ia)?.medianStep ?? 15
        return min(100.0, max(5.0, meters.rounded()))
    }

    /// 「跟随原始」：清掉手动标记，按当前断档重新建议
    func followOriginalSpacing() {
        fillSpacingManual = false
        refreshSpacingSuggestion()
    }

    /// 选中一个候选：锚点 = 断档两端，清空顶点，相机飞过去
    func selectGap(_ g: GapCandidate) {
        guard let track, fillMode, g.indexA >= 0, g.indexB > g.indexA, g.indexB < track.timedCount, track.topology.indices(between: g.indexA, and: g.indexB) != nil else { return }
        noteUserActivity()
        // 主窗口候选列表点的：只有确实在批量流程里（批次存在、处于预览阶段、这处在批次中）才当作「点批量列表的一行」
        //（选中 + 批量窗口折叠成单处卡片）；其它情况照旧只选断档，不碰批量窗口
        if let st = batch, st.phase == .preview, track.id == st.trackID,
           let item = st.items.first(where: { $0.candidate.id == g.id }) {
            selectBatchItem(item.id)
            return
        }
        // 再点一次当前这处：锚点没动只把相机飞回去；锚点挪过则把两端放回检测到的位置
        //（画好的顶点保留，过时出口点重新派生），都不清空编辑
        if let c = fillCandidate, c == g, fillAnchorA != nil {
            if fillAnchorA != g.indexA || fillAnchorB != g.indexB {
                pushFillHistory()
                fillAnchorA = g.indexA
                fillAnchorB = g.indexB
                if fillRouteInfo == nil {
                    // 原地重建：用户顶点保持原顺序，重新派生的出口点放回原来第一个派生顶点的位置
                    //（用户可能在派生点之间或之后又插过顶点，不能一股脑排到前面）
                    let seeded = seededVertices(for: g, a: g.indexA, b: g.indexB)
                    let at = fillVertexSources.firstIndex { $0 != nil } ?? fillVertexSources.count
                    let before = (0..<at).filter { fillVertexSources[$0] == nil }
                    let after = (at..<fillVertexSources.count).filter { fillVertexSources[$0] == nil }
                    fillVertices = before.map { fillVertices[$0] } + seeded.coords + after.map { fillVertices[$0] }
                    fillVertexSources = before.map { _ in nil } + seeded.sources + after.map { _ in nil }
                } else {
                    fillRouteInfo?.edited = true    // 路网草稿已经盖过出口段，不再派生；锚点变了算改过
                }
                rebuildFillColors()
                fillVersion &+= 1
            }
            fillFocusVersion &+= 1
            return
        }
        cancelRouteDraft()                      // 换了一处断档：上一处的路网草稿/在途请求都作废
        fillAnchorA = g.indexA
        fillAnchorB = g.indexB
        fillCandidate = g
        // Garmin 类过时时间戳的出口点：位置是对的（沿出口道路、步长正常），只是钟慢了。
        // 默认把它们的位置当作折线顶点——替换后沿同一路径得到时间正确的点，而不是一删了之
        let seeded = seededVertices(for: g, a: g.indexA, b: g.indexB)
        fillVertices = seeded.coords
        fillVertexSources = seeded.sources
        fillVertexHistory = []
        rebuildFillColors()
        fillVersion &+= 1
        fillFocusVersion &+= 1
    }

    func addFillVertex(_ c: CLLocationCoordinate2D) {
        insertFillVertex(c, at: fillVertices.count)
    }

    /// 在折线第 index 段之后插入顶点（0 = 紧接锚点 A；调用方按屏幕最近线段算 index）
    func insertFillVertex(_ c: CLLocationCoordinate2D, at index: Int) {
        guard fillMode, fillActive, batch == nil, c.latitude.isFinite, c.longitude.isFinite else { return }
        pushFillHistory()
        let k = min(max(0, index), fillVertices.count)
        fillVertices.insert(c, at: k)
        fillVertexSources.insert(nil, at: k)
        fillRouteInfo?.edited = true
        fillVersion &+= 1
    }

    /// 拖动真正改变了顶点/锚点时记一次历史（只按下不动不记；拖动过程中逐帧移动不记）
    func beginFillDrag() {
        guard fillMode else { return }
        pushFillHistory()
    }

    func moveFillVertex(_ index: Int, to c: CLLocationCoordinate2D) {
        guard fillMode, batch == nil, fillVertices.indices.contains(index), c.latitude.isFinite, c.longitude.isFinite else { return }
        fillVertices[index] = c                 // 来源保留：挪过的派生顶点仍是"出口点"，不进套用模板
        fillRouteInfo?.edited = true
        fillVersion &+= 1
    }

    func removeFillVertex(_ index: Int) {
        guard fillMode, batch == nil, fillVertices.indices.contains(index) else { return }
        pushFillHistory()
        fillVertices.remove(at: index)
        fillVertexSources.remove(at: index)
        fillRouteInfo?.edited = true
        fillVersion &+= 1
    }

    /// 锚点变动后，派生顶点若已不在 (A, B) 区间内（例如把 B 挪回出口点上）就去掉，否则折线会越过锚点再折返
    ///（调用方已在改锚点前记过历史）
    private func pruneSeededVertices() {
        guard let a = fillAnchorA, let b = fillAnchorB else { return }
        let keep = fillVertexSources.map { $0.map { $0 > a && $0 < b } ?? true }
        guard keep.contains(false) else { return }
        fillVertices = zip(fillVertices, keep).compactMap { $0.1 ? $0.0 : nil }
        fillVertexSources = zip(fillVertexSources, keep).compactMap { $0.1 ? $0.0 : nil }
    }

    /// staleClock 候选的过时区间 (indexA, indexB)：这些点时间是错的，不能当锚点
    private func isStaleIndex(_ i: Int) -> Bool {
        guard let c = fillCandidate, c.kind == .staleClock, let track, i >= 0, i < track.count, track.topology.segment(of: i) == c.segment else { return false }
        // A 侧冻结外推点（frozenA）时间正常、不是过时点：允许把 A 挪回去（用户不同意前移时可逆）
        let rank = track.topology.pathRank(of: i)
        return rank > (c.pathA ?? track.topology.pathRank(of: c.indexA)) + c.frozenA && rank < (c.pathB ?? track.topology.pathRank(of: c.indexB))
    }
    /// 锚点仍是候选检测出的 (A, B)（允许路网草稿因隧道口漂移自动外推的那几点，手动挪过就不算）
    private var fillAnchorsMatchCandidate: Bool {
        guard let c = fillCandidate, let ia = fillAnchorA, let ib = fillAnchorB, let track else { return false }
        let sa = fillRouteInfo?.shiftA ?? 0, sb = fillRouteInfo?.shiftB ?? 0
        return (ia == c.indexA || ia == shifted(c.indexA, by: -sa, track: track)) && (ib == c.indexB || ib == shifted(c.indexB, by: sb, track: track))
    }

    /// ⌘Z：回到上一次编辑（插入/拖动/删除顶点、挪锚点）之前；拖动进行中不可用
    func undoFillVertex() {
        guard fillMode, batch == nil, !fillDragging, let track, let prev = fillVertexHistory.popLast() else { return }
        fillVertices = prev.coords
        fillVertexSources = prev.sources
        if let a = prev.a, let b = prev.b, a >= 0, a < b, b < track.timedCount {
            fillAnchorA = a
            fillAnchorB = b
        }
        fillRouteInfo = prev.route              // 路网信息随快照一起回退（撤掉草稿 → 未使用；回到上一份草稿 → 它的标签）
        syncCrossDrafts()
        rebuildFillColors()
        fillVersion &+= 1
    }

    /// 单处交叉验证的两份草稿只在"当前顶点就是 shown 那份"时有意义：撤销 / 丢弃 / 换草稿后对不上就清掉
    /// （否则「换看 X」按钮和状态行的「两路一致/不一致」会指着一份没显示的草稿）
    private func syncCrossDrafts() {
        guard let x = fillCrossDrafts else { return }
        guard let r = fillRouteInfo, r.source == x.shown.source, r.vertexCount == x.shown.coords.count else { fillCrossDrafts = nil; return }
    }

    // MARK: 路网草稿（公路 OSRM / 铁路 Overpass；只在用户点击时请求，同一时刻一个）

    /// 这一步算不算断档：与 GapDetector 完全同一口径（GapDetector.isBreakStep：≥150 m 且 ≥20 s，或 >350 km/h，或时间不前进）
    private func isBreak(_ i: Int, _ j: Int) -> Bool {
        guard let track, track.topology.segment(of: i) == track.topology.segment(of: j) else { return true }
        return GapDetector.isBreakStep(dt: abs(track.time[j] - track.time[i]),
                                       meters: GeoMath.haversine(track.lat[i], track.lon[i], track.lat[j], track.lon[j]))
    }

    /// 一个来源对一处断档取路，先查路网缓存（ignoreCache 时跳过）：命中不发请求；取到草稿或路网明确回答的「无路」类错误写入缓存，
    /// 传输失败 / 冷却 / 取消不写。返回 (结果, 是否来自缓存)。命中的草稿由调用方把 RouteCache.hitNote 加到说明首行
    nonisolated static func cachedRoute(_ cache: RouteCache, key: RouteCacheKey, ignoreCache: Bool,
                                        fetch: () async throws -> RouteDraft) async -> (result: Result<RouteDraft, Error>, cached: Bool) {
        if !ignoreCache, let hit = cache.lookup(key) {
            switch hit {
            case .draft(let d): return (.success(d), true)
            case .noRoute(let e): return (.failure(e), true)
            }
        }
        do {
            let d = try await fetch()
            if !d.partial { cache.store(key, .draft(d)) }      // 有候选传输失败的结果不完整：不进缓存，下次照常重请求
            return (.success(d), false)
        } catch {
            if !Task.isCancelled, let r = error as? RouteError, RouteCache.isCacheable(r) { cache.store(key, .noRoute(r)) }
            return (.failure(error), false)
        }
    }

    /// 「重新取（忽略缓存）」：按当前草稿的来源再请求一次（交叉验证的两份 → 两路都重取），不看缓存、结果覆盖缓存
    func refetchRouteDraft() {
        guard fillMode, batch == nil, fillRouteBusy == nil else { return }
        if fillCrossDrafts != nil { requestCrossCheckedDraft(ignoreCache: true); return }
        guard let src = fillRouteInfo?.source, src != .deleteOnly else { return }
        requestRouteDraft(src, ignoreCache: true)
    }

    func requestRouteDraft(_ source: RouteSource, ignoreCache: Bool = false) {
        guard fillMode, batch == nil, fillRouteBusy == nil, let ia = fillAnchorA, let ib = fillAnchorB,
              let a = fillAnchor(ia), let b = fillAnchor(ib) else { return }
        noteUserActivity()
        let A = CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon)
        let B = CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)
        guard let track else { return }
        // 上下文/方向/匹配轨迹/成因 全部由 GapRouteInputs 一次算出（纯函数，harness 与钩子共用同一份）
        let inp = GapRouteInputs.build(track, ia: ia, ib: ib, profile: profile(at: ia))
        guard inp.valid else { return }
        let bearingA = inp.a.heading.bearing, bearingB = inp.b.heading.bearing
        let ctxA = inp.a.context.anchor, ctxB = inp.b.context.anchor
        let trace = inp.trace
        let radius = inp.radius
        let seconds = b.time - a.time
        let inputNotes = candidateNotes(ia: ia, ib: ib) + GapRouteInputs.notes(inp, profile: profile(at: ia))
        let cache = routeCache
        fillRouteBusy = source
        fillRouteProgress = String(localized: "请求 \(source.label)…", comment: "Gap Fill panel progress while requesting a route; %@ = routing source name")
        fillRouteRequestID &+= 1
        let rid = fillRouteRequestID
        let progress: RoadNetwork.Progress = { [weak self] text in
            DispatchQueue.main.async { guard let self, self.fillRouteRequestID == rid, self.fillRouteBusy != nil else { return }; self.fillRouteProgress = text }
        }
        fillRouteTask = Task { [weak self] in
            var result: Result<RouteDraft, Error>
            switch source {
            case .osrmCar, .valhallaCar:
                let leftHand = await TrafficSide.leftHand(at: CLLocationCoordinate2D(latitude: (A.latitude + B.latitude) / 2, longitude: (A.longitude + B.longitude) / 2))
                let key = RouteCacheKey(source: source, economy: false, ia: ia, ib: ib, a: A, b: B, seconds: seconds, inputs: inp, leftHand: leftHand)
                let (r, cached) = await Self.cachedRoute(cache, key: key, ignoreCache: ignoreCache) {
                    try await RoadNetwork.carRoute(a: A, b: B, bearingA: bearingA, bearingB: bearingB,
                                                   contextA: ctxA, contextB: ctxB, trace: trace,
                                                   matchRadius: radius, seconds: seconds,
                                                   portalA: inp.portalA, portalB: inp.portalB,
                                                   farContextA: inp.farContextA, farContextB: inp.farContextB,
                                                   portalFarA: inp.portalFarA, portalFarB: inp.portalFarB,
                                                   leftHandTraffic: leftHand,
                                                   engine: source == .valhallaCar ? .valhalla : .osrm, progress: progress)
                }
                result = r
                if case .success(var d) = r { d.notes = (cached ? [RouteCache.hitNote] : []) + inputNotes + d.notes; result = .success(d) }
            case .overpassRail:
                let key = RouteCacheKey(source: .overpassRail, economy: false, ia: ia, ib: ib, a: A, b: B, seconds: seconds, inputs: inp, leftHand: nil)
                let (r, cached) = await Self.cachedRoute(cache, key: key, ignoreCache: ignoreCache) {
                    try await RoadNetwork.railRoute(a: A, b: B, contextA: ctxA, contextB: ctxB,
                                                    portalA: inp.portalA, portalB: inp.portalB,
                                                    matchRadius: radius, seconds: seconds, progress: progress)
                }
                result = r
                if cached, case .success(var d) = r { d.notes.insert(RouteCache.hitNote, at: 0); result = .success(d) }
            case .deleteOnly:
                // 本地判定，不是路网来源；单处补点不会请求它
                result = .failure(RouteError.noRoute(String(localized: "只删点不是路网来源", comment: "Route error detail (inside “no route found (…)”): Delete Only is not a road-network source")))
            }
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.fillRouteRequestID == rid else { return }   // 已被取消/被新请求取代：不碰任何状态
                self.fillRouteBusy = nil
                self.fillRouteProgress = nil
                self.fillRouteTask = nil
                // 请求期间锚点/候选变了：这条路径已经不对应，丢弃
                guard self.fillMode, self.fillAnchorA == ia, self.fillAnchorB == ib else {
                    self.errorMessage = String(localized: "路网草稿已取回，但锚点在请求期间变了，已丢弃；请重新取", comment: "Error alert: the Road Draft arrived but the anchors changed while it was being requested, so it was discarded")
                    return
                }
                switch result {
                case .success(let d): self.fillCrossDrafts = nil; self.applyRouteDraft(d, ia: ia, ib: ib)
                case .failure(let e): self.errorMessage = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
                }
            }
        }
    }

    /// 单处精确取路：同时向 OSRM 与 Valhalla 请求并比对几何。一致 → 应用采用的那份（另一份留作对照）；
    /// 不一致 → 先应用 OSRM 份并警告，操作条出现「换看 Valhalla」；只有一路成功 → 应用它并警告无法交叉验证
    func requestCrossCheckedDraft(ignoreCache: Bool = false) {
        guard fillMode, batch == nil, fillRouteBusy == nil, let ia = fillAnchorA, let ib = fillAnchorB,
              let a = fillAnchor(ia), let b = fillAnchor(ib), let track else { return }
        noteUserActivity()
        let A = CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon)
        let B = CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)
        let inp = GapRouteInputs.build(track, ia: ia, ib: ib, profile: profile(at: ia))
        guard inp.valid else { return }
        let seconds = b.time - a.time
        let inputNotes = candidateNotes(ia: ia, ib: ib) + GapRouteInputs.notes(inp, profile: profile(at: ia))
        let cache = routeCache
        fillRouteBusy = .osrmCar
        fillCrossLegStatus = [0, 0]
        fillRouteProgress = Self.crossProgressLine(fillCrossLegStatus)
        fillRouteProgressDetail = nil
        fillRouteRequestID &+= 1
        let rid = fillRouteRequestID
        // 两路共用操作条上的一个位置：引擎细节进度只进悬停提示，显示的是合成的一行
        let progress: RoadNetwork.Progress = { [weak self] text in
            DispatchQueue.main.async { guard let self, self.fillRouteRequestID == rid, self.fillRouteBusy != nil else { return }; self.fillRouteProgressDetail = text }
        }
        @Sendable func legDone(_ k: Int, ok: Bool) async {
            await MainActor.run { [weak self] in
                guard let self, self.fillRouteRequestID == rid, self.fillRouteBusy != nil else { return }
                self.fillCrossLegStatus[k] = ok ? 1 : 2
                self.fillRouteProgress = Self.crossProgressLine(self.fillCrossLegStatus)
            }
        }
        fillRouteTask = Task { [weak self] in
            let mid = CLLocationCoordinate2D(latitude: (A.latitude + B.latitude) / 2, longitude: (A.longitude + B.longitude) / 2)
            let leftHand = await TrafficSide.leftHand(at: mid)
            @Sendable func leg(_ e: RoadNetwork.RouteEngine) async -> Result<RouteDraft, Error> {
                let key = RouteCacheKey(source: e == .osrm ? .osrmCar : .valhallaCar, economy: false, ia: ia, ib: ib, a: A, b: B, seconds: seconds, inputs: inp, leftHand: leftHand)
                let (r, cached) = await Self.cachedRoute(cache, key: key, ignoreCache: ignoreCache) {
                    try await RoadNetwork.carRoute(a: A, b: B, bearingA: inp.a.heading.bearing, bearingB: inp.b.heading.bearing,
                                                   contextA: inp.a.context.anchor, contextB: inp.b.context.anchor, trace: inp.trace,
                                                   matchRadius: inp.radius, seconds: seconds,
                                                   portalA: inp.portalA, portalB: inp.portalB,
                                                   farContextA: inp.farContextA, farContextB: inp.farContextB,
                                                   portalFarA: inp.portalFarA, portalFarB: inp.portalFarB,
                                                   leftHandTraffic: leftHand, engine: e, progress: progress)
                }
                if case .success = r { await legDone(e == .osrm ? 0 : 1, ok: true) } else { await legDone(e == .osrm ? 0 : 1, ok: false) }
                guard case .success(var d) = r else { return r }
                d.notes = (cached ? [RouteCache.hitNote] : []) + inputNotes + d.notes
                return .success(d)
            }
            async let rO = leg(.osrm)
            async let rV = leg(.valhalla)
            let (o, v) = await (rO, rV)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.fillRouteRequestID == rid else { return }
                self.fillRouteBusy = nil
                self.fillRouteProgress = nil
                self.fillRouteProgressDetail = nil
                self.fillRouteTask = nil
                guard self.fillMode, self.fillAnchorA == ia, self.fillAnchorB == ib else {
                    self.errorMessage = String(localized: "路网草稿已取回，但锚点在请求期间变了，已丢弃；请重新取", comment: "Error alert: the Road Draft arrived but the anchors changed while it was being requested, so it was discarded")
                    return
                }
                func why(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? e.localizedDescription }
                // 先应用、再登记两份草稿：草稿被挂起或丢弃时不能留下指着一份没显示的草稿的登记
                @MainActor func applyThenRegister(_ d: RouteDraft, other: RouteDraft, agree: Bool) {
                    self.fillCrossDrafts = nil
                    self.applyRouteDraft(d, ia: ia, ib: ib)
                    if self.pendingRouteDraft == nil, let r = self.fillRouteInfo, r.source == d.source, r.vertexCount == d.coords.count {
                        self.fillCrossDrafts = FillCrossDrafts(shown: d, other: other, ia: ia, ib: ib, agree: agree)
                        // 两路比对的最大偏差也进自检（applyRouteDraft 时还没有）
                        let cross = RouteCrossCheck.compare(d, other, a: A, b: B)
                        if let p = self.assessSingleDraft(d, crossMaxDev: cross.maxDev) {
                            if let old = self.fillRouteInfo?.plausibility?.summaryLine, self.fillRouteInfo?.notes.first == old { self.fillRouteInfo?.notes.removeFirst() }
                            self.fillRouteInfo?.plausibility = p
                            self.fillRouteInfo?.notes.insert(p.summaryLine, at: 0)
                        }
                    }
                }
                switch (o, v) {
                case (.success(let dO), .success(let dV)):
                    let cross = RouteCrossCheck.compare(dO, dV, a: A, b: B)
                    if cross.agree {
                        func annotated(_ x: RouteDraft, other: RouteDraft) -> RouteDraft {
                            var y = x
                            y.notes = [RouteCrossCheck.agreeNote(cross, adopted: x, other: other)] + y.notes
                            if let w = RouteCrossCheck.anchorWarning(x, matchRadius: inp.radius) { y.warnings.append(w) }
                            return y
                        }
                        let aO = annotated(dO, other: dV), aV = annotated(dV, other: dO)
                        let useO = RouteCrossCheck.preferred(dO, dV)
                        applyThenRegister(useO ? aO : aV, other: useO ? aV : aO, agree: true)
                    } else {
                        var d = dO
                        let reasons = cross.reasons.joined(separator: String(localized: "list.semicolon", defaultValue: "；", comment: "Separator between entries of an error list (Chinese full-width semicolon; en/de \"; \")"))
                        d.warnings.insert(String(localized: "两路不一致：\(reasons)。先显示 OSRM 的路径，点「换看 Valhalla」对比后再决定", comment: "Road-draft warning (single-gap cross-check): OSRM and Valhalla disagree; %@ = reasons. The quoted term is the 换看 (Show other) button"), at: 0)
                        applyThenRegister(d, other: dV, agree: false)
                    }
                case (.success(let d), .failure(let e)), (.failure(let e), .success(let d)):
                    var d = d
                    let name = d.source.label, reason = why(e)
                    d.warnings.insert(String(localized: "只有 \(name) 给出结果，无法交叉验证（另一路：\(reason)）", comment: "Road-draft warning (single-gap cross-check): only one router returned a route. Placeholders: source label of the route shown, failure reason of the other router"), at: 0)
                    self.fillCrossDrafts = nil
                    self.applyRouteDraft(d, ia: ia, ib: ib)
                case (.failure(let e1), .failure(let e2)):
                    let a = why(e1), b = why(e2)
                    self.errorMessage = String(localized: "两路都没有取到路径。OSRM：\(a)；Valhalla：\(b)", comment: "Error alert (single-gap cross-check): both routers failed. Placeholders: OSRM's reason, Valhalla's reason. Keep router names untranslated")
                }
            }
        }
    }

    /// 「换看」：两份草稿互换显示（回到请求时的锚点再应用另一份；整步可 ⌘Z）
    func swapCrossDraft() {
        guard fillMode, fillActive, var x = fillCrossDrafts, fillRouteBusy == nil, !fillDragging, fillPrompt == nil, fillSimilarPrompt == nil,
              let track else { return }
        guard x.ia >= 0, x.ib < track.timedCount, x.ia < x.ib else { return }
        pushFillHistory()
        fillAnchorA = x.ia
        fillAnchorB = x.ib
        let next = x.other
        x.other = x.shown
        x.shown = next
        fillCrossDrafts = x
        applyRouteDraft(next, ia: x.ia, ib: x.ib, recordHistory: false)
    }

    /// 用路网折线替换全部顶点（含过时出口点派生的——路网路径本来就经过出口那段路，保留会折返）。
    /// ia/ib = 请求时的锚点；草稿判出隧道口漂移时把锚点往外挪（跳过的漂移点进区间，落地时替换）
    private func applyRouteDraft(_ d: RouteDraft, ia: Int, ib: Int, recordHistory: Bool = true) {
        guard fillMode, fillActive, let track else { return }
        // 正在拖顶点/锚点或确认框开着：不能从手底下换掉顶点，先挂起，拖动结束/弹框关闭再应用
        guard !fillDragging, fillPrompt == nil, fillSimilarPrompt == nil else { pendingRouteDraft = (d, ia, ib); return }
        pendingRouteDraft = nil
        guard fillAnchorA == ia, fillAnchorB == ib else { errorMessage = String(localized: "路网草稿已取回，但锚点在这期间变了，已丢弃；请重新取", comment: "Error alert: the Road Draft arrived but the anchors changed in the meantime, so it was discarded"); fillCrossDrafts = nil; return }
        if recordHistory { pushFillHistory() }
        if d.shiftA > 0 || d.shiftB > 0 {
            let na = shifted(ia, by: -d.shiftA, track: track), nb = shifted(ib, by: d.shiftB, track: track)
            if na < nb { fillAnchorA = na; fillAnchorB = nb; pruneSeededVertices() }
        }
        fillVertices = d.coords
        fillVertexSources = Array(repeating: nil, count: d.coords.count)
        var warnings = d.warnings
        if d.coords.isEmpty { warnings.append(String(localized: "路网路径没有中间点（直线即可）", comment: "Road Draft warning: the route has no intermediate points (a straight line is enough)")) }
        fillRouteInfo = FillRouteInfo(source: d.source, endpoint: d.endpoint, vertexCount: d.coords.count,
                                      meters: d.meters, snapA: d.snapA, snapB: d.snapB, warnings: warnings, notes: d.notes, edited: false,
                                      shiftA: d.shiftA, shiftB: d.shiftB)
        fillRouteInfo?.plausibility = assessSingleDraft(d, crossMaxDev: nil)
        if let p = fillRouteInfo?.plausibility { fillRouteInfo?.notes.insert(p.summaryLine, at: 0) }
        rebuildFillColors()
        fillVersion &+= 1
    }

    /// 单处草稿的落地前自检：按当前锚点（草稿外推后）与将落地的合成点评估。锚点与候选对不上（手动挪过）时没有参照车速，照样评估几何
    private func assessSingleDraft(_ d: RouteDraft, crossMaxDev: Double?) -> FillPlausibility? {
        guard let track, d.source != .deleteOnly, let ia = fillAnchorA, let ib = fillAnchorB, let a = fillAnchor(ia), let b = fillAnchor(ib) else { return nil }
        let A = CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon), B = CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)
        // P 只含合成点；保留 / 改时的真实点（位置是真实观测，离路线 ≤ 容差）走 innerMaxOff，不算「补点离路网」
        let plan = currentRetimePlan()
        let pts = currentFillPoints().map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        let cand = fillAnchorsMatchCandidate ? fillCandidate : nil
        let keep = plan == nil ? keptInnerPoints(ia: ia, ib: ib, vertices: fillVertices, candidate: cand) : Set(plan!.retimed.map(\.index))
        let real = keep.sorted().map { CLLocationCoordinate2D(latitude: track.lat[$0], longitude: track.lon[$0]) }
        let inp = GapRouteInputs.build(track, ia: ia, ib: ib, profile: profile(at: ia))
        var x = FillPlausibility.input(draft: d, a: A, b: B, seconds: b.time - a.time, points: pts, inputs: inp, candidate: cand,
                                       crossMaxDev: crossMaxDev, innerMaxOff: FillPlausibility.innerMaxOff(a: A, points: pts, b: B, real: real))
        if let plan { x = FillPlausibility.retarget(x, fillB: CLLocationCoordinate2D(latitude: plan.fillB.lat, longitude: plan.fillB.lon)) }
        return FillPlausibility.assess(x)
    }

    /// 批量项的落地前自检：按 landingJob 同一口径算出将落地的点再评估；只删点 / 直线 = nil
    private func assessBatchItem(_ item0: BatchItem, draft: RouteDraft, track: TrackData) -> FillPlausibility? {
        guard draft.source != .deleteOnly else { return nil }
        var item = item0
        item.draft = draft; item.useStraight = false; item.status = .done
        guard let (job, rec) = landingJob(for: item, track: track, lastB: -1, forPreview: true),
              let a = fillAnchor(job.indexA), let b = fillAnchor(job.indexB) else { return nil }
        let A = CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon), B = CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)
        // P 只含合成点；改时的过时出口点（位置是真实观测）与保留的贴路点一起走 innerMaxOff
        let synthetic = job.points.filter { !rec.retimedKeys.contains(GapFillExport.PointKey($0.time, $0.lat, $0.lon, segment: rec.segment)) }
        let pts = synthetic.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        let retimed = job.points.filter { rec.retimedKeys.contains(GapFillExport.PointKey($0.time, $0.lat, $0.lon, segment: rec.segment)) }.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        let real = job.keep.sorted().map { CLLocationCoordinate2D(latitude: track.lat[$0], longitude: track.lon[$0]) } + retimed
        let inp = GapRouteInputs.build(track, ia: item.candidate.indexA, ib: item.candidate.indexB, profile: profile(at: item.candidate.indexA))
        var x = FillPlausibility.input(draft: draft, a: A, b: B, seconds: b.time - a.time, points: pts, inputs: inp, candidate: item.candidate,
                                       crossMaxDev: item.cross?.maxDev, innerMaxOff: FillPlausibility.innerMaxOff(a: A, points: pts, b: B, real: real))
        // 合成点只铺到第一个改时点：它才是 P 的终点
        if let firstRetimed = job.points.filter({ rec.retimedKeys.contains(GapFillExport.PointKey($0.time, $0.lat, $0.lon, segment: rec.segment)) }).min(by: { $0.time < $1.time }) {
            x = FillPlausibility.retarget(x, fillB: CLLocationCoordinate2D(latitude: firstRetimed.lat, longitude: firstRetimed.lon))
        }
        return FillPlausibility.assess(x)
    }

    /// 挂起的草稿：拖动结束 / 弹框关闭后应用（异步一拍，让确认按钮的同步流程先跑完）
    private func applyPendingRouteDraftIfPossible() {
        guard pendingRouteDraft != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let (d, ia, ib) = self.pendingRouteDraft, self.fillMode, self.fillActive,
                  !self.fillDragging, self.fillPrompt == nil, self.fillSimilarPrompt == nil else { return }
            self.applyRouteDraft(d, ia: ia, ib: ib)
        }
    }

    /// 锚点逐点前后挪（隧道里常有基站漂移点，真实两端未必相邻）；始终 0 ≤ A < B < timedCount
    func moveFillAnchor(a isA: Bool, by delta: Int) {
        guard let track, fillMode, batch == nil, var a = fillAnchorA, var b = fillAnchorB else { return }
        guard let next = track.topology.adjacent(to: isA ? a : b, direction: delta >= 0 ? 1 : -1, steps: abs(delta)) else { return }
        if isA { a = next } else { b = next }
        guard a >= 0, b < track.timedCount, a < b, !isStaleIndex(isA ? a : b) else { return }
        pushFillHistory()
        fillAnchorA = a
        fillAnchorB = b
        pruneSeededVertices()
        fillRouteInfo?.edited = true
        rebuildFillColors()
        fillVersion &+= 1
    }

    /// ⌥点击轨迹点 → 设为更近的那个锚点（只认断档附近 ±2000 个点，防吸到别的日期）
    /// 返回是否真的改了锚点。拖动时由协调器在第一次改动前记历史（recordHistory=false）
    @discardableResult
    func setFillAnchor(nearest index: Int, side: Bool? = nil, recordHistory: Bool = true) -> Bool {
        guard let track, fillMode, batch == nil, let a = fillAnchorA, let b = fillAnchorB,
              index >= 0, index < track.timedCount, track.topology.segment(of: index) == track.topology.segment(of: a),
              abs(track.topology.pathRank(of: index) - track.topology.pathRank(of: a)) <= 2000 || abs(track.topology.pathRank(of: index) - track.topology.pathRank(of: b)) <= 2000 else { return false }
        guard !isStaleIndex(index) else { return false }      // 过时时间戳的点不能当锚点
        let pickA = side ?? (abs(track.topology.pathRank(of: index) - track.topology.pathRank(of: a)) <= abs(track.topology.pathRank(of: index) - track.topology.pathRank(of: b)))
        if pickA {
            guard index < b, index != a else { return false }
            if recordHistory { pushFillHistory() }
            fillAnchorA = index
        } else {
            guard index > a, index != b else { return false }
            if recordHistory { pushFillHistory() }
            fillAnchorB = index
        }
        pruneSeededVertices()
        fillRouteInfo?.edited = true
        rebuildFillColors()
        fillVersion &+= 1
        return true
    }

    private func rebuildFillColors() {
        refreshSpacingSuggestion()
        guard let track, let a = fillAnchorA, let b = fillAnchorB, let inner = track.topology.indices(between: a, and: b), !inner.isEmpty else {
            fillDisplayColors = nil; fillColorVersion &+= 1
            return
        }
        var colors = track.colors
        colors.withUnsafeMutableBufferPointer { buf in
            for k in inner {
                let o = k * 4
                buf[o] = 255; buf[o + 1] = 60; buf[o + 2] = 170; buf[o + 3] = 235   // 粉：区间内现有点
            }
        }
        fillDisplayColors = colors; fillColorVersion &+= 1
    }

    func fillAnchor(_ index: Int) -> FillAnchor? {
        guard let track, index >= 0, index < track.count else { return nil }
        return FillAnchor(lat: track.lat[index], lon: track.lon[index],
                          ele: track.ele[index], time: track.time[index])
    }

    /// 单处草稿的改时计划（StaleRetime）：只对 staleClock 候选、且锚点没手动改过（与 fillInnerStaleLag 同条件）；
    /// 手动挪过锚点按老规则整点替换
    func currentRetimePlan() -> StaleRetime.Plan? {
        guard let c = fillCandidate, c.kind == .staleClock, let track,
              let ia = fillAnchorA, let ib = fillAnchorB, fillAnchorsMatchCandidate,
              !fillHasSeededVertices else { return nil }   // 没取路网时顶点就是过时点本身（离路恒为 0，筛不出飘的）：按老规则沿顶点铺合成点
        return StaleRetime.plan(track: track, ia: ia, ib: ib, candidate: c, vertices: fillVertices,
                                radius: profile(at: ia)?.matchRadius ?? 15)
    }
    /// 「保留」（不删区间内点）时合成点铺满 A → B 的点数（有改时计划时与 insert 不同）
    func currentFillPointsKeepingInner() -> Int {
        guard let ia = fillAnchorA, let ib = fillAnchorB, let a = fillAnchor(ia), let b = fillAnchor(ib) else { return 0 }
        return FillPath.interpolate(a: a, vertices: fillVertices, b: b, spacingMeters: fillSpacingMeters).count
    }

    /// 当前草稿的合成点（预览与落地共用）。有改时计划时只补 A → 第一个保留点（不含改时点本身）
    func currentFillPoints() -> [FillPoint] {
        guard let ia = fillAnchorA, let ib = fillAnchorB,
              let a = fillAnchor(ia), let b = fillAnchor(ib) else { return [] }
        if let plan = currentRetimePlan() {
            return FillPath.interpolate(a: a, vertices: plan.vertices, b: plan.fillB, spacingMeters: fillSpacingMeters)
        }
        return FillPath.interpolate(a: a, vertices: fillVertices, b: b, spacingMeters: fillSpacingMeters)
    }

    func requestApplyFill() {
        guard fillMode, fillActive, batch == nil else { return }
        let pts = currentFillPoints()
        let plan = currentRetimePlan()
        let retimed = plan?.retimed.count ?? 0
        let insertKeep = plan == nil ? pts.count : currentFillPointsKeepingInner()
        // 两锚点太近插不出合成点时，只要区间内还有点（隧道群之间的假点），仍可落地：只删飘点
        guard !pts.isEmpty || insertKeep > 0 || fillRemoveCount > 0 else {
            errorMessage = String(localized: "两锚点之间太短，按当前点距插不出合成点，区间内也没有点可处理；可减小点距或把锚点挪远一点", comment: "Error alert when applying a fill: anchors too close for any synthetic point and no points in between")
            return
        }
        let keep = plan != nil ? 0 : (fillAnchorA.flatMap { ia in fillAnchorB.map { ib in keptInnerPoints(ia: ia, ib: ib, vertices: fillVertices, candidate: fillCandidate, deleteOnly: pts.isEmpty) } } ?? []).count
        let frozen = fillAnchorsMatchCandidate ? (fillCandidate?.frozenA ?? 0) : 0
        var paras = [fillPromptMessage(remove: fillRemoveCount, retimed: retimed, frozen: frozen)]   // 段落各自是完整句子，代码里用空行拼
        if keep > 0 {
            if fillCandidate?.kind == .jitter && pts.isEmpty {
                paras.append(String(localized: "其中 \(keep) 个点沿 A→B 单调推进、车速合理（两路定位交替时真的那一路）：「替换」会把它们保留下来，只删来回跳的。", comment: "Apply-fill confirmation paragraph (jitter, delete only); %lld = number of points that advance monotonically from A to B at a plausible speed and are kept. the bracketed terms are this dialog's Replace / Keep buttons"))
            } else {
                let radius = Int(max(fillAnchorA.flatMap { profile(at: $0)?.matchRadius } ?? 15, 10))
                paras.append(String(localized: "其中 \(keep) 个点贴着折线（离路网路径 \(radius) m 内），是准的真实点：「替换」也会把它们保留下来，只删飘了的。", comment: "Apply-fill confirmation paragraph; first %lld = number of real points lying on the polyline that are kept, second %lld = distance tolerance in metres. the bracketed terms are this dialog's Replace / Keep buttons"))
            }
        }
        if retimed > 0 {
            paras.append(String(localized: "其中 \(retimed) 个点位置在路线上、只是时间滞后：「替换」会保留它们的位置，时间按出口速度回推。", comment: "Apply-fill confirmation paragraph (stale-clock exit points kept with corrected time); %lld = number of points whose position lies on the route and only the timestamp lags: Replace keeps their position and recomputes the time from the exit speed. the bracketed term is this dialog's Replace button"))
        }
        if pts.isEmpty && insertKeep == 0 { paras.append(String(localized: "折线太短，按当前点距插不出合成点：「替换」只删掉区间内飘了的点；「保留」则什么都不改。", comment: "Apply-fill confirmation paragraph: polyline too short for any synthetic point. the bracketed terms are this dialog's Replace / Keep buttons")) }
        let message = paras.joined(separator: "\n\n")
        fillPrompt = FillPrompt(insert: pts.count, remove: fillRemoveCount, message: message, keep: keep, retimed: retimed, insertKeep: insertKeep)
    }

    /// 确认对话框的说明：区间内的点是什么、「替换」与「保留」各意味着什么
    /// retimed = 「替换」时保留位置只改时间的过时点数；frozen = 区间内 A 侧冻结外推假点数（时间正常、位置是假的，一并替换）
    private func fillPromptMessage(remove: Int, retimed: Int = 0, frozen: Int = 0) -> String {
        var paras = [String(localized: "合成点沿折线按弧长等距、时间在两端锚点之间匀速插值（方向 A → B）。", comment: "Apply-fill confirmation, first paragraph: synthetic points are spaced evenly along the polyline and their times interpolated linearly between the anchors")]
        if remove > 0 {
            if let lag = fillInnerStaleLag {
                let lagSeconds = Int(lag.rounded())
                let stale = max(0, remove - frozen)     // 过时出口点数（不含冻结外推点）
                // 同一段里两句直接相连：按是否已留作折线顶点 / 是否有改时计划给整段变体（不拼半句）
                if retimed > 0 {
                    paras.append(String(localized: "区间内 \(stale) 个点（粉色）是设备重新定位后带着过时时间戳的出口点：位置正常，时间却比真实早约 \(lagSeconds) 秒。「替换」把其中位置在路线上的保留下来、只把时间按出口速度回推，离路线的删掉由合成点接上；「保留」会让时间线在出口来回跳，不推荐。", comment: "Apply-fill confirmation paragraph (stale-clock exit points, some of which keep their position with a corrected time); first %lld = number of stale exit points in the range (shown pink), second %lld = seconds their timestamps lag behind. the bracketed terms are this dialog's Replace / Keep buttons"))
                } else if fillHasSeededVertices {
                    paras.append(String(localized: "区间内 \(stale) 个点（粉色）是设备重新定位后带着过时时间戳的出口点：位置正常，时间却比真实早约 \(lagSeconds) 秒。它们的位置已作为折线顶点保留——「替换」沿同一路径生成时间正确的点；「保留」会让时间线在出口来回跳，不推荐。", comment: "Apply-fill confirmation paragraph (stale-clock exit points, already kept as polyline vertices); first %lld = number of points in the range (shown pink), second %lld = seconds their timestamps lag behind. the bracketed terms are this dialog's Replace / Keep buttons"))
                } else {
                    paras.append(String(localized: "区间内 \(stale) 个点（粉色）是设备重新定位后带着过时时间戳的出口点：位置正常，时间却比真实早约 \(lagSeconds) 秒。「替换」把它们删掉，由折线上的合成点接上；「保留」会让时间线在出口来回跳，不推荐。", comment: "Apply-fill confirmation paragraph (stale-clock exit points); first %lld = number of points in the range (shown pink), second %lld = seconds their timestamps lag behind. the bracketed terms are this dialog's Replace / Keep buttons"))
                }
                if frozen > 0 {
                    paras.append(String(localized: "另外 \(frozen) 个点是进隧道后设备按最后航向外推出来的（航向/步长锁死），位置不真实：「替换」一并删掉。", comment: "Apply-fill confirmation paragraph: %lld = number of points before the tunnel entrance that the device extrapolated after losing the signal (heading/step locked); Replace removes them too. the bracketed term is this dialog's Replace button"))
                }
            } else if let c = fillCandidate, c.kind == .jitter {
                let maxJump = Int(c.jitterMaxJump)
                paras.append(String(localized: "区间内 \(remove) 个点（粉色）是乱跳点：在相隔几百米到几公里的位置之间来回跳（大跳 \(c.jitterJumps) 步、倒退 \(c.jitterReversals) 步，最大一步 \(maxJump) m）——车厢里没信号时设备回放旧位置或两路定位交替。「替换」把它们删掉，「保留」则与合成点按时间混排（不推荐）。", comment: "Apply-fill confirmation paragraph (jitter points); 1st %lld = number of points in the range (shown pink), 2nd %lld = big-jump steps, 3rd %lld = reversal steps, 4th %lld = largest single step in metres. the bracketed terms are this dialog's Replace / Keep buttons"))
            } else {
                paras.append(String(localized: "区间内 \(remove) 个点（粉色）是夹在两锚点之间的现有点（挪锚点后夹进来的，通常是隧道里的基站漂移点或钟慢的点）：「替换」把它们删掉，「保留」则与合成点按时间混排。", comment: "Apply-fill confirmation paragraph (existing points between the anchors); %lld = number of points in the range (shown pink). the bracketed terms are this dialog's Replace / Keep buttons"))
            }
        }
        paras.append(String(localized: "落地后可用「撤销落地」整批撤回。", comment: "Apply-fill confirmation, last paragraph; the bracketed term is the Undo Apply button"))
        return paras.joined(separator: "\n\n")
    }

    /// 确认落地：插入合成点，区间内的点按用户选择删除或保留
    func confirmApplyFill(removeInner: Bool) {
        let prompt = fillPrompt
        fillPrompt = nil
        guard batch == nil, let ia = fillAnchorA, let ib = fillAnchorB,
              let a = fillAnchor(ia), let b = fillAnchor(ib) else { return }
        let pts = currentFillPoints()
        // 草稿在弹框期间变了（理论上已被挡住）：重新弹框而不是按旧数字落地
        if let prompt, prompt.insert != pts.count || prompt.remove != fillRemoveCount {
            // 弹框关闭时 isPresented 的 setter 会把 fillPrompt 置空，再弹要等它跑完
            DispatchQueue.main.async { [weak self] in self?.requestApplyFill() }
            return
        }
        // 改时计划只在「替换」时生效：「保留」时区间内的点原样留着，合成点照旧铺满 A → B
        let anyPlan = currentRetimePlan()
        let plan = removeInner ? anyPlan : nil
        let fillPts: [FillPoint]
        if let plan, let track { fillPts = StaleRetime.landingPoints(track: track, ia: ia, ib: ib, plan: plan, synthetic: pts) }
        else if anyPlan != nil { fillPts = FillPath.interpolate(a: a, vertices: fillVertices, b: b, spacingMeters: fillSpacingMeters) }
        else { fillPts = pts }
        guard !fillPts.isEmpty || (removeInner && fillRemoveCount > 0) else { return }
        // 有改时计划时区间内其余点一律替换（过时点要么改时要么删，不再按贴路保留）
        let synthetic = plan == nil ? fillPts : pts
        var keep = removeInner && plan == nil ? keptInnerPoints(ia: ia, ib: ib, vertices: fillVertices, candidate: fillCandidate, deleteOnly: synthetic.isEmpty) : []
        if let plan { keep.subtract(plan.retimed.map(\.index)) }   // 改时点：旧点照常删、新点在 fillPts 里
        var record = GapFill(anchorA: a, anchorB: b, vertices: fillVertices, points: fillPts,
                             removedInner: removeInner ? max(0, originalInnerCount(a: ia, b: ib) - keep.count) : 0,
                             userVertices: fillUserVertices, routeSource: fillRouteInfo?.source)
        record.segment = track?.topology.segment(of: ia) ?? 0
        record.plausibility = fillRouteInfo?.edited == true ? nil : fillRouteInfo?.plausibility   // 手改过顶点就不再是那条路线的评估
        if let plan, let track {
            record.retimedKeys = StaleRetime.keys(track: track, plan: plan)
            record.retimedOldKeys = StaleRetime.oldKeys(track: track, plan: plan)
        }
        // 路网证据：交叉验证的两份都留（一致与否都存比对结果；手改过顶点的把采用份坐标换成当前顶点并记一笔）；
        // 只有一份路网草稿时按状态行信息拼一份（顶点 = 当前草稿坐标）
        record.straight = fillRouteInfo == nil && fillVertices.isEmpty
        record.originalA = CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon); record.originalB = CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)
        let editedNote = String(localized: "取回后手动调整过顶点", comment: "Route evidence note: the fetched draft was edited by hand before applying")
        if let x = fillCrossDrafts {
            var shown = x.shown
            if fillRouteInfo?.edited == true {
                var e = RouteDraft(source: shown.source, coords: fillVertices, meters: shown.meters, snapA: shown.snapA, snapB: shown.snapB, endpoint: shown.endpoint,
                                   warnings: shown.warnings + [editedNote], notes: shown.notes, method: shown.method)
                e.shiftA = shown.shiftA; e.shiftB = shown.shiftB; e.anchorA = shown.anchorA; e.anchorB = shown.anchorB; e.residualA = shown.residualA; e.residualB = shown.residualB
                shown = e
            }
            record.drafts = [shown, x.other]
            record.cross = RouteCrossCheck.compare(x.shown, x.other, a: CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon), b: CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon))
        } else if let r = fillRouteInfo {
            var d = RouteDraft(source: r.source, coords: fillVertices, meters: r.meters, snapA: r.snapA, snapB: r.snapB, endpoint: r.endpoint,
                               warnings: r.warnings + (r.edited ? [editedNote] : []), notes: r.notes)
            d.shiftA = r.shiftA; d.shiftB = r.shiftB
            record.drafts = [d]
        }
        let job = GapSplice.Job(indexA: ia, indexB: ib, points: fillPts, removeInner: removeInner, keep: keep, trackID: track?.id, segment: record.segment)
        // 等确认框的关闭动画跑完再落地：SwiftUI 的 NSAlert 桥在布局过程中关框时，同一轮里的大量状态变更
        // 曾触发一次 UpdateCycle 空指针崩溃（2026-10-21 钩子回归偶发）
        enqueueEdit { $0.performFills([(job, record)]) }
    }

    /// 同路段套用：两端都在 300m 内（允许反向）的其它候选
    func similarGaps(to f: GapFill) -> [GapCandidate] {
        let r = 300.0
        return gapCandidates.filter { c in
            let dAA = GeoMath.haversine(c.latA, c.lonA, f.anchorA.lat, f.anchorA.lon)
            let dBB = GeoMath.haversine(c.latB, c.lonB, f.anchorB.lat, f.anchorB.lon)
            let dAB = GeoMath.haversine(c.latA, c.lonA, f.anchorB.lat, f.anchorB.lon)
            let dBA = GeoMath.haversine(c.latB, c.lonB, f.anchorA.lat, f.anchorA.lon)
            return (dAA <= r && dBB <= r) || (dAB <= r && dBA <= r)
        }
    }

    func requestApplySimilar() {
        guard let f = lastFill, batch == nil else { return }
        let sims = similarGaps(to: f)
        guard !sims.isEmpty else { return }
        fillSimilarPrompt = sims
    }

    /// 套用：每个相似断档用同一条顶点折线（反向时倒序），锚点取各自的两端，一次重建
    func confirmApplySimilar() {
        guard batch == nil, let f = lastFill, let sims = fillSimilarPrompt else { return }
        fillSimilarPrompt = nil
        var batch: [(GapSplice.Job, GapFill)] = []
        let template = f.userVertices ?? f.vertices      // 只复用用户画的隧道轮廓，不带上一处的出口点
        for c in sims {
            guard let track, let a = fillAnchor(c.indexA), let b = fillAnchor(c.indexB) else { continue }
            let forward = GeoMath.haversine(c.latA, c.lonA, f.anchorA.lat, f.anchorA.lon)
                <= GeoMath.haversine(c.latA, c.lonA, f.anchorB.lat, f.anchorB.lon)
            var verts = forward ? template : Array(template.reversed())
            if f.routeSource != nil {
                // 路网草稿贴着道路一直铺到出口附近：按这处的新锚点在模板上裁一段，不再追加出口点（会折返）
                verts = Self.clipPolyline(verts, from: CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon),
                                          to: CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon))
            } else if c.kind == .staleClock, c.innerCount > c.frozenA {
                // 这处自己的过时出口点（紧挨 B 之前、位于出口道路上）同样当作顶点，替换为时间正确的点；
                // A 侧冻结外推假点（frozenA）位置不真实，不当顶点（与 seededVertices 一致）
                verts += (track.topology.indices(between: c.indexA, and: c.indexB).map { Array($0.dropFirst(c.frozenA)) } ?? []).map {
                    CLLocationCoordinate2D(latitude: track.lat[$0], longitude: track.lon[$0])
                }
            }
            let pts = FillPath.interpolate(a: a, vertices: verts, b: b, spacingMeters: spacingFor(c.indexA, c.indexB))
            guard !pts.isEmpty else { continue }
            var rec = GapFill(anchorA: a, anchorB: b, vertices: verts, points: pts,
                              removedInner: originalInnerCount(a: c.indexA, b: c.indexB),
                              userVertices: forward ? template : Array(template.reversed()), routeSource: f.routeSource)
            rec.segment = c.segment
            rec.drafts = f.drafts.map { d in var x = d; x.notes = [String(localized: "沿用同路段那处的路网折线（套用相似）", comment: "Route evidence note on a gap filled by reusing a similar gap's polyline")] + x.notes; return x }
            rec.originalA = CLLocationCoordinate2D(latitude: c.latA, longitude: c.lonA); rec.originalB = CLLocationCoordinate2D(latitude: c.latB, longitude: c.lonB)
            batch.append((GapSplice.Job(indexA: c.indexA, indexB: c.indexB, points: pts, removeInner: c.innerCount > 0, trackID: track.id, segment: c.segment), rec))
        }
        guard !batch.isEmpty else { return }
        enqueueEdit { $0.performFills(batch) }   // 同上：确认框关闭后再落地
    }

    /// 把折线裁到 a、b 在折线上投影点之间的那一段（a 的投影在 b 之后则反向）
    static func clipPolyline(_ pts: [CLLocationCoordinate2D], from a: CLLocationCoordinate2D,
                             to b: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        guard pts.count >= 2 else { return pts }
        func project(_ p: CLLocationCoordinate2D) -> (seg: Int, t: Double, s: Double) {
            let kx = 111_320.0 * cos(p.latitude * .pi / 180), ky = 110_540.0
            var best = (seg: 0, t: 0.0, s: 0.0); var bestD = Double.infinity; var acc = 0.0
            for k in 1..<pts.count {
                let ux = (pts[k - 1].longitude - p.longitude) * kx, uy = (pts[k - 1].latitude - p.latitude) * ky
                let vx = (pts[k].longitude - p.longitude) * kx, vy = (pts[k].latitude - p.latitude) * ky
                let dx = vx - ux, dy = vy - uy, len2 = dx * dx + dy * dy
                let t = len2 > 0 ? max(0, min(1, -(ux * dx + uy * dy) / len2)) : 0
                let fx = ux + dx * t, fy = uy + dy * t
                let d = (fx * fx + fy * fy).squareRoot()
                let segLen = len2.squareRoot()
                if d < bestD { bestD = d; best = (k - 1, t, acc + segLen * t) }
                acc += segLen
            }
            return best
        }
        var pa = project(a), pb = project(b)
        var reversed = false
        if pa.s > pb.s { swap(&pa, &pb); reversed = true }
        // 取 pa 之后、pb 之前的原有顶点（投影点本身不加：锚点已经在那附近）
        var out: [CLLocationCoordinate2D] = []
        for k in (pa.seg + 1)...pb.seg where k < pts.count { out.append(pts[k]) }
        if pa.seg == pb.seg { out = [] }
        return reversed ? Array(out.reversed()) : out
    }

    /// 撤销上一次落地（整批）：从快照重建
    func undoLastFill() {
        guard let snap = fillUndo, !isLoading, batch == nil else { return }
        guard let source = track else { return }
        let token = beginDataOperation(source: source)
        let mode = settings.colorMode
        let single = singleRGBA()
        isLoading = true
        loadingLabel = String(localized: "撤销补点…", comment: "Loading overlay while undoing the last Gap Fill")
        let parsed = snap.parsed
        resetFillDraft()
        gapCandidates = []
        Task.detached(priority: .userInitiated) { [weak self] in
            let (newTrack, newStats) = TrackData.build(parsed: parsed, preferredMode: mode, singleColor: single)
            guard let self else { return }
            await self.publishData(token) {
                self.fillUndo = nil; self.fillCanUndo = false
                self.fillApplying = true
                self.preserveNextCamera = true
                if self.files.count == 1 { self.files[0].parsed = parsed }
                self.apply(track: newTrack, stats: newStats)
                self.fillApplying = false
                // A fill transaction may contain delete-only records as well.
                // Restore its complete pre-transaction log, not only fill IDs.
                self.changes = snap.changes
                self.fills = snap.fills
                self.lastFill = snap.last
                self.resetFillDraft()
                self.refreshGapCandidates()
            }
        }
    }

    private func performFills(_ batch: [(GapSplice.Job, GapFill)]) {
        guard let current = track, !isLoading else { return }
        let jobs = batch.map { $0.0 }
        var memberships: [GapSplice.Membership] = []
        for job in jobs {
            guard case .success(let membership) = GapSplice.membership(to: current, job: job) else {
                errorMessage = String(localized: "无法应用补点：锚点或区间已改变，请重新选择。", comment: "Apply-fill conflict: the anchors or segment membership changed; select the gap again")
                return
            }
            memberships.append(membership)
        }
        let token = beginDataOperation(source: current)
        let landingToast = pendingLandingToast
        pendingLandingToast = nil   // owned by this transaction; cannot leak into a later file/fill
        // 撤销快照：ParsedTrack 直接共享 TrackData 的数组存储（写时复制，不拷贝）
        var snapParsed = ParsedTrack()
        snapParsed.lat = current.lat; snapParsed.lon = current.lon
        snapParsed.ele = current.ele; snapParsed.time = current.time
        snapParsed.name = current.name
        snapParsed.creator = current.creator; snapParsed.accuracyMedian = current.gpsAccuracy
        snapParsed.fileID = current.fileID; snapParsed.segmentID = current.segmentID
        let baseline = snapParsed
        let undoSnapshot = (snapParsed, fills, lastFill, changes)
        let records = batch.map { $0.1 }
        let now = Date()
        let newChanges: [TrackChange] = zip(batch, memberships).map { pair, membership in
            let (_, rec) = pair
            let added = rec.points.map { ChangePoint(lat: $0.lat, lon: $0.lon, ele: $0.ele, time: $0.time, originalIndex: -1, segment: rec.segment) }
            var removed: [ChangePoint] = []
            for k in membership.removed {
                removed.append(ChangePoint(lat: current.lat[k], lon: current.lon[k], ele: current.ele[k], time: current.time[k], originalIndex: k, segment: current.topology.segment(of: k)))
            }
            let anchors = [rec.anchorA, rec.anchorB].map { ChangePoint(lat: $0.lat, lon: $0.lon, ele: $0.ele, time: $0.time, originalIndex: -1, segment: rec.segment) }
            // 没插点（乱跳只删点 / 两锚点太近只删飘点）：是一条删除记录，不进补点清单
            let isFill = !rec.points.isEmpty
            var change = TrackChange(kind: isFill ? .fill : .deletion, date: now, added: added, removed: removed, anchors: anchors, fillID: isFill ? rec.id : nil)
            change.drafts = rec.drafts; change.cross = rec.cross; change.routeSource = rec.routeSource
            change.straight = rec.straight
            change.originalA = rec.originalA; change.originalB = rec.originalB
            change.retimed = rec.retimed; change.retimedKeys = rec.retimedKeys; change.retimedOldKeys = rec.retimedOldKeys
            change.plausibility = rec.plausibility
            return change
        }
        let mode = settings.colorMode
        let single = singleRGBA()
        // 重建期间锚点/候选都指向旧轨迹：先清空草稿与列表，落地后重新检测
        resetFillDraft()
        gapCandidates = []
        isLoading = true
        let inserted = records.reduce(0) { $0 + $1.points.count - $1.retimed }   // 改时点不算新增
        let retimedTotal = records.reduce(0) { $0 + $1.retimed }
        if inserted > 0 {
            let insertedText = inserted.formatted()
            loadingLabel = String(localized: "补入 \(insertedText) 个点…", comment: "Loading overlay while applying fills; %@ = number of points inserted (already formatted with grouping)")
        } else if retimedTotal > 0 {
            loadingLabel = String(localized: "改时间 \(retimedTotal) 个点…", comment: "Loading overlay while applying fills that only correct timestamps of kept points; %lld = number of points retimed")
        } else {
            loadingLabel = String(localized: "删除 \(jobs.count) 处的乱跳点…", comment: "Loading overlay while applying delete-only fills; %lld = number of places whose jitter points are removed")
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard case .success(let p) = GapSplice.plan(to: current, jobs: jobs) else {
                guard let self else { return }
                await self.publishData(token) {
                    self.isLoading = false
                    self.errorMessage = String(localized: "无法应用补点：锚点或区间已改变，请重新选择。", comment: "Apply-fill conflict: the anchors or segment membership changed; select the gap again")
                }
                return
            }
            let (newTrack, newStats) = TrackData.build(parsed: p, preferredMode: mode, singleColor: single)
            guard let self else { return }
            await self.publishData(token) {
                self.rememberEditBaseline(baseline)
                self.fillUndo = undoSnapshot
                self.fillApplying = true
                self.preserveNextCamera = true
                if self.files.count == 1 { self.files[0].parsed = p }
                self.apply(track: newTrack, stats: newStats)
                self.fillApplying = false
                let real = records.filter { !$0.points.isEmpty }
                self.fills += real
                self.lastFill = real.last ?? self.lastFill
                self.fillCanUndo = true
                self.changes += newChanges
                self.resetFillDraft()
                self.refreshGapCandidates()
                if let n = landingToast {
                    let removed = newChanges.reduce(0) { $0 + $1.netRemoved }   // 改时点的旧点不算替换
                    var text = String(localized: "已落地 \(n) 处 · 新增 \(inserted) 点 · 替换 \(removed) 点", comment: "Toast after batch gap fill was applied. Placeholders: number of gaps applied; points added; original points replaced")
                    if retimedTotal > 0 {
                        text += " · " + String(localized: "改时间 \(retimedTotal) 点", comment: "Change Log: number of existing points whose position was kept and only the timestamp was corrected (stale-clock exit points after a tunnel); shown after “+N points”, e.g. “+7 points · retimed 1 point”")
                    }
                    self.showToast(text,
                                   action: .openReview, actionTitle: String(localized: "查看修改记录", comment: "Toast button: open the Change Log window"))
                }
            }
        }
    }

    // MARK: - 修改记录（单文件模式：补点 / 删除，逐条还原）

    @Published private(set) var changes: [TrackChange] = []
    /// 还没还原的修改
    var activeChanges: [TrackChange] { changes.filter { !$0.reverted } }
    /// 审阅顺序：沿轨迹时刻（人工逐个校验按路线走，不按操作先后）
    var orderedChanges: [TrackChange] {
        changes.sorted { a, b in
            switch (a.trackTime, b.trackTime) {
            case let (x?, y?): return x != y ? x < y : a.date < b.date
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.date < b.date
            }
        }
    }
    @Published var reviewDetail = false                  // 修改记录窗口：false 总览 / true 详细
    @Published var reviewSelection: UUID?                // 详细页正在看的那一处
    /// 修改记录窗口的「落地前审阅」模式：列表与合成轨迹来自批量项（将落地的效果），不是已落地的修改
    @Published var reviewPreview = false
    /// 审阅地图自己的底图（与主窗口无关；默认浅色——深色底图上蓝点看不清）
    @Published var reviewMapStyle: BaseMapStyle = BaseMapStyle(rawValue: UserDefaults.standard.string(forKey: "reviewMapStyle") ?? "") ?? .standard {
        didSet { UserDefaults.standard.set(reviewMapStyle.rawValue, forKey: "reviewMapStyle") }
    }
    @Published var reviewLightMap = UserDefaults.standard.object(forKey: "reviewLightMap") as? Bool ?? true {
        didSet { UserDefaults.standard.set(reviewLightMap, forKey: "reviewLightMap") }
    }
    /// 叠加 OSM 隧道（任何底图上都能开；主窗口与审阅窗口各自按视野取数，TunnelOverlay.swift）
    @Published var tunnelOverlay = UserDefaults.standard.object(forKey: "tunnelOverlay") as? Bool ?? false {
        didSet { UserDefaults.standard.set(tunnelOverlay, forKey: "tunnelOverlay") }
    }
    /// 主窗口隧道层状态行（「隧道层：取回 N 条 / 冷却中 / …」；关着时 nil）
    @Published var tunnelStatus: String?
    /// 审阅窗口隧道层状态行
    @Published var reviewTunnelStatus: String?
    /// 第一次切到外部底图（OSM / OpenTopoMap / Esri）的一次性说明；弹过记在 UserDefaults 不再弹
    @Published var externalMapNotice = false
    @Published var reviewExternalMapNotice = false
    func noteBaseMapChosen(_ style: BaseMapStyle, review: Bool = false) {
        guard ExternalMapNotice.consume(for: style) else { return }
        if review { reviewExternalMapNotice = true } else { externalMapNotice = true }
    }
    private var previewChangesCache: (key: String, list: [TrackChange])?
    private var previewIDs: [GapID: UUID] = [:]

    /// 审阅窗口正在列的项（按轨迹顺序）：预览模式 = 批量项的落地效果；否则 = 修改记录
    var reviewItems: [TrackChange] { reviewPreview ? batchPreviewChanges : orderedChanges }
    /// 合成轨迹要画的项：预览模式只画勾选落地的；否则画未还原的
    var reviewActiveItems: [TrackChange] { reviewPreview ? batchPreviewChanges.filter { $0.previewIncluded } : activeChanges }
    func reviewItem(_ id: UUID) -> TrackChange? { reviewItems.first { $0.id == id } }

    /// 批量项 → 落地效果的预览记录（与 landBatch 同一口径：外推锚点、点距、区间内保留点）。按内容键缓存
    var batchPreviewChanges: [TrackChange] {
        guard let st = batch, st.phase == .preview || st.phase == .landing, let track, track.id == st.trackID else { return [] }
        let key = st.items.map { it in
            "\(it.id)|\(it.status.isDone ? "d" : (it.status.isConflict ? "c" : (it.status.isFailed ? "f" : "x")))|\(it.include)|\(it.useStraight)|\(it.deleteOnly)|\(it.draft?.source.rawValue ?? "-")|\(it.draft?.coords.count ?? -1)|\(it.declined)|\(it.refetchCount)"
        }.joined(separator: ";") + "|\(fillSpacingManual ? fillSpacingMeters : -1)"
        if let c = previewChangesCache, c.key == key { return c.list }
        var out: [TrackChange] = []
        var lastB: [UInt32: Int] = [:]                                   // 与 landBatch 同口径：只在将落地的项之间防重叠
        for item in st.items.sorted(by: { $0.candidate.indexA < $1.candidate.indexA }) where item.kind != nil && item.kind != .skip {
            guard let (ch, ib) = previewChange(for: item, track: track, lastB: item.willLand ? (lastB[item.candidate.segment] ?? -1) : -1) else { continue }
            if item.willLand { lastB[item.candidate.segment] = ib }
            out.append(ch)
        }
        previewChangesCache = (key, out)
        return out
    }

    /// 一个批量项将要做的事（预览用；不改任何状态）——几何完全走 landingJob（与落地同口径）。没有可画的东西返回 nil
    private func previewChange(for item: BatchItem, track: TrackData, lastB: Int) -> (TrackChange, Int)? {
        guard let (job, rec) = landingJob(for: item, track: track, lastB: lastB, forPreview: true) else { return nil }
        var removed: [ChangePoint] = []
        guard case .success(let membership) = GapSplice.membership(to: track, job: job) else { return nil }
        for k in membership.removed { removed.append(ChangePoint(lat: track.lat[k], lon: track.lon[k], ele: track.ele[k], time: track.time[k], originalIndex: k, segment: track.topology.segment(of: k))) }
        let added = rec.points.map { ChangePoint(lat: $0.lat, lon: $0.lon, ele: $0.ele, time: $0.time, originalIndex: -1, segment: rec.segment) }
        let anchors = [rec.anchorA, rec.anchorB].map { ChangePoint(lat: $0.lat, lon: $0.lon, ele: $0.ele, time: $0.time, originalIndex: -1, segment: rec.segment) }
        let id = previewIDs[item.id] ?? { let u = UUID(); previewIDs[item.id] = u; return u }()
        var ch = TrackChange(id: id, kind: added.isEmpty ? .deletion : .fill, date: Date(), added: added, removed: removed, anchors: anchors, fillID: nil)
        ch.drafts = rec.drafts
        ch.cross = rec.cross
        ch.routeSource = rec.routeSource
        ch.straight = rec.straight
        ch.originalA = rec.originalA; ch.originalB = rec.originalB
        ch.retimed = rec.retimed; ch.retimedKeys = rec.retimedKeys; ch.retimedOldKeys = rec.retimedOldKeys
        ch.plausibility = rec.plausibility
        ch.previewItemID = item.id
        ch.previewIncluded = item.willLand
        ch.previewPending = item.status.isConflict && !item.declined
        ch.previewDeclined = item.status.isConflict && item.declined
        ch.previewUnverified = item.status.isUnverified
        let f = added.first, l = added.last
        ch.contentKey = "\(rec.routeSource?.rawValue ?? "-")|\(rec.straight)|\(job.indexA)-\(job.indexB)|\(added.count)/\(removed.count)|\(f.map { String(format: "%.6f,%.6f", $0.lat, $0.lon) } ?? "")|\(l.map { String(format: "%.6f,%.6f", $0.lat, $0.lon) } ?? "")"
        return (ch, track.topology.pathRank(of: job.indexB))
    }

    /// 主窗口「修改记录」入口：一律进真实记录模式（预览模式只由批量第 3 步的按钮进入）
    func openChangeLog() {
        if reviewPreview { reviewPreview = false; reviewSelect(nil) }
    }

    /// 打开落地前审阅（批量第 3 步）：窗口由调用方打开
    func openBatchPreview() {
        guard let st = batch, st.phase == .preview else { return }
        reviewPreview = true
        reviewSelect(nil)
    }
    /// 预览模式里切换某一处落不落地（= 批量窗口的「落地」勾选）
    func setPreviewIncluded(_ changeID: UUID, _ on: Bool) {
        guard let ch = reviewItem(changeID), let itemID = ch.previewItemID else { return }
        setBatchInclude(itemID, on)
    }
    @Published private(set) var reviewTrack: TrackData?  // 合成轨迹：蓝 = 轨迹、绿 = 新增、红 = 删除
    @Published private(set) var reviewBuilding = false
    @Published private(set) var reviewPlaces: [UUID: String] = [:]   // 国家 - 州 - 城市（逆地理编码结果缓存）
    @Published private(set) var reviewFlags: [UUID: String] = [:]    // 国旗 emoji（ISO 国家码 → 区域指示符）
    private var reviewTrackKey = ""
    private var reviewRebuildPending = false
    private var keepChangeLog = false                    // 删除/还原重建期间 apply() 不清修改记录
    private var reviewGeocoder: CLGeocoder?
    /// 审阅地图协调器挂上来的当前可见范围（minLat, minLon, maxLat, maxLon），自测用
    var reviewVisibleBox: (() -> (Double, Double, Double, Double)?)?
    private var reviewGeocoding = Set<UUID>()
    private var reviewPlaceFailed = Set<UUID>()         // 地名查询失败过的（再进入时重试）

    /// 详细页「OSRM | Valhalla」切换：当前显示哪一份草稿（nil = 采用的那份 / 第一份）。只改显示，不改采用与勾选；换一处时复位
    @Published var reviewShownSource: RouteSource?
    func reviewShowDraft(_ source: RouteSource?) {
        guard let id = reviewSelection, let c = reviewItem(id) else { return }
        guard let s = source else { reviewShownSource = nil; return }
        guard c.drafts.contains(where: { $0.source == s }) else { return }
        reviewShownSource = s
    }
    /// 轮到下一份（钩子 reviewdraft next）
    func reviewShowNextDraft() {
        guard let id = reviewSelection, let c = reviewItem(id), c.drafts.count >= 2 else { return }
        let cur = Self.reviewShownDraft(c, preferred: reviewShownSource)?.source
        let i = c.drafts.firstIndex { $0.source == cur } ?? -1
        reviewShownSource = c.drafts[(i + 1) % c.drafts.count].source
    }
    /// 详细页当前显示的那份：用户选的 → 采用的 → 第一份
    static func reviewShownDraft(_ c: TrackChange, preferred: RouteSource?) -> RouteDraft? {
        if let p = preferred, let d = c.drafts.first(where: { $0.source == p }) { return d }
        return c.drafts.first { !c.straight && c.routeSource != nil && $0.source == c.routeSource } ?? c.drafts.first
    }
    /// 两份草稿几何完全相同（比对最大偏差为 0，或坐标逐点相等）：切换时提示用户别以为没反应
    static func reviewSameGeometry(_ c: TrackChange) -> Bool {
        guard c.drafts.count >= 2 else { return false }
        if let x = c.cross, x.maxDev == 0 { return true }
        let p = c.drafts[0], q = c.drafts[1]
        guard p.coords.count == q.coords.count, p.shiftA == q.shiftA, p.shiftB == q.shiftB else { return false }
        func same(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D?) -> Bool {
            switch (a, b) { case (nil, nil): return true; case (let a?, let b?): return a.latitude == b.latitude && a.longitude == b.longitude; default: return false }
        }
        guard same(p.anchorA, q.anchorA), same(p.anchorB, q.anchorB) else { return false }
        return zip(p.coords, q.coords).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
    }

    /// 详细页选中（nil = 回到总览）
    func reviewSelect(_ id: UUID?) {
        if id != reviewSelection { reviewShownSource = nil }   // 翻到另一处：显示份复位为采用的那份
        reviewSelection = id
        reviewDetail = id != nil
        if let id, let c = reviewItem(id) { requestReviewPlace(c) }
    }
    /// 主地图飞到一块范围（修改记录「在主地图上看」）：只飞相机，不改主窗口的模式（补点/批量/筛选一律不动）。
    /// 地图视图看到 mapFocusVersion 变化后按 mapFocusRequest 取景，和批量小卡片飞断档共用同一套外扩/避让（PointMapView.flyTo）
    struct MapFocusRequest { let minLat, maxLat, minLon, maxLon: Double; let minSpanMeters: Double; let keepKey: NSWindow? }
    @Published private(set) var mapFocusVersion = 0
    private(set) var mapFocusRequest: MapFocusRequest?
    /// 主地图当前取景（中心 + 宽度 km）；地图视图挂上来，钩子 reviewstate 用
    var mainMapRegion: (() -> (lat: Double, lon: Double, spanKm: Double)?)?

    /// 修改记录详细页「在主地图上看」：主窗口地图飞到当前这处（外扩一点、最小跨度按这处范围保证看清），
    /// 主窗口置前但修改记录窗口保持键盘焦点（‹ › / 方向键继续翻）
    func reviewShowOnMainMap() {
        guard let id = reviewSelection, let c = reviewItem(id) else { return }
        let b = c.bbox
        guard b.minLat <= b.maxLat, b.minLon <= b.maxLon else { return }
        mapFocusRequest = MapFocusRequest(minLat: b.minLat, maxLat: b.maxLat, minLon: b.minLon, maxLon: b.maxLon,
                                          minSpanMeters: max(800, c.spanMeters * 1.3),
                                          keepKey: NSApp.window(scene: SceneID.changeReview))
        mapFocusVersion &+= 1
    }

    /// 上一处 / 下一处（按轨迹顺序，含已还原的，便于复核）
    func reviewStep(_ delta: Int) {
        let list = reviewItems
        guard !list.isEmpty else { return }
        let cur = reviewSelection.flatMap { id in list.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : list.count)
        let next = min(max(cur + delta, 0), list.count - 1)
        reviewSelect(list[next].id)
        // 详细页「主地图跟随」开着：翻页后自动执行一次「在主地图上看」（翻到头没动也飞，等于再看一次当前这处）
        if reviewFollowMap, reviewDetail { reviewShowOnMainMap() }
    }
    /// 修改记录详细页「主地图跟随」（偏好 reviewFollowMap，默认关）：开着时 ‹ › / ← → 翻页后主地图自动飞到那一处
    var reviewFollowMap: Bool {
        get { UserDefaults.standard.bool(forKey: "reviewFollowMap") }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "reviewFollowMap") }
    }

    /// 还原若干处修改：按值去掉它们新增的点、按时间把删掉的点插回去，整条重建一次
    func revertChanges(_ ids: Set<UUID>) {
        guard let current = track, !isLoading, batch == nil, displayMode == .single else { return }
        let targets = changes.filter { ids.contains($0.id) && !$0.reverted }
        guard !targets.isEmpty else { return }
        let token = beginDataOperation(source: current)
        let history = changes
        let baseline = editBaseline
        noteUserActivity()
        let mode = settings.colorMode
        let single = singleRGBA()
        let keepFill = fillMode
        if keepFill { resetFillDraft(); gapCandidates = [] }
        isLoading = true
        loadingLabel = String(localized: "还原 \(targets.count) 处修改…", comment: "Loading overlay while reverting entries of the Change Log; %lld = number of changes")
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = ChangeRevert.apply(to: current, changes: targets, history: history, baseline: baseline)
            guard case .success(let p) = result else {
                guard let self else { return }
                await self.publishData(token) {
                    self.isLoading = false; self.loadingLabel = ""; self.loadingProgress = nil
                    self.errorMessage = String(localized: "无法安全还原这些修改。请连同后续相关修改一起还原，或还原全部修改。", comment: "Safe refusal when selected changes depend on later edits or point order is ambiguous")
                }
                return
            }
            let (newTrack, newStats) = TrackData.build(parsed: p, preferredMode: mode, singleColor: single)
            guard let self else { return }
            await self.publishData(token) {
                self.fillApplying = true          // 补点模式与记录跨重建保留（和撤销落地一样）
                self.keepChangeLog = true
                self.preserveNextCamera = true
                if self.files.count == 1 { self.files[0].parsed = p }
                self.apply(track: newTrack, stats: newStats)
                self.keepChangeLog = false
                self.fillApplying = false
                let fillIDs = Set(targets.compactMap(\.fillID))
                if !fillIDs.isEmpty { self.fills.removeAll { fillIDs.contains($0.id) } }
                self.lastFill = nil
                self.fillUndo = nil               // 整批撤销的快照已不对应现在的轨迹
                self.fillCanUndo = false
                let now = Date()
                for i in self.changes.indices where ids.contains(self.changes[i].id) && !self.changes[i].reverted {
                    self.changes[i].reverted = true
                    self.changes[i].revertedDate = now
                }
                if keepFill { self.resetFillDraft(); self.refreshGapCandidates() }
            }
        }
    }
    func revertAllChanges() { revertChanges(Set(activeChanges.map(\.id))) }

    /// 审阅合成轨迹按需重建（窗口打开时调用；轨迹或未还原集合变了才重建，后台构建）
    func ensureReviewTrack() {
        let items = reviewActiveItems
        guard let current = track, displayMode == .single, !reviewItems.isEmpty else {
            if reviewTrack != nil { reviewTrack = nil }
            reviewTrackKey = ""
            return
        }
        let key = (reviewPreview ? "preview|" : "changes|") + current.id.uuidString + "|" + items.map { $0.id.uuidString + $0.contentKey + "\($0.added.count)/\($0.removed.count)" }.joined(separator: ",")
        guard key != reviewTrackKey else { return }
        // A changed input receives a new owner immediately; an older build may finish, but cannot publish.
        if reviewBuilding { reviewBuilding = false }
        let token = publicationClock.begin(.review, fileIDs: files.map(\.id), sourceID: current.id)
        reviewTrackKey = key
        reviewBuilding = true
        let changes = items
        let preview = reviewPreview
        Task.detached(priority: .userInitiated) { [weak self] in
            let parsed = preview ? ChangeRevert.previewParsed(current: current, changes: changes) : ChangeRevert.reviewParsed(current: current, changes: changes)
            // fileID 0 轨迹蓝 / 1 新增绿 / 2 删除红 / 3 改时间橙（StaleRetime 保留位置的过时出口点）
            let colors: [SIMD4<UInt8>] = [SIMD4(10, 122, 255, 190), SIMD4(40, 200, 80, 255), SIMD4(235, 50, 50, 255), SIMD4(255, 160, 0, 255)]
            let built = TrackData.build(parsed: parsed, preferredMode: .single, singleColor: colors[0], overlayFileColors: colors).0
            guard let self else { return }
            await MainActor.run {
                guard self.owns(token) else { return }
                self.reviewBuilding = false
                if self.track?.id == current.id { self.reviewTrack = built } else { self.reviewTrackKey = "" }
                if self.reviewRebuildPending { self.reviewRebuildPending = false; self.ensureReviewTrack() }
            }
        }
    }

    /// 国家 - 州 - 城市（CLGeocoder 逆地理编码，一处一次，结果缓存）
    func requestReviewPlace(_ c: TrackChange) {
        guard reviewPlaces[c.id] == nil || reviewPlaceFailed.contains(c.id), !reviewGeocoding.contains(c.id) else { return }
        if reviewPreview && c.previewItemID == nil { return }
        reviewPlaceFailed.remove(c.id)
        reviewGeocoder?.cancelGeocode()                  // ← → 快速翻处：只查当前这处，上一处的请求取消（失败不缓存，下次再查）
        if c.kind == .replay { reviewPlaces[c.id] = String(localized: "整条轨迹（回放点散布全程）", comment: "Change Log place line for a Replay Cleanup: the whole track (replay points are spread over all of it)"); return }
        reviewGeocoding.insert(c.id)
        let id = c.id
        let center = c.center
        let g = reviewGeocoder ?? CLGeocoder()
        reviewGeocoder = g
        g.reverseGeocodeLocation(CLLocation(latitude: center.latitude, longitude: center.longitude)) { [weak self] marks, error in
            let text: String
            var flag = ""
            var failedNow = false
            if let iso = marks?.first?.isoCountryCode?.uppercased(), iso.count == 2 {
                flag = String(iso.unicodeScalars.compactMap { UnicodeScalar(0x1F1E6 + ($0.value - 65)) }.map(Character.init))
            }
            if let m = marks?.first {
                let parts = [m.country, m.administrativeArea ?? m.subAdministrativeArea, m.locality ?? m.subLocality ?? m.name]
                    .compactMap { $0 }.filter { !$0.isEmpty }
                text = parts.isEmpty ? String(localized: "（没有地名）", comment: "Change Log place line when reverse geocoding returned no names") : parts.joined(separator: " - ")
            } else {
                failedNow = true
                let why = error.map { NetworkHealth.describe($0) } ?? String(localized: "没有结果", comment: "Reverse-geocoding failure reason: the service returned no result")
                if let e = error, (e as? CLError)?.code == .network { NetworkHealth.note(host: "geocode", ok: false, seconds: 0, detail: String(localized: "地名服务没有网络", comment: "Network banner detail: the place-name (reverse geocoding) service has no network")) }
                text = String(localized: "（地名查询失败：\(why)，可稍后再点进来重试）", comment: "Change Log place line when reverse geocoding failed; %@ = reason")
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reviewGeocoding.remove(id)
                if failedNow { self.reviewPlaceFailed.insert(id) }
                if self.changes.contains(where: { $0.id == id }) || self.previewIDs.values.contains(id) { self.reviewPlaces[id] = text; if !flag.isEmpty { self.reviewFlags[id] = flag } }
            }
        }
    }

    // MARK: 一键补全部断档（分类 → 顺序取草稿 → 预览 → 一次落地）

    @Published var batch: BatchState?
    /// 批量窗口折叠成小卡片（点一行看地图时）：只留当前这处的信息和选择，地图露出来
    @Published var batchCompact = false {
        didSet { if batchCompact != oldValue { DispatchQueue.main.async { [weak self] in self?.dockBatchWindow() } } }
    }
    /// 第 2/3 步表格的三个过滤开关（互斥；新一批开始时清零）。放在 store 里是为了钩子能开关、能报筛选后行数
    @Published var batchWarnedOnly = false       // 只看有疑点的
    @Published var batchConflictOnly = false     // 精确模式：只看要你选的
    @Published var batchRiskOnly = false         // 落地前自检：只看要看一眼的（medium + high）
    /// 表格实际列出的行（过滤 + 风险排序）。过滤结果为空时回到全表，开关不会把表格卡空
    func batchVisibleRows(_ st: BatchState) -> [BatchItem] {
        let rows: [BatchItem]
        if batchConflictOnly, st.pendingPickCount > 0 {
            rows = st.items.filter { $0.status.isConflict && !$0.declined }
        } else if batchWarnedOnly, case let w = st.items.filter({ $0.status.isDone && !($0.draft?.warnings.isEmpty ?? true) }), !w.isEmpty {
            rows = w
        } else if batchRiskOnly, case let r = st.items.filter({ Self.batchNeedsLook($0) }), !r.isEmpty {
            rows = r
        } else {
            rows = st.items
        }
        return BatchFillWindowView.riskSorted(rows)
    }
    /// 「要看一眼的」= 落地前自检 medium 或 high
    static func batchNeedsLook(_ it: BatchItem) -> Bool { (it.plausibility?.level ?? .low) != .low }
    /// 单处卡片内容的实测高度（SwiftUI 布局后回报；0 = 还没量到）。卡片窗口高度 = 它 + 标题栏
    var batchCardContentHeight: CGFloat = 0 {
        didSet {
            guard abs(batchCardContentHeight - oldValue) > 1, batchCompact else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.batchCompact, let win = NSApp.window(scene: SceneID.batchFill), win.isVisible, self.batchSavedFrame != nil else { return }
                self.applyBatchCard(win)
            }
        }
    }
    private var batchSavedFrame: NSRect?
    private var batchPinTopLeft: NSPoint?                  // 折叠期间卡片应在的左上角（SwiftUI 重排后钉回去）
    /// 折叠卡片的目标框（屏幕坐标）：飞到断档时按它避让，不等窗口真的缩完（SwiftUI 重排有延迟）
    var batchCardTarget: NSRect?
    private var batchResizeObserver: NSObjectProtocol?
    var lastDockInfo = ""                                   // 钩子诊断用
    /// SwiftUI 的 Window 场景在内容理想尺寸变化后会按原左上角重排窗口，把我们设的位置盖掉：
    /// 折叠期间每次尺寸变化都把左上角钉回目标；用户自己拖动（didMove 不带尺寸变化）不干预
    private weak var batchObservedWindow: NSWindow?
    private var batchCloseObserver: NSObjectProtocol?
    private func pinBatchWindow(_ win: NSWindow) {
        guard batchObservedWindow !== win else { return }
        batchObservedWindow = win
        if let o = batchResizeObserver { NotificationCenter.default.removeObserver(o) }
        if let o = batchCloseObserver { NotificationCenter.default.removeObserver(o) }
        batchResizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: win, queue: .main) { [weak self, weak win] _ in
            MainActor.assumeIsolated {
                guard let self, let win, self.batchCompact, let tl = self.batchPinTopLeft else { return }
                if abs(win.frame.minX - tl.x) > 2 || abs(win.frame.maxY - tl.y) > 2 {
                    win.setFrameOrigin(NSPoint(x: tl.x, y: tl.y - win.frame.height))
                }
            }
        }
        // 关窗 = 离开小卡片：先把原框放回去（SwiftUI 记住的是关窗时的框，下次打开才是大窗口），再退出折叠。
        // 以前关窗不清 batchCompact，重开时恢复成大窗口、折叠标志却还在（didSet 不再触发）→ 大窗口中间一张卡片
        batchCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self, weak win] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let f = self.batchSavedFrame, let win { win.setFrame(f, display: false) }
                self.batchSavedFrame = nil
                self.batchPinTopLeft = nil
                self.batchCardTarget = nil
                if self.batchCompact { self.batchCompact = false }
                self.lastDockInfo = "dock: window closed"
            }
        }
    }
    /// 小卡片的目标框（屏幕坐标）：宽 560，高 = 卡片内容实测高度（compactView 用 onGeometryChange 回报）+ 标题栏，
    /// 限制在 160…560；还没量到时先用 fittingSize / 默认 300，量到后 batchCardContentHeight 的 didSet 再校正。
    /// 停到主窗口顶部居中、往下 40（两侧面板不在那里，地图下半部分露出来）
    private func batchCardFrame(for win: NSWindow) -> NSRect {
        let width: CGFloat = 560
        var contentH: CGFloat = 300
        if batchCardContentHeight > 60 { contentH = batchCardContentHeight.rounded(.up) }
        else if let fit = win.contentView?.fittingSize.height, fit > 120, fit < 600 { contentH = fit + 12 }   // 还没换成卡片内容时（表格 ≥ 680）先用默认值，稍后校正
        // 标题栏高度按 contentLayoutRect 算：SwiftUI 的窗口是 fullSizeContentView，frameRect(forContentRect:) 不含标题栏
        // （2026-10-27 第一次按它算，卡片底行被裁掉 28 pt）
        let titleBar = max(0, win.frame.height - win.contentLayoutRect.height)
        let size = NSSize(width: width, height: min(560, max(160, contentH + titleBar)))
        let main = mainWindow ?? NSApp.windows.first { $0 !== win && $0.isVisible && $0.frame.width >= 700 }
        var origin = NSPoint(x: win.frame.minX, y: win.frame.maxY - size.height)
        if let main { origin = NSPoint(x: main.frame.midX - size.width / 2, y: main.frame.maxY - 40 - size.height) }
        return NSRect(origin: origin, size: size)
    }
    /// 折叠：记住进入前的框，**不论当前窗口多大**都缩成小卡片停到约定位置；展开（「展开列表」、批次重跑、关窗）：放回原框。
    /// SwiftUI 在内容尺寸变化后会自己再排一次窗口框（还可能按旧内容的最小尺寸撑大），所以之后再校正几次尺寸和位置
    func dockBatchWindow() {
        guard let win = NSApp.window(scene: SceneID.batchFill), win.isVisible else { lastDockInfo = "dock: no batch window"; return }
        pinBatchWindow(win)
        if batchCompact {
            // 卡片只在有选中项、分类/预览阶段才显示；否则窗口里仍是完整表格（最小 820×680），缩了也会被 SwiftUI 撑回去
            guard let st = batch, st.selectedID != nil, st.phase == .classify || st.phase == .preview else { lastDockInfo = "dock: no card to show"; return }
            if batchSavedFrame == nil { batchSavedFrame = win.frame }
            applyBatchCard(win)
            for delay in [0.15, 0.4, 0.9] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak win] in
                    guard let self, let win, self.batchCompact, win.isVisible else { return }
                    self.applyBatchCard(win)
                }
            }
        } else if let f = batchSavedFrame {
            lastDockInfo = "dock expand \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
            batchSavedFrame = nil
            batchPinTopLeft = nil
            batchCardTarget = nil
            win.setFrame(f, display: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak win] in
                guard let self, !self.batchCompact else { return }
                win?.setFrame(f, display: true)
            }
        }
    }
    private func applyBatchCard(_ win: NSWindow) {
        // 同一次折叠里左上角保持第一次算出的位置，后续校正只按卡片内容调高度（不让卡片上下跳）
        var target = batchCardFrame(for: win)
        if let tl = batchPinTopLeft, let old = batchCardTarget, abs(tl.x - old.minX) < 1, abs(tl.y - old.maxY) < 1 {
            target.origin = NSPoint(x: tl.x, y: tl.y - target.height)
        }
        lastDockInfo = "dock compact main=\(mainWindow?.title ?? "nil") target=\(Int(target.minX)),\(Int(target.minY)) \(Int(target.width))x\(Int(target.height))"
        batchPinTopLeft = NSPoint(x: target.minX, y: target.maxY)
        batchCardTarget = target
        if abs(win.frame.width - target.width) > 2 || abs(win.frame.height - target.height) > 2
            || abs(win.frame.minX - target.minX) > 2 || abs(win.frame.maxY - target.maxY) > 2 {
            win.setFrame(target, display: true)
        }
    }
    /// 主窗口里各浮层的位置（root 坐标，y 向下）：飞到断档时避开它们。不发布：每次布局都会写，发布会让整个视图树重绘、打断拖动
    var uiPanelFrames: [CGRect] = []
    /// 地图所在的主窗口（批量窗口折叠成卡片时要贴着它放）
    weak var mainWindow: NSWindow?
    @Published private(set) var batchResolving = false
    /// 地图判断进度：已判 / 总数（界面进度条）
    @Published private(set) var batchResolveProgress: (done: Int, total: Int)? = nil
    private var batchRunTask: Task<Void, Never>?
    private var batchResolveTask: Task<Void, Never>?
    private var batchGeneration = 0                          // 每次开始/取消/关闭/换轨迹递增；旧任务回写一律作废
    private let overpassCache = OverpassCache()
    /// 路网结果缓存（按打开的文件；换文件时 load/loadFwdb/clearTrack 清空，批量取消/关窗/落地/撤销/还原都不清）。
    /// 批量 worker 与单处请求都先查它：同一处断档同样输入第二次不再请求；「重新获取」用 ignoreCache 绕过并覆盖
    let routeCache = RouteCache()
    /// 第 3 步里单处「重新获取这一处」的在途任务（按项 id）；取消/关窗/重跑整批时一并取消
    private var batchRefetchTasks: [GapID: Task<Void, Never>] = [:]
    /// 进入批量时暂存的手工草稿（放弃批量时恢复，不丢用户已经画的东西）
    private var batchSavedDraft: (candidate: GapCandidate?, a: Int?, b: Int?, coords: [CLLocationCoordinate2D], sources: [Int?],
                                  history: [(coords: [CLLocationCoordinate2D], sources: [Int?], a: Int?, b: Int?, route: FillRouteInfo?)],
                                  route: FillRouteInfo?, trackID: UUID)?
    var batchActive: Bool { batch != nil }

    /// 轨迹换代/撤销落地/单处落地之后：批次里的候选下标全部失效，整个作废
    private func invalidateBatch() {
        guard batch != nil || batchResolving || batchRunTask != nil || batchResolveTask != nil || !batchRefetchTasks.isEmpty else { return }
        batchGeneration &+= 1
        batchRunTask?.cancel(); batchRunTask = nil
        cancelBatchRefetches()
        batchResolveTask?.cancel(); batchResolveTask = nil
        batchResolving = false
        batch = nil
        batchSavedDraft = nil
        if reviewPreview { reviewPreview = false; reviewSelect(nil) }
        previewChangesCache = nil
    }

    /// 进入批量：按当前候选建表并自动分类；当前手工草稿先存起来
    func startBatchPlanning() {
        guard fillMode, let track, !filteredGapCandidates.isEmpty, !isLoading, batch == nil, !candidatesRefreshing,
              fillPrompt == nil, fillSimilarPrompt == nil else { return }
        noteUserActivity()
        if fillActive {
            batchSavedDraft = (fillCandidate, fillAnchorA, fillAnchorB, fillVertices, fillVertexSources, fillVertexHistory, fillRouteInfo, track.id)
        }
        batchGeneration &+= 1
        var st = BatchState()
        st.trackID = track.id
        st.generation = batchGeneration
        st.items = filteredGapCandidates.map { c in
            let auto = classify(c)        // 先按行程（长停切分 + v95），行程不确定时按单处速度规则
            // 自动判断不了的默认跳过（用户要求）：不挡「开始」，可逐行改、让地图判断或一键全按公路/铁路；
            // 「只补公路」时疑似铁路也跳过（火车段用户自己从 gpx.studio 导）
            let kind = plannedKind(auto, for: c)
            var item = BatchItem(candidate: c, kind: kind, autoKind: auto, sampling: gapSampling[c.id])
            item.tripIndex = trip(for: c)?.index ?? -1
            return item
        }
        for it in st.items where it.tripIndex >= 0 { st.itemsPerTrip[it.tripIndex, default: 0] += 1 }
        if UITestHook.autoTripMap { resolveTripsByMap() }   // 还没用地图判过的行程：进入批量就自动查（每段 ≤6 个点，串行限速）；离线测试可用钩子关掉
        batch = st
        resetFillDraft()
    }

    func setBatchKind(_ id: GapID, _ kind: BatchKind) {
        guard var st = batch, st.phase == .classify, let i = st.items.firstIndex(where: { $0.id == id }) else { return }
        st.items[i].kind = kind
        st.items[i].userSet = true
        batch = st
    }

    /// 把自动判断不了、用户也没改过的一次设为某类
    func setBatchUncertain(_ kind: BatchKind) {
        guard var st = batch, st.phase == .classify else { return }
        for i in st.items.indices where st.items[i].autoKind == nil && !st.items[i].userSet { st.items[i].kind = kind }
        batch = st
    }

    func setBatchAll(_ kind: BatchKind) {
        guard var st = batch, st.phase == .classify else { return }
        for i in st.items.indices { st.items[i].kind = kind }
        batch = st
    }

    /// 让地图判断没选的：两端离最近可行驶道路的距离（OSRM nearest，每处 2 个请求）。用户先选了的不覆盖
    func resolveBatchUncertainByMap() {
        guard let st = batch, st.phase == .classify, !batchResolving else { return }
        let pending = st.items.filter { $0.autoKind == nil && !$0.userSet }
        guard !pending.isEmpty else { return }
        batchResolving = true
        batchResolveProgress = (0, pending.count)
        let gen = batchGeneration
        let token = publicationClock.begin(.batchResolve, fileIDs: files.map(\.id), sourceID: track?.id)
        batchResolveTask = Task { [weak self] in
            var consecutiveNoAnswer = 0
            for (n, item) in pending.enumerated() {
                if Task.isCancelled || consecutiveNoAnswer >= 3 { break }   // 服务连不上：别一路空转
                let c = item.candidate
                await MainActor.run { [weak self] in
                    guard let self, self.owns(token), self.batchGeneration == gen, var st = self.batch else { return }
                    let placeNo = n + 1, total = pending.count
                    let timeText = Self.batchTimeText(c.tA), meters = Int(c.meters)
                    st.progressText = String(localized: "地图判断 第 \(placeNo)/\(total) 处 · \(timeText) · \(meters) m（查两端离最近公路、最近铁路的距离：OSRM 2 次 + Overpass 2 次）", comment: "Batch Gap Fill progress of the map check; 1st %lld = current gap number, 2nd %lld = total gaps, %@ = gap time (MM-dd HH:mm), last %lld = gap length in metres")
                    self.batch = st
                    self.batchResolveProgress = (n, pending.count)
                }
                let A = CLLocationCoordinate2D(latitude: c.latA, longitude: c.lonA), B = CLLocationCoordinate2D(latitude: c.latB, longitude: c.lonB)
                let dA = await RoadNetwork.nearestRoadDistance(A)
                let dB = dA == nil ? nil : await RoadNetwork.nearestRoadDistance(B)
                consecutiveNoAnswer = (dA == nil) ? consecutiveNoAnswer + 1 : 0
                let rA = dA == nil ? nil : await RoadNetwork.nearestRailDistance(A)
                let rB = rA == nil ? nil : await RoadNetwork.nearestRailDistance(B)
                guard let self, !Task.isCancelled else { return }
                let verdict = BatchClassifier.classifyByMap(roadA: dA, roadB: dB, railA: rA, railB: rB, kmh: c.kmh)
                let note = BatchClassifier.mapReason(roadA: dA, roadB: dB, railA: rA, railB: rB, verdict: verdict)
                await MainActor.run {
                    guard self.owns(token), self.batchGeneration == gen, var st = self.batch, st.phase == .classify,
                          let i = st.items.firstIndex(where: { $0.id == item.id }), !st.items[i].userSet else { return }
                    st.items[i].mapNote = note
                    if let v = verdict { st.items[i].kind = self.plannedKind(v, for: st.items[i].candidate) }
                    st.requestsMade = RoadNetwork.RateLimiter.shared.countSnapshot
                    self.batch = st
                    self.batchResolveProgress = (n + 1, pending.count)
                }
            }
            guard let self else { return }
            await MainActor.run {
                guard self.owns(token), self.batchGeneration == gen else { return }
                self.batchResolving = false
                self.batchResolveProgress = nil
                self.batchResolveTask = nil
                if var st = self.batch { st.progressText = ""; self.batch = st }
            }
        }
    }

    func cancelBatchResolve() {
        publicationClock.cancel(.batchResolve)
        batchResolveTask?.cancel()
        batchResolveTask = nil
        batchResolving = false
        batchResolveProgress = nil
        if var st = batch { st.progressText = ""; batch = st }
    }

    /// 顺序取草稿：公路走 OSRM（上下文优先、省请求），铁路走 Overpass（包围盒缓存）；全局限速；可取消。
    /// ignoreCache：「重新获取全部」——不看路网缓存，每处都重新请求（结果覆盖缓存）
    func runBatch(ignoreCache: Bool = false) {
        guard var st = batch, st.phase == .classify, st.uncertainUnresolved == 0, st.workCount > 0, !batchResolving,
              let track, track.id == st.trackID else { return }
        noteUserActivity()
        batchGeneration &+= 1
        cancelBatchRefetches()
        let gen = batchGeneration
        let token = publicationClock.begin(.batchRouting, fileIDs: files.map(\.id), sourceID: track.id)
        st.generation = gen
        st.phase = .running
        st.startedAt = Date()
        st.requestsMade = 0
        st.requestsByHost = [:]
        st.cacheHits = 0
        st.engineDisabled = nil
        RoadNetwork.RateLimiter.shared.resetCount()
        for i in st.items.indices {
            st.items[i].status = (st.items[i].kind == nil || st.items[i].kind == .skip) ? .skipped : .pending
            st.items[i].draft = nil
            st.items[i].crossDrafts = []
            st.items[i].cross = nil
            st.items[i].userPicked = false
            st.items[i].include = false
        }
        batch = st
        let items = st.items
        let roadOnly = fillRoadOnly
        let crossCheck = fillCrossCheck
        let work = items.enumerated().map { ($0.offset, $0.element) }.filter { $0.1.kind != nil && $0.1.kind != .skip }
        let cache = overpassCache
        let rcache = routeCache
        // 普通模式两路分活：OSRM 一路、Valhalla 一路（FOSSGIS 的两台机器），各自仍是"一个客户端、1 秒 1 次"；
        // 共用一个队列，谁空闲谁取下一处。铁路（Overpass）哪一路取到都行。
        // 精确模式：每处公路同时发两路再比对几何；仍开两个 worker（RateLimiter 保证每台主机同一时刻只有一个在途请求、≥1.05 s），
        // 吞吐约为普通模式一半。某一路连续 3 处连不上（或一次 429）就停用它，剩下的只走另一路、标为「没比对」；
        // 两路都停用时公路项不再发出（收尾标失败），铁路项照常
        let engines: [RoadNetwork.RouteEngine] = [.osrm, .valhalla]
        let coord = BatchCoordinator(work: work, engines: engines, roadOnly: roadOnly)
        batchRunTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for engine in engines {
                    group.addTask { [weak self] in
                        // 普通模式：worker 绑引擎，take(worker:) 只给它自己引擎还活着时才能做的项（铁路/本地只删点不需要引擎，谁都能做）；
                        // 精确模式：worker 不绑引擎，每处用此刻还活着的全部引擎
                        while let (ordinal, activeEngines) = await coord.take(worker: crossCheck ? nil : engine) {
                            if Task.isCancelled { break }
                            guard let self else { return }
                            let (i, item) = work[ordinal]
                            let c = item.candidate
                            await MainActor.run {
                                guard self.owns(token), self.batchGeneration == gen, var st = self.batch, st.items.indices.contains(i), st.items[i].id == item.id else { return }
                                st.currentIndex = i
                                st.items[i].status = .running
                                st.progressText = Self.batchProgressText(st, work: work.count, current: item, crossCheck: crossCheck)
                                self.batch = st
                            }
                            let legEngines = crossCheck ? activeEngines : [engine]
                            guard let out = await self.routeBatchItem(item, trackID: track.id, engines: legEngines, crossCheck: crossCheck,
                                                                        roadOnly: roadOnly, cache: cache, routeCache: rcache, ignoreCache: ignoreCache,
                                                                        coord: coord) else { break }   // 取消
                            if Task.isCancelled { break }
                            let downNow = await coord.downEngines
                            await self.applyBatchOutcome(out, index: i, item: item, gen: gen, owner: token, crossCheck: crossCheck, engines: engines, downNow: downNow)
                        }
                    }
                }
            }
            guard let self else { return }
            let unstarted = await coord.remaining()
            await MainActor.run {
                guard self.owns(token), self.batchGeneration == gen, var st = self.batch else { return }
                let cancelled = String(localized: "已取消", comment: "Batch Gap Fill row status (after “failed:”): the request was cancelled")
                for i in st.items.indices where st.items[i].status == .running { st.items[i].status = .failed(cancelled) }
                if !Task.isCancelled, !unstarted.isEmpty {
                    let stopped = String(localized: "服务连不上，已停止", comment: "Batch Gap Fill row status (after “failed:”): not attempted because the routing services were unreachable and the batch stopped")
                    for ordinal in unstarted { let (i, _) = work[ordinal]; if st.items[i].status == .pending { st.items[i].status = .failed(stopped) } }
                    st.progressText = String(localized: "两路都连续连不上路网服务，已停止（可能被公共服务暂时限流，几分钟后再试）", comment: "Batch Gap Fill progress line: both routing services (OSRM and Valhalla) failed repeatedly, the batch stopped (maybe rate-limited; retry in a few minutes)")
                } else { st.progressText = "" }
                st.currentIndex = nil
                st.phase = .preview
                st.requestsMade = RoadNetwork.RateLimiter.shared.countSnapshot
                st.requestsByHost = RoadNetwork.RateLimiter.shared.perHostSnapshot
                self.batch = st
                self.batchRunTask = nil
                self.fillVersion &+= 1
            }
        }
    }

    /// 一处取路结果回写到批次（runBatch 的 worker 与「重新获取这一处」共用）：世代号不对或项已换就丢弃
    private func applyBatchOutcome(_ out: BatchOutcome, index i: Int, item: BatchItem, gen: Int, owner token: DataPublicationToken, crossCheck: Bool,
                                   engines: [RoadNetwork.RouteEngine], downNow: [RoadNetwork.RouteEngine]) {
        guard owns(token), batchGeneration == gen, var st = batch, st.items.indices.contains(i), st.items[i].id == item.id else { return }
        let c = item.candidate
        st.requestsMade = RoadNetwork.RateLimiter.shared.countSnapshot
        st.requestsByHost = RoadNetwork.RateLimiter.shared.perHostSnapshot
        if out.cached { st.cacheHits += 1 }
        st.items[i].cached = out.cached
        st.items[i].crossDrafts = out.crossDrafts
        st.items[i].cross = out.cross
        switch out.kind {
        case .skipped:
            st.items[i].status = .pending            // 轨迹换代：世代号校验会把整批作废
        case .draft(let d):
            var d = d
            st.items[i].draft = d
            st.items[i].status = .done
            st.items[i].include = true
            st.items[i].computeBBox()
            // 落地前自检：high 默认不勾选（用户看过地图可手动勾回）
            if let track, let p = assessBatchItem(st.items[i], draft: d, track: track) {
                st.items[i].plausibility = p
                d.notes.insert(p.summaryLine, at: 0)
                if p.level == .high { st.items[i].include = false; d.notes.insert(FillPlausibility.highNote, at: 1) }
                st.items[i].draft = d
            } else { st.items[i].plausibility = nil }
        case .conflict(let kind):
            st.items[i].draft = nil
            st.items[i].status = .conflict(kind)
            st.items[i].include = false              // 待选：用户选了才落地
            st.items[i].computeBBox()
            // 待选项按 OSRM 份（或唯一那份）评估，只做展示
            if let track, let first = out.crossDrafts.first { st.items[i].plausibility = assessBatchItem(st.items[i], draft: first, track: track) }
        case .failed(let e):
            let why = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
            st.items[i].status = ((e as? RouteError)?.isRailSkip ?? false) ? .notTunnel(why) : .failed(why)
            if item.kind == .rail, !((e as? RouteError)?.isRailSkip ?? false) { st.items[i].useStraight = false }
            st.items[i].include = false
            if c.kind == .jitter, !Self.isTransportFailure(e) {
                // 乱跳簇被路网/隧道判定拒绝（不是网络问题）：默认仍落地——只删区间内的乱跳点，不插点（可逐行关掉）
                st.items[i].deleteOnly = true
                st.items[i].include = true
            }
        }
        if crossCheck, !downNow.isEmpty {
            // 每次按当前停用集合重算（第二路后来也停用时提示要跟着变）
            let down = downNow.map(RoadNetwork.name).joined(separator: Fmt.listSeparator)
            let remaining = engines.filter { !downNow.contains($0) }.map(RoadNetwork.name).joined(separator: Fmt.listSeparator)
            st.engineDisabled = downNow.count == engines.count
                ? String(localized: "两路路网服务都连续连不上，已停用：剩下的公路断档不再请求", comment: "Batch Gap Fill (precise mode) notice: both routing services were disabled after repeated connection failures")
                : String(localized: "\(down) 连续连不上，已停用；后面只用 \(remaining)，结果标为「没比对」", comment: "Batch Gap Fill (precise mode) notice: one routing service was disabled after repeated connection failures. Placeholders: disabled router name(s), remaining router name(s). Keep router names untranslated")
        }
        batch = st
        fillVersion &+= 1                      // 覆盖层立刻画出这一处
    }

    /// 「重新获取全部…」（第 2/3 步）：忽略路网缓存，整个第 2 步重跑（等同于回到第 1 步按「开始」；勾选/手选随之重置）
    func refetchBatchAll() {
        guard var st = batch, st.phase == .preview || st.phase == .running else { return }
        if st.phase == .running { cancelBatch(); guard let now = batch else { return }; st = now }
        cancelBatchRefetches()
        st.phase = .classify
        st.selectedID = nil
        batch = st
        runBatch(ignoreCache: true)
    }

    /// 「重新获取这一处」（第 3 步）：只重取这一项（忽略缓存，结果覆盖缓存），其它项的状态、勾选、手选都不动。
    /// 这一项回到「请求中」，旧草稿/两路/手选清掉；普通模式沿用它原来的引擎（没有就 OSRM），精确模式两路都取
    /// 「重新比对这一处（两路重取）」：只对「只有一路结果」（unverified、没选「都不补」）的项，忽略缓存两路都重取，
    /// 不管当前「精确模式」开没开（这一处本来就是精确模式取的）。走 refetchBatchItem 的同一路径。返回是否真的开始了
    @discardableResult
    func recrossBatchItem(_ id: GapID) -> Bool {
        guard let st = batch, st.phase == .preview, let it = st.items.first(where: { $0.id == id }),
              it.status.isUnverified, !it.declined else { return false }
        return refetchBatchItem(id, forceCross: true)
    }

    /// 「全部重新比对 N 处」：所有 unverified 项逐个 recrossBatchItem（各自一个任务；限流由 RateLimiter 管）。返回开始了几处
    @discardableResult
    func recrossUnverifiedAll() -> Int {
        guard let st = batch, st.phase == .preview else { return 0 }
        let ids = st.items.filter { $0.status.isUnverified && !$0.declined }.map(\.id)
        return ids.reduce(0) { $0 + (recrossBatchItem($1) ? 1 : 0) }
    }

    @discardableResult
    func refetchBatchItem(_ id: GapID, forceCross: Bool = false) -> Bool {
        guard var st = batch, st.phase == .preview, let i = st.items.firstIndex(where: { $0.id == id }),
              let track, track.id == st.trackID, batchRefetchTasks[id] == nil,
              let kind = st.items[i].kind, kind != .skip else { return false }
        noteUserActivity()
        let gen = batchGeneration
        let token = publicationClock.begin(.batchRefetch(id), fileIDs: files.map(\.id), sourceID: track.id)
        let prevSource = st.items[i].draft?.source ?? st.items[i].crossDrafts.first?.source
        if st.items[i].cached { st.cacheHits = max(0, st.cacheHits - 1); st.items[i].cached = false }   // 原来算命中的，重取后不再是
        st.items[i].refetchCount += 1
        st.items[i].status = .running
        st.items[i].draft = nil
        st.items[i].crossDrafts = []
        st.items[i].cross = nil
        st.items[i].userPicked = false
        st.items[i].declined = false
        st.items[i].useStraight = false
        st.items[i].include = false
        st.currentIndex = i
        batch = st
        fillVersion &+= 1
        let item = st.items[i]
        let crossCheck = fillCrossCheck || forceCross, roadOnly = fillRoadOnly
        let engines: [RoadNetwork.RouteEngine] = crossCheck ? [.osrm, .valhalla] : [prevSource == .valhallaCar ? .valhalla : .osrm]
        let cache = overpassCache, rcache = routeCache
        let coord = BatchCoordinator(work: [(i, item)], engines: engines, roadOnly: roadOnly)
        batchRefetchTasks[id] = Task { [weak self] in
            guard let self else { return }
            let out = await self.routeBatchItem(item, trackID: track.id, engines: engines, crossCheck: crossCheck,
                                                roadOnly: roadOnly, cache: cache, routeCache: rcache, ignoreCache: true, coord: coord)
            await MainActor.run {
                guard self.owns(token), self.batchGeneration == gen, var st = self.batch, st.items.indices.contains(i), st.items[i].id == item.id else { return }
                self.batchRefetchTasks[id] = nil
                if let out, !Task.isCancelled {
                    self.applyBatchOutcome(out, index: i, item: item, gen: gen, owner: token, crossCheck: crossCheck, engines: engines, downNow: [])
                    guard var st2 = self.batch else { return }
                    if st2.currentIndex == i { st2.currentIndex = nil }
                    self.batch = st2
                } else {
                    // 取消：这一处标失败（和整批取消同一口径），不碰别的项
                    st.items[i].status = .failed(String(localized: "已取消", comment: "Batch Gap Fill row status (after “failed:”): the request was cancelled"))
                    if st.currentIndex == i { st.currentIndex = nil }
                    self.batch = st
                    self.fillVersion &+= 1
                }
            }
        }
        return true
    }

    private func cancelBatchRefetches() {
        for (id, t) in batchRefetchTasks { publicationClock.cancel(.batchRefetch(id)); t.cancel() }
        batchRefetchTasks = [:]
    }

    /// 第 2 步进度文字：普通模式 / 精确模式（精确模式附实时的一致 / 不一致 / 没比对 计数）；命中过缓存时附「命中缓存 N 处」
    private static func batchProgressText(_ st: BatchState, work total: Int, current item: BatchItem, crossCheck: Bool) -> String {
        let doneN = st.items.filter { $0.status.isFinished }.count
        let kindName = item.kind?.label ?? ""
        let timeText = batchTimeText(item.candidate.tA), meters = Int(item.candidate.meters)
        var text: String
        if crossCheck {
            let agree = st.agreeCount, disagree = st.disagreeCount, unverified = st.unverifiedCount
            text = String(localized: "已完成 \(doneN)/\(total) · 精确模式（OSRM + Valhalla 交叉验证）· 一致 \(agree) · 不一致 \(disagree) · 没比对 \(unverified) · 正在取 \(kindName) · \(timeText) · \(meters) m", comment: "Batch Gap Fill progress in precise mode. Placeholders in order: finished gaps; total gaps; gaps where both routers agree; gaps where they disagree; gaps with only one result; category being fetched (Road / Rail, may be empty); gap time (MM-dd HH:mm); gap length in metres. Keep OSRM and Valhalla untranslated")
        } else {
            text = String(localized: "已完成 \(doneN)/\(total) · 两路并行（OSRM + Valhalla）· 正在取 \(kindName) · \(timeText) · \(meters) m", comment: "Batch Gap Fill progress; 1st %lld = finished gaps, 2nd %lld = total gaps, 1st %@ = category being fetched (Road / Rail, may be empty), 2nd %@ = gap time (MM-dd HH:mm), last %lld = gap length in metres")
        }
        if st.cacheHits > 0 { text += " · " + cacheHitsText(st.cacheHits) }
        return text
    }
    /// 「命中缓存 N 处」（进度文字 / 第 3 步统计共用）
    static func cacheHitsText(_ n: Int) -> String {
        String(localized: "命中缓存 \(n) 处", comment: "Batch Gap Fill progress / summary clause: %lld gaps were answered from the in-memory road-network cache without a new request")
    }

    /// 预计用时（秒）：每台主机 1 秒 1 次，公路每处约 1.3 s / 腿，铁路（Overpass）约 2.5 s；普通模式两路分活，精确模式两路都取
    func batchEstimateSeconds(crossCheck: Bool) -> Double {
        guard let st = batch else { return 0 }
        let road = Double(st.items.filter { $0.kind == .road }.count), rail = Double(st.items.filter { $0.kind == .rail }.count)
        return crossCheck ? road * 1.3 + rail * 2.5 / 2 : (road * 1.3 + rail * 2.5) / 2
    }

    /// 批量队列 + 引擎健康，一个 actor：发活与"该引擎还活着吗"的判断原子。
    /// take() 给出下一处与此刻还没停用的引擎快照；两路都停用时公路项直接记为 stopped（收尾标失败），铁路照常发出。
    /// 停用是粘滞的：同一次运行里迟到的成功不能让它恢复（FOSSGIS 的屏蔽几分钟才解除，别再刺激它）
    actor BatchCoordinator {
        enum Leg { case success, noRoute, transport, cancelled }
        private var pending: [Int]                       // 还没发出的 work 序号（按原顺序）
        private let work: [(Int, BatchItem)]
        private let engines: [RoadNetwork.RouteEngine]
        private let roadOnly: Bool
        private var fails: [RoadNetwork.RouteEngine: Int] = [:]
        private var down: Set<RoadNetwork.RouteEngine> = []
        private var stopped: [Int] = []
        init(work: [(Int, BatchItem)], engines: [RoadNetwork.RouteEngine], roadOnly: Bool) {
            self.work = work; self.engines = engines; self.roadOnly = roadOnly; pending = Array(work.indices)
        }
        var active: [RoadNetwork.RouteEngine] { engines.filter { !down.contains($0) } }
        var allDown: Bool { active.isEmpty }
        var downEngines: [RoadNetwork.RouteEngine] { engines.filter { down.contains($0) } }
        func isDown(_ e: RoadNetwork.RouteEngine) -> Bool { down.contains(e) }
        /// 这一项要不要公路引擎：公路且不是本地只删点的乱跳簇（铁路走 Overpass，本地判定不发请求）
        private func needsRoadEngine(_ o: Int) -> Bool {
            let it = work[o].1
            return it.kind == .road && !TrackStore.localDeleteOnly(it.candidate, kind: it.kind, roadOnly: roadOnly)
        }
        /// 发活（原子）：worker = nil（精确模式）给第一项还没发的；worker = 某引擎（普通模式）给它能做的第一项——
        /// 需要公路引擎的项只在该引擎活着时给它，否则留给另一路；两路都停用时需要引擎的项直接记 stopped，其余照常
        func take(worker: RoadNetwork.RouteEngine?) -> (ordinal: Int, engines: [RoadNetwork.RouteEngine])? {
            if allDown {
                let (stop, keep) = pending.reduce(into: ([Int](), [Int]())) { acc, o in needsRoadEngine(o) ? acc.0.append(o) : acc.1.append(o) }
                stopped += stop; pending = keep
            }
            for (idx, o) in pending.enumerated() {
                if let w = worker, needsRoadEngine(o), down.contains(w) { continue }   // 普通模式：我的引擎停了，留给另一路
                pending.remove(at: idx)
                return (o, active)
            }
            return nil
        }
        /// hard = 一次就停用（429 冷却中）；否则连续 3 次传输失败停用。回答过（成功 / 没路）就算活着，计数清零
        func record(_ e: RoadNetwork.RouteEngine, _ leg: Leg, hard: Bool = false) {
            switch leg {
            case .transport: fails[e, default: 0] += hard ? 3 : 1; if fails[e, default: 0] >= 3 { down.insert(e) }
            case .success, .noRoute: fails[e] = 0
            case .cancelled: break
            }
        }
        func remaining() -> [Int] { pending + stopped }
    }

    /// 乱跳簇在批量里不发请求、只删区间内乱跳点的本地判定：两锚点太近 / 隐含速度不合理 / 「只补公路」下的铁路乱跳
    nonisolated static func localDeleteOnly(_ c: GapCandidate, kind: BatchKind?, roadOnly: Bool) -> Bool {
        let opt = GapDetector.Options()
        return c.kind == .jitter && (c.meters < opt.minMeters || c.kmh > opt.maxKmh || (kind == .rail && roadOnly))
    }

    /// 精确模式里两路都失败时的合并错误（文字整句本地化；不是 RouteError，所以乱跳簇不会按"路网判定拒绝"默认只删点）
    struct BothEnginesFailed: LocalizedError {
        let osrm: String, valhalla: String
        var errorDescription: String? { String(localized: "两路都没有取到路径。OSRM：\(osrm)；Valhalla：\(valhalla)", comment: "Error alert (single-gap cross-check): both routers failed. Placeholders: OSRM's reason, Valhalla's reason. Keep router names untranslated") }
    }

    /// 一条腿（一个引擎对一处）的结果分类：取消只认 Task.isCancelled；没路 / 太远是"引擎回答了"；其余算传输失败
    enum LegOutcome {
        case draft(RouteDraft), noRoute(Error), transport(Error), cancelled
        var draft: RouteDraft? { if case .draft(let d) = self { return d }; return nil }
        var error: Error? { switch self { case .noRoute(let e), .transport(let e): return e; default: return nil } }
        var legKind: BatchCoordinator.Leg { switch self { case .draft: return .success; case .noRoute: return .noRoute; case .transport: return .transport; case .cancelled: return .cancelled } }
        static func classify(_ error: Error) -> LegOutcome {
            if Task.isCancelled { return .cancelled }
            if let r = error as? RouteError { switch r { case .noRoute, .tooFar: return .noRoute(error); default: return .transport(error) } }
            return .transport(error)
        }
    }

    /// 一处断档的取路结果（批量 worker 用）
    struct BatchOutcome {
        enum Kind { case skipped, draft(RouteDraft), conflict(BatchStatus.ConflictKind), failed(Error) }   // skipped = 轨迹换代，这一处无意义
        var kind: Kind
        var crossDrafts: [RouteDraft] = []
        var cross: RouteCrossCheck.Result? = nil
        /// 这一处用到的每一路结果都来自路网缓存（没发请求）
        var cached: Bool = false
    }

    /// 取一处断档的路网草稿。engines = 这处要用的引擎（普通模式 1 个；精确模式 = 此刻还没停用的）。
    /// 先查路网缓存（ignoreCache 时跳过）；命中的腿不计入引擎健康（没真问过服务器）。返回 nil = 被取消（worker 应退出）
    nonisolated private func routeBatchItem(_ item: BatchItem, trackID: UUID, engines: [RoadNetwork.RouteEngine], crossCheck: Bool,
                                            roadOnly: Bool, cache: OverpassCache, routeCache: RouteCache, ignoreCache: Bool,
                                            coord: BatchCoordinator) async -> BatchOutcome? {
        let c = item.candidate
        let A = CLLocationCoordinate2D(latitude: c.latA, longitude: c.lonA)
        let B = CLLocationCoordinate2D(latitude: c.latB, longitude: c.lonB)
        let opt = GapDetector.Options()
        if Self.localDeleteOnly(c, kind: item.kind, roadOnly: roadOnly) {
            // 乱跳簇两锚点太近 / 隐含速度不合理 / 「只补公路」下的铁路乱跳：不取路径，只删区间内的乱跳点（本地判定，不发请求）
            let why: String
            let inner = c.innerCount
            if c.meters < opt.minMeters {
                let meters = Int(c.meters)
                why = String(localized: "两锚点只相距 \(meters) m，插不出路径：只删区间内 \(inner) 个乱跳点", comment: "Batch Gap Fill note (Delete Only draft); first %lld = anchor distance in metres, second %lld = number of jitter points removed")
            } else if c.kmh > opt.maxKmh {
                let kmh = Int(c.kmh)
                why = String(localized: "两锚点之间隐含 \(kmh) km/h，锚点本身不可信：不取路径，只删区间内 \(inner) 个乱跳点（沿 A→B 单调推进的那一路保留）", comment: "Batch Gap Fill note (Delete Only draft); first %lld = implied speed in km/h between the anchors, second %lld = number of jitter points removed")
            } else {
                why = String(localized: "「只补公路」：铁路上的乱跳段不取路径，只删区间内 \(inner) 个乱跳点（沿 A→B 单调推进的那一路保留）", comment: "Batch Gap Fill note (Delete Only draft); the bracketed term is the batch's Road Only option; %lld = number of jitter points removed")
            }
            let local = String(localized: "本地", comment: "Route draft server/endpoint: computed locally, no network request")
            return BatchOutcome(kind: .draft(RouteDraft(source: .deleteOnly, coords: [], meters: 0, snapA: 0, snapB: 0, endpoint: local,
                                                        warnings: [], notes: [why], method: .deleteOnly)))
        }
        // 轨迹换代（落地/撤销/换文件）时输入无意义：这一处跳过，世代号校验会把整批作废
        let built = await MainActor.run { () -> (GapRouteInputs.Inputs, [String])? in
            guard let t = self.track, t.id == trackID else { return nil }
            let inp = GapRouteInputs.build(t, ia: c.indexA, ib: c.indexB, profile: self.profile(at: c.indexA))
            return (inp, GapRouteInputs.candidateNotes(c) + GapRouteInputs.notes(inp, profile: self.profile(at: c.indexA)))
        }
        guard let (inp, inputNotes) = built, inp.valid else { return BatchOutcome(kind: .skipped) }
        switch item.kind {
        case .road:
            guard !engines.isEmpty else {
                return BatchOutcome(kind: .failed(RouteError.allEndpointsFailed([String(localized: "两路路网服务都已停用（连续连不上）", comment: "Route error entry in precise mode: both routing services were disabled after repeated connection failures")])))
            }
            let leftHand = await TrafficSide.leftHand(at: CLLocationCoordinate2D(latitude: (c.latA + c.latB) / 2, longitude: (c.lonA + c.lonB) / 2))
            /// 一路引擎（economy；精确模式 failFast：传输失败/429 立刻放弃这一腿，别对已限流的主机连发候选）；先查缓存
            @Sendable func leg(_ e: RoadNetwork.RouteEngine) async -> (outcome: LegOutcome, cached: Bool) {
                let key = RouteCacheKey(source: e == .osrm ? .osrmCar : .valhallaCar, economy: true, ia: c.indexA, ib: c.indexB, a: A, b: B,
                                        seconds: c.seconds, inputs: inp, leftHand: leftHand)
                let (r, cached) = await Self.cachedRoute(routeCache, key: key, ignoreCache: ignoreCache) {
                    try await RoadNetwork.carRoute(a: A, b: B, bearingA: inp.a.heading.bearing, bearingB: inp.b.heading.bearing,
                                                   contextA: inp.a.context.anchor, contextB: inp.b.context.anchor, trace: inp.trace,
                                                   matchRadius: inp.radius, seconds: c.seconds,
                                                   portalA: inp.portalA, portalB: inp.portalB,
                                                   farContextA: inp.farContextA, farContextB: inp.farContextB,
                                                   portalFarA: inp.portalFarA, portalFarB: inp.portalFarB,
                                                   leftHandTraffic: leftHand,
                                                   economy: true, engine: e, failFast: crossCheck)
                }
                switch r {
                case .success(var d):
                    d.notes = (cached ? [RouteCache.hitNote] : []) + inputNotes + d.notes
                    return (.draft(d), cached)
                case .failure(let error):
                    return (LegOutcome.classify(error), cached)
                }
            }
            var legs: [RoadNetwork.RouteEngine: LegOutcome] = [:]
            var cachedLegs: Set<RoadNetwork.RouteEngine> = []
            if engines.count >= 2 {
                async let r0 = leg(engines[0])
                async let r1 = leg(engines[1])
                let (a0, a1) = await (r0, r1)
                legs[engines[0]] = a0.outcome; legs[engines[1]] = a1.outcome
                if a0.cached { cachedLegs.insert(engines[0]) }
                if a1.cached { cachedLegs.insert(engines[1]) }
            } else {
                let a0 = await leg(engines[0])
                legs[engines[0]] = a0.outcome
                if a0.cached { cachedLegs.insert(engines[0]) }
            }
            if Task.isCancelled { return nil }
            let allCached = cachedLegs.count == engines.count
            for (e, l) in legs where !cachedLegs.contains(e) {      // 命中缓存的腿没问过服务器，不改引擎健康
                var hard = false
                if case .transport = l { hard = await RoadNetwork.RateLimiter.shared.cooling(RoadNetwork.host(for: e)) }   // 429 冷却中：一次就停用
                await coord.record(e, l.legKind, hard: hard)
            }
            func why(_ l: LegOutcome?) -> String {
                guard let e = l?.error else { return "" }
                return (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
            }
            let ordered: [RoadNetwork.RouteEngine] = [.osrm, .valhalla]
            let drafts = ordered.compactMap { legs[$0]?.draft }
            guard crossCheck else {
                if let d = drafts.first { return BatchOutcome(kind: .draft(d), cached: allCached) }
                return BatchOutcome(kind: .failed(legs.values.first?.error ?? RouteError.allEndpointsFailed([])), cached: allCached)
            }
            if drafts.count == 2 {
                let dO = drafts[0], dV = drafts[1]
                let cross = RouteCrossCheck.compare(dO, dV, a: A, b: B)
                if cross.agree {
                    // 两份都加上「两路一致」说明和锚点离路提醒：「改用另一条」换过去、再换回来都不丢
                    func annotated(_ x: RouteDraft, other: RouteDraft) -> RouteDraft {
                        var y = x
                        y.notes = [RouteCrossCheck.agreeNote(cross, adopted: x, other: other)] + y.notes
                        if let w = RouteCrossCheck.anchorWarning(x, matchRadius: inp.radius) { y.warnings.append(w) }
                        return y
                    }
                    let aO = annotated(dO, other: dV), aV = annotated(dV, other: dO)
                    let useO = RouteCrossCheck.preferred(dO, dV)
                    return BatchOutcome(kind: .draft(useO ? aO : aV), crossDrafts: [aO, aV], cross: cross, cached: allCached)
                }
                return BatchOutcome(kind: .conflict(.disagree), crossDrafts: drafts, cross: cross, cached: allCached)
            }
            if drafts.count == 1 {
                let ok = drafts[0].source == .osrmCar ? RoadNetwork.RouteEngine.osrm : .valhalla
                let other: RoadNetwork.RouteEngine = ok == .osrm ? .valhalla : .osrm
                let reason = legs[other] == nil
                    ? String(localized: "已停用：连续连不上", comment: "Precise mode: why the other routing service gave no result — it was disabled after repeated connection failures")
                    : why(legs[other])
                return BatchOutcome(kind: .conflict(.unverified(reason)), crossDrafts: drafts, cached: allCached)
            }
            // 两路都失败：引擎"回答了"的错误（没路 / 太远）优先报；只有一路有错误就报它；否则合并成一句
            if let answered = ordered.compactMap({ legs[$0] }).first(where: { if case .noRoute = $0 { return true }; return false })?.error { return BatchOutcome(kind: .failed(answered), cached: allCached) }
            let errs = ordered.compactMap { legs[$0]?.error }
            if errs.count == 1, let only = errs.first { return BatchOutcome(kind: .failed(only), cached: allCached) }
            return BatchOutcome(kind: .failed(BothEnginesFailed(osrm: why(legs[.osrm]), valhalla: why(legs[.valhalla]))), cached: allCached)
        case .rail:
            // economy: true = 批量的 railRoute 带 OverpassCache、包围盒更大（≥6 km），结果可能与单处（≥1.5 km）不同，分开缓存
            let key = RouteCacheKey(source: .overpassRail, economy: true, ia: c.indexA, ib: c.indexB, a: A, b: B, seconds: c.seconds, inputs: inp, leftHand: nil)
            let (r, cached) = await Self.cachedRoute(routeCache, key: key, ignoreCache: ignoreCache) {
                try await RoadNetwork.railRoute(a: A, b: B, cache: cache,
                                                contextA: inp.a.context.anchor, contextB: inp.b.context.anchor,
                                                portalA: inp.portalA, portalB: inp.portalB,
                                                matchRadius: inp.radius, seconds: c.seconds)
            }
            switch r {
            case .success(var d):
                if cached { d.notes.insert(RouteCache.hitNote, at: 0) }
                if crossCheck { d.notes.append(String(localized: "铁路只有 Overpass 一个来源，未做交叉验证", comment: "Route note in precise mode: rail geometry has a single source (Overpass), so no cross-check was possible. Keep Overpass untranslated")) }
                return BatchOutcome(kind: .draft(d), cached: cached)
            case .failure(let error):
                if Task.isCancelled { return nil }
                if error is CancellationError { return nil }
                if let u = error as? URLError, u.code == .cancelled { return nil }
                return BatchOutcome(kind: .failed(error), cached: cached)
            }
        default:
            return BatchOutcome(kind: .skipped)
        }
    }

    /// 精确模式「待选」项的人工决定
    enum BatchPick: Equatable { case source(RouteSource), straight, none }

    /// 待选 → 选一路 / 直线 / 都不补。选一路：该份成为草稿、状态完成、勾选落地；直线：只对公路；
    /// 都不补：状态仍是待选（两份草稿还在、地图上还画着、随时可改选），只是不再算"等你选"、不落地。
    /// 已经选定过的（done 且有两份草稿）也可以再改选
    func resolveBatchConflict(_ id: GapID, _ pick: BatchPick) {
        guard var st = batch, st.phase == .preview || st.phase == .running, let i = st.items.firstIndex(where: { $0.id == id }),
              st.items[i].status.isConflict || (st.items[i].status.isDone && st.items[i].userPicked && !st.items[i].crossDrafts.isEmpty) else { return }
        // 改选时先回到待选的样子（原来的种类按比对结果恢复）
        if st.items[i].status.isDone {
            st.items[i].status = .conflict(st.items[i].cross == nil
                ? .unverified(String(localized: "已停用：连续连不上", comment: "Precise mode: why the other routing service gave no result — it was disabled after repeated connection failures"))
                : .disagree)
        }
        switch pick {
        case .source(let source):
            guard var chosen = st.items[i].crossDrafts.first(where: { $0.source == source }) else { return }
            let name = source.label
            let note = st.items[i].status.isDisagree
                ? String(localized: "人工审核：两路不一致，选用 \(name)", comment: "Route note (precise mode): the user reviewed a disagreement between the routers and picked this source. %@ = source label")
                : String(localized: "人工采用：只有 \(name) 给出结果，未交叉验证", comment: "Route note (precise mode): the user accepted the only router result; it was not cross-checked. %@ = source label")
            chosen.notes = [note] + chosen.notes
            st.items[i].draft = chosen
            st.items[i].useStraight = false
            st.items[i].status = .done
            st.items[i].include = true
            st.items[i].declined = false
            if let track { st.items[i].plausibility = assessBatchItem(st.items[i], draft: chosen, track: track) }   // 人工选的照样评估，但不改勾选
        case .straight:
            guard st.items[i].kind == .road else { return }
            st.items[i].draft = nil
            st.items[i].useStraight = true
            st.items[i].status = .done
            st.items[i].include = true
            st.items[i].declined = false
        case .none:
            st.items[i].draft = nil
            st.items[i].useStraight = false
            st.items[i].include = false
            st.items[i].declined = true
        }
        st.items[i].userPicked = true
        st.items[i].computeBBox()
        batch = st
        fillVersion &+= 1
    }

    /// 已选定/一致的项「改用另一条」：草稿换成另一路那份（一致项的另一份也在 crossDrafts 里）
    func swapBatchCross(_ id: GapID) {
        guard var st = batch, st.phase == .preview, let i = st.items.firstIndex(where: { $0.id == id }),
              st.items[i].status.isDone, var other = st.items[i].otherCrossDraft else { return }
        let name = other.source.label
        other.notes = [String(localized: "人工改用 \(name)", comment: "Route note (precise mode): the user switched this gap to the other router's route. %@ = source label")] + other.notes
        st.items[i].draft = other
        st.items[i].useStraight = false
        st.items[i].userPicked = true
        st.items[i].include = true
        st.items[i].computeBBox()
        if let track { st.items[i].plausibility = assessBatchItem(st.items[i], draft: other, track: track) }
        batch = st
        fillVersion &+= 1
    }

    /// 「只有一路结果的全部采用」：没比对的待选项一律采用唯一那份（notes 记明未交叉验证）
    func acceptUnverifiedAll() {
        guard let st = batch, st.phase == .preview else { return }
        for it in st.items where it.status.isUnverified && !it.declined && it.crossDrafts.count == 1 { resolveBatchConflict(it.id, .source(it.crossDrafts[0].source)) }
    }

    /// 跳到下一处等你选的（不含已选「都不补」的；从当前选中处往后找，到底绕回开头）
    func selectBatchNextConflict() {
        guard let st = batch else { return }
        let ids = st.items.indices.filter { st.items[$0].status.isConflict && !st.items[$0].declined }
        guard !ids.isEmpty else { return }
        let cur = st.selectedID.flatMap { id in st.items.firstIndex { $0.id == id } } ?? -1
        let next = ids.first { $0 > cur } ?? ids[0]
        selectBatchItem(st.items[next].id)
    }

    /// 当前锚点的输入说明（不联网；钩子 `notes` 命令用）
    func currentRouteInputNotes() -> [String] {
        guard let track, let ia = fillAnchorA, let ib = fillAnchorB else { return [] }
        return candidateNotes(ia: ia, ib: ib) + GapRouteInputs.notes(GapRouteInputs.build(track, ia: ia, ib: ib, profile: profile(at: ia)), profile: profile(at: ia))
    }

    /// 锚点正好是某处候选的 (A, B) 时，该候选自带的说明（冻结假点链前移等）；手动挪过锚点就不再适用
    private func candidateNotes(ia: Int, ib: Int) -> [String] {
        // 草稿把锚点自动外推后下标对不上候选：当前候选且锚点没手动挪过时仍给同一条说明
        GapRouteInputs.candidateNotes(gapCandidates.first { $0.indexA == ia && $0.indexB == ib }
                                      ?? (fillAnchorsMatchCandidate && fillAnchorA == ia && fillAnchorB == ib ? fillCandidate : nil))
    }

    /// 当前轨迹全部候选的路由输入（JSONL，一行一处；钩子 `routeinputs` 命令用，与离线 harness 的导出逐字节可比）
    func routeInputsDump() -> String {
        guard let track else { return "" }
        return gapCandidates.enumerated().map { i, c in
            GapInputDump.line(index: i, candidate: c, inputs: GapRouteInputs.build(track, ia: c.indexA, ib: c.indexB, profile: profile(at: c.indexA)))
        }.joined(separator: "\n")
    }

    /// 分类阶段：把成因是「采样稀疏」的全部设成某一类（通常是跳过）
    @discardableResult
    func setBatchSparse(_ kind: BatchKind) -> Int {
        guard var st = batch, st.phase == .classify else { return 0 }
        var n = 0
        for i in st.items.indices where st.items[i].sampling?.nature == .sparseSampling { st.items[i].kind = kind; n += 1 }
        batch = st
        fillVersion &+= 1
        return n
    }

    /// 预览阶段：按草稿的采用依据（匹配/上下文/约束/直接/铁路）批量勾选或取消
    func setBatchIncludeMethod(_ method: RouteMethod, _ on: Bool) {
        guard var st = batch, st.phase == .preview else { return }
        for i in st.items.indices where st.items[i].draft?.method == method && !st.items[i].userPicked { st.items[i].include = on }   // 用户手选过的不覆盖
        batch = st
        fillVersion &+= 1
    }

    func cancelBatch() {
        batchRunTask?.cancel()
        batchRunTask = nil
        cancelBatchRefetches()
        guard var st = batch else { return }
        if st.phase == .running {
            batchGeneration &+= 1
            st.generation = batchGeneration
            let cancelled = String(localized: "已取消", comment: "Batch Gap Fill row status (after “failed:”): the request was cancelled")
            for i in st.items.indices where st.items[i].status == .running || st.items[i].status == .pending {
                st.items[i].status = st.items[i].status == .pending ? .skipped : .failed(cancelled)
            }
            st.currentIndex = nil
            st.phase = .preview
            st.progressText = ""
            batch = st
            fillVersion &+= 1
        }
    }

    func setBatchInclude(_ id: GapID, _ on: Bool) {
        guard var st = batch, let i = st.items.firstIndex(where: { $0.id == id }), !st.items[i].status.isConflict else { return }   // 待选项只能走 resolveBatchConflict
        st.items[i].include = on
        batch = st
        fillVersion &+= 1
    }

    func setBatchIncludeAllDone() {
        guard var st = batch else { return }
        for i in st.items.indices where st.items[i].status.isDone { st.items[i].include = true }
        batch = st
        fillVersion &+= 1
    }

    /// 连不上/服务异常（而非路网或隧道判定）：乱跳簇遇到这种失败不默认删点
    static func isTransportFailure(_ e: Error) -> Bool {
        guard let r = e as? RouteError else { return true }
        switch r {
        case .allEndpointsFailed, .badResponse: return true
        default: return false
        }
    }
    /// 「只补公路」时疑似铁路的跳过；铁路上的乱跳段除外（批量里按本地只删点处理，不发请求）
    private func plannedKind(_ k: BatchKind?, for c: GapCandidate) -> BatchKind {
        (k == .rail && fillRoadOnly && c.kind != .jitter) ? .skip : (k ?? .skip)
    }

    func setBatchStraight(_ id: GapID, _ on: Bool) {
        guard var st = batch, let i = st.items.firstIndex(where: { $0.id == id }), st.items[i].kind == .road || !on, !st.items[i].status.isConflict else { return }   // 铁路不给直线兜底；待选项走 resolveBatchConflict
        st.items[i].useStraight = on
        if on { st.items[i].include = true; st.items[i].computeBBox() }
        else { st.items[i].include = st.items[i].draft != nil || st.items[i].deleteOnlyActive }   // 关掉直线：只删点的兜底仍落地
        batch = st
        fillVersion &+= 1
    }

    /// 乱跳簇取不到路径时「只删点」开关（只对乱跳簇有意义）
    func setBatchDeleteOnly(_ id: GapID, _ on: Bool) {
        guard var st = batch, let i = st.items.firstIndex(where: { $0.id == id }), st.items[i].candidate.kind == .jitter, !st.items[i].status.isConflict else { return }
        st.items[i].deleteOnly = on
        st.items[i].include = on || st.items[i].draft != nil || st.items[i].useStraight
        batch = st
        fillVersion &+= 1
    }

    /// 预览里选中一处：主地图飞过去并高亮。只设锚点用于定位，不进入顶点编辑（编辑在批量期间禁用）
    /// 紧凑卡片里的上一处/下一处
    func selectBatchNeighbor(_ delta: Int) {
        guard let st = batch, let id = st.selectedID, let i = st.items.firstIndex(where: { $0.id == id }),
              st.items.indices.contains(i + delta) else { return }
        selectBatchItem(st.items[i + delta].id)
    }

    func selectBatchItem(_ id: GapID) {
        guard var st = batch, let item = st.items.first(where: { $0.id == id }), let track, track.id == st.trackID else { return }
        st.selectedID = id
        batch = st
        if !batchCompact { batchCompact = true }      // 点行就是要看地图：窗口折叠成小卡片
        let c = item.candidate
        guard c.indexA >= 0, c.indexB > c.indexA, c.indexB < track.timedCount,
              c.trackID == track.id, track.topology.segment(of: c.indexA) == c.segment, track.topology.segment(of: c.indexB) == c.segment,
              track.time[c.indexA] == c.tA, track.time[c.indexB] == c.tB else { return }
        let shiftA = item.useStraight ? 0 : (item.draft?.shiftA ?? 0), shiftB = item.useStraight ? 0 : (item.draft?.shiftB ?? 0)
        fillAnchorA = shifted(c.indexA, by: -shiftA, track: track)
        fillAnchorB = shifted(c.indexB, by: shiftB, track: track)
        fillCandidate = c
        fillVertices = []
        fillVertexSources = []
        fillVertexHistory = []
        rebuildFillColors()
        fillVersion &+= 1
        fillFocusVersion &+= 1
    }

    /// 一次落地所有勾选的：有草稿的按草稿，勾了直线的按直线；过时出口点一律替换
    func landBatch() {
        // 单项重取在途时不落地：那一处旧草稿已清、新结果未到，落了会把它悄悄漏掉
        guard var st = batch, st.phase == .preview, !isLoading, st.refetchingCount == 0, batchRefetchTasks.isEmpty,
              let track, track.id == st.trackID else { return }
        var jobs: [(GapSplice.Job, GapFill)] = []
        var lastB: [UInt32: Int] = [:]
        for item in st.items.sorted(by: { $0.candidate.indexA < $1.candidate.indexA }) where item.willLand {
            guard let (job, rec) = landingJob(for: item, track: track, lastB: lastB[item.candidate.segment] ?? -1) else {
                errorMessage = String(localized: "无法应用补点：锚点或区间已改变，请重新选择。", comment: "Apply-fill conflict: the anchors or segment membership changed; select the gap again")
                return
            }
            lastB[item.candidate.segment] = track.topology.pathRank(of: job.indexB)
            jobs.append((job, rec))
        }
        guard !jobs.isEmpty else { return }
        st.phase = .landing
        batch = st
        batchSavedDraft = nil
        pendingLandingToast = jobs.count         // 重建完成后弹「已落地 N 处」横幅（用户：不要再停在批量窗口的空页）
        performFills(jobs)                       // 落地后 apply() 会作废批次
        invalidateBatch()
        NSApp.window(scene: SceneID.batchFill)?.performClose(nil)
        if reviewPreview { reviewPreview = false; reviewSelect(nil) }   // 审阅窗口若开着：从「落地前预览」切回真实的修改记录
    }

    // MARK: - 顶部横幅提示（落地成功等；几秒后自动消失）

    struct Toast: Equatable {
        enum Action: Equatable { case none, openReview }
        let text: String
        let action: Action
        let actionTitle: String?
    }
    @Published var toast: Toast?
    private var toastTimer: Timer?
    private var pendingLandingToast: Int?
    func showToast(_ text: String, action: Toast.Action = .none, actionTitle: String? = nil, seconds: Double = 6) {
        toast = Toast(text: text, action: action, actionTitle: actionTitle)
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.toast = nil }
        }
    }
    func dismissToast() { toastTimer?.invalidate(); toast = nil }

    /// 一处批量项的落地作业——landBatch 与落地前预览共用，口径完全一致：
    /// 隧道口漂移按草稿外推锚点（直线不挪）；相邻两处挪完不能重叠（后一处的 A 最多退到前一处的 B = lastB）；
    /// 区间内贴路点按 keptInnerPoints 保留；既插不出点、也没有点要删的处什么都不做（返回 nil）。
    /// forPreview：待选项按 OSRM 份（或唯一那份）看效果
    private func landingJob(for item: BatchItem, track: TrackData, lastB: Int, forPreview: Bool = false) -> (job: GapSplice.Job, rec: GapFill)? {
        let c = item.candidate
        guard c.indexA >= 0, c.indexB > c.indexA, c.indexB < track.timedCount,
              c.trackID == track.id, track.topology.segment(of: c.indexA) == c.segment, track.topology.segment(of: c.indexB) == c.segment,
              track.time[c.indexA] == c.tA, track.time[c.indexB] == c.tB else { return nil }
        let draft = item.draft ?? (forPreview && item.status.isConflict ? item.crossDrafts.first : nil)
        let deleteOnly = item.landsDeleteOnly                 // 乱跳簇只删点：不插合成点
        guard draft != nil || item.useStraight || deleteOnly else { return nil }
        let shiftA = item.useStraight ? 0 : (draft?.shiftA ?? 0), shiftB = item.useStraight ? 0 : (draft?.shiftB ?? 0)
        guard lastB <= track.topology.pathRank(of: c.indexA) else { return nil }
        let shiftedA = shifted(c.indexA, by: -shiftA, track: track)
        let rankA = max(lastB, track.topology.pathRank(of: shiftedA))
        let ia = track.topology.globalIndex(atPathRank: rankA), ib = shifted(c.indexB, by: shiftB, track: track)
        guard let inner = track.topology.indices(between: ia, and: ib), let a = fillAnchor(ia), let b = fillAnchor(ib) else { return nil }
        let verts = (item.useStraight || deleteOnly) ? [] : (draft?.coords ?? [])
        // 过时出口点保留位置、只改时间（与单处同一规则 StaleRetime）：合成点只补 A → 第一个保留点
        let plan = deleteOnly ? nil : StaleRetime.plan(track: track, ia: ia, ib: ib, candidate: c, vertices: verts,
                                                       radius: profile(at: ia)?.matchRadius ?? 15)
        var pts = deleteOnly ? [] : FillPath.interpolate(a: a, vertices: plan?.vertices ?? verts, b: plan?.fillB ?? b, spacingMeters: spacingFor(ia, ib))
        // 有改时计划时区间内其余点一律替换（过时点要么改时要么删）
        var keep = !inner.isEmpty && plan == nil ? keptInnerPoints(ia: ia, ib: ib, vertices: verts, candidate: c, deleteOnly: deleteOnly) : []
        if let plan {
            pts = StaleRetime.landingPoints(track: track, ia: ia, ib: ib, plan: plan, synthetic: pts)
            keep.subtract(plan.retimed.map(\.index))       // 改时点：旧点照常删、新点在 pts 里
        }
        let removing = keep.count < inner.count
        guard !pts.isEmpty || removing else { return nil }  // 插不出点但有飘点要删：也做（只删点）
        var rec = GapFill(anchorA: a, anchorB: b, vertices: verts, points: pts,
                          removedInner: max(0, originalInnerCount(a: ia, b: ib) - keep.count),
                          userVertices: verts, routeSource: (item.useStraight || deleteOnly) ? nil : draft?.source)
        if let plan {
            rec.retimedKeys = StaleRetime.keys(track: track, plan: plan)
            rec.retimedOldKeys = StaleRetime.oldKeys(track: track, plan: plan)
        }
        rec.segment = c.segment
        rec.straight = item.useStraight
        // 路网证据随记录保留：采用的在前，另一路（精确模式）在后；直线/只删点也把取到的草稿留着（用户要能回查当时两路给了什么）
        rec.drafts = ([item.draft].compactMap { $0 } + item.crossDrafts.filter { $0.source != item.draft?.source }).filter { $0.source != .deleteOnly }
        if rec.drafts.isEmpty, let d = draft, d.source != .deleteOnly { rec.drafts = [d] }
        rec.cross = item.cross
        rec.originalA = CLLocationCoordinate2D(latitude: c.latA, longitude: c.lonA)
        rec.originalB = CLLocationCoordinate2D(latitude: c.latB, longitude: c.lonB)
        rec.plausibility = (item.useStraight || deleteOnly) ? nil : item.plausibility
        return (GapSplice.Job(indexA: ia, indexB: ib, points: pts, removeInner: !inner.isEmpty, keep: keep, trackID: track.id, segment: c.segment), rec)
    }

    /// 放弃批量：恢复进入前的手工草稿（轨迹没变的话）
    func closeBatch() {
        let saved = batchSavedDraft
        invalidateBatch()
        if let saved, let track, track.id == saved.trackID, fillMode {
            fillCandidate = saved.candidate
            fillAnchorA = saved.a
            fillAnchorB = saved.b
            fillVertices = saved.coords
            fillVertexSources = saved.sources
            fillVertexHistory = saved.history
            fillRouteInfo = saved.route
            fillCrossDrafts = nil                 // 进批量时已清掉；恢复的草稿不带两份对照
            rebuildFillColors()
        } else {
            resetFillDraft()
        }
        fillVersion &+= 1
    }

    private static let batchTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
    static func batchTimeText(_ t: Double) -> String { batchTimeFmt.string(from: Date(timeIntervalSince1970: t)) }

    /// 仅补点增量 → GPX（完整数据：时间/速度/海拔）。每处补点一个 <trkseg>，只含合成点。
    /// 增量文件表达不了"删除"：本会话替换掉的原始点若已在目标 app 里，仍会留在那里
    func exportFillsGPX() {
        guard !fills.isEmpty, let track else { return }
        let base = Self.exportedFileName(from: track.name)
        let panel = NSSavePanel()
        var types: [UTType] = [.xml]
        if let gpx = UTType(filenameExtension: "gpx") { types = [gpx] }
        panel.allowedContentTypes = types
        let fillsWord = String(localized: "补点增量", comment: "filename fragment: no / or : (default file name of the gap-fill increment export: <track>_<this>.gpx)")
        panel.nameFieldStringValue = "\(base)_\(fillsWord).gpx"
        let removed = fills.reduce(0) { $0 + $1.removedInner }
        let added = fills.reduce(0) { $0 + $1.points.count }
        if removed > 0 {
            panel.message = String(localized: "只含本会话新增的 \(added) 个点（每处补点一段）。注意：补点时替换掉了 \(removed) 个原始点，增量文件无法表达删除——如果目标 app 里已有这些点，请改用「整条轨迹」导出", comment: "Save panel message of the gap-fill increment export; first %lld = points added this session, second %lld = original points replaced; the bracketed term refers to the Whole Track GPX export menu item")
        } else {
            panel.message = String(localized: "只含本会话新增的 \(added) 个点（每处补点一段），导入已有该轨迹的 app", comment: "Save panel message of the gap-fill increment export; %lld = points added this session (one track segment per fill)")
        }
        let res = panel.runModal()
        noteUserActivity()
        guard res == .OK, let url = panel.url else { return }
        // 按身份（时间+坐标位级）在当前轨迹里找回每处补点的合成点，保持每段内时间有序
        let allKeys = GapFillExport.syntheticKeys(fills)
        let segments: [[Int32]] = GapFillExport.segmentIndices(track: track, fills: fills, includeAnchors: false).map { $0.map(Int32.init) }
        let dropped = fills.reduce(0) { $0 + $1.points.count } - segments.reduce(0) { $0 + $1.count }
        do {
            let gpxName = String(localized: "\(base) 补点增量", comment: "GPX <name> written into the gap-fill increment file; %@ = track base name")
            try GPXWriter.write(track: track, segments: segments, name: gpxName, to: url,
                                synthetic: allKeys)
            if dropped > 0 {
                errorMessage = String(localized: "增量已导出，但有 \(dropped) 个合成点在后来的补点中又被替换掉，未包含在内", comment: "Alert after the increment export; %lld = synthetic points left out because later fills replaced them")
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 区间内"原始点"数：排除本会话早先补点生成的合成点（增量导出的删除提示只该数真实数据）
    private var syntheticKeyCache: (count: Int, last: UUID?, keys: Set<GapFillExport.PointKey>)?
    private func originalInnerCount(a: Int, b: Int) -> Int {
        guard let track, let inner = track.topology.indices(between: a, and: b) else { return 0 }
        guard !fills.isEmpty else { return inner.count }
        // 合成点集合按补点清单缓存：批量落地几千处时每处重建一次是 O(处 × 合成点)
        let keys: Set<GapFillExport.PointKey>
        if let c = syntheticKeyCache, c.count == fills.count, c.last == fills.last?.id { keys = c.keys }
        else { keys = GapFillExport.syntheticKeys(fills); syntheticKeyCache = (fills.count, fills.last?.id, keys) }
        var n = 0
        for k in inner where !keys.contains(GapFillExport.PointKey(track.time[k], track.lat[k], track.lon[k], segment: track.topology.segment(of: k))) { n += 1 }
        return n
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

    /// 一键清理回放点：先弹确认（点数），确认后作为一条「回放点清理」修改记录删除
    func requestCleanReplays() {
        guard let track, track.id == replayTrackID, !replayIndices.isEmpty, !isLoading, batch == nil else { return }
        replayPrompt = replayIndices.count
    }
    func confirmCleanReplays() {
        replayPrompt = nil
        guard let track, track.id == replayTrackID, !replayIndices.isEmpty, !isLoading, batch == nil else { return }
        let idx = replayIndices
        resetFillDraft()
        gapCandidates = []                 // 重建期间旧候选的下标已无意义
        // 等确认框关完再重建（同 confirmApplyFill 的理由）
        enqueueEdit { store in
            guard let t = store.track, t.id == track.id else { return }
            store.performDeletion(of: idx, from: t, kind: .replay)
        }
    }

    private func performDeletion(of toDelete: [Int32], from current: TrackData, kind: TrackChange.Kind = .deletion) {
        guard track?.id == current.id, !isLoading else { return }
        let token = beginDataOperation(source: current)
        let baseline = ChangeRevert.snapshot(current)
        isLoading = true
        let pointsText = toDelete.count.formatted()
        loadingLabel = String(localized: "删除 \(pointsText) 个点…", comment: "Loading overlay while deleting points; %@ = number of points (already formatted with grouping)")
        let mode = settings.colorMode
        let single = singleRGBA()

        Task.detached(priority: .userInitiated) { [weak self] in
            var keep = [Bool](repeating: true, count: current.count)
            for i in toDelete { keep[Int(i)] = false }
            let kept = current.count - toDelete.count
            var p = ParsedTrack()
            p.creator = current.creator; p.accuracyMedian = current.gpsAccuracy
            p.lat.reserveCapacity(kept)
            p.lon.reserveCapacity(kept)
            p.ele.reserveCapacity(kept)
            p.time.reserveCapacity(kept)
            for i in 0..<current.count where keep[i] {
                p.lat.append(current.lat[i])
                p.lon.append(current.lon[i])
                p.ele.append(current.ele[i])
                p.time.append(current.time[i])
                p.segmentID.append(current.topology.segment(of: i))
                if current.fileID.count == current.count { p.fileID.append(current.fileID[i]) }
            }
            p.name = current.name
            p.chunkCount = ProcessInfo.processInfo.activeProcessorCount
            let (newTrack, newStats) = TrackData.build(parsed: p, preferredMode: mode, singleColor: single)
            var removed: [ChangePoint] = []
            removed.reserveCapacity(toDelete.count)
            for i in toDelete.sorted() {
                let k = Int(i)
                removed.append(ChangePoint(lat: current.lat[k], lon: current.lon[k], ele: current.ele[k], time: current.time[k], originalIndex: k, segment: current.topology.segment(of: k)))
            }
            let change = TrackChange(kind: kind, date: Date(), added: [], removed: removed, anchors: [], fillID: nil)
            guard let self else { return }
            let keptParsed = p
            await self.publishData(token) {
                self.rememberEditBaseline(baseline)
                self.preserveNextCamera = true
                // 单文件留底同步为删除后的数据，防止之后重建/切模式复活已删点
                if self.files.count == 1 {
                    self.files[0].parsed = keptParsed
                }
                self.keepChangeLog = true          // 删除是一条修改记录，不是换文件
                // 回放点清理在补点模式里发起：模式保留，重建后重新检测候选（与撤销落地同一路径）
                let keepFill = kind == .replay && self.fillMode
                if keepFill { self.fillApplying = true; self.resetFillDraft(); self.gapCandidates = [] }
                self.apply(track: newTrack, stats: newStats)
                self.keepChangeLog = false
                if keepFill {
                    self.fillApplying = false
                    // 旧的「撤销落地」快照不再对应现在的轨迹（同 revertChanges）；行程判定按段号键，删掉几千点后段可能重切
                    self.lastFill = nil; self.fillUndo = nil; self.fillCanUndo = false
                    self.tripKindOverride = [:]; self.tripMap = [:]; self.cancelTripMap()
                    self.resetFillDraft(); self.refreshGapCandidates(); self.fillVersion &+= 1
                }
                self.changes.append(change)
            }
        }
    }
}

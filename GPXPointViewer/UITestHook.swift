//
//  UITestHook.swift
//  GPXPointViewer
//
//  自测钩子：只有启动时带环境变量 GPXPV_UITEST_DIR 才启用，正常使用完全不参与。
//  轮询 <dir>/cmd（每行一条命令），执行后把结果写到 <dir>/out.txt 并删除 cmd。
//  坐标一律是主窗口 contentView 的左上角原点（与覆盖层投影同一坐标系）。
//  鼠标事件通过 NSApp.postEvent 投进自己的事件队列——不需要任何系统权限，
//  本地事件监视器、手势识别器、MapKit 都和真实输入一样收到。
//

import AppKit
import CoreLocation
import MapKit
import SwiftUI
import simd

@MainActor
final class UITestHook {
    static let shared = UITestHook()
    /// 只查一次（鼠标事件路径上会频繁判断）；空值视为未设置
    /// 钩子目录：环境变量 GPXPV_UITEST_DIR；没有就看 relaunch 留下的交接文件（NSWorkspace 新开的实例拿不到环境变量和启动参数，
    /// 实测两者都被剥掉）——容器 tmp 里的 uitest-handoff，2 分钟内新鲜才认，读完即删
    static let dirPath: String? = {
        if let d = ProcessInfo.processInfo.environment["GPXPV_UITEST_DIR"], !d.isEmpty { return d }
        let handoff = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("uitest-handoff")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: handoff.path), let m = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(m) < 120, let d = try? String(contentsOf: handoff, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty else { return nil }
        try? FileManager.default.removeItem(at: handoff)
        return d
    }()
    /// relaunch 前调用：把钩子目录交给下一个实例
    static func writeHandoff() {
        guard let d = dirPath else { return }
        try? d.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("uitest-handoff"), atomically: true, encoding: .utf8)
    }
    static let enabled: Bool = dirPath != nil
    private var readFailures = 0
    /// 进入批量时是否自动跑「地图判段」（会真实查 Overpass）：离线测试用钩子 `autotripmap 0` 关掉
    nonisolated(unsafe) static var autoTripMap = true

    /// 假引擎模式（fakeroute 命令）：按引擎给 "ok" / "offset <m>" / "noroute" / "fail" / "slow <ms>"；都没设时恢复真实请求。
    /// 只设了一路时另一路按"连不上"处理（不联网）
    nonisolated(unsafe) static var fakeModes: [RoadNetwork.RouteEngine: String] = [:]
    static func installFakeRoutes() {
        let modes = fakeModes
        guard !modes.isEmpty else { RoadNetwork.routeOverride = nil; return }
        RoadNetwork.routeOverride = { engine, a, b in
            // 假请求也计数（按主机）：测试用 requestsByHost 证明"命中缓存时没有再请求"
            RoadNetwork.RateLimiter.shared.counter.increment(RoadNetwork.host(for: engine))
            guard let mode = modes[engine] else {
                throw RouteError.allEndpointsFailed(["\(RoadNetwork.host(for: engine)) fake: 此路未设假模式"])
            }
            let parts = mode.split(separator: " ").map(String.init)
            let kind = parts[0], arg = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
            switch kind {
            case "noroute": throw RouteError.noRoute(String(localized: "两点之间没有可行驶路径", comment: "No-route reason: there is no drivable path between the two points"))
            case "fail": throw RouteError.allEndpointsFailed(["\(RoadNetwork.host(for: engine)) fake 超时"])
            case "slow": try await Task.sleep(nanoseconds: UInt64(max(0, arg) * 1e6)); fallthrough
            default:
                // 直连弦上 3 个中间点；offset = 整条向右（垂直于行进方向）平移 m 米
                let off = kind == "offset" ? arg : 0
                let f = PortalDrift.Frame(origin: a)
                let pa = f.xy(a), pb = f.xy(b), d = pb - pa
                let len = simd_length(d)
                let n = len > 0 ? SIMD2(d.y, -d.x) / len : SIMD2(0, 0)
                let coords = [0.25, 0.5, 0.75].map { f.coord(pa + d * $0 + n * off) }
                var draft = RouteDraft(source: engine == .osrm ? .osrmCar : .valhallaCar, coords: coords, meters: len, snapA: 0, snapB: 0,
                                       endpoint: "fake", warnings: [], notes: ["fake \(mode)"], method: .context)
                // 「路网原始折线」= 直弦本身：offset 模式下补点离它 m 米，落地前自检（FillPlausibility）据此扣分，模拟「后处理把几何弄坏」
                draft.rawCoords = [a, b]
                return draft
            }
        }
    }
    /// 自测时相机不做动画：被判定为"不可见"的窗口（如由脚本启动）MapKit 不跑动画，相机会卡在原地
    static let noAnimation: Bool = enabled

    var topologyStats: (() -> [String: Int])?
    var lastOverlay = TrackStore.FillOverlay()   // 协调器每次发布时镜像一份（仅启用时）
    var debugInfo: (() -> String)?                // 协调器挂上来的内部状态描述
    var projectNow: (() -> Void)?                 // 立即重投影覆盖层（锁屏/遮挡时显示链接不跳，投影会过期）
    var openBatchWindow: (() -> Void)?            // ContentView 挂上来的 openWindow(id: SceneID.batchFill)（测试用，合成点击会误拖窗口）
    var openReviewWindow: (() -> Void)?           // 同上：修改记录窗口
    var openRegionsWindow: (() -> Void)?          // 同上：地区统计窗口
    var openSummaryWindow: (() -> Void)?
    var summaryScroll: ((Bool) -> Void)?
    var summaryFilterFrame: CGRect?
    var regionOverlayCount = 0                    // 地图上当前的地区边界多边形数（协调器写）
    weak var surface: NSView?                     // 地图容器（覆盖层投影的坐标系；窗口是 fullSizeContentView，contentView 含标题栏）

    /// 测试日志（仅启用时写 <dir>/log.txt）
    nonisolated static func log(_ msg: @autoclosure () -> String) {
        guard let d = dirPath else { return }
        let line = msg() + "\n"
        if let h = FileHandle(forWritingAtPath: d + "/log.txt") { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        else { try? line.write(toFile: d + "/log.txt", atomically: true, encoding: .utf8) }
    }
    private weak var store: TrackStore?
    private var timer: Timer?
    private var dir: URL?
    private var eventNumber = 1000

    func start(store: TrackStore) {
        guard timer == nil, let d = Self.dirPath else { return }
        self.store = store
        dir = URL(fileURLWithPath: d)
        try? "started \(Date())".write(to: dir!.appendingPathComponent("alive"), atomically: true, encoding: .utf8)
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)      // 菜单/拖拽跟踪期间也要跑
        timer = t
    }
    private var polls = 0

    private var window: NSWindow? {
        NSApp?.windows.first { $0.isVisible && $0.contentView != nil && $0.title.contains("GPX") }
            ?? NSApp?.windows.first { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }
    }

    private func poll() {
        guard let dir else { return }
        polls += 1
        if polls % 20 == 0 { try? "poll \(polls) \(Date())".write(to: dir.appendingPathComponent("alive"), atomically: true, encoding: .utf8) }
        let cmdURL = dir.appendingPathComponent("cmd")
        let text: String
        do { text = try String(contentsOf: cmdURL, encoding: .utf8); readFailures = 0 }
        catch {
            // ui.py 先写 cmd.tmp 再 rename 成 cmd：exists 与读之间撞上替换会 ENOENT。下一拍再读；连续 10 拍都读不到才报错并清掉
            guard FileManager.default.fileExists(atPath: cmdURL.path) else { return }
            readFailures += 1
            if readFailures >= 10 {
                readFailures = 0
                try? "read error: \(error)".write(to: dir.appendingPathComponent("out.txt"), atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: cmdURL)
            }
            return
        }
        try? FileManager.default.removeItem(at: cmdURL)
        var out: [String] = []
        store?.onUserActivity?()          // 每批命令都算用户活动，别在测试中途进入闲置展示
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            guard let c = parts.first else { continue }
            out.append(run(c, parts))
        }
        try? out.joined(separator: "\n").write(to: dir.appendingPathComponent("out.txt"), atomically: true, encoding: .utf8)
    }

    private func num(_ parts: [String], _ i: Int) -> CGFloat { CGFloat(Double(parts.count > i ? parts[i] : "") ?? 0) }

    private func run(_ c: String, _ p: [String]) -> String {
        guard let store else { return "no store" }
        switch c {
        case "open":
            // open <path>：GPX/CSV 走统一载入；.fwdb 目录走存档导入（与打开面板同一分流）
            let path = p.dropFirst().joined(separator: " ")
            let url = URL(fileURLWithPath: path)
            if FogArchive.looksLikeArchive(url) { store.loadFwdb(urls: [url]); return "open fwdb \(path)" }
            store.load(urls: [url])
            return "open \(path)"
        case "fogstats":
            // 迷雾统计卡的数字（GPX 轨迹按需后台算；存档直读）——地区统计迷雾口径的 totalCells 应与 cells 一致
            store.ensureFogStats()
            let st = store.fogArchive?.stats ?? store.fogStats
            guard let st else { return "{\"ready\":false}" }
            return String(format: "{\"ready\":true,\"cells\":%d,\"km2\":%.6f,\"level\":%d,\"percent\":%.9f,\"nextLevelKm2\":%.6f}", st.cells, st.km2, st.level, st.percent, st.nextLevelKm2)
        case "fill": store.enterFillMode(); return "fill \(store.fillMode)"
        case "exit": store.exitFillMode(); return "exit"
        case "select":
            let i = Int(num(p, 1))
            guard store.gapCandidates.indices.contains(i) else { return "select: no candidate \(i)" }
            store.selectGap(store.gapCandidates[i]); return "select \(i)"
        case "apply": store.requestApplyFill(); return "apply prompt=\(store.fillPrompt.map { "\($0.insert)/\($0.remove)" } ?? "nil")"
        case "confirm":
            // 走真实用户路径：点确认框里的按钮。程序化置空 fillPrompt 会让 SwiftUI 在布局过程中带动画关 sheet，
            // 嵌套 runloop 里再进 UpdateCycle → 偶发空指针崩溃（2026-10-21、10-23 两次都在这里）
            let replace = (p.count > 1 ? p[1] : "replace") == "replace"
            if let panel = NSApp.windows.first(where: { $0.isVisible && $0.isSheet }),
               let btn = Self.findButton(in: panel.contentView, titleContains: replace ? "替换" : "保留") ?? Self.findButton(in: panel.contentView, titleContains: "插入") {
                btn.performClick(nil); pump(400)
                return "confirm (click \(btn.title))"
            }
            // 找不到按钮就报错，不做程序化关闭（会崩，见上）
            return "confirm: button not found"
        case "dismiss":
            // 关掉当前的提示框（错误提示等）：点它的默认/取消按钮——按 keyEquivalent 找，不看按钮文字，四种界面语言都适用
            guard let panel = NSApp.windows.first(where: { $0.isVisible && $0.isSheet }) else { return "dismiss: no sheet" }
            var buttons: [NSButton] = []
            func collect(_ v: NSView) { if let b = v as? NSButton { buttons.append(b) }; v.subviews.forEach(collect) }
            if let cv = panel.contentView { collect(cv) }
            let target = buttons.first { $0.keyEquivalent == "\u{1b}" } ?? buttons.first { $0.keyEquivalent == "\r" } ?? (buttons.count == 1 ? buttons[0] : nil)
            guard let b = target else { return "dismiss: \(buttons.count) buttons, none default/cancel" }
            b.performClick(nil); pump(300)
            return "dismiss (click \(b.title))"
        case "undo": store.undoFillVertex(); return "undo"
        case "pointat":
            // pointat <i>：第 i 个点的时间/坐标（time = Unix 秒）
            guard let t = store.track else { return "{\"error\":\"no track\"}" }
            let i = Int(num(p, 1))
            guard i >= 0, i < t.count else { return "{\"error\":\"out of range\"}" }
            return String(format: "{\"index\":%d,\"time\":%.3f,\"lat\":%.8f,\"lon\":%.8f}", i, t.time[i], t.lat[i], t.lon[i])
        case "pointfind":
            // pointfind <lat> <lon>：离该坐标最近的点（下标/时间/距离 m）
            guard let t = store.track, t.count > 0 else { return "{\"error\":\"no track\"}" }
            let lat = Double(num(p, 1)), lon = Double(num(p, 2))
            var best = 0, bestD = Double.infinity
            for i in 0..<t.count {
                let d = GeoMath.haversine(t.lat[i], t.lon[i], lat, lon)
                if d < bestD { bestD = d; best = i }
            }
            return String(format: "{\"index\":%d,\"time\":%.3f,\"lat\":%.8f,\"lon\":%.8f,\"dist\":%.3f}", best, t.time[best], t.lat[best], t.lon[best], bestD)
        case "selectnear":
            // selectnear lat lon：选 A 端离该坐标最近的候选
            let lat = Double(num(p, 1)), lon = Double(num(p, 2))
            guard let (i, c) = store.gapCandidates.enumerated().min(by: {
                GeoMath.haversine($0.element.latA, $0.element.lonA, lat, lon) < GeoMath.haversine($1.element.latA, $1.element.lonA, lat, lon) }) else { return "selectnear: no candidates" }
            store.selectGap(c)
            return "selectnear \(i) d=\(Int(GeoMath.haversine(c.latA, c.lonA, lat, lon)))m \(Int(c.meters))m \(Int(c.kmh))km/h"
        case "set":
            // set showTrackLine|showArrows|showStats|lodEnabled 0/1 ；set arrowEvery N ；set pointSize X
            guard p.count > 2 else { return "set: key value" }
            let on = p[2] != "0" && p[2].lowercased() != "false"
            switch p[1] {
            case "showTrackLine": store.settings.showTrackLine = on
            case "showArrows": store.settings.showArrows = on
            case "showStats": store.settings.showStats = on
            case "fogMap": store.settings.fogMap = on        // 迷雾模式（地区统计窗口据此默认迷雾口径）
            case "heatMap": store.settings.heatMap = on      // 热力图模式（控制面板隐藏「地区统计…」）
            case "lodEnabled": store.settings.lodEnabled = on
            case "arrowEvery": store.settings.arrowEvery = Int(num(p, 2))
            case "pointSize": store.settings.pointSize = Double(num(p, 2))
            case "mapStyle": store.settings.mapStyle = Self.baseMapStyle(p[2])   // rawValue（标准/卫星/混合/OpenStreetMap/OpenTopoMap/Esri 影像）或英文名
            case "mapOpacity": store.settings.mapOpacity = Double(num(p, 2))
            default: return "set: unknown key \(p[1])"
            }
            return "set \(p[1]) = \(p[2])"
        case "filter":
            // filter <startUnix> <endUnix> | filter off
            if p.count > 1, p[1] == "off" { store.viewFilter = nil; return "filter off" }
            guard p.count > 2 else { return "filter: start end" }
            store.viewFilter = (Double(num(p, 1)), Double(num(p, 2)))
            return "filter \(store.visibleIndexRange().len) 点"
        case "hover":
            // hover <index> <x> <y>：直接发布悬停信息（测试信息卡摆放；mouseMoved 依赖窗口为 key 和追踪区）
            guard let track = store.track, p.count > 3 else { return "hover: index x y" }
            let i = Int(num(p, 1))
            guard i >= 0, i < track.count else { return "hover: bad index" }
            store.hover = track.info(at: i, screenPoint: CGPoint(x: num(p, 2), y: num(p, 3)))
            return "hover \(i) at \(num(p, 2)),\(num(p, 3))"
        case "anchor":
            // anchor A|B <delta>：对应操作条的 ‹ › 按钮
            let isA = (p.count > 1 && p[1].uppercased() == "A")
            store.moveFillAnchor(a: isA, by: Int(num(p, 2)))
            return "anchor \(isA ? "A" : "B") → \(isA ? store.fillAnchorA ?? -1 : store.fillAnchorB ?? -1)"
        case "routecancel": store.cancelRouteRequest(); return "routecancel busy=\(store.fillRouteBusy != nil)"
        case "batchplan": store.startBatchPlanning(); return "batchplan items=\(store.batch?.items.count ?? -1)"
        case "batchall": store.setBatchAll(p.count > 1 && p[1] == "rail" ? .rail : (p.count > 1 && p[1] == "skip" ? .skip : .road)); return "batchall"
        case "batchkind":
            // batchkind <index> road|rail|skip
            guard let st = store.batch, st.items.indices.contains(Int(num(p, 1))) else { return "batchkind: bad index" }
            store.setBatchKind(st.items[Int(num(p, 1))].id, p.count > 2 && p[2] == "rail" ? .rail : (p.count > 2 && p[2] == "skip" ? .skip : .road)); return "batchkind ok"
        case "batchresolve": store.resolveBatchUncertainByMap(); return "batchresolve resolving=\(store.batchResolving)"
        case "batchrun": store.runBatch(); return "batchrun phase=\(String(describing: store.batch?.phase))"
        case "batchcancel": store.cancelBatch(); return "batchcancel"
        case "batchland": store.landBatch(); return "batchland"
        case "batchclose": store.closeBatch(); return "batchclose"
        case "netfail":
            // netfail <n> [host]：注入 n 次失败（测横幅）
            let n = max(1, Int(num(p, 1))), host = p.count > 2 ? p[2] : "routing.openstreetmap.de"
            for _ in 0..<n { NetworkHealth.shared.inject(host: host, ok: false, seconds: 25, detail: "超时") }
            return "netfail \(n) \(host)"
        case "netok":
            let n = max(1, Int(num(p, 1)))
            for _ in 0..<n { NetworkHealth.shared.inject(host: "routing.openstreetmap.de", ok: true, seconds: 0.6) }
            return "netok \(n)"
        // —— 地区统计 ——
        case "summary":
            store.openSummaryFromMainFilter(); openSummaryWindow?()
            return "summary \(openSummaryWindow != nil)"
        case "summarymaindate":
            // Production semantic snapshot, not an interval-duration heuristic.
            guard p.count == 5, let y = Int(p[1]), let m = Int(p[2]), let d = Int(p[3]),
                  let zone = TimeZone(identifier: p[4]) else { return "summarymaindate: year month day IANA" }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let spec = ViewFilterSpec(mode: .day, dayY: y, dayM: m, dayD: d, calendar: calendar)
            guard let range = spec.summaryRange() else { return "summarymaindate: invalid date" }
            store.viewFilter = range; store.viewFilterSpec = spec
            return "summarymaindate"
        case "summarymainall":
            store.viewFilter = nil; store.viewFilterSpec = nil; return "summarymainall"
        case "summarydatefocus", "summarydatecontrol":
            guard let window = NSApp.window(scene: SceneID.journeySummary),
                  let picker = Self.findDatePicker(in: window.contentView) else { return "summarydatecontrol: no native date field" }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(picker)
            if c == "summarydatecontrol" {
                guard p.count == 4, let y = Int(p[1]), let m = Int(p[2]), let d = Int(p[3]),
                      let date = SummaryCalendarDay(year: y, month: m, day: d).interval(in: "UTC")?.start else {
                    return "summarydatecontrol: year month day"
                }
                picker.dateValue = date
                picker.sendAction(picker.action, to: picker.target)
            }
            return "\(c)"
        case "summarykey":
            guard p.count > 1, let window = NSApp.window(scene: SceneID.journeySummary) else { return "summarykey: no window" }
            let value = p[1]
            let code: UInt16 = value == "return" ? 36 : (value == "tab" ? 48 : (value == "left" ? 123 : (value == "right" ? 124 : 0)))
            let chars = value == "return" ? "\r" : (value == "tab" ? "\t" : value)
            let flags: NSEvent.ModifierFlags = p.contains("cmd") ? [.command] : []
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    NSApp.postEvent(event, atStart: false); pump(50)
                }
            }
            return "summarykey"
        case "testquit":
            DispatchQueue.main.async { NSApp.terminate(nil) }; return "testquit"
        case "summarydraft", "summarydate":
            guard p.count == 4, let y = Int(p[1]), let m = Int(p[2]), let d = Int(p[3]) else {
                return "summarydate: year month day"
            }
            let day = SummaryCalendarDay(year: y, month: m, day: d)
            if p[0] == "summarydraft" { store.editSummaryDateDraft(day) }
            else { store.selectSummaryDate(day) }
            return "\(p[0])"
        case "summaryjourney":
            let index = Int(num(p, 1)), rows = store.currentSummaryDayJourneys
            guard rows.indices.contains(index) else { return "summaryjourney: bad current-day index" }
            store.selectSummaryJourney(rows[index].id); return "summaryjourney"
        case "persistsettings":
            guard let id = Bundle.main.bundleIdentifier, id.hasPrefix("de.wayne.GPXPointViewer.test."),
                  ProcessInfo.processInfo.environment["GPXPV_TEST_BUNDLE_ID"] == id,
                  NSHomeDirectory().contains("/Containers/\(id)/Data") else {
                return "persistsettings: isolated test bundle and sandbox required"
            }
            guard p.count == 5, let language = AppLanguage(rawValue: p[1] == "system" ? "" : p[1]),
                  p[2] == "0" || p[2] == "1", let globe = Double(p[3]), let map = Double(p[4]),
                  (1...60).contains(globe), (1...60).contains(map) else {
                return "persistsettings: system|zh-Hans|zh-Hant|en|de 0|1 globeSeconds mapSeconds"
            }
            // This switch is reachable only in explicitly enabled UITestHook mode.
            AppLanguage.apply(language)
            store.updateSetting(\.idleDisabled, to: p[2] == "1")
            store.updateSetting(\.idleGlobeSeconds, to: globe)
            store.updateSetting(\.idleMapSeconds, to: map)
            return settingsJSON(store)
        case "settingsstate": return settingsJSON(store)
        case "summaryclose":
            store.summaryWindowOpen = false
            NSApp.window(scene: SceneID.journeySummary)?.close()
            return "summaryclose"
        case "summarytab":
            store.summaryShowsJourneys = p.count > 1 && p[1] == "journey"
            return "summarytab \(store.summaryShowsJourneys ? "journey" : "day")"
        case "summarydisplay":
            guard p.count > 1 else { return "summarydisplay: single|overlay|compare" }
            let mode: DisplayMode = p[1] == "compare" ? .compare : (p[1] == "overlay" ? .overlay : .single)
            store.switchDisplayMode(to: mode); return "summarydisplay \(p[1])"
        case "summaryclear": store.clearTrack(); return "summaryclear"
        case "summarysize":
            guard p.count > 2, let window = NSApp.window(scene: SceneID.journeySummary) else { return "summarysize: no window" }
            window.setContentSize(NSSize(width: max(780, num(p, 1)), height: max(560, num(p, 2))))
            return "summarysize"
        case "summaryshot":
            guard p.count > 1, let window = NSApp.window(scene: SceneID.journeySummary) else { return "summaryshot: no window" }
            return run("shotwin", ["shotwin", window.title, p.dropFirst().joined(separator: " ")])
        case "summaryscroll":
            summaryScroll?(p.count > 1 && p[1] == "lower")
            return "summaryscroll \(summaryScroll != nil)"
        case "summarystate": return summaryJSON(store)
        case "summarysource":
            let index = Int(num(p, 1))
            guard store.summarySources.indices.contains(index) else { return "summarysource: bad index" }
            store.pickSummarySource(store.summarySources[index].id); return "summarysource \(index)"
        case "summaryzone":
            guard p.count > 1 else { return "summaryzone: system|UTC|IANA" }
            store.pickSummaryTimeZone(p[1] == "system" ? .system : (p[1] == "UTC" ? .utc : .named(p[1])))
            return "summaryzone \(p[1])"
        case "summarymode":
            let index = Int(num(p, 1))
            guard p.count > 2, let report = store.summaryReport,
                  report.journeys.indices.contains(index),
                  p[2] == "auto" || SummaryTransportMode(rawValue: p[2]) != nil else { return "summarymode: index auto|mode" }
            store.setSummaryTransport(p[2] == "auto" ? nil : SummaryTransportMode(rawValue: p[2]),
                                      journeyID: report.journeys[index].id)
            return "summarymode \(index) \(p[2])"
        case "summarymap":
            guard p.count > 2, let report = store.summaryReport else { return "summarymap: day|journey index" }
            let rows = p[1] == "journey" ? report.journeys : report.days
            let index = Int(num(p, 2))
            guard rows.indices.contains(index) else { return "summarymap: bad index" }
            store.showSummaryOnMainMap(rows[index].id); return "summarymap \(store.summaryFilterSelection != nil)"
        case "summaryfilter":
            store.clearSummaryMapFilter(); return "summaryfilter off"
        case "regions": openRegionsWindow?(); store.ensureRegionReport(); return "regions \(openRegionsWindow != nil)"
        case "regionsmode":
            guard p.count > 1, let m = RegionReport.Mode(rawValue: p[1]) else { return "regionsmode: points|fog" }
            store.pickRegionsMode(m); store.ensureRegionReport(); return "regionsmode \(store.regionsMode.rawValue)"
        case "regionstate": return regionsJSON(store)
        case "regionselect":
            if p.count > 1, p[1] == "off" { store.selectRegion(nil, fly: false); return "regionselect off" }
            guard p.count > 1, let v = Int(p[1]), v >= 0, v <= 0xFFFD, RegionIndex.shared?.region(UInt16(v)) != nil else {
                return "regionselect: no region \(p.count > 1 ? p[1] : "")"
            }
            store.selectRegion(UInt16(v)); return "regionselect \(v)"
        case "regionlookup":
            guard p.count > 2, let la = Double(p[1]), let lo = Double(p[2]) else { return "regionlookup <lat> <lon>" }
            guard let idx = RegionIndex.shared else { return "regionlookup: no index" }
            guard let id = idx.lookup(lat: la, lon: lo) else { return "regionlookup: none" }
            var chain: [String] = []
            var cur: UInt16? = id
            while let c = cur, let r = idx.region(c) { chain.append("\(c):\(r.nameHans)"); cur = idx.parent(of: c) }
            return "regionlookup " + chain.joined(separator: " < ")
        // —— 修改记录窗口 ——
        case "review": store.openChangeLog(); openReviewWindow?(); return "review \(openReviewWindow != nil) preview=\(store.reviewPreview)"
        case "reviewstate": return reviewJSON(store)
        case "reviewselect":
            let list = store.reviewItems
            let i = Int(num(p, 1))
            guard list.indices.contains(i) else { return "reviewselect: no change \(i)" }
            store.reviewSelect(list[i].id); return "reviewselect \(i)"
        case "reviewgoto":     // = 详细页「在主地图上看」
            guard store.reviewSelection != nil else { return "reviewgoto: no selection" }
            store.reviewShowOnMainMap(); return "reviewgoto v=\(store.mapFocusVersion)"
        case "reviewfollow":   // 详细页「主地图跟随」开关（偏好 reviewFollowMap）
            if p.count > 1 { store.reviewFollowMap = p[1] == "1" }
            return "reviewfollow \(store.reviewFollowMap)"
        case "reviewnext": store.reviewStep(1); return "reviewnext"
        case "reviewprev": store.reviewStep(-1); return "reviewprev"
        case "reviewdetail":
            if p.count > 1, p[1] == "off" { store.reviewSelect(nil); return "reviewdetail off" }
            if let id = store.reviewSelection ?? store.reviewItems.first?.id { store.reviewSelect(id) }
            return "reviewdetail on"
        case "reviewrevert":
            let list = store.reviewItems
            let i = Int(num(p, 1))
            guard list.indices.contains(i) else { return "reviewrevert: no change \(i)" }
            store.revertChanges([list[i].id]); return "reviewrevert \(i)"
        case "reviewall": store.revertAllChanges(); return "reviewall"
        case "delete":
            // delete <i0> <i1>：圈选删除 [i0, i1) 这段点（进删除模式 → 暂存 → 直接确认）
            guard let t = store.track else { return "delete: no track" }
            let a = max(0, Int(num(p, 1))), b = min(t.count, Int(num(p, 2)))
            guard b > a else { return "delete: empty range" }
            store.enterDeleteMode()
            store.stagePoints((a..<b).map(Int32.init))
            store.confirmExecuteStaged()
            return "delete \(a)..<\(b)"
        case "batchselect":
            guard let st = store.batch, st.items.indices.contains(Int(num(p, 1))) else { return "batchselect: bad index" }
            store.selectBatchItem(st.items[Int(num(p, 1))].id); return "batchselect ok"
        case "route":
            let src: RouteSource = (p.count > 1 && p[1] == "rail") ? .overpassRail : .osrmCar
            store.requestRouteDraft(src); return "route \(src.rawValue) busy=\(store.fillRouteBusy != nil)"
        case "routeinputs":
            let path = p.count > 1 ? p[1] : (dir?.appendingPathComponent("routeinputs.jsonl").path ?? "routeinputs.jsonl")
            let text = store.routeInputsDump()
            do { try text.write(toFile: path, atomically: true, encoding: .utf8) } catch { return "routeinputs: write failed \(error.localizedDescription)" }
            return "routeinputs \(store.gapCandidates.count) -> \(path)"
        case "notes": return store.currentRouteInputNotes().joined(separator: " | ")
        case "routedump":
            // routedump <path>：把当前单处草稿（顶点）与交叉验证的两份草稿（坐标/长度/依据/警告/说明）写成 JSON
            let path = p.count > 1 ? p[1] : (dir?.appendingPathComponent("routedump.json").path ?? "routedump.json")
            func draftJSON(_ d: RouteDraft) -> [String: Any] {
                ["source": d.source.rawValue, "meters": d.meters, "method": d.method?.rawValue ?? "", "snapA": d.snapA, "snapB": d.snapB,
                 "shiftA": d.shiftA, "shiftB": d.shiftB, "warnings": d.warnings, "notes": d.notes,
                 "coords": d.coords.map { [$0.latitude, $0.longitude] }]
            }
            var obj: [String: Any] = ["anchorA": store.fillAnchorA ?? -1, "anchorB": store.fillAnchorB ?? -1,
                                      "vertices": store.fillVertices.map { [$0.latitude, $0.longitude] },
                                      "points": store.currentFillPoints().map { [$0.lat, $0.lon] }]
            if let x = store.fillCrossDrafts { obj["cross"] = ["agree": x.agree, "shown": draftJSON(x.shown), "other": draftJSON(x.other)] }
            if let r = store.fillRouteInfo { obj["route"] = ["source": r.source.rawValue, "meters": r.meters, "warnings": r.warnings, "notes": r.notes] }
            do {
                let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
                try data.write(to: URL(fileURLWithPath: path))
            } catch { return "routedump: \(error.localizedDescription)" }
            return "routedump -> \(path)"
        case "region":
            // region lat,lon;lat,lon;...  或 region clear
            if p.count > 1, p[1] == "clear" { store.setFillRegion(nil); return "region cleared" }
            let poly = p.dropFirst().joined(separator: " ").split(separator: ";").compactMap { pair -> CLLocationCoordinate2D? in
                let xy = pair.split(separator: ","); guard xy.count == 2, let la = Double(xy[0]), let lo = Double(xy[1]) else { return nil }
                return CLLocationCoordinate2D(latitude: la, longitude: lo)
            }
            store.setFillRegion(poly); return "region \(poly.count) pts → filtered \(store.filteredGapCandidates.count)"
        case "regioninvert": store.fillRegionInvert = p.count > 1 ? p[1] == "1" : !store.fillRegionInvert; return "regioninvert \(store.fillRegionInvert) → filtered \(store.filteredGapCandidates.count)"
        case "chains":
            return store.gapCandidates.enumerated().filter { $0.element.chainCount > 1 }.map { "\($0.offset):x\($0.element.chainCount)/inner\($0.element.innerCount)" }.joined(separator: " ")
        case "jitter":
            // 乱跳候选：序号:tA/内点/大跳/倒退/最大步/弦/隐含速度
            return store.gapCandidates.enumerated().filter { $0.element.kind == .jitter }.map {
                let c = $0.element
                // 时间里的空格换成 T，输出按空格分词
                return String(format: "%d:%@/inner%d/j%d/r%d/max%.0f/m%.0f/v%.0f", $0.offset, TrackStore.batchTimeText(c.tA).replacingOccurrences(of: " ", with: "T"), c.innerCount, c.jitterJumps, c.jitterReversals, c.jitterMaxJump, c.meters, c.kmh)
            }.joined(separator: " ")
        case "findjitter": store.fillJitter = p.count > 1 ? p[1] == "on" : !store.fillJitter; return "findjitter \(store.fillJitter) candidates=\(store.gapCandidates.count)"
        case "replays": return "replays \(store.replayCount)"
        case "cleanreplays":
            // 走真实用户路径：弹确认框 → 点「删除 N 个回放点」
            store.requestCleanReplays(); pump(400)
            if let panel = NSApp.windows.first(where: { $0.isVisible && $0.isSheet }),
               let btn = Self.findButton(in: panel.contentView, titleContains: "回放点") {
                btn.performClick(nil); pump(400)
                return "cleanreplays (click \(btn.title))"
            }
            // 找不到按钮就报错，不做程序化关闭（程序化关 SwiftUI 确认框可能崩，同 confirm）
            return "cleanreplays: button not found"
        case "batchdeleteonly":
            guard p.count > 2, let st = store.batch else { return "batchdeleteonly <GapID|index> 0|1" }
            let exact: GapID?
            if let item = st.items.first(where: { $0.id.description == p[1] }) { exact = item.id }
            else if let i = Int(p[1]), st.items.indices.contains(i) { exact = st.items[i].id }
            else if let time = Double(p[1]) {
                let matches = st.items.filter { abs($0.candidate.tA - time) < 0.01 }
                exact = matches.count == 1 ? matches[0].id : nil
            } else { exact = nil }
            guard let exact else { return "batchdeleteonly: unknown or ambiguous item \(p[1])" }
            store.setBatchDeleteOnly(exact, p[2] == "1"); return "batchdeleteonly \(exact) \(p[2])"
        case "mergechains":
            store.fillMergeChains = p.count > 1 ? p[1] == "on" : !store.fillMergeChains
            return "mergechains \(store.fillMergeChains) candidates=\(store.gapCandidates.count)"
        case "roadonly": store.fillRoadOnly = p.count > 1 ? p[1] == "1" : !store.fillRoadOnly; return "roadonly \(store.fillRoadOnly)"
        case "crosscheck": store.fillCrossCheck = p.count > 1 ? p[1] == "1" : !store.fillCrossCheck; return "crosscheck \(store.fillCrossCheck)"
        case "faketiles":
            // faketiles 0|1：外部底图瓦片不出网，返回程序生成的 z/x/y 图；开时把 tileRequests 清零
            ExternalTileOverlay.fakeTiles = p.count > 1 ? p[1] == "1" : !ExternalTileOverlay.fakeTiles
            if ExternalTileOverlay.fakeTiles { ExternalTileOverlay.resetRequestCount() }
            return "faketiles \(ExternalTileOverlay.fakeTiles) tileRequests=\(ExternalTileOverlay.requestCount)"
        case "tunnels":
            // tunnels 0|1：叠加 OSM 隧道（主窗口 + 审阅窗口共用的偏好）
            store.tunnelOverlay = p.count > 1 ? p[1] == "1" : !store.tunnelOverlay
            return "tunnels \(store.tunnelOverlay)"
        case "faketunnels":
            // faketunnels <n>：注入 n 条视野内的合成隧道 way（不出网）；0 = 关
            TunnelLayer.fakeCount = max(0, Int(num(p, 1)))
            TunnelLayer.registry.values.forEach { $0.invalidate() }
            return "faketunnels \(TunnelLayer.fakeCount)"
        case "tunnelrefresh":
            TunnelLayer.registry.values.forEach { $0.invalidate() }
            return "tunnelrefresh"
        case "tunnelnet":
            // tunnelnet 0|1：自测副本默认不让隧道层出网；1 = 放行真实 Overpass（只在人工验证时用，一次一个客户端）
            TunnelLayer.allowNetwork = p.count > 1 ? p[1] == "1" : !TunnelLayer.allowNetwork
            TunnelLayer.registry.values.forEach { $0.invalidate() }
            return "tunnelnet \(TunnelLayer.allowNetwork)"
        case "mapnotice":
            // mapnotice [0|1]：读/写「外部底图一次性说明已弹过」偏好（与正式版共用；脚本结束要还原）
            if p.count > 1 { ExternalMapNotice.shown = p[1] == "1" }
            return "mapnotice \(ExternalMapNotice.shown ? 1 : 0)"
        case "mapgoto":
            // mapgoto <lat> <lon> <km>：主地图视野置中到坐标、跨度 km（瓦片/隧道层测试用；不动画）
            guard p.count > 3, let mv = (surface as? MapContainerView)?.mapView else { return "mapgoto: lat lon km（主地图未就绪）" }
            guard let lat = Double(p[1]), let lon = Double(p[2]), let km0 = Double(p[3]),
                  abs(lat) <= 85, abs(lon) <= 180, km0 > 0 else { return "mapgoto: 参数非法（|lat| ≤ 85、|lon| ≤ 180、km > 0）" }
            let km = min(max(0.1, km0), 20_000)
            mv.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon), latitudinalMeters: km * 1000, longitudinalMeters: km * 1000), animated: false)
            let r = mv.region
            return String(format: "mapgoto %.4f,%.4f span=%.4f,%.4f", r.center.latitude, r.center.longitude, r.span.latitudeDelta, r.span.longitudeDelta)
        case "fillpoints": store.fillShowPoints = p.count > 1 ? p[1] == "1" : !store.fillShowPoints; projectNow?(); return "fillpoints \(store.fillShowPoints) preview=\(lastOverlay.previewPoints.count)"
        case "batchpick":
            // batchpick <index> osrm|valhalla|straight|none：等你选的那处做决定
            guard p.count > 2, let st = store.batch, st.items.indices.contains(Int(num(p, 1))) else { return "batchpick <index> osrm|valhalla|straight|none" }
            let pick: TrackStore.BatchPick = p[2] == "valhalla" ? .source(.valhallaCar) : (p[2] == "straight" ? .straight : (p[2] == "none" ? .none : .source(.osrmCar)))
            store.resolveBatchConflict(st.items[Int(num(p, 1))].id, pick)
            return "batchpick \(String(describing: store.batch?.items[Int(num(p, 1))].status))"
        case "batchswap":
            guard let st = store.batch, st.items.indices.contains(Int(num(p, 1))) else { return "batchswap <index>" }
            store.swapBatchCross(st.items[Int(num(p, 1))].id); return "batchswap \(store.batch?.items[Int(num(p, 1))].draft?.source.rawValue ?? "nil")"
        case "batchnextconflict": store.selectBatchNextConflict(); return "batchnextconflict selected=\(store.batch?.selectedID?.description ?? "none")"
        case "batchreview": store.openBatchPreview(); openReviewWindow?(); return "batchreview preview=\(store.reviewPreview) items=\(store.reviewItems.count)"
        case "reviewinclude":
            // reviewinclude <i> 0|1：预览模式里第 i 项落不落地
            let list = store.reviewItems; let i = Int(num(p, 1))
            guard list.indices.contains(i), p.count > 2 else { return "reviewinclude <i> 0|1" }
            store.setPreviewIncluded(list[i].id, p[2] == "1"); return "reviewinclude \(i) \(store.reviewItems[i].previewIncluded)"
        case "reviewmap":
            // reviewmap standard|imagery|hybrid|osm|topo|esri [light 0|1]
            if p.count > 1 { store.reviewMapStyle = Self.baseMapStyle(p[1]) }
            if p.count > 3, p[2] == "light" { store.reviewLightMap = p[3] == "1" }
            return "reviewmap \(store.reviewMapStyle.rawValue) light=\(store.reviewLightMap)"
        case "toastdismiss": store.dismissToast(); return "toastdismiss"
        case "batchincludeall": store.setBatchIncludeAllDone(); return "batchincludeall included=\(store.batch?.includedCount ?? -1)"
        case "batchstraightall":
            if let st = store.batch { for it in st.items where it.status.isFailed && it.kind == .road { store.setBatchStraight(it.id, true) } }
            return "batchstraightall included=\(store.batch?.includedCount ?? -1)"
        case "batchuncheck": store.setBatchIncludeMethod(.direct, false); return "batchuncheck direct included=\(store.batch?.includedCount ?? -1)"
        case "batchacceptunverified": store.acceptUnverifiedAll(); return "batchacceptunverified unverified=\(store.batch?.unverifiedCount ?? -1)"
        case "crosstol":
            // crosstol <米>|off：覆盖交叉验证容差（设很小 → 真实数据必出分歧；设很大 → 全部一致）
            if p.count > 1, p[1] != "off", let v = Double(p[1]) { RouteCrossCheck.toleranceOverride = v } else { RouteCrossCheck.toleranceOverride = nil }
            return "crosstol \(RouteCrossCheck.tolerance)"
        case "riskthreshold":
            // riskthreshold <n>|off：临时改落地前自检的 high 门槛（分 > n 为 high）；已有批次不重算，新评估生效
            if p.count > 1, p[1] != "off", let v = Int(p[1]) { FillPlausibility.highThresholdOverride = v } else { FillPlausibility.highThresholdOverride = nil }
            return "riskthreshold \(FillPlausibility.highThresholdOverride ?? FillPlausibility.Thresholds.current.highFrom)"
        case "replay":
            // replay <录音目录>|off：公路引擎的 HTTP 按考卷录音回放（不出网；找不到录音的请求按传输失败处理）
            if p.count > 1, p[1] != "off" { RouteReplay.mode = .replay(p[1]) } else { RouteReplay.mode = nil }
            store.routeCache.clear()
            return "replay \(RouteReplay.mode.map { String(describing: $0) } ?? "off")"
        case "fakeroute":
            // fakeroute <osrm|valhalla|all> <ok|offset <m>|noroute|fail|slow <ms>|off>：假引擎，不联网（测两路一致/不一致/只一路/都失败/停用）
            guard p.count > 2 else { return "fakeroute <osrm|valhalla|all> <ok|offset m|noroute|fail|slow ms|off>" }
            let targets: [RoadNetwork.RouteEngine] = p[1] == "all" ? [.osrm, .valhalla] : [p[1] == "valhalla" ? .valhalla : .osrm]
            let mode: String? = p[2] == "off" ? nil : (p.count > 3 ? "\(p[2]) \(p[3])" : p[2])
            for t in targets { Self.fakeModes[t] = mode }
            Self.installFakeRoutes()
            store.routeCache.clear()      // 换了假引擎 = 换了"服务器"：旧结果作废，否则同样输入会命中上一种假模式的草稿
            return "fakeroute " + [RoadNetwork.RouteEngine.osrm, .valhalla].map { "\(RoadNetwork.name($0))=\(Self.fakeModes[$0] ?? "real")" }.joined(separator: " ")
        case "routecross": store.requestCrossCheckedDraft(); return "routecross busy=\(store.fillRouteBusy != nil)"
        case "routerefetch": store.refetchRouteDraft(); return "routerefetch busy=\(store.fillRouteBusy != nil)"
        case "routecache":
            // routecache stats|clear：路网结果缓存（按文件）的条目数与命中数
            if p.count > 1, p[1] == "clear" { store.routeCache.clear(); return "routecache cleared" }
            let s = store.routeCache.stats
            return "entries=\(s.entries) hits=\(s.hits)"
        case "batchrefetch":
            // batchrefetch all|<i>：忽略缓存重取全部（= 重跑第 2 步）/ 只重取第 i 项
            guard p.count > 1 else { return "batchrefetch all|<index>" }
            if p[1] == "all" { store.refetchBatchAll(); return "batchrefetch all phase=\(String(describing: store.batch?.phase))" }
            guard let st = store.batch, let i = Int(p[1]), st.items.indices.contains(i) else { return "batchrefetch: bad index" }
            store.refetchBatchItem(st.items[i].id)
            return "batchrefetch \(i) status=\(String(describing: store.batch?.items[i].status))"
        case "batchrecross":
            // batchrecross all|<i>：「只有一路结果」的项两路重取（忽略缓存）；非 unverified 项不动
            guard p.count > 1 else { return "batchrecross all|<index>" }
            if p[1] == "all" { let n = store.recrossUnverifiedAll(); return "batchrecross all started=\(n)" }
            guard let st = store.batch, let i = Int(p[1]), st.items.indices.contains(i) else { return "batchrecross: bad index" }
            let ok = store.recrossBatchItem(st.items[i].id)
            return "batchrecross \(i) started=\(ok) status=\(String(describing: store.batch?.items[i].status))"
        case "reviewdraft":
            // reviewdraft osrm|valhalla|next|default：修改记录详细页显示哪一份草稿
            guard p.count > 1 else { return "reviewdraft osrm|valhalla|next|default" }
            switch p[1] {
            case "next": store.reviewShowNextDraft()
            case "default": store.reviewShowDraft(nil)
            default: store.reviewShowDraft(p[1] == "valhalla" ? .valhallaCar : .osrmCar)
            }
            let c = store.reviewSelection.flatMap { store.reviewItem($0) }
            return "reviewdraft shown=\(c.flatMap { TrackStore.reviewShownDraft($0, preferred: store.reviewShownSource) }?.source.rawValue ?? "none")"
        case "routeswap": store.swapCrossDraft(); return "routeswap shown=\(store.fillCrossDrafts?.shown.source.rawValue ?? "none")"
        case "batchskipsparse": return "batchskipsparse \(store.setBatchSparse(.skip))"
        case "tripmap": store.resolveTripsByMap(force: p.count > 1 && p[1] == "force"); return "tripmap running=\(store.tripMapRunning)"
        case "autotripmap": Self.autoTripMap = p.count > 1 ? p[1] == "1" : !Self.autoTripMap; return "autotripmap \(Self.autoTripMap)"
        case "tripsamples":
            return store.trips.map { t in
                let e = store.tripMap[t.index]
                let rows = (e?.samples ?? []).map { s in
                    let v = (s.index < (store.track?.speedKmh.count ?? 0)) ? (store.track?.speedKmh[s.index] ?? 0) : 0
                    return String(format: "#%d v=%.0f road=%@ rail=%@", s.index, v, s.road.map { String(format: "%.0f", $0) } ?? "nil", s.rail.map { $0 >= 1e8 ? "none" : String(format: "%.0f", $0) } ?? "nil")
                }.joined(separator: "; ")
                return "行程\(t.index + 1): " + rows
            }.joined(separator: "\n")
        case "trip":
            // trip <序号从 1> road|rail|skip|auto
            guard p.count > 2, let k = Int(p[1]), store.trips.indices.contains(k - 1) else { return "trip: bad index" }
            store.setTripKind(k - 1, p[2] == "auto" ? nil : BatchKind(rawValue: p[2])); return "trip \(k) → \(store.tripKind(store.trips[k - 1])?.rawValue ?? "nil")"
        case "riskpopover":    // riskpopover 1|0：打开/关上单处卡片（或补点操作条）上的落地前自检徽标弹窗
            NotificationCenter.default.post(name: RiskBadge.hookOpen, object: p.count > 1 ? p[1] == "1" : true); return "riskpopover"
        case "batchriskonly":  // 批量表格「只看要看一眼的」（与 只看有疑点的 / 只看要你选的 互斥）
            let on = p.count > 1 ? p[1] == "1" : !store.batchRiskOnly
            store.batchRiskOnly = on
            if on { store.batchWarnedOnly = false; store.batchConflictOnly = false }
            return "batchriskonly \(store.batchRiskOnly) visible=\(store.batch.map { store.batchVisibleRows($0).count } ?? -1)"
        case "batchcompact":
            let on = p.count > 1 ? p[1] == "1" : !store.batchCompact
            // 卡片要有「当前这处」才显示（真实入口都是点行进来的）：没选中时先选第一处，和点第一行等价
            if on, let st = store.batch, st.selectedID == nil, let first = st.items.first { store.selectBatchItem(first.id) }
            store.batchCompact = on; return "batchcompact \(store.batchCompact)"
        case "mainwin":
            let mw = store.mainWindow.map { "\($0.title) \($0.frame)" } ?? "nil"
            let all = NSApp.windows.map { "[\($0.title)|vis=\($0.isVisible)|w=\(Int($0.frame.width))]" }.joined()
            return "mainWindow=\(mw) all=\(all)"
        case "movewin":
            // movewin <标题子串> <x> <y>：直接 setFrameOrigin，立刻回读（看 SwiftUI 场景是否允许程序改位置）
            guard p.count > 3, let w = NSApp.windows.first(where: { $0.title.contains(p[1]) }), let x = Double(p[2]), let y = Double(p[3]) else { return "movewin: bad args" }
            w.setFrameOrigin(NSPoint(x: x, y: y))
            return "movewin now=\(Int(w.frame.minX)),\(Int(w.frame.minY))"
        case "resizewin":     // resizewin <标题子串> <宽> <高>：保持左上角改窗口外框尺寸
            guard p.count > 3, let w = NSApp.windows.first(where: { $0.isVisible && $0.title.contains(p[1]) }), let ww = Double(p[2]), let hh = Double(p[3]) else { return "resizewin: bad args" }
            w.setFrame(NSRect(x: w.frame.minX, y: w.frame.maxY - hh, width: ww, height: hh), display: true)
            return "resizewin now=\(Int(w.frame.width))x\(Int(w.frame.height))"
        case "screens":
            return NSScreen.screens.map { "frame=\($0.frame) visible=\($0.visibleFrame)" }.joined(separator: " | ")
        case "openbatch":
            guard let f = openBatchWindow else { return "openbatch: no handler" }
            f(); return "openbatch"
        case "closebatchwin":     // = 点批量窗口的红色关闭按钮（批次留着）
            guard let w = NSApp.window(scene: SceneID.batchFill), w.isVisible else { return "closebatchwin: no window" }
            w.performClose(nil); return "closebatchwin"
        case "windows":
            return NSApp.windows.filter { $0.isVisible }.map { w in
                let f = w.frame; return "\(w.title.isEmpty ? "(无标题)" : w.title): x=\(Int(f.minX)) y=\(Int(f.minY)) w=\(Int(f.width)) h=\(Int(f.height)) id=\(w.identifier?.rawValue ?? "-")"
            }.joined(separator: " | ") + " || \(store.lastDockInfo)"
        case "shotwin":
            // shotwin <标题子串…> <文件名>：CGWindowList 截某个窗口（标题可含空格：最后一个词是路径，中间全是标题）
            guard p.count > 2 else { return "shotwin: title path" }
            let title = p[1..<(p.count - 1)].joined(separator: " "), out = p[p.count - 1]
            // 标题前加 "+"（如 `shotwin +批量补点 x.png`）：连同本 app 打开着的 popover 小窗一起截（只截本进程的这几个窗口，不截别的 app）
            let withPopovers = title.hasPrefix("+"), t = withPopovers ? String(title.dropFirst()) : title
            guard let w = NSApp.windows.first(where: { $0.isVisible && $0.title.contains(t) }) else { return "shotwin: no window" }
            let cgImg: CGImage?
            if withPopovers {
                let pops = NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
                let ids = (pops + [w]).map { CGWindowID($0.windowNumber) }
                var ptrs: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }   // CFArray 里直接放 CGWindowID 值（不是对象）
                guard pops.count > 0, let arr = CFArrayCreate(kCFAllocatorDefault, &ptrs, ptrs.count, nil) else { return "shotwin: popovers=\(pops.count)" }
                cgImg = CGImage(windowListFromArrayScreenBounds: .null, windowArray: arr, imageOption: [.bestResolution])
            } else {
                cgImg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.bestResolution])
            }
            guard let cg = cgImg else { return "shotwin: capture failed" }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let png = rep.representation(using: .png, properties: [:]) else { return "shotwin: png failed" }
            do { try png.write(to: URL(fileURLWithPath: out)) } catch { return "shotwin: write failed \(error.localizedDescription)" }
            return "shotwin \(cg.width)x\(cg.height) -> \(out)"
        case "batchnext": store.selectBatchNeighbor(p.count > 1 ? Int(p[1]) ?? 1 : 1); return "batchnext selected=\(store.batch?.selectedID?.description ?? "none")"
        case "topology":
            guard let t = store.track else { return "{}" }
            var result: [String: Any] = ["segments": t.topology.segments.count, "count": t.count,
                                         "renderer": topologyStats?() ?? [:]]
            if t.count <= 256 {
                result["segmentID"] = (0..<t.count).map { Int(t.topology.segment(of: $0)) }
                result["order"] = (0..<t.count).map { t.topology.globalIndex(atPathRank: $0) }
                result["lineEdges"] = t.topology.lineRuns.flatMap { run in
                    run.dropLast().map { [t.topology.globalIndex(atPathRank: $0), t.topology.globalIndex(atPathRank: $0 + 1)] }
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), let json = String(data: data, encoding: .utf8) else { return "{}" }
            return json
        case "state": projectNow?(); return stateJSON(store)
        case "debug": return debugInfo?() ?? "no debugInfo"
        case "lang": return Self.langReport()
        case "relaunch": AppLanguage.relaunch(); return "relaunch requested"   // 和设置页「立即重启」同一入口（测试重启是否真的起来）
        case "setlang":
            // setlang <zh-Hans|zh-Hant|en|de|…|system>：和设置面板同一个 AppLanguage.apply，不重启（重启后才生效）。
            // 注意：测试副本与 /Applications 那份同 bundle id、同一个容器 plist——测完要 setlang system 还原
            guard p.count > 1 else { return "setlang: <code|system>" }
            let l: AppLanguage
            if p[1] == "system" { l = .system }
            else if let m = AppLanguage.match(p[1]) { l = m }
            else { return "setlang: unknown \(p[1])" }
            AppLanguage.apply(l)
            return "setlang \(l == .system ? "system" : l.rawValue) → " + Self.langReport()
        case "info":
            guard let w = window else { return "info: no window" }
            return "active=\(NSApp.isActive) hidden=\(NSApp.isHidden) key=\(w.isKeyWindow) visible=\(w.isVisible) mini=\(w.isMiniaturized) onActiveSpace=\(w.isOnActiveSpace) occl=\(w.occlusionState.rawValue) screen=\(w.screen?.frame ?? .zero) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")"
        case "shot": return shot(to: p.count > 1 ? p[1] : "shot.png")
        case "shotview":
            // 锁屏/遮挡时窗口截图是空白：改用视图树离屏渲染（SwiftUI 覆盖层/面板正常，MapKit 底图可能是黑的）
            guard let w = window, let root = w.contentView else { return "shotview: no window" }
            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return "shotview: rep failed" }
            root.cacheDisplay(in: root.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return "shotview: png failed" }
            let path = p.count > 1 ? p[1] : "shotview.png"
            do { try png.write(to: URL(fileURLWithPath: path)); return "shotview \(rep.pixelsWide)x\(rep.pixelsHigh) -> \(path)" }
            catch { return "shotview: \(error)" }
        case "shotviewwin":
            // shotviewwin <标题子串…> <文件>：任意窗口的视图树离屏渲染（锁屏时 shotwin 全白）；标题可含空格
            guard p.count > 2 else { return "shotviewwin: title path" }
            let title = p[1..<(p.count - 1)].joined(separator: " "), out = p[p.count - 1]
            guard let w = NSApp.windows.first(where: { $0.isVisible && $0.title.contains(title) }), let root = w.contentView else { return "shotviewwin: no window" }
            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return "shotviewwin: rep failed" }
            root.cacheDisplay(in: root.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return "shotviewwin: png failed" }
            do { try png.write(to: URL(fileURLWithPath: out)); return "shotviewwin \(rep.pixelsWide)x\(rep.pixelsHigh) -> \(out)" }
            catch { return "shotviewwin: \(error)" }
        case "down", "up", "move", "click", "rclick", "dbl", "drag":
            return mouse(c, p)
        case "key":
            return key(p)
        case "sleep":
            RunLoop.main.run(until: Date().addingTimeInterval(Double(num(p, 1)) / 1000))
            return "slept"
        case "front":
            NSApp.activate(ignoringOtherApps: true)
            window?.orderFrontRegardless()
            window?.makeKey()
            return "front key=\(window?.isKeyWindow ?? false) occluded=\(!(window?.occlusionState.contains(.visible) ?? false))"
        case "place":
            // 放到第 i 块屏幕的可见区域中央并置前（被遮挡的窗口 MapKit 不动画也不重绘）
            guard let w = window else { return "place: no window" }
            let i = Int(num(p, 1))
            guard NSScreen.screens.indices.contains(i) else { return "place: no screen \(i)" }
            let v = NSScreen.screens[i].visibleFrame
            let size = NSSize(width: min(1320, v.width), height: min(860, v.height))
            w.setFrame(NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height), display: true)
            NSApp.activate(ignoringOtherApps: true)
            w.orderFrontRegardless()
            w.makeKey()
            return "place \(w.frame) key=\(w.isKeyWindow) occluded=\(!w.occlusionState.contains(.visible))"
        case "frame":
            // 屏幕坐标（左下原点）：frame x y w h
            guard let w = window else { return "frame: no window" }
            w.setFrame(NSRect(x: num(p, 1), y: num(p, 2), width: num(p, 3), height: num(p, 4)), display: true)
            return "frame \(w.frame)"
        default: return "unknown \(c)"
        }
    }

    /// lang：本 app 持久域里存的覆盖（stored）、启动时的快照（launch）、启动参数里的 -AppleLanguages（arg，
    /// 参数域压过存储的选择）、实际生效的列表首项（effective）、Locale.current 与 bundle 实际选中的本地化
    private static func langReport() -> String {
        func code(_ l: AppLanguage) -> String { l == .system ? "system" : l.rawValue }
        let args = ProcessInfo.processInfo.arguments
        let arg = args.firstIndex(of: "-AppleLanguages").flatMap { i in args.indices.contains(i + 1) ? args[i + 1] : nil } ?? "-"
        let effective = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first ?? "-"
        return "lang stored=\(code(AppLanguage.stored)) launch=\(code(AppLanguage.launchSnapshot)) arg=\(arg) effective=\(effective) locale=\(Locale.current.identifier) bundle=\(Bundle.main.preferredLocalizations.first ?? "-") live=\(String(localized: "地区统计")) names=\(RegionIndex.nameLanguage)"
    }

    /// 地区统计：索引是否就位、报告（国家 → 下级嵌套，按指标降序）、选中与高亮多边形数
    private func summaryJSON(_ store: TrackStore) -> String {
        func row(_ r: SummaryRow) -> [String: Any] {
            ["id": r.id, "start": r.startTime, "end": r.endTime,
             "points": r.metrics.pointCount, "synthetic": r.metrics.syntheticPointCount,
             "retimed": r.metrics.retimedPointCount, "recordedMeters": r.metrics.recordedMeters,
             "estimatedMeters": r.metrics.estimatedMeters, "excludedEdges": r.metrics.excludedEdgeCount,
             "observedSeconds": r.metrics.observedSeconds, "unknownSeconds": r.metrics.unknownSeconds,
             "regionsAvailable": r.geography.available,
             "candidates": r.transport.candidates.map(\.rawValue),
             "manual": store.summaryTransportOverrides[r.id]?.rawValue ?? "auto"]
        }
        var data: [String: Any] = [
            "open": store.summaryWindowOpen, "busy": store.summaryBusy,
            "ready": store.summaryReport != nil, "error": store.summaryError ?? "",
            "builds": store.summaryBuildCount, "fwdb": store.fwdbActive,
            "source": store.summarySourceID?.uuidString ?? "",
            "sources": store.summarySources.map { ["id": $0.id.uuidString, "name": $0.name] },
            "mapDisabled": store.summaryMapUnavailableReason ?? "",
            "filterChip": store.summaryFilterSelection != nil
        ]
        data["list"] = store.summaryShowsJourneys ? "journey" : "day"
        data["selectedDay"] = store.summaryDateNavigation.selectedDay?.isoDescription ?? ""
        data["draftDay"] = store.summaryDateNavigation.draftDay.isoDescription
        data["draftEdited"] = store.summaryDateNavigation.draftEdited
        data["navigationRevision"] = store.summaryDateNavigation.revision
        data["dateHint"] = store.summaryDateNavigation.hint?.rawValue ?? ""
        data["fromMainRange"] = store.summaryDateNavigation.fromMainRange
        data["currentDay"] = store.currentSummaryDayRow.map(row) ?? [:]
        data["currentDayJourneys"] = store.currentSummaryDayJourneys.map(row)
        data["currentJourney"] = store.currentSummaryJourney.map(row) ?? [:]
        if let frame = summaryFilterFrame, let size = surface?.window?.contentView?.bounds.size {
            data["filterChipRendered"] = frame.width > 0 && frame.height > 0
                && frame.intersects(CGRect(origin: .zero, size: size))
        } else { data["filterChipRendered"] = false }
        if let r = store.summaryReport {
            data["track"] = r.trackID.uuidString; data["reportSource"] = r.sourceID.uuidString
            data["zone"] = r.timeZoneIdentifier; data["totalPoints"] = r.totalPointCount
            data["undatedPoints"] = r.undatedPointCount
            data["days"] = r.days.map(row); data["journeys"] = r.journeys.map(row)
        }
        if let f = store.viewFilter { data["filterStart"] = f.start; data["filterEnd"] = f.end }
        data["filterPoints"] = store.visibleIndexRange().len
        guard let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func settingsJSON(_ store: TrackStore) -> String {
        let id = Bundle.main.bundleIdentifier ?? ""
        let domain = UserDefaults.standard.persistentDomain(forName: id) ?? [:]
        // Deliberately limited to the relevant language/idle preference keys.
        let keys = ["AppleLanguages", "idleDisabled", "idleGlobeSeconds", "idleMapSeconds"]
        var values: [String: Any] = [:]
        for key in keys { values[key] = domain[key] ?? NSNull() }
        let data: [String: Any] = ["bundleID": id, "home": NSHomeDirectory(), "temporaryDirectory": NSTemporaryDirectory(),
            "storedLanguage": AppLanguage.stored.rawValue, "launchLanguage": AppLanguage.launchSnapshot.rawValue,
            "locale": Locale.current.identifier, "preferredLocalizations": Bundle.main.preferredLocalizations,
            "idleDisabled": store.settings.idleDisabled, "idleGlobeSeconds": store.settings.idleGlobeSeconds,
            "idleMapSeconds": store.settings.idleMapSeconds, "persistent": values,
            "argumentLanguages": UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["AppleLanguages"] ?? NSNull()]
        guard let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func regionsJSON(_ store: TrackStore) -> String {
        guard let idx = RegionIndex.shared else { return "{\"index\":false}" }
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "\"", with: "'") }
        var s = "{\"index\":true,\"regions\":\(idx.regions.count),\"mode\":\"\(store.regionsMode.rawValue)\",\"modes\":[\(store.regionModesAvailable.map { "\"\($0.rawValue)\"" }.joined(separator: ","))],"
        s += "\"selection\":\(store.regionSelection.map(String.init) ?? "null"),\"highlightPolys\":\(regionOverlayCount),"
        guard let rep = store.regionReport else { return s + "\"ready\":false}" }
        func node(_ id: UInt16) -> String {
            let st = rep.stats[id] ?? RegionStat(id: id)
            guard let r = idx.region(id) else { return "{}" }
            let kids = rep.visitedChildren(of: id, idx)
            return "{\"id\":\(id),\"name\":\"\(esc(r.nameHans))\",\"localizedName\":\"\(esc(r.localizedName))\",\"level\":\(r.level),\"iso\":\"\(r.iso2)\",\"points\":\(st.points),\"days\":\(st.days),\"timed\":\(st.firstTime.isFinite),\"cells\":\(st.cells),\"km2\":\(String(format: "%.6f", st.km2)),\"lv\":\(st.level),\"areaKm2\":\(String(format: "%.1f", r.areaKm2)),\"childTotal\":\(idx.children[id]?.count ?? 0),\"children\":[\(kids.map(node).joined(separator: ","))]}"
        }
        s += "\"ready\":true,\"totalPoints\":\(rep.totalPoints),\"totalCells\":\(rep.totalCells),\"unassignedPoints\":\(rep.unassignedPoints),\"unassignedCells\":\(rep.unassignedCells),"
        s += "\"countries\":[\(rep.countries(idx).map(node).joined(separator: ","))]}"
        return s
    }

    /// 底图名 → 样式：先按 rawValue（标准/卫星/混合/OpenStreetMap/OpenTopoMap/Esri 影像），再按英文短名；认不出回标准
    static func baseMapStyle(_ s: String) -> BaseMapStyle {
        if let v = BaseMapStyle(rawValue: s) { return v }
        switch s.lowercased() {
        case "imagery", "satellite": return .imagery
        case "hybrid": return .hybrid
        case "osm", "openstreetmap": return .osm
        case "topo", "opentopomap": return .topo
        case "esri": return .esri
        default: return .standard
        }
    }

    /// 落地前自检字段（items / route / reviewstate 共用）：`"risk":N,"riskLevel":"low|medium|high","riskReasons":[...]`；没有评估全为 null/[]
    static func riskJSON(_ p: FillPlausibility?) -> String {
        guard let p else { return "\"risk\":null,\"riskLevel\":null,\"riskReasons\":[]" }
        let reasons = p.reasons.map { "\"" + $0.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ") + "\"" }.joined(separator: ",")
        return "\"risk\":\(p.risk),\"riskLevel\":\"\(p.level.rawValue)\",\"riskReasons\":[\(reasons)]"
    }

    private func gapIDJSON(_ id: GapID?) -> String {
        id.map { "\"" + $0.description + "\"" } ?? "null"
    }
    private func stateJSON(_ store: TrackStore) -> String {
        func pts(_ a: [CGPoint]) -> String {
            "[" + a.map { $0.x.isFinite ? String(format: "[%.1f,%.1f]", $0.x, $0.y) : "null" }.joined(separator: ",") + "]"
        }
        func pt(_ a: CGPoint?) -> String { a.map { String(format: "[%.1f,%.1f]", $0.x, $0.y) } ?? "null" }
        let o = lastOverlay
        let w = window
        let content = (surface ?? w?.contentView)?.bounds.size ?? .zero
        var s = "{"
        s += "\"loading\":\(store.isLoading),\"points\":\(store.track?.count ?? 0),"
        s += "\"fillMode\":\(store.fillMode),\"fillActive\":\(store.fillActive),"
        s += "\"anchorA\":\(store.fillAnchorA.map(String.init) ?? "null"),\"anchorB\":\(store.fillAnchorB.map(String.init) ?? "null"),"
        s += "\"vertexCount\":\(store.fillVertices.count),\"sources\":[\(store.fillVertexSources.map { $0.map(String.init) ?? "null" }.joined(separator: ","))],"
        s += "\"history\":\(store.fillVertexHistory.count),\"dragging\":\(store.fillDragging),\"candidates\":\(store.gapCandidates.count),"
        s += "\"removeCount\":\(store.fillRemoveCount),\"prompt\":\(store.fillPrompt != nil),\"promptKeep\":\(store.fillPrompt?.keep ?? -1),\"promptInsert\":\(store.fillPrompt?.insert ?? -1),\"promptRetimed\":\(store.fillPrompt?.retimed ?? -1),\"fills\":\(store.fills.count),"
        s += "\"toast\":" + (store.toast.map { "\"" + $0.text.replacingOccurrences(of: "\"", with: "'") + "\"" } ?? "null") + ","
        s += "\"routeBusy\":\(store.fillRouteBusy.map { "\"\($0.rawValue)\"" } ?? "null"),\"crossCheck\":\(store.fillCrossCheck),"
        s += "\"cross\":" + (store.fillCrossDrafts.map { "{\"agree\":\($0.agree),\"shown\":\"\($0.shown.source.rawValue)\",\"other\":\"\($0.other.source.rawValue)\",\"otherMeters\":\(Int($0.other.meters))}" } ?? "null") + ","
        if let st = store.batch {
            let items = st.items.map { it -> String in
                let status: String
                switch it.status { case .pending: status = "pending"; case .running: status = "running"; case .done: status = "done"; case .failed(let w): status = "failed:" + w.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " "); case .notTunnel(let w): status = "nottunnel:" + w.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " "); case .conflict(let k): status = k == .disagree ? "conflict:disagree" : "conflict:unverified"; case .skipped: status = "skipped" }
                let cross = it.cross.map { $0.agree ? "agree" : "disagree" } ?? (it.status.isUnverified ? "unverified" : "none")
                let crossNum = it.cross.map { String(format: "\"coverage\":%.3f,\"maxDev\":%.0f,\"diverge\":%.0f,\"lenO\":%.0f,\"lenV\":%.0f,", $0.coverage, $0.maxDev, $0.divergence, $0.lenP, $0.lenQ) } ?? "\"coverage\":null,\"maxDev\":null,\"diverge\":null,\"lenO\":null,\"lenV\":null,"
                let routes = it.crossDrafts.map { x in "{\"engine\":\"\(x.source == .osrmCar ? "osrm" : "valhalla")\",\"meters\":\(Int(x.meters)),\"method\":\"\(x.method?.rawValue ?? "")\",\"warnings\":\(x.warnings.count),\"shiftA\":\(x.shiftA),\"shiftB\":\(x.shiftB)}" }.joined(separator: ",")
                func optNum(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "null" }
                let ck = it.candidate.kind == .staleClock ? "stale" : (it.candidate.kind == .jitter ? "jitter" : "tgap")
                return "{\"id\":\(gapIDJSON(it.id)),\"kind\":\(it.kind.map { "\"\($0.rawValue)\"" } ?? "null"),\"auto\":\(it.autoKind.map { "\"\($0.rawValue)\"" } ?? "null"),\"status\":\"\(status)\",\"meters\":\(Int(it.draft?.meters ?? -1)),\"warnings\":\(it.draft?.warnings.count ?? 0),\"shiftA\":\(it.draft?.shiftA ?? 0),\"shiftB\":\(it.draft?.shiftB ?? 0),\"include\":\(it.willLand),\"straight\":\(it.useStraight),\"deleteOnly\":\(it.landsDeleteOnly),\"ckind\":\"\(ck)\",\"inner\":\(it.candidate.innerCount),\"nature\":\(it.sampling.map { "\"\($0.nature.rawValue)\"" } ?? "null"),\"method\":\"\(it.draft?.method?.rawValue ?? "")\",\"source\":\"\(it.draft?.source.rawValue ?? "")\",\"cross\":\"\(cross)\",\"routes\":[\(routes)],\"picked\":\(it.userPicked),\"declined\":\(it.declined),\(crossNum)\"wIn\":\(optNum(it.candidate.windowSpeedInKmh)),\"wOut\":\(optNum(it.candidate.windowSpeedOutKmh)),\(Self.riskJSON(it.plausibility))}"
            }
            let byHost = st.requestsByHost.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
            let disabled = st.engineDisabled.map { "\"" + $0.replacingOccurrences(of: "\"", with: "'") + "\"" } ?? "null"
            // 批量窗口外框尺寸 [宽, 高]（整数，含标题栏）；窗口没开为 null
            let bw = NSApp?.window(scene: SceneID.batchFill).flatMap { $0.isVisible ? $0.frame : nil }
            let winSize = bw.map { "[\(Int($0.width.rounded())),\(Int($0.height.rounded()))]" } ?? "null"
            s += "\"batch\":{\"phase\":\"\(st.phase)\",\"compact\":\(store.batchCompact),\"windowSize\":\(winSize),\"cardContentHeight\":\(Int(store.batchCardContentHeight.rounded())),\"riskOnly\":\(store.batchRiskOnly),\"warnedOnly\":\(store.batchWarnedOnly),\"conflictOnly\":\(store.batchConflictOnly),\"visibleCount\":\(store.batchVisibleRows(st).count),\"dock\":\"\(store.lastDockInfo)\",\"selected\":\(gapIDJSON(st.selectedID)),\"resolving\":\(store.batchResolving),\"unresolved\":\(st.uncertainUnresolved),\"included\":\(st.includedCount),\"requests\":\(st.requestsMade),\"requestsByHost\":{\(byHost)},\"cacheHits\":\(st.cacheHits),\"crossCheck\":\(store.fillCrossCheck),\"engineDisabled\":\(disabled),\"counts\":{\"agree\":\(st.agreeCount),\"disagree\":\(st.disagreeCount),\"unverified\":\(st.unverifiedCount),\"pending\":\(st.pendingPickCount),\"declined\":\(st.declinedCount),\"high\":\(st.highRiskCount),\"medium\":\(st.mediumRiskCount)},\"progress\":\"\(st.progressText.replacingOccurrences(of: "\"", with: "'"))\",\"lines\":\(lastOverlay.batchLines.count),\"lineLabels\":\(TrackStore.FillOverlay.engineLabels(lastOverlay.batchLines).count),\"items\":[\(items.joined(separator: ","))]},"
        } else { s += "\"batch\":null," }
        let rc = store.routeCache.stats
        s += "\"routeCache\":{\"entries\":\(rc.entries),\"hits\":\(rc.hits)},"
        s += "\"routeProgress\":" + (store.fillRouteProgress.map { "\"" + $0.replacingOccurrences(of: "\"", with: "'") + "\"" } ?? "null") + ","
        s += "\"routeProgressDetail\":" + (store.fillRouteProgressDetail.map { "\"" + $0.replacingOccurrences(of: "\"", with: "'") + "\"" } ?? "null") + ",\"crossLegs\":\(store.fillCrossLegStatus),\"netRequests\":\(RoadNetwork.RateLimiter.shared.countSnapshot),\"replayHits\":\(RouteReplay.replayHits),\"replayMisses\":\(RouteReplay.replayMisses),"
        s += "\"route\":" + (store.fillRouteInfo.map { "{\"source\":\"\($0.source.rawValue)\",\"endpoint\":\"\($0.endpoint)\",\"vertices\":\($0.vertexCount),\"meters\":\(Int($0.meters)),\"edited\":\($0.edited),\"warnings\":\($0.warnings.count),\"shiftA\":\($0.shiftA),\"shiftB\":\($0.shiftB),\"snapA\":\(Int($0.snapA)),\"snapB\":\(Int($0.snapB)),\(Self.riskJSON($0.edited ? nil : $0.plausibility)),\"notes\":[\($0.notes.map { "\"" + $0.replacingOccurrences(of: "\"", with: "'") + "\"" }.joined(separator: ","))]}" } ?? "null") + ","
        let prof = store.samplingProfile
        let kindName: String
        switch prof?.kind { case .deviceLogger?: kindName = "deviceLogger"; case .phone?: kindName = "phone"; case .unknown?: kindName = "unknown"; case nil: kindName = "" }
        s += "\"profile\":" + (prof.map { String(format: "{\"kind\":\"%@\",\"medianDt\":%.1f,\"medianStep\":%.0f,\"q90Step\":%.0f,\"accuracy\":%@,\"radius\":%.0f,\"creator\":\"%@\"}", kindName, $0.medianDt, $0.medianStep, $0.q90Step, $0.accuracy.map { String(format: "%.0f", $0) } ?? "null", $0.matchRadius, $0.creator.replacingOccurrences(of: "\"", with: "'")) } ?? "null") + ","
        s += "\"spacing\":\(Int(store.fillSpacingMeters)),\"spacingManual\":\(store.fillSpacingManual),\"showPoints\":\(store.fillShowPoints),\"previewPoints\":\(lastOverlay.previewPoints.count),"
        var perTrip: [Int: Int] = [:]
        for c in store.gapCandidates { if let tr = store.trip(for: c) { perTrip[tr.index, default: 0] += 1 } }
        s += "\"trips\":[" + store.trips.map { t in
            let n = perTrip[t.index] ?? 0
            let e = store.tripMap[t.index]
            return String(format: "{\"i\":%d,\"km\":%.0f,\"v50\":%.0f,\"v95\":%.0f,\"auto\":%@,\"kind\":%@,\"gaps\":%d,\"mapRail\":%d,\"mapRoad\":%d,\"mapN\":%d,\"mapVerdict\":%@}", t.index + 1, t.km, t.v50, t.v95,
                          t.autoKind.map { "\"\($0.rawValue)\"" } ?? "null", store.tripKind(t).map { "\"\($0.rawValue)\"" } ?? "null", n,
                          e?.railVotes ?? -1, e?.roadVotes ?? -1, e?.answered ?? 0, e?.verdict.map { "\"\($0.rawValue)\"" } ?? "null")
        }.joined(separator: ",") + "],"
        s += "\"tripMapRunning\":\(store.tripMapRunning),"
        s += "\"filtered\":\(store.filteredGapCandidates.count),\"region\":\(store.fillRegion?.count ?? 0),\"regionInvert\":\(store.fillRegionInvert),\"roadOnly\":\(store.fillRoadOnly),"
        s += "\"mergeChains\":\(store.fillMergeChains),\"chains\":\(store.gapCandidates.filter { $0.chainCount > 1 }.count),"
        s += "\"refreshing\":\(store.candidatesRefreshing),\"findJitter\":\(store.fillJitter),\"jitter\":\(store.gapCandidates.filter { $0.kind == .jitter }.count),\"replays\":\(store.replayCount),\"replayPrompt\":\(store.replayPrompt != nil),"
        s += "\"nature\":" + (store.fillSampling.map { "\"\($0.nature.rawValue)\"" } ?? "null") + ",\"tau\":" + (store.fillSampling?.tau.map { String(format: "%.1f", $0) } ?? "null") + ",\"tauN\":\(store.fillSampling?.count ?? 0),"
        s += "\"localStep\":" + (store.fillLocalStep.map { String(format: "[%.0f,%.0f]", $0.meters, $0.dt) } ?? "null") + ","
        s += "\"error\":" + (store.errorMessage.map { "\"" + $0.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ") + "\"" } ?? "null") + ","
        s += "\"content\":[\(Int(content.width)),\(Int(content.height))],"
        s += "\"hover\":" + (store.hover.map { String(format: "{\"index\":%d,\"x\":%.1f,\"y\":%.1f}", $0.index, $0.screenPoint.x, $0.screenPoint.y) } ?? "null") + ","
        s += "\"filterLen\":\(store.viewFilter == nil ? -1 : store.visibleIndexRange().len),\"trackLine\":\(store.settings.showTrackLine),\"multiSeg\":\(store.track?.isMultiSegment ?? false),"
        s += "\"changes\":\(store.changes.count),\"activeChanges\":\(store.activeChanges.count),\"bodyEvals\":\(ContentView.bodyEvaluations),"
        s += "\"regionsReady\":\(store.regionReport != nil),\"regionSelection\":\(store.regionSelection.map(String.init) ?? "null"),\"regionsIndex\":\(RegionIndex.shared != nil),"
        s += "\"network\":" + (NetworkHealth.shared.summary.map { "\"" + $0.replacingOccurrences(of: "\"", with: "'") + "\"" } ?? "null") + ",\"offline\":\(NetworkHealth.shared.offline),"
        s += "\"baseMap\":\"\(store.settings.mapStyle.rawValue)\",\"tileRequests\":\(ExternalTileOverlay.requestCount),\"fakeTiles\":\(ExternalTileOverlay.fakeTiles),"
        s += "\"attribution\":" + (store.settings.mapStyle.tileSource.map { "\"" + $0.attribution.replacingOccurrences(of: "\"", with: "'") + "\"" } ?? "null") + ","
        s += "\"tunnelOverlay\":" + (TunnelLayer.registry["main"]?.hookJSON ?? "null") + ","
        s += "\"overlay\":{\"a\":\(pt(o.anchorA)),\"b\":\(pt(o.anchorB)),\"vertices\":\(pts(o.vertices)),\"midpoints\":\(pts(o.midpoints)),\"inner\":\(pts(o.inner)),\"preview\":\(pts(o.preview)),\"departure\":\(pts(Array(o.departure.prefix(4)))),\"dragging\":\(o.dragging.map(String.init) ?? "null")}"
        s += "}"
        return s
    }

    /// 修改记录窗口状态：各处修改（按轨迹顺序）、页/选中、合成轨迹点数、地图可见范围
    private func reviewJSON(_ store: TrackStore) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "\"", with: "'") + "\"" }
        let list = store.reviewItems
        let items = list.enumerated().map { i, c -> String in
            let b = c.bbox
            let base = String(format: "{\"i\":%d,\"kind\":\"%@\",\"added\":%d,\"removed\":%d,\"reverted\":%@,\"lat\":%.6f,\"lon\":%.6f,\"bbox\":[%.6f,%.6f,%.6f,%.6f],\"trackTime\":%@,\"place\":%@",
                          i, c.kind.rawValue, c.netAdded, c.netRemoved, c.reverted ? "true" : "false",   // 净新增 / 真删掉（不含改时点）
                          c.center.latitude, c.center.longitude, b.minLat, b.minLon, b.maxLat, b.maxLon,
                          c.trackTime.map { String(format: "%.0f", $0) } ?? "null",
                          store.reviewPlaces[c.id].map { q($0 + " " + (store.reviewFlags[c.id] ?? "")) } ?? "null")
            let drafts = c.drafts.map { "\"\($0.source.rawValue)\"" }.joined(separator: ",")
            return base + ",\"retimed\":\(c.retimed),\"included\":\(c.previewIncluded),\"pending\":\(c.previewPending),\"declined\":\(c.previewDeclined),\"unverified\":\(c.previewUnverified),\"straight\":\(c.straight),\"source\":\"\(c.routeSource?.rawValue ?? "")\",\"drafts\":[\(drafts)],\"cross\":\(c.cross.map { $0.agree ? "\"agree\"" : "\"disagree\"" } ?? "null"),\"warnings\":\(c.drafts.reduce(0) { $0 + $1.warnings.count }),\(Self.riskJSON(c.plausibility))}"
        }
        let sel = store.reviewSelection.flatMap { id in list.firstIndex { $0.id == id } } ?? -1
        let box = store.reviewVisibleBox?()
        let selChange = store.reviewSelection.flatMap { store.reviewItem($0) }
        let shownDraft = selChange.flatMap { TrackStore.reviewShownDraft($0, preferred: store.reviewShownSource) }?.source.rawValue
        let sameGeometry = selChange.map { TrackStore.reviewSameGeometry($0) } ?? false
        var s = "{\"detail\":\(store.reviewDetail),\"selected\":\(sel),\"building\":\(store.reviewBuilding),\"preview\":\(store.reviewPreview),\"mapStyle\":\"\(store.reviewMapStyle.rawValue)\",\"light\":\(store.reviewLightMap),"
        s += "\"followMap\":\(store.reviewFollowMap),"
        s += "\"shownDraft\":" + (shownDraft.map { "\"\($0)\"" } ?? "null") + ",\"sameGeometry\":\(sameGeometry),"
        s += "\"baseMap\":\"\(store.reviewMapStyle.rawValue)\",\"attribution\":" + (store.reviewMapStyle.tileSource.map { "\"" + $0.attribution.replacingOccurrences(of: "\"", with: "'") + "\"" } ?? "null") + ","
        // 审阅地图只在有记录/预览项时存在；没地图时给出偏好值、state "noMap"
        s += "\"tunnelOverlay\":" + (TunnelLayer.registry["review"]?.hookJSON ?? "{\"on\":\(store.tunnelOverlay),\"ways\":0,\"state\":\"noMap\",\"lastError\":null}") + ","
        s += "\"reviewPoints\":\(store.reviewTrack?.count ?? -1),\"trackPoints\":\(store.track?.count ?? 0),\"fills\":\(store.fills.count),\"loading\":\(store.isLoading),"
        s += "\"visible\":" + (box.map { String(format: "[%.6f,%.6f,%.6f,%.6f]", $0.0, $0.1, $0.2, $0.3) } ?? "null") + ","
        let mr = store.mainMapRegion?()
        s += "\"mainMapCenter\":" + (mr.map { String(format: "[%.6f,%.6f]", $0.lat, $0.lon) } ?? "null") + ",\"mainMapSpanKm\":" + (mr.map { String(format: "%.3f", $0.spanKm) } ?? "null") + ","
        s += "\"changes\":[" + items.joined(separator: ",") + "]}"
        return s
    }

    /// 自己截自己的窗口（CGWindowListCreateImage 对本进程窗口不需要屏幕录制权限）；失败则退回 cacheDisplay
    private func shot(to path: String) -> String {
        guard let w = window, let cv = surface ?? w.contentView else { return "shot: no window" }
        var cg: CGImage?
        if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
            // 裁掉标题栏：contentView 在窗口里的位置
            let scale = w.backingScaleFactor
            let contentRectInWindow = cv.convert(cv.bounds, to: nil)     // 窗口坐标（左下原点）
            let top = (w.frame.height - contentRectInWindow.maxY) * scale
            let crop = CGRect(x: contentRectInWindow.minX * scale, y: top,
                              width: contentRectInWindow.width * scale, height: contentRectInWindow.height * scale)
            cg = img.cropping(to: crop) ?? img
        }
        if cg == nil, let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
            cv.cacheDisplay(in: cv.bounds, to: rep)
            cg = rep.cgImage
        }
        guard let cg else { return "shot: capture failed" }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return "shot: png failed" }
        do { try png.write(to: URL(fileURLWithPath: path)); return "shot \(cg.width)x\(cg.height) -> \(path)" }
        catch { return "shot: \(error)" }
    }

    private func post(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        guard let w = window, let cv = surface ?? w.contentView else { return }
        // 容器左上原点（容器是 flipped）→ 窗口坐标（左下原点）
        let inContent = CGPoint(x: x, y: cv.isFlipped ? y : cv.bounds.height - y)
        let loc = cv.convert(inContent, to: nil)
        eventNumber += 1
        guard let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: flags,
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: w.windowNumber, context: nil,
                                         eventNumber: eventNumber, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        NSApp.postEvent(e, atStart: false)
    }

    private func pump(_ ms: Double) { RunLoop.main.run(until: Date().addingTimeInterval(ms / 1000)) }
    /// 视图树里找标题含某文字的按钮（确认框的按钮是 NSAlert 面板里的 NSButton）
    private static func findButton(in view: NSView?, titleContains text: String) -> NSButton? {
        guard let view else { return nil }
        if let b = view as? NSButton, b.title.contains(text) { return b }
        for sub in view.subviews { if let b = findButton(in: sub, titleContains: text) { return b } }
        return nil
    }

    private static func findDatePicker(in view: NSView?) -> NSDatePicker? {
        guard let view else { return nil }
        if let picker = view as? NSDatePicker { return picker }
        for child in view.subviews { if let picker = findDatePicker(in: child) { return picker } }
        return nil
    }

    private func mouse(_ c: String, _ p: [String]) -> String {
        projectNow?(); pump(30)
        let x = num(p, 1), y = num(p, 2)
        let flags: NSEvent.ModifierFlags = p.contains("opt") ? [.option] : []
        switch c {
        case "move": post(.mouseMoved, x, y, flags: flags)
        case "down": post(.leftMouseDown, x, y, flags: flags)
        case "up": post(.leftMouseUp, x, y, flags: flags)
        case "click":
            post(.mouseMoved, x, y, flags: flags); pump(30)
            post(.leftMouseDown, x, y, flags: flags); pump(40); post(.leftMouseUp, x, y, flags: flags); pump(60)
        case "dbl":
            post(.mouseMoved, x, y); pump(30)
            post(.leftMouseDown, x, y, clicks: 1); pump(30); post(.leftMouseUp, x, y, clicks: 1); pump(60)
            post(.leftMouseDown, x, y, clicks: 2); pump(30); post(.leftMouseUp, x, y, clicks: 2); pump(60)
        case "rclick":
            post(.mouseMoved, x, y); pump(30)
            post(.rightMouseDown, x, y); pump(40); post(.rightMouseUp, x, y); pump(60)
        case "drag":
            let x2 = num(p, 3), y2 = num(p, 4)
            let steps = max(2, Int(num(p, 5) > 0 ? num(p, 5) : 10))
            post(.mouseMoved, x, y); pump(30)
            post(.leftMouseDown, x, y); pump(50)
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                post(.leftMouseDragged, x + (x2 - x) * t, y + (y2 - y) * t); pump(25)
            }
            pump(40); post(.leftMouseUp, x2, y2); pump(80)
        default: break
        }
        pump(120)
        projectNow?()
        return "\(c) \(x),\(y)"
    }

    private func key(_ p: [String]) -> String {
        guard let w = window, p.count > 1 else { return "key: ?" }
        let ch = p[1]
        let flags: NSEvent.ModifierFlags = p.contains("cmd") ? [.command] : []
        let code: UInt16 = ch == "esc" ? 53 : (ch == "z" ? 6 : 0)
        let chars = ch == "esc" ? "\u{1B}" : ch
        guard let d = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code),
              let u = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return "key: build failed" }
        NSApp.postEvent(d, atStart: false); pump(30); NSApp.postEvent(u, atStart: false); pump(120)
        return "key \(ch)"
    }
}

//
//  RoadNetwork.swift
//  GPXPointViewer
//
//  路网草稿（第二期）：把断档两端交给公共 OpenStreetMap 服务，拿回一条沿路网的折线当作顶点草稿，
//  用户在此基础上手动微调。两个来源都要在界面上标明：
//  - 公路：OSRM 路由（FOSSGIS 公共实例 routing.openstreetmap.de，备用 router.project-osrm.org），
//    带两端行进方向约束（bearings）防止吸到对向车道；
//  - 铁路：Overpass 取包围盒内的 OSM 铁路几何，自己在图上做最短路（公共路由器都没有铁路 profile）。
//  数据 © OpenStreetMap contributors（ODbL）。只在用户点击时请求，同一时刻最多一个请求。
//

import Foundation
import CoreLocation
import Network
import simd

// MARK: - 网络状况（联网的几处都要能告诉用户"网络不好"）

/// 两类信号：系统网络路径（NWPathMonitor：离线 / 受限）+ 实际请求结果（最近几次失败、超时、很慢）。
/// 独立小对象，只有横幅视图观察它
@MainActor final class NetworkHealth: ObservableObject {
    static let shared = NetworkHealth()
    @Published private(set) var offline = false
    @Published private(set) var constrained = false            // 低数据模式 / 蜂窝热点等受限网络
    @Published private(set) var summary: String?               // nil = 正常；否则一句大白话
    struct Outcome { let host: String; let ok: Bool; let seconds: Double; let at: Date; let detail: String }
    private(set) var recent: [Outcome] = []
    private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let off = path.status != .satisfied, cons = path.isConstrained || path.isExpensive
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.offline = off; self.constrained = cons
                self.refresh()
            }
        }
        m.start(queue: DispatchQueue.global(qos: .utility))
        monitor = m
    }
    /// 任何线程可调：记一次请求结果（跳回主线程再写）
    nonisolated static func note(host: String, ok: Bool, seconds: Double, detail: String = "") {
        Task { @MainActor in NetworkHealth.shared.add(Outcome(host: host, ok: ok, seconds: seconds, at: Date(), detail: detail)) }
    }
    private var refreshScheduled = false
    private func add(_ o: Outcome) {
        recent.append(o)
        if recent.count > 40 { recent.removeFirst(recent.count - 40) }
        // 合并发布：批量运行时每秒几次请求结果，逐次发布会让观察它的整棵视图树每次重算；1.5 s 汇总一次，且只在文案变了才发
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }
    /// 慢的门槛：路网 /route 正常 0.6 s、/match 被节流到 7–9 s；Overpass 正常就要排队 30–60 s；地名查询正常 1 s 内
    private static func slowThreshold(_ host: String) -> Double {
        if host.contains("overpass") { return 150 }
        if host == "geocode" { return 10 }
        return 15
    }
    private func refresh() {
        let new = computeSummary()
        if new != summary { summary = new }
    }
    /// 立刻重算（自测钩子注入请求结果后用；正常路径走 1.5 s 合并）
    func flushNow() { refreshScheduled = false; refresh() }
    /// 自测钩子：同步记一次结果并立刻重算（note 是异步跳回主线程的）
    func inject(host: String, ok: Bool, seconds: Double, detail: String = "") {
        recent.append(Outcome(host: host, ok: ok, seconds: seconds, at: Date(), detail: detail))
        if recent.count > 40 { recent.removeFirst(recent.count - 40) }
        flushNow()
    }
    private func computeSummary() -> String? {
        if offline { return String(localized: "当前离线：取路网草稿、地图判段、地名查询都需要联网", comment: "Network banner: the Mac is offline; lists the features that need the internet (road draft, map-based gap classification, place-name lookup)") }
        let now = Date()
        let window = recent.filter { now.timeIntervalSince($0.at) < 180 }      // 只看最近 3 分钟
        let last = Array(window.suffix(6))
        let fails = last.filter { !$0.ok }
        let slow = last.filter { $0.ok && $0.seconds > Self.slowThreshold($0.host) }
        if last.count >= 2, fails.count >= 2, let f = fails.last {
            let why = f.detail.isEmpty ? f.host : f.detail
            return String(localized: "网络不好：最近 \(last.count) 次请求 \(fails.count) 次失败（\(why)）；联网的功能可能取不到结果，可稍后重试", comment: "Network banner. 1st = number of recent requests, 2nd = how many of them failed, 3rd = last failure reason or host name")
        } else if slow.count >= 2, let s = slow.last {
            return String(localized: "网络慢：最近请求要 \(s.seconds, format: Fmt.f0) 秒才有回应（正常 1 秒内），联网的功能会很慢", comment: "Network banner. %@ = seconds the last slow request took to answer")
        } else if constrained, last.isEmpty {
            return String(localized: "当前是受限网络（低数据模式 / 热点），联网的功能可能很慢", comment: "Network banner: constrained network (Low Data Mode / personal hotspot)")
        } else {
            return nil
        }
    }
    nonisolated static func describe(_ error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .timedOut: return String(localized: "超时", comment: "Network failure reason (request timed out), shown in the network banner and failure lists")
            case .notConnectedToInternet: return String(localized: "没有网络", comment: "Network failure reason: not connected to the internet")
            case .cannotFindHost, .dnsLookupFailed: return String(localized: "找不到服务器", comment: "Network failure reason: server host not found / DNS failed")
            case .cannotConnectToHost: return String(localized: "连不上服务器", comment: "Network failure reason: cannot connect to the server")
            case .networkConnectionLost: return String(localized: "连接中断", comment: "Network failure reason: connection lost")
            case .secureConnectionFailed: return String(localized: "安全连接失败", comment: "Network failure reason: TLS/secure connection failed")
            default: return u.localizedDescription
            }
        }
        if let c = error as? CLError, c.code == .network { return String(localized: "地名服务没有网络", comment: "Network failure reason: Apple place-name (reverse geocoding) service has no network") }
        return error.localizedDescription
    }
}

enum RouteSource: String, Codable {
    case osrmCar
    case valhallaCar
    case overpassRail
    /// 乱跳簇的本地判定：不取路径，只删区间内的乱跳点（两锚点太近 / 隐含速度不合理时）
    case deleteOnly

    var label: String {
        switch self {
        case .osrmCar: return String(localized: "OSRM 公路", comment: "Road-draft source label: road route from the OSRM router (keep OSRM untranslated)")
        case .valhallaCar: return String(localized: "Valhalla 公路", comment: "Road-draft source label: road route from the Valhalla router (keep Valhalla untranslated)")
        case .overpassRail: return String(localized: "Overpass 铁路", comment: "Road-draft source label: rail geometry from the Overpass API (keep Overpass untranslated)")
        case .deleteOnly: return String(localized: "只删点", comment: "Road-draft source label: no route fetched, only the jitter points inside the gap are deleted")
        }
    }
    var detail: String {
        switch self {
        case .osrmCar: return String(localized: "OSRM 路由 · routing.openstreetmap.de（FOSSGIS）/ router.project-osrm.org · OpenStreetMap 公路数据", comment: "Road-draft source details (help text). Keep host names, OSRM, FOSSGIS and OpenStreetMap untranslated")
        case .valhallaCar: return String(localized: "Valhalla 路由 · valhalla1.openstreetmap.de（FOSSGIS，与 OSRM 不同机器）· OpenStreetMap 公路数据", comment: "Road-draft source details (help text): Valhalla runs on a different FOSSGIS machine than OSRM. Keep host names and product names untranslated")
        case .overpassRail: return String(localized: "Overpass API（overpass-api.de 及镜像）· OpenStreetMap 铁路几何 + 本地最短路", comment: "Rail-draft source details (help text): Overpass API (overpass-api.de and mirrors), OSM rail geometry + local shortest path. Keep host names untranslated")
        case .deleteOnly: return String(localized: "本地判定：乱跳簇两锚点太近或隐含速度不合理，不取路径，只删区间内的乱跳点", comment: "Delete-only source details (help text): decided locally because the two anchors of a jitter cluster are too close or the implied speed is implausible")
        }
    }
    static var attribution: String { String(localized: "数据 © OpenStreetMap contributors", comment: "Map data attribution line. Translate only 数据 (Data); keep \"© OpenStreetMap contributors\" exactly") }
}

/// 草稿采用的取路方式（批量窗口「依据」列）。rawValue 是冻结的 ASCII 标识（钩子 JSON / 测试脚本按它比较），
/// 界面显示用 label
enum RouteMethod: String {
    case match = "match"
    case context = "context"
    case constraint = "constraint"
    case direct = "direct"
    case rail = "rail"
    case deleteOnly = "deleteOnly"

    var label: String {
        switch self {
        case .match: return String(localized: "匹配", comment: "Route method (batch window 依据 column, notes): OSRM map matching of the real points around the gap. Glossary: Match")
        case .context: return String(localized: "上下文", comment: "Route method: routed from a real point ~150 m before A to one after B, then clipped. Glossary: Context")
        case .constraint: return String(localized: "约束", comment: "Route method: A→B route constrained by the travel direction at both ends. Glossary: Constrained")
        case .direct: return String(localized: "直接", comment: "Route method: plain A→B route without direction constraint. Glossary: Direct")
        case .rail: return String(localized: "铁路", comment: "Route method / kind: rail (Overpass rail geometry). Glossary: Rail")
        case .deleteOnly: return String(localized: "删点", comment: "Route method: delete the jitter points only, no route. Same key as the 删点 toggle. Glossary: Delete Only")
        }
    }

    /// 公路取路内部的候选名（匹配 / 上下文 / 约束 / 直接）→ 方式；认不出的返回 nil
    init?(candidateName: String) {
        switch candidateName {
        case "匹配": self = .match
        case "上下文": self = .context
        case "约束": self = .constraint
        case "直接": self = .direct
        default: return nil
        }
    }
}

struct RouteDraft {
    let source: RouteSource
    let coords: [CLLocationCoordinate2D]   // 不含两端锚点，WGS-84
    let meters: Double                     // 路网路径长度
    let snapA: Double                      // 锚点到路网起点的距离（米）
    let snapB: Double
    let endpoint: String                   // 实际用的服务器
    var warnings: [String]
    /// 判断依据（给用户看的）：比较了哪些候选、各自绕路比、采用了哪个、匹配半径多少
    var notes: [String] = []
    /// 采用的取路方式：匹配 / 上下文 / 约束 / 直接 / 铁路 / 删点（批量窗口「依据」列）；nil = 未知
    var method: RouteMethod? = nil
    /// 隧道口定位漂移：锚点往外挪了几个点（0 = 没挪）。挪了之后 anchorA/anchorB 是新锚点坐标，
    /// 调用方要把补点区间也扩到新锚点（被跳过的漂移点随区间一起替换）
    var shiftA: Int = 0
    var shiftB: Int = 0
    var anchorA: CLLocationCoordinate2D? = nil
    var anchorB: CLLocationCoordinate2D? = nil
    /// 锚点到路的残余偏移（米）：末端已用渐进靠拢消化
    var residualA: Double = 0
    var residualB: Double = 0
    /// 末端渐进靠拢实际用的偏移（米）：taper 没触发为 0。远大于 residual 时说明起止段几何不是路网（伪影信号）
    var taperA: Double = 0
    var taperB: Double = 0
    /// 取路过程中有候选请求传输失败（非 failFast 时照样选出结果，只是少了对照）：结果不完整，不进路网缓存，下次照常重请求
    var partial: Bool = false
    /// 路网原始折线（clip 的输出、trimEnds/taper 之前；直接/约束候选 = 原始几何）：落地前自检量「补点离路网多远」的基准
    var rawCoords: [CLLocationCoordinate2D] = []
    /// 采用候选 A–B 段沿途的道路（OSRM steps / Valhalla maneuvers 的 ref/name）；没带回来为空
    var legs: [RouteLeg] = []
    /// 上下文路由里 A 之前 / B 之后那一步所在的道路（= 真实轨迹两侧所在的路）；直接/约束/匹配候选为 nil
    var roadBeforeA: RouteLeg? = nil
    var roadAfterB: RouteLeg? = nil
    /// A–B 段里隧道（OSRM intersections.classes 含 "tunnel"）长度占原始折线弧长的比例 0…1；
    /// nil = 未知（Valhalla、铁路、回复里没有 intersections 的旧录音）。落地前自检用（FillPlausibility）
    var tunnelShare: Double? = nil
}

enum RouteError: LocalizedError {
    case allEndpointsFailed([String])
    /// partial = 虽然有端点明确回答了"没路"，但同时有候选请求传输失败：答案不完整，不进路网缓存
    case noRoute(String, partial: Bool = false)
    case badResponse(String)
    case tooFar(Double)
    case noRailNearby(Double, Double)
    case noRailPath
    /// 铁路：不像隧道断档（路径里隧道占比太低——更像车厢里没信号），不补
    case railNotTunnel(share: Double, meters: Double)
    /// 铁路：断档太长（直线 / 时长），分不清是隧道还是车厢屏蔽，不补
    case railTooLong(km: Double, seconds: Double)
    /// 铁路：拿不准（隧道之间露天太长没点、路径可疑、像停站），按用户要求不补
    case railUnsure(String)
    var isRailSkip: Bool { switch self { case .railNotTunnel, .railTooLong, .railUnsure: return true; default: return false } }

    var errorDescription: String? {
        switch self {
        case .railNotTunnel(let share, let meters):
            let km = meters / 1000, pct = share * 100
            return String(localized: "不像隧道：这段铁路路径 \(km, format: Fmt.f1) km 里隧道只占 \(pct, format: Fmt.f0)%，更像车厢里收不到信号；不补，需要的话从 gpx.studio 导", comment: "Rail gap not filled. 1st = rail path length in km, 2nd = tunnel share in percent (followed by a literal %). Keep gpx.studio untranslated")
        case .railTooLong(let km, let seconds):
            let minutes = seconds / 60
            return String(localized: "断档太长（直线 \(km, format: Fmt.f0) km / \(minutes, format: Fmt.f0) 分钟），分不清是隧道还是车厢屏蔽；不补", comment: "Rail gap not filled. 1st = straight-line distance in km, 2nd = gap duration in minutes")
        case .railUnsure(let why): return String(localized: "拿不准，不补：\(why)", comment: "Rail gap not filled because the result is uncertain. %@ = reason (a complete sentence)")
        case .allEndpointsFailed(let errs):
            let list = errs.joined(separator: String(localized: "list.semicolon", defaultValue: "；", comment: "Separator between entries of an error list (Chinese full-width semicolon; en/de \"; \")"))
            return String(localized: "路网服务不可用：\(list)", comment: "Routing failed on every server. %@ = per-server error entries (host, method, reason)")
        case .noRoute(let s, _): return String(localized: "路网没有找到路径（\(s)）", comment: "Routing error. %@ = reason, e.g. no drivable road near the anchor")
        case .badResponse(let s): return String(localized: "路网响应无法解析：\(s)", comment: "Routing error: the server response could not be parsed. %@ = detail")
        case .tooFar(let km): return String(localized: "断档直线 \(km, format: Fmt.f0) km，太长了，先用锚点分段再取路网", comment: "Routing error. %@ = straight-line gap length in km; the user should split the gap with anchors first")
        case .noRailNearby(let dA, let dB):
            // dA/dB 可能是 +∞（包围盒里一条铁路都没有）：沿用旧 String(format: "%.0f") 的 "inf"，zh-Hans 输出逐字不变
            let ma = dA.isFinite ? dA.formatted(Fmt.f0) : "inf", mb = dB.isFinite ? dB.formatted(Fmt.f0) : "inf"
            return String(localized: "两端附近没有铁路（A 最近 \(ma) m，B 最近 \(mb) m）", comment: "Rail routing error. 1st = distance from anchor A to the nearest railway in m, 2nd = same for anchor B (may be \"inf\")")
        case .noRailPath: return String(localized: "包围盒内的铁路连不通两端（可能缺数据或要绕出包围盒）", comment: "Rail routing error: the railways inside the bounding box do not connect both ends (missing data, or the path leaves the box)")
        }
    }
}

enum RoadNetwork {
    /// 全局请求限速：同一主机至少间隔 1.2 s（FOSSGIS 实测比"每秒 1 次"更严，两条请求流并发几分钟就封 IP），
    /// 并统计实际发出的请求数（批量窗口显示）
    actor RateLimiter {
        static let shared = RateLimiter()
        private var lastByHost: [String: Date] = [:]
        private var cooldownUntil: [String: Date] = [:]     // 429/5xx 之后该主机的冷却截止（所有调用方共用）
        private var cooldownStreak: [String: Int] = [:]
        /// 请求计数（跨隔离域读写，自己加锁）：总数 + 按主机
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            private var byHost: [String: Int] = [:]
            func increment(_ host: String) { lock.lock(); n += 1; byHost[host, default: 0] += 1; lock.unlock() }
            func reset() { lock.lock(); n = 0; byHost = [:]; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
            var perHost: [String: Int] { lock.lock(); defer { lock.unlock() }; return byHost }
        }
        nonisolated let counter = Counter()
        private var inFlight: Set<String> = []

        /// 同一主机同一时刻只许一个在途请求 + 请求之间 ≥ minInterval + 429/5xx 后的冷却期：
        /// 批量用两个引擎并行、精确模式两个 worker 同打一台主机时，每台公共服务器看到的仍是"一个客户端、1 秒 1 次"
        /// （FOSSGIS 对并发客户端会封 IP）。actor 可重入：检查与占位必须在同一个同步段里完成，睡醒后要重新检查，
        /// 不能先占槽再睡（那样两个调用方会同时放行）
        /// 主机在 429/5xx 冷却期内（精确模式 failFast 时直接抛，不等）
        struct HostCooling: LocalizedError {
            let host: String
            let seconds: Double
            var errorDescription: String? { String(localized: "\(host) 刚被限流，冷却中（还有 \(seconds, format: Fmt.f0) s），这一路先放弃", comment: "Routing error (precise mode): the server rate-limited us and is in a cool-down; this leg is abandoned. Placeholders: host name, remaining seconds") }
        }
        func perform<T: Sendable>(host: String, minInterval: TimeInterval = 1.05, failIfCooling: Bool = false, _ op: @Sendable () async throws -> T) async throws -> T {
            while true {
                try Task.checkCancellation()
                if failIfCooling, let until = cooldownUntil[host], until > Date() { throw HostCooling(host: host, seconds: until.timeIntervalSinceNow) }
                if !inFlight.contains(host) {
                    let earliest = max((lastByHost[host] ?? .distantPast).addingTimeInterval(minInterval), cooldownUntil[host] ?? .distantPast)
                    let wait = earliest.timeIntervalSinceNow
                    if wait <= 0 { inFlight.insert(host); break }
                    try await Task.sleep(nanoseconds: UInt64(min(wait, 5) * 1e9))     // 睡醒重检：冷却可能被别的调用延长
                } else {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            counter.increment(host)
            defer { inFlight.remove(host); lastByHost[host] = Date() }
            // 结果记进网络状况：传输失败 / 超时 / HTTP 429、5xx 算失败，耗时也记（界面据此提示"网络不好"）；取消不记
            let t0 = Date()
            do {
                let r = try await op()
                var ok = true, detail = ""
                if let (_, resp) = r as? (Data, URLResponse), let h = resp as? HTTPURLResponse, h.statusCode == 429 || h.statusCode >= 500 {
                    ok = false; detail = String(localized: "HTTP \(h.statusCode)（服务端限流/过载）", comment: "Network failure reason. %lld = HTTP status code (429 or 5xx): server rate-limited / overloaded")
                    noteOverload(host: host, retryAfter: h.value(forHTTPHeaderField: "Retry-After"))
                } else {
                    cooldownStreak[host] = 0
                }
                NetworkHealth.note(host: host, ok: ok, seconds: Date().timeIntervalSince(t0), detail: detail)
                return r
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as URLError where e.code == .cancelled {
                throw e
            } catch {
                NetworkHealth.note(host: host, ok: false, seconds: Date().timeIntervalSince(t0), detail: NetworkHealth.describe(error))
                throw error
            }
        }
        /// 429/5xx：该主机冷却 max(服务器 Retry-After, 指数退避 10·2^(n−1) s 封顶 120 s)；成功一次复位。
        /// Retry-After 可以是秒数或 HTTP 日期（RFC 7231）
        private func noteOverload(host: String, retryAfter: String?) {
            let streak = (cooldownStreak[host] ?? 0) + 1
            cooldownStreak[host] = streak
            var server = 0.0
            if let ra = retryAfter?.trimmingCharacters(in: .whitespaces), !ra.isEmpty {
                if let secs = Double(ra) { server = max(0, secs) }
                else {
                    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
                    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    if let d = f.date(from: ra) { server = max(0, d.timeIntervalSinceNow) }
                }
            }
            let backoff = min(120, 10 * pow(2, Double(streak - 1)))
            cooldownUntil[host] = Date().addingTimeInterval(max(server, backoff))
        }
        /// 该主机是否在冷却中（精确模式：429 之后立即停用该引擎，不再累计）
        func cooling(_ host: String) -> Bool { (cooldownUntil[host] ?? .distantPast) > Date() }
        nonisolated var countSnapshot: Int { counter.value }
        nonisolated var perHostSnapshot: [String: Int] { counter.perHost }
        nonisolated func resetCount() { counter.reset() }
    }

    /// 带时间的轨迹点（地图匹配用）
    struct TracePoint { var coord: CLLocationCoordinate2D; var time: Double; var index: Int = -1 }
    /// 锚点外侧的真实点（隧道口漂移判定用）：从锚点往外数第 k 个，离锚点沿轨迹多少米、多少秒
    struct PortalSample { var index: Int; var coord: CLLocationCoordinate2D; var meters: Double; var seconds: Double }

    // router.project-osrm.org 只是 routing.openstreetmap.de 的 CNAME（同一台机器），不是真正的备用
    static let carEndpoints = [
        "https://routing.openstreetmap.de/routed-car/route/v1/driving/",
    ]
    static let overpassEndpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://lz4.overpass-api.de/api/interpreter",
        "https://z.overpass-api.de/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
    ]
    static let maxStraightKm = 80.0
    /// /match 是否带 waypoints 参数（见 fetchMatch）。实验：不带时外侧点匹配不上不会拖垮整次匹配
    static var useMatchWaypoints = false

    static let session: URLSession = makeSession(timeout: 25)
    /// Overpass 公共实例常排队 30–60 s（实测 37 s 才回），超时要给够
    static let overpassSession: URLSession = makeSession(timeout: 60)

    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout + 30
        c.httpAdditionalHeaders = ["User-Agent": "GPXPointViewer/1.0 (personal GPX tunnel gap filling; macOS)",
                                   "Accept": "application/json"]
        return URLSession(configuration: c)
    }

    // MARK: 公路（OSRM）

    /// bearingA = 进入 A 的行进方向，bearingB = 离开 B 的行进方向（度，北 0 顺时针）；nil 则不约束
    /// 进度回调：请求到哪一步了（界面显示；主线程由调用方保证）
    typealias Progress = @Sendable (String) -> Void

    /// 一次 OSRM 查询的结果
    /// 路线的一步及它在几何上的起点位置（沿路由自身的 distance 累计，米）
    struct RouteStep { var leg: RouteLeg; var startMeters: Double }
    struct OSRMAnswer {
        var coords: [CLLocationCoordinate2D]
        var meters: Double
        var snapA: Double
        var snapB: Double
        /// 沿途道路（steps=true / maneuvers）；服务没给为空
        var steps: [RouteStep] = []
        /// 后处理前的几何（trimEnds 之前；上下文候选 = clip 输出）。nil = 与 coords 相同
        var rawCoords: [CLLocationCoordinate2D]? = nil
        /// 上下文候选裁剪时记下的 A 之前 / B 之后那一步
        var roadBeforeA: RouteLeg? = nil
        var roadAfterB: RouteLeg? = nil
        /// 隧道段（OSRM intersections.classes 含 tunnel）；nil = 未知（Valhalla / 回复里没有 intersections）
        var tunnelSpans: [(CLLocationCoordinate2D, CLLocationCoordinate2D)]? = nil
    }
    /// OSRM legs[].steps[] → RouteStep（ref/name；distance 累计）
    static func parseOSRMSteps(_ legs: [[String: Any]]) -> [RouteStep] {
        var out: [RouteStep] = []
        var acc = 0.0
        for leg in legs {
            for st in (leg["steps"] as? [[String: Any]]) ?? [] {
                let d = (st["distance"] as? NSNumber)?.doubleValue ?? 0
                let ref = (st["ref"] as? String) ?? "", name = (st["name"] as? String) ?? ""
                if d > 0 { out.append(RouteStep(leg: RouteLeg(ref: ref, name: name, meters: d), startMeters: acc)) }
                acc += d
            }
        }
        return out
    }
    /// 隧道段（起点、终点）：OSRM steps[].intersections[] 按顺序排开，classes 含 "tunnel" 的那个路口到下一个路口算一段隧道
    /// （classes = 离开该路口那条路的类别；car 配置的类别有 toll/motorway/ferry/restricted/tunnel。类别变了边就不会被压缩，
    /// 隧道口一定有一个路口记录）。没有任何 intersections 字段（旧录音 / 服务没给）→ nil = 未知；有但没有隧道 → []
    static func parseOSRMTunnelSpans(_ legs: [[String: Any]]) -> [(CLLocationCoordinate2D, CLLocationCoordinate2D)]? {
        var marks: [(loc: CLLocationCoordinate2D, tunnel: Bool)] = []
        var sawIntersections = false
        for leg in legs {
            for st in (leg["steps"] as? [[String: Any]]) ?? [] {
                guard let xs = st["intersections"] as? [[String: Any]] else { continue }
                sawIntersections = true
                for x in xs {
                    guard let l = x["location"] as? [NSNumber], l.count >= 2 else { continue }
                    let c = CLLocationCoordinate2D(latitude: l[1].doubleValue, longitude: l[0].doubleValue)
                    guard c.latitude.isFinite, c.longitude.isFinite else { continue }
                    let tunnel = ((x["classes"] as? [String]) ?? []).contains("tunnel")
                    marks.append((c, tunnel))
                }
            }
        }
        guard sawIntersections else { return nil }
        var out: [(CLLocationCoordinate2D, CLLocationCoordinate2D)] = []
        for k in 0..<max(0, marks.count - 1) where marks[k].tunnel {
            out.append((marks[k].loc, marks[k + 1].loc))
        }
        return out
    }
    /// 隧道段长度占 `raw`（A–B 段路网原始折线）弧长的比例：每段两端投影到折线上取弧长区间，合并重叠后求和。
    /// spans 为 nil（未知）或折线太短 → nil；投影落在 A 之前 / B 之后的部分自然被夹到两端
    static func tunnelShare(spans: [(CLLocationCoordinate2D, CLLocationCoordinate2D)]?, along raw: [CLLocationCoordinate2D]) -> Double? {
        guard let spans, raw.count >= 2 else { return nil }
        let f = PortalDrift.Frame(origin: raw[0])
        let poly = PortalDrift.Poly(raw, frame: f)
        guard poly.length > 1 else { return nil }
        // 端点离折线太远（>60 m）的段不属于这段 A–B（上下文路由 A 之前 / B 之后的隧道）
        var iv: [(Double, Double)] = []
        for (p, q) in spans {
            let hp = poly.project(f.xy(p)), hq = poly.project(f.xy(q))
            guard hp.d <= 60 || hq.d <= 60 else { continue }
            let lo = min(hp.s, hq.s), hi = max(hp.s, hq.s)
            if hi - lo > 0.5 { iv.append((lo, hi)) }
        }
        iv.sort { $0.0 < $1.0 }
        var total = 0.0, curLo = -1.0, curHi = -1.0
        for (lo, hi) in iv {
            if lo > curHi { total += max(0, curHi - curLo); curLo = lo; curHi = hi } else { curHi = max(curHi, hi) }
        }
        total += max(0, curHi - curLo)
        return min(1, max(0, total / poly.length))
    }
    /// Valhalla trip.legs[].maneuvers[] → RouteStep（street_names 里形如 "A22"/"E45" 的当 ref，其余当 name；length 为 km）
    static func parseValhallaManeuvers(_ legs: [[String: Any]]) -> [RouteStep] {
        var out: [RouteStep] = []
        var acc = 0.0
        for leg in legs {
            for mv in (leg["maneuvers"] as? [[String: Any]]) ?? [] {
                let d = ((mv["length"] as? NSNumber)?.doubleValue ?? 0) * 1000
                let names = (mv["street_names"] as? [String]) ?? []
                let ref = names.first { n in n.count <= 8 && n.first?.isLetter == true && n.contains { $0.isNumber } && !n.contains(" ") } ?? ""
                let name = names.first { $0 != ref } ?? ""
                if d > 0 { out.append(RouteStep(leg: RouteLeg(ref: ref, name: name, meters: d), startMeters: acc)) }
                acc += d
            }
        }
        return out
    }
    /// 把沿路由 distance 计的 steps 映射到几何弧长 [arcA, arcB] 段：返回段内各步（长度按重叠部分）与 A 之前 / B 之后那一步。
    /// geometryLength = 原始几何的弧长（局部平面），steps 的累计距离按比例缩放到它
    static func stepsInside(_ steps: [RouteStep], arcA: Double, arcB: Double, geometryLength: Double) -> (inside: [RouteLeg], before: RouteLeg?, after: RouteLeg?) {
        guard !steps.isEmpty else { return ([], nil, nil) }
        let total = steps.last.map { $0.startMeters + $0.leg.meters } ?? 0
        let scale = total > 0 && geometryLength > 0 ? geometryLength / total : 1
        let lo = min(arcA, arcB), hi = max(arcA, arcB)
        var inside: [RouteLeg] = []
        var before: RouteLeg? = nil, after: RouteLeg? = nil
        // before = 覆盖 A 弧长位置（或在它之前结束）的最后一步；after = 覆盖 B 位置（或在它之后开始）的第一步。
        // 跨越 A 的那一步既是段内首步也是 A 之前的路（上下文路由从 A′ 一路开到 A，同一条路）
        for s in steps {
            let s0 = s.startMeters * scale, s1 = (s.startMeters + s.leg.meters) * scale
            if s0 < lo - 1 { before = s.leg }
            if s1 > hi + 1, after == nil { after = s.leg }
            let ov = min(s1, hi) - max(s0, lo)
            if ov > 1 { inside.append(RouteLeg(ref: s.leg.ref, name: s.leg.name, meters: ov)) }
        }
        if arcA > arcB { inside.reverse(); swap(&before, &after) }
        return (inside, before, after)
    }
    enum OSRMOutcome { case ok(OSRMAnswer), status(String) }

    /// 公路路由引擎：OSRM（有地图匹配）与 Valhalla（FOSSGIS 另一台机器，/route 约 0.1 s）。批量用两个引擎各开一路，
    /// 每台服务器仍然是一个客户端、1 秒 1 次
    enum RouteEngine { case osrm, valhalla }
    static let valhallaEndpoint = "https://valhalla1.openstreetmap.de/route"
    /// 引擎对应的主机名（限速/冷却/请求计数都按它）
    static func host(for engine: RouteEngine) -> String { engine == .osrm ? host(carEndpoints[0]) : (URL(string: valhallaEndpoint)?.host ?? "valhalla1.openstreetmap.de") }
    static func name(_ engine: RouteEngine) -> String { engine == .osrm ? "OSRM" : "Valhalla" }
    /// 自测用假引擎（只有 UITestHook 会设置）：非 nil 时 carRoute 不联网，直接返回它给的草稿或抛它的错误
    nonisolated(unsafe) static var routeOverride: (@Sendable (RouteEngine, CLLocationCoordinate2D, CLLocationCoordinate2D) async throws -> RouteDraft)?

    /// Valhalla /route：locations 带 heading（±45°），polyline6 解码；无路 → .status("NoRoute")
    static func fetchValhalla(a: CLLocationCoordinate2D, b: CLLocationCoordinate2D,
                                      bearingA: Double?, bearingB: Double?, failFast: Bool = false) async throws -> OSRMOutcome {
        func loc(_ p: CLLocationCoordinate2D, _ h: Double?) -> [String: Any] {
            var d: [String: Any] = ["lat": p.latitude, "lon": p.longitude, "radius": 120]
            if let h { d["heading"] = ((Int(h.rounded()) % 360) + 360) % 360; d["heading_tolerance"] = 45 }
            return d
        }
        let body: [String: Any] = ["locations": [loc(a, bearingA), loc(b, bearingB)], "costing": "auto",
                                   "shape_format": "polyline6", "units": "kilometers"]
        guard let url = URL(string: valhallaEndpoint) else { return .status(String(localized: "URL 无效", comment: "Routing status shown in notes/errors: the request URL is invalid")) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])   // 键序固定：考卷录音按请求体哈希
        let hostName = url.host ?? "valhalla1.openstreetmap.de"
        var (data, resp) = try await transport(host: hostName, req, failFast: failFast)
        var code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 || (500...504).contains(code), !failFast, RouteReplay.mode == nil {
            // 公共实例限流/过载：RateLimiter 已给该主机设了冷却期（≥10 s），再试一次会自动等过去；精确模式（failFast）不重发
            (data, resp) = try await transport(host: hostName, req, failFast: false)
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .status(code == 429 ? String(localized: "HTTP 429 限流", comment: "Routing status: server answered HTTP 429 (rate limited)")
                                       : String(localized: "非 JSON（HTTP \(code)）", comment: "Routing status: the response is not JSON. %lld = HTTP status code"))
        }
        if let err = json["error"] as? String {
            let ec = (json["error_code"] as? NSNumber)?.intValue ?? 0
            return .status(ec == 442 || ec == 171 ? "NoRoute" : (ec == 170 || ec == 442 ? "NoSegment" : "Valhalla \(ec) \(err.prefix(60))"))
        }
        guard let trip = json["trip"] as? [String: Any], let legs = trip["legs"] as? [[String: Any]], let shape = legs.first?["shape"] as? String,
              let km = ((trip["summary"] as? [String: Any])?["length"] as? NSNumber)?.doubleValue else { return .status(String(localized: "Valhalla 无路线", comment: "Routing status: Valhalla returned no route (keep Valhalla untranslated)")) }
        let pts = decodePolyline6(shape)
        guard pts.count >= 2 else { return .status(String(localized: "Valhalla 几何为空", comment: "Routing status: Valhalla returned an empty geometry")) }
        let sA = GeoMath.haversine(a.latitude, a.longitude, pts[0].latitude, pts[0].longitude)
        let sB = GeoMath.haversine(b.latitude, b.longitude, pts[pts.count - 1].latitude, pts[pts.count - 1].longitude)
        return .ok(OSRMAnswer(coords: pts, meters: km * 1000, snapA: sA, snapB: sB, steps: parseValhallaManeuvers(legs)))
    }
    /// Google polyline，精度 1e6（Valhalla）
    static func decodePolyline6(_ s: String) -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        var lat = 0, lon = 0, i = s.startIndex
        func next() -> Int? {
            var result = 0, shift = 0
            while i < s.endIndex {
                let b = Int(s[i].asciiValue ?? 63) - 63
                i = s.index(after: i)
                result |= (b & 0x1f) << shift
                shift += 5
                if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : (result >> 1) }
            }
            return nil
        }
        while i < s.endIndex {
            guard let dLat = next(), let dLon = next() else { break }
            lat += dLat; lon += dLon
            out.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e6, longitude: Double(lon) / 1e6))
        }
        return out
    }

    static func fetchOSRM(base: String, a: CLLocationCoordinate2D, b: CLLocationCoordinate2D,
                                  bearingA: Double?, bearingB: Double?, failFast: Bool = false) async throws -> OSRMOutcome {
        // steps=true：每步带 ref/name（落地前自检的「沿途换路」指标）；几何仍是 overview=full 的整条
        var q = String(format: "%.6f,%.6f;%.6f,%.6f?overview=full&geometries=geojson&steps=true&alternatives=false",
                       a.longitude, a.latitude, b.longitude, b.latitude)
        if bearingA != nil || bearingB != nil {
            func bstr(_ v: Double?) -> String { v.map { String(format: "%d,45", ((Int($0.rounded()) % 360) + 360) % 360) } ?? "" }
            q += "&bearings=\(bstr(bearingA));\(bstr(bearingB))&radiuses=120;120"
        }
        guard let url = URL(string: base + q) else { return .status(String(localized: "URL 无效", comment: "Routing status shown in notes/errors: the request URL is invalid")) }
        var (data, resp) = try await transport(host: host(base), URLRequest(url: url), failFast: failFast)
        var code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 || (500...504).contains(code), !failFast, RouteReplay.mode == nil {
            // 公共实例限流/过载：RateLimiter 已给该主机设了冷却期（≥10 s），再试一次会自动等过去；精确模式（failFast）不重发
            (data, resp) = try await transport(host: host(base), URLRequest(url: url), failFast: false)
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .status(code == 429 ? String(localized: "HTTP 429 限流", comment: "Routing status: server answered HTTP 429 (rate limited)")
                                       : String(localized: "非 JSON（HTTP \(code)）", comment: "Routing status: the response is not JSON. %lld = HTTP status code"))
        }
        let status = json["code"] as? String ?? "HTTP \(code)"
        guard status == "Ok" else { return .status(status) }
        // JSONSerialization 里整数坐标是 NSNumber，不能直接 as? [[Double]]
        guard let routes = json["routes"] as? [[String: Any]], let r0 = routes.first,
              let geom = r0["geometry"] as? [String: Any],
              let rawCoords = geom["coordinates"] as? [[NSNumber]],
              let dist = (r0["distance"] as? NSNumber)?.doubleValue else { return .status(String(localized: "响应缺 routes/geometry", comment: "Routing status: the OSRM response lacks the routes/geometry fields (keep the field names)")) }
        let wps = (json["waypoints"] as? [[String: Any]]) ?? []
        let pts = rawCoords.compactMap { c -> CLLocationCoordinate2D? in
            guard c.count >= 2 else { return nil }
            let lon = c[0].doubleValue, lat = c[1].doubleValue
            return lon.isFinite && lat.isFinite ? CLLocationCoordinate2D(latitude: lat, longitude: lon) : nil
        }
        let legs = (r0["legs"] as? [[String: Any]]) ?? []
        var ans = OSRMAnswer(coords: pts, meters: dist,
                             snapA: (wps.first?["distance"] as? NSNumber)?.doubleValue ?? 0,
                             snapB: (wps.last?["distance"] as? NSNumber)?.doubleValue ?? 0,
                             steps: parseOSRMSteps(legs))
        ans.tunnelSpans = parseOSRMTunnelSpans(legs)
        return .ok(ans)
    }

    /// 公路引擎的每次 HTTP 都经这里：正常走 RateLimiter（同主机串行、≥1.05 s、429 冷却）；
    /// 考卷录制/回放（RouteReplay）时由它接管——回放不出网，录制自带更保守的限速
    static func transport(host hostName: String, _ req: URLRequest, failFast: Bool) async throws -> (Data, URLResponse) {
        if RouteReplay.mode != nil { return try await RouteReplay.perform(req) }
        return try await RateLimiter.shared.perform(host: hostName, failIfCooling: failFast) { try await session.data(for: req) }
    }

    /// OSRM /match 地图匹配：把 A 前、B 后的真实点一起送去，断档处 gaps=ignore 跨过去，取 A→B 那一腿。
    /// FOSSGIS 最多收 10 个点。返回 nil = 匹配失败/不可用（调用方退回其它候选）
    static func fetchMatch(base: String, trace: [TracePoint], a: CLLocationCoordinate2D, b: CLLocationCoordinate2D,
                                   radius: Double, failFast: Bool = false, stepA: Double = 30, stepB: Double = 30) async throws -> OSRMAnswer? {
        guard trace.count >= 3, trace.count <= 10,
              let iA = trace.firstIndex(where: { $0.coord.latitude == a.latitude && $0.coord.longitude == a.longitude }),
              let iB = trace.firstIndex(where: { $0.coord.latitude == b.latitude && $0.coord.longitude == b.longitude }), iB == iA + 1 else { return nil }
        let matchBase = base.replacingOccurrences(of: "/route/v1/driving/", with: "/match/v1/driving/")
        let coords = trace.map { String(format: "%.6f,%.6f", $0.coord.longitude, $0.coord.latitude) }.joined(separator: ";")
        // 时间戳必须严格递增：OSRM 用相邻时间差算可达距离，Δt=0 会让容差为 0 直接 NoMatch
        var last = Int.min
        let times = trace.map { p -> String in
            var t = Int(p.time.rounded())
            if t <= last { t = last + 1 }
            last = t
            return String(t)
        }.joined(separator: ";")
        // radiuses = GPS 标准差：专用记录仪 15 m；手机按精度 20–50 m（太小时手机点落在候选圈外 → NoMatch）
        let r = String(Int(min(100, max(5, radius)).rounded()))
        let radiuses = trace.map { _ in r }.joined(separator: ";")
        // waypoints：只在首、A、B、尾处分腿。缺点是首/尾点匹配不上时整次报 NoMatch
        //（"Requested waypoint parameter could not be matched"）；不传时外侧点匹配不上只会被丢掉。
        // 两种模式下都按 tracepoints 里 A、B 的 matchings_index / waypoint_index 找那一腿
        var q = "\(coords)?timestamps=\(times)&radiuses=\(radiuses)&gaps=ignore&tidy=false&overview=full&geometries=geojson&steps=true"
        if useMatchWaypoints {
            let wp = Array(Set([0, iA, iB, trace.count - 1])).sorted()
            q += "&waypoints=\(wp.map(String.init).joined(separator: ";"))"
        }
        guard let url = URL(string: matchBase + q) else { return nil }
        var (data, resp) = try await transport(host: host(base), URLRequest(url: url), failFast: failFast)
        var code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 || (500...504).contains(code), !failFast, RouteReplay.mode == nil {
            // 与 fetchOSRM 同款：冷却期由 RateLimiter 统一管，再试一次；精确模式（failFast）不重发
            (data, resp) = try await transport(host: host(base), URLRequest(url: url), failFast: false)
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard (json["code"] as? String) == "Ok", let matchings = json["matchings"] as? [[String: Any]],
              let tps = json["tracepoints"] as? [Any], tps.count > iB,
              let ta = tps[iA] as? [String: Any], let tb = tps[iB] as? [String: Any],
              let mi = (ta["matchings_index"] as? NSNumber)?.intValue, (tb["matchings_index"] as? NSNumber)?.intValue == mi,
              let wa = (ta["waypoint_index"] as? NSNumber)?.intValue, (tb["waypoint_index"] as? NSNumber)?.intValue == wa + 1,
              mi < matchings.count else { _ = code; return nil }
        let m0 = matchings[mi]
        guard let legs = m0["legs"] as? [[String: Any]], wa < legs.count,
              let dist = (legs[wa]["distance"] as? NSNumber)?.doubleValue else { return nil }
        // 吸附坐标（一定落在 matching 几何上）：用它裁几何比用原始 A/B 投影稳——跨断档的匹配轨迹可能两次经过 A 附近
        func loc(_ tp: [String: Any]) -> CLLocationCoordinate2D? {
            guard let l = tp["location"] as? [NSNumber], l.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: l[1].doubleValue, longitude: l[0].doubleValue)
        }
        let snappedA = loc(ta) ?? a, snappedB = loc(tb) ?? b
        // 腿的几何：没有逐腿几何时用整条 matching 的几何按 A、B 投影裁出
        guard let geom = m0["geometry"] as? [String: Any], let raw = geom["coordinates"] as? [[NSNumber]] else { return nil }
        let pts = raw.compactMap { c -> CLLocationCoordinate2D? in
            guard c.count >= 2 else { return nil }
            let lon = c[0].doubleValue, lat = c[1].doubleValue
            return lon.isFinite && lat.isFinite ? CLLocationCoordinate2D(latitude: lat, longitude: lon) : nil
        }
        guard let clipped = clipPolyline(pts, from: snappedA, to: snappedB) else { return nil }
        // 裁出来的几何必须和腿距离对得上：跨断档的匹配轨迹可能在同一条路上折返，裁剪投影到前一次经过的位置
        // 就会裁错段（长度明显不等于腿距离）→ 放弃这个候选
        guard abs(clipped.meters - dist) <= max(50, 0.2 * dist) else { return nil }
        // 以腿距离为准（匹配给出的真实路网长度），几何用裁出来的；贴路 = 锚点到吸附点
        let sA = GeoMath.haversine(a.latitude, a.longitude, snappedA.latitude, snappedA.longitude)
        let sB = GeoMath.haversine(b.latitude, b.longitude, snappedB.latitude, snappedB.longitude)
        // 这一腿的 steps（ref/name）：legs[wa].steps 就是 A→B 那一腿的
        let steps = parseOSRMSteps([legs[wa]])
        var ans = OSRMAnswer(coords: trimEnds(clipped.coords, a: a, b: b, stepA: stepA, stepB: stepB), meters: max(dist, clipped.meters * 0.5), snapA: sA, snapB: sB,
                             steps: steps, rawCoords: clipped.coords)
        ans.tunnelSpans = parseOSRMTunnelSpans([legs[wa]])
        return ans
    }

    /// 上下文端点：A 之前 / B 之后约 150 m 处的真实轨迹点及其行进方向。
    /// 锚点本身的 GPS 常落在匝道/辅路旁（出口点 B 离匝道 2 m 就会让 OSRM 下匝道绕一圈回来），
    /// 从更远处出发、到更远处结束再裁出 A–B 段，路径才跟着车真正走的那条路
    struct ContextAnchor {
        var coord: CLLocationCoordinate2D
        var bearing: Double?
    }

    /// bearingA = 进入 A 的行进方向，bearingB = 离开 B 的行进方向（度，北 0 顺时针）；nil 则不约束。
    /// 候选：直接 A→B（带/不带方向约束）、上下文 A′→B′ 裁剪到 A–B。按"相对直线的绕路比"选最小的；
    /// 平手时优先上下文版（它还保证了进出方向与真实轨迹一致）。
    /// portalA/portalB = 锚点外侧的真实点：上下文几何回来后先判隧道口定位漂移——锚点离路太远而外侧几个点回到路上，
    /// 就把锚点往外挪到第一个在路上的点（漂移点随区间一起替换），再裁几何；挪不动的残余偏移在末端渐进靠拢
    static func carRoute(a: CLLocationCoordinate2D, b: CLLocationCoordinate2D,
                         bearingA: Double?, bearingB: Double?,
                         contextA: ContextAnchor? = nil, contextB: ContextAnchor? = nil,
                         trace: [TracePoint] = [], matchRadius: Double = 15, seconds: Double? = nil,
                         portalA: [PortalSample] = [], portalB: [PortalSample] = [],
                         farContextA: ContextAnchor? = nil, farContextB: ContextAnchor? = nil,
                         portalFarA: [PortalSample] = [], portalFarB: [PortalSample] = [],
                         leftHandTraffic: Bool? = nil,
                         economy: Bool = false, engine: RouteEngine = .osrm, failFast: Bool = false, progress: Progress? = nil) async throws -> RouteDraft {
        let straight0 = GeoMath.haversine(a.latitude, a.longitude, b.latitude, b.longitude)
        guard straight0 <= maxStraightKm * 1000 else { throw RouteError.tooFar(straight0 / 1000) }
        if let fake = routeOverride { return try await fake(engine, a, b) }      // 自测假引擎
        // 贴路容差：专用记录仪 60 m；手机按匹配半径放宽到最多 100 m
        let snapTol = min(100, max(60, 2 * matchRadius))
        // 漂移判定：在路上 = 离路 ≤ max(半径, 10)；漂移 = 离路 > max(1.5×半径, 20)
        let tolOn = max(matchRadius, 10), tolDrift = max(1.5 * matchRadius, 20)
        // 锚点外侧的局部步长（第一个外侧点离锚点多远）：trimEnds 判断「锚点旁的近点能不能删」用，钳到 10–100 m
        let stepA = min(100, max(10, portalA.first?.meters ?? 30)), stepB = min(100, max(10, portalB.first?.meters ?? 30))
        // 路径按断档时长算出的隐含速度（m/s）；>50 m/s（180 km/h）的公路路径不可信（Newson & Krumm 的 50 m/s 规则）
        func impliedMps(_ m: Double) -> Double? { seconds.map { $0 > 0 ? m / $0 : .infinity } }
        var errors: [String] = []
        var routingStatuses: [String] = []
        let hasBearings = bearingA != nil || bearingB != nil
        let endpoints = engine == .osrm ? carEndpoints : [valhallaEndpoint]
        let src: RouteSource = engine == .osrm ? .osrmCar : .valhallaCar
        let engineName = engine == .osrm ? "OSRM" : "Valhalla"
        for (k, base) in endpoints.enumerated() {
            try Task.checkCancellation()
            let hostName = host(base), step = k + 1, total = endpoints.count
            progress?(String(localized: "请求 \(engineName) 公路…（\(hostName)，\(step)/\(total)）", comment: "Progress text while fetching a road route. 1st = router name (OSRM or Valhalla), 2nd = server host name, 3rd = attempt number, 4th = number of servers"))
            // 本端点内可变的锚点（漂移外推后更新）
            var A = a, B = b, shiftA = 0, shiftB = 0
            var bearingA = bearingA, bearingB = bearingB
            var straight = straight0
            var driftNotes: [String] = []
            var trace = trace
            var laneSideBad = false                  // 车道侧校验：真实点落在了路线的错误一侧（吸到对向车道）
            func ratio(_ m: Double) -> Double { max(1, m / max(straight, 1)) }
            // (名字, 答案, 是否受方向约束)
            var candidates: [(name: String, ans: OSRMAnswer, constrained: Bool)] = []
            var failedNotes: [String] = []           // 哪些候选没拿到结果、为什么（给用户看）
            var transportErrors = 0
            // 一次原始请求（不裁剪）：失败只记录，取消立刻抛出
            func fetchRaw(_ name: String, _ pa: CLLocationCoordinate2D, _ pb: CLLocationCoordinate2D, _ ba: Double?, _ bb: Double?) async throws -> OSRMAnswer? {
                try Task.checkCancellation()
                do {
                    let outcome = engine == .osrm ? try await fetchOSRM(base: base, a: pa, b: pb, bearingA: ba, bearingB: bb, failFast: failFast)
                                                  : try await fetchValhalla(a: pa, b: pb, bearingA: ba, bearingB: bb, failFast: failFast)
                    switch outcome {
                    case .ok(let ans): return ans
                    case .status(let st):
                        let label = candidateLabel(name)
                        failedNotes.append(String(localized: "「\(label)」无结果（\(engineName)：\(st)）", comment: "Routing note. 1st = route method name (Match / Context / Far Context / Constrained / Direct), 2nd = router name (OSRM or Valhalla), 3rd = status returned by the router"))
                        if st == "NoRoute" || st == "NoSegment" { routingStatuses.append(st) }
                        else {
                            errors.append("\(host(base)) \(label) \(st)"); transportErrors += 1
                            if failFast { throw RouteError.allEndpointsFailed(errors) }
                        }
                        return nil
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let e as URLError where e.code == .cancelled {
                    throw CancellationError()
                } catch let e as RouteError where failFast {
                    throw e                                   // 上面 failFast 抛出的 allEndpointsFailed：原样向外，不再包一层
                } catch {
                    let label = candidateLabel(name), why = error.localizedDescription
                    failedNotes.append(String(localized: "「\(label)」请求失败（\(why)）", comment: "Routing note. 1st = route method name (Match / Context / Far Context / Constrained / Direct), 2nd = system error description"))
                    errors.append("\(host(base)) \(label) \(why)"); transportErrors += 1
                    if failFast { throw RouteError.allEndpointsFailed(errors) }
                    return nil
                }
            }
            // 直接/约束：A→B 整条就是答案，只去掉紧挨锚点的小折
            func fetchDirect(_ name: String, _ ba: Double?, _ bb: Double?, constrained: Bool) async throws {
                if let ans = try await fetchRaw(name, A, B, ba, bb) {
                    candidates.append((name, OSRMAnswer(coords: trimEnds(ans.coords, a: A, b: B, stepA: stepA, stepB: stepB), meters: ans.meters, snapA: ans.snapA, snapB: ans.snapB,
                                                        steps: ans.steps, rawCoords: ans.coords), constrained))
                }
            }
            // 上下文：A′→B′ 原始几何 → 漂移判定（可能挪锚点）→ 沿线裁到 A–B。
            // 近上下文（150 m）不干净（绕圈 / 锚点离路远且外侧点没回到路上）时，用远上下文（600–900 m）再试一次：
            // 隧道口整段漂到平行路上时，只有从更远处回望才看得出真正走的是哪条路；远的结果明显更干净才采用
            struct ContextTry { var raw: OSRMAnswer; var analysis: PortalDrift.Analysis; var clip: (coords: [CLLocationCoordinate2D], meters: Double, snapA: Double, snapB: Double); var A: CLLocationCoordinate2D; var B: CLLocationCoordinate2D; var samplesA: [PortalSample]; var samplesB: [PortalSample] }
            func tryContext(_ name: String, _ ca: ContextAnchor, _ cb: ContextAnchor, samplesA: [PortalSample], samplesB: [PortalSample]) async throws -> ContextTry? {
                guard let raw = try await fetchRaw(name, ca.coord, cb.coord, ca.bearing, cb.bearing), raw.coords.count >= 2 else { return nil }
                let analysis = PortalDrift.analyze(raw: raw.coords, a: a, b: b, portalA: samplesA, portalB: samplesB, tolOn: tolOn, tolDrift: tolDrift,
                                                   bearingA: bearingA, bearingB: bearingB)
                let A2 = analysis.newA?.coord ?? a, B2 = analysis.newB?.coord ?? b
                guard let c = PortalDrift.clip(raw: raw.coords, a: A2, b: B2, arcA: analysis.arcA, arcB: analysis.arcB) else {
                    let label = candidateLabel(name)
                    failedNotes.append(String(localized: "「\(label)」几何无法裁到 A–B", comment: "Routing note: the route geometry of this method could not be clipped to the A–B section. %@ = route method name (Context / Far Context). A and B are the gap anchors")); return nil
                }
                return ContextTry(raw: raw, analysis: analysis, clip: c, A: A2, B: B2, samplesA: samplesA, samplesB: samplesB)
            }
            func dirty(_ t: ContextTry) -> Bool {
                let st = GeoMath.haversine(t.A.latitude, t.A.longitude, t.B.latitude, t.B.longitude)
                return t.clip.meters > max(1.25 * st, st + 80) || max(t.clip.snapA, t.clip.snapB) > tolDrift
            }
            func fetchContext() async throws {
                guard contextA != nil || contextB != nil, !candidates.contains(where: { $0.name == "上下文" }) else { return }
                let ca = contextA ?? ContextAnchor(coord: A, bearing: bearingA)
                let cb = contextB ?? ContextAnchor(coord: B, bearing: bearingB)
                guard var best = try await tryContext("上下文", ca, cb, samplesA: contextA == nil ? [] : portalA, samplesB: contextB == nil ? [] : portalB) else { return }
                var usedFar = false
                if dirty(best), farContextA != nil || farContextB != nil {
                    // 哪一侧有问题就升级哪一侧：锚点离路远且没挪动的那侧；绕圈但两侧都贴路时两侧都升级
                    let badA = best.clip.snapA > tolDrift, badB = best.clip.snapB > tolDrift
                    let upA = (badA || !(badA || badB)) && farContextA != nil, upB = (badB || !(badA || badB)) && farContextB != nil
                    if upA || upB {
                        let fa = upA ? farContextA! : ca, fb = upB ? farContextB! : cb
                        if let far = try await tryContext("远上下文", fa, fb, samplesA: upA ? portalFarA : (contextA == nil ? [] : portalA), samplesB: upB ? portalFarB : (contextB == nil ? [] : portalB)) {
                            let stN = GeoMath.haversine(best.A.latitude, best.A.longitude, best.B.latitude, best.B.longitude)
                            let stF = GeoMath.haversine(far.A.latitude, far.A.longitude, far.B.latitude, far.B.longitude)
                            let rN = best.clip.meters / max(1, stN), rF = far.clip.meters / max(1, stF)
                            if rF <= 1.35, rF <= rN - 0.15 || max(far.clip.snapA, far.clip.snapB) < max(best.clip.snapA, best.clip.snapB) - tolDrift, max(far.clip.snapA, far.clip.snapB) <= snapTol {
                                let farA = Int(portalFarA.last?.meters ?? 0), farB = Int(portalFarB.last?.meters ?? 0)
                                let sides = [upA ? String(localized: "A 前 \(farA) m", comment: "Which far-context point was used: %lld metres before anchor A") : nil,
                                             upB ? String(localized: "B 后 \(farB) m", comment: "Which far-context point was used: %lld metres after anchor B") : nil].compactMap { $0 }.joined(separator: Fmt.listSeparator)
                                driftNotes.append(String(localized: "近上下文（150 m 外）的路由不干净（绕路比 \(rN, format: Fmt.f2)、贴路 \(best.clip.snapA, format: Fmt.f0)/\(best.clip.snapB, format: Fmt.f0) m），改用远上下文（\(sides)）：绕路比 \(rF, format: Fmt.f2)、贴路 \(far.clip.snapA, format: Fmt.f0)/\(far.clip.snapB, format: Fmt.f0) m", comment: "Routing note: the near-context route (from 150 m away) was not clean, the far context is used instead. 1st = near detour ratio (route length / straight line), 2nd/3rd = near snap distance to the road at A/B in m, 4th = list of far points used (e.g. \"A 前 600 m\"), 5th = far detour ratio, 6th/7th = far snap distance at A/B in m. Glossary: 上下文 = Context, 远上下文 = Far Context"))
                                best = far; usedFar = true
                            } else {
                                driftNotes.append(String(localized: "远上下文也没更干净（绕路比 \(rF, format: Fmt.f2)、贴路 \(far.clip.snapA, format: Fmt.f0)/\(far.clip.snapB, format: Fmt.f0) m），仍用近上下文", comment: "Routing note: the far-context route was not cleaner, the near context is kept. 1st = far detour ratio, 2nd/3rd = snap distance to the road at A/B in m. Glossary: 远上下文 = Far Context"))
                            }
                        }
                    }
                }
                _ = usedFar
                if let s = best.analysis.newA { A = s.coord; shiftA = s.shift }
                if let s = best.analysis.newB { B = s.coord; shiftB = s.shift }
                if shiftA > 0 || shiftB > 0 {
                    straight = GeoMath.haversine(A.latitude, A.longitude, B.latitude, B.longitude)
                    // 新锚点处的行进方向：从新锚点往外第一个 ≥25 m 的真实点算（约束/直接候选和后面的校验都用它）
                    if shiftA > 0, let nb = PortalDrift.headingAtShifted(best.samplesA, shift: shiftA, forward: false) { bearingA = nb }
                    if shiftB > 0, let nb = PortalDrift.headingAtShifted(best.samplesB, shift: shiftB, forward: true) { bearingB = nb }
                    // 被跳过的漂移点不再当匹配轨迹（它们本来就不在路上）
                    let dropA = Set(best.samplesA.prefix(shiftA).map(\.index)), dropB = Set(best.samplesB.prefix(shiftB).map(\.index))
                    let oldA = trace.first { $0.coord.latitude == a.latitude && $0.coord.longitude == a.longitude }?.index
                    let oldB = trace.first { $0.coord.latitude == b.latitude && $0.coord.longitude == b.longitude }?.index
                    trace = trace.filter { p in
                        if p.index < 0 { return true }
                        if shiftA > 0, p.index == oldA || dropA.contains(p.index) { return p.index == best.samplesA[shiftA - 1].index }
                        if shiftB > 0, p.index == oldB || dropB.contains(p.index) { return p.index == best.samplesB[shiftB - 1].index }
                        return true
                    }
                }
                driftNotes += best.analysis.notes
                // 车道侧校验：靠右（左）通行时，真实点应贴着路线或在它的左（右）侧一个车道内；
                // 若一串在路上的真实点都落在路线的右（左）侧 6–60 m，说明路线吸到了对向车道
                let lane = PortalDrift.laneSideCheck(raw: best.raw.coords, a: A, b: B,
                                                     samplesA: Array(best.samplesA.dropFirst(shiftA)), samplesB: Array(best.samplesB.dropFirst(shiftB)),
                                                     arcA: best.analysis.arcA, arcB: best.analysis.arcB, tolOn: tolOn, leftHand: leftHandTraffic)
                driftNotes.append(lane.note)
                laneSideBad = lane.wrongSide
                // 沿途道路：整条 A′→B′ 的 steps 按弧长映射到 A–B 段；A 之前 / B 之后那一步 = 真实轨迹两侧所在的路
                let rawLen = PortalDrift.Poly(best.raw.coords, frame: PortalDrift.Frame(origin: A)).length
                let legs = stepsInside(best.raw.steps, arcA: best.analysis.arcA, arcB: best.analysis.arcB, geometryLength: rawLen)
                var ctxAns = OSRMAnswer(coords: trimEnds(best.clip.coords, a: A, b: B, stepA: stepA, stepB: stepB), meters: best.clip.meters, snapA: best.clip.snapA, snapB: best.clip.snapB)
                ctxAns.steps = legs.inside.enumerated().map { RouteStep(leg: $0.element, startMeters: legs.inside.prefix($0.offset).reduce(0) { $0 + $1.meters }) }
                ctxAns.rawCoords = best.clip.coords
                ctxAns.roadBeforeA = legs.before; ctxAns.roadAfterB = legs.after
                ctxAns.tunnelSpans = best.raw.tunnelSpans     // 整条 A′→B′ 的隧道段；finish 里按 A–B 原始折线量占比
                candidates.append(("上下文", ctxAns, true))
            }
            // 经济模式"够干净"：短弦上 1.25 倍只有几十米，给 +80 m 的绝对下限；隐含速度不能超过 50 m/s
            func cleanEnough(_ x: OSRMAnswer) -> Bool {
                x.meters <= max(1.25 * straight, straight + 80) && max(x.snapA, x.snapB) <= snapTol && (impliedMps(x.meters) ?? 0) <= 50
            }
            /// lengthWarnings：warnings 里的两条几何警告（路网路径远长于直线 / 隐含速度不可能），是 warnings 的子集、顺序不变；
            /// 折返截断生效（ex.notes 非空）后它们不再成立，按值去掉（不按文字前缀匹配，翻译后也成立）
            func finish(_ c: (name: String, ans: OSRMAnswer, constrained: Bool), warnings: [String], lengthWarnings: [String] = [], notes: [String]) -> RouteDraft {
                // 最终路径再查一次折返（约束/直接候选没经过沿线裁剪；上下文裁剪后也兜一道），
                // 然后残余偏移（锚点离路 d 米）在末端 L 米内渐进靠拢，不留垂直于路的急拐
                let ex = PortalDrift.trimExcursion(c.ans.coords, a: A, b: B, bearingA: bearingA, bearingB: bearingB)
                let meters = ex.notes.isEmpty ? c.ans.meters : ex.meters
                // d 用锚点到原始路网的距离（snap）；折返截断改了哪一端，那一端的 snap 就不再对应首（末）点，退回现算
                // （trimExcursion 会把坐标经局部平面来回换算，位级未必相等，按 <0.05 m 判同一点）
                func samePt(_ x: CLLocationCoordinate2D?, _ y: CLLocationCoordinate2D?) -> Bool {
                    guard let x, let y else { return false }
                    return GeoMath.haversine(x.latitude, x.longitude, y.latitude, y.longitude) < 0.05
                }
                let keptA = samePt(ex.coords.first, c.ans.coords.first)
                let keptB = samePt(ex.coords.last, c.ans.coords.last)
                let tapered = PortalDrift.taper(ex.coords, a: A, b: B, dA: keptA ? c.ans.snapA : nil, dB: keptB ? c.ans.snapB : nil,
                                                minOffset: max(8, tolOn))
                var warnings = warnings
                if !ex.notes.isEmpty { warnings.removeAll { lengthWarnings.contains($0) } }
                // 事后自检：首（末）个路网点离锚点太远，或方向跟真实轨迹对不上 → 起止段多半不是路网几何（隧道 way 节点稀疏时的伪影）。
                // 离锚点 ≤30 m 时方向由 GPS 横向噪声主导（锚点离路 12 m 时投影点在正侧方），只看距离；
                // 距离门槛与 trimEnds 的 reach（max(60, 2×步长)）一致：trimEnds 删近点时本来就允许首点停在 reach 内，
                // 比它低的门槛会把城市慢速断档（步长 10 m、首点停在 45 m）全都误报
                if let first = tapered.coords.first, let last = tapered.coords.last {
                    func angDiff(_ x: Double, _ y: Double) -> Double { let d = abs(x - y).truncatingRemainder(dividingBy: 360); return d > 180 ? 360 - d : d }
                    let distA = GeoMath.haversine(A.latitude, A.longitude, first.latitude, first.longitude)
                    let dirA = bearingA.map { angDiff(GeoMath.bearing(A.latitude, A.longitude, first.latitude, first.longitude), $0) } ?? 0
                    if distA > max(60, 2 * stepA) || (distA > 30 && dirA > 30) {
                        warnings.append(String(localized: "补点起始段不是路网几何（首个路网点离 A \(distA, format: Fmt.f0) m / 方向差 \(dirA, format: Fmt.f0)°），请在地图上看一眼", comment: "Road-draft warning: the start of the filled path does not follow the road network. 1st = distance from anchor A to the first route vertex in m, 2nd = angle between that direction and the travel direction at A in degrees"))
                    }
                    let distB = GeoMath.haversine(last.latitude, last.longitude, B.latitude, B.longitude)
                    let dirB = bearingB.map { angDiff(GeoMath.bearing(last.latitude, last.longitude, B.latitude, B.longitude), $0) } ?? 0
                    if distB > max(60, 2 * stepB) || (distB > 30 && dirB > 30) {
                        warnings.append(String(localized: "补点末尾段不是路网几何（最后一个路网点离 B \(distB, format: Fmt.f0) m / 方向差 \(dirB, format: Fmt.f0)°），请在地图上看一眼", comment: "Road-draft warning: the end of the filled path does not follow the road network. 1st = distance from the last route vertex to anchor B in m, 2nd = angle between that direction and the travel direction at B in degrees"))
                    }
                }
                var d = RouteDraft(source: src, coords: tapered.coords, meters: meters, snapA: c.ans.snapA, snapB: c.ans.snapB,
                                   endpoint: host(base), warnings: warnings, notes: driftNotes + notes + ex.notes + tapered.notes, method: RouteMethod(candidateName: c.name))
                d.shiftA = shiftA; d.shiftB = shiftB
                d.anchorA = shiftA > 0 ? A : nil; d.anchorB = shiftB > 0 ? B : nil
                d.residualA = c.ans.snapA; d.residualB = c.ans.snapB
                d.taperA = tapered.dA; d.taperB = tapered.dB
                // 落地前自检用：后处理前的几何 + 沿途道路
                d.rawCoords = c.ans.rawCoords ?? c.ans.coords
                d.legs = c.ans.steps.map(\.leg)
                d.roadBeforeA = c.ans.roadBeforeA; d.roadAfterB = c.ans.roadAfterB
                d.tunnelShare = tunnelShare(spans: c.ans.tunnelSpans, along: d.rawCoords)
                return d
            }
            // 0) 上下文永远先发：它的整条几何是漂移判定的依据，挪过锚点之后其它候选才有正确的起终点。
            //    经济模式：够干净就直接采用（/route 约 0.6 s，而 /match 被 FOSSGIS 节流到 7–9 s 一次）
            try await fetchContext()
            if economy, !laneSideBad, let c = candidates.first(where: { $0.name == "上下文" }), cleanEnough(c.ans) {
                let r = ratio(c.ans.meters)
                return finish(c, warnings: [],
                              notes: [String(localized: "采用「上下文」：绕路比 \(r, format: Fmt.f2)、贴路 \(c.ans.snapA, format: Fmt.f0)/\(c.ans.snapB, format: Fmt.f0) m，达标即止（批量先走上下文：/route 0.6 s，地图匹配被服务器节流到 7–9 s）", comment: "Routing note (economy mode): the Context route was clean enough and used directly. 1st = detour ratio (route length / straight line), 2nd/3rd = snap distance to the road at A/B in m. Keep /route untranslated. Glossary: 上下文 = Context")])
            }
            // 1) 地图匹配（1 次请求，把 A 前 B 后的真实点一起交给 OSRM，由它判断车在哪条路上）
            if trace.count >= 3, engine == .osrm {
                do {
                    if let m = try await fetchMatch(base: base, trace: trace, a: A, b: B, radius: matchRadius, failFast: failFast, stepA: stepA, stepB: stepB) {
                        candidates.append(("匹配", m, true))
                        if economy, cleanEnough(m) {
                            let iA = trace.firstIndex { $0.coord.latitude == A.latitude && $0.coord.longitude == A.longitude } ?? 0
                            let nB = trace.count - 2 - iA, r = ratio(m.meters)
                            return finish(("匹配", m, true), warnings: [],
                                          notes: [String(localized: "采用「匹配」（A 前 \(iA) 点 + B 后 \(nB) 点，半径 \(matchRadius, format: Fmt.f0) m）：绕路比 \(r, format: Fmt.f2)、贴路 \(m.snapA, format: Fmt.f0)/\(m.snapB, format: Fmt.f0) m，达标即止，没再比较其它候选", comment: "Routing note (economy mode): map matching was clean enough, no other candidates compared. 1st = number of real points before A, 2nd = number of points after B, 3rd = matching radius in m, 4th = detour ratio, 5th/6th = snap distance at A/B in m. Glossary: 匹配 = Match")])
                        }
                    }
                } catch is CancellationError { throw CancellationError() }
                  catch let e as URLError where e.code == .cancelled { throw CancellationError() }
                  catch {
                      errors.append("\(host(base)) \(RouteMethod.match.label) \(error.localizedDescription)"); transportErrors += 1
                      if failFast { throw RouteError.allEndpointsFailed(errors) }
                  }
            }
            if hasBearings { try await fetchDirect("约束", bearingA, bearingB, constrained: true) }
            try await fetchDirect("直接", nil, nil, constrained: false)
            guard !candidates.isEmpty else { continue }      // 这个端点没给出任何路径（没路或全失败）：试下一个
            if transportErrors > 0 { /* 部分变体失败不影响选择，只是少了对照 */ }
            // 选最小绕路比；相差 5%（短弦至少 40 m，约两端各 2σ）以内算平手 → 匹配 > 上下文 > 约束 > 直接。
            // 贴路超过容差的上下文/匹配候选不得胜出（它的 A/B 投影根本不在锚点附近，长度没有意义）
            let order = ["匹配": 0, "上下文": 1, "约束": 2, "直接": 3]
            let tie = max(0.05 * straight, 40.0)
            func eligible(_ c: (name: String, ans: OSRMAnswer, constrained: Bool)) -> Bool {
                (c.name == "约束" || c.name == "直接") || max(c.ans.snapA, c.ans.snapB) <= max(snapTol, 150)
            }
            var pool = candidates.filter(eligible).isEmpty ? candidates : candidates.filter(eligible)
            if laneSideBad, pool.count > 1 { pool.removeAll { $0.name == "上下文" } }   // 吸到对向车道的上下文候选让位给其它候选
            let best = pool.min { x, y in
                if abs(x.ans.meters - y.ans.meters) <= tie { return (order[x.name] ?? 9) < (order[y.name] ?? 9) }
                return x.ans.meters < y.ans.meters
            }!
            var warnings: [String] = []
            var lengthWarnings: [String] = []          // warnings 的子集：折返截断后由 finish 去掉
            if !best.constrained, hasBearings { warnings.append(String(localized: "未能按行进方向约束，路径可能吸到对向车道", comment: "Road-draft warning: the route could not be constrained by the travel direction and may snap to the opposite carriageway")) }
            if laneSideBad, best.name == "上下文" { warnings.append(String(localized: "按通行侧校验，两端真实点落在路线的错误一侧：路线可能吸到了对向车道，请在地图上看一眼", comment: "Road-draft warning from the driving-side check: real points at both ends lie on the wrong side of the route; it may be on the opposite carriageway, please check on the map")) }
            if let direct = candidates.first(where: { $0.name == "约束" || $0.name == "直接" }), best.name == "上下文" || best.name == "匹配",
               ratio(direct.ans.meters) > ratio(best.ans.meters) + 0.5 {
                let km = direct.ans.meters / 1000
                warnings.append(String(localized: "锚点本身吸到了别的路（直接路由 \(km, format: Fmt.f2) km），已按前后轨迹走向纠正", comment: "Road-draft warning: the anchor itself snapped to another road; corrected using the track before/after. %@ = length of the direct route in km"))
            }
            if best.ans.meters > max(2.5 * straight, straight + 300) {
                let km = best.ans.meters / 1000, straightKm = straight / 1000
                let w = String(localized: "路网路径 \(km, format: Fmt.f2) km 远长于直线 \(straightKm, format: Fmt.f2) km，可能绕路或端点接错路", comment: "Road-draft warning. 1st = route length in km, 2nd = straight-line distance in km; the route may detour or an end may be on the wrong road")
                warnings.append(w); lengthWarnings.append(w)
            }
            if max(best.ans.snapA, best.ans.snapB) > 150 { warnings.append(String(localized: "锚点离路网 \(best.ans.snapA, format: Fmt.f0) m / \(best.ans.snapB, format: Fmt.f0) m，端点可能接错路", comment: "Road-draft warning. 1st/2nd = distance from anchor A/B to the road network in m")) }
            if let v = impliedMps(best.ans.meters), v > 50 {
                let km = best.ans.meters / 1000, secs = seconds ?? 0, kmh = v * 3.6
                // 断档时长为 0 时 v = +∞：沿用旧 String(format: "%.0f") 的 "inf"，zh-Hans 输出逐字不变
                let speed = kmh.isFinite ? kmh.formatted(Fmt.f0) : "inf"
                let w = String(localized: "路径 \(km, format: Fmt.f2) km 要在 \(secs, format: Fmt.f0) s 内走完（\(speed) km/h），公路上不可能，端点可能接错路", comment: "Road-draft warning. 1st = route length in km, 2nd = gap duration in seconds, 3rd = implied speed in km/h (may be \"inf\"); impossible on a road")
                warnings.append(w); lengthWarnings.append(w)
            }
            if trace.count < 3, contextA == nil, contextB == nil {
                warnings.append(hasBearings ? String(localized: "两侧没有可用于上下文/匹配的真实轨迹点（前后点太远、跨了别的断档或停车超过 600 s），结果只按两端行进方向路由", comment: "Road-draft warning: no usable real track points on either side for Context/Match; the route only uses the travel direction at both ends. Glossary: 上下文 = Context, 匹配 = Match")
                                            : String(localized: "两侧没有可用的真实轨迹点（前后点太远、跨了别的断档或停车超过 600 s），结果只是两点间最短路", comment: "Road-draft warning: no usable real track points on either side; the result is just the shortest path between the two points"))
            }
            var notes: [String] = []
            let ratios = candidates.map { "\(candidateLabel($0.name)) \(ratio($0.ans.meters).formatted(Fmt.f2))" }.joined(separator: Fmt.listSeparator)
            let snapLimit = max(snapTol, 150)
            notes.append(String(localized: "候选（绕路比 = 路网长 / 直线，长度不含两端贴路）：\(ratios)；相差 ≤\(tie, format: Fmt.f0) m（直线的 5%，至少 40 m）算平手，按 匹配 > 上下文 > 约束 > 直接 取；贴路超过 \(snapLimit, format: Fmt.f0) m 的匹配/上下文不参选", comment: "Routing note explaining the candidate choice. 1st = list of \"method ratio\" pairs (e.g. \"匹配 1.05、上下文 1.10\"), 2nd = tie tolerance in m, 3rd = maximum snap distance in m. Contains a literal %. Method names must follow the glossary: 匹配 = Match, 上下文 = Context, 约束 = Constrained, 直接 = Direct"))
            let chosen = candidateLabel(best.name)
            notes.append(String(localized: "采用「\(chosen)」，贴路 \(best.ans.snapA, format: Fmt.f0) / \(best.ans.snapB, format: Fmt.f0) m", comment: "Routing note. 1st = chosen route method name (Match / Context / Constrained / Direct), 2nd/3rd = snap distance to the road at A/B in m"))
            if trace.count >= 3, !candidates.contains(where: { $0.name == "匹配" }) { notes.append(String(localized: "「匹配」没有结果（半径 \(matchRadius, format: Fmt.f0) m：A/B 没贴到路，或前后点之间按时间戳在路网上走不通）", comment: "Routing note: map matching gave no result. %@ = matching radius in m. Glossary: 匹配 = Match")) }
            notes += failedNotes
            return finish(best, warnings: warnings, lengthWarnings: lengthWarnings, notes: notes)
        }
        // 任一端点明确回答过"没路"就按没路报（后面镜像的传输错误不该盖过这个确定的答案）
        if !routingStatuses.isEmpty {
            throw RouteError.noRoute(routingStatuses.contains("NoSegment") ? String(localized: "锚点附近没有可行驶道路", comment: "No-route reason: there is no drivable road near the anchor")
                                                                            : String(localized: "两点之间没有可行驶路径", comment: "No-route reason: there is no drivable path between the two points"),
                                     partial: !errors.isEmpty)   // 另有候选传输失败：答案不完整，不进缓存
        }
        throw RouteError.allEndpointsFailed(errors)
    }

    /// 锚点离最近可行驶道路的距离（米）；用于自动分不清公路/铁路时让地图判断。失败返回 nil
    static func nearestRoadDistance(_ p: CLLocationCoordinate2D) async -> Double? {
        for base in carEndpoints {
            let nearestBase = base.replacingOccurrences(of: "/route/v1/driving/", with: "/nearest/v1/driving/")
            guard let url = URL(string: nearestBase + String(format: "%.6f,%.6f?number=1", p.longitude, p.latitude)) else { continue }
            do {
                let (data, _) = try await RateLimiter.shared.perform(host: host(base)) { try await session.data(from: url) }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (json["code"] as? String) == "Ok",
                      let wp = (json["waypoints"] as? [[String: Any]])?.first,
                      let d = (wp["distance"] as? NSNumber)?.doubleValue else { continue }
                return d
            } catch { continue }
        }
        return nil
    }

    /// 锚点离最近铁路（rail/light_rail/subway/tram 等）的距离（米，Overpass around 150 m）；150 m 内没有铁路返回 1e9；
    /// 请求失败返回 nil。用于"让地图判断"：公路网和铁路网各算一次距离，比只看公路可靠（车站旁也有街道）
    static func nearestRailDistance(_ p: CLLocationCoordinate2D) async -> Double? {
        let query = String(format: "[out:json][timeout:20];way(around:150,%.6f,%.6f)[\"railway\"~\"^(rail|light_rail|subway|narrow_gauge|tram|monorail)$\"];out geom;", p.latitude, p.longitude)
        for base in overpassEndpoints {
            guard let url = URL(string: base) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = ("data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)).data(using: .utf8)
            req.timeoutInterval = 30
            do {
                let (data, _) = try await RateLimiter.shared.perform(host: host(base), minInterval: 2.0) { try await overpassSession.data(for: req) }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let elements = json["elements"] as? [[String: Any]] else { continue }
                if let remark = json["remark"] as? String, !remark.isEmpty { continue }
                var best = 1e9
                for el in elements {
                    guard let geom = el["geometry"] as? [[String: Any]], geom.count >= 2 else { continue }
                    let pts = geom.compactMap { g -> CLLocationCoordinate2D? in
                        guard let la = (g["lat"] as? NSNumber)?.doubleValue, let lo = (g["lon"] as? NSNumber)?.doubleValue else { return nil }
                        return CLLocationCoordinate2D(latitude: la, longitude: lo)
                    }
                    if let c = clipPolyline(pts, from: p, to: p) { best = min(best, c.snapA) }
                }
                return best
            } catch { continue }
        }
        return nil
    }

    /// 多个点一次查：每点 150 m 内的铁路（union），返回每点到最近铁路的距离（1e9 = 150 m 内无；整个请求失败 → 全 nil）。
    /// 一段行程 6 个采样点只发 1 次 Overpass（公共实例排队慢、每次 2 s 限速，逐点查太慢）
    static func nearestRailDistances(_ pts: [CLLocationCoordinate2D]) async -> [Double?] {
        guard !pts.isEmpty else { return [] }
        let clauses = pts.map { String(format: "way(around:150,%.6f,%.6f)[\"railway\"~\"^(rail|light_rail|subway|narrow_gauge|tram|monorail)$\"];", $0.latitude, $0.longitude) }.joined()
        let query = "[out:json][timeout:25];(" + clauses + ");out geom;"
        // 公共 Overpass 排队常到 30–40 s：最多试 2 个镜像、各 45 s，失败就让调用方按"离公路远/近"退一步判
        let ordered = overpassEndpoints.sorted { a, _ in a.contains("overpass-api.de") }   // 主站最稳，先试它
        for base in ordered.prefix(3) {
            guard let url = URL(string: base) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = ("data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)).data(using: .utf8)
            req.timeoutInterval = 60
            do {
                let (data, _) = try await RateLimiter.shared.perform(host: host(base), minInterval: 2.0) { try await overpassSession.data(for: req) }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let elements = json["elements"] as? [[String: Any]] else { continue }
                if let remark = json["remark"] as? String, !remark.isEmpty { continue }
                let ways: [[CLLocationCoordinate2D]] = elements.compactMap { el in
                    guard let geom = el["geometry"] as? [[String: Any]], geom.count >= 2 else { return nil }
                    return geom.compactMap { g -> CLLocationCoordinate2D? in
                        guard let la = (g["lat"] as? NSNumber)?.doubleValue, let lo = (g["lon"] as? NSNumber)?.doubleValue else { return nil }
                        return CLLocationCoordinate2D(latitude: la, longitude: lo)
                    }
                }
                return pts.map { p in
                    var best = 1e9
                    for w in ways { if let c = clipPolyline(w, from: p, to: p) { best = min(best, c.snapA) } }
                    return best
                }
            } catch { continue }
        }
        return pts.map { _ in nil }
    }

    // MARK: 铁路（Overpass + 最短路）

    /// 铁路只补能明确是隧道的断档：OSM 铁路 way 带 tunnel 标签，取到 A→B 的铁路路径后看隧道占比；
    /// 占比 < railTunnelMinShare、或直线 > railMaxStraightKm、或时长 > railMaxSeconds（车厢屏蔽可以几百公里没点）→ 不补。
    /// 流程与公路同构：有上下文点时从 A′ 路由到 B′，整条几何做隧道口漂移判定（挪锚点）再沿线裁到 A–B，残余偏移末端靠拢
    static let railTunnelMinShare = 0.5, railMaxStraightKm = 60.0, railMaxSeconds = 25.0 * 60
    static func railRoute(a: CLLocationCoordinate2D, b: CLLocationCoordinate2D, cache: OverpassCache? = nil,
                          contextA: ContextAnchor? = nil, contextB: ContextAnchor? = nil,
                          portalA: [PortalSample] = [], portalB: [PortalSample] = [],
                          matchRadius: Double = 15, seconds: Double? = nil,
                          progress: Progress? = nil) async throws -> RouteDraft {
        let started = Date()
        let straight = GeoMath.haversine(a.latitude, a.longitude, b.latitude, b.longitude)
        if straight > railMaxStraightKm * 1000 || (seconds ?? 0) > railMaxSeconds { throw RouteError.railTooLong(km: straight / 1000, seconds: seconds ?? 0) }
        guard straight <= maxStraightKm * 1000 else { throw RouteError.tooFar(straight / 1000) }
        let ca = contextA?.coord ?? a, cb = contextB?.coord ?? b
        // 包围盒：四个点（A、B、A′、B′）外扩 15% 的直线距离（至少 1.5 km），两个方向用同一个边距。
        // 有缓存（批量）时放大到至少 6 km：同一条线上相邻的断档共用一次查询
        let margin = cache == nil ? max(0.15 * straight, 1500) : max(0.3 * straight, 6000)
        let lats = [a.latitude, b.latitude, ca.latitude, cb.latitude], lons = [a.longitude, b.longitude, ca.longitude, cb.longitude]
        let midLat = (lats.min()! + lats.max()!) / 2
        let dLat = margin / 110_540
        let dLon = margin / (111_320 * max(0.2, cos(midLat * .pi / 180)))
        let s = lats.min()! - dLat, n = lats.max()! + dLat
        let w = lons.min()! - dLon, e = lons.max()! + dLon
        func finish(_ elements: [[String: Any]], endpoint: String) throws -> RouteDraft {
            let tolOn = max(matchRadius, 10), tolDrift = max(1.5 * matchRadius, 20)
            // 车厢里的定位常偏 200–500 m：接入半径放宽到 400 m。上下文点 A′/B′ 接不上铁路或连不通时退回直接 A→B
            var path: RailPath
            var usedContext = contextA != nil || contextB != nil
            do { path = try shortestRailPath(elements: elements, a: ca, b: cb, attachRadius: railAttachRadius) }
            catch let e as RouteError where usedContext {
                guard case .noRailNearby = e else { if case .noRailPath = e { path = try shortestRailPath(elements: elements, a: a, b: b, attachRadius: railAttachRadius); usedContext = false } else { throw e } ; return try finishPath(path, usedContext: false, endpoint: endpoint, tolOn: tolOn, tolDrift: tolDrift) }
                path = try shortestRailPath(elements: elements, a: a, b: b, attachRadius: railAttachRadius); usedContext = false
            }
            return try finishPath(path, usedContext: usedContext, endpoint: endpoint, tolOn: tolOn, tolDrift: tolDrift)
        }
        func finishPath(_ path: RailPath, usedContext: Bool, endpoint: String, tolOn: Double, tolDrift: Double) throws -> RouteDraft {
            // 漂移判定 + 沿线裁剪（没有上下文的一侧样本为空，analyze 只投影不外推）
            let analysis = PortalDrift.analyze(raw: path.coords, a: a, b: b,
                                               portalA: (usedContext && contextA != nil) ? portalA : [], portalB: (usedContext && contextB != nil) ? portalB : [],
                                               tolOn: tolOn, tolDrift: tolDrift)
            var A = a, B = b, shiftA = 0, shiftB = 0
            if let sft = analysis.newA { A = sft.coord; shiftA = sft.shift }
            if let sft = analysis.newB { B = sft.coord; shiftB = sft.shift }
            guard let clip = PortalDrift.clip(raw: path.coords, a: A, b: B, arcA: analysis.arcA, arcB: analysis.arcB) else { throw RouteError.noRailPath }
            // 裁后区间 [arcA, arcB] 里隧道段占多少。弧长用与 analyze/clip 同一套局部平面（PortalDrift.Poly.acc），不混用 haversine
            let P = PortalDrift.Poly(path.coords, frame: PortalDrift.Frame(origin: a))
            let lo = min(analysis.arcA, analysis.arcB), hi = max(analysis.arcA, analysis.arcB)
            let span = max(1, hi - lo)
            var tunnelM = 0.0
            // 露天段：隧道之间没有一个点的露天线路。车厢屏蔽的断档在隧道密集线上也能凑够 50% 隧道，
            // 但中间会夹着几公里露天没点；真隧道群之间的露天段短（并群规则 ≤90 s）。两端的露天段是出隧道后重新定位的延迟，放宽
            var runs: [(start: Double, end: Double, tunnel: Bool)] = []
            for i in 0..<path.segTunnel.count {
                let s0 = max(P.acc[i], lo), s1 = min(P.acc[i + 1], hi)
                guard s1 > s0 else { continue }
                if path.segTunnel[i] { tunnelM += s1 - s0 }
                if let last = runs.last, last.tunnel == path.segTunnel[i], abs(last.end - s0) < 1 { runs[runs.count - 1].end = s1 }
                else { runs.append((s0, s1, path.segTunnel[i])) }
            }
            let share = tunnelM / span
            // 先排除"像停站"：几乎没动却过了很久（站台棚下没信号），不是隧道
            if let secs = seconds, secs > 0, clip.meters / secs * 3.6 < 20 {
                let kmh = clip.meters / secs * 3.6
                throw RouteError.railUnsure(String(localized: "按时长算只有 \(kmh, format: Fmt.f0) km/h（\(clip.meters, format: Fmt.f0) m / \(secs, format: Fmt.f0) s），更像停站/停车时没信号，不是隧道", comment: "Reason a rail gap is not filled. 1st = implied speed in km/h, 2nd = path length in m, 3rd = gap duration in s; looks like a station stop without signal, not a tunnel"))
            }
            var notes = analysis.notes
            let spanKm = span / 1000, pct = share * 100, tunnelKm = tunnelM / 1000
            notes.append(share >= railTunnelMinShare
                ? String(localized: "铁路路径 \(spanKm, format: Fmt.f1) km（OSM railway，隧道标签逐段）：隧道占 \(pct, format: Fmt.f0)%（\(tunnelKm, format: Fmt.f1) km），达到 50%", comment: "Rail routing note, tunnel share reaches 50 %. 1st = rail path length in km, 2nd = tunnel share in percent (followed by a literal %), 3rd = tunnel length in km. Keep \"OSM railway\" (the OSM tag) untranslated")
                : String(localized: "铁路路径 \(spanKm, format: Fmt.f1) km（OSM railway，隧道标签逐段）：隧道占 \(pct, format: Fmt.f0)%（\(tunnelKm, format: Fmt.f1) km），不到 50%", comment: "Rail routing note, tunnel share below 50 %. 1st = rail path length in km, 2nd = tunnel share in percent (followed by a literal %), 3rd = tunnel length in km. Keep \"OSM railway\" (the OSM tag) untranslated"))
            guard share >= railTunnelMinShare else { throw RouteError.railNotTunnel(share: share, meters: span) }
            let open = runs.filter { !$0.tunnel }
            let interior = open.filter { $0.start > lo + 1 && $0.end < hi - 1 }
            let interiorMax = interior.map { $0.end - $0.start }.max() ?? 0
            let endMax = open.filter { !($0.start > lo + 1 && $0.end < hi - 1) }.map { $0.end - $0.start }.max() ?? 0
            if interiorMax > max(2000, 0.3 * span) {
                let gapKm = interiorMax / 1000
                throw RouteError.railUnsure(String(localized: "隧道之间有 \(gapKm, format: Fmt.f1) km 露天线路一个点都没有（隧道占 \(pct, format: Fmt.f0)%），更像车厢里没信号", comment: "Reason a rail gap is not filled. 1st = length in km of open-air track between tunnels without any point, 2nd = tunnel share in percent (followed by a literal %); looks like no signal inside the train"))
            }
            if endMax > max(3000, 0.4 * span) {
                let gapKm = endMax / 1000
                throw RouteError.railUnsure(String(localized: "隧道口外 \(gapKm, format: Fmt.f1) km 露天线路没有点（出隧道后重新定位不该这么久），更像车厢里没信号", comment: "Reason a rail gap is not filled. %@ = length in km of open-air track outside the tunnel portal without points (re-acquiring GPS after a tunnel should not take that long)"))
            }
            let straight2 = GeoMath.haversine(A.latitude, A.longitude, B.latitude, B.longitude)
            // 路径可疑（绕路、端点接错、速度不像火车、像停站）：对铁路一律"拿不准不补"，不留作警告
            if clip.meters > max(3 * straight2, straight2 + 2000) {
                let pathKm = clip.meters / 1000, straightKm = straight2 / 1000
                throw RouteError.railUnsure(String(localized: "铁路路径 \(pathKm, format: Fmt.f1) km 远长于直线 \(straightKm, format: Fmt.f1) km，可能绕路或接错线", comment: "Reason a rail gap is not filled. 1st = rail path length in km, 2nd = straight-line distance in km; may detour or be attached to the wrong line"))
            }
            if max(clip.snapA, clip.snapB) > 150 { throw RouteError.railUnsure(String(localized: "锚点离铁路 \(clip.snapA, format: Fmt.f0) m / \(clip.snapB, format: Fmt.f0) m，端点可能接错线", comment: "Reason a rail gap is not filled. 1st/2nd = distance from anchor A/B to the railway in m; an end may be on the wrong line")) }
            if let secs = seconds, secs > 0 {
                let kmh = clip.meters / secs * 3.6
                let pathKm = clip.meters / 1000
                if kmh > 350 { throw RouteError.railUnsure(String(localized: "路径 \(pathKm, format: Fmt.f1) km 要在 \(secs, format: Fmt.f0) s 内走完（\(kmh, format: Fmt.f0) km/h），火车也不可能", comment: "Reason a rail gap is not filled. 1st = path length in km, 2nd = gap duration in s, 3rd = implied speed in km/h; impossible even for a train")) }
                if kmh < 20 { throw RouteError.railUnsure(String(localized: "按时长算只有 \(kmh, format: Fmt.f0) km/h，更像停站/停车时没信号，不是隧道", comment: "Reason a rail gap is not filled. %@ = implied speed in km/h; looks like a station stop without signal, not a tunnel")) }
            }
            notes.append(String(localized: "露天段：隧道之间最长 \(interiorMax, format: Fmt.f0) m，两端最长 \(endMax, format: Fmt.f0) m，当作隧道断档补", comment: "Rail routing note. 1st = longest open-air section between tunnels in m, 2nd = longest open-air section at the ends in m; filled as a tunnel gap"))
            var warnings: [String] = []
            if max(clip.snapA, clip.snapB) > 60 { warnings.append(String(localized: "锚点离铁路 \(clip.snapA, format: Fmt.f0) m / \(clip.snapB, format: Fmt.f0) m", comment: "Rail-draft warning. 1st/2nd = distance from anchor A/B to the railway in m")) }
            let railStepA = min(100, max(10, portalA.first?.meters ?? 30)), railStepB = min(100, max(10, portalB.first?.meters ?? 30))
            let trimmed = trimEnds(clip.coords, a: A, b: B, stepA: railStepA, stepB: railStepB)
            let tapered = PortalDrift.taper(trimmed, a: A, b: B,
                                            dA: trimmed.first.map { p in clip.coords.first.map { $0.latitude == p.latitude && $0.longitude == p.longitude } ?? false } == true ? clip.snapA : nil,
                                            dB: trimmed.last.map { p in clip.coords.last.map { $0.latitude == p.latitude && $0.longitude == p.longitude } ?? false } == true ? clip.snapB : nil)
            var d = RouteDraft(source: .overpassRail, coords: tapered.coords, meters: clip.meters, snapA: clip.snapA, snapB: clip.snapB,
                               endpoint: endpoint, warnings: warnings, notes: notes + tapered.notes, method: .rail)
            d.shiftA = shiftA; d.shiftB = shiftB
            d.anchorA = shiftA > 0 ? A : nil; d.anchorB = shiftB > 0 ? B : nil
            d.residualA = clip.snapA; d.residualB = clip.snapB
            d.taperA = tapered.dA; d.taperB = tapered.dB
            return d
        }
        if let cache, let cached = cache.lookup(s: s, w: w, n: n, e: e) {
            return try finish(cached, endpoint: String(localized: "缓存", comment: "Server name shown for a rail draft that came from the local Overpass cache (no request sent)"))
        }
        let query = String(format: "[out:json][timeout:55];way[\"railway\"~\"^(rail|light_rail|narrow_gauge|subway|monorail|tram)$\"](%.5f,%.5f,%.5f,%.5f);out geom;", s, w, n, e)
        var errors: [String] = []
        for (k, base) in overpassEndpoints.enumerated() {
            try Task.checkCancellation()
            let remaining = 150 - Date().timeIntervalSince(started)
            if remaining < 10 { errors.append(String(localized: "总时长已到 150 s，放弃", comment: "Rail routing error entry: the total time limit of 150 s was reached, giving up")); break }
            let hostName = host(base), step = k + 1, total = overpassEndpoints.count
            progress?(String(localized: "请求 Overpass 铁路…（\(hostName)，\(step)/\(total)，公共实例常排队 30–60 秒）", comment: "Progress text while fetching rail geometry. 1st = server host name, 2nd = attempt number, 3rd = number of servers; public instances often queue for 30–60 s"))
            guard let url = URL(string: base) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = min(60, remaining)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = ("data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)).data(using: .utf8)
            do {
                let (data, resp) = try await RateLimiter.shared.perform(host: host(base), minInterval: 2.0) { try await overpassSession.data(for: req) }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else { errors.append("\(host(base)) HTTP \(code)"); continue }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let elements = json["elements"] as? [[String: Any]] else {
                    errors.append(String(localized: "\(hostName) 非 JSON", comment: "Rail routing error entry. %@ = server host name; the response is not JSON")); continue
                }
                // Overpass 的运行时错误（查询超时/内存）是 HTTP 200 + remark，数据不完整：换镜像
                if let remark = json["remark"] as? String, !remark.isEmpty {
                    errors.append("\(host(base)) \(remark.prefix(80))"); continue
                }
                cache?.store(s: s, w: w, n: n, e: e, elements: elements)
                return try finish(elements, endpoint: host(base))
            } catch let e as RouteError {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as URLError where e.code == .cancelled {
                throw CancellationError()
            } catch {
                errors.append("\(host(base)) \(error.localizedDescription)")
            }
        }
        throw RouteError.allEndpointsFailed(errors)
    }

    /// 铁路最短路的结果：完整路径几何（含两端接入点）、每段是否隧道、累计弧长、两端接入距离
    struct RailPath {
        var coords: [CLLocationCoordinate2D]
        var segTunnel: [Bool]       // coords[i]→coords[i+1] 是否在 tunnel=yes（或 subway/covered）的 way 上
        var acc: [Double]           // 每个顶点的累计弧长
        var snapA: Double
        var snapB: Double
    }

    /// 把 Overpass 的 way 几何拼成图，A/B 各吸附到最近节点，Dijkstra；每条边记住所属 way 是否隧道
    static let railAttachRadius = 400.0
    static func shortestRailPath(elements: [[String: Any]], a: CLLocationCoordinate2D, b: CLLocationCoordinate2D, attachRadius: Double = 150) throws -> RailPath {
        var coord: [Int64: CLLocationCoordinate2D] = [:]
        var adj: [Int64: [(Int64, Double)]] = [:]
        var edges: [(Int64, Int64)] = []
        var edgeTunnel: [Bool] = []
        struct Pair: Hashable { let u: Int64; let v: Int64; init(_ a: Int64, _ b: Int64) { u = min(a, b); v = max(a, b) } }
        var pairTunnel: [Pair: Bool] = [:]
        for el in elements {
            guard (el["type"] as? String) == "way",
                  let nodes = el["nodes"] as? [NSNumber], let geom = el["geometry"] as? [[String: Any]],
                  nodes.count == geom.count, nodes.count >= 2 else { continue }
            let tags = el["tags"] as? [String: String] ?? [:]
            // tunnel 标签优先；明确 bridge 的不算；没标的只在 subway 且 layer<0 / location=underground 时算隧道（高架地铁、地面段不算）
            let tunnel: Bool
            if let tv = tags["tunnel"] { tunnel = tv != "no" }
            else if let bv = tags["bridge"], bv != "no" { tunnel = false }
            else if let cv = tags["covered"], cv != "no" { tunnel = true }
            else if tags["location"] == "underground" { tunnel = true }
            else { tunnel = tags["railway"] == "subway" && (Int(tags["layer"] ?? "0") ?? 0) < 0 }
            var prev: (Int64, CLLocationCoordinate2D)?
            for (k, g) in geom.enumerated() {
                guard let lat = g["lat"] as? Double, let lon = g["lon"] as? Double else { prev = nil; continue }
                let id = nodes[k].int64Value
                let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                coord[id] = c
                if let (pid, pc) = prev, pid != id {
                    let wgt = GeoMath.haversine(pc.latitude, pc.longitude, lat, lon)
                    adj[pid, default: []].append((id, wgt))
                    adj[id, default: []].append((pid, wgt))
                    edges.append((pid, id)); edgeTunnel.append(tunnel)
                    pairTunnel[Pair(pid, id)] = tunnel
                }
                prev = (id, c)
            }
        }
        guard !coord.isEmpty else { throw RouteError.noRailNearby(.infinity, .infinity) }
        // 接入点：把锚点投影到附近每条铁路线段上（节点间距可达数百米、手机定位误差也大，不能只看节点）。
        // 双线铁路是两条平行 way，上下行各自接入，Dijkstra 多源多汇自然选通的那条。
        // 同一条线段上的接入点按 t 排序后把线段真正切开（u–f1–f2–…–v），A、B 落在同一段时才能直接相连
        var nextVirtual: Int64 = -1
        var attachments: [Int: [(vid: Int64, t: Double)]] = [:]     // 边下标 → 接入点
        var snapOf: [Int64: Double] = [:]                            // 接入点 → 锚点到它的距离
        func attach(_ p: CLLocationCoordinate2D, radius: Double) -> (ids: [Int64], best: Double) {
            let kx = 111_320.0 * cos(p.latitude * .pi / 180), ky = 110_540.0
            var best = Double.infinity
            var found: [Int64] = []
            for (ei, (u, v)) in edges.enumerated() {
                guard let cu = coord[u], let cv = coord[v] else { continue }
                let ux = (cu.longitude - p.longitude) * kx, uy = (cu.latitude - p.latitude) * ky
                let vx = (cv.longitude - p.longitude) * kx, vy = (cv.latitude - p.latitude) * ky
                let dx = vx - ux, dy = vy - uy
                let len2 = dx * dx + dy * dy
                let t = len2 > 0 ? max(0, min(1, -(ux * dx + uy * dy) / len2)) : 0
                let fx = ux + dx * t, fy = uy + dy * t
                let d = (fx * fx + fy * fy).squareRoot()
                best = min(best, d)
                guard d <= radius else { continue }
                let vid = nextVirtual; nextVirtual -= 1
                coord[vid] = CLLocationCoordinate2D(latitude: p.latitude + fy / ky, longitude: p.longitude + fx / kx)
                attachments[ei, default: []].append((vid, t))
                snapOf[vid] = d
                found.append(vid)
            }
            return (found, best)
        }
        let (srcs, da) = attach(a, radius: attachRadius), (dsts, db) = attach(b, radius: attachRadius)
        guard !srcs.isEmpty, !dsts.isEmpty else { throw RouteError.noRailNearby(da, db) }
        for (ei, list) in attachments {
            let (u, v) = edges[ei]
            let chain = [u] + list.sorted { $0.t < $1.t }.map { $0.vid } + [v]
            for k in 1..<chain.count {
                let p = chain[k - 1], q = chain[k]
                guard let cp = coord[p], let cq = coord[q] else { continue }
                let wgt = GeoMath.haversine(cp.latitude, cp.longitude, cq.latitude, cq.longitude)
                adj[p, default: []].append((q, wgt))
                adj[q, default: []].append((p, wgt))
                pairTunnel[Pair(p, q)] = edgeTunnel[ei]
            }
        }
        // 超级汇点：每个 B 侧接入点连到汇点，权重 = 离线段的距离 ×3（离开轨道的"横跳"比沿轨道走更贵，
        // 避免为了少走 50 m 轨道而接到 140 m 外的另一条线上）；A 侧同样以 ×3 的接入距离起步
        let sink: Int64 = Int64.min + 1
        let chordWeight = 3.0
        let targetSet = Set(dsts)
        for t in dsts { adj[t, default: []].append((sink, (snapOf[t] ?? 0) * chordWeight)) }
        var dist: [Int64: Double] = [:]
        var prevNode: [Int64: Int64] = [:]
        var heap: [(Double, Int64)] = []
        func push(_ x: (Double, Int64)) { heap.append(x); var i = heap.count - 1; while i > 0 { let p = (i - 1) / 2; if heap[p].0 <= heap[i].0 { break }; heap.swapAt(p, i); i = p } }
        func pop() -> (Double, Int64)? {
            guard !heap.isEmpty else { return nil }
            let top = heap[0]; let last = heap.removeLast()
            if !heap.isEmpty { heap[0] = last; var i = 0
                while true { let l = 2 * i + 1, r = l + 1; var m = i
                    if l < heap.count, heap[l].0 < heap[m].0 { m = l }
                    if r < heap.count, heap[r].0 < heap[m].0 { m = r }
                    if m == i { break }; heap.swapAt(m, i); i = m } }
            return top
        }
        for id in srcs { let d0 = (snapOf[id] ?? 0) * chordWeight; dist[id] = d0; push((d0, id)) }
        var reachedSink = false
        while let (d, u) = pop() {
            if d > (dist[u] ?? .infinity) { continue }
            if u == sink { reachedSink = true; break }
            for (v, wgt) in adj[u] ?? [] {
                let nd = d + wgt
                if nd < (dist[v] ?? .infinity) { dist[v] = nd; prevNode[v] = u; push((nd, v)) }
            }
        }
        guard reachedSink, let sb = prevNode[sink], targetSet.contains(sb) else { throw RouteError.noRailPath }
        var ids: [Int64] = []
        var cur = sb
        while true { ids.append(cur); guard let p = prevNode[cur] else { break }; cur = p }
        ids.reverse()
        let path = ids.compactMap { coord[$0] }
        var segTunnel: [Bool] = [], acc = [0.0]
        for k in 1..<path.count {
            segTunnel.append(pairTunnel[Pair(ids[k - 1], ids[k])] ?? false)
            acc.append(acc[k - 1] + GeoMath.haversine(path[k - 1].latitude, path[k - 1].longitude, path[k].latitude, path[k].longitude))
        }
        return RailPath(coords: path, segTunnel: segTunnel, acc: acc, snapA: snapOf[ids.first!] ?? da, snapB: snapOf[sb] ?? db)
    }

    /// 把折线裁到 a、b 在折线上投影点之间的那一段（a 的投影在 b 之后则反向）。
    /// 返回 nil = 折线太短；meters = 裁后几何长度；snapA/B = 锚点到折线的垂距
    static func clipPolyline(_ pts: [CLLocationCoordinate2D], from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D)
        -> (coords: [CLLocationCoordinate2D], meters: Double, snapA: Double, snapB: Double)? {
        guard pts.count >= 2 else { return nil }
        let kx = 111_320.0 * cos(a.latitude * .pi / 180), ky = 110_540.0
        func xy(_ p: CLLocationCoordinate2D) -> (Double, Double) { ((p.longitude - a.longitude) * kx, (p.latitude - a.latitude) * ky) }
        let P = pts.map(xy)
        func project(_ q: CLLocationCoordinate2D) -> (seg: Int, t: Double, s: Double, d: Double, pt: CLLocationCoordinate2D) {
            let (qx, qy) = xy(q)
            var best = (seg: 0, t: 0.0, s: 0.0, d: Double.infinity, pt: pts[0]); var acc = 0.0
            for k in 1..<pts.count {
                let (ux, uy) = P[k - 1], (vx, vy) = P[k]
                let dx = vx - ux, dy = vy - uy, len2 = dx * dx + dy * dy
                let t = len2 > 0 ? max(0, min(1, ((qx - ux) * dx + (qy - uy) * dy) / len2)) : 0
                let fx = ux + dx * t, fy = uy + dy * t
                let d = ((fx - qx) * (fx - qx) + (fy - qy) * (fy - qy)).squareRoot()
                let segLen = len2.squareRoot()
                if d < best.d {
                    best = (k - 1, t, acc + segLen * t, d,
                            CLLocationCoordinate2D(latitude: a.latitude + fy / ky, longitude: a.longitude + fx / kx))
                }
                acc += segLen
            }
            return best
        }
        var pa = project(a), pb = project(b)
        var reversed = false
        if pa.s > pb.s { swap(&pa, &pb); reversed = true }
        var out: [CLLocationCoordinate2D] = [pa.pt]
        if pb.seg >= pa.seg + 1 { for k in (pa.seg + 1)...pb.seg { out.append(pts[k]) } }
        out.append(pb.pt)
        if reversed { out.reverse() }
        var meters = 0.0
        for k in 1..<out.count { meters += GeoMath.haversine(out[k - 1].latitude, out[k - 1].longitude, out[k].latitude, out[k].longitude) }
        let (sa, sb) = reversed ? (pb.d, pa.d) : (pa.d, pb.d)
        // 长度只算路径本身，不含两端贴路：/route 的 distance 与 /match 的腿距离都不含，
        // 否则手机 15–56 m 的贴路会在 200–600 m 的短弦上给上下文候选虚增 0.1–0.2 的绕路比
        return (out, meters, sa, sb)
    }

    /// 去掉紧挨两端锚点（<30 m）的路网点，避免折线在锚点旁边打小折。
    /// 只有「删掉后新首点离锚点仍 ≤ max(60, 2×局部步长)」才删：隧道 way 常只有两个节点，裁剪投影点后面的下一顶点
    /// 可能在 150 m 外，删了投影点整条直边就丢了（Muenchen_Roma 第 14/16/19 处）——这时保留投影点。
    /// stepA/stepB = 锚点外侧真实点的局部步长（米），B 侧对称
    static func trimEnds(_ pts: [CLLocationCoordinate2D], a: CLLocationCoordinate2D, b: CLLocationCoordinate2D,
                         stepA: Double = 30, stepB: Double = 30) -> [CLLocationCoordinate2D] {
        var p = pts
        func dist(_ x: CLLocationCoordinate2D, _ y: CLLocationCoordinate2D) -> Double { GeoMath.haversine(x.latitude, x.longitude, y.latitude, y.longitude) }
        let reachA = max(60, 2 * stepA), reachB = max(60, 2 * stepB)
        while p.count >= 2, dist(p[0], a) < 30, dist(p[1], a) <= reachA { p.removeFirst() }
        while p.count >= 2, dist(p[p.count - 1], b) < 30, dist(p[p.count - 2], b) <= reachB { p.removeLast() }
        return p
    }

    private static func host(_ base: String) -> String { URL(string: base)?.host ?? base }

    /// 公路候选的内部名（匹配 / 上下文 / 远上下文 / 约束 / 直接）只用于比较与排序，不翻译；进说明 / 错误文字时换成界面显示名
    private static func candidateLabel(_ name: String) -> String {
        if let m = RouteMethod(candidateName: name) { return m.label }
        return name == "远上下文" ? String(localized: "远上下文", comment: "Route candidate name: context route from a real point ~600–900 m before A / after B. Glossary: Far Context") : name
    }
}

// MARK: - 通行侧（靠左/靠右）：按国家码查表，位置 → 国家用 Apple 逆地理编码，按 1° 格缓存

enum TrafficSide {
    /// 靠左通行的国家/地区（ISO 3166-1 alpha-2）
    static let leftHandISO: Set<String> = ["GB", "IE", "IM", "JE", "GG", "MT", "CY", "JP", "AU", "NZ", "IN", "PK", "BD", "LK", "NP", "BT", "ID", "MY", "SG", "TH", "BN", "TL", "PG",
                                           "HK", "MO", "ZA", "NA", "BW", "ZW", "ZM", "MW", "MZ", "TZ", "KE", "UG", "LS", "SZ", "MU", "SC", "JM", "BB", "TT", "BS", "GY", "SR",
                                           "FJ", "WS", "TO", "SB", "KI", "TV", "NR", "VG", "KY", "BM", "AG", "DM", "GD", "KN", "LC", "VC", "MS", "AI", "TC", "FK", "SH", "CK", "NU", "TK", "PN", "MV", "MP"]
    private actor Cache {
        var cells: [String: Bool?] = [:]
        func get(_ k: String) -> Bool?? { cells[k] }
        func set(_ k: String, _ v: Bool?) { cells[k] = v }
    }
    private static let cache = Cache()
    /// 离线兜底：几块大且无争议的靠左通行区域（纬度 / 经度范围），查不到国家时用它粗判
    static let leftHandBoxes: [(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, name: String)] = [
        (49.8, 60.9, -10.7, 1.5, "英国/爱尔兰"), (24.0, 45.6, 122.9, 146.0, "日本"), (-43.7, -10.5, 112.9, 153.7, "澳大利亚"),
        (-47.4, -34.3, 166.4, 178.6, "新西兰"), (-35.0, -22.0, 16.4, 33.0, "南非"), (6.5, 35.5, 68.1, 92.0, "印度/巴基斯坦/尼泊尔/孟加拉"),
        (-11.0, 6.0, 95.0, 141.0, "印度尼西亚"),
    ]
    static func leftHandByBox(_ c: CLLocationCoordinate2D) -> Bool {
        leftHandBoxes.contains { c.latitude >= $0.minLat && c.latitude <= $0.maxLat && c.longitude >= $0.minLon && c.longitude <= $0.maxLon }
    }
    /// 该位置是否靠左通行；nil = 查不到国家（离线或逆地理编码失败），调用方可退到 leftHandByBox
    static func leftHand(at c: CLLocationCoordinate2D) async -> Bool? {
        let key = "\(Int(floor(c.latitude))),\(Int(floor(c.longitude)))"
        if let hit = await cache.get(key) { return hit }
        var result: Bool? = nil
        let t0 = Date()
        do {
            let marks = try await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude))
            if let iso = marks.first?.isoCountryCode?.uppercased() { result = leftHandISO.contains(iso) }
            NetworkHealth.note(host: "geocode", ok: true, seconds: Date().timeIntervalSince(t0))
        } catch {
            NetworkHealth.note(host: "geocode", ok: (error as? CLError)?.code != .network, seconds: Date().timeIntervalSince(t0), detail: NetworkHealth.describe(error))
        }
        if result != nil { await cache.set(key, result) }   // 查失败不缓存，下次再试
        return result
    }
}

// MARK: - 隧道口定位漂移：锚点外推、沿线裁剪、末端渐进靠拢（纯几何，可离线测）

/// 隧道口的 GPS 常常先"飘"几个点再回到路上：锚点本身离路 20–80 m，再往外 2–5 个点就回到 0–8 m。
/// 以上下文路由（A′→B′）的整条几何为"路"，量锚点外侧真实点离路多远：锚点离路 > tolDrift 而外侧某点（及其下一点）≤ tolOn，
/// 就把锚点挪到那个点，跳过的漂移点随补点区间一起替换。挪不动的（外侧一串点都偏——整体偏移/对向车道）不动锚点，
/// 由 taper 把路径末端在 L 米内渐进平移到锚点，不留垂直于路的急拐。
/// 裁剪按"沿线弧长"而不是"全局最近投影"：路由在 B 附近经过两次（过头后掉头回来）时取第一次，绕圈不进草稿
enum PortalDrift {
    struct Frame {
        let origin: CLLocationCoordinate2D
        let kx: Double, ky: Double
        init(origin: CLLocationCoordinate2D) {
            self.origin = origin
            kx = 111_320.0 * cos(origin.latitude * .pi / 180); ky = 110_540.0
        }
        func xy(_ p: CLLocationCoordinate2D) -> SIMD2<Double> { SIMD2((p.longitude - origin.longitude) * kx, (p.latitude - origin.latitude) * ky) }
        func coord(_ v: SIMD2<Double>) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: origin.latitude + v.y / ky, longitude: origin.longitude + v.x / kx) }
    }
    struct Hit { var seg: Int; var t: Double; var s: Double; var d: Double; var pt: SIMD2<Double> }
    struct Poly {
        let pts: [SIMD2<Double>]
        let acc: [Double]                  // 每个顶点的弧长位置
        var length: Double { acc.last ?? 0 }
        init(_ coords: [CLLocationCoordinate2D], frame f: Frame) {
            let p = coords.map(f.xy)
            var a = [0.0]; a.reserveCapacity(p.count)
            for k in 1..<max(1, p.count) { a.append(a[k - 1] + simd_length(p[k] - p[k - 1])) }
            pts = p; acc = a
        }
        /// q 到折线的最近点；window 限定只在这段弧长范围内找（防止投影到折返的另一趟）
        func project(_ q: SIMD2<Double>, window: ClosedRange<Double>? = nil) -> Hit {
            var best = Hit(seg: 0, t: 0, s: 0, d: .infinity, pt: pts.first ?? q)
            guard pts.count >= 2 else { return best }
            for k in 1..<pts.count {
                if let w = window, acc[k] < w.lowerBound || acc[k - 1] > w.upperBound { continue }
                let u = pts[k - 1], v = pts[k], dv = v - u, len2 = simd_length_squared(dv)
                let t = len2 > 0 ? max(0, min(1, simd_dot(q - u, dv) / len2)) : 0
                let f = u + dv * t, d = simd_length(f - q)
                if d < best.d { best = Hit(seg: k - 1, t: t, s: acc[k - 1] + len2.squareRoot() * t, d: d, pt: f) }
            }
            return best
        }
        /// 折线经过 q 附近（≤ within）的每一次：连续在容差内的一段取最近点，按弧长排序
        func passes(_ q: SIMD2<Double>, within: Double) -> [Hit] {
            guard pts.count >= 2 else { return [] }
            var out: [Hit] = []
            var run: Hit? = nil
            for k in 1..<pts.count {
                let u = pts[k - 1], v = pts[k], dv = v - u, len2 = simd_length_squared(dv)
                let t = len2 > 0 ? max(0, min(1, simd_dot(q - u, dv) / len2)) : 0
                let f = u + dv * t, d = simd_length(f - q)
                if d <= within {
                    let h = Hit(seg: k - 1, t: t, s: acc[k - 1] + len2.squareRoot() * t, d: d, pt: f)
                    if let r = run { if h.d < r.d { run = h } } else { run = h }
                } else if let r = run { out.append(r); run = nil }
            }
            if let r = run { out.append(r) }
            return out
        }
        /// 第 seg 段的行进方位（北 0 顺时针；x 东 y 北）
        func bearing(seg: Int) -> Double {
            guard seg >= 0, seg + 1 < pts.count else { return 0 }
            let d = pts[seg + 1] - pts[seg]
            let b = atan2(d.x, d.y) * 180 / .pi
            return b < 0 ? b + 360 : b
        }
        func slice(from a: Hit, to b: Hit) -> [SIMD2<Double>] {
            var out = [a.pt]
            if b.seg >= a.seg + 1 { for k in (a.seg + 1)...b.seg { out.append(pts[k]) } }
            out.append(b.pt)
            return out
        }
    }

    struct Shift { var index: Int; var coord: CLLocationCoordinate2D; var shift: Int; var arc: Double; var onRoad: Double }
    struct Analysis {
        var newA: Shift?; var newB: Shift?
        var arcA: Double; var arcB: Double      // 锚点（挪后）在几何上的弧长位置，裁剪用
        var notes: [String]
    }

    /// 两端漂移判定。portalA 从 A 往前（时间更早）数、portalB 从 B 往后数，都是"离锚点越来越远"的顺序
    /// 经过的行进方向与真实轨迹的行进方向差 ≤75° 才算（分向车道的对向那趟、盘山回头弯的另一条腿直接出局）
    static func consistent(_ P: Poly, _ h: Hit, _ bearing: Double?) -> Bool {
        guard let bearing else { return true }
        var d = abs(P.bearing(seg: h.seg) - bearing)
        if d > 180 { d = 360 - d }
        return d <= 75
    }
    static func analyze(raw: [CLLocationCoordinate2D], a: CLLocationCoordinate2D, b: CLLocationCoordinate2D,
                        portalA: [RoadNetwork.PortalSample], portalB: [RoadNetwork.PortalSample],
                        tolOn: Double, tolDrift: Double, bearingA: Double? = nil, bearingB: Double? = nil) -> Analysis {
        let f = Frame(origin: a)
        let P = Poly(raw, frame: f)
        let qa = f.xy(a), qb = f.xy(b)
        let pa0 = P.project(qa), pb0 = P.project(qb)
        // 经过位置：A 取最早一次；B 取 A 之后最早一次；A 在那之前若还经过一次取最后那次（A′→…→A 之间的折返不属于 A–B）。
        // 方向不一致的经过先剔掉（全被剔掉就退回不看方向）
        func filtered(_ ps: [Hit], _ bearing: Double?) -> [Hit] { let c = ps.filter { consistent(P, $0, bearing) }; return c.isEmpty ? ps : c }
        let passesA = filtered(P.passes(qa, within: max(25, 1.5 * pa0.d + 10)), bearingA)
        let passesB = filtered(P.passes(qb, within: max(25, 1.5 * pb0.d + 10)), bearingB)
        var sA = passesA.first?.s ?? pa0.s
        var sB = passesB.first(where: { $0.s > sA + 5 })?.s ?? (pb0.s > sA ? pb0.s : (passesB.last?.s ?? pb0.s))
        if let later = passesA.last(where: { $0.s < sB - 5 }) { sA = later.s }
        var notes: [String] = []
        func m(_ x: Double) -> String { String(format: "%.0f", x) }
        func side(_ name: String, samples: [RoadNetwork.PortalSample], s0: Double, d0: Double, forward: Bool) -> (Shift?, Double) {
            guard !samples.isEmpty else {
                if d0 > tolDrift {
                    let off = m(d0)
                    notes.append(String(localized: "\(name) 离路 \(off) m，但这一侧没有可用的上下文点，判断不了是不是隧道口漂移；末端渐进靠拢", comment: "Tunnel-portal drift note. 1st = anchor letter (A or B, keep as is), 2nd = distance of the anchor from the road in m; no context points on this side, so drift cannot be judged; the route end is tapered towards the anchor"))
                }
                return (nil, s0)
            }
            var hits: [Hit] = []
            for smp in samples {
                let w = forward ? (s0 - 100)...(s0 + 1.6 * smp.meters + 150) : (s0 - 1.6 * smp.meters - 150)...(s0 + 100)
                hits.append(P.project(f.xy(smp.coord), window: w))
            }
            guard d0 > tolDrift else { return (nil, s0) }
            for k in 0..<samples.count {
                // 外侧出现停车（几乎没动却过了 ≥5 s）就到此为止：停车点是真实的，不能当漂移替换掉
                if k > 0, samples[k].meters - samples[k - 1].meters < 3, samples[k].seconds - samples[k - 1].seconds >= 5 {
                    let off = m(d0), nth = k + 1
                    notes.append(String(localized: "\(name) 离路 \(off) m，但往外第 \(nth) 个点处停了车，不再外推；末端渐进靠拢", comment: "Tunnel-portal drift note. 1st = anchor letter (A or B), 2nd = distance of the anchor from the road in m, 3rd = ordinal of the outward point where the vehicle stopped; the anchor is not moved further, the route end is tapered"))
                    return (nil, s0)
                }
                let ok = hits[k].d <= tolOn && (k + 1 < samples.count ? hits[k + 1].d <= tolOn : true)
                if ok {
                    let skipped = hits.prefix(k).map { m($0.d) }.joined(separator: "/")
                    let off = m(d0), back = m(hits[k].d), nth = k + 1
                    // 四个整句变体：有没有"再往外 k 个点"一段 × 后移（B 侧）/ 前移（A 侧）
                    let note: String
                    if k > 0 {
                        note = forward
                            ? String(localized: "\(name) 离路 \(off) m、再往外 \(k) 个点离路 \(skipped) m，第 \(nth) 个点回到路上（\(back) m）→ 隧道口定位漂移：\(name) 后移 \(nth) 点，跳过的点随区间一起替换", comment: "Tunnel-portal drift note, anchor moved later in time (B side). 1st = anchor letter (A or B), 2nd = anchor distance from the road in m, 3rd = number of further outward points also off the road, 4th = their distances in m joined by /, 5th = ordinal of the first point back on the road, 6th = its distance from the road in m, 7th = anchor letter again, 8th = number of points the anchor moves")
                            : String(localized: "\(name) 离路 \(off) m、再往外 \(k) 个点离路 \(skipped) m，第 \(nth) 个点回到路上（\(back) m）→ 隧道口定位漂移：\(name) 前移 \(nth) 点，跳过的点随区间一起替换", comment: "Tunnel-portal drift note, anchor moved earlier in time (A side). 1st = anchor letter (A or B), 2nd = anchor distance from the road in m, 3rd = number of further outward points also off the road, 4th = their distances in m joined by /, 5th = ordinal of the first point back on the road, 6th = its distance from the road in m, 7th = anchor letter again, 8th = number of points the anchor moves")
                    } else {
                        note = forward
                            ? String(localized: "\(name) 离路 \(off) m，第 \(nth) 个点回到路上（\(back) m）→ 隧道口定位漂移：\(name) 后移 \(nth) 点，跳过的点随区间一起替换", comment: "Tunnel-portal drift note, anchor moved later in time (B side). 1st = anchor letter (A or B), 2nd = anchor distance from the road in m, 3rd = ordinal of the first point back on the road, 4th = its distance from the road in m, 5th = anchor letter again, 6th = number of points the anchor moves")
                            : String(localized: "\(name) 离路 \(off) m，第 \(nth) 个点回到路上（\(back) m）→ 隧道口定位漂移：\(name) 前移 \(nth) 点，跳过的点随区间一起替换", comment: "Tunnel-portal drift note, anchor moved earlier in time (A side). 1st = anchor letter (A or B), 2nd = anchor distance from the road in m, 3rd = ordinal of the first point back on the road, 4th = its distance from the road in m, 5th = anchor letter again, 6th = number of points the anchor moves")
                    }
                    notes.append(note)
                    return (Shift(index: samples[k].index, coord: samples[k].coord, shift: k + 1, arc: hits[k].s, onRoad: hits[k].d), hits[k].s)
                }
            }
            let ds = hits.map(\.d)
            let off = m(d0), within = m(samples.last!.meters), dMin = m(ds.min()!), dMax = m(ds.max()!)
            notes.append(String(localized: "\(name) 离路 \(off) m，往外 \(samples.count) 个点（\(within) m 内）离路 \(dMin)–\(dMax) m 都没回到路上：不像隧道口漂移（像整体偏移或对向车道），不挪锚点，末端渐进靠拢", comment: "Tunnel-portal drift note. 1st = anchor letter (A or B), 2nd = anchor distance from the road in m, 3rd = number of outward points checked, 4th = how far out they reach in m, 5th/6th = min/max distance of those points from the road in m; not a portal drift (looks like a global offset or the opposite carriageway), the anchor is not moved, the route end is tapered"))
            return (nil, s0)
        }
        let (shA, arcA) = side("A", samples: portalA, s0: sA, d0: P.project(qa, window: (sA - 60)...(sA + 60)).d, forward: false)
        let (shB, arcB) = side("B", samples: portalB, s0: sB, d0: P.project(qb, window: (sB - 60)...(sB + 60)).d, forward: true)
        if passesB.count > 1 || passesA.count > 1 {
            notes.append(String(localized: "路由在锚点附近经过了不止一次（\(passesA.count)/\(passesB.count) 次），按沿线顺序取 A 之后第一次到 B 的那段，折返不进草稿", comment: "Routing note. 1st/2nd = how many times the route passes near anchor A/B; the section from A to the first arrival at B is used, the back-and-forth is dropped"))
        }
        return Analysis(newA: shA, newB: shB, arcA: arcA, arcB: arcB, notes: notes)
    }

    /// 在已知弧长位置附近裁出 A–B 段（投影只在 ±80 m 弧长窗内找）
    static func clip(raw: [CLLocationCoordinate2D], a: CLLocationCoordinate2D, b: CLLocationCoordinate2D, arcA: Double, arcB: Double)
        -> (coords: [CLLocationCoordinate2D], meters: Double, snapA: Double, snapB: Double)? {
        guard raw.count >= 2 else { return nil }
        let f = Frame(origin: a)
        let P = Poly(raw, frame: f)
        var pa = P.project(f.xy(a), window: (arcA - 80)...(arcA + 80)), pb = P.project(f.xy(b), window: (arcB - 80)...(arcB + 80))
        if !pa.d.isFinite { pa = P.project(f.xy(a)) }
        if !pb.d.isFinite { pb = P.project(f.xy(b)) }
        guard pa.d.isFinite, pb.d.isFinite else { return nil }
        var reversed = false
        if pa.s > pb.s { swap(&pa, &pb); reversed = true }
        var out = P.slice(from: pa, to: pb)
        if reversed { out.reverse() }
        var meters = 0.0
        for k in 1..<out.count { meters += simd_length(out[k] - out[k - 1]) }
        return (out.map(f.coord), meters, reversed ? pb.d : pa.d, reversed ? pa.d : pb.d)
    }

    /// 外推后新锚点处的行进方向：samples 是从原锚点往外的真实点，新锚点 = samples[shift-1]；
    /// B 侧取新锚点 → 再往外第一个 ≥25 m 的点；A 侧取再往外第一个 ≥25 m 的点 → 新锚点
    static func headingAtShifted(_ samples: [RoadNetwork.PortalSample], shift: Int, forward: Bool) -> Double? {
        guard shift >= 1, shift - 1 < samples.count else { return nil }
        let n = samples[shift - 1]
        for k in shift..<samples.count {
            let s = samples[k]
            if GeoMath.haversine(n.coord.latitude, n.coord.longitude, s.coord.latitude, s.coord.longitude) >= 25 {
                return forward ? GeoMath.bearing(n.coord.latitude, n.coord.longitude, s.coord.latitude, s.coord.longitude)
                               : GeoMath.bearing(s.coord.latitude, s.coord.longitude, n.coord.latitude, n.coord.longitude)
            }
        }
        return nil
    }

    /// 车道侧校验（用户提议：通行侧 + 行进方向 → 真实点该在路线哪一边）。
    /// 在路上的真实点（离路 ≤ tolOn 的不算，它们本来就贴着；取 6–60 m 的）相对路线行进方向的带符号横偏：
    /// 靠右通行时，车在右侧车道/右侧那条路，对向车道在它左边——真实点若一致落在路线**右**侧 6–60 m，路线就是吸到了对向（左侧）那条。靠左通行镜像
    static func laneSideCheck(raw: [CLLocationCoordinate2D], a: CLLocationCoordinate2D, b: CLLocationCoordinate2D,
                              samplesA: [RoadNetwork.PortalSample], samplesB: [RoadNetwork.PortalSample],
                              arcA: Double, arcB: Double, tolOn: Double, leftHand: Bool?) -> (wrongSide: Bool, note: String) {
        let f = Frame(origin: a)
        let P = Poly(raw, frame: f)
        guard P.pts.count >= 2 else { return (false, String(localized: "车道侧校验：几何太短，没法校验", comment: "Driving-side check note: the route geometry is too short to check")) }
        let side = leftHand ?? TrafficSide.leftHandByBox(a)
        /// 返回该侧样本的带符号横偏中位数（正 = 在路线行进方向的右侧）与样本数
        func lateral(_ samples: [RoadNetwork.PortalSample], s0: Double, forward: Bool) -> (median: Double, n: Int) {
            var offs: [Double] = []
            for smp in samples.prefix(6) {
                let w = forward ? (s0 - 100)...(s0 + 1.6 * smp.meters + 150) : (s0 - 1.6 * smp.meters - 150)...(s0 + 100)
                let h = P.project(f.xy(smp.coord), window: w)
                guard h.d.isFinite, h.d <= 60 else { continue }
                let dir = P.pts[h.seg + 1] - P.pts[h.seg]
                guard simd_length(dir) > 0 else { continue }
                let v = f.xy(smp.coord) - h.pt
                let cross = dir.x * v.y - dir.y * v.x          // >0 = 点在行进方向左侧
                offs.append(cross > 0 ? -h.d : h.d)            // 正 = 右侧
            }
            guard !offs.isEmpty else { return (0, 0) }
            offs.sort()
            return (offs[offs.count / 2], offs.count)
        }
        let la = lateral(samplesA, s0: arcA, forward: false), lb = lateral(samplesB, s0: arcB, forward: true)
        func desc(_ l: (median: Double, n: Int)) -> String {
            guard l.n > 0 else { return String(localized: "无可用点", comment: "Driving-side check: no usable real points on this side") }
            let off = abs(l.median), n = l.n
            return l.median >= 0 ? String(localized: "右侧 \(off, format: Fmt.f0) m（\(n) 点）", comment: "Driving-side check: real points lie to the right of the route. 1st = median lateral offset in m, 2nd = number of points")
                                 : String(localized: "左侧 \(off, format: Fmt.f0) m（\(n) 点）", comment: "Driving-side check: real points lie to the left of the route. 1st = median lateral offset in m, 2nd = number of points")
        }
        // 错误一侧：靠右通行 → 右侧 ≥ max(12, tolOn) 且 ≤60（Garmin 实测正确路线上两侧随机 0–13 m，是定位噪声；
        // 分向车道中心线相距一般 15–30 m）；靠左通行 → 左侧。两端都偏才下结论，单侧只记一笔
        func bad(_ l: (median: Double, n: Int)) -> Bool {
            guard l.n >= 3 else { return false }
            let m = side ? -l.median : l.median
            return m >= max(12, tolOn) && m <= 60
        }
        let badA = bad(la), badB = bad(lb)
        let wrong = badA && badB
        let descA = desc(la), descB = desc(lb)
        // 四个整句变体：靠左 / 靠右通行 × 查不查得到国家
        let base: String
        switch (side, leftHand == nil) {
        case (true, true):
            base = String(localized: "车道侧校验（靠左通行，查不到国家，按粗略范围判）：真实点在路线 A 侧 \(descA)、B 侧 \(descB)", comment: "Driving-side check note, left-hand traffic guessed from a rough area because the country is unknown. 1st/2nd = result for side A/B (e.g. \"右侧 12 m（4 点）\" or \"无可用点\")")
        case (true, false):
            base = String(localized: "车道侧校验（靠左通行）：真实点在路线 A 侧 \(descA)、B 侧 \(descB)", comment: "Driving-side check note, left-hand traffic. 1st/2nd = result for side A/B (e.g. \"右侧 12 m（4 点）\" or \"无可用点\")")
        case (false, true):
            base = String(localized: "车道侧校验（靠右通行，查不到国家，按粗略范围判）：真实点在路线 A 侧 \(descA)、B 侧 \(descB)", comment: "Driving-side check note, right-hand traffic guessed from a rough area because the country is unknown. 1st/2nd = result for side A/B (e.g. \"右侧 12 m（4 点）\" or \"无可用点\")")
        case (false, false):
            base = String(localized: "车道侧校验（靠右通行）：真实点在路线 A 侧 \(descA)、B 侧 \(descB)", comment: "Driving-side check note, right-hand traffic. 1st/2nd = result for side A/B (e.g. \"右侧 12 m（4 点）\" or \"无可用点\")")
        }
        let badSide = badA ? "A" : "B"
        let verdict = wrong ? String(localized: "两端都落在对向车道那一边，路线可能吸错车道", comment: "Driving-side check verdict (after an arrow): points at both ends are on the opposite-carriageway side; the route may be on the wrong carriageway")
                    : (badA || badB ? String(localized: "\(badSide) 侧偏到对向那一边、另一侧正常，单侧不作判定", comment: "Driving-side check verdict (after an arrow). %@ = anchor letter A or B whose side is off; the other side is fine, one side alone is not conclusive")
                                    : String(localized: "车道侧正确", comment: "Driving-side check verdict (after an arrow): the route is on the correct carriageway"))
        return (wrong, base + " → " + verdict)
    }

    /// 最终路径的折返截断：路径第一次（方向一致、容差内）到 B 附近之后还要绕很远才回到 B（或起点先绕一圈再真正离开 A），
    /// 截到第一次到达 / 最后一次离开。只在剩余部分 ≥ max(300 m, 路长 25%) 时截，盘山回头弯的另一条腿因方向相反不算经过
    static func trimExcursion(_ coords: [CLLocationCoordinate2D], a: CLLocationCoordinate2D, b: CLLocationCoordinate2D,
                              bearingA: Double?, bearingB: Double?) -> (coords: [CLLocationCoordinate2D], meters: Double, notes: [String]) {
        let f = Frame(origin: a)
        var pts = coords.map(f.xy)
        var notes: [String] = []
        func total(_ p: [SIMD2<Double>]) -> Double { var s = 0.0; for k in 1..<max(1, p.count) { s += simd_length(p[k] - p[k - 1]) }; return s }
        guard pts.count >= 3 else { return (coords, total(pts), notes) }
        let qa = f.xy(a), qb = f.xy(b)
        // B 端
        do {
            let P = Poly(pts.map(f.coord), frame: f)
            let endD = simd_length(pts[pts.count - 1] - qb)
            let passes = P.passes(qb, within: max(25, 1.5 * endD + 10)).filter { consistent(P, $0, bearingB) }
            if let first = passes.first, P.length - first.s >= max(300, 0.25 * P.length) {
                let cut = P.length - first.s
                pts = Array(pts[0...first.seg]) + [first.pt]
                notes.append(String(localized: "路径第一次到 B 附近（\(first.d, format: Fmt.f0) m）后又绕了 \(cut, format: Fmt.f0) m 才回到 B：按第一次到达截断", comment: "Routing note: the route reached anchor B, then detoured before coming back; it is cut at the first arrival. 1st = distance from B at the first arrival in m, 2nd = length of the extra detour in m"))
            }
        }
        // A 端
        do {
            let P = Poly(pts.map(f.coord), frame: f)
            let startD = simd_length(pts[0] - qa)
            let passes = P.passes(qa, within: max(25, 1.5 * startD + 10)).filter { consistent(P, $0, bearingA) }
            if let last = passes.last, last.s >= max(300, 0.25 * P.length), last.s < P.length - 50 {
                pts = [last.pt] + Array(pts[(last.seg + 1)...])
                notes.append(String(localized: "路径从 A 出发先绕了 \(last.s, format: Fmt.f0) m 又回到 A 附近（\(last.d, format: Fmt.f0) m）：按最后一次离开截断", comment: "Routing note: the route left anchor A, looped and came back near A; it is cut at the last departure. 1st = length of the loop in m, 2nd = distance from A when passing again in m"))
            }
        }
        return (pts.map(f.coord), total(pts), notes)
    }

    /// 末端渐进靠拢：锚点离路 d ≥ minOffset 时，把路径起（止）段 L = clamp(6d, 80, 400) 米（且 ≤ 45% 路长）内的点按平滑权重
    /// 平移向锚点，首点正好平移到锚点旁——没有垂直于路的急拐。两端各做一次。
    /// dA/dB = 锚点到原始路网折线的距离（clip 已算出的 snap）：有就用它当 d，不再对首段的无限延长线量垂距
    /// （首段方向与真实路差几度、延长 150 m 就能量出几十米的假偏移）。返回的 dA/dB = 实际用的 d，没 taper 为 0。
    /// minOffset：公路传 max(8, 匹配半径)——锚点在匹配半径内就是「在路上」，路网几何比锚点准，不该把路往 GPS 噪声弯；
    /// 超出半径且漂移判定没挪锚点时才有真实残余偏移需要渐进靠拢
    static func taper(_ coords: [CLLocationCoordinate2D], a: CLLocationCoordinate2D, b: CLLocationCoordinate2D,
                      dA: Double? = nil, dB: Double? = nil, minOffset: Double = 8) -> (coords: [CLLocationCoordinate2D], notes: [String], dA: Double, dB: Double) {
        guard !coords.isEmpty else { return (coords, [], 0, 0) }
        let f = Frame(origin: a)
        var pts = coords.map(f.xy)
        let qa = f.xy(a), qb = f.xy(b)
        var notes: [String] = []
        func total(_ p: [SIMD2<Double>]) -> Double { var s = 0.0; for k in 1..<max(1, p.count) { s += simd_length(p[k] - p[k - 1]) }; return s }
        func taperStart(_ p0in: [SIMD2<Double>], anchor q: SIMD2<Double>, far: SIMD2<Double>, given: Double?) -> ([SIMD2<Double>], Double, Double)? {
            // 裁剪点正好落在顶点上时首两点重合：去掉紧挨首点（<1 m）的重复点，方向才算得出来
            var p = p0in
            while p.count > 1, simd_length(p[1] - p[0]) < 1 { p.remove(at: 1) }
            let p0 = p[0], p1 = p.count > 1 ? p[1] : far
            let seg = p1 - p0
            guard simd_length(seg) > 1 else { return nil }
            let dir = seg / simd_length(seg)
            var along = simd_dot(q - p0, dir)
            var v = q - (p0 + dir * along)              // 垂直于路的偏移（方向按几何）
            var vLen = simd_length(v)
            if along < -10 {
                // 垂足在首点后方 10 m 以外 = 首点在锚点前方（锚点旁的路网点被 trimEnds 删了）。两种情况：
                // - 首段延长线量出的垂距 vLen 与锚点到原始路网的 snap 对不上（隧道 way 两节点、首段方向差几度延长 150 m
                //   量出 32 m，真实 12 m）：这是伪影，不 taper；
                // - vLen ≈ snap：首段的直线确实从锚点旁经过（投影点只是因 <30 m 被删了），把垂足补回当首点再 taper，
                //   否则锚点离路 15–28 m 时会留下一条斜线
                guard let g = given, abs(vLen - g) <= max(5, 0.3 * g) else { return nil }
                p.insert(p0 + dir * along, at: 0)
                along = 0; v = q - p[0]; vLen = simd_length(v)
            }
            let d = given ?? vLen                       // 长度用锚点到原始路网的距离
            guard d >= minOffset, vLen > 1e-6 else { return nil }
            v = v / vLen * d
            let len = total(p)
            let L = min(0.45 * len, min(400, max(80, 6 * d)))
            guard L > 10 else { return nil }
            // [0, L] 内每 20 m 重采样 + 平滑权重平移；L 之外的原顶点原样保留
            var out: [SIMD2<Double>] = []
            var s = 0.0
            while s < L {
                // 弧长 s 处的点
                var acc = 0.0, pt = p[0]
                for k in 1..<max(1, p.count) {
                    let l = simd_length(p[k] - p[k - 1])
                    if acc + l >= s { pt = p[k - 1] + (p[k] - p[k - 1]) * (l > 0 ? (s - acc) / l : 0); break }
                    acc += l; pt = p[k]
                }
                let x = 1 - s / L, w = x * x * (3 - 2 * x)
                out.append(pt + v * w)
                s += 20
            }
            var acc = 0.0
            for k in 1..<max(1, p.count) {
                acc += simd_length(p[k] - p[k - 1])
                if acc >= L { out.append(p[k]) }
            }
            if p.count == 1 { /* 只有一个顶点：重采样已覆盖它 */ }
            return (out, d, L)
        }
        var usedA = 0.0, usedB = 0.0
        if let (np, d, L) = taperStart(pts, anchor: qa, far: qb, given: dA) {
            pts = np; usedA = d
            notes.append(String(localized: "A 离路 \(d, format: Fmt.f0) m：补点起始 \(L, format: Fmt.f0) m 内渐进靠到 A（不画垂直于路的急拐）", comment: "Taper note: anchor A is off the road, so the start of the filled path bends gradually towards A instead of a sharp perpendicular kink. 1st = A's distance from the road in m, 2nd = taper length in m"))
        }
        if let (np, d, L) = taperStart(Array(pts.reversed()), anchor: qb, far: qa, given: dB) {
            pts = Array(np.reversed()); usedB = d
            notes.append(String(localized: "B 离路 \(d, format: Fmt.f0) m：补点末尾 \(L, format: Fmt.f0) m 内渐进靠到 B", comment: "Taper note: anchor B is off the road, so the end of the filled path bends gradually towards B. 1st = B's distance from the road in m, 2nd = taper length in m"))
        }
        // 去掉与锚点重合的点（首点平移后可能正好落在锚点上）
        pts = pts.filter { simd_length($0 - qa) > 3 && simd_length($0 - qb) > 3 }
        return (pts.map(f.coord), notes, usedA, usedB)
    }
}

// MARK: - 精确模式：两路引擎交叉验证

/// 精确模式下同一处断档由 OSRM 与 Valhalla 各出一份草稿，这里比对两份几何是否"走的是同一条路"。
/// 两个引擎用同一份 OpenStreetMap 数据、同一组锚点：同一条路的几何来自同一批节点（偏差 ≈ 0 m，抽稀后也在几米内），
/// 不同的路（同向平行的集散车道/辅路/匝道、新旧线、护栏分隔的分向车道 11–15 m）中心线至少相隔 10 m 以上。
/// 容差与 GPS 半径无关（GPS 噪声只通过两边共用的锚点进入），固定 10 m；
/// 判定看"最长连续超容差段"而不是百分比——长断档上一段几百米的别路、短断档上整段平移都抓得住，
/// 单个离群节点、路口渠化的几十米差异放过。纯几何、无状态：离线 harness 与批量共用。
enum RouteCrossCheck {
    struct Result: Equatable {
        var agree: Bool
        var tol: Double                 // 容差（米）
        var lenP: Double, lenQ: Double  // 两条完整折线（含锚点）的长度
        var uncoveredP: Double          // P 上离 Q 超过容差的总长度（米）
        var uncoveredQ: Double
        var maxRunP: Double             // P 上最长的一段连续超容差（米）——"分歧段"
        var maxRunQ: Double
        var maxDev: Double              // 双向最近距离的最大值（Hausdorff）
        var meanDev: Double
        var reasons: [String]           // 不一致的原因（给用户看）；一致时为空
        /// 分歧段长度（给用户看：能在地图上对照的量）
        var divergence: Double { max(maxRunP, maxRunQ) }
        /// 重合占比（取两方向较小者），0–1；只做展示
        var coverage: Double {
            let cp = lenP > 0 ? 1 - uncoveredP / lenP : 1, cq = lenQ > 0 ? 1 - uncoveredQ / lenQ : 1
            return max(0, min(cp, cq))
        }
    }

    /// 容差：固定 10 m（见上）；自测可覆盖（设很小则真实数据必出分歧，设很大则全部一致）
    nonisolated(unsafe) static var toleranceOverride: Double? = nil
    static var tolerance: Double { toleranceOverride ?? 10 }

    /// 草稿的完整折线：挪后锚点（或原锚点）+ 路网点 + 锚点
    static func polyline(_ d: RouteDraft, a: CLLocationCoordinate2D, b: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        [d.anchorA ?? a] + d.coords + [d.anchorB ?? b]
    }

    /// 两份草稿比对。隧道口漂移判定不同（外推点数不同）时直接判不一致，几何只比公共内段（两边都覆盖的那一段），
    /// 原因里说清是"隧道口位置看法不同"还是"内段也不同"
    static func compare(_ p: RouteDraft, _ q: RouteDraft, a: CLLocationCoordinate2D, b: CLLocationCoordinate2D) -> Result {
        var P = polyline(p, a: a, b: b), Q = polyline(q, a: a, b: b)
        guard p.shiftA != q.shiftA || p.shiftB != q.shiftB else { return compare(P, Q, tol: tolerance) }
        // 没外推的那一方从漂移锚点起有一段渐进靠拢（taper，L = clamp(6·离路距离, 80, 400)）：那不是"路"，比内段前先去掉，
        // 否则内段永远不一致、「中间路段几何一致」这个结论永远给不出来
        func taperLength(residual: Double, total: Double) -> Double { residual >= 8 ? min(0.45 * total, min(400, max(80, 6 * residual))) : 0 }
        func length(_ poly: [CLLocationCoordinate2D]) -> Double { PortalDrift.Poly(poly, frame: PortalDrift.Frame(origin: a)).length }
        if p.shiftA != q.shiftA {
            let pSide = p.shiftA == 0
            let L = taperLength(residual: pSide ? p.residualA : q.residualA, total: length(pSide ? P : Q))
            if L > 0 { if pSide { P = dropArc(P, meters: L, fromStart: true) } else { Q = dropArc(Q, meters: L, fromStart: true) } }
        }
        if p.shiftB != q.shiftB {
            let pSide = p.shiftB == 0
            let L = taperLength(residual: pSide ? p.residualB : q.residualB, total: length(pSide ? P : Q))
            if L > 0 { if pSide { P = dropArc(P, meters: L, fromStart: false) } else { Q = dropArc(Q, meters: L, fromStart: false) } }
        }
        let (ip, iq) = innerSections(P, Q)
        var r = compare(ip, iq, tol: tolerance)
        let pa = p.shiftA, qa = q.shiftA, pb = p.shiftB, qb = q.shiftB
        let head = String(localized: "两路对隧道口位置判断不同：A 外推 \(pa) / \(qa) 点，B 外推 \(pb) / \(qb) 点", comment: "Cross-check reason: the two routers moved the anchors outward by different numbers of track points (portal drift). Placeholders: A shift by router 1 / router 2, B shift by router 1 / router 2")
        if r.agree {
            r.reasons = [head + String(localized: "；中间路段几何一致", comment: "Cross-check reason suffix: the common middle section of the two routes does agree")]
        } else {
            let inner = r.reasons.joined(separator: String(localized: "list.semicolon", defaultValue: "；", comment: "Separator between entries of an error list (Chinese full-width semicolon; en/de \"; \")"))
            r.reasons = [head + String(localized: "；中间路段也不一致：\(inner)", comment: "Cross-check reason suffix: the common middle section also differs. %@ = geometric reasons")]
        }
        r.agree = false
        return r
    }

    /// 去掉折线起始（或末尾）meters 米
    static func dropArc(_ poly: [CLLocationCoordinate2D], meters: Double, fromStart: Bool) -> [CLLocationCoordinate2D] {
        guard poly.count >= 2, meters > 0 else { return poly }
        let pts = fromStart ? poly : Array(poly.reversed())
        let f = PortalDrift.Frame(origin: pts[0])
        let P = PortalDrift.Poly(pts, frame: f)
        guard meters < P.length - 1 else { return fromStart ? [poly[poly.count - 1]] : [poly[0]] }
        var out: [CLLocationCoordinate2D] = []
        for k in 1..<P.pts.count where P.acc[k] > meters {
            if out.isEmpty {
                let l = P.acc[k] - P.acc[k - 1], t = l > 0 ? (meters - P.acc[k - 1]) / l : 0
                out.append(f.coord(P.pts[k - 1] + (P.pts[k] - P.pts[k - 1]) * t))
            }
            out.append(pts[k])
        }
        return fromStart ? out : Array(out.reversed())
    }

    /// 两条折线都裁到"更靠内"的起点/终点之间（起点取两者中沿对方弧长更靠后的那个，终点取更靠前的那个）
    static func innerSections(_ polyP: [CLLocationCoordinate2D], _ polyQ: [CLLocationCoordinate2D]) -> ([CLLocationCoordinate2D], [CLLocationCoordinate2D]) {
        guard let origin = polyP.first, polyP.count >= 2, polyQ.count >= 2 else { return (polyP, polyQ) }
        let f = PortalDrift.Frame(origin: origin)
        let P = PortalDrift.Poly(polyP, frame: f), Q = PortalDrift.Poly(polyQ, frame: f)
        // 起点：P 起点在 Q 上的位置 vs Q 起点在 P 上的位置——谁的起点落在对方内部更深，就以它为公共起点
        let pOnQ = Q.project(P.pts[0]), qOnP = P.project(Q.pts[0])
        var sP = PortalDrift.Hit(seg: 0, t: 0, s: 0, d: 0, pt: P.pts[0]), sQ = PortalDrift.Hit(seg: 0, t: 0, s: 0, d: 0, pt: Q.pts[0])
        if pOnQ.s > qOnP.s { sQ = pOnQ } else { sP = qOnP }
        let pEndOnQ = Q.project(P.pts[P.pts.count - 1]), qEndOnP = P.project(Q.pts[Q.pts.count - 1])
        var eP = PortalDrift.Hit(seg: P.pts.count - 2, t: 1, s: P.length, d: 0, pt: P.pts[P.pts.count - 1])
        var eQ = PortalDrift.Hit(seg: Q.pts.count - 2, t: 1, s: Q.length, d: 0, pt: Q.pts[Q.pts.count - 1])
        if (Q.length - pEndOnQ.s) > (P.length - qEndOnP.s) { eQ = pEndOnQ } else { eP = qEndOnP }
        guard sP.s < eP.s, sQ.s < eQ.s else { return (polyP, polyQ) }
        return (P.slice(from: sP, to: eP).map(f.coord), Q.slice(from: sQ, to: eQ).map(f.coord))
    }

    /// 两条折线（WGS-84）的几何比对。
    /// 规则：ln = 较短者长度；步长 h = ln < 1 km ? 5 : 10 m；允许的分歧段 R = clamp(0.15·ln, 15, 40) m；
    /// 一致 ⇔ 两方向最长连续超容差段 ≤ R，且超容差总长 ≤ R + min(120, 0.2% 长度)，且长度差 ≤ max(25 m, 1%)
    static func compare(_ polyP: [CLLocationCoordinate2D], _ polyQ: [CLLocationCoordinate2D], tol: Double) -> Result {
        guard let origin = polyP.first ?? polyQ.first else {
            return Result(agree: true, tol: tol, lenP: 0, lenQ: 0, uncoveredP: 0, uncoveredQ: 0, maxRunP: 0, maxRunQ: 0, maxDev: 0, meanDev: 0, reasons: [])
        }
        let f = PortalDrift.Frame(origin: origin)
        let P = PortalDrift.Poly(polyP, frame: f), Q = PortalDrift.Poly(polyQ, frame: f)
        let ln = min(P.length, Q.length)
        let step = ln < 1000 ? 5.0 : 10.0
        /// 沿 src 每 step 米取样（含末点），量到 dst 的最近距离；返回（超容差总长, 最长连续超容差段, 距离列表）
        func sweep(_ src: PortalDrift.Poly, _ dst: PortalDrift.Poly) -> (uncovered: Double, maxRun: Double, dists: [Double]) {
            guard let first = src.pts.first else { return (0, 0, []) }
            func dist(_ pt: SIMD2<Double>) -> Double { dst.pts.count >= 2 ? dst.project(pt).d : simd_length(pt - (dst.pts.first ?? pt)) }
            guard src.pts.count >= 2, src.length > 0 else { let d = dist(first); return (d > tol ? step : 0, d > tol ? step : 0, [d]) }
            var dists: [Double] = []
            var uncovered = 0.0, run = 0.0, maxRun = 0.0
            let total = src.length
            let n = Int((total / step).rounded(.up))
            var k = 1
            for i in 0...n {
                let s = min(total, Double(i) * step)
                while k < src.pts.count - 1, src.acc[k] < s { k += 1 }
                let l = src.acc[k] - src.acc[k - 1]
                let t = l > 0 ? max(0, min(1, (s - src.acc[k - 1]) / l)) : 0
                let pt = src.pts[k - 1] + (src.pts[k] - src.pts[k - 1]) * t
                let d = dist(pt)
                dists.append(d)
                let seg = i == n ? max(0, total - Double(n - 1) * step) : step      // 末样点只算剩余长度
                if d > tol { uncovered += seg; run += seg; maxRun = max(maxRun, run) } else { run = 0 }
            }
            return (min(uncovered, total), min(maxRun, total), dists)
        }
        let sp = sweep(P, Q), sq = sweep(Q, P)
        let all = sp.dists + sq.dists
        let maxDev = all.max() ?? 0
        let meanDev = all.isEmpty ? 0 : all.reduce(0, +) / Double(all.count)
        let lenP = P.length, lenQ = Q.length
        let R = max(15, min(40, 0.15 * ln))
        var reasons: [String] = []
        let tolM = Int(tol), md = Int(maxDev.rounded())
        if sp.maxRun > R || sq.maxRun > R {
            let run = Int(max(sp.maxRun, sq.maxRun).rounded())
            reasons.append(String(localized: "有一段 \(run) m 两路相隔超过 \(tolM) m（最大偏差 \(md) m）", comment: "Cross-check reason: a continuous stretch of the two routes lies apart. Placeholders: length of that stretch in m, tolerance in m, maximum deviation in m"))
        } else if sp.uncovered > R + min(120, 0.002 * lenP) || sq.uncovered > R + min(120, 0.002 * lenQ) {
            let un = Int(max(sp.uncovered, sq.uncovered).rounded())
            reasons.append(String(localized: "两路相隔超过 \(tolM) m 的部分合计 \(un) m（分散在多处，最大偏差 \(md) m）", comment: "Cross-check reason: the parts where the two routes lie apart add up to too much. Placeholders: tolerance in m, total length in m, maximum deviation in m"))
        }
        if abs(lenP - lenQ) > max(25, 0.01 * max(lenP, lenQ)) {
            let lp = Int(lenP.rounded()), lq = Int(lenQ.rounded())
            reasons.append(String(localized: "长度不同：\(lp) m 对 \(lq) m", comment: "Cross-check reason: the two routes differ in length. Placeholders: length of router 1's route in m, length of router 2's route in m"))
        }
        return Result(agree: reasons.isEmpty, tol: tol, lenP: lenP, lenQ: lenQ, uncoveredP: sp.uncovered, uncoveredQ: sq.uncovered,
                      maxRunP: sp.maxRun, maxRunQ: sq.maxRun, maxDev: maxDev, meanDev: meanDev, reasons: reasons)
    }

    /// 一致时的说明（notes 首行 / 悬停首行）：另一路的长度、最大相差、采用了谁
    static func agreeNote(_ r: Result, adopted: RouteDraft, other: RouteDraft) -> String {
        let otherName = RoadNetwork.name(other.source == .osrmCar ? .osrm : .valhalla)
        let otherLen = other.meters >= 1000 ? "\((other.meters / 1000).formatted(Fmt.f2)) km" : "\(other.meters.formatted(Fmt.f0)) m"
        let md = Int(r.maxDev.rounded())
        let name = RoadNetwork.name(adopted.source == .osrmCar ? .osrm : .valhalla)
        return String(localized: "两路一致：\(otherName) \(otherLen)，最多相差 \(md) m；采用 \(name)", comment: "Cross-check note when OSRM and Valhalla agree. Placeholders: name of the other router, its route length (e.g. 1.21 km), maximum deviation in m, name of the adopted router. Keep router names untranslated")
    }

    /// 两份都成功时采用哪一份：警告少 → 残余偏移小 → 落地前自检分低 → OSRM（有地图匹配，且与普通模式的首选一致）
    static func preferred(_ p: RouteDraft, _ q: RouteDraft) -> Bool {   // true = 用 p
        if p.warnings.count != q.warnings.count { return p.warnings.count < q.warnings.count }
        let rp = p.residualA + p.residualB, rq = q.residualA + q.residualB
        if abs(rp - rq) > 5 { return rp < rq }
        return p.source == .osrmCar || q.source != .osrmCar
    }

    /// 精确模式的额外提醒：两路一致，但没外推的锚点离路仍远——两个服务用同一份地图、同一组锚点，
    /// 锚点本身漂到旁边那条路上时会一起接错，交叉验证查不出来，所以给一条警告让人看一眼
    static func anchorWarning(_ d: RouteDraft, matchRadius: Double) -> String? {
        let tolDrift = max(1.5 * matchRadius, 20)
        let offA = d.shiftA == 0 ? d.residualA : 0, offB = d.shiftB == 0 ? d.residualB : 0
        // 渐进靠拢的偏移远大于锚点离路：起止段的几何是被 taper 拉过去的（伪影信号）。两路走同一段后处理会一起错，交叉验证查不出
        let extraA = d.taperA - d.residualA, extraB = d.taperB - d.residualB
        if max(extraA, extraB) > 10 {
            let (pull, off) = extraA >= extraB ? (d.taperA, d.residualA) : (d.taperB, d.residualB)
            return extraA >= extraB
                ? String(localized: "两路一致，但补点起始段向 A 靠拢了 \(pull, format: Fmt.f0) m、远多于 A 离路的 \(off, format: Fmt.f0) m：起始几何可能不是路网，请在地图上看一眼", comment: "Road-draft warning (precise mode): both routers agree, but the start of the filled path was bent towards anchor A much more than A's distance from the road; the start geometry may not follow the road network. 1st = taper offset in m, 2nd = A's distance from the road in m")
                : String(localized: "两路一致，但补点末尾段向 B 靠拢了 \(pull, format: Fmt.f0) m、远多于 B 离路的 \(off, format: Fmt.f0) m：末尾几何可能不是路网，请在地图上看一眼", comment: "Road-draft warning (precise mode): both routers agree, but the end of the filled path was bent towards anchor B much more than B's distance from the road; the end geometry may not follow the road network. 1st = taper offset in m, 2nd = B's distance from the road in m")
        }
        guard max(offA, offB) > tolDrift else { return nil }
        return String(localized: "两路一致，但锚点离路 \(offA, format: Fmt.f0) / \(offB, format: Fmt.f0) m：两个服务用同一份地图和同一组锚点，锚点本身漂到旁边路上时会一起接错，请在地图上看一眼", comment: "Road-draft warning (precise mode): both routers agree but an anchor is far from the road, so both may have snapped to the same wrong road. Placeholders: distance of anchor A / anchor B from the road in m")
    }
}

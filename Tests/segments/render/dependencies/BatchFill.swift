//
//  BatchFill.swift
//  GPXPointViewer
//
//  一键补全部断档：分类（公路/铁路/跳过，自动判断不了的让用户先选）→ 顺序取路网草稿（限速、可取消、
//  Overpass 包围盒缓存）→ 预览（主地图画出每处草稿，列表里逐处飞过去、勾选）→ 一次落地（整批可撤销）。
//

import Foundation
import CoreLocation

enum BatchKind: String, Codable, CaseIterable {
    case road, rail, skip
    var label: String {
        switch self {
        case .road: return String(localized: "公路", comment: "Batch gap fill: gap type choice – fill along the road network")
        case .rail: return String(localized: "铁路", comment: "Batch gap fill: gap type choice – fill along the railway network")
        case .skip: return String(localized: "跳过", comment: "Batch gap fill: gap type choice – leave this gap unfilled")
        }
    }
}

enum BatchStatus: Equatable {
    case pending, running, done, failed(String), skipped
    /// 铁路：路网取到了但判定不是隧道断档（车厢屏蔽 / 太长），按用户要求不补；不算失败，也不给直线兜底
    case notTunnel(String)
    /// 精确模式：等用户选。disagree = 两路给的不是同一条路；unverified = 只有一路给出结果（载荷 = 另一路的失败原因），没比成。
    /// 两种都不自动落地；两份草稿在 BatchItem.crossDrafts 里，选定后才写进 draft
    case conflict(ConflictKind)
    enum ConflictKind: Equatable { case disagree, unverified(String) }
    var isDone: Bool { if case .done = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }
    var isNotTunnel: Bool { if case .notTunnel = self { return true }; return false }
    var isConflict: Bool { if case .conflict = self { return true }; return false }
    var isDisagree: Bool { if case .conflict(.disagree) = self { return true }; return false }
    var isUnverified: Bool { if case .conflict(.unverified) = self { return true }; return false }
    /// 已有结果（成功 / 失败 / 不补 / 待选）：进度条与进度文字的口径
    var isFinished: Bool { switch self { case .done, .failed, .notTunnel, .conflict: return true; default: return false } }
}

struct BatchItem: Identifiable, Equatable {
    var id: Double { candidate.tA }
    let candidate: GapCandidate
    var kind: BatchKind?                // 用户/自动的最终选择；nil = 还没选（自动判断不了且用户未点）
    let autoKind: BatchKind?            // 自动判断（nil = 不确定）
    var status: BatchStatus = .pending
    var draft: RouteDraft?              // 取回的路网草稿（nil = 失败/跳过/直线）
    /// 精确模式：两路各自的草稿（OSRM 在前、Valhalla 在后，1–2 份）。待选时 draft 为空、两份都在这里；
    /// 一致或选定后 draft 是采用的那份，这里仍留全部（「改用另一条」用）
    var crossDrafts: [RouteDraft] = []
    /// 精确模式的比对结果（nil = 没比成：普通模式、铁路、只删点、只有一路成功）
    var cross: RouteCrossCheck.Result? = nil
    /// 用户在待选项上做过选择（选一路 / 直线 / 都不补 / 改用另一条）：批量按钮不再覆盖它
    var userPicked: Bool = false
    /// 待选项上用户选了「都不补」：状态仍是待选（两份草稿还在、随时可改选），只是不再算"等你选"，也不落地
    var declined: Bool = false
    /// 「改用另一条」：与当前 draft 来源不同的那份
    var otherCrossDraft: RouteDraft? { crossDrafts.first { $0.source != draft?.source } }
    var include: Bool = true            // 预览里勾选落地
    var useStraight: Bool = false       // 失败的用直线补
    /// 乱跳簇取不到路径（铁路不像隧道 / 失败）时只删区间内的乱跳点、不插点（默认开；两锚点之间留空由用户另行处理）
    var deleteOnly: Bool = false
    var bbox: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)?   // 草稿包围盒（覆盖层剔除用）
    var sampling: LocalSampling? = nil  // 成因（采样稀疏 / 信号中断），只是标签
    var userSet: Bool = false           // 用户手动改过「采用」：地图判断 / 批量按钮不再覆盖
    var mapNote: String? = nil          // 地图判断的依据（离公路/铁路各多远）
    var tripIndex: Int = -1             // 所属行程（-1 = 未知）
    var cached: Bool = false            // 这一处当前结果整处来自路网缓存（BatchState.cacheHits 的计数依据；单项重取时扣回）
    /// 「重新获取这一处」的次数：草稿可能换成点数/来源/外推都相同但坐标不同的另一份，按签名缓存的地图折线与预览列表靠它失效
    var refetchCount: Int = 0
    /// 落地前自检（FillPlausibility）：取到草稿后立刻评估；待选项按 OSRM 份评估（只做展示）；没有草稿 = nil
    var plausibility: FillPlausibility? = nil
    var riskLevel: FillPlausibility.Level? { plausibility?.level }

    var willLand: Bool { include && !status.isConflict && (draft != nil || useStraight || deleteOnlyActive) }
    /// 只删点生效：乱跳簇没有草稿、也没选直线
    var deleteOnlyActive: Bool { deleteOnly && draft == nil && !useStraight && candidate.kind == .jitter }
    /// 落地时不插合成点、只删区间内的点（本地判定的删点草稿，或取不到路径后的只删点）
    var landsDeleteOnly: Bool { draft?.source == .deleteOnly || deleteOnlyActive }

    static func == (a: BatchItem, b: BatchItem) -> Bool {
        a.candidate == b.candidate && a.kind == b.kind && a.status == b.status && a.include == b.include
            && a.useStraight == b.useStraight && a.deleteOnly == b.deleteOnly && (a.draft?.coords.count ?? -1) == (b.draft?.coords.count ?? -1)
            && (a.draft?.source == b.draft?.source) && a.crossDrafts.count == b.crossDrafts.count && a.userPicked == b.userPicked && a.declined == b.declined
            && a.plausibility?.risk == b.plausibility?.risk
    }

    mutating func computeBBox() {
        var lats = [candidate.latA, candidate.latB], lons = [candidate.lonA, candidate.lonB]
        for d in [draft].compactMap({ $0 }) + crossDrafts {
            lats += d.coords.map(\.latitude); lons += d.coords.map(\.longitude)
            for p in [d.anchorA, d.anchorB].compactMap({ $0 }) { lats.append(p.latitude); lons.append(p.longitude) }
        }
        bbox = (lats.min()!, lats.max()!, lons.min()!, lons.max()!)
    }
}

enum BatchPhase: Equatable { case classify, running, preview, landing }

struct BatchState: Equatable {
    var phase: BatchPhase = .classify
    var items: [BatchItem] = []
    var trackID: UUID?                  // 建表时的轨迹：换了文件/撤销/落地后整个批次作废
    var generation: Int = 0             // 每次开始/取消/关闭递增，旧任务的回写一律作废
    var currentIndex: Int?              // 正在处理的下标
    var progressText: String = ""
    var startedAt: Date?
    var requestsMade: Int = 0           // 实际发出的 HTTP 请求数
    var selectedID: Double?             // 预览里选中的那处（主地图高亮并飞过去）
    /// 每段行程里有几处（建表时算一次；行程条每次重绘都要用，几千段 × 几千处逐个过滤会把主线程占满）
    var itemsPerTrip: [Int: Int] = [:]

    var uncertainUnresolved: Int { items.filter { $0.kind == nil }.count }
    /// 精确模式：待选处数（不一致 + 只有一路结果，含已选「都不补」的）
    var conflictCount: Int { items.filter { $0.status.isConflict }.count }
    /// 还没做决定的待选处数（不含「都不补」）
    var pendingPickCount: Int { items.filter { $0.status.isConflict && !$0.declined }.count }
    var declinedCount: Int { items.filter { $0.status.isConflict && $0.declined }.count }
    var disagreeCount: Int { items.filter { $0.status.isDisagree && !$0.declined }.count }
    var unverifiedCount: Int { items.filter { $0.status.isUnverified && !$0.declined }.count }
    var agreeCount: Int { items.filter { $0.cross?.agree == true }.count }
    /// 某一路连续连不上被停用后的提示（精确模式）
    var engineDisabled: String? = nil
    /// 按主机的请求数（界面显示 OSRM / Valhalla / Overpass 各发了多少）
    var requestsByHost: [String: Int] = [:]
    /// 这一轮里整处结果都来自路网缓存（没发请求）的处数（见 RouteCache）
    var cacheHits: Int = 0
    /// 自动判断不了、用户也没手动改的（默认跳过）：地图判断与「不确定的全部按…」只动这些
    var uncertainDefaulted: Int { items.filter { $0.autoKind == nil && !$0.userSet }.count }
    var includedCount: Int { items.filter { $0.willLand }.count }
    var workCount: Int { items.filter { $0.kind != nil && $0.kind != .skip }.count }
    /// 第 3 步里还在「重新获取这一处」的项数（>0 时不能落地：那一处的旧草稿已清、新结果未到）
    var refetchingCount: Int { items.filter { $0.status == .running }.count }
    /// 落地前自检：有草稿（成功）的项里风险 high / medium 的处数（待选项不算，它们本来就不自动落地）
    var highRiskCount: Int { items.filter { $0.status.isDone && $0.plausibility?.level == .high }.count }
    var mediumRiskCount: Int { items.filter { $0.status.isDone && $0.plausibility?.level == .medium }.count }
}

enum BatchClassifier {
    /// 自动判断（只看速度，离线，只在很有把握时才下结论）：
    /// - 铁路：隐含速度 >200 km/h（德国高速公路也到不了），或断档前后记录速度都 >170；
    /// - 公路：隐含速度 60–140、前后记录速度都在 40–150 且时长 <15 min（高速公路/国道驾车）；
    /// - 其它一律不确定：慢速的（地铁、公交、步行 25–60 km/h）和 140–200 的（区域列车/ICE 与高速公路重叠），
    ///   交给「让地图判断」或用户。
    /// 铁路还要求 10 s / 100 m 窗口速度也 >170：手机单步速度在跳点上不可信（一步 1.3 km / 3 s）
    static func classify(_ c: GapCandidate) -> BatchKind? {
        let sIn = c.speedInKmh, sOut = c.speedOutKmh
        // 隐含 >200 还要前后记录速度撑得住（≥120）：Garmin 过时时钟没完全回正时隐含速度会虚高（大巴隧道算出 225）
        let fastAround = max(sIn, sOut, c.windowSpeedInKmh ?? 0, c.windowSpeedOutKmh ?? 0) >= 120
        if c.kmh > 200, fastAround { return .rail }
        // 两侧都 >170 却在断档里只走了几十米（隐含 <60 km/h）物理上不可能是火车：是过夜停留点的唤醒跳点
        if c.kmh >= 60 && sIn > 170 && sOut > 170 && (c.windowSpeedInKmh ?? 0) > 170 && (c.windowSpeedOutKmh ?? 0) > 170 { return .rail }
        if c.kmh >= 60 && c.kmh <= 140 && sIn >= 40 && sIn <= 150 && sOut >= 40 && sOut <= 150 && c.seconds < 900 { return .road }
        return nil
    }

    /// 自动判断的依据（给「自动判断」列的 help）
    static func reason(_ c: GapCandidate) -> String {
        let sIn = c.speedInKmh, sOut = c.speedOutKmh
        func w(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "—" }
        if c.kmh > 200 {
            if max(sIn, sOut, c.windowSpeedInKmh ?? 0, c.windowSpeedOutKmh ?? 0) >= 120 {
                return String(localized: "铁路：隐含速度 \(c.kmh, format: Fmt.f0) km/h > 200（公路上到不了），前后记录速度 \(sIn, format: Fmt.f0)/\(sOut, format: Fmt.f0) 也支持",
                              comment: "Batch gap fill, tooltip of the auto-classification column (verdict: rail). Placeholders in order: implied speed across the gap (km/h); recorded speed before the gap; recorded speed after the gap (km/h)")
            }
            return String(localized: "不确定：隐含速度 \(c.kmh, format: Fmt.f0) km/h 但前后记录只有 \(sIn, format: Fmt.f0)/\(sOut, format: Fmt.f0) km/h——时间跨度可疑（专用记录仪的时钟可能没完全回正），请看地图或手选",
                          comment: "Batch gap fill, tooltip of the auto-classification column (verdict: uncertain). Placeholders in order: implied speed across the gap (km/h); recorded speed before the gap; recorded speed after the gap (km/h)")
        }
        if sIn > 170, sOut > 170 {
            if c.kmh < 60 {
                return String(localized: "不确定：进/出单步速度 \(sIn, format: Fmt.f0)/\(sOut, format: Fmt.f0) km/h 像火车，但断档里隐含只有 \(c.kmh, format: Fmt.f0) km/h（两侧都是跳点，多为停留点的唤醒定位），请让地图判断或手选",
                              comment: "Batch gap fill, tooltip of the auto-classification column (verdict: uncertain). Placeholders in order: single-step speed entering the gap; single-step speed leaving the gap (km/h); implied speed across the gap (km/h)")
            }
            if (c.windowSpeedInKmh ?? 0) > 170, (c.windowSpeedOutKmh ?? 0) > 170 {
                let wIn = c.windowSpeedInKmh ?? 0, wOut = c.windowSpeedOutKmh ?? 0
                return String(localized: "铁路：进/出单步速度 \(sIn, format: Fmt.f0)/\(sOut, format: Fmt.f0)、10 s / 100 m 窗口速度 \(wIn, format: Fmt.f0)/\(wOut, format: Fmt.f0) km/h，都 > 170",
                              comment: "Batch gap fill, tooltip of the auto-classification column (verdict: rail). Placeholders in order: single-step speed entering / leaving the gap; speed over a 10 s / 100 m window entering / leaving the gap (all km/h)")
            }
            let wIn = w(c.windowSpeedInKmh), wOut = w(c.windowSpeedOutKmh)
            return String(localized: "不确定：单步速度 \(sIn, format: Fmt.f0)/\(sOut, format: Fmt.f0) km/h 像火车，但 10 s / 100 m 窗口速度 \(wIn)/\(wOut) km/h（跳点或后台稀疏，取不到可靠值或不到 170），请让地图判断或手选",
                          comment: "Batch gap fill, tooltip of the auto-classification column (verdict: uncertain). Placeholders in order: single-step speed entering / leaving the gap (km/h); speed over a 10 s / 100 m window entering / leaving the gap (a number, or — when unavailable)")
        }
        if classify(c) == .road {
            return String(localized: "公路：隐含 \(c.kmh, format: Fmt.f0) km/h（60–140），进/出单步速度 \(sIn, format: Fmt.f0)/\(sOut, format: Fmt.f0) km/h（40–150），时长 \(c.seconds, format: Fmt.f0) s（< 15 min）",
                          comment: "Batch gap fill, tooltip of the auto-classification column (verdict: road). Placeholders in order: implied speed across the gap (km/h); single-step speed entering / leaving the gap (km/h); gap duration (seconds)")
        }
        return String(localized: "不确定：隐含 \(c.kmh, format: Fmt.f0) km/h、进/出单步速度 \(sIn, format: Fmt.f0)/\(sOut, format: Fmt.f0) km/h、时长 \(c.seconds, format: Fmt.f0) s，不在「公路」或「铁路」的有把握范围（慢速的地铁/公交/步行，或 140–200 km/h 区域列车与高速公路重叠），请让地图判断或手选",
                      comment: "Batch gap fill, tooltip of the auto-classification column (verdict: uncertain). Placeholders in order: implied speed across the gap (km/h); single-step speed entering / leaving the gap (km/h); gap duration (seconds). 「公路」/「铁路」 are the gap type choices Road / Rail")
    }

    /// 让地图判断：两端都离可行驶道路 >60 m → 铁路；都 ≤40 m 且隐含速度 ≥40 km/h → 公路；否则仍不确定
    /// （地铁站在马路底下、车站旁有街道，慢速的交给用户）
    static func classifyByRoadDistance(dA: Double?, dB: Double?, kmh: Double) -> BatchKind? {
        guard let dA, let dB else { return nil }
        if dA > 60 && dB > 60 { return .rail }
        if dA <= 40 && dB <= 40 && kmh >= 40 { return .road }
        return nil
    }

    /// 让地图判断（公路网 + 铁路网各算一次距离）：两端都贴着铁路（≤50 m）且不都贴着公路（或隐含 >120）→ 铁路；
    /// 两端都贴着公路（≤40 m）且离铁路远（>80 m，或隐含 <100）→ 公路；其它仍不确定。铁路距离拿不到时退回只看公路
    static func classifyByMap(roadA: Double?, roadB: Double?, railA: Double?, railB: Double?, kmh: Double) -> BatchKind? {
        guard let roadA, let roadB else { return nil }
        guard let railA, let railB else { return classifyByRoadDistance(dA: roadA, dB: roadB, kmh: kmh) }
        let nearRail = railA <= 50 && railB <= 50
        let nearRoad = roadA <= 40 && roadB <= 40
        if nearRail, !nearRoad || kmh > 120 { return .rail }
        if nearRoad, railA > 80 || railB > 80 || kmh < 100 { return .road }
        if nearRoad, !nearRail { return .road }
        return nil
    }
    static func mapReason(roadA: Double?, roadB: Double?, railA: Double?, railB: Double?, verdict: BatchKind?) -> String {
        func f(_ v: Double?) -> String {
            v.map { $0 >= 1e8 ? String(localized: "150 m 内无", comment: "Batch gap fill, map check: value shown instead of a distance when no road/railway exists within 150 m") : "\($0.formatted(Fmt.f0)) m" } ?? "—"
        }
        let roadDA = f(roadA), roadDB = f(roadB), railDA = f(railA), railDB = f(railB)
        let result = verdict?.label ?? String(localized: "仍不确定", comment: "Batch gap fill, map check result: the map could not decide road vs rail either")
        return String(localized: "地图判断：离公路 \(roadDA) / \(roadDB)，离铁路 \(railDA) / \(railDB) → \(result)",
                      comment: "Batch gap fill, map check explanation. Placeholders in order: distance from anchor A to the nearest road; from anchor B to the nearest road; from A to the nearest railway; from B to the nearest railway (each like “23 m” or “none within 150 m”); verdict (Road / Rail / still uncertain)")
    }
}

/// 路由输入的逐候选导出（JSONL 一行一处）：离线 harness 与 UITestHook 共用，证明 app 的载入路径和 CLI 一致
enum GapInputDump {
    static func line(index i: Int, candidate c: GapCandidate, inputs inp: GapRouteInputs.Inputs) -> String {
        func deg(_ b: Double?) -> String { b.map { String(((Int($0.rounded()) % 360) + 360) % 360) } ?? "null" }
        func h(_ x: GapRouteInputs.Heading) -> String { x.bearing == nil ? "null" : "[\(x.index ?? -1),\(deg(x.bearing))]" }
        func ctx(_ x: GapRouteInputs.Context) -> String { x.anchor == nil ? "null" : "[\(x.index ?? -1),\(Int(x.rung ?? 0)),\(deg(x.anchor?.bearing))]" }
        func opt(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "null" }
        let auto = BatchClassifier.classify(c).map { "\"\($0.rawValue)\"" } ?? "null"
        let s = inp.sampling
        let kindName = c.kind == .staleClock ? "stale" : (c.kind == .jitter ? "jitter" : "tgap")
        return "{\"i\":\(i),\"kind\":\"\(kindName)\",\"ia\":\(c.indexA),\"ib\":\(c.indexB),\"tA\":\(Int(c.tA)),"
            + "\"bA\":\(h(inp.a.heading)),\"bAstop\":\"\(inp.a.heading.stop.key)\",\"bB\":\(h(inp.b.heading)),\"bBstop\":\"\(inp.b.heading.stop.key)\","
            + "\"cA\":\(ctx(inp.a.context)),\"cAstop\":\"\(inp.a.context.stop.key)\",\"cB\":\(ctx(inp.b.context)),\"cBstop\":\"\(inp.b.context.stop.key)\","
            + "\"trace\":[\(inp.traceIndices.map(String.init).joined(separator: ","))],\"radius\":\(Int(inp.radius)),\"auto\":\(auto),"
            + String(format: "\"sIn\":%.1f,\"sOut\":%.1f,", c.speedInKmh, c.speedOutKmh) + "\"wIn\":\(opt(c.windowSpeedInKmh)),\"wOut\":\(opt(c.windowSpeedOutKmh)),"
            + "\"tau\":\(opt(s.tau)),\"tauN\":\(s.count),\"nature\":\"\(s.nature.rawValue)\",\"reqs\":\(inp.requestCount)}"
    }
}

/// 路网结果缓存的键 = 一处断档向某个来源取路的**全部输入**：同样的输入第二次就不再请求。
/// 参与的字段（任一变了就是另一处/另一次请求）：
/// - `source`（OSRM 公路 / Valhalla 公路 / Overpass 铁路）与 `economy`（批量的省请求候选集与单处交互的候选集不同，结果可能不同）；
/// - 锚点下标 `ia`/`ib` 与坐标 `a`/`b`、断档时长 `seconds`（隐含速度校验用）；
/// - 两端行进方向 `bearingA`/`bearingB`、近上下文 `contextA`/`contextB`、远上下文 `farContextA`/`farContextB`（坐标 + 方向）；
/// - 匹配轨迹 `trace`（每点下标/坐标/时间）、匹配半径 `radius`；
/// - 隧道口漂移判定用的外侧点 `portalA`/`portalB`/`portalFarA`/`portalFarB`；
/// - 左行/右行 `leftHand`（车道侧校验）。
/// **不参与**：点距、精确模式开关、勾选/落地状态、failFast（只影响失败时的行为）、轨迹 id（换文件时整个缓存清空）。
/// 浮点一律按值比较（Double 的 Hashable），同一文件里同一处断档算出的输入逐位相同。
struct RouteCacheKey: Hashable, Sendable {
    struct P: Hashable, Sendable { var lat: Double; var lon: Double
        init(_ c: CLLocationCoordinate2D) { lat = c.latitude; lon = c.longitude } }
    struct Ctx: Hashable, Sendable { var p: P; var bearing: Double?
        init(_ c: RoadNetwork.ContextAnchor) { p = P(c.coord); bearing = c.bearing } }
    struct TP: Hashable, Sendable { var index: Int; var p: P; var time: Double
        init(_ t: RoadNetwork.TracePoint) { index = t.index; p = P(t.coord); time = t.time } }
    struct PS: Hashable, Sendable { var index: Int; var p: P; var meters: Double; var seconds: Double
        init(_ s: RoadNetwork.PortalSample) { index = s.index; p = P(s.coord); meters = s.meters; seconds = s.seconds } }
    var source: RouteSource
    var economy: Bool
    var ia: Int, ib: Int
    var a: P, b: P
    var seconds: Double
    var bearingA: Double?, bearingB: Double?
    var contextA: Ctx?, contextB: Ctx?
    var farContextA: Ctx?, farContextB: Ctx?
    var trace: [TP]
    var radius: Double
    var portalA: [PS], portalB: [PS], portalFarA: [PS], portalFarB: [PS]
    var leftHand: Bool?

    init(source: RouteSource, economy: Bool, ia: Int, ib: Int, a: CLLocationCoordinate2D, b: CLLocationCoordinate2D, seconds: Double,
         inputs inp: GapRouteInputs.Inputs, leftHand: Bool?) {
        self.source = source; self.economy = economy
        self.ia = ia; self.ib = ib
        self.a = P(a); self.b = P(b)
        self.seconds = seconds
        bearingA = inp.a.heading.bearing; bearingB = inp.b.heading.bearing
        contextA = inp.a.context.anchor.map(Ctx.init); contextB = inp.b.context.anchor.map(Ctx.init)
        farContextA = inp.farContextA.map(Ctx.init); farContextB = inp.farContextB.map(Ctx.init)
        trace = inp.trace.map(TP.init)
        radius = inp.radius
        portalA = inp.portalA.map(PS.init); portalB = inp.portalB.map(PS.init)
        portalFarA = inp.portalFarA.map(PS.init); portalFarB = inp.portalFarB.map(PS.init)
        self.leftHand = leftHand
    }
}

/// 路网结果按打开的文件缓存（内存；`TrackStore.load` 换文件时清空，批量取消/关窗/落地/撤销/还原都不清）：
/// 值是该来源这一处的**确定性**结果——草稿，或路网明确回答的「无路」类错误（没路 / 太远 / 铁路不像隧道 …）。
/// 传输失败、429 冷却、取消都不是答案，不缓存（下次照常请求）。主线程持有，批量 worker（nonisolated）通过锁访问
final class RouteCache: @unchecked Sendable {
    enum Value: Sendable {
        case draft(RouteDraft)
        case noRoute(RouteError)
    }
    private var entries: [RouteCacheKey: Value] = [:]
    private var hitCount = 0
    private let lock = NSLock()

    /// 命中就计一次 hits（统计用：界面「命中缓存 N 处」按项另算）
    func lookup(_ key: RouteCacheKey) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard let v = entries[key] else { return nil }
        hitCount += 1
        return v
    }
    func store(_ key: RouteCacheKey, _ value: Value) {
        lock.lock(); defer { lock.unlock() }
        entries[key] = value
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries = [:]; hitCount = 0
    }
    var stats: (entries: Int, hits: Int) {
        lock.lock(); defer { lock.unlock() }
        return (entries.count, hitCount)
    }
    /// 这个错误是不是路网给出的确定答案（可缓存）：RouteError 里除「服务不可用 / 响应无法解析」之外都是；
    /// 「没路」若同时有候选传输失败（partial）也不算确定答案
    static func isCacheable(_ error: Error) -> Bool {
        guard let r = error as? RouteError else { return false }
        switch r {
        case .allEndpointsFailed, .badResponse: return false
        case .noRoute(_, let partial): return !partial
        default: return true
        }
    }
    /// 命中时加在草稿说明首行
    static var hitNote: String { String(localized: "路网结果来自缓存（本文件打开以来取过）", comment: "Route note: this result was served from the in-memory cache (fetched earlier for this file) instead of a new request") }
}

/// Overpass 结果按包围盒缓存：同一条铁路线上相邻的断档共用一次查询
final class OverpassCache: @unchecked Sendable {
    private var entries: [(bbox: (s: Double, w: Double, n: Double, e: Double), elements: [[String: Any]])] = []
    private let lock = NSLock()

    func lookup(s: Double, w: Double, n: Double, e: Double) -> [[String: Any]]? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.bbox.s <= s && $0.bbox.w <= w && $0.bbox.n >= n && $0.bbox.e >= e }?.elements
    }
    func store(s: Double, w: Double, n: Double, e: Double, elements: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        entries.append(((s, w, n, e), elements))
        if entries.count > 32 { entries.removeFirst() }
    }
}


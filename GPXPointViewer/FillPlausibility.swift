//
//  FillPlausibility.swift
//  GPXPointViewer
//
//  补点「落地前自检」：对一处将要落地的补点序列算一组纯几何/规则指标，合成 0–100 的风险分并附上人话原因。
//  不用模型、不联网、无 UI 依赖（离线 synthrunner 也编它）。指标与阈值来源：Tests/reports/20261026_1500_tunnel_diagnosis.md
//  §1–§3（上周 5 处补错点：trimEnds+taper 伪影 16–32 m、Garmin 真实点离 OSM 线 0–7 m、分向车道中心线相距 11–30 m）。
//  设计：docs/fill-plausibility-design.md §1。
//

import Foundation
import CoreLocation
import simd

/// 路线沿途的一步（一段同名/同编号的道路）：OSRM steps / Valhalla maneuvers 带回来的
struct RouteLeg: Equatable, Sendable {
    var ref: String        // 道路编号，如 "A22"；没有为空串
    var name: String       // 道路名，如 "Autostrada del Brennero"；没有为空串
    var meters: Double     // 这一步的长度（米）
    /// 给用户看的名字：编号优先，再名字；都没有为 nil
    var label: String? {
        if !ref.isEmpty { return ref }
        if !name.isEmpty { return name }
        return nil
    }
    /// 同一条路：编号相同（都有编号时）；否则名字相同；都没有信息 → 当作同一条（不计换路）
    static func sameRoad(_ x: RouteLeg, _ y: RouteLeg) -> Bool {
        if !x.ref.isEmpty, !y.ref.isEmpty { return x.ref == y.ref }
        if !x.name.isEmpty, !y.name.isEmpty { return x.name == y.name }
        return x.label == nil || y.label == nil
    }
}

struct FillPlausibility: Equatable {
    enum Level: String, Equatable { case low, medium, high }

    /// 全部指标；nil = 该项没有数据（不扣分，原因里也不提）
    struct Metrics: Equatable {
        var devRouteMax: Double = 0          // 补点到路网原始折线（clip 输出）的最大距离（taper 区内扣掉允许量）
        var devRouteMedian: Double = 0
        var devRouteAllowance: Double = 0    // devRouteMax 那一处扣掉的端部允许量（0 = 不在端部区）；原因文案里写出来
        var devSampledVertices: Bool = false // 补点太少（< Thresholds.sparsePointsBelow）：按补点所沿折线的顶点采样，而不是按补点
        var detourRatio: Double = 1          // 路网长度 ÷ A–B 直线
        var impliedSpeedKmh: Double = 0      // 路网长度 ÷ 空洞时长
        var impliedSpeedRatio: Double? = nil // 隐含速度 ÷ 前后真实车速中位（= 任务文档的 detourVsExpected，同一公式）
        var headingA: Double? = nil          // 路线起始方向与 A 侧行进方向夹角（度）
        var headingB: Double? = nil
        var roadRefChanges: Int? = nil       // 沿途道路编号/名称变化次数（没有道路信息 = nil）
        var roadMatchesContext: Bool? = nil  // 首步与 A 侧所在道路、末步与 B 侧所在道路一致
        var snapA: Double = 0
        var snapB: Double = 0
        var taperExcessA: Double = 0         // taperA − residualA（>10 = 起始段几何被拉过去的伪影信号）
        var taperExcessB: Double = 0
        var crossMaxDev: Double? = nil       // 精确模式两路最大偏差
        var uTurnCount: Int = 0              // 路线上相邻段方向翻转 >150° 的次数
        var innerMaxOff: Double? = nil       // 区间内被保留/改时的真实点到路线的最大距离
        var tunnelShare: Double? = nil       // 隧道占比（OSRM intersections.classes；Valhalla / 旧录音 = nil 未知）
        var tunnelWaived: Bool = false       // 隧道占比高且补点贴路网：锚点离路的扣分免了
        var routeMeters: Double = 0
        var straightMeters: Double = 0
        var seconds: Double = 0
    }

    /// 阈值表（集中一处，考卷调参改这里）。每项 (档位上限, 分)，按第一个满足 `value <= bound` 的档计分；超过最后一档取 `over`
    struct Thresholds: Equatable {
        struct Ladder: Equatable {
            var steps: [(bound: Double, points: Int)]
            var over: Int
            func score(_ v: Double) -> Int {
                for s in steps where v <= s.bound { return s.points }
                return over
            }
            static func == (a: Ladder, b: Ladder) -> Bool { a.over == b.over && a.steps.map { $0.bound } == b.steps.map { $0.bound } && a.steps.map { $0.points } == b.steps.map { $0.points } }
        }
        // 来源：诊断 §1.2 伪影 16–32 m、Garmin 真实点离 OSM 0–7 m（≤5 不扣）、分向车道 11–30 m（15–30 档）
        var devRouteMax = Ladder(steps: [(5, 0), (15, 10), (30, 30)], over: 60)
        var devRouteMedian = Ladder(steps: [(3, 0), (10, 10)], over: 25)
        /// 伪影信号 taperExcess = taper − residual（起止段被拉离路网原始折线的量，扣掉锚点本来离路的部分）：
        /// ≤10 不扣（与 RouteCrossCheck.anchorWarning 同门槛）；10–18 扣 30；>18 扣 50（单项即到 medium 上沿，再加任何一项就 high）。
        /// 2026-10-28 方案 B（docs/fill-plausibility-design.md §8）：扰动题「伪影」里 16 题锚点本身离路 7–19 m，端部允许量
        /// min(taper, residual) 把 32 m 的推开吃掉大半，devRouteMax 只扣 10，risk 停在 40–50；伪影信号本身（excess 20–30）
        /// 才是稳定的证据。重扣档上限取 18 而不是 §8 写的 20：上周 5 处真伪影的原型是 taper 32 对 snap 12，excess 正好 20，
        /// 按「>20」会落在 30 分档（+ dev 10 = 40，medium）；基础题 excess 全 ≤0、真实数据 ≤10，18 与 20 的误报余量一样
        var taperExcess = Ladder(steps: [(10, 0), (18, 30)], over: 50)
        /// 补点少于这个数时（<10 s 的短断档），P 按补点所沿折线（后处理后的顶点）采样伪影信号，而不是按补点：
        /// 5–6 个点、首点离 A 30 m 以上时，被推开的峰值落在两点之间采不到（§8 的 0018/0030）
        var sparsePointsBelow = 4
        var detourRatio = Ladder(steps: [(1.3, 0), (1.8, 10), (2.5, 25)], over: 50)   // carRoute 的「远长于直线」警告是 2.5×
        /// 隐含速度 ÷ 前后车速：0.6–1.5 正常（隧道里常减速），0.4–0.6 / 1.5–2.0 留意，其它扣 40
        var speedRatioLow = 0.6, speedRatioHigh = 1.5, speedRatioLow2 = 0.4, speedRatioHigh2 = 2.0
        var speedRatioMild = 15, speedRatioBad = 40
        var heading = Ladder(steps: [(30, 0), (60, 10), (120, 25)], over: 45)         // OSRM bearings 容差 ±45°
        var roadRefChanges = Ladder(steps: [(0, 0), (1, 10)], over: 20)
        var roadMismatch = 20
        var snap = Ladder(steps: [(0, 0), (60, 10), (150, 25)], over: 40)             // 第一档上限在 assess 里换成 max(1.5×半径, 20)
        var snapMildFrom = 10.0, snapMild = 10                                        // 漂移容差内但 >10 m：轻度扣分（考卷调的）
        var crossMaxDev = Ladder(steps: [(10, 0), (30, 10)], over: 25)                // 交叉验证容差 10 m
        var uTurn = 25, uTurnCap = 50
        var innerOff = Ladder(steps: [(0, 0), (30, 10)], over: 25)                    // 第一档上限在 assess 里换成 max(半径, 10)
        /// 隧道：tunnelShare ≥ tunnelShareWaive 且补点离路网原始折线最远 ≤ devRouteMax 第一档（5 m）时，
        /// 锚点离路 ≤ tunnelSnapWaiveMax 的扣分（含轻度那条）免掉——隧道口 GPS 漂移让锚点「看着在路外」，补点本身在路网上。
        /// tunnelShare 为 nil（未知）时不生效，与之前完全一样。2026-10-28 新增，不动其它阈值
        var tunnelShareWaive = 0.5, tunnelSnapWaiveMax = 60.0
        /// 等级边界：risk < mediumFrom → low；≤ highFrom → medium；> highFrom → high
        var mediumFrom = 20, highFrom = 50

        static let `default` = Thresholds()
        /// 当前生效的阈值（考卷调参 / 自测可整体替换）
        nonisolated(unsafe) static var current = Thresholds()
    }
    /// 钩子 `riskthreshold <n>`：临时改 high 门槛（分 > n 为 high）；nil = 用 Thresholds.current.highFrom
    nonisolated(unsafe) static var highThresholdOverride: Int? = nil

    struct Input {
        var a: CLLocationCoordinate2D
        var b: CLLocationCoordinate2D
        var points: [CLLocationCoordinate2D]        // 将落地的合成点（不含锚点）
        var routeRaw: [CLLocationCoordinate2D]      // 路网原始折线（clip 输出、后处理前）；空 = 没有（直线补）
        /// 补点所沿的折线顶点（后处理后的 RouteDraft.coords；有改时计划时是裁到第一个保留点的 plan.vertices）。
        /// 补点 < Thresholds.sparsePointsBelow 时 P 用它代替 points 采样「补点离路网」；空 = 没有（直线补 / 旧调用方）
        var vertices: [CLLocationCoordinate2D] = []
        var routeMeters: Double
        var seconds: Double
        var bearingA: Double? = nil
        var bearingB: Double? = nil
        var refSpeedMps: Double? = nil
        var snapA: Double = 0
        var snapB: Double = 0
        var residualA: Double = 0, residualB: Double = 0
        var taperA: Double = 0, taperB: Double = 0
        var legs: [RouteLeg] = []
        var roadBeforeA: RouteLeg? = nil
        var roadAfterB: RouteLeg? = nil
        var crossMaxDev: Double? = nil
        var innerMaxOff: Double? = nil
        var tunnelShare: Double? = nil
        var matchRadius: Double = 15
        /// 合成点只铺到第一个改时点时（StaleRetime）：b 是那个点，straightB 仍是原锚点 B（直线/速度按原断档算），
        /// endOffB = 那个点到路网原始折线的距离（≤ 容差，是合法的端部偏移，不是贴路信号）
        var straightB: CLLocationCoordinate2D? = nil
        var endOffB: Double? = nil
    }

    var metrics: Metrics
    var risk: Int
    var level: Level
    var reasons: [String]

    static func level(for risk: Int, thresholds t: Thresholds = Thresholds.current) -> Level {
        let high = highThresholdOverride ?? t.highFrom
        if risk > high { return .high }
        if risk >= t.mediumFrom { return .medium }
        return .low
    }

    // MARK: - 评估

    static func assess(_ inp: Input, thresholds t: Thresholds = Thresholds.current) -> FillPlausibility {
        var m = Metrics()
        var reasons: [String] = []
        var risk = 0
        func add(_ pts: Int, _ why: @autoclosure () -> String) { if pts > 0 { risk += pts; reasons.append(why()) } }

        let f = PortalDrift.Frame(origin: inp.a)
        let qa = f.xy(inp.a), qb = f.xy(inp.straightB ?? inp.b)
        m.straightMeters = simd_length(qb - qa)
        m.routeMeters = inp.routeMeters
        m.seconds = inp.seconds
        m.snapA = inp.snapA; m.snapB = inp.snapB
        m.taperExcessA = inp.taperA - inp.residualA
        m.taperExcessB = inp.taperB - inp.residualB
        m.crossMaxDev = inp.crossMaxDev
        m.innerMaxOff = inp.innerMaxOff
        m.tunnelShare = inp.tunnelShare

        // 1) 补点到路网原始折线：P 每 5 m 取样，到 R 的距离；taper 区内允许 d + 5 m
        // 补点太少时按补点所沿折线的顶点采样（补点都在这条折线上；点少时峰值会落在两点之间）
        let useVertices = inp.points.count < t.sparsePointsBelow && !inp.vertices.isEmpty
        m.devSampledVertices = useVertices
        let P = PortalDrift.Poly([inp.a] + (useVertices ? inp.vertices : inp.points) + [inp.b], frame: f)
        if inp.routeRaw.count >= 2, P.pts.count >= 2, P.length > 1 {
            let R = PortalDrift.Poly(inp.routeRaw, frame: f)
            // 端部允许量：锚点本来就离路 residual 米，补点从锚点斜到路上是正常的——taper 触发时在 L = clamp(6d,80,400) 内
            // 线性消化 min(taper, residual)（taper 比 residual 大的那部分不是路网，不放过：上周伪影就是 taper 32 对 snap 12）；
            // 没 taper 时在 A→首顶点那一段里消化 snap。线性 + 10% 的余量能盖住 taper 的平滑权重
            func taperLen(_ d: Double) -> Double { d > 0 ? min(0.45 * P.length, min(400, max(80, 6 * d))) : 0 }
            func endZone(taper: Double, residual: Double, snap: Double, firstSeg: Double) -> (len: Double, off: Double) {
                taper > 0 ? (taperLen(taper), min(taper, residual)) : (firstSeg, snap)
            }
            let zA = endZone(taper: inp.taperA, residual: inp.residualA, snap: inp.snapA, firstSeg: P.pts.count >= 2 ? simd_length(P.pts[1] - P.pts[0]) : 0)
            let lastSeg = P.pts.count >= 2 ? simd_length(P.pts[P.pts.count - 1] - P.pts[P.pts.count - 2]) : 0
            let zB: (len: Double, off: Double) = inp.endOffB.map { (len: lastSeg, off: $0) } ?? endZone(taper: inp.taperB, residual: inp.residualB, snap: inp.snapB, firstSeg: lastSeg)
            var devs: [Double] = []
            var allowAtMax = 0.0, devMax = -1.0
            var s = 0.0
            var k = 1
            while true {
                let sc = min(s, P.length)
                while k < P.pts.count - 1, P.acc[k] < sc { k += 1 }
                let l = P.acc[k] - P.acc[k - 1]
                let tt = l > 0 ? max(0, min(1, (sc - P.acc[k - 1]) / l)) : 0
                let pt = P.pts[k - 1] + (P.pts[k] - P.pts[k - 1]) * tt
                var allowed = 0.0
                if zA.len > 0, sc < zA.len { allowed = zA.off * (1 - sc / zA.len) + max(5, 0.1 * zA.off) }
                if zB.len > 0, P.length - sc < zB.len { allowed = max(allowed, zB.off * (1 - (P.length - sc) / zB.len) + max(5, 0.1 * zB.off)) }
                let dev = max(0, R.project(pt).d - allowed)
                if dev > devMax { devMax = dev; allowAtMax = allowed }
                devs.append(dev)
                if sc >= P.length { break }
                s += 5
            }
            let sorted = devs.sorted()
            m.devRouteMax = sorted.last ?? 0
            m.devRouteMedian = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            m.devRouteAllowance = m.devRouteMax > 0 ? allowAtMax : 0
            let dmax = m.devRouteMax, dmed = m.devRouteMedian, dall = m.devRouteAllowance
            add(t.devRouteMax.score(dmax), dall >= 0.5
                ? String(localized: "补点离路网原始折线最远 \(dmax, format: Fmt.f0) m（已扣除端部允许的 \(dall, format: Fmt.f0) m；应 ≤5 m）", comment: "Plausibility reason: the synthetic points stray from the raw road-network polyline, after subtracting the allowance near the anchor. 1st = maximum excess distance in m, 2nd = allowance subtracted at that spot in m")
                : String(localized: "补点离路网原始折线最远 \(dmax, format: Fmt.f0) m（应 ≤5 m）", comment: "Plausibility reason: the synthetic points stray from the raw road-network polyline. %@ = maximum distance in m"))
            add(t.devRouteMedian.score(dmed), String(localized: "补点离路网原始折线中位 \(dmed, format: Fmt.f0) m（应 ≤3 m）", comment: "Plausibility reason: median distance of the synthetic points from the raw road-network polyline. %@ = median distance in m"))
            // 折返：R 相邻两段（各 ≥10 m）方向翻转 >150°
            var turns = 0
            var prevSeg: Int? = nil
            for seg in 0..<(R.pts.count - 1) where simd_length(R.pts[seg + 1] - R.pts[seg]) >= 10 {
                if let p = prevSeg {
                    var d = abs(R.bearing(seg: seg) - R.bearing(seg: p))
                    if d > 180 { d = 360 - d }
                    if d > 150 { turns += 1 }
                }
                prevSeg = seg
            }
            m.uTurnCount = turns
            if turns > 0 {
                add(min(t.uTurnCap, turns * t.uTurn), String(localized: "路线上有 \(turns) 处折返（相邻路段方向翻转超过 150°）", comment: "Plausibility reason: the route doubles back on itself. %lld = number of U-turn-like reversals"))
            }
            // 起止方向
            func chordBearing(_ pts: [SIMD2<Double>]) -> Double? {
                guard let p0 = pts.first else { return nil }
                for p in pts.dropFirst() where simd_length(p - p0) >= 20 {
                    let d = p - p0
                    let b = atan2(d.x, d.y) * 180 / .pi
                    return b < 0 ? b + 360 : b
                }
                return nil
            }
            func angDiff(_ x: Double, _ y: Double) -> Double { let d = abs(x - y).truncatingRemainder(dividingBy: 360); return d > 180 ? 360 - d : d }
            if let ba = inp.bearingA, let rb = chordBearing(R.pts) {
                let h = angDiff(ba, rb); m.headingA = h
                add(t.heading.score(h), String(localized: "路线起始方向与 A 侧行进方向差 \(h, format: Fmt.f0)°", comment: "Plausibility reason: the route starts in a different direction than the track was travelling at anchor A. %@ = angle in degrees"))
            }
            if let bb = inp.bearingB, let rb = chordBearing(Array(R.pts.reversed())) {
                let h = angDiff(bb, (rb + 180).truncatingRemainder(dividingBy: 360)); m.headingB = h
                add(t.heading.score(h), String(localized: "路线末段方向与 B 侧行进方向差 \(h, format: Fmt.f0)°", comment: "Plausibility reason: the route ends in a different direction than the track continues after anchor B. %@ = angle in degrees"))
            }
        }

        // 2) 伪影信号：taper 远多于锚点离路（excess = 两者之差；>20 m 是重扣档，文案把差值写出来）
        let te = max(m.taperExcessA, m.taperExcessB)
        if te > 0 {
            let aSide = m.taperExcessA >= m.taperExcessB
            let pull = aSide ? inp.taperA : inp.taperB, off = aSide ? inp.residualA : inp.residualB
            add(t.taperExcess.score(te), aSide
                ? String(localized: "起始段向 A 靠拢了 \(pull, format: Fmt.f0) m，比 A 离路的 \(off, format: Fmt.f0) m 多出 \(te, format: Fmt.f0) m：起始几何可能不是路网", comment: "Plausibility reason: the start was bent towards anchor A much more than A's distance from the road. 1st = taper offset in m, 2nd = A's distance from the road in m, 3rd = the excess (1st minus 2nd) in m")
                : String(localized: "末尾段向 B 靠拢了 \(pull, format: Fmt.f0) m，比 B 离路的 \(off, format: Fmt.f0) m 多出 \(te, format: Fmt.f0) m：末尾几何可能不是路网", comment: "Plausibility reason: the end was bent towards anchor B much more than B's distance from the road. 1st = taper offset in m, 2nd = B's distance from the road in m, 3rd = the excess (1st minus 2nd) in m"))
        }

        // 3) 绕路与隐含速度
        if inp.routeMeters > 0, m.straightMeters > 1 {
            m.detourRatio = inp.routeMeters / m.straightMeters
            let r = m.detourRatio
            add(t.detourRatio.score(r), String(localized: "路网长度是直线的 \(r, format: Fmt.f1) 倍", comment: "Plausibility reason: route length divided by the straight-line distance between the anchors. %@ = ratio"))
        }
        if inp.seconds > 0, inp.routeMeters > 0 {
            let v = inp.routeMeters / inp.seconds
            m.impliedSpeedKmh = v * 3.6
            if let ref = inp.refSpeedMps, ref > 1 {
                let ratio = v / ref
                m.impliedSpeedRatio = ratio
                var pts = 0
                if ratio < t.speedRatioLow2 || ratio > t.speedRatioHigh2 { pts = t.speedRatioBad }
                else if ratio < t.speedRatioLow || ratio > t.speedRatioHigh { pts = t.speedRatioMild }
                let kmh = v * 3.6
                add(pts, ratio > 1
                    ? String(localized: "按时长算 \(kmh, format: Fmt.f0) km/h，是前后车速的 \(ratio, format: Fmt.f1) 倍", comment: "Plausibility reason: the implied speed across the gap is much higher than the recorded speed before/after. 1st = implied speed in km/h, 2nd = ratio")
                    : String(localized: "按时长算只有 \(kmh, format: Fmt.f0) km/h，是前后车速的 \(ratio, format: Fmt.f1) 倍", comment: "Plausibility reason: the implied speed across the gap is much lower than the recorded speed before/after. 1st = implied speed in km/h, 2nd = ratio"))
            }
        }

        // 4) 道路编号/名称
        let named = inp.legs.filter { $0.label != nil }
        if !named.isEmpty {
            // 只比相邻的「有名字」的步：匝道/连接线常没有 ref 也没有 name，夹在中间不算换路，也不该把前后两条路隔开
            var changes = 0
            var from: RouteLeg? = nil, to: RouteLeg? = nil
            for k in 1..<max(1, named.count) where !RouteLeg.sameRoad(named[k - 1], named[k]) {
                changes += 1
                if from == nil { from = named[k - 1]; to = named[k] }
            }
            m.roadRefChanges = changes
            if changes > 0, let f0 = from?.label, let t0 = to?.label {
                add(t.roadRefChanges.score(Double(changes)), changes == 1
                    ? String(localized: "路线沿途道路从 \(f0) 换到 \(t0)", comment: "Plausibility reason: the route changes road once. 1st = road ref/name before, 2nd = road after")
                    : String(localized: "路线沿途换了 \(changes) 次路（先从 \(f0) 换到 \(t0)）", comment: "Plausibility reason: the route changes road several times. 1st = number of changes, 2nd = road before the first change, 3rd = road after it"))
            }
            var matches: Bool? = nil
            if let before = inp.roadBeforeA, before.label != nil, let first = inp.legs.first, first.label != nil {
                matches = RouteLeg.sameRoad(before, first)
                if matches == false, let x = first.label, let y = before.label {
                    add(t.roadMismatch, String(localized: "路线起点所在道路（\(x)）与 A 侧所在道路（\(y)）不同", comment: "Plausibility reason: the route starts on a different road than the track was on before anchor A. 1st = route's first road, 2nd = road at A"))
                }
            }
            if let after = inp.roadAfterB, after.label != nil, let last = inp.legs.last, last.label != nil {
                let ok = RouteLeg.sameRoad(after, last)
                matches = matches == nil ? ok : (matches! && ok)
                if !ok, let x = last.label, let y = after.label {
                    add(t.roadMismatch, String(localized: "路线终点所在道路（\(x)）与 B 侧所在道路（\(y)）不同", comment: "Plausibility reason: the route ends on a different road than the track continues on after anchor B. 1st = route's last road, 2nd = road at B"))
                }
            }
            m.roadMatchesContext = matches
        }

        // 5) 锚点贴路
        var snap = t.snap
        if !snap.steps.isEmpty { snap.steps[0].bound = max(1.5 * inp.matchRadius, 20) }
        // 隧道免扣：隧道占比高、补点又贴着路网原始折线（devRoute 小）→ 锚点「看着在路外」是隧道口漂移，不扣
        let devSmall = inp.routeRaw.count >= 2 && m.devRouteMax <= (t.devRouteMax.steps.first?.bound ?? 5)
        let tunnelWaive = (inp.tunnelShare ?? 0) >= t.tunnelShareWaive && inp.tunnelShare != nil && devSmall
        func waived(_ s: Double) -> Bool { tunnelWaive && s <= t.tunnelSnapWaiveMax }
        if tunnelWaive, [inp.snapA, inp.snapB].contains(where: { waived($0) && (snap.score($0) > 0 || $0 > t.snapMildFrom) }) { m.tunnelWaived = true }
        if !waived(inp.snapA) { add(snap.score(inp.snapA), String(localized: "锚点 A 离路网 \(inp.snapA, format: Fmt.f0) m", comment: "Plausibility reason: anchor A is far from the road network. %@ = distance in m")) }
        if !waived(inp.snapB) { add(snap.score(inp.snapB), String(localized: "锚点 B 离路网 \(inp.snapB, format: Fmt.f0) m", comment: "Plausibility reason: anchor B is far from the road network. %@ = distance in m")) }
        // 轻度：锚点在漂移容差内但明显大于这类设备的典型离路（考卷 2026-10-27：通过题锚点离路中位 2.5 m、p90 7 m；
        // 4 道未通过题 snapB 10–19 m——GPS 与 OSM 中心线在匝道/分向车道处不一致，补点沿路网走就会和真实轨迹差这么多）
        for (name, s) in [("A", inp.snapA), ("B", inp.snapB)] where snap.score(s) == 0 && s > t.snapMildFrom && !waived(s) {
            add(t.snapMild, String(localized: "锚点 \(name) 离路网 \(s, format: Fmt.f0) m（这类设备通常 ≤5 m）：补点沿路网走，会和真实轨迹差这么多", comment: "Plausibility reason (mild): the anchor is further from the road than typical for this device, so the filled points (which follow the road) will differ from the real track by about that much. 1st = anchor letter A or B, 2nd = distance in m"))
        }

        // 6) 两路比对、保留的真实点
        if let x = inp.crossMaxDev {
            add(t.crossMaxDev.score(x), String(localized: "两路路网结果最大相差 \(x, format: Fmt.f0) m", comment: "Plausibility reason: the two routers' geometries differ. %@ = maximum deviation in m"))
        }
        if let x = inp.innerMaxOff {
            var inner = t.innerOff
            if !inner.steps.isEmpty { inner.steps[0].bound = max(inp.matchRadius, 10) }
            add(inner.score(x), String(localized: "保留的真实点离路线最远 \(x, format: Fmt.f0) m", comment: "Plausibility reason: a real point kept inside the gap lies far from the route. %@ = distance in m"))
        }

        risk = min(100, risk)
        return FillPlausibility(metrics: m, risk: risk, level: level(for: risk, thresholds: t), reasons: reasons)
    }

    /// 前后真实车速中位（m/s）：候选的单步 / 窗口速度里 >0 的取中位；没有候选 = nil
    static func refSpeed(_ c: GapCandidate?) -> Double? {
        guard let c else { return nil }
        let v = [c.speedInKmh, c.speedOutKmh, c.windowSpeedInKmh ?? 0, c.windowSpeedOutKmh ?? 0].filter { $0 > 0 && $0.isFinite }.sorted()
        guard !v.isEmpty else { return nil }
        return v[v.count / 2] / 3.6
    }

    /// 由草稿 + 路由输入 + 将落地的点组装评估输入（批量 / 单处 / 考卷三处共用，口径一致）。
    /// a/b = 最终落地锚点（草稿外推后的），points = 将落地的合成点（含改时点），innerMaxOff = 保留的真实点离 P 的最大距离；
    /// vertices = 补点所沿的折线顶点（默认 = 草稿 coords；有改时计划时 retarget 会裁到第一个保留点）
    static func input(draft d: RouteDraft, a: CLLocationCoordinate2D, b: CLLocationCoordinate2D, seconds: Double,
                      points: [CLLocationCoordinate2D], inputs inp: GapRouteInputs.Inputs?, candidate c: GapCandidate?,
                      crossMaxDev: Double?, innerMaxOff: Double?, vertices: [CLLocationCoordinate2D]? = nil) -> Input {
        var x = Input(a: a, b: b, points: points, routeRaw: d.rawCoords, routeMeters: d.meters, seconds: seconds)
        x.vertices = vertices ?? d.coords
        x.bearingA = inp?.a.heading.bearing; x.bearingB = inp?.b.heading.bearing
        x.refSpeedMps = refSpeed(c)
        x.snapA = d.snapA; x.snapB = d.snapB
        x.residualA = d.residualA; x.residualB = d.residualB
        x.taperA = d.taperA; x.taperB = d.taperB
        x.legs = d.legs; x.roadBeforeA = d.roadBeforeA; x.roadAfterB = d.roadAfterB
        x.crossMaxDev = crossMaxDev; x.innerMaxOff = innerMaxOff
        x.tunnelShare = d.tunnelShare
        x.matchRadius = inp?.radius ?? 15
        return x
    }

    /// 有改时计划时合成点只铺到第一个保留点：把它当 P 的终点 b，snapB 换成它到路网原始折线的距离（≤ 容差，是合法的端部偏移）
    static func retarget(_ x: Input, fillB: CLLocationCoordinate2D) -> Input {
        var y = x
        y.straightB = x.b
        y.b = fillB
        let f = PortalDrift.Frame(origin: x.a)
        if x.routeRaw.count >= 2 {
            y.endOffB = PortalDrift.Poly(x.routeRaw, frame: f).project(f.xy(fillB)).d
        }
        // 顶点裁到第一个保留点的投影处（与 StaleRetime.plan 同一规则：只留投影所在线段之前的顶点）
        if !x.vertices.isEmpty {
            let hit = PortalDrift.Poly([x.a] + x.vertices + [x.b], frame: f).project(f.xy(fillB))
            y.vertices = Array(x.vertices.prefix(min(x.vertices.count, hit.seg)))
        }
        return y
    }

    /// 保留/改时的真实点到路线 P（a + points + b）的最大距离；没有这类点 = nil
    static func innerMaxOff(a: CLLocationCoordinate2D, points: [CLLocationCoordinate2D], b: CLLocationCoordinate2D, real: [CLLocationCoordinate2D]) -> Double? {
        guard !real.isEmpty else { return nil }
        let f = PortalDrift.Frame(origin: a)
        let P = PortalDrift.Poly([a] + points + [b], frame: f)
        guard P.pts.count >= 2 else { return nil }
        return real.map { P.project(f.xy($0)).d }.max()
    }

    /// 直线补（没有路网折线）：只有绕路/速度/贴路这些信息可用；给个最小评估，别让直线显得比路网还安全
    static func assessStraight(a: CLLocationCoordinate2D, b: CLLocationCoordinate2D, seconds: Double, refSpeedMps: Double?, matchRadius: Double) -> FillPlausibility {
        let d = GeoMath.haversine(a.latitude, a.longitude, b.latitude, b.longitude)
        return assess(Input(a: a, b: b, points: [], routeRaw: [], routeMeters: d, seconds: seconds, refSpeedMps: refSpeedMps, matchRadius: matchRadius))
    }

    /// 徽标文字（批量窗口「风险」列）：high「要看一眼」/ medium「留意」/ low 空
    var badge: String {
        switch level {
        case .high: return String(localized: "要看一眼", comment: "Batch gap fill risk badge for a high-risk fill: please look at it on the map before applying")
        case .medium: return String(localized: "留意", comment: "Batch gap fill risk badge for a medium-risk fill")
        case .low: return ""
        }
    }
    /// 一行摘要（notes / help）
    var summaryLine: String {
        let n = risk
        switch level {
        case .high: return String(localized: "落地前自检：风险 \(n)（要看一眼）", comment: "Plausibility summary line. %lld = risk score 0–100; level high")
        case .medium: return String(localized: "落地前自检：风险 \(n)（留意）", comment: "Plausibility summary line. %lld = risk score 0–100; level medium")
        case .low: return String(localized: "落地前自检：风险 \(n)（正常）", comment: "Plausibility summary line. %lld = risk score 0–100; level low")
        }
    }
    /// high 时加在草稿说明里的一句
    static var highNote: String { String(localized: "落地前自检判为要看一眼：默认不勾选落地，看过地图后可手动勾上", comment: "Route note added to a high-risk batch item: it is unticked by default; the user can tick it after checking the map") }
}

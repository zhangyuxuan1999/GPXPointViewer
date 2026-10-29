//
//  GapFill.swift
//  GPXPointViewer
//
//  断档补点（隧道等 GPS 失锁段）：
//  - GapDetector：从时间有序的轨迹里找"行车状态下的断档"候选（两端相距 ≥150m、
//    间隔 20s–1h、隐含速度 15–350 km/h），按时间排列；
//  - FillPath：锚点 A → 用户折线顶点 → 锚点 B，按弧长等距生成密集合成点，
//    时间在 (tA, tB) 内按弧长匀速插值（整数秒唯一，便于一生足迹 CSV）；
//  - GapFill：一次落地记录（时间键、锚点、顶点、合成点、删掉的区间内点数）；
//  - GapFillExport：世界迷雾 GPX（只要折线，不要时间）/ 一生足迹增量 CSV（11 列）。
//  数据内部恒为 WGS-84；地图取坐标/往地图画坐标统一经 GeoCoord 挂点。
//

import Foundation
import CoreLocation

/// 坐标系挂点：目前恒等。人在中国大陆时 MapKit 底图为高德 GCJ-02，
/// 届时在这里补 wgs↔gcj 转换并加设置开关——数据内部永远是 WGS-84
enum GeoCoord {
    static func mapToData(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D { c }
    static func dataToMap(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D { c }
}

enum GeoMath {
    static let earthRadius = 6_371_000.0

    /// 球面距离（米）
    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// 初始方位角（度，0 = 北，顺时针）
    static func bearing(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        var b = atan2(y, x) * 180 / .pi
        if b < 0 { b += 360 }
        return b
    }
}

/// 断档候选。两种成因：
/// - timeGap：时间空洞——两点时间差 ≥20s 且距离 ≥150m（一生足迹类 app：失锁期间不记）；
/// - staleClock：Garmin 类设备——失锁期间不记，重新定位后头几个点带着**过时的时间戳**
///   （紧接入口时间），之后时钟一次跳回真实时间。表现为相邻两点时间差 1–2s 却相距
///   数百米到十几公里，几个点之后出现一次时间跳变。锚点取 入口最后一点 → 时间跳变后
///   首点，中间那几个时间错误的出口点默认删除，时间跨度即真实用时
struct GapCandidate: Identifiable, Equatable {
    enum Kind { case timeGap, staleClock, jitter }
    var id: Double { tA }               // 时间键：下标在每次落地后都会变
    let kind: Kind
    let indexA: Int                     // 锚点 A（当前 TrackData 下标）
    let indexB: Int                     // 锚点 B（> indexA；timeGap 时 = indexA+1）
    let tA: Double
    let tB: Double
    let latA: Double, lonA: Double
    let latB: Double, lonB: Double
    let meters: Double                  // A→B 直线距离
    var seconds: Double { tB - tA }
    var kmh: Double { seconds > 0 ? meters / seconds * 3.6 : 0 }
    var innerCount: Int { max(0, indexB - indexA - 1) }
    let speedInKmh: Double              // 进断档前的记录速度
    let speedOutKmh: Double             // 出断档后的记录速度
    /// 窗口速度：从锚点往外第一个 ≥10 s 或 ≥100 m 的点算的平均速度（跨断档或 60 s 内取不到 → nil）。
    /// 单步速度在手机跳点上不可信（一步 1.3 km / 3 s），判铁路要求两者都 >170
    var windowSpeedInKmh: Double? = nil
    var windowSpeedOutKmh: Double? = nil
    /// 隧道群：由几处相邻断档并成（1 = 单独一处）。并起来的区间里夹着的点（隧道群之间手机常只记到一两个离路几百米的假点）落地时随区间替换
    var chainCount: Int = 1
    /// A 侧冻结假点链前移的点数（见 GapDetector.shiftFrozenChains）：>0 时 indexA 已比检测结果往前挪了这么多点，
    /// 原 A−n+1…A（进隧道后航向/步长锁死的外推点）现在落在区间内，落地时随区间替换
    var frozenA: Int = 0
    /// 乱跳簇（kind == .jitter）：区间内的点在相隔几百米到几公里的位置之间来回跳——车厢里没信号时设备回放旧位置、
    /// 或两路定位交替。统计量给用户看：大跳步数、倒退步数、最大一步
    var jitterJumps: Int = 0
    var jitterReversals: Int = 0
    var jitterMaxJump: Double = 0
    /// 列表筛选用：分类器有把握判为铁路（隐含 >200 且前后记录速度支持，或单步+窗口速度都 >170）
    var looksLikeRail: Bool { BatchClassifier.classify(self) == .rail }

    static func == (a: GapCandidate, b: GapCandidate) -> Bool { a.tA == b.tA && a.tB == b.tB }
}

/// 轨迹的采样画像。补点流程里凡是和"点有多密"有关的门槛都从这里换算，
/// 而不是写死在 Garmin 1 Hz / 27 m 上：一生足迹前台约 3 s / 75 m，后台 7–28 s / 60 m–4 km，
/// 定位精度也差一个量级（专用记录仪 3–5 m，手机 10–15 m、长尾 50 m+）
struct SamplingProfile: Equatable {
    enum Kind: Equatable { case deviceLogger, phone, unknown }
    var kind: Kind
    var creator: String
    var medianDt: Double          // 移动步（速度 >1 m/s）的步时中位数，秒
    var q90Dt: Double
    var medianStep: Double        // 移动步的步长中位数，米
    var q90Step: Double
    var accuracy: Double?         // CSV 精度列中位数（米）；无则 nil
    var sampleCount: Int

    /// OSRM /match 的 radiuses（= GPS 标准差）：专用记录仪 15 m；手机按精度 2× 钳在 20–30 m
    ///（FOSSGIS 对 50 m 回 TooBig；实测 Garmin 真值上 15 m 最准，30 m 在突发稀疏上下文下偶有偏差）
    var matchRadius: Double {
        switch kind {
        case .deviceLogger: return 15
        case .phone, .unknown: return min(30, max(20, (accuracy ?? 15) * 2))
        }
    }
    /// 上下文锚点离 A/B 最远多少米：更远的点无法保证 A′→B′ 的最短路一定经过 A，
    /// 稀疏数据（前一个点在 1–2 km 外）就不用上下文，交给地图匹配
    var contextCap: Double { 600 }
    /// 地图匹配的前后点可以跨过别的断档，但离锚点不超过这个距离（匹配按时间戳自己判断可达性）
    var matchReach: Double { 5000 }
    /// 地图匹配每侧至少覆盖这么远（米）就不再多取点；点数上限 4（FOSSGIS 共 ≤10 点）
    var matchBudget: Double { 300 }
    /// 上下文、方向、局部采样间隔只看离锚点这么多秒以内的点（原上限是 60/40 个点，在 1 Hz 下约 1 分钟，
    /// 手机采样上就没有这层含义了；Garmin 实测最远用到 400 s，600 s 时 0 变化）
    var contextMaxSeconds: Double { 600 }
    /// 方向弦长上限：R=500 m 的弯上 300 m 弦切角 ≤17°，600 m 弦约 37°，加噪声会超出 OSRM ±45°
    var headingChordMax: Double { 300 }

    var kindLabel: String {
        switch kind {
        case .deviceLogger: return String(localized: "专用记录仪", comment: "Sampling profile source kind: dedicated GPS logger (Garmin etc.). Shown inside the sampling summary line (采样 … · 中位 …)")
        case .phone: return String(localized: "手机", comment: "Sampling profile source kind: phone app recording. Shown inside the sampling summary line")
        case .unknown: return String(localized: "未知来源", comment: "Sampling profile source kind: unknown source. Shown inside the sampling summary line")
        }
    }
    /// 一行摘要，给操作条/批量窗口显示
    var summary: String {
        var parts: [String] = []
        if q90Step > 3 * medianStep {
            parts.append(String(localized: "采样 \(kindLabel) · 中位 \(medianDt, format: Fmt.f0) s / \(medianStep, format: Fmt.f0) m（稀疏时 \(q90Step, format: Fmt.f0) m）",
                                comment: "Sampling profile summary (fill panel, batch window). 1 source kind (dedicated logger/phone/unknown), 2 median seconds between moving samples, 3 median metres per moving step, 4 90th-percentile step length in metres (track is sparse at times)"))
        } else {
            parts.append(String(localized: "采样 \(kindLabel) · 中位 \(medianDt, format: Fmt.f0) s / \(medianStep, format: Fmt.f0) m",
                                comment: "Sampling profile summary (fill panel, batch window). 1 source kind (dedicated logger/phone/unknown), 2 median seconds between moving samples, 3 median metres per moving step"))
        }
        if let accuracy { parts.append(String(localized: "精度 \(accuracy, format: Fmt.f0) m", comment: "Sampling profile summary clause: median GPS accuracy in metres from the CSV accuracy column")) }
        if !creator.isEmpty { parts.append(creator) }
        return parts.joined(separator: " · ")
    }
    /// 换算出来的门槛，给用户看
    var derivedSummary: String {
        let reachKm = matchReach / 1000
        let stale = kind == .deviceLogger
            ? String(localized: "过时时钟检测开", comment: "Derived gap-fill threshold clause: stale-clock detection (Garmin stale timestamps after signal loss) is ON")
            : String(localized: "过时时钟检测关", comment: "Derived gap-fill threshold clause: stale-clock detection is OFF")
        return [String(localized: "匹配半径 \(matchRadius, format: Fmt.f0) m", comment: "Derived gap-fill threshold clause: OSRM map-matching radius in metres"),
                stale,
                String(localized: "上下文只取 \(contextCap, format: Fmt.f0) m、\(contextMaxSeconds, format: Fmt.f0) s 内的点", comment: "Derived gap-fill threshold clause: context anchor points are only taken within 1 = metres and 2 = seconds of the gap anchor"),
                String(localized: "方向弦长 25–\(headingChordMax, format: Fmt.f0) m", comment: "Derived gap-fill threshold clause: chord length used to estimate travel direction, from 25 m up to the given metres"),
                String(localized: "匹配前后点最远 \(reachKm, format: Fmt.f1) km / 180 s", comment: "Derived gap-fill threshold clause: points before/after the gap used for map matching are at most this many km / 180 s away")
        ].joined(separator: " · ")
    }

    /// 均匀抽 ≤100k 个相邻点对统计（O(n)）；只算移动步
    static func compute(track: TrackData, creator: String, accuracy: Double?) -> SamplingProfile {
        let n = track.timedCount
        var dts: [Double] = [], ds: [Double] = []
        if n >= 2 {
            let stride = max(1, (n - 1) / 100_000)
            dts.reserveCapacity(min(n, 100_000)); ds.reserveCapacity(min(n, 100_000))
            var i = 1
            while i < n {
                let dt = track.time[i] - track.time[i - 1]
                if dt > 0 {
                    let d = GeoMath.haversine(track.lat[i - 1], track.lon[i - 1], track.lat[i], track.lon[i])
                    if d / dt > 1 { dts.append(dt); ds.append(d) }
                }
                i += stride
            }
        }
        dts.sort(); ds.sort()
        func q(_ a: [Double], _ p: Double, _ fallback: Double) -> Double {
            a.isEmpty ? fallback : a[min(a.count - 1, Int(Double(a.count) * p))]
        }
        let mdt = q(dts, 0.5, 1), q90dt = q(dts, 0.9, mdt)
        let mst = q(ds, 0.5, 30), q90st = q(ds, 0.9, mst)
        let lc = creator.lowercased()
        let deviceCreator = lc.contains("garmin") || lc.contains("etrex") || lc.contains("wahoo") || lc.contains("suunto")
        let phoneCreator = lc.contains("stepofmyworld") || lc.contains("一生足迹") || lc.contains("fog") || lc.contains("iphone") || lc.contains("android")
        let steady = !dts.isEmpty && mdt <= 2 && q90dt <= 2 * mdt + 1 && q90st <= 3 * mst
        let kind: Kind
        if deviceCreator, accuracy == nil {
            kind = .deviceLogger
        } else if deviceCreator {
            kind = steady ? .deviceLogger : .phone   // Garmin GPX 与手机 CSV 混合载入：按数据规律判
        } else if accuracy != nil || phoneCreator {
            kind = .phone
        } else if steady {
            kind = .deviceLogger          // 没有来源信息但步时步长都很整齐：按专用记录仪
        } else {
            kind = dts.isEmpty ? .unknown : .phone
        }
        return SamplingProfile(kind: kind, creator: creator, medianDt: mdt, q90Dt: q90dt, medianStep: mst, q90Step: q90st,
                               accuracy: accuracy, sampleCount: dts.count)
    }
}

enum GapDetector {
    struct Options {
        var minMeters = 150.0
        var minSeconds = 20.0           // timeGap 的最短时间空洞
        var maxSeconds = 3600.0
        var minKmh = 15.0
        var maxKmh = 350.0
        /// staleClock 分支是 Garmin 固件的现象（复锁后几个点带过时时间戳）；手机上不存在，按采样画像关掉
        var staleEnabled = true
        var staleWindow = 20            // staleClock：空间跳变后在多少点内找时间跳变（Garmin 实测过时点 3–8 个）
        var staleMinJump = 5.0          // 时间跳变至少多少秒（绝对下限；还要 ≥4× 局部采样间隔、≥ 半个断档时长）
        /// 「微型」staleClock 入口（跳变 < minMeters、dt < minSeconds、隐含速度 > maxKmh）用的时间跳变下限。
        /// 实测 Muenchen_Roma_Garmin：1 s 跳 106–146 m、再 4–5 s 回正的 100 m 级短隧道 6 处，卡在 150 m 与 5 s 两道门槛上
        var staleMicroMinJump = 4.0
        /// 乱跳簇检测（见 GapDetector.detectJitter）
        var jitterEnabled = true
        var jitterMinJump = 300.0       // 大跳的绝对下限（米）；实际门槛 = max(此值, 2.5×参照速度×步时 + 4×局部步长）
        var jitterMinReversal = 200.0   // 倒退的绝对下限（米）；实际门槛 = max(此值, 3×局部步长, 步时²）
        var jitterSettleSeconds = 20.0  // 簇结束：之后连续这么久步步合理
        var jitterSettleCount = 4
        var jitterMaxClusterSeconds = 1800.0   // 20 分钟连续乒乒球也要能成一簇（并簇上限同为 30 min）
        var jitterMergeSeconds = 90.0   // 相隔这么近的簇并成一处（Garmin Explore 回放的半周期约 75 s）
        var jitterWindowSeconds = 60.0  // 参照统计量的窗口
    }

    /// 隧道群合并：相邻两处断档之间的露天段只有 ≤maxOpenPoints 个点（含两端锚点，共用一点时为 1）且 ≤maxOpenSeconds 时并成一处。
    /// 实测：一生足迹 4493 处断档里 2986 处成群，群之间中位只有 1 个点、离路几百米（手机在隧道里给的网络定位）；
    /// Garmin 群之间是 17–30 个贴路的真实点，按点数门槛不会并。并后的区间仍可按正常流程取路网、外推锚点、落地替换
    /// canMerge：两处都得是「信号中断」才并——采样稀疏（手机后台每 20–30 s 一个真实点）的连续步也满足"露天 1 点"，
    /// 并起来会把真实点当假点删掉；TrackStore 按 LocalSampling.nature 传入
    static func mergeChains(_ cands: [GapCandidate], maxOpenPoints: Int = 3, maxOpenSeconds: Double = 90,
                            canMerge: (GapCandidate, GapCandidate) -> Bool = { _, _ in true }) -> [GapCandidate] {
        let sorted = cands.sorted { $0.indexA < $1.indexA }
        var out: [GapCandidate] = []
        var cur: GapCandidate? = nil
        for c in sorted {
            guard let p = cur else { cur = c; continue }
            let openPts = c.indexA - p.indexB + 1, dt = c.tA - p.tB
            if c.indexA >= p.indexB, openPts <= maxOpenPoints, dt >= 0, dt <= maxOpenSeconds, canMerge(p, c) {
                let kind: GapCandidate.Kind = (p.kind == .jitter || c.kind == .jitter) ? .jitter
                    : ((p.kind == .staleClock && c.kind == .staleClock) ? .staleClock : .timeGap)
                var m = GapCandidate(kind: kind,
                                     indexA: p.indexA, indexB: c.indexB, tA: p.tA, tB: c.tB,
                                     latA: p.latA, lonA: p.lonA, latB: c.latB, lonB: c.lonB,
                                     meters: GeoMath.haversine(p.latA, p.lonA, c.latB, c.lonB),
                                     speedInKmh: p.speedInKmh, speedOutKmh: c.speedOutKmh,
                                     windowSpeedInKmh: p.windowSpeedInKmh, windowSpeedOutKmh: c.windowSpeedOutKmh)
                m.chainCount = p.chainCount + c.chainCount
                m.frozenA = p.frozenA            // 并后的 A 就是前一处的 A
                m.jitterJumps = p.jitterJumps + c.jitterJumps
                m.jitterReversals = p.jitterReversals + c.jitterReversals
                m.jitterMaxJump = max(p.jitterMaxJump, c.jitterMaxJump)
                cur = m
            } else {
                out.append(p); cur = c
            }
        }
        if let p = cur { out.append(p) }
        return out
    }

    /// 只扫有效时间区间 [0, timedCount)。先按时间差/距离粗筛（便宜），再算距离与速度
    static func detect(track: TrackData, options o: Options = Options()) -> [GapCandidate] {
        let n = track.timedCount
        guard n >= 2 else { return [] }
        var out: [GapCandidate] = []
        track.time.withUnsafeBufferPointer { t in
        track.lat.withUnsafeBufferPointer { la in
        track.lon.withUnsafeBufferPointer { lo in
        track.speedKmh.withUnsafeBufferPointer { sp in
            func speed(_ i: Int) -> Double { i >= 1 && i < sp.count ? sp[i] : 0 }
            // 窗口速度（见 GapCandidate.windowSpeedInKmh）
            func windowSpeed(_ idx: Int, forward: Bool) -> Double? {
                var k = idx
                for _ in 0..<GapDetector.windowMaxSteps {
                    let prev = k
                    k += forward ? 1 : -1
                    guard k >= 0, k < n else { return nil }
                    let sdt = abs(t[k] - t[prev]), sd = GeoMath.haversine(la[prev], lo[prev], la[k], lo[k])
                    if GapDetector.isBreakStep(dt: sdt, meters: sd) { return nil }
                    let dtA = abs(t[k] - t[idx])
                    if dtA > GapDetector.windowMaxSeconds { return nil }
                    let dA = GeoMath.haversine(la[idx], lo[idx], la[k], lo[k])
                    // 至少跨 2 步：只跨 1 步时窗口速度就等于单步速度，对孤立跳点没有过滤作用
                    if abs(k - idx) >= 2, dtA > 0, dtA >= GapDetector.windowMinSeconds || dA >= GapDetector.windowMinMeters {
                        let v = dA / dtA * 3.6
                        return v <= GapDetector.breakOptions.maxKmh ? v : nil     // 同秒点会让窗口速度虚高：不可信
                    }
                }
                return nil
            }
            var i = 1
            while i < n {
                let dt = t[i] - t[i - 1]
                let d = GeoMath.haversine(la[i - 1], lo[i - 1], la[i], lo[i])
                // 微型过时时钟入口：跳变不到 minMeters，但 dt<20 s 且隐含速度超上限（实际门槛见下面 stale 分支里的 gate）
                let microEntry = d < o.minMeters && o.staleEnabled && dt > 0 && dt < o.minSeconds && d / dt * 3.6 > o.maxKmh
                if d >= o.minMeters || microEntry {
                    let kmh = dt > 0 ? d / dt * 3.6 : .infinity
                    if dt >= o.minSeconds {
                        // 时间空洞
                        if dt <= o.maxSeconds, kmh >= o.minKmh, kmh <= o.maxKmh {
                            out.append(GapCandidate(kind: .timeGap, indexA: i - 1, indexB: i,
                                                    tA: t[i - 1], tB: t[i],
                                                    latA: la[i - 1], lonA: lo[i - 1], latB: la[i], lonB: lo[i],
                                                    meters: d, speedInKmh: speed(i - 1), speedOutKmh: speed(i + 1),
                                                    windowSpeedInKmh: windowSpeed(i - 1, forward: false), windowSpeedOutKmh: windowSpeed(i, forward: true)))
                        }
                    } else if kmh > o.maxKmh, o.staleEnabled {
                        // 时钟未推进的空间跳变：向后找第一个使 A→B 速度合理的时间跳变
                        //（≥ staleMinJump；不用窗内最大者——那可能是更远处的一次停车）
                        let a = i - 1
                        var bestK = -1
                        var dAB = 0.0, span = 0.0, v = Double.infinity
                        let end = min(n - 1, i + o.staleWindow)
                        // 入口前的局部采样间隔（≤12 步中位数）：时钟"回正"那一步必须明显大于正常步时，
                        // 否则手机 3–7 s 的普通采样步会被当成回正（一生足迹 2026 全年数据实测 286 处误报、
                        // 涉及 6426 个真实点；加这一门槛后约 10–13 处，Garmin 101 处全部保留；
                        // App 里手机数据由采样画像把 staleEnabled 关掉，实际为 0）
                        var dtsBefore: [Double] = [], dsBefore: [Double] = []
                        var kb = a
                        while kb >= 1, dtsBefore.count < 12 {
                            dtsBefore.append(t[kb] - t[kb - 1])
                            dsBefore.append(GeoMath.haversine(la[kb - 1], lo[kb - 1], la[kb], lo[kb]))
                            kb -= 1
                        }
                        dtsBefore.sort(); dsBefore.sort()
                        let localDtBefore = dtsBefore.isEmpty ? 1.0 : dtsBefore[dtsBefore.count / 2]
                        let localStepMeters = dsBefore.isEmpty ? 30.0 : dsBefore[dsBefore.count / 2]
                        // 按入口类型取门槛：老入口（d ≥ minMeters）参数不变；微型入口用
                        // 距离门槛 gate = max(60, 3.5× 局部步长)（入口跳变与 A→B 距离共用）、时钟回正 ≥4 s、上下文 ≥3.5× 典型步长。
                        // 在 Muenchen_Roma_Garmin 上正好多收 6 处 1 s 跳 106–146 m 的短隧道；Inntal 那几个 83 m 的量化抖动步
                        // 后面没有 ≥4 s 的回正，不会被收
                        let gate = microEntry ? max(60.0, 3.5 * localStepMeters) : o.minMeters
                        let minJump = microEntry ? o.staleMicroMinJump : o.staleMinJump
                        let ctxK = microEntry ? 3.5 : 5.0
                        if microEntry, d < gate { i += 1; continue }
                        var k = i
                        while k < end {
                            let ddt = t[k + 1] - t[k]
                            if ddt >= minJump {
                                let b = k + 1
                                // 出口后的局部采样间隔，与入口前合并取中位
                                var dts = dtsBefore
                                var ka = b + 1
                                while ka < n, dts.count < dtsBefore.count + 12 { dts.append(t[ka] - t[ka - 1]); ka += 1 }
                                dts.sort()
                                let localDt = dts.isEmpty ? localDtBefore : dts[dts.count / 2]
                                let dd = GeoMath.haversine(la[a], lo[a], la[b], lo[b])
                                let sp = t[b] - t[a]
                                let vv = sp > 0 ? dd / sp * 3.6 : .infinity
                                // 回正量 ≥4× 局部步时，且至少占断档时长的 35%（过时点段本身只有几秒；
                                // 0.5 在 Garmin 最短隧道上只剩 1 s 余量，0.35 时手机误报 10→13，可接受）
                                if ddt >= 4 * localDt, ddt >= 0.35 * sp,
                                   dd >= gate, vv >= o.minKmh, vv <= o.maxKmh {
                                    bestK = b; dAB = dd; span = sp; v = vv
                                    // 时钟可能分几次回正（实测 Garmin 3.2 km 隧道：+46 s 之后又 +68 s）。第一次回正算出的
                                    // 隐含速度（225 km/h）明显高于前后记录速度（100）时，说明时间还没全回正：
                                    // 继续在窗内找后面的回正步，直到隐含速度与前后记录速度相称
                                    // 参照速度：A 前 / B 后各 6 步的最大记录速度（城里慢行时不能拿 13 km/h 当参照），下限 60
                                    func refSpeed(_ a: Int, _ b: Int) -> Double {
                                        var r = 60.0
                                        var k3 = max(1, a - 5); while k3 <= a { r = max(r, speed(k3)); k3 += 1 }
                                        k3 = b + 1; while k3 <= min(n - 1, b + 6) { r = max(r, speed(k3)); k3 += 1 }
                                        return r
                                    }
                                    if vv > 1.5 * refSpeed(a, b) + 20 {
                                        var k2 = b
                                        while k2 < end {
                                            // 中间又出现一次空间跳变（≥5× 典型步长）= 另一条隧道的过时段开始：不能并成一处
                                            let stepD = GeoMath.haversine(la[k2], lo[k2], la[k2 + 1], lo[k2 + 1])
                                            if stepD >= 5 * max(10.0, localStepMeters) { break }
                                            let ddt2 = t[k2 + 1] - t[k2]
                                            if ddt2 >= max(minJump, 4 * localDt) {
                                                let b2 = k2 + 1
                                                let dd2 = GeoMath.haversine(la[a], lo[a], la[b2], lo[b2])
                                                let sp2 = t[b2] - t[a]
                                                let vv2 = sp2 > 0 ? dd2 / sp2 * 3.6 : .infinity
                                                if vv2 >= o.minKmh, vv2 <= o.maxKmh {
                                                    bestK = b2; dAB = dd2; span = sp2; v = vv2
                                                    if vv2 <= 1.5 * refSpeed(a, b2) + 20 { break }   // 已相称
                                                }
                                            }
                                            k2 += 1
                                        }
                                    }
                                    break
                                }
                            }
                            k += 1
                        }
                        // 上下文：跳变距离必须远大于前后的常规步长（≥5×）。飞机/高铁按 1Hz 记录
                        // 每步也有几百米，但步步如此；隧道跳变是孤立的
                        var typical = 10.0
                        if bestK > 0 {
                            let b = bestK
                            var ctx: [Double] = []
                            var k3 = max(1, a - 10)
                            while k3 <= a { ctx.append(GeoMath.haversine(la[k3 - 1], lo[k3 - 1], la[k3], lo[k3])); k3 += 1 }
                            k3 = b + 1
                            while k3 <= min(n - 1, b + 10) { ctx.append(GeoMath.haversine(la[k3 - 1], lo[k3 - 1], la[k3], lo[k3])); k3 += 1 }
                            ctx.sort()
                            typical = ctx.isEmpty ? 10.0 : max(10.0, ctx[ctx.count / 2])
                            if d < ctxK * typical { bestK = -1 }
                        }
                        if bestK > 0 {
                            let b = bestK
                            // GPS 多径毛刺是"跳出去又跳回来"：跳变之后到 B 若有点回到
                            // 入口 A 附近就不是隧道。"附近"按局部步长放大（3×，100–400 m）：
                            // 手机 75 m 一个点时毛刺之后的第一个真实点离 A 已有一两步。
                            // 隧道群（失锁-复锁-再失锁，时钟只回正一次）则一路远离 A，归为一个候选
                            let returnRadius = min(400.0, max(100.0, 3 * typical))
                            var returned = false
                            var k2 = i
                            while k2 <= b {
                                if GeoMath.haversine(la[a], lo[a], la[k2], lo[k2]) < returnRadius { returned = true; break }
                                k2 += 1
                            }
                            if !returned, dAB >= gate, span <= o.maxSeconds, v >= o.minKmh, v <= o.maxKmh {
                                out.append(GapCandidate(kind: .staleClock, indexA: a, indexB: b,
                                                        tA: t[a], tB: t[b],
                                                        latA: la[a], lonA: lo[a], latB: la[b], lonB: lo[b],
                                                        meters: dAB, speedInKmh: speed(a), speedOutKmh: speed(b + 1),
                                                        windowSpeedInKmh: windowSpeed(a, forward: false), windowSpeedOutKmh: windowSpeed(b, forward: true)))
                                i = b            // 跳过已归入本候选的过时点
                            }
                        }
                    }
                }
                i += 1
            }
        }}}}
        return out
    }
}

// MARK: - A 侧冻结假点链

extension GapDetector {
    /// Garmin 进隧道失锁后不会立刻停记，而是按最后的航向/步长再外推几个点（实测第 14 处 9729–9732：4 步航向差 0、
    /// 步长差 <0.1 m，一路偏出隧道轴线到 12 m）。这几个点被当成 A 侧真实点，A 就落在了路外。
    /// 判别：这台设备在高速直路上定速巡航时真实点同样「冻」（全文件 1983 段），单看锁死没有判别力；有判别力的是「掐弯」——
    /// 锁死之前 5 步内道路还在转（|Δ航向| ≥1°/s），锁死段突然一点不转。规则只在断档锚点 A 处生效：
    /// - 前提：A 往前 9 步都 dt=1，且 A−1 步长 20–80 m；
    /// - 从步 A−1 往回数相邻航向差 ≤angleTol、步长差 ≤stepTol 的连续正常步（dt=1、0.5–80 m），链长 n ∈ [3, 6]
    ///  （更长当真实直路，如 23756 的 12 步）；
    /// - 链起点 s = A−n 之前 6 步都正常，且其中后 5 步的最大 |Δ航向| ≥ minPreTurn。
    /// 命中则 A 前移 n 点（frozenA = n）。B 侧不做：B 后冻结步数全部 ≤1，是滤波器重新收敛。
    /// 只对专用记录仪画像的 staleClock 候选；Muenchen_Roma_Garmin 原 44 处命中 12 处，随机巧合期望 0.7 处
    static func shiftFrozenChains(track: TrackData, candidates: [GapCandidate], profile: SamplingProfile,
                                  angleTol: Double = 0.2, stepTol: Double = 0.2, minPreTurn: Double = 1.0) -> [GapCandidate] {
        guard profile.kind == .deviceLogger else { return candidates }
        let n = track.timedCount
        // 步 i = 点 i→i+1
        func len(_ i: Int) -> Double { GeoMath.haversine(track.lat[i], track.lon[i], track.lat[i + 1], track.lon[i + 1]) }
        func brg(_ i: Int) -> Double { GeoMath.bearing(track.lat[i], track.lon[i], track.lat[i + 1], track.lon[i + 1]) }
        func dt1(_ i: Int) -> Bool { abs(track.time[i + 1] - track.time[i] - 1) < 1e-3 }
        func ok(_ i: Int) -> Bool { guard i >= 0, i + 1 < n, dt1(i) else { return false }; let l = len(i); return l >= 0.5 && l < 80 }
        func turn(_ a: Double, _ b: Double) -> Double { abs((b - a + 540).truncatingRemainder(dividingBy: 360) - 180) }
        func frozenCount(_ a: Int) -> Int {
            guard a >= 9, a < n else { return 0 }
            for k in 1...9 where !dt1(a - k) { return 0 }
            let l1 = len(a - 1)
            guard l1 >= 20, l1 < 80, ok(a - 1) else { return 0 }
            var c = 1, k = a - 1
            while k - 1 >= 0, ok(k - 1), turn(brg(k - 1), brg(k)) <= angleTol, abs(len(k - 1) - len(k)) <= stepTol {
                c += 1; k -= 1
                if c > 6 { return 0 }          // 更长的锁死段 = 真实直路
            }
            guard c >= 3 else { return 0 }
            let s = a - c
            guard s - 6 >= 0 else { return 0 }
            for i in (s - 6)..<s where !ok(i) { return 0 }
            var preMax = 0.0
            for i in (s - 5)..<s { preMax = max(preMax, turn(brg(i - 1), brg(i))) }
            return preMax >= minPreTurn ? c : 0
        }
        var out: [GapCandidate] = []
        out.reserveCapacity(candidates.count)
        for c in candidates {
            let f = c.kind == .staleClock && c.frozenA == 0 ? frozenCount(c.indexA) : 0
            let a = c.indexA - f
            // 前移后不能越过前一处的 B（正常不会：链与链前 6 步都是 dt=1 的正常步，B 前一步是时钟回正）
            guard f > 0, out.last.map({ $0.indexB <= a }) ?? true else { out.append(c); continue }
            var m = GapCandidate(kind: c.kind, indexA: a, indexB: c.indexB, tA: track.time[a], tB: c.tB,
                                 latA: track.lat[a], lonA: track.lon[a], latB: c.latB, lonB: c.lonB,
                                 meters: GeoMath.haversine(track.lat[a], track.lon[a], c.latB, c.lonB),
                                 speedInKmh: a >= 1 && a < track.speedKmh.count ? track.speedKmh[a] : 0, speedOutKmh: c.speedOutKmh,
                                 windowSpeedInKmh: windowSpeed(track: track, idx: a, forward: false), windowSpeedOutKmh: c.windowSpeedOutKmh)
            m.chainCount = c.chainCount
            m.jitterJumps = c.jitterJumps; m.jitterReversals = c.jitterReversals; m.jitterMaxJump = c.jitterMaxJump
            m.frozenA = f
            out.append(m)
        }
        return out
    }
}

// MARK: - 乱跳：回放点与乱跳簇

extension GapDetector {
    /// 经度差折到 (-180, 180]：跨日界线（179.9 → -179.9）在平面近似里不能算成绕地球一圈
    @inline(__always) static func wrapLon(_ d: Double) -> Double {
        var x = d.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 } else if x <= -180 { x += 360 }
        return x
    }
    /// 回放点：坐标与 10 s–30 min 前某个点**位级相同**，期间轨迹离开过 ≥300 m，且这个点本身处在移动中（与约 10 s 前的点相距 ≥50 m）。
    /// 真 GPS 在移动中不会给出一字不差的坐标；手机 / Garmin Explore 在车厢里没信号时会把存过的旧位置来回回放
    ///（实测 RE1 Koblenz–Trier 9638 点里 1976 个移动中的回放点；一生足迹 2026 全年 11.8 万点里 1.6 万个，全在坐火车的日子；
    /// Garmin 专用记录仪 0 个）。静止时反复写同一缓存位置不算（邻点不动）。
    /// O(n)：字典只留最近 30 min 内出现过的坐标；每个坐标记"最近一次相隔 ≥10 s 的出现"，同秒重复不覆盖
    static func replayFlags(track: TrackData, minSeconds: Double = 10, maxSeconds: Double = 1800,
                            awayMeters: Double = 300, movingMeters: Double = 50) -> [Bool] {
        let n = track.timedCount
        var flags = [Bool](repeating: false, count: track.count)
        guard n >= 3 else { return flags }
        struct Key: Hashable { let la: UInt64, lo: UInt64 }
        track.time.withUnsafeBufferPointer { t in
        track.lat.withUnsafeBufferPointer { la in
        track.lon.withUnsafeBufferPointer { lo in
            func key(_ i: Int) -> Key { Key(la: la[i].bitPattern, lo: lo[i].bitPattern) }
            // 不动点迭代：每一轮把上一轮判为回放的点当作不存在（不进字典、不做邻点参照、不算"离开过"），
            // 直到没有新增——这样"删掉回放点再检测"得到空集（幂等）。一般两轮收敛
            for _ in 0..<4 {
                let prev = flags
                var next = prev
                var changed = false
                var last: [Key: Int] = [:]
                var order: [Int] = []          // 进入字典的顺序（下标），按时间淘汰
                var head = 0
                for i in 0..<n where !prev[i] {
                    // 淘汰 30 min 以前进入的坐标（字典里记的仍是那一次出现时才删）
                    while head < order.count, t[i] - t[order[head]] > maxSeconds {
                        let k = order[head]
                        if last[key(k)] == k { last[key(k)] = nil }
                        head += 1
                    }
                    if head > 65_536 { order.removeFirst(head); head = 0 }
                    let kk = key(i)
                    var isReplay = false
                    if let j = last[kk] {
                        let dt = t[i] - t[j]
                        if dt < minSeconds { continue }           // 同秒/紧邻的重复：不覆盖，留着更早那次
                        // "移动中"：约 10 s 前、约 30 s 后的（非回放）点都离这里 ≥50 m。
                        // 只看前一点不行（回放扫一趟 4 Hz 相邻点只隔 10–40 m）；只看前面也不行——静止的手机
                        // 从一次外飘回到缓存位置后，后面的点都还在原地，它们是真位置不是回放（否则会一路级联误判）。
                        // 往后看 30 s 而不是 10 s：回放扫段掉头处 10 s 后会扫回同一位置附近
                        var k = i - 1, steps = 0
                        while k > 0, prev[k] || t[i] - t[k] < minSeconds, steps < 256 { k -= 1; steps += 1 }
                        var f = min(i + 1, n - 1); steps = 0
                        while f < n - 1, prev[f] || t[f] - t[i] < 3 * minSeconds, steps < 1024 { f += 1; steps += 1 }
                        let backFar = GeoMath.haversine(la[k], lo[k], la[i], lo[i]) >= movingMeters
                        // 末尾没有"之后的点"（f 落回 i 自己）时只看前面
                        let fwdFar = f <= i || GeoMath.haversine(la[f], lo[f], la[i], lo[i]) >= movingMeters
                        if backFar && fwdFar {
                            let stride = max(1, (i - j) / 60)
                            var m = j + 1, away = false
                            while m < i { if !prev[m], GeoMath.haversine(la[i], lo[i], la[m], lo[m]) >= awayMeters { away = true; break }; m += stride }
                            if away { isReplay = true }
                        }
                    }
                    if isReplay { next[i] = true; changed = true } else { last[kk] = i; order.append(i) }
                }
                flags = next
                if !changed { break }
            }
            // 孤立的重复不算回放：回放扫段一分钟内有几十个重复点，而量化坐标（手机 5 位小数）下真实来回路线
            // 偶然撞上同一坐标是零星的。±60 s 内（含自己）不足 3 个标记就撤掉
            var prefix = [Int](repeating: 0, count: n + 1)
            for i in 0..<n { prefix[i + 1] = prefix[i] + (flags[i] ? 1 : 0) }
            var lo = 0, hi = 0
            for i in 0..<n where flags[i] {
                while lo < i, t[i] - t[lo] > 60 { lo += 1 }
                while hi < n, t[hi] - t[i] <= 60 { hi += 1 }
                if prefix[hi] - prefix[lo] < 3 { flags[i] = false }
            }
        }}}
        return flags
    }

    /// 时间戳相同的一组点（Garmin Explore 每秒最多写 4 个、时间只到秒）合成一个样本：中位坐标，首末下标
    struct JitterSample {
        var t: Double
        var lat: Double
        var lon: Double
        var first: Int
        var last: Int
        /// 与上一组之间原始点（含被跳过的回放点）的最大时间间隔：判"时间空洞"用它，不能用两组样本的时间差——
        /// 回放点被跳过后两组样本可能隔几十秒，但原始记录其实是连续的
        var gapBefore: Double = 0
    }

    /// 乱跳簇：从"已接受"的最近 60 s 轨迹取参照（局部步长、参照速度、行进方向），逐步判「大跳」（远超该速度与噪声能走出的距离）
    /// 和「倒退」（相对行进方向后退几百米——任何车都做不到在几秒内倒回去），进簇后直到后面出现 ≥20 s 步步合理、
    /// 弦速不超过参照上限的稳定段才结束；簇里的点全是乱跳点。回放点（replay）在扫描时跳过，但落在簇区间里的也随区间删。
    /// 单秒瞬时速度不能当判据：Garmin Explore 时间戳成批冲刷，1 Hz 噪声里单秒速度常达 200–700 km/h。
    /// 输出的 A 是簇前最后一个真实点、B 是稳定段第一个点（都用原始点而非中位坐标）
    static func detectJitter(track: TrackData, profile: SamplingProfile?, replay: [Bool]?, options o: Options = Options(),
                             trace: ((Double, String) -> Void)? = nil) -> [GapCandidate] {
        let n = track.timedCount
        guard o.jitterEnabled, n >= 8 else { return [] }
        let profStep = max(10.0, profile?.medianStep ?? 30), profDt = max(1.0, profile?.medianDt ?? 1)
        let time = track.time, lat = track.lat, lon = track.lon
        func hav(_ a: JitterSample, _ b: JitterSample) -> Double { GeoMath.haversine(a.lat, a.lon, b.lat, b.lon) }
        /// 从点 i 起的下一组（同一整秒内、非回放）→ 样本；i 推进到组后。
        /// 解析时同秒重复点会被摊成 0.25 s 的小增量以保持严格递增，所以按整秒分组而不是按相等
        func sample(from i: inout Int) -> JitterSample? {
            let startCursor = i
            while i < n, replay?[i] == true { i += 1 }
            guard i < n else { return nil }
            var gap = 0.0
            var g = max(1, startCursor)
            while g <= i { gap = max(gap, time[g] - time[g - 1]); g += 1 }
            let t = time[i], sec = floor(t)
            var las: [Double] = [], los: [Double] = []
            var first = i, last = i
            while i < n, floor(time[i]) == sec {
                if replay?[i] != true { las.append(lat[i]); los.append(lon[i]); last = i }
                i += 1
            }
            if las.count > 2 { las.sort(); los.sort() }
            let mid = las.count / 2
            let cla = las.count % 2 == 1 ? las[mid] : (las[mid - 1] + las[mid]) / 2
            let clo = los.count % 2 == 1 ? los[mid] : (los[mid - 1] + los[mid]) / 2
            return JitterSample(t: t, lat: cla, lon: clo, first: first, last: last, gapBefore: gap)
        }
        struct Stats { var mLoc: Double; var vRef: Double; var heading: (x: Double, y: Double)?; var dtLoc: Double; var dur: Double }
        /// 参照统计量：局部步长 = 窗口步长均值去掉最大的一步；参照速度 = 窗口弦长/时长；方向 = 弦方向（弦长够长才算有）
        func stats(_ w: ArraySlice<JitterSample>) -> Stats {
            guard w.count >= 2, let f = w.first, let l = w.last else { return Stats(mLoc: profStep, vRef: profStep / profDt, heading: nil, dtLoc: profDt, dur: 0) }
            var sum = 0.0, mx = 0.0, cnt = 0
            var prev = f
            for q in w.dropFirst() { let d = hav(prev, q); sum += d; mx = max(mx, d); cnt += 1; prev = q }
            let mLoc = cnt >= 3 ? max(10.0, (sum - mx) / Double(cnt - 1)) : profStep
            let dur = l.t - f.t, chord = hav(f, l)
            let dtLoc = cnt >= 3 ? max(1.0, dur / Double(cnt)) : profDt
            let vRef = dur >= 10 ? chord / dur : mLoc / dtLoc
            var heading: (x: Double, y: Double)? = nil
            if chord >= max(100.0, 3 * mLoc), w.count >= 3, dur >= 5 {      // 两个样本一步噪声就能"定"方向：不算
                let kx = 111_320 * cos(l.lat * .pi / 180), ky = 110_540.0
                heading = (wrapLon(l.lon - f.lon) * kx, (l.lat - f.lat) * ky)
            }
            return Stats(mLoc: mLoc, vRef: vRef, heading: heading, dtLoc: dtLoc, dur: dur)
        }
        /// 一步是否大跳 / 倒退（时间空洞 ≥minSeconds 的步归断档检测，不算）
        func test(_ a: JitterSample, _ b: JitterSample, _ st: Stats) -> (jump: Bool, rev: Bool, d: Double) {
            let dt = b.t - a.t, d = hav(a, b)
            if dt >= o.minSeconds { return (false, false, d) }
            let jump = d > max(o.jitterMinJump, 2.5 * st.vRef * dt + 4 * st.mLoc)
            var rev = false
            if let h = st.heading {
                let kx = 111_320 * cos(a.lat * .pi / 180), ky = 110_540.0
                let sx = wrapLon(b.lon - a.lon) * kx, sy = (b.lat - a.lat) * ky
                let hn = (h.x * h.x + h.y * h.y).squareRoot()
                let proj = hn > 0 ? (sx * h.x + sy * h.y) / hn : 0
                // 倒退门槛随步时放宽：匀加速 a=2 m/s² 在 dt 秒内最多倒回 dt² 米
                rev = proj < -max(o.jitterMinReversal, 3 * st.mLoc, dt * dt)
            }
            return (jump, rev, d)
        }
        /// 从样本 q（点游标 cursor 已在 q 之后）起是否有稳定段：≥settle 秒、≥settleCount 个样本、步步合理、无倒退、弦速 ≤cap。
        /// pre = 进簇前的参照：稳定段的参照步长不能由它自己说了算（两点间来回跳时自身均值极大，步步都"合理"）
        func settled(_ q: JitterSample, cursor: Int, capKmh: Double, pre: Stats) -> Bool {
            var run = [q]
            var c = cursor
            while let s = sample(from: &c) {
                if s.gapBefore >= o.minSeconds { break }
                if s.t - q.t > o.jitterSettleSeconds + 5 { break }
                run.append(s)
            }
            guard run.count >= o.jitterSettleCount, run[run.count - 1].t - q.t >= o.jitterSettleSeconds else { return false }
            let dur = run[run.count - 1].t - q.t
            if hav(q, run[run.count - 1]) / dur * 3.6 > capKmh { return false }
            var st = stats(run[...])
            st.mLoc = min(st.mLoc, max(2 * pre.mLoc, 60))
            for k in 1..<run.count {
                let r = test(run[k - 1], run[k], st)
                if r.jump || r.rev { return false }
            }
            return true
        }

        struct Cluster { var a: JitterSample; var b: JitterSample; var jumps: Int; var revs: Int; var maxJump: Double; var path: Double }
        var clusters: [Cluster] = []
        var win: [JitterSample] = []
        var winHead = 0
        func pushWin(_ s: JitterSample) {
            win.append(s)
            while win.count - winHead > 2, s.t - win[winHead].t > o.jitterWindowSeconds { winHead += 1 }
            if winHead > 4096 { win.removeFirst(winHead); winHead = 0 }
        }
        func resetWin(_ s: JitterSample) { win = [s]; winHead = 0 }
        var holes: [Double] = []          // 时间空洞之后第一个样本的时刻（合并簇时不能跨过空洞）
        var i = 0
        guard let first = sample(from: &i) else { return [] }
        resetWin(first)
        while let s = sample(from: &i) {
            let prev = win[win.count - 1]
            if s.gapBefore >= o.minSeconds { holes.append(s.t); resetWin(s); continue }      // 时间空洞（按原始点间隔）：参照重置
            let st = stats(win[winHead...])
            let r = test(prev, s, st)
            if let trace { trace(s.t, String(format: "d=%.0f dt=%.0f mLoc=%.0f vRef=%.0f km/h head=%@ J=%.0f%@%@", r.d, s.t - prev.t, st.mLoc, st.vRef * 3.6, st.heading == nil ? "-" : "ok", max(o.jitterMinJump, 2.5 * st.vRef * (s.t - prev.t) + 4 * st.mLoc), r.jump ? " JUMP" : "", r.rev ? " REV" : "")) }
            if !(r.jump || r.rev) { pushWin(s); continue }
            // 进簇：A = 簇前最后一个接受的样本；簇内统计一律相对进簇前的参照。
            // 若 A 自己也是一步偏大的跳（略低于门槛混进窗口的离群点，紧接着的真实点才触发倒退），A 再退一个样本，把它算进簇
            var A = prev
            let capKmh = min(o.maxKmh, max(120.0, st.dur >= 10 ? 1.5 * st.vRef * 3.6 : o.maxKmh))
            var jumps = r.jump ? 1 : 0, revs = r.rev ? 1 : 0, maxJump = r.d, path = r.d
            if win.count - winHead >= 2 {
                let p2 = win[win.count - 2]
                let dp = hav(p2, prev), dtp = prev.t - p2.t
                if dtp < o.minSeconds, dp > max(0.5 * o.jitterMinJump, 1.5 * st.vRef * dtp + 3 * st.mLoc) {
                    A = p2; jumps += 1; path += dp; maxJump = max(maxJump, dp)
                }
            }
            var last = s
            var B: JitterSample? = nil
            var j = i
            while true {
                let before = j
                guard let q = sample(from: &j) else { break }
                if q.t - A.t > o.jitterMaxClusterSeconds { j = before; break }
                if q.gapBefore >= o.minSeconds { j = before; break }          // 簇里出现真正的时间空洞（原始点间隔）：放弃，交给断档检测
                if settled(q, cursor: j, capKmh: capKmh, pre: st) {
                    // 回到 B 的那一步也是簇的一部分（单个尖峰 = 跳出去 + 跳回来两步）
                    let rb = test(last, q, st)
                    if rb.jump { jumps += 1 }
                    if rb.rev { revs += 1 }
                    maxJump = max(maxJump, rb.d); path += rb.d
                    if let trace { trace(q.t, String(format: "  稳定段开始 → 簇 %@ 结束，cap %.0f", String(describing: A.t), capKmh)) }
                    B = q; break
                }
                let rq = test(last, q, st)
                if let trace { trace(q.t, String(format: "  簇内 d=%.0f dt=%.0f%@%@", rq.d, q.t - last.t, rq.jump ? " JUMP" : "", rq.rev ? " REV" : "")) }
                if rq.jump { jumps += 1 }
                if rq.rev { revs += 1 }
                maxJump = max(maxJump, rq.d); path += rq.d
                last = q
            }
            if let B {
                let chord = hav(A, B)
                if revs >= 1 || (jumps >= 2 && path >= 2 * chord) {
                    clusters.append(Cluster(a: A, b: B, jumps: jumps, revs: revs, maxJump: maxJump, path: path))
                }
                resetWin(B); i = j
            } else {
                // 没稳定下来（空洞 / 超时 / 到结尾）：放弃这簇；从放弃处往后找第一个稳定段起点再重新开始，
                // 不拿垃圾中间的某个样本当参照（最多再往后找 30 分钟）
                if j > i { i = j }
                var k = i, restarted = false
                while let nxt = sample(from: &k) {
                    if nxt.gapBefore >= o.minSeconds { holes.append(nxt.t) }
                    if settled(nxt, cursor: k, capKmh: o.maxKmh, pre: st) || nxt.t - A.t > 3 * o.jitterMaxClusterSeconds {
                        resetWin(nxt); i = k; restarted = true; break
                    }
                    last = nxt
                }
                if !restarted { break }
            }
        }
        // 相隔 ≤merge 秒的簇并成一处（簇间夹着的"稳定段"多半也是回放的一趟）
        var merged: [Cluster] = []
        for c in clusters {
            // 不跨时间空洞、并后总长 ≤30 min（更长的两路交替段分成几处各自处理）
            let holeBetween = holes.contains { $0 > (merged.last?.b.t ?? -1) && $0 <= c.a.t }
            if var m = merged.last, c.a.t - m.b.t <= o.jitterMergeSeconds, !holeBetween, c.b.t - m.a.t <= 1800 {
                m.b = c.b; m.jumps += c.jumps; m.revs += c.revs; m.maxJump = max(m.maxJump, c.maxJump); m.path += c.path
                merged[merged.count - 1] = m
            } else { merged.append(c) }
        }
        var out: [GapCandidate] = []
        out.reserveCapacity(merged.count)
        for c in merged {
            let ia = c.a.last, ib = c.b.first
            guard ib > ia, ib < n else { continue }
            var g = GapCandidate(kind: .jitter, indexA: ia, indexB: ib, tA: time[ia], tB: time[ib],
                                 latA: lat[ia], lonA: lon[ia], latB: lat[ib], lonB: lon[ib],
                                 meters: GeoMath.haversine(lat[ia], lon[ia], lat[ib], lon[ib]),
                                 speedInKmh: ia >= 1 ? track.speedKmh[ia] : 0, speedOutKmh: ib + 1 < track.speedKmh.count ? track.speedKmh[ib + 1] : 0,
                                 windowSpeedInKmh: windowSpeed(track: track, idx: ia, forward: false),
                                 windowSpeedOutKmh: windowSpeed(track: track, idx: ib, forward: true))
            g.jitterJumps = c.jumps; g.jitterReversals = c.revs; g.jitterMaxJump = c.maxJump
            out.append(g)
        }
        return out
    }

    /// 窗口速度（与 detect 内的同名闭包同口径），按下标单独算一处用
    static func windowSpeed(track: TrackData, idx: Int, forward: Bool) -> Double? {
        let n = track.timedCount
        var k = idx
        for _ in 0..<windowMaxSteps {
            let prev = k
            k += forward ? 1 : -1
            guard k >= 0, k < n else { return nil }
            let sdt = abs(track.time[k] - track.time[prev]), sd = GeoMath.haversine(track.lat[prev], track.lon[prev], track.lat[k], track.lon[k])
            if isBreakStep(dt: sdt, meters: sd) { return nil }
            let dtA = abs(track.time[k] - track.time[idx])
            if dtA > windowMaxSeconds { return nil }
            let dA = GeoMath.haversine(track.lat[idx], track.lon[idx], track.lat[k], track.lon[k])
            if abs(k - idx) >= 2, dtA > 0, dtA >= windowMinSeconds || dA >= windowMinMeters {
                let v = dA / dtA * 3.6
                return v <= breakOptions.maxKmh ? v : nil
            }
        }
        return nil
    }

    /// 乱跳簇只删点时仍保留的区间内点：沿 A→B 方向单调推进、相邻保留点之间车速不超过 cap 的最长子序列
    ///（两路定位交替时其中一路是真的；回放来回扫时第一趟是真的）。用 A→B 弦方向上的投影做"推进"度量，
    /// 允许 30 m 噪声回退；点数 >2000 时按步长抽样后再算；链上不足 2 点时不保留（整段删）
    static func monotonicChain(track: TrackData, ia: Int, ib: Int, capKmh: Double) -> Set<Int> {
        let n = ib - ia - 1
        guard n >= 2, ib < track.count else { return [] }
        // 点太多时按步长抽样再做 DP（O(n²) 封顶 2000 点），链上只留抽到的点——比"超限就全删"稳妥
        let stride = max(1, (n + 1999) / 2000)
        let kx = 111_320 * cos(track.lat[ia] * .pi / 180), ky = 110_540.0
        let bx = wrapLon(track.lon[ib] - track.lon[ia]) * kx, by = (track.lat[ib] - track.lat[ia]) * ky
        let bl = (bx * bx + by * by).squareRoot()
        guard bl > 1 else { return [] }
        let ux = bx / bl, uy = by / bl
        let cap = capKmh / 3.6
        func proj(_ k: Int) -> Double { (wrapLon(track.lon[k] - track.lon[ia]) * kx) * ux + ((track.lat[k] - track.lat[ia]) * ky) * uy }
        func ok(_ u: Int, _ v: Int) -> Bool {
            let dt = track.time[v] - track.time[u]
            let d = GeoMath.haversine(track.lat[u], track.lon[u], track.lat[v], track.lon[v])
            if dt <= 0 { return d <= 50 }
            return d / dt <= cap && proj(v) >= proj(u) - 30
        }
        // 最长链 DP：len[k] = 以 k 结尾、从 A 可达的最长链
        let idx = Swift.stride(from: ia + 1, to: ib, by: stride).map { $0 }
        let m = idx.count
        var len = [Int](repeating: 0, count: m), prevIdx = [Int](repeating: -1, count: m)
        var best = -1, bestLen = 0
        for q in 0..<m {
            let k = idx[q]
            let p = proj(k)
            guard p >= -200, p <= bl + 200, ok(ia, k) else { continue }
            len[q] = 1
            for r in 0..<q where len[r] > 0 && len[r] + 1 > len[q] && ok(idx[r], k) { len[q] = len[r] + 1; prevIdx[q] = r }
            if ok(k, ib), len[q] > bestLen { bestLen = len[q]; best = q }
        }
        guard bestLen >= 2 else { return [] }
        var keep = Set<Int>()
        var q = best
        while q >= 0 { keep.insert(idx[q]); q = prevIdx[q] }
        return keep
    }
}

/// 一段行程：按长停（≥10 min 在 150 m 内不动，或记录空白 ≥10 min）切分。公路/铁路按行程判比按单处断档判可靠：
/// 一趟火车的断档隐含速度 110–140 和高速公路重叠，但整趟的高速分位数（v95 ≥150）只有火车/小汽车能到，大巴到不了
struct Trip: Identifiable, Equatable {
    let index: Int
    let range: Range<Int>          // 轨迹下标 [start, end)
    let tStart: Double, tEnd: Double
    let km: Double
    let v50: Double, v95: Double   // 移动步速度分位数（km/h）
    var id: Int { index }
    /// 按速度分位数的自动判断：v95 ≥150 铁路（小汽车也可能，所以界面上给用户看一眼），≤115 公路，中间不确定
    var autoKind: BatchKind? { v95 >= 150 ? .rail : (v95 <= 115 ? .road : nil) }
    var speedReason: String {
        if v95 >= 150 {
            return String(localized: "本段 v95 \(v95, format: Fmt.f0) km/h（v50 \(v50, format: Fmt.f0)）：≥150，大巴到不了 → 铁路（小汽车也可能，请看一眼）",
                          comment: "Batch fill trip classification by speed (tooltip). 1 95th-percentile speed km/h, 2 median speed km/h. v95/v50 are symbols, keep them. Verdict: buses cannot reach 150 → rail (could also be a car, please check)")
        }
        if v95 <= 115 {
            return String(localized: "本段 v95 \(v95, format: Fmt.f0) km/h（v50 \(v50, format: Fmt.f0)）：≤115 → 公路",
                          comment: "Batch fill trip classification by speed (tooltip). 1 95th-percentile speed km/h, 2 median speed km/h. Verdict: road")
        }
        return String(localized: "本段 v95 \(v95, format: Fmt.f0) km/h（v50 \(v50, format: Fmt.f0)）：115–150 之间，区域列车与高速公路重叠 → 不确定，按单处速度规则",
                      comment: "Batch fill trip classification by speed (tooltip). 1 95th-percentile speed km/h, 2 median speed km/h. Verdict: between 115 and 150 regional trains overlap with motorways → undecided, use the per-gap speed rule")
    }
    func contains(_ c: GapCandidate) -> Bool { range.contains(c.indexA) }
}

/// 行程的地图证据：沿行程均匀取几个移动中的点，各查离最近铁路、最近可行驶道路多远。
/// 火车的点贴着铁路、离公路远；大巴反过来。这是判公路/铁路的主依据，速度只做没有地图时的退路
struct TripMapEvidence: Equatable {
    struct Sample: Equatable { var index: Int; var road: Double?; var rail: Double? }   // 米；nil = 请求失败；rail 1e9 = 150 m 内无铁路
    var samples: [Sample]
    /// 有公路答案的采样点
    var answered: Int { samples.filter { $0.road != nil }.count }
    var hasRailData: Bool { samples.contains { $0.rail != nil } }
    /// 有铁路答案的采样点（公路距离对火车也常只有几米——轨道旁总有辅路——没有区分力，只用铁路距离投票）
    var railAnswered: Int { samples.filter { $0.rail != nil }.count }
    /// 贴铁路：150 m 内有铁路且 ≤30 m
    var railVotes: Int { samples.filter { ($0.rail ?? 1e9) <= 30 }.count }
    /// 不贴铁路：150 m 内没有铁路，或最近的也在 80 m 外
    var roadVotes: Int { samples.filter { s in guard let rail = s.rail else { return false }; return rail >= 80 }.count }
    /// 有把握才下结论：≥2/3 的采样点投同一边，另一边 ≤1/3；没拿到铁路数据就不猜（退回速度）
    var verdict: BatchKind? {
        guard railAnswered >= 3 else { return nil }
        if railVotes * 3 >= railAnswered * 2, roadVotes * 3 <= railAnswered { return .rail }
        if roadVotes * 3 >= railAnswered * 2, railVotes * 3 <= railAnswered { return .road }
        return nil
    }
    var note: String {
        func med(_ xs: [Double]) -> String {
            let a = xs.sorted()
            return a.isEmpty ? "—" : (a[a.count / 2] > 150 ? String(localized: "150 m 内无", comment: "Median distance to the nearest railway: no railway within 150 m. Inserted into the trip map-evidence note") : "\(a[a.count / 2].formatted(Fmt.f0)) m")
        }
        let rails = samples.compactMap(\.rail), roads = samples.compactMap(\.road)
        if railAnswered == 0 { return String(localized: "地图：铁路数据没拿到（Overpass 超时/排队），没法判；可点「重新用地图判断」再试，或手选本段", comment: "Batch fill trip map evidence (tooltip): railway data from Overpass failed (timeout/queue). 「重新用地图判断」 is the button label 'Re-check with Map'; reuse its translation") }
        _ = roads
        let railMedian = med(rails)
        let verdictText = verdict?.label ?? String(localized: "拿不准（两边都没到三分之二）", comment: "Batch fill trip map evidence verdict: undecided (neither side reached two thirds of the sampled points)")
        return String(localized: "地图：这段抽了 \(railAnswered) 个点，贴着铁路（≤30 m）的 \(railVotes) 个、离铁路远（≥80 m 或 150 m 内没有）的 \(roadVotes) 个（离铁路中位 \(railMedian)）→ \(verdictText)",
                      comment: "Batch fill trip map evidence (tooltip). 1 sampled points with railway data, 2 points within 30 m of a railway, 3 points far from any railway (≥80 m or none within 150 m), 4 median distance to railway (e.g. '12 m' or 'none within 150 m'), 5 verdict (Road/Rail/undecided)")
    }
}

enum TripSegmenter {
    static let stopRadius = 150.0, stopSeconds = 10.0 * 60     // 10 min（用户定）：换乘 ≥10 min 切开大巴和火车；DB 车站停靠通常几分钟
    /// 每隔 ~30 s 取一个检查点，向前扫到离开 150 m 为止；停留 ≥20 min 或之后记录空白 ≥20 min 就在停留结束处切一刀
    static func trips(track t: TrackData) -> [Trip] {
        let n = t.timedCount
        guard n >= 2 else { return [] }
        var cuts = Set<Int>()
        // 记录空白 ≥10 min 的地方一律切（检查点每 30 s 步进时会跳过夹在两个检查点之间的空白）
        for m in 1..<n where t.time[m] - t.time[m - 1] >= stopSeconds { cuts.insert(m) }
        var i = 0
        while i < n - 1 {
            var j = i
            while j + 1 < n, GeoMath.haversine(t.lat[i], t.lon[i], t.lat[j + 1], t.lon[j + 1]) <= stopRadius { j += 1 }
            let stayed = t.time[j] - t.time[i] >= stopSeconds
            let blank = j + 1 < n && t.time[j + 1] - t.time[j] >= stopSeconds
            if stayed || blank {
                if j + 1 < n { cuts.insert(j + 1) }
                i = j + 1
            } else {
                // 下一个检查点：时间推进 ≥30 s（至少前进 1 点）
                var k = i + 1
                while k < n - 1, t.time[k] - t.time[i] < 30 { k += 1 }
                i = k
            }
        }
        // 同一次停留里既有"停留结束"的切点又有"空白"的切点（停靠时记录中断了一段）：只留最后那个，
        // 中间夹着的几个静止点不该单独成一段
        var sortedCuts = cuts.filter { $0 > 0 && $0 < n }.sorted()
        var k = 0
        while k + 1 < sortedCuts.count {
            let a = sortedCuts[k], b = sortedCuts[k + 1]
            // 只在"空白两侧都在同一地点"时才算同一次停留（孤立的远处单点不并）
            var stationary = a >= 1 && GeoMath.haversine(t.lat[a - 1], t.lon[a - 1], t.lat[a], t.lon[a]) <= stopRadius
            var q = a
            while stationary, q < b { if GeoMath.haversine(t.lat[a], t.lon[a], t.lat[q], t.lon[q]) > stopRadius { stationary = false }; q += 1 }
            if stationary { sortedCuts.remove(at: k) } else { k += 1 }
        }
        let bounds = [0] + sortedCuts + [n]
        var out: [Trip] = []
        for k in 0..<(bounds.count - 1) {
            let a = bounds[k], b = bounds[k + 1]
            guard b - a >= 2 else { continue }
            var speeds: [Double] = []
            var km = 0.0
            var q = a + 1
            while q < b {
                let dt = t.time[q] - t.time[q - 1]
                let d = GeoMath.haversine(t.lat[q - 1], t.lon[q - 1], t.lat[q], t.lon[q])
                if dt > 0, dt <= 60 {
                    let v = d / dt * 3.6
                    if v <= 350 { km += d / 1000 }
                    if v > 1, v <= 350 { speeds.append(v) }
                }
                q += 1
            }
            speeds.sort()
            let v50 = speeds.isEmpty ? 0 : speeds[speeds.count / 2]
            let v95 = speeds.isEmpty ? 0 : speeds[Int(0.95 * Double(speeds.count - 1))]
            out.append(Trip(index: out.count, range: a..<b, tStart: t.time[a], tEnd: t.time[b - 1], km: km, v50: v50, v95: v95))
        }
        return out
    }

    /// 地图判断用的采样点：掐掉首尾各 60 s（车站/停车场），在速度 >5 km/h 的点里按时间均匀取 count 个
    static func samplePoints(track t: TrackData, trip: Trip, count: Int) -> [Int] {
        let a = trip.range.lowerBound, b = trip.range.upperBound
        var moving: [Int] = []
        var i = a + 1
        while i < b {
            // 只在车真正跑起来的点上采样（≥30 km/h）：换乘走路、站台、停车场的点会把火车判成公路
            if t.time[i] - trip.tStart >= 60, trip.tEnd - t.time[i] >= 60, i < t.speedKmh.count, t.speedKmh[i] >= 30, t.speedKmh[i] <= 350 { moving.append(i) }
            i += 1
        }
        guard !moving.isEmpty else { return [] }
        let k = min(count, moving.count)
        return (0..<k).map { moving[Int((Double($0) + 0.5) / Double(k) * Double(moving.count))] }
    }
}

extension GapDetector {
    /// "断档步"唯一口径：所有向外遍历（上下文、方向、窗口速度、点距统计）共用，只读默认门槛 150 m / 20 s / 350 km/h。
    /// refreshGapCandidates 改动的只是 staleEnabled，与这里无关
    static let breakOptions = Options()
    static func isBreakStep(dt: Double, meters d: Double) -> Bool {
        let o = breakOptions
        if dt <= 0 { return d >= o.minMeters }
        if d / dt * 3.6 > o.maxKmh { return true }
        return d >= o.minMeters && dt >= o.minSeconds
    }
    static let windowMinSeconds = 10.0, windowMinMeters = 100.0, windowMaxSeconds = 60.0, windowMaxSteps = 120
}

/// 断档成因：手机后台本来就 7–28 s 记一个点（前一个点常在 0.5–2 km 外）——这是"稀疏采样步"；
/// 时长远大于两侧采样间隔的才是"失锁断档"。只是标签，不改检测也不改路由
enum GapNature: String { case sparseSampling = "sparse", lossOfLock = "lol"
    var label: String {
        self == .sparseSampling
            ? String(localized: "采样稀疏", comment: "Gap cause label: sparse sampling (the device records this rarely anyway; not a signal problem)")
            : String(localized: "信号中断", comment: "Gap cause label: signal loss (the device recorded nothing during the gap)")
    }
}

struct LocalSampling: Equatable {
    var tau: Double?          // 两侧移动步的采样间隔中位数；样本 <3 时为 nil
    var count: Int
    var fallbackTau: Double   // 画像的中位步时；无画像时 1
    var seconds: Double       // t[B] − t[A]
    var effectiveTau: Double { tau ?? fallbackTau }
    var nature: GapNature { seconds < GapRouteInputs.samplingFactor * effectiveTau ? .sparseSampling : .lossOfLock }
    /// 操作条用的一行
    var shortText: String {
        guard let tau else {
            let cause = nature.label
            return String(localized: "成因：\(cause) · 两侧步数不足，按画像中位 \(fallbackTau, format: Fmt.f0) s",
                          comment: "Gap cause, one line in the fill panel / gap list. 1 cause label (sparse sampling / signal loss), 2 median seconds between samples of the whole track profile (too few steps on both sides of the gap)")
        }
        let ratio = seconds / tau
        return nature == .sparseSampling
            ? String(localized: "成因：采样稀疏 · 这段 \(seconds, format: Fmt.f0) s，前后本来就每 \(tau, format: Fmt.f0) s 记一个点（\(ratio, format: Fmt.f1) 倍，正常跳步）",
                     comment: "Gap cause, one line in the fill panel / gap list. 1 gap duration seconds, 2 usual seconds between samples around the gap, 3 ratio (times). Sparse sampling: a normal skipped step")
            : String(localized: "成因：信号中断 · 这段 \(seconds, format: Fmt.f0) s 没有记录，前后每 \(tau, format: Fmt.f0) s 一个点（\(ratio, format: Fmt.f0) 倍）",
                     comment: "Gap cause, one line in the fill panel / gap list. 1 gap duration seconds with no record, 2 usual seconds between samples around the gap, 3 ratio (times). Signal loss")
    }
    /// 草稿说明用的一行
    var noteText: String {
        guard let tau else {
            let cause = nature.label
            return String(localized: "成因：\(cause)（两侧可用步数只有 \(count) 步，按整条轨迹画像中位 \(fallbackTau, format: Fmt.f0) s 判断）",
                          comment: "Gap cause line in the route draft notes. 1 cause label (sparse sampling / signal loss), 2 number of usable steps on both sides (steps = sample intervals), 3 median seconds between samples of the whole track")
        }
        let ratio = seconds / tau
        return nature == .sparseSampling
            ? String(localized: "成因：采样稀疏（这段 \(seconds, format: Fmt.f0) s，前后本来就每 \(tau, format: Fmt.f0) s 记一个点，按 \(count) 步算）",
                     comment: "Gap cause line in the route draft notes. 1 gap duration seconds, 2 usual seconds between samples around the gap, 3 number of steps the median was computed from")
            : String(localized: "成因：信号中断（这段 \(seconds, format: Fmt.f0) s 没有记录，约为前后采样间隔 \(tau, format: Fmt.f0) s 的 \(ratio, format: Fmt.f0) 倍）",
                     comment: "Gap cause line in the route draft notes. 1 gap duration seconds with no record, 2 usual sampling interval seconds around the gap, 3 ratio (times)")
    }
    static var helpText: String { String(localized: "怎么分：看断档前后本来多久记一个点（各取 ≤12 个移动点算中位数）。这段空白不到它的 3 倍，就是「采样稀疏」——设备本来就隔这么久记一个点，不是信号问题（手机后台常常 7–28 秒才记一个点、前一个点在 0.5–2 公里外）；超过 3 倍，就是「信号中断」——这段时间设备没记到点（隧道、失去定位）。两种都照常列为候选：补上路网可以让世界迷雾沿路解锁；批量窗口里可以一键跳过采样稀疏的那些。", comment: "Tooltip explaining the two gap causes 「采样稀疏」 (sparse sampling) and 「信号中断」 (signal loss); reuse those label translations. 世界迷雾 = Fog of World") }
}

/// 路网请求的输入组装（上下文锚点、行进方向、匹配轨迹、成因），纯函数：TrackStore、离线 harness、UITestHook 共用同一份。
/// 每次向外遍历都记下停止原因，给用户看"为什么没用上下文/方向"
enum GapRouteInputs {
    static let contextLadder: [Double] = [150, 100, 60]
    static let contextMaxPoints = 60, headingMaxPoints = 40
    static let headingMinChord = 25.0, headingChordFloor = 150.0
    static let samplingPerSide = 12, samplingScanPerSide = 60, samplingFactor = 3.0

    enum Stop: Equatable {
        case found, edge, breakStep(seconds: Double, meters: Double), tooFar(meters: Double, limit: Double), tooOld(seconds: Double), tooFew(points: Int), parked(seconds: Double)
        var key: String {
            switch self {
            case .found: return "found"; case .edge: return "edge"; case .breakStep: return "break"; case .tooFar: return "tooFar"
            case .tooOld: return "tooOld"; case .tooFew: return "tooFew"; case .parked: return "parked"
            }
        }
    }
    struct Heading { var bearing: Double?; var index: Int?; var meters: Double; var seconds: Double; var maxChord: Double; var stop: Stop }
    struct Context { var anchor: RoadNetwork.ContextAnchor?; var index: Int?; var rung: Double?; var meters: Double; var seconds: Double; var stop: Stop }
    struct Side { var heading: Heading; var context: Context }
    struct Inputs {
        var a: Side; var b: Side
        var traceIndices: [Int]; var trace: [RoadNetwork.TracePoint]; var traceBefore: Int; var traceAfter: Int
        var radius: Double
        var sampling: LocalSampling
        /// 锚点外侧的真实点（A 往前、B 往后各 ≤10 个，≤60 s、≤300 m，不跨断档，最多到上下文点）：隧道口漂移判定用
        var portalA: [RoadNetwork.PortalSample] = []
        var portalB: [RoadNetwork.PortalSample] = []
        /// 远上下文：近上下文的路由不干净（绕圈/锚点离路远）时再往外取一次——隧道口整段漂到平行路上时，
        /// 只有从更远处回望才能看出真正走的是哪条路。≥600 m 且 ≥30 s，最远 900 m / 90 s / 60 点，不跨断档
        var farContextA: RoadNetwork.ContextAnchor? = nil
        var farContextB: RoadNetwork.ContextAnchor? = nil
        var portalFarA: [RoadNetwork.PortalSample] = []
        var portalFarB: [RoadNetwork.PortalSample] = []
        /// 交互模式的请求数：直接 1 + 匹配(trace≥3) + 上下文(任一侧) + 约束(任一侧有方向)
        var requestCount: Int { 1 + (trace.count >= 3 ? 1 : 0) + ((a.context.anchor != nil || b.context.anchor != nil) ? 1 : 0) + ((a.heading.bearing != nil || b.heading.bearing != nil) ? 1 : 0) }
    }
    /// 只给离线 harness 用：覆盖时限/弦长上限（例如 (∞, 600) 复现第一轮行为，作为基线与新行为逐行比对）。App 里永远为 nil
    nonisolated(unsafe) static var limitOverride: (seconds: Double, chord: Double)? = nil
    // 没有画像时的默认值
    private static func cap(_ p: SamplingProfile?) -> Double { p?.contextCap ?? 600 }
    private static func maxSeconds(_ p: SamplingProfile?) -> Double { limitOverride?.seconds ?? p?.contextMaxSeconds ?? 600 }
    private static func chordMax(_ p: SamplingProfile?) -> Double { limitOverride?.chord ?? p?.headingChordMax ?? 300 }

    /// 该侧 ≤12 步的步长中位数（含静止步与断档步，与旧 localStep 相同）
    static func localStepMeters(_ t: TrackData, _ idx: Int, forward: Bool) -> Double {
        var ds: [Double] = []
        var k = idx
        for _ in 0..<12 {
            let prev = k
            k += forward ? 1 : -1
            guard k >= 0, k < t.timedCount else { break }
            ds.append(GeoMath.haversine(t.lat[prev], t.lon[prev], t.lat[k], t.lon[k]))
        }
        guard !ds.isEmpty else { return 30 }
        ds.sort()
        return ds[ds.count / 2]
    }

    /// 行进方向：进入 A（forward=false，取 k→idx）/ 离开 B（forward=true，取 idx→k）。第一个 ≥25 m 的点；
    /// 弦长上限 min(300, max(150, 2×局部步长))；不跨断档；只看 600 s 内
    static func heading(_ t: TrackData, _ idx: Int, forward: Bool, profile p: SamplingProfile?) -> Heading {
        let step = localStepMeters(t, idx, forward: forward)
        let maxChord = min(chordMax(p), max(headingChordFloor, 2 * step))
        var k = idx
        for _ in 0..<headingMaxPoints {
            let prev = k
            k += forward ? 1 : -1
            guard k >= 0, k < t.timedCount else { return Heading(bearing: nil, index: nil, meters: 0, seconds: 0, maxChord: maxChord, stop: .edge) }
            let sdt = abs(t.time[k] - t.time[prev]), sd = GeoMath.haversine(t.lat[prev], t.lon[prev], t.lat[k], t.lon[k])
            if GapDetector.isBreakStep(dt: sdt, meters: sd) { return Heading(bearing: nil, index: nil, meters: 0, seconds: 0, maxChord: maxChord, stop: .breakStep(seconds: sdt, meters: sd)) }
            let secs = abs(t.time[k] - t.time[idx])
            if secs > maxSeconds(p) { return Heading(bearing: nil, index: nil, meters: 0, seconds: secs, maxChord: maxChord, stop: .tooOld(seconds: secs)) }
            let d = GeoMath.haversine(t.lat[idx], t.lon[idx], t.lat[k], t.lon[k])
            if d > maxChord { return Heading(bearing: nil, index: nil, meters: d, seconds: secs, maxChord: maxChord, stop: .tooFar(meters: d, limit: maxChord)) }
            if d >= headingMinChord {
                let b = forward ? GeoMath.bearing(t.lat[idx], t.lon[idx], t.lat[k], t.lon[k])
                                : GeoMath.bearing(t.lat[k], t.lon[k], t.lat[idx], t.lon[idx])
                return Heading(bearing: b, index: k, meters: d, seconds: secs, maxChord: maxChord, stop: .found)
            }
        }
        return Heading(bearing: nil, index: nil, meters: 0, seconds: 0, maxChord: maxChord, stop: .tooFew(points: headingMaxPoints))
    }

    /// 上下文锚点：单遍向外，第一个 ≥150 m 的点；走不到时退到 ≥100 / ≥60 m 的点（stop 记的是 150 m 档为什么没走到）。
    /// 不跨断档；离锚点 >600 m 或 >600 s 的点不用（A′ 太远时 A′→B′ 的最短路不一定经过 A；停车/下车后的点不当上下文）
    static func context(_ t: TrackData, _ idx: Int, forward: Bool, profile p: SamplingProfile?) -> Context {
        var k = idx
        var first100: (Int, Double, Double)? = nil, first60: (Int, Double, Double)? = nil
        var stop: Stop = .tooFew(points: contextMaxPoints)
        func anchor(_ k: Int) -> RoadNetwork.ContextAnchor {
            RoadNetwork.ContextAnchor(coord: CLLocationCoordinate2D(latitude: t.lat[k], longitude: t.lon[k]),
                                      bearing: heading(t, k, forward: forward, profile: p).bearing)
        }
        for _ in 0..<contextMaxPoints {
            let prev = k
            k += forward ? 1 : -1
            guard k >= 0, k < t.timedCount else { stop = .edge; break }
            let sdt = abs(t.time[k] - t.time[prev]), sd = GeoMath.haversine(t.lat[prev], t.lon[prev], t.lat[k], t.lon[k])
            if GapDetector.isBreakStep(dt: sdt, meters: sd) { stop = .breakStep(seconds: sdt, meters: sd); break }
            let secs = abs(t.time[k] - t.time[idx])
            if secs > maxSeconds(p) { stop = .tooOld(seconds: secs); break }
            let d = GeoMath.haversine(t.lat[idx], t.lon[idx], t.lat[k], t.lon[k])
            if d > cap(p) { stop = .tooFar(meters: d, limit: cap(p)); break }
            if d >= contextLadder[0] { return Context(anchor: anchor(k), index: k, rung: contextLadder[0], meters: d, seconds: secs, stop: .found) }
            if d >= contextLadder[1], first100 == nil { first100 = (k, d, secs) }
            if d >= contextLadder[2], first60 == nil { first60 = (k, d, secs) }
        }
        if let (k, d, s) = first100 { return Context(anchor: anchor(k), index: k, rung: contextLadder[1], meters: d, seconds: s, stop: stop) }
        if let (k, d, s) = first60 { return Context(anchor: anchor(k), index: k, rung: contextLadder[2], meters: d, seconds: s, stop: stop) }
        return Context(anchor: nil, index: nil, rung: nil, meters: 0, seconds: 0, stop: stop)
    }

    /// 地图匹配用的真实点下标：A 前 ≤4 + B 后 ≤4。可以跨断档（OSRM 按时间戳判可达性），但离锚点 ≤5 km、≤180 s，
    /// 每侧覆盖到 300 m 就停，相邻步 ≤350 km/h，遇 dt ≤0 停
    static func matchTraceIndices(_ t: TrackData, ia: Int, ib: Int, profile p: SamplingProfile?) -> [Int] {
        guard ia >= 0, ib < t.timedCount, ia < ib else { return [] }
        let reach = p?.matchReach ?? 5000, budget = p?.matchBudget ?? 300
        func side(_ idx: Int, forward: Bool) -> [Int] {
            var out: [Int] = []
            var k = idx
            while out.count < 4 {
                let prev = k
                k += forward ? 1 : -1
                guard k >= 0, k < t.timedCount else { break }
                let dAnchor = GeoMath.haversine(t.lat[idx], t.lon[idx], t.lat[k], t.lon[k])
                let tAnchor = abs(t.time[k] - t.time[idx])
                if dAnchor > reach || tAnchor > 180 { break }
                let dt = abs(t.time[k] - t.time[prev])
                let d = GeoMath.haversine(t.lat[prev], t.lon[prev], t.lat[k], t.lon[k])
                if dt <= 0 || d / dt * 3.6 > 350 { break }
                out.append(k)
                if dAnchor >= budget { break }
            }
            return out
        }
        let before = side(ia, forward: false).reversed(), after = side(ib, forward: true)
        guard !before.isEmpty || !after.isEmpty else { return [] }
        return Array(before) + [ia, ib] + after
    }

    /// 两侧采样间隔中位数：各扫 ≤60 点、600 s 内，不在断档处停；只收 0<Δt≤3600 且 1 m/s<v≤350 km/h 的步，每侧 ≤12
    static func localSampling(_ t: TrackData, ia: Int, ib: Int, profile p: SamplingProfile?) -> LocalSampling {
        var dts: [Double] = []
        for (idx, forward) in [(ia, false), (ib, true)] {
            var k = idx, got = 0
            for _ in 0..<samplingScanPerSide {
                let prev = k
                k += forward ? 1 : -1
                guard k >= 0, k < t.timedCount, got < samplingPerSide else { break }
                if abs(t.time[k] - t.time[idx]) > maxSeconds(p) { break }
                let dt = abs(t.time[k] - t.time[prev])
                guard dt > 0, dt <= 3600 else { continue }
                let v = GeoMath.haversine(t.lat[prev], t.lon[prev], t.lat[k], t.lon[k]) / dt
                if v > 1, v * 3.6 <= 350 { dts.append(dt); got += 1 }
            }
        }
        let secs = (ia >= 0 && ib < t.timedCount) ? t.time[ib] - t.time[ia] : 0
        var tau: Double? = nil
        if dts.count >= 3 { dts.sort(); tau = dts[dts.count / 2] }
        return LocalSampling(tau: tau, count: dts.count, fallbackTau: p?.medianDt ?? 1, seconds: secs)
    }

    /// 组装全部输入；停车联动：某侧上下文因 600 s 时限失败（停车/下车）时，这一侧的方向也不用
    static func build(_ t: TrackData, ia: Int, ib: Int, profile p: SamplingProfile?) -> Inputs {
        var a = Side(heading: heading(t, ia, forward: false, profile: p), context: context(t, ia, forward: false, profile: p))
        var b = Side(heading: heading(t, ib, forward: true, profile: p), context: context(t, ib, forward: true, profile: p))
        for side in [0, 1] {
            var s = side == 0 ? a : b
            if s.context.anchor == nil, case .tooOld(let secs) = s.context.stop {
                s.heading.bearing = nil; s.heading.index = nil; s.heading.stop = .parked(seconds: secs)
            }
            if side == 0 { a = s } else { b = s }
        }
        let idxs = matchTraceIndices(t, ia: ia, ib: ib, profile: p)
        let trace = idxs.map { RoadNetwork.TracePoint(coord: CLLocationCoordinate2D(latitude: t.lat[$0], longitude: t.lon[$0]), time: t.time[$0], index: $0) }
        let farA = farContext(t, ia, forward: false, profile: p), farB = farContext(t, ib, forward: true, profile: p)
        return Inputs(a: a, b: b, traceIndices: idxs, trace: trace,
                      traceBefore: idxs.filter { $0 < ia }.count, traceAfter: idxs.filter { $0 > ib }.count,
                      radius: p?.matchRadius ?? 15, sampling: localSampling(t, ia: ia, ib: ib, profile: p),
                      portalA: portalSamples(t, ia, forward: false, limit: a.context.index),
                      portalB: portalSamples(t, ib, forward: true, limit: b.context.index),
                      farContextA: farA?.anchor, farContextB: farB?.anchor,
                      portalFarA: farA.map { portalSamples(t, ia, forward: false, limit: $0.index, maxPoints: farMaxPoints, maxSeconds: farMaxSeconds, maxMeters: farMaxMeters) } ?? [],
                      portalFarB: farB.map { portalSamples(t, ib, forward: true, limit: $0.index, maxPoints: farMaxPoints, maxSeconds: farMaxSeconds, maxMeters: farMaxMeters) } ?? [])
    }

    static let farMinMeters = 600.0, farMinSeconds = 30.0, farMaxMeters = 900.0, farMaxSeconds = 90.0, farMaxPoints = 60
    /// 远上下文点：往外第一个 ≥600 m 且 ≥30 s 的真实点；走不到就取 900 m / 90 s / 60 点内最远的那个（至少要比近上下文远 250 m）
    static func farContext(_ t: TrackData, _ idx: Int, forward: Bool, profile p: SamplingProfile?) -> (anchor: RoadNetwork.ContextAnchor, index: Int)? {
        var k = idx, along = 0.0
        var best: Int? = nil
        for _ in 0..<farMaxPoints {
            let prev = k
            k += forward ? 1 : -1
            guard k >= 0, k < t.timedCount else { break }
            let sdt = abs(t.time[k] - t.time[prev]), sd = GeoMath.haversine(t.lat[prev], t.lon[prev], t.lat[k], t.lon[k])
            if GapDetector.isBreakStep(dt: sdt, meters: sd) { break }
            along += sd
            let secs = abs(t.time[k] - t.time[idx])
            if secs > farMaxSeconds || along > farMaxMeters { break }
            if along >= 250 { best = k }
            if along >= farMinMeters, secs >= farMinSeconds { break }
        }
        guard let b = best else { return nil }
        let anchor = RoadNetwork.ContextAnchor(coord: CLLocationCoordinate2D(latitude: t.lat[b], longitude: t.lon[b]),
                                               bearing: heading(t, b, forward: forward, profile: p).bearing)
        return (anchor, b)
    }

    static let portalMaxPoints = 10, portalMaxSeconds = 60.0, portalMaxMeters = 300.0
    /// 锚点外侧的真实点：往外 ≤10 个、≤60 s、≤300 m，不跨断档；有上下文点时最多数到上下文点（几何只到那里）
    static func portalSamples(_ t: TrackData, _ idx: Int, forward: Bool, limit: Int?,
                              maxPoints: Int = portalMaxPoints, maxSeconds: Double = portalMaxSeconds, maxMeters: Double = portalMaxMeters) -> [RoadNetwork.PortalSample] {
        var out: [RoadNetwork.PortalSample] = []
        var k = idx
        var along = 0.0
        while out.count < maxPoints {
            let prev = k
            k += forward ? 1 : -1
            guard k >= 0, k < t.timedCount else { break }
            if let limit, forward ? k > limit : k < limit { break }
            let sdt = abs(t.time[k] - t.time[prev]), sd = GeoMath.haversine(t.lat[prev], t.lon[prev], t.lat[k], t.lon[k])
            if GapDetector.isBreakStep(dt: sdt, meters: sd) { break }
            along += sd
            let secs = abs(t.time[k] - t.time[idx])
            if secs > maxSeconds || along > maxMeters { break }
            out.append(RoadNetwork.PortalSample(index: k, coord: CLLocationCoordinate2D(latitude: t.lat[k], longitude: t.lon[k]), meters: along, seconds: secs))
        }
        return out
    }

    private static func m(_ x: Double) -> String { x >= 1000 ? "\((x / 1000).formatted(Fmt.f1)) km" : "\(x.formatted(Fmt.f0)) m" }

    /// 停止原因的说明。reach = 该遍历想走到多远；heading = 是否方向遍历
    static func why(_ stop: Stop, side: String, reach: Double, heading: Bool, profile p: SamplingProfile?) -> String {
        let T = maxSeconds(p)
        let isA = side == "A"
        switch stop {
        case .found: return String(localized: "已找到", comment: "Route input stop reason (draft notes): the context/heading point was found")
        case .edge: return String(localized: "已到轨迹端点", comment: "Route input stop reason (draft notes): reached the start/end of the track")
        case .breakStep(let s, let d):
            let dist = m(d)
            return String(localized: "下一步本身是断档（\(s, format: Fmt.f0) s / \(dist)）",
                          comment: "Route input stop reason (draft notes): the next step outward is itself a gap. 1 seconds, 2 distance with unit (e.g. 320 m / 1.2 km)")
        case .tooFar(let d, let lim):
            let dist = m(d)
            return heading ? String(localized: "第一个离 \(side) ≥25 m 的点在 \(dist) 外（弦长上限 \(lim, format: Fmt.f0) m）",
                                    comment: "Route input stop reason (draft notes, travel direction): 1 anchor letter A or B, 2 distance with unit, 3 chord length limit in metres")
                           : String(localized: "往外走到的点已在 \(dist) 外（上限 \(lim, format: Fmt.f0) m）",
                                    comment: "Route input stop reason (draft notes, context point): walking outward the point is already beyond 1 = distance with unit; 2 = limit in metres")
        case .tooOld:
            return isA ? String(localized: "A 前 \(T, format: Fmt.f0) s 内都没离开 A \(reach, format: Fmt.f0) m（停车或下车）",
                                comment: "Route input stop reason (draft notes): within 1 = seconds before anchor A the track never moved 2 = metres away from A (parked or got out). A is the gap's start anchor")
                       : String(localized: "B 后 \(T, format: Fmt.f0) s 内都没离开 B \(reach, format: Fmt.f0) m（停车或下车）",
                                comment: "Route input stop reason (draft notes): within 1 = seconds after anchor B the track never moved 2 = metres away from B (parked or got out). B is the gap's end anchor")
        case .tooFew(let n):
            return String(localized: "往外 \(n) 个点都没离开 \(side) \(reach, format: Fmt.f0) m",
                          comment: "Route input stop reason (draft notes): 1 number of points walked outward, none of them left 2 = anchor letter A or B by 3 = metres")
        case .parked:
            return isA ? String(localized: "A 前 \(T, format: Fmt.f0) s 内都没离开 A 60 m（停车），25–60 m 的挪动不算行进方向",
                                comment: "Route input stop reason (draft notes, travel direction): within the given seconds before anchor A the track stayed within 60 m of A (parked); moves of 25–60 m do not count as a direction of travel")
                       : String(localized: "B 后 \(T, format: Fmt.f0) s 内都没离开 B 60 m（停车），25–60 m 的挪动不算行进方向",
                                comment: "Route input stop reason (draft notes, travel direction): within the given seconds after anchor B the track stayed within 60 m of B (parked); moves of 25–60 m do not count as a direction of travel")
        }
    }

    /// 候选自带的说明（与锚点输入无关，只看检测结果）：目前只有 A 侧冻结假点链前移（GapDetector.shiftFrozenChains）
    static func candidateNotes(_ c: GapCandidate?) -> [String] {
        guard let c, c.frozenA > 0 else { return [] }
        let n = c.frozenA
        return [String(localized: "A 前 \(n) 个点是进隧道后的外推点（航向/步长锁死），已并入替换区间",
                       comment: "Route draft notes: %lld = number of points just before anchor A that the GPS device extrapolated after entering a tunnel (heading and step length frozen); they were moved into the replaced interval")]
    }

    /// 给用户看的说明：A 上下文 → B 上下文 → 行进方向 → 匹配 → 成因 → 画像
    static func notes(_ inp: Inputs, profile p: SamplingProfile?) -> [String] {
        var out: [String] = []
        for (side, s) in [("A", inp.a), ("B", inp.b)] {
            let c = s.context
            if let rung = c.rung, c.anchor != nil {
                let dir = c.anchor?.bearing == nil
                    ? String(localized: "无行进方向", comment: "Route draft notes: the context point has no direction of travel (inserted into the context line)")
                    : String(localized: "带行进方向", comment: "Route draft notes: the context point carries a direction of travel (inserted into the context line)")
                let dist = m(c.meters)
                if rung == contextLadder[0] {
                    out.append(String(localized: "\(side) 侧上下文：\(dist) 外的真实点（距 \(side) \(c.seconds, format: Fmt.f0) s，\(dir)）",
                                      comment: "Route draft notes, context point line. 1 anchor letter A or B, 2 distance with unit, 3 the same anchor letter, 4 seconds from the anchor, 5 with/without direction of travel"))
                } else {
                    let reason = why(c.stop, side: side, reach: 150, heading: false, profile: p)
                    out.append(String(localized: "\(side) 侧上下文：\(dist) 外的真实点（距 \(side) \(c.seconds, format: Fmt.f0) s，\(dir)；150 m 档没走到：\(reason)，退到 \(rung, format: Fmt.f0) m 档）",
                                      comment: "Route draft notes, context point line (fallback tier). 1 anchor letter A or B, 2 distance with unit, 3 the same anchor letter, 4 seconds from the anchor, 5 with/without direction of travel, 6 why the 150 m tier was not reached, 7 the smaller tier in metres that was used"))
                }
            } else {
                let reason = why(c.stop, side: side, reach: 60, heading: false, profile: p)
                switch c.stop {
                case .breakStep, .tooFar:
                    out.append(String(localized: "\(side) 侧未用上下文：\(reason)，交给地图匹配",
                                      comment: "Route draft notes: 1 anchor letter A or B, 2 reason; no context point used on that side, left to map matching"))
                case .tooOld:
                    out.append(side == "A"
                        ? String(localized: "A 侧未用上下文：\(reason)，更早的点不当上下文",
                                 comment: "Route draft notes: no context point used on side A; reason; earlier points are not used as context")
                        : String(localized: "B 侧未用上下文：\(reason)，更晚的点不当上下文",
                                 comment: "Route draft notes: no context point used on side B; reason; later points are not used as context"))
                default:
                    out.append(String(localized: "\(side) 侧未用上下文：\(reason)",
                                      comment: "Route draft notes: 1 anchor letter A or B, 2 reason; no context point used on that side"))
                }
            }
        }
        func headingText(_ side: String, _ h: Heading) -> String {
            if let b = h.bearing {
                let deg = ((Int(b.rounded()) % 360) + 360) % 360
                let dist = m(h.meters)
                return String(localized: "\(side) 侧 \(deg)°（\(dist) / \(h.seconds, format: Fmt.f0) s 外的点）",
                              comment: "Route draft notes, direction of travel on one side. 1 anchor letter A or B, 2 bearing in degrees, 3 distance with unit, 4 seconds of the point used")
            }
            let reason = why(h.stop, side: side, reach: 25, heading: true, profile: p)
            return String(localized: "\(side) 侧未约束（\(reason)）",
                          comment: "Route draft notes: 1 anchor letter A or B, 2 reason; no direction constraint on that side")
        }
        let ha = headingText("A", inp.a.heading), hb = headingText("B", inp.b.heading)
        if inp.a.heading.bearing == nil, inp.b.heading.bearing == nil {
            out.append(String(localized: "行进方向：\(ha)；\(hb)；两侧都没有方向，不发「约束」请求",
                              comment: "Route draft notes: direction of travel. 1 side A text, 2 side B text; neither side has a direction, so no 「约束」 request is sent (「约束」 = route method Constrained; reuse its translation)"))
        } else {
            out.append(String(localized: "行进方向：\(ha)；\(hb)",
                              comment: "Route draft notes: direction of travel. 1 side A text, 2 side B text"))
        }
        if inp.trace.count >= 3 {
            out.append(String(localized: "匹配轨迹：A 前 \(inp.traceBefore) 点 + B 后 \(inp.traceAfter) 点，半径 \(inp.radius, format: Fmt.f0) m",
                              comment: "Route draft notes: map-matching trace. 1 points before anchor A, 2 points after anchor B, 3 matching radius in metres"))
        } else {
            out.append(String(localized: "匹配未发：两侧 5 km / 180 s 内没有可用的真实点",
                              comment: "Route draft notes: map matching was not requested, no usable real points within 5 km / 180 s on either side"))
        }
        out.append(inp.sampling.noteText)
        if let p { out.append(p.summary + " → " + p.derivedSummary) }
        return out
    }
}

/// 一个合成点（时间为小数秒，但按整数秒唯一、严格落在 (tA, tB) 内）
struct FillPoint {
    var lat: Double
    var lon: Double
    var ele: Double          // NaN = 无海拔
    var time: Double
    var headingDeg: Double   // 所在线段方向
    var speedMps: Double     // 弧长匀速
    var distFromPrev: Double // 与上一点（含锚点 A）的距离，米
}

struct FillAnchor: Equatable {
    var lat: Double
    var lon: Double
    var ele: Double
    var time: Double
}

enum FillPath {
    /// 折线 A → vertices → B 的总弧长与分段长
    static func segmentLengths(a: FillAnchor, vertices: [CLLocationCoordinate2D],
                               b: FillAnchor) -> (lengths: [Double], total: Double) {
        var pts: [(Double, Double)] = [(a.lat, a.lon)]
        pts += vertices.map { ($0.latitude, $0.longitude) }
        pts.append((b.lat, b.lon))
        var lens: [Double] = []
        var total = 0.0
        for k in 1..<pts.count {
            let l = GeoMath.haversine(pts[k - 1].0, pts[k - 1].1, pts[k].0, pts[k].1)
            lens.append(l)
            total += l
        }
        return (lens, total)
    }

    /// 按弧长等距生成合成点（不含两端锚点）。spacing 为目标点距（米）；
    /// 时间 t = tA + (tB−tA)·s/L。点数上限 tB−tA−1 保证整数秒唯一且严格在开区间内
    static func interpolate(a: FillAnchor, vertices: [CLLocationCoordinate2D], b: FillAnchor,
                            spacingMeters: Double) -> [FillPoint] {
        guard b.time > a.time + 1 else { return [] }
        let (lens, total) = segmentLengths(a: a, vertices: vertices, b: b)
        guard total > 1 else { return [] }
        let spacing = max(1.0, spacingMeters)
        var n = max(0, Int((total / spacing).rounded()) - 1)
        let maxBySeconds = Int(floor(b.time) - floor(a.time)) - 1
        n = min(n, max(0, maxBySeconds))
        guard n > 0 else { return [] }

        var pts: [(Double, Double)] = [(a.lat, a.lon)]
        pts += vertices.map { ($0.latitude, $0.longitude) }
        pts.append((b.lat, b.lon))
        let duration = b.time - a.time
        let speed = total / duration
        let hasEle = a.ele.isFinite && b.ele.isFinite
        var out: [FillPoint] = []
        out.reserveCapacity(n)
        var seg = 0
        var segStart = 0.0          // 当前线段起点的弧长
        var prevLat = a.lat, prevLon = a.lon
        for i in 1...n {
            let s = total * Double(i) / Double(n + 1)
            while seg < lens.count - 1, s > segStart + lens[seg] { segStart += lens[seg]; seg += 1 }
            let f = lens[seg] > 0 ? min(1, max(0, (s - segStart) / lens[seg])) : 0
            let lat = pts[seg].0 + (pts[seg + 1].0 - pts[seg].0) * f
            // 跨 ±180° 子午线：差值按最短弧展开再混合，结果归一化回 [-180, 180]
            let dLon = remainder(pts[seg + 1].1 - pts[seg].1, 360)
            var lon = pts[seg].1 + dLon * f
            if lon > 180 { lon -= 360 } else if lon < -180 { lon += 360 }
            let t = a.time + duration * s / total
            let ele = hasEle ? a.ele + (b.ele - a.ele) * s / total : Double.nan
            let heading = GeoMath.bearing(pts[seg].0, pts[seg].1, pts[seg + 1].0, pts[seg + 1].1)
            let d = GeoMath.haversine(prevLat, prevLon, lat, lon)
            out.append(FillPoint(lat: lat, lon: lon, ele: ele, time: t,
                                 headingDeg: heading, speedMps: speed, distFromPrev: d))
            prevLat = lat; prevLon = lon
        }
        return out
    }
}

/// 一次已落地的补点记录
struct GapFill: Identifiable {
    let id = UUID()
    let anchorA: FillAnchor
    let anchorB: FillAnchor
    let vertices: [CLLocationCoordinate2D]
    let points: [FillPoint]
    let removedInner: Int               // 落地时删掉的区间内点数
    var userVertices: [CLLocationCoordinate2D]? = nil   // 用户画的顶点（不含由过时点派生的）；nil = 全部
    var routeSource: RouteSource? = nil                  // 顶点草稿来自哪个路网服务（nil = 纯手动）
    /// 路网证据（用户要求落地后还能回查）：采用的草稿在前，精确模式下另一路在后；比对结果
    var drafts: [RouteDraft] = []
    var cross: RouteCrossCheck.Result? = nil
    var straight = false                                 // 用直线补的（草稿可能仍留在 drafts 里，但没采用）
    var originalA: CLLocationCoordinate2D? = nil         // 断档原始两端（草稿没外推时折线从这里起画）
    var originalB: CLLocationCoordinate2D? = nil
    /// points 里有几个是「改时间」的过时出口点（位置是真实观测、时间按出口速度回推，见 StaleRetime）；其余是合成点
    var retimedKeys: Set<GapFillExport.PointKey> = []    // 这些改时点（新时间）的键
    var retimedOldKeys: Set<GapFillExport.PointKey> = [] // 对应旧点（旧时间）的键
    var retimed: Int { retimedKeys.count }
    /// 落地前自检结果（落地后可回查；直线 / 只删点 / 纯手动为 nil）
    var plausibility: FillPlausibility? = nil
    var tA: Double { anchorA.time }
    var tB: Double { anchorB.time }
}

/// 过时时钟点「保留位置、只改时间」（诊断报告 §1.4）：Garmin 出隧道后头几个点位置在出口车道上、时间戳却滞后。
/// 对区间内的过时出口点（下标 ∈ (indexA + frozenA, indexB)，排除 A 侧冻结外推假点）：离最终路线折线
/// （A + 顶点 + B）≤ max(匹配半径, 10) m、且按回推时间算车速 15–350 km/h 的，保留位置，时间改为
/// t′ = tB − (沿路到 B 的距离) / v_B（四舍五入到整秒，v_B = 出口速度）；其余照旧整点替换。
/// 合成点只补 A → 第一个保留点；保留点之间、最后一个保留点到 B 之间不插点。
/// 落地表达：保留点 = 旧点删掉 + 新点（同坐标/海拔、新时间）加入（Job.points 里），拼接/还原/增量导出都不用特殊处理。
/// 单处与批量共用；无 UI 依赖（离线 harness 也能编）
enum StaleRetime {
    struct Plan {
        var retimed: [(index: Int, time: Double)]        // 保留点（按下标升序，时间严格递增）
        var vertices: [CLLocationCoordinate2D]           // 裁到第一个保留点投影处的顶点（A → 第一个保留点）
        var fillB: FillAnchor                            // 合成点的终点锚：第一个保留点（新时间）
    }
    static let minKmh = 15.0, maxKmh = 350.0

    /// 出口速度 m/s：候选的记录速度；没有就用 B→B+1 的位置/时间；都无效 → nil
    static func exitSpeed(track: TrackData, ib: Int, candidate c: GapCandidate) -> Double? {
        if c.speedOutKmh > 0, c.speedOutKmh.isFinite { return c.speedOutKmh / 3.6 }
        guard ib + 1 < track.timedCount else { return nil }
        let dt = track.time[ib + 1] - track.time[ib]
        guard dt > 0 else { return nil }
        let v = GeoMath.haversine(track.lat[ib], track.lon[ib], track.lat[ib + 1], track.lon[ib + 1]) / dt
        return v > 0 && v.isFinite ? v : nil
    }

    /// ia/ib = 当前落地的锚点（可因隧道口漂移比候选的 A/B 更靠外：ia ≤ c.indexA、ib ≥ c.indexB；
    /// 只有候选 (A+frozenA, B] 里的点算过时出口点，锚点外推进来的漂移点照常替换）；vertices = 最终路线的中间顶点；radius = 匹配半径
    static func plan(track: TrackData, ia: Int, ib: Int, candidate c: GapCandidate,
                     vertices: [CLLocationCoordinate2D], radius: Double) -> Plan? {
        guard c.kind == .staleClock, ib >= c.indexB, ia < ib, ib < track.timedCount, ia >= 0 else { return nil }
        let lo = max(ia, c.indexA + c.frozenA) + 1
        let hi = min(ib - 1, c.indexB)                   // ib 外推过时原 B（时间正常）也在区间里，按同一规则处理
        guard lo <= hi, let vB = exitSpeed(track: track, ib: ib, candidate: c) else { return nil }
        let tA = track.time[ia], tB = track.time[ib]
        let A = CLLocationCoordinate2D(latitude: track.lat[ia], longitude: track.lon[ia])
        let Bc = CLLocationCoordinate2D(latitude: track.lat[ib], longitude: track.lon[ib])
        let f = PortalDrift.Frame(origin: A)
        let poly = PortalDrift.Poly([A] + vertices + [Bc], frame: f)
        let L = poly.length
        guard L > 0 else { return nil }
        let tol = max(radius, 10)
        // 从 B 往回：每个点的 t′ 必须早于后一个保留点（含 B），相邻隐含车速 15–350 km/h
        var nextS = L, nextT = tB
        var kept: [(index: Int, time: Double, hit: PortalDrift.Hit)] = []
        for k in stride(from: hi, through: lo, by: -1) {
            let q = f.xy(CLLocationCoordinate2D(latitude: track.lat[k], longitude: track.lon[k]))
            let h = poly.project(q)
            guard h.d <= tol, h.s < nextS else { continue }
            let t = (tB - (L - h.s) / vB).rounded()
            guard t > tA, t < nextT else { continue }
            let kmh = (nextS - h.s) / (nextT - t) * 3.6
            guard kmh >= minKmh, kmh <= maxKmh else { continue }
            kept.append((k, t, h))
            nextS = h.s; nextT = t
        }
        // A 侧也要合理：A → 第一个保留点的隐含车速（合成点按它匀速铺）不在 15–350 km/h 就把最早的保留点退回替换，再看下一个
        // （出口单步速度偏低时 t′ 会贴近 tA，否则 A 到首个保留点会铺出上千 km/h 的合成点）
        while let e = kept.last {
            let kmh = e.hit.s / (e.time - tA) * 3.6
            if kmh >= minKmh, kmh <= maxKmh { break }
            kept.removeLast()
        }
        guard let first = kept.last else { return nil }
        // 顶点裁到第一个保留点的投影处：只留投影所在线段之前的顶点（poly 顶点 k 对应 vertices[k-1]）
        let verts = Array(vertices.prefix(min(vertices.count, first.hit.seg)))
        let fb = FillAnchor(lat: track.lat[first.index], lon: track.lon[first.index], ele: track.ele[first.index], time: first.time)
        return Plan(retimed: kept.reversed().map { ($0.index, $0.time) }, vertices: verts, fillB: fb)
    }

    /// 落地用的点：合成点（A → 第一个保留点）+ 各保留点的新点（同坐标/海拔、新时间），按时间升序。
    /// 保留点的 heading/speed 按到下一点（下一保留点或 B）算，distFromPrev 按上一点（末个合成点或 A）算
    static func landingPoints(track: TrackData, ia: Int, ib: Int, plan: Plan, synthetic: [FillPoint]) -> [FillPoint] {
        var out = synthetic
        var prevLat = synthetic.last?.lat ?? track.lat[ia], prevLon = synthetic.last?.lon ?? track.lon[ia]
        for (n, r) in plan.retimed.enumerated() {
            let la = track.lat[r.index], lo = track.lon[r.index]
            let (nla, nlo, nt) = n + 1 < plan.retimed.count
                ? (track.lat[plan.retimed[n + 1].index], track.lon[plan.retimed[n + 1].index], plan.retimed[n + 1].time)
                : (track.lat[ib], track.lon[ib], track.time[ib])
            let dNext = GeoMath.haversine(la, lo, nla, nlo)
            out.append(FillPoint(lat: la, lon: lo, ele: track.ele[r.index], time: r.time,
                                 headingDeg: GeoMath.bearing(la, lo, nla, nlo),
                                 speedMps: nt > r.time ? dNext / (nt - r.time) : 0,
                                 distFromPrev: GeoMath.haversine(prevLat, prevLon, la, lo)))
            prevLat = la; prevLon = lo
        }
        return out.sorted { $0.time < $1.time }
    }

    /// 保留点新点的键（与 landingPoints 里的新点位级相同）
    static func keys(track: TrackData, plan: Plan) -> Set<GapFillExport.PointKey> {
        Set(plan.retimed.map { GapFillExport.PointKey($0.time, track.lat[$0.index], track.lon[$0.index]) })
    }
    /// 保留点旧点的键（旧时间；审阅图据此不把它们当「删除」画红）
    static func oldKeys(track: TrackData, plan: Plan) -> Set<GapFillExport.PointKey> {
        Set(plan.retimed.map { GapFillExport.PointKey(track.time[$0.index], track.lat[$0.index], track.lon[$0.index]) })
    }
}

/// 落地拼接：把若干补点（按锚点下标互不重叠）拼进当前轨迹，可选删掉区间内的点。
/// 轨迹已按时间有序，合成点时间严格在 (tA,tB) 内 → 结果仍有序，build 不需要重排
enum GapSplice {
    struct Job {
        let indexA: Int
        let indexB: Int             // > indexA
        let points: [FillPoint]
        let removeInner: Bool
        /// removeInner 时仍保留的区间内点（贴着路网折线的真实点，手机数据隧道群之间的准点）；合成点按时间混排
        var keep: Set<Int> = []
    }

    static func apply(to current: TrackData, jobs: [Job]) -> ParsedTrack {
        var p = applyBody(to: current, jobs: jobs)
        p.creator = current.creator            // 来源与精度随轨迹走，落地后采样画像不变
        p.accuracyMedian = current.gpsAccuracy
        return p
    }
    private static func applyBody(to current: TrackData, jobs: [Job]) -> ParsedTrack {
        let sorted = jobs.sorted { $0.indexA < $1.indexA }
        var p = ParsedTrack()
        let extra = sorted.reduce(0) { $0 + $1.points.count }
        p.lat.reserveCapacity(current.count + extra)
        p.lon.reserveCapacity(current.count + extra)
        p.ele.reserveCapacity(current.count + extra)
        p.time.reserveCapacity(current.count + extra)
        var i = 0
        for job in sorted {
            guard job.indexA >= i, job.indexB > job.indexA, job.indexB < current.count else { continue }
            // 原样复制到锚点 A（含）
            for k in i...job.indexA {
                p.lat.append(current.lat[k]); p.lon.append(current.lon[k])
                p.ele.append(current.ele[k]); p.time.append(current.time[k])
            }
            // 删区间内：直接跳到 B；保留：先把区间内的点原样复制（合成点按时间混排）
            if job.removeInner {
                var fi = 0
                for k in (job.indexA + 1)..<job.indexB where job.keep.contains(k) {
                    while fi < job.points.count, job.points[fi].time < current.time[k] {
                        let fp = job.points[fi]
                        p.lat.append(fp.lat); p.lon.append(fp.lon); p.ele.append(fp.ele); p.time.append(fp.time)
                        fi += 1
                    }
                    p.lat.append(current.lat[k]); p.lon.append(current.lon[k])
                    p.ele.append(current.ele[k]); p.time.append(current.time[k])
                }
                while fi < job.points.count {
                    let fp = job.points[fi]
                    p.lat.append(fp.lat); p.lon.append(fp.lon); p.ele.append(fp.ele); p.time.append(fp.time)
                    fi += 1
                }
            } else {
                var fi = 0
                for k in (job.indexA + 1)..<job.indexB {
                    while fi < job.points.count, job.points[fi].time < current.time[k] {
                        let fp = job.points[fi]
                        p.lat.append(fp.lat); p.lon.append(fp.lon); p.ele.append(fp.ele); p.time.append(fp.time)
                        fi += 1
                    }
                    p.lat.append(current.lat[k]); p.lon.append(current.lon[k])
                    p.ele.append(current.ele[k]); p.time.append(current.time[k])
                }
                while fi < job.points.count {
                    let fp = job.points[fi]
                    p.lat.append(fp.lat); p.lon.append(fp.lon); p.ele.append(fp.ele); p.time.append(fp.time)
                    fi += 1
                }
            }
            i = job.indexB
        }
        if i < current.count {
            for k in i..<current.count {
                p.lat.append(current.lat[k]); p.lon.append(current.lon[k])
                p.ele.append(current.ele[k]); p.time.append(current.time[k])
            }
        }
        p.name = current.name
        p.chunkCount = ProcessInfo.processInfo.activeProcessorCount
        return p
    }
}

enum GapFillExport {
    /// 点身份：合成点原样拼进轨迹，(time, lat, lon) 位级相等即同一点。
    /// 导出只认"记录里的合成点/锚点"，不按时间窗猜——保留的漂移点、相邻段共用的
    /// 锚点、同时间戳的邻点都不会被误当成新增点
    struct PointKey: Hashable {
        let t: UInt64, la: UInt64, lo: UInt64
        init(_ time: Double, _ lat: Double, _ lon: Double) {
            t = time.bitPattern; la = lat.bitPattern; lo = lon.bitPattern
        }
    }

    static func syntheticKeys(_ fills: [GapFill]) -> Set<PointKey> {
        var s = Set<PointKey>()
        for f in fills { for p in f.points { s.insert(PointKey(p.time, p.lat, p.lon)) } }
        return s
    }

    static func anchorKeys(_ fills: [GapFill]) -> Set<PointKey> {
        var s = Set<PointKey>()
        for f in fills {
            s.insert(PointKey(f.anchorA.time, f.anchorA.lat, f.anchorA.lon))
            s.insert(PointKey(f.anchorB.time, f.anchorB.lat, f.anchorB.lon))
        }
        return s
    }

    /// 合并补点记录的时间窗（重叠/相邻合并），只用来缩小扫描范围
    static func mergedWindows(_ fills: [GapFill]) -> [(Double, Double)] {
        let sorted = fills.map { ($0.tA, $0.tB) }.sorted { $0.0 < $1.0 }
        var out: [(Double, Double)] = []
        for w in sorted {
            if let last = out.last, w.0 <= last.1 {
                out[out.count - 1].1 = max(last.1, w.1)
            } else {
                out.append(w)
            }
        }
        return out
    }

    /// 轨迹里时间落在 [t0, t1]（含端点）的下标区间（时间有序前缀内二分）
    static func indexRange(track: TrackData, t0: Double, t1: Double) -> Range<Int> {
        let n = track.timedCount
        var lo = 0, hi = n
        while lo < hi { let m = (lo + hi) >> 1; if track.time[m] < t0 { lo = m + 1 } else { hi = m } }
        let a = lo
        lo = a; hi = n
        while lo < hi { let m = (lo + hi) >> 1; if track.time[m] <= t1 { lo = m + 1 } else { hi = m } }
        return a..<lo
    }

    /// 世界迷雾：每个时间窗一个 <trkseg>，按轨迹顺序写出窗内的锚点与仍存在的合成点
    /// （两端锚点必须带，否则两头各缺几格；被后来删掉的合成点自然不在轨迹里）。
    /// 只写经纬（有海拔则带上）；迷雾按相邻点连线解锁，不需要时间
    static func fogOfWorldGPX(track: TrackData, fills: [GapFill], name: String) -> String {
        let syn = syntheticKeys(fills), anc = anchorKeys(fills)
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="GPXPointViewer gap-fill" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(xmlEscape(name))</name>

        """
        for w in mergedWindows(fills) {
            var seg = ""
            var n = 0
            for i in indexRange(track: track, t0: w.0, t1: w.1) {
                let k = PointKey(track.time[i], track.lat[i], track.lon[i])
                guard syn.contains(k) || anc.contains(k) else { continue }
                seg += trkpt(track.lat[i], track.lon[i], track.ele[i])
                n += 1
            }
            guard n >= 2 else { continue }
            s += "    <trkseg>\n" + seg + "    </trkseg>\n"
        }
        s += "  </trk>\n</gpx>\n"
        return s
    }

    private static func trkpt(_ lat: Double, _ lon: Double, _ ele: Double) -> String {
        var line = "      <trkpt lat=\"\(fmt(lat, 7))\" lon=\"\(fmt(lon, 7))\">"
        if ele.isFinite { line += "<ele>\(fmt(ele, 1))</ele>" }
        return line + "</trkpt>\n"
    }

    /// 一生足迹增量 CSV：只含仍在轨迹里的合成点（绝不含锚点与任何原始点），原生 11 列，
    /// dataTime 整数秒严格递增（同秒只留第一个）。航向/速度/距离按轨迹里的前一点现算；
    /// 非几何列用社区实测可导入的占位值
    static func stepLifeCSV(track: TrackData, fills: [GapFill]) -> String {
        let syn = syntheticKeys(fills)
        var s = "dataTime,locType,longitude,latitude,heading,accuracy,speed,distance,isBackForeground,stepType,altitude\n"
        var lastSec = Int.min
        for w in mergedWindows(fills) {
            for i in indexRange(track: track, t0: w.0, t1: w.1) {
                guard i > 0, syn.contains(PointKey(track.time[i], track.lat[i], track.lon[i])) else { continue }
                let sec = Int(floor(track.time[i]))
                guard sec > lastSec else { continue }
                lastSec = sec
                let d = GeoMath.haversine(track.lat[i - 1], track.lon[i - 1], track.lat[i], track.lon[i])
                let dt = track.time[i] - track.time[i - 1]
                let speed = dt > 0 ? d / dt : 0
                let heading = GeoMath.bearing(track.lat[i - 1], track.lon[i - 1], track.lat[i], track.lon[i])
                let ele = track.ele[i].isFinite ? track.ele[i] : 0
                s += "\(sec),1,\(fmt(track.lon[i], 6)),\(fmt(track.lat[i], 6)),\(fmt(heading, 6)),10.000000,\(fmt(speed, 6)),\(fmt(d, 6)),1,0,\(fmt(ele, 6))\n"
            }
        }
        return s
    }

    /// 整条轨迹导出一生足迹 CSV（Garmin 等外部轨迹首次导入时用）：同秒只留第一个
    static func stepLifeCSVWholeTrack(track: TrackData) -> String {
        var s = "dataTime,locType,longitude,latitude,heading,accuracy,speed,distance,isBackForeground,stepType,altitude\n"
        var lastSec = Int.min
        for i in 0..<track.timedCount {
            let sec = Int(floor(track.time[i]))
            guard sec > lastSec else { continue }
            lastSec = sec
            let d = i > 0 ? GeoMath.haversine(track.lat[i - 1], track.lon[i - 1], track.lat[i], track.lon[i]) : 0
            let dt = i > 0 ? track.time[i] - track.time[i - 1] : 0
            let speed = dt > 0 ? d / dt : 0
            let heading = i > 0 ? GeoMath.bearing(track.lat[i - 1], track.lon[i - 1], track.lat[i], track.lon[i]) : 0
            let ele = track.ele[i].isFinite ? track.ele[i] : 0
            s += "\(sec),1,\(fmt(track.lon[i], 6)),\(fmt(track.lat[i], 6)),\(fmt(heading, 6)),10.000000,\(fmt(speed, 6)),\(fmt(d, 6)),1,0,\(fmt(ele, 6))\n"
        }
        return s
    }

    private static func fmt(_ v: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", v)
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

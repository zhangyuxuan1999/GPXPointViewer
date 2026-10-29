import Foundation
import CoreLocation

// synthrunner <file>...
// 对每个文件跑一遍与 App 相同的检测流水线（TrackStore.refreshGapCandidates，fillJitter / fillMergeChains 取默认 true），
// 每个文件打印一行 JSON 到 stdout：
//   {"file":..., "points":N, "timed":N, "profile":"deviceLogger|phone|unknown", "gaps":N, "stale":N, "replays":N,
//    "jitter":[{"tA","tB","inner","jumps","revs","meters",...}], "merged":N, "trips":N, "ms":{"load","detect","replay","jitter",...}, ...}
// 解析抛错时：{"file":..., "error":"...", "stage":"read|parse"}（退出码仍为 0）。
// Swift 运行时陷阱（越界、溢出、强制解包）无法捕获——由 check.py 按子进程退出信号报 crash；
// 为了定位，每进入一个阶段往 stderr 写一行 "@stage <name>"，崩溃时 check.py 取最后一行。
setbuf(stdout, nil)
setbuf(stderr, nil)

// MARK: - 有序 JSON（键序与说明一致；非有限数写 null，避免 JSONSerialization 抛 ObjC 异常）

indirect enum J {
    case s(String), d(Double), i(Int), b(Bool), null, a([J]), o([(String, J)])
}

func esc(_ s: String) -> String {
    var out = "\""
    out.reserveCapacity(s.utf8.count + 2)
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if u.value < 0x20 || u.value == 0x7F || u.value == 0x2028 || u.value == 0x2029 {
                out += String(format: "\\u%04x", u.value)
            } else {
                out.unicodeScalars.append(u)
            }
        }
    }
    return out + "\""
}

func enc(_ j: J, into out: inout String) {
    switch j {
    case .s(let s): out += esc(s)
    case .d(let d):
        if !d.isFinite { out += "null" }
        else if d == d.rounded(), abs(d) < 1e15 { out += String(Int64(d)) }
        else { out += "\(d)" }
    case .i(let i): out += String(i)
    case .b(let b): out += b ? "true" : "false"
    case .null: out += "null"
    case .a(let xs):
        out += "["
        for (k, x) in xs.enumerated() { if k > 0 { out += "," }; enc(x, into: &out) }
        out += "]"
    case .o(let kv):
        out += "{"
        for (k, (key, v)) in kv.enumerated() { if k > 0 { out += "," }; out += esc(key); out += ":"; enc(v, into: &out) }
        out += "}"
    }
}

func emit(_ j: J) {
    var s = ""
    enc(j, into: &s)
    s += "\n"
    FileHandle.standardOutput.write(s.data(using: .utf8)!)
}

func stage(_ s: String) {
    FileHandle.standardError.write(("@stage " + s + "\n").data(using: .utf8)!)
}

@inline(__always) func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ a: UInt64, _ b: UInt64) -> J { .d((Double(b &- a) / 1e4).rounded() / 100) }   // 0.01 ms 精度

func kindName(_ k: SamplingProfile.Kind) -> String {
    switch k {
    case .deviceLogger: return "deviceLogger"
    case .phone: return "phone"
    case .unknown: return "unknown"
    }
}

func candKind(_ k: GapCandidate.Kind) -> String {
    switch k {
    case .timeGap: return "timeGap"
    case .staleClock: return "staleClock"
    case .jitter: return "jitter"
    }
}

func r1(_ x: Double) -> J { x.isFinite ? .d((x * 10).rounded() / 10) : .null }

/// 列表上限：防止病态输入把一行 JSON 撑到几百 MB；计数字段始终是全量
let listCap = Int(ProcessInfo.processInfo.environment["SYNTH_LIST_CAP"] ?? "") ?? 5000

func candJSON(_ c: GapCandidate, jitter: Bool, track: TrackData) -> J {
    var kv: [(String, J)] = [
        ("tA", .d(c.tA)), ("tB", .d(c.tB)),
        ("iA", .i(c.indexA)), ("iB", .i(c.indexB)),
        ("inner", .i(c.innerCount)),
        ("segment", .i(Int(c.segment))),
        ("segmentA", .i(Int(track.topology.segment(of: c.indexA)))),
        ("segmentB", .i(Int(track.topology.segment(of: c.indexB)))),
        ("pathA", .i(track.topology.pathRank(of: c.indexA))),
        ("pathB", .i(track.topology.pathRank(of: c.indexB))),
        ("nextInSegment", track.topology.adjacent(to: c.indexA, direction: 1).map { .i($0) } ?? .null),
    ]
    if jitter {
        kv += [("jumps", .i(c.jitterJumps)), ("revs", .i(c.jitterReversals)), ("maxJump", r1(c.jitterMaxJump))]
    } else {
        kv.insert(("kind", .s(candKind(c.kind))), at: 0)
    }
    kv += [("meters", r1(c.meters)), ("kmh", r1(c.kmh))]
    if c.chainCount > 1 { kv.append(("chain", .i(c.chainCount))) }
    if c.frozenA > 0 { kv.append(("frozenA", .i(c.frozenA))) }     // 只在 >0 时输出，合成套件的期望不受影响
    return .o(kv)
}

func errorJSON(_ path: String, _ stageName: String, _ error: Error) -> J {
    var msg = error.localizedDescription
    let raw = String(describing: error)
    if !msg.contains(raw) { msg += " [\(raw)]" }
    return .o([("file", .s(path)), ("error", .s(msg)), ("stage", .s(stageName))])
}

func run(_ path: String) -> J {
    let name = (path as NSString).lastPathComponent
    stage("read \(name)")
    let tRead = now()
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    } catch {
        return errorJSON(path, "read", error)
    }
    stage("parse")
    let tParse = now()
    var parsed: ParsedTrack
    do {
        parsed = try GPXParser.parse(data: data)
    } catch {
        return errorJSON(path, "parse", error)
    }
    parsed.name = name
    stage("build")
    let tBuild = now()
    let track = TrackData.build(parsed: parsed, preferredMode: .single).0
    let tLoaded = now()

    stage("profile")
    let profile = SamplingProfile.compute(track: track, creator: track.creator, accuracy: track.gpsAccuracy)
    var opt = GapDetector.Options()
    opt.staleEnabled = profile.kind == .deviceLogger      // 与 TrackStore 一致：过时时钟只在专用记录仪上找
    let profilesBySegment = SamplingProfile.bySegment(track: track, creator: track.creator, accuracy: track.gpsAccuracy)
    let tProfile = now()

    stage("detect")
    // 与 TrackStore.computeCandidates 一致：detect 之后做 A 侧冻结假点链前移（只对专用记录仪的 staleClock）
    let gaps = GapDetector.shiftFrozenChains(track: track, candidates: GapDetector.detect(track: track, options: opt, profiles: profilesBySegment), profile: profile)
    let tDetect = now()

    stage("replay")
    let flags = GapDetector.replayFlags(track: track)
    var nRep = 0
    for f in flags where f { nRep += 1 }
    let tReplay = now()

    stage("jitter")
    let jit = GapDetector.detectJitter(track: track, profile: profile, replay: nRep > 0 ? flags : nil, options: opt, profiles: profilesBySegment)
    let tJitter = now()

    // App 流水线（TrackStore.refreshGapCandidates）：整个包住已有候选的乱跳簇取代它；只部分重叠的乱跳簇不要；
    // 再只并「信号中断」的相邻处
    stage("merge")
    var cands = gaps
    var jitterKept = 0
    if !jit.isEmpty {
        // 与 TrackStore.computeCandidates 同口径：部分重叠（非整个包住）的簇不要；共用端点不算重叠；剩下的簇取代被它包住的候选
        func encloses(_ j: GapCandidate, _ c: GapCandidate) -> Bool { j.trackID == c.trackID && j.segment == c.segment && (j.pathA ?? j.indexA) <= (c.pathA ?? c.indexA) && (j.pathB ?? j.indexB) >= (c.pathB ?? c.indexB) }
        func overlaps(_ j: GapCandidate, _ c: GapCandidate) -> Bool { j.trackID == c.trackID && j.segment == c.segment && (j.pathA ?? j.indexA) < (c.pathB ?? c.indexB) && (j.pathB ?? j.indexB) > (c.pathA ?? c.indexA) }
        let survivors = jit.filter { j in !cands.contains { c in overlaps(j, c) && !encloses(j, c) } }
        var kept = cands.filter { c in !survivors.contains { encloses($0, c) } }
        let fresh = survivors
        jitterKept = fresh.count
        kept += fresh
        cands = kept.sorted { $0.indexA < $1.indexA }
    }
    var nature: [GapID: GapNature] = [:]
    var lol = 0
    for c in cands {
        let nat = GapRouteInputs.localSampling(track, ia: c.indexA, ib: c.indexB, profile: profilesBySegment[c.segment] ?? profile).nature
        nature[c.id] = nat
        if nat == .lossOfLock { lol += 1 }
    }
    let merged = GapDetector.mergeChains(cands) { nature[$0.id] == .lossOfLock && nature[$1.id] == .lossOfLock }
    let tMerge = now()

    stage("trips")
    let trips = TripSegmenter.trips(track: track)
    let tTrips = now()
    stage("encode")

    let nStale = gaps.filter { $0.kind == .staleClock }.count
    var mergedKinds: [String: Int] = [:]
    for c in merged { mergedKinds[candKind(c.kind), default: 0] += 1 }

    var kv: [(String, J)] = []
    kv.append(("file", .s(path)))
    kv.append(("topology_version", .i(1)))
    kv.append(("segment_count", .i(track.topology.segments.count)))
    kv.append(("points", .i(track.count)))
    kv.append(("timed", .i(track.timedCount)))
    kv.append(("profile", .s(kindName(profile.kind))))
    kv.append(("gaps", .i(gaps.count)))
    kv.append(("stale", .i(nStale)))
    kv.append(("replays", .i(nRep)))
    let jitList: [J] = jit.prefix(listCap).map { candJSON($0, jitter: true, track: track) }
    kv.append(("jitter", .a(jitList)))
    kv.append(("merged", .i(merged.count)))
    kv.append(("trips", .i(trips.count)))
    var msKV: [(String, J)] = []
    msKV.append(("load", ms(tRead, tLoaded)))
    msKV.append(("detect", ms(tProfile, tDetect)))
    msKV.append(("replay", ms(tDetect, tReplay)))
    msKV.append(("jitter", ms(tReplay, tJitter)))
    msKV.append(("read", ms(tRead, tParse)))
    msKV.append(("parse", ms(tParse, tBuild)))
    msKV.append(("build", ms(tBuild, tLoaded)))
    msKV.append(("profile", ms(tLoaded, tProfile)))
    msKV.append(("merge", ms(tJitter, tMerge)))
    msKV.append(("trips", ms(tMerge, tTrips)))
    msKV.append(("total", ms(tRead, tTrips)))
    kv.append(("ms", .o(msKV)))
    // —— 以下为附加信息（check.py 的扩展检查与排错用）——
    kv.append(("timegap", .i(gaps.count - nStale)))
    kv.append(("jitter_count", .i(jit.count)))
    kv.append(("jitter_kept", .i(jitterKept)))
    kv.append(("candidates", .i(cands.count)))
    kv.append(("loss_of_lock", .i(lol)))
    let mk: [(String, J)] = mergedKinds.sorted { $0.key < $1.key }.map { ($0.key, J.i($0.value)) }
    kv.append(("merged_kinds", .o(mk)))
    var pd: [(String, J)] = []
    pd.append(("creator", .s(profile.creator)))
    pd.append(("accuracy", profile.accuracy.map { r1($0) } ?? .null))
    pd.append(("medianDt", r1(profile.medianDt)))
    pd.append(("q90Dt", r1(profile.q90Dt)))
    pd.append(("medianStep", r1(profile.medianStep)))
    pd.append(("q90Step", r1(profile.q90Step)))
    pd.append(("samples", .i(profile.sampleCount)))
    kv.append(("profile_detail", .o(pd)))
    let gapList: [J] = gaps.prefix(listCap).map { candJSON($0, jitter: false, track: track) }
    kv.append(("gap_list", .a(gapList)))
    let mergedList: [J] = merged.prefix(listCap).map { candJSON($0, jitter: $0.kind == .jitter, track: track) }
    kv.append(("merged_list", .a(mergedList)))
    var tripList: [J] = []
    for tr in trips.prefix(listCap) {
        var tk: [(String, J)] = []
        tk.append(("tStart", .d(tr.tStart)))
        tk.append(("tEnd", .d(tr.tEnd)))
        tk.append(("segment", .i(Int(tr.segment))))
        tk.append(("pathStart", .i(tr.pathRange.lowerBound)))
        tk.append(("pathEnd", .i(tr.pathRange.upperBound)))
        tk.append(("iStart", .i(track.topology.globalIndex(atPathRank: tr.pathRange.lowerBound))))
        tk.append(("iLast", .i(track.topology.globalIndex(atPathRank: tr.pathRange.upperBound - 1))))
        // Legacy global envelope; exact source membership is segment + pathStart..<pathEnd.
        tk.append(("iEnd", .i(track.topology.globalIndex(atPathRank: tr.pathRange.upperBound - 1) + 1)))
        tk.append(("km", r1(tr.km)))
        tk.append(("v50", r1(tr.v50)))
        tk.append(("v95", r1(tr.v95)))
        tripList.append(.o(tk))
    }
    kv.append(("trip_list", .a(tripList)))
    if track.timedCount > 0 {
        kv.append(("time_range", .a([.d(track.time[0]), .d(track.time[track.timedCount - 1])])))
    } else {
        kv.append(("time_range", .null))
    }
    return .o(kv)
}

// MARK: - 精确模式几何比对自测（synthrunner --crosscheck-selftest）
// 合成两条折线跑 RouteCrossCheck.compare（容差固定 10 m，规则见 RoadNetwork.swift）：
// 同一条路（含抽稀、单个离群节点、末端渐进靠拢差异、路口渠化几十米差异、弦与弧弓高 5 m）必须判一致，
// 同向平行路（12–30 m，各长度）/ 平行匝道 / 一方外推锚点 / 长断档中段换路 / 往返 / 另一条路 必须判不一致。
// 每个用例一行 JSON，有不符的退出码 1
func crossCheckSelfTest() -> Int32 {
    let lat0 = 48.0, lon0 = 8.0
    let ky = 110_540.0, kx = 111_320.0 * cos(lat0 * .pi / 180)
    func pt(_ x: Double, _ y: Double) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat0 + y / ky, longitude: lon0 + x / kx) }
    /// 东向缓弯道路：x 每 step 米一个节点，y = amp·sin(x/period) + offset
    func road(_ length: Double, step: Double = 50, amp: Double = 60, period: Double = 900, offset: Double = 0, from x0: Double = 0) -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        var x = x0
        while x <= length + 1e-9 { out.append(pt(x, amp * sin(x / period) + offset)); x += step }
        if let last = out.last, abs(last.longitude - pt(length, 0).longitude) > 1e-9 { out.append(pt(length, amp * sin(length / period) + offset)) }
        return out
    }
    /// 中段 [x1, x2] 平移 off 米的版本
    func roadBump(_ length: Double, step: Double = 50, amp: Double = 60, period: Double = 900, from x1: Double, to x2: Double, off: Double) -> [CLLocationCoordinate2D] {
        road(length, step: step, amp: amp, period: period).enumerated().map { i, c in
            let x = Double(i) * step
            return (x >= x1 && x <= x2) ? pt(x, amp * sin(x / period) + off) : c
        }
    }
    struct Case { let name: String; let p: [CLLocationCoordinate2D]; let q: [CLLocationCoordinate2D]; let expect: Bool }
    let L = 2000.0
    let base = road(L)
    var cases: [Case] = []
    cases.append(Case(name: "identical", p: base, q: base, expect: true))
    cases.append(Case(name: "simplified_every_other_node", p: base, q: base.enumerated().filter { $0.offset % 2 == 0 || $0.offset == base.count - 1 }.map(\.element), expect: true))
    cases.append(Case(name: "coarse_nodes_200m", p: base, q: road(L, step: 200), expect: true))
    // 单个离群节点：同一条路的两份几何都来自 OSM 节点，一个节点偏 15 m 以内算抽稀/取整差异（一致）；偏 30 m 说明是另一条 way（不一致）
    var stray = base; stray[20] = pt(1000, 60 * sin(1000 / 900) + 15)
    cases.append(Case(name: "one_stray_node_15m", p: base, q: stray, expect: true))
    var stray30 = base; stray30[20] = pt(1000, 60 * sin(1000 / 900) + 30)
    cases.append(Case(name: "one_stray_node_30m_flagged", p: base, q: stray30, expect: false))
    // 同向平行路：间距 12/15/20/30 m × 长度 300/1000 m → 全部不一致（容差与 GPS 半径无关）
    for gap in [12.0, 15.0, 20.0, 30.0] {
        for len in [300.0, 1000.0] {
            cases.append(Case(name: "parallel_\(Int(gap))m_\(Int(len))m", p: road(len, step: 25), q: road(len, step: 25, offset: gap), expect: false))
        }
    }
    // 分辨率下限：间距 9 m 判一致（记录行为）
    cases.append(Case(name: "parallel_9m_1000m_resolution_limit", p: road(1000, step: 25), q: road(1000, step: 25, offset: 9), expect: true))
    // 平行匝道：前 300 m 偏 40 m 后汇入
    let ramp = base.enumerated().map { i, c -> CLLocationCoordinate2D in let x = Double(i) * 50; return x < 300 ? pt(x, 60 * sin(x / 900) + 40 * (1 - x / 300)) : c }
    cases.append(Case(name: "parallel_ramp_300m_40m", p: base, q: ramp, expect: false))
    // 一方外推锚点：P 从 x=-150 开始
    cases.append(Case(name: "one_side_shifted_anchor_150m", p: road(L, from: -150), q: base, expect: false))
    // 另一条路
    let detour = [pt(0, 0), pt(300, 400), pt(1000, 900), pt(1700, 400), pt(2000, 60 * sin(2000 / 900))]
    cases.append(Case(name: "different_road", p: base, q: detour, expect: false))
    cases.append(Case(name: "both_straight", p: [pt(0, 0), pt(120, 0)], q: [pt(0, 0), pt(120, 0)], expect: true))
    let shortP = road(120, step: 20)
    cases.append(Case(name: "short_gap_5m_noise", p: shortP, q: road(120, step: 20, offset: 5), expect: true))
    cases.append(Case(name: "short_gap_opposite_25m", p: shortP, q: road(120, step: 20, offset: 25), expect: false))
    cases.append(Case(name: "short_gap_150m_parallel_20m", p: road(150, step: 10), q: road(150, step: 10, offset: 20), expect: false))
    // 长 30 km 抽稀 → 一致
    cases.append(Case(name: "long_30km_coarse", p: road(30_000, step: 50, amp: 200, period: 3000), q: road(30_000, step: 250, amp: 200, period: 3000), expect: true))
    // 10 km 中段 300 m 偏 25 m → 不一致；80 km 中段 1.2 km 偏 150 m → 不一致
    cases.append(Case(name: "10km_mid_300m_off25", p: road(10_000, amp: 100, period: 2000), q: roadBump(10_000, amp: 100, period: 2000, from: 5000, to: 5300, off: 25), expect: false))
    cases.append(Case(name: "80km_mid_1200m_off150", p: road(80_000, step: 100, amp: 300, period: 5000), q: roadBump(80_000, step: 100, amp: 300, period: 5000, from: 40_000, to: 41_200, off: 150), expect: false))
    // 5 km 路上 30 m 长、偏 12 m 的路口渠化差异 → 一致
    cases.append(Case(name: "5km_junction_30m_off12", p: road(5000, step: 10), q: roadBump(5000, step: 10, from: 2500, to: 2530, off: 12), expect: true))
    // 20 km 路上 400 m 往返（P 多出一段去而复返的支线）→ 不一致
    var spur = road(20_000, step: 50, amp: 100, period: 2000)
    let k = 200
    let fork = spur[k]
    let spurPts = (1...8).map { pt(10_000, 100 * sin(10_000 / 2000) + Double($0) * 50) }
    spur.insert(contentsOf: spurPts + spurPts.reversed() + [fork], at: k + 1)
    cases.append(Case(name: "20km_spur_400m_out_and_back", p: spur, q: road(20_000, step: 50, amp: 100, period: 2000), expect: false))
    // 弦 vs 弧：2 km 直连 对 弓高 5 m 的弧 → 一致；弓高 30 m → 不一致
    func arc(_ sagitta: Double) -> [CLLocationCoordinate2D] { stride(from: 0.0, through: L, by: 25).map { x in pt(x, sagitta * sin(.pi * x / L)) } }
    cases.append(Case(name: "chord_vs_arc_sagitta5", p: [pt(0, 0), pt(L, 0)], q: arc(5), expect: true))
    cases.append(Case(name: "chord_vs_arc_sagitta30", p: [pt(0, 0), pt(L, 0)], q: arc(30), expect: false))
    // 末端渐进靠拢差异：一方 taper（锚点离路 ≥8 m 才做）、另一方不做，同路最坏相差 ≈8–9 m → 末 200 m 斜到 9 m 判一致；斜到 15 m 不一致
    func taperTo(_ d: Double) -> [CLLocationCoordinate2D] { base.enumerated().map { i, c in let x = Double(i) * 50; return x > L - 200 ? pt(x, 60 * sin(x / 900) + d * (x - (L - 200)) / 200) : c } }
    cases.append(Case(name: "taper_difference_9m", p: base, q: taperTo(9), expect: true))
    cases.append(Case(name: "taper_difference_15m_flagged", p: base, q: taperTo(15), expect: false))
    var bad = 0
    for cs in cases {
        let t0 = now()
        let r = RouteCrossCheck.compare(cs.p, cs.q, tol: RouteCrossCheck.tolerance)
        let ok = r.agree == cs.expect
        if !ok { bad += 1 }
        emit(.o([("case", .s(cs.name)), ("agree", .b(r.agree)), ("expect", .b(cs.expect)), ("ok", .b(ok)),
                 ("maxRun", .d(r.divergence.rounded())), ("uncoveredP", .d(r.uncoveredP.rounded())), ("uncoveredQ", .d(r.uncoveredQ.rounded())),
                 ("maxDev", .d(r.maxDev.rounded())), ("lenP", .d(r.lenP.rounded())), ("lenQ", .d(r.lenQ.rounded())),
                 ("reasons", .a(r.reasons.map { .s($0) })), ("ms", ms(t0, now()))]))
    }
    // 两份草稿（外推不同）：几何原因只比内段
    let dA = RouteDraft(source: .osrmCar, coords: Array(road(L, from: -150).dropFirst().dropLast()), meters: L + 150, snapA: 0, snapB: 0, endpoint: "t", warnings: [], shiftA: 3, anchorA: pt(-150, 60 * sin(-150 / 900)))
    let dB = RouteDraft(source: .valhallaCar, coords: Array(base.dropFirst().dropLast()), meters: L, snapA: 0, snapB: 0, endpoint: "t", warnings: [])
    let rs = RouteCrossCheck.compare(dA, dB, a: pt(0, 0), b: pt(L, 60 * sin(L / 900)))
    let shiftOK = !rs.agree && rs.reasons.count == 1 && rs.reasons[0].contains("中间路段几何一致")
    if !shiftOK { bad += 1 }
    emit(.o([("case", .s("drafts_shift_differs_inner_agrees")), ("agree", .b(rs.agree)), ("expect", .b(false)), ("ok", .b(shiftOK)), ("reasons", .a(rs.reasons.map { .s($0) }))]))
    return bad == 0 ? 0 : 1
}
if CommandLine.arguments.contains("--crosscheck-selftest") { exit(crossCheckSelfTest()) }

// MARK: - 隧道口裁剪/靠拢自测（synthrunner --portal-selftest [fixturesDir]）
// 走与 carRoute 的 finish 相同的顺序：PortalDrift.analyze → clip → RoadNetwork.trimEnds → trimExcursion → taper。
// 真实夹具（Muenchen_Roma_Garmin 第 14/16/19 处，OSRM 上下文路由原始几何 + Overpass way 节点）：trimEnds 不得删掉
// 稀疏隧道 way 上的裁剪投影点、taper 不得把起始段推离路网；合成反例：锚点真离路 40 m 仍要渐进靠拢、锚点旁打小折的近点仍要删。
// 每个用例一行 JSON，有不符的退出码 1；fixturesDir 默认 Tests/synth/fixtures/tunnel（相对 cwd）
func portalSelfTest() -> Int32 {
    let args = CommandLine.arguments
    var dir = "Tests/synth/fixtures/tunnel"
    if let k = args.firstIndex(of: "--portal-selftest"), k + 1 < args.count, !args[k + 1].hasPrefix("--") { dir = args[k + 1] }
    func c(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    func dist(_ x: CLLocationCoordinate2D, _ y: CLLocationCoordinate2D) -> Double { GeoMath.haversine(x.latitude, x.longitude, y.latitude, y.longitude) }
    func brg(_ x: CLLocationCoordinate2D, _ y: CLLocationCoordinate2D) -> Double { GeoMath.bearing(x.latitude, x.longitude, y.latitude, y.longitude) }
    func loadRoute(_ name: String) -> [CLLocationCoordinate2D]? {
        guard let data = FileManager.default.contents(atPath: dir + "/" + name),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = j["routes"] as? [[String: Any]], let g = routes.first?["geometry"] as? [String: Any],
              let cs = g["coordinates"] as? [[NSNumber]] else { return nil }
        return cs.map { c($0[1].doubleValue, $0[0].doubleValue) }
    }
    let ways: [String: [CLLocationCoordinate2D]] = {
        guard let data = FileManager.default.contents(atPath: dir + "/osm_ways_16_19.json"),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: [[NSNumber]]] else { return [:] }
        return j.mapValues { $0.map { c($0[0].doubleValue, $0[1].doubleValue) } }
    }()
    /// 点到一组折线的最小距离（米）
    func distToWays(_ p: CLLocationCoordinate2D, _ polys: [[CLLocationCoordinate2D]]) -> Double {
        let f = PortalDrift.Frame(origin: p)
        return polys.map { PortalDrift.Poly($0, frame: f).project(f.xy(p)).d }.min() ?? .infinity
    }
    struct Out { var coords: [CLLocationCoordinate2D]; var clipped: [CLLocationCoordinate2D]; var trimmed: [CLLocationCoordinate2D]; var snapA: Double; var snapB: Double; var taperA: Double; var taperB: Double; var notes: [String] }
    /// carRoute finish 同序：tolOn 15 / tolDrift 22.5（匹配半径 15）、portal 样本为空、minOffset 15、步长 28
    func pipeline(_ raw: [CLLocationCoordinate2D], a: CLLocationCoordinate2D, b: CLLocationCoordinate2D, bearingA: Double?, bearingB: Double?) -> Out? {
        let an = PortalDrift.analyze(raw: raw, a: a, b: b, portalA: [], portalB: [], tolOn: 15, tolDrift: 22.5, bearingA: bearingA, bearingB: bearingB)
        guard let cl = PortalDrift.clip(raw: raw, a: a, b: b, arcA: an.arcA, arcB: an.arcB) else { return nil }
        let tr = RoadNetwork.trimEnds(cl.coords, a: a, b: b, stepA: 28, stepB: 28)
        let ex = PortalDrift.trimExcursion(tr, a: a, b: b, bearingA: bearingA, bearingB: bearingB)
        func same(_ x: CLLocationCoordinate2D?, _ y: CLLocationCoordinate2D?) -> Bool { x != nil && y != nil && x!.latitude == y!.latitude && x!.longitude == y!.longitude }
        let tp = PortalDrift.taper(ex.coords, a: a, b: b, dA: same(ex.coords.first, tr.first) ? cl.snapA : nil, dB: same(ex.coords.last, tr.last) ? cl.snapB : nil, minOffset: 15)
        return Out(coords: tp.coords, clipped: cl.coords, trimmed: ex.coords, snapA: cl.snapA, snapB: cl.snapB, taperA: tp.dA, taperB: tp.dB, notes: an.notes + ex.notes + tp.notes)
    }
    func r1(_ x: Double) -> J { x.isFinite ? .d((x * 10).rounded() / 10) : .null }
    var bad = 0
    func report(_ name: String, ok: Bool, _ kv: [(String, J)]) {
        if !ok { bad += 1 }
        emit(.o([("case", .s(name)), ("ok", .b(ok))] + kv))
    }

    // 第 14 处（A22 Tusch 隧道）：a = trkpt 9732、b = trkpt 9734（data/compare/Muenchen_Roma_Garmin.gpx，从 0 数）；
    // 方向用相邻真实点：9731→9732、9734→9735
    do {
        let a = c(46.50340092182159, 11.4571932554245), b = c(46.50194931030273, 11.4545156955719)
        let p9731 = c(46.50358068943024, 11.45746099948883), p9735 = c(46.5017386674881, 11.45427918434143)
        if let raw = loadRoute("gap14_osrm_ctx.json"), let o = pipeline(raw, a: a, b: b, bearingA: brg(p9731, a), bearingB: brg(b, p9735)) {
            let want0 = c(46.503487, 11.457094)
            let d0 = o.coords.first.map { dist($0, want0) } ?? .infinity
            // 理想折线：A 投影、节点 9194517、9193813、2430268940、B 投影
            let f = PortalDrift.Frame(origin: a)
            let bProj = f.coord(PortalDrift.Poly(raw, frame: f).project(f.xy(b)).pt)
            let ideal = [want0, c(46.502613, 11.455508), c(46.502288, 11.455055), c(46.502122, 11.454843), bProj]
            let fa = FillAnchor(lat: a.latitude, lon: a.longitude, ele: .nan, time: 0)
            let fb = FillAnchor(lat: b.latitude, lon: b.longitude, ele: .nan, time: 9)
            let fill = FillPath.interpolate(a: fa, vertices: o.coords, b: fb, spacingMeters: 29)
            let devs = fill.map { distToWays(c($0.lat, $0.lon), [ideal]) }
            let maxDev = devs.max() ?? .infinity
            let bad32 = o.notes.contains { $0.contains("A 离路 32") }
            let ok = d0 <= 5 && fill.count == 8 && maxDev <= 3 && !bad32
            report("gap14_tusch_9732_9734", ok: ok, [("first_to_A_proj_m", r1(d0)), ("expect_first_le", .d(5)), ("fill_n", .i(fill.count)),
                   ("fill_dev_m", .a(devs.map(r1))), ("expect_dev_le", .d(3)), ("coords_before_taper", .i(o.trimmed.count)), ("coords_after_taper", .i(o.coords.count)),
                   ("clip_n", .i(o.clipped.count)), ("snapA", r1(o.snapA)), ("snapB", r1(o.snapB)), ("taperA", r1(o.taperA)), ("taperB", r1(o.taperB)),
                   ("notes", .a(o.notes.map { .s($0) }))])
        } else { report("gap14_tusch_9732_9734", ok: false, [("error", .s("fixture/clip failed"))]) }
    }
    // 第 16 处（Trento）a = trkpt 12013、b = trkpt 12015，方向 12012→12013、12015→12016，way 23882756 + 23882762；
    // 第 19 处（Monzuno）a = trkpt 20893、b = trkpt 20895，方向 20892→20893、20895→20896，way 155056885 + 155056896 + 296778992
    let real: [(name: String, file: String, a: CLLocationCoordinate2D, b: CLLocationCoordinate2D, pa: CLLocationCoordinate2D, pb: CLLocationCoordinate2D, ways: [String])] = [
        ("gap16_trento_12013_12015", "gap15_osrm_ctx.json", c(46.07210099697113, 11.107547402381897), c(46.064438700675964, 11.110057950019836),
         c(46.072293519973755, 11.10750126838684), c(46.0642511844635, 11.110116958618164), ["23882756", "23882762"]),
        ("gap19_monzuno_20893_20895", "gap18_osrm_ctx.json", c(44.321520924568176, 11.25327980518341), c(44.311159491539, 11.250449299812317),
         c(44.32175254821777, 11.253421187400818), c(44.31091833114624, 11.250398993492126), ["155056885", "155056896", "296778992"]),
    ]
    for t in real {
        let polys = t.ways.compactMap { ways[$0] }
        guard polys.count == t.ways.count, let raw = loadRoute(t.file), let o = pipeline(raw, a: t.a, b: t.b, bearingA: brg(t.pa, t.a), bearingB: brg(t.b, t.pb)) else {
            report(t.name, ok: false, [("error", .s("fixture/clip failed"))]); continue
        }
        let devs = o.coords.map { distToWays($0, polys) }
        let maxDev = devs.max() ?? .infinity
        report(t.name, ok: !o.coords.isEmpty && maxDev <= 10, [("vertex_to_osm_m", .a(devs.map(r1))), ("max_m", r1(maxDev)), ("expect_max_le", .d(10)),
               ("coords_before_taper", .i(o.trimmed.count)), ("coords_after_taper", .i(o.coords.count)), ("snapA", r1(o.snapA)), ("snapB", r1(o.snapB)),
               ("taperA", r1(o.taperA)), ("taperB", r1(o.taperB)), ("notes", .a(o.notes.map { .s($0) }))])
    }

    // 合成（东向直路，局部平面米坐标）
    let lat0 = 48.0, lon0 = 8.0
    let ky = 110_540.0, kx = 111_320.0 * cos(lat0 * .pi / 180)
    func pt(_ x: Double, _ y: Double) -> CLLocationCoordinate2D { c(lat0 + y / ky, lon0 + x / kx) }
    let straight = stride(from: 0.0, through: 1000, by: 50).map { pt($0, 0) }
    // 反例 1：A 真离路 40 m（垂直偏移）→ 仍要渐进靠拢，d ≈ 40，首点不再是投影点
    do {
        let a = pt(100, 40), b = pt(900, 0)
        if let o = pipeline(straight, a: a, b: b, bearingA: 90, bearingB: 90) {
            let proj = pt(100, 0)
            let first = o.coords.first
            let moved = first.map { dist($0, proj) } ?? 0
            let note = o.notes.contains { $0.contains("A 离路 40 m") }
            let ok = abs(o.taperA - 40) <= 1 && note && moved > 5
            report("synthetic_anchor_off_40m_still_tapers", ok: ok, [("taperA", r1(o.taperA)), ("expect_taperA", .d(40)), ("first_from_proj_m", r1(moved)),
                   ("first_to_A_m", r1(first.map { dist($0, a) } ?? .infinity)), ("notes", .a(o.notes.map { .s($0) }))])
        } else { report("synthetic_anchor_off_40m_still_tapers", ok: false, [("error", .s("clip failed"))]) }
    }
    // 反例 2：A 投影约 5 m，再往前 15 m 处有一个偏 10 m 的顶点，45 m 处回到直路 → trimEnds 照旧删掉 <30 m 的近点
    do {
        let a = pt(100, 5), b = pt(900, 0)
        let raw = [pt(0, 0), pt(50, 0), pt(100, 0), pt(115, 10), pt(145, 0)] + stride(from: 200.0, through: 1000, by: 50).map { pt($0, 0) }
        if let o = pipeline(raw, a: a, b: b, bearingA: 90, bearingB: 90) {
            let firstD = o.trimmed.first.map { dist($0, a) } ?? 0
            let ok = firstD >= 40
            report("synthetic_small_kink_near_A_trimmed", ok: ok, [("clip_first_to_A_m", r1(o.clipped.first.map { dist($0, a) } ?? .infinity)), ("clip_n", .i(o.clipped.count)),
                   ("trimmed_n", .i(o.trimmed.count)), ("trimmed_first_to_A_m", r1(firstD)), ("expect_ge", .d(40)), ("taperA", r1(o.taperA)), ("notes", .a(o.notes.map { .s($0) }))])
        } else { report("synthetic_small_kink_near_A_trimmed", ok: false, [("error", .s("clip failed"))]) }
    }
    // 隧道 2 节点 way：投影点离 A 12 m、下一顶点在 155 m 外 → trimEnds 保留投影点（taper 也不触发：12 < 15）
    do {
        let a = pt(0, 12), b = pt(900, 0)
        let raw = [pt(-50, 0), pt(155, 0)] + stride(from: 300.0, through: 1000, by: 50).map { pt($0, 0) }
        if let o = pipeline(raw, a: a, b: b, bearingA: 90, bearingB: 90) {
            let proj = pt(0, 0)
            let kept = o.trimmed.first.map { dist($0, proj) } ?? .infinity
            let finalFirst = o.coords.first.map { dist($0, proj) } ?? .infinity
            let ok = kept <= 1 && finalFirst <= 1 && o.taperA == 0
            report("synthetic_two_node_tunnel_keeps_projection", ok: ok, [("trimmed_first_from_proj_m", r1(kept)), ("final_first_from_proj_m", r1(finalFirst)),
                   ("trimmed_n", .i(o.trimmed.count)), ("taperA", r1(o.taperA)), ("notes", .a(o.notes.map { .s($0) }))])
        } else { report("synthetic_two_node_tunnel_keeps_projection", ok: false, [("error", .s("clip failed"))]) }
    }
    // 反例 3：A 离路 20 m（超出匹配半径 15）、路网节点每 10 m 一个 → trimEnds 把投影点及 <30 m 的顶点都删掉、首点在 A 前方 30 m
    // （垂足 along ≈ −30）；首段直线确实从 A 旁经过（延长线垂距 ≈ snap 20），应补回垂足再 taper（d ≈ 20），不能留斜线
    do {
        let a = pt(0, 20), b = pt(900, 0)
        let raw = stride(from: -100.0, through: 1000, by: 10).map { pt($0, 0) }
        if let o = pipeline(raw, a: a, b: b, bearingA: 90, bearingB: 90) {
            let trimmedFirst = o.trimmed.first.map { dist($0, a) } ?? 0
            let note = o.notes.contains { $0.contains("A 离路 20 m") }
            let ok = trimmedFirst >= 30 && abs(o.taperA - 20) <= 1 && note
            report("synthetic_dense_nodes_anchor_off_20m_foot_restored", ok: ok, [("trimmed_first_to_A_m", r1(trimmedFirst)), ("expect_trimmed_ge", .d(30)),
                   ("taperA", r1(o.taperA)), ("expect_taperA", .d(20)), ("first_to_A_m", r1(o.coords.first.map { dist($0, a) } ?? .infinity)),
                   ("notes", .a(o.notes.map { .s($0) }))])
        } else { report("synthetic_dense_nodes_anchor_off_20m_foot_restored", ok: false, [("error", .s("clip failed"))]) }
    }
    // anchorWarning：taper 远多于 residual 时提醒；正常草稿不提醒
    do {
        var d = RouteDraft(source: .osrmCar, coords: [], meters: 0, snapA: 12, snapB: 0, endpoint: "t", warnings: [])
        d.residualA = 12; d.taperA = 32
        let w = RouteCrossCheck.anchorWarning(d, matchRadius: 15)
        var d2 = d; d2.taperA = 12
        let w2 = RouteCrossCheck.anchorWarning(d2, matchRadius: 15)
        report("anchor_warning_taper_vs_residual", ok: w != nil && w2 == nil, [("warning", w.map { .s($0) } ?? .null), ("normal", w2.map { .s($0) } ?? .null)])
    }
    return bad == 0 ? 0 : 1
}
if CommandLine.arguments.contains("--portal-selftest") { exit(portalSelfTest()) }

// MARK: - 限速器自测（synthrunner --ratelimit-selftest）：4 个并发调用方打同一主机，断言同一时刻在途 ≤1、相邻开始 ≥1.05 s、取消后迅速退出
func rateLimitSelfTest() -> Int32 {
    final class Probe: @unchecked Sendable {
        let lock = NSLock(); var cur = 0; var maxSeen = 0; var starts: [Double] = []
        func enter(_ t: Double) { lock.lock(); cur += 1; maxSeen = max(maxSeen, cur); starts.append(t); lock.unlock() }
        func leave() { lock.lock(); cur -= 1; lock.unlock() }
    }
    let rl = RoadNetwork.RateLimiter.shared, probe = Probe()
    let t0 = Date()
    let sem = DispatchSemaphore(value: 0)
    var cancelledQuickly = false
    let task = Task {
        await withTaskGroup(of: Void.self) { group in
            for w in 0..<4 {
                group.addTask {
                    for d in [0.3, 1.5, 0.3] {
                        do {
                            try await rl.perform(host: "selftest.host") {
                                probe.enter(Date().timeIntervalSince(t0))
                                try await Task.sleep(nanoseconds: UInt64(d * 1e9))
                                probe.leave()
                                return (Data(), URLResponse())
                            }
                        } catch { probe.leave(); return }
                        _ = w
                    }
                }
            }
        }
    }
    // 跑 6 s 后取消，看是否 200 ms 内全部退出
    Task {
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        let tc = Date()
        task.cancel()
        _ = await task.value
        cancelledQuickly = Date().timeIntervalSince(tc) < 2.0   // 在途请求最长 1.5 s，加上退出开销
        sem.signal()
    }
    sem.wait()
    let starts = probe.starts.sorted()
    var minGap = Double.infinity
    for i in 1..<max(1, starts.count) { minGap = min(minGap, starts[i] - starts[i - 1]) }
    let ok = probe.maxSeen <= 1 && (starts.count < 2 || minGap >= 1.0) && cancelledQuickly
    emit(.o([("case", .s("ratelimit_single_inflight")), ("ok", .b(ok)), ("maxInFlight", .i(probe.maxSeen)), ("requests", .i(starts.count)),
             ("minGapSeconds", .d(minGap.isFinite ? (minGap * 100).rounded() / 100 : -1)), ("cancelledQuickly", .b(cancelledQuickly))]))
    return ok ? 0 : 1
}
if CommandLine.arguments.contains("--ratelimit-selftest") { exit(rateLimitSelfTest()) }

// MARK: - 隧道占比自测（synthrunner --tunnel-selftest）：自己构造的 OSRM 回复（steps[].intersections[].classes 含 tunnel）
// 解析出 tunnelShare；缺 intersections（旧录音）→ nil；FillPlausibility 隧道免扣只在有值时生效
func tunnelSelfTest() -> Int32 {
    var allOK = true
    func check(_ name: String, _ ok: Bool, _ extra: [(String, J)] = []) {
        allOK = allOK && ok
        emit(.o([("case", .s(name)), ("ok", .b(ok))] + extra))
    }
    // 沿经线 11.0 向北 0.01°（≈1112 m）；路口在 45.000 / 45.003（进隧道）/ 45.006（出隧道），到达 45.010
    let sample = """
    {"code":"Ok","waypoints":[{"distance":1.0},{"distance":2.0}],"routes":[{"distance":1112,"geometry":{"type":"LineString","coordinates":[[11.0,45.0],[11.0,45.003],[11.0,45.006],[11.0,45.01]]},
     "legs":[{"steps":[
       {"distance":1112,"name":"SS12","ref":"SS12","intersections":[{"location":[11.0,45.0]},{"location":[11.0,45.003],"classes":["tunnel"]},{"location":[11.0,45.006]}]},
       {"distance":0,"name":"SS12","intersections":[{"location":[11.0,45.01]}]}]}]}]}
    """
    let old = """
    {"legs":[{"steps":[{"distance":1112,"name":"SS12"},{"distance":0,"name":"SS12"}]}]}
    """
    let raw = [CLLocationCoordinate2D(latitude: 45.0, longitude: 11.0), CLLocationCoordinate2D(latitude: 45.01, longitude: 11.0)]
    if let j = try? JSONSerialization.jsonObject(with: Data(sample.utf8)) as? [String: Any],
       let r0 = (j["routes"] as? [[String: Any]])?.first, let legs = r0["legs"] as? [[String: Any]] {
        let spans = RoadNetwork.parseOSRMTunnelSpans(legs)
        let share = RoadNetwork.tunnelShare(spans: spans, along: raw)
        check("tunnel_share_from_classes", spans?.count == 1 && share.map { abs($0 - 0.3) < 0.01 } == true,
              [("spans", .i(spans?.count ?? -1)), ("share", .d(share.map { ($0 * 1000).rounded() / 1000 } ?? -1))])
        // A–B 只取后半段（45.005→45.010）：隧道只剩 45.005→45.006 = 1/5
        let half = [CLLocationCoordinate2D(latitude: 45.005, longitude: 11.0), CLLocationCoordinate2D(latitude: 45.01, longitude: 11.0)]
        let s2 = RoadNetwork.tunnelShare(spans: spans, along: half)
        check("tunnel_share_clipped_to_ab", s2.map { abs($0 - 0.2) < 0.01 } == true, [("share", .d(s2.map { ($0 * 1000).rounded() / 1000 } ?? -1))])
    } else { check("tunnel_share_from_classes", false) }
    if let j = try? JSONSerialization.jsonObject(with: Data(old.utf8)) as? [String: Any], let legs = j["legs"] as? [[String: Any]] {
        let spans = RoadNetwork.parseOSRMTunnelSpans(legs)
        check("old_recording_no_intersections_is_nil", spans == nil && RoadNetwork.tunnelShare(spans: spans, along: raw) == nil)
    } else { check("old_recording_no_intersections_is_nil", false) }
    // 有 intersections 但没有 classes → 0（不是 nil）
    let noTunnel = [["steps": [["distance": 100, "intersections": [["location": [11.0, 45.0]], ["location": [11.0, 45.01]]]]]]] as [[String: Any]]
    let z = RoadNetwork.tunnelShare(spans: RoadNetwork.parseOSRMTunnelSpans(noTunnel), along: raw)
    check("intersections_without_tunnel_is_zero", z == 0)
    // 免扣：补点在路网上、锚点离路 15 m（轻度扣 10）；tunnelShare 0.8 → 不扣，nil / 0.3 → 照扣
    let pts = stride(from: 1, to: 20, by: 1).map { CLLocationCoordinate2D(latitude: 45.0 + Double($0) * 0.0005, longitude: 11.0) }
    func risk(_ share: Double?) -> FillPlausibility {
        var x = FillPlausibility.Input(a: raw[0], b: raw[1], points: pts, routeRaw: raw, routeMeters: 1112, seconds: 40)
        x.snapA = 15; x.residualA = 15; x.tunnelShare = share
        return FillPlausibility.assess(x, thresholds: .default)
    }
    let rNil = risk(nil), rLow = risk(0.3), rHigh = risk(0.8)
    check("plausibility_tunnel_waive", rNil.risk == rLow.risk && rHigh.risk == rNil.risk - FillPlausibility.Thresholds.default.snapMild && rHigh.metrics.tunnelWaived && !rNil.metrics.tunnelWaived,
          [("riskNil", .i(rNil.risk)), ("riskLow", .i(rLow.risk)), ("riskHigh", .i(rHigh.risk))])
    return allOK ? 0 : 1
}
if CommandLine.arguments.contains("--tunnel-selftest") { exit(tunnelSelfTest()) }

// MARK: - 落地前自检阈值自测（synthrunner --plausibility-selftest）：2026-10-28 方案 B（伪影信号 >20 m 扣 50）与
// 补点太少时按折线顶点采样（docs/fill-plausibility-design.md §8）。全部自构造几何，不用录音
func plausibilitySelfTest() -> Int32 {
    var allOK = true
    func check(_ name: String, _ ok: Bool, _ extra: [(String, J)] = []) {
        allOK = allOK && ok
        emit(.o([("case", .s(name)), ("ok", .b(ok))] + extra))
    }
    let T = FillPlausibility.Thresholds.default
    // 路网原始折线：沿经线 11.0 向北 1112 m；补点贴在折线上
    let A = CLLocationCoordinate2D(latitude: 45.0, longitude: 11.0), B = CLLocationCoordinate2D(latitude: 45.01, longitude: 11.0)
    let raw = [A, B]
    let onRoad = stride(from: 1, to: 20, by: 1).map { CLLocationCoordinate2D(latitude: 45.0 + Double($0) * 0.0005, longitude: 11.0) }
    func base() -> FillPlausibility.Input {
        var x = FillPlausibility.Input(a: A, b: B, points: onRoad, routeRaw: raw, routeMeters: 1112, seconds: 40)
        x.vertices = onRoad
        return x
    }
    // 1) 伪影信号阶梯：excess 8 → 0；15 → 30；18 → 30；20 → 50；25 → 50（锚点离路 7 m 不另扣）
    func excess(_ taper: Double, residual: Double = 7) -> FillPlausibility {
        var x = base(); x.taperA = taper; x.residualA = residual; x.snapA = residual
        return FillPlausibility.assess(x, thresholds: T)
    }
    let e0 = excess(15), e1 = excess(22), e18 = excess(25), e20 = excess(27), e2 = excess(32)
    check("taper_excess_ladder", e0.risk == 0 && e1.risk == 30 && e18.risk == 30 && e20.risk == 50 && e2.risk == 50 && e2.level == .medium,
          [("excess8", .i(e0.risk)), ("excess15", .i(e1.risk)), ("excess18", .i(e18.risk)), ("excess20", .i(e20.risk)), ("excess25", .i(e2.risk))])
    let f = PortalDrift.Frame(origin: A)
    // 1b) 上周第 14 处原型：taper 32、锚点离路 12（excess 正好 20），补点每 55 m 一个、起始 150 m 内推开 32·(1−s/L) → 必须 high
    do {
        var x = base(); x.taperA = 32; x.residualA = 12; x.snapA = 12
        let L = 150.0
        x.points = stride(from: 55.0, to: 1112, by: 55).map { s in f.coord(SIMD2(s < L ? 32 * (1 - s / L) : 0, s)) }
        x.vertices = x.points
        let p = FillPlausibility.assess(x, thresholds: T)
        check("archetype_taper32_snap12_is_high", p.level == .high, [("risk", .i(p.risk)), ("devRouteMax", .d((p.metrics.devRouteMax * 10).rounded() / 10)), ("reasons", .a(p.reasons.map { J.s($0) }))])
    }
    check("taper_excess_reason_mentions_excess", e2.reasons.first.map { $0.contains("25 m") && $0.contains("32 m") && $0.contains("7 m") } == true,
          [("reason", .s(e2.reasons.first ?? ""))])
    // 2) §8 的 16 题画像：excess 21–30 + devRouteMax 5–15 档（扣 10）→ 60 → high（改前 40 → medium）
    var art = base(); art.taperA = 32; art.residualA = 9; art.snapA = 9
    art.points = onRoad.enumerated().map { k, p in k < 4 ? f.coord(f.xy(p) + SIMD2(20.0 - Double(k) * 5, 0)) : p }   // 首段推开 20→5 m
    art.vertices = art.points
    let artP = FillPlausibility.assess(art, thresholds: T)
    check("artefact_profile_is_high", artP.level == .high && artP.metrics.devRouteMax > 5,
          [("risk", .i(artP.risk)), ("devRouteMax", .d((artP.metrics.devRouteMax * 10).rounded() / 10)), ("allowance", .d((artP.metrics.devRouteAllowance * 10).rounded() / 10)), ("reasons", .a(artP.reasons.map { J.s($0) }))])
    check("dev_reason_mentions_allowance", artP.reasons.contains { $0.contains("已扣除端部允许的") })
    // 3) 补点太少：3 个补点都在路上，折线顶点在两点之间鼓出 30 m → 按顶点采样才看得见；5 个补点时照旧按补点
    let bump = CLLocationCoordinate2D(latitude: 45.004, longitude: 11.0 + 30 / f.kx)
    func sparse(_ n: Int) -> FillPlausibility {
        var x = base()
        x.points = stride(from: 1, through: n, by: 1).map { CLLocationCoordinate2D(latitude: 45.0 + 0.01 * Double($0) / Double(n + 1), longitude: 11.0) }
        x.vertices = [CLLocationCoordinate2D(latitude: 45.002, longitude: 11.0), bump, CLLocationCoordinate2D(latitude: 45.006, longitude: 11.0)]
        return FillPlausibility.assess(x, thresholds: T)
    }
    let s3 = sparse(3), s5 = sparse(5)
    check("sparse_points_sample_vertices", s3.metrics.devSampledVertices && s3.metrics.devRouteMax > 25 && s3.risk > 0 && !s5.metrics.devSampledVertices && s5.metrics.devRouteMax < 1 && s5.risk == 0,
          [("dev3", .d((s3.metrics.devRouteMax * 10).rounded() / 10)), ("risk3", .i(s3.risk)), ("dev5", .d((s5.metrics.devRouteMax * 10).rounded() / 10)), ("risk5", .i(s5.risk))])
    // 4) retarget 把顶点裁到第一个保留点之前：fillB 在 45.005 → 顶点只剩 45.002（鼓包在后面，采不到）
    var y = base(); y.points = [CLLocationCoordinate2D(latitude: 45.0025, longitude: 11.0)]
    y.vertices = [CLLocationCoordinate2D(latitude: 45.002, longitude: 11.0), bump, CLLocationCoordinate2D(latitude: 45.006, longitude: 11.0)]
    let yr = FillPlausibility.retarget(y, fillB: CLLocationCoordinate2D(latitude: 45.003, longitude: 11.0))
    check("retarget_clips_vertices", yr.vertices.count == 1 && FillPlausibility.assess(yr, thresholds: T).metrics.devRouteMax < 1, [("vertices", .i(yr.vertices.count))])
    return allOK ? 0 : 1
}
if CommandLine.arguments.contains("--plausibility-selftest") { exit(plausibilitySelfTest()) }

// MARK: - 合成断档考卷（synthrunner --exam <dir> | --exam-record <dir> [--max-requests N] [--exam-baseline]；见 exam.swift）
do {
    let args = CommandLine.arguments
    if let k = args.firstIndex(where: { $0 == "--exam" || $0 == "--exam-record" }) {
        let dir = k + 1 < args.count && !args[k + 1].hasPrefix("--") ? args[k + 1] : "Tests/exam"
        var maxReq = 700
        if let m = args.firstIndex(of: "--max-requests"), m + 1 < args.count, let v = Int(args[m + 1]) { maxReq = v }
        exit(GapExam.run(dir: dir, record: args[k] == "--exam-record", maxRequests: maxReq, writeBaseline: args.contains("--exam-baseline")))
    }
}

let paths = Array(CommandLine.arguments.dropFirst())
if paths.isEmpty {
    FileHandle.standardError.write("usage: synthrunner <file.gpx|file.csv>...\n".data(using: .utf8)!)
    exit(2)
}
for p in paths {
    emit(run(p))
}
stage("exit")
exit(0)

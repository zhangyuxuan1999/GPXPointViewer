import Foundation
import CoreLocation
import simd

// MARK: - 合成断档考卷（synthrunner --exam <dir> | --exam-record <dir> [--max-requests N] [--exam-baseline]）
// 设计：docs/fill-plausibility-design.md §2。题目 <dir>/questions/*.json，录音 <dir>/recordings/<keyHash>.json，
// 结果 <dir>/results/<yyyyMMdd_HHmm>.json，基线 <dir>/baseline.json（--exam-baseline 写；--exam 对照：基线里通过的题现在不过 = 回归，退出码 1）。
// 每题跑与 app 批量相同的流程：载入 → 候选检测 → GapRouteInputs.build → carRoute（经济模式，两个引擎，HTTP 层录制/回放）
// → StaleRetime + FillPath.interpolate（点距 = 两侧局部步长中位，夹 5–100）→ 与答案比 → 同时记落地前自检（FillPlausibility）。

enum GapExam {
    struct Question {
        var id: String, kind: String, source: String, band: String, roadType: String
        var tA: Double, tB: Double
        var a: CLLocationCoordinate2D, b: CLLocationCoordinate2D
        var truthPolyline: [CLLocationCoordinate2D]      // real 题：OSM way 几何（未裁）；synthetic 为空（答案从原始轨迹取）
    }
    struct Thresholds { static let maxDev = 20.0, within = 20.0, withinShare = 0.95 }

    static func loadQuestions(_ dir: String) -> [Question] {
        let qd = dir + "/questions"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: qd)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        var out: [Question] = []
        for n in names {
            guard let data = FileManager.default.contents(atPath: qd + "/" + n), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = j["id"] as? String, let a = j["anchorA"] as? [String: Any], let b = j["anchorB"] as? [String: Any],
                  let tA = (a["time"] as? NSNumber)?.doubleValue, let tB = (b["time"] as? NSNumber)?.doubleValue,
                  let la = (a["lat"] as? NSNumber)?.doubleValue, let lo = (a["lon"] as? NSNumber)?.doubleValue,
                  let lb = (b["lat"] as? NSNumber)?.doubleValue, let lob = (b["lon"] as? NSNumber)?.doubleValue else { continue }
            let poly = ((j["truthPolyline"] as? [[NSNumber]]) ?? []).compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[0].doubleValue, longitude: $0[1].doubleValue) : nil }
            out.append(Question(id: id, kind: (j["kind"] as? String) ?? "synthetic", source: (j["source"] as? String) ?? "", band: (j["band"] as? String) ?? "",
                                roadType: (j["roadType"] as? String) ?? "", tA: tA, tB: tB,
                                a: CLLocationCoordinate2D(latitude: la, longitude: lo), b: CLLocationCoordinate2D(latitude: lb, longitude: lob), truthPolyline: poly))
        }
        return out
    }

    /// 源文件只解析一次
    nonisolated(unsafe) static var parsedCache: [String: ParsedTrack] = [:]
    static func parsed(_ path: String) -> ParsedTrack? {
        if let p = parsedCache[path] { return p }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe), var p = try? GPXParser.parse(data: data) else { return nil }
        p.name = (path as NSString).lastPathComponent
        parsedCache[path] = p
        return p
    }

    /// 与 TrackStore.localMovingStep / spacingFor 同口径：两侧各 ≤12 步、不跨断档、移动步（>1 m/s）的步长中位，夹 5–100 m
    static func spacing(_ t: TrackData, ia: Int, ib: Int, profile: SamplingProfile) -> Double {
        var ds: [Double] = []
        for (idx, forward) in [(ia, false), (ib, true)] {
            var k = idx
            for _ in 0..<12 {
                let prev = k
                k += forward ? 1 : -1
                guard k >= 0, k < t.timedCount else { break }
                let dt = abs(t.time[k] - t.time[prev]), d = GeoMath.haversine(t.lat[prev], t.lon[prev], t.lat[k], t.lon[k])
                if GapDetector.isBreakStep(dt: dt, meters: d) { break }
                if dt > 0, d / dt > 1 { ds.append(d) }
            }
        }
        let m: Double
        if ds.count >= 3 { ds.sort(); m = ds[ds.count / 2] } else { m = profile.medianStep }
        return min(100, max(5, m.rounded()))
    }

    /// 折线几何比对：P 每 5 m 取样到 T 的距离（最大 / 中位 / ≤within 占比），T 顶点到 P 的最大距离，长度比
    struct Score { var pMax: Double; var pMedian: Double; var tMax: Double; var within: Double; var lenRatio: Double; var pass: Bool }
    static func score(p: [CLLocationCoordinate2D], truth: [CLLocationCoordinate2D]) -> Score? {
        guard p.count >= 2, truth.count >= 2 else { return nil }
        let f = PortalDrift.Frame(origin: p[0])
        let P = PortalDrift.Poly(p, frame: f), T = PortalDrift.Poly(truth, frame: f)
        guard P.length > 0, T.length > 0 else { return nil }
        var ds: [Double] = []
        var s = 0.0, k = 1
        while true {
            let sc = min(s, P.length)
            while k < P.pts.count - 1, P.acc[k] < sc { k += 1 }
            let l = P.acc[k] - P.acc[k - 1], tt = l > 0 ? max(0, min(1, (sc - P.acc[k - 1]) / l)) : 0
            ds.append(T.project(P.pts[k - 1] + (P.pts[k] - P.pts[k - 1]) * tt).d)
            if sc >= P.length { break }
            s += 5
        }
        let sorted = ds.sorted()
        let tMax = T.pts.map { P.project($0).d }.max() ?? 0
        let within = Double(ds.filter { $0 <= Thresholds.within }.count) / Double(max(1, ds.count))
        let pMax = sorted.last ?? 0
        return Score(pMax: pMax, pMedian: sorted[sorted.count / 2], tMax: tMax, within: within, lenRatio: P.length / T.length,
                     pass: max(pMax, tMax) <= Thresholds.maxDev && within >= Thresholds.withinShare)
    }

    struct EngineResult {
        var status = "ok"               // ok | noRecording | error
        var error = ""
        var score: Score? = nil
        var plaus: FillPlausibility? = nil
        var draft: RouteDraft? = nil
        var points = 0
        var ia = 0, ib = 0
        var perturbArtefact: FillPlausibility.Level? = nil
        var perturbParallel: FillPlausibility.Level? = nil
        /// 伪影扰动题的明细（分析「只到 medium」用；不进汇总行）：评估结果 + 扰动长度 L、补点数、P 长度
        var perturbArtefactDetail: (p: FillPlausibility, L: Double, n: Int, len: Double)? = nil
    }

    static func run(dir: String, record: Bool, maxRequests: Int, writeBaseline: Bool) -> Int32 {
        let questions = loadQuestions(dir)
        guard !questions.isEmpty else { FileHandle.standardError.write("no questions in \(dir)/questions\n".data(using: .utf8)!); return 2 }
        let recDir = dir + "/recordings"
        RouteReplay.mode = record ? .record(recDir) : .replay(recDir)
        RouteReplay.maxRequests = maxRequests
        RouteReplay.log = { FileHandle.standardError.write(("  " + $0 + "\n").data(using: .utf8)!) }
        RouteReplay.resetCounters()
        let baselinePath = dir + "/baseline.json"
        let baseline: [String: [String: Bool]] = {
            guard let d = FileManager.default.contents(atPath: baselinePath), let j = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Bool]] else { return [:] }
            return j
        }()
        var lines: [J] = []
        var baselineOut: [String: [String: Bool]] = [:]
        var regressions: [String] = []
        // 汇总计数
        struct Tally { var n = 0, pass = 0, fail = 0, noRec = 0, err = 0; var failHigh = 0, failNotHigh = 0, passHigh = 0, passNotHigh = 0; var passMedium = 0, failMedium = 0
                       var perturbN = 0, artefactHigh = 0, parallelHigh = 0 }
        var tally: [String: Tally] = ["osrm": Tally(), "valhalla": Tally()]
        var byBand: [String: (n: Int, pass: Int)] = [:]
        var agreeButFail = 0, agreeN = 0, disagreeN = 0, detectedN = 0
        var budgetExhausted = false

        for (qi, q) in questions.enumerated() {
            stage("exam \(q.id)")
            guard var p = parsed(q.source) else { lines.append(.o([("id", .s(q.id)), ("error", .s("source not found: \(q.source)"))])); continue }
            // synthetic：挖掉 (tA, tB) 之间的点
            if q.kind == "synthetic" {
                var keep: [Int] = []; keep.reserveCapacity(p.count)
                for i in 0..<p.count where !(p.time[i] > q.tA && p.time[i] < q.tB) { keep.append(i) }
                p.lat = keep.map { p.lat[$0] }; p.lon = keep.map { p.lon[$0] }; p.ele = keep.map { p.ele[$0] }; p.time = keep.map { p.time[$0] }
                if !p.segmentID.isEmpty { p.segmentID = keep.map { p.segmentID[$0] } }
                p.fileID = []; p.sortedRuns = []
            }
            let track = TrackData.build(parsed: p, preferredMode: .single).0
            let full = TrackData.build(parsed: parsed(q.source)!, preferredMode: .single).0
            guard let iA = (0..<track.timedCount).first(where: { track.time[$0] == q.tA }), let iB = (0..<track.timedCount).first(where: { track.time[$0] == q.tB }), iA < iB else {
                lines.append(.o([("id", .s(q.id)), ("error", .s("anchor times not found"))])); continue
            }
            let profile = SamplingProfile.compute(track: track, creator: track.creator, accuracy: track.gpsAccuracy)
            var opt = GapDetector.Options(); opt.staleEnabled = profile.kind == .deviceLogger
            let cands = GapDetector.shiftFrozenChains(track: track, candidates: GapDetector.detect(track: track, options: opt), profile: profile)
            let found = cands.first { $0.indexA <= iA && $0.indexB >= iB && $0.indexB - iB <= 3 && iA - $0.indexA <= 8 }
            let detected = found != nil
            if detected { detectedN += 1 }
            let c = found ?? GapCandidate(kind: .timeGap, indexA: iA, indexB: iB, tA: track.time[iA], tB: track.time[iB],
                                          latA: track.lat[iA], lonA: track.lon[iA], latB: track.lat[iB], lonB: track.lon[iB],
                                          meters: GeoMath.haversine(track.lat[iA], track.lon[iA], track.lat[iB], track.lon[iB]),
                                          speedInKmh: iA >= 1 ? track.speedKmh[iA] : 0, speedOutKmh: iB + 1 < track.speedKmh.count ? track.speedKmh[iB + 1] : 0)
            let ia = c.indexA, ib = c.indexB
            let A = CLLocationCoordinate2D(latitude: track.lat[ia], longitude: track.lon[ia]), B = CLLocationCoordinate2D(latitude: track.lat[ib], longitude: track.lon[ib])
            let inp = GapRouteInputs.build(track, ia: ia, ib: ib, profile: profile)
            let mid = CLLocationCoordinate2D(latitude: (A.latitude + B.latitude) / 2, longitude: (A.longitude + B.longitude) / 2)
            let leftHand: Bool? = TrafficSide.leftHandByBox(mid)      // 不查地理编码（联网）；欧洲 = 靠右，与 app 查出的一致
            var results: [String: EngineResult] = [:]
            var drafts: [RoadNetwork.RouteEngine: RouteDraft] = [:]
            for engine in [RoadNetwork.RouteEngine.osrm, .valhalla] {
                let name = engine == .osrm ? "osrm" : "valhalla"
                var r = EngineResult()
                let key = RouteCacheKey(source: engine == .osrm ? .osrmCar : .valhallaCar, economy: true, ia: ia, ib: ib, a: A, b: B, seconds: c.seconds, inputs: inp, leftHand: leftHand)
                RouteReplay.currentKeyHash = RouteReplay.stableHash(key)
                if budgetExhausted { r.status = "noRecording"; r.error = "budget"; results[name] = r; continue }
                let missBefore = RouteReplay.replayMisses
                let sem = DispatchSemaphore(value: 0)
                var outcome: Result<RouteDraft, Error> = .failure(RouteError.allEndpointsFailed([]))
                Task.detached {
                    do {
                        let d = try await RoadNetwork.carRoute(a: A, b: B, bearingA: inp.a.heading.bearing, bearingB: inp.b.heading.bearing,
                                                               contextA: inp.a.context.anchor, contextB: inp.b.context.anchor, trace: inp.trace,
                                                               matchRadius: inp.radius, seconds: c.seconds,
                                                               portalA: inp.portalA, portalB: inp.portalB,
                                                               farContextA: inp.farContextA, farContextB: inp.farContextB,
                                                               portalFarA: inp.portalFarA, portalFarB: inp.portalFarB,
                                                               leftHandTraffic: leftHand, economy: true, engine: engine, failFast: false)
                        outcome = .success(d)
                    } catch { outcome = .failure(error) }
                    sem.signal()
                }
                sem.wait()
                switch outcome {
                case .failure(let e):
                    let text = String(describing: e)
                    if RouteReplay.replayMisses > missBefore || text.contains("no recording") { r.status = "noRecording" }
                    else if text.contains("budget exhausted") { r.status = "noRecording"; r.error = "budget"; budgetExhausted = true }
                    else { r.status = "error"; r.error = (e as? LocalizedError)?.errorDescription ?? text }
                    results[name] = r
                    continue
                case .success(let d):
                    r.draft = d; drafts[engine] = d
                    // 落地（与 TrackStore.landingJob 同口径）
                    let ia2 = max(0, ia - d.shiftA), ib2 = min(track.timedCount - 1, ib + d.shiftB)
                    r.ia = ia2; r.ib = ib2
                    let fa = FillAnchor(lat: track.lat[ia2], lon: track.lon[ia2], ele: track.ele[ia2], time: track.time[ia2])
                    let fb = FillAnchor(lat: track.lat[ib2], lon: track.lon[ib2], ele: track.ele[ib2], time: track.time[ib2])
                    let plan = StaleRetime.plan(track: track, ia: ia2, ib: ib2, candidate: c, vertices: d.coords, radius: profile.matchRadius)
                    let synthetic = FillPath.interpolate(a: fa, vertices: plan?.vertices ?? d.coords, b: plan?.fillB ?? fb, spacingMeters: spacing(track, ia: ia2, ib: ib2, profile: profile))
                    var pts = synthetic
                    if let plan { pts = StaleRetime.landingPoints(track: track, ia: ia2, ib: ib2, plan: plan, synthetic: pts) }
                    r.points = pts.count
                    let A2 = CLLocationCoordinate2D(latitude: fa.lat, longitude: fa.lon), B2 = CLLocationCoordinate2D(latitude: fb.lat, longitude: fb.lon)
                    // 与 TrackStore.assessBatchItem 同口径：P 只含合成点，改时的真实点走 innerMaxOff；判卷用的折线含全部落地点
                    let pc = synthetic.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                    let retimed = (plan?.retimed ?? []).map { CLLocationCoordinate2D(latitude: track.lat[$0.index], longitude: track.lon[$0.index]) }
                    var baseInput = FillPlausibility.input(draft: d, a: A2, b: B2, seconds: fb.time - fa.time, points: pc, inputs: inp, candidate: c, crossMaxDev: nil,
                                                           innerMaxOff: FillPlausibility.innerMaxOff(a: A2, points: pc, b: B2, real: retimed))
                    if let plan { baseInput = FillPlausibility.retarget(baseInput, fillB: CLLocationCoordinate2D(latitude: plan.fillB.lat, longitude: plan.fillB.lon)) }
                    r.plaus = FillPlausibility.assess(baseInput)
                    // 已知错误类的「扰动题」：同一处录音上人为造出上周那两类错误，看第一关抓不抓得住（命中率的口径）
                    // artefact = 旧 trimEnds+taper 伪影：起始 150 m 内的补点横向推开 32 m 再线性回到路上，taperA 记 32；
                    // parallel = 整条补点平移 25 m（吸到平行路/对向车道，路网原始折线不变）
                    // 补点所沿的折线顶点（baseInput.vertices，retarget 已裁）也按同一公式推开/平移：补点 < 4 个时第一关按顶点采样
                    if pc.count >= 2 {
                        let f = PortalDrift.Frame(origin: A2)
                        let P = PortalDrift.Poly([A2] + pc + [B2], frame: f)
                        let dir0 = P.pts.count >= 2 ? (P.pts[1] - P.pts[0]) : SIMD2(1, 0)
                        let n0 = simd_length(dir0) > 0 ? SIMD2(dir0.y, -dir0.x) / simd_length(dir0) : SIMD2(0, 1)
                        let L = min(150.0, 0.45 * P.length)
                        func pushed(_ poly: PortalDrift.Poly, _ cs: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
                            cs.enumerated().map { k, p in
                                let s = poly.acc[k + 1]
                                return s < L ? f.coord(f.xy(p) + n0 * (32 * (1 - s / L))) : p
                            }
                        }
                        var art = baseInput
                        art.points = pushed(P, pc)
                        art.vertices = pushed(PortalDrift.Poly([A2] + baseInput.vertices + [baseInput.b], frame: f), baseInput.vertices)
                        art.taperA = 32
                        let artP = FillPlausibility.assess(art)
                        r.perturbArtefact = artP.level
                        r.perturbArtefactDetail = (artP, L, pc.count, P.length)
                        let chord = f.xy(B2) - f.xy(A2)
                        let nc = simd_length(chord) > 0 ? SIMD2(chord.y, -chord.x) / simd_length(chord) : SIMD2(0, 1)
                        var par = baseInput
                        par.points = pc.map { f.coord(f.xy($0) + nc * 25) }
                        par.vertices = baseInput.vertices.map { f.coord(f.xy($0) + nc * 25) }
                        r.perturbParallel = FillPlausibility.assess(par).level
                    }
                    // 答案折线：synthetic = 原始轨迹里 [t(A2), t(B2)] 的点；real = OSM way 几何裁到 A2/B2 投影之间
                    var truth: [CLLocationCoordinate2D] = []
                    if q.kind == "synthetic" {
                        for i in 0..<full.timedCount where full.time[i] >= fa.time && full.time[i] <= fb.time { truth.append(CLLocationCoordinate2D(latitude: full.lat[i], longitude: full.lon[i])) }
                    } else if let cl = RoadNetwork.clipPolyline(q.truthPolyline, from: A2, to: B2) {
                        truth = [A2] + cl.coords + [B2]
                    }
                    r.score = score(p: [A2] + pts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } + [B2], truth: truth)
                    results[name] = r
                }
            }
            // 两路比对
            var agree: Bool? = nil
            if let dO = drafts[.osrm], let dV = drafts[.valhalla] {
                agree = RouteCrossCheck.compare(dO, dV, a: A, b: B).agree
                if agree == true { agreeN += 1 } else { disagreeN += 1 }
                if agree == true, results["osrm"]?.score?.pass == false || results["valhalla"]?.score?.pass == false { agreeButFail += 1 }
            }
            var kv: [(String, J)] = [("i", .i(qi)), ("id", .s(q.id)), ("kind", .s(q.kind)), ("band", .s(q.band)), ("roadType", .s(q.roadType)),
                                     ("detected", .b(detected)), ("candidateKind", .s(candKind(c.kind))), ("ia", .i(ia)), ("ib", .i(ib)),
                                     ("agree", agree.map { .b($0) } ?? .null)]
            var base: [String: Bool] = [:]
            for name in ["osrm", "valhalla"] {
                let r = results[name] ?? EngineResult(status: "error", error: "missing")
                var t = tally[name]!
                t.n += 1
                var ekv: [(String, J)] = [("status", .s(r.status))]
                if !r.error.isEmpty { ekv.append(("error", .s(r.error))) }
                if let d = r.draft {
                    ekv += [("method", .s(d.method?.rawValue ?? "")), ("meters", r1(d.meters)), ("shiftA", .i(d.shiftA)), ("shiftB", .i(d.shiftB)),
                            ("warnings", .i(d.warnings.count)), ("points", .i(r.points)), ("legs", .a(d.legs.compactMap { $0.label }.map { .s($0) }))]
                }
                if let s = r.score {
                    ekv += [("pass", .b(s.pass)), ("pMax", r1(s.pMax)), ("pMedian", r1(s.pMedian)), ("tMax", r1(s.tMax)), ("within20", .d((s.within * 1000).rounded() / 1000)), ("lenRatio", .d((s.lenRatio * 1000).rounded() / 1000))]
                    if s.pass { t.pass += 1 } else { t.fail += 1 }
                    base[name] = s.pass
                    if let was = baseline[q.id]?[name], was, !s.pass { regressions.append("\(q.id)/\(name)") }
                    var b = byBand[q.band] ?? (0, 0); b.n += 1; if s.pass { b.pass += 1 }; byBand[q.band] = b
                    if let pl = r.plaus {
                        let high = pl.level == .high
                        if s.pass { if high { t.passHigh += 1 } else { t.passNotHigh += 1 }; if pl.level == .medium { t.passMedium += 1 } }
                        else { if high { t.failHigh += 1 } else { t.failNotHigh += 1 }; if pl.level == .medium { t.failMedium += 1 } }
                    }
                } else if r.status == "noRecording" { t.noRec += 1 } else { t.err += 1 }
                if let pl = r.plaus {
                    let m = pl.metrics
                    func r2(_ x: Double) -> J { .d((x * 100).rounded() / 100) }
                    var mk: [(String, J)] = []
                    mk.append(("devRouteMax", r1(m.devRouteMax)))
                    mk.append(("devRouteMedian", r1(m.devRouteMedian)))
                    mk.append(("devRouteAllowance", r1(m.devRouteAllowance)))
                    mk.append(("devSampledVertices", .b(m.devSampledVertices)))
                    mk.append(("detourRatio", r2(m.detourRatio)))
                    mk.append(("impliedSpeedKmh", r1(m.impliedSpeedKmh)))
                    mk.append(("impliedSpeedRatio", m.impliedSpeedRatio.map(r2) ?? J.null))
                    mk.append(("headingA", m.headingA.map(r1) ?? J.null))
                    mk.append(("headingB", m.headingB.map(r1) ?? J.null))
                    mk.append(("roadRefChanges", m.roadRefChanges.map { J.i($0) } ?? J.null))
                    mk.append(("roadMatchesContext", m.roadMatchesContext.map { J.b($0) } ?? J.null))
                    mk.append(("snapA", r1(m.snapA)))
                    mk.append(("snapB", r1(m.snapB)))
                    mk.append(("taperExcessA", r1(m.taperExcessA)))
                    mk.append(("taperExcessB", r1(m.taperExcessB)))
                    mk.append(("uTurnCount", .i(m.uTurnCount)))
                    ekv.append(("risk", .i(pl.risk)))
                    ekv.append(("level", .s(pl.level.rawValue)))
                    ekv.append(("reasons", .a(pl.reasons.map { J.s($0) })))
                    ekv.append(("metrics", .o(mk)))
                }
                if let pa = r.perturbArtefact, let pp = r.perturbParallel {
                    ekv.append(("perturbArtefact", .s(pa.rawValue)))
                    ekv.append(("perturbParallel", .s(pp.rawValue)))
                    if let d = r.perturbArtefactDetail {
                        let m = d.p.metrics
                        func r1(_ x: Double) -> J { .d((x * 10).rounded() / 10) }
                        ekv.append(("perturbArtefactDetail", .o([("risk", .i(d.p.risk)), ("L", r1(d.L)), ("points", .i(d.n)), ("pathLength", r1(d.len)),
                                                                 ("devRouteMax", r1(m.devRouteMax)), ("devRouteMedian", r1(m.devRouteMedian)),
                                                                 ("devRouteAllowance", r1(m.devRouteAllowance)), ("devSampledVertices", .b(m.devSampledVertices)),
                                                                 ("taperExcessA", r1(m.taperExcessA)), ("headingA", m.headingA.map(r1) ?? .null),
                                                                 ("reasons", .a(d.p.reasons.map { J.s($0) }))])))
                    }
                    t.perturbN += 1
                    if pa == .high { t.artefactHigh += 1 }
                    if pp == .high { t.parallelHigh += 1 }
                }
                tally[name] = t
                kv.append((name, .o(ekv)))
            }
            baselineOut[q.id] = base
            let line = J.o(kv)
            lines.append(line)
            emit(line)
            if record {
                FileHandle.standardError.write("  [\(qi + 1)/\(questions.count)] \(q.id) requests so far \(RouteReplay.requestsSent) (replayed \(RouteReplay.replayHits))\n".data(using: .utf8)!)
            }
        }
        // 汇总
        func pct(_ a: Int, _ b: Int) -> String { b > 0 ? String(format: "%.0f%%", Double(a) / Double(b) * 100) : "—" }
        var parts: [String] = ["questions \(questions.count)", "detected \(detectedN)"]
        var sumKV: [(String, J)] = [("questions", .i(questions.count)), ("detected", .i(detectedN)), ("agree", .i(agreeN)), ("disagree", .i(disagreeN)), ("agreeButFail", .i(agreeButFail)),
                                    ("requestsSent", .i(RouteReplay.requestsSent)), ("replayHits", .i(RouteReplay.replayHits)), ("replayMisses", .i(RouteReplay.replayMisses))]
        for name in ["osrm", "valhalla"] {
            let t = tally[name]!
            let graded = t.pass + t.fail
            let hit = pct(t.failHigh, t.fail), fa = pct(t.passHigh, t.pass)
            parts.append("\(name): pass \(t.pass)/\(graded) noRecording \(t.noRec) error \(t.err) | high∧fail \(t.failHigh) high∧pass \(t.passHigh) → hit \(hit) falseAlarm \(fa) | perturb artefact \(t.artefactHigh)/\(t.perturbN) parallel \(t.parallelHigh)/\(t.perturbN) high")
            sumKV.append((name, .o([("graded", .i(graded)), ("pass", .i(t.pass)), ("fail", .i(t.fail)), ("noRecording", .i(t.noRec)), ("error", .i(t.err)),
                                    ("confusion", .o([("failHigh", .i(t.failHigh)), ("failNotHigh", .i(t.failNotHigh)), ("passHigh", .i(t.passHigh)), ("passNotHigh", .i(t.passNotHigh)),
                                                      ("failMedium", .i(t.failMedium)), ("passMedium", .i(t.passMedium))])),
                                    ("hitRate", .s(hit)), ("falseAlarmRate", .s(fa)),
                                    ("perturb", .o([("n", .i(t.perturbN)), ("artefactHigh", .i(t.artefactHigh)), ("parallelHigh", .i(t.parallelHigh))]))])))
        }
        parts.append("agree \(agreeN) disagree \(disagreeN) agreeButFail \(agreeButFail)")
        parts.append("bands " + byBand.keys.sorted().map { "\($0) \(byBand[$0]!.pass)/\(byBand[$0]!.n)" }.joined(separator: " "))
        parts.append("requests sent \(RouteReplay.requestsSent) replayed \(RouteReplay.replayHits) missing \(RouteReplay.replayMisses)")
        if !regressions.isEmpty { parts.append("REGRESSIONS \(regressions.count): " + regressions.prefix(20).joined(separator: " ")) }
        sumKV.append(("bands", .o(byBand.keys.sorted().map { ($0, J.o([("n", .i(byBand[$0]!.n)), ("pass", .i(byBand[$0]!.pass))])) })))
        sumKV.append(("regressions", .a(regressions.map { .s($0) })))
        sumKV.append(("thresholds", .o([("maxDev", .d(Thresholds.maxDev)), ("within", .d(Thresholds.within)), ("withinShare", .d(Thresholds.withinShare))])))
        // 结果文件
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd_HHmm"; fmt.locale = Locale(identifier: "en_US_POSIX")
        let resDir = dir + "/results"
        try? FileManager.default.createDirectory(atPath: resDir, withIntermediateDirectories: true)
        var out = ""
        enc(.o([("mode", .s(record ? "record" : "replay")), ("summary", .o(sumKV)), ("questions", .a(lines))]), into: &out)
        try? out.write(toFile: resDir + "/" + fmt.string(from: Date()) + ".json", atomically: true, encoding: .utf8)
        if writeBaseline {
            let obj = baselineOut.mapValues { $0 }
            if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted]) { try? d.write(to: URL(fileURLWithPath: baselinePath)) }
            parts.append("baseline written (\(baselineOut.count))")
        }
        print("exam summary: " + parts.joined(separator: " · "))
        RouteReplay.mode = nil
        let errs = tally.values.reduce(0) { $0 + $1.err }
        return (regressions.isEmpty && errs == 0) ? 0 : 1
    }
}

import Foundation
setbuf(stdout, nil)
func load(_ path: String) throws -> TrackData {
    let d = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    var p = try GPXParser.parse(data: d); p.name = (path as NSString).lastPathComponent
    return TrackData.build(parsed: p, preferredMode: .single).0
}
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: dump <file> <out.jsonl>   (环境变量 SAMPLETEST_OLD=1 → 无时限、弦长上限 600，复现第一轮行为) | check <file> <baseline.jsonl>"); exit(1) }
if ProcessInfo.processInfo.environment["SAMPLETEST_OLD"] == "1" { GapRouteInputs.limitOverride = (seconds: .infinity, chord: 600) }
let t = try load(args[2])
let profile = SamplingProfile.compute(track: t, creator: t.creator, accuracy: t.gpsAccuracy)
var opt = GapDetector.Options(); opt.staleEnabled = profile.kind == .deviceLogger
let gaps = GapDetector.detect(track: t, options: opt)
switch args[1] {
case "dump":
    var lines: [String] = []
    for (i, c) in gaps.enumerated() {
        let inp = GapRouteInputs.build(t, ia: c.indexA, ib: c.indexB, profile: profile)
        lines.append(GapInputDump.line(index: i, candidate: c, inputs: inp))
    }
    try lines.joined(separator: "\n").write(toFile: args[3], atomically: true, encoding: .utf8)
    print(String(format: "%@: %d 处 → %@ · 画像 %@ %.0f s / %.0f m 半径 %.0f", (args[2] as NSString).lastPathComponent, gaps.count, (args[3] as NSString).lastPathComponent, profile.kindLabel, profile.medianDt, profile.medianStep, profile.matchRadius))
case "check":
    // A3 基线相对不变量：方向 ∈ {基线方向, nil}；上下文 ∈ {基线点, 同侧更近档位, nil}，基线 nil ⇒ 新 nil；reqs ≤ 基线；
    // 绝对不变量：方向弦长 ≤ maxChord 且 ≥25；上下文/方向点 |Δt| ≤600、上下文 ≤600 m；parked ⇔ 上下文 tooOld 且无方向；trace ≤10
    struct Row: Decodable { let i: Int; let ia: Int; let ib: Int; let bA: [Int]?; let bB: [Int]?; let cA: [Int?]?; let cB: [Int?]?; let trace: [Int]; let reqs: Int; let cAstop: String; let cBstop: String; let auto: String? }
    let baseText = try String(contentsOfFile: args[3], encoding: .utf8)
    let base = try baseText.split(separator: "\n").map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
    precondition(base.count == gaps.count, "基线 \(base.count) 处 ≠ 当前 \(gaps.count) 处")
    var bad = 0, stops: [String: Int] = [:], natures: [String: Int] = [:], autos: [String: Int] = [:], reqs = 0, baseReqs = 0, changed = 0
    let isGarmin = profile.kind == .deviceLogger
    for (i, c) in gaps.enumerated() {
        let b = base[i]
        precondition(b.ia == c.indexA && b.ib == c.indexB, "候选集不同 i=\(i)")
        let inp = GapRouteInputs.build(t, ia: c.indexA, ib: c.indexB, profile: profile)
        var rowChanged = false
        for (side, idx, bh, bc, bstop) in [(inp.a, c.indexA, b.bA, b.cA, b.cAstop), (inp.b, c.indexB, b.bB, b.cB, b.cBstop)] {
            stops[side.context.stop.key, default: 0] += 1
            // 方向：基线有 → 新值要么同一个点同一角度要么 nil；基线 nil → 新 nil
            if let k = side.heading.index, let bb = side.heading.bearing {
                let deg = ((Int(bb.rounded()) % 360) + 360) % 360
                if bh == nil || bh![0] != k || bh![1] != deg { bad += 1; print("  方向不是基线子集 i=\(i) new=[\(k),\(deg)] base=\(bh ?? [])") }
                let d = GeoMath.haversine(t.lat[idx], t.lon[idx], t.lat[k], t.lon[k])
                if d > side.heading.maxChord + 0.001 || d < 25 { bad += 1; print("  方向弦长越界 i=\(i) d=\(d) max=\(side.heading.maxChord)") }
                if abs(t.time[k] - t.time[idx]) > 600 { bad += 1; print("  方向点超 600 s i=\(i)") }
            } else if bh != nil { rowChanged = true }
            // 上下文
            if let k = side.context.index {
                if abs(t.time[k] - t.time[idx]) > 600 { bad += 1; print("  上下文点超 600 s i=\(i)") }
                if GeoMath.haversine(t.lat[idx], t.lon[idx], t.lat[k], t.lon[k]) > 600.001 { bad += 1; print("  上下文点超 600 m i=\(i)") }
                if let bc {
                    let bk = bc[0]!, brung = bc[1]!
                    if k != bk {
                        // 允许：同侧更近档位（档位更小且点更近）
                        let newRung = Int(side.context.rung ?? 0)
                        let closer = newRung < brung && abs(k - idx) <= abs(bk - idx)
                        if !closer { bad += 1; print("  上下文点既非基线也非更近档 i=\(i) new=\(k)/\(newRung) base=\(bk)/\(brung)") }
                        rowChanged = true
                    } else if (bc[2] == nil) != (side.context.anchor?.bearing == nil) { rowChanged = true }
                } else { bad += 1; print("  基线无上下文而新有 i=\(i)") }
            } else if bc != nil { rowChanged = true }
            // 停车联动双向
            let parked: Bool = { if case .parked = side.heading.stop { return true }; return false }()
            let tooOld = side.context.anchor == nil && side.context.stop.key == "tooOld"
            if parked != tooOld || (parked && side.heading.bearing != nil) { bad += 1; print("  停车联动不一致 i=\(i)") }
            if isGarmin, side.context.stop.key == "tooOld" || parked { bad += 1; print("  Garmin 出现 tooOld/parked i=\(i)") }
            _ = bstop
        }
        if inp.traceIndices != b.trace { rowChanged = true }
        if inp.trace.count > 10 { bad += 1; print("  trace >10 i=\(i)") }
        if inp.requestCount > b.reqs { bad += 1; print("  请求数增加 i=\(i) \(b.reqs)→\(inp.requestCount)") }
        reqs += inp.requestCount; baseReqs += b.reqs
        if rowChanged { changed += 1 }
        natures[inp.sampling.nature.rawValue, default: 0] += 1
        autos[BatchClassifier.classify(c)?.rawValue ?? "nil", default: 0] += 1
    }
    print("\((args[2] as NSString).lastPathComponent): 候选 \(gaps.count) 违规 \(bad) 相对基线变化 \(changed) 处 请求 \(baseReqs)→\(reqs) 停止原因 \(stops.sorted { $0.key < $1.key }) 成因 \(natures) 自动分类 \(autos)")
    if isGarmin, changed > 0 { print("  ✗ Garmin 应 0 变化"); bad += 1 }
    exit(bad == 0 ? 0 : 1)
default: print("unknown")
}

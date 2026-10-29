import Foundation
import CoreLocation
setbuf(stdout, nil)
// jitterprobe <file>...：回放点数、乱跳簇（与 Python 探针对照）、与已有候选的重叠、耗时
func load(_ path: String) throws -> TrackData {
    let d = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    var p = try GPXParser.parse(data: d)
    p.name = (path as NSString).lastPathComponent
    return TrackData.build(parsed: p, preferredMode: .single).0
}
let fmt = DateFormatter(); fmt.dateFormat = "MM-dd HH:mm:ss"; fmt.timeZone = TimeZone(identifier: "UTC")
func hms(_ t: Double) -> String { fmt.string(from: Date(timeIntervalSince1970: t)) }
for path in CommandLine.arguments.dropFirst() {
    let t = try load(path)
    let profile = SamplingProfile.compute(track: t, creator: t.creator, accuracy: t.gpsAccuracy)
    var opt = GapDetector.Options(); opt.staleEnabled = profile.kind == .deviceLogger
    var t0 = Date()
    let gaps = GapDetector.detect(track: t, options: opt)
    let tDetect = Date().timeIntervalSince(t0)
    t0 = Date()
    let flags = GapDetector.replayFlags(track: t)
    let nRep = flags.filter { $0 }.count
    let tRep = Date().timeIntervalSince(t0)
    t0 = Date()
    let traceWin = ProcessInfo.processInfo.environment["JITTER_TRACE"]?.split(separator: "-").map(String.init)   // "MM-dd HH:mm:ss" 两端用 ~ 分隔
    let tw = ProcessInfo.processInfo.environment["JITTER_TRACE"]?.split(separator: "~").map(String.init)
    let jit = GapDetector.detectJitter(track: t, profile: profile, replay: nRep > 0 ? flags : nil, options: opt,
                                       trace: tw.map { w in { (tt: Double, msg: String) in let h = hms(tt); if h >= w[0] && h <= w[1] { print("    \(h) \(msg)") } } })
    _ = traceWin
    let tJit = Date().timeIntervalSince(t0)
    let ranges = gaps.map { ($0.indexA, $0.indexB) }
    let overlap = jit.filter { j in ranges.contains { j.indexA <= $0.1 && j.indexB >= $0.0 && !(j.indexA <= $0.0 && j.indexB >= $0.1) } }
    print(String(format: "\n%@: %d 点 · 画像 %@ · 断档 %d（%.2f s）· 回放点 %d（%.2f s）· 乱跳簇 %d（%.2f s），与断档重叠 %d",
                 (path as NSString).lastPathComponent, t.count, profile.kindLabel, gaps.count, tDetect, nRep, tRep, jit.count, tJit, overlap.count))
    for c in jit.prefix(60) {
        print(String(format: "  %@ → %@ 跨 %4.0f s · 弦 %6.0f m（%4.0f km/h）· 大跳 %d 倒退 %d 最大步 %.0f · 内点 %d%@",
                     hms(c.tA), hms(c.tB), c.seconds, c.meters, c.kmh, c.jitterJumps, c.jitterReversals, c.jitterMaxJump, c.innerCount,
                     overlap.contains(where: { $0.tA == c.tA }) ? " [与断档重叠]" : ""))
    }
    if jit.count > 60 { print("  … 共 \(jit.count) 簇") }
    // 只删点时的单调链：对前 5 个簇算一下保留多少
    for c in jit.prefix(5) {
        let cap = c.kmh > opt.maxKmh ? opt.maxKmh : max(60, 1.5 * c.kmh)
        let keep = GapDetector.monotonicChain(track: t, ia: c.indexA, ib: c.indexB, capKmh: cap)
        print("  单调链 \(hms(c.tA))：内点 \(c.innerCount) → 保留 \(keep.count)（cap \(Int(cap)) km/h）")
    }
}

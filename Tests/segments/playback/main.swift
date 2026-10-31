//
//  时光机「城市章节 + 按区域揭示」原型验证（DeepSeek 2026-10-31）
//  分支 fix/playback-area-reveal；不改产品行为，只编译真实规划源码。
//
import Foundation
import CoreLocation

setvbuf(stdout, nil, _IONBF, 0)
var passed = 0
var failed: [String] = []
func check(_ v: @autoclosure () -> Bool, _ msg: String) {
    if v() { passed += 1 } else { failed.append(msg); print("FAIL: \(msg)") }
}

let path = ProcessInfo.processInfo.environment["GPXPV_PLAYBACK_GPX"] ?? "data/backUpData-all 6.gpx"
guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
    print("SKIP: \(path) not available (set GPXPV_PLAYBACK_GPX)"); exit(0)
}
let parsed = try! GPXParser.parse(data: data)
let (track, _) = TrackData.build(parsed: parsed, preferredMode: .single)
let evs = PlaybackPlan.events(track: track)
let duration = 45.06666666666667
guard let plan = PlaybackPlan.buildCities(events: evs, duration: duration),
      let cp = plan.cityPlan else { print("FAIL: no city plan"); exit(1) }
print(String(format: "plan duration=%.2fs cities=%d transit=%d chapters=%d",
             plan.duration, cp.cities.count, cp.transit.count, cp.chapters.count))

let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = TimeZone(identifier: "UTC")
func d(_ t: Double) -> String { t.isFinite ? df.string(from: Date(timeIntervalSince1970: t)) : "—" }
func ll(_ x: Double, _ y: Double) -> String {
    let la = atan(sinh(Double.pi * (1 - 2 * y))) * 180 / .pi
    return String(format: "%.2f,%.2f", la, x * 360 - 180)
}
for (i, c) in cp.cities.enumerated() {
    print(String(format: "  city %2d %-18@ %@..%@ w=%.0f  chapter=%.1f..%.1fs",
                 i, ll(c.cx, c.cy) as NSString, d(c.t0), d(c.t1), c.weight,
                 cp.chapters[cp.cityChapter[i]].p0, cp.chapters[cp.cityChapter[i]].p1))
}

check(cp.cities.count >= 4 && cp.cities.count <= 12, "city count in 4…12")
check(cp.chapters.last?.finale == true, "plan ends with the all-tracks overview")
check(plan.duration <= duration + 0.01, "plan fits the requested duration")

// 城市按首次到访排序
var ordered = true
for i in 1..<cp.cities.count where cp.cities[i].t0 < cp.cities[i - 1].t0 { ordered = false }
check(ordered, "cities ordered by first visit")

// 片尾总览：相机范围要能放下全部数据（含跨洲）
if let fin = cp.chapters.last, fin.finale {
    let span = max(fin.x1 - fin.x0, fin.y1 - fin.y0)
    print(String(format: "finale %.1f..%.1fs span=%.3f (%.0f°)", fin.p0, fin.p1, span,
                 (fin.x1 - fin.x0) * 360))
    check(span >= 0.25, "finale covers the whole track (cross-continent)")
}

// 找到西安，验证“到达时 0%、平台结束 100%”
var xi = -1
var bestD = Double.infinity
for (i, c) in cp.cities.enumerated() {
    let la = atan(sinh(Double.pi * (1 - 2 * c.cy))) * 180 / .pi
    let lo = c.cx * 360 - 180
    let dd = GeoMath.haversine(34.20, 108.91, la, lo)
    if dd < bestD { bestD = dd; xi = i }
}
check(xi >= 0 && bestD < 120_000, "Xi'an is one of the cities (\(Int(bestD / 1000)) km)")
guard xi >= 0, let rv = PlaybackRevealData(track: track, plan: cp) else { print("FAIL: no reveal"); exit(1) }
let chapter = cp.chapters[cp.cityChapter[xi]]
var total = 0
for a in rv.areaOfPoint where Int(a) == xi { total += 1 }
func revealed(at p: Double) -> Int {
    let cs = cp.relativeCursors(at: p, epoch: cp.dataStart.rounded(.down))
    var n = 0
    for i in 0..<track.count where Int(rv.areaOfPoint[i]) == xi {
        if rv.times[i] <= cs[xi] { n += 1 }
    }
    return n
}
let start = revealed(at: chapter.p0)
let mid = revealed(at: (chapter.p0 + chapter.p1) / 2)
let end = revealed(at: chapter.p1)
print(String(format: "Xi'an area #%d: %d points, chapter %.2f..%.2fs", xi, total, chapter.p0, chapter.p1))
print(String(format: "  arrival %.1f%%  mid %.1f%%  end %.1f%%",
             100.0 * Double(start) / Double(max(1, total)),
             100.0 * Double(mid) / Double(max(1, total)),
             100.0 * Double(end) / Double(max(1, total))))
check(Double(start) / Double(max(1, total)) < 0.01, "Xi'an starts near empty on arrival")
check(Double(end) / Double(max(1, total)) > 0.99, "Xi'an is complete at the end of its chapter")

// 城际过渡段：至少有一处带有交通点
let withTransit = cp.chapters.filter { !$0.transit.isEmpty }.count
check(withTransit >= 1, "at least one intercity transition carries transit points")
// 每个城市章节的相机不做跨洲宽幅（城市要看得清）
var citySpansOK = true
for (i, _) in cp.cities.enumerated() {
    let c = cp.camera(at: cp.chapters[cp.cityChapter[i]].p0 + 0.01, aspect: 16.0 / 9.0)
    if c.span > PlaybackPlan.maxSpan + 1e-9 { citySpansOK = false }
}
check(citySpansOK, "city chapters stay within the normal zoom cap")

print("passed=\(passed) failed=\(failed)")
exit(failed.isEmpty ? 0 : 1)

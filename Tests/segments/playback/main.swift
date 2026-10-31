//
//  时光机"按区域揭示"原型验证（DeepSeek 2026-10-31，分支 fix/playback-area-reveal）
//
//  用真实数据验证：现有全局时间模型在相机到达西安时已经揭示 86% 的西安点；
//  按区域游标模型在平台开始时应接近 0%，平台结束时 100%。
//  没有安装、没有导出视频、没有修改产品行为。
//
import Foundation
import CoreLocation

setvbuf(stdout, nil, _IONBF, 0)
var passed = 0
var failed: [String] = []
func check(_ v: @autoclosure () -> Bool, _ msg: String) {
    if v() { passed += 1 } else { failed.append(msg); print("FAIL: \(msg)") }
}

let env = ProcessInfo.processInfo.environment["GPXPV_PLAYBACK_GPX"]
let path = env ?? "data/backUpData-all 6.gpx"
guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
    print("SKIP: \(path) not available (set GPXPV_PLAYBACK_GPX)")
    exit(0)
}
let parsed = try! GPXParser.parse(data: data)
let (track, _) = TrackData.build(parsed: parsed, preferredMode: .single)
guard let plan = PlaybackPlan.build(events: PlaybackPlan.events(track: track), duration: 45.06666666666667) else {
    print("SKIP: no playback plan"); exit(0)
}
guard let map = PlaybackRevealMap.build(track: track, plan: plan) else {
    print("SKIP: no reveal map"); exit(0)
}

// 西安：找中心离 (34.20,108.91) 最近的、带平台的区域
let target = CLLocationCoordinate2D(latitude: 34.20, longitude: 108.91)
var xiArea = -1
var bestD = Double.infinity
for (ai, a) in map.areas.enumerated() where map.platform[ai] != nil && a.points > 0 {
    let lon = a.cx * 360 - 180
    let lat = atan(sinh(Double.pi * (1 - 2 * a.cy))) * 180 / .pi
    let d = GeoMath.haversine(target.latitude, target.longitude, lat, lon)
    if d < bestD { bestD = d; xiArea = ai }
}
check(xiArea >= 0, "found a Xi'an area with a platform")
guard xiArea >= 0, let pl = map.platform[xiArea] else { print("FAILED"); exit(1) }
let area = map.areas[xiArea]
let n = area.points

func revealedOld(at p: Double) -> Int {
    map.revealedCount(area: xiArea, upto: plan.dataTime(at: p), time: track.time)
}
func revealedNew(at p: Double) -> Int {
    let cs = map.cursors(at: p)
    var c = 0
    for i in 0..<track.count where Int(map.areaOfPoint[i]) == xiArea {
        if map.isRevealed(i, time: track.time[i], cursors: cs) { c += 1 }
    }
    return c
}

let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.timeZone = TimeZone(identifier: "UTC")
func d(_ t: Double) -> String { t.isFinite ? f.string(from: Date(timeIntervalSince1970: t)) : "—" }
print("Xi'an area #\(xiArea): \(n) points, \(d(area.t0)) .. \(d(area.t1))")
print("platform: \(String(format: "%.2f", pl.p0))s .. \(String(format: "%.2f", pl.p1))s")
print("  p        dataTime(global)   old%    new%")
for p in [pl.p0, (pl.p0 + pl.p1) / 2, pl.p1] {
    let o = revealedOld(at: p), nw = revealedNew(at: p)
    print(String(format: "  %6.2f   %@   %5.1f%%  %5.1f%%", p, d(plan.dataTime(at: p)),
                 100.0 * Double(o) / Double(n), 100.0 * Double(nw) / Double(n)))
}
let oldAtStart = revealedOld(at: pl.p0)
let newAtStart = revealedNew(at: pl.p0)
let newAtEnd = revealedNew(at: pl.p1)
check(Double(oldAtStart) / Double(n) > 0.5, "old global-time model pre-draws most of Xi'an before arrival (\(oldAtStart)/\(n))")
check(Double(newAtStart) / Double(n) < 0.01, "area cursor starts near empty (\(newAtStart)/\(n))")
check(Double(newAtEnd) / Double(n) > 0.99, "area cursor reaches the whole area at platform end (\(newAtEnd)/\(n))")

print("passed=\(passed) failed=\(failed)")
exit(failed.isEmpty ? 0 : 1)

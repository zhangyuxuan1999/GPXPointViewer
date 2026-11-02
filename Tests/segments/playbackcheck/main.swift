import Foundation
setvbuf(stdout, nil, _IONBF, 0)
let path = "/Users/zyx/Documents/GPXPointViewer/data/backUpData-all 6.gpx"
let data = try! Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
let parsed = try! GPXParser.parse(data: data)
let (track, _) = TrackData.build(parsed: parsed, preferredMode: .single)
let plan = PlaybackPlan.buildCities(events: PlaybackPlan.events(track: track), duration: 45.0667)!
let cp = plan.cityPlan!
guard let rv = PlaybackRevealData(track: track, plan: cp) else { print("no reveal"); exit(1) }
func lon(_ x: Double) -> Double { x*360-180 }
func kind(_ ch: PlaybackChapter) -> String { ch.city >= 0 ? "city\(ch.city)" : (ch.trip ? "trip" : (ch.finale ? "finale" : "transition")) }
var failures = 0
// 长途区域不能重叠
var allTripIds = Set<Int>()
for ch in cp.chapters where ch.trip {
    let s = Set(ch.transit)
    if !allTripIds.isDisjoint(with: s) { print("FAIL duplicate transit in trip chapters"); failures += 1 }
    allTripIds.formUnion(s)
}
func visible(_ ch: PlaybackChapter, _ p: Double) -> (eu: Int, cn: Int, total: Int) {
    guard let cur = plan.cursors(at: p) else { return (0,0,0) }
    let cam = cp.camera(at: p, aspect: 9.0/16.0)
    let halfW = cam.span/2, halfH = cam.span*(9.0/16.0)/2
    var eu = 0, cn = 0, total = 0
    for k in 0..<track.count {
        let a = Int(rv.areaOfPoint[k]); guard a < cur.count, cur[a] > 0 else { continue }
        let t = Double(rv.times[k]) + cp.dataStart - 1
        guard t <= cp.dataStart + Double(cur[a]-1) else { continue }
        let x = track.mercX[k], y = track.mercY[k]
        guard x >= cam.cx-halfW, x <= cam.cx+halfW, y >= cam.cy-halfH, y <= cam.cy+halfH else { continue }
        total += 1
        let lo = lon(x)
        if lo < 30 { eu += 1 }
        if lo > 70 { cn += 1 }
    }
    return (eu, cn, total)
}
for ch in cp.chapters where ch.city >= 0 || ch.trip || ch.finale {
    let p = (ch.p0 + ch.p1) * 0.5
    let v = visible(ch, p)
    let k = kind(ch)
    if ch.city == 0 || ch.city == 1 {
        if v.cn == 0 || v.eu > 0 { print("FAIL \(k) visible eu=\(v.eu) cn=\(v.cn)"); failures += 1 }
    } else if ch.city == 2 {
        if v.eu == 0 || v.cn > 0 { print("FAIL \(k) visible eu=\(v.eu) cn=\(v.cn)"); failures += 1 }
    } else if ch.trip {
        // 中国章只能看到中国；欧洲章只能看到欧洲
        if v.cn > 0 && v.eu > 0 { print("FAIL trip mixes eu=\(v.eu) cn=\(v.cn)"); failures += 1 }
        if v.total == 0 { print("FAIL trip empty at mid"); failures += 1 }
    } else if ch.finale, v.total == 0 {
        print("FAIL finale empty"); failures += 1
    }
    // 章节开头自己的区域必须为空
    let startP = ch.p0 + 0.01
    if let cur = plan.cursors(at: startP) {
        if ch.city >= 0, cur[ch.city] != 0 { print("FAIL \(k) start not empty"); failures += 1 }
        if ch.trip, ch.transit.contains(where: { $0 + cp.cities.count < cur.count && cur[$0 + cp.cities.count] != 0 }) {
            print("FAIL trip start not empty"); failures += 1
        }
    }
}
print(failures == 0 ? "CHECK PASS" : "CHECK FAIL \(failures)")
exit(failures == 0 ? 0 : 1)

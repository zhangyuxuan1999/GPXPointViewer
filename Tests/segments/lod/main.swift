import Foundation
func check(_ ok: Bool, _ name: String) {
    if !ok { print("FAIL \(name)"); exit(1) }
    print("PASS \(name)")
}
// 稀疏单条轨迹（10 点，约 100m 间隔）+ 密集城区（600 点）
var lat: [Double] = [], lon: [Double] = [], tim: [Double] = []
for i in 0..<10 { lat.append(40.0); lon.append(116.0 + Double(i) * 0.001); tim.append(1_600_000_000 + Double(i) * 60) }
for i in 0..<600 { lat.append(40.5 + 0.0005 * sin(Double(i))); lon.append(116.5 + 0.0008 * cos(Double(i) * 1.7)); tim.append(1_610_000_000 + Double(i) * 60) }
var p = ParsedTrack(); p.lat = lat; p.lon = lon; p.ele = Array(repeating: 0, count: lat.count); p.time = tim
p.segmentID = (0..<lat.count).map { $0 < 10 ? UInt32(1) : UInt32(2) }
let (track, _) = TrackData.build(parsed: p, preferredMode: .single)
var x0 = 1.0, x1 = 0.0, y0 = 1.0, y1 = 0.0
for i in 0..<track.count { x0 = min(x0, track.mercX[i]); x1 = max(x1, track.mercX[i]); y0 = min(y0, track.mercY[i]); y1 = max(y1, track.mercY[i]) }
let center = ((x0+x1)/2, (y0+y1)/2), base = max(x1-x0, y1-y0) * 1.3
let levels = PointLODBuilder.build(track: track, center: center, baseSpan: base, levels: 4, k: 2)
check(levels.count == 4, "4 levels")
for (li, lv) in levels.enumerated() {
    let set = Set(lv.order)
    check(set.count == lv.order.count, "L\(li) order unique")
    check(lv.order == lv.order.sorted(), "L\(li) order sorted")
    // 覆盖：整个 base 区域内，每个 480×270 目标格若有原始点，则 LOD 也必须有
    let cols = 480, rows = 270
    let gx0 = center.0 - base/2, gy0 = center.1 - base/2
    var full = Set<Int>(), lod = Set<Int>()
    for i in 0..<track.count {
        let x = track.mercX[i], y = track.mercY[i]
        guard x >= gx0, x < gx0+base, y >= gy0, y < gy0+base else { continue }
        let cx = min(cols-1, max(0, Int((x-gx0)/base*Double(cols))))
        let cy = min(rows-1, max(0, Int((y-gy0)/base*Double(rows))))
        full.insert(cy*cols+cx)
    }
    for o in lv.order {
        let i = Int(o)
        let cx = min(cols-1, max(0, Int((track.mercX[i]-gx0)/base*Double(cols))))
        let cy = min(rows-1, max(0, Int((track.mercY[i]-gy0)/base*Double(rows))))
        lod.insert(cy*cols+cx)
    }
    check(lod.isSuperset(of: full), "L\(li) covers all occupied cells")
    // 稀疏轨迹：10 个点全部保留
    check((0..<10).allSatisfy { set.contains(UInt32($0)) }, "L\(li) keeps isolated track")
}
print("LOD SUMMARY \(levels.count) levels PASS")

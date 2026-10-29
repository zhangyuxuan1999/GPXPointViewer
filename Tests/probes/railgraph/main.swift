import Foundation
import CoreLocation
setbuf(stdout, nil)
// 合成铁路图：东西向直线，纬度 30，x 米 → 经度
let lat0 = 30.0
let kx = 111_320.0 * cos(lat0 * .pi / 180), ky = 110_540.0
func c(_ x: Double, _ y: Double) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat0 + y / ky, longitude: 110.0 + x / kx) }
func way(_ id: Int, _ pts: [(Double, Double)], nodeBase: Int) -> [String: Any] {
    ["type": "way", "id": id, "nodes": pts.indices.map { NSNumber(value: nodeBase + $0) },
     "geometry": pts.map { ["lat": c($0.0, $0.1).latitude, "lon": c($0.0, $0.1).longitude] }]
}
func run(_ name: String, _ els: [[String: Any]], _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, expectMeters: ClosedRange<Double>) {
    do {
        let d = try RoadNetwork.shortestRailPath(elements: els, a: a, b: b)
        let xs = d.coords.map { Int(($0.longitude - 110.0) * kx) }
        let meters = d.acc.last ?? 0      // RailPath 不再带 meters/warnings：路径从 A 接入点到 B 接入点，累计弧长末值即路长
        let ok = expectMeters.contains(meters)
        print("\(ok ? "ok  " : "FAIL") \(name): \(Int(meters)) m, 中间点 x=\(xs), snap \(Int(d.snapA))/\(Int(d.snapB))")
        precondition(ok, name)
    } catch { print("FAIL \(name): \(error.localizedDescription)"); exit(1) }
}
// 1) A、B 落在同一条 3 km 线段内：应 ≈2000 m，不能绕到端点
run("同段", [way(1, [(0,0),(3000,0)], nodeBase: 100)], c(500, 10), c(2500, 10), expectMeters: 1990...2040)
// 2) 双线平行（相距 8 m）：A 接近线 1、B 接近线 2 也应 ≈2000 m
run("双线", [way(1, [(0,0),(3000,0)], nodeBase: 100), way(2, [(0,8),(3000,8)], nodeBase: 200)], c(500, -3), c(2500, 11), expectMeters: 1990...2060)
// 3) 分叉：主线 X 过 B 旁 2 m；支线 Y 在 x=1000 分出、到 B 旁 138 m 处。正确答案是沿 X
let X = way(1, [(0,0),(1000,0),(2000,0),(3000,0)], nodeBase: 100)
let Y: [String: Any] = ["type": "way", "id": 2, "nodes": [NSNumber(value: 101), NSNumber(value: 301), NSNumber(value: 302)],
                        "geometry": [["lat": c(1000,0).latitude, "lon": c(1000,0).longitude], ["lat": c(1500,70).latitude, "lon": c(1500,70).longitude], ["lat": c(2000,140).latitude, "lon": c(2000,140).longitude]]]
run("分叉", [X, Y], c(200, 5), c(2000, 2), expectMeters: 1790...1830)
// 4) 多节点折线：路径应经过中间节点
run("多节点", [way(1, [(0,0),(800,0),(1600,300),(2400,300),(3200,0)], nodeBase: 100)], c(400, 5), c(2800, 5), expectMeters: 2500...2700)
print("ALL OK")

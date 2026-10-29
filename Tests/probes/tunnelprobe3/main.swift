import Foundation
import CoreLocation
setbuf(stdout, nil)
// tunnelprobe3 <footprint.gpx> <garmin.gpx>：两个方向的系统扫描——
//  A) 足迹的每处时间空洞（≥300 m）里，Garmin 严格区间内有多少点、覆盖了多少秒、离 OSRM 道路几何多远、是否共线
//  B) Garmin 的每处断档里，足迹严格区间内的点同样统计
func load(_ path: String) throws -> TrackData {
    let d = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    var p = try GPXParser.parse(data: d); p.name = (path as NSString).lastPathComponent
    return TrackData.build(parsed: p, preferredMode: .single).0
}
let fmt = DateFormatter(); fmt.dateFormat = "MM-dd HH:mm:ss"
func ts(_ t: Double) -> String { fmt.string(from: Date(timeIntervalSince1970: t)) }
func m(_ x: Double) -> String { x >= 1000 ? String(format: "%.1f km", x / 1000) : String(format: "%.0f m", x) }
let args = CommandLine.arguments
let foot = try load(args[1]); let g = try load(args[2])
func gaps(_ t: TrackData) -> [GapCandidate] {
    let p = SamplingProfile.compute(track: t, creator: t.creator, accuracy: t.gpsAccuracy)
    var opt = GapDetector.Options(); opt.staleEnabled = p.kind == .deviceLogger
    return GapDetector.detect(track: t, options: opt).filter { $0.meters >= 300 }.sorted { $0.tA < $1.tA }
}
/// other 在 (tA, tB) 严格内部的点：数量、覆盖秒数、离道路几何的中位/最大、共线窗比例
func inside(_ other: TrackData, _ c: GapCandidate, road: PortalDrift.Poly?, frame: PortalDrift.Frame?) -> String {
    let idx = (0..<other.timedCount).filter { other.time[$0] > c.tA + 1 && other.time[$0] < c.tB - 1 }
    guard idx.count >= 2 else { return "区间内 \(idx.count) 点" }
    var covered = 0.0, ds: [Double] = []
    for (k, i) in idx.enumerated() {
        if k > 0 { let dt = other.time[i] - other.time[idx[k - 1]]; if dt <= 3 { covered += dt } }
        if let road, let frame { ds.append(road.project(frame.xy(CLLocationCoordinate2D(latitude: other.lat[i], longitude: other.lon[i]))).d) }
    }
    ds.sort()
    let kx = 111_320.0 * cos(other.lat[idx[0]] * .pi / 180), ky = 110_540.0
    var col = 0, win = 0
    if idx.count >= 8 {
        for s in stride(from: 0, to: idx.count - 8, by: 4) {
            let w = Array(idx[s..<(s + 8)]); win += 1
            let a = w.first!, b = w.last!
            let vx = (other.lon[b] - other.lon[a]) * kx, vy = (other.lat[b] - other.lat[a]) * ky, l = max(1, (vx * vx + vy * vy).squareRoot())
            if w.allSatisfy({ i in let px = (other.lon[i] - other.lon[a]) * kx, py = (other.lat[i] - other.lat[a]) * ky; return abs(vx * py - vy * px) / l <= 3 }) { col += 1 }
        }
    }
    let roadTxt = ds.isEmpty ? "离路 —" : String(format: "离路 中位 %.0f m 最大 %.0f m", ds[ds.count / 2], ds.last!)
    return String(format: "区间内 %d 点 · 连续覆盖 %.0f/%.0f s · %@ · 共线窗 %d/%d", idx.count, covered, c.seconds, roadTxt, col, win)
}
let sem = DispatchSemaphore(value: 0)
Task {
    for (label, base, other) in [("足迹空洞 → Garmin 在里面有什么", foot, g), ("Garmin 断档 → 足迹在里面有什么", g, foot)] {
        print("\n================ \(label) ================")
        for c in gaps(base) {
            let A = CLLocationCoordinate2D(latitude: c.latA, longitude: c.lonA), B = CLLocationCoordinate2D(latitude: c.latB, longitude: c.lonB)
            var road: PortalDrift.Poly? = nil, frame: PortalDrift.Frame? = nil
            if case .ok(let ans)? = try? await RoadNetwork.fetchOSRM(base: RoadNetwork.carEndpoints[0], a: A, b: B, bearingA: nil, bearingB: nil), ans.meters < 3 * c.meters {
                let fr = PortalDrift.Frame(origin: A); frame = fr; road = PortalDrift.Poly([A] + ans.coords + [B], frame: fr)
            }
            print(String(format: "%@ → %@  直线 %@  %.0f s  %@ ｜ %@", ts(c.tA), ts(c.tB), m(c.meters), c.seconds, c.kind == .staleClock ? "stale" : "tgap ", inside(other, c, road: road, frame: frame)))
        }
    }
    sem.signal()
}
sem.wait()

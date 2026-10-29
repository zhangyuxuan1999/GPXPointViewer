import Foundation
import CoreLocation
setbuf(stdout, nil)
// routeprobe <gpx> <HH:mm>[,<HH:mm>…]  — 对指定时刻的断档：打印输入、上下文原始几何、A 前/B 后真实点到几何的垂距、B 附近经过次数、裁剪结果
func load(_ path: String) throws -> TrackData {
    let d = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    var p = try GPXParser.parse(data: d); p.name = (path as NSString).lastPathComponent
    return TrackData.build(parsed: p, preferredMode: .single).0
}
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: routeprobe <gpx> <HH:mm,...>"); exit(1) }
let t = try load(args[1])
let profile = SamplingProfile.compute(track: t, creator: t.creator, accuracy: t.gpsAccuracy)
var opt = GapDetector.Options(); opt.staleEnabled = profile.kind == .deviceLogger
let gaps = GapDetector.detect(track: t, options: opt)
let fmt = DateFormatter(); fmt.dateFormat = "MM-dd HH:mm"
let wanted = args[2].split(separator: ",").map(String.init)
func label(_ tA: Double) -> String { fmt.string(from: Date(timeIntervalSince1970: tA)) }
// 局部平面投影 + 点到折线垂距（含沿线弧长位置）
struct Proj { var d: Double; var s: Double }
func projectAll(_ pts: [CLLocationCoordinate2D], origin: CLLocationCoordinate2D) -> ([(Double, Double)], [Double]) {
    let kx = 111_320.0 * cos(origin.latitude * .pi / 180), ky = 110_540.0
    let P = pts.map { (($0.longitude - origin.longitude) * kx, ($0.latitude - origin.latitude) * ky) }
    var acc = [0.0]
    for k in 1..<P.count { acc.append(acc[k-1] + ((P[k].0-P[k-1].0)*(P[k].0-P[k-1].0) + (P[k].1-P[k-1].1)*(P[k].1-P[k-1].1)).squareRoot()) }
    return (P, acc)
}
func distTo(_ P: [(Double, Double)], _ acc: [Double], q: CLLocationCoordinate2D, origin: CLLocationCoordinate2D) -> Proj {
    let kx = 111_320.0 * cos(origin.latitude * .pi / 180), ky = 110_540.0
    let qx = (q.longitude - origin.longitude) * kx, qy = (q.latitude - origin.latitude) * ky
    var best = Proj(d: .infinity, s: 0)
    for k in 1..<P.count {
        let (ux, uy) = P[k-1], (vx, vy) = P[k]; let dx = vx-ux, dy = vy-uy, len2 = dx*dx+dy*dy
        let tt = len2 > 0 ? max(0, min(1, ((qx-ux)*dx + (qy-uy)*dy)/len2)) : 0
        let fx = ux+dx*tt, fy = uy+dy*tt; let d = ((fx-qx)*(fx-qx)+(fy-qy)*(fy-qy)).squareRoot()
        if d < best.d { best = Proj(d: d, s: acc[k-1] + len2.squareRoot()*tt) }
    }
    return best
}
/// 折线上离 q 的所有局部极小（经过次数）：每个 (弧长, 距离)
func passes(_ P: [(Double, Double)], _ acc: [Double], q: CLLocationCoordinate2D, origin: CLLocationCoordinate2D, within: Double) -> [(Double, Double)] {
    let kx = 111_320.0 * cos(origin.latitude * .pi / 180), ky = 110_540.0
    let qx = (q.longitude - origin.longitude) * kx, qy = (q.latitude - origin.latitude) * ky
    var ds: [(Double, Double)] = []
    for k in 1..<P.count {
        let (ux, uy) = P[k-1], (vx, vy) = P[k]; let dx = vx-ux, dy = vy-uy, len2 = dx*dx+dy*dy
        let tt = len2 > 0 ? max(0, min(1, ((qx-ux)*dx + (qy-uy)*dy)/len2)) : 0
        let fx = ux+dx*tt, fy = uy+dy*tt; ds.append((acc[k-1] + len2.squareRoot()*tt, ((fx-qx)*(fx-qx)+(fy-qy)*(fy-qy)).squareRoot()))
    }
    var out: [(Double, Double)] = []
    var i = 0
    while i < ds.count {
        if ds[i].1 <= within {
            var j = i, best = ds[i]
            while j < ds.count, ds[j].1 <= within { if ds[j].1 < best.1 { best = ds[j] }; j += 1 }
            out.append(best); i = j
        } else { i += 1 }
    }
    return out
}
let sem = DispatchSemaphore(value: 0)
Task {
    for w in wanted {
        guard let c = gaps.first(where: { label($0.tA).hasSuffix(w) }) else { print("== \(w): 没有这个时刻的断档"); continue }
        let inp = GapRouteInputs.build(t, ia: c.indexA, ib: c.indexB, profile: profile)
        print(String(format: "\n== %@  ia=%d ib=%d 直线 %.0f m  %.0f s  kind=%@", label(c.tA), c.indexA, c.indexB, c.meters, c.seconds, c.kind == .staleClock ? "stale" : "tgap"))
        print("   A: ctx=\(inp.a.context.index.map(String.init) ?? "nil") (\(Int(inp.a.context.meters)) m, stop \(inp.a.context.stop.key)) bearing=\(inp.a.heading.bearing.map { String(Int($0)) } ?? "nil");  B: ctx=\(inp.b.context.index.map(String.init) ?? "nil") (\(Int(inp.b.context.meters)) m, stop \(inp.b.context.stop.key)) bearing=\(inp.b.heading.bearing.map { String(Int($0)) } ?? "nil"); ctxB bearing=\(inp.b.context.anchor?.bearing.map { String(Int($0)) } ?? "nil") ctxA bearing=\(inp.a.context.anchor?.bearing.map { String(Int($0)) } ?? "nil")")
        let A = CLLocationCoordinate2D(latitude: c.latA, longitude: c.lonA), B = CLLocationCoordinate2D(latitude: c.latB, longitude: c.lonB)
        let ca = inp.a.context.anchor ?? RoadNetwork.ContextAnchor(coord: A, bearing: inp.a.heading.bearing)
        let cb = inp.b.context.anchor ?? RoadNetwork.ContextAnchor(coord: B, bearing: inp.b.heading.bearing)
        for engine in ["osrm", "valhalla"] {
            let outcome: RoadNetwork.OSRMOutcome
            do {
                outcome = engine == "osrm" ? try await RoadNetwork.fetchOSRM(base: RoadNetwork.carEndpoints[0], a: ca.coord, b: cb.coord, bearingA: ca.bearing, bearingB: cb.bearing)
                                           : try await RoadNetwork.fetchValhalla(a: ca.coord, b: cb.coord, bearingA: ca.bearing, bearingB: cb.bearing)
            } catch { print("   \(engine): 请求失败 \(error)"); continue }
            guard case .ok(let ans) = outcome else { if case .status(let s) = outcome { print("   \(engine): \(s)") }; continue }
            // 原始几何（fetch 已 trimEnds 掉紧挨 A′/B′ 的点，无妨）
            let raw = [ca.coord] + ans.coords + [cb.coord]
            let (P, acc) = projectAll(raw, origin: A)
            print(String(format: "   %@ 上下文 A′→B′：%d 点 %.0f m（snap %.0f/%.0f）", engine, raw.count, ans.meters, ans.snapA, ans.snapB))
            let pa = distTo(P, acc, q: A, origin: A), pb = distTo(P, acc, q: B, origin: A)
            print(String(format: "   A 垂距 %.0f m @s=%.0f；B 垂距 %.0f m @s=%.0f；总长 %.0f", pa.d, pa.s, pb.d, pb.s, acc.last ?? 0))
            let pbs = passes(P, acc, q: B, origin: A, within: 120), pas = passes(P, acc, q: A, origin: A, within: 120)
            print("   经过 A 附近(≤120 m)：" + pas.map { String(format: "s=%.0f d=%.0f", $0.0, $0.1) }.joined(separator: " | "))
            print("   经过 B 附近(≤120 m)：" + pbs.map { String(format: "s=%.0f d=%.0f", $0.0, $0.1) }.joined(separator: " | "))
            // A 前 30 点、B 后 30 点到几何的垂距（含到锚点的距离与时间差）
            func side(_ idx: Int, _ dir: Int, _ name: String) {
                var row: [String] = []
                var k = idx
                for _ in 0..<30 {
                    k += dir
                    guard k >= 0, k < t.timedCount else { break }
                    let q = CLLocationCoordinate2D(latitude: t.lat[k], longitude: t.lon[k])
                    let pr = distTo(P, acc, q: q, origin: A)
                    row.append(String(format: "%+d:%.0fm/%.0fs/d%.0f", k - idx, GeoMath.haversine(t.lat[idx], t.lon[idx], t.lat[k], t.lon[k]), abs(t.time[k] - t.time[idx]), pr.d))
                }
                print("   \(name) 真实点（偏移:离锚点m/秒/到路垂距）: " + row.joined(separator: " "))
            }
            side(c.indexA, -1, "A 前"); side(c.indexB, 1, "B 后")
            if let clip = RoadNetwork.clipPolyline(ans.coords, from: A, to: B) {
                print(String(format: "   现行裁剪：%d 点 %.0f m（直线 %.0f，比 %.2f），snap %.0f/%.0f", clip.coords.count, clip.meters, c.meters, clip.meters / max(1, c.meters), clip.snapA, clip.snapB))
            }
        }
    }
    sem.signal()
}
sem.wait()

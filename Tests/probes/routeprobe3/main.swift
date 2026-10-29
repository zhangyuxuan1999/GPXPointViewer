import Foundation
import CoreLocation
setbuf(stdout, nil)
// routeprobe3 <gpx> <HH:mm>：从 A（带进入方向）直接路由到 B 之后第 k 个点（k = 0,5,10,20,30，各带该点行进方向），看绕路比——
// 判断 Uetliberg 的绕圈是 B 附近局部吸错路，还是出口这条路本来就只能绕过去
func load(_ path: String) throws -> TrackData {
    let d = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    var p = try GPXParser.parse(data: d); p.name = (path as NSString).lastPathComponent
    return TrackData.build(parsed: p, preferredMode: .single).0
}
let args = CommandLine.arguments
let t = try load(args[1])
let profile = SamplingProfile.compute(track: t, creator: t.creator, accuracy: t.gpsAccuracy)
var opt = GapDetector.Options(); opt.staleEnabled = profile.kind == .deviceLogger
let gaps = GapDetector.detect(track: t, options: opt)
let fmt = DateFormatter(); fmt.dateFormat = "MM-dd HH:mm"
guard let c = gaps.first(where: { fmt.string(from: Date(timeIntervalSince1970: $0.tA)).hasSuffix(args[2]) }) else { print("no gap"); exit(1) }
let inp = GapRouteInputs.build(t, ia: c.indexA, ib: c.indexB, profile: profile)
let A = CLLocationCoordinate2D(latitude: c.latA, longitude: c.lonA)
let sem = DispatchSemaphore(value: 0)
Task {
    for k in [0, 5, 10, 20, 30, 60] {
        let ib = c.indexB + k
        let B = CLLocationCoordinate2D(latitude: t.lat[ib], longitude: t.lon[ib])
        let hb = GapRouteInputs.heading(t, ib, forward: true, profile: profile).bearing
        let straight = GeoMath.haversine(A.latitude, A.longitude, B.latitude, B.longitude)
        for engine in ["osrm", "valhalla"] {
            for useBearing in [true, false] {
                let outcome: RoadNetwork.OSRMOutcome
                do {
                    outcome = engine == "osrm" ? try await RoadNetwork.fetchOSRM(base: RoadNetwork.carEndpoints[0], a: A, b: B, bearingA: useBearing ? inp.a.heading.bearing : nil, bearingB: useBearing ? hb : nil)
                                               : try await RoadNetwork.fetchValhalla(a: A, b: B, bearingA: useBearing ? inp.a.heading.bearing : nil, bearingB: useBearing ? hb : nil)
                } catch { print("k=\(k) \(engine): err \(error)"); continue }
                if case .ok(let ans) = outcome {
                    print(String(format: "k=%2d B+%2d (%.0f s 后, 方向 %@) %@ %@: 路长 %.0f  直线 %.0f  比 %.2f  snap %.0f/%.0f", k, k, t.time[ib] - c.tB, hb.map { String(Int($0)) } ?? "nil", engine, useBearing ? "带方向" : "无方向", ans.meters, straight, ans.meters / straight, ans.snapA, ans.snapB))
                } else if case .status(let s) = outcome { print("k=\(k) \(engine) \(useBearing): \(s)") }
            }
        }
    }
    sem.signal()
}
sem.wait()

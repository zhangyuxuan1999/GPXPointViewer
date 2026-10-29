import Foundation
import CoreLocation
setbuf(stdout, nil)
// routeprobe2 <gpx> <HH:mm,...> [economy]：走新的 carRoute（含漂移外推 / 沿线裁剪 / 末端靠拢），两引擎各一次，
// 打印 shift、snap、长度比、警告、说明，以及最终折线在新锚点附近的经过次数（绕圈是否被裁掉）
func load(_ path: String) throws -> TrackData {
    let d = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    var p = try GPXParser.parse(data: d); p.name = (path as NSString).lastPathComponent
    return TrackData.build(parsed: p, preferredMode: .single).0
}
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: routeprobe2 <gpx> <HH:mm,...> [economy]"); exit(1) }
let economy = args.contains("economy")
let t = try load(args[1])
let profile = SamplingProfile.compute(track: t, creator: t.creator, accuracy: t.gpsAccuracy)
var opt = GapDetector.Options(); opt.staleEnabled = profile.kind == .deviceLogger
let gaps = GapDetector.detect(track: t, options: opt)
let fmt = DateFormatter(); fmt.dateFormat = "MM-dd HH:mm"
func label(_ tA: Double) -> String { fmt.string(from: Date(timeIntervalSince1970: tA)) }
let sem = DispatchSemaphore(value: 0)
Task {
    for w in args[2].split(separator: ",").map(String.init) {
        guard let c = gaps.first(where: { label($0.tA).hasSuffix(w) }) else { print("== \(w): 没有这个时刻的断档"); continue }
        let inp = GapRouteInputs.build(t, ia: c.indexA, ib: c.indexB, profile: profile)
        print(String(format: "\n== %@  ia=%d ib=%d 直线 %.0f m  %.0f s  portalA %d / portalB %d  far %d / %d", label(c.tA), c.indexA, c.indexB, c.meters, c.seconds, inp.portalA.count, inp.portalB.count, inp.portalFarA.count, inp.portalFarB.count))
        let A = CLLocationCoordinate2D(latitude: c.latA, longitude: c.lonA), B = CLLocationCoordinate2D(latitude: c.latB, longitude: c.lonB)
        for engine in [RoadNetwork.RouteEngine.osrm, .valhalla] {
            do {
                let d = try await RoadNetwork.carRoute(a: A, b: B, bearingA: inp.a.heading.bearing, bearingB: inp.b.heading.bearing,
                                                       contextA: inp.a.context.anchor, contextB: inp.b.context.anchor, trace: inp.trace,
                                                       matchRadius: inp.radius, seconds: c.seconds, portalA: inp.portalA, portalB: inp.portalB,
                                                       farContextA: inp.farContextA, farContextB: inp.farContextB, portalFarA: inp.portalFarA, portalFarB: inp.portalFarB,
                                                       economy: economy, engine: engine)
                let na = c.indexA - d.shiftA, nb = c.indexB + d.shiftB
                let a2 = CLLocationCoordinate2D(latitude: t.lat[na], longitude: t.lon[na]), b2 = CLLocationCoordinate2D(latitude: t.lat[nb], longitude: t.lon[nb])
                let straight = GeoMath.haversine(a2.latitude, a2.longitude, b2.latitude, b2.longitude)
                // 最终折线 A2 → coords → B2 的总长与在 B2 附近的经过次数
                let poly = [a2] + d.coords + [b2]
                let f = PortalDrift.Frame(origin: a2); let P = PortalDrift.Poly(poly, frame: f)
                let passB = P.passes(f.xy(b2), within: 60).count, passA = P.passes(f.xy(a2), within: 60).count
                // 首段/末段与路的夹角：急拐检查（首段方向 vs 第二段方向）
                func kink(_ p: [CLLocationCoordinate2D]) -> Double {
                    guard p.count >= 3 else { return 0 }
                    let b1 = GeoMath.bearing(p[0].latitude, p[0].longitude, p[1].latitude, p[1].longitude), b2 = GeoMath.bearing(p[1].latitude, p[1].longitude, p[2].latitude, p[2].longitude)
                    var dd = abs(b1 - b2); if dd > 180 { dd = 360 - dd }; return dd
                }
                print(String(format: "   %@ 「%@」 shift A%d/B%d  snap %.0f/%.0f  路长 %.0f m  折线 %.0f m（新直线 %.0f，比 %.2f） 顶点 %d  经过 A/B 附近 %d/%d 次  首折 %.0f° 末折 %.0f°  警告 %d",
                             engine == .osrm ? "OSRM" : "Valhalla", d.method?.rawValue ?? "-", d.shiftA, d.shiftB, d.snapA, d.snapB, d.meters, P.length, straight, P.length / max(1, straight), d.coords.count, passA, passB, kink(poly), kink(Array(poly.reversed())), d.warnings.count))
                for w in d.warnings { print("      ⚠︎ " + w) }
                let all = CommandLine.arguments.contains("all")
                for n in d.notes where all || n.contains("漂移") || n.contains("靠拢") || n.contains("经过") || n.hasPrefix("采用") { print("      · " + n) }
                if all {
                    let tail = Array(poly.suffix(6))
                    print("      尾部 6 点离 B：" + tail.map { String(format: "%.0f", GeoMath.haversine($0.latitude, $0.longitude, b2.latitude, b2.longitude)) }.joined(separator: " → ")
                          + "  头部 6 点离 A：" + poly.prefix(6).map { String(format: "%.0f", GeoMath.haversine($0.latitude, $0.longitude, a2.latitude, a2.longitude)) }.joined(separator: " → "))
                }
            } catch { print("   \(engine): 失败 \(error)") }
        }
    }
    sem.signal()
}
sem.wait()

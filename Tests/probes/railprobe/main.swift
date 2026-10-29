import Foundation
import CoreLocation
setbuf(stdout, nil)
// railprobe <gpx> <index>：复现 railRoute.finish 的每一步——Overpass 元素里带 tunnel 标签的 way 数、最短路的段数/隧道段数、A/B 投影弧长、裁后占比
func load(_ path: String) throws -> TrackData {
    let d = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    var p = try GPXParser.parse(data: d); p.name = (path as NSString).lastPathComponent
    return TrackData.build(parsed: p, preferredMode: .single).0
}
let args = CommandLine.arguments
let t = try load(args[1])
let profile = SamplingProfile.compute(track: t, creator: t.creator, accuracy: t.gpsAccuracy)
var opt = GapDetector.Options(); opt.staleEnabled = profile.kind == .deviceLogger
let raw = GapDetector.detect(track: t, options: opt)
var natureOf: [Double: GapNature] = [:]
for g in raw { natureOf[g.tA] = GapRouteInputs.localSampling(t, ia: g.indexA, ib: g.indexB, profile: profile).nature }
let gaps = GapDetector.mergeChains(raw) { natureOf[$0.tA] == .lossOfLock && natureOf[$1.tA] == .lossOfLock }
let c = gaps[Int(args[2])!]
let inp = GapRouteInputs.build(t, ia: c.indexA, ib: c.indexB, profile: profile)
let a = CLLocationCoordinate2D(latitude: c.latA, longitude: c.lonA), b = CLLocationCoordinate2D(latitude: c.latB, longitude: c.lonB)
let ca = inp.a.context.anchor?.coord ?? a, cb = inp.b.context.anchor?.coord ?? b
print(String(format: "断档 ia=%d ib=%d 直线 %.0f m %.0f s；A′ %@ B′ %@；portal %d/%d", c.indexA, c.indexB, c.meters, c.seconds, inp.a.context.anchor == nil ? "无" : String(format: "%.0f m", inp.a.context.meters), inp.b.context.anchor == nil ? "无" : String(format: "%.0f m", inp.b.context.meters), inp.portalA.count, inp.portalB.count))
let straight = c.meters
let margin = max(0.15 * straight, 1500)
let lats = [a.latitude, b.latitude, ca.latitude, cb.latitude], lons = [a.longitude, b.longitude, ca.longitude, cb.longitude]
let midLat = (lats.min()! + lats.max()!) / 2
let dLat = margin / 110_540, dLon = margin / (111_320 * max(0.2, cos(midLat * .pi / 180)))
let s = lats.min()! - dLat, n = lats.max()! + dLat, w = lons.min()! - dLon, e = lons.max()! + dLon
let query = String(format: "[out:json][timeout:55];way[\"railway\"~\"^(rail|light_rail|narrow_gauge|subway|monorail|tram)$\"](%.5f,%.5f,%.5f,%.5f);out geom;", s, w, n, e)
let sem = DispatchSemaphore(value: 0)
Task {
    var elements: [[String: Any]] = []
    for base in RoadNetwork.overpassEndpoints {
        var req = URLRequest(url: URL(string: base)!)
        req.httpMethod = "POST"; req.timeoutInterval = 90
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = ("data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)).data(using: .utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { print("\(base) 请求失败"); continue }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        print("\(base) HTTP \(code)，\(data.count) 字节")
        guard code == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let els = json["elements"] as? [[String: Any]] else { continue }
        elements = els; break
    }
    do {
        var withTags = 0, tunnelWays = 0, tunnelLen = 0.0
        for el in elements {
            if let tags = el["tags"] as? [String: String] { withTags += 1
                if let tv = tags["tunnel"], tv != "no" { tunnelWays += 1
                    if let geom = el["geometry"] as? [[String: Any]] { for k in 1..<geom.count { if let la0 = geom[k-1]["lat"] as? Double, let lo0 = geom[k-1]["lon"] as? Double, let la1 = geom[k]["lat"] as? Double, let lo1 = geom[k]["lon"] as? Double { tunnelLen += GeoMath.haversine(la0, lo0, la1, lo1) } } }
                }
            } else if el["tags"] != nil { print("   tags 不是 [String:String]：\(type(of: el["tags"]!))") }
        }
        print("元素 \(elements.count)，带 tags \(withTags)，tunnel way \(tunnelWays)，隧道 way 总长 \(Int(tunnelLen)) m")
        let path = try RoadNetwork.shortestRailPath(elements: elements, a: ca, b: cb)
        let tun = path.segTunnel.filter { $0 }.count
        print(String(format: "最短路 A′→B′：%d 点，长 %.0f m，隧道段 %d/%d（%.0f m）", path.coords.count, path.acc.last ?? 0, tun, path.segTunnel.count, zip(path.segTunnel, 0..<path.segTunnel.count).reduce(0.0) { $0 + ($1.0 ? path.acc[$1.1 + 1] - path.acc[$1.1] : 0) }))
        let tolOn = max(inp.radius, 10), tolDrift = max(1.5 * inp.radius, 20)
        let an = PortalDrift.analyze(raw: path.coords, a: a, b: b, portalA: inp.portalA, portalB: inp.portalB, tolOn: tolOn, tolDrift: tolDrift)
        print(String(format: "analyze：arcA %.0f arcB %.0f shift %d/%d；notes: %@", an.arcA, an.arcB, an.newA?.shift ?? 0, an.newB?.shift ?? 0, an.notes.joined(separator: " | ")))
        let f = PortalDrift.Frame(origin: a); let P = PortalDrift.Poly(path.coords, frame: f)
        let pa = P.project(f.xy(a)), pb = P.project(f.xy(b))
        print(String(format: "全局投影：A 在弧长 %.0f（离 %.0f m），B 在弧长 %.0f（离 %.0f m）", pa.s, pa.d, pb.s, pb.d))
        let passesA = P.passes(f.xy(a), within: max(25, 1.5 * pa.d + 10)), passesB = P.passes(f.xy(b), within: max(25, 1.5 * pb.d + 10))
        print("经过 A：" + passesA.map { String(format: "s=%.0f d=%.0f", $0.s, $0.d) }.joined(separator: " | ") + "；经过 B：" + passesB.map { String(format: "s=%.0f d=%.0f", $0.s, $0.d) }.joined(separator: " | "))
    } catch { print("错误：\(error)") }
    sem.signal()
}
sem.wait()

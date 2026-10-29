import Foundation
import CoreLocation
setbuf(stdout, nil)
// tunnelprobe2 <footprint.gpx> <garmin.gpx> <HH:mm:ss-HH:mm:ss,...>：窗口内 Garmin 逐点（时间、步时、步长、转向、海拔、离 OSRM 道路几何的垂距）
func load(_ path: String) throws -> TrackData {
    let d = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    var p = try GPXParser.parse(data: d); p.name = (path as NSString).lastPathComponent
    return TrackData.build(parsed: p, preferredMode: .single).0
}
let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
func ts(_ t: Double) -> String { fmt.string(from: Date(timeIntervalSince1970: t)) }
let args = CommandLine.arguments
let foot = try load(args[1]); let g = try load(args[2])
let day = dayFmt.string(from: Date(timeIntervalSince1970: g.time[g.timedCount / 2])).prefix(10)
func parse(_ s: String) -> Double { dayFmt.date(from: "\(day) \(s)")!.timeIntervalSince1970 }
let sem = DispatchSemaphore(value: 0)
Task {
    for w in args[3].split(separator: ",") {
        let parts = w.split(separator: "-"); let t0 = parse(String(parts[0])) - 30, t1 = parse(String(parts[1])) + 30
        let gi = (0..<g.timedCount).filter { g.time[$0] >= t0 && g.time[$0] <= t1 }
        let fi = (0..<foot.timedCount).filter { foot.time[$0] >= t0 && foot.time[$0] <= t1 }
        guard gi.count >= 2 else { print("\n== \(w): Garmin 无点"); continue }
        let A = CLLocationCoordinate2D(latitude: g.lat[gi.first!], longitude: g.lon[gi.first!]), B = CLLocationCoordinate2D(latitude: g.lat[gi.last!], longitude: g.lon[gi.last!])
        print("\n== 窗口 \(w)（±30 s）：Garmin \(gi.count) 点，足迹 \(fi.count) 点；用 OSRM 取窗口首尾点之间的道路几何做参照")
        var road: PortalDrift.Poly? = nil; var frame: PortalDrift.Frame? = nil
        if case .ok(let ans)? = try? await RoadNetwork.fetchOSRM(base: RoadNetwork.carEndpoints[0], a: A, b: B, bearingA: nil, bearingB: nil) {
            let fr = PortalDrift.Frame(origin: A); frame = fr; road = PortalDrift.Poly([A] + ans.coords + [B], frame: fr)
            print(String(format: "   道路几何 %d 点 %.0f m（首尾直线 %.0f m）", ans.coords.count + 2, ans.meters, GeoMath.haversine(A.latitude, A.longitude, B.latitude, B.longitude)))
        } else { print("   OSRM 没取到，只看几何") }
        func dRoad(_ lat: Double, _ lon: Double) -> String {
            guard let road, let frame else { return "  —" }
            let h = road.project(frame.xy(CLLocationCoordinate2D(latitude: lat, longitude: lon)))
            return String(format: "%3.0f", h.d)
        }
        print("   Garmin:  时间     Δt   步长  转向  海拔  离路")
        var prevB: Double? = nil
        for (k, i) in gi.enumerated() {
            var dt = 0.0, step = 0.0, turn = 0.0
            if k > 0 { let j = gi[k - 1]; dt = g.time[i] - g.time[j]; step = GeoMath.haversine(g.lat[j], g.lon[j], g.lat[i], g.lon[i])
                let b = GeoMath.bearing(g.lat[j], g.lon[j], g.lat[i], g.lon[i]); if let pb = prevB { turn = abs(b - pb); if turn > 180 { turn = 360 - turn } }; prevB = b }
            let mark = (fi.contains { abs(foot.time[$0] - g.time[i]) <= 1.5 }) ? "  （足迹同秒有点）" : ""
            print(String(format: "   %@  %4.0f  %5.0f  %4.0f  %5.0f   %@%@", ts(g.time[i]), dt, step, turn, g.ele[i], dRoad(g.lat[i], g.lon[i]), mark))
        }
        print("   足迹同窗：" + fi.map { String(format: "%@(%@m)", ts(foot.time[$0]), dRoad(foot.lat[$0], foot.lon[$0]).trimmingCharacters(in: .whitespaces)) }.joined(separator: " "))
    }
    sem.signal()
}
sem.wait()

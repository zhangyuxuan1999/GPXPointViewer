import Foundation
import CoreLocation
setbuf(stdout, nil)
// chainprobe <gpx> [osrmSamples]：隧道群（相邻断档露天段 ≤90 s / ≤800 m）统计；锚点附近的定位噪声（逐处）；抽样用 OSRM 看露天段点离路多远
func load(_ path: String) throws -> TrackData {
    let d = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    var p = try GPXParser.parse(data: d); p.name = (path as NSString).lastPathComponent
    return TrackData.build(parsed: p, preferredMode: .single).0
}
let fmt = DateFormatter(); fmt.dateFormat = "yy-MM-dd HH:mm:ss"
func ts(_ t: Double) -> String { fmt.string(from: Date(timeIntervalSince1970: t)) }
let args = CommandLine.arguments
let t0 = Date()
let t = try load(args[1])
let profile = SamplingProfile.compute(track: t, creator: t.creator, accuracy: t.gpsAccuracy)
var opt = GapDetector.Options(); opt.staleEnabled = profile.kind == .deviceLogger
let gaps = GapDetector.detect(track: t, options: opt).sorted { $0.indexA < $1.indexA }
print(String(format: "%@: %d 点，载入+检测 %.1f s · 画像 %@ 中位 %.0f s / %.0f m 半径 %.0f · 断档 %d 处（stale %d）", t.name, t.timedCount, Date().timeIntervalSince(t0), profile.kindLabel, profile.medianDt, profile.medianStep, profile.matchRadius, gaps.count, gaps.filter { $0.kind == .staleClock }.count))
// 1) 隧道群
var chains: [[GapCandidate]] = []
var cur: [GapCandidate] = []
for c in gaps {
    if let last = cur.last {
        let dt = c.tA - last.tB, dm = GeoMath.haversine(last.latB, last.lonB, c.latA, c.lonA)
        if dt <= 90, dm <= 800 { cur.append(c); continue }
        chains.append(cur)
    }
    cur = [c]
}
if !cur.isEmpty { chains.append(cur) }
let multi = chains.filter { $0.count >= 2 }
print("隧道群（露天段 ≤90 s 且 ≤800 m 连起来）：\(multi.count) 群，含 \(multi.reduce(0) { $0 + $1.count }) 处断档；群大小分布：" +
      Dictionary(grouping: multi, by: { min($0.count, 6) }).sorted { $0.key < $1.key }.map { "\($0.key)\($0.key == 6 ? "+" : "")处×\($0.value.count)" }.joined(separator: " "))
var openSecs: [Double] = [], openPts: [Int] = []
for ch in multi { for k in 1..<ch.count { openSecs.append(ch[k].tA - ch[k - 1].tB); openPts.append(ch[k].indexA - ch[k - 1].indexB + 1) } }
openSecs.sort(); openPts.sort()
if !openSecs.isEmpty { print(String(format: "露天段时长 中位 %.0f s · p90 %.0f s；露天段点数 中位 %d · p90 %d", openSecs[openSecs.count / 2], openSecs[openSecs.count * 9 / 10], openPts[openPts.count / 2], openPts[openPts.count * 9 / 10])) }
// 2) 逐处定位噪声：锚点外 10–40 步的点相对局部弦（i-3 → i+3）的垂距中位数；与出口头 5 点 / 入口前 5 点相对同一局部弦的垂距比较
func lateral(_ i: Int) -> Double? {
    guard i - 3 >= 0, i + 3 < t.timedCount else { return nil }
    let a = i - 3, b = i + 3
    let kx = 111_320.0 * cos(t.lat[i] * .pi / 180), ky = 110_540.0
    let ux = (t.lon[b] - t.lon[a]) * kx, uy = (t.lat[b] - t.lat[a]) * ky, L = (ux * ux + uy * uy).squareRoot()
    guard L > 20 else { return nil }
    let px = (t.lon[i] - t.lon[a]) * kx, py = (t.lat[i] - t.lat[a]) * ky
    return abs(ux * py - uy * px) / L
}
func med(_ xs: [Double]) -> Double { let s = xs.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }
var farNoise: [Double] = [], nearA: [Double] = [], nearB: [Double] = []
for c in gaps.prefix(2000) {
    var f: [Double] = [], na: [Double] = [], nb: [Double] = []
    for k in 10...40 { if let d = lateral(c.indexA - k) { f.append(d) }; if let d = lateral(c.indexB + k) { f.append(d) } }
    for k in 0..<5 { if let d = lateral(c.indexA - k) { na.append(d) }; if let d = lateral(c.indexB + k) { nb.append(d) } }
    if f.count >= 10 { farNoise.append(med(f)) }
    if !na.isEmpty { nearA.append(med(na)) }
    if !nb.isEmpty { nearB.append(med(nb)) }
}
func stats(_ xs: [Double]) -> String { let s = xs.sorted(); guard !s.isEmpty else { return "—" }; return String(format: "中位 %.1f · p75 %.1f · p90 %.1f m（%d 处）", s[s.count / 2], s[s.count * 3 / 4], s[s.count * 9 / 10], s.count) }
print("锚点外 10–40 步的局部横向噪声：" + stats(farNoise))
print("入口前 0–4 步的横向偏离：" + stats(nearA))
print("出口后 0–4 步的横向偏离：" + stats(nearB))
// 3) 抽样隧道群：OSRM 从群首 A 前 300 m 到群尾 B 后 300 m，露天段点离路多远
let n = args.count > 2 ? Int(args[2]) ?? 0 : 0
if n > 0 {
    let sem = DispatchSemaphore(value: 0)
    Task {
        var picked = 0
        for ch in multi.filter({ $0.count >= 2 }).shuffled().prefix(n * 2) where picked < n {
            let first = ch.first!, last = ch.last!
            var ia = first.indexA, ib = last.indexB
            while ia > 0, GeoMath.haversine(t.lat[ia], t.lon[ia], first.latA, first.lonA) < 300, first.tA - t.time[ia] < 120 { ia -= 1 }
            while ib < t.timedCount - 1, GeoMath.haversine(t.lat[ib], t.lon[ib], last.latB, last.lonB) < 300, t.time[ib] - last.tB < 120 { ib += 1 }
            let A = CLLocationCoordinate2D(latitude: t.lat[ia], longitude: t.lon[ia]), B = CLLocationCoordinate2D(latitude: t.lat[ib], longitude: t.lon[ib])
            let straight = GeoMath.haversine(A.latitude, A.longitude, B.latitude, B.longitude)
            guard straight < 30_000 else { continue }
            guard case .ok(let ans)? = try? await RoadNetwork.fetchOSRM(base: RoadNetwork.carEndpoints[0], a: A, b: B, bearingA: nil, bearingB: nil), ans.meters < 1.6 * straight else { continue }
            picked += 1
            let fr = PortalDrift.Frame(origin: A); let road = PortalDrift.Poly([A] + ans.coords + [B], frame: fr)
            var line = String(format: "群 %@ · %d 处 · 整群 %.1f km/%.0f s · 露天段：", ts(first.tA), ch.count, straight / 1000, last.tB - first.tA)
            for k in 1..<ch.count {
                let idx = Array(ch[k - 1].indexB...ch[k].indexA)
                let ds = idx.map { road.project(fr.xy(CLLocationCoordinate2D(latitude: t.lat[$0], longitude: t.lon[$0]))).d }
                line += String(format: "[%d 点/%.0f s 离路 中位 %.0f 最大 %.0f] ", idx.count, ch[k].tA - ch[k - 1].tB, med(ds), ds.max() ?? 0)
            }
            // 入口前 5 点、出口后 5 点离路
            let pre = (max(0, first.indexA - 4)...first.indexA).map { road.project(fr.xy(CLLocationCoordinate2D(latitude: t.lat[$0], longitude: t.lon[$0]))).d }
            let post = (last.indexB...min(t.timedCount - 1, last.indexB + 4)).map { road.project(fr.xy(CLLocationCoordinate2D(latitude: t.lat[$0], longitude: t.lon[$0]))).d }
            line += "· 入口前5点离路 " + pre.map { String(format: "%.0f", $0) }.joined(separator: "/") + " · 出口后5点 " + post.map { String(format: "%.0f", $0) }.joined(separator: "/")
            print(line)
        }
        sem.signal()
    }
    sem.wait()
}

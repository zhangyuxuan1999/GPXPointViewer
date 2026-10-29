import Foundation
import CoreLocation
setbuf(stdout, nil)
// tunnelprobe <footprint.gpx> <garmin1.gpx> [<garmin2.gpx>…]
// 同一趟车两台设备同时记录：以 Garmin 的断档（隧道）为准，看同一时间窗里足迹有什么；再以足迹的"直线插值段/断档"为准看 Garmin
func load(_ path: String) throws -> TrackData {
    let d = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    var p = try GPXParser.parse(data: d); p.name = (path as NSString).lastPathComponent
    return TrackData.build(parsed: p, preferredMode: .single).0
}
let fmt = DateFormatter(); fmt.dateFormat = "MM-dd HH:mm:ss"
func ts(_ t: Double) -> String { fmt.string(from: Date(timeIntervalSince1970: t)) }
func m(_ x: Double) -> String { x >= 1000 ? String(format: "%.1f km", x / 1000) : String(format: "%.0f m", x) }
struct Win { var idx: [Int] }
func window(_ t: TrackData, from: Double, to: Double) -> [Int] {
    var out: [Int] = []
    for i in 0..<t.timedCount where t.time[i] >= from && t.time[i] <= to { out.append(i) }
    return out
}
/// 点列相对首尾弦的最大垂距 / 弦长；点列总长 / 弦长；时间步统计
func describe(_ t: TrackData, _ idx: [Int]) -> String {
    guard idx.count >= 2 else { return "点 \(idx.count)" }
    let a = idx.first!, b = idx.last!
    let chord = GeoMath.haversine(t.lat[a], t.lon[a], t.lat[b], t.lon[b])
    let kx = 111_320.0 * cos(t.lat[a] * .pi / 180), ky = 110_540.0
    let ux = (t.lon[b] - t.lon[a]) * kx, uy = (t.lat[b] - t.lat[a]) * ky, L = max(1, (ux * ux + uy * uy).squareRoot())
    var maxDev = 0.0, path = 0.0, dts: [Double] = [], steps: [Double] = []
    for (k, i) in idx.enumerated() {
        let px = (t.lon[i] - t.lon[a]) * kx, py = (t.lat[i] - t.lat[a]) * ky
        maxDev = max(maxDev, abs(ux * py - uy * px) / L)
        if k > 0 { let j = idx[k - 1]; let d = GeoMath.haversine(t.lat[j], t.lon[j], t.lat[i], t.lon[i]); path += d; steps.append(d); dts.append(t.time[i] - t.time[j]) }
    }
    dts.sort(); steps.sort()
    let medDt = dts[dts.count / 2], maxDt = dts.last!, medStep = steps[steps.count / 2]
    // 共线窗口占比（8 点窗全部落在首尾连线 3 m 内 = 直线插值的痕迹）
    var collinear = 0, windows = 0
    if idx.count >= 8 {
        for s in stride(from: 0, to: idx.count - 8, by: 4) {
            let w = Array(idx[s..<(s + 8)]); windows += 1
            let a2 = w.first!, b2 = w.last!
            let vx = (t.lon[b2] - t.lon[a2]) * kx, vy = (t.lat[b2] - t.lat[a2]) * ky, l2 = max(1, (vx * vx + vy * vy).squareRoot())
            var ok = true
            for i in w { let px = (t.lon[i] - t.lon[a2]) * kx, py = (t.lat[i] - t.lat[a2]) * ky; if abs(vx * py - vy * px) / l2 > 3 { ok = false; break } }
            if ok { collinear += 1 }
        }
    }
    return String(format: "点 %d · 弦 %@ · 路径/弦 %.2f · 离弦最大 %.0f m · 步时中位 %.0f s 最大 %.0f s · 步长中位 %.0f m · 共线窗 %d/%d · 海拔 %.0f→%.0f",
                  idx.count, m(chord), path / max(1, chord), maxDev, medDt, maxDt, medStep, collinear, windows, t.ele[a], t.ele[b])
}
let args = CommandLine.arguments
let foot = try load(args[1])
let garmins = try args.dropFirst(2).map(load)
for t in [foot] + garmins {
    let p = SamplingProfile.compute(track: t, creator: t.creator, accuracy: t.gpsAccuracy)
    print(String(format: "%@: %d 点 · %@ → %@ · 画像 %@ 中位 %.0f s / %.0f m · creator=%@", t.name, t.timedCount, ts(t.time[0]), ts(t.time[t.timedCount - 1]), p.kindLabel, p.medianDt, p.medianStep, t.creator))
}
print("\n================ 以 Garmin 的断档为准（隧道），看同一时间窗里两边各是什么 ================")
for g in garmins {
    let p = SamplingProfile.compute(track: g, creator: g.creator, accuracy: g.gpsAccuracy)
    var opt = GapDetector.Options(); opt.staleEnabled = p.kind == .deviceLogger
    let gaps = GapDetector.detect(track: g, options: opt).filter { $0.meters >= 300 }.sorted { $0.meters > $1.meters }
    print("\n--- \(g.name)：断档（直线 ≥300 m）\(gaps.count) 处，按长度前 12 ---")
    for c in gaps.prefix(12) {
        print(String(format: "\n[%@] %@ → %@  直线 %@  %.0f s  kind=%@  Garmin 区间内点 %d", String(g.name.prefix(10)), ts(c.tA), ts(c.tB), m(c.meters), c.seconds, c.kind == .staleClock ? "stale" : "tgap", c.innerCount))
        // Garmin 自己：A 前 10 点 … B 后 10 点 的描述，以及区间内点（stale 时有）
        let gIn = Array(c.indexA...c.indexB)
        print("   Garmin A→B 含区间内点：" + describe(g, gIn))
        // 足迹同一时间窗（扩 20 s）
        let fw = window(foot, from: c.tA - 20, to: c.tB + 20)
        if fw.count >= 2 { print("   足迹 同窗(±20s)：" + describe(foot, fw)) } else { print("   足迹 同窗：没有点（\(fw.count)）") }
        // 足迹在 A..B 严格内部有没有点、点是不是直线插值
        let fin = window(foot, from: c.tA + 1, to: c.tB - 1)
        if fin.count >= 2 { print("   足迹 严格区间内：" + describe(foot, fin)) } else { print("   足迹 严格区间内：\(fin.count) 点") }
    }
}
print("\n================ 以足迹为准：足迹里的断档（时间空洞）在 Garmin 那边是什么 ================")
do {
    let p = SamplingProfile.compute(track: foot, creator: foot.creator, accuracy: foot.gpsAccuracy)
    var opt = GapDetector.Options(); opt.staleEnabled = false
    let gaps = GapDetector.detect(track: foot, options: opt).filter { $0.meters >= 300 }.sorted { $0.meters > $1.meters }
    print("足迹断档（直线 ≥300 m）\(gaps.count) 处，按长度前 10（画像 \(p.kindLabel)）")
    for c in gaps.prefix(10) {
        print(String(format: "\n[足迹] %@ → %@  直线 %@  %.0f s  区间内点 %d", ts(c.tA), ts(c.tB), m(c.meters), c.seconds, c.innerCount))
        for g in garmins {
            let gw = window(g, from: c.tA - 20, to: c.tB + 20)
            if gw.count >= 2 { print("   \(g.name.prefix(14)) 同窗(±20s)：" + describe(g, gw)) }
        }
    }
}

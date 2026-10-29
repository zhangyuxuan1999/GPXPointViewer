import Foundation
import CoreLocation
setbuf(stdout, nil)
// railprobe2 <gpx> <i,i,…>：直接调 RoadNetwork.railRoute（与 app 同一函数），打印补/不补及原因
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
let fmt = DateFormatter(); fmt.dateFormat = "MM-dd HH:mm"
let sem = DispatchSemaphore(value: 0)
Task {
    for s in args[2].split(separator: ",") {
        let c = gaps[Int(s)!]
        let inp = GapRouteInputs.build(t, ia: c.indexA, ib: c.indexB, profile: profile)
        let a = CLLocationCoordinate2D(latitude: c.latA, longitude: c.lonA), b = CLLocationCoordinate2D(latitude: c.latB, longitude: c.lonB)
        print(String(format: "\n== #%@ %@ 直线 %.0f m %.0f s（A′ %@，B′ %@）", String(s), fmt.string(from: Date(timeIntervalSince1970: c.tA)), c.meters, c.seconds, inp.a.context.anchor == nil ? "无" : "有", inp.b.context.anchor == nil ? "无" : "有"))
        do {
            let d = try await RoadNetwork.railRoute(a: a, b: b, contextA: inp.a.context.anchor, contextB: inp.b.context.anchor,
                                                   portalA: inp.portalA, portalB: inp.portalB, matchRadius: inp.radius, seconds: c.seconds)
            print(String(format: "   补：%d 顶点 路长 %.0f m snap %.0f/%.0f shift %d/%d 警告 %d", d.coords.count, d.meters, d.snapA, d.snapB, d.shiftA, d.shiftB, d.warnings.count))
            for n in d.notes where n.contains("隧道") || n.contains("露天") || n.contains("漂移") { print("      · " + n) }
            for w in d.warnings { print("      ⚠︎ " + w) }
        } catch let e as RouteError {
            print("   " + ((e.isRailSkip ? "不补：" : "失败：") + (e.errorDescription ?? "\(e)")))
        } catch { print("   错误：\(error)") }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }
    sem.signal()
}
sem.wait()

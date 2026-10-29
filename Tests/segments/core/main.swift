import Foundation
import Cocoa

var passed = 0
var failed: [String] = []
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if value() { passed += 1 } else { failed.append(message); print("FAIL: \(message)") }
}
func point(_ lat: Double, _ lon: Double, _ second: Int?, _ ele: Int = 0) -> String {
    let t = second.map { "<time>2026-01-01T00:\(String(format: "%02d", $0 / 60)):\(String(format: "%02d", $0 % 60))Z</time>" } ?? ""
    return "<trkpt lat=\"\(lat)\" lon=\"\(lon)\"><ele>\(ele)</ele>\(t)</trkpt>"
}
func build(_ p: ParsedTrack) -> TrackData { TrackData.build(parsed: p, preferredMode: .single).0 }
func parsed(_ xml: String) throws -> ParsedTrack { try GPXParser.parse(data: Data(xml.utf8)) }
func raw(_ times: [Double], _ ids: [UInt32] = [], _ coordinates: [Double]? = nil) -> ParsedTrack {
    var p = ParsedTrack()
    p.time = times; p.segmentID = ids
    p.lat = coordinates ?? times.indices.map { Double($0) * 0.0001 }
    p.lon = [Double](repeating: 0, count: times.count)
    p.ele = times.indices.map(Double.init)
    return p
}
func edges(_ t: TrackTopology, _ kind: PathDrawKind, _ range: Range<Int>, _ stride: Int,
           soft: Bool = true) -> [[Int]] {
    let plan = t.makeDrawRuns(kind: kind, globalTimeRange: range, stride: stride, includeSoftBreaks: soft)
    var out: [[Int]] = []
    var expected = 0
    for r in plan.runs {
        check(Int(r.firstInstance) == expected, "draw instance prefix")
        expected += Int(r.instanceCount)
        let len = Int(r.end - r.begin)
        for j in 0..<Int(r.instanceCount) {
            let a = Int(r.begin) + min(j * plan.stride, len - 1)
            let b = Int(r.begin) + min((j + 1) * plan.stride, len - 1)
            out.append([t.globalIndex(atPathRank: a), t.globalIndex(atPathRank: b)])
        }
    }
    check(expected == plan.instanceCount, "draw instance total")
    return out
}

do {
    // True production parser/build, not a topology model.
    let a = point(0, 0, 0) + point(0.0004, 0, 2)
    let b = point(0.01, 0, 1) + point(0.0104, 0, 3)
    let xml = "<gpx><trk><trkseg>\(a)</trkseg><trkseg>\(b)</trkseg></trk></gpx>"
    let p = try parsed(xml), t = build(p)
    check(p.segmentID.count == 4, "parser writes full segment column")
    check(p.segmentID[0] == p.segmentID[1] && p.segmentID[0] != p.segmentID[2], "trkseg identities")
    check(t.ele == [0, 0, 0, 0] && t.time == t.time.sorted(), "global normalization")
    check(t.topology.order == [0, 2, 1, 3], "interleaved path order")
    check(t.topology.rank == [0, 2, 1, 3], "interleaved inverse")
    check(t.topology.adjacent(to: 0, direction: 1) == 2, "true successor 0→2")
    check(t.topology.adjacent(to: 3, direction: -1) == 1, "true predecessor 1→3")
    check(t.topology.adjacent(to: 2, direction: 1) == nil, "segment end remains bounded")
    check(t.topology.innerCount(0, 3) == nil, "cross segment membership rejected")
    check(Array(t.topology.indices(between: 0, and: 2, includeEnds: true)!) == [0, 2], "path member view")
    for step in [1, 2, 100] {
        check(edges(t.topology, .line, 0..<4, step) == [[0, 2], [1, 3]], "overlap line stride \(step)")
        check(edges(t.topology, .fog, 0..<4, step) == [[0, 2], [1, 3]], "overlap fog stride \(step)")
    }
    check(edges(t.topology, .line, 1..<4, 100) == [[1, 3]], "filtered line")
    check(edges(t.topology, .fog, 1..<4, 100) == [[2, 2], [1, 3]], "filtered fog singleton")
    let ta = build(try parsed("<gpx><trk><trkseg>\(a)</trkseg></trk></gpx>"))
    let tb = build(try parsed("<gpx><trk><trkseg>\(b)</trkseg></trk></gpx>"))
    check(abs(t.totalMercLength - ta.totalMercLength - tb.totalMercLength) < 1e-14, "length excludes false bridges")
    check(abs(t.speedKmh[0] - ta.speedKmh[0]) < 1e-8 && abs(t.speedKmh[2] - ta.speedKmh[1]) < 1e-8, "A speed standalone equivalence")
    check(abs(t.speedKmh[1] - tb.speedKmh[0]) < 1e-8 && abs(t.speedKmh[3] - tb.speedKmh[1]) < 1e-8, "B speed standalone equivalence")
    check(Set(t.fogUnlockKeys()) == Set(ta.fogUnlockKeys()).union(tb.fogUnlockKeys()), "fog DDA true edges, no false bridge")
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("segments-core-\(UUID()).gpx")
    defer { try? FileManager.default.removeItem(at: url) }
    try GPXWriter.write(track: t, indices: [0, 1, 2, 3], name: "overlap", to: url)
    let reread = build(try GPXParser.parse(data: Data(contentsOf: url)))
    check(reread.count == 4 && reread.topology.segments.count == 2, "GPX reread preserves segments")
    check(edges(reread.topology, .line, 0..<4, 1) == [[0, 2], [1, 3]], "GPX reread true edges")
    try GPXWriter.write(track: t, segments: [[0, 1, 2, 3], [1, 3]], name: "windows", to: url)
    let windowed = build(try GPXParser.parse(data: Data(contentsOf: url)))
    check(windowed.count == 6 && windowed.topology.segments.count == 3, "incremental supplied windows split by source")

    // Actual writer must distinguish identical coordinates/times from separate sources.
    var twins = raw([1, 1], [7, 8], [0, 0])
    twins.ele = [0, 0]
    let twinTrack = build(twins)
    let onlySeven: Set<GapFillExport.PointKey> = [GapFillExport.PointKey(1, 0, 0, segment: 7)]
    try GPXWriter.write(track: twinTrack, indices: [0, 1], name: "segment-synthetic", to: url, synthetic: onlySeven)
    let taggedXML = try String(contentsOf: url, encoding: .utf8)
    let segmentBodies = Array(taggedXML.components(separatedBy: "<trkseg>").dropFirst())
    let marker = "<src>GPXPointViewer-fill</src>"
    check(segmentBodies.count == 2, "synthetic twins remain separate GPX segments")
    check(taggedXML.components(separatedBy: marker).count - 1 == 1, "exactly one identical-coordinate source marked synthetic")
    check(segmentBodies[0].contains(marker) && !segmentBodies[1].contains(marker), "synthetic marker follows segment7 only")
    try GPXWriter.write(track: twinTrack, indices: [1], name: "segment-real-only", to: url, synthetic: onlySeven)
    let realOnlyXML = try String(contentsOf: url, encoding: .utf8)
    check(!realOnlyXML.contains(marker), "filtered real twin never inherits another segment synthetic marker")

    // Lexical exclusions and containers. Fake markup must neither count nor assign segments.
    let poison = "<!-- <trkseg><trkpt lat=\"89\" lon=\"179\"/></trkseg> --><![CDATA[<trkseg><wpt lat=\"88\" lon=\"178\"/></trkseg>]]>"
    let tricky = "<gpx>\(poison)<trk hint='<trkseg><trkpt lat=\"87\" lon=\"177\"/>'><trkseg><trkpt lat='1' lon='2'><![CDATA[<time>1900-01-01T00:00:00Z</time>]]><time>2026-01-01T00:00:00Z</time></trkpt></trkseg></trk><trk><trkpt lat=\"1\" lon=\"2\"/></trk><rte><rtept lat=\"1\" lon=\"2\"/><rtept lat=\"1\" lon=\"2\"/></rte><wpt lat=\"1\" lon=\"2\"/><wpt lat=\"1\" lon=\"2\"/></gpx>"
    let tp = try parsed(tricky)
    check(tp.count == 6 && GPXParser.countPoints(data: Data(tricky.utf8)) == 6, "fake tags excluded from parse and count")
    check(Set(tp.segmentID).count == 5 && tp.segmentID[2] == tp.segmentID[3], "trk/rte/wpt source identities")
    check(tp.time[0] > 1_700_000_000, "CDATA time ignored")
    let sample = GPXParser.sampleScan(data: Data(tricky.utf8), targetPoints: 20)
    check(sample.totalPointCount == 6 && sample.segmentID.count == sample.count && sample.lat.allSatisfy { $0 == 1 }, "sampling retains source and excludes fake tags")
    check(sample.firstTime > 1_700_000_000 && sample.lastTime > 1_700_000_000, "sampling ignores CDATA time")
    let sliced = GPXParser.slice(tp, range: 1..<5, name: "slice")
    check(sliced.segmentID == Array(tp.segmentID[1..<5]), "slice metadata")

    // Chunk starts fall in already-open source containers, and bad points compact both columns.
    var big = "<gpx><trk>"
    let points = 12_000
    for i in 0..<points {
        if i == 0 || i == 5_123 { big += "<trkseg>" }
        if i == 100 { big += "<trkpt lon=\"0\"><ele>100</ele></trkpt>" }
        else { big += "<trkpt lat=\"0\" lon=\"0\"><ele>\(i)</ele></trkpt>" }
        if i == 5_122 || i == points - 1 { big += "</trkseg>" }
    }
    big += "</trk></gpx>"
    let bp = try parsed(big)
    check(bp.count == points - 1 && bp.chunkCount > 1, "parallel parse plus invalid compact")
    check(bp.segmentID.count == bp.count && Set(bp.segmentID).count == 2, "parallel segment column complete")
    check(zip(bp.ele, bp.segmentID).allSatisfy { ($0 < 5_123) == ($1 == bp.segmentID[0]) }, "chunk segment ownership")
    let many = GPXParser.parseMany(files: [Data(big.utf8), Data(tricky.utf8), Data("dataTime,longitude,latitude\n1,2,1\n2,2,1\n".utf8)])
    check(many.failedFiles.isEmpty && many.merged.count == bp.count + tp.count + 2, "parseMany mixed sources")
    let firstIDs = Set(many.merged.segmentID.prefix(bp.count))
    let restIDs = Set(many.merged.segmentID.dropFirst(bp.count))
    check(firstIDs.isDisjoint(with: restIDs), "parseMany file namespaces disjoint")

    // All normalization paths: fallback, overlap heap merge, disjoint block moves, equal times, NaN tails.
    let unsorted = build(raw([2, 1, 1, .nan, 0, .nan], [7, 8, 7, 8, 7, 8]))
    check(unsorted.ele == [4, 1, 2, 0, 3, 5], "fallback stable duplicates and missing time")
    check(unsorted.segmentID == [7, 8, 7, 7, 8, 8], "fallback segment permutation")
    for inputs in [
        [raw([0, 2, 2, .nan], [0, 0, 0, 0]), raw([1, 2, 3, .nan], [0, 0, 0, 0])],
        [raw([10, 11, .nan], [8, 8, 8]), raw([0, 1, .nan], [8, 8, 8])],
        [raw([0, 1], [0, 0]), raw([1, 2], [0, 0])]
    ] {
        let merged = GPXParser.mergeParsed(inputs)
        let track = build(merged)
        let expected = merged.time.indices.sorted {
            let a = merged.time[$0].isFinite ? merged.time[$0] : Double.infinity
            let b = merged.time[$1].isFinite ? merged.time[$1] : Double.infinity
            return a == b ? $0 < $1 : a < b
        }
        check(track.ele == expected.map { merged.ele[$0] }, "merge stable normalization")
        check(track.fileID == expected.map { merged.fileID[$0] }, "merge file ownership")
        check(track.segmentID == expected.map { merged.segmentID[$0] }, "merge source ownership")
        check(track.topology.segments.count == 2, "merge remaps equal source labels")
    }
    let soft = build(raw([0, 1, 2_000, 2_001, 2_002]))
    check(edges(soft.topology, .line, 0..<5, 3) == [[0, 1], [2, 4]], "LOD cannot jump soft break")
    check(edges(soft.topology, .line, 0..<5, 3, soft: false) == [[0, 3], [3, 4]], "unculled line preserves tail")
    let tail = build(raw([0, 1, 2, 3, 4]))
    check(tail.topology.order.isEmpty && tail.topology.rank.isEmpty, "single identity fast storage")
    check(edges(tail.topology, .line, 0..<5, 3) == [[0, 3], [3, 4]], "identity LOD tail")
    check(edges(tail.topology, .fog, 2..<3, 999) == [[2, 2]], "identity filtered singleton")
    check(MemoryLayout<PathDrawRun>.size == 16 && MemoryLayout<PathDrawRun>.stride == 16, "draw ABI")
    let shape = GPXTrackShape(lat: t.lat, lon: t.lon, segmentID: t.segmentID)
    check(shape.connectedEdgeCount == 2, "QuickLook overlap draws two real strokes")
    let isolated = GPXTrackShape(lat: [0, 0.00001], lon: [0, 0], segmentID: [1, 2])
    check(isolated.connectedEdgeCount == 0, "QuickLook close separate segments do not join")
    let singleton = build(raw([1], [99]))
    check(singleton.speedKmh == [0] && singleton.totalMercLength == 0, "singleton kinematics")
    check(edges(singleton.topology, .fog, 0..<1, 1) == [[0, 0]], "singleton fog")
} catch { failed.append("unexpected error \(error)") }
let report: [String: Any] = ["passed": passed, "failed": failed, "gpuPublication": "stubbed (no GPU submitted)", "productSources": ["GPXParser", "TrackData", "GeoCompute", "GPXWriter", "TrackShape"]]
let json = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(data: json, encoding: .utf8)!)
exit(failed.isEmpty ? 0 : 1)

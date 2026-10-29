import Foundation
let n = 1_000_000
let begin = DispatchTime.now().uptimeNanoseconds
var p = ParsedTrack()
p.lat = (0..<n).map { Double($0) * 0.0000001 }
p.lon = [Double](repeating: 0, count: n)
p.ele = [Double](repeating: .nan, count: n)
p.time = (0..<n).map(Double.init)
let b0 = DispatchTime.now().uptimeNanoseconds
let t = TrackData.build(parsed: p, preferredMode: .single).0
let b1 = DispatchTime.now().uptimeNanoseconds
let xml = Data(("<gpx><trk><trkseg>" + String(repeating: "<trkpt lat=\"0\" lon=\"0\"/>", count: n) + "</trkseg></trk></gpx>").utf8)
let p0 = DispatchTime.now().uptimeNanoseconds
let parsed = try GPXParser.parse(data: xml)
let p1 = DispatchTime.now().uptimeNanoseconds
assert(parsed.count == n && t.count == n)
#if SEGMENT_TOPOLOGY
assert(t.topology.order.isEmpty && t.topology.rank.isEmpty)
let plan = t.topology.makeDrawRuns(kind: .line, globalTimeRange: 0..<n, stride: 3)
assert(plan.instanceCount == (n - 2) / 3 + 1 && plan.runs.count == 1)
let parsedTrack = TrackData.build(parsed: parsed, preferredMode: .single).0
assert(parsedTrack.topology.order.isEmpty && parsedTrack.topology.segments.count == 1)
#endif
print("{\"count\":\(n),\"build_ms\":\(Double(b1-b0)/1e6),\"parse_ms\":\(Double(p1-p0)/1e6),\"bytes\":\(xml.count),\"wall_ms\":\(Double(DispatchTime.now().uptimeNanoseconds-begin)/1e6)}")

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

var passed = 0
var failed: [String] = []
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { passed += 1 }
    else { failed.append(message) }
}

let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

func archive(_ caseName: String) -> FogArchive? {
    FogArchive.load(url: fixtures.appendingPathComponent(caseName + ".fwdb"))
}

// The fixture has one bit in tile 0 of its block. Expected keys are computed
// from the documented 512 blocks * 8192 cells layout, independent of decoder.
for caseName in ["zero", "padded-zero"] {
    let a = archive(caseName)
    check(a?.levelKeys.first == [0], "N20 \(caseName) imports world origin cell")
    check(a?.stats.cells == 1, "N20 \(caseName) has exactly one cell")
}
let lastCell = UInt64(511 * 8192)
let lastKey = (lastCell << 22) | lastCell
for caseName in ["max", "padded-max"] {
    let a = archive(caseName)
    check(a?.levelKeys.first == [lastKey], "N20 \(caseName) imports maximum legal block")
    check((a?.bbox.maxX ?? 2) <= 1 && (a?.bbox.maxY ?? 2) <= 1, "N20 \(caseName) remains inside world")
}
for caseName in ["out-of-world", "u64-overflow", "long-nines", "bad-cipher"] {
    check(archive(caseName) == nil, "N20 \(caseName) rejected without trap or wrapped valid region")
}
check(archive("mixed")?.levelKeys.first == [UInt64(8192) << 22],
      "N20 polluted archive keeps valid block and rejects invalid blocks")

// Foundation XMLParser inspects actual written XML: no product parser or
// GPXWriter helper supplies the expected segment grouping or point order.
final class WrittenGPX: NSObject, XMLParserDelegate {
    var segments: [[Double]] = []
    var synthetic = 0
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if element == "trkseg" { segments.append([]) }
        if element == "trkpt", let lat = attributes["lat"].flatMap(Double.init), !segments.isEmpty {
            segments[segments.count - 1].append(lat)
        }
        text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        if element == "src", text == "GPXPointViewer-fill" { synthetic += 1 }
    }
}

func inspect(_ url: URL) throws -> WrittenGPX {
    let delegate = WrittenGPX()
    let parser = XMLParser(data: try Data(contentsOf: url))
    parser.delegate = delegate
    guard parser.parse() else { throw parser.parserError! }
    return delegate
}

func makeTrack(count: Int, interleaved: Bool = false) -> TrackData {
    var p = ParsedTrack()
    p.name = "probe"
    p.lat = (0..<count).map { 40 + Double($0) * 0.00001 }
    p.lon = [Double](repeating: 10, count: count)
    p.ele = [Double](repeating: .nan, count: count)
    p.time = (0..<count).map { 1_700_000_000 + Double($0) }
    p.segmentID = (0..<count).map { interleaved ? UInt32($0 % 2 + 7) : 0 }
    return TrackData.build(parsed: p, preferredMode: .single).0
}

let track = makeTrack(count: 4, interleaved: true)
let target = output.appendingPathComponent("export.gpx")
let sentinel = Data("existing destination must survive failed export".utf8)
let invalid: [[[Int32]]] = [
    [[-1]], [[Int32.min]], [[4]], [[Int32.max]], [[0, 4, 2]], [[0, 2], [1, -1, 3]],
]
for (i, selections) in invalid.enumerated() {
    try sentinel.write(to: target)
    var expectedError = false
    do { try GPXWriter.write(track: track, segments: selections, name: "invalid", to: target) }
    catch GPXWriteError.invalidSelection { expectedError = true }
    catch { failed.append("N26 unexpected error type: \(error)") }
    check(expectedError, "N26 invalid selection \(i) returns recoverable invalidSelection")
    check((try? Data(contentsOf: target)) == sentinel, "N26 invalid selection \(i) preserves existing file")
}
let missingTarget = output.appendingPathComponent("must-not-exist.gpx")
do {
    try GPXWriter.write(track: track, indices: [0, -1], name: "invalid", to: missingTarget)
    check(false, "N26 invalid indices overload must throw")
} catch GPXWriteError.invalidSelection { check(true, "N26 indices overload propagates recoverable error") }
check(!FileManager.default.fileExists(atPath: missingTarget.path), "N26 invalid request creates no partial file")
try sentinel.write(to: target)
do {
    try GPXWriter.write(track: track, segments: [[], []], name: "empty", to: target)
    check(false, "N26 empty export must throw")
} catch GPXWriteError.noPoints { check(true, "N26 empty export retains noPoints") }
check((try? Data(contentsOf: target)) == sentinel, "N26 empty export preserves existing file")

let synthetic: Set<GapFillExport.PointKey> = [
    .init(track.time[0], track.lat[0], track.lon[0], segment: 7),
]
try GPXWriter.write(track: track, segments: [[2, 1, 0, 3], [], [3, 1]],
                    name: "windows & <source>", to: target, synthetic: synthetic)
let windows = try inspect(target)
check(windows.segments == [[40, 40.00002], [40.00001, 40.00003], [40.00001, 40.00003]],
      "writer keeps true source segments, order and caller windows")
check(windows.synthetic == 1, "writer keeps segment-aware synthetic marker")
try GPXWriter.write(track: track, indices: [2, 0, 2], name: "duplicate", to: target)
check((try? inspect(target))?.segments == [[40, 40.00002, 40.00002]], "writer preserves valid repeated selections")

// 20,001 points selects the existing parallel serialization branch, verifying
// the new selection guard does not alter chunk boundaries or drop endpoints.
let large = makeTrack(count: 20_001)
try GPXWriter.write(track: large, indices: (0..<large.count).map(Int32.init), name: "parallel", to: target)
let parallel = try inspect(target)
check(parallel.segments.count == 1 && parallel.segments[0].count == large.count,
      "writer parallel branch preserves one segment and all points")
check(parallel.segments.first?.first == 40 && parallel.segments.first?.last == 40.2,
      "writer parallel branch keeps first/last points")

let report: [String: Any] = ["passed": passed, "failed": failed, "count": passed + failed.count,
                            "scope": "N20 filename bounds and N26 writer selection safety; actual product sources, offline"]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
try data.write(to: output.appendingPathComponent("checks.json"))
exit(failed.isEmpty ? 0 : 1)

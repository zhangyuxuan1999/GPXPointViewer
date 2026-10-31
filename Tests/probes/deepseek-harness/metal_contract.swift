import Foundation
import Metal

var passed = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { print("FAIL \(label)"); exit(1) }
    passed += 1
    print("PASS \(label)")
}
func makeTrack() -> TrackData {
    var parsed = ParsedTrack()
    parsed.lat = [48, 48.001, 48.002]
    parsed.lon = [11, 11.001, 11.002]
    parsed.ele = [100, 110, 120]
    parsed.time = [0, 1, 2]
    return TrackData.build(parsed: parsed, preferredMode: .single).0
}
let args = CommandLine.arguments
var cpuChecks = 0
let output = URL(fileURLWithPath: args[2])
func writeResult(gpu: Bool, gpuChecks: Int) {
    let result: [String: Any] = ["cpu_checks": cpuChecks, "gpu_available": gpu,
                               "gpu_checks": gpuChecks, "total_checks": passed,
                               "scope": "actual renderer malformed-column contract; no app/UI/draw"]
    try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
}
let mutations: [(String, (TrackData) -> Void)] = [
    ("rtcX", { $0.rtcX = [] }),
    ("rtcX", { $0.rtcX.removeLast() }),
    ("rtcY", { $0.rtcY.append(1) }),
    ("unitX", { $0.unitX.removeLast() }),
    ("unitY", { $0.unitY = [] }),
    ("unitZ", { $0.unitZ.append(1) }),
    ("liftF", { $0.liftF.removeLast() }),
    ("colors", { $0.colors.removeLast() }),
    ("colors", { $0.colors = [] }),
    ("fileID", { $0.fileID = [0] }),
    ("lineBreakPrefix", { $0.lineBreakPrefix = [0] }),
    ("fogBreakPrefix", { $0.fogBreakPrefix = [0] }),
    ("spatialOrder", { $0.spatialOrder = [0] }),
    ("spatialOrder", { $0.spatialOrder = [0, 1, UInt32.max] }),
    ("spatialKeys", { $0.spatialKeys = [] }),
    ("spatialFirsts", { $0.spatialFirsts = [UInt32.max] }),
    ("topology", { $0.topology = TrackTopology(segmentID: [], count: 2) })
]
if !args.contains("--gpu-only") {
    require(TrackGPUBuffers.validationIssue(for: makeTrack()) == nil, "valid TrackData column counts accepted")
    for (index, mutation) in mutations.enumerated() {
        let track = makeTrack()
        mutation.1(track)
        let issue = TrackGPUBuffers.validationIssue(for: track)
        print("REJECTION \(index): \(issue ?? "MISSING")")
        require(issue?.contains(mutation.0) == true, "malformed \(index) reports column \(mutation.0)")
    }
    let implicit = makeTrack()
    implicit.fileID = []; implicit.lineBreakPrefix = []; implicit.fogBreakPrefix = []
    require(TrackGPUBuffers.validationIssue(for: implicit) == nil, "empty optional columns retain implicit defaults")
    cpuChecks = passed
}
guard let device = MTLCreateSystemDefaultDevice() else {
    print("UNSUPPORTED GPU unavailable; CPU checks executed in this invocation: \(cpuChecks)")
    writeResult(gpu: false, gpuChecks: 0)
    exit(77)
}
let library = try device.makeLibrary(source: String(contentsOfFile: args[1], encoding: .utf8), options: nil)
let renderer = MetalPointRenderer(library: library)!
for (index, mutation) in mutations.enumerated() {
    let valid = makeTrack()
    renderer.setData(track: valid)
    require((renderer.topologyDrawStats["segments"] ?? 0) > 0, "renderer has valid data before malformed \(index)")
    // Preserve any prebuilt buffers to verify validation precedes adoption too.
    let invalid = makeTrack()
    mutation.1(invalid)
    require(TrackGPUBuffers(device: device, track: invalid) == nil,
            "background prebuild rejects malformed \(index)")
    renderer.setData(track: invalid)
    require(renderer.topologyDrawStats["segments"] == 0,
            "renderer clears draw topology for malformed \(index)")
}
writeResult(gpu: true, gpuChecks: passed - cpuChecks)
print("ALL PASS \(passed); no window or GPU draw was submitted")

import Foundation
setbuf(stdout, nil)
// mergeprobe <gpx>…：合并隧道群前后的候选数、群大小分布、并掉的点数
func load(_ path: String) throws -> TrackData {
    let d = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    var p = try GPXParser.parse(data: d); p.name = (path as NSString).lastPathComponent
    return TrackData.build(parsed: p, preferredMode: .single).0
}
for path in CommandLine.arguments.dropFirst() {
    let t = try load(path)
    let profile = SamplingProfile.compute(track: t, creator: t.creator, accuracy: t.gpsAccuracy)
    var opt = GapDetector.Options(); opt.staleEnabled = profile.kind == .deviceLogger
    let raw = GapDetector.detect(track: t, options: opt)
    var nature: [Double: GapNature] = [:]
    for c in raw { nature[c.tA] = GapRouteInputs.localSampling(t, ia: c.indexA, ib: c.indexB, profile: profile).nature }
    let merged = GapDetector.mergeChains(raw) { nature[$0.tA] == .lossOfLock && nature[$1.tA] == .lossOfLock }
    let sparseRaw = raw.filter { nature[$0.tA] == .sparseSampling }.count
    let chains = merged.filter { $0.chainCount > 1 }
    let swallowed = chains.reduce(0) { $0 + $1.innerCount }
    let dist = Dictionary(grouping: chains, by: { min($0.chainCount, 6) }).sorted { $0.key < $1.key }.map { "\($0.key)\($0.key == 6 ? "+" : "")处×\($0.value.count)" }.joined(separator: " ")
    print(String(format: "%@: 候选 %d（其中采样稀疏 %d）→ %d（群 %d 个：%@；并进区间的点 %d）", t.name, raw.count, sparseRaw, merged.count, chains.count, dist, swallowed))
}

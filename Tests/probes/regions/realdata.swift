// 真实数据模式（在 main.swift 的断言之前按参数分流）：
//   regions_probe <Regions.bin> --csv <lat,lon[,unix]> 文件…     点口径：各国/省/市点数
//   regions_probe <Regions.bin> --fwdb <存档目录>                 迷雾口径：各国 km² + 下级前 12，和存档总量对账
//   regions_probe <Regions.bin> --lookup lat lon [lat lon …]      逐点归属链
//   regions_probe <Regions.bin> --audit                           名称/ISO/层级体检
import Foundation

func chain(_ idx: RegionIndex, _ id: UInt16?) -> String {
    guard var cur = id else { return "none" }
    var parts: [String] = []
    while let r = idx.region(cur) { parts.append(r.nameHans.isEmpty ? r.nameEn : r.nameHans); guard r.hasParent else { break }; cur = r.parent }
    return parts.joined(separator: " < ")
}
func fmt(_ v: Double, _ d: Int = 5) -> String { String(format: "%.\(d)f", v) }

func runRealData(_ args: [String]) -> Bool {
    guard args.count >= 3, args[2].hasPrefix("--") else { return false }
    guard let idx = RegionIndex.load(url: URL(fileURLWithPath: args[1])) else { print("load failed"); exit(2) }
    let mode = args[2]
    switch mode {
    case "--lookup":
        var i = 3
        while i + 1 < args.count, let la = Double(args[i]), let lo = Double(args[i + 1]) {
            print("\(la),\(lo) -> \(chain(idx, idx.lookup(lat: la, lon: lo)))"); i += 2
        }
    case "--audit":
        let byLevel = Dictionary(grouping: idx.regions, by: \.level).mapValues(\.count)
        print("regions \(idx.regions.count) byLevel \(byLevel.sorted { $0.key < $1.key })")
        let noIso = idx.regions.filter { $0.level == 0 && $0.flag.isEmpty }
        print("countries without flag (\(noIso.count)): \(noIso.map(\.nameEn).joined(separator: ", "))")
        let emptyHans = idx.regions.filter { $0.nameHans.isEmpty }
        print("empty zh-Hans names: \(emptyHans.count)  e.g. \(emptyHans.prefix(8).map { "\($0.nameEn)#\($0.id)" })")
        let emptyEn = idx.regions.filter { $0.nameEn.isEmpty && $0.level < 2 }
        print("empty en names (level<2): \(emptyEn.count)  e.g. \(emptyEn.prefix(8).map { "\($0.nameHans)#\($0.id)" })")
        var perCountry: [UInt16: Int] = [:]
        for r in idx.regions where r.level == 1 { perCountry[r.parent, default: 0] += 1 }
        let big = perCountry.filter { $0.value > 40 }.sorted { $0.value > $1.value }
        print("countries with >40 admin1: \(big.map { "\(idx.region($0.key)!.nameEn)=\($0.value)" })")
        let zeroKids = idx.countries.filter { (idx.children[$0] ?? []).isEmpty }
        print("countries with 0 admin1 (\(zeroKids.count)): \(zeroKids.prefix(40).map { idx.region($0)!.nameEn })")
        for n in ["中国", "德国", "香港", "澳门", "北京", "上海", "黑龙江", "巴登-符腾堡"] {
            if let r = idx.regions.first(where: { $0.nameHans == n }) { print("  \(n): level \(r.level) children \(idx.children[r.id]?.count ?? 0) area \(fmt(r.areaKm2, 0)) km² en=\(r.nameEn) de=\(r.nameDe) hant=\(r.nameHant)") } else { print("  \(n): NOT FOUND") }
        }
    case "--csv":
        for f in args[3...] {
            guard let text = try? String(contentsOfFile: f, encoding: .utf8) else { print("cannot read \(f)"); continue }
            var la: [Double] = [], lo: [Double] = [], tm: [Double] = []
            for line in text.split(separator: "\n") {
                let p = line.split(separator: ",")
                guard p.count >= 2, let a = Double(p[0]), let b = Double(p[1]) else { continue }
                la.append(a); lo.append(b); tm.append(p.count > 2 ? (Double(p[2]) ?? .nan) : .nan)
            }
            let timed = tm.filter { $0.isFinite }.count
            let track = TrackData(lat: la, lon: lo, time: tm, timedCount: timed == la.count ? timed : 0)
            let t0 = Date(); let rep = RegionStatsBuilder.points(track: track, index: idx); let dt = Date().timeIntervalSince(t0)
            print("== \(f): \(la.count) points, \(fmt(dt, 2)) s, unassigned \(rep.unassignedPoints)")
            for c in rep.countries(idx) {
                let r = idx.region(c)!; print("  \(r.nameHans) \(r.flag): \(rep.stats[c]!.points) pts, days \(rep.stats[c]!.days)")
                for k in rep.visitedChildren(of: c, idx).prefix(12) { print("     \(idx.region(k)!.nameHans): \(rep.stats[k]!.points)") }
                if rep.stats[c]!.points < 1000 {        // 疑似边界漏点：列出样本坐标
                    var shown = 0
                    for i in 0..<la.count where shown < 8 {
                        if let id = idx.lookup(lat: la[i], lon: lo[i]), idx.country(of: id) == c { print("       sample \(fmt(la[i], 5)),\(fmt(lo[i], 5))"); shown += 1 }
                    }
                }
            }
        }
    case "--fwdb":
        guard args.count > 3, let arch = FogArchive.load(url: URL(fileURLWithPath: args[3])) else { print("fwdb load failed"); exit(2) }
        let keys = arch.levelKeys[0]
        let t0 = Date(); let rep = RegionStatsBuilder.fog(keys: keys, index: idx); let dt = Date().timeIntervalSince(t0)
        print("archive cells \(arch.stats.cells) km² \(fmt(arch.stats.km2, 8)) level \(arch.stats.level); report cells \(rep.totalCells) km² \(fmt(rep.totalM2 / 1e6, 8)) unassigned \(rep.unassignedCells) (\(fmt(rep.unassignedM2 / 1e6, 5)) km²) in \(fmt(dt, 2)) s")
        for c in rep.countries(idx) {
            let r = idx.region(c)!, s = rep.stats[c]!
            print("  \(r.nameHans) \(r.flag): \(fmt(s.km2, 8)) km² level \(s.level) sub \(rep.visitedChildren(of: c, idx).count)/\(rep.childCount(of: c, idx))")
            for k in rep.visitedChildren(of: c, idx).prefix(12) {
                let ks = rep.stats[k]!
                print("     \(idx.region(k)!.nameHans): \(fmt(ks.km2, 5)) km² \(fmt(rep.share(k, in: c), 2))% sub \(rep.visitedChildren(of: k, idx).count)/\(rep.childCount(of: k, idx))")
                for g in rep.visitedChildren(of: k, idx).prefix(6) { print("        \(idx.region(g)!.nameHans): \(fmt(rep.stats[g]!.km2, 5)) km² \(fmt(rep.share(g, in: k), 2))%") }
            }
            let rest = rep.remainder(of: c, idx); if rest > 0 { print("     其余: \(fmt(rest / 1e6, 5)) km²") }
        }
    default: return false
    }
    return true
}

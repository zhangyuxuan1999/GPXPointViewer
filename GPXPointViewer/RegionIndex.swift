//
//  RegionIndex.swift
//  GPXPointViewer
//
//  内置行政区边界索引（Regions.bin，由 Tools/build_regions.py 预处理；格式见 docs/regions-design.md）。
//  三层：0 国家、1 省/州、2 中国地级（直辖市给区）。点 → 地区：1°×1° 格取候选，按射线法（偶奇）判定，
//  坐标全部微度 Int64 整数运算；外接框在载入时由顶点重算（文件里的 f32 只作参考）。只依赖 Foundation（离线探针也能编）。
//

import Foundation

final class RegionIndex: @unchecked Sendable {
    struct Region {
        let id: UInt16
        let level: UInt8            // 0 国 1 省/州 2 市
        let parent: UInt16          // 0xFFFF = 无
        let iso2: String            // 国家才有（A–Z 两位；别的值不出旗）
        let areaKm2: Double
        let minLat: Int32, minLon: Int32, maxLat: Int32, maxLon: Int32   // 微度，由顶点重算
        let ringStart: Int, ringCount: Int
        let nameHans: String, nameEn: String, nameDe: String, nameHant: String
        var hasParent: Bool { parent != 0xFFFF }
        var minLatDeg: Double { Double(minLat) / 1e6 }
        var maxLatDeg: Double { Double(maxLat) / 1e6 }
        var minLonDeg: Double { Double(minLon) / 1e6 }
        var maxLonDeg: Double { Double(maxLon) / 1e6 }
        /// 按界面实际使用的语言取名称；任何一级都不会返回空串
        var localizedName: String {
            func pick(_ a: String, _ b: String, _ c: String) -> String { !a.isEmpty ? a : (!b.isEmpty ? b : (!c.isEmpty ? c : nameHans)) }
            switch RegionIndex.nameLanguage {
            case "zh-Hant": return pick(nameHant, nameHans, nameEn)
            case "de": return pick(nameDe, nameEn, nameHans)
            case "en": return pick(nameEn, nameHans, nameDe)
            default: return pick(nameHans, nameEn, nameHant)
            }
        }
        /// 国旗 emoji（ISO 3166-1 alpha-2 → 区域指示符）；非 A–Z 两位就不出旗，绝不陷入溢出
        var flag: String {
            let u = iso2.uppercased().unicodeScalars
            guard u.count == 2, u.allSatisfy({ (65...90).contains($0.value) }) else { return "" }
            return String(String.UnicodeScalarView(u.compactMap { UnicodeScalar(0x1F1E6 + ($0.value - 65)) }))
        }
    }
    struct Ring {
        let start: Int, count: Int, hole: Bool
        let minLat: Int32, minLon: Int32, maxLat: Int32, maxLon: Int32   // 微度，由顶点重算
    }

    let regions: [Region]
    let rings: [Ring]
    let latMicro: [Int32]
    let lonMicro: [Int32]
    private let cellOffset: [UInt32]       // 360×180 格 → 候选列表偏移/个数（列表按 level 降序：市、省、国）
    private let cellCount: [UInt16]
    private let cellList: [UInt16]
    private let cellMultiCountry: [Bool]   // 该 1° 格的候选分属多个国家（跨国格：子级命中还要国家多边形也包含）
    /// 大环（≥ 2000 顶点）的纬度分带边索引：0.05° 一带，CSR；contains 只扫点所在带的边（近岸水上点不再整环扫描）
    private struct Bands { let minLat: Int32; let count: Int; let offsets: [Int32]; let edges: [Int32] }
    private let ringBands: [Int: Bands]
    private static let bandMicro: Int64 = 50_000
    /// 每个地区的直接下级（按 id 升序）
    let children: [UInt16: [UInt16]]
    let countries: [UInt16]
    var isEmpty: Bool { regions.isEmpty }

    /// 设置页选中的语言（运行中可变；nil = 跟随 app 启动时解析出的界面语言）
    nonisolated(unsafe) static var languageOverride: String?
    /// 名称语言：设置页的选择优先；否则跟 app 实际解析出的界面语言一致（String Catalog 用的那套），没有本地化目录的命令行探针才退回系统首选语言
    static var nameLanguage: String {
        let raw = (languageOverride ?? Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "zh-Hans").lowercased()
        if raw.hasPrefix("zh") {
            if raw.contains("hans") { return "zh-Hans" }
            if raw.contains("hant") || raw.contains("-tw") || raw.contains("-hk") || raw.contains("-mo") { return "zh-Hant" }
            return "zh-Hans"
        }
        if raw.hasPrefix("de") { return "de" }
        if raw.hasPrefix("en") { return "en" }
        return "zh-Hans"
    }

    // MARK: 加载

    /// app 内置数据；环境变量 GPXPV_REGIONS_BIN 可换一份（自测用合成边界）
    static let shared: RegionIndex? = {
        if let p = ProcessInfo.processInfo.environment["GPXPV_REGIONS_BIN"], let idx = load(url: URL(fileURLWithPath: p)) { return idx }
        guard let url = Bundle.main.url(forResource: "Regions", withExtension: "bin") else { return nil }
        return load(url: url)
    }()
    /// 有可用的边界数据（占位文件 = 没有）
    static var hasData: Bool { shared?.isEmpty == false }

    static func load(url: URL) -> RegionIndex? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= 24 else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> RegionIndex? in
            let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var o = 0
            func u8() -> UInt8 { let v = p[o]; o += 1; return v }
            func u16() -> UInt16 { let v = UInt16(p[o]) | UInt16(p[o + 1]) << 8; o += 2; return v }
            func u32() -> UInt32 { var v: UInt32 = 0; for k in 0..<4 { v |= UInt32(p[o + k]) << (8 * k) }; o += 4; return v }
            func i32() -> Int32 { Int32(bitPattern: u32()) }
            guard p[0] == 0x52, p[1] == 0x47, p[2] == 0x4E, p[3] == 0x31 else { return nil }   // "RGN1"
            o = 4
            let version = u32(); guard version == 1 else { return nil }
            let nRegions = Int(u32()), nRings = Int(u32()), nVerts = Int(u32()), nCells = Int(u32())
            guard nCells == 360 * 180, nRegions < 0xFFFE,
                  raw.count >= o + nRegions * 49 + nRings * 25 + nVerts * 8 + nCells * 6 + 8 else { return nil }
            struct Rec { var id: UInt16; var level: UInt8; var parent: UInt16; var iso: String; var area: Double; var rs: Int; var rc: Int; var n: [Int] }
            var recs: [Rec] = []; recs.reserveCapacity(nRegions)
            for _ in 0..<nRegions {
                let id = u16(), level = u8(), parent = u16()
                let isoBytes = [p[o], p[o + 1]].filter { $0 > 32 && $0 < 127 }; o += 2
                let iso = String(bytes: isoBytes, encoding: .ascii) ?? ""
                let area = Double(Float(bitPattern: u32()))
                o += 16                                                  // 文件里的 f32 外接框：不用，按顶点重算
                let rs = Int(u32()), rc = Int(u16())
                let n0 = Int(u32()), n1 = Int(u32()), n2 = Int(u32()), n3 = Int(u32())
                recs.append(Rec(id: id, level: level, parent: parent, iso: iso, area: area, rs: rs, rc: rc, n: [n0, n1, n2, n3]))
            }
            struct RawRing { var vs: Int; var vc: Int; var hole: Bool }
            var rawRings: [RawRing] = []; rawRings.reserveCapacity(nRings)
            for _ in 0..<nRings {
                let vs = Int(u32()), vc = Int(u32()), hole = u8() != 0
                o += 16
                rawRings.append(RawRing(vs: vs, vc: vc, hole: hole))
            }
            var la = [Int32](repeating: 0, count: nVerts), lo = [Int32](repeating: 0, count: nVerts)
            for i in 0..<nVerts { la[i] = i32(); lo[i] = i32() }
            var cellOffset = [UInt32](repeating: 0, count: nCells), cellCount = [UInt16](repeating: 0, count: nCells)
            for i in 0..<nCells { cellOffset[i] = u32(); cellCount[i] = u16() }
            let nList = Int(u32())
            guard raw.count >= o + nList * 2 + 4 else { return nil }
            var list = [UInt16](repeating: 0, count: nList)
            for i in 0..<nList { list[i] = u16() }
            let nNames = Int(u32())
            guard raw.count >= o + nNames else { return nil }
            let names = Data(bytes: p + o, count: nNames)
            func name(_ off: Int) -> String {
                guard off < nNames else { return "" }
                var end = off
                while end < nNames, names[end] != 0 { end += 1 }
                return String(data: names[off..<end], encoding: .utf8) ?? ""
            }
            // 校验（索引全部在界内；id == 下标；父级有效）：任何一条不满足就当没有数据，不在之后的查询里崩
            for r in rawRings { guard r.vs >= 0, r.vc >= 0, r.vs + r.vc <= nVerts else { return nil } }
            for (i, r) in recs.enumerated() {
                guard Int(r.id) == i, r.level <= 2, r.rs >= 0, r.rc >= 0, r.rs + r.rc <= nRings,
                      r.parent == 0xFFFF || Int(r.parent) < nRegions else { return nil }
            }
            for i in 0..<nCells { guard Int(cellOffset[i]) + Int(cellCount[i]) <= nList else { return nil } }
            for id in list { guard Int(id) < nRegions else { return nil } }
            // 环与地区外接框：按微度顶点重算（文件里的 f32 四舍五入会向内缩 ≈1 m，让极边上的点被预筛掉）
            var rings: [Ring] = []; rings.reserveCapacity(nRings)
            for r in rawRings {
                var a: Int32 = .max, b: Int32 = .max, c: Int32 = .min, d: Int32 = .min
                for v in r.vs..<(r.vs + r.vc) { a = min(a, la[v]); b = min(b, lo[v]); c = max(c, la[v]); d = max(d, lo[v]) }
                if r.vc == 0 { a = 0; b = 0; c = -1; d = -1 }
                rings.append(Ring(start: r.vs, count: r.vc, hole: r.hole, minLat: a, minLon: b, maxLat: c, maxLon: d))
            }
            var regions: [Region] = []; regions.reserveCapacity(nRegions)
            for r in recs {
                var a: Int32 = .max, b: Int32 = .max, c: Int32 = .min, d: Int32 = .min
                for ri in r.rs..<(r.rs + r.rc) where rings[ri].count > 0 {
                    a = min(a, rings[ri].minLat); b = min(b, rings[ri].minLon); c = max(c, rings[ri].maxLat); d = max(d, rings[ri].maxLon)
                }
                if a > c { a = 0; b = 0; c = -1; d = -1 }
                regions.append(Region(id: r.id, level: r.level, parent: r.parent, iso2: r.iso, areaKm2: r.area,
                                      minLat: a, minLon: b, maxLat: c, maxLon: d, ringStart: r.rs, ringCount: r.rc,
                                      nameHans: name(r.n[0]), nameEn: name(r.n[1]), nameDe: name(r.n[2]), nameHant: name(r.n[3])))
            }
            var children: [UInt16: [UInt16]] = [:]
            for r in regions where r.hasParent { children[r.parent, default: []].append(r.id) }
            // 父链到国家（深度 ≤ 3）
            func countryOf(_ id: UInt16) -> UInt16? {
                var cur = id
                for _ in 0..<4 { let r = regions[Int(cur)]; if r.level == 0 { return cur }; guard r.hasParent else { return nil }; cur = r.parent }
                return nil
            }
            var multi = [Bool](repeating: false, count: nCells)
            for ci in 0..<nCells {
                let off = Int(cellOffset[ci]), n = Int(cellCount[ci])
                guard n > 1 else { continue }
                var first: UInt16? = nil
                for k in off..<(off + n) {
                    let c = countryOf(list[k])
                    if first == nil { first = c } else if c != first { multi[ci] = true; break }
                }
            }
            var bands: [Int: Bands] = [:]
            for (ri, ring) in rings.enumerated() where ring.count >= 2000 {
                let b0 = Int64(ring.minLat).quotientAndRemainder(dividingBy: bandMicro).quotient - (ring.minLat < 0 ? 1 : 0)
                let bandMin = Int32(b0 * bandMicro)
                let nb = Int((Int64(ring.maxLat) - Int64(bandMin)) / bandMicro) + 1
                var counts = [Int32](repeating: 0, count: nb + 1)
                let s = ring.start, n = ring.count
                func bandRange(_ i: Int, _ j: Int) -> (Int, Int) {
                    let lo = Int64(min(la[i], la[j])), hi = Int64(max(la[i], la[j]))
                    return (Int((lo - Int64(bandMin)) / bandMicro), Int((hi - Int64(bandMin)) / bandMicro))
                }
                var j = s + n - 1
                for i in s..<(s + n) { let (a, b) = bandRange(i, j); for k in a...min(b, nb - 1) { counts[k + 1] += 1 }; j = i }
                for k in 0..<nb { counts[k + 1] += counts[k] }
                var fill = counts
                var edges = [Int32](repeating: 0, count: Int(counts[nb]))
                j = s + n - 1
                for i in s..<(s + n) { let (a, b) = bandRange(i, j); for k in a...min(b, nb - 1) { edges[Int(fill[k])] = Int32(i); fill[k] += 1 }; j = i }
                bands[ri] = Bands(minLat: bandMin, count: nb, offsets: counts, edges: edges)
            }
            return RegionIndex(regions: regions, rings: rings, lat: la, lon: lo, cellOffset: cellOffset, cellCount: cellCount,
                               cellList: list, cellMultiCountry: multi, children: children, ringBands: bands)
        }
    }

    private init(regions: [Region], rings: [Ring], lat: [Int32], lon: [Int32], cellOffset: [UInt32], cellCount: [UInt16],
                 cellList: [UInt16], cellMultiCountry: [Bool], children: [UInt16: [UInt16]], ringBands: [Int: Bands]) {
        self.regions = regions; self.rings = rings; self.latMicro = lat; self.lonMicro = lon
        self.cellOffset = cellOffset; self.cellCount = cellCount; self.cellList = cellList
        self.cellMultiCountry = cellMultiCountry; self.children = children; self.ringBands = ringBands
        self.countries = regions.filter { $0.level == 0 }.map(\.id)
    }

    /// 经度归一到 [-180, 180)（裁剪后的飞行范围可能越过 180）
    static func normalizeLon(_ lon: Double) -> Double {
        var w = lon.truncatingRemainder(dividingBy: 360)
        if w >= 180 { w -= 360 } else if w < -180 { w += 360 }
        return w
    }

    // MARK: 查询

    func region(_ id: UInt16) -> Region? { Int(id) < regions.count ? regions[Int(id)] : nil }
    func parent(of id: UInt16) -> UInt16? { guard let r = region(id), r.hasParent else { return nil }; return r.parent }
    func country(of id: UInt16) -> UInt16? {
        var cur = id
        for _ in 0..<4 { guard let r = region(cur) else { return nil }; if r.level == 0 { return cur }; guard r.hasParent else { return nil }; cur = r.parent }
        return nil
    }
    /// 地区的多边形（外环 + 其内环）。环的顺序由写入端保证：每个外环后面紧跟它自己的洞
    func polygons(of id: UInt16) -> [(outer: [(lat: Double, lon: Double)], holes: [[(lat: Double, lon: Double)]])] {
        guard let r = region(id) else { return [] }
        var out: [(outer: [(lat: Double, lon: Double)], holes: [[(lat: Double, lon: Double)]])] = []
        for ri in r.ringStart..<(r.ringStart + r.ringCount) {
            let ring = rings[ri]
            let coords = (ring.start..<(ring.start + ring.count)).map { (Double(latMicro[$0]) / 1e6, Double(lonMicro[$0]) / 1e6) }
            if ring.hole { if !out.isEmpty { out[out.count - 1].holes.append(coords) } }
            else { out.append((outer: coords, holes: [])) }
        }
        return out
    }
    /// 兼容旧调用：所有环（不分洞）
    func outlines(of id: UInt16) -> [[(lat: Double, lon: Double)]] {
        polygons(of: id).flatMap { [$0.outer] + $0.holes }
    }
    /// 经度范围（环绕日界线也对）：按外环的经度区间求圆上最大空隙，取其补集。返回西边界与跨度（度）
    func lonExtent(of id: UInt16) -> (west: Double, span: Double)? {
        guard let r = region(id) else { return nil }
        var ivs: [(Double, Double)] = []
        for ri in r.ringStart..<(r.ringStart + r.ringCount) where !rings[ri].hole && rings[ri].count > 0 {
            ivs.append((Double(rings[ri].minLon) / 1e6, Double(rings[ri].maxLon) / 1e6))
        }
        guard !ivs.isEmpty else { return nil }
        ivs.sort { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for iv in ivs {
            if let last = merged.last, iv.0 <= last.1 { merged[merged.count - 1].1 = max(last.1, iv.1) } else { merged.append(iv) }
        }
        // 最大空隙：相邻区间之间，以及尾→头（跨 180°）
        var bestGap = merged[0].0 + 360 - merged[merged.count - 1].1, west = merged[0].0
        for i in 0..<(merged.count - 1) {
            let g = merged[i + 1].0 - merged[i].1
            if g > bestGap { bestGap = g; west = merged[i + 1].0 }
        }
        return (west, max(0.0001, 360 - bestGap))
    }

    /// 点是否在地区内（偶奇规则，含洞；微度整数运算）
    func contains(_ id: UInt16, latMicro y: Int64, lonMicro x: Int64) -> Bool {
        guard let r = region(id) else { return false }
        guard y >= Int64(r.minLat), y <= Int64(r.maxLat), x >= Int64(r.minLon), x <= Int64(r.maxLon) else { return false }
        var inside = false
        for ri in r.ringStart..<(r.ringStart + r.ringCount) {
            let ring = rings[ri]
            guard y >= Int64(ring.minLat), y <= Int64(ring.maxLat), x >= Int64(ring.minLon), x <= Int64(ring.maxLon) else { continue }
            let s = ring.start, n = ring.count
            guard n >= 3 else { continue }
            @inline(__always) func edge(_ i: Int, _ j: Int) {
                let yi = Int64(latMicro[i]), yj = Int64(latMicro[j])
                if (yi > y) != (yj > y) {
                    let xi = Int64(lonMicro[i]), xj = Int64(lonMicro[j])
                    // 交点在点右侧：x < xi + (y-yi)*(xj-xi)/(yj-yi)，整数化避免除法
                    let side = (xj - xi) * (y - yi) - (x - xi) * (yj - yi)
                    if (yj > yi) ? (side > 0) : (side < 0) { inside.toggle() }
                }
            }
            if let b = ringBands[ri] {
                let k = Int((y - Int64(b.minLat)) / Self.bandMicro)
                guard k >= 0, k < b.count else { continue }
                for e in Int(b.offsets[k])..<Int(b.offsets[k + 1]) {
                    let i = Int(b.edges[e]); edge(i, i == s ? s + n - 1 : i - 1)
                }
            } else {
                var j = s + n - 1
                for i in s..<(s + n) { edge(i, j); j = i }
            }
        }
        return inside
    }

    /// 经纬度 → 微度（180° 并到 −180°：同一条经线，多边形都在 −180 这一侧）
    static func micro(lat: Double, lon: Double) -> (y: Int64, x: Int64)? {
        guard lat.isFinite, lon.isFinite, lat >= -90, lat <= 90, lon >= -180, lon <= 180 else { return nil }
        var x = Int64((lon * 1e6).rounded())
        if x >= 180_000_000 { x = -180_000_000 }
        return (Int64((lat * 1e6).rounded()), x)
    }

    /// 最细一级的地区 id（市 > 省/州 > 国），都不在 → nil
    func lookup(lat: Double, lon: Double) -> UInt16? {
        guard let m = Self.micro(lat: lat, lon: lon) else { return nil }
        return lookupMicro(y: m.y, x: m.x)
    }

    func lookupMicro(y: Int64, x: Int64) -> UInt16? {
        let cy = min(179, max(0, Int((y + 90_000_000) / 1_000_000))), cx = min(359, max(0, Int((x + 180_000_000) / 1_000_000)))
        let ci = cy * 360 + cx
        let off = Int(cellOffset[ci]), n = Int(cellCount[ci])
        guard n > 0 else { return nil }
        let multi = cellMultiCountry[ci]
        var fallback: UInt16? = nil
        for k in off..<(off + n) {                 // 列表已按 level 降序：先市再省再国；同级小的在前
            let id = cellList[k]
            guard contains(id, latMicro: y, lonMicro: x) else { continue }
            if multi, let r = region(id), r.level > 0, let c = country(of: id), !contains(c, latMicro: y, lonMicro: x) {
                // 跨国格：子级（可能来自另一套数据）伸到了国境外 → 先不算它，继续找别国；
                // 谁也不包含这个点（海岸带 / 填海 / 小岛只被子级包含）时才退回最细的那个命中
                if fallback == nil { fallback = id }
                continue
            }
            if let r = region(id), r.level == 0 {
                var best = id
                if multi {                         // 几个国家多边形都包含这点（飞地没挖洞、属地叠加）：取包含该点的最小外环所属的国家
                    var bestArea = containingRingBBoxArea(id, latMicro: y, lonMicro: x) ?? .infinity
                    for k2 in (k + 1)..<(off + n) {
                        let id2 = cellList[k2]
                        guard let r2 = region(id2), r2.level == 0, contains(id2, latMicro: y, lonMicro: x) else { continue }
                        if let a2 = containingRingBBoxArea(id2, latMicro: y, lonMicro: x), a2 < bestArea { bestArea = a2; best = id2 }
                    }
                }
                if let near = nearestChild(of: best, latMicro: y, lonMicro: x, maxMeters: 6000) {
                    // 国界与州界两套数据之间的缝（1–2 km；比利时在荷兰境内的飞地离本省 ~5 km）：吸到本国最近的一级行政区；该级还有下级（法/意大区的省）就再吸一层
                    return nearestChild(of: near, latMicro: y, lonMicro: x, maxMeters: 3000) ?? near
                }
                return best
            }
            return id
        }
        return fallback
    }

    /// 包含该点的最小外环的外接框面积（微度²）；没有外环包含 → nil
    private func containingRingBBoxArea(_ id: UInt16, latMicro y: Int64, lonMicro x: Int64) -> Double? {
        guard let r = region(id) else { return nil }
        var best: Double? = nil
        for ri in r.ringStart..<(r.ringStart + r.ringCount) {
            let ring = rings[ri]
            guard !ring.hole, ring.count >= 3, y >= Int64(ring.minLat), y <= Int64(ring.maxLat), x >= Int64(ring.minLon), x <= Int64(ring.maxLon) else { continue }
            var inside = false
            let s = ring.start, n = ring.count
            var j = s + n - 1
            for i in s..<(s + n) {
                let yi = Int64(latMicro[i]), yj = Int64(latMicro[j])
                if (yi > y) != (yj > y) {
                    let xi = Int64(lonMicro[i]), xj = Int64(lonMicro[j])
                    let side = (xj - xi) * (y - yi) - (x - xi) * (yj - yi)
                    if (yj > yi) ? (side > 0) : (side < 0) { inside.toggle() }
                }
                j = i
            }
            if inside {
                let a = Double(Int64(ring.maxLat) - Int64(ring.minLat)) * Double(Int64(ring.maxLon) - Int64(ring.minLon))
                if best == nil || a < best! { best = a }
            }
        }
        return best
    }

    /// 点到某地区边界的最近距离（米，近似：微度按纬度余弦换算），只看外接框 3 km 内的环
    private func distance(to id: UInt16, latMicro y: Int64, lonMicro x: Int64, within maxMeters: Double) -> Double? {
        guard let r = region(id) else { return nil }
        let cosLat = max(0.05, cos(Double(y) / 1e6 * .pi / 180))
        let padLat = Int64(maxMeters / 111_320 * 1e6), padLon = Int64(maxMeters / (111_320 * cosLat) * 1e6)
        guard y >= Int64(r.minLat) - padLat, y <= Int64(r.maxLat) + padLat, x >= Int64(r.minLon) - padLon, x <= Int64(r.maxLon) + padLon else { return nil }
        let mLat = 111_320.0 / 1e6, mLon = 111_320.0 * cosLat / 1e6
        var best = Double.infinity
        for ri in r.ringStart..<(r.ringStart + r.ringCount) {
            let ring = rings[ri]
            guard ring.count >= 2, y >= Int64(ring.minLat) - padLat, y <= Int64(ring.maxLat) + padLat,
                  x >= Int64(ring.minLon) - padLon, x <= Int64(ring.maxLon) + padLon else { continue }
            let s = ring.start, n = ring.count
            var j = s + n - 1
            for i in s..<(s + n) {
                let ax = Double(Int64(lonMicro[j]) - x) * mLon, ay = Double(Int64(latMicro[j]) - y) * mLat
                let bx = Double(Int64(lonMicro[i]) - x) * mLon, by = Double(Int64(latMicro[i]) - y) * mLat
                let dx = bx - ax, dy = by - ay
                let len2 = dx * dx + dy * dy
                let t = len2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len2)) : 0
                let px = ax + dx * t, py = ay + dy * t
                best = min(best, (px * px + py * py).squareRoot())
                j = i
            }
        }
        return best <= maxMeters ? best : nil
    }

    /// 本国范围内离点最近的一级行政区（≤ maxMeters），没有下级或都太远 → nil
    private func nearestChild(of country: UInt16, latMicro y: Int64, lonMicro x: Int64, maxMeters: Double) -> UInt16? {
        guard let kids = children[country], !kids.isEmpty else { return nil }
        var best: (UInt16, Double)? = nil
        for k in kids {
            if let d = distance(to: k, latMicro: y, lonMicro: x, within: maxMeters), best == nil || d < best!.1 { best = (k, d) }
        }
        return best?.0
    }

    /// 0.01° 单元 (cy, cx) 内是否有候选环的边经过（保守：栅格化带 1 单元余量）。1° 格的位图第一次用到时生成并缓存在调用方
    func boundaryCrosses(cy: Int, cx: Int, bitmaps: inout [Int: [UInt64]]) -> Bool {
        let gy = min(179, cy / 100), gx = min(359, cx / 100)
        let ci = gy * 360 + gx
        let bm: [UInt64]
        if let b = bitmaps[ci] { bm = b } else { bm = buildBoundaryBitmap(gy: gy, gx: gx); bitmaps[ci] = bm }
        let ly = min(99, cy - gy * 100), lx = min(99, cx - gx * 100)
        let bit = ly * 100 + lx
        return bm[bit >> 6] & (1 << UInt64(bit & 63)) != 0
    }

    private func buildBoundaryBitmap(gy: Int, gx: Int) -> [UInt64] {
        var bm = [UInt64](repeating: 0, count: 157)        // 100×100 位
        let ci = gy * 360 + gx
        let off = Int(cellOffset[ci]), n = Int(cellCount[ci])
        guard n > 0 else { return bm }
        let y0 = Int64(gy) * 1_000_000 - 90_000_000, x0 = Int64(gx) * 1_000_000 - 180_000_000
        let y1 = y0 + 1_000_000, x1 = x0 + 1_000_000
        @inline(__always) func mark(_ v: Int, _ u: Int) {
            guard v >= 0, v < 100, u >= 0, u < 100 else { return }
            let b = v * 100 + u; bm[b >> 6] |= 1 << UInt64(b & 63)
        }
        /// 线段 (ay,ax)→(by,bx)（微度）在单元坐标系里采样，每个采样点标 3×3（步长 ≤ 0.5 单元，所以经过的单元一个不漏）
        func rasterize(_ ay: Int64, _ ax: Int64, _ by: Int64, _ bx: Int64) {
            let av = Double(ay - y0) / 10_000, au = Double(ax - x0) / 10_000
            let bv = Double(by - y0) / 10_000, bu = Double(bx - x0) / 10_000
            // 参数区间裁到 [-1, 101]² 内（Liang–Barsky），长边只走格内那一段
            var t0 = 0.0, t1 = 1.0
            let dv = bv - av, du = bu - au
            for (p, q) in [(-dv, av + 1), (dv, 101 - av), (-du, au + 1), (du, 101 - au)] {
                if p == 0 { if q < 0 { return } ; continue }
                let t = q / p
                if p < 0 { if t > t1 { return }; if t > t0 { t0 = t } } else { if t < t0 { return }; if t < t1 { t1 = t } }
            }
            let sv = av + dv * t0, su = au + du * t0, ev = av + dv * t1, eu = au + du * t1
            let len = max(abs(ev - sv), abs(eu - su))
            let steps = max(1, Int((len / 0.5).rounded(.up)))
            for s in 0...steps {
                let f = Double(s) / Double(steps)
                let v = Int((sv + (ev - sv) * f).rounded(.down)), u = Int((su + (eu - su) * f).rounded(.down))
                for dy in -1...1 { for dx in -1...1 { mark(v + dy, u + dx) } }
            }
        }
        for k in off..<(off + n) {
            guard let r = region(cellList[k]) else { continue }
            for ri in r.ringStart..<(r.ringStart + r.ringCount) {
                let ring = rings[ri]
                guard ring.count >= 2, Int64(ring.maxLat) >= y0 - 20_000, Int64(ring.minLat) <= y1 + 20_000,
                      Int64(ring.maxLon) >= x0 - 20_000, Int64(ring.minLon) <= x1 + 20_000 else { continue }
                let s = ring.start, cnt = ring.count
                var j = s + cnt - 1
                for i in s..<(s + cnt) {
                    let ay = Int64(latMicro[j]), ax = Int64(lonMicro[j]), by = Int64(latMicro[i]), bx = Int64(lonMicro[i])
                    j = i
                    if max(ay, by) < y0 - 20_000 || min(ay, by) > y1 + 20_000 || max(ax, bx) < x0 - 20_000 || min(ax, bx) > x1 + 20_000 { continue }
                    rasterize(ay, ax, by, bx)
                }
            }
        }
        return bm
    }

    /// 批量归属：按 0.01°（≈1 km）单元缓存。单元内没有任何边界经过 → 整单元同属（中心判一次）；有边界经过 → 逐点判
    final class Assigner {
        private let index: RegionIndex
        private var cache: [Int64: UInt16] = [:]      // 0xFFFF = 不在任何地区；0xFFFE = 有边界的单元（逐点）
        private var bitmaps: [Int: [UInt64]] = [:]
        init(_ index: RegionIndex) { self.index = index }
        func assign(lat: Double, lon: Double) -> UInt16? {
            guard let m = RegionIndex.micro(lat: lat, lon: lon) else { return nil }
            return assignMicro(y: m.y, x: m.x)
        }
        func assignMicro(y: Int64, x: Int64) -> UInt16? {
            let cy = min(17_999, Int((y + 90_000_000) / 10_000)), cx = min(35_999, Int((x + 180_000_000) / 10_000))
            let key = Int64(cy) << 32 | Int64(cx)
            if let v = cache[key] {
                if v == 0xFFFE { return index.lookupMicro(y: y, x: x) }
                return v == 0xFFFF ? nil : v
            }
            if index.boundaryCrosses(cy: cy, cx: cx, bitmaps: &bitmaps) {
                cache[key] = 0xFFFE
                return index.lookupMicro(y: y, x: x)
            }
            let r = index.lookupMicro(y: Int64(cy) * 10_000 - 90_000_000 + 5_000, x: Int64(cx) * 10_000 - 180_000_000 + 5_000)
            cache[key] = r ?? 0xFFFF
            return r
        }
    }
}

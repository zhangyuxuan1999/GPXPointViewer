// 地区索引 / 统计的离线探针（swiftc 直接编 RegionIndex.swift + RegionStats.swift）。用法：regions_probe <synthetic.bin> <synthetic2.bin>
// 检查：lookup 与浮点参考射线法逐点一致；Assigner 与 lookup 逐点一致（边界位图必须保守）；刁钻几何的期望归属；
//       跨日界线经度范围；迷雾统计总量守恒；夏令时按点当时偏移算天数。
import Foundation

var fails = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  — " + detail)); if !ok { fails += 1 }
}
if runRealData(CommandLine.arguments) { exit(0) }
guard CommandLine.arguments.count > 2, let idx = RegionIndex.load(url: URL(fileURLWithPath: CommandLine.arguments[1])),
      let idx2 = RegionIndex.load(url: URL(fileURLWithPath: CommandLine.arguments[2])) else { print("usage / load failed"); exit(2) }
func byName(_ i: RegionIndex, _ n: String) -> UInt16 { i.regions.first { $0.nameHans == n }!.id }

/// 点到某地区任一边的最近距离（度，平面近似）；随机扫描里离边 < 2 µ° 的点整数/浮点两种判法可能不同，不计入不一致
func nearEdge(_ i: RegionIndex, _ ids: [UInt16?], lat: Double, lon: Double, eps: Double = 2e-6) -> Bool {
    for case let id? in ids {
        guard let r = i.region(id) else { continue }
        for ri in r.ringStart..<(r.ringStart + r.ringCount) {
            let ring = i.rings[ri]; let s = ring.start, n = ring.count
            guard n >= 2 else { continue }
            var j = s + n - 1
            for k in s..<(s + n) {
                let ax = Double(i.lonMicro[j]) / 1e6 - lon, ay = Double(i.latMicro[j]) / 1e6 - lat
                let bx = Double(i.lonMicro[k]) / 1e6 - lon, by = Double(i.latMicro[k]) / 1e6 - lat
                let dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy
                let t = len2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len2)) : 0
                let px = ax + dx * t, py = ay + dy * t
                if (px * px + py * py).squareRoot() < eps { return true }
                j = k
            }
        }
    }
    return false
}

/// 浮点参考：偶奇射线法，直接用顶点度数
func refLookup(_ i: RegionIndex, lat: Double, lon: Double) -> UInt16? {
    var best: (UInt8, UInt16)? = nil
    for r in i.regions {
        var inside = false
        for ri in r.ringStart..<(r.ringStart + r.ringCount) {
            let ring = i.rings[ri]; let s = ring.start, n = ring.count
            guard n >= 3 else { continue }
            var j = s + n - 1
            for k in s..<(s + n) {
                let yi = Double(i.latMicro[k]) / 1e6, yj = Double(i.latMicro[j]) / 1e6
                let xi = Double(i.lonMicro[k]) / 1e6, xj = Double(i.lonMicro[j]) / 1e6
                if (yi > lat) != (yj > lat) {
                    let xint = xi + (lat - yi) * (xj - xi) / (yj - yi)
                    if lon < xint { inside.toggle() }
                }
                j = k
            }
        }
        if inside, best == nil || r.level > best!.0 { best = (r.level, r.id) }
    }
    return best?.1
}

// 1) 基础合成：扫描 0–4° × 0–2°（避开整数边界的偏移网格）
var mism = 0, amism = 0, n = 0
let asg = RegionIndex.Assigner(idx)
for a in 0..<400 { for b in 0..<200 {
    let lat = Double(b) * 0.01 + 0.0037, lon = Double(a) * 0.01 + 0.0041
    let l = idx.lookup(lat: lat, lon: lon); n += 1
    let ref = refLookup(idx, lat: lat, lon: lon)
    // 参考法只看“包含”；lookup 还会把国家直属（洞/缝里）的点吸到本国 ≤3 km 内最近的一级行政区，这种差异是设计内的
    let snapped = (l != ref) && ref != nil && idx.region(ref!)?.level == 0 && l != nil && idx.parent(of: l!) == ref
    if l != ref && !snapped && !nearEdge(idx, [l, ref], lat: lat, lon: lon) { mism += 1 }
    // 吸附带（国家直属区域里离州 ≤6 km）按 0.01° 单元统一归属，单元中心与点的吸附判定可能不同：这是设计内的粒度，不算不一致
    let snapZone = ref != nil && idx.region(ref!)?.level == 0 && !(idx.children[ref!] ?? []).isEmpty
    if asg.assign(lat: lat, lon: lon) != l && !snapZone { amism += 1 }
}}
check("synthetic: lookup == 浮点参考（\(n) 点，吸附差异除外）", mism == 0, "mismatch \(mism)")
check("synthetic: Assigner == lookup", amism == 0, "mismatch \(amism)")
// 边界上的点：相邻区分配一致、不丢
check("synthetic: 边界 lat=1.0 落在上方的甲二市", idx.lookup(lat: 1.0, lon: 0.5) == byName(idx, "甲二市"))
check("synthetic: 边界 lon=1.0 落在右侧的乙州", idx.lookup(lat: 0.5, lon: 1.0) == byName(idx, "乙州"))
check("synthetic: 极边 1.999999 仍在乙州（外接框按顶点重算，1 µ° 精度）", idx.lookup(lat: 0.5, lon: 1.999999) == byName(idx, "乙州"))
check("synthetic: 2.0 整线归右侧的丙州（半开区间）", idx.lookup(lat: 0.5, lon: 1.9999997) == byName(idx, "丙州"))
check("synthetic: 洞里归国家", idx.lookup(lat: 1.0, lon: 3.0) == byName(idx, "贝塔国"))

// 2) 刁钻几何
let west = byName(idx2, "西州"), east = byName(idx2, "东州"), enclave = byName(idx2, "飞地"), strip = byName(idx2, "窄条州")
let dd = byName(idx2, "丁国"), ee = byName(idx2, "戊国"), vv = byName(idx2, "梵国"), lazio = byName(idx2, "拉州"), ff = byName(idx2, "己国"), fstate = byName(idx2, "己州"), over = byName(idx2, "越界州")
let asg2 = RegionIndex.Assigner(idx2)
var rng = SystemRandomNumberGenerator()
func both(_ lat: Double, _ lon: Double) -> (UInt16?, UInt16?) { (idx2.lookup(lat: lat, lon: lon), asg2.assign(lat: lat, lon: lon)) }
// 先用一个远离舌头的点把单元缓存起来，再查舌头里的点（这正是 5 探针捷径会错的顺序）
_ = asg2.assign(lat: 11.0085, lon: 11.9985)
var r = both(11.002, 11.998); check("synthetic2: 东州舌头（凸进西州单元）", r.0 == east && r.1 == east, "\(String(describing: r))")
r = both(11.008, 11.998); check("synthetic2: 舌头旁边仍是西州", r.0 == west && r.1 == west, "\(String(describing: r))")
_ = asg2.assign(lat: 10.509, lon: 10.509)
r = both(10.5015, 10.5015); check("synthetic2: 0.003° 飞地", r.0 == enclave && r.1 == enclave, "\(String(describing: r))")
_ = asg2.assign(lat: 10.5, lon: 13.009)
r = both(10.5, 13.001); check("synthetic2: 200 m 窄条", r.0 == strip && r.1 == strip, "\(String(describing: r))")
r = both(10.5, 13.0015); check("synthetic2: 窄条内第二点", r.0 == strip && r.1 == strip, "\(String(describing: r))")
r = both(10.5, 13.005); check("synthetic2: 窄条右侧东州", r.0 == east && r.1 == east, "\(String(describing: r))")
_ = asg2.assign(lat: 10.0001, lon: 15.0001)
r = both(10.005, 15.005); check("synthetic2: 避开探针的小岛", r.0 == dd && r.1 == dd, "\(String(describing: r))")
r = both(10.001, 15.001); check("synthetic2: 小岛旁海面无归属", r.0 == nil && r.1 == nil, "\(String(describing: r))")
_ = asg2.assign(lat: 41.909, lon: 12.459)
r = both(41.903, 12.453); check("synthetic2: 梵蒂冈式微型国（州与国家都挖了洞）", r.0 == vv && r.1 == vv, "\(String(describing: r))")
r = both(41.95, 12.5); check("synthetic2: 意国境内归拉州", r.0 == lazio && r.1 == lazio, "\(String(describing: r))")
r = both(30.5, 21.45); check("synthetic2: 跨国格：越界州伸进己国 → 己州", r.0 == fstate && r.1 == fstate, "\(String(describing: r))")
r = both(30.5, 21.6); check("synthetic2: 庚国境内归越界州", r.0 == over && r.1 == over, "\(String(describing: r))")
let coast = byName(idx2, "海岸州")
r = both(30.5, 19.95); check("synthetic2: 跨国格里只被州包含的填海带 → 退回该州", r.0 == coast && r.1 == coast, "\(String(describing: r))")
check("normalizeLon: 197.7 → −162.3；−190 → 170", abs(RegionIndex.normalizeLon(197.7) + 162.3) < 1e-9 && abs(RegionIndex.normalizeLon(-190) - 170) < 1e-9)
r = both(51, 179); check("synthetic2: 日界线东侧", r.0 == ee && r.1 == ee, "\(String(describing: r))")
r = both(51, -179); check("synthetic2: 日界线西侧", r.0 == ee && r.1 == ee, "\(String(describing: r))")
r = both(51, 180); check("synthetic2: lon=180 并到 −180", r.0 == ee && r.1 == ee, "\(String(describing: r))")
if let ext = idx2.lonExtent(of: ee) { check("synthetic2: 戊国经度范围 west=178 span=4", abs(ext.west - 178) < 1e-6 && abs(ext.span - 4) < 1e-6, "\(ext)") } else { check("synthetic2: lonExtent", false) }
if let ext = idx2.lonExtent(of: byName(idx2, "丙国")) { check("synthetic2: 丙国经度范围 west=10 span=4", abs(ext.west - 10) < 1e-6 && abs(ext.span - 4) < 1e-6, "\(ext)") }
check("synthetic2: 旗帜 CC → 🇨🇨", idx2.region(byName(idx2, "丙国"))?.flag == "🇨🇨")
let polys = idx2.polygons(of: byName(idx2, "意国")); check("synthetic2: 意国 1 外环 + 1 洞按顺序分组", polys.count == 1 && polys[0].holes.count == 1, "\(polys.map { ($0.outer.count, $0.holes.count) })")
// 大环（纬度分带边索引）：圆内/圆外/洞里 与浮点参考一致，含随机扫描
let hh = byName(idx2, "辛国")
check("synthetic2: 大环圆心命中", idx2.lookup(lat: 35, lon: 25) == hh)
check("synthetic2: 大环的洞", idx2.lookup(lat: 35.25, lon: 25.25) == nil)
check("synthetic2: 大环外", idx2.lookup(lat: 36.5, lon: 25) == nil && idx2.lookup(lat: 35, lon: 26.5) == nil)
var bm = 0
for _ in 0..<40_000 {
    let lat = Double.random(in: 33.9...36.1, using: &rng), lon = Double.random(in: 23.9...26.1, using: &rng)
    let lh = idx2.lookup(lat: lat, lon: lon), rh = refLookup(idx2, lat: lat, lon: lon)
    if lh != rh && !nearEdge(idx2, [lh, rh], lat: lat, lon: lon) { bm += 1 }
}
check("synthetic2: 大环随机 4 万点 lookup == 浮点参考（分带索引）", bm == 0, "mismatch \(bm)")
// 缝吸附 + 属地叠加
let jstate = byName(idx2, "壬州"), jj = byName(idx2, "壬国"), ll = byName(idx2, "属地"), kk = byName(idx2, "癸国")
r = both(11.0, 41.99); check("synthetic2: 国界与州界之间的缝 → 吸到最近的州", r.0 == jstate && r.1 == jstate, "\(String(describing: r))")
r = both(11.0, 41.9); check("synthetic2: 州内正常", r.0 == jstate && r.1 == jstate, "\(String(describing: r))")
check("synthetic2: 离州 >6 km 的点不在国内 → none；缝里的点吸到州", idx2.lookup(lat: 13.5, lon: 41.99) == nil && idx2.lookup(lat: 11, lon: 41.995) == jstate)
r = both(10.55, 44.55); check("synthetic2: 套在大国里的属地（无洞）→ 面积小的先命中", r.0 == ll && r.1 == ll, "\(String(describing: r))")
r = both(11.5, 45.5); check("synthetic2: 属地之外归大国", r.0 == kk && r.1 == kk, "\(String(describing: r))")
let mm = byName(idx2, "飞地国"), nn = byName(idx2, "邻国")
r = both(10.305, 50.305); check("synthetic2: 邻国没挖洞的飞地 → 最小外环所属的国家", r.0 == mm && r.1 == mm, "\(String(describing: r))")
r = both(11.0, 51.0); check("synthetic2: 飞地之外是邻国", r.0 == nn && r.1 == nn, "\(String(describing: r))")
// 随机扫描：Assigner 与 lookup 逐点一致（含舌头/飞地/窄条/小岛区域）
var am2 = 0, lm2 = 0
for _ in 0..<60_000 {
    let lat = Double.random(in: 9.99...12.01, using: &rng), lon = Double.random(in: 9.99...15.01, using: &rng)
    let l = idx2.lookup(lat: lat, lon: lon)
    let ref2z = refLookup(idx2, lat: lat, lon: lon)
    let snapZone2 = ref2z != nil && idx2.region(ref2z!)?.level == 0 && !(idx2.children[ref2z!] ?? []).isEmpty
    if asg2.assign(lat: lat, lon: lon) != l && !snapZone2 { am2 += 1 }
    let ref2 = refLookup(idx2, lat: lat, lon: lon)
    let snapped2 = (l != ref2) && ref2 != nil && idx2.region(ref2!)?.level == 0 && l != nil && idx2.parent(of: l!) == ref2
    if l != ref2 && !snapped2 && !nearEdge(idx2, [l, ref2], lat: lat, lon: lon) { lm2 += 1 }
}
check("synthetic2: 随机 6 万点 Assigner == lookup", am2 == 0, "mismatch \(am2)")
check("synthetic2: 随机 6 万点 lookup == 浮点参考", lm2 == 0, "mismatch \(lm2)")

// 3) 迷雾统计守恒：甲一市内外各若干格，带重复键
func key(lat: Double, lon: Double) -> UInt64 {
    let grid = Double(1 << 22)
    let x = UInt64(min(grid - 1, max(0, (lon + 180) / 360 * grid)))
    let yM = (1 - log(tan(lat * .pi / 180) + 1 / cos(lat * .pi / 180)) / .pi) / 2
    let y = UInt64(min(grid - 1, max(0, yM * grid)))
    return x << 22 | y
}
var keys: [UInt64] = []
for i in 0..<500 { keys.append(key(lat: 0.5 + Double(i) * 1e-4, lon: 0.5)) }        // 甲一市
for i in 0..<300 { keys.append(key(lat: 1.0 + Double(i) * 1e-4, lon: 3.0)) }        // 丙州的洞 → 贝塔国直属
for i in 0..<100 { keys.append(key(lat: 5.0 + Double(i) * 1e-4, lon: 5.0)) }        // 海上
keys.sort(); let uniq = Set(keys).count
let dup = (keys + keys).sorted()
let rep = RegionStatsBuilder.fog(keys: dup, index: idx)
check("fog: totalCells = 去重格数（输入有重复）", rep.totalCells == uniq, "\(rep.totalCells) vs \(uniq)")
let sumC = idx.countries.reduce(0.0) { $0 + rep.metric($1) }
check("fog: Σ国家 + 未归属 = 全部面积", abs(sumC + rep.unassignedM2 - rep.totalM2) < 1e-6, "\(sumC) + \(rep.unassignedM2) vs \(rep.totalM2)")
check("fog: 贝塔国直属格（洞）计入国家、不计入丙州", rep.stats[byName(idx, "贝塔国")]!.cells > 0 && rep.stats[byName(idx, "丙州")] == nil)
check("fog: 阿尔法国 = 甲州 = 甲一市", rep.stats[byName(idx, "阿尔法国")]!.cells == rep.stats[byName(idx, "甲一市")]!.cells)
check("fog: 剩余 = 国家 − 下级", abs(rep.remainder(of: byName(idx, "贝塔国"), idx) - rep.metric(byName(idx, "贝塔国"))) < 1e-9)

// 4) 点口径 + 夏令时：本机时区取 TZ 环境变量（默认 Europe/Berlin），期望值用 Calendar 独立算
let tzName = ProcessInfo.processInfo.environment["TZ"] ?? "Europe/Berlin"
if let tz = TimeZone(identifier: tzName) {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
    let f = ISO8601DateFormatter(); f.timeZone = tz; f.formatOptions = [.withInternetDateTime]
    let stamps = ["2026-01-10T23:30:00+01:00", "2026-01-11T08:00:00+01:00", "2026-07-10T23:30:00+02:00", "2026-07-11T00:10:00+02:00", "2026-03-29T01:30:00+01:00", "2026-03-29T03:30:00+02:00"]
    let ts = stamps.map { f.date(from: $0)!.timeIntervalSince1970 }.sorted()
    let track = TrackData(lat: ts.map { _ in 0.5 }, lon: ts.map { _ in 0.5 }, time: ts, timedCount: ts.count)
    let expectDays = Set(ts.map { t -> String in
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: t)); return "\(c.year!)-\(c.month!)-\(c.day!)" }).count
    let pr = RegionStatsBuilder.points(track: track, index: idx)
    let got = pr.stats[byName(idx, "甲一市")]?.days ?? -1
    check("points: 到访天数按各点当时的时区偏移（\(tzName)）", got == expectDays, "got \(got) expected \(expectDays)")
    check("points: hasTime / 点数 / 首次最近", pr.hasTime && pr.stats[byName(idx, "阿尔法国")]?.points == ts.count && pr.stats[byName(idx, "甲州")]?.firstTime == ts.first)
}
let mixed = TrackData(lat: [0.5, 1.5], lon: [0.5, 0.5], time: [1_700_000_000, .nan], timedCount: 1)
let pm = RegionStatsBuilder.points(track: mixed, index: idx)
check("points: 混合轨迹里只被无时间尾部覆盖的地区 firstTime 非有限（界面显示 —）", pm.hasTime && pm.stats[byName(idx, "甲二市")]?.firstTime.isFinite == false && pm.stats[byName(idx, "甲一市")]?.days == 1)
let untimed = TrackData(lat: [0.5, 1.5], lon: [0.5, 0.5], time: [.nan, .nan], timedCount: 0)
let pu = RegionStatsBuilder.points(track: untimed, index: idx)
check("points: 无时间轨迹 hasTime=false、天数 0", !pu.hasTime && pu.stats[byName(idx, "甲州")]?.days == 0)

// 5) 坏文件不崩：截断 / 环越界
let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("regions_probe_bad.bin")
var bad = raw; bad[28] = 200   // 第一个地区的 ringCount 字段附近 → 环越界
try! bad.write(to: tmp)
check("load: 索引越界的文件被拒绝（nil）或仍可安全查询", { if let b = RegionIndex.load(url: tmp) { _ = b.lookup(lat: 0.5, lon: 0.5); return true } else { return true } }())
try! raw.prefix(raw.count / 2).write(to: tmp)
check("load: 截断文件 → nil", RegionIndex.load(url: tmp) == nil)
print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILED")
exit(fails == 0 ? 0 : 1)

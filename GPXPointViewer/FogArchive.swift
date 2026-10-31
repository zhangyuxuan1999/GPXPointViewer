//
//  FogArchive.swift
//  GPXPointViewer
//
//  《世界迷雾》.fwdb 存档导入：Sync/ 目录下每个文件是一个 512×512 世界
//  区块（文件名按 o=0/l=1/h=2/w=3/j=4/s=5/k=6/t=7/r=8/i=9 密码表解出
//  区块号 = 512×y + x），zlib 解压后为 128×128 的 tile 索引表（uint16 LE，
//  0 = 空）+ 每 tile 512 字节的 64×64 位图（MSB 在前）+ 3 字节校验。
//  世界格网 2²²×2²²，与 GPX 迷雾统计同一坐标系。
//
//  渲染侧数据：把解锁格按 2^k 聚合成多级金字塔（键 x<<22|y 按 x 主序
//  排序 + 每块的解锁计数）。取景时按"块 ≈ 2 像素"选级别，x 列二分
//  查找收集视口内实例——任何缩放级别的实例数都有常数上界。
//

import Foundation
import Compression

/// 一个已解析的迷雾存档（不可变，跨线程共享安全）
final class FogArchive: @unchecked Sendable {
    let name: String
    /// 每级：键（x<<22|y，按数值即 x 主序排序）与该块内解锁的 0 级格数。
    /// 级 k 的块边长 = 2^k 格
    let levelKeys: [[UInt64]]
    let levelCounts: [[UInt32]]
    /// 与 levelKeys 平行：块的"出现代序"（区块文件 mtime 升序的秩；父块取子块最小值）。
    /// 时光机回放按 gen ≤ 当前代过滤——.fwdb 无逐格时间戳，采用区块文件的
    /// 修改时间近似排序；同区块格子同代出现，不代表实际探索日期，复制/同步也可能改变它。
    let levelGens: [[UInt16]]
    /// 代序 → 区块文件修改时间（升序）；count ≤ 1 时无时间线（时光机不可用）
    let genTimes: [Double]
    /// 每代：外接框（归一化墨卡托）+ 格数（时光机的相机规划输入）
    struct GenInfo {
        var time: Double
        var x0: Double, y0: Double, x1: Double, y1: Double
        var cells: Int
    }
    let genInfo: [GenInfo]
    let stats: FogStats
    /// 墨卡托 [0,1] 外接框
    let bbox: (minX: Double, minY: Double, maxX: Double, maxY: Double)
    /// RTC 中心（渲染实例的批中心）
    var center: (x: Double, y: Double) {
        ((bbox.minX + bbox.maxX) / 2, (bbox.minY + bbox.maxY) / 2)
    }

    /// 一个 URL 是不是世界迷雾存档：`.fwdb` 后缀的目录，或者任何目录里直接（或 Sync/ 下）放着区块文件
    /// （文件名去掉前 4 后 2 字符后全部是密码表字母 olhwjsktri）。解压出来的 `Sync_all`、`xxx_db` 之类不带后缀也能认
    static func looksLikeArchive(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        if url.pathExtension.lowercased() == "fwdb" { return true }
        let alphabet = Set("olhwjsktri")
        func hasBlocks(_ dir: URL) -> Bool {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
            var hits = 0
            for n in names where n.count >= 8 && n.count <= 20 {
                let core = n.dropFirst(4).dropLast(2)
                if !core.isEmpty, core.allSatisfy({ alphabet.contains($0) }) { hits += 1; if hits >= 2 { return true } }
            }
            return false
        }
        return hasBlocks(url) || hasBlocks(url.appendingPathComponent("Sync"))
    }

    static let gridBits = 22
    static let grid = 1 << 22
    /// 《世界迷雾》名义格宽（赤道，米）= 2πa/2²²
    static let cellMeters = 2.0 * Double.pi * 6_378_137.0 / Double(1 << 22)

    private init(name: String, levelKeys: [[UInt64]], levelCounts: [[UInt32]],
                 levelGens: [[UInt16]], genTimes: [Double], genInfo: [GenInfo],
                 stats: FogStats, bbox: (Double, Double, Double, Double)) {
        self.name = name
        self.levelKeys = levelKeys
        self.levelCounts = levelCounts
        self.levelGens = levelGens
        self.genTimes = genTimes
        self.genInfo = genInfo
        self.stats = stats
        self.bbox = bbox
    }

    /// 数据时间 t 时刻已出现的最大代序（-1 = 尚无任何格子）
    func genUpTo(_ t: Double) -> Int {
        var lo = 0, hi = genTimes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if genTimes[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    // MARK: 解析

    private static let cipher: [Character: UInt64] = [
        "o": 0, "l": 1, "h": 2, "w": 3, "j": 4, "s": 5, "k": 6, "t": 7, "r": 8, "i": 9,
    ]

    /// 后台解析整个 .fwdb 目录；无有效区块时返回 nil
    static func load(url: URL) -> FogArchive? {
        let syncDir = url.appendingPathComponent("Sync")
        let dir = FileManager.default.fileExists(atPath: syncDir.path) ? syncDir : url
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return nil }

        // 并行解析各区块文件（附带文件修改时间 = 该区块最后一次同步）
        let regionFiles = files.filter { !$0.lastPathComponent.hasPrefix(".") }
        var parts = [[UInt64]](repeating: [], count: regionFiles.count)
        parts.withUnsafeMutableBufferPointer { pb in
            let out = pb
            DispatchQueue.concurrentPerform(iterations: regionFiles.count) { fi in
                out[fi] = parseRegion(regionFiles[fi])
            }
        }
        let mtimes = regionFiles.map {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
        }
        // 时间去重升序 → 代序表
        let times = Array(Set(mtimes.filter { $0 > 0 })).sorted()
        let genOf: (Double) -> UInt16 = { t in
            guard !times.isEmpty else { return 0 }
            var lo = 0, hi = times.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if times[mid] < t { lo = mid + 1 } else { hi = mid }
            }
            return UInt16(clamping: min(lo, times.count - 1))
        }
        var pairs = [(key: UInt64, gen: UInt16)]()
        pairs.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for (fi, p) in parts.enumerated() {
            let g = genOf(mtimes[fi])
            for k in p { pairs.append((k, g)) }
        }
        guard !pairs.isEmpty else { return nil }
        return build(name: url.deletingPathExtension().lastPathComponent,
                     pairs: &pairs, times: times.isEmpty ? [0] : times)
    }

    /// 多个存档合并为一个（键并集去重——重叠格只算一次，统计口径与手机 App 一致；
    /// 各档时间轴并入全局代序，重复格取更早的代）
    static func merged(name: String, _ archives: [FogArchive]) -> FogArchive? {
        guard !archives.isEmpty else { return nil }
        if archives.count == 1 { return archives[0] }
        var allTimes = Set<Double>()
        for a in archives { allTimes.formUnion(a.genTimes) }
        let times = allTimes.sorted()
        var pairs = [(key: UInt64, gen: UInt16)]()
        pairs.reserveCapacity(archives.reduce(0) { $0 + $1.levelKeys[0].count })
        for a in archives {
            // 本档代序 → 全局代序（时间二分）
            let remap = a.genTimes.map { t -> UInt16 in
                var lo = 0, hi = times.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if times[mid] < t { lo = mid + 1 } else { hi = mid }
                }
                return UInt16(clamping: min(lo, max(0, times.count - 1)))
            }
            let keys0 = a.levelKeys[0], gens0 = a.levelGens[0]
            for i in 0..<keys0.count {
                pairs.append((keys0[i], remap[Int(gens0[i])]))
            }
        }
        guard !pairs.isEmpty else { return nil }
        return build(name: name, pairs: &pairs, times: times.isEmpty ? [0] : times)
    }

    /// 由 (格键, 代序) 构建存档对象（统计 + 外接框 + 金字塔 + 事件表）。
    /// pairs 无需有序；重复键取最小代（最早出现算数）
    private static func build(name: String,
                              pairs: inout [(key: UInt64, gen: UInt16)],
                              times: [Double]) -> FogArchive? {
        guard !pairs.isEmpty else { return nil }
        pairs.sort { $0.key < $1.key || ($0.key == $1.key && $0.gen < $1.gen) }
        var uniq = [UInt64]()
        var gens = [UInt16]()
        uniq.reserveCapacity(pairs.count)
        gens.reserveCapacity(pairs.count)
        var prevKey = UInt64.max
        for (k, g) in pairs {
            if k != prevKey {
                prevKey = k
                uniq.append(k)
                gens.append(g)      // 排序保证同键第一条 gen 最小
            }
        }
        // 统计（与 GPX 路径同一套对账校准公式）+ 外接框
        let n = Double(grid)
        let baseW = cellMeters
        var m2 = 0.0
        var minX = UInt64.max, maxX = UInt64.min, minY = UInt64.max, maxY = UInt64.min
        for k in uniq {
            let x = k >> 22, y = k & 0x3F_FFFF
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            let yTile = Double(y & ~63) + 32.0          // tile 行中心（对账校准）
            let cosLat = 1.0 / cosh(Double.pi * (1.0 - 2.0 * yTile / n))
            let w = baseW * cosLat
            m2 += w * w
        }
        let km2 = m2 / 1e6
        let level = Int((km2 * 250.0).squareRoot())
        let stats = FogStats(cells: uniq.count, km2: km2, level: level,
                             percent: km2 / 510_072_000.0 * 100.0,
                             nextLevelKm2: max(0, 0.004 * Double((level + 1) * (level + 1)) - km2))
        let bbox = (Double(minX) / n, Double(minY) / n,
                    Double(maxX + 1) / n, Double(maxY + 1) / n)

        // 每代事件表（时光机规划）：代内格子外接框与数量
        var info = [GenInfo](repeating: GenInfo(time: 0, x0: 2, y0: 2, x1: -1, y1: -1, cells: 0),
                             count: times.count)
        for i in 0..<times.count { info[i].time = times[i] }
        for i in 0..<uniq.count {
            let g = Int(gens[i])
            guard g < info.count else { continue }
            let x = Double(uniq[i] >> 22) / n
            let y = Double(uniq[i] & 0x3F_FFFF) / n
            info[g].x0 = min(info[g].x0, x); info[g].x1 = max(info[g].x1, x)
            info[g].y0 = min(info[g].y0, y); info[g].y1 = max(info[g].y1, y)
            info[g].cells += 1
        }
        info.removeAll { $0.cells == 0 }

        // 金字塔：逐级聚合（父键需重排序；计数合并、代序取最小）
        var levelKeys: [[UInt64]] = [uniq]
        var levelCounts: [[UInt32]] = [[UInt32](repeating: 1, count: uniq.count)]
        var levelGens: [[UInt16]] = [gens]
        var curK = uniq
        var curC = levelCounts[0]
        var curG = gens
        for k in 1...14 {
            _ = k
            var pk = [UInt64]()
            pk.reserveCapacity(curK.count / 2 + 1)
            // 父键 = (x>>1)<<22 | (y>>1)：先算再排序、合并计数/代序
            var pp = [(k: UInt64, c: UInt32, g: UInt16)]()
            pp.reserveCapacity(curK.count)
            for i in 0..<curK.count {
                let x = curK[i] >> 22, y = curK[i] & 0x3F_FFFF
                pp.append(((x >> 1) << 22 | (y >> 1), curC[i], curG[i]))
            }
            pp.sort { $0.k < $1.k }
            var pc = [UInt32]()
            var pg = [UInt16]()
            pc.reserveCapacity(pp.count / 2 + 1)
            pg.reserveCapacity(pp.count / 2 + 1)
            var lastKey = UInt64.max
            for (key, c, g) in pp {
                if key == lastKey {
                    pc[pc.count - 1] &+= c
                    pg[pg.count - 1] = min(pg[pg.count - 1], g)
                } else {
                    lastKey = key
                    pk.append(key)
                    pc.append(c)
                    pg.append(g)
                }
            }
            levelKeys.append(pk)
            levelCounts.append(pc)
            levelGens.append(pg)
            curK = pk
            curC = pc
            curG = pg
            if pk.count <= 256 { break }
        }

        return FogArchive(name: name,
                          levelKeys: levelKeys, levelCounts: levelCounts,
                          levelGens: levelGens, genTimes: times, genInfo: info,
                          stats: stats, bbox: bbox)
    }

    /// 解析单个区块文件 → 世界格键数组
    private static func parseRegion(_ url: URL) -> [UInt64] {
        let name = url.lastPathComponent
        // 去前 4、去后 2，余下按密码表转十进制 → 区块号 = 512×y + x
        guard name.count >= 7 else { return [] }
        let core = String(name.dropFirst(4).dropLast(2))
        var num: UInt64 = 0
        let maxRegion: UInt64 = 512 * 512 - 1
        for ch in core {
            guard let d = cipher[ch] else { return [] }
            // Check before multiplying: reject invalid block numbers without
            // overflowing, while accepting any number of leading zeroes.
            guard num <= (maxRegion - d) / 10 else { return [] }
            num = num * 10 + d
        }
        let regionX = num % 512, regionY = num / 512
        guard regionY < 512 else { return [] }

        guard let comp = try? Data(contentsOf: url), comp.count > 8 else { return [] }
        // zlib 流：跳过 2 字节头，用 Compression 的原始 deflate 解压
        let expectedMax = 32768 + 515 * 16384
        var raw = Data(count: expectedMax)
        let written = raw.withUnsafeMutableBytes { dst in
            comp.dropFirst(2).withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.baseAddress!.assumingMemoryBound(to: UInt8.self), expectedMax,
                    src.baseAddress!.assumingMemoryBound(to: UInt8.self), src.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 32768 else { return [] }

        var keys = [UInt64]()
        raw.withUnsafeBytes { rb in
            let p = rb.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let baseX = Int(regionX) * 8192, baseY = Int(regionY) * 8192
            for ty in 0..<128 {
                for tx in 0..<128 {
                    let idx = tx + ty * 128
                    let nblk = Int(p[idx * 2]) | (Int(p[idx * 2 + 1]) << 8)
                    guard nblk > 0 else { continue }
                    let start = 32768 + 515 * (nblk - 1)
                    guard start + 512 <= written else { continue }
                    let tileX = UInt64(baseX + tx * 64)
                    let tileY = UInt64(baseY + ty * 64)
                    for byi in 0..<512 {
                        let b = p[start + byi]
                        guard b != 0 else { continue }
                        let bitBase = byi * 8
                        for k in 0..<8 where (b & (0x80 >> UInt8(k))) != 0 {
                            let bit = bitBase + k
                            let x = tileX + UInt64(bit & 63)
                            let y = tileY + UInt64(bit >> 6)
                            keys.append(x << 22 | y)
                        }
                    }
                }
            }
        }
        return keys
    }

    // MARK: 视口查询（渲染实例收集）

    /// 收集级别 k 下与视口相交的块实例。
    /// 返回 [x, y, halfSize, coverage] × N（墨卡托，相对 batchCenter）
    func collectInstances(level: Int, x0: Double, y0: Double, x1: Double, y1: Double,
                          batchCenter: (x: Double, y: Double),
                          maxGen: Int = .max) -> [Float] {
        let k = min(level, levelKeys.count - 1)
        let keys = levelKeys[k]
        let counts = levelCounts[k]
        let gens = levelGens[k]
        let genFilter = maxGen < genTimes.count - 1     // 全量时零开销跳过
        let genCap = UInt16(clamping: max(0, maxGen))
        guard !keys.isEmpty, maxGen >= 0 else { return [] }
        let n = Double(Self.grid)
        let blockCells = Double(1 << k)
        let blockMerc = blockCells / n
        let cellsPerRow = (Self.grid >> k)
        // 查询 x 区间按世界宽度环绕拆段（MapKit 跨日界线的 visibleMapRect 会越出
        // [0,1]，含边距后更常见）；渲染端已把批中心环绕到视口所在副本，
        // 这里只需保证格子被收集，实例偏移仍相对原批中心
        var xSegs: [(Double, Double)] = []
        if x1 - x0 >= 1.0 {
            xSegs = [(0.0, 1.0)]
        } else {
            let f = (x0).rounded(.down)
            let a = x0 - f, b = x1 - f
            xSegs = b <= 1.0 ? [(a, b)] : [(a, 1.0), (0.0, b - 1.0)]
        }
        let by0 = max(0, Int(floor(y0 * n / blockCells)))
        let by1 = min(cellsPerRow - 1, Int(ceil(y1 * n / blockCells)))
        guard by0 <= by1 else { return [] }

        var out = [Float]()
        out.reserveCapacity(4096)
        // 覆盖率按"线密度"归一：count/2^k（穿过块的轨迹 → 1.0）。按面积占比
        // (count/4^k) 会让远缩放下的轨迹线整体掉到清除阈值以下而消失
        let lineNorm = Float(blockCells)
        let half = Float(blockMerc / 2)
        keys.withUnsafeBufferPointer { kb in
            counts.withUnsafeBufferPointer { cb in
                gens.withUnsafeBufferPointer { gb in
                let K = kb.baseAddress!, C = cb.baseAddress!, G = gb.baseAddress!, m = kb.count
                for (sx0, sx1) in xSegs {
                let bx0 = max(0, Int(floor(sx0 * n / blockCells)))
                let bx1 = min(cellsPerRow - 1, Int(ceil(sx1 * n / blockCells)))
                guard bx0 <= bx1 else { continue }
                // 每列二分下界，向后线性收集
                for x in bx0...bx1 {
                    let lowKey = UInt64(x) << 22 | UInt64(by0)
                    let hiKey = UInt64(x) << 22 | UInt64(by1)
                    var lo = 0, hi = m
                    while lo < hi {
                        let mid = (lo + hi) / 2
                        if K[mid] < lowKey { lo = mid + 1 } else { hi = mid }
                    }
                    var i = lo
                    while i < m, K[i] <= hiKey {
                        if genFilter, G[i] > genCap { i += 1; continue }
                        let y = K[i] & 0x3F_FFFF
                        let cx = (Double(x) + 0.5) * blockMerc
                        let cy = (Double(y) + 0.5) * blockMerc
                        out.append(Float(cx - batchCenter.x))
                        out.append(Float(cy - batchCenter.y))
                        out.append(half)
                        out.append(min(1, Float(C[i]) / lineNorm))
                        i += 1
                    }
                }
                }
                }
            }
        }
        return out
    }

    /// 估算视口内某级别的实例数（选级用，不收集）
    func estimateCount(level: Int, x0: Double, y0: Double, x1: Double, y1: Double) -> Int {
        let k = min(level, levelKeys.count - 1)
        let keys = levelKeys[k]
        guard !keys.isEmpty else { return 0 }
        let n = Double(Self.grid)
        let blockCells = Double(1 << k)
        let cellsPerRow = Self.grid >> k
        let bx0 = max(0, Int(floor(x0 * n / blockCells)))
        let bx1 = min(cellsPerRow - 1, Int(ceil(x1 * n / blockCells)))
        let by0 = max(0, Int(floor(y0 * n / blockCells)))
        let by1 = min(cellsPerRow - 1, Int(ceil(y1 * n / blockCells)))
        guard bx0 <= bx1, by0 <= by1 else { return 0 }
        var total = 0
        keys.withUnsafeBufferPointer { kb in
            let K = kb.baseAddress!, m = kb.count
            for x in stride(from: bx0, through: bx1, by: max(1, (bx1 - bx0) / 64)) {
                let lowKey = UInt64(x) << 22 | UInt64(by0)
                let hiKey = UInt64(x) << 22 | UInt64(by1)
                var lo = 0, hi = m
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if K[mid] < lowKey { lo = mid + 1 } else { hi = mid }
                }
                var c = 0
                var i = lo
                while i < m, K[i] <= hiKey { c += 1; i += 1 }
                total += c * max(1, (bx1 - bx0) / 64)
            }
        }
        return total
    }
}

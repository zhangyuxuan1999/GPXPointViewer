//
//  DiffCompare.swift
//  GPXPointViewer
//
//  找不同：两条轨迹点集的多重集对称差。
//  键 = 量化经纬（1e-6°，≈0.11m——导出按 6~8 位小数取整，往返精确命中）
//      + 可选的秒级时间，SplitMix64 混合成 64 位（4M 点碰撞概率 ~2e-7）。
//  键生成分块并行；两趟字典计数得到两侧"独有"下标（多重集语义：
//  左出现两次右一次 → 左独有一次）。
//

import Foundation

enum DiffCompare {

    struct Result {
        var leftOnly: [Int32] = []      // 左轨迹中右侧没有的点（下标进左轨迹数组）
        var rightOnly: [Int32] = []
        var common = 0                  // 匹配的点对数
    }

    @inline(__always)
    private static func mix64(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 有限但超界的值也要安全：Int64(Double) 是受检转换，超界即 trap。
    /// 钳到 ±4.6e18（< Int64.max）后转换永远安全；垃圾值塌进同一桶无碍
    @inline(__always)
    private static func safeQ(_ x: Double) -> Int64 {
        x.isFinite ? Int64(min(max(x, -4.6e18), 4.6e18)) : 0
    }

    @inline(__always)
    private static func quant(_ lat: Double, _ lon: Double, _ time: Double,
                              _ matchTime: Bool) -> (Int64, Int64, Int64) {
        var lo = safeQ((lon * 1e6).rounded())
        // ±180° 别名归一：同一子午线的两种写法落进同一格
        if lo >= 180_000_000 { lo -= 360_000_000 }
        else if lo < -180_000_000 { lo += 360_000_000 }
        return (safeQ((lat * 1e6).rounded()), lo,
                matchTime ? safeQ(time.rounded()) : 0)
    }

    @inline(__always)
    private static func qkey(_ la: Int64, _ lo: Int64, _ t: Int64) -> UInt64 {
        var h = mix64(UInt64(bitPattern: la))
        h = mix64(h ^ UInt64(bitPattern: lo))
        h = mix64(h ^ UInt64(bitPattern: t))
        return h
    }

    /// 逐点键（并行分块）。时间无效或不参与匹配时按 0 混入
    static func keys(lat: [Double], lon: [Double], time: [Double],
                     matchTime: Bool) -> [UInt64] {
        let n = lat.count
        var out = [UInt64](unsafeUninitializedCapacity: n) { _, m in m = n }
        out.withUnsafeMutableBufferPointer { ob in
            lat.withUnsafeBufferPointer { la in
            lon.withUnsafeBufferPointer { lo in
            time.withUnsafeBufferPointer { ti in
                let o = ob.baseAddress!, a = la.baseAddress!
                let b = lo.baseAddress!, t = ti.baseAddress!
                let cores = ProcessInfo.processInfo.activeProcessorCount
                let chunks = n > 100_000 ? max(1, min(cores, n / 50_000)) : 1
                DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                    for i in (n * ci / chunks)..<(n * (ci + 1) / chunks) {
                        let (la2, lo2, t2) = quant(a[i], b[i], t[i], matchTime)
                        o[i] = qkey(la2, lo2, t2)
                    }
                }
            }}}
        }
        return out
    }

    /// 多重集对称差，两阶段、单一匹配（左右结论同源，账目必然自洽）：
    /// 1. 精确阶段：逐键 min(左计数, 右计数) 配平——按构造对称；
    /// 2. 邻格阶段：只在两侧的精确残留之间做一次贪心匹配（±1e-6°
    ///    的 8 邻格，≈0.11m）——足迹 CSV 四舍五入到 6 位、GPX 保留
    ///    8 位时同一点会落进相邻格，这里把导出精度毛刺全部吸收。
    ///    右残留以"格 → 下标列表"存池，左残留消费即配对；池中剩余
    ///    即右独有——两侧结果来自同一场匹配，不会互相矛盾
    static func diff(latL: [Double], lonL: [Double], timeL: [Double],
                     latR: [Double], lonR: [Double], timeR: [Double],
                     matchTime: Bool) -> Result {
        let kl = keys(lat: latL, lon: lonL, time: timeL, matchTime: matchTime)
        let kr = keys(lat: latR, lon: lonR, time: timeR, matchTime: matchTime)
        var res = Result()

        @inline(__always)
        func consume(_ cnt: inout [UInt64: Int32], _ k: UInt64) -> Bool {
            if let c = cnt[k], c > 0 {
                cnt[k] = c - 1
                return true
            }
            return false
        }

        // —— 阶段 1：精确配平（左消费右计数；右消费左计数。两趟消费的
        //    都是逐键 min，残留集合按构造对称）——
        var cntR = [UInt64: Int32](minimumCapacity: kr.count * 2)
        for k in kr { cntR[k, default: 0] += 1 }
        var leftoverL: [Int32] = []
        for i in 0..<kl.count {
            if consume(&cntR, kl[i]) {
                res.common += 1
            } else {
                leftoverL.append(Int32(i))
            }
        }
        var cntL = [UInt64: Int32](minimumCapacity: kl.count * 2)
        for k in kl { cntL[k, default: 0] += 1 }
        var pool = [UInt64: [Int32]]()          // 右残留：格键 → 下标
        for i in 0..<kr.count where !consume(&cntL, kr[i]) {
            pool[kr[i], default: []].append(Int32(i))
        }

        // —— 阶段 2：残留间邻格匹配（单一匹配，双方结论同源）——
        let neighbors: [(Int64, Int64)] = [(-1, -1), (-1, 0), (-1, 1), (0, -1),
                                           (0, 1), (1, -1), (1, 0), (1, 1)]
        for i32 in leftoverL {
            let i = Int(i32)
            let (la, lo, t) = quant(latL[i], lonL[i], timeL[i], matchTime)
            var matched = false
            for (dx, dy) in neighbors {
                let k = qkey(la + dx, lo + dy, t)
                if var arr = pool[k], !arr.isEmpty {
                    arr.removeLast()
                    pool[k] = arr
                    matched = true
                    break
                }
            }
            if matched {
                res.common += 1
            } else {
                res.leftOnly.append(i32)
            }
        }
        res.rightOnly = pool.values.flatMap { $0 }.sorted()
        return res
    }

    /// 差异合成轨迹：左独有（fileID 0）+ 右独有（fileID 1），
    /// 走常规 TrackData.build 流水线 → 独立窗口用双色按 fileID 着色
    static func makeDiffParsed(latL: [Double], lonL: [Double], eleL: [Double], timeL: [Double],
                               latR: [Double], lonR: [Double], eleR: [Double], timeR: [Double],
                               r: Result, name: String) -> ParsedTrack {
        let nl = r.leftOnly.count, nr = r.rightOnly.count
        let n = nl + nr
        var p = ParsedTrack()
        guard n > 0 else { return p }
        var lat = GeoCompute.uninitialized(n)
        var lon = GeoCompute.uninitialized(n)
        var ele = GeoCompute.uninitialized(n)
        var time = GeoCompute.uninitialized(n)
        var fid = [UInt16](unsafeUninitializedCapacity: n) { _, m in m = n }
        for (j, i32) in r.leftOnly.enumerated() {
            let i = Int(i32)
            lat[j] = latL[i]; lon[j] = lonL[i]
            ele[j] = eleL[i]; time[j] = timeL[i]
            fid[j] = 0
        }
        for (j, i32) in r.rightOnly.enumerated() {
            let i = Int(i32), d = nl + j
            lat[d] = latR[i]; lon[d] = lonR[i]
            ele[d] = eleR[i]; time[d] = timeR[i]
            fid[d] = 1
        }
        p.lat = lat; p.lon = lon; p.ele = ele; p.time = time
        p.fileID = fid
        p.sortedRuns = [0..<nl, nl..<n]
        p.name = name
        return p
    }
}

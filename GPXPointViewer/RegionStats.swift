//
//  RegionStats.swift
//  GPXPointViewer
//
//  按行政区的统计（对标《世界迷雾》行政区卡片）：查看点模式按点数/到访天数，迷雾模式按解锁格面积（与 FogStats 同口径）。
//  统计只在最细一级落点，再逐级汇总到省/州和国家。只依赖 Foundation。
//

import Foundation

struct RegionStat: Equatable {
    var id: UInt16
    var points = 0
    var days = 0                 // 到访天数（本机时区、按每个点当时的偏移折算日期后去重）
    var firstTime = Double.infinity
    var lastTime = -Double.infinity
    var cells = 0                // 迷雾：解锁格
    var m2 = 0.0                 // 迷雾：面积（m²）
    var km2: Double { m2 / 1e6 }
    var level: Int { Int(max(0, km2 * 250).squareRoot()) }   // 本 app 的分区等级：同一公式 ⌊√(km²×250)⌋ 用在该区面积上
}

struct RegionReport: Equatable {
    enum Mode: String { case points, fog }
    let mode: Mode
    var stats: [UInt16: RegionStat]
    var unassignedPoints = 0     // 不在任何地区（海上/边界数据缺）
    var unassignedCells = 0
    var unassignedM2 = 0.0
    var totalPoints = 0
    var totalCells = 0           // 去重后的格数（与 FogStats.cells 同口径）
    var totalM2 = 0.0            // 全部解锁面积（= 各国之和 + 未归属）
    var hasTime = false          // 点口径：有带时间的点（没有就不显示天数）

    func metric(_ id: UInt16) -> Double {
        guard let s = stats[id] else { return 0 }
        return mode == .points ? Double(s.points) : s.m2
    }
    /// 子地区占父地区该指标的百分比
    func share(_ id: UInt16, in parent: UInt16) -> Double {
        let p = metric(parent); return p > 0 ? metric(id) / p * 100 : 0
    }
    /// 到访的国家，按指标降序
    func countries(_ index: RegionIndex) -> [UInt16] {
        index.countries.filter { stats[$0] != nil }.sorted { metric($0) > metric($1) }
    }
    /// 到访的下级地区，按指标降序
    func visitedChildren(of id: UInt16, _ index: RegionIndex) -> [UInt16] {
        (index.children[id] ?? []).filter { stats[$0] != nil }.sorted { metric($0) > metric($1) }
    }
    func childCount(of id: UInt16, _ index: RegionIndex) -> Int { index.children[id]?.count ?? 0 }
    /// 父地区里没有落到任何下级的那部分（直属：下级边界之间的缝、洞、没有更细划分的区域）
    func remainder(of id: UInt16, _ index: RegionIndex) -> Double {
        max(0, metric(id) - (index.children[id] ?? []).reduce(0.0) { $0 + metric($1) })
    }
    /// 国家之和（根列表的分母）
    func assignedTotal(_ index: RegionIndex) -> Double { index.countries.reduce(0.0) { $0 + metric($1) } }
}

enum RegionStatsBuilder {
    /// 查看点模式：每个点归到最细地区，汇总到上级
    static func points(track: TrackData, index: RegionIndex) -> RegionReport {
        var report = RegionReport(mode: .points, stats: [:])
        let n = track.count
        report.totalPoints = n
        report.hasTime = track.timedCount > 0
        guard n > 0 else { return report }
        let assigner = RegionIndex.Assigner(index)
        var perRegionDays: [UInt16: Set<Int32>] = [:]
        var lastDay: [UInt16: Int32] = [:]            // 同日连续命中时跳过 Set 插入（只是省事，不影响正确性）
        // 本机时区偏移按每个点当时生效的值取（夏令时前后不一样）；点按时间有序，缓存到下一次切换
        let zone = TimeZone.current
        var offFrom = Double.infinity, offUntil = -Double.infinity, off = 0.0
        func offset(_ t: Double) -> Double {
            if t >= offFrom, t < offUntil { return off }
            let d = Date(timeIntervalSince1970: t)
            off = Double(zone.secondsFromGMT(for: d))
            offFrom = t
            offUntil = zone.nextDaylightSavingTimeTransition(after: d)?.timeIntervalSince1970 ?? .infinity
            return off
        }
        track.lat.withUnsafeBufferPointer { la in
        track.lon.withUnsafeBufferPointer { lo in
        track.time.withUnsafeBufferPointer { tm in
            for i in 0..<n {
                if i & 0xFFFF == 0, Task.isCancelled { return }           // 数据换代后旧任务尽早退出（结果本来也会被丢）
                guard let id = assigner.assign(lat: la[i], lon: lo[i]) else { report.unassignedPoints += 1; continue }
                let t = i < track.timedCount ? tm[i] : Double.nan
                let day: Int32 = t.isFinite ? Int32(((t + offset(t)) / 86400).rounded(.down)) : .min
                var cur: UInt16? = id
                var depth = 0
                while let c = cur, depth < 4 {
                    var s = report.stats[c] ?? RegionStat(id: c)
                    s.points += 1
                    if t.isFinite {
                        s.firstTime = min(s.firstTime, t); s.lastTime = max(s.lastTime, t)
                        if lastDay[c] != day { lastDay[c] = day; perRegionDays[c, default: []].insert(day) }
                    }
                    report.stats[c] = s
                    cur = index.parent(of: c); depth += 1
                }
            }
        }}}
        for (id, d) in perRegionDays { report.stats[id]?.days = d.count }
        return report
    }

    /// 迷雾模式：解锁格（2²²×2²² 墨卡托格键 x<<22|y，已排序）归到地区，面积与 FogStats 同口径
    static func fog(keys: [UInt64], index: RegionIndex) -> RegionReport {
        var report = RegionReport(mode: .fog, stats: [:])
        guard !keys.isEmpty else { return report }
        let assigner = RegionIndex.Assigner(index)
        let grid = Double(1 << 22), mask: UInt64 = (1 << 22) - 1
        let baseW = 2.0 * Double.pi * 6_378_137.0 / grid
        var prev: UInt64 = .max
        for k in keys where k != prev {       // 两种来源都已排序；防重复计
            prev = k
            report.totalCells += 1
            if report.totalCells & 0xFFFF == 0, Task.isCancelled { return report }
            let x = Double(k >> 22) + 0.5, y = Double(k & mask) + 0.5
            let lon = x / grid * 360 - 180
            let lat = atan(sinh(Double.pi * (1 - 2 * y / grid))) * 180 / Double.pi
            let yTile = Double((k & mask) & ~63) + 32.0
            let cosLat = 1.0 / cosh(Double.pi * (1.0 - 2.0 * yTile / grid))
            let w = baseW * cosLat
            report.totalM2 += w * w
            guard let id = assigner.assign(lat: lat, lon: lon) else { report.unassignedCells += 1; report.unassignedM2 += w * w; continue }
            var cur: UInt16? = id
            var depth = 0
            while let c = cur, depth < 4 {
                var s = report.stats[c] ?? RegionStat(id: c)
                s.cells += 1; s.m2 += w * w
                report.stats[c] = s
                cur = index.parent(of: c); depth += 1
            }
        }
        return report
    }
}

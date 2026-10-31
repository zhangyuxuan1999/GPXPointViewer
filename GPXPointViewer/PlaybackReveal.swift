//
//  PlaybackReveal.swift
//  GPXPointViewer
//
//  原型（分支 fix/playback-area-reveal，DeepSeek 2026-10-31）：
//  时光机"按区域揭示"模型。
//
//  背景：现有 dataTime(at:) 是全局单调时间，回放时任何"时间已走过"的点都会
//  被画出，即使相机还没到那里；北京↔西安这类交错数据会让目的地的历史在
//  到达前就画完（见 DeepSeek/2026-10-31-playback-reveal-analysis.md）。
//
//  本文件不改产品行为：没有加入 Xcode 工程，只被离线测试/探针编译。
//  模型：每个子相机平台 = 一个"区域"；区域的揭示游标只在自己的平台期内
//  从区域最早时间走到最晚时间，其他区域保持上一次的值。
//

import Foundation

/// 一个"区域"= 簇内一个子相机（子相机是空间分组的结果）。
/// 点的归属按"时间 → 簇 → 最近的子相机中心"计算；区域的数据区间取归属点的
/// 最早/最晚时间（不是子相机本身的单次会话区间）。
struct PlaybackArea {
    let id: UInt16
    let cluster: Int
    let sub: Int
    var t0: Double = .infinity
    var t1: Double = -Double.infinity
    var points: Int = 0
    let cx: Double
    let cy: Double
}

struct PlaybackRevealMap {
    let plan: PlaybackPlan
    let areas: [PlaybackArea]
    /// 每个点所属区域；UInt16.max = 未归属（无时间/无子相机）
    let areaOfPoint: [UInt16]
    /// 每个区域的平台（回放秒区间）；nil = 该区域没有平台
    let platform: [(p0: Double, p1: Double)?]

    static func build(track: TrackData, plan: PlaybackPlan) -> PlaybackRevealMap? {
        guard track.count > 0, !plan.clusters.isEmpty else { return nil }
        var areas: [PlaybackArea] = []
        for (ci, c) in plan.clusters.enumerated() {
            for (si, s) in c.subs.enumerated() {
                areas.append(PlaybackArea(id: UInt16(areas.count), cluster: ci, sub: si,
                                          cx: s.cx, cy: s.cy))
            }
        }
        guard !areas.isEmpty else { return nil }

        // 平台区间：簇的驻留段 × 子相机份额
        var platform = [(p0: Double, p1: Double)?](repeating: nil, count: areas.count)
        for (ai, a) in areas.enumerated() {
            guard let seg = plan.segments.first(where: { $0.from == a.cluster && $0.to == a.cluster }) else { continue }
            let sub = plan.clusters[a.cluster].subs[a.sub]
            let hold = seg.p1 - seg.p0
            platform[ai] = (seg.p0 + sub.f0 * hold, seg.p0 + sub.f1 * hold)
        }

        // 每个点：时间 → 簇（簇时间区间有序）→ 最近的子相机
        var areaOf = [UInt16](repeating: .max, count: track.count)
        for i in 0..<track.count {
            let t = track.time[i]
            guard t.isFinite else { continue }
            var lo = 0, hi = plan.clusters.count
            while lo < hi {
                let m = (lo + hi) / 2
                if plan.clusters[m].t1 < t { lo = m + 1 } else { hi = m }
            }
            var ci = min(lo, plan.clusters.count - 1)
            if ci > 0, t < plan.clusters[ci].t0,
               abs(t - plan.clusters[ci - 1].t1) < abs(t - plan.clusters[ci].t0) { ci -= 1 }
            let c = plan.clusters[ci]
            guard !c.subs.isEmpty else { continue }
            var best = -1
            var bestD = Double.infinity
            for (ai, a) in areas.enumerated() where a.cluster == ci {
                let dx = track.mercX[i] - a.cx
                let dy = track.mercY[i] - a.cy
                let d = dx * dx + dy * dy
                if d < bestD { bestD = d; best = ai }
            }
            guard best >= 0 else { continue }
            areaOf[i] = UInt16(best)
            areas[best].t0 = min(areas[best].t0, t)
            areas[best].t1 = max(areas[best].t1, t)
            areas[best].points += 1
        }
        return PlaybackRevealMap(plan: plan, areas: areas, areaOfPoint: areaOf, platform: platform)
    }

    /// 某区域在回放时刻 p 的揭示游标；-inf = 还没开始（一个点都不画）
    func cursor(area ai: Int, at p: Double) -> Double {
        let a = areas[ai]
        guard let pl = platform[ai] else { return -Double.infinity }
        if p < pl.p0 { return -Double.infinity }
        if p >= pl.p1 { return a.t1 }
        let u = (p - pl.p0) / max(1e-9, pl.p1 - pl.p0)
        return a.t0 + (a.t1 - a.t0) * min(1, max(0, u))
    }

    func cursors(at p: Double) -> [Double] {
        (0..<areas.count).map { cursor(area: $0, at: p) }
    }

    /// 日期条该显示的"故事当前时间"：正在驻留的区域用它的游标；
    /// 飞行段取所有已开始区域的游标最大值（不倒退）。
    func displayTime(at p: Double) -> Double {
        var best = -Double.infinity
        for ai in areas.indices {
            let pl = platform[ai]
            if let pl, p >= pl.p0, p <= pl.p1 { return cursor(area: ai, at: p) }
            best = max(best, cursor(area: ai, at: p))
        }
        return best
    }

    /// 对测试/导出友好：直接按 track 时间判断
    func isRevealed(_ i: Int, time: Double, cursors: [Double]) -> Bool {
        let ai = Int(areaOfPoint[i])
        guard ai != Int(UInt16.max) else { return false }
        return time.isFinite && time <= cursors[ai]
    }

    /// 真实文件验证用：旧模型（全局时间）与新区模型对某区域的揭示比例
    func revealedCount(area ai: Int, upto dt: Double, time: [Double]) -> Int {
        var n = 0
        for i in time.indices where Int(areaOfPoint[i]) == ai && time[i].isFinite && time[i] <= dt { n += 1 }
        return n
    }
}

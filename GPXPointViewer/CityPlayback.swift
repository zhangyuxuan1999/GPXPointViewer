//
//  CityPlayback.swift
//  GPXPointViewer
//
//  时光机「城市章节」规划（DeepSeek 2026-10-31，分支 fix/playback-area-reveal）
//
//  旧规划把整段时间当成一条全局时间线，北京/西安交错时相机会在城市间来回，
//  而“时间走过 = 数据已画”会让目的地在到达前就画完。
//  新规划：
//    · 每座城市只出现一次，平台内按该城市自己的时间线生长；
//    · 城市之间是过渡段：相机拉远到能同时放下两座城市的区域视角，
//      城际交通点按时间生长；
//    · 片尾是整条轨迹的总览：相机放到全部数据的范围，所有城际线按时间再走一遍。
//  揭示用“每个区域自己的游标”（PlaybackRevealData），不是全局 dataTime。
//
import Foundation

// MARK: - 数据模型

struct PlaybackCity {
    var id: Int = 0
    var t0: Double = .infinity
    var t1: Double = -.infinity
    var x0: Double = .infinity, y0: Double = .infinity
    var x1: Double = -.infinity, y1: Double = -.infinity
    var weight: Double = 0
    var sessions: [Int] = []
    var cx: Double { (x0 + x1) / 2 }
    var cy: Double { (y0 + y1) / 2 }
}

struct PlaybackTransit {
    var id: Int = 0
    var session: Int = -1
    var t0: Double = .infinity
    var t1: Double = -.infinity
    var x0: Double = .infinity, y0: Double = .infinity
    var x1: Double = -.infinity, y1: Double = -.infinity
    var weight: Double = 0
    var a: Int = -1          // 出发城市（最近的城市，-1 = 未知）
    var b: Int = -1          // 到达城市
}

struct TripCluster {
    var ids: [Int] = []
    var t0: Double = .infinity
    var t1: Double = -.infinity
    var x0: Double = .infinity, y0: Double = .infinity
    var x1: Double = -.infinity, y1: Double = -.infinity
    var weight: Double = 0
    var span: Double { max(x1 - x0, y1 - y0) }
}

struct PlaybackChapter {
    var p0: Double = 0
    var p1: Double = 0
    var d0: Double = 0
    var d1: Double = 0
    var city: Int = -1            // >= 0 = 城市驻留
    var fromCity: Int = -1        // 过渡段
    var toCity: Int = -1
    var transit: [Int] = []       // 本过渡段展示的城际段
    var x0: Double = 0, y0: Double = 0, x1: Double = 1, y1: Double = 1
    var margin: Double = 1.2
    var wide: Bool = false
    var finale: Bool = false
    var trip: Bool = false        // 长途专题章节
}

/// 一个点的区域归属（城市或城际段），以及按时间排序的会话表。
struct CityPlan {
    var cities: [PlaybackCity] = []
    var transit: [PlaybackTransit] = []
    var chapters: [PlaybackChapter] = []
    /// (时间区间, 区域)：区域 = 城市下标，或 cities.count + 城际段下标
    var timeline: [(t0: Double, t1: Double, area: Int)] = []
    var cityChapter: [Int] = []
    var transitChapter: [Int] = []
    var cityTimeAt: [[Double]] = []
    var dataStart: Double = 0
    var dataEnd: Double = 0
    var finaleRange: (Double, Double) = (0, 0)

    var areaCount: Int { cities.count + transit.count }
    /// 片尾/跨洲过渡允许的宽幅上限（约 162°；实时回放在这个尺度会进入地球视角）
    static let wideMaxSpan = 0.45

    // MARK: 相机

    private func camera(box: (x0: Double, y0: Double, x1: Double, y1: Double),
                        margin: Double, wide: Bool, aspect: Double) -> PlaybackCamera {
        let w = max(1e-9, box.x1 - box.x0)
        let h = max(1e-9, box.y1 - box.y0)
        var span = max(w, h / max(0.2, aspect)) * margin
        span = min(wide ? Self.wideMaxSpan : PlaybackPlan.maxSpan,
                   max(PlaybackPlan.minSpan, span))
        let cx = (box.x0 + box.x1) / 2
        var cy = (box.y0 + box.y1) / 2
        let half = span * aspect / 2
        if half < 0.5 { cy = min(max(cy, half), 1 - half) }
        return PlaybackCamera(cx: cx, cy: cy, span: span)
    }

    private func blend(_ a: PlaybackCamera, _ b: PlaybackCamera, _ t: Double) -> PlaybackCamera {
        let u = min(1, max(0, t))
        let la = log(max(a.span, 1e-9)), lb = log(max(b.span, 1e-9))
        return PlaybackCamera(cx: a.cx + (b.cx - a.cx) * u,
                              cy: a.cy + (b.cy - a.cy) * u,
                              span: exp(la + (lb - la) * u))
    }

    private func chapter(at p: Double) -> PlaybackChapter? {
        guard !chapters.isEmpty else { return nil }
        if p <= chapters[0].p0 { return chapters[0] }
        var lo = 0, hi = chapters.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if chapters[mid].p0 <= p { lo = mid } else { hi = mid - 1 }
        }
        return p <= chapters[lo].p1 + 1e-9 ? chapters[lo] : nil
    }

    func camera(at p: Double, aspect: Double) -> PlaybackCamera {
        guard let ch = chapter(at: p) else {
            guard let last = chapters.last else { return PlaybackCamera(cx: 0.5, cy: 0.5, span: 0.1) }
            return camera(box: (last.x0, last.y0, last.x1, last.y1), margin: last.margin,
                          wide: last.wide, aspect: aspect)
        }
        if ch.city >= 0 || ch.finale || ch.trip {
            return camera(box: (ch.x0, ch.y0, ch.x1, ch.y1), margin: ch.margin,
                          wide: ch.wide, aspect: aspect)
        }
        // 过渡：城市 A → 区域视角 → 城市 B
        let u = ch.p1 > ch.p0 ? min(1, max(0, (p - ch.p0) / (ch.p1 - ch.p0))) : 1
        let a = cities[max(0, ch.fromCity)]
        let b = cities[max(0, ch.toCity)]
        let camA = camera(box: (a.x0, a.y0, a.x1, a.y1), margin: 1.35, wide: false, aspect: aspect)
        let camB = camera(box: (b.x0, b.y0, b.x1, b.y1), margin: 1.35, wide: false, aspect: aspect)
        let camR = camera(box: (ch.x0, ch.y0, ch.x1, ch.y1), margin: ch.margin,
                          wide: ch.wide, aspect: aspect)
        if u < 0.12 { return blend(camA, camR, u / 0.12) }
        if u > 0.88 { return blend(camR, camB, (u - 0.88) / 0.12) }
        return camR
    }

    // MARK: 故事时间与揭示游标

    private func progress(_ ch: PlaybackChapter, _ p: Double) -> Double {
        ch.p1 > ch.p0 ? min(1, max(0, (p - ch.p0) / (ch.p1 - ch.p0))) : 1
    }

    /// 故事当前时间：城市用本地时间，过渡/片尾用城际时间。
    func displayTime(at p: Double) -> Double {
        guard let ch = chapter(at: p) else {
            return chapters.last.map { $0.d1 } ?? dataEnd
        }
        let u = progress(ch, p)
        // DeepSeek 2026-11-01：城市章节的日期必须和点的揭示游标用同一条
        // 点数分位曲线，否则会出现“2021 年却显示 2023 年的点”。
        if ch.city >= 0, cityTimeAt.indices.contains(ch.city) {
            let q = cityTimeAt[ch.city]
            if q.count >= 2 {
                let x = min(1, max(0, u)) * Double(q.count - 1)
                let i = Int(x), f = x - Double(i)
                return q[i] + ((i + 1 < q.count ? q[i + 1] : q[i]) - q[i]) * f
            }
        }
        return ch.d0 + (ch.d1 - ch.d0) * u
    }

    /// 某区域在时刻 p 的揭示时间。
    /// 关键：一旦某个区域开始揭示，它就**单调累积**，不会因为换章节被清零/重画。
    /// 城市/长途章节只决定“现在推进哪个区域”，已经画过的点永远保留。
    func cursor(area: Int, at p: Double) -> Double {
        if area < cities.count {
            let ci = cityChapter[area]
            guard ci >= 0 else { return -.infinity }
            let ch = chapters[ci]
            if p < ch.p0 { return -.infinity }
            if p >= ch.p1 { return cities[area].t1 }
            let hold = min(0.5, (ch.p1 - ch.p0) * 0.1)
            if p < ch.p0 + hold { return -.infinity }
            let denom = max(1e-9, ch.p1 - ch.p0 - hold)
            let u = min(1, max(0, (p - ch.p0 - hold) / denom))
            let q = cityTimeAt.indices.contains(area) ? cityTimeAt[area] : []
            if q.count >= 2 {
                let x = u * Double(q.count - 1)
                let i = Int(x), f = x - Double(i)
                return q[i] + ((i + 1 < q.count ? q[i + 1] : q[i]) - q[i]) * f
            }
            return ch.d0 + (ch.d1 - ch.d0) * u
        }
        let ti = area - cities.count
        guard ti >= 0, ti < transit.count else { return -.infinity }
        if let ci = transitChapter.indices.contains(ti) ? transitChapter[ti] : nil, ci >= 0 {
            let ch = chapters[ci]
            if p < ch.p0 { return -.infinity }
            if p >= ch.p1 { return transit[ti].t1 }
            let hold = min(0.3, (ch.p1 - ch.p0) * 0.05)
            if p < ch.p0 + hold { return -.infinity }
            let denom = max(1e-9, ch.p1 - ch.p0 - hold)
            let u = min(1, max(0, (p - ch.p0 - hold) / denom))
            return ch.d0 + (ch.d1 - ch.d0) * u
        }
        // 没有专题章节的城际段：片尾一次性显示（不重画，之前已显示的保持）
        if let fin = chapters.last, fin.finale, p >= fin.p0 { return transit[ti].t1 }
        return -.infinity
    }

    /// 全部区域的揭示游标（相对 epoch 的秒 +1；0 = 未开始）
    func relativeCursors(at p: Double, epoch: Double) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: areaCount)
        for ai in 0..<areaCount {
            let t = cursor(area: ai, at: p)
            guard t.isFinite else { continue }
            let rel = (t - epoch).rounded(.down)
            if rel <= 0 { out[ai] = 1 }
            else if rel >= Double(UInt32.max - 2) { out[ai] = UInt32.max - 1 }
            else { out[ai] = UInt32(rel) + 1 }
        }
        return out
    }
}

// MARK: - 点 → 区域

/// 供渲染器做“按区域揭示”的逐点数据。
/// times 是相对 epoch 的秒数 +1；游标 0 表示该区域还没开始。
struct PlaybackRevealData {
    let areaOfPoint: [UInt16]
    let times: [UInt32]
    let epoch: Double
    let areaCount: Int

    init?(track: TrackData, plan: CityPlan) {
        let n = track.count
        guard n > 0, plan.areaCount > 0, !plan.timeline.isEmpty else { return nil }
        let epoch = plan.dataStart.rounded(.down)
        var areas = [UInt16](repeating: UInt16(plan.areaCount), count: n)   // 默认隐藏区
        var times = [UInt32](repeating: 0, count: n)
        let tl = plan.timeline
        let m = tl.count
        // 每个点：在时间覆盖它的会话中，优先选 bbox 包含该点的区域。
        // 只按时间会在“同一时刻有跨洲会话”时把中国点错分到欧洲区域，
        // 导致画面在欧洲却画出中国轨迹。
        func areaBox(_ a: Int) -> (x0: Double, y0: Double, x1: Double, y1: Double) {
            if a < plan.cities.count {
                let c = plan.cities[a]; return (c.x0, c.y0, c.x1, c.y1)
            }
            let t = plan.transit[a - plan.cities.count]; return (t.x0, t.y0, t.x1, t.y1)
        }
        var active: [Int] = []
        var next = 0
        var lo = 0
        for i in 0..<n {
            let t = track.time[i]
            guard t.isFinite else { times[i] = 0; continue }
            while next < m && tl[next].t0 <= t { active.append(next); next += 1 }
            active.removeAll { tl[$0].t1 < t }
            var area = plan.areaCount   // 隐藏区
            if !active.isEmpty {
                let x = track.mercX[i], y = track.mercY[i]
                var bestSpan = Double.infinity
                var bestDist = Double.infinity
                var insideArea = -1
                var nearestArea = -1
                for j in active {
                    let a = tl[j].area
                    let b = areaBox(a)
                    if x >= b.x0 && x <= b.x1 && y >= b.y0 && y <= b.y1 {
                        let sp = (b.x1 - b.x0) + (b.y1 - b.y0)
                        if sp < bestSpan { bestSpan = sp; insideArea = a }
                    } else {
                        let dx = max(0, max(b.x0 - x, x - b.x1))
                        let dy = max(0, max(b.y0 - y, y - b.y1))
                        let d = dx * dx + dy * dy
                        if d < bestDist { bestDist = d; nearestArea = a }
                    }
                }
                area = insideArea >= 0 ? insideArea
                    : (bestDist < 0.000004 ? nearestArea : plan.areaCount)
            }
            areas[i] = UInt16(max(0, min(plan.areaCount, area)))
            let rel = (t - epoch).rounded(.down)
            times[i] = rel <= 0 ? 1
                : (rel >= Double(UInt32.max - 2) ? UInt32.max - 1 : UInt32(rel) + 1)
        }
        self.areaOfPoint = areas
        self.times = times
        self.epoch = epoch
        self.areaCount = plan.areaCount + 1
    }
}

// MARK: - 规划

enum CityPlaybackPlanner {

    private struct Session {
        var t0: Double, t1: Double
        var x0: Double, x1: Double, y0: Double, y1: Double
        var cx: Double, cy: Double
        var w: Double
        var n: Int
        var sx: Double, sy: Double      // 首点
        var ex: Double, ey: Double      // 末点
        var span: Double { max(x1 - x0, y1 - y0) }
    }

    /// 会话切分规则与旧规划一致：>6h 或 >~80km 跳变
    private static func sessions(_ ev: [PlaybackEvent]) -> [Session] {
        guard let first = ev.first else { return [] }
        var out: [Session] = []
        var s = Session(t0: first.t, t1: first.t,
                        x0: first.x, x1: first.x, y0: first.y, y1: first.y,
                        cx: first.x, cy: first.y, w: first.w, n: 1,
                        sx: first.x, sy: first.y, ex: first.x, ey: first.y)
        var px = first.x, py = first.y
        for e in ev.dropFirst() {
            if e.t - s.t1 > 21_600 || max(abs(e.x - px), abs(e.y - py)) > 0.002 {
                s.cx /= Double(s.n); s.cy /= Double(s.n)
                out.append(s)
                s = Session(t0: e.t, t1: e.t, x0: e.x, x1: e.x, y0: e.y, y1: e.y,
                            cx: e.x, cy: e.y, w: 0, n: 0,
                            sx: e.x, sy: e.y, ex: e.x, ey: e.y)
            }
            s.t1 = e.t
            s.x0 = min(s.x0, e.x); s.x1 = max(s.x1, e.x)
            s.y0 = min(s.y0, e.y); s.y1 = max(s.y1, e.y)
            s.cx += e.x; s.cy += e.y; s.w += e.w; s.n += 1
            s.ex = e.x; s.ey = e.y
            px = e.x; py = e.y
        }
        s.cx /= Double(s.n); s.cy /= Double(s.n)
        out.append(s)
        return out
    }

    private static func dist(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Double {
        max(abs(x0 - x1), abs(y0 - y1))
    }

    static func build(events: [PlaybackEvent], duration: Double) -> CityPlan? {
        guard events.count >= 2, duration > 6 else { return nil }
        let ev = events.sorted { $0.t < $1.t }
        guard let firstT = ev.first?.t, let lastT = ev.last?.t, lastT - firstT > 60 else { return nil }
        let ss = sessions(ev)
        guard !ss.isEmpty else { return nil }

        // 1) 城市种子：按会话权重从大到小取“彼此相距 > 160km”的中心作为城市种子。
        //    这样北京/西安的区县会归到同一个城市，而不是被 48km 拆成好几块；
        //    也避免单链合并（北京→天津→唐山…）滚成跨省大团。
        struct CityAcc {
            var sessions: [Int] = []
            var x0 = Double.infinity, y0 = Double.infinity
            var x1 = -Double.infinity, y1 = -Double.infinity
            var t0 = Double.infinity, t1 = -Double.infinity
            var w = 0.0
            var cx = 0.0, cy = 0.0
            var n = 0
        }
        let shortIdx = ss.indices.filter { ss[$0].span <= 0.002 }
        let byWeight = shortIdx.sorted { ss[$0].w > ss[$1].w }
        func pickSeeds(_ sep: Double) -> [(x: Double, y: Double)] {
            var out: [(x: Double, y: Double)] = []
            for i in byWeight {
                let d = out.map { dist(ss[i].cx, ss[i].cy, $0.x, $0.y) }.min() ?? .infinity
                if d > sep {
                    out.append((ss[i].cx, ss[i].cy))
                    if out.count >= 14 { break }
                }
            }
            return out
        }
        // 默认 ~90km 间距：北京/西安的区县归到同一个种子。只有整份数据几乎
        // 集中在一个城市（种子 ≤1 个）时才收紧，避免把大城市拆成多章。
        var seeds = pickSeeds(0.003)
        if seeds.count < 2 { seeds = pickSeeds(0.0015) }
        guard !seeds.isEmpty else { return nil }

        // 2) 会话 → 最近种子（约 280km 外算城际；长会话直接算城际）
        var accs = seeds.map { _ in CityAcc() }
        var accOfSession = [Int](repeating: -1, count: ss.count)
        for i in ss.indices {
            let s = ss[i]
            guard s.span <= 0.002 else { continue }
            var best = -1
            var bestD = Double.infinity
            for (k, seed) in seeds.enumerated() {
                let d = dist(s.cx, s.cy, seed.x, seed.y)
                if d < bestD { bestD = d; best = k }
            }
            guard best >= 0, bestD <= 0.0016 else { continue }   // ~85km：更远的算城际，城市镜头不会被撑大
            accOfSession[i] = best
            var a = accs[best]
            a.sessions.append(i)
            a.x0 = min(a.x0, s.x0); a.x1 = max(a.x1, s.x1)
            a.y0 = min(a.y0, s.y0); a.y1 = max(a.y1, s.y1)
            a.t0 = min(a.t0, s.t0); a.t1 = max(a.t1, s.t1)
            a.w += s.w
            a.cx += s.cx * s.w; a.cy += s.cy * s.w
            a.n += s.n
            accs[best] = a
        }
        for k in accs.indices where accs[k].w > 0 {
            accs[k].cx /= accs[k].w
            accs[k].cy /= accs[k].w
        }

        // 3) 按权重选 K 座城市（45s 量级放 10–12 座；留够每城 ≥1.4s 的驻留）
        let totalW = accs.reduce(0.0) { $0 + $1.w }
        var ranked = accs.enumerated().filter { $0.element.w > 0 }
            .sorted { $0.element.w > $1.element.w }
        if ranked.count > 4 {
            let base = ranked
            ranked = ranked.filter { item in
                let a = item.element
                let span = max(a.x1 - a.x0, a.y1 - a.y0)
                let days = (a.t1 - a.t0) / 86400
                return a.w >= totalW * 0.02 && span <= 0.0045 && days >= 30
            }
            if ranked.count < 2 { ranked = base.filter { $0.element.w >= totalW * 0.005 } }
        }
        // DeepSeek 2026-11-01：单城不做片尾/长途章节（否则日期倒回重放）
        var singleCity = ranked.count <= 1
        var finaleDur = singleCity ? 0.0 : min(8.0, max(4.0, duration * 0.13))
        let maxK = min(8, max(4, Int((duration - finaleDur) / 3.7) + 1))
        if ranked.count > maxK { ranked = Array(ranked.prefix(maxK)) }
        while ranked.count > 4 {
            let k = ranked.count
            let need = finaleDur + Double(k - 1) * 1.5 + Double(k) * 3.0
            if need <= duration { break }
            ranked.removeLast()
        }
        guard !ranked.isEmpty else { return nil }

        // 4) 建立城市（按首次到访时间排序）
        var cities: [PlaybackCity] = []
        var oldToNew: [Int: Int] = [:]
        let ordered = ranked.map { $0.offset }.sorted { accs[$0].w > accs[$1].w }
        for (newID, oldID) in ordered.enumerated() {
            oldToNew[oldID] = newID
            let a = accs[oldID]
            var c = PlaybackCity(id: newID, t0: a.t0, t1: a.t1,
                                 x0: a.x0, y0: a.y0, x1: a.x1, y1: a.y1,
                                 weight: a.w)
            c.sessions = a.sessions
            cities.append(c)
        }

        // 5) 会话归属：城市 / 被吸收 / 城际
        var transit: [PlaybackTransit] = []
        var cityOfSession = [Int](repeating: -2, count: ss.count)   // -2 未定, -1 城际
        for (i, s) in ss.enumerated() {
            let old = accOfSession[i]
            if old >= 0, let nid = oldToNew[old] {
                cityOfSession[i] = nid
                continue
            }
            if ss[i].span > 0.002 { cityOfSession[i] = -1; continue }
            // 被丢弃的小城：离保留城市 120km 内并入，否则算城际
            var best = -1
            var bestD = Double.infinity
            for (ci, c) in cities.enumerated() {
                let d = dist(s.cx, s.cy, c.cx, c.cy)
                if d < bestD { bestD = d; best = ci }
            }
            if best >= 0, bestD <= 0.0016 {
                cityOfSession[i] = best
                cities[best].x0 = min(cities[best].x0, s.x0)
                cities[best].x1 = max(cities[best].x1, s.x1)
                cities[best].y0 = min(cities[best].y0, s.y0)
                cities[best].y1 = max(cities[best].y1, s.y1)
                cities[best].t0 = min(cities[best].t0, s.t0)
                cities[best].t1 = max(cities[best].t1, s.t1)
                cities[best].weight += s.w
                cities[best].sessions.append(i)
            } else {
                cityOfSession[i] = -1
            }
        }

        // 5b) 收尾合并：吸收周边小城后，两个同城种子的包围盒可能靠得很近
        //     （北京被拆成两三章）。中心相距 <~40km 的城市合并，会话归属同步改写。
        var mergedAny = true
        while mergedAny {
            mergedAny = false
            var i = 0
            while i < cities.count {
                var j = i + 1
                while j < cities.count {
                    let d = dist(cities[i].cx, cities[i].cy, cities[j].cx, cities[j].cy)
                    guard d < 0.0015 else { j += 1; continue }
                    cities[i].x0 = min(cities[i].x0, cities[j].x0)
                    cities[i].x1 = max(cities[i].x1, cities[j].x1)
                    cities[i].y0 = min(cities[i].y0, cities[j].y0)
                    cities[i].y1 = max(cities[i].y1, cities[j].y1)
                    cities[i].t0 = min(cities[i].t0, cities[j].t0)
                    cities[i].t1 = max(cities[i].t1, cities[j].t1)
                    cities[i].weight += cities[j].weight
                    cities[i].sessions += cities[j].sessions
                    for k in cityOfSession.indices where cityOfSession[k] == j { cityOfSession[k] = i }
                    for k in cityOfSession.indices where cityOfSession[k] > j { cityOfSession[k] -= 1 }
                    cities.remove(at: j)
                    mergedAny = true
                }
                i += 1
            }
        }

        // 合并/吸收后如果只剩一座城市，同样不做片尾
        if cities.count == 1 { singleCity = true; finaleDur = 0 }

        // 3b) 每城“累计点数 → 时间”分位：揭示按点数走，不按时间线性走
        var cityTimeAt = [[Double]](repeating: [], count: cities.count)
        for i in cities.indices {
            var entries: [(t0: Double, t1: Double, w: Double)] = []
            for si in cities[i].sessions {
                let s = ss[si]
                entries.append((s.t0, s.t1, max(1.0, s.w)))
            }
            entries.sort { $0.t0 < $1.t0 }
            let total = entries.reduce(0.0) { $0 + $1.w }
            guard total > 0 else { continue }
            var samples: [Double] = []
            var idx = 0
            var cum = 0.0
            for k in 0...64 {
                let target = total * Double(k) / 64
                while idx < entries.count && cum + entries[idx].w < target {
                    cum += entries[idx].w; idx += 1
                }
                if idx >= entries.count { samples.append(entries.last!.t1) }
                else {
                    let e = entries[idx]
                    let f = e.w > 0 ? min(1, max(0, (target - cum) / e.w)) : 0
                    samples.append(e.t0 + (e.t1 - e.t0) * f)
                }
            }
            cityTimeAt[i] = samples
        }

        func nearestCity(_ x: Double, _ y: Double) -> Int {
            var best = -1
            var bestD = Double.infinity
            for (ci, c) in cities.enumerated() {
                let d = dist(x, y, c.cx, c.cy)
                if d < bestD { bestD = d; best = ci }
            }
            return best
        }

        // 6) 城际段（按首末点归到两座城市）
        for (i, s) in ss.enumerated() where cityOfSession[i] == -1 {
            var tr = PlaybackTransit(id: transit.count, session: i,
                                     t0: s.t0, t1: s.t1,
                                     x0: s.x0, y0: s.y0, x1: s.x1, y1: s.y1)
            tr.a = nearestCity(s.sx, s.sy)
            tr.b = nearestCity(s.ex, s.ey)
            tr.weight = s.w
            transit.append(tr)
        }

        if singleCity, !transit.isEmpty {
            // 单城没有过渡/片尾：城际（长途）点并入城市区域，时间范围也覆盖它们
            if let t0 = transit.map(\.t0).min(), let t1 = transit.map(\.t1).max() {
                cities[0].t0 = min(cities[0].t0, t0)
                cities[0].t1 = max(cities[0].t1, t1)
            }
        }

        // 7) 时长：驻留按权重、过渡按是否有城际段
        let n = cities.count
        var transDurs = [Double](repeating: 1.0, count: max(0, n - 1))
        // 5c) 长途专题按“地理区域”聚合：同一区域的所有城际会话在同一章内
        // 按时间揭示，保证新疆/东北/欧洲的路线不会一半在专题、一半在片尾。
        func latitude(_ y: Double) -> Double { atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi }
        func longitude(_ x: Double) -> Double { x * 360 - 180 }
        struct RegionDef {
            let name: String
            let minLat: Double, maxLat: Double, minLon: Double, maxLon: Double
        }
        let regions = [
            RegionDef(name: "欧洲", minLat: 30, maxLat: 65, minLon: -15, maxLon: 30),
            RegionDef(name: "新疆", minLat: 35, maxLat: 50, minLon: 73, maxLon: 97),
            RegionDef(name: "东北", minLat: 38, maxLat: 56, minLon: 115, maxLon: 135),
            RegionDef(name: "青藏", minLat: 26, maxLat: 38, minLon: 78, maxLon: 103),
        ]
        var tripClusters: [TripCluster] = []
        if !singleCity {
            var bucketed = [[Int]](repeating: [], count: regions.count)
            for (ti, t) in transit.enumerated() {
                // 只有整段都落在区域内才收进来，跨洲/跨国长线不进区域章，
                // 避免“欧洲章里画出中国轨迹”。
                let laLo = latitude(max(t.y0, t.y1))
                let laHi = latitude(min(t.y0, t.y1))
                let loLo = longitude(min(t.x0, t.x1))
                let loHi = longitude(max(t.x0, t.x1))
                for (ri, r) in regions.enumerated()
                where laLo >= r.minLat && laHi <= r.maxLat && loLo >= r.minLon && loHi <= r.maxLon {
                    bucketed[ri].append(ti); break
                }
            }
            for ids in bucketed where ids.count >= 3 {
                let w = ids.reduce(0.0) { $0 + transit[$1].weight }
                guard w >= 8000 else { continue }
                var c = TripCluster(ids: ids)
                for ti in ids {
                    let t = transit[ti]
                    c.t0 = min(c.t0, t.t0); c.t1 = max(c.t1, t.t1)
                    c.x0 = min(c.x0, t.x0); c.y0 = min(c.y0, t.y0)
                    c.x1 = max(c.x1, t.x1); c.y1 = max(c.y1, t.y1)
                }
                c.weight = w
                tripClusters.append(c)
            }
            tripClusters.sort { $0.t0 < $1.t0 }
            if tripClusters.count > 4 { tripClusters = Array(tripClusters.prefix(4)) }
        }
        func tripDuration(_ c: TripCluster) -> Double {
            min(5.0, 2.0 + 0.12 * Double(c.ids.count))
        }
        let tripSet = Set(tripClusters.flatMap { $0.ids })
        // 过渡段只做城市间的相机移动，不再画城际点：
        // 城际全部交给长途专题/片尾，避免“断线”和把相机拉到全国尺度。
        let pairTransit = [[Int]](repeating: [], count: max(0, n - 1))
        _ = tripSet
        for c in 0..<max(0, n - 1) where !pairTransit[c].isEmpty { transDurs[c] = 1.5 }
        let tripDur = tripClusters.reduce(0.0) { $0 + tripDuration($1) }
        let holdTotal = max(Double(n) * 1.5, duration - finaleDur - tripDur - transDurs.reduce(0, +))
        let wSum = max(1e-9, cities.reduce(0.0) { $0 + $1.weight })
        let floorHold = 1.5
        var holds = [Double](repeating: floorHold, count: n)
        let extra = max(0, holdTotal - floorHold * Double(n))
        for i in cities.indices { holds[i] += extra * cities[i].weight / wSum }

        // 8) 章节 + 相机范围
        var chapters: [PlaybackChapter] = []
        var cityChapter = [Int](repeating: -1, count: n)
        var p = 0.0
        var c = 0
        while c < n {
            cityChapter[c] = chapters.count
            chapters.append(PlaybackChapter(p0: p, p1: p + holds[c],
                                            d0: cities[c].t0, d1: max(cities[c].t0 + 1, cities[c].t1),
                                            city: c,
                                            x0: cities[c].x0, y0: cities[c].y0,
                                            x1: cities[c].x1, y1: cities[c].y1,
                                            margin: 1.35, wide: false))
            p += holds[c]
            if c + 1 < n {
                var box = (x0: min(cities[c].x0, cities[c + 1].x0),
                           y0: min(cities[c].y0, cities[c + 1].y0),
                           x1: max(cities[c].x1, cities[c + 1].x1),
                           y1: max(cities[c].y1, cities[c + 1].y1))
                var d0 = cities[c].t1
                var d1 = max(cities[c].t1 + 1, cities[c + 1].t0)
                // 过渡段没有城际点，d0/d1 只用于日期条
                _ = d0; _ = d1
                chapters.append(PlaybackChapter(p0: p, p1: p + transDurs[c],
                                                d0: d0, d1: max(d0 + 1, d1),
                                                fromCity: c, toCity: c + 1,
                                                transit: pairTransit[c],
                                                x0: box.x0, y0: box.y0,
                                                x1: box.x1, y1: box.y1,
                                                margin: 1.18, wide: true))
                p += transDurs[c]
            }
            c += 1
        }
        var all = (x0: Double.infinity, y0: Double.infinity,
                   x1: -Double.infinity, y1: -Double.infinity)
        for c in cities {
            all.x0 = min(all.x0, c.x0); all.y0 = min(all.y0, c.y0)
            all.x1 = max(all.x1, c.x1); all.y1 = max(all.y1, c.y1)
        }
        for tr in transit {
            all.x0 = min(all.x0, tr.x0); all.y0 = min(all.y0, tr.y0)
            all.x1 = max(all.x1, tr.x1); all.y1 = max(all.y1, tr.y1)
        }
        for cl in tripClusters {
            let dur = tripDuration(cl)
            chapters.append(PlaybackChapter(p0: p, p1: p + dur,
                                            d0: cl.t0, d1: max(cl.t0 + 1, cl.t1),
                                            transit: cl.ids,
                                            x0: cl.x0, y0: cl.y0, x1: cl.x1, y1: cl.y1,
                                            margin: 1.3, wide: true, trip: true))
            p += dur
        }
        if !transit.isEmpty, !singleCity {
            let tr0 = transit.map(\.t0).min() ?? firstT
            let tr1 = transit.map(\.t1).max() ?? lastT
            chapters.append(PlaybackChapter(p0: p, p1: p + finaleDur,
                                            d0: tr0, d1: max(tr0 + 1, tr1),
                                            x0: all.x0, y0: all.y0, x1: all.x1, y1: all.y1,
                                            margin: 1.06, wide: true, finale: true))
            p += finaleDur
        }

        // 9) 城际段 → 过渡章节 / 片尾
        var transitChapter = [Int](repeating: -1, count: transit.count)
        for (ci, ch) in chapters.enumerated() where !ch.transit.isEmpty {
            for k in ch.transit { if k < transitChapter.count { transitChapter[k] = ci } }
        }

        // 10) 点的时间线（会话 → 区域）
        var timeline: [(t0: Double, t1: Double, area: Int)] = []
        for (i, s) in ss.enumerated() {
            let area: Int
            if cityOfSession[i] >= 0 { area = cityOfSession[i] }
            else if singleCity { area = 0 }   // 单城：长途点跟城市一起揭示
            else if let ti = transit.firstIndex(where: { $0.session == i }) { area = cities.count + ti }
            else { continue }
            timeline.append((s.t0, s.t1, area))
        }
        timeline.sort { $0.t0 < $1.t0 }
        guard !timeline.isEmpty else { return nil }

        var plan = CityPlan()
        plan.cities = cities
        plan.transit = transit
        plan.chapters = chapters
        plan.timeline = timeline
        plan.cityChapter = cityChapter
        plan.transitChapter = transitChapter
        plan.cityTimeAt = cityTimeAt
        plan.dataStart = firstT
        plan.dataEnd = lastT
        plan.finaleRange = transit.isEmpty ? (firstT, lastT)
            : (transit.map(\.t0).min() ?? firstT, transit.map(\.t1).max() ?? lastT)
        return plan
    }
}

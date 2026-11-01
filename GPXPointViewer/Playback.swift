//
//  Playback.swift
//  GPXPointViewer
//
//  时光机回放：按真实时间流逝重放整段历史——轨迹/热力/迷雾从无到有生长，
//  相机在活跃区域之间自动缓动（驻留 → 拉高飞行 → 落下）。
//
//  规划（一次性，后台）：
//    事件（时间 + 墨卡托坐标 + 权重）
//      → 会话切分（时间断档 >6h 或跳跃 >80km）
//      → 活跃簇（相邻会话中心 <60km 合并；驻留取景 = 簇外接框 ×1.35，跨度钳
//        [~3km, ~5500km]——上限保证飞行拉高时不触发地球视角切换）
//      → 时长分配（驻留 ∝ 权重（保底），飞行固定 ~1.6s）
//      → 时间弯曲（簇内数据时间线性走，空档压缩进飞行段）
//  相机（纯函数 camera(t)）：驻留静止；飞行 = 中心 smoothstep 平移 +
//  对数跨度的二次贝塞尔"拉高-俯冲"弧线。回放与视频导出共用同一套规划。
//

import Foundation

/// 规划输入事件（GPX = 抽稀轨迹点；.fwdb = 每代区块的外接框角点）
struct PlaybackEvent {
    var t: Double        // Unix 秒
    var x: Double        // 归一化墨卡托
    var y: Double
    var w: Double        // 权重（点数/格数）
}

struct PlaybackCamera {
    var cx: Double
    var cy: Double
    var span: Double     // 取景宽（归一化墨卡托）
}

final class PlaybackPlan: @unchecked Sendable {
    /// 驻留段内的子相机。f0/f1 是"平台期"（相机静止停在该区的进度区间），
    /// 平台之间是相机过渡窗口。数据-相机合同：本区数据只在平台期内生长
    /// （相机就位后才画）；两平台之间的过渡窗口只快进区间外的过路数据
    struct SubCam {
        var f0: Double, f1: Double           // 平台期（驻留段内进度比例）
        var d0: Double, d1: Double           // 本区自己的数据时间区间
        var cx: Double, cy: Double
        var spanX: Double, spanY: Double
    }

    struct Cluster {
        var t0: Double, t1: Double
        var cx: Double, cy: Double
        var spanX: Double, spanY: Double     // 外接框两向跨度（取景时按窗口宽高比取大）
        var weight: Double
        var subs: [SubCam] = []              // ≥2 才启用（单一活动区的驻留保持静止）
    }
    struct Segment {
        var p0: Double, p1: Double    // 回放秒
        var d0: Double, d1: Double    // 数据时间
        var from: Int, to: Int        // 簇下标；from == to 为驻留
    }

    let clusters: [Cluster]
    let segments: [Segment]
    let duration: Double
    let dataStart: Double
    let dataEnd: Double
    let holdDurs: [Double]     // 每簇驻留段回放时长（飞行端点与子相机衔接用）
    var cityPlan: CityPlan?    // 非 nil = 城市章节规划（GPX）；nil = 旧簇规划（.fwdb）

    private init(clusters: [Cluster], segments: [Segment], duration: Double,
                 holdDurs: [Double], cityPlan: CityPlan? = nil) {
        self.clusters = clusters
        self.segments = segments
        self.duration = duration
        self.holdDurs = holdDurs
        self.cityPlan = cityPlan
        self.dataStart = segments.first?.d0 ?? 0
        self.dataEnd = segments.last?.d1 ?? 0
    }

    /// 跨度上限：飞行拉高不能越过地球视角切换阈值（~5500km）
    static let maxSpan = 0.137
    /// 驻留最小取景宽（~3.2km）
    static let minSpan = 0.00008

    /// 取景宽：两向外接框按窗口宽高比取大 × 1.35 边距（保证目标都在窗内）
    private static func fitSpan(spanX: Double, spanY: Double, aspect: Double) -> Double {
        min(Self.maxSpan,
            max(Self.minSpan, max(spanX, spanY / max(0.2, aspect)) * 1.35))
    }

    private func viewSpan(_ c: Cluster, aspect: Double) -> Double {
        Self.fitSpan(spanX: c.spanX, spanY: c.spanY, aspect: aspect)
    }

    // MARK: 查询（纯函数，逐帧调用）

    func dataTime(at p: Double) -> Double {
        if let cp = cityPlan { return cp.displayTime(at: p) }
        guard let seg = segment(at: p) else { return dataEnd }
        let u = seg.p1 > seg.p0 ? min(1, max(0, (p - seg.p0) / (seg.p1 - seg.p0))) : 1
        // 驻留段带子相机：平台期内铺本区数据（相机就位后才画），
        // 平台间隙快进两区之间的过路/被吸收数据（相机移动时画的是路上的）
        if seg.from == seg.to, subsActive(seg.from) {
            // 驻留太短相机不巡游时数据也必须线性铺（否则平台节奏
            // 对着一台静止的整簇相机走，数据与镜头脱节）
            let subs = clusters[seg.from].subs
            if !subs.isEmpty {
                var prevF = 0.0
                var prevD = seg.d0
                for sub in subs {
                    if u <= sub.f0 + 1e-9 {
                        let g = sub.f0 > prevF ? (u - prevF) / (sub.f0 - prevF) : 1
                        return prevD + (sub.d0 - prevD) * min(1, max(0, g))
                    }
                    if u <= sub.f1 + 1e-9 {
                        // 平台头留 ~0.3s 落地缓冲：底图瓦片加载完再开始生长
                        let holdDur = max(0.1, seg.p1 - seg.p0)
                        let grace = min(0.3 / holdDur, (sub.f1 - sub.f0) * 0.2)
                        let a0 = sub.f0 + grace
                        let fu = sub.f1 > a0 ? (u - a0) / (sub.f1 - a0) : 1
                        return sub.d0 + (sub.d1 - sub.d0) * min(1, max(0, fu))
                    }
                    prevF = sub.f1
                    prevD = sub.d1
                }
                let g = 1 > prevF ? (u - prevF) / (1 - prevF) : 1
                return prevD + (seg.d1 - prevD) * min(1, max(0, g))
            }
        }
        return seg.d0 + (seg.d1 - seg.d0) * u
    }

    /// 该簇的子相机是否生效（驻留 ≥2.5s 才巡游）
    private func subsActive(_ i: Int) -> Bool {
        !clusters[i].subs.isEmpty && holdDurs[i] >= 2.5
    }

    private func subCamera(_ s: SubCam, aspect: Double) -> PlaybackCamera {
        PlaybackCamera(cx: s.cx, cy: s.cy,
                       span: Self.fitSpan(spanX: s.spanX, spanY: s.spanY, aspect: aspect))
    }

    /// 簇的入场/出场相机：有子相机巡游时是第一个/最后一个子相机——
    /// 飞行段两端必须与之衔接，否则落地/起飞瞬间取景跳变
    private func entryCamera(_ i: Int, aspect: Double) -> PlaybackCamera {
        if subsActive(i) { return subCamera(clusters[i].subs[0], aspect: aspect) }
        let c = clusters[i]
        return PlaybackCamera(cx: c.cx, cy: c.cy, span: viewSpan(c, aspect: aspect))
    }

    private func exitCamera(_ i: Int, aspect: Double) -> PlaybackCamera {
        if subsActive(i) {
            return subCamera(clusters[i].subs[clusters[i].subs.count - 1], aspect: aspect)
        }
        let c = clusters[i]
        return PlaybackCamera(cx: c.cx, cy: c.cy, span: viewSpan(c, aspect: aspect))
    }

    func camera(at p: Double, aspect: Double = 9.0 / 16.0) -> PlaybackCamera {
        if let cp = cityPlan { return cp.camera(at: p, aspect: aspect) }
        guard let seg = segment(at: p) else {
            return exitCamera(clusters.count - 1, aspect: aspect)
        }
        let a = clusters[seg.from]
        if seg.from == seg.to {
            if subsActive(seg.from) {
                return holdCamera(a, seg: seg, p: p, aspect: aspect)
            }
            return PlaybackCamera(cx: a.cx, cy: a.cy, span: viewSpan(a, aspect: aspect))
        }
        // 飞行：出场相机 → 入场相机（与两端驻留取景严格连续）
        let camA = exitCamera(seg.from, aspect: aspect)
        let camB = entryCamera(seg.to, aspect: aspect)
        let u = seg.p1 > seg.p0 ? min(1, max(0, (p - seg.p0) / (seg.p1 - seg.p0))) : 1
        return flyCamera(camA, camB, u, arcK: 1.35)
    }

    /// 平移-缩放耦合过渡（van Wijk 式）：跨度走对数空间二次贝塞尔，
    /// 平移速度 ∝ 当前跨度——从城市尺度平台直飞洲际时，起降端
    /// 跨度小、平移自动慢，帧间移动/跨度比全程近似恒定，不甩鞭
    private func flyCamera(_ x: PlaybackCamera, _ y: PlaybackCamera,
                           _ u: Double, arcK: Double) -> PlaybackCamera {
        let dist = ((y.cx - x.cx) * (y.cx - x.cx)
                  + (y.cy - x.cy) * (y.cy - x.cy)).squareRoot()
        let arc = min(Self.maxSpan, max(max(x.span, y.span), dist * arcK))
        let l0 = log(x.span), l1 = log(y.span), lm = log(arc)
        @inline(__always) func spanAt(_ t: Double) -> Double {
            let s = t * t * (3 - 2 * t)
            let s01 = l0 + (lm - l0) * s
            let s12 = lm + (l1 - lm) * s
            return exp(s01 + (s12 - s01) * s)
        }
        // 平移进度 = 跨度的归一化积分（24 段中点法，确定性）
        let nBins = 24
        var total = 0.0
        var upto = 0.0
        for i in 0..<nBins {
            let a0 = Double(i) / Double(nBins)
            let a1 = Double(i + 1) / Double(nBins)
            let w = spanAt((a0 + a1) / 2)
            total += w
            if u >= a1 { upto += w }
            else if u > a0 { upto += w * (u - a0) / (a1 - a0) }
        }
        let T = total > 0 ? upto / total : u * u * (3 - 2 * u)
        return PlaybackCamera(cx: x.cx + (y.cx - x.cx) * T,
                              cy: x.cy + (y.cy - x.cy) * T,
                              span: spanAt(u))
    }

    /// 驻留段内的子相机巡游：平台期静止取景本区，平台之间的窗口做
    /// 对数跨度弧线过渡——窗口与 dataTime 的"过路数据快进"严格重合，
    /// 到位之前不画目的地的数据
    private func holdCamera(_ c: Cluster, seg: Segment, p: Double,
                            aspect: Double) -> PlaybackCamera {
        let holdDur = max(0.1, seg.p1 - seg.p0)
        let f = min(1, max(0, (p - seg.p0) / holdDur))
        let subs = c.subs

        var prevF = 0.0
        for (k, sub) in subs.enumerated() {
            if f <= sub.f0 + 1e-9 {
                if k == 0 { return subCamera(sub, aspect: aspect) }   // 入场已由飞行衔接
                let u = sub.f0 > prevF
                    ? min(1, max(0, (f - prevF) / (sub.f0 - prevF))) : 1
                return flyCamera(subCamera(subs[k - 1], aspect: aspect),
                                 subCamera(sub, aspect: aspect),
                                 u, arcK: 1.2)
            }
            if f <= sub.f1 + 1e-9 { return subCamera(sub, aspect: aspect) }
            prevF = sub.f1
        }
        return subCamera(subs[subs.count - 1], aspect: aspect)
    }

    private func segment(at p: Double) -> Segment? {
        guard !segments.isEmpty else { return nil }
        if p <= segments[0].p0 { return segments[0] }
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].p0 <= p { lo = mid } else { hi = mid - 1 }
        }
        return p <= segments[lo].p1 + 1e-9 ? segments[lo] : nil
    }

    // MARK: 规划

    static func build(events: [PlaybackEvent], duration: Double) -> PlaybackPlan? {
        guard events.count >= 2, duration > 3 else { return nil }
        let ev = events.sorted { $0.t < $1.t }
        guard ev.last!.t - ev.first!.t > 60 else { return nil }

        // 1) 会话：相邻事件时间断档 >6h 或空间跳跃 >~80km（无数据的瞬移，
        //    如飞行）才切开——连续的长途行程保持为一个会话
        var sessions: [Cluster] = []
        var s = Cluster(t0: ev[0].t, t1: ev[0].t, cx: ev[0].x, cy: ev[0].y,
                        spanX: 0, spanY: 0, weight: ev[0].w)
        var sx0 = ev[0].x, sx1 = ev[0].x, sy0 = ev[0].y, sy1 = ev[0].y
        var prevX = ev[0].x, prevY = ev[0].y
        func closeSession() {
            s.cx = (sx0 + sx1) / 2
            s.cy = (sy0 + sy1) / 2
            s.spanX = sx1 - sx0
            s.spanY = sy1 - sy0
            sessions.append(s)
        }
        for e in ev.dropFirst() {
            let gap = e.t - s.t1
            let jump = max(abs(e.x - prevX), abs(e.y - prevY))
            if gap > 21_600 || jump > 0.002 {
                closeSession()
                s = Cluster(t0: e.t, t1: e.t, cx: e.x, cy: e.y,
                            spanX: 0, spanY: 0, weight: 0)
                sx0 = e.x; sx1 = e.x; sy0 = e.y; sy1 = e.y
            }
            s.t1 = e.t
            s.weight += e.w
            sx0 = min(sx0, e.x); sx1 = max(sx1, e.x)
            sy0 = min(sy0, e.y); sy1 = max(sy1, e.y)
            prevX = e.x; prevY = e.y
        }
        closeSession()

        // 2) 相邻会话外接框中心接近（起步 ~60km）→ 合并为活跃簇；
        //    簇太多时加倍合并距离重跑，钳到 ≤22 个（相机巡游节奏的上限）。
        //    成员会话保留下来供第 2b 步生成驻留段内的子相机
        var mergeDist = 0.0015
        var clusters: [Cluster] = sessions
        var members: [[Cluster]] = sessions.map { [$0] }
        for _ in 0..<10 {
            var merged: [Cluster] = []
            var mergedMembers: [[Cluster]] = []
            for (ci, sess) in clusters.enumerated() {
                if var last = merged.last,
                   max(abs(sess.cx - last.cx), abs(sess.cy - last.cy)) < mergeDist {
                    let x0 = min(last.cx - last.spanX / 2, sess.cx - sess.spanX / 2)
                    let x1 = max(last.cx + last.spanX / 2, sess.cx + sess.spanX / 2)
                    let y0 = min(last.cy - last.spanY / 2, sess.cy - sess.spanY / 2)
                    let y1 = max(last.cy + last.spanY / 2, sess.cy + sess.spanY / 2)
                    last.cx = (x0 + x1) / 2
                    last.cy = (y0 + y1) / 2
                    last.spanX = x1 - x0
                    last.spanY = y1 - y0
                    last.t1 = max(last.t1, sess.t1)
                    last.weight += sess.weight
                    merged[merged.count - 1] = last
                    mergedMembers[mergedMembers.count - 1] += members[ci]
                } else {
                    merged.append(sess)
                    mergedMembers.append(members[ci])
                }
            }
            clusters = merged
            members = mergedMembers
            if clusters.count <= 22 { break }
            mergeDist *= 2.2
        }
        // 权重过小的簇（如只有几个点的一次路过）不值得飞过去——跳过，
        // 其时间段自然并入相邻飞行段的时间弯曲
        let wTotal = clusters.reduce(0.0) { $0 + $1.weight }
        if clusters.count > 2 {
            // 首尾簇必须保留——故事的开头（哪怕只有几百个点）和结尾不能被跳过
            let keepIdx = (0..<clusters.count).filter {
                $0 == 0 || $0 == clusters.count - 1
                    || clusters[$0].weight >= wTotal * 0.005
            }
            if !keepIdx.isEmpty {
                clusters = keepIdx.map { clusters[$0] }
                members = keepIdx.map { members[$0] }
            }
        }

        // 2b) 驻留段子相机：簇内会话再按固定 ~60km 合并成"活动区"。
        //    ≥2 个活动区才启用——长驻留期（在西安过冬）相机会放大跟随当期
        //    活动区，短途出行临时切换取景，不再整段停在簇外接框看不清细节
        for i in 0..<clusters.count {
            // 细粒度（~60km）合并出活动区；再按权重挑 ≤6 个"主区"取景，
            // 小区被吸收进相邻主区的时间轴——镜头只在真正待过的地方之间
            // 巡游，主区取景保持紧凑（加倍合并会把西安和远途撑成一大框）
            var areas: [Cluster] = []
            for sess in members[i] {
                if var last = areas.last,
                   max(abs(sess.cx - last.cx), abs(sess.cy - last.cy)) < 0.0006 {
                    let x0 = min(last.cx - last.spanX / 2, sess.cx - sess.spanX / 2)
                    let x1 = max(last.cx + last.spanX / 2, sess.cx + sess.spanX / 2)
                    let y0 = min(last.cy - last.spanY / 2, sess.cy - sess.spanY / 2)
                    let y1 = max(last.cy + last.spanY / 2, sess.cy + sess.spanY / 2)
                    last.cx = (x0 + x1) / 2
                    last.cy = (y0 + y1) / 2
                    last.spanX = x1 - x0
                    last.spanY = y1 - y0
                    last.t1 = max(last.t1, sess.t1)
                    last.weight += sess.weight
                    areas[areas.count - 1] = last
                } else {
                    areas.append(sess)
                }
            }
            if areas.count > 2 {
                // 同一地点多次回访是多个"连续会话区"（单区权重都不大）——
                // 按空间分组合计权重选主区：常驻地整组保留，各时段各自成子相机
                var groupOf = [Int](repeating: -1, count: areas.count)
                var groups: [[Int]] = []
                for (j, area) in areas.enumerated() {
                    var g = -1
                    for (gi, grp) in groups.enumerated() {
                        let rep = areas[grp[0]]
                        if max(abs(area.cx - rep.cx), abs(area.cy - rep.cy)) < 0.0012 {
                            g = gi
                            break
                        }
                    }
                    if g < 0 {
                        groups.append([j])
                        g = groups.count - 1
                    } else {
                        groups[g].append(j)
                    }
                    groupOf[j] = g
                }
                let totalW = areas.reduce(0.0) { $0 + $1.weight }
                let gw = groups.map { grp in grp.reduce(0.0) { $0 + areas[$1].weight } }
                let rankedG = gw.enumerated().sorted { $0.element > $1.element }
                var keepG = Set(rankedG.prefix(8)
                    .filter { $0.element >= totalW * 0.05 }
                    .map { $0.offset })
                if keepG.isEmpty { keepG.insert(rankedG[0].offset) }
                var keepSet = Set(areas.indices.filter { keepG.contains(groupOf[$0]) })
                if keepSet.isEmpty { keepSet.insert(0) }
                var kept: [Cluster] = []
                var leading: [Cluster] = []
                for (idx, area) in areas.enumerated() {
                    if keepSet.contains(idx) {
                        var a2 = area
                        for lead in leading { a2.weight += lead.weight }
                        leading = []
                        kept.append(a2)
                    } else if kept.isEmpty {
                        leading.append(area)
                    } else {
                        // 只并份额不并时间：被吸收时段在相机过渡窗口里快进
                        kept[kept.count - 1].weight += area.weight
                    }
                }
                if kept.count >= 2 { areas = kept }
                else if kept.count == 1 { areas = kept }
            }
            guard areas.count >= 2 else { continue }
            // 回放份额 ∝ 权重（保底 5% 防闪切），归一后铺满 [0,1]
            let aw = areas.map { max($0.weight, 1e-9) }
            let awSum = aw.reduce(0, +)
            let fracs = aw.map { $0 / awSum }
            var subs: [SubCam] = []
            var acc = 0.0
            for (j, area) in areas.enumerated() {
                let f1 = j == areas.count - 1 ? 1.0 : acc + fracs[j]
                subs.append(SubCam(f0: acc, f1: f1,
                                   d0: area.t0, d1: max(area.t0 + 1, area.t1),
                                   cx: area.cx, cy: area.cy,
                                   spanX: area.spanX, spanY: area.spanY))
                acc = f1
            }
            clusters[i].subs = subs
        }

        // 3) 时长分配：飞行 1.6s（不够就压到 0.8s），驻留 ∝ 权重。
        //    保底 0.5s 用水位法迭代——触底簇钉死，只对其余簇按权重分剩余预算
        //    （先保底再整体归一会把保底又压回去）；总时长只在保底逼迫时超出请求
        let n = clusters.count
        var flightDur = 1.6
        if Double(n - 1) * flightDur > duration * 0.45 {
            flightDur = max(0.8, duration * 0.45 / Double(max(1, n - 1)))
        }
        // 保底分层：有多个活动区的簇保底 2.6–4.6s（跨过 2.5s 巡游激活线
        // 且按权重加成——重簇要装下多个放大平台）；普通簇 0.5s。
        // 预算装不下时按权重从轻到重降回 0.5——重簇优先保住巡游，
        // 不整体压扁（压扁会抹平权重信号，谁都巡不了）
        let wMean = clusters.reduce(0.0) { $0 + $1.weight } / Double(max(1, n))
        var floors = clusters.map { c in
            c.subs.count >= 2
                ? 2.6 + 2.0 * min(1.0, c.weight / max(1e-9, wMean))
                : 0.5
        }
        let holdTotal = max(Double(n) * 0.5, duration - Double(n - 1) * flightDur)
        var fSum = floors.reduce(0, +)
        if fSum > holdTotal {
            for i in clusters.indices
                .sorted(by: { clusters[$0].weight < clusters[$1].weight })
            where floors[i] > 0.5 {
                fSum -= floors[i] - 0.5
                floors[i] = 0.5
                if fSum <= holdTotal { break }
            }
        }
        let wSum = clusters.reduce(0.0) { $0 + $1.weight }
        let frac = clusters.map { c in
            0.35 / Double(n) + 0.65 * c.weight / max(1e-9, wSum)
        }
        var locked = [Bool](repeating: false, count: n)
        var lockedTime = 0.0
        for _ in 0..<n {
            let freeW = (0..<n).reduce(0.0) { locked[$1] ? $0 : $0 + frac[$1] }
            guard freeW > 1e-12 else { break }
            var changed = false
            for i in 0..<n where !locked[i] {
                if (holdTotal - lockedTime) * frac[i] / freeW < floors[i] {
                    locked[i] = true
                    lockedTime += floors[i]
                    changed = true
                }
            }
            if !changed { break }
        }
        let freeW = (0..<n).reduce(0.0) { locked[$1] ? $0 : $0 + frac[$1] }
        let holds = (0..<n).map { i in
            locked[i] ? floors[i]
                      : (holdTotal - lockedTime) * frac[i] / max(1e-12, freeW)
        }

        // 3b) 时长已定：回放份额 <1.2s 的子区不值得停留——吸收进相邻
        //     保留子区（时间与份额并入），只剩一个则撤销巡游
        for i in 0..<n where !clusters[i].subs.isEmpty {
            let hd = holds[i]
            if hd < 2.5 { continue }        // camera 侧按 holdDurs 判定不启用
            var subs = clusters[i].subs
            // 平台最短时长随驻留缩放（0.9–1.2s）：2.6s 保底簇按 1.2 会把
            // 两个 ~1.17s 的平台全裁光，退回整簇大框——正是"小区域不放大"
            let minPlat = min(1.2, max(0.9, hd * 0.45))
            var keepSet = Set(subs.enumerated()
                .filter { ($0.element.f1 - $0.element.f0) * hd >= minPlat }
                .map { $0.offset })
            if keepSet.count < 2 {
                // 份额均匀碎裂时全员不达标——按份额取前 N 个（每个 ~1.5s），
                // 其余吸收进去后份额自然变够；一个不留会退回整簇大框取景
                let maxN = max(2, Int(hd / 1.5))
                keepSet = Set(subs.enumerated()
                    .sorted { ($0.element.f1 - $0.element.f0)
                            > ($1.element.f1 - $1.element.f0) }
                    .prefix(maxN)
                    .map { $0.offset })
            }
            if keepSet.count < subs.count {
                var out: [SubCam] = []
                var pendingF = 0.0
                for (j, sub) in subs.enumerated() {
                    if keepSet.contains(j) {
                        var s2 = sub
                        s2.f0 -= pendingF
                        pendingF = 0
                        out.append(s2)
                    } else if out.isEmpty {
                        pendingF += sub.f1 - sub.f0
                    } else {
                        out[out.count - 1].f1 = sub.f1
                    }
                }
                if !out.isEmpty {
                    out[0].f0 = 0
                    out[out.count - 1].f1 = 1
                }
                subs = out
            }
            // 吸收会改变份额——再校验：驻留装得下时先从富余平台抽份额
            // 补足短平台（吸收常产生 19/81 失衡，按旧逻辑第二平台会被
            // 误杀，整簇退回大框）；装不下才丢最小的（0.5s 秒级迁移是
            // 甩鞭的根源）
            while subs.count >= 2 {
                let needF = minPlat / hd
                let deficient = subs.indices
                    .filter { subs[$0].f1 - subs[$0].f0 < needF - 1e-9 }
                if deficient.isEmpty { break }
                var rebalanced = false
                if hd >= Double(subs.count) * (minPlat + 0.35) {
                    var shares = subs.map { $0.f1 - $0.f0 }
                    var deficit = 0.0
                    for j in shares.indices where shares[j] < needF {
                        deficit += needF - shares[j]
                        shares[j] = needF
                    }
                    let sSum = shares.reduce(0.0) { $0 + max(0, $1 - needF) }
                    if sSum > deficit {
                        for j in shares.indices where shares[j] > needF {
                            shares[j] -= deficit * (shares[j] - needF) / sSum
                        }
                        var acc = 0.0
                        for j in subs.indices {
                            subs[j].f0 = acc
                            acc += shares[j]
                            subs[j].f1 = acc
                        }
                        subs[subs.count - 1].f1 = 1
                        rebalanced = true
                    }
                }
                if rebalanced { break }
                let bad = deficient.min(by: { subs[$0].f1 - subs[$0].f0
                                            < subs[$1].f1 - subs[$1].f0 })!
                let dropped = subs.remove(at: bad)
                if bad > 0 {
                    subs[bad - 1].f1 = dropped.f1
                } else {
                    subs[0].f0 = dropped.f0
                }
            }
            // 重访使相邻平台的数据区间重叠时，间隙映射会倒退——
            // 链式钳单调（上限簇末端）：重叠部分在更早的平台已经画过
            let dCap = max(clusters[i].t0 + 1, clusters[i].t1)
            for k in 1..<max(1, subs.count) {
                subs[k].d0 = min(max(subs[k].d0, subs[k - 1].d1), dCap)
                subs[k].d1 = min(max(subs[k].d1, subs[k].d0 + 1), dCap)
            }
            // 钳后不足 1h 的平台（被吞或本就极短）：没有生长可看，
            // 相机驻留只是干瞪眼——并入相邻
            var j = 0
            while subs.count >= 2, j < subs.count {
                if subs[j].d1 - subs[j].d0 < 3600 {
                    let dropped = subs.remove(at: j)
                    if j > 0 { subs[j - 1].f1 = dropped.f1 }
                    else { subs[0].f0 = dropped.f0 }
                } else {
                    j += 1
                }
            }
            // 份额区间 → 平台期：每个边界挖出相机过渡窗口（0.4–1.2s，
            // 不超过两侧份额的 35%）；窗口即 dataTime 的过路快进区
            if subs.count >= 2 {
                var res = subs
                for k in 1..<subs.count {
                    let lenP = (subs[k - 1].f1 - subs[k - 1].f0) * hd
                    let lenK = (subs[k].f1 - subs[k].f0) * hd
                    let tSec = min(1.2, max(0.4, 0.4 * min(lenP, lenK)))
                    let t = min(tSec / hd,
                                0.35 * (subs[k - 1].f1 - subs[k - 1].f0),
                                0.35 * (subs[k].f1 - subs[k].f0))
                    res[k - 1].f1 = subs[k].f0 - t
                    res[k].f0 = subs[k].f0 + t
                }
                subs = res
            }
            // 端窗：簇头/簇尾被"只并份额不并时间"吸收的时段也要有快进窗。
            // f0==0 / f1==1 会让 dataTime 的头尾映射零宽，这些数据在
            // 驻留边界一帧内瞬间出现而不是快进铺开
            if subs.count >= 2 {
                if subs[0].d0 > clusters[i].t0 + 1800 {
                    subs[0].f0 = min(0.3 / hd, (subs[0].f1 - subs[0].f0) * 0.25)
                }
                let last = subs.count - 1
                if subs[last].d1 < dCap - 1800 {
                    subs[last].f1 = 1 - min(0.4 / hd,
                                            (subs[last].f1 - subs[last].f0) * 0.25)
                }
            }
            clusters[i].subs = subs.count >= 2 ? subs : []
        }

        // 4) 段表（回放秒 ↔ 数据时间的分段线性弯曲；dEnd 保证跨段单调）
        var segments: [Segment] = []
        var pp = 0.0
        for i in 0..<n {
            let c = clusters[i]
            let dEnd = max(c.t0 + 1, c.t1)
            segments.append(Segment(p0: pp, p1: pp + holds[i],
                                    d0: c.t0, d1: dEnd, from: i, to: i))
            pp += holds[i]
            if i + 1 < n {
                segments.append(Segment(p0: pp, p1: pp + flightDur,
                                        d0: dEnd, d1: max(dEnd, clusters[i + 1].t0),
                                        from: i, to: i + 1))
                pp += flightDur
            }
        }
        return PlaybackPlan(clusters: clusters, segments: segments, duration: pp,
                            holdDurs: holds)
    }

    /// 城市章节：逐区域揭示游标（相对 dataStart 的秒 +1；0 = 未开始）。
    /// nil = 旧规划（.fwdb），不做区域揭示。
    func cursors(at p: Double) -> [UInt32]? {
        guard let cp = cityPlan else { return nil }
        return cp.relativeCursors(at: p, epoch: dataStart.rounded(.down))
    }

    /// 城市章节规划（GPX 时光机）：每城一次、城际区域视角、片尾总览。
    static func buildCities(events: [PlaybackEvent], duration: Double) -> PlaybackPlan? {
        guard let cp = CityPlaybackPlanner.build(events: events, duration: duration) else { return nil }
        let clusters = cp.cities.map { c in
            Cluster(t0: c.t0, t1: c.t1, cx: c.cx, cy: c.cy,
                    spanX: max(0, c.x1 - c.x0), spanY: max(0, c.y1 - c.y0),
                    weight: c.weight)
        }
        var segs: [Segment] = []
        var holds: [Double] = []
        for ch in cp.chapters {
            let from = ch.city >= 0 ? ch.city : max(0, ch.fromCity)
            let to = ch.city >= 0 ? ch.city : max(0, ch.toCity)
            segs.append(Segment(p0: ch.p0, p1: ch.p1, d0: ch.d0, d1: ch.d1, from: from, to: to))
            if ch.city >= 0 { holds.append(ch.p1 - ch.p0) }
        }
        return PlaybackPlan(clusters: clusters, segments: segs,
                            duration: cp.chapters.last?.p1 ?? duration,
                            holdDurs: holds.isEmpty ? [0] : holds,
                            cityPlan: cp)
    }

    // MARK: 事件提取

    /// GPX：时间有序段抽稀成 ≤15 万事件
    static func events(track: TrackData) -> [PlaybackEvent] {
        guard track.timedCount > 1 else { return [] }
        let n = track.timedCount
        let stride = max(1, n / 150_000)
        var out = [PlaybackEvent]()
        out.reserveCapacity(n / stride + 2)
        var i = 0
        while i < n {
            out.append(PlaybackEvent(t: track.time[i], x: track.mercX[i],
                                     y: track.mercY[i], w: Double(stride)))
            i += stride
        }
        return out
    }

    /// .fwdb：每代区块的外接框两角（权重均分）——簇外接框据此撑开
    static func events(archive: FogArchive) -> [PlaybackEvent] {
        guard archive.genTimes.count > 1 else { return [] }
        var out = [PlaybackEvent]()
        out.reserveCapacity(archive.genInfo.count * 2)
        for g in archive.genInfo where g.x1 >= g.x0 {
            let w = Double(g.cells) / 2
            out.append(PlaybackEvent(t: g.time, x: g.x0, y: g.y0, w: w))
            out.append(PlaybackEvent(t: g.time, x: g.x1, y: g.y1, w: w))
        }
        return out
    }
}

/// 回放时钟（时间轴 UI 独立观察，60fps 步进不惊扰整棵视图树）
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var head: Double = 0
    @Published var playing: Bool = true
}

/// 一次回放会话（store 持有；plan 可因时长调整而重建）
@MainActor
final class PlaybackSession: ObservableObject {
    @Published var plan: PlaybackPlan
    let clock = PlaybackClock()
    let events: [PlaybackEvent]     // 时长调整时重建 plan 用
    let isArchive: Bool
    /// 城市章节的逐点区域数据（旧 .fwdb 规划为 nil）
    var reveal: PlaybackRevealData?
    /// 规划重建（改时长）后递增；视图据此重绑渲染器的逐点数据
    var revealVersion = 1

    init(plan: PlaybackPlan, events: [PlaybackEvent], isArchive: Bool,
         reveal: PlaybackRevealData? = nil) {
        self.plan = plan
        self.events = events
        self.isArchive = isArchive
        self.reveal = reveal
    }
}

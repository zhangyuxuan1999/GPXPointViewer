//
//  TrackShape.swift
//  GPXQuickLook / GPXThumbnail 共用
//
//  轨迹形状绘制：等距投影（中纬 cos 补偿）、预览级抽稀（全局≤6000点）、
//  轨迹间"瞬移"长段自动断开、起点绿/终点红。
//  描边用不透明色分块冲刷——半透明超长单一路径会让 CG 做
//  昂贵的描边轮廓合并（443MB 备份文件实测 11s → 毫秒级）。
//

import Cocoa

/// Preview-only sampling. Output storage is capped globally; source statistics are
/// O(pointBudget), and the common single path never allocates an input-sized index array.
enum GPXPreviewSampling {
    static let pointBudget = 6_000
    struct Plan {
        let indices: [Int]
        /// Hard source boundary or any original soft break since the previous retained point.
        let breakBefore: [Bool]
        let medianStep: Double
    }
    private struct Source {
        let id: UInt32
        var count: Int
        var first: Int
        var last: Int
    }
    private static func distance(_ a: Int, _ b: Int, lat: [Double], lon: [Double]) -> Double {
        hypot(lon[b] - lon[a], lat[b] - lat[a])
    }
    private static func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
    static func plan(lat: [Double], lon: [Double], segmentID: [UInt32]) -> Plan {
        let n = min(lat.count, lon.count)
        precondition(segmentID.isEmpty || segmentID.count == n)
        guard n > 0 else { return Plan(indices: [], breakBefore: [], medianStep: 0) }
        let sampleEvery = max(1, (n + 4095) / 4096)
        if segmentID.isEmpty || segmentID.dropFirst().allSatisfy({ $0 == segmentID.first }) {
            var distances: [Double] = []
            distances.reserveCapacity(min(4096, n - 1))
            if n > 1 {
                for i in stride(from: 1, to: n, by: sampleEvery) {
                    distances.append(distance(i - 1, i, lat: lat, lon: lon))
                }
            }
            let med = median(distances), jump = max(50 * med, 0.5)
            let wanted = min(n, pointBudget)
            var indices: [Int] = [], breaks: [Bool] = []
            indices.reserveCapacity(wanted); breaks.reserveCapacity(wanted)
            var nextRank = 0, emitted = 0, pendingBreak = false
            for i in 0..<n {
                if i > 0, distance(i - 1, i, lat: lat, lon: lon) > jump { pendingBreak = true }
                if i == nextRank {
                    indices.append(i); breaks.append(emitted == 0 || pendingBreak)
                    pendingBreak = false; emitted += 1
                    nextRank = emitted < wanted ? emitted * (n - 1) / (wanted - 1) : Int.max
                }
            }
            return Plan(indices: indices, breakBefore: breaks, medianStep: med)
        }

        // Candidate source IDs come from a bounded document-wide sample. A full
        // scan then finds their true first/last/member counts without retaining
        // metadata for every waypoint in a very large document.
        var sources: [Source] = [], slots: [UInt32: Int] = [:]
        let candidates = min(n, pointBudget)
        for j in 0..<candidates {
            let i = candidates == 1 ? 0 : j * (n - 1) / (candidates - 1)
            let id = segmentID[i]
            if slots[id] == nil {
                slots[id] = sources.count
                sources.append(Source(id: id, count: 0, first: Int.max, last: -1))
            }
        }
        var distances: [Double] = []
        distances.reserveCapacity(4096)
        var edgeOrdinal = 0
        for i in 0..<n {
            guard let k = slots[segmentID[i]] else { continue }
            if sources[k].count > 0 {
                if edgeOrdinal % sampleEvery == 0 {
                    distances.append(distance(sources[k].last, i, lat: lat, lon: lon))
                }
                edgeOrdinal += 1
            } else { sources[k].first = i }
            sources[k].count += 1; sources[k].last = i
        }
        sources.sort { $0.first < $1.first }
        slots = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($0.element.id, $0.offset) })
        let med = median(distances), jump = max(50 * med, 0.5)
        let minimumCost = sources.reduce(0) { $0 + min(2, $1.count) }
        var selected: [Int] = [], selectedSet = Set<Int>(), spent = 0
        func choose(_ k: Int) {
            let cost = min(2, sources[k].count)
            guard !selectedSet.contains(k), spent + cost <= pointBudget else { return }
            selectedSet.insert(k); selected.append(k); spent += cost
        }
        // Original input endpoints retain their marker meaning even after source grouping.
        choose(0); choose(slots[segmentID[n - 1]]!)
        if minimumCost <= pointBudget {
            for k in sources.indices { choose(k) }
        } else {
            // Spread a conservative number of sources across the document, then use
            // spare slots for omitted short sources. No partially retained multi-point source.
            let picks = min(sources.count, max(1, (pointBudget - spent) / 2))
            for j in 0..<picks {
                choose(picks == 1 ? sources.count / 2 : j * (sources.count - 1) / (picks - 1))
            }
            for k in sources.indices { choose(k) }
        }
        selected.sort()
        var quotas = selected.map { min(2, sources[$0].count) }
        let available = selected.reduce(0) { $0 + sources[$1].count } - spent
        let extra = min(pointBudget - spent, available)
        if extra > 0 {
            var cumulative = 0, assigned = 0
            for k in selected.indices {
                cumulative += sources[selected[k]].count - quotas[k]
                let target = extra * cumulative / available
                quotas[k] += target - assigned; assigned = target
            }
        }
        var selectedSlots: [UInt32: Int] = [:]
        var buckets = [[Int]](repeating: [], count: selected.count)
        var breakBuckets = [[Bool]](repeating: [], count: selected.count)
        for k in selected.indices {
            selectedSlots[sources[selected[k]].id] = k
            buckets[k].reserveCapacity(quotas[k]); breakBuckets[k].reserveCapacity(quotas[k])
        }
        var seen = [Int](repeating: 0, count: selected.count)
        var nextRank = seen
        var previous = [Int](repeating: -1, count: selected.count)
        var pending = [Bool](repeating: false, count: selected.count)
        for i in 0..<n {
            guard let k = selectedSlots[segmentID[i]] else { continue }
            if previous[k] >= 0, distance(previous[k], i, lat: lat, lon: lon) > jump { pending[k] = true }
            if seen[k] == nextRank[k] {
                let emitted = buckets[k].count
                buckets[k].append(i); breakBuckets[k].append(emitted == 0 || pending[k])
                pending[k] = false
                let emittedNow = emitted + 1
                nextRank[k] = emittedNow < quotas[k]
                    ? emittedNow * (sources[selected[k]].count - 1) / (quotas[k] - 1) : Int.max
            }
            previous[k] = i; seen[k] += 1
        }
        var indices: [Int] = [], breaks: [Bool] = []
        indices.reserveCapacity(pointBudget); breaks.reserveCapacity(pointBudget)
        for k in selected.indices {
            assert(buckets[k].count == quotas[k])
            indices.append(contentsOf: buckets[k]); breaks.append(contentsOf: breakBuckets[k])
        }
        assert(indices.count <= pointBudget)
        return Plan(indices: indices, breakBefore: breaks, medianStep: med)
    }
}

/// 轨迹几何（从 lat/lon 一次性预处理），可画进任意当前上下文
struct GPXTrackShape {
    private let scaledPts: [CGPoint]
    private let breaks: [Bool]
    private let bounds2D: CGRect
    private let startMarkerIndex: Int
    private let endMarkerIndex: Int

    var isEmpty: Bool { scaledPts.isEmpty }
    /// Number of actual strokes after explicit/soft breaks (also used by offline geometry regression).
    var connectedEdgeCount: Int { breaks.reduce(0) { $0 + ($1 ? 0 : 1) } }

    init(lat: [Double], lon: [Double], segmentID: [UInt32] = []) {
        let plan = GPXPreviewSampling.plan(lat: lat, lon: lon, segmentID: segmentID)
        let n = min(lat.count, lon.count)
        guard !plan.indices.isEmpty else {
            scaledPts = []; breaks = []; bounds2D = .zero
            startMarkerIndex = 0; endMarkerIndex = 0
            return
        }
        var out: [CGPoint] = []
        out.reserveCapacity(plan.indices.count)
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for i in plan.indices {
            let x = CGFloat(lon[i]), y = CGFloat(lat[i])
            out.append(CGPoint(x: x, y: y))
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        breaks = Array(plan.breakBefore.dropFirst())
        startMarkerIndex = plan.indices.firstIndex(of: 0)!
        endMarkerIndex = plan.indices.firstIndex(of: n - 1)!

        // 纬度畸变补偿：经度按中纬 cos 压缩，形状接近真实比例
        let midLat = Double(minY + maxY) / 2 * .pi / 180
        let cosMid = CGFloat(max(0.2, cos(midLat)))
        var b = CGRect(x: minX * cosMid, y: minY,
                       width: max((maxX - minX) * cosMid, 1e-6),
                       height: max(maxY - minY, 1e-6))
        if b.width < 1e-5 { b = b.insetBy(dx: -5e-6, dy: 0) }
        if b.height < 1e-5 { b = b.insetBy(dx: 0, dy: -5e-6) }
        bounds2D = b
        var scaled = out
        for j in 0..<scaled.count { scaled[j].x *= cosMid }
        scaledPts = scaled
    }

    /// 画进当前 NSGraphicsContext（rect 内等比适配居中）
    func draw(in rect: CGRect, lineWidth: CGFloat, dotRadius: CGFloat) {
        guard !scaledPts.isEmpty, rect.width > 4, rect.height > 4 else { return }
        let sx = rect.width / bounds2D.width
        let sy = rect.height / bounds2D.height
        let s = min(sx, sy)
        let offX = rect.minX + (rect.width - bounds2D.width * s) / 2
        let offY = rect.minY + (rect.height - bounds2D.height * s) / 2
        func mapPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(x: offX + (p.x - bounds2D.minX) * s,
                    y: offY + (p.y - bounds2D.minY) * s)
        }

        func freshPath() -> NSBezierPath {
            let p = NSBezierPath()
            p.lineWidth = lineWidth
            p.lineJoinStyle = .round
            p.lineCapStyle = .round
            return p
        }
        NSColor.systemBlue.setStroke()
        var path = freshPath()
        var penDown = false
        var segsInPath = 0
        for (j, p) in scaledPts.enumerated() {
            let v = mapPoint(p)
            if !penDown {
                path.move(to: v)
                penDown = true
            } else {
                path.line(to: v)
                segsInPath += 1
                if segsInPath >= 512 {          // 分块冲刷（不透明色下接缝不可见）
                    path.stroke()
                    path = freshPath()
                    path.move(to: v)
                    segsInPath = 0
                }
            }
            if j < breaks.count, breaks[j] { penDown = false }
        }
        if segsInPath > 0 { path.stroke() }

        // 起点绿 / 终点红
        func dot(_ p: CGPoint, _ color: NSColor) {
            let r = dotRadius
            let oval = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            color.setFill()
            NSBezierPath(ovalIn: oval).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: oval)
            ring.lineWidth = max(1, dotRadius * 0.3)
            ring.stroke()
        }
        // A move-only subpath has no stroke. Draw every retained isolated point,
        // including one created by a soft break, before applying original endpoint markers.
        for j in scaledPts.indices {
            let previousConnected = j > 0 && !breaks[j - 1]
            let nextConnected = j < breaks.count && !breaks[j]
            if !previousConnected && !nextConnected { dot(mapPoint(scaledPts[j]), .systemBlue) }
        }
        dot(mapPoint(scaledPts[startMarkerIndex]), .systemGreen)
        if endMarkerIndex != startMarkerIndex {
            dot(mapPoint(scaledPts[endMarkerIndex]), .systemRed)
        }
    }
}

/// 预览面板用的 NSView 外壳
final class GPXTrackShapeView: NSView {
    private let shape: GPXTrackShape

    init(lat: [Double], lon: [Double], segmentID: [UInt32] = []) {
        shape = GPXTrackShape(lat: lat, lon: lon, segmentID: segmentID)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        shape.draw(in: bounds.insetBy(dx: 24, dy: 24), lineWidth: 2, dotRadius: 5)
    }
}

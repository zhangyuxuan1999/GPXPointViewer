//
//  ChangeLog.swift
//  GPXPointViewer
//
//  单文件模式下本次会话对轨迹的修改记录（补点落地的每一处断档、每一次圈选删除），
//  以及按记录还原的纯函数。无 UI 依赖（离线 harness 也能编）。
//
//  还原身份使用四列完整位键与多重集；全还原恢复会话精确基线。
//  没有稳定点/事务ID时，对依赖或顺序不明的部分还原安全拒绝。
//

import Foundation
import CoreLocation

struct ChangePoint: Equatable {
    var lat: Double
    var lon: Double
    var ele: Double           // NaN = 无海拔
    var time: Double          // NaN = 无时间
    var originalIndex: Int    // 记录当时在轨迹里的下标（无时间戳的轨迹插回时用；合成点为 -1）
    var segment: UInt32 = 0
    var key: GapFillExport.PointKey { GapFillExport.PointKey(time, lat, lon, segment: segment) }
}

/// 一处修改：补点落地的一处断档（新增合成点 + 可能替换掉的区间内点），或一次圈选删除
struct TrackChange: Identifiable {
    enum Kind: String { case fill, deletion, replay }   // replay = 一键清理回放点（也是删除，单独标出来）
    var id = UUID()                  // 落地前审阅的预览项用固定 id（随批量项），翻页/地名缓存才稳定
    let kind: Kind
    let date: Date                   // 操作时刻
    let added: [ChangePoint]         // 新增（合成）点
    let removed: [ChangePoint]       // 删掉的原始点（删除；补点「替换」掉的区间内点）
    let anchors: [ChangePoint]       // 补点两端 A/B（画范围、取地名用）；删除为空
    let fillID: UUID?                // 对应的 GapFill 记录（还原时从导出清单里摘掉）
    var reverted = false
    var revertedDate: Date?
    /// 路网证据（落地后可回查）：采用的草稿在前、另一路在后；比对结果；采用的来源（nil = 纯手动 / 直线）
    var drafts: [RouteDraft] = []
    var cross: RouteCrossCheck.Result? = nil
    var routeSource: RouteSource? = nil
    var straight = false             // 用直线补的
    /// 落地前审阅（预览模式）：对应的批量项 id；previewIncluded = 当前是否勾选落地
    var previewItemID: GapID? = nil
    var previewIncluded = true
    /// 精确模式待选项（预览里显示「等你选」）：还没做决定的；declined = 已选「都不补」；unverified = 只有一路有结果
    var previewPending = false
    var previewDeclined = false
    var previewUnverified = false
    /// 断档原始两端（草稿没外推时另一路折线从这里起画；与 RouteCrossCheck.polyline 口径一致）
    var originalA: CLLocationCoordinate2D? = nil
    var originalB: CLLocationCoordinate2D? = nil
    /// 内容指纹（预览项：来源 / 直线 / 首尾点 / 删点数）：id 固定不变，靠它触发合成轨迹重建
    var contentKey = ""
    /// 改时间的过时出口点（StaleRetime）：added 里含它们的新点、removed 里含对应旧点（还原按值照常）；
    /// 计数/显示时两边都扣掉——它们不是新增也不是删除。retimedKeys = 新点的键
    var retimed = 0
    var retimedKeys: Set<GapFillExport.PointKey> = []
    var retimedOldKeys: Set<GapFillExport.PointKey> = []   // 对应旧点（旧时间）的键：审阅图按完整键认，不按坐标猜
    /// 落地前自检结果（随 GapFill 记录进来；详细页可显示风险与原因）
    var plausibility: FillPlausibility? = nil
    /// 净新增（不含改时点）/ 真删掉（不含改时点的旧点）
    var netAdded: Int { max(0, added.count - retimed) }
    var netRemoved: Int { max(0, removed.count - retimed) }

    var title: String {
        switch kind {
        case .fill: return String(localized: "补点", comment: "Change Log: kind tag of a change – a gap fill that was applied")
        case .deletion: return String(localized: "changeKind.deletion", defaultValue: "删除", comment: "Change Log: kind tag of a change – points removed by a lasso deletion (noun, e.g. “Deletion”; not the Delete button)")
        case .replay: return String(localized: "回放点清理", comment: "Change Log: kind tag of a change – replay points cleaned up")
        }
    }
    var summary: String {
        var parts: [String] = []
        let nAdded = netAdded, nRemoved = netRemoved, nRetimed = retimed
        if nAdded > 0 { parts.append(String(localized: "+\(nAdded) 点", comment: "Change Log: number of points this change added (shown as e.g. “+12 points”)")) }
        if nRemoved > 0 { parts.append(String(localized: "−\(nRemoved) 点", comment: "Change Log: number of points this change removed; the leading sign is U+2212 MINUS SIGN (shown as e.g. “−3 points”)")) }
        var text = parts.joined(separator: " ")
        if nRetimed > 0 {
            let r = String(localized: "改时间 \(nRetimed) 点", comment: "Change Log: number of existing points whose position was kept and only the timestamp was corrected (stale-clock exit points after a tunnel); shown after “+N points”, e.g. “+7 points · retimed 1 point”")
            text = text.isEmpty ? r : text + " · " + r
        }
        return text
    }
    /// 修改落在轨迹的哪个时刻（排序、显示用）：锚点 A 的时间，否则删掉的首点，否则新增首点
    var trackTime: Double? {
        let t = anchors.first?.time ?? removed.first(where: { $0.time.isFinite })?.time ?? added.first?.time
        return (t?.isFinite ?? false) ? t : nil
    }
    private var allPoints: [ChangePoint] { added + removed + anchors }
    var bbox: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        var b = (minLat: 90.0, maxLat: -90.0, minLon: 180.0, maxLon: -180.0)
        for p in allPoints {
            b.minLat = min(b.minLat, p.lat); b.maxLat = max(b.maxLat, p.lat)
            b.minLon = min(b.minLon, p.lon); b.maxLon = max(b.maxLon, p.lon)
        }
        return b
    }
    var center: CLLocationCoordinate2D {
        let b = bbox
        return CLLocationCoordinate2D(latitude: (b.minLat + b.maxLat) / 2, longitude: (b.minLon + b.maxLon) / 2)
    }
    /// 范围对角线（米），详细页取景的最小尺度用
    var spanMeters: Double {
        let b = bbox
        return GeoMath.haversine(b.minLat, b.minLon, b.maxLat, b.maxLon)
    }
}

enum ChangeRevert {
    /// Revert identity deliberately includes elevation and exact NaN bits;
    /// it does not change the incremental export PointKey contract.
    struct PointBits: Hashable {
        let lat, lon, ele, time: UInt64
        let segment: UInt32
        init(_ p: ChangePoint) {
            segment = p.segment
            lat = p.lat.bitPattern; lon = p.lon.bitPattern
            ele = p.ele.bitPattern; time = p.time.bitPattern
        }
    }
    enum Conflict: String, Error {
        case missingBaseline, laterDependency, missingOccurrence, untimedInsertion, ambiguousOrder
    }

    static func snapshot(_ current: TrackData) -> ParsedTrack {
        var p = ParsedTrack()
        p.lat = current.lat; p.lon = current.lon; p.ele = current.ele; p.time = current.time
        p.fileID = current.fileID; p.segmentID = current.segmentID
        p.name = current.name; p.creator = current.creator; p.accuracyMedian = current.gpsAccuracy
        p.chunkCount = ProcessInfo.processInfo.activeProcessorCount
        return p
    }

    /// Plans only. Callers commit track, files, fills and flags together after
    /// checking the original document publication owner. No approximate insertion.
    static func apply(to current: TrackData, changes selected: [TrackChange],
                      history: [TrackChange]? = nil,
                      baseline: ParsedTrack? = nil) -> Result<ParsedTrack, Conflict> {
        let targets = selected.filter { !$0.reverted }
        let ids = Set(targets.map(\.id))
        let active = (history ?? targets).filter { !$0.reverted }
        if history != nil, ids == Set(active.map(\.id)), !ids.isEmpty {
            guard let baseline else { return .failure(.missingBaseline) }
            return .success(baseline)  // exact session sequence, duplicates and missing times included
        }
        let touched = Set(targets.flatMap { $0.added + $0.removed }.map(PointBits.init))
        if let first = active.firstIndex(where: { ids.contains($0.id) }) {
            for c in active.dropFirst(first + 1) where !ids.contains(c.id) {
                if (c.added + c.removed + c.anchors).contains(where: { touched.contains(PointBits($0)) }) {
                    return .failure(.laterDependency)
                }
            }
        }
        var balance: [PointBits: Int] = [:]
        var candidates: [PointBits: ChangePoint] = [:]
        for c in targets {
            for p in c.removed {
                let key = PointBits(p); balance[key, default: 0] += 1; candidates[key] = p
            }
            for p in c.added { balance[PointBits(p), default: 0] -= 1 }
        }
        var toDrop = balance.filter { $0.value < 0 }.mapValues { -$0 }
        var kept: [Int] = []
        kept.reserveCapacity(current.count)
        for i in 0..<current.count {
            let q = ChangePoint(lat: current.lat[i], lon: current.lon[i], ele: current.ele[i],
                                time: current.time[i], originalIndex: i, segment: current.topology.segment(of: i))
            let key = PointBits(q)
            if let count = toDrop[key], count > 0 { toDrop[key] = count - 1 }
            else { kept.append(i) }
        }
        guard !toDrop.values.contains(where: { $0 > 0 }) else { return .failure(.missingOccurrence) }
        var inserted: [ChangePoint] = []
        for (key, count) in balance where count > 0 {
            guard let q = candidates[key], q.time.isFinite else { return .failure(.untimedInsertion) }
            inserted += Array(repeating: q, count: count)
        }
        // Existing records have no stable instance/order IDs. Equal-time points
        // with different bits cannot be positioned safely from originalIndex.
        var atTime: [UInt64: PointBits] = [:]
        var ambiguousTimes = Set<UInt64>()
        for i in kept where current.time[i].isFinite {
            let q = ChangePoint(lat: current.lat[i], lon: current.lon[i], ele: current.ele[i],
                                time: current.time[i], originalIndex: i, segment: current.topology.segment(of: i))
            let t: UInt64 = q.time == 0 ? 0 : q.time.bitPattern
            if let existing = atTime[t], existing != PointBits(q) { ambiguousTimes.insert(t) }
            else { atTime[t] = PointBits(q) }
        }
        for q in inserted {
            let key = PointBits(q), t: UInt64 = q.time == 0 ? 0 : q.time.bitPattern
            if ambiguousTimes.contains(t) { return .failure(.ambiguousOrder) }
            if let existing = atTime[t], existing != key { return .failure(.ambiguousOrder) }
            atTime[t] = key
        }
        inserted.sort { $0.time < $1.time }
        var p = snapshot(current)
        p.lat = []; p.lon = []; p.ele = []; p.time = []; p.fileID = []; p.segmentID = []
        let hasFiles = current.fileID.count == current.count
        func append(_ q: ChangePoint, file: UInt16 = 0) {
            p.lat.append(q.lat); p.lon.append(q.lon); p.ele.append(q.ele); p.time.append(q.time)
            if hasFiles { p.fileID.append(file) }
            p.segmentID.append(q.segment)
        }
        var j = 0
        for i in kept {
            while j < inserted.count && (!current.time[i].isFinite || inserted[j].time <= current.time[i]) {
                append(inserted[j]); j += 1
            }
            append(ChangePoint(lat: current.lat[i], lon: current.lon[i], ele: current.ele[i],
                               time: current.time[i], originalIndex: i, segment: current.topology.segment(of: i)), file: hasFiles ? current.fileID[i] : 0)
        }
        while j < inserted.count { append(inserted[j]); j += 1 }
        return .success(p)
    }

    /// 落地前预览的合成轨迹：当前轨迹（将被替换的点标红 2）+ 各处将新增的合成点（绿 1，追加在尾部，build 按时间重排）。
    /// 与 reviewParsed 的区别：新增点还不在轨迹里、删除点还在轨迹里
    static func previewParsed(current: TrackData, changes: [TrackChange]) -> ParsedTrack {
        var removedKeys = Set<GapFillExport.PointKey>()
        var retimedKeys = Set<GapFillExport.PointKey>(), retimedOld = Set<GapFillExport.PointKey>()
        var added: [ChangePoint] = []
        for c in changes where !c.reverted {
            for p in c.removed { removedKeys.insert(p.key) }
            added += c.added
            retimedKeys.formUnion(c.retimedKeys); retimedOld.formUnion(c.retimedOldKeys)
        }
        // 改时点的旧点与新点同坐标：旧点（按完整键认，同坐标的别的被删点照常标红）不标红、隐藏，只画新点（橙 3）
        let n = current.count
        var p = ParsedTrack()
        p.lat = current.lat; p.lon = current.lon; p.ele = current.ele; p.time = current.time
        p.segmentID = (0..<current.count).map { current.topology.segment(of: $0) }
        var fid = [UInt16](repeating: 0, count: n + added.count)
        var hide: [Int] = []
        if !removedKeys.isEmpty {
            for i in 0..<n {
                let k = GapFillExport.PointKey(current.time[i], current.lat[i], current.lon[i], segment: current.topology.segment(of: i))
                guard removedKeys.contains(k) else { continue }
                if retimedOld.contains(k) { hide.append(i) } else { fid[i] = 2 }
            }
        }
        for (k, q) in added.enumerated() {
            p.lat.append(q.lat); p.lon.append(q.lon); p.ele.append(q.ele); p.time.append(q.time); p.segmentID.append(q.segment)
            fid[n + k] = retimedKeys.contains(q.key) ? 3 : 1
        }
        if !hide.isEmpty {
            let drop = Set(hide)
            var keepIdx: [Int] = []; keepIdx.reserveCapacity(p.lat.count - drop.count)
            for i in 0..<p.lat.count where !drop.contains(i) { keepIdx.append(i) }
            p.lat = keepIdx.map { p.lat[$0] }; p.lon = keepIdx.map { p.lon[$0] }
            p.ele = keepIdx.map { p.ele[$0] }; p.time = keepIdx.map { p.time[$0] }; p.segmentID = keepIdx.map { p.segmentID[$0] }
            fid = keepIdx.map { fid[$0] }
        }
        p.fileID = fid
        p.name = String(localized: "落地前预览", comment: "Name of the synthesized track drawn in the Change Log window's pre-apply preview mode")
        p.chunkCount = ProcessInfo.processInfo.activeProcessorCount
        return p
    }

    /// 审阅用合成轨迹：当前轨迹全部点 + 各处修改删掉的点；fileID 0 = 轨迹（蓝）、1 = 新增（绿）、2 = 删除（红）、3 = 改时间（橙）。
    /// 删掉的点追加在尾部，build 会按时间重排并同步搬 fileID
    static func reviewParsed(current: TrackData, changes: [TrackChange]) -> ParsedTrack {
        var addedKeys = Set<GapFillExport.PointKey>()
        var retimedKeys = Set<GapFillExport.PointKey>(), retimedOld = Set<GapFillExport.PointKey>()
        var removed: [ChangePoint] = []
        for c in changes where !c.reverted {
            for p in c.added { addedKeys.insert(p.key) }
            retimedKeys.formUnion(c.retimedKeys); retimedOld.formUnion(c.retimedOldKeys)
            removed += c.removed
        }
        // 改时点：新点橙（3）；对应旧点（按完整键认）不再画红
        if !retimedOld.isEmpty { removed.removeAll { retimedOld.contains($0.key) } }
        let n = current.count
        var p = ParsedTrack()
        p.lat = current.lat; p.lon = current.lon; p.ele = current.ele; p.time = current.time
        p.segmentID = (0..<current.count).map { current.topology.segment(of: $0) }
        var fid = [UInt16](repeating: 0, count: n + removed.count)
        if !addedKeys.isEmpty {
            for i in 0..<n {
                let k = GapFillExport.PointKey(current.time[i], current.lat[i], current.lon[i], segment: current.topology.segment(of: i))
                if addedKeys.contains(k) { fid[i] = retimedKeys.contains(k) ? 3 : 1 }
            }
        }
        for (k, q) in removed.enumerated() {
            p.lat.append(q.lat); p.lon.append(q.lon); p.ele.append(q.ele); p.time.append(q.time); p.segmentID.append(q.segment)
            fid[n + k] = 2
        }
        p.fileID = fid
        p.name = String(localized: "修改记录", comment: "Name of the synthesized track drawn in the Change Log window (same term as the Change Log window title)")
        p.chunkCount = ProcessInfo.processInfo.activeProcessorCount
        return p
    }
}


/// One document revision, separate owners for derived views. TrackStore owns
/// this value on MainActor; pure deterministic tests can complete tokens in any order.
enum PublicationLane: Hashable, Sendable { case data, compareDiff, review, fogStats, playback, fogArchive, regions, summary, candidates, tripMap, batchResolve, batchRouting
    case batchRefetch(GapID)
}
struct DataPublicationToken: Equatable, Sendable {
    let lane: PublicationLane
    let owner: UUID
    let revision: UInt64
    let fileIDs: [UUID]
    let sourceID: UUID?
}
struct DataPublicationClock {
    private(set) var revision: UInt64 = 0
    private var owners: [PublicationLane: UUID] = [:]
    mutating func invalidate() { revision &+= 1; owners.removeAll() }
    mutating func cancel(_ lane: PublicationLane) { owners[lane] = nil }
    mutating func begin(_ lane: PublicationLane = .data, fileIDs: [UUID], sourceID: UUID? = nil) -> DataPublicationToken {
        let owner = UUID(); owners[lane] = owner
        return DataPublicationToken(lane: lane, owner: owner, revision: revision, fileIDs: fileIDs, sourceID: sourceID)
    }
    func accepts(_ token: DataPublicationToken, fileIDs: [UUID], sourceID: UUID?) -> Bool {
        token.revision == revision && owners[token.lane] == token.owner && token.fileIDs == fileIDs &&
        (token.sourceID == nil || token.sourceID == sourceID)
    }
}

import Foundation

/// Business identity is a Gregorian civil day, never a fixed 86,400 second span.
struct SummaryCalendarDay: Equatable, Hashable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }
    init(date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }
    func interval(in identifier: String) -> DateInterval? {
        guard (1...9999).contains(year), let zone = TimeZone(identifier: identifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        // Noon also handles zones whose midnight is skipped. A completely skipped
        // civil day and invalid Y/M/D fail the round-trip instead of normalizing.
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
              SummaryCalendarDay(date: date, timeZone: zone) == self,
              let interval = calendar.dateInterval(of: .day, for: date),
              SummaryCalendarDay(date: interval.start, timeZone: zone) == self else { return nil }
        return interval
    }
    var isoDescription: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

enum SummaryDateHint: String, Sendable {
    case chooseDate, year, month, multipleDays, invalidDay
    var message: String {
        switch self {
        case .chooseDate: return String(localized: "请选择日期后查看摘要。")
        case .year: return String(localized: "已选择年份，请选择具体日期。")
        case .month: return String(localized: "已选择月份，请选择具体日期。")
        case .multipleDays: return String(localized: "当前范围包含多日，请选择其中一天。")
        case .invalidDay: return String(localized: "该年月日在所选时区中不可用，请输入有效日期。")
        }
    }
}

enum SummaryEntryRequest {
    case day(SummaryCalendarDay, timeZoneIdentifier: String)
    case chooseDate(seed: SummaryCalendarDay?, timeZoneIdentifier: String?, hint: SummaryDateHint)

    /// Read intent first, then validate it against the actual effective interval.
    /// The duration alone can never turn a journey or stale range into a day.
    static func mainFilter(spec: ViewFilterSpec?, range: (start: Double, end: Double)?) -> Self {
        guard let spec, let range, let expected = spec.summaryRange(),
              expected.start == range.start, expected.end == range.end else {
            return .chooseDate(seed: nil, timeZoneIdentifier: nil, hint: .chooseDate)
        }
        let zone = spec.calendar.timeZone
        let seed = SummaryCalendarDay(date: Date(timeIntervalSince1970: expected.start), timeZone: zone)
        let single = spec.mode == .day || (spec.mode == .custom
            && spec.startY == spec.endY && spec.startM == spec.endM && spec.startD == spec.endD)
        if single, let interval = seed.interval(in: zone.identifier),
           interval.start.timeIntervalSince1970 == range.start, interval.end.timeIntervalSince1970 == range.end {
            return .day(seed, timeZoneIdentifier: zone.identifier)
        }
        let hint: SummaryDateHint = spec.mode == .year ? .year : (spec.mode == .month ? .month : .multipleDays)
        return .chooseDate(seed: seed, timeZoneIdentifier: zone.identifier, hint: hint)
    }
}

struct SummaryDateNavigation {
    var revision: UInt64 = 0
    var selectedDay: SummaryCalendarDay?
    var draftDay = SummaryCalendarDay(date: Date(), timeZone: .current)
    var draftEdited = false
    var hint: SummaryDateHint? = .chooseDate
    var selectedJourneyID: String?
    var fromMainRange = false
}

struct SummaryNavigationIndex: Sendable {
    let sourceID: UUID
    let trackID: UUID
    let timeZoneIdentifier: String
    let dayRowByStart: [Double: Int]
    let journeyRowsByDayStart: [Double: [Int]]

    init(report: SummaryReport, isCancelled: () -> Bool = { Task.isCancelled }) throws {
        sourceID = report.sourceID; trackID = report.trackID; timeZoneIdentifier = report.timeZoneIdentifier
        var days: [Double: Int] = [:], journeys: [Double: [Int]] = [:]
        for (i, row) in report.days.enumerated() {
            if i & 1023 == 0, isCancelled() { throw SummaryBuildError.cancelled }
            if let start = row.dayStart { days[start] = i }
        }
        for (j, journey) in report.journeys.enumerated() {
            if isCancelled() { throw SummaryBuildError.cancelled }
            var low = 0, high = report.days.count
            while low < high {
                let mid = (low + high) / 2
                if (report.days[mid].dayEnd ?? -.infinity) <= journey.startTime { low = mid + 1 }
                else { high = mid }
            }
            var i = low
            while i < report.days.count, let start = report.days[i].dayStart, start <= journey.endTime {
                if i & 1023 == 0, isCancelled() { throw SummaryBuildError.cancelled }
                if journey.startTime < (report.days[i].dayEnd ?? -.infinity) { journeys[start, default: []].append(j) }
                i += 1
            }
        }
        dayRowByStart = days; journeyRowsByDayStart = journeys
    }
    func belongs(to report: SummaryReport) -> Bool {
        sourceID == report.sourceID && trackID == report.trackID && timeZoneIdentifier == report.timeZoneIdentifier
    }
}

struct SummaryNavigationPublication: Sendable {
    let report: SummaryReport
    let index: SummaryNavigationIndex
}

enum SummaryTimeZoneChoice: Equatable {
    case system, utc, named(String)

    var identifier: String? {
        switch self {
        case .system: return TimeZone.current.identifier
        case .utc: return "UTC"
        case .named(let name): return TimeZone(identifier: name)?.identifier
        }
    }
}

struct SummaryFilterSelection: Equatable {
    let trackID: UUID
    let sourceID: UUID
    let rowID: String
    let start: Double
    let end: Double
    let timeZoneIdentifier: String
}

struct SummarySourceOption: Identifiable {
    let id: UUID
    let name: String
}

struct SummaryCacheKey: Equatable {
    let revision: UInt64
    let mode: String
    let sourceID: UUID
    let trackID: UUID
    let timeZone: String
    let provenanceRevision: UInt64
    let regionIdentity: ObjectIdentifier?
    let rules = JourneySummaryBuilder.ruleVersion
}

/// Only immutable geometry arrays and value records cross into the worker. Array
/// assignments retain CoW storage; construction never scans the point columns.
struct SummaryWorkSnapshot: @unchecked Sendable {
    let sourceID: UUID
    let trackID: UUID
    let name: String
    let zone: String
    let lat, lon, elevation, time: [Double]
    let fileID: [UInt16]
    let selectedFileID: UInt16?
    let order: [UInt32]
    let segments: [SummarySegment]
    let fills: [GapFill]

    init(track: TrackData, sourceID: UUID, name: String, zone: String,
         selectedFileID: UInt16?, fills: [GapFill]) {
        self.sourceID = sourceID; trackID = track.id; self.name = name; self.zone = zone
        lat = track.lat; lon = track.lon; elevation = track.ele; time = track.time
        fileID = track.fileID; self.selectedFileID = selectedFileID; order = track.topology.order
        segments = track.topology.segments.map { SummarySegment(id: $0.id, pathRange: $0.range) }
        self.fills = fills
    }

    /// Called on the worker, including the potentially large provenance scan.
    func input() throws -> SummaryInput {
        var synthetic = Set<SummaryPointKey>(), retimed = Set<SummaryPointKey>()
        for fill in fills {
            for (offset, point) in fill.points.enumerated() {
                if offset & 4095 == 0, Task.isCancelled { throw SummaryBuildError.cancelled }
                let key = SummaryPointKey(time: point.time, lat: point.lat, lon: point.lon, segment: fill.segment)
                let old = GapFillExport.PointKey(point.time, point.lat, point.lon, segment: fill.segment)
                if fill.retimedKeys.contains(old) { retimed.insert(key) }
                else { synthetic.insert(key) }
            }
        }
        return SummaryInput(sourceID: sourceID, trackID: trackID, sourceName: name,
                            timeZoneIdentifier: zone, lat: lat, lon: lon, elevation: elevation,
                            time: time, fileID: fileID, selectedFileID: selectedFileID,
                            pathOrder: order, segments: segments, syntheticKeys: synthetic, retimedKeys: retimed)
    }
}

extension SummaryTransportMode {
    var summaryTitle: String {
        switch self {
        case .unknown: return String(localized: "未知", comment: "Summary transport mode")
        case .walking: return String(localized: "步行", comment: "Summary transport mode")
        case .cycling: return String(localized: "骑行", comment: "Summary transport mode")
        case .road: return String(localized: "公路", comment: "Summary transport mode")
        case .rail: return String(localized: "铁路", comment: "Summary transport mode")
        case .air: return String(localized: "航空", comment: "Summary transport mode")
        case .water: return String(localized: "水路", comment: "Summary transport mode")
        }
    }
}

enum SummaryDisplay {
    static func time(_ value: Double, zone: String, dateOnly: Bool = false) -> String {
        guard value.isFinite else { return "—" }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = .autoupdatingCurrent; f.timeZone = TimeZone(identifier: zone)
        f.dateStyle = .medium; f.timeStyle = dateOnly ? .none : .medium
        return f.string(from: Date(timeIntervalSince1970: value))
    }
    static func distance(_ meters: Double) -> String {
        (meters / 1000).formatted(.number.precision(.fractionLength(2))) + " km"
    }
    static func duration(_ seconds: Double) -> String {
        let f = DateComponentsFormatter(); f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated; f.maximumUnitCount = 3
        return f.string(from: max(0, seconds)) ?? "—"
    }
}

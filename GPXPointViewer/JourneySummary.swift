import Foundation

struct SummaryPointKey: Hashable, Sendable {
    let timeBits: UInt64
    let latBits: UInt64
    let lonBits: UInt64
    let segment: UInt32
    init(time: Double, lat: Double, lon: Double, segment: UInt32) {
        self.timeBits = time.bitPattern
        self.latBits = lat.bitPattern
        self.lonBits = lon.bitPattern
        self.segment = segment
    }
}
struct SummarySegment: Sendable {
    let id: UInt32
    let pathRange: Range<Int>       // indexes into pathOrder; identity if empty
}
struct SummaryInput: Sendable {
    let sourceID: UUID
    let trackID: UUID
    let sourceName: String
    let timeZoneIdentifier: String
    let lat: [Double]
    let lon: [Double]
    let elevation: [Double]
    let time: [Double]
    let fileID: [UInt16]            // empty means implicit file zero
    let selectedFileID: UInt16?     // nil means all points in this snapshot
    let pathOrder: [UInt32]         // empty means identity
    let segments: [SummarySegment]
    let syntheticKeys: Set<SummaryPointKey>
    let retimedKeys: Set<SummaryPointKey>
}
struct SummaryBounds: Equatable, Sendable {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double
    // UI skips camera flight if maxLon-minLon > 180; time selection still works.
}
struct SummaryMetrics: Equatable, Sendable {
    let pointCount: Int
    let syntheticPointCount: Int
    let retimedPointCount: Int      // excludes points already counted synthetic
    let acceptedEdgeCount: Int
    let excludedEdgeCount: Int
    let recordedMeters: Double
    let estimatedMeters: Double
    let elapsedSeconds: Double
    let observedSeconds: Double
    let estimatedSeconds: Double
    let movingSeconds: Double
    let lowMotionSeconds: Double
    let unknownSeconds: Double
    let overlapSeconds: Double
    let elevationEligibleEdges: Int
    let elevationCoveredEdges: Int
    let ascentMeters: Double?
    let descentMeters: Double?
}
struct SummaryGeography: Equatable, Sendable {
    let available: Bool
    let recordedRegionIDs: [UInt16] // unique, sorted; includes ancestor IDs
    let estimatedRegionIDs: [UInt16]
    let unassignedRecordedPoints: Int
    let unassignedSyntheticPoints: Int
}
enum SummaryTransportMode: String, CaseIterable, Equatable, Sendable {
    case unknown, walking, cycling, road, rail, air, water
}
struct SummaryTransportEvidence: Equatable, Sendable {
    let candidates: [SummaryTransportMode] // empty = insufficient evidence
    let observedMovingSeconds: Double
    let observedMovingEdgeCount: Int
}
enum SummaryRowKind: String, Equatable, Sendable { case day, journey }
struct SummaryRow: Identifiable, Equatable, Sendable {
    let id: String
    let kind: SummaryRowKind
    let sourceID: UUID
    let segment: UInt32?           // only journey rows
    let firstPathRank: Int?        // only journey rows
    let startTime: Double          // actual first contribution, Unix seconds
    let endTime: Double            // actual last contribution, inclusive instant
    let dayStart: Double?          // natural day [dayStart,dayEnd); nil for journey
    let dayEnd: Double?
    let bounds: SummaryBounds?
    let metrics: SummaryMetrics
    let geography: SummaryGeography
    let transport: SummaryTransportEvidence
    // Day filter: [dayStart,dayEnd). Journey filter: [startTime,endTime.nextUp).
}
struct SummaryReport: Sendable {
    let sourceID: UUID
    let trackID: UUID
    let sourceName: String
    let timeZoneIdentifier: String
    let ruleVersion: String        // exactly JourneySummaryBuilder.ruleVersion
    let totalPointCount: Int
    let undatedPointCount: Int
    let invalidCoordinatePointCount: Int
    let days: [SummaryRow]          // chronological; ID tie break
    let journeys: [SummaryRow]      // startTime, segment, firstPathRank order
}
enum SummaryBuildError: Error {
    case invalidInput(String)
    case invalidTimeZone(String)
    case cancelled
}
enum JourneySummaryBuilder {
    static let ruleVersion = "summary-v1"
    static func build(
        _ input: SummaryInput,
        regionIndex: RegionIndex?,
        isCancelled: () -> Bool = { false }
    ) throws -> SummaryReport {
        return try withoutActuallyEscaping(isCancelled) { callback in
            let worker = try SummaryWorker(input, regionIndex: regionIndex, isCancelled: callback)
            return try worker.build()
        }
    }
}

// All mutable objects below belong to one synchronous build invocation. No worker
// object, assigner, interval buffer, or mutable collection escapes in the report.
private struct SummaryInterval {
    var start: Double
    var end: Double
}

private struct SummaryDay {
    let start: Double
    let end: Double
}

private final class SummaryAccumulator {
    let id: String
    let kind: SummaryRowKind
    let segment: UInt32?
    let firstPathRank: Int?
    let day: SummaryDay?
    var start = Double.infinity
    var end = -Double.infinity
    var minLat = Double.infinity
    var maxLat = -Double.infinity
    var minLon = Double.infinity
    var maxLon = -Double.infinity
    var points = 0
    var synthetic = 0
    var retimed = 0
    var accepted = 0
    var excluded = 0
    var recordedMeters = 0.0
    var estimatedMeters = 0.0
    var elevationEligible = 0
    var elevationCovered = 0
    var ascent = 0.0
    var descent = 0.0
    var recordedRegions = Set<UInt16>()
    var estimatedRegions = Set<UInt16>()
    var unassignedRecorded = 0
    var unassignedSynthetic = 0
    var observed: [SummaryInterval] = []
    var estimated: [SummaryInterval] = []
    var moving: [SummaryInterval] = []
    var transportEdges = 0
    var transportWeight = 0.0
    var transportSlowWeight = 0.0
    var transportMediumWeight = 0.0

    init(id: String, kind: SummaryRowKind, segment: UInt32? = nil,
         firstPathRank: Int? = nil, day: SummaryDay? = nil) {
        self.id = id
        self.kind = kind
        self.segment = segment
        self.firstPathRank = firstPathRank
        self.day = day
    }

    func include(time: Double) {
        start = min(start, time)
        end = max(end, time)
    }

    func include(lat: Double, lon: Double) {
        minLat = min(minLat, lat)
        maxLat = max(maxLat, lat)
        minLon = min(minLon, lon)
        maxLon = max(maxLon, lon)
    }

    // Input is monotonic inside each source segment. Compaction here keeps long
    // continuous tracks small; final union also handles interleaved source spans.
    static func append(_ interval: SummaryInterval, to buffer: inout [SummaryInterval]) {
        if let last = buffer.last, interval.start >= last.start, interval.start <= last.end {
            buffer[buffer.count - 1].end = max(last.end, interval.end)
        } else {
            buffer.append(interval)
        }
    }

    func edge(start a: Double, end b: Double, meters: Double, estimatedPosition: Bool,
              estimatedTime: Bool, moving isMoving: Bool, kmh: Double,
              elevationEligible eligible: Bool, elevationCovered covered: Bool) {
        include(time: a)
        include(time: b)
        accepted += 1
        if estimatedPosition { estimatedMeters += meters } else { recordedMeters += meters }
        if eligible { elevationEligible += 1 }
        if covered { elevationCovered += 1 }
        let interval = SummaryInterval(start: a, end: b)
        if estimatedTime {
            Self.append(interval, to: &estimated)
        } else {
            Self.append(interval, to: &observed)
            if isMoving {
                Self.append(interval, to: &moving)
                transportEdges += 1
                transportWeight += b - a
                if kmh <= 12 { transportSlowWeight += b - a }
                if kmh <= 45 { transportMediumWeight += b - a }
            }
        }
    }
}

private struct SummarySample {
    let index: Int
    let rank: Int
    let file: UInt16
    let time: Double
    let day: SummaryDay?
    let validCoordinate: Bool
    let synthetic: Bool
    let retimed: Bool
}

private struct SummaryElevationNode {
    let time: Double
    let elevation: Double
    let incomingStart: Double?
    let journey: SummaryAccumulator
}

private final class SummaryWorker {
    private let input: SummaryInput
    private let index: RegionIndex?
    private let assigner: RegionIndex.Assigner?
    private let isCancelled: () -> Bool
    private var calendar: Calendar
    private var dayCache: SummaryDay?
    private var days: [Double: SummaryAccumulator] = [:]
    private var journeys: [SummaryAccumulator] = []
    private var segmentSpans: [SummaryInterval] = []
    private var totalPoints = 0
    private var undatedPoints = 0
    private var invalidCoordinates = 0
    // Five samples, including endpoint padding; never a whole-track altitude copy.
    private var elevationWindow: [SummaryElevationNode] = []
    private var elevationAnchor: Double?
    private var elevationLast: SummaryElevationNode?

    init(_ input: SummaryInput, regionIndex: RegionIndex?, isCancelled: @escaping () -> Bool) throws {
        self.input = input
        self.index = regionIndex.flatMap { $0.isEmpty ? nil : $0 }
        self.assigner = self.index.map(RegionIndex.Assigner.init)
        self.isCancelled = isCancelled
        guard TimeZone.knownTimeZoneIdentifiers.contains(input.timeZoneIdentifier) || input.timeZoneIdentifier == "UTC",
              let zone = TimeZone(identifier: input.timeZoneIdentifier) else {
            throw SummaryBuildError.invalidTimeZone(input.timeZoneIdentifier)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        self.calendar = calendar
    }

    private func checkCancellation() throws {
        if isCancelled() { throw SummaryBuildError.cancelled }
    }

    private func validate() throws {
        try checkCancellation()
        let n = input.lat.count
        guard input.lon.count == n, input.elevation.count == n, input.time.count == n,
              input.fileID.isEmpty || input.fileID.count == n,
              input.pathOrder.isEmpty || input.pathOrder.count == n else {
            throw SummaryBuildError.invalidInput("Summary columns and path order must have equal lengths")
        }
        // Compact permutation validation costs one bit per point instead of a
        // million-entry hash set. It detects repeated and missing array indices.
        if !input.pathOrder.isEmpty {
            var seen = [UInt64](repeating: 0, count: (n + 63) / 64)
            for (rank, value) in input.pathOrder.enumerated() {
                if rank & 4095 == 0 { try checkCancellation() }
                let i = Int(value)
                guard i < n else { throw SummaryBuildError.invalidInput("Path index out of range") }
                let mask = UInt64(1) << UInt64(i & 63)
                guard seen[i >> 6] & mask == 0 else {
                    throw SummaryBuildError.invalidInput("Path order is not a permutation")
                }
                seen[i >> 6] |= mask
            }
        }
        var next = 0
        var segmentIDs = Set<UInt32>()
        for (offset, segment) in input.segments.enumerated() {
            if offset & 4095 == 0 { try checkCancellation() }
            guard segment.pathRange.lowerBound == next,
                  segment.pathRange.upperBound > next,
                  segment.pathRange.upperBound <= n,
                  segmentIDs.insert(segment.id).inserted else {
                throw SummaryBuildError.invalidInput("Segments must uniquely and completely partition path order")
            }
            next = segment.pathRange.upperBound
        }
        guard next == n else { throw SummaryBuildError.invalidInput("Incomplete segment topology") }
    }

    private func day(for time: Double) -> SummaryDay? {
        // ICU's supported UDate domain is +/-100,000,000 days in milliseconds.
        // Guard before invoking Calendar: extreme finite Doubles are not dates.
        guard time.isFinite, abs(time) <= 8_640_000_000_000 else { return nil }
        if let cached = dayCache, time >= cached.start, time < cached.end { return cached }
        guard let interval = calendar.dateInterval(of: .day, for: Date(timeIntervalSince1970: time)) else { return nil }
        let start = interval.start.timeIntervalSince1970
        let end = interval.end.timeIntervalSince1970
        guard start.isFinite, end.isFinite, start <= time, end > time, end > start else { return nil }
        let result = SummaryDay(start: start, end: end)
        dayCache = result
        return result
    }

    private func dayRow(_ day: SummaryDay) -> SummaryAccumulator {
        if let row = days[day.start] { return row }
        let row = SummaryAccumulator(id: "\(input.trackID.uuidString):\(input.sourceID.uuidString):day:\(day.start.bitPattern)", kind: .day, day: day)
        days[day.start] = row
        return row
    }

    private func newJourney(segment: UInt32, rank: Int) -> SummaryAccumulator {
        let row = SummaryAccumulator(id: "\(input.trackID.uuidString):\(input.sourceID.uuidString):\(segment):\(rank)",
                                     kind: .journey, segment: segment, firstPathRank: rank)
        journeys.append(row)
        return row
    }

    private func point(_ sample: SummarySample, regionIDs: [UInt16], in row: SummaryAccumulator) {
        row.points += 1
        if sample.synthetic { row.synthetic += 1 } else if sample.retimed { row.retimed += 1 }
        row.include(time: sample.time)
        guard sample.validCoordinate else { return }
        row.include(lat: input.lat[sample.index], lon: input.lon[sample.index])
        guard index != nil else { return }
        if sample.synthetic {
            row.estimatedRegions.formUnion(regionIDs)
            if regionIDs.isEmpty { row.unassignedSynthetic += 1 }
        } else {
            row.recordedRegions.formUnion(regionIDs)
            if regionIDs.isEmpty { row.unassignedRecorded += 1 }
        }
    }

    private func distance(_ a: Int, _ b: Int) -> Double {
        let radians = Double.pi / 180
        let latA = input.lat[a] * radians
        let latB = input.lat[b] * radians
        let x = sin((latB - latA) / 2)
        let y = sin((input.lon[b] - input.lon[a]) * radians / 2)
        let h = min(1, max(0, x * x + cos(latA) * cos(latB) * y * y))
        return 6_371_000 * 2 * asin(sqrt(h))
    }

    private func forDayPieces(start: Double, end: Double,
                              _ body: (SummaryAccumulator, Double, Double, Double) -> Void) throws {
        var cursor = start
        while cursor < end {
            try checkCancellation()
            guard let day = day(for: cursor) else {
                throw SummaryBuildError.invalidInput("Accepted edge crosses an unrepresentable calendar day")
            }
            let finish = min(day.end, end)
            guard finish > cursor else { throw SummaryBuildError.invalidInput("Calendar day did not advance") }
            body(dayRow(day), cursor, finish, (finish - cursor) / (end - start))
            cursor = finish
        }
    }

    private func emitElevationCenter() throws {
        guard elevationWindow.count == 5 else { return }
        let value = elevationWindow.map(\.elevation).sorted()[2]
        let node = elevationWindow[2]
        if let anchor = elevationAnchor {
            let delta = value - anchor
            if abs(delta) >= 3 {
                if let start = node.incomingStart {
                    let ascent = max(0, delta)
                    let descent = max(0, -delta)
                    node.journey.ascent += ascent
                    node.journey.descent += descent
                    try forDayPieces(start: start, end: node.time) { row, _, _, fraction in
                        row.ascent += ascent * fraction
                        row.descent += descent * fraction
                    }
                }
                elevationAnchor = value
            }
        } else { elevationAnchor = value }
        elevationWindow.removeFirst()
    }

    private func appendElevation(_ node: SummaryElevationNode) throws {
        if elevationWindow.isEmpty {
            elevationWindow = [node, node, node]
        } else {
            elevationWindow.append(node)
            try emitElevationCenter()
        }
        elevationLast = node
    }

    private func flushElevation() throws {
        if let last = elevationLast {
            // Replicate the final endpoint twice for the centered median5.
            for _ in 0..<2 {
                elevationWindow.append(last)
                try emitElevationCenter()
            }
        }
        elevationWindow.removeAll(keepingCapacity: true)
        elevationAnchor = nil
        elevationLast = nil
    }

    func build() throws -> SummaryReport {
        try validate()
        for segment in input.segments {
            try checkCancellation()
            var previous: SummarySample?
            var journey: SummaryAccumulator?
            var spanStart = Double.infinity
            var spanEnd = -Double.infinity
            for rank in segment.pathRange {
                if rank & 4095 == 0 { try checkCancellation() }
                let i = input.pathOrder.isEmpty ? rank : Int(input.pathOrder[rank])
                let file = input.fileID.isEmpty ? 0 : input.fileID[i]
                if let selected = input.selectedFileID, selected != file {
                    try flushElevation()
                    previous = nil
                    journey = nil
                    continue
                }
                totalPoints += 1
                let validCoordinate = input.lat[i].isFinite && input.lon[i].isFinite &&
                    abs(input.lat[i]) <= 90 && abs(input.lon[i]) <= 180
                if !validCoordinate { invalidCoordinates += 1 }
                let key = SummaryPointKey(time: input.time[i], lat: input.lat[i], lon: input.lon[i], segment: segment.id)
                let synthetic = input.syntheticKeys.contains(key)
                let retimed = !synthetic && input.retimedKeys.contains(key)
                let date = day(for: input.time[i])
                let sample = SummarySample(index: i, rank: rank, file: file, time: input.time[i], day: date,
                                           validCoordinate: validCoordinate, synthetic: synthetic, retimed: retimed)
                var regionIDs: [UInt16] = []
                if validCoordinate, let assigner = assigner, let index = index {
                    try checkCancellation()
                    var current = assigner.assign(lat: input.lat[i], lon: input.lon[i])
                    // Parent depth is bounded even if an input index has a cycle.
                    for _ in 0..<4 {
                        guard let id = current, !regionIDs.contains(id) else { break }
                        regionIDs.append(id)
                        current = index.parent(of: id)
                    }
                }
                if let date = date {
                    spanStart = min(spanStart, sample.time)
                    spanEnd = max(spanEnd, sample.time)
                    if journey == nil || previous?.day == nil || previous?.file != file ||
                        (previous.map { sample.time - $0.time >= 1800 } ?? false) {
                        journey = newJourney(segment: segment.id, rank: rank)
                    }
                    let dayRow = dayRow(date)
                    point(sample, regionIDs: regionIDs, in: dayRow)
                    point(sample, regionIDs: regionIDs, in: journey!)
                } else { undatedPoints += 1 }

                var accepted = false
                if let previous = previous, previous.file == sample.file {
                    let dt = sample.time - previous.time
                    let canMeasure = previous.day != nil && sample.day != nil && previous.validCoordinate &&
                        sample.validCoordinate && dt > 0 && dt <= 300
                    let meters = canMeasure ? distance(previous.index, i) : 0
                    let kmh = canMeasure ? meters / dt * 3.6 : 0
                    if canMeasure && kmh <= 1200, let journey = journey {
                        accepted = true
                        let estimatedPosition = previous.synthetic || synthetic
                        let estimatedTime = estimatedPosition || previous.retimed || retimed
                        let eligible = !estimatedPosition
                        let covered = eligible && input.elevation[previous.index].isFinite && input.elevation[i].isFinite
                        let moving = meters / dt > 1
                        journey.edge(start: previous.time, end: sample.time, meters: meters,
                                     estimatedPosition: estimatedPosition, estimatedTime: estimatedTime,
                                     moving: moving, kmh: kmh, elevationEligible: eligible, elevationCovered: covered)
                        try forDayPieces(start: previous.time, end: sample.time) { row, a, b, fraction in
                            row.edge(start: a, end: b, meters: meters * fraction,
                                     estimatedPosition: estimatedPosition, estimatedTime: estimatedTime,
                                     moving: moving, kmh: kmh, elevationEligible: eligible, elevationCovered: covered)
                            // Bounds include an edge's endpoints even on a day that
                            // contains only a sliced contribution.
                            row.include(lat: input.lat[previous.index], lon: input.lon[previous.index])
                            row.include(lat: input.lat[i], lon: input.lon[i])
                        }
                        if covered {
                            if elevationLast == nil {
                                try appendElevation(SummaryElevationNode(time: previous.time,
                                    elevation: input.elevation[previous.index], incomingStart: nil, journey: journey))
                            }
                            try appendElevation(SummaryElevationNode(time: sample.time,
                                elevation: input.elevation[i], incomingStart: previous.time, journey: journey))
                        } else { try flushElevation() }
                    } else if let date = sample.day, let journey = journey {
                        dayRow(date).excluded += 1
                        journey.excluded += 1
                    }
                }
                if !accepted { try flushElevation() }
                if date == nil { journey = nil }
                previous = sample
            }
            try flushElevation()
            if spanEnd > spanStart { segmentSpans.append(SummaryInterval(start: spanStart, end: spanEnd)) }
        }
        try checkCancellation()
        let overlap = try overlappingSpans(segmentSpans)
        var dayRows: [SummaryRow] = []
        for row in days.values { dayRows.append(try finish(row, overlap: overlap)) }
        dayRows.sort {
            $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime < $1.startTime
        }
        try checkCancellation()
        var journeyRows: [SummaryRow] = []
        for row in journeys { journeyRows.append(try finish(row, overlap: overlap)) }
        journeyRows.sort {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            if $0.segment != $1.segment { return ($0.segment ?? 0) < ($1.segment ?? 0) }
            return ($0.firstPathRank ?? 0) < ($1.firstPathRank ?? 0)
        }
        try checkCancellation()
        return SummaryReport(sourceID: input.sourceID, trackID: input.trackID, sourceName: input.sourceName,
            timeZoneIdentifier: input.timeZoneIdentifier, ruleVersion: JourneySummaryBuilder.ruleVersion,
            totalPointCount: totalPoints, undatedPointCount: undatedPoints,
            invalidCoordinatePointCount: invalidCoordinates, days: dayRows, journeys: journeyRows)
    }

    private func union(_ intervals: [SummaryInterval]) throws -> [SummaryInterval] {
        try checkCancellation()
        let sorted = intervals.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        try checkCancellation()
        var result: [SummaryInterval] = []
        for (i, interval) in sorted.enumerated() {
            if i & 4095 == 0 { try checkCancellation() }
            SummaryAccumulator.append(interval, to: &result)
        }
        return result
    }

    private func length(_ intervals: [SummaryInterval]) throws -> Double {
        var result = 0.0
        for (i, interval) in intervals.enumerated() {
            if i & 4095 == 0 { try checkCancellation() }
            result += interval.end - interval.start
        }
        return result
    }

    private func intersectionLength(_ a: [SummaryInterval], _ b: [SummaryInterval]) throws -> Double {
        var i = 0, j = 0
        var result = 0.0
        while i < a.count && j < b.count {
            if (i + j) & 4095 == 0 { try checkCancellation() }
            result += max(0, min(a[i].end, b[j].end) - max(a[i].start, b[j].start))
            if a[i].end <= b[j].end { i += 1 } else { j += 1 }
        }
        return result
    }

    private func overlappingSpans(_ spans: [SummaryInterval]) throws -> [SummaryInterval] {
        try checkCancellation()
        var events: [(time: Double, delta: Int)] = []
        for (i, span) in spans.enumerated() {
            if i & 4095 == 0 { try checkCancellation() }
            events.append((span.start, 1))
            events.append((span.end, -1))
        }
        events.sort { $0.time < $1.time }
        try checkCancellation()
        var active = 0
        var previous = 0.0
        var result: [SummaryInterval] = []
        var i = 0
        while i < events.count {
            if i & 4095 == 0 { try checkCancellation() }
            let time = events[i].time
            if active >= 2 && time > previous {
                SummaryAccumulator.append(SummaryInterval(start: previous, end: time), to: &result)
            }
            while i < events.count && events[i].time == time {
                if i & 4095 == 0 { try checkCancellation() }
                active += events[i].delta
                i += 1
            }
            previous = time
        }
        return result
    }

    private func finish(_ row: SummaryAccumulator, overlap: [SummaryInterval]) throws -> SummaryRow {
        let observed = try union(row.observed)
        let estimated = try union(row.estimated)
        let moving = try union(row.moving)
        let observedSeconds = try length(observed)
        let estimatedSeconds = max(0, try length(estimated) - intersectionLength(observed, estimated))
        let movingSeconds = try length(moving)
        let elapsed = row.end - row.start
        // Start at the first overlapping fragment rather than scanning all prior
        // fragments again for every day/journey row.
        var lo = 0, hi = overlap.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if overlap[mid].end <= row.start { lo = mid + 1 } else { hi = mid }
        }
        var overlapSeconds = 0.0
        while lo < overlap.count && overlap[lo].start < row.end {
            if lo & 4095 == 0 { try checkCancellation() }
            overlapSeconds += max(0, min(row.end, overlap[lo].end) - max(row.start, overlap[lo].start))
            lo += 1
        }
        let publishesElevation = row.elevationEligible > 0 && row.elevationCovered >= 2 &&
            Double(row.elevationCovered) / Double(row.elevationEligible) >= 0.8
        let metrics = SummaryMetrics(pointCount: row.points, syntheticPointCount: row.synthetic,
            retimedPointCount: row.retimed, acceptedEdgeCount: row.accepted, excludedEdgeCount: row.excluded,
            recordedMeters: row.recordedMeters, estimatedMeters: row.estimatedMeters, elapsedSeconds: elapsed,
            observedSeconds: observedSeconds, estimatedSeconds: estimatedSeconds, movingSeconds: movingSeconds,
            lowMotionSeconds: max(0, observedSeconds - movingSeconds),
            unknownSeconds: max(0, elapsed - observedSeconds - estimatedSeconds), overlapSeconds: overlapSeconds,
            elevationEligibleEdges: row.elevationEligible, elevationCoveredEdges: row.elevationCovered,
            ascentMeters: publishesElevation ? row.ascent : nil, descentMeters: publishesElevation ? row.descent : nil)
        var candidates: [SummaryTransportMode] = []
        if movingSeconds >= 120 && row.transportEdges >= 5 && row.transportWeight > 0 {
            if row.transportSlowWeight / row.transportWeight >= 0.9 { candidates = [.walking, .cycling] }
            else if row.transportMediumWeight / row.transportWeight >= 0.9 { candidates = [.cycling, .road, .rail] }
            else { candidates = [.road, .rail, .air] }
        }
        try checkCancellation()
        let geography = SummaryGeography(available: index != nil,
            recordedRegionIDs: row.recordedRegions.sorted(), estimatedRegionIDs: row.estimatedRegions.sorted(),
            unassignedRecordedPoints: row.unassignedRecorded, unassignedSyntheticPoints: row.unassignedSynthetic)
        let bounds = row.minLat.isFinite ? SummaryBounds(minLat: row.minLat, maxLat: row.maxLat,
                                                         minLon: row.minLon, maxLon: row.maxLon) : nil
        return SummaryRow(id: row.id, kind: row.kind, sourceID: input.sourceID, segment: row.segment,
            firstPathRank: row.firstPathRank, startTime: row.start, endTime: row.end,
            dayStart: row.day?.start, dayEnd: row.day?.end, bounds: bounds, metrics: metrics, geography: geography,
            transport: SummaryTransportEvidence(candidates: candidates, observedMovingSeconds: movingSeconds,
                                                 observedMovingEdgeCount: row.transportEdges))
    }
}

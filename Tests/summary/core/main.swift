import Foundation
import CryptoKit
import Darwin

enum ProbeFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String { switch self { case .assertion(let message): return message } }
}
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw ProbeFailure.assertion(message) }
}
func near(_ actual: Double, _ expected: Double, _ message: String, tolerance: Double = 0.000001) throws {
    try expect(actual.isFinite && abs(actual - expected) <= tolerance, "\(message): actual=\(actual), expected=\(expected)")
}
let sourceID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
let trackID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
let base = 1_767_225_600.0 // 2026-01-01 UTC
let angularMeters = 6_371_000.0 * Double.pi / 180
var inputHashes: [String] = []
var details: [String: Any] = [:]

func input(_ times: [Double], lon: [Double]? = nil, lat: [Double]? = nil,
           elevation: [Double]? = nil, files: [UInt16] = [], selected: UInt16? = nil,
           order: [UInt32] = [], segments: [SummarySegment]? = nil, zone: String = "UTC",
           synthetic: Set<SummaryPointKey> = [], retimed: Set<SummaryPointKey> = []) -> SummaryInput {
    let n = times.count
    return SummaryInput(sourceID: sourceID, trackID: trackID, sourceName: "deterministic",
        timeZoneIdentifier: zone, lat: lat ?? Array(repeating: 0, count: n),
        lon: lon ?? (0..<n).map { Double($0) * 0.0001 },
        elevation: elevation ?? Array(repeating: 0, count: n), time: times,
        fileID: files, selectedFileID: selected, pathOrder: order,
        segments: segments ?? (n == 0 ? [] : [SummarySegment(id: 0, pathRange: 0..<n)]),
        syntheticKeys: synthetic, retimedKeys: retimed)
}
func key(_ i: Int, _ times: [Double], _ lons: [Double], segment: UInt32 = 0) -> SummaryPointKey {
    SummaryPointKey(time: times[i], lat: 0, lon: lons[i], segment: segment)
}
func hash(_ input: SummaryInput) -> String {
    var digest = SHA256()
    func bytes<T>(_ column: [T]) {
        column.withUnsafeBytes { digest.update(data: Data($0)) }
    }
    bytes(input.lat); bytes(input.lon); bytes(input.elevation); bytes(input.time)
    bytes(input.fileID); bytes(input.pathOrder)
    var metadata = "\(input.sourceID)|\(input.trackID)|\(input.timeZoneIdentifier)|\(String(describing: input.selectedFileID))"
    for segment in input.segments { metadata += "|\(segment.id):\(segment.pathRange)" }
    func sortedKeys(_ keys: Set<SummaryPointKey>) -> [String] {
        keys.map { "\($0.segment):\($0.timeBits):\($0.latBits):\($0.lonBits)" }.sorted()
    }
    metadata += "|S:" + sortedKeys(input.syntheticKeys).joined(separator: ",")
    metadata += "|R:" + sortedKeys(input.retimedKeys).joined(separator: ",")
    digest.update(data: Data(metadata.utf8))
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
func build(_ input: SummaryInput, index: RegionIndex? = nil,
           cancellation: () -> Bool = { false }) throws -> SummaryReport {
    inputHashes.append(hash(input))
    return try JourneySummaryBuilder.build(input, regionIndex: index, isCancelled: cancellation)
}
func invalid(_ input: SummaryInput) throws {
    do { _ = try build(input); throw ProbeFailure.assertion("Invalid input unexpectedly succeeded") }
    catch SummaryBuildError.invalidInput { }
}
func date(_ value: String) -> Double {
    ISO8601DateFormatter().date(from: value)!.timeIntervalSince1970
}
func metrics(_ input: SummaryInput) throws -> SummaryMetrics { try build(input).journeys[0].metrics }

let cases: [(String, () throws -> Void)] = [
    ("geometry-sparse", {
        let row = try metrics(input([base, base + 120], lon: [0, 0.002]))
        try near(row.recordedMeters, angularMeters * 0.002, "independent equatorial arc")
        try near(row.observedSeconds, 120, "sparse interval retained")
        try expect(row.acceptedEdgeCount == 1 && row.excludedEdgeCount == 0, "sparse accepted count")
    }),
    ("topology-interleaving", {
        let report = try build(input([base, base, base + 120, base + 120], lon: [0, 1, 0.001, 1.001],
            order: [0, 2, 1, 3], segments: [SummarySegment(id: 7, pathRange: 0..<2), SummarySegment(id: 8, pathRange: 2..<4)]))
        let row = report.days[0].metrics
        try near(row.recordedMeters, angularMeters * 0.002, "only A0-A1 and B0-B1")
        try near(row.observedSeconds, 120, "overlap duration union")
        try near(row.overlapSeconds, 120, "different source spans overlap")
        try expect(report.journeys.count == 2, "hard segments remain separate")
        try expect(report.journeys.allSatisfy { $0.metrics.overlapSeconds == 120 }, "journey overlap clipped from source spans")
    }),
    ("source-selection", {
        let times = [base, base, base + 120, base + 120]
        let segments = [SummarySegment(id: 1, pathRange: 0..<2), SummarySegment(id: 2, pathRange: 2..<4)]
        for selected: UInt16 in [0, 1] {
            let report = try build(input(times, lon: [0, 1, 0.001, 1.002], files: [0, 1, 0, 1],
                selected: selected, order: [0, 2, 1, 3], segments: segments))
            try expect(report.totalPointCount == 2 && report.journeys.count == 1, "one selected source")
            try near(report.days[0].metrics.recordedMeters, angularMeters * (selected == 0 ? 0.001 : 0.002), "independent source")
        }
        let zero = try build(input([base, base + 60], selected: 0))
        let missing = try build(input([base, base + 60], selected: 1))
        try expect(zero.totalPointCount == 2 && missing.totalPointCount == 0 && missing.days.isEmpty, "implicit zero distinguished from nil/one")
        let mixed = try build(input([base, base + 60], files: [0, 1]))
        try expect(mixed.journeys.count == 2 && mixed.days[0].metrics.acceptedEdgeCount == 0, "never join different files")
    }),
    ("continuity-boundaries", {
        try expect(try metrics(input([base, base + 300])).acceptedEdgeCount == 1, "300 seconds accepted")
        let over = try build(input([base, base + 300.001]))
        try expect(over.journeys.count == 1 && over.days[0].metrics.excludedEdgeCount == 1, "300+epsilon excluded without journey split")
        try near(over.journeys[0].metrics.unknownSeconds, 300.001, "uncovered interval", tolerance: 0.00001)
        try expect(try build(input([base, base + 1800])).journeys.count == 2, "1800 seconds splits exactly")
        try expect(try build(input([base, base + 1799.999])).journeys.count == 1, "below 1800 remains one journey")
        let dt = angularMeters * 0.1 * 3.6 / 1200
        try expect(try metrics(input([base, base + dt * 1.000001], lon: [0, 0.1])).acceptedEdgeCount == 1, "speed below 1200 accepted")
        try expect(try metrics(input([base, base + dt * 0.999999], lon: [0, 0.1])).acceptedEdgeCount == 0, "speed above 1200 excluded")
    }),
    ("zero-unavailable", {
        let zero = try metrics(input([base, base + 60], lon: [0, 0]))
        let lone = try metrics(input([base], lon: [0]))
        try expect(zero.acceptedEdgeCount == 1 && zero.recordedMeters == 0, "valid zero distance available")
        try expect(lone.acceptedEdgeCount == 0 && lone.elapsedSeconds == 0 && lone.ascentMeters == nil, "isolated point unavailable")
        try expect(try build(input([])).days.isEmpty, "empty snapshot valid")
    }),
    ("invalid-input", {
        try invalid(input([base], lon: []))
        try invalid(input([base, base + 60], order: [0]))
        try invalid(input([base, base + 60], order: [0, 0]))
        try invalid(input([base, base + 60], order: [0, 2]))
        try invalid(input([base, base + 60], segments: [SummarySegment(id: 0, pathRange: 0..<1)]))
        try invalid(input([base, base + 60], segments: [SummarySegment(id: 0, pathRange: 0..<1), SummarySegment(id: 0, pathRange: 1..<2)]))
        try invalid(input([base], segments: [SummarySegment(id: 0, pathRange: -1..<1)]))
        try invalid(input([base], files: [0, 1]))
        do { _ = try build(input([base], zone: "Fake/Nowhere")); throw ProbeFailure.assertion("timezone silently accepted") }
        catch SummaryBuildError.invalidTimeZone { }
    }),
    ("bad-points", {
        let times = [base, .nan, base + 60, base + 60, base + 40, base + 400, .greatestFiniteMagnitude]
        let report = try build(input(times, lat: [0, 0, 91, 0, 0, 0, 0]))
        try expect(report.totalPointCount == 7 && report.undatedPointCount == 2 && report.invalidCoordinatePointCount == 1, "bad point diagnostics")
        try expect(report.days.count == 1 && report.journeys.count == 2, "invalid time terminates known journey")
        try expect(report.days[0].metrics.acceptedEdgeCount == 0 && report.days[0].metrics.excludedEdgeCount == 4, "no bridge across invalid/equal/reversed times")
    }),
    ("midnight-conservation", {
        let midnight = date("2026-01-02T00:00:00Z")
        let report = try build(input([midnight - 60, midnight + 60], lon: [0, 0.002]))
        try expect(report.days.count == 2 && report.journeys.count == 1, "journey crosses midnight")
        for row in report.days {
            try near(row.metrics.recordedMeters, angularMeters * 0.001, "half distance")
            try near(row.metrics.observedSeconds, 60, "half duration")
            try expect(row.metrics.pointCount == 1 && row.metrics.acceptedEdgeCount == 1, "point/edge day ownership")
        }
        try near(report.days.reduce(0) { $0 + $1.metrics.recordedMeters }, report.journeys[0].metrics.recordedMeters, "distance conserved")
        let exact = try build(input([midnight - 60, midnight]))
        try expect(exact.days[0].metrics.pointCount == 1 && exact.days[1].metrics.pointCount == 1, "midnight point only next day")
        try expect(exact.days[0].metrics.acceptedEdgeCount == 1 && exact.days[1].metrics.acceptedEdgeCount == 0, "half-open edge ending midnight")
    }),
    ("calendar-dst-zones", {
        let spring = try build(input([date("2026-03-29T12:00:00Z")], zone: "Europe/Berlin")).days[0]
        let autumn = try build(input([date("2026-10-25T12:00:00Z")], zone: "Europe/Berlin")).days[0]
        try near(spring.dayEnd! - spring.dayStart!, 23 * 3600, "23 hour day")
        try near(autumn.dayEnd! - autumn.dayStart!, 25 * 3600, "25 hour day")
        let times = [date("2026-01-01T23:59:00Z"), date("2026-01-02T00:01:00Z")]
        let utc = try build(input(times))
        let berlin = try build(input(times, zone: "Europe/Berlin"))
        try expect(utc.days.count == 2 && berlin.days.count == 1, "zone changes day buckets")
        try expect(utc.journeys[0].id == berlin.journeys[0].id, "zone preserves journey ID")
        try near(utc.journeys[0].metrics.recordedMeters, berlin.journeys[0].metrics.recordedMeters, "zone preserves journey distance")
    }),
    ("long-gaps-no-empty-days", {
        let report = try build(input([base, base + 7 * 86400]))
        try expect(report.days.count == 2 && report.journeys.count == 2, "no fabricated empty days")
        try expect(report.journeys.allSatisfy { $0.metrics.unknownSeconds == 0 }, "inter-journey gap outside row scope")
        let midnight = date("2026-01-02T00:00:00Z")
        let short = try build(input([midnight - 450, midnight + 450]))
        try expect(short.days.count == 2 && short.days.allSatisfy { $0.metrics.unknownSeconds == 0 }, "no cross-midnight gap forced into day spans")
        try near(short.journeys[0].metrics.unknownSeconds, 900, "same-journey gap visible in journey")
    }),
    ("synthetic-retimed-provenance", {
        let times = (0..<4).map { base + Double($0) * 60 }
        let lons = [0.0, 0.001, 0.002, 0.003]
        let synthetic: Set<SummaryPointKey> = [key(1, times, lons), key(2, times, lons)]
        let syntheticRow = try metrics(input(times, lon: lons, synthetic: synthetic, retimed: synthetic))
        try near(syntheticRow.estimatedMeters, angularMeters * 0.003, "both anchor sides estimated")
        try expect(syntheticRow.recordedMeters == 0 && syntheticRow.syntheticPointCount == 2 && syntheticRow.retimedPointCount == 0, "synthetic precedence")
        let retimedRow = try metrics(input(times, lon: lons, retimed: [key(1, times, lons)]))
        try near(retimedRow.recordedMeters, angularMeters * 0.003, "retimed remains recorded position")
        try near(retimedRow.estimatedSeconds, 120, "retimed edge time estimated")
        try near(retimedRow.observedSeconds, 60, "unmodified edge observed")
        let segments = [SummarySegment(id: 0, pathRange: 0..<2), SummarySegment(id: 1, pathRange: 2..<4)]
        let collisionTimes = [base, base + 60, base, base + 60]
        let collisionLons = [0.0, 0.001, 0, 0.001]
        let collision = try build(input(collisionTimes, lon: collisionLons, segments: segments,
            synthetic: [key(1, collisionTimes, collisionLons)]))
        try expect(collision.days[0].metrics.syntheticPointCount == 1, "segment-qualified key")
        try near(collision.days[0].metrics.estimatedMeters, angularMeters * 0.001, "only marked segment estimated")
        let duplicate = try build(input([base, base], lon: [0, 0], synthetic: [SummaryPointKey(time: base, lat: 0, lon: 0, segment: 0)]))
        try expect(duplicate.days[0].metrics.syntheticPointCount == 2, "same-value original cannot be upgraded")
    }),
    ("interval-precedence", {
        let times = [base, base + 100, base + 50, base + 150]
        let lons = [0.0, 0.002, 0, 0.002]
        let report = try build(input(times, lon: lons,
            segments: [SummarySegment(id: 0, pathRange: 0..<2), SummarySegment(id: 1, pathRange: 2..<4)],
            synthetic: [key(3, times, lons, segment: 1)]))
        let row = report.days[0].metrics
        try near(row.elapsedSeconds, 150, "span")
        try near(row.observedSeconds, 100, "O union")
        try near(row.estimatedSeconds, 50, "E minus O")
        try near(row.unknownSeconds, 0, "duration conservation")
        try near(row.overlapSeconds, 50, "segment overlap")
        let motion = try build(input([base, base + 100, base, base + 100], lon: [0, 0, 0, 0.002],
            segments: [SummarySegment(id: 0, pathRange: 0..<2), SummarySegment(id: 1, pathRange: 2..<4)]))
        try near(motion.days[0].metrics.movingSeconds, 100, "moving interval wins conflict")
        try near(motion.days[0].metrics.lowMotionSeconds, 0, "low motion union remainder")
    }),
    ("moving-threshold", {
        let meters = angularMeters * 0.001
        let below = try metrics(input([base, base + meters * 1.000001], lon: [0, 0.001]))
        let above = try metrics(input([base, base + meters * 0.999999], lon: [0, 0.001]))
        try expect(below.movingSeconds == 0 && below.lowMotionSeconds > 0, "below 1m/s low motion")
        try expect(above.movingSeconds > 0 && above.lowMotionSeconds == 0, "above 1m/s moving")
    }),
    ("elevation-filter", {
        let times = (0..<15).map { base + Double($0) * 30 }
        let elevations = Array(repeating: 0.0, count: 5) + Array(repeating: 10.0, count: 5) + Array(repeating: 0.0, count: 5)
        let steps = try metrics(input(times, elevation: elevations))
        try near(steps.ascentMeters ?? -1, 10, "platform rise")
        try near(steps.descentMeters ?? -1, 10, "platform descent")
        var spike = Array(repeating: 0.0, count: 15); spike[7] = 100
        let suppressed = try metrics(input(times, elevation: spike))
        try expect(suppressed.ascentMeters == 0 && suppressed.descentMeters == 0, "median5 suppresses isolated spike")
        let jitter = try metrics(input(times, elevation: (0..<15).map { $0 % 2 == 0 ? 0 : 2 }))
        try expect(jitter.ascentMeters == 0 && jitter.descentMeters == 0, "deadband suppresses sub-3m jitter")
    }),
    ("elevation-coverage-breaks", {
        let times = (0..<6).map { base + Double($0) * 30 }
        let at80 = try metrics(input(times, elevation: [0, 0, 0, 0, 0, .nan]))
        try expect(at80.elevationEligibleEdges == 5 && at80.elevationCoveredEdges == 4 && at80.ascentMeters == 0, "80 percent publishes")
        let under80 = try metrics(input(times, elevation: [0, 0, 0, .nan, 100, 100]))
        try expect(under80.elevationCoveredEdges == 3 && under80.ascentMeters == nil, "below80 does not extrapolate")
        try expect(try metrics(input([base, base + 30], elevation: [0, 10])).ascentMeters == nil, "one covered edge unavailable")
        let lons = (0..<8).map { Double($0) * 0.0001 }
        let t = (0..<8).map { base + Double($0) * 30 }
        let synthetic = try metrics(input(t, lon: lons, elevation: [0, 0, 0, 50, 100, 100, 100, 100], synthetic: [key(3, t, lons)]))
        try expect(synthetic.elevationEligibleEdges == 5 && synthetic.elevationCoveredEdges == 5 && synthetic.ascentMeters == 0, "synthetic altitude breaks chain")
        let missing = try metrics(input(t, elevation: [0, 0, 0, .nan, 100, 100, 100, 100]))
        try expect(missing.ascentMeters == nil, "missing chain has insufficient coverage")
        let gap = try metrics(input([base, base + 30, base + 60, base + 400, base + 430, base + 460], elevation: [0, 0, 0, 100, 100, 100]))
        try expect(gap.ascentMeters == 0, "continuity gap never creates elevation rise")
        let retimed = try metrics(input(t, lon: lons, elevation: [0, 0, 0, 10, 10, 10, 10, 10], retimed: [key(3, t, lons)]))
        try expect(retimed.ascentMeters == 10, "retimed recorded elevation remains eligible")
    }),
    ("elevation-midnight", {
        let midnight = date("2026-01-02T00:00:00Z")
        let times = (0..<15).map { midnight - 210 + Double($0) * 30 }
        let report = try build(input(times, elevation: Array(repeating: 0, count: 7) + Array(repeating: 10, count: 8)))
        let daily = report.days.reduce(0) { $0 + ($1.metrics.ascentMeters ?? -1000) }
        try near(daily, report.journeys[0].metrics.ascentMeters ?? -1, "midnight preserves global filter contribution")
        try near(daily, 10, "known step conserved")
    }),
    ("elevation-midnight-proportions", {
        let midnight = date("2026-01-02T00:00:00Z")
        let times = (0..<15).map { midnight - 195 + Double($0) * 30 }
        let report = try build(input(times, elevation: Array(repeating: 0, count: 7) + Array(repeating: 10, count: 8)))
        try expect(report.days.count == 2 && report.journeys.count == 1, "cross-midnight elevation chain intact")
        // The threshold-triggering edge is [-15,+15] seconds around midnight.
        // Its independently known 10m step must contribute precisely half each.
        try near(report.days[0].metrics.ascentMeters ?? -1, 5, "pre-midnight half step")
        try near(report.days[1].metrics.ascentMeters ?? -1, 5, "post-midnight half step")
        try near(report.journeys[0].metrics.ascentMeters ?? -1, 10, "unbroken journey step")
    }),
    ("geography-evidence", {
        let fixture = ProcessInfo.processInfo.environment["SUMMARY_REGION_FIXTURE"]!
        guard let index = RegionIndex.load(url: URL(fileURLWithPath: fixture)) else { throw ProbeFailure.assertion("fixture did not load") }
        let times = [base, base + 60, base + 120]
        let synthetic: Set<SummaryPointKey> = [SummaryPointKey(time: times[1], lat: 0.2, lon: 0.2, segment: 0)]
        let report = try build(input(times, lon: [0.1, 0.2, 2], lat: [0.1, 0.2, 2], synthetic: synthetic), index: index)
        let geography = report.days[0].geography
        try expect(geography.available && geography.recordedRegionIDs == [0, 1, 2] && geography.estimatedRegionIDs == [0, 1, 2], "finest and parent IDs per evidence")
        try expect(geography.unassignedRecordedPoints == 1 && geography.unassignedSyntheticPoints == 0, "unassigned visible")
        let unavailable = try build(input(times)).days[0].geography
        try expect(!unavailable.available && unavailable.recordedRegionIDs.isEmpty && unavailable.unassignedRecordedPoints == 0, "absent index unavailable")
    }),
    ("transport-evidence", {
        func sample(edges: Int, duration: Double, mps: Double) -> SummaryInput {
            let times = (0...edges).map { base + Double($0) * duration / Double(edges) }
            let lons = (0...edges).map { Double($0) * duration / Double(edges) * mps / angularMeters }
            return input(times, lon: lons)
        }
        try expect(try build(sample(edges: 5, duration: 120, mps: 2)).journeys[0].transport.candidates == [.walking, .cycling], "120sec/5edges slow candidates")
        try expect(try build(sample(edges: 4, duration: 120, mps: 2)).journeys[0].transport.candidates.isEmpty, "4edges insufficient")
        try expect(try build(sample(edges: 5, duration: 119, mps: 2)).journeys[0].transport.candidates.isEmpty, "119sec insufficient")
        try expect(try build(sample(edges: 5, duration: 120, mps: 5)).journeys[0].transport.candidates == [.cycling, .road, .rail], "medium candidates unconfirmed set")
        try expect(try build(sample(edges: 5, duration: 120, mps: 20)).journeys[0].transport.candidates == [.road, .rail, .air], "fast candidates no auto confirmed mode")
        let t = (0...5).map { base + Double($0) * 24 }
        let lon = (0...5).map { Double($0) * 48 / angularMeters }
        let all = Set((0...5).map { key($0, t, lon) })
        try expect(try build(input(t, lon: lon, retimed: all)).journeys[0].transport.candidates.isEmpty, "retimed speed not evidence")
        let weightedT = [base, base + 108, base + 111, base + 114, base + 117, base + 120]
        let weightedLon = [0.0, 216, 276, 336, 396, 456].map { $0 / angularMeters }
        try expect(try build(input(weightedT, lon: weightedLon)).journeys[0].transport.candidates == [.walking, .cycling], "duration weighted 90 percent slow")
    }),
    ("cancellation", {
        let n = 100_000
        let snapshot = input((0..<n).map { base + Double($0) }, lon: (0..<n).map { Double($0) * 0.00001 })
        var calls = 0
        let start = Date()
        do {
            _ = try build(snapshot, cancellation: { calls += 1; return calls >= 1000 })
            throw ProbeFailure.assertion("Cancellation published success")
        } catch SummaryBuildError.cancelled { }
        details["callbackCalls"] = calls
        details["cancellationWallSeconds"] = Date().timeIntervalSince(start)
        try expect(calls == 1000, "real production callback cancels")
    }),
    ("scale-continuous-million", {
        let n = 1_000_000
        let snapshot = input((0..<n).map { base + Double($0) }, lon: (0..<n).map { Double($0) * 0.00001 }, elevation: Array(repeating: 100, count: n))
        let start = Date()
        let report = try build(snapshot)
        details["buildAndInputHashWallSeconds"] = Date().timeIntervalSince(start)
        details["pointCount"] = n
        details["dayCount"] = report.days.count
        try expect(report.totalPointCount == n && report.journeys.count == 1, "million one journey")
        try near(report.journeys[0].metrics.recordedMeters, Double(n - 1) * angularMeters * 0.00001, "million exact equatorial truth", tolerance: 0.001)
        try near(report.journeys[0].metrics.observedSeconds, Double(n - 1), "million interval compaction")
        try expect(report.journeys[0].metrics.ascentMeters == 0, "million flat altitude")
    }),
    ("scale-overlap-million", {
        let half = 500_000
        let t = (0..<half).map { base + Double($0) }
        let lon = (0..<half).map { Double($0) * 0.00001 }
        let snapshot = input(t + t, lon: lon + lon, segments: [SummarySegment(id: 1, pathRange: 0..<half), SummarySegment(id: 2, pathRange: half..<(2 * half))])
        let start = Date()
        let report = try build(snapshot)
        details["buildAndInputHashWallSeconds"] = Date().timeIntervalSince(start)
        details["pointCount"] = 2 * half
        details["segmentCount"] = 2
        try expect(report.journeys.count == 2, "million hard segments")
        let dailyMeters = report.days.reduce(0) { $0 + $1.metrics.recordedMeters }
        let dailyObserved = report.days.reduce(0) { $0 + $1.metrics.observedSeconds }
        let dailyOverlap = report.days.reduce(0) { $0 + $1.metrics.overlapSeconds }
        try near(dailyMeters, 2 * Double(half - 1) * angularMeters * 0.00001, "overlap preserves both polylines", tolerance: 0.001)
        try near(dailyObserved, Double(half - 1), "overlap observation union")
        try near(dailyOverlap, Double(half - 1), "overlap warning full span")
    })
]

let requested = Array(CommandLine.arguments.dropFirst())
if requested == ["--list"] { print(cases.map(\.0).joined(separator: "\n")); exit(0) }
let selectedCases = requested.isEmpty ? cases.filter { !$0.0.hasPrefix("scale-") } : cases.filter { requested.contains($0.0) }
if selectedCases.isEmpty || requested.contains(where: { name in !cases.contains(where: { $0.0 == name }) }) {
    fputs("Unknown case. Use --list.\n", stderr); exit(2)
}
var failed = 0
for (name, body) in selectedCases {
    inputHashes = []; details = [:]
    let start = Date()
    var record: [String: Any] = ["case": name, "ruleVersion": JourneySummaryBuilder.ruleVersion]
    do { try body(); record["status"] = "passed" }
    catch { failed += 1; record["status"] = "failed"; record["error"] = String(describing: error) }
    record["wallSeconds"] = Date().timeIntervalSince(start)
    record["inputSHA256"] = inputHashes
    record["details"] = details
    var usage = rusage()
    if getrusage(RUSAGE_SELF, &usage) == 0 {
        record["processPeakRSSBytes"] = usage.ru_maxrss
    }
    let encoded = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    print(String(data: encoded, encoding: .utf8)!)
}
exit(failed == 0 ? 0 : 1)

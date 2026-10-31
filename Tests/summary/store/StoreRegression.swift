import Foundation
import SwiftUI

@main struct SummaryStoreRegression {
    @MainActor static var failures = 0
    @MainActor static var checks = 0
    @MainActor static func check(_ name: String, _ good: @autoclosure () -> Bool) {
        let ok = good(); checks += 1; if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") \(name)")
        fflush(stdout)
    }
    static func parsed(_ count: Int, offset: Double = 0, start: Double = 1_767_225_540) -> ParsedTrack {
        var p = ParsedTrack()
        p.lat = (0..<count).map { _ in 0 }; p.lon = (0..<count).map { Double($0) * 0.0001 + offset }
        p.time = (0..<count).map { start + Double($0) * 30 }
        p.ele = (0..<count).map { _ in 10 }; p.name = "summary fixture"
        return p
    }
    static func build(_ p: ParsedTrack) -> TrackData { TrackData.build(parsed: p, preferredMode: .single).0 }
    @MainActor static func store(_ count: Int = 8) -> TrackStore {
        let s = TrackStore(applyAppearance: false)
        let p = parsed(count)
        s.files = [LoadedFile(name: "A", url: nil, parsed: p, color: .blue)]
        s.track = build(p); s.pickSummaryTimeZone(.utc)
        return s
    }
    @MainActor static func wait(_ label: String, _ predicate: () -> Bool) async {
        for _ in 0..<1500 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        check("timeout: " + label, false)
    }
    @MainActor static func ready(_ s: TrackStore) async {
        await wait("summary ready") { s.summaryReport != nil || s.summaryError != nil }
        check("report completed without error", s.summaryReport != nil && s.summaryError == nil && !s.summaryBusy)
    }
    @MainActor static func cache() async {
        let s = store(); s.summaryWindowOpen = true; await ready(s)
        let n = s.summaryBuildCount, id = s.summaryReport!.journeys[0].id
        s.ensureSummaryReport(); s.viewFilter = (0, 1); s.settings.pointSize += 1
        s.ensureSummaryReport()
        check("filter and visual settings excluded from cache key", s.summaryBuildCount == n)
        s.setSummaryTransport(.water, journeyID: id)
        check("manual water override does not rebuild", s.summaryTransportOverrides[id] == .water && s.summaryBuildCount == n)
        s.setSummaryTransport(.unknown, journeyID: id)
        check("unknown is an explicit manual choice", s.summaryTransportOverrides[id] == .unknown)
        s.setSummaryTransport(nil, journeyID: id)
        check("restore automatic removes override", s.summaryTransportOverrides[id] == nil)
        s.setSummaryTransport(.air, journeyID: "not-a-row")
        check("foreign journey cannot acquire manual mode", s.summaryTransportOverrides.isEmpty)
        s.setSummaryTransport(.rail, journeyID: id)
        s.pickSummaryTimeZone(.named("Europe/Berlin")); await ready(s)
        check("timezone reuses stable journey identity and override", s.summaryReport!.journeys[0].id == id && s.summaryTransportOverrides[id] == .rail)
        check("report captures actual requested timezone", s.summaryReport!.timeZoneIdentifier == "Europe/Berlin")
        let built = s.summaryBuildCount; s.summaryWindowOpen = false; s.summaryWindowOpen = true; await ready(s)
        check("close/reopen completed same key reuses one report", s.summaryBuildCount == built)
        s.pickSummaryTimeZone(.named("Definitely/Invalid"))
        check("invalid timezone has honest error and no fallback report", s.summaryError != nil && s.summaryReport == nil && !s.summaryBusy)
        s.pickSummaryTimeZone(.utc); await ready(s)
        s.track = build(parsed(3)); check("track mutation immediately removes report/filter", s.summaryReport == nil && s.summaryFilterSelection == nil)
        s.ensureSummaryReport(); await ready(s)
        check("new track clears journey manual choices", s.summaryTransportOverrides.isEmpty)
        s.clearTrack()
        check("clear removes report, busy and choices immediately", s.summaryReport == nil && !s.summaryBusy && s.summaryTransportOverrides.isEmpty)
        s.summaryWindowOpen = false
    }
    @MainActor static func sources() async {
        let s = TrackStore(applyAppearance: false)
        let a = parsed(4), b = parsed(9, offset: 1)
        s.files = [LoadedFile(name: "same", url: nil, parsed: a, color: .blue),
                   LoadedFile(name: "same", url: nil, parsed: b, color: .red)]
        s.displayMode = .overlay; s.track = build(GPXParser.mergeParsed([a,b]))
        s.summaryWindowOpen = true; await ready(s)
        check("overlay selects first file rather than adding devices", s.summaryReport?.totalPointCount == 4)
        check("duplicate filenames have distinct labels", s.summarySources[0].name != s.summarySources[1].name)
        s.pickSummarySource(s.files[1].id); await ready(s)
        check("overlay source switch uses correct fileID subset", s.summaryReport?.totalPointCount == 9)
        check("overlay map action is disabled", s.summaryMapUnavailableReason != nil)
        let actual = build(parsed(6, offset: 4))
        s.displayMode = .compare; s.compareTracks = [build(a), actual]
        s.ensureSummaryReport(); await ready(s)
        check("compare uses pane TrackData identity, not merged store.track", s.summaryReport?.trackID == actual.id && s.summaryReport?.totalPointCount == 6)
        s.compareTracks = nil
        check("compare-not-ready immediately removes old report", s.summaryReport == nil && !s.summaryBusy)
        s.ensureSummaryReport()
        check("compare waits rather than falling back to merged data", s.summaryReport == nil && !s.summaryBusy)
        s.summaryWindowOpen = false
        let untimed = store(2); var noTime = parsed(2); noTime.time = [.nan,.nan]
        untimed.track = build(noTime); untimed.summaryWindowOpen = true; await ready(untimed)
        check("untimed report preserves unknown dates instead of invented rows", untimed.summaryReport!.undatedPointCount == 2 && untimed.summaryReport!.days.isEmpty)
        untimed.summaryWindowOpen = false
    }
    @MainActor static func ownership() async {
        for failure in [false, true] {
            let s = store(); var held: [@MainActor () -> Void] = []
            var hold = true
            s.publicationGate = { token, commit in
                if token.lane == .summary && hold { held.append(commit) } else { commit() }
            }
            if failure { s.summaryBuilderOverride = { _,_ in throw SummaryBuildError.invalidInput("injected worker failure") } }
            s.summaryWindowOpen = true
            await wait("old result gated") { !held.isEmpty }
            check("old result remains busy while gated", s.summaryBusy && s.summaryReport == nil)
            hold = false; s.summaryBuilderOverride = nil
            s.pickSummaryTimeZone(.named("Europe/Berlin")); await ready(s)
            let id = s.summaryReport?.trackID, count = s.summaryBuildCount
            held.forEach { $0() }
            check("stale \(failure ? "failure" : "success") cannot overwrite newer report or busy",
                  s.summaryReport?.trackID == id && s.summaryReport?.timeZoneIdentifier == "Europe/Berlin"
                    && !s.summaryBusy && s.summaryError == nil && s.summaryBuildCount == count)
            s.summaryWindowOpen = false
        }
        let s = store(); var held: [@MainActor () -> Void] = []
        s.publicationGate = { token, commit in if token.lane == .summary { held.append(commit) } else { commit() } }
        s.summaryWindowOpen = true; await wait("close result gated") { !held.isEmpty }
        s.summaryWindowOpen = false; held.forEach { $0() }
        check("window close cancels in-flight ownership and suppresses publication", s.summaryReport == nil && !s.summaryBusy && s.summaryTask == nil)
        s.publicationGate = nil; s.summaryWindowOpen = true; await ready(s)
        s.clearTrack()
        check("clear cannot resurrect stale report", s.summaryReport == nil && !s.summaryBusy)
        s.summaryWindowOpen = false
    }
    @MainActor static func map() async {
        let s = store(8); s.summaryWindowOpen = true; await ready(s)
        let report = s.summaryReport!, journey = report.journeys[0], count = s.summaryBuildCount
        s.showSummaryOnMainMap(journey.id)
        check("journey map range includes final endpoint through nextUp", s.viewFilter?.end == journey.endTime.nextUp && s.visibleIndexRange().len == 8)
        check("map filter stores truthful source/zone chip and no date spec", s.summaryFilterSelection?.rowID == journey.id && s.viewFilterSpec == nil)
        s.ensureSummaryReport(); check("summary does not recompute from its own filter", s.summaryBuildCount == count)
        s.clearSummaryMapFilter(); check("chip clear restores full data", s.viewFilter == nil && s.summaryFilterSelection == nil && s.visibleIndexRange().len == 8)
        let day = report.days[0]; s.showSummaryOnMainMap(day.id)
        check("day filter uses natural-day interval", s.viewFilter?.start == day.dayStart && s.viewFilter?.end == day.dayEnd)
        s.viewFilter = (1,2)
        check("external explicit filter removes stale summary marker", s.summaryFilterSelection == nil && s.viewFilter?.start == 1)
        s.deleteMode = true; s.showSummaryOnMainMap(journey.id)
        check("map selection cannot alter active delete flow", s.viewFilter?.start == 1 && s.deleteMode)
        s.deleteMode = false; s.fillMode = true; s.showSummaryOnMainMap(journey.id)
        check("map selection cannot alter active fill flow", s.viewFilter?.start == 1 && s.fillMode)
        s.fillMode = false; s.showSummaryOnMainMap(journey.id)
        s.track = build(parsed(3))
        check("reload clears active summary filter immediately", s.summaryFilterSelection == nil && s.viewFilter == nil)
        s.summaryWindowOpen = false
    }
    @MainActor static func provenance() async {
        let s = store(3), t = s.track!
        func point(_ i: Int) -> FillPoint {
            FillPoint(lat: t.lat[i], lon: t.lon[i], ele: t.ele[i], time: t.time[i], headingDeg: 0, speedMps: 1, distFromPrev: 1)
        }
        func fill(_ indexes: [Int], retimed: Set<GapFillExport.PointKey> = []) -> GapFill {
            var f = GapFill(anchorA: FillAnchor(lat:t.lat[0],lon:t.lon[0],ele:10,time:t.time[0]),
                            anchorB: FillAnchor(lat:t.lat[2],lon:t.lon[2],ele:10,time:t.time[2]),
                            vertices: [], points: indexes.map(point), removedInner: 0)
            f.retimedKeys = retimed; return f
        }
        let old = GapFillExport.PointKey(t.time[2],t.lat[2],t.lon[2],segment:0)
        let record = fill([1,2],retimed:[old])
        let snap = SummaryWorkSnapshot(track:t,sourceID:s.files[0].id,name:"A",zone:"UTC",selectedFileID:0,fills:[record])
        do {
            let input = try await Task.detached { try snap.input() }.value
            let sk = SummaryPointKey(time:t.time[1],lat:t.lat[1],lon:t.lon[1],segment:0)
            let rk = SummaryPointKey(time:t.time[2],lat:t.lat[2],lon:t.lon[2],segment:0)
            check("worker adapter separates synthetic and retimed positions", input.syntheticKeys == [sk] && input.retimedKeys == [rk])
        } catch { check("adapter unexpectedly threw", false) }
        s.fills = [fill([1])]; s.summaryWindowOpen = true; await ready(s)
        let n = s.summaryBuildCount
        check("current fill provenance appears in real builder", s.summaryReport!.journeys[0].metrics.syntheticPointCount == 1)
        let oneRetimed = GapFillExport.PointKey(t.time[1],t.lat[1],t.lon[1],segment:0)
        s.fills = [fill([1],retimed:[oneRetimed])]; s.ensureSummaryReport(); await ready(s)
        check("equal-count provenance replacement invalidates cache", s.summaryBuildCount == n + 1 && s.summaryReport!.journeys[0].metrics.syntheticPointCount == 0 && s.summaryReport!.journeys[0].metrics.retimedPointCount == 1)
        s.summaryWindowOpen = false
    }
    @MainActor static func lifecycle() async {
        let s = store(); s.summaryWindowOpen = true; await ready(s)
        let n = s.summaryBuildCount
        // Production display-mode didSet invalidates even if the input track is
        // unchanged. This must autonomously schedule a replacement report.
        s.displayMode = .overlay
        check("mode-only invalidation removes report synchronously", s.summaryReport == nil)
        await ready(s)
        check("mode-only invalidation refreshes open window without view callback", s.summaryBuildCount == n + 1)
        s.displayMode = .single; await ready(s)
        let row = s.summaryReport!.journeys[0]
        s.showSummaryOnMainMap(row.id)
        check("lifecycle baseline has active chip", s.summaryFilterSelection != nil)
        // Test-copy access models an effective system timezone resolution change
        // that reaches ensureSummaryReport without pickSummaryTimeZone. No system
        // preference or global timezone is mutated.
        s.summaryTimeZoneChoice = .named("Asia/Tokyo")
        s.ensureSummaryReport()
        check("changed effective timezone clears old chip before worker publish", s.summaryFilterSelection == nil && s.viewFilter == nil)
        await ready(s)
        check("effective timezone refresh publishes captured identifier", s.summaryReport!.timeZoneIdentifier == "Asia/Tokyo")
        var p = parsed(2);p.lon=[179.999,-179.999]
        s.track = build(p); await ready(s)
        let version = s.mapFocusVersion
        s.showSummaryOnMainMap(s.summaryReport!.journeys[0].id)
        check("dateline bounds keep exact time filter without wrong camera flight",
              s.summaryFilterSelection != nil && s.visibleIndexRange().len == 2 && s.mapFocusVersion == version)
        s.summaryShowsJourneys = true
        check("production UI tab state changes independently of report computation", s.summaryShowsJourneys && !s.summaryBusy)
        s.summaryWindowOpen = false
    }
    @MainActor static func modeentry() async {
        let s = store(); s.summaryWindowOpen = true; await ready(s)
        let original = s.track!.id, count = s.summaryBuildCount
        s.switchDisplayMode(to: .overlay)
        await ready(s)
        check("public single-to-overlay entry refreshes without manual ensure or track change",
              s.track!.id == original && s.summaryBuildCount == count + 1 && s.summaryReport != nil)
        s.switchDisplayMode(to: .single)
        await ready(s)
        check("public one-file overlay-to-single entry refreshes without manual ensure",
              s.track!.id == original && s.summaryBuildCount == count + 2 && s.summaryReport != nil)
        s.summaryWindowOpen = false
    }
    @MainActor static func navigation(continuationOnly: Bool = false) async {
        let utc = TimeZone(secondsFromGMT: 0)!
        var berlin = Calendar(identifier: .gregorian); berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        func day(_ d: Int) -> SummaryCalendarDay { SummaryCalendarDay(year: 2026, month: 10, day: d) }
        func spec(_ d: Int) -> ViewFilterSpec {
            ViewFilterSpec(mode: .day, dayY: 2026, dayM: 10, dayD: d, calendar: berlin)
        }
        func selected(_ request: SummaryEntryRequest) -> SummaryCalendarDay? {
            if case .day(let d, _) = request { return d }; return nil
        }
        if !continuationOnly {
        for (m, d, hours) in [(3, 29, 23.0), (10, 25, 25.0)] {
            let value = SummaryCalendarDay(year: 2026, month: m, day: d)
            let s = ViewFilterSpec(mode: .day, dayY: 2026, dayM: m, dayD: d, calendar: berlin)
            let range = s.summaryRange()!
            check("navigation DST \(hours)h is explicit same-day intent", selected(.mainFilter(spec: s, range: range)) == value
                  && range.end - range.start == hours * 3600
                  && value.interval(in: "Europe/Berlin")!.duration == hours * 3600)
        }
        check("navigation rejects nonexistent Gregorian date", SummaryCalendarDay(year: 2026, month: 2, day: 30).interval(in: "UTC") == nil)
        check("navigation rejects whole civil day skipped by Apia", SummaryCalendarDay(year: 2011, month: 12, day: 30).interval(in: "Pacific/Apia") == nil)
        var buddhist = Calendar(identifier: .buddhist); buddhist.timeZone = berlin.timeZone
        let nonGregorian = ViewFilterSpec(mode: .day, dayY: 2569, dayM: 10, dayD: 16, calendar: buddhist)
        check("navigation non-Gregorian intent converts same real natural day", selected(.mainFilter(spec: nonGregorian, range: nonGregorian.summaryRange())) == day(16))
        let stale = spec(16), range = stale.summaryRange()!
        check("navigation stale semantic spec cannot infer date", selected(.mainFilter(spec: stale, range: (range.start + 1, range.end))) == nil)
        for mode in [ExportMode.all, .year, .month, .custom] {
            let s = ViewFilterSpec(mode: mode, year: 2026, month: 10,
                                   startY: 2026, startM: 10, startD: 17, endY: 2026, endM: 10, endD: 16, calendar: berlin)
            check("navigation \(mode) remains unsubmitted", selected(.mainFilter(spec: s, range: s.summaryRange())) == nil)
        }
        let custom = ViewFilterSpec(mode: .custom, startY: 2026, startM: 10, startD: 16,
                                    endY: 2026, endM: 10, endD: 16, calendar: berlin)
        check("navigation same-day custom is explicit day", selected(.mainFilter(spec: custom, range: custom.summaryRange())) == day(16))

        }
        let s = store()
        let first = day(16).interval(in: "UTC")!.end.timeIntervalSince1970 - 60
        let p = parsed(8, start: first)
        s.files = [LoadedFile(name: "navigation", url: nil, parsed: p, color: .blue)]; s.track = build(p)
        if continuationOnly {
            s.applySummaryEntry(.day(day(16), timeZoneIdentifier: "UTC")); await ready(s)
        } else {
        s.viewFilterSpec = spec(16); s.viewFilter = spec(16).summaryRange()
        s.openSummaryFromMainFilter(); await ready(s)
        check("navigation main entry submits October 16 and captures Berlin", s.summaryDateNavigation.selectedDay == day(16)
              && s.summaryTimeZoneChoice == .named("Europe/Berlin") && s.summaryDateNavigation.fromMainRange)
        check("navigation captured main range and report Gregorian day interval agree", day(16).interval(in: s.summaryReport!.timeZoneIdentifier)!.start.timeIntervalSince1970 == s.viewFilter!.start)
        let builds = s.summaryBuildCount, revision = s.summaryDateNavigation.revision
        s.summaryShowsJourneys = true
        s.viewFilterSpec = spec(17); s.viewFilter = spec(17).summaryRange(); s.openSummaryFromMainFilter()
        check("navigation already-open explicit entry receives October 17 and daily mode", s.summaryDateNavigation.selectedDay == day(17)
              && s.summaryDateNavigation.revision == revision + 1 && !s.summaryShowsJourneys && s.summaryBuildCount == builds)
        s.pickSummaryTimeZone(.utc); await ready(s)
        check("navigation changing zone preserves civil date and removes main-range claim", s.summaryDateNavigation.selectedDay == day(17) && !s.summaryDateNavigation.fromMainRange)
        let report = s.summaryReport!, journey = report.journeys[0], count = s.summaryBuildCount
        s.selectSummaryDate(day(16)); let firstIDs = s.currentSummaryDayJourneys.map(\.id)
        s.selectSummaryDate(day(17)); s.summaryShowsJourneys = true
        check("navigation cross-midnight journey belongs to both selected days", firstIDs == [journey.id] && s.currentSummaryDayJourneys.map(\.id) == [journey.id])
        check("navigation journey projection preserves full original metrics", s.currentSummaryJourney == journey)
        s.selectSummaryJourney("foreign")
        check("navigation foreign journey selection is rejected", s.currentSummaryJourney?.id == journey.id)
        s.selectSummaryDate(day(20))
        check("navigation empty date persists without any first-row fallback", s.summaryDateNavigation.selectedDay == day(20)
              && s.currentSummaryDayRow == nil && s.currentSummaryDayJourneys.isEmpty && s.currentSummaryJourney == nil)
        s.selectSummaryDate(day(16)); s.summaryShowsJourneys = false; s.summaryShowsJourneys = true
        check("navigation dates, empty days and tabs never rebuild statistics", s.summaryBuildCount == count)
        let invalid = SummaryCalendarDay(year: 2026, month: 2, day: 30)
        s.selectSummaryDate(invalid)
        check("navigation invalid draft reports error without normalizing", s.summaryDateNavigation.draftDay == invalid
              && s.summaryDateNavigation.hint == .invalidDay && s.summaryDateNavigation.selectedDay == day(16))
        let apia = SummaryCalendarDay(year: 2011, month: 12, day: 30)
        s.pickSummaryTimeZone(.named("Pacific/Apia")); await ready(s); s.selectSummaryDate(apia)
        check("navigation skipped Apia draft stays exact with inline error", s.summaryDateNavigation.draftDay == apia && s.summaryDateNavigation.hint == .invalidDay)
        s.pickSummaryTimeZone(.utc); await ready(s); s.selectSummaryDate(day(16))
        }
        s.showSummaryOnMainMap(s.currentSummaryDayRow!.id); s.openSummaryFromMainFilter()
        await ready(s) // UTC's named alias may canonicalize to GMT and rebuild.
        check("navigation valid day chip retains exact day and zone", s.summaryDateNavigation.selectedDay == day(16)
              && s.summaryTimeZoneChoice.identifier == s.summaryReport!.timeZoneIdentifier)
        s.showSummaryOnMainMap(s.summaryReport!.journeys[0].id); s.openSummaryFromMainFilter()
        check("navigation journey chip never guesses a natural day", s.summaryDateNavigation.selectedDay == nil && s.currentSummaryDayRow == nil)
        s.viewFilter = nil; s.viewFilterSpec = nil; s.openSummaryFromMainFilter()
        check("navigation all entry shows only an unsubmitted draft", s.summaryDateNavigation.selectedDay == nil && s.summaryDateNavigation.hint == .chooseDate)
        s.summaryWindowOpen = false

        // Actual builder work is held at the production publication seam. Date
        // changes do not restart that worker; its index must explain the latest day.
        let pending = store(); pending.files = s.files; pending.track = build(p)
        var held: [@MainActor () -> Void] = []
        pending.publicationGate = { token, commit in if token.lane == .summary { held.append(commit) } else { commit() } }
        pending.applySummaryEntry(.day(day(16), timeZoneIdentifier: "UTC"))
        await wait("navigation gated report") { !held.isEmpty }
        let once = pending.summaryBuildCount
        pending.selectSummaryDate(day(17)); held.removeFirst()()
        check("navigation delayed report and index resolve latest date without rebuilding", pending.summaryDateNavigation.selectedDay == day(17)
              && pending.currentSummaryDayRow?.dayStart == day(17).interval(in: "UTC")!.start.timeIntervalSince1970
              && pending.summaryBuildCount == once)
        pending.publicationGate = nil; pending.summaryWindowOpen = false

        for edit in [false, true] {
            let draft = store(); draft.files = s.files; draft.track = build(p)
            var gates: [@MainActor () -> Void] = []
            draft.publicationGate = { token, commit in if token.lane == .summary { gates.append(commit) } else { commit() } }
            draft.applySummaryEntry(.chooseDate(seed: nil, timeZoneIdentifier: nil, hint: .chooseDate))
            await wait("navigation draft seed gated") { !gates.isEmpty }
            let typed = SummaryCalendarDay(year: 2016, month: 1, day: 1)
            if edit { draft.editSummaryDateDraft(typed) }
            gates.removeFirst()()
            check("navigation late report \(edit ? "preserves edited draft" : "seeds latest only as draft")",
                  draft.summaryDateNavigation.draftDay == (edit ? typed : day(17)) && draft.summaryDateNavigation.selectedDay == nil)
            draft.publicationGate = nil; draft.summaryWindowOpen = false
        }
        for event in ["zone", "source", "clear", "edit", "close"] {
            let delayed = store(); delayed.files = s.files; delayed.track = build(p)
            var gates: [@MainActor () -> Void] = []
            delayed.publicationGate = { token, commit in if token.lane == .summary { gates.append(commit) } else { commit() } }
            delayed.applySummaryEntry(.day(day(17), timeZoneIdentifier: "UTC"))
            await wait("navigation lifecycle gated \(event)") { !gates.isEmpty }
            delayed.publicationGate = nil
            switch event {
            case "zone": delayed.pickSummaryTimeZone(.named("Europe/Berlin")); await ready(delayed)
            case "source":
                let other = parsed(2, offset: 1, start: first - 86400 * 3)
                delayed.files.append(LoadedFile(name: "other", url: nil, parsed: other, color: .red))
                delayed.track = build(GPXParser.mergeParsed([p, other])); delayed.displayMode = .overlay
                delayed.pickSummarySource(delayed.files[1].id); await ready(delayed)
            case "edit": delayed.track = build(parsed(2, start: first - 86400 * 3)); delayed.ensureSummaryReport(); await ready(delayed)
            case "clear": delayed.clearTrack()
            default: delayed.summaryWindowOpen = false
            }
            let newTrack = delayed.summaryReport?.trackID, newZone = delayed.summaryReport?.timeZoneIdentifier
            gates.forEach { $0() }
            check("navigation stale report/index cannot publish after \(event)", delayed.summaryReport?.trackID == newTrack
                  && delayed.summaryReport?.timeZoneIdentifier == newZone && !delayed.summaryBusy)
            if event == "clear" {
                check("navigation clear removes submitted day and index projections", delayed.summaryDateNavigation.selectedDay == nil
                      && delayed.currentSummaryDayRow == nil && delayed.currentSummaryDayJourneys.isEmpty)
            } else if event != "close" {
                check("navigation \(event) preserves requested civil day", delayed.summaryDateNavigation.selectedDay == day(17))
            }
            delayed.summaryWindowOpen = false
        }
        // Explicit midnight endpoints: start at midnight is not yesterday; a
        // previous journey whose final sample is midnight still belongs today.
        let midnight = day(17).interval(in: "UTC")!.start.timeIntervalSince1970
        for startAtMidnight in [false, true] {
            let input = parsed(2, start: midnight + (startAtMidnight ? 0 : -30))
            let st = store(); st.files = [LoadedFile(name: "boundary", url: nil, parsed: input, color: .blue)]
            st.track = build(input); st.applySummaryEntry(.day(day(16), timeZoneIdentifier: "UTC")); await ready(st)
            check("navigation midnight \(startAtMidnight ? "start excludes previous day" : "endpoint includes previous day")", st.currentSummaryDayJourneys.count == (startAtMidnight ? 0 : 1))
            st.selectSummaryDate(day(17))
            check("navigation midnight endpoint belongs to current day", st.currentSummaryDayJourneys.count == 1)
            st.summaryWindowOpen = false
        }
        _ = utc // explicit fixture zone, no system defaults or global zone writes.
    }
    @MainActor static func navigationChip() async {
        // Separate directed closeout: UTC is canonicalized to GMT by Foundation
        // for named zones. The independent contract is the captured chip zone and
        // absolute day interval, not a spelling of the requested alias.
        let day = SummaryCalendarDay(year: 2026, month: 10, day: 16)
        let p = parsed(8, start: day.interval(in: "UTC")!.end.timeIntervalSince1970 - 60)
        let s = store(); s.files = [LoadedFile(name: "chip", url: nil, parsed: p, color: .blue)]; s.track = build(p)
        s.applySummaryEntry(.day(day, timeZoneIdentifier: "UTC")); await ready(s)
        let report = s.summaryReport!, row = s.currentSummaryDayRow!, capturedZone = report.timeZoneIdentifier
        let count = s.summaryBuildCount
        s.showSummaryOnMainMap(row.id); s.openSummaryFromMainFilter(); await ready(s)
        check("navigation chip receives actual captured zone and exact natural-day range",
              s.summaryDateNavigation.selectedDay == day && s.summaryTimeZoneChoice == .named(capturedZone)
              && day.interval(in: capturedZone)!.start.timeIntervalSince1970 == row.dayStart
              && day.interval(in: capturedZone)!.end.timeIntervalSince1970 == row.dayEnd)
        check("navigation same captured chip zone reuses report without date rebuild", s.summaryBuildCount == count)
        s.summaryWindowOpen = false

        let skipped = SummaryCalendarDay(year: 2011, month: 12, day: 30)
        let invalid = store(); invalid.applySummaryEntry(.day(skipped, timeZoneIdentifier: "UTC")); await ready(invalid)
        invalid.pickSummaryTimeZone(.named("Pacific/Apia"))
        check("navigation timezone change preserves skipped civil YMD and reports invalid immediately",
              invalid.summaryDateNavigation.selectedDay == skipped && invalid.summaryDateNavigation.draftDay == skipped
              && invalid.summaryDateNavigation.hint == .invalidDay && invalid.currentSummaryDayRow == nil)
        await ready(invalid)
        check("navigation report completion cannot normalize skipped selected date", invalid.summaryDateNavigation.selectedDay == skipped
              && invalid.summaryDateNavigation.hint == .invalidDay && invalid.currentSummaryDayJourneys.isEmpty)
        invalid.pickSummaryTimeZone(.utc)
        check("navigation changing back to valid timezone clears date error without changing YMD",
              invalid.summaryDateNavigation.selectedDay == skipped && invalid.summaryDateNavigation.hint == nil)
        invalid.summaryWindowOpen = false
    }
    @MainActor static func main() async {
        let selected = Set(CommandLine.arguments.dropFirst())
        if selected.isEmpty || selected.contains("cache") { await cache() }
        if selected.isEmpty || selected.contains("sources") { await sources() }
        if selected.isEmpty || selected.contains("ownership") { await ownership() }
        if selected.isEmpty || selected.contains("map") { await map() }
        if selected.isEmpty || selected.contains("provenance") { await provenance() }
        if selected.isEmpty || selected.contains("lifecycle") { await lifecycle() }
        if selected.isEmpty || selected.contains("modeentry") { await modeentry() }
        if selected.isEmpty || selected.contains("navigation") { await navigation() }
        if selected.contains("navigation-continuation") { await navigation(continuationOnly: true) }
        if selected.contains("navigation-chip") { await navigationChip() }
        print("SUMMARY \(checks) checks; \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}

import SwiftUI

struct JourneySummaryCommands: Commands {
    @ObservedObject var store: TrackStore
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .windowList) {
            Button("每日与行程摘要…") {
                store.openSummaryFromMainFilter()
                openWindow(id: SceneID.journeySummary)
            }
        }
    }
}

struct JourneySummaryWindowView: View {
    @ObservedObject var store: TrackStore
    @State private var namedZone = "Europe/Berlin"
    @State private var dateField = SummaryDateFieldController()

    private var report: SummaryReport? { store.summaryReport }
    private var journeys: Bool { store.summaryShowsJourneys }
    private var rows: [SummaryRow] { store.currentSummaryDayJourneys }
    private var selected: SummaryRow? { journeys ? store.currentSummaryJourney : store.currentSummaryDayRow }
    private var zone: String { report?.timeZoneIdentifier ?? store.summaryTimeZoneChoice.identifier ?? "—" }
    private var dateCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .current
        return calendar
    }
    private var draftDate: Binding<Date> {
        Binding(get: {
            // The control edits civil components. UTC is an adapter only, so a
            // date skipped in the actual summary zone stays visible for validation.
            store.summaryDateNavigation.draftDay.interval(in: "UTC")?.start ?? Date()
        }, set: {
            store.editSummaryDateDraft(SummaryCalendarDay(date: $0, timeZone: TimeZone(secondsFromGMT: 0)!))
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(12)
            Divider()
            if let report, store.summaryDateNavigation.selectedDay != nil, selected != nil {
                HSplitView {
                    if journeys { List(rows, selection: Binding(get: {
                        store.summaryDateNavigation.selectedJourneyID
                    }, set: { if let id = $0 { store.selectSummaryJourney(id) } })) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(SummaryDisplay.time(row.dayStart ?? row.startTime, zone: zone, dateOnly: !journeys))
                                .font(.headline).fixedSize(horizontal: false, vertical: true)
                            Text(row.metrics.acceptedEdgeCount > 0
                                 ? SummaryDisplay.distance(row.metrics.recordedMeters + row.metrics.estimatedMeters)
                                 : String(localized: "距离不可计算"))
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4).tag(row.id)
                    }
                    .frame(minWidth: 215, idealWidth: 250, maxWidth: 340)
                    .accessibilityIdentifier("summaryDayJourneys") }
                    ScrollViewReader { proxy in
                        ScrollView {
                            if let row = selected { detail(row, report: report).padding(16) }
                        }
                        .onAppear {
                            if UITestHook.enabled {
                                UITestHook.shared.summaryScroll = { lower in
                                    proxy.scrollTo(lower ? "summaryGeography" : "summaryDetailTop", anchor: .top)
                                }
                            }
                        }
                        .onDisappear { if UITestHook.enabled { UITestHook.shared.summaryScroll = nil } }
                    }.frame(minWidth: 410, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("按所选日期浏览；统计基于所选文件的全部记录。查看摘要不会改变主地图筛选。")
                Text("补点来源仅在本次编辑会话可识别。")
                if let report, report.undatedPointCount > 0 {
                    Text("日期未知：\(report.undatedPointCount) 点")
                }
                if let report, report.invalidCoordinatePointCount > 0 {
                    Text("无效坐标：\(report.invalidCoordinatePointCount) 点")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .frame(minWidth: 780, minHeight: 560)
        .onAppear { syncNamedZone(); store.summaryWindowOpen = true; store.ensureSummaryReport() }
        .onDisappear { store.summaryWindowOpen = false }
        .onChange(of: store.track?.id) { store.ensureSummaryReport() }
        .onChange(of: store.compareTracks?.map(\.id)) { store.ensureSummaryReport() }
        .onChange(of: store.fwdbVersion) { store.ensureSummaryReport() }
        .onChange(of: store.summaryDateNavigation.revision) { syncNamedZone() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            if store.summaryTimeZoneChoice == .system { store.ensureSummaryReport() }
        }
        .accessibilityIdentifier("journeySummaryWindow")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Picker("来源", selection: Binding(get: { store.summarySourceID }, set: { if let id = $0 { store.pickSummarySource(id) } })) {
                    ForEach(store.summarySources) { source in
                        Text(source.name).tag(Optional(source.id))
                    }
                }
                .frame(maxWidth: .infinity)
                .disabled(store.summarySources.isEmpty)
                Picker("摘要列表", selection: $store.summaryShowsJourneys) {
                    Text("每日").tag(false)
                    Text("行程").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(Text("摘要列表"))
                .frame(width: 180)
            }
            HStack {
                Picker("日期时区", selection: Binding(get: { zoneMode }, set: { mode in
                    if mode == 0 { store.pickSummaryTimeZone(.system) }
                    else if mode == 1 { store.pickSummaryTimeZone(.utc) }
                    else { store.pickSummaryTimeZone(.named(namedZone)) }
                })) {
                    Text("本机时区").tag(0)
                    Text("UTC").tag(1)
                    Text("指定时区").tag(2)
                }.frame(maxWidth: 330)
                if zoneMode == 2 {
                    TextField("IANA 时区", text: $namedZone)
                        .onSubmit { store.pickSummaryTimeZone(.named(namedZone)) }
                    Button("应用时区") { store.pickSummaryTimeZone(.named(namedZone)) }
                }
                if store.summaryBusy { ProgressView().controlSize(.small) }
            }
            Text("日期按所选时区划分：\(zone)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                HStack {
                    Text("查看日期")
                    SummaryNativeDateField(selection: draftDate,
                                           revision: store.summaryDateNavigation.revision,
                                           controller: dateField) { date in
                        store.selectSummaryDate(SummaryCalendarDay(date: date, timeZone: TimeZone(secondsFromGMT: 0)!))
                    }
                    .frame(width: 170, height: 24)
                    .accessibilityIdentifier("summaryDateInput")
                }
                .frame(maxWidth: 320, alignment: .leading)
                Button("查看") { dateField.submit() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("summaryDateSubmit")
            }
            if let day = store.summaryDateNavigation.selectedDay {
                Text("当前摘要日期：\(day.isoDescription)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if store.summaryDateNavigation.fromMainRange {
                Text("日期与主面板所选自然日一致。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let hint = store.summaryDateNavigation.hint {
                Text(hint.message).font(.callout)
                    .foregroundStyle(hint == .invalidDay ? .red : .secondary)
                    .accessibilityIdentifier("summaryDateHint")
            }
        }
    }

    private func syncNamedZone() {
        if case .named(let name) = store.summaryTimeZoneChoice { namedZone = name }
    }

    private var zoneMode: Int {
        switch store.summaryTimeZoneChoice {
        case .system: return 0
        case .utc: return 1
        case .named: return 2
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.fwdbActive {
                Text("存档没有逐点真实时间和连续路线，无法计算每日／行程摘要。")
            } else if store.isLoading {
                ProgressView()
                Text("正在载入轨迹…")
            } else if let error = store.summaryError {
                Text(error).foregroundStyle(.red)
                Button("重新计算") { store.ensureSummaryReport() }
            } else if store.summaryBusy {
                ProgressView()
                Text("正在计算摘要…")
            } else if store.track == nil && store.compareTracks == nil {
                Text("请先导入 GPX 或 CSV 轨迹。")
            } else if store.summaryDateNavigation.selectedDay == nil {
                Text("请选择日期后查看摘要。")
            } else if let day = store.summaryDateNavigation.selectedDay, report != nil {
                Text(verbatim: day.isoDescription).font(.headline).monospacedDigit()
                Text("该日期没有记录。")
                Text("日期按所选时区划分：\(zone)")
            } else if let report, report.undatedPointCount > 0 {
                Text("轨迹没有可用于日期摘要的时间。")
                Text("日期未知：\(report.undatedPointCount) 点")
            } else {
                Text("当前来源没有可用于摘要的记录。")
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func detail(_ row: SummaryRow, report: SummaryReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(SummaryDisplay.time(row.startTime, zone: zone) + " – " + SummaryDisplay.time(row.endTime, zone: zone))
                .font(.headline).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .id("summaryDetailTop")
            if row.kind == .journey,
               !dateCalendar.isDate(Date(timeIntervalSince1970: row.startTime),
                                    inSameDayAs: Date(timeIntervalSince1970: row.endTime)) {
                Text("跨日行程；以下为完整行程统计。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if row.metrics.pointCount == 1 { Text("仅一个记录点").foregroundStyle(.secondary) }
            GroupBox("距离") {
                VStack(alignment: .leading, spacing: 6) {
                    if row.metrics.acceptedEdgeCount == 0 { Text("距离不可计算") }
                    else {
                        metric("记录折线", SummaryDisplay.distance(row.metrics.recordedMeters))
                        metric("补点估算", SummaryDisplay.distance(row.metrics.estimatedMeters))
                    }
                    Text("存储点的折线长度；稀疏记录可能漏掉弯道，定位抖动可能增大长度。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("合格边：\(row.metrics.acceptedEdgeCount)；排除边：\(row.metrics.excludedEdgeCount)")
                        .font(.caption)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("时间覆盖") {
                VStack(alignment: .leading, spacing: 6) {
                    metric("记录跨度", SummaryDisplay.duration(row.metrics.elapsedSeconds))
                    metric("观测间隔", SummaryDisplay.duration(row.metrics.observedSeconds))
                    metric("估算时间", SummaryDisplay.duration(row.metrics.estimatedSeconds))
                    metric("未覆盖时间", SummaryDisplay.duration(row.metrics.unknownSeconds))
                    metric("移动估计", SummaryDisplay.duration(row.metrics.movingSeconds))
                    metric("低速间隔", SummaryDisplay.duration(row.metrics.lowMotionSeconds))
                    Text("仅统计本行首末记录之间；低速和空白不代表确定停留。")
                        .font(.caption).foregroundStyle(.secondary)
                    if row.metrics.overlapSeconds > 0 {
                        Text("源段时间重叠，距离可能含重复记录。").foregroundStyle(.orange)
                    }
                    if row.metrics.retimedPointCount > 0 {
                        Text("包含 \(row.metrics.retimedPointCount) 个改时观察点，日期与时间含估算。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("爬升与下降") {
                VStack(alignment: .leading, spacing: 6) {
                    if let up = row.metrics.ascentMeters, let down = row.metrics.descentMeters {
                        metric("爬升（滤波估算）", up.formatted(.number.precision(.fractionLength(0))) + " m")
                        metric("下降（滤波估算）", down.formatted(.number.precision(.fractionLength(0))) + " m")
                    } else { Text("海拔覆盖不足，爬升／下降不可用。") }
                    Text("海拔边覆盖率：\(row.metrics.elevationCoveredEdges) / \(row.metrics.elevationEligibleEdges)")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            geography(row).id("summaryGeography")
            transport(row, report: report)
            VStack(alignment: .leading, spacing: 6) {
                Button("在主地图上查看") { store.showSummaryOnMainMap(row.id) }
                    .disabled(store.summaryMapUnavailableReason != nil)
                if let reason = store.summaryMapUnavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                Text("行程按源轨迹段和 30 分钟记录空白分段，不按午夜拆分。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func metric(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }

    private func regionNames(_ ids: [UInt16]) -> String {
        guard let index = RegionIndex.shared else { return "—" }
        return ids.compactMap { index.region($0)?.localizedName }.joined(separator: " · ")
    }
    private func geography(_ row: SummaryRow) -> some View {
        GroupBox("国家与地区") {
            VStack(alignment: .leading, spacing: 8) {
                if row.geography.available {
                    Text("记录位置到访").font(.caption.bold())
                    Text(regionNames(row.geography.recordedRegionIDs).isEmpty
                         ? String(localized: "没有地区落点") : regionNames(row.geography.recordedRegionIDs))
                    Text("补点经过（估算）").font(.caption.bold())
                    Text(regionNames(row.geography.estimatedRegionIDs).isEmpty
                         ? String(localized: "没有地区落点") : regionNames(row.geography.estimatedRegionIDs))
                    Text("未归属：记录 \(row.geography.unassignedRecordedPoints) 点，补点 \(row.geography.unassignedSyntheticPoints) 点")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("仅按落点归属，不推断越境时刻、地区内里程或停留时长。")
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text("行政区边界数据不可用。") }
            }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func evidence(_ row: SummaryRow) -> String {
        guard !row.transport.candidates.isEmpty else { return String(localized: "交通方式未知：观测证据不足。") }
        let candidates = row.transport.candidates.map(\.summaryTitle).joined(separator: " / ")
        return String(localized: "候选：\(candidates)（仅按速度，未确认）", comment: "Summary speed-only candidate list, never a confirmed mode")
    }
    private func transport(_ row: SummaryRow, report: SummaryReport) -> some View {
        GroupBox("交通方式") {
            VStack(alignment: .leading, spacing: 8) {
                if row.kind == .journey {
                    Picker("本行程模式", selection: Binding(get: {
                        store.summaryTransportOverrides[row.id]?.rawValue ?? "automatic"
                    }, set: { value in
                        store.setSummaryTransport(value == "automatic" ? nil : SummaryTransportMode(rawValue: value), journeyID: row.id)
                    })) {
                        Text("恢复自动候选").tag("automatic")
                        ForEach(SummaryTransportMode.allCases, id: \.rawValue) { mode in
                            Text(mode.summaryTitle).tag(mode.rawValue)
                        }
                    }
                    if let mode = store.summaryTransportOverrides[row.id] {
                        Text("手动指定：\(mode.summaryTitle)")
                    }
                    Text(evidence(row)).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(store.currentSummaryDayJourneys) { journey in
                        if let mode = store.summaryTransportOverrides[journey.id] {
                            Text("手动指定：\(mode.summaryTitle)")
                        } else { Text(evidence(journey)) }
                    }
                    Text("每日显示相关行程的模式与候选，不生成唯一的全天交通方式。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Both the explicit button and Return read the native editor's committed value.
/// SwiftUI's date field consumes Return before the window's default button.
private final class SummaryDateFieldController {
    weak var picker: SummarySubmittingDatePicker?
    @MainActor func submit() { picker?.commitAndSubmit() }
}

private struct SummaryNativeDateField: NSViewRepresentable {
    @Binding var selection: Date
    let revision: UInt64
    let controller: SummaryDateFieldController
    let onSubmit: (Date) -> Void

    func makeNSView(context: Context) -> SummarySubmittingDatePicker {
        let picker = SummarySubmittingDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerMode = .single
        picker.datePickerElements = [.yearMonthDay]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        picker.calendar = calendar; picker.timeZone = calendar.timeZone
        picker.locale = .autoupdatingCurrent
        picker.isBezeled = true; picker.drawsBackground = true
        picker.isContinuous = true
        picker.target = picker; picker.action = #selector(SummarySubmittingDatePicker.changed)
        picker.setAccessibilityLabel(String(localized: "查看日期"))
        updateNSView(picker, context: context)
        return picker
    }

    func updateNSView(_ picker: SummarySubmittingDatePicker, context: Context) {
        controller.picker = picker
        picker.onChange = { selection = $0 }
        picker.onSubmit = onSubmit
        // A new explicit entry wins over an in-progress old edit. Ordinary view
        // updates must not replace a segment while the user is typing it.
        if picker.navigationRevision != revision {
            picker.isSynchronizing = true
            if picker.ownsEditor { _ = picker.window?.makeFirstResponder(nil) }
            picker.dateValue = selection
            picker.navigationRevision = revision
            picker.isSynchronizing = false
        } else if !picker.ownsEditor, picker.dateValue != selection {
            picker.dateValue = selection
        }
    }

    static func dismantleNSView(_ picker: SummarySubmittingDatePicker, coordinator: ()) {
        picker.stopMonitoring()
    }
}

private final class SummarySubmittingDatePicker: NSDatePicker {
    var onChange: ((Date) -> Void)?
    var onSubmit: ((Date) -> Void)?
    var navigationRevision: UInt64?
    var isSynchronizing = false
    private var isSubmitting = false
    private var returnMonitor: Any?

    var ownsEditor: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === self || responder === currentEditor() { return true }
        return (responder as? NSView)?.isDescendant(of: self) == true
    }

    @objc func changed() {
        if !isSynchronizing { onChange?(dateValue) }
    }

    func commitAndSubmit() {
        guard !isSubmitting, !isSynchronizing else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        // NSControl validates the current field editor before we read dateValue;
        // makeFirstResponder then finishes any segment edit. A refused edit does
        // not submit an older date under the newly typed text.
        validateEditing()
        if let window, !window.makeFirstResponder(nil) { NSSound.beep(); return }
        let committed = dateValue
        onChange?(committed)
        onSubmit?(committed)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        returnMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.ownsEditor,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  event.keyCode == 36 || event.keyCode == 76 else { return event }
            self.commitAndSubmit()
            return nil
        }
    }

    func stopMonitoring() {
        if let returnMonitor { NSEvent.removeMonitor(returnMonitor) }
        returnMonitor = nil
    }
}

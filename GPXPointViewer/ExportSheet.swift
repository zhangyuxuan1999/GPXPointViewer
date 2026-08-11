//
//  ExportSheet.swift
//  GPXPointViewer
//
//  导出面板：粒度自适应数据的实际时间跨度——
//  跨多年：全部/年/月/日/自定义；同一年：不再出现年选择（年份直接显示为文字）；
//  同一个月：只需选日；同一天：根本不会打开本面板（ContentView 直接导出）。
//  绝不出现"只有一个选项的选择框"。
//  日期一律用明确的「年 / 月 / 日」下拉，无区域格式歧义；边界按本机时区。
//

import SwiftUI

enum ExportMode: String, CaseIterable, Identifiable {
    case all = "全部"
    case year = "年"
    case month = "月"
    case day = "日"
    case custom = "自定义"
    var id: String { rawValue }
}

/// 查看筛选的"形状"（粒度 + 各粒度的具体取值）。
/// 时间筛选生效时由 TimeFilterSection 维护，导出面板打开时用它预设
/// 同一时间段——查哪段就默认导哪段。
struct ViewFilterSpec: Equatable {
    var mode: ExportMode
    var year = 2026
    var month = 1
    var dayY = 2026, dayM = 1, dayD = 1
    var startY = 2026, startM = 1, startD = 1
    var endY = 2026, endM = 1, endD = 1
}

struct ExportSheet: View {
    @ObservedObject var store: TrackStore
    @Environment(\.dismiss) private var dismiss

    // 数据实际时间跨度（本机时区，onAppear 填充）
    // 注：@State 只能修饰单变量声明，逐行拆开
    @State private var y0 = 2026
    @State private var m0 = 1
    @State private var d0 = 1
    @State private var y1 = 2026
    @State private var m1 = 1
    @State private var d1 = 1
    @State private var modes: [ExportMode] = [.all]
    @State private var mode: ExportMode = .all

    @State private var year = 2026
    @State private var month = 1
    @State private var dayY = 2026
    @State private var dayM = 1
    @State private var dayD = 1
    @State private var startY = 2026
    @State private var startM = 1
    @State private var startD = 1
    @State private var endY = 2026
    @State private var endM = 1
    @State private var endD = 1

    private var multiYear: Bool { y0 != y1 }
    private var multiMonth: Bool { multiYear || m0 != m1 }

    // MARK: - 范围工具

    private func daysIn(_ y: Int, _ m: Int) -> Int {
        let cal = Calendar.current
        guard let d = cal.date(from: DateComponents(year: y, month: m, day: 1)),
              let r = cal.range(of: .day, in: .month, for: d) else { return 31 }
        return r.count
    }

    private func monthLow(_ y: Int) -> Int { y == y0 ? m0 : 1 }
    private func monthHigh(_ y: Int) -> Int { y == y1 ? m1 : 12 }
    private func dayLow(_ y: Int, _ m: Int) -> Int { (y == y0 && m == m0) ? d0 : 1 }
    private func dayHigh(_ y: Int, _ m: Int) -> Int {
        min((y == y1 && m == m1) ? d1 : 31, daysIn(y, m))
    }

    private func dayStart(_ y: Int, _ m: Int, _ d: Int) -> Date? {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: min(d, daysIn(y, m))))
    }

    private var range: (Double, Double)? {
        let cal = Calendar.current
        switch mode {
        case .all:
            return nil
        case .year:
            guard let s = cal.date(from: DateComponents(year: year)),
                  let e = cal.date(byAdding: .year, value: 1, to: s) else { return nil }
            return (s.timeIntervalSince1970, e.timeIntervalSince1970)
        case .month:
            guard let s = cal.date(from: DateComponents(year: year, month: month)),
                  let e = cal.date(byAdding: .month, value: 1, to: s) else { return nil }
            return (s.timeIntervalSince1970, e.timeIntervalSince1970)
        case .day:
            guard let s = dayStart(dayY, dayM, dayD),
                  let e = cal.date(byAdding: .day, value: 1, to: s) else { return nil }
            return (s.timeIntervalSince1970, e.timeIntervalSince1970)
        case .custom:
            guard let a = dayStart(startY, startM, startD),
                  let b = dayStart(endY, endM, endD) else { return nil }
            let lo = min(a, b)
            let hi = max(a, b)
            guard let e = cal.date(byAdding: .day, value: 1, to: hi) else { return nil }
            return (lo.timeIntervalSince1970, e.timeIntervalSince1970)   // 含首尾两天
        }
    }

    private var previewCount: Int {
        store.countPoints(in: mode == .all ? nil : range)
    }

    // MARK: - 视图

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导出 GPX")
                .font(.headline)

            if modes.count > 1 {
                Picker("范围", selection: $mode) {
                    ForEach(modes) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Group {
                switch mode {
                case .all:
                    Text("导出当前数据的全部点（删除操作之后剩下的点）。")
                        .font(.caption)
                        .foregroundStyle(Color.primary.opacity(0.7))
                case .year:
                    HStack(spacing: 6) {
                        yearPicker($year)
                        Text("年")
                    }
                case .month:
                    HStack(spacing: 6) {
                        if multiYear {
                            yearPicker($year)
                            Text("年")
                        } else {
                            Text("\(String(y0)) 年")
                        }
                        numberPicker($month, monthLow(year)...monthHigh(year), width: 60)
                        Text("月")
                    }
                case .day:
                    ymdRow(y: $dayY, m: $dayM, d: $dayD)
                case .custom:
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text("从").frame(width: 20, alignment: .leading)
                            ymdRow(y: $startY, m: $startM, d: $startD)
                        }
                        HStack(spacing: 6) {
                            Text("到").frame(width: 20, alignment: .leading)
                            ymdRow(y: $endY, m: $endM, d: $endD)
                        }
                        Text("含首尾两天整天")
                            .font(.caption2)
                            .foregroundStyle(Color.primary.opacity(0.6))
                    }
                }
            }
            .font(.callout)

            Divider()

            HStack {
                Text("将导出 \(previewCount.formatted()) 个点")
                    .font(.callout.monospacedDigit())
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("导出…") {
                    let r = mode == .all ? nil : range
                    dismiss()
                    store.exportGPX(range: r)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(previewCount == 0)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: initDefaults)
        .onChange(of: year) {
            month = min(max(month, monthLow(year)), monthHigh(year))
        }
        .onChange(of: dayY) {
            dayM = min(max(dayM, monthLow(dayY)), monthHigh(dayY))
            dayD = min(max(dayD, dayLow(dayY, dayM)), dayHigh(dayY, dayM))
        }
        .onChange(of: dayM) {
            dayD = min(max(dayD, dayLow(dayY, dayM)), dayHigh(dayY, dayM))
        }
        .onChange(of: startY) {
            startM = min(max(startM, monthLow(startY)), monthHigh(startY))
            startD = min(max(startD, dayLow(startY, startM)), dayHigh(startY, startM))
        }
        .onChange(of: startM) {
            startD = min(max(startD, dayLow(startY, startM)), dayHigh(startY, startM))
        }
        .onChange(of: endY) {
            endM = min(max(endM, monthLow(endY)), monthHigh(endY))
            endD = min(max(endD, dayLow(endY, endM)), dayHigh(endY, endM))
        }
        .onChange(of: endM) {
            endD = min(max(endD, dayLow(endY, endM)), dayHigh(endY, endM))
        }
    }

    // MARK: - 明确的年/月/日控件（自适应：单一取值时显示为文字）

    private func yearPicker(_ sel: Binding<Int>) -> some View {
        Picker("", selection: sel) {
            ForEach(Array(y0...max(y0, y1)), id: \.self) { y in
                Text(String(y)).tag(y)
            }
        }
        .labelsHidden()
        .frame(width: 84)
    }

    private func numberPicker(_ sel: Binding<Int>, _ bounds: ClosedRange<Int>, width: CGFloat) -> some View {
        Picker("", selection: sel) {
            ForEach(Array(bounds), id: \.self) { v in
                Text(String(v)).tag(v)
            }
        }
        .labelsHidden()
        .frame(width: width)
    }

    @ViewBuilder
    private func ymdRow(y: Binding<Int>, m: Binding<Int>, d: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            if multiYear {
                yearPicker(y)
                Text("年")
            } else {
                Text("\(String(y0)) 年")
            }
            if multiMonth {
                numberPicker(m, monthLow(y.wrappedValue)...monthHigh(y.wrappedValue), width: 60)
                Text("月")
            } else {
                Text("\(m0) 月")
            }
            numberPicker(d, dayLow(y.wrappedValue, m.wrappedValue)...dayHigh(y.wrappedValue, m.wrappedValue), width: 60)
            Text("日")
        }
    }

    private func initDefaults() {
        guard let track = store.track, let tr = track.timeRange else {
            modes = [.all]
            mode = .all
            return
        }
        let cal = Calendar.current
        let first = Date(timeIntervalSince1970: tr.min)
        let last = Date(timeIntervalSince1970: tr.max)
        y0 = cal.component(.year, from: first)
        m0 = cal.component(.month, from: first)
        d0 = cal.component(.day, from: first)
        y1 = cal.component(.year, from: last)
        m1 = cal.component(.month, from: last)
        d1 = cal.component(.day, from: last)

        if multiYear {
            modes = [.all, .year, .month, .day, .custom]
        } else if multiMonth {
            modes = [.all, .month, .day, .custom]
        } else {
            modes = [.all, .day, .custom]
        }
        mode = .all

        year = y1
        month = m1
        dayY = y1; dayM = m1; dayD = d1
        startY = y0; startM = m0; startD = d0
        endY = y1; endM = m1; endD = d1

        // 查看筛选进行中 → 导出默认预设为同一时间段（同粒度），方便"查哪段导哪段"
        if let spec = store.viewFilterSpec, modes.contains(spec.mode) {
            mode = spec.mode
            year = min(max(spec.year, y0), y1)
            month = spec.month
            dayY = spec.dayY; dayM = spec.dayM; dayD = spec.dayD
            startY = spec.startY; startM = spec.startM; startD = spec.startD
            endY = spec.endY; endM = spec.endM; endD = spec.endD
        }
    }
}

// MARK: - 控制面板内的查看时间筛选（自适应粒度，写 store.viewFilter）
//
// 注意：body 拆成小块子视图、年/月/日合并为 Equatable 结构体——
// 否则十几个链式 onChange 组成的巨型表达式会让类型检查器超时（编译失败）。

struct TimeFilterSection: View {
    @ObservedObject var store: TrackStore

    private struct YMD: Equatable {
        var y = 2026
        var m = 1
        var d = 1
    }

    @State private var y0 = 2026
    @State private var m0 = 1
    @State private var d0 = 1
    @State private var y1 = 2026
    @State private var m1 = 1
    @State private var d1 = 1
    @State private var modes: [ExportMode] = [.all]
    @State private var mode: ExportMode = .all

    @State private var year = 2026
    @State private var month = 1
    @State private var day = YMD()
    @State private var rangeStart = YMD()
    @State private var rangeEnd = YMD()

    private var multiYear: Bool { y0 != y1 }
    private var multiMonth: Bool { multiYear || m0 != m1 }

    // MARK: 布局（body 保持极小，防类型检查超时）

    var body: some View {
        content
            .font(.caption)
            .onAppear(perform: initSpan)
            .onChange(of: store.track?.id) { initSpan() }
            .onChange(of: mode) { push() }
            .onChange(of: year) { clampYearMonth() }
            .onChange(of: month) { push() }
            .onChange(of: day) { day = clamped(day); push() }
            .onChange(of: rangeStart) { rangeStart = clamped(rangeStart); push() }
            .onChange(of: rangeEnd) { rangeEnd = clamped(rangeEnd); push() }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if modes.count > 1 {
                modePicker
                modeContent
            }
        }
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            ForEach(modes) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var modeContent: some View {
        switch mode {
        case .all:
            EmptyView()
        case .year:
            HStack(spacing: 6) {
                yearPicker($year)
                Text("年")
            }
        case .month:
            monthRow
        case .day:
            ymdRow($day)
        case .custom:
            customRows
        }
    }

    private var monthRow: some View {
        HStack(spacing: 6) {
            if multiYear {
                yearPicker($year)
                Text("年")
            } else {
                Text("\(String(y0)) 年")
            }
            numberPicker($month, monthLow(year)...monthHigh(year), width: 56)
            Text("月")
        }
    }

    private var customRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("从").frame(width: 18, alignment: .leading)
                ymdRow($rangeStart)
            }
            HStack(spacing: 6) {
                Text("到").frame(width: 18, alignment: .leading)
                ymdRow($rangeEnd)
            }
        }
    }

    @ViewBuilder
    private func ymdRow(_ v: Binding<YMD>) -> some View {
        let cur = v.wrappedValue
        HStack(spacing: 6) {
            if multiYear {
                yearPicker(v.y)
                Text("年")
            } else {
                Text("\(String(y0)) 年")
            }
            if multiMonth {
                numberPicker(v.m, monthLow(cur.y)...monthHigh(cur.y), width: 56)
                Text("月")
            } else {
                Text("\(m0) 月")
            }
            numberPicker(v.d, dayLow(cur.y, cur.m)...dayHigh(cur.y, cur.m), width: 56)
            Text("日")
        }
    }

    private func yearPicker(_ sel: Binding<Int>) -> some View {
        Picker("", selection: sel) {
            ForEach(Array(y0...max(y0, y1)), id: \.self) { y in
                Text(String(y)).tag(y)
            }
        }
        .labelsHidden()
        .frame(width: 78)
    }

    private func numberPicker(_ sel: Binding<Int>, _ bounds: ClosedRange<Int>, width: CGFloat) -> some View {
        Picker("", selection: sel) {
            ForEach(Array(bounds), id: \.self) { v in
                Text(String(v)).tag(v)
            }
        }
        .labelsHidden()
        .frame(width: width)
    }

    // MARK: 范围与钳制

    private func daysIn(_ y: Int, _ m: Int) -> Int {
        let cal = Calendar.current
        guard let d = cal.date(from: DateComponents(year: y, month: m, day: 1)),
              let r = cal.range(of: .day, in: .month, for: d) else { return 31 }
        return r.count
    }
    private func monthLow(_ y: Int) -> Int { y == y0 ? m0 : 1 }
    private func monthHigh(_ y: Int) -> Int { y == y1 ? m1 : 12 }
    private func dayLow(_ y: Int, _ m: Int) -> Int { (y == y0 && m == m0) ? d0 : 1 }
    private func dayHigh(_ y: Int, _ m: Int) -> Int {
        min((y == y1 && m == m1) ? d1 : 31, daysIn(y, m))
    }

    private func clamped(_ v: YMD) -> YMD {
        var r = v
        r.m = min(max(r.m, monthLow(r.y)), monthHigh(r.y))
        r.d = min(max(r.d, dayLow(r.y, r.m)), dayHigh(r.y, r.m))
        return r
    }

    private func clampYearMonth() {
        month = min(max(month, monthLow(year)), monthHigh(year))
        push()
    }

    private func dayStart(_ v: YMD) -> Date? {
        Calendar.current.date(from: DateComponents(year: v.y, month: v.m,
                                                   day: min(v.d, daysIn(v.y, v.m))))
    }

    private func currentRange() -> (Double, Double)? {
        let cal = Calendar.current
        switch mode {
        case .all:
            return nil
        case .year:
            guard let s = cal.date(from: DateComponents(year: year)),
                  let e = cal.date(byAdding: .year, value: 1, to: s) else { return nil }
            return (s.timeIntervalSince1970, e.timeIntervalSince1970)
        case .month:
            guard let s = cal.date(from: DateComponents(year: year, month: month)),
                  let e = cal.date(byAdding: .month, value: 1, to: s) else { return nil }
            return (s.timeIntervalSince1970, e.timeIntervalSince1970)
        case .day:
            guard let s = dayStart(day),
                  let e = cal.date(byAdding: .day, value: 1, to: s) else { return nil }
            return (s.timeIntervalSince1970, e.timeIntervalSince1970)
        case .custom:
            guard let a = dayStart(rangeStart),
                  let b = dayStart(rangeEnd) else { return nil }
            let lo = min(a, b)
            let hi = max(a, b)
            guard let e = cal.date(byAdding: .day, value: 1, to: hi) else { return nil }
            return (lo.timeIntervalSince1970, e.timeIntervalSince1970)
        }
    }

    private func push() {
        if mode == .all {
            store.viewFilter = nil
            store.viewFilterSpec = nil
        } else if let r = currentRange() {
            store.viewFilter = (start: r.0, end: r.1)
            store.viewFilterSpec = ViewFilterSpec(
                mode: mode, year: year, month: month,
                dayY: day.y, dayM: day.m, dayD: day.d,
                startY: rangeStart.y, startM: rangeStart.m, startD: rangeStart.d,
                endY: rangeEnd.y, endM: rangeEnd.m, endD: rangeEnd.d)
        }
    }

    private func initSpan() {
        guard let track = store.track, let tr = track.timeRange else {
            modes = [.all]
            mode = .all
            return
        }
        let cal = Calendar.current
        let first = Date(timeIntervalSince1970: tr.min)
        let last = Date(timeIntervalSince1970: tr.max)
        y0 = cal.component(.year, from: first)
        m0 = cal.component(.month, from: first)
        d0 = cal.component(.day, from: first)
        y1 = cal.component(.year, from: last)
        m1 = cal.component(.month, from: last)
        d1 = cal.component(.day, from: last)

        if multiYear {
            modes = [.all, .year, .month, .day, .custom]
        } else if multiMonth {
            modes = [.all, .month, .day, .custom]
        } else {
            modes = [.all, .day, .custom]
        }
        mode = .all
        year = y1
        month = m1
        day = YMD(y: y1, m: m1, d: d1)
        rangeStart = YMD(y: y0, m: m0, d: d0)
        rangeEnd = YMD(y: y1, m: m1, d: d1)
    }
}

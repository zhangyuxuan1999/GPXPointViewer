//
//  RegionsWindow.swift
//  GPXPointViewer
//
//  「地区统计」窗口：到访国家列表 → 省/州 → 中国地级市（对标《世界迷雾》行政区卡片）。
//  口径二选一：点（点数 / 到访天数）或迷雾（解锁面积 / 等级，世界迷雾口径）。点一行 → 主地图高亮边界并飞过去，
//  行下方出现该地区的卡片；有到访下级的行末有 › 可下钻。
//

import SwiftUI

struct RegionsWindowView: View {
    @ObservedObject var store: TrackStore
    @State private var path: [UInt16] = []          // 下钻路径（国 → 省/州）

    private var index: RegionIndex? { RegionIndex.shared }
    private var hasData: Bool { store.track != nil || store.fwdbActive }
    private var indexUsable: Bool { index?.isEmpty == false }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(10)
            Divider()
            content
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { store.autoRegionsMode(); store.ensureRegionReport() }
        .onChange(of: store.track?.id) { path = []; store.autoRegionsMode(); store.ensureRegionReport() }
        .onChange(of: store.fwdbVersion) { path = []; store.autoRegionsMode(); store.ensureRegionReport() }
        .onChange(of: store.settings.fogMap) { store.autoRegionsMode() }
        .onChange(of: store.regionsMode) { store.ensureRegionReport() }
        .onChange(of: store.regionReport == nil) { trimPath() }
    }

    /// 换口径后当前层级没数据 → 回到有数据的祖先
    private func trimPath() {
        guard let report = store.regionReport else { return }
        while let last = path.last, report.stats[last] == nil { path.removeLast() }
    }

    // MARK: 头部

    private var title: String {
        guard let index, !path.isEmpty else { return String(localized: "地区统计") }
        return path.compactMap { index.region($0)?.localizedName }.joined(separator: " › ")
    }

    private var header: some View {
        HStack(spacing: 10) {
            if !path.isEmpty {
                Button {
                    path.removeLast()
                    store.selectRegion(path.last, fly: path.last != nil)
                } label: { Label("返回上一级", systemImage: "chevron.left").labelStyle(.iconOnly) }
                .keyboardShortcut("[", modifiers: .command)
                .help("返回上一级（⌘[）")
            }
            Text(verbatim: title).font(.headline).lineLimit(1)
            Spacer()
            if indexUsable, store.regionModesAvailable.count > 1 {
                Picker("统计口径", selection: Binding(get: { store.regionsMode }, set: { store.pickRegionsMode($0) })) {
                    Text("点").tag(RegionReport.Mode.points)
                    Text("迷雾").tag(RegionReport.Mode.fog)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .help("点 = 落在该地区的轨迹点数与到访天数；迷雾 = 该地区内解锁的格子面积（世界迷雾口径）与按同一公式折算的等级")
            }
            if store.regionSelection != nil {
                Button("清除高亮") { store.selectRegion(nil, fly: false) }
                    .help("去掉主地图上的地区边界")
            }
        }
    }

    // MARK: 内容

    @ViewBuilder private var content: some View {
        if let index, !index.isEmpty {
            if !hasData {
                placeholder("先载入 GPX / CSV 轨迹或 .fwdb 存档")
            } else if let report = store.regionReport {
                if let current = path.last, index.region(current) != nil {
                    drill(report, index, current: current)
                } else {
                    root(report, index)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("计算中…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            placeholder("这个版本没有内置行政区边界数据，地区统计暂不可用")
        }
    }

    private func placeholder(_ key: LocalizedStringKey) -> some View {
        Text(key).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func root(_ report: RegionReport, _ index: RegionIndex) -> some View {
        let countries = report.countries(index)
        let total = report.assignedTotal(index)
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("到访国家 \(countries.count)")
                if report.mode == .fog {
                    Text("已探索 \((report.totalM2 / 1e6).formatted(Self.km2Style)) km²")
                    if report.unassignedCells > 0 {
                        Text("其中未归属 \((report.unassignedM2 / 1e6).formatted(Self.km2Style)) km²（\(report.unassignedCells) 格，海上 / 无边界数据）")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("共 \(report.totalPoints) 点")
                    if report.unassignedPoints > 0 { Text("未归属 \(report.unassignedPoints) 点（海上 / 无边界数据）").foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            if let sel = store.regionSelection, let r = index.region(sel), r.level == 0, report.stats[sel] != nil {
                card(sel, report, index, compact: true).padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
            }
            if countries.isEmpty {
                placeholder("没有点落在任何国家境内")
            } else {
                List {
                    ForEach(Array(countries.enumerated()), id: \.element) { i, id in
                        row(rank: i + 1, id: id, report: report, index: index, parentMetric: total)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func drill(_ report: RegionReport, _ index: RegionIndex, current: UInt16) -> some View {
        let kids = report.visitedChildren(of: current, index)
        let rest = report.remainder(of: current, index)
        return VStack(spacing: 0) {
            card(current, report, index, compact: false).padding(12)
            if let sel = store.regionSelection, sel != current, index.parent(of: sel) == current, report.stats[sel] != nil {
                Divider()
                card(sel, report, index, compact: true).padding(.horizontal, 12).padding(.vertical, 8)
            }
            Divider()
            if kids.isEmpty {
                placeholder(report.childCount(of: current, index) > 0 ? "下级行政区都没有数据" : "该地区没有更细的行政区划")
            } else {
                List {
                    ForEach(Array(kids.enumerated()), id: \.element) { i, id in
                        row(rank: i + 1, id: id, report: report, index: index, parentMetric: report.metric(current))
                    }
                    if rest > 0 {
                        remainderRow(rest, report: report, parentMetric: report.metric(current))
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: 卡片与行

    private func card(_ id: UInt16, _ report: RegionReport, _ index: RegionIndex, compact: Bool) -> some View {
        let r = index.region(id)
        let s = report.stats[id] ?? RegionStat(id: id)
        let total = report.childCount(of: id, index)
        let visited = report.visitedChildren(of: id, index).count
        let area = r?.areaKm2 ?? 0
        let parent: UInt16? = r.flatMap { $0.hasParent ? $0.parent : nil }
        return VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack(spacing: 10) {
                if let f = r?.flag, !f.isEmpty { Text(verbatim: f).font(.system(size: compact ? 22 : 34)) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: r?.localizedName ?? "").font(compact ? .headline : .title3.bold())
                    Text("面积 \(area.formatted(Self.areaStyle)) km²").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if report.mode == .fog { levelBadge(s.level, compact: compact) }
            }
            HStack(alignment: .top, spacing: 22) {
                if total > 0 { stat(r?.level == 0 ? "行政区" : "次级行政区", "\(visited)/\(total)") }
                if let parent {
                    stat("探索占比", Self.pct(report.share(id, in: parent)))
                        .help(report.mode == .fog ? "占上一级已探索面积的比例" : "占上一级点数的比例")
                }
                if report.mode == .fog {
                    stat("已探索面积", "\(s.km2.formatted(Self.km2Style)) km²")
                    stat("占本区面积", Self.pct(area > 0 ? s.km2 / area * 100 : 0))
                    stat("解锁格子", s.cells.formatted())
                } else {
                    stat("点数", s.points.formatted())
                    if report.hasTime {
                        stat("到访天数", s.firstTime.isFinite ? s.days.formatted() : "—")
                        if s.firstTime.isFinite { stat("首次 / 最近", "\(Self.day(s.firstTime)) – \(Self.day(s.lastTime))") }
                    }
                }
                Spacer()
            }
        }
    }

    private func levelBadge(_ level: Int, compact: Bool) -> some View {
        Text("等级 \(level)")
            .font(compact ? .subheadline.monospacedDigit() : .headline.monospacedDigit())
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .help("本区已探索面积按 ⌊√(km²×250)⌋ 折算的等级（与总览卡同一公式；世界迷雾分区等级的口径未公开，可能不同）")
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(verbatim: value).font(.body.monospacedDigit())
        }
    }

    private func row(rank: Int, id: UInt16, report: RegionReport, index: RegionIndex, parentMetric: Double) -> some View {
        let r = index.region(id)
        let s = report.stats[id] ?? RegionStat(id: id)
        let kidsTotal = report.childCount(of: id, index)
        let kidsVisited = report.visitedChildren(of: id, index).count
        let selected = store.regionSelection == id
        let share = parentMetric > 0 ? report.metric(id) / parentMetric * 100 : 0
        return HStack(spacing: 8) {
            Button {
                store.selectRegion(id)
            } label: {
                HStack(spacing: 8) {
                    Text(verbatim: "\(rank)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                    if let f = r?.flag, !f.isEmpty { Text(verbatim: f) }
                    Text(verbatim: r?.localizedName ?? "").lineLimit(1)
                    if kidsVisited > 0 {
                        Text(verbatim: "\(kidsVisited)")
                            .font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(.green.opacity(0.4 + 0.6 * Double(kidsVisited) / Double(max(1, kidsTotal)))))
                            .help("到访的下级行政区数（颜色越深 = 覆盖越全）")
                            .accessibilityLabel(Text("到访的下级行政区 \(kidsVisited) 个"))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(verbatim: report.mode == .fog ? "\(s.km2.formatted(Self.km2Style)) km²" : s.points.formatted())
                            .font(.body.monospacedDigit())
                        Text(verbatim: Self.pct(share))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if report.mode == .fog {
                        Text("等级 \(s.level)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                    } else if report.hasTime {
                        Group {
                            if s.firstTime.isFinite { Text("\(s.days) 天") } else { Text(verbatim: "—") }   // 只被无时间尾部覆盖的地区
                        }
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(report.mode == .fog ? "占上一级已探索面积的比例；点一下在地图上高亮并飞过去" : "占上一级点数的比例；点一下在地图上高亮并飞过去")
            if kidsVisited > 0 {
                Button {
                    store.selectRegion(id)
                    path.append(id)
                } label: { Image(systemName: "chevron.right").font(.caption) }
                .buttonStyle(.borderless)
                .help("查看下级行政区")
            } else {
                Color.clear.frame(width: 16, height: 1).accessibilityHidden(true)
            }
        }
        .listRowBackground(selected ? Color.accentColor.opacity(0.18) : nil)
    }

    private func remainderRow(_ rest: Double, report: RegionReport, parentMetric: Double) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "–").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
            Text("其余（未细分 / 下级边界之间）").foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: report.mode == .fog ? "\((rest / 1e6).formatted(Self.km2Style)) km²" : Int(rest).formatted())
                    .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                Text(verbatim: Self.pct(parentMetric > 0 ? rest / parentMetric * 100 : 0))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Color.clear.frame(width: 80, height: 1)
        }
        .help("直接落在上一级、没归到任何下级的部分：没有更细划分的区域、下级边界之间的缝或洞")
    }

    private static let areaStyle = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0))            // 分组，整数
    private static let km2Style = FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.fractionLength(5))
    private static let pct2 = FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.fractionLength(2))
    private static let pctSig = FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.significantDigits(2...3))
    /// 百分比：≥0.1 % 用两位小数，更小的用 2–3 位有效数字（国家级「占本区面积」常只有 0.00x %）
    private static func pct(_ v: Double) -> String { (v >= 0.1 ? v.formatted(pct2) : v.formatted(pctSig)) + " %" }
    private static func day(_ t: Double) -> String {
        Date(timeIntervalSince1970: t).formatted(date: .numeric, time: .omitted)
    }
}

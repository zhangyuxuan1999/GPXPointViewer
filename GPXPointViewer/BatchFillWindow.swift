//
//  BatchFillWindow.swift
//  GPXPointViewer
//
//  批量补点窗口（三步页面）。模型在 BatchFill.swift（无 UI 依赖，离线 harness 也能编）
//

import Foundation
import CoreLocation
// MARK: - 批量补点窗口

import SwiftUI

struct BatchFillWindowView: View {
    @ObservedObject var store: TrackStore
    @ObservedObject private var health = NetworkHealth.shared
    @Environment(\.openWindow) private var openWindow
    @State private var confirmRefetchAll = false // 「重新获取全部…」确认

    var body: some View {
        Group {
            if let st = store.batch, store.batchCompact, let id = st.selectedID, let item = st.items.first(where: { $0.id == id }),
               st.phase == .classify || st.phase == .preview {
                compactView(st, item)
                    .frame(minWidth: 440, maxWidth: .infinity, minHeight: 120, maxHeight: .infinity, alignment: .top)   // 万一窗口没缩成也贴顶，不居中留白
            } else if let st = store.batch {
                Group {
                    switch st.phase {
                    case .classify: classifyView(st)
                    case .running: runningView(st)
                    case .preview, .landing: previewView(st)
                    }
                }
                .frame(minWidth: 820, minHeight: 680)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").font(.largeTitle).foregroundStyle(.secondary)
                    Text("在主窗口进入「补点」模式后，点操作条上的「一键补全部…」开始",
                         comment: "Empty batch window hint; 「补点」 = the Gap Fill mode toggle, 「一键补全部…」 = the Fill All… button in the main window (use the glossary names)")
                        .foregroundStyle(.secondary)
                    if store.fillMode, !store.filteredGapCandidates.isEmpty {
                        Button("开始：对当前 \(store.filteredGapCandidates.count) 处断档分类") { store.startBatchPlanning() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minWidth: 820, minHeight: 680)
            }
        }
        .onAppear { if store.batchCompact { DispatchQueue.main.async { store.dockBatchWindow() } } }   // 重新打开时仍在折叠：按卡片尺寸停靠
        .onChange(of: store.batch?.phase) {
            if store.batch == nil || store.batch?.phase == .running { store.batchCompact = false; store.batchConflictOnly = false; store.batchWarnedOnly = false; store.batchRiskOnly = false }   // 过滤开关不带进下一批
        }
        .alert("重新获取全部？", isPresented: $confirmRefetchAll) {
            Button("重新获取") { store.refetchBatchAll() }
            Button("取消", role: .cancel) {}
        } message: {
            let st = store.batch
            let road = st?.items.filter { $0.kind == .road }.count ?? 0, rail = st?.items.filter { $0.kind == .rail }.count ?? 0
            let minutes = Int((store.batchEstimateSeconds(crossCheck: store.fillCrossCheck) / 60).rounded(.up))
            Text("会忽略缓存，向路网重新请求 \(road + rail) 处断档（公路 \(road) · 铁路 \(rail)），预计约 \(minutes) 分钟。等同于重新跑第 2 步：勾选与手选会重置。",
                 comment: "Batch Gap Fill › Fetch All Again confirmation. Placeholders in order: total gaps to re-request; road gaps; rail gaps; estimated minutes")
        }
    }

    /// 「重新获取全部…」（第 2/3 步）：忽略缓存重跑第 2 步
    private func refetchAllButton(_ st: BatchState) -> some View {
        Button("重新获取全部…") { confirmRefetchAll = true }
            .disabled(st.workCount == 0 || health.offline || st.phase == .landing)
            .help("不用本文件打开以来取过的结果，所有公路/铁路断档重新向路网请求一遍（有确认）；只重取某一处请右键那一行")
    }

    // MARK: 紧凑卡片（点行看地图时）

    private static func statusText(_ item: BatchItem) -> String {
        switch item.status {
        case .pending: return String(localized: "等待", comment: "Batch gap fill: row status, route request not started yet")
        case .running: return String(localized: "请求中", comment: "Batch gap fill: row status, route request in progress")
        case .done:
            guard let d = item.draft else {
                return item.useStraight ? String(localized: "直线（人工选择）", comment: "Batch gap fill: row status, the user chose a straight line for this gap")
                                        : String(localized: "完成", comment: "Batch gap fill: row status, finished")
            }
            if d.source == .deleteOnly {
                let what = d.notes.first ?? String(localized: "不取路径，只删区间内的乱跳点", comment: "Batch gap fill: default explanation of a delete-only row (no route is fetched; only the jitter points inside the gap are deleted)")
                return String(localized: "只删点：\(what)", comment: "Batch gap fill compact card: status of a delete-only row; %@ = explanation")
            }
            let method = d.method?.label ?? "—"
            let basis = String(localized: "依据 \(method)", comment: "Batch gap fill status clause: how the route was obtained; %@ = route method name (Match / Context / Constrained / Direct / Rail / Delete Only)")
            return (draftParts(d) + [basis]).joined(separator: " · ") + shiftText(d) + (d.warnings.isEmpty ? "" : " · ⚠︎ \(d.warnings.count)")
        case .failed(let why):
            return item.deleteOnlyActive
                ? String(localized: "失败，只删乱跳点：\(why)", comment: "Batch gap fill compact card: route request failed, the row will only delete jitter points; %@ = failure reason")
                : String(localized: "失败：\(why)", comment: "Batch gap fill: row status, route request failed; %@ = failure reason")
        case .notTunnel(let why):
            return item.deleteOnlyActive
                ? String(localized: "不补路径，只删乱跳点：\(why)", comment: "Batch gap fill compact card: rail gap is not a tunnel, no path is filled and only jitter points are deleted; %@ = reason")
                : String(localized: "不补：\(why)", comment: "Batch gap fill: row status, rail gap is not a tunnel so it is not filled (glossary 不补 = Don't Fill); %@ = reason")
        case .conflict:
            return conflictText(item)
        case .skipped: return String(localized: "batch.status.skipped", defaultValue: "跳过", comment: "Batch gap fill: row status of a gap that was skipped (a state, e.g. en “Skipped”), not the 跳过/Skip choice button")
        }
    }

    /// 引擎名（不翻译）：OSRM / Valhalla
    private static func engineName(_ s: RouteSource) -> String { s == .osrmCar ? "OSRM" : (s == .valhallaCar ? "Valhalla" : s.label) }

    /// 一路的摘要：OSRM 1.2 km（上下文）
    private static func routeBrief(_ x: RouteDraft) -> String {
        let name = engineName(x.source), len = meters(x.meters), method = x.method?.label ?? "—"
        return String(localized: "\(name) \(len)（\(method)）", comment: "Precise mode: one router's result in a conflict row. Placeholders: router name (OSRM / Valhalla), route length (e.g. 1.2 km), route method (Match / Context / Constrained / Direct)")
    }

    /// 待选一行的摘要。两路不一致：两路各自的来源、长度、依据 + 分歧段；只有一路：那一路 + 另一路为什么没结果
    private static func conflictText(_ item: BatchItem) -> String {
        guard case .conflict(let kind) = item.status else { return "—" }
        switch kind {
        case .disagree:
            guard item.crossDrafts.count == 2 else { return "—" }
            let a = routeBrief(item.crossDrafts[0]), b = routeBrief(item.crossDrafts[1])
            let diverge = meters(item.cross?.divergence ?? 0)
            return String(localized: "两路不一致，请选一条：\(a) / \(b) · 分歧段 \(diverge)", comment: "Precise mode conflict row: the two routers disagree. Placeholders: summary of router 1's route, summary of router 2's route, length of the divergent stretch (e.g. 320 m)")
        case .unverified(let reason):
            guard let d = item.crossDrafts.first else { return "—" }
            let a = routeBrief(d), other = engineName(d.source == .osrmCar ? .valhallaCar : .osrmCar)
            return String(localized: "只有 \(a) 有结果，没比对（\(other)：\(reason)）", comment: "Precise mode conflict row: only one router returned a route. Placeholders: summary of that route, name of the other router, why it gave no result. Keep router names untranslated")
        }
    }

    /// 待选悬停说明：比对原因 + 两路各自的摘要、警告、依据
    private static func conflictHelp(_ item: BatchItem) -> String {
        var lines: [String] = []
        if let r = item.cross {
            lines += r.reasons
            let cov = Int((r.coverage * 100).rounded()), md = Int(r.maxDev.rounded()), un = Int(max(r.uncoveredP, r.uncoveredQ).rounded())
            lines.append(String(localized: "重合 \(cov)% · 最大偏差 \(md) m · 相隔超过容差的部分共 \(un) m", comment: "Precise mode tooltip line with the raw comparison numbers. Placeholders: overlap percent (followed by literal %), maximum deviation in m, total non-overlapping length in m"))
        }
        for x in item.crossDrafts {
            lines.append("")
            let name = engineName(x.source), summary = (draftParts(x) + [x.method?.label ?? "—"]).joined(separator: " · ") + shiftText(x)
            lines.append(String(localized: "— \(name)：\(summary)", comment: "Tooltip header line for one router's route in a precise-mode row. Placeholders: router name (OSRM / Valhalla), route summary (source · length · points · method)"))
            lines += x.warnings.map { "⚠︎ " + $0 } + x.notes.map { "· " + $0 }
        }
        return lines.joined(separator: "\n")
    }

    /// 待选项的选择菜单（表格「落地」列与紧凑卡片共用）：选一路 / 直线（公路）/ 都不补。
    /// 已选「都不补」或已选定的项也用它改选（标签相应变化）
    private func pickMenu(_ item: BatchItem) -> some View {
        Menu {
            ForEach(item.crossDrafts, id: \.source) { x in
                Button(Self.routeBrief(x)) { store.resolveBatchConflict(item.id, .source(x.source)) }
            }
            if item.kind == .road {
                Button { store.resolveBatchConflict(item.id, .straight) } label: {
                    Text(LocalizedStringResource("batch.pick.straight", defaultValue: "直线", comment: "Action: fill this gap with a straight line (menu item / toggle); not the 直线 (straight-line distance) column header"))
                }
            }
            if !item.declined {
                Button("都不补") { store.resolveBatchConflict(item.id, .none) }
            }
            if item.status.isUnverified, !item.declined {
                Divider()
                Button("重新比对这一处（两路重取）") { store.recrossBatchItem(item.id) }
                    .disabled(health.offline)
            }
        } label: {
            if item.declined {
                Text("不补（改选…）", comment: "Menu button on a precise-mode row where the user chose to fill neither route; opens the menu again to change the decision")
            } else if item.status.isConflict {
                Text("选一条…", comment: "Menu button on a precise-mode row waiting for the user's choice between the two routers' routes")
            } else {
                Text("改选…", comment: "Menu button on a precise-mode row the user already decided; opens the menu again to change the decision")
            }
        }
        .fixedSize()
        .help("地图上：实线 = OSRM，虚线 = Valhalla（选中这一行时两条都加粗）。选一条就按它落地；直线 = 两点直连；都不补 = 这处留着不动（两条线还在，随时可改选）")
    }

    /// 草稿摘要的三段：来源 · 距离 · 点数（紧凑卡片和「状态」列共用，调用方用 " · " 连接）
    private static func draftParts(_ d: RouteDraft) -> [String] {
        let n = d.coords.count
        return [d.source.label, meters(d.meters), String(localized: "\(n) 点", comment: "Batch gap fill: number of points in a fetched road draft")]
    }

    private func compactView(_ st: BatchState, _ item: BatchItem) -> some View {
        let c = item.candidate
        let idx = st.items.firstIndex(where: { $0.id == item.id }) ?? 0
        let autoText: String = item.autoKind?.label ?? String(localized: "不确定", comment: "Batch gap fill: automatic road/rail decision could not be made")
        let natureText = Self.natureText(item)
        let winIn = Self.optKmh(c.windowSpeedInKmh), winOut = Self.optKmh(c.windowSpeedOutKmh)
        return VStack(alignment: .leading, spacing: 7) {
            // 模式名 + 来由：用户不知道为什么窗口突然变成这样
            HStack(spacing: 6) {
                Image(systemName: "rectangle.compress.vertical").foregroundStyle(.secondary)
                Text("单处卡片 · 点列表某一行后窗口折叠，方便看主地图",
                     comment: "Batch gap fill compact card title: names the mode and explains why the window shrank (the user clicked a row; the window folds so the main map is visible)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("展开列表") { store.batchCompact = false }
                    .help("回到完整表格（会再挡住地图；点任一行又会折叠）")
            }
            NetworkBanner()
            HStack(spacing: 8) {
                Button { store.selectBatchNeighbor(-1) } label: { Image(systemName: "chevron.left") }.disabled(idx == 0)
                    .help("上一处")
                Text("第 \(idx + 1)/\(st.items.count) 处").font(.headline).monospacedDigit()
                Button { store.selectBatchNeighbor(1) } label: { Image(systemName: "chevron.right") }.disabled(idx >= st.items.count - 1)
                    .help("下一处")
                Spacer()
                if st.phase == .preview {
                    Button("审阅…") { store.openBatchPreview(); openWindow(id: SceneID.changeReview) }
                        .help("在修改记录窗口里预览全部落地效果，逐处决定落不落地")
                }
            }
            Text("\(TrackStore.batchTimeText(c.tA)) · 直线 \(Self.meters(c.meters)) · \(Self.seconds(c.seconds)) · 隐含 \(Int(c.kmh)) km/h",
                 comment: "Batch gap fill compact card, gap facts. Placeholders in order: start time of the gap; straight-line distance with unit (e.g. 1.2 km); duration with unit (e.g. 5 min); implied speed in km/h")
                .font(.callout.monospacedDigit())
            Text("前/后速度 单步 \(c.speedInKmh, specifier: "%.0f")/\(c.speedOutKmh, specifier: "%.0f") · 窗口 \(winIn)/\(winOut) km/h · 自动判断：\(autoText) · 成因：\(natureText)",
                 comment: "Batch gap fill compact card. Placeholders in order: single-step speed before the gap; single-step speed after the gap (km/h); window-average speed before; window-average speed after (number or —); automatic decision (Road / Rail / Uncertain); gap cause (jitter / sparse sampling / signal loss / —)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .help(store.classifyReason(c) + (item.mapNote.map { "\n" + $0 } ?? "") + (item.sampling.map { "\n" + $0.noteText } ?? ""))
            if let t = store.trip(for: c) {
                let tripKindText: String = store.tripKind(t)?.label ?? String(localized: "拿不准", comment: "Batch gap fill: road/rail decision for a trip segment is uncertain")
                let tripBasis: String = store.tripKindOverride[t.index] != nil ? String(localized: "手选", comment: "Batch gap fill: basis of a road/rail decision — chosen by the user")
                    : (store.tripMap[t.index]?.verdict != nil ? String(localized: "地图", comment: "Batch gap fill: basis of a road/rail decision — judged from the map (OpenStreetMap)")
                       : String(localized: "速度", comment: "Batch gap fill: basis of a road/rail decision — judged from speed"))
                HStack(spacing: 8) {
                    Text("第 \(t.index + 1) 段：\(TrackStore.batchTimeText(t.tStart))–\(TrackStore.batchTimeText(t.tEnd)) · \(Int(t.km)) km → \(tripKindText)（\(tripBasis)）",
                         comment: "Batch gap fill compact card, trip segment line. Placeholders in order: segment number; start time; end time; length in km; decision (Road / Rail / Skip / Uncertain); basis of the decision (chosen by user / map / speed)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(store.tripReason(t))
                    Button("本段全按铁路") { store.setTripKind(t.index, .rail) }.font(.caption2)
                    Button("全按公路") { store.setTripKind(t.index, .road) }.font(.caption2)
                }
            }
            if let m = item.mapNote { Text(m).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            if st.phase == .classify {
                HStack(spacing: 10) {
                    Picker("采用", selection: Binding<BatchKind?>(get: { item.kind }, set: { if let k = $0 { store.setBatchKind(item.id, k) } })) {
                        ForEach(BatchKind.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                    if item.autoKind == nil, !item.userSet {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).help("自动判断不了，默认跳过；看地图后选公路或铁路")
                    }
                    Spacer()
                    Toggle("精确模式", isOn: $store.fillCrossCheck).toggleStyle(.checkbox).font(.caption)
                        .help("两路都取、比对；详见展开列表里的说明")
                    Button("取消") { store.closeBatch() }
                    startButton(st)
                }
            } else {
                HStack(spacing: 10) {
                    Text(Self.statusText(item)).font(.caption).lineLimit(item.status.isConflict ? 2 : 1)
                        .help(item.status.isConflict ? Self.conflictHelp(item) : (item.draft.map { ($0.warnings.map { "⚠︎ " + $0 } + $0.notes.map { "· " + $0 }).joined(separator: "\n") } ?? Self.statusText(item)))
                    if let p = item.plausibility, p.level != .low { RiskBadge(p: p, hookTarget: true) }   // 落地前自检：与表格「风险」列同一徽标，点开列原因
                    if item.status.isConflict || (item.status.isDone && item.userPicked && !item.crossDrafts.isEmpty) {
                        pickMenu(item)
                    } else if item.status.isDone, item.otherCrossDraft != nil, st.phase == .preview {
                        Button("改用另一条") { store.swapBatchCross(item.id) }.font(.caption)
                            .help("换成另一路服务给出的路径（两路一致时差别很小）")
                    }
                    if st.pendingPickCount > 0 {
                        Button { store.selectBatchNextConflict() } label: { Text("下一处要选的 ›", comment: "Compact card button: jump to the next gap waiting for the user's choice (precise mode)") }
                            .font(.caption)
                    }
                    if st.phase == .preview, item.kind != nil, item.kind != .skip, item.status != .running {
                        Button { store.refetchBatchItem(item.id) } label: { Image(systemName: "arrow.clockwise") }
                            .font(.caption).disabled(health.offline)
                            .help("重新获取这一处（忽略缓存，只重取这一处；其它处不动）")
                    }
                    Toggle("落地", isOn: Binding(get: { item.willLand }, set: { store.setBatchInclude(item.id, $0) }))
                        .toggleStyle(.checkbox).disabled(item.status.isConflict || (item.draft == nil && !item.useStraight && !item.deleteOnlyActive))
                    if item.status.isFailed, item.kind == .road {
                        Toggle(isOn: Binding(get: { item.useStraight }, set: { store.setBatchStraight(item.id, $0) })) { Text(LocalizedStringResource("batch.pick.straight", defaultValue: "直线", comment: "Action: fill this gap with a straight line (menu item / toggle); not the 直线 (straight-line distance) column header")) }.toggleStyle(.checkbox)
                    }
                    if item.candidate.kind == .jitter, item.draft == nil, !item.useStraight, item.status.isFailed || item.status.isNotTunnel {
                        Toggle("只删乱跳点", isOn: Binding(get: { item.deleteOnly }, set: { store.setBatchDeleteOnly(item.id, $0) })).toggleStyle(.checkbox)
                            .help("取不到路径：勾上则落地时只删两锚点之间的乱跳点、不插点（最多 \(item.candidate.innerCount) 个；沿 A→B 单调推进、车速合理的那一路保留）；两锚点之间只剩保留的那一路，需要的话从 gpx.studio 导")
                    }
                    Spacer()
                    Button("放弃") { store.closeBatch() }
                    Button("落地 \(st.includedCount) 处") { store.landBatch() }
                        .buttonStyle(.borderedProminent)
                        .disabled(st.includedCount == 0 || st.phase == .landing || store.isLoading || st.refetchingCount > 0)
                        .help(st.refetchingCount > 0 ? "有一处正在重新获取，等它取回再落地" : "")
                }
            }
            Text("主地图已飞到这处（两端为锚点，避开面板）· 用 ‹ › 看上一处/下一处").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .fixedSize(horizontal: false, vertical: true)
        // 卡片内容高度回报给 store：窗口高度按它算（原因弹窗是 popover，不改这里的布局，不会触发）
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { store.batchCardContentHeight = $0 }
    }

    // MARK: 第一步：分类

    private func classifyView(_ st: BatchState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NetworkBanner()
            HStack {
                Text("第 1 步 · 每处断档走公路还是铁路").font(.title3.bold())
                Spacer()
                Text("共 \(st.items.count) 处 · 公路 \(st.items.filter { $0.kind == .road }.count) · 铁路 \(st.items.filter { $0.kind == .rail }.count) · 跳过 \(st.items.filter { $0.kind == .skip }.count)（其中自动判断不了默认跳过 \(st.uncertainDefaulted)）",
                     comment: "Batch gap fill step 1 summary. Placeholders in order: total gaps; gaps set to Road; gaps set to Rail; gaps set to Skip; of those skipped, how many were skipped by default because the automatic decision failed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let p = store.samplingProfile {
                Text(p.summary + " → " + p.derivedSummary)
                    .font(.caption).foregroundStyle(.secondary)
                    .help("补点里和点密度有关的判断按这份采样画像换算（专用记录仪与手机的点距、精度差一个量级）")
            }
            if !store.trips.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    // 「段」是什么、为什么按段判：用户看到"行程 1–10"不知所云，这里用大白话说清
                    let judged = store.trips.filter { store.tripMap[$0.index]?.railAnswered ?? 0 > 0 || store.tripKindOverride[$0.index] != nil }.count
                    HStack(spacing: 8) {
                        Text("先按「段」定公路还是铁路", comment: "Batch gap fill step 1 heading: decide road vs rail per trip segment first; 「段」 = the 段 (segment) column / concept explained next to it")
                            .font(.caption.bold())
                        Text("整条轨迹按停车切成 \(store.trips.count) 段（停 ≥10 分钟、或没记录 ≥10 分钟就切一刀）。一段就是一趟连续的行驶，要么全程公路、要么全程火车，所以段里的断档一起定；下面每行是一段，行末选择器整段改。")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            .help("判法：每段抽 3–8 个行驶中的点（车速 ≥30 km/h），问 OpenStreetMap 这些点 150 m 内有没有铁路——贴着铁路（≤30 m）的点占三分之二以上判铁路，离铁路远（≥80 m 或没有）的占三分之二以上判公路，两边都不到就拿不准、退回看整段速度（v95 ≥150 铁路、≤115 公路）。你手选的优先。")
                    }
                    if store.tripMapRunning, let p = store.tripMapProgress {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                ProgressView(value: Double(p.done), total: Double(max(1, p.total))).frame(width: 220)
                                ProgressView().controlSize(.mini)
                                (store.tripMapPhase.isEmpty ? Text("准备…") : Text(verbatim: store.tripMapPhase)).font(.caption).monospacedDigit().lineLimit(1)
                                if let t0 = store.tripMapStarted {
                                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                        Text("已等 \(Int(ctx.date.timeIntervalSince(t0))) s").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                }
                                Button("停止，按表里的判断") { store.cancelTripMap() }
                                    .help("放弃地图判断；每处仍按下表里现在的判断（速度规则 / 你手选的）走，不影响后面取草稿")
                            }
                            Text("正在做什么：把 \(store.trips.count) 段里抽出的点合成 \(p.total) 批，每批去问 Overpass（公共 OpenStreetMap 查询服务，一批要排队 30–60 秒）这些点附近有没有铁路。判完的段会出现在下面（已判 \(judged)/\(store.trips.count) 段）；等不及可以先在下面的表里逐行手选，停止也行。",
                                 comment: "Batch gap fill step 1, progress explanation while trips are judged by map. Placeholders in order: number of trip segments; number of Overpass query batches; segments judged so far; number of trip segments")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                            Text("知道每处是公路还是铁路就不用等这一步：用行末的选择器或「全部公路」「全部铁路」直接定，然后点「开始取路网草稿」——开始按钮不受这里影响；Overpass 慢是常事，点「停止」也不影响后面的步骤。")
                                .font(.caption).foregroundStyle(.orange).lineLimit(2)
                        }
                    } else {
                        HStack(spacing: 8) {
                            (judged < store.trips.count
                                ? Text("已判 \(judged)/\(store.trips.count) 段（没判出来的按整段速度兜底，拿不准的默认跳过）")
                                : Text("已判 \(judged)/\(store.trips.count) 段"))
                                .font(.caption).foregroundStyle(.secondary)
                            Button("重新用地图判断") { store.resolveTripsByMap(force: true) }
                                .help("每段抽 3–8 个行驶中的点，一次 Overpass 查 150 m 内铁路，只按离铁路距离投票")
                        }
                    }
                    // 还没判断出来的段先不列（判断中只会干扰）；判完的按固定列宽对齐
                    let shown = store.trips.filter { t in
                        (st.itemsPerTrip[t.index] ?? 0) > 0 && (!store.tripMapRunning || store.tripMap[t.index]?.railAnswered ?? 0 > 0 || store.tripKindOverride[t.index] != nil)
                    }
                    ScrollView(.vertical) {
                        // 懒加载：全年数据上千段，每行一个分段选择器；非懒的 VStack 每次 store 发布都重建上千个控件
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(shown) { t in
                                let n = st.itemsPerTrip[t.index] ?? 0
                                let basis = tripBasisText(t)
                                let kindText: String = store.tripKind(t)?.label ?? String(localized: "拿不准", comment: "Batch gap fill: road/rail decision for a trip segment is uncertain")
                                HStack(spacing: 8) {
                                    Text("第 \(t.index + 1) 段 · \(TrackStore.batchTimeText(t.tStart)) → \(TrackStore.batchTimeText(t.tEnd)) · \(Int(t.km)) km · \(n) 处断档 · 判定 \(kindText)（\(basis)）",
                                         comment: "Batch gap fill step 1, one row per trip segment. Placeholders in order: segment number; start time; end time; length in km; number of gaps in the segment; decision (Road / Rail / Skip / Uncertain); basis of the decision (chosen by user / map votes / speed fallback)")
                                        .font(.caption).monospacedDigit().lineLimit(1).truncationMode(.middle)
                                        .frame(width: 560, alignment: .leading)
                                        .help(store.tripReason(t))
                                    Picker("整段类别", selection: Binding<Int>(get: { Self.kindTag(store.tripKind(t)) }, set: { store.setTripKind(t.index, Self.tagKind($0)) })) {
                                        Text("公路").tag(1); Text("铁路").tag(2); Text("跳过").tag(3); Text("自动").tag(0)
                                    }
                                    .pickerStyle(.segmented).labelsHidden().frame(width: 250)
                                    .help(Text("整段的所有断档一起按这个类别（会覆盖逐行的选择；「自动」= 回到地图/速度的判断）",
                                               comment: "Help for the per-segment Road/Rail/Skip/Auto picker; 「自动」 = its Auto option"))
                                }
                            }
                            if store.tripMapRunning, shown.count < store.trips.count {
                                Text("还有 \(store.trips.count - shown.count) 段在判断中…").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxHeight: 170)
                }
            }
            let sparseN = st.items.filter { $0.sampling?.nature == .sparseSampling }.count
            if sparseN > 0 {
                HStack(spacing: 8) {
                    Text("其中 \(sparseN) 处是「采样稀疏」（设备本来就隔这么久记一个点，不是信号问题），默认照常列出：补上路网可让迷雾沿路解锁",
                         comment: "Batch gap fill step 1; %lld = number of gaps whose cause is sparse sampling; 「采样稀疏」 = the cause label shown in the 成因 (Cause) column (glossary: sparse sampling)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(LocalSampling.helpText)
                    Button("采样稀疏的全部跳过（\(sparseN) 处）") { store.setBatchSparse(.skip) }
                        .help(Text("只把成因是「采样稀疏」的设为跳过，可逐行改回；省下的是这些处的路网请求",
                                   comment: "Help for the skip-all-sparse-sampling button; 「采样稀疏」 = the cause label in the 成因 (Cause) column (glossary: sparse sampling)"))
                }
            }
            HStack(spacing: 8) {
                let n = st.uncertainDefaulted
                if n > 0 {
                    Text("有 \(n) 处只看速度判断不了（区域列车/ICE 与高速公路速度重叠，或手机跳点让单步速度不可信），已默认跳过。点一行可在地图上看：")
                        .font(.caption)
                    if store.batchResolving {
                        if let p = store.batchResolveProgress {
                            ProgressView(value: Double(p.done), total: Double(max(1, p.total))).frame(width: 120)
                            Text("地图判断 \(p.done)/\(p.total)").font(.caption).monospacedDigit()
                        } else {
                            ProgressView().controlSize(.small)
                            Text("地图判断中…").font(.caption)
                        }
                        Button("停止") { store.cancelBatchResolve() }
                    } else {
                        Button("让地图判断（联网）") { store.resolveBatchUncertainByMap() }
                            .help("两端各查离最近公路（OSRM）和最近铁路（Overpass）的距离：都贴铁路且不贴公路算铁路，都贴公路且离铁路远算公路，否则留给你选。每处 4 次请求，Overpass 约 2 秒一次")
                    }
                    Button("不确定的全部按公路") { store.setBatchUncertain(.road) }
                    Button("不确定的全部按铁路") { store.setBatchUncertain(.rail) }
                } else {
                    Text("全部自动判断完成，可逐行改").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("只补公路（跳过铁路）", isOn: $store.fillRoadOnly).toggleStyle(.checkbox)
                    .help(Text("勾上则铁路一律跳过。不勾时铁路也补，但只补判定为隧道的断档（OSM 铁路 tunnel 标签占 ≥50%、直线 ≤60 km、≤25 分钟），车厢屏蔽的长空洞标「不补」。改动只影响之后的分类，已列出的行用下面按钮或逐行改",
                               comment: "Help for the road-only toggle; ≥50% is a literal percentage; 「不补」 = the Don't Fill status shown in the table (glossary 不补 = Don't Fill)"))
                Button("全部公路") { store.setBatchAll(.road) }
                Button("全部铁路") { store.setBatchAll(.rail) }
                Button("全部跳过") { store.setBatchAll(.skip) }
            }
            .font(.caption)
            if store.batchResolving, !st.progressText.isEmpty {
                Text(st.progressText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("点一行：主地图飞到那处断档（两端设为锚点），自己看是公路还是铁路").font(.caption2).foregroundStyle(.secondary)
            Table(st.items, selection: Binding(get: { st.selectedID }, set: { if let id = $0 { store.selectBatchItem(id) } })) {
                TableColumn(Text("段", comment: "Batch gap fill table column header: trip segment number (a segment = one continuous drive between stops)")) { Text(verbatim: $0.tripIndex >= 0 ? "\($0.tripIndex + 1)" : "—").monospacedDigit() }.width(36)
                TableColumn("时间") { Text(TrackStore.batchTimeText($0.candidate.tA)).monospacedDigit() }.width(110)
                TableColumn("直线") { Text(Self.meters($0.candidate.meters)).monospacedDigit() }.width(70)
                TableColumn("时长") { Text(Self.seconds($0.candidate.seconds)).monospacedDigit() }.width(60)
                TableColumn("隐含速度") { Text(verbatim: "\($0.candidate.kmh.formatted(Fmt.f0)) km/h").monospacedDigit() }.width(80)
                TableColumn("前/后速度（单步 · 窗口）") { item in
                    let c = item.candidate
                    Text(verbatim: "\(c.speedInKmh.formatted(Fmt.f0))/\(c.speedOutKmh.formatted(Fmt.f0)) · \(Self.optKmh(c.windowSpeedInKmh))/\(Self.optKmh(c.windowSpeedOutKmh))").monospacedDigit()
                        .help("单步 = 断档前一步/后一步的速度；窗口 = 从锚点往外第一个 ≥10 s 或 ≥100 m 的点算的平均速度（跨断档或 60 s 内取不到记 —）。判铁路要求单步和窗口都 >170 km/h")
                }.width(125)
                TableColumn("自动判断") { item in
                    Text(Self.autoKindText(item))
                        .foregroundStyle(item.autoKind == nil ? Color.orange : Color.secondary)
                        .help(store.classifyReason(item.candidate) + (item.mapNote.map { "\n" + $0 } ?? ""))
                }.width(70)
                TableColumn("成因") { item in
                    let c = item.candidate
                    Text(Self.causeText(item))
                        .foregroundStyle(c.kind == .jitter ? Color.orange : (item.sampling?.nature == .sparseSampling ? Color.secondary : Color.primary))
                        .help(Self.causeHelp(item))
                }.width(72)
                TableColumn("采用") { item in
                    Picker("采用", selection: Binding<BatchKind?>(get: { item.kind }, set: { if let k = $0 { store.setBatchKind(item.id, k) } })) {
                        ForEach(BatchKind.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 165)
                    .overlay(alignment: .trailing) {
                        if item.autoKind == nil, !item.userSet {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).offset(x: 18)
                                .help("自动判断不了，默认跳过；点这一行在地图上看，再选公路或铁路")
                        }
                    }
                }.width(190)
            }
            HStack {
                Group {
                    if store.fillCrossCheck {
                        Text("精确模式：每处公路同时发给 OSRM 和 Valhalla 两个路线服务（都用 OpenStreetMap 数据，算法不同），几何是同一条路才自动采用，不一致的或只有一路有结果的等你选。两个服务用同一份地图、同一组锚点，锚点本身漂到旁边路上时两边会一起错，这种查不出来。铁路：Overpass 取 OSM 铁路几何，只有一个来源。")
                    } else {
                        Text("公路：OSRM 和 Valhalla 两个路线服务分头取（都用 OpenStreetMap 数据，每处只由其中一个算），带前后轨迹上下文；铁路：Overpass 取 OSM 铁路几何。都是公共服务，1 秒最多 1 个请求，Overpass 常排队 30–60 秒，同一条线上的断档会共用查询。")
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { store.closeBatch() }
                if st.uncertainUnresolved > 0 {
                    Text("还有 \(st.uncertainUnresolved) 处没选").font(.caption).foregroundStyle(.orange)
                }
                crossCheckToggle(st)
                let startHelp: LocalizedStringKey = health.offline ? "当前离线：取路网草稿需要联网"
                    : (store.batchResolving ? "地图判断还在进行，先等它结束或停止" : (st.uncertainUnresolved > 0 ? "还有 \(st.uncertainUnresolved) 处没选" : ""))
                startButton(st)
                    .help(startHelp)
            }
        }
        .padding(16)
    }

    // MARK: 第二步：进行中

    private func runningView(_ st: BatchState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NetworkBanner()
            Text("第 2 步 · 正在取路网草稿").font(.title3.bold())
            let total = st.workCount
            let done = st.items.filter { $0.status.isFinished }.count
            ProgressView(value: Double(done), total: Double(max(1, total)))
            if let note = st.engineDisabled { Text(note).font(.caption).foregroundStyle(.orange) }
            HStack {
                Text(st.progressText).font(.caption)
                Spacer()
                if let t0 = st.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("已用 \(Int(ctx.date.timeIntervalSince(t0))) s · 请求 \(st.requestsMade)").font(.caption).foregroundStyle(.secondary)
                            .help(Text(verbatim: st.requestsByHost.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")))
                    }
                }
                refetchAllButton(st)
                Button("取消") { store.cancelBatch() }
            }
            if store.fillCrossCheck {
                Text("正在做什么：精确模式——每处公路断档同时发给 OSRM 和 Valhalla 两个路线服务（都用 OpenStreetMap 数据，算法不同），取回后比对几何：走的是同一条路才自动采用，不一致的、或只有一路有结果的等你在地图上选。每个服务仍是 1 秒最多 1 次，所以耗时约为普通模式的两倍。")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            } else {
                Text("正在做什么：把每处断档两端的坐标（连同前后一小段真实轨迹）发给公共路线服务，要回「车在路上会怎么走」的道路几何。OSRM 和 Valhalla 是两个都用 OpenStreetMap 数据的免费路线服务，各开一路同时取（每个服务 1 秒最多 1 次，所以快不了更多）。")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
            qualityBar(st)
            resultsTable(st)
        }
        .padding(16)
    }

    /// ✓ / ⚠ / ✗ 统计 + 「只看有疑点的」过滤 + 图例（第 2、3 步共用）
    private func qualityBar(_ st: BatchState) -> some View {
        let ok = st.items.filter { $0.status.isDone && $0.draft != nil && $0.draft?.source != .deleteOnly && ($0.draft?.warnings.isEmpty ?? true) }.count   // 直线（人工选择）不算"取到"
        let warned = st.items.filter { $0.status.isDone && $0.draft?.source != .deleteOnly && !($0.draft?.warnings.isEmpty ?? true) }.count
        let bad = st.items.filter { $0.status.isFailed }.count
        let nt = st.items.filter { $0.status.isNotTunnel }.count
        return HStack(spacing: 10) {
            HStack(spacing: 4) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text("取到、没疑点 \(ok)") }
            HStack(spacing: 4) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text("取到、有疑点 \(warned)") }
                .help("有疑点 = 道路几何取到了，但有一条或多条异常：绕路明显、路径比直线长太多、两端离路远、按断档时长算车速不合理、没能按行进方向约束等。悬停某一行的状态看具体是哪条；落地前建议点进去在地图上看一眼")
            HStack(spacing: 4) { Image(systemName: "xmark.circle.fill").foregroundStyle(.red); Text("失败 \(bad)") }
            if nt > 0 {
                HStack(spacing: 4) { Image(systemName: "minus.circle").foregroundStyle(.secondary); Text("铁路不像隧道、不补 \(nt)") }
                    .help(Text("铁路断档只补判定为隧道的：A–B 铁路路径里 OSM tunnel 标签段占 ≥50%，且直线 ≤60 km、时长 ≤25 分钟。其余多半是车厢里收不到信号，不补，需要的话从 gpx.studio 导",
                               comment: "Help for the rail-not-a-tunnel count in the batch quality bar; ≥50% is a literal percentage; A–B = the two gap anchors"))
            }
            if store.fillCrossCheck || st.agreeCount > 0 || st.conflictCount > 0 {
                let agree = st.agreeCount, disagree = st.disagreeCount, unverified = st.unverifiedCount
                HStack(spacing: 4) { Image(systemName: "checkmark.seal").foregroundStyle(.blue); Text("两路一致 \(agree)") }
                    .help("OSRM 与 Valhalla 给出的是同一条路（绝大部分相距不到 10 m，只允许不超过几十米的一小段分开）。一致只说明两个服务看法相同，不等于路一定对：锚点本身漂到旁边路上时两边会一起错，这种情况会另加一条疑点")
                if disagree > 0 {
                    HStack(spacing: 4) { Image(systemName: "arrow.triangle.branch").foregroundStyle(.blue); Text("两路不一致、要你选 \(disagree)") }
                        .help("OSRM 与 Valhalla 给出的不是同一条路。点一行，主地图上实线 = OSRM、虚线 = Valhalla（都是蓝色）；看清后点「选一条…」，不选就不落地")
                }
                if unverified > 0 {
                    HStack(spacing: 4) { Image(systemName: "questionmark.circle").foregroundStyle(.blue); Text("只有一路有结果、没比对 \(unverified)") }
                        .help("另一路没给出结果（连不上、没路或已停用），没法比对。可逐处采用，或在第 3 步一键全部采用（效果等于普通模式）")
                    if st.phase == .preview {
                        Button { store.recrossUnverifiedAll() } label: {
                            Text("全部重新比对 \(unverified) 处", comment: "Batch quality bar button (precise mode): fetch both routers again (ignoring the cache) for every gap where only one router answered; %lld = how many")
                        }
                        .controlSize(.small)
                        .disabled(health.offline)
                        .help("对「只有一路有结果」的这些处两路都重取（忽略缓存）再比对；其它处不动")
                    }
                }
                if disagree + unverified > 0 {
                    Toggle(isOn: $store.batchConflictOnly) { Text("只看要你选的") }
                        .toggleStyle(.checkbox)
                        .onChange(of: store.batchConflictOnly) { _, on in if on { store.batchWarnedOnly = false; store.batchRiskOnly = false } }
                }
            }
            let del = st.items.filter { $0.landsDeleteOnly && $0.include }.count
            if del > 0 {
                let pts = st.items.filter { $0.landsDeleteOnly && $0.include }.reduce(0) { $0 + $1.candidate.innerCount }
                HStack(spacing: 4) { Image(systemName: "eraser").foregroundStyle(.orange); Text("乱跳只删点 \(del) 处 · 最多删 \(pts) 点") }
                    .help("乱跳段不取路径（铁路不像隧道 / 两锚点太近 / 隐含速度不合理 / 只补公路下的铁路乱跳 / 路网判定失败）：落地时只删两锚点之间的乱跳点，不插点；沿 A→B 单调推进、车速合理的那一路会保留，所以实际删的少于这个数。网络连不上的失败不默认删点。逐行可关")
            }
            Toggle(isOn: $store.batchWarnedOnly) { Text("只看有疑点的 \(warned) 处") }
                .toggleStyle(.checkbox)
                .disabled(warned == 0)
                .onChange(of: store.batchWarnedOnly) { _, on in if on { store.batchConflictOnly = false; store.batchRiskOnly = false } }
                .help("表格只列有疑点的；点一行主地图飞过去，橙线就是这处的草稿")
            let look = st.items.filter { TrackStore.batchNeedsLook($0) }.count
            if look > 0 || store.batchRiskOnly {
                Toggle(isOn: $store.batchRiskOnly) { Text("只看要看一眼的 \(look) 处", comment: "Batch gap fill filter checkbox: show only rows whose pre-apply self-check is high (要看一眼) or medium (留意); %lld = how many") }
                    .toggleStyle(.checkbox)
                    .disabled(look == 0)
                    .onChange(of: store.batchRiskOnly) { _, on in if on { store.batchConflictOnly = false; store.batchWarnedOnly = false } }
                    .help(Text("表格只列落地前自检判为「要看一眼」或「留意」的；点徽标看原因，点一行主地图飞过去", comment: "Help for the show-only-risky filter; 「要看一眼」/「留意」 are the two risk badge texts"))
            }
            Spacer()
            Text("依据：匹配 = 按前后真实点做地图匹配 · 上下文 = 从前后真实点路由再裁 · 约束 = 带行进方向 · 直接 = 两点最短路")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.caption)
    }

    // MARK: 第三步：预览

    private func previewView(_ st: BatchState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NetworkBanner()
            HStack {
                Text("第 3 步 · 预览").font(.title3.bold())
                Spacer()
                Text(Self.previewSummary(st))
                    .font(.caption).foregroundStyle(.secondary)
            }
            qualityBar(st)
            let methods = st.items.compactMap { $0.draft?.method }
            if !methods.isEmpty {
                let nMatch = methods.filter { $0 == .match }.count, nContext = methods.filter { $0 == .context }.count, nConstraint = methods.filter { $0 == .constraint }.count
                let nDirect = methods.filter { $0 == .direct }.count, nRail = methods.filter { $0 == .rail }.count
                Text("各处怎么取到的：匹配 \(nMatch) · 上下文 \(nContext) · 约束 \(nConstraint) · 直接 \(nDirect) · 铁路 \(nRail)",
                     comment: "Batch gap fill step 3: how many drafts each route method produced. Placeholders in order: Match; Context; Constrained; Direct; Rail (use the same method names as the 依据/Basis column)")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(Text("「直接」是两点间最短路，没用到前后轨迹，建议逐处看一眼",
                               comment: "Help on the per-method counts; 「直接」 = the Direct route method (glossary: Direct)"))
            }
            Text("主地图上画出了每处草稿：绿 = 取到路网，橙 = 取到但有警告，灰 = 用直线补，红虚线 = 失败/不落地（淡色 = 没勾选）。点一行飞过去查看；不满意的取消勾选，落地后可在补点模式里单独改。右键一行可只重新获取那一处。")
                .font(.caption).foregroundStyle(.secondary)
            if st.cacheHits > 0 {
                Text("\(TrackStore.cacheHitsText(st.cacheHits))：这些处用的是本文件打开以来取过的路网结果，没有再请求；要重新向路网取请用「重新获取全部…」或右键某一行", comment: "Batch Gap Fill step 3 note under the summary; %@ = the “N gaps served from cache” clause")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if st.conflictCount > 0 {
                Text("等你选的那些处两路都画出来（蓝色）：实线 = OSRM、虚线 = Valhalla，选中一行两条都加粗。看清哪条对，点该行的「选一条…」；不选就不落地。")
                    .font(.caption).foregroundStyle(.blue)
            }
            resultsTable(st)
            HStack {
                Button("审阅落地效果…") { store.openBatchPreview(); openWindow(id: SceneID.changeReview) }
                    .help("像修改记录那样看：总览整条轨迹上会补哪里，‹ › 逐处看将新增的点（绿）和将被替换的点（红），逐处决定落不落地，看完在那里一键落地")
                Button("全部勾选成功的") { store.setBatchIncludeAllDone() }
                Button("失败的公路全用直线") {
                    for it in st.items where it.status.isFailed && it.kind == .road { store.setBatchStraight(it.id, true) }
                }
                .help("只对公路：铁路断档不给直线兜底（隧道判定不通过的就不补）")
                let unverifiedN = st.unverifiedCount
                if unverifiedN > 0 {
                    Button { store.acceptUnverifiedAll() } label: {
                        Text("只有一路结果的 \(unverifiedN) 处全部采用", comment: "Button (precise mode): accept the single router result for every gap that could not be cross-checked; %lld = how many")
                    }
                    .help("另一路没给出结果、没法比对的那些处，一律采用唯一的那份（效果等于普通模式；记录里会写明未交叉验证）")
                }
                let directN = st.items.filter { $0.draft?.method == .direct && $0.include && !$0.userPicked }.count   // 与 setBatchIncludeMethod 同口径：手选的不动
                Button { store.setBatchIncludeMethod(.direct, false) } label: {
                    Text("取消勾选「直接」的 \(directN) 处", comment: "Button: untick all drafts obtained with the Direct route method; 「直接」 = Direct (glossary); %lld = how many")
                }
                    .disabled(directN == 0)
                    .help(Text("「直接」没有用到前后轨迹，最容易绕路或接错路；取消后可在补点模式里逐处处理",
                               comment: "Help for the untick-Direct button; 「直接」 = the Direct route method (glossary: Direct)"))
                refetchAllButton(st)
                Spacer()
                if st.pendingPickCount > 0 {
                    let k = st.pendingPickCount
                    Text("还有 \(k) 处等你选，落地后这些不补", comment: "Hint next to the Apply button (precise mode): gaps still waiting for the user's choice will not be filled; %lld = how many")
                        .font(.caption).foregroundStyle(.orange)
                    Button { store.selectBatchNextConflict() } label: { Text("去选 ›", comment: "Button next to the Apply button: jump to the next gap waiting for the user's choice") }
                }
                Button("放弃") { store.closeBatch() }
                Button("落地 \(st.includedCount) 处") { store.landBatch() }
                    .buttonStyle(.borderedProminent)
                    .disabled(st.includedCount == 0 || st.phase == .landing || store.isLoading || st.refetchingCount > 0)
                    .help(st.refetchingCount > 0 ? "有一处正在重新获取，等它取回再落地" : "")
            }
        }
        .padding(16)
    }

    /// 精确模式开关 + 预计用时（第 1 步开始按钮旁）
    private func crossCheckToggle(_ st: BatchState) -> some View {
        let precise = Int((store.batchEstimateSeconds(crossCheck: true) / 60).rounded(.up)), normal = Int((store.batchEstimateSeconds(crossCheck: false) / 60).rounded(.up))
        return Toggle(isOn: $store.fillCrossCheck) {
            Text("精确模式（两路都取、比对；预计约 \(precise) 分钟，普通约 \(normal) 分钟）", comment: "Precise-mode toggle in batch step 1. Placeholders: estimated minutes in precise mode, estimated minutes in normal mode")
        }
        .toggleStyle(.checkbox).font(.caption)
        .help(Text("每处公路断档同时向 OSRM 和 Valhalla 两个路线服务请求并比对几何：是同一条路才自动采用；不一致的、或只有一路给出结果的，等你在地图上比较后选一条，不选就不落地。能查出：一路吸到匝道/辅路/对向车道、一路绕远。查不出：两个服务用同一份 OpenStreetMap 和同一组锚点，锚点本身漂到旁边路上时两边会一起错。铁路只有 Overpass 一个来源，不比对",
                   comment: "Help for the precise-mode (cross-check) toggle. Keep OSRM, Valhalla, OpenStreetMap and Overpass untranslated"))
    }

    /// 开始按钮（第 1 步与紧凑卡片共用）：精确模式时标出来
    private func startButton(_ st: BatchState) -> some View {
        let n = st.workCount
        return Button {
            store.runBatch()
        } label: {
            store.fillCrossCheck
                ? Text("开始取路网草稿（\(n) 处 · 精确模式）", comment: "Start button of batch gap fill when precise mode is on; %lld = number of gaps")
                : Text("开始取路网草稿（\(n) 处）", comment: "Start button of batch gap fill; %lld = number of gaps")
        }
        .buttonStyle(.borderedProminent)
        .disabled(st.uncertainUnresolved > 0 || st.workCount == 0 || store.batchResolving || health.offline)
    }

    /// 第 3 步行顺序：落地前自检 high → medium → 其它，各自保持原时间序（Opus 接界面时可换成可切换的排序）
    static func riskSorted(_ items: [BatchItem]) -> [BatchItem] {
        func rank(_ it: BatchItem) -> Int { it.plausibility?.level == .high ? 0 : (it.plausibility?.level == .medium ? 1 : 2) }
        return items.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    private func resultsTable(_ st: BatchState) -> some View {
        let rows = store.batchVisibleRows(st)      // 过滤 + 风险排序；过滤结果为空时回到全表
        return Table(rows, selection: Binding(get: { st.selectedID }, set: { if let id = $0 { store.selectBatchItem(id) } })) {
            TableColumn("时间") { Text(TrackStore.batchTimeText($0.candidate.tA)).monospacedDigit() }.width(110)
            TableColumn("直线") { Text(Self.meters($0.candidate.meters)).monospacedDigit() }.width(70)
            TableColumn("类型") { Text($0.kind?.label ?? "—") }.width(50)
            TableColumn("风险") { item in
                // 落地前自检徽标：high「要看一眼」（红）/ medium「留意」（橙）/ low 空；悬停列原因
                if let p = item.plausibility, p.level != .low {
                    RiskBadge(p: p)
                } else if let p = item.plausibility {
                    Text(verbatim: "\(p.risk)").font(.caption).foregroundStyle(.secondary).help(p.summaryLine)
                } else {
                    Text(verbatim: "—").foregroundStyle(.secondary)
                }
            }.width(96)
            TableColumn("依据") { item in
                Text(verbatim: item.status.isConflict ? item.crossDrafts.map { $0.method?.label ?? "—" }.joined(separator: " / ") : (item.draft?.method?.label ?? "—"))
                    .help("匹配 = OSRM 按前后真实轨迹点做地图匹配；上下文 = 从 A 前/B 后的真实点路由再裁到 A–B；约束 = 带两端行进方向的路由；直接 = 两点最短路（没有用到前后轨迹，最容易绕路或接错路）；铁路 = Overpass 铁路几何")
            }.width(56)
            TableColumn("疑点") { item in
                let w = item.status.isConflict ? [Self.conflictText(item)] : (item.draft?.warnings ?? [])
                Text(Self.warningsText(item))
                    .foregroundStyle(w.isEmpty ? Color.secondary : Color.orange)
                    .lineLimit(1).truncationMode(.tail)
                    .help(w.isEmpty ? "" : w.map { "⚠︎ " + $0 }.joined(separator: "\n"))
            }.width(min: 160, ideal: 260)
            TableColumn("状态") { item in
                switch item.status {
                case .pending: Text("等待").foregroundStyle(.secondary)
                case .running: HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("请求中") }
                case .done where item.draft == nil:
                    Text(Self.statusText(item)).foregroundStyle(.secondary)
                case .done:
                    let d = item.draft!
                    HStack(spacing: 4) {
                        Image(systemName: d.source == .deleteOnly ? "eraser" : (d.warnings.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                            .foregroundStyle(d.source == .deleteOnly ? Color.orange : (d.warnings.isEmpty ? Color.green : Color.orange))
                        (d.source == .deleteOnly
                            ? Text("只删点 · 区间内 \(item.candidate.innerCount) 个乱跳点")
                            : Text(verbatim: Self.draftParts(d).joined(separator: " · ") + Self.shiftText(d)))
                    }
                    .help((d.warnings.map { "⚠︎ " + $0 } + d.notes.map { "· " + $0 }).joined(separator: "\n"))
                case .failed(let why):
                    (item.deleteOnlyActive ? Text("失败 · 将只删乱跳点：\(why)") : Text("失败：\(why)"))
                        .foregroundStyle(.red).lineLimit(1).help(why)
                case .notTunnel(let why):
                    HStack(spacing: 4) {
                        Image(systemName: item.deleteOnlyActive ? "eraser" : "minus.circle").foregroundStyle(item.deleteOnlyActive ? Color.orange : Color.secondary)
                        (item.deleteOnlyActive ? Text("不补路径 · 将只删乱跳点：\(why)") : Text("不补：\(why)"))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help(why + "\n\n" + String(localized: "铁路只补判定为隧道的断档：OSM 铁路线段自带 tunnel 标签，裁出的 A–B 路径里隧道占比 ≥50% 才补；车厢里收不到信号造成的长空洞请从 gpx.studio 导入",
                                                comment: "Batch gap fill status tooltip paragraph after the not-a-tunnel reason; ≥50% is a literal percentage; A–B = the two gap anchors"))
                case .conflict(let kind):
                    HStack(spacing: 4) {
                        Image(systemName: kind == .disagree ? "arrow.triangle.branch" : "questionmark.circle").foregroundStyle(Color.blue)
                        Text(verbatim: Self.conflictText(item)).foregroundStyle(Color.blue).lineLimit(1)
                    }
                    .help(Self.conflictHelp(item))
                case .skipped:
                    Text(LocalizedStringResource("batch.status.skipped", defaultValue: "跳过", comment: "Batch gap fill: row status of a gap that was skipped (a state, e.g. en “Skipped”), not the 跳过/Skip choice button"))
                        .foregroundStyle(.secondary)
                }
            }
            TableColumn("落地") { item in
                if item.status.isConflict, st.phase == .preview || st.phase == .running {
                    pickMenu(item)                         // 待选：选了才落地
                } else if st.phase == .preview || st.phase == .landing {
                    HStack(spacing: 8) {
                        if item.status.isDone, item.userPicked, !item.crossDrafts.isEmpty {
                            pickMenu(item)                 // 已选定的可改选
                        } else if item.status.isDone, item.otherCrossDraft != nil {
                            Button { store.swapBatchCross(item.id) } label: { Image(systemName: "arrow.left.arrow.right") }
                                .buttonStyle(.borderless)
                                .help("改用另一路服务给出的路径")
                        }
                        Toggle("落地", isOn: Binding(get: { item.willLand }, set: { store.setBatchInclude(item.id, $0) }))
                            .labelsHidden().disabled(item.draft == nil && !item.useStraight && !item.deleteOnlyActive)
                        if item.status.isFailed, item.kind == .road {
                            Toggle(isOn: Binding(get: { item.useStraight }, set: { store.setBatchStraight(item.id, $0) })) { Text(LocalizedStringResource("batch.pick.straight", defaultValue: "直线", comment: "Action: fill this gap with a straight line (menu item / toggle); not the 直线 (straight-line distance) column header")) }
                                .font(.caption)
                        }
                        if item.candidate.kind == .jitter, item.draft == nil, !item.useStraight, item.status.isFailed || item.status.isNotTunnel {
                            Toggle("删点", isOn: Binding(get: { item.deleteOnly }, set: { store.setBatchDeleteOnly(item.id, $0) }))
                                .font(.caption)
                                .help("取不到路径：勾上则只删两锚点之间的乱跳点、不插点（最多 \(item.candidate.innerCount) 个；沿 A→B 单调推进、车速合理的那一路保留）")
                        }
                    }
                }
            }.width(110)
        }
        .contextMenu(forSelectionType: GapID.self) { ids in
            // 右键一行：只重取这一处（忽略缓存）。第 3 步可用；多选时逐个
            let targets = ids.compactMap { id in st.items.first { $0.id == id } }.filter { $0.kind != nil && $0.kind != .skip && $0.status != .running }
            if st.phase == .preview, !targets.isEmpty {
                Button {
                    for t in targets { store.refetchBatchItem(t.id) }
                } label: {
                    if targets.count == 1 { Text("重新获取这一处（忽略缓存）") }
                    else { Text("重新获取这 \(targets.count) 处（忽略缓存）", comment: "Batch Gap Fill table context menu with several rows selected; %lld = number of gaps to fetch again") }
                }
                .disabled(health.offline)
                let unv = targets.filter { $0.status.isUnverified && !$0.declined }
                if !unv.isEmpty {
                    Button {
                        for t in unv { store.recrossBatchItem(t.id) }
                    } label: {
                        if unv.count == 1 { Text("重新比对这一处（两路重取）") }
                        else { Text("重新比对这 \(unv.count) 处（两路重取）", comment: "Batch Gap Fill table context menu, several rows selected: fetch both routers again for the selected gaps that have only one router's result; %lld = how many") }
                    }
                    .disabled(health.offline)
                }
            }
        }
    }

    private static func meters(_ m: Double) -> String { m >= 1000 ? "\((m / 1000).formatted(Fmt.f1)) km" : "\(m.formatted(Fmt.f0)) m" }
    /// 隧道口漂移导致的锚点外挪
    static func shiftText(_ d: RouteDraft) -> String {
        var parts: [String] = []
        let a = d.shiftA, b = d.shiftB
        if a > 0 { parts.append(String(localized: "A 前移 \(a) 点", comment: "Gap fill draft: anchor A was moved back by %lld track points (GPS drift at a tunnel portal)")) }
        if b > 0 { parts.append(String(localized: "B 后移 \(b) 点", comment: "Gap fill draft: anchor B was moved forward by %lld track points (GPS drift at a tunnel portal)")) }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: Fmt.listSeparator)
    }
    private static func optKmh(_ v: Double?) -> String { v.map { $0.formatted(Fmt.f0) } ?? "—" }
    private static func kindTag(_ k: BatchKind?) -> Int { switch k { case .road?: return 1; case .rail?: return 2; case .skip?: return 3; case nil: return 0 } }
    private static func tagKind(_ t: Int) -> BatchKind? { t == 1 ? .road : (t == 2 ? .rail : (t == 3 ? .skip : nil)) }
    private static func seconds(_ s: Double) -> String { s >= 60 ? "\((s / 60).formatted(Fmt.f0)) min" : "\(s.formatted(Fmt.f0)) s" }

    /// 「成因」：乱跳 / 采样稀疏 / 信号中断（没有采样信息时 —）
    private static func natureText(_ item: BatchItem) -> String {
        item.candidate.kind == .jitter
            ? String(localized: "乱跳", comment: "Batch gap fill: gap cause — jitter, positions jumping back and forth (glossary 乱跳 = jitter)")
            : (item.sampling.map { $0.nature.label } ?? "—")
    }

    /// 「自动判断」列：公路 / 铁路；判断不了时「不确定」，有地图依据时「地图」
    private static func autoKindText(_ item: BatchItem) -> String {
        if let label = item.autoKind?.label { return label }
        return item.mapNote == nil
            ? String(localized: "不确定", comment: "Batch gap fill: automatic road/rail decision could not be made")
            : String(localized: "地图", comment: "Batch gap fill: basis of a road/rail decision — judged from the map (OpenStreetMap)")
    }

    /// 「成因」列文字：多处并成一群时前缀「群×N」
    private static func causeText(_ item: BatchItem) -> String {
        let nature = natureText(item)
        let n = item.candidate.chainCount
        return n > 1 ? String(localized: "群×\(n) \(nature)", comment: "Batch gap fill 成因 (Cause) column: %lld adjacent gaps merged into one group, then the cause (%@: jitter / sparse sampling / signal loss / —)") : nature
    }

    /// 「成因」列的悬停说明：乱跳段落、并群说明、采样说明、本处采样备注，各段之间的换行在代码里拼
    private static func causeHelp(_ item: BatchItem) -> String {
        let c = item.candidate
        var help = ""
        if c.kind == .jitter {
            let inner = c.innerCount, jumps = c.jitterJumps, revs = c.jitterReversals, maxJump = Int(c.jitterMaxJump)
            help += String(localized: "乱跳：两锚点之间 \(inner) 个点在相隔几百米到几公里的位置之间来回跳（大跳 \(jumps) 步、倒退 \(revs) 步，最大一步 \(maxJump) m）——车厢里没信号时设备回放旧位置或两路定位交替。有路径就整段替换，取不到路径就只删这些点",
                           comment: "Batch gap fill 成因 (Cause) tooltip for a jitter gap. Placeholders in order: points between the two anchors; big jumps (steps); reversals (steps); largest single step in metres (glossary: 乱跳 jitter, 大跳 big jumps, 倒退 reversals)") + "\n\n"
        }
        if c.chainCount > 1 {
            if c.kind == .jitter {
                let others = c.chainCount - 1
                help += String(localized: "乱跳段与相邻的 \(others) 处断档并成一处，整段一起处理", comment: "Batch gap fill 成因 tooltip: a jitter stretch was merged with %lld neighbouring gaps and is handled as one") + "\n"
            } else {
                let n = c.chainCount, inner = c.innerCount
                help += String(localized: "隧道群：由 \(n) 处相邻断档并成，中间夹的 \(inner) 个点随区间替换", comment: "Batch gap fill 成因 tooltip: tunnel group made of %1$lld adjacent gaps; the %2$lld points between them are replaced with the range") + "\n"
            }
        }
        return help + LocalSampling.helpText + "\n" + (item.sampling?.noteText ?? "")
    }

    /// 「疑点」列：没有疑点时「无」（还没完成时 —）；多条时前缀条数
    private static func warningsText(_ item: BatchItem) -> String {
        if item.status.isDisagree { return String(localized: "两路不一致", comment: "Batch gap fill 疑点 (Issues) column for a precise-mode row where the routers disagree") }
        if item.status.isUnverified { return String(localized: "没比对", comment: "Batch gap fill 疑点 (Issues) column for a precise-mode row where only one router answered") }
        let w = item.draft?.warnings ?? []
        guard let first = w.first else {
            return item.status.isDone ? String(localized: "无", comment: "Batch gap fill 疑点 (Issues) column: the draft has no issues") : "—"
        }
        let n = w.count
        return n > 1 ? String(localized: "\(n) 条：\(first)", comment: "Batch gap fill 疑点 (Issues) column: %lld = number of warnings, %@ = text of the first warning") : first
    }

    /// 第 3 步标题行的统计：每项独立成句，可选项按条件加入，用 " · " 连接
    private static func previewSummary(_ st: BatchState) -> String {
        let ok = st.items.filter { $0.status.isDone && $0.draft != nil && $0.draft?.source != .deleteOnly }.count   // 直线（人工选择）不算成功
        let bad = st.items.filter { $0.status.isFailed }.count
        let nt = st.items.filter { $0.status.isNotTunnel }.count
        let delOnly = st.items.filter { $0.landsDeleteOnly && $0.include }.count
        let skipped = st.items.filter { $0.status == .skipped }.count
        let included = st.includedCount
        var parts = [String(localized: "成功 \(ok)", comment: "Batch gap fill step 3 summary: %lld gaps got a road draft"),
                     String(localized: "失败 \(bad)", comment: "Batch gap fill summary: %lld route requests failed")]
        if nt > 0 { parts.append(String(localized: "铁路不像隧道不补 \(nt)", comment: "Batch gap fill step 3 summary: %lld rail gaps are not tunnels and are not filled")) }
        let disagree = st.disagreeCount, unverified = st.unverifiedCount
        if disagree > 0 { parts.append(String(localized: "两路不一致 \(disagree)", comment: "Batch gap fill step 3 summary (precise mode): %lld gaps where the two routers disagree, waiting for the user's choice")) }
        if unverified > 0 { parts.append(String(localized: "没比对 \(unverified)", comment: "Batch gap fill step 3 summary (precise mode): %lld gaps where only one router answered")) }
        let declined = st.declinedCount
        if declined > 0 { parts.append(String(localized: "选了不补 \(declined)", comment: "Batch gap fill step 3 summary (precise mode): %lld gaps where the user chose to fill neither route")) }
        let high = st.highRiskCount, medium = st.mediumRiskCount
        if high + medium > 0 { parts.append(String(localized: "要看一眼 \(high) · 留意 \(medium)", comment: "Batch gap fill step 3 summary: pre-apply self-check counts. %1$lld = rows with the high-risk badge 要看一眼, %2$lld = rows with the medium badge 留意 (use the same badge texts)")) }
        if delOnly > 0 { parts.append(String(localized: "乱跳只删点 \(delOnly)", comment: "Batch gap fill step 3 summary: %lld jitter gaps will only have their jitter points deleted")) }
        parts.append(String(localized: "跳过 \(skipped)", comment: "Batch gap fill step 3 summary: %lld gaps were skipped"))
        parts.append(String(localized: "勾选落地 \(included)", comment: "Batch gap fill step 3 summary: %lld gaps are ticked to be applied (glossary 落地 = Apply)"))
        if st.cacheHits > 0 { parts.append(TrackStore.cacheHitsText(st.cacheHits)) }
        return parts.joined(separator: " · ")
    }

    /// 段条每行括号里的判定依据：手选 / 地图票数 / 按速度兜底
    private func tripBasisText(_ t: Trip) -> String {
        if store.tripKindOverride[t.index] != nil {
            return String(localized: "手选", comment: "Batch gap fill: basis of a road/rail decision — chosen by the user")
        }
        let v95 = Int(t.v95)
        guard let e = store.tripMap[t.index] else {
            return String(localized: "还没用地图，按速度 v95 \(v95)", comment: "Batch gap fill trip basis: map not queried yet, decided by speed; %lld = 95th-percentile speed in km/h")
        }
        let answered = e.railAnswered, votes = e.railVotes
        if e.verdict != nil {
            return String(localized: "地图：\(answered) 个点里 \(votes) 个贴铁路", comment: "Batch gap fill trip basis: decided by map; %1$lld = sampled points with rail data, %2$lld = of those, points lying on a railway")
        }
        if answered > 0 {
            return String(localized: "地图拿不准（\(votes)/\(answered) 贴铁路），按速度 v95 \(v95)", comment: "Batch gap fill trip basis: map inconclusive, fell back to speed. Placeholders in order: points on a railway; sampled points with rail data; 95th-percentile speed in km/h")
        }
        return String(localized: "没拿到地图数据，按速度 v95 \(v95)", comment: "Batch gap fill trip basis: no map data received, decided by speed; %lld = 95th-percentile speed in km/h")
    }
}

/// 落地前自检徽标（批量表格「风险」列、单处卡片、补点操作条共用）：high「要看一眼」红、medium「留意」黄橙（和「疑点」的橙色区分）、
/// low 不显示。点一下弹出原因：每条前加 ⚠︎，底部一行「风险 N / 100 · 等级」
struct RiskBadge: View {
    let p: FillPlausibility
    var hookTarget = false       // 自测钩子 riskpopover 只打开这一个（单处卡片 / 补点操作条那枚）
    @State private var show = false
    static let hookOpen = Notification.Name("RiskBadge.hookOpen")
    /// medium 用黄橙（琥珀色），「疑点」列保持系统橙
    static let mediumColor = Color(red: 0.86, green: 0.62, blue: 0.0)
    static func color(_ level: FillPlausibility.Level) -> Color { level == .high ? .red : mediumColor }

    var body: some View {
        if p.level != .low {
            let c = Self.color(p.level)
            Button { show.toggle() } label: {
                Text(verbatim: p.badge)
                    .font(.caption).fontWeight(.semibold)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(c.opacity(0.18), in: Capsule())
                    .foregroundStyle(c)
            }
            .buttonStyle(.plain)
            .help(([p.summaryLine] + p.reasons.map { "⚠︎ " + $0 }).joined(separator: "\n"))
            .popover(isPresented: $show, arrowEdge: .bottom) { RiskReasonsView(p: p).padding(12).frame(width: 380, alignment: .leading) }
            .onReceive(NotificationCenter.default.publisher(for: Self.hookOpen)) { n in if hookTarget { show = (n.object as? Bool) ?? true } }
        }
    }
}

/// 原因列表 + 底行「风险 N / 100 · 等级」（徽标弹窗与修改记录「说明…」共用）
struct RiskReasonsView: View {
    let p: FillPlausibility
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(p.reasons.enumerated()), id: \.offset) { _, r in
                Text(verbatim: "⚠︎ " + r).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            let n = p.risk, level = p.badge
            Text("风险 \(n) / 100 · \(level)", comment: "Footer of the self-check reasons popover. %1$lld = risk score 0–100 (followed by literal “/ 100”), %2$@ = level badge text (要看一眼 / 留意)")
                .font(.caption.bold()).foregroundStyle(RiskBadge.color(p.level))
        }
        .textSelection(.enabled)
    }
}

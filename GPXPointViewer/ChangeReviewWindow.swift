//
//  ChangeReviewWindow.swift
//  GPXPointViewer
//
//  修改记录窗口（单文件模式）：本次会话对轨迹的全部修改——补点落地的每一处断档、每一次圈选删除。
//  总览：整条轨迹（蓝）+ 所有新增点（绿）+ 删掉的点（红）；右侧清单可点进详细。
//  详细：地图刚好框住某一处修改，显示国家 - 州 - 城市，‹ › 逐处人工校验，一键还原这一处。
//  地图/渲染复用 ComparePaneView + MetalPointRenderer（与找不同窗口同一套管线）。模型在 ChangeLog.swift
//

import SwiftUI
import MapKit

struct ChangeReviewView: View {
    @ObservedObject var store: TrackStore
    @Environment(\.openWindow) private var openWindow
    @State private var confirmAll = false
    @State private var confirmLand = false
    @State private var showEvidence = false
    @State private var showRiskReasons = false

    /// 列表内容键：修改记录（含已还原标记）或预览项（含勾选/草稿）变了就重建合成轨迹
    private var changesKey: String {
        (store.reviewPreview ? "P|" : "C|") + store.reviewItems.map { $0.id.uuidString + ($0.reverted ? "r" : "") + ($0.previewIncluded ? "i" : "x") + ($0.previewDeclined ? "d" : "") + $0.contentKey + "\($0.added.count)" }.joined()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            NetworkBanner().padding(.horizontal, 14).padding(.bottom, 6)
            Divider()
            content
            Divider()
            legend
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
        .frame(minWidth: 820, minHeight: 560)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { store.reviewStep(-1); return .handled }
        .onKeyPress(.rightArrow) { store.reviewStep(1); return .handled }
        .onAppear { store.ensureReviewTrack() }
        .onDisappear { store.openChangeLog() }              // 关掉窗口 = 退出预览模式；主窗口「修改记录」再进来看到的是真实记录
        .onChange(of: changesKey) {
            if let id = store.reviewSelection, store.reviewItem(id) == nil { store.reviewSelect(nil) }   // 选中的那处从列表里消失了（如预览项取消了直线）
            store.ensureReviewTrack()
        }
        .onChange(of: store.track?.id) { store.ensureReviewTrack() }
        .onChange(of: store.reviewPreview) { store.ensureReviewTrack() }
        .onChange(of: store.reviewSelection) { if let id = store.reviewSelection, let c = store.reviewItem(id) { store.requestReviewPlace(c) } }
        .alert("落地这些修改？", isPresented: $confirmLand) {
            Button("落地", role: .destructive) { store.landBatch() }
            Button("取消", role: .cancel) {}
        } message: {
            let a = store.reviewActiveItems
            let addedTotal = a.reduce(0) { $0 + $1.netAdded }, removedTotal = a.reduce(0) { $0 + $1.netRemoved }
            let n = a.count
            Text("把勾选的 \(n) 处补进轨迹：新增 \(addedTotal) 个点、替换 \(removedTotal) 个原始点。落地后在「修改记录」里可逐处还原。",
                 comment: "Pre-apply review › Apply confirmation. Placeholders in order: number of gaps ticked; points added; original points replaced")
        }
        .modifier(ExternalMapNoticeAlert(isPresented: $store.reviewExternalMapNotice))
        .alert("还原全部修改？", isPresented: $confirmAll) {
            Button("全部还原", role: .destructive) { store.revertAllChanges() }
            Button("取消", role: .cancel) {}
        } message: {
            let a = store.activeChanges
            let addedTotal = a.reduce(0) { $0 + $1.netAdded }
            let removedTotal = a.reduce(0) { $0 + $1.netRemoved }
            Text("把这 \(a.count) 处修改全部撤回：删掉补进去的 \(addedTotal) 个点，加回删掉的 \(removedTotal) 个点。还原本身不能再撤销。",
                 comment: "Change Log › Revert All confirmation message. Placeholders in order: number of changes; number of filled-in points that will be deleted; number of deleted points that will be added back")
        }
    }

    // MARK: 顶栏

    private var header: some View {
        // 两行：上面是「总览/详细 + 统计摘要」，下面是「底图控件 + 导航/落地按钮」。
        // 一行的时代，德文按钮（„Übernommene Änderungen zeigen“、„Zurück zum Stapelfenster“、
        // „100 Lücken übernehmen…“）在 1000 pt 窗口里全被压成省略号。
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("总览 / 详细", selection: Binding(get: { store.reviewDetail ? 1 : 0 }, set: { v in
                    if v == 0 { store.reviewSelect(nil) }
                    else if let id = store.reviewSelection ?? store.reviewItems.first?.id { store.reviewSelect(id) }
                })) {
                    Text("总览").tag(0)
                    Text("详细").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .disabled(store.reviewItems.isEmpty)
                if store.reviewPreview {
                    let a = store.reviewActiveItems, all = store.reviewItems
                    let n = a.count, total = all.count
                    let addedTotal = a.reduce(0) { $0 + $1.netAdded }, removedTotal = a.reduce(0) { $0 + $1.netRemoved }
                    let pending = all.filter { $0.previewPending }.count
                    Text("落地前审阅：\(total) 处 · 勾选落地 \(n) · 将新增 \(addedTotal) 点 · 替换 \(removedTotal) 点", comment: "Pre-apply review header. Placeholders in order: gaps listed; gaps ticked to apply; points that will be added; original points that will be replaced")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if pending > 0 {
                        Text("等你选 \(pending)", comment: "Pre-apply review header: %lld gaps still wait for the user's pick between the two routers")
                            .font(.caption.bold()).foregroundStyle(.blue)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                } else if !store.changes.isEmpty {
                    let a = store.activeChanges
                    let fills = a.filter { $0.kind == .fill }.count, dels = a.filter { $0.kind != .fill }.count
                    let reverted = store.changes.count - a.count
                    let total = a.count
                    let addedTotal = a.reduce(0) { $0 + $1.netAdded }
                    let removedTotal = a.reduce(0) { $0 + $1.netRemoved }
                    let line = String(localized: "\(total) 处修改（补点 \(fills) · 删除 \(dels)）· 新增 \(addedTotal) 点 · 删掉 \(removedTotal) 点",
                                      comment: "Change Log window header. Placeholders in order: number of active changes; of which gap fills; of which deletions (incl. replay cleanups); total points added; total points removed")
                    Text(verbatim: reverted > 0 ? line + " · " + String(localized: "已还原 \(reverted) 处", comment: "Change Log window header, appended after “ · ” when some changes were reverted: number of reverted changes") : line)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                // 审阅地图自己的底图：卫星/混合能看见隧道口（Apple 标准底图不画隧道几何，补在隧道里的点会显得"不在路上"）；浅色让蓝点看得清
                BaseMapStylePicker(selection: $store.reviewMapStyle, axis: .horizontal)   // 6 段一行在 1000 pt 窗口里和按钮挤不下，改成菜单
                    .help("审阅地图的底图（与主窗口无关）。Apple 标准底图不画隧道几何，补在隧道里的点看起来会在路外；OpenStreetMap 画隧道虚线，就是补点用的那条路")
                    .onChange(of: store.reviewMapStyle) { store.noteBaseMapChosen(store.reviewMapStyle, review: true) }
                Toggle("浅色", isOn: $store.reviewLightMap).toggleStyle(.checkbox)
                    .disabled(store.reviewMapStyle.isExternal)   // 外部瓦片不分日夜
                    .help("浅色底图上蓝色轨迹点最清楚；关掉则跟系统深色外观（外部瓦片不分日夜）")
                Toggle("叠加 OSM 隧道", isOn: $store.tunnelOverlay).toggleStyle(.checkbox)
                    .help("任何底图上都叠一层 OpenStreetMap 的隧道线（公路/铁路两色虚线）；视野 ≤ 40 km 时按视野向 Overpass 取")
                if let t = store.reviewTunnelStatus {
                    Text(verbatim: t).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.reviewBuilding {
                    ProgressView().controlSize(.small)
                    Text("生成审阅图…").font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: 8)
                if store.reviewPreview {
                    Button("看已落地的记录") { store.openChangeLog() }
                        .disabled(store.changes.isEmpty)
                        .help("切回本次会话已落地的修改记录（批次仍在，随时可再回到预览）")
                    Button("返回批量窗口") { store.reviewSelect(nil); openWindow(id: SceneID.batchFill) }
                    let n = store.reviewActiveItems.count
                    Button { confirmLand = true } label: { Text("落地 \(n) 处…", comment: "Pre-apply review: apply button; %lld = gaps ticked") }
                        .buttonStyle(.borderedProminent)
                        .disabled(n == 0 || store.isLoading || store.batch?.phase != .preview || (store.batch?.refetchingCount ?? 0) > 0)
                } else {
                    if store.batch?.phase == .preview {
                        Button("看落地前预览") { store.openBatchPreview() }
                            .help("回到当前批次的落地前预览")
                    }
                    Button("全部还原…") { confirmAll = true }
                        .disabled(store.activeChanges.isEmpty || store.isLoading || store.batchActive)
                        .help(Text("撤回本次会话的全部修改（补进去的点删掉、删掉的点加回来）；逐处还原请进「详细」",
                                   comment: "Tooltip of the Revert All… button in the Change Log window; 「详细」 is the Details tab of the Overview / Details picker"))
                }
            }
        }
        .font(.caption)
    }

    // MARK: 主体

    @ViewBuilder private var content: some View {
        if store.track == nil || store.displayMode != .single {
            placeholder("在主窗口以单文件模式打开一条轨迹后，这里会列出本次会话对它的全部修改。",
                        icon: "clock.arrow.circlepath")
        } else if store.reviewPreview, store.reviewItems.isEmpty {
            placeholder("批量里还没有可以预览的草稿：先在批量窗口取路网草稿，再回到这里看落地效果。",
                        icon: "point.topleft.down.to.point.bottomright.curvepath")
        } else if !store.reviewPreview, store.changes.isEmpty, store.isLoading {
            placeholder("正在落地，稍等…落地完成后这里列出每一处修改。", icon: "hourglass")
        } else if !store.reviewPreview, store.changes.isEmpty {
            placeholder("本次会话还没有修改。补点落地或圈选删除后，会在这里逐条列出：总览看整条轨迹上改了哪里，详细逐处校验，每一处都能一键还原。",
                        icon: "checkmark.circle")
        } else {
            // 总览 / 详细共用同一个地图视图（结构位置不变 → SwiftUI 不会销毁重建 MKMapView，切页不重载瓦片、不重传点）
            let detail = store.reviewDetail ? store.reviewSelection.flatMap { id in store.reviewItem(id) } : nil
            VStack(spacing: 0) {
                if let c = detail {
                    detailHeader(c)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    evidenceRow(c)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                    if let p = c.plausibility {
                        plausibilityRow(p)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 6)
                    }
                    Divider()
                }
                HStack(spacing: 0) {
                    ReviewMapView(store: store)
                        .overlay(alignment: .bottomLeading) { MapAttributionView(style: store.reviewMapStyle).padding(6) }
                    if detail == nil {
                        Divider()
                        changeList
                            .frame(width: 320)
                    }
                }
            }
        }
    }

    private func placeholder(_ text: LocalizedStringKey, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 总览清单

    private var changeList: some View {
        let list = store.reviewItems
        let preview = store.reviewPreview
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                (preview ? Text("按轨迹顺序 · 点一行进详细 · 勾选 = 落地") : Text("按轨迹顺序 · 点一行进详细")).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8)
                ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                    HStack(spacing: 4) {
                        if preview {
                            Toggle("落地", isOn: Binding(get: { c.previewIncluded }, set: { store.setPreviewIncluded(c.id, $0) }))
                                .toggleStyle(.checkbox).labelsHidden().disabled(c.previewPending || c.previewDeclined)
                                .help(c.previewPending || c.previewDeclined ? "还没选用哪一路：用详细页或批量窗口的「选一条…」" : "勾上 = 落地这一处")
                        }
                        Button { store.reviewSelect(c.id) } label: {
                            HStack(spacing: 8) {
                                Text(verbatim: "\(i + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                                kindTag(c)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(Self.trackTimeText(c)).font(.caption.monospacedDigit())
                                    Text(verbatim: Self.rowStatus(c, preview: preview)).font(.caption2).foregroundStyle(c.reverted || (preview && !c.previewIncluded) ? .secondary : .primary)
                                }
                                Spacer()
                                if let place = store.reviewPlaces[c.id] {
                                    Text(place).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head).frame(maxWidth: 120, alignment: .trailing)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(store.reviewSelection == c.id ? Color.accentColor.opacity(0.18) : Color.clear))
                            .contentShape(Rectangle())
                            .opacity(c.reverted || (preview && !c.previewIncluded) ? 0.55 : 1)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 6)
                }
            }
            .padding(.bottom, 8)
        }
    }

    /// 一行的第二行文字：修改记录 = 摘要（+ 已还原）；预览 = 摘要 + 将落地 / 不落地 / 等你选
    private static func rowStatus(_ c: TrackChange, preview: Bool) -> String {
        if !preview { return c.reverted ? c.summary + " · " + String(localized: "已还原", comment: "Change Log: status of a change that has been reverted") : c.summary }
        let state: String
        if c.previewDeclined { state = String(localized: "不补（已选都不补）", comment: "Pre-apply review row state: the user chose to fill neither route for this gap") }
        else if c.previewPending { state = c.previewUnverified ? String(localized: "等你选（只有一路有结果）", comment: "Pre-apply review row state: only one router answered and the user has not decided yet")
                                                          : String(localized: "等你选", comment: "Pre-apply review row state: the two routers disagree and the user has not picked yet") }
        else if c.previewIncluded { state = String(localized: "将落地", comment: "Pre-apply review row state: this gap is ticked and will be applied") }
        else { state = String(localized: "不落地", comment: "Pre-apply review row state: this gap is not ticked and will not be applied") }
        return c.summary + " · " + state
    }

    /// 路网证据一行：来源 · 依据 · 长度 · 两路一致/不一致 · 警告数，悬停给全文；「说明…」弹出全部 notes
    /// 某份草稿是不是这处采用的那路（直线/只删点/手动 = 都没采用）
    static func isAdopted(_ x: RouteDraft, in c: TrackChange) -> Bool { !c.straight && c.routeSource != nil && x.source == c.routeSource }

    /// 引擎名（不翻译）：OSRM / Valhalla；其它来源用标签
    static func engineName(_ s: RouteSource) -> String { s == .osrmCar ? "OSRM" : (s == .valhallaCar ? "Valhalla" : s.label) }

    private func evidenceRow(_ c: TrackChange) -> some View {
        let adopted = c.drafts.first { Self.isAdopted($0, in: c) }
        // 详细页当前显示的那份（两路切换；默认采用的那份）：来源·方式·长度·贴路与「说明…」都跟它走
        let shown = TrackStore.reviewShownDraft(c, preferred: store.reviewShownSource)
        let shownIsAdopted = shown.map { Self.isAdopted($0, in: c) } ?? false
        let sameGeometry = TrackStore.reviewSameGeometry(c)
        var parts: [String] = []
        if c.straight { parts.append(String(localized: "直线补点", comment: "Route evidence: this gap was filled with a straight line")) }
        if let d = shown, adopted != nil || c.drafts.count > 1 {
            parts.append(shownIsAdopted ? d.source.label
                         : String(localized: "\(d.source.label)（显示中，未采用）", comment: "Route evidence: the draft currently shown on the map is not the adopted one; %@ = source label"))
            if let m = d.method?.label { parts.append(m) }
            parts.append(d.meters >= 1000 ? "\((d.meters / 1000).formatted(Fmt.f2)) km" : "\(d.meters.formatted(Fmt.f0)) m")
            parts.append(String(localized: "贴路 \(d.snapA, format: Fmt.f0) / \(d.snapB, format: Fmt.f0) m", comment: "Route evidence: snap distance of anchor A / anchor B to the road in m"))
            if d.shiftA > 0 || d.shiftB > 0 { parts.append(BatchFillWindowView.shiftText(d).trimmingCharacters(in: CharacterSet(charactersIn: " ·"))) }
        } else if !c.straight, let src = c.routeSource {
            parts.append(src.label)
            if c.drafts.isEmpty { parts.append(String(localized: "套用同路段的折线", comment: "Route evidence: the polyline was reused from a similar gap (Apply Similar)")) }
        } else if !c.straight, c.kind == .fill, c.drafts.isEmpty { parts.append(String(localized: "纯手动描线", comment: "Route evidence: the polyline was drawn by hand, no routing service")) }
        if !c.drafts.isEmpty, adopted == nil, !c.straight, c.previewPending || c.previewDeclined {
            parts.append(String(localized: "两路都取到了，还没选用", comment: "Route evidence (preview): both routers' drafts exist but none has been adopted yet"))
        } else if !c.drafts.isEmpty, adopted == nil, c.straight {
            let n = c.drafts.count
            parts.append(String(localized: "取到的 \(n) 份路网草稿未采用", comment: "Route evidence: %lld routing drafts were fetched but not adopted (straight line chosen instead)"))
        }
        var crossHelp = ""
        if let x = c.cross {
            let md = Int(x.maxDev.rounded())
            if x.agree { parts.append(String(localized: "两路一致（最多相差 \(md) m）", comment: "Route evidence: both routers agree; %lld = max deviation in m")) }
            else {
                parts.append(String(localized: "两路不一致（分歧段 \(x.divergence, format: Fmt.f0) m）", comment: "Route evidence: the routers disagreed; %@ = divergent stretch in m"))
                if let r = x.reasons.first { parts.append(r) }
                crossHelp = x.reasons.joined(separator: "\n")
            }
        }
        // 警告计数与「说明…」只看当前显示的那份（切换分段控件就换成另一份的）
        let warnings = shown?.warnings ?? c.drafts.flatMap(\.warnings)
        let notes: [String] = ([crossHelp].filter { !$0.isEmpty }) + (shown.map { [$0] } ?? c.drafts).flatMap { x -> [String] in
            let head: String
            if Self.isAdopted(x, in: c) { head = String(localized: "— \(x.source.label)（采用）", comment: "Route evidence popover: heading of the adopted router's section; %@ = source label") }
            else if adopted != nil { head = String(localized: "— \(x.source.label)（另一路）", comment: "Route evidence popover: heading of the other router's section; %@ = source label") }
            else { head = String(localized: "— \(x.source.label)（未采用）", comment: "Route evidence popover: heading of a router's section when no route was adopted; %@ = source label") }
            return [head] + x.warnings.map { "⚠︎ " + $0 } + x.notes.map { "· " + $0 } + [""]
        }
        return HStack(spacing: 8) {
            Image(systemName: "map").foregroundStyle(.secondary)
            Text(verbatim: parts.isEmpty ? String(localized: "没有路网信息", comment: "Route evidence row when the record carries no routing information") : parts.joined(separator: " · "))
                .font(.caption).lineLimit(1).truncationMode(.middle)
                .help(crossHelp.isEmpty ? parts.joined(separator: " · ") : crossHelp)
            if !warnings.isEmpty {
                let n = warnings.count
                Text("⚠︎ \(n)", comment: "Route evidence row: number of warnings").font(.caption.bold()).foregroundStyle(.orange).help(warnings.joined(separator: "\n"))
            }
            if c.drafts.count > 1 {
                // 两路切换：只改地图上哪份画粗实线、说明与依据看哪份；不改采用、不改勾选
                Picker("显示哪一路", selection: Binding<String>(get: { shown?.source.rawValue ?? "" }, set: { v in store.reviewShowDraft(RouteSource(rawValue: v)) })) {
                    ForEach(c.drafts, id: \.source) { x in
                        Text(verbatim: Self.engineName(x.source) + (Self.isAdopted(x, in: c) ? " ✓" : "")).tag(x.source.rawValue)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("切换看 OSRM 和 Valhalla 各自给的路径：地图上显示的那份画成粗实线（绿 = 采用的，蓝 = 未采用），另一份细虚线；依据行与「说明…」也跟着换。✓ = 这处采用的那路。只是看，不改采用")
                if sameGeometry {
                    Text("两路几何完全相同").font(.caption2).foregroundStyle(.secondary)
                        .help("两个服务给出的坐标逐点相同（都用同一份 OpenStreetMap 数据），切换看不出差别是正常的")
                }
            }
            Spacer()
            if !c.drafts.isEmpty {
                Button("说明…") { showEvidence.toggle() }
                    .popover(isPresented: $showEvidence, arrowEdge: .bottom) {
                        ScrollView {
                            Text(verbatim: notes.joined(separator: "\n")).font(.caption).textSelection(.enabled).frame(width: 560, alignment: .leading).padding(12)
                        }
                        .frame(maxHeight: 420)
                    }
                    .help("当前显示的那份路网草稿的依据、警告与全部说明（两路时用左边的切换看另一份）")
            }
        }
        .font(.caption)
    }

    /// 落地前自检一行（依据行下面；预览与已落地都显示）：「落地前自检：风险 N（等级）」+ 原因；多于 3 条时只列前 3 条，其余进「说明…」
    private func plausibilityRow(_ p: FillPlausibility) -> some View {
        let shown = Array(p.reasons.prefix(3))
        let color: Color = p.level == .low ? .secondary : RiskBadge.color(p.level)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: p.level == .low ? "checkmark.shield" : "exclamationmark.shield").foregroundStyle(color)
                Text(verbatim: p.summaryLine).font(.caption.bold()).foregroundStyle(color)
                Spacer()
                if p.reasons.count > 3 {
                    Button("说明…") { showRiskReasons.toggle() }
                        .popover(isPresented: $showRiskReasons, arrowEdge: .bottom) { RiskReasonsView(p: p).padding(12).frame(width: 420, alignment: .leading) }
                        .help(Text("落地前自检的全部原因", comment: "Help of the 说明… button on the Change Log self-check row: shows all reasons"))
                }
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, r in
                Text(verbatim: "⚠︎ " + r).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(r)
            }
        }
        .font(.caption)
    }

    // MARK: 详细页头

    private func detailHeader(_ c: TrackChange) -> some View {
        let list = store.reviewItems
        let pos = (list.firstIndex { $0.id == c.id } ?? 0) + 1
        let placeText = store.reviewPlaces[c.id] ?? String(localized: "地名查询中…", comment: "Change Log details: shown while the place name (country - state - city) is being looked up")
        let opTime = Self.opTimeText(c.date)
        let revertTitle: LocalizedStringKey = c.reverted ? "已还原" : "还原此处"
        let nAdded = c.netAdded, nRemoved = c.netRemoved   // 改时点不算新增/删除
        let revertHelp: String
        if c.kind == .fill {
            revertHelp = nRemoved == 0
                ? String(localized: "删掉这处补进去的 \(nAdded) 个点", comment: "Tooltip of Revert This (gap fill change): number of filled-in points that will be deleted")
                : String(localized: "删掉这处补进去的 \(nAdded) 个点，加回被替换的 \(nRemoved) 个原始点", comment: "Tooltip of Revert This (gap fill change that replaced points). Placeholders in order: filled-in points that will be deleted; replaced original points that will be added back")
        } else {
            revertHelp = String(localized: "把这次删掉的 \(nRemoved) 个点加回轨迹", comment: "Tooltip of Revert This (deletion change): number of deleted points that will be added back to the track")
        }
        return HStack(spacing: 10) {
            // 左上角：所在国家的国旗（逆地理编码的 ISO 国家码）
            Text(store.reviewFlags[c.id] ?? "🏳️")
                .font(.system(size: 34))
                .frame(width: 44)
                .help(placeText)
            HStack(spacing: 2) {
                Button { store.reviewStep(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(pos <= 1)
                    .help("上一处（按轨迹顺序）")
                Button { store.reviewStep(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(pos >= list.count)
                    .help("下一处（按轨迹顺序）")
            }
            .buttonStyle(.bordered)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("第 \(pos) / \(list.count) 处").font(.caption.bold().monospacedDigit())
                    kindTag(c)
                    Text(Self.trackTimeText(c)).font(.caption.monospacedDigit())
                    Text(c.summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if c.reverted { Text("已还原").font(.caption.bold()).foregroundStyle(.orange) }
                }
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary)
                    Text(placeText)
                        .font(.caption)
                        .help("国家 - 州/省 - 城市（Apple 地图逆地理编码，按这处修改的中心点）")
                    Text(String(format: "%.5f°, %.5f°", c.center.latitude, c.center.longitude))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    if !store.reviewPreview {
                        Text(verbatim: "· " + String(localized: "操作于 \(opTime)", comment: "Change Log details: clock time (HH:mm:ss) at which this change was made")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Toggle(isOn: Binding(get: { store.reviewFollowMap }, set: { store.reviewFollowMap = $0; if $0 { store.reviewShowOnMainMap() } })) {
                Text("主地图跟随", comment: "Change Log detail toggle: when on, paging with ‹ › / arrow keys also flies the main window's map to that change")
            }
            .toggleStyle(.checkbox)
            .fixedSize()
            .help(Text("开着时，用 ‹ › 或方向键翻页后主地图自动飞到那一处；关着时点「在主地图上看」才飞", comment: "Help of the Follow on Main Map toggle; 「在主地图上看」 = the Show on Main Map button"))
            Button {
                store.reviewShowOnMainMap()
            } label: {
                Label { Text("在主地图上看", comment: "Change Log detail button: fly the main window's map to this change (the Change Log window keeps focus)") } icon: { Image(systemName: "map") }
            }
            .help("主窗口的地图飞到这一处（避开面板），主窗口置前；这个窗口仍可用 ‹ › 或方向键继续翻。不改主窗口的模式")
            Button("回总览") { store.reviewSelect(nil) }
            if store.reviewPreview {
                if c.previewPending || c.previewDeclined {
                    Text(c.previewDeclined ? "已选都不补" : (c.previewUnverified ? "只有一路有结果，没比对" : "两路不一致，还没选")).font(.caption).foregroundStyle(.blue)
                    if let itemID = c.previewItemID, let item = store.batch?.items.first(where: { $0.id == itemID }) {
                        Menu {
                            ForEach(item.crossDrafts, id: \.source) { x in
                                Button(x.source.label) { store.resolveBatchConflict(item.id, .source(x.source)) }
                            }
                            if item.kind == .road {
                                Button { store.resolveBatchConflict(item.id, .straight) } label: { Text(LocalizedStringResource("batch.pick.straight", defaultValue: "直线", comment: "Action: fill this gap with a straight line (menu item / toggle); not the 直线 (straight-line distance) column header")) }
                            }
                            if !item.declined { Button("都不补") { store.resolveBatchConflict(item.id, .none) } }
                        } label: { Text("选一条…", comment: "Menu button on a precise-mode row waiting for the user's choice between the two routers' routes") }
                        .fixedSize()
                    }
                } else {
                    Toggle(isOn: Binding(get: { c.previewIncluded }, set: { store.setPreviewIncluded(c.id, $0) })) {
                        Text(c.previewIncluded ? "落地这一处" : "不落地这一处", comment: "Pre-apply review detail toggle label (on / off)")
                    }
                    .toggleStyle(.switch)
                    .help("关掉 = 这一处不补（= 批量窗口里取消勾选）")
                }
            } else {
                Button(revertTitle) { store.revertChanges([c.id]) }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(c.reverted || store.isLoading || store.batchActive)
                    .help(revertHelp)
            }
        }
        .font(.caption)
    }

    private func kindTag(_ c: TrackChange) -> some View {
        Text(c.title)
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(c.kind == .fill ? Color(red: 0.16, green: 0.72, blue: 0.31) : Color(red: 0.86, green: 0.22, blue: 0.22)))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendDot(Color(red: 10 / 255, green: 122 / 255, blue: 1.0), "轨迹")
            if store.reviewPreview {
                legendDot(Color(red: 40 / 255, green: 200 / 255, blue: 80 / 255), "将新增的点")
                legendDot(Color(red: 235 / 255, green: 50 / 255, blue: 50 / 255), "将被替换的原始点")
            } else {
                legendDot(Color(red: 40 / 255, green: 200 / 255, blue: 80 / 255), "新增的点（补点）")
                legendDot(Color(red: 235 / 255, green: 50 / 255, blue: 50 / 255), "删掉的点（圈选删除 / 补点替换掉的原始点）")
            }
            // 只在有改时点时出现，平时不占图例位置
            if store.reviewActiveItems.contains(where: { $0.retimed > 0 }) {
                HStack(spacing: 5) {
                    Circle().fill(Color(red: 1.0, green: 160 / 255, blue: 0)).frame(width: 9, height: 9)
                    Text(String(localized: "改时间的点（位置是真实观测，时间按出口速度回推）", comment: "Change Log legend: orange dots = existing points after a tunnel whose position was kept (real observation) and whose timestamp was recomputed from the exit speed"))
                }
            }
            Spacer()
            if store.reviewMapStyle == .standard, !store.tunnelOverlay {
                Text("Apple 标准底图不画隧道：补在隧道里的点看着在路外，切 OpenStreetMap 或打开「叠加 OSM 隧道」可见隧道线").font(.caption2).foregroundStyle(.orange)
            }
            (store.reviewPreview ? Text("← → 翻处；这里只是预览，点「落地」才写进轨迹") : Text("若后续修改依赖此处，请一并还原相关修改。")).font(.caption2).foregroundStyle(.secondary)
        }
        .font(.caption2)
    }
    private func legendDot(_ color: Color, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 9, height: 9); Text(text) }
    }

    static func trackTimeText(_ c: TrackChange) -> String {
        guard let t = c.trackTime else { return String(localized: "（无时间）", comment: "Change Log: shown instead of the track time when the change has no timestamp") }
        return TrackStore.batchTimeText(t)
    }
    private static let opFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    static func opTimeText(_ d: Date) -> String { opFormatter.string(from: d) }
}

// MARK: - 审阅地图（合成轨迹：蓝 / 绿 / 红；总览整条、详细框住一处）

struct ReviewMapView: NSViewRepresentable {
    @ObservedObject var store: TrackStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> ComparePaneView {
        let v = ComparePaneView(frame: CGRect(x: 0, y: 0, width: 900, height: 620))
        context.coordinator.attach(v)
        return v
    }

    func updateNSView(_ nsView: ComparePaneView, context: Context) {
        context.coordinator.sync()
    }

    static func dismantleNSView(_ nsView: ComparePaneView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        private let store: TrackStore
        private weak var pane: ComparePaneView?
        private var renderer: MetalPointRenderer?
        private var shownTrackID: UUID?
        private var shownColorVersion = -1
        private var shownSettings = ViewSettings()
        private var shownFocusKey = ""
        private var shownMapStyle: BaseMapStyle?
        private var shownLight: Bool?
        private var shownBaseKey = ""                  // 底轨 id + 模式：只有它变了才重新取景（勾选切换引起的重建不动相机）
        private var shownRouteKey = ""
        private var routeOverlays: [MKPolyline] = []
        private var redrawScheduled = false
        private let baseMap = BaseMapApplier()
        private let tunnels = TunnelLayer(name: "review")

        init(store: TrackStore) {
            self.store = store
            super.init()
        }

        func attach(_ pane: ComparePaneView) {
            self.pane = pane
            pane.mapView.delegate = self
            tunnels.mapView = pane.mapView
            tunnels.onChange = { [weak self] in
                guard let self else { return }
                let t = self.tunnels.statusText
                if self.store.reviewTunnelStatus != t {
                    DispatchQueue.main.async { [weak self] in self?.store.reviewTunnelStatus = t }   // 可能在视图更新中触发，推后发布
                }
                self.raiseRouteOverlays()   // 隧道线刚画上来：草稿折线重新抬到最上面
            }
            tunnels.setEnabled(store.tunnelOverlay)
            pane.mapView.isRotateEnabled = false
            pane.mapView.isPitchEnabled = false
            pane.mapView.showsZoomControls = false
            pane.dimView.alphaValue = 0          // 审阅图不压暗（压暗会把路一起压掉；可见度靠浅色底图 + 白描边）
            pane.overlay.onGeometryChange = { [weak self] in self?.scheduleRedraw() }
            applyMapStyle()
            renderer = MetalPointRenderer()
            if let r = renderer { pane.overlay.metalLayer.device = r.device }
            shownSettings = store.settings
            store.reviewVisibleBox = { [weak self] in
                guard let mv = self?.pane?.mapView else { return nil }
                let r = mv.region
                return (r.center.latitude - r.span.latitudeDelta / 2, r.center.longitude - r.span.longitudeDelta / 2,
                        r.center.latitude + r.span.latitudeDelta / 2, r.center.longitude + r.span.longitudeDelta / 2)
            }
            sync()
        }

        func detach() {   // 闭包弱引用自己，视图没了自然返回 nil；不在这儿清，免得和新实例的 attach 抢先后
            renderer = nil
            tunnels.setEnabled(false)                 // 窗口关了：取消在飞的请求、状态行清空
            if TunnelLayer.registry["review"] === tunnels { TunnelLayer.registry["review"] = nil }
        }

        func sync() {
            guard let pane else { return }
            if let t = store.reviewTrack {
                if t.id != shownTrackID {
                    shownTrackID = t.id
                    shownColorVersion = t.colorVersion
                    renderer?.setData(track: t)
                    renderer?.updateColors(t.colors)
                    let base = (store.track?.id.uuidString ?? "") + (store.reviewPreview ? "P" : "C")
                    if base != shownBaseKey { shownBaseKey = base; shownFocusKey = "" }   // 换了轨迹/模式才重新取景；勾选引起的重建不动相机
                    scheduleRedraw()
                } else if t.colorVersion != shownColorVersion {
                    shownColorVersion = t.colorVersion
                    renderer?.updateColors(t.colors)
                    scheduleRedraw()
                }
            } else if shownTrackID != nil {
                shownTrackID = nil
                renderer?.clearData()
                scheduleRedraw()
            }
            // 取景：详细页框住选中的那一处；总览回到整条。只在页/选中处/数据变化时动相机，不打断用户自己平移
            let focusKey = store.reviewDetail ? "detail:" + (store.reviewSelection?.uuidString ?? "-") : "overview"
            if focusKey != shownFocusKey, store.reviewTrack != nil || store.track != nil {
                shownFocusKey = focusKey
                if store.reviewDetail, let id = store.reviewSelection, let c = store.reviewItem(id) {
                    focus(on: c, in: pane.mapView)
                } else if let t = store.reviewTrack ?? store.track {
                    zoomToFit(t, in: pane.mapView)
                }
            }
            if store.settings != shownSettings {
                shownSettings = store.settings
                scheduleRedraw()
            }
            if shownMapStyle != store.reviewMapStyle || shownLight != store.reviewLightMap { applyMapStyle() }
            if tunnels.enabled != store.tunnelOverlay { tunnels.setEnabled(store.tunnelOverlay) }
            // 详细页：把这一处的路网草稿画成折线。当前显示的那份（两路切换；默认采用的那份）粗实线，另一份细虚线；
            // 颜色按是否采用：绿 = 采用的，蓝 = 未采用。显示的那份后画（盖在上面）
            let routeKey = store.reviewDetail ? "r:" + (store.reviewSelection?.uuidString ?? "-") + ":" + changesKeyForRoutes() : "r:none"
            if routeKey != shownRouteKey {
                shownRouteKey = routeKey
                pane.mapView.removeOverlays(routeOverlays); routeOverlays = []
                if store.reviewDetail, let id = store.reviewSelection, let c = store.reviewItem(id) {
                    let shownSource = TrackStore.reviewShownDraft(c, preferred: store.reviewShownSource)?.source
                    // 草稿没外推时从断档原始两端起画（与 RouteCrossCheck.polyline 口径一致；c.anchors 可能是采用那路外推后的）
                    let a0 = c.originalA ?? c.anchors.first.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                    let b0 = c.originalB ?? c.anchors.last.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                    var shownLine: MKPolyline?
                    for d in c.drafts {
                        var coords: [CLLocationCoordinate2D] = []
                        if let p = d.anchorA ?? a0 { coords.append(GeoCoord.dataToMap(p)) }
                        coords += d.coords.map(GeoCoord.dataToMap)
                        if let p = d.anchorB ?? b0 { coords.append(GeoCoord.dataToMap(p)) }
                        guard coords.count >= 2 else { continue }
                        let line = MKPolyline(coordinates: coords, count: coords.count)
                        let adopted = ChangeReviewView.isAdopted(d, in: c)
                        if d.source == shownSource { line.title = adopted ? "shown-adopted" : "shown-other"; shownLine = line }
                        else { line.title = adopted ? "dim-adopted" : "dim-other"; routeOverlays.append(line) }
                    }
                    if let s = shownLine { routeOverlays.append(s) }
                    // .aboveLabels：外部瓦片底图挂在这一层的最底部（不透明），.aboveRoads 整层会被它盖住；隧道线也在这一层，草稿要后加才在上面
                    if !routeOverlays.isEmpty { pane.mapView.addOverlays(routeOverlays, level: .aboveLabels) }
                }
            }
        }

        /// 隧道线画上来之后把草稿折线移除再加回，保证草稿始终在最上面
        private func raiseRouteOverlays() {
            guard let pane, !routeOverlays.isEmpty, !tunnels.overlays.isEmpty else { return }
            pane.mapView.removeOverlays(routeOverlays)
            pane.mapView.addOverlays(routeOverlays, level: .aboveLabels)
        }

        private func changesKeyForRoutes() -> String {
            guard let id = store.reviewSelection, let c = store.reviewItem(id) else { return "" }
            return c.drafts.map { "\($0.source.rawValue)\($0.coords.count)" }.joined(separator: ",") + "|\(c.routeSource?.rawValue ?? "-")|\(c.straight)|\(store.reviewShownSource?.rawValue ?? "-")"
        }

        nonisolated func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let r = BaseMapApplier.renderer(for: overlay) { return r }      // 外部瓦片底图
            if let r = TunnelLayer.renderer(for: overlay) { return r }         // OSM 隧道线
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            let green = NSColor(red: 0.16, green: 0.78, blue: 0.31, alpha: 0.9), blue = NSColor(red: 0.1, green: 0.5, blue: 1.0, alpha: 0.9)
            switch line.title {
            case "shown-adopted": r.strokeColor = green; r.lineWidth = 4
            case "shown-other": r.strokeColor = blue; r.lineWidth = 4
            case "dim-adopted": r.strokeColor = green; r.lineWidth = 1.5; r.lineDashPattern = [8, 6]
            default: r.strokeColor = blue; r.lineWidth = 1.5; r.lineDashPattern = [8, 6]
            }
            return r
        }

        private func applyMapStyle() {
            guard let pane else { return }
            shownMapStyle = store.reviewMapStyle
            shownLight = store.reviewLightMap
            baseMap.apply(store.reviewMapStyle, to: pane.mapView, elevation: .flat)
            tunnels.reattachIfNeeded()
            // 关掉 = 跟窗口/系统外观；外部瓦片不分日夜（不反色），只让 MapKit 自己的控件跟系统
            pane.mapView.appearance = store.reviewLightMap && !store.reviewMapStyle.isExternal ? NSAppearance(named: .aqua) : nil
        }

        private func zoomToFit(_ t: TrackData, in mapView: MKMapView) {
            let p1 = MKMapPoint(CLLocationCoordinate2D(latitude: t.bbox.maxLat, longitude: t.bbox.minLon))
            let p2 = MKMapPoint(CLLocationCoordinate2D(latitude: t.bbox.minLat, longitude: t.bbox.maxLon))
            var rect = MKMapRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                                 width: max(1000, abs(p1.x - p2.x)), height: max(1000, abs(p1.y - p2.y)))
            rect = rect.insetBy(dx: -rect.size.width * 0.08, dy: -rect.size.height * 0.08)
            mapView.setVisibleMapRect(rect, animated: false)
        }

        /// 刚好框住一处修改：范围四周留 22% 边距，至少 160 m 见方（一两个点的删除也要看得见周围）
        private func focus(on c: TrackChange, in mapView: MKMapView) {
            let b = c.bbox
            guard b.minLat <= b.maxLat else { return }
            let p1 = MKMapPoint(CLLocationCoordinate2D(latitude: b.maxLat, longitude: b.minLon))
            let p2 = MKMapPoint(CLLocationCoordinate2D(latitude: b.minLat, longitude: b.maxLon))
            let minSide = MKMapPointsPerMeterAtLatitude(c.center.latitude) * 160
            var w = max(abs(p1.x - p2.x), minSide), h = max(abs(p1.y - p2.y), minSide)
            let cx = (p1.x + p2.x) / 2, cy = (p1.y + p2.y) / 2
            w *= 1.44; h *= 1.44
            let rect = MKMapRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
            mapView.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12), animated: !UITestHook.noAnimation)
        }

        nonisolated func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            MainActor.assumeIsolated { scheduleRedraw() }
        }
        nonisolated func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            MainActor.assumeIsolated { scheduleRedraw(); tunnels.viewChanged() }
        }

        private func scheduleRedraw() {
            guard !redrawScheduled else { return }
            redrawScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.redrawScheduled = false
                self.performRedraw()
            }
        }

        private func performRedraw() {
            guard let pane, let renderer else { return }
            let r = pane.mapView.visibleMapRect
            let world = MKMapRect.world.size.width
            guard r.size.width > 0, r.size.height > 0, pane.overlay.metalLayer.drawableSize.width > 1 else { return }
            let camera = CameraRect(x0: r.origin.x / world, y0: r.origin.y / world,
                                    w: r.size.width / world, h: r.size.height / world,
                                    pxW: Double(pane.overlay.metalLayer.drawableSize.width),
                                    pxH: Double(pane.overlay.metalLayer.drawableSize.height))
            let scale = Double(pane.overlay.backingScale)
            let size = max(3.5, store.settings.pointSize) * (store.reviewDetail ? 1.6 : 1.3)    // 审阅图点画大些
            renderer.render(layer: pane.overlay.metalLayer, camera: camera,
                            pointSizePx: size * scale, opacity: 1.0, halo: true,                  // 一律白描边：深色/卫星底图上也看得清
                            line: nil, highlight: nil,
                            lodStride: lodStride(camera: camera, scale: scale),
                            range: nil, lodDedupe: store.settings.lodEnabled,
                            orderSensitive: true)
        }

        private func lodStride(camera: CameraRect, scale: Double) -> Int {
            guard let t = store.reviewTrack, store.settings.lodEnabled, t.count > 60_000, t.medianSegMerc > 0 else { return 1 }
            let pxPerMerc = camera.pxW / camera.w
            let segPx = t.medianSegMerc * pxPerMerc
            let targetPx = max(1.0, store.settings.pointSize * scale * 1.2)
            guard segPx < targetPx else { return 1 }
            var stride = Int((targetPx / segPx).rounded(.up))
            stride = min(stride, max(1, t.count / 20_000))
            return max(1, min(stride, 4096))
        }
    }
}

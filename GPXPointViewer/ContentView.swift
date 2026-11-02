//
//  ContentView.swift
//  GPXPointViewer
//
//  主界面：地图 + 控制面板 + 图例 + 性能面板 + 悬停/选中详情卡。
//  所有设置控件都用 store.binding()（延迟发布），配合 onChange 触发重着色，
//  不会在视图更新期间发布状态。
//

import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: TrackStore
    // 本窗口的补点覆盖层投影（多窗口各自一份）。@State 只保证实例稳定、不订阅它：
    // 逐帧发布只重绘观察它的 FillOverlayView，不能让整个 ContentView 每帧重算
    @State private var fillOverlay = FillOverlayState()
    @State private var panelFrames: [CGRect] = []          // 各浮层的位置（悬停卡避让；坐标空间 root）
    @Environment(\.openWindow) private var openWindow
    @State private var dropTargeted = false
    @State private var hoveringName = false
    @AppStorage("panelCollapsed") private var panelCollapsed = false
    @ObservedObject private var health = NetworkHealth.shared      // 离线/网络不好：联网按钮置灰 + 横幅
    /// body 求值次数（自测用：验证悬停/帧率刷新不再重算整个 ContentView）
    nonisolated(unsafe) static var bodyEvaluations = 0

    var body: some View {
        let _ = { if UITestHook.enabled { Self.bodyEvaluations += 1 } }()
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if store.displayMode == .compare {
                    CompareMapView(store: store)
                } else {
                    PointMapView(store: store, fillOverlay: fillOverlay)
                }

                if store.track == nil && !store.fwdbActive && !store.isLoading {
                    Group {
                        if store.presenting {
                            // 闲置展示：不挡地球，仅左上角一行白字
                            Text("拖入 GPX 文件或 .fwdb 迷雾存档，或按 ⌘O 打开")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .shadow(color: .black.opacity(0.8), radius: 3)
                                .padding(.leading, 18)
                                .padding(.top, 14)
                                .transition(.opacity)
                        } else {
                            emptyState
                                .frame(width: geo.size.width, height: geo.size.height)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.3), value: store.presenting)
                    .allowsHitTesting(false)
                }

                if dropTargeted {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        .padding(8)
                        .allowsHitTesting(false)
                }

                if let pts = store.selectionPath, pts.count >= 2 {
                    LassoShape(points: pts)
                        .fill(Color.red.opacity(0.10))
                        .allowsHitTesting(false)
                    LassoShape(points: pts)
                        .stroke(Color.red.opacity(0.85),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round,
                                                   lineJoin: .round, dash: [6, 4]))
                        .allowsHitTesting(false)
                }

                // 补点覆盖层：断档直连（红虚线）、预览折线（橙）、顶点与锚点
                // （独立观察 fillOverlayState：平移逐帧更新只重绘这一层）
                if store.fillMode {
                    FillOverlayView(state: fillOverlay)
                        .allowsHitTesting(false)
                }

                if store.isLoading {
                    loadingCard
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if store.displayMode != .compare {
                Group {
                    if panelCollapsed { collapsedPanelChip } else { controlPanel }
                }
                .padding(12)
                // 补点模式底部操作条横贯整个窗口：左面板也停在它上面（800 pt 高的窗口里最底一行「导出/图片/删除点/补点」
                // 与「修改记录」曾被盖住）；放不下时面板自己变成可滚动（见 controlPanel 的 ViewThatFits）
                .padding(.bottom, store.fillMode ? max(0, bottomStackHeight - 2) : 0)
                .opacity(uiFade).animation(.easeInOut(duration: 0.3), value: store.presenting)
                .reportPanelFrame()
            }
        }
        .overlay(alignment: .topTrailing) {
            if store.displayMode != .compare {
                VStack(alignment: .trailing, spacing: 10) {
                    if store.settings.heatMap, store.settings.heat3D,
                       store.track != nil, store.playback == nil, !store.fillMode {
                        Heat3DCompass(store: store, cam: store.heat3DCam)
                    }
                    selectedCard
                    fileListPanel
                    fwdbListPanel
                    gapListPanel
                    // 补点模式：性能面板收成一行接在候选面板下面（同一列堆叠，永远不会盖住候选面板底部的说明）
                    if store.fillMode { statsPanel.opacity(uiFade) }
                }
                .padding(12)
                // 补点模式底部操作条横贯整个窗口：右列停在它上面，候选列表（ScrollView，最高 320）自己缩短让出高度。
                // 不这样的话 800 pt 高的窗口里德文候选面板的说明和性能面板会被操作条盖住
                .padding(.bottom, store.fillMode ? max(0, bottomStackHeight - 2) : 0)
                .reportPanelFrame()
            }
        }
        .overlay(alignment: .trailing) {
            globeStyleControls.padding(.trailing, 12).opacity(uiFade).animation(.easeInOut(duration: 0.3), value: store.presenting)
                .reportPanelFrame()
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 10) {
                if store.displayMode != .compare {
                    VStack(alignment: .leading, spacing: 10) {
                        fogStatsCard
                        legend
                    }
                    .opacity(uiFade)
                    .animation(.easeInOut(duration: 0.3), value: store.presenting)
                }
                MapAttributionView(style: store.settings.mapStyle)   // 外部底图署名（Apple「地图」标识旁）：展示模式下也不淡出
            }
            .padding(12)
            .reportPanelFrame()
        }
        .onChange(of: store.showFogStats) {
            if store.showFogStats { store.ensureFogStats() }
        }
        .overlay(alignment: .bottomTrailing) {
            if store.displayMode != .compare, !store.fillMode {
                statsPanel.padding(12).opacity(uiFade).animation(.easeInOut(duration: 0.3), value: store.presenting)
                    .reportPanelFrame()
            }
        }
        .overlay(alignment: .bottom) {
            if store.displayMode != .compare {
                VStack(spacing: 8) {
                    if let pb = store.playback {
                        PlaybackBarView(store: store, session: pb, clock: pb.clock)
                    }
                    fillModeHint
                    scaleBarView
                }
                .padding(.bottom, 10)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                    if abs(h - bottomStackHeight) > 2 { bottomStackHeight = h }   // 只在高度真变了时写，免得每帧重算 ContentView
                }
                .reportPanelFrame()
            }
        }
        .overlay(alignment: .top) {
            if store.displayMode == .compare {
                compareBar.padding(.top, 10)
            } else {
                deleteModeHint.padding(.top, 10).reportPanelFrame()
            }
        }
        // 顶部横幅提示（落地成功等）：几秒后自动消失，可点动作
        .overlay(alignment: .top) {
            if let t = store.toast {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(verbatim: t.text).font(.callout)
                    if let title = t.actionTitle {
                        Button(title) {
                            if t.action == .openReview { store.openChangeLog(); openWindow(id: SceneID.changeReview) }
                            store.dismissToast()
                        }
                        .controlSize(.small)
                    }
                    Button { store.dismissToast() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(radius: 6)
                .padding(.top, 54)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.toast)
        // 悬停信息卡：最后一个 overlay = 最上层；避开所有上报了位置的浮层（不互相遮挡）；
        // 光标本身在某个浮层上时不显示（那是在操作面板，不是在看点）。
        // 单独观察 hoverState：鼠标每动一下只重算这一层，不重算整个 ContentView
        .overlay(alignment: .topLeading) {
            if store.displayMode != .compare {
                HoverTooltipLayer(hover: store.hoverState, panelFrames: panelFrames)
            }
        }
        .onPreferenceChange(PanelFramesKey.self) { panelFrames = $0; if store.uiPanelFrames != $0 { store.uiPanelFrames = $0 } }
        .onAppear {
            NetworkHealth.shared.start()
            if UITestHook.enabled {
                UITestHook.shared.openBatchWindow = { openWindow(id: SceneID.batchFill) }
                UITestHook.shared.openReviewWindow = { openWindow(id: SceneID.changeReview) }
                UITestHook.shared.openRegionsWindow = { openWindow(id: SceneID.regions) }
            }
        }
        .coordinateSpace(name: "root")
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { handleDrop($0) }
        .onChange(of: dropTargeted) {
            // Finder 拖拽悬停期间没有 mouseMoved，isTargeted 是唯一的活动信号
            if dropTargeted { store.noteUserActivity() }
        }
        .onChange(of: store.settings.heatMap) {
            // 热力与迷雾互斥（都是全屏图层，叠加无意义）
            if store.fogArchive == nil, store.settings.heatMap, store.settings.fogMap {
                store.updateSetting(\.fogMap, to: false)
            }
        }
        .onChange(of: store.settings.fogMap) {
            // 从查看点/热力图进入迷雾：底图快速渐变到 100%（滑轨平滑随动）
            if store.settings.fogMap, store.track != nil, store.settings.mapOpacity < 0.999 {
                store.animateMapOpacity(to: 1.0)
            }
            if store.settings.fogMap, store.settings.heatMap {
                store.updateSetting(\.heatMap, to: false)
            }
        }
        .onChange(of: store.settings.colorMode) { store.recolorNow() }
        .onChange(of: store.settings.singleColor) {
            if store.settings.colorMode == .single { store.recolorNow() }
        }
        .sheet(isPresented: $store.showExportSheet) { ExportSheet(store: store) }
        .sheet(isPresented: $store.showSettingsSheet) { settingsSheet }
        .modifier(ExternalMapNoticeAlert(isPresented: $store.externalMapNotice))
        .sheet(isPresented: $store.showImageExportSheet) { imageExportSheet }
        .sheet(isPresented: $store.showVideoExportSheet) { videoExportSheet }
        .alert("确认删除 \(store.executePrompt ?? 0) 个点？", isPresented: executeBinding) {
            Button("删除", role: .destructive) { store.confirmExecuteStaged() }
            Button("取消（什么都不删）", role: .cancel) { store.discardStagedAndExit() }
        } message: {
            Text("其余点保持原样。此确认为最终操作（预删除阶段随时可 ⌘Z 逐步撤销）。确认或取消后都会退出删除模式。")
        }
        .alert("应用补点？", isPresented: fillPromptBinding) {
            if let p = store.fillPrompt, p.remove > 0 {
                Button("插入 \(p.insert) 个点，替换区间内 \(p.remove) 个点", role: .destructive) {
                    store.confirmApplyFill(removeInner: true)
                }
                Button("插入 \(p.insertKeep) 个点，保留区间内 \(p.remove) 个点原样") {
                    store.confirmApplyFill(removeInner: false)
                }
            } else {
                Button("插入 \(store.fillPrompt?.insert ?? 0) 个点") {
                    store.confirmApplyFill(removeInner: false)
                }
            }
            Button("取消", role: .cancel) { store.fillPrompt = nil }
        } message: {
            Text(store.fillPrompt?.message ?? "")
        }
        .alert("清理 \(store.replayPrompt ?? 0) 个回放点？", isPresented: replayPromptBinding) {
            Button("删除 \(store.replayPrompt ?? 0) 个回放点", role: .destructive) { store.confirmCleanReplays() }
            Button("取消", role: .cancel) { store.replayPrompt = nil }
        } message: {
            Text("这些点的坐标与几分钟前某个点一字不差，期间轨迹已离开几百米，而且是在移动中记下的：是设备没信号时回放的旧位置，不是新的定位。删掉后几何不变（每个位置首次出现的点留着），时间线会少掉这些来回；会记成一条「回放点清理」修改记录，可随时还原。",
                 comment: "Message of the clean-replay-points alert. The quoted term is the change-log entry type “Replay Cleanup”.")
        }
        .alert("套用到 \(store.fillSimilarPrompt?.count ?? 0) 处相似断档？", isPresented: fillSimilarBinding) {
            Button("套用") { store.confirmApplySimilar() }
            Button("取消", role: .cancel) { store.fillSimilarPrompt = nil }
        } message: {
            Text("两端都在 300 米内的断档会用同一条折线（反向自动倒序）补上，锚点取各自的两端；一次重建，可整批撤销。")
        }
        .alert("无法加载", isPresented: errorBinding) {
            Button(role: .cancel) {} label: { Text("好", comment: "OK button of the load-error alert") }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onExitCommand {
            if store.deleteMode { store.discardStagedAndExit() }
            if store.fillMode { store.exitFillMode() }
        }
    }

    /// 闲置展示模式：UI 面板快速渐隐（有鼠标动作立即渐现）
    private var uiFade: Double { store.presenting ? 0 : 1 }

    /// 地球视角悬浮控件：写实/像素 风格切换 + 像素模式的地名开关
    private var globeStyleControls: some View {
        Group {
            if store.globeShowing {
                VStack(alignment: .trailing, spacing: 8) {
                    Picker("地球风格", selection: store.binding(\.globeStyle)) {
                        ForEach(GlobeStyle.allCases) { st in
                            Text(st.title).tag(st)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)

                    if store.settings.globeStyle == .pixel {
                        Toggle("地名", isOn: store.binding(\.showPixelLabels))
                            .font(.caption)
                            .toggleStyle(.checkbox)
                    }
                }
                .padding(10)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            }
        }
    }

    // MARK: - 高清图片导出选项

    @State private var imgExportWidth = 3840
    @State private var imgExportTransparent = false
    @State private var imgExportScaleBar = true

    @AppStorage("videoWidth") private var vidExportWidth = 1920

    private var videoExportSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导出回放视频")
                .font(.headline)
            Text("把整段时光机回放离屏渲染为 H.264 视频（含底图、生长中的轨迹/迷雾与时间轴）。时长 = 当前回放时长，可先在时间轴调整。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("分辨率").font(.callout).frame(width: 60, alignment: .leading)
                Picker("分辨率", selection: $vidExportWidth) {
                    Text("720p（1280×720）").tag(1280)
                    Text("1080p（1920×1080）").tag(1920)
                    Text("4K（3840×2160）").tag(3840)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Divider()
            HStack {
                Spacer()
                Button("取消") { store.showVideoExportSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("导出…") {
                    store.showVideoExportSheet = false
                    store.requestVideoExport(VideoExportOptions(pixelWidth: vidExportWidth))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430)
    }

    /// .fwdb 存档作为数据源（无 GPX 轨迹）：点云/轨迹线相关控件不适用
    private var fwdbMode: Bool { store.fwdbActive }

    private var imageExportSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导出图片")
                .font(.headline)
            Text(store.globeShowing ? "导出当前地球视角（含点云/像素柱）"
                                    : "导出当前平面视图（底图 + 点云，所见即所得）")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("分辨率").font(.callout).frame(width: 60, alignment: .leading)
                Picker("分辨率", selection: $imgExportWidth) {
                    Text("4K（3840 宽）").tag(3840)
                    Text("8K（7680 宽）").tag(7680)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Toggle("透明背景（只导出点云图层）", isOn: $imgExportTransparent)
                .toggleStyle(.checkbox)
                .font(.callout)
            if !store.globeShowing {
                Toggle("绘制比例尺", isOn: $imgExportScaleBar)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .disabled(imgExportTransparent)
            }

            Divider()
            HStack {
                Spacer()
                Button("取消") { store.showImageExportSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("导出…") {
                    store.showImageExportSheet = false
                    store.requestImageExport(ImageExportOptions(
                        pixelWidth: imgExportWidth,
                        transparentBackground: imgExportTransparent,
                        includeScaleBar: imgExportScaleBar && !imgExportTransparent))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    // MARK: - 对比模式顶栏（居中悬浮：文件、交换、共享显示设置；不偏占任何一侧）

    private var compareBar: some View {
        HStack(spacing: 10) {
            compareChip(side: 0)
            Button {
                store.toggleCompareSwap()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .help("交换左右")
            compareChip(side: 1)

            Divider().frame(height: 16)

            if let r = store.diffResult {
                let lCnt = store.compareSwap ? r.rightOnly.count : r.leftOnly.count
                let rCnt = store.compareSwap ? r.leftOnly.count : r.rightOnly.count
                Text("左独有 \(lCnt.formatted()) · 右独有 \(rCnt.formatted())")
                    .font(.caption.monospacedDigit())
                Button {
                    openWindow(id: SceneID.diff)
                } label: {
                    Image(systemName: "macwindow.badge.plus")
                }
                .help("在独立窗口展示差异点（两色可选）")
                Button {
                    store.clearDiff()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .help("清除差异高亮")
            } else {
                Button {
                    store.computeDiff()
                } label: {
                    Label("找不同", systemImage: "plus.forwardslash.minus")
                        .font(.caption)
                }
                .disabled(store.diffBusy || store.compareTracks == nil)
                .help("两个文件的点集差异：各自独有的点高亮，其余变灰（多重集匹配：坐标 ≈0.1m + 秒级时间）")
                Toggle("含时间", isOn: $store.diffMatchTime)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("勾选 = 坐标+时间都相同才算同一个点；取消 = 只比坐标")
            }

            Divider().frame(height: 16)

            Text("点大小").font(.caption)
            Slider(value: store.binding(\.pointSize), in: 1...12).frame(width: 70)
            Text("点透明").font(.caption)
            Slider(value: store.binding(\.opacity), in: 0.15...1).frame(width: 70)
            Text("底图").font(.caption)
            Slider(value: store.binding(\.mapOpacity), in: 0.2...1).frame(width: 70)

            Divider().frame(height: 16)

            Button("退出对比") { store.switchDisplayMode(to: .overlay) }
                .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thickMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    /// 对比顶栏的文件角标（side 0 = 左，1 = 右；随交换实时对应）
    @ViewBuilder
    private func compareChip(side: Int) -> some View {
        let idx = store.compareSwap ? (1 - side) : side
        if idx < store.files.count {
            let f = store.files[idx]
            HStack(spacing: 4) {
                Text(side == 0
                     ? LocalizedStringResource("compare.badge.left", defaultValue: "左",
                                               comment: "Compare mode top bar: badge before the file shown on the LEFT half (one short word/letter)")
                     : LocalizedStringResource("compare.badge.right", defaultValue: "右",
                                               comment: "Compare mode top bar: badge before the file shown on the RIGHT half (one short word/letter)"))
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Text(f.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 140)
                Button {
                    store.closeFile(f.id)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭此文件（退出对比，回到单文件）")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }

    // MARK: - 迷雾统计卡（《世界迷雾》口径）

    private var fogStatsCard: some View {
        Group {
            if store.showFogStats,
               store.settings.fogMap || store.fwdbActive,
               store.track != nil || store.fwdbActive {
                VStack(alignment: .leading, spacing: 5) {
                    Text("迷雾统计 · 世界迷雾口径")
                        .font(.caption.bold())
                    if let s = store.fogStats {
                        fogStatRow("等级", "Lv. \(s.level)")
                        fogStatRow("探索面积", "\(s.km2.formatted(Fmt.f3)) km²")
                        fogStatRow("地球占比", "\(s.percent.formatted(Self.fogPercentStyle)) %")
                        fogStatRow("解锁格子", s.cells.formatted())
                        fogStatRow("距下一级", "\(s.nextLevelKm2.formatted(Fmt.f3)) km²")
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("计算中…").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .frame(width: 210, alignment: .leading)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            }
        }
    }

    /// 地球占比：8 位小数、不分组，小数点随界面语言（Fmt 只有 f0…f3）
    private static let fogPercentStyle = FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.fractionLength(8))

    private func fogStatRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption2.monospacedDigit())
        }
    }

    // MARK: - 文件列表（重叠模式）

    /// .fwdb 多存档列表：勾选显隐（并集渲染/统计）+ 逐个关闭
    private var fwdbListPanel: some View {
        Group {
            if fwdbMode, store.fogArchiveFiles.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("迷雾存档").font(.caption.bold())
                        Spacer()
                        Text(LocalizedStringResource("count.archives", defaultValue: "\(store.fogArchiveFiles.count) 个",
                                                     comment: "Fog archive list header, right side: number of loaded fog archives (%lld)"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.fogArchiveFiles) { a in
                        HStack(spacing: 6) {
                            Toggle("显示此存档", isOn: Binding(
                                get: { store.fogArchiveFiles.first(where: { $0.id == a.id })?.enabled ?? true },
                                set: { _ in store.toggleArchive(a.id) }))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .help("勾选显示 / 取消隐藏该存档（统计取勾选存档的并集，重叠格只算一次）")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(a.archive.stats.cells.formatted()) 格")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button {
                                store.closeArchive(a.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("移除此存档")
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(a.enabled ? 0.08 : 0.03),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .opacity(a.enabled ? 1 : 0.55)
                    }
                }
                .padding(10)
                .frame(width: 230)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                .opacity(uiFade)
                .animation(.easeInOut(duration: 0.3), value: store.presenting)
            }
        }
    }

    private var fileListPanel: some View {
        Group {
            if store.displayMode == .overlay, !store.files.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("文件列表").font(.caption.bold())
                        Spacer()
                        Text(LocalizedStringResource("count.files", defaultValue: "\(store.files.count) 个",
                                                     comment: "File list header (overlay mode), right side: number of loaded GPX files (%lld)"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.files) { f in
                        fileRow(f)
                    }
                    if store.files.count == 2 {
                        Button {
                            store.switchDisplayMode(to: .compare)
                        } label: {
                            Label("进入对比模式", systemImage: "rectangle.split.2x1")
                        }
                        .font(.caption)
                    }
                    Text(store.settings.fogMap
                         ? "勾选控制各文件的消雾轨迹显隐"
                         : "点击文件名可在地图上高亮对应轨迹")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(width: 230)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                .opacity(uiFade)
                .animation(.easeInOut(duration: 0.3), value: store.presenting)
            }
        }
    }

    /// 单个文件行：色标取色器 + 名称（点击闪烁高亮）+ 关闭；行底色跟随文件色。
    /// 迷雾模式下点色无意义：色标换成显隐勾选（GPU 端按 fileID 位掩码过滤消雾）
    private func fileRow(_ f: LoadedFile) -> some View {
        let fileIdx = store.files.firstIndex(where: { $0.id == f.id }) ?? 0
        return HStack(spacing: 6) {
            if store.settings.fogMap {
                if fileIdx < 32 {
                    Toggle("显示此文件的消雾轨迹", isOn: Binding(
                        get: { store.files.first(where: { $0.id == f.id })?.fogVisible ?? true },
                        set: { store.setFileFogVisible(f.id, $0) }))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .frame(width: 26)
                        .help("勾选显示 / 取消隐藏该文件的消雾轨迹")
                } else {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .frame(width: 26)
                        .help("迷雾显隐仅支持前 32 个文件，此文件恒显示")
                }
            } else {
            ColorPicker("点颜色", selection: Binding(
                get: { store.files.first(where: { $0.id == f.id })?.color ?? f.color },
                set: { store.setFileColor(f.id, $0) }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 26)
                .help("此文件的点颜色")
            }
            Group {
                if store.settings.fogMap {
                    // 迷雾模式：点云不绘制，闪烁高亮无视觉效果——纯文本展示
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(f.parsed.count.formatted()) 点")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        store.flashFile(f.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.name)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(f.parsed.count.formatted()) 点")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("点击在地图上高亮此文件的轨迹")
                }
            }
            Spacer(minLength: 0)
            Button {
                store.closeFile(f.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭此文件")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(store.settings.fogMap ? Color.primary.opacity(f.fogVisible ? 0.08 : 0.03)
                                          : f.color.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 6))
        .opacity(store.settings.fogMap && !f.fogVisible ? 0.55 : 1)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { store.errorMessage != nil },
                set: { if !$0 {
                    store.errorMessage = nil
                    store.noteUserActivity()   // 关闭弹窗后闲置计时从此刻重新起算
                } })
    }

    private var executeBinding: Binding<Bool> {
        Binding(get: { store.executePrompt != nil },
                set: { if !$0 { store.executePrompt = nil } })
    }

    private var fillPromptBinding: Binding<Bool> {
        Binding(get: { store.fillPrompt != nil },
                set: { if !$0 { store.fillPrompt = nil } })
    }
    private var replayPromptBinding: Binding<Bool> {
        Binding(get: { store.replayPrompt != nil },
                set: { if !$0 { store.replayPrompt = nil } })
    }

    private var fillSimilarBinding: Binding<Bool> {
        Binding(get: { store.fillSimilarPrompt != nil },
                set: { if !$0 { store.fillSimilarPrompt = nil } })
    }

    private var deleteModeHint: some View {
        Group {
            if store.deleteMode {
                HStack(spacing: 12) {
                    Text("预删除：按住拖拽手绘圈选（松手自动首尾连线）· 右键拖拽平移")
                        .font(.caption)
                    Text("已选 \(store.stagedCount.formatted())")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(store.stagedCount > 0 ? Color.red : Color.primary.opacity(0.6))
                    Button("撤销") { store.undoStage() }
                        .disabled(store.stageSteps == 0)
                        .keyboardShortcut("z", modifiers: .command)
                        .help("撤销上一次圈选（可连续撤销，⌘Z）")
                    Button("执行删除…") { store.requestExecuteStaged() }
                        .disabled(store.stagedCount == 0)
                    Button("退出(不删)") { store.discardStagedAndExit() }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thickMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            }
        }
    }

    /// 补点模式操作条（底部居中、两行，窗口窄时也不压左右面板；说明放 tooltip，点距滑杆在候选面板）
    private var fillModeHint: some View {
        Group {
            if store.fillMode {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        if store.fillActive {
                            HStack(spacing: 1) {
                                Text(verbatim: "A").font(.caption2.bold()).foregroundStyle(.red)
                                Button { store.moveFillAnchor(a: true, by: -1) } label: { Image(systemName: "chevron.left") }
                                Button { store.moveFillAnchor(a: true, by: 1) } label: { Image(systemName: "chevron.right") }
                                Text(verbatim: "B").font(.caption2.bold()).foregroundStyle(.red).padding(.leading, 4)
                                Button { store.moveFillAnchor(a: false, by: -1) } label: { Image(systemName: "chevron.left") }
                                Button { store.moveFillAnchor(a: false, by: 1) } label: { Image(systemName: "chevron.right") }
                            }
                            .buttonStyle(.borderless)
                            .help("锚点逐点前后挪（隧道里常有漂移点，真实两端未必相邻）；⌥点击轨迹点也可直接设锚点")
                            Text("顶点 \(store.fillVertices.count)")
                                .font(.caption.monospacedDigit())
                                .help("拖动线段中点的小空心圆 = 在这段上加顶点；拖动顶点调整；双击或右键顶点删除；⌘Z 撤销上一步")
                            if store.fillRemoveCount > 0 {
                                Text("区间内 \(store.fillRemoveCount)")
                                    .font(.caption.monospacedDigit().bold())
                                    .foregroundStyle(Self.fillInnerPink)
                                    .help(store.fillInnerStaleLag == nil
                                          ? Text("两锚点之间现有的点（粉色），应用时可选替换或保留")
                                          : store.fillHasSeededVertices
                                            ? Text("两锚点之间现有的点（粉色）：设备重新定位后带着过时时间戳的出口点，位置已保留为折线顶点；应用时「替换」为时间正确的点",
                                                   comment: "Tooltip on the in-range point count (pink points). The quoted word is the Replace button of the apply-fill alert.")
                                            : Text("两锚点之间现有的点（粉色）：设备重新定位后带着过时时间戳的出口点；它们的顶点已被删掉，「替换」会把这些点删掉并由折线上的合成点接上",
                                                   comment: "Tooltip on the in-range point count (pink points). The quoted word is the Replace button of the apply-fill alert."))
                            }
                            Button("撤销") { store.undoFillVertex() }
                                .disabled(!store.fillCanUndoVertex || store.fillDragging)
                                .keyboardShortcut("z", modifiers: .command)
                                .help("撤销上一步编辑：插入/拖动/删除顶点、挪锚点（⌘Z）")
                            Button("应用…") { store.requestApplyFill() }
                                .buttonStyle(.borderedProminent)
                                .disabled(store.batchActive)
                                .help(store.batchActive ? "批量补点进行中：请在批量窗口里落地或放弃" : "沿折线按间距插点、时间匀速插值，确认后落地")
                            if let busy = store.fillRouteBusy {
                                ProgressView().controlSize(.small)
                                Text(store.fillRouteProgress
                                     ?? String(localized: "请求 \(busy.label)…",
                                               comment: "Fill mode bar: road-network request in flight; %@ = route source label (e.g. \"OSRM road\" / \"Overpass rail\")"))
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                    .frame(width: 240, alignment: .leading)
                                    .help([store.fillRouteProgress, store.fillRouteProgressDetail].compactMap { $0 }.joined(separator: "\n"))
                                Button("取消") { store.cancelRouteRequest() }
                                    .help("中断这次路网请求，顶点保持原样")
                            } else {
                                Menu("路网草稿") {
                                    Button("沿公路取路径（OSRM · OpenStreetMap）") { store.requestRouteDraft(.osrmCar) }
                                    Button("沿公路取路径并交叉验证（OSRM + Valhalla）") { store.requestCrossCheckedDraft() }
                                    Button("沿铁路取路径（Overpass · OpenStreetMap）") { store.requestRouteDraft(.overpassRail) }
                                }
                                .fixedSize()
                                .disabled(health.offline)
                                .help("向公共 OpenStreetMap 服务请求 A→B 的路网路径，替换当前全部顶点作为草稿（可撤销、可继续手动调）。只在点击时联网，一次一个请求；「交叉验证」同时请求 OSRM 和 Valhalla 并比对，一致才算放心。同一处同样输入第二次直接用本文件打开以来取过的结果（缓存）")
                                if store.fillRouteInfo != nil, store.fillRouteInfo?.source != .deleteOnly {
                                    Button("重新取（忽略缓存）") { store.refetchRouteDraft() }
                                        .disabled(health.offline)
                                        .help("不用缓存，按当前草稿的来源向路网再请求一次（交叉验证的两份都重取），新结果覆盖缓存")
                                }
                                if let x = store.fillCrossDrafts {
                                    // 交叉验证取回的两份草稿：来回切换着看（一致时差别很小；每次切换可 ⌘Z）
                                    Picker("显示", selection: Binding<Int>(get: { x.shown.source == .osrmCar ? 0 : 1 },
                                                                          set: { if $0 != (x.shown.source == .osrmCar ? 0 : 1) { store.swapCrossDraft() } })) {
                                        Text(verbatim: "OSRM").tag(0); Text(verbatim: "Valhalla").tag(1)
                                    }
                                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                                    .disabled(store.fillRouteBusy != nil)
                                    .help(x.agree ? "两路一致：切换着看两份草稿（差别很小，可撤销）" : "两路不一致：切换着对比两份草稿，看准了再「应用」（可撤销）")
                                }
                            }
                        } else {
                            Text("在右侧列表选一处断档；然后拖橙线中点的小空心圆加顶点、拖顶点把线塑成隧道的形状")
                                .font(.caption)
                        }
                    }
                    if store.fillActive {
                        // 图例按模式只列画面上真有的东西
                        HStack(spacing: 8) {
                            Circle().stroke(Color.red, lineWidth: 2).frame(width: 9, height: 9)
                            Text("红圈 = 断档两端 A/B（沿轨迹拖动可换）")
                            if store.batchActive {
                                Rectangle().fill(Color.green).frame(width: 14, height: 3)
                                Text("绿 = 路网草稿")
                                Rectangle().fill(Color.orange).frame(width: 14, height: 3)
                                Text("橙 = 草稿有警告")
                                Rectangle().fill(Color.gray).frame(width: 14, height: 3)
                                Text("灰 = 直线")
                                Rectangle().fill(Color.red).frame(width: 14, height: 3)
                                Text("红虚线 = 失败/不落地")
                                if (store.batch?.conflictCount ?? 0) > 0 {
                                    Rectangle().fill(Color.blue).frame(width: 14, height: 3)
                                    Text("蓝 = 等你选的两路（实线 OSRM、虚线 Valhalla），在批量窗口选一条")
                                }
                            } else {
                                legendDot(fill: .orange, stroke: .white, size: 9)
                                Text("橙线 = 补点走向（拖顶点调整，双击删；拖段中点加顶点）")
                                if store.fillShowPoints {
                                    legendDot(fill: .orange, stroke: .white, size: 7)
                                    Text("橙点 = 要补的点")
                                }
                            }
                            Text(verbatim: "×").font(.caption.bold()).foregroundStyle(Self.fillInnerPink)
                            Text("粉 × = 区间内原始点")
                        }
                        .font(.caption2)
                    }
                    HStack(spacing: 8) {
                        Button(store.batchActive ? "批量补点窗口" : "一键补全部…") {
                            if !store.batchActive { store.startBatchPlanning() }
                            openWindow(id: SceneID.batchFill)
                        }
                        .disabled(store.gapCandidates.isEmpty || store.isLoading || (health.offline && !store.batchActive))
                        .help(health.offline ? "当前离线：取路网草稿需要联网" : "把当前列表里的断档一次取路网草稿：先确认每处走公路还是铁路，取完在主地图预览，再一次落地")
                        if store.lastFill != nil {
                            Button("套用相似…") { store.requestApplySimilar() }
                                .disabled(store.batchActive)
                                .help("两端都在 300 米内的其它断档，用同一条折线一次补完")
                        }
                        Button("撤销落地") { store.undoLastFill() }
                            .disabled(!store.fillCanUndo || store.batchActive)
                            .help("整批撤回上一次落地的补点")
                        Button(store.changes.isEmpty ? "修改记录" : "修改记录 \(store.changes.count)") { store.openChangeLog(); openWindow(id: SceneID.changeReview) }
                            .help("本次会话的全部修改：总览 / 逐处校验 / 一键还原某一处")
                        Menu("导出") {
                            Button("整条轨迹 GPX（含时间/速度/海拔）…") { store.exportGPX(range: nil) }
                            Button("仅补点增量 GPX（含时间/速度/海拔）…") { store.exportFillsGPX() }
                                .disabled(store.fills.isEmpty)
                        }
                        .fixedSize()
                        .help("整条：首次导入目标 app 用。增量：目标 app 里已有这条轨迹时只补新点；增量表达不了删除，替换掉的原始点会留在目标 app 里")
                        Button("退出") { store.exitFillMode() }
                            .fixedSize()          // 状态行再长也不挤它（简中曾显示成「退…」）
                            .layoutPriority(1)
                        routeStatusLabel
                    }
                    NetworkBanner()
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            }
        }
    }

    /// 比例尺单独观察 scaleBarState（平移/缩放时每 0.12 s 变一次，不惊动整棵视图树）
    private var scaleBarView: some View { ScaleBarLayer(state: store.scaleBarState) }

    // MARK: - 断档候选列表（补点模式）

    @State private var gapRailFilter = 0
    /// 底部浮层（回放条 / 补点操作条 / 比例尺）的总高度：补点模式下右列停在它上面
    @State private var bottomStackHeight: CGFloat = 0        // 0 全部 1 非铁路 2 疑似铁路（分类器有把握判铁路的）

    private var gapListPanel: some View {
        Group {
            if store.fillMode {
                let shown = store.filteredGapCandidates.filter { c in
                    let rail = store.classify(c) == .rail
                    return gapRailFilter == 0 || (gapRailFilter == 1 ? !rail : rail)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(shown.count != store.gapCandidates.count
                         ? "断档候选 \(shown.count)（共 \(store.gapCandidates.count)）"
                         : "断档候选 \(shown.count)")
                        .font(.caption.bold())
                    // 分段控件独占一行：和标题挤在 290 pt 面板里时，德文「Lückenkandidaten … Vermutlich Bahn」
                    // 会把控件顶出窗口右边；整行宽度由面板给，三种语言都放得下
                    Picker("断档类型", selection: $gapRailFilter) {
                        Text("全部").tag(0)
                        Text("公路").tag(1)
                        Text("疑似铁路").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .help(Text("「疑似铁路」先按段判（轨迹按停车 ≥10 分钟切段，每段抽几个点问地图附近有没有铁路；批量窗口里可按段手选），段拿不准时按单处：隐含速度 >200 且前后记录速度支持，或前后单步与 10 s 窗口速度都 >170", comment: "Tooltip on the gap-type filter (segmented control). The quoted term is this control's option “Likely Rail”."))
                    WrappingHStack(spacing: 6, lineSpacing: 6) {
                        Button(store.fillRegionDrawing ? "圈选中…（拖拽画）" : (store.fillRegion == nil ? "圈选范围" : "重新圈选")) {
                            store.fillRegionDrawing.toggle()
                        }
                        .help("在地图上按住左键拖拽画一个圈（松手自动闭合），之后只列出、只补两端都在圈里的断档；右键拖拽平移地图")
                        if store.fillRegion != nil {
                            Toggle("反选", isOn: $store.fillRegionInvert).toggleStyle(.checkbox)
                                .help("改为只要圈外的断档")
                            Button("清除") { store.setFillRegion(nil) }
                        }
                        if store.viewFilter != nil {
                            Toggle("只看时间筛选内", isOn: $store.fillFollowTimeFilter).toggleStyle(.checkbox)
                                .help(Text("左侧「时间筛选」选了日/自定义时，只列那段时间里的断档", comment: "Tooltip on the 'only inside time filter' toggle. The quoted term is the “Time Filter” section of the left panel."))
                        }
                        Toggle("合并隧道群", isOn: $store.fillMergeChains).toggleStyle(.checkbox)
                            .disabled(store.batchActive)
                            .help("相邻两处断档之间只有 ≤3 个点、≤90 秒时并成一处一次补完（隧道群之间手机常只记到一两个离路几百米的假点，并起来后这些点随区间替换）。Garmin 隧道群之间是几十个贴路的真实点，不会被并")
                        Toggle("只补公路", isOn: $store.fillRoadOnly).toggleStyle(.checkbox)
                            .help(Text("勾上则批量里疑似铁路的一律跳过。不勾时铁路也补，但只补判定为隧道的断档（OSM 铁路 tunnel 标签占 ≥50%、直线 ≤60 km、≤25 分钟），车厢里没信号造成的长空洞标「不补」；单处补点不受影响", comment: "Tooltip on the road-only toggle. Contains a literal percent sign (share of OSM tunnel tags). The quoted term is the batch status “Don't Fill”."))
                        Toggle("找乱跳", isOn: $store.fillJitter).toggleStyle(.checkbox)
                            .disabled(store.batchActive)
                            .help(Text("乱跳：没有时间空洞，但点在相隔几百米到几公里的位置之间来回跳（车厢里没信号时设备回放旧位置，或两路定位交替；手机上的 Garmin Explore App 在火车里就是这样，专用记录仪没有这个问题）。按步判「大跳」（远超当时车速与噪声能走出的距离）和「倒退」（相对行进方向后退几百米），直到后面连续 20 秒步步合理才算结束。乱跳段当断档列出：有路径就整段替换，取不到路径就只删乱跳点", comment: "Tooltip on the find-jitter toggle. The two quoted terms are the step categories “big jumps” and “reversals”."))
                        if store.replayCount > 0 {
                            Button("清理回放点 \(store.replayCount)") { store.requestCleanReplays() }
                                .disabled(store.batchActive || store.isLoading)
                                .help(Text("回放点：坐标与几分钟前某个点一字不差、期间轨迹已离开几百米、而且这个点是在移动中记下的——真 GPS 移动中不会这样，是设备没信号时在回放存过的旧位置（手机、Garmin Explore 在车厢里常见）。删掉它们几何不变（首次出现的那个点留着），乱跳候选也会清爽很多。可在「修改记录」里一键还原", comment: "Tooltip on the clean-replay-points button. The quoted term is the “Change Log” window."))
                        }
                        if store.tripMapRunning, let p = store.tripMapProgress {
                            ProgressView().controlSize(.mini)
                            Text("地图判段 第 \(min(p.done + 1, max(1, p.total)))/\(p.total) 批").monospacedDigit().lineLimit(1)
                                .help(store.tripMapPhase)
                        } else if !store.trips.isEmpty {
                            Button("地图判段") { store.resolveTripsByMap(force: store.trips.allSatisfy { store.tripMap[$0.index] != nil }) }
                                .disabled(health.offline)
                                .help(Text("联网：轨迹按停车切成 \(store.trips.count) 段，每段抽 3–8 个行驶中的点问 OpenStreetMap 附近有没有铁路，整段定公路还是铁路（「疑似铁路」筛选与批量分类都按它）", comment: "Tooltip on the map-segmentation button; %lld = number of trip segments. The quoted term is the gap filter option “Likely Rail”."))
                        }
                    }
                    .font(.caption2)
                    if store.candidatesRefreshing {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("大文件：正在后台找断档、回放点和乱跳段…").font(.caption2).foregroundStyle(.secondary) }
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(shown) { c in
                                    let active = store.fillAnchorA == c.indexA
                                    Button {
                                        store.selectGap(c)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Text(Self.gapTimeText(c.tA))
                                                .font(.caption2.monospacedDigit())
                                                .frame(width: 96, alignment: .leading)
                                            Text(verbatim: c.meters >= 1000
                                                 ? "\((c.meters / 1000).formatted(Fmt.f1))km"
                                                 : "\(c.meters.formatted(Fmt.f0))m")
                                                .font(.caption2.monospacedDigit())
                                                .frame(width: 46, alignment: .trailing)
                                            Text(verbatim: c.seconds >= 60
                                                 ? "\((c.seconds / 60).formatted(Fmt.f0))min"
                                                 : "\(c.seconds.formatted(Fmt.f0))s")
                                                .font(.caption2.monospacedDigit())
                                                .frame(width: 40, alignment: .trailing)
                                            Text(verbatim: "\(c.kmh.formatted(Fmt.f0))km/h")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(store.classify(c) == .rail ? Color.purple : Color.secondary)
                                                .frame(width: 48, alignment: .trailing)
                                            Image(systemName: c.kind == .staleClock ? "clock.badge.exclamationmark" : (c.kind == .jitter ? "arrow.left.arrow.right" : "clock"))
                                                .font(.caption2)
                                                .foregroundStyle(c.kind == .jitter ? Color.orange : Color.secondary)
                                                .help(gapKindHelp(c))
                                            if c.chainCount > 1 {
                                                Text(verbatim: "×\(c.chainCount)").font(.caption2.bold()).foregroundStyle(.orange)
                                                    .help("隧道群：由 \(c.chainCount) 处相邻断档并成，中间夹的 \(c.innerCount) 个点随区间替换")
                                            }
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(active ? Color.accentColor.opacity(0.25) : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 5))
                                    }
                                    .buttonStyle(.plain)
                                    .id(c.id)
                                }
                            }
                        }
                        .frame(maxHeight: 320)
                        .onChange(of: store.fillAnchorA) {
                            if let a = store.fillAnchorA,
                               let c = store.gapCandidates.first(where: { $0.indexA == a }) {
                                proxy.scrollTo(c.id, anchor: .center)
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        Text("点距").font(.caption)
                        Slider(value: $store.fillSpacingMeters, in: 5...100, step: 5)
                        Text(verbatim: "\(Int(store.fillSpacingMeters))m")
                            .font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                        if store.fillSpacingManual {
                            Button("跟随原始") { store.followOriginalSpacing() }
                                .font(.caption2).buttonStyle(.plain).foregroundStyle(.blue)
                                .help("改回按这处断档两侧的原始点距自动取（原始点距本身，5–100 m）")
                        }
                        Toggle("显示补的点", isOn: $store.fillShowPoints).toggleStyle(.checkbox).font(.caption)
                            .help("把按当前点距要插进去的合成点画出来（橙点），折线照旧；落地的就是这些点")
                    }
                    .help("合成点间距。没拖过滑块时按断档两侧的原始点距自动取（原始点距本身，5–100 m）；世界迷雾按相邻点连线解锁，一生足迹按点显示")
                    if let s = store.fillLocalStep {
                        Text(store.fillSpacingManual
                             ? "原始点距 ≈\(s.meters, specifier: "%.0f") m / \(s.dt, specifier: "%.0f") s（手动）"
                             : "原始点距 ≈\(s.meters, specifier: "%.0f") m / \(s.dt, specifier: "%.0f") s（自动跟随）")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let s = store.fillSampling {
                        Text(s.shortText).font(.caption2).foregroundStyle(.secondary).lineLimit(2).help(LocalSampling.helpText)
                    }
                    if let p = store.samplingProfile {
                        Text(p.summary)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .help(String(localized: "\(p.summary)\n换算的门槛：\(p.derivedSummary)\n画像决定匹配半径与过时时钟检测开关；上下文取点上限 600 m / 600 s，方向取点 25–300 m / 600 s，匹配取点上限 5 km / 180 s（都是绝对量）；点距按断档两侧原始步长（15–60 m）",
                                         comment: "Gap list: tooltip on the sampling-profile line. %1$@ = profile summary (e.g. device type + typical step), %2$@ = derived thresholds; then a fixed paragraph on what the profile controls"))
                    }
                    Text("时间 · 直线距离 · 时长 · 隐含速度。点一行飞过去并把两端设为锚点")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(width: 290)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    /// 断档行成因图标的说明：三种成因各是一整句（String 场景，逐句本地化；插值先取成局部量）
    private func gapKindHelp(_ c: GapCandidate) -> String {
        let inner = c.innerCount
        switch c.kind {
        case .staleClock:
            return String(localized: "出口处 \(inner) 个点带过时时间戳（Garmin 类设备）：位置保留为折线顶点，应用时替换为时间正确的点",
                          comment: "Gap list row: tooltip on the stale-clock icon; %lld = number of exit points carrying stale timestamps")
        case .jitter:
            let jumps = c.jitterJumps
            let reversals = c.jitterReversals
            let maxJump = Int(c.jitterMaxJump)
            return String(localized: "乱跳：两锚点之间 \(inner) 个点在相隔几百米到几公里的位置之间来回跳（大跳 \(jumps) 步、倒退 \(reversals) 步，最大一步 \(maxJump) m）——车厢里没信号时设备回放旧位置或两路定位交替。批量：有路径就整段替换，取不到路径就只删这些点；单处：不画折线直接「应用」= 只删乱跳点，取了路网就整段替换",
                          comment: "Gap list row: tooltip on the jitter icon. %1$lld = points between the anchors, %2$lld = big-jump steps, %3$lld = reversal steps, %4$lld = largest single step in metres. The quoted button name is the Apply… button of the fill bar")
        default:
            let cause = store.gapSampling[c.id]?.shortText
                ?? String(localized: "成因未知", comment: "Gap list row tooltip: the cause of this time gap could not be determined")
            return String(localized: "时间空洞 · \(cause)",
                          comment: "Gap list row: tooltip on the time-gap clock icon; %@ = short sampling diagnosis (cause of the gap)")
        }
    }

    private static let gapTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")      // 纯数字格式：不随界面语言/历法变
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yy-MM-dd HH:mm"
        return f
    }()

    /// 区间内现有点的高亮色（与 TrackStore.rebuildFillColors 的 255,60,170 一致）
    private static let fillInnerPink = Color(red: 1.0, green: 60.0 / 255, blue: 170.0 / 255)

    /// 悬停卡放哪：光标右下 → 左下 → 右上 → 左上，取第一个既在窗口内又不压到任何面板的；都不行就取压得最少的
    static func tooltipOrigin(cursor c: CGPoint, size: CGSize, bounds: CGSize, avoid: [CGRect]) -> CGPoint {
        let gap: CGFloat = 16
        var candidates = [
            CGPoint(x: c.x + gap, y: c.y + gap),
            CGPoint(x: c.x - gap - size.width, y: c.y + gap),
            CGPoint(x: c.x + gap, y: c.y - gap - size.height),
            CGPoint(x: c.x - gap - size.width, y: c.y - gap - size.height),
        ]
        // 光标就在某个面板里/边上时，四个角都会压到它：再给"面板左侧"和"面板上方"两个位置
        for r in avoid where r.insetBy(dx: -gap - size.width, dy: -gap - size.height).contains(c) {
            candidates.append(CGPoint(x: r.minX - 8 - size.width, y: min(c.y - size.height / 2, r.maxY - size.height)))
            candidates.append(CGPoint(x: min(c.x - size.width / 2, r.maxX - size.width), y: r.minY - 8 - size.height))
        }
        func clamp(_ o: CGPoint) -> CGPoint {
            CGPoint(x: min(max(0, o.x), max(0, bounds.width - size.width)),
                    y: min(max(0, o.y), max(0, bounds.height - size.height)))
        }
        var best = clamp(candidates[0])
        var bestScore = CGFloat.infinity
        for o in candidates {
            let r = CGRect(origin: clamp(o), size: size)
            let overlap = avoid.reduce(0) { $0 + $1.intersection(r).size.width * $1.intersection(r).size.height }
            let cursorCovered = r.insetBy(dx: -4, dy: -4).contains(c) ? 1.0 : 0.0
            let score = overlap + cursorCovered * 1e6
            if score < bestScore { bestScore = score; best = r.origin }
            if score == 0 { break }
        }
        return best
    }

    /// 路网来源标签：用户要求必须标明是否用了路网、来源是什么
    private var routeStatusLabel: some View {
        Group {
            if let r = store.fillRouteInfo {
                let helpLines: [String] = [r.source.detail,
                                           String(localized: "服务器：\(r.endpoint)",
                                                  comment: "Route status tooltip line; %@ = host name of the routing server actually used"),
                                           String(localized: "两端吸附 \(r.snapA, format: Fmt.f0) m / \(r.snapB, format: Fmt.f0) m",
                                                  comment: "Route status tooltip line: distance from anchor A / anchor B to where the route snapped onto the road network; %1$@ / %2$@ = metres"),
                                           RouteSource.attribution]
                    + r.warnings.map { "⚠︎ " + $0 } + r.notes.map { "· " + $0 }
                HStack(spacing: 4) {
                    Image(systemName: r.warnings.isEmpty ? "map" : "exclamationmark.triangle")
                        .foregroundStyle(r.warnings.isEmpty ? Color.secondary : Color.orange)
                    Text(routeStatusText(r))
                        .lineLimit(1).truncationMode(.tail)
                        .help(helpLines.joined(separator: "\n"))
                    // 落地前自检徽标（手改过顶点后不再是那条路线，不显示）
                    if r.edited != true, let p = r.plausibility, p.level != .low { RiskBadge(p: p, hookTarget: true) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Text("路网：未使用（纯手动描线）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(Text("「路网草稿」可向 OSRM（公路）或 Overpass（铁路）取 OpenStreetMap 路网路径；不取就是纯手动描线", comment: "Tooltip on the route status line when no route was fetched. The quoted term is the “Road Draft” menu of the fill bar."))
            }
        }
    }

    /// 路网状态行：各子句独立成句，再用 " · " 连接（可选子句不出现时整句不出现，便于翻译）
    private func routeStatusText(_ r: TrackStore.FillRouteInfo) -> String {
        let source = r.source.label
        let vertices = store.fillVertices.count
        let km = r.meters >= 1000 ? "\((r.meters / 1000).formatted(Fmt.f1)) km" : "\(r.meters.formatted(Fmt.f0)) m"
        var parts = [String(localized: "路网：\(source)",
                            comment: "Fill mode route status line, first clause; %@ = route source label (e.g. \"OSRM road\"). Clauses are joined with ' · '"),
                     String(localized: "\(vertices) 顶点",
                            comment: "Fill mode route status line clause: number of polyline vertices (%lld)"),
                     km]
        if r.shiftA > 0 {
            parts.append(String(localized: "A 前移 \(r.shiftA) 点",
                                comment: "Route status clause: anchor A was moved this many points (%lld) earlier, past drifting tunnel-mouth points"))
        }
        if r.shiftB > 0 {
            parts.append(String(localized: "B 后移 \(r.shiftB) 点",
                                comment: "Route status clause: anchor B was moved this many points (%lld) later, past drifting tunnel-mouth points"))
        }
        if r.edited {
            parts.append(String(localized: "已手动调整",
                                comment: "Route status clause: the fetched route was edited by hand afterwards"))
        }
        if let x = store.fillCrossDrafts {
            parts.append(x.agree ? String(localized: "两路一致", comment: "Route status clause (single-gap cross-check): OSRM and Valhalla agree")
                                 : String(localized: "两路不一致", comment: "Route status clause (single-gap cross-check): OSRM and Valhalla disagree"))
        }
        parts.append("© OpenStreetMap contributors")
        return parts.joined(separator: " · ")
    }

    private func legendDot(fill: Color, stroke: Color, size: CGFloat) -> some View {
        Circle().fill(fill).frame(width: size, height: size)
            .overlay(Circle().stroke(stroke, lineWidth: 1.2))
    }

    private static func gapTimeText(_ t: Double) -> String {
        gapTimeFormatter.string(from: Date(timeIntervalSince1970: t))
    }

    // MARK: - 控制面板

    /// 折叠态：只留一枚展开按钮（快捷键 ⌘O / ⌘, 由隐形按钮继续承接）
    private var collapsedPanelChip: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { panelCollapsed = false }
        } label: {
            Image(systemName: "sidebar.leading")
                .padding(8)
        }
        .buttonStyle(.plain)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
        .help("展开面板")
        .background {
            Group {
                Button { store.openPanel() } label: { EmptyView() }
                    .keyboardShortcut("o", modifiers: .command)
                Button { store.showSettingsSheet = true } label: { EmptyView() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    /// 左侧控制面板：高度够就原样；不够（补点模式下要让出底部操作条的高度）就中间部分可滚动，
    /// 底部两行（导出/图片/删除点/补点、修改记录）固定在底部，永远完整可见
    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .vertical) {
                controlPanelContent
                ScrollView(.vertical) { controlPanelContent }
                    .scrollIndicators(.automatic)
            }
            controlPanelFooter
        }
        .frame(width: 290, alignment: .leading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    @ViewBuilder private var displayToggles: some View {
                if !fwdbMode {
                    Toggle("轨迹线", isOn: store.binding(\.showTrackLine))
                        .help(Text("轨迹线沿各段内的时间顺序连接；不同轨迹段不相连，超过 30 分钟或 10 km 的间隔断开；地球视角只显示点云"))
                    Toggle("白描边", isOn: store.binding(\.showHalo))
                    Toggle("热力图", isOn: store.binding(\.heatMap))
                        .help("平面地图按点密度渲染热力图（GPU 实时聚合，多年轨迹一眼看出常去区域；删除模式下自动回点显示）")
                }
                Toggle("迷雾", isOn: fwdbMode ? .constant(true) : store.binding(\.fogMap))
                    .disabled(fwdbMode)
                    .help(fwdbMode
                          ? "迷雾存档模式：迷雾即数据本身，始终开启"
                          : "世界迷雾模式：未探索区域盖雾，走过的地方沿轨迹擦亮（半径可调，随纬度校正；缩小后轨迹保持可见宽度）")
    }

    private var controlPanelContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    store.clearTrack()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .help("清除当前已导入的文件 / 迷雾存档")
                .disabled(store.track == nil && !store.fwdbActive)

                Button {
                    store.openPanel()
                } label: {
                    // 顶行按钮多（补点模式还有额外按钮）时，整段文字放不下就只留图标；
                    // 悬停提示与辅助功能标签仍是全名，三种语言都不会截成「GPX…」
                    ViewThatFits(in: .horizontal) {
                        Label("打开 GPX", systemImage: "folder")
                        Image(systemName: "folder")
                    }
                }
                .help("打开 GPX")
                .accessibilityLabel(Text("打开 GPX"))
                .keyboardShortcut("o", modifiers: .command)

                Button {
                    store.showSettingsSheet = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("设置：外观 / 闲置展示 / 地图 / 压力测试")
                .keyboardShortcut(",", modifiers: .command)

                if store.displayMode == .single, store.track != nil {
                    Button {
                        store.requestLocate()
                    } label: {
                        Image(systemName: "location")
                    }
                    .help("定位到轨迹起点（地球视角同样可用）")
                }

                if store.playbackAvailable, store.playback == nil,
                   !store.deleteMode, !store.fillMode, store.displayMode != .compare {
                    Button {
                        store.loadCityCandidates()
                        store.showPlaybackSetup = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .help("时光机：先选城市/整体模式、时长和分辨率")
                    .sheet(isPresented: Binding(get: { store.showPlaybackSetup },
                                                set: { store.showPlaybackSetup = $0 })) {
                        PlaybackSetupSheet(store: store)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { panelCollapsed = true }
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help("折叠面板")
            }

            // 文件信息独占整行（不再挤在按钮行右侧）：名称 / 专属点数行 / 时间范围
            if fwdbMode {
                VStack(alignment: .leading, spacing: 2) {
                    (store.fogArchiveFiles.count == 1
                         ? Text(verbatim: store.fogArchiveFiles[0].name)
                         : Text("\(store.fogArchiveFiles.count) 个迷雾存档"))
                        .font(.caption.bold())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Image(systemName: "square.grid.3x3.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.primary.opacity(0.6))
                        Text("\((store.fogArchive?.stats.cells ?? 0).formatted()) 格")
                            .font(.caption.monospacedDigit().weight(.semibold))
                    }
                }
            } else if let track = store.track {
                VStack(alignment: .leading, spacing: 2) {
                    // 悬停立即原地展开为多行完整文件名（onHover 事件级响应，无系统延迟）
                    Text(track.name)
                        .font(.caption.bold())
                        .lineLimit(hoveringName ? nil : 1)
                        .truncationMode(.middle)
                        .onHover { hoveringName = $0 }
                        .animation(.easeOut(duration: 0.1), value: hoveringName)
                    HStack(spacing: 5) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.primary.opacity(0.6))
                        Text("\(track.count.formatted()) 个点")
                            .font(.caption.monospacedDigit().weight(.semibold))
                        if let tr = track.timeRange {
                            Text(verbatim: "·")
                                .foregroundStyle(Color.primary.opacity(0.5))
                            Text("\(Self.dayText(tr.min)) ~ \(Self.dayText(tr.max))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Color.primary.opacity(0.75))
                        }
                    }
                }
            }

            Divider()

            if !store.files.isEmpty {
                Picker("显示模式", selection: Binding(
                    get: { store.displayMode },
                    set: { store.switchDisplayMode(to: $0) })) {
                    ForEach(store.availableModes) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(store.fillMode || store.deleteMode)
                .help("单文件：新文件替换当前｜重叠：分批拖入合并显示｜对比：两文件左右分屏")
            }

            if fwdbMode {
                // 存档模式：无点云，着色不适用
            } else if store.displayMode == .overlay {
                Text("重叠模式：每个文件单独着色（见右侧文件列表）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    Picker("着色", selection: store.binding(\.colorMode)) {
                        ForEach(ColorMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(ColorMode.allCases) { mode in
                            Button { store.updateSetting(\.colorMode, to: mode) } label: {
                                Text(mode.title).frame(maxWidth: .infinity)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .buttonStyle(.bordered)
                            .tint(store.settings.colorMode == mode ? Color.accentColor : Color.secondary)
                            .accessibilityAddTraits(store.settings.colorMode == mode ? .isSelected : [])
                        }
                    }
                    .controlSize(.small)
                }

                if store.settings.colorMode == .single {
                    HStack(spacing: 8) {
                        Text("点颜色").font(.caption)
                        ColorPicker("点颜色", selection: store.binding(\.singleColor), supportsOpacity: false)
                            .labelsHidden()
                        Spacer()
                    }
                }
            }

            BaseMapStylePicker(selection: store.binding(\.mapStyle))   // Apple 三段 + 外部三段两行：6 段一行会撑爆面板
            Text("持续缩小地图会无缝进入地球视角，放大自动返回")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)   // 允许换行，不撑宽面板
            Toggle("叠加 OSM 隧道", isOn: $store.tunnelOverlay)
                .font(.caption).toggleStyle(.checkbox)
                .help("任何底图上都叠一层 OpenStreetMap 的隧道线（公路/铁路两色虚线）；视野 ≤ 40 km 时按视野向 Overpass 取，Apple 底图不画隧道、补在隧道里的点看着在路外就靠它")
            if let t = store.tunnelStatus {
                Text(verbatim: t).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }

            if !fwdbMode {
                HStack(spacing: 8) {
                    Text("点大小").font(.caption).frame(minWidth: 56, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                    Slider(value: store.binding(\.pointSize), in: 1...12)
                    Text(verbatim: store.settings.pointSize.formatted(Fmt.f1))
                        .font(.caption.monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                }
                HStack(spacing: 8) {
                    Text("点透明").font(.caption).frame(minWidth: 56, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                    Slider(value: store.binding(\.opacity), in: 0.15...1)
                    Text(verbatim: store.settings.opacity.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                }
            }
            HStack(spacing: 8) {
                Text("底图").font(.caption).frame(minWidth: 56, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                Slider(value: store.binding(\.mapOpacity), in: 0.2...1)
                Text(verbatim: store.settings.mapOpacity.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .frame(width: 34, alignment: .trailing)
            }

            if let track = store.track, track.isTimeSorted, let tr = track.timeRange,
               !Calendar.current.isDate(Date(timeIntervalSince1970: tr.min),
                                        inSameDayAs: Date(timeIntervalSince1970: tr.max)) {
                Divider()
                HStack {
                    Text("时间筛选").font(.caption.bold())
                    Spacer()
                    if store.viewFilter != nil {
                        Text("\(store.visibleIndexRange().len.formatted()) 点")
                            .font(.caption2.monospacedDigit().bold())
                            .foregroundStyle(Color.red)
                    }
                }
                TimeFilterSection(store: store)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { displayToggles }.fixedSize(horizontal: true, vertical: false)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) { displayToggles }
            }
            .font(.caption)
            .toggleStyle(.checkbox)

            if store.settings.heatMap, !fwdbMode {
                HStack(spacing: 10) {
                    Toggle("3D 热力柱", isOn: store.binding(\.heat3D))
                        .font(.caption)
                        .toggleStyle(.checkbox)
                        .disabled(store.playback != nil || store.fillMode || store.deleteMode)
                        .help("按世界迷雾格网聚合成方块的 3D 透视场景：块内点数越多柱越高越红。拖拽旋转 · 滚轮缩放 · 右键拖拽平移")
                    if store.settings.heat3D {
                        Picker("样式", selection: store.binding(\.heat3DSmooth)) {
                            Text("平滑").tag(true)
                            Text("棱角").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 110)
                        .help("平滑 = 与相邻块衔接成连续地形；棱角 = 独立平顶方柱")
                    }
                }
                if store.settings.heat3D {
                    HStack(spacing: 8) {
                        Text("块大小").font(.caption).frame(width: 44, alignment: .leading)
                        Picker("块大小", selection: store.binding(\.heat3DBlock)) {
                            ForEach([1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 24, 32, 48, 64,
                                     100, 150, 200, 300],
                                    id: \.self) { k in
                                Text("\((k * k).formatted()) 格").tag(k)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                    }
                    .help("聚合块面积（世界迷雾格 ≈9.55m 的倍数）：1 格最细（≈9.55m），90000 格最粗（≈2.9km）")
                    Text("拖拽旋转 · 滚轮缩放 · 右键拖拽平移 · 罗盘回北")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if store.settings.fogMap || fwdbMode {
                if fwdbMode {
                    Toggle("平滑迷雾边缘", isOn: store.binding(\.fogSmooth))
                        .font(.caption)
                        .toggleStyle(.checkbox)
                        .help("勾选 = 格子边缘扩散圆滑（手机版世界迷雾观感）；取消 = 精确显示 .fwdb 存档的原始小格（约 9.55 米，一格不差）")
                }
                if !fwdbMode {
                HStack(spacing: 8) {
                    Text("雾径").font(.caption).frame(width: 44, alignment: .leading)
                    Slider(value: store.binding(\.fogRadiusMeters), in: 5...150, step: 1)
                    Text(verbatim: "\(Int(store.settings.fogRadiusMeters.rounded())) m")
                        .font(.caption.monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                    Button {
                        store.updateSetting(\.fogRadiusMeters, to: FogArchive.cellMeters)
                    } label: {
                        Image(systemName: "squareshape.split.3x3")
                    }
                    .buttonStyle(.plain)
                    .help("设为世界迷雾原始格宽（约 \(FogArchive.cellMeters, specifier: "%.2f") 米——.fwdb 里一个小格的边长，即最细雾径）")
                }
                .help("迷雾清除半径（米）：走过的地方向两侧擦亮多宽")
                }
                Toggle("迷雾统计（世界迷雾口径）", isOn: $store.showFogStats)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                    .help("等级 / 探索面积 / 地球占比，算法与《世界迷雾》一致（2²²×2²² 格网 + 逐格纬度面积 + 等级=√(面积×250)）")
            }
            HStack(spacing: 8) {
                if !store.settings.heatMap {
                    Button("地区统计…") { openWindow(id: SceneID.regions) }
                        .disabled((store.track == nil && !fwdbMode) || !RegionIndex.hasData)
                        .help(RegionIndex.hasData
                              ? "按国家 / 省州（中国到地级市）统计：查看点模式按点数与到访天数，迷雾模式按解锁面积（世界迷雾口径）与按同一公式折算的等级；点一行在地图上高亮边界"
                              : "这个版本没有内置行政区边界数据，地区统计暂不可用")
                }
                if store.regionSelection != nil {                          // 热力图模式下也能清掉留在地图上的边界
                    Button("清除地区高亮") { store.selectRegion(nil, fly: false) }
                }
            }
            .font(.caption)
            HStack(spacing: 12) {
                Toggle("性能面板", isOn: store.binding(\.showStats))
                if !fwdbMode {
                    Toggle("自动降采样", isOn: store.binding(\.lodEnabled))
                }
            }
            .font(.caption)
            .toggleStyle(.checkbox)

            if store.settings.showTrackLine, !fwdbMode {
                HStack(spacing: 10) {
                    Text("线颜色").font(.caption)
                    ColorPicker("线颜色", selection: store.binding(\.lineColor), supportsOpacity: false)
                        .labelsHidden()
                    Toggle("方向箭头", isOn: store.binding(\.showArrows))
                        .font(.caption)
                        .toggleStyle(.checkbox)
                    Spacer()
                }
                if store.settings.showArrows {
                    HStack(spacing: 8) {
                        Text("箭头密度").font(.caption).frame(width: 44, alignment: .leading)
                        Picker("箭头密度", selection: store.binding(\.arrowEvery)) {
                            Text("每段都加").tag(1)
                            Text("隔一段").tag(2)
                            Text("隔两段").tag(3)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .font(.caption)
                        .frame(width: 110)
                        .help("每两点之间都画箭头，或每隔一段/两段画一个（箭杆照常连）")
                        Spacer()
                    }
                }
                HStack(spacing: 8) {
                    Text("线宽").font(.caption).frame(width: 44, alignment: .leading)
                    Slider(value: store.binding(\.lineWidth), in: 1...8)
                    Text(verbatim: store.settings.lineWidth.formatted(Fmt.f1))
                        .font(.caption.monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                }
                HStack(spacing: 8) {
                    Text("线透明").font(.caption).frame(width: 44, alignment: .leading)
                    Slider(value: store.binding(\.lineOpacity), in: 0.1...1)
                    Text(verbatim: store.settings.lineOpacity.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .frame(width: 262, alignment: .leading)   // 290 panel minus two 14pt insets; intrinsic pickers cannot widen the whole panel
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    /// 左面板底部两行（导出/图片/删除点/补点、修改记录）：固定在面板底部，不随中间部分滚动
    private var controlPanelFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            // 底行四个按钮：放得下时图标 + 文字，其次只要文字，再放不下（德文）时整行只留图标，
            // 悬停提示带全名，三种语言都不出现「Exp…」「删…」这类截断（同顶行「打开 GPX」的做法）
            ViewThatFits(in: .horizontal) {
                bottomActionRow(iconOnly: false).labelStyle(.titleAndIcon)
                bottomActionRow(iconOnly: false).labelStyle(.titleOnly)     // 中间一档：只要文字（简中/英文放得下）
                bottomActionRow(iconOnly: true).labelStyle(.iconOnly)
            }
            .font(.caption)

            HStack(spacing: 8) {
                Button {
                    store.openChangeLog(); openWindow(id: SceneID.changeReview)
                } label: {
                    Label(store.changes.isEmpty ? "修改记录" : "修改记录 \(store.changes.count)", systemImage: "clock.arrow.circlepath")
                }
                .disabled(store.track == nil || store.displayMode != .single)
                .help("本次会话对这条轨迹的全部修改（补点、删点）：总览看改了哪里，详细逐处校验，每一处可一键还原")
                Spacer()
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    // MARK: - 设置面板（外观 / 闲置展示 / 压力测试）

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置")
                .font(.headline)

            HStack(spacing: 8) {
                Text("外观").font(.callout).frame(width: 60, alignment: .leading)
                Picker("外观", selection: store.binding(\.appearance)) {
                    ForEach(AppearanceMode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            LanguageSettingRow(store: store)

            Divider()

            Text("闲置展示").font(.callout.bold())
            Toggle("禁用闲置展示模式", isOn: store.binding(\.idleDisabled))
                .toggleStyle(.checkbox)
                .font(.callout)
                .help("勾选后不再自动进入星球展示动画")
            if !store.settings.idleDisabled {
                HStack(spacing: 8) {
                    Text("地球视角").font(.callout).frame(width: 60, alignment: .leading)
                    Slider(value: store.binding(\.idleGlobeSeconds), in: 1...60, step: 1)
                    Text("\(Int(store.settings.idleGlobeSeconds)) 秒")
                        .font(.callout.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                }
                .help("地球视角下无操作多少秒后进入星球展示动画")
                HStack(spacing: 8) {
                    Text("平面地图").font(.callout).frame(width: 60, alignment: .leading)
                    Slider(value: store.binding(\.idleMapSeconds), in: 1...60, step: 1)
                    Text("\(Int(store.settings.idleMapSeconds)) 秒")
                        .font(.callout.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                }
                .help("平面地图下无操作多少秒后进入星球展示动画")
            }

            Divider()

            MapSettingsSection()

            Divider()

            Text("压力测试").font(.callout.bold())
            HStack(spacing: 8) {
                Button("生成 100 万点") { store.runStress(count: 1_000_000); store.showSettingsSheet = false }
                Button("生成 500 万点") { store.runStress(count: 5_000_000); store.showSettingsSheet = false }
            }
            .font(.callout)
            if store.currentFileURL != nil {
                Button("重新加载当前文件") { store.reloadCurrentFile(); store.showSettingsSheet = false }
                    .font(.callout)
            }

            Divider()

            HStack {
                Spacer()
                Button("完成") { store.showSettingsSheet = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// 设置面板「语言」行：选择立即写入 AppleLanguages（AppLanguage.apply），重启 app 后生效。
    /// 自带 @State、只持有不观察 store（重启前才读一次会话状态），切换选项不重算整个 ContentView
    private struct LanguageSettingRow: View {
        let store: TrackStore
        @State private var language = AppLanguage.stored
        @State private var confirmRelaunch = false
        @State private var pending: AppLanguage? = nil      // 等确认的选择（取消就退回）

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("语言").font(.callout).frame(width: 60, alignment: .leading)
                    Picker("语言", selection: $language) {
                        ForEach(AppLanguage.allCases, id: \.self) { l in
                            l.label.tag(l)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    Spacer(minLength: 0)
                }
                .onChange(of: language) { old, l in
                    guard pending == nil else { return }                  // 取消确认时的回退写入，不再触发
                    if l == AppLanguage.launchSnapshot { AppLanguage.apply(l); return }   // 改回启动时的语言：只写设置，不用重启
                    // 界面语言在启动时定死（String Catalog），选完直接重启换语言；修改记录 / 补点 / 批量只在内存里，有的话先确认
                    if !store.changes.isEmpty || store.fillMode || store.batch != nil {
                        pending = l; language = old; confirmRelaunch = true
                    } else {
                        AppLanguage.apply(l); AppLanguage.relaunch()
                    }
                }

                Text("切换后 app 会立刻重新打开，并记住这个选择")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 68)

                Text("也可在 系统设置 › 通用 › 语言与地区 › 应用程序 里设置")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 68)
            }
            .alert("切换语言要重新打开 app，本次会话的修改记录会丢失，仍要切换？", isPresented: $confirmRelaunch) {
                Button("切换并重启", role: .destructive) {
                    if let l = pending { AppLanguage.apply(l); pending = nil; AppLanguage.relaunch() }
                }
                Button("取消", role: .cancel) { pending = nil }
            }
        }
    }

    // MARK: - 图例

    private var legend: some View {
        Group {
            if let track = store.track, let labels = track.legendLabels() {
                HStack(spacing: 8) {
                    Text(track.effectiveMode.title)
                        .font(.caption.bold())
                    Text(labels.lo)
                        .font(.caption.monospacedDigit())
                    LinearGradient(
                        gradient: Gradient(stops: track.effectiveMode.colormap.gradientStops),
                        startPoint: .leading, endPoint: .trailing)
                        .frame(width: 150, height: 9)
                        .clipShape(Capsule())
                    Text(labels.hi)
                        .font(.caption.monospacedDigit())
                    Text(labels.unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("· 2–98 百分位")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
        }
    }

    // MARK: - 性能面板

    /// 性能面板单独观察 renderStats（每 0.25 s 一次帧率刷新只重算这块）
    private var statsPanel: some View { StatsPanelView(store: store, render: store.renderStats) }

    /// 控制面板底行：导出 / 图片 / 删除点 / 补点。iconOnly 时悬停提示 = 全名 + 原说明
    private func bottomActionRow(iconOnly: Bool) -> some View {
        func tip(_ name: String, _ help: String?) -> String {
            iconOnly ? ([name] + (help.map { [$0] } ?? [])).joined(separator: "\n") : (help ?? "")
        }
        let exportName = String(localized: "导出")
        let imageName = String(localized: "图片")
        let deleteName = store.deleteMode ? String(localized: "放弃删除") : String(localized: "删除点")
        let fillName = store.fillMode ? String(localized: "退出补点") : String(localized: "补点")
        return HStack(spacing: 8) {
            Button {
                if store.exportNeedsSheet {
                    store.showExportSheet = true
                } else {
                    store.exportGPX(range: nil)   // 单日/无时间数据：直接导出
                }
            } label: {
                Label(exportName, systemImage: "square.and.arrow.up")
            }
            .disabled(store.track == nil)
            .help(tip(exportName, nil))
            .accessibilityLabel(Text(exportName))

            Button {
                store.showImageExportSheet = true
            } label: {
                Label(imageName, systemImage: "photo")
            }
            .disabled((store.track == nil && !store.fwdbActive)
                      || store.displayMode == .compare)
            .help(tip(imageName, String(localized: "把当前视图（平面地图或地球）导出为 4K/8K PNG")))
            .accessibilityLabel(Text(imageName))

            Button {
                store.toggleDeleteMode()
            } label: {
                Label(deleteName, systemImage: "lasso")
            }
            .disabled(store.track == nil || store.displayMode != .single
                      || store.playback != nil || store.fillMode)
            .help(tip(deleteName, store.displayMode == .single
                      ? String(localized: "手绘圈选暂存待删点；地球视角下同样可用（右键拖拽旋转地球）")
                      : String(localized: "重叠/对比模式下不可删除点（请切回单文件模式）")))
            .accessibilityLabel(Text(deleteName))
            .tint(store.deleteMode ? Color.red : Color.accentColor)

            Button {
                store.toggleFillMode()
            } label: {
                Label(fillName, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .disabled(store.track == nil || store.displayMode != .single
                      || store.playback != nil || store.deleteMode || store.globeShowing)
            .help(tip(fillName, String(localized: "断档补点：列出隧道类断档，选一处后在地图上点出轮廓折线，按时间匀速插点；可导出给世界迷雾/一生足迹")))
            .accessibilityLabel(Text(fillName))
            .tint(store.fillMode ? Color.orange : Color.accentColor)
        }
        .fixedSize()       // 按理想宽度量：放不下就让 ViewThatFits 换成纯图标那一行，而不是把文字截成省略号
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")      // 纯数字格式：不随界面语言/历法变
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private static func dayText(_ t: Double) -> String {
        dayFormatter.string(from: Date(timeIntervalSince1970: t))
    }

    // MARK: - 选中详情卡

    private var selectedCard: some View {
        Group {
            if let info = store.selected {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("点 #\(info.index.formatted())")
                            .font(.caption.bold())
                        Spacer()
                        Button {
                            store.selected = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    if let t = info.timeText {
                        infoRow("时间", t)
                    }
                    if let v = info.speedKmh {
                        infoRow("速度", "\(v.formatted(Fmt.f1)) km/h")
                    }
                    if let e = info.ele {
                        infoRow("海拔", "\(e.formatted(Fmt.f1)) m")
                    }
                    infoRow("纬度", String(format: "%.6f°", info.lat))
                    infoRow("经度", String(format: "%.6f°", info.lon))
                    Text("点击地图空白处取消固定")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption.monospacedDigit())
                .padding(12)
                .frame(width: 230, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
        }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    // MARK: - 空状态 / 加载中

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("拖入 GPX 文件或 .fwdb 迷雾存档，或按 ⌘O 打开")
                .font(.title3.bold())
        }
        .padding(30)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var loadingCard: some View {
        VStack(spacing: 10) {
            if let p = store.loadingProgress {
                ProgressView(value: p)          // 确定进度（已解析点数 / 总点数）
                    .frame(width: 180)
            } else {
                ProgressView()
            }
            Text(store.loadingLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 拖放

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let list = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !list.isEmpty else { return false }

        // 并发解析全部拖入项，齐了再一次性（多文件即合并）载入
        let group = DispatchGroup()
        let box = DropURLBox()
        for provider in list {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let url { box.append(url) }
            }
        }
        group.notify(queue: .main) {
            var urls = box.urls
            // .fwdb 迷雾存档：直接作为迷雾数据源，自动切到迷雾模式（可多选）
            let fws = urls.filter { FogArchive.looksLikeArchive($0) }
                          .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if !fws.isEmpty {
                store.loadFwdb(urls: fws)
                return
            }
            let gpxish = urls.filter { ["gpx", "xml", "csv"].contains($0.pathExtension.lowercased()) }
            if !gpxish.isEmpty { urls = gpxish }
            urls.sort { $0.lastPathComponent < $1.lastPathComponent }   // 合并顺序稳定
            if !urls.isEmpty { store.load(urls: urls) }
        }
        return true
    }
}

/// 拖放 URL 收集盒（回调可能来自不同队列，锁保护）
private final class DropURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func append(_ u: URL) { lock.lock(); storage.append(u); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
}

extension TrackStore.FillOverlay {
    struct EngineLabel: Equatable { var at: CGPoint; var text: String }
    static var engineLabelFont: NSFont { .systemFont(ofSize: 10, weight: .semibold) }
    static func engineLabelSize(_ text: String) -> CGSize {
        let size = (text as NSString).size(withAttributes: [.font: engineLabelFont])
        return CGSize(width: ceil(size.width + 8), height: ceil(size.height + 2))
    }
    /// 精确模式等你选的两路（status 4 = OSRM 实线、5 = Valhalla 虚线）：在每条线的屏幕弧长中点贴引擎名，
    /// 先沿法向错开 11 pt；若真实字体矩形仍相交，再沿原侧法向移到有 4 pt 间隔的位置。
    /// 线在屏幕上短于 `minScreenLength`（缩得太小、看不清是哪条）就不标。钩子 `lineLabels` 用同一个函数计数。
    static func engineLabels(_ lines: [BatchLine], minScreenLength: CGFloat = 90) -> [EngineLabel] {
        var out: [EngineLabel] = []
        var occupied: [CGRect] = []
        for l in lines where (l.status == 4 || l.status == 5) && l.pts.count >= 2 {
            var segs: [CGFloat] = []; segs.reserveCapacity(l.pts.count - 1)
            var total: CGFloat = 0
            for k in 1..<l.pts.count {
                let a = l.pts[k - 1], b = l.pts[k]
                let d = (a.x.isFinite && b.x.isFinite) ? hypot(b.x - a.x, b.y - a.y) : 0
                segs.append(d); total += d
            }
            guard total >= minScreenLength else { continue }
            var acc: CGFloat = 0, at = l.pts[0], nx: CGFloat = 0, ny: CGFloat = -1
            for k in 0..<segs.count where segs[k] > 0 {
                if acc + segs[k] >= total / 2 {
                    let a = l.pts[k], b = l.pts[k + 1], t = (total / 2 - acc) / segs[k]
                    at = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                    nx = -(b.y - a.y) / segs[k]; ny = (b.x - a.x) / segs[k]
                    break
                }
                acc += segs[k]
            }
            let side: CGFloat = l.status == 4 ? -11 : 11
            let text = l.status == 4 ? "OSRM" : "Valhalla"
            let size = engineLabelSize(text)
            let direction: CGFloat = side < 0 ? -1 : 1
            let vx = nx * direction, vy = ny * direction
            var center = CGPoint(x: at.x + nx * side, y: at.y + ny * side)
            var rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                              width: size.width, height: size.height)
            while let conflict = occupied.first(where: { $0.intersects(rect) }) {
                let clearance = conflict.insetBy(dx: -4, dy: -4)
                var distance = CGFloat.infinity
                if vx > 0 { distance = min(distance, (clearance.maxX - rect.minX) / vx) }
                if vx < 0 { distance = min(distance, (rect.maxX - clearance.minX) / -vx) }
                if vy > 0 { distance = min(distance, (clearance.maxY - rect.minY) / vy) }
                if vy < 0 { distance = min(distance, (rect.maxY - clearance.minY) / -vy) }
                // 正向越过一个矩形后不会再次进入；半点余量避免浮点边界接触。
                let shift = max(0, distance) + 0.5
                center.x += vx * shift; center.y += vy * shift
                rect.origin.x = center.x - size.width / 2; rect.origin.y = center.y - size.height / 2
            }
            occupied.append(rect)
            out.append(EngineLabel(at: center, text: text))
        }
        return out
    }
}

/// 补点覆盖层（只观察 FillOverlayState）。
/// 青色细线 = 真实轨迹的来向（…→A）与去向（B→…）；红虚线 = 断档直连；橙色折线 = 补点走向；
/// 所有线都带行进方向的箭头，锚点标注「A 入口 时刻」「B 出口 时刻」
private struct FillOverlayView: View {
    @ObservedObject var state: FillOverlayState

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")      // 纯数字格式：不随界面语言/历法变
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private static let innerPink = Color(red: 1.0, green: 60.0 / 255, blue: 170.0 / 255)

    struct BatchGroup { let key: Int; let status: Int; let selected: Bool; let included: Bool; var lines: [[CGPoint]] }
    static func batchGroups(_ lines: [TrackStore.FillOverlay.BatchLine]) -> [BatchGroup] {
        var groups: [Int: BatchGroup] = [:]
        for l in lines {
            let key = (l.selected ? 100 : 0) + l.status * 4 + (l.included ? 1 : 0)      // 选中位最高：选中的线总在最后画、压在上面
            if groups[key] == nil { groups[key] = BatchGroup(key: key, status: l.status, selected: l.selected, included: l.included, lines: []) }
            groups[key]!.lines.append(l.pts)
        }
        return groups.values.sorted { $0.key < $1.key }      // 选中的（key 大）最后画，压在上面
    }

    var body: some View {
        let o = state.overlay
        ZStack {
            // 来向/去向不再另画青线（用户反馈画面太杂，而且会画出轨迹之外）：轨迹点本身带行进箭头
            // 断档直连：红虚线，只在 B 端一个箭头
            if let a = o.anchorA, let b = o.anchorB {
                PolylineShape(points: [a, b], dashPeriod: 10)
                    .stroke(Color.red.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                EndArrowShape(points: [a, b], size: 8, inset: 9)
                    .fill(Color.red.opacity(0.7))
            }
            // 补点范围：虚线多边形（反选时淡红，表示圈内不补）
            if o.region.count >= 3 {
                LassoShape(points: o.region)
                    .fill((o.regionInverted ? Color.red : Color.green).opacity(0.08))
                    .allowsHitTesting(false)
                LassoShape(points: o.region)
                    .stroke((o.regionInverted ? Color.red : Color.green).opacity(0.9),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [8, 5]))
                    .allowsHitTesting(false)
            }
            // 批量预览：每处草稿一条线（绿 = 成功，橙 = 有警告，红虚线 = 失败/直线）。
            // 按（状态, 选中, 勾选）分组，每组合成一个形状：上千处在平移时每帧不再重建上千个视图
            ForEach(Self.batchGroups(o.batchLines), id: \.key) { g in
                // 4/5 = 精确模式等你选的两路：同一"待你选"蓝，OSRM 实线、Valhalla 长虚线；不按「未勾选」淡化（最需要看的线不能最淡）
                let color: Color = g.status == 0 ? .green : (g.status == 1 ? .orange : (g.status == 3 ? .gray : (g.status >= 4 ? .blue : .red)))
                let alpha: Double = g.selected ? 1 : (g.included || g.status >= 4 ? 0.8 : 0.3)
                let dash: [CGFloat] = g.status == 2 ? [5, 5] : (g.status == 5 ? [10, 4] : [])
                PolylinesShape(lines: g.lines, dashPeriod: g.status == 2 ? 10 : (g.status == 5 ? 14 : 0))
                    .stroke(color.opacity(alpha),
                            style: StrokeStyle(lineWidth: g.selected ? 4 : (g.included || g.status >= 4 ? 2.5 : 1.5), lineCap: .round, lineJoin: .round,
                                               dash: dash))
                if g.included {
                    MultiEndArrowsShape(lines: g.lines, size: 8, inset: 2).fill(color.opacity(alpha))
                }
            }
            // 等你选的两路：线中点贴引擎名（缩小到线很短时不标）
            ForEach(Array(TrackStore.FillOverlay.engineLabels(o.batchLines).enumerated()), id: \.offset) { _, lab in
                let size = TrackStore.FillOverlay.engineLabelSize(lab.text)
                Text(verbatim: lab.text)
                    .font(Font(TrackStore.FillOverlay.engineLabelFont))
                    .foregroundStyle(.white)
                    .frame(width: size.width, height: size.height)
                    .background(Color.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
                    .position(lab.at)
            }
            // 补点折线：每段一个箭头，放在段尾（顶点/B 之前紧挨着）
            if o.preview.count >= 2 {
                PolylineShape(points: o.preview)
                    .stroke(Color.orange.opacity(0.95), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                SegmentEndArrowsShape(points: o.preview, size: 10, inset: 6, onlyLast: false)
                    .fill(Color.orange)
                SegmentEndArrowsShape(points: o.preview, size: 10, inset: 6, onlyLast: false)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
            }
            // 「显示补的点」：要插进去的合成点（橙点，白描边）
            if !o.previewPoints.isEmpty {
                CircleMarksShape(points: o.previewPoints, radius: 3).fill(Color.orange)
                CircleMarksShape(points: o.previewPoints, radius: 3).stroke(Color.white.opacity(0.9), lineWidth: 1)
            }
            // 将被替换的原始点：粉色 ×
            if !o.inner.isEmpty {
                CrossMarksShape(points: o.inner, half: 4)
                    .stroke(Self.innerPink, lineWidth: 1.5)
            }
            // 句柄很多（路网草稿几百个顶点）时合成一个形状画，而不是几百个视图每帧重建
            if o.vertices.count > 120 {
                CircleMarksShape(points: o.midpoints.filter { $0.x.isFinite }, radius: 4.5)
                    .fill(Color.orange.opacity(0.35))
                CircleMarksShape(points: o.vertices, radius: 5.5).fill(Color.orange)
                CircleMarksShape(points: o.vertices, radius: 5.5).stroke(Color.white, lineWidth: 1.5)
                if let d = o.dragging, d < o.vertices.count {
                    Circle().fill(Color.orange).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2.2)).position(o.vertices[d])
                }
            } else {
            // 线段中点句柄：空心小圆，拖它 = 在这段上加顶点
            ForEach(Array(o.midpoints.enumerated()), id: \.offset) { _, m in
                if m.x.isFinite {
                    Circle().fill(Color.orange.opacity(0.35)).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.2))
                        .position(m)
                }
            }
            // 顶点：实心橙圆白边，拖动调整
            ForEach(Array(o.vertices.enumerated()), id: \.offset) { i, v in
                let hot = o.dragging == i
                Circle().fill(Color.orange).frame(width: hot ? 14 : 11, height: hot ? 14 : 11)
                    .overlay(Circle().stroke(Color.white, lineWidth: hot ? 2.2 : 1.8))
                    .position(v)
            }
            }
            if let a = o.anchorA {
                Circle().stroke(Color.red, lineWidth: 2.5).frame(width: 16, height: 16).position(a)
                anchorLabel(isA: true, o.tA).position(x: a.x, y: a.y - 20)
            }
            if let b = o.anchorB {
                Circle().stroke(Color.red, lineWidth: 2.5).frame(width: 16, height: 16).position(b)
                anchorLabel(isA: false, o.tB).position(x: b.x, y: b.y + 20)
            }
        }
    }

    /// 锚点标签「A 入口 时刻」/「B 出口 时刻」：每种组合一整句做键（时刻缺失时只显示前半）
    private func anchorLabel(isA: Bool, _ t: Double?) -> some View {
        let label: Text
        if let t {
            let time = Self.timeFormatter.string(from: Date(timeIntervalSince1970: t))
            label = isA ? Text("A 入口 \(time)", comment: "Fill overlay: label above anchor A (gap entry); %@ = time of day HH:mm:ss")
                        : Text("B 出口 \(time)", comment: "Fill overlay: label below anchor B (gap exit); %@ = time of day HH:mm:ss")
        } else {
            label = isA ? Text("A 入口", comment: "Fill overlay: label above anchor A (gap entry), no timestamp")
                        : Text("B 出口", comment: "Fill overlay: label below anchor B (gap exit), no timestamp")
        }
        return label
            .font(.caption2.bold().monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.red.opacity(0.85), in: Capsule())
            .fixedSize()
    }
}

/// 每段一个行进方向箭头，放在段尾：三角形尖端离段尾 inset 像素（给顶点圆/锚点环让位）。
/// onlyLast = 整条折线只在最后一段画（来向/去向/断档直连）
private struct SegmentEndArrowsShape: Shape {
    let points: [CGPoint]
    let size: CGFloat
    let inset: CGFloat
    let onlyLast: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard points.count >= 2 else { return p }
        let visible = rect.insetBy(dx: -size * 2, dy: -size * 2)
        let first = onlyLast ? points.count - 1 : 1
        for k in first..<points.count {
            let a = points[k - 1], b = points[k]
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len.isFinite, len >= inset + size + 4, visible.contains(b) else { continue }
            let dx = (b.x - a.x) / len, dy = (b.y - a.y) / len
            let nx = -dy, ny = dx
            let tip = CGPoint(x: b.x - dx * inset, y: b.y - dy * inset)
            let base = CGPoint(x: tip.x - dx * size, y: tip.y - dy * size)
            let l = CGPoint(x: base.x + nx * size * 0.5, y: base.y + ny * size * 0.5)
            let r = CGPoint(x: base.x - nx * size * 0.5, y: base.y - ny * size * 0.5)
            p.move(to: tip); p.addLine(to: l); p.addLine(to: r); p.closeSubpath()
        }
        return p
    }
}

/// 折线末端一个行进方向箭头：方向按从末端回溯 ≥ size+inset 像素的弧长取（最后一步再短也能画）
private struct EndArrowShape: Shape {
    let points: [CGPoint]
    let size: CGFloat
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard points.count >= 2, let end = points.last, end.x.isFinite, end.y.isFinite else { return p }
        guard rect.insetBy(dx: -size * 3, dy: -size * 3).contains(end) else { return p }
        let need = inset + size + 2
        var walked: CGFloat = 0
        var from: CGPoint?
        var k = points.count - 1
        while k >= 1 {
            let a = points[k - 1], b = points[k]
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len.isFinite else { return p }
            if walked + len >= need {
                let f = (need - walked) / len            // 从 b 往 a 回退 need-walked
                from = CGPoint(x: b.x + (a.x - b.x) * f, y: b.y + (a.y - b.y) * f)
                break
            }
            walked += len
            k -= 1
        }
        guard let from else { return p }                 // 整条线比箭头还短：不画
        let dxl = end.x - from.x, dyl = end.y - from.y
        let l = hypot(dxl, dyl)
        guard l > 0 else { return p }
        let dx = dxl / l, dy = dyl / l, nx = -dy, ny = dx
        let tip = CGPoint(x: end.x - dx * inset, y: end.y - dy * inset)
        let base = CGPoint(x: tip.x - dx * size, y: tip.y - dy * size)
        p.move(to: tip)
        p.addLine(to: CGPoint(x: base.x + nx * size * 0.5, y: base.y + ny * size * 0.5))
        p.addLine(to: CGPoint(x: base.x - nx * size * 0.5, y: base.y - ny * size * 0.5))
        p.closeSubpath()
        return p
    }
}

/// 沿折线弧长 distance 像素处一个行进方向箭头（去向线：紧挨出口之后）
private struct ArrowAtDistanceShape: Shape {
    let points: [CGPoint]
    let distance: CGFloat
    let size: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard points.count >= 2 else { return p }
        var walked: CGFloat = 0
        for k in 1..<points.count {
            let a = points[k - 1], b = points[k]
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len.isFinite, len > 0 else { continue }
            if walked + len >= distance || k == points.count - 1 {
                let f = min(1, max(0, (distance - walked) / len))
                let c = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                guard rect.insetBy(dx: -size * 2, dy: -size * 2).contains(c) else { return p }
                let dx = (b.x - a.x) / len, dy = (b.y - a.y) / len
                let nx = -dy, ny = dx
                let tip = CGPoint(x: c.x + dx * size * 0.5, y: c.y + dy * size * 0.5)
                let base = CGPoint(x: c.x - dx * size * 0.5, y: c.y - dy * size * 0.5)
                p.move(to: tip)
                p.addLine(to: CGPoint(x: base.x + nx * size * 0.5, y: base.y + ny * size * 0.5))
                p.addLine(to: CGPoint(x: base.x - nx * size * 0.5, y: base.y - ny * size * 0.5))
                p.closeSubpath()
                return p
            }
            walked += len
        }
        return p
    }
}

/// × 标记（将被替换的原始点）
private struct CrossMarksShape: Shape {
    let points: [CGPoint]
    let half: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let visible = rect.insetBy(dx: -half * 2, dy: -half * 2)
        for c in points where c.x.isFinite && c.y.isFinite && visible.contains(c) {
            p.move(to: CGPoint(x: c.x - half, y: c.y - half)); p.addLine(to: CGPoint(x: c.x + half, y: c.y + half))
            p.move(to: CGPoint(x: c.x - half, y: c.y + half)); p.addLine(to: CGPoint(x: c.x + half, y: c.y - half))
        }
        return p
    }
}

/// 开放折线（补点预览 / 断档直连 / 来向去向）。每段裁到可见区域再画：
/// 百公里断档放大到洞口时直连线有上百万像素长，虚线会生成几十万段
private struct PolylineShape: Shape {
    let points: [CGPoint]
    var dashPeriod: CGFloat = 0             // 虚线周期（像素）：裁剪起点对齐到周期，平移时虚线不"爬"

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard points.count >= 2 else { return p }
        let r = rect.insetBy(dx: -64, dy: -64)
        var pen: CGPoint?                       // 上一段裁剪后的终点（连续时不重新 move）
        for k in 1..<points.count {
            guard let (a, b) = Self.clip(points[k - 1], points[k], to: r, dashPeriod: dashPeriod) else { pen = nil; continue }
            if let pen, abs(pen.x - a.x) < 0.01, abs(pen.y - a.y) < 0.01 {
                p.addLine(to: b)
            } else {
                p.move(to: a); p.addLine(to: b)
            }
            pen = b
        }
        return p
    }

    /// Liang–Barsky 线段裁剪；段完全在外时返回 nil
    private static func clip(_ a: CGPoint, _ b: CGPoint, to r: CGRect, dashPeriod: CGFloat) -> (CGPoint, CGPoint)? {
        guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return nil }
        let dx = b.x - a.x, dy = b.y - a.y
        var t0: CGFloat = 0, t1: CGFloat = 1
        let checks: [(CGFloat, CGFloat)] = [(-dx, a.x - r.minX), (dx, r.maxX - a.x), (-dy, a.y - r.minY), (dy, r.maxY - a.y)]
        for (pp, q) in checks {
            if pp == 0 {
                if q < 0 { return nil }
            } else {
                let t = q / pp
                if pp < 0 { if t > t1 { return nil }; if t > t0 { t0 = t } }
                else      { if t < t0 { return nil }; if t < t1 { t1 = t } }
            }
        }
        if dashPeriod > 0, t0 > 0 {
            let len = hypot(dx, dy)
            if len > 0 { t0 = floor(t0 * len / dashPeriod) * dashPeriod / len }   // 起点退到整周期处（仍在 64px 边距外）
        }
        return (CGPoint(x: a.x + dx * t0, y: a.y + dy * t0), CGPoint(x: a.x + dx * t1, y: a.y + dy * t1))
    }
}

// MARK: - 套索路径形状（自动闭合：绘制首尾之间的连线）

private struct LassoShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first)
        p.addLines(points)
        p.closeSubpath()
        return p
    }
}

// MARK: - 悬停提示卡

/// 浮层面板的窗口坐标（悬停卡避让用）
private struct PanelFramesKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

private struct TooltipSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { let n = nextValue(); if n.width > 0 { value = n } }
}

private extension View {
    /// 把自己的位置（坐标空间 root）上报给悬停卡避让
    func reportPanelFrame() -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: PanelFramesKey.self, value: [g.frame(in: .named("root"))])
        })
    }
}

private struct TooltipCard: View {
    let info: PointInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("点 #\(info.index.formatted())")
                .font(.caption.bold())
            if let t = info.timeText {
                Text(t)
            }
            HStack(spacing: 8) {
                if let v = info.speedKmh {
                    Text(verbatim: "\(v.formatted(Fmt.f1)) km/h")
                }
                if let e = info.ele {
                    Text(verbatim: "\(e.formatted(Fmt.f1)) m")
                }
            }
            Text(String(format: "%.5f°, %.5f°", info.lat, info.lon))
                .foregroundStyle(.secondary)
        }
        .font(.caption.monospacedDigit())
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}


// MARK: - 时光机时间轴（独立观察回放时钟，60fps 步进不惊扰整棵视图树）

struct PlaybackBarView: View {
    @ObservedObject var store: TrackStore
    @ObservedObject var session: PlaybackSession
    @ObservedObject var clock: PlaybackClock

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if !clock.playing, clock.head >= session.plan.duration - 1e-6 {
                    clock.head = 0        // 播完后再按 = 重播
                }
                clock.playing.toggle()
                store.pokePlayback()
            } label: {
                Image(systemName: clock.playing ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.plain)

            Button {
                store.showCityPicker = true
            } label: {
                Image(systemName: "building.2")
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help("选择要单独展示的城市")
            .sheet(isPresented: Binding(get: { store.showCityPicker }, set: { store.showCityPicker = $0 })) {
                CityPickerSheet(store: store)
            }

            Text(Self.dayFmt.string(from: Date(
                timeIntervalSince1970: session.plan.dataTime(at: clock.head))))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(width: 150, height: 16, alignment: .leading)
                .lineLimit(1)

            Slider(value: Binding(
                get: { clock.head },
                set: { clock.head = $0; store.pokePlayback() }),
                   in: 0...max(1, session.plan.duration))
                .frame(width: 300)
                .controlSize(.small)

            Menu {
                ForEach([10.0, 20.0, 30.0, 45.0, 60.0, 120.0], id: \.self) { d in
                    Button("\(Int(d)) 秒") { store.setPlaybackDuration(d) }
                }
            } label: {
                Text(verbatim: "\(Int(session.plan.duration.rounded()))s")
                    .font(.caption.monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("回放总时长")

            Button {
                NotificationCenter.default.post(name: .resetPlaybackCamera, object: nil)
            } label: {
                Image(systemName: "scope")
            }
            .buttonStyle(.plain)
            .help("回到默认视角")

            Button {
                store.showVideoExportSheet = true
            } label: {
                Image(systemName: "film")
            }
            .buttonStyle(.plain)
            .disabled(store.isLoading)
            .help("把整段回放导出为视频（离屏渲染，含底图与时间轴）")

            Button {
                store.stopPlayback()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("结束回放")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thickMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }
}


// MARK: - 3D 热力柱罗盘（指针实时指北；点击平滑转回北向上）

struct Heat3DCompass: View {
    let store: TrackStore
    @ObservedObject var cam: Heat3DCamState

    var body: some View {
        Button {
            store.heat3DPointNorth()
        } label: {
            ZStack {
                Circle()
                    .fill(.thickMaterial)
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.18), radius: 5, y: 1)
                VStack(spacing: -2) {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.red)
                    Text(verbatim: "N")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.secondary)
                }
                .rotationEffect(.radians(-Double(cam.yaw)))
            }
        }
        .buttonStyle(.plain)
        .help("指北针：红色箭头指向北；点击平滑转回北向上")
    }
}


// MARK: - 高频小状态的独立观察视图（悬停卡 / 性能面板 / 比例尺）

/// 悬停信息卡。只观察 HoverState：鼠标每动一下只有它重算
private struct HoverTooltipLayer: View {
    @ObservedObject var hover: HoverState
    let panelFrames: [CGRect]
    @State private var tooltipSize = CGSize(width: 240, height: 92)   // 实测尺寸（摆放用）

    var body: some View {
        Group {
            if let info = hover.info, !panelFrames.contains(where: { $0.contains(info.screenPoint) }) {
                GeometryReader { geo in
                    let size = tooltipSize
                    let p = ContentView.tooltipOrigin(cursor: info.screenPoint, size: size, bounds: geo.size, avoid: panelFrames)
                    TooltipCard(info: info)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: TooltipSizeKey.self, value: g.size)
                        })
                        .position(x: p.x + size.width / 2, y: p.y + size.height / 2)
                        .allowsHitTesting(false)
                }
                .allowsHitTesting(false)
            }
        }
        .onPreferenceChange(TooltipSizeKey.self) { if $0.width > 10 { tooltipSize = $0 } }
    }
}

/// 性能面板：帧率等渲染统计走 RenderStatsState
private struct StatsPanelView: View {
    @ObservedObject var store: TrackStore
    @ObservedObject var render: RenderStatsState
    /// 补点模式下默认收成一行（点开展开）；离开补点模式后恢复完整面板
    @State private var expandedInFill = false

    var body: some View {
        Group {
            if store.settings.showStats, store.track != nil || store.fwdbActive {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if store.fillMode && !expandedInFill {
                            Text("性能面板").font(.caption.bold()).lineLimit(1)    // 收成一行时只留名字 + 帧率，德文也不截断
                        } else {
                            Text("性能 · \(render.stats.cores) 核 / Metal · \(PerfStats.buildConfig)")
                                .font(.caption.bold())
                                .lineLimit(1)
                        }
                        if store.fillMode {
                            Spacer(minLength: 4)
                            if !expandedInFill {
                                Text(verbatim: render.stats.fps >= 1 ? "\(render.stats.fps.formatted(Fmt.f0)) fps" : "—")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Button { expandedInFill.toggle() } label: {
                                Image(systemName: expandedInFill ? "chevron.up" : "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .help(expandedInFill ? String(localized: "收起性能面板") : String(localized: "展开性能面板"))
                        }
                    }
                    .padding(.bottom, store.fillMode && !expandedInFill ? 0 : 2)
                    if !store.fillMode || expandedInFill {
                    if store.track != nil {
                        statRow("点数", store.viewFilter != nil
                            ? "\(store.visibleIndexRange().len.formatted()) / \(render.stats.pointCount.formatted())"
                            : render.stats.pointCount.formatted())
                        statRow("采样率", lodText)
                        statRow("解析", parseText)
                        statRow("投影", "\(render.stats.projectMs.formatted(Fmt.f2)) ms · vForce")
                        statRow("测速", "\(render.stats.speedMs.formatted(Fmt.f2)) ms · vDSP")
                        statRow("着色", "\(render.stats.colorMs.formatted(Fmt.f2)) ms · LUT")
                    } else if store.fwdbActive {
                        statRow("格子", (store.fogArchive?.stats.cells ?? 0).formatted())
                    }
                    statRow("编码", "\(render.stats.encodeMs.formatted(Fmt.f2)) ms · 1 draw call")
                    statRow("等待", "\(render.stats.waitMs.formatted(Fmt.f2)) ms")
                    statRow(verbatim: "GPU", "\(render.stats.gpuMs.formatted(Fmt.f2)) ms")
                    statRow("帧率", render.stats.fps >= 1
                        ? "\(render.stats.fps.formatted(Fmt.f0)) fps" : "—")
                    if store.track != nil {
                        statRow("拾取", "\(render.stats.hoverMicros.formatted(Fmt.f0)) µs · argmin")
                    }
                    }
                }
                .font(.caption.monospacedDigit())
                .padding(store.fillMode && !expandedInFill ? 8 : 12)
                .frame(width: 250, alignment: .leading)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
        }
    }

    /// 「采样率」一行的值：LOD 抽稀时显示步长与实际上屏点数
    private var lodText: String {
        let stride = render.stats.lodStride
        guard stride > 1 else {
            return String(localized: "全量", comment: "Performance panel, sampling-rate row: every point is drawn (no LOD thinning)")
        }
        let drawn = render.stats.drawnPoints.formatted()
        return String(localized: "1/\(stride) · \(drawn) 点",
                      comment: "Performance panel, sampling-rate row: LOD stride 1/%1$lld, then number of points actually drawn (%2$@, already digit-grouped)")
    }

    /// 「解析」一行的值：耗时 · 并行块数（· 吞吐）
    private var parseText: String {
        let s = render.stats
        if s.throughputMBs > 0 {
            return String(localized: "\(s.parseMs, format: Fmt.f1) ms · \(s.chunks) 块 · \(s.throughputMBs, format: Fmt.f0) MB/s",
                          comment: "Performance panel, parse row: %1$@ = parse time in ms, %2$lld = number of chunks parsed in parallel, %3$@ = throughput in MB/s")
        }
        return String(localized: "\(s.parseMs, format: Fmt.f1) ms · \(s.chunks) 块并行",
                      comment: "Performance panel, parse row: %1$@ = parse time in ms, %2$lld = number of chunks parsed in parallel")
    }

    private func statRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        statRow(label: Text(label), value)
    }

    /// 不翻译的标签（GPU 这类专名）
    private func statRow(verbatim label: String, _ value: String) -> some View {
        statRow(label: Text(verbatim: label), value)
    }

    private func statRow(label: Text, _ value: String) -> some View {
        HStack {
            label.foregroundStyle(Color.primary.opacity(0.72))
            Spacer()
            Text(value).foregroundStyle(Color.primary)
        }
    }

}

/// 比例尺
private struct ScaleBarLayer: View {
    @ObservedObject var state: ScaleBarState

    var body: some View {
        Group {
            if let info = state.info {
                VStack(spacing: 3) {
                    Text(info.label)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.primary)
                    ZStack(alignment: .leading) {
                        Rectangle().frame(width: info.widthPt, height: 2)
                        Rectangle().frame(width: 1.5, height: 7)
                        Rectangle().frame(width: 1.5, height: 7).offset(x: info.widthPt - 1.5)
                    }
                    .foregroundStyle(Color.primary.opacity(0.85))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - 网络状况横幅（离线 / 最近请求失败 / 很慢）：联网的几个界面都放一条

struct NetworkBanner: View {
    @ObservedObject private var health = NetworkHealth.shared

    var body: some View {
        if let s = health.summary {
            HStack(spacing: 6) {
                Image(systemName: health.offline ? "wifi.slash" : "wifi.exclamationmark").foregroundStyle(.orange)
                Text(s).font(.caption).lineLimit(2)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            .help("路网草稿（OSRM / Valhalla）、铁路数据（Overpass）、地图判段、地名查询都要联网。判定依据：系统网络状态，以及最近 3 分钟内请求的失败/超时/耗时")
        }
    }
}


/// 一组圆点合成一个形状（几百个句柄时比几百个 Circle 视图便宜）
struct CircleMarksShape: Shape {
    var points: [CGPoint]
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for c in points where c.x.isFinite && c.y.isFinite {
            p.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
        }
        return p
    }
}


/// 多条折线合成一个形状（批量预览上千条线时用）
private struct PolylinesShape: Shape {
    let lines: [[CGPoint]]
    var dashPeriod: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for l in lines { p.addPath(PolylineShape(points: l, dashPeriod: dashPeriod).path(in: rect)) }
        return p
    }
}
private struct MultiEndArrowsShape: Shape {
    let lines: [[CGPoint]]
    let size: CGFloat
    let inset: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for l in lines { p.addPath(SegmentEndArrowsShape(points: l, size: size, inset: inset, onlyLast: true).path(in: rect)) }
        return p
    }
}

/// 自动换行的横向排列：补点候选面板只有 290 pt，德文/英文的筛选控件一行放不下。
/// 每个控件按自己的理想宽度摆放，放不下就换行——不压缩、不折字、不省略。
private struct WrappingHStack: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    private func layoutRows(maxWidth: CGFloat, subviews: Subviews) -> ([[(Int, CGSize)]], CGFloat) {
        var rows: [[(Int, CGSize)]] = []
        var current: [(Int, CGSize)] = []
        var x: CGFloat = 0
        var widest: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let ideal = v.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            let w = min(ideal.width, maxWidth)
            if !current.isEmpty && x + spacing + w > maxWidth {
                rows.append(current)
                widest = max(widest, x)
                current = []
                x = 0
            }
            x += (current.isEmpty ? 0 : spacing) + w
            current.append((i, CGSize(width: w, height: ideal.height)))
        }
        if !current.isEmpty {
            rows.append(current)
            widest = max(widest, x)
        }
        return (rows, min(widest, maxWidth))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let (rows, width) = layoutRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(CGFloat(0)) { $0 + ($1.map { $0.1.height }.max() ?? 0) }
            + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (rows, _) = layoutRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for (i, s) in row {
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: s.width, height: s.height))
                x += s.width + spacing
            }
            y += (row.map { $0.1.height }.max() ?? 0) + lineSpacing
        }
    }
}


struct CityPickerSheet: View {
    @ObservedObject var store: TrackStore
    @State private var selected: Set<Int> = []
    @State private var names: [Int: String] = [:]

    private func lat(_ y: Double) -> Double { atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi }
    private func lon(_ x: Double) -> Double { x * 360 - 180 }

    private func loadNames() {
        for item in store.cityPickerItems where names[item.id] == nil {
            let loc = CLLocation(latitude: lat(item.y), longitude: lon(item.x))
            CLGeocoder().reverseGeocodeLocation(loc) { placemarks, _ in
                let p = placemarks?.first
                if let n = p?.locality ?? p?.subAdministrativeArea ?? p?.administrativeArea {
                    DispatchQueue.main.async { names[item.id] = n }
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择要单独展示的城市").font(.headline)
            Text("默认勾选当前自动选中的城市；点数 ≥10000 的种子城市都可加入。")
                .font(.caption).foregroundStyle(.secondary)
            List(store.cityPickerItems) { item in
                Toggle(isOn: Binding(
                    get: { selected.contains(item.id) },
                    set: { on in
                        if on { selected.insert(item.id) } else { selected.remove(item.id) }
                    })) {
                    Text("\(names[item.id] ?? String(format: "%.2f, %.2f", lat(item.y), lon(item.x)))  ·  \(Int(item.w)) 点")
                        .font(.system(.body, design: .monospaced))
                }
            }
            HStack {
                Spacer()
                Button("取消") { store.showCityPicker = false }
                Button("应用") {
                    store.showCityPicker = false
                    store.applyCitySelection(selected)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding()
        .frame(width: 440, height: 480)
        .onAppear { selected = store.defaultCitySelection(); loadNames() }
    }
}

struct PlaybackSetupSheet: View {
    @ObservedObject var store: TrackStore
    @AppStorage("playbackMode") private var modeRaw = "overall"
    @AppStorage("playbackDuration") private var duration = 45.0
    @AppStorage("videoWidth") private var videoWidth = 1920
    @AppStorage("playbackCityX") private var cityX = 0.0
    @AppStorage("playbackCityY") private var cityY = 0.0
    @State private var selectedCity = -1
    @State private var names: [Int: String] = [:]

    private func lat(_ y: Double) -> Double { atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi }
    private func lon(_ x: Double) -> Double { x * 360 - 180 }

    private func restoreSelection() {
        guard !store.cityPickerItems.isEmpty else { return }
        var best = -1
        var bestD = Double.infinity
        for (i, item) in store.cityPickerItems.enumerated() {
            let d = abs(item.x - cityX) + abs(item.y - cityY)
            if d < bestD { bestD = d; best = i }
        }
        if bestD < 0.01 { selectedCity = best }
        else if selectedCity < 0 { selectedCity = store.cityPickerItems.first?.id ?? -1 }
    }

    private func loadNames() {
        for item in store.cityPickerItems where names[item.id] == nil {
            let loc = CLLocation(latitude: lat(item.y), longitude: lon(item.x))
            CLGeocoder().reverseGeocodeLocation(loc) { placemarks, _ in
                let p = placemarks?.first
                let name = p?.locality ?? p?.subAdministrativeArea ?? p?.administrativeArea
                if let name {
                    DispatchQueue.main.async { names[item.id] = name }
                }
            }
        }
    }

    private func name(for item: CityPickItem) -> String {
        names[item.id] ?? String(format: "%.2f, %.2f", lat(item.y), lon(item.x))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("时光机").font(.title2).bold()
            Picker("模式", selection: $modeRaw) {
                Text("整体时光机").tag("overall")
                Text("城市时光机").tag("city")
            }
            .pickerStyle(.segmented)

            if modeRaw == "city" {
                Text("选择城市").font(.headline)
                if store.cityPickerItems.isEmpty {
                    HStack { ProgressView(); Text("正在分析城市…").font(.caption) }
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(store.cityPickerItems) { item in
                                Button {
                                    selectedCity = item.id
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: selectedCity == item.id ? "largecircle.fill.circle" : "circle")
                                        Text(name(for: item))
                                        Spacer()
                                        Text("\(Int(item.w)) 点").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                    .frame(height: 150)
                }
            }

            Picker("时长", selection: $duration) {
                Text("10 秒").tag(10.0)
                Text("20 秒").tag(20.0)
                Text("30 秒").tag(30.0)
                Text("45 秒").tag(45.0)
                Text("60 秒").tag(60.0)
                Text("2 分钟").tag(120.0)
            }
            .pickerStyle(.segmented)
            .onAppear {
                if duration < 10 { duration = 10 }
                if duration > 120 { duration = 120 }
            }

            Picker("视频分辨率", selection: $videoWidth) {
                Text("720p").tag(1280)
                Text("1080p").tag(1920)
                Text("4K").tag(3840)
            }
            .pickerStyle(.segmented)

            HStack {
                Spacer()
                Button("取消") { store.showPlaybackSetup = false }
                Button("开始") {
                    var centers: [(x: Double, y: Double)]? = nil
                    if modeRaw == "city", let item = store.cityPickerItems.first(where: { $0.id == selectedCity }) {
                        centers = [(x: item.x, y: item.y)]
                        cityX = item.x
                        cityY = item.y
                    }
                    store.showPlaybackSetup = false
                    store.startPlayback(duration: duration, seedCenters: centers)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(modeRaw == "city" && selectedCity < 0)
            }
        }
        .padding(20)
        .frame(width: 520, height: 520)
        .onAppear {
            store.loadCityCandidates()
            restoreSelection()
        }
        .onChange(of: store.cityPickerItems.count) { _ in
            restoreSelection()
            loadNames()
        }
        .onAppear { loadNames() }
    }
}

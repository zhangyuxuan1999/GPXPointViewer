//
//  ContentView.swift
//  GPXPointViewer
//
//  主界面：地图 + 控制面板 + 图例 + 性能面板 + 悬停/选中详情卡。
//  所有设置控件都用 store.binding()（延迟发布），配合 onChange 触发重着色，
//  不会在视图更新期间发布状态。
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store = TrackStore()
    @State private var dropTargeted = false
    @State private var hoveringName = false
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if store.displayMode == .compare {
                    CompareMapView(store: store)
                } else {
                    PointMapView(store: store)
                }

                if store.track == nil && !store.isLoading {
                    Group {
                        if store.presenting {
                            // 闲置展示：不挡地球，仅左上角一行白字
                            Text("拖入 GPX 文件，或按 ⌘O 打开")
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

                if let info = store.hover {
                    TooltipCard(info: info)
                        .offset(x: min(info.screenPoint.x + 16, geo.size.width - 250),
                                y: min(info.screenPoint.y + 16, geo.size.height - 170))
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

                if store.isLoading {
                    loadingCard
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if store.displayMode != .compare {
                controlPanel.padding(12).opacity(uiFade).animation(.easeInOut(duration: 0.3), value: store.presenting)
            }
        }
        .overlay(alignment: .topTrailing) {
            if store.displayMode != .compare {
                VStack(alignment: .trailing, spacing: 10) {
                    selectedCard
                    fileListPanel
                }
                .padding(12)
            }
        }
        .overlay(alignment: .trailing) { globeStyleControls.padding(.trailing, 12).opacity(uiFade).animation(.easeInOut(duration: 0.3), value: store.presenting) }
        .overlay(alignment: .bottomLeading) {
            if store.displayMode != .compare {
                legend.padding(12).opacity(uiFade).animation(.easeInOut(duration: 0.3), value: store.presenting)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if store.displayMode != .compare {
                statsPanel.padding(12).opacity(uiFade).animation(.easeInOut(duration: 0.3), value: store.presenting)
            }
        }
        .overlay(alignment: .bottom) {
            if store.displayMode != .compare { scaleBarView.padding(.bottom, 10) }
        }
        .overlay(alignment: .top) {
            if store.displayMode == .compare {
                compareBar.padding(.top, 10)
            } else {
                deleteModeHint.padding(.top, 10)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { handleDrop($0) }
        .onChange(of: dropTargeted) {
            // Finder 拖拽悬停期间没有 mouseMoved，isTargeted 是唯一的活动信号
            if dropTargeted { store.noteUserActivity() }
        }
        .onChange(of: store.settings.colorMode) { store.recolorNow() }
        .onChange(of: store.settings.singleColor) {
            if store.settings.colorMode == .single { store.recolorNow() }
        }
        .sheet(isPresented: $store.showExportSheet) { ExportSheet(store: store) }
        .sheet(isPresented: $store.showSettingsSheet) { settingsSheet }
        .alert("确认删除 \(store.executePrompt ?? 0) 个点？", isPresented: executeBinding) {
            Button("删除", role: .destructive) { store.confirmExecuteStaged() }
            Button("取消（什么都不删）", role: .cancel) { store.discardStagedAndExit() }
        } message: {
            Text("其余点保持原样。此确认为最终操作（预删除阶段随时可 ⌘Z 逐步撤销）。确认或取消后都会退出删除模式。")
        }
        .alert("无法加载", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onExitCommand {
            if store.deleteMode { store.discardStagedAndExit() }
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
                            Text(st.rawValue).tag(st)
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

    // MARK: - 对比模式顶栏（居中悬浮：文件、交换、共享显示设置；不偏占任何一侧）

    private var compareBar: some View {
        HStack(spacing: 10) {
            compareChip(side: 0)
            Button {
                store.compareSwap.toggle()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .help("交换左右")
            compareChip(side: 1)

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
                Text(side == 0 ? "左" : "右")
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

    // MARK: - 文件列表（重叠模式）

    private var fileListPanel: some View {
        Group {
            if store.displayMode == .overlay, !store.files.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("文件列表").font(.caption.bold())
                        Spacer()
                        Text("\(store.files.count) 个")
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
                    Text("点击文件名可在地图上高亮对应轨迹")
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

    /// 单个文件行：色标取色器 + 名称（点击闪烁高亮）+ 关闭；行底色跟随文件色
    private func fileRow(_ f: LoadedFile) -> some View {
        HStack(spacing: 6) {
            ColorPicker("", selection: Binding(
                get: { store.files.first(where: { $0.id == f.id })?.color ?? f.color },
                set: { store.setFileColor(f.id, $0) }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 26)
                .help("此文件的点颜色")
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
        .background(f.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
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

    private var scaleBarView: some View {
        Group {
            if let info = store.scaleBar {
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

    // MARK: - 控制面板

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    store.clearTrack()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .help("清除当前已导入的文件")
                .disabled(store.track == nil)

                Button {
                    store.openPanel()
                } label: {
                    Label("打开 GPX", systemImage: "folder")
                }
                .keyboardShortcut("o", modifiers: .command)

                Button {
                    store.showSettingsSheet = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("设置：外观 / 闲置展示 / 压力测试")
                .keyboardShortcut(",", modifiers: .command)

                if store.displayMode == .single, store.track != nil {
                    Button {
                        store.requestLocate()
                    } label: {
                        Image(systemName: "location")
                    }
                    .help("定位到轨迹起点（地球视角同样可用）")
                }

                if let track = store.track {
                    VStack(alignment: .leading, spacing: 1) {
                        // 悬停立即原地展开为多行完整文件名（onHover 事件级响应，无系统延迟）
                        Text(track.name)
                            .font(.caption.bold())
                            .lineLimit(hoveringName ? nil : 1)
                            .truncationMode(.middle)
                        Text("\(track.count.formatted()) 个点")
                            .font(.caption2)
                            .foregroundStyle(Color.primary.opacity(0.75))
                        if let tr = track.timeRange {
                            Text("\(Self.dayText(tr.min)) ~ \(Self.dayText(tr.max))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Color.primary.opacity(0.75))
                        }
                    }
                    .onHover { hoveringName = $0 }
                    .animation(.easeOut(duration: 0.1), value: hoveringName)
                }
            }

            Divider()

            if !store.files.isEmpty {
                Picker("显示模式", selection: Binding(
                    get: { store.displayMode },
                    set: { store.switchDisplayMode(to: $0) })) {
                    ForEach(store.availableModes) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("单文件：新文件替换当前｜重叠：分批拖入合并显示｜对比：两文件左右分屏")
            }

            if store.displayMode == .overlay {
                Text("重叠模式：每个文件单独着色（见右侧文件列表）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Picker("着色", selection: store.binding(\.colorMode)) {
                    ForEach(ColorMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if store.settings.colorMode == .single {
                    HStack(spacing: 8) {
                        Text("点颜色").font(.caption)
                        ColorPicker("点颜色", selection: store.binding(\.singleColor), supportsOpacity: false)
                            .labelsHidden()
                        Spacer()
                    }
                }
            }

            Picker("底图", selection: store.binding(\.mapStyle)) {
                ForEach(BaseMapStyle.allCases) { style in
                    Text(style.rawValue).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("持续缩小地图会无缝进入地球视角，放大自动返回")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("点大小").font(.caption).frame(width: 44, alignment: .leading)
                Slider(value: store.binding(\.pointSize), in: 1...12)
                Text(String(format: "%.1f", store.settings.pointSize))
                    .font(.caption.monospacedDigit())
                    .frame(width: 34, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Text("点透明").font(.caption).frame(width: 44, alignment: .leading)
                Slider(value: store.binding(\.opacity), in: 0.15...1)
                Text(String(format: "%.0f%%", store.settings.opacity * 100))
                    .font(.caption.monospacedDigit())
                    .frame(width: 34, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Text("底图").font(.caption).frame(width: 44, alignment: .leading)
                Slider(value: store.binding(\.mapOpacity), in: 0.2...1)
                Text(String(format: "%.0f%%", store.settings.mapOpacity * 100))
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

            HStack(spacing: 12) {
                Toggle("轨迹线", isOn: store.binding(\.showTrackLine))
                    .disabled(store.track?.isMultiSegment == true)
                    .help(store.track?.isMultiSegment == true
                          ? "多段/多日轨迹已禁用轨迹线：跨轨迹连线无意义且耗性能"
                          : "线段渲染为方向箭头（时间早 → 晚）；地球视角只显示点云")
                Toggle("白描边", isOn: store.binding(\.showHalo))
            }
            .font(.caption)
            .toggleStyle(.checkbox)
            HStack(spacing: 12) {
                Toggle("性能面板", isOn: store.binding(\.showStats))
                Toggle("自动降采样", isOn: store.binding(\.lodEnabled))
            }
            .font(.caption)
            .toggleStyle(.checkbox)

            if store.settings.showTrackLine {
                HStack(spacing: 10) {
                    Text("线颜色").font(.caption)
                    ColorPicker("线颜色", selection: store.binding(\.lineColor), supportsOpacity: false)
                        .labelsHidden()
                    Toggle("方向箭头", isOn: store.binding(\.showArrows))
                        .font(.caption)
                        .toggleStyle(.checkbox)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Text("线宽").font(.caption).frame(width: 44, alignment: .leading)
                    Slider(value: store.binding(\.lineWidth), in: 1...8)
                    Text(String(format: "%.1f", store.settings.lineWidth))
                        .font(.caption.monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                }
                HStack(spacing: 8) {
                    Text("线透明").font(.caption).frame(width: 44, alignment: .leading)
                    Slider(value: store.binding(\.lineOpacity), in: 0.1...1)
                    Text(String(format: "%.0f%%", store.settings.lineOpacity * 100))
                        .font(.caption.monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    if store.exportNeedsSheet {
                        store.showExportSheet = true
                    } else {
                        store.exportGPX(range: nil)   // 单日/无时间数据：直接导出
                    }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .disabled(store.track == nil)

                Button {
                    store.toggleDeleteMode()
                } label: {
                    Label(store.deleteMode ? "放弃删除" : "删除点", systemImage: "lasso")
                }
                .disabled(store.track == nil || store.displayMode != .single)
                .help(store.displayMode == .single
                      ? "手绘圈选暂存待删点；地球视角下同样可用（右键拖拽旋转地球）"
                      : "重叠/对比模式下不可删除点（请切回单文件模式）")
                .tint(store.deleteMode ? Color.red : Color.accentColor)
            }
            .font(.caption)

        }
        .padding(14)
        .frame(width: 290)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
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
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

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

    // MARK: - 图例

    private var legend: some View {
        Group {
            if let track = store.track, let labels = track.legendLabels() {
                HStack(spacing: 8) {
                    Text(track.effectiveMode.rawValue)
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

    private var statsPanel: some View {
        Group {
            if store.settings.showStats, store.track != nil {
                VStack(alignment: .leading, spacing: 3) {
                    Text("性能 · \(store.stats.cores) 核 / Metal · \(PerfStats.buildConfig)")
                        .font(.caption.bold())
                        .padding(.bottom, 2)
                    statRow("点数", store.viewFilter != nil
                        ? "\(store.visibleIndexRange().len.formatted()) / \(store.stats.pointCount.formatted())"
                        : store.stats.pointCount.formatted())
                    statRow("采样率", store.stats.lodStride > 1
                        ? "1/\(store.stats.lodStride) · \(store.stats.drawnPoints.formatted()) 点"
                        : "全量")
                    statRow("解析", store.stats.throughputMBs > 0
                        ? String(format: "%.1f ms · %d 块 · %.0f MB/s", store.stats.parseMs, store.stats.chunks, store.stats.throughputMBs)
                        : String(format: "%.1f ms · %d 块并行", store.stats.parseMs, store.stats.chunks))
                    statRow("投影", String(format: "%.2f ms · vForce", store.stats.projectMs))
                    statRow("测速", String(format: "%.2f ms · vDSP", store.stats.speedMs))
                    statRow("着色", String(format: "%.2f ms · LUT", store.stats.colorMs))
                    statRow("编码", String(format: "%.2f ms · 1 draw call", store.stats.encodeMs))
                    statRow("等待", String(format: "%.2f ms", store.stats.waitMs))
                    statRow("GPU", String(format: "%.2f ms", store.stats.gpuMs))
                    statRow("帧率", store.stats.fps >= 1
                        ? String(format: "%.0f fps", store.stats.fps) : "—")
                    statRow("拾取", String(format: "%.0f µs · argmin", store.stats.hoverMicros))
                }
                .font(.caption.monospacedDigit())
                .padding(12)
                .frame(width: 250, alignment: .leading)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.primary.opacity(0.72))
            Spacer()
            Text(value).foregroundStyle(Color.primary)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
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
                        infoRow("速度", String(format: "%.1f km/h", v))
                    }
                    if let e = info.ele {
                        infoRow("海拔", String(format: "%.1f m", e))
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

    private func infoRow(_ label: String, _ value: String) -> some View {
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
            Text("拖入 GPX 文件，或按 ⌘O 打开")
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
            let gpxish = urls.filter { ["gpx", "xml"].contains($0.pathExtension.lowercased()) }
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
                    Text(String(format: "%.1f km/h", v))
                }
                if let e = info.ele {
                    Text(String(format: "%.1f m", e))
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

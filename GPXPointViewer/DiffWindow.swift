//
//  DiffWindow.swift
//  GPXPointViewer
//
//  找不同的独立窗口：一张地图同时展示"左独有"与"右独有"的点，
//  两种颜色可选（对比面板同步换色）。地图/渲染复用 ComparePaneView +
//  MetalPointRenderer（与对比面板同一套点云管线与 LOD）。
//

import SwiftUI
import MapKit

struct DiffWindowView: View {
    @ObservedObject var store: TrackStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let r = store.diffResult {
                    label(color: displayLeftColor,
                          text: "左独有 \(leftCount(r).formatted())")
                    label(color: displayRightColor,
                          text: "右独有 \(rightCount(r).formatted())")
                    Text("共同 \(r.common.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider().frame(height: 16)
                    ColorPicker("左色", selection: store.binding(\.diffColorLeft))
                        .font(.caption)
                        .fixedSize()
                    ColorPicker("右色", selection: store.binding(\.diffColorRight))
                        .font(.caption)
                        .fixedSize()
                    Spacer()
                    if store.diffTrack == nil {
                        Text("两个文件完全相同")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }
                } else {
                    (store.displayMode == .compare
                        ? Text("在对比模式点击「找不同」计算差异",
                               comment: "Find Differences window, before a result exists; 「找不同」 is the Find Differences button in the main window's compare panel")
                        : Text("先在主窗口进入对比模式（导入两个文件）"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            DiffMapView(store: store)
                .overlay(alignment: .bottomLeading) { MapAttributionView(style: store.settings.mapStyle).padding(6) }   // 外部底图署名
        }
        // 换色实时重刷两处着色（对比面板 + 本窗口）
        .onChange(of: store.settings.diffColorLeft) { store.applyDiffColors() }
        .onChange(of: store.settings.diffColorRight) { store.applyDiffColors() }
    }

    // applyDiffColors 保证"显示在左的那条"永远用 diffColorLeft 着色
    //（交换时换的是数据侧别，不是颜色侧别），标签色块与渲染色一致
    private var displayLeftColor: Color { store.settings.diffColorLeft }
    private var displayRightColor: Color { store.settings.diffColorRight }
    private func leftCount(_ r: DiffCompare.Result) -> Int {
        store.compareSwap ? r.rightOnly.count : r.leftOnly.count
    }
    private func rightCount(_ r: DiffCompare.Result) -> Int {
        store.compareSwap ? r.leftOnly.count : r.rightOnly.count
    }

    private func label(color: Color, text: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.caption.monospacedDigit().bold())
        }
    }
}

/// 单面板差异地图（渲染循环与对比面板同构，无左右镜像）
struct DiffMapView: NSViewRepresentable {
    @ObservedObject var store: TrackStore

    func makeCoordinator() -> DiffCoordinator { DiffCoordinator(store: store) }

    func makeNSView(context: Context) -> ComparePaneView {
        let v = ComparePaneView(frame: CGRect(x: 0, y: 0, width: 900, height: 620))
        context.coordinator.attach(v)
        return v
    }

    func updateNSView(_ nsView: ComparePaneView, context: Context) {
        context.coordinator.sync()
    }

    @MainActor
    final class DiffCoordinator: NSObject, MKMapViewDelegate {
        private let store: TrackStore
        private weak var pane: ComparePaneView?
        private var renderer: MetalPointRenderer?
        private var shownTrackID: UUID?
        private var shownColorVersion = -1
        private var shownSettings = ViewSettings()
        private var redrawScheduled = false
        private let baseMap = BaseMapApplier()

        init(store: TrackStore) {
            self.store = store
            super.init()
        }

        func attach(_ pane: ComparePaneView) {
            self.pane = pane
            pane.mapView.delegate = self
            pane.mapView.isRotateEnabled = false
            pane.mapView.isPitchEnabled = false
            pane.mapView.showsZoomControls = false
            pane.dimView.alphaValue = CGFloat(1.0 - store.settings.mapOpacity)
            pane.overlay.onGeometryChange = { [weak self] in self?.scheduleRedraw() }
            applyMapStyle()
            renderer = MetalPointRenderer()
            if let r = renderer { pane.overlay.metalLayer.device = r.device }
            shownSettings = store.settings
            sync()
        }

        func sync() {
            guard let pane else { return }
            if let t = store.diffTrack {
                if t.id != shownTrackID {
                    shownTrackID = t.id
                    shownColorVersion = t.colorVersion
                    renderer?.setData(track: t)
                    // setData 领养的是 build 期预建的颜色缓冲——computeDiff 在
                    // build 之后又做了 recolorByFile，必须再传一次当前颜色，
                    // 否则首帧显示的是重着色前的单蓝
                    renderer?.updateColors(t.colors)
                    zoomToFit(t, in: pane.mapView)
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
            if store.settings != shownSettings {
                let old = shownSettings
                shownSettings = store.settings
                if old.mapOpacity != store.settings.mapOpacity {
                    pane.dimView.alphaValue = CGFloat(1.0 - store.settings.mapOpacity)
                }
                if old.mapStyle != store.settings.mapStyle { applyMapStyle() }
                scheduleRedraw()
            }
        }

        private func applyMapStyle() {
            guard let pane else { return }
            baseMap.apply(store.settings.mapStyle, to: pane.mapView, elevation: .flat)
        }

        nonisolated func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            BaseMapApplier.renderer(for: overlay) ?? MKOverlayRenderer(overlay: overlay)
        }

        private func zoomToFit(_ t: TrackData, in mapView: MKMapView) {
            let p1 = MKMapPoint(CLLocationCoordinate2D(latitude: t.bbox.maxLat,
                                                       longitude: t.bbox.minLon))
            let p2 = MKMapPoint(CLLocationCoordinate2D(latitude: t.bbox.minLat,
                                                       longitude: t.bbox.maxLon))
            var rect = MKMapRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                                 width: max(1000, abs(p1.x - p2.x)),
                                 height: max(1000, abs(p1.y - p2.y)))
            rect = rect.insetBy(dx: -rect.size.width * 0.14, dy: -rect.size.height * 0.14)
            mapView.setVisibleMapRect(rect, animated: false)
        }

        nonisolated func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            MainActor.assumeIsolated { scheduleRedraw() }
        }

        nonisolated func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            MainActor.assumeIsolated { scheduleRedraw() }
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
            // diffTrack 清空后也要画一帧空帧，否则覆盖层残留上一次的差异点
            guard let pane, let renderer else { return }
            let r = pane.mapView.visibleMapRect
            let world = MKMapRect.world.size.width
            guard r.size.width > 0, r.size.height > 0,
                  pane.overlay.metalLayer.drawableSize.width > 1 else { return }
            let camera = CameraRect(
                x0: r.origin.x / world,
                y0: r.origin.y / world,
                w: r.size.width / world,
                h: r.size.height / world,
                pxW: Double(pane.overlay.metalLayer.drawableSize.width),
                pxH: Double(pane.overlay.metalLayer.drawableSize.height))
            let scale = Double(pane.overlay.backingScale)
            renderer.render(
                layer: pane.overlay.metalLayer,
                camera: camera,
                pointSizePx: store.settings.pointSize * scale,
                opacity: store.settings.opacity,
                halo: store.settings.showHalo,
                line: nil,
                highlight: nil,
                lodStride: lodStride(camera: camera, scale: scale),
                range: nil,
                lodDedupe: store.settings.lodEnabled,
                orderSensitive: true)      // 左右独有点重叠处按时间"晚者在上"
        }

        /// 与对比面板同一套中位段长 LOD（差异集也可能达百万点级）
        private func lodStride(camera: CameraRect, scale: Double) -> Int {
            guard let t = store.diffTrack,
                  store.settings.lodEnabled, t.count > 60_000,
                  t.medianSegMerc > 0 else { return 1 }
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

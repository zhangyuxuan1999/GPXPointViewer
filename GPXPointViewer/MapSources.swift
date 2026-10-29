//
//  MapSources.swift
//  GPXPointViewer
//
//  多来源底图：除 Apple 的标准/卫星/混合外，可切到 OpenStreetMap 标准瓦片、OpenTopoMap、Esri World Imagery。
//  动机：补点用的是 OSM 道路几何，而 Apple 底图不画隧道——补在隧道里的点看起来"在路外"，其实在 OSM 隧道中心线上。
//  换成 OSM 瓦片就能看到路由用的那条线（隧道虚线、分向车道）。
//
//  实现：MKTileOverlay 子类（canReplaceMapContent = true，自己用 URLSession 取瓦片），插在 MKMapView 覆盖层最底部；
//  Metal 点层是 MKMapView 的兄弟子视图，永远在瓦片之上，叠层顺序不受影响。切回 Apple 底图时移除 overlay。
//
//  公共服务使用纪律（见 docs/map-sources.md）：
//  - 请求头 User-Agent: GPXPointViewer/<版本> (macOS; de.wayne.GPXPointViewer)，Accept: image/png
//  - 不超过各来源的最大 zoom（maximumZ 让 MapKit 放大低一级瓦片，不请求不存在的级别）
//  - 独立 URLCache（磁盘 ≤ 300 MB，容器 Caches/MapTiles），遵守服务器缓存头；不预取、不批量下载（OSMF 瓦片使用政策）
//  - 失败的瓦片 60 s 内不再请求；连续失败进 NetworkHealth 横幅
//  - 左下角显示对应署名并可点开版权页；第一次切到外部底图弹一次性说明
//  Google 地图不做：需要密钥计费，且条款禁止在 Google SDK 之外使用其瓦片。
//

import SwiftUI
import MapKit
import AppKit
import ImageIO
import UniformTypeIdentifiers
import os

// MARK: - 瓦片来源

/// 一个外部瓦片来源（URL 模板、最大级别、署名）
struct TileSource: Sendable {
    let id: String                      // 稳定标识（缓存/日志用）
    let host: String                    // NetworkHealth / 日志里的主机名
    let maxZ: Int
    let attribution: String             // 署名原文（服务商要求的措辞，不本地化）
    let attributionURL: URL
    let url: @Sendable (MKTileOverlayPath) -> URL

    /// OpenStreetMap 标准瓦片（tile.openstreetmap.org，z ≤ 19）
    static let openStreetMap = TileSource(
        id: "osm", host: "tile.openstreetmap.org", maxZ: 19,
        attribution: "© OpenStreetMap contributors",
        attributionURL: URL(string: "https://www.openstreetmap.org/copyright")!,
        url: { p in URL(string: "https://tile.openstreetmap.org/\(p.z)/\(p.x)/\(p.y).png")! })

    /// OpenTopoMap（a/b/c 三个子域轮流，z ≤ 17）
    static let openTopoMap = TileSource(
        id: "topo", host: "tile.opentopomap.org", maxZ: 17,
        attribution: "© OpenTopoMap (CC-BY-SA), data © OpenStreetMap contributors, SRTM",
        attributionURL: URL(string: "https://opentopomap.org/about")!,
        url: { p in
            let sub = ["a", "b", "c"][(p.x + p.y) % 3]
            return URL(string: "https://\(sub).tile.opentopomap.org/\(p.z)/\(p.x)/\(p.y).png")!
        })

    /// Esri World Imagery（ArcGIS Online，路径顺序是 z/y/x，z ≤ 19）
    static let esriImagery = TileSource(
        id: "esri", host: "server.arcgisonline.com", maxZ: 19,
        attribution: "Source: Esri, Maxar, Earthstar Geographics, and the GIS User Community",
        attributionURL: URL(string: "https://www.esri.com/en-us/legal/terms/data-attributions")!,
        url: { p in URL(string: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/\(p.z)/\(p.y)/\(p.x)")! })
}

extension BaseMapStyle {
    /// 外部瓦片来源；Apple 三种为 nil
    var tileSource: TileSource? {
        switch self {
        case .osm: return .openStreetMap
        case .topo: return .openTopoMap
        case .esri: return .esriImagery
        case .standard, .imagery, .hybrid: return nil
        }
    }
    var isExternal: Bool { tileSource != nil }

    /// 快照/导出/3D 热力地面用的 Apple 替代：MKMapSnapshotter 不画瓦片 overlay，外部底图退回最接近的 Apple 底图
    var appleFallback: BaseMapStyle {
        switch self {
        case .osm, .topo: return .standard
        case .esri: return .imagery
        case .standard, .imagery, .hybrid: return self
        }
    }

    /// Apple 底图配置（外部底图按 appleFallback 退化）
    func appleConfiguration(elevation: MKMapConfiguration.ElevationStyle) -> MKMapConfiguration {
        switch appleFallback {
        case .imagery: return MKImageryMapConfiguration(elevationStyle: elevation)
        case .hybrid: return MKHybridMapConfiguration(elevationStyle: elevation)
        default: return MKStandardMapConfiguration(elevationStyle: elevation)
        }
    }
}

// MARK: - 瓦片 overlay

/// 自己取瓦片的 MKTileOverlay：UA/Accept 头、独立 URLCache、失败冷却、假瓦片（自测）
final class ExternalTileOverlay: MKTileOverlay, @unchecked Sendable {
    let source: TileSource

    /// 自测：开着时不出网，返回程序生成的 256×256 PNG（画上 z/x/y）。只有 UITestHook 会设置
    nonisolated(unsafe) static var fakeTiles = UITestHook.enabled   // 自测副本启动就不出网（偏好里可能记着外部底图）
    /// 瓦片请求计数（含假瓦片；钩子 state.tileRequests）
    private static let requestLock = OSAllocatedUnfairLock(initialState: 0)
    static var requestCount: Int { requestLock.withLock { $0 } }
    static func resetRequestCount() { requestLock.withLock { $0 = 0 } }

    static let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("MapTiles", isDirectory: true)
    }()
    /// 独立缓存：内存 32 MB、磁盘 300 MB，遵守服务器缓存头（不自己强制过期）
    static let cache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 300 << 20, directory: cacheDirectory)
    static let userAgent: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "GPXPointViewer/\(v) (macOS; de.wayne.GPXPointViewer)"
    }()
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = cache
        c.requestCachePolicy = .useProtocolCachePolicy
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 40
        c.httpMaximumConnectionsPerHost = 4          // 对公共服务客气一点
        c.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept": "image/png"]
        return URLSession(configuration: c)
    }()

    /// 当前磁盘占用（字节）
    static var diskUsage: Int { cache.currentDiskUsage }
    static func clearCache() { cache.removeAllCachedResponses() }

    struct TileError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 失败冷却：同一瓦片 60 s 内不再请求（4xx/5xx/超时都算）
    private let failLock = NSLock()
    private var failedUntil: [String: Date] = [:]
    static let failureCooldown: TimeInterval = 60

    init(source: TileSource) {
        self.source = source
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        minimumZ = 0
        maximumZ = source.maxZ          // 超过最大级别时 MapKit 放大低一级瓦片，不会请求不存在的级别
        tileSize = CGSize(width: 256, height: 256)
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL { source.url(path) }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping @Sendable (Data?, Error?) -> Void) {
        Self.requestLock.withLock { $0 += 1 }
        if Self.fakeTiles {
            result(Self.fakeTileData(path), nil)
            return
        }
        let key = "\(path.z)/\(path.x)/\(path.y)"
        let now = Date()
        failLock.lock()
        if let until = failedUntil[key], until > now {
            failLock.unlock()
            result(nil, TileError(message: "tile cooling"))
            return
        }
        failLock.unlock()

        var req = URLRequest(url: url(forTilePath: path))
        req.cachePolicy = .useProtocolCachePolicy
        let host = source.host
        let t0 = CFAbsoluteTimeGetCurrent()
        Self.session.dataTask(with: req) { [weak self] data, resp, err in
            let dt = CFAbsoluteTimeGetCurrent() - t0
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let data, code == 200, !data.isEmpty {
                Self.health.note(host: host, ok: true, seconds: dt, detail: "")
                result(data, nil)
                return
            }
            let detail = err.map { NetworkHealth.describe($0) } ?? "HTTP \(code)"
            if let self {
                self.failLock.lock()
                self.failedUntil[key] = Date().addingTimeInterval(Self.failureCooldown)
                if self.failedUntil.count > 4096 { self.failedUntil = self.failedUntil.filter { $0.value > Date() } }
                self.failLock.unlock()
            }
            // 404（该级别/区域没有瓦片）不算网络故障；取消也不算
            if (err as? URLError)?.code != .cancelled, code != 404 {
                Self.health.note(host: host, ok: false, seconds: dt, detail: detail)
            }
            result(nil, err ?? TileError(message: detail))
        }.resume()
    }

    /// 瓦片请求结果 → NetworkHealth 的汇总上报：一次平移就是几十块瓦片，逐块上报会把补点/Overpass 的横幅冲掉。
    /// 这里按 30 s 窗口汇总：窗口内失败 ≥ 3 块且失败占多数才报一次失败；成功每窗口最多报一次（让横幅能恢复）
    static let health = TileHealthAggregator()
    final class TileHealthAggregator: @unchecked Sendable {
        private let lock = NSLock()
        private var windowStart = 0.0
        private var ok = 0, fail = 0, slow = 0.0
        private var lastDetail = ""
        private var reportedOK = false, reportedFail = false
        static let window = 30.0
        func note(host: String, ok good: Bool, seconds: Double, detail: String) {
            lock.lock()
            let now = CFAbsoluteTimeGetCurrent()
            if now - windowStart > Self.window { windowStart = now; ok = 0; fail = 0; slow = 0; reportedOK = false; reportedFail = false }
            if good { ok += 1; slow = max(slow, seconds) } else { fail += 1; lastDetail = detail }
            var send: (Bool, Double, String)?
            if !good, !reportedFail, fail >= 3, fail > ok { reportedFail = true; send = (false, seconds, lastDetail) }
            if good, !reportedOK, fail == 0 { reportedOK = true; send = (true, seconds, "") }
            lock.unlock()
            if let (g, s, d) = send { NetworkHealth.note(host: host, ok: g, seconds: s, detail: d) }
        }
    }

    /// 假瓦片：浅色底 + 边框 + "z/x/y" 文字，PNG
    static func fakeTileData(_ path: MKTileOverlayPath) -> Data? {
        let w = 256, h = 256
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let shade = CGFloat(0.86 + 0.06 * Double((path.x + path.y) % 2))
        ctx.setFillColor(CGColor(red: shade, green: shade + 0.04, blue: shade, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(CGColor(red: 0.45, green: 0.45, blue: 0.5, alpha: 1))
        ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: 1, y: 1, width: w - 2, height: h - 2))
        let text = "\(path.z)/\(path.x)/\(path.y)" as CFString
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font,
                                      kCTForegroundColorAttributeName: CGColor(red: 0.15, green: 0.15, blue: 0.2, alpha: 1)]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text, attrs as CFDictionary))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.textPosition = CGPoint(x: (CGFloat(w) - bounds.width) / 2, y: CGFloat(h) / 2 - bounds.height / 2 + 4)
        CTLineDraw(line, ctx)
        guard let img = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

// MARK: - 把底图样式应用到 MKMapView

/// 每个 MKMapView 一个：记住当前瓦片 overlay，切换时增删；Apple 底图直接设 preferredConfiguration
@MainActor
final class BaseMapApplier {
    private(set) var style: BaseMapStyle?
    private(set) var overlay: ExternalTileOverlay?

    func apply(_ style: BaseMapStyle, to mapView: MKMapView, elevation: MKMapConfiguration.ElevationStyle) {
        // 同一样式重复 apply（首个 sync 的 shownSettings 比较）：瓦片还挂着就什么都不做，免得白发一批请求
        if style == self.style, overlay == nil || mapView.overlays.contains(where: { $0 === overlay }) { return }
        if let overlay {
            mapView.removeOverlay(overlay)
            self.overlay = nil
        }
        if let src = style.tileSource {
            // 外部瓦片替换 Apple 底图内容：配置退到平面标准图（立体高程会让瓦片变形），不画 Apple 的兴趣点/交通
            let cfg = MKStandardMapConfiguration(elevationStyle: .flat)
            cfg.pointOfInterestFilter = .excludingAll
            cfg.showsTraffic = false
            mapView.preferredConfiguration = cfg
            let ov = ExternalTileOverlay(source: src)
            // 放在 .aboveLabels 这一层的最底部：盖住 Apple 自己的文字（OSM 瓦片自带文字），
            // 但在所有折线/多边形覆盖层之下；Metal 点层是兄弟视图，不受影响
            mapView.insertOverlay(ov, at: 0, level: .aboveLabels)
            overlay = ov
        } else {
            mapView.preferredConfiguration = style.appleConfiguration(elevation: elevation)
        }
        self.style = style
    }

    /// rendererFor 里调用：是自己的瓦片 overlay 就返回渲染器
    nonisolated static func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        guard let tile = overlay as? ExternalTileOverlay else { return nil }
        return MKTileOverlayRenderer(tileOverlay: tile)
    }
}

// MARK: - 署名 / 一次性说明

/// 第一次切到任一外部底图时弹一次性说明；记住不再弹
enum ExternalMapNotice {
    static let key = "externalMapNoticeShown"
    static var shown: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    /// 切到外部底图：第一次返回 true（并记住），之后 false
    static func consume(for style: BaseMapStyle) -> Bool {
        guard style.isExternal, !shown else { return false }
        shown = true
        return true
    }
    /// 一次性说明的正文
    static var message: String {
        String(localized: "OpenStreetMap、OpenTopoMap 与 Esri 影像的瓦片来自各自的公共服务器，不是 Apple 地图。请正常浏览使用：本软件只按视野取瓦片、本地缓存不超过 300 MB、不预取不批量下载。地图左下角会显示对应署名，点一下可打开版权页。隧道线数据来自 © OpenStreetMap contributors。",
               comment: "One-time notice shown the first time the user picks an external base map (OSM / OpenTopoMap / Esri)")
    }
}

/// 一次性说明的弹窗（主窗口 / 审阅窗口各挂一个；拆成 modifier 免得把大 body 的类型检查拖爆）
struct ExternalMapNoticeAlert: ViewModifier {
    @Binding var isPresented: Bool
    func body(content: Content) -> some View {
        content.alert("外部底图说明", isPresented: $isPresented) {
            Button("知道了") {}
        } message: { Text(ExternalMapNotice.message) }
    }
}

/// 地图左下角的署名（Apple 的「地图」标识旁）：外部底图显示对应文字，可点开版权页
struct MapAttributionView: View {
    let style: BaseMapStyle
    var body: some View {
        if let src = style.tileSource {
            Link(destination: src.attributionURL) {
                Text(verbatim: src.attribution)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
            .help("底图版权页")
            .accessibilityIdentifier("map-attribution")
        }
    }
}

/// 设置页「地图」区：底图来源说明（公共服务、署名、用量）+ 清空底图缓存（显示当前占用）
struct MapSettingsSection: View {
    @State private var cacheBytes = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("地图").font(.callout.bold())
            Text("底图可选 Apple（标准 / 卫星 / 混合）或外部公共瓦片：OpenStreetMap（画隧道虚线，是补点用的路网）、OpenTopoMap（地形，最大 17 级）、Esri 影像。外部瓦片只按视野取、遵守服务器缓存头、不预取不批量下载；请勿用脚本大量拉取。地图左下角显示署名，点开可看版权页。",
                 comment: "Settings › Map: explanation of the base map sources, their usage policy and attribution")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "© OpenStreetMap contributors · © OpenTopoMap (CC-BY-SA) · Esri, Maxar, Earthstar Geographics, GIS User Community")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("清空底图缓存") {
                    ExternalTileOverlay.clearCache()
                    cacheBytes = ExternalTileOverlay.diskUsage
                }
                .font(.callout)
                .help("删除外部瓦片的本地缓存（容器 Caches/MapTiles，上限 300 MB）；下次显示时重新下载")
                Text("当前占用 \(ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file))",
                     comment: "Settings › Map: current size of the external tile cache; %@ = formatted byte count")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { cacheBytes = ExternalTileOverlay.diskUsage }
    }
}

// MARK: - 底图选择控件（Apple 三段 + 外部三段，分两个分段控件）

/// 6 段放一个分段控件里固有宽度会超过图层面板（≈262 pt，德语更长），SwiftUI 把超宽子视图居中后整个面板两侧被裁。
/// 拆成两个三段控件，绑定同一个 BaseMapStyle：选中项不在本组时本组无高亮（Optional 绑定 nil）。
/// 外部来源用短标签 OSM / OpenTopo / Esri（专名，不翻译），工具提示给全名。
/// axis = .vertical 两行分段（主窗口面板）；.horizontal 一个菜单（修改记录窗口顶栏）。
struct BaseMapStylePicker: View {
    @Binding var selection: BaseMapStyle
    var axis: Axis = .vertical

    private static let apple: [BaseMapStyle] = [.standard, .imagery, .hybrid]
    private static let external: [BaseMapStyle] = [.osm, .topo, .esri]

    private func group(_ members: [BaseMapStyle]) -> Binding<BaseMapStyle?> {
        Binding(get: { members.contains(selection) ? selection : nil },
                set: { if let v = $0 { selection = v } })
    }

    private static func shortLabel(_ s: BaseMapStyle) -> String {
        switch s {
        case .osm: return "OSM"
        case .topo: return "OpenTopo"
        case .esri: return "Esri"
        default: return s.rawValue
        }
    }

    private var applePicker: some View {
        Picker("底图", selection: group(Self.apple)) {
            ForEach(Self.apple) { s in Text(s.title).tag(Optional(s)) }
        }
        .pickerStyle(.segmented).labelsHidden()
    }

    private var externalPicker: some View {
        Picker("底图", selection: group(Self.external)) {
            ForEach(Self.external) { s in Text(verbatim: Self.shortLabel(s)).tag(Optional(s)) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .help(Text("OpenStreetMap") + Text(verbatim: " · ") + Text("OpenTopoMap") + Text(verbatim: " · ") + Text("Esri 影像"))
    }

    var body: some View {
        if axis == .vertical {
            VStack(alignment: .leading, spacing: 6) { applePicker; externalPicker }
        } else {
            // 顶栏一行：两个分段控件也要 ~350 pt，和 4 个按钮挤不进 1000 pt 窗口；改成一个菜单（显示当前来源，~130 pt）
            Picker("底图", selection: $selection) {
                ForEach(Self.apple) { s in Text(s.title).tag(s) }
                Divider()
                ForEach(Self.external) { s in Text(s.title).tag(s) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
        }
    }
}

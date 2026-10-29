//
//  TunnelOverlay.swift
//  GPXPointViewer
//
//  OSM 隧道叠加层：任何底图上都能开。开着时按当前视野向 Overpass 取 tunnel=yes 的公路/铁路 way（out geom），
//  画成虚线（公路一色、铁路一色，3 pt 宽、白描边，线上无文字）。
//
//  请求规则（docs/map-sources.md）：
//  - 视野跨度 ≤ 40 km 且 zoom ≥ 11 才取；更远显示「放大后显示隧道」
//  - bbox 取视野外扩 20%；相机停稳 600 ms 后再请求；同一时刻只有一个请求在飞（主窗口/审阅窗口共享）
//  - 结果按 bbox 缓存（OverpassCache 同款，包含匹配即命中）
//  - 429/5xx 走 RateLimiter 冷却（failIfCooling：冷却中直接报「冷却中」，不排队；冷却到期自动重试一次）；失败/恢复自动进 NetworkHealth 横幅
//  - 自测：faketunnels n 注入 n 条合成直线；自测副本默认不出网（tunnelnet 1 才放行）
//

import MapKit

/// 一条隧道 way
struct TunnelWay: Sendable {
    let id: Int64
    let rail: Bool                       // false = 公路，true = 铁路
    let coords: [CLLocationCoordinate2D]
}

/// 每个 MKMapView 一个：防抖、取数、缓存、画线、状态
@MainActor
final class TunnelLayer {
    enum State: Equatable {
        case off, idle, tooFar, fetching, ready, cooling(Int), failed
        var key: String {
            switch self {
            case .off: return "off"
            case .idle: return "idle"
            case .tooFar: return "tooFar"
            case .fetching: return "fetching"
            case .ready: return "ready"
            case .cooling: return "cooling"
            case .failed: return "failed"
            }
        }
    }

    /// 自测：n > 0 时不出网，注入 n 条视野内的合成直线。只有 UITestHook 会设置
    static var fakeCount: Int = 0
    /// 自测副本默认不出网（偏好里 tunnelOverlay 可能是开的）；钩子 tunnelnet 1 才放行真实 Overpass
    static var allowNetwork = !UITestHook.enabled
    /// 同一时刻只有一个 Overpass 隧道请求在飞（主窗口 + 审阅窗口共享）
    private static var inFlight = false
    /// bbox 缓存（与批量流程的 OverpassCache 分开：同一 bbox 不同查询不能串）
    static let cache = OverpassCache()
    /// 钩子按名字找图层（"main" / "review"）
    static var registry: [String: TunnelLayer] = [:]

    static let maxSpanKm = 40.0
    static let minZoom = 11.0
    static let debounceSeconds = 0.6
    static let expandRatio = 0.2

    let name: String
    weak var mapView: MKMapView?
    /// 状态变化回调（状态栏文字、钩子镜像；画完线也会调，审阅窗口据此把草稿折线重新抬到最上面）
    var onChange: (() -> Void)?

    private(set) var enabled = false
    private(set) var state: State = .off
    private(set) var ways: [TunnelWay] = []
    private(set) var lastError: String?
    private(set) var overlays: [MKPolyline] = []
    private var debounce: DispatchWorkItem?
    private var task: Task<Void, Never>?
    private var shownBox: (s: Double, w: Double, n: Double, e: Double)?
    private var generation = 0            // 每次 setEnabled(false)/tooFar 递增，旧任务的结果不再落地

    init(name: String) {
        self.name = name
        TunnelLayer.registry[name] = self
    }

    // MARK: 开关 / 视野

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            state = .idle
            refresh()
        } else {
            cancelWork()
            removeOverlays()
            ways = []
            shownBox = nil
            lastError = nil
            setState(.off)
        }
    }

    private func cancelWork() {
        debounce?.cancel(); debounce = nil
        task?.cancel(); task = nil
        generation &+= 1
    }

    /// 相机停稳回调：600 ms 防抖
    func viewChanged() {
        guard enabled else { return }
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceSeconds, execute: item)
    }

    /// 作废已取的范围并重取（钩子 faketunnels/tunnelrefresh、冷却到期用）
    func invalidate() {
        shownBox = nil
        viewChanged()
    }

    /// 底图切换/地图重建后把线重新挂上（overlay 对象仍在 mapView 里时不用）
    func reattachIfNeeded() {
        guard enabled, let mapView, !overlays.isEmpty else { return }
        let present = Set(mapView.overlays.compactMap { ($0 as? MKPolyline).map(ObjectIdentifier.init) })
        if let first = overlays.first, !present.contains(ObjectIdentifier(first)) {
            mapView.addOverlays(overlays, level: .aboveLabels)
        }
    }

    // MARK: 取数

    private func refresh() {
        guard enabled, let mapView else { return }
        let region = mapView.region
        let rect = mapView.visibleMapRect
        guard rect.size.width > 0, region.span.longitudeDelta > 0, mapView.bounds.width > 0 else { return }
        let lat = region.center.latitude
        let mpp = MKMetersPerMapPointAtLatitude(lat)
        let spanKm = max(rect.size.width, rect.size.height) * mpp / 1000
        // 瓦片 zoom（256 px/瓦片）：z = log2(360 · 视宽px / (256 · 经度跨度))
        let zoom = log2(360.0 * Double(mapView.bounds.width) / (256.0 * region.span.longitudeDelta))
        if spanKm > Self.maxSpanKm || zoom < Self.minZoom {
            cancelWork()
            removeOverlays()
            ways = []
            shownBox = nil
            setState(.tooFar)
            return
        }
        // bbox：视野外扩 20%
        let dLat = region.span.latitudeDelta * (0.5 + Self.expandRatio)
        let dLon = region.span.longitudeDelta * (0.5 + Self.expandRatio)
        let s = max(-85, lat - dLat), n = min(85, lat + dLat)
        let w = max(-180, region.center.longitude - dLon), e = min(180, region.center.longitude + dLon)
        if let b = shownBox, b.s <= s, b.w <= w, b.n >= n, b.e >= e, state == .ready { return }   // 已取的范围包住当前视野
        if Self.fakeCount > 0 {
            apply(Self.fakeWays(Self.fakeCount, s: s, w: w, n: n, e: e), box: (s, w, n, e))
            return
        }
        if let hit = Self.cache.lookup(s: s, w: w, n: n, e: e) {
            apply(Self.parse(hit), box: (s, w, n, e))
            return
        }
        guard Self.allowNetwork else {           // 自测副本：不出网，清线、报原因
            removeOverlays(); ways = []; shownBox = nil
            lastError = "self-test: network disabled (tunnelnet 1 to allow)"
            setState(.failed)
            return
        }
        guard !Self.inFlight else { viewChanged(); return }   // 别的图层正在请求：稍后再试
        task?.cancel()
        setState(.fetching)
        Self.inFlight = true
        let gen = generation
        task = Task { [weak self] in
            defer { Self.inFlight = false }
            do {
                let (elements, parsed) = try await Self.fetchAndParse(s: s, w: w, n: n, e: e)
                guard !Task.isCancelled, let self, self.generation == gen else { return }
                Self.cache.store(s: s, w: w, n: n, e: e, elements: elements)
                self.apply(parsed, box: (s, w, n, e))
            } catch is CancellationError {
            } catch let c as RoadNetwork.RateLimiter.HostCooling {
                guard !Task.isCancelled, let self, self.generation == gen else { return }
                self.lastError = c.localizedDescription
                let sec = max(1, Int(c.seconds.rounded(.up)))
                self.setState(.cooling(sec))
                // 冷却到期自动重试一次（最多等 125 s）
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(min(sec, 125)) + 1) { [weak self] in
                    guard let self, self.enabled, self.generation == gen, case .cooling = self.state else { return }
                    self.invalidate()
                }
            } catch {
                guard !Task.isCancelled, let self, self.generation == gen else { return }
                self.lastError = (error as? LocalizedError)?.errorDescription ?? NetworkHealth.describe(error)
                self.setState(.failed)
            }
        }
    }

    /// 取 + 解析都在非隔离上下文跑（不占主线程；城市 40 km 的 out geom 可能有几 MB）
    nonisolated static func fetchAndParse(s: Double, w: Double, n: Double, e: Double) async throws -> ([[String: Any]], [TunnelWay]) {
        let elements = try await fetch(s: s, w: w, n: n, e: e)
        return (elements, parse(elements))
    }

    /// Overpass：公路（motorway…tertiary 及其 link）与铁路（rail/light_rail/subway/narrow_gauge）的 tunnel=yes way，out geom。
    /// 镜像按顺序失败转移；RateLimiter 冷却中直接抛 HostCooling（不排队等）；所有镜像都在冷却才把冷却报给上层
    nonisolated static func fetch(s: Double, w: Double, n: Double, e: Double) async throws -> [[String: Any]] {
        let bbox = String(format: "(%.5f,%.5f,%.5f,%.5f)", s, w, n, e)
        let query = "[out:json][timeout:25];(way[\"tunnel\"=\"yes\"][\"highway\"~\"motorway|trunk|primary|secondary|tertiary\"]\(bbox);way[\"tunnel\"=\"yes\"][\"railway\"~\"rail|light_rail|subway|narrow_gauge\"]\(bbox););out geom;"
        var errors: [String] = []
        var coolingCount = 0, tried = 0
        var cooling: RoadNetwork.RateLimiter.HostCooling?
        for base in RoadNetwork.overpassEndpoints {
            try Task.checkCancellation()
            guard let url = URL(string: base) else { continue }
            tried += 1
            let host = url.host ?? base
            var req = URLRequest(url: url)
            req.timeoutInterval = 40
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = ("data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)).data(using: .utf8)
            do {
                let (data, resp) = try await RoadNetwork.RateLimiter.shared.perform(host: host, minInterval: 2.0, failIfCooling: true) {
                    try await RoadNetwork.overpassSession.data(for: req)
                }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else { errors.append("\(host) HTTP \(code)"); continue }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let elements = json["elements"] as? [[String: Any]] else {
                    errors.append("\(host) non-JSON"); continue   // 技术细节，与 railRoute 的错误串同款，不本地化
                }
                if let remark = json["remark"] as? String, !remark.isEmpty { errors.append("\(host) \(remark)"); continue }
                return elements
            } catch let c as RoadNetwork.RateLimiter.HostCooling {
                coolingCount += 1
                if cooling == nil || c.seconds < cooling!.seconds { cooling = c }
                errors.append(c.localizedDescription); continue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                errors.append("\(host) " + NetworkHealth.describe(error)); continue
            }
        }
        if let cooling, coolingCount == tried { throw cooling }
        throw RouteError.allEndpointsFailed(errors)
    }

    /// out geom 的 elements → TunnelWay（只认有 geometry 的 way）
    nonisolated static func parse(_ elements: [[String: Any]]) -> [TunnelWay] {
        var out: [TunnelWay] = []
        out.reserveCapacity(elements.count)
        for el in elements {
            guard (el["type"] as? String) == "way", let geom = el["geometry"] as? [[String: Any]] else { continue }
            let tags = el["tags"] as? [String: String] ?? [:]
            let rail = tags["railway"] != nil && tags["highway"] == nil
            let coords: [CLLocationCoordinate2D] = geom.compactMap { g in
                guard let lat = (g["lat"] as? NSNumber)?.doubleValue, let lon = (g["lon"] as? NSNumber)?.doubleValue else { return nil }
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            guard coords.count >= 2 else { continue }
            let id = (el["id"] as? NSNumber)?.int64Value ?? Int64(out.count)
            out.append(TunnelWay(id: id, rail: rail, coords: coords))
        }
        return out
    }

    /// 合成隧道：bbox 内 n 条水平直线（公路/铁路交替），不出网
    nonisolated static func fakeWays(_ n: Int, s: Double, w: Double, n north: Double, e: Double) -> [TunnelWay] {
        guard n > 0 else { return [] }
        return (0..<n).map { i in
            let t = (Double(i) + 1) / (Double(n) + 1)
            let lat = s + (north - s) * t
            let lon0 = w + (e - w) * 0.3, lon1 = w + (e - w) * 0.7
            return TunnelWay(id: Int64(-1 - i), rail: i % 2 == 1,
                             coords: [CLLocationCoordinate2D(latitude: lat, longitude: lon0),
                                      CLLocationCoordinate2D(latitude: lat, longitude: lon1)])
        }
    }

    // MARK: 画线

    private func apply(_ list: [TunnelWay], box: (s: Double, w: Double, n: Double, e: Double)) {
        ways = list
        shownBox = box
        lastError = nil
        removeOverlays()
        guard let mapView else { return }
        var lines: [MKPolyline] = []
        lines.reserveCapacity(list.count * 2)
        // 白描边靠两条同几何折线：下面一条白色更宽，上面一条彩色；虚线节奏相同
        for way in list {
            let halo = MKPolyline(coordinates: way.coords, count: way.coords.count)
            halo.title = way.rail ? "tunnel-rail-halo" : "tunnel-road-halo"
            lines.append(halo)
        }
        for way in list {
            let line = MKPolyline(coordinates: way.coords, count: way.coords.count)
            line.title = way.rail ? "tunnel-rail" : "tunnel-road"
            lines.append(line)
        }
        overlays = lines
        if !lines.isEmpty { mapView.addOverlays(lines, level: .aboveLabels) }
        setState(.ready)
    }

    private func removeOverlays() {
        if let mapView, !overlays.isEmpty { mapView.removeOverlays(overlays) }
        overlays = []
    }

    private func setState(_ s: State) {
        state = s
        onChange?()
    }

    /// rendererFor 里调用：隧道折线返回带样式的渲染器，其他返回 nil
    nonisolated static func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        guard let line = overlay as? MKPolyline, let t = line.title, t.hasPrefix("tunnel-") else { return nil }
        let r = MKPolylineRenderer(polyline: line)
        let road = NSColor(red: 0.85, green: 0.25, blue: 0.55, alpha: 0.95)    // 公路隧道：洋红
        let rail = NSColor(red: 0.20, green: 0.45, blue: 0.90, alpha: 0.95)    // 铁路隧道：蓝
        r.lineCap = .butt
        r.lineDashPattern = [10, 6]
        if t.hasSuffix("-halo") {
            r.strokeColor = NSColor.white.withAlphaComponent(0.95)
            r.lineWidth = 5
        } else {
            r.strokeColor = t.hasPrefix("tunnel-rail") ? rail : road
            r.lineWidth = 3
        }
        return r
    }

    // MARK: 文案 / 钩子

    /// 状态栏一行：「隧道层：取回 N 条 / 冷却中 / 失败原因 / 放大后显示隧道」；关着时 nil
    var statusText: String? {
        switch state {
        case .off: return nil
        case .idle: return String(localized: "隧道层：准备中", comment: "Tunnel overlay status line, before the first request")
        case .tooFar: return String(localized: "隧道层：放大后显示隧道", comment: "Tunnel overlay status line when the view spans more than 40 km / zoom < 11")
        case .fetching: return String(localized: "隧道层：正在取回…", comment: "Tunnel overlay status line while the Overpass request is in flight")
        case .ready: return String(localized: "隧道层：取回 \(ways.count) 条", comment: "Tunnel overlay status line; %lld = number of tunnel ways drawn")
        case .cooling(let sec): return String(localized: "隧道层：冷却中（还有 \(sec) s）", comment: "Tunnel overlay status line while the Overpass host is rate-limited; %lld = seconds left")
        case .failed: return String(localized: "隧道层：失败（\(lastError ?? "")）", comment: "Tunnel overlay status line after all Overpass mirrors failed; %@ = reason")
        }
    }

    /// 钩子 JSON：{"on":..,"ways":..,"state":"..","lastError":..}
    var hookJSON: String {
        let err = lastError.map { "\"" + Self.jsonSafe($0) + "\"" } ?? "null"
        return "{\"on\":\(enabled),\"ways\":\(ways.count),\"state\":\"\(state.key)\",\"lastError\":\(err)}"
    }

    /// 钩子 JSON 字符串值：反斜杠→/、引号→'、所有控制字符→空格
    nonisolated static func jsonSafe(_ s: String) -> String {
        String(s.map { c -> Character in
            if c == "\\" { return "/" }
            if c == "\"" { return "'" }
            if let v = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1, v < 0x20 { return " " }
            return c
        })
    }
}

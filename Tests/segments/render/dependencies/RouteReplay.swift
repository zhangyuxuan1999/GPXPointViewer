//
//  RouteReplay.swift
//  GPXPointViewer
//
//  合成断档考卷的录制 / 回放（HTTP 层；docs/fill-plausibility-design.md §2.2）。
//  公路引擎的每次 HTTP 都经 `RoadNetwork.transport`，这里接管它：`.record(dir)` 真发请求并把原始回复存盘；
//  `.replay(dir)` 只读盘、**不出网**。
//  文件：`<dir>/<keyHash>.json`，keyHash = 当前这处断档某个引擎的 `RouteCacheKey` 的稳定哈希（`stableHash`，进程间一致；
//  Swift 的 hashValue 每次运行都不同所以不用它）；文件内按请求哈希（方法 + URL + 请求体）存每次 HTTP 的 url/body/status/response。
//  回放另建一张「请求哈希 → 回复」的全局索引（扫全部文件）：GapRouteInputs 的键字段以后改了也不至于整份录音作废，
//  只有请求本身变了才会。找不到录音 → 抛 `Missing`（考卷记「无录音」，不算失败）。
//  录制纪律：串行、任意两次请求 ≥ 1.0 s（两个域名同一台机器，按全局算）、User-Agent `GPXPointViewer-exam/1.0`、
//  429/5xx 停 60 s 再重试一次、总请求 ≤ maxRequests（超出即抛 Budget）。无 UI 依赖（synthrunner 也编）。
//

import Foundation

enum RouteReplay {
    enum Mode: Equatable { case record(String), replay(String) }
    struct Missing: Error, CustomStringConvertible { let reqHash: String; var description: String { "no recording for request \(reqHash)" } }
    struct Budget: Error, CustomStringConvertible { var description: String { "recording request budget exhausted" } }
    struct Rejected: Error, CustomStringConvertible { let status: Int; var description: String { "HTTP \(status) twice" } }

    nonisolated(unsafe) static var mode: Mode? = nil
    /// 当前这处断档 × 引擎的录音文件名（不含扩展名）；runner 在每次 carRoute 前设置
    nonisolated(unsafe) static var currentKeyHash: String = "unkeyed"
    nonisolated(unsafe) static var maxRequests = 700
    nonisolated(unsafe) static var minInterval: TimeInterval = 1.0
    /// 统计：本进程发出的真实请求数 / 回放命中数 / 未命中数
    nonisolated(unsafe) private(set) static var requestsSent = 0
    nonisolated(unsafe) private(set) static var replayHits = 0
    nonisolated(unsafe) private(set) static var replayMisses = 0
    nonisolated(unsafe) static var log: ((String) -> Void)? = nil

    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastSent = Date.distantPast
    /// 回放索引：请求哈希 → (status, body)
    nonisolated(unsafe) private static var index: [String: (Int, Data)] = [:]
    nonisolated(unsafe) private static var indexedDir: String? = nil
    /// 录制中：每个文件当前的内容（按 keyHash）
    nonisolated(unsafe) private static var fileCache: [String: [String: Any]] = [:]

    static func resetCounters() { requestsSent = 0; replayHits = 0; replayMisses = 0 }
    /// 该录音目录里有没有这个键的文件（续跑时跳过已录的题）
    static func hasRecording(dir: String, keyHash: String) -> Bool { FileManager.default.fileExists(atPath: dir + "/" + keyHash + ".json") }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
        c.httpAdditionalHeaders = ["User-Agent": "GPXPointViewer-exam/1.0 (recording routing replies for an offline regression exam)", "Accept": "application/json"]
        return URLSession(configuration: c)
    }()

    /// FNV-1a 64 位（十六进制 16 位）
    static func fnv(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }
    /// RouteCacheKey 的稳定哈希：全部字段规范化成一个字符串再 FNV
    static func stableHash(_ k: RouteCacheKey) -> String {
        func p(_ x: RouteCacheKey.P) -> String { String(format: "%.7f,%.7f", x.lat, x.lon) }
        func opt(_ x: Double?) -> String { x.map { String(format: "%.3f", $0) } ?? "-" }
        func ctx(_ x: RouteCacheKey.Ctx?) -> String { x.map { p($0.p) + "@" + opt($0.bearing) } ?? "-" }
        func ps(_ xs: [RouteCacheKey.PS]) -> String { xs.map { "\($0.index):\(p($0.p)):\(String(format: "%.2f", $0.meters)):\(String(format: "%.1f", $0.seconds))" }.joined(separator: "|") }
        var s = "\(k.source.rawValue);\(k.economy);\(k.ia);\(k.ib);\(p(k.a));\(p(k.b));\(String(format: "%.1f", k.seconds));"
        s += "\(opt(k.bearingA));\(opt(k.bearingB));\(ctx(k.contextA));\(ctx(k.contextB));\(ctx(k.farContextA));\(ctx(k.farContextB));"
        s += k.trace.map { "\($0.index):\(p($0.p)):\(String(format: "%.1f", $0.time))" }.joined(separator: "|") + ";"
        s += "\(String(format: "%.1f", k.radius));\(ps(k.portalA));\(ps(k.portalB));\(ps(k.portalFarA));\(ps(k.portalFarB));\(k.leftHand.map { String($0) } ?? "-")"
        return fnv(s)
    }
    /// 请求体规范化：JSON 的键序在不同进程里不一样（JSONSerialization 的字典），按 sortedKeys 重排后再哈希
    static func canonicalBody(_ body: String) -> String {
        guard let d = body.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d),
              let c = try? JSONSerialization.data(withJSONObject: j, options: [.sortedKeys]), let s = String(data: c, encoding: .utf8) else { return body }
        return s
    }
    static func requestHash(method: String, url: String, body: String) -> String { fnv(method + " " + url + "\n" + canonicalBody(body)) }
    static func requestHash(_ req: URLRequest) -> String {
        let body = req.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return requestHash(method: req.httpMethod ?? "GET", url: req.url?.absoluteString ?? "", body: body)
    }

    static func perform(_ req: URLRequest) async throws -> (Data, URLResponse) {
        guard let mode else { throw Missing(reqHash: "off") }
        let rh = requestHash(req)
        let url = req.url ?? URL(string: "https://replay.invalid")!
        switch mode {
        case .replay(let dir):
            buildIndexIfNeeded(dir)
            lock.lock(); let hit = index[rh]; lock.unlock()
            guard let (status, body) = hit else { replayMisses += 1; throw Missing(reqHash: rh) }
            replayHits += 1
            let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            return (body, resp)
        case .record(let dir):
            // 已有录音（续跑）：直接用，不再出网
            buildIndexIfNeeded(dir)
            lock.lock(); let hit = index[rh]; lock.unlock()
            if let (status, body) = hit {
                replayHits += 1
                let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (body, resp)
            }
            guard requestsSent < maxRequests else { throw Budget() }
            var (data, resp) = try await send(req)
            var code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 || code >= 500 {
                log?("HTTP \(code) from \(url.host ?? "?"): pausing 60 s")
                try await Task.sleep(nanoseconds: 60_000_000_000)
                guard requestsSent < maxRequests else { throw Budget() }
                (data, resp) = try await send(req)
                code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 429 || code >= 500 { throw Rejected(status: code) }
            }
            store(dir: dir, reqHash: rh, req: req, status: code, body: data)
            return (data, resp)
        }
    }

    private static func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        // 全局串行 + ≥ minInterval
        lock.lock(); let wait = minInterval - Date().timeIntervalSince(lastSent); lock.unlock()
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        lock.lock(); lastSent = Date(); requestsSent += 1; let n = requestsSent; lock.unlock()
        let t0 = Date()
        let r = try await session.data(for: req)
        let code = (r.1 as? HTTPURLResponse)?.statusCode ?? 0
        let u = String((req.url?.absoluteString ?? "").prefix(110))
        log?(String(format: "#%d %@ %@ -> %d (%.2f s, %d B)", n, req.httpMethod ?? "GET", u, code, Date().timeIntervalSince(t0), r.0.count))
        return r
    }

    private static func buildIndexIfNeeded(_ dir: String) {
        lock.lock(); defer { lock.unlock() }
        guard indexedDir != dir else { return }
        index = [:]; fileCache = [:]
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".json") {
            guard let data = fm.contents(atPath: dir + "/" + name),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let reqs = obj["requests"] as? [String: [String: Any]] else { continue }
            for (h, r) in reqs {
                let status = (r["status"] as? NSNumber)?.intValue ?? 200
                var body = Data()
                if let j = r["response"], !(j is NSNull), let d = try? JSONSerialization.data(withJSONObject: j) { body = d }
                else if let s = r["responseText"] as? String { body = s.data(using: .utf8) ?? Data() }
                index[h] = (status, body)
                // 文件里记的键是录制进程算的；按存下的 method/url/body 重新算一遍规范化哈希（早期录音的 POST 体键序随机）
                if let m = r["method"] as? String, let u = r["url"] as? String {
                    index[requestHash(method: m, url: u, body: (r["body"] as? String) ?? "")] = (status, body)
                }
            }
            fileCache[String(name.dropLast(5))] = obj
        }
        indexedDir = dir
    }

    private static func store(dir: String, reqHash: String, req: URLRequest, status: Int, body: Data) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let key = currentKeyHash
        var obj = fileCache[key] ?? ["keyHash": key, "requests": [String: Any]()]
        var reqs = (obj["requests"] as? [String: Any]) ?? [:]
        var entry: [String: Any] = ["method": req.httpMethod ?? "GET", "url": req.url?.absoluteString ?? "", "status": status,
                                    "recordedAt": ISO8601DateFormatter().string(from: Date())]
        if let b = req.httpBody, let s = String(data: b, encoding: .utf8) { entry["body"] = s }
        if let j = try? JSONSerialization.jsonObject(with: body) { entry["response"] = j } else { entry["responseText"] = String(data: body, encoding: .utf8) ?? "" }
        reqs[reqHash] = entry
        obj["requests"] = reqs
        fileCache[key] = obj
        index[reqHash] = (status, body)
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: dir + "/" + key + ".json"), options: .atomic)
        }
    }
}

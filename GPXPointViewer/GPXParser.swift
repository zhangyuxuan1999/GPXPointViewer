//
//  GPXParser.swift
//  GPXPointViewer
//
//  两趟式多核并行 GPX 解析器（v2，为数百 MB 级文件重构）。
//
//  v1 的三个瓶颈（460MB 文件实测暴露）：逐点 append 的容量检查与增长、
//  各块解析完再合并的整体拷贝、每个点对 body 的三次独立扫描。
//
//  v2 流水线：
//    Pass 1（并行）：各块只数点（memchr 驱动的起始标签计数）——接近内存带宽速度；
//    前缀和 → 每块在成品数组中的写入偏移；
//    成品 SoA 数组按精确总数一次性分配（免零填充，无页错误浪费）；
//    Pass 2（并行）：各线程把解析结果**直写**到全局偏移处 —— 零 append、
//    零合并拷贝、零锁（写入区间互不重叠）；body 单趟前向扫描，
//    遇 <ele>/<time> 就地解析，遇闭合标签即跳出。
//
//  正确性基石（与 v1 相同）："起始标签所有权"分区——点归属于其 '<' 字节
//  所在的块，标签体允许只读越过块尾；两趟使用同一个标签判定函数，
//  计数与写入必然一致；个别缺 lat/lon 的坏点走稀有的压紧回退路径。
//

import Foundation

/// 解析产物（SoA 布局）。ele/time 缺失时以 .nan 占位。
struct ParsedTrack {
    var lat: [Double] = []
    var lon: [Double] = []
    var ele: [Double] = []
    var time: [Double] = []       // Unix 秒（UTC）
    var name: String = ""
    var chunkCount: Int = 1
    var parseSeconds: Double = 0
    var byteCount: Int = 0
    /// 各文件在合并数组中的区间（按时间多路归并用）。空 = 单一整体（StressTest/删除路径默认）
    var sortedRuns: [Range<Int>] = []
    /// 每点所属文件下标（重叠模式按文件着色/高亮用）。空 = 单一来源。
    /// 排序重排时与四个坐标数组同步搬运
    var fileID: [UInt16] = []
    var count: Int { lat.count }
}

enum GPXParseError: LocalizedError {
    case empty
    case noPoints
    var errorDescription: String? {
        switch self {
        case .empty:    return "文件为空或无法读取。"
        case .noPoints: return "文件里没有找到任何点（<trkpt>/<rtept>/<wpt>）。"
        }
    }
}

enum GPXParser {

    // MARK: - 入口

    static func parse(data: Data) throws -> ParsedTrack {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let n = data.count
        guard n > 8 else { throw GPXParseError.empty }

        let cores = ProcessInfo.processInfo.activeProcessorCount
        let chunks = max(1, min(cores, n / 65_536 + 1))
        var starts = [Int](repeating: 0, count: chunks + 1)
        for i in 0...chunks { starts[i] = i * n / chunks }

        // ---- Pass 1：并行计数 ----
        var counts = [Int](repeating: 0, count: chunks)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let rb = raw.baseAddress else { return }
            let base = rb.assumingMemoryBound(to: UInt8.self)
            counts.withUnsafeMutableBufferPointer { cbuf in
                let cb = cbuf
                DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                    cb[ci] = countChunk(base, n, starts[ci], starts[ci + 1])
                }
            }
        }
        let total = counts.reduce(0, +)
        guard total > 0 else { throw GPXParseError.noPoints }

        var offsets = [Int](repeating: 0, count: chunks + 1)
        for i in 0..<chunks { offsets[i + 1] = offsets[i] + counts[i] }

        // ---- 精确分配（免零填充） ----
        var lat = GeoCompute.uninitialized(total)
        var lon = GeoCompute.uninitialized(total)
        var ele = GeoCompute.uninitialized(total)
        var time = GeoCompute.uninitialized(total)
        var written = [Int](repeating: 0, count: chunks)

        // ---- Pass 2：并行解析，直写全局偏移 ----
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let rb = raw.baseAddress else { return }
            let base = rb.assumingMemoryBound(to: UInt8.self)
            lat.withUnsafeMutableBufferPointer { latB in
            lon.withUnsafeMutableBufferPointer { lonB in
            ele.withUnsafeMutableBufferPointer { eleB in
            time.withUnsafeMutableBufferPointer { timeB in
                written.withUnsafeMutableBufferPointer { wbuf in
                    let wb = wbuf
                    DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                        let o = offsets[ci]
                        let w = Writers(
                            lat: latB.baseAddress! + o,
                            lon: lonB.baseAddress! + o,
                            ele: eleB.baseAddress! + o,
                            time: timeB.baseAddress! + o)
                        wb[ci] = parseChunk(base, n,
                                            ownedStart: starts[ci], ownedEnd: starts[ci + 1],
                                            out: w, expected: counts[ci])
                    }
                }
            }}}}
        }

        // ---- 稀有回退：存在缺 lat/lon 的坏点时压紧数组 ----
        let totalWritten = written.reduce(0, +)
        if totalWritten != total {
            compact(&lat, offsets: offsets, written: written)
            compact(&lon, offsets: offsets, written: written)
            compact(&ele, offsets: offsets, written: written)
            compact(&time, offsets: offsets, written: written)
        }
        guard totalWritten > 0 else { throw GPXParseError.noPoints }

        var result = ParsedTrack()
        result.lat = lat
        result.lon = lon
        result.ele = ele
        result.time = time
        result.chunkCount = chunks
        result.byteCount = n
        result.parseSeconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        return result
    }

    // MARK: - 多文件统一两趟解析

    /// 全局分块（块永不跨文件）
    private struct FileChunk {
        let file: Int
        let a: Int
        let b: Int
    }

    /// Pass2 进度计数器：按块累计已解析点数，节流回调（任意线程、~10Hz）
    private final class ProgressCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var done = 0
        private var lastReport: UInt64 = 0
        private let total: Int
        private let callback: (@Sendable (Int, Int) -> Void)?
        init(total: Int, callback: (@Sendable (Int, Int) -> Void)?) {
            self.total = total
            self.callback = callback
        }
        func add(_ n: Int) {
            guard let callback else { return }
            lock.lock()
            done += n
            let now = DispatchTime.now().uptimeNanoseconds
            let fire = done == total || now - lastReport > 100_000_000
            if fire { lastReport = now }
            let d = done
            lock.unlock()
            if fire { callback(d, total) }
        }
    }

    /// 多文件统一两趟解析：全部文件的分块并行计数 → 按精确总数一次分配 →
    /// 并行直写全局偏移。相比逐文件串行解析再 append 合并：
    /// - 跨文件并行，小文件不再各自串行；
    /// - 零合并拷贝、零 realloc 链；
    /// - Pass1 给出精确总数 → 确定进度分母（progress(done, total)）。
    /// 单个文件为空/无点不再中断整体：其区间为空，下标记入 failedFiles。
    /// merged.sortedRuns = 各文件区间（供载入时按时间多路归并）。
    static func parseMany(files: [Data],
                          progress: (@Sendable (Int, Int) -> Void)? = nil)
        -> (merged: ParsedTrack, failedFiles: [Int]) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let cores = ProcessInfo.processInfo.activeProcessorCount

        // ---- 全局分块表：跨文件并行已提供占用率，块粒度放宽到 256 KB ----
        var tableBuild: [FileChunk] = []
        var fileFirstChunk = [Int](repeating: 0, count: files.count + 1)
        for (fi, data) in files.enumerated() {
            fileFirstChunk[fi] = tableBuild.count
            let n = data.count
            guard n > 8 else { continue }               // 读失败占位的空 Data：0 块
            let chunks = max(1, min(cores, n / 262_144 + 1))
            for ci in 0..<chunks {
                tableBuild.append(FileChunk(file: fi, a: ci * n / chunks, b: (ci + 1) * n / chunks))
            }
        }
        fileFirstChunk[files.count] = tableBuild.count
        let table = tableBuild
        let m = table.count
        guard m > 0 else { return (ParsedTrack(), Array(files.indices)) }

        // ---- Pass 1：并行计数 ----
        var counts = [Int](repeating: 0, count: m)
        counts.withUnsafeMutableBufferPointer { cbuf in
            let cb = cbuf
            DispatchQueue.concurrentPerform(iterations: m) { gi in
                let c = table[gi]
                // 同一 mmap Data 的并发只读 withUnsafeBytes 合法
                files[c.file].withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let rb = raw.baseAddress else { return }
                    let base = rb.assumingMemoryBound(to: UInt8.self)
                    cb[gi] = countChunk(base, files[c.file].count, c.a, c.b)
                }
            }
        }
        let total = counts.reduce(0, +)
        guard total > 0 else { return (ParsedTrack(), Array(files.indices)) }

        var offsets = [Int](repeating: 0, count: m + 1)
        for i in 0..<m { offsets[i + 1] = offsets[i] + counts[i] }

        // ---- 精确分配（免零填充），并行直写全局偏移 ----
        var lat = GeoCompute.uninitialized(total)
        var lon = GeoCompute.uninitialized(total)
        var ele = GeoCompute.uninitialized(total)
        var time = GeoCompute.uninitialized(total)
        var written = [Int](repeating: 0, count: m)
        let reporter = ProgressCounter(total: total, callback: progress)

        lat.withUnsafeMutableBufferPointer { latB in
        lon.withUnsafeMutableBufferPointer { lonB in
        ele.withUnsafeMutableBufferPointer { eleB in
        time.withUnsafeMutableBufferPointer { timeB in
            written.withUnsafeMutableBufferPointer { wbuf in
                let wb = wbuf
                DispatchQueue.concurrentPerform(iterations: m) { gi in
                    let c = table[gi]
                    files[c.file].withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                        guard let rb = raw.baseAddress else { return }
                        let base = rb.assumingMemoryBound(to: UInt8.self)
                        let o = offsets[gi]
                        let w = Writers(
                            lat: latB.baseAddress! + o,
                            lon: lonB.baseAddress! + o,
                            ele: eleB.baseAddress! + o,
                            time: timeB.baseAddress! + o)
                        wb[gi] = parseChunk(base, files[c.file].count,
                                            ownedStart: c.a, ownedEnd: c.b,
                                            out: w, expected: counts[gi])
                    }
                    reporter.add(counts[gi])
                }
            }
        }}}}

        // ---- 稀有回退：存在缺 lat/lon 的坏点时压紧数组（与单文件路径同构）----
        let totalWritten = written.reduce(0, +)
        if totalWritten != total {
            compact(&lat, offsets: offsets, written: written)
            compact(&lon, offsets: offsets, written: written)
            compact(&ele, offsets: offsets, written: written)
            compact(&time, offsets: offsets, written: written)
        }

        // ---- 各文件最终区间（压紧后按 written 前缀和，两种情形统一）----
        var failedFiles: [Int] = []
        var runs: [Range<Int>] = []
        var pos = 0
        for fi in files.indices {
            var cnt = 0
            for gi in fileFirstChunk[fi]..<fileFirstChunk[fi + 1] { cnt += written[gi] }
            if cnt > 0 { runs.append(pos..<(pos + cnt)) } else { failedFiles.append(fi) }
            pos += cnt
        }

        var result = ParsedTrack()
        result.lat = lat
        result.lon = lon
        result.ele = ele
        result.time = time
        result.sortedRuns = runs
        result.chunkCount = m
        result.byteCount = files.reduce(0) { $0 + $1.count }
        result.parseSeconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        return (result, failedFiles)
    }

    // MARK: - 多文件辅助（重叠模式：切片 / 带 fileID 的合并）

    /// 取合并数组的一个连续区间为独立 ParsedTrack（重叠模式的每文件留底）
    static func slice(_ p: ParsedTrack, range r: Range<Int>, name: String) -> ParsedTrack {
        var out = ParsedTrack()
        out.lat = Array(p.lat[r])
        out.lon = Array(p.lon[r])
        out.ele = Array(p.ele[r])
        out.time = Array(p.time[r])
        out.name = name
        out.chunkCount = 1
        return out
    }

    /// 把各文件的 ParsedTrack 拼接为显示轨迹：填 sortedRuns（每文件区间）
    /// 与 fileID（每点所属文件），供载入排序快路与按文件着色/高亮使用
    static func mergeParsed(_ parts: [ParsedTrack]) -> ParsedTrack {
        let total = parts.reduce(0) { $0 + $1.count }
        var m = ParsedTrack()
        guard total > 0 else { return m }
        m.lat = GeoCompute.uninitialized(total)
        m.lon = GeoCompute.uninitialized(total)
        m.ele = GeoCompute.uninitialized(total)
        m.time = GeoCompute.uninitialized(total)
        m.fileID = [UInt16](unsafeUninitializedCapacity: total) { _, n in n = total }
        m.chunkCount = 0
        var pos = 0
        for (fi, p) in parts.enumerated() {
            let n = p.count
            guard n > 0 else { continue }
            let dst = pos
            m.lat.withUnsafeMutableBufferPointer { b in
                p.lat.withUnsafeBufferPointer { memcpy(b.baseAddress! + dst, $0.baseAddress!, n * 8) }
            }
            m.lon.withUnsafeMutableBufferPointer { b in
                p.lon.withUnsafeBufferPointer { memcpy(b.baseAddress! + dst, $0.baseAddress!, n * 8) }
            }
            m.ele.withUnsafeMutableBufferPointer { b in
                p.ele.withUnsafeBufferPointer { memcpy(b.baseAddress! + dst, $0.baseAddress!, n * 8) }
            }
            m.time.withUnsafeMutableBufferPointer { b in
                p.time.withUnsafeBufferPointer { memcpy(b.baseAddress! + dst, $0.baseAddress!, n * 8) }
            }
            m.fileID.withUnsafeMutableBufferPointer { b in
                let base = b.baseAddress! + dst
                for i in 0..<n { base[i] = UInt16(min(fi, 65_535)) }
            }
            m.sortedRuns.append(pos..<(pos + n))
            m.chunkCount += max(1, p.chunkCount)
            m.parseSeconds += p.parseSeconds
            m.byteCount += p.byteCount
            pos += n
        }
        return m
    }

    // MARK: - Pass 1：计数

    private static func countChunk(_ base: UnsafePointer<UInt8>, _ n: Int, _ a: Int, _ b: Int) -> Int {
        var count = 0
        var i = a
        let lt = UInt8(ascii: "<")
        while let p = nextByte(base, limit: b, from: i, lt) {
            if let idx = pointTagIndex(base, n, at: p) {
                count += 1
                i = p + tagOpen[idx].count
            } else {
                i = p + 1
            }
        }
        return count
    }

    // MARK: - Pass 2：解析直写

    private struct Writers {
        let lat: UnsafeMutablePointer<Double>
        let lon: UnsafeMutablePointer<Double>
        let ele: UnsafeMutablePointer<Double>
        let time: UnsafeMutablePointer<Double>
    }

    private static func parseChunk(_ base: UnsafePointer<UInt8>, _ n: Int,
                                   ownedStart: Int, ownedEnd: Int,
                                   out: Writers, expected: Int) -> Int {
        var writtenCount = 0
        var i = ownedStart
        let ltByte = UInt8(ascii: "<")

        while writtenCount < expected {
            guard let tagPos = nextByte(base, limit: ownedEnd, from: i, ltByte) else { break }
            guard let tagIdx = pointTagIndex(base, n, at: tagPos) else { i = tagPos + 1; continue }
            let open = tagOpen[tagIdx]
            let close = tagClose[tagIdx]

            guard let gt = nextByte(base, limit: n, from: tagPos, UInt8(ascii: ">")) else { break }

            // 属性（顺序无关，容忍换行/制表缩进）
            var latVal = Double.nan
            var lonVal = Double.nan
            if let p = findAttr(base, from: tagPos + open.count, limit: gt, patLat),
               let v = parseDouble(base, limit: gt, from: p) { latVal = v.value }
            if let p = findAttr(base, from: tagPos + open.count, limit: gt, patLon),
               let v = parseDouble(base, limit: gt, from: p) { lonVal = v.value }

            var eleVal = Double.nan
            var timeVal = Double.nan
            var next = gt + 1

            let selfClosing = gt > 0 && base[gt - 1] == UInt8(ascii: "/")
            if !selfClosing {
                // body 单趟前向扫描
                var j = gt + 1
                while true {
                    guard let e = nextByte(base, limit: n, from: j, ltByte) else { next = n; break }
                    let b1 = (e + 1 < n) ? base[e + 1] : 0
                    if b1 == UInt8(ascii: "/") {
                        if e + close.count <= n, memcmp(base + e, close, close.count) == 0 {
                            next = e + close.count
                            break
                        }
                        j = e + 2                       // 别的元素的闭合标签，跳过
                    } else if b1 == UInt8(ascii: "e"), e + 5 <= n, memcmp(base + e, patEle, 5) == 0 {
                        if let v = parseDouble(base, limit: n, from: e + 5) {
                            eleVal = v.value
                            j = v.end
                        } else { j = e + 5 }
                    } else if b1 == UInt8(ascii: "t"), e + 6 <= n, memcmp(base + e, patTime, 6) == 0 {
                        let t = parseISO8601(base, limit: n, from: e + 6)
                        timeVal = t.value
                        j = t.end
                    } else {
                        j = e + 1
                    }
                }
            }

            if latVal.isFinite, lonVal.isFinite {
                out.lat[writtenCount] = latVal
                out.lon[writtenCount] = lonVal
                out.ele[writtenCount] = eleVal
                out.time[writtenCount] = timeVal
                writtenCount += 1
            }
            i = next
        }
        return writtenCount
    }

    /// 坏点压紧（极少触发）：把各块已写段搬到连续位置并裁掉尾部
    private static func compact(_ array: inout [Double], offsets: [Int], written: [Int]) {
        var dst = 0
        array.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            for ci in 0..<written.count {
                let src = offsets[ci]
                let cnt = written[ci]
                if cnt > 0, dst != src {
                    memmove(p + dst, p + src, cnt * MemoryLayout<Double>.stride)
                }
                dst += cnt
            }
        }
        array.removeLast(array.count - dst)
    }

    // MARK: - 标签与字节原语

    private static let tagOpen: [[UInt8]] = [
        Array("<trkpt".utf8), Array("<wpt".utf8), Array("<rtept".utf8),
    ]
    private static let tagClose: [[UInt8]] = [
        Array("</trkpt>".utf8), Array("</wpt>".utf8), Array("</rtept>".utf8),
    ]
    private static let patLat  = Array("lat=\"".utf8)
    private static let patLon  = Array("lon=\"".utf8)
    private static let patEle  = Array("<ele>".utf8)
    private static let patTime = Array("<time>".utf8)

    /// at 处是否为点起始标签（'<' + 标签名 + 空白边界），返回标签下标
    @inline(__always)
    private static func pointTagIndex(_ base: UnsafePointer<UInt8>, _ n: Int, at p: Int) -> Int? {
        // 快速二字符预筛：'<' 后必须是 t/w/r
        guard p + 1 < n else { return nil }
        let b1 = base[p + 1]
        guard b1 == UInt8(ascii: "t") || b1 == UInt8(ascii: "w") || b1 == UInt8(ascii: "r") else { return nil }
        for k in 0..<tagOpen.count {
            let pat = tagOpen[k]
            if p + pat.count < n,
               memcmp(base + p, pat, pat.count) == 0,
               isSpace(base[p + pat.count]) {
                return k
            }
        }
        return nil
    }

    @inline(__always)
    private static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }

    /// 在 [from, limit) 中找单字节，返回下标
    /// （memchr 返回可变指针，Swift 指针运算要求两侧同型，需显式转成 UnsafePointer）
    @inline(__always)
    private static func nextByte(_ base: UnsafePointer<UInt8>, limit: Int, from: Int, _ byte: UInt8) -> Int? {
        guard from < limit else { return nil }
        guard let p = memchr(base + from, Int32(byte), limit - from) else { return nil }
        return base.distance(to: UnsafePointer(p.assumingMemoryBound(to: UInt8.self)))
    }

    /// 在 [from, limit) 中找完整字节串，返回起始下标
    private static func find(_ base: UnsafePointer<UInt8>, limit: Int, from: Int, _ pat: [UInt8]) -> Int? {
        let m = pat.count
        guard m > 0, limit - from >= m else { return nil }
        var i = from
        let searchEnd = limit - m + 1
        while let j = nextByte(base, limit: searchEnd, from: i, pat[0]) {
            if memcmp(base + j, pat, m) == 0 { return j }
            i = j + 1
        }
        return nil
    }

    /// 找 name=" 形式的属性，要求前一字节是空白（容忍空格/换行/制表缩进），
    /// 返回属性值起始下标
    private static func findAttr(_ base: UnsafePointer<UInt8>, from: Int, limit: Int, _ pat: [UInt8]) -> Int? {
        var i = from
        while let p = find(base, limit: limit, from: i, pat) {
            if p > 0, isSpace(base[p - 1]) { return p + pat.count }
            i = p + 1
        }
        return nil
    }

    // MARK: - 手写数值解析（无分配、无 locale 依赖）

    private static let pow10Table: [Double] = (0...22).map { pow(10.0, Double($0)) }

    @inline(__always)
    private static func pow10(_ e: Int) -> Double {
        if e >= 0 { return e <= 22 ? pow10Table[e] : pow(10.0, Double(e)) }
        let a = -e
        return a <= 22 ? 1.0 / pow10Table[a] : pow(10.0, Double(e))
    }

    /// 解析 [from, limit) 起始处的十进制浮点数
    private static func parseDouble(_ base: UnsafePointer<UInt8>, limit: Int, from: Int) -> (value: Double, end: Int)? {
        var i = from
        while i < limit, isSpace(base[i]) { i += 1 }
        guard i < limit else { return nil }

        var negative = false
        if base[i] == UInt8(ascii: "-") { negative = true; i += 1 }
        else if base[i] == UInt8(ascii: "+") { i += 1 }

        var mantissa: UInt64 = 0
        var digits = 0
        var extraExp = 0
        var sawDigit = false

        while i < limit, base[i] >= 48, base[i] <= 57 {
            sawDigit = true
            if digits < 18 { mantissa = mantissa * 10 + UInt64(base[i] - 48); digits += 1 }
            else { extraExp += 1 }
            i += 1
        }
        var fracDigits = 0
        if i < limit, base[i] == UInt8(ascii: ".") {
            i += 1
            while i < limit, base[i] >= 48, base[i] <= 57 {
                sawDigit = true
                if digits < 18 { mantissa = mantissa * 10 + UInt64(base[i] - 48); digits += 1; fracDigits += 1 }
                i += 1
            }
        }
        guard sawDigit else { return nil }

        var expVal = 0
        if i < limit, base[i] == UInt8(ascii: "e") || base[i] == UInt8(ascii: "E") {
            var j = i + 1
            var expNeg = false
            if j < limit, base[j] == UInt8(ascii: "-") { expNeg = true; j += 1 }
            else if j < limit, base[j] == UInt8(ascii: "+") { j += 1 }
            var e = 0
            var sawExpDigit = false
            while j < limit, base[j] >= 48, base[j] <= 57 {
                sawExpDigit = true
                e = min(e * 10 + Int(base[j] - 48), 400)
                j += 1
            }
            if sawExpDigit { expVal = expNeg ? -e : e; i = j }
        }

        let totalExp = expVal + extraExp - fracDigits
        var value = Double(mantissa) * pow10(totalExp)
        if negative { value = -value }
        return (value, i)
    }

    /// 解析 ISO8601 时间戳（如 2026-03-26T06:06:00.364Z）。
    /// 返回 (Unix 秒或 .nan, 扫描终点下标)。
    private static func parseISO8601(_ base: UnsafePointer<UInt8>, limit: Int, from: Int) -> (value: Double, end: Int) {
        var i = from
        while i < limit, isSpace(base[i]) { i += 1 }

        @inline(__always)
        func readInt(_ len: Int) -> Int? {
            guard i + len <= limit else { return nil }
            var v = 0
            for k in 0..<len {
                let b = base[i + k]
                guard b >= 48, b <= 57 else { return nil }
                v = v * 10 + Int(b - 48)
            }
            i += len
            return v
        }
        @inline(__always)
        func expect(_ ch: UInt8) -> Bool {
            guard i < limit, base[i] == ch else { return false }
            i += 1
            return true
        }

        guard let y = readInt(4), expect(UInt8(ascii: "-")),
              let mo = readInt(2), expect(UInt8(ascii: "-")),
              let d = readInt(2), expect(UInt8(ascii: "T")),
              let h = readInt(2), expect(UInt8(ascii: ":")),
              let mi = readInt(2), expect(UInt8(ascii: ":")),
              let s = readInt(2)
        else { return (.nan, i) }

        var frac = 0.0
        if i < limit, base[i] == UInt8(ascii: ".") {
            i += 1
            var scale = 0.1
            while i < limit, base[i] >= 48, base[i] <= 57 {
                frac += Double(base[i] - 48) * scale
                scale *= 0.1
                i += 1
            }
        }
        // 时区：Z / ±hh:mm / 缺省按 UTC
        var tzOffset = 0
        if i < limit {
            let b = base[i]
            if b == UInt8(ascii: "+") || b == UInt8(ascii: "-") {
                let sign = (b == UInt8(ascii: "-")) ? -1 : 1
                i += 1
                if let th = readInt(2) {
                    var tm = 0
                    if i < limit, base[i] == UInt8(ascii: ":") { i += 1; tm = readInt(2) ?? 0 }
                    tzOffset = sign * (th * 3600 + tm * 60)
                }
            } else if b == UInt8(ascii: "Z") {
                i += 1
            }
        }

        // Howard Hinnant days-from-civil：公历日期 -> 距 1970-01-01 天数
        var yy = y
        if mo <= 2 { yy -= 1 }
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468

        let value = Double(days) * 86400.0 + Double(h * 3600 + mi * 60 + s) + frac - Double(tzOffset)
        return (value, i)
    }
}

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
    /// Source path identity, independent of fileID. Empty means one implicit segment.
    var segmentID: [UInt32] = []
    /// GPX 根元素的 creator（"Garmin Explore App" / "StepOfMyWorld" …）；CSV 为空串。采样画像据此分辨专用记录仪与手机
    var creator: String = ""
    /// CSV 定位精度列（accuracy，米）中 >0 部分的中位数；GPX 或无此列时为 nil
    var accuracyMedian: Double? = nil
    /// parseMany 的逐文件来源/精度（按传入文件下标，含失败文件）；切每文件留底时用它，不继承整批的合并值
    var perFileCreator: [String] = []
    var perFileAccuracy: [Double?] = []
    var count: Int { lat.count }
}

enum GPXParseError: LocalizedError {
    case empty
    case noPoints
    case fwdbInvalid
    var errorDescription: String? {
        switch self {
        case .empty:
            return String(localized: "文件为空或无法读取。",
                          comment: "Error message when opening a track file: the file is empty or cannot be read")
        case .noPoints:
            return String(localized: "文件里没有找到任何点（<trkpt>/<rtept>/<wpt>）。",
                          comment: "Error message when opening a track file: no points found; <trkpt>/<rtept>/<wpt> are GPX element names, keep them verbatim")
        case .fwdbInvalid:
            return String(localized: "无法解析迷雾存档（未找到有效的 Sync 区块文件）。",
                          comment: "Error message when opening a Fog of World archive (.fwdb): it could not be parsed; 'Sync' is a folder name inside the archive, keep it verbatim")
        }
    }
}

enum GPXParser {
    /// 海拔合法范围之外视为"无海拔"（Garmin 无定高时写 9.999999562023526e+24 哨兵；死海 -430m、珠峰 8849m）
    @inline(__always) static func sanitizeEle(_ e: Double) -> Double {
        (e > -12_000 && e < 100_000) ? e : .nan
    }


    // MARK: - 入口

    static func parse(data: Data) throws -> ParsedTrack {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let n = data.count
        guard n > 8 else { throw GPXParseError.empty }

        let cores = ProcessInfo.processInfo.activeProcessorCount
        let chunks = max(1, min(cores, n / 65_536 + 1))
        var starts = [Int](repeating: 0, count: chunks + 1)
        for i in 0...chunks { starts[i] = i * n / chunks }

        // ---- 格式嗅探：CSV 与 GPX 共用同一套两趟并行架构，块级分派 ----
        let csv = csvLayout(data: data)
        let structure = csv == nil ? xmlStructure(data: data) : XMLStructure()

        // ---- Pass 1：并行计数 ----
        var counts = [Int](repeating: 0, count: chunks)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let rb = raw.baseAddress else { return }
            let base = rb.assumingMemoryBound(to: UInt8.self)
            counts.withUnsafeMutableBufferPointer { cbuf in
                let cb = cbuf
                DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                    cb[ci] = csv != nil
                        ? countChunkCSV(base, n, starts[ci], starts[ci + 1])
                        : countChunk(base, n, starts[ci], starts[ci + 1], structure: structure)
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
        var segmentID = [UInt32](repeating: 0, count: total)
        var written = [Int](repeating: 0, count: chunks)

        // ---- Pass 2：并行解析，直写全局偏移 ----
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let rb = raw.baseAddress else { return }
            let base = rb.assumingMemoryBound(to: UInt8.self)
            lat.withUnsafeMutableBufferPointer { latB in
            lon.withUnsafeMutableBufferPointer { lonB in
            ele.withUnsafeMutableBufferPointer { eleB in
            time.withUnsafeMutableBufferPointer { timeB in
            segmentID.withUnsafeMutableBufferPointer { segmentB in
                written.withUnsafeMutableBufferPointer { wbuf in
                    let wb = wbuf
                    DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                        let o = offsets[ci]
                        let w = Writers(
                            lat: latB.baseAddress! + o,
                            lon: lonB.baseAddress! + o,
                            ele: eleB.baseAddress! + o,
                            time: timeB.baseAddress! + o, segment: segmentB.baseAddress! + o)
                        wb[ci] = csv != nil
                            ? parseChunkCSV(base, n,
                                            ownedStart: starts[ci], ownedEnd: starts[ci + 1],
                                            layout: csv!, out: w, expected: counts[ci])
                            : parseChunk(base, n,
                                         ownedStart: starts[ci], ownedEnd: starts[ci + 1],
                                         out: w, expected: counts[ci], structure: structure)
                    }
                }
            }}}}}
        }

        // ---- 稀有回退：存在缺 lat/lon 的坏点时压紧数组 ----
        let totalWritten = written.reduce(0, +)
        if totalWritten != total {
            compact(&lat, offsets: offsets, written: written)
            compact(&lon, offsets: offsets, written: written)
            compact(&ele, offsets: offsets, written: written)
            compact(&time, offsets: offsets, written: written)
            compact(&segmentID, offsets: offsets, written: written)
        }
        guard totalWritten > 0 else { throw GPXParseError.noPoints }

        var result = ParsedTrack()
        result.lat = lat
        result.lon = lon
        result.ele = ele
        result.time = time
        result.segmentID = csv == nil ? segmentID : []
        result.chunkCount = chunks
        result.byteCount = n
        if let csv {
            result.accuracyMedian = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Double? in
                guard let rb = raw.baseAddress else { return nil }
                return csvAccuracyMedian(rb.assumingMemoryBound(to: UInt8.self), n, layout: csv)
            }
        } else {
            result.creator = gpxCreator(data: data)
        }
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
        // 逐文件格式嗅探（CSV 布局；nil = GPX/XML），块级分派两趟共用
        var tableBuild: [FileChunk] = []
        var fileFirstChunk = [Int](repeating: 0, count: files.count + 1)
        var csvOf = [CSVLayout?](repeating: nil, count: files.count)
        for (fi, data) in files.enumerated() {
            fileFirstChunk[fi] = tableBuild.count
            let n = data.count
            guard n > 8 else { continue }               // 读失败占位的空 Data：0 块
            csvOf[fi] = csvLayout(data: data)
            let chunks = max(1, min(cores, n / 262_144 + 1))
            for ci in 0..<chunks {
                tableBuild.append(FileChunk(file: fi, a: ci * n / chunks, b: (ci + 1) * n / chunks))
            }
        }
        fileFirstChunk[files.count] = tableBuild.count
        let structures = files.enumerated().map { fi, data in
            csvOf[fi] == nil ? xmlStructure(data: data) : XMLStructure()
        }
        var segmentBases = [UInt32](repeating: 0, count: files.count)
        var nextBase: UInt32 = 0
        for fi in files.indices {
            segmentBases[fi] = nextBase
            nextBase += max(1, structures[fi].segmentCount)
        }
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
                    cb[gi] = csvOf[c.file] != nil
                        ? countChunkCSV(base, files[c.file].count, c.a, c.b)
                        : countChunk(base, files[c.file].count, c.a, c.b, structure: structures[c.file])
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
        var segmentID = [UInt32](repeating: 0, count: total)
        var written = [Int](repeating: 0, count: m)
        let reporter = ProgressCounter(total: total, callback: progress)

        lat.withUnsafeMutableBufferPointer { latB in
        lon.withUnsafeMutableBufferPointer { lonB in
        ele.withUnsafeMutableBufferPointer { eleB in
        time.withUnsafeMutableBufferPointer { timeB in
        segmentID.withUnsafeMutableBufferPointer { segmentB in
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
                            time: timeB.baseAddress! + o, segment: segmentB.baseAddress! + o, segmentBase: segmentBases[c.file])
                        wb[gi] = csvOf[c.file] != nil
                            ? parseChunkCSV(base, files[c.file].count,
                                            ownedStart: c.a, ownedEnd: c.b,
                                            layout: csvOf[c.file]!,
                                            out: w, expected: counts[gi])
                            : parseChunk(base, files[c.file].count,
                                         ownedStart: c.a, ownedEnd: c.b,
                                         out: w, expected: counts[gi], structure: structures[c.file])
                    }
                    reporter.add(counts[gi])
                }
            }
        }}}}}

        // ---- 稀有回退：存在缺 lat/lon 的坏点时压紧数组（与单文件路径同构）----
        let totalWritten = written.reduce(0, +)
        if totalWritten != total {
            compact(&lat, offsets: offsets, written: written)
            compact(&lon, offsets: offsets, written: written)
            compact(&ele, offsets: offsets, written: written)
            compact(&time, offsets: offsets, written: written)
            compact(&segmentID, offsets: offsets, written: written)
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
        result.segmentID = segmentID
        result.sortedRuns = runs
        result.chunkCount = m
        result.byteCount = files.reduce(0) { $0 + $1.count }
        // 来源与精度（采样画像用）：逐文件各算各的；整批的合并值 = 第一个非空（单文件载入时就是它自己）
        result.perFileCreator = files.map { csvLayout(data: $0) == nil ? gpxCreator(data: $0) : "" }
        result.perFileAccuracy = files.map { d -> Double? in
            guard let l = csvLayout(data: d), l.colAcc >= 0 else { return nil }
            return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Double? in
                guard let rb = raw.baseAddress else { return nil }
                return csvAccuracyMedian(rb.assumingMemoryBound(to: UInt8.self), d.count, layout: l)
            }
        }
        result.creator = result.perFileCreator.first { !$0.isEmpty } ?? ""
        result.accuracyMedian = result.perFileAccuracy.first { $0 != nil } ?? nil
        result.parseSeconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        return (result, failedFiles)
    }

    // MARK: - 轻量采样扫描（Quick Look 缩略图 / 超大文件预览降级）

    /// 不做完整解析：按文件等距分块，每块只取第一个点的 lat/lon
    /// （GPX 点按记录顺序排列，分块采样天然保持轨迹走向），
    /// XML容器先扫描一次以识别显式段并排除伪标签；只为采样点分配坐标，
    /// 保持预览内存有界（段边界表随源段数增长）。
    struct SampleScan {
        var lat: [Double] = []
        var lon: [Double] = []
        var segmentID: [UInt32] = []
        var totalPointCount: Int = 0
        var firstTime: Double = .nan
        var lastTime: Double = .nan
        var count: Int { lat.count }
    }

    /// Count genuine point tags during the shared lexical structure scan.
    static func countPoints(data: Data) -> Int {
        guard data.count > 8 else { return 0 }
        return xmlStructure(data: data).pointCount
    }

    static func sampleScan(data: Data, targetPoints: Int,
                           includeTimes: Bool = true) -> SampleScan {
        var out = SampleScan()
        let n = data.count
        guard n > 8 else { return out }
        let structure = xmlStructure(data: data)
        out.totalPointCount = structure.pointCount
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let rb = raw.baseAddress else { return }
            let base = rb.assumingMemoryBound(to: UInt8.self)
            let chunks = max(1, min(targetPoints, n / 256))
            out.lat.reserveCapacity(chunks)
            out.lon.reserveCapacity(chunks)
            let lt = UInt8(ascii: "<")
            var tMin = Double.infinity, tMax = -Double.infinity
            for ci in 0..<chunks {
                let a = ci * n / chunks
                let b = (ci + 1) * n / chunks
                // 块内找首个点标签（跨块继续找直到下一块开头，防块小于点间距漏采）
                var i = a
                while let p = nextByte(base, limit: min(b + 4096, n), from: i, lt) {
                    if !structure.isExcluded(p), let idx = pointTagIndex(base, n, at: p) {
                        let open = tagOpen[idx]
                        guard let gt = xmlTagEnd(base, n, from: p) else { break }
                        if let lav = coordinateAttribute(base, from: p + open.count, limit: gt, name: "lat"),
                           let lov = coordinateAttribute(base, from: p + open.count, limit: gt, name: "lon") {
                            out.lat.append(lav.value)
                            out.lon.append(lov.value)
                            out.segmentID.append(structure.segment(at: p))
                        }
                        // 顺带在同一窗口采一个时间戳：备份文件时间常乱序，
                        // 只扫头尾会拿到错误的日期范围——按块采样取 min/max
                        if includeTimes,
                           let tp = findRealTime(base, limit: min(p + 4096, n),
                                                 from: p, structure: structure) {
                            let v = parseISO8601(base, limit: n, from: tp + patTime.count).value
                            if v.isFinite {
                                if v < tMin { tMin = v }
                                if v > tMax { tMax = v }
                            }
                        }
                        break
                    }
                    i = p + 1
                }
            }
            guard includeTimes else { return }
            // 头尾窗口补充（首末点常是极值，采样漏掉时兜底）
            if let t0 = findRealTime(base, limit: min(n, 262_144), from: 0, structure: structure) {
                let v = parseISO8601(base, limit: n, from: t0 + patTime.count).value
                if v.isFinite {
                    if v < tMin { tMin = v }
                    if v > tMax { tMax = v }
                }
            }
            let tailStart = max(0, n - 262_144)
            var lastPos: Int? = nil
            var j = tailStart
            while let p = findRealTime(base, limit: n, from: j, structure: structure) {
                lastPos = p
                j = p + patTime.count
            }
            if let p = lastPos {
                let v = parseISO8601(base, limit: n, from: p + patTime.count).value
                if v.isFinite {
                    if v < tMin { tMin = v }
                    if v > tMax { tMax = v }
                }
            }
            if tMin.isFinite { out.firstTime = tMin }
            if tMax.isFinite { out.lastTime = tMax }
        }
        return out
    }

    // MARK: - 多文件辅助（重叠模式：切片 / 带 fileID 的合并）

    /// 取合并数组的一个连续区间为独立 ParsedTrack（重叠模式的每文件留底）
    static func slice(_ p: ParsedTrack, range r: Range<Int>, name: String) -> ParsedTrack {
        var out = ParsedTrack()
        out.lat = Array(p.lat[r])
        out.lon = Array(p.lon[r])
        out.ele = Array(p.ele[r])
        out.time = Array(p.time[r])
        if !p.segmentID.isEmpty { out.segmentID = Array(p.segmentID[r]) }
        if !p.fileID.isEmpty { out.fileID = Array(p.fileID[r]) }
        out.name = name
        out.chunkCount = 1
        out.creator = p.creator
        out.accuracyMedian = p.accuracyMedian
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
        m.segmentID = [UInt32](repeating: 0, count: total)
        var nextSegment: UInt32 = 0
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
            precondition(p.segmentID.isEmpty || p.segmentID.count == n)
            var remap: [UInt32: UInt32] = [:]
            for i in 0..<n {
                let old = p.segmentID.isEmpty ? 0 : p.segmentID[i]
                if remap[old] == nil { remap[old] = nextSegment; nextSegment += 1 }
                m.segmentID[pos + i] = remap[old]!
            }
            m.sortedRuns.append(pos..<(pos + n))
            m.chunkCount += max(1, p.chunkCount)
            m.parseSeconds += p.parseSeconds
            m.byteCount += p.byteCount
            if m.creator.isEmpty { m.creator = p.creator }
            if m.accuracyMedian == nil { m.accuracyMedian = p.accuracyMedian }
            pos += n
        }
        return m
    }

    // MARK: - Pass 1：计数

    // MARK: - CSV（足迹类导出：dataTime,locType,longitude,latitude,…,altitude）

    /// CSV 列布局（-1 = 缺列）。按表头列名识别；无表头的纯数字文件按
    /// 足迹 app 固定布局（0=时间 2=经度 3=纬度 10=海拔）
    struct CSVLayout {
        var colTime = -1
        var colLon = -1
        var colLat = -1
        var colEle = -1
        var colAcc = -1                 // 定位精度（米）；只用于采样画像，不逐点保存
        var maxCol: Int { max(colTime, max(colLon, max(colLat, colEle))) }
    }

    /// 内容嗅探：首行含 '<' 即 XML/GPX（返回 nil）；逗号 ≥2 且能定位
    /// 经纬列才认作 CSV。表头大小写不敏感，容忍 BOM/引号/\r
    static func csvLayout(data: Data) -> CSVLayout? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> CSVLayout? in
            guard let rb = raw.baseAddress, raw.count > 8 else { return nil }
            return csvLayout(rb.assumingMemoryBound(to: UInt8.self), raw.count)
        }
    }

    /// UTF-8 BOM（EF BB BF）长度：Excel/记事本导出常见，嗅探与行判定都要跳过
    @inline(__always)
    private static func bomLen(_ base: UnsafePointer<UInt8>, _ n: Int) -> Int {
        n >= 3 && base[0] == 0xEF && base[1] == 0xBB && base[2] == 0xBF ? 3 : 0
    }

    private static func csvLayout(_ base: UnsafePointer<UInt8>, _ n: Int) -> CSVLayout? {
        let bom = bomLen(base, n)
        let lim = min(n, 4096)
        var end = bom
        var commas = 0
        while end < lim, base[end] != 0x0A {
            if base[end] == UInt8(ascii: "<") { return nil }
            if base[end] == UInt8(ascii: ",") { commas += 1 }
            end += 1
        }
        guard commas >= 2 else { return nil }
        // 表头解析：小写化 + 去引号/空白/BOM
        let header = String(decoding: UnsafeBufferPointer(start: base + bom, count: end - bom),
                            as: UTF8.self)
        let fields = header.lowercased().split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\"'\u{FEFF}")) }
        var l = CSVLayout()
        for (i, f) in fields.enumerated() {
            switch f {
            case "datatime", "time", "timestamp", "date":
                if l.colTime < 0 { l.colTime = i }
            case "longitude", "lon", "lng":
                if l.colLon < 0 { l.colLon = i }
            case "latitude", "lat":
                if l.colLat < 0 { l.colLat = i }
            case "altitude", "alt", "ele", "elevation":
                if l.colEle < 0 { l.colEle = i }
            case "accuracy", "hacc", "horizontalaccuracy", "horizontal_accuracy":
                if l.colAcc < 0 { l.colAcc = i }
            default: break
            }
        }
        if l.colLat >= 0, l.colLon >= 0 { return l }
        // 无表头：首字符（跳过 BOM）是数字/负号则按足迹布局
        let c0 = base[bom]
        if (c0 >= UInt8(ascii: "0") && c0 <= UInt8(ascii: "9")) || c0 == UInt8(ascii: "-") {
            return CSVLayout(colTime: 0, colLon: 2, colLat: 3, colEle: 10, colAcc: 5)
        }
        return nil
    }

    /// GPX 根元素的 creator 属性（只扫前 4 KB）；找不到为空串
    static func gpxCreator(data: Data) -> String {
        let head = data.prefix(4096)
        let s = String(decoding: head, as: UTF8.self)      // 截断处的半个多字节字符只变成 U+FFFD，不整体回退
        guard let r = s.range(of: "creator=\"") else { return "" }
        let rest = s[r.upperBound...]
        guard let q = rest.firstIndex(of: "\"") else { return "" }
        return String(rest[..<q]).trimmingCharacters(in: .whitespaces)
    }

    /// CSV 精度列的中位数（均匀抽 ≤4000 行，只取 0 < acc < 1000 的值；样本 <20 个返回 nil）。
    /// 一生足迹的 accuracy 有一半是 0（未知），所以只看非零部分
    private static func csvAccuracyMedian(_ base: UnsafePointer<UInt8>, _ n: Int, layout: CSVLayout) -> Double? {
        guard layout.colAcc >= 0, n > 64 else { return nil }
        let bom = bomLen(base, n)
        let comma = UInt8(ascii: ","), quote = UInt8(ascii: "\"")
        var vals: [Double] = []
        let samples = 4000
        var lastLine = -1
        for s in 0..<samples {
            let pos = bom + Int(Double(n - bom) * Double(s) / Double(samples))
            let i = csvLineStart(base, n, max(pos, 1))
            guard i < n, i != lastLine else { continue }
            lastLine = i
            guard csvIsDataStart(base, i, n) else { continue }
            let lineEnd = nextByte(base, limit: n, from: i, 0x0A) ?? n
            var col = 0, p = i
            while p < lineEnd, col < layout.colAcc {
                guard let cm = nextByte(base, limit: lineEnd, from: p, comma) else { p = lineEnd; break }
                p = cm + 1; col += 1
            }
            guard p < lineEnd, col == layout.colAcc else { continue }
            var fp = p
            if base[fp] == quote { fp += 1 }
            if let v = parseDouble(base, limit: lineEnd, from: fp)?.value, v > 0, v < 1000 { vals.append(v) }
        }
        guard vals.count >= 20 else { return nil }
        vals.sort()
        return vals[vals.count / 2]
    }

    /// 行归属：起始字节在 [a,b) 的行属于本块。a>0 时从 a-1 起越过
    /// 上一块的残行（a-1 恰为换行时起点就是 a）
    @inline(__always)
    private static func csvLineStart(_ base: UnsafePointer<UInt8>, _ n: Int, _ a: Int) -> Int {
        if a == 0 { return 0 }
        var i = a - 1
        while i < n, base[i] != 0x0A { i += 1 }
        return i + 1
    }

    /// 数据行判定：数字/符号开头；引号包裹的数字（"39.9"）也算
    @inline(__always)
    private static func csvIsDataStart(_ base: UnsafePointer<UInt8>, _ i: Int, _ n: Int) -> Bool {
        var c = base[i]
        if c == UInt8(ascii: "\""), i + 1 < n { c = base[i + 1] }
        return (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
            || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") || c == UInt8(ascii: ".")
    }

    /// Pass 1（CSV）：数以数字开头的行（表头/空行天然跳过；首块跳过 BOM）
    private static func countChunkCSV(_ base: UnsafePointer<UInt8>, _ n: Int, _ a: Int, _ b: Int) -> Int {
        var i = csvLineStart(base, n, a)
        if a == 0 { i += bomLen(base, n) }
        var count = 0
        while i < b {
            if csvIsDataStart(base, i, n) { count += 1 }
            guard let e = nextByte(base, limit: n, from: i, 0x0A) else { break }
            i = e + 1
        }
        return count
    }

    /// Pass 2（CSV）：逐行按列布局取时间/经/纬/海拔。经纬无效的行跳过
    ///（written < expected 走压紧回退，与 GPX 路径同构）；
    /// 毫秒时间戳（>4e10）自动折算成秒
    private static func parseChunkCSV(_ base: UnsafePointer<UInt8>, _ n: Int,
                                      ownedStart a: Int, ownedEnd b: Int,
                                      layout: CSVLayout,
                                      out: Writers, expected: Int) -> Int {
        var w = 0
        var i = csvLineStart(base, n, a)
        if a == 0 { i += bomLen(base, n) }
        let comma = UInt8(ascii: ",")
        let quote = UInt8(ascii: "\"")
        let maxCol = layout.maxCol
        while i < b, w < expected {
            let lineEnd = nextByte(base, limit: n, from: i, 0x0A) ?? n
            if csvIsDataStart(base, i, n) {
                var lat = Double.nan, lon = Double.nan
                var ele = Double.nan, t = Double.nan
                var col = 0
                var p = i
                while p < lineEnd, col <= maxCol {
                    var fp = p                              // 引号字段："39.9"
                    if base[fp] == quote { fp += 1 }
                    if col == layout.colLat {
                        lat = parseDouble(base, limit: lineEnd, from: fp)?.value ?? .nan
                    } else if col == layout.colLon {
                        lon = parseDouble(base, limit: lineEnd, from: fp)?.value ?? .nan
                    } else if col == layout.colTime {
                        // 数字 epoch 为主；形如 2023-07-22T… 的日期串走 ISO 解析
                        if let v = parseDouble(base, limit: lineEnd, from: fp) {
                            if v.value < 10000, v.end < lineEnd,
                               base[v.end] == UInt8(ascii: "-") {
                                t = parseISO8601(base, limit: lineEnd, from: fp).value
                            } else {
                                t = v.value
                            }
                        }
                    } else if col == layout.colEle {
                        ele = GPXParser.sanitizeEle(parseDouble(base, limit: lineEnd, from: fp)?.value ?? .nan)
                    }
                    guard let cm = nextByte(base, limit: lineEnd, from: p, comma) else { break }
                    p = cm + 1
                    col += 1
                }
                if t > 4e10 { t /= 1000 }                    // 毫秒时间戳
                if !(abs(t) < 1e11) { t = .nan }             // 荒谬时间当缺失
                if lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 {
                    out.lat[w] = lat
                    out.lon[w] = lon
                    out.ele[w] = ele
                    out.time[w] = t
                    out.segment?[w] = out.segmentBase
                    w += 1
                }
            }
            i = lineEnd + 1
        }
        return w
    }

    private static func countChunk(_ base: UnsafePointer<UInt8>, _ n: Int, _ a: Int, _ b: Int, structure: XMLStructure) -> Int {
        var count = 0
        var i = a
        let lt = UInt8(ascii: "<")
        while let p = nextByte(base, limit: b, from: i, lt) {
            if !structure.isExcluded(p), let idx = pointTagIndex(base, n, at: p) {
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
        var segment: UnsafeMutablePointer<UInt32>? = nil
        var segmentBase: UInt32 = 0
    }

    private static func parseChunk(_ base: UnsafePointer<UInt8>, _ n: Int,
                                   ownedStart: Int, ownedEnd: Int,
                                   out: Writers, expected: Int, structure: XMLStructure) -> Int {
        var writtenCount = 0
        var boundaryCursor = 0
        var boundaryEnd = structure.boundaries.count
        while boundaryCursor < boundaryEnd {
            let mid = (boundaryCursor + boundaryEnd) / 2
            if structure.boundaries[mid].offset <= ownedStart { boundaryCursor = mid + 1 }
            else { boundaryEnd = mid }
        }
        boundaryCursor -= 1
        var i = ownedStart
        let ltByte = UInt8(ascii: "<")

        while writtenCount < expected {
            guard let tagPos = nextByte(base, limit: ownedEnd, from: i, ltByte) else { break }
            guard !structure.isExcluded(tagPos), let tagIdx = pointTagIndex(base, n, at: tagPos) else { i = tagPos + 1; continue }
            let open = tagOpen[tagIdx]
            let close = tagClose[tagIdx]

            guard let gt = xmlTagEnd(base, n, from: tagPos) else { break }

            // 属性（顺序无关，容忍换行/制表缩进）
            var latVal = Double.nan
            var lonVal = Double.nan
            if let v = coordinateAttribute(base, from: tagPos + open.count, limit: gt, name: "lat") { latVal = v.value }
            if let v = coordinateAttribute(base, from: tagPos + open.count, limit: gt, name: "lon") { lonVal = v.value }

            var eleVal = Double.nan
            var timeVal = Double.nan
            var next = gt + 1

            let selfClosing = gt > 0 && base[gt - 1] == UInt8(ascii: "/")
            if !selfClosing {
                // body 单趟前向扫描
                var j = gt + 1
                while true {
                    guard let e = nextByte(base, limit: n, from: j, ltByte) else { next = n; break }
                    if structure.isExcluded(e) { j = structure.excludedEnd(at: e); continue }
                    let b1 = (e + 1 < n) ? base[e + 1] : 0
                    if b1 == UInt8(ascii: "/") {
                        if e + close.count <= n, memcmp(base + e, close, close.count) == 0 {
                            next = e + close.count
                            break
                        }
                        j = e + 2                       // 别的元素的闭合标签，跳过
                    } else if b1 == UInt8(ascii: "e"), e + 5 <= n, memcmp(base + e, patEle, 5) == 0 {
                        if let v = parseDouble(base, limit: n, from: e + 5) {
                            eleVal = GPXParser.sanitizeEle(v.value)
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

            if latVal.isFinite, lonVal.isFinite, abs(latVal) <= 90, abs(lonVal) <= 180 {
                out.lat[writtenCount] = latVal
                out.lon[writtenCount] = lonVal
                out.ele[writtenCount] = eleVal
                out.time[writtenCount] = timeVal
                while boundaryCursor + 1 < structure.boundaries.count && structure.boundaries[boundaryCursor + 1].offset <= tagPos { boundaryCursor += 1 }
                let localSegment = boundaryCursor >= 0 ? structure.boundaries[boundaryCursor].id : 0
                out.segment?[writtenCount] = out.segmentBase + localSegment
                writtenCount += 1
            }
            i = next
        }
        return writtenCount
    }

    /// 坏点压紧（极少触发）：把各块已写段搬到连续位置并裁掉尾部
    private static func compact<T>(_ array: inout [T], offsets: [Int], written: [Int]) {
        var dst = 0
        array.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            for ci in 0..<written.count {
                let src = offsets[ci]
                let cnt = written[ci]
                if cnt > 0, dst != src {
                    memmove(p + dst, p + src, cnt * MemoryLayout<T>.stride)
                }
                dst += cnt
            }
        }
        array.removeLast(array.count - dst)
    }

    // MARK: - 标签与字节原语

    /// A single lexical pass records only source-container transitions and exceptional
    /// excluded ranges. Chunks can start inside any open segment without rescanning XML.
    private struct XMLStructure {
        var boundaries: [(offset: Int, id: UInt32)] = []
        var excluded: [Range<Int>] = []
        var segmentCount: UInt32 = 0
        var pointCount: Int = 0
        func segment(at offset: Int) -> UInt32 {
            var lo = 0, hi = boundaries.count
            while lo < hi {
                let m = (lo + hi) / 2
                if boundaries[m].offset <= offset { lo = m + 1 } else { hi = m }
            }
            return lo > 0 ? boundaries[lo - 1].id : 0
        }
        func excludedEnd(at offset: Int) -> Int {
            var lo = 0, hi = excluded.count
            while lo < hi {
                let m = (lo + hi) / 2
                if excluded[m].lowerBound <= offset { lo = m + 1 } else { hi = m }
            }
            return lo > 0 && excluded[lo - 1].contains(offset) ? excluded[lo - 1].upperBound : offset + 1
        }
        func isExcluded(_ offset: Int) -> Bool {
            var lo = 0, hi = excluded.count
            while lo < hi {
                let m = (lo + hi) / 2
                if excluded[m].lowerBound <= offset { lo = m + 1 } else { hi = m }
            }
            return lo > 0 && excluded[lo - 1].contains(offset)
        }
    }

    private static func findRealTime(_ base: UnsafePointer<UInt8>, limit: Int, from start: Int,
                                     structure: XMLStructure) -> Int? {
        var i = start
        while let p = find(base, limit: limit, from: i, patTime) {
            if !structure.isExcluded(p) { return p }
            i = max(p + patTime.count, structure.excludedEnd(at: p))
        }
        return nil
    }

    /// Lexical attribute scan accepts both XML quote forms and never treats text
    /// inside another attribute value as latitude/longitude.
    private static func coordinateAttribute(_ b: UnsafePointer<UInt8>, from start: Int,
                                            limit: Int, name: StaticString) -> (value: Double, end: Int)? {
        var p = start
        while p < limit {
            while p < limit && isSpace(b[p]) { p += 1 }
            let a = p
            while p < limit && !isSpace(b[p]) && b[p] != 61 && b[p] != 47 { p += 1 }
            let length = p - a
            guard length > 0 else { p += 1; continue }
            while p < limit && isSpace(b[p]) { p += 1 }
            guard p < limit, b[p] == 61 else { continue }
            p += 1
            while p < limit && isSpace(b[p]) { p += 1 }
            guard p < limit, b[p] == 34 || b[p] == 39 else { continue }
            let quote = b[p]; p += 1
            let valueStart = p
            while p < limit && b[p] != quote { p += 1 }
            if length == name.utf8CodeUnitCount, memcmp(b + a, name.utf8Start, length) == 0 {
                return parseDouble(b, limit: p, from: valueStart)
            }
            p += 1
        }
        return nil
    }

    /// Opening/closing tag terminator, ignoring > and pseudo markup in quoted values.
    private static func xmlTagEnd(_ b: UnsafePointer<UInt8>, _ n: Int, from p: Int) -> Int? {
        var quote: UInt8 = 0, bracket = 0, i = p + 1
        while i < n {
            let c = b[i]
            if quote != 0 { if c == quote { quote = 0 } }
            else if c == 34 || c == 39 { quote = c }
            else if c == 91 { bracket += 1 }
            else if c == 93 && bracket > 0 { bracket -= 1 }
            else if c == 62 && bracket == 0 { return i }
            i += 1
        }
        return nil
    }

    private static func xmlStructure(data: Data) -> XMLStructure {
        data.withUnsafeBytes { raw -> XMLStructure in
            var out = XMLStructure()
            guard let address = raw.baseAddress else { return out }
            let b = address.assumingMemoryBound(to: UInt8.self), n = raw.count
            var i = 0
            var containers: [(kind: Int, id: UInt32)] = []
            var loose: UInt32? = nil
            func allocate() -> UInt32 { let id = out.segmentCount; out.segmentCount += 1; return id }
            func boundary(_ offset: Int, _ id: UInt32) {
                if out.boundaries.last?.id != id { out.boundaries.append((offset, id)) }
            }
            func matches(_ p: Int, _ text: StaticString) -> Bool {
                let size = text.utf8CodeUnitCount
                return p + size <= n && memcmp(b + p, text.utf8Start, size) == 0
            }
            while let p = nextByte(b, limit: n, from: i, 60) {
                if matches(p, "<!--") || matches(p, "<![CDATA[") {
                    let comment = matches(p, "<!--")
                    let terminator = Array((comment ? "-->" : "]]>" ).utf8)
                    let end = find(b, limit: n, from: p + (comment ? 4 : 9), terminator).map { $0 + terminator.count } ?? n
                    out.excluded.append(p..<end); i = end; continue
                }
                guard let gt = xmlTagEnd(b, n, from: p) else { out.excluded.append(p..<n); break }
                if p + 1 < n && (b[p + 1] == 33 || b[p + 1] == 63) {
                    out.excluded.append(p..<(gt + 1)); i = gt + 1; continue
                }
                // Most tags have no embedded '<'; only unusual quoted attributes need an exclusion.
                if nextByte(b, limit: gt, from: p + 1, 60) != nil { out.excluded.append((p + 1)..<(gt + 1)) }
                let closing = p + 1 < n && b[p + 1] == 47
                let start = p + (closing ? 2 : 1)
                var end = start
                while end < gt && !isSpace(b[end]) && b[end] != 47 { end += 1 }
                let size = end - start
                func name(_ value: StaticString) -> Bool {
                    size == value.utf8CodeUnitCount && memcmp(b + start, value.utf8Start, size) == 0
                }
                if !closing, pointTagIndex(b, n, at: p) != nil { out.pointCount += 1 }
                let kind: Int
                switch size {
                case 3: kind = name("trk") ? 0 : (name("rte") ? 2 : (name("wpt") ? 3 : -1))
                case 6: kind = name("trkseg") ? 1 : -1
                default: kind = -1
                }
                let selfClosing = gt > p && b[gt - 1] == 47
                if kind >= 0 {
                    if closing {
                        if let k = containers.lastIndex(where: { $0.kind == kind }) { containers.removeSubrange(k...) }
                        loose = nil
                        if let active = containers.last { boundary(gt + 1, active.id) }
                    } else {
                        let id = allocate()
                        boundary(p, id)
                        if !selfClosing { containers.append((kind, id)) }
                        else if let active = containers.last { boundary(gt + 1, active.id) }
                        loose = nil
                    }
                } else if !closing && containers.isEmpty && (name("trkpt") || name("rtept")) {
                    if loose == nil { loose = allocate(); boundary(p, loose!) }
                }
                i = gt + 1
            }
            return out
        }
    }

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

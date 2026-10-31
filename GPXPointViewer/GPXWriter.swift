//
//  GPXWriter.swift
//  GPXPointViewer
//
//  多核并行 GPX 写出器。
//
//  与解析器同一套哲学：不走 Formatter / String 插值（每点微秒级的分配与
//  locale 开销在百万点下是数秒），全部手写 ASCII 定点数字与 ISO8601 时间
//  格式化，各线程把自己负责的点段格式化成独立字节缓冲，最后顺序拼接落盘。
//

import Foundation

enum GPXWriteError: LocalizedError {
    case noPoints
    case invalidSelection
    var errorDescription: String? {
        switch self {
        case .noPoints:
            return String(localized: "所选范围内没有点可导出。",
                          comment: "Error message when exporting GPX: the selected time range contains no points")
        case .invalidSelection:
            return String(localized: "导出范围包含无效的点索引。",
                          comment: "Error message when exporting GPX: the selected point indices are invalid")
        }
    }
}

enum GPXWriter {

    /// 把选中的点（升序原始下标）写成 GPX 1.1 文件。
    /// 每点：ele、time、（合成点）<src>、<extensions> 里的 gpxtpx:speed（m/s，Garmin
    /// TrackPointExtension v2）——一生足迹与世界迷雾都按标准 GPX 读，扩展字段无害
    static func write(track: TrackData, indices: [Int32], name: String, to url: URL,
                      synthetic: Set<GapFillExport.PointKey>? = nil) throws {
        try write(track: track, segments: [indices], name: name, to: url, synthetic: synthetic)
    }

    /// 多个 <trkseg>（增量导出：每处补点一段——世界迷雾按同一 trkseg 内相邻点连线，不同补点段之间不能连）
    static func write(track: TrackData, segments: [[Int32]], name: String, to url: URL,
                      synthetic: Set<GapFillExport.PointKey>? = nil) throws {
        // A requested export window may contain interleaved sources. Split by true
        // path membership before writing, preserving each caller-supplied window.
        var segs: [[Int32]] = []
        for selection in segments {
            var groups: [[Int32]] = []
            var slots: [UInt32: Int] = [:]
            for index in selection {
                // Never turn an invalid export request into a partial file.
                // Both callers already surface LocalizedError to the user.
                guard index >= 0, Int(index) < track.count else { throw GPXWriteError.invalidSelection }
                let id = track.topology.segment(of: Int(index))
                if slots[id] == nil { slots[id] = groups.count; groups.append([]) }
                groups[slots[id]!].append(index)
            }
            for group in groups { segs.append(group.sorted()) }
        }
        guard !segs.isEmpty else { throw GPXWriteError.noPoints }
        if segs.count > 1 {
            var out = Data()
            out.append(Data(header(name: name).utf8))
            for (k, seg) in segs.enumerated() {
                if k > 0 { out.append(Data(segmentBreak.utf8)) }
                var bytes = [UInt8]()
                bytes.reserveCapacity(seg.count * 130 + 64)
                for i in seg { appendPoint(&bytes, track: track, i: Int(i), synthetic: synthetic) }
                out.append(Data(bytes))
            }
            out.append(Data(footer.utf8))
            try out.write(to: url, options: .atomic)
            return
        }
        let indices = segs[0]
        let n = indices.count

        let cores = ProcessInfo.processInfo.activeProcessorCount
        let chunks = max(1, min(cores, n / 20_000 + 1))
        var parts = [Data?](repeating: nil, count: chunks)

        indices.withUnsafeBufferPointer { idx in
            parts.withUnsafeMutableBufferPointer { pbuf in
                let slots = pbuf
                DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                    let a = ci * n / chunks
                    let b = (ci + 1) * n / chunks
                    var bytes = [UInt8]()
                    bytes.reserveCapacity((b - a) * 130 + 64)
                    for k in a..<b {
                        appendPoint(&bytes, track: track, i: Int(idx[k]), synthetic: synthetic)
                    }
                    slots[ci] = Data(bytes)
                }
            }
        }

        var out = Data()
        out.reserveCapacity(n * 130 + 1024)
        out.append(Data(header(name: name).utf8))
        for part in parts {
            if let part { out.append(part) }
        }
        out.append(Data(footer.utf8))
        try out.write(to: url, options: .atomic)
    }

    // MARK: - 单点格式化

    private static func appendPoint(_ b: inout [UInt8], track: TrackData, i: Int,
                                    synthetic: Set<GapFillExport.PointKey>?) {
        b.append(contentsOf: ptOpen)                     // "      <trkpt lat=\""
        appendFixed(&b, track.lat[i], decimals: 7)
        b.append(contentsOf: ptLon)                      // "\" lon=\""
        appendFixed(&b, track.lon[i], decimals: 7)

        let ele = track.ele[i]
        let time = track.time[i]
        if !ele.isFinite && !time.isFinite {
            b.append(contentsOf: ptSelfClose)            // "\"/>\n"
            return
        }
        b.append(contentsOf: ptOpenEnd)                  // "\">"
        if ele.isFinite {
            b.append(contentsOf: eleOpen)
            appendFixed(&b, ele, decimals: 2)
            b.append(contentsOf: eleClose)
        }
        if time.isFinite {
            b.append(contentsOf: timeOpen)
            appendISO8601(&b, time)
            b.append(contentsOf: timeClose)
            if let synthetic, synthetic.contains(GapFillExport.PointKey(time, track.lat[i], track.lon[i],
                                                                       segment: track.topology.segment(of: i))) {
                b.append(contentsOf: srcFill)            // 补点标记（GPX 1.1 的 <src>）
            }
            // 速度：segment i-1→i 的记录速度（m/s）；断档处原本荒谬的值在补点后自然合理
            if i < track.speedKmh.count, track.speedKmh[i].isFinite {
                // 相邻点时间几乎相同时 d/dt 会爆炸（定点格式化会溢出）：钳到 1000 m/s
                let mps = min(1000.0, max(0, track.speedKmh[i]) / 3.6)
                b.append(contentsOf: speedOpen)
                appendFixed(&b, mps, decimals: 2)
                b.append(contentsOf: speedClose)
            }
        }
        b.append(contentsOf: ptClose)                    // "</trkpt>\n"
    }

    private static let ptOpen      = Array("      <trkpt lat=\"".utf8)
    private static let ptLon       = Array("\" lon=\"".utf8)
    private static let ptOpenEnd   = Array("\">".utf8)
    private static let ptSelfClose = Array("\"/>\n".utf8)
    private static let eleOpen     = Array("<ele>".utf8)
    private static let eleClose    = Array("</ele>".utf8)
    private static let timeOpen    = Array("<time>".utf8)
    private static let timeClose   = Array("</time>".utf8)
    private static let ptClose     = Array("</trkpt>\n".utf8)
    private static let srcFill     = Array("<src>GPXPointViewer-fill</src>".utf8)
    private static let speedOpen   = Array("<extensions><gpxtpx:TrackPointExtension><gpxtpx:speed>".utf8)
    private static let speedClose  = Array("</gpxtpx:speed></gpxtpx:TrackPointExtension></extensions>".utf8)

    // MARK: - 手写数字/时间格式化（零分配、零 locale）

    private static func appendUInt(_ b: inout [UInt8], _ value: UInt64) {
        if value == 0 { b.append(48); return }
        var digits = [UInt8]()
        var x = value
        while x > 0 {
            digits.append(UInt8(48 + x % 10))
            x /= 10
        }
        b.append(contentsOf: digits.reversed())
    }

    /// 定点小数（四舍五入到 decimals 位）
    private static func appendFixed(_ b: inout [UInt8], _ value: Double, decimals: Int) {
        var v = value
        guard v.isFinite else { b.append(48); return }
        if v < 0 { b.append(UInt8(ascii: "-")); v = -v }
        let p = pow(10.0, Double(decimals))
        guard v * p < 1.0e18 else {                       // 异常巨值：走通用格式化，绝不陷入 UInt64 溢出
            b.append(contentsOf: Array(String(v).utf8)); return
        }
        let scaled = UInt64((v * p).rounded())
        let pu = UInt64(p)
        appendUInt(&b, scaled / pu)
        if decimals > 0 {
            b.append(UInt8(ascii: "."))
            let frac = scaled % pu
            var div = pu / 10
            while div > 0 {
                b.append(UInt8(48 + (frac / div) % 10))
                div /= 10
            }
        }
    }

    @inline(__always)
    private static func append2(_ b: inout [UInt8], _ v: Int) {
        b.append(UInt8(48 + (v / 10) % 10))
        b.append(UInt8(48 + v % 10))
    }

    /// Unix 秒 → "YYYY-MM-DDTHH:MM:SS[.mmm]Z"（Hinnant civil-from-days，无 Foundation 日期开销）
    private static func appendISO8601(_ b: inout [UInt8], _ t: Double) {
        let ti = t.rounded(.down)
        var days = Int((ti / 86400.0).rounded(.down))
        var secOfDay = Int(ti) - days * 86400
        if secOfDay < 0 { secOfDay += 86400; days -= 1 }

        let z = days + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        var y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        if m <= 2 { y += 1 }

        appendUInt(&b, UInt64(max(0, y)))
        b.append(UInt8(ascii: "-")); append2(&b, m)
        b.append(UInt8(ascii: "-")); append2(&b, d)
        b.append(UInt8(ascii: "T")); append2(&b, secOfDay / 3600)
        b.append(UInt8(ascii: ":")); append2(&b, (secOfDay / 60) % 60)
        b.append(UInt8(ascii: ":")); append2(&b, secOfDay % 60)

        let frac = t - ti
        if frac >= 0.0005 {
            let ms = min(999, Int((frac * 1000).rounded()))
            b.append(UInt8(ascii: "."))
            b.append(UInt8(48 + (ms / 100) % 10))
            b.append(UInt8(48 + (ms / 10) % 10))
            b.append(UInt8(48 + ms % 10))
        }
        b.append(UInt8(ascii: "Z"))
    }

    // MARK: - 文件头尾

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func header(name: String) -> String {
        let escaped = xmlEscape(name)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="GPXPointViewer" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v2">
          <metadata>
            <name>\(escaped)</name>
          </metadata>
          <trk>
            <name>\(escaped)</name>
            <trkseg>

        """
    }

    private static let footer = """
            </trkseg>
          </trk>
        </gpx>

        """

    private static let segmentBreak = """
            </trkseg>
            <trkseg>

        """
}

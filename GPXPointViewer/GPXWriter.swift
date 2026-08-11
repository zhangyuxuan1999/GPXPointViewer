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
    var errorDescription: String? { "所选范围内没有点可导出。" }
}

enum GPXWriter {

    /// 把选中的点（升序原始下标）写成 GPX 1.1 文件
    static func write(track: TrackData, indices: [Int32], name: String, to url: URL) throws {
        let n = indices.count
        guard n > 0 else { throw GPXWriteError.noPoints }

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
                        appendPoint(&bytes, track: track, i: Int(idx[k]))
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

    private static func appendPoint(_ b: inout [UInt8], track: TrackData, i: Int) {
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
        <gpx version="1.1" creator="GPXPointViewer" xmlns="http://www.topografix.com/GPX/1/1">
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
}

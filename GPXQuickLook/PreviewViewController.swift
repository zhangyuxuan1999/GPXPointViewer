//
//  PreviewViewController.swift
//  GPXQuickLook
//
//  Finder 空格键的 GPX 快速预览：自绘轨迹折线 + 概要信息行。
//  常规文件复用主 App 的两趟并行解析器；超大文件（>32MB）降级为
//  轻量采样扫描 + 并行计数——Quick Look 扩展的内存预算比主 App 紧，
//  绝不在扩展进程里为预览分配整套点数组。
//  不依赖网络/地图服务：秒开、离线可用、沙盒内零权限诉求。
//

import Cocoa
import Quartz

final class PreviewViewController: NSViewController, QLPreviewingController {

    /// 超过该大小不做完整解析，走采样降级
    private static let fullParseLimit = 32 * 1024 * 1024

    override func loadView() {
        view = NSView()          // 尺寸由 Quick Look 决定
        view.wantsLayer = true
    }

    func preparePreviewOfFile(at url: URL,
                              completionHandler handler: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let lat: [Double]
                let lon: [Double]
                let segmentID: [UInt32]
                let summary: String
                if data.count > Self.fullParseLimit {
                    // One lexical structure scan supplies both the count and sampled source labels.
                    let scan = GPXParser.sampleScan(data: data, targetPoints: 4000)
                    guard scan.count > 0 else { throw GPXParseError.noPoints }
                    lat = scan.lat
                    lon = scan.lon
                    segmentID = scan.segmentID
                    summary = Self.summaryLine(count: scan.totalPointCount,
                                               tMin: scan.firstTime, tMax: scan.lastTime,
                                               sampled: true)
                } else {
                    let parsed = try GPXParser.parse(data: data)
                    var tMin = Double.infinity, tMax = -Double.infinity
                    for t in parsed.time where t.isFinite {
                        if t < tMin { tMin = t }
                        if t > tMax { tMax = t }
                    }
                    lat = parsed.lat
                    lon = parsed.lon
                    segmentID = parsed.segmentID
                    summary = Self.summaryLine(count: parsed.count, tMin: tMin, tMax: tMax,
                                               sampled: false)
                }
                DispatchQueue.main.async { [weak self] in
                    self?.buildUI(lat: lat, lon: lon, segmentID: segmentID, summary: summary)
                    handler(nil)
                }
            } catch {
                DispatchQueue.main.async { handler(error) }
            }
        }
    }

    private func buildUI(lat: [Double], lon: [Double], segmentID: [UInt32], summary: String) {
        let label = NSTextField(labelWithString: summary)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        let trackView = GPXTrackShapeView(lat: lat, lon: lon, segmentID: segmentID)
        trackView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(label)
        view.addSubview(trackView)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -14),
            trackView.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            trackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            trackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            trackView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// 概要行：点数 · 日期范围 · 时长（· 抽样显示）。
    /// 不显示里程——GPS 抖动会让逐点求和严重灌水（App 内已知问题），
    /// 预览宁缺毋滥，只给完全可靠的信息
    /// 文案经 String(localized:) 走扩展自己的 Localizable.xcstrings（Bundle.main = appex）
    private static func summaryLine(count: Int, tMin: Double, tMax: Double,
                                    sampled: Bool) -> String {
        let countText = count.formatted()
        var parts = [String(localized: "\(countText) 个点",
                            comment: "Quick Look preview summary line: number of track points in the file; %@ = point count, already formatted with grouping (e.g. 12,345)")]
        if tMin.isFinite, tMax.isFinite {
            // 纯数字固定格式：POSIX + 公历，不随地区换历法/数字
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.calendar = Calendar(identifier: .gregorian)
            fmt.dateFormat = "yyyy-MM-dd"
            let a = fmt.string(from: Date(timeIntervalSince1970: tMin))
            let b = fmt.string(from: Date(timeIntervalSince1970: tMax))
            if a == b {
                parts.append(a)
            } else {
                parts.append(String(localized: "\(a) ~ \(b)",
                                    comment: "Quick Look preview summary line: date range of the track; first %@ = first day, second %@ = last day (both yyyy-MM-dd); en/de use an en dash: %1$@ – %2$@"))
            }

            let span = tMax - tMin
            if span >= 60, span < 3600 * 24 * 2 {   // 单次记录才显示时长
                // 先去尾到整分钟（与旧版一致，不让 59.6 分进位成 1 小时）
                let wholeMinutes = Int(span) / 60
                parts.append(Duration.seconds(wholeMinutes * 60)
                    .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
            }
        }
        if sampled {
            parts.append(String(localized: "抽样显示",
                                comment: "Quick Look preview summary line, last item: the file is very large, so only an evenly spaced sample of its points is drawn"))
        }
        return parts.joined(separator: "  ·  ")
    }
}

//
//  PreviewViewController.swift
//  GPXQuickLook
//
//  Finder 空格键的 GPX 快速预览：复用主 App 的两趟并行解析器，
//  自绘轨迹折线（免零填充墨卡托投影 + 抽稀 + 跳段断开）+ 概要信息行。
//  不依赖网络/地图服务：秒开、离线可用、沙盒内零权限诉求。
//

import Cocoa
import Quartz

final class PreviewViewController: NSViewController, QLPreviewingController {

    override func loadView() {
        view = NSView()          // 尺寸由 Quick Look 决定
        view.wantsLayer = true
    }

    func preparePreviewOfFile(at url: URL,
                              completionHandler handler: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let parsed = try GPXParser.parse(data: data)
                DispatchQueue.main.async { [weak self] in
                    self?.buildUI(parsed: parsed)
                    handler(nil)
                }
            } catch {
                DispatchQueue.main.async { handler(error) }
            }
        }
    }

    private func buildUI(parsed: ParsedTrack) {
        let summary = Self.summaryLine(parsed)
        let label = NSTextField(labelWithString: summary)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        let trackView = GPXTrackPreviewView(parsed: parsed)
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

    /// 概要行：点数 · 日期范围 · 时长。
    /// 不显示里程——GPS 抖动会让逐点求和严重灌水（App 内已知问题），
    /// 预览宁缺毋滥，只给完全可靠的信息
    private static func summaryLine(_ p: ParsedTrack) -> String {
        var parts = ["\(p.count.formatted()) 个点"]

        var tMin = Double.infinity, tMax = -Double.infinity
        for t in p.time where t.isFinite {
            if t < tMin { tMin = t }
            if t > tMax { tMax = t }
        }
        if tMin.isFinite, tMax.isFinite {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            let a = fmt.string(from: Date(timeIntervalSince1970: tMin))
            let b = fmt.string(from: Date(timeIntervalSince1970: tMax))
            parts.append(a == b ? a : "\(a) ~ \(b)")

            let span = tMax - tMin
            if span >= 60, span < 3600 * 24 * 2 {   // 单次记录才显示时长
                let h = Int(span) / 3600
                let m = (Int(span) % 3600) / 60
                parts.append(h > 0 ? "\(h) 小时 \(m) 分" : "\(m) 分钟")
            }
        }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - 轨迹绘制视图

/// 等距墨卡托投影下的轨迹折线：适配窗口留边、按需抽稀（≤2 万段）、
/// 轨迹间"瞬移"长段自动断开；起点绿点、终点红点。
private final class GPXTrackPreviewView: NSView {
    private let pts: [CGPoint]        // 投影后的原始坐标（未归一化）
    private let breaks: [Bool]        // pts[i] 与 pts[i+1] 之间是否断开
    private let bounds2D: CGRect

    init(parsed: ParsedTrack) {
        let n = parsed.count
        let stride = max(1, n / 6_000)   // 预览 ≤6000 段足够，描边成本与段数成正比
        var out = [CGPoint]()
        out.reserveCapacity(n / stride + 2)
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        var i = 0
        while i < n {
            // 等距圆柱投影足够预览用：x = lon·cos(中纬)，y = lat
            let x = CGFloat(parsed.lon[i])
            let y = CGFloat(parsed.lat[i])
            out.append(CGPoint(x: x, y: y))
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            i += stride
        }
        if let last = out.last, (n - 1) % stride != 0 {
            _ = last   // 末点补齐：保证终点标记落在真实终点
            let x = CGFloat(parsed.lon[n - 1]), y = CGFloat(parsed.lat[n - 1])
            out.append(CGPoint(x: x, y: y))
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        pts = out

        // 断开检测：段长 > max(50×中位段, 0.5°) 视为轨迹间跳跃
        var segs = [CGFloat]()
        segs.reserveCapacity(min(out.count, 4096))
        let sampleStride = max(1, out.count / 4096)
        var k = sampleStride
        while k < out.count {
            let dx = out[k].x - out[k - sampleStride].x
            let dy = out[k].y - out[k - sampleStride].y
            segs.append(hypot(dx, dy))
            k += sampleStride
        }
        segs.sort()
        let median = segs.isEmpty ? 0 : segs[segs.count / 2]
        let jump = max(median * 50, 0.5)
        var br = [Bool](repeating: false, count: max(0, out.count - 1))
        for j in 0..<br.count {
            let dx = out[j + 1].x - out[j].x
            let dy = out[j + 1].y - out[j].y
            if hypot(dx, dy) > jump { br[j] = true }
        }
        breaks = br

        // 纬度畸变补偿：经度按中纬 cos 压缩，让形状接近真实比例
        let midLat = Double(minY + maxY) / 2 * .pi / 180
        let cosMid = CGFloat(max(0.2, cos(midLat)))
        var b = CGRect(x: minX * cosMid, y: minY,
                       width: max((maxX - minX) * cosMid, 1e-6),
                       height: max(maxY - minY, 1e-6))
        if b.width < 1e-5 { b = b.insetBy(dx: -5e-6, dy: 0) }
        if b.height < 1e-5 { b = b.insetBy(dx: 0, dy: -5e-6) }
        bounds2D = b
        var scaled = pts
        for j in 0..<scaled.count { scaled[j].x *= cosMid }
        self.scaledPts = scaled
        super.init(frame: .zero)
    }

    private let scaledPts: [CGPoint]

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard !scaledPts.isEmpty else { return }
        let pad: CGFloat = 24
        let w = bounds.width - pad * 2
        let h = bounds.height - pad * 2
        guard w > 10, h > 10 else { return }

        // 等比适配 + 居中
        let sx = w / bounds2D.width
        let sy = h / bounds2D.height
        let s = min(sx, sy)
        let offX = pad + (w - bounds2D.width * s) / 2
        let offY = pad + (h - bounds2D.height * s) / 2
        func mapPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(x: offX + (p.x - bounds2D.minX) * s,
                    y: offY + (p.y - bounds2D.minY) * s)
        }

        // 不透明 + 分块描边：半透明的超长单一路径会让 CG 做昂贵的
        // 描边轮廓合并（443MB 备份文件实测 11s → 毫秒级）
        NSColor.systemBlue.setStroke()
        var path = NSBezierPath()
        path.lineWidth = 2
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        var penDown = false
        var segsInPath = 0
        for (j, p) in scaledPts.enumerated() {
            let v = mapPoint(p)
            if !penDown {
                path.move(to: v)
                penDown = true
            } else {
                path.line(to: v)
                segsInPath += 1
                if segsInPath >= 512 {          // 分块冲刷（不透明色下接缝不可见）
                    path.stroke()
                    path = NSBezierPath()
                    path.lineWidth = 2
                    path.lineJoinStyle = .round
                    path.lineCapStyle = .round
                    path.move(to: v)
                    segsInPath = 0
                }
            }
            if j < breaks.count, breaks[j] { penDown = false }
        }
        if segsInPath > 0 { path.stroke() }

        // 起点绿 / 终点红
        func dot(_ p: CGPoint, _ color: NSColor) {
            let r: CGFloat = 5
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: rect)
            ring.lineWidth = 1.5
            ring.stroke()
        }
        dot(mapPoint(scaledPts[0]), .systemGreen)
        if scaledPts.count > 1 {
            dot(mapPoint(scaledPts[scaledPts.count - 1]), .systemRed)
        }
    }
}

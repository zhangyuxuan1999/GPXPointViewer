//
//  ThumbnailProvider.swift
//  GPXThumbnail
//
//  Finder 图标缩略图：GPX 文件的图标直接显示迷你轨迹图。
//  文件夹视图会成批生成缩略图，预算最紧——始终走轻量采样扫描
//  （等距取 ≤600 点），绝不完整解析。
//

import Cocoa
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let size = request.maximumSize
        let reply = QLThumbnailReply(contextSize: size) { () -> Bool in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
            let scan = GPXParser.sampleScan(data: data, targetPoints: 600,
                                            includeTimes: false)   // 图标用不到时间
            guard scan.count > 0 else { return false }

            let rect = CGRect(origin: .zero, size: size)
            // 纸面底色（浅色固定：Finder 文档图标习惯）+ 细边
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: size.width * 0.06,
                         yRadius: size.width * 0.06).fill()

            let shape = GPXTrackShape(lat: scan.lat, lon: scan.lon, segmentID: scan.segmentID)
            let inset = min(size.width, size.height) * 0.12
            shape.draw(in: rect.insetBy(dx: inset, dy: inset),
                       lineWidth: max(1.5, size.width / 64),
                       dotRadius: max(2.0, size.width / 32))
            return true
        }
        handler(reply, nil)
    }
}

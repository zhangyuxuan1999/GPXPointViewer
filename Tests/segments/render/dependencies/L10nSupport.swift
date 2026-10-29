//
//  L10nSupport.swift
//  GPXPointViewer
//
//  本地化辅助。只依赖 Foundation：离线 CLI 探针用 swiftc 直接编引擎文件（GapFill/RoadNetwork/TrackData/…），
//  这里不能拖进 SwiftUI/AppKit。
//

import Foundation

/// 数字格式：不分组（1234 而不是随语言变成 1,234 / 1.234 / 1 234），固定小数位；小数点随界面语言
enum Fmt {
    static let f0 = FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.fractionLength(0))
    static let f1 = FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.fractionLength(1))
    static let f2 = FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.fractionLength(2))
    static let f3 = FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.fractionLength(3))

    /// 列举分隔符：中文「、」，其它语言由字符串目录给出（如 ", "）
    static var listSeparator: String { String(localized: "list.separator", defaultValue: "、") }
}

//
//  GPXPointViewerApp.swift
//  GPXPointViewer
//

import SwiftUI
import AppKit

/// 各 Window 场景的 id：openWindow(id:) 与按场景找 NSWindow 都用它（窗口标题会被本地化，不能拿来当标识）
enum SceneID {
    static let diff = "diff", batchFill = "batchFill", changeReview = "changeReview", regions = "regions", journeySummary = "journeySummary"
}

extension NSApplication {
    /// 按 SwiftUI 场景 id 找窗口：NSWindow.identifier 为 id 本身或 "id-AppWindow-N" 之类；优先可见的那个。
    /// 批量补点窗口兜底再按（本地化后的）标题找一次
    func window(scene id: String) -> NSWindow? {
        let hits = windows.filter { w in
            guard let raw = w.identifier?.rawValue else { return false }
            return raw == id || raw.hasPrefix(id + "-")
        }
        if let w = hits.first(where: { $0.isVisible }) ?? hits.first { return w }
        if id == SceneID.batchFill {
            let title = String(localized: "批量补点")
            return windows.first { $0.isVisible && $0.title == title } ?? windows.first { $0.title == title }
        }
        return nil
    }
}

/// 应用内语言覆盖（设置面板「语言」）：写本 app 自己域里的 AppleLanguages，重启 app 后生效——
/// 和 系统设置 › 通用 › 语言与地区 › 应用程序 写的是同一个键，两边互通。
///
/// 优先级（UserDefaults 域顺序）：参数域 > 本 app 持久域 > 全局域。自测/uitest 启动带
/// `--args -AppleLanguages '(zh-Hans)'` 落在参数域，总能压过这里存的选择，所以测试始终是中文界面。
enum AppLanguage: String, CaseIterable {
    case system = ""
    case hans = "zh-Hans"
    case hant = "zh-Hant"
    case en = "en"
    case de = "de"

    /// 本 app 持久域里存的选择（nil / 空 / 不认识的语言 = 跟随系统）。
    /// 必须读 persistentDomain：UserDefaults.array(forKey: "AppleLanguages") 会落到全局域，返回系统的语言列表
    static var stored: AppLanguage {
        guard let id = Bundle.main.bundleIdentifier,
              let langs = UserDefaults.standard.persistentDomain(forName: id)?["AppleLanguages"] as? [String],
              let first = langs.first else { return .system }
        return match(first) ?? .system
    }

    /// 启动时存的选择（App.init 里触碰一次，static let 才会在启动时求值而不是第一次打开设置时）；
    /// 设置面板据此判断"改了还没重启"
    static let launchSnapshot = stored

    /// 语言代码 → 支持的语言（按语言子标签 + 文字/地区判断）：
    /// zh-Hans-CN / zh-CN / zh → 简体；zh-Hant-TW / zh-TW / zh-HK / zh-MO → 繁体；en-US → en；de-DE → de；其余 nil
    static func match(_ code: String) -> AppLanguage? {
        let parts = code.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").map(String.init)
        switch parts.first {
        case "en": return .en
        case "de": return .de
        case "zh":
            let rest = parts.dropFirst()
            if rest.contains("hant") { return .hant }
            if rest.contains("hans") { return .hans }
            return rest.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? .hant : .hans
        default: return nil
        }
    }

    /// 写入本 app 持久域：跟随系统 = 删键（回落到全局域）；其余 = 只放这一种语言。
    /// 界面文字（String Catalog）要重启才换：试过运行中换 Bundle.main 的类来改 String(localized:) 的查表，实测不生效，
    /// 所以设置页选完直接 relaunch()。只有地区名（RegionIndex 自己查名字池）能当场跟着换。
    static func apply(_ l: AppLanguage) {
        if l == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([l.rawValue], forKey: "AppleLanguages")
        }
        RegionIndex.languageOverride = l == .system ? nil : l.rawValue   // 地区名跟着选择走（统计窗口下一次刷新就变）
    }

    /// 菜单里的名字：跟随系统 走本地化（与 AppearanceMode 共用同一个键），其余用各语言的自称
    var label: Text {
        switch self {
        case .system: return Text("跟随系统")
        case .hans: return Text(verbatim: "简体中文")
        case .hant: return Text(verbatim: "繁體中文")
        case .en: return Text(verbatim: "English")
        case .de: return Text(verbatim: "Deutsch")
        }
    }

    /// 以新实例重新打开自己，成功后退出当前实例；打不开就留在原地报错（不能白白退出）
    @MainActor
    static func relaunch() {
        // 自测钩子：NSWorkspace 新开的实例拿不到环境变量/启动参数（实测被剥掉），用容器 tmp 里的交接文件把钩子目录传过去
        if UITestHook.enabled { UITestHook.writeHandoff() }
        let config: NSWorkspace.OpenConfiguration = {
            let c = NSWorkspace.OpenConfiguration()
            c.createsNewApplicationInstance = true
            return c
        }()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error {
                    NSAlert(error: error).runModal()
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

@main
struct GPXPointViewerApp: App {
    // App 级共享：主窗口与"找不同"窗口读写同一份状态
    @StateObject private var store = TrackStore()

    init() {
        _ = AppLanguage.launchSnapshot   // 启动时定格存储的语言选择（见 AppLanguage.launchSnapshot）
        RegionIndex.languageOverride = AppLanguage.stored == .system ? nil : AppLanguage.stored.rawValue
    }

    var body: some Scene {
        WindowGroup("GPX 点位查看器") {
            ContentView(store: store)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear { UITestHook.shared.start(store: store) }   // 仅 GPXPV_UITEST_DIR 环境变量存在时生效
        }
        .defaultSize(width: 1320, height: 860)
        .commands { JourneySummaryCommands(store: store) }

        Window("找不同", id: SceneID.diff) {
            DiffWindowView(store: store)
                .frame(minWidth: 700, minHeight: 480)
        }
        .defaultSize(width: 1000, height: 700)

        Window("批量补点", id: SceneID.batchFill) {
            BatchFillWindowView(store: store)
        }
        .defaultSize(width: 920, height: 780)

        Window("修改记录", id: SceneID.changeReview) {
            ChangeReviewView(store: store)
        }
        .defaultSize(width: 1000, height: 720)

        Window("地区统计", id: SceneID.regions) {
            RegionsWindowView(store: store)
        }
        .defaultSize(width: 720, height: 640)

        Window("每日与行程摘要", id: SceneID.journeySummary) {
            JourneySummaryWindowView(store: store)
        }
        .defaultSize(width: 1000, height: 700)
    }
}

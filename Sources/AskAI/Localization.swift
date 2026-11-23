import Foundation

// MARK: - 本地化（中文 / English）
// 默认跟随系统首选语言；可用 defaults write com.dsh.AskAI lang en 强制切换。

private enum Language {
    static let isChinese: Bool = {
        if let forced = defaults.string(forKey: "lang"), !forced.isEmpty {
            return forced.lowercased().hasPrefix("zh")
        }
        return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    }()
}
var appIsChinese: Bool { Language.isChinese }

/// 双语取词：中文环境返回 zh，否则返回 en
func L(_ zh: String, _ en: String) -> String { appIsChinese ? zh : en }

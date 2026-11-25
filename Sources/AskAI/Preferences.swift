import Foundation

// MARK: - 配置与通用工具

var defaults: UserDefaults { .standard }

struct AskError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

extension String {
    /// 压平换行并去除首尾空白，供标题与菜单条目单行展示。
    var flattenedLine: String {
        replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

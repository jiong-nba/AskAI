import Foundation

// MARK: - 历史记录

struct HistoryEntry: Codable, Equatable {
    let time: Date
    let mode: String
    let source: String
    let answer: String
    var sentCharacters: Int? = nil
    var question: String? = nil   // 追问的问题；对原文的提问没有这一项，旧版本写出的条目也没有
}

/// 历史菜单里的相对时间：一天以内用相对说法，更早的给日期。
func relativeTime(from date: Date, now: Date = Date()) -> String {
    let elapsed = now.timeIntervalSince(date)
    let minute: TimeInterval = 60, hour: TimeInterval = 3_600, day: TimeInterval = 86_400
    switch elapsed {
    case ..<minute:   // 时钟略有偏差时 elapsed 可能是负的，也算「刚刚」
        return L("刚刚", "just now")
    case ..<hour:
        let minutes = Int(elapsed / minute)
        return L("\(minutes) 分钟前", "\(minutes) min ago")
    case ..<day:
        let hours = Int(elapsed / hour)
        return L("\(hours) 小时前", "\(hours) h ago")
    case ..<(2 * day):
        return L("昨天", "yesterday")
    default:
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appIsChinese ? "zh_CN" : "en_US")
        formatter.dateFormat = elapsed < 365 * day
            ? (appIsChinese ? "M月d日" : "MMM d")
            : (appIsChinese ? "yyyy年M月d日" : "MMM d, yyyy")
        return formatter.string(from: date)
    }
}

let historyKey = "history"
let historyLimit = 20

// 历史存文件而非 UserDefaults：避免 plist 膨胀，也便于用户自行删除/审计
let historyDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("AskAI", isDirectory: true)
let historyFile = historyDir.appendingPathComponent("history.json")

// history.json is atomically replaced. Lock a separate, persistent inode for every writer.
private func withHistoryLock<T>(_ operation: () throws -> T) throws -> T {
    try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
    let path = historyDir.appendingPathComponent("history.lock").path
    var fd: Int32
    repeat {
        fd = open(path, O_RDWR | O_CREAT | O_EXLOCK | O_CLOEXEC, 0o600)
    } while fd == -1 && errno == EINTR
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer { close(fd) }
    return try operation()
}

/// 给用户看的一次性提示，跨线程传递（历史在后台任务里写，在界面上读）。只保留最新一条。
/// 可变状态都在锁里，所以可以标成 Sendable。
final class HistoryNotice: @unchecked Sendable {
    static let shared = HistoryNotice()
    private let lock = NSLock()
    private var text: String?

    init() {}

    func post(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        text = message
    }

    /// 取走当前的提示；没有就返回 nil。
    func take() -> String? {
        lock.lock(); defer { lock.unlock() }
        let message = text
        text = nil
        return message
    }
}

/// history.json 存在却读不出来（手改出错的 JSON、权限问题）时，把它挪到一旁再从空历史开始。
/// 不然之后每一条回答都存不进去，界面上只会看到「暂无记录」。
/// 挪不动（目录不可写等）时把错误抛出去，由调用方处理。
private func quarantineUnreadableHistory(_ reason: Error) throws {
    let stamp = Int(Date().timeIntervalSince1970)
    var backup = historyDir.appendingPathComponent("history.corrupt-\(stamp).json")
    while FileManager.default.fileExists(atPath: backup.path) {
        backup = historyDir.appendingPathComponent("history.corrupt-\(stamp)-\(UUID().uuidString.prefix(8)).json")
    }
    try FileManager.default.moveItem(at: historyFile, to: backup)
    NSLog("AskAI: unreadable history moved to \(backup.lastPathComponent): \(reason.localizedDescription)")
    HistoryNotice.shared.post(L("history.json 读不出来，已另存为 \(backup.lastPathComponent)，历史记录从空开始。",
                                "history.json could not be read. It was moved aside as \(backup.lastPathComponent) and history starts empty."))
}

func readHistoryFile() throws -> [HistoryEntry] {
    do {
        let data = try Data(contentsOf: historyFile)
        return try JSONDecoder().decode([HistoryEntry].self, from: data)
    } catch CocoaError.fileReadNoSuchFile {
        return []
    } catch {
        try quarantineUnreadableHistory(error)
        return []
    }
}

private func saveHistory(_ entries: [HistoryEntry]) throws {
    let data = try JSONEncoder().encode(Array(entries.prefix(historyLimit)))
    try data.write(to: historyFile, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyFile.path)
}

/// Called under the history lock. Another process may have migrated these defaults already.
private func migrateLegacyHistoryIfNeeded() throws {
    guard defaults.object(forKey: historyKey) != nil else { return }
    defaults.synchronize()
    guard let raw = defaults.array(forKey: historyKey) as? [[String: Any]] else { return }
    let legacy: [HistoryEntry] = raw.compactMap { d in
        guard let t = d["time"] as? Double, let m = d["mode"] as? String,
              let s = d["source"] as? String, let a = d["answer"] as? String else { return nil }
        return HistoryEntry(time: Date(timeIntervalSince1970: t), mode: m, source: s, answer: a)
    }
    if !legacy.isEmpty {
        let existing = try readHistoryFile()
        try saveHistory(existing + legacy.filter { !existing.contains($0) })
    }
    defaults.removeObject(forKey: historyKey)
    defaults.synchronize()
}

func loadHistory() -> [HistoryEntry] {
    do {
        return try withHistoryLock {
            try migrateLegacyHistoryIfNeeded()
            return try readHistoryFile()
        }
    } catch {
        NSLog("AskAI: failed to load history: \(error.localizedDescription)")
        return []
    }
}

func clearHistoryStorage() {
    do {
        try withHistoryLock {
            if FileManager.default.fileExists(atPath: historyFile.path) {
                try FileManager.default.removeItem(at: historyFile)
            }
            defaults.removeObject(forKey: historyKey)
            defaults.synchronize()
        }
    } catch {
        NSLog("AskAI: failed to clear history: \(error.localizedDescription)")
    }
}

/// 是否往 history.json 里写。关掉之后已有的条目保留，直到用户清空。
/// defaults write com.dsh.AskAI saveHistory false
func historySavingEnabled(defaults: UserDefaults = .standard) -> Bool {
    // 没设就是开；设了就按布尔值读（defaults write ... false 存的是 Bool，命令行参数 -saveHistory NO 给的是字符串）
    defaults.object(forKey: "saveHistory") == nil || defaults.bool(forKey: "saveHistory")
}

func appendHistory(mode: String, source: String, answer: String, sentCharacters: Int? = nil,
                    question: String? = nil) throws {
    guard !answer.isEmpty, !answer.hasPrefix("❌"), historySavingEnabled() else { return }
    try withHistoryLock {
        try migrateLegacyHistoryIfNeeded()
        var list = try readHistoryFile()
        list.insert(HistoryEntry(time: Date(), mode: mode, source: source, answer: answer, sentCharacters: sentCharacters, question: question), at: 0)
        try saveHistory(list)
    }
}

import Foundation

// MARK: - 历史记录

struct HistoryEntry: Codable, Equatable {
    let time: Date
    let mode: String
    let source: String
    let answer: String
    var sentCharacters: Int? = nil
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

func readHistoryFile() throws -> [HistoryEntry] {
    do {
        let data = try Data(contentsOf: historyFile)
        return try JSONDecoder().decode([HistoryEntry].self, from: data)
    } catch CocoaError.fileReadNoSuchFile {
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

func appendHistory(mode: String, source: String, answer: String, sentCharacters: Int? = nil) throws {
    guard !answer.isEmpty, !answer.hasPrefix("❌") else { return }
    try withHistoryLock {
        try migrateLegacyHistoryIfNeeded()
        var list = try readHistoryFile()
        list.insert(HistoryEntry(time: Date(), mode: mode, source: source, answer: answer, sentCharacters: sentCharacters), at: 0)
        try saveHistory(list)
    }
}

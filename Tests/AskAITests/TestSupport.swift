import Foundation
@testable import AskAI

/// 测试专用的 UserDefaults：只存在内存里，不落盘。
///
/// 不要用 `UserDefaults(suiteName:)` 做隔离：即使随后 removePersistentDomain，macOS 也会在
/// ~/Library/Preferences 留下一个空 plist，测试每跑一次就多一个文件。进程自己的 `.standard`
/// 同样不能写——那是 swiftpm-testing-helper 的真实域，值会一直留在开发机上。
final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock(); defer { lock.unlock() }
        values[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        lock.lock(); defer { lock.unlock() }
        values[defaultName] = nil
    }

    // 类型化的读取在 Foundation 里不一定经过 object(forKey:)，这里逐一改写，保证只读内存。
    override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { object(forKey: defaultName) as? [String: Any] }
    override func integer(forKey defaultName: String) -> Int { number(forKey: defaultName)?.intValue ?? 0 }
    override func double(forKey defaultName: String) -> Double { number(forKey: defaultName)?.doubleValue ?? 0 }
    override func float(forKey defaultName: String) -> Float { number(forKey: defaultName)?.floatValue ?? 0 }
    override func bool(forKey defaultName: String) -> Bool { number(forKey: defaultName)?.boolValue ?? false }

    private func number(forKey defaultName: String) -> NSNumber? { object(forKey: defaultName) as? NSNumber }
}

/// 给 @Sendable 回调记录调用用：这种闭包不能捕获可变的局部变量。
final class Recorder<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    var values: [Element] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    func append(_ element: Element) {
        lock.lock(); defer { lock.unlock() }
        items.append(element)
    }
}

/// 一个带锁的盒子：给需要在并发检查下读写的静态状态用（`nonisolated(unsafe)` 要 Swift 5.10）。
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}

/// 一次性的信号：测试夹具等到它才继续，用不着靠睡眠去猜。
final class Cue: @unchecked Sendable {
    private let condition = NSCondition()
    private var signalled = false

    func signal() {
        condition.lock()
        signalled = true
        condition.broadcast()
        condition.unlock()
    }

    /// 等到信号返回 true；超时返回 false。
    func wait(seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        condition.lock(); defer { condition.unlock() }
        while !signalled && condition.wait(until: deadline) { }
        return signalled
    }
}

/// 测试里的固定连接：不读进程的 defaults，结果不受开发机上残留配置的影响。
let fixtureConnection = ConnectionSettings(url: URL(string: "https://fixture.invalid/chat/completions")!,
                                           model: "fixture-model", apiKey: "fixture-key", summaryLimit: 16_000)

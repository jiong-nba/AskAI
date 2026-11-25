import AppKit
import Carbon

// 快捷键配置（默认 ⌘⇧E；用菜单栏 🤖 →「设置快捷键…」改，自动存进 defaults）
let defaultHotKeyCode = UInt32(kVK_ANSI_E)
let defaultHotKeyMods = UInt(NSEvent.ModifierFlags.command.union(.shift).rawValue)

extension NSEvent.ModifierFlags {
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}

/// 有效的 macOS 虚拟键码（排除 54–63 单独修饰键和越界键码）。
func isSupportedKeyCode(_ keyCode: UInt32) -> Bool {
    keyCode <= 126 && !(54...63).contains(keyCode)
}

/// defaults 里当前配置的快捷键。
func configuredHotKey(defaults: UserDefaults = .standard) -> (code: UInt32, mods: NSEvent.ModifierFlags) {
    let code = UInt32(defaults.object(forKey: "hotkeyKey") as? Int ?? Int(defaultHotKeyCode))
    let raw = UInt(defaults.object(forKey: "hotkeyMods") as? Int ?? Int(defaultHotKeyMods))
    return (code, NSEvent.ModifierFlags(rawValue: raw))
}

private let hotKeySignature: OSType = 0x41736B48   // 'AskH'

private func carbonHotKeyCallback(_ nextHandler: EventHandlerCallRef?,
                                    _ event: EventRef?,
                                    _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == hotKeySignature,
          let handler = HotKeyCenter.shared.handler(for: hotKeyID.id) else {
        return OSStatus(eventNotHandledErr)
    }
    MainActor.assumeIsolated { handler() }
    return noErr
}

private final class HotKeyCenter: @unchecked Sendable {
    static let shared = HotKeyCenter()
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    private var handlers: [UInt32: @MainActor @Sendable () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    private func installIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), carbonHotKeyCallback, 1, &spec, nil, &eventHandler)
    }

    func register(keyCode: UInt32, mods: NSEvent.ModifierFlags,
                  handler: @escaping @MainActor @Sendable () -> Void) -> (id: UInt32, ref: EventHotKeyRef)? {
        installIfNeeded()
        lock.lock()
        let id = nextID
        nextID = nextID == UInt32.max ? 1 : nextID + 1
        handlers[id] = handler
        lock.unlock()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: id)
        let status = RegisterEventHotKey(keyCode, mods.carbonFlags, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            lock.lock()
            handlers[id] = nil
            lock.unlock()
            return nil
        }
        return (id, ref)
    }

    func unregister(id: UInt32, ref: EventHotKeyRef) {
        UnregisterEventHotKey(ref)
        lock.lock()
        handlers[id] = nil
        lock.unlock()
    }

    func handler(for id: UInt32) -> (@MainActor @Sendable () -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return handlers[id]
    }
}

private final class CarbonHotKey {
    private let id: UInt32
    private let ref: EventHotKeyRef

    init?(keyCode: UInt32, mods: NSEvent.ModifierFlags, handler: @escaping @MainActor @Sendable () -> Void) {
        guard let registered = HotKeyCenter.shared.register(keyCode: keyCode, mods: mods, handler: handler) else {
            return nil
        }
        id = registered.id
        ref = registered.ref
    }

    deinit {
        HotKeyCenter.shared.unregister(id: id, ref: ref)
    }
}

/// 组合是否已被占用：别的进程持有，或本进程里还没注销的注册。
func hotKeyIsTaken(keyCode: UInt32, mods: NSEvent.ModifierFlags) -> Bool {
    var probe: EventHotKeyRef?
    let id = EventHotKeyID(signature: 0x41736B50, id: UInt32.random(in: 1...UInt32.max))
    let status = RegisterEventHotKey(keyCode, mods.carbonFlags, id, GetEventDispatcherTarget(), 0, &probe)
    if status == noErr { UnregisterEventHotKey(probe) }
    return status != noErr
}

/// 录制窗收到一组带修饰键的按键之后该怎么处理。
enum HotKeyRecording: Equatable {
    case unchanged     // 与当前组合相同，现有注册继续有效
    case unsupported   // 不支持的虚拟键码
    case taken         // 已被其他应用占用
    case accepted

    static func outcome(keyCode: UInt32, mods: NSEvent.ModifierFlags,
                        current: (code: UInt32, mods: NSEvent.ModifierFlags)) -> HotKeyRecording {
        guard isSupportedKeyCode(keyCode) else { return .unsupported }
        // 先判“组合没变”再探测占用：探测会把本进程自己的现有注册也算成已占用
        if keyCode == current.code, mods == current.mods { return .unchanged }
        return hotKeyIsTaken(keyCode: keyCode, mods: mods) ? .taken : .accepted
    }
}

/// 全局快捷键当前绑定的持有者。
/// 换绑时先注销旧组合再注册新组合：顺序反过来时，组合若与原来相同，新注册会因“已存在”失败，
/// 紧接着旧的又被释放，最后一个快捷键都不剩。
@MainActor
final class HotKeySlot {
    private var hotKey: CarbonHotKey?
    private var combo: (code: UInt32, mods: NSEvent.ModifierFlags)?
    private var previousHandler: (@MainActor @Sendable () -> Void)?

    /// 返回 false 表示没能换绑（被占用或按键不受支持），此时原有绑定保持不变。
    @discardableResult
    func bind(keyCode: UInt32, mods: NSEvent.ModifierFlags,
              handler: @escaping @MainActor @Sendable () -> Void) -> Bool {
        let previousCombo = combo
        let oldHandler = previousHandler
        hotKey = nil
        guard isSupportedKeyCode(keyCode),
              !hotKeyIsTaken(keyCode: keyCode, mods: mods),
              let next = CarbonHotKey(keyCode: keyCode, mods: mods, handler: handler) else {
            if let previousCombo, let oldHandler {
                hotKey = CarbonHotKey(keyCode: previousCombo.code, mods: previousCombo.mods, handler: oldHandler)
            }
            return false
        }
        combo = (keyCode, mods)
        previousHandler = handler
        hotKey = next
        return true
    }
}

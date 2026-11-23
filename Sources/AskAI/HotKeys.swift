import AppKit
import Carbon
import HotKey

// 快捷键配置（默认 ⌘⇧E；用菜单栏 🤖 →「设置快捷键…」改，自动存进 defaults）
let defaultHotKeyCode = UInt32(kVK_ANSI_E)
let defaultHotKeyMods = UInt(NSEvent.ModifierFlags.command.union(.shift).rawValue)

/// defaults 里当前配置的快捷键。
func configuredHotKey(defaults: UserDefaults = .standard) -> (code: UInt32, mods: NSEvent.ModifierFlags) {
    let code = UInt32(defaults.object(forKey: "hotkeyKey") as? Int ?? Int(defaultHotKeyCode))
    let raw = UInt(defaults.object(forKey: "hotkeyMods") as? Int ?? Int(defaultHotKeyMods))
    return (code, NSEvent.ModifierFlags(rawValue: raw))
}

func makeHotKey(keyCode: UInt32, mods: NSEvent.ModifierFlags, handler: @escaping () -> Void) -> HotKey? {
    guard Key(carbonKeyCode: keyCode) != nil else { return nil }
    return HotKey(keyCombo: KeyCombo(carbonKeyCode: keyCode, carbonModifiers: mods.carbonFlags),
                  keyDownHandler: handler)
}

/// 组合是否已被占用：别的进程持有，或本进程里还没注销的注册。
/// HotKey 库注册失败时静默返回，所以动手前先用 Carbon 探测一次。
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
    case unsupported   // HotKey 库不认识这个按键
    case taken         // 已被其他应用占用
    case accepted

    static func outcome(keyCode: UInt32, mods: NSEvent.ModifierFlags,
                        current: (code: UInt32, mods: NSEvent.ModifierFlags)) -> HotKeyRecording {
        guard Key(carbonKeyCode: keyCode) != nil else { return .unsupported }
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
    private var hotKey: HotKey?
    private var combo: KeyCombo?

    /// 返回 false 表示没能换绑（被占用或按键不受支持），此时原有绑定保持不变。
    @discardableResult
    func bind(keyCode: UInt32, mods: NSEvent.ModifierFlags, handler: @escaping () -> Void) -> Bool {
        let previous = combo
        hotKey = nil
        guard !hotKeyIsTaken(keyCode: keyCode, mods: mods),
              let next = makeHotKey(keyCode: keyCode, mods: mods, handler: handler) else {
            if let previous { hotKey = HotKey(keyCombo: previous, keyDownHandler: handler) }
            return false
        }
        combo = next.keyCombo
        hotKey = next
        return true
    }
}

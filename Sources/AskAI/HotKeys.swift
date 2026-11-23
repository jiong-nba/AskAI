import AppKit
import Carbon
import HotKey

// 快捷键配置（默认 ⌘⇧E；用菜单栏 🤖 →「设置快捷键…」改，自动存进 defaults）
let defaultHotKeyCode = UInt32(kVK_ANSI_E)
let defaultHotKeyMods = UInt(NSEvent.ModifierFlags.command.union(.shift).rawValue)
let hotkeyKeyCode = UInt32(defaults.object(forKey: "hotkeyKey") as? Int ?? Int(defaultHotKeyCode))
let hotkeyModsRaw = UInt(defaults.object(forKey: "hotkeyMods") as? Int ?? Int(defaultHotKeyMods))
let hotkeyText = defaults.string(forKey: "hotkeyDesc") ?? "⌘⇧E"

func makeHotKey(keyCode: UInt32, mods: NSEvent.ModifierFlags, handler: @escaping () -> Void) -> HotKey? {
    guard Key(carbonKeyCode: keyCode) != nil else { return nil }
    return HotKey(keyCombo: KeyCombo(carbonKeyCode: keyCode, carbonModifiers: mods.carbonFlags),
                  keyDownHandler: handler)
}

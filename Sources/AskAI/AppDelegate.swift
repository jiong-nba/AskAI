import AppKit
import ApplicationServices
import Carbon
import Darwin

// MARK: - 4. 菜单栏常驻 + 全局快捷键（快捷键可在菜单里自己录）

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let hotKeySlot = HotKeySlot()
    private var statusItem: NSStatusItem?   // 必须强引用！局部变量会被立即释放，图标就没了
    private var infoItem: NSMenuItem?
    private var setHotkeyItem: NSMenuItem?
    private var recorderPanel: NSPanel?
    private var keyMonitor: Any?
    private var recording = false
    private var settingsWindow: NSWindow?
    private var lastPanel: ResultPanel?        // 记住上一个结果窗，新结果出来时先关掉

    private var hotkeyDesc: String { defaults.string(forKey: "hotkeyDesc") ?? "⌘⇧E" }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "🤖"

        let menu = NSMenu()
        let info = NSMenuItem(title: L("选中文字后按 \(hotkeyDesc) 询问 AI", "Select text, then press \(hotkeyDesc)"), action: nil, keyEquivalent: "")
        infoItem = info
        menu.addItem(info)
        menu.addItem(.separator())

        // 模式切换（单选）
        let modeMenu = NSMenu()
        for m in PromptMode.all {
            let it = NSMenuItem(title: m.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m.key
            modeMenu.addItem(it)
        }
        let modeItem = NSMenuItem(title: L("模式", "Mode"), action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // 历史记录（子菜单，点条目直接回看）
        let histItem = NSMenuItem(title: L("历史记录", "History"), action: nil, keyEquivalent: "")
        histItem.submenu = NSMenu()
        menu.addItem(histItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: L("设置…", "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let setHotkey = NSMenuItem(title: L("设置快捷键…（当前 \(hotkeyDesc)）", "Set Hotkey… (now \(hotkeyDesc))"),
                                   action: #selector(openRecorder), keyEquivalent: "")
        setHotkey.target = self
        setHotkeyItem = setHotkey
        menu.addItem(setHotkey)

        let shot = NSMenuItem(title: L("截图解释…（图片里的文字）", "Explain from Screen… (text in images)"),
                              action: #selector(askFromScreen), keyEquivalent: "")
        shot.target = self
        menu.addItem(shot)

        // 重启：同一二进制重开，不会丢辅助功能授权（重建才会丢）
        let restart = NSMenuItem(title: L("重启 AskAI", "Restart AskAI"), action: #selector(relaunch), keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)

        let auth = NSMenuItem(title: L("打开辅助功能设置…", "Open Accessibility Settings…"),
                              action: #selector(openAccessibilitySettings), keyEquivalent: "")
        auth.target = self
        menu.addItem(auth)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("退出", "Quit"), action: #selector(NSApplication.terminate(_:)),
                               keyEquivalent: "q"))
        statusItem?.menu = menu
        menu.delegate = self
        refreshMenu()

        if !registerHotKey() { showHotKeyRegistrationFailure() }
        if ConnectionSettings.current().apiKey.isEmpty { openSettings() }
        else { promptForAccessibilityIfNeeded() }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = makeSettingsWindow { [weak self] in self?.settingsWindow?.close() }
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// 每次打开菜单时刷新勾选状态与历史条目
    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }

    private func refreshMenu() {
        guard let menu = statusItem?.menu else { return }
        let cur = currentMode().key
        for item in menu.items where item.submenu !== statusItem?.menu {
            if let sub = item.submenu, item.title == L("模式", "Mode") {
                for m in sub.items { m.state = (m.representedObject as? String) == cur ? .on : .off }
            }
        }
        if let hist = menu.items.first(where: { $0.title == L("历史记录", "History") })?.submenu {
            hist.removeAllItems()
            let list = loadHistory()
            if list.isEmpty {
                let empty = NSMenuItem(title: L("（暂无记录）", "(none)"), action: nil, keyEquivalent: "")
                empty.isEnabled = false
                hist.addItem(empty)
            } else {
                for h in list {
                    let t = h.source.replacingOccurrences(of: "\n", with: " ")
                    let label = t.count > 24 ? String(t.prefix(24)) + "…" : t
                    let it = NSMenuItem(title: label, action: #selector(showHistory(_:)), keyEquivalent: "")
                    it.target = self
                    it.representedObject = h
                    hist.addItem(it)
                }
                hist.addItem(NSMenuItem.separator())
                let clear = NSMenuItem(title: L("清空历史", "Clear History"), action: #selector(clearHistory), keyEquivalent: "")
                clear.target = self
                hist.addItem(clear)
            }
        }
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        defaults.set(key, forKey: "mode")
        refreshMenu()
    }

    @objc private func showHistory(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? HistoryEntry else { return }
        let panel = presentResult(source: entry.source)
        panel.show(entry)
    }

    @objc private func clearHistory() {
        clearHistoryStorage()
        refreshMenu()
    }

    // MARK: 重启与授权入口

    /// 用 -n 强制启动新实例，等 LaunchServices 接收请求后再退出当前实例（避免竞态）；
    /// 启动失败则保持运行，不会出现"旧的一退、新的一直没起来"。
    /// 同一二进制重启不会改变签名，所以辅助功能授权保持不变。
    @objc private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        do {
            try task.run()
        } catch {
            NSSound.beep()
            return
        }
        task.waitUntilExit()

        // 再确认新实例真的起来了（除了自己还有同 bundle id 的进程）才退出，
        // 最多等 2 秒；没起来就保持运行，绝不出现"旧的退了新的没有"。
        let bundleID = Bundle.main.bundleIdentifier ?? "com.dsh.AskAI"
        var newInstanceUp = false
        for _ in 0..<10 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
                newInstanceUp = true
                break
            }
            usleep(200_000)
        }
        if newInstanceUp {
            NSApp.terminate(nil)
        } else {
            NSSound.beep()
        }
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 未授权时弹系统对话框，并直接打开「隐私与安全性 → 辅助功能」，
    /// 免得用户在系统设置里找不到入口。
    private func promptForAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 注册全局快捷键。返回 false 表示没注册上（被其他应用占用或按键不受支持）。
    @discardableResult
    private func registerHotKey() -> Bool {
        infoItem?.title = L("选中文字后按 \(hotkeyDesc) 询问 AI", "Select text, then press \(hotkeyDesc)")
        setHotkeyItem?.title = L("设置快捷键…（当前 \(hotkeyDesc)）", "Set Hotkey… (now \(hotkeyDesc))")
        let current = configuredHotKey()
        return hotKeySlot.bind(keyCode: current.code, mods: current.mods) { [weak self] in
            self?.ask()
        }
    }

    /// 快捷键没注册上要明说，别让用户对着“按了没反应”猜。
    private func showHotKeyRegistrationFailure() {
        let alert = NSAlert()
        alert.messageText = L("快捷键 \(hotkeyDesc) 未能注册", "Hotkey \(hotkeyDesc) could not be registered")
        alert.informativeText = L("它可能已被其他应用占用，或这个按键不受支持。请到菜单栏 🤖 →「设置快捷键…」换一个组合。",
                                  "It may already be taken by another app, or the key is not supported. Choose another combination via 🤖 → Set Hotkey….")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private var capturingSelection = false

    private func ask() {
        guard !recording, !capturingSelection else { return }
        guard !ConnectionSettings.current().apiKey.isEmpty else { openSettings(); return }
        capturingSelection = true
        Task { @MainActor in
            defer { capturingSelection = false }
            do {
                if let text = try await selectedText() {
                    runQuery(source: text)
                } else {
                    askFromScreen()
                }
            } catch { /* Focus changed or capture was cancelled. */ }
        }
    }

    /// 截图选区 → OCR → 解释
    @objc private func askFromScreen() {
        guard !ConnectionSettings.current().apiKey.isEmpty else { openSettings(); return }
        guard let shot = captureRegion() else { return }   // 取消截图则静默返回
        guard let text = ocrText(from: shot) else {
            let alert = NSAlert()
            alert.messageText = L("没有识别到文字", "No text found")
            alert.informativeText = L("选区内未检测到可识别的文本，请重新框选。", "No recognizable text in that region. Try selecting it again.")
            alert.runModal()
            return
        }
        runQuery(source: text)
    }

    private func runQuery(source: String) {
        presentResult(source: source).request(mode: currentMode())
    }

    private func presentResult(source: String) -> ResultPanel {
        lastPanel?.close()
        let panel = ResultPanel(source: source)
        panel.delegate = self
        lastPanel = panel
        panel.showNearMouse()
        panel.makeKeyAndOrderFront(nil)
        return panel
    }

    // MARK: 快捷键录制窗口

    @objc private func openRecorder() {
        if recorderPanel != nil { return }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 140),
                            styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        panel.title = L("设置快捷键", "Set Hotkey")
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let label = NSTextField(labelWithString: L("按下新的快捷键组合\n需至少包含一个修饰键，Esc 取消", "Press the new shortcut\nAt least one modifier is required; Esc to cancel"))
        label.alignment = .center
        label.font = .systemFont(ofSize: 14)
        label.frame = NSRect(x: 20, y: 20, width: 360, height: 90)
        label.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(label)

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        recorderPanel = panel
        recording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === panel else { return event }
            return self.handleRecorderKey(event)
        }
    }

    private func handleRecorderKey(_ event: NSEvent) -> NSEvent? {
        let code = event.keyCode
        if code == UInt16(kVK_Escape) { closeRecorder(); return nil }

        // 单独的修饰键不算有效组合
        let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        if modifierKeyCodes.contains(code) { return nil }

        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !mods.isEmpty else { return nil }                  // 至少一个修饰键
        let takenMessage = L("这个组合已被其他应用占用，请换一个",
                             "This shortcut is already taken by another app; try another combination")
        switch HotKeyRecording.outcome(keyCode: UInt32(code), mods: mods, current: configuredHotKey()) {
        case .unsupported:   // 该键不受支持就提示，不改配置
            showRecorderMessage(L("这个按键暂不支持，请换一个组合", "That key is not supported; try another combination"))
        case .unchanged:
            closeRecorder()
        case .taken:
            showRecorderMessage(takenMessage)
        case .accepted:
            let previous = configuredHotKey()
            let previousDesc = hotkeyDesc
            saveHotKey(code: UInt32(code), mods: mods, desc: modifierSymbols(mods) + keyLabel(event))
            if registerHotKey() {
                closeRecorder()
            } else {
                // 探测之后、注册之前被别的应用抢走了：配置和绑定都退回原样
                saveHotKey(code: previous.code, mods: previous.mods, desc: previousDesc)
                registerHotKey()
                showRecorderMessage(takenMessage)
            }
        }
        return nil
    }

    private func saveHotKey(code: UInt32, mods: NSEvent.ModifierFlags, desc: String) {
        defaults.set(Int(code), forKey: "hotkeyKey")
        defaults.set(Int(mods.rawValue), forKey: "hotkeyMods")
        defaults.set(desc, forKey: "hotkeyDesc")
    }

    private func showRecorderMessage(_ text: String) {
        (recorderPanel?.contentView?.subviews.first as? NSTextField)?.stringValue = text
    }

    private func modifierSymbols(_ mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s
    }

    private func keyLabel(_ event: NSEvent) -> String {
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            return chars.uppercased()
        }
        return L("键\(event.keyCode)", "Key\(event.keyCode)")
    }

    private func closeRecorder() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        recording = false
        recorderPanel?.close()
        recorderPanel = nil
    }

    // MARK: 结果窗的生命周期

    /// 用户拖拽结束后记住浮窗尺寸，下次打开沿用
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel = notification.object as? ResultPanel else { return }
        ResultPanel.rememberSize(of: panel)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            settingsWindow = nil
            lastPanel?.refreshSummaryLimit()
            if !ConnectionSettings.current().apiKey.isEmpty { promptForAccessibilityIfNeeded() }
        }
        if window === recorderPanel {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            recording = false
            recorderPanel = nil
        }
        if window === lastPanel {
            lastPanel = nil
        }
    }
}

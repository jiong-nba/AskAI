// AskAI —— macOS 划词问 AI 小工具
// 用法：在任意 App 里选中文字 → 按 ⌘⇧E → 弹窗显示 AI 对这个名词/术语的解释
//
// 权限说明（精确版）：
//   · 读剪贴板（NSPasteboard）本身【不需要】任何系统权限；
//   · 需要「辅助功能」权限的是【向别的 App 模拟 ⌘C】这一步（CGEvent）。
//     授权对象是"运行本工具的那个 App"，做一次即可：
//     - 用 AskAI.app 启动（推荐）：系统设置 → 隐私与安全性 → 辅助功能 → 添加 AskAI.app
//       授权绑定 app 本身，长期有效；
//     - 用 swift run 启动：授权的是终端 App，且终端一关进程就被杀，只适合调试。
//
// API Key 配置（二选一）：
//   defaults write com.dsh.AskAI apiKey sk-你的密钥   # .app 方式，写一次永久生效
//   export ASKAI_KEY=sk-你的密钥                      # 命令行调试方式
// 可选：换模型 defaults write com.dsh.AskAI model deepseek-reasoner

import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import Darwin
import HotKey
import Vision

// MARK: - 配置

let defaults = UserDefaults.standard
let apiKey = ProcessInfo.processInfo.environment["ASKAI_KEY"]
    ?? defaults.string(forKey: "apiKey")
    ?? ""
let apiURL = URL(string: defaults.string(forKey: "baseURL")
                 ?? "https://api.deepseek.com/chat/completions")!  // 可换任意 OpenAI 兼容服务
let model = defaults.string(forKey: "model") ?? "deepseek-chat"

/// 单次请求最多发送的字符数（含 OCR 结果），防止超长文本超出上下文
let maxSourceChars = 2000

// MARK: - 提示词模式

struct PromptMode {
    let key: String
    let title: String
    let system: String
}

let promptModes: [PromptMode] = [
    PromptMode(key: "explain", title: "解释名词",
               system: "你是名词/术语解释助手，读者有计算机/数据库/软件工程背景。用户给出的通常是一个名词、术语或一小段文字。"
                     + "请用简体中文解释：如果原文是英文单词或术语，开头先给出它的中文翻译或对应说法；"
                     + "然后用一句话说清它是什么，再补充关键背景、机制或一个例子。"
                     + "技术术语优先按其领域含义解释（有歧义时点明），但不要预设具体技术栈、产品名或内部语境。"
                     + "不要翻译腔。控制在 150 字以内。"),
    PromptMode(key: "translate", title: "翻译",
               system: "你是翻译助手。把用户给出的文本翻译成简体中文；若原文本身是中文，则翻译成英文。"
                     + "只输出译文，不要解释、不要加引号或前缀。专业术语按通行译法。"),
    PromptMode(key: "summarize", title: "总结要点",
               system: "你是摘要助手。用简体中文概括用户文本的核心要点，最多 3 条，每条一行，以「• 」开头。"
                     + "保留关键数字与结论，删除铺垫和重复。不要输出原文。"),
    PromptMode(key: "code", title: "解释代码",
               system: "你是代码讲解助手。用简体中文解释用户给出的代码：先说它整体做什么，"
                     + "再按执行顺序说明关键语句的作用，最后指出可能的坑或副作用。控制在 200 字以内。"),
]

func currentMode() -> PromptMode {
    let key = defaults.string(forKey: "mode") ?? "explain"
    return promptModes.first { $0.key == key } ?? promptModes[0]
}

// MARK: - 历史记录

struct HistoryEntry {
    let time: Date
    let mode: String
    let source: String
    let answer: String
}

let historyKey = "history"
let historyLimit = 20

func loadHistory() -> [HistoryEntry] {
    guard let raw = defaults.array(forKey: historyKey) as? [[String: Any]] else { return [] }
    return raw.compactMap { d in
        guard let t = d["time"] as? Double, let m = d["mode"] as? String,
              let s = d["source"] as? String, let a = d["answer"] as? String else { return nil }
        return HistoryEntry(time: Date(timeIntervalSince1970: t), mode: m, source: s, answer: a)
    }
}

func saveHistory(_ entries: [HistoryEntry]) {
    let arr: [[String: Any]] = entries.prefix(historyLimit).map {
        ["time": $0.time.timeIntervalSince1970, "mode": $0.mode, "source": $0.source, "answer": $0.answer]
    }
    defaults.set(arr, forKey: historyKey)
}

func appendHistory(mode: String, source: String, answer: String) {
    guard !answer.isEmpty, !answer.hasPrefix("❌") else { return }
    var list = loadHistory()
    list.insert(HistoryEntry(time: Date(), mode: mode, source: source, answer: answer), at: 0)
    saveHistory(list)
}

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

// MARK: - 1. 抓取选中文本：模拟 ⌘C → 读剪贴板 → 还原剪贴板

func selectedText() -> String? {
    let pb = NSPasteboard.general
    let backup = pb.string(forType: .string) // 备份原有文本
    pb.clearContents() // 先清空，避免读到旧内容

    let src = CGEventSource(stateID: .combinedSessionState)
    func tapC(_ down: Bool) {
        let c = CGEvent(keyboardEventSource: src, virtualKey: 0x08 /* kVK_ANSI_C */, keyDown: down)
        c?.flags = .maskCommand
        c?.post(tap: .cghidEventTap)
    }
    tapC(true)
    usleep(30_000)
    tapC(false)
    usleep(250_000) // 给目标 App 一点完成复制的时间

    let text = pb.string(forType: .string)?
        .trimmingCharacters(in: .whitespacesAndNewlines)

    pb.clearContents() // 还原剪贴板
    if let backup { pb.setString(backup, forType: .string) }

    return (text?.isEmpty == false) ? text : nil
}

// MARK: - 2. 调用 LLM（OpenAI Chat Completions 格式）

func askLLM(_ text: String, mode: PromptMode, onDelta: ((String) -> Void)? = nil) async throws -> String {
    guard !apiKey.isEmpty else {
        throw NSError(domain: "AskAI", code: 0,
                      userInfo: [NSLocalizedDescriptionKey:
                            "未配置 API Key。请执行：defaults write com.dsh.AskAI apiKey sk-你的密钥，"
                          + "然后重启本 App（或改用环境变量 ASKAI_KEY）"])
    }

    // 超长文本（常见于截图 OCR）先截断，避免超出上下文
    var user = text
    if user.count > maxSourceChars {
        user = String(user.prefix(maxSourceChars)) + "\n…（后文已截断）"
    }

    var req = URLRequest(url: apiURL)
    req.httpMethod = "POST"
    req.timeoutInterval = 60
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let streaming = onDelta != nil
    var body: [String: Any] = [
        "model": model,
        "temperature": 0.3,
        "messages": [
            ["role": "system", "content": mode.system],
            ["role": "user", "content": user],
        ],
    ]
    if streaming { body["stream"] = true }
    req.httpBody = try JSONSerialization.data(withJSONObject: body)

    guard streaming else {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "AskAI", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "API 出错 (\(code)): \(errBody.prefix(200))"])
        }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = root?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        guard let content = message?["content"] as? String, !content.isEmpty else {
            throw NSError(domain: "AskAI", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "响应里没有 content"])
        }
        return content
    }

    // 流式：逐行解析 SSE，边到边刷新
    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
    guard code == 200 else {
        // 读取有限量错误信息后立即跳出：不让序列继续挂起等待
        var raw = ""
        var lines = 0
        for try await line in bytes.lines {
            raw += line
            lines += 1
            if raw.count > 300 || lines > 20 { break }
        }
        throw NSError(domain: "AskAI", code: code,
                      userInfo: [NSLocalizedDescriptionKey: "API 出错 (\(code)): \(raw.prefix(200))"])
    }

    var full = ""
    for try await line in bytes.lines {
        guard line.hasPrefix("data:") else { continue }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { break }
        guard let d = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let piece = delta["content"] as? String, !piece.isEmpty
        else { continue }
        full += piece
        onDelta?(full)
    }
    guard !full.isEmpty else {
        throw NSError(domain: "AskAI", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "流式响应没有内容"])
    }
    return full
}

// MARK: - 2.5 OCR：截图选区 → 识别文字（用于图片里不可复制的词）

func captureRegion() -> URL? {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("askai-shot-\(UUID().uuidString).png")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-i", "-x", "-t", "png", url.path]   // -i 交互选区，-x 静音
    do { try task.run() } catch { return nil }
    task.waitUntilExit()
    // 用户按 Esc 取消时不会产生文件
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

func ocrText(from url: URL) -> String? {
    defer { try? FileManager.default.removeItem(at: url) }
    guard let img = NSImage(contentsOf: url),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])

    let text = (request.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

// MARK: - 3. 结果浮窗（✕ 关闭 / Esc 关闭）

final class ResultPanel: NSPanel {
    var textView: NSTextView?
    private let speaker = AVSpeechSynthesizer()

    override func cancelOperation(_ sender: Any?) { close() }   // Esc 关闭

    @objc func copyResult() {
        guard let t = textView?.string, !t.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
        NSSound.beep()   // 轻提示已复制
    }

    @objc func speakResult() {
        guard let t = textView?.string, !t.isEmpty else { return }
        if speaker.isSpeaking { speaker.stopSpeaking(at: .immediate); return }
        let u = AVSpeechUtterance(string: t)
        // 含中文就用中文嗓音，否则用英文
        let hasCJK = t.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        u.voice = AVSpeechSynthesisVoice(language: hasCJK ? "zh-CN" : "en-US")
        u.rate = 0.5
        speaker.speak(u)
    }
}

func makePanel(selected: String) -> NSPanel {
    let short: String = selected.count > 30 ? String(selected.prefix(30)) + "…" : selected
    let W: CGFloat = 480, H: CGFloat = 280, bar: CGFloat = 34
    let panel = ResultPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                            styleMask: [.titled, .closable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
    panel.level = .floating
    panel.title = "AI 解释：\(short)"
    panel.isMovableByWindowBackground = true
    panel.becomesKeyOnlyIfNeeded = false   // 让它能立即响应 Esc

    let container = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
    container.autoresizingMask = [.width, .height]

    let scroll = NSScrollView(frame: NSRect(x: 0, y: bar, width: W, height: H - bar))
    scroll.autoresizingMask = [.width, .height]
    scroll.hasVerticalScroller = true

    let tv = NSTextView(frame: scroll.bounds)
    tv.isEditable = false
    tv.drawsBackground = false
    tv.textContainerInset = NSSize(width: 14, height: 12)
    tv.font = .systemFont(ofSize: 14)
    scroll.documentView = tv
    container.addSubview(scroll)

    // 底部按钮：复制 / 朗读
    let copyBtn = NSButton(title: "复制", target: panel, action: #selector(ResultPanel.copyResult))
    copyBtn.bezelStyle = .rounded
    copyBtn.frame = NSRect(x: W - 80, y: 6, width: 68, height: 24)
    copyBtn.autoresizingMask = [.minXMargin]
    container.addSubview(copyBtn)

    let speakBtn = NSButton(title: "朗读", target: panel, action: #selector(ResultPanel.speakResult))
    speakBtn.bezelStyle = .rounded
    speakBtn.frame = NSRect(x: W - 154, y: 6, width: 68, height: 24)
    speakBtn.autoresizingMask = [.minXMargin]
    container.addSubview(speakBtn)

    panel.textView = tv
    panel.contentView = container
    panel.center()
    return panel
}

func setPanelText(_ panel: NSPanel, _ text: String) {
    (panel as? ResultPanel)?.textView?.string = text
}

// MARK: - 4. 菜单栏常驻 + 全局快捷键（快捷键可在菜单里自己录）

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?   // 必须强引用！局部变量会被立即释放，图标就没了
    private var infoItem: NSMenuItem?
    private var setHotkeyItem: NSMenuItem?
    private var recorderPanel: NSPanel?
    private var keyMonitor: Any?
    private var recording = false
    private var lastPanel: NSPanel?        // 记住上一个结果窗，新结果出来时先关掉
    private var escMonitor: Any?           // 结果窗显示期间监听全局 Esc，保证一定能关

    private var hotkeyDesc: String { defaults.string(forKey: "hotkeyDesc") ?? "⌘⇧E" }

    func applicationDidFinishLaunching(_ note: Notification) {
        promptForAccessibilityIfNeeded()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "🤖"

        let menu = NSMenu()
        let info = NSMenuItem(title: "选中文字后按 \(hotkeyDesc) 询问 AI", action: nil, keyEquivalent: "")
        infoItem = info
        menu.addItem(info)
        menu.addItem(.separator())

        // 模式切换（单选）
        let modeMenu = NSMenu()
        for m in promptModes {
            let it = NSMenuItem(title: m.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m.key
            modeMenu.addItem(it)
        }
        let modeItem = NSMenuItem(title: "模式", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // 历史记录（子菜单，点条目直接回看）
        let histItem = NSMenuItem(title: "历史记录", action: nil, keyEquivalent: "")
        histItem.submenu = NSMenu()
        menu.addItem(histItem)

        menu.addItem(.separator())

        let setHotkey = NSMenuItem(title: "设置快捷键…（当前 \(hotkeyDesc)）",
                                   action: #selector(openRecorder), keyEquivalent: "")
        setHotkey.target = self
        setHotkeyItem = setHotkey
        menu.addItem(setHotkey)

        let shot = NSMenuItem(title: "截图解释…（图片里的文字）",
                              action: #selector(askFromScreen), keyEquivalent: "")
        shot.target = self
        menu.addItem(shot)

        // 重启：同一二进制重开，不会丢辅助功能授权（重建才会丢）
        let restart = NSMenuItem(title: "重启 AskAI", action: #selector(relaunch), keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)

        let auth = NSMenuItem(title: "打开辅助功能设置…",
                              action: #selector(openAccessibilitySettings), keyEquivalent: "")
        auth.target = self
        menu.addItem(auth)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)),
                               keyEquivalent: "q"))
        statusItem?.menu = menu
        menu.delegate = self
        refreshMenu()

        registerHotKey()
    }

    /// 每次打开菜单时刷新勾选状态与历史条目
    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }

    private func refreshMenu() {
        guard let menu = statusItem?.menu else { return }
        let cur = currentMode().key
        for item in menu.items where item.submenu !== statusItem?.menu {
            if let sub = item.submenu, item.title == "模式" {
                for m in sub.items { m.state = (m.representedObject as? String) == cur ? .on : .off }
            }
        }
        if let hist = menu.items.first(where: { $0.title == "历史记录" })?.submenu {
            hist.removeAllItems()
            let list = loadHistory()
            if list.isEmpty {
                let empty = NSMenuItem(title: "（暂无记录）", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                hist.addItem(empty)
            } else {
                for (i, h) in list.enumerated() {
                    let t = h.source.replacingOccurrences(of: "\n", with: " ")
                    let label = t.count > 24 ? String(t.prefix(24)) + "…" : t
                    let it = NSMenuItem(title: label, action: #selector(showHistory(_:)), keyEquivalent: "")
                    it.target = self
                    it.tag = i
                    hist.addItem(it)
                }
                hist.addItem(.separator())
                let clear = NSMenuItem(title: "清空历史", action: #selector(clearHistory), keyEquivalent: "")
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
        let list = loadHistory()
        guard sender.tag >= 0, sender.tag < list.count else { return }
        let h = list[sender.tag]
        lastPanel?.close()
        let panel = makePanel(selected: h.source)
        panel.delegate = self
        lastPanel = panel
        panel.title = "\(currentMode().title)｜历史：\(h.source.prefix(20))"
        setPanelText(panel, h.answer)
        panel.makeKeyAndOrderFront(nil)
        startEscMonitor()
    }

    @objc private func clearHistory() {
        defaults.removeObject(forKey: historyKey)
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

    private func registerHotKey() {
        infoItem?.title = "选中文字后按 \(hotkeyDesc) 询问 AI"
        setHotkeyItem?.title = "设置快捷键…（当前 \(hotkeyDesc)）"
        let code = UInt32(defaults.object(forKey: "hotkeyKey") as? Int ?? Int(defaultHotKeyCode))
        let raw = UInt(defaults.object(forKey: "hotkeyMods") as? Int ?? Int(defaultHotKeyMods))
        let mods = NSEvent.ModifierFlags(rawValue: raw)
        hotKey = makeHotKey(keyCode: code, mods: mods) { [weak self] in
            self?.ask()
        }
    }

    private func ask() {
        guard !recording else { return }   // 录制快捷键时不触发

        // 取不到选中文本时不再直接报错，自动降级为截图 OCR
        if let text = selectedText() {
            runQuery(source: text)
            return
        }
        guard let shot = captureRegion() else { return }   // 用户取消截图
        guard let text = ocrText(from: shot) else {
            let alert = NSAlert()
            alert.messageText = "没有识别到文字"
            alert.informativeText = "既没有取到选中文本，截图里也没识别出文字。"
                + "请确认本 App 已在「隐私与安全性 → 辅助功能」中被勾选。"
            alert.runModal()
            return
        }
        runQuery(source: text)
    }

    /// 截图选区 → OCR → 解释
    @objc private func askFromScreen() {
        guard let shot = captureRegion() else { return }   // 取消截图则静默返回
        guard let text = ocrText(from: shot) else {
            let alert = NSAlert()
            alert.messageText = "没有识别到文字"
            alert.informativeText = "选区内未检测到可识别的文本，请重新框选。"
            alert.runModal()
            return
        }
        runQuery(source: text)
    }

    private func runQuery(source: String) {
        lastPanel?.close()                 // 避免结果窗越堆越多
        let mode = currentMode()
        let panel = makePanel(selected: source)
        panel.delegate = self
        lastPanel = panel
        panel.title = "\(mode.title)：\(source.prefix(30))"
        setPanelText(panel, "思考中…")
        panel.makeKeyAndOrderFront(nil)
        startEscMonitor()

        Task.detached { [mode] in
            do {
                // 流式：边收边显示
                let answer = try await askLLM(source, mode: mode) { full in
                    DispatchQueue.main.async { setPanelText(panel, full) }
                }
                appendHistory(mode: mode.title, source: source, answer: answer)
            } catch {
                await MainActor.run { setPanelText(panel, "❌ \(error.localizedDescription)") }
            }
        }
    }

    // MARK: 快捷键录制窗口

    @objc private func openRecorder() {
        if recorderPanel != nil { return }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 140),
                            styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        panel.title = "设置快捷键"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let label = NSTextField(labelWithString: "按下新的快捷键组合\n需至少包含一个修饰键，Esc 取消")
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
        guard Key(carbonKeyCode: UInt32(code)) != nil else {     // 该键不受支持就提示，不改配置
            (recorderPanel?.contentView?.subviews.first as? NSTextField)?.stringValue =
                "这个按键暂不支持，请换一个组合"
            return nil
        }

        let desc = modifierSymbols(mods) + keyLabel(event)
        defaults.set(Int(code), forKey: "hotkeyKey")
        defaults.set(Int(mods.rawValue), forKey: "hotkeyMods")
        defaults.set(desc, forKey: "hotkeyDesc")
        registerHotKey()
        closeRecorder()
        return nil
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
        return "键\(event.keyCode)"
    }

    private func closeRecorder() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        recording = false
        recorderPanel?.close()
        recorderPanel = nil
    }

    // MARK: 结果窗的生命周期

    /// 全局监听 Esc：结果窗不一定是 key window，用系统级监听兜底，保证一定能关。
    private func startEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            DispatchQueue.main.async { self?.lastPanel?.close() }
        }
    }

    private func stopEscMonitor() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSPanel) === recorderPanel {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            recording = false
            recorderPanel = nil
        }
        if (notification.object as? NSPanel) === lastPanel {
            stopEscMonitor()
            lastPanel = nil
        }
    }
}

// MARK: - 配置自检：AskAI.app/Contents/MacOS/AskAI --check
// 用来确认「defaults 里写的 Key」和「App 实际读的域」是同一个，避免静默失效。

if CommandLine.arguments.contains("--check") {
    let bundleID = Bundle.main.bundleIdentifier ?? "(未在 .app 内运行)"
    let envKey = ProcessInfo.processInfo.environment["ASKAI_KEY"]
    let defaultsKey = defaults.string(forKey: "apiKey")
    print("bundle id        : \(bundleID)")
    print("defaults 域      : \(bundleID)   ← UserDefaults.standard 即读这里")
    print("env ASKAI_KEY    : \(envKey == nil ? "未设置" : "已设置(\(envKey!.count) 字符)")")
    print("defaults apiKey  : \(defaultsKey == nil ? "未设置" : "已设置(\(defaultsKey!.count) 字符)")")
    print("优先级           : env ASKAI_KEY > defaults com.dsh.AskAI/apiKey")
    print("生效模型         : \(model)")
    print("接口地址         : \(apiURL.absoluteString)")
    print("快捷键           : \(hotkeyText)（菜单栏 🤖 →「设置快捷键…」可改）")
    print("辅助功能授权     : \(AXIsProcessTrusted() ? "已授权" : "未授权（模拟 ⌘C 会失败）")")
    exit(0)
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // 常驻菜单栏，不占 Dock
app.run()

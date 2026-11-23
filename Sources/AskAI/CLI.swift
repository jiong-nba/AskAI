import AppKit
import ApplicationServices

// MARK: - 配置自检：AskAI.app/Contents/MacOS/AskAI --check
// 用来确认「defaults 里写的 Key」和「App 实际读的域」是同一个，避免静默失效。

func runCheck() -> Never {
    let connection = ConnectionSettings.current()
    let bundleID = Bundle.main.bundleIdentifier ?? L("(未在 .app 内运行)", "(not running inside a .app)")
    let envKey = ProcessInfo.processInfo.environment["ASKAI_KEY"]
    let defaultsKey = defaults.string(forKey: "apiKey")
    let yes = L("已设置", "set")
    let no  = L("未设置", "not set")
    print(L("bundle id        : ", "bundle id        : ") + bundleID)
    print(L("defaults 域      : ", "defaults domain  : ") + bundleID)
    print("env ASKAI_KEY    : " + (envKey == nil ? no : "\(yes) (\(envKey!.count) chars)"))
    print("defaults apiKey  : " + (defaultsKey == nil ? no : "\(yes) (\(defaultsKey!.count) chars)"))
    print(L("优先级           : env ASKAI_KEY > defaults apiKey", "precedence       : env ASKAI_KEY > defaults apiKey"))
    print(L("生效模型         : ", "model            : ") + connection.model)
    print(L("接口地址         : ", "endpoint         : ") + connection.url.absoluteString)
    if let bad = defaults.string(forKey: "baseURL"), ConnectionSettings.storedEndpoint(bad) == nil {
        print(L("⚠️ baseURL 配置「\(bad)」无效（应为完整 https:// 地址），已回落默认地址",
               "⚠️ configured baseURL '\(bad)' is invalid (expected a full https:// URL); using the default"))
    }
    let hotkeyText = defaults.string(forKey: "hotkeyDesc") ?? "⌘⇧E"
    print(L("快捷键           : ", "hotkey           : ") + hotkeyText)
    print(L("界面语言         : ", "ui language      : ") + (appIsChinese ? "zh-CN" : "en"))
    print(L("辅助功能授权     : ", "accessibility    : ")
          + (AXIsProcessTrusted() ? L("已授权", "granted") : L("未授权（模拟 ⌘C 会失败）", "NOT granted (⌘C simulation will fail)")))
    exit(0)
}

// MARK: - 命令行问答：AskAI --ask "要解释的文字"
// 用于端到端自测（真发一次请求 + 真实写历史），也可当作脚本工具使用。

func runAsk(arguments: [String]) -> Never {
    guard let i = arguments.firstIndex(of: "--ask"), i + 1 < arguments.count else {
        fputs(L("用法：AskAI --ask <文字>\n", "Usage: AskAI --ask <text>\n"), stderr)
        exit(EXIT_FAILURE)
    }
    let question = arguments[i + 1]
    let mode = currentMode()
    Task {
        do {
            let input = QueryInput(preview: question)
            let answer = try await askLLM(input, mode: mode, connection: .current())
            print(answer)
            do {
                try appendHistory(mode: mode.key, source: question, answer: answer)
            } catch {
                throw AskError(L("历史记录写入失败（\(historyFile.path)）：", "Could not write history (\(historyFile.path)): ")
                               + error.localizedDescription)
            }
            // history.json 读不出来时 appendHistory 会把它挪开重建：查询本身是成功的，但要让用户知道
            if let notice = HistoryNotice.shared.take() {
                fputs("warning: " + notice + "\n", stderr)
            }

            let attrs = try? FileManager.default.attributesOfItem(atPath: historyFile.path)
            let perms = (attrs?[.posixPermissions] as? NSNumber).map { String($0.intValue, radix: 8) }
            print("---")
            print(L("历史文件 : ", "history file : ") + historyFile.path)
            print(L("文件权限 : ", "file mode    : ") + (perms ?? L("文件不存在", "missing")))
            print(L("记录条数 : ", "entries      : ") + "\(loadHistory().count)")
            print(L("可解析   : ", "json round-trip : ") + (try readHistoryFile().isEmpty ? L("否", "failed") : L("是", "ok")))
        } catch {
            fputs(L("错误: ", "error: ") + error.localizedDescription + "\n", stderr)
            exit(EXIT_FAILURE)
        }
        exit(EXIT_SUCCESS)
    }
    dispatchMain()
}

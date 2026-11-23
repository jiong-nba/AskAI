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

// MARK: - 入口

// 命令行模式不启动菜单栏：处理完直接退出。
if CommandLine.arguments.contains("--check") { runCheck() }
if CommandLine.arguments.contains("--ask") { runAsk(arguments: CommandLine.arguments) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}

# AskAI —— macOS 划词问 AI 菜单栏小工具

在任意 App 里**选中文字 → 按快捷键 → 浮窗流式显示 AI 解释**。
轻量（约 300 KB / 22 MB 内存），无 Dock 图标，纯原生 Swift，单文件核心代码。

> 不是翻译工具：解释模式会先用中文说清这个词是什么，再补背景与例子。
> 也提供翻译、总结、代码讲解三种模式。

## 功能

- **划词解释**：选中文字 → 快捷键 → 流式逐字显示
- **四种模式**：解释名词 / 翻译 / 总结要点 / 解释代码（菜单切换，记住选择）
- **截图 OCR**：取不到选中文本时自动降级为框选截图，用 Vision 识别后解释
- **历史记录**：最近 20 条，菜单里点回看
- **朗读结果**：系统 TTS，中文/英文自动选嗓音
- **结果可复制**：浮窗「复制」按钮
- **快捷键自定义**：菜单里直接按键录制
- **兼容任意 OpenAI 格式接口**：DeepSeek / OpenAI / 本地 Ollama 等

## 快速开始

需要 macOS 13+ 与 Swift 工具链（安装 Xcode Command Line Tools 即可）。

```bash
git clone <this-repo>
cd AskAI
./make-app.sh                       # 编译并打包成 AskAI.app
defaults write com.dsh.AskAI apiKey sk-你的密钥
open AskAI.app                      # 菜单栏出现 🤖
./AskAI.app/Contents/MacOS/AskAI --check   # 自检：确认 Key 与授权状态
```

**首次必须授权**（模拟 ⌘C 取选中文本需要）：

> 系统设置 → 隐私与安全性 → 辅助功能 → ➕ 添加 `AskAI.app` → 打开开关

不授权时：取词会失败，但会自动降级为截图 OCR（Vision 不需要该权限）。

## 配置（全部走 `defaults`，无需改代码）

| 配置项 | 命令 |
|---|---|
| API Key | `defaults write com.dsh.AskAI apiKey sk-xxx` |
| 模型 | `defaults write com.dsh.AskAI model deepseek-chat` |
| 接口地址 | `defaults write com.dsh.AskAI baseURL "https://api.openai.com/v1/chat/completions"` |
| 快捷键 | 菜单 🤖 →「设置快捷键…」按键录制 |
| 模式 | 菜单 🤖 →「模式」 |
| 历史 | `defaults read com.dsh.AskAI history` |

环境变量 `ASKAI_KEY` 优先于 `defaults`（方便命令行调试）。

## 签名与授权持久性（重要）

macOS 按**代码签名**识别 App。ad-hoc 签名每次重建都会变，导致辅助功能授权失效。

本工具支持用**自签证书**签名，让授权一次长期有效：

```bash
# 1. 创建自签代码签名证书（命令行，一次性）
openssl req -x509 -newkey rsa:2048 -keyout k.pem -out c.pem -days 3650 -nodes \
  -subj "/CN=AskAI Local" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -legacy -inkey k.pem -in c.pem -out id.p12 -passout pass:askai
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P askai -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db c.pem
rm -f k.pem id.p12 c.pem

# 2. 之后都用它打包（cdhash 变、证书不变，授权不失效）
ASKAI_SIGN_ID="AskAI Local" ./make-app.sh
```

首次签名会弹「codesign 想要访问钥匙串」→ 点**始终允许**。

## 实现要点

| 环节 | 做法 |
|---|---|
| 全局快捷键 | [HotKey](https://github.com/soffes/HotKey) 库 |
| 取选中文本 | 模拟 ⌘C → 读剪贴板 → 还原原剪贴板 |
| 截图 OCR | `screencapture -i` + `Vision` 框架识别 |
| 流式输出 | `URLSession.bytes` 逐行解析 SSE |
| 浮窗 | 非激活 `NSPanel`，✕ 或 Esc 关闭 |
| 朗读 | `AVSpeechSynthesizer` |

## 隐私说明

- **API Key** 存在 `defaults`（`~/Library/Preferences/com.dsh.AskAI.plist`），明文，仅本机可读
- **历史记录**存在 `~/Library/Application Support/AskAI/history.json`，文件权限 `0600`（仅当前用户可读），最多 20 条，菜单「历史记录 → 清空历史」可一键删除
- 选中文本只发送到你配置的接口地址，工具本身不收集任何数据

## 已知局限

- 不可复制的文本（受保护界面、密码框）取词会失败，靠截图 OCR 兜底
- 部分 App 复制较慢，可在 `selectedText()` 里调大等待时间
- 单次请求最多发送 2000 字符（超出截断，避免超上下文）

## License

MIT
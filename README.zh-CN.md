# AskAI —— macOS 划词问 AI 小工具

在任意 App 里**选中文字 → 按快捷键 → 浮窗流式显示 AI 解释**。
轻量（约 300 KB / 22 MB 内存），无 Dock 图标，纯原生 Swift，核心代码单文件。

> 不是翻译工具：解释模式会先用中文说清这个词是什么，再补背景与例子。
> 另有翻译、总结、代码讲解三种模式。

**语言：** [English](README.md) | 简体中文

## 功能

- **划词解释**：选中文字 → 快捷键 → 流式逐字显示
- **四种模式**：解释名词 / 翻译 / 总结要点 / 解释代码（菜单切换，记住选择）
- **截图 OCR**：取不到选中文本时自动降级为框选截图，用 Vision 识别后解释
- **历史记录**：最近 20 条，菜单里点回看
- **朗读结果**：系统 TTS，中英文自动选嗓音
- **结果可复制**：浮窗「复制」按钮
- **快捷键自定义**：菜单里直接按键录制
- **兼容任意 OpenAI 格式接口**：DeepSeek / OpenAI / 本地 Ollama 等

## 环境要求

- macOS 13 或更高
- Swift 工具链（安装 Xcode Command Line Tools 即可）

## 快速开始

```bash
git clone https://github.com/jiong-nba/AskAI.git
cd AskAI
./make-app.sh                                  # 编译并打包成 AskAI.app
defaults write com.dsh.AskAI apiKey sk-你的密钥  # 或 export ASKAI_KEY=sk-...
open AskAI.app                                 # 菜单栏出现 🤖
./AskAI.app/Contents/MacOS/AskAI --check       # 自检：Key、接口、授权状态
```

**首次必须授权**（模拟 ⌘C 取选中文本需要）：

> 系统设置 → 隐私与安全性 → 辅助功能 → ➕ 添加 `AskAI.app` → 打开开关

不授权时取词会失败，但会自动降级为截图 OCR（Vision OCR 不需要该权限）。
原因与解决办法见[签名与授权](#签名与授权为什么授权总失效)。

## 配置

全部走 `defaults`，无需改代码。

| 配置项 | 命令 |
|---|---|
| API Key | `defaults write com.dsh.AskAI apiKey sk-xxx` |
| 模型 | `defaults write com.dsh.AskAI model deepseek-chat` |
| 接口地址 | `defaults write com.dsh.AskAI baseURL "https://api.openai.com/v1/chat/completions"` |
| 快捷键 | 菜单 🤖 →「设置快捷键…」按键录制 |
| 模式 | 菜单 🤖 →「模式」 |
| 历史 | 编辑 `~/Library/Application Support/AskAI/history.json` |
| 界面语言 | `defaults write com.dsh.AskAI lang zh`（或 `en`；默认跟随系统） |

环境变量 `ASKAI_KEY` 优先于 `defaults`，适合脚本与调试。

## 命令行

### `--check`

打印 App 实际读到的配置：bundle id、defaults 域、Key 来源、接口、模型、快捷键、辅助功能授权状态。
出问题时先跑它。

```bash
./AskAI.app/Contents/MacOS/AskAI --check
```

若显示两个来源都「未设置」，而你认为自己配过，说明 App 读的是另一个域——对照 `bundle id` 检查。

### `--ask "<文字>"`

端到端跑一次真实请求：打印答案、写入历史、并报告存储状态。可作冒烟测试，也可当普通命令行工具用。

```bash
./AskAI.app/Contents/MacOS/AskAI --ask "throttling"
```

```
**节流**：限制操作执行频率的机制……
---
历史文件 : /Users/you/Library/Application Support/AskAI/history.json
文件权限 : 600（600 = 仅本人可读）
记录条数 : 1
可解析   : 是（JSON 往返正常）
```

回复使用的模式取自当前选中模式（`defaults write com.dsh.AskAI mode translate` 可切换）。

## 签名与授权（为什么授权总失效）

macOS 按**代码签名**识别 App。ad-hoc 签名每次重建都会变，辅助功能授权随之静默失效——
这就是经典的「取不到选中文本」死循环。

用一次**自签证书**签名，身份即可跨重建保持稳定：

```bash
# 1. 创建自签代码签名证书（一次性）
openssl req -x509 -newkey rsa:2048 -keyout k.pem -out c.pem -days 3650 -nodes \
  -subj "/CN=AskAI Local" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -legacy -inkey k.pem -in c.pem -out id.p12 -passout pass:askai
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P askai -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db c.pem
rm -f k.pem id.p12 c.pem

# 2. 之后每次都用它签名（cdhash 变、证书不变）
ASKAI_SIGN_ID="AskAI Local" ./make-app.sh
```

首次签名会弹钥匙串授权，选**始终允许**。

若辅助功能列表里堆积了失效条目：

```bash
tccutil reset Accessibility com.dsh.AskAI
```

## 隐私说明

- **API Key** 存在 `defaults`（`~/Library/Preferences/com.dsh.AskAI.plist`），明文，仅本机
- **历史记录**存在 `~/Library/Application Support/AskAI/history.json`，权限 `0600`，最多 20 条，
  菜单「历史记录 → 清空历史」可一键删除
- 选中文本只发送到你配置的接口地址，工具本身不收集任何数据

## 实现要点

| 环节 | 做法 |
|---|---|
| 全局快捷键 | [HotKey](https://github.com/soffes/HotKey) |
| 取选中文本 | 模拟 ⌘C → 读剪贴板 → 还原原剪贴板 |
| 截图 OCR | `screencapture -i` + Vision 框架 |
| 流式输出 | `URLSession.bytes` 逐行解析 SSE |
| 浮窗 | 非激活 `NSPanel`，✕ 或 Esc 关闭 |
| 朗读 | `AVSpeechSynthesizer` |

## 已知局限

- 不可复制的文本（受保护界面、密码框）靠截图 OCR 兜底，识别有损失
- 部分 App 复制较慢，可在 `selectedText()` 里调大等待时间
- 单次请求最多发送 2000 字符（超出截断并标注）
- 界面与命令行输出支持中英双语，启动时按系统语言选择；改 `lang` 后需重启 App

## 参与开发

构建、签名与验证约定见 [AGENTS.md](AGENTS.md)。

## License

MIT
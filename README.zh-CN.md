# AskAI —— macOS 划词问 AI 小工具

在任意 App 里**选中文字 → 按快捷键 → 浮窗流式显示 AI 解释**。
原生 Swift 菜单栏应用，无 Dock 图标。

[下载 Mac 版（Apple Silicon）](https://github.com/jiong-nba/AskAI/releases/latest) · macOS 13 或更高版本

> 不是翻译工具：解释模式会先用中文说清这个词是什么，再补背景与例子。
> 另有翻译、总结、代码讲解三种模式。

**语言：** [English](README.md) | 简体中文

## 功能

- **划词解释**：选中文字 → 快捷键 → 流式逐字显示，停在底部时自动跟随滚动。
  回答中断时，浮窗保留已收到的文字并显示错误。只有完整回答才会进入历史记录。
- **四种模式**：解释名词 / 翻译 / 总结要点 / 解释代码。菜单栏记住默认模式；结果浮窗和历史条目也可用同一原文临时换模式，切换时会取消上一次请求。
- **截图 OCR**：取不到选中文本时自动降级为框选截图，用 Vision 识别后解释
- **历史记录**：最近 20 条，菜单里点回看
- **朗读结果**：系统 TTS，中英文自动选嗓音；朗读的是去掉 Markdown 符号后的正文
- **复制结果**：在浮窗按 ⌘C（或点「复制」按钮）复制回答的 Markdown 原文，不含思考过程；若已选中部分文字，⌘C 复制的是选区
- **就近显示**：结果浮窗出现在鼠标附近，长结果不必回屏幕正中查看
- **窗口可调**：拖拽调整结果浮窗大小，下次打开记住尺寸
- **Markdown 渲染**：回答里的粗体、斜体、行内代码、链接按行内语法渲染（块级语法按原文显示）
- **推理模型**：deepseek-reasoner 等的思考过程（reasoning_content）在正文上方实时展示，历史与复制保存的仍是正文
- **快捷键自定义**：菜单里直接按键录制；组合已被其他应用占用时会提示
- **兼容任意 OpenAI 格式接口**：DeepSeek / OpenAI / 本地 Ollama 等

## 快速开始

1. 从发布页下载 ZIP，解压后将 `AskAI.app` 拖入「应用程序」并打开。
2. 首次启动时，在设置窗填入聊天接口完整地址、模型和 API Key，点「测试连接」，然后保存。之后可从菜单栏 🤖 →「设置…」修改，保存后对下一次查询生效。若下载的是 v1.1.1 或更早版本，可用下方配置表里的命令配置。
3. 授予辅助功能权限，选中文字后按 **⌘⇧E**。

从源码构建需要 Swift 5.9+ 和 Xcode Command Line Tools：

```bash
git clone https://github.com/jiong-nba/AskAI.git
cd AskAI
./make-app.sh
open AskAI.app
```

直接取词和模拟复制都使用辅助功能权限。

> 系统设置 → 隐私与安全性 → 辅助功能 → ➕ 添加 `AskAI.app` → 打开开关

不授权时取词会失败，但会自动降级为截图 OCR（Vision OCR 不需要该权限）。
原因与解决办法见[签名与授权](#签名与授权为什么授权总失效)。

## 配置

原生设置窗与命令行共用 `defaults`。连接测试只向当前填写的接口发送一条固定的测试消息。

| 配置项 | 命令 |
|---|---|
| API Key | `defaults write com.dsh.AskAI apiKey sk-xxx` |
| 模型 | `defaults write com.dsh.AskAI model deepseek-chat` |
| 接口地址 | `defaults write com.dsh.AskAI baseURL "https://api.openai.com/v1/chat/completions"`（须为完整 `https://` 地址；填错时回落默认地址，`--check` 会提示） |
| 快捷键 | 菜单 🤖 →「设置快捷键…」按键录制 |
| 模式 | 菜单 🤖 →「模式」 |
| 历史 | 编辑 `~/Library/Application Support/AskAI/history.json` |
| 界面语言 | `defaults write com.dsh.AskAI lang zh`（或 `en`；默认跟随系统） |

语言回落规则：系统首选语言不是中文时，界面回落到英文，此时「翻译」模式的目标语言是英文
（若原文本身是英文，则译为简体中文，避免原样输出）。在非中文系统上想用中文界面，请显式设置 `lang`。

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

端到端跑一次真实请求：打印答案、写入历史、并报告存储状态。成功时退出码为 0。请求失败时，诊断写入标准错误，退出码为非零。

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

指定的签名身份不可用或签名校验失败时，脚本会报错退出，保留上次构建的 App。

首次签名会弹钥匙串授权，选**始终允许**。

若辅助功能列表里堆积了失效条目：

```bash
tccutil reset Accessibility com.dsh.AskAI
```

## 隐私说明

- **API Key** 存在 `defaults`（`~/Library/Preferences/com.dsh.AskAI.plist`），明文，仅本机
- **历史记录**存在 `~/Library/Application Support/AskAI/history.json`，权限 `0600`，最多 20 条，
  菜单栏和命令行并发查询共用这 20 条记录，可通过「历史记录 → 清空历史」删除。
  文件读不出来时（例如手动编辑改坏了），会另存为 `history.corrupt-<时间戳>.json` 并重建，浮窗和 `--ask` 都会提示
- 选中文本只发送到你配置的接口地址，工具本身不收集任何数据

## 实现要点

| 环节 | 做法 |
|---|---|
| 全局快捷键 | [HotKey](https://github.com/soffes/HotKey) |
| 取选中文本 | 优先直接读辅助功能选区；回退时模拟 ⌘C，检测剪贴板更新后还原 |
| 截图 OCR | `screencapture -i` + Vision 框架 |
| 流式输出 | `URLSession.bytes` 逐行解析 SSE |
| 浮窗 | 非激活 `NSPanel`，出现在鼠标附近，✕ 或 Esc 关闭 |
| 朗读 | `AVSpeechSynthesizer` |

## 已知局限

- 不可复制的文本（受保护界面、密码框）靠截图 OCR 兜底，识别有损失
- 默认发送前 2,000 个原文字符，浮窗显示本次字符数与原文总数。长文可点「总结全文」，将整段原文发给当前模型。全文上限默认 16,000 个原文字符，在设置里可按模型调整；服务商另有 token 限制。命令行 `--ask` 沿用 2,000 字符预览。
- 界面与命令行输出支持中英双语，启动时按系统语言选择；改 `lang` 后需重启 App

## 参与开发

构建、签名与验证约定见 [AGENTS.md](AGENTS.md)。

## License

MIT
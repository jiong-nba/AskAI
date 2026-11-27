### Explain presets and Windows support

Choose a reader background in Settings on either platform. Six presets tailor the explanation. For example, software engineering emphasizes mechanisms and boundary cases, while business emphasizes incentives and trade-offs. Type a custom background or clear the field for a general explanation.

- **macOS 13+, Apple Silicon**. Unzip the macOS archive, move AskAI.app to Applications and open it. The ad-hoc signed app is not notarized. On macOS 15 or newer, open it once, then choose System Settings → Privacy & Security → Open Anyway. On older macOS versions, right-click → Open. Configure the provider in Settings. For command-line configuration, use `defaults write com.dsh.AskAI apiKey "YOUR_KEY"` or supply `ASKAI_KEY` in the app's launch environment. Run `/Applications/AskAI.app/Contents/MacOS/AskAI --check` to verify. Grant Accessibility and press ⌘⇧E on a selection.
- **Windows 10/11 x64, .NET Framework 4.8**. Extract the Windows ZIP and open AskAI.exe. The executable is unsigned. In Settings enter a chat completions endpoint, model and API key (or set ASKAI_KEY before launch). Press Ctrl+Shift+E on selected text, or paste it into the window and click Explain.

### 中文说明

两端均支持六种领域预设与自定义背景。Mac 用户解压后将应用移到「应用程序」，首次打开按上方说明通过 Gatekeeper 并授予辅助功能权限。Windows 用户解压整个 ZIP，运行 AskAI.exe，在「设置」填入接口、模型与密钥后即可用 Ctrl+Shift+E 划词解释。

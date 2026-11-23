# AskAI — Ask AI about any selected text on macOS

A tiny menu-bar app for macOS: **select text anywhere → press a hotkey → a floating window streams an explanation from your LLM**.

Lightweight (~300 KB on disk, ~22 MB resident), no Dock icon, native Swift, single-file core.

> Not a translation tool. The default *Explain* mode tells you what a term means in plain Chinese,
> then adds context and an example. Three more modes are included: Translate, Summarize, Explain Code.

**Languages:** English | [简体中文](README.zh-CN.md)

## Features

- **Explain selection** — select text, press the hotkey, watch the answer stream in
  If a stream is interrupted, the panel keeps the partial answer and shows the error. Only completed answers enter history.
- **Four modes** — Explain / Translate / Summarize / Explain Code (switch from the menu, remembered)
- **Screenshot OCR** — if no text can be read from the selection, it falls back to a screen-region capture and Vision OCR
- **History** — last 20 entries, reopen any from the menu
- **Read aloud** — system TTS, picks a Chinese or English voice automatically
- **Copy result** — one click
- **Custom hotkey** — record it right in the menu
- **Any OpenAI-compatible endpoint** — DeepSeek, OpenAI, Ollama, etc.

## Requirements

- macOS 13 or later
- Swift toolchain (install Xcode Command Line Tools)

## Quick start

```bash
git clone https://github.com/jiong-nba/AskAI.git
cd AskAI
./make-app.sh                                  # build + bundle into AskAI.app
defaults write com.dsh.AskAI apiKey sk-YOUR-KEY  # or export ASKAI_KEY=sk-...
open AskAI.app                                 # 🤖 appears in the menu bar
./AskAI.app/Contents/MacOS/AskAI --check       # sanity check: key, endpoint, permission
```

**Grant Accessibility permission once** (required to read the selection by simulating ⌘C):

> System Settings → Privacy & Security → Accessibility → ➕ add `AskAI.app` → toggle on

Without it, text capture fails and the app falls back to screenshot OCR
(Vision OCR does not need this permission). See [Signing & permissions](#signing--why-your-grant-keeps-resetting).

## Configuration

Everything is stored in `defaults` — no code edits needed.

| What | Command |
|---|---|
| API key | `defaults write com.dsh.AskAI apiKey sk-xxx` |
| Model | `defaults write com.dsh.AskAI model deepseek-chat` |
| Endpoint | `defaults write com.dsh.AskAI baseURL "https://api.openai.com/v1/chat/completions"` (must be a full `https://` URL; an invalid value falls back to the default endpoint and `--check` prints a warning) |
| Hotkey | Menu 🤖 → "Set Hotkey…" and press the combination |
| Mode | Menu 🤖 → "Mode" |
| History | Edit `~/Library/Application Support/AskAI/history.json` |
| UI language | `defaults write com.dsh.AskAI lang en` (or `zh`; default follows macOS) |

Language fallback: any preferred system language other than Chinese falls back to the English UI,
and the Translate mode targets English in that case (English input is translated into Simplified
Chinese instead of being a no-op). Set `lang` explicitly if you want Chinese UI on a non-Chinese system.

`ASKAI_KEY` (environment variable) takes precedence over `defaults`, which is convenient for scripts and debugging.

## Command line

Two flags are available on the bundled binary (or via `swift run -- --check`):

### `--check`

Prints what the app actually sees: bundle id, defaults domain, key source, endpoint, model, hotkey,
and whether Accessibility is granted. Use it first whenever something does not work.

```bash
./AskAI.app/Contents/MacOS/AskAI --check
```

```
bundle id        : com.dsh.AskAI
defaults domain  : com.dsh.AskAI
env ASKAI_KEY    : not set
defaults apiKey  : set (35 chars)
precedence       : env ASKAI_KEY > defaults apiKey
model            : deepseek-chat
endpoint         : https://api.deepseek.com/chat/completions
hotkey           : ⌘⇧E
ui language      : en
accessibility    : granted
```

Output follows the UI language (`defaults write com.dsh.AskAI lang zh` for Chinese).
If it reports `not set` for both key sources while you believe you configured one, the app is reading a
different domain — check `bundle id` against the domain you wrote to.

### `--ask "<text>"`

Runs a real query end to end, prints the answer, writes it to history, and reports storage state.
Successful queries exit with status 0. Request failures write a diagnostic to stderr and exit with a nonzero status.

```bash
./AskAI.app/Contents/MacOS/AskAI --ask "throttling"
```

```
Idempotency means an operation can be repeated without changing the result...
---
history file : /Users/you/Library/Application Support/AskAI/history.json
file mode    : 600
entries      : 1
json round-trip : ok
```

The reply follows whichever mode is currently selected (`defaults write com.dsh.AskAI mode translate` to change it).

## Signing & why your grant keeps resetting

macOS identifies an app by its **code signature**. An ad-hoc signed app gets a new identity on every
rebuild, so the Accessibility grant silently stops applying — the classic "cannot read selection" loop.

Sign with a **self-signed certificate** once and the identity stays stable across rebuilds:

```bash
# 1. create a self-signed code-signing certificate (one time)
openssl req -x509 -newkey rsa:2048 -keyout k.pem -out c.pem -days 3650 -nodes \
  -subj "/CN=AskAI Local" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -legacy -inkey k.pem -in c.pem -out id.p12 -passout pass:askai
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P askai -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db c.pem
rm -f k.pem id.p12 c.pem

# 2. sign every build with it (cdhash changes, certificate does not)
ASKAI_SIGN_ID="AskAI Local" ./make-app.sh
```

If the requested identity is unavailable or signature verification fails, the build exits with an error and keeps the previous app bundle.

The first signature triggers a Keychain prompt — choose **Always Allow**.

If the Accessibility list has accumulated stale entries, clear them:

```bash
tccutil reset Accessibility com.dsh.AskAI
```

## Privacy

- **API key** lives in `defaults` (`~/Library/Preferences/com.dsh.AskAI.plist`), plain text, local only
- **History** lives in `~/Library/Application Support/AskAI/history.json`, permissions `0600`, max 20 entries;
  concurrent CLI and menu-bar queries share the same 20 entries. Use "History → Clear History" to delete them
- Selected text is sent only to the endpoint you configured; the app collects nothing

## How it works

| Step | Implementation |
|---|---|
| Global hotkey | [HotKey](https://github.com/soffes/HotKey) |
| Read selection | simulate ⌘C → read pasteboard → restore previous clipboard |
| Screenshot OCR | `screencapture -i` + Vision framework |
| Streaming | `URLSession.bytes` + SSE line parsing |
| Floating window | non-activating `NSPanel`, close with ✕ or Esc |
| Speech | `AVSpeechSynthesizer` |

## Limitations

- Text that cannot be copied (protected views, password fields) falls back to OCR, which is lossy
- A few apps copy slowly; raise the delay in `selectedText()` if needed
- Requests are capped at 2000 characters of source text (truncated with a marker)
- UI and CLI output are bilingual (zh/en), chosen from the system language at launch; changing `lang` requires a restart

## Contributing

See [AGENTS.md](AGENTS.md) for build, signing and verification conventions.

## License

MIT
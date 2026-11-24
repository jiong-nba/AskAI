# AskAI — Ask AI about any selected text on macOS

A tiny menu-bar app for macOS: **select text anywhere → press a hotkey → a floating window streams an explanation from your LLM**.

Native Swift menu-bar app with no Dock icon.

[Download for Mac (Apple Silicon)](https://github.com/jiong-nba/AskAI/releases/latest) · macOS 13 or later

> Not a translation tool. The default *Explain* mode tells you what a term means in plain Chinese,
> then adds context and an example. Three more modes are included: Translate, Summarize, Explain Code.

**Languages:** English | [简体中文](README.zh-CN.md)

## Features

- **Explain selection** — select text, press the hotkey, watch the answer stream in;
  it auto-scrolls while you stay at the bottom.
  If a stream is interrupted, the panel keeps the partial answer and shows the error. Only completed answers enter history.
- **Four modes** — Explain / Translate / Summarize / Explain Code — choose a default in the menu bar, or rerun the same selection in a different mode from a result or history window. Switching cancels the previous request and starts a fresh conversation.
- **Screenshot OCR** — if no text can be read from the selection, it falls back to a screen-region capture and Vision OCR
- **History** — last 20 entries, reopen any from the menu; each entry is listed with its mode and age, and shows the full text on hover
- **Read aloud** — system TTS, picks a Chinese or English voice automatically; reads the answers of all turns without Markdown symbols
- **Copy result** — press ⌘C in the panel (or click Copy) to copy the whole conversation as Markdown source, without the reasoning trace; with text selected, ⌘C copies the selection
- **Near the cursor** — the panel opens next to the selection instead of screen center
- **Follow-up questions** — type a question at the bottom of the panel and press Return; earlier turns are sent back as context (the last 8). Follow-up answers go to history with their question, marked `↳`
- **Stop / Retry** — stop a running answer and keep what has arrived; after a stop or an error, retry with one click
- **Resizable** — drag to resize the result panel; the size is remembered, and pulled back on screen when it no longer fits the display in use
- **Markdown rendering** — bold, italic, inline code and links in answers are rendered; fenced code blocks are shown in a monospaced font (other block syntax is shown verbatim)
- **Reasoning models** — the thinking trace (reasoning_content, e.g. deepseek-reasoner) streams above the answer; history and copy keep the final answer
- **Custom hotkey** — record it right in the menu; the recorder tells you when another app already uses the combination
- **Any OpenAI-compatible endpoint** — DeepSeek, OpenAI, Ollama, etc. Settings offers the common addresses as presets, and endpoints on `localhost` need no API key
- **Answer language of its own** — answers follow the UI language by default; choose Chinese or English separately in Settings
- **Custom modes** — add your own modes (a name and a system prompt) via 🤖 → "Manage Modes…"; they appear in the Mode menu and in the panel's mode picker

## Quick start

1. Download the ZIP from the release page, unzip it, move `AskAI.app` to Applications, and open it.
2. On first launch, pick your provider in Settings (or enter its chat completions endpoint), then the model and API key. Endpoints on `localhost` need no key. Click **Test Connection**, then **Save**. Reopen Settings from the 🤖 menu to change providers for the next query. For v1.1.1 and earlier downloads, use the configuration commands below.
3. Grant Accessibility access, select text, and press **⌘⇧E**.

> The release is ad-hoc signed and not notarized, so Gatekeeper blocks the first launch.
> On macOS 15 or later, try to open it once, then go to System Settings → Privacy & Security and click
> **Open Anyway**. On earlier versions, right-click `AskAI.app` → **Open**.
> `xattr -dr com.apple.quarantine /Applications/AskAI.app` clears the flag directly.

Building from source requires Swift 5.9+ and Xcode Command Line Tools:

```bash
git clone https://github.com/jiong-nba/AskAI.git
cd AskAI
./make-app.sh
open AskAI.app
```

Both direct selection capture and simulated Copy use Accessibility permission.

> System Settings → Privacy & Security → Accessibility → ➕ add `AskAI.app` → toggle on

Without it, text capture fails and the app falls back to screenshot OCR
(Vision OCR does not need this permission). See [Signing & permissions](#signing--why-your-grant-keeps-resetting).

The screenshot itself needs **Screen Recording** permission (System Settings → Privacy & Security →
Screen Recording): until it is granted, the capture has no window content and OCR finds no text.

## Configuration

Settings and the CLI share the same `defaults` preferences. Test Connection sends a fixed probe to the endpoint in the form.

| What | Command |
|---|---|
| API key | `defaults write com.dsh.AskAI apiKey sk-xxx` |
| Model | `defaults write com.dsh.AskAI model deepseek-chat` |
| Endpoint | `defaults write com.dsh.AskAI baseURL "https://api.openai.com/v1/chat/completions"` (a full `http://` or `https://` URL — `http` for an endpoint on your own machine; an invalid value falls back to the default endpoint and `--check` prints a warning) |
| Hotkey | Menu 🤖 → "Set Hotkey…" and press the combination |
| Mode | Menu 🤖 → "Mode" |
| Custom modes | Menu 🤖 → "Manage Modes…" (kept in `defaults` as JSON under `customModes`) |
| History | Edit `~/Library/Application Support/AskAI/history.json` |
| UI language | `defaults write com.dsh.AskAI lang en` (or `zh`; default follows macOS) |
| Temperature | `defaults write com.dsh.AskAI temperature 0.3` (0–2; `-1` = do not send it and use the provider default. OpenAI's reasoning models such as the o-series and GPT-5 reject any other value, so use `-1` for them) |
| Copy fallback wait | `defaults write com.dsh.AskAI copyTimeoutMs 350` (how long to wait for ⌘C before falling back to screenshot OCR; raise it for slow apps, 100–5000) |
| Answer language | `defaults write com.dsh.AskAI answerLanguage zh` (or `en`; unset = follow the UI language) |
| Save history | `defaults write com.dsh.AskAI saveHistory false` (stop adding entries; existing ones stay until you clear them) |

Language fallback: any preferred system language other than Chinese falls back to the English UI,
and the Translate mode targets English in that case (English input is translated into Simplified
Chinese instead of being a no-op). Set `lang` explicitly if you want Chinese UI on a non-Chinese system, and `answerLanguage` to choose the answer language on its own.

`ASKAI_KEY` (environment variable) takes precedence over `defaults`, which is convenient for scripts and debugging.
An empty `ASKAI_KEY` counts as unset.

## Command line

Two flags are available on the bundled binary (or via `swift run -- --check`):

### `--check`

Prints what the app actually sees: bundle id, defaults domain, key source, endpoint, model, temperature, hotkey,
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
temperature      : 0.3
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

Add `--stream` to print the answer as it arrives. A non-streaming request waits at most 60 seconds for the whole
answer, which reasoning models can exceed; `--stream` has no such limit:

```bash
./AskAI.app/Contents/MacOS/AskAI --ask "throttling" --stream
```

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
  concurrent CLI and menu-bar queries share the same 20 entries. Use "History → Clear History" to delete them,
  or `saveHistory false` to stop adding new ones.
  If the file cannot be read (for example after an interrupted hand edit), it is moved aside as
  `history.corrupt-<timestamp>.json` and a fresh one is started; the panel and `--ask` say so when that happens
- Selected text is sent only to the endpoint you configured; the app collects nothing

## How it works

| Step | Implementation |
|---|---|
| Global hotkey | [HotKey](https://github.com/soffes/HotKey) |
| Read selection | Read the Accessibility selection first. Fall back to ⌘C, wait for a pasteboard change, then restore the previous clipboard |
| Screenshot OCR | `screencapture -i` + Vision framework |
| Streaming | `URLSession.bytes` + SSE line parsing |
| Floating window | non-activating `NSPanel` shown near the cursor; close with ✕, or with Esc while the panel has the focus (Esc pressed inside another app leaves it open) |
| Speech | `AVSpeechSynthesizer` |

## Limitations

- Text that cannot be copied (protected views, password fields) falls back to OCR, which is lossy
- Queries preview the first 2,000 source characters. The panel shows the count used and the original length. **Summarize All** sends the entire selection up to the limit in Settings (16,000 characters by default). Set this for your model; the provider also enforces its token limit. CLI `--ask` keeps the 2,000-character preview.
- UI and CLI output are bilingual (zh/en), chosen from the system language at launch; changing `lang` requires a restart

## Contributing

See [AGENTS.md](AGENTS.md) for build, signing and verification conventions.

## License

MIT
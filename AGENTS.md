# AGENTS.md

Instructions for AI coding agents (and human contributors) working on this repository.

## What this project is

A native macOS menu-bar app that reads the current selection, sends it to an
OpenAI-compatible endpoint, and streams the answer into a floating panel. CLI regression tests use a local HTTP fixture. The app has no server side.

## Layout

```
Sources/AskAI/main.swift              # process entry: CLI dispatch, then the menu-bar run loop
Sources/AskAI/AppDelegate.swift       # menu, hotkey recorder, panel and settings-window lifecycle
Sources/AskAI/CLI.swift               # --check and --ask
Sources/AskAI/Preferences.swift       # the shared `defaults` instance
Sources/AskAI/Localization.swift      # L(zh, en)
Sources/AskAI/PromptMode.swift        # built-in prompt modes
Sources/AskAI/History.swift           # history.json storage and the cross-process lock
Sources/AskAI/HotKeys.swift           # hotkey defaults and registration
Sources/AskAI/ChatClient.swift        # chat completions request and SSE stream parsing
Sources/AskAI/OCR.swift               # region capture and Vision OCR
Sources/AskAI/Selection.swift         # Accessibility and pasteboard capture
Sources/AskAI/ResultPanel.swift       # per-selection requests and result controls
Sources/AskAI/ConnectionSettings.swift # live provider configuration and native settings
Sources/AskAI/ModesSettings.swift      # user-defined prompt modes and the window that edits them
Package.swift              # SwiftPM manifest, depends on HotKey
make-app.sh                # builds a release binary and assembles AskAI.app (Info.plist + codesign)
README.md                  # English, primary
README.zh-CN.md            # Chinese translation — keep in sync
```

## Build and run

```bash
swift build -c release                 # compile only
ASKAI_SIGN_ID="AskAI Local" ./make-app.sh   # full build + bundle + sign
open AskAI.app
```

`make-app.sh` runs `swift build -c release`, assembles `AskAI.app`, signs it, and then runs
`codesign --verify --strict`. If signing fails, the script exits non-zero — do not ignore that.

## Non-negotiable invariants

1. **Never rebuild the installed app with an ad-hoc signature.** Accessibility permission (TCC) is keyed to
   the code signature; an ad-hoc rebuild invalidates the user's grant and sends them into a re-authorization
   loop. Always sign with a stable identity (`ASKAI_SIGN_ID="AskAI Local"`). If a change only touches data
   (hotkey, key, model), do not rebuild at all — those live in `defaults`.
2. **Never put secrets in the repo.** The API key lives in `defaults`. Before committing, check that no
   `sk-...` string and no personal absolute path (`/Users/<name>`) leaked into sources or docs.
3. **Keep both READMEs in sync.** Any user-visible change (flag, config key, feature) must land in
   `README.md` and `README.zh-CN.md`, and in the release notes of the next tag.
4. **Do not grow the dependency list without a reason.** The app's selling point is being small. The
   durable limits are **~1 MB bundle** and **~60 MB resident**; approaching either needs a justification.
   For orientation only — a snapshot, not a target: at v1.1.1 (Apple Silicon, release build) the bundle was
   ~580 KB and RSS ~45 MB. Re-measure (`du -sh AskAI.app`, `ps -o rss=`) instead of trusting these numbers;
   they will drift. Anything that ships assets (dictionary data, OCR models, fonts) is out of scope.

## Verifying a change

GitHub Actions (`.github/workflows/ci.yml`) runs the checks below on every push and pull request; a PR is
ready to merge only when that run is green.

Run `swift test --disable-xctest` with Swift 6+ to check streaming completion and interruption.
After a release build, run `python3 Tests/test_cli.py` to exercise the CLI against a local fixture with isolated history.

```bash
./AskAI.app/Contents/MacOS/AskAI --check        # config, endpoint, permission state
./AskAI.app/Contents/MacOS/AskAI --ask "throttling"   # real request + history round trip
```

`--ask` exercises the non-streaming API call, history persistence, and file permissions. Run it after touching any of those. It costs one small API
call, so do not loop on it.

When verifying accessibility state, remember that `--check` launched from a terminal may report the terminal's
grant rather than the app's; the authoritative signals are the toggle in System Settings and the app's own
behaviour.

Run `bash Tests/test_packaging.sh` after changing the packager. It checks signing and replacement in a temporary directory.

`swift build -Xswiftc -strict-concurrency=complete` must report nothing that is an error in the Swift 6 language
mode; CI fails otherwise. The package builds with zero diagnostics under it today. Three things trip it:
closures that cross into nonisolated code must be `@Sendable` (streaming callbacks are `StreamCallback`, i.e.
`@MainActor @Sendable`, because they touch the panel); read `AttributedString` attributes with
`run[Attribute.self]`, since the dot accessors go through key paths; and reference globals imported from C
(`kAXTrustedCheckOptionPrompt`) only behind `@preconcurrency import`.

## Code conventions

- Swift 5.9+, macOS 13+ target, no force-unwraps except for compile-time literals (URL, key codes)
- All UI work on the main thread; network work in `Task`, UI updates via `DispatchQueue.main.async` or `MainActor`
- User-facing strings go through `L(zh, en)`; never hardcode a single language in UI code. Docs are bilingual and must stay in sync
- Split by responsibility, not by size: `AppDelegate.swift` (menu, recorder, window lifecycle), `CLI.swift`,
  `History.swift`, `HotKeys.swift`, `ChatClient.swift`, `OCR.swift`, `PromptMode.swift`, `Selection.swift`
  (capture), `ResultPanel.swift` (panel + per-selection requests), `ConnectionSettings.swift` (provider config
  and settings UI). `main.swift` is only the entry point. Give a new responsibility its own file rather than
  letting any file grow past ~900 lines
- Comments explain *why*, not *what*
- Tests never touch real preference domains. Use `InMemoryDefaults` from `Tests/AskAITests/TestSupport.swift`
  instead of `UserDefaults(suiteName:)` — even a removed suite leaves an empty plist in `~/Library/Preferences` —
  and pass `connection:` / `defaults:` into panels instead of reading `.standard`, which is the test runner's
  real domain (`swiftpm-testing-helper`) and keeps whatever a test writes

## Shell conventions

`make-app.sh` uses `set -euo pipefail`. Always write variables as `${NAME}` — bash merges the first byte of a
following multi-byte character into the variable name, which produces a confusing `unbound variable` error.

## Workflow

All changes land through a pull request — no direct commits to `main`:

```bash
git checkout -b fix/short-topic       # feat/, fix/, chore/, docs/
# ...edit, commit...
git push -u origin HEAD
gh pr create --fill                   # or --title/--body
gh pr merge --squash --delete-branch  # self-merge is allowed; no approvals required
```

`main` is protected: direct pushes are rejected by the server, so a local `git push origin main` fails
instead of silently bypassing review. Never force-push `main`. Keep each PR focused — a behavioural fix
and a documentation change belong in separate commits (ideally separate PRs).

## Release process

Before tagging, set `APP_VERSION` in `make-app.sh` to the release version without the leading `v`.

```bash
git tag v1.x.y && git push origin v1.x.y
```

Then build a distribution zip from a **separate temp bundle** (never overwrite the installed `AskAI.app`),
ad-hoc sign it, and attach it to a GitHub release with install steps that mention both configuration paths
(`defaults write` and `ASKAI_KEY`) plus a `--check` step. The asset is ad-hoc signed and not notarized, so the
steps must also say how to get past Gatekeeper (System Settings → Privacy & Security → Open Anyway on macOS 15
or later; right-click → Open before that). Update the Chinese release notes if the release is
announced in Chinese.

**Release assets must match their tag.** Build each asset from that tag's own source
(`git worktree add /tmp/vX vX.Y.Z && cd /tmp/vX && swift build -c release`), never from the working tree
of a later commit. Do not use `--clobber` on a published release to swap binaries: if the source moved on,
cut a new version instead. Keep the tag message and release notes stating which source the asset was built from.

## Out of scope

- App Store distribution (needs sandboxing and would break ⌘C simulation)
- Bundled dictionaries / OCR models (size)
- Telemetry of any kind
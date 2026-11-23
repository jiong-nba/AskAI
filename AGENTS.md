# AGENTS.md

Instructions for AI coding agents (and human contributors) working on this repository.

## What this project is

A single-file macOS menu-bar app (~900 lines of Swift) that reads the current selection, sends it to an
OpenAI-compatible endpoint, and streams the answer into a floating panel. CLI regression tests use a local HTTP fixture. The app has no server side.

## Layout

```
Sources/AskAI/main.swift   # everything: config, selection capture, LLM call, OCR, UI, menu bar
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
4. **Do not grow the dependency list without a reason.** The app's selling point is being ~300 KB. Anything
   that ships assets (dictionary data, OCR models, fonts) is out of scope.

## Verifying a change

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

## Code conventions

- Swift 5.9+, macOS 13+ target, no force-unwraps except for compile-time literals (URL, key codes)
- All UI work on the main thread; network work in `Task`, UI updates via `DispatchQueue.main.async` or `MainActor`
- User-facing strings go through `L(zh:en:)`; never hardcode a single language in UI code. Docs are bilingual and must stay in sync
- Keep `main.swift` a single file unless it exceeds ~1200 lines; comments explain *why*, not *what*

## Shell conventions

`make-app.sh` uses `set -euo pipefail`. Always write variables as `${NAME}` — bash merges the first byte of a
following multi-byte character into the variable name, which produces a confusing `unbound variable` error.

## Release process

```bash
git tag v1.x.y && git push origin v1.x.y
```

Then build a distribution zip from a **separate temp bundle** (never overwrite the installed `AskAI.app`),
ad-hoc sign it, and attach it to a GitHub release with install steps that mention both configuration paths
(`defaults write` and `ASKAI_KEY`) plus a `--check` step. Update the Chinese release notes if the release is
announced in Chinese.

**Release assets must match their tag.** Build each asset from that tag's own source
(`git worktree add /tmp/vX vX.Y.Z && cd /tmp/vX && swift build -c release`), never from the working tree
of a later commit. Do not use `--clobber` on a published release to swap binaries: if the source moved on,
cut a new version instead. Keep the tag message and release notes stating which source the asset was built from.

## Out of scope

- App Store distribution (needs sandboxing and would break ⌘C simulation)
- Bundled dictionaries / OCR models (size)
- Telemetry of any kind
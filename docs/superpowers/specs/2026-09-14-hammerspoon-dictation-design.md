# Anchor Whisper as a Hammerspoon module

Date: 2026-09-14
Status: approved design, replaces the Tauri application

> **Historical record — as designed, not as built.** Details drifted during
> implementation and this file is deliberately not rewritten to match. Most
> visibly, the trigger below is Ctrl+Space; the shipped trigger is holding
> **Control+Option** with no key (`hotkey = { mods = { "ctrl", "alt" } }`).
> For current behaviour read `README.md` and `hammerspoon/dictate_config.lua`,
> which are the source of truth.

## Goal

Hold a hotkey, speak, release, and have cleaned-up text pasted into whatever
app is focused, about two seconds after release. Single user, single Mac,
starts at login, no accounts, no API keys, no updater, no UI.

## Non-goals

- Distribution to anyone else. No installer, no signing, no Windows.
- Settings screens. All configuration is one Lua table.
- Streaming transcription while speaking. Possible later; not in this build.
- Preserving any of the Tauri code. It is deleted from `main`; the v0.1.3 tag
  keeps the history.

## Verified facts the design rests on

Checked on this machine on 2026-09-14:

- Apple Silicon, macOS 15.7. Hammerspoon is installed, running, and already
  set to launch at login (`hs.autoLaunch(true)` in the existing config).
- The existing `~/.hammerspoon/init.lua` already contains a clipboard-paste
  helper with a secure-input guard, used by three date hotkeys.
- Homebrew has `whisper-cpp` 1.9.4 and `sox` 14.4.2. Neither is installed.
- The `ggml-large-v3-turbo.bin` model (1.6GB) and `ggml-small.en.bin`
  (488MB) download from Hugging Face with HTTP 200.
- The Claude Code CLI is on the Max 20x subscription with a clean
  environment. Headless mode via `claude -p` works without an API key.
- A long-lived `claude -p --input-format stream-json --output-format
  stream-json` process answers a cleanup request in about 1.1 seconds when
  started with `--setting-sources ""` (skips user hooks), `--tools ""`,
  `--strict-mcp-config --mcp-config '{"mcpServers":{}}'`, and
  `--no-session-persistence`. A cold process takes 4 to 5 seconds. The user's
  global hooks add 1.3 seconds per message if not skipped.
- Hammerspoon's `hs.task` supports `setInput`, `closeInput`,
  `setStreamingCallback`, `setEnvironment`, `terminate`, and `isRunning`.
- Model choice barely matters for latency; Sonnet was the fastest and most
  consistent through the CLI. Haiku was slower and had an 18-second outlier.

## Architecture

Three Lua files in this repo, symlinked into `~/.hammerspoon/`:

| File | Responsibility |
|---|---|
| `hammerspoon/dictate.lua` | Hotkey binding, menubar state, recording task, pipeline orchestration, Claude worker lifecycle. Depends on `hs.*`. |
| `hammerspoon/dictate_core.lua` | Pure functions with no `hs` dependency: keyword replacement, Whisper output parsing, stream-json request encoding and response decoding, prompt assembly. Testable with plain `lua`. |
| `hammerspoon/paste.lua` | The clipboard-paste helper extracted from the existing `init.lua`, with one new option: whether to restore the previous clipboard afterward. Used by both the date hotkeys and dictation. |

Plus:

| File | Responsibility |
|---|---|
| `setup.sh` | Idempotent install: Homebrew packages, model download, symlinks, `require` lines in `init.lua`, Hammerspoon reload. |
| `tests/` | Plain-Lua tests for `dictate_core.lua` and a fixture WAV. |
| `README.md` | What it is, how to install, how to tune, how to debug. |

The user's existing `init.lua` keeps its date hotkeys and mouse module. It
gains `require("paste")` and `require("dictate")` and loses its inline copy of
the paste helper, which moves to `paste.lua` unchanged in behavior.

## Runtime flow

1. **Press Ctrl+Space.** `hs.hotkey.bind` with `pressedfn` and `releasedfn`.
   The menubar icon switches to the recording glyph. A `sox` task starts:
   `rec -q -c 1 -r 16000 -b 16 <tmp>.wav`. The press timestamp is recorded.
2. **Release.** The recording task is stopped with `interrupt()` (SIGINT), which
   lets sox finalize the WAV header. If the hold was shorter than 300ms, the
   file is discarded and the menubar returns to idle with no alert.
3. **Transcribe.** A `whisper-cli` task runs on the WAV with the configured
   model, `--no-timestamps`, `--no-prints`, `--language en`. The menubar shows
   the processing glyph. Stdout is parsed by `dictate_core.parse_whisper`.
   Empty or whitespace-only output ends the pipeline silently.
4. **Clean up.** The transcript is encoded as one stream-json user message and
   written to the warm Claude worker's stdin. The streaming callback
   accumulates stdout lines until a `result` event arrives.
   `dictate_core.decode_result` extracts the text. A per-request timeout
   (default 10s) guards against a hung worker.
5. **Keyword pass.** `dictate_core.apply_keywords` runs case-insensitive
   whole-phrase replacement over the cleaned text. The keyword list is also
   included in the system prompt so the model applies them, but the Lua pass
   is the guarantee.
6. **Paste.** `paste.insert(text, { restore = false })` sets the clipboard and
   sends Cmd+V. The text stays on the clipboard. The menubar returns to idle.

Hammerspoon has no window, so keyboard focus never leaves the target app and
no focus-timing delay is needed.

## Claude worker

A single long-lived `hs.task` running:

```
claude -p --model <config.claude_model>
  --input-format stream-json --output-format stream-json --verbose
  --system-prompt <assembled prompt>
  --tools "" --max-turns 1
  --strict-mcp-config --mcp-config '{"mcpServers":{}}'
  --setting-sources "" --no-session-persistence
```

Environment: `PATH` includes `~/.local/bin` and `/opt/homebrew/bin` because
Hammerspoon's process environment does not. Working directory is an empty
directory under the module's data folder so no `CLAUDE.md` is picked up.

Lifecycle:

- Spawned at module load and warmed with one throwaway message so the first
  real dictation gets the 1.1-second path rather than the 1.8-second first-
  message path.
- Recycled after `config.worker_max_requests` (default 20) requests or after
  `config.worker_idle_seconds` (default 1800) of inactivity. Recycling spawns
  and warms the replacement first, then terminates the old one, so the user
  never waits on a boot.
- If the worker dies or times out mid-request, the raw Whisper text is pasted,
  an alert says "Cleanup failed, pasted raw text", and a fresh worker is
  spawned.
- Only one dictation is processed at a time. A hotkey press during processing
  is ignored with a brief alert.

## Configuration

One table at the top of `dictate.lua`:

```lua
local config = {
  hotkey        = { mods = { "ctrl" }, key = "space" },
  min_hold_ms   = 300,
  whisper_bin   = "/opt/homebrew/bin/whisper-cli",
  whisper_model = os.getenv("HOME") .. "/.local/share/whisper/ggml-large-v3-turbo.bin",
  rec_bin       = "/opt/homebrew/bin/rec",
  claude_bin    = os.getenv("HOME") .. "/.local/bin/claude",
  claude_model  = "sonnet",
  request_timeout_s   = 10,
  worker_max_requests = 20,
  worker_idle_seconds = 1800,
  keywords = {
    -- ["spoken phrase"] = "Replacement",
  },
  prompt = [[ ...the formatting prompt from the Tauri app, verbatim... ]],
}
```

The prompt is the `DEFAULT_PROMPT` from `src-tauri/src/lib.rs` lines 55 to 124,
copied before that file is deleted. The keyword list starts empty; the user
adds entries by editing the table. Hammerspoon's existing path watcher reloads
the config on save.

## Menubar and feedback

An `hs.menubar` item with three states: idle, recording, processing. Its menu
has "Reload dictation", "Restart Claude worker", and "Show log". Failures
surface as `hs.alert` messages with a one-line cause. Details go to an
`hs.logger` at info level, viewable in the Hammerspoon console.

## Error handling

| Failure | Behavior |
|---|---|
| Secure input enabled | Alert, nothing pasted (existing helper behavior). |
| Microphone permission missing | sox exits non-zero with no data. Alert: "Recording failed. Check Hammerspoon microphone permission." |
| whisper-cli missing or model missing | Alert naming the missing path. Checked once at module load and again on failure. |
| Whisper returns nothing | Silent return to idle. |
| Claude worker timeout, crash, or non-zero exit | Raw text pasted, alert, worker respawned. |
| Claude worker rate-limited | The CLI emits a `rate_limit_event`; treated as a normal request unless the `result` reports an error, then same as crash. |
| Hotkey during processing | Alert "Still processing". |

## Setup script

`setup.sh` is idempotent and safe to rerun:

1. `brew install whisper-cpp sox` if not present.
2. Download the model to `~/.local/share/whisper/` if not present, verifying
   the file size against the expected byte count.
3. Symlink the three Lua files into `~/.hammerspoon/`.
4. If `init.lua` lacks `require("paste")` or `require("dictate")`, append
   them. Print a note if the inline paste helper is still present so the user
   can remove it, rather than editing their file destructively.
5. Reload Hammerspoon via `hs -c "hs.reload()"`, falling back to a printed
   instruction if the `hs` CLI hangs.
6. Print the two permissions Hammerspoon needs: Microphone (prompted on first
   recording) and Accessibility (already granted).

## Repo changes

- Delete the Tauri application: `src/`, `src-tauri/`, `package.json`,
  `package-lock.json`, `.github/workflows/release.yml`, and `recovered-assets/`
  from `.gitignore`.
- Add `hammerspoon/`, `setup.sh`, `tests/`, and a real `README.md`.
- Work happens on the `hammerspoon-rewrite` branch. Merge to `main` only with
  explicit sign-off. This repo has no deploy trigger.

## Testing

- `tests/run.sh` runs plain-Lua tests against `dictate_core.lua`: keyword
  replacement (case-insensitive, whole phrase, multiple keywords, no
  keywords), Whisper output parsing (blank, single line, multi-line, trailing
  whitespace), stream-json encoding, result decoding (success, error, partial
  lines), and prompt assembly with and without keywords.
- `dictate.debug_run(path_to_wav)` is exposed in the module for end-to-end
  checks from the Hammerspoon console without recording. A short fixture WAV
  is committed under `tests/fixtures/`.
- Manual acceptance: hold Ctrl+Space in TextEdit, say a sentence with a filler
  word, release. Cleaned text appears within about two seconds. Repeat twenty-
  one times and confirm the worker recycled without a visible delay.

## Things to verify during implementation, not assume

- That `whisper-cli` is the binary name the Homebrew formula installs, and
  that it uses Metal by default on this machine.
- That `hs.task:interrupt()` makes sox write a valid WAV header. If not, use
  `rec` with a `trim` effect plus `terminate()` and check the header.
- That `hs.task` streaming callbacks deliver partial lines, so line buffering
  must be handled in `dictate_core`.
- Whether Ctrl+Space conflicts with the macOS input-source switch on this Mac.
  If it does, note the System Settings toggle in the README.

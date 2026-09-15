# anchor-whisper

Hold **Control+Option+Command**, talk, release. About a second and a half later the cleaned-up
text is pasted into whatever app you were in. Runs entirely on this Mac
through Hammerspoon: local Whisper for speech-to-text, and a headless Claude
Code worker on your Claude subscription for cleanup. No API keys, no cloud
transcription, no app to update.

## Install

```bash
./setup.sh
```

That installs `whisper-cpp`, `sox`, and `lua` from Homebrew, downloads the
Whisper model once (1.6GB to `~/.local/share/whisper/`), symlinks the module
into `~/.hammerspoon/`, imports your Wispr Flow dictionary, and reloads
Hammerspoon. macOS asks for microphone access the first time you record.

The trigger is the three modifiers held with no other key. Pressing a letter
while they are held (for example the Ctrl+Alt+Cmd+D date hotkey) cancels the
recording, so those shortcuts keep working. If Wispr Flow is still running on
Control+Option, it may start its own recording as you press the chord; change
its shortcut or quit it. To use a normal key chord instead, add `key = "space"`
to `hotkey` in `hammerspoon/dictate_config.lua`.

The module lives in this repo on the external drive and is symlinked into
`~/.hammerspoon`. If the drive is not mounted, dictation is unavailable and
Hammerspoon logs a `require` error for `dictate`, but the other hotkeys keep
working.

## Choosing the cleanup backend

The transcript-cleanup step is a config choice among four backends:

| Backend    | What it calls                          | Key needed        |
|------------|-----------------------------------------|--------------------|
| `local`    | The headless Claude Code CLI worker, on your Claude subscription | none |
| `anthropic`| Anthropic Messages API                  | `ANTHROPIC_API_KEY`|
| `openai`   | OpenAI Chat Completions API             | `OPENAI_API_KEY`   |
| `gemini`   | Gemini `generateContent` API            | `GEMINI_API_KEY`   |

`local` is the default and also the automatic fallback: if an API backend
fails or times out, that dictation falls back to the local worker (set
`cleanup.local_fallback = false` to disable this). The local worker's model
is still controlled by `claude_model`, separate from `cleanup.model`.

Defaults, from `hammerspoon/dictate_config.lua`:

```lua
cleanup = { backend = "local", model = nil, timeout_s = 10, local_fallback = true },
cleanup_models = {
  anthropic = "claude-haiku-4-5",
  openai = "gpt-5-nano",
  gemini = "gemini-2.5-flash-lite",
},
```

Keys and backend choice never go in the repo or the shell environment.
Set them in one of, highest priority first:

1. `~/.config/dictate/env` (created by `setup.sh` from `scripts/env.example`,
   `chmod 600`) — `KEY=VALUE` lines: `DICTATE_BACKEND`, `DICTATE_MODEL`,
   `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`.
2. `~/.hammerspoon/dictate_local.lua` — any `dictate_config.lua` key,
   plus `anthropic_api_key` / `openai_api_key` / `gemini_api_key` and a
   `cleanup = { backend = "...", model = "..." }` table. See
   `hammerspoon/dictate_local.example.lua`.
3. `dictate_config.lua` defaults above.

To compare backends side by side on the same transcript, from the
Hammerspoon console:

```lua
dictate.compare("some dictated text")
```

This races every backend with a configured key (plus `local`) and writes
timings and outputs to `/tmp/dictate-compare.txt`.

## Dictionary

`scripts/import-wispr-dictionary.sh` reads Wispr Flow's local database and
writes `~/.hammerspoon/dictate_dictionary.lua`. Terms are given to Whisper as
a spelling hint and to Claude as a vocabulary list for phonetic near-misses.
Entries under `replacements` are applied verbatim after cleanup. Edit the file
by hand or re-run the script; it is never committed.

## Debugging

Open the Hammerspoon console (menubar icon > Show console). Useful calls:

```lua
dictate.debug_text("um so send the the report to bob")   -- cleanup + paste only
dictate.debug_run("/path/to/16k-mono.wav")                -- transcribe + cleanup + paste
dictate.restart_worker()
```

A stuck recording is stopped automatically after two minutes, and a stuck
transcription is killed after one.

Tests for the pure logic: `tests/run.sh`.

## How it works

`hammerspoon/dictate.lua` keeps one `claude -p` process alive in stream-json
mode with tools, MCP servers, hooks, and session persistence all disabled.
Each dictation is one message on its stdin. The worker is recycled every 20
requests or after 30 idle minutes, with the replacement booted first. If the
worker fails, the raw Whisper text is pasted and an alert says so.

A `whisper-server` process keeps the Whisper model loaded and answers
transcription requests over loopback on port 18081, skipping the ~0.66s model
load that `whisper-cli` pays on every dictation. If it is down, `whisper-cli`
is used automatically and a console line says which path ran. A restart boots
a replacement server on the alternate port (18081/18082) and only retires the
old one once the replacement answers, so there is never a window with no
server.

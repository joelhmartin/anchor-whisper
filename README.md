# anchor-whisper

Hold **Control+Option**, talk, release. About a second and a half later the cleaned-up
text is pasted into whatever app you were in. Runs on this Mac through
Hammerspoon, with no app to update.

**Where your words go.** Speech-to-text is local: Whisper runs on this machine
and the audio never leaves it. Cleanup is not. The transcript is sent to
whichever backend `DICTATE_BACKEND` names — a Claude Code worker on your Claude
subscription, or the Anthropic, OpenAI or Gemini API — along with the cursor
context (`context.enabled`) and your dictionary terms, which travel in the
prompt. Only the `local` backend needs no API key, and it still leaves the Mac.
Set `context = { enabled = false }` to stop sending surrounding text.

## Install

```bash
./setup.sh
```

That installs `whisper-cpp`, `sox`, and `lua` from Homebrew, downloads the
Whisper model once (1.6GB to `~/.local/share/whisper/`), symlinks the module
into `~/.hammerspoon/`, imports your Wispr Flow dictionary, and reloads
Hammerspoon. macOS asks for microphone access the first time you record.

The trigger is the two modifiers held with no other key. Pressing a letter
while they are held (for example the Ctrl+Option+Command+D date hotkey) cancels the
recording, so those shortcuts keep working. If Wispr Flow is still running on
Control+Option, it may start its own recording as you press the chord; change
its shortcut or quit it. To use a normal key chord instead, add `key = "space"`
to `hotkey` in `hammerspoon/dictate_config.lua`.

The module lives in this repo at `~/Developer/anchor-whisper` and is symlinked
into `~/.hammerspoon`. `setup.sh` creates those symlinks, so re-run it after
moving the repo.

## Always on

Hammerspoon launches at login (`hs.autoLaunch(true)` in `~/.hammerspoon/init.lua`).
The dictation modules are symlinks into this repo, and the repo is on the boot
volume, so they always resolve — nothing has to be plugged in. Date hotkeys
(`Ctrl+Option+Command+D`/`+Shift`/`+T`) live in `init.lua` itself and use
`paste.lua` from here.

Keep it that way. The repo sat on an external SSD until 2026-09-16, and because
that drive could mount *after* Hammerspoon had already started, `init.lua`
needed a wait-for-mount guard — a one-time alert, an `hs.fs.volume` watcher and
a 30s retry timer that reloaded once the symlinks resolved. Moving to the
internal drive deleted all of it. Putting the repo back on removable storage,
or anywhere that can go away (an iCloud-synced folder counts: files there can be
evicted to the cloud), means bringing that guard back.

## Visualizer and sounds

A tiny opaque black capsule (`hammerspoon/dictate_overlay.lua`, built on
`hs.canvas`) sits flush with the very bottom edge of whichever screen has the
mouse while you dictate, Wispr Flow style — no dot, no text, just a row of
white bars. It never takes keyboard focus. While recording the bars track
your actual microphone level in real time (dictate.lua reads the RMS of the
last 50ms of the WAV `rec` is writing, a few times a second); at silence they
rest flat. While cleanup is running the bars dim and ripple gently on their
own. A brief green flash marks success, a brief red flash marks an error (the
existing `hs.alert` popup still carries the words; the pill itself never
shows text). The pill and the start chirp are both delayed by `min_hold_ms`,
so a quick date-hotkey tap never flickers or plays a sound. Subtle system
sounds (`/System/Library/Sounds`) mark start, stop, and errors.

Config, in `hammerspoon/dictate_config.lua`:

```lua
overlay = { enabled = true, width = 60, height = 26, bottom_margin = 10, bars = 12, fps = 20 },
sounds  = { start = "Tink", stop = "Pop", error = "Basso", volume = 0.25 },
```

`bottom_margin` is the gap, in pixels, between the pill and the very bottom
edge of the display (measured from the screen's full frame, so it floats
over the Dock area rather than above it).

Set `overlay.enabled = false` to disable the pill, or any `sounds` name to
`false` to silence that cue. From the Hammerspoon console, `dictate.overlay_demo()`
cycles the pill through recording -> processing -> done for a manual check.

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
`cleanup.local_fallback = false` to disable this).

Defaults, from `hammerspoon/dictate_config.lua`:

```lua
cleanup = { backend = "local", model = nil, timeout_s = 10, local_fallback = true },
cleanup_models = {
  anthropic = "claude-haiku-4-5",
  openai = "gpt-5-nano",
  gemini = "gemini-3.5-flash-lite",
},
```

Backend, models, and keys all live in one place: **`.env` at the repo
root** (`setup.sh` creates it from `scripts/env.example`, `chmod 600`,
and it is gitignored — never commit it). It is plain `KEY=VALUE` lines,
`#` comments, and quoted values:

```
DICTATE_BACKEND=local        # local | anthropic | openai | gemini
DICTATE_LOCAL_MODEL=sonnet   # local worker's model: sonnet | haiku | opus
DICTATE_MODEL=               # API model; blank = provider default
ANTHROPIC_API_KEY=
OPENAI_API_KEY=
GEMINI_API_KEY=
```

Saving `.env` reloads Hammerspoon automatically. `~/.hammerspoon/dictate_local.lua`
still works as a lower-priority override (any `dictate_config.lua` key,
plus `anthropic_api_key` / `openai_api_key` / `gemini_api_key` and a
`cleanup = { backend = "...", model = "..." }` table — see
`hammerspoon/dictate_local.example.lua`), and `dictate_config.lua`'s
defaults are the last resort. Precedence, highest first: `.env` >
`dictate_local.lua` > `dictate_config.lua`.

Process environment variables are a fallback for **API keys only**, and only
after both files: `.env` > `dictate_local.lua` > `ANTHROPIC_API_KEY` /
`OPENAI_API_KEY` / `GEMINI_API_KEY` in the environment. The backend and model
are never read from the environment — set those in `.env`. (Keeping keys out of
the shell is the point of `.env`; the fallback exists for one-off tests.)

To compare backends side by side on the same transcript, from the
Hammerspoon console:

```lua
dictate.compare("some dictated text")
```

This races every backend with a key, regardless of `DICTATE_BACKEND` (plus
`local`), and writes timings and outputs to `/tmp/dictate-compare.txt`.

## Dictionary

`~/.hammerspoon/dictate_dictionary.lua` is a hand-edited Lua table (template:
`hammerspoon/dictate_dictionary.example.lua`; `setup.sh` copies it there if
missing). Saving it reloads Hammerspoon. `terms` are given to Whisper as a
spelling hint and to the cleanup model as a vocabulary list for phonetic
near-misses. Entries under `replacements` are applied verbatim after cleanup.
The file is never committed.

## Debugging

Open the Hammerspoon console (menubar icon > Show console). Useful calls:

```lua
dictate.debug_text("um so send the the report to bob")   -- cleanup + paste only
dictate.debug_run("/path/to/16k-mono.wav")                -- transcribe + cleanup + paste
dictate.restart_worker()
dictate.debug_context(os.getenv("HOME") .. "/ctx.txt")                     -- what the focused field exposes around the caret
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

Whisper runs with Silero voice-activity detection (`setup.sh` downloads the
small VAD model next to the Whisper model). Non-speech audio is skipped, so
a hold with nothing said comes back empty in a few milliseconds instead of
as a hallucinated "Thank you." Transcripts with no letters or digits never
reach the cleanup model, and an empty answer from the cleanup model counts
as "nothing to paste" rather than as a failure.

Before the transcript goes to cleanup, the text around the caret in the
focused field (up to 200 characters each side, read through the
accessibility API) is attached as context so a dictation that continues a
sentence is cased and punctuated as a continuation. The leading/trailing
space is decided in code, not by the model. Fields that do not expose their
text (some web and Electron views) simply get no context. That context goes
to the configured cleanup backend; set `context = { enabled = false }` in
`dictate_local.lua` to turn it off.

A `whisper-server` process keeps the Whisper model loaded and answers
transcription requests over loopback on port 18081, skipping the ~0.66s model
load that `whisper-cli` pays on every dictation. If it is down, `whisper-cli`
is used automatically and a console line says which path ran. A restart boots
a replacement server on the alternate port (18081/18082) and only retires the
old one once the replacement answers, so there is never a window with no
server.

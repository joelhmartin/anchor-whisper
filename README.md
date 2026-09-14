# anchor-whisper

Hold **Control+Option+Command**, talk, release. About two seconds later the cleaned-up
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

## Switching the Claude model

Edit `claude_model` in `hammerspoon/dictate_config.lua` (`sonnet`, `haiku`,
or `opus`) and save; Hammerspoon reloads on its own. To keep a personal
choice out of git, put it in `~/.hammerspoon/dictate_local.lua` instead:

```lua
return { claude_model = "haiku" }
```

Latency is dominated by process startup, not the model, so Sonnet and Haiku
feel about the same. See `hammerspoon/dictate_local.example.lua` for other
overrides.

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

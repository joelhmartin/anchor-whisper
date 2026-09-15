-- Copy to ~/.hammerspoon/dictate_dictionary.lua and edit. Saving it reloads
-- Hammerspoon. The real file is gitignored; nothing personal belongs in the repo.
return {
  -- Names and jargon spelled the way you want them. Whisper gets them as a
  -- spelling hint; the cleanup model corrects phonetic near-misses to them.
  terms = {
    "Hammerspoon",
    "whisper.cpp",
  },
  -- Exact spoken phrase -> text to output (case-insensitive), applied after
  -- cleanup. Handy for addresses and anything the model should never touch.
  replacements = {
    ["my email"] = "you@example.com",
  },
}

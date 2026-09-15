-- Copy to ~/.hammerspoon/dictate_local.lua to override defaults. Never commit it.
-- Any key from dictate_config.lua may appear here.
return {
  -- claude_model = "haiku",
  -- worker_max_requests = 50,
  -- whisper_model = os.getenv("HOME") .. "/.local/share/whisper/ggml-small.en.bin",

  -- Use a direct API backend instead of the local Claude Code worker.
  -- Prefer ~/.config/dictate/env for this (see scripts/env.example); these
  -- keys are here only as a reminder of the names dictate_core expects.
  -- cleanup = { backend = "gemini", model = "gemini-2.5-flash-lite" },
  -- anthropic_api_key = "sk-ant-...",
  -- openai_api_key = "sk-...",
  -- gemini_api_key = "...",
}

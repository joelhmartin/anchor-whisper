-- Pure functions for the dictation pipeline. No Hammerspoon dependency so
-- this file is testable with plain lua (see tests/run.sh).
local core = {}
local json = require("json")

-- Whisper stdout (with -nt -np) is one or more lines of text. Silence comes
-- back as "[BLANK_AUDIO]" or nothing at all.
function core.parse_whisper(stdout)
  local text = stdout or ""
  text = text:gsub("%[[%u_ ]+%]", " ")      -- [BLANK_AUDIO], [MUSIC], ...
  text = text:gsub("[\r\n]+", " ")
  text = text:gsub("%s+", " ")
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  return text
end

local function is_word_char(c)
  return c ~= "" and c:match("[%w_']") ~= nil
end

-- Whisper answers silence with a lone "." / "-" (or, without VAD, a
-- hallucinated pleasantry). Anything without a letter or digit is not speech
-- and must not be sent for cleanup.
-- Glyphs whisper emits for non-speech (music, trailing-off) or as typography;
-- none of them is a word on its own.
local NON_SPEECH_GLYPHS = { "…", "♪", "♫", "—", "–", "’", "‘", "“", "”", "·", "•" }
function core.has_speech(text)
  if type(text) ~= "string" then return false end
  for _, g in ipairs(NON_SPEECH_GLYPHS) do text = text:gsub(g, "") end
  -- %w is ASCII-only in Lua; any remaining non-ASCII byte (accented letters) counts too.
  return text:find("[%w\128-\255]") ~= nil
end

-- Model output as returned by an API backend: trim the ends, normalize line
-- endings, keep interior newlines (lists, paragraph breaks). parse_whisper is
-- for whisper's stdout and would flatten those.
function core.trim_output(text)
  text = (text or ""):gsub("\r\n?", "\n")
  return text:gsub("^%s+", ""):gsub("%s+$", "")
end

-- Cursor context: what sits immediately before/after the insertion point in
-- the focused field (see paste.context). The model gets it so a dictation
-- that continues a sentence is cased and punctuated as a continuation; the
-- spacing itself is decided here, deterministically, in join_at_cursor.
local function has_context(ctx)
  return type(ctx) == "table" and ((ctx.before or "") ~= "" or (ctx.after or "") ~= "")
end

-- Document text is untrusted input to the prompt: it must not be able to
-- close a context block early, so the fences are stripped from it.
local function fence_safe(text)
  return (text:gsub("<<<", ""):gsub(">>>", ""))
end

function core.build_user_message(transcript, ctx)
  if not has_context(ctx) then return transcript end
  local parts = {}
  if (ctx.before or "") ~= "" then
    parts[#parts + 1] = "Text before the cursor (context only, do not repeat it):\n<<<\n" .. fence_safe(ctx.before) .. "\n>>>"
  end
  if (ctx.after or "") ~= "" then
    parts[#parts + 1] = "Text after the cursor (context only, do not repeat it):\n<<<\n" .. fence_safe(ctx.after) .. "\n>>>"
  end
  parts[#parts + 1] = "Transcript:\n<<<\n" .. transcript .. "\n>>>"
  return table.concat(parts, "\n\n")
end

-- Leading/trailing space so the paste lands cleanly: a space after a word or
-- closing punctuation before the cursor, none after whitespace, a newline, or
-- an opening bracket/quote; a trailing space when non-space text follows.
function core.join_at_cursor(ctx, out)
  if out == nil or out == "" then return out end
  -- Spaces/tabs at the ends are the model's, not the speaker's; a deliberate
  -- leading newline ("new paragraph") survives.
  out = out:gsub("^[ \t]+", ""):gsub("[ \t]+$", "")
  if not has_context(ctx) then return out end
  local before, after = ctx.before or "", ctx.after or ""
  local last, first = before:sub(-1), out:sub(1, 1)
  -- No space after whitespace, an opener, or a character that joins to the
  -- next one (path, URL, hyphen, identifier, address); none before
  -- punctuation that attaches to the previous word.
  if last ~= "" and not last:match("[%s%(%[{\"'`/%-_@#]")
     and not first:match("[%s,%.;:%?!%)%]}]") then
    out = " " .. out
  end
  local nxt = after:sub(1, 1)
  if nxt ~= "" and not nxt:match("[%s%)%]}>,%.;:%?!'\"]") and not out:sub(-1):match("%s") then
    out = out .. " "
  end
  return out
end

-- Replace each spoken phrase (table key, lowercase) with its written form,
-- case-insensitively, matching whole phrases only. Longer keys win.
function core.apply_replacements(text, replacements)
  if not replacements or next(replacements) == nil then return text end
  local keys = {}
  for k in pairs(replacements) do if k ~= "" then keys[#keys + 1] = k end end
  table.sort(keys, function(a, b) return #a > #b end)
  for _, key in ipairs(keys) do
    local needle = key:lower()
    local lower = text:lower()
    local out, pos = {}, 1
    while true do
      local s, e = lower:find(needle, pos, true)
      if not s then out[#out + 1] = text:sub(pos); break end
      local before = s > 1 and text:sub(s - 1, s - 1) or ""
      local after = text:sub(e + 1, e + 1)
      if not is_word_char(before) and not is_word_char(after) then
        out[#out + 1] = text:sub(pos, s - 1)
        out[#out + 1] = replacements[key]
      else
        out[#out + 1] = text:sub(pos, e)
      end
      pos = e + 1
    end
    text = table.concat(out)
  end
  return text
end

-- LineBuffer: accumulates stdout chunks and yields complete lines.
local LineBuffer = {}
LineBuffer.__index = LineBuffer
core.LineBuffer = LineBuffer

function LineBuffer.new()
  return setmetatable({ rest = "" }, LineBuffer)
end

function LineBuffer:push(chunk)
  local data = self.rest .. (chunk or "")
  local lines, pos = {}, 1
  while true do
    local nl = data:find("\n", pos, true)
    if not nl then break end
    local line = data:sub(pos, nl - 1):gsub("\r$", "")
    if line ~= "" then lines[#lines + 1] = line end
    pos = nl + 1
  end
  self.rest = data:sub(pos)
  return lines
end

-- One stream-json user turn for `claude -p --input-format stream-json`.
function core.encode_request(text)
  return json.encode({ type = "user", message = { role = "user", content = text } }) .. "\n"
end

function core.decode_event(line)
  if not line or line == "" then return nil end
  local ok, ev = pcall(json.decode, line)
  if ok and type(ev) == "table" then return ev end
  return nil
end

-- Returns "success", text | "error", label | nil for non-result events.
function core.decode_result(ev)
  if type(ev) ~= "table" or ev.type ~= "result" then return nil end
  if ev.is_error or ev.subtype ~= "success" then
    return "error", tostring(ev.subtype or "error")
  end
  return "success", ev.result or ""
end

-- Appends the user's vocabulary and exact replacements to the base prompt.
function core.build_system_prompt(base, dictionary)
  local terms = dictionary and dictionary.terms or {}
  local replacements = dictionary and dictionary.replacements or {}
  local parts = { base }
  if #terms > 0 then
    local lines = { "Vocabulary", "",
      "The speaker regularly uses the names and terms below. When a transcribed word or phrase is a close phonetic match for one of them, output the spelling shown here instead of what was transcribed." }
    for _, t in ipairs(terms) do lines[#lines + 1] = "- " .. t end
    parts[#parts + 1] = table.concat(lines, "\n")
  end
  if next(replacements) ~= nil then
    local keys = {}
    for k in pairs(replacements) do keys[#keys + 1] = k end
    table.sort(keys)
    local lines = { "Exact Replacements", "", "Apply these replacements case-insensitively wherever the spoken phrase appears:" }
    for _, k in ipairs(keys) do
      lines[#lines + 1] = string.format('- "%s" -> "%s"', k, replacements[k])
    end
    parts[#parts + 1] = table.concat(lines, "\n")
  end
  return table.concat(parts, "\n\n")
end

-- whisper-server /inference JSON body -> transcript text, or nil on anything unexpected.
function core.parse_server_response(body)
  local ev = core.decode_event(body)
  if not ev or type(ev.text) ~= "string" then return nil end
  return core.parse_whisper(ev.text)
end

-- Cleanup backends -----------------------------------------------------------

-- KEY=VALUE lines -> table. Ignores comments/blank lines; strips one pair of
-- matching quotes, or (when unquoted) a trailing " # comment" -- a comment
-- needs a space before '#', so "value#nospace" is left untouched.
function core.parse_env_file(text)
  local out = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      local k, v = trimmed:match("^([%w_]+)%s*=%s*(.*)$")
      if k then
        local quote = v:sub(1, 1)
        if quote == '"' or quote == "'" then
          local close = v:find(quote, 2, true)
          if close then v = v:sub(2, close - 1) end
        else
          v = v:gsub("%s+#.*$", "")
        end
        out[k] = v
      end
    end
  end
  return out
end

-- Each backend: build(model, key, system, text) -> { url = , headers = {}, body = <table> }
--               parse(body_json_string) -> text | nil, error_label
core.backends = {}

core.backends.anthropic = {
  build = function(model, key, system, text)
    return {
      url = "https://api.anthropic.com/v1/messages",
      headers = { ["x-api-key"] = key, ["anthropic-version"] = "2023-06-01", ["content-type"] = "application/json" },
      body = {
        model = model, max_tokens = 1024, temperature = 0,
        system = { { type = "text", text = system, cache_control = { type = "ephemeral" } } },
        messages = { { role = "user", content = text } },
      },
    }
  end,
  parse = function(body)
    local r = core.decode_event(body)
    if not r then return nil, "bad json" end
    if r.error then return nil, tostring(r.error.message or r.error.type or "error") end
    if r.stop_reason == "refusal" then return nil, "refusal" end
    for _, block in ipairs(r.content or {}) do
      if block.type == "text" and type(block.text) == "string" then return core.trim_output(block.text) end
    end
    -- The prompt asks for an empty answer on silence; the API then sends no
    -- content blocks at all. That is a result, not a failure.
    if type(r.content) == "table" and #r.content == 0 and r.stop_reason == "end_turn" then return "" end
    return nil, "no text block"
  end,
}

core.backends.openai = {
  build = function(model, key, system, text)
    return {
      url = "https://api.openai.com/v1/chat/completions",
      headers = { ["Authorization"] = "Bearer " .. key, ["content-type"] = "application/json" },
      -- No temperature: gpt-5 family models reject values other than the default.
      body = { model = model, messages = { { role = "system", content = system }, { role = "user", content = text } } },
    }
  end,
  parse = function(body)
    local r = core.decode_event(body)
    if not r then return nil, "bad json" end
    if r.error then return nil, tostring(r.error.message or "error") end
    local c = r.choices and r.choices[1]
    local content = c and c.message and c.message.content
    if type(content) ~= "string" then return nil, "no content" end
    return core.trim_output(content)
  end,
}

core.backends.gemini = {
  build = function(model, key, system, text)
    return {
      url = "https://generativelanguage.googleapis.com/v1beta/models/" .. model .. ":generateContent",
      headers = { ["x-goog-api-key"] = key, ["content-type"] = "application/json" },
      body = {
        system_instruction = { parts = { { text = system } } },
        contents = { { role = "user", parts = { { text = text } } } },
        generationConfig = { temperature = 0 },
      },
    }
  end,
  parse = function(body)
    local r = core.decode_event(body)
    if not r then return nil, "bad json" end
    if r.error then return nil, tostring(r.error.message or "error") end
    local cand = r.candidates and r.candidates[1]
    local parts = cand and cand.content and cand.content.parts
    if type(parts) ~= "table" then
      -- An empty answer arrives as {"content":{},"finishReason":"STOP"}:
      -- the prompt's required response to silence, so a valid empty result.
      if cand and cand.finishReason == "STOP" then return "" end
      return nil, (cand and cand.finishReason) or "no parts"
    end
    local out = {}
    for _, p in ipairs(parts) do if type(p.text) == "string" then out[#out + 1] = p.text end end
    if #out == 0 then return nil, "no text" end
    return core.trim_output(table.concat(out, ""))
  end,
}

-- A blank string from an env file or a dictate_local table counts as unset.
local function nonempty(s)
  if s == nil or s == "" then return nil end
  return s
end

-- Decide backend/model/key/local_model. env = parsed env file, locals =
-- dictate_local table, getenv = optional function(name) (defaults to a
-- no-op) consulted last for keys.
function core.resolve_cleanup(cfg, env, locals, getenv)
  env = env or {}; locals = locals or {}; getenv = getenv or function() return nil end
  local c = cfg.cleanup or {}
  local lc = (locals.cleanup or {})
  local backend = nonempty(env.DICTATE_BACKEND) or nonempty(lc.backend) or c.backend or "local"
  local models = cfg.cleanup_models or {}
  local model = nonempty(env.DICTATE_MODEL) or nonempty(lc.model) or c.model or models[backend]
  local local_model = nonempty(env.DICTATE_LOCAL_MODEL) or nonempty(locals.claude_model) or cfg.claude_model
  if backend == "local" then return { backend = "local", model = nil, key = nil, local_model = local_model } end
  local envname = ({ anthropic = "ANTHROPIC_API_KEY", openai = "OPENAI_API_KEY", gemini = "GEMINI_API_KEY" })[backend]
  if not envname then
    return { backend = "local", reason = "unknown backend " .. tostring(backend), local_model = local_model }
  end
  local key = nonempty(env[envname]) or nonempty(locals[backend .. "_api_key"]) or nonempty(getenv(envname))
  if not key then return { backend = "local", reason = "no key for " .. backend, local_model = local_model } end
  return { backend = backend, model = model, key = key, local_model = local_model }
end

-- Comma-separated spelling hint for whisper-cli --prompt, capped by length.
function core.build_whisper_prompt(terms, max_chars)
  if not terms or #terms == 0 then return "" end
  local out, len = {}, 0
  for _, t in ipairs(terms) do
    local add = (#out == 0) and #t or (#t + 2)
    if len + add > max_chars then break end
    out[#out + 1] = t
    len = len + add
  end
  return table.concat(out, ", ")
end

return core

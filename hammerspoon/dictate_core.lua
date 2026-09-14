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

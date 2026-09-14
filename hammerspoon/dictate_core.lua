-- Pure functions for the dictation pipeline. No Hammerspoon dependency so
-- this file is testable with plain lua (see tests/run.sh).
local core = {}

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
  for k in pairs(replacements) do keys[#keys + 1] = k end
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

return core

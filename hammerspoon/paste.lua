-- Insert text into the focused app. Shared by the date hotkeys in init.lua
-- and by dictate.lua.
--
-- Default is clipboard + Cmd-V: save panels honor a paste reliably, while
-- synthetic keystrokes get dropped by some text fields. Pass method = "type"
-- to type character-by-character instead.
--
-- restore = true (default) puts the previous clipboard back after 0.6s.
-- Dictation passes restore = false so the dictated text stays copied.
local M = {}

function M.insert(text, opts)
  opts = opts or {}
  -- Secure input (a password field somewhere, sometimes a stuck Terminal)
  -- blocks all synthetic events. Fail loudly instead of silently doing nothing.
  if hs.eventtap.isSecureInputEnabled() then
    hs.alert.show("Secure input is on — nothing inserted")
    return false
  end

  if opts.method == "type" then
    hs.eventtap.keyStrokes(text)
    return true
  end

  local restore = opts.restore ~= false
  local saved = restore and hs.pasteboard.readAllData() or nil
  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({ "cmd" }, "v")
  if saved then
    hs.timer.doAfter(0.6, function() hs.pasteboard.writeAllData(saved) end)
  end
  return true
end

-- What surrounds the insertion point in the focused field, via the
-- accessibility API: { before = <up to max_chars before the caret>,
-- after = <up to max_chars after it> }, or nil when the focused element does
-- not expose its text (many Electron/web views do not). Read-only and cheap;
-- never logged by callers. Used so dictation can continue a sentence
-- instead of always starting a new one.
function M.context(max_chars)
  max_chars = max_chars or 200
  local ok, result = pcall(function()
    local ax = require("hs.axuielement")
    local el = ax.systemWideElement():attributeValue("AXFocusedUIElement")
    if not el then
      local app = hs.application.frontmostApplication()
      local ae = app and ax.applicationElement(app)
      el = ae and ae:attributeValue("AXFocusedUIElement")
    end
    if not el then return nil end
    local range = el:attributeValue("AXSelectedTextRange")
    if type(range) ~= "table" or type(range.location) ~= "number" then return nil end
    local caret = range.location
    local total = el:attributeValue("AXNumberOfCharacters")
    local function slice(loc, len)
      if len <= 0 then return "" end
      local s = el:parameterizedAttributeValue("AXStringForRange", { location = loc, length = len })
      return type(s) == "string" and s or nil
    end
    local before = slice(math.max(0, caret - max_chars), math.min(caret, max_chars))
    local after
    if type(total) == "number" then
      local tail_start = caret + (range.length or 0)
      after = slice(tail_start, math.max(0, math.min(max_chars, total - tail_start)))
    end
    if before == nil then
      -- No AXStringForRange: fall back to the whole value when it is small.
      local v = el:attributeValue("AXValue")
      if type(v) ~= "string" or #v > 200000 then return nil end
      before = v:sub(math.max(1, caret - max_chars + 1), caret)
      local tail_start = caret + (range.length or 0) + 1
      after = v:sub(tail_start, tail_start + max_chars - 1)
    end
    return { before = before or "", after = after or "" }
  end)
  if ok then return result end
  return nil
end

return M

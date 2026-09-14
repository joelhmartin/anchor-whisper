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

return M

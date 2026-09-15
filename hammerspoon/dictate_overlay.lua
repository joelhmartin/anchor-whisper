-- Wispr Flow-style floating pill: a small hs.canvas window, bottom-center of
-- whichever screen has the mouse, that shows recording/processing/done/error
-- without ever taking keyboard focus or stealing focus from the app the user
-- is dictating into.
--
-- One canvas object is created lazily and reused for the process lifetime.
-- Every timer (the bar-animation ticker and a pending done()/error() hide)
-- is held in a module local so Hammerspoon's timer GC cannot silently stop
-- it (see dictate.lua's `later()` for the same concern).
local M = {}

local cfg = { enabled = true, width = 168, height = 36, bottom_margin = 72, bars = 7, fps = 15 }

local canvas = nil
local animTimer = nil    -- bar-animation ticker, recreated per state
local flashTimer = nil   -- pending done()/error() auto-hide
local flashing = false   -- true while a done/error flash is in progress
local barHeights = {}    -- smoothed per-bar heights, carried across ticks
local demoTimers = {}    -- timers used only by demo()

local BAR_LEFT = 32 -- leaves room for the status dot on the left

function M.configure(overlay_cfg)
  if type(overlay_cfg) ~= "table" then return end
  for k, v in pairs(overlay_cfg) do cfg[k] = v end
end

local function ensure_canvas()
  if canvas then return canvas end
  canvas = hs.canvas.new({ x = 0, y = 0, w = cfg.width, h = cfg.height })
  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:behavior({ "canJoinAllSpaces", "stationary" })
  canvas:clickActivating(false)
  canvas:alpha(0.95)
  return canvas
end

-- Bottom-center of whichever screen currently has the mouse pointer.
-- Recomputed on every state change since the user may switch screens
-- mid-session.
local function reposition()
  local c = ensure_canvas()
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  if not screen then return end
  local frame = screen:frame()
  c:topLeft({
    x = frame.x + (frame.w - cfg.width) / 2,
    y = frame.y + frame.h - cfg.bottom_margin - cfg.height,
  })
end

local function stop_anim()
  if animTimer then animTimer:stop(); animTimer = nil end
end

-- Cancels a pending done()/error() auto-hide, if any, and clears the flag
-- that makes hide() a no-op. Every state-entry function calls this first so
-- state changes are safe regardless of what the pill was doing before.
local function stop_flash()
  if flashTimer then flashTimer:stop(); flashTimer = nil end
  flashing = false
end

local function base_elements(dot_color)
  return {
    {
      type = "rectangle", action = "fill",
      frame = { x = 0, y = 0, w = cfg.width, h = cfg.height },
      roundedRectRadii = { xRadius = 18, yRadius = 18 },
      fillColor = { red = 0.1, green = 0.1, blue = 0.12, alpha = 0.85 },
    },
    {
      type = "circle", action = "fill",
      center = { x = 16, y = cfg.height / 2 },
      radius = 5,
      fillColor = dot_color,
    },
  }
end

local function bar_geometry(i)
  local usable = cfg.width - BAR_LEFT - 12
  local gap = usable / cfg.bars
  return BAR_LEFT + gap * (i - 1) + gap * 0.25, gap * 0.5 -- x, w
end

local function bar_element(i, h, color)
  local x, w = bar_geometry(i)
  return {
    type = "rectangle", action = "fill",
    frame = { x = x, y = (cfg.height - h) / 2, w = w, h = h },
    roundedRectRadii = { xRadius = w / 2, yRadius = w / 2 },
    fillColor = color,
  }
end

-- Hides the pill. A no-op while a done()/error() flash is in progress (that
-- flash's own timer is responsible for hiding); otherwise idempotent: safe
-- to call on an already-hidden or never-shown canvas.
function M.hide()
  if not cfg.enabled then return end
  if flashing then return end
  stop_anim()
  if canvas then canvas:hide() end
end

-- Used internally by the done()/error() timers, which must hide even though
-- `flashing` is still true at the moment they fire (they clear it first).
local function force_hide()
  stop_anim()
  if canvas then canvas:hide() end
end

function M.recording()
  if not cfg.enabled then return end
  stop_flash()
  reposition()
  local c = ensure_canvas()
  local color = { red = 0.9, green = 0.2, blue = 0.2 }
  for i = 1, cfg.bars do barHeights[i] = barHeights[i] or 4 end
  local function redraw()
    local els = base_elements(color)
    for i = 1, cfg.bars do
      local target = math.random(4, math.max(4, cfg.height - 12))
      barHeights[i] = barHeights[i] + (target - barHeights[i]) * 0.5
      els[#els + 1] = bar_element(i, barHeights[i], color)
    end
    c:replaceElements(els)
  end
  redraw()
  c:show()
  stop_anim()
  animTimer = hs.timer.doEvery(1 / cfg.fps, redraw)
end

function M.processing()
  if not cfg.enabled then return end
  stop_flash()
  reposition()
  local c = ensure_canvas()
  local color = { white = 0.55 }
  local function redraw()
    local els = base_elements(color)
    -- oscillates between 4 and 12
    local h = 4 + (math.sin(os.clock() * 4) * 0.5 + 0.5) * 8
    for i = 1, cfg.bars do
      els[#els + 1] = bar_element(i, h, color)
    end
    c:replaceElements(els)
  end
  redraw()
  c:show()
  stop_anim()
  animTimer = hs.timer.doEvery(1 / cfg.fps, redraw)
end

function M.done()
  if not cfg.enabled then return end
  stop_flash()
  stop_anim()
  reposition()
  local c = ensure_canvas()
  local green = { red = 0.25, green = 0.8, blue = 0.35 }
  local els = base_elements(green)
  local cx, cy = (BAR_LEFT + cfg.width - 12) / 2, cfg.height / 2
  els[#els + 1] = {
    type = "segments", action = "stroke", closed = false,
    strokeColor = green, strokeWidth = 2.5,
    coordinates = {
      { x = cx - 10, y = cy },
      { x = cx - 3, y = cy + 7 },
      { x = cx + 12, y = cy - 8 },
    },
  }
  c:replaceElements(els)
  c:show()
  flashing = true
  flashTimer = hs.timer.doAfter(0.35, function()
    flashing = false
    flashTimer = nil
    force_hide()
  end)
end

function M.error(msg)
  if not cfg.enabled then return end
  stop_flash()
  stop_anim()
  reposition()
  local c = ensure_canvas()
  msg = tostring(msg or "Error"):sub(1, 24)
  local red = { red = 0.85, green = 0.2, blue = 0.2 }
  local els = base_elements(red)
  els[1].fillColor = { red = 0.35, green = 0.08, blue = 0.08, alpha = 0.9 }
  els[#els + 1] = {
    type = "text",
    frame = { x = BAR_LEFT, y = 0, w = cfg.width - BAR_LEFT - 8, h = cfg.height },
    text = msg, textSize = 12, textColor = { white = 1 }, textAlignment = "left",
  }
  c:replaceElements(els)
  c:show()
  flashing = true
  flashTimer = hs.timer.doAfter(1.5, function()
    flashing = false
    flashTimer = nil
    force_hide()
  end)
end

-- Cycles recording -> processing -> done for manual checks from the console.
function M.demo()
  if not cfg.enabled then return end
  M.recording()
  demoTimers[1] = hs.timer.doAfter(1.5, function() M.processing() end)
  demoTimers[2] = hs.timer.doAfter(3.0, function() M.done() end)
end

return M

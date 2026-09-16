-- Wispr Flow-style floating pill: a tiny opaque capsule flush with the
-- bottom edge of whichever screen has the mouse, that shows recording (real
-- microphone level), processing, done, and error without ever taking
-- keyboard focus.
--
-- One canvas object is created lazily and reused for the process lifetime.
-- Every timer (the processing-state ripple ticker and a pending done()/
-- error() hide) is held in a module local so Hammerspoon's timer GC cannot
-- silently stop it (see dictate.lua's `later()` for the same concern).
--
-- Recording-state bars are NOT self-animated: they move only when
-- dictate.lua calls M.level(l) with a real reading off the WAV sox is
-- writing (see read_level() there). If no level() call ever arrives, the
-- bars simply stay at rest (min height) -- there is no synthetic fallback
-- animation.
local M = {}

local cfg = { enabled = true, width = 60, height = 26, bottom_margin = 10, bars = 12, fps = 20 }

local canvas = nil
local animTimer = nil    -- processing-state ripple ticker only
local flashTimer = nil   -- pending done()/error() auto-hide
local flashing = false   -- true while a done/error flash is in progress
local barHeights = {}    -- smoothed per-bar heights, carried across level() calls
local demoTimers = {}    -- timers used only by demo()
local state = nil        -- "recording" | "processing" | nil; gates M.level()
local pendingState = nil -- "processing" deferred until an in-progress flash ends

local BAR_W, BAR_GAP = 1.5, 1.5 -- pixels

function M.configure(overlay_cfg)
  if type(overlay_cfg) ~= "table" then return end
  for k, v in pairs(overlay_cfg) do cfg[k] = v end
end

local function ensure_canvas()
  if canvas then return canvas end
  canvas = hs.canvas.new({ x = 0, y = 0, w = cfg.width, h = cfg.height })
  canvas:level(hs.canvas.windowLevels.overlay) -- draws above the Dock
  canvas:behavior({ "canJoinAllSpaces", "stationary" })
  canvas:clickActivating(false)
  canvas:alpha(0.95)
  return canvas
end

-- Bottom-center of whichever screen currently has the mouse, floating
-- `bottom_margin` px above the very bottom edge of the display (fullFrame,
-- not frame, so it sits over the Dock rather than above it -- Wispr Flow's
-- own placement). Recomputed on every state change since the user may
-- switch screens mid-session.
local function reposition()
  local c = ensure_canvas()
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  if not screen then return end
  local full = screen:fullFrame()
  c:topLeft({
    x = full.x + (full.w - cfg.width) / 2,
    y = full.y + full.h - cfg.height - cfg.bottom_margin,
  })
end

local function stop_anim()
  if animTimer then animTimer:stop(); animTimer = nil end
end

-- Cancels a pending done()/error() auto-hide, if any, and clears the flag
-- that makes hide() a no-op, plus any deferred processing() (see
-- M.processing()). Called by recording()/done()/error(), which -- unlike
-- processing() -- always cancel-and-take-over rather than defer.
local function stop_flash()
  if flashTimer then flashTimer:stop(); flashTimer = nil end
  flashing = false
  pendingState = nil
end

local function min_h() return 2 end
local function max_h() return cfg.height - 10 end

-- Symmetric envelope: 1.0 at the middle bar, tapering to 0.25 at the edges,
-- so the pill looks like a little waveform instead of a flat block.
local function bar_weight(i, n)
  local center = (n + 1) / 2
  local ratio = math.abs(i - center) / center
  if ratio > 1 then ratio = 1 end
  return 0.25 + 0.75 * (1 - ratio) ^ 1.5
end

local function bars_left()
  local total = cfg.bars * BAR_W + (cfg.bars - 1) * BAR_GAP
  return (cfg.width - total) / 2
end

local function bar_x(i)
  return bars_left() + (i - 1) * (BAR_W + BAR_GAP)
end

local function pill_element()
  return {
    type = "rectangle", action = "fill",
    frame = { x = 0, y = 0, w = cfg.width, h = cfg.height },
    roundedRectRadii = { xRadius = cfg.height / 2, yRadius = cfg.height / 2 },
    fillColor = { red = 0.02, green = 0.02, blue = 0.02, alpha = 1.0 },
  }
end

local function bar_element(i, h, color)
  return {
    type = "rectangle", action = "fill",
    frame = { x = bar_x(i), y = (cfg.height - h) / 2, w = BAR_W, h = h },
    roundedRectRadii = { xRadius = BAR_W / 2, yRadius = BAR_W / 2 },
    fillColor = color,
  }
end

local function redraw(heights, color)
  local c = ensure_canvas()
  local els = { pill_element() }
  for i = 1, cfg.bars do
    els[#els + 1] = bar_element(i, heights[i] or min_h(), color)
  end
  c:replaceElements(els)
end

-- Hides the pill. No-op while a done()/error() flash is in progress (that
-- flash's own timer is responsible for hiding), except that it cancels any
-- deferred processing() (see M.processing()) -- the most recent intent
-- wins, so a hide() that arrives during a flash must not have a stale
-- processing() take over once the flash ends. Otherwise idempotent: safe
-- to call on an already-hidden or never-shown canvas.
function M.hide()
  if not cfg.enabled then return end
  pendingState = nil
  if flashing then return end
  state = nil
  stop_anim()
  if canvas then canvas:hide() end
end

-- Used internally by the done()/error() timers, which must hide even though
-- `flashing` is still true at the moment they fire (they clear it first).
local function force_hide()
  state = nil
  stop_anim()
  if canvas then canvas:hide() end
end

-- Called by the done()/error() flash timers once flashing has been cleared.
-- If processing() was deferred while the flash was in progress (see
-- M.processing()), enter it now instead of hiding -- the capped-recording
-- bug this closes: a cap or an API failure marks the pill red for a full
-- second, and the cleanup work that follows must not cut that short just
-- because it also wants the pill.
local function end_flash()
  if pendingState == "processing" then
    pendingState = nil
    M.processing()
  else
    force_hide()
  end
end

-- Returns the current state string ("recording"/"processing") or nil, for
-- calibration/tests from the console (e.g. confirming a deferred
-- processing() actually took over once a flash finished).
function M.state()
  return state
end

local function reset_bars()
  for i = 1, cfg.bars do barHeights[i] = min_h() end
end

function M.recording()
  if not cfg.enabled then return end
  stop_flash()
  stop_anim()
  reposition()
  state = "recording"
  reset_bars() -- rest at min height until a real level() reading arrives
  redraw(barHeights, { white = 1.0 })
  ensure_canvas():show()
end

-- Real microphone level, 0..1, fed by dictate.lua's WAV-tail reader at
-- cfg.fps. Ignored outside the recording state (e.g. a late/stale reading
-- that arrives after processing() has already taken over).
function M.level(l)
  if not cfg.enabled or state ~= "recording" then return end
  l = l or 0
  if l < 0 then l = 0 elseif l > 1 then l = 1 end
  local lo, hi = min_h(), max_h()
  for i = 1, cfg.bars do
    local w = bar_weight(i, cfg.bars)
    -- The (0.9 + 0.2 * math.random()) factor is +/-10% jitter texture on
    -- top of the real level, not a substitute for it -- it is not the
    -- random bar-height animation that was removed from the recording
    -- state; every bar still tracks `l`, just not perfectly identically.
    local target = lo + (hi - lo) * l * w * (0.9 + 0.2 * math.random())
    local prev = barHeights[i] or lo
    barHeights[i] = prev + (target - prev) * 0.6
  end
  redraw(barHeights, { white = 1.0 })
end

-- Unlike recording()/done()/error(), processing() does NOT cancel an
-- in-progress done()/error() flash: a cap ("Recording stopped: too long")
-- or an API failure that still delivers text is not itself an error, but
-- showing one already is, and it must run its full hold before cleanup's
-- own bars take over. Deferred here; entered by end_flash() once the
-- flash's own timer fires.
function M.processing()
  if not cfg.enabled then return end
  if flashing then
    pendingState = "processing"
    return
  end
  stop_anim()
  reposition()
  state = "processing"
  local color = { white = 0.55 }
  local lo, hi = min_h(), max_h()
  local function tick()
    local heights = {}
    for i = 1, cfg.bars do
      local w = bar_weight(i, cfg.bars)
      local ripple = 0.5 + 0.5 * math.sin(hs.timer.secondsSinceEpoch() * 5 + i * 0.9)
      heights[i] = lo + (hi - lo) * 0.3 * w * ripple
    end
    redraw(heights, color)
  end
  tick()
  ensure_canvas():show()
  animTimer = hs.timer.doEvery(1 / cfg.fps, tick)
end

-- A static envelope (no motion, no randomness) at a fixed level, used by
-- both done() and error() -- they differ only in color and hold time.
local function envelope_heights(level)
  local lo, hi = min_h(), max_h()
  local heights = {}
  for i = 1, cfg.bars do
    heights[i] = lo + (hi - lo) * level * bar_weight(i, cfg.bars)
  end
  return heights
end

function M.done()
  if not cfg.enabled then return end
  stop_flash()
  stop_anim()
  reposition()
  state = nil
  redraw(envelope_heights(0.6), { red = 0.35, green = 0.85, blue = 0.45 })
  ensure_canvas():show()
  flashing = true
  flashTimer = hs.timer.doAfter(0.25, function()
    flashing = false
    flashTimer = nil
    end_flash()
  end)
end

-- `msg` is accepted for API compatibility but not drawn -- the pill never
-- shows text; the existing hs.alert calls already carry the words.
function M.error(_msg)
  if not cfg.enabled then return end
  stop_flash()
  stop_anim()
  reposition()
  state = nil
  redraw(envelope_heights(0.6), { red = 0.95, green = 0.3, blue = 0.3 })
  ensure_canvas():show()
  flashing = true
  flashTimer = hs.timer.doAfter(1.0, function()
    flashing = false
    flashTimer = nil
    end_flash()
  end)
end

-- Cycles recording (fed a synthetic level ramp) -> processing -> done, for
-- manual checks from the console.
function M.demo()
  if not cfg.enabled then return end
  M.recording()
  local t0 = hs.timer.secondsSinceEpoch()
  demoTimers[1] = hs.timer.doEvery(1 / cfg.fps, function()
    local t = hs.timer.secondsSinceEpoch() - t0
    if t > 1.5 then
      if demoTimers[1] then demoTimers[1]:stop(); demoTimers[1] = nil end
      return
    end
    M.level(0.5 + 0.5 * math.sin(t * 6))
  end)
  demoTimers[2] = hs.timer.doAfter(1.5, function() M.processing() end)
  demoTimers[3] = hs.timer.doAfter(3.0, function() M.done() end)
end

return M

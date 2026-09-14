-- Hold-to-talk dictation: sox records, whisper-cli transcribes, a warm
-- headless Claude Code worker cleans up, paste.lua inserts.
-- Config: dictate_config.lua (repo defaults) + ~/.hammerspoon/dictate_local.lua (overrides).
-- Dictionary: ~/.hammerspoon/dictate_dictionary.lua (generated, see scripts/).
local core = require("dictate_core")
local paste = require("paste")

local log = hs.logger.new("dictate", "info")

-- Config ---------------------------------------------------------------------
local cfg = require("dictate_config")
do
  local ok, overrides = pcall(require, "dictate_local")
  if ok and type(overrides) == "table" then
    for k, v in pairs(overrides) do cfg[k] = v end
  end
end

local dictionary = { terms = {}, replacements = {} }
do
  local ok, d = pcall(require, "dictate_dictionary")
  if ok and type(d) == "table" then
    dictionary.terms = d.terms or {}
    dictionary.replacements = d.replacements or {}
  end
end

local SYSTEM_PROMPT = core.build_system_prompt(cfg.prompt, dictionary)
local WHISPER_PROMPT = core.build_whisper_prompt(dictionary.terms, cfg.whisper_prompt_max_chars)

hs.fs.mkdir(cfg.work_dir)

local M = {}

-- Environment for child processes. Hammerspoon's own env lacks ~/.local/bin
-- and /opt/homebrew/bin; the Claude CLI needs HOME for ~/.claude.
local function child_env()
  local home = os.getenv("HOME")
  return {
    HOME = home,
    USER = os.getenv("USER") or "",
    LANG = "en_US.UTF-8",
    TMPDIR = os.getenv("TMPDIR") or "/tmp",
    PATH = home .. "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
  }
end

-- Claude worker ---------------------------------------------------------------
-- One long-lived `claude -p` in stream-json mode. Each request is one user
-- message on stdin; the reply is the `result` event on stdout.
local worker = nil          -- the warm worker serving requests
local pending_worker = nil  -- a replacement that is booting/warming
local worker_generation = 0
local respawn_attempts = 0
local last_used = os.time()

-- Hammerspoon garbage-collects unreferenced timers, so every one-shot timer
-- is held here until it fires.
local timers = {}
local function later(seconds, fn)
  local t
  t = hs.timer.doAfter(seconds, function()
    timers[t] = nil
    fn()
  end)
  timers[t] = true
  return t
end

local spawn_worker   -- forward declaration
local recycle_worker -- forward declaration

local function worker_args()
  return {
    "-p", "--model", cfg.claude_model,
    "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
    "--system-prompt", SYSTEM_PROMPT,
    "--tools", "", "--max-turns", "1",
    "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
    "--setting-sources", "", "--no-session-persistence",
  }
end

local function fail_pending(w, label)
  local p = w.pending
  if not p then return end
  w.pending = nil
  if p.timer then p.timer:stop() end
  p.cb(false, label)
end

local function handle_line(w, line)
  local ev = core.decode_event(line)
  if not ev then return end
  local status, payload = core.decode_result(ev)
  if not status then return end
  local p = w.pending
  if not p then return end
  w.pending = nil
  if p.timer then p.timer:stop() end
  w.requests = w.requests + 1
  if status == "success" then p.cb(true, payload) else p.cb(false, payload) end
end

local function send(w, text, cb)
  if w.pending then cb(false, "busy"); return end
  local p = { cb = cb }
  p.timer = hs.timer.doAfter(cfg.request_timeout_s, function()
    if w.pending == p then
      w.pending = nil
      w.ready = false -- stop routing to a worker that may be hung
      log.w("worker request timed out")
      cb(false, "timeout")
      recycle_worker("request timeout")
    end
  end)
  w.pending = p
  w.task:setInput(core.encode_request(text))
end

local function schedule_respawn(on_ready)
  respawn_attempts = respawn_attempts + 1
  if respawn_attempts > 3 then
    hs.alert.show("Dictation: Claude worker will not start. See Hammerspoon console.")
    return
  end
  later(2, function() spawn_worker(on_ready) end)
end

local function on_worker_exit(w, code, _, stderr)
  if w.pending then fail_pending(w, "exited") end
  if w ~= worker and w ~= pending_worker then return end -- retired worker; nothing to do
  log.w(string.format("worker gen %d exited (code %s): %s", w.gen, tostring(code), (stderr or ""):sub(1, 300)))
  if w == worker then worker = nil end
  if w == pending_worker then pending_worker = nil end
  schedule_respawn(w.on_ready)
end

spawn_worker = function(on_ready)
  if pending_worker then return pending_worker end -- one boot at a time
  worker_generation = worker_generation + 1
  local w = { requests = 0, ready = false, pending = nil, buf = core.LineBuffer.new(),
              gen = worker_generation, on_ready = on_ready }
  w.task = hs.task.new(cfg.claude_bin,
    function(code, out, err) on_worker_exit(w, code, out, err) end,
    function(_, stdout, _)
      for _, line in ipairs(w.buf:push(stdout)) do handle_line(w, line) end
      return true
    end,
    worker_args())
  w.task:setEnvironment(child_env())
  w.task:setWorkingDirectory(cfg.work_dir)
  if not w.task:start() then
    log.e("could not start claude worker at " .. cfg.claude_bin)
    hs.alert.show("Dictation: could not start Claude worker")
    return nil
  end
  pending_worker = w
  -- Warm it so the first real request gets the fast path. The worker starts
  -- serving only once warm; until then `worker` keeps pointing at the old one.
  send(w, "warm up", function(ok, label)
    if not ok then
      log.w("warm-up failed (" .. tostring(label) .. ")")
      if pending_worker == w then pending_worker = nil end
      if w.task:isRunning() then w.task:terminate() end
      schedule_respawn(on_ready)
      return
    end
    w.ready = true
    w.requests = 0 -- the warm-up does not count toward the request cap
    respawn_attempts = 0
    pending_worker = nil
    worker = w
    log.i(string.format("worker gen %d ready (model %s)", w.gen, cfg.claude_model))
    if on_ready then on_ready(w) end
  end)
  return w
end

-- Boot and warm a replacement first, then retire the old one, so nobody waits
-- on startup. If the replacement never warms, the old worker keeps serving.
recycle_worker = function(reason)
  if pending_worker then return end
  local old = worker
  log.i("recycling worker: " .. reason)
  spawn_worker(function(neww)
    if old and old ~= neww and old.task:isRunning() then old.task:terminate() end
  end)
end

function M.restart_worker()
  recycle_worker("manual restart")
end

-- Public: clean up a transcript. cb(ok, text_or_error_label).
function M.cleanup(text, cb)
  last_used = os.time()
  if not worker or not worker.ready then
    cb(false, "worker not ready")
    if not worker and not pending_worker then spawn_worker() end
    return
  end
  local w = worker
  send(w, text, function(ok, result)
    cb(ok, result)
    if ok and w.requests >= cfg.worker_max_requests and w == worker then
      recycle_worker("request cap")
    end
  end)
end

-- Idle recycle so a stale worker does not hold hours-old context.
local idle_timer = hs.timer.doEvery(60, function()
  if worker and worker.requests > 1 and (os.time() - last_used) > cfg.worker_idle_seconds then
    recycle_worker("idle")
    last_used = os.time()
  end
end)
M._idle_timer = idle_timer -- keep a reference so it is not collected

spawn_worker()

-- Menubar ---------------------------------------------------------------------
local menubar = hs.menubar.new()
local GLYPH = {
  idle = "◌",
  recording = hs.styledtext.new("●", { color = { red = 0.9, green = 0.15, blue = 0.15 } }),
  processing = "…",
}
local phase = "idle"

local function set_phase(p)
  phase = p
  if menubar then menubar:setTitle(GLYPH[p] or GLYPH.idle) end
end

local function open_console()
  hs.openConsole()
end

if menubar then
  menubar:setTitle(GLYPH.idle)
  menubar:setTooltip("Dictation: hold Control+Option+Command")
  menubar:setMenu(function()
    return {
      { title = "Dictation: " .. phase .. " (" .. cfg.claude_model .. ")", disabled = true },
      { title = "-" },
      { title = "Restart Claude worker", fn = M.restart_worker },
      { title = "Reload Hammerspoon config", fn = hs.reload },
      { title = "Show console", fn = open_console },
    }
  end)
end

local function alert(msg)
  hs.alert.show(msg, 2)
end

local function finish()
  set_phase("idle")
end

-- Cleanup + paste -------------------------------------------------------------
local function deliver(text)
  local final = core.apply_replacements(text, dictionary.replacements)
  if final ~= "" then
    paste.insert(final, { restore = false })
  end
  finish()
end

local function clean_and_paste(raw)
  set_phase("processing")
  M.cleanup(raw, function(ok, result)
    if ok then
      deliver(result)
    else
      log.w("cleanup failed (" .. tostring(result) .. "); pasting raw text")
      alert("Cleanup failed, pasted raw text")
      deliver(raw)
    end
  end)
end

-- Transcription ----------------------------------------------------------------
local function transcribe(wav, on_done)
  set_phase("processing")
  local args = { "-m", cfg.whisper_model, "-f", wav, "-nt", "-np", "-l", "en" }
  if WHISPER_PROMPT ~= "" then
    args[#args + 1] = "--prompt"; args[#args + 1] = WHISPER_PROMPT
  end
  local t = hs.task.new(cfg.whisper_bin, function(code, stdout, stderr)
    if code ~= 0 then
      log.e("whisper-cli failed: " .. (stderr or ""):sub(1, 400))
      alert("Transcription failed. See Hammerspoon console.")
      on_done(nil)
      return
    end
    on_done(core.parse_whisper(stdout))
  end, args)
  t:setEnvironment(child_env())
  if not t:start() then
    alert("Could not start whisper-cli at " .. cfg.whisper_bin)
    on_done(nil)
  end
end

local function run_pipeline(wav)
  transcribe(wav, function(text)
    os.remove(wav)
    if not text or text == "" then
      if text == "" then log.i("nothing transcribed") end
      finish()
      return
    end
    log.i("transcript: " .. #text .. " chars")
    clean_and_paste(text)
  end)
end

-- Recording -------------------------------------------------------------------
local recorder = nil
local pressed_at = nil
local wav_path = nil
local discard = false

local function wav_has_audio(path)
  local attrs = hs.fs.attributes(path)
  return attrs ~= nil and attrs.size > 44
end

local function on_record_exit(code, _, stderr)
  recorder = nil
  local path = wav_path
  wav_path = nil
  if discard then
    if path then os.remove(path) end
    finish()
    return
  end
  if not path or not wav_has_audio(path) then
    log.e(string.format("rec produced no audio (code %s): %s", tostring(code), (stderr or ""):sub(1, 300)))
    alert("Recording failed. Check Hammerspoon's microphone permission.")
    if path then os.remove(path) end
    finish()
    return
  end
  run_pipeline(path)
end

local function start_recording(quiet)
  if phase ~= "idle" then
    if not quiet then alert("Still processing") end
    return
  end
  discard = false
  pressed_at = hs.timer.secondsSinceEpoch()
  wav_path = hs.fs.temporaryDirectory() .. string.format("dictate-%d.wav", os.time())
  recorder = hs.task.new(cfg.rec_bin, on_record_exit,
    { "-q", "-c", "1", "-r", "16000", "-b", "16", wav_path })
  recorder:setEnvironment(child_env())
  if not recorder:start() then
    recorder = nil
    alert("Could not start rec at " .. cfg.rec_bin)
    return
  end
  set_phase("recording")
end

local function stop_recording()
  if phase ~= "recording" or not recorder then return end
  local held_ms = (hs.timer.secondsSinceEpoch() - pressed_at) * 1000
  if held_ms < cfg.min_hold_ms then discard = true end
  recorder:interrupt() -- SIGINT lets sox finalize the WAV header
end

-- Trigger ---------------------------------------------------------------------
local function flags_match(flags)
  local want = {}
  for _, m in ipairs(cfg.hotkey.mods) do want[m] = true end
  for _, m in ipairs({ "cmd", "alt", "ctrl", "shift", "fn" }) do
    if (flags[m] or false) ~= (want[m] or false) then return false end
  end
  return true
end

if cfg.hotkey.key then
  M._hotkey = hs.hotkey.bind(cfg.hotkey.mods, cfg.hotkey.key, function() start_recording(false) end, stop_recording)
else
  -- Modifier-only hold: record while exactly cfg.hotkey.mods are down.
  local chord_down = false
  M._flags_tap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(ev)
    local match = flags_match(ev:getFlags())
    if match and not chord_down then
      chord_down = true
      start_recording(true)
    elseif not match and chord_down then
      chord_down = false
      stop_recording()
    end
    return false
  end):start()
  -- A real key while the chord is held (e.g. the Ctrl+Alt+Cmd+D date hotkey)
  -- means this was a shortcut, not dictation: drop the recording.
  M._key_tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function()
    if chord_down and phase == "recording" then discard = true end
    return false
  end):start()
end

-- Debug entry points for the console ------------------------------------------
function M.debug_run(wav)
  set_phase("processing")
  transcribe(wav, function(text)
    print("transcript: " .. tostring(text))
    if not text or text == "" then finish() return end
    clean_and_paste(text)
  end)
end

function M.debug_text(text)
  clean_and_paste(text)
end

local startup_problems = {}
for _, p in ipairs({ cfg.rec_bin, cfg.whisper_bin, cfg.claude_bin, cfg.whisper_model }) do
  if not hs.fs.attributes(p) then startup_problems[#startup_problems + 1] = p end
end
if #startup_problems > 0 then
  log.e("missing: " .. table.concat(startup_problems, ", "))
  alert("Dictation setup incomplete. Run setup.sh. See console.")
else
  log.i("ready")
end

_G.dictate = M
return M

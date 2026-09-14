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
local worker = nil          -- current worker table
local worker_generation = 0
local respawn_attempts = 0
local last_used = os.time()

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
      log.w("worker request timed out")
      cb(false, "timeout")
      M.restart_worker()
    end
  end)
  w.pending = p
  w.task:setInput(core.encode_request(text))
end

local spawn_worker -- forward declaration

local function on_worker_exit(w, code, _, stderr)
  if w.pending then fail_pending(w, "exited") end
  if worker ~= w then return end -- an old worker being retired; nothing to do
  log.w(string.format("worker exited (code %s): %s", tostring(code), (stderr or ""):sub(1, 300)))
  worker = nil
  respawn_attempts = respawn_attempts + 1
  if respawn_attempts > 3 then
    hs.alert.show("Dictation: Claude worker keeps dying. See Hammerspoon console.")
    return
  end
  hs.timer.doAfter(2, function() spawn_worker() end)
end

spawn_worker = function(on_ready)
  worker_generation = worker_generation + 1
  local w = { requests = 0, ready = false, pending = nil, buf = core.LineBuffer.new(), gen = worker_generation }
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
  worker = w
  -- Warm it so the first real request gets the fast path.
  send(w, "warm up", function(ok, label)
    if not ok then
      log.w("warm-up failed (" .. tostring(label) .. ")")
      respawn_attempts = respawn_attempts + 1
      if w.task:isRunning() then w.task:terminate() end
      if worker == w then worker = nil end
      if respawn_attempts <= 3 then
        hs.timer.doAfter(2, function() spawn_worker(on_ready) end)
      else
        hs.alert.show("Dictation: Claude worker will not start. See Hammerspoon console.")
      end
      return
    end
    w.ready = true
    respawn_attempts = 0
    log.i(string.format("worker gen %d ready (model %s)", w.gen, cfg.claude_model))
    if on_ready then on_ready(w) end
  end)
  return w
end

-- Boot a replacement first, then retire the old one, so nobody waits on startup.
local function recycle_worker(reason)
  local old = worker
  log.i("recycling worker: " .. reason)
  spawn_worker(function()
    if old and old ~= worker and old.task and old.task:isRunning() then
      old.task:terminate()
    end
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
    if not worker then spawn_worker() end
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

_G.dictate = M
return M

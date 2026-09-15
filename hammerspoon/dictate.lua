-- Hold-to-talk dictation: sox records, whisper-cli transcribes, a warm
-- headless Claude Code worker cleans up, paste.lua inserts.
-- Config: dictate_config.lua (repo defaults) + ~/.hammerspoon/dictate_local.lua
-- (overrides) + <repo>/.env (backend/model/key settings).
-- Dictionary: ~/.hammerspoon/dictate_dictionary.lua (generated, see scripts/).
local core = require("dictate_core")
local paste = require("paste")

local log = hs.logger.new("dictate", "info")

-- ~/.hammerspoon holds symlinks into the repo; hs.fs.pathToAbsolute resolves
-- them to the repo's hammerspoon/ directory. Computed once: used below for
-- the .env lookup, and at the bottom for the repo-edit reload watchers.
local module_dir
do
  local src = debug.getinfo(1, "S").source:sub(2)
  local real = hs.fs.pathToAbsolute(src)
  module_dir = real and real:match("^(.*)/")
end
local ENV_FILE = module_dir and hs.fs.pathToAbsolute(module_dir .. "/../.env")
local REPO_ROOT = module_dir and hs.fs.pathToAbsolute(module_dir .. "/..")

-- Config ---------------------------------------------------------------------
local cfg = require("dictate_config")

-- One level of nested-table merge, so e.g. dictate_local.lua's
-- `cleanup = { backend = ... }` overrides only the fields it sets instead of
-- replacing cfg.cleanup wholesale and dropping timeout_s/local_fallback.
local function merge_into(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then
      for kk, vv in pairs(v) do dst[k][kk] = vv end
    else
      dst[k] = v
    end
  end
end

local overrides = {} -- the dictate_local table, kept for M.compare's re-resolution
do
  local ok, o = pcall(require, "dictate_local")
  if ok and type(o) == "table" then
    overrides = o
    merge_into(cfg, overrides)
  end
end

-- Wispr Flow-style floating pill; see dictate_overlay.lua.
local overlay = require("dictate_overlay")
overlay.configure(cfg.overlay)

-- Cleanup backend resolution: <repo>/.env > dictate_local > dictate_config.
local CLEANUP
do
  local env = {}
  if ENV_FILE then
    local fh = io.open(ENV_FILE)
    if fh then
      env = core.parse_env_file(fh:read("a"))
      fh:close()
    end
  end
  CLEANUP = core.resolve_cleanup(cfg, env, overrides, os.getenv)
  if CLEANUP.reason then log.w("cleanup backend: " .. CLEANUP.reason .. "; using local") end
  cfg.claude_model = CLEANUP.local_model -- the worker section below reads this
end

-- Shared label for the menubar and the startup log.
local function cleanup_label()
  if CLEANUP.backend == "local" then return "local/" .. cfg.claude_model end
  return CLEANUP.backend .. "/" .. CLEANUP.model
end

-- Subtle start/stop/error sounds, like Wispr Flow. Names are macOS system
-- sounds (see /System/Library/Sounds). Set a name to false in config to mute.
local sounds = {}
local function load_sounds()
  for _, k in ipairs({ "start", "stop", "error" }) do
    local name = cfg.sounds and cfg.sounds[k]
    if name then
      local s = hs.sound.getByName(name)
      if s then sounds[k] = s:volume(cfg.sounds.volume or 0.25) else log.w("sound not found: " .. tostring(name)) end
    end
  end
end
local function play_sound(k)
  local s = sounds[k]
  if s then pcall(function() s:stop(); s:play() end) end
end
load_sounds()

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

hs.execute("mkdir -p '" .. cfg.work_dir .. "'")

local M = {}
M.overlay_demo = overlay.demo

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
  if pending_worker then
    if on_ready then
      local prev = pending_worker.on_ready
      pending_worker.on_ready = function(w) if prev then prev(w) end on_ready(w) end
    end
    return pending_worker
  end
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
      schedule_respawn(w.on_ready)
      return
    end
    w.ready = true
    w.requests = 0 -- the warm-up does not count toward the request cap
    respawn_attempts = 0
    pending_worker = nil
    worker = w
    log.i(string.format("worker gen %d ready (model %s)", w.gen, cfg.claude_model))
    if w.on_ready then w.on_ready(w) end
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
  respawn_attempts = 0
  recycle_worker("manual restart")
end

-- Public: clean up a transcript. cb(ok, text_or_error_label).
function M.cleanup(text, cb)
  last_used = os.time()
  if not worker or not worker.ready then
    cb(false, "worker not ready")
    if (not worker or not worker.ready) and not pending_worker then recycle_worker("stale worker") end
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
  if worker and worker.requests > 0 and (os.time() - last_used) > cfg.worker_idle_seconds then
    recycle_worker("idle")
    last_used = os.time()
  end
end)
M._idle_timer = idle_timer -- keep a reference so it is not collected

-- The local worker is the default backend and the automatic fallback for the
-- others, so it spawns whenever either applies.
if CLEANUP.backend == "local" or cfg.cleanup.local_fallback then
  spawn_worker()
end

-- API cleanup -----------------------------------------------------------------
local json = require("json")

-- One transport for every provider adapter. cb(ok, text_or_label).
local function cleanup_api(backend_name, model, key, text, cb)
  local adapter = core.backends[backend_name]
  local req = adapter.build(model, key, SYSTEM_PROMPT, text)
  local done = false
  local started = hs.timer.secondsSinceEpoch()
  local timeout = cfg.cleanup.timeout_s or 10
  later(timeout, function()
    if done then return end
    done = true
    cb(false, "timeout")
  end)
  hs.http.asyncPost(req.url, json.encode(req.body), req.headers, function(status, body, _)
    if done then return end
    done = true
    if status ~= 200 then
      log.w(string.format("%s HTTP %s: %s", backend_name, tostring(status), (body or ""):sub(1, 200)))
      cb(false, "http " .. tostring(status))
      return
    end
    local out, label = adapter.parse(body)
    if not out then cb(false, label or "parse") return end
    log.i(string.format("cleanup via %s/%s in %.2fs", backend_name, model, hs.timer.secondsSinceEpoch() - started))
    cb(true, out)
  end)
end

-- Public: clean up a transcript with the configured backend. cb(ok, text_or_label).
function M.clean(text, cb)
  if CLEANUP.backend == "local" then return M.cleanup(text, cb) end
  cleanup_api(CLEANUP.backend, CLEANUP.model, CLEANUP.key, text, function(ok, out)
    if ok then return cb(true, out) end
    log.w(CLEANUP.backend .. " cleanup failed (" .. tostring(out) .. ")")
    if cfg.cleanup.local_fallback then
      log.i("falling back to local worker")
      return M.cleanup(text, cb)
    end
    cb(false, out)
  end)
end

-- Run one transcript through every backend that has a key, plus local, and
-- write timings and outputs to out_path (default /tmp/dictate-compare.txt).
function M.compare(text, out_path)
  out_path = out_path or "/tmp/dictate-compare.txt"
  local rows, pending = {}, 0
  local function finish_one(name, model, t0, ok, out)
    rows[#rows + 1] = string.format("%-10s %-24s %6.2fs  %s  %s", name, model or "-", hs.timer.secondsSinceEpoch() - t0, ok and "ok " or "ERR", tostring(out))
    pending = pending - 1
    if pending == 0 then
      local f = io.open(out_path, "w"); f:write(table.concat(rows, "\n") .. "\n"); f:close()
      log.i("compare written to " .. out_path) -- console only; never a screen alert
    end
  end
  local env = {}  -- reuse the same resolution as at load: read the .env file again
  if ENV_FILE then
    local fh = io.open(ENV_FILE); if fh then env = core.parse_env_file(fh:read("a")); fh:close() end
  end
  local jobs = { { "local", nil, nil } }
  for _, name in ipairs({ "anthropic", "openai", "gemini" }) do
    -- Force each candidate to resolve as `name` regardless of the globally
    -- configured DICTATE_BACKEND (which would otherwise win precedence for
    -- every candidate): strip DICTATE_BACKEND/DICTATE_MODEL from the env
    -- copy and `cleanup` from the locals copy, so every backend with a key
    -- gets raced, not only the one currently selected.
    local benv = {}
    for k, v in pairs(env) do
      if k ~= "DICTATE_BACKEND" and k ~= "DICTATE_MODEL" then benv[k] = v end
    end
    local blocals = {}
    for k, v in pairs(overrides) do if k ~= "cleanup" then blocals[k] = v end end
    local r = core.resolve_cleanup({ cleanup = { backend = name }, cleanup_models = cfg.cleanup_models }, benv, blocals, os.getenv)
    if r.backend == name then
      -- The actually-configured backend keeps its configured model; the
      -- others use their own provider default (r.model already is that,
      -- since DICTATE_MODEL/cleanup.model were stripped above).
      local model = (name == CLEANUP.backend) and CLEANUP.model or r.model
      jobs[#jobs + 1] = { name, model, r.key }
    end
  end
  pending = #jobs
  for _, j in ipairs(jobs) do
    local t0 = hs.timer.secondsSinceEpoch()
    if j[1] == "local" then M.cleanup(text, function(ok, out) finish_one("local", cfg.claude_model, t0, ok, out) end)
    else cleanup_api(j[1], j[2], j[3], text, function(ok, out) finish_one(j[1], j[2], t0, ok, out) end) end
  end
end

-- Whisper server --------------------------------------------------------------
-- A resident whisper-server keeps the model loaded. A replacement is always
-- booted on the other of two loopback ports and adopted only once it answers,
-- so a restart never leaves a window with no server (mirrors recycle_worker).
local whisper = { active = nil, pending = nil, ready = false, attempts = 0 }

-- Model/language/VAD flags shared by whisper-server and the whisper-cli
-- fallback so both transcribe identically.
local function whisper_model_args()
  local args = { "-m", cfg.whisper_model, "-l", "en", "-nt" }
  if cfg.whisper_vad_model and hs.fs.attributes(cfg.whisper_vad_model) then
    args[#args + 1] = "--vad"; args[#args + 1] = "--vad-model"; args[#args + 1] = cfg.whisper_vad_model
  else
    log.w("VAD model missing (" .. tostring(cfg.whisper_vad_model) .. "); silence may transcribe as text. Run setup.sh")
  end
  return args
end

local function whisper_url(path)
  local port = whisper.active and whisper.active.port or cfg.whisper_port
  return string.format("http://127.0.0.1:%d%s", port, path)
end

local function other_port()
  if whisper.active and whisper.active.port == cfg.whisper_port then return cfg.whisper_port + 1 end
  return cfg.whisper_port
end

local start_server -- forward declaration

local function adopt(entry)
  local old = whisper.active
  whisper.active = entry
  whisper.ready = true
  whisper.attempts = 0
  log.i("whisper-server ready on port " .. entry.port)
  if old and old ~= entry and old.task:isRunning() then old.task:terminate() end
end

-- A 200 on the target port is not proof this entry's own process answered it:
-- something else (another server, a leftover process) may be squatting on the
-- port while whisper-server is still loading its model. whisper-server
-- identifies itself via a "Server: whisper.cpp" header and its HTML title, so
-- check that before trusting readiness.
local function is_whisper_server(status, body, headers)
  if status ~= 200 then return false end
  local server = headers and (headers.Server or headers.server)
  if server == "whisper.cpp" then return true end
  return type(body) == "string" and body:find("Whisper.cpp Server", 1, true) ~= nil
end

local function probe(entry, deadline)
  hs.http.asyncGet(string.format("http://127.0.0.1:%d/", entry.port), nil, function(status, body, headers)
    if not entry.task:isRunning() then return end
    if is_whisper_server(status, body, headers) then
      if whisper.pending == entry then whisper.pending = nil end
      adopt(entry)
      return
    end
    if hs.timer.secondsSinceEpoch() > deadline then
      log.e("whisper-server on port " .. entry.port .. " never became ready; giving up on it")
      if whisper.pending == entry then whisper.pending = nil end
      entry.task:terminate()
      return
    end
    later(0.5, function() probe(entry, deadline) end)
  end)
end

start_server = function(port)
  local entry = { port = port }
  local args = whisper_model_args()
  for _, a in ipairs({ "--host", "127.0.0.1", "--port", tostring(port) }) do args[#args + 1] = a end
  entry.task = hs.task.new(cfg.whisper_server_bin, function(code, _, stderr)
    log.w(string.format("whisper-server (port %d) exited (code %s): %s", port, tostring(code), (stderr or ""):sub(1, 300)))
    local was_pending = (whisper.pending == entry)
    if was_pending then whisper.pending = nil end
    if whisper.active ~= entry then
      if was_pending then
        whisper.attempts = whisper.attempts + 1
        if whisper.attempts <= 3 then
          later(2, function() if not whisper.pending then whisper.pending = start_server(port) end end)
        else
          log.e("whisper-server keeps failing to start; using whisper-cli until 'Restart Whisper server'")
        end
      end
      return -- a retired server; nothing to do
    end
    whisper.active = nil
    whisper.ready = false
    whisper.attempts = whisper.attempts + 1
    if whisper.attempts <= 3 then
      later(2, function() if not whisper.pending then whisper.pending = start_server(port) end end)
    else
      log.e("whisper-server keeps dying; using whisper-cli until 'Restart Whisper server'")
    end
  end, args)
  entry.task:setEnvironment(child_env())
  if not entry.task:start() then
    log.e("could not start whisper-server at " .. cfg.whisper_server_bin)
    return nil
  end
  probe(entry, hs.timer.secondsSinceEpoch() + cfg.whisper_server_boot_s)
  return entry
end

function M.restart_whisper()
  if whisper.pending then return end
  whisper.attempts = 0
  whisper.pending = start_server(other_port())
end

whisper.pending = start_server(cfg.whisper_port)

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
  if p == "processing" then
    overlay.processing()
  elseif p == "idle" then
    overlay.hide() -- no-op while a done()/error() flash is in progress
  end
  -- Recording has no branch here on purpose: the pill and the start sound
  -- are delayed by min_hold_ms (see start_recording) so a quick date-hotkey
  -- tap does not flicker or chirp.
end

local function open_console()
  hs.openConsole()
end

if menubar then
  menubar:setTitle(GLYPH.idle)
  menubar:setTooltip("Dictation: hold Control+Option+Command")
  menubar:setMenu(function()
    return {
      { title = "Dictation: " .. phase .. " (" .. cleanup_label() .. ")", disabled = true },
      { title = "-" },
      { title = "Restart Claude worker", fn = M.restart_worker },
      { title = "Restart Whisper server", fn = M.restart_whisper },
      { title = "Reload Hammerspoon config", fn = hs.reload },
      { title = "Show console", fn = open_console },
    }
  end)
end

local function alert(msg)
  hs.alert.show(msg, 2)
end

-- Cursor context for the dictation in flight: read when the chord is
-- released (the caret is where the text will land), fed to the cleanup
-- model, and used for the spacing of the paste. Never logged.
local insert_ctx = nil

local function capture_context()
  insert_ctx = nil
  if cfg.context and cfg.context.enabled then
    insert_ctx = paste.context(cfg.context.chars)
  end
end

local function finish()
  insert_ctx = nil
  set_phase("idle")
end

-- Cleanup + paste -------------------------------------------------------------
-- skip_done: true when the caller already showed overlay.error() for this
-- delivery (the cleanup-API-failed-but-raw-text-still-pasted path) -- a
-- done() right after would just overwrite the error flash a moment later.
local function deliver(text, skip_done)
  -- Context was read at chord release; if the user has since switched apps
  -- the paste lands somewhere else, so the spacing derived from it is wrong.
  if insert_ctx and insert_ctx.pid then
    local front = hs.application.frontmostApplication()
    if front and front:pid() ~= insert_ctx.pid then insert_ctx = nil end
  end
  local final = core.join_at_cursor(insert_ctx, core.apply_replacements(text, dictionary.replacements))
  if final ~= "" then
    if not paste.insert(final, { restore = false }) then
      hs.pasteboard.setContents(final)
      alert("Copied to clipboard instead")
    end
  end
  if not skip_done then
    overlay.done() -- before finish() so the check-mark actually shows
  end
  finish()
end

local function clean_and_paste(raw)
  set_phase("processing")
  M.clean(core.build_user_message(raw, insert_ctx), function(ok, result)
    if ok then
      -- The transcript had speech (run_pipeline gated it), so an empty answer
      -- is the model dropping everything. Leave a trace; nothing is pasted.
      if result == "" then log.w("cleanup returned nothing for a " .. #raw .. "-char transcript") end
      deliver(result)
    else
      log.w("cleanup failed (" .. tostring(result) .. "); pasting raw text")
      alert("Cleanup failed, pasted raw text")
      overlay.error("Cleanup failed")
      play_sound("error")
      deliver(raw, true)
    end
  end)
end

-- Transcription ----------------------------------------------------------------
local function transcribe_cli(wav, on_done)
  set_phase("processing")
  local args = whisper_model_args()
  for _, a in ipairs({ "-f", wav, "-np" }) do args[#args + 1] = a end
  if WHISPER_PROMPT ~= "" then
    args[#args + 1] = "--prompt"; args[#args + 1] = WHISPER_PROMPT
  end
  local done = false
  local t
  t = hs.task.new(cfg.whisper_bin, function(code, stdout, stderr)
    if done then return end
    done = true
    if code ~= 0 then
      log.e("whisper-cli failed: " .. (stderr or ""):sub(1, 400))
      alert("Transcription failed. See Hammerspoon console.")
      overlay.error("Transcription failed")
      play_sound("error")
      on_done(nil)
      return
    end
    log.i("transcribed via cli")
    on_done(core.parse_whisper(stdout))
  end, args)
  t:setEnvironment(child_env())
  if not t:start() then
    done = true
    alert("Could not start whisper-cli at " .. cfg.whisper_bin)
    on_done(nil)
    return
  end
  later(cfg.transcribe_timeout_s, function()
    if done then return end
    done = true
    log.e("whisper-cli timed out after " .. cfg.transcribe_timeout_s .. "s")
    if t:isRunning() then t:terminate() end
    alert("Transcription timed out")
    overlay.error("Transcription timed out")
    play_sound("error")
    on_done(nil)
  end)
end

-- Resident-server path: POST the WAV with curl. Falls back to whisper-cli
-- when the server is not ready or the request fails.
local function transcribe_server(wav, on_done)
  local done = false
  local target = whisper.active
  local args = { "-s", "-m", tostring(cfg.whisper_request_timeout_s), "-X", "POST", whisper_url("/inference"),
    "-F", "file=@" .. wav, "--form-string", "response_format=json", "--form-string", "temperature=0.0" }
  if WHISPER_PROMPT ~= "" then
    args[#args + 1] = "--form-string"; args[#args + 1] = "prompt=" .. WHISPER_PROMPT
  end
  local t = hs.task.new("/usr/bin/curl", function(code, stdout, stderr)
    if done then return end
    done = true
    local text = (code == 0) and core.parse_server_response(stdout) or nil
    if text == nil then
      log.w(string.format("whisper-server request failed (code %s); falling back to whisper-cli", tostring(code)))
      if whisper.active == target then
        whisper.ready = false
        M.restart_whisper()
      end
      transcribe_cli(wav, on_done)
      return
    end
    log.i("transcribed via server")
    on_done(text)
  end, args)
  t:setEnvironment(child_env())
  if not t:start() then
    done = true
    transcribe_cli(wav, on_done)
  end
end

local function transcribe(wav, on_done)
  set_phase("processing")
  if whisper.ready then
    transcribe_server(wav, on_done)
  else
    transcribe_cli(wav, on_done)
  end
end

local function run_pipeline(wav)
  transcribe(wav, function(text)
    os.remove(wav)
    if not core.has_speech(text) then
      if text then log.i("nothing transcribed") end
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
local stop_recording -- forward declaration; start_recording's watchdog calls it
local rec_seq = 0 -- bumped per recording so a stale watchdog/exit can recognize itself

local function wav_has_audio(path)
  local attrs = hs.fs.attributes(path)
  return attrs ~= nil and attrs.size > 44
end

-- Real microphone level for the overlay: RMS of the last 50 ms of the WAV
-- sox is writing. Cheap enough at 20 fps (1600 bytes per read).
local level_timer = nil
local function read_level(path)
  local f = io.open(path, "rb")
  if not f then return 0 end
  local size = f:seek("end")
  local n = 1600 -- 50 ms at 16 kHz, 16-bit mono
  if not size or size < 44 + n then f:close() return 0 end
  f:seek("set", size - n)
  local data = f:read(n) or ""
  f:close()
  local sum, count = 0, 0
  for i = 1, #data - 1, 2 do
    local s = string.unpack("<i2", data, i)
    sum = sum + s * s
    count = count + 1
  end
  if count == 0 then return 0 end
  local rms = math.sqrt(sum / count)          -- 0..32767
  -- Knee tuned against tests/fixtures/sample.wav: its last 50ms (a soft
  -- trailing breath, not full-volume speech) reads ~154 RMS and needs to
  -- land mid-range; 300 left it under 0.1. See debug_level().
  local KNEE = 15
  local level = math.log(1 + rms / KNEE) / math.log(1 + 32767 / KNEE) -- perceptual-ish 0..1
  if level > 1 then level = 1 end
  return level
end

local function start_level_meter(path, seq)
  if level_timer then level_timer:stop() end
  level_timer = hs.timer.doEvery(1 / cfg.overlay.fps, function()
    if rec_seq ~= seq or phase ~= "recording" then
      if level_timer then level_timer:stop(); level_timer = nil end
      return
    end
    overlay.level(read_level(path))
  end)
end
local function stop_level_meter()
  if level_timer then level_timer:stop(); level_timer = nil end
end

local function on_record_exit(seq, code, _, stderr)
  if seq ~= rec_seq then return end -- a zombie rec from a reset recording; ignore
  -- NB: placed after the seq guard, not before it -- a zombie exit from a
  -- hard-reset recording (see the watchdog below) must not stop the level
  -- meter belonging to whatever NEW recording may already be running.
  stop_level_meter()
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
    overlay.error("Recording failed")
    play_sound("error")
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
  rec_seq = rec_seq + 1
  local my_seq = rec_seq
  pressed_at = hs.timer.secondsSinceEpoch()
  wav_path = hs.fs.temporaryDirectory() .. string.format("dictate-%d.wav", os.time())
  recorder = hs.task.new(cfg.rec_bin,
    function(code, out, err) on_record_exit(my_seq, code, out, err) end,
    -- --buffer is a sox global option and must come first: it keeps rec's
    -- I/O buffer small so bytes hit the file promptly, for the level meter.
    -- 512 (and even 1024) reliably triggers CoreAudio "unhandled buffer
    -- overrun. Data discarded." on this Mac -- dropped audio, not just
    -- lower latency -- confirmed across repeated runs; 2048 showed zero
    -- overruns in the same testing and still keeps latency well under the
    -- meter's 50ms read window.
    { "--buffer", "2048", "-q", "-c", "1", "-r", "16000", "-b", "16", wav_path })
  recorder:setEnvironment(child_env())
  if not recorder:start() then
    recorder = nil
    alert("Could not start rec at " .. cfg.rec_bin)
    return
  end
  set_phase("recording")
  -- Delayed so a quick date-hotkey tap (well under min_hold_ms) never shows
  -- the pill or plays the start chirp.
  later(cfg.min_hold_ms / 1000, function()
    if rec_seq == my_seq and phase == "recording" and not discard then
      overlay.recording()
      play_sound("start")
      start_level_meter(wav_path, my_seq)
    end
  end)
  later(cfg.record_max_s, function()
    if rec_seq ~= my_seq or phase ~= "recording" or not recorder then return end
    log.w("recording exceeded " .. cfg.record_max_s .. "s; stopping")
    alert("Recording stopped: too long")
    -- Not an error: the recording is being capped, not failing, so no
    -- overlay.error()/error sound here. stop_recording() below still plays
    -- the normal stop chirp since real audio was captured (discard is
    -- false on this path).
    stop_recording()
    later(5, function()
      if rec_seq ~= my_seq or phase ~= "recording" then return end
      if recorder and recorder:isRunning() then recorder:terminate() end -- rec ignored SIGINT
      later(5, function()
        if rec_seq ~= my_seq or phase ~= "recording" then return end
        log.e("rec did not exit; resetting")
        stop_level_meter()
        recorder = nil
        if wav_path then os.remove(wav_path) end
        wav_path = nil
        finish()
      end)
    end)
  end)
end

stop_recording = function()
  if phase ~= "recording" or not recorder then return end
  local held_ms = (hs.timer.secondsSinceEpoch() - pressed_at) * 1000
  if held_ms < cfg.min_hold_ms then discard = true end
  if not discard then
    play_sound("stop")
    capture_context()
  end
  stop_level_meter() -- no point reading the tail once the mic has stopped
  recorder:interrupt() -- SIGINT lets sox finalize the WAV header
end

-- Trigger ---------------------------------------------------------------------
if cfg.hotkey.key then
  M._hotkey = hs.hotkey.bind(cfg.hotkey.mods, cfg.hotkey.key, function() start_recording(false) end, stop_recording)
else
  -- Modifier-only hold: record while exactly cfg.hotkey.mods are down.
  local chord_down = false
  local want_mods = {}
  for _, m in ipairs(cfg.hotkey.mods) do want_mods[m] = true end

  -- "exact": only the configured modifiers are down. "superset": all of them
  -- plus at least one more (e.g. Shift added for a date hotkey) — abort, not
  -- release. "none": anything else.
  local function chord_state(flags)
    local all_wanted, extra = true, false
    for _, m in ipairs({ "cmd", "alt", "ctrl", "shift", "fn" }) do
      local wanted = want_mods[m] or false
      local down = flags[m] or false
      if wanted and not down then all_wanted = false end
      if down and not wanted then extra = true end
    end
    if all_wanted and not extra then return "exact" end
    if all_wanted and extra then return "superset" end
    return "none"
  end

  -- Armed only while the chord is held; catches a real key (e.g. the
  -- Ctrl+Alt+Cmd+Shift+D date hotkey) that means this was a shortcut, not
  -- dictation.
  M._key_tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function()
    if phase == "recording" then discard = true end
    return false
  end)

  M._flags_tap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(ev)
    local state = chord_state(ev:getFlags())
    if state == "exact" and not chord_down then
      chord_down = true
      M._key_tap:start()
      start_recording(true)
    elseif state ~= "exact" and chord_down then
      chord_down = false
      M._key_tap:stop()
      if state == "superset" then discard = true end
      stop_recording()
    end
    return false
  end):start()
end

-- Debug entry points for the console ------------------------------------------

-- Runs the overlay's real level reader against a WAV file, for calibration
-- from `hs -c` (no microphone or paste involved). Returns a number 0..1.
function M.debug_level(wav)
  return read_level(wav)
end

function M.debug_run(wav)
  set_phase("processing")
  capture_context()
  transcribe(wav, function(text)
    print("transcript: " .. tostring(text))
    if not core.has_speech(text) then finish() return end
    clean_and_paste(text)
  end)
end

function M.debug_text(text)
  capture_context()
  clean_and_paste(text)
end

-- Cursor context of the focused field, as the pipeline would see it; the
-- text is written to out_path (not printed) so nothing lands in the console.
function M.debug_context(out_path)
  local ctx = paste.context(cfg.context and cfg.context.chars)
  local f = io.open(out_path, "w")
  if not f then return "cannot write " .. tostring(out_path) end
  f:write(ctx and (ctx.before .. "\n---\n" .. ctx.after) or "nil")
  f:close()
  return ctx ~= nil
end

function M.debug_transcribe(wav, out_path)
  transcribe(wav, function(text)
    local f = io.open(out_path, "w")
    f:write(tostring(text))
    f:close()
    finish()
  end)
end

local startup_problems = {}
for _, p in ipairs({ cfg.rec_bin, cfg.whisper_bin, cfg.whisper_server_bin, cfg.claude_bin, cfg.whisper_model }) do
  if not hs.fs.attributes(p) then startup_problems[#startup_problems + 1] = p end
end
if #startup_problems > 0 then
  log.e("missing: " .. table.concat(startup_problems, ", "))
  alert("Dictation setup incomplete. Run setup.sh. See console.")
else
  log.i("ready")
end
log.i("cleanup backend: " .. cleanup_label())

-- ~/.hammerspoon holds symlinks into the repo, and the watcher in init.lua
-- does not see edits to symlink targets. Watch the real directory so editing
-- the repo files reloads too.
if module_dir and module_dir ~= os.getenv("HOME") .. "/.hammerspoon" then
  M._src_watcher = hs.pathwatcher.new(module_dir, function(files)
    for _, f in ipairs(files) do
      if f:sub(-4) == ".lua" then hs.reload() return end
    end
  end):start()
end

-- Reload when the repo-root .env changes (backend/model/key settings).
if REPO_ROOT then
  M._env_watcher = hs.pathwatcher.new(REPO_ROOT, function(files)
    for _, f in ipairs(files) do
      if f:sub(-5) == "/.env" then hs.reload() return end
    end
  end):start()
end

_G.dictate = M
return M

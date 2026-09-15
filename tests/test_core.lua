-- Minimal assert harness. Each test is a function; failures print and exit 1.
local core = require("dictate_core")

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "value", tostring(expected), tostring(actual)), 2)
  end
end

-- parse_whisper -------------------------------------------------------------

test("parse_whisper trims and joins lines", function()
  eq(core.parse_whisper("  Hello there.\n This is a test. \n"), "Hello there. This is a test.")
end)

test("parse_whisper returns empty for blank output", function()
  eq(core.parse_whisper(""), "")
  eq(core.parse_whisper("   \n\n  "), "")
end)

test("parse_whisper drops blank-audio markers", function()
  eq(core.parse_whisper("[BLANK_AUDIO]\n"), "")
  eq(core.parse_whisper(" [BLANK_AUDIO] Hello [BLANK_AUDIO]\n"), "Hello")
end)

test("parse_whisper collapses repeated spaces", function()
  eq(core.parse_whisper("one   two\n\nthree"), "one two three")
end)

-- apply_replacements --------------------------------------------------------

test("apply_replacements is case-insensitive and keeps surrounding text", function()
  eq(core.apply_replacements("Call anchor corps today.", { ["anchor corps"] = "Anchor Corps" }),
     "Call Anchor Corps today.")
  eq(core.apply_replacements("ANCHOR CORPS rocks", { ["anchor corps"] = "Anchor Corps" }),
     "Anchor Corps rocks")
end)

test("apply_replacements matches whole phrases only", function()
  eq(core.apply_replacements("anchorage is far", { ["anchor"] = "Anchor" }), "anchorage is far")
  eq(core.apply_replacements("the anchor, yes", { ["anchor"] = "Anchor" }), "the Anchor, yes")
end)

test("apply_replacements prefers longer phrases", function()
  eq(core.apply_replacements("anchor corps and anchor", { ["anchor"] = "A", ["anchor corps"] = "AC" }),
     "AC and A")
end)

test("apply_replacements handles nil and empty tables", function()
  eq(core.apply_replacements("unchanged", nil), "unchanged")
  eq(core.apply_replacements("unchanged", {}), "unchanged")
end)

test("apply_replacements replaces every occurrence", function()
  eq(core.apply_replacements("kinsta then kinsta", { ["kinsta"] = "Kinsta" }), "Kinsta then Kinsta")
end)

-- LineBuffer ----------------------------------------------------------------

test("LineBuffer returns only complete lines and keeps the remainder", function()
  local b = core.LineBuffer.new()
  local lines = b:push('{"a":1}\n{"b":')
  eq(#lines, 1, "first push count"); eq(lines[1], '{"a":1}')
  lines = b:push('2}\n\n{"c":3}\n')
  eq(#lines, 2, "second push count"); eq(lines[1], '{"b":2}'); eq(lines[2], '{"c":3}')
  eq(#b:push(""), 0, "empty push")
end)

test("LineBuffer strips carriage returns", function()
  local b = core.LineBuffer.new()
  eq(b:push("x\r\n")[1], "x")
end)

-- encode/decode -------------------------------------------------------------

test("encode_request produces a single stream-json user line", function()
  local json = require("json")
  local line = core.encode_request('say "hi"\nnow')
  eq(line:sub(-1), "\n", "trailing newline")
  local ev = json.decode(line)
  eq(ev.type, "user"); eq(ev.message.role, "user"); eq(ev.message.content, 'say "hi"\nnow')
end)

test("decode_event returns nil for garbage and a table for json", function()
  eq(core.decode_event("not json"), nil)
  eq(core.decode_event(""), nil)
  eq(core.decode_event('{"type":"system","subtype":"init"}').subtype, "init")
end)

test("decode_result extracts success text", function()
  local status, text = core.decode_result({ type = "result", subtype = "success", is_error = false, result = "Clean." })
  eq(status, "success"); eq(text, "Clean.")
end)

test("decode_result reports errors", function()
  local status, label = core.decode_result({ type = "result", subtype = "error_during_execution", is_error = true })
  eq(status, "error"); eq(label, "error_during_execution")
  status = core.decode_result({ type = "result", subtype = "success", is_error = true, result = "x" })
  eq(status, "error")
end)

test("decode_result ignores non-result events", function()
  eq(core.decode_result({ type = "assistant" }), nil)
end)

-- prompt builders -----------------------------------------------------------

test("build_system_prompt returns base unchanged without dictionary", function()
  eq(core.build_system_prompt("BASE", nil), "BASE")
  eq(core.build_system_prompt("BASE", { terms = {}, replacements = {} }), "BASE")
end)

test("build_system_prompt appends vocabulary and replacements", function()
  local p = core.build_system_prompt("BASE", { terms = { "Kinsta", "Anchor Corps" }, replacements = { ["call rail"] = "CallRail" } })
  assert(p:find("^BASE\n\n"), "starts with base")
  assert(p:find("Vocabulary", 1, true), "has vocabulary header")
  assert(p:find("- Kinsta", 1, true) and p:find("- Anchor Corps", 1, true), "lists terms")
  assert(p:find('"call rail" -> "CallRail"', 1, true), "lists replacement")
end)

test("build_whisper_prompt joins terms within a length budget", function()
  eq(core.build_whisper_prompt({ "Kinsta", "Anchor Corps", "WordPress" }, 100), "Kinsta, Anchor Corps, WordPress")
  eq(core.build_whisper_prompt({ "Kinsta", "Anchor Corps", "WordPress" }, 15), "Kinsta")
  eq(core.build_whisper_prompt(nil, 100), "")
  eq(core.build_whisper_prompt({}, 100), "")
end)

test("apply_replacements ignores an empty key instead of hanging", function()
  eq(core.apply_replacements("abc", { [""] = "x" }), "abc")
end)

test("apply_replacements passes non-ASCII bytes through untouched", function()
  eq(core.apply_replacements("café anchor", { ["anchor"] = "Anchor" }), "café Anchor")
end)

test("build_whisper_prompt fits an exact budget", function()
  eq(core.build_whisper_prompt({ "abc", "de" }, 7), "abc, de")
  eq(core.build_whisper_prompt({ "abc", "de" }, 6), "abc")
end)

test("parse_server_response extracts and cleans text", function()
  eq(core.parse_server_response('{"text":" Hello there. \\n"}'), "Hello there.")
end)

test("parse_server_response returns nil on garbage or missing text", function()
  eq(core.parse_server_response("not json"), nil)
  eq(core.parse_server_response('{"error":"x"}'), nil)
  eq(core.parse_server_response(""), nil)
end)

-- env file / backend adapters / resolve_cleanup ----------------------------

test("parse_env_file handles comments, blanks, quotes, spaces", function()
  local t = core.parse_env_file("# c\n\nDICTATE_BACKEND = gemini\nGEMINI_API_KEY=\"abc=123\"\nOPENAI_API_KEY='x'\nbad line\n")
  eq(t.DICTATE_BACKEND, "gemini"); eq(t.GEMINI_API_KEY, "abc=123"); eq(t.OPENAI_API_KEY, "x"); eq(t.bad, nil)
end)

test("parse_env_file returns empty table for nil or empty", function()
  eq(next(core.parse_env_file(nil)), nil); eq(next(core.parse_env_file("")), nil)
end)

test("parse_env_file strips an unquoted trailing comment but not a quoted one", function()
  local t = core.parse_env_file('KEY=value   # note\nQUOTED="a # b"\nNOSPACE=value#nospace\n')
  eq(t.KEY, "value")
  eq(t.QUOTED, "a # b")
  eq(t.NOSPACE, "value#nospace") -- a comment needs a space before '#'
end)

test("anthropic build shapes the Messages request", function()
  local r = core.backends.anthropic.build("claude-haiku-4-5", "K", "SYS", "hi")
  eq(r.url, "https://api.anthropic.com/v1/messages"); eq(r.headers["x-api-key"], "K")
  eq(r.body.model, "claude-haiku-4-5"); eq(r.body.system[1].text, "SYS"); eq(r.body.messages[1].content, "hi")
  eq(r.body.system[1].cache_control.type, "ephemeral")
end)

test("anthropic parse extracts the text block", function()
  eq(core.backends.anthropic.parse('{"content":[{"type":"text","text":" Clean. "}],"stop_reason":"end_turn"}'), "Clean.")
end)

test("anthropic parse reports errors and refusals", function()
  local t, e = core.backends.anthropic.parse('{"error":{"type":"authentication_error","message":"bad key"}}')
  eq(t, nil); eq(e, "bad key")
  t, e = core.backends.anthropic.parse('{"content":[],"stop_reason":"refusal"}')
  eq(t, nil); eq(e, "refusal")
  eq((core.backends.anthropic.parse("nope")), nil)
end)

test("openai build shapes the chat request without temperature", function()
  local r = core.backends.openai.build("gpt-5-nano", "K", "SYS", "hi")
  eq(r.url, "https://api.openai.com/v1/chat/completions"); eq(r.headers["Authorization"], "Bearer K")
  eq(r.body.messages[1].role, "system"); eq(r.body.messages[2].content, "hi"); eq(r.body.temperature, nil)
end)

test("openai parse extracts choices[1].message.content", function()
  eq(core.backends.openai.parse('{"choices":[{"message":{"role":"assistant","content":"Clean."}}]}'), "Clean.")
  local t, e = core.backends.openai.parse('{"error":{"message":"quota"}}'); eq(t, nil); eq(e, "quota")
  eq((core.backends.openai.parse('{"choices":[]}')), nil)
end)

test("gemini build shapes generateContent with the model in the URL", function()
  local r = core.backends.gemini.build("gemini-3.5-flash-lite", "K", "SYS", "hi")
  eq(r.url, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent")
  eq(r.headers["x-goog-api-key"], "K"); eq(r.body.system_instruction.parts[1].text, "SYS")
  eq(r.body.contents[1].parts[1].text, "hi"); eq(r.body.generationConfig.temperature, 0)
end)

test("gemini parse concatenates candidate parts", function()
  eq(core.backends.gemini.parse('{"candidates":[{"content":{"parts":[{"text":"Cle"},{"text":"an."}]}}]}'), "Clean.")
  local t, e = core.backends.gemini.parse('{"error":{"message":"denied"}}'); eq(t, nil); eq(e, "denied")
  eq((core.backends.gemini.parse('{"candidates":[]}')), nil)
end)

test("every backend exposes build and parse", function()
  for _, name in ipairs({ "anthropic", "openai", "gemini" }) do
    assert(type(core.backends[name].build) == "function", name .. " build")
    assert(type(core.backends[name].parse) == "function", name .. " parse")
  end
end)

test("resolve_cleanup picks env file over local over defaults", function()
  local cfg = { cleanup = { backend = "local", model = nil }, cleanup_models = { gemini = "g-default" } }
  local r = core.resolve_cleanup(cfg, { DICTATE_BACKEND = "gemini", GEMINI_API_KEY = "envkey" }, {})
  eq(r.backend, "gemini"); eq(r.model, "g-default"); eq(r.key, "envkey")
  r = core.resolve_cleanup(cfg, {}, { gemini_api_key = "localkey" })
  eq(r.backend, "local"); eq(r.key, nil)
  r = core.resolve_cleanup({ cleanup = { backend = "openai", model = "m" }, cleanup_models = {} }, { DICTATE_MODEL = "m2" }, { openai_api_key = "lk" })
  eq(r.backend, "openai"); eq(r.model, "m2"); eq(r.key, "lk")
end)

test("resolve_cleanup falls back to local when the key is missing", function()
  local r = core.resolve_cleanup({ cleanup = { backend = "openai" }, cleanup_models = { openai = "x" } }, {}, {})
  eq(r.backend, "local"); eq(r.reason, "no key for openai")
end)

test("resolve_cleanup treats a blank DICTATE_MODEL as unset", function()
  local cfg = { cleanup = { backend = "anthropic" }, cleanup_models = { anthropic = "provider-default" } }
  local r = core.resolve_cleanup(cfg, { DICTATE_MODEL = "", ANTHROPIC_API_KEY = "k" }, {})
  eq(r.backend, "anthropic"); eq(r.model, "provider-default")
end)

test("resolve_cleanup treats a blank DICTATE_BACKEND as unset", function()
  local cfg = { cleanup = { backend = "anthropic" }, cleanup_models = {} }
  local r = core.resolve_cleanup(cfg, { DICTATE_BACKEND = "", ANTHROPIC_API_KEY = "k" }, {})
  eq(r.backend, "anthropic")
end)

test("resolve_cleanup treats a blank API key as unset and falls back to local", function()
  local cfg = { cleanup = { backend = "anthropic" }, cleanup_models = {} }
  local r = core.resolve_cleanup(cfg, { ANTHROPIC_API_KEY = "" }, {})
  eq(r.backend, "local"); eq(r.reason, "no key for anthropic")
end)

test("resolve_cleanup resolves local_model from env, then locals, then config", function()
  local cfg = { cleanup = { backend = "local" }, cleanup_models = {}, claude_model = "sonnet" }
  local r = core.resolve_cleanup(cfg, { DICTATE_LOCAL_MODEL = "haiku" }, {})
  eq(r.local_model, "haiku")
  r = core.resolve_cleanup(cfg, {}, { claude_model = "opus" })
  eq(r.local_model, "opus")
  r = core.resolve_cleanup(cfg, {}, {})
  eq(r.local_model, "sonnet")
  r = core.resolve_cleanup(cfg, { DICTATE_LOCAL_MODEL = "" }, { claude_model = "opus" })
  eq(r.local_model, "opus")
end)

-- has_speech ----------------------------------------------------------------

test("has_speech is false for empty or punctuation-only transcripts", function()
  eq(core.has_speech(""), false)
  eq(core.has_speech("."), false)
  eq(core.has_speech(" - "), false)
  eq(core.has_speech("..."), false)
  eq(core.has_speech(nil), false)
end)

test("has_speech is true once there is a word", function()
  eq(core.has_speech("ok"), true)
  eq(core.has_speech("Thank you."), true)
  eq(core.has_speech("3"), true)
  eq(core.has_speech("café"), true)
  eq(core.has_speech("é"), true)
end)

-- empty model answers are a valid (empty) result, not an error -------------

test("gemini parse treats an empty STOP candidate as an empty transcript", function()
  local out, label = core.backends.gemini.parse('{"candidates":[{"content":{},"finishReason":"STOP","index":0}]}')
  eq(out, ""); eq(label, nil)
end)

test("gemini parse still errors on a candidate that stopped for another reason", function()
  local out, label = core.backends.gemini.parse('{"candidates":[{"content":{},"finishReason":"SAFETY","index":0}]}')
  eq(out, nil); eq(label, "SAFETY")
end)

test("anthropic parse treats empty content with end_turn as an empty transcript", function()
  local out, label = core.backends.anthropic.parse('{"content":[],"stop_reason":"end_turn"}')
  eq(out, ""); eq(label, nil)
end)

-- cursor context --------------------------------------------------------------

test("build_user_message is the bare transcript without context", function()
  eq(core.build_user_message("hello there", nil), "hello there")
  eq(core.build_user_message("hello there", { before = "", after = "" }), "hello there")
end)

test("build_user_message wraps transcript and context when context exists", function()
  local m = core.build_user_message("and then we left", { before = "We had dinner", after = "" })
  assert(m:find("Text before the cursor", 1, true), "before header")
  assert(m:find("We had dinner", 1, true), "before text")
  assert(m:find("Transcript", 1, true), "transcript header")
  assert(m:find("and then we left", 1, true), "transcript text")
  assert(not m:find("Text after the cursor", 1, true), "no after header when after is empty")
  local m2 = core.build_user_message("x", { before = "", after = "later." })
  assert(m2:find("Text after the cursor", 1, true), "after header")
  assert(not m2:find("Text before the cursor", 1, true), "no before header when before is empty")
end)

test("join_at_cursor adds a space after a word or punctuation before the cursor", function()
  eq(core.join_at_cursor({ before = "We had dinner", after = "" }, "and then left."), " and then left.")
  eq(core.join_at_cursor({ before = "We had dinner.", after = "" }, "Then we left."), " Then we left.")
end)

test("join_at_cursor adds nothing after whitespace, a newline, an opener, or at the start", function()
  eq(core.join_at_cursor({ before = "We had dinner ", after = "" }, "and"), "and")
  eq(core.join_at_cursor({ before = "Notes:\n", after = "" }, "First"), "First")
  eq(core.join_at_cursor({ before = "He said (", after = "" }, "hi"), "hi")
  eq(core.join_at_cursor({ before = 'He said "', after = "" }, "hi"), "hi")
  eq(core.join_at_cursor({ before = "", after = "" }, "Hello."), "Hello.")
  eq(core.join_at_cursor(nil, "Hello."), "Hello.")
end)

test("join_at_cursor adds a trailing space when text follows the cursor immediately", function()
  eq(core.join_at_cursor({ before = "", after = "The end." }, "Start."), "Start. ")
  eq(core.join_at_cursor({ before = "", after = " The end." }, "Start."), "Start.")
  eq(core.join_at_cursor({ before = "", after = ")" }, "inside"), "inside")
  eq(core.join_at_cursor({ before = "a", after = "b" }, ""), "")
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)

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

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)

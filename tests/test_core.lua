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

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)

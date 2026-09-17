#!/bin/bash
# Runs the pure-Lua tests for hammerspoon/dictate_core.lua.
# Requires Homebrew lua: brew install lua
set -euo pipefail
cd "$(dirname "$0")/.."
LUA="${LUA:-$(command -v lua || true)}"
if [ -z "$LUA" ]; then echo "lua not found; run: brew install lua" >&2; exit 2; fi
exec "$LUA" -e 'package.path = "hammerspoon/?.lua;" .. package.path' tests/test_core.lua

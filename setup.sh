#!/bin/bash
# Idempotent setup for the Hammerspoon dictation module. Safe to re-run.
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
HS_DIR="$HOME/.hammerspoon"
MODEL_DIR="$HOME/.local/share/whisper"
WORK_DIR="$HOME/.local/share/dictate/work"
MODEL="${WHISPER_MODEL:-ggml-large-v3-turbo.bin}"

case "$MODEL" in
  ggml-large-v3-turbo.bin) EXPECTED_BYTES=1624555275 ;;
  ggml-small.en.bin)       EXPECTED_BYTES=487614201 ;;
  *) echo "Unknown model $MODEL; add its byte size to setup.sh" >&2; exit 1 ;;
esac

echo "== Homebrew packages"
for f in whisper-cpp sox lua; do
  brew list --formula "$f" >/dev/null 2>&1 || brew install "$f"
done
for bin in /opt/homebrew/bin/rec /opt/homebrew/bin/whisper-cli /opt/homebrew/bin/lua; do
  [ -x "$bin" ] || { echo "Missing $bin after install" >&2; exit 1; }
done

echo "== Whisper model ($MODEL)"
mkdir -p "$MODEL_DIR" "$WORK_DIR"
if [ ! -f "$MODEL_DIR/$MODEL" ] || [ "$(stat -f%z "$MODEL_DIR/$MODEL")" != "$EXPECTED_BYTES" ]; then
  curl -L --fail --progress-bar -o "$MODEL_DIR/$MODEL.part" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL"
  [ "$(stat -f%z "$MODEL_DIR/$MODEL.part")" = "$EXPECTED_BYTES" ] || { echo "Download size mismatch" >&2; exit 1; }
  mv "$MODEL_DIR/$MODEL.part" "$MODEL_DIR/$MODEL"
fi

echo "== Symlinks into $HS_DIR"
mkdir -p "$HS_DIR"
for f in paste.lua json.lua dictate_core.lua dictate_config.lua dictate.lua; do
  ln -sfn "$REPO/hammerspoon/$f" "$HS_DIR/$f"
done

echo "== init.lua requires"
if ! grep -q 'require("dictate")' "$HS_DIR/init.lua" 2>/dev/null; then
  printf '\n-- Hold Control+Option+Command to dictate. See anchor-whisper repo.\nrequire("dictate")\n' >> "$HS_DIR/init.lua"
fi

echo "== Dictionary"
if [ ! -f "$HS_DIR/dictate_dictionary.lua" ]; then
  "$REPO/scripts/import-wispr-dictionary.sh" || echo "No dictionary imported (Wispr Flow not found). Continuing without one."
fi

echo "== Reload Hammerspoon"
touch "$HS_DIR/init.lua"   # the pathwatcher in init.lua reloads on change

cat <<MSG

Done. Permissions Hammerspoon needs:
  * Microphone: macOS will prompt the first time you hold Control+Option+Command.
  * Accessibility: already granted if your date hotkeys paste.
Check the Hammerspoon console for "dictate: ready".
MSG

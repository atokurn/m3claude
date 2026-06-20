#!/usr/bin/env bash
#
# m3claude installer.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/atokurn/m3claude/main/install.sh | bash
#
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/atokurn/m3claude/main"
CMD_NAME="m3claude"
BIN_DIR="${M3CLAUDE_BIN_DIR:-$HOME/.local/bin}"

mkdir -p "$BIN_DIR"

echo "Installing $CMD_NAME to $BIN_DIR ..."
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$REPO_RAW/$CMD_NAME" -o "$BIN_DIR/$CMD_NAME"
  curl -fsSL "$REPO_RAW/proxy.py"  -o "$BIN_DIR/proxy.py"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$BIN_DIR/$CMD_NAME" "$REPO_RAW/$CMD_NAME"
  wget -qO "$BIN_DIR/proxy.py"  "$REPO_RAW/proxy.py"
else
  echo "Need curl or wget." >&2
  exit 1
fi
chmod +x "$BIN_DIR/$CMD_NAME"

echo "Installed: $BIN_DIR/$CMD_NAME"

# Ensure auto-compact is explicitly enabled for m3claude sessions.
# TokenRouter / MiniMax-M3 benefits from context summarization when the
# context window fills; the Claude Code default is also true, but writing
# it explicitly makes the behavior obvious and survives upstream default
# changes. Honored as-is: users can still set DISABLE_AUTO_COMPACT=1 in
# their environment to override.
CLAUDE_SETTINGS_DIR="${CLAUDE_SETTINGS_DIR:-$HOME/.claude}"
CLAUDE_SETTINGS_FILE="$CLAUDE_SETTINGS_DIR/settings.json"
mkdir -p "$CLAUDE_SETTINGS_DIR"
chmod 700 "$CLAUDE_SETTINGS_DIR" 2>/dev/null || true

write_auto_compact() {
  local file="$1"
  if command -v jq >/dev/null 2>&1; then
    local current='{}'
    [ -f "$file" ] && current="$(cat "$file" 2>/dev/null || echo '{}')"
    if printf '%s' "$current" | jq --argjson ac true '. + {autoCompactEnabled: $ac}' > "$file.tmp" 2>/dev/null; then
      mv "$file.tmp" "$file"
    else
      rm -f "$file.tmp"
      return 1
    fi
  else
    # Fallback: parse with python3 (already required by m3claude runtime).
    python3 - "$file" <<'PY'
import json, os, sys
p = sys.argv[1]
try:
    with open(p, 'r', encoding='utf-8') as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
data['autoCompactEnabled'] = True
os.makedirs(os.path.dirname(p), exist_ok=True)
with open(p, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PY
  fi
  chmod 600 "$file" 2>/dev/null || true
}
write_auto_compact "$CLAUDE_SETTINGS_FILE"
echo "Auto-compact enabled in $CLAUDE_SETTINGS_FILE"

case ":$PATH:" in
  *":$BIN_DIR:"*)
    echo "Ready. Run: $CMD_NAME"
    ;;
  *)
    echo
    echo "NOTE: $BIN_DIR is not on your PATH."
    echo "Add this to your shell profile (~/.bashrc or ~/.zshrc):"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    echo "Then open a new terminal and run: $CMD_NAME"
    ;;
esac

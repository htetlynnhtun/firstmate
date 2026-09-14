#!/usr/bin/env bash
# Antigravity CLI Stop hook adapter for firstmate PRIMARY turn-end guard.
#
# Registered in tracked .agents/hooks.json.
# Runs when agy is about to stop the turn. If supervision is in flight and
# watcher is unestablished, bin/fm-turnend-guard.sh exits 2. This adapter
# formats the repair instruction into {"decision": "continue", "reason": "..."}
# to force continuation. If the guard allows the turn end (exit 0), this
# outputs {} and exits 0.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || { printf '{}\n'; exit 0; }

command -v jq >/dev/null 2>&1 || { printf '{}\n'; exit 0; }

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-agy.XXXXXX") || { printf '{}\n'; exit 0; }
trap 'rm -f "$ERR"' EXIT

printf '%s' "$PAYLOAD" | "$FM_ROOT/bin/fm-turnend-guard.sh" 2>"$ERR"
RC=$?

if [ "$RC" -eq 2 ]; then
  REASON=$(cat "$ERR" 2>/dev/null || true)
  [ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'
  jq -n --arg r "$REASON" '{"decision": "continue", "reason": $r}'
  exit 0
fi

printf '{}\n'
exit 0

#!/usr/bin/env bash
# Antigravity CLI PreInvocation hook adapter for firstmate PRIMARY session start.
#
# Registered in tracked .agents/hooks.json for Antigravity's `PreInvocation` step.
# Injects the session-start digest into model context via additionalContext and
# injectSteps when the session has not yet taken the helm. Once completed,
# subsequent turns exit 0 with {} without repeating the startup sweep.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
COMPLETION_FILE="$STATE/.session-start-complete"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_ROOT/bin/fm-session-lock-lib.sh"

session_start_completed() {
  local lock_pid completion_pid
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  [ -f "$COMPLETION_FILE" ] && [ ! -L "$COMPLETION_FILE" ] || return 1
  fm_session_lock_owned_by_self "$STATE" || return 1
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  completion_pid=$(cat "$COMPLETION_FILE" 2>/dev/null) || return 1
  case "$lock_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$completion_pid" = "$lock_pid" ]
}

if session_start_completed; then
  printf '{}\n'
  exit 0
fi

DIGEST=$("$FM_ROOT/bin/fm-sessionstart-run.sh" --source startup </dev/null 2>/dev/null || true)
[ -n "$DIGEST" ] || { printf '{}\n'; exit 0; }

command -v jq >/dev/null 2>&1 || { printf '{}\n'; exit 0; }
jq -n --arg c "$DIGEST" '{
  additionalContext: $c,
  injectSteps: [
    {
      type: "systemMessage",
      message: $c
    }
  ]
}' 2>/dev/null || printf '{}\n'
exit 0

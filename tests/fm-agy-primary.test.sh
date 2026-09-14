#!/usr/bin/env bash
# Behavior tests for Antigravity CLI (agy) as an authorized primary supervisor
# (docs/supervision-protocols/agy.md, docs/verification/agy.md, .agents/hooks.json).
#
# Areas covered:
#   1. Session Lock: Ancestry recognition for `agy`, lock acquisition, and holder liveness.
#   2. Session Start: bin/fm-sessionstart-agy.sh PreInvocation digest injection & dedupe.
#   3. Turn-End Guard: bin/fm-turnend-guard-agy.sh Stop hook continuation handling on exit 2.
#   4. PreToolUse Guards:
#      - bin/fm-arm-pretool-check.sh CommandLine extraction & watcher arm protection.
#      - bin/fm-cd-pretool-check.sh CommandLine extraction & cd projects denial.
#      - bin/fm-subagent-pretool-check.sh tool/name extraction & subagent tool denial.
#   5. Hooks Configuration: .agents/hooks.json structure and registered script paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-primary)
fm_git_identity fmtest fmtest@example.invalid

LOCK_LIB="$ROOT/bin/fm-session-lock-lib.sh"
LOCK_SCRIPT="$ROOT/bin/fm-lock.sh"
START_SCRIPT="$ROOT/bin/fm-sessionstart-agy.sh"
STOP_SCRIPT="$ROOT/bin/fm-turnend-guard-agy.sh"
ARM_SCRIPT="$ROOT/bin/fm-arm-pretool-check.sh"
CD_SCRIPT="$ROOT/bin/fm-cd-pretool-check.sh"
SUBAGENT_SCRIPT="$ROOT/bin/fm-subagent-pretool-check.sh"
HOOKS_CONFIG="$ROOT/.agents/hooks.json"

# Helper to run session-lock library with fake ps
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return 0; }
    $expr
  " "$LOCK_LIB"
}

# --- 1. Session Lock & Ancestry ---------------------------------------------

test_agy_session_lock_ancestry() {
  local dir fakebin got
  dir="$TMP_ROOT/lock-unit"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  850:comm=) printf '%s\n' 'agy' ;;
  850:args=) printf '%s\n' 'agy' ;;
  850:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash -c ...' ;;
  *:ppid=) printf '%s\n' 850 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '850\n' > "$dir/state/.lock"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "agy was not found in the ancestry"
  [ "$got" = 850 ] || fail "ancestry resolved '$got', expected agy pid 850"

  lib_eval "$fakebin" 'fm_harness_pid_alive 850' \
    || fail "a live agy process was not recognized as a harness"

  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the agy session holding the lock did not recognize itself as the owner"

  pass "session-lock: agy is recognized in ancestry and owns the session lock"
}

test_agy_lock_claim_and_status() {
  local dir fakebin out rc
  dir="$TMP_ROOT/lock-claim"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state" "$dir/config" "$dir/data" "$dir/projects"
  cat > "$dir/AGENTS.md" <<'EOF'
# Firstmate
EOF
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
field= pid=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) field=\$2; shift 2 ;;
    -p) pid=\$2; shift 2 ;;
    *) shift ;;
  esac
done
case "\$pid:\$field" in
  $$:comm=) printf '%s\n' 'agy' ;;
  $$:args=) printf '%s\n' 'agy' ;;
  $$:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash ...' ;;
  *:ppid=) printf '%s\n' $$ ;;
esac
SH
  chmod +x "$fakebin/ps"

  # Initial status should be free
  out=$(FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    PATH="$fakebin:$PATH" "$LOCK_SCRIPT" status)
  assert_contains "$out" "lock: free" "initial lock status was not free"

  # Claim the lock as agy process $$
  out=$(FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    PATH="$fakebin:$PATH" "$LOCK_SCRIPT")
  rc=$?
  expect_code 0 "$rc" "agy session failed to acquire lock: $out"
  assert_contains "$out" "lock acquired: harness pid $$" "lock claim message did not name agy pid"
  [ "$(cat "$dir/state/.lock")" = "$$" ] || fail "state/.lock was not written with pid $$"

  # Status should now report held by live harness
  out=$(FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    PATH="$fakebin:$PATH" "$LOCK_SCRIPT" status)
  assert_contains "$out" "lock: held by live harness pid $$" "lock status did not report live agy holder"

  pass "fm-lock.sh: agy acquires session lock and status verifies holder"
}

# --- 2. Session Start (PreInvocation) ---------------------------------------

test_agy_sessionstart_hook_injects_digest() {
  local dir fakebin out rc
  dir="$TMP_ROOT/sessionstart"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/bin" "$dir/state" "$dir/data" "$dir/config"
  printf '# Firstmate\n' > "$dir/AGENTS.md"

  # Fake sessionstart-run: prints a predictable digest and marks completion
  cat > "$dir/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '### Session Start Digest\nAll fleet systems ready.\n'
SH
  chmod +x "$dir/bin/fm-sessionstart-run.sh"
  cp "$LOCK_LIB" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"

  # First run: should produce JSON with additionalContext and injectSteps
  out=$(FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    "$START_SCRIPT")
  rc=$?
  expect_code 0 "$rc" "sessionstart-agy hook failed: $out"

  assert_contains "$out" "additionalContext" "hook output lacked additionalContext"
  assert_contains "$out" "injectSteps" "hook output lacked injectSteps"
  assert_contains "$out" "All fleet systems ready" "hook output omitted the digest"

  # Now write completion marker and own the lock
  printf '%s\n' "$$" > "$dir/state/.lock"
  printf '%s\n' "$$" > "$dir/state/.session-start-complete"

  # Mock ps so lock is owned by self
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
field= pid=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) field=\$2; shift 2 ;;
    -p) pid=\$2; shift 2 ;;
    *) shift ;;
  esac
done
case "\$pid:\$field" in
  $$:comm=) printf '%s\n' 'agy' ;;
  $$:args=) printf '%s\n' 'agy' ;;
  $$:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash ...' ;;
  *:ppid=) printf '%s\n' $$ ;;
esac
SH
  chmod +x "$fakebin/ps"

  # Second run: session start is completed, should return {}
  out=$(FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    PATH="$fakebin:$PATH" "$START_SCRIPT")
  rc=$?
  expect_code 0 "$rc" "sessionstart-agy completed run failed"
  [ "$(printf '%s' "$out" | tr -d '[:space:]')" = '{}' ] \
    || fail "expected empty object {} on completed sessionstart, got '$out'"

  pass "bin/fm-sessionstart-agy.sh: injects digest on first call and deduplicates subsequent calls"
}

# --- 3. Turn-End Guard (Stop Hook) -----------------------------------------

test_agy_turnend_guard_hook() {
  local dir out rc
  dir="$TMP_ROOT/turnend"
  mkdir -p "$dir/bin" "$dir/state"

  # Case A: fm-turnend-guard exits 2 (needs continuation)
  cat > "$dir/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
echo "tasks in flight, no live watcher: repair supervision before turn end" >&2
exit 2
SH
  chmod +x "$dir/bin/fm-turnend-guard.sh"

  out=$(printf '{"hook_event_name":"Stop"}\n' | \
    FM_ROOT_OVERRIDE="$dir" "$STOP_SCRIPT")
  rc=$?
  expect_code 0 "$rc" "turnend-guard-agy hook failed"
  assert_contains "$out" '"decision": "continue"' "hook did not output continue decision"
  assert_contains "$out" "repair supervision before turn end" "hook did not include reason"

  # Case B: fm-turnend-guard exits 0 (allow turn end)
  cat > "$dir/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/bin/fm-turnend-guard.sh"

  out=$(printf '{"hook_event_name":"Stop"}\n' | \
    FM_ROOT_OVERRIDE="$dir" "$STOP_SCRIPT")
  rc=$?
  expect_code 0 "$rc" "turnend-guard-agy hook failed on clean stop"
  [ "$(printf '%s' "$out" | tr -d '[:space:]')" = '{}' ] \
    || fail "expected empty object {} on clean stop, got '$out'"

  pass "bin/fm-turnend-guard-agy.sh: returns decision continue on exit 2 and {} on clean stop"
}

# --- 4. PreToolUse Guards --------------------------------------------------

test_agy_pretool_arm_check() {
  local payload out rc
  # Denied watcher command
  payload='{"CommandLine":"bin/fm-watch.sh"}'
  rc=0
  out=$(printf '%s' "$payload" | "$ARM_SCRIPT") || rc=$?
  [ "$rc" -eq 2 ] || fail "arm pretool check did not deny protected watcher command, got exit $rc"
  assert_contains "$out" '"decision":"deny"' "arm check deny output was not a deny object"

  # Allowed command
  payload='{"CommandLine":"echo hello world"}'
  rc=0
  out=$(printf '%s' "$payload" | "$ARM_SCRIPT") || rc=$?
  expect_code 0 "$rc" "arm pretool check denied safe command: $out"
  [ -z "$out" ] || fail "arm pretool check produced output on allowed command: $out"

  pass "bin/fm-arm-pretool-check.sh: extracts CommandLine and enforces watcher protection"
}

test_agy_pretool_cd_check() {
  local payload out rc

  # Denied cd into projects
  payload='{"CommandLine":"cd projects/foo"}'
  rc=0
  out=$(printf '%s' "$payload" | "$CD_SCRIPT") || rc=$?
  [ "$rc" -eq 2 ] || fail "cd pretool check did not deny cd into projects/, got exit $rc"
  assert_contains "$out" '"decision":"deny"' "cd check deny output was not a deny object"

  # Allowed command
  payload='{"CommandLine":"pwd"}'
  rc=0
  out=$(printf '%s' "$payload" | "$CD_SCRIPT") || rc=$?
  expect_code 0 "$rc" "cd pretool check denied pwd: $out"

  pass "bin/fm-cd-pretool-check.sh: extracts CommandLine and blocks cd into projects/"
}

test_agy_pretool_subagent_check() {
  local payload out rc tool

  for tool in schedule manage_task send_message invoke_subagent define_subagent; do
    payload=$(jq -n --arg t "$tool" '{"name": $t, "args": {}}')
    rc=0
    out=$(printf '%s' "$payload" | "$SUBAGENT_SCRIPT") || rc=$?
    [ "$rc" -eq 2 ] || fail "subagent check did not deny tool '$tool' via name, got exit $rc"
    assert_contains "$out" '"decision":"deny"' "subagent check deny output was not a deny object for '$tool'"

    # Also test via tool field
    payload=$(jq -n --arg t "$tool" '{"tool": $t, "args": {}}')
    rc=0
    out=$(printf '%s' "$payload" | "$SUBAGENT_SCRIPT") || rc=$?
    [ "$rc" -eq 2 ] || fail "subagent check did not deny tool '$tool' via tool field, got exit $rc"
  done

  # Allowed tool
  payload='{"name":"run_command","args":{"CommandLine":"echo 1"}}'
  rc=0
  out=$(printf '%s' "$payload" | "$SUBAGENT_SCRIPT") || rc=$?
  expect_code 0 "$rc" "subagent check denied safe tool run_command: $out"

  pass "bin/fm-subagent-pretool-check.sh: denies subagent tools by name/tool and allows safe tools"
}

# --- 5. Hooks Configuration ------------------------------------------------

test_agy_hooks_json_structure() {
  [ -f "$HOOKS_CONFIG" ] || fail ".agents/hooks.json is missing"
  jq -e . "$HOOKS_CONFIG" >/dev/null 2>&1 || fail ".agents/hooks.json is not valid JSON"

  # Verify PreInvocation hook
  assert_contains "$(jq -r '(.firstmate // .hooks).PreInvocation[0].command' "$HOOKS_CONFIG")" \
    "bin/fm-sessionstart-agy.sh" "PreInvocation hook does not route to fm-sessionstart-agy.sh"

  # Verify Stop hook
  assert_contains "$(jq -r '(.firstmate // .hooks).Stop[0].command' "$HOOKS_CONFIG")" \
    "bin/fm-turnend-guard-agy.sh" "Stop hook does not route to fm-turnend-guard-agy.sh"

  # Verify PreToolUse hooks
  local cmd_hooks
  cmd_hooks=$(jq -r '(.firstmate // .hooks).PreToolUse[] | select(.matcher == "run_command") | .command' "$HOOKS_CONFIG")
  assert_contains "$cmd_hooks" "bin/fm-arm-pretool-check.sh" "PreToolUse lacks arm check"
  assert_contains "$cmd_hooks" "bin/fm-cd-pretool-check.sh" "PreToolUse lacks cd check"

  local subagent_matcher
  subagent_matcher=$(jq -r '(.firstmate // .hooks).PreToolUse[] | select(.command | contains("fm-subagent-pretool-check.sh")) | .matcher' "$HOOKS_CONFIG")
  assert_contains "$subagent_matcher" "schedule" "subagent hook matcher lacks schedule"
  assert_contains "$subagent_matcher" "manage_task" "subagent hook matcher lacks manage_task"
  assert_contains "$subagent_matcher" "send_message" "subagent hook matcher lacks send_message"

  pass ".agents/hooks.json: hooks structure and script routing are verified"
}

# --- Runner -----------------------------------------------------------------

test_agy_session_lock_ancestry
test_agy_lock_claim_and_status
test_agy_sessionstart_hook_injects_digest
test_agy_turnend_guard_hook
test_agy_pretool_arm_check
test_agy_pretool_cd_check
test_agy_pretool_subagent_check
test_agy_hooks_json_structure

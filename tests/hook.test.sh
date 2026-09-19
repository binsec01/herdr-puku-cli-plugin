#!/bin/sh
# Tests for puku-hooks/herdr-status.sh (v1 scope: lifecycle hook only).
# v2 watcher cases are TODO.
. "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/puku-hooks/herdr-status.sh"
STUB="$ROOT/tests/fixtures/herdr-stub.sh"
HERDR_CAPTURE="${HERDR_CAPTURE:-/tmp/herdr-capture.jsonl}"
export HERDR_CAPTURE
export HERDR_BIN_PATH="$STUB"
export HERDR_PANE_ID="pane-123"

# Run the hook with a payload; HERDR_ENV must be set by caller.
run_hook() { echo "$1" | sh "$HOOK"; }

echo "herdr-status.sh (v1 scope: hook events only)"

# 1. No-op when NOT inside herdr (HERDR_ENV unset)
clear_capture
t_title "no-op outside herdr"
unset HERDR_ENV
run_hook '{"hook_event_name":"SessionStart","session_id":"s1"}'
t_assert_eq "0" "$(capture_count)" "should not call herdr"

# 2. SessionStart -> idle + label + session with --session-start-source
clear_capture
t_title "SessionStart reports idle + label + session"
export HERDR_ENV=1
run_hook '{"hook_event_name":"SessionStart","session_id":"sess-abc"}'
t_assert_eq "3" "$(capture_count)" "expected 3 calls (report-agent + report-metadata + report-agent-session)"
t_assert_eq "idle" "$(capture_flag 1 --state)" "SessionStart state is idle"
t_assert_eq "puku-cli" "$(capture_flag 2 --display-agent)" "display-agent label set"
t_assert_eq "sess-abc" "$(capture_flag 3 --agent-session-id)" "session id reported"
t_assert_eq "new" "$(capture_flag 3 --session-start-source)" "session-start-source is new"

# 3. PreToolUse with non-blocking tool -> working
clear_capture
t_title "PreToolUse (Read) reports working"
run_hook '{"hook_event_name":"PreToolUse","tool_name":"Read","session_id":"s1"}'
t_assert_eq "1" "$(capture_count)" "one call"
t_assert_eq "working" "$(capture_flag 1 --state)" "non-blocking tool is working"

# 4. PreToolUse with blocking tool (AskUserQuestion) -> blocked
clear_capture
t_title "PreToolUse (AskUserQuestion) reports blocked"
run_hook '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"choices":["a","b"]},"session_id":"s1"}'
t_assert_eq "blocked" "$(capture_flag 1 --state)" "blocking tool is blocked"

# 5. PostToolUse -> working
clear_capture
t_title "PostToolUse reports working"
run_hook '{"hook_event_name":"PostToolUse","tool_name":"Read","session_id":"s1"}'
t_assert_eq "working" "$(capture_flag 1 --state)" "PostToolUse state"

# 6. Stop -> idle
clear_capture
t_title "Stop reports idle"
run_hook '{"hook_event_name":"Stop","session_id":"s1"}'
t_assert_eq "idle" "$(capture_flag 1 --state)" "Stop state"

# 7. JSON robustness: tool_input is a nested object with commas/braces
clear_capture
t_title "parses event with nested tool_input"
run_hook '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo a, b {c}"},"session_id":"s9"}'
t_assert_eq "working" "$(capture_flag 1 --state)" "non-blocking tool still maps correctly"

# 8. Comma inside session_id value must be preserved verbatim
clear_capture
t_title "comma inside session_id value"
run_hook '{"hook_event_name":"SessionStart","session_id":"a,b,c"}'
t_assert_eq "a,b,c" "$(capture_flag 3 --agent-session-id)" "comma preserved"

# 12. --seq is present and monotonically increasing per pane (authority counter)
if [ "${TMPDIR+x}" = "x" ]; then
  ORIGINAL_TMPDIR=$TMPDIR
  TMPDIR_WAS_SET=1
else
  TMPDIR_WAS_SET=0
fi
TMP_SEQ="$(mktemp -d)"
export TMPDIR="$TMP_SEQ"
export HERDR_PANE_ID="seq-pane-test"
clear_capture
t_title "seq present + increasing"
run_hook '{"hook_event_name":"PreToolUse","tool_name":"Read","session_id":"s1"}'
s1=$(capture_flag 1 --seq)
run_hook '{"hook_event_name":"PostToolUse","tool_name":"Read","session_id":"s1"}'
s2=$(capture_flag 2 --seq)
t_assert_eq "yes" "$([ -n "$s1" ] && [ "$s1" -eq "$s1" ] 2>/dev/null && echo yes || echo no)" "seq is numeric"
t_assert_eq "yes" "$([ "$s2" -gt "$s1" ] 2>/dev/null && echo yes || echo no)" "seq increases across calls"
rm -rf "$TMP_SEQ"
if [ "$TMPDIR_WAS_SET" -eq 1 ]; then
  export TMPDIR="$ORIGINAL_TMPDIR"
else
  unset TMPDIR
fi

# --- v2 cases (skipped in v1) ---
# [v1] # TODO: enable in v2
# 9.  Exact visible shell-command permission prompt -> blocked
# 10. Near miss must not match only one prompt line.
# 11. A matching screen reports once until the prompt clears, then can report again.
# 13. Plan mode prompt in visible pane -> blocked
# 14. Act mode prompt in visible pane -> blocked
# 15. Near-miss plan mode prompt is ignored
# 16. Full review card in the visible pane -> blocked
# 17-21. Review card edge cases (visible-only / detection / stale scrollback / reset)
#
# Reason: we don't yet know the literal text puku-cli renders for these prompts.
# To enable, capture the literal strings from a live puku-cli session, fill in
# the BLOCKING_SIGNAL_* constants in puku-hooks/herdr-status.sh, set
# BLOCKING_PROMPT_WATCHER_ENABLED=1, and port the corresponding cases from
# herdr-commandcode-plugin/tests/hook.test.sh.

summary

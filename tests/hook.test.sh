#!/bin/sh
# Tests for puku-plugin/hooks/herdr-status.sh (lifecycle hook + blocking-prompt watcher).
. "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/puku-plugin/hooks/herdr-status.sh"
STUB="$ROOT/tests/fixtures/herdr-stub.sh"
HERDR_CAPTURE="${HERDR_CAPTURE:-/tmp/herdr-capture.jsonl}"
export HERDR_CAPTURE
export HERDR_BIN_PATH="$STUB"
export HERDR_PANE_ID="pane-123"
# SessionStart starts a watcher in production. Keep test watchers single-scan
# so they cannot outlive this test process.
export HERDR_PERMISSION_MAX_SCANS=1

# Run the hook with a payload; HERDR_ENV must be set by caller.
run_hook() { echo "$1" | sh "$HOOK"; }

# puku-cli blocking-prompt literals under test.
PERMISSION_PROMPT='Do you want to proceed?
Esc to cancel'
EDIT_PROMPT='Do you want to make this edit to src/app.js?
Esc to cancel'
PLAN_MODE_PROMPT='Enter plan mode?'
REVIEW_CARD='Puku has written up a plan and is ready to execute. Would you like to proceed?
❯ 1. Yes, manually approve edits
  2. No, keep planning'

echo "herdr-status.sh"

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

# 3. UserPromptSubmit -> working
clear_capture
t_title "UserPromptSubmit reports working"
run_hook '{"hook_event_name":"UserPromptSubmit","prompt":"explain TOCTOU","session_id":"s1"}'
t_assert_eq "1" "$(capture_count)" "one call"
t_assert_eq "working" "$(capture_flag 1 --state)" "prompt submit is working"

# 4. PreToolUse with non-blocking tool -> working
clear_capture
t_title "PreToolUse (Read) reports working"
run_hook '{"hook_event_name":"PreToolUse","tool_name":"Read","session_id":"s1"}'
t_assert_eq "1" "$(capture_count)" "one call"
t_assert_eq "working" "$(capture_flag 1 --state)" "non-blocking tool is working"

# 5. PreToolUse with puku-cli blocking tools -> blocked
for blocking_tool in AskUserQuestion ExitPlanMode Edit Write NotebookEdit; do
  clear_capture
  t_title "PreToolUse ($blocking_tool) reports blocked"
  run_hook "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"$blocking_tool\",\"tool_input\":{},\"session_id\":\"s1\"}"
  t_assert_eq "blocked" "$(capture_flag 1 --state)" "$blocking_tool is blocking"
done

# 6. PostToolUse / PostToolUseFailure / PermissionDenied -> working
for working_event in PostToolUse PostToolUseFailure PermissionDenied; do
  clear_capture
  t_title "$working_event reports working"
  run_hook "{\"hook_event_name\":\"$working_event\",\"tool_name\":\"Read\",\"session_id\":\"s1\"}"
  t_assert_eq "1" "$(capture_count)" "one call"
  t_assert_eq "working" "$(capture_flag 1 --state)" "$working_event reports working"
done

# 7. Stop / StopFailure / SessionEnd -> idle
for idle_event in Stop StopFailure SessionEnd; do
  clear_capture
  t_title "$idle_event reports idle"
  run_hook "{\"hook_event_name\":\"$idle_event\",\"session_id\":\"s1\"}"
  t_assert_eq "1" "$(capture_count)" "one call"
  t_assert_eq "idle" "$(capture_flag 1 --state)" "$idle_event reports idle"
done

# 8. JSON robustness: tool_input is a nested object with commas/braces
clear_capture
t_title "parses event with nested tool_input"
run_hook '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo a, b {c}"},"session_id":"s9"}'
t_assert_eq "working" "$(capture_flag 1 --state)" "non-blocking tool still maps correctly"

# 9. Comma inside session_id value must be preserved verbatim
clear_capture
t_title "comma inside session_id value"
run_hook '{"hook_event_name":"SessionStart","session_id":"a,b,c"}'
t_assert_eq "a,b,c" "$(capture_flag 3 --agent-session-id)" "comma preserved"

# 10. Exact shell permission dialog (question + cancel footer) -> blocked
clear_capture
t_title "shell permission dialog reports blocked"
export HERDR_PANE_CONTENT='Execute Shell Command
Do you want to proceed?
❯ 1. Yes
  2. Yes, and do not ask again
  3. No
Esc to cancel'
sh "$HOOK" --watch-shell-permission
t_assert_eq "1" "$(capture_count)" "one blocked report"
t_assert_eq "blocked" "$(capture_flag 1 --state)" "permission dialog is blocked"
t_assert_eq "puku-cli" "$(capture_flag 1 --source)" "uses puku-cli authority"
t_assert_eq "puku-cli" "$(capture_flag 1 --agent)" "uses puku-cli agent label"
permission_seq=$(capture_flag 1 --seq)
t_assert_eq "yes" "$([ -n "$permission_seq" ] && [ "$permission_seq" -eq "$permission_seq" ] 2>/dev/null && echo yes || echo no)" "blocked report has numeric seq"

# 11. The question line alone must not match (ordinary prose).
clear_capture
t_title "proceed question without cancel footer is ignored"
export HERDR_PANE_CONTENT='Do you want to proceed? That is what the review asked.'
sh "$HOOK" --watch-shell-permission
t_assert_eq "0" "$(capture_count)" "question line alone does not report blocked"

# 12. The cancel footer alone must not match.
clear_capture
t_title "cancel footer without question is ignored"
export HERDR_PANE_CONTENT='Press Esc to cancel whenever you are done writing.'
sh "$HOOK" --watch-shell-permission
t_assert_eq "0" "$(capture_count)" "footer alone does not report blocked"

# 13. A matching screen reports once until the prompt clears, then can report again.
clear_capture
t_title "permission watcher debounces and resets"
PERMISSION_TMP=$(mktemp -d)
export HERDR_PANE_CONTENT_VISIBLE_SEQUENCE_FILE="$PERMISSION_TMP/screens"
export HERDR_PANE_READ_COUNT_VISIBLE_FILE="$PERMISSION_TMP/read-count"
export HERDR_PANE_CONTENT_DETECTION=''
unset HERDR_PANE_CONTENT
printf '%s\n---HERDR-PANE-READ---\n%s\n---HERDR-PANE-READ---\n\n---HERDR-PANE-READ---\n%s' \
  "$PERMISSION_PROMPT" \
  "$PERMISSION_PROMPT" \
  "$PERMISSION_PROMPT" > "$HERDR_PANE_CONTENT_VISIBLE_SEQUENCE_FILE"
export HERDR_PERMISSION_MAX_SCANS=4
sh "$HOOK" --watch-shell-permission
t_assert_eq "2" "$(capture_count)" "one report before and after the prompt clears"
t_assert_eq "blocked" "$(capture_flag 1 --state)" "first matching screen is blocked"
t_assert_eq "blocked" "$(capture_flag 2 --state)" "matching screen after clear is blocked"
rm -rf "$PERMISSION_TMP"
unset HERDR_PANE_CONTENT_VISIBLE_SEQUENCE_FILE HERDR_PANE_READ_COUNT_VISIBLE_FILE HERDR_PANE_CONTENT_DETECTION
export HERDR_PERMISSION_MAX_SCANS=1

# 14. Edit confirmation prompt in visible pane -> blocked
clear_capture
t_title "edit confirmation prompt reports blocked"
export HERDR_PANE_CONTENT="$EDIT_PROMPT"
sh "$HOOK" --watch-shell-permission
t_assert_eq "1" "$(capture_count)" "one blocked report"
t_assert_eq "blocked" "$(capture_flag 1 --state)" "edit confirmation is blocked"

# 15. Plan mode entry prompt in visible pane -> blocked
clear_capture
t_title "plan mode prompt reports blocked"
export HERDR_PANE_CONTENT="$PLAN_MODE_PROMPT"
sh "$HOOK" --watch-shell-permission
t_assert_eq "1" "$(capture_count)" "one blocked report"
t_assert_eq "blocked" "$(capture_flag 1 --state)" "plan mode prompt is blocked"

# 16. Near-miss plan mode prompt is ignored
clear_capture
t_title "near-miss plan mode prompt is ignored"
export HERDR_PANE_CONTENT='Enter plan mode for read-only exploration'
sh "$HOOK" --watch-shell-permission
t_assert_eq "0" "$(capture_count)" "partial match does not report blocked"

# 17. Full plan review card in the visible pane -> blocked
clear_capture
t_title "visible review card reports blocked"
export HERDR_PANE_CONTENT="$REVIEW_CARD"
sh "$HOOK" --watch-shell-permission
t_assert_eq "1" "$(capture_count)" "one blocked report"
t_assert_eq "blocked" "$(capture_flag 1 --state)" "review prompt is blocked"

# 18. The ready sentence alone is not enough to mark the pane blocked.
clear_capture
t_title "ready sentence without approval option is ignored"
export HERDR_PANE_CONTENT='Would you like to proceed?'
sh "$HOOK" --watch-shell-permission
t_assert_eq "0" "$(capture_count)" "ready sentence alone does not report blocked"

# 19. Approval text alone is not enough to mark the pane blocked.
clear_capture
t_title "approval text without review card is ignored"
export HERDR_PANE_CONTENT='Yes, manually approve edits'
sh "$HOOK" --watch-shell-permission
t_assert_eq "0" "$(capture_count)" "approval text alone does not report blocked"

# 20. Detection is a live fallback when the review card is outside the viewport.
clear_capture
t_title "detection review card reports blocked"
export HERDR_PANE_CONTENT_VISIBLE='working on implementation'
export HERDR_PANE_CONTENT_DETECTION="$REVIEW_CARD"
sh "$HOOK" --watch-shell-permission
t_assert_eq "1" "$(capture_count)" "one blocked report from detection"
t_assert_eq "blocked" "$(capture_flag 1 --state)" "detection review card is blocked"
unset HERDR_PANE_CONTENT_VISIBLE HERDR_PANE_CONTENT_DETECTION

# 21. Stale scrollback must not keep the pane blocked after approval.
clear_capture
t_title "stale unwrapped review card is ignored"
export HERDR_PANE_CONTENT_VISIBLE='implementation is running'
export HERDR_PANE_CONTENT_DETECTION='implementation is running'
export HERDR_PANE_CONTENT_RECENT_UNWRAPPED="$REVIEW_CARD"
sh "$HOOK" --watch-shell-permission
t_assert_eq "0" "$(capture_count)" "scrollback-only review card is ignored"
unset HERDR_PANE_CONTENT_VISIBLE HERDR_PANE_CONTENT_DETECTION HERDR_PANE_CONTENT_RECENT_UNWRAPPED

# 22. A resolved review card resets the watcher so a later review reports blocked.
clear_capture
t_title "review watcher resets after approval"
REVIEW_TMP=$(mktemp -d)
export HERDR_PANE_CONTENT_VISIBLE_SEQUENCE_FILE="$REVIEW_TMP/screens"
export HERDR_PANE_READ_COUNT_VISIBLE_FILE="$REVIEW_TMP/read-count"
export HERDR_PANE_CONTENT_DETECTION=''
unset HERDR_PANE_CONTENT
printf '%s\n---HERDR-PANE-READ---\n%s\n---HERDR-PANE-READ---\n\n---HERDR-PANE-READ---\n%s' \
  "$REVIEW_CARD" \
  "$REVIEW_CARD" \
  "$REVIEW_CARD" > "$HERDR_PANE_CONTENT_VISIBLE_SEQUENCE_FILE"
export HERDR_PERMISSION_MAX_SCANS=4
sh "$HOOK" --watch-shell-permission
t_assert_eq "2" "$(capture_count)" "review reports before and after a resolved card"
t_assert_eq "blocked" "$(capture_flag 1 --state)" "first review card is blocked"
t_assert_eq "blocked" "$(capture_flag 2 --state)" "later review card is blocked"
rm -rf "$REVIEW_TMP"
unset HERDR_PANE_CONTENT_VISIBLE_SEQUENCE_FILE HERDR_PANE_READ_COUNT_VISIBLE_FILE HERDR_PANE_CONTENT_DETECTION
export HERDR_PERMISSION_MAX_SCANS=1

# 23. --seq is present and monotonically increasing per pane (authority counter)
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

summary

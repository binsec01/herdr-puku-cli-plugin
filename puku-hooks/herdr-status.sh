#!/bin/sh
# puku-cli -> Herdr status hook.
#
# Installed as a puku-cli hook (SessionStart / PreToolUse / PostToolUse / Stop).
# It runs INSIDE the live puku-cli process so puku-cli does NOT need to exit
# for herdr to learn its status. Mirrors the Command Code herdr-status.sh
# pattern (which itself mirrors the OpenCode herdr-agent-state.js plugin):
# SessionStart claims the agent and reports `idle`, PreToolUse reports
# `working` (only `blocked` for interactive blocking tools), PostToolUse
# reports `working`, Stop reports `idle`.
#
# The agent claim is kept alive for the pane's lifetime so herdr keeps showing
# the agent even when the matched puku-cli process ends between turns.
#
# puku-cli invokes this with a JSON hook payload on stdin:
#   { "hook_event_name": "...", "session_id": "...", "cwd": "...",
#     "tool_name": "...", "tool_input": {...} }
#
# It reports to herdr through $HERDR_BIN_PATH (the running herdr binary). When
# puku-cli is not running inside herdr (no HERDR_ENV), the hook is a no-op.
#
# v1 scope: hook-event-driven state only (PreToolUse -> blocked vs working,
# PostToolUse -> working, Stop -> idle, SessionStart -> idle + label + session).
# The visible-pane blocking-prompt watcher is scaffolded but DISABLED in v1
# (see BLOCKING_PROMPT_WATCHER_ENABLED below). v2 will turn it on after we
# observe the literal text puku-cli renders for permission/plan/act/review
# prompts in a live session.

HERDR="${HERDR_BIN_PATH:-herdr}"

# Only act when puku-cli is running inside a managed herdr pane.
[ "${HERDR_ENV:-}" = "1" ] || exit 0
PANE_ID="${HERDR_PANE_ID:-}"
[ -n "$PANE_ID" ] || exit 0

# Monotonic authority counter. Uses nanosecond-precision timestamp as seed
# so each report carries a unique, always-increasing seq, matching OpenCode's
# `reportSeq = Date.now() * 1000` + increment pattern.
SEQ_FILE="${TMPDIR:-/tmp}/herdr-puku-cli-seq-${PANE_ID}"
next_seq() {
  lock_dir="${SEQ_FILE}.lock"
  attempts=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 100 ] || return 1
    sleep 0.01
  done

  if [ -f "$SEQ_FILE" ]; then
    seq=$(cat "$SEQ_FILE" 2>/dev/null | tr -dc '0-9')
  else
    seq=$(node -e 'process.stdout.write(String(Date.now()*1000))')
  fi
  seq=$(( ${seq:-0} + 1 ))
  printf '%s' "$seq" > "$SEQ_FILE"
  rmdir "$lock_dir" 2>/dev/null
  printf '%s' "$seq"
}

report() {
  "$HERDR" pane report-agent "$PANE_ID" \
    --source puku-cli --agent puku-cli --state "$1" --seq "$(next_seq)" >/dev/null 2>&1
}

# Claim the agent label on BOTH surfaces (agent panel + space/tab). Without
# this, surfaces that can't infer the agent from the process fall back to
# `unknown` (red dot). Mirrors how OpenCode's herdr plugin establishes the
# agent identity once per session.
label() {
  "$HERDR" pane report-metadata "$PANE_ID" \
    --source puku-cli --agent puku-cli --display-agent puku-cli >/dev/null 2>&1
}

# v1: blocking-prompt watcher scaffolding kept but disabled.
# We don't yet know the literal text puku-cli renders for these prompts.
# To enable in v2: replace `return 0` with the real watcher (see
# Command Code herdr-status.sh for the reference implementation), capture the
# literal strings in a live session, and set BLOCKING_PROMPT_WATCHER_ENABLED=1.
BLOCKING_PROMPT_WATCHER_ENABLED=0

# Internal test/worker modes must not consume a puku-cli JSON payload.
case "${1:-}" in
  --watch-shell-permission)
    exit 0
    ;;
esac

# Read the hook payload (one JSON object) from stdin.
PAYLOAD=$(cat)

# Robust extraction: parse JSON instead of pattern-matching.
EVENT=$(printf '%s' "$PAYLOAD"   | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{const j=JSON.parse(d);process.stdout.write(j.hook_event_name||"")}catch{}})')
SESSION=$(printf '%s' "$PAYLOAD" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{const j=JSON.parse(d);process.stdout.write(j.session_id||"")}catch{}})')
TOOL=$(printf '%s' "$PAYLOAD"    | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{const j=JSON.parse(d);process.stdout.write(j.tool_name||"")}catch{}})')

# Blocking tools are the ones that pause puku-cli waiting for user
# input/decision (arrow-key choices, permission prompts). v1 uses the
# Command Code list as a conservative default; v2 should verify against
# actual puku-cli tool names.
is_blocking_tool() {
  case "$TOOL" in
    AskUserQuestion|Question|ask_user_question|question|edit_file|write_file) return 0 ;;
    *) return 1 ;;
  esac
}

case "$EVENT" in
  SessionStart)
    report idle
    label
    if [ -n "$SESSION" ]; then
      "$HERDR" pane report-agent-session "$PANE_ID" \
        --source puku-cli --agent puku-cli \
        --agent-session-id "$SESSION" \
        --session-start-source new \
        --seq "$(next_seq)" >/dev/null 2>&1
    fi
    ;;
  PreToolUse)
    if is_blocking_tool; then
      report blocked
    else
      report working
    fi
    ;;
  PostToolUse)
    report working
    ;;
  Stop)
    report idle
    ;;
esac

exit 0

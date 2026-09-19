#!/bin/sh
# puku-cli -> Herdr status hook.
#
# Installed as a puku-cli hook (SessionStart / UserPromptSubmit / PreToolUse /
# PostToolUse / PostToolUseFailure / PermissionDenied / Stop / StopFailure /
# SessionEnd). It runs INSIDE the live puku-cli process so puku-cli does NOT
# need to exit for herdr to learn its status. Mirrors the Command Code
# herdr-status.sh pattern (which itself mirrors the OpenCode
# herdr-agent-state.js plugin).
#
# State model
#   SessionStart          -> idle  (+ agent label + session id + start watcher)
#   UserPromptSubmit      -> working
#   PreToolUse (blocking) -> blocked
#   PreToolUse (other)    -> working
#   PostToolUse           -> working
#   PostToolUseFailure    -> working
#   PermissionDenied      -> working
#   Stop / StopFailure    -> idle
#   SessionEnd            -> idle
#
# Prompts that are NOT tool calls (shell-command permission, file-edit
# confirmation, plan-mode entry, plan-review card) are matched from the live
# visible pane by watch_blocking_prompt(). The visible pane is authoritative and
# scrollback is never consulted, so an approved prompt cannot leave the pane
# stuck on `blocked`.
#
# PermissionRequest is deliberately NOT wired: puku-cli treats a hook exit code
# of 0 as "allow", so registering it would risk auto-approving permission
# prompts. Shell permissions are covered by the visible-pane watcher instead
# (same approach as the Command Code integration).
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

# puku-cli renders blocking prompts on the visible pane when waiting for user
# input/decision. These are read from the live screen, rather than history, so a
# resolved prompt cannot keep the pane blocked on a later turn.
#
# Shell command / file-edit permission:
#   Do you want to proceed?
#   Esc to cancel
#
# File edit confirmation:
#   Do you want to make this edit to <path>?
#
# Plan-mode entry (card title):
#   Enter plan mode?
#
# Plan review / approval card:
#   Puku has written up a plan and is ready to execute. Would you like to proceed?
#   Yes, manually approve edits / No, keep planning
#
# The permission dialog is a two-part signal: the question line alone can appear
# in ordinary assistant prose, so the cancel footer must be in the same live
# snapshot.
BLOCKING_SIGNAL_PERMISSION='Do you want to proceed?'
BLOCKING_SIGNAL_PERMISSION_FOOTER='Esc to cancel'
BLOCKING_SIGNAL_EDIT_PROMPT='Do you want to make this edit to'
BLOCKING_SIGNAL_PLAN_MODE='Enter plan mode?'
# Require the plan-ready sentence and an approval option in the same snapshot.
BLOCKING_SIGNAL_REVIEW_READY='Would you like to proceed?'
BLOCKING_SIGNAL_REVIEW_APPROVAL='manually approve edits'

has_review_card() {
  case "$1" in
    *"$BLOCKING_SIGNAL_REVIEW_READY"*"$BLOCKING_SIGNAL_REVIEW_APPROVAL"*) return 0 ;;
    *) return 1 ;;
  esac
}

has_permission_dialog() {
  case "$1" in
    *"$BLOCKING_SIGNAL_PERMISSION"*"$BLOCKING_SIGNAL_PERMISSION_FOOTER"*) return 0 ;;
    *) return 1 ;;
  esac
}

# The visible pane is authoritative for all normal prompts. It also catches the
# plan review card when it is onscreen.
has_visible_blocking_prompt() {
  pane_content=$("$HERDR" pane read "$PANE_ID" --source visible 2>/dev/null) || return 2
  has_permission_dialog "$pane_content" && return 0
  for signal in "$BLOCKING_SIGNAL_EDIT_PROMPT" "$BLOCKING_SIGNAL_PLAN_MODE"; do
    case "$pane_content" in
      *"$signal"*) return 0 ;;
    esac
  done
  has_review_card "$pane_content"
}

# The detection snapshot is another live, plain-text rendering. It is only a
# fallback for a plan review card, which can sit outside the visible viewport.
# Do not read recent/recent-unwrapped here: they retain resolved cards in
# scrollback and would leave the agent incorrectly blocked.
has_detection_review_card() {
  pane_content=$("$HERDR" pane read "$PANE_ID" --source detection 2>/dev/null)
  [ $? -eq 0 ] || return 2
  has_review_card "$pane_content"
}

watch_blocking_prompt() {
  seen=0
  read_failures=0
  scans=0
  max_scans="${HERDR_PERMISSION_MAX_SCANS:-}"

  while :; do
    visible_result=0
    detection_result=1
    has_visible_blocking_prompt; visible_result=$?
    if [ "$visible_result" -eq 0 ]; then
      prompt_result=0
    else
      has_detection_review_card; detection_result=$?
      if [ "$detection_result" -eq 0 ]; then
        prompt_result=0
      else
        prompt_result=1
      fi
    fi

    if [ "$prompt_result" -eq 0 ]; then
      read_failures=0
      if [ "$seen" -eq 0 ]; then
        report blocked
        seen=1
      fi
    else
      if [ "$visible_result" -eq 2 ] && [ "$detection_result" -eq 2 ]; then
        read_failures=$((read_failures + 1))
        [ "$read_failures" -lt "${HERDR_PERMISSION_MAX_READ_FAILURES:-5}" ] || break
      else
        read_failures=0
        seen=0
      fi
    fi

    scans=$((scans + 1))
    [ -z "$max_scans" ] || [ "$scans" -lt "$max_scans" ] || break
    sleep "${HERDR_PERMISSION_POLL_INTERVAL:-1}"
  done
}

start_blocking_prompt_watcher() {
  watcher_dir="${TMPDIR:-/tmp}/herdr-puku-cli-blocking-prompt-watcher-${PANE_ID}"
  mkdir "$watcher_dir" 2>/dev/null || return 0
  (
    trap 'rmdir "$watcher_dir" 2>/dev/null' 0 HUP INT TERM
    watch_blocking_prompt
  ) &
}

# Internal test/worker modes must not consume a puku-cli JSON payload.
case "${1:-}" in
  --watch-shell-permission)
    watch_blocking_prompt
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
# input/decision (arrow-key choices, permission prompts). These are puku-cli's
# real tool names (v1.8.56) - notably Edit/Write/NotebookEdit/ExitPlanMode, not
# Command Code's edit_file/write_file.
is_blocking_tool() {
  case "$TOOL" in
    AskUserQuestion|ExitPlanMode|Edit|Write|NotebookEdit) return 0 ;;
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
    start_blocking_prompt_watcher
    ;;
  UserPromptSubmit)
    report working
    ;;
  PreToolUse)
    if is_blocking_tool; then
      report blocked
    else
      report working
    fi
    ;;
  PostToolUse|PostToolUseFailure)
    report working
    ;;
  PermissionDenied)
    report working
    ;;
  Stop|StopFailure|SessionEnd)
    report idle
    ;;
esac

exit 0

#!/bin/sh
# Capture stub standing in for the real `herdr` binary.
# Every invocation is appended as one JSON array line to $HERDR_CAPTURE
# (default /tmp/herdr-capture.jsonl), using node to guarantee valid JSON.
# Used by the test suite to assert what the hook / scripts would have told herdr.
export HERDR_CAPTURE="${HERDR_CAPTURE:-/tmp/herdr-capture.jsonl}"

# v1: the blocking-prompt watcher is disabled in puku-hooks/herdr-status.sh, so
# pane read is only called by hooks under test if the watcher is enabled.
# Stub it anyway in case future tests probe it.
if [ "$1" = "pane" ] && [ "$2" = "read" ]; then
  pane_source="recent"
  shift 2
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--source" ] && [ "$#" -gt 1 ]; then
      pane_source=$2
      break
    fi
    shift
  done

  case "$pane_source" in
    visible)
      pane_content="${HERDR_PANE_CONTENT_VISIBLE-${HERDR_PANE_CONTENT:-}}"
      ;;
    detection)
      pane_content="${HERDR_PANE_CONTENT_DETECTION-${HERDR_PANE_CONTENT:-}}"
      ;;
    recent-unwrapped)
      pane_content="${HERDR_PANE_CONTENT_RECENT_UNWRAPPED-${HERDR_PANE_CONTENT:-}}"
      ;;
    *)
      pane_content="${HERDR_PANE_CONTENT_RECENT-${HERDR_PANE_CONTENT:-}}"
      ;;
  esac

  printf '%s' "$pane_content"
  exit 0
fi

node -e '
const fs=require("fs");
const args=process.argv.slice(1);
fs.appendFileSync(process.env.HERDR_CAPTURE, JSON.stringify(args)+"\n");
process.exit(0);
' "$@" < /dev/null
exit 0

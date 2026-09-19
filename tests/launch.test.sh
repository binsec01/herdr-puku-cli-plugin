#!/bin/sh
# Tests for scripts/launch.sh (mode resolution + resume-named extraction).
# We don't exec puku-cli; instead we put a stub puku-cli on PATH that captures argv.
. "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCH="$ROOT/scripts/launch.sh"
STUB="$ROOT/tests/fixtures/herdr-stub.sh"
HERDR_CAPTURE="${HERDR_CAPTURE:-/tmp/herdr-capture.jsonl}"
export HERDR_CAPTURE
export HERDR_BIN_PATH="$STUB"
export HERDR_PANE_ID="pane-1"
unset HERDR_ENV   # launch.sh doesn't require herdr env; it just runs puku-cli

# Make `puku-cli` resolve to our stub so `exec puku-cli ...` is captured.
CMD_DIR="$ROOT/tests/fixtures/bin"
mkdir -p "$CMD_DIR"
cat > "$CMD_DIR/puku-cli" <<'EOF'
#!/bin/sh
# stub puku-cli: record argv
OUT="${HERDR_CAPTURE:-/tmp/herdr-capture.jsonl}"
printf '%s\n' "$(printf '%s\0' "$@" | sed 's/"/\\"/g; s/\x00/","/g; s/^/["/; s/$/"]/')" >> "$OUT"
EOF
chmod +x "$CMD_DIR/puku-cli"
export PATH="$CMD_DIR:$PATH"

echo "launch.sh"

# 1. task mode -> puku-cli invoked with no args (stub captures argv)
clear_capture
t_title "task mode -> puku-cli with no args"
sh "$LAUNCH" task
t_assert_eq "1" "$(capture_count)" "puku-cli invoked once"
t_assert_eq "" "$(capture_arg 1 0)" "no args passed to puku-cli"

# 2. resume-last -> -c
clear_capture
t_title "resume-last passes -c"
sh "$LAUNCH" resume-last
t_assert_eq "1" "$(capture_count)" "puku-cli invoked once"
t_assert_eq "-c" "$(capture_arg 1 0)" "first arg is -c"

# 3. resume-named with explicit arg
clear_capture
t_title "resume-named with arg -> --resume name"
sh "$LAUNCH" resume-named my-session
t_assert_eq "--resume" "$(capture_arg 1 0)" "has --resume"
t_assert_eq "my-session" "$(capture_arg 1 1)" "session name passed"

# 4. resume-named without arg but with context JSON
clear_capture
t_title "resume-named from context json"
export HERDR_PLUGIN_CONTEXT_JSON='{"session_name":"ctx-session"}'
sh "$LAUNCH" resume-named
t_assert_eq "ctx-session" "$(capture_arg 1 1)" "session name from context"
unset HERDR_PLUGIN_CONTEXT_JSON

# 5. resume-named with no name -> error exit
clear_capture
t_title "resume-named without name exits 1"
sh "$LAUNCH" resume-named >/dev/null 2>&1
t_assert_eq "1" "$?" "exit code 1"

summary

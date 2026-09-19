#!/bin/sh
# Tests for the puku-cli plugin payload (puku-plugin/.puku-plugin/plugin.json
# + puku-plugin/hooks/hooks.json). The actual install is `puku-cli plugin install`
# (out of scope for these tests); we assert the payload is structurally correct
# and the hook command resolves to a real script on disk.
. "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_JSON="$ROOT/puku-plugin/.puku-plugin/plugin.json"
HOOKS_JSON="$ROOT/puku-plugin/hooks/hooks.json"
HOOK_SCRIPT="$ROOT/puku-hooks/herdr-status.sh"

echo "puku-plugin payload"

# 1. plugin.json is valid JSON with required keys
t_title "plugin.json is valid JSON with required keys"
export PJ="$PLUGIN_JSON"
node -e '
  const fs=require("fs");
  const j=JSON.parse(fs.readFileSync(process.env.PJ,"utf8"));
  const missing=["name","version","hooks"].filter(k=>!(k in j));
  process.stdout.write(missing.length===0 ? "ok" : "missing:"+missing.join(","));
' > /tmp/pj.txt
t_assert_eq "ok" "$(cat /tmp/pj.txt)" "plugin.json has name, version, hooks"

# 2. hooks.json is valid JSON and lists all 4 lifecycle events
t_title "hooks.json lists all 4 lifecycle events"
export HJ="$HOOKS_JSON"
node -e '
  const fs=require("fs");
  const j=JSON.parse(fs.readFileSync(process.env.HJ,"utf8"));
  const have=Object.keys(j.hooks||{}).sort().join(",");
  const want=["PostToolUse","PreToolUse","SessionStart","Stop"].sort().join(",");
  process.stdout.write(have===want ? "ok" : "have:"+have+" want:"+want);
' > /tmp/hj.txt
t_assert_eq "ok" "$(cat /tmp/hj.txt)" "all four hook events present"

# 3. Each event has at least one entry with a matcher -> hooks list whose
#    command points at our herdr-status.sh (via sh + absolute path)
t_title "every event's hook command points at herdr-status.sh"
export HJ="$HOOKS_JSON"
export HS="$HOOK_SCRIPT"
node -e '
  const fs=require("fs");
  const j=JSON.parse(fs.readFileSync(process.env.HJ,"utf8"));
  const want=process.env.HS;
  let bad=[];
  for (const ev of Object.keys(j.hooks)) {
    const entries=j.hooks[ev];
    const ok = entries.some(e=>(e.hooks||[]).some(h=>h.type==="command" && h.command.endsWith(" "+want)));
    if (!ok) bad.push(ev);
  }
  process.stdout.write(bad.length===0 ? "ok" : "bad:"+bad.join(","));
' > /tmp/hj2.txt
t_assert_eq "ok" "$(cat /tmp/hj2.txt)" "all events point at herdr-status.sh"

# 4. The hook script actually exists and is executable
t_title "hook script exists and is executable"
t_assert_eq "yes" "$([ -x "$HOOK_SCRIPT" ] && echo yes || echo no)" "herdr-status.sh is executable on disk"

# 5. The hook script invokes `herdr pane report-agent` with --source puku-cli
#    and --agent puku-cli in the report() function. Spot-check the source.
t_title "hook reports with --source puku-cli and --agent puku-cli"
t_assert_eq "yes" "$(grep -q -- '--source puku-cli' "$HOOK_SCRIPT" && echo yes || echo no)" "--source puku-cli present"
t_assert_eq "yes" "$(grep -q -- '--agent puku-cli' "$HOOK_SCRIPT" && echo yes || echo no)" "--agent puku-cli present"

# 6. Uniqueness: each event has exactly one entry (so re-install is idempotent)
t_title "each event has exactly one entry"
export HJ="$HOOKS_JSON"
node -e '
  const fs=require("fs");
  const j=JSON.parse(fs.readFileSync(process.env.HJ,"utf8"));
  let bad=[];
  for (const ev of Object.keys(j.hooks)) {
    if ((j.hooks[ev]||[]).length!==1) bad.push(ev+":"+j.hooks[ev].length);
  }
  process.stdout.write(bad.length===0 ? "ok" : "bad:"+bad.join(","));
' > /tmp/hj3.txt
t_assert_eq "ok" "$(cat /tmp/hj3.txt)" "single entry per event"

summary

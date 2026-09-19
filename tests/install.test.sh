#!/bin/sh
# Tests for the puku-cli plugin payload (puku-plugin/.puku-plugin/plugin.json
# + puku-plugin/hooks/hooks.json). The actual install is `puku-cli plugin install`
# (out of scope for these tests); we assert the payload is structurally correct
# and that the hook command resolves via ${PUKU_CLI_PLUGIN_ROOT} rather than a
# hard-coded absolute path.
. "$(dirname "$0")/lib.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_JSON="$ROOT/puku-plugin/.puku-plugin/plugin.json"
HOOKS_JSON="$ROOT/puku-plugin/hooks/hooks.json"
HOOK_SCRIPT="$ROOT/puku-plugin/hooks/herdr-status.sh"

echo "puku-plugin payload"

# 1. plugin.json is valid JSON with required keys.
# puku-cli auto-loads ./hooks/hooks.json from the plugin install dir, so
# declaring manifest.hooks triggers a duplicate-load error. Required keys
# are therefore name + version (hooks must NOT be in the manifest).
t_title "plugin.json has required keys and does NOT declare hooks"
export PJ="$PLUGIN_JSON"
node -e '
  const fs=require("fs");
  const j=JSON.parse(fs.readFileSync(process.env.PJ,"utf8"));
  const missing=["name","version"].filter(k=>!(k in j));
  const hasHooks = "hooks" in j;
  if (missing.length) process.stdout.write("missing:"+missing.join(","));
  else if (hasHooks) process.stdout.write("forbidden:hooks");
  else process.stdout.write("ok");
' > /tmp/pj.txt
t_assert_eq "ok" "$(cat /tmp/pj.txt)" "plugin.json has name+version and omits hooks"

# 2. hooks.json is valid JSON and lists every lifecycle event we report on
t_title "hooks.json lists every lifecycle event"
export HJ="$HOOKS_JSON"
node -e '
  const fs=require("fs");
  const j=JSON.parse(fs.readFileSync(process.env.HJ,"utf8"));
  const have=Object.keys(j.hooks||{}).sort().join(",");
  const want=["PermissionDenied","PostToolUse","PostToolUseFailure","PreToolUse","SessionEnd","SessionStart","Stop","StopFailure","UserPromptSubmit"].sort().join(",");
  process.stdout.write(have===want ? "ok" : "have:"+have+" want:"+want);
' > /tmp/hj.txt
t_assert_eq "ok" "$(cat /tmp/hj.txt)" "all lifecycle events present"

# 3. Every event's hook command resolves via ${PUKU_CLI_PLUGIN_ROOT} and is
#    NOT an absolute path (regression guard for the old hard-coded path).
t_title "every hook command uses \${PUKU_CLI_PLUGIN_ROOT} (no absolute path)"
export HJ="$HOOKS_JSON"
node -e '
  const fs=require("fs");
  const j=JSON.parse(fs.readFileSync(process.env.HJ,"utf8"));
  let bad=[];
  for (const ev of Object.keys(j.hooks)) {
    const entries=j.hooks[ev];
    const ok = entries.some(e=>(e.hooks||[]).some(h=>
      h.type==="command" &&
      h.command.includes("${PUKU_CLI_PLUGIN_ROOT}/hooks/herdr-status.sh") &&
      !h.command.includes("/home/")
    ));
    if (!ok) bad.push(ev);
  }
  process.stdout.write(bad.length===0 ? "ok" : "bad:"+bad.join(","));
' > /tmp/hj2.txt
t_assert_eq "ok" "$(cat /tmp/hj2.txt)" "all events templated, none hard-coded"

# 4. The hook script actually exists (inside the plugin payload) and is executable
t_title "hook script exists, is in the payload, and is executable"
t_assert_eq "yes" "$([ -x "$HOOK_SCRIPT" ] && echo yes || echo no)" "herdr-status.sh is executable on disk"
t_assert_eq "yes" "$(case "$HOOK_SCRIPT" in "$ROOT/puku-plugin/"*) echo yes ;; *) echo no ;; esac)" "hook lives inside the plugin payload"

# 5. The hook script invokes `herdr pane report-agent` with --source puku-cli
#    and --agent puku-cli in the report() function. Spot-check the source.
t_title "hook reports with --source puku-cli and --agent puku-cli"
t_assert_eq "yes" "$(grep -q -- '--source puku-cli' "$HOOK_SCRIPT" && echo yes || echo no)" "--source puku-cli present"
t_assert_eq "yes" "$(grep -q -- '--agent puku-cli' "$HOOK_SCRIPT" && echo yes || echo no)" "--agent puku-cli present"

# 6. Windows paths: the template must not be Windows-escaped in the payload.
t_title "hook command keeps POSIX separators"
export HJ="$HOOKS_JSON"
node -e '
  const fs=require("fs");
  const j=JSON.parse(fs.readFileSync(process.env.HJ,"utf8"));
  const cmds=Object.values(j.hooks).flatMap(e=>e.flatMap(x=>(x.hooks||[]).map(h=>h.command)));
  process.stdout.write(cmds.every(c=>!c.includes("\\\\")) ? "ok" : "bad");
' > /tmp/hj3.txt
t_assert_eq "ok" "$(cat /tmp/hj3.txt)" "no backslash-escaped separators"

# 7. Uniqueness: each event has exactly one entry (so re-install is idempotent)
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
' > /tmp/hj4.txt
t_assert_eq "ok" "$(cat /tmp/hj4.txt)" "single entry per event"

summary

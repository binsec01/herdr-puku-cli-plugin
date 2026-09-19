# puku-cli → Herdr Integration

Makes [puku-cli](https://puku.sh) a first-class agent inside
[Herdr](https://herdr.dev), the terminal multiplexer for coding agents.

Mirrors the structure of [`herdr-commandcode-plugin`](../herdr-commandcode-plugin)
with two deliberate deviations:

1. **Shipped as a real puku-cli plugin** under `puku-plugin/`, installable via
   `puku-cli plugin install <path>`. Uses puku-cli's built-in plugin loader
   instead of editing `settings.json` directly. Hook commands resolve through
   `${PUKU_CLI_PLUGIN_ROOT}`, so the integration keeps working after the repo is
   moved or the plugin is installed into the puku-cli plugin cache.
2. **No fingerprint step.** puku-cli has no `trusted-hooks.json` mechanism — its
   hook trust gate is interactive workspace trust, accepted on first run.

## Capabilities

- **Lifecycle state** — `idle` on start (green checkmark), `working` during
  processing, `blocked` when a blocking tool runs or a blocking prompt is
  onscreen, `idle` when the turn finishes. Status is reported from inside the
  live puku-cli process — puku-cli does **not** need to exit for state to update.
- **Blocking-prompt detection** — a watcher reads the live visible pane and
  reports `blocked` for shell-command permission, file-edit confirmation,
  plan-mode entry, and the plan review card (see below).
- **Session restore** — reports the puku-cli `session_id` (a UUIDv4) so Herdr
  can resume the agent after a server restart.
- **Sidebar detection** — seeds an agent-detection override so Herdr
  recognizes the `puku-cli` process.
- **Launch panes** — new task, resume last session (`-c`), or resume a
  named session (`--resume <uuid>`).
- **Notifications** — a `notify` action sends a Herdr toast.

## Requirements

- Herdr >= 0.7.0
- puku-cli on your `PATH`

## Install

```bash
# Link the herdr plugin (creates panes + actions).
herdr plugin link /home/rahat/development/herdr-puku-cli-plugin

# Register the puku-cli marketplace (one-time). puku-cli only installs
# plugins via a named marketplace, so we publish one in this repo
# (.puku-plugin/marketplace.json) that points at puku-plugin/.
puku-cli plugin marketplace add binsec01/herdr-puku-cli-plugin

# Install the puku-cli plugin (registers the lifecycle hooks).
puku-cli plugin install herdr-integration@herdr-puku-cli-local

# Seed the herdr agent-detection override.
herdr plugin action invoke setup --plugin puku-cli.integration
```

Uninstall:

```bash
puku-cli plugin uninstall herdr-integration@herdr-puku-cli-local
herdr plugin unlink /home/rahat/development/herdr-puku-cli-plugin
```

## Use

```bash
herdr plugin pane open --plugin puku-cli.integration --entrypoint task
herdr plugin pane open --plugin puku-cli.integration --entrypoint resume-last
herdr plugin pane open --plugin puku-cli.integration --entrypoint resume-named
```

Send a notification:

```bash
herdr plugin action invoke notify --plugin puku-cli.integration -- "Build done" "api workspace"
```

Keybinding:

```toml
[[keys.command]]
key = "prefix+p"
type = "plugin_pane"
command = "puku-cli.integration.task"
description = "puku-cli: new task"
```

### Notifications (blocked → toast + sound)

Enable toasts + sound in `~/.config/herdr/config.toml`:

```toml
[ui.toast]
delivery = "herdr"
delay_seconds = 1

[ui.toast.herdr]
position = "bottom-right"

[ui.sound]
enabled = true
```

## How status reporting works

Status is reported from **inside the live `puku-cli` process** via puku-cli
hooks — never from the launcher.

| Hook event | State | When |
|---|---|---|
| `SessionStart` | `idle` | Agent launches (green checkmark); also claims the agent label, reports the session id, and starts the blocking-prompt watcher |
| `UserPromptSubmit` | `working` | A turn begins |
| `PreToolUse` (blocking tool) | `blocked` | `AskUserQuestion`, `ExitPlanMode`, `Edit`, `Write`, `NotebookEdit` |
| `PreToolUse` (other) | `working` | Any other tool |
| `PostToolUse` / `PostToolUseFailure` | `working` | A tool finished |
| `PermissionDenied` | `working` | A permission prompt was answered |
| Visible pane prompt | `blocked` | Shell-command permission, file-edit confirmation, plan-mode entry, plan review |
| `Stop` / `StopFailure` | `idle` | Turn finished (or failed) |
| `SessionEnd` | `idle` | Session ended / process exited |

The watcher matches these **live visible-pane** signals (literal puku-cli renders):

```text
Do you want to proceed?          # + "Esc to cancel" in the same snapshot
Esc to cancel

Do you want to make this edit to # edit confirmation

Enter plan mode?                 # plan-mode entry card

Would you like to proceed?       # + an approval option, plan review card
Yes, manually approve edits
```

Two of these are deliberately two-part: the permission question alone can appear
in ordinary assistant prose, and the review "ready" sentence alone is not a card.
Both must appear together with their footer/option in **one live snapshot**.

The watcher reads the visible pane first, then Herdr's live plain-text detection
snapshot as a fallback for a review card that sits outside the viewport. It never
uses scrollback, so an approved prompt cannot leave the pane incorrectly blocked.
It reports `blocked` once per prompt and resets after the prompt clears.

### Herdr state vocabulary

- `blocked` = agent needs input/approval/decision
- `working` = actively running
- `done`    = finished, unseen by user
- `idle`    = finished/waiting, seen
- `unknown` = cannot classify

The hook sends `idle` on `Stop`/`SessionEnd`, so it never produces the
checkmark `done` state — the same behaviour as the OpenCode and Command Code
integrations (`done` is only reachable via Herdr's internal `AgentStatus` field,
not `report-agent`).

## Driving puku-cli from another agent (e.g. Command Code)

puku-cli is **not** one of Herdr's *supported interactive agent kinds*
(`herdr agent start --kind <KIND>` accepts only pi, omp, claude, codex, copilot,
devin, droid, kimi, opencode, kilo, hermes, qodercli, qwen, letta, cursor,
mastracode, grok). Two consequences:

- `herdr agent start --kind puku-cli` is rejected (`unsupported interactive agent kind`).
- Because only `agent start` can create a *named* agent, `herdr agent prompt <pane>`
  fails with `agent_not_ready: … is not an active named agent`.

opencode is a supported kind, which is why it can be driven natively with
`agent start` + `agent prompt`. **This is a Herdr-side limitation, not a plugin
bug** — fixing it needs a change in herdr (`src/app/ids.rs` + an integration
manifest).

Until then, drive a puku-cli pane through the pane API:

```bash
# 1. Open the pane (this also seeds agent detection + hooks).
herdr plugin pane open --plugin puku-cli.integration --entrypoint task

# 2. Type the prompt and submit it.
herdr pane send-text <PANE_ID> "explain the TOCTOU vulnerability"
herdr pane send-keys <PANE_ID> enter

# 3. Read the result back (visible/detection are live; recent-unwrapped is scrollback).
herdr pane read <PANE_ID> --source recent-unwrapped --lines 200
```

`herdr pane run <PANE_ID> "<text>"` is equivalent to steps 2's text + Enter.

## Files

| File | Role |
|---|---|
| `herdr-plugin.toml` | Herdr manifest: 3 panes + setup + notify action |
| `.puku-plugin/marketplace.json` | puku-cli marketplace manifest (declares `herdr-integration`) |
| `puku-plugin/.puku-plugin/plugin.json` | puku-cli plugin metadata (no `hooks` key — puku-cli auto-loads `hooks/hooks.json`) |
| `puku-plugin/hooks/hooks.json` | Hook matchers (SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / PostToolUseFailure / PermissionDenied / Stop / StopFailure / SessionEnd) → `herdr-status.sh`, via `${PUKU_CLI_PLUGIN_ROOT}` |
| `puku-plugin/hooks/herdr-status.sh` | Lifecycle hook + blocking-prompt watcher reporting to Herdr |
| `scripts/launch.sh` | Pane entrypoint; runs `puku-cli` |
| `scripts/common.sh` | Shared helpers (agent-detection seeding) |
| `scripts/setup.sh` | Action: seeds herdr agent-detection override |
| `scripts/notify.sh` | Action: herdr toast |
| `config/agent-detection/puku-cli.toml` | Herdr agent-detection override for `puku-cli` |
| `tests/` | POSIX `sh` test suite (no bats) |

The hook lives inside the plugin payload (`puku-plugin/hooks/herdr-status.sh`) on
purpose: puku-cli substitutes `${PUKU_CLI_PLUGIN_ROOT}` with the installed plugin
directory, so the hook resolves from the plugin cache without a hard-coded path.

## Notes

- Launching uses plugin **panes** (real PTYs); actions run detached without
  a TTY and `puku-cli` requires one.
- Windows is supported via Git Bash (scripts are POSIX `sh`).
- Verify the agent-detection schema with `herdr api schema --json`; adjust
  `config/agent-detection/puku-cli.toml` if field names differ on your version.
- **Workspace trust:** puku-cli silently skips hooks (including the watcher) until
  workspace trust is accepted, so a first run in a new directory may report
  nothing. Hooks are skipped, not failed.

## TODO / follow-ups

- [ ] Confirm the `BLOCKING_SIGNAL_*` literals against live screens on the puku-cli
      version in use (they were derived from the bundled CLI, not a live pane);
      capture them with `herdr pane read <pane> --source visible`.
- [ ] `PermissionRequest` is deliberately **not** wired: puku-cli treats a hook
      exit code of `0` as *allow*, so registering it risks auto-approving
      permission prompts. Shell permissions are covered by the visible-pane
      watcher instead (same approach as the Command Code integration).
- [ ] Verify the watcher survives after the hook process returns on your puku-cli
      version (it is detached as a background subshell; if puku-cli reaps the
      process group, the watcher would need an external supervisor).
- [ ] Decide whether to surface `--session-id <uuid>` (pin a fresh session id)
      as a fourth launch mode, and `-n <name>` as a pane option.
- [ ] Force-quit behaviour: puku-cli fires `SessionEnd`, which now reports `idle`;
      verify Herdr transitions cleanly when the process is `SIGKILL`ed.

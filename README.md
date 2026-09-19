# puku-cli → Herdr Integration

Makes [puku-cli](https://puku.sh) a first-class agent inside
[Herdr](https://herdr.dev), the terminal multiplexer for coding agents.

Mirrors the structure of [`herdr-commandcode-plugin`](../herdr-commandcode-plugin)
with three deliberate deviations:

1. **Shipped as a real puku-cli plugin** under `puku-plugin/`, installable via
   `puku-cli plugin install <path>`. Uses puku-cli's built-in plugin loader
   instead of editing `settings.json` directly.
2. **No fingerprint step.** puku-cli doesn't have a `trusted-hooks.json`
   mechanism — its hook trust gate is interactive workspace trust, which the
   user accepts on first interactive run.
3. **No blocking-prompt watcher (v1).** We don't yet know the literal text
   puku-cli renders for shell-permission / plan-mode / act-mode / review
   prompts. v1 reports `blocked` from hook events only (PreToolUse on
   interactive tools). Watcher scaffolding is present in
   `puku-hooks/herdr-status.sh` so v2 is a small change.

## Capabilities

- **Lifecycle state** — `idle` on start (green checkmark), `working` during
  processing, `blocked` when a known interactive tool is about to run,
  `idle` when the turn finishes. Status is reported from inside the live
  puku-cli process — puku-cli does **not** need to exit for state to update.
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

# Install the puku-cli plugin (registers the lifecycle hook).
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

Same as the Command Code integration — enable toasts + sound in
`~/.config/herdr/config.toml`:

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

This plugin mirrors Herdr's Command Code / OpenCode integrations: status is
reported from **inside the live `puku-cli` process** via puku-cli hooks, not
from the launcher.

| Hook event | State | When |
|---|---|---|
| `SessionStart` | `idle` | Agent launches (green checkmark) |
| `PreToolUse` (blocking tool) | `blocked` | `AskUserQuestion`, `Question`, `edit_file`, `write_file` (TODO: refine vs actual puku-cli tool names) |
| `PreToolUse` (other) | `working` | Any other tool |
| `PostToolUse` | `working` | After any tool completes |
| `Stop` | `idle` | Turn finished |
| Visible pane prompt | `blocked` | **(v2)** Shell-command permission, plan mode, act mode, review prompts |

In v1 `SessionStart -> idle` matches OpenCode's behavior (green checkmark on
start). The state vocabulary, per the OpenCode / Command Code taste files:

- `blocked` = agent needs input/approval/decision
- `working` = actively running
- `done`    = finished, unseen by user
- `idle`    = finished/waiting, seen
- `unknown` = cannot classify

The hook sends `idle` on Stop, so it never produces the checkmark `done`
state (the OpenCode integration behaves the same way).

After the user answers a question or approves a prompt, normal `PostToolUse`
or `Stop` events report the next `working` or `idle` state.

## v2 / TODO

- [ ] Observe puku-cli's literal rendered text for: shell-command permission,
      plan-mode entry, act-mode entry, plan review approval. Wire those into
      the visible-pane watcher (flip
      `BLOCKING_PROMPT_WATCHER_ENABLED=1` in
      `puku-hooks/herdr-status.sh`).
- [ ] Refine `is_blocking_tool` against actual puku-cli tool names
      (likely diverges: `notify_user` / `request_user_input` / etc.).
- [ ] Verify that puku-cli's plugin loader supports a `${plugin_dir}` template
      in `hooks/hooks.json` so we can drop the absolute-path coupling.
- [ ] Decide whether to surface `--session-id <uuid>` (pin a fresh session id)
      as a fourth launch mode.
- [ ] Force-quit behavior: puku-cli (like Command Code) has no `Exit` hook;
      verify Herdr transitions the pane to `idle`/`unknown` cleanly when the
      puku-cli process is killed.

## Files

| File | Role |
|---|---|
| `herdr-plugin.toml` | Herdr manifest: 3 panes + setup + notify action |
| `.puku-plugin/marketplace.json` | puku-cli marketplace manifest (declares `herdr-integration`) |
| `puku-plugin/.puku-plugin/plugin.json` | puku-cli plugin metadata (no `hooks` key — puku-cli auto-loads `hooks/hooks.json`) |
| `puku-plugin/hooks/hooks.json` | Hook matchers (SessionStart / PreToolUse / PostToolUse / Stop) → herdr-status.sh |
| `puku-hooks/herdr-status.sh` | Lifecycle hook reporting to Herdr socket |
| `scripts/launch.sh` | Pane entrypoint; runs `puku-cli` |
| `scripts/common.sh` | Shared helpers (agent-detection seeding) |
| `scripts/setup.sh` | Action: seeds herdr agent-detection override |
| `scripts/notify.sh` | Action: herdr toast |
| `config/agent-detection/puku-cli.toml` | Herdr agent-detection override for `puku-cli` |
| `tests/` | POSIX `sh` test suite (no bats) |

## Notes

- Launching uses plugin **panes** (real PTYs); actions run detached without
  a TTY and `puku-cli` requires one.
- Windows is supported via Git Bash (scripts are POSIX `sh`).
- Verify the agent-detection schema with `herdr api schema --json`; adjust
  `config/agent-detection/puku-cli.toml` if field names differ on your version.
- **Moving this directory breaks the hook.** `hooks/hooks.json` hard-codes the
  absolute path to `puku-hooks/herdr-status.sh`. If you move the repo,
  re-run `puku-cli plugin install` to refresh the registered path. v2 will
  template this once puku-cli's loader syntax is verified.

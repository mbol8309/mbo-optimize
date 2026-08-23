# mbo.optimize

An [Omarchy](https://omarchy.org/) shell plugin that asks your configured AI
coding agent to review disk usage and installed packages, then shows the
recommendations in a bar panel where you can pick which to act on.

> Work in progress — scaffold with the data pipeline, panel, systemd timer,
> and deploy script in place. The QML panel is a skeleton that the shell will
> load; first end-to-end test against the default agent is the next milestone.

## What it does

1. `omarchy-optimize-collect` builds a JSON snapshot: disk usage per
   filesystem, big directories under `$HOME`, large files in `~/Downloads`,
   installed packages with size and install date, journal size, old kernels,
   and docker images.
2. `omarchy-optimize-analyze` sends that snapshot to your default agent via
   `omarchy agent prompt --inline`, parses the JSON recommendations it returns,
   and writes `recommendations.json` + `state.json`.
3. The **bar widget** shows up only when there are pending recommendations.
   Hover for a status line (optimized / N pending / last scan date). Click to
   open the panel.
4. The **panel** lists each recommendation with a checkbox, severity, estimated
   savings, and the exact command the agent proposes. "Execute selected" runs
   the actions; cloud/uninstall/delete actions open a floating terminal so you
   can type the sudo password.
5. A **systemd --user timer** re-runs the scan weekly and fires a desktop
   notification when new recommendations land.

## Repo layout

The repo root **is** the plugin folder — that is the Omarchy convention, so
`omarchy plugin add https://github.com/mbol8309/mbo-optimize.git` works out of
the box. Everything else lives alongside:

```
mbo-optimize/
├── manifest.json          # plugin manifest (root = plugin, per Omarchy convention)
├── Panel.qml              # bar-widget entry point (popup with recommendations)
├── bin/
│   ├── omarchy-optimize-collect    # df/du/pacman/journal → snapshot.json
│   ├── omarchy-optimize-analyze    # omarchy agent prompt --inline → recommendations
│   ├── omarchy-optimize-apply      # runs the selected actions
│   └── omarchy-optimize-state      # read/write state.json, dismiss, reset
├── prompts/
│   └── analyze.md         # prompt template fed to the agent (__SNAPSHOT__ replaced)
├── systemd/
│   ├── mbo-optimize-scan.service   # --user oneshot that runs analyze + notify
│   └── mbo-optimize-scan.timer    # weekly trigger (Mon 09:00, Persistent=true)
├── deploy/
│   ├── deploy.sh          # one-command install (copies plugin, links bins, timer, menu)
│   └── uninstall.sh      # clean removal
└── assets/                # icons (optional)
```

State lives in `~/.local/state/omarchy/optimize/` (`snapshot.json`,
`recommendations.json`, `state.json`).

## Install

```bash
git clone https://github.com/mbol8309/mbo-optimize.git
cd mbo-optimize
./deploy/deploy.sh
```

`deploy.sh`:

1. copies the plugin into `~/.config/omarchy/plugins/mbo.optimize/`,
2. symlinks `bin/*` into `~/.local/bin/` (on PATH in Omarchy),
3. installs and enables the systemd --user timer,
4. adds an idempotent "Optimize system" entry to the Omarchy menu,
5. rescans the shell and enables the widget.

To install without the timer or menu: `./deploy/deploy.sh --no-timer --no-menu`.
After a `git pull`, re-run `./deploy/deploy.sh --update` to refresh the copies.

> `omarchy plugin add <git-url>` also works on its own, but it does not put the
> bin scripts on PATH or install the timer — `deploy.sh` exists to cover those.

## Settings

Tunable via the widget's entry in `~/.config/omarchy/shell.json`, set with
`omarchy bar set mbo.optimize <key> <value> [--json]`:

| Key | Default | What it does |
|---|---|---|
| `scanIntervalDays` | `7` | How often the timer fires |
| `minSeverity` | `"low"` | Lowest severity shown in the panel |
| `cloudProvider` | `"none"` | Handler for `action:cloud` (rclone / local-send / tailscale) |
| `autoNotify` | `"On"` | Notify when new recommendations land |
| `agent` | `"default"` | Informational; the agent used is `omarchy default agent` |

## Uninstall

```bash
./deploy/uninstall.sh          # keeps state
./deploy/uninstall.sh --purge-state  # also removes ~/.local/state/omarchy/optimize/
```

## Manual use (without the UI)

```bash
omarchy-optimize-analyze                  # scan + analyze now
omarchy-optimize-state read               # current status
omarchy-optimize-state recommendations    # the recommendation list
omarchy-optimize-apply apply '["downloads-iso"]'   # apply by id
omarchy-shell mbo.optimize.open           # open the panel
```

## Safety

- The agent is told never to recommend deleting outside `$HOME` and never to
  uninstall essential packages (kernel, mesa, hyprland, omarchy, firmware…).
- The apply script refuses `delete`/`rm -rf /` or `$HOME` root.
- Any command needing privileges opens in a floating terminal so you type the
  password and see the output — no blind privileged execution.

## License

MIT

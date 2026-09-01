# Omachord

Omachord is an accessibility-oriented shortcut and routine composer for Omarchy. It shows the effective Hyprland shortcut catalogue and lets you compose app-owned routines from ordered actions, one optional keyboard shortcut, Omarchy event hooks, and conditions such as a time period or a Wi-Fi network. Routines can change Omarchy state (night light, do not disturb, stay awake, theme, brightness) and put it back when they end; a routine that does is a *mode* that can be on or off.

The panel, the condition service, and a small bar widget run inside the existing `omarchy-shell` process. A separate Bash/`jq` runner owns validation, persistence, integration, and execution so shortcuts, hooks, and restores keep working when the panel is closed.

The microphone routine is inspired by [Easy-Mic-Mute-Hyprland](https://github.com/anothaDev/Easy-Mic-Mute-Hyprland), expanded here to preserve Omarchy's native mute behavior and compose with other actions.

## Requirements

- Omarchy 4.0.2
- Hyprland 0.56.2
- Quickshell 0.3.1
- Bash, Perl, GNU coreutils, `jq`, `flock`, `fuser`, `timeout`, `wpctl`, and `paplay`

These are present in a standard Omarchy installation.

## Install

After publishing the repository, install and enable the plugin from Git:

```bash
omarchy plugin add https://github.com/anothaDev/omachord.git --enable
```

Open the panel:

```bash
omarchy-shell shell summon anothadev.omachord '{}'
```

Omachord enables its Hyprland integration on first use, so the panel opens with the **Omachord** switch on and saved routines are live immediately. Turn that switch off to pause shortcuts, hooks, and conditions while keeping every routine; that choice persists across shell restarts until you turn it on again.

Upgrading from 0.2.0: restart the shell once (`omarchy restart shell`) so the shell reads the manifest's new bar-widget kind and the new QML files. The service then places the bar widget once; see [Bar widget](#bar-widget).

## Development

For a local checkout, link the repository into the third-party plugin directory, validate it, and enable it:

```bash
ln -s "$PWD" ~/.config/omarchy/plugins/anothadev.omachord
omarchy plugin validate .
omarchy plugin enable anothadev.omachord
omarchy-shell shell summon anothadev.omachord '{}'
```

Edits under `~/.config/omarchy/plugins/` are normally hot-reloaded. Restart Omarchy Shell after adding a new QML component or changing the manifest. Enabling the plugin loads its panel, its condition service, and its bar widget; the service logs as `omachord` in the shell log.

To review the panel without opening it on your desktop, `test/render/render.sh` renders every view offscreen to PNG files (see [Test](#test)).

## Integration

On first use, Omachord automatically performs its system-integration transaction:

- Refuses a fresh connection if Hyprland already reports configuration errors; an owned broken integration can still be repaired transactionally.
- Backs up `~/.config/hypr/bindings.lua`.
- Adds one marked optional-loader line to `bindings.lua`.
- Generates app-owned shortcut Lua and six guarded hook dispatchers.
- Installs the Omachord desktop entry.
- Reloads Hyprland, verifies the generated configuration, and rolls back on failure.

Turning the **Omachord** switch off removes generated integration and persists that preference. Saving while it is off only updates the routine document and never reactivates integration. Turning it on performs the same guarded transaction again, including the required Hyprland reload. The same switch sits in the bar popup.

## Panel

The window has three views, chosen from the sidebar or with a payload (`omarchy-shell shell summon anothadev.omachord '{"view":"activity"}'`):

- **Routines**: the list with an on/off switch per routine (saved immediately), a live dot while a mode is on, and the editor. The editor reads top to bottom: name and enabled flag, **Starts when** (shortcut, Omarchy events), **If** (conditions, all of which must hold), **Then** (actions in order), and **When it ends**. A mode shows a switch in its header to turn it on or off right now; the footer keeps **Save** (Ctrl+S), **Run now** / **Turn on** / **Turn off** (or **Save & run** while the draft is unsaved), **Duplicate**, and **Delete** in view at all times. Validation marks the failing card and scrolls to it.
- **Shortcuts**: every shortcut Hyprland currently has, searchable, filtered by **All** / **Omachord** / **Hyprland**. Pick a Hyprland shortcut to start a routine that overrides it.
- **Activity**: what is on now (with **End**), each condition routine and why it is waiting (for example `Waiting for Wi-Fi Home (connected to Cafe)`), the routines attached to Omarchy events, the condition service's inputs, and the recent run history.

The window follows the Omarchy theme live: colors crossfade when `omarchy theme set` runs, and the on-state green comes from the theme's own palette (`green` in `colors.toml`, with a fallback for themes that ship none). The current theme name is shown at the bottom of the sidebar. Keyboard: Tab moves between controls, j/k walk a focused list, Enter opens the highlighted routine, Esc leaves a text field first and then closes the window, Ctrl+S saves, Ctrl+R refreshes. The panel mirrors the in-process service, so a routine started by its shortcut, an event, a condition, or ended from the bar updates the window without pressing Refresh.

## Bar widget

A 󰘮 icon appears in the bar's center section while a routine is on. Left or right click opens a popup listing what is on, when it started, when it ends, and what it restores, with an end button per routine and a switch for Omachord itself; j/k, Enter, x, and Esc work as in other Omarchy panels, and `o` opens the window. Middle click opens the window directly. Two settings live on the bar entry in `shell.json`:

```bash
omarchy bar set anothadev.omachord alwaysShow true --json   # keep the icon while nothing is on
omarchy bar set anothadev.omachord showName true --json     # show the routine's name next to the icon
```

The widget is placed once per install by `omachord widget ensure`, which the service runs after the shell finishes scanning plugins. A fresh `omarchy plugin add --enable` already puts the widget on the bar, because the shell records a plugin with a `bar-widget` kind in `bar.layout`. Installs enabled before the widget existed carry the id in `plugins[]` instead, and the shell's `putBarWidget` verb answers `ok` for such an entry without adding the widget; the runner therefore reads `shell.json` itself and moves the entry in one atomic edit (into the center section right after `omarchy.indicators`), keeping the previous file under `~/.local/state/omarchy/omachord/backups/`. `omachord widget status` reports the placement record and whether the id is on the bar; `omachord widget forget` lets the next `ensure` place it again. The manual equivalent is `omarchy bar put anothadev.omachord --after omarchy.indicators`.

Because the bar entry is what enables the plugin, `omarchy plugin disable anothadev.omachord` (or taking the widget off the bar) also stops the panel and the condition service. To hide the icon instead, leave `alwaysShow` off: the widget takes no space while nothing is on.

## Routines

A routine can be run manually, by one optional keyboard shortcut, or by any combination of these Omarchy events:

- `battery-low`
- `font-set`
- `post-boot`
- `post-update`
- `pre-refresh-pacman`
- `theme-set`

Actions execute in order and stop at the first failure. Supported actions are microphone toggle, application launch, Omarchy command, notification, OSD, sound, delay, direct program execution, and an advanced shell command.

### Setters and restore

Five actions set Omarchy state instead of running a program: **night light**, **do not disturb**, **stay awake**, **theme**, and **display brightness**. They go through the Omarchy shell (`omarchy-shell nightlight|idle|notifications`), `omarchy-theme-set`, and `omarchy-brightness-display`, so the bar indicators follow and Omarchy's own hooks still fire. There is no light/dark mode in Omarchy; the theme setter with restore is the equivalent.

Each setter has a **Return to previous state when routine ends** switch. A routine with at least one restoring setter is *stateful*:

- Activating it records every restoring setter's value before changing it. The record lives in `~/.local/state/omarchy/omachord/active/<routine-id>.json` and is rewritten after each setter, so an interrupted activation still leaves a restorable record.
- Its shortcut and manual runs **toggle** it: the first run activates, the next one ends it. Omarchy events only ever activate a stateful routine.
- Ending it restores the recorded values in reverse order, but only where the live value still equals what the routine applied. A value you changed yourself in the meantime is left alone.
- Saving a configuration that deletes or disables an active routine ends it first, and so does turning Omachord off.
- A setter read that returns something unexpected refuses the activation before anything is changed. A failure part-way through rolls back the setters that were already applied.
- A restore that cannot complete (for example while the shell is not running) keeps the activation record and reports the routine as still active, so a later deactivation finishes the job. Records are only discarded once everything they recorded has been dealt with.
- While a routine is active, another routine cannot claim the same restoring setter type. The second activation reports a conflict; non-restoring setters remain unrestricted.

### When a routine ends

- **Return to the state before the routine ran** (default): revert the restoring setters.
- **Restore, then run end actions**: revert, then run a separate action list. Setters in that list apply without recording anything.

End actions are checkpointed as at-most-once before execution. If one fails, a later deactivation continues with the next action rather than repeating an external effect whose completion may be ambiguous.
- **Leave everything as it is**: nothing is reverted.

### Keep until

A stateful routine ends when its conditions stop matching or when you toggle it off. Choosing **a fixed number of minutes** (1 to 1440) instead records an expiry time in the activation record.

### Conditions

A routine can carry **time period**, **Wi-Fi network**, **power source**, and **Omarchy toggle** conditions. All of them must hold; while they do, the routine is active, and when one stops holding, a routine the service started ends and restores. A routine with conditions but nothing to restore simply runs once each time its conditions become true.

- **Time period**: `HH:MM` start and end, optional weekdays. An end before the start crosses midnight and belongs to the weekday it started on.
- **Wi-Fi network**: connected to one of the listed network names, matched exactly.
- **Power source**: plugged in, on battery, or on battery below a percentage.
- **Omarchy toggle**: a flag under `~/.local/state/omarchy/toggles/` exists, the same flags `omarchy toggle <flag>` manages.

Conditions are evaluated by the plugin's **service** entry point inside `omarchy-shell`. It reads Wi-Fi and power state from the shell's own NetworkManager and UPower bindings, watches the toggle directory, and wakes at the next time boundary (never less often than once a minute, which also covers suspend and resume). It only decides *when*; every start and end is an `omachord activate` or `omachord deactivate` call, so the runner remains the single executor.

The service stays idle while Omachord is off, ignores uncommitted configuration, and never ends a routine that a person or an event started. A routine ended by its timer or by hand does not restart until its conditions have been false at least once. Inspect it with:

```bash
omarchy-shell omachord status
```

The status names every active routine and, for each condition routine, one `details` entry per condition (its summary, whether it holds, and the input the service sees) plus the last failed start or end and when it will be retried. The same service accepts `omarchy-shell omachord end <routine-id>` and `start <routine-id>`, which is what the bar widget uses.

### Runner commands

| Command | Purpose |
| --- | --- |
| `omachord run <id> [manual\|shortcut\|test]` | Run a routine; toggles a stateful routine |
| `omachord activate <id> [manual\|shortcut\|test]` | Activate without toggling; already-active routines report `alreadyActive` |
| `omachord deactivate <id> [manual\|shortcut\|test]` | End a routine from its activation record |
| `omachord active` | List activation records |
| `omachord logs [limit]` | Run history; stateful routines log `activated` and `deactivated` entries |
| `omachord widget ensure\|status\|forget` | Place the bar widget once through the Omarchy shell, inspect or clear that record |

The microphone template calls `omarchy audio input mute` first, preserving Omarchy's OSD and hardware LED behavior. It then reads the resulting microphone state and plays the configured mute or live sound.

## Hook Context

Child programs launched by a hook-triggered routine receive:

```text
OMACHORD_TRIGGER=hook
OMACHORD_HOOK=<event>
OMACHORD_ARG_1=<first hook argument>
OMACHORD_ARG_2=<second hook argument>
...
```

Hook values are exported as data and are not evaluated by the runner. Every child also receives `OMACHORD_PHASE` as `run`, `activate`, or `deactivate`, and `OMACHORD_TRIGGER` carries `condition`, `service`, or `timer` when the activation did not come from a person.

## Security

Routines are trusted local configuration and are not sandboxed.

- `exec` launches the selected program with a literal JSON argument array and no shell parsing.
- `shell` intentionally runs `bash -lc` and can execute arbitrary commands as your user.
- `exec` and `shell` can invoke `sudo`; cached credentials may allow a routine to elevate without another password prompt.
- Omarchy command choices exclude commands marked hidden or `requires_sudo`, but command metadata is not a security boundary; a selected command can still open a privilege prompt internally.
- Child output is bounded, and foreground program-execution stages have a 30-second default timeout. Explicit delays are capped at five minutes.
- The only file the runner edits outside Hyprland's and its own is `~/.config/omarchy/shell.json`, once, to move this plugin's entry onto the bar on an install upgraded from 0.2.0; the previous file is kept under `~/.local/state/omarchy/omachord/backups/`.
- Setter writes are argv-literal calls to Omarchy tools. Activation records are validated before use; a record that fails validation stops `run`, `activate`, `deactivate`, and `active` with `unsafe-state` instead of being treated as inactive.
- A theme setter makes Omarchy fire its `theme-set` hook, which re-enters the runner. The per-routine lock reports the originating routine as busy, so a routine cannot recurse into itself.
- Saves use revision-based compare-and-swap, so a stale panel cannot overwrite a newer configuration.
- Condition-service jobs carry the revision they evaluated; the runner rejects stale jobs and post-Disconnect activations before any routine action runs.
- Readers require the canonical configuration to match a post-reload commit record. A candidate cannot execute before its integration transaction commits, and an interrupted candidate fails closed.
- Integration writes use atomic compare-and-swap operations. Concurrent versions and verified inodes still held open by another process are preserved under the private state directory instead of being overwritten.

Review routine JSON added outside the panel before running it, especially `exec` and `shell` actions.
If an interrupted transaction leaves an uncommitted configuration, the panel refuses to load or run it. Inspect the canonical JSON before explicitly repairing or replacing it.

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Files

| Path | Purpose |
| --- | --- |
| `~/.config/omarchy/omachord.json` | Canonical routine configuration |
| `~/.config/hypr/omachord.lua` | Generated enabled shortcuts |
| `~/.config/hypr/bindings.lua` | Receives one marked optional-loader line |
| `~/.config/omarchy/hooks/<event>.d/anothadev.omachord` | Guarded event dispatchers |
| `~/.local/share/applications/anothadev.omachord.desktop` | Application launcher |
| `~/.local/state/omarchy/omachord/runs.jsonl` | Rolling execution history |
| `~/.local/state/omarchy/omachord/active/<routine-id>.json` | Activation record of a stateful routine, holding the values to restore |
| `~/.local/state/omarchy/toggles/<flag>` | Omarchy toggle flags read by the toggle condition |
| `~/.local/state/omarchy/omachord/connection.json` | Integration ownership record |
| `~/.local/state/omarchy/omachord/bar-widget.json` | Record that the bar widget was placed once |
| `~/.local/state/omarchy/omachord/backups/shell.json.<suffix>` | `shell.json` as it was before the widget entry was moved |
| `~/.local/state/omarchy/omachord/config.commit.json` | Last committed configuration revision |
| `~/.local/state/omarchy/omachord/conflicts/` | Concurrent file versions preserved during a rare transaction conflict |
| `~/.local/state/omarchy/omachord/retired/` | Replaced inodes retained only when changed after verification or still open elsewhere |

## Remove

Turn Omachord off before removing the plugin:

1. Open Omachord and turn the **Omachord** switch off.
2. Confirm that the sidebar reports **Off**.
3. Run `omarchy plugin remove anothadev.omachord`.

Turning Omachord off removes generated integration while preserving routines and run history. If desired, those retained files can then be removed from `~/.config/omarchy/omachord.json` and `~/.local/state/omarchy/omachord/`.

## Test

The test suite uses temporary HOME and XDG directories and does not touch the live Hyprland configuration:

```bash
test/run.sh
```

Tests additionally require Node.js, `luac`, `qmllint`, `qmltestrunner`, `desktop-file-validate`, and the Omarchy plugin validator. The local gate verifies the exact Omarchy, Hyprland, and Quickshell release targets above.

It exercises strict and byte-bounded schema validation, literal argv handling, isolated hooks, microphone sounds, setter activation and restore, compare-before-restore, orphan deactivation, revision conflicts, exact-gap transaction races, non-executable uncommitted state, private state paths, signal-safe action ownership, reload rollback, bar-widget placement and the `plugins[]` migration, model and condition logic, runtime QML interaction, an offscreen run of the condition service against a fake runner, plugin validation, and QML linting.

`test/render/render.sh` is not part of the gate: it renders the panel's views, the compact layout, and the bar popup offscreen into `test/render/out/` so a change can be reviewed as images. It reads your real configuration through the runner but never writes.

## License

MIT. See [LICENSE](LICENSE).

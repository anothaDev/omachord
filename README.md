<p align="center">
  <img src="assets/omachord-icon.svg" alt="Omachord logo" width="80" height="80">
</p>

<h1 align="center">Omachord</h1>

![Omachord showcase](https://github.com/user-attachments/assets/323382f2-9eda-49a7-ae79-f5e9454a60bc)

Omachord is an accessibility-oriented shortcut and routine composer for Omarchy. It shows the effective Hyprland shortcut catalogue and lets you compose app-owned routines from ordered actions, one optional keyboard shortcut, Omarchy event hooks, and conditions such as a time period or a Wi-Fi network. Routines can change Omarchy state (night light, do not disturb, stay awake, theme, brightness) and put it back when they end; a routine that does is a *mode* that can be on or off.

The panel, the condition service, and a small bar widget run inside the existing `omarchy-shell` process. A separate Bash/`jq` runner owns validation, persistence, integration, and execution so shortcuts, hooks, and restores keep working when the panel is closed.

Omachord started with an old microphone automation. While revisiting it, something clicked: composable, restorable routines felt like a missing piece in the OS.

Release notes are in [CHANGELOG.md](CHANGELOG.md).

## Contents

- [Quick start](#quick-start)
- [Requirements](#requirements)
- [Install](#install) ([what enabling changes](#what-enabling-omachord-changes), [updating](#updating))
- [Development](#development)
- [Integration](#integration)
- [Panel](#panel) and [Bar widget](#bar-widget)
- [Routines](#routines) ([runner commands](#runner-commands))
- [Hook Context](#hook-context)
- [Security](#security)
- [Files](#files)
- [Remove](#remove)
- [Test](#test)
- [License](#license)

## Quick start

Read [what enabling Omachord changes](#what-enabling-omachord-changes), then install, enable, and open it:

```bash
omarchy plugin add https://github.com/anothaDev/omachord.git --enable
omarchy-shell shell summon anothadev.omachord '{}'
```

In **Routines**, choose a starting point from **New routine** (for example **Meeting microphone**), adjust its shortcut and actions, and press **Save** (Ctrl+S). The routine is live as soon as it is saved. Turn the **Omachord** switch off at any time to pause every shortcut, hook, and condition while keeping your routines.

## Requirements

- Omarchy 4.0.2
- Hyprland 0.56.2
- Quickshell 0.3.1

The runner also uses these commands. The Arch package that provides each is in parentheses; all of them are present in a standard Omarchy installation:

- `bash`, `jq` (`jq`), `flock` (`util-linux`), `fuser` (`psmisc`), `gawk` (`gawk`)
- GNU coreutils 9.5 or later (`coreutils`), for `mv --exchange` and `--update=none-fail`; the runner checks the version at startup and reports a clear error on an older one
- `perl` (`perl`), using only core modules: `Digest::SHA`, `Encode`, `Errno`, `Fcntl`, `IO::Handle`, `JSON::PP`, `POSIX`, and `Time::HiRes`
- `wpctl` (`wireplumber`) and `paplay` (`libpulse`) for the microphone action and sound cues
- `uwsm-app` (`uwsm`) and `gtk-launch` (`gtk3`) for the application-launch action
- `hyprctl` (`hyprland`) and `cmp` (`diffutils`)
- `sound-theme-freedesktop`, whose `/usr/share/sounds/freedesktop/stereo/` sounds are the default microphone and sound-action cues

The test suite additionally needs `lua` (for `luac`), `qt6-declarative` (for `qmllint` and `qmltestrunner`), `desktop-file-utils` (for `desktop-file-validate`), `python`, `nodejs`, and `strace`. See [Test](#test).

## Install

### What enabling Omachord changes

Enabling the plugin is your consent to the changes below. As soon as the plugin is enabled, and again each time Omarchy Shell starts, its condition service runs `omachord autostart`, which connects Omachord unless you turned it Off earlier. Connecting:

- Appends one marked loader line to `~/.config/hypr/bindings.lua`, after first saving a copy under `~/.local/state/omarchy/omachord/backups/`.
- Writes the generated shortcuts to `~/.config/hypr/omachord.lua`.
- Installs six hook dispatchers, one per supported event: `~/.config/omarchy/hooks/<event>.d/anothadev.omachord`.
- Installs a launcher entry, `~/.local/share/applications/anothadev.omachord.desktop`, and its icon, `~/.local/share/icons/hicolor/scalable/apps/anothadev.omachord.svg`.
- Reloads Hyprland, verifies the result, and rolls back on failure.

Once per install, on an installation first enabled with 0.2.0 or earlier (before the bar widget existed), Omachord also moves its own entry in `~/.config/omarchy/shell.json` from `plugins[]` onto the bar, keeping the previous file under the same `backups/` directory.

Turning the **Omachord** switch Off, or running `omachord disconnect`, reverses every change above except that one-time `shell.json` move. Nothing else is changed outside Omachord's own configuration file, state directory, and runtime lock directory (see [Files](#files)).

### With the plugin manager

Install and enable the plugin from Git:

```bash
omarchy plugin add https://github.com/anothaDev/omachord.git --enable
```

### Manual install (without the plugin manager)

You can manage the checkout yourself without using any `omarchy plugin` commands. This still loads Omachord as an Omarchy Shell plugin; the panel, bar, and automatic condition service are not standalone applications. For command-line use without loading a plugin, see [Runner only](#runner-only-no-shell-plugin).

Clone the complete repository into the shell's user-plugin directory:

```bash
mkdir -p "$HOME/.config/omarchy/plugins"
git clone -- https://github.com/anothaDev/omachord.git \
  "$HOME/.config/omarchy/plugins/anothadev.omachord"
```

If that destination already exists, do not overwrite it or nest another clone inside it. Use the existing installation or choose the development symlink approach below. Keep the complete checkout: the runner needs its sibling helpers and bundled assets.

Review the checkout before enabling it; plugins run as unsandboxed code in your shell. Then ask the shell to discover it and add its bar entry:

```bash
omarchy-shell shell rescanPlugins
omarchy bar put anothadev.omachord --section center --after omarchy.indicators
```

Wait for the plugin scan to finish before the second command if the shell reports `not ready`. The bar entry enables the panel and condition service too. By default the icon is hidden while no routine is active; [enable `alwaysShow`](#bar-widget) if you want it visible all the time.

### Open Omachord

For either installation method, open the panel with:

```bash
omarchy-shell shell summon anothadev.omachord '{}'
```

Omachord connects its Hyprland integration as soon as the plugin is enabled (see [What enabling Omachord changes](#what-enabling-omachord-changes)), so the panel opens with the **Omachord** switch on and saved routines are live immediately. Turn that switch off to pause shortcuts, hooks, and conditions while keeping every routine; that choice persists across shell restarts until you turn it on again.

Once connected, you can also open **Omachord** from the application launcher. If the service is not available after installation, restart the shell with `omarchy restart shell` and try again.

### Runner only (no shell plugin)

If you do not want to load a shell plugin at all, keep the repository outside the plugin directory and use the runner directly. This still targets the Omarchy/Hyprland environment listed above; it is not a generic Linux installation. Choose this instead of the plugin installation, not alongside it: both use the same routine configuration and integration files.

```bash
mkdir -p "$HOME/.local/share"
git clone -- https://github.com/anothaDev/omachord.git "$HOME/.local/share/omachord"

export OMACHORD_RUNNER_PATH="$HOME/.local/share/omachord/bin/omachord"
export PATH="$HOME/.local/share/omachord/bin:$PATH"
omachord connect
omachord status
```

Keep both exports in your shell startup file if you want to use `omachord` in future terminals. `OMACHORD_RUNNER_PATH` ensures generated shortcuts and hooks call this checkout rather than the default plugin path. Do not move the checkout while connected; disconnect first.

`connect` creates the same managed shortcuts, hooks, desktop entry, and icon described under [Integration](#integration), but it does **not** load a shell plugin. Manual runs, shortcuts, hooks, and explicit restore work. There is **no panel or bar popup, automatic condition evaluation, or automatic expiry handling** without the resident service. The installed desktop entry also needs the panel plugin, so it cannot open a window in this mode. End active modes yourself with `omachord deactivate <id>`.

To create or edit routines, take a revisioned snapshot and edit a separate draft, not the canonical config:

```bash
snapshot=$(omachord config snapshot) &&
  revision=$(printf '%s\n' "$snapshot" | jq -er '.revision') &&
  draft=$(mktemp --suffix=.json) &&
  printf '%s\n' "$snapshot" | jq '.config' > "$draft"
# Edit the JSON in "$draft" with your editor, then:
omachord config validate < "$draft" &&
  omachord config apply "$revision" < "$draft"
```

Stop if any command fails. Keep the original revision while editing; if apply reports `stale-config`, take a fresh snapshot and reconcile your edits rather than forcing an overwrite. Only apply routine JSON you trust: it can execute commands as your user. See [Routines](#routines) and [Runner commands](#runner-commands) for execution and restore behavior.

### Updating

For a plugin-manager installation:

```bash
omarchy plugin update anothadev.omachord
omarchy restart shell
```

`omarchy plugin update` fetches the repository's current default branch (`HEAD` of its origin), shows the diff for confirmation, fast-forwards, and validates the result. It does not install a marketplace-verified snapshot or a release tag, so it can include unreleased changes.

For a manual shell-plugin installation:

```bash
git -C "$HOME/.config/omarchy/plugins/anothadev.omachord" pull --ff-only
omarchy restart shell
```

For a runner-only installation, use `git -C "$HOME/.local/share/omachord" pull --ff-only` instead, then `omachord connect` to repair or refresh owned integration if needed. These commands also follow the repository's default branch. If you want a published version, check out an existing tag from [Releases](https://github.com/anothaDev/omachord/releases) instead. Do not discard local edits to force an update.

When upgrading a shell-plugin installation to 0.4.0 or later, restart Omarchy Shell so it discovers the new QML components. Existing routines are retained. If an older installation still has the generic launcher icon, run `~/.config/omarchy/plugins/anothadev.omachord/bin/omachord connect` to migrate the owned launcher integration (or use **Repair** if the panel offers it). Upgrades from 0.2.0 also receive the bar-widget placement described below.

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

When the plugin is enabled and each time Omarchy Shell starts, the condition service runs `omachord autostart`. Unless Omachord was turned Off, that performs its system-integration transaction:

- Refuses a fresh connection if Hyprland already reports configuration errors; an owned broken integration can still be repaired transactionally.
- Backs up `~/.config/hypr/bindings.lua` under `~/.local/state/omarchy/omachord/backups/`, keeping the ten most recent backups plus the original.
- Adds one marked optional-loader line to `bindings.lua`. Disconnecting removes it again and leaves the file byte-identical to how it was before connecting, apart from any edits you made in the meantime.
- Generates app-owned shortcut Lua and six guarded hook dispatchers.
- Installs the Omachord desktop entry and its branded SVG under the user's hicolor icon theme.
- Reloads Hyprland, verifies the generated configuration, and rolls back on failure.

Turning the **Omachord** switch off removes generated integration and persists that preference. Saving while it is off only updates the routine document and never reactivates integration. Turning it on performs the same guarded transaction again, including the required Hyprland reload. The same switch sits in the bar popup.

Switches keep a fixed size and replace their thumb with a spinner while an operation is pending. Repeat activation is ignored until it finishes; other routine rows can join a pending enable/disable batch. The bar and panel share connection progress, and the confirmed on/off state is published before the switch becomes available again. A disabled control that is not waiting for an operation (for example, a live routine switch with unsaved edits) does not spin.

## Panel

The window has three views, chosen from the sidebar or with a payload (`omarchy-shell shell summon anothadev.omachord '{"view":"activity"}'`):

- **Routines**: the list with an on/off switch per routine (saved immediately), a live dot while a mode is on, and the editor. The editor reads top to bottom: name and enabled flag, **Starts when** (shortcut, Omarchy events), **If** (conditions, all of which must hold), **Then** (actions in order), and **When it ends**. A mode shows a switch in its header to turn it on or off right now; the footer keeps **Save** (Ctrl+S), **Run now** / **Turn on** / **Turn off** (or **Save & run** while the draft is unsaved), **Duplicate**, and **Delete** in view at all times. Validation marks the failing card and scrolls to it.
- **Shortcuts**: every shortcut Hyprland currently has, searchable, filtered by **All** / **Omachord** / **Hyprland**. Pick a Hyprland shortcut to start a routine that overrides it.
- **Activity**: what is on now (with **End**), each condition routine and why it is waiting (for example `Waiting for Wi-Fi Home (connected to Cafe)`), the routines attached to Omarchy events, the condition service's inputs, and the recent run history.

The window follows the Omarchy theme live: colors crossfade when `omarchy theme set` runs, and the on-state green comes from the theme's own palette (`green` in `colors.toml`, with a fallback for themes that ship none). The current theme name is shown at the bottom of the sidebar. Keyboard: Tab moves between controls, j/k walk a focused list, Enter opens the highlighted routine, Esc leaves a text field first and then closes the window, Ctrl+S saves, Ctrl+R refreshes. The panel mirrors the in-process service, so a routine started by its shortcut, an event, a condition, or ended from the bar updates the window without pressing Refresh.

## Bar widget

The transparent Omachord ring/keycap mark appears in the bar while a routine is running. When kept visible while idle, it is dimmed only when Omachord is Off; On uses normal theme brightness, and a running routine uses the theme accent. The popup keeps its own theme foreground. Neither surface adds a background tile. The initial placement is the center section; use `omarchy bar move` to choose another section without changing your routine configuration. Left or right click opens a popup listing what is on, when it started, when it ends, and what it restores, with an end button per routine and a switch for Omachord itself; j/k, Enter, x, and Esc work as in other Omarchy panels, and `o` opens the window. Middle click opens the window directly. Two settings live on the bar entry in `shell.json`:

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
- A restoring setter read that returns something unexpected refuses that setter's change. A failure part-way through rolls back the setters that were already applied. Brightness availability is additionally checked before **any** action in a routine that declares a brightness action.
- A restore that cannot complete (for example while the shell is not running) keeps the activation record and reports the routine as still active, so a later deactivation finishes the job. Records are only discarded once everything they recorded has been dealt with.
- While a routine is active, another routine cannot claim the same restoring setter type. The second activation reports a conflict; non-restoring setters remain unrestricted.

#### Display brightness availability

A brightness action requires a working software brightness controller. Being wired does not determine support: some external displays support DDC/CI, others do not, and DDC/CI may be disabled in the display's own menu. Omachord does not substitute a dimming overlay or silently omit the brightness action. If the selected display is unsupported, asleep, disconnected, or unreadable at preflight, the **whole routine is blocked before its actions run**, including a brightness action with restore disabled. A readable probe cannot guarantee that a later write will succeed; later failures still use rollback and retained recovery, not a claim that earlier non-restoring effects can be undone.

For condition-driven starts, this appears as **Unavailable** rather than an endless five-minute retry. You can explicitly retry after the display becomes available, edit the routine, or wait for its conditions to go false and become true again. An already-active routine with pending recovery is different: restoration keeps its record and retains the normal retry behavior. Do not delete the record to silence a hardware error.

Brightness requirements in both start and end actions are checked at activation. Reads, writes, restoration and end actions use the display chosen then, not whichever display is focused later. Records store the connector name and a digest of the compositor's make/model/serial metadata. A missing or observably replaced display defers restoration; identical/blank hardware metadata, cached DDC bus mappings, the backend's internal-backlight selection, and changes during external tool calls cannot provide a kernel-level physical identity guarantee. Omarchy's Apple HID helper cannot currently bind its device to a named display, so those brightness routines are reported unavailable rather than risking a different display.

On external DDC displays, a requested 0% is recorded as the backend's effective minimum of **1%**; internal backlights can use 0%. A successful helper exit is not enough: Omachord reads brightness back on the same target before confirming the setter. Dropped writes, unsupported precision/rounding, and unreadable confirmation fail rather than claiming success. An unconfirmed intermediate value keeps recovery for inspection instead of being mistaken for a manual override. Restoration also records pending/done progress so an uncertain restoring write cannot become a false manual override on retry. Once a manual override is detected, older brightness entries for the same target are not replayed. Checkpoint updates and record removal compare against the expected record; a concurrent change stops further recovery effects instead of overwriting the changed record. **Deactivated** can mean that restoration was intentionally skipped because a value changed; it is not a guarantee that every original value was written back.

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

The status names every active routine and, for each condition routine, one `details` entry per condition (its summary, whether it holds, and the input the service sees) plus the last failed start or end and when it will be retried. The same service accepts `omarchy-shell omachord end <routine-id>` and `start <routine-id>`, which is what the bar widget uses. Two more IPC calls are for troubleshooting: `omarchy-shell omachord evaluate` schedules a condition evaluation after a short debounce (it answers `scheduled`), and `omarchy-shell omachord reload` makes the service re-read status, configuration, activation records, and toggles from the runner (it answers `reloading`).

### Runner commands

| Command | Purpose |
| --- | --- |
| `omachord status` | Inspect configuration and integration health |
| `omachord connect [revision]` | Reuse committed configuration; supply the inspected revision to approve changed configuration |
| `omachord autostart` | What the service runs at startup: connect with committed configuration (or bootstrap an empty one) unless Omachord was turned Off |
| `omachord disconnect` | End active routines and remove owned integration, keeping configuration and history; persists Off |
| `omachord config show` | Print the committed configuration as validated, sorted JSON |
| `omachord config snapshot` | Read configuration with its compare-and-swap revision |
| `omachord config validate` | Validate candidate JSON from stdin without saving |
| `omachord config apply <revision>` | Apply candidate JSON from stdin only if the loaded revision still matches |
| `omachord run <id> [source [revision]]` | Run a routine; toggles a stateful routine; an optional reviewed revision must still match |
| `omachord activate <id> [source [revision]]` | Activate without toggling; manual/test callers may bind a reviewed revision |
| `omachord deactivate <id> [manual\|shortcut\|test]` | End a routine from its activation record |
| `omachord active` | List activation records |
| `omachord trigger hook <event> [args...]` | Run the routines attached to one of the six Omarchy events; this is what the hook dispatchers call |
| `omachord recovery inspect <id>` | Inspect an activation record and its recovery revision |
| `omachord recovery restore <id> <revision> --skip-end-actions` | Restore recorded setter values without executing remaining end actions, only for the inspected record |
| `omachord recovery bind-brightness <id> <revision> <monitor>` | Explicitly bind an inspected legacy brightness record to its original display; does not change physical brightness |
| `omachord bindings` | Print the current shortcut catalogue (from `omarchy menu keybindings --print`) as JSON |
| `omachord commands` | List Omarchy commands offered as actions, excluding hidden and `requires_sudo` ones |
| `omachord toggles` | List valid top-level Omarchy toggle flags as bounded JSON |
| `omachord themes` | List installed themes through a bounded control probe |
| `omachord service-status` | Read one validated condition-service status object through a bounded probe |
| `omachord theme-palette` | Read the current theme name and green within fixed file-size limits |
| `omachord logs [limit]` | Newest-first run history, 50 entries by default and at most 500; stateful routines log `activated` and `deactivated` entries |
| `omachord widget ensure\|status\|forget` | Place the bar widget once through the Omarchy shell, inspect or clear that record |

In a plugin installation, the runner is at `~/.config/omarchy/plugins/anothadev.omachord/bin/omachord`; use that full path if `omachord` is not on your `PATH`. `omachord --help` prints the full usage, including the `activate`/`deactivate` forms reserved for the condition service.

Run history is `~/.local/state/omarchy/omachord/runs.jsonl`. When it grows past 256 KiB, the next entry first trims it to its last 200 lines.

The microphone template calls `omarchy audio input mute` first, preserving Omarchy's OSD and hardware LED behavior. It then reads the resulting microphone state and starts the configured mute or live cue asynchronously, so playback does not hold routine/configuration locks or delay completion.

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

- **Routines are trusted code.** Saving a routine authorizes Omachord to run it as your user whenever its shortcut, events, or conditions fire, without sandboxing. Review routine JSON from anyone else before saving or running it.
- **`exec` and `shell`.** `exec` launches the chosen program with a literal argument list and no shell parsing. `shell` intentionally runs `bash -lc` and can do anything your user can.
- **No elevation.** Omachord needs no sudo or pkexec and never elevates itself. `exec` and `shell` actions run any program you choose with your user's rights, so a routine can call a privilege-elevation tool, and a recently cached password may let it do so without asking again. Save only routines you would run yourself.
- **Backups and rollback.** Omachord keeps a copy of `bindings.lua` and `shell.json` before editing them (see [Files](#files)) and rolls back a failed integration or configuration transaction. Ending a routine is not rolled back: if Disconnect, or a save that disables or deletes an active routine, fails after that routine was ended, it stays ended. Other effects of routine actions are not undone, apart from the values a restoring setter puts back.
- **Reporting.** Report vulnerabilities privately through GitHub private vulnerability reporting (**Report a vulnerability** in the Security tab), not in a public issue.

[SECURITY.md](SECURITY.md) describes the trust model, the supported environment overrides, resource limits, and the transaction and recovery invariants.

### Recovering interrupted state

If an interrupted transaction leaves an uncommitted configuration, the panel refuses to load or run it. Inspect `omachord config snapshot`, review all routines in that snapshot, then use `omachord connect <inspected-revision>` or replace the configuration through revision-bound `config apply`. A revision identifies bytes; it does not replace reviewing them.

Activation records for stateful routines requiring brightness use schema version 3, including a display identity and, for restoring setters, write-confirmation and restore-progress receipts; other new records remain version 2. Older runners intentionally reject unknown versions, so finish restoring active routines before downgrading. Legacy brightness records do not identify their display: they remain pending rather than guessing from today's focus. Inspect the record with `omachord recovery inspect <id>`, then explicitly bind its original display with `omachord recovery bind-brightness <id> <revision> DP-1` (use the actual original monitor name). The mapping is saved only if the inspected record is unchanged; it does not assert that the legacy write succeeded. Normal deactivation can then retry restoration, retaining ambiguous values for inspection. Already-bound records cannot be retargeted with this command.

Legacy records with end actions cannot prove which action list their saved progress referred to and require explicit recovery. Run `omachord recovery inspect <id>`, review the snapshot and recorded setter values, then use `omachord recovery restore <id> <revision> --skip-end-actions` if restoring those values and skipping remaining executable end effects is the intended outcome. The runner records that choice durably before restoring setters. If restoration fails, it keeps the record so recovery can be retried. For an unbound legacy brightness record with legacy end actions, explicitly skip those end actions first, then inspect the updated record and bind its display.

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Files

Paths follow the XDG defaults: `~/.local/state` is `$XDG_STATE_HOME` and `~/.local/share` is `$XDG_DATA_HOME` when those are set. The `~/.config` paths are fixed, as in Omarchy, and do not follow `XDG_CONFIG_HOME`.

| Path | Purpose |
| --- | --- |
| `~/.config/omarchy/omachord.json` | Canonical routine configuration |
| `~/.config/hypr/omachord.lua` | Generated enabled shortcuts |
| `~/.config/hypr/bindings.lua` | Receives one marked optional-loader line |
| `~/.config/omarchy/hooks/<event>.d/anothadev.omachord` | Guarded event dispatchers |
| `~/.local/share/applications/anothadev.omachord.desktop` | Application launcher |
| `~/.local/share/icons/hicolor/scalable/apps/anothadev.omachord.svg` | Application launcher icon |
| `~/.local/state/omarchy/omachord/runs.jsonl` | Rolling execution history |
| `~/.local/state/omarchy/omachord/active/<routine-id>.json` | Activation record of a stateful routine, holding the values to restore |
| `~/.local/state/omarchy/toggles/<flag>` | Omarchy-owned toggle flags; Omachord only reads them for the toggle condition |
| `~/.local/state/omarchy/omachord/connection.json` | Integration ownership record |
| `~/.local/state/omarchy/omachord/connection.disabled.json` | Persisted Off choice; while present, startup does not reconnect |
| `~/.local/state/omarchy/omachord/bar-widget.json` | Record that the bar widget was placed once |
| `~/.local/state/omarchy/omachord/backups/bindings.lua.<suffix>` | `bindings.lua` as it was before Omachord edited it; pruned to the ten most recent plus the original |
| `~/.local/state/omarchy/omachord/backups/shell.json.<suffix>` | `shell.json` as it was before the widget entry was moved |
| `~/.local/state/omarchy/omachord/config.commit.json` | Last committed configuration revision |
| `~/.local/state/omarchy/omachord/config.lock`, `log.lock` | Configuration and run-history locks |
| `$XDG_RUNTIME_DIR/omachord/*.lock` | Per-routine and shared-resource locks (`~/.local/state/omarchy/omachord/runtime/` when `XDG_RUNTIME_DIR` is unset) |
| `~/.local/state/omarchy/omachord/conflicts/` | Concurrent file versions preserved during a rare transaction conflict |
| `~/.local/state/omarchy/omachord/retired/` | Replaced inodes retained only when changed after verification or still open elsewhere |
| `<managed-parent>/.omachord-conflicts/` and `.omachord-retired/` | Private adjacent archives when state-directory storage cannot retain the original inode |

Recovery archives may contain unique later writes made through an already-open file descriptor. They have no automatic age-based deletion or total storage quota; closing a file or waiting does not prove it is safe to delete. Preserve the reported recovery locations, inspect their contents, and decide which versions to keep before manual cleanup. An interrupted cleanup may also leave a private transaction file beside a managed destination. See [SECURITY.md](SECURITY.md) for the durability and recovery boundaries.

## Remove

Disconnect before removing the code. Only the runner removes the generated shortcuts and hook dispatchers, so deleting the checkout first leaves them behind.

For a **plugin-manager installation**, either turn the **Omachord** switch off in the panel, confirm the sidebar reports **Off**, and run `omarchy plugin remove anothadev.omachord`, or do the same from a terminal:

```bash
~/.config/omarchy/plugins/anothadev.omachord/bin/omachord disconnect &&
  omarchy plugin remove anothadev.omachord
```

For a **manual shell-plugin installation**, disconnect first and unload it without the plugin manager:

```bash
~/.config/omarchy/plugins/anothadev.omachord/bin/omachord disconnect &&
  omarchy-shell shell setPluginEnabled anothadev.omachord false
```

Only after disconnect succeeds and the shell replies `ok`, remove the checkout at `~/.config/omarchy/plugins/anothadev.omachord` (or just its symlink if you used a development checkout).

For a **runner-only installation**, run `omachord disconnect` before deleting `~/.local/share/omachord`, then remove the exports you added to your shell startup file. If disconnect fails, keep the checkout and activation records so you can finish restoring active routines before removal.

**Removed while On?** If the plugin was removed without disconnecting first, reinstall it without enabling it, disconnect, and remove it again:

```bash
omarchy plugin add https://github.com/anothaDev/omachord.git   # answer No to "Enable now?"
~/.config/omarchy/plugins/anothadev.omachord/bin/omachord disconnect &&
  omarchy plugin remove anothadev.omachord
```

`omarchy plugin add --yes` also installs without enabling. Disconnect ends active routines, restoring what they recorded, and removes the loader line, shortcuts, hook dispatchers, launcher entry, and icon.

**What stays behind.** Disconnecting preserves your routines and history and does not remove:

- `~/.config/omarchy/omachord.json` (your routines) and the state directory `~/.local/state/omarchy/omachord/` (history, records, backups, and recovery archives; see [Files](#files)).
- The `~/.config/omarchy/hooks/<event>.d/` directories, which may now be empty.
- Any private `.omachord-conflicts/` or `.omachord-retired/` archive directories, or an interrupted private transaction file (`.omachord-*`), beside managed files. These are created only in the rare cases described under [Files](#files).
- Lock files under `$XDG_RUNTIME_DIR/omachord/`, which the system clears when your last session ends (or under `~/.local/state/omarchy/omachord/runtime/` when `XDG_RUNTIME_DIR` is unset).

`~/.local/state/omarchy/omachord/backups/` holds the only copies of `bindings.lua` and `shell.json` from before Omachord edited them. Compare them with your current files and restore anything you need **before** deleting the state directory. Inspect recovery archives before deleting them, too; they may contain changes that exist nowhere else.

## Test

The test suite uses temporary HOME and XDG directories under `${TMPDIR:-/tmp}` and does not touch the live Hyprland configuration:

```bash
test/run.sh
```

Tests additionally require Python 3 (standard library only), Node.js, `strace`, `luac`, `qmllint`, `qmltestrunner`, `desktop-file-validate`, and the Omarchy plugin validator. `strace` verifies that notification-only service watchers do not read file bodies and enables the real write-error injection checks. Skipped injections in environments without it must be reported and do not count as local release evidence. The local gate verifies the exact Omarchy, Hyprland, and Quickshell release targets above.

Deterministic filesystem race and failure calls explicitly select disposable instrumented helper copies. Ordinary calls still test the shipped files. Production helpers ignore the former filesystem test variables and reload-bypass flag; the production-boundary suite verifies this separately. Fixture insertion points are checked so source changes cannot silently disable fault coverage.

It exercises strict and byte-bounded schema validation, bounded toggle discovery, literal argv handling, isolated hooks, microphone sounds, setter activation and restore, compare-before-restore, orphan deactivation, revision conflicts, descriptor-pinned transaction races and durability failures, non-executable uncommitted state, private state paths, signal-safe action ownership, reload rollback, bar-widget placement and the `plugins[]` migration, launcher ownership upgrades, reload-free saves and their repair fallbacks, and detached audio lock release. Desktop checks cover model and condition logic, runtime QML interaction, service concurrency and panel enable batching against fake runners, transparent bar artwork and theme switching at 1×/2× scaling, plugin validation, and QML linting.

The toggle regressions cover fixed geometry, animated pending states, mouse/keyboard/accessibility activation, shared panel/bar connection progress, stale status replies, and failure recovery. The runner speed suite checks that shortcut processing uses a constant number of `jq` launches as the shortcut count grows; its reported connect/status timings are diagnostic, not desktop latency guarantees.

Brightness regressions exercise unavailable-controller preflight, pinned target selection, disconnect/replacement, write confirmation, retained recovery, legacy binding, and manual overrides without touching real displays. The additional [Lean verification](docs/BRIGHTNESS_PROOFS.md) is run with `bash test/lean/run.sh` using an installed Lean 4 toolchain (tested with 4.34.0). It proves the stated model properties and compares generated cases against the actual condition functions; it is not a proof of the entire Bash/QML application or external hardware. Lean is a separate local check, not installed or silently skipped by portable CI.

GitHub Actions runs the required `portable` check on pull requests and on pushes to `main` and `v*` tags. It includes source and manifest validation, required QML/artwork file checks, the filesystem transaction tests, the action-supervisor tests, runner integration and fast-path/audio regressions with mocked desktop commands, and the Node.js model, condition, and QML policy tests. Tag builds also require the tag to match `v` plus the manifest version. The job uses Debian 13 for GNU coreutils 9.5+ (`mv --exchange` and `--update=none-fail`) explicitly installs GNU awk for Unicode key normalization, and installs `strace` so the write-error injection checks run; the shell test suites run as a non-root user so permission-denial checks remain meaningful. It does not replace the full local gate: run `test/run.sh` before releasing to also check the target desktop versions, plugin validation, runtime QML behavior, and QML linting. See [Releasing](docs/RELEASING.md) for the clean-archive and review requirements.

`test/render/render.sh` is not part of the gate: it renders the panel's views, the compact layout, and the bar popup (including off and pending states) offscreen to PNG files so a change can be reviewed as images. It reads your real configuration through the runner but never writes it. Because the images show your own routines, they go to a new private temporary directory by default (printed when it finishes); pass a directory, such as `test/render/out`, to choose the location.

## License

MIT. See [LICENSE](LICENSE).

Omachord bundles no third-party code or assets. Its runtime dependencies (see [Requirements](#requirements)) are installed separately and remain under their own licenses.

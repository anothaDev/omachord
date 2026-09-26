# Changelog

All notable changes to Omachord. Versions follow the `version` field in `manifest.json`; release tags are `v` plus that version.

## 0.5.0 — 2026-09-26

Activation records for brightness routines move to schema version 3 and the runner gains commands. Finish restoring active routines before downgrading: older runners reject version 3 records.

### Brightness

- **Capability gating:** a routine that declares a brightness action (in its start or end actions) checks for a working brightness controller before **any** of its actions run. An unsupported, asleep, disconnected, or unreadable display blocks the whole routine instead of running the other actions and failing part-way. Condition-driven starts show **Unavailable** instead of retrying every five minutes.
- **Target-bound recovery:** reads, writes, restoration, and end actions use the display chosen at activation, not whichever display is focused later. Records store the connector name and a digest of the display's make/model/serial metadata; a missing or replaced display defers restoration.
- **Confirmed writes:** brightness is read back on the same display before a setter counts as applied, and restoration records pending/done progress so an uncertain write is not mistaken for a manual change on retry. On external DDC displays a requested 0% is recorded as the backend's effective minimum of 1%.
- **Legacy records:** `omachord recovery bind-brightness <id> <revision> <monitor>` binds an inspected pre-0.5 brightness record to its original display. It does not change physical brightness.
- A scoped Lean model of the brightness policy ([docs/BRIGHTNESS_PROOFS.md](docs/BRIGHTNESS_PROOFS.md)) runs locally with `bash test/lean/run.sh`.

### Integration and transactions

- **`bindings.lua` round trip:** Connect followed by Disconnect leaves `~/.config/hypr/bindings.lua` byte-identical to the original. Backups under `~/.local/state/omarchy/omachord/backups/` are pruned to the ten most recent plus the original pre-Omachord copy.
- **Configuration lock no longer held while actions run:** a long action (a theme change, a delay) no longer blocks a concurrent save for its whole duration. A save, Connect or Disconnect that must end a routine which is still mid-run waits up to the lock timeout (10 seconds by default) and then reports the retryable `routine-running` code without changing anything. (Previously listed in the known issues.)
- **Deactivation ordering:** Disconnect and saves that remove or disable an active routine end it as late as possible, after the checks that could still refuse the operation. Ending a routine is not rolled back if a later step fails. (Previously listed in the known issues.)

### Hardening

- `OMACHORD_CAPTURE_MODE` and `OMACHORD_CAPTURE_LIMIT` are no longer honored from the environment. Hook suppression ignores the old bare `OMACHORD_BULK_CLEANUP` flag and requires an internal live-owner context. The supported overrides are listed in [SECURITY.md](SECURITY.md).
- The runner checks for GNU coreutils 9.5 or later (`mv --exchange`) before stateful commands and reports a clear error instead of failing inside a transaction.
- Invalid `OMACHORD_ACTION_TIMEOUT`, `OMACHORD_CONTROL_TIMEOUT` or `OMACHORD_LOCK_TIMEOUT` values are rejected with the `invalid-environment` code.
- Actions only inherit standard input, output and error; timeouts, kills and supervisor failures are reported separately instead of all as timeouts.
- `omachord --help` lists `themes`, `service-status`, and `theme-palette`.
- QML watchdogs keep the panel, bar, and service from waiting indefinitely on a runner request that never finishes.
- Panel and service operations that execute routine actions have a ten-minute total deadline, including configuration apply, Disconnect, and brightness recovery. Per-action timeout overrides do not extend it. Use the CLI for longer operations; see the README for interruption behavior.

### Documentation and CI

- README: what enabling Omachord changes, a Quick start, a table of contents, a complete command table, distribution package names, and safer removal and update steps. Release notes moved to this file.
- SECURITY.md lists the supported environment overrides and holds the internal invariants formerly in the README.
- Release checklist: filing the marketplace verification request.
- CI pins `actions/checkout` and the Debian image by digest, installs `strace`, avoids duplicate push/PR runs, and Dependabot tracks GitHub Actions weekly.
- Tests use `${TMPDIR:-/tmp}` for temporary files, and `test/render/render.sh` writes to a temporary directory by default because it renders your real routines.

## 0.4.1

- **Clear bar status:** dimmed when Off, normal theme brightness when On, and the theme accent while a routine is running.
- **Balanced icon size:** the bar mark matches the stock icon font size while retaining the standard click target. Popup artwork is unchanged.

To place the widget with your right-side status controls while preserving its settings:

```bash
omarchy bar move anothadev.omachord --section right --after omarchy.tray
```

## 0.4.0

- **More responsive routines:** independent manual routine requests can run concurrently, and busy indicators stay with the affected routine instead of blocking the whole panel.
- **Stable loading switches:** pending toggles show a spinner without changing size, and ignore repeat activation until the operation settles. The panel and bar share connection progress.
- **Faster connection changes:** redundant status probes are avoided, and shortcut processing and inode safety checks are batched while retaining locking, rollback, and durability protections.
- **Faster saves:** enable/disable edits to different routines are batched, and edits that leave generated shortcuts unchanged avoid an unnecessary Hyprland reload when the existing integration is verified.
- **Faster shortcut browsing:** the catalogue is parsed in batches and has a styled scrollbar.
- **Non-blocking microphone cues:** mute/unmute sounds no longer hold routine locks while playing.
- **Omachord branding:** a branded application launcher icon, plus a transparent ring/keycap mark in the bar and popup that follows their theme foreground colors.

Earlier releases: see [GitHub Releases](https://github.com/anothaDev/omachord/releases).

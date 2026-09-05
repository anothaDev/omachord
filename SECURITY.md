# Security Policy

## Supported Versions

Security fixes are provided for the latest released version of Omachord.

## Reporting

Use **Report a vulnerability** in the repository's Security tab to open a private security advisory. Do not include vulnerability details in a public issue. If private reporting is unavailable, contact the maintainer through the GitHub profile to request a private channel first.

Include the affected version, reproduction steps, impact, and any suggested mitigation. Reports will be acknowledged and assessed before coordinated disclosure.

## Trust Model

Routine configuration is trusted local code and is not sandboxed. `exec` and `shell` actions can run arbitrary programs, read user data, and invoke `sudo`; cached credentials may permit elevation without another password prompt. Review externally supplied routine configuration before saving or running it.

The runner protects its managed configuration and state files from unsafe ownership, permissions, symlinks, concurrent replacement, and partial integration transactions. Security reports that bypass those controls are in scope.

Setter actions change Omarchy state (night light, do-not-disturb, idle inhibition, theme, brightness) through argv-literal calls to Omarchy's own tools, and activation records under the private state directory are validated before they are trusted for a restore. The runner remains the only component that executes anything or writes state; the panel composes configuration and the condition service, which is resident inside `omarchy-shell` while the plugin is enabled, only decides when to call `omachord activate` or `omachord deactivate` with a literal argument list. The bar widget and the panel ask that service to end or start a routine, or to turn the integration on or off; each request becomes one runner call with a literal argument list.

Besides the Hyprland files it already owns, the runner installs its launcher and branded icon under `~/.local/share/applications/` and `~/.local/share/icons/hicolor/scalable/apps/`. It edits `~/.config/omarchy/shell.json` in exactly one case: `omachord widget ensure` moves this plugin's own entry from `plugins[]` into the bar layout on an install upgraded from 0.2.0. The edit is a single atomic rewrite of a parsed document (no other entry is touched), the previous file is kept under the private state directory, and the placement is recorded so it never repeats. Reports that show the runner writing anything else outside its owned files are in scope.

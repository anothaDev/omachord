# Security Policy

## Supported Versions

Security fixes are provided for the latest released version of Omachord.

## Reporting

Use **Report a vulnerability** in the repository's Security tab (GitHub private vulnerability reporting) to open a private security advisory. Do not include vulnerability details in a public issue. If private reporting is unavailable, contact the maintainer through the GitHub profile to request a private channel first.

Include the affected version, reproduction steps, impact, and any suggested mitigation. Reports will be acknowledged and assessed before coordinated disclosure.

## Trust Model

Routine configuration is trusted local code and is not sandboxed. `exec` and `shell` actions can run arbitrary programs and read user data. Review externally supplied routine configuration before saving or running it.

Omachord needs no sudo or pkexec and never elevates itself. `exec` and `shell` actions run any program you choose with your user's rights, so a routine can call a privilege-elevation tool, and a recently cached password may let it do so without asking again. Save only routines you would run yourself.

- `exec` launches the selected program with a literal JSON argument array and no shell parsing. `shell` intentionally runs `bash -lc`.
- Omarchy command choices exclude commands marked hidden or `requires_sudo`, but that metadata is not a security boundary; a selected command can still open a privilege prompt internally.

The runner protects its managed configuration and state files from unsafe ownership, permissions, symlinks, concurrent replacement, and partial integration transactions. Security reports that bypass those controls are in scope.

The supported release environment is Omarchy 4.0.2, Hyprland 0.56.2, and Quickshell 0.3.1 on Linux, with the system tools listed in the README. The QML panel and condition service run inside the user's Omarchy Shell process; there is no privileged Omachord daemon or network listener. The user's shell/plugin installation, executable search path, and environment are trusted code/configuration inputs. Omachord does not isolate itself from arbitrary malicious code already executing as the same user, but same-user control of a documented configuration, integration path, or recovery record does not waive the integrity guarantees below.

## Environment overrides

The runner and the QML components honor only the variables below. They exist for tests, runner-only installations, and unusual layouts. They are same-user conveniences, not security boundaries: anything that can set your environment can already run code as you.

| Variable | Default | Effect |
| --- | --- | --- |
| `OMACHORD_ACTION_TIMEOUT` | `30s` | Per-stage timeout for ordinary action programs (a `timeout(1)` duration) |
| `OMACHORD_CONTROL_TIMEOUT` | `5s` | Timeout for built-in control probes (Omarchy, Hyprland, and shell queries) |
| `OMACHORD_LOCK_TIMEOUT` | `10` | Seconds to wait for the configuration and run-history locks |
| `OMACHORD_OMARCHY_CONFIG_DIR` | `~/.config/omarchy` | Base for the default configuration, hook, shell, and runner paths |
| `OMACHORD_CONFIG_FILE` | `<omarchy config>/omachord.json` | Routine configuration (also read by the QML components) |
| `OMACHORD_STATE_DIR` | `$XDG_STATE_HOME/omarchy/omachord` | Private state directory (also read by the QML components) |
| `OMACHORD_HYPR_DIR` | `~/.config/hypr` | Directory holding `bindings.lua` and the generated `omachord.lua` |
| `OMACHORD_HOOK_ROOT` | `<omarchy config>/hooks` | Root of the `<event>.d/` hook directories |
| `OMACHORD_DESKTOP_FILE` | `$XDG_DATA_HOME/applications/anothadev.omachord.desktop` | Installed launcher entry |
| `OMACHORD_ICON_FILE` | `$XDG_DATA_HOME/icons/hicolor/scalable/apps/anothadev.omachord.svg` | Installed launcher icon |
| `OMACHORD_SHELL_CONFIG` | `<omarchy config>/shell.json` | Shell configuration read and, once, edited by `widget ensure` |
| `OMACHORD_RUN_LOCK_DIR` | `$XDG_RUNTIME_DIR/omachord`, else `<state>/runtime` | Per-routine and shared-resource locks |
| `OMACHORD_THEME_DIR` | `$XDG_STATE_HOME/omarchy/current/theme` | Theme directory read by `theme-palette` |
| `OMACHORD_THEME_NAME_FILE` | `$XDG_STATE_HOME/omarchy/current/theme.name` | Theme name read by `theme-palette` |
| `OMACHORD_RUNNER_PATH` | `<omarchy config>/plugins/anothadev.omachord/bin/omachord` | Runner that generated shortcuts and hooks call; the QML components use it only when it is an absolute path |
| `XDG_STATE_HOME`, `XDG_DATA_HOME`, `XDG_RUNTIME_DIR` | `~/.local/state`, `~/.local/share`, unset | Standard base directories for the defaults above |

Internal knobs are not honored from the environment: `OMACHORD_BULK_CLEANUP`, `OMACHORD_CAPTURE_MODE`, `OMACHORD_CAPTURE_LIMIT`, the `OMACHORD_FS_TEST_*` fault controls, and the former `OMACHORD_SKIP_HYPR_RELOAD` bypass. `OMACHORD_TRIGGER`, `OMACHORD_HOOK`, `OMACHORD_PHASE`, and `OMACHORD_ARG_<n>` are outputs: the runner clears inherited values on entry and sets them only for the child programs it starts.

## Authorization and recovery

- Saving routine JSON is an explicit authorization to publish that executable configuration. Importing or generating a file outside the panel does not establish review. Exactly one JSON document is accepted, and execution requires its committed revision.
- Automatic startup checks persistent Off under the integration mutation lock. It reuses committed content or bootstraps an initially absent, empty configuration; it does not promote changed or unmarked routine content. Explicit Connect with an inspected revision and revision-bound configuration apply are the admission paths for that content.
- Hook, shortcut, condition-service and timer requests recheck automatic eligibility after acquiring the shared configuration lock. A dispatcher launched before Disconnect cannot start work after Off has committed. Explicit manual/test commands retain their documented runner-only behavior.
- Saved enable/disable intents compare the complete reviewed routine definition. Queued manual UI Run/Start carries the reviewed full-configuration revision from the click (or successful Save & Run commit) through the worker queue. The runner compares that revision with the exact bounded snapshot it resolves and executes, without a second configuration load. An intervening save, even to another routine, requires a fresh start request. Explicit runner CLI calls without a revision intentionally select the latest committed routine; the condition service binds requests to the revision it evaluated. End/recovery use recorded lifecycle state instead of a queued-start revision, while executable end plans still require their stored identity checks.
- Active end-plan identity is frozen. A numeric checkpoint cannot be reused against today's edited action list. New activation records carry the plan digest; legacy action records require explicit recovery instead of inferring their history. Typed restore data remains available when an end action, restore, or removal fails.
- Saves use revision-based compare-and-swap, so a stale panel cannot overwrite a newer configuration. Readers require the canonical configuration to match a post-reload commit record; a candidate cannot execute before its integration transaction commits, and an interrupted candidate fails closed.
- Condition-service jobs carry the revision they evaluated; the runner rejects stale jobs and post-Disconnect activations before any routine action runs. A queued routine switch is bound to the complete definition reviewed when it was requested; a retry cancels that switch if the definition changed or disappeared, and independent switches remain available.
- Saves reject changes to a retained active routine's end plan. End the routine before editing that plan; disabling or removing a routine still performs the existing cleanup first. Ending routines is not part of the rolled-back transaction: it happens as late as possible, and a routine ended before a later step fails stays ended.
- Activation records are validated before use. A record that fails validation stops `run`, `activate`, `deactivate`, and `active` with `unsafe-state` instead of being treated as inactive. Setter writes are argv-literal calls to Omarchy tools.
- A theme setter makes Omarchy fire its `theme-set` hook, which re-enters the runner. The per-routine lock reports the originating routine as busy, so a routine cannot recurse into itself.
- `recovery restore ... --skip-end-actions` is an explicit revision-bound choice to restore saved setter values and skip remaining executable end effects. That choice is committed before restoration, so a retry cannot revive skipped commands.

## Process and resource boundaries

The native supervisor owns both output capture and the timeout process group. It leaves the group leader unreaped until every possible group signal has been sent. Runner cancellation closes an owned pipe; Bash does not signal a remembered collector or supervisor PID. Deliberate detachment or `setsid` by trusted user code is not cgroup containment, and detached microphone audio intentionally outlives the initiating request.

| Surface | Enforced limit or behavior |
| --- | --- |
| Configuration | At most 1 MiB before JSON validation; 256 routines and 64 actions per list |
| Resident service file watchers | Notifications only, with preloading disabled and no body-reading calls; content is obtained through bounded runner requests |
| Ordinary action capture | Retains the final 4 KiB of combined output; default 30-second stage timeout |
| Built-in control capture | Rejects more than 1 MiB of combined output; default five-second stage timeout |
| Panel theme-list and fallback service status | Fixed runner probes apply the control deadline and stdout cap before QML collection; stderr is discarded |
| Theme palette files | Opened regular descriptors, nonblocking open, 64 KiB colors and 4 KiB name limits; only validated green/name fields reach QML |
| Toggle discovery | 4096 entries and 512 KiB before JSON construction |
| Condition service | Four manual workers, one condition worker, bounded request queues |
| Explicit delays | At most five minutes per delay |

These limits do not imply a universal deadline for filesystem I/O, an aggregate quota for independently invoked CLI/hook processes, or a sandbox for authored commands. A retained-output limit does not limit all bytes a trusted command produces. Filesystem fingerprinting and open-file inspection use bounded buffers but depend on kernel/filesystem progress. Recovery archives have no global retention quota. The [environment overrides](#environment-overrides) are not privilege boundaries; deployments must not treat a hostile environment as constrained by these defaults.

Production helpers do not honor `OMACHORD_FS_TEST_*` fault, pause, marker or count controls, or the former `OMACHORD_SKIP_HYPR_RELOAD` bypass. Compositor reload and validation still run when required. Deterministic failure tests explicitly create disposable instrumented helper copies; no runtime flag selects that instrumentation in the shipped helpers. Ordinary test calls continue to use production files, and separate production-boundary tests check that inherited test variables cannot alter their behavior.

The palette refreshes after the shell's color-change signal and polls every two seconds while its component is active; inactive components stop polling. Theme listing still invokes the installed Omarchy implementation, whose upstream directory sorting has no separate Omachord memory budget. The wrapper bounds its runtime and what reaches the panel, not the internals of that external executable.

Setter actions change Omarchy state (night light, do-not-disturb, idle inhibition, theme, brightness) through argv-literal calls to Omarchy's own tools, and activation records under the private state directory are validated before they are trusted for a restore. The runner remains the only component that executes anything or writes state; the panel composes configuration and the condition service, which is resident inside `omarchy-shell` while the plugin is enabled, only decides when to call `omachord activate` or `omachord deactivate` with a literal argument list. The bar widget and the panel ask that service to end or start a routine, or to turn the integration on or off; each request becomes one runner call with a literal argument list.

Besides the Hyprland files it already owns, the runner installs its launcher and branded icon under `~/.local/share/applications/` and `~/.local/share/icons/hicolor/scalable/apps/`. It edits `~/.config/omarchy/shell.json` in exactly one case: `omachord widget ensure` moves this plugin's own entry from `plugins[]` into the bar layout on an install upgraded from 0.2.0. The edit is a single atomic rewrite of a parsed document (no other entry is touched), the previous file is kept under the private state directory, and the placement is recorded so it never repeats. Reports that show the runner writing anything else outside its owned files are in scope.

## Filesystem preservation

Private configuration/state/runtime roots and the fixed integration targets above define the managed surface. Managed writes and removals pin verified parent-directory descriptors, use descriptor-relative atomic compare-and-swap operations, and check staged producer failures before publication. Successful publication syncs both the file and its containing directory. Concurrent versions and open or uncertain inodes are preserved, using private state archives where possible and adjacent private archives when inode identity requires it. A newly acquired legacy icon must retain a missing baseline; repair cannot promote a concurrently created unowned icon into owned content. Checked staging writes precede publication and setter effects. Descriptor-relative compare-and-swap, rollback, and durability checks remain required even though routine execution itself is trusted code.

To preserve original inode identity and writes through held descriptors, the helper may create private `.omachord-conflicts` or `.omachord-retired` archives beside managed destinations when central state archives cannot preserve that inode. Transaction failures can also leave private temporary names there. Supported Omarchy/Quickshell discovery excludes the tested archive names; arbitrary recursive third-party consumers are outside that compatibility evidence.

On preservation failure, helper responses retain the surviving locator and distinguish archive-file sync, archive-directory sync, source removal, and source-directory sync progress. A reported path is a recovery location, not a claim that every durability step succeeded. Never replace inode-preserving recovery with unconditional copy-and-unlink, or delete a retained file solely because it is old or no longer open: it may contain unique user changes.

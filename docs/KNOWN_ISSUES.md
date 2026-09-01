# Known Issues and Deferred Design Notes

Items to open as issues once the repository is published. Each records the current behavior, why it is that way, and what a change would involve.

## Configuration lock is held for the duration of a run

`run`, `activate`, and `deactivate` hold the shared configuration lock while actions execute, so a long action (a theme change, a delay) blocks a concurrent `config apply` for that time. This predates the routine work and guarantees a routine never observes a half-applied configuration. A narrower design would release the lock after the routine JSON is resolved and rely on the per-routine lock alone.

## Disconnect ends active routines before its transaction

`disconnect` restores every active routine *before* the file transaction begins, so a rolled-back disconnect leaves routines ended but integration intact. This is deliberate: a routine that could no longer be ended after its dispatcher was removed is the worse outcome. It could move inside the transaction once a snapshot-restore step exists for activation records.

Configuration saves likewise end routines deleted or disabled by the candidate before publishing it. If the later configuration transaction fails, those routines stay ended while the old configuration remains committed.

## Latches after a service restart are reconstructed heuristically

The service keeps in memory which condition routines already fired (or were ended by hand) during the current true period. After a shell restart it rebuilds that set from run history, accepting the latest entry per routine only if it is newer than the routine's most recent time edge (or 24 hours when it has no time condition). A routine whose Wi-Fi or power condition went false and true again within that window, with no entry in between, may be suppressed until the condition goes false once more. Persisting latches in the private state directory would make this exact.

## Stale-save recovery overwrites by design

When a save is rejected because the configuration changed elsewhere, the panel refreshes the list and revision without touching the open draft. Saving again applies that routine draft to the refreshed configuration, preserving unrelated routine changes but deliberately replacing concurrent changes to the same routine. A field-level merge view is out of scope; the run history and `config show` keep previous content recoverable.

## Bar-widget settings have no form in Omarchy 4.0.x

The manifest declares `barWidget.schema` and `barWidget.defaults` for `alwaysShow` and `showName`, but the shell only stores that metadata; nothing renders a settings form and defaults are not merged into the widget's `settings`. The widget reads both keys with `setting(key, fallback)` and users change them with `omarchy bar set anothadev.omachord <key> <value> --json`. The schema stays declared so a future shell that renders it picks the settings up unchanged.

## The bar entry is the plugin's enabled state

For a plugin with a `bar-widget` kind the shell records enablement as the entry in `bar.layout`, so removing the widget from the bar (or `omarchy plugin disable`) also unloads the panel and the condition service. Keeping a second entry in `plugins[]` would let the widget be removed independently, but `omarchy plugin list` would then report the plugin as disabled while its service runs; Omachord follows the shell's model instead and documents `alwaysShow` as the way to keep the icon out of sight.

## Action cards are rebuilt on every edit

The editor replaces its draft with a normalized clone on each structural change, and the action and condition repeaters rebuild their cards from it. Reordering therefore cannot animate, and the editor re-focuses the moved card's button by hand after the rebuild. Diffing into a stable `ListModel` would allow a move transition; no first-party Omarchy panel animates reorders, so this is deferred.

# Releasing Omachord

## Local Gate

Release validation requires Omarchy 4.0.2, Hyprland 0.56.2, Quickshell 0.3.1, and the tools listed in the README.

The manifest declares `panel`, `service`, and `bar-widget` kinds; restart Omarchy Shell after checking out a manifest change or a new QML file so the condition service and the bar widget are loaded before any live check, and confirm them with `omarchy-shell omachord status` and `omachord widget status`.

Review the offscreen renders (`test/render/render.sh`, output under `test/render/out/`) for each view, the compact layout, and the bar popup before tagging; the theme crossfade and the bar widget itself need a live shell.

Run the complete local suite from a clean checkout:

```bash
test/run.sh
```

Validate the exact committed artifact as well as the checkout so untracked files, local symlinks, or omitted files cannot mask packaging errors:

```bash
release_dir=$(mktemp -d)
git archive --format=tar HEAD | tar -xf - -C "$release_dir"
(cd "$release_dir" && test/run.sh)
rm -rf "$release_dir"
```

Review the release diff for credentials, generated state, unexpected binaries, and changes to integration ownership or transaction behavior. A reviewer other than the author should approve the exact commit being tagged.

## Tagging

Create an annotated `v*` tag only after the local gate and review pass, and sign it when a release signing identity is configured. Confirm the tag name is `v$(jq -r .version manifest.json)` before pushing it. Publish release notes that identify supported Omarchy, Hyprland, and Quickshell versions and call out security-relevant behavior changes.

## Repository Rules

After the repository is published, protect the default branch against force-pushes and deletion, require pull-request and CODEOWNERS approval, and require the CI checks. Protect `v*` tags from deletion or unreviewed creation. Enable private vulnerability reporting, secret scanning, and least-privilege GitHub Actions permissions.

Hosted CI may run portable checks, but the local Omarchy/QML suite remains a required release gate until an equivalent reproducible CI environment exists.

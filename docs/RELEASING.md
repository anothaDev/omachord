# Releasing Omachord

## Local Gate

Release validation requires Omarchy 4.0.1, Hyprland 0.56.2, Quickshell 0.3.1, and the tools listed in the README.

The manifest declares both a `panel` and a `service` kind; restart Omarchy Shell after checking out a manifest change so the condition service is loaded before any live check, and confirm it with `omarchy-shell omachord status`.

Run the complete local suite from a clean checkout:

```bash
test/run.sh
```

Validate an extracted copy as well as the checkout so local symlinks or omitted files cannot mask packaging errors:

```bash
release_dir=$(mktemp -d)
tar -cf - . | tar -xf - -C "$release_dir"
omarchy plugin validate "$release_dir"
desktop-file-validate "$release_dir/desktop/anothadev.omachord.desktop"
rm -rf "$release_dir"
```

Review the release diff for credentials, generated state, unexpected binaries, and changes to integration ownership or transaction behavior. A reviewer other than the author should approve the exact commit being tagged.

## Tagging

Create an annotated `v*` tag only after the local gate and review pass, and sign it when a release signing identity is configured. Publish release notes that identify supported Omarchy, Hyprland, and Quickshell versions and call out security-relevant behavior changes.

## Repository Rules

After the repository is published, protect the default branch against force-pushes and deletion, require pull-request and CODEOWNERS approval, and require the CI checks. Protect `v*` tags from deletion or unreviewed creation. Enable private vulnerability reporting, secret scanning, and least-privilege GitHub Actions permissions.

Hosted CI may run portable checks, but the local Omarchy/QML suite remains a required release gate until an equivalent reproducible CI environment exists.

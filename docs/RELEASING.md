# Releasing Omachord

## Local Gate

Release validation requires Omarchy 4.0.2, Hyprland 0.56.2, Quickshell 0.3.1, and the tools listed in the README.

The manifest declares `panel`, `service`, and `bar-widget` kinds; restart Omarchy Shell after checking out a manifest change or a new QML file so the condition service and the bar widget are loaded before any live check, and confirm them with `omarchy-shell omachord status` and `omachord widget status`.

Review the offscreen renders (`test/render/render.sh`, which prints its temporary output directory) for each view, the compact layout, and the bar popup before tagging; the theme crossfade and the bar widget itself need a live shell.

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

Review the release diff for credentials, generated state, unexpected binaries, and changes to integration ownership or transaction behavior. When a second reviewer is available, they should approve the exact commit being tagged.

## Tagging

Create an annotated `v*` tag only after the local gate and review pass, and sign it when a release signing identity is configured. Confirm the tag name is `v$(jq -r .version manifest.json)` before pushing it. Move the `Unreleased` notes in `CHANGELOG.md` under the new version before tagging. Publish release notes that identify supported Omarchy, Hyprland, and Quickshell versions and call out security-relevant behavior changes.

## Marketplace Verification

After pushing the tag, file the marketplace [Plugin verification](https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=verify-plugin.yml) issue form, choosing **Verify and publish a newer upstream commit**, with:

- plugin id `anothadev.omachord`
- repository URL `https://github.com/anothaDev/omachord`
- the full 40-character commit SHA the tag points to, from `git rev-parse "v$(jq -r .version manifest.json)^{commit}"`

The form accepts a newer commit only while it is the repository's current `HEAD`, so tag the default-branch tip and file the request before merging anything else. Once the default branch moves past the verified snapshot, the listing shows **Update unverified** until a newer commit is approved. Verification covers that exact commit only: `omarchy plugin add` and `omarchy plugin update` install the repository's current default branch (upstream `HEAD`) regardless of verification status.

## Repository Rules

The maintainer's current solo-maintainer workflow protects the default branch against force-pushes and deletion and requires a pull request, resolved conversations, an up-to-date branch, and the `portable` check. It requires zero GitHub approvals and permits no bypass. Second-reviewer approval is a separate practice above; the branch rules do not require or certify it.

Before release, record the current controls and any difference from the intended policy. Prospective tag protection, immutable releases, signing identity, CODEOWNERS approvals, and secret-scanning/push-protection settings are maintainer decisions. Do not silently change repository settings, rewrite existing tags, or describe an unenforced control as active. Keep private vulnerability reporting and least-privilege workflow permissions, and use normal PR/CI flow for fixes.

Hosted CI may run portable checks, but the local Omarchy/QML suite remains a required release gate until an equivalent reproducible CI environment exists.

# Distribution and releases

## Current status

The app can now be packaged as a portable ZIP containing `Spleen.app`, a readable optional `Install.command`, license material, installation notes, and build provenance. No optional Codex hooks are installed automatically. Recipients need no Xcode, Git, Python, API key, or companion app. There is no automatic updater.

**No notarized public release is currently available.** Local previews are ad-hoc signed by default and explicitly labeled `preview`; signature verification checks integrity, not an Apple-verified publisher. They can be blocked by Gatekeeper after download. Do not remove quarantine or disable Gatekeeper. A friction-free download still requires a Developer ID Application certificate, an Apple Developer team with notarization access, successful notarization, and validation on a separate Mac. Apple Development or ad-hoc certificates do not satisfy that requirement.

Packages contain only Apple silicon (`arm64`). The app declares macOS 13 as its minimum deployment target, but functional testing has been on macOS 26. Do not advertise verified compatibility with older macOS or Intel based on that declaration alone. Temporary Safari extension support, where included, is separate from app notarization.

For a preview you trust, Apple documents [per-app opening options](https://support.apple.com/en-us/102445); this installer never changes those protections.

## Build a private preview

On an Apple silicon Mac with Xcode 26+ and Python 3:

```sh
./scripts/package.sh --preview
```

This builds fresh source, strips debug symbols, checks the app file allowlist and local-path leaks, verifies its signature, and writes `dist/Spleen-VERSION-macos-arm64-preview.zip` plus a SHA-256 sidecar. `--app /absolute/path/Spleen.app` packages an already built app after the same validation. `BUILD-INFO.txt` records the source commit and whether the checkout was modified; it contains no machine paths. With `--app`, it explicitly marks `prebuilt_app=true` and `source_provenance=packaging-checkout-only`: the commit identifies the packaging checkout and does not prove which source produced that supplied binary. For reproducible public releases, use a clean commit and update both bundle version fields before release.

Set `SPLEEN_BUILD_ROOT`, `SPLEEN_OUTPUT_DIR`, and `SPLEEN_DIST_DIR` to absolute paths to isolate the Swift build cache, app output, and packages. Defaults are `.build`, `build`, and `dist`. Source builds preserve the first available Developer ID or Apple Development identity and fall back to ad-hoc. Set `SPLEEN_SIGN_IDENTITY` to choose a certificate or `-` for ad-hoc. Preview packaging explicitly defaults to ad-hoc unless you choose a certificate. No key file, preference, saved conversation, browsing inventory, live screenshot, source history, or local store is copied into the package. Do not add user state to app resources.

To verify a downloaded archive against its sidecar, in the folder containing both files run `shasum -a 256 -c Spleen-VERSION-macos-arm64-preview.zip.sha256`, using the actual filename. A checksum detects changes relative to that sidecar; it is not publisher authentication. The release build signs the app and preserves its stapled ticket independently of that checksum.

## Produce a notarized release

Use a valid **Developer ID Application** identity and an existing private `notarytool` keychain profile. Store credentials using Apple's documented keychain workflow, not in repository files or shell history. This repository neither supplies nor creates paid credentials.

```sh
export SPLEEN_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
./scripts/package.sh --notarize YOUR_KEYCHAIN_PROFILE
```

If the profile is in a custom keychain, set `SPLEEN_NOTARY_KEYCHAIN` to its path. The build uses hardened runtime and a secure timestamp for certificate signatures. Release mode fails unless the app has Developer ID signing, runtime protection and a timestamp, then submits to Apple, waits, staples the ticket, and requires both ticket validation and Gatekeeper assessment to succeed. It re-extracts the final ZIP and verifies the signature and ticket again. It never silently falls back to preview mode. A rejected submission produces no release ZIP.

Notarization is a network action and may take time. Review Apple's returned diagnostics if it fails; do not relax app security to force acceptance. [Apple's notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) explain signing, hardened runtime, timestamps and tickets.

## GitHub workflow

`.github/workflows/release.yml` runs only when explicitly dispatched. It uses the [macOS 26 Apple silicon runner](https://github.com/actions/runner-images), runs Swift and installer tests, builds a package, and uploads workflow artifacts. Preview is the default and needs no signing secrets. Supplying a version-matching `draft_tag` creates a **draft** release only; previews are also prereleases. The workflow does not publish a public release and does not run from a pull request.

For notarized mode, configure the `release` environment with suitable reviewers and these private GitHub secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded exported Developer ID certificate and private key |
| `DEVELOPER_ID_P12_PASSWORD` | Password protecting that export |
| `RELEASE_KEYCHAIN_PASSWORD` | Password for the temporary CI keychain |
| `DEVELOPER_ID_IDENTITY` | Exact certificate name or fingerprint |
| `NOTARY_APPLE_ID` | Apple account with notarization access |
| `NOTARY_APP_PASSWORD` | App-specific password for that account |
| `APPLE_TEAM_ID` | Developer team identifier |

Signing material is imported into a temporary runner keychain and removed in an always-run cleanup step. Do not put secret values into workflow inputs, source, issues, logs, or release notes. CI signing/notarization remains unverified until these credentials are provided and a real release run succeeds.

Before publishing the draft, download the artifact normally on a separate Mac so Gatekeeper's download checks are exercised. Verify first launch, permission flows, an update from the prior version, and companion handoff. The installer tests use synthetic apps and temporary folders; they do not prove notarization acceptance or compatibility with every OS/provider build.

## Checked installation and recovery

Run `/bin/zsh ./Install.command` from the extracted folder, or use `scripts/install-app.sh --app /path/Spleen.app` in a source checkout. Both default to `~/Applications`; `--destination` or `SPLEEN_INSTALL_DIR` selects another folder you own. The helper uses macOS's built-in tools only and refuses sudo. It preserves download quarantine and never grants permissions, launches/quits apps, installs hooks/extensions, or changes data stores.

The helper stages and validates the replacement, refuses a running destination, locks competing installations, rejects app/destination symlinks, prevents accidental build-number downgrades, and rejects a change from an existing signing team. It checks the destination again immediately before replacement. If the final move fails or receives a normal interrupt, it restores the previous app; if restoration cannot complete it prints the preserved backup path instead of deleting it. A power failure or SIGKILL can leave a `.spleen-install.*` staging folder or `.spleen-install.lock`; inspect these and preserve any `Previous.app` before removing a stale lock. These are application files only, not user data. Finder drag-and-drop does not perform the helper's checks.

An intentional downgrade requires `--allow-downgrade`. It does not reverse any data-format migration, so keep a separate backup of important app data. Ad-hoc builds can change Accessibility grants on each rebuild; stable Developer ID signing is part of release readiness.

Run `python3 scripts/test-install.py` for fresh-install, update, downgrade, quarantine, identity, symlink, tampering, running-destination, lock and rollback checks using synthetic apps. No real app is launched or stopped by that suite.

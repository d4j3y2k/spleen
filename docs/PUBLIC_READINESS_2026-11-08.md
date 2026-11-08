# Independent public-source readiness review — 8 November 2026

**Verdict: ready to share as an experimental source project with the fixes below included.** No remaining blocking source defect was found in the exercised scope. This is not approval of a notarized binary release or a claim of universal provider compatibility. The review covered the intended source changes and new files. The initial review made no commits; the subsequently authorized local preparation is recorded below. Nothing has been pushed or published, and no Git remote is configured.

## Findings and fixes

| Severity | Finding | Resolution and verification |
| --- | --- | --- |
| P1 | Restoring assessment consent and displaying the initial panel could send changed Codex excerpts at app launch, contradicting the documented no-send-at-launch boundary. | Initial presentation explicitly disables assessment. A native regression presents that startup panel with restored consent and an injected transport, verifies zero requests, then verifies a subsequent ordinary opening sends the eligible card. |
| P2 | An app-modal consent dialog took key status from the switcher and dismissed its Settings context. | Owned alerts and key pickers now guard that temporary focus change. Native checks preserve normal focus-loss dismissal afterward. Actual consent cancellation and file-picker cancellation returned to Settings with assessment still off. |
| P2 | Catalog discovery assumed the Desktop app was named `ChatGPT.app` in `/Applications`. | Native clients now locate the running or registered `com.openai.codex` installation and use its bundled helper, retaining the conventional fallback. Fixture checks cover renamed/relocated paths and absent registration. The installed helper returned 26 scoped catalog entries. A physically moved installation was not tested. |
| P2 | The optional hook installer imported `tomllib` immediately and crashed under this Mac's default Python 3.9; the public integration guide lacked fresh-checkout installation commands. | Documented Python 3.11+ for this optional script, added explicit dry-run/install/enable/trust steps, and replaced the missing-module traceback with actionable guidance. Python 3.13 disposable fixtures verified dry-run, repeated installation, preserved hooks/notify/features, and private backups. No real hooks were installed or trusted. |
| P3 | The pin switch's accessible name was its explanatory sentence. | Added an explicit name and hint; the live AX tree now exposes “Pin to your compass” and its on/off value. |
| P3 | The ranking trial document still said the production app never constructed an HTTP transport, despite the separate opt-in assessment paths. | Narrowed the statement to next-chat ranking. Added provider-mark attribution and clarified the MIT license's scope in third-party notices. |

## Reproduction and evidence

Host: Apple silicon, macOS 26.5.2, Xcode 26.6, Swift 6.3.3, macOS SDK 26.5. Installed providers: Claude 4.23118.0 and Codex/ChatGPT 26.1103.41825. App bundle remains 0.2.24.

The initial snapshot copied every tracked and non-ignored untracked intended file into a new temporary directory, including `ProviderGlyph.swift` and both README images. It excluded Git metadata, existing build products, credentials, evidence and local state. Compilation began without a Swift build cache in that directory. Fixes were then synced into the same isolated source tree and the complete script rerun.

| Check | Independent result |
| --- | --- |
| `./scripts/test.sh` on updated snapshot | **254 package tests, 421 native checks; zero failures.** Includes release build and strict signature verification. |
| `./scripts/build.sh` | Passed in snapshot and workspace with the existing Apple Development identity. The original running app was left running; relaunch is needed to use the rebuilt executable. |
| `SPLEEN_SIGN_IDENTITY=- ./scripts/build.sh` | Ad-hoc option verified in the isolated snapshot. It is a development signature, with the documented Accessibility identity limitations. |
| `./scripts/package.sh` | App-only arm64 ZIP and SHA-256 sidecar generated; compressed-data check and strict signature verification of the extracted app passed. No local data or source history in the archive. |
| Native previews | 20 fictional scenarios rendered. Inspected representative light/dark compass, long title, selected recents, empty state, editor, settings, search, and high-contrast render. No material overlap or clipped controls found; settings/search scroll normally. Offscreen renders use the fallback material. |
| Local docs and source hygiene | Local Markdown and image targets resolved, excluding explicitly private `evidence/` links. Executable script modes and MIT license checked. No external Swift package dependencies. Ignore rules cover build products, `.local-state/`, `.env*`, `.swiftpm/` and `evidence/`. |
| Credential and history scan | Working-tree text and reachable history scanned for provider keys, private-key markers, personal paths/email patterns and private-state filenames. Matches were intentional fake credential fixtures and the deliberate private-key marker fixture. Reachable branch history has one import commit; local amended history was also inspected. This is a pattern scan, not a proof that arbitrary secrets cannot exist. |

Apple's `iconutil` failed with “Invalid Iconset” inside the agent sandbox. The same build script succeeded outside it. Likewise, verifying the extracted development signature required leaving the sandbox's restricted trust environment. These were environment restrictions, not ignored build/test failures. No script was weakened to bypass them.

Local scratch evidence, deliberately outside the repository: `/tmp/spleen-independent-final-tests.log`, `/tmp/spleen-independent-workspace-build.log`, `/tmp/spleen-independent-adhoc-build.log`, `/tmp/spleen-independent-package.log`, `/tmp/spleen-independent-fixed-ui-events.jsonl`, and `/tmp/spleen-independent-final-previews/`. These are temporary review artifacts, not dependencies of this record.

## Live behavior and boundaries

- An isolated empty catalog exercised the first-destination UI without private discovery data. Invalid/new-session links stayed editable with an error; a valid fictional destination saved and received search focus. Pin save/reopen and confirmed removal worked. Native fixtures separately cover automatic discovery arriving into an untouched empty panel, frozen selections/search, persistence/migrations, damaged stores, expiry and rejected dispatch recovery.
- The user's original Spleen process already owned the default shortcut. The disposable instance showed an explanatory conflict and remained usable. Saving a different shortcut allowed actual global-key delivery, Escape/reopen, first-character search, compass selection, and Right → Right → Down navigation in recent sessions. Saved destinations, shortcut and recents survived relaunch. Unconfigured ⌘D opened Settings.
- Two existing Claude Code sessions passed **B → A → B → A** through Spleen. Each arrival was checked against Claude's exposed route, including a Return from the recent-session list. The original session was restored. No prompt was sent, task stopped, conversation edited, or provider permission/configuration changed.
- Existing Accessibility permission allowed the read-only Claude selection probe to attach and observe the current Code identity. The status probe produced three fresh `working=true`, `unread=false` samples from actual exposed controls. Reply-age metadata was unavailable in that active session and remained unknown. These probes logged counts/status only.
- The Codex catalog adapter returned 26 entries in the explicitly supplied project scope. Exact Codex external arrival could not be inspected: Computer Use disallows that application. Injected dispatch success is not an arrival assertion.
- Assessment stayed disabled in the disposable UI; cancellation created no consent file. Request bytes, response validation, stale results, cancellation, secret screening, error/backoff behavior, durable request caps and restart behavior were tested with injected transports/fixtures. No real key, private-text transmission, paid request, or new hook trust was used. The published [Decisions guide](https://developers.openai.com/api/docs/guides/decisions) was fetched and matches the endpoint/model/JSON-choice contract; account access, billing and classifier quality were not measured here.

## Remaining limits and sharing actions

1. The authorized local preparation includes the reviewed source, `Sources/Spleen/ProviderGlyph.swift`, fictional preview assets, notices, setup guide and this record. Keep private `evidence/`, credentials and local state excluded when publishing. The original import commit's personal author/committer email was replaced with the account's GitHub noreply identity, and this repository now uses that identity for future commits.
2. Keep the README's experimental label and coverage limits. Positive unread → read transitions, Codex exact arrival/selection on the current build, ordinary Claude Chat arrival, provider cold start/restart, account changes, deleted/archived sessions, and an actually absent provider were not independently exercised live. Related parsers and failure paths have fixture coverage; this does not establish those live cases.
3. Only this Mac and macOS 26 were tested. macOS 13–15 fallback execution, a fresh Mac's Accessibility-grant flow, other displays/Spaces/fullscreen combinations, and sustained real IME/alternate-keyboard use remain unverified. Native tests cover composition/dead-key routing, and source/previews cover accessibility preferences; a full VoiceOver usability pass and system-wide reduced-motion/transparency verification remain outstanding.
4. Source sharing can proceed with those limits. A downloadable app intended for ordinary users needs a separate Developer ID, hardened-runtime/notarization and clean-Mac Gatekeeper verification workflow. The local ZIP is explicitly not notarized; a development or ad-hoc signature does not establish distribution readiness.

## Follow-up privacy and editorial pass

The README now explicitly states that optional assessment excerpts are not anonymized. The assessment documentation identifies the actual outgoing fields, distinguishes manual allowances from the automatic daily cap, and removes obsolete personal development anecdotes and unsupported typical-request claims. A fresh scan of 135 intended public files and reachable/reflog history found only deliberate fake credential and private-key-marker fixtures. No local state, credential file or private evidence artifact is included in that file set. Public local links and `git diff --check` passed. This follow-up changed documentation only; it made no API requests and did not change the previously tested application code.

## Local preparation before publication

At the user's request, preparation proceeded locally without publication. A private temporary recovery backup preserves the prior import history and intended working source. The import commit was amended to replace both author and committer emails with the GitHub noreply identity; its source tree, author name and original author date were preserved. The email setting was changed for this repository only.

The follow-up source commit includes the reviewed application changes, new glyph, public fictional previews, license notices and setup documentation. Ignored state, credentials, private evidence and build products remain excluded. The previously tested application source is unchanged by this preparation. No remote repository was created, no remote was added, and nothing was pushed or published. Older local recovery objects and the private backup are not part of the branch intended for publication.

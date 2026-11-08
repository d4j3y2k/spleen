# Spleen

A small native macOS switcher for getting back to the AI conversation you were in.

Press **Control–Option–Space** and a compass appears over whatever you are doing: the conversation you most likely want to return to in the center, four more around it, and a column of recent sessions on the right. Arrow keys pick one, Return opens it in its own app, Escape puts everything back. Typing searches by title, topic or project.

Spleen treats a **Codex** thread, a **Claude** chat and a **Claude Code** session inside Claude Desktop as the same kind of thing: a destination you can jump to. It keeps a short local memory of where you have been so the center choice is usually right, and it stays out of the way otherwise. There is no chat window, no composer and no model in the loop by default.

> **Status: experimental.** Spleen reads the accessibility trees of two Electron apps to know which conversation is on screen. An update to Claude Desktop or the Codex app can break that overnight. It was built and tested against the app builds current in early November 2026 on macOS 26.

## What it does

- **Compass navigation.** Five fixed positions, so the same key always means the same place. The center starts on the previous distinct conversation, within or across providers, and refines once from local relevance if you have not touched anything yet.
- **Recent sessions.** Press → twice from the center to enter a list of up to 64 sessions from the last 30 days, newest first, independent of pins and ranking.
- **Search.** Start typing from the compass. Exact and prefix title matches first, then topic and project matches, including provider names.
- **Pins and labels.** Pin a conversation to keep it within reach, or give it a label that is easier to recognize than its generated title.
- **Live indicators.** A green **Working** pill with a spinner and a green stripe make active Codex and Claude Code conversations stand out across the compass, recent sessions, and search. A dot marks an unread reply, and **Last reply** shows its time where known.
- **Dot.** One fixed shortcut, ⌘D, that opens a conversation you nominate in Settings, outside of ranking.
- **Native look.** An AppKit non-activating panel hosting SwiftUI, Liquid Glass on macOS 26 with a standard material fallback, light and dark palettes, and respect for reduced motion, reduced transparency and increased contrast.

## How it knows where you are

Spleen combines several sources, all local:

| Source | What it provides | Requires |
| --- | --- | --- |
| Its own dispatches | Which conversation you opened through Spleen | Nothing |
| Codex app-server metadata | Thread titles, projects, short recent excerpts | The Codex desktop app |
| Codex lifecycle hooks (optional) | Working and completed-turn times | Reviewing and trusting the hooks in Codex |
| Claude Desktop observation (optional) | Which Claude chat or Code session is in front, and its last-reply age | macOS Accessibility permission |

Observation never reads message text, screenshots or the clipboard. The observers read window metadata and the sidebar's current-row marker, and the diagnostic probes print counts only. See [docs/CONTEXT_CONTRACT.md](docs/CONTEXT_CONTRACT.md) for exactly what is recorded and for how long.

## Requirements

- An Apple silicon Mac. macOS 26 for the glass panel; the app runs on macOS 13 and later with the fallback material.
- Xcode with the macOS toolchain. There are no third-party dependencies.
- The Codex desktop app, Claude Desktop, or both.

## Build and run

```sh
git clone <this repository> spleen
cd spleen
./scripts/build.sh
./scripts/run.sh
```

`build.sh` produces `build/Spleen.app` and signs it with the first Developer ID or Apple Development identity in your keychain, falling back to an ad-hoc signature. A stable identity matters: macOS ties the Accessibility grant to the code signature, and an ad-hoc signature changes on every build, which silently revokes the grant. Set `SPLEEN_SIGN_IDENTITY` to choose a certificate, or to `-` for ad-hoc on purpose.

`run.sh` launches the app with its data in `.local-state/` inside the checkout. Launching the `.app` directly uses `~/Library/Application Support/Spleen/`. Quit before switching between the two.

To check everything:

```sh
./scripts/test.sh
```

That runs the Swift package tests, rebuilds the app and runs its native self-test, which exercises the real panel, key handling, store migrations and dispatch paths with injected fixtures.

## Setting up observation

Spleen works with no permissions at all. Saved and discovered conversations are searchable, and anything you open through Spleen is remembered. The two observers are opt-in:

1. Open **Settings** from Spleen's menu bar item.
2. Turn on **Remember visited Claude Desktop sessions** and, if you use Codex, **Remember visited Codex Desktop sessions**.
3. Press **Save settings**. macOS asks for Accessibility access the first time; allow it for Spleen.

The Claude card in Settings reports what the observer is doing. "Claude Code selection observed" means it is working. If it says to allow Spleen in Accessibility after a rebuild, the signature changed: remove Spleen from System Settings → Privacy & Security → Accessibility, add `build/Spleen.app` again, and save settings once more.

For Codex working and reply indicators, see [integrations/codex](integrations/codex/README.md). The hooks are metadata only, are installed through Codex's own hook review, and are never enabled by Spleen itself.

## Privacy and local storage

Everything lives in a handful of JSON files in the data directory:

- `destinations.json`: saved labels, targets, pins, shortcut and the Dot link.
- `catalog.json` and `relevance.json`: Codex thread metadata and short excerpts, at most three 280-character fields per thread.
- `context.json`: at most 64 recent navigation events, kept for 30 days.
- `claude-reply-times.json`: observed reply ages, also expiring after 30 days.

Full transcripts, tool output, reasoning, screen contents and clipboard are never stored. Turning off recent selections in Settings clears the navigation memory and pauses observation. The shipping app constructs no network transport; the optional model-assessment path described in [docs/DECISIONS_TRIAL.md](docs/DECISIONS_TRIAL.md) is off by default and requires an explicitly supplied credential file for every request.

## Project layout

- `Sources/SpleenCore`: identity, catalog, relevance, context memory, ranking. Pure Swift with no AppKit dependency, exercised by the package tests.
- `Sources/Spleen`: the AppKit and SwiftUI app, observers, panel controller, CLI diagnostics and the native self-test.
- `Sources/SpleenEvaluation` and `Sources/SpleenReplay`: a headless replay harness for ranking changes against scripted scenarios.
- `integrations/codex`: example hook definitions and the installer for optional Codex reports.
- `docs/`: design notes and verification records, indexed in [docs/README.md](docs/README.md).

If you fork this and change the bundle identifier in `Resources/Info.plist`, expect to grant Accessibility access again: the grant belongs to the identifier and signature together.

## License

[MIT](LICENSE).

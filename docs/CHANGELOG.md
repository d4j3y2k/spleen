# Development log

This is the original working README, kept as a release-by-release record of what was built and verified. Links into `evidence/` refer to a local, untracked folder of logs and probe output. For an introduction to the app, read the [top-level README](../README.md).

---

Claude and newly created sessions (0.2.23): Recent sessions now includes Codex chats created directly in Codex, using the provider’s **Created** timestamp until a later selection or visit. Session-start and prompt hooks refresh discovery for unknown chats before their first reply finishes. Older Claude visits retained only in interaction history are recovered during loading, including stores affected by the previous migration. Background replies still do not reorder the list; clear/disable controls also suppress creation history. 248 package tests and 401 native checks passed. The running app was reloaded and both this new Codex chat and a retained Claude visit were verified in the list. Spleen’s macOS Accessibility grant has now been restored with user approval, and the running observer reports ready; a new physical foreground visit has not yet been verified. [Verification](docs/DETERMINISTIC_NAVIGATION.md#claude-history-recovery-and-new-sessions--0223).

Reply and selection times (0.2.22): compass cards and recent-session rows now show **Last reply** above **Last selected** or **Last visited**, when a reply timestamp is available. Search and the selected preview show both inline. Navigation mode previously hid cached reply times. Recent sessions still sort by navigation, and missing reply timestamps remain unknown.

Main compass correction (0.2.21): this installation now uses recorded navigation for its main cards as well as the recent list. Historical task text no longer selects the compass cards. Direct Codex capture remains subject to the documented verification limit.

Navigation history (0.2.20): local deterministic recent sessions now retain observed visits independently of background activity, support Claude Chat and Code, and include a fail-closed Codex exact-selection adapter. See [coverage and verification limits](docs/DETERMINISTIC_NAVIGATION.md). No automatic transcript requests are enabled by this feature.

> Decisions update (November 7): Settings now supports a reviewed one-request assessment and an opt-in **assessment on open**: each shortcut press assesses only the Codex cards on screen whose text changed, up to 100 requests a day. It is off until enabled, caches results by content version, never delays opening, and offers Pause. "Appears finished" needs at least 70% probability. Local Codex only; Claude text assessment is not yet supported. See [session attention](docs/SESSION_ATTENTION_IMPLEMENTATION.md).

> Update: [Live indicator adapters are now installed](docs/LIVE_INDICATORS.md). Desktop unread polling is running; trusted lifecycle hooks are delivering real callbacks. See the update for verification and remaining coverage limits.

# Spleen

A small native macOS switcher for returning to conversations. Current local build: **0.2.19, 6 November 2026**.

The compass now has a **Recent sessions** column on its right. From the center, press **→ twice** to enter it, **↑/↓** to browse, **←** to return to the compass, and **Space or Enter** to open the selected session. The list scrolls with keyboard selection and updates the existing preview. It keeps up to 64 distinct sessions from the last 30 days, newest recorded selection or observed visit first, independently of pins, suggestion ranking, and background replies. Its order stays fixed while browsing; accepted opens appear first on immediate reopening. Clearing or disabling recent history also clears this list. Direct switches inside Codex are still not observed as visits.

Recent-sessions verification: **213 package tests and 378 native checks passed**, along with release build and strict signature verification. Eighteen synthetic previews cover light/dark appearances and recent-list selection. The running app was restarted with its existing development store; the 39-session live list was checked for two-Right entry, down-arrow scrolling, preview updates, and return to the compass. External session dispatch was covered by injected native tests, not repeated live. [Package tests](evidence/recent-sessions-tests.txt) · [Native checks](evidence/recent-sessions-native-tests.txt) · [Selected recent-session preview](evidence/recent-sessions-previews/native-fixture-compass-recents-dark@2x.png).

The switcher now has a unified native panel with coordinated light and dark palettes, a clear teal selection, compact provider marks, and contextual keyboard hints. The compass keeps its fixed spatial choices while giving conversation titles more room. Search uses compact rows and a dedicated field; settings are grouped by shortcut, history, and provider, and the conversation editor has labeled fields. Hover and pressed feedback do not change selection. Reduced motion, reduced transparency, and increased contrast preferences are respected by the new shared styling.

Verified in 0.2.18: 197 package tests and 331 native checks pass; the release build and strict signature verification pass. Sixteen synthetic native previews cover both appearances, Codex/Claude selection, long titles, empty compass/search, search, settings, and the editor. The running app was restarted with its existing development store; live arrow selection, first-key search, settings navigation/scrolling, and reopening were checked. External conversation dispatch was not repeated. The rebuilt app currently reports that its macOS Accessibility approval needs refreshing for fresh Claude observation; existing cached destinations remain available. Logs: [build](evidence/ui-build.txt), [package tests](evidence/ui-core-tests.txt), [native checks](evidence/ui-native-tests.txt), [preview list](evidence/ui-preview.txt). [Dark compass preview](evidence/ui-previews/native-fixture-compass-dark@2x.png) · [Light search preview](evidence/ui-previews/native-fixture-search-light@2x.png).

Claude Code cards, search rows and previews now show **Last reply ≈12m ago** once the displayed session's latest assistant footer has been observed. Claude supplies a rounded relative age, so the tooltip explains its approximate precision and coverage. Older selected-message timestamps and background-task timers are ignored. These local reply times survive restarts, expire after 30 days, and are cleared with recent history. A reply time does not imply that background work has finished. Until a reply time is available, the card keeps its selection/visit fallback.

Verified in 0.2.17: 197 package tests and 331 native checks pass; release build and strict signature verification pass. The live bounded adapter reads the existing Claude Code reply footer while independently preserving its running background-task indicator (390 nodes, within budget). After the user-authorized Accessibility approval refresh, the running picker and selected preview both displayed **Last reply ≈3m ago** for a real Claude session. The original Claude chat was restored afterward. Logs: [package tests](evidence/claude-reply-core-tests.txt), [native checks](evidence/claude-reply-native-tests.txt), [live adapter](evidence/claude-reply-status-probe.txt), [release build](evidence/claude-reply-release.txt).

Opening now starts with the previous distinct conversation immediately, within or across providers. Accepted navigation prepares that return choice synchronously, so rapid reopening does not wait for background ranking or repeat the conversation just opened. Ranking may refine an untouched initial compass once, including when a prepared ranking is already available. Arrow/focus navigation, typing, management or dismissal ends that refinement window; later changes wait for another opening. In-flight context-file reads cannot overwrite newer local selections. The opening path copies cached choices and performs no catalog scan, disk read or ranking.

Verified in 0.2.16: 188 package tests, 324 native checks, release build and strict signature verification. New fixtures hold ranking and context reads in flight while dispatching/reopening repeatedly, verify one untouched refinement, and preserve navigation/search once used. After restarting with the existing development store, the live picker was exercised in both directions between two existing Codex chats: each reopening centered the conversation just left. External destination arrival was not independently inspected. Logs: [release build](evidence/immediate-return-release.txt), [package tests](evidence/immediate-return-core-tests.txt), [native checks](evidence/immediate-return-native-tests.txt).

The previous distinct conversation now has a stronger return preference, within or across providers. Among recent candidates it receives a ten-minute comparison advantage; the fallback relevance bonus is doubled from 12 to 24. Fresh working, unread, approval or input signals still take precedence, and substantially newer activity can win. Actual visit times and the 30-minute eligibility window remain unchanged. This uses recorded Spleen selections and observed Claude visits; switches made directly inside Codex are not observed as visits.

Verified in 0.2.15: 188 package tests, 294 native checks, release build and strict signature verification. Return-preference regressions cover all four provider-switch combinations, newer-activity/live-status overrides, pins, search and prepared-versus-rebuilt ordering at expiry. The updated picker was opened after restarting with the existing development store; real cross-app navigation was not exercised in this check.

The compass now shows a selected-conversation preview with its title, project/reason metadata, and an available cached Codex excerpt. Arrow or Tab selection updates the preview without fetching content or moving the choices. Claude cards carry a subtle orange tint in both the compass and search; selection retains a distinct outline. Claude message excerpts are unavailable; its integration reads session metadata and native status controls only.

Codex cards, search rows, and the selected preview show **Last reply 2m ago** when a completed-turn timestamp is available; its tooltip gives the exact local date/time. Cached turn start and last successful completion times stay separate from catalog update and visit timestamps. Older excerpts are upgraded in bounded background batches, prioritizing the current and suggested chats. Missing timestamps remain undisplayed. These historical facts do not claim live running state or that a response still requires attention.

The center and nearby choices prioritize distinct sessions with a recorded Spleen selection or observed Claude visit within the last 30 minutes. Multiple recently used Claude sessions can appear together. Pins keep their nearby places, and older activity/topic choices fill remaining space. Selection time is independent of foreground visit time and cannot discover a Claude target by itself. Claude cards fall back to **Last selected** or **Last visited**, with an exact-time tooltip, when reply metadata is unavailable. An older Claude visit may still supply an alternative when no recent working choices fill the panel. Provider names (`Claude`, `Claude Code`, `Codex`) remain searchable.

The newest observed Claude session remains eligible for a nearby choice even when it is the last-observed selection; that observation does not prove the user is still viewing it. This also applies when an older Claude pin is already visible. Discovery requires Spleen's own Accessibility approval for the current app build; the running Settings status is authoritative, rather than a helper launched through another permitted app.

**Control–Option–Space** opens a prepared compass immediately. The center starts selected; arrows choose a fixed neighboring destination; **→ twice** enters the recent-sessions list on the right. **Space or Enter** opens the selection; **Escape** cancels. Typing switches to local search. The menu bar provides Open Dot, Search, Add conversation, and Settings.

**Dot is a fixed shortcut in Spleen:** click **Dot** in the compass/search header, press **⌘D** while Spleen is open, or choose **Open Dot** from its menu bar. Save your Dot’s copied chat link in Settings → Dot. Cloud links retain their `hostId`; the shortcut stays outside local conversation ranking and recents. An unconfigured shortcut opens Settings, and a rejected open displays an error without discarding the link.

```sh
cd spleen
./scripts/run.sh
```

## What works

- Native AppKit/SwiftUI compass with system materials and a center plus up to four alternatives. The center starts with the previous conversation and may receive one untouched-opening refinement combining attention, history, topic/project relevance and recency. Pins stay nearby without automatically claiming the ranked center; a pin can still win on relevance. The last known selection remains searchable and follows alternatives. Pins and saved labels are preserved. After initial refinement or user interaction, choices and typed search stay fixed; completed refreshes apply on another opening or explicitly from search. An empty untouched invocation fills when its first discovered choices arrive.
- Cached title/topic/project search. Exact, prefix, and substring title matches precede topic/project matches. Opening directly copies prepared choices and selects the center, with no search, selection scan, model, disk read, catalog merge, or process launch. Superseded background builds retain only the latest pending work. Rapid reopen clears stale text composition/focus before the first compass key.
- Automatic local Codex project discovery, bounded to 1,000 chats / ten pages / ten seconds / 4 MB per session. A live counts-only check found **541 chats across 108 projects**, without truncation. Cached metadata stays ready for five minutes by default, with failed attempts throttled; manual refresh bypasses the wait. Existing folder-scoped stores retain their scope; Settings → **Discover Codex projects automatically** enables the broader mode once. Fresh stores default to automatic discovery.
- Bounded background Codex excerpts: at most eight changed chats and three recent summary turns per refresh. The app-server validates metadata before reads. No resume, new turn, or transcript mutation is used.
- Provider-qualified saved destinations: Codex, ordinary Claude Chat, and Claude Desktop Code remain distinct even with the same UUID suffix. Ordinary Chat uses the documented `claude://claude.ai/chat/<UUID>` route. Experimental Desktop Code uses the separately tested `claude://claude.ai/epitaxy/local_<UUID>` route.
- Bounded local context memory distinguishes observed selection, Spleen dispatch intent, inferred interaction, and background lifecycle activity. Current hints expire after 30 minutes, including sleep or clock adjustments, through a precomputed fallback. At most 64 metadata events/interactions are retained for 30 days. Recent-selection controls clear/disable that memory too. Lifecycle-only bursts do not rebuild the index.
- Opt-in Claude Desktop observation uses foreground URL/title events to remember visits. A separate bounded status reader checks the currently displayed Code session every two seconds, including while Claude is in the background. Enabled response/background-task controls and its verified Running marker drive the spinner; Unread response drives the blue dot. Working controls are anchored to the open route; sidebar read state additionally requires a current-page marker. Titles alone never identify a session. Neither reader reads messages, screenshots or the clipboard. Spleen needs its own Accessibility approval and never requests it on startup. [Coverage and verification](docs/LIVE_INDICATORS.md#claude-desktop-code).
- Installed Codex lifecycle hooks report working/completion metadata, and Desktop unread polling supplies read markers. The helper discards prompt/transcript fields and cannot label agent activity as foreground attention. Hooks have completed normal Codex review/trust. [Coverage and limits](docs/LIVE_INDICATORS.md).

**Claude Desktop Code now has experimental switch targets.** External B → A → B → A → B dispatch selected the original identities of two existing interactive sessions (local and SSH-backed) on Claude 4.16336.0, without visible duplication. Copy link was unavailable in the tested menus, so the URIs were constructed from observed identities using the reported route; this is live-tested behavior, not an official API guarantee. With the existing observation opt-in enabled, recently visited Code sessions become searchable compass candidates. The list uses bounded local context memory, preserves saved labels/pins, and is not a complete Claude catalog. Observation is now enabled in the current user's saved settings. [Evidence, limits, and retest recipe](docs/CLAUDE_DESKTOP_FEASIBILITY.md).

## Context and Decisions

Local ranking uses the last known interaction or observed topic, same-project evidence, shared topic terms, and recency. An external Claude topic can influence Codex suggestions without inventing a navigable Claude candidate. Background completion does not mean the user is viewing that conversation.

The five compass choices also retain the most recently updated catalog alternative, favoring another project when project context is known. If it would otherwise fall below the five visible choices, it takes the fifth position with a **Latest activity** label. The center and pins keep their places. This prevents older topic matches from occupying every choice; update timestamps indicate thread activity, not foreground attention.

The optional Decisions adapter now accepts provider-aware aliases, short approved notes, context evidence, and transition counts. Response validation, 750 ms deadlines, stale-generation rejection, 120-second expiry, request caps, cancellation, and local fallback are implemented. Payload encoding and response parsing run on utility queues. A unique chosen probability winner may be promoted; all other candidates keep their local order. Ties, disagreement, an unchanged winner, and none preserve the baseline. Unicode-aware compaction fits the 6,000-byte cap, prioritizing labels and provenance over optional prose. Mock transport checks prove a completed prediction affects only a later opening, and 100 cached opens/searches cause no additional requests.

**The shipping app constructs no remote transport. No paid inference request was made.** A durable request ledger now enforces a finite trial allowance across restarts, deduplicates payload hashes, and reserves before HTTP. A real trial still needs explicit data choices, supported credentials, and spend authorization; a request cap is not a dollar guarantee. [Trial status](docs/DECISIONS_TRIAL.md).

## Offline evaluation pre-work

`./scripts/replay.sh` runs a separate, headless evaluation tool with built-in synthetic scenarios. It uses Spleen's actual local ranking and prediction state machine with scripted responses and virtual time. It reports coverage, center/top-three/compass hits, paired wins/losses, and prediction availability at opening. The default 16-case suite covers 18 openings, including wrong, late, missing, stale and expired predictions. Synthetic scores are not evidence of model quality or API speed.

```sh
./scripts/replay.sh --synthetic --output "$PWD/evidence/replay"
./scripts/replay.sh --fixture "$PWD/fixtures/replay/synthetic.json" --json
```

An explicit `--export-requests DIRECTORY` writes exact pre-choice request examples plus a SHA-256 manifest for local review. Reports contain numeric indices, counts and statuses; request exports can contain the supplied titles/topics/notes. The tool reads only an explicitly provided fixture (or built-in synthetic data), and has no credential setup, provider access, network requests or chat dispatch. [Data contract and evaluation rules](docs/DECISIONS_TRIAL.md#offline-replay).

## Local storage

`run.sh` uses `.local-state/`; direct `.app` launch uses `~/Library/Application Support/Spleen/` unless `--data-dir` is supplied. Quit before switching stores.

- `destinations.json`: saved labels, targets, pins, shortcut, selection timestamps, and an optional `dotLink`. Legacy Codex entries decode unchanged; ordinary Claude Chat uses schema v2 and Desktop Code uses v3 so older builds reject newer stores safely.
- `catalog.json`: metadata, discovery scope/policy, exclusions, refresh time.
- `relevance.json`: short local excerpts, at most three 280-character fields per chat.
- `context.json`: bounded context metadata and short observed topics; interprocess locking and atomic replacement prevent cooperating writers losing updates.
- `context-settings.json`: explicit Claude observation preference, off by default.

Folder removal and hidden chats prune local excerpts; saved targets survive provider absence. Full transcripts, tool outputs, reasoning, query history, screen recordings, and clipboard contents are not retained. Corrupt stores are preserved. Turning off recent selections clears selection/context memory and pauses observation.

## Verification

```sh
./scripts/build.sh
./scripts/test.sh
./build/Spleen.app/Contents/MacOS/Spleen --relevance-check --catalog-folder "$PWD"
./build/Spleen.app/Contents/MacOS/Spleen --discovery-check
./build/Spleen.app/Contents/MacOS/Spleen --context-check --data-dir "$PWD/.local-state"
./build/Spleen.app/Contents/MacOS/Spleen --claude-context-check
./build/Spleen.app/Contents/MacOS/Spleen --render-preview "$PWD/evidence/native-previews"
```

**Passed in 0.2.7:** 101 core tests, 10 replay tests, 258 native app checks, release build, and strict ad-hoc signature verification. New cases cover strict Desktop Code routes/schema migration, observed-only candidates, duplicate-title identity, restart, saved overrides, hides/restores, clear/disable, attention versus retention expiry, lifecycle exclusion, frozen compass/search, and dispatch after a newer prepared index removed the chosen session. Existing cross-project activity/center/pin regressions still pass. Native tests inject external dispatch; a separate isolated live Spleen compass test used the real `NSWorkspace` opener and confirmed exact local and SSH Code identities in both directions. It used restored observation fixtures, not a new live observer attachment. The running app was upgraded using the same store; saved destinations remained byte-identical and persistent Claude observation stayed off. [Evidence](evidence/claude-code-navigation-2026-11-04.json).

**Measured:** release app-model preparation with 1,000 synthetic entries: p95 **0.007 ms**; search: p95 **1.914 ms** (100 samples). These measure computation, not compositor, physical-hotkey, or destination-arrival latency. A physical shortcut was previously captured live: its handler-to-key-panel presentation took 3.969 ms, excluding hardware input and compositor latency. Earlier live arrows, first-key search, and Escape/focus restoration also passed.

`./scripts/package.sh` builds an app-only local ZIP plus SHA-256 checksum in `dist/`. It excludes saved state, source history, and extended file attributes. The archive is ad-hoc signed, not notarized or published. Read-only catalog/relevance checks require explicit `--catalog-folder` arguments; `scripts/probe-catalog.py --folder "$PWD"` delegates to the compiled counts-only checker.

Requires the installed Xcode macOS toolchain. No downloaded dependencies. The arm64 app is ad-hoc signed for local development. Native checks need a normal desktop session. The live setup uses trusted Codex hooks; no extensions or launch agents are needed. Claude observation remains opt-in; a successful permission check alone is not proof of live observation.

[Implementation and evidence](docs/IMPLEMENTATION.md) · [Context contract](docs/CONTEXT_CONTRACT.md) · [Architecture](docs/ARCHITECTURE.md) · [Product brief](docs/PRODUCT.md)

[Short live check for the next unlocked session](docs/LIVE_CHECK.md). Native preview rendering uses only synthetic data and hidden app-owned views; it does not capture the desktop or prove live focus/arrival.


### Session attention (5 November 2026)

The app now retains bounded chronological recent-message windows, recognizes unanswered input as ongoing, and has a cached Decisions assessment path with stale-result rejection. Ongoing/waiting work receives priority; a valid appears-finished assessment is softly demoted and remains searchable. Hard exclusion is disabled pending real classifier validation and a reliable read/runtime source. Saved labels, pins, preferences and frozen compass positions are preserved.

Blue unread dots and working spinners now have connected Codex sources: Desktop unread polling and trusted lifecycle callbacks. Working evidence expires after 15 seconds without a fresh callback; approval/input coverage remains limited. Fresh working or unread status keeps a last-selected chat eligible for the five-choice compass, because a Spleen dispatch does not prove the user is still viewing it. Badge updates preserve the open picker's positions; refreshed choices apply on reopening. [Live integration and verification](docs/LIVE_INDICATORS.md). Dot navigation is now available through the configured shortcut described above.

Normal launch still sends zero model requests. A local exact-payload exporter and finite two-request trial are available; transmission requires approval and an explicitly supplied credential file. See [Session attention implementation](docs/SESSION_ATTENTION_IMPLEMENTATION.md) for behavior, limits, verification and activation.

Claude Code indicators are also connected in 0.2.12: live working was verified on the running SSH-backed session, and native unread → read changes were verified on a completed session. Coverage is the Code session currently displayed in Claude, even while another app is in front; other Claude sessions and ordinary Chat do not yet have live indicators. All 177 package tests and 290 native checks pass.

Version 0.2.13 fixes missing Claude spinners when its sidebar marker is absent or its main reply has ended while a background task is still running. The live task-control signal and drawn picker spinner were verified; 182 package tests and 291 native checks pass.

Version 0.2.14 keeps recently selected or recently active work ahead of older inferred unfinished chats. Real Codex hook timestamps supply up to 30 minutes of ranking history, independently of the 15-second working badge. This prevents long silent model/tool calls from dropping a recent chat out of the compass. Pins and fixed positions during an invocation remain unchanged. The disappearing the running Codex chat case was reproduced in a regression before the fix.

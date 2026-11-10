# Deterministic navigation history

The recent-sessions list is ordered by session creation timestamps, actual observed foreground selections and explicit Spleen dispatches. Creation is labelled **Created** and does not establish a foreground visit or current selection. Replies, lifecycle hooks, generated titles, status badges and model assessments do not count as navigation. Dispatch is labelled selection rather than a verified arrival.

## Persistence and speed

A separate bounded selection record survives a busy lifecycle audit and same-session dispatches. It retains up to 64 distinct observed identities for 30 days, with backward-compatible decoding of existing context stores. Clear history and disabling recents clear the selection record too. The prepared recent list has no runtime reads or requests on its opening path. Saved names take priority; hidden Codex sessions stay hidden.

## Claude

The opt-in observer now discovers ordinary Chat as well as Desktop Code sessions. Exact foreground routes identify sessions; identical UUID suffixes in the two surfaces do not alias. Native focus events are supplemented by a coalesced 500 ms foreground-only metadata sample because Electron route changes sometimes omit focus notifications. Title updates do not create visits. Activation generations and newer reads reject stale deliveries. No message bodies, screenshots or input actions are used.

## Codex

The installed app is ChatGPT.app, bundle com.openai.codex. The packaged renderer's local route and host rules were verified from its shipped code. Exact local thread routes are parsed; remote/unknown hosts, bootstrap URLs and malformed IDs fail closed. The observer checks the focused foreground app and only records a verified identity.

The renderer uses an in-memory router, so window URLs alone are not a reliable current-thread signal. The local passive probe had existing Accessibility trust and successful observer registration but no exposed renderer web area. No direct-navigation claim can be made from that probe. The adapter must remain unavailable when current selection metadata is absent. No title matching or read-time inference is used as a substitute.

Runtime working/waiting/read evidence remains independent. No Decisions calls or automatic transcript transmission are needed or enabled for navigation. User settings control each app observer; no Accessibility prompt is shown at startup.

## Verification and deployment

234 package tests and 382 native checks passed on 7 November 2026. Synthetic regressions cover host validation, stale/overtaken observations, duplicate titles, ordinary Chat/Code namespace separation, audit pressure, persistence, clear/disable, hidden sessions, sidebar ambiguity and scan limits. Prepared opening p95 was 0.005 ms for 1,000 synthetic sessions; this measures cached computation, not screen rendering.

The signed 0.2.20 build was gracefully reloaded with `--background-launch`, preserving all 39 saved destinations byte-for-byte. Both local observers are enabled; automatic API assessment remains unconfigured. Exact running executable inode was verified against the signed build.

The current real Codex direct-switch path is **not yet verified**: earlier passive probes saw no exposed web area, and the final adapter probe occurred while Codex was not foreground. The sidebar fallback requires an explicit current-page link with an exact local route. Spleen will not replace missing evidence with guessed visits. No forced app navigation or computer-control session was used for testing.

## Main compass correction — 0.2.21

The user's screenshot exposed an integration mistake: deterministic history was only in the right-hand recent list. The main compass still used the older relevance/unfinished-text ranking, allowing an unpinned 26-day-old chat and untitled catalog entries to occupy its arms. No pinned choices explained those entries.

The new `navigationFirstCompass` preference is enabled in this installation. Main compass candidates now come from NavigationCompass's recorded visits/selections, with a fresh current selection deferred for quick return and explicit pins appended afterward. It never fills unused slots with unvisited catalog guesses. Cards show selection/visit time. Catalog search remains separate. Legacy relevance mode remains available as a compatibility preference; it is not active here.

239 package tests and 388 native checks passed, including a native regression for old catalog entries crowding out true selections older than 30 minutes, full search, provenance labels, and clearing history. The signed build was reloaded in the background; all 40 saved destinations were preserved byte-for-byte.

This fixes the incorrect ranking path, not the missing direct Codex observations. At deployment the two newest recorded selections were minutes old, followed by 10–11-hour-old selections. No observed Codex navigation events had been captured. Do not describe the remaining capture gap as solved or fill it with inferred activity.

## Accessibility exposure recovery

The Codex observer now reports raw accessibility-exposure error codes and retries only communication failures (`cannotComplete`/`failure`) with bounded backoff. It makes at most four requests per process, including across foreground transitions, with a separate 500 ms background messaging timeout. Success or an unsupported/error outcome stops further requests. This follows Electron's documented AXManualAccessibility mechanism; no OS trust prompt or remote control is used.

242 package tests and 388 native checks passed. The signed build was reloaded in the background. A passive follow-up found Codex was not foreground, so direct navigation is still not live-verified. Earlier diagnostics showed exposure failed but did not retain the error code; the new diagnostics distinguish initialization failures from unsupported attributes.

## Exposure blocker diagnosed

Signed diagnostic on November 7: Codex advertises `AXEnhancedUserInterface` as writable but its setter returns `kAXErrorNotImplemented` (-25208). `AXManualAccessibility` reads as unsupported (-25205). No exposure change succeeded. Thus bounded retries do not repair this specific installed-build limitation. A documented Chromium launch-time `--force-renderer-accessibility` experiment is a possible next test, but has not been attempted and would require a coordinated Codex relaunch. Private renderer IPC does contain selected-conversation notifications, but no supported external subscription has been established.

## Reply and navigation timestamps — 0.2.22

Navigation mode previously replaced the available reply timestamp with selection/visit time, and the recent list displayed only its ordering timestamp. Cards and recent rows now show both on separate lines, with **Last reply** first; search and the selected preview show both inline. Each retains its source-specific tooltip and accessibility label. Unknown reply times remain absent, and Claude's observed reply ages retain their approximate marker. The list order still comes exclusively from navigation. All timestamps use existing prepared caches; opening and selection add no provider requests.

243 package tests and 394 native checks passed. Regression coverage includes deterministic mode, recent entries outside the compass, missing/future reply timestamps, Claude approximate reply ages, and navigation order independent of newer replies. Light/dark native previews were inspected, including long titles with both timestamps. The signed build was reloaded with the existing store. A live UI read confirmed both timestamps on real compass cards and recent rows, including “Last reply 18h ago” alongside “Last selected 3h ago.” Saved destinations and observation settings remained byte-identical across the reload. Evidence: `evidence/reply-selection-tests.txt`, `evidence/reply-selection-native-tests.txt`, `evidence/reply-selection-build.txt`, and `evidence/reply-selection-previews/`.

## Claude history recovery and new sessions — 0.2.23

The missing Claude entries exposed a migration bug: the new selection record was seeded only from the bounded event log, even when an older observed visit survived in the interaction history. Loading now merges validated observations from all three records, keeps the newest observation per identity and its latest nonempty title, and bounds the result to 64. This also repairs an already persisted empty selection record. Dispatches and background activity do not invent observed Claude identities, and clearing history still removes every source of recoverable visits.

New Codex chats were present in the catalog but absent from recents until Spleen recorded navigation to them. The catalog now retains the app-server’s optional `createdAt` field (verified in the installed CLI’s generated Thread schema). Eligible creations join the same chronological list and compass with **Created** labels. A later explicit selection or visit takes precedence; updated/reply timestamps do not. Creation does not identify the current chat. Missing, future, expired, hidden and excluded creation records are suppressed. A persisted clear-history cutoff prevents catalog refresh from resurrecting cleared creations; switching history off and back on resets that cutoff too.

SessionStart and UserPromptSubmit hook events request a catalog refresh for an unknown thread, without recording the hook as navigation. Existing refresh and frozen-picker behavior remain: new metadata becomes available on the next opening, and a completion is not required to discover a new session.

248 package tests and 401 native checks passed, including real helper journal/watch integration for session-start discovery, creation labels, frozen lists, clear-history persistence, legacy catalog decoding and Claude migration repair. Release build and strict signature verification passed. The signed app was reloaded with the existing local store; saved destinations and observation preferences were byte-identical. The live list showed the current Claude Code chat with **Created**, plus a retained Claude entry with **Last visited**, in a bounded 64-session list. With the user’s subsequent approval, the stale Spleen Accessibility entry was replaced with the current app bundle. Re-saving the existing Spleen settings changed the live GUI observer status from permission-denied to ready. No other app’s permission changed. The metadata-only follow-up probe saw no foreground Claude activation and therefore captured no new visit; fresh foreground capture and provider arrival are not claimed. See `evidence/claude-recents-permission-repair.json`.

Evidence: `evidence/claude-created-recents-tests.txt`, `evidence/claude-created-recents-native-tests.txt`, `evidence/claude-created-recents-build.txt`, and `evidence/claude-created-recents-verification.json`.

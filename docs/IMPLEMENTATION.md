# Recent working choices and Claude timestamps — build 0.2.11, 4 November 2026

Recent Claude jumps were recorded as Spleen dispatches, but unsaved visited destinations had no saved `lastOpenedAt`; their ranking recency came only from an older Accessibility observation. The earlier provider rule ensured one Claude option, so the second recently used session could remain hidden. A read-only replay of the updated ranking now places both sessions at ranks 1 and 3.

Known candidates now retain Spleen selection time independently of observed visit time. Recorded selections and observed visits within 30 minutes form the recent working set, which precedes older topic matches for the center and unpinned neighbors. Bare legacy saved timestamps retain their modest recency score without acquiring this stronger provenance tier. Pins remain nearby; catalog/provider fallback promotions cannot displace these recent choices. Dispatch-only records still cannot create an unobserved Claude identity, and the last known current destination remains excluded from alternatives.

Cards show source-specific timestamps: a verified completed turn as **Last reply**, otherwise the newer actual visit or Spleen selection as **Last visited** or **Last selected**. Tooltips show the exact date/time and source meaning. Claude reply completion remains unavailable through the current metadata-only observer; lifecycle hooks are a possible future source, requiring verified mapping of engine and Desktop identities, including SSH-backed sessions. No transcript/private storage read, hook installation, model request, or permission change was added.

Validation: 122 core/replay tests and 264 native app checks passed, plus strict release signature verification and inspected light/dark previews. The running app was relaunched with the existing store. A live UI read confirmed both recent Claude cards at ranks 1 and 3 with **Last selected** labels; the original Claude session was restored without sending a prompt. Saved destinations and the observation preference stayed byte-identical across relaunch. Claude's own UI displayed a relative reply age and an awaiting-input cue, establishing useful metadata surfaces to investigate without claiming a finished adapter. [Claude Code completion hooks](https://code.claude.com/docs/en/hooks#stop) are another potential source. Evidence: `evidence/recent-working-tests.txt`, `evidence/recent-working-native-tests.txt`, `evidence/recent-working-verification.json`, and `evidence/recent-working-previews/`.

---

# Turn timestamps — build 0.2.10, 4 November 2026

The existing bounded Codex turn-summary read now retains actual start and successful completion timestamps. The latest completed timestamp can precede a newer started turn, and remains distinct from thread update/dispatch/visit time. Cards, selected preview, and search rows display a relative last-reply time with the exact local timestamp in a tooltip. Missing, future, failed, interrupted, and inconsistent completion data does not become a completion label. Older excerpt caches decode unchanged and receive an in-place metadata upgrade, prioritizing current/suggested chats within the existing eight-chat background budget. Visible metadata stays frozen with its invocation snapshot.

The installed protocol schema includes thread runtime status, approval/input flags, parent-thread identity, turn timestamps, command status, and child-agent status. The live Desktop app tools correctly reported an active chat and an idle completed chat. A separate read-only stdio probe, matching Spleen's current catalog transport, reported zero loaded chats and `notLoaded` for both; its persisted latest-turn status was not an authoritative live status. The default app-server control socket was absent. Historical timing is therefore shipped separately from activity classification. No hook, daemon, subscription, permission, or model transport was installed or enabled; the ranking formula is unchanged in this slice.

The next activity adapter must observe the owning runtime and expose source/freshness. Lifecycle should select running, blocked, and freshly completed candidates; prediction should then use task relationships and repeated returns within that useful working set. Parent cards should aggregate child agents, shells, and monitors rather than filling the compass with workers. See `CONTEXT_CONTRACT.md` and `evidence/activity-design-2026-11-04.json`.

Validation: 120 core/replay tests and 264 native app checks passed, including source timestamps, invalid/absent metadata, old-cache upgrade with a fresh catalog, source-version isolation, and frozen visible timing. Light/dark native fixtures were visually inspected. After relaunch with the existing store, a live UI read confirmed relative completion labels on real Codex cards and in the selected preview; 15 cached entries had acquired timing metadata. Saved destinations and the observation preference stayed byte-identical. Evidence: `evidence/turn-timing-tests.txt`, `evidence/turn-timing-native-tests.txt`, and `evidence/timing-previews/`.

---

# Claude visibility — build 0.2.9, 4 November 2026

Claude discovery was working, but a read-only replay of the current store found four retained Claude Code sessions at ranks 22, 25, 26, and 550, leaving all five compass cards occupied by Codex. The last-ranked session was the last known selection and intentionally followed alternatives.

If the first five contain no Claude option, the local ranking now includes the most recently observed eligible Claude alternative from the last 24 hours. It replaces an unprotected nearby choice while preserving the center, pins, and latest cross-project activity. The displaced choice becomes the first hidden result. Current, excluded, future, disabled, and old visits do not acquire this reserved slot. Retained older visits remain searchable. Provider labels are now part of the search corpus, without adding provider terms to topic scores.

Regression coverage includes crowded catalogs with two pins and cross-project activity, current-Claude exclusion, disabled/expired/excluded visits, provider search, and an already-visible Claude option. The preview and orange tint are unchanged.

Validation: all 116 core/replay tests and 261 native app checks passed; the release app passed strict signature verification. Replaying the same store moved the first Claude alternative from rank 22 to rank 4, with all four retained Claude sessions still searchable. After relaunching with the existing store, Computer Use confirmed a Claude card among the five live compass choices. No external destination was opened. Saved destinations and the observation preference remained byte-identical. Evidence: `evidence/claude-visibility-tests.txt`, `evidence/claude-visibility-native-tests.txt`, and `evidence/claude-visibility-verification.json`.

---

# Conversation recognition — build 0.2.8, 4 November 2026

The native compass keeps its five fixed choices and adds a selected-conversation preview below them. Cards include the project where available. The preview displays the selected title, factual relevance metadata, and a short cached excerpt from recent Codex turns. Claude cards and their preview use a soft orange tint; the selection outline remains blue, and search rows also distinguish Claude by tint. Claude has no message excerpts through the current integration, so the preview states when an excerpt is unavailable.

Preview details are prepared with the immutable relevance snapshot. Notes must match the allowed catalog folder and exact source update timestamp, and provider-qualified keys prevent Codex notes appearing on Claude destinations. Background updates preserve the visible preview until the next invocation. Selection performs only in-memory lookups and leaves navigation/dispatch behavior intact. The panel is 680 × 474 points to reserve space for the preview.

Validation: 112 core/replay tests and 261 native app checks passed, including scoped/fresh/provider-isolated excerpts and frozen-preview behavior. Native light/dark compass, selected-Claude, and search fixtures were rendered and visually inspected. Checks inject dispatch/focus callbacks and do not establish external arrival. Evidence: `evidence/recognition-tests.txt`, `evidence/recognition-native-tests.txt`, and `evidence/recognition-previews/`.

The running app was relaunched with its existing `.local-state` directory. A live native UI check confirmed that Right changed the selected card and its preview together, without dispatching a destination. Saved destinations and the Claude observation preference remained byte-identical. See `evidence/recognition-verification.json`.

---

# Claude Desktop Code switching — build 0.2.7, 4 November 2026

The missing external opener is now experimentally verified on Claude **4.16336.0**. Two existing interactive sessions, one local and one SSH-backed, completed external B → A → B → A → B navigation with exact original AX identities and one visible sidebar row each. The installed sidebar right-click menus exposed no Copy link, so the probe explicitly tested the reported `claude://claude.ai/epitaxy/local_<UUID>` template using independently observed IDs. These were constructed test links, not app-generated links or an official route guarantee. A second isolated test exercised Spleen's actual native compass and `NSWorkspace` dispatcher in both directions, confirming exact arrival. [Full evidence and limits](CLAUDE_DESKTOP_FEASIBILITY.md).

`ClaudeDesktopCodeTarget` adds strict validation and retains the existing `desktop-code:local_<UUID>` identity namespace. Code, ordinary Chat, and Codex cannot merge by UUID suffix or title. Code saves use schema v3 without changing legacy labels, pins, or targets. There is no full external Claude catalog API established: `ClaudeDesktopRecents` projects only the opt-in observer's accepted foreground selection events into bounded recently visited destinations, using the existing 64-event/30-day store. It does not read private Claude storage, invoke Claude's session-list tools, install hooks, or learn destinations from lifecycle events.

Observed visit time stays separate from dispatch time. Saved metadata overrides observed labels, duplicate titles retain separate identities, and unsaved visits are not permanently added on dispatch. Removing a Code target records a provider-qualified exclusion; restore, clear, and disable honor the corresponding state. The shared context-event bound can evict a visit before 30 days. Duplicate visible labels can still look alike; users can save distinct labels through the editor.

Background preparation merges candidates before constructing contextual and neutral indexes. Attention expiry after 30 minutes does not erase valid visits. At the earliest 30-day retention expiry (or clock reversal), a prebuilt no-visits fallback prevents stale targets from leaking through the opening path; a queued rebuild restores other still-valid visits on a later invocation. No scan, hashing, catalog merge, or disk access was added to shortcut opening. Frozen compass/search and the 0.2.6 cross-project activity choice are preserved. Dispatch recording resolves the frozen result even after panel dismissal and replacement of the prepared candidate set.

Validation: **111 Swift tests (101 core, 10 replay), 258 native checks**, release build, plist validation, and strict ad-hoc signature verification pass. New regressions cover strict route rejection, namespaces/schema migration, title suffix preservation, duplicate identities, restart, hides/restores, clearing, foreground/lifecycle separation, expiry, frozen presentations, and actual controller sequencing after a prepared candidate disappears. Native checks required normal macOS window-server access; their external dispatcher is injected. The separate live check used the real opener but restored observation fixtures, so a new complete live-observer-to-list-to-dispatch chain is not claimed.

Release preparation over 1,000 synthetic entries measured p95 **0.007 ms**, search p95 **1.914 ms** (100 samples); these remain computation measurements, not screen or arrival latency. The tested 0.2.7 build is running with the original explicit `.local-state` directory. Saved destinations were byte-identical across relaunch, and **Remember visited Claude Desktop sessions** was verified unchecked. Settings remains open at that option; no persistent observation, permission, or hook was enabled. Temporary session fixtures and launch helpers were removed.

Evidence: `evidence/claude-code-navigation-2026-11-04.json`, `claude-code-tests.txt`, `claude-code-native-tests.txt`, and `claude-code-build.txt`. Claude cold launch/restart, archived/deleted sessions, account changes, and future builds remain outside the tested claim.

---

# Recent activity coverage — build 0.2.6, 4 November 2026

A Codex chat the user reported missing from the suggestions was present in the 543-thread cache and searchable, but ranked 68th despite being the second most recently updated catalog thread. Topic/project overlap and Spleen dispatch history crowded the compass; catalog activity only broke otherwise-equal baseline ties.

The prepared local order now retains one latest-activity alternative among the five compass choices, preferring another project when project context is known. If that candidate is already visible, the order stays unchanged; otherwise it moves to fifth, after the center and reserved pins, with a “Latest activity” subtitle. Remaining relative order, search, and frozen presentations are preserved. Candidate selection respects provider identity, catalog scope, hidden rows, current-conversation exclusion, and future timestamps. Latest activity is relative to the available catalog, not proof of foreground attention or a claim of recent human interaction.

Validation: 97 Swift tests (87 core, 10 replay), 234 native app checks, release build, and strict ad-hoc signature verification pass. Three new regressions cover crowded cross-project activity (including a newer same-project thread), an already-visible activity candidate, and visibility/provider/timestamp boundaries. Native checks required running outside the shell sandbox to access the macOS window server. A read-only replay of the existing cache moved the reported thread from 68th to fifth. The app was restarted with its existing `.local-state` store, and Computer Use verified the reported chat among the five visible compass buttons. No destination was dispatched in the live check.

This addresses the reported coverage miss; general prediction quality remains unmeasured, and direct Codex navigation still does not update Spleen's last-known selection. Evidence: `evidence/activity-suggestions-tests.txt`, `evidence/activity-suggestions-native.txt`.

---

# Next-destination center — build 0.2.5, 4 November 2026

Previously, pins always preceded relevance and the last selected conversation received a large score bonus. Because the first result is the compass center, a pin could permanently occupy it, and unpinning could still recommend the conversation just opened.

The local center now chooses the highest-scoring different conversation. Previous-distinct interaction adds return evidence alongside project/topic overlap and recency; stored selection timestamps supply the previous conversation when interaction memory is unavailable. Pins reserve nearby positions instead of overriding the center, but a relevant pinned destination can still win it. The last known selection follows other choices and remains searchable. A single available destination remains usable. Choices still freeze during an invocation; completed background preparation applies on reopening. Discovery scope, saved labels/pins, observation preferences and the disabled remote transport are unchanged. This uses last known interaction, not continuous foreground Codex tracking.

Verification: 94 Swift tests (84 core and 10 replay) and 234 native checks pass. New regressions exercise successive A → B → A dispatches, an unrelated pin staying nearby, a current pinned chat, equal IDs across providers, missing previous destinations, title search, and empty/single catalogs. Existing replay expectations were updated for the new local center positions. The optional remote experiment retains its existing separate pin policy and remains disabled. Release build and strict ad-hoc signature verification pass. Tests inject dispatch and do not establish destination arrival or measured prediction quality.

Evidence: `evidence/next-destination-verification.txt` and `evidence/next-destination-native.txt`.

---

# Live native and Claude verification — build 0.2.4, 3 November 2026

The user unlocked the Mac and performed one physical shortcut check. The current build is running normally with the existing `.local-state` store; temporary diagnostic tracing was removed on relaunch and the panel was dismissed for normal use.

**Verified live:** native compass and arrow selection; first-character replay into native search; subsequent text preservation and known-title lookup; preserved labels/pins/exact folder scope; physical Control–Option–Space delivery with a key panel; Escape cancellation and a transient foreground-restoration match. The captured hotkey-handler-to-panel-presentation interval is **3.969 ms**. This excludes hardware key delivery and actual compositor/photon latency. Event traces contain only fixed navigation/lifecycle names and timestamps, with no typed characters, queries, app/session identities or PIDs.

Live testing found a focus issue: reopening an already-presented nonkey panel returned without bringing it forward. `present()` now reasserts key/front status without resetting the visible snapshot, search or selection. Two native regressions cover this. Opt-in key-routing/window/focus diagnostics made automation-induced reopening distinguishable from the actual global shortcut. Normal mode incurs no diagnostic disk writes.

**Claude Code observation passed:** with Claude genuinely foreground, the temporary observer captured four observations across two distinct identities, returned to the original session, and exited after 15.2 seconds. There were two successful attachments, seven raw AX notifications, six metadata reads/parsed records, four accepted deliveries and two deduplicated deliveries; permission/attachment/scan-limit failures were zero. Earlier incomplete probes had no foreground Claude application and therefore correctly did not attach. No subscription or foreground-gating relaxation was needed. The probe emits only aggregate counts and retains no identities/titles/messages in evidence. Its duration is configurable from 1–60 seconds with an initial-selection signal and count-only diagnostics. The installed Claude bundle reports version 4.16336.0. Persistent Claude observation remains off in Spleen Settings.

**Boundaries:** Computer Use explicitly blocks inspection of the Codex app. The user reported that Codex came forward and believed the selected chat opened; exact destination identity remains unconfirmed. Do not interpret NSWorkspace acceptance as proof of that identity. A bounded Claude sidebar-menu inspection exposed Open in → Split view/New window and obtained no app-generated existing-Code link. External Claude Code reopening remains unverified/unimplemented. Ordinary Claude Chat link syntax support remains separate. Paid Decisions calls remain zero.

**Regression/package checks:** all 89 Swift tests and 228 native checks pass; four invalid probe-duration checks reject before observer startup. Release 1,000-chat warm model benchmark: preparation p95 **0.007 ms**, search p95 **1.885 ms**; direct prepared opening p95 **0.003 ms**. Measurements vary with host load and do not establish end-to-end input/render/arrival latency. The app-only 0.2.4 ZIP passes integrity, checksum, extracted strict signature and executable checks. Original destination targets/labels/pins and discovery scope remain intact; live dispatch recency updates are expected. No OS permission, hook, discovery-scope or observer-preference change occurred.

Evidence: `evidence/live-core-tests.txt`, `live-app-tests.txt`, `live-build-package.txt`, `live-helper-checks.txt`, `live-ui-events.jsonl`, `live-claude-selection-probe.txt`, `live-verification.txt`, and `live-summary.json`.

---

# Offline evaluation pre-work — 3 November 2026

Added a separate `SpleenEvaluation` library, `SpleenReplay` executable, and `scripts/replay.sh` runner. The app stays at build 0.2.3, and its binary hash matches the prior verified release. App builds now explicitly select the Spleen product; replay tooling is not included in the distributed app bundle.

The tool replays real local ranking and prediction-state code with built-in or explicitly supplied evidence/responses and virtual time. The default 16 cases cover 18 openings, including 17 labels and one dismissal. They include a scripted prediction loss, shortlist/availability misses, no-ops, refusal/malformed replies, missing/late/stale results, exact deadline/cache expiry, frozen open choices, repeated openings and pins. Tests additionally cover provider collisions, two-pin losses, no-request cases, context expiry, bounds and future-label isolation.

Reports distinguish raw arrival, fresh timely validation, and an applied reorder at opening. Every labeled opening contributes to center/top-three/compass and paired win/loss counts; missing/late/unavailable targets remain in the denominator. Outcome labels are structurally separate from pre-choice evidence. Changing/removing them cannot affect request bytes, generation keys, or local order. Superseded replies are distinct from deadline-late replies. No history is learned from labels automatically.

**Validation:** all 89 Swift tests pass (79 core + 10 replay); 15 CLI end-to-end checks pass. The generated fixture roundtrips deterministically, all 17 local request examples fit the byte limit and pass manifest hashes, changing every outcome preserves every request byte, and private title sentinels remain absent from reports. Explicit request exports expose the exact proposed title for local review. Invalid/missing/conflicting options, malformed/oversize input, symlinks, directories and FIFOs are rejected without echoing content. Existing saved destinations remain byte-identical; prior native checks remain 226/226 for the unchanged 0.2.3 app.

Artifacts: `fixtures/replay/synthetic.json`, `evidence/replay/replay-report.txt`, `replay-report.json`, `requests/manifest.json`; verification in `evidence/replay-core-tests.txt`, `replay-build.txt`, `replay-run.txt`, `replay-cli-checks.txt` and `replay-summary.json`. All fixture event times are simulated; scripted scores are not model-quality results or measured network latency. No real API call, credential setup, provider/chat-store access, UI action, permission change, hook installation or telemetry collection occurred. Live desktop checks and a real approved prediction experiment remain pending. [Replay contract](DECISIONS_TRIAL.md#offline-replay).

---

# Responsiveness and prediction efficiency — build 0.2.3, 3 November 2026

A further user-requested pass tightened the prepared opening path, background indexing, Decisions payload/response work, and rapid-reopen input handling. Production remote transport remains absent; no paid requests or credential setup occurred.

- `prepare()` installs the ready order/results and center directly, resetting query without a search refresh or scan for the old selected ID. Initial mode is compass, avoiding an initial management-view mount. Existing invocation choices stay frozen.
- `LatestSnapshotScheduler` retains one running build and one replaceable pending build. Superseded builds skip expensive later stages and publication. A deterministic fixture holds one running build, submits 32 waiting updates, and observes only the latest additional build/prediction. Explicit-edit adoption is now scoped to its presentation generation, so closing/reopening cannot let an old edit move the new invocation.
- Optional request encoding and response parsing run on utility queues; main-thread completion handles only typed result/job/deadline state. Only the current job may clear its timeout/cancellation state. The full 750 ms deadline includes validation.
- Input uses indexed metadata/notes and one compiled literal-ID matcher across fields. JSON-escaped UTF-8 compaction fits 6,000 bytes without dropping aliases, providers, provenance, ages or transition counts. Labels precede optional text in the budget; extreme graphemes shorten safely. A retained hint's identity remains redacted after lifecycle activity evicts its audit event.
- A unique chosen probability winner may move first; remaining candidates preserve local order. None, an unchanged leader, tied maxima, or choice/probability disagreement leave local order intact. Pins keep priority. Applying an accepted order indexes only the eight candidates, with one pass over the remaining baseline.
- Dismissal clears marked text/first responder synchronously, preventing a rapid reopen's first Space/arrow from reaching the previous search editor. Deferred field readiness checks attachment generation/window before requesting focus.
- The context watcher creates its own fresh directory and reconciles once after attaching, closing startup races with asynchronous catalog persistence. It compares context file identity/size/modification time, ignoring catalog/insight/preference/temp-write bursts. File metadata changes that do not indicate content were deliberately excluded after a fixture caught redundant reloads.

**Final validation:** 79 core tests, 226 native app checks, and nine focused release ranking tests pass. The 1,000-chat release app benchmark reports preparation p95 **0.003 ms** and search p95 **1.695 ms** (100 samples); a direct opening fixture from typed/tail-selected state also reports p95 **0.003 ms** without refreshing results. Release input+body construction over 1,000 synthetic metadata IDs: p95 **6.453 ms**, 3,062-byte body, entirely background work (30 samples). The extreme Unicode/56-transition fixture fits in **5,984 bytes**. These measurements exclude physical hotkey delivery, screen compositing, real network inference, and destination arrival; no real-world prediction-quality gain is claimed.

The 0.2.3 local ZIP passes integrity/checksum and extracted-bundle strict signature/executable checks. It contains only the app, without user stores/source history/extended attributes. Native fixtures were regenerated. Saved destinations remain byte-identical to the pre-slice backup and discovery scope is unchanged. No observer preference, hook, or OS permission was changed; paid inference remains off. The archive is ad-hoc signed, not notarized or published, and no relaunch was performed.

Evidence: `evidence/efficiency-core-tests.txt`, `efficiency-release-ranking-tests.txt`, `efficiency-app-tests.txt`, `efficiency-build-package.txt`, `efficiency-file-checks.txt`, `efficiency-preview.txt`, `efficiency-summary.json`, and `native-previews/`. Live shortcut/focus/arrival, Claude selection roundtrip/external Code reopening, and real ranking usefulness still require an unlocked session or explicitly enabled experiment. [Next live check](LIVE_CHECK.md).

---

# Startup and keyboard polish — build 0.2.2, 3 November 2026

A further user-requested pass fixed cold startup, refresh scheduling, and native control focus. An empty untouched invocation now adopts its first discovered choices even if an earlier empty cache snapshot completed; typed search and existing choices remain frozen. Loading copy accounts for active discovery. Automatic refresh honors the persisted discovery-policy cache lifetime and a failed-attempt backoff, supports explicit force, and recovers from backwards wall time.

Compass Tab focus and arrow selection share the same selected destination. Empty-state/native buttons retain activation keys; search navigation/confirmation is intercepted only while the native search editor owns focus. Search accessibility includes provider and selection, folder-removal labels identify their folder, and restoring hidden chats remains available in automatic discovery.

Diagnostics now write event names plus wall/monotonic timestamps on a serial utility queue, capped at 1 MB. Headless catalog/relevance checks require explicit folder scope; the app binary contains no hardcoded personal project path or chat ID. The legacy Python probe delegates to the bounded counts-only compiled checker. Every native-test model now injects provider/insight callbacks, including the original fresh-store fixture, so fixture runs cannot start a real provider through automatic discovery.

**Validation:** 70 core tests and 197 native app checks passed. New fixtures cover delayed first discovery, frozen typed/nonempty invocations, persisted cache freshness, expiry, force/failure/backoff/clock reversal, and focus-aware native control routing. Six invalid/missing-scope CLI checks terminate before provider access. Six native light/dark renders were regenerated; modified compass/search layouts were re-inspected. An optional trace contained 93 ordered event-only records. Release computation with 1,000 synthetic entries / 100 samples: preparation p95 **0.027 ms**, search p95 **1.828 ms**; these are not physical-hotkey, screen-render, or destination-arrival timings.

`dist/Spleen-0.2.2-macos-arm64-local.zip` contains only the app bundle, without saved state, source history, or extended attributes. Archive integrity, checksum, extracted-bundle strict signature, and executable hash all pass. This is a local ad-hoc signed development archive, not a notarized/public release. The saved destination file remains byte-identical to the pre-slice backup; discovery scope, observation settings, hooks and OS permissions were not changed. Paid inference remains off.

Evidence: `evidence/polish-core-tests.txt`, `polish-app-tests.txt`, `polish-build-package.txt`, `polish-helper-package-checks.txt`, `polish-event-trace.jsonl`, `polish-summary.json`, and `native-previews/`. Live focus/shortcut/arrival, the Claude observed-selection roundtrip, external Claude Code reopening, and real prediction quality remain unverified. [Next unlocked-session check](LIVE_CHECK.md).

---

# Desktop context and native compass — 3 November 2026

Three user-requested agents implemented and reviewed the native interface, provider/context core, and Claude Desktop feasibility/adapter work. The coordinating agent integrated them in the existing checkout. Source and state were backed up first at `/private/tmp/spleen-desktop-slice.5Tdap0`; no repository or worktree was created.

## Delivered in build 0.2.1

- A real native 680×326 compass replaces the search-list landing. Center/up/right/down/left positions stay fixed; arrows select and Space/Return/keypad Enter dispatch. Modified shortcut keys and repeated confirmation cannot accidentally open a destination. Typing replays into a native AppKit search field, preserving rapid initial keystrokes and marked-text composition. Management remains 560×480 and is reachable from the menu bar; settings scroll while actions remain fixed. Rejected dispatch retains the exact choice order, selection, and original cancellation focus target.
- Backward-compatible provider-qualified destinations distinguish Codex and ordinary Claude Chat. The existing Codex label/pin store is retained. Claude links are syntactically validated against the documented ordinary-chat route; existence and visible arrival are separate.
- Automatic Codex metadata discovery omits `cwd`, filters source kinds, paginates to a maximum 1,000 entries, and retains ten-second/4 MB response bounds. A live compiled check returned **541 chats across 108 projects**, not truncated, logging counts only and caching none of that expanded survey. Existing stores remain exact-folder scoped until switched in Settings; fresh stores default to automatic mode.
- `ContextMemory` records a maximum 64 events/interactions over 30 days, with 30-minute current-hint freshness, previous distinct interaction, provenance, and explicit observed/inferred/lifecycle semantics. A dispatch records user intent, not successful arrival. Context persistence is locked across processes, bounded to 256 KiB, and replaced atomically. A directory event watcher reloads it off the opening path, with semantic snapshots staged for the next invocation.
- The `--context-event codex` helper accepts at most 64 KiB, checks the configured discovery scope, discards prompt/transcript fields, and never starts NSApplication or emits model context. The example hook config remains **uninstalled** and requires normal hook trust review.
- The opt-in Claude observer uses workspace activation plus AX notifications; no idle polling. Reads are bounded to 80 nodes/depth eight with per-call/deadline bounds on a utility queue. Only focused WebArea URL/title are collected while Claude is active; no message values, full transcript, screenshot, or clipboard access. It distinguishes ordinary-chat UUIDs, Desktop Code `local_` identifiers, and engine session IDs. Accessibility permission is checked without prompting at startup; a request can originate only from the explicit saved preference.
- Context topics can influence relevance even when the selected external Claude Code session is not an openable Spleen destination. No external selection is invented from a background completion. Optional Decisions input now includes provider-aware aliases, short approved notes, provenance-aware current/previous hints, and transition counts. Opening uses prepared arrays; optional payload construction is skipped entirely when transport is disabled.
- Mock-backed app integration proves predictions affect only a subsequent invocation and 100 opens/searches do not create more calls. Expired remote order falls back through an O(1) timestamp check. The production app still supplies no remote transport; **zero paid inference calls** were made.
- Fresh and neutral context snapshots are both built in the background. Opening chooses between them using wall-clock and uptime checks, so sleep or a backwards clock adjustment cannot extend a stale hint. The open invocation stays frozen. Lifecycle audit events, audit eviction, filtered metadata, and semantically unchanged refreshes do not rebuild or invalidate useful prepared ranking.
- Catalog persistence now uses a serial utility queue, preserving write order without disk work on opening. Staged/existing stores are validated; corrupt saved state disables context observation/recents writes rather than overwriting unrelated stores.
- The Claude observer now uses first-edge event coalescing, retired attachment callback IDs, immediate generation invalidation on workspace transitions/stop, and final foreground/permission checks before delivery. Unknown web areas are scan leaves; title preprocessing is bounded by scalars/bytes as well as characters.
- Optional HTTP trials require a durable, expiry-bounded request ledger. Request fingerprints and reservation times survive restarts; duplicate payloads, corrupt/symlink stores, and configuration resets fail closed. Cancellation claims completion atomically, and expiry is rechecked after disk work. This is a finite request allowance, not a dollar guarantee. Production remote transport remains absent.
- `--render-preview <absolute-directory>` renders the actual native compass/search/settings in light and dark using synthetic data, hidden app-owned views, and a neutral material backing. No desktop capture, user store, provider process, hotkey registration, or observer is involved.

## Verification

**70 core tests, 162 native app checks, and four headless helper checks passed.** New checks cover durable request caps/deduplication across restarts and concurrent writers, blocked-ledger expiry, cancellation arbitration, context expiry across sleep/clock changes, lifecycle-only bursts, serial cache persistence, preserved corruption, and first Option dead-key routing. Earlier checks include legacy migration, equal technical IDs across providers, automatic/excluded scope, stale context, concurrency/corruption, lifecycle versus attention, external topic relevance, hostile routes, frozen snapshots, all native confirmation keys, modifier/repeat rejection, failed dispatch recovery, first-key replay, IME behavior, injected Decisions completion, and legacy disabled-recents synchronization to the hook store.

The release build passed plist validation and strict ad-hoc signature checks. Release computation benchmark with 1,000 synthetic entries / 100 samples: **p95 preparation 0.026 ms, search 1.724 ms**. These are not screen-render, physical-hotkey, or destination-arrival timings. Final build evidence: `evidence/readiness-core-tests.txt`, `readiness-app-tests.txt`, `readiness-build.txt`, `readiness-preview.txt`, `readiness-summary.json`, and six PNGs under `evidence/native-previews/`. Earlier helper/discovery/permission checks remain in `desktop-context-cli-tests.txt`, `desktop-context-discovery.txt`, and `desktop-context-permission.txt`.

The live Claude UI probe identified the user's actual workspace as **Claude Code inside Desktop**, exposing a selected `AXWebArea` route shaped `claude.ai/epitaxy/local_<UUID>`. This is a useful observed context surface, not a documented external opener or a complete catalog. No app-generated existing-Code link was obtained from the bounded menu inspection; no guessed Code link was dispatched. See [the detailed feasibility report](CLAUDE_DESKTOP_FEASIBILITY.md).

The desktop locked before the final native-panel/selection-roundtrip UI checks. Offline integration, fixture rendering, and documentation continued while the user was away. Do not claim live checks passed until a follow-up observation records them. A headless Accessibility permission check returned allowed without requesting or changing permission; that alone does not establish the complete observer workflow in the launched app. The bundle can be newer than the still-running process. [Next live check](LIVE_CHECK.md).

Native fixture inspection confirmed readable light/dark compass/search/settings layouts. Search subtitles now omit technical IDs, and the Claude preference explains its use of the selected title. These offscreen renders use neutral backing rather than live desktop compositing. Saved destinations remain byte-identical to the pre-slice backup and the existing discovery policy is unchanged.

## Remaining integration boundaries

Claude Code external reopening and catalog coverage, actual observed-context roundtrip, visible Codex arrival, physical focus restoration, and prediction usefulness remain unverified. No hooks, extensions, launch agents, remote inference, or OS permissions were enabled. Terminal integrations are deferred. This local development build is not a public release.

---

# Earlier: local relevance with a prepared fast path — 3 November 2026

Implemented by the user-requested development agent and reviewed/integrated in the existing checkout. This expands Spleen's local relevance data from titles to bounded recent prose excerpts. No other project folder was added and no external inference service was enabled.

## Current behavior

- `Relevance.swift` builds an immutable normalized search/ranking snapshot on a utility queue. `AppModel.prepare()` copies the ready snapshot and selects a row. It does no disk reads, process launches, catalog merging, sorting, hashing, or remote calls. Typing searches normalized in-memory strings.
- Context comes from the most recent remembered Spleen selection within 30 days. Ranking preserves up to two pins, then combines same-project evidence, uncommon shared terms, and modest recency. With no selection context the deterministic saved/update baseline remains. This does not identify the current foreground Codex thread.
- Title exact/prefix/substring matches remain first; additional results can match all query tokens across the title, project label, and local excerpts. No query history is retained.
- Background snapshot generations reject obsolete completions. The visible list and search corpus stay fixed until another opening or **New chats ready**. A first startup build can populate an untouched empty panel; explicit edits carry their adoption intent through superseding background builds. An unchanged catalog does not advertise new results.
- A separate short-lived app-server session enriches at most eight changed threads per refresh. Metadata-only `thread/read` validates ID, exact allowed folder, and update timestamp before `thread/turns/list(limit: 3, sortDirection: desc, itemsView: summary)`. No full-history hydration, resume, turn creation, transcript mutation, or private database access is used. Each session retains the 10-second/4 MB protocol bounds.
- `relevance.json` contains short notes; cache loading accepts at most 1,000 entries / 1 MB, with each with topic/decision/next-step fields of at most 280 characters. Extraction ignores tool output, reasoning, commentary, code fences, and structured environment blocks. Topic extraction includes substantive requests and final-answer prose so a short latest follow-up does not erase the topic. Decision/next-step fields are historical excerpts, not statements of live task state.
- Folder removals and hidden chats prune excerpts; late enrichment cannot restore removed scope. Changed thread timestamps invalidate old notes. Missing or corrupt excerpt caches regenerate while title/project search remains usable. Saved labels and destinations remain independent of provider presence.
- The native app no longer invokes the isolated optional Decisions pipeline. No paid requests, credential discovery, additional permissions, or new service were introduced.

## Verification and timing

24 core tests and **83/83 native app checks** passed, including seven relevance tests for a concrete database-lock fixture, title precedence, project/topic search, metadata validation, excluded/stale/hidden data, prose-only extraction, short follow-ups, corrupt-cache handling, generation rejection, and 1,000-thread performance. Native app checks cover startup adoption, superseded explicit edits, unchanged refreshes, stale enrichment, navigation, persistence, panel behavior, and frozen search/selection. The final release bundle passed plist validation and strict ad-hoc signature verification.

The compiled live adapter found **three catalog threads and three nonempty bounded notes** in the approved Spleen folder. The complete cold discovery/enrichment/index check took **588 ms**; this work is outside the panel's presentation and typing paths. The independent protocol-shape probe also confirmed paginated summary turns on the installed CLI. It logged field types/counts rather than conversation text.

The old app was cleanly quit and the final release relaunched through `scripts/run.sh` with its preserved project store. Spleen-only Computer Use verified that searching **quickness** found this conversation even though the word appears in no thread title. Clearing search restored all three rows; the custom **Spleen planning** label and pin survived. Settings disclosed local excerpt storage and no remote ranking. The final panel was left open on the three-chat list. No settings were changed and no real chat dispatch was performed in this check.

| Measurement | Result | What it measures |
| --- | --- | --- |
| Debug immutable snapshot access, 1,000 synthetic threads / 100 samples | p95 0.011 ms | Copy ready value and retrieve empty-query array |
| Debug normalized search, 1,000 synthetic threads / 100 samples | p95 1.795 ms | In-memory title/topic/project matching |
| Release warm `AppModel.prepare`, 2 saved entries / 100 samples | p95 0.005 ms | Actual app-model presentation preparation |
| Release warm `AppModel.prepare`, 1,000 synthetic entries / 100 samples | p95 **0.029 ms** | Actual app-model preparation, including observable state changes |
| Release app-model search, 1,000 synthetic entries / 100 samples | p95 **1.790 ms** | Query change, normalized matching, and selection maintenance |
| Cold live discovery, excerpt extraction, and index | 588 ms, 3/3 notes nonempty | Entire bounded background pipeline for the verified folder |
| External inference requests | 0 | No runtime model transport is constructed |

These are computation and protocol timings, not compositor, physical-hotkey, or destination-arrival measurements. Timing and check outputs are in `evidence/relevance-app-tests.txt` and `evidence/relevance-live-check.txt`. Actual ranking usefulness, broader folder coverage, and end-to-end navigation latency remain unmeasured. Earlier physical hotkey operation was confirmed by the user. No Codex UI was accessed.

---

# Historical: instant catalog and optional ranking — 2 November 2026

This continuation extends the existing app; the first-slice report below is historical. No new worktree/repository or additional agents were created.

## Delivered now

- Real folder-scoped catalog discovery through a short-lived desktop CLI app-server; a separate cache preserves manual destinations and custom labels. Exact folders only, max 10 scopes / 200 entries / four pages / 10 seconds / 4 MB. Uses explicit top-level source kinds and `useStateDbOnly: true`; no resume or turn calls.
- Background refresh on opening (60-second throttle) or explicit refresh; no idle polling. Cached search is immediate. The visible catalog and order freeze for each invocation; new results require next opening or **New chats ready**. Settings allows adding/removing personal folders. Only Spleen is enabled now.
- Optional Decisions payload/HTTP transport and injected transport boundary. No production transport is constructed. `gpt-6-luna` choice schema verified against current official documentation. Candidate aliases, bounded labels, coarse local selection age; no IDs/paths/content/query transmission.
- Ranking state machine: eight unpinned candidates, 750 ms deadline, SHA-256 generation key, 120-second freshness, request cap, same-generation retry suppression, cancellation, late/stale rejection, none/refusal/malformed fallback, pins preserved. Completion cannot alter visible order. Evaluation arithmetic includes missing targets and missing/late results.
- User report “the hot key works” recorded separately from automated verification.

## Verification

17 core tests and 77 in-process app checks passed. New coverage includes preview removal, scope filtering, saved-label precedence, frozen visible catalog/search/selection, next-opening refresh, discovered selection persistence, scope removal, generation/freshness/deadline rules, malformed/refusal/none responses, injected cancellable mock transport, no automatic retry, and evaluation denominators. No test sends a paid request.

The live Python feasibility probe and the compiled Swift client both returned the two Spleen chats. Both were classified `vscode` in this installation. Default and explicit-source probes agreed for this bounded folder; this does not establish all-source equivalence. Known planning ID was present. No pagination was needed. Runtime live status was not interpreted.

Spleen-only Computer Use verified: staged **New chats ready**, adoption of both chats, local “decisions” search, preserved custom planning label/pin, Settings layout, and folder-picker cancellation. The app was cleanly quit and relaunched with the preserved store. Codex UI was not accessed or bypassed. The current build is running with both chats ready.

| Measurement | Result | Limit |
| --- | --- | --- |
| Debug local search, 1,000 synthetic entries / 100 samples | median 1.115 ms; p95 1.130 ms; max 1.150 ms | CPU search only; individual test runs vary |
| Release warm model preparation, 2 saved entries / 100 samples | median 0.026 ms; p95 0.031 ms; max 0.033 ms | Snapshot/computation, not compositor or global shortcut delivery |
| Live Swift catalog probe | 2 entries; known planning chat present; not truncated | Exact Spleen folder and installed desktop CLI only |
| Paid Decisions calls | 0 | Real readiness, ranking quality, tokens/spend remain unmeasured |

AppKit tests still require approved normal desktop execution: the restricted shell aborts before NSApplication initialization. Normal-desktop tests passed. No permissions were changed. The compiled Swift adapter also passed with normal desktop access.

## Remaining limits

Visible arrival in Codex and actual cross-app focus recovery remain unverified. Physical hotkey operation is user-confirmed. Full-screen Spaces, multi-display, VoiceOver, wider folder coverage, helper memory/energy cost and end-to-end timing remain open. Cached entries can outlive a deleted/archived chat until refresh; saved destinations deliberately survive provider absence. No activity badge claims another process is idle or complete.

The optional transport is implementation scaffolding, not an enabled service. Build 0.2.1 adds a persistent request allowance alongside the per-process cap; the real trial still needs an explicit approved payload, supported credential setup, current pricing and spend authorization. The current catalog contains only one unpinned candidate, so a useful ranking comparison requires a larger approved personal set. See [the concrete trial proposal](DECISIONS_TRIAL.md).

---

# First-slice implementation

Implemented 2 November 2026 after explicit user approval. The user requested the shortcut → panel → selected Codex chat loop and skipped the earlier pre-build navigation study.

## Delivered

One Swift package with no downloaded dependencies. `SpleenCore` validates local chat targets, stores a versioned JSON catalog atomically, searches titles, orders pins/recents, and defines cancellation focus policy. The app owns an AppKit nonactivating `NSPanel`, SwiftUI search/editor/settings, a menu-bar entry, and Carbon `RegisterEventHotKey` registration. The default is Control–Option–Space. Registration is exclusive; a conflict is reported and the menu-bar path remains available. Reconfiguration registers the replacement before releasing the previous shortcut.

The panel opens on the pointer's display. It is key-capable but not a main window. Search is immediate, case/diacritic insensitive, and orders exact, prefix, then substring matches. Empty-query results put up to two pins first, then recent selections, then saved order; all saved results remain scrollable. No background process changes visible ordering. Add/edit/remove, duplicate rejection, empty/error states, keyboard navigation, click opening, and settings are implemented. Escape/repeated shortcut cancel; focus loss dismisses without stealing focus back.

Dispatch constructs a canonical existing-chat URI from a validated ID and calls `NSWorkspace.open`. The panel hides before dispatch and guards repeated dispatch. macOS rejection reopens the panel with an error and does not record a recent selection. Acceptance is recorded as a dispatch, not proof of visible arrival. Corrupt or newer-version saved files are preserved and writes are disabled until repaired; the user receives the file location.

No automatic discovery, fuzzy search, prediction, Decisions, API credentials, clipboard/screen monitoring, app-content inspection, launch-at-login, or external service was added. Only Spleen's own local key events are monitored while its panel is open. App activation notifications are transient dismissal signals, not retained activity history.

## Artifact and commands

- App: `<repo>/build/Spleen.app`
- Launch with the verified project store: `./scripts/run.sh` from the project directory.
- Build: `./scripts/build.sh`.
- Core + release build + app tests: `./scripts/test.sh`.
- App tests alone: `build/Spleen.app/Contents/MacOS/Spleen --self-test`.

The build is arm64 and ad-hoc signed. `plutil -lint` and `codesign --verify --strict` validate the bundle. It is ready for local use, not packaged for public distribution.

## Verification and limits

| Check | Result | What it establishes |
| --- | --- | --- |
| Eight XCTest cases | Passed | URI rejection/canonicalization, CRUD/deduplication, search, pin limit, recency, persistence/corruption preservation, shortcut validity, focus policy |
| 69 in-process app checks | Passed | Real NSPanel visibility over 25 toggle cycles; editor/search/selection integration; exact URL passed to injected dispatcher; failed-dispatch recovery; restoration callback policy |
| Spleen UI via permitted Computer Use | Passed | Added and edited the known local planning chat; live search; initial/editor/return-to-search focus; settings changed shortcut and restored default |
| Escape in Spleen UI | Trace confirms cancellation | The observation tool subsequently reopens the app, so a screenshot alone is misleading |
| Return and row click in Spleen UI | Both dispatches accepted by macOS | Actual `NSWorkspace.open` success; no claim that Codex showed the expected chat |
| Carbon registration and reconfiguration | Returned success | Default and temporary modified shortcut registered; physical global event delivery remains untested |
| Targeted synthetic Control–Option–Space | Did not invoke Carbon handler | This tool input is not a valid external system-hotkey test; it inserted a space into the targeted field |
| External app focus restoration | Policy/callback tests only | Actual cross-app behavior remains a manual check |
| Codex UI arrival | Not inspected | Prior Computer Use restriction remains in force; no alternate UI technology was used |

The app self-test never calls real Codex dispatch or real external focus restoration. It uses a disposable temporary store. No test makes API requests.

Initial sandboxed launch failed inside macOS application registration before Spleen's code ran; Launch Services also returned `kLSNoExecutableErr` from the restricted shell despite a valid executable. Approved execution with desktop-session access launched successfully and passed the app tests. No security permission was changed and no installation was required.

An opt-in `--diagnostics <path>` flag records only Spleen event names and timestamps for verification. The test trace is in `.local-state/ui-test.jsonl`; it contains Escape cancellation, observation-triggered reopening, and two accepted dispatches. Normal `run.sh` does not enable it. No destination IDs, queries, or external app identities appear in the trace.

## Remaining manual checks

1. With another app active, physically press Control–Option–Space. Confirm Spleen opens with search focused; repeat the shortcut and confirm dismissal.
2. Open again and press Escape. Confirm the previous app retains working keyboard focus. Switch deliberately to a third app and ensure Spleen does not pull focus back.
3. Choose **Spleen planning** by Return, then by mouse in a separate invocation. Confirm Codex visibly reaches the intended local chat. No new turn should be started.
4. Try a conflicting shortcut, full-screen Space, second display, wake, and VoiceOver. Use the menu-bar fallback if registration fails.

The physical hotkey, external focus, and destination-arrival checks are the concrete remaining integration uncertainties. They do not prevent building or launching this first slice. The broader usefulness study, latency/memory measurement, and coverage/ranking comparisons remain future work.

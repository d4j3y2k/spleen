# Live indicator integration — 5 November 2026

The running Spleen build now has actual source adapters, not just injected UI samples. It was rebuilt, code-signature checked, and reloaded against the existing `.local-state` directory. Existing destinations, labels, pins, context preferences and opening path were preserved.

## Clearer working indicators — 0.2.24

Working conversations show a blinking monochrome dot beside plain **Working…** text and slightly bolder titles on compass cards, recent-session rows, and search results. The dot draws natively in AppKit; a common-mode timer alternates full and 15% opacity every 0.65 seconds. Activity uses the normal text color, with no additional pill, stripe, or colored highlight. Reduced motion keeps the dot steady and removes its timer; the status text remains visible. The separate blue unread dot does not blink. Card footers and recent-row status lines reserve their height. Synthetic snapshots hold the activity dot at full opacity.

The cues use the same fresh `.working` sample as the previous spinner. Unread, approval/input and completion remain independent; old reply timestamps and recent activity do not turn on the cues. The existing runtime coverage and expiry limits below still apply.

Validation: release build, strict signature verification using the existing Apple Development identity, and 406/406 native checks passed. Twenty synthetic previews cover both appearances, selected Codex and Claude cards, an active long title, selected recents, search, and high-contrast appearance fixtures. Build (`evidence/active-thread-build.txt`) · Native checks (`evidence/active-thread-native-tests.txt`) · Dark preview (`evidence/active-thread-previews/native-fixture-compass-dark@2x.png`).

## Recent work stays discoverable — 0.2.14

The user reported the running Codex chat missing from the compass while Codex's own sidebar showed it running. The owning Codex app confirmed an active thread and an in-progress turn. Spleen already had its exact identity in the catalog and had recorded a selection less than two minutes earlier. Two competing older conversations had excerpts ending in user messages, so their inferred ongoing priority beat the recent selection whenever the real hook's 15-second working pulse expired. A regression reproduced that failure before the fix.

Ranking now considers live attention first, recent explicit visits/selections or provider activity next, and historical task inference after that. Pins still reserve nearby positions, the center remains an alternative to the last selection, and an already-open picker retains its targets. A last-selected chat with recent real provider activity stays eligible nearby even when its live pulse has expired.

`ActivityHookSnapshot.recentActivity` projects actual prompt/model/tool/subagent-start receipt times into ranking history. It never renews them on polling. `SessionAttention` retains at most 128 identities for 30 minutes in memory; the existing bounded hook journal can rehydrate them after restart. Disabled or unavailable activity reporting clears this history. Prepared snapshots include its expiry boundaries, preserving the read-free shortcut path. This does not add visits or change unread state.

This is a visibility fix, not a replacement for owning-runtime monitoring. Codex's separate working spinner can still expire during long silent requests. Historical activity keeps a conversation useful to select without falsely displaying a continuously working badge.

Validation: 186 package tests and 294 native checks passed. New checks cover old unanswered chats competing with recent work, live-pulse expiry, historical timestamp freshness, last-selected eligibility, and a native app restart after the pulse expires. The updated 0.2.14 app was signed and launched with the existing store. See verification evidence (`evidence/recent-work-verification.json`).

## Claude Desktop Code

Version 0.2.13 fixes a real missing-spinner case reported immediately after 0.2.12 verification. The initial adapter depended on a sidebar current-page marker and the row's `Running` text. A failing probe rejected the marker even though the route was open. A second observed case had a finished main response but an enabled `Stop this task` action in Session details → Background tasks. A sidebar-only spinner missed that still-running work. The earlier successful sample was insufficient evidence of reliability across these states.

The opt-in `ClaudeDesktopStatusObserver` now reads three independent kinds of native evidence every two seconds, including while Claude is in the background:

- The exact displayed Code route, revalidated after every scan, anchors identity.
- The current sidebar row supplies unread state and can corroborate working. This requires a unique exact title match and an explicit `AXARIACurrent` marker. No other sessions are associated by title.
- `ClaudeDesktopWorkControls` examines the current primary pane's enabled response Stop control and Session details → Background tasks → Stop this task controls. Either proves ongoing work even without a sidebar marker, and background tasks keep the spinner after the main response ends. Disabled controls, finished-task labels and stop buttons inside messages or unrelated content are ignored. These controls never manufacture an unread/read acknowledgement.

The work-control scan does not enter Chat messages, the prompt field, artifacts, or other named content regions. Version 0.2.17 adds a separate metadata-only read of Chat messages' top-level trailing assistant actions toolbar. It requires the `Read aloud` control and exactly one supported relative age. Numbered message groups, their nested actions, and message text remain opaque. An active main-response Stop control suppresses new reply metadata; background-task controls do not. Scans run on a utility queue with at most 480 copied nodes, bounded depths, a 600 ms overall budget and at most 80 ms per AX request. Live status has an eight-second evidence lease refreshed by actual control observations, not a timer assumption. A missing, ambiguous, truncated or unknown layout, app termination, lost permission, disabled observation, or navigation away clears this live source. Canceled timer generations cannot deliver after stopping. Status updates do not write visit history or move the open picker's card targets.

Reply ages are approximate historical display metadata, separate from live completion and activity. The route-qualified local `claude-reply-times.json` retains at most 256 entries for 30 days, uses private file permissions, and clears with recent history. Repeated rounded ages cannot creep forward on each poll; a clearly newer estimate replaces the retained time. Reply metadata neither discovers a destination nor changes ranking. An open picker's reply metadata stays frozen until reopening. The tooltip explains that hidden sessions cannot be refreshed until displayed in Claude.

**Coverage:** the Code session currently displayed in Claude's focused window, including local and SSH-backed sessions. Claude can be in the background. Working requires an exposed native work control or a verified Running sidebar row; unread requires the verified current sidebar row. Approximate last-reply ages require the exposed latest assistant footer. Other sessions hidden behind it, ordinary Chat, a complete Claude catalog, reply excerpts, and exact reply-completion timestamps remain unsupported. Native labels/layout may change with Claude updates; unsupported layouts fail closed.

**Live verification:** 0.2.12 verified a real working turn and a reversible native unread → read transition, but missed the reported state above. Version 0.2.13 directly detected the existing active background task while the main reply was finished. The updated GUI's card reported Working and its actual drawn spinner was inspected. Repeated real probes checked persistence beyond the evidence lifetime. No Claude prompt was sent and no active task was stopped. The app was rebuilt, signed, reapproved using the previously authorized Accessibility refresh, and relaunched with the existing `.local-state` directory.

All 182 package tests and 291 native checks pass. New regressions exercise the actual control traversal through deep anonymous groups and Session details, multiple background tasks after main completion, absent sidebar markers, disabled/finished controls, transcript boundaries, and sustained fresh evidence followed by expiry. See spinner repair evidence (`evidence/claude-spinner-verification.json`) and the earlier unread verification (`evidence/claude-status-verification.json`). `--claude-status-probe` emits only status flags, known marker enums and bounded scan counts, never identities, titles or messages.

## Unread/read

`CodexDesktopReadStateClient` reads only `electron-thread-read-state-v1` from the Desktop's persisted global-state JSON. It requires schema version 1, exactly one identity and one local-host namespace, valid bounded IDs, and an accessible source file. It ignores legacy migration lists and unrelated app state. The native app supplies at most 16 catalog-validated local IDs per poll, checks that Codex Desktop is running, and polls off the UI thread every two seconds while open (ten seconds in the background). Failures or ambiguous schemas disconnect to unknown. It never marks anything read when Spleen navigates.

This is a guarded private Desktop storage format, **not a supported public API**. A future Desktop schema change or multiple accounts/local namespaces can disable the adapter safely. Current unread=false observations agree with the assistant Desktop tool. The positive unread→read UI transition still requires the user's live check.

The generated app-server API also exposes top-level `readState` in `thread/read`, a field missed by the earlier Thread-only schema investigation. However, two real catalog chats were unread there while Desktop `list_threads.isUnread` and Desktop's persisted local marker set both reported read. Therefore that protocol field is deliberately not used as a mirror of Desktop's blue dot. The isolated app-server's runtime `notLoaded` remains unsuitable.

## Working and completed turns

The installed metadata-only Codex lifecycle hooks report actual pre/post model/tool events to `Spleen --activity-event codex`. `ActivityHookRepository` persists at most 128 metadata events for one hour with private atomic locked writes. It does not retain prompts, tool commands, replies, or transcript paths. The native app watches this journal and updates fixed card badges without moving their keyboard targets.

Working is a **15-second evidence lease from a real callback**, not an uninterrupted owning-runtime subscription. Concurrent tools/children are aggregated. Stop, interrupt and post events clear the relevant activity; missing callbacks expire to unknown. Long silent model/tool calls can outlast the lease and lose the spinner until another real callback. No heartbeat fabricates freshness.

The separate documented `notify` event `agent-turn-complete` records an exact completed-turn ID. Completion is not task completion, session-wide idle, or read acknowledgement. Its source provides no completion timestamp, so none is invented. Completion triggers a background catalog refresh for historical “Last reply” details.

`Stop` hooks are stop attempts: another hook can continue the turn. `PermissionRequest` occurs before approval resolution: another hook can auto-allow it. Neither is mislabeled as definitive completion or an outstanding user blocker. Exact long-running activity and approval/input coverage remain limited by available provider events.

Runtime, read and completion sources retain independent freshness, epochs and disconnection barriers. An activity-only sample cannot clear or refresh read evidence. Blue unread dots can coexist with working; completion can display a checkmark without inventing read state. Search and compass accessibility include badge text, and timer expiry uses common run-loop modes.

## Installation and trust

`scripts/install-activity-reports.py` was run for the existing app/data directory. It merged the twelve activity event groups without replacing other hook handlers. The original `notify` command is forwarded with its exact arguments, environment, stdout and exit status. Timestamped private backups of both configuration files are in `.local-state/activity-integration/backup-*`. An idempotence fixture verified existing hooks/notify, feature flags and backups survive repeated install.

Activity reporting is enabled in Spleen's journal. **Hook trust was completed by the user and real callbacks were verified on 5 November 2026.** The official [hooks documentation](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks) requires review of the exact definitions before they run; no trust records or bypass flags were changed. The current chat began emitting prompt, model-request and tool-use callbacks immediately after the user trusted the definitions. Other existing sessions may need their configuration reloaded or reopened before the new callbacks are used. The [completion notification](https://learn.chatgpt.com/docs/config-file/config-advanced#notifications) is forwarded separately.

The running Spleen settings screen was observed to report “Reading desktop unread markers” and “Waiting for Codex activity reports · review hooks in Codex.” This verifies adapter startup, not hook trust or a positive unread transition. After trust, the real journal received UserPromptSubmit, PreModelRequest, PostModelRequest, PreToolUse and PostToolUse from this chat. Spleen had no visible window during this follow-up, so this confirms callback delivery rather than a visible badge. The remaining acceptance checks are a visible working badge, an actual agent-turn-complete notification, and a recent Codex chat unread → viewed transition.

## Verification

### Picker visibility correction — 5 November 2026

A reported active thread in another project was already present in the catalog and sending real callbacks, but the ranking pushed the last Spleen-selected conversation behind every alternative. The user had switched elsewhere inside Codex, so that selection hint no longer described the visible conversation. Fresh working, unread, approval or input evidence now exempts that destination from the last-selection demotion. A different conversation still takes the center; the active last-selected conversation can occupy a nearby choice. Historical catalog activity and older Claude visits can no longer displace fresh live-attention choices. Pins, explicit search and frozen positions during an invocation remain intact.

Two regression tests reproduced the failures before the correction. All 170 package tests and 283 native checks pass afterward. A read-only replay of the real 553-entry cache and fresh activity journal placed the reported thread third, with working status, while retaining its last-selection hint. The native helper/watcher fixture now covers a crowded picker whose last-selected thread moves into view only on the next opening.

The release build and strict signature verification passed, and Spleen was relaunched with the existing `.local-state` directory. Its live accessibility tree then showed another Codex chat as the third compass choice with **Working**, alongside the current Spleen chat with its own **Working** indicator. This verifies actual callback-to-picker visibility, without dispatching either conversation. Saved destinations and context preferences remained byte-identical. The positive unread→viewed UI transition remains unverified. Evidence: `active-picker-before-tests.txt`, `active-picker-tests.txt`, `active-picker-live-replay.json`, `active-picker-native-tests.txt`, and `active-picker-verification.json` in `evidence/`.

Package regressions cover source isolation, expiry, restarts, old epochs/events, post-disconnect races, local unread schema ambiguity and malformed files, callback semantics, concurrent tools, old-turn completion, storage corruption and size bounds. Native tests exercise a real helper process → journal write → file watcher → model → badge, including completion and disabled-source clearing while card identities stay fixed. Package results: 168 tests passed. Native results: 280/280 checks passed. These helpers received synthetic provider payloads; no synthetic event was written into the real user's journal.

No Decisions API call or credential access was needed for this indicator work. The previously approved two-request trial remains a separate task awaiting a credential-file path.

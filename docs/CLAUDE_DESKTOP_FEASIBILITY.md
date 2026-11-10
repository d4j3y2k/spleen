# Current status — 5 November 2026

Claude Code now has working and unread indicators for the session displayed in its window, including while Claude is in the background. A separate opt-in status observer anchors enabled response/background-task controls to the exact open route. Sidebar read state also requires the current-page marker. Version 0.2.13 repairs a missing-spinner case that the initial sidebar-only check missed. The original foreground-only visit observer remains unchanged. See [live status coverage and verification](LIVE_INDICATORS.md#claude-desktop-code). The sections below preserve earlier investigation and version-specific results.

# Claude Desktop: Code workspace first, ordinary Chat separately

Checked **2026-11-04**, installed Claude **4.16336.0**. **Existing Desktop Code session reopening now passes a live roundtrip.** Spleen implements the narrow route as experimental support. The user's workspace is Claude Code inside Desktop, including local and SSH-backed sessions; ordinary Chat and terminal-only sessions remain separate surfaces.

## Accessibility approval repair — 5 November 2026

A newly opened Code session was missing because the running Spleen app was denied Accessibility access, even though its observation preference and the macOS Spleen switch were both on. The running Settings status remained permission-denied after resaving its unchanged settings. A helper launched from the privileged command environment reported allowed; that result did **not** establish permission for the separately launched GUI app.

With explicit user approval, the existing Spleen access was refreshed. Toggling off/on and restarting did not fix it. Removing only the Spleen entry and re-adding the current `build/Spleen.app` through System Settings, then saving Spleen's existing settings, changed the live GUI status to **Ready · waiting for a supported Claude selection**. The app is ad-hoc signed with a designated requirement tied to its current code hash; a stale build approval is consistent with these observations. No other app permission was changed.

Permission recovery alone is not a successful session-discovery check. Automated background window inspection did not produce a real activation. After the user brought Claude forward, the production observer accepted two visits to the new session at 19:10 local time on 5 November. Observation is now enabled in the user's settings; earlier statements that it remains off describe prior checks.

That successful discovery exposed a ranking defect: the newest observed Claude identity was treated as continuously current and put behind every other candidate. The newest eligible visit can now occupy a nearby compass position even if it is the last-observed selection, while a different destination remains in the center. An older visible Claude pin no longer satisfies the newest-visit reservation. Pins, live-attention choices, recent working choices and the reserved catalog-activity choice retain their protections. The promotion is labeled **Recently visited**, without claiming live runtime or unread state.

Two ranking fixtures reproduced this behavior before the correction; all 171 package tests and 284 native checks pass afterward. Native coverage also checks a newly observed Claude candidate in a crowded picker, frozen positions across background removal, and dispatch using the preserved candidate.

After rebuilding and verifying the signature, the existing approval was refreshed for the current app bundle and Spleen was relaunched with the same store. The live compass visibly included the newly visited Claude chat as its fifth choice, labeled **Claude · Last visited just now**. The production context store also recorded fresh observations after relaunch. Context preferences stayed byte-identical; the destinations file changed during the live session, so byte preservation is not claimed for it. The agent did not dispatch a provider conversation in this verification. This verifies permission repair → actual foreground observation → persisted candidate → live picker visibility; it does not add Claude runtime/unread badges. Evidence: `evidence/claude-picker-before-tests.txt`, `claude-picker-tests.txt`, `claude-picker-native-tests.txt`, `claude-picker-verification.json`, and `claude-new-session-permission-repair.json`.

## New decisive evidence: actual arrival, not merely dispatch

The investigation used two existing interactive Code sessions: A was local and B was SSH-backed. Only their identity/title and navigation controls were used for the test; real identifiers and titles are omitted from this document.

1. Verified distinct focused `AXWebArea` identities under `claude.ai/epitaxy/local_<UUID>` for A and B.
2. Opened the **actual sidebar row right-click menu** for both session types. Neither exposed Copy link. B's Open in submenu offered New window. The native File menu also had no session-link command. This is bounded evidence for these surfaces on this build, not proof of absence everywhere.
3. Because an app-generated link could not be obtained, explicitly revised the earlier conservative probe: constructed the URI using the firsthand-reported `claude://claude.ai/epitaxy/local_<UUID>` template and each independently observed Desktop identity. **These were constructed test URIs, not copied/app-generated links.** No engine ID, ordinary Chat ID, private record, or guessed UUID was used.
4. From B, entered A's URI in a fresh Safari tab and accepted the one-time “open Claude” prompt. The resulting focused Claude web area matched **A's original exact identity and title**.
5. Repeated reciprocal external dispatch **B → A → B → A → B**. Every dispatch reached the expected original identity. Each known sidebar row remained present exactly once; no duplicate row or new-session screen appeared. This establishes no *visible* duplication, not a private-database audit.
6. Restored B, the original selection, and closed the temporary Safari tab. No prompt was submitted, model invoked, session content edited, hook installed, permission changed, or persistent observation enabled. Safari's Always Allow option was not selected.

This supersedes “external Code reopening unverified.” It supports a **version-tested experimental adapter** for the observed route; it does not make that route an official public API. Cold launch, Claude restart, archived/deleted sessions, account changes, and future Claude builds were not tested. OS acceptance still never counts as arrival inside Spleen's context model.

**Spleen's own dispatch also passed.** A separately signed temporary copy of 0.2.7 loaded an isolated two-session context fixture with synthetic labels and the already-observed real identities. Discovery and persistent observation were off. Clicking the native compass invoked the unmodified `PanelController` → `NSWorkspace.shared.open` path: B → A → B reached both exact original identities, with one visible row per session. The temporary app was quit and its session fixture removed. This validates restored recents plus actual dispatch; the earlier real observer A → B → A probe remains the evidence for live AX attachment. No complete live observer-to-new-list-to-dispatch chain or Claude restart is claimed.

Validation: **111 Swift tests, 258 native checks**, release build, and strict signature verification passed. The native checks use temporary stores and injected external dispatch. The final 0.2.7 app was relaunched with the original explicit data directory, saved destinations remained byte-identical across that relaunch, and the new Settings checkbox was verified off. Identity-free experiment record (`evidence/claude-code-navigation-2026-11-04.json`).

## Bounded discovery decision

No supported external catalog API was identified. The [Desktop reference](https://code.claude.com/docs/en/desktop) describes an in-session cross-session listing tool; that is a model-mediated Claude tool, not an interface Spleen can invoke. Hooks describe engine activity, not foreground selection, and no supported engine-ID-to-Desktop-ID mapping was established. Sidebar titles alone cannot distinguish duplicates, so title-only scraping is unsuitable.

Spleen instead derives **recently visited Code sessions** from the existing opt-in Accessibility observer's accepted foreground observations: exact provider-qualified identity, bounded title, and observation time. It uses the existing 64-event/30-day context memory and persists through that store; it is not a complete catalog and may retain fewer than 64 sessions because other events share the bound. Lifecycle events cannot create candidates or pretend to be foreground visits. If shared-log eviction removes the last observation, that candidate disappears on a later prepared refresh.

Repeated visits and renamed titles retain identity; duplicate titles remain distinct. Saved labels and pins override observed metadata. Clear/disable recent selections removes these derived candidates. Removing a recent Code target uses a provider-qualified exclusion, so retained observations cannot immediately resurrect it; an explicit restore can make retained visits eligible again. No absence-based archive/delete inference is made. Stale unpinned visits expire, while explicitly saved targets survive provider absence and remain removable by the user.

Candidate construction, validation, merging, and expiry snapshots run off the shortcut path. The prepared neutral fallback retains valid visited destinations after the 30-minute attention hint expires. Existing choices and typed search remain frozen per invocation. Foreground visit time and background catalog activity remain separate signals; the previous cross-project latest-activity choice is preserved.

## Typed opener and saved-state boundary

`ClaudeDesktopCodeTarget` accepts only `claude://claude.ai/epitaxy/local_<UUID>` and emits the canonical form. Its key is `ConversationKey(.claude, "desktop-code:local_<UUID>")`, exactly matching the observer. It rejects ordinary Chat, mobile, web, new-session, parameterized, encoded, malformed, and other-host routes. The observation adapter itself remains metadata-only; the experimental opener is a separate capability.

Saving a Code destination uses saved-state schema **v3**. Legacy Codex and ordinary Chat entries retain their identity, labels, and pins; saving ordinary Chat after Code cannot downgrade the schema. Old builds reject/preserve the newer store rather than misreading a Code target. Manual links work without observation; learning visited sessions requires the existing explicit Settings opt-in and Spleen's own Accessibility permission. The user's current preference remains **off**.

## Earlier evidence and supported-interface limits

## Live Desktop Code evidence

The coordinating agent inspected the running app through its accessibility UI and reported a focused `AXWebArea` with a URL shaped like `claude.ai/epitaxy/local_<UUID>` and a title ending in `- Claude Code`. Named Code sessions were visible in the sidebar. The actual conversation ID and title are intentionally omitted here. This establishes a promising current-session identity surface in this installed build; it does not establish a complete catalog or an external opening route.

An AX URL under `/epitaxy/local_<UUID>` must not be rewritten to `/chat/<UUID>`, stripped to a bare UUID, or treated as a Claude Code engine `session_id`. Keep at least three distinct namespaces: ordinary Chat UUID, Desktop Code `local_<UUID>`, and Code engine session ID. Do not merge identities by title, project path, or matching UUID-shaped suffixes. `ClaudeDesktopObservation` parses the observed AX shape into an observation with key `desktop-code:local_<UUID>`; it has no navigation URL and makes no public API claim.

Earlier checks of the session header's **More Options > Open in** and sidebar menu obtained no permalink. Those checks did not dispatch a constructed URI and therefore did not establish that external reopening was impossible. The new live experiment above supplies that missing evidence.

## Official support for Code inside Desktop

Anthropic documents that Desktop runs the Code engine and that settings-defined hooks apply to Desktop and CLI. It documents reopening Desktop sessions through the sidebar. `claude --desktop --resume <session-id>` is a supported way to bring an existing **CLI** session into Desktop; that is not a documented way to resolve an AX `local_` ID, and it is outside this Desktop-only integration. The current reference does not document an external existing-Code URI opener. [Desktop reference: shared configuration and CLI transition](https://code.claude.com/docs/en/desktop#coming-from-the-cli).

Code lifecycle hooks therefore are relevant to the user's actual Code workspace. Their `session_id` and `cwd` can supply bounded engine metadata; session/turn events still do not prove selection, focus, or human attention. No public mapping from hook `session_id` to the observed Desktop `local_` ID was established. Hooks cannot complete the identity join merely because both IDs describe the same underlying task. [Code hooks reference](https://code.claude.com/docs/en/hooks#common-input-fields).

## Public issue evidence and opening uncertainty

A firsthand macOS report in Anthropic's repository says the Code sidebar's **Copy link** action produces `claude://claude.ai/epitaxy/local_<UUID>` and distinguishes that Desktop ID from the engine session ID. This is a user report in the official repository, not an Anthropic API guarantee. [Issue #101545](https://github.com/anthropics/claude-code/issues/101545).

A separate report says an exact `epitaxy/local_` link opened the destination through Windows OS dispatch but failed as an in-chat link; comments also report in-chat failures on macOS. These reports justify testing the app-generated link on this machine, not assuming either universal success or universal failure. No private storage, reverse-engineered bundle code, or reported private mapping should be used to fill the gap. [Issue #98386](https://github.com/anthropics/claude-code/issues/98386).

A later firsthand macOS report says OS dispatch of an `epitaxy/local_` link opened a scheduled Code run on Desktop 2.37337.1. Another commenter reports a similar result using an environment variable named `CLAUDE_CODE_HOST_SESSION_ID`. This is useful corroboration of a possible route, but neither a supported identity-mapping contract nor proof for this installed build and an ordinary interactive Code session. No environment values or private session records were collected. [October 15–16 comments on issue #102158](https://github.com/anthropics/claude-code/issues/102158).

The official `claude://code/{session-id}` existing-session documentation found in this review explicitly covers **iOS and Android**. It must not be applied to macOS Desktop by analogy. [Mobile deep-link reference](https://support.claude.com/en/articles/14898120-open-the-claude-mobile-app-with-a-link). The experimental Desktop opener uses the separately live-tested `epitaxy/local_` route, not this mobile route.

`ClaudeChatTarget` remains an ordinary-Chat adapter and intentionally rejects Desktop Code routes; `ClaudeDesktopCodeTarget` now handles the distinct Code surface.

## Implemented opt-in observation and remaining validation

`ClaudeDesktopObserver` is off by default and requires **Spleen's own macOS Accessibility permission**. A privileged Codex computer-use host seeing Claude's AX tree does not mean the Spleen executable has TCC access. Startup uses the non-prompting trust check; only an explicit permission action may request the system prompt. `start()` returns that observation is armed after the trust check, not that Claude is running or its AX notifications have attached successfully. Attachment and scans run on a utility queue, outside the shortcut path.

The adapter only targets active `com.anthropic.claudefordesktop` processes. It watches workspace activation/termination and supported focus/window notifications; it never launches Claude or polls. A scan starts at the focused window, visits at most 80 nodes through depth 8, and treats every web area as a leaf. It reads only roles/children needed to reach that leaf, plus its URL/title; it never reads message values, descends into transcript DOM, scrolls, or accesses the clipboard. Each request is checked against a 350 ms scan budget with a timeout of at most 100 ms or the remaining budget. OS messaging timeouts are not a hard realtime latency guarantee.

Notifications coalesce into the first scheduled read after 80 ms; additional notifications cannot keep pushing the deadline out. Every attachment gets a new callback identifier. Workspace changes and stop invalidate pending work/deliveries immediately, including a rapid leave-and-return to the same Claude process. Delivery checks Accessibility trust again, confirms that Claude remains active, and deduplicates only accepted identity/title pairs. Permission loss stops observation when next detected; no idle timer is introduced to monitor TCC. URL input is capped at 128 bytes. Titles are capped at 180 characters and 720 UTF-8 bytes, with bounded Unicode preprocessing to handle unusually large combining-character sequences.

Pure tests cover URL rejection, namespace separation, title limits, notification bursts, canceled reads, activation roundtrips, and delivery deduplication. An authorized foreground live check now verifies session switching: the existing notifications and bounded traversal captured four observations across two distinct Code identities and returned to the original selection in 15.2 seconds. The installed bundle reported version 4.16336.0. Existing Accessibility permission sufficed. Initial background-only automation probes correctly did not attach; a physical foreground step resolved the test setup. No broader scraping, idle polling, or new notification subscription was needed. Persistent observation remains off until enabled in Settings.

## Repeatable opener probe after Claude updates

1. Pick two already-existing Code sessions, A and B. Record only their current AX identity and bounded title. Prefer the visible sidebar **Copy link** action if present. If absent, the now-tested adapter can construct only the exact `epitaxy/local_` route from a validated observed identity; explicitly record that provenance. Do not substitute an engine or ordinary Chat ID.
2. Select B through its visible sidebar row and verify that the focused AX identity changes. This separately tests whether accessibility exposes actual selection.
3. Open the validated link to A through normal macOS URL dispatch. Do not send a prompt, invoke a model, install hooks, run CLI resume, or read app storage.
4. Compare the resulting focused AX identity with the original A identity. A match, with the existing session and no duplicate sidebar row, supports reopening that exact link on this build. An OS success return alone is insufficient. Stop after this single roundtrip if it no-ops, creates a new session, displays an error, or requires unexpected configuration.

If a future update breaks arrival, suspend claims for that version and retain the visible sidebar as a fallback. Observation and dispatch remain separate operations. The observer continues to read only current route/title, honor access permission, and avoid transcript scraping. Lifecycle hooks remain supplementary metadata until a supported engine-to-Desktop identity mapping exists.

## Ordinary Chat: what is established

Anthropic documents `claude://claude.ai/chat/{conversation-id}` for opening an existing chat, with a UUID corresponding to the chat URL. Invalid IDs may fall back to the chat list. The same document describes project links and **new** Code/Cowork sessions; it does not establish a route for reopening existing Code/Cowork sessions. [Official deep-link reference](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link).

An earlier read-only inspection of `/Applications/Claude.app/Contents/Info.plist` recorded version `4.4212.0`, bundle ID `com.anthropic.claudefordesktop`, and the registered `claude` URL scheme. That was scheme-registration evidence only. The current November 4 probe independently read version **4.16336.0** and separately verified Code arrival as described above.

`ClaudeChatTarget` accepts the exact `claude://claude.ai/chat/<UUID>` form and converts a supplied `https://claude.ai/chat/<UUID>` permalink into that Desktop form. Web-link conversion is a local adapter based on the documented shared conversation ID, not a claim that macOS itself sends HTTPS links to Desktop. It normalizes UUID case and surrounding paste whitespace. It rejects bare IDs, share/project/new/Code/Cowork routes, other hosts, credentials, ports, percent encoding, path traversal, queries, fragments, and trailing path segments. Validation establishes syntax, not existence, account membership, or successful focus.

## Ordinary Chat: discovery and observation remain unproven

| Required capability | Evidence and current status |
| --- | --- |
| Enumerate ordinary Desktop chats | No supported consumer Desktop catalog API identified in the official sources reviewed. Do not implement discovery using private storage or authenticated internal endpoints. |
| Know the selected chat UUID | No ordinary Chat selection event/API identified. Application activation, a title, and a requested URL do not establish conversation identity. |
| Read bounded topic metadata | User-supplied titles/topics are feasible now. No supported automatic ordinary Desktop title/topic feed identified. A visible title alone cannot reliably distinguish duplicate titles. |
| Open an existing ordinary chat | Documented deep link, syntactic validation implemented; successful selection still requires a live probe. |

These are evidence limits, not proof that no future or undocumented interface exists.

Claude Code hooks expose session/turn/tool lifecycle events and are documented to run for Code sessions inside the Desktop app as well as other Code surfaces. That does **not** document hooks for ordinary Chat, or events when the person switches between chats. A Code session ID must not be treated as an ordinary Chat UUID. [Claude Code hooks reference](https://code.claude.com/docs/en/hooks).

Desktop extensions package local MCP servers so Claude can access external tools and data. MCP tools are exposed by a server and invoked by a client/model. Neither source documents automatic disclosure of the host's selected conversation or its full catalog to an extension. A hypothetical tool that receives a user-supplied chat link/topic would be explicit registration, not passive discovery or reliable focus tracking. [Desktop MCP documentation](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop), [MCP tools specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools).

The extension manifest's documented substitutions supply package paths, standard user directories, and user-configured values. Its `_meta` field describes platform integration metadata, not live chat state. No current-conversation substitution or selection subscription is documented there. [MCPB manifest specification linked by Anthropic](https://github.com/modelcontextprotocol/mcpb/blob/main/MANIFEST.md). MCP initialization carries protocol version, capabilities, and `clientInfo` such as app name/version. These identify the client implementation, not an ordinary chat. The documented standard client capabilities do not include a chat catalog or selection notification. [MCP lifecycle specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle). An undocumented or experimental payload would require separate evidence and could not be assumed to track focus.

The Compliance API provides organizational chat/activity/file access and has Enterprise/Claude Platform eligibility and administrative enablement requirements. It is not a consumer Desktop discovery or selection API, and is outside this integration. [Official Compliance API overview](https://support.claude.com/en/articles/13015708-access-the-compliance-api).

## Minimum ordinary-Chat fallback

Accept explicitly supplied existing chat links with a local title and optional short topic, tag their provider as Claude Desktop, and dispatch the validated Desktop URL. Label any timestamp as a Spleen dispatch attempt rather than observed chat activity. Keep current-chat identity unknown until independently observed. Cache bounded metadata and ranking outside the shortcut path; do not require a model response to show the compass. An accepted OS open request must not be presented as proof of destination selection.

This ordinary-Chat adapter is not a complete automatic discovery experience. No fake catalog, guessed conversation IDs, or hook installation is included. Credential/transcript collection, private databases, browser storage, ASAR inspection, provider configuration changes, and model calls are not used by the integration.

## Optional ordinary-Chat probe

With two existing, user-selected ordinary chats and their known links, open each validated Desktop URI and verify the visible destination without sending a prompt. Check already-visible accessibility attributes for a stable URL/UUID and a bounded title; inspect at most the current window and selected sidebar item, without expanding transcript contents. If accessibility permission is absent, report that limitation rather than changing it silently. Record only whether a stable identity is exposed, which attribute carries it, and whether it changes correctly between the two known chats.

This probe is a hypothesis about UI observability, not a documented Claude integration. Stop if only a generic window title or unidentifiable selection is exposed. In that case retain explicit links and mark automatic selection tracking unavailable. A later supported Desktop connector API would be preferable to depending on UI structure.

> Update: [Live indicator adapters are now installed](LIVE_INDICATORS.md). The earlier “no production source” statements below describe the initial build; the linked update records the new sources, trust requirement and remaining limits.

## Session attention update — 5 November 2026

See [the implementation contract](SESSION_ATTENTION_IMPLEMENTATION.md) for bounded chronological message windows, separate inferred task/live runtime/unread states, stale-result rejection and trial activation. These message windows live in the separate relevance cache; `ContextMemory` remains metadata-only. Live indicators have a tested adapter entry point but no connected production Desktop source yet. Finished work is soft-demoted; hard exclusion remains disabled pending validation and requires fresh read+idle evidence.

# Local context and discovery contract

## Turn timing and future activity adapters

`TurnTiming` stores `lastStartedAt`, `lastCompletedAt`, and `checkedAt` from a bounded persisted-turn read. It is scoped and source-versioned through its enclosing `ThreadInsight` and cannot advance interaction/attention memory. Completion is accepted only for a successfully completed turn with valid source timestamps. Failed, interrupted, in-progress, unknown, future, and internally inconsistent completion timestamps do not establish successful completion. A newer started turn may legitimately follow the last completed one.

These timestamps are not live activity. A separate stdio app-server has its own loaded-thread view; a read-only probe found zero loaded threads and `notLoaded` for a chat simultaneously reported as active by Desktop. It also returned persisted status that did not describe the current live turn. Never map this process-local `notLoaded`, or a historical completion, to "idle", "done", or "your turn". A future activity adapter must observe the owning runtime, preserve the exact provider/host identity, expose its source/freshness, and expire to unknown on disconnection. [Official App Server documentation](https://learn.chatgpt.com/docs/app-server).

The intended ranking layers are lifecycle/attention candidate generation, task relevance and return-pattern ordering, then selection of a useful non-redundant set. Explicit approval/input blockers, freshly completed work, running turns, child agents, background commands, and monitors are distinct facts. Parent cards should aggregate their child activity. A completion is not automatically an outstanding user obligation; acknowledgement, later user input, a newer turn, and explicit provider blockers matter separately. Claude's current title/identity observer does not supply these lifecycle facts.

## Selection recency and display timestamps

After candidate discovery, `spleenDispatch` records from source `spleen` can independently refresh that known candidate's selection recency. They do not change its observed visit time or create a new Desktop identity. Cards distinguish **Last selected**, **Last visited**, and a source-verified **Last reply**. The most recent interaction timestamp is not silently substituted for reply completion. Recent recorded selections/visits form a 30-minute working set for ranking; this is a navigation heuristic, not a declaration of live running state or unfinished work.

## Existing identity and interaction contract

`ConversationKey` combines the provider (`codex` or `claude`) with its opaque conversation ID. IDs are never interchangeable across providers. The core does not assume a Claude Desktop discovery API or that Claude Code hooks describe ordinary Desktop chats.

Claude Desktop Code retains `desktop-code:local_<UUID>` as its opaque ID; ordinary Claude Chat uses its own UUID and Code engine IDs are not joined by suffix, title, or project. The experimental Code opener maps only this validated Desktop identity to the live-tested `claude://claude.ai/epitaxy/local_<UUID>` route. Dispatch still records intent; only an independent observed selection can establish arrival.

Recently visited Code candidates derive only from retained `selectedConversation` + `observedSelection` events whose source is exactly `claude-desktop-accessibility`. They contain the bounded observed title and visit time, not transcript text or inferred background updates. They share the 64-event/30-day context bound, so event eviction can shorten coverage. Saved labels/pins override derived metadata; duplicate titles do not merge identities. Clearing/disabling recents removes derived candidates. Provider-qualified exclusions prevent removed candidates from reappearing from retained observations. A prepared neutral snapshot keeps valid visits after attention expires; retention expiry uses a prebuilt fallback and an off-path refresh, never a new scan during shortcut opening.

`ContextMemory` is a metadata-only, Codable value. It stores no prompts, transcripts, credentials, or model replies. Adapters submit a conversation key, optional project path, event kind, observation time, short adapter/source identifier, and evidence category. A source identifier must be a fixed adapter label, not hook payload text.

Only these combinations advance interaction memory:

- `selectedConversation` + `observedSelection`: an adapter actually observed selection.
- `spleenDispatch` + `spleenInteraction`: the person selected a destination through Spleen. Dispatch is intent, not confirmation that the receiving app displayed it. The legacy `observedSelection` category is also accepted for this event kind, but never exposed as observed app selection.
- `userPromptSubmitted` + `inferredHumanActivity`: the adapter knows a human submitted a prompt. This is an interaction inference, not evidence that the conversation is currently viewed.

Session start, turn completion, thread updates, agent/subagent prompts, and background or unknown actor activity do not advance interaction memory. Adapters must label unknown/background actors as `background`; a hook event name alone cannot establish human origin. An adapter must not relabel lifecycle evidence as observed selection.

`currentHint(at:)` returns the latest known interaction while fresh (30 minutes); unknown or stale returns nil. Its evidence remains explicit. `latestObservedSelection(at:)` separately exposes a fresh actual selection observation, and never treats dispatch or prompt activity as a viewed conversation. It may return nil if its observation aged out of the bounded event log. Neither method proves the app is still foreground.

`previousDistinct(at:)` returns the preceding distinct interaction through the 30-day retention window, even if the current hint is stale. Repeated interactions with one key update its timestamp without moving the previous key. A → B → A is two transitions. A late event is retained as provenance but cannot rewrite an established interaction sequence. Different keys with equal timestamps have ambiguous ordering; the first accepted interaction wins. Exact duplicates are ignored. Future, expired, empty-ID, and oversized metadata events are rejected. Transition output contains only keys, evidence, and time; local ranking can map those keys to candidates and use opaque labels before any optional remote request.

Both the event log and distinct interaction sequence are capped at 64 entries, retained for at most 30 days. Queries filter expired entries without needing disk IO. `prune(now:)` physically removes expired data; the application should call it during off-path maintenance and before persisting. Decoding validates version 1, bounds, identity metadata, evidence, and interaction order. Disabling recents immediately clears both histories; re-enabling starts empty. `clear()` does the same without changing the preference. The app owns persistence outside the panel opening path and must not rehydrate cleared state from another cache.

`DiscoveryPolicy()` defaults to automatic metadata discovery across local project folders. `legacy(folders:)` preserves exact-folder selection, including an explicitly empty scope. An existing store must migrate with this helper rather than silently widening scope; the person can explicitly switch it in settings. An absent store may take the automatic default.

`allows(folder:key:)` applies exact-folder matching (when selected), excluded folders including descendants, and provider-qualified excluded IDs. Paths are lexically standardized without filesystem access or symlink resolution; adapters must supply consistent canonical project metadata. Relative paths are rejected. Automatic discovery does not authorize transcript or summary reads. Pagination defaults to four pages of 50 entries (hard policy bounds: ten pages of 100). Cache lifetime defaults to five minutes (bounds: 30 seconds to one day). `shouldRefresh` is a scheduling predicate; protocol IO, cache writes, and optional insight reads belong to the application’s background refresh path, never the shortcut-open path.

The core installs no hooks and edits no provider settings. Hook integrations must be explicit and separately verified. In particular, lifecycle completion is not a viewed-thread event.

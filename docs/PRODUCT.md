# Product brief

**UI update, 6 November 2026:** the compass now lives in one softly tinted native panel with a consistent teal selection, compact provider marks, contextual key hints, and a quieter selected-conversation preview. Search, settings, and the conversation editor share the same typography and surfaces. Compass positions and keyboard navigation are preserved.

**Desktop interaction update, 4 November 2026:** the native landing is a quiet compass: shortcut opens with center selected, arrows choose fixed neighbors, Space/Enter opens, Escape cancels, typing searches. The center recommends a different conversation from the last known selection, using previous-distinct history, topic/project relevance and recency. Pins occupy nearby choices unless their relevance independently wins the center. The last known selection stays searchable and follows alternatives. Context can combine explicit Spleen choices with optional observed Claude Desktop identity/topic. Code workspace context does not imply a supported Code opener. Automatic Codex discovery replaces per-project setup for new stores, with explicit migration of existing scope. End-to-end usefulness and public-release readiness remain unmeasured.

**Current status, 3 November 2026:** saved and folder-discovered chats use a prepared local search and relevance snapshot. Short excerpts from recent conversational turns add topic information beyond titles. The last Spleen-selected thread supplies topic/project context; this is a known selection, not an observation of the current Codex thread. Background refresh builds the next snapshot while the open list stays fixed. Decisions remains disabled. [Implementation status](IMPLEMENTATION.md) records measurements and test coverage. Actual relevance benefit, end-to-end navigation speed, and voluntary use remain unmeasured. The original first-slice proposal below is retained for context; its metadata-only privacy boundary and future targets describe that earlier proposal.

## Thesis

Spleen reduces the effort of returning to a useful context. Its unit is a **destination**, initially a specific Codex thread, rather than an app window or a generated answer. The user supplies the final intent by choosing a result.

The important hypothesis is that a short, stable list of likely destinations beats navigating an app sidebar. A prediction system is useful only if it improves that interaction. It need not be part of the first version.

The provisional first job is **return to a known personal thread**. “Find an unsaved thread” depends on catalog coverage; “show what needs attention” depends on trustworthy activity and intent signals. These are different product claims. Neither is established by the current evidence, so neither belongs in the first prototype's promise.

## First experience

1. The user saves a few personal Codex thread links and gives them recognizable labels.
2. A configurable global shortcut opens a compact panel on the current display.
3. Up to five destinations appear immediately from a local snapshot: up to two fixed pins, then recent Spleen selections without duplicates. Before there is history, preserve saved order. The user can type to search all saved destinations; pins do not displace matching search results.
4. Up/down changes selection; Return or a click opens it; Escape dismisses the panel and preserves the prior context. Modified shortcuts may provide direct selection after testing for conflicts.
5. Opening uses the saved `codex://threads/<thread-id>` URI. Spleen records the selection locally, not the contents of the destination.

Use restrained typography, a readable title, a small project label, and a factual reason such as “Opened recently.” Avoid a chat composer, explanatory paragraphs, novelty animation, or numeric confidence scores. An optional footer can say “Saved links” or “Last refreshed…” when useful.

The panel's ordering freezes while it is open. A background update can affect the next invocation; it must not move a row beneath a click or change what Return will open. Typed queries update search results deliberately, preserving selection by destination ID when possible.

## Initial boundaries

The first version opens known destinations. Later candidates might include user-saved folders and app shortcuts, each through a narrowly defined opener. “Actions” initially means navigation. Running commands, changing files, sending messages, and autonomous task initiation are outside the first prototype.

Spleen does not need to modify Codex, scrape its UI, ingest every conversation, or read clipboard or screen contents. A paste into Spleen's explicit “Add destination” form is different from background clipboard monitoring. App activation notifications can provide coarse context later; they cannot identify the active Codex thread.

No automatic window switching, hidden prompting, or foreground API wait. If a provider fails, saved destinations and local search continue to work. If no candidate is good, typing or dismissing remains easy.

## Learning and privacy

Start with explicit Spleen selections, not inferred intent. A Codex thread update timestamp records thread activity, not when the user visited it. A dismissal is ambiguous and is not automatically a negative label for every visible result. An open request is a dispatch event, not proof that the user reached or wanted that destination.

Keep a rolling, local record of impressions and chosen IDs only when needed to evaluate ranking. Default proposal: 30-day retention, explicit pause and clear controls, and no raw query retention. These are design proposals to validate in the first prototype.

Any later provider should have an explicit personal-project allowlist. Employer context and unrelated projects are excluded by default. Any future remote inference must show the exact categories of data being sent and use the minimum necessary context.

## Success and falsification

For a personal trial, measure:

- Time from shortcut to destination dispatch, plus a small manual sample of time until the destination is visibly ready.
- Fraction of intended destinations in the first three results; search use and cancellation rates.
- Local render latency, CPU while idle, total memory including helper processes, and stale-result frequency.
- Whether the user voluntarily uses Spleen over a week instead of existing Codex search and recent-thread shortcuts.

Separate three outcomes in a small manually labeled sample: **coverage** (intended destination is saved), **ordering** (it appears in the first three given that it is saved), and **arrival** (selection visibly reaches the intended chat). Count missing destinations as misses in end-to-end top-three success; do not silently omit them. Selection logs are a proxy for intent and are biased by the order shown. Annotate a few search failures and dismissals manually without storing query text.

Manual setup has a cost. Record time to save the initial set and later maintenance. A suggested trial gate is at least 80% coverage of sampled intended returns; below that, test supported discovery before refining prediction. This is a proposed personal-product threshold, not a measured result. A good result in a curated set does not establish usefulness across the entire desktop catalog.

Targets are proposed, not measured: warm panel p95 under 75 ms; p99 under 150 ms; local search under 30 ms for 1,000 destinations; destination dispatch under 50 ms after selection. Codex launch or navigation time is reported separately. Aim for under 100 MB steady-state total memory, then revise based on measurement rather than adding an expensive permanent helper by default.

Spleen should become a simpler saved-context launcher if prediction does not beat recency/frequency. If the app's built-in search is consistently easier, that is a valid stop result.

## Questions for the first trial

These are product choices, not blockers to the current plan:

- Is returning to known threads the right first job, or is attention triage the essential value? The latter requires a different evidence gate.
- Which 5–10 personal local threads form the first set, and is saving/maintaining them acceptable?
- Which shortcut and display placement feel natural? Proposed defaults: a user-chosen collision-tested chord and the pointer's display.

Use up to two fixed pins for the trial. Decide automatic-provider scope and coarse app-context retention only if those later experiments are justified.


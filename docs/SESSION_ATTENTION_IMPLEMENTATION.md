> Update: [Live indicator adapters are now installed](LIVE_INDICATORS.md). The earlier “no production source” statements below describe the initial build; the linked update records the new sources, trust requirement and remaining limits.

# Session attention implementation — 5 November 2026

The native app now retains bounded chronological user/assistant message windows alongside its old recognition excerpts. These carry provider/host identity, source update version, message IDs/order, and explicit truncation/incomplete flags. Commentary and tools do not become final replies. The latest unanswered user input is locally ongoing; inferred completion never stands in for runtime or unread state.

## Implemented

- Background enrichment reserves four of eight reads for newest catalog entries independently of the five-card/eight-candidate ranking shortlist. Old caches backfill message windows; ordinary saved destinations, labels, pins and context preferences retain their existing storage contract.
- Decisions task assessment has four outcomes: ongoing, waiting for user, appears finished, unclear. Each request contains one bounded recent conversation, at most 6,000 encoded bytes. Any compaction explicitly marks incomplete evidence and prevents a finished classification. The response validator checks question, options, normalized finite probabilities, confidence shape and a unique winner. This validates protocol correctness, not classifier quality. An appears-finished choice also needs at least 70% probability; weaker ones stay unclear and are not demoted. The 70% is a starting guess, not calibrated on labeled sessions.
- Exact content/prompt versions avoid repeated classification on metadata-only changes. Full source-version equality rejects late results; new input immediately invalidates earlier completion. The app processes one request at a time, at most 20 attempts per launch, over at most 16 recent available windows. The durable trial ledger additionally caps requests across launches.
- Ongoing/waiting tasks get priority; appears-finished tasks get a soft demotion. Hard suppression is implemented but **disabled** pending classifier evaluation. Even when validated, suppression requires fresh, known read + idle state newer than the assessed messages, and cannot remove pins. Suppressed rows remain searchable.
- Separate live-state samples include exact identity, local host, source, sequence, observation and expiry. Unknown fields stay nil. Older, future, wrong-host and stale samples are rejected. Read/unread, working and approval/input are independent of prose. Blue dot, working spinner (static under Reduce Motion), and amber blocker badges render on fixed cards with accessibility labels. Expired samples disappear; navigation does not manufacture acknowledgement.
- A visible compass keeps its identities, ordering and selected item while badges/assessments update. Reordering applies on the next invocation.
- Fixed the dormant remote pin-before-center bug and excluded the local current conversation from the app's model shortlist. Fixed saved generic labels masking fresh observed topics, expired context resurrection through a 30-day fallback, and cached ranking overlooking individual 30-minute working-set expiries. Boundary snapshots are prepared in the background and selected by binary search during opening.

## Current integration boundaries

Codex's live sources are now connected: guarded Desktop unread-marker polling and trusted lifecycle callbacks. A live Spleen check verified an active thread in another project thread appearing among the five compass choices with its Working badge after correcting last-selection demotion. Working callbacks have a 15-second freshness limit and do not supply a continuous runtime subscription; the positive unread→viewed UI transition still needs verification. The assistant-side Desktop list is not a standalone Spleen transport, and the isolated app-server's runtime state is not used for badges. Claude's existing observer remains title/identity/visit only. See [Live indicators](LIVE_INDICATORS.md) for the current sources, installation, tests and remaining limits.

## Finite Decisions review and activation

Normal launch makes zero paid requests. The [official Decisions guide](https://developers.openai.com/api/docs/guides/decisions) was checked for `gpt-6-luna`, `input_json` and choice schema. No credentials were searched for and no API requests were made during implementation.

`Spleen --data-dir /absolute/state --export-attention-trial /absolute/review` reads at most eight recent scoped sessions through the existing read-only client, exports at most two complete answered windows, and writes exact request JSON plus `trial.json`. This is local-only; requests contain conversation text and must be reviewed before transmission. The manifest allows only those exact request hashes, at most two requests, and expires after 24 hours. The review files use private directory/file permissions.

After explicit approval and a user-supplied credential file, launch with `--attention-trial /absolute/review/trial.json --attention-credential-file /absolute/key-file`. The app never searches for a credential. A changed conversation produces a different payload and is rejected by the exact-payload transport. The durable ledger prevents retries from exceeding the allowance. Model quality, false-exclusion rate on real labeled tasks, paid latency and account access remain unmeasured. Hard suppression stays disabled for this trial.

## Verification

Regression fixtures cover unanswered requests, incomplete and compacted text, provider/host/order identity, stale responses, unread final results, working/blocker protections, pins, search retention, clock/expiry boundaries and exact-payload admission. Native app checks exercise injected asynchronous classification and live samples, fixed card positions, next-opening ranking, and search. Native light/dark previews use explicitly synthetic badges; they are not evidence of a live Desktop feed.

Final package verification: 138 tests passed. Native verification: 273/273 checks passed. Native light/dark previews were rendered and visually inspected. These counts include synthetic protocol and UI integration tests, not real Decisions accuracy or a verified live Desktop feed.

## In-app reviewed assessment (November 7)

Settings → Decisions assessment → Review selected conversation snapshots the selected Codex window and shows the exact JSON before one explicitly approved request. A file chooser reads the approved `.env.local` or a raw-key file in memory; it does not save or print the key. Credential files must be regular, non-symlink, owner-only files. Normal launch still has no remote transport and sends nothing automatically.

The result goes through the same versioned parser, stale-window check, local assessment cache and next-opening ranking as the background adapter. Stop discards late results; errors are not retried. Visible compass positions remain fixed. Each manual request gets a one-request durable ledger and expires after 60 seconds. The background HTTP timeout for this path is five seconds, while opening/search never waits for it. The ranking adapter retains its separate 750 ms deadline.

Core prompt version v2 rejects missing user-request evidence, distinguishes unresolved work from an unanswered necessary user decision, and resolves old approval questions using later replies. Full transcripts, runtime activity and unread status are not inferred. No hard hiding is enabled.

Three live fictional cases returned the expected labels: ongoing (94%, 524 ms), waiting for user (83%, 197 ms), appears finished (71%, 244 ms). These are end-to-end request timings from one small smoke test, not a latency benchmark or an accuracy claim. Total usage: 1,055 uncached input tokens, $0.0001055 at the documented base rate. No additional private conversations were transmitted.

## Assessment on open (opt-in, November 7)

This replaces the earlier 24-hour all-sessions trial. That trial started with every unassessed session in the discovery scope, so its 100-request allowance would have run out on old conversations within a few minutes of being turned on.

Settings → **Assess cards on open…** is a standing opt-in. After consent and a chosen key file, each press of the Spleen shortcut assesses only the local Codex cards in the compass at that moment whose message text changed since their last assessment. Cards you don't see are never sent; Claude remains metadata/status-only. Turning it on sends nothing by itself, and launch sends nothing.

- **What is sent:** the existing recent-message source (up to three turns/six messages, 6,000 bytes per request), never screenshots or tool/reasoning output. Known credential-like text, incomplete/compacted windows, unanswered input, and sessions that are working or awaiting approval/input are skipped. So are sessions where Codex activity (a new message, model call or tool) is at least one second newer than the retained messages: those messages refresh only when a turn finishes, and working signals last just 15 seconds. Such cards show "Work ongoing" until the next turn's messages arrive. Secret screening is conservative, not guaranteed sanitization.
- **When:** the press records its Codex cards. Requests run one at a time, in the background; opening never waits. A press's cards are finished even if the panel closes, but nothing is sent more than 30 seconds after that press. Labels update on the open cards; order changes apply at the next opening.
- **Caching:** the version includes message identities/text and prompt version, not catalog timestamps. Cached assessments survive metadata refresh gaps and restarts; new messages invalidate them, so a typical press sends 0–1 requests.
- **Cap:** at most 100 requests per local calendar day, enforced by a durable per-day ledger in `assessment-ledgers/` that survives restarts and resets at midnight. Ledgers older than yesterday are removed. When the cap is reached, nothing more is sent until the next day; affected text is retried then. Other failed/uncertain requests are not retried during the same run.
- **Consent:** `assessment-on-open.json` stores the consent ID, daily cap and key file path (owner-only), never the key. Pause cancels pending work and persists the disabled state; turning it back on needs a new consent action.

No permissions, approvals, or external agent actions are inferred from model output.

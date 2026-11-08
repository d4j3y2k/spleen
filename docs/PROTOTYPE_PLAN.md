# Staged prototype plan

**Implementation update, 2 November 2026:** the user subsequently authorized the first native slice and explicitly skipped the pre-build paired-navigation study. That slice is built; see [implementation status](IMPLEMENTATION.md) for tests and remaining integration checks. The staged plan below is retained as research history and future evaluation guidance. Monitoring, credentials, and API calls remain outside the authorization.

## 0 — Verified setup and navigation gate

The project is registered at `<repo>`. **Plan Spleen prototype** (`<thread-id>`) is verified in the project on host `local`, with matching execution directory. The original projectless task's failed move is retained in the feasibility history and is no longer a blocker. No git repository, commit, or remote has been created; choose repository setup when implementation begins.

**Highest-value next experiment, not yet run:** select 5–10 personal local Codex thread links explicitly, using short recognizable labels. Record how each ID/link was obtained; do not assume a convenient copy-link UI exists or use private storage to obtain one. Agent-supplied IDs can bootstrap a test but do not prove a self-service onboarding flow. This verified local planning thread can be one user-approved target; the historical `durable` task is not a local-routing test.

First verify every saved link visibly reaches the intended chat, with Codex already open, and repeat a representative link after relaunch. Use user observation; the prior restriction on automating Codex's UI remains in force. Record invalid/deleted-link behavior when a suitable test target is available. OS URL acceptance is insufficient.

Then perform 10 paired return tasks against the user's best existing navigation method, alternating which method goes first. Record setup time, navigation time, visible arrival, and errors by target ID; no screen recording or query retention. A manual saved-link list isolates navigation feasibility, not hotkey latency or the future overlay's benefit. Stop to repair routing if any target opens incorrectly. Proceed to the native shell only if links work and the baseline leaves a useful opportunity to reduce navigation effort. This navigation trial goes beyond the current read-only planning scope and remains proposed work.

**Exit:** setup is already verified; next obtain a bounded destination set, demonstrated local routing, and a baseline to beat. If link acquisition is impractical, investigate a supported import path before building a polished shell.

## 1 — Prove the interaction with saved links

Build one small Swift app: menu-bar access, configurable hotkey, NSPanel with a SwiftUI search/list view, local saved destinations, up to two pins, MRU selection history, explicit selection, and URI dispatch. Include add/rename/remove so the saved set is maintainable. The app renders a cached list and needs no Codex process or API request to open the panel. Defer fuzzy search, transition learning, provider polling, SQLite, helper processes, and inference.

Test focus, text input, keyboard navigation, dismissal, mouse selection, duplicate titles, invalid/deleted links, dark/light appearance, increased text size, VoiceOver labeling, multiple displays, Spaces, full-screen apps, and wake. Exercise shortcut conflict handling and retain a menu-bar fallback. Measure app-open and destination-open latency separately.

**Exit:** 20 repeated open/select/dismiss cycles without focus theft, wrong-target activation, or moving rows; a known test thread opens visibly. Separately measure at least 100 warm invocations for a provisional p95, reporting sample count and range; do not claim a reliable p99 from this small sample. Repeat the paired tasks with the actual overlay. Proposed usefulness gate: at least 20% lower median time to visible arrival, no added wrong-target arrivals, and voluntary use over the following week. These are decision heuristics, not statistical proof. If this fails, fix interaction or stop before adding prediction.

## 2 — Establish a local ranking baseline

Extend MRU history with the recency/frequency comparison and bounded impression logs. Keep query contents unrecorded. Record only enough to compare rankers: candidate IDs/order, feature snapshot before selection, snapshot/ranker version, selected ID or dismissal, dispatch result, and timings. Let the user pause and clear history.

Collect roughly 50–100 deliberate uses, or about a week of ordinary personal use. Compare MRU, frequency, and a simple weighted combination using chronological held-out events. Do not tune on the same events used to report improvement. A dismissal has no assumed correct target. Keep a small manually annotated sample to assess actual intention and search failures.

Report catalog coverage separately from top-three accuracy conditional on coverage, and report end-to-end success including missing targets. Keep pins and candidate eligibility fixed across comparisons. Reconstruction must use only history and candidates available before each event; do not leak the selected ID into its own recency features. If coverage is below the proposed 80% gate, prioritize the bounded discovery experiment instead of ranker tuning. With only 50–100 uses, prefer a simple policy unless improvements repeat across days.

**Exit:** one reproducible baseline report with top-1/top-3 hit rates, search/cancel rates, time to selection, memory including helpers, and idle CPU. Keep the simpler policy if differences are inconclusive.

## 3 — Bound the Codex integration experiment

Treat three questions independently: catalog visibility, navigation, and live activity.

1. Record desktop and CLI versions and generate schemas from the chosen binary.
2. Establish a documented supported connection. Do not discover private credentials, patch internal state, or install/start a persistent daemon as an incidental setup step. A separate stdio process may be considered as a bounded integration experiment, with its startup side effects understood and no generation calls.
3. Against one known personal test thread, compare a default list with a narrowly filtered explicit-source list and then `thread/read` with `includeTurns: false`. Use `useStateDbOnly: true` for listing. Keep page limits small; stop once coverage is established. Do not collect every conversation to test one ID.
4. Validate that the listed technical ID opens that same desktop thread. Compare the displayed title manually.
5. Test whether the connected server observes a known desktop turn changing state. If it does not, retain catalog discovery but label activity unknown. A second process returning `notLoaded` is inconclusive, not a completed/idle signal.
6. Repeat after desktop restart and with an unavailable provider; verify cache behavior and graceful fallback.

The current setup has no default control socket, and UI automation is denied. Those limitations remain explicit. Agent-side `list_threads` is not proof of an external Swift API.

**Exit:** a compatibility matrix for the exact installation with separate pass/fail/unknown columns for discovery, navigation, and live status. Ship only the capabilities that pass. If discovery remains unsupported, saved links are a complete fallback, not a reason to access private databases.

## 4 — Test coarse context only if useful

Try transient foreground bundle ID from NSWorkspace and Spleen's last selected destination. Do not read window titles, screen contents, browser tabs, or clipboard. Ignore Spleen's own activation and avoid counting its overlay as a context change.

Compare against the phase 2 baseline. Retain context only if it improves useful ordering without surprising jumps or an unjustified privacy cost. Keep a pause switch; minimize or eliminate retained raw activation history.

**Exit:** measured incremental value, or remove the extra signal.

## 5 — Optional Decisions comparison

Before any call, obtain separately authorized API access and spending, select an explicit trial budget and request cap, and show the minimal payload. Do not retrieve or configure credentials merely because a model experiment appears in this plan.

Use a short candidate list and a “none” option. Initially run in shadow mode: the local baseline determines the visible order, while a background result is logged only for comparison. Include timeouts, refusals, malformed responses, late responses, unavailable candidates, and context changes in the evaluation. Keep one in-flight request and do not blindly retry timeouts that may have been processed.

Compare on the same held-out choices: top-3 lift, latency/freshness, cancellation/search burden, total input tokens, requests, and estimated/actual spend. The candidate generator must be identical across conditions. Offline replay is useful but cannot establish how reordered choices change user behavior; follow promising results with a small opt-in alternating trial.

Use the same fixed pins and full candidate set for both policies; measure unpinned ranking separately to expose ceiling effects. Report two model results: quality when a valid result was ready at invocation, and deployed-policy quality over **all** invocations with local fallback for late/missing results. Shadow requests started at invocation cannot count as ready for that invocation. Offline replay must use only pre-choice inputs and measures ranking potential rather than deployable benefit. Count stale, unused, refused, and failed requests in cost and readiness reports. Do not send the eventual selection or later context as model evidence.

Suggested continuation threshold: at least a 10 percentage-point top-3 improvement over the best local baseline, with no interaction latency regression and enough observations to distinguish a real improvement from a few lucky events. This is a starting decision rule, not a statistical claim. If there is no clear improvement, retain the local product.

Apply that threshold to the deployed policy, not only successful API responses. If baseline top-three accuracy is already above 90%, this gate has little or no room; skip the experiment unless a different primary outcome, such as top-one accuracy or selection time, is chosen in advance. Show paired wins/losses and uncertainty, and confirm promising lift on later days before enabling visible reranking. A model cannot repair a missing destination or infer unobserved intention merely from an API confidence score.

**Exit:** explicit keep/remove decision for remote inference; no perpetual background calls by default.

## 6 — Personal daily-use hardening

Only after the interaction has earned repeated use: error recovery, storage migration, crash diagnostics without content, stable signing/build packaging, startup preference, energy measurements, and clear settings. Keep launch-at-login opt-in. Avoid auto-updaters and distribution infrastructure until there is a distribution need.

**Exit:** a dependable personal utility with documented supported integrations and no hidden coupling to other projects.

## First implementation decision

The original recommendation was to run phase 0 before phase 1. The user chose to build phase 1 directly; the first slice is now implemented with manual links and no model. This isolates whether a shortcut-driven switcher makes returning to known contexts easier. Manual curation remains provisional: poor coverage should move discovery earlier; poor interaction should stop expansion; strong local performance can make Decisions unnecessary.

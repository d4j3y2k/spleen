# Matching review — 4 November 2026

Spleen currently combines a recent-navigation rule, a weighted word-overlap ranker, and several rules for arranging five visible choices. It has no learned local model, embeddings, or enabled remote inference. Its strongest existing foundation is the background preparation and frozen presentation. The main opportunity is better evidence and a consistent definition of a useful next return.

This review inspected the current source, ran all 122 Swift package tests successfully, and added eight reproducible behavior probes. No production source, user settings, provider data, or running app was changed. The probes characterize existing behavior; their results do not measure recommendation accuracy. See probe source (`evidence/matching-review-probes.swift`), results (`evidence/matching-review-probes.json`), and test output (`evidence/matching-review-tests.txt`).

## What runs today

1. **Discover destinations.** Merge saved labels/pins, scoped Codex catalog metadata, and retained observed Claude Desktop Code identities. Ordinary Claude chats can be saved explicitly. There is no complete Claude catalog. Identity includes provider and the exact conversation ID.
2. **Add available text.** Codex gets a title plus up to three short fields extracted from recent turns. These fields use text prefixes and sentence keyword checks, not semantic summarization. Claude candidates have their labels/observed titles. Project and provider names are also searchable.
3. **Choose a context.** Prefer the latest fresh interaction hint, which normally comes from a Spleen dispatch or opt-in Claude observation. If its identity matches a candidate, use that candidate's text. Without a fresh hint, the ranker can fall back to the most recent saved dispatch from the last 30 days. This is last-known interaction, not live Codex focus.
4. **Choose a center.** Exclude the last-known current candidate if alternatives exist. A recorded Spleen selection or observed Claude visit within 30 minutes beats every candidate outside that window; the most recent qualifying candidate wins. Otherwise, use the score below. A lone current candidate remains available.
5. **Arrange the other choices.** Pins precede the remaining candidates. Where eligible slots exist, bring the latest catalog activity into the fifth slot, preferring another project, and retain a recently observed Claude alternative. These rules protect the center, pins, and recent working candidates. They are set-composition rules, not score components.
6. **Freeze on opening.** The UI copies a prepared snapshot. Typing uses exact title, title prefix, title substring, then all query tokens appearing anywhere in the combined text. No fuzzy or semantic search is implemented. Background updates normally apply on a later opening.

The fallback score in `Relevance.swift:218–227` is:

| Signal | Contribution |
| --- | --- |
| Same canonical project path | +10 |
| Previous distinct conversation | +12 |
| Shared title/excerpt terms | `min(14, 2 × Σ log(1 + candidateCount / documentFrequency(term)))` |
| Last selection/visit recency | `max(0, 8 − ageInDays)` |

This formula does not determine the whole ordering: the recent-use rule takes precedence, and visible-slot rules run afterward. One minute and six hours ago get approximately 8 and 7.75 recency points. One day ago still gets 7.

Primary implementation locations: [Relevance.swift](../Sources/SpleenCore/Relevance.swift), [PreparedContext.swift](../Sources/SpleenCore/PreparedContext.swift), [AppModel.swift](../Sources/Spleen/AppModel.swift), [Context.swift](../Sources/SpleenCore/Context.swift), and [ClaudeDesktopRecents.swift](../Sources/SpleenCore/ClaudeDesktopRecents.swift).

## Findings and their implications

**1. Word overlap can reward conversational filler as strongly as task meaning.** The stop list leaves `let`, `yeah`, `make`, `them`, and `were`. There is no field weighting or document-length normalization, and the score saturates quickly. In the 103-candidate probe, an unrelated conversation sharing only `yeah let` earns 14 topic points and beats a SQLite conversation sharing `SQLite`, which earns 7.92. The earlier real audit (`evidence/ranking-design-audit-2026-11-04.json`) likewise shows full scores from generic shared words. That audit records an explicitly unwanted center conversation; it does not identify a preferred next destination. The newer 30-minute working-set rule helps recent navigation but leaves this fallback intact.

**2. The working set has a cliff, and its cache does not track every cliff.** With a fresh current hint, a different conversation visited 29m50s ago wins automatically. Twenty seconds later it loses that priority and, in the probe, a related conversation wins. But the previously prepared snapshot still returns the old center and reports itself fresh. `PreparedContext` expires at the current hint's deadline or Claude identity retention; it does not expire when each working-set member crosses 30 minutes. Thus refresh timing affects ranking even for identical evidence and evaluation time. This is distinct from the intentional freeze while a panel is open.

**3. Expired context can return after a rebuild.** When a prepared current hint expires, its fallback removes inferred current project/topic. Rebuilding from the same evidence then uses `lastOpenedAt` through the separate 30-day legacy path. The probe changes center solely because of that rebuild. `Relevance.swift:197–203` and `PreparedContext.swift:75–85` need one shared policy for how long a dispatch may establish current context. Retaining historical recency for 30 days need not retain current-context authority for 30 days.

**4. Saving a generic label can erase useful observed context.** `activeRow?.terms ?? observedTopicTerms` chooses the matched row even when its label is uninformative. The probe's observed “SQLite WAL locking transaction contention” correctly promotes the related chat until the observed identity is saved as “Main”; then an unrelated recent chat wins. Keep display labels separate from task evidence, and combine valid fresh observed text with the matched candidate's text.

**5. Topic coverage is uneven and changes during refresh.** At this review's final read-only cache sample, 128 of 548 visible Codex entries had current excerpts: **23.4%**. The remaining entries rely on titles for topic matching; Claude has no message excerpts. Any catalog `updatedAt` change immediately invalidates the old excerpt. The probe shows a topic-search hit disappearing until replacement text arrives. Enrichment handles at most eight entries per batch, prioritizing the latest selection and already-visible suggestions. That creates a potential exposure advantage for existing suggestions; it is an inference from the policy, not a measured feedback-loop effect.

**6. Interaction history is recorded but barely used for prediction.** The local score uses the previous distinct conversation, not repeated transition counts or return frequency. Ten additional A→B transitions do not change ordering in the probe when the latest pair and relevant timestamps are held fixed. The final sampled cache contains 63 retained transitions, but the 64-entry bound and mixed event sources limit the amount of evidence. Counts need recency decay, source awareness, and a minimum-support policy before they deserve much weight.

**7. There is no explicit “stop suggesting this” state that preserves searchability.** A user can remove/hide a candidate, but the current destination model has no suggestion-only suppression, snooze, or user-confirmed retirement. A completed reply is shown as a historical timestamp and does not establish that a task is finished or awaiting attention. The unwanted-center example would benefit from a direct, reversible preference instead of trying to infer task status from prose.

**8. The optional remote adapter needs integration changes before enabling.** The shipping app supplies no transport. Its dormant adapter selects the first eight unpinned candidates and can promote a unique winner. On successful promotion, `RankingPipeline.snapshot` returns `pins + ranked + tail`; the mock-only probe moves a nearby pin into the center. That conflicts with the current local compass policy. The shortlist can also include the current conversation in a small catalog, and a target outside the eight candidates cannot be rescued. Candidate eligibility and five-slot composition should be shared by local and optional remote ranking. These are dormant integration issues, not causes of today's shipping suggestions.

## Recommended implementation order

**First, make the existing policy consistent and inspectable.** Fix the observed-topic precedence and both expiry mismatches. Extract context selection, score features, and visible-slot composition into separate pure components. Produce structured reasons from the same components used to rank, including whether a candidate won by recent use or by score. Compute the next ranking-validity deadline off the UI path; prepare replacements/fallbacks for relevant boundaries, and keep open panels frozen. Add targeted regressions for cached-versus-rebuilt behavior at the same time, including sleep and clock changes. This is a correctness step rather than a claim of better prediction.

**Second, improve the local next-return baseline.** Compare the current rules with most-recent-distinct and a small blend of decaying recent use, repeated returns, task similarity, and project evidence. Replace the binary 30-minute jump with a measured continuous decay candidate. Weight the title/latest substantive request separately from assistant prose, normalize overlap, and suppress conversational filler. Provider words should remain searchable; downweighting them for automatic similarity must not prevent meaningful tasks about a provider from matching. Treat missing excerpts as unknown, not negative relevance. Add a bounded enrichment allocation for underrepresented candidates alongside current/visible work so evaluation is not confined to already-rich entries. The decay times and weights are hypotheses to compare, not established optimal values.

**Third, make the five choices useful together.** Build a union of recent interactions, repeated-return candidates, task/project matches, and recent catalog updates; deduplicate by identity. Rank the center for the next return, then choose complements while respecting pins. Penalize genuinely redundant task matches softly rather than imposing one-chat-per-project: several conversations in the same project can be exactly what the user needs. Add reversible “stop suggesting” and “snooze” preferences that leave explicit search available. Unknown task status stays unknown.

**Then evaluate whether semantic or model ranking adds value.** Better text representations may help when task descriptions use different words. A model still cannot recover missing candidates, determine live focus from absent evidence, or infer reliable unfinished-work status from a stale excerpt. The local improvements above establish a baseline against which any added model cost and latency can be judged. Reuse the existing optional adapter only after its center/pin/current-candidate rules agree with the local path.

## How to establish an improvement

The 122 package tests pass, including replay mechanics. They establish implementation behavior, not that the intended next chat appears. The shipped app does not record impressions, and the existing built-in replay fixture is synthetic. Current evidence does not support a numerical accuracy claim or a promise that changing weights will help.

Collect a small initial set of explicitly labeled return cases, including cross-provider switches, breaks longer than 30 minutes, same-project task changes, title-only candidates, and unwanted repeated suggestions. Capture evidence and visible order before the choice; hold the intended target separately. A selection is a useful proxy, but exposure biases it; manually label some search misses. Do not turn dismissals into negative labels for every visible item. Keep collection bounded and local, with pause/clear controls and no raw query retention.

Compare the current ranker, most-recent-distinct baseline, and each proposed change on the same cases. Measure target availability separately from center/top-three/top-five hits, retaining missing targets as end-to-end misses. Also measure repeated unwanted centers, search use, time to dispatch, and preparation/search latency. Keep pins identical across comparisons. Split cases chronologically and reserve later cases for evaluation; report counts and uncertainty because an initial small personal sample is diagnostic, not conclusive. Selection/arrival success remains a separate check from ranking quality.

The existing replay runner already separates pre-choice evidence from labels and tests stale/late predictions. Extend its comparison harness with local baseline variants and the time-boundary cases instead of creating an unrelated evaluation path.

## Reproducing this review

From the repository root, build and run the package tests, then compile the standalone probe against the freshly built core. The paths below match this arm64 development checkout. Omit `.local-state` to run only synthetic cases. The optional cache inspection emits counts, not real titles, paths, excerpts, or conversation IDs; caches are read independently, so the sample is not a transactional multi-file snapshot.

```sh
env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang-cache" \
    swift test --disable-sandbox --scratch-path .build --cache-path .build/swiftpm-cache

env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
    swiftc -I .build/arm64-apple-macosx/debug/Modules \
    evidence/matching-review-probes.swift \
    .build/arm64-apple-macosx/debug/SpleenCore.build/*.swift.o \
    -o /tmp/spleen-matching-review-probes

/tmp/spleen-matching-review-probes .local-state
```

`reproduced: true` means the identified behavior occurred. These flags intentionally characterize the reviewed implementation; future fixes should change the relevant probe results and add permanent tests for the desired behavior. No native UI or arrival test was needed for this source-level investigation, and none was performed.

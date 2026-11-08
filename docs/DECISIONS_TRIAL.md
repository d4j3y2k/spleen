# Task assessment addition — 5 November 2026

The new task-assessment path is separate from next-chat ranking. Normal launch still makes zero Decisions calls. See [Session attention implementation](SESSION_ATTENTION_IMPLEMENTATION.md) for the exact-payload, expiring, at-most-two-request trial exporter and explicit credential-file activation. No paid trial has run. The ranking details below describe the earlier optional next-chat adapter.

# Optional Decisions trial — not enabled

The shipping app makes **zero Decisions calls** and constructs no remote transport. Implementation authorization does not authorize sending personal conversation metadata or discovering credentials. The Decisions endpoint uses its own supported model.

The [official guide checked for this implementation](https://developers.openai.com/api/docs/guides/decisions) specifies `POST /v1/decisions`, model `gpt-6-luna`, structured `input_json`, and `choice` questions with option probabilities. Real account access, pricing, API latency, and ranking quality remain unmeasured. Verify current pricing and account controls before any paid trial.

## Implemented boundary

`RankingInput(baseline:context:catalog:insights:now:)` builds at most eight unpinned candidates on the background path. Each candidate sends only a temporary alias `c0`…`c7`, provider, label (80 characters), project basename (80), approved short note (180), coarse selection/note age (whole hours, 0…720), and recent-return count. Context can include similarly bounded current/previous/observed topics, project basename, provider, provenance, coarse age, and alias-only transition counts.

Technical identities, actual timestamps, and observation freshness remain in the local generation key. Outgoing strings redact known technical IDs, UUIDs, paths, and links. A shared compiled ID matcher is reused across input fields, with indexed metadata/note lookups; retained interaction hints remain redacted even after their audit events are evicted. This is a bounded metadata contract, not an anonymization guarantee: labels, basenames, and approved notes can still identify personal work. A topic from an external Claude selection can appear even when that selection is not an openable candidate. A real trial therefore needs review of the **exact populated payload**, including external context, rather than approval of a title-only example.

The app and HTTP transport enforce a 6,000-byte body limit. Deterministic compaction counts JSON-escaped UTF-8 bytes, preserving required aliases, providers, provenance, ages and transition counts first, then labels, and finally available optional text. Optional fields may be omitted/shortened; unusually large Unicode labels shorten safely after optional text is exhausted. A fixture with eight candidates and all 56 directed transition pairs fits in 5,984 bytes. Pins stay fixed, typed search stays local, and existing choices never reorder during an invocation. A request may promote only a unique probability winner that agrees with the returned choice; the remaining candidates retain local order. An unchanged winner, none, ties, or choice/probability disagreement preserve the baseline. No calibrated confidence threshold has been introduced. Prediction is precomputed after meaningful evidence changes. Background jobs retain only the latest pending build; obsolete builds skip later ranking/encoding/publication stages. Request encoding and response parsing are off the main thread; typed job/deadline arbitration happens on the main thread. The deadline includes response parsing. Completed current jobs clear their timeout/cancellation state. A response can affect only a later opening; no response can invent a navigation target.

Responses must match the question and expected options, include finite bounded confidence/probabilities, and have approximately normalized probabilities. Refusal, malformed/unknown options, top-ranked `none`, expired/mismatched input, and late/missing responses all fall back locally. Endpoint confidence is not established accuracy or a calibrated measure of user intent.

## Offline replay

`SpleenReplay` is a separate development executable backed by `SpleenEvaluation`; it is not part of the app's opening path or distributed app bundle. It reuses `PreparedContext`, `RankingInput`, and `RankingPipeline` without constructing a transport. Built-in response recipes or explicitly supplied raw response JSON drive a virtual timeline. No credentials, network, provider, UI interaction, automatic history logging or real chat-store access is involved.

```sh
./scripts/replay.sh --synthetic --output "$PWD/evidence/replay"
./scripts/replay.sh --synthetic --write-synthetic-fixture "$PWD/fixtures/replay/synthetic.json"
./scripts/replay.sh --fixture "$PWD/fixtures/replay/synthetic.json" --export-requests "$PWD/evidence/replay/requests" --json
```

The fixture schema is version 1 with an `evidenceKind` declaration (`synthetic` or caller-declared `recorded`) and independent cases. Each case separates pre-choice `evidence` (state/catalog/notes/context events/ISO8601 anchor date), scheduled `attempts`, and `opens` containing eventual target labels. Attempt/open/close offsets and response/validation delays are **virtual seconds relative to the anchor**, not measured API latency. At equal time, replacement/attempt runs before arrival, validation, and then opening. An open's order is frozen at opening; a reply arriving before eventual choice cannot retroactively improve its score. Independent cases reset the pipeline; repeated openings inside a case retain it. History changes require explicit pre-choice replacement evidence; outcomes are never fed back automatically.

The main quality denominators are **every labeled opening**, including repeated opens, unavailable targets, and late/missing/invalid predictions. Dismissals count as openings but receive no invented target. Available-at-open coverage includes saved plus discovered navigable targets. Pinned targets are separate from the unpinned eight-candidate model shortlist; the shortlist denominator excludes pinned labels and retains unavailable targets. Local/replay center, top-three and five-slot compass hits, plus paired wins/losses, use these full denominators.

Raw response arrival for the current generation is reported separately from a timely validated response that remains fresh, and from an accepted reorder ready at opening. Invalid/late/expired bytes can be available without being usable. Valid no-ops can be fresh without changing order. Deadline-late validation is separate from stale/superseded completions. Validation consumes the 750 ms deadline; accepted response availability expires after 120 seconds and also respects context freshness. Report strata are numeric: 0 dismissal, 1 pinned target, 2 unpinned shortlist, 3 available outside eight, 4 unavailable.

Bounds: 1 MiB fixture JSON; 1–32 cases; up to 1,000 available entries per evidence snapshot; 10,000 evidence entries total; up to 32 non-overlapping openings and eight attempt declarations per case; 100,000 bytes per raw reply; finite timeline offsets within one day. Provider-qualified identities, source text lengths, date causality, store versions and response recipes are validated. CLI input must be a regular file; symlinks, FIFOs and oversize input are rejected. Errors do not echo fixture content.

Reports export only aggregates, numeric case/open indices, ranks and flags. Explicit local request exports contain the exact bounded pre-choice evidence and may still identify personal work through titles/basenames/notes. `manifest.json` lists the current exported request files, sizes and SHA-256 hashes; use those entries to identify the reviewed bytes. Other existing files in an export directory are preserved and are not part of that manifest's request set. Export is not transmission authorization. The tool rejects API-key options and cannot make paid calls.

The default suite's 18 openings (17 labels, one dismissal) include scripted wins and a top-three loss. Those counts verify arithmetic and failure handling only. Changing/removing labels preserves request bytes, private generation keys, and baseline order. Real prediction quality, live API latency and calibrated thresholds still need explicitly collected application examples and a separately approved experiment.

## Durable allowance

A `DecisionsHTTPTransport` requires an explicitly supplied credential and `DecisionsTrialLedger`; it never discovers credentials. Its default URLSession is ephemeral. The production app does not instantiate it.

The ledger contains an immutable trial ID, expiry, finite maximum request count (1…100; proposed trial 20), and only SHA-256 body fingerprints plus reservation times. Stable sidecar locking, bounded regular-file reads, corruption/symlink rejection, private atomic writes, and synchronization preserve the allowance across cooperating processes and restarts. Changing the configuration cannot silently reset an existing ledger. Duplicate payloads are rejected. No credential, body, label, or note is stored in the ledger.

Reservation precedes HTTP on a utility queue. Failed, cancelled, expired-after-reservation, or unused attempts consume their reservation; no refunds or retries can exceed the allowance. Expiry is checked again after disk work before HTTP starts. Cancellation claims completion atomically and calls the client at most once. The in-memory pipeline separately caps attempts, suppresses identical generations, rejects late results after 750 ms, and expires accepted order after 120 seconds.

**This enforces a request allowance, not a hard dollar cap.** Spending authorization and any supported account-level limit must be settled before paid use. No dollar amount has been approved or spent here.

## Small proposed experiment

1. Choose 5–8 personal candidates and exactly which context fields/notes may leave the machine. The existing Spleen cache and a counts-only survey of 541 chats are not an approved remote data set.
2. Review the exact populated payload, explicit supported credential setup, trial expiry, maximum requests, applicable pricing, and authorized spend.
3. Use a separate explicitly enabled shadow harness; do not change candidate generation or pins. Stop after the allowance/expiry, with no recurring service or automatic retry.
4. Measure candidate coverage, local/deployed top-three success over **all** labeled invocations, ready-only top-three success, readiness/latency, and usage/spend. A missing target counts as a miss; dismissals have no invented target. Eventually selected IDs must never enter their own pre-choice input.

Synthetic evaluation and URLProtocol transport fixtures verify arithmetic and control flow without contacting the API. They do not establish model usefulness, cost, or real network readiness. The shipped app does not retain impression or query logs.

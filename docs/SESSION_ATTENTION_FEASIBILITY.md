# Session attention and task assessment — 4 November 2026

The proposed features have different data requirements. Recent-message task assessment is feasible through the existing read-only Codex history path. Exact unread and working indicators require a live Desktop data source that the standalone Spleen process does not currently have. This investigation prepared evidence and a synthetic request; it did not enable model calls, modify shipping ranking/UI, install hooks, or change thread read state.

| Feature | Evidence required | Result |
| --- | --- | --- |
| Infer whether requested work appears finished | Ordered recent user/assistant messages, latest message/version identity, coverage and truncation flags | Recent text retrieval verified; Decisions supports this classification. Actual classification quality remains untested. |
| Mirror the unread dot | Authoritative Desktop unread state and subsequent read/unread changes | The assistant-side Desktop listing returns `isUnread`; no standalone Spleen transport established. |
| Show a working spinner | Fresh status from the runtime executing the turn, including blocker flags | Desktop tool reports this chat active; Spleen's isolated connection reports it not loaded. That connection is unsuitable for live indicators. |
| Show “Needs approval/input” | Outstanding provider request or active blocker flag | Present in the inspected protocol; live owning-runtime connection still required. Textual inference must have a separate meaning. |

## Verified evidence

The read-only probe (`evidence/session-attention-probe.py`) inspected two already-cataloged conversations through a short-lived isolated app-server. It used `thread/read` with `includeTurns: false` followed by `thread/turns/list` with `limit: 2`, descending order, and `itemsView: summary`. It did not resume a conversation or launch a turn. The run read 9,294 bytes and persisted only status and text-length counts. Probe output (`evidence/session-attention-probe.json`).

- The current conversation's previous completed exchange contained a 210-character user message and a 1,419-character assistant response. The latest stored turn contained a user message and no non-commentary assistant reply yet.
- The idle comparison conversation supplied two completed exchanges with user and assistant text.
- The isolated server had zero loaded threads and returned `notLoaded` for both. It reported the active conversation's latest persisted turn as `interrupted`. These values describe its persisted/process-local view, not the Desktop turn currently executing.
- The contemporaneous Desktop tool sample reported the current conversation `active` and the comparison `idle`. It returned a Boolean `isUnread` for all 48 sampled Codex chats; all were false. An unread-true-to-read transition was not tested, so field presence is established but exact sidebar synchronization is not yet verified. Desktop tool evidence (`evidence/session-attention-desktop-tool.json`).
- The documented default app-server control socket was absent. The read-only `app-server daemon version` command confirmed it could not connect. No service or listener was started to change that setup.

The official [App Server guide](https://learn.chatgpt.com/docs/app-server) documents bounded stored-history reads, status changes, and `activeFlags` such as `waitingOnApproval`. Its stored-read interface is distinct from subscribing to a loaded runtime. The inspected `Thread` schema does not contain `isUnread`. The Desktop tool's extra field is not evidence that a separately launched app-server exposes it.

## Recent-message classification

Use the last one or two exchanges rather than just the last assistant sentence. Preserve role and chronological order, and include the newest user request even when it has no final response. A new request must invalidate an older “finished” assessment immediately. The existing three 280-character `ThreadInsight` fields collapse role/order and can omit the ending of a reply; they are insufficient as the sole task-state evidence.

The [Decisions guide](https://developers.openai.com/api/docs/guides/decisions) supports conversation and JSON evidence plus fixed-choice questions. A proposed per-conversation choice is:

| Assessment | Meaning |
| --- | --- |
| `ongoing` | Requested work remains, or the latest request has no final response |
| `waiting_for_user` | The messages explicitly request a necessary answer, approval, or decision; this is inferred from text |
| `appears_finished` | The latest requested work is described as delivered, without a visible unresolved requirement or newer request |
| `unclear` | Missing, conflicting, insufficient, or materially truncated evidence |

An agent finishing a turn is not equivalent to a completed task. A response can end by asking a question or identifying an unresolved step. Conversely, optional future ideas do not necessarily keep the requested task open. “Appears finished” is an assessment of what the text says, not independent verification that code, tests, or delivery succeeded.

The synthetic request (`evidence/session-assessment-request.synthetic.json`) contains two small sessions and independent questions for each. It is 3,652 bytes in compact UTF-8 encoding, within the existing 6,000-byte request cap. It was parsed and checked locally, not sent to the API. Do not treat fixture wording as a quality result. Actual recent messages may not fit this example's size: retain a strict total budget and mark incomplete coverage explicitly; do not silently expand the transport limit or imply that omitted text was assessed.

Classification should run in the background only when the relevant message window changes, with a cache key containing exact provider/host identity, message/turn version, and classifier/prompt version. A stale response must never overwrite a newer request or assessment. A later user prompt invalidates a finished result even when the new classification is unavailable. Refresh only a bounded number of changed candidates at a time; do not read/classify hundreds of conversations on every compass opening.

Include new/recently updated sessions in the candidate pool independently of the existing eight-candidate ranking shortlist. Otherwise, a useful new chat ranked eighth or lower can remain excluded before the classifier ever sees it. Classification describes each task; a subsequent ranking step selects useful returns from eligible candidates. Dependent classification and reranking should not be assumed to form an ordered chain inside one Decisions request.

## Eligibility rules

Keep three independent fields: inferred task assessment, verified runtime activity, and verified unread state. Preserve unknown values; absence of unread evidence is not evidence that a reply was seen.

| Situation | Proposed automatic-suggestion behavior |
| --- | --- |
| Actual outstanding approval or input request | Keep eligible and give attention priority |
| Unread final reply, even if text says the task is finished | Keep eligible so the result can be read |
| Verified active turn | Keep eligible; show working state |
| Newer user message than the assessment | Invalidate assessment and keep eligible |
| Appears finished, with sufficiently validated classifier evidence and known acknowledgement/no pending live activity | Suppress from automatic suggestions; retain explicit search |
| Unknown task or unread/activity evidence | Avoid a confident finished exclusion; use the local fallback |
| Explicit pin or user override | Preserve deliberate access |

This fulfills the intent to remove settled work from the automatic set without hiding its final unread result. While a reliable unread/activity source is missing, test finished assessments in shadow mode or as a soft demotion before using them for hard exclusion. Tune any probability threshold with labeled examples; a model confidence value alone is not validated accuracy.

The [official command reference](https://learn.chatgpt.com/docs/reference/commands#keyboard-shortcuts) includes both “Mark chat as unread” and “Clear all unread indicators.” Thus unread is a user-facing attention marker, not proof of an unanswered question or a required next turn.

## Card behavior and live integration

The existing SwiftUI cards can display a small blue dot for authoritative unread state, a spinner with “Working” for a fresh active turn, and an amber input/approval indicator for an actual blocker. A working turn can be executing tools as well as generating text, so “Working” is a better general label than “Thinking.” Unread and working can coexist; they should not be forced into one mutually exclusive enum. A completed and read task can have no attention badge and become eligible for automatic suppression through the separate task assessment.

Attach provider, host, conversation ID, source, observation time, and validity/version information to every live status sample. A disconnected or stale source becomes unknown; it must not leave an indefinite spinner or manufacture a read acknowledgement. An accepted Spleen navigation must not clear the provider's unread flag by itself. Respect reduced-motion settings and supply accessible text for all indicators.

Keep the chosen conversation identities and positions frozen during an invocation. Fresh activity/unread badges may update on those fixed cards without changing arrow-key targets. Model assessment and new ordering apply on a later opening.

Integration options, in order of fidelity:

1. **A supported Desktop status/read-state feed or adapter.** This would supply actual runtime and unread state together. The assistant tools establish that the app has such data internally, but the current investigation did not establish a callable endpoint for standalone Spleen. The next gate is a bounded continuous adapter test against the owning runtime, including running→completed→unread→read and approval/input transitions.
2. **A reviewed lifecycle hook integration.** Hooks can report lifecycle events prospectively for configured sessions. They do not supply exact Desktop read state, and prompt-submission/stop events need explicit semantics, expiry, and restart handling before use as working-state evidence. They cannot reconstruct every already-running session. No hooks were installed here.
3. **Accessibility observation.** A separate feasibility test could determine whether Desktop exposes stable per-thread status and unread labels. Visible rows alone may not cover virtualized/offscreen chats, and a visual dot need not have an accessible semantic label. No Codex sidebar scraping or permission changes were performed here. Claude's existing observer remains title/identity/visit only.

Do not treat the assistant writing a one-time snapshot into a file as a continuous production integration. Do not use a separate app-server's `notLoaded`, cached turn status, elapsed time, or a model's wording to animate a live spinner.

## Concrete next implementation

First establish the live status/read-state adapter and its event identity/freshness contract. In parallel with that engineering work, expand the bounded local message representation to retain role/order/version and prepare the per-session classification cache. Then connect card indicators to verified state and apply the eligibility table before the existing relevance ranker. Preserve searchable destinations and frozen card positions.

Validate against a small labeled fixture set containing genuinely finished work, unanswered questions, unfinished requirements, optional future suggestions, new prompts after completion, ambiguous or truncated endings, unread completed results, active tools, stale/disconnected status, and out-of-order events. Evaluate false exclusions separately from top-five usefulness. Paid classification quality and latency remain unmeasured; a real API trial still needs a concrete scoped payload and finite spend/request configuration. This investigation made zero paid model requests.

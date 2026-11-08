> **Continuation evidence, 3 November 2026:** the compiled local relevance adapter returned three Spleen threads and three nonempty bounded notes using metadata validation and paginated summary turns. The native UI found a thread by a word absent from its title. With 1,000 synthetic threads, release app-model preparation measured p95 0.029 ms and search p95 1.790 ms. These establish the local relevance path and computation speed for the tested scope, not measured ranking usefulness, live activity, screen rendering, or visible Codex arrival. No paid API requests occurred. Earlier findings below are historical; see [current evidence](IMPLEMENTATION.md).

# Feasibility findings

Checked on 2 November 2026. “Documented,” “locally verified,” and “unverified” are deliberately distinct.

## Implementation update

The first native app is now built and launches. Eight core tests and 69 in-process app checks pass. Permitted inspection of Spleen's own UI verified add/edit/search and focus behavior; Return and mouse dispatch were accepted by macOS. Carbon shortcut registration/reconfiguration succeeds, but physical global-key delivery, external focus recovery, and visible Codex arrival remain unverified. Automatic desktop catalog discovery and live status are still unknown. No API calls, credentials, installs, or security permission changes occurred. See [implementation status](IMPLEMENTATION.md).

The installed evidence and setup history below retain the earlier planning inspection. Statements that no build or navigation was attempted describe that initial inspection, not the later authorized implementation.

## Initial planning assessment

**A native saved-context switcher is feasible with the installed tools.** Automatic Codex catalog discovery is plausible but unproven in this desktop configuration. Reliable cross-process live thread activity is a separate open question. Neither is necessary for the first usable prototype.

| Capability | Evidence | Conclusion |
| --- | --- | --- |
| Native macOS development | macOS 26.5.2, Apple Silicon; Swift 6.3.3; selected Xcode developer directory exists | Toolchain present; no app build attempted |
| Global shortcut API | Installed HIToolbox header declares `RegisterEventHotKey`, exclusive registration, and collision error behavior | SDK declaration verified; runtime hotkey, permissions, and focus behavior untested |
| Codex thread navigation | Official `codex://threads/<thread-id>` documentation; installed app declares `codex` URI scheme | Documented and registered; end-to-end navigation not exercised |
| Thread listing and metadata reads | Both installed CLI schemas contain `ThreadListParams` and `ThreadReadParams` | Protocol capability locally verified; desktop data visibility not verified |
| Desktop source coverage | Docs and generated schemas expose explicit source filters | Default omitted/empty filters are not an all-source query |
| Live desktop status | Default CLI control socket absent; no authorized desktop transport established | Unknown; do not advertise live running/waiting status |
| Decisions reranking | Official guide documents fixed choices and probabilities | Suitable for a later controlled comparison, not required for launch |
| Codex project and local planning context | `list_projects` returned `spleen`; `list_threads` returned this continuation in that project on host `local`; shell `pwd` matched | Registration, local chat membership, and execution directory verified; original task move remains failed history |

## Installed evidence

- Existing local projects use `~/Developer`. Root-level `/developer` and `/Developer` do not exist. The chosen lowercase project name follows existing folder naming.
- No applicable `AGENTS.md` was found at the task workspace or the checked ancestor locations, including the Developer root. Instructions in sibling projects do not apply to Spleen.
- The local continuation rechecked `/AGENTS.md`, `/Users/AGENTS.md`, `~/AGENTS.md`, `~/Developer/AGENTS.md`, and this project's root and descendants; none was present.
- New directory created without overwriting anything: `<repo>`.
- Desktop application: `/Applications/ChatGPT.app`, bundle ID `com.openai.codex`, version `26.1027.61615`, build `24141`.
- Shell CLI: `/opt/homebrew/bin/codex`, version `0.157.1`.
- Bundled desktop CLI: `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex`, version `0.166.0-alpha.5.1`.
- Both schema generators completed. Selected generated schemas are saved in `../evidence/`; they are evidence of installed protocol shape, not an implementation dependency or proof of runtime data access.
- A read-only `codex app-server daemon version` probe failed because `~/.codex/app-server-control/app-server-control.sock` did not exist. This says nothing definitive about an app-private transport. No daemon was started or reconfigured, and no socket discovery bypass was attempted.
- CLI help/schema generation warned that PATH aliases could not be created under the sandbox. Schema output still completed successfully. No permission changes were made to remove the warning.
- The continuation inspected `CarbonEvents.h` under the selected Xcode macOS SDK, including the `RegisterEventHotKey` declaration and comments at lines 15428–15491. No compilation, hotkey registration, or permission probe was performed.

The version, schema-generation, and socket findings above are retained initial-inspection evidence from the same date. The continuation re-read the saved desktop list/read schemas and verified all saved schema hashes; it did not regenerate them or establish an app-server connection. Official deep-link, thread-list, and Decisions documentation was fetched again. None of these documentation checks demonstrates end-to-end desktop navigation or independent-app catalog access.

The bundled CLI differs from the PATH CLI. Any later adapter should detect and record the exact binary/version it uses and tolerate unknown fields. The latest docs and both local schemas also differ in optional filter fields. Use generated schemas for the tested installation instead of copying every current web example blindly.

## Thread discovery details

Official documentation says `thread/list` defaults to interactive sources `cli` and `vscode` when `sourceKinds` is omitted or empty. Both installed schemas allow `cli`, `vscode`, `exec`, `appServer`, several subagent kinds, and `unknown`. There is no literal `desktop` enum value. Do not assume which source represents desktop chats; determine it using one known personal test thread. [App-server thread listing](https://learn.chatgpt.com/docs/app-server#list-threads-with-pagination--filters).

`thread/read` can return metadata without resuming the thread. `thread/list` supports `useStateDbOnly: true` to avoid the documented scan-and-repair behavior for rollout metadata. Both still require a supported connection to the correct store. [App-server reference](https://learn.chatgpt.com/docs/app-server).

Runtime `status` and `thread/status/changed` concern loaded threads on the connected server. A separately started process may see persisted logs while having no knowledge of another process's live turns. There is no evidence from this inspection that it can observe all desktop activity. No claim of active-thread detection is warranted.

The thread schema includes `preview`, described as usually the first user message. “Metadata only” does not mean “content free.” An adapter must discard unwanted previews and honor a personal project allowlist before persistence or inference.

## Deep links and supported fallback

The documented URI can open a **local** chat. Cloud chats and remotely hosted threads need separate validation; do not assume the same URI has identical routing. A manually saved technical ID avoids a discovery dependency. The app's own chat search and recent-chat shortcuts remain the fallback if Spleen cannot find or open a destination. [Commands and links](https://learn.chatgpt.com/docs/app/commands).

The available app connector can list projects and threads, but those tools run within the assistant environment. A standalone desktop app is not automatically entitled to that connector transport. No unsupported Codex database editing or private preference mutation is proposed.

## Decisions assessment

The current guide documents `POST /v1/decisions`, using `gpt-6-luna`, for predicate, choice, and score questions. Choice evaluates provided values and produces option probabilities plus separate confidence. It does not retrieve the candidates. Thresholds should be chosen from labeled examples relevant to the application. These features support an optional shortlist-reranking experiment. [Decisions guide](https://developers.openai.com/api/docs/guides/decisions).

The harder problem is not model classification speed; it is whether available local evidence predicts what this user wants next. Many switches are habitual, so recency, frequency, pins, and transition counts may win on both quality and latency. Background inference can be ready at invocation but still be stale. Empirical comparison is required.

No API requests, account inspection, credential setup, or spending occurred.

## Setup outcomes and history

**Project registration: verified.** The original task's final `list_projects` call returned local project `spleen`, ID `<project-id>`, path `<repo>`, host `local`, and `isGitRepository: false`. This local continuation independently confirmed that record. Registration appeared during the original task and was not performed by that agent. The project registry is verified, but a visual sidebar inspection was unavailable.

**Earlier denied action:** inspect/open Codex's project UI through `cua.getApp("Codex")`, target `com.openai.codex`. Computer Use returned “Computer Use is not allowed to use the app 'com.openai.codex' for safety reasons.” It was not retried or bypassed. This was a Computer Use restriction, not a shell auto-review rejection.

**Historical failed action:** associate planning task `<task-id>` on host `durable` with local project `<project-id>` through `move_thread_to_project`. The tool returned an error: “The task's source project could not be safely determined.” A subsequent `list_threads` confirmed `projectId: null`; the local continuation confirmed it remains projectless. No retry or workaround modified that task.

**Completed:** project directory, independently verified project registration, local conventions inspection, official documentation research, installed version/schema checks, and planning documents.

**Resolved by local continuation:** **Plan Spleen prototype**, ID `<thread-id>`, is returned by `list_threads` with project ID `<project-id>`, host `local`, and cwd `<repo>`. Shell `pwd` independently agrees. The earlier task need not be moved for this project to proceed. The connector response verifies context, not the underlying model identity.

**Still unknown:** link acquisition effort and actual local-chat arrival; native panel/hotkey behavior; whether a saved set covers enough intended returns; whether an independently supported provider sees desktop metadata or live activity; and whether Decisions adds useful, timely ranking lift. The first two can be tested without automatic catalog discovery. The current recommendation is an engineering judgment based on documented interfaces and installed declarations, not a working-prototype result.

During initial setup, the README was queued to open in the original planning task's Codex panel. That was an artifact-view action, not evidence of project membership.


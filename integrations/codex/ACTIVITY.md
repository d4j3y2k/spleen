# Prospective local activity observations

`activity-hooks.json.example` is staged integration configuration, not installed configuration. Merge it into one appropriate local hook source, retain other hooks, and use Codex's normal **Review hooks** / **Settings > Hooks** workflow. Never edit hook trust records or use a trust bypass to activate it. The callbacks are synchronous, advisory, silent, capped at one second, and never return an approval decision, model context, or continuation instruction.

The callback mode is `Spleen --activity-event codex --data-dir <same app directory>`. It receives hook JSON on stdin. `ActivityHookDecoder` reads at most 64 KiB, validates local identity/cwd/turn/call IDs, and retains only event kind, IDs, project, receipt timestamp and generated event UUID. Prompt, assistant text, tools, output and transcript paths are discarded, and no transcript is opened. These are not attention or observed-selection events.

The separate `notify` configuration in `activity-notify.toml.example` invokes `--activity-notification codex` and receives one JSON argument appended by Codex. The documented `agent-turn-complete` notification provides exact thread/turn identity. It establishes completion of that turn, but does not establish read status, task completion, absence of child work, or a source completion timestamp. Only metadata is retained. Existing `notify` configuration must be preserved, or explicitly combined with a reviewed dispatcher; there is a single notify setting.

The actual source contract follows [official hooks documentation](https://learn.chatgpt.com/docs/hooks) and [official notify documentation](https://learn.chatgpt.com/docs/config-file/config-advanced#notifications):

| Evidence | Effect |
| --- | --- |
| PreModelRequest / PreToolUse / SubagentStart | Short-lived working pulse from a real loop event |
| PostModelRequest / PostToolUse | Close only the matching operation's pulse; never turn completion |
| Stop / SubagentStop | Stop attempt, clear matching pulses; another hook may continue execution |
| PermissionRequest | Approval may be requested, clear this agent's pulse; another hook may auto-allow, so no claim of outstanding approval |
| UserPromptSubmit | New request invalidates prior completion, but does not prove model execution started |
| Interrupt / SessionEnd | Clear appropriate pulses, never claim successful completion |
| notify agent-turn-complete | Exact turn completion, with unknown read state and unknown source timestamp |

`ActivityHookRepository` stores a private bounded journal in `activity-hooks.json`. It is disabled by default; Spleen must explicitly enable it during setup. A stable sidecar lock serializes helpers, with a 200 ms lock-acquisition deadline. Data uses a private temporary file and atomic rename; symlinks, nonregular files, oversized/unknown/corrupt content are rejected and preserved. The journal retains at most 128 events for one hour. Per-conversation receipt times reject backwards events, while sequence numbers order cooperating writers. Disabling clears records and rotates the producer epoch, so old samples cannot reappear after re-enable.

Working pulses expire 15 seconds after their actual source event. Polling and file reads do not renew them. Long model requests/tools without fresh callbacks become unknown until another callback; this deliberately does not claim continuous tracking across arbitrary long operations. Concurrent tools and child pulses have independent leases. Older-turn Stop/notify callbacks cannot clear a later known root turn. Hook delivery has no provider-issued monotonic sequence, so synchronous callbacks and this conservative short lease bound the effect of incomplete coverage; they cannot reconstruct already-running sessions or prove an exact sidebar state.

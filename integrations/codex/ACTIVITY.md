# Prospective local activity observations

`activity-hooks.json.example` shows exactly the twelve handlers that `scripts/install-activity-reports.py` adds to `hooks.json`, with placeholder paths. The installer quotes each path for the shell only when needed, using Python's `shlex.quote`: a plain path appears bare, and one with spaces or shell metacharacters appears in single quotes. The example is not installed by itself. Use the [installer](README.md#set-up-activity-reports-in-a-fresh-checkout), or merge the example by hand into one local hook source and keep the other hooks. Either way, use Codex's normal **Review hooks** / **Settings > Hooks** workflow. Never edit hook trust records or use a trust bypass to activate it. The callbacks are synchronous, advisory, silent, limited to two seconds by the hook `timeout`, and never return an approval decision, model context, or continuation instruction.

The callback mode is `Spleen --activity-event codex --data-dir <same app directory>`. It receives hook JSON on stdin. `ActivityHookDecoder` reads at most 64 KiB, validates local identity/cwd/turn/call IDs, and retains only event kind, IDs, project, receipt timestamp and generated event UUID. Prompt, assistant text, tools, output and transcript paths are discarded, and no transcript is opened. These are not attention or observed-selection events.

The separate notification mode, `--activity-notification codex`, receives one JSON argument appended by Codex. The documented `agent-turn-complete` notification provides exact thread/turn identity. It establishes completion of that turn, but does not establish read status, task completion, absence of child work, or a source completion timestamp. Only metadata is retained. Codex has a single `notify` setting, so the installer does not use `activity-notify.toml.example`. It points `notify` at its forwarder, which runs this mode and then the `notify` command you already had. The direct example suits only a setup with no other `notify` command; otherwise preserve the existing one, or combine them with a reviewed dispatcher.

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

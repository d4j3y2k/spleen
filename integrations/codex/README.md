# Optional Codex metadata hook

This example is not installed. It is for local Codex hooks only; it does not provide ordinary Claude Desktop discovery or selection tracking.

Codex command hooks receive JSON on stdin, including `session_id`, `cwd`, and `hook_event_name`. Async commands use the same trust review as synchronous hooks. Non-managed hooks must be reviewed and trusted before execution. In the Desktop app, use **Review hooks** or **Settings > Hooks**; the CLI exposes `/hooks`. See the [official OpenAI hook documentation](https://learn.chatgpt.com/docs/hooks).

To enable after reviewing the implementation:

1. Build and inspect the local Spleen executable. In `hooks.json.example`, replace the executable placeholder with that approved absolute path and `/absolute/path/to/spleen-data` with the same data directory used by the app. The `/Applications/Spleen.app/...` path is an example, not an installer or an assertion that the app is there. Quote paths correctly if they contain spaces or shell metacharacters.
2. Merge the example's three event groups into the desired Codex hook source without replacing existing hooks. Choose one scope to avoid duplicate delivery.
3. Use Codex's normal hook review flow to review and trust the exact definitions. Re-review changed definitions. Never bypass hook trust or edit its trust records to activate this integration.

The helper invocation is `Spleen --context-event codex --data-dir <directory>`. It must handle that mode before starting `NSApplication`, read at most 65,537 input bytes to detect overflow, and exit without writing stdout. It makes no model or network calls and must not emit context, decisions, or blocking responses to Codex. Keep diagnostics generic and off stdout; never log raw stdin. The example's five-second timeout bounds hook waiting. No command is run by this README.

`ContextHookDecoder` accepts at most 64 KiB and decodes only the three required metadata fields. It validates the session ID using `ThreadTarget`, requires a bounded absolute working directory, and ignores prompts, replies, transcript paths, and other fields. It never opens a transcript. Events map as follows:

| Codex hook | Spleen event | Evidence |
| --- | --- | --- |
| `SessionStart` | `sessionStarted` | lifecycle |
| `UserPromptSubmit` | `userPromptSubmitted` | lifecycle |
| `Stop` | `turnCompleted` | lifecycle |

These hooks do not establish the actor, active window, selected chat, or human attention. Background hooks may finish out of order. Spleen records local receipt time, not a fabricated source timestamp, and lifecycle events cannot update the current-chat hint. Hooks are supplementary metadata, not a complete conversation catalog.

`ContextRepository` reads at most 256 KiB and relies on `ContextMemory`'s 64-event bound. It serializes read/modify/write under a persistent adjacent `.lock` using `flock`, then atomically renames a private temporary file. Do not delete the lock file while app/helper processes are running. Recents disabling clears memory and suppresses subsequent recording until re-enabled. Corrupt, oversized, or newer-version files produce an error and remain untouched; errors do not trigger automatic reset. Storage calls belong on a background queue, outside the instantaneous compass path.

Removing these three definitions through the normal hook configuration/review workflow disables future delivery. Existing local history is controlled by Spleen's recents settings. This example does not modify any Codex configuration itself.

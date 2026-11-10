# Optional Codex integrations

For **Working** and completed-turn indicators, start with [activity reports](ACTIVITY.md) and the [installation notes](../../docs/LIVE_INDICATORS.md#installation-and-trust). The examples are not installed automatically. The installation notes include the author's local verification history; a fresh checkout still needs its own setup and normal Codex hook review.

The simpler context hook below records lifecycle metadata and does not power the working indicators.

## Set up activity reports in a fresh checkout

Build Spleen first. The installer needs **Python 3.11 or later** for its standard-library TOML parser; Apple's bundled Python 3.9 is too old. Check `python3 --version` and substitute a newer interpreter name, such as `python3.13`, in the commands below if needed. No Python packages are required. The generated notification helper uses Apple's Python and does not need TOML support.

From the repository root, review the proposed setup without changing files:

```sh
python3 scripts/install-activity-reports.py \
  --data-dir "$PWD/.local-state" \
  --executable "$PWD/build/Spleen.app/Contents/MacOS/Spleen"
```

After reviewing the script and the [hook definitions it adds](activity-hooks.json.example), run the same command with `--install`, then enable Spleen's metadata journal:

```sh
python3 scripts/install-activity-reports.py \
  --data-dir "$PWD/.local-state" \
  --executable "$PWD/build/Spleen.app/Contents/MacOS/Spleen" --install
./build/Spleen.app/Contents/MacOS/Spleen --data-dir "$PWD/.local-state" --enable-activity-reports
```

These paths match `scripts/run.sh`. For a directly launched app, use its actual data directory and executable instead. The installer defaults to `~/.codex`; pass `--codex-home /absolute/config-directory` if your Codex configuration is elsewhere. It keeps other hook handlers and your existing `notify` command, and prints that command and the backup folder when it finishes. Unsupported configuration shapes, such as a `notify` setting split over several lines, are rejected before anything changes.

Finally, use Codex's **Review hooks** or **Settings → Hooks** to review and trust the new exact definitions. Installation alone does not trust them. Existing sessions may need to be reopened to load the hooks. See [coverage and expiry limits](../../docs/LIVE_INDICATORS.md); the historical verification there is not setup performed on a fresh checkout.

### What the installer writes

Everything goes in the Codex home, outside the checkout:

- `hooks.json` gains one handler for each of twelve lifecycle events. Each runs `<executable> --activity-event codex --data-dir <data-dir>` with a two-second timeout, exactly as in [`activity-hooks.json.example`](activity-hooks.json.example). Other handlers stay as they are.
- The root `notify` in `config.toml` becomes `["/usr/bin/python3", "<codex-home>/spleen-activity/notify-forwarder.py"]`. The forwarder reports each completed turn to Spleen, then runs your previous `notify` command with the same arguments, environment, output and exit status. A missing, failing or slow Spleen never stops that command.
- `spleen-activity/` holds the forwarder, `forwarding.json` with your previous `notify` command and the Spleen command, and `backups/<UTC time>/` with copies of `config.toml`, `hooks.json` and any replaced `forwarding.json` from before each change. The folders and files are private to your account.

If `config.toml` or `hooks.json` is a symbolic link, for example into a dotfiles repository, the file it points to is updated and the link is kept.

### Switch data directories or uninstall

To send reports to another Spleen, such as a directly launched app, run the installer again with its `--data-dir` and `--executable`. It replaces every earlier Spleen hook handler, whatever paths it names, and keeps the single forwarder and the `notify` command it wraps, so no event is delivered twice. The changed hook commands need Codex's review again. Running the installer again with the same paths changes nothing.

To remove the integration, preview with `--uninstall --dry-run`, then run:

```sh
python3 scripts/install-activity-reports.py --uninstall
```

This restores your previous `notify` command, or removes the line if you had none, removes Spleen's hook handlers and deletes the forwarder and `forwarding.json`. It backs up the current files first, prints what it restored and keeps every backup; delete `spleen-activity/` yourself when you no longer need them. Uninstalling needs no `--data-dir` or `--executable`, only `--codex-home` if you installed elsewhere, and it leaves Spleen's own data directory alone.

Deleting the checkout, or running `git clean -xdf`, keeps your `notify` working: the forwarder skips Spleen once its executable is gone and still runs your command. The twelve hooks would keep pointing at the missing executable, so uninstall first, or afterwards from a fresh clone.

Earlier versions of the installer kept the forwarder and backups in `<data-dir>/activity-integration/`. Installing or uninstalling again recognizes that layout, also when several installs were stacked: it recovers your original `notify` command, removes the old forwarder files and keeps their backups. If that folder is already gone, the script changes nothing and lists the backups that may show your earlier `notify` line. Set it back in `config.toml` by hand, then run the script again.

## Context metadata hook

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

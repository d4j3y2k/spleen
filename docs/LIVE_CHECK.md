# Live-check status — 4 November 2026

Build **0.2.7** adds experimental Claude Desktop Code targets. The existing saved store and observation preference are preserved. The temporary event trace is off.

The tested build is now running with the original explicit `.local-state` directory. Saved destinations were byte-identical across relaunch; Settings was left open with **Remember visited Claude Desktop sessions** unchecked. No persistent observer or new permission was enabled.

Completed live: physical Control–Option–Space delivery, key-panel presentation, arrows, first-character search input, title lookup, Escape cancellation, and foreground restoration. The Claude observer also completed a foreground A → B → A session roundtrip using existing permission. Labels/pins and the exact discovery scope are preserved.

Exact Codex chat identity still needs a direct user check: Computer Use blocks the Codex app. macOS accepted dispatch and the user saw Codex come forward, but the specific selected destination was not conclusively confirmed.

Claude Code external reopening passed **B → A → B → A → B** on Claude **4.16336.0**, covering existing local and SSH-backed interactive sessions. Every arrival matched the original AX identity and title, with one visible sidebar row per session. Copy link was absent from both tested right-click menus. The tested URIs were constructed from independently observed Desktop identities using the reported `epitaxy/local_` template; they were not app-generated links. Ordinary Claude Chat UUID links remain a separate syntax. See the [experiment and remaining limits](CLAUDE_DESKTOP_FEASIBILITY.md).

The actual Spleen compass/`NSWorkspace` path also passed B → A → B using an isolated restored-observation fixture. The temporary app was quit and fixture removed. This verifies real dispatch plus candidate restoration, not a new live observer attachment or Claude restart.

Optional setup remains in Settings: **Discover Codex projects automatically** broadens an existing exact-folder scope; the Claude Desktop observation option enables persistent local title/identity observation and recently visited Code targets. Neither setting was changed during verification. An explicitly saved Code link can be used without observation.

On the next Claude update, repeat a two-session arrival check before extending the version-tested claim. Claude cold launch/restart, archived/deleted sessions, and account changes remain untested. Spleen records accepted dispatch as intent, not automatic arrival confirmation.

Remote ranking remains off. Exact pre-choice payload review and an explicitly enabled bounded trial are still needed for real Decisions quality/network measurements. The offline replay tool is ready for this preparation: `./scripts/replay.sh`.

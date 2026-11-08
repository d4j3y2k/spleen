# Documentation

These documents were written while Spleen was built and read best as design and verification notes rather than a manual. Dates and version numbers refer to the local build at the time.

Start here:

- [SETUP.md](SETUP.md): first run, observation, optional Decisions API key setup, pause controls and troubleshooting.
- [PUBLIC_READINESS_2026-11-08.md](PUBLIC_READINESS_2026-11-08.md): independent source-sharing review, fixes, test evidence and remaining live-verification limits.
- [ARCHITECTURE.md](ARCHITECTURE.md): native shell, local core, snapshots, ranking.
- [CONTEXT_CONTRACT.md](CONTEXT_CONTRACT.md): what context memory records, its bounds and expiry.
- [DETERMINISTIC_NAVIGATION.md](DETERMINISTIC_NAVIGATION.md): how recent sessions and the compass are ordered.
- [LIVE_INDICATORS.md](LIVE_INDICATORS.md): working spinners and unread dots for Codex and Claude Code.
- [CLAUDE_DESKTOP_FEASIBILITY.md](CLAUDE_DESKTOP_FEASIBILITY.md): Accessibility observation and the Claude Desktop routes.
- [PRODUCT.md](PRODUCT.md): the product thesis and boundaries.
- [CHANGELOG.md](CHANGELOG.md): release-by-release development log.

Optional and experimental:

- [DECISIONS_TRIAL.md](DECISIONS_TRIAL.md), [SESSION_ATTENTION_FEASIBILITY.md](SESSION_ATTENTION_FEASIBILITY.md), [SESSION_ATTENTION_IMPLEMENTATION.md](SESSION_ATTENTION_IMPLEMENTATION.md): the opt-in, off-by-default model assessment path.
- [MATCHING_REVIEW.md](MATCHING_REVIEW.md), [IMPLEMENTATION.md](IMPLEMENTATION.md), [FEASIBILITY.md](FEASIBILITY.md), [PROTOTYPE_PLAN.md](PROTOTYPE_PLAN.md), [LIVE_CHECK.md](LIVE_CHECK.md): earlier reviews and plans.

Links into `evidence/` point at a local folder of build logs, test output, probe results and rendered previews. It is excluded from the repository because it contains the author's own session metadata.

## Public previews

The README's light and dark images in `assets/` come from the app's native preview renderer with fictional fixture data. They use navigation history and the fallback material; they are not desktop captures. To regenerate after building, run from the repository root:

```sh
./build/Spleen.app/Contents/MacOS/Spleen --render-preview "$PWD/evidence/native-previews"
```

Inspect `native-fixture-compass-light@2x.png` and `native-fixture-compass-dark@2x.png`, then copy them to `docs/assets/compass-light.png` and `docs/assets/compass-dark.png`. Other rendered scenarios remain local verification artifacts.

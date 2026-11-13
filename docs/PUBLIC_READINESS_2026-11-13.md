# Public-source review — November 13, 2026

Prepared Spleen 0.2.28 for sharing with the optional Moonshine connection. Both applications remain independent. The source installer builds and verifies an app for `~/Applications`; neither notarized binaries nor user data are published.

Validation passed 286 Swift package tests and 480 native fixture checks. The shared handoff contract is byte-identical across repositories. Native checks inject dispatch and restoration callbacks, so they do not claim a new live cross-application keyboard/focus check. The installer was exercised in a temporary destination, including spaces in the path and replacement/refusal cases.

Reviewed candidate source, documentation, synthetic images and their metadata, tracked files, commit author email addresses, and all 10 pre-existing reachable commits. Gitleaks found no secrets in the reachable history. Its source scan initially matched a synthetic private-key header in a security test; the test now constructs the same fake marker explicitly, without containing key material. The final source scan and exact-match checks against local credentials found no matches. Commit email uses the existing GitHub no-reply address.

Local `.env` files, `.local-state`, evidence, build outputs, and real conversation fixtures remain excluded. Images contain synthetic content; their metadata contains rendering dimensions/resolution, not personal identifiers. No production API requests or uploads of local conversation data were part of verification.

This is a scoped review, not proof that every vulnerability or sensitive input is excluded. Provider compatibility and macOS permission limitations remain as described in the README.

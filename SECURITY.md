# Security

Spleen is experimental software. Ordinary local navigation needs no API key. Optional observation, Codex hooks, and remote Decisions assessment have separate permissions and setup. Read [privacy and local storage](README.md#privacy-and-local-storage) before enabling them.

Report vulnerabilities privately through this repository’s **Security → Report a vulnerability** feature. Do not post keys, personal conversation excerpts, live screenshots, or exploitable details in public issues. Use fictional examples and redact machine paths and identifiers.

The Moonshine connection transfers bounded search text through a local URL handler. Other local applications can invoke that handler; it is not authenticated interprocess communication. Received text does not activate a destination. A transferred search does not trigger Spleen’s assessment-on-open; each app retains its own remote-processing settings.

Before publishing, review staged files and reachable Git history for secrets and personal context. Keep `.env*`, `.local-state/`, `evidence/`, build outputs, and real conversation fixtures out of source control. Use synthetic screenshots and tests. A secret scan complements manual review and privacy tests; it cannot guarantee that all sensitive information or vulnerabilities are absent.

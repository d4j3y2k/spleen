# Moonshine and Spleen

These are independent macOS apps with one optional connection: continuing the same search in the other app.

- [Moonshine](https://github.com/d4j3y2k/moonshine) finds open native windows and ordinary browser tabs.
- [Spleen](https://github.com/d4j3y2k/spleen) finds saved and locally discovered AI conversations.

Install each using its own `scripts/install.sh` and open each once. Their default install folder is `~/Applications`; neither needs the other to be installed. No shared server, API key, account, extension, or browser pairing code is involved in connecting the two apps.

Type in either app, then press **Tab** or **Shift–Tab**, or click the companion action in its footer. The other app opens its own search with exactly that query and the caret at the end. A closed app starts automatically. Your global shortcuts remain separate: **Control–Option–M** for Moonshine and **Control–Option–Space** for Spleen. Settings and editing forms keep normal Tab navigation.

The transfer uses a versioned local URL (`moonshine-search://search` or `spleen-search://search`) delivered to the companion's matching application bundle identifier. It contains the query and, when available, the prior application's process ID for Escape restoration. The apps do not write the query to a file or clipboard. They reject unexpected routes/fields, duplicate fields, invalid PIDs, and oversized queries. A handoff never executes a destination or shell command.

This is a local convenience, not authenticated communication between trusted processes. Other local applications can invoke the URL handlers; treat received search text as untrusted. The receiving app applies its existing privacy settings: Moonshine may refine a transferred query remotely if you enabled refinement. Entering Spleen through a transferred search does not trigger assessment-on-open. Each app retains its own settings, inventories, history, credentials, and macOS permissions.

If switching fails, the sender restores its search. Install a current version of the missing companion and open it once. Quit old copies in build folders if macOS selects an unexpected installation. A source build also supports a sibling checkout for development, but installed apps do not depend on that folder layout.

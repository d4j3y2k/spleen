# Set up Spleen

Spleen currently ships as source to build on your Mac. You need an Apple silicon Mac, Xcode 26 or later selected as the active developer toolchain, and Codex Desktop, Claude Desktop, or both. It has been tested on macOS 26; earlier supported deployment targets remain unverified. A notarized installer is not provided by this repository.

Switching, search and local indicators work without an OpenAI API key. The Decisions assessment section below is optional.

## Build and start

```sh
git clone https://github.com/d4j3y2k/spleen.git
cd spleen
./scripts/install.sh
open "$HOME/Applications/Spleen.app"
```

The installer builds and installs into `~/Applications` without sudo. Quit any running Spleen first. Set `SPLEEN_INSTALL_DIR` to choose a different folder you own. To update, quit Spleen, run `git pull --ff-only` and `./scripts/install.sh` in your clone, then open the installed app again. Preferences and conversation state are kept separately.

For development, `./scripts/build.sh` creates `build/Spleen.app`, and `./scripts/run.sh` launches it with `.local-state/` inside the checkout. Opening the app directly, including an installed copy, reuses the last normal data directory. Before one has been chosen, it uses `~/Library/Application Support/Spleen/`. An explicit `--data-dir` overrides it. Quit before changing stores. Do not delete a development checkout while you still use its `.local-state/` store; preserve that directory first.

The build selects an available Developer ID or Apple Development signing identity, or uses ad-hoc signing if none is available. Accessibility permission may need to be granted again after an ad-hoc rebuild. See [build and signing details](../README.md#build-and-run).

## First conversation

1. Open Codex Desktop or Claude Desktop.
2. Find Spleen in the menu bar and choose **Open Spleen**, or press **Control–Option–Space**.
3. Local Codex discovery can populate the compass automatically. To save a conversation yourself, choose **Add conversation…**, enter a name and paste an existing Codex or Claude chat link. Claude Code links are experimental; terminal-only Claude Code sessions are not supported destinations.
4. Use the arrow keys to select a card and Return to open it. Type to search. Escape closes Spleen and restores the prior app when available.

Press Right twice from the compass center to enter **Recent sessions**, then Up/Down to select, Left to return, or Return to open. The list fills from recorded selections, observed visits and recent Codex creation times.

You can edit a conversation's label or pin it from search using its **…** button. Removing a destination changes Spleen's list, not the conversation in its own app.

## Optional local observation and indicators

In **Settings**, turn on **Remember visited Claude Desktop sessions** or **Remember visited Codex Desktop sessions**, then choose **Save settings**. Allow Spleen in **System Settings → Privacy & Security → Accessibility** when prompted. Check the provider's status in Spleen Settings afterward; permission alone does not establish that the current app build exposes a supported session route.

Claude discovery learns sessions you save or visit while observation is enabled. It does not import the entire Claude catalog. Its current Code session can supply working/unread metadata when available.

For Codex working and completed-turn reports, follow the separate [activity-report installation steps](../integrations/codex/README.md#set-up-activity-reports-in-a-fresh-checkout). They require Python 3.11+ and Codex's own hook review. Accessibility observation and hook installation are separate options; neither is required for Decisions assessment. See [indicator coverage and limits](LIVE_INDICATORS.md).

## Optional Decisions assessment

This feature sends bounded recent Codex message text to OpenAI to label the requested work as ongoing, waiting for the user, apparently finished, or unclear. Claude message assessment is not supported. It does not send screenshots, tool output or full history, and it never approves an action. Excerpts can still contain private information and are not anonymized.

### Prepare your own key file

1. Create an API key in your own [OpenAI Platform account](https://platform.openai.com/settings/organization/api-keys). The API project needs suitable access and [available billing/credits](https://platform.openai.com/settings/organization/billing). Spleen does not reuse your Codex sign-in or provide a shared API key. See OpenAI's [Decisions guide](https://developers.openai.com/api/docs/guides/decisions) for current availability and pricing.
2. In Terminal, create a private folder and empty file outside the repository:

   ```sh
   mkdir -p "$HOME/Library/Application Support/Spleen Credentials"
   chmod 700 "$HOME/Library/Application Support/Spleen Credentials"
   (umask 077; touch "$HOME/Library/Application Support/Spleen Credentials/openai-key.txt")
   chmod 600 "$HOME/Library/Application Support/Spleen Credentials/openai-key.txt"
   ```

3. Open `openai-key.txt` in a plain-text editor. In TextEdit, choose **Format → Make Plain Text** if needed. Paste your key as the file's only contents, or use this form with the placeholder replaced:

   ```text
   OPENAI_API_KEY=YOUR_API_KEY_HERE
   ```

   Save the file. Paste the key in the editor rather than a Terminal command so it does not enter shell history. Keep the file outside Git and shared/synced folders. The `.txt` filename is accepted; an `.env.local` file is also supported.
4. After saving, run the permission command again in case the editor replaced the file:

   ```sh
   chmod 600 "$HOME/Library/Application Support/Spleen Credentials/openai-key.txt"
   ```

The file must be a regular file, not a symlink, and have no group/other permissions. Spleen reads it in memory and does not copy the key into app data. For assessment on open, Spleen saves the file's path and reads the key again at launch; keep it at that location.

### Start with one reviewed request

1. Open Spleen and select a Codex conversation with recent, completed user/assistant messages. You can type its title to find it. Leave it selected and open **Settings**.
2. Under **Decisions assessment**, choose **Review selected conversation…**.
3. Read the exact outgoing JSON. It includes recent message text, so cancel if anything should stay local. Choosing **Send this excerpt** advances to a file picker; cancelling either dialog sends nothing.
4. Select the key file you prepared. To reach the example folder in the picker, press **⌘⇧G** and enter `~/Library/Application Support/Spleen Credentials/`. Confirming the file authorizes that one request.
5. The assessment status in Settings shows the result or an error. This action does not enable recurring requests. **Stop** cancels pending work; a request already sent may still be billed.

Empty or incomplete message windows, an unanswered latest input, or known newer Codex activity can make a conversation ineligible. In that case Settings explains why no request was sent.

### Enable assessment on open

Choose **Assess cards on open…** in the same Settings section. Read the disclosure, choose **Turn on**, then select your key file. This takes effect immediately after that flow; it does not need **Save settings**. Enabling it and relaunching the app send nothing by themselves.

On subsequent openings, Spleen assesses only eligible changed Codex cards in the compass, one request at a time. Each request is at most 20,000 encoded bytes and uses at most six recent messages. A message longer than 2,400 characters is sent as its beginning and its ending, with the middle left out and marked. Unchanged cards reuse cached results. Automatic screening skips recognizable secret-like text, but cannot guarantee removal of sensitive information. Pending work from an opening can finish after the panel closes.

Automatic assessment is capped at 100 requests per local calendar day, including failed attempts. An excerpt whose request failed can be tried again on a later opening, at most three attempts a day. The count survives relaunch, pausing and re-enabling. Manual reviews authorize separate single requests. These are request allowances, not guaranteed dollar limits.

Choose **Pause assessment on open** to stop future automatic requests. The paused choice is saved immediately. A request already sent may still complete or be billed. Deleting a local key file does not revoke the key at OpenAI; revoke it in your Platform account if it is no longer needed or has been exposed.

For the exact payload, caching and consent contract, see [assessment implementation](SESSION_ATTENTION_IMPLEMENTATION.md). Its command-line trial is a separate developer tool; ordinary setup uses the Settings flows above.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Build cannot find the required SDK or tools | Install Xcode 26 or later and select it as the active developer toolchain. Check `xcodebuild -version` in Terminal. |
| Shortcut is unavailable or already in use | Open Spleen from the menu bar, choose a different shortcut in Settings, then **Save settings**. |
| Compass has no conversations | Add an existing chat link, or use search's refresh button for Codex discovery. Claude sessions appear after saving them or visiting them with observation enabled. Cached and saved conversations remain usable when discovery fails. |
| Observer asks for Accessibility after a rebuild | Re-add the current app bundle in System Settings → Privacy & Security → Accessibility, then save Spleen Settings again. Check the provider status; an unsupported route can remain unknown even with permission. |
| Settings says to select a conversation with recent messages | Select a Codex conversation first. Discovery/enrichment must have retrieved eligible recent messages. An unanswered or incomplete window can be skipped without an API call. |
| Key-file setup fails | Use a plain-text regular file containing just the key or one `OPENAI_API_KEY=` assignment. Run `chmod 600` on that file. Choose the actual file rather than a symlink. |
| Assessment pauses after HTTP 401/403 | Check the key, project access and account restrictions in OpenAI Platform, update the file if necessary, then enable assessment again. |
| HTTP 429, a server error, or a network failure | Check API credits, limits and connectivity. Automatic attempts back off for at least a minute and need a later opening. The same excerpt is tried at most three times a day, and each attempt counts toward the daily cap. Use the reviewed single-request flow for a deliberate retry after resolving the problem. A manual request is not retried automatically. |
| Daily allowance is used | Automatic assessment becomes eligible again on the next local calendar day. Pausing or relaunching does not reset the count. |
| Saved settings or conversations appear missing | Confirm how you launched Spleen. The run script and a directly opened app use different data directories. Quit before switching between them. |

OpenAI's [API error guide](https://developers.openai.com/api/docs/guides/error-codes#api-errors) explains account, credit and access failures. Spleen remains usable for local switching when assessment is off or unavailable.

## Optional Moonshine connection

Install [Moonshine](https://github.com/d4j3y2k/moonshine#install) and open both apps once. Tab or Shift–Tab transfers the exact search between them. Moonshine searches open windows and browser tabs; Spleen searches conversations. Both work independently. See the [connection guide](INTEGRATION.md).

## Remove

Quit Spleen and move `~/Applications/Spleen.app` to the Trash. Saved state and any separate API key file remain unless you remove them. If you enabled optional Codex hooks, use the [activity-report guide](../integrations/codex/README.md) to remove that integration separately. Revoke any macOS permissions you no longer need.

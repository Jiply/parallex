# Parallex

![Parallex abstract landscape](assets/parallex-hero.png)

Parallex is an unofficial, open-source macOS menu-bar utility for people who
use local Codex with more than one ChatGPT billing account. Hover over its
menu-bar icon to see active local turns, their billing context, and one
account-bound Codex Desktop instance for each saved profile.

Parallex is not affiliated with or endorsed by OpenAI. Codex, ChatGPT, and
OpenAI are trademarks of OpenAI.

## What it does

- Shows active top-level local Codex sessions, including their indexed title,
  workspace, and active subagent count.
- Shows the ChatGPT email and plan returned by the local Codex app-server, when
  available.
- Identifies API-key and Amazon Bedrock authentication when Codex reports it.
- Warns when file-backed credentials changed after a turn began.
- Opens, focuses, or closes Codex Desktop instances for saved billing accounts.

Parallex never creates a Codex chat. The bulk-open action brings running
account instances forward and opens stopped instances at their normal history
view. The bulk-close action gracefully terminates only account instances managed
by Parallex. Parallex itself has no Dock icon or windows.

The **Hide email** preference updates the open menu and persists between
launches. Observed account and session data does not persist.

## Requirements

- macOS 14 or later.
- Codex Desktop installed in `/Applications`.
- Xcode Command Line Tools, including Swift. Install them with:

  ```sh
  xcode-select --install
  ```

## Quick start

Clone or download the repository, then run from its root:

```sh
./script/build_and_run.sh
```

Parallex builds to `dist/Parallex.app` and opens as a Dock-free menu-bar app.
Hover over its icon to reveal the menu. To keep the locally built app, drag
`dist/Parallex.app` into `/Applications`.

Choose **Add billing account…**, enter its email address, and complete the
OpenAI sign-in that opens in your browser. Repeat for each additional billing
account, then choose **Open one Codex desktop instance per billing account**.
Parallex focuses or starts every configured account instance without creating a
chat. Each Desktop keeps the same credentials for its entire lifetime, so
Account A and Account B can run concurrently without changing credentials
underneath active work. Active turns appear beneath the billing account
currently paying for their inference.

Useful commands:

| Command                              | Purpose                                             |
| ------------------------------------ | --------------------------------------------------- |
| `./script/build_and_run.sh build`    | Build without opening the app.                      |
| `./script/build_and_run.sh run`      | Build and open the app.                             |
| `./script/build_and_run.sh --verify` | Build, open, and confirm the process stays running. |
| `./script/build_and_run.sh --debug`  | Build and run the executable under LLDB.            |
| `./script/build_and_run.sh --logs`   | Build, open, and stream process logs.               |
| `./script/build_and_run.sh icon`     | Regenerate `Resources/Parallex.icns`.               |
| `./script/clean.sh`                  | Remove generated build output and Finder metadata.  |

## Account instances and shared state

Parallex discovers saved profiles from this local layout:

```text
~/.codex                                 shared Codex state
~/.codex-accounts/<email>/home           private account home and auth.json
~/.codex-accounts/<email>/desktop        private Desktop browser state
~/.codex-accounts/<email>/.parallex-codex
                                         private runtime credential shim
```

The shim starts the bundled Codex backend with the canonical shared data home
and process-local authentication. A separate credential helper uses the
profile's private `auth.json` for login and refresh. Tokens pass through local
pipes into that instance's memory; the shared `auth.json` is never replaced.
The shim contains no credential data.

Browser authentication reads use the same profile's native credential helper.
At backend startup and when a thread opens or resumes, the relay aligns browser
runtime paths with the installed app and trusts the canonical shared plugin
location. Each Desktop launch starts a fresh browser tool runtime. Launcher
preflight restores missing browser bundles from that exact app version, keeping
vendor files and backing up incomplete cache entries. It does not restart active
apps or run a restart loop; browser connectivity still depends on Chrome, its
extension, and the account's current authentication.

Every managed backend uses `~/.codex` for both `CODEX_HOME` and
`CODEX_SQLITE_HOME`. Session files, databases, configuration, attachments,
plugins, and writer locks therefore have one source of truth, including new
storage paths introduced by Codex updates. The Desktop process uses a private
home for its IPC channel: native cross-window execution forwarding would
otherwise bill the task owner's account instead of the sending window's account.

Desktop bootstrap configuration, preferences, browser state, and temporary
plugin installation files remain private. The backend uses the canonical
configuration. Task title updates refresh other instances' catalogs. While
Parallex runs, its local IPC bridge shares read/unread, archive, and unarchive
metadata between saved profiles. One native notification router starts per
account before Desktop opens and stays available across app restarts, preventing
clients from splitting across competing sockets. Unread state is reconciled after reconnects and
restarts using a private local journal, including reads made while Parallex is
stopped. On first adoption, conflicting lists preserve unread notifications;
subsequent explicit read/unread changes establish the shared state. It never
forwards execution requests, approvals,
or credentials across accounts. Remote hosts remain separate.

When another account opens an idle task, the relay asks its backend to release
the writer and waits for Codex to confirm closure before resuming it with the
new account. Active tasks keep their current owner. Their saved history remains
readable through Codex's local read API, but Codex Desktop does not expose a
passive cross-account live view.

Parallex never replaces an unrecognized or divergent profile item. Declared
shared-state paths link the canonical item so there is only one source of truth;
a conflicting local item stops launch unchanged. Account directories are
owner-only, and `auth.json` must be a regular non-symbolic-link file.

Do not log out of the default Codex instance to add another account: that
changes the credentials in `~/.codex`. Parallex instead runs login with the
new profile's private account home. For a manual recovery workflow, paste
[CODEX_SETUP_PROMPT.md](CODEX_SETUP_PROMPT.md) into your local Codex.

Codex does not expose a complete desktop synchronization API. Its in-memory
preferences, project organization, and live views cannot all be synchronized
through the supported protocol. Sharing its preferences JSON file would risk
overwriting another window's changes. Parallex does not claim complete UI
synchronization. Keep normal backups and avoid concurrent edits to one task.

Run `python3 tests/read_state_bridge.py` to verify read-state synchronization
against isolated IPC servers, including reconnects, process restarts, and missed
read events. Run `python3 tests/native_ipc_router.py` on macOS with Codex
installed to verify native router startup, singleton ownership, routing, and
restart takeover. The sidebar CI workflow runs the bridge test and builds the
app. Run
`python3 tests/profile_state.py` to verify
profile migration and preservation of existing settings. Run
`python3 tests/event_relay.py` to verify response framing and lifecycle filtering,
and `python3 tests/credential_bridge.py` to verify credential isolation.
Run `python3 tests/browser_configuration.py` for browser account and trust-path
isolation, and `python3 tests/writer_handoff.py` for idle task handoff.

## Privacy

Parallex has no analytics, update service, or network client. It inspects
same-user local processes and Codex state, asks a locally started Codex
app-server for `account/read`, and starts account-bound Desktop processes only
when selected. The runtime relay reads credentials only to authenticate the
corresponding local backend, and the IPC bridge reads account identity claims
for read-state matching. Credentials are never displayed or logged. Codex
handles authentication and network requests.

Read [PRIVACY.md](PRIVACY.md) for the exact fields and transient buffers the app
accesses.

## Accuracy and limitations

- Parallex reports the account associated with each observed Codex home. Codex
  rollouts do not contain an authoritative historical billing email for every
  turn.
- A chat is not inherently bound to its original billing account. Its next turn
  is billed through the account instance that resumes it.
- Do not resume the same chat concurrently in multiple account instances.
- The account-changed warning uses the modification time of file-backed
  `auth.json` and cannot make that inference for Keychain-only credentials.
- API-key authentication identifies the billing mode, but `account/read` does
  not reveal the specific OpenAI Platform organization or project being billed.
- Only turns running locally on this Mac are shown. Codex cloud tasks and idle
  or completed local threads are outside the active-session list.
- The Codex app-server and rollout formats may change. Parallex can require an
  update after a Codex release.

## Distribution status

The build script creates a current-architecture app with an ad-hoc signature.
That is appropriate for building and running Parallex locally. It is not a
Developer ID-signed or notarized release for redistribution to other Macs.
There are currently no official prebuilt binaries.

## Security

Report security issues using [SECURITY.md](SECURITY.md), and never attach Codex
credentials or rollout transcripts to a public issue.

Parallex is available under the [MIT License](LICENSE).

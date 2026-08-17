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
- Opens or focuses one Codex Desktop instance for every saved billing account.

Parallex never creates a Codex chat. The bulk-open action brings running
account instances forward and opens stopped instances at their normal history
view. Parallex itself has no Dock icon or windows.

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

Choose **Open one Codex desktop instance per billing account**. Parallex focuses
or starts every configured account instance without creating a chat. Each
Desktop keeps the same credentials for its entire lifetime, so Account A and
Account B can run concurrently without changing credentials underneath active
work. Active turns appear beneath the billing account currently paying for
their inference.

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

The shim pins the bundled Codex runtime to file-backed ChatGPT credentials in
that profile. It does not open the Desktop or create a chat, and it contains no
credential data.

Each Electron Desktop receives the canonical `~/.codex` as its `CODEX_HOME` and
`CODEX_SQLITE_HOME`, so every instance reads the same project/sidebar state and
local history. Its browser and login state remains private under the profile's
`desktop` directory; runtime caches, logs, and IPC remain private under the
profile's account home.

Only the generated runtime shim changes `CODEX_HOME` to the profile's private
account home before Codex starts. The runtime therefore reads that account's
file-backed credentials while continuing to use shared SQLite-backed history.
Profiles also link selected non-auth state from `~/.codex`, including sessions,
configuration, skills, rules, attachments, automations, and worktrees. Parallex
removes obsolete profile-local global-state files from older layouts because
Codex Desktop reads the canonical shared state directly.

Parallex never replaces an unrecognized or divergent profile item. Declared
shared-state paths link the canonical item so there is only one source of truth;
a conflicting local item stops launch unchanged. Account directories are
owner-only, and `auth.json` must be a regular non-symbolic-link file.

For a copy-pasteable setup workflow, paste
[CODEX_SETUP_PROMPT.md](CODEX_SETUP_PROMPT.md) into your local Codex.

Codex documents `CODEX_HOME` and `CODEX_SQLITE_HOME`, but running multiple
Desktop instances against shared thread files is not an officially documented
multi-account feature. Keep Parallex and Codex current, avoid editing the same
chat or reorganizing projects concurrently in two instances, and retain normal
backups of local work.

## Privacy

Parallex has no analytics, update service, or network client. It inspects
same-user local processes and Codex state, asks a locally started Codex
app-server for `account/read`, and starts account-bound Desktop processes only
when selected. Parallex validates credential file metadata but never reads,
copies, parses, displays, logs, or transmits credential contents. Codex itself
retains responsibility for its normal authentication and network activity.

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

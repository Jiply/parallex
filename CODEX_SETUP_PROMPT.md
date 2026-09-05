# Set up this Mac for Parallex account instances

This is a manual recovery workflow. Prefer Parallex's **Add billing account…**
menu action for normal setup. Never log out of the default Codex Desktop
instance to add an account because that changes `~/.codex/auth.json`.

Implement the setup below on this Mac; do not only explain it. All Parallex
state and credential movement must remain local. Preserve all existing Codex
data and never print, decode, paste into chat, or commit any credential or
token. Codex's normal interactive authentication is the only network step.

First inspect `~/.codex` and `~/.codex-accounts` structurally. Do not read or
print credential contents. If `~/.codex` does not exist, tell me to open Codex
once and stop. If I have not supplied the ChatGPT billing email addresses I
want to use, ask only for those addresses.

Use this layout for every lowercase email address:

```text
~/.codex                                  shared Codex state
~/.codex-accounts/                        account vault, mode 0700
~/.codex-accounts/<email>/                account root, mode 0700
~/.codex-accounts/<email>/home/           private CODEX_HOME, mode 0700
~/.codex-accounts/<email>/home/auth.json  private credentials, mode 0600
~/.codex-accounts/<email>/desktop/        private Desktop state, mode 0700
~/.codex-accounts/<email>/.parallex-codex
                                          private runtime shim, mode 0700
```

Each account home must keep `auth.json`, `installation_id`, `cache`,
`models_cache.json`, logs, and IPC private. Never link those items from another
account. Do not copy or link `.codex-global-state.json`; the Electron Desktop
process reads project/sidebar state directly from the canonical `~/.codex`.

For each source that currently exists in `~/.codex`, create an absolute
symbolic link with the same name inside every account `home` for:

```text
.tmp
AGENTS.md
AGENTS.override.md
archived_sessions
attachments
automations
browser
computer-use
config.toml
generated_images
history.jsonl
node_repl
pets
plugins
rules
sessions
shell_snapshots
skills
state
themes
tmp
transcription-history.jsonl
vendor_imports
visualizations
worktrees
```

Also link every top-level `~/.codex/*.config.toml` file. Skip sources that do
not exist and keep an existing correct link. Any other existing item at a
declared shared path is a conflict: leave it unchanged, stop, and report it.
Never replace anything outside this explicit list.

For the account already active in `~/.codex`, use the local Codex app-server
`account/read` method with token refresh disabled to identify its email. If that
email is requested and `~/.codex/auth.json` is a regular file, copy it to the
matching profile's `home/auth.json` without printing its contents. Use a
same-directory temporary file with mode `0600` followed by an atomic rename.

For every other requested account that lacks credentials, authenticate through
the installed Codex CLI with that private account home:

```sh
CODEX_HOME="$HOME/.codex-accounts/<email>/home" codex \
  -c cli_auth_credentials_store=file \
  -c forced_login_method=chatgpt \
  login
```

Let me complete Codex's normal browser authentication. This command provisions
credentials only and must not start a task. After login, verify through the
local app-server that the reported email exactly matches the profile directory.
If it does not match, stop and report only the mismatch.

Create `.parallex-codex` as a narrow runtime shim. It must export the profile's
absolute account-home path as `CODEX_HOME`, then `exec` Parallex's bundled Codex
event relay with the installed Codex Desktop runtime as its first argument,
preserve all received arguments with `"$@"`, and prepend:

```text
-c cli_auth_credentials_store=file
-c sqlite_home=<absolute path to ~/.codex>
-c forced_login_method=chatgpt
```

Quote generated paths safely. The shim contains paths and configuration flags
only; it must never contain a token or open Codex itself.

Do not create a task launcher, deep link, or `codex://threads/new` command.
Parallex starts the existing Desktop executable only after I select **Open one
Codex desktop instance per billing account**. It supplies the canonical
`~/.codex` as each Electron process's `CODEX_HOME` and `CODEX_SQLITE_HOME`, plus
the private Desktop data directory and runtime shim. Only the runtime shim
switches to the private account home for credentials. Each Desktop opens
normally without creating a chat.

When finished, verify directory and shim permissions, verify every credential
is a regular non-symbolic-link file with mode `0600`, and verify every created
link resolves into `~/.codex`. Summarize only paths and status—never credential
contents, token fragments, hashes, or byte samples.

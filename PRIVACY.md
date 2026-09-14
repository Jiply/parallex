# Privacy

Parallex is designed to observe local Codex activity and keep simultaneous
billing accounts isolated without sending that data to another service.

## Data accessed

On each refresh, Parallex may access:

- same-user Codex process IDs, executable paths, and profile-identifying launch
  arguments;
- `CODEX_HOME`, `CODEX_SQLITE_HOME`, and `CODEX_CLI_PATH` from the process argument/environment
  buffer;
- paths of rollout files currently open by Codex processes;
- lifecycle markers and timestamps in those rollout files;
- the first `session_meta` record, including thread ID, originator, subagent
  parent thread ID when present, and the last component of the working-directory
  path;
- indexed thread titles from `session_index.jsonl`;
- account type, email, and plan returned by the local Codex app-server's
  `account/read` method;
- the modification time of file-backed `auth.json`, when present;
- credential file metadata such as type and size before an account instance is
  opened;
- local app-server thread notifications and protocol messages while profile
  instances are open;
- account identity claims and each profile’s own persisted unread-task list for
  matching and reconciling local read-state notifications;
- private profile credentials, solely to authenticate that profile's backend
  through local pipes.

macOS returns the complete process argument/environment buffer, and rollout
reads occur in bounded byte buffers. Transient buffers can contain fields
Parallex does not use. The monitor decodes only the fields listed above. The
relay mediates authentication messages and passes task traffic to the bundled
Codex backend. Task names, native read/archive metadata, and idle writer-handoff
identifiers are shared between account windows; credentials and task execution requests are not
broadcast. Protocol buffers are transient and are not written to logs.

## Data stored

Observed accounts and sessions remain in memory. Parallex stores one boolean in
macOS user defaults: whether email addresses should be hidden. It does not store
account emails, thread titles, workspace names, process details, or scan
history. The owner-only `~/.codex/parallex-read-state.json` journal stores task
IDs, read/unread booleans, hashed profile and identity keys, and reconciliation
snapshots. It contains no task contents or credentials and is atomically updated
to recover missed notifications across restarts. Each account’s `ipc` directory
also holds an owner-only kernel lock file and a readiness record containing the
router’s process ID.

Saved profiles are user-managed directories under `~/.codex-accounts`. When an
account is added or its instance is first opened, Parallex may create or update:

- an owner-only `desktop` directory for that account's Desktop browser state;
- a private account home where the installed Codex login process writes its
  file-backed credentials;
- safe links from its account home to recognized non-auth state in `~/.codex`;
- an owner-only `.parallex-codex` runtime shim containing local paths and
  configuration flags, but no credential data.

Parallex never replaces an unrecognized or divergent profile item. Declared
shared paths must be absent or already link to the canonical item; a conflict
stops launch without deleting it. Desktop preferences and bootstrap configuration
are seeded once from the shared home and then remain private. Known links to
these private bootstrap files are replaced with copies while their shared
targets remain intact. All inference backends use the canonical shared data home.
Launcher preflight can restore missing browser plugin bundles from the installed
app into the shared cache, preserving vendor files and backing up incomplete
entries. Browser authentication reads use the selected profile's native helper.

## Network behavior

Parallex contains no analytics, telemetry, or update checker. A small persistent
process per account loads the installed Codex app’s unmodified IPC implementation
in memory using its bundled Node runtime. It establishes one Unix-domain socket
router before Desktop launches and routes native messages only within that
account. It does not read credentials or send data to external services. These
routers remain available when Parallex or Desktop quits.
For account information it starts the installed Codex executable as a local
stdio app-server, disables plugins and apps for that probe, and sends
`account/read` with token refresh disabled. When **Add billing account…** is
selected, Parallex starts the installed Codex login process with that account's
private home; Codex opens and owns the browser authentication flow. When the
bulk-open action is selected, Parallex may start one installed Codex Desktop
process per configured billing account. The runtime credential helper asks Codex to refresh the selected account when
needed. Codex performs all authentication and network requests.

## Credentials

Each account keeps its own regular, non-symbolic-link
`~/.codex-accounts/<email>/home/auth.json`. The relay validates and reads that
file, then supplies its access token to the corresponding backend using Codex's
external-authentication protocol over a local pipe. The backend stores this
authentication in process memory. Login, logout, and refresh are handled through
a separate Codex credential process using that profile's private home. The
shared `auth.json` is not modified. Credential values never appear in generated
shims, command arguments, application logs, or UI.

The read-state bridge decodes account identity claims solely to match local IPC
notifications. It does not forward tokens. Treat every `auth.json` as a password
and never include one in a bug report.

## User control

- Select **Add billing account…** to create and authenticate a private profile.
- Select **Hide email** to replace visible account emails with **Email hidden**.
- Select **Close all Codex instances** to terminate every account instance
  managed by Parallex without affecting an unmanaged Codex instance.
- Close an account's Codex Desktop window or process to stop that instance.
- Remove `~/.codex-accounts/<email>` to delete one local account profile after
  closing its Desktop. Shared state linked from `~/.codex` is not deleted.
- Select **Quit Parallex** to stop observation immediately. Codex Desktop
  instances remain under normal Codex control.
- Remove Parallex from Applications and run
  `defaults delete org.curvelabs.Parallex hideEmailAddresses` to remove the app
  and its persisted preference. Remove `~/.codex/parallex-read-state.json` to delete
  the notification journal. Saved profiles remain until you remove them.

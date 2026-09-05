# Privacy

Parallex is designed to observe local Codex activity and keep simultaneous
billing accounts isolated without sending that data to another service.

## Data accessed

On each refresh, Parallex may access:

- same-user Codex process IDs, executable paths, and profile-identifying launch
  arguments;
- `CODEX_HOME` and `CODEX_SQLITE_HOME` from the process argument/environment
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
- local app-server `thread/started`, `thread/name/updated`, and
  `thread/status/changed` notifications while profile instances are open.

macOS returns the complete process argument/environment buffer, and rollout
reads occur in bounded byte buffers. Those transient buffers can contain fields
Parallex does not use. During ordinary refreshes, the app decodes only the
fields listed above. Legacy global-state cleanup reads filesystem metadata only
to confirm that each obsolete item is a regular file or symbolic link. It does
not display or log other fields. The runtime relay passes all app-server traffic
through unchanged and copies only the three listed thread notifications to other
local profile instances. It does not persist or transmit them over a network,
and it discards transient buffers after use.

## Data stored

Observed accounts and sessions remain in memory. Parallex stores one boolean in
macOS user defaults: whether email addresses should be hidden. It does not store
account emails, thread titles, workspace names, process details, or scan
history.

Saved profiles are user-managed directories under `~/.codex-accounts`. When an
account is added or its instance is first opened, Parallex may create or update:

- an owner-only `desktop` directory for that account's Desktop browser state;
- a private account home where the installed Codex login process writes its
  file-backed credentials;
- safe links from its account home to recognized non-auth state in `~/.codex`;
- an owner-only `.parallex-codex` runtime shim containing local paths and
  configuration flags, but no credential data.

Parallex never replaces an unrecognized or divergent profile item. Declared
shared-state paths must be absent or already link to the canonical `~/.codex`
item. A conflict stops launch without deleting it. Parallex removes obsolete
profile-local `.codex-global-state.json`, `.codex-global-state.json.bak`, and
`.codex-global-state.before-parallex-sharing.json` items after validating that
each one is a regular file or symbolic link. It never rewrites the canonical
file; Codex Desktop reads it directly because each Electron process receives
the shared Codex home.

## Network behavior

Parallex contains no analytics, telemetry, update checker, or network client.
For account information it starts the installed Codex executable as a local
stdio app-server, disables plugins and apps for that probe, and sends
`account/read` with token refresh disabled. When **Add billing account…** is
selected, Parallex starts the installed Codex login process with that account's
private home; Codex opens and owns the browser authentication flow. When the
bulk-open action is selected, Parallex may start one installed Codex Desktop
process per configured billing account. Codex performs its own authentication
and network activity independently of Parallex.

## Credentials

Each account keeps its own regular, non-symbolic-link
`~/.codex-accounts/<email>/home/auth.json`. Parallex validates only file metadata
before launch. It does not read, copy, parse, display, log, or transmit the
contents, and it never hot-swaps credentials beneath a running Codex process.

The private runtime shim forces file-backed ChatGPT authentication so separate
instances do not collapse into one shared Keychain credential. Treat every
`auth.json` as a password and never include one in a bug report.

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
  and its persisted preference. Saved profiles remain until you remove them.

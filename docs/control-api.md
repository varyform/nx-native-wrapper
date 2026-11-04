# Local control API and MCP

Scripts and AI agents on your Mac can drive NX Play without clicking its window. NX Play has an HTTP API inside the running app, on 127.0.0.1 only, and an MCP server on top of it, reached through that API or over stdio through a small adapter. The API runs NX Play's own operations on the library the window shows, so a change made through it is the window's change too. The window redraws, and the setting is saved where the Settings window saves it.

It is **off unless turned on**.

## Turning it on

NX Play checks these when it starts:

| How | Effect |
| --- | --- |
| `NX Play.app/Contents/Resources/nxplay_control.py enable` (creates `control-api/enabled`) | On at every launch |
| `open -a "NX Play" --args --control-api` | On for this launch |
| `NXPLAY_CONTROL_API=1` / `=0` in NX Play's environment | Forces it on or off. `0` wins over the other two. |
| `NXPLAY_CONTROL_PORT=<1024–65535>` | A fixed port instead of a random one (still 127.0.0.1 only) |
| `NXPLAY_CONTROL_DIR=/abs/path` | Another folder for the endpoint file, for a test instance |

The folder is `~/Library/Application Support/NX Play/control-api`. The switch is read at launch, so restart NX Play after `enable`. Screenshot mode never starts the API.

## Security

- **Loopback only.** The listener is bound to 127.0.0.1, and every connection is checked again for a loopback peer. Nothing on the network can reach it.
- **Its own credential.** Each start makes a new 64-hex-digit token from the system's random generator. It is written only to `control-api/endpoint.json` (file mode 0600, folder 0700, never through a link) and is compared in constant time. It is never logged and never sent in an answer. The file is removed when NX Play quits.
- **The iOS app's pairing code opens nothing here.** The pairing code (Settings › Devices, port 47474 on the local network) opens only the iOS app's API, and the control token opens nothing there. No command shows the pairing code or a Sources access token.
- **Web pages are refused.** The `Host` header must be `127.0.0.1:<port>` or `localhost:<port>`, which stops DNS rebinding. Any `Origin` or `Sec-Fetch-*` header is refused. POST bodies must be `application/json`. `OPTIONS` is refused, and no CORS header is ever sent.
- **Bounds.** A request head is limited to 16 KiB and a body to 1 MiB. Bodies use `Content-Length` only: a chunked body, a repeated `Content-Length`, `Host` or `Authorization`, and a proxy-style absolute target are all refused. A client has 10 s to send its request. There are at most 16 connections and 32 unfinished calls at once. Waits are capped: a call at 10 min, an event poll at 30 s. The API keeps 256 jobs and 2000 events.
- **No shell, files or secrets.** No command runs a program it is given, reads or writes an arbitrary file, or returns a key, token or pairing code. A job keeps its arguments with any secret-named value shown as `***`, and any address in them, its error or its result loses its user, password and secret-looking query values (`token`, `key`, `sig`…) before it is kept. A query name is judged as a server reads it, percent-decoded (`%74oken` is `token`, `%2574oken` too), with malformed escapes left as they are; the address keeps its own encoding and only the value becomes `***`. A name that carries its value with an encoded `=` (`token%3D…`), an address written fully encoded, a redirect's address inside a value, and an encoded token in a fragment go too. Whatever was hidden from a call's arguments is hidden from the rest of its job as well (its error, result, progress and outcome), also where it is quoted back decoded or without its address. Encoded text is read to the end however many times it was encoded, within a work budget per field (proportional to its size, with a floor), not a fixed depth: a field that can't be read within it is shown whole as `***`, and Sources refuses such an address. Every event is kept scrubbed the same way, whoever produced it (a job, or a change the API saw: a search, a download's message, a build's text, an install's status), and a job's events also lose what its arguments hid. So an address the backend refuses for carrying a credential isn't kept with it. Paths are taken only where the window takes one: the games folder and the save folders, each checked to be an existing folder. `nxnativePath` and `keysPath` are read-only here, because they name the code builds run and the keys they read.
- **No redirects, no proxies.** The API never redirects. The adapter talks to 127.0.0.1 with `http.client`, which neither uses a proxy nor follows a redirect. It refuses an endpoint file that another user can read or that sits in a folder others can write to.

## HTTP API

Every request needs `Authorization: Bearer <token>`. Errors look like `{"ok": false, "error": {"code", "message"}}`, with a matching HTTP status.

| Route | What |
| --- | --- |
| `GET /v1/status` | The app, the API and the library at a glance |
| `GET /v1/commands?query=&group=` | Every command, in short |
| `GET /v1/commands/<name>` | One command in full: its effect, cancel and `input_schema` |
| `POST /v1/invoke` | `{command, args?, wait?: "answer" \| "done", timeout_ms?}`. See below. |
| `GET /v1/jobs`, `GET /v1/jobs/<id>?wait_ms=` | Jobs: `queued`, `running`, `cancelling`, `succeeded`, `failed` or `cancelled`, with progress, result and outcome |
| `POST /v1/jobs/<id>/cancel` | Cancels the job's work through NX Play's own Cancel |
| `GET /v1/events?after=&names=a,b&limit=&wait_ms=` | Numbered events. Pass `next_after` back as `after` (0 to 2147483647). `limit` is 1 to 1000, `wait_ms` long-polls for up to 30 000. A value out of range or not a whole number is `400 invalid_args`. `missed` is true when events after `after` were dropped before being read. |
| `GET /v1/settings`, `POST /v1/settings {patch}` | The settings, or a change to them |
| `GET /v1/limitations` | What the API doesn't do |
| `POST /mcp` | MCP JSON-RPC |

**Invoke.** Every call is a job. A command that answers at once returns `200 {ok, result, job_id}`. Builds, installs, plays and downloads start the library's own work and answer at once with `202 {ok, job_id, result, job}`. Follow the work with `GET /v1/jobs/<id>?wait_ms=` or the events. With `wait: "done"`, the call waits up to `timeout_ms` for the work to end, then answers `200` with its `state` and `outcome`. Arguments are checked against the command's schema first: an unknown key, a missing key or a wrong type gives `400 invalid_args`.

**Jobs follow the library's own records.** A build job follows the very `Job` the window shows. A download job follows one run of a download: its id and its `attempt`, which each Retry raises by one while keeping the id. An Install NX Play job follows that run's own id. A job's state is read from that record, never kept twice. Once the work ends, the job's state is frozen. A run another one replaced is kept by the backend as it ended: a Retry from the Sources window, the iOS app or a call, or another Install NX Play from Settings, can't be taken for the run a job followed, and cancelling that job never reaches the new run.

**Cancel.** Cancel goes in at once, because every command has started its work (or refused) by the time it answers. A queued build or download ends as `cancelled` right away. A running one shows `cancelling` until NX Play reports how it ended. A job is never reported cancelled before its process or transfer has stopped. A build is stopped with SIGINT, then SIGTERM, then SIGKILL; a download's partial file is deleted. Jobs that end on their own answer `409 not_cancellable`, and an ended job answers `409 already_finished`. `games.stop` and `downloads.cancel` stop work whoever started it: the window, the controller or the iOS app.

**Settings.** `settings.update` checks the whole patch, then applies it in the same main-actor step: all of it or none. Each key goes through the same property the Settings window uses, so it is saved and drawn. Only the keys given change. `globalChoices` is merged key by key, and `null` takes a key back to each game's default. So two patches made at the same time, and the window's own changes, are all kept. There is no whole-object save that could put old values back.

**The window stays coherent.** A refused build answers with its reason as an error. It doesn't leave the window's "Can't run nxplay" alert behind: the message is taken back in the same main-actor step, before the window draws. `games.extract_all` and `games.update_all` start each game the same way: they answer with the games that started (`queued`) and why each other one didn't (`refused`), and with `422` when none started (`409` when there was nothing to start). `ui.open` queues a request for the main window, which opens every queued window and answers each request on its own: `opened: true` means that very window was opened. A request nobody answered within 2 s reports `opened: false` and is withdrawn, so it can't open later. NX Play is brought forward either way.

**Deleting files takes turns.** Free Up Space's Delete (`cleanup.delete` and the window's button) and Remove Game (`games.remove` and the window's sheet) run one at a time, first come first served, and hold the games they touch while they run: no build, play or install starts on a held game, Keep This Build can't be changed on it (the window's toggle is off and `games.set_kept` answers `409`), and it can't be removed meanwhile. Right before deleting a build, its keep marker is read from the disk again: one written since the scan by anything else protects the build all the same. Each deletion is judged only when its turn comes: NX Play reads the games folder again, scans it, and deletes nothing unless every path is still listed, not blocked, not busy, and not a build going with its own game's files. So two deletions chosen from the same scan, one taking a game's files and the other its build, can't both go through: the second sees a game whose build is all it has left, and is refused with `409`. A refused deletion deletes nothing.

**Events.** NX Play's changes are seen through Observation, whoever made them, and logged as these events:

| Event | When |
| --- | --- |
| `job` | A job changed state |
| `build` | A game's build, play or install changed status or progress, in whole percents |
| `download` | A download changed state or progress |
| `library` | The games folder or its games changed |
| `sources` | A source was added, removed, turned on or off, or loaded |
| `settings` | Settings changed; `changed` lists which |
| `ui` | Selection, search, Console Mode, a question or the Settings tab changed |
| `ios_app` | Install NX Play started, moved on to its next step, or ended |

## Commands (coverage inventory)

`GET /v1/commands` lists these from the running app. A test checks the list against this table.

| Command | Effect | What it runs |
| --- | --- | --- |
| `library.status` | read | the games folder, builds, downloads, waiting questions |
| `library.refresh` | write | Refresh |
| `library.inspect_folder {path}` | read | what a folder holds as a games folder (`GameScanner`), without choosing it |
| `library.set_folder {path}` | write | Choose Games Folder… (refused while builds or downloads run) |
| `setup.status` | read | whether nxnative and its Python environment are installed |
| `games.list {query?}`, `games.get {game}`, `games.log {game, lines?}` | read | the games, one in full, its job's output |
| `games.extract`, `games.rebuild`, `games.build_ipa`, `games.make_mac_app` `{game, select?}` | write, job | Extract, Rebuild, Build IPA, Make Mac App, queued one at a time |
| `games.install {game, device, select?}` | write, job | Install on Device |
| `games.play {game, select?}` | write, job | Play. It may wait for `games.answer_update` or `games.answer_save`. |
| `games.stop {game}` | write | Stop or Cancel the game's job |
| `games.answer_update {answer, game?}`, `games.answer_save {choice, remember?, game?}` | write | the play's questions |
| `games.set_kept {game, kept}` | write | Keep This Build (`409` while Free Up Space or Remove Game holds the game) |
| `games.settings {game}`, `games.set_setting {game, env, value}`, `games.clear_settings {game}`, `games.forget_save_choice {game}` | read / write | Game Settings… |
| `games.extract_all`, `games.update_all {onlyWhilePluggedIn?}` | write | Extract All, Update All Builds… |
| `games.remove {game, removeSaves?, confirm}` | destructive | Remove Game… (`confirm` = the game's id) |
| `settings.get`, `settings.update {patch}` | read / write | Settings, without secrets |
| `companion.status` | read | the iOS app's server: on or off, port, addresses, Bonjour, Tailscale (never the pairing code) |
| `sources.list`, `sources.entries {source?, query?}` | read | Sources, with whether a token is saved |
| `sources.add {url, name?}`, `sources.set_enabled {source, enabled}` | write | Add Source (without a token), Turn On/Off |
| `sources.remove {source}` | destructive | Remove Source (and its Keychain token) |
| `sources.refresh {source?}` | read, network | Refresh |
| `downloads.list` | read | Downloads |
| `downloads.start {source, entry, packages?}`, `downloads.retry {download}` | write, job, network | Download, Retry |
| `downloads.cancel {download}` | write | Cancel |
| `devices.list {refresh?}` | read | devices and teams (devicectl, Xcode) |
| `ios_app.install {device}` | write, job | Install NX Play on a device |
| `cleanup.scan {measure?}` | read | Free Up Space's list |
| `cleanup.delete {paths, confirm}` | destructive | Free Up Space › Delete: only paths the scan lists, with its rules, `confirm` = `yes, I'm sure`; one deletion at a time, judged again when its turn comes (`404` for a path no longer listed, `409` for one that no longer holds) |
| `ui.state`, `ui.select {game}`, `ui.search {text}`, `ui.console_mode {on}`, `ui.open {window, tab?}` | read / write | the window |

Not available: native file pickers, Setup, Uninstall, app updates, turning on the iOS app's server or changing its port or code, Sources access tokens, Transfer Saves, nxnative Notes and Finder actions. `GET /v1/limitations` says what to use instead.

## MCP

The MCP server handles `initialize`, `ping`, `tools/list` and `tools/call`, for protocol versions 2025-11-25, 2025-06-18, 2025-03-26 and 2024-11-05. A notification gets `202` with no body. Batches are refused. An unknown `MCP-Protocol-Version` header gets `400`. Tools:

- `nx_<command>` for each command, with dots replaced by underscores: `nx_games_extract`. The command's parameters are the tool's input schema. The annotations are `readOnlyHint`, `destructiveHint` (true only for `games.remove`, `cleanup.delete` and `sources.remove`), `idempotentHint` and `openWorldHint`.
- `nxapi_status`, `nxapi_list_commands`, `nxapi_describe_command`, `nxapi_invoke`, `nxapi_jobs`, `nxapi_job` (with `wait_ms`), `nxapi_cancel_job`, `nxapi_events` and `nxapi_limitations`.

A result carries `structuredContent` (`{ok, result | error, job_id, job?}`) and the same JSON as text. A refusal or failure is an `isError: true` result. An unknown tool is JSON-RPC error `-32602`.

### stdio adapter

`Control/nxplay_control.py` uses the standard library only and runs on Python 3.8 or later. It is bundled as `NX Play.app/Contents/Resources/nxplay_control.py`. It reads the endpoint file for every message, so a restarted NX Play is picked up. It sends each JSON-RPC line to `/mcp` and prints the answer, and stdout carries protocol messages only. When NX Play isn't reachable, a request gets JSON-RPC error `-32000`. `--tools meta` lists only the `nxapi_*` tools.

```sh
claude mcp add nxplay -- python3 "/Applications/NX Play.app/Contents/Resources/nxplay_control.py" mcp
```

### Command line

```sh
C="/Applications/NX Play.app/Contents/Resources/nxplay_control.py"
python3 "$C" status
python3 "$C" commands --group games
python3 "$C" describe games.extract
python3 "$C" call games.list
python3 "$C" call games.extract --arg game="Metroid Dread"      # → job id
python3 "$C" job job-3 --wait-ms 120000
python3 "$C" cancel job-3
python3 "$C" events --follow --names build,download
python3 "$C" settings '{"viewStyle": "list"}'
python3 "$C" endpoint      # where the file is and whether NX Play answers (never the token)
```

Exit codes: 0 ok, 1 the call failed, 2 usage, 3 NX Play's control API isn't reachable.

## Tests

```sh
swift test --package-path Packages/NXPlayKit --filter 'ControlTests|ControlRecheckTests'
python3 -m unittest discover -s Control -p 'test_*.py'
```

`ControlTests` run a real loopback server on a synthetic library. They cover:

- auth, the pairing code being refused in both directions, the Host, Origin and Sec-Fetch guards, the request bounds, and loopback-only listening
- the commands on a synthetic games folder, with refused builds leaving no alert behind
- settings: atomic, persisted, and patched at the same time as the window changes them
- jobs following a real process that stands in for nxplay: cancel while running, while queued, and of an ended job
- a download from a synthetic catalog, cancelled and then retried as a new job
- cleanup and removal confirmations, the window, events and long polls
- MCP over HTTP, and the stdio adapter end to end

`ControlRecheckTests` cover the races and contracts an independent review found: two deletions from the same scan (in both orders, and the window's against a call), a game that becomes busy while a deletion scans, nothing starting on a held game, deletions taking turns in order, a Retry from the Sources window or the iOS app, Install NX Play's end and a later run, bulk starts that start nothing, event cursors at `Int.max` and the range edges, a credential in a refused address (also with its name percent-encoded once or more, carrying its value, fully encoded, in a redirect or beside a malformed escape, through the HTTP job and events, MCP's tools/call and nxapi_job; encoded past any fixed depth, read to the end or hidden whole when too costly, with ordinary deeply encoded or large text kept exactly), a credential in a change the API saw for itself (a search, a download's message, an install's status) kept out of every event, HTTP and MCP, Keep This Build changed while a deletion holds the game (from the window and the API) or its marker written behind the library's back, coalesced window requests, and parsed booleans.

The Python tests check the adapter against a fake server: endpoint-file checks, no proxy, no redirects, framing, exit codes, and that the token never reaches stdout or stderr.

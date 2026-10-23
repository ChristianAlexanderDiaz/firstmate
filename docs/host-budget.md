# Per-user local workload budget

`bin/fm-resource-run` provides a deterministic owner for the local heavy-job budget shared by Firstmate homes.
It requires Python 3 with its standard library and performs no model calls.
The initial profile admits one heavy job, including on a stronger adapter; raising that limit requires a later coordinated calibration and implementation change.
`bin/fm-resource-run --help` and its subcommand help own configuration, command flags, reservations and the persisted protocol.

## Setup

Start from [the example policy](examples/host-budget.json), replacing every path and the user id with this machine's explicit canonical paths.
Store the private policy at `~/.config/firstmate/host-budget.json` and select that same file in every home with `FM_RESOURCE_CONFIG` or a `config/host-budget.json` symlink.
The socket and ledger must be outside home-specific state directories, with one private directory for each.
On macOS use `/private/tmp` rather than its `/tmp` symlink for a socket under temporary storage.
The durable ledger belongs outside temporary storage so an emergency latch survives reboot.
Never run independent policy owners for separate homes on the same user account.

The dotfiles monitor publishes `~/Library/Application Support/mac-workload/status.json`.
The coordinator reads its schema 1 status and never changes that monitor, OS power settings, sleep behavior or backup exclusions.
Start the owner explicitly with an absolute Python executable under the operator's chosen service manager:

```sh
/absolute/path/to/python3 /absolute/path/to/firstmate/bin/fm_resource.py --config /absolute/path/to/host-budget.json serve
```

No client starts or repairs an owner automatically.
For a LaunchAgent, use that exact argv, `RunAtLoad`, a conservative restart throttle and `Umask` 63; retain transition output with bounded logging.
Keep the executable and configuration paths stable across Firstmate worktree cleanup.
`bin/fm-resource-run status` gives the compact exception view, active reservations, pending queue, monitor timestamp and last cause.
The owner appends each cause change to its private `transitions.jsonl` and also emits it to stdout.
For each supervising home with an existing state directory, run `bin/fm-resource-run register-check --directory /absolute/path/to/home/state` once with the same policy selected.
Existing state-directory permissions are preserved; generated check, trust, cursor and lock files are private.
This creates `host-budget.check.sh` and authenticates it through `bin/fm-check-register.sh`; the ordinary watcher check sweep prints one line per new transition using that home's durable byte cursor.
The transition file is append-only so a home that was offline can read its missed events.
Retire the check with `bin/fm-check-unregister.sh host-budget` in that home before changing its registration.

## Local launch boundaries

```sh
bin/fm-resource-run run --class test -- vitest run
bin/fm-resource-run run --class build -- npm run build
bin/fm-resource-run run --class exclusive -- nix build .
bin/fm-resource-run run --class browser -- ./task-owned-browser-and-server.sh
bin/fm-resource-stage.sh -- ./unknown-local-validation.sh
```

When configured, worker dispatch validates a restore manifest before starting the model CLI, reserves resident CLI memory separately from compute, and supplies task-owned PATH adapters for common package, compiler, graph, browser and Nix entry points.
The wrapper surrounds the existing launch command after account resolution and before backend delivery, so it applies to every harness and runtime backend without driving their lifecycle.
Supervisor sessions do not acquire resident worker leases: primary sessions start outside this wrapper, and persistent second mates keep the compute adapters and selected policy without waiting for resident capacity.
Their local compute commands still require stage reservations.
Interactive launches retain the controlling terminal, transfer foreground ownership to the verified child process group before execution, and restore it after completion; terminal interrupts reach the running CLI normally.
Existing account authentication and pin validation remain in the account adapter.
Worker manifest validation rejects changed directory, branch, task, account configuration or argv rather than choosing another account or directory.
Recovery never automatically relaunches saved commands.
Relaunch preparation creates a new manifest from the supervisor's validated task record.

PATH adapters catch ordinary graphify launches from commit hooks as well as worker commands.
Unclassified package scripts and local stages reserve exclusive capacity.
Direct interpreter invocations, absolute executable paths and tools that replace PATH must use `run` or `fm-resource-stage.sh` explicitly.
These integration boundaries are not an operating-system sandbox; the budget cannot constrain arbitrary unintegrated processes or unrelated desktop applications.
Supported read-only package queries (`npm`/`pnpm` view, info, ls/list, outdated, help and bare version; `yarn` info, list, outdated and help; version/help flags) do not require a compute reservation.

`fm-test-run.sh` and `fm-lint.sh` acquire exclusive stage reservations when configured, including when called by no-mistakes agents outside the original worker environment.
Their inspection modes remain available without compute.
Other projects can use `fm-resource-stage.sh` around existing local stage commands without changing the shared no-mistakes daemon.
Do not wrap an entire no-mistakes controller or its CI wait in a compute lease: only its local commands acquire capacity.
Keep the existing review, test, documentation, lint and CI requirements; no broad local suite is added by this integration.

## Composite work and cleanup

Reserve browser plus server as one outer stage and keep both in that stage's process group.
Give each task a new browser profile and a task-specific server port; only reuse a server after checking its task, process identity and build commit.
A browser stage creates a private profile, named Chrome automation session, server/bridge port candidates and a same-commit resource manifest, exported through `FM_RESOURCE_BROWSER_PROFILE`, `FM_RESOURCE_SERVER_PORT` and `FM_RESOURCE_BROWSER_MANIFEST`.
Nested browser stages initialize these resources if the outer compute reservation has none; otherwise they reuse the inherited profile and composite lifetime.
Project server configuration must consume that port and keep reuse disabled by default; a bind collision must fail rather than attach to a different server.
The Chrome adapter rejects short requests outside that composite lifetime and clears ambient auto-connect and browser URL settings when creating it.
The `npx chrome-devtools-mcp` adapter recovers the caller's existing browser reservation from verified process ancestry, including the detached bridge that `chrome-devtools-axi` starts inside a browser stage, whether or not the MCP transport filters lease environment variables.
It restores the owned browser context and attaches the bridge process group to that reservation without queuing a second job; a launch without a live ancestor browser reservation queues for its own browser reservation.
The wrapper exports `FM_RESOURCE_CPU_WORKERS` and `FM_RESOURCE_BROWSER_WORKERS` for project runners, and applies direct Vitest, Node test, Playwright, graphify and Nix caps where the command interface supports them.
Package-script Vitest runs inherit `VITEST_MAX_WORKERS` and the older thread/fork environment limits, with minimum workers set to one; see [Vitest's environment variable migration](https://vitest.dev/guide/migration.html).
Prepared launches and direct leased package-test runs install a Node PATH adapter that caps `node --test` before file arguments at two workers on desk power or one on portable power, including npm and pnpm package scripts.
Portable power means a non-AC source, or AC while the owner's recent battery history shows the charge falling; AC that holds its charge is desk power whatever the adapter wattage.
Explicit Node concurrency limits at or below the cap are preserved, and other Node invocations pass through unchanged.
For npm, pnpm and yarn `run <script>` or `test`, simple package scripts invoking `playwright test` receive one worker, while simple Node test scripts rely on the prepared Node adapter subject to the PATH limitations below.
Scripts containing `playwright test` or `node --test` tokens anywhere are refused unless they are recognized as a simple runner command; this includes shell compounds with setup or cleanup commands and script-level `--` terminators.
Package directory and single workspace selectors are resolved before inspecting the script; workspace selections that cannot be resolved to one package are refused.
Playwright forwarding is refused if npm receives a runner-level `--` after its forwarding separator, or if pnpm or yarn receives a forwarded `--`.
Worker-cap detection is limited to the supported explicit `run <script>` and `test` forms and recognized option operands.
It does not resolve package selection from npm configuration files or environment variables, npm option abbreviations or combined short flags, or indirect runners such as `bash tests.sh`.
Separate operands for unrecognized options, such as `npm --fetch-retry-mintimeout 10 run test` or `node --dns-result-order ipv4first --test`, are outside this containment; use the full `--option=value` form instead.
Package scripts invoking Node by an absolute path or shadowing `node` with a project-local executable bypass the PATH adapter; invoke that runner directly through `run` for a worker cap.
Yarn Classic 1.22.22 prepends its own temporary Node launcher ahead of the PATH adapter, so package scripts such as `node --test --test-concurrency=99 n*.cjs` remain uncapped with either new or inherited reservations on desk or portable power; invoke Node directly through `run` for a worker cap.
`playwright test # smoke` is an unsupported npm, pnpm and yarn package-script shape: a trailing shell comment can swallow the appended `--workers=1`, leaving the original Playwright concurrency unchanged.
These package scripts still reserve exclusive global capacity.
Project configuration still needs to consume the exported values for custom runners and Next compiler settings.
Neither a generic Node heap limit nor these worker defaults is a process-tree memory ceiling.
The reservations are planning budgets, with live memory pressure providing the admission veto.
An oversized project must request a larger `--memory-mib` reservation.

Nested stages inherit and, if necessary, atomically upgrade the outer reservation.
An upgrade that cannot fit refuses instead of holding one slot while waiting for another.
Do not launch independent parallel stages behind a single composite token.
Keep the parent stage alive until all owned resources finish; detached sessions other than verified browser bridge groups need their own explicit leased lifetime.
In particular, a browser automation CLI's short connection request is not proof that its persistent browser or bridge stopped.
Launch the browser/server under the composite stage and connect the client to that owned instance; never attach the budget to an unrelated existing browser.

The ledger binds boot identity, kernel process start time, nonce and process group.
Heartbeat expiry alone cannot release capacity while an owned group survives.
An unanchored surviving group is quarantined, retaining capacity without signaling an unverified process.
Cancellation sends TERM to verified members, then KILL after the configured grace, and never kills by executable name or port.
Stopping the owner preserves live reservations for reconciliation by its replacement.
Once a lease's verified process group has drained, the owner checks the browser manifest's lease, boot and profile identity and removes the token directory, including its profile and caches.
The same reconciliation handles completion, cancellation, inherited browser stages, attached bridge groups and owner recovery.
Unknown or corrupt recovery state fails closed; preserve it for inspection rather than deleting it to regain slots.

## Exceptions and rollout

Missing, stale, unavailable, wrong-boot or malformed monitor samples hold new compute and resident workers.
Resident workers may start under warning memory pressure, subject to the resident count, actual memory reservations and other telemetry checks; critical or unknown pressure holds new workers.
Heavy and exclusive jobs remain held under warning pressure.
The queue admits requests that fit the available capacity without reserving memory for waiting requests, so a queued exclusive job cannot block workers or smaller compute jobs behind it.
Reconciliation drops queued requests whose controller identity is dead or whose controller was reparented to process 1 after it started waiting; such a controller cannot queue again.
A controller whose parent was already process 1 when it first asked, such as one started by launchd, is admitted normally.
A request from a client or ledger that predates parent tracking records the controller's observed parent when the owner first sees it, so only a later transition to process 1 drops it.
The owner uses the monitor's observation time and uptime, restarts recovery after source or monitor-instance changes, observed suspension or gaps longer than ten seconds, and persists its last blocking cause.
An explicit `emergency --evidence` records an observed emergency sleep; a critical thermal reading also latches conservatively without asserting that sleep occurred.
Dotfiles schema 1 does not report historical emergency sleeps, so an emergency that happened while both monitor and coordinator were absent must be recorded from inspected OS evidence before restoring work.
Clear the latch only with `clear-emergency --evidence` after inspecting that evidence.
Heavy compute must still satisfy continuous nominal recovery hysteresis after a clear, warning, wake or owner restart.

The bounded private metrics ring records telemetry and numeric resource usage by lease, without prompts, cookies or environment contents.
Transition history, current cause and quarantine status provide the Firstmate exception summary; there is no permanent AI health watcher.
A request waiting more than ten minutes, or waiting on capacity held by its own process or an ancestor compute stage rather than its resident worker lease, emits one stuck-request notification through the registered transition check.
The notification names the request, task, workload class, wait duration and blocking lease holders with their process and task identities, or the admission policy when no lease holds the requested capacity.
Its notification marker survives owner recovery, preventing repeated notifications for the same queued request.
Indexing and backup policies stay with the opted-in dotfiles helper; this implementation never excludes worktrees or deletes unique work.

Use `bin/fm-test-run.sh tests/fm-resource.test.sh` to exercise socket admission, process ownership and fixture policy failures without generating thermal load.
Actual Herdr restore testing requires a separate guarded Herdr lab.
Full Playwright, real Nix and local no-mistakes calibration, idle service overhead measurement, sleep/wake/unplug trials and any higher concurrency need a coordinated quiet window.
Do not treat short fixture runs as thermal or capacity certification.

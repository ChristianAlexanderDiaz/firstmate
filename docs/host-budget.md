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
The owner also writes one JSON transition event to stdout when the cause changes; an existing process-event source can consume those events without polling a model.

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
Existing account authentication and pin validation remain in the account adapter.
Manifest validation rejects changed directory, branch, task, account configuration or argv rather than choosing another account or directory.
Recovery never automatically relaunches saved commands.
Relaunch preparation creates a new manifest from the supervisor's validated task record.

PATH adapters catch ordinary graphify launches from commit hooks as well as worker commands.
Unclassified package scripts and local stages reserve exclusive capacity.
Direct interpreter invocations, absolute executable paths and tools that replace PATH must use `run` or `fm-resource-stage.sh` explicitly.
These integration boundaries are not an operating-system sandbox; the budget cannot constrain arbitrary unintegrated processes or unrelated desktop applications.
Read-only queries do not require a compute reservation.

`fm-test-run.sh` and `fm-lint.sh` acquire exclusive stage reservations when configured, including when called by no-mistakes agents outside the original worker environment.
Their inspection modes remain available without compute.
Other projects can use `fm-resource-stage.sh` around existing local stage commands without changing the shared no-mistakes daemon.
Do not wrap an entire no-mistakes controller or its CI wait in a compute lease: only its local commands acquire capacity.
Keep the existing review, test, documentation, lint and CI requirements; no broad local suite is added by this integration.

## Composite work and cleanup

Reserve browser plus server as one outer stage and keep both in that stage's process group.
Give each task a new browser profile and a task-specific server port; only reuse a server after checking its task, process identity and build commit.
An outer browser stage creates a private profile, named Chrome automation session, server/bridge port candidates and a same-commit resource manifest, exported through `FM_RESOURCE_BROWSER_PROFILE`, `FM_RESOURCE_SERVER_PORT` and `FM_RESOURCE_BROWSER_MANIFEST`.
Project server configuration must consume that port and keep reuse disabled by default; a bind collision must fail rather than attach to a different server.
The Chrome adapter rejects short requests outside that composite lifetime and clears ambient auto-connect and browser URL settings when creating it.
The wrapper exports `FM_RESOURCE_CPU_WORKERS` and `FM_RESOURCE_BROWSER_WORKERS` for project runners, and applies direct Vitest, Node test, Playwright, graphify and Nix caps where the command interface supports them.
Project configuration still needs to consume the exported values for custom runners and Next compiler settings.
Neither a generic Node heap limit nor these worker defaults is a process-tree memory ceiling.
The reservations are planning budgets, with live memory pressure providing the admission veto.
An oversized project must request a larger `--memory-mib` reservation.

Nested stages inherit and, if necessary, atomically upgrade the outer reservation.
An upgrade that cannot fit refuses instead of holding one slot while waiting for another.
Do not launch independent parallel stages behind a single composite token.
Keep the parent stage alive until all owned resources finish; detached sessions that escape its process group need their own explicit leased lifetime.
In particular, a browser automation CLI's short connection request is not proof that its persistent browser or bridge stopped.
Launch the browser/server under the composite stage and connect the client to that owned instance; never attach the budget to an unrelated existing browser.

The ledger binds boot identity, kernel process start time, nonce and process group.
Heartbeat expiry alone cannot release capacity while an owned group survives.
An unanchored surviving group is quarantined, retaining capacity without signaling an unverified process.
Cancellation sends TERM to verified members, then KILL after the configured grace, and never kills by executable name or port.
Stopping the owner preserves live reservations for reconciliation by its replacement.
Unknown or corrupt recovery state fails closed; preserve it for inspection rather than deleting it to regain slots.

## Exceptions and rollout

Missing, stale, unavailable, wrong-boot or malformed monitor samples hold new compute.
The owner uses the monitor's observation time and uptime, restarts recovery after source or monitor-instance changes, and persists its last blocking cause.
An explicit `emergency --evidence` records an observed emergency sleep; a critical thermal reading also latches conservatively without asserting that sleep occurred.
Dotfiles schema 1 does not report historical emergency sleeps, so an emergency that happened while both monitor and coordinator were absent must be recorded from inspected OS evidence before restoring work.
Clear the latch only with `clear-emergency --evidence` after inspecting that evidence.
Fresh healthy telemetry must still satisfy recovery hysteresis after a clear or owner restart.

The bounded private metrics ring records telemetry and numeric resource usage by lease, without prompts, cookies or environment contents.
Transition history, current cause and quarantine status provide the Firstmate exception summary; there is no permanent AI health watcher.
Indexing and backup policies stay with the opted-in dotfiles helper; this implementation never excludes worktrees or deletes unique work.

Use `bin/fm-test-run.sh tests/fm-resource.test.sh` to exercise socket admission, process ownership and fixture policy failures without generating thermal load.
Actual Herdr restore testing requires a separate guarded Herdr lab.
Full Playwright, real Nix and local no-mistakes calibration, idle service overhead measurement, sleep/wake/unplug trials and any higher concurrency need a coordinated quiet window.
Do not treat short fixture runs as thermal or capacity certification.

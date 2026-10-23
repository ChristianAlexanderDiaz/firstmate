#!/usr/bin/env python3
"""Behavior through the executable, socket protocol and durable recovery ledger."""
import copy
import importlib.util
import json
import os
import pty
import select
import shlex
import shutil
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
CLI = str(ROOT / "bin/fm-resource-run")
spec = importlib.util.spec_from_file_location("resource", ROOT / "bin/fm_resource.py")
resource = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resource)
SAMPLE = {"schemaVersion": 1, "instanceUUID": "fixture-instance", "lifecycle": "running",
    "unavailable": [], "thermalState": "nominal", "lowPowerModeEnabled": False,
    "lidClosed": False, "memory": {"pressure": "normal", "swapUsedBytes": 0},
    "power": {"source": "ac", "adapterWatts": 65, "batteryPercent": 80, "isCharging": True},
    "policy": {"schemaVersion": 1, "maxHeavyJobs": 1, "batteryAdmissionPercent": 30,
               "batteryCancellationPercent": 15, "staleAfterSeconds": 10}}


def wait_for(predicate, seconds=12):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError("bounded condition wait expired")


class ResourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fm-res-", dir="/tmp")
        self.root = Path(self.temp.name).resolve()
        self.config = {"schemaVersion": 1, "stateDirectory": str(self.root / "state"),
            "socketPath": str(self.root / "socket" / "owner"), "monitorPath": str(self.root / "monitor.json"),
            "graceSeconds": 1}
        self.write("config.json", self.config)
        self.write("input.json", SAMPLE)
        (self.root / "clock").write_text("0")
        self.log = open(self.root / "owner.log", "w+")
        self.children = []
        self.start()
        wait_for(lambda: self.status()["reason"].startswith("recovery hysteresis"))
        (self.root / "clock").write_text("121")
        wait_for(lambda: self.status()["reason"] == "ready")

    def write(self, name, value):
        path = self.root / name
        tmp = path.with_suffix(".write")
        tmp.write_text(json.dumps(value))
        os.replace(tmp, path)

    def start(self):
        self.server = subprocess.Popen([sys.executable, str(ROOT / "tests/fixtures/resource-owner.py"),
            str(ROOT / "bin/fm_resource.py"), str(self.root)], stdout=self.log, stderr=self.log)
        wait_for(lambda: Path(self.config["socketPath"]).exists() or self.server.poll() is not None)
        if self.server.poll() is not None:
            self.log.seek(0)
            self.fail(self.log.read())

    def stop(self, sig=signal.SIGTERM):
        if self.server.poll() is None:
            self.server.send_signal(sig)
            self.server.wait(timeout=5)

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.terminate()
        for child in self.children:
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
            for stream in (child.stdout, child.stderr):
                if stream is not None:
                    stream.close()
        self.stop()
        self.log.close()
        self.temp.cleanup()

    def call(self, *argv, **kwargs):
        return subprocess.run([CLI, "--config", str(self.root / "config.json"), *argv],
            text=True, capture_output=True, timeout=15, **kwargs)

    def status(self):
        try:
            return resource.rpc(self.config, resource.load_config(str(self.root / "config.json"))[2], op="status")
        except (OSError, ValueError):
            return {"reason": "not ready"}

    def job(self, code, kind="test", wait=0, env=None):
        child = subprocess.Popen([CLI, "--config", str(self.root / "config.json"), "run",
            "--class", kind, "--wait-seconds", str(wait), "--", "/bin/sh", "-c", code],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        self.children.append(child)
        return child

    def request(self, op, **values):
        return resource.rpc(self.config, resource.load_config(str(self.root / "config.json"))[2],
            op=op, **values)

    def acquire(self, kind, memory=None, controller=None, task="fixture"):
        token = uuid.uuid4().hex
        result = self.request("acquire", token=token, controller=controller or resource.identity(os.getpid()),
            **{"class": kind, "memoryMiB": memory or resource.CLASSES[kind], "task": task})
        return token, result["state"]

    def poll_transitions(self):
        result = self.call("transitions", "--cursor", str(self.root / "cursor"))
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def test_warning_admits_residents_but_not_compute_and_unknown_holds_residents(self):
        sample = copy.deepcopy(SAMPLE)
        sample["memory"]["pressure"] = "warning"
        self.write("input.json", sample)
        wait_for(lambda: "warning" in self.status()["reason"])
        token, state = self.acquire("worker")
        self.assertEqual(state, "leased")
        self.request("release", token=token)
        for kind in ("test", "build", "browser", "graph", "exclusive"):
            token, state = self.acquire(kind)
            self.assertEqual(state, "queued", kind)
            self.request("cancel-queued", token=token)
        for changed in ({"memory": {"pressure": "critical", "swapUsedBytes": 0}},
                {"memory": {"pressure": "unknown", "swapUsedBytes": 0}},
                {"_missing": True}, {"unavailable": ["power.source"]}, {"lidClosed": True}):
            with self.subTest(changed=changed):
                self.write("input.json", dict(copy.deepcopy(sample), **changed))
                wait_for(lambda: self.status()["reason"] != resource.MEMORY_WARNING)
                result = self.call("run", "--class", "worker", "--wait-seconds", "0.1", "--", "true")
                self.assertEqual(result.returncode, 75, result.stderr)

    def test_unfittable_exclusive_does_not_block_workers_or_other_classes(self):
        self.assertEqual(self.acquire("worker", memory=6656)[1], "leased")
        exclusive, state = self.acquire("exclusive")
        self.assertEqual(state, "queued")
        self.assertEqual(self.acquire("worker")[1], "leased")
        self.assertEqual(self.acquire("graph")[1], "leased")
        self.assertEqual([q["token"] for q in self.status()["queue"]], [exclusive])

    def test_dead_controller_request_is_dropped_on_reconcile(self):
        self.assertEqual(self.acquire("exclusive")[1], "leased")
        controller = subprocess.Popen(["/bin/sleep", "30"])
        self.children.append(controller)
        token, state = self.acquire("exclusive", controller=resource.identity(controller.pid))
        self.assertEqual(state, "queued")
        controller.terminate()
        controller.wait(timeout=5)
        self.assertNotIn(token, [q["token"] for q in self.status()["queue"]])

    def test_orphaned_controller_request_is_dropped_on_reconcile(self):
        self.assertEqual(self.acquire("exclusive")[1], "leased")
        controller = subprocess.Popen(["/bin/sleep", "30"])
        self.children.append(controller)
        owner = resource.identity(controller.pid)
        token, state = self.acquire("exclusive", controller=owner)
        self.assertEqual(state, "queued")
        # Some test hosts adopt orphans through a subreaper, so supply only the
        # parent-1 observation while retaining the real live kernel identity.
        (self.root / "orphan-controller").write_text(str(controller.pid))
        self.assertNotIn(token, [q["token"] for q in self.status()["queue"]])
        self.assertIsNone(controller.poll())
        with self.assertRaisesRegex(resource.Refusal, "orphaned controller"):
            self.acquire("exclusive", controller=owner)
        self.assertFalse(self.status()["queue"])

    def test_long_queued_request_emits_one_wake_naming_the_holder(self):
        self.job("sleep 30", kind="exclusive")
        lease = wait_for(lambda: next((l for l in self.status().get("leases", {}).values() if l.get("group")), None))
        token, state = self.acquire("test", task="waiting-task")
        self.assertEqual(state, "queued")
        self.assertFalse(any("host-budget-stuck" in line for line in self.poll_transitions()))
        (self.root / "clock").write_text("722")
        lines = wait_for(lambda: [line for line in self.poll_transitions() if "host-budget-stuck" in line])
        self.assertEqual(len(lines), 1)
        for expected in (token, "waiting-task", "class=test", f"pid={lease['group']['pid']}", f"task={lease['task']}"):
            self.assertIn(expected, lines[0])
        self.assertGreater(int(lines[0].split("waited=")[1].split("s:")[0]), 600)
        self.assertIn("stuckNotified", next(q for q in self.status()["queue"] if q["token"] == token))
        self.stop()
        self.start()
        # The request marker survives recovery and repeated admission attempts.
        self.acquire("worker")
        self.assertFalse(any("host-budget-stuck" in line for line in self.poll_transitions()))

    def test_self_held_request_emits_one_wake_without_waiting_ten_minutes(self):
        holder, state = self.acquire("exclusive", task="holding-task")
        self.assertEqual(state, "leased")
        token, state = self.acquire("test", task="nested-task")
        self.assertEqual(state, "queued")
        lines = [line for line in self.poll_transitions() if "host-budget-stuck" in line]
        self.assertEqual(len(lines), 1)
        for expected in (token, "class=test", "waited=0s", "self-held lease", f"pid={os.getpid()}", "task=holding-task"):
            self.assertIn(expected, lines[0])
        self.request("acquire", **self.status()["queue"][0])
        self.stop()
        self.start()
        self.request("acquire", **self.status()["queue"][0])
        self.assertFalse(any("host-budget-stuck" in line for line in self.poll_transitions()))
        self.request("release", token=holder)

    def test_atomic_races_are_serial_across_homes(self):
        lock = self.root / "exclusive"
        code = f"mkdir {lock} || exit 99; sleep 0.15; rmdir {lock}"
        jobs = [self.job(code, env=dict(os.environ, FM_HOME=str(self.root / f"home-{n}"))) for n in range(6)]
        for job in jobs:
            out, err = job.communicate(timeout=15)
            self.assertEqual(job.returncode, 0, out + err)
        self.assertFalse(self.status()["leases"])

    def test_nested_inheritance_and_atomic_upgrade(self):
        code = f"{CLI} --config {self.root / 'config.json'} run --class build -- /bin/sh -c 'echo nested'"
        job = self.job(code)
        out, err = job.communicate(timeout=15)
        self.assertEqual(job.returncode, 0, err)
        self.assertIn("nested", out)

    def test_stale_missing_invalid_and_old_boot_hold_work(self):
        for field in ({"timestamp": time.time() - 100}, {"uptimeSeconds": 0},
                      {"bootSessionUUID": "old-boot"}, {"schemaVersion": 8},
                      {"_missing": True}, {"_malformed": True}, {"lidClosed": True},
                      {"unavailable": ["power.source"]}, {"lifecycle": "sleeping"}):
            with self.subTest(field=field):
                sample = dict(copy.deepcopy(SAMPLE), **field)
                self.write("input.json", sample)
                time.sleep(0.12)
                result = self.call("run", "--class", "test", "--wait-seconds", "0.1", "--", "/bin/echo", "UNSAFE")
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertNotIn("UNSAFE", result.stdout)

    def test_queue_cancellation_and_weight_limits(self):
        first = self.job("sleep 1")
        wait_for(lambda: self.status().get("leases"))
        second = self.job("echo UNSAFE", wait=0.2)
        out, err = second.communicate(timeout=5)
        self.assertEqual(second.returncode, 75, err)
        self.assertNotIn("UNSAFE", out)
        first.communicate(timeout=10)
        self.assertFalse(self.status()["queue"])
        result = self.call("run", "--memory-mib", "9999999", "--", "true")
        self.assertEqual(result.returncode, 75)

    def test_parent_exit_does_not_release_surviving_group(self):
        job = self.job("sleep 3 & exit 0")
        wait_for(lambda: self.status().get("leases"))
        time.sleep(0.3)
        self.assertTrue(self.status()["leases"])
        result = self.call("run", "--wait-seconds", "0.2", "--", "true")
        self.assertEqual(result.returncode, 75)
        job.communicate(timeout=10)
        self.assertFalse(self.status()["leases"])

    def test_duplicate_owner_and_stale_socket_recovery(self):
        result = self.call("serve")
        self.assertEqual(result.returncode, 75)
        self.assertIn("already holds", result.stderr)
        self.stop(signal.SIGKILL)
        self.assertTrue(Path(self.config["socketPath"]).exists())
        self.start()
        wait_for(lambda: "recovery hysteresis" in self.status()["reason"])

    def test_crash_preserves_live_reservation_and_partial_writes(self):
        job = self.job("sleep 5")
        wait_for(lambda: any(l.get("group") for l in self.status().get("leases", {}).values()))
        self.stop(signal.SIGKILL)
        (self.root / "state/.resource-interrupted").write_text('{"partial":')
        self.start()
        wait_for(lambda: self.status().get("leases"))
        self.assertEqual(len(self.status()["leases"]), 1)
        # The original wrapper exits on socket loss; the verified group still
        # holds its reservation through owner recovery until the child exits.
        wait_for(lambda: not self.status().get("leases"), seconds=10)
        job.communicate(timeout=10)

    def test_reused_pid_is_not_signalled_or_adopted(self):
        victim = subprocess.Popen(["/bin/sleep", "30"], start_new_session=True)
        self.children.append(victim)
        self.stop()
        ledger = json.loads((self.root / "state/ledger.json").read_text())
        wrong = dict(resource.identity(victim.pid), start="reused-pid-old-start")
        token = uuid.uuid4().hex
        ledger["leases"][token] = {"token": token, "class": "test", "memoryMiB": 1024,
            "controller": resource.identity(os.getpid()), "group": wrong, "members": [wrong], "cancelAt": 0}
        self.write("state/ledger.json", ledger)
        self.start()
        lease = wait_for(lambda: self.status().get("leases", {}).get(token))
        self.assertTrue(lease["quarantined"])
        time.sleep(0.3)
        self.assertIsNone(victim.poll())

    def test_emergency_latch_survives_restart_and_explicit_clear(self):
        result = self.call("emergency", "--evidence", "fixture thermal emergency sleep")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.stop()
        self.start()
        wait_for(lambda: self.status().get("emergency"))
        result = self.call("clear-emergency", "--evidence", "short")
        self.assertEqual(result.returncode, 75)
        result = self.call("clear-emergency", "--evidence", "inspected fixture recovery evidence")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.status()["emergency"])

    def test_critical_cancels_only_owned_compute(self):
        victim = subprocess.Popen(["/bin/sleep", "30"], start_new_session=True)
        self.children.append(victim)
        job = self.job("trap '' TERM; sleep 30")
        wait_for(lambda: any(l.get("group") for l in self.status().get("leases", {}).values()))
        sample = copy.deepcopy(SAMPLE)
        sample["thermalState"] = "critical"
        self.write("input.json", sample)
        wait_for(lambda: self.status().get("emergency"))
        (self.root / "clock").write_text("124")
        wait_for(lambda: not self.status().get("leases"))
        job.communicate(timeout=10)
        self.assertNotEqual(job.returncode, 0)
        self.assertIsNone(victim.poll())

    def test_stdin_and_environment_caps_are_preserved(self):
        result = self.call("run", "--class", "test", "--", "/bin/sh", "-c", 'read x; printf "%s/%s/%s" "$x" "$GRAPHIFY_MAX_WORKERS" "$FM_RESOURCE_BROWSER_WORKERS"', input="hello\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "hello/1/1")

    def test_manifest_refuses_directory_account_task_and_argv_drift(self):
        directory = self.root / "launch"
        result = self.call("prepare", "--directory", str(directory), "--worktree", str(ROOT),
            "--task", "fixture", "--account-label", "fixture-default", "--", "/bin/echo", "manifest")
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = directory / "manifest.json"
        result = self.call("run", "--class", "worker", "--manifest", str(manifest), "--", "/bin/echo", "wrong")
        self.assertEqual(result.returncode, 75)
        value = json.loads(manifest.read_text())
        value["accountEnvironment"]["CLAUDE_CONFIG_DIR"] = str(self.root / "missing-account")
        manifest.write_text(json.dumps(value))
        result = self.call("run", "--class", "worker", "--manifest", str(manifest), "--", "/bin/echo", "manifest")
        self.assertEqual(result.returncode, 75)
        self.assertNotIn("manifest\n", result.stdout)

    def test_prepared_hook_adapter_and_stage_wrapper_use_the_owner(self):
        fake = self.root / "fakebin"
        fake.mkdir()
        graph = fake / "graphify"
        graph.write_text('#!/bin/sh\nprintf "graph-workers=%s" "$GRAPHIFY_MAX_WORKERS"\n')
        graph.chmod(0o700)
        env = dict(os.environ, PATH=str(fake) + os.pathsep + os.environ["PATH"])
        directory = self.root / "adapters"
        result = self.call("prepare", "--directory", str(directory), "--worktree", str(ROOT),
            "--task", "fixture", "--account-label", "fixture-default", "--", "true", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run([str(directory / "bin/graphify"), "update"], text=True, capture_output=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "graph-workers=1")
        env["FM_RESOURCE_CONFIG"] = str(self.root / "config.json")
        result = subprocess.run([str(ROOT / "bin/fm-resource-stage.sh"), "--", "/bin/sh", "-c", 'echo "$FM_RESOURCE_CPU_WORKERS"'], env=env, text=True, capture_output=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "1\n")

    def test_monitor_restart_and_source_change_restart_hysteresis(self):
        sample = copy.deepcopy(SAMPLE)
        sample["instanceUUID"] = "restarted-monitor"
        self.write("input.json", sample)
        wait_for(lambda: self.status()["reason"].startswith("recovery hysteresis"))
        result = self.call("run", "--wait-seconds", "0.1", "--", "true")
        self.assertEqual(result.returncode, 75)
        (self.root / "clock").write_text("242")
        wait_for(lambda: self.status()["reason"] == "ready")
        sample["power"]["source"], sample["power"]["adapterWatts"] = "battery", None
        self.write("input.json", sample)
        wait_for(lambda: self.status()["reason"].startswith("recovery hysteresis"))

    def test_battery_warning_memory_and_numeric_zero(self):
        sample = copy.deepcopy(SAMPLE)
        sample["thermalWarning"] = 0
        sample["performanceWarning"] = 0
        self.write("input.json", sample)
        self.assertEqual(self.call("run", "--class", "test", "--", "true").returncode, 0)
        sample["power"].update(source="battery", adapterWatts=None, batteryPercent=29)
        self.write("input.json", sample)
        wait_for(lambda: "30%" in self.status()["reason"])
        sample["memory"]["pressure"] = "warning"
        self.write("input.json", sample)
        wait_for(lambda: "warning" in self.status()["reason"])
        result = self.call("run", "--wait-seconds", "0.1", "--", "true")
        self.assertEqual(result.returncode, 75)

    def test_recovery_rejects_corrupt_complete_ledger(self):
        self.stop()
        ledger = self.root / "state/ledger.json"
        ledger.write_text('{"incomplete":')
        result = self.call("serve")
        self.assertEqual(result.returncode, 75)
        self.assertEqual(ledger.read_text(), '{"incomplete":')

    def test_external_group_cannot_be_bound_to_a_lease(self):
        victim = subprocess.Popen(["/bin/sleep", "30"], start_new_session=True)
        self.children.append(victim)
        digest = resource.load_config(str(self.root / "config.json"))[2]
        token = uuid.uuid4().hex
        result = resource.rpc(self.config, digest, op="acquire", token=token,
            controller=resource.identity(os.getpid()), **{"class": "test", "memoryMiB": 1024})
        self.assertEqual(result["state"], "leased")
        # A direct child is valid. A forged start identity is never valid, even
        # when its PID still belongs to this user's live process.
        with self.assertRaises(resource.Refusal):
            resource.rpc(self.config, digest, op="bind", token=token,
                group=dict(resource.identity(victim.pid), start="old-start"))
        resource.rpc(self.config, digest, op="release", token=token)
        self.assertIsNone(victim.poll())

    def test_configured_dispatch_executes_its_validated_launch(self):
        script = self.root / "dispatch.sh"
        script.write_text('''#!/usr/bin/env bash
set -eu
. "$1/tests/fixtures.sh"
case_root=$2/dispatch
task_home=$case_root/home
project=$case_root/project
worktree=$case_root/wt
fakebin=$(fm_test_make_spawn_fakebin "$case_root/fake")
fm_test_spawn_home "$task_home" codex
fm_git_worktree "$project" "$worktree" wt-resource
fm_test_spawn_brief "$task_home" budget-fixture
printf '#!/bin/sh\\ntest -d "$CODEX_HOME" || exit 19\\nprintf "resource-probe=%%s\\n" "$FM_TASK_ID"\\nexec "%s/bin/fm-resource-run" status\\n' "$ROOT" > "$fakebin/codex"
chmod +x "$fakebin/codex"
export FM_FAKE_LAUNCH_LOG=$case_root/launch.log
export CLAUDE_CONFIG_DIR=$case_root/unrelated
mkdir -p "$case_root/codex-config"
export CODEX_HOME=$case_root/codex-config
FM_RESOURCE_CONFIG=$2/config.json fm_test_run_spawn "$task_home" "$worktree" "$fakebin" budget-fixture "$project" --mode no-mistakes --yolo off > "$case_root/spawn.out"
cd "$worktree"
export FM_TASK_ID=budget-fixture
unset CODEX_HOME CLAUDE_CONFIG_DIR
PATH="$fakebin:$PATH" /bin/bash -c "$(cat "$case_root/launch.log")"
''')
        result = subprocess.run(["/bin/bash", str(script), str(ROOT), str(self.root)],
            text=True, capture_output=True, timeout=40)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("resource-probe=budget-fixture", result.stdout)
        status = json.loads(result.stdout.split("\n", 1)[1])
        self.assertTrue(any(lease["class"] == "worker" and lease.get("group") for lease in status["leases"].values()))

    def test_supervisor_dispatch_bypasses_full_budget_and_critical_pressure(self):
        self.assertEqual(self.acquire("worker", memory=10240)[1], "leased")
        sample = copy.deepcopy(SAMPLE)
        sample["memory"]["pressure"] = "critical"
        self.write("input.json", sample)
        wait_for(lambda: "critical" in self.status()["reason"])
        script = self.root / "supervisor.sh"
        script.write_text('''#!/usr/bin/env bash
set -eu
. "$1/tests/fixtures.sh"
case_root=$2/supervisor
task_home=$case_root/home
sm=$case_root/secondmate
fakebin=$(fm_test_make_spawn_fakebin "$case_root/fake" make)
fm_test_spawn_home "$task_home" codex
fm_test_spawn_home "$sm" codex
mkdir -p "$sm/bin"
printf '# Firstmate\\n' > "$sm/AGENTS.md"
printf 'budget-supervisor\\n' > "$sm/.fm-secondmate-home"
printf 'Supervise local tasks.\\n' > "$sm/data/charter.md"
printf '%s\\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
git -C "$sm" init -q -b main
git -C "$sm" add AGENTS.md .gitignore
git -C "$sm" -c user.name=Tests -c user.email=tests@example.invalid commit -qm initial
fm_test_spawn_brief "$task_home" budget-supervisor
printf '#!/bin/sh\\ntest -n "$FM_RESOURCE_CONFIG" || exit 19\\ncase "$(command -v make)" in */resource-*/bin/make) ;; *) exit 20 ;; esac\\nprintf "supervisor-probe\\\\n"\\nexec "%s/bin/fm-resource-run" status\\n' "$ROOT" > "$fakebin/codex"
chmod +x "$fakebin/codex"
export FM_FAKE_LAUNCH_LOG=$case_root/launch.log
FM_RESOURCE_CONFIG=$2/config.json fm_test_run_spawn "$task_home" "$sm" "$fakebin" budget-supervisor "$sm" --secondmate > "$case_root/spawn.out"
cd "$sm"
PATH="$fakebin:$PATH" /bin/bash -c "$(cat "$case_root/launch.log")"
''')
        result = subprocess.run(["/bin/bash", str(script), str(ROOT), str(self.root)],
            text=True, capture_output=True, timeout=40)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("supervisor-probe", result.stdout)
        status = json.loads(result.stdout.split("\n", 1)[1])
        self.assertEqual(len(status["leases"]), 1)
        self.assertFalse(status["queue"])

    def test_browser_stage_isolates_profile_session_and_server(self):
        env = dict(os.environ, CHROME_DEVTOOLS_AXI_AUTO_CONNECT="1",
            CHROME_DEVTOOLS_AXI_BROWSER_URL="http://unrelated.invalid", CHROME_DEVTOOLS_AXI_SESSION="default")
        code = 'cat "$FM_RESOURCE_BROWSER_MANIFEST"; test -d "$FM_RESOURCE_BROWSER_PROFILE"; test "$CHROME_DEVTOOLS_AXI_AUTO_CONNECT" = 0; test -z "${CHROME_DEVTOOLS_AXI_BROWSER_URL:-}"'
        result = self.call("run", "--class", "browser", "--", "/bin/sh", "-c", code, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(result.stdout)
        self.assertTrue(manifest["session"].startswith("fm-resource-"))
        self.assertFalse(manifest["reuseServer"])
        self.assertGreater(manifest["serverPort"], 0)
        self.assertFalse(Path(manifest["profile"]).parent.exists())
        result = self.call("run", "--class", "browser", "--", "chrome-devtools-axi", "start")
        self.assertEqual(result.returncode, 75)

    def test_browser_client_requires_and_inherits_composite_lifetime(self):
        fake = self.root / "browser-bin"
        fake.mkdir()
        client = fake / "chrome-devtools-axi"
        client.write_text("#!" + sys.executable + "\n" + '''import json, os, subprocess
from pathlib import Path
manifest = json.loads(Path(os.environ["FM_RESOURCE_BROWSER_MANIFEST"]).read_text())
status = json.loads(subprocess.check_output([os.environ["CLIENT_RESOURCE_CLI"],
    "--config", os.environ["FM_RESOURCE_CONFIG"], "status"], text=True))
print(json.dumps({"lease": os.environ["FM_RESOURCE_LEASE"],
    "profile": os.environ["FM_RESOURCE_BROWSER_PROFILE"], "manifest": manifest,
    "leases": list(status["leases"])}))
''')
        client.chmod(0o700)
        env = dict(os.environ, PATH=str(fake) + os.pathsep + os.environ["PATH"], CLIENT_RESOURCE_CLI=CLI)
        directory = self.root / "browser-adapters"
        result = self.call("prepare", "--directory", str(directory), "--worktree", str(ROOT),
            "--task", "browser-client", "--account-label", "fixture-default", "--", "true", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        adapter = str(directory / "bin/chrome-devtools-axi")
        direct = [CLI, "--config", str(self.root / "config.json"), "run", "--class", "browser", "--", str(client)]
        driver = self.root / "browser-client-driver.py"
        driver.write_text('''import json, subprocess, sys
for command in json.loads(sys.argv[1]):
    result = subprocess.run(command, text=True, capture_output=True, timeout=10)
    if result.returncode:
        sys.stderr.write(result.stderr)
        sys.exit(result.returncode)
    print(result.stdout, end="")
''')
        result = self.call("run", "--class", "browser", "--", sys.executable, str(driver),
            json.dumps([[adapter, "rpc"], [*direct, "rpc"]]), env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(records), 2)
        self.assertEqual(records[0], records[1])
        for record in records:
            self.assertEqual(record["leases"], [record["lease"]])
            self.assertEqual(record["manifest"]["lease"], record["lease"])
            self.assertEqual(record["manifest"]["profile"], record["profile"])
        for command in ([adapter, "rpc"], [*direct, "rpc"]):
            for inherited in (False, True):
                with self.subTest(command=command, forged=inherited):
                    outside = env.copy()
                    outside.pop("FM_RESOURCE_LEASE", None)
                    outside.pop("FM_RESOURCE_BROWSER_PROFILE", None)
                    if inherited:
                        outside.update(FM_RESOURCE_LEASE=uuid.uuid4().hex,
                            FM_RESOURCE_BROWSER_PROFILE=records[0]["profile"])
                    result = subprocess.run(command, text=True, capture_output=True, timeout=10, env=outside)
                    self.assertEqual(result.returncode, 75, result.stderr)
                    self.assertEqual(result.stdout, "")
            result = self.call("run", "--class", "exclusive", "--", *command, env=env)
            self.assertEqual(result.returncode, 75, result.stderr)
            self.assertEqual(result.stdout, "")

    def test_browser_bridge_inherits_after_environment_filtering_and_timeout_leaves_no_queue(self):
        fake = self.root / "mcp-bin"
        fake.mkdir()
        npx = fake / "npx"
        npx.write_text("#!" + sys.executable + '''
import json, os, subprocess, sys, time
state = json.loads(subprocess.check_output([os.environ["CLIENT_RESOURCE_CLI"],
    "--config", os.environ["FM_RESOURCE_CONFIG"], "status"], text=True))
print(json.dumps({"token": os.environ["FM_RESOURCE_LEASE"], "queue": state["queue"],
    "leases": list(state["leases"]), "groups": list(state["leases"].values())[0]["browserGroups"]}), flush=True)
if "--fixture-timeout" in sys.argv:
    time.sleep(30)
''')
        npx.chmod(0o700)
        env = dict(os.environ, PATH=str(fake) + os.pathsep + os.environ["PATH"])
        directory = self.root / "mcp-adapters"
        result = self.call("prepare", "--directory", str(directory), "--worktree", str(ROOT),
            "--task", "browser-bridge", "--account-label", "default", "--", "true", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        adapter = str(directory / "bin/npx")
        driver = self.root / "bridge-driver.py"
        # The real MCP transport filters out FM_RESOURCE_* but preserves PATH;
        # the bridge itself is detached from the caller's process group.
        driver.write_text('''import json, os, signal, subprocess, sys
bridge = "import os,subprocess,sys; env={k:v for k,v in os.environ.items() if k in ('HOME','PATH')}; env['CLIENT_RESOURCE_CLI']=sys.argv[1]; sys.exit(subprocess.call(['npx','-y','chrome-devtools-mcp@latest',*sys.argv[2:]],env=env))"
for timeout in (False, True):
    child = subprocess.Popen([sys.executable, "-c", bridge, sys.argv[1], *(["--fixture-timeout"] if timeout else [])],
        start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        if timeout:
            line = child.stdout.readline()
            try:
                child.wait(timeout=0.1)
                raise AssertionError("fixture bridge should still be running")
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGTERM)
            child.communicate(timeout=5)
            print(line, end="")
        else:
            out, err = child.communicate(timeout=8)
            assert child.returncode == 0, err
            print(out, end="")
    finally:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
            child.communicate(timeout=5)
''')
        result = self.call("run", "--class", "browser", "--", sys.executable, str(driver), CLI,
            env=dict(env, PATH=str(directory / "bin") + os.pathsep + env["PATH"]))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(records), 2)
        for record in records:
            self.assertEqual(record["leases"], [record["token"]])
            self.assertFalse(record["queue"])
            self.assertTrue(record["groups"])
        self.assertEqual(records[0]["token"], records[1]["token"])
        wait_for(lambda: not self.status()["leases"])
        self.assertFalse(self.status()["queue"])
        result = subprocess.run([adapter, "-y", "chrome-devtools-mcp@latest"],
            env=env, text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertFalse(self.status()["queue"])

    def test_recovery_requires_continuous_nominal_observations(self):
        sample = copy.deepcopy(SAMPLE)
        sample["thermalState"] = "serious"
        self.write("input.json", sample)
        wait_for(lambda: "serious" in self.status()["reason"])
        sample["thermalState"] = "nominal"
        self.write("input.json", sample)
        wait_for(lambda: "recovery hysteresis" in self.status()["reason"])
        (self.root / "clock").write_text("181")
        sample["thermalState"] = "fair"
        self.write("input.json", sample)
        wait_for(lambda: "nominal thermal recovery" in self.status()["reason"])
        sample["thermalState"] = "nominal"
        self.write("input.json", sample)
        (self.root / "clock").write_text("242")
        wait_for(lambda: "recovery hysteresis" in self.status()["reason"])
        self.assertEqual(self.call("run", "--wait-seconds", "0.1", "--", "true").returncode, 75)
        (self.root / "clock").write_text("363")
        wait_for(lambda: self.status()["reason"] == "ready")
        sample["thermalState"] = "fair"
        self.write("input.json", sample)
        self.assertEqual(self.call("run", "--wait-seconds", "3", "--", "true").returncode, 0)

    def test_fresh_post_sleep_sample_restarts_recovery(self):
        (self.root / "sleep-offset").write_text("60")
        wait_for(lambda: "recovery hysteresis" in self.status()["reason"])
        self.assertEqual(self.call("run", "--wait-seconds", "0.1", "--", "true").returncode, 75)
        (self.root / "clock").write_text("242")
        wait_for(lambda: self.status()["reason"] == "ready")

    def test_ac_low_battery_blocks_and_cancels(self):
        job = self.job("sleep 30")
        wait_for(lambda: any(l.get("group") for l in self.status().get("leases", {}).values()))
        sample = copy.deepcopy(SAMPLE)
        sample["power"]["batteryPercent"] = 29
        self.write("input.json", sample)
        wait_for(lambda: "30%" in self.status()["reason"])
        self.assertEqual(self.call("run", "--wait-seconds", "0.1", "--", "true").returncode, 75)
        self.assertIsNone(job.poll())
        sample["power"]["batteryPercent"] = 10
        self.write("input.json", sample)
        wait_for(lambda: not self.status().get("leases"))
        job.communicate(timeout=10)
        self.assertNotEqual(job.returncode, 0)

    def test_nested_browser_setup_uses_one_outer_lease(self):
        script = self.root / "browser.sh"
        script.write_text('cat "$FM_RESOURCE_BROWSER_MANIFEST"; test -d "$FM_RESOURCE_BROWSER_PROFILE"; test -n "$FM_RESOURCE_SERVER_PORT"')
        result = self.call("run", "--class", "exclusive", "--", CLI,
            "--config", str(self.root / "config.json"), "run", "--class", "browser", "--", "/bin/sh", str(script))
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(result.stdout)
        self.assertFalse(Path(manifest["profile"]).parent.exists())
        self.assertFalse(self.status()["leases"])

    def test_browser_cleanup_waits_for_descendants_and_survives_restart(self):
        job = self.job('cat "$FM_RESOURCE_BROWSER_MANIFEST"; sleep 30 & sleep 3; exit 0', kind="browser")
        manifest = json.loads(job.stdout.readline())
        self.assertTrue(Path(manifest["profile"]).is_dir())
        wait_for(lambda: any(len(l.get("members", [])) > 1 for l in self.status().get("leases", {}).values()))
        self.stop(signal.SIGKILL)
        self.start()
        wait_for(lambda: self.status().get("leases"))
        self.assertTrue(Path(manifest["profile"]).is_dir())
        sample = copy.deepcopy(SAMPLE)
        sample["power"]["batteryPercent"] = 10
        self.write("input.json", sample)
        wait_for(lambda: not self.status().get("leases"))
        self.assertFalse(Path(manifest["profile"]).parent.exists())
        job.communicate(timeout=10)

    def test_runner_options_and_package_script_environment(self):
        fake = self.root / "runners"
        fake.mkdir()
        for name, argv, expected in (("playwright", ["install", "chromium"], []),
                ("playwright", ["show-report"], []), ("playwright", ["test"], ["--workers=1"]),
                ("nix-build", ["."], ["--max-jobs", "1", "--cores", "2"]),
                ("npm", ["run", "test"], [])):
            with self.subTest(name=name, argv=argv):
                tool = fake / name
                tool.write_text("#!" + sys.executable + "\nimport json, os, sys\nprint(json.dumps([sys.argv[1:], {k:v for k,v in os.environ.items() if k.startswith('VITEST_')}]))\n")
                tool.chmod(0o700)
                result = self.call("run", "--class", "exclusive", "--", str(tool), *argv)
                self.assertEqual(result.returncode, 0, result.stderr)
                actual, env = json.loads(result.stdout)
                self.assertEqual(actual, argv + expected)
                for key in ("VITEST_MAX_WORKERS", "VITEST_MAX_THREADS", "VITEST_MAX_FORKS"):
                    self.assertEqual(env[key], "1")

    def test_package_scripts_cap_node_and_playwright_workers(self):
        fake = self.root / "package-runners"
        fake.mkdir()
        for name in ("node", "playwright", "probe"):
            tool = fake / name
            tool.write_text("#!" + sys.executable + "\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n")
            tool.chmod(0o700)
        for name in ("npm", "pnpm", "yarn"):
            tool = fake / name
            tool.write_text("#!" + sys.executable + '''
import json, shlex, subprocess, sys
args = sys.argv[1:]
script = args.pop(0)
if script in ("run", "run-script"):
    script = args.pop(0)
if args[:1] == ["--"]:
    args.pop(0)
command = json.load(open("package.json"))["scripts"][script]
sys.exit(subprocess.call(command + " " + shlex.join(args), shell=True))
''')
            tool.chmod(0o700)
        env = dict(os.environ, PATH=str(fake) + os.pathsep + os.environ["PATH"])
        adapters = self.root / "script-adapters"
        result = self.call("prepare", "--directory", str(adapters), "--worktree", str(ROOT),
            "--task", "scripts", "--account-label", "default", "--", "true", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        # Model project-local executable precedence for these fake package managers.
        # Node resolves through its adapter here; Playwright is local.
        local = self.root / "node_modules" / ".bin"
        local.mkdir(parents=True)
        (fake / "playwright").rename(local / "playwright")
        env["PATH"] = os.pathsep.join((str(local), str(adapters / "bin"), env["PATH"]))
        for watts, workers in ((140, 2), (65, 1)):
            sample = copy.deepcopy(SAMPLE)
            sample["power"]["adapterWatts"] = watts
            self.write("input.json", sample)
            wait_for(lambda: self.status().get("telemetry", {}).get("power", {}).get("adapterWatts") == watts)
            clock = self.root / "clock"
            clock.write_text(str(int(clock.read_text()) + 121))
            wait_for(lambda: self.status()["reason"] == "ready")
            for runner, script, expected in (
                    ("node", "node --test --test-concurrency=99 sample.test.js",
                        ["--test", f"--test-concurrency={workers}", "sample.test.js"]),
                    ("node-options", "node --env-file .env --test --test-name-pattern --test-concurrency=99 sample.test.js",
                        ["--env-file", ".env", "--test", f"--test-concurrency={workers}", "--test-name-pattern", "--test-concurrency=99", "sample.test.js"]),
                    ("playwright", "playwright test --workers=99 sample.spec.js",
                        ["test", "--workers=99", "sample.spec.js", "--workers=1"]),
                    ("other", "probe sample.js", ["sample.js"])):
                self.write("package.json", {"scripts": {"test": script, "check": script}})
                for name in ("npm", "pnpm", "yarn"):
                    for argv in (["run", "check"], ["test"]):
                        with self.subTest(watts=watts, runner=runner, name=name, argv=argv):
                            # Exercise both direct leasing and the PATH adapter's
                            # inherited-lease path through the executable API.
                            command = [str(fake / name), *argv]
                            if argv[0] == "test":
                                command = [CLI, "--config", str(self.root / "config.json"),
                                    "tool", "--name", name, "--executable", str(fake / name), "--", *argv]
                            result = self.call("run", "--class", "exclusive", "--", *command,
                                cwd=self.root, env=env)
                            self.assertEqual(result.returncode, 0, result.stderr)
                            actual = json.loads(result.stdout)
                            self.assertEqual(actual, expected)

    def test_package_runner_compounds_do_not_silently_escape_limits(self):
        fake = self.root / "npm"
        fake.write_text('#!/bin/sh\necho UNCAPPED\n')
        fake.chmod(0o700)
        for script in ("playwright test && echo finished", "playwright test; echo finished", "playwright test -- sample.js",
                "echo preparing && playwright test", "echo preparing && node --test",
                "node --test && echo finished", "probe node --test playwright test"):
            with self.subTest(script=script):
                self.write("package.json", {"scripts": {"test": script}})
                result = self.call("run", "--class", "exclusive", "--", str(fake), "test", cwd=self.root)
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertNotIn("UNCAPPED", result.stdout)
                self.assertIn("simple runner command", result.stderr)
                self.assertFalse(self.status()["leases"])

    def test_package_forwarded_runner_terminators_are_refused(self):
        self.write("package.json", {"scripts": {"test": "playwright test"}})
        for name in ("npm", "pnpm", "yarn"):
            tool = self.root / name
            tool.write_text("#!" + sys.executable + "\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n")
            tool.chmod(0o700)
            terminators = ["--", "--"] if name == "npm" else ["--"]
            for invocation in (["run", "test"], ["test"]):
                with self.subTest(name=name, invocation=invocation):
                    result = self.call("run", "--class", "exclusive", "--", str(tool), *invocation,
                        *terminators, "--custom=value", cwd=self.root)
                    self.assertEqual(result.returncode, 75, result.stderr)
                    self.assertFalse(result.stdout)
                    self.assertIn("simple runner command", result.stderr)
                    self.assertFalse(self.status()["leases"])
            if name == "npm":
                result = self.call("run", "--class", "exclusive", "--", str(tool), "run", "test", "--", "--custom=value", cwd=self.root)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), ["run", "test", "--", "--custom=value", "--workers=1"])

    @unittest.skipUnless(shutil.which("npm") and shutil.which("node"), "npm and node required")
    def test_real_npm_package_selection_caps_only_selected_runner(self):
        ui = self.root / "ui"
        ui.mkdir()
        for directory in (self.root, ui):
            local = directory / "node_modules" / ".bin"
            local.mkdir(parents=True)
            tool = local / "playwright"
            tool.write_text("#!" + sys.executable + "\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n")
            tool.chmod(0o700)
            (directory / "probe.cjs").write_text("console.log(JSON.stringify(process.argv.slice(2)))")
        (self.root / "user.npmrc").write_text("")
        for root_runner, selected_runner in (("node probe.cjs", "playwright test"), ("playwright test", "node probe.cjs")):
            self.write("package.json", {"private": True, "workspaces": ["ui"], "scripts": {"test": root_runner}})
            self.write("ui/package.json", {"name": "playwright", "version": "1.0.0", "scripts": {"test": selected_runner}})
            for argv in (["--prefix", "ui", "run", "test"], ["run", "test", "--prefix=ui"],
                    ["run", "test", "--workspace", "ui"], ["--workspace=playwright", "run", "test"],
                    ["run", "--workspace", "playwright", "test"], ["run", "test", "-w", "ui"],
                    ["--loglevel", "error", "--prefix", "ui", "run", "test"],
                    ["--userconfig", str(self.root / "user.npmrc"), "--prefix", "ui", "run", "test"],
                    ["--loglevel=error", "--userconfig=" + str(self.root / "user.npmrc"), "-C", "ui", "run", "test"],
                    ["run", "--loglevel", "error", "test", "--workspace", "ui"],
                    ["-C", "ui", "run", "test"]):
                with self.subTest(root_runner=root_runner, argv=argv):
                    result = self.call("run", "--class", "exclusive", "--", shutil.which("npm"), *argv, cwd=self.root)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(json.loads(result.stdout.splitlines()[-1]),
                        ["test", "--workers=1"] if selected_runner == "playwright test" else [])

    def test_package_directory_and_workspace_selection_through_adapters(self):
        ui = self.root / "ui"
        ui.mkdir()
        fake = self.root / "selection-bin"
        fake.mkdir()
        for name in ("pnpm", "yarn"):
            tool = fake / name
            tool.write_text("#!" + sys.executable + '''
import json, os, shlex, subprocess, sys
args = sys.argv[1:]
while args[0] in ("--dir", "-C", "--cwd", "--filter", "-F", "workspace") or "=" in args[0]:
    option, equals, target = args.pop(0).partition("=")
    if not equals:
        target = args.pop(0)
    os.chdir("ui" if option in ("--filter", "-F", "workspace") else target)
script = args.pop(0)
if script == "run":
    script = args.pop(0)
command = json.load(open("package.json"))["scripts"][script]
sys.exit(subprocess.call(command + " " + shlex.join(args), shell=True))
''')
            tool.chmod(0o700)
        local = ui / "node_modules" / ".bin"
        local.mkdir(parents=True)
        for name in ("playwright", "probe"):
            tool = local / name
            tool.write_text("#!" + sys.executable + "\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n")
            tool.chmod(0o700)
        env = dict(os.environ, PATH=os.pathsep.join((str(local), str(fake), os.environ["PATH"])))
        adapters = self.root / "selection-adapters"
        result = self.call("prepare", "--directory", str(adapters), "--worktree", str(ROOT),
            "--task", "selection", "--account-label", "default", "--", "true", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        for selected_runner in ("playwright test", "probe"):
            self.write("package.json", {"workspaces": ["ui"], "scripts": {"test": "playwright test"}})
            self.write("ui/package.json", {"name": "budget-ui", "scripts": {"test": selected_runner}})
            for name, argv in (("pnpm", ["--dir", "ui", "run", "test"]),
                    ("pnpm", ["-C", "ui", "test"]), ("pnpm", ["--filter=budget-ui", "run", "test"]),
                    ("yarn", ["--cwd", "ui", "run", "test"]), ("yarn", ["workspace", "budget-ui", "run", "test"])):
                with self.subTest(runner=selected_runner, name=name, argv=argv):
                    result = self.call("run", "--class", "exclusive", "--", "/bin/sh", "-c", 'exec "$@"',
                        "adapter", str(adapters / "bin" / name), *argv, cwd=self.root, env=env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout), ["test", "--workers=1"] if selected_runner == "playwright test" else [])
        result = self.call("run", "--class", "exclusive", "--", str(adapters / "bin/pnpm"),
            "--filter", "missing", "run", "test", cwd=self.root, env=env)
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertFalse(result.stdout)

    def test_node_adapter_preserves_lower_limits_and_executes_real_node(self):
        fake = self.root / "node-bin"
        fake.mkdir()
        node = fake / "node"
        node.write_text("#!" + sys.executable + "\nimport json, os, sys\nprint(json.dumps([sys.argv[1:], os.getpid()]))\n")
        node.chmod(0o700)
        env = dict(os.environ, PATH=str(fake) + os.pathsep + os.environ["PATH"])
        adapters = self.root / "node-adapters"
        result = self.call("prepare", "--directory", str(adapters), "--worktree", str(ROOT),
            "--task", "node-limits", "--account-label", "default", "--", "true", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        adapter = str(adapters / "bin/node")
        driver = self.root / "node-driver.py"
        driver.write_text('''import json, subprocess, sys
for argv in json.loads(sys.argv[2]):
    child = subprocess.Popen([sys.argv[1], *argv], text=True, stdout=subprocess.PIPE)
    output = json.loads(child.communicate(timeout=10)[0])
    assert child.returncode == 0
    assert output[1] == child.pid, "adapter must exec real node"
    print(json.dumps(output[0]))
''')
        for watts, cap in ((140, 2), (65, 1)):
            sample = copy.deepcopy(SAMPLE)
            sample["power"]["adapterWatts"] = watts
            self.write("input.json", sample)
            wait_for(lambda: self.status().get("telemetry", {}).get("power", {}).get("adapterWatts") == watts)
            clock = self.root / "clock"
            clock.write_text(str(int(clock.read_text()) + 121))
            wait_for(lambda: self.status()["reason"] == "ready")
            cases = [
                (["--test", "--experimental-test-coverage", "--test-coverage-exclude", "fixtures/**", "--test-concurrency=99", "file.js"],
                    ["--test", "--experimental-test-coverage", "--test-coverage-exclude", "fixtures/**", f"--test-concurrency={cap}", "file.js"]),
                (["--test", "--test_concurrency=99", "file.js"], ["--test", f"--test-concurrency={cap}", "file.js"]),
                (["--env_file", ".env", "--test", "--test_concurrency", "1", "file.js"],
                    ["--env_file", ".env", "--test", "--test_concurrency", "1", "file.js"]),
                (["--test", "--test_coverage_exclude", "--test-concurrency=99", "file.js"],
                    ["--test", f"--test-concurrency={cap}", "--test_coverage_exclude", "--test-concurrency=99", "file.js"]),
                (["--env-file", ".env", "--test", "file.js"],
                    ["--env-file", ".env", "--test", f"--test-concurrency={cap}", "file.js"]),
                (["--test", "--test-name-pattern", "--test-concurrency=99", "file.js"],
                    ["--test", f"--test-concurrency={cap}", "--test-name-pattern", "--test-concurrency=99", "file.js"]),
                (["--test", "--test-reporter", "spec", "--test-concurrency=1", "file.js"],
                    ["--test", "--test-reporter", "spec", "--test-concurrency=1", "file.js"]),
                (["--test", "--", "--test-concurrency=99"],
                    ["--test", f"--test-concurrency={cap}", "--", "--test-concurrency=99"]),
                (["--require", "--test", "script.js"], ["--require", "--test", "script.js"]),
                (["--eval=process.exit(0)", "--test"], ["--eval=process.exit(0)", "--test"]),
                (["--test", "file.js"], ["--test", f"--test-concurrency={cap}", "file.js"]),
                (["--test", "--test-concurrency=1", "file.js"], ["--test", "--test-concurrency=1", "file.js"]),
                (["--test-concurrency=99", "--test", "file.js"], [f"--test-concurrency={cap}", "--test", "file.js"]),
                (["--test-concurrency", "1", "--test", "file.js"], ["--test-concurrency", "1", "--test", "file.js"]),
                (["--test", "--test-concurrency", "2", "file.js"], ["--test", "--test-concurrency", str(cap), "file.js"]),
                (["--test", "file.js", "--test-concurrency=99"], ["--test", f"--test-concurrency={cap}", "file.js", "--test-concurrency=99"]),
                (["script.js", "--test"], ["script.js", "--test"]),
                (["-e", "console.log('hello')", "--test"], ["-e", "console.log('hello')", "--test"]),
                (["-r", "setup.js", "--test", "file.js"], ["-r", "setup.js", "--test", f"--test-concurrency={cap}", "file.js"])]
            result = self.call("run", "--class", "exclusive", "--", sys.executable, str(driver),
                adapter, json.dumps([argv for argv, _ in cases]))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([json.loads(line) for line in result.stdout.splitlines()], [expected for _, expected in cases])
            for argv, expected in cases[:2]:
                result = self.call("run", "--class", "test", "--", str(node), *argv)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)[0], expected)

    def test_plain_node_passthrough_preserves_exit_and_signal_without_owner(self):
        fake = self.root / "plain-node-bin"
        fake.mkdir()
        node = fake / "node"
        node.write_text("#!" + sys.executable + '''
import json, os, sys, time
print(json.dumps([sys.argv[1:], os.getpid()]), flush=True)
if sys.argv[1:] == ["sleep.js"]:
    time.sleep(30)
sys.exit(23)
''')
        node.chmod(0o700)
        adapters = self.root / "plain-node-adapters"
        result = self.call("prepare", "--directory", str(adapters), "--worktree", str(ROOT),
            "--task", "plain-node", "--account-label", "default", "--", "true",
            env=dict(os.environ, PATH=str(fake) + os.pathsep + os.environ["PATH"]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.stop()
        adapter = str(adapters / "bin/node")
        child = subprocess.Popen([adapter, "script.js", "arg"], text=True, stdout=subprocess.PIPE)
        self.children.append(child)
        out, _ = child.communicate(timeout=10)
        self.assertEqual(child.returncode, 23)
        self.assertEqual(json.loads(out), [["script.js", "arg"], child.pid])
        child = subprocess.Popen([adapter, "sleep.js"], text=True, stdout=subprocess.PIPE)
        self.children.append(child)
        self.assertEqual(json.loads(child.stdout.readline()), [["sleep.js"], child.pid])
        child.terminate()
        child.communicate(timeout=10)
        self.assertEqual(child.returncode, -signal.SIGTERM)

    @unittest.skipUnless(shutil.which("npm") and shutil.which("node"), "npm and node required")
    def test_real_npm_node_tests_run_one_file_at_a_time(self):
        self.write("package.json", {"scripts": {"test": "node --test --test-concurrency=99 first.cjs second.cjs"}})
        probe = '''const fs = require('node:fs');
fs.mkdirSync('active-test');
setTimeout(() => fs.rmdirSync('active-test'), 300);
'''
        for name in ("first.cjs", "second.cjs"):
            (self.root / name).write_text(probe)
        adapters = self.root / "real-adapters"
        result = self.call("prepare", "--directory", str(adapters), "--worktree", str(ROOT),
            "--task", "real-npm", "--account-label", "default", "--", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        env = dict(os.environ, PATH=str(adapters / "bin") + os.pathsep + os.environ["PATH"])
        for argv in (["run", "test"], ["test"]):
            with self.subTest(argv=argv):
                result = self.call("run", "--class", "exclusive", "--", shutil.which("npm"), *argv,
                    cwd=self.root, env=env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse((self.root / "active-test").exists())

    @unittest.skipUnless(shutil.which("npm") and shutil.which("node"), "npm and node required")
    def test_direct_npm_node_tests_cap_new_and_inherited_leases_with_ordinary_path(self):
        probe = "const fs = require('node:fs'); fs.mkdirSync('active-test'); setTimeout(() => fs.rmdirSync('active-test'), 300);"
        for name in ("first.cjs", "second.cjs"):
            (self.root / name).write_text(probe)
        for options in ("--test-concurrency=99", "--test_concurrency=99",
                "--experimental-test-coverage --test-coverage-exclude fixtures/** --test-concurrency=99"):
            self.write("package.json", {"scripts": {"test": "node --test " + options + " first.cjs second.cjs"}})
            for inherited in (False, True):
                with self.subTest(options=options, inherited=inherited):
                    command = [shutil.which("npm"), "test"]
                    if inherited:
                        command = ["/bin/sh", "-c", 'exec "$@"', "nested", CLI, "--config", str(self.root / "config.json"),
                            "run", "--class", "test", "--", *command]
                    result = self.call("run", "--class", "test", "--", *command, cwd=self.root)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertFalse((self.root / "active-test").exists())

    def test_registered_check_emits_each_transition_once(self):
        state = self.root / "home-state"
        state.mkdir(mode=0o755)
        state.chmod(0o755)
        result = self.call("register-check", "--directory", str(state))
        self.assertEqual(result.returncode, 0, result.stderr)
        check = state / "host-budget.check.sh"
        self.assertTrue((state / "host-budget.check-trust").is_file())
        def poll():
            result = subprocess.run([str(check)], text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.splitlines()
        first = poll()
        self.assertTrue(first)
        self.assertEqual(poll(), [])
        sample = copy.deepcopy(SAMPLE)
        sample["thermalState"] = "serious"
        self.write("input.json", sample)
        wait_for(lambda: "serious" in self.status()["reason"])
        lines = wait_for(poll)
        self.assertEqual(len(lines), 1)
        self.assertIn("serious", lines[0])
        self.assertEqual(poll(), [])
        self.assertEqual(state.stat().st_mode & 0o777, 0o755)
        for name, mode in (("host-budget.check.sh", 0o700), ("host-budget.check-trust", 0o600),
                (".host-budget-cursor", 0o600), (".host-budget-cursor.lock", 0o600)):
            self.assertEqual((state / name).stat().st_mode & 0o777, mode)

    def test_read_only_package_queries_bypass_compute_veto(self):
        sample = copy.deepcopy(SAMPLE)
        sample["thermalState"] = "serious"
        self.write("input.json", sample)
        wait_for(lambda: "serious" in self.status()["reason"])
        fake = self.root / "packagebin"
        fake.mkdir()
        for name in ("npm", "pnpm", "yarn"):
            tool = fake / name
            tool.write_text('#!/bin/sh\nprintf "query:%s" "$*"\n')
            tool.chmod(0o700)
        directory = self.root / "package-adapters"
        result = self.call("prepare", "--directory", str(directory), "--worktree", str(ROOT),
            "--task", "queries", "--account-label", "default", "--", "true",
            env=dict(os.environ, PATH=str(fake) + os.pathsep + os.environ["PATH"]))
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("npm", "pnpm", "yarn"):
            queries = ["info", "list", "outdated", "help", "--version", "--help"]
            if name != "yarn":
                queries += ["view", "ls", "version"]
            for query in queries:
                argv = [query] if query in ("version", "--version", "--help", "help") else [query, "package"]
                with self.subTest(name=name, argv=argv):
                    result = subprocess.run([str(directory / "bin" / name), *argv],
                        capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, "query:" + " ".join(argv))
        self.assertFalse(self.status()["leases"])
        self.assertFalse(self.status()["queue"])
        self.stop()
        for name, argv in (("npm", ["version", "patch"]), ("pnpm", ["run", "test"]),
                ("yarn", ["version"]), ("yarn", ["build"])):
            result = subprocess.run([str(directory / "bin" / name), *argv],
                capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 75, result.stderr)
            self.assertNotIn("query:", result.stdout)

    def test_unrequested_runner_settings_are_preserved(self):
        keys = ("RAYON_NUM_THREADS", "CARGO_BUILD_JOBS", "CMAKE_BUILD_PARALLEL_LEVEL",
            "OMP_NUM_THREADS", "GOMAXPROCS")
        probe = "import json,os; print(json.dumps({k:os.environ.get(k) for k in " + repr(keys) + "}))"
        for inherited in (False, True):
            for configured in (False, True):
                with self.subTest(inherited=inherited, configured=configured):
                    env = os.environ.copy()
                    for key in keys:
                        env.pop(key, None)
                    if configured:
                        env.update({key: "7" for key in keys})
                    command = [sys.executable, "-c", probe]
                    if inherited:
                        command = [CLI, "--config", str(self.root / "config.json"),
                            "run", "--class", "test", "--", *command]
                    result = self.call("run", "--class", "exclusive", "--", *command, env=env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout), {key: "7" if configured else None for key in keys})

    def test_interactive_launch_preserves_foreground_and_interrupts(self):
        probe = self.root / "terminal-probe.py"
        probe.write_text('''import json, os, signal, sys
signal.signal(signal.SIGINT, lambda *_: print("INTERRUPTED", flush=True))
print("PROBE:" + json.dumps([os.getpid(), os.getpgrp(), os.tcgetpgrp(0)]), flush=True)
for line in sys.stdin:
    if line.strip() == "exit":
        break
print("EXITED", flush=True)
''')
        for kind in ("worker", "test"):
            with self.subTest(kind=kind):
                command = [CLI, "--config", str(self.root / "config.json"), "run", "--class", kind,
                    "--", sys.executable, str(probe)]
                after = "import os; print('RESTORED:' + str(os.getpgrp() == os.tcgetpgrp(0)), flush=True)"
                script = shlex.join(command) + "; " + shlex.join([sys.executable, "-c", after])
                pid, master = pty.fork()
                if pid == 0:
                    os.execv("/bin/sh", ["/bin/sh", "-c", script])
                output = bytearray()
                def read_until(marker):
                    def received():
                        if select.select([master], [], [], 0.05)[0]:
                            try:
                                output.extend(os.read(master, 65536))
                            except OSError:
                                pass
                        return marker in output
                    try:
                        wait_for(received)
                    except AssertionError:
                        self.fail(f"missing {marker!r}; terminal output: {bytes(output)!r}; owner: {self.status()!r}")
                try:
                    read_until(b"PROBE:")
                    read_until(b"]")
                    record = bytes(output).split(b"PROBE:", 1)[1].splitlines()[0]
                    child_pid, group, foreground = json.loads(record)
                    self.assertEqual(child_pid, group)
                    self.assertEqual(group, foreground)
                    self.assertNotEqual(group, pid)
                    self.assertTrue(any(l.get("group", {}).get("pid") == group
                        for l in self.status()["leases"].values()))
                    os.write(master, b"\x03")
                    read_until(b"INTERRUPTED")
                    self.assertTrue(self.status()["leases"])
                    os.write(master, b"exit\n")
                    read_until(b"EXITED")
                    read_until(b"RESTORED:True")
                    ended, status = os.waitpid(pid, 0)
                    self.assertEqual(ended, pid)
                    self.assertEqual(os.waitstatus_to_exitcode(status), 0)
                    pid = None
                    self.assertFalse(self.status()["leases"])
                finally:
                    if pid is not None:
                        os.kill(pid, signal.SIGKILL)
                        os.waitpid(pid, 0)
                    os.close(master)


if __name__ == "__main__":
    unittest.main(verbosity=2)

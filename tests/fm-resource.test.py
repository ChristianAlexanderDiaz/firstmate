#!/usr/bin/env python3
"""Behavior through the executable, socket protocol and durable recovery ledger."""
import copy
import importlib.util
import json
import os
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
printf '#!/bin/sh\\nprintf "resource-probe=%%s\\n" "$FM_TASK_ID"\\nexec "%s/bin/fm-resource-run" status\\n' "$ROOT" > "$fakebin/codex"
chmod +x "$fakebin/codex"
export FM_FAKE_LAUNCH_LOG=$case_root/launch.log
FM_RESOURCE_CONFIG=$2/config.json fm_test_run_spawn "$task_home" "$worktree" "$fakebin" budget-fixture "$project" --mode no-mistakes --yolo off > "$case_root/spawn.out"
cd "$worktree"
export FM_TASK_ID=budget-fixture
PATH="$fakebin:$PATH" /bin/bash -c "$(cat "$case_root/launch.log")"
''')
        result = subprocess.run(["/bin/bash", str(script), str(ROOT), str(self.root)],
            text=True, capture_output=True, timeout=40)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("resource-probe=budget-fixture", result.stdout)
        status = json.loads(result.stdout.split("\n", 1)[1])
        self.assertTrue(any(lease["class"] == "worker" and lease.get("group") for lease in status["leases"].values()))

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
        self.assertEqual(Path(manifest["profile"]).stat().st_mode & 0o777, 0o700)
        result = self.call("run", "--class", "browser", "--", "chrome-devtools-axi", "start")
        self.assertEqual(result.returncode, 75)


if __name__ == "__main__":
    unittest.main(verbosity=2)

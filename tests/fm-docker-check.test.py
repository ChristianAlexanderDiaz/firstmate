#!/usr/bin/env python3
"""Exercise the registered check with synthetic task endpoints and Docker results."""
from datetime import datetime, timezone
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DockerCheckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fm-docker-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        for directory in ("state", "config", "bin"):
            (self.home / directory).mkdir(mode=0o700)
        self.env = dict(os.environ, PATH=str(self.home / "bin") + os.pathsep + os.environ["PATH"],
            FIXTURE_HOME=str(self.home), PYTHONDONTWRITEBYTECODE="1", FM_CHECK_TIMEOUT="30")
        self.docker = self.home / "bin/docker-fixture"
        self.docker.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$FIXTURE_HOME/docker-calls"
case "$(cat "$FIXTURE_HOME/docker-result")" in
  healthy) exit 0 ;;
  hanging) exec sleep 60 ;;
  *) printf 'sensitive daemon details\\n' >&2; exit 1 ;;
esac
''')
        self.docker.chmod(0o700)
        tmux = self.home / "bin/tmux"
        tmux.write_text('''#!/bin/sh
[ -e "$FIXTURE_HOME/live" ] && printf '%%17\\n'
''')
        tmux.chmod(0o700)
        (self.home / "docker-result").write_text("healthy")
        self.meta = self.home / "state/fixture-task.meta"
        self.meta.write_text("project=/fixture/example\nkind=ship\nwindow=%17\n")
        (self.home / "config/docker-projects").write_text("# explicit dependency\nexample\n")
        (self.home / "live").touch()
        self.run_cli("register-check")

    def run_cli(self, action, timeout=1):
        result = subprocess.run([sys.executable, str(ROOT / "bin/fm-docker-check.py"),
            "--home", str(self.home), "--docker", str(self.docker), "--timeout", str(timeout), action],
            env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def poll(self):
        result = subprocess.run([str(self.home / "state/docker.check.sh")],
            env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return result.stdout

    def test_failure_once_recovery_and_registration_permissions(self):
        self.assertEqual(self.poll(), "")
        (self.home / "docker-result").write_text("failed")
        alarm = self.poll()
        self.assertIn("docker-unavailable:", alarm)
        self.assertNotIn("sensitive", alarm)
        stamp = datetime.fromisoformat(alarm.split()[0].replace("Z", "+00:00"))
        self.assertEqual(stamp.tzinfo, timezone.utc)
        self.assertLess(abs(time.time() - stamp.timestamp()), 10)
        self.assertEqual(self.poll(), "")
        (self.home / "docker-result").write_text("healthy")
        self.assertEqual(self.poll(), "")
        self.assertFalse((self.home / "state/.docker-unavailable").exists())
        (self.home / "docker-result").write_text("failed")
        self.assertIn("docker-unavailable:", self.poll())
        for name, mode in (("docker.check.sh", 0o700), ("docker.check-trust", 0o600),
                (".docker-unavailable", 0o600), (".docker-check.lock", 0o600)):
            self.assertEqual((self.home / "state" / name).stat().st_mode & 0o777, mode)
        self.assertEqual(set((self.home / "docker-calls").read_text().splitlines()), {"info"})

    def test_no_matching_live_local_task_does_not_call_docker(self):
        (self.home / "docker-result").write_text("failed")
        for metadata in ("project=/fixture/unlisted\nwindow=%17\n", "project=/fixture/example\n",
                "project=/fixture/example\nwindow=%17\nremote_host=remote\n",
                "project=/fixture/example\nwindow=%17\nkind=secondmate\n"):
            with self.subTest(metadata=metadata):
                self.meta.write_text(metadata)
                self.assertEqual(self.poll(), "")
        self.meta.write_text("project=/fixture/example\nwindow=%17\n")
        (self.home / "live").unlink()
        self.assertEqual(self.poll(), "")
        (self.home / "live").touch()
        (self.home / "config/docker-projects").unlink()
        self.assertEqual(self.poll(), "")
        self.assertFalse((self.home / "docker-calls").exists())

    def test_timeout_missing_executable_and_task_exit_rearm(self):
        (self.home / "docker-result").write_text("hanging")
        start = time.monotonic()
        self.assertIn("docker-unavailable:", self.poll())
        self.assertLess(time.monotonic() - start, 5)
        (self.home / "live").unlink()
        self.assertEqual(self.poll(), "")
        self.docker.unlink()
        (self.home / "live").touch()
        self.assertIn("docker-unavailable:", self.poll())
        self.assertEqual(self.poll(), "")

    def test_overlapping_polls_emit_one_alarm(self):
        self.docker.write_text("#!/bin/sh\nsleep 0.2\nexit 1\n")
        command = [str(self.home / "state/docker.check.sh")]
        children = [subprocess.Popen(command, env=self.env, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True) for _ in range(2)]
        results = [child.communicate(timeout=10) for child in children]
        self.assertEqual([child.returncode for child in children], [0, 0])
        self.assertEqual(sum(len(stdout.splitlines()) for stdout, _ in results), 1)
        self.assertTrue(all(stderr == "" for _, stderr in results))

    def test_maximum_registered_timeout_alarms_before_consumer_deadline(self):
        (self.home / "state/docker.check.sh").unlink()
        self.run_cli("register-check", timeout=30)
        (self.home / "docker-result").write_text("hanging")
        start = time.monotonic()
        result = subprocess.run([str(self.home / "state/docker.check.sh")],
            env=self.env, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("docker-unavailable:", result.stdout)
        self.assertLess(time.monotonic() - start, 29.5)
        self.assertTrue((self.home / "state/.docker-unavailable").exists())

    def test_slow_endpoints_and_docker_share_consumer_budget(self):
        self.env["FM_CHECK_TIMEOUT"] = "8"
        for index in range(2):
            (self.home / f"state/aaa-{index}.meta").write_text(
                "project=/fixture/example\nwindow=@slow\n")
        (self.home / "bin/tmux").write_text('''#!/bin/sh
case "$1" in list-windows) exec sleep 60 ;; esac
printf '%%17\\n'
''')
        (self.home / "docker-result").write_text("hanging")
        start = time.monotonic()
        result = self.run_cli("check", timeout=30)
        self.assertIn("docker-unavailable:", result.stdout)
        self.assertLess(time.monotonic() - start, 7.5)
        self.assertEqual((self.home / "docker-calls").read_text().splitlines(), ["info"])

    def test_endpoint_discovery_stops_at_shared_deadline(self):
        self.env["FM_CHECK_TIMEOUT"] = "6"
        for index in range(8):
            (self.home / f"state/aaa-{index}.meta").write_text(
                "project=/fixture/example\nwindow=%slow\n")
        (self.home / "bin/tmux").write_text("#!/bin/sh\nexec sleep 60\n")
        start = time.monotonic()
        self.assertEqual(self.run_cli("check", timeout=30).stdout, "")
        self.assertLess(time.monotonic() - start, 5.5)
        self.assertFalse((self.home / "docker-calls").exists())

    def slow_prefix(self):
        self.env["FM_CHECK_TIMEOUT"] = "6"
        for index in range(3):
            (self.home / f"state/aaa-{index}.meta").write_text(
                "project=/fixture/example\nwindow=@slow\n")
        (self.home / "bin/tmux").write_text('''#!/bin/sh
case "$1" in list-windows) exec sleep 60 ;; esac
[ -e "$FIXTURE_HOME/live" ] && printf '%%17\\n'
''')

    def test_later_live_endpoint_eventually_alarms(self):
        self.slow_prefix()
        (self.home / "docker-result").write_text("failed")
        self.assertEqual(self.poll(), "")
        self.assertFalse((self.home / "docker-calls").exists())
        alarms = []
        for _ in range(3):
            start = time.monotonic()
            alarm = self.poll()
            self.assertLess(time.monotonic() - start, 5.5)
            if alarm:
                alarms.append(alarm)
                break
        self.assertEqual(len(alarms), 1)
        self.assertIn("docker-unavailable:", alarms[0])

    def test_incomplete_discovery_preserves_outage(self):
        (self.home / "docker-result").write_text("failed")
        self.assertIn("docker-unavailable:", self.poll())
        record = self.home / "state/.docker-unavailable"
        original = record.read_bytes()
        self.slow_prefix()
        for _ in range(2):
            self.assertEqual(self.poll(), "")
            self.assertEqual(record.read_bytes(), original)
        (self.home / "live").unlink()
        for meta in (self.home / "state").glob("aaa-*.meta"):
            meta.unlink()
        self.assertEqual(self.poll(), "")
        self.assertFalse(record.exists())


if __name__ == "__main__":
    unittest.main()

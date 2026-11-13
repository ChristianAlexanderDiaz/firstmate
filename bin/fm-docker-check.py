#!/usr/bin/env python3
"""Registered, opt-in Docker availability alarm for local task endpoints."""

import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time

from fm_resource import Refusal, atomic_json, check_directory

HERE = Path(__file__).resolve().parent


def bounded(argv, timeout, env=None):
    """Discard tool output, kill the command group, and reap the direct child."""
    if timeout <= 0:
        return None
    try:
        process = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True, env=env)
    except OSError:
        return False
    try:
        return process.wait(timeout=timeout) == 0
    except subprocess.TimeoutExpired:
        return None
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def live_dependency(home, projects, deadline):
    # Use the existing backend abstraction for every supported task runtime.
    # Remote secondmates monitor their own local dependencies in their home.
    probe = '''
source "$1/fm-backend.sh"
target=$(fm_backend_target_of_meta "$2")
[ -n "$target" ] || exit 1
fm_backend_target_exists "$(fm_backend_of_meta "$2")" "$target" "fm-$3"
'''
    cursor = home / "state/.docker-check-cursor"
    after = json.loads(cursor.read_text())["after"] if cursor.exists() else ""
    metas = sorted((home / "state").glob("*.meta"))
    metas = [meta for meta in metas if meta.name > after] + [meta for meta in metas if meta.name <= after]
    incomplete = False
    last = None
    try:
        for meta in metas:
            if deadline <= time.monotonic():
                return None
            last = meta.name
            if meta.is_symlink():
                continue
            fields = dict(line.split("=", 1) for line in meta.read_text().splitlines() if "=" in line)
            if (fields.get("remote_host") or fields.get("kind") == "secondmate" or
                    Path(fields.get("project", "")).name not in projects):
                continue
            result = bounded(["/bin/bash", "-c", probe, "docker-check", str(HERE), str(meta), meta.stem],
                min(2, deadline - time.monotonic()), env=dict(os.environ, FM_HOME=str(home)))
            if result:
                return True
            incomplete = incomplete or result is None
        return None if incomplete else False
    finally:
        if last is not None:
            atomic_json(cursor, {"after": last})


def check(args, home):
    consumer_timeout = float(os.environ.get("FM_CHECK_TIMEOUT", "30"))
    if not 0 < consumer_timeout < float("inf"):
        raise ValueError("FM_CHECK_TIMEOUT must be positive and finite")
    deadline = time.monotonic() + max(0, consumer_timeout - 2)
    state = home / "state"
    record = state / ".docker-unavailable"
    with os.fdopen(os.open(state / ".docker-check.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        config = home / "config/docker-projects"
        projects = {line.strip() for line in config.read_text().splitlines()
            if line.strip() and not line.lstrip().startswith("#")} if config.exists() else set()
        dependency = live_dependency(home, projects, deadline) if projects else False
        if dependency is None:
            return
        if not dependency:
            record.unlink(missing_ok=True)
            return
        if bounded([args.docker, "info"], min(args.timeout, deadline - time.monotonic())):
            record.unlink(missing_ok=True)
            return
        if record.exists():
            return
        stamp = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        atomic_json(record, {"timestamp": stamp})
        print(f"{stamp} docker-unavailable: docker info failed or timed out while a Docker-dependent task is live", flush=True)


def register(args, home):
    state = home / "state"
    check_path = state / "docker.check.sh"
    command = [sys.executable, str(Path(__file__).resolve()), "--home", str(home),
        "--docker", args.docker, "--timeout", str(args.timeout), "check"]
    with os.fdopen(os.open(check_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o700), "w") as stream:
        stream.write("#!/bin/sh\nexec " + shlex.join(command) + "\n")
    check_path.chmod(0o700)
    try:
        subprocess.run(["/bin/bash", str(HERE / "fm-check-register.sh"), "docker"],
            env=dict(os.environ, FM_HOME=str(home), FM_STATE_OVERRIDE=str(state)), check=True)
    except BaseException:
        check_path.unlink()
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog="""
Create HOME/config/docker-projects with one project directory basename per line
(blank lines and # comments ignored). Only local non-secondmate task records
with matching project names and an existing backend endpoint count as live.
No configuration or confirmed absence of matching live endpoints clears the episode.
Incomplete discovery is silent, preserves the episode, and resumes across polls.
A healthy docker info also clears it; failure, timeout or missing executable
prints one UTC-timestamped alarm per episode. Tool output is never relayed.
--docker selects an executable (no shell expansion); --timeout bounds docker info.
Endpoint discovery and Docker probing share FM_CHECK_TIMEOUT (default 30) minus
two seconds reserved for recording and emitting the alarm.
register-check creates and trusts HOME/state/docker.check.sh; retire it with
FM_HOME=HOME bin/fm-check-unregister.sh docker before changing registration.
Use a stable installed code path. This check never starts or restarts Docker.
""")
    parser.add_argument("--home", required=True, help="absolute supervising home with an existing state directory")
    parser.add_argument("--docker", default="docker", help="Docker executable or injectable test replacement")
    parser.add_argument("--timeout", type=int, choices=range(1, 31), default=5, metavar="SECONDS")
    parser.add_argument("action", choices=("check", "register-check"))
    args = parser.parse_args()
    home = check_directory(args.home)
    check_directory(home / "state")
    if args.action == "register-check":
        register(args, home)
    else:
        check(args, home)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, Refusal, subprocess.CalledProcessError) as error:
        print(f"docker-check: {error}", file=sys.stderr)
        sys.exit(1)

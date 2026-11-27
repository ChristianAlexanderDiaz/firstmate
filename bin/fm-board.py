#!/usr/bin/env python3
"""Lavish board inventory and author protection; no board capacity limit.

Usage: fm-board.py record STATE SOURCE
       fm-board.py snapshot STATE [--liveness]
       fm-board.py guard STATE TASK
       fm-board.py pressure-guard STATE TASK
       fm-board.py pressure-lock STATE

record stores a locator under the shared process-event claim root's boards/
directory. Registrations remain the sole authority for ownership. Locators let
the fleet find an author across homes even between listener rounds; legacy
claims and the current home's registry supply pre-upgrade boards. Saved Lavish
sessions supply open/closed status. No session, worker or listener is changed.
guard refuses exit/cleanup until the author's registration is retired, including
a terminal round awaiting acknowledgement. Malformed records refuse protection
checks instead of letting an author close. pressure-guard accepts only fresh
same-boot OS memory warning/critical or serious/critical thermal pressure, and
the oldest current-generation semantic idle timestamp among live board authors.
Unknown liveness/idle age refuses selection; busy authors are excluded.
fm-control serializes pressure exits using pressure-lock, rechecks immediately
before submission and records verified closure. Resume belongs to its saved-
session path, not this helper.
"""

import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time


def root():
    return Path(os.environ.get("FM_PROCEVENT_CLAIM_ROOT", str(
        Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
        / "firstmate/procevent-claims")))


def read_json(path, default):
    try:
        with path.open() as stream:
            return json.load(stream)
    except FileNotFoundError:
        return default


def source_paths(state):
    directory = Path(state) / "procevent"
    try:
        mode = directory.lstat().st_mode
    except FileNotFoundError:
        return []
    if not stat.S_ISDIR(mode):
        raise ValueError(f"invalid board registry: {directory}")
    # pathlib.glob can suppress scandir errors; uncertainty must refuse exit.
    with os.scandir(directory) as entries:
        return [Path(entry.path) for entry in entries if entry.name.endswith(".source")]


def registration(path):
    if path.is_symlink():
        raise ValueError(f"symlink board registration: {path}")
    try:
        fields, argv = path.read_text().split("argv:\n", 1)
    except FileNotFoundError:
        return None
    pairs = [line.split("=", 1) for line in fields.splitlines() if "=" in line]
    fields = dict(pairs)
    if any(sum(key == name for key, _ in pairs) > 1 for name in ("adapter", "owner_task")):
        raise ValueError(f"ambiguous board ownership: {path}")
    argv = argv.splitlines()
    if fields.get("adapter") != "lavish":
        return None
    if len(argv) < 3 or argv[1] != "poll":
        if fields.get("owner_task"):
            raise ValueError(f"malformed owned board: {path}")
        return None
    return dict(source=path.stem, artifact=str(Path(argv[2]).resolve()),
                state=str(path.parent.parent.resolve()), task=fields.get("owner_task", ""),
                registered_at=int(fields.get("registered_at", int(path.stat().st_mtime))),
                registered=True)


def record(state, source):
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]*", source):
        raise ValueError("invalid source identifier")
    path = Path(state) / "procevent" / (source + ".source")
    value = registration(path)
    if value is None:
        return
    value["registration"] = str(path)
    directory = root() / "boards"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".board-", dir=directory)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream)
        os.replace(name, directory / (source + ".json"))
    finally:
        if os.path.exists(name):
            os.unlink(name)


def inventory(state, liveness=False):
    store = Path(os.environ.get("LAVISH_AXI_STATE_DIR", str(Path.home() / ".lavish-axi")))
    sessions = read_json(store / "state.json", {"sessions": {}})
    if not isinstance(sessions, dict) or not isinstance(sessions.get("sessions"), dict):
        raise ValueError("invalid Lavish session store")
    rows = {}
    for session in sessions["sessions"].values():
        if not isinstance(session, dict) or not isinstance(session.get("file"), str):
            raise ValueError("invalid Lavish session")
        artifact = str(Path(session["file"]).resolve())
        rows[artifact] = dict(artifact=artifact, status="closed" if session.get("status") == "ended" else "open",
                              url=session.get("url", ""), task="", state="", registered=False,
                              registered_at=None, author="unknown")
    paths = set(source_paths(state))
    for locator in (root() / "boards").glob("*.json"):
        entry = read_json(locator, {})
        paths.add(Path(entry["registration"]))
        if entry["artifact"] in rows:
            rows[entry["artifact"]].update(task=entry["task"], state=entry["state"])
    # Claims locate pre-upgrade boards without consulting another home's index.
    for claim in root().glob("lavish-*.claim"):
        lines = claim.read_text().splitlines()
        if len(lines) >= 5 and lines[4]:
            paths.add(Path(lines[4]) / (claim.stem + ".source"))
        elif lines:
            paths.add(Path(lines[0]) / "state/procevent" / (claim.stem + ".source"))
    for path in sorted(paths):
        value = registration(path)
        if value is None:
            continue
        row = rows.setdefault(value["artifact"], dict(artifact=value["artifact"], status="open", url="", author="unknown"))
        row.update(value)
    for row in rows.values():
        if row["status"] == "closed":
            row["author"] = "board-closed"
        elif liveness and row.get("task"):
            probe = Path(__file__).with_name("fm-procevent-lavish.sh")
            env = dict(os.environ, FM_HOME=str(Path(row["state"]).parent), FM_STATE_OVERRIDE=row["state"])
            try:
                result = subprocess.run([str(probe), "author-state", row["state"], row["task"]],
                                        env=env, capture_output=True, text=True, timeout=10, check=False)
                verdict = result.stdout.strip()
                row["author"] = verdict if result.returncode == 0 and verdict in (
                    "alive", "dead", "missing", "unknown") else "unknown"
            except subprocess.TimeoutExpired:
                row["author"] = "unknown"
    return sorted(rows.values(), key=lambda row: row["artifact"])


def pressure_guard(state, task):
    # Reuse the host-budget owner's configuration and host identity primitives.
    # A quota, battery mode, missing reading or recovery dwell is not pressure.
    sys.dont_write_bytecode = True
    from fm_resource import load_config, boot_id, uptime, Refusal
    try:
        _, config, _ = load_config(None)
    except Refusal as error:
        raise ValueError(str(error)) from error
    sample = read_json(Path(config["monitorPath"]), {})
    if not isinstance(sample, dict):
        raise ValueError("invalid machine pressure sample")
    wall_age = time.time() - float(sample["timestamp"])
    try:
        uptime_age = uptime() - float(sample["uptimeSeconds"])
    except Refusal as error:
        raise ValueError(str(error)) from error
    if (sample.get("schemaVersion") != 1 or sample.get("lifecycle") != "running" or
            sample.get("bootSessionUUID") != boot_id() or
            not all(math.isfinite(age) and -1 <= age <= 10 for age in (wall_age, uptime_age))):
        raise ValueError("machine pressure requires a fresh same-boot monitor sample")
    unavailable = sample.get("unavailable")
    if not isinstance(unavailable, list):
        raise ValueError("machine pressure readings are unavailable")
    memory = sample.get("memory")
    memory = memory.get("pressure") if isinstance(memory, dict) else None
    thermal = sample.get("thermalState")
    if not ((memory in ("warning", "critical") and "memory.pressure" not in unavailable) or
            (thermal in ("serious", "critical") and "thermalState" not in unavailable)):
        raise ValueError("no current RAM or thermal CPU pressure; board authors stay open")
    candidates = []
    seen = set()
    for row in inventory(state, liveness=True):
        identity = (row.get("state"), row.get("task"))
        if not identity[1] or not row.get("registered") or identity in seen:
            continue
        seen.add(identity)
        if row["author"] in ("dead", "missing", "board-closed"):
            continue
        if row["author"] != "alive":
            raise ValueError("cannot rank board authors with unknown liveness")
        probe = Path(__file__).with_name("fm-procevent-lavish.sh")
        env = dict(os.environ, FM_HOME=str(Path(identity[0]).parent), FM_STATE_OVERRIDE=identity[0])
        result = subprocess.run([str(probe), "idle-since", *identity],
                                env=env, capture_output=True, text=True, timeout=10, check=False)
        value = result.stdout.strip()
        if result.returncode == 0 and value == "busy":
            continue
        if result.returncode or not value.isdigit() or int(value) > time.time():
            raise ValueError(f"cannot prove idle age for board author {identity[1]}")
        candidates.append((int(value), *identity))
    if not candidates or min(candidates)[1:] != (state, task):
        raise ValueError("pressure exit requires the longest-idle live board author")
    return 0


def main():
    command, state, *args = sys.argv[1:]
    state = str(Path(state).resolve())
    if command == "pressure-lock":
        print(root() / ".board-pressure.lock")
        return 0
    if command == "pressure-guard":
        return pressure_guard(state, *args)
    if command == "guard":
        task, = args
        for path in source_paths(state):
            value = registration(path)
            if value and value["task"] == task:
                print(f"refused: {task} authors open board {value['artifact']}; conclude and acknowledge its session before exit or cleanup", file=sys.stderr)
                return 1
        return 0
    if command == "snapshot":
        print(json.dumps(inventory(state, "--liveness" in args)))
        return 0
    if command == "record":
        source, = args
        record(state, source)
        return 0
    raise ValueError("unknown board command")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        print(f"board inventory unavailable: {error}", file=sys.stderr)
        sys.exit(1)

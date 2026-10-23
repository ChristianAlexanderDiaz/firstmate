#!/usr/bin/env python3
"""Fixture only: fresh synthetic dotfiles monitor and controllable policy clock.

The production owner and every real client/socket/process path remain intact.
An optional legacy-owner marker models an owner that predates portable status
and browser bridge recovery.
No thermal load, machine settings, user daemon or runtime backend is involved.
"""
import importlib.util
import json
import os
from pathlib import Path
import sys
import threading
import time
import types

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("resource", sys.argv[1])
resource = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resource)
root = Path(sys.argv[2])
real_time = time
real_uptime = resource.uptime
real_process_table = resource.process_table
wall_epoch = real_time.time() - real_time.monotonic()


def wall_time():
    # Keep the synthetic monitor and owner on one stable wall-clock basis.
    # Host clock corrections must not restart this fixture's policy recovery.
    return wall_epoch + real_time.monotonic()


def process_table():
    rows = real_process_table()
    try:
        orphan = int((root / "orphan-controller").read_text())
        if orphan in rows:
            rows[orphan]["ppid"] = 1
    except (OSError, ValueError):
        pass
    return rows


resource.process_table = process_table
real_handle = resource.Budget.handle


def handle(budget, request):
    legacy = (root / "legacy-owner").exists() and isinstance(request, dict)
    if legacy and request.get("op") == "inherit-browser":
        raise resource.Refusal("invalid request nonce")
    result = real_handle(budget, request)
    if legacy and request.get("op") == "status":
        result.pop("portable", None)
    return result


resource.Budget.handle = handle


def awake_uptime():
    try:
        slept = float((root / "sleep-offset").read_text())
    except (OSError, ValueError):
        slept = 0
    return real_uptime() - slept


resource.uptime = awake_uptime


def offset():
    try:
        return float((root / "clock").read_text())
    except (OSError, ValueError):
        return 0


resource.time = types.SimpleNamespace(time=wall_time, monotonic=lambda: real_time.monotonic() + offset(), sleep=real_time.sleep)


def publish():
    while True:
        try:
            sample = json.loads((root / "input.json").read_text())
            if sample.pop("_missing", False):
                (root / "monitor.json").unlink(missing_ok=True)
            elif sample.pop("_malformed", False):
                (root / "monitor.json").write_text("{")
            else:
                sample.setdefault("bootSessionUUID", resource.boot_id())
                sample.setdefault("timestamp", wall_time())
                sample.setdefault("uptimeSeconds", resource.uptime())
                sample.setdefault("sequence", int(real_time.monotonic() * 100))
                target = root / "monitor.tmp"
                target.write_text(json.dumps(sample))
                os.replace(target, root / "monitor.json")
        except (OSError, ValueError):
            pass
        real_time.sleep(0.05)


threading.Thread(target=publish, daemon=True).start()
name, config, digest = resource.load_config(str(root / "config.json"))
resource.serve(config, digest)

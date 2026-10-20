#!/usr/bin/env python3
"""Fixture only: fresh synthetic dotfiles monitor and controllable policy clock.

The production owner and every real client/socket/process path remain intact.
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


def offset():
    try:
        return float((root / "clock").read_text())
    except (OSError, ValueError):
        return 0


resource.time = types.SimpleNamespace(time=real_time.time, monotonic=lambda: real_time.monotonic() + offset(), sleep=real_time.sleep)


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
                sample.setdefault("timestamp", real_time.time())
                sample.setdefault("uptimeSeconds", resource.uptime())
                sample.setdefault("sequence", int(real_time.time() * 100))
                target = root / "monitor.tmp"
                target.write_text(json.dumps(sample))
                os.replace(target, root / "monitor.json")
        except (OSError, ValueError):
            pass
        real_time.sleep(0.05)


threading.Thread(target=publish, daemon=True).start()
name, config, digest = resource.load_config(str(root / "config.json"))
resource.serve(config, digest)

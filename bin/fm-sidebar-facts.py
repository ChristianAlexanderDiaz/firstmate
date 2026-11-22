#!/usr/bin/env python3
"""Read optional machine/service facts for a proven local pane shell.

Usage: fm-sidebar-facts.py SHELL_PID TASK [RESOURCE_JSON]
Print machine<TAB>detail or service<TAB>detail, or nothing when unverified.
Only live descendants of the exact pane shell can own either fact. A matching
task name alone is insufficient across homes. No processes are started/stopped.
"""
import json
import subprocess
import sys


def descendants(shell):
    rows = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid="], text=True, timeout=2
    )
    parents = dict(tuple(map(int, row.split())) for row in rows.splitlines())
    if shell not in parents:
        return set()
    owned = {shell}
    while True:
        added = {pid for pid, parent in parents.items() if parent in owned}
        if added <= owned:
            return owned - {shell}
        owned |= added


def facts(shell, task, resource):
    owned = descendants(shell)
    if not owned:
        return
    if resource:
        with open(resource, encoding="utf-8") as stream:
            budget = json.load(stream)
        for row in budget.get("queue", []):
            if row.get("task") != task or row.get("controller", {}).get("pid") not in owned:
                continue
            elapsed = row.get("waitedSeconds")
            if type(elapsed) is not int or elapsed < 0:
                continue
            reason = "heavy slot" if budget.get("reason") == "ready" else "memory/host guard"
            print(f"machine\t{reason} {elapsed // 60}m {elapsed % 60}s")
            return
    # Kernel listener ownership, not process names or a server-looking title.
    try:
        output = subprocess.run(
            ["lsof", "-nP", "-a", "-p", ",".join(map(str, sorted(owned))),
             "-iTCP", "-sTCP:LISTEN", "-Fp"],
            capture_output=True, text=True, timeout=2, check=False,
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return
    listeners = {int(line[1:]) for line in output.splitlines()
                 if line.startswith("p") and line[1:].isdigit()}
    if listeners & owned:
        print("service\tlistening TCP service")


if __name__ == "__main__":
    try:
        facts(int(sys.argv[1]), sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "")
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        pass  # Optional unreadable evidence must never invent a status.

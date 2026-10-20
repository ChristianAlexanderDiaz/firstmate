#!/usr/bin/env python3
"""Per-user deterministic admission owner; no model, daemon or backend lifecycle calls.

Wire/configuration owner: --help and the parser below. Snapshots use atomic
replacement; transitions append durably. The lifetime flock is never removed.
Clients cannot grant leases.
"""

import argparse
import collections
import ctypes
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import select
import shlex
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
import uuid

CLASSES = {"test": 1024, "build": 3072, "browser": 2048, "graph": 512,
           "exclusive": 4096, "worker": 512}
HERE = Path(__file__).resolve().parent
BOOT = None


class Refusal(Exception):
    pass


def boot_id():
    global BOOT
    if BOOT is None:
        if sys.platform == "darwin":
            BOOT = subprocess.check_output(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"], text=True).strip()
        else:
            BOOT = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    return BOOT


def uptime():
    if sys.platform == "darwin":
        # Matches Foundation systemUptime, including the monitor's sleep basis.
        # CLOCK_UPTIME_RAW (8) is mach_absolute_time, like systemUptime.
        class Timespec(ctypes.Structure):
            _fields_ = [("seconds", ctypes.c_long), ("nanos", ctypes.c_long)]
        ts = Timespec()
        if ctypes.CDLL(None).clock_gettime(8, ctypes.byref(ts)) != 0:
            raise Refusal("cannot read host uptime")
        return ts.seconds + ts.nanos / 1e9
    return float(Path("/proc/uptime").read_text().split()[0])


def process_table():
    """Kernel-derived start identity plus pgrp; zombies do not retain a slot."""
    rows = {}
    if sys.platform != "darwin":
        for directory in Path("/proc").iterdir():
            if not directory.name.isdigit():
                continue
            try:
                if directory.stat().st_uid != os.getuid():
                    continue
                raw = (directory / "stat").read_text()
                fields = raw[raw.rfind(")") + 2:].split()
                if fields[0] == "Z":
                    continue
                rows[int(directory.name)] = {"start": fields[19], "ppid": int(fields[1]),
                    "pgid": int(fields[2]), "rssKiB": int(fields[21]) * os.sysconf("SC_PAGE_SIZE") // 1024,
                    "cpuTicks": int(fields[11]) + int(fields[12])}
            except (OSError, ValueError, IndexError):
                continue
        return rows
    # proc_pidinfo(PROC_PIDTBSDINFO) supplies microsecond start times on macOS;
    # ps lstart only has second resolution and is insufficient for PID reuse.
    class BSDInfo(ctypes.Structure):
        _fields_ = [("flags", ctypes.c_uint32), ("status", ctypes.c_uint32),
            ("xstatus", ctypes.c_uint32), ("pid", ctypes.c_uint32),
            ("ppid", ctypes.c_uint32), ("uid", ctypes.c_uint32),
            ("gid", ctypes.c_uint32), ("ruid", ctypes.c_uint32),
            ("rgid", ctypes.c_uint32), ("svuid", ctypes.c_uint32),
            ("svgid", ctypes.c_uint32), ("rfu", ctypes.c_uint32),
            ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32),
            ("nfiles", ctypes.c_uint32), ("pgid", ctypes.c_uint32),
            ("pjobc", ctypes.c_uint32), ("tdev", ctypes.c_uint32),
            ("tpgid", ctypes.c_uint32), ("nice", ctypes.c_int32),
            ("start_sec", ctypes.c_uint64), ("start_usec", ctypes.c_uint64)]
    lib = ctypes.CDLL("/usr/lib/libproc.dylib")
    output = subprocess.check_output(["/bin/ps", "-axo", "pid=,rss=,time="], text=True)
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        pid = int(parts[0])
        info = BSDInfo()
        if lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
            continue
        if info.uid != os.getuid() or info.status == 5:
            continue
        rows[pid] = {"start": f"{info.start_sec}.{info.start_usec:06d}",
                     "ppid": info.ppid, "pgid": info.pgid, "rssKiB": int(parts[1]),
                     "cpuTime": parts[2] if len(parts) > 2 else ""}
    return rows


def identity(pid, table=None):
    row = (table if table is not None else process_table()).get(pid)
    if row is None:
        raise Refusal(f"process {pid} is not live")
    return {"boot": boot_id(), "pid": pid, "start": row["start"]}


def matches(owner, table):
    return (owner.get("boot") == boot_id() and owner.get("pid") in table and
            table[owner["pid"]]["start"] == owner.get("start"))


def group_exists(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def private_dir(path):
    path = Path(path)
    if not path.is_absolute():
        raise Refusal("state and socket directories must be absolute")
    # Reject links at every existing component; do not tighten unrelated parents.
    for part in [path, *path.parents]:
        if part.is_symlink():
            raise Refusal(f"symlink in private path: {part}")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    mode = path.stat()
    if mode.st_uid != os.getuid() or stat.S_IMODE(mode.st_mode) & 0o077:
        raise Refusal(f"directory must be owned by this user with mode 0700: {path}")
    return path


def atomic_json(path, value):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix=".resource-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, separators=(",", ":"), allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load_config(name):
    name = name or os.environ.get("FM_RESOURCE_CONFIG") or str(Path.home() / ".config/firstmate/host-budget.json")
    config = json.loads(Path(name).read_text())
    if not isinstance(config, dict):
        raise Refusal("host budget policy must be a JSON object")
    if config.get("schemaVersion") != 1 or config.get("maxHeavyJobs", 1) != 1:
        raise Refusal("only schemaVersion 1 and the uncalibrated one-heavy-job profile are supported")
    for key in ("stateDirectory", "socketPath", "monitorPath"):
        if not isinstance(config.get(key), str) or not Path(config[key]).is_absolute():
            raise Refusal(f"configuration requires absolute {key}")
    if len(config["socketPath"].encode()) > 100:
        raise Refusal("Unix socket path exceeds portable 100-byte limit")
    for key, default, low, high in (("memoryMiB", 10240, 4096, 1048576),
            ("maxResidentWorkers", 12, 1, 128), ("recoverySeconds", 120, 120, 3600),
            ("graceSeconds", 5, 1, 60)):
        value = config.setdefault(key, default)
        if type(value) is not int or not low <= value <= high:
            raise Refusal(f"invalid {key}")
    config["maxHeavyJobs"] = 1
    digest = hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()
    return str(Path(name).resolve()), config, digest


def peer_uid(connection):
    if sys.platform == "darwin":
        uid, gid = ctypes.c_uint(), ctypes.c_uint()
        if ctypes.CDLL(None).getpeereid(connection.fileno(), ctypes.byref(uid), ctypes.byref(gid)):
            raise Refusal("cannot authenticate socket peer")
        return uid.value
    return struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]


class Budget:
    def __init__(self, config, digest):
        self.config, self.digest = config, digest
        self.root = private_dir(config["stateDirectory"])
        self.path = self.root / "ledger.json"
        if (self.root / "owner.lock").is_symlink() or self.path.is_symlink():
            raise Refusal("symlink in recovery ledger/lock")
        self.lock = open(self.root / "owner.lock", "a+")
        os.chmod(self.root / "owner.lock", 0o600)
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise Refusal("a per-user budget owner already holds the ledger") from error
        if self.path.exists():
            self.data = json.loads(self.path.read_text())
            if self.data.get("schemaVersion") != 1:
                raise Refusal("unknown recovery ledger schema; preserve it for inspection")
            if self.data.get("configDigest") != digest:
                raise Refusal("policy changed; reconcile the existing ledger before changing configuration")
        else:
            self.data = {"schemaVersion": 1, "configDigest": digest, "leases": {},
                         "queue": [], "emergency": None, "events": []}
        self.healthy_since = None
        self.source = None
        self.monitor_id = None
        self.sample_id = None
        self.last_uptime = None
        self.last_wall = None
        self.last_sequence = None
        self.swap = collections.deque()
        self.swap_bad = 0
        self.reason = "starting: reconciliation and recovery hysteresis required"
        self.telemetry = None
        self.metrics = collections.deque(maxlen=900)
        metrics_file = self.root / "metrics.json"
        if metrics_file.exists():
            for sample in json.loads(metrics_file.read_text()):
                if time.time() - 1800 <= sample["timestamp"] <= time.time() + 1:
                    self.metrics.append(sample)
        self.exception = None
        self.table = process_table()
        self.reconcile()
        self.save()

    def save(self):
        atomic_json(self.path, self.data)

    def event(self, reason):
        if reason != self.exception:
            self.exception = reason
            self.data["events"].append({"timestamp": time.time(), "reason": reason})
            self.data["events"] = self.data["events"][-100:]
            record = json.dumps({"event": "host-budget-transition", "reason": reason})
            with open(self.root / "transitions.jsonl", "a") as stream:
                stream.write(record + "\n")
                stream.flush()
                os.fsync(stream.fileno())
            print(record, flush=True)

    def cleanup_browser(self, token, lease):
        directory = self.root / "browser-jobs" / token
        if not directory.exists():
            return
        private_dir(directory.parent)
        private_dir(directory)
        manifest = json.loads((directory / "manifest.json").read_text())
        if (manifest.get("lease") != token or manifest.get("boot") != lease["controller"]["boot"] or
                manifest.get("profile") != str(directory / "profile")):
            raise Refusal("browser cleanup ownership mismatch")
        shutil.rmtree(directory)

    def reconcile(self):
        self.table = process_table()
        self.data["queue"] = [r for r in self.data["queue"] if matches(r["controller"], self.table)]
        for token, lease in list(self.data["leases"].items()):
            group = lease.get("group")
            if lease["controller"].get("boot") != boot_id():
                self.cleanup_browser(token, lease)
                del self.data["leases"][token]
                continue
            if group:
                pgid = group["pid"]
                # Keep known descendants, adding group members only while a
                # verified member anchors that group. Unknown groups quarantine.
                known = [member for member in lease.get("members", [group]) if matches(member, self.table)]
                members = [pid for pid, row in self.table.items() if row["pgid"] == pgid]
                if known:
                    lease["members"] = [identity(pid, self.table) for pid in members]
                    lease["quarantined"] = False
                elif members or group_exists(pgid):
                    lease["quarantined"] = True
                else:
                    self.cleanup_browser(token, lease)
                    del self.data["leases"][token]
            elif not matches(lease["controller"], self.table):
                self.cleanup_browser(token, lease)
                del self.data["leases"][token]

    def policy(self):
        now, mono = time.time(), time.monotonic()
        cancel = False
        try:
            sample = json.loads(Path(self.config["monitorPath"]).read_text())
            if sample["schemaVersion"] != 1 or sample["lifecycle"] != "running":
                raise Refusal("monitor schema or lifecycle is unavailable")
            if sample["bootSessionUUID"] != boot_id():
                raise Refusal("old-boot monitor sample")
            age = now - float(sample["timestamp"])
            host_uptime = uptime()
            uptime_age = host_uptime - float(sample["uptimeSeconds"])
            if not math.isfinite(age) or not math.isfinite(uptime_age) or not -1 <= age <= 10 or not -1 <= uptime_age <= 10:
                raise Refusal("stale or future monitor sample")
            thermal, pressure = sample["thermalState"], sample["memory"]["pressure"]
            cancel = thermal == "critical" or pressure == "critical"
            if sample.get("thermalEmergencySleep") is True or thermal == "critical":
                self.data["emergency"] = self.data["emergency"] or {"timestamp": now, "cause": "critical thermal signal / emergency sleep"}
            if sample["unavailable"]:
                raise Refusal("monitor has unavailable readings: " + ",".join(sample["unavailable"]))
            monitor_id = sample["instanceUUID"]
            sequence = sample["sequence"]
            source = (sample["power"]["source"], sample["power"]["adapterWatts"])
            if monitor_id != self.monitor_id or source != self.source or (self.last_wall is not None and (now - self.last_wall > 10 or abs((now - self.last_wall) - (host_uptime - self.last_uptime)) > 1)):
                self.healthy_since = None
                self.swap.clear()
                self.swap_bad = 0
            if monitor_id == self.monitor_id and self.last_sequence is not None and sequence < self.last_sequence:
                raise Refusal("monitor sequence regressed")
            self.monitor_id, self.source, self.last_sequence = monitor_id, source, sequence
            self.last_uptime, self.last_wall = host_uptime, now
            self.telemetry = sample
            power = sample["power"]
            battery = power["batteryPercent"]
            if type(battery) not in (int, float) or not 0 <= battery <= 100:
                raise Refusal("battery reading is unavailable")
            if power["source"] not in ("ac", "battery", "ups") or type(power["isCharging"]) is not bool:
                raise Refusal("power source is unavailable")
            if power["source"] == "ac" and (type(power["adapterWatts"]) not in (int, float) or power["adapterWatts"] <= 0):
                raise Refusal("negotiated AC supply is unavailable")
            if thermal == "critical" or pressure == "critical" or battery < 15:
                cancel = True
            if thermal not in ("nominal", "fair") or pressure != "normal":
                raise Refusal(f"thermal={thermal} memory={pressure}")
            if sample["lidClosed"] is not False:
                raise Refusal("portable lid is closed or unknown")
            if battery < 30:
                raise Refusal("battery below 30% admission reserve")
            if sample.get("performanceWarning", False) or sample.get("thermalWarning", False):
                raise Refusal("secondary OS performance/thermal warning")
            swap = sample["memory"]["swapUsedBytes"]
            if type(swap) not in (int, float) or not math.isfinite(swap) or swap < 0:
                raise Refusal("swap reading is unavailable")
            sample_id = (monitor_id, sequence)
            if sample_id != self.sample_id:
                self.swap.append((mono, swap, battery))
                while len(self.swap) > 1 and mono - self.swap[1][0] >= 60:
                    self.swap.popleft()
                if self.swap and mono - self.swap[0][0] >= 60:
                    growth = swap - self.swap[0][1]
                    self.swap_bad = self.swap_bad + 1 if growth >= 256 * 1024 * 1024 else 0
                self.sample_id = sample_id
            if self.swap_bad >= 2:
                raise Refusal("sustained swap growth >=256 MiB/60s")
            if power["source"] == "ac" and self.swap and mono - self.swap[0][0] >= 60 and battery < self.swap[0][2]:
                raise Refusal("sustained AC battery discharge")
            if self.data["emergency"]:
                raise Refusal("persistent emergency latch requires inspected evidence and explicit clear")
            # Fair allows one but never satisfies post-warning nominal recovery.
            if thermal == "nominal":
                if self.healthy_since is None:
                    self.healthy_since = mono
            elif self.healthy_since is None or self.reason != "ready":
                raise Refusal("nominal thermal recovery required")
            if mono - self.healthy_since < self.config["recoverySeconds"]:
                return "recovery hysteresis: 120s stable nominal/normal/source required", cancel
            return "ready", cancel
        except (OSError, ValueError, KeyError, TypeError, Refusal) as error:
            self.healthy_since = None
            return str(error), cancel

    def tick(self):
        self.reconcile()
        self.reason, cancel = self.policy()
        if cancel:
            for lease in self.data["leases"].values():
                if lease["class"] != "worker":
                    lease.setdefault("cancelAt", time.monotonic())
        for lease in self.data["leases"].values():
            if "cancelAt" in lease:
                self.signal_lease(lease, signal.SIGKILL if time.monotonic() - lease["cancelAt"] >= self.config["graceSeconds"] else signal.SIGTERM)
        self.admit()
        quarantined = sum(bool(l.get("quarantined")) for l in self.data["leases"].values())
        self.event(self.reason + (f"; {quarantined} unverified process group(s) quarantined" if quarantined else ""))
        usage = [{"lease": token, "class": lease["class"], "rssKiB": sum(
            self.table[m["pid"]]["rssKiB"] for m in lease.get("members", []) if matches(m, self.table)),
            "cpu": [self.table[m["pid"]].get("cpuTime", self.table[m["pid"]].get("cpuTicks"))
                    for m in lease.get("members", []) if matches(m, self.table)]}
            for token, lease in self.data["leases"].items()]
        self.metrics.append({"timestamp": time.time(), "reason": self.reason,
            "power": self.telemetry.get("power") if self.telemetry else None,
            "thermal": self.telemetry.get("thermalState") if self.telemetry else None,
            "memory": self.telemetry.get("memory") if self.telemetry else None, "jobs": usage})
        atomic_json(self.root / "metrics.json", list(self.metrics))
        self.save()

    def signal_lease(self, lease, sig):
        # Never signal a reused PID or an unverified group. Signal individual
        # verified members so an unrelated process cannot be collateral damage.
        if lease.get("quarantined"):
            return
        for member in lease.get("members", []):
            table = process_table()
            if matches(member, table):
                try:
                    os.kill(member["pid"], sig)
                except ProcessLookupError:
                    pass

    def admit(self):
        leases = self.data["leases"]
        # FIFO within heavy work; a waiting large reservation blocks smaller
        # work from jumping ahead. Resident cloud CLIs have a separate cap.
        heavy_waiting = False
        for request in list(self.data["queue"]):
            worker = request["class"] == "worker"
            if not worker and (heavy_waiting or self.reason != "ready"):
                heavy_waiting = True
                continue
            active_heavy = sum(l["class"] != "worker" for l in leases.values())
            resident = sum(l["class"] == "worker" for l in leases.values())
            memory = sum(l["memoryMiB"] for l in leases.values())
            reserved = max((q["memoryMiB"] for q in self.data["queue"] if q["class"] != "worker"), default=0) if worker else 0
            if (worker and resident >= self.config["maxResidentWorkers"]) or (not worker and active_heavy >= 1) or memory + request["memoryMiB"] + reserved > self.config["memoryMiB"]:
                if not worker:
                    heavy_waiting = True
                continue
            # Resident CLIs need their own admission check even without compute;
            # unknown or warning memory cannot admit more resident CLI memory.
            if worker and (self.telemetry is None or self.telemetry["memory"]["pressure"] != "normal" or self.reason not in ("ready", "battery below 30% admission reserve") and not self.reason.startswith("recovery hysteresis")):
                continue
            lease = dict(request, acquired=time.monotonic(), heartbeat=time.monotonic())
            leases[request["token"]] = lease
            self.data["queue"].remove(request)
            self.save()  # Reservation reaches durable storage before response.

    def handle(self, request):
        if not isinstance(request, dict):
            raise Refusal("request must be a JSON object")
        if request.get("configDigest") != self.digest:
            raise Refusal("client policy differs from the single running owner")
        op = request.get("op")
        self.reconcile()
        if op in ("acquire", "inherit"):
            self.reason, _ = self.policy()
            quarantined = sum(bool(l.get("quarantined")) for l in self.data["leases"].values())
            self.event(self.reason + (f"; {quarantined} unverified process group(s) quarantined" if quarantined else ""))
        if op == "status":
            return {"ok": True, "reason": self.reason, "availableHeavySlots": max(0, 1 - sum(l["class"] != "worker" for l in self.data["leases"].values())) if self.reason == "ready" else 0,
                "leases": self.data["leases"], "queue": self.data["queue"],
                "telemetry": self.telemetry, "events": self.data["events"], "emergency": self.data["emergency"]}
        if op == "emergency":
            self.data["emergency"] = {"timestamp": time.time(), "cause": request["evidence"]}
            self.save()
            self.tick()
            return {"ok": True}
        if op == "clear-emergency":
            if len(request.get("evidence", "").strip()) < 12:
                raise Refusal("clearing requires an inspection note of at least 12 characters")
            self.data["emergency"] = None
            self.healthy_since = None
            self.event("emergency cleared after inspection: " + request["evidence"])
            self.save()
            return {"ok": True}
        token = request.get("token")
        if not isinstance(token, str) or len(token) != 32 or any(c not in "0123456789abcdef" for c in token):
            raise Refusal("invalid request nonce")
        if op == "acquire":
            controller = request["controller"]
            if not matches(controller, self.table):
                raise Refusal("controller boot/start identity does not match")
            existing = self.data["leases"].get(token) or next((q for q in self.data["queue"] if q["token"] == token), None)
            if existing is None:
                kind = request["class"]
                memory = request["memoryMiB"]
                if kind not in CLASSES or type(memory) is not int or not CLASSES[kind] <= memory <= self.config["memoryMiB"]:
                    raise Refusal("invalid or oversized reservation")
                self.data["queue"].append({"token": token, "controller": controller,
                    "class": kind, "memoryMiB": memory, "task": request.get("task", "ad-hoc"),
                    "queued": time.monotonic()})
            elif existing["controller"] != controller:
                raise Refusal("nonce belongs to another controller")
            self.admit()
            self.save()
            return {"ok": True, "state": "leased" if token in self.data["leases"] else "queued", "reason": self.reason}
        lease = self.data["leases"].get(token)
        if op == "cancel-queued":
            self.data["queue"] = [q for q in self.data["queue"] if q["token"] != token]
        elif lease is None:
            raise Refusal("lease is no longer active")
        elif op == "bind":
            group = request["group"]
            if (lease.get("group") or not matches(group, self.table) or
                    not matches(lease["controller"], self.table) or
                    self.table[group["pid"]]["pgid"] != group["pid"] or
                    self.table[group["pid"]]["ppid"] != lease["controller"]["pid"]):
                raise Refusal("group is already bound or is not a fresh process-group leader")
            lease["group"], lease["members"] = group, [group]
        elif op == "heartbeat":
            lease["heartbeat"] = time.monotonic()
        elif op == "cancel":
            lease.setdefault("cancelAt", time.monotonic())
            self.signal_lease(lease, signal.SIGTERM)
        elif op == "release":
            if lease.get("group"):
                raise Refusal("owned group still exists; reservation retained")
            self.cleanup_browser(token, lease)
            del self.data["leases"][token]
        elif op == "inherit":
            if lease["class"] == "worker" or "cancelAt" in lease:
                raise Refusal("resident/cancelled leases cannot cover local compute")
            owner = request["controller"]
            if not matches(owner, self.table) or self.table[owner["pid"]]["pgid"] != lease.get("group", {}).get("pid"):
                raise Refusal("inherited lease caller is outside its owned process group")
            if request["memoryMiB"] > lease["memoryMiB"]:
                # Atomic in-place upgrade, never acquire a second slot while
                # holding one. Fail rather than wait if it cannot fit.
                others = sum(l["memoryMiB"] for k, l in self.data["leases"].items() if k != token)
                if others + request["memoryMiB"] > self.config["memoryMiB"]:
                    raise Refusal("nested lease upgrade cannot fit; declare composite reservation at outer stage")
                lease["memoryMiB"] = request["memoryMiB"]
        else:
            raise Refusal("unknown request operation")
        self.save()
        return {"ok": True}


def serve(config, digest):
    budget = Budget(config, digest)
    path = Path(config["socketPath"])
    private_dir(path.parent)
    if path.exists() or path.is_symlink():
        if not stat.S_ISSOCK(path.lstat().st_mode) or path.lstat().st_uid != os.getuid():
            raise Refusal("refusing to replace a non-owned socket path")
        probe = socket.socket(socket.AF_UNIX)
        try:
            probe.connect(str(path))
        except ConnectionRefusedError:
            path.unlink()  # Only while holding the ledger's lifetime flock.
        else:
            raise Refusal("another live socket owner exists")
        finally:
            probe.close()
    server = socket.socket(socket.AF_UNIX)
    server.bind(str(path))
    os.chmod(path, 0o600)
    server.listen(64)
    stopping = False

    def stop(_sig, _frame):
        nonlocal stopping
        stopping = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    next_tick = 0
    try:
        while not stopping:
            if time.monotonic() >= next_tick:
                budget.tick()
                next_tick = time.monotonic() + 2
            if not select.select([server], [], [], 0.2)[0]:
                continue
            connection, _ = server.accept()
            with connection:
                connection.settimeout(1)
                try:
                    if peer_uid(connection) != os.getuid():
                        raise Refusal("socket peer is not this user")
                    raw = b""
                    while not raw.endswith(b"\n") and len(raw) <= 65536:
                        chunk = connection.recv(65536 - len(raw) + 1)
                        if not chunk:
                            break
                        raw += chunk
                    if len(raw) > 65536:
                        raise Refusal("request too large")
                    result = budget.handle(json.loads(raw))
                except (Refusal, ValueError, KeyError, TypeError, OSError) as error:
                    result = {"ok": False, "error": str(error)}
                try:
                    connection.sendall(json.dumps(result).encode() + b"\n")
                except OSError:
                    pass
    finally:
        # Stopping admission never frees a live reservation or restarts work.
        budget.save()
        server.close()
        path.unlink(missing_ok=True)


def rpc(config, digest, **request):
    path = Path(config["socketPath"])
    if path.is_symlink() or not path.exists() or path.stat().st_uid != os.getuid():
        raise Refusal("budget service socket missing or unsafe; compute is held")
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5)
        connection.connect(str(path))
        if peer_uid(connection) != os.getuid():
            raise Refusal("budget owner is not this user")
        connection.sendall(json.dumps(dict(request, configDigest=digest)).encode() + b"\n")
        raw = b""
        while not raw.endswith(b"\n"):
            part = connection.recv(65536)
            if not part or len(raw) > 4 * 1024 * 1024:
                break
            raw += part
    result = json.loads(raw)
    if not result.get("ok"):
        raise Refusal(result.get("error", "invalid budget response"))
    return result


def validate_manifest(path, command, task):
    value = json.loads(Path(path).read_text())
    cwd = str(Path.cwd().resolve())
    if value.get("schemaVersion") != 1 or value.get("worktree") != cwd or not Path(cwd).is_dir():
        raise Refusal("recovery manifest directory mismatch")
    if value.get("argv") != command or value.get("task") != task or value.get("task") != os.environ.get("FM_TASK_ID", value.get("task")):
        raise Refusal("recovery manifest task/argv mismatch")
    branch = subprocess.run(["git", "symbolic-ref", "--short", "-q", "HEAD"], text=True, capture_output=True).stdout.strip()
    if value.get("branch", "") != branch:
        raise Refusal("recovery manifest branch mismatch")
    if not branch and value.get("detachedHead") != subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip():
        raise Refusal("recovery manifest detached revision mismatch")
    for key, expected in value.get("accountEnvironment", {}).items():
        if key not in ("CLAUDE_CONFIG_DIR", "PI_CODING_AGENT_DIR", "CODEX_HOME", "OPENCODE_CONFIG_DIR"):
            raise Refusal("unsupported account configuration axis")
        if (os.environ.get(key) or None) != expected or expected is not None and (not expected or not Path(expected).is_dir()):
            raise Refusal(f"recovery manifest account/config mismatch: {key}")
    if not value.get("accountLabel") or not value.get("task"):
        raise Refusal("recovery manifest needs explicit task and account label")
    return value


def prepare(args, config_name):
    """Write task-owned launch material, never change a project or account."""
    directory = private_dir(args.directory)
    command = args.argv[1:] if args.argv and args.argv[0] == "--" else args.argv
    if not command:
        raise Refusal("prepare needs launch argv")
    cwd = str(Path(args.worktree).resolve(strict=True))
    branch = subprocess.run(["git", "-C", cwd, "symbolic-ref", "--short", "-q", "HEAD"], text=True, capture_output=True).stdout.strip()
    head = subprocess.check_output(["git", "-C", cwd, "rev-parse", "HEAD"], text=True).strip()
    account = {}
    for pair in args.account_env:
        key, separator, value = pair.partition("=")
        if not separator or key not in ("CLAUDE_CONFIG_DIR", "PI_CODING_AGENT_DIR", "CODEX_HOME", "OPENCODE_CONFIG_DIR") or value and not Path(value).is_dir():
            raise Refusal("account environment must name an existing explicit config directory")
        account[key] = str(Path(value).resolve()) if value else None
    manifest = {"schemaVersion": 1, "worktree": cwd, "branch": branch,
        "nonce": uuid.uuid4().hex, "detachedHead": head if not branch else None,
        "task": args.task, "accountLabel": args.account_label,
        "accountEnvironment": account, "argv": command}
    if not args.account_label or not args.task:
        raise Refusal("prepare requires explicit account label and task")
    atomic_json(directory / "manifest.json", manifest)
    shims = directory / "bin"
    private_dir(shims)
    tools = ("node", "npm", "npx", "pnpm", "yarn", "bun", "vitest", "playwright", "graphify",
             "make", "cmake", "ninja", "cargo", "go", "nix", "nix-build", "darwin-rebuild", "nixos-rebuild",
             "chrome-devtools-axi")
    for name in tools:
        executable = shutil.which(name)
        if executable:
            text = "#!/bin/sh\nexec " + " ".join(shlex.quote(v) for v in [sys.executable,
                str(Path(__file__).resolve()), "--config", config_name, "tool", "--name", name,
                "--executable", executable, "--"]) + ' "$@"\n'
            path = shims / name
            if path.exists() or path.is_symlink():
                raise Refusal("refusing to replace an existing task command adapter")
            path.write_text(text)
            path.chmod(0o700)
    print(str(directory / "manifest.json"))


def node_options(command):
    """Return option positions without consuming operands as options or files."""
    values = {"-r", "--require", "--import", "--loader", "--experimental-loader", "-C", "--conditions",
        "--env-file", "--env-file-if-exists", "--test-concurrency", "--test-reporter",
        "--test-reporter-destination", "--test-name-pattern", "--test-skip-pattern", "--test-timeout",
        "--test-shard", "--inspect-port", "--title", "--icu-data-dir", "--openssl-config",
        "--redirect-warnings", "--diagnostic-dir", "--report-directory", "--report-dir",
        "--report-filename", "--snapshot-blob", "--heap-prof-dir", "--heap-prof-name",
        "--heap-prof-interval", "--cpu-prof-dir", "--cpu-prof-name", "--cpu-prof-interval",
        "--trace-event-categories", "--trace-event-file-pattern", "--unhandled-rejections",
        "--experimental-default-type", "--experimental-specifier-resolution", "--input-type",
        "--experimental-policy", "--policy-integrity", "--max-old-space-size", "--max-semi-space-size"}
    indices = []
    index = 1
    while index < len(command):
        value = command[index]
        if (not value.startswith("-") or value in ("--", "-")
                or value.split("=", 1)[0] in ("--eval", "--print")
                or value.startswith(("-e", "-p"))):
            break
        indices.append(index)
        index += 2 if value in values else 1
    return indices


def tool_job(args, name, config, digest):
    argv = args.argv[1:] if args.argv and args.argv[0] == "--" else args.argv
    if args.name == "node" and not any(argv[index - 1] == "--test" for index in node_options([args.executable, *argv])):
        os.execv(args.executable, [args.executable, *argv])
    kind = "exclusive"
    if args.name == "graphify":
        kind = "graph"
    elif args.name in ("vitest", "node"):
        kind = "test"
    elif args.name in ("playwright", "chrome-devtools-axi"):
        kind = "browser"
    queries = {"npm": ("view", "info", "ls", "list", "outdated", "help"),
        "pnpm": ("view", "info", "ls", "list", "outdated", "help"),
        "yarn": ("info", "list", "outdated", "help")}
    if argv and (argv[0] in ("--help", "--version", "-h") or
            args.name == "graphify" and argv[0] in ("query", "stats") or
            argv[0] in queries.get(args.name, ()) or
            args.name in ("npm", "pnpm") and argv == ["version"]):
        os.execv(args.executable, [args.executable, *argv])
    args.argv = [args.executable, *argv]
    args.resource_class, args.memory_mib = kind, None
    args.manifest, args.wait_seconds = None, 0
    args.task = os.environ.get("FM_TASK_ID", "ad-hoc")
    return run_job(args, name, config, digest)


def package_test_runner(command):
    """Resolve simple package scripts without executing or changing the project."""
    name = Path(command[0]).name
    if name not in ("npm", "pnpm", "yarn") or len(command) < 2:
        return None
    directory = Path.cwd()
    selectors = []
    script = None
    running = False
    multiple = False
    directory_options = {"npm": ("--prefix",), "pnpm": ("--dir", "-C"), "yarn": ("--cwd",)}
    workspace_options = {"npm": ("--workspace", "-w"), "pnpm": ("--filter", "-F"), "yarn": ()}
    index = 1
    while index < len(command):
        token = command[index]
        if token == "--":
            break
        option, equals, operand = token.partition("=")
        if option in (*directory_options[name], *workspace_options[name]) or name == "yarn" and token == "workspace" and script is None:
            if not equals:
                index += 1
                if index >= len(command):
                    raise Refusal("package selection needs an operand")
                operand = command[index]
            if option in directory_options[name]:
                directory = Path.cwd() / operand
            else:
                selectors.append(operand)
        elif name == "npm" and option in ("--workspaces", "--include-workspace-root", "-ws"):
            multiple = True
        elif script is None and not token.startswith("-"):
            if not running and token in ("run", "run-script"):
                running = True
            elif running or token == "test":
                script = token
            else:
                return None
        if script is not None and name != "npm":
            break
        index += 1
    if script is None:
        return None
    if multiple:
        raise Refusal("package worker limits require a single selected package")
    package = next((parent / "package.json" for parent in (directory, *directory.parents)
        if (parent / "package.json").is_file()), None)
    if package is None:
        return None
    try:
        value = json.loads(package.read_text())
        if selectors:
            if len(selectors) != 1:
                raise Refusal("package worker limits require a single selected package")
            selector = selectors[0]
            patterns = value.get("workspaces", [])
            if isinstance(patterns, dict):
                patterns = patterns.get("packages", [])
            candidates = {path.parent for pattern in patterns for path in package.parent.glob(pattern + "/package.json")}
            selected_path = package.parent / selector
            matches = [path for path in candidates if selector == json.loads((path / "package.json").read_text()).get("name")
                or path.resolve() == selected_path.resolve()]
            if len(matches) != 1:
                raise Refusal("package worker limits cannot resolve a single workspace")
            value = json.loads((matches[0] / "package.json").read_text())
        text = value.get("scripts", {}).get(script, "")
        lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        argv = list(lexer)
    except (OSError, ValueError, AttributeError, TypeError):
        if selectors:
            raise Refusal("package worker limits cannot resolve a single workspace")
        return None
    mentions_runner = any(
        Path(token).name == "playwright" and argv[index + 1:index + 2] == ["test"]
        or Path(token).name == "node" and any(argv[index + offset] == "--test" for offset in node_options(argv[index:]))
        for index, token in enumerate(argv))
    if not mentions_runner:
        return "other"
    while argv and "=" in argv[0] and not argv[0].startswith("-"):
        argv.pop(0)
    if argv[:1] == ["npx"]:
        argv.pop(0)
    runner = Path(argv[0]).name if argv else ""
    simple = runner == "playwright" and argv[1:2] == ["test"] or runner == "node" and any(argv[index] == "--test" for index in node_options(argv))
    if not simple or "\n" in text or any(token and all(c in "();<>|&" for c in token) for token in argv) or "--" in argv:
        raise Refusal("package test script needs a simple runner command for worker limits")
    return runner


def caps(command, kind, portable):
    workers = 1 if portable else 2
    env = os.environ.copy()
    env.update({"GRAPHIFY_MAX_WORKERS": str(workers),
        "FM_RESOURCE_CPU_WORKERS": str(workers), "FM_RESOURCE_BROWSER_WORKERS": "1",
        "VITEST_MAX_WORKERS": str(workers), "VITEST_MAX_THREADS": str(workers),
        "VITEST_MAX_FORKS": str(workers), "VITEST_MIN_WORKERS": "1",
        "VITEST_MIN_THREADS": "1", "VITEST_MIN_FORKS": "1"})
    name = Path(command[0]).name
    result = command[:]
    package_runner = package_test_runner(command)
    if package_runner:
        if package_runner == "playwright":
            if name == "npm" and "--" not in result[2:]:
                result += ["--"]
            result += ["--workers=1"]
    elif name == "vitest":
        result += [f"--maxWorkers={workers}"]
    elif name == "playwright" and len(command) > 1 and command[1] == "test":
        result += ["--workers=1"]
    elif name in ("npx", "npm", "pnpm", "yarn", "bun") and "playwright" in result and "test" in result:
        result += ["--workers=1"]
    elif name in ("npx", "npm", "pnpm", "yarn", "bun") and "vitest" in result:
        result += [f"--maxWorkers={workers}"]
    elif name == "node":
        indices = node_options(command)
        test_index = next((index for index in indices if command[index] == "--test"), None)
        if test_index is not None:
            explicit = False
            for index in indices:
                value = result[index]
                if value.startswith("--test-concurrency="):
                    explicit = True
                    try:
                        if not 0 < int(value.split("=", 1)[1]) <= workers:
                            result[index] = f"--test-concurrency={workers}"
                    except ValueError:
                        pass
                elif value == "--test-concurrency" and index + 1 < len(result):
                    explicit = True
                    try:
                        if not 0 < int(result[index + 1]) <= workers:
                            result[index + 1] = str(workers)
                    except ValueError:
                        pass
            if not explicit:
                result.insert(test_index + 1, f"--test-concurrency={workers}")
    elif name == "nix-build" or name in ("nix", "darwin-rebuild", "nixos-rebuild") and any(v in command for v in ("build", "switch", "test")):
        result += ["--max-jobs", "1", "--cores", "2"]
    return result, env


def browser_environment(config, token, env):
    directory = private_dir(private_dir(Path(config["stateDirectory"]) / "browser-jobs") / token)
    profile = private_dir(directory / "profile")
    with socket.socket() as port_probe, socket.socket() as bridge_probe:
        port_probe.bind(("127.0.0.1", 0))
        server_port = port_probe.getsockname()[1]
        bridge_probe.bind(("127.0.0.1", 0))
        bridge_port = bridge_probe.getsockname()[1]
    session = "fm-resource-" + token
    revision = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    atomic_json(directory / "manifest.json", {"schemaVersion": 1, "lease": token,
        "boot": boot_id(), "worktree": str(Path.cwd().resolve()), "commit": revision,
        "profile": str(profile), "serverPort": server_port, "bridgePort": bridge_port,
        "session": session, "reuseServer": False})
    env.update(FM_RESOURCE_BROWSER_PROFILE=str(profile), FM_RESOURCE_SERVER_PORT=str(server_port),
        FM_RESOURCE_BROWSER_MANIFEST=str(directory / "manifest.json"), FM_RESOURCE_REUSE_SERVER="0",
        CHROME_DEVTOOLS_AXI_SESSION=session, CHROME_DEVTOOLS_AXI_PORT=str(bridge_port),
        CHROME_DEVTOOLS_AXI_USER_DATA_DIR=str(profile), CHROME_DEVTOOLS_AXI_AUTO_CONNECT="0")
    env.pop("CHROME_DEVTOOLS_AXI_BROWSER_URL", None)
    env.pop("CHROME_DEVTOOLS_AXI_WS_HEADERS", None)


def run_job(args, config_name, config, digest):
    command = args.argv
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        raise Refusal("run requires an argv after --")
    inherited = os.environ.get("FM_RESOURCE_LEASE")
    if (args.resource_class == "browser" and
            (Path(command[0]).name == "chrome-devtools-axi" or getattr(args, "name", None) == "chrome-devtools-axi") and
            not (inherited and os.environ.get("FM_RESOURCE_BROWSER_PROFILE"))):
        raise Refusal("lease a composite browser/server script, not a short persistent-browser CLI request")
    if args.manifest:
        validate_manifest(args.manifest, command, args.task)
    kind = args.resource_class
    memory = args.memory_mib or CLASSES[kind]
    if memory < CLASSES[kind]:
        raise Refusal("reservation cannot be smaller than its workload class")
    owner = identity(os.getpid())
    if inherited and kind != "worker":
        rpc(config, digest, op="inherit", token=inherited, controller=owner, memoryMiB=memory)
        command, env = caps(command, kind, os.environ.get("FM_RESOURCE_PORTABLE") == "1")
        if kind == "browser" and not env.get("FM_RESOURCE_BROWSER_PROFILE"):
            browser_environment(config, inherited, env)
        os.execvpe(command[0], command, env)
    token = uuid.uuid4().hex
    child = None
    released = False
    interrupted = False
    terminal = sys.stdin.fileno() if sys.stdin.isatty() else None
    foreground = os.tcgetpgrp(terminal) if terminal is not None else None
    if foreground != os.getpgrp():
        terminal = None

    def interrupt(_sig, _frame):
        nonlocal interrupted
        interrupted = True
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    deadline = time.monotonic() + args.wait_seconds if args.wait_seconds else None
    try:
        while True:
            if interrupted or deadline and time.monotonic() >= deadline:
                rpc(config, digest, op="cancel-queued", token=token)
                return 130 if interrupted else 75
            result = rpc(config, digest, op="acquire", token=token, controller=owner,
                **{"class": kind, "memoryMiB": memory, "task": args.task})
            if result["state"] == "leased":
                break
            time.sleep(0.2)
        state = rpc(config, digest, op="status")
        portable = state["telemetry"]["power"]["source"] != "ac" or state["telemetry"]["power"]["adapterWatts"] < 96
        command, env = caps(command, kind, portable)
        env.update(FM_RESOURCE_CONFIG=config_name, FM_RESOURCE_PORTABLE="1" if portable else "0")
        if kind == "browser":
            browser_environment(config, token, env)
        if kind != "worker":
            env["FM_RESOURCE_LEASE"] = token
        else:
            env.pop("FM_RESOURCE_LEASE", None)
        # A child cannot execute user code until its process group identity is
        # durable. SIGKILL in this window closes the pipe and the barrier exits.
        read_fd, write_fd = os.pipe()
        try:
            child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "_barrier", str(read_fd), *command],
                pass_fds=(read_fd,), start_new_session=terminal is None,
                preexec_fn=os.setpgrp if terminal is not None else None, env=env)
            os.close(read_fd)
            read_fd = -1
            group = identity(child.pid)
            rpc(config, digest, op="bind", token=token, group=group)
            if terminal is not None:
                signal.signal(signal.SIGTTOU, signal.SIG_IGN)
                os.tcsetpgrp(terminal, child.pid)
                signal.signal(signal.SIGINT, signal.SIG_IGN)
            os.write(write_fd, b"go\n")
        finally:
            os.close(write_fd)
            if read_fd != -1:
                os.close(read_fd)
        while True:
            child.poll()  # Reap an exited leader while its children drain.
            if interrupted:
                rpc(config, digest, op="cancel", token=token)
            try:
                rpc(config, digest, op="heartbeat", token=token)
            except Refusal as error:
                if "no longer active" in str(error):
                    released = True
                    break
                raise
            time.sleep(2)
        returncode = child.wait()
        return 128 - returncode if returncode < 0 else returncode
    finally:
        if terminal is not None and child is not None:
            signal.signal(signal.SIGTTOU, signal.SIG_IGN)
            if os.tcgetpgrp(terminal) == child.pid:
                os.tcsetpgrp(terminal, foreground)
        if not released:
            try:
                if child:
                    rpc(config, digest, op="cancel", token=token)
                else:
                    rpc(config, digest, op="cancel-queued", token=token)
                    rpc(config, digest, op="release", token=token)
            except (OSError, Refusal, ValueError):
                # A stopped owner retains the ledger; no unverified cleanup.
                pass


def check_directory(path):
    directory = Path(path)
    if not directory.is_absolute() or not directory.is_dir() or directory.is_symlink():
        raise Refusal("check state directory must be an existing absolute non-symlink directory")
    return directory


def register_check(args, config_name):
    directory = check_directory(args.directory)
    check = directory / "host-budget.check.sh"
    command = [sys.executable, str(Path(__file__).resolve()), "--config", config_name,
        "transitions", "--cursor", str(directory / ".host-budget-cursor")]
    with os.fdopen(os.open(check, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o700), "w") as stream:
        stream.write("#!/bin/sh\nexec " + shlex.join(command) + "\n")
    check.chmod(0o700)
    subprocess.run(["/bin/bash", str(HERE / "fm-check-register.sh"), "host-budget"],
        env=dict(os.environ, FM_STATE_OVERRIDE=str(directory)), check=True)


def transitions(args, config):
    cursor = Path(args.cursor)
    check_directory(cursor.parent)
    with os.fdopen(os.open(str(cursor) + ".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        position = json.loads(cursor.read_text()) if cursor.exists() else 0
        path = Path(config["stateDirectory"]) / "transitions.jsonl"
        with path.open("rb") as stream:
            stream.seek(position)
            for line in stream:
                if not line.endswith(b"\n"):
                    break
                record = json.loads(line)
                print(record["event"] + ": " + record["reason"], flush=True)
                position += len(line)
        atomic_json(cursor, position)


def parser():
    p = argparse.ArgumentParser(description="One per-user atomic host budget. No auto-start or unlimited fallback.",
        epilog="Config schemaVersion=1: absolute stateDirectory (0700), socketPath (private directory), monitorPath; maxHeavyJobs=1, memoryMiB=10240, maxResidentWorkers=12, recoverySeconds=120, graceSeconds=5. All homes must select the same config, via --config or FM_RESOURCE_CONFIG; default ~/.config/firstmate/host-budget.json. Monitor: dotfiles mac-workload schema 1. Ledger and 30-minute metrics ring are private atomic JSON; transitions append to transitions.jsonl. register-check --directory STATE requires an existing home state directory, creates private files and registers a host-budget custom watcher check; transitions --cursor PATH prints each new transition once per cursor. Critical thermal signals latch across boot; clear only after inspecting evidence. Missing/stale input holds compute. Read-only commands need no lease. Unknown local validation/Nix work uses exclusive. Nested compute inherits/atomically upgrades one lease; worker leases cover resident CLI memory only. prepare writes a task-owned manifest and PATH adapters; these are integration boundaries, not an OS sandbox. Direct interpreter/absolute executable launches must use run explicitly. No no-mistakes daemon or backend lifecycle is managed here.")
    p.add_argument("--config")
    sub = p.add_subparsers(dest="action", required=True)
    sub.add_parser("serve", help="foreground single owner; operator may supervise it with launchd")
    sub.add_parser("status", help="compact JSON status, including queue and last cause")
    q = sub.add_parser("register-check", help="register the transition wake check in an explicit home state directory")
    q.add_argument("--directory", required=True)
    q = sub.add_parser("transitions", help="print new transition lines and advance a private byte cursor")
    q.add_argument("--cursor", required=True)
    q = sub.add_parser("prepare", help="write a private restore manifest and command adapters")
    q.add_argument("--directory", required=True)
    q.add_argument("--worktree", required=True)
    q.add_argument("--task", required=True)
    q.add_argument("--account-label", required=True)
    q.add_argument("--account-env", action="append", default=[], help="selected harness config axis KEY=PATH; empty PATH requires the default account")
    q.add_argument("argv", nargs=argparse.REMAINDER)
    q = sub.add_parser("tool", help=argparse.SUPPRESS)
    q.add_argument("--name", required=True)
    q.add_argument("--executable", required=True)
    q.add_argument("argv", nargs=argparse.REMAINDER)
    for action in ("emergency", "clear-emergency"):
        q = sub.add_parser(action)
        q.add_argument("--evidence", required=True, help="inspection/cause note; never credentials")
    q = sub.add_parser("run", help="lease a bounded process group; descendants retain reservation after parent exit")
    q.add_argument("--class", dest="resource_class", choices=CLASSES, default="exclusive",
        help="minimum MiB: test=1024, build=3072, browser=2048, graph=512, exclusive=4096, worker=512")
    q.add_argument("--memory-mib", type=int, help="larger planning reservation for an oversized project")
    q.add_argument("--task", default=os.environ.get("FM_TASK_ID", "ad-hoc"))
    q.add_argument("--manifest")
    q.add_argument("--wait-seconds", type=float, default=0, help="queue deadline; exit 75 on expiry, 0 waits indefinitely")
    q.add_argument("argv", nargs=argparse.REMAINDER)
    return p


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "_barrier":
        with os.fdopen(int(sys.argv[2]), "rb") as gate:
            if gate.readline() != b"go\n":
                return 125
        os.execvpe(sys.argv[3], sys.argv[3:], os.environ)
    args = parser().parse_args()
    name, config, digest = load_config(args.config)
    if args.action == "register-check":
        register_check(args, name)
        return 0
    if args.action == "transitions":
        transitions(args, config)
        return 0
    if args.action == "prepare":
        prepare(args, name)
        return 0
    if args.action == "tool":
        return tool_job(args, name, config, digest)
    if args.action == "serve":
        serve(config, digest)
        return 0
    if args.action == "run":
        return run_job(args, name, config, digest)
    result = rpc(config, digest, op=args.action, **({"evidence": args.evidence} if hasattr(args, "evidence") else {}))
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Refusal, OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"fm-resource-run: {exc}", file=sys.stderr)
        sys.exit(75)

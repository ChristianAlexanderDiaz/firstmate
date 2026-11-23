#!/usr/bin/env python3
"""Private bounded observation cache used only by fm-github-read.sh.

256 fixed request slots (one JSON and lock each), plus one quota file and lock.
Each slot holds at most 16 unexpired keys; collisions share a lock and never
evict a fresh observation. A full slot waits until entries expire.
Each JSON is at most 1 MiB. Atomic replacement and advisory locks make readers
in separate homes/processes share a single fetch. No stale success is returned
on any read error. Quota cooldown takes precedence even over cached success.
Credentials are hashed in memory, never persisted. Debug transport output is
kept in memory only; only reset/retry headers and a generic failure escape.
REST validators and page bodies survive expiry for up to one day, within the
same slot/size limits. Only a successful 304 permits expired body reuse.
"""
import contextlib
import datetime
import email.utils
try:
    import fcntl
except ImportError:  # Native Windows Python used from Git Bash.
    fcntl = None
    import msvcrt
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
import urllib.parse

LIMIT = 1024 * 1024
SLOTS = 256
FIELDS = "state,isDraft,headRefOid,url"
BATCH_JQ = '''if .errors then empty else
.data | to_entries[] | select(.value.pullRequest != null)
| [.key, .value.pullRequest.url, .value.pullRequest.state,
.value.pullRequest.isDraft, .value.pullRequest.headRefOid] | @tsv end'''
PR = re.compile(r"https://github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)/pull/([1-9][0-9]*)\Z")
PART = re.compile(r'w[0-9]+: repository\(owner: "[A-Za-z0-9-]+", name: "[A-Za-z0-9._-]+"\) \{ pullRequest\(number: [1-9][0-9]*\) \{ url state isDraft headRefOid \} \}')


class Waiting(Exception):
    pass


class ReadError(Exception):
    def __init__(self, message, status):
        super().__init__(message)
        self.status = status if status > 0 else 128 - status


def now():
    if os.environ.get("FM_TEST_SEAM") == "1" and "FM_TEST_GITHUB_NOW" in os.environ:
        return float(os.environ["FM_TEST_GITHUB_NOW"])
    return time.time()


def digest(value):
    return hashlib.sha256(value).hexdigest()


def credential_key():
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        return digest(token.encode())
    config = Path(os.environ.get("GH_CONFIG_DIR") or
                  str(Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "gh"))
    # hosts.yml binds the active account, including keyring-backed logins. No
    # credential material or user paths are written into cache keys on disk.
    hosts = config / "hosts.yml"
    data = hosts.read_bytes() if hosts.exists() else b""
    return digest(str(config.resolve()).encode() + b"\0" + data)


class Cache:
    def __init__(self, path):
        self.path = Path(path)
        self.path.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.path.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != getattr(os, "getuid", lambda: 0)() or (os.name != "nt" and info.st_mode & 0o077):
            raise Waiting("GitHub cache directory must be private and owned by this user")
        self.identity = credential_key()
        self.ttl = int(os.environ.get("FM_GITHUB_CACHE_TTL", "300"))
        if not 0 <= self.ttl <= 3600:
            raise ValueError("invalid cache interval")

    def key(self, value):
        return digest((self.identity + "\0" + value).encode())

    def slot(self, key):
        return str(int(key[:8], 16) % SLOTS)

    @contextlib.contextmanager
    def locks(self, slots):
        with contextlib.ExitStack() as stack:
            for slot in sorted(set(slots)):
                lock_path = self.path / (slot + ".lock")
                if lock_path.is_symlink():
                    raise Waiting("unsafe GitHub cache lock")
                fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
                stream = stack.enter_context(os.fdopen(fd, "w"))
                info = os.fstat(fd)
                if info.st_uid != getattr(os, "getuid", lambda: 0)() or info.st_nlink != 1:
                    raise Waiting("unsafe GitHub cache lock")
                # The caller's bounded runner can terminate a wait; kernel locks
                # release automatically after crashes, without PID reclamation.
                if fcntl is not None:
                    fcntl.flock(stream, fcntl.LOCK_EX)
                else:
                    # msvcrt retries for ten seconds before raising; the outer
                    # bounded check runner can terminate the process earlier.
                    if info.st_size == 0:
                        stream.write("0")
                        stream.flush()
                    stream.seek(0)
                    msvcrt.locking(stream.fileno(), msvcrt.LK_LOCK, 1)
            yield

    def load(self, slot):
        try:
            record_path = self.path / (slot + ".json")
            if record_path.is_symlink():
                raise Waiting("unsafe GitHub cache record")
            fd = os.open(record_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            with os.fdopen(fd) as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > LIMIT or info.st_uid != getattr(os, "getuid", lambda: 0)() or (os.name != "nt" and info.st_mode & 0o077):
                    raise Waiting("unsafe GitHub cache record")
                record = json.load(stream)
                if not isinstance(record, dict):
                    raise Waiting("invalid GitHub cache record")
                return record
        except FileNotFoundError:
            return {}

    def save(self, slot, record):
        content = json.dumps(record)
        if len(content.encode()) > LIMIT:
            # Large paginated review bodies remain readable but are not cached.
            return
        # One fixed scratch per locked slot keeps even interrupted writes bounded.
        tmp = self.path / (slot + ".tmp")
        if tmp.is_symlink():
            raise Waiting("unsafe GitHub cache scratch")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(fd, "w") as stream:
            if os.fstat(stream.fileno()).st_nlink != 1:
                raise Waiting("unsafe GitHub cache scratch")
            stream.truncate(0)
            stream.write(content)
        os.replace(tmp, self.path / (slot + ".json"))

    def get(self, key):
        record = self.load(self.slot(key)).get(key, {})
        age = now() - record.get("at", 0)
        if 0 <= age < self.ttl:
            return record.get("value")
        return None

    def put(self, key, value, pages=None):
        if self.ttl == 0:
            return
        records = self.load(self.slot(key))
        records = {k: r for k, r in records.items()
                   if 0 <= now() - r.get("at", 0) < (86400 if r.get("pages") else self.ttl)}
        if key not in records and len(records) >= 16:
            expired = [k for k, r in records.items() if now() - r["at"] >= self.ttl]
            if not expired:
                raise Waiting("GitHub cache slot full until observations expire")
            del records[min(expired, key=lambda k: records[k]["at"])]
        records[key] = {"at": now(), "value": value}
        if pages:
            records[key]["pages"] = pages
        self.save(self.slot(key), records)

    def cooldown(self):
        # A machine-wide conservative cooldown also protects separate local
        # credentials sharing one upstream account. No quota data can imply green.
        with self.locks(["quota"]):
            until = self.load("quota").get("until", 0)
        if until > now():
            stamp = datetime.datetime.fromtimestamp(until, datetime.timezone.utc).isoformat()
            raise Waiting("GitHub rate limit until " + stamp)

    def fetch(self, args, headers=False):
        self.cooldown()
        env = dict(os.environ, GH_HOST="github.com", GH_DEBUG="api", GH_PROMPT_DISABLED="1", GH_NO_UPDATE_NOTIFIER="1")
        result = subprocess.run(["gh", *args], env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=25, text=True, encoding="utf-8")
        debug = result.stderr
        status, response_headers, body = None, {}, result.stdout
        if headers:
            parts = re.split(r"\r?\n\r?\n", result.stdout, maxsplit=1)
            match = re.match(r"HTTP/\S+ ([0-9]{3})\b", parts[0])
            if match and len(parts) == 2:
                status = int(match[1])
                response_headers = dict((name.lower(), value.strip())
                                        for name, value in re.findall(r"^([^:\r\n]+):([^\r\n]*)", parts[0], re.M))
                body = parts[1]
        refused = status != 304 and result.returncode and re.search(r"rate.?limit.{0,30}(exceeded|exhausted)|secondary rate limit|RATE_LIMITED|HTTP[^\n]* 429", debug + (result.stdout if result.returncode else ""), re.I)
        if refused:
            observed_at = now()
            resets = [int(x) for x in re.findall(r"(?im)^< x-ratelimit-reset:\s*([0-9]+)", debug)]
            remaining = [int(x) for x in re.findall(r"(?im)^< x-ratelimit-remaining:\s*([0-9]+)", debug)]
            retry = re.findall(r"(?im)^< retry-after:\s*([^\r\n]+)", debug)
            deadlines = [x for x in resets if x > observed_at] if remaining and remaining[-1] == 0 else []
            for value in retry:
                try:
                    deadlines.append(observed_at + int(value))
                except ValueError:
                    try:
                        deadlines.append(email.utils.parsedate_to_datetime(value).timestamp())
                    except (ValueError, TypeError):
                        pass
            with self.locks(["quota"]):
                quota = self.load("quota")
                # Without a deadline, only explicit zero remaining proves hourly
                # exhaustion. Secondary/unknown refusals start at one minute and
                # grow to fifteen minutes, shared across all local readers.
                delay = 0
                if deadlines:
                    until = max(observed_at + 60, *deadlines)
                elif remaining and remaining[-1] == 0:
                    until = observed_at + 3600
                else:
                    delay = min(900, max(60, quota.get("burst_delay", 0) * 2))
                    until = observed_at + delay
                until = max(until, quota.get("until", 0))
                self.save("quota", {"until": until, "burst_delay": delay})
            self.cooldown()
        if result.returncode and status != 304:
            # Never persist raw debug headers/bodies, credentials or comments.
            if "* Request at" not in debug:
                # Transport shims may supply only the ordinary CLI diagnostic.
                message = debug.strip()
            else:
                message = "\n".join(line for line in debug.splitlines()
                                    if line.startswith(("gh:", "HTTP ", "error:", "Get ", "Post ")))
            raise ReadError(message or "GitHub read unavailable (exit %d)" % result.returncode, result.returncode)
        if headers and status is None:
            raise ReadError("GitHub REST response headers unavailable", 1)
        with self.locks(["quota"]):
            quota = self.load("quota")
            # A success already in flight must not erase a newer refusal.
            if quota.get("burst_delay", 0) and quota.get("until", 0) <= now():
                self.save("quota", {"until": 0, "burst_delay": 0})
        self.cooldown()
        return (status, response_headers, body) if headers else result.stdout

    def rest(self, args, prior, projection):
        # gh's --paginate cannot apply a distinct validator to each page. Walk
        # its Link headers explicitly so an unchanged first page never hides a
        # changed later page. Formatting stays outside the cached page bodies.
        endpoint = args[1]
        pages, visited = [], set()
        previous = {page["url"]: page for page in prior.get("pages", [])}
        while endpoint:
            if endpoint in visited:
                raise ValueError("cyclic GitHub pagination")
            visited.add(endpoint)
            old = previous.get(endpoint, {})
            request = ["api", endpoint, "--include"]
            if old.get("etag"):
                request += ["-H", "If-None-Match: " + old["etag"]]
            elif old.get("modified"):
                request += ["-H", "If-Modified-Since: " + old["modified"]]
            status, headers, body = self.fetch(request, headers=True)
            if status == 304 and "--paginate" in args and "link" not in headers and old:
                # A full page can gain a successor without changing its body.
                # Missing Link metadata cannot prove the old topology is still
                # current. Re-read it unconditionally rather than hide a page.
                payload = json.loads(old["body"])
                size = int(urllib.parse.parse_qs(urllib.parse.urlsplit(endpoint).query).get("per_page", ["30"])[-1])
                collections = [payload] if isinstance(payload, list) else list(payload.values()) if isinstance(payload, dict) else []
                if old.get("link") or any(isinstance(value, list) and len(value) >= size for value in collections):
                    status, headers, body = self.fetch(["api", endpoint, "--include"], headers=True)
            if status == 304:
                if not old or not (old.get("etag") or old.get("modified")):
                    raise ValueError("GitHub returned 304 without a stored representation")
                body = old["body"]
                # 304 may omit unchanged representation metadata.
                page = dict(old)
            elif status == 200:
                page = {"url": endpoint, "body": body}
            else:
                raise ReadError("Unexpected GitHub REST status %s" % status, 1)
            for name, field in (("etag", "etag"), ("last-modified", "modified"), ("link", "link")):
                if name in headers:
                    if "\r" in headers[name] or "\n" in headers[name]:
                        raise ValueError("invalid GitHub response header")
                    page[field] = headers[name]
            pages.append(page)
            endpoint = None
            if "--paginate" in args:
                link = re.search(r'<([^>]+)>;\s*rel="next"', page.get("link", ""))
                if link:
                    url = urllib.parse.urlsplit(link[1])
                    if url.scheme != "https" or url.netloc != "api.github.com" or not url.path.startswith("/repos/") or url.fragment:
                        raise ValueError("unexpected GitHub pagination URL")
                    endpoint = url.path.lstrip("/") + ("?" + url.query if url.query else "")
        if "--slurp" in args:
            value = json.dumps([json.loads(page["body"]) for page in pages]) + "\n"
        else:
            value = "".join(page["body"] + ("" if page["body"].endswith("\n") else "\n") for page in pages)
        if projection:
            # jq is already required by the REST consumers; -r matches gh's
            # string output while retaining JSON for objects and arrays.
            formatted = subprocess.run(["jq", "-r", projection], input=value,
                                       text=True, capture_output=True, timeout=25)
            if formatted.returncode:
                raise ReadError("GitHub REST projection failed", formatted.returncode)
            value = formatted.stdout
        return value, pages if any(p.get("etag") or p.get("modified") for p in pages) else None

    def read(self, args, fresh=False):
        # Admit only the observation forms used by these callers. In particular,
        # gh api fields implicitly select POST, even without an explicit method.
        api = args[:1] == ["api"]
        if api:
            if len(args) < 2 or not args[1].startswith("repos/"):
                raise ValueError("expected a REST GET")
            tail = args[2:]
        elif args[:2] == ["pr", "view"] and len(args) >= 3 and PR.fullmatch(args[2]):
            tail = args[3:]
        else:
            raise ValueError("expected a GitHub read")
        projection = None
        while tail:
            if api and tail[0] in ("--paginate", "--slurp"):
                tail = tail[1:]
            elif len(tail) >= 2 and tail[0] in (("--jq", "-q") if api else ("--json", "--jq", "-q")):
                if api:
                    projection = tail[1]
                tail = tail[2:]
            else:
                raise ValueError("unsupported GitHub read option")
        if api and "--slurp" in args and ("--paginate" not in args or "--jq" in args or "-q" in args):
            raise ValueError("--slurp requires --paginate and cannot be combined with --jq")
        key = self.key(json.dumps(args))
        with self.locks([self.slot(key)]):
            self.cooldown()
            value = None if fresh else self.get(key)
            if value is None:
                pages = None
                if api and not fresh and self.ttl:
                    prior = self.load(self.slot(key)).get(key, {})
                    if not 0 <= now() - prior.get("at", 0) < 86400:
                        prior = {}
                    value, pages = self.rest(args, prior, projection)
                else:
                    value = self.fetch(args)
                if not fresh:
                    self.put(key, value, pages)
            return value

    def fresh_head(self, url):
        if not PR.fullmatch(url):
            raise ValueError("expected canonical GitHub PR URL")
        key = self.key(url.lower())
        slot = self.slot(key)
        with self.locks([slot]):
            value = self.fetch(["pr", "view", url, "--json", "headRefOid", "-q", ".headRefOid"])
            records = self.load(slot)
            if key in records:
                del records[key]
                self.save(slot, records)
            return value

    def core(self, url):
        if not PR.fullmatch(url):
            raise ValueError("expected canonical GitHub PR URL")
        key = self.key(url.lower())
        with self.locks([self.slot(key)]):
            self.cooldown()
            value = self.get(key)
            if value is None:
                value = json.loads(self.fetch(["pr", "view", url, "--json", FIELDS]))
                validate_core(value, url)
                self.put(key, value)
            return value

    def batch(self, query):
        parts = PART.findall(query)
        if not parts or query != "query { " + " ".join(parts) + " }":
            raise ValueError("expected merge-wait query")
        requests = []
        for part in parts:
            alias, owner, repo, number = re.match(r'(w[0-9]+): repository\(owner: "([^"]+)", name: "([^"]+)"\) \{ pullRequest\(number: ([0-9]+)', part).groups()
            url = f"https://github.com/{owner}/{repo}/pull/{number}"
            requests.append((alias, url, part, self.key(url.lower())))
        with self.locks([self.slot(key) for _, _, _, key in requests]):
            self.cooldown()
            values = {url: self.get(key) for _, url, _, key in requests}
            missing = []
            seen = set()
            for row in requests:
                if values[row[1]] is None and row[1] not in seen:
                    missing.append(row)
                    seen.add(row[1])
            if missing:
                query = "query { " + " ".join(row[2] for row in missing) + " }"
                output = self.fetch(["api", "graphql", "-f", "query=" + query, "--jq", BATCH_JQ])
                rows = {}
                for line in output.splitlines():
                    alias, url, state, draft, head = line.split("\t")
                    if alias in rows or draft not in ("true", "false"):
                        raise ValueError("invalid GitHub batch response")
                    rows[alias] = dict(url=url, state=state, isDraft=draft == "true", headRefOid=head)
                for alias, url, _, key in missing:
                    value = rows.get(alias)
                    validate_core(value, url)
                    values[url] = value
                # Publish only after the entire response has been validated.
                for _, url, _, key in missing:
                    self.put(key, values[url])
            return "".join(f'{alias}\t{url}\t{values[url]["state"]}\t{str(values[url]["isDraft"]).lower()}\t{values[url]["headRefOid"]}\n'
                           for alias, url, _, _ in requests)


def validate_core(value, url):
    if not isinstance(value, dict) or str(value.get("url", "")).lower() != url.lower() or value.get("state") not in ("OPEN", "CLOSED", "MERGED") or type(value.get("isDraft")) is not bool or not re.fullmatch(r"[0-9a-fA-F]{40}", value.get("headRefOid", "")):
        raise ValueError("incomplete GitHub PR observation")


def main():
    os.umask(0o077)
    cache = Cache(sys.argv[1])
    mode, args = sys.argv[2], sys.argv[3:]
    if mode == "core":
        value = cache.core(args[0])
        field = args[1] if len(args) > 1 else "json"
        print(value["state"] if field == "state" else value["headRefOid"] if field == "head" else json.dumps(value))
    elif mode == "fresh-head":
        print(cache.fresh_head(args[0]), end="")
    elif mode == "batch":
        print(cache.batch(args[0]), end="")
    elif mode in ("read", "fresh"):
        print(cache.read(args, mode == "fresh"), end="")
    else:
        raise ValueError("unknown observation mode")


if __name__ == "__main__":
    try:
        main()
    except ReadError as error:
        print(str(error), file=sys.stderr)
        sys.exit(error.status)
    except Waiting as error:
        print("waiting: " + str(error), file=sys.stderr)
        sys.exit(75)
    except (OSError, ValueError, RuntimeError, IndexError, subprocess.TimeoutExpired) as error:
        print("GitHub observation unavailable: " + str(error), file=sys.stderr)
        sys.exit(1)

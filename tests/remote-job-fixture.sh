#!/usr/bin/env bash
# Private account, service-manager guards, and scoped process scans for remote
# transport fixtures. Source after lib.sh; install after copying the remote bin/.
# No production entrypoint is changed: it still resolves the real SSH account.
# A private worker is ready before SSH enters that path, including after a test
# deliberately stops it. Bootstrap doctor calls remain read-only and guarded.

fm_test_remote_isolate() { # <fixture-root> <remote-root> [<private-account-home>]
  local fixture=$1 remote=$2 account=${3:-$1/account} manager real_ps
  export FM_TEST_REMOTE_ACCOUNT_HOME="$account"
  export FM_TEST_REMOTE_HELPERS="$ROOT/tests/remote-job-fixture.sh"
  export FM_TEST_REMOTE_GUARDS="$fixture/remote-guards"
  export FM_TEST_REMOTE_MANAGER_LOG="$fixture/host-manager-calls"
  mkdir -p "$FM_TEST_REMOTE_GUARDS" "$remote/bin" "$account/.local/bin" \
    "$account/.config/systemd/user" "$account/run"
  chmod 700 "$account/run"
  cat > "$FM_TEST_REMOTE_GUARDS/systemctl" <<SH
#!/usr/bin/env bash
printf '%s %s\\n' "\${0##*/}" "\$*" >> '$fixture/host-manager-calls'
exit 70
SH
  chmod +x "$FM_TEST_REMOTE_GUARDS/systemctl"
  cp "$FM_TEST_REMOTE_GUARDS/systemctl" "$FM_TEST_REMOTE_GUARDS/loginctl"
  for manager in systemctl loginctl; do
    cp "$FM_TEST_REMOTE_GUARDS/$manager" "$remote/bin/$manager"
    cp "$FM_TEST_REMOTE_GUARDS/$manager" "$account/.local/bin/$manager"
  done
  # The reaper's account-wide ps scan is the sole sweep boundary. Identity and
  # parent/group probes still use real ps, so worker-tree behavior stays real.
  if [ -x /bin/ps ]; then real_ps=/bin/ps; else real_ps=/usr/bin/ps; fi
  cat > "$FM_TEST_REMOTE_GUARDS/ps" <<SH
#!/usr/bin/env bash
if [ "\$#" -eq 4 ] && [ "\$1" = -u ] && [ "\$3" = -o ] && [ "\$4" = pid=,command= ]; then
  scan=\$('$real_ps' "\$@") || exit 1
  printf '%s\\n' "\$scan" | awk -v prefix='$fixture/' '
    {
      original=\$0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
      if (index(\$0, prefix) == 1) { print original; next }
      sub(/^[^[:space:]]+[[:space:]]+/, "")
      if (index(\$0, prefix) == 1) print original
    }'
else
  exec '$real_ps' "\$@"
fi
SH
  chmod +x "$FM_TEST_REMOTE_GUARDS/ps"
  cp "$FM_TEST_REMOTE_GUARDS/ps" "$remote/bin/ps"
  cp "$FM_TEST_REMOTE_GUARDS/ps" "$account/.local/bin/ps"
  export HOME="$account" PATH="$FM_TEST_REMOTE_GUARDS:$PATH"
  export FM_REMOTE_SYSTEMCTL="$FM_TEST_REMOTE_GUARDS/systemctl"
  export FM_REMOTE_SYSTEMD_UNIT_DIR="$account/.config/systemd/user"
  export XDG_CONFIG_HOME="$account/.config" XDG_RUNTIME_DIR="$account/run"
}

fm_test_remote_start_worker() { # <remote-root> <state-root>
  local remote=$1 state=$2 i
  set -m
  HOME="$FM_TEST_REMOTE_ACCOUNT_HOME" FM_ROOT_OVERRIDE="$remote" \
    FM_REMOTE_JOB_STATE_ROOT="$state" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    "$remote/bin/fm-remote-job-worker.sh" > "$state.worker.log" 2>&1 &
  FM_TEST_REMOTE_WORKER_PID=$!
  set +m
  for ((i = 0; i < 200; i++)); do
    [ -f "$state/worker.ready" ] && return 0
    kill -0 "$FM_TEST_REMOTE_WORKER_PID" 2>/dev/null || break
    sleep 0.1
  done
  fail "private remote worker did not report ready"
}

# Called inside every fake SSH process, before any entrypoint invocation.
fm_test_remote_ssh_worker() (
  local command_name remote
  export HOME="$FM_TEST_REMOTE_ACCOUNT_HOME"
  command_name=$(perl -MMIME::Base64=decode_base64 -e \
    '($c)=split(/\0/,decode_base64($ARGV[0])); print $c' "$4") || exit 1
  [ "$command_name" != fm-remote-doctor.sh ] || exit 0
  remote=${FM_FAKE_REMOTE_ENTRYPOINT%/bin/fm-remote-entrypoint.sh}
  # shellcheck source=/dev/null
  . "$remote/bin/fm-remote-job-lib.sh"
  fm_remote_job_ensure_worker "$remote" "$HOME" || {
    printf 'private remote worker: %s\n' "$FM_REMOTE_JOB_ERROR" >&2
    exit 1
  }
)

fm_test_remote_stop_worker() { # <state-root>
  local state=$1 pid
  if [ -f "$state/worker.pid" ]; then
    pid=$(cat "$state/worker.pid")
    # shellcheck source=bin/fm-remote-job-lib.sh
    . "$ROOT/bin/fm-remote-job-lib.sh"
    fm_remote_job_stop_worker_tree "$pid" || fail "private remote worker did not stop"
  fi
  if [ -n "${FM_TEST_REMOTE_WORKER_PID:-}" ]; then
    kill -TERM "$FM_TEST_REMOTE_WORKER_PID" 2>/dev/null || true
    wait "$FM_TEST_REMOTE_WORKER_PID" 2>/dev/null || true
  fi
}

fm_test_remote_assert_isolated() {
  # A refused version probe selects the direct worker path. No other manager
  # operation, including loginctl, may be attempted, and no unit may be written.
  if [ -f "$FM_TEST_REMOTE_MANAGER_LOG" ]; then
    if grep -vx 'systemctl --user show --property=Version --value' "$FM_TEST_REMOTE_MANAGER_LOG"; then
      fail "remote fixture attempted a host service-manager operation"
    fi
  fi
  [ -z "$(find "$FM_REMOTE_SYSTEMD_UNIT_DIR" -type f -print)" ] \
    || fail "remote fixture wrote a service unit"
}

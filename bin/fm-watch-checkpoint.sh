#!/usr/bin/env bash
# Run one bounded foreground watcher checkpoint for harnesses that should not
# rely on background-task completion to wake the model.
# --wait is the normal Codex path: one foreground wait keeps the watcher alive
# until a wake or a repair reason arrives. No queue rows are consumed here.
# The wait observes the existing queue and beacon; it adds no daemon or polling
# to the watcher. Its owned process group is cleaned up on interruption.
#
# SUPERVISION HOST. A home opted in with config/supervision-host
# (docs/configuration.md "Supervision host" owns the gate;
# config/supervision-host-off opts out, and a Codex home without the file does not run the host) runs
# bin/fm-supervision-host.sh in the watcher's place for the checkpoint's bound,
# as the host's park boundary; the host takes away-posture wakes itself and
# returns only when main is needed (its header owns the output read here).
# While an away record state/.afk-contract exists (never quiet mode's, whose
# captain is present: bin/fm-afk-contract.sh mode), the bound is
# raised to FM_CODEX_WATCH_CHECKPOINT_AWAY (default 3600) when that is longer,
# so a parked main is not woken every few minutes; an engine turn that starts
# before the bound may finish after it. A close that carries a wake or a
# "supervision-host:" line other than the park boundary passes through as a
# wake; the boundary alone is the ordinary quiet diagnostic checkpoint.
# --wait instead asks the Codex host to park without a quiet boundary and
# observes its liveness without imposing a wall timeout.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SECONDS_ARG=${FM_CODEX_WATCH_CHECKPOINT:-180}
WAIT_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-watch-checkpoint.sh [--wait] [--seconds <n>]

Run bin/fm-watch.sh in the foreground for a bounded checkpoint.
On an actionable watcher wake, pass through the watcher output and exit 0.
On a quiet checkpoint, print "checkpoint: no actionable wake within <n>s" and exit 124.
With --wait, the watcher stays alive until a wake (0) or failure (1, with "repair:").
--seconds applies only to the bounded diagnostic checkpoint.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --wait)
      WAIT_MODE=1
      shift
      ;;
    --seconds)
      [ "$#" -gt 1 ] || { echo "error: --seconds requires a value" >&2; exit 2; }
      SECONDS_ARG=$2
      shift 2
      ;;
    --seconds=*)
      SECONDS_ARG=${1#--seconds=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$SECONDS_ARG" in
  ''|*[!0-9]*) echo "error: --seconds must be a positive integer" >&2; exit 2 ;;
  0) echo "error: --seconds must be greater than zero" >&2; exit 2 ;;
esac

# A checkpoint is neither an ordinary watcher start nor an Option B handling
# successor. It keeps an announced recovery episode stable while preserving the
# watcher's ordinary recovery of a generation that becomes pending.
export FM_WATCH_FOREGROUND_CHECKPOINT=1

OUT=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.out.XXXXXX") || exit 1
ERR=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.err.XXXXXX") || {
  rm -f "$OUT"
  exit 1
}
trap 'rm -f "$OUT" "$ERR"' EXIT

quiet_boundary() {
  printf 'checkpoint: no actionable wake within %ss\n' "$1"
  exit 124
}

wait_failure() {
  [ "$WAIT_MODE" -ne 1 ] || echo 'repair: watcher wait ended without a wake; drain queued wakes, inspect watcher liveness, then restore the foreground wait' >&2
}

run_with_perl_timeout() {  # <seconds> <signal> <kill-after-seconds> <command...>
  perl -e '
    use POSIX qw(:sys_wait_h);
    my $seconds = shift;
    my $signal = shift;
    my $kill_after = shift;
    my $pid = fork;
    die "fork failed\n" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
      die "exec failed: $!\n";
    }
    my $timed_out = 0;
    local $SIG{ALRM} = sub {
      if ($timed_out) {
        kill "KILL", -$pid;
        waitpid $pid, 0;
        exit 124;
      }
      $timed_out = 1;
      kill $signal, -$pid;
      alarm($kill_after) if $kill_after;
    };
    alarm $seconds;
    while (1) {
      my $waited = waitpid $pid, WNOHANG;
      if ($waited == $pid) {
        alarm 0;
        exit($timed_out ? 124 : ($? >> 8));
      }
      select undef, undef, undef, 0.05;
    }
  ' "$@"
}

run_bounded() {  # <seconds> <signal> <kill-after-seconds> <command...>
  local seconds=$1 signal=$2 kill_after=$3 cleanup_lock_bound
  shift 3
  if [ "$kill_after" -gt 0 ]; then
    cleanup_lock_bound=${FM_WATCHER_CLEANUP_LOCK_BOUND:-2}
    case "$cleanup_lock_bound" in
      ''|*[!0-9]*) cleanup_lock_bound=2 ;;
      *) cleanup_lock_bound=$((10#$cleanup_lock_bound)) ;;
    esac
    [ "$cleanup_lock_bound" -gt 0 ] || cleanup_lock_bound=2
    [ "$cleanup_lock_bound" -gt "$kill_after" ] || cleanup_lock_bound=$kill_after
    kill_after=$cleanup_lock_bound
  fi
  if command -v timeout >/dev/null 2>&1; then
    if [ "$kill_after" -gt 0 ]; then
      timeout --signal="$signal" --kill-after="${kill_after}s" "$seconds" "$@"
    else
      timeout --signal="$signal" "$seconds" "$@"
    fi
  elif command -v gtimeout >/dev/null 2>&1; then
    if [ "$kill_after" -gt 0 ]; then
      gtimeout --signal="$signal" --kill-after="${kill_after}s" "$seconds" "$@"
    else
      gtimeout --signal="$signal" "$seconds" "$@"
    fi
  else
    run_with_perl_timeout "$seconds" "$signal" "$kill_after" "$@"
  fi
}

# Keep one owned child throughout the wait. Perl is already the portable
# checkpoint timeout fallback; here it also observes the same durable queue and
# watcher beacon, without process/endpoint scans or a fork per observation.
# The queue belongs to the host when hosted, so only plain waits observe it.
run_waiting() {  # <plain|host> <command...>
  local kind=$1 stall confirm cleanup
  shift
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  stall=$(fm_watcher_stall_bound)
  confirm=$(positive_or "${FM_ARM_CONFIRM_TIMEOUT:-}" 30)
  [ "$kind" != host ] || confirm=$((confirm + $(positive_or "${FM_SUPERVISION_HOST_READY_TIMEOUT:-}" 25)))
  cleanup=$(positive_or "${FM_WATCHER_CLEANUP_LOCK_BOUND:-}" 5)
  [ "$cleanup" -ge 5 ] || cleanup=5
  perl -e '
    use strict;
    use warnings;
    use POSIX qw(:sys_wait_h);
    my ($kind, $queue, $beat, $stall, $confirm, $grace, $lock, $state) = splice @ARGV, 0, 8;
    my $owner = getppid();
    my $started = time;
    my $pid = fork;
    die "fork failed\n" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      # A tool/test may launch us with INT ignored. Restore dispositions before
      # exec so the watcher can install its cleanup traps instead of requiring KILL.
      $SIG{$_} = "DEFAULT" for qw(INT TERM HUP ALRM);
      exec @ARGV;
      die "exec failed: $!\n";
    }
    my ($closing, $deadline, $reason) = (0, 0, "");
    my $stop = sub {
      my ($signal, $why) = @_;
      return if $closing;
      $closing = 1;
      $reason = $why;
      $deadline = time + $grace;
      kill $signal, -$pid;
    };
    for my $signal (qw(TERM INT HUP)) {
      $SIG{$signal} = sub { $stop->($signal, "interrupted"); };
    }
    while (1) {
      my $waited = waitpid $pid, WNOHANG;
      if ($waited == $pid) {
        my $status = $?;
        kill "KILL", -$pid if $closing;
        exit($reason eq "queued" ? 0 : $closing ? 1 :
          ($status & 127) ? 128 + ($status & 127) : $status >> 8);
      }
      if (!$closing) {
        my $queued = 0;
        # Match fm_sleep_active: held rows are not a reason to wake the model.
        my $sleep_state = $state;
        my $sleeping = 0;
        while (1) {
          $sleeping = -e "$sleep_state/.sleep" || -e "$sleep_state/.sleep-return";
          last if $sleeping || $sleep_state !~ s{/parent-route$}{};
        }
        if ($kind eq "plain" && !$sleeping
            && -s $queue && open(my $owner_file, "<", "$lock/pid")) {
          my $watcher = <$owner_file> // "";
          close $owner_file;
          chomp $watcher;
          # watcher-path is published after the watcher installs its cleanup
          # traps. Never interrupt it midway through initial lock acquisition.
          $queued = $watcher eq "$pid" && -s "$lock/watcher-path";
        }
        if (getppid() != $owner) {
          $stop->("INT", "owner died");
        } elsif ($queued) {
          $stop->("INT", "queued");
        } else {
          my @beat = stat $beat;
          my $age = @beat ? time - $beat[9] : time - $started;
          if (time - $started >= $confirm && (!@beat || $age >= $stall)) {
            print STDERR "repair: watcher beacon stalled during the foreground wait\n";
            $stop->("INT", "stalled");
          }
        }
      } elsif (time >= $deadline) {
        kill "KILL", -$pid;
        waitpid $pid, 0;
        exit($reason eq "queued" ? 0 : 1);
      }
      select undef, undef, undef, 0.2;
    }
  ' "$kind" "$FM_WAKE_QUEUE" "$STATE/.last-watcher-beat" "$stall" "$confirm" "$cleanup" "$STATE/.watch.lock" "$STATE" "$@"
}

positive_or() {  # <value> <default>
  case "$1" in ''|0*|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"
if fm_supervision_host_enabled "$CONFIG" codex; then
  BOUND=$SECONDS_ARG
  if [ -f "$STATE/.afk-contract" ] \
    && [ "$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" != quiet ]; then
    AWAY_BOUND=$(positive_or "${FM_CODEX_WATCH_CHECKPOINT_AWAY:-}" 3600)
    [ "$AWAY_BOUND" -le "$BOUND" ] 2>/dev/null || BOUND=$AWAY_BOUND
  fi
  # The host's park boundary stays below the 28800-second registration.
  [ "$BOUND" -lt 27000 ] 2>/dev/null || BOUND=27000
  LIMIT=$(( BOUND + $(positive_or "${FM_SUPERVISION_HOST_TURN_TIMEOUT:-}" 1200) + $(positive_or "${FM_SUPERVISION_ENGINE_GRACE:-}" 30) ))
  set +e
  # The host ends its own park; the outer bound only catches a host that
  # outlived every one of its own bounds.
  if [ "$WAIT_MODE" -eq 1 ]; then
    FM_SUPERVISION_HOST_PRIMARY=codex FM_SUPERVISION_HOST_PARK_RESUME=1 \
      run_waiting host "$SCRIPT_DIR/fm-supervision-host.sh" park >"$OUT" 2>"$ERR"
    RC=$?
  else
    FM_SUPERVISION_HOST_PRIMARY=codex FM_SUPERVISION_HOST_PARK_SECONDS=$BOUND FM_SUPERVISION_HOST_PARK_LIMIT=$LIMIT \
      run_bounded $((LIMIT + 120)) TERM 0 "$SCRIPT_DIR/fm-supervision-host.sh" park >"$OUT" 2>"$ERR"
    RC=$?
  fi
  set -e
  if grep -E '^(signal:|stale:|check:|heartbeat($|:)|supervision-host:)' "$OUT" 2>/dev/null \
    | grep -Ev '^supervision-host: cycle boundary' >/dev/null; then
    grep -Ev '^watcher: (started|attached) ' "$OUT"
    [ ! -s "$ERR" ] || cat "$ERR" >&2
    exit 0
  fi
  if grep -E '^supervision-host: cycle boundary' "$OUT" >/dev/null 2>&1; then
    if [ "$WAIT_MODE" -eq 1 ]; then
      echo 'repair: supervision host ended a continuous wait at a quiet boundary' >&2
      exit 1
    fi
    quiet_boundary "$BOUND"
  fi
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  wait_failure
  if [ "$RC" -eq 124 ]; then
    echo "checkpoint: the supervision host outlived its own bound of ${BOUND}s" >&2
    exit 1
  fi
  [ "$RC" -ne 0 ] || RC=1
  exit "$RC"
fi

# A previously presented but unacknowledged queue must still return immediately,
# even when its recovery generation was already announced. The host path above
# retains actor routing; plain Codex owns the whole queue. Observation never
# grants, drains, or acknowledges rows (including a row arriving at the bound).
wait_queue_ready() {
  [ "$WAIT_MODE" -eq 1 ] && [ -s "${FM_WAKE_QUEUE:-$STATE/.wake-queue}" ] || return 1
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_sleep_active "$STATE" && return 1
  echo 'check: durable wake queued; drain before other action'
}
wait_queue_ready && exit 0

set +e
# Interrupt the checkpoint's active check group so the watcher's native EXIT cleanup can release its lock; ordinary watcher shutdown still uses TERM.
if [ "$WAIT_MODE" -eq 1 ]; then
  run_waiting plain "$SCRIPT_DIR/fm-watch.sh" >"$OUT" 2>"$ERR"
  RC=$?
else
  run_bounded "$SECONDS_ARG" INT 5 "$SCRIPT_DIR/fm-watch.sh" >"$OUT" 2>"$ERR"
  RC=$?
fi
set -e

if grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" >/dev/null 2>&1; then
  cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  exit 0
fi

if grep -E '^watcher: already running' "$OUT" "$ERR" >/dev/null 2>&1; then
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  echo "checkpoint: watcher is already running outside this foreground checkpoint" >&2
  wait_failure
  exit 1
fi

if [ "$RC" -eq 124 ] && [ "$WAIT_MODE" -eq 0 ]; then
  quiet_boundary "$SECONDS_ARG"
fi

[ ! -s "$OUT" ] || cat "$OUT"
[ ! -s "$ERR" ] || cat "$ERR" >&2
if [ "$WAIT_MODE" -eq 1 ]; then
  wait_queue_ready && exit 0
  wait_failure
  exit 1
fi
exit "$RC"

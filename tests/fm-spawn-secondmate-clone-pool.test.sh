#!/usr/bin/env bash
# Real-Treehouse regression: a secondmate home spawns from its OWN project clone.
#
# Every home's clone of one project shares one Treehouse pool: Treehouse keys a
# pool by the clone's directory name and origin URL, and bin/fm-home-seed.sh
# clones a secondmate's copy from the same origin into the same projects/<name>.
# A spawn must still be handed a pooled worktree of the clone it spawns from,
# which is what the launch-time Claude trust scope check (bin/fm-claude-trust.sh)
# accepts, even while the other home's clone has an idle copy in that pool.
# Treehouse before 3.0.0 handed out whichever idle copy it found first, so a
# secondmate's claude launch was refused with "... is not a worktree of project
# ...", and once the secondmate held a copy of its own the parent's launches
# could be refused the same way. bin/fm-bootstrap.sh's TREEHOUSE_MIN owns that
# floor; this suite skips below it.
#
# Drives the real bin/fm-spawn.sh against a real tmux server on a private
# socket and a real Treehouse on a scratch pool root, with a throwaway HOME and
# a stub claude that only stands in for the agent after the launch-time trust
# registration. Each idle-copy precondition is asserted from Treehouse's own
# status before the spawn that depends on it, so the case cannot pass without
# the other clone's copy actually being on offer.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }
TREEHOUSE_VERSION=$(TREEHOUSE_NO_UPDATE_CHECK=1 treehouse --version 2>/dev/null | head -n 1)
TREEHOUSE_MAJOR=$(printf '%s\n' "$TREEHOUSE_VERSION" | sed -nE 's/^[vV]?([0-9]+)\.[0-9]+\.[0-9]+$/\1/p')
if [ -z "$TREEHOUSE_MAJOR" ] || [ "$TREEHOUSE_MAJOR" -lt 3 ]; then
  echo "skip: treehouse older than 3.0.0 (${TREEHOUSE_VERSION:-unknown version})"
  exit 0
fi

# Hermetic backend resolution: pin tmux per home and drop any ambient runtime
# markers so an operator's own herdr, cmux, or tmux session never leaks in.
unset TMUX TMUX_PANE FM_BACKEND HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID 2>/dev/null || true

TMP_ROOT=$(fm_test_tmproot fm-spawn-secondmate-clone-pool)
REAL_TMUX=$(command -v tmux)
SOCKET="fm-sm-clone-pool-$$"
on_exit() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap on_exit EXIT

# A tmux shim routing every call to the private socket, and a stub claude.
SHIM="$TMP_ROOT/shim"
mkdir -p "$SHIM"
cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
cat > "$SHIM/claude" <<'SH'
#!/bin/sh
echo "stub claude started"
exec sleep "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}"
SH
chmod +x "$SHIM/tmux" "$SHIM/claude"

export PATH="$SHIM:$PATH"
export HOME="$TMP_ROOT/user-home"
export CLAUDE_CONFIG_DIR=
export TREEHOUSE_ROOT="$TMP_ROOT/pools"
export TREEHOUSE_NO_UPDATE_CHECK=1
mkdir -p "$HOME" "$TREEHOUSE_ROOT"

fm_git_init_commit "$TMP_ROOT/seed/demo"
git clone --quiet --bare "$TMP_ROOT/seed/demo" "$TMP_ROOT/origin/demo.git"

make_home() { # <home>
  fm_test_spawn_home "$1" claude
  printf 'tmux\n' > "$1/config/backend"
  git clone --quiet "file://$TMP_ROOT/origin/demo.git" "$1/projects/demo"
}
MAIN="$TMP_ROOT/main"
SM="$TMP_ROOT/secondmate"
make_home "$MAIN"
make_home "$SM"
cat > "$SM/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$MAIN
EOF

spawn_task() { # <home> <id>
  fm_test_spawn_brief "$1" "$2"
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    FM_CONFIG_OVERRIDE="$1/config" FM_PROJECTS_OVERRIDE="$1/projects" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$2" "$1/projects/demo" claude --scout 2>&1
}

copy_of() { # <home> <id>
  sed -n 's/^worktree=//p' "$1/state/$2.meta"
}

physical() { # <path>
  (cd "$1" && pwd -P)
}

# The clone a pooled copy belongs to: the physical Git common directory it
# shares, the same identity Treehouse and the trust check compare.
clone_of() { # <copy>
  physical "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"
}

claim_of() { # <copy>
  sed -n 's/^task=//p' "$(dirname "$(physical "$1")")/.fm-slot-owner" 2>/dev/null
}

stop_task() { # <id>
  tmux kill-window -t "firstmate:fm-$1"
}

# Wait until Treehouse itself reports <copy> available for reuse.
wait_available() { # <copy>
  local want i path
  want=$(physical "$1")
  for i in $(seq 1 60); do
    while IFS= read -r path; do
      [ -n "$path" ] && [ -d "$path" ] && [ "$(physical "$path")" = "$want" ] && return 0
    done < <(cd "$MAIN/projects/demo" && treehouse status --json 2>/dev/null \
      | jq -r '.[] | select(.status == "available") | .path')
    [ "$i" -lt 60 ] && sleep 0.5
  done
  return 1
}

MAIN_CLONE=$(physical "$MAIN/projects/demo/.git")
SM_CLONE=$(physical "$SM/projects/demo/.git")

# 1. The parent home takes the pool's first copy, and its worker exits.
out=$(spawn_task "$MAIN" main-a)
expect_code 0 "$?" "the parent home's first spawn should launch"$'\n'"$out"
MAIN_COPY=$(copy_of "$MAIN" main-a)
assert_equals "$MAIN_CLONE" "$(clone_of "$MAIN_COPY")" "the parent's copy should belong to the parent's clone"
stop_task main-a
wait_available "$MAIN_COPY" || fail "the parent's copy never became available after its worker exited"

# 2. The secondmate spawns while the parent's copy is the idle one on offer.
out=$(spawn_task "$SM" sm-a)
expect_code 0 "$?" "a secondmate spawn must launch from its own clone while the parent's copy is idle"$'\n'"$out"
SM_COPY=$(copy_of "$SM" sm-a)
assert_not_equals "$(physical "$MAIN_COPY")" "$(physical "$SM_COPY")" \
  "the secondmate was handed the parent's idle copy"
assert_equals "$SM_CLONE" "$(clone_of "$SM_COPY")" "the secondmate's copy should belong to its own clone"
assert_equals sm-a "$(claim_of "$SM_COPY")" "the secondmate's spawn should claim its own copy"
assert_equals main-a "$(claim_of "$MAIN_COPY")" "the parent's copy should keep the parent's claim"
pass "a secondmate spawn gets a copy of its own clone while the parent's copy is idle"

# 3. The parent reuses its own idle copy, which keeps it busy for step 4.
stop_task sm-a
wait_available "$SM_COPY" || fail "the secondmate's copy never became available after its worker exited"
out=$(spawn_task "$MAIN" main-b)
expect_code 0 "$?" "the parent's second spawn should launch"$'\n'"$out"
assert_equals "$(physical "$MAIN_COPY")" "$(physical "$(copy_of "$MAIN" main-b)")" \
  "the parent should reuse its own idle copy"

# 4. The parent spawns while only the secondmate's copy is idle.
wait_available "$SM_COPY" || fail "the secondmate's copy was not on offer before the parent's third spawn"
out=$(spawn_task "$MAIN" main-c)
expect_code 0 "$?" "a parent spawn must launch from its own clone while the secondmate's copy is idle"$'\n'"$out"
MAIN_COPY_C=$(copy_of "$MAIN" main-c)
assert_not_equals "$(physical "$SM_COPY")" "$(physical "$MAIN_COPY_C")" \
  "the parent was handed the secondmate's idle copy"
assert_equals "$MAIN_CLONE" "$(clone_of "$MAIN_COPY_C")" "the parent's new copy should belong to the parent's clone"
assert_equals sm-a "$(claim_of "$SM_COPY")" "the secondmate's idle copy should keep its claim"
pass "a parent spawn gets a copy of its own clone while the secondmate's copy is idle"

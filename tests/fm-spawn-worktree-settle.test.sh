#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
window_file="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}.window"
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file"; exit 0 ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" > "$window_file"
    exit 0 ;;
  kill-window) : > "$window_file"; exit 0 ;;
  has-session|new-session) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 3 ] || fail "already-settled pane took $reads reads to confirm - expected the first read, one confirmation, and the launch-boundary cwd check"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

test_unborn_head_project_is_refused_at_once() {
  local rec id out status started elapsed
  id=settle-unborn-head-z5
  rec=$(make_settle_case settle-unborn "$id" 0)
  read_settle_record "$rec"
  PROJ_DIR="$TMP_ROOT/settle-unborn/unborn-project"
  git init -q "$PROJ_DIR"

  started=$SECONDS
  out=$(run_settle_spawn "$id")
  status=$?
  elapsed=$((SECONDS - started))
  expect_code 1 "$status" "spawn into a project with no commit should be refused"
  assert_contains "$out" "unborn HEAD" "the refusal did not name the unborn HEAD cause"
  assert_contains "$out" "make one commit" "the refusal did not name the remedy"
  [ "$elapsed" -lt 30 ] || fail "refusal took ${elapsed}s instead of failing before the treehouse wait"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  [ -z "$(git -C "$PROJ_DIR" rev-list --all 2>/dev/null)" ] || fail "spawn committed into the project"
  pass "a project with an unborn HEAD is refused at once with its cause named"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_unborn_head_project_is_refused_at_once

# The Herdr CLI is entirely fake, with shells on a private tmux socket so the
# acquisition command really executes. No real Herdr session is inspected or
# changed. Unlike a canned cwd response, this catches an exited Treehouse
# command that leaves the outer shell sitting in the project.
#
# treehouse_failure_setup <case> <presentation-mode> builds the case's home,
# project and fakebin, exports the fixture environment, and starts the private
# tmux server. The caller writes "$fakebin/treehouse" afterwards.
treehouse_failure_setup() {
  local mode=$2
  case_dir="$TMP_ROOT/treehouse-failure-$1"
  home="$case_dir/home"
  proj="$case_dir/project"
  fakebin="$case_dir/fakebin"
  fm_test_spawn_home "$home" codex
  fm_git_init_commit "$proj"
  fm_test_spawn_brief "$home" "fail-$1"
  mkdir -p "$fakebin" "$case_dir/herdr" "$case_dir/user"
  cp "$ROOT/tests/herdr-spawn-fixture.py" "$fakebin/herdr"
  chmod +x "$fakebin/herdr"
  export FM_HERDR_FIXTURE="$case_dir/herdr" FM_FIXTURE_TMUX
  FM_FIXTURE_TMUX=$(command -v tmux)
  export FM_FIXTURE_SOCKET="fm-acquire-$1-$$"
  trap '"$FM_FIXTURE_TMUX" -L "$FM_FIXTURE_SOCKET" kill-server >/dev/null 2>&1 || true' EXIT
  unset TMUX TMUX_PANE HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_WORKSPACE_ID HERDR_TAB_ID FM_BACKEND_HERDR_BIN FM_BACKEND_HERDR_CLIENT_SESSION TREEHOUSE_DIR
  export HOME="$case_dir/user" SHELL=/bin/bash HERDR_SESSION=fixture PATH="$fakebin:$PATH"
  "$FM_FIXTURE_TMUX" -L "$FM_FIXTURE_SOCKET" -f /dev/null new-session -d -s fixture -c "$proj" 'bash --noprofile --norc'
  cat > "$FM_HERDR_FIXTURE/state.json" <<'EOF'
{"next":2,"workspaces":[{"workspace_id":"w1","label":"firstmate","active_tab_id":"w1:t1","focused":true}],"tabs":[{"tab_id":"w1:t1","pane_id":"w1:p1","workspace_id":"w1","label":"terminal","target":"%0","focused":true}]}
EOF
  printf 'herdr\n' > "$home/config/backend"
  if [ "$mode" = off ]; then
    printf 'off\n' > "$home/config/herdr-presentation-spaces"
  else
    printf 'on\n' > "$home/config/herdr-presentation-spaces"
  fi
  if [ "$mode" = stale ]; then
    printf 'version=1\ntask_id=fail-%s\nprojection_id=AbCdEfGhIjKlMnOpQrStUv\n' "$1" > "$home/state/fail-$1.herdr-presentation"
  fi
}

treehouse_failure_spawn() { # <case>
  FM_HOME="$home" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "fail-$1" "$proj" --mode no-mistakes --yolo off 2>&1
}

# treehouse_failure_pane <case> prints the worker's tmux target, failing when
# the spawn closed it or did not keep it in its own workspace.
treehouse_failure_pane() {
  local target
  jq -e '[.tabs[] | select(.workspace_id == "w1")] | length == 1' "$FM_HERDR_FIXTURE/state.json" >/dev/null \
    || fail "fallback put a worker tab in the launcher workspace"
  target=$(jq -r --arg label "fm-fail-$1" '.tabs[] | select(.label == $label) | .target' "$FM_HERDR_FIXTURE/state.json")
  if [ -z "$target" ] || ! "$FM_FIXTURE_TMUX" -L "$FM_FIXTURE_SOCKET" list-panes -t "$target" >/dev/null 2>&1; then
    fail "failed acquisition closed its diagnostic pane"
  fi
  printf '%s\n' "$target"
}

# Treehouse can refuse an available-looking slot it cannot safely reuse.
# Its refusal controls the label; status only adds context about those slots.
# The "wrapped" pool pads the refusal so the space after "in use," is the last
# screen column; the pane capture trims it, joining the rows with no space.
test_treehouse_failure_preserves_own_workspace() (
  local mode=$1 pool=${2:-full} case_dir home proj fakebin out status target reads slot_status=in-use refusal
  treehouse_failure_setup "$mode-$pool" "$mode"
  refusal='all 1 worktrees are in use or dirty (max_trees = 1). Run treehouse status'
  if [ "$pool" != full ]; then
    refusal="all 1 worktrees are in use, dirty, or not provably this clone's (max_trees = 1). Run treehouse status"
  fi
  [ "$pool" != free ] || slot_status=available
  cat > "$fakebin/treehouse" <<EOF
#!/usr/bin/env bash
if [ "\$1" = status ]; then
  printf '[{"name":"1","status":"$slot_status"}]\n'
  exit 0
fi
pad=0 prefix='all 1 worktrees are in use,'
if [ "$pool" = wrapped ]; then
  pad=\$(( \$(stty size < /dev/tty | cut -d' ' -f2) - 1 - \${#prefix} ))
fi
printf '%*s%s\n' "\$pad" '' "$refusal" >&2
exit 17
EOF
  chmod +x "$fakebin/treehouse"
  fm_test_fake_sleep_noop "$fakebin"
  out=$(treehouse_failure_spawn "$mode-$pool")
  status=$?
  [ "$status" -ne 0 ] || fail "a failed allocation must refuse the spawn"
  assert_contains "$out" 'pool exhausted' "allocation error was hidden by a cwd timeout or status listing"$'\n'"$out"
  if [ "$pool" != free ]; then
    assert_not_contains "$out" 'would not reuse' "full pool should not report available slots"$'\n'"$out"
  else
    assert_contains "$out" 'status lists 1 available slot(s) Treehouse would not reuse' "available-looking slots must add context without hiding exhaustion"$'\n'"$out"
  fi
  assert_contains "$out" 'status 17' "spawn must report the actual Treehouse exit status"$'\n'"$out"
  [ ! -e "$home/state/fail-$mode-$pool.meta" ] || fail "failed acquisition published metadata"
  reads=$(jq -s '[.[] | select(.[0:2] == ["pane", "get"])] | length' "$FM_HERDR_FIXTURE/calls.jsonl")
  [ "$reads" -lt 60 ] || fail "an exited allocation waited for the entire cwd deadline ($reads reads)"
  target=$(treehouse_failure_pane "$mode-$pool") || exit 1
  assert_contains "$("$FM_FIXTURE_TMUX" -L "$FM_FIXTURE_SOCKET" capture-pane -p -t "$target" -S -100)" 'max_trees = 1' 'allocation output must remain readable'
  assert_contains "$(cat "$home/data/fail-$mode-$pool"/treehouse.*/pane.log)" 'max_trees = 1' 'allocation output must be saved durably'
  if [ "$pool" = wrapped ]; then
    assert_not_contains "$(cat "$home/data/fail-$mode-$pool"/treehouse.*/pane.log)" 'in use, dirty' 'the refusal must be split by a screen wrap'
  fi
  pass "Treehouse failure ($mode, $pool pool): prompt error, separate workspace, retained pane and log"
)

# At the deadline the allocation is interrupted rather than left to finish in
# an orphan pane. "allocating" never returns from allocation; "entered" opens
# its subshell (outside any git worktree, so never accepted) and holds the slot
# until that subshell exits. Either way no slot stays held, and the pane stays.
# The fake sleep returns at once, but only after the stub reached that point.
test_treehouse_deadline_interrupts_allocation() (
  local stage=$1 case_dir home proj fakebin out status target pane real_sleep
  real_sleep=$(command -v sleep)
  export FM_TEST_TH_CASE="$TMP_ROOT/treehouse-failure-deadline-$stage" FM_TEST_TH_SLEEP="$real_sleep"
  treehouse_failure_setup "deadline-$stage" projected
  cat > "$fakebin/sleep" <<'EOF'
#!/usr/bin/env bash
if compgen -G "$FM_TEST_TH_CASE/home/data/*/treehouse.*/get.sh" >/dev/null; then
  for _ in $(seq 1 200); do
    [ -e "$FM_TEST_TH_CASE/ready" ] && exit 0
    "$FM_TEST_TH_SLEEP" 0.05
  done
fi
exit 0
EOF
  if [ "$stage" = allocating ]; then
    cat > "$fakebin/treehouse" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_TEST_TH_CASE/slot"
: > "$FM_TEST_TH_CASE/ready"
exec "$FM_TEST_TH_SLEEP" 600
EOF
  else
    cat > "$fakebin/treehouse" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$FM_TEST_TH_CASE/slot.d"
printf '%s\n' "$$" > "$FM_TEST_TH_CASE/slot"
(cd "$FM_TEST_TH_CASE/slot.d" && TREEHOUSE_DIR="$PWD" PROMPT_COMMAND=": > '$FM_TEST_TH_CASE/ready'" exec bash --noprofile --norc -i)
rm -f "$FM_TEST_TH_CASE/slot"
EOF
  fi
  chmod +x "$fakebin/sleep" "$fakebin/treehouse"
  out=$(treehouse_failure_spawn "deadline-$stage")
  status=$?
  [ "$status" -ne 0 ] || fail "an allocation that never settled must refuse the spawn"
  assert_contains "$out" 'within 60s' "spawn must report the deadline"$'\n'"$out"
  [ ! -e "$home/state/fail-deadline-$stage.meta" ] || fail "timed-out acquisition published metadata"
  pane=$(jq -r '.tabs[] | select(.label == "fm-fail-deadline-'"$stage"'") | .pane_id' "$FM_HERDR_FIXTURE/state.json")
  jq -e --arg pane "$pane" 'select(.[0:3] == ["pane", "send-keys", $pane] and any(.[]; . == "ctrl+c"))' \
    "$FM_HERDR_FIXTURE/calls.jsonl" >/dev/null || fail "the kept pane was not sent Ctrl-C at the deadline"
  if [ "$stage" = allocating ]; then
    for _ in $(seq 1 100); do
      kill -0 "$(cat "$case_dir/slot")" 2>/dev/null || break
      "$real_sleep" 0.1
    done
    ! kill -0 "$(cat "$case_dir/slot")" 2>/dev/null || fail "the interrupted allocation is still running"
  else
    for _ in $(seq 1 100); do
      [ -e "$case_dir/slot" ] || break
      "$real_sleep" 0.1
    done
    [ ! -e "$case_dir/slot" ] || fail "the opened Treehouse subshell still holds its slot"
  fi
  target=$(treehouse_failure_pane "deadline-$stage") || exit 1
  [ "$("$FM_FIXTURE_TMUX" -L "$FM_FIXTURE_SOCKET" display-message -p -t "$target" '#{pane_current_path}')" = "$proj" ] \
    || fail "the kept pane did not return to its own shell"
  pass "Treehouse deadline ($stage): allocation interrupted, no slot held, pane retained"
)

if command -v tmux >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  test_treehouse_failure_preserves_own_workspace off || exit 1
  test_treehouse_failure_preserves_own_workspace stale || exit 1
  test_treehouse_failure_preserves_own_workspace projected || exit 1
  test_treehouse_failure_preserves_own_workspace projected free || exit 1
  test_treehouse_failure_preserves_own_workspace projected wrapped || exit 1
  test_treehouse_deadline_interrupts_allocation allocating || exit 1
  test_treehouse_deadline_interrupts_allocation entered || exit 1
else
  echo '# skip: real-shell acquisition regressions need tmux, python3, and jq'
fi

echo "# all fm-spawn-worktree-settle tests passed"

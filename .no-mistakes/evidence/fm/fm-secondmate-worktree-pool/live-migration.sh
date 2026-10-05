#!/usr/bin/env bash
set -eu
ROOT=$PWD
BASE="$ROOT/.nm-test/migration"
trap 'rm -rf "$BASE"' EXIT
export TREEHOUSE_ROOT="$BASE/pools" TREEHOUSE_NO_UPDATE_CHECK=1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$BASE/main/demo" "$BASE/local-trust"
git -C "$BASE/main/demo" init -q
git -C "$BASE/main/demo" config user.name 'Live Test'
git -C "$BASE/main/demo" config user.email live-test@example.invalid
printf 'migration fixture\n' > "$BASE/main/demo/README.md"
git -C "$BASE/main/demo" add README.md
git -C "$BASE/main/demo" -c commit.gpgsign=false commit -qm init
git clone -q --bare "$BASE/main/demo" "$BASE/origin/demo.git"
git -C "$BASE/main/demo" remote add origin "file://$BASE/origin/demo.git"
git clone -q "file://$BASE/origin/demo.git" "$BASE/secondmate/demo"
OLD="$ROOT/.nm-test/releases/2.3.0/treehouse"
BAD="$ROOT/.nm-test/releases/3.0.0/treehouse"
ADOPT="$ROOT/.nm-test/releases/3.0.1/treehouse"
CURRENT="$ROOT/.nm-test/install/treehouse"
cd "$BASE/main/demo"
printf '\n=== Create and return a pre-3.0 parent copy ===\n'
copy=$("$OLD" get --lease --no-fetch)
"$OLD" return "$copy"
"$OLD" status --json
printf '\n=== Historical dependency reuses the parent copy for a secondmate ===\n'
cd "$BASE/secondmate/demo"
wrong=$("$OLD" get --lease --no-fetch)
printf 'Parent copy: %s\nSecondmate acquired: %s\n' "$copy" "$wrong"
[ "$copy" = "$wrong" ]
set +e
CLAUDE_CONFIG_DIR="$BASE/local-trust" "$ROOT/bin/fm-claude-trust.sh" "$wrong" "$BASE/secondmate/demo"
rc=$?
set -e
printf 'Expected cross-clone trust refusal exit: %s\n' "$rc"
[ "$rc" -ne 0 ]
"$OLD" return "$wrong"
printf '\n=== Treehouse 3.0.0 rewrites the old pool as recovered leases ===\n'
"$BAD" status --json | tee "$BASE/quarantine.json"
jq -e 'length > 0 and all(.[]; .status == "leased" and (.lease_holder | startswith("recovered:")))' "$BASE/quarantine.json" >/dev/null
printf '\n=== Treehouse 3.0.1 still leaves the quarantine leased ===\n'
"$ADOPT" status --json | tee "$BASE/adopt.json"
jq -e 'all(.[]; .status == "leased")' "$BASE/adopt.json" >/dev/null
printf '\n=== Treehouse 3.1.0 automatically restores the safe recovered copy ===\n'
"$CURRENT" status --json | tee "$BASE/recovered.json"
jq -e 'all(.[]; .status == "available" and .lease_holder == "")' "$BASE/recovered.json" >/dev/null
cd "$BASE/main/demo"
reused=$("$CURRENT" get --lease --no-fetch)
printf 'Recovered copy acquired by its original clone: %s\n' "$reused"
[ "$reused" = "$copy" ]
"$CURRENT" return "$reused"
printf '\nLIVE_RECOVERY_SCENARIOS_COMPLETED\n'

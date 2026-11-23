#!/usr/bin/env bash
# Execute the primary launch helper with probe harnesses, including config
# override, unsupported pass-through, argument boundaries and invalid input.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAB=$(fm_test_tmproot fm-context-launch)
mkdir -p "$LAB/bin" "$LAB/config" "$LAB/other"
for harness in claude codex pi; do
  cat > "$LAB/bin/$harness" <<'SH'
#!/usr/bin/env bash
printf 'window=%s\n' "${CLAUDE_CODE_AUTO_COMPACT_WINDOW-unset}"
printf 'arg=<%s>\n' "$@"
SH
  chmod +x "$LAB/bin/$harness"
done
launch() {
  env -u CLAUDE_CODE_AUTO_COMPACT_WINDOW PATH="$LAB/bin:$PATH" \
    FM_CONFIG_OVERRIDE="$LAB/config" "$ROOT/bin/fm-context-launch.sh" "$@"
}

out=$(launch claude 'one argument') || fail 'Claude primary launch failed'
assert_contains "$out" 'window=200000' 'Claude primary default'
assert_contains "$out" 'arg=<one argument>' 'primary argument boundaries'
out=$(launch codex 'one argument') || fail 'Codex primary launch failed'
assert_contains "$out" 'arg=<model_auto_compact_token_limit=200000>' 'Codex primary default'
assert_contains "$out" 'arg=<model_auto_compact_token_limit_scope="total">' 'Codex counts the full context'
assert_contains "$out" 'arg=<one argument>' 'Codex argument boundaries'
pass 'primary launch defaults reach both native harnesses'

printf '180000\n' > "$LAB/config/context-cap"
for harness in claude codex; do
  out=$(launch "$harness") || fail "$harness override failed"
  assert_contains "$out" 180000 "$harness home config override"
done
printf '150000\n' > "$LAB/other/context-cap"
out=$(launch --config-dir "$LAB/other" claude)
assert_contains "$out" 'window=150000' 'explicit config directory takes precedence'
out=$(env -u FM_CONFIG_OVERRIDE PATH="$LAB/bin:$PATH" FM_HOME="$LAB" \
  "$ROOT/bin/fm-context-launch.sh" claude)
assert_contains "$out" 'window=180000' 'FM_HOME config resolution'
out=$(CLAUDE_CODE_AUTO_COMPACT_WINDOW=900000 PATH="$LAB/bin:$PATH" \
  "$ROOT/bin/fm-context-launch.sh" --config-dir "$LAB/config" claude)
assert_contains "$out" 'window=180000' 'home threshold replaces ambient window'
pass 'home, explicit directory and ambient precedence use one threshold'

for bad in '' 0 99999 1000001 0200000 200k '200000 300000' $'200000\n300000'; do
  printf '%s\n' "$bad" > "$LAB/config/context-cap"
  out=$(launch claude 2>&1)
  expect_code 1 "$?" 'invalid threshold must refuse launch'
  assert_contains "$out" 'config/context-cap' 'invalid threshold diagnostic'
done
out=$(launch pi 'one argument') || fail 'unsupported harness must ignore invalid config'
assert_equals $'window=unset\narg=<one argument>' "$out" 'unsupported harness launch stays unchanged'
pass 'invalid thresholds refuse supported launches; unsupported harnesses pass through'

printf '200000\n' > "$LAB/config/context-cap"
for harness in claude codex; do
  prefix=$(launch --print-command "$harness") || fail 'prefix generation failed'
  out=$(env -u CLAUDE_CODE_AUTO_COMPACT_WINDOW PATH="$LAB/bin:$PATH" /bin/sh -c "$prefix 'one argument'")
  expected=$(launch "$harness" 'one argument')
  assert_equals "$expected" "$out" 'emitted POSIX launch matches primary execution'
done
pass 'spawn prefixes execute with the same settings as primary launches'

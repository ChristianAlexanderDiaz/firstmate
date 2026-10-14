#!/usr/bin/env bash
# fm-worker-account-lib.sh - the single owner of the opt-in per-home worker
# account pin: which runners can be pinned, how a pin file is parsed and
# resolved, the launch-time sign-in check under it, and the environment
# credentials a pinned Claude launch sheds. It also owns the opt-in Claude
# account failover map (config/claude-failover): how that file is parsed and
# how one of its named accounts resolves to the Claude config root a moved
# worker launches under, and model-aware quota eligibility; and Claude account
# pacing, the `paced` pin value that picks one qualifying account per launch
# and refuses when none qualifies.
#
# docs/configuration.md "Worker account pin", "Claude account failover", and
# "Claude account pacing" own the operator-facing contracts.
# Sourced by bin/fm-spawn.sh, bin/fm-control.sh, and bin/fm-account-failover.sh.
#
# Pinnable runners, each a credential store inside a root its vendor lets a
# process select:
#   claude          CLAUDE_CONFIG_DIR     config/claude-account
#   pi, pi-signed   PI_CODING_AGENT_DIR   config/pi-account
#
# The pin is opt-in: an absent file is no pin, and the launch keeps today's
# ambient behavior byte for byte. A present file must resolve, or the launch
# refuses; nothing falls back to an ambient or vendor-default login once a
# home has declared one. `ordinary` selects the vendor default: for Claude
# that is CLAUDE_CONFIG_DIR unset, because Claude reads $CLAUDE_CONFIG_DIR/
# .claude.json and keys its macOS Keychain entry to any CLAUDE_CONFIG_DIR that
# is set, even $HOME/.claude; for Pi it is $HOME/.pi/agent. Any other value is
# one absolute path to an existing readable, searchable directory. Firstmate
# never copies credentials or changes a global login. For Claude only, `paced`
# fixes no account: each ship and scout launch picks one account of
# config/claude-failover instead (fm_worker_account_pace below), and every
# other Claude launch keeps today's ambient behavior.
#
# A Pi root can hold several provider identities, so config/pi-account names
# the root on line 1 and the providers that home may spend on line 2,
# separated by spaces. A pinned Pi launch must name its provider explicitly as
# --model <provider>/<id>, and that provider must be declared; Firstmate never
# guesses a provider for an unqualified model. The canonical launch also
# passes --provider <that provider>, because without it Pi may resolve a
# provider-prefixed model under another authenticated provider. A raw Pi
# launch command is launched verbatim and cannot receive that flag, so a home
# with config/pi-account refuses raw Pi launches. A raw Claude launch command
# runs after the pinned root and shed credentials are applied, so its own
# leading CLAUDE_CONFIG_DIR or shed-credential assignment would override the
# pin; a home with a fixed config/claude-account pin refuses such a command.
#
# The sign-in check asks the runner itself, with only HOME, PATH, TMPDIR,
# USER, LOGNAME, and the selected root in its environment, so a credential
# variable left in the caller cannot answer for a root that has no login:
#   Claude: `claude auth status`, which exits 0 only when signed in.
#   Pi:     `pi auth check --provider <p> --json --no-refresh`; status "ready"
#           passes. `pi auth check` loads no extensions, so it answers
#           not_ready/provider_not_found for an extension-registered provider,
#           and a Pi without the command (before 0.84.1) prints no JSON. Both
#           fall through to `pi --list-models <p>`, which lists only the models
#           a root can authenticate; a row whose provider column is exactly
#           <p> passes. --no-refresh keeps the check from rewriting a root's
#           tokens while other workers use them.
# A pinned Claude launch also unsets the environment credentials Claude ranks
# above the root's stored login, so an ambient API key or token cannot outrank
# the pin. Pi ranks a root's stored credentials above environment variables,
# and the check refuses a provider the root has not stored, so a pinned Pi
# launch unsets nothing.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_WORKER_ACCOUNT_CHECK_SECONDS=${FM_WORKER_ACCOUNT_CHECK_SECONDS:-30}

# Credentials Claude Code ranks above the /login stored in its config root
# (code.claude.com/docs/en/authentication, "Authentication precedence"; the
# Claude Platform on AWS and Bedrock Mantle switches from
# code.claude.com/docs/en/env-vars).
FM_WORKER_ACCOUNT_CLAUDE_SHED="CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_FEDERATION_RULE_ID"

# fm_worker_account_file <harness>
# Prints the pin file name for a pinnable runner; returns 1 for any other.
fm_worker_account_file() {
  case "$1" in
  claude) printf '%s\n' claude-account ;;
  pi | pi-signed) printf '%s\n' pi-account ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_read <harness> <file>
# Prints "declared<TAB>providers" for a valid pin, where declared is
# `ordinary`, Claude's `paced`, or the absolute path and providers is empty for
# Claude. The final
# newline is optional; any other control byte, including a CR, is malformed.
# Parses bytes before the shell can drop NULs or trailing newlines; paths are
# literal, never shell expressions. Returns 0 on success, 3 when the file does
# not exist, 4 when it cannot be inspected (one error already printed), 5 when
# it is not a readable regular file, and 6 when it is malformed.
fm_worker_account_read() {
  perl -MErrno=ENOENT -e '
    my ($harness, $f) = @ARGV;
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    if ($harness eq "claude") {
      $body =~ /\A(ordinary|paced|\/[^\x00-\x1f\x7f]*)\n?\z/ or exit 6;
      print $1, "\t";
    } else {
      $body =~ /\A(ordinary|\/[^\x00-\x1f\x7f]*)\n([A-Za-z0-9][A-Za-z0-9._-]*(?: +[A-Za-z0-9][A-Za-z0-9._-]*)*)\n?\z/ or exit 6;
      print $1, "\t", $2;
    }
  ' -- "$1" "$2"
}

# fm_worker_account_resolve <harness> <config-dir>
# Prints "declared<TAB>root<TAB>providers" for a valid pin, where root is the
# directory the launch selects (empty for ordinary Claude, meaning
# CLAUDE_CONFIG_DIR unset). Prints nothing and returns 0 when the runner is
# not pinnable, the home has no pin, or the Claude pin is `paced`, which fixes
# no account. On refusal prints one error naming the file and returns 1.
fm_worker_account_resolve() {
  local harness=$1 config=$2 file cfg token rc declared root fallback
  file=$(fm_worker_account_file "$harness") || return 0
  cfg="$config/$file"
  token=$(fm_worker_account_read "$harness" "$cfg")
  rc=$?
  case "$rc" in
  0) ;;
  3) return 0 ;;
  4) return 1 ;;
  5)
    echo "error: config/$file must be a readable regular file: $cfg" >&2
    return 1
    ;;
  *)
    if [ "$file" = pi-account ]; then
      echo "error: config/$file must hold 'ordinary' or one absolute path on line 1 and the providers this home may spend on line 2, separated by spaces, with no other lines or control characters: $cfg" >&2
    else
      echo "error: config/$file must hold 'ordinary', 'paced', or one absolute path on a single line with no control characters: $cfg" >&2
    fi
    return 1
    ;;
  esac
  declared=${token%%$'\t'*}
  [ "$declared" != paced ] || return 0
  root=$declared
  # shellcheck disable=SC2088  # The fallbacks are literal text for the refusal.
  case "$harness" in
  claude) fallback='~/.claude with CLAUDE_CONFIG_DIR unset' ;;
  *) fallback='~/.pi/agent' ;;
  esac
  if [ "$declared" = ordinary ]; then
    case "$harness" in
    claude) root= ;;
    *) root="${HOME:?HOME is required to resolve an ordinary Pi account}/.pi/agent" ;;
    esac
  fi
  if [ -n "$root" ] && { [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; }; then
    echo "error: config/$file must name a readable, searchable existing directory (ordinary means $fallback): $cfg -> $root" >&2
    return 1
  fi
  printf '%s\t%s\t%s\n' "$declared" "$root" "${token#*$'\t'}"
}

# fm_worker_account_pi_provider <model>
# Prints the provider an explicit Pi --model <provider>/<id> names. Returns 1,
# silently, for anything else, so no caller can fall back to a guess.
fm_worker_account_pi_provider() {
  local model=$1
  case "$model" in
  */*)
    [ -n "${model%%/*}" ] && [ -n "${model#*/}" ] || return 1
    printf '%s\n' "${model%%/*}"
    ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_check <harness> <declared> <root> <executable> [<provider>]
# Returns 0 only when the runner's own check says the selected root is signed
# in for this launch; otherwise prints one error and returns 1.
fm_worker_account_check() {
  local harness=$1 declared=$2 root=$3 executable=$4 provider=${5:-} out verdict name
  local -a clean=(env -i "HOME=${HOME:-}" "PATH=${PATH:-}")
  for name in TMPDIR USER LOGNAME; do
    [ -z "${!name:-}" ] || clean+=("$name=${!name}")
  done
  case "$harness" in
  claude)
    [ -z "$root" ] || clean+=("CLAUDE_CONFIG_DIR=$root")
    if fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth status >/dev/null 2>&1 </dev/null; then
      return 0
    fi
    if [ -n "$root" ]; then
      echo "error: config/claude-account pins Claude workers to $root, which is not signed in (claude auth status); sign in with CLAUDE_CONFIG_DIR=$root claude, then /login, or change the pin" >&2
    else
      echo "error: config/claude-account pins Claude workers to the ordinary account, which is not signed in (claude auth status); sign in with env -u CLAUDE_CONFIG_DIR claude, then /login, or change the pin" >&2
    fi
    return 1
    ;;
  pi | pi-signed)
    clean+=("PI_CODING_AGENT_DIR=$root")
    out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth check --provider "$provider" --json --no-refresh 2>/dev/null </dev/null)
    verdict=$(printf '%s\n' "$out" | jq -r '
      if type != "object" or (has("status") | not) then "list"
      elif .status == "ready" then "ready"
      elif .status == "not_ready" and .reason == "provider_not_found" then "list"
      else "\(.status) \(.reason // "")"
      end' 2>/dev/null)
    case "${verdict:-list}" in
    ready) return 0 ;;
    list)
      if out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
        "$executable" --list-models "$provider" 2>/dev/null </dev/null) &&
        printf '%s\n' "$out" | awk -v p="$provider" 'NR > 1 && $1 == p { found = 1; exit } END { exit !found }'; then
        return 0
      fi
      verdict="no model listed for provider $provider"
      ;;
    esac
    echo "error: config/pi-account pins Pi workers to $declared, which is not signed in for provider '$provider' ($verdict); sign in with PI_CODING_AGENT_DIR=$root $harness, then /login, or change the pin" >&2
    return 1
    ;;
  esac
  return 0
}

# fm_worker_account_select <harness> <config-dir> <model> <executable> [<raw-command>]
# The whole launch-time decision. Prints nothing for an unpinned runner, so
# the caller keeps today's launch unchanged. For a pinned one prints
# "declared<TAB>root<TAB>provider", where provider is the Pi launch model's
# own (empty for Claude), after the model guard and the sign-in check pass. On
# refusal prints one error and returns 1. bin/fm-spawn.sh runs it before any
# endpoint exists, and bin/fm-control.sh before a relaunch stops the live
# agent.
fm_worker_account_select() {
  local harness=$1 config=$2 model=$3 executable=$4 raw=${5:-} selection declared root providers word provider=
  selection=$(fm_worker_account_resolve "$harness" "$config") || return 1
  [ -n "$selection" ] || return 0
  declared=${selection%%$'\t'*}
  root=${selection#*$'\t'}
  providers=${root#*$'\t'}
  root=${root%%$'\t'*}
  if [ "$harness" = claude ]; then
    for word in $raw; do
      case "$word" in
      [A-Za-z_]*=*)
        case " CLAUDE_CONFIG_DIR $FM_WORKER_ACCOUNT_CLAUDE_SHED " in
        *" ${word%%=*} "*)
          echo "error: config/claude-account pins Claude workers, but the raw launch command sets ${word%%=*}, which would override the pinned account; remove ${word%%=*} from the raw command, or change or remove config/claude-account" >&2
          return 1
          ;;
        esac
        ;;
      *) break ;;
      esac
    done
  else
    if [ -n "$raw" ]; then
      echo "error: config/pi-account pins Pi workers, and a raw Pi launch command runs verbatim, so it cannot carry the pinned --provider; launch with --harness $harness and --model <provider>/<id> instead" >&2
      return 1
    fi
    provider=$(fm_worker_account_pi_provider "$model") || {
      echo "error: config/pi-account pins Pi workers to providers ($providers), so a Pi launch needs --model <provider>/<id> naming one of them; '${model:-none}' names no provider, and Firstmate does not guess one" >&2
      return 1
    }
    case " $providers " in
    *" $provider "*) ;;
    *)
      echo "error: config/pi-account pins Pi workers to providers ($providers), but --model '$model' names provider '$provider'" >&2
      return 1
      ;;
    esac
  fi
  fm_worker_account_check "$harness" "$declared" "$root" "$executable" "$provider" || return 1
  printf '%s\t%s\t%s\n' "$declared" "$root" "$provider"
}

# fm_worker_account_claude_shed
# Prints the `env` launch prefix that unsets the environment credentials Claude
# ranks above a pinned root's stored login. The caller appends the root
# assignment, or -u CLAUDE_CONFIG_DIR for the ordinary account.
fm_worker_account_claude_shed() {
  local var prefix=env
  for var in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do
    prefix="$prefix -u $var"
  done
  printf '%s\n' "$prefix"
}

# --- Claude account failover map (config/claude-failover) --------------------
#
# Opt-in; an absent file is no failover. The file names the Claude accounts a
# worker may be moved between, each by the account name `quota-axi
# --all-accounts` reports for it:
#   account <name> <ordinary | absolute CLAUDE_CONFIG_DIR>
# Blank lines and lines starting with # are ignored. `ordinary` means
# CLAUDE_CONFIG_DIR unset, for the same Keychain reason the pin above gives.
# Names are [A-Za-z0-9][A-Za-z0-9._-]* and unique; a path is the rest of its
# line, absolute, with no control characters.

FM_WORKER_ACCOUNT_FAILOVER_FILE=claude-failover

# fm_worker_account_failover_read <file>
# Prints one "account<TAB><name><TAB><declared>" line per account in file
# order. Returns 0 on success, 3 when the file does not exist, 4 when it cannot be inspected
# (one error already printed), 5 when it is not a readable regular file, and 6
# when it is malformed (one error naming the line already printed).
fm_worker_account_failover_read() {
  perl -MErrno=ENOENT -e '
    my ($f) = @ARGV;
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my (%seen, @accounts);
    my $n = 0;
    while (my $line = <$fh>) {
      $n++;
      $line =~ s/\n\z//;
      my $bad = sub { print STDERR "error: config/claude-failover line $n: $_[0]: $f\n"; exit 6 };
      $bad->("control characters are not allowed") if $line =~ /[\x00-\x1f\x7f]/;
      next if $line =~ /\A\s*(?:#.*)?\z/;
      if ($line =~ /\Aaccount +([A-Za-z0-9][A-Za-z0-9._-]*) +(ordinary|\/.*?) *\z/) {
        $bad->("account $1 is named twice") if $seen{$1}++;
        push @accounts, "account\t$1\t$2\n";
      } else {
        $bad->("expected \"account <name> <ordinary|/absolute/path>\"");
      }
    }
    print @accounts;
  ' -- "$1"
}

# fm_worker_account_failover_load <config-dir>
# Prints the parsed map for this home (the read format above). Prints nothing
# and returns 0 when the home has no map. On refusal prints one error and
# returns 1.
fm_worker_account_failover_load() {
  local cfg="$1/$FM_WORKER_ACCOUNT_FAILOVER_FILE" out rc
  out=$(fm_worker_account_failover_read "$cfg")
  rc=$?
  case "$rc" in
  0) printf '%s\n' "$out" ;;
  3) return 0 ;;
  5)
    echo "error: config/$FM_WORKER_ACCOUNT_FAILOVER_FILE must be a readable regular file: $cfg" >&2
    return 1
    ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_failover_resolve <config-dir> <name> [parsed-map]
# Prints "declared<TAB>root" for one named account of this home's map, where
# root is empty for `ordinary` (CLAUDE_CONFIG_DIR unset). Refuses, printing one
# error and returning 1, when the home has no map, the map is malformed, it
# does not name the account, the account's root is unusable, or the home also
# pins every Claude worker to one account with config/claude-account, because a
# moved worker would break that pin (a `paced` pin fixes no account).
fm_worker_account_failover_resolve() {
  local config=$1 name=$2 map=${3:-} line declared root
  if { [ -e "$config/claude-account" ] || [ -L "$config/claude-account" ]; } \
    && ! fm_worker_account_paced "$config"; then
    echo "error: config/claude-account pins every Claude worker in this home to one account, so a worker cannot run on failover account '$name'; remove one of config/claude-account and config/$FM_WORKER_ACCOUNT_FAILOVER_FILE" >&2
    return 1
  fi
  if [ -z "$map" ]; then
    map=$(fm_worker_account_failover_load "$config") || return 1
  fi
  [ -n "$map" ] || {
    echo "error: this home has no config/$FM_WORKER_ACCOUNT_FAILOVER_FILE, so Claude account '$name' names nothing" >&2
    return 1
  }
  line=$(printf '%s\n' "$map" | awk -F'\t' -v n="$name" '$1 == "account" && $2 == n { print; exit }')
  [ -n "$line" ] || {
    echo "error: config/$FM_WORKER_ACCOUNT_FAILOVER_FILE names no Claude account '$name'" >&2
    return 1
  }
  declared=${line#account$'\t'"$name"$'\t'}
  root=$declared
  [ "$declared" != ordinary ] || root=
  if [ -n "$root" ] && { [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; }; then
    echo "error: config/$FM_WORKER_ACCOUNT_FAILOVER_FILE account '$name' must name a readable, searchable existing directory (ordinary means ~/.claude with CLAUDE_CONFIG_DIR unset): $root" >&2
    return 1
  fi
  printf '%s\t%s\n' "$declared" "$root"
}

# fm_worker_account_failover_quota <map-text> <snapshot-json> <current> <model>
# Prints one JSON array of per-account verdicts in map order.
fm_worker_account_failover_quota() {
  local map=$1 snapshot=$2 current=$3 model=$4 names
  names=$(printf '%s\n' "$map" | awk -F'\t' '$1 == "account" { print $2 }' | jq -R . | jq -sc .)
  printf '%s' "$snapshot" | jq -c --argjson names "$names" \
    --arg current "$current" --arg model "$model" '
    def short_time: if type == "string" then sub("\\.[0-9]+"; "") | sub(":[0-9]{2}(\\+00:00|Z)$"; "Z") else null end;
    def model_family:
      if type != "string" then null
      else ascii_downcase | gsub("\\."; "-") |
        [capture("^(?:claude-(?:[0-9]+-)*)?(?<family>opus|sonnet|fable|haiku)(?:-[0-9]+)*(?:-latest)?$").family] | first // null
      end;
    ($model | ascii_downcase | sub("\\[1m\\]$"; "")) as $model_name |
    (if $model_name == "opusplan" then ["opus", "sonnet"]
     elif $model_name == "best" then ["fable", "opus"]
     else
       [$model_name | model_family | select(. != null)] |
       if length == 0 then null
       elif . == ["haiku"] then ["haiku", "sonnet"]
       else . end
     end) as $families |
    . as $snap |
    if (($snap | type) != "object") or (($snap.providers | type) != "array") then error("snapshot has no providers array") else . end |
    [ $names | to_entries[] | .key as $order | .value as $name |
      [ $snap.providers[] | select(type == "object" and .provider == "claude" and .account == $name) ] as $rows |
      { name: $name, order: $order } +
      (if ($rows | length) == 0 then { ok: false, why: "no quota reading for this account" }
      elif ($rows | length) > 1 then { ok: false, why: "more than one quota reading for this account" }
      else
        $rows[0] as $row |
        ([ ($row.windows // [])[] | select(type == "object") ]) as $windows |
        ([ ($row.quotaSemantics.effectiveAvailability // [])[] | select(type == "object") |
           (.scope | if type == "string" then ascii_downcase | sub("^model:"; "") | sub("^seven_day_opus$"; "opus") else . end | model_family) as $family |
           select(.scope == "all_models" or $families == null or $family == null or ($families | index($family)) != null) ]) as $scopes |
        if ($row.state.stale // false) == true then { ok: false, why: "its quota reading is stale" }
        elif ([ $scopes[] | select(.scope == "all_models") ] | length) != 1 then { ok: false, why: "its all-models quota is unknown" }
        elif any($scopes[]; .status != "known" or ((.effectivePercentRemaining | type) != "number")) then { ok: false, why: "its quota is unknown" }
        else
          ($scopes | min_by(.effectivePercentRemaining)) as $limiting |
          ($limiting.runway.limitingWindowId // (($limiting.limitingWindowIds // [])[0])) as $wid |
          ([ $windows[] | select(.id == $wid) ][0].resetsAt | short_time) as $resets |
          ([ $windows[] | select(.kind == "credits") | .id ]) as $credit_ids |
          { percent: $limiting.effectivePercentRemaining, resets: $resets,
            spend: (if ($limiting.selection.status // "") == "known" and (($limiting.selection.spendPriority | type) == "number")
                    then $limiting.selection.spendPriority else null end) } +
          if any($scopes[]; (.boundedBy // []) as $b | any($credit_ids[]; . as $c | ($b | index($c)) != null))
          then { ok: false, why: "its availability counts paid usage credits" }
          elif any($scopes[]; (.runway.status // "") == "exhausted_now") then { ok: false, why: "it is exhausted now" }
          elif $limiting.effectivePercentRemaining <= 5 then { ok: false, why: "at or below the 5% safety margin" }
          else { ok: true } end
        end
      end) |
      if $name == $current then .ok = false | .why = "the account the worker just ran out on" else . end ]'
}

# fm_worker_account_failover_select <config-dir> <name> <executable> <model>
#                                   [snapshot-json] [parsed-map]
# The launch-time decision for a worker recorded on a failover account: the
# resolve above, the same sign-in check a pin gets, and a fresh quota reading
# proving paid usage disabled and model quota above the fixed safety margin;
# reused readings refuse. Without a supplied snapshot, reads
# quota-axi --all-accounts --json at launch with QUOTA_AXI_MAX_AGE unset, so
# the vendor is asked (--all-accounts refuses --max-age). Prints
# "declared<TAB>root" on success; on refusal prints one error and returns 1.
fm_worker_account_failover_select() {
  local config=$1 name=$2 executable=$3 model=$4 snapshot=${5:-} map=${6:-} selection declared root verdict reason
  selection=$(fm_worker_account_failover_resolve "$config" "$name" "$map") || return 1
  declared=${selection%%$'\t'*}
  root=${selection#*$'\t'}
  if ! fm_worker_account_check claude "$declared" "$root" "$executable" 2>/dev/null; then
    echo "error: config/$FM_WORKER_ACCOUNT_FAILOVER_FILE account '$name' ($declared) is not signed in (claude auth status); sign in to it, or remove it from the map" >&2
    return 1
  fi
  if [ -z "$snapshot" ]; then
    snapshot=$(fm_run_timed "${FM_ACCOUNT_FAILOVER_QUOTA_SECONDS:-90}" env -u QUOTA_AXI_MAX_AGE quota-axi --all-accounts --json 2>/dev/null </dev/null) || {
      echo "error: Claude account '$name' paid usage could not be checked" >&2
      return 1
    }
  fi
  if ! printf '%s' "$snapshot" | jq -e --arg name "$name" '
    [.providers[] | select(.provider == "claude" and .account == $name)] |
    length == 1 and (.[0] | .state.status == "fresh" and .state.stale != true and .state.reused != true
      and .quotaSemantics.status == "known" and (.windows | type) == "array"
      and any(.windows[]; .kind == "session" or .kind == "weekly")
      and all(.windows[]; .kind != "credits" and .id != "extra_usage"))' >/dev/null 2>&1; then
    echo "error: Claude account '$name' has paid usage enabled or its paid usage status is unknown" >&2
    return 1
  fi
  verdict=$(fm_worker_account_failover_quota "$(printf 'account\t%s\n' "$name")" "$snapshot" '' "$model" 2>/dev/null) || {
    echo "error: Claude account '$name' quota could not be checked" >&2
    return 1
  }
  if ! printf '%s' "$verdict" | jq -e '.[0].ok == true' >/dev/null; then
    reason=$(printf '%s' "$verdict" | jq -r '.[0].why')
    echo "error: Claude account '$name' cannot launch: $reason" >&2
    return 1
  fi
  printf '%s\n' "$selection"
}

# --- Claude account pacing (config/claude-account `paced`) --------------------
#
# Opt-in through the pin value `paced`; every other pin value, and a home
# without the pin, never paces. Pacing spends the accounts of
# config/claude-failover so each one's weekly allowance is used before it
# resets: the account whose weekly window resets nearest gets the work while it
# is on or behind the pace that would empty it at that reset (its weekly
# reserve is zero or more), or its pace is unknown. Only affirmative
# ahead-of-pace evidence moves it behind the other accounts.
# A worker that later hits a limit still fails over through
# bin/fm-account-failover.sh.
#
# An account is choosable only when it passes every failover launch check
# (fm_worker_account_failover_select: signed in, a fresh unreused reading,
# paid usage disabled, model quota known and above the fixed 5 percent safety
# margin). A missing, stale, or unreadable reading is never choosable.

# fm_worker_account_paced <config-dir>
# Returns 0 when this home's config/claude-account selects pacing.
fm_worker_account_paced() {
  local token
  token=$(fm_worker_account_read claude "$1/claude-account" 2>/dev/null) || return 1
  [ "${token%%$'\t'*}" = paced ]
}

# fm_worker_account_pace <config-dir> <executable> <model> [snapshot-json]
# Picks the account for one Claude ship or scout launch in a paced home from
# one quota-axi --all-accounts reading (read here, with QUOTA_AXI_MAX_AGE
# unset, unless supplied). Prints
# "pick<TAB><name><TAB><declared><TAB><root><TAB><reason>" and returns 0.
# The reason is one line naming each account's week left, weekly reset, and
# pace. Prints one error and returns 1 when no account is choosable or the
# home has no usable config/claude-failover; callers must refuse the launch.
fm_worker_account_pace() {
  local config=$1 executable=$2 model=$3 snapshot=${4:-} map verdicts plan summary name selection err refused=
  map=$(fm_worker_account_failover_load "$config") || return 1
  [ -n "$map" ] || {
    echo "error: config/claude-account selects pacing across the accounts of config/$FM_WORKER_ACCOUNT_FAILOVER_FILE, and this home has none" >&2
    return 1
  }
  if [ -z "$snapshot" ]; then
    snapshot=$(fm_run_timed "${FM_ACCOUNT_FAILOVER_QUOTA_SECONDS:-90}" env -u QUOTA_AXI_MAX_AGE quota-axi --all-accounts --json 2>/dev/null </dev/null) || {
      echo 'error: Claude account pacing: the quota-axi --all-accounts reading failed' >&2
      return 1
    }
  fi
  verdicts=$(fm_worker_account_failover_quota "$map" "$snapshot" '' "$model" 2>/dev/null) || {
    echo 'error: Claude account pacing: the quota-axi --all-accounts reading was unreadable' >&2
    return 1
  }
  # Line 1 is the summary; each later line is one candidate, in pacing order.
  plan=$(printf '%s' "$snapshot" | jq -r --argjson verdicts "$verdicts" '
    def short_time: if type == "string" then sub("\\.[0-9]+"; "") | sub(":[0-9]{2}(\\+00:00|Z)$"; "Z") else null end;
    . as $snap |
    [ $verdicts[] | . as $v |
      ([ $snap.providers[] | select(type == "object" and .provider == "claude" and .account == $v.name) ][0]) as $row |
      ([ ($row.windows // [])[] | select(type == "object") ]) as $windows |
      ([ $windows[] | select(.kind == "weekly") ][0] // [ $windows[] | select(.id == "seven_day") ][0]) as $week |
      ($week.pace.reservePercentPoints) as $reserve |
      $v + { reset: ($week.resetsAt // null), week: ($week.percentRemaining // null),
             behind: (if ($reserve | type) == "number" then $reserve >= 0
                      elif ($week.pace.status // "") == "ahead" then false
                      elif (($week.pace.status // "") | IN("behind", "on", "on_pace", "on_track")) then true
                      else null end) } |
      if .ok != true then .
      elif $week == null or (.reset | type) != "string" or (.week | type) != "number" then .ok = false | .why = "its weekly reset is unknown"
      else . end ] as $accounts |
    ($accounts | map(
      "\(.name) \(if (.week | type) == "number" then "\(.week)%" else "unknown" end) week left, resets \((.reset | short_time) // "unknown"), " +
      (if .ok then (if .behind == null then "pace unknown" elif .behind then "on or behind pace" else "ahead of pace" end)
       else "not choosable (\(.why))" end)) | join("; ")) as $summary |
    ([ $accounts[] | select(.ok) ] | sort_by((.reset | short_time), .order)) as $ready |
    (if ($ready | length) == 0 then []
     elif $ready[0].behind == false then $ready[1:] + $ready[:1]
     else $ready end) as $order |
    $summary, ($order[] | .name)')  || {
    echo 'error: Claude account pacing: the quota-axi --all-accounts reading was unreadable' >&2
    return 1
  }
  summary=$(printf '%s\n' "$plan" | head -1 | tr '\t' ' ')
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if selection=$(fm_worker_account_failover_select "$config" "$name" "$executable" "$model" "$snapshot" "$map" 2>&1); then
      printf 'pick\t%s\t%s\t%s\n' "$name" "$selection" "chose $name: $summary$refused"
      return 0
    fi
    err=$(printf '%s' "$selection" | tail -1 | tr '\t' ' ')
    refused="$refused; $name refused at launch (${err#error: })"
  done < <(printf '%s\n' "$plan" | tail -n +2)
  printf 'error: Claude account pacing: no account is choosable: %s%s\n' "$summary" "$refused" >&2
  return 1
}

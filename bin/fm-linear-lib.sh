#!/usr/bin/env bash
# fm-linear-lib.sh - best-effort, one-way Linear lifecycle sync.
# Usage: fm-linear-lib.sh spawn|merge|closed|hold|release|idle|teardown|dependencies|refresh <task-id> [pr-url]
#        fm-linear-lib.sh tick
# FM_HOME and FM_{STATE,DATA,CONFIG}_OVERRIDE address the owning home.
# FM_LINEAR_TEARDOWN_{BRANCH,REPO} name a zero-work teardown's branch and clone;
# its issue is demoted only after a GitHub lookup there lists no merged PR.
# Configuration schema: docs/configuration.md, "Linear sync".
#
# Call only AFTER the local lifecycle action succeeds. Every public invocation
# returns zero, emits at most one generic diagnostic on stderr, and bounds the
# entire attempt (including credentials, backlog and forge reads) to 10 seconds.
# No API response, credential-command output or curl error is printed.
# The key travels to curl through its header stdin, never argv or a file.
#
# Linkage is a `Linear issue: ABC-123` line in the existing backlog body.
# A deterministic client issue UUID, derived from the data root, task and team,
# prevents duplicate creation after an ambiguous timeout or failed link write.
# Only spawn creates; all other events require an existing issue.
# `closed` returns a started issue (In Progress or a review state) to Todo when
# its recorded PR is closed without merging and no worker is on it. Teardown
# produces it with the recorded PR URL; the heartbeat produces it for a ship
# whose worker the busy classifier reports idle or dead.
# A relaunch (FM_LINEAR_RELAUNCH=1) preserves a started In Review issue.
# `merge` skips an attachment the issue already has for that PR URL.
# Private runtime records: <id>.linear-idle stores observation signature and
# epoch, <id>.linear-dependencies keeps dependency clearing eligible after the
# worker ends, and .linear-cursor rotates the existing heartbeat over tasks.
# Dependencies use deterministic home/source/target UUIDs; only owned blocking
# relations are removed. No issue is deleted.
# Triage issues and excluded/unmapped work are never mutated.
# State choices and additive/subtractive label updates do not write cycles.
#
# --run is the internal bounded child, not a lifecycle entry point. The hold,
# relaunch, teardown and merge-poll producers set FM_LINEAR_CONTROL_LOCK_HELD=1 while
# holding the task's control lock; other callers acquire that same lock before
# reading/updating its body.

fm_linear_api() {  # <query> <variables-json>; sets LINEAR_RESPONSE
  local payload
  payload=$(jq -cn --arg query "$1" --argjson variables "$2" '{query:$query,variables:$variables}')
  LINEAR_RESPONSE=$(printf 'Authorization: %s\n' "$LINEAR_KEY" |
    curl -q --silent --fail --connect-timeout 3 --max-time 10 \
      --header @- --header 'Content-Type: application/json' \
      --data-binary "$payload" https://api.linear.app/graphql) || return 1
  printf '%s' "$LINEAR_RESPONSE" | jq -e '(.errors // [] | length) == 0 and (.data | type == "object")' >/dev/null
}

fm_linear_field() {  # <tasks-axi-show> <field>
  local value
  value=$(printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1)
  case "$value" in
    \"*\") printf '%s' "$value" | jq -er 'select(type == "string")' ;;
    -) printf '' ;;
    *) printf '%s' "$value" ;;
  esac
}

fm_linear_candidates() {  # <text>; one distinct identifier per line
  printf '%s' "$1" | jq -Rrs --argjson teams "$LINEAR_TEAMS" '
    [scan("(?<![A-Za-z0-9])[A-Z][A-Z0-9]*-[0-9]+(?![A-Za-z0-9])")
      | . as $id | select(any($teams[]; .key == ($id | split("-")[0])))] | unique | .[]'
}

fm_linear_state() {  # <team-id> <started|completed|unstarted>
  local name
  case "$2" in started) name='In Progress' ;; completed) name=Done ;; unstarted) name=Todo ;; esac
  printf '%s' "$LINEAR_TEAMS" | jq -er --arg team "$1" --arg type "$2" --arg name "$name" '
    [.[] | select(.id == $team) | .states.nodes[] | select(.type == $type)] |
    ([.[] | select(.name == $name)][0].id // .[0].id) | select(type == "string" and length > 0)'
}

fm_linear_closing_references() {  # <text>; identifiers named by a closing keyword
  printf '%s' "$1" | jq -Rrs '
    [scan("(?<![A-Za-z])(?i:fixes|closes|resolves):?\\s+([A-Z][A-Z0-9]*-[0-9]+)(?![A-Za-z0-9])") | .[0]] | .[]'
}

fm_linear_pr_body() {  # <url>; read only the supported forge's complete PR body
  local record
  fm_pr_url_parse "$1" || return 1
  case "$FM_PR_PROVIDER" in
    github)
      record=$(gh-axi pr view "$FM_PR_NUMBER" --repo "$FM_PR_PATH" --hostname "$FM_PR_HOST" --full) || return 1
      printf '%s\n' "$record" | grep -q '^  body: ' || return 1
      fm_linear_field "$record" body
      ;;
    gitlab) glab mr view "$FM_PR_NUMBER" --repo "$FM_PR_HOST/$FM_PR_PATH" --output json | jq -er '.description' ;;
    *) return 1 ;;
  esac
}

# Deterministic UUIDs let retries recognize only relations owned by this home.
fm_linear_relation_id() {
  printf '%s\n%s\n%s' "$1" "$2" "$3" |
    perl -MDigest::SHA=sha256_hex -e 'local $/; my $h=sha256_hex(<STDIN>); printf "%s-%s-4%s-8%s-%s", substr($h,0,8),substr($h,8,4),substr($h,13,3),substr($h,17,3),substr($h,20,12)'
}

# shellcheck disable=SC2016
fm_linear_dependencies() {  # <data> <state> <task> <row> <issue-id>
  local data=$1 state=$2 task=$3 row=$4 target=$5 active dep other text candidates project kind pattern skip
  local existing desired='[]' source relation record type
  active=$(fm_linear_field "$row" blocked_by)
  # The marker keeps queued tasks in the heartbeat rotation after their worker
  # disappears, until every owned relation has been removed.
  [ "$active" != none ] || active=''
  [ -n "$active" ] || [ -f "$state/$task.linear-dependencies" ] || return 0
  touch "$state/$task.linear-dependencies"
  fm_linear_api 'query Relations($id:String!){issue(id:$id){inverseRelations(first:250){nodes{id type issue{id state{type}}} pageInfo{hasNextPage}}}}' \
    "$(jq -cn --arg id "$target" '{id:$id}')"
  existing=$(printf '%s' "$LINEAR_RESPONSE" | jq -ec '.data.issue.inverseRelations | select(.pageInfo.hasNextPage == false) | .nodes')
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    case "$dep" in *[!A-Za-z0-9._-]*) return 1 ;; esac
    other=$(fm_backlog_row_show "$data" "$dep" --full) || {
      printf '%s\n' "$other" | grep -q '^code: NOT_FOUND$' || return 1
      continue
    }
    project=$(fm_linear_field "$other" repo); kind=$(fm_linear_field "$other" kind)
    case "$kind" in scout|secondmate) continue ;; esac
    skip=0
    while IFS= read -r pattern; do
      # shellcheck disable=SC2254
      case "$dep" in $pattern) skip=1 ;; esac
    done < <(printf '%s' "$LINEAR_CONFIG" | jq -r '.[] | select(.key == "exclude_task") | .value')
    [ "$skip" = 0 ] || continue
    printf '%s' "$LINEAR_CONFIG" | jq -e --arg project "$project" '
      any(.[]; .key == "project" and (.value | split("|")[0]) == $project)' >/dev/null || continue
    text=$(fm_linear_field "$other" body)
    candidates=$(printf '%s\n' "$text" | sed -n 's/^Linear issue: //p')
    [ -n "$candidates" ] || candidates=$(fm_linear_candidates "$dep"$'\n'"$(fm_linear_field "$other" title)"$'\n'"$text")
    case "$candidates" in ''|*$'\n'*) continue ;; esac
    [ "$(fm_linear_candidates "$candidates")" = "$candidates" ] || continue
    fm_linear_api 'query Issue($id:String!){issue(id:$id){id identifier team{id} state{id name type}}}' \
      "$(jq -cn --arg id "$candidates" '{id:$id}')"
    printf '%s' "$LINEAR_RESPONSE" | jq -e --argjson teams "$LINEAR_TEAMS" \
      '.data.issue.team.id as $id | any($teams[]; .id == $id)' >/dev/null
    source=$(printf '%s' "$LINEAR_RESPONSE" | jq -er '.data.issue.id')
    type=$(printf '%s' "$LINEAR_RESPONSE" | jq -er '.data.issue.state.type')
    [ "$type" != triage ] || continue
    [ "$source" != "$target" ] || continue
    relation=$(fm_linear_relation_id "$(cd "$data" && pwd -P)" "$source" "$target")
    desired=$(printf '%s' "$desired" | jq -c --arg id "$relation" '. + [$id]')
    printf '%s' "$existing" | jq -e --arg source "$source" 'any(.[]; .type == "blocks" and .issue.id == $source)' >/dev/null && continue
    fm_linear_api 'mutation Block($input:IssueRelationCreateInput!){issueRelationCreate(input:$input){success}}' \
      "$(jq -cn --arg id "$relation" --arg source "$source" --arg target "$target" '{input:{id:$id,issueId:$source,relatedIssueId:$target,type:"blocks"}}')"
    printf '%s' "$LINEAR_RESPONSE" | jq -e '.data.issueRelationCreate.success == true' >/dev/null
  done < <(printf '%s\n' "$active" | tr ',' '\n' | sed 's/^ *//;s/ *$//')
  while IFS= read -r record; do
    source=$(printf '%s' "$record" | jq -r '.issue.id')
    relation=$(printf '%s' "$record" | jq -r '.id')
    [ "$relation" = "$(fm_linear_relation_id "$(cd "$data" && pwd -P)" "$source" "$target")" ] || continue
    printf '%s' "$desired" | jq -e --arg id "$relation" 'index($id) != null' >/dev/null && continue
    fm_linear_api 'mutation Unblock($id:String!){issueRelationDelete(id:$id){success}}' "$(jq -cn --arg id "$relation" '{id:$id}')"
    printf '%s' "$LINEAR_RESPONSE" | jq -e '.data.issueRelationDelete.success == true' >/dev/null
  done < <(printf '%s' "$existing" | jq -c '.[] | select(.type == "blocks" and .issue.state.type != "triage")')
  [ -n "$active" ] || rm -f "$state/$task.linear-dependencies"
}

fm_linear_review_state() {  # <issue-json>
  printf '%s' "$1" | jq -e '.state.type == "started" and ((.state.name // "") | ascii_downcase) == "in review"' >/dev/null
}

fm_linear_pr_closed() {  # <url>; succeeds only for a PR the forge reports closed and unmerged
  fm_pr_url_parse "$1" || return 1
  case "$FM_PR_PROVIDER" in
    github) fm_pr_github_read_record "$FM_PR_OWNER" "$FM_PR_REPO" "$FM_PR_NUMBER" || return 1 ;;
    gitlab) fm_pr_gitlab_read_record "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" || return 1 ;;
    *) return 1 ;;
  esac
  [ "$FM_PR_RECORD_MERGED" = false ] || return 1
  case "$FM_PR_RECORD_STATE" in CLOSED|closed) ;; *) return 1 ;; esac
}

# A ship nobody is working on: a dead endpoint or hook-backed idle verdict.
# Missing evidence is never treated as absence of a worker.
fm_linear_worker_gone() {  # <state> <task>; sets LINEAR_VERDICT
  local state=$1 task=$2 meta="$1/$2.meta" backend target harness
  [ -f "$meta" ] || return 1
  # shellcheck source=bin/fm-backend.sh
  . "$LINEAR_DIR/fm-backend.sh"
  # shellcheck source=bin/fm-busy-lib.sh
  . "$LINEAR_DIR/fm-busy-lib.sh"
  [ "$(fm_meta_get "$meta" kind)" = ship ] || return 1
  backend=$(fm_backend_of_meta "$meta"); target=$(fm_backend_target_of_meta "$meta"); harness=$(fm_meta_get "$meta" harness)
  LINEAR_VERDICT=$(fm_busy_classify_live "$backend" "$target" "$harness" "$task" "$state")
  case "$LINEAR_VERDICT" in
    dead\ *) return 0 ;;
    idle\ *) [ -n "$(fm_busy_sources_for_harness "$harness")" ] ;;
    *) return 1 ;;
  esac
}

# A ship whose recorded PR was closed without merging while no worker is on it.
# The cheap local checks run before the forge read.
fm_linear_closed_due() {  # <state> <task>; sets LINEAR_CLOSED_URL
  local state=$1 task=$2 meta="$1/$2.meta"
  [ -f "$meta" ] || return 1
  # shellcheck source=bin/fm-backend.sh
  . "$LINEAR_DIR/fm-backend.sh"
  LINEAR_CLOSED_URL=$(fm_meta_get "$meta" pr)
  [ -n "$LINEAR_CLOSED_URL" ] || return 1
  fm_linear_worker_gone "$state" "$task" || return 1
  fm_linear_pr_closed "$LINEAR_CLOSED_URL"
}

fm_linear_idle_due() {  # <state> <task>; classifier owns all harness/backend facts
  local state=$1 task=$2 meta="$1/$2.meta" verdict signature old since now backend target harness
  [ -f "$meta" ] || return 1
  # shellcheck source=bin/fm-backend.sh
  . "$LINEAR_DIR/fm-backend.sh"
  # shellcheck source=bin/fm-busy-lib.sh
  . "$LINEAR_DIR/fm-busy-lib.sh"
  [ "$(fm_meta_get "$meta" kind)" = ship ] || return 1
  backend=$(fm_backend_of_meta "$meta"); target=$(fm_backend_target_of_meta "$meta"); harness=$(fm_meta_get "$meta" harness)
  # Recorded PRs use closure reconciliation instead of the inactivity rule.
  # Harnesses without busy-state hooks offer only sparse samples, which
  # cannot prove a continuous idle day.
  if [ -n "$(fm_meta_get "$meta" pr)" ] || [ -z "$(fm_busy_sources_for_harness "$harness")" ]; then
    rm -f "$state/$task.linear-idle"
    return 1
  fi
  verdict=$(fm_busy_classify_live "$backend" "$target" "$harness" "$task" "$state")
  case "$verdict" in idle\ *|dead\ *) ;; *) rm -f "$state/$task.linear-idle"; return 1 ;; esac
  signature=$(printf '%s\n%s\n%s' "$(fm_meta_get "$meta" spawn_gen)" "$(cat "$state/$task.busy-state" 2>/dev/null || true)" "$verdict" | cksum)
  old=$(sed -n '1p' "$state/$task.linear-idle" 2>/dev/null || true)
  since=$(sed -n '2p' "$state/$task.linear-idle" 2>/dev/null || true)
  now=$(date +%s)
  case "$since" in ''|*[!0-9]*) since=$now ;; esac
  if [ "$old" != "$signature" ]; then
    printf '%s\n%s\n' "$signature" "$now" > "$state/$task.linear-idle"
    return 1
  fi
  [ "$((now - since))" -gt 86400 ]
}

# Each heartbeat refreshes ship records and dependency markers in rotation
# within one ten-second budget, starting no task with less than five seconds
# left. The cursor names the last task attempted, so a timed-out task waits for
# its next turn instead of starving the rest. This is part of the existing
# watcher, not a daemon.
fm_linear_tick() {
  local state=${FM_STATE_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$LINEAR_DIR/.." && pwd)}}/state}
  local previous task ids file deadline=$((SECONDS + 10)) LINEAR_BOUND
  previous=$(cat "$state/.linear-cursor" 2>/dev/null || true)
  ids=$({
    for file in "$state"/*.meta; do
      [ -f "$file" ] || continue
      [ "$(sed -n 's/^kind=//p' "$file" | tail -1)" = ship ] || continue
      task=${file##*/}; printf '%s\n' "${task%.meta}"
    done
    for file in "$state"/*.linear-dependencies; do
      [ -f "$file" ] || continue
      task=${file##*/}; printf '%s\n' "${task%.linear-dependencies}"
    done
  } | LC_ALL=C sort -u | LC_ALL=C awk -v previous="$previous" '
    $0 > previous {print; next} {rest = rest $0 "\n"} END {printf "%s", rest}')
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    LINEAR_BOUND=$((deadline - SECONDS))
    [ "$LINEAR_BOUND" -ge 5 ] || break
    fm_linear_main refresh "$task"
    printf '%s\n' "$task" > "$state/.linear-cursor"
  done <<< "$ids"
}

# shellcheck disable=SC2016 # GraphQL variables are literal; JSON variables carry their values.
fm_linear_event() {
  local event=$1 id=$2 url=${3:-} home state data config row project kind team ids
  local key_command key_count pattern label title body linked candidates issue issue_id issue_team state_id input
  local idle_due=0 closed_due=0 attached
  local identifier marker pr_body create_id lock='' metadata meta_kind meta_project issue_type merged
  home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$LINEAR_DIR/.." && pwd)}}
  state=${FM_STATE_OVERRIDE:-$home/state}
  data=${FM_DATA_OVERRIDE:-$home/data}
  config=${FM_CONFIG_OVERRIDE:-$home/config}/linear
  case "$event" in spawn|merge|closed|hold|release|idle|teardown|dependencies|refresh) ;; *) exit 1 ;; esac
  case "$id" in ''|*[!A-Za-z0-9._-]*) exit 1 ;; esac
  [ -f "$config" ] || exit 20
  command -v jq >/dev/null
  command -v curl >/dev/null
  LINEAR_CONFIG=$(jq -Rn '[inputs | select((test("^\\s*$") | not) and (test("^\\s*#") | not)) |
    if test("^[^=]+=.*$") then capture("^(?<key>[^=]+)=(?<value>.*)$") else error("invalid directive") end]' < "$config")
  printf '%s' "$LINEAR_CONFIG" | jq -e 'all(.[];
    (.key == "key_command" or .key == "waiting_label" or .key == "project" or
     .key == "exclude_task") and
    (.value | length > 0) and (.value | explode | all(.[]; . >= 32 and . != 127))) and
    all(.[] | select(.key == "project"); (.value | split("|") | length == 2 and all(.[]; length > 0)))' >/dev/null
  while IFS= read -r pattern; do
    # shellcheck disable=SC2254 # Configured shell globs deliberately match patterns.
    case "$id" in $pattern) exit 22 ;; esac
  done < <(printf '%s' "$LINEAR_CONFIG" | jq -r '.[] | select(.key == "exclude_task") | .value')

  # The shared addressing owner supports markdown and non-markdown backlogs.
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$LINEAR_DIR/fm-tasks-axi-lib.sh"
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$LINEAR_DIR/fm-backlog-transition-lib.sh"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$LINEAR_DIR/fm-wake-lib.sh"
  # A heartbeat with nothing due must not contend for the lifecycle lock.
  if [ "$event" = refresh ]; then
    if fm_linear_idle_due "$state" "$id"; then idle_due=1; fi
    if [ "$idle_due" = 0 ] && fm_linear_closed_due "$state" "$id"; then closed_due=1; fi
    [ "$idle_due" = 1 ] || [ "$closed_due" = 1 ] || [ -f "$state/$id.linear-dependencies" ] || exit 0
  fi
  if [ "${FM_LINEAR_CONTROL_LOCK_HELD:-0}" != 1 ]; then
    lock="$state/.control-$id.lock"
    fm_lock_acquire_wait "$lock"
    LINEAR_LOCK=$lock
    trap 'fm_lock_release "$LINEAR_LOCK"' EXIT
  fi
  if [ "$idle_due" = 1 ]; then
    fm_linear_idle_due "$state" "$id" || idle_due=0
  fi
  if [ "$closed_due" = 1 ]; then
    fm_linear_closed_due "$state" "$id" || closed_due=0
  fi
  if [ "$event" = refresh ]; then
    [ "$idle_due" = 1 ] || [ "$closed_due" = 1 ] || [ -f "$state/$id.linear-dependencies" ] || exit 0
  fi
  if [ "$closed_due" = 1 ]; then url=$LINEAR_CLOSED_URL; fi
  case "$event" in merge|closed) fm_pr_url_parse "$url" ;; *) [ "$closed_due" = 1 ] || url='' ;; esac
  row=$(fm_backlog_row_show "$data" "$id" --full) || {
    # An archived or removed task has no dependencies left to clear.
    [ "$event" = refresh ] && printf '%s\n' "$row" | grep -q '^code: NOT_FOUND$' || exit 1
    rm -f "$state/$id.linear-dependencies"
    exit 0
  }
  body=$(fm_linear_field "$row" body)
  title=$(fm_linear_field "$row" title)
  project=$(fm_linear_field "$row" repo)
  kind=$(fm_linear_field "$row" kind)
  metadata="$state/$id.meta"
  if [ -f "$metadata" ]; then
    [ ! -L "$metadata" ]
    meta_kind=$(sed -n 's/^kind=//p' "$metadata" | tail -1)
    meta_project=$(sed -n 's/^project=//p' "$metadata" | tail -1)
    [ -z "$meta_kind" ] || kind=$meta_kind
    if [ -n "$meta_project" ]; then
      project=${meta_project%/}; project=${project##*/}
    fi
  fi
  case "$kind" in scout|secondmate) exit 22 ;; esac
  team=$(printf '%s' "$LINEAR_CONFIG" | jq -er --arg project "$project" '
    [.[] | select(.key == "project") | .value | split("|") | select(.[0] == $project) | .[1]] |
    if length == 0 then "" elif length == 1 then .[0] else error("duplicate project") end')
  [ -n "$team" ] || exit 22
  label=$(printf '%s' "$LINEAR_CONFIG" | jq -r '[.[] | select(.key == "waiting_label") | .value] |
    if length > 1 then error("duplicate label") else .[0] // "" end')
  case "$event" in hold|release) [ -n "$label" ] || exit 22 ;; esac
  key_count=$(printf '%s' "$LINEAR_CONFIG" | jq '[.[] | select(.key == "key_command")] | length')
  [ "$key_count" -le 1 ]
  LINEAR_KEY=${FM_LINEAR_API_KEY:-}
  unset FM_LINEAR_API_KEY
  if [ -z "$LINEAR_KEY" ]; then
    key_command=$(printf '%s' "$LINEAR_CONFIG" | jq -r '.[] | select(.key == "key_command") | .value')
    [ -n "$key_command" ] || exit 21
    LINEAR_KEY=$(bash -c "$key_command" 2>/dev/null) || exit 21
  fi
  [ -n "$LINEAR_KEY" ] || exit 21
  case "$LINEAR_KEY" in *$'\n'*|*$'\r'*) exit 1 ;; esac

  ids=$(printf '%s' "$LINEAR_CONFIG" | jq '[.[] | select(.key == "project") | .value | split("|")[1]] | unique')
  fm_linear_api 'query Teams($ids:[ID!]!){teams(filter:{id:{in:$ids}},first:250){nodes{id key states(first:250){nodes{id name type} pageInfo{hasNextPage}}} pageInfo{hasNextPage}}}' \
    "$(jq -cn --argjson ids "$ids" '{ids:$ids}')"
  printf '%s' "$LINEAR_RESPONSE" | jq -e --argjson ids "$ids" '
    .data.teams | .pageInfo.hasNextPage == false and
    ([.nodes[].id] | sort) == ($ids | sort) and
    all(.nodes[]; (.key | test("^[A-Z][A-Z0-9]*$")) and .states.pageInfo.hasNextPage == false)' >/dev/null
  LINEAR_TEAMS=$(printf '%s' "$LINEAR_RESPONSE" | jq -c '.data.teams.nodes')
  marker=$(printf '%s\n' "$body" | sed -n 's/^Linear issue: //p')
  if [ -n "$marker" ]; then
    candidates=$(fm_linear_candidates "$marker")
    [ "$candidates" = "$marker" ] && [ -n "$candidates" ]
  else
    candidates=$(fm_linear_candidates "$id"$'\n'"$title"$'\n'"$body")
    if [ -z "$candidates" ] && [ -n "$url" ]; then
      # A failed forge read is not proof that the PR has no ticket. Only a
      # closing keyword makes a PR mention a link.
      pr_body=$(fm_linear_pr_body "$url")
      candidates=$(fm_linear_candidates "$(fm_linear_closing_references "$pr_body")")
    fi
  fi
  case "$candidates" in *$'\n'*) exit 23 ;; esac
  linked=$candidates
  if [ -n "$linked" ]; then
    fm_linear_api 'query Issue($id:String!){issue(id:$id){id identifier team{id} state{id name type}}}' \
      "$(jq -cn --arg id "$linked" '{id:$id}')"
    issue=$(printf '%s' "$LINEAR_RESPONSE" | jq -ec '.data.issue | select(.id != null)')
  else
    # The UUID is stable across retries, even when create succeeded but its
    # response or the backlog write was lost. No local credential/state cache.
    create_id=$(printf '%s\n%s\n%s' "$(cd "$data" && pwd -P)" "$id" "$team" |
      perl -MDigest::SHA=sha256_hex -e 'local $/; my $h=sha256_hex(<STDIN>); printf "%s-%s-4%s-8%s-%s", substr($h,0,8),substr($h,8,4),substr($h,13,3),substr($h,17,3),substr($h,20,12)')
    fm_linear_api 'query CreatedIssue($id:ID!){issues(filter:{id:{eq:$id}},first:1){nodes{id identifier team{id} state{id name type}}}}' \
      "$(jq -cn --arg id "$create_id" '{id:$id}')"
    printf '%s' "$LINEAR_RESPONSE" | jq -e '.data.issues.nodes | type == "array"' >/dev/null
    issue=$(printf '%s' "$LINEAR_RESPONSE" | jq -c '.data.issues.nodes[0] // empty')
    if [ -z "$issue" ]; then
      [ "$event" = spawn ] || exit 22
      [ -n "$title" ]
      state_id=$(fm_linear_state "$team" started)
      input=$(jq -cn --arg id "$create_id" --arg team "$team" --arg title "$title" --arg body "$body" --arg state "$state_id" \
        '{input:{id:$id,teamId:$team,title:$title,description:$body,stateId:$state}}')
      fm_linear_api 'mutation CreateIssue($input:IssueCreateInput!){issueCreate(input:$input){success issue{id identifier team{id} state{id name type}}}}' "$input"
      printf '%s' "$LINEAR_RESPONSE" | jq -e '.data.issueCreate.success == true' >/dev/null
      issue=$(printf '%s' "$LINEAR_RESPONSE" | jq -ec '.data.issueCreate.issue | select(.id != null)')
    fi
  fi
  issue_id=$(printf '%s' "$issue" | jq -er '.id')
  identifier=$(printf '%s' "$issue" | jq -er '.identifier')
  issue_team=$(printf '%s' "$issue" | jq -er '.team.id')
  printf '%s' "$LINEAR_TEAMS" | jq -e --arg team "$issue_team" 'any(.[]; .id == $team)' >/dev/null
  [ "$(fm_linear_candidates "$identifier")" = "$identifier" ]
  issue_type=$(printf '%s' "$issue" | jq -er '.state.type | select(type == "string" and length > 0)')
  [ "$issue_type" != triage ] || exit 24
  # Finished work is reopened or re-completed only through its saved linkage,
  # never through an incidental mention.
  case "$issue_type" in completed|canceled) [ -n "$marker" ] || exit 22 ;; esac
  if [ "$marker" != "$identifier" ]; then
    # Re-read before writing, preserving current body and all other fields.
    row=$(fm_backlog_row_show "$data" "$id" --full)
    body=$(fm_linear_field "$row" body | sed '/^Linear issue: /d')
    fm_backlog_mutate "$data" update "$id" --body "${body}${body:+$'\n\n'}Linear issue: $identifier"
  fi
  case "$event" in dependencies|refresh)
    fm_linear_dependencies "$data" "$state" "$id" "$row" "$issue_id"
    if [ "$event" = refresh ] && [ "$closed_due" = 1 ]; then
      event=closed
    elif [ "$event" = refresh ] && [ "$idle_due" = 1 ]; then
      event=idle
    else
      exit 0
    fi
    ;; esac
  case "$event" in
    idle|teardown)
      # Only the In Progress state this sync sets means a working ship. Other
      # states, including custom review or waiting states, and captain-held
      # work keep their status.
      [ "$(printf '%s' "$issue" | jq -r '.state.id')" = "$(fm_linear_state "$issue_team" started)" ] || exit 0
      [ "$(fm_linear_field "$row" hold_kind)" != captain ] || [ "$(fm_linear_field "$row" state)" = "done" ] || exit 0
      if [ "$event" = teardown ] && [ -n "${FM_LINEAR_TEARDOWN_BRANCH:-}" ]; then
        # Merged, failed or unreadable lookups are not proof that nothing landed.
        [ -n "${FM_LINEAR_TEARDOWN_REPO:-}" ] || exit 0
        merged=$(cd "$FM_LINEAR_TEARDOWN_REPO" && gh-axi pr list --state merged \
          --head "$FM_LINEAR_TEARDOWN_BRANCH" --limit 1 2>/dev/null) || exit 0
        printf '%s\n' "$merged" | grep -qx 'count: 0' || exit 0
      fi
      state_id=$(fm_linear_state "$issue_team" unstarted)
      input=$(jq -cn --arg id "$issue_id" --arg state "$state_id" '{id:$id,input:{stateId:$state}}')
      ;;
    closed)
      # Any started state, including In Review, means the ticket still claims
      # work whose PR is no longer open. Captain-held work keeps its status.
      [ "$issue_type" = started ] || exit 0
      [ "$(fm_linear_field "$row" hold_kind)" != captain ] || [ "$(fm_linear_field "$row" state)" = "done" ] || exit 0
      fm_linear_pr_closed "$url" || exit 0
      state_id=$(fm_linear_state "$issue_team" unstarted)
      input=$(jq -cn --arg id "$issue_id" --arg state "$state_id" '{id:$id,input:{stateId:$state}}')
      ;;
    spawn|merge)
      if [ "$event" = spawn ]; then
        kind=started
        # A relaunch resumes work on a ticket whose PR is already up for review.
        if [ "${FM_LINEAR_RELAUNCH:-0}" = 1 ] && fm_linear_review_state "$issue"; then kind=''; fi
      else
        kind=completed
      fi
      if [ -n "$kind" ]; then
        state_id=$(fm_linear_state "$issue_team" "$kind")
        input=$(jq -cn --arg id "$issue_id" --arg state "$state_id" '{id:$id,input:{stateId:$state}}')
      else
        input=''
      fi
      ;;
    hold) input=$(jq -cn --arg id "$issue_id" --arg label "$label" '{id:$id,input:{addedLabelIds:[$label]}}') ;;
    release) input=$(jq -cn --arg id "$issue_id" --arg label "$label" '{id:$id,input:{removedLabelIds:[$label]}}') ;;
  esac
  if [ -n "$input" ]; then
    fm_linear_api 'mutation UpdateIssue($id:String!,$input:IssueUpdateInput!){issueUpdate(id:$id,input:$input){success}}' "$input"
    printf '%s' "$LINEAR_RESPONSE" | jq -e '.data.issueUpdate.success == true' >/dev/null
  fi
  case "$event" in idle|teardown|closed)
    local reason='Worker has been idle or gone for more than a day; returned to Todo.'
    [ "$event" != teardown ] || reason='Worker was torn down without landed work; returned to Todo.'
    [ "$event" != closed ] || reason='Pull request was closed without merging and no worker is on it; returned to Todo.'
    fm_linear_api 'mutation Comment($input:CommentCreateInput!){commentCreate(input:$input){success}}' \
      "$(jq -cn --arg id "$issue_id" --arg body "$reason" '{input:{issueId:$id,body:$body}}')"
    printf '%s' "$LINEAR_RESPONSE" | jq -e '.data.commentCreate.success == true' >/dev/null
    ;; esac
  if [ "$event" = spawn ]; then
    fm_linear_dependencies "$data" "$state" "$id" "$row" "$issue_id"
  fi
  if [ "$event" = merge ]; then
    [ -n "$url" ]
    # Linear's own GitHub integration usually attaches the PR first.
    attached=0
    if fm_linear_api 'query Attachments($id:String!){issue(id:$id){attachments(first:250){nodes{url} pageInfo{hasNextPage}}}}' \
        "$(jq -cn --arg id "$issue_id" '{id:$id}')" &&
        printf '%s' "$LINEAR_RESPONSE" | jq -e --arg url "${url%/}" \
          'any(.data.issue.attachments.nodes[]?; (.url | rtrimstr("/")) == $url)' >/dev/null; then
      attached=1
    fi
    [ "$attached" = 0 ] || return 0
    fm_linear_api 'mutation AttachPR($input:AttachmentCreateInput!){attachmentCreate(input:$input){success}}' \
      "$(jq -cn --arg id "$issue_id" --arg url "$url" '{input:{issueId:$id,url:$url,title:"Merged pull request"}}')"
    printf '%s' "$LINEAR_RESPONSE" | jq -e '.data.attachmentCreate.success == true' >/dev/null
  fi
}

fm_linear_main() {
  local result=0 config
  LINEAR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  case "${1:-}" in
    -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; return 0 ;;
    --run)
      shift
      set -euo pipefail
      fm_linear_event "$@"
      return 0
      ;;
  esac
  config=${FM_CONFIG_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$LINEAR_DIR/.." && pwd)}}/config}/linear
  if [ ! -f "$config" ]; then
    printf 'linear: sync off (no config)\n' >&2
    return 0
  fi
  if [ "${1:-}" = tick ]; then fm_linear_tick; return 0; fi
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$LINEAR_DIR/fm-timeout-lib.sh"
  fm_run_timed "${LINEAR_BOUND:-10}" bash "$LINEAR_DIR/fm-linear-lib.sh" --run "$@" >/dev/null 2>&1 || result=$?
  # Heartbeat refreshes revisit excluded, unmapped and unlinked work routinely.
  [ "${1:-}" != refresh ] || case "$result" in 22|23|24) return 0 ;; esac
  case "$result" in
    0) ;;
    20) printf 'linear: sync off (no config)\n' >&2 ;;
    21) printf 'linear: sync off (no key)\n' >&2 ;;
    22) printf 'linear: skipped (excluded, unmapped or unlinked work)\n' >&2 ;;
    23) printf 'linear: skipped (ambiguous ticket linkage)\n' >&2 ;;
    24) printf 'linear: skipped (triage issue)\n' >&2 ;;
    124|137) printf 'linear: sync timed out; lifecycle action succeeded\n' >&2 ;;
    *) printf 'linear: sync failed; lifecycle action succeeded\n' >&2 ;;
  esac
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # Do not let shell tracing expose credentials, including key-command output.
  set +x
  fm_linear_main "$@"
fi

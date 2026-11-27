#!/usr/bin/env bash
# Saved native conversations for canonical Claude and Codex workers.
# agent_session_id is a UUID, agent_session_root is the launch credential and
# transcript root (empty for Claude's ordinary account), and spawn_gen binds
# asynchronous Codex notifications to one launch. These fields are not endpoint
# authority. Resume still goes through fm-control and fm-spawn's stopped-agent,
# ownership, account, worktree and transactional publication checks.
# A missing/unreadable transcript is unavailable, never permission to select
# the most recent conversation. No credential or vendor configuration is written.

fm_agent_session_uuid() {
  [[ ${1:-} =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

fm_agent_session_root() { # <harness>
  local root
  case "$1" in
    claude) root=${CLAUDE_CONFIG_DIR:-} ;;
    codex) root=${CODEX_HOME:-$HOME/.codex} ;;
    *) return 1 ;;
  esac
  case "$root" in
    ''|/*) printf '%s' "$root" ;;
    *) echo "error: native session account root must be absolute" >&2; return 1 ;;
  esac
}

fm_agent_session_file() { # <harness> <root> <uuid> <cwd>
  local harness=$1 root=$2 uuid=$3 cwd=$4 file found='' header
  fm_agent_session_uuid "$uuid" || return 1
  case "$harness" in
    claude) root="${root:-$HOME/.claude}/projects" ;;
    codex) root="$root/sessions" ;;
    *) return 1 ;;
  esac
  [ -d "$root" ] || return 1
  # Account roots commonly share a vendor transcript directory by symlink.
  # Resolve that directory without following arbitrary per-session links.
  root=$(cd "$root" && pwd -P) || return 1
  while IFS= read -r file; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    case "$harness" in
      claude)
        # The first conversation entry carries the session and original cwd;
        # skip queue/history records without reading the full conversation.
        header=$(awk '/"sessionId"/ && /"cwd"/ { print; exit }' "$file")
        printf '%s\n' "$header" | jq -e --arg id "$uuid" --arg cwd "$cwd" \
          '.sessionId == $id and .cwd == $cwd' >/dev/null 2>&1 || continue
        ;;
      codex)
        header=$(head -n 1 "$file")
        printf '%s\n' "$header" | jq -e --arg id "$uuid" --arg cwd "$cwd" \
          '.type == "session_meta" and .payload.id == $id and .payload.cwd == $cwd' >/dev/null 2>&1 || continue
        ;;
    esac
    jq empty "$file" >/dev/null 2>&1 || continue
    [ -z "$found" ] || return 1
    found=$file
  done < <(find "$root" -maxdepth 4 -type f -name "*$uuid.jsonl" 2>/dev/null)
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

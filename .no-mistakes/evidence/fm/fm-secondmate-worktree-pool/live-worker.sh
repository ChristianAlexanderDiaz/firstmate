#!/usr/bin/env bash
set -eu
root=$1
lab_home=$2
project=$3
id=$4
out="$lab_home/state/$id.worker.log"
exec >"$out" 2>&1
printf 'Worker task: %s\nWorking directory: %s\nGit common directory: %s\n' "$id" "$PWD" "$(git rev-parse --path-format=absolute --git-common-dir)"
CLAUDE_CONFIG_DIR="$lab_home/claude-config" "$root/bin/fm-claude-trust.sh" "$PWD" "$project"
printf 'Claude CLI version: '
claude --version
unset CLAUDE_CONFIG_DIR
claude -p --no-session-persistence --setting-sources project,local --strict-mcp-config --mcp-config '{"mcpServers":{}}' --tools '' --system-prompt 'You are a read-only launch probe. Use no tools. Respond only with the requested token.' 'Reply with exactly LIVE_WORKER_OK.'
printf '\nWORKER_COMPLETED\n'
while [ ! -f "$lab_home/state/$id.stop" ]; do sleep .2; done

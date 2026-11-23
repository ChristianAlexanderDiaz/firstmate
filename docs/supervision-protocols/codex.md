Mode: Codex foreground wake wait.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED` and verify `WAKE_ACK_CONFIRMED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. Run exactly one foreground `bin/fm-watch-checkpoint.sh --wait` and let it block until a wake or repair reason returns.
   The script's help owns the wait and diagnostic checkpoint exit statuses.
   Do not poll the drain, checkpoint, or a short timed wait while this command is running.
   If the tool yields a running command handle, keep waiting on that same command with the longest supported blocking wait; never start a second command or drain merely because the tool yielded.
4. Ordinary wake (`signal:`, `stale:`, `check:`, or `heartbeat`): drain before any other action, handle, acknowledge using the printed generation-bound command, then issue the next foreground wait.
5. Quiet intervals resume inside that same shell command, keeping the same watcher alive without draining, replying, or returning to the model.
   A user message or explicit interruption is handled normally; it is not an empty poll.
6. Failure or missing cycle only: drain queued wakes first, inspect the repair reason, then restore one foreground wait.
7. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
   Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.

Waiting happens inside the shell, with no model-visible output while idle.
A foreground wait delays ordinary user-message processing until it returns unless the user interrupts it.

---
name: sleep
description: >-
  Load when /sleep is invoked, sleep mode is requested, or state/.sleep or state/.sleep-return exists.
  Hold all fleet work and operational input during sleep; the first ordinary user message exits sleep across the registered fleet and presents its held queue before ordinary work resumes.
user-invocable: true
metadata:
  internal: true
---

# Sleep

This posture overlays away and quiet mode.
[bin/fm-sleep.sh](../../../bin/fm-sleep.sh) owns the record, propagation, lifecycle, return, failure, and standalone gnhf exception contracts; consult its help for mechanics.

On `/sleep` or `/sleep on`, run `FM_HOME=<active-home> bin/fm-sleep.sh on` before other work.
Report its actual result, then end the entry turn without starting work or a model-driven polling loop.
Keep the existing shell or extension supervision cycle parked; its sleep guards retain events without opening turns.
A nonzero result means the fleet has not fully entered sleep: name the failed endpoint or route and retain the hold while resolving that failure.
Never claim every worker stopped on partial propagation, a refused interrupt, or an unconfirmed cancellation; the control output states the available proof.
Do not remove, stop, or discover standalone gnhf processes.

On `/sleep status`, run the script's `status` command without clearing sleep.
On `/sleep off`, run its `off` command.
On the first ordinary user message while either sleep record exists, run its `input` command with the message verbatim on stdin before doing the requested work.
Operational input, including firstmate routing, watcher wakes, and backed doorbells, is held rather than treated as a return.
Do not acknowledge or act on held events until the sleep return succeeds.

Present this home's returned normal drain output, handle its open decisions and unread statuses, and acknowledge only after handling using its printed command.
Descendant sections are read-only summaries: never act on or acknowledge those rows from the parent.
Each secondmate drains, handles, and acknowledges its own queue when its watcher is released.
The command does not resume interrupted workers; steer them normally after resolving the held queue.
If an away record also exists on return, load [afk](../afk/SKILL.md) and complete its return procedure before ordinary work.
Quiet mode keeps its usual explicit-off semantics.

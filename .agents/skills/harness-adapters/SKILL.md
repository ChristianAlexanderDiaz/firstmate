---
name: harness-adapters
description: >-
  Agent-only reference for firstmate harness operations.
  Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter.
  Contains verified facts for claude, codex, opencode, pi, pi-signed, grok, kimi, cursor, gemini, muse, rovo, omp, agy, and devin.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

This is the one skill, trigger, and routing owner for harness-specific Firstmate operations.
Load this router first, then exactly the common reference and one harness reference selected below.
When an action spans rows, load the union once rather than every reference.
Files under `references/` are resources of this skill, not additional catalogued skills.

## Path contract

The skill directory is the directory containing this `SKILL.md`.
Resolve on-demand reference links and relative links to their executable, documentation, or sibling-skill owners against the skill directory, including links named by a nested reference.
Operational paths keep the context named by their owner: `config/` and active-home settings belong to the active Firstmate home, `state/` belongs to that home, and project settings such as `.claude/settings.json` belong to the target project.

## Non-negotiable safety

Never dispatch a crewmate or secondmate on an unverified adapter.
If `config/crew-harness` or `config/secondmate-harness` names one, tell the captain under `../../../AGENTS.md` section 9 that the requested worker runtime is not verified, use firstmate's own verified runtime for current work, and ask only whether to verify the requested runtime for future work.
Do not pause current work for that choice.

On `unknown`, ask the captain instead of guessing.
A current captain override beats detection, while a per-task override governs only that dispatch.
For recovery and control, use the exact `harness=` in `state/<id>.meta`; never infer it from a model or provider.

Deliver lifecycle actions only through `../../../bin/fm-control.sh <task-id> interrupt|exit|relaunch`.
Never type an interrupt key or exit command through `fm-send`, where routing-marked lifecycle text becomes chat.
Trust handling is complete only when inspection proves the target started processing its instructions; delivery success alone is not proof.
Muse, Gemini, AGY, and Devin are verified only for crewmate and scout work, never a secondmate or primary.

## Detection

`../../../bin/fm-harness.sh` prints firstmate's own harness from verified environment markers and process ancestry, and owns how they combine.
A marker names its harness, but a structural ancestor of a different harness outranks it, because a marker is ordinary environment state a child or a multiplexer can retain while ancestry is what proves who owns the process tree.
Only `FM_PI_HARNESS=pi-signed` at the launch boundary together with `PI_CODING_AGENT=true` selects Pi-signed; shared unmarked launcher ancestry remains Pi.
omp publishes no marker of its own; `FM_OMP_HARNESS=omp` is Firstmate's launch marker and the anchored process name `omp` is its ancestry evidence, as `references/harness/omp.md` records.
`../../../bin/fm-spawn.sh` owns worker marker establishment, while the README launch command owns the signed-primary boundary.
`../../../bin/fm-harness.sh crew` resolves `config/crew-harness`, where absent or `default` means firstmate's own harness.
`../../../bin/fm-harness.sh secondmate` resolves `config/secondmate-harness` -> `config/crew-harness` -> firstmate's own harness.
`../../../bin/fm-spawn.sh` re-resolves on every spawn, and an explicit per-spawn argument wins for that spawn.
A new adapter's verified marker and command name must land in `../../../bin/fm-harness.sh`.

## Operation-to-reference matrix

Every emitted plan appends the selected or recorded harness reference after the named common references.
The `harness-adapter-routing-v1` object is the machine-readable and human-visible selection contract: choose the operation, choose the scenario within it, then append the selected harness reference.
`default` is the normal scenario when no narrower scenario applies.
Kimi establishes its unsupported primary boundary in its selected harness reference; Muse and Gemini follow Non-negotiable safety above.
A new tool remains undispatchable until the `verify` plan, its harness entry, every named owner, and the live checks land.

```json harness-adapter-routing-v1
{
  "operations": {
    "start": {
      "default": ["references/common/dispatch.md", "references/common/model-and-effort.md"],
      "trust-dialog": ["references/common/control-and-recovery.md"]
    },
    "trust": {"default": ["references/common/control-and-recovery.md"]},
    "skill": {"default": ["references/common/control-and-recovery.md"]},
    "interrupt": {"default": ["references/common/control-and-recovery.md"]},
    "exit": {"default": ["references/common/control-and-recovery.md"]},
    "resume": {"default": ["references/common/control-and-recovery.md"]},
    "recovery": {
      "default": ["references/common/control-and-recovery.md"],
      "replacement-profile": ["references/common/control-and-recovery.md", "references/common/dispatch.md", "references/common/model-and-effort.md"],
      "secondmate": ["references/common/control-and-recovery.md", "references/common/primary-hooks.md"],
      "replacement-secondmate": ["references/common/control-and-recovery.md", "references/common/dispatch.md", "references/common/model-and-effort.md", "references/common/primary-hooks.md"]
    },
    "primary": {"default": ["references/common/primary-hooks.md"]},
    "model-effort": {
      "default": ["references/common/model-and-effort.md"],
      "configured-profile": ["references/common/model-and-effort.md", "references/common/dispatch.md"]
    },
    "verify": {"default": ["references/common/dispatch.md", "references/common/control-and-recovery.md", "references/common/primary-hooks.md", "references/common/model-and-effort.md"]}
  },
  "harnesses": {
    "claude": "references/harness/claude.md",
    "codex": "references/harness/codex.md",
    "opencode": "references/harness/opencode.md",
    "pi": "references/harness/pi.md",
    "pi-signed": "references/harness/pi.md",
    "grok": "references/harness/grok.md",
    "kimi": "references/harness/kimi.md",
    "cursor": "references/harness/cursor.md",
    "gemini": "references/harness/gemini.md",
    "muse": "references/harness/muse.md",
    "rovo": "references/harness/rovo.md",
    "omp": "references/harness/omp.md",
    "agy": "references/harness/agy.md",
    "devin": "references/harness/devin.md"
  }
}
```

## Harness and runtime dispatch

- The verified harnesses are `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi`, `cursor`, and `omp`, plus `muse`, `gemini`, `rovo`, `agy`, and `devin` for crewmates and scouts only; never dispatch on an unverified adapter.
- If static `config/crew-harness` or `config/secondmate-harness` names an unverified adapter, report it and fall back only to a verified adapter rather than launching it.

`docs/configuration.md` owns dispatch-profile and runtime-backend schemas, `bin/fm-harness.sh` owns static resolution, and `bin/fm-spawn.sh` owns launch flags and fail-closed validation.
When dispatch profiles exist, consult them at every crewmate or scout intake and pass the resolved concrete profile required by `fm-spawn`.
Routing precedence is an explicit per-task captain override, then the best-fit configured rule, then the configured default, then the static crewmate harness.
Firstmate alone resolves a matched profile array: begin with `quota-axi`'s default TOON at that intake, using the skill's narrow TOON-then-`--json` fallback only for genuine ambiguity, evaluate every configured candidate against that current output, and choose with inspectable `spendPriority` as the one quota-perspective ranker after the skill's eligibility, reasoning-class, and runway-feasibility gates.
Account for every candidate with the catalog evidence, provider relationship, applicable quota and authentication facts, remaining uncertainty, fit and reasoning class, and the spendPriority and runway evidence used in selection; never omit a candidate, guess, fall back silently, or call the result quota-informed without them.
Establish model support and provider family from that harness's own authoritative catalog, then apply the [account and scope matching rules in `quota-array-dispatch`](../quota-array-dispatch/SKILL.md#1-eligibility).
Missing model-level quota, a missing authentication source, unmeasurable headroom, or unmodeled authentication is disclosed uncertainty that keeps a candidate eligible, never a credential or login escalation.
Only concrete contradictory evidence blocks a candidate, such as an authoritative catalog proving the model unsupported or proof that the credential selected for that surface is unusable; never infer a credential store, provider family, or quota mapping from a harness, model, or source name, and never launch another harness's CLI to judge a candidate.
Preserve malformed profile configuration as an actionable error rather than selecting around it.
When every candidate is tight, preserve the captain's strongest-reasoning class rather than silently downgrading it solely to conserve quota; stop and report the tight choice if that class cannot proceed.
Break genuine evidence ties without array-order or harness bias.
`quota-axi` owns how model or product windows relate to bounding account windows and remains data-only.
Run `bin/fm-dispatch-resolve.sh` directly on the written brief in the same turn, with no preflight, and on `clear` pass its `profile:` line to `fm-spawn` unless you state a reason to override; `ambiguous`, `escalate`, `error`, and off all mean the intake above, unchanged (contract: `docs/configuration.md` "Typed dispatch resolution").
The generic effort fallback and its precedence are owned by `harness-adapters`: explicit captain and standing configured effort win; otherwise use low for well-understood explicit work, xhigh for ambiguous investigation or design, intermediate levels proportionally, and never max without explicit captain preference.
Do not add model-specific versions of that policy.

`secondmate-provisioning` owns secondmate harness pins and inherited local material, while `harness-adapters` owns the harness consequences.
Dispatch only on a backend that `fm-spawn` validates as spawn-capable; pass an explicit per-spawn `--backend` only under that exact task's own authority, never as later-task precedent (selection contract: [`docs/configuration.md`](../../../docs/configuration.md) "Runtime backend").
A missing dependency, authentication failure, unsupported backend, or version refusal is a blocker; never silently retry on another backend.

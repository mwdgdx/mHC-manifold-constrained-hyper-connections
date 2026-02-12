# Infra Workflow Constitution (v1 Draft)

This document defines the constitutional contract for the infra workflow.
It is normative for `infra_scripts/` and intended to make the infra surface:

- all-inclusive (full lifecycle, including teardown policy)
- invariant (same rules every run)
- auto-communicative (runtime self-describes its decisions)
- constitutional (explicit laws, not implicit conventions)

## Scope

Applies to:

- `infra_scripts/workflow.sh`
- `infra_scripts/workflow.env`
- `docs/remote-experiment-workflow.md`

Does not define model/training internals beyond the infra contract.

## Constitutional Laws

All laws are MUST unless explicitly marked SHOULD/MAY.

### Law 1: Canonical Config

- Active config MUST be `infra_scripts/workflow.env`.
- `WORKFLOW_CONFIG` overrides MUST be rejected unless `WF_ALLOW_OVERRIDE=1`.
- Runtime MUST print:
  - `active_config_path`
  - `active_config_sha256`
  - `override_enabled`

### Law 2: Single Canonical Lifecycle Entrypoint

- A single composite command MUST exist as canonical lifecycle runner:

```bash
bash infra_scripts/workflow.sh flow
```

- Primitive commands (`pod-up`, `checkout`, `sweep-start`, etc.) MAY remain, but docs MUST define `flow` as the constitutional path.

### Law 3: Target Resolution and Immutability

- Target resolution precedence for a flow run MUST be:
  1) explicit `LIUM_TARGET`
  2) auto-bind from `pod-up` result (if provisioning happened)
  3) fail fast
- Once resolved, target MUST be immutable for the flow run.
- Runtime MUST print `target_source` (`explicit|autobind`) and `resolved_target`.

### Law 4: Noninteractive Safety

- In non-TTY mode, commands that can prompt MUST fail fast unless noninteractive consent is explicit.
- For pod provisioning, `LIUM_YES=1` (or equivalent) MUST be required in non-TTY mode.
- No hidden hangs, no implicit stdin waiting.

### Law 5: Phase Contracts

- Every phase MUST declare:
  - preconditions
  - postconditions
  - produced artifacts
  - failure code family
- No phase may perform undeclared side effects.

### Law 6: Provenance and Evidence

- Every flow MUST write machine-readable evidence locally and remotely.
- Evidence MUST include:
  - config fingerprint
  - resolved target/transport
  - FSM transitions
  - phase outcomes
  - artifact locations

### Law 7: Explicit Destruction Policy

- Teardown MUST be explicit policy, never implicit behavior.
- Default MUST be `teardown=keep`.
- Delete mode MUST require explicit opt-in.

### Law 8: Doc/Script Consistency

- `docs/remote-experiment-workflow.md` MUST mirror script behavior for:
  - lifecycle order
  - required vars
  - teardown semantics
  - provenance artifacts

### Law 9: Phase-End Constitutional Validation (Zero Negotiation)

- Every phase MUST run a constitutional validation gate before the next phase starts.
- Validation MUST be fail-closed:
  - pass -> continue
  - fail or unverified -> halt the flow
- No implicit retries, no soft warnings, no manual interpretation required to proceed.
- Validation MUST include:
  1) deterministic correctness checks
  2) subagent constitutional audit
  3) a persisted verdict artifact

## Constitutional Lifecycle

Canonical phases:

```
P00 PRECHECK
P10 PROVISION (optional)
P20 TARGET_BIND
P30 POD_READY
P40 BOOTSTRAP
P50 CHECKOUT
P60 SWEEP
P70 MONITOR
P80 FETCH (optional)
P90 TEARDOWN (policy-driven)
P99 SUMMARY
```

ASCII flow:

```
flow
 |
 +--> P00 precheck (vars, tty, config hash, policy)
 |
 +--> P10 provision? -----------------------------+
 |                                                |
 +--> P20 target_bind (explicit or autobind)      |
 |                                                |
 +--> P30 pod_ready (status + reachability)       |
 +--> P40 bootstrap                               |
 +--> P50 checkout                                |
 +--> P60 sweep (start/resume/skip)               |
 +--> P70 monitor (wait or snapshot)              |
 +--> P80 fetch? ---------------------------------+
 +--> P90 teardown (keep/delete)
 +--> P99 summary (constitutional verdict)
```

## Phase Contract Table

| Phase | Preconditions | Postconditions | Required Artifacts |
|------:|---------------|----------------|--------------------|
| P00 | config file exists; legal policy flags | config hash computed; mode declared | `flow.start.json` + `phase.P00.*` |
| P10 | provisioning mode is `auto` | pod created or phase skipped | `phase.P10.*` |
| P20 | pod identity available | `resolved_target` locked | `phase.P20.*` |
| P30 | target locked | reachable remote; FSM >= `POD_READY` | `phase.P30.*` |
| P40 | legal FSM state | prereqs/helpers done; FSM >= `BOOTSTRAPPED` | `phase.P40.*` |
| P50 | repo/data path vars valid | checkout complete; torch/data contracts pass; FSM >= `CHECKED_OUT` | `phase.P50.*` |
| P60 | sweep manifest available | sweep launched or resumed; FSM `SWEEP_RUNNING` or `SWEEP_COMPLETED` | `phase.P60.*` |
| P70 | status endpoint reachable | summary counts produced; FSM updated | `phase.P70.*` |
| P80 | fetch policy requests artifacts | local extraction complete | `phase.P80.*` |
| P90 | teardown policy explicit | pod kept or deleted deterministically | `phase.P90.*` |
| P99 | all prior phase statuses known | final verdict emitted | `flow.summary.json` |

## Phase-End Constitutional Court

Each phase MUST end with a two-layer validation court.

```
phase execution
   |
   +--> deterministic validator (objective checks)
   |
   +--> subagent constitutional auditor (rule compliance)
   |
   +--> verdict merge (AND gate)
           pass + pass => continue
           else        => halt
```

### Layer A: Deterministic Validator (Required)

Objective, machine-checkable assertions. Examples:

- command exit code and timeout state
- required artifact existence and JSON parseability
- FSM transition correctness
- target immutability within run context
- config hash continuity

Output artifact (required):

```text
phase.<Pxx>.deterministic.json
```

### Layer B: Subagent Constitutional Auditor (Required)

Read-only subagent validates constitutional compliance against this document.

- MUST receive phase evidence pack + applicable law IDs.
- MUST return structured verdict:
  - `pass|fail|unverified`
  - violated law IDs
  - evidence references
  - remediation text

Output artifact (required):

```text
phase.<Pxx>.constitutional.json
```

### Verdict Merge Rule (Zero Negotiation)

The phase verdict is:

```text
phase_pass = deterministic_pass AND constitutional_pass
```

If `phase_pass=false`, workflow MUST halt and emit:

```text
phase.<Pxx>.verdict.json
```

with `halt_reason`, violated law IDs, and suggested next command.

### Subagent Constraints

- Subagent MUST be read-only (no mutation tools).
- Subagent MUST be deterministic-input scoped (only provided evidence pack + constitution text).
- Subagent output MUST be machine-readable JSON.
- Subagent timeout/failure MUST be treated as `unverified` and therefore a phase failure.

### Evidence Pack Schema (Minimum)

Per phase, the evidence pack MUST include:

- `flow_id`, `phase_id`, `started_at`, `ended_at`
- `active_config_path`, `active_config_sha256`
- `lium_target` or `ops_default_host`, `transport_hint`, `remote_env_path`
- `fsm_before`, `fsm_after`
- `command_name`, `command_rc`, `phase_status`
- `repo_url`, `teardown_mode`

## Canonical Command Contract

Implemented command:

```bash
bash infra_scripts/workflow.sh flow \
  --provision auto|skip \
  --sweep start|resume|skip \
  --wait true|false \
  --fetch none|run:<id>|all \
  --teardown keep|delete
```

Recommended defaults:

- `--provision=auto`
- `--sweep=start`
- `--wait=false`

The parser also accepts `--key=value` forms for the same options.

## Implementation Hooks

Current enforcement knobs in `infra_scripts/workflow.env`:

- `WF_PHASE_COURT_ENFORCE=1`
- `WF_SUBAGENT_VALIDATOR_CMD="python3 infra_scripts/workflow_phase_court.py"`
- `WF_SUBAGENT_VALIDATOR_TIMEOUT_SECS=120`
- `WF_FLOW_EVIDENCE_DIR="artifacts/pod_logs/_flows"`

Default subagent auditor entrypoint:

```text
infra_scripts/workflow_phase_court.py
```

## Runtime Auto-Communication Requirements

Every run MUST print a constitutional header before work starts:

```text
WF_CONSTITUTION_VERSION=1
active_config_path=infra_scripts/workflow.env
active_config_sha256=<sha256>
override_enabled=<0|1>
resolved_target=<value>
target_source=<explicit|autobind>
transport=<lium|ssh>
remote_env_path=<path>
fsm_state_file=<path>
flow_id=<timestamp-hash>
```

Every phase completion MUST print one line:

```text
PHASE=<Pxx> STATUS=<ok|skip|fail> CODE=<int> ARTIFACT=<path>
```

Validation gate output MUST also print one line:

```text
PHASE=<Pxx> COURT=<pass|fail> DET=<pass|fail> CONST=<pass|fail|unverified> VERDICT=<path>
```

## Provenance Layout

```
local:
  artifacts/pod_logs/_flows/<flow_id>/
    flow.start.json
    phase/*.json
    flow.summary.json

remote:
  ${OPS_REMOTE_OUTPUTS_DIR}/_control/
    workflow_state.json
  ${OPS_REMOTE_OUTPUTS_DIR}/_manifests/
    sweep-latest.csv
    sweep-<timestamp>.csv
    workflow-<timestamp>.env
    flow-<flow_id>.json
```

## Policy Matrix

| Policy | Allowed Values | Default | Constitutional Effect |
|--------|----------------|---------|-----------------------|
| Override config | `WF_ALLOW_OVERRIDE=0|1` | `0` | Disallow ad-hoc config path drift by default |
| Teardown | `keep|delete` | `keep` | Prevent accidental destructive end-of-flow behavior |
| Noninteractive | `true|false` | auto | Prevent interactive stalls in automation |
| Force clean checkout | `CHECKOUT_FORCE_CLEAN=0|1` | `0` | Explicitly gates destructive git reset |

## Failure Semantics

- Precheck failure MUST stop before any remote mutation.
- Each phase MUST return unique code namespace (example):
  - `1xx`: configuration and policy violations
  - `2xx`: provisioning/target failures
  - `3xx`: bootstrap/checkout failures
  - `4xx`: sweep/monitor failures
  - `5xx`: fetch/teardown failures
- Summary MUST include first-failure phase and code.

## Required Documentation Changes (Constitution Compliance)

`docs/remote-experiment-workflow.md` SHOULD be updated to:

1. Declare `flow` as canonical lifecycle command.
2. Include teardown section with explicit keep/delete policy.
3. Explain target autobind vs explicit binding.
4. Document noninteractive policy requirements.
5. Document evidence files and where they live.

## Migration Plan

1. Add `flow` command without removing primitive commands.
2. Mark primitive-only flows as legacy in help output.
3. Add `doctor` command for preflight diagnostics.
4. After one stabilization window, enforce canonical path in docs and CI checks.

## Constitutional Acceptance Criteria

This constitution is considered implemented when:

- `flow` executes full lifecycle deterministically from one command.
- noninteractive runs cannot stall on prompts.
- target binding is explicit and immutable per run.
- teardown policy is explicit and auditable.
- runtime outputs and JSON artifacts are sufficient to reconstruct run decisions without guesswork.
- each phase is blocked by a zero-negotiation constitutional court gate.

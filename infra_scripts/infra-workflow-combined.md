# Infra Workflow Combined Guide

This is the single combined infra reference for remote experiment orchestration in this repo.
It merges the operational contract, constitutional rules, and design intent previously split across multiple docs.

## Scope

This guide governs:

- `infra_scripts/workflow.sh`
- `infra_scripts/workflow.env`
- remote experiment execution, monitoring, artifact fetch, and teardown policy

It does not define model internals or research algorithm details.

## Canonical Files and Entrypoint

- Config: `infra_scripts/workflow.env`
- Script: `infra_scripts/workflow.sh`
- Canonical lifecycle command:

```bash
bash infra_scripts/workflow.sh flow \
  --provision auto \
  --sweep start \
  --wait false \
  --fetch none \
  --teardown keep
```

Primitive commands remain available, but `flow` is the default constitutional path.

## Constitutional Rules

All rules are MUST unless otherwise stated.

1. **Canonical Config**
   - Active config is `infra_scripts/workflow.env`.
   - `WORKFLOW_CONFIG` override is blocked unless `WF_ALLOW_OVERRIDE=1`.
   - Runtime prints active config path/hash and override status.

2. **Single Lifecycle Path**
   - `flow` is the authoritative end-to-end lifecycle command.

3. **Target Resolution and Immutability**
   - Resolution order: explicit `LIUM_TARGET` -> autobind from provisioning -> fail.
   - Resolved target is immutable for the run.

4. **Noninteractive Safety**
   - Prompt-prone actions in non-TTY must fail fast unless explicit noninteractive consent is set.

5. **Phase Contracts**
   - Every phase has preconditions, postconditions, artifacts, and failure code family.

6. **Provenance and Evidence**
   - Every run writes machine-readable evidence sufficient for replay and debugging.

7. **Explicit Teardown Policy**
   - Teardown is never implicit.
   - Default teardown is `keep`; delete must be explicit.

8. **Doc/Script Consistency**
   - Runtime behavior, config contract, and docs must stay aligned.

9. **Phase-End Constitutional Court**
   - Each phase must pass deterministic checks and constitutional audit.
   - Any fail/unverified verdict halts the flow.

## Lifecycle Phases

```text
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

## Command Contract

`flow` options:

- `--provision auto|skip`
- `--sweep start|resume|skip`
- `--wait true|false`
- `--fetch none|all|run:<id>`
- `--teardown keep|delete`

Both `--key value` and `--key=value` are supported.

Useful support commands:

```bash
bash infra_scripts/workflow.sh checklist-status
bash infra_scripts/workflow.sh checklist-reset
bash infra_scripts/workflow.sh fsm-status
bash infra_scripts/workflow.sh fsm-reset INIT
bash infra_scripts/workflow.sh task-list
```

## Required Configuration Areas

Minimum setup in `infra_scripts/workflow.env`:

- Pod/host target: `LIUM_TARGET` or `OPS_DEFAULT_HOST`
- Repo checkout source: `REPO_URL`, and `CHECKOUT_BRANCH` or `CHECKOUT_PR`
- Paths: `OPS_REMOTE_REPO`, `OPS_REMOTE_OUTPUTS_DIR`, `DATA_DIR`

Recommended constitutional defaults:

- `WF_CONSTITUTION_VERSION=1`
- `WF_ALLOW_OVERRIDE=0`
- `WF_REQUIRE_NONINTERACTIVE_SAFE=1`
- `WF_DEFAULT_TEARDOWN=keep`
- `WF_PHASE_COURT_ENFORCE=1`

## FSM, Tasks, and Sweep Manifest

- FSM state file defaults to `${OPS_REMOTE_OUTPUTS_DIR}/_control/workflow_state.json`
- Typical path: `INIT -> POD_READY -> BOOTSTRAPPED -> CHECKED_OUT -> SWEEP_RUNNING -> SWEEP_COMPLETED`
- Tracked task artifacts live under `${OPS_REMOTE_OUTPUTS_DIR}/_tasks/<task_id>/`
- Sweep CSV schema:

```text
run_id,config,seed,overrides,notes
```

## Evidence and Provenance Artifacts

Local flow evidence root (default): `artifacts/pod_logs/_flows`

Per flow:

- `flow.start.json`
- `phase.<Pxx>.evidence.json`
- `phase.<Pxx>.deterministic.json`
- `phase.<Pxx>.constitutional.json`
- `phase.<Pxx>.verdict.json`
- `flow.summary.json`

Remote provenance under `${OPS_REMOTE_OUTPUTS_DIR}` includes control state and manifest snapshots.

## Reliability and Error Policy

Use deterministic error handling tiers:

- Correctable: retry and continue with counters
- Uncorrected: isolate failing run where possible
- Fatal: halt flow/sweep
- Policy violation: immediate halt and explicit verdict

Escalate repeated correctable errors before they become hard failures.

## Practical Guardrails

- Prefer fixed, typed workflow actions over free-form shell composition.
- Keep workflow transitions explicit and auditable.
- Preserve immutable run evidence to reconstruct decisions without guesswork.
- Fail closed on constitutional uncertainty (including validator timeout).

## Legacy Detailed Docs

For deep detail and historical context, see:

- `docs/infra-workflow-constitution.md`
- `docs/remote-experiment-workflow.md`
- `docs/agentic-workflow-design.md`

This combined guide is the main infra entrypoint to import into `main`.

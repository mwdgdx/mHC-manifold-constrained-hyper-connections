# Open Challenges: Sweep Monitoring and Run Reliability

This document captures current gaps in `infra_scripts/workflow.sh` and `infra_scripts/workflow.cfg` for production-grade experiment orchestration.

## 1) Run timeout is disabled by default

- Current behavior: `RUN_TIMEOUT_SECS="0"` means a single hung run can block the sweep indefinitely.
- Impact: no bounded completion time for a campaign.
- Needed: enforce a non-zero default timeout and require explicit opt-out.

## 2) Sweep execution is fail-fast on first failed run

- Current behavior: `_sweep_run_all` exits immediately on first non-zero run.
- Impact: later experiments are never executed after one failure.
- Needed: continue-on-failure mode by default, with optional fail-fast override.

## 3) No retry policy for transient failures

- Current behavior: timeouts/NCCL/network flakiness are treated as terminal for that run.
- Impact: avoidable data loss from transient infrastructure failures.
- Needed: retry budget with backoff and failure-class matching.

## 4) Stall detection has no automated remediation

- Current behavior: `sweep-watch` can label state `SWEEP_STALLED`, but does not restart/resume runs.
- Impact: human intervention required for routine recovery.
- Needed: auto-recover from stalled states (kill/restart run, then continue queue).

## 5) Monitoring is snapshot-based, not supervisor-based

- Current behavior: status/watch commands are point-in-time checks.
- Impact: no persistent control loop enforcing liveness and progress guarantees.
- Needed: a long-running supervisor mode with progress heartbeat checks.

## 6) No progress heartbeat SLA per run

- Current behavior: no standard rule like "no stdout progress for N minutes => mark stalled".
- Impact: hangs can consume expensive hardware unnoticed between manual checks.
- Needed: heartbeat timeout separate from wall-clock timeout.

## 7) Weak failure taxonomy

- Current behavior: summary tracks `ok/state/exit_code`, but root-cause classes are not normalized.
- Impact: hard to query campaign health by failure type (OOM, NCCL timeout, data, auth).
- Needed: structured failure classifier in `summary.json`.

## 8) Manifest source mismatch risk during fetch

- Current behavior: execution uses remote `_manifests/sweep-latest.csv`, while `fetch-all` reads local `SWEEP_CSV`.
- Impact: local config drift can fetch artifacts for the wrong campaign.
- Needed: bind fetch/status to immutable campaign manifest ID.

## 9) FSM artifact state can be misleading

- Current behavior: `ARTIFACTS_SYNCED` can be set relative to current local manifest, not necessarily the launched campaign.
- Impact: false confidence in completeness.
- Needed: campaign-scoped sync completeness checks.

## 10) Run namespace is not campaign-isolated

- Current behavior: outputs are keyed by `run_id` under shared root.
- Impact: collisions/stale summaries can block or contaminate new sweeps.
- Needed: campaign directory prefix and immutable run metadata linkage.

## 11) Task diagnostics can hang forever

- Current behavior: `TASK_TIMEOUT_SECS="0"` allows `task-run` to run unbounded.
- Impact: even debugging workflows can consume resources indefinitely.
- Needed: non-zero default task timeout with per-task override.

## 12) W&B verification is not enforced as a quality gate

- Current behavior: runs can complete locally even if remote W&B expectations are unmet.
- Impact: monitoring/reporting can silently degrade.
- Needed: optional strict gate that verifies run registration and heartbeat in W&B when enabled.

---

## Minimum Professional Baseline

1. Non-zero defaults for `RUN_TIMEOUT_SECS` and `TASK_TIMEOUT_SECS`.
2. Continue-on-failure sweep execution plus retry-on-transient policy.
3. Automated stalled-run remediation and resume of missing/failed queue entries.
4. Immutable campaign manifest ID used by launch, status, and fetch.
5. Structured failure class in run summary for fleet-level reporting.

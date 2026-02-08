# Research Ops Blueprint (Config-Driven, Pod-First)

This document is a recommendation for making `remote-ops` + scripts *general across any work*, with a single project-level configuration that fully specifies what you need to run, track, and monitor experiments on ephemeral GPU pods with a persistent `/mnt` volume.

It is written to reflect what we learned from bringing up an 8x A100 pod, running a PR validation run, and making W&B reliable for non-interactive sessions.

## Goals

- One command to launch work and one place to find the truth.
- Reproducible runs (someone else can re-run the same thing later).
- Uniform monitoring and artifact collection across *all* workloads (train / eval / serve).
- Secrets never leak into logs, tmux server environment, or repo history.

## Core Principle: The Run Directory Is The Unit Of Science

Every run (training, eval, service test) must have a durable run directory under a configurable outputs root on `/mnt`.

Recommended canonical root:

- `REMOTE_OUTPUTS_DIR=/mnt/runs` (general across projects)

Recommended run directory layout:

```
/mnt/runs/<project>/<run_id>/
  command.sh
  run_metadata.json
  config_effective.json
  env_snapshot.json
  dataset_manifest.json
  stdout.log
  summary.json
  checkpoints/
    ckpt_last.pt
    ckpt_best.pt
  wandb/
  events.jsonl              # optional structured timeline
  metrics.jsonl             # optional streaming metrics
```

### Required files (minimal contract)

If you want `ops status`, `ops fetch`, `ops validate`, `ops report` to be reliable, standardize on these as the minimum:

- `command.sh`: exact command executed (no secrets)
- `run_metadata.json`: run_id, git commit, branch/ref, pod id, timestamps
- `stdout.log`: full stdout/stderr (tee'd)
- `summary.json`: written on completion (success/failure marker)

Everything else is optional but highly recommended (`config_effective.json`, `env_snapshot.json`, `dataset_manifest.json`).

## Unify The Two Existing Worlds

Today there are two “artifact contracts”:

- Training scripts + pod runners naturally write to `/mnt/experiments/mhc/<run-id>` and do not emit the `ops.py` contract files.
- `infra_scripts/ops.py` expects `/mnt/pod_artifacts/outputs/<run-id>` and uses `summary.json` as the completion marker.

Recommendation:

- Stop hardcoding multiple output roots.
- Move to a single configurable `REMOTE_OUTPUTS_DIR` and make *all* runners conform to the same minimum contract.

In practice this means:

- Update training launchers (`pod-smoke-run.sh`, any training submit path) to always write the minimum contract.
- Update `ops.py` defaults to point to the same outputs root.

## Project Configuration: One File That Nails The Spec

Adopt a single project config that describes:

- hosts and how to reach them (ssh alias, pod id discovery)
- repo checkout details
- outputs root and artifact contract
- data/caches placement on `/mnt`
- secrets materialization strategy
- run presets (common “jobs”)

### Recommended config structure

Store a committed, secret-free config:

- `configs/ops/project.json` (committed)

Store machine/user overrides uncommitted:

- `configs/ops/project.local.json` (gitignored)

Secrets should be referenced by *path* only (e.g. `/mnt/set-wandb-api-key.sh`), never embedded.

### Example `configs/ops/project.json`

```json
{
  "project": {
    "name": "mhc",
    "remote_outputs_dir": "/mnt/runs/mhc",
    "remote_repo_dir": "/root/work/mHC-manifold-constrained-hyper-connections",
    "remote_repo_url": "https://github.com/tokenbender/mHC-manifold-constrained-hyper-connections.git",
    "venv_python": "/root/work/mHC-manifold-constrained-hyper-connections/.venv/bin/python"
  },
  "storage": {
    "hf_home": "/mnt/hf",
    "datasets_root": "/mnt/data",
    "wandb": {
      "mode": "auto",
      "project": "mhc-nanogpt-dev",
      "ensure_creds_script": "/mnt/set-wandb-api-key.sh"
    }
  },
  "tmux": {
    "enabled": true,
    "session_prefix": "run",
    "watch_interval_sec": 20,
    "heartbeat_file": "heartbeat.txt"
  },
  "artifact_contract": {
    "required": [
      "command.sh",
      "run_metadata.json",
      "stdout.log",
      "summary.json"
    ],
    "completion_file": "summary.json"
  },
  "presets": {
    "hc_small": {
      "kind": "nanogpt_train",
      "config": "examples/nanogpt/config/train_fineweb10B_hc.py",
      "overrides": {
        "max_iters": 50,
        "eval_interval": 10,
        "eval_iters": 1,
        "batch_size": 8,
        "block_size": 256,
        "gradient_accumulation_steps": 8,
        "wandb_log": "auto"
      }
    },
    "mhc_small": {
      "kind": "nanogpt_train",
      "config": "examples/nanogpt/config/train_fineweb10B_mhc.py",
      "overrides": {
        "max_iters": 50,
        "eval_interval": 10,
        "eval_iters": 1
      }
    }
  }
}
```

This config becomes the single source of truth for:

- where outputs go
- how W&B is enabled
- which presets exist
- how to construct a run

## Secrets: Durable Credentials, Not Ephemeral Exports

Lesson learned: exporting `WANDB_API_KEY` in a bootstrap subprocess does not persist for future `lium exec` sessions, and can also leak into tmux server environments.

Recommendation:

- Standardize on *materializing* W&B credentials into `~/.netrc`.
- Make the credential materializer idempotent and verifiable (parse netrc via python).
- Unset `WANDB_API_KEY` after writing `~/.netrc`.

Operationally:

- `/mnt/set-wandb-api-key.sh` should write/repair `~/.netrc`.
- A one-time upgrade script should exist for migrating export-only scripts.

## Monitoring: Make It Uniform

Your monitoring should be independent of whether you launched training, eval, or a service.

Minimum recommended monitoring signals in the run dir:

- `stdout.log` (full logs)
- `heartbeat.txt` updated periodically
- `summary.json` for completion

Recommended primitives:

- Always run long work in tmux (detached)
- Always tee logs to `stdout.log`
- Always update a heartbeat file (watcher loop)

Then `ops status` can reliably show:

- last heartbeat time
- last 50 lines of stdout
- pod GPU snapshot (`nvidia-smi`)
- W&B URL / run id (if enabled)

## Reproducibility: Snapshot What Actually Ran

For nanoGPT-style “config = python file + overrides”, you must write the effective configuration at run start.

Recommendation:

- `config_effective.json`:
  - config path
  - CLI overrides
  - derived values that affect behavior (e.g. DDP-adjusted grad accumulation)
- `env_snapshot.json`:
  - python version
  - pip freeze
  - torch/cuda versions
  - GPU model/count
- `dataset_manifest.json`:
  - dataset name
  - shard filenames used
  - sizes + checksums (or at least mtime + size)
  - HF dataset repo/version if applicable

This is the difference between “it trained” and “it is a scientific record.”

## Recommended CLI Surface (What `ops` Should Grow Into)

Keep `ops` as the single entry point. Make it read `configs/ops/project.json`.

Suggested commands:

- `ops pod up|status|rm`
- `ops repo sync --ref <sha|branch|pr:N>`
- `ops run submit --preset <name> [--ref ...] [--run-id ...]`
- `ops run status --run-id ...`
- `ops run tail --run-id ...`
- `ops run fetch --run-id ... --to artifacts/pod_logs/...`
- `ops run report --glob artifacts/pod_logs/**/summary.json`

Under the hood:

- `kind=nanogpt_train` calls a runner that matches the run directory contract.
- `kind=vllm_serve` starts a tmux session and writes logs into the same run directory.
- `kind=eval` runs an eval entrypoint and writes `results.jsonl` + `summary.json`.

## Implementation Roadmap (Incremental)

1) Unify output root:
   - Introduce `REMOTE_OUTPUTS_DIR` and make both training and ops flows default to it.
2) Enforce the minimum run contract for training:
   - Ensure `command.sh`, `run_metadata.json`, `stdout.log`, `summary.json` exist for every training run.
3) Add reproducibility snapshots:
   - Write `config_effective.json`, `env_snapshot.json`, `dataset_manifest.json`.
4) Make `ops` config-driven:
   - Add `--project-config` and `--preset` support.
5) Make reporting boring:
   - `ops validate` and `ops report` work for all run kinds.

## Non-Goals (Avoid Scope Creep)

- Building a full workflow orchestrator.
- Replacing W&B.
- Abstracting away python configs entirely (you can keep them; just snapshot them).

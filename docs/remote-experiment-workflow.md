# Remote Experiment Workflow (Config-Driven)

This repo uses a single config file + single entrypoint script to run end-to-end remote experiments on GPU pods (Lium-first, SSH fallback).

## Canonical Files

- Config: `infra_scripts/workflow.env`
- Script: `infra_scripts/workflow.sh`

The script syncs the config to the pod at `REMOTE_ENV_PATH` (default `/mnt/project.env`) and then runs all remote steps from that config.

## What Goes In Config vs Docs

- Config (`infra_scripts/workflow.env`): anything that changes by user/project/platform (pod target, repo URL, paths, volume spec, sweep selection, W&B).
- Docs: only placeholders + workflow explanation (no hardcoded org/repo/branch).

## Minimal Setup

1) Edit `infra_scripts/workflow.env`:
- REQUIRED: `LIUM_TARGET` (pod name/ID or index from `lium ps`) OR `OPS_DEFAULT_HOST` (ssh alias)
- REQUIRED: `REPO_URL` (git URL to clone)
- Set `CHECKOUT_BRANCH` or `CHECKOUT_PR`
- Confirm: `OPS_REMOTE_REPO`, `OPS_REMOTE_OUTPUTS_DIR`, `DATA_DIR`

Torch/CUDA requirement: this workflow assumes your **pod image already includes GPU-enabled PyTorch**.
`checkout` creates the venv with `--system-site-packages` and will fail fast if `import torch` fails or
`torch.cuda.is_available()` is false.

If torch lives in a non-default python (e.g. conda), set `REMOTE_PYTHON_BIN` to that python.
If you already created a venv in the repo, set `VENV_RECREATE=1` once and rerun `checkout`.

2) (Optional) If your environment provides helper scripts on the persistent volume:
- `BOOTSTRAP_SCRIPT=/mnt/bootstrap-pod.sh`
- `WANDB_SETUP_SCRIPT=/mnt/set-wandb-api-key.sh` (should write `~/.netrc`)

## Workflow FSM (First-Class)

The workflow now persists a remote state file and enforces legal command transitions.

- Default state file: `${OPS_REMOTE_OUTPUTS_DIR}/_control/workflow_state.json`
- Toggle enforcement: `WF_FSM_ENFORCE=1` (default)
- Optional override: `WF_STATE_FILE=/custom/path/workflow_state.json`

Useful commands:

```bash
bash infra_scripts/workflow.sh fsm-status
bash infra_scripts/workflow.sh fsm-reset INIT
```

Typical transition path:

`INIT -> POD_READY -> BOOTSTRAPPED -> CHECKED_OUT -> SWEEP_RUNNING -> SWEEP_COMPLETED`

If a command is called in an illegal state, it fails fast with a clear state/allowed-state error.

## Tracked Tasks (Jenkins-Style)

For long-running remote actions that you want to observe and reliably classify as success/failure/timeout,
use the tracked task wrapper.

Contract:
- Remote task root: `${OPS_REMOTE_OUTPUTS_DIR}/_tasks/<task_id>/`
- Files:
  - `status.json`: state machine (`pending` -> `running` -> `success|failed|timed_out`)
  - `stdout.log`: combined output
  - `command.sh`: exact command executed
- Debug session: tasks run in tmux session `${WF_TMUX_SESSION}` (one window per task).

Examples:

```bash
# Start a tracked task (runs in tmux)
bash infra_scripts/workflow.sh task-run \
  --id preflight-$(date +%Y%m%d-%H%M%S) \
  --timeout-secs 600 \
  --cmd 'nvidia-smi && df -h /mnt'

# Monitor
bash infra_scripts/workflow.sh task-status --id preflight-<timestamp>
bash infra_scripts/workflow.sh task-wait --id preflight-<timestamp> --timeout-secs 900
bash infra_scripts/workflow.sh task-list

# Watch live
lium ssh "$LIUM_TARGET"
tmux attach -t "$WF_TMUX_SESSION"
```

## Sweep CSV Format

CSV columns:

```
run_id,config,seed,overrides,notes
```

Where:
- `run_id`: directory name under `${OPS_REMOTE_OUTPUTS_DIR}/<run_id>/`
- `config`: path relative to `examples/nanogpt/` (e.g. `config/train_fineweb10B_mhc.py`)
- `seed`: integer
- `overrides`: space-separated `train.py` overrides (wrap in quotes)
- `notes`: freeform

Generate a starter file at `SWEEP_CSV`:

```bash
bash infra_scripts/workflow.sh sweep-csv-template
```

## End-to-End Mock Flow

### 1) (Optional) Rent a pod

```bash
bash infra_scripts/workflow.sh pod-up
```

Then set `LIUM_TARGET` in `infra_scripts/workflow.env` (recommended: set it to your pod name).

### 2) Verify pod + volume

```bash
bash infra_scripts/workflow.sh pod-status
```

### 3) Bootstrap prereqs (and optional helpers)

```bash
bash infra_scripts/workflow.sh bootstrap
```

This can auto-install missing prereqs via apt if `AUTO_INSTALL_PREREQS=1`.

By default, `WANDB_SETUP_SCRIPT` only runs when `SWEEP_WANDB=1` (or when `RUN_WANDB_SETUP=1`).

### 4) Checkout repo + install deps + validate data

```bash
bash infra_scripts/workflow.sh checkout
```

If FineWeb shards are missing, either pre-load them under `DATA_DIR` or set `DOWNLOAD_FINEWEB=1` to download a minimal shard pair.

If `DATA_DIR` is under `/mnt` and `/mnt` is mounted via s3fs, the workflow will stage the download on local disk and then copy
completed shards into `DATA_DIR` (to avoid s3fs append/resume I/O issues during download).

### 5) Start a tmux sweep

```bash
bash infra_scripts/workflow.sh sweep-start
```

Optional: enforce a per-run wall-clock timeout by setting `RUN_TIMEOUT_SECS` in `infra_scripts/workflow.env`.

Optional: if you want training artifacts to be written on fast local disk (and mirrored into the durable run directory),
set:
- `RUN_OUT_MODE=local_sync`
- `RUN_OUT_LOCAL_ROOT=/path/on/local/disk` (default is `${OPS_REMOTE_REPO}/examples/nanogpt/out`)
- `SYNC_INTERVAL_SECS=<seconds>`

In `local_sync` mode, `train.py` writes to `RUN_OUT_LOCAL_ROOT/<run_id>/` and the workflow runs an rsync loop to keep
`${OPS_REMOTE_OUTPUTS_DIR}/<run_id>/` up to date (logs + status still live on the durable directory).

What happens:
- The sweep CSV is uploaded to `${OPS_REMOTE_OUTPUTS_DIR}/_manifests/sweep-latest.csv` and timestamp-copied under `_manifests/` for provenance.
  This avoids writing the CSV into the remote git checkout (`${OPS_REMOTE_REPO}`).
- A tmux session `${SWEEP_TMUX_SESSION}` is created with a single `sweep` window.
- The `sweep` window runs `infra_scripts/workflow.sh _sweep_run_all` and executes the CSV sequentially.
- Each CSV row is launched with `torchrun` using *all visible GPUs* (respecting `CUDA_VISIBLE_DEVICES` if set).

### 6) Monitor progress

```bash
bash infra_scripts/workflow.sh sweep-status
```

This prints a summary based on whether `${OPS_REMOTE_OUTPUTS_DIR}/<run_id>/summary.json` exists and has `{"ok": true}`.

To watch live logs, attach to tmux on the pod:

```bash
# if using Lium
lium ssh "$LIUM_TARGET"
tmux attach -t "$SWEEP_TMUX_SESSION"
```

### 7) Fetch a run locally

```bash
bash infra_scripts/workflow.sh fetch-run <run_id>
```

Artifacts are extracted under `${LOCAL_ARTIFACTS_DIR}/<run_id>/`.

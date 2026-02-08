# Sweep Postmortem (2026-02-08)

This note records what went wrong during the first FineWeb10B sweep attempt on a Lium GPU pod, what was fixed in-repo, and what is safe/recommended for the next attempt.

## Goal

- Run `infra_scripts/sweeps/fineweb10B_full_sweep.csv` on an 8x GPU pod.
- Persist all artifacts under `/mnt/pod_artifacts/outputs/<run_id>/` using the run-artifact contract (`stdout.log`, `summary.json`, `run_metadata.json`, etc.).
- Allow both operator + user to monitor via SSH + tmux.

## What Actually Happened (High-Signal Failures)

### 1) Pod bootstrap could lock us out (authorized_keys clobbered)

- Symptom: after running bootstrap, SSH / `lium exec` stopped working (publickey denied).
- Root cause: `infra_scripts/pod-fastpath.sh` replaced `~/.ssh` by symlinking it to `/mnt/.ssh` or `/mnt/ssh`.
  - Many pod providers inject `authorized_keys` into `~/.ssh`. Replacing the directory removes that file.
- Fix: `infra_scripts/pod-fastpath.sh` now **never symlinks** `~/.ssh`.
  - It keeps `~/.ssh` as a real directory and **copies** persisted keys/config from `/mnt` into it without touching `authorized_keys`.

### 2) FineWeb data handling assumed a symlink that can’t exist

- Symptom: bootstrap failed with: `fineweb10B path exists and is not a symlink: .../examples/nanogpt/data/fineweb10B`.
- Root cause:
  - The repo path `examples/nanogpt/data/fineweb10B/` is a real directory (contains `download.py`).
  - `pod-fastpath` was trying to enforce that path be a symlink to `/mnt/data/fineweb10B`.
- Fix:
  - `examples/nanogpt/data/fineweb10B/download.py` now respects `FINEWEB10B_LOCAL_DIR`.
  - `infra_scripts/pod-fastpath.sh` downloads shards directly into `$DATA_DIR` using:
    - `FINEWEB10B_LOCAL_DIR="$DATA_DIR" python ... download.py 1`
  - No symlink enforcement required.

### 3) `--no-wandb` did not actually disable W&B

- Symptom: a sweep run failed with W&B error: `No API key configured. Use wandb login`.
- Root cause: the sweep runner passed `wandb_log=false` (lowercase), which does not parse as a Python literal in nanoGPT config overrides.
  - Result: W&B remained enabled even though `--no-wandb` was set.
- Fix: `infra_scripts/sweeps/run_fineweb10B_sweep.sh` now passes Python booleans:
  - `--no-wandb` -> `wandb_log=False` (correct)

### 4) Failed runs could be skipped accidentally

- Symptom: a directory containing `summary.json` could be skipped even if the run failed.
- Root cause: skip logic initially used only existence of `summary.json`.
- Fix: runner now skips only if `summary.json` exists AND `ok == true`.
  - If `summary.json` exists but `ok != true`, runner errors (forces operator decision).
  - `--force` now backs up `stdout.log` and `summary.json` to `*.bak-<timestamp>` before rerun.

### 5) Monitoring via `nvidia-smi` “Processes” is misleading

- Symptom: `nvidia-smi` sometimes displayed:
  - `No running processes found`
  while GPU utilization/memory was clearly non-zero.
- Root cause: PID namespace/containerization issues prevent NVML from mapping compute PIDs to visible host process names.
- Reliable monitoring sources:
  - `nvidia-smi --query-gpu=index,utilization.gpu,memory.used --format=csv`
  - `tail -F /mnt/pod_artifacts/outputs/<run_id>/stdout.log`
  - `/mnt/pod_artifacts/outputs/<run_id>/summary.json`

### 6) Only 1 GPU was used on an 8x node

- Symptom: GPU0 at ~100%, GPUs 1-7 idle.
- Root cause: each sweep row ran `python train.py ...` (single-process), so only `cuda:0` was used.
- Fix: added parallel sweep support:
  - `infra_scripts/sweeps/run_fineweb10B_sweep.sh` supports:
    - `--shard-index i --shard-count N` and `--cuda-devices <str>`
  - New launcher: `infra_scripts/sweeps/start_fineweb10B_sweep_tmux.sh`
    - starts `N` tmux sessions (`sweep-0..sweep-(N-1)`)
    - pins each shard to one GPU via `CUDA_VISIBLE_DEVICES=i`
    - shards are disjoint by row index modulo.

## Sweep Outputs Observed On /mnt

Outputs root (contract): `/mnt/pod_artifacts/outputs/`.

Runs created (at snapshot time):
- `fineweb10B-base-6l-default-s1337`: `summary.json` present with `ok: false` (failed run).
- `fineweb10B-base-6l-default-s1338`: `summary.json` present with `ok: true` (completed).
- `fineweb10B-base-6l-default-s1339`: `summary.json` present with `ok: true` (completed).
- `fineweb10B-hc-6l-default-s1337`: in progress when killed (no `summary.json` yet).

Sweep-level log (when running via nohup):
- `/mnt/pod_artifacts/outputs/sweep-fineweb10B.stdout.log`

Note: after requested stop, sweep processes were killed and the pod was terminated. The persistent volume keeps `/mnt/pod_artifacts/outputs/` intact for next pod.

## Recommended Next Attempt (Operator-Friendly)

Use SSH + tmux as the control plane, and use all GPUs via sharded sweeps.

Inside the pod:

```bash
cd /root/work/mHC-manifold-constrained-hyper-connections
git fetch origin
git checkout integrate/research-unified
git pull --ff-only origin integrate/research-unified

# One-time: set defaults on the volume
cp -n infra_scripts/project.env.example /mnt/project.env || true

source infra_scripts/load_project_env.sh

# Bootstrap env + ensure FineWeb shards exist in $DATA_DIR
source infra_scripts/pod-fastpath.sh --branch integrate/research-unified --download-fineweb

# Start 8 shards (one per GPU) in tmux
tmux new -As sweeps
bash infra_scripts/sweeps/start_fineweb10B_sweep_tmux.sh \
  --csv infra_scripts/sweeps/fineweb10B_full_sweep.csv \
  --workdir "${OPS_REMOTE_REPO:-/root/work/mHC-manifold-constrained-hyper-connections}" \
  --out-root "${OPS_REMOTE_OUTPUTS_DIR:-/mnt/pod_artifacts/outputs}" \
  --data-dir "${DATA_DIR:-/mnt/data/fineweb10B}" \
  --wandb-group "${WANDB_GROUP:-fineweb10B-sweep-$(date +%Y%m%d)}" \
  --shards 8 \
  --no-wandb
```

Monitoring:
- `tmux attach -t sweep-0` (or any shard) to see live output.
- `tail -F /mnt/pod_artifacts/outputs/<run_id>/stdout.log`.
- Completion is `summary.json` with `ok: true`.

Rerunning a failed run:
- Use `--force` for the runner (backs up `stdout.log` + `summary.json` and reruns).

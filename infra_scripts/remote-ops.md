# Remote Operations Guide

Manage remote pods, vLLM servers, and evaluation runs using the deterministic ops CLI (`infra_scripts/ops.py`).

## Prerequisites

- Local: Lium CLI (`lium`) installed (PyPI package: `lium.io`, requires Python >= 3.9)
- Local: authenticated (`lium init` completed, or `LIUM_API_KEY` set)
- Local: `ssh` + `scp` available
- Remote pod: `tmux` and `curl` installed (used by `vllm start/status/stop` and run submission)

## Persistent Volume (Strict Default)

We assume a durable volume is always attached and mounted at `/mnt`.

- Standard volume: `${LIUM_DEFAULT_VOLUME:-my_volume}` (verify with `lium volumes list`).
- Prefer `infra_scripts/lium-pod.sh up ...` which attaches `${LIUM_DEFAULT_VOLUME:-my_volume}` by default; opt-out only when necessary with `--no-volume`.
- Use `/mnt` for heavy/persistent state: datasets, HuggingFace cache, experiment outputs, and SSH keys for Git.
- Do NOT put `uv`/`pip` caches on `/mnt` (it is slower); keep those caches on the pod's local disk.

## SSH Keys For Git (Use Persisted Keys)

Do not generate new Git SSH keys per pod. Use the keys stored on the persistent volume.

- Preferred location on volume: `/mnt/.ssh` (fallback: `/mnt/ssh`).
- `infra_scripts/pod-fastpath.sh` will copy persisted keys/config into `~/.ssh` automatically.

Important: do NOT replace `~/.ssh` with a symlink to `/mnt`. Pod providers inject `authorized_keys` into `~/.ssh`, and replacing the directory can lock you out.

## Common Workflows

```bash
# Infra check (host reachable + /mnt mounted)
python3 infra_scripts/ops.py pod status --host "${OPS_DEFAULT_HOST:-lium}"

# vLLM lifecycle
python3 infra_scripts/ops.py vllm start --host "${OPS_DEFAULT_HOST:-lium}" --model-id Qwen/Qwen3-4B-Instruct-2507 --tensor-parallel-size 8
python3 infra_scripts/ops.py vllm status --host "${OPS_DEFAULT_HOST:-lium}"
python3 infra_scripts/ops.py vllm stop --host "${OPS_DEFAULT_HOST:-lium}"

# Submit and monitor a run
python3 infra_scripts/ops.py runs submit --host "${OPS_DEFAULT_HOST:-lium}" --config configs/pilots.json
python3 infra_scripts/ops.py runs status --host "${OPS_DEFAULT_HOST:-lium}" --run-id <run_id>

# Archive, fetch, and report
python3 infra_scripts/ops.py artifacts archive --host "${OPS_DEFAULT_HOST:-lium}" --run-id <run_id>
python3 infra_scripts/ops.py artifacts fetch --host "${OPS_DEFAULT_HOST:-lium}" --run-id <run_id>
python3 infra_scripts/ops.py report --root artifacts/pod_logs
```

## Run Artifact Contract

A completed run MUST produce a directory containing the following files:

| File | Description |
|---|---|
| `command.sh` | The exact shell command executed. |
| `run_metadata.json` | Structured metadata (commit, model, env, decoding, dataset overrides). |
| `summary.json` | Final JSON summary payload (avg reward, counts, etc.). |
| `stdout.log` | Full captured stdout/stderr from the execution. |
| `results.jsonl` | (Optional) Per-example results and rollouts. |

**Paths:**
- Remote: `${OPS_REMOTE_OUTPUTS_DIR:-/mnt/pod_artifacts/outputs}/<run_id>/`
- Local: `artifacts/pod_logs/<run_id>/`

**Training runs (nanoGPT)**
- `examples/nanogpt/train.py` writes `command.sh`, `run_metadata.json`, `config_effective.json`, `dataset_manifest.json`, and `summary.json` into `out_dir` (master process).
- To satisfy this contract end-to-end, set `out_dir=${OPS_REMOTE_OUTPUTS_DIR:-/mnt/pod_artifacts/outputs}/<run_id>` and capture console output to `stdout.log` (the pod runner scripts in `infra_scripts/` do this by default).

## Project Env Loading (Recommended)

Infra shell scripts support a shared env file so docs and commands do not hardcode paths.

- Recommended: place a customized env file at `/mnt/project.env` (persistent across pods).
  - Start from `infra_scripts/project.env.example` (no secrets).
- Infra scripts will auto-source `infra_scripts/load_project_env.sh` when present.
- Loading precedence (lowest -> highest):
  - `/mnt/project.env`
  - `infra_scripts/project.env` (repo-local; gitignored)
  - `OPS_PROJECT_ENV` (explicit path)

Secrets note: keep API keys out of these env files. Use `wandb login` (writes `~/.netrc`) and service-specific auth.

## Sweeps (nanoGPT FineWeb10B)

The sweep runner executes a CSV manifest and writes each run to `${OPS_REMOTE_OUTPUTS_DIR}/<run_id>/`.

If you want the simplest possible flow, run:

```bash
# Inside the pod
cd /root/work/mHC-manifold-constrained-hyper-connections
bash infra_scripts/sweeps/one_click_fineweb10B_sweep.sh
```

This uses `infra_scripts/sweeps/fineweb10B_sweep_config.sh` (hardcoded defaults) and starts an 8-shard tmux session.

```bash
# Inside the repo on the pod
export OPS_REMOTE_OUTPUTS_DIR=/mnt/pod_artifacts/outputs
export DATA_DIR=/mnt/data/fineweb10B
export WANDB_GROUP=fineweb10B-sweep-$(date +%Y%m%d)

bash infra_scripts/sweeps/run_fineweb10B_sweep.sh \
  --csv infra_scripts/sweeps/fineweb10B_full_sweep.csv \
  --data-dir "$DATA_DIR" \
  --wandb-group "$WANDB_GROUP"
```

Useful flags:
- `--match <substr>`: run a subset (e.g. only `mhc-6l` rows)
- `--start-at <run_id>`: resume from a specific row
- `--limit <n>`: stop after N rows
- `--force`: rerun even if `<run_dir>/summary.json` exists
- `--dry-run`: print commands only
- `--no-wandb`: disable W&B logging
- `--device cuda|cpu|mps`: force device override

Status summary:
- `python3 infra_scripts/sweeps/sweep_status.py`

### Using all GPUs on an 8x node

By default, each `train.py` run uses a single GPU. For sweeps, the fastest way to use all GPUs is to run multiple independent sweep shards in parallel (one per GPU).

```bash
# Inside the pod
cd /root/work/mHC-manifold-constrained-hyper-connections

source infra_scripts/load_project_env.sh

tmux new -As sweeps

# Start 8 shards (one per GPU), each writing to the same OUT_ROOT.
# Each shard runs a disjoint subset of CSV rows.
bash infra_scripts/sweeps/start_fineweb10B_sweep_tmux.sh \
  --csv infra_scripts/sweeps/fineweb10B_full_sweep.csv \
  --workdir "${OPS_REMOTE_REPO:-/root/work/mHC-manifold-constrained-hyper-connections}" \
  --out-root "${OPS_REMOTE_OUTPUTS_DIR:-/mnt/pod_artifacts/outputs}" \
  --data-dir "${DATA_DIR:-/mnt/data/fineweb10B}" \
  --wandb-group "${WANDB_GROUP:-fineweb10B-sweep-$(date +%Y%m%d)}" \
  --shards 8 \
  --no-wandb
```

W&B conventions:
- `wandb_group` should identify the sweep (e.g. `fineweb10B-sweep-YYYYMMDD`).
- `wandb_run_name` is set to `run_id` so W&B runs match run directories exactly.

## Ops CLI Reference (`infra_scripts/ops.py`)

All commands support `--json` (compact), `--pretty` (indented), and `--dry-run`.

**Host management**
- Default host: `lium` (override via `--host` or `OPS_DEFAULT_HOST`).

**Pod & vLLM status**
- `pod status`: Check host reachability and `/mnt` mount.
- `vllm status`: Poll `/v1/models` for readiness.
  - `--api-base-url`: Override default (checks `VLLM_BASE_URL` or `OPENAI_API_BASE`).

**vLLM lifecycle**
- `vllm start`: Start vLLM in detached `tmux` (session `vllm`).
  - Required: `--model-id`
  - Common options: `--vllm-bin`, `--tensor-parallel-size`, `--gpu-memory-utilization`, `--max-model-len`, `--dtype`, `--quantization`, `--trust-remote-code`.
- `vllm stop`: Kill the `vllm` tmux session.

**Run management**
- `runs submit`: Submit runs to a remote `tmux` session (default: `pilots`).
  - Required: `--config <path>`
  - Repo: set `remote_repo` in config, `OPS_REMOTE_REPO`, or pass `--remote-repo`
  - Outputs root: set `remote_outputs_dir` in config, `OPS_REMOTE_OUTPUTS_DIR`, or pass `--remote-outputs-dir`
  - Flags: `--force`, `--no-tmux`
- `runs status`: Fetch `summary.json` and tail `stdout.log`.
  - Required: `--run-id`
  - Option: `--tail-lines <n>`
  - Outputs root: `OPS_REMOTE_OUTPUTS_DIR` or `--remote-outputs-dir`

**Artifacts & reporting**
- `artifacts archive`: Move raw `/mnt/eval_*` files into the run directory on the pod.
- `artifacts fetch`: Download the run directory to the local machine.
- `validate`: Check a local root for runs missing required artifact files.
- `report`: Aggregate `summary.json` files into a Markdown table and JSON summary.

## Pod Lifecycle & Setup

**Provisioning**
- Use `infra_scripts/lium-pod.sh` to manage pods. Standard volume for ops is `my_volume`.
- Use `infra_scripts/lium-pod.sh` to manage pods. Standard volume for ops is `${LIUM_DEFAULT_VOLUME:-my_volume}`.
```bash
# Recommended: pick an exact executor (includes GPU count + variant)
lium-pod.sh ls A100
# Example: 8x A100 with persistent volume (use the executor index/id from `lium-pod.sh ls`)
lium-pod.sh up --config 4 --name epiplexity-a100x8 --ttl 12h

# Alternative: let Lium auto-select by filters (may choose a different A100 variant)
lium-pod.sh up --gpu A100 --count 8 --name epiplexity-a100x8 --ttl 12h
```

**Bootstrapping**
```bash
# Inside the pod
bash /mnt/bootstrap-pod.sh

# Ensure W&B works in non-interactive sessions
# (should create/update ~/.netrc for api.wandb.ai)
bash /mnt/set-wandb-api-key.sh

# Alternative (interactive): creates ~/.netrc
# python -m wandb login
```

Notes:
- Exporting `WANDB_API_KEY` inside a script is NOT sufficient for later non-interactive sessions (e.g. `lium exec`, `tmux`, detached jobs).
- The durable mechanism is `~/.netrc` (what `wandb login` writes). Our pod scripts auto-detect `~/.netrc`.

If your `/mnt/set-wandb-api-key.sh` only does `export WANDB_API_KEY=...`, upgrade it once so it writes `~/.netrc`:
```bash
# From your local machine
lium exec <pod> --script infra_scripts/pod-upgrade-wandb-key.sh
```

**Repo sync**
Set the repo path explicitly (config `remote_repo`, `OPS_REMOTE_REPO`, or `--remote-repo`).
```bash
git fetch origin
git checkout <branch>
git pull
```

## Environment Variables

| Variable | Description | Default |
|---|---|---|
| `OPS_DEFAULT_HOST` | Default SSH host for commands. | `lium` |
| `OPS_REMOTE_REPO` | Repo path for `runs submit`. | - |
| `OPS_REMOTE_OUTPUTS_DIR` | Default remote output root for run directories. | `/mnt/pod_artifacts/outputs` |
| `LIUM_DEFAULT_VOLUME` | Default Lium volume name for `lium-pod.sh up`. | `my_volume` |
| `DATA_DIR` | Default FineWeb data directory (used by sweep runner). | `/mnt/data/fineweb10B` |
| `OPS_PROJECT_ENV` | Optional env file path sourced by infra scripts. | - |
| `VLLM_BASE_URL` | Base URL for vLLM status checks. | `http://127.0.0.1:8000/v1` |
| `OPENAI_API_BASE` | Fallback for vLLM status checks. | - |
| `OPENAI_API_KEY` | Required for some eval environments. | - |

## Safety Notes
- Always check `pod status` before submitting runs.
- Use `--dry-run` to verify generated SSH/tmux commands.
- The `artifacts/` directory is gitignored; `archive` and `fetch` before terminating a pod.
- Avoid manual `kill -9` on vLLM; use `vllm stop` or `tmux kill-session`.

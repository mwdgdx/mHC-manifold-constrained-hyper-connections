# Pod Fast-Path Workflow

Run compute from fast local disk (root) while keeping data and artifacts on `/mnt`.

## Conventions

- Repo (fast): `${OPS_REMOTE_REPO:-/root/work/mHC-manifold-constrained-hyper-connections}`
- Persistent volume: `${LIUM_DEFAULT_VOLUME:-my_volume}` mounted at `/mnt`
- Data (durable): `${DATA_DIR:-/mnt/data/fineweb10B}`
- Outputs (durable): `${OPS_REMOTE_OUTPUTS_DIR:-/mnt/pod_artifacts/outputs}`

Tip: copy and customize `infra_scripts/project.env.example` to `/mnt/project.env` so infra scripts pick up consistent defaults.

## Setup (one-time per pod)

```bash
# Bootstrapping (installs base tools, configures tokens/keys)
bash /mnt/bootstrap-pod.sh

# Optional: standardize env defaults for all infra scripts
cp -n /root/work/mHC-manifold-constrained-hyper-connections/infra_scripts/project.env.example /mnt/project.env || true
# edit /mnt/project.env as needed
# source /mnt/project.env

# Ensure W&B is configured for non-interactive sessions (writes ~/.netrc)
bash /mnt/set-wandb-api-key.sh

# If your /mnt/set-wandb-api-key.sh only exports WANDB_API_KEY, upgrade it once:
# (run from your local machine)
# lium exec <pod> --script infra_scripts/pod-upgrade-wandb-key.sh

# Repo lives on fast local disk (root filesystem)
mkdir -p /root/work
cd /root/work

# Ensure persisted SSH keys are active before cloning (preferred)
if [[ -d /mnt/.ssh ]]; then
  rm -rf ~/.ssh
  ln -s /mnt/.ssh ~/.ssh
elif [[ -d /mnt/ssh ]]; then
  rm -rf ~/.ssh
  ln -s /mnt/ssh ~/.ssh
fi

# Clone once per pod (repo is NOT on /mnt)
if [[ ! -d /root/work/mHC-manifold-constrained-hyper-connections/.git ]]; then
  git clone git@github.com:tokenbender/mHC-manifold-constrained-hyper-connections.git
fi

# Setup env + data symlinks (and checkout branch/PR)
source /root/work/mHC-manifold-constrained-hyper-connections/infra_scripts/pod-fastpath.sh --branch <branch> --download-fineweb

# or checkout a GitHub PR directly
source /root/work/mHC-manifold-constrained-hyper-connections/infra_scripts/pod-fastpath.sh --pr <number> --download-fineweb
```

Notes:
- Use `DOWNLOAD_FINEWEB=1` (or `--download-fineweb`) if shards are missing.
- `pod-fastpath.sh` will fail if data is missing and download is not enabled.

## SSH Keys (Persistent, Preferred)

We keep Git SSH keys on the persistent volume so pods do not need to generate new keys.

- Store keys on the mounted volume at `/mnt/.ssh` (preferred) or `/mnt/ssh`.
- `infra_scripts/pod-fastpath.sh` links `/mnt/.ssh` (or `/mnt/ssh`) into `~/.ssh` automatically.
- Disable this behavior only if necessary: `--no-ssh`.

Tip: If `/mnt/setup-github-ssh.sh` exists on the volume, you can run it to ensure `known_hosts` and `ssh-agent` are set up.

## Smoke Run

```bash
cd /root/work/mHC-manifold-constrained-hyper-connections
infra_scripts/pod-smoke-run.sh --run-id pr-smoke-$(date +%Y%m%d-%H%M%S)
```

Defaults:
- `max_iters=20`, `eval_interval=10`, `eval_iters=5`
- `wandb_log=auto` (enabled when W&B creds exist: `WANDB_API_KEY` or `~/.netrc`)
- Runs in `tmux` and writes to `${OPS_REMOTE_OUTPUTS_DIR:-/mnt/pod_artifacts/outputs}/<run-id>`

Log paths:
- Stdout: `${OPS_REMOTE_OUTPUTS_DIR:-/mnt/pod_artifacts/outputs}/<run-id>/stdout.log`
- Watch: `${OPS_REMOTE_OUTPUTS_DIR:-/mnt/pod_artifacts/outputs}/<run-id>/watch.log`

## Manual Sync

```bash
infra_scripts/pod-sync.sh --run-id <run-id>
```

## Ops (repo-agnostic)

```bash
export OPS_REMOTE_REPO=/root/work/mHC-manifold-constrained-hyper-connections
python infra_scripts/ops.py runs submit --host "${OPS_DEFAULT_HOST:-lium}" --config configs/pilots.json
```

`runs submit` now requires `remote_repo` (config, `OPS_REMOTE_REPO`, or `--remote-repo`).

## Sweeps

The sweep runner executes `infra_scripts/sweeps/fineweb10B_full_sweep.csv` and writes each run to `${OPS_REMOTE_OUTPUTS_DIR:-/mnt/pod_artifacts/outputs}/<run_id>/`.

```bash
cd /root/work/mHC-manifold-constrained-hyper-connections

# Optional: ensure env defaults are set once
cp -n infra_scripts/project.env.example /mnt/project.env || true

export WANDB_GROUP=fineweb10B-sweep-$(date +%Y%m%d)

bash infra_scripts/sweeps/run_fineweb10B_sweep.sh \
  --csv infra_scripts/sweeps/fineweb10B_full_sweep.csv \
  --wandb-group "$WANDB_GROUP"
```

Useful flags:
- `--match <substr>` for subsets
- `--start-at <run_id>` to resume
- `--limit <n>` for a short pilot
- `--dry-run` to print commands without running

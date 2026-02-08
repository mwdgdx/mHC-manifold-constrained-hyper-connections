# PROJECT KNOWLEDGE BASE

**Generated:** 2026-02-06 | **Commit:** 2da037c | **Branch:** main

## Overview

Research prototype for **mHC (Manifold-Constrained Hyper-Connections)** (arXiv:2512.24880) implemented in the style of `lucidrains/hyper-connections` (arXiv:2409.19606), plus a nanoGPT benchmark under `examples/nanogpt/`.

Core equation:
```
x_{l+1} = H_l^{res} x_l + H_l^{post,T} F(H_l^{pre} x_l, W_l)
```

Constraints (mHC mode):
- `H_res`: non-negative + doubly stochastic (Sinkhorn, or orthostochastic projection)
- `H_pre`, `H_post`: non-negative (softmax)

## Structure (Tracked)

```
.
├── hyper_connections/          # library implementation + variants
├── examples/nanogpt/           # benchmark (train loop + model + configs)
├── tests/                      # pytest suite
├── pyproject.toml              # deps + pytest config
├── README.md                   # usage + training commands
└── .gitignore                  # also ignores local-only research artifacts
```

## Where To Look

| Task | Location | Notes |
|------|----------|-------|
| Core HC/mHC layer | `hyper_connections/hyper_connections.py` | `HyperConnections` + `mhc=True` path |
| Numeric projections | `hyper_connections/hyper_connections.py` | `sinkhorn_log`, `orthostochastic_project` |
| Channel-first variant | `hyper_connections/hyper_connections_channel_first.py` | does not implement mHC yet |
| nanoGPT training | `examples/nanogpt/train.py` | DDP, wandb, config loader |
| nanoGPT model | `examples/nanogpt/model.py` | wires HC/mHC into blocks |
| Training configs | `examples/nanogpt/config/` | baseline / hc / vres / mhc + 48-layer variants |
| Sweep manifest | `infra_scripts/sweeps/fineweb10B_full_sweep.csv` | full FineWeb10B sweep grid + overrides |
| Sweep runner | `infra_scripts/sweeps/run_fineweb10B_sweep.sh` | executes CSV runs to `${OPS_REMOTE_OUTPUTS_DIR}/<run_id>` |
| Remote ops docs | `infra_scripts/remote-ops.md` | pod setup, run artifact contract, ops commands |
| Ops blueprint | `infra_scripts/research-ops-blueprint.md` | infra design memo + future ops roadmap |
| Tests | `tests/test_hyper_connections.py` | constraints, shapes, gradients |

## Code Map (Key Symbols)

| Symbol | Type | Location | Role |
|--------|------|----------|------|
| `HyperConnections` | class | `hyper_connections/hyper_connections.py` | HC/mHC residual stream mixing |
| `sinkhorn_log` | function | `hyper_connections/hyper_connections.py` | Birkhoff projection (doubly stochastic) |
| `orthostochastic_project` | function | `hyper_connections/hyper_connections.py` | optional H_res projection |
| `get_init_and_expand_reduce_stream_functions` | function | `hyper_connections/hyper_connections.py` | factory used by tests + nanoGPT |

## Conventions (Project-Specific)

- Match lucidrains style: `einops` ops (`rearrange`, `einsum`, `reduce`, `repeat`), helper funcs (`exists`, `default`, `divisible_by`).
- Keep typing lightweight; the code uses `from __future__ import annotations` / `typing` sparingly.
- mHC is static per-layer routing; treat `mhc=True` as a constrained mode (see Anti-Patterns).
- Local-only research artifacts: this repo may ignore folders like `docs/`, `reference-hc/`, `reference-valueres/` and local notes.

## Anti-Patterns (This Repo)

- mHC: no per-token dynamic routing; no negative values in `H_res`, `H_pre`, `H_post`.
- mHC: do not set `num_fracs > 1` or `num_input_views > 1`.
- Avoid adding new deps unless necessary; keep diffs close to upstream style.

## Commands

```bash
# editable install
pip install -e .

# tests
pytest -q

# nanoGPT runs (run from examples/nanogpt/)
python train.py config/train_fineweb10B.py
python train.py config/train_fineweb10B_hc.py
python train.py config/train_fineweb10B_mhc.py

# DDP
torchrun --standalone --nproc_per_node=4 train.py config/train_fineweb10B_mhc.py
```

## References

- mHC paper: https://arxiv.org/abs/2512.24880
- HC paper: https://arxiv.org/abs/2409.19606
- Upstream repo: https://github.com/lucidrains/hyper-connections

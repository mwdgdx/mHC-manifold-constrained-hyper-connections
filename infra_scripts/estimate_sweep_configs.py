#!/usr/bin/env python3
"""Estimate optimal sweep configs based on detected (or overridden) hardware.

Parses nanoGPT config files, estimates model parameter counts and memory
footprints, then recommends batch_size / gradient_accumulation_steps for
both BAT (sanity) and E2E (full workload) sweeps. Optionally writes CSVs.

Usage:
    # auto-detect GPUs
    python infra_scripts/estimate_sweep_configs.py

    # override hardware (e.g. running locally without GPUs)
    python infra_scripts/estimate_sweep_configs.py --num-gpus 8 --gpu-mem-gb 48

    # write sweep CSVs directly
    python infra_scripts/estimate_sweep_configs.py --num-gpus 8 --gpu-mem-gb 48 --write-csv

    # target specific config glob
    python infra_scripts/estimate_sweep_configs.py --config-glob 'train_fineweb10B*.py'
"""
from __future__ import annotations

import argparse
import csv
import fnmatch
import math
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Hardware detection
# ---------------------------------------------------------------------------

def detect_gpus() -> tuple[int, float, str]:
    """Return (num_gpus, vram_gb_per_gpu, gpu_name).

    Falls back to (0, 0.0, 'none') when CUDA is unavailable.
    """
    try:
        import torch
        if not torch.cuda.is_available():
            return 0, 0.0, "none"
        n = torch.cuda.device_count()
        props = torch.cuda.get_device_properties(0)
        vram_gb = props.total_mem / (1024 ** 3)
        name = props.name
        return n, vram_gb, name
    except Exception:
        return 0, 0.0, "none"


# ---------------------------------------------------------------------------
# Config parser — reads nanoGPT config .py files (flat assignment statements)
# ---------------------------------------------------------------------------

_ASSIGN_RE = re.compile(
    r"^([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(.+?)(?:\s*#.*)?$"
)

def parse_config(path: Path) -> dict:
    """Parse a nanoGPT config file into a dict of name -> Python value."""
    cfg: dict = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = _ASSIGN_RE.match(line)
            if not m:
                continue
            key, raw = m.group(1), m.group(2)
            try:
                val = eval(raw, {"__builtins__": {}}, {})  # safe-ish for literals
            except Exception:
                val = raw
            cfg[key] = val
    return cfg


# ---------------------------------------------------------------------------
# Model sizing
# ---------------------------------------------------------------------------

def estimate_params(cfg: dict) -> int:
    """Estimate total trainable parameters (GPT-2 style, bias=False)."""
    V = cfg.get("vocab_size", 50304)
    T = cfg.get("block_size", 1024)
    L = cfg.get("n_layer", 12)
    D = cfg.get("n_embd", 768)
    hc_streams = cfg.get("hc_num_streams", 1)
    hc_disabled = cfg.get("hc_disable", False)

    # embeddings
    emb = V * D + T * D

    # per-layer transformer params: attn(4*D^2) + MLP(8*D^2) + 2*layernorm(D)
    per_layer = 12 * D * D + 2 * D

    # HC overhead per layer (~2 small matrices of size streams*D or similar)
    hc_overhead = 0
    if not hc_disabled and hc_streams > 1:
        # H_pre, H_post: each ~ (streams, streams) applied per layer
        # H_res: (streams, streams) per layer
        # plus expand/reduce linear projections: streams*D <-> D
        hc_overhead = 3 * hc_streams * hc_streams + 2 * hc_streams * D

    # final layernorm
    final_ln = D

    total = emb + L * (per_layer + hc_overhead) + final_ln
    # lm_head is tied to wte — no extra params

    return total


def estimate_memory_gb(
    params: int,
    batch_size: int,
    block_size: int,
    n_layer: int,
    n_embd: int,
    hc_streams: int = 1,
    hc_disabled: bool = True,
) -> dict:
    """Estimate GPU memory components in GB.

    Returns dict with keys: weights, optimizer, gradients, activations, total.
    """
    B = batch_size
    T = block_size
    L = n_layer
    D = n_embd

    # static memory (per GPU, full replica — DDP)
    weights_gb = params * 4 / 1e9          # FP32 master
    optimizer_gb = params * 8 / 1e9        # AdamW momentum + variance (FP32)
    gradients_gb = params * 4 / 1e9        # FP32 gradients

    # activation memory (rough, BF16 with flash attention)
    # each layer stores: residual input, attn output, mlp output, layernorms
    # ~20 bytes per element with BF16 and flash attention
    act_multiplier = max(hc_streams, 1) if not hc_disabled else 1
    activations_gb = B * T * D * L * 20 * act_multiplier / 1e9

    total = weights_gb + optimizer_gb + gradients_gb + activations_gb

    return {
        "weights": weights_gb,
        "optimizer": optimizer_gb,
        "gradients": gradients_gb,
        "activations": activations_gb,
        "total": total,
    }


# ---------------------------------------------------------------------------
# Batch estimation
# ---------------------------------------------------------------------------

def estimate_max_batch(
    params: int,
    block_size: int,
    n_layer: int,
    n_embd: int,
    gpu_mem_gb: float,
    hc_streams: int = 1,
    hc_disabled: bool = True,
    headroom: float = 0.15,
) -> int:
    """Estimate max per-GPU batch_size that fits in VRAM."""
    static_gb = params * 16 / 1e9  # weights + optimizer + gradients
    available = gpu_mem_gb * (1 - headroom) - static_gb
    if available <= 0:
        return 1

    act_multiplier = max(hc_streams, 1) if not hc_disabled else 1
    per_sample = block_size * n_embd * n_layer * 20 * act_multiplier / 1e9

    if per_sample <= 0:
        return 1

    return max(1, int(available / per_sample))


def recommend_batch_config(
    max_batch: int,
    num_gpus: int,
    block_size: int,
    target_tokens_per_iter: int | None = None,
) -> dict:
    """Recommend batch_size and gradient_accumulation_steps.

    Strategy:
    - Use ~50% of max_batch for safety margin (torch.compile spikes, etc.)
    - Keep effective global batch in a sensible range
    - gradient_accumulation_steps must be divisible by num_gpus
    """
    safe_batch = max(1, int(max_batch * 0.5))

    # default target: ~500K tokens/iter (GPT-2 scale rule of thumb)
    if target_tokens_per_iter is None:
        target_tokens_per_iter = 524_288  # 512K

    # effective tokens = batch * grad_accum * num_gpus * block_size
    # solve for grad_accum
    needed_seqs = target_tokens_per_iter / block_size
    ideal_grad_accum = max(1, int(math.ceil(needed_seqs / (safe_batch * num_gpus))))

    # round up to be divisible by num_gpus (nanoGPT divides by world_size)
    raw_total = ideal_grad_accum * num_gpus
    if raw_total % num_gpus != 0:
        raw_total = ((raw_total // num_gpus) + 1) * num_gpus
    config_grad_accum = raw_total  # this is what goes in the config file

    actual_tokens = safe_batch * config_grad_accum * block_size
    # (train.py will divide config_grad_accum by world_size internally)

    return {
        "batch_size": safe_batch,
        "gradient_accumulation_steps": config_grad_accum,
        "tokens_per_iter": actual_tokens,
        "max_batch_per_gpu": max_batch,
        "utilization_pct": round(safe_batch / max_batch * 100, 1) if max_batch > 0 else 0,
    }


# ---------------------------------------------------------------------------
# Throughput estimation
# ---------------------------------------------------------------------------

def estimate_wall_time(
    params: int,
    max_iters: int,
    tokens_per_iter: int,
    num_gpus: int,
    gpu_tflops_bf16: float = 182.0,
    mfu: float = 0.40,
) -> dict:
    """Estimate wall-clock training time.

    Uses the approximation: flops_per_token ≈ 6 * params (forward + backward).
    """
    flops_per_token = 6 * params
    total_tokens = max_iters * tokens_per_iter
    total_flops = total_tokens * flops_per_token

    cluster_flops = num_gpus * gpu_tflops_bf16 * 1e12 * mfu  # effective FLOP/s
    if cluster_flops <= 0:
        return {"seconds": float("inf"), "hours": float("inf"), "tokens_per_sec": 0}

    seconds = total_flops / cluster_flops
    tokens_per_sec = total_tokens / seconds if seconds > 0 else 0

    return {
        "seconds": seconds,
        "hours": round(seconds / 3600, 2),
        "tokens_per_sec": int(tokens_per_sec),
    }


# ---------------------------------------------------------------------------
# Report + CSV generation
# ---------------------------------------------------------------------------

def fmt_params(n: int) -> str:
    if n >= 1e9:
        return f"{n / 1e9:.1f}B"
    if n >= 1e6:
        return f"{n / 1e6:.1f}M"
    if n >= 1e3:
        return f"{n / 1e3:.1f}K"
    return str(n)


def fmt_mem(gb: float) -> str:
    if gb < 1.0:
        return f"{gb * 1024:.0f} MB"
    return f"{gb:.2f} GB"


def short_name(config_path: str) -> str:
    """Derive a short run_id from config filename."""
    name = Path(config_path).stem
    name = name.replace("train_fineweb10B_", "").replace("train_fineweb10B", "base")
    name = name.replace("_", "-")
    if not name:
        name = "base"
    return name


def make_bat_row(config_relpath: str, seed: int = 0) -> dict:
    """BAT sweep row — short sanity run."""
    return {
        "run_id": f"bat-{short_name(config_relpath)}-s{seed}",
        "config": config_relpath,
        "seed": seed,
        "overrides": "max_iters=20 eval_interval=10 eval_iters=5",
        "notes": "bat",
    }


def make_e2e_row(
    config_relpath: str,
    rec: dict,
    seed: int = 0,
) -> dict:
    """E2E sweep row — full workload with hardware-tuned batch config."""
    overrides_parts = []
    overrides_parts.append(f"batch_size={rec['batch_size']}")
    overrides_parts.append(
        f"gradient_accumulation_steps={rec['gradient_accumulation_steps']}"
    )
    overrides = " ".join(overrides_parts)
    return {
        "run_id": f"e2e-{short_name(config_relpath)}-s{seed}",
        "config": config_relpath,
        "seed": seed,
        "overrides": overrides,
        "notes": "e2e",
    }


def write_sweep_csv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["run_id", "config", "seed", "overrides", "notes"])
        w.writeheader()
        for row in rows:
            w.writerow(row)
    print(f"  wrote {path} ({len(rows)} rows)")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Estimate optimal sweep configs based on hardware."
    )
    parser.add_argument(
        "--num-gpus", type=int, default=None,
        help="Override GPU count (auto-detected if omitted).",
    )
    parser.add_argument(
        "--gpu-mem-gb", type=float, default=None,
        help="Override per-GPU VRAM in GB (auto-detected if omitted).",
    )
    parser.add_argument(
        "--gpu-bf16-tflops", type=float, default=182.0,
        help="BF16 Tensor Core TFLOPS per GPU (default: 182 for RTX 6000 Ada).",
    )
    parser.add_argument(
        "--mfu", type=float, default=0.40,
        help="Assumed model FLOP utilization (default: 0.40).",
    )
    parser.add_argument(
        "--headroom", type=float, default=0.15,
        help="VRAM headroom fraction to reserve (default: 0.15).",
    )
    parser.add_argument(
        "--config-dir", type=str, default="examples/nanogpt/config",
        help="Path to config directory.",
    )
    parser.add_argument(
        "--config-glob", type=str, default="train_fineweb10B*.py",
        help="Glob pattern for config files (default: train_fineweb10B*.py).",
    )
    parser.add_argument(
        "--seeds", type=int, nargs="+", default=[0],
        help="Seeds for sweep rows (default: [0]).",
    )
    parser.add_argument(
        "--write-csv", action="store_true",
        help="Write sweeps/bat.csv and sweeps/e2e.csv.",
    )
    parser.add_argument(
        "--csv-dir", type=str, default="sweeps",
        help="Output directory for CSV files.",
    )
    args = parser.parse_args()

    # -- detect / override hardware --
    det_n, det_mem, det_name = detect_gpus()
    num_gpus = args.num_gpus if args.num_gpus is not None else det_n
    gpu_mem = args.gpu_mem_gb if args.gpu_mem_gb is not None else det_mem
    gpu_name = det_name

    if num_gpus == 0 or gpu_mem == 0:
        print("WARNING: No GPUs detected. Use --num-gpus and --gpu-mem-gb to override.")
        if num_gpus == 0:
            num_gpus = 8
        if gpu_mem == 0:
            gpu_mem = 48.0

    print("=" * 80)
    print("HARDWARE")
    print(f"  GPUs: {num_gpus}× {gpu_name}")
    print(f"  VRAM: {gpu_mem:.1f} GB/GPU ({gpu_mem * num_gpus:.0f} GB total)")
    print(f"  BF16 Tensor: {args.gpu_bf16_tflops} TFLOPS/GPU")
    print(f"  Headroom: {args.headroom * 100:.0f}%")
    print(f"  Assumed MFU: {args.mfu * 100:.0f}%")
    print()

    # -- discover configs --
    config_dir = Path(args.config_dir)
    if not config_dir.is_dir():
        print(f"ERROR: config dir not found: {config_dir}", file=sys.stderr)
        sys.exit(1)

    config_files = sorted(
        p for p in config_dir.iterdir()
        if p.is_file() and fnmatch.fnmatch(p.name, args.config_glob)
    )

    if not config_files:
        print(f"ERROR: no configs matching '{args.config_glob}' in {config_dir}", file=sys.stderr)
        sys.exit(1)

    # -- analyze each config --
    print("=" * 80)
    hdr = f"{'Config':<40} {'Params':>8} {'Layers':>6} {'D':>5} {'BS':>4} {'GA':>4} {'MaxBS':>6} {'RecBS':>6} {'RecGA':>6} {'Tok/iter':>10} {'E2E hrs':>8}"
    print(hdr)
    print("-" * len(hdr))

    bat_rows: list[dict] = []
    e2e_rows: list[dict] = []

    for cf in config_files:
        cfg = parse_config(cf)
        config_relpath = f"config/{cf.name}"

        n_layer = cfg.get("n_layer", 12)
        n_embd = cfg.get("n_embd", 768)
        block_size = cfg.get("block_size", 1024)
        cur_batch = cfg.get("batch_size", 32)
        cur_grad_accum = cfg.get("gradient_accumulation_steps", 4)
        max_iters = cfg.get("max_iters", 5000)
        hc_streams = cfg.get("hc_num_streams", 1)
        hc_disabled = cfg.get("hc_disable", False)

        params = estimate_params(cfg)
        max_bs = estimate_max_batch(
            params, block_size, n_layer, n_embd, gpu_mem,
            hc_streams, hc_disabled, args.headroom,
        )
        rec = recommend_batch_config(
            max_bs, num_gpus, block_size,
        )

        wall = estimate_wall_time(
            params, max_iters, rec["tokens_per_iter"],
            num_gpus, args.gpu_bf16_tflops, args.mfu,
        )

        label = cf.name.replace("train_fineweb10B_", "").replace("train_fineweb10B", "base").replace(".py", "")
        if not label:
            label = "base"

        print(
            f"{label:<40} {fmt_params(params):>8} {n_layer:>6} {n_embd:>5}"
            f" {cur_batch:>4} {cur_grad_accum:>4}"
            f" {max_bs:>6} {rec['batch_size']:>6} {rec['gradient_accumulation_steps']:>6}"
            f" {rec['tokens_per_iter']:>10,} {wall['hours']:>8}"
        )

        for seed in args.seeds:
            bat_rows.append(make_bat_row(config_relpath, seed))
            e2e_rows.append(make_e2e_row(config_relpath, rec, seed))

    print()

    # -- memory breakdown for first & last config (illustrative) --
    print("=" * 80)
    print("MEMORY BREAKDOWN (first config at recommended batch_size)")
    cf = config_files[0]
    cfg = parse_config(cf)
    params = estimate_params(cfg)
    rec = recommend_batch_config(
        estimate_max_batch(
            params, cfg.get("block_size", 1024),
            cfg.get("n_layer", 12), cfg.get("n_embd", 768),
            gpu_mem, cfg.get("hc_num_streams", 1),
            cfg.get("hc_disable", False), args.headroom,
        ),
        num_gpus, cfg.get("block_size", 1024),
    )
    mem = estimate_memory_gb(
        params, rec["batch_size"], cfg.get("block_size", 1024),
        cfg.get("n_layer", 12), cfg.get("n_embd", 768),
        cfg.get("hc_num_streams", 1), cfg.get("hc_disable", False),
    )
    print(f"  Config:       {cf.name}")
    print(f"  Params:       {fmt_params(params)}")
    print(f"  Batch size:   {rec['batch_size']}")
    print(f"  Weights:      {fmt_mem(mem['weights'])}")
    print(f"  Optimizer:    {fmt_mem(mem['optimizer'])}")
    print(f"  Gradients:    {fmt_mem(mem['gradients'])}")
    print(f"  Activations:  {fmt_mem(mem['activations'])}")
    print(f"  TOTAL:        {fmt_mem(mem['total'])} / {gpu_mem:.0f} GB ({mem['total']/gpu_mem*100:.0f}%)")
    print()

    # -- write CSVs --
    if args.write_csv:
        print("=" * 80)
        print("WRITING SWEEP CSVs")
        csv_dir = Path(args.csv_dir)
        write_sweep_csv(csv_dir / "bat.csv", bat_rows)
        write_sweep_csv(csv_dir / "e2e.csv", e2e_rows)
        print()

    # -- summary --
    print("=" * 80)
    print("LEGEND")
    print("  BS     = current config batch_size (per GPU)")
    print("  GA     = current config gradient_accumulation_steps (before DDP division)")
    print("  MaxBS  = estimated max batch_size per GPU (with headroom)")
    print("  RecBS  = recommended batch_size per GPU (~50% of max)")
    print("  RecGA  = recommended gradient_accumulation_steps (config value, DDP-aware)")
    print("  Tok/iter = tokens per training step at recommended settings")
    print("  E2E hrs  = estimated wall-clock hours for full training run")
    print()
    print("NOTES")
    print(f"  - Estimates assume {args.mfu*100:.0f}% MFU, {args.headroom*100:.0f}% VRAM headroom, BF16, flash attention")
    print("  - Activation memory is approximate; actual may vary with torch.compile")
    print("  - For BAT sweeps: overrides shorten to max_iters=20 (sanity check)")
    print("  - For E2E sweeps: overrides apply recommended batch_size + grad_accum")
    print("  - Run with --write-csv to generate sweeps/bat.csv and sweeps/e2e.csv")


if __name__ == "__main__":
    main()

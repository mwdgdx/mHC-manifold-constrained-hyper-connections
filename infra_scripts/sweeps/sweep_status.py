from __future__ import annotations

import csv
import json
import os
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Status:
    ok: list[str]
    failed: list[str]
    in_progress: list[str]
    missing_dir: list[str]
    parse_error: list[str]


def load_run_ids(csv_path: Path) -> list[str]:
    run_ids: list[str] = []
    with csv_path.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rid = (row.get("run_id") or "").strip().strip('"').strip("'")
            if rid:
                run_ids.append(rid)
    return run_ids


def compute_status(out_root: Path, run_ids: list[str]) -> Status:
    ok: list[str] = []
    failed: list[str] = []
    in_progress: list[str] = []
    missing_dir: list[str] = []
    parse_error: list[str] = []

    for rid in run_ids:
        run_dir = out_root / rid
        summary_path = run_dir / "summary.json"
        if not run_dir.is_dir():
            missing_dir.append(rid)
            continue
        if not summary_path.is_file():
            in_progress.append(rid)
            continue
        try:
            data = json.loads(summary_path.read_text())
        except Exception:
            parse_error.append(rid)
            continue
        if data.get("ok") is True:
            ok.append(rid)
        else:
            failed.append(rid)

    return Status(ok=ok, failed=failed, in_progress=in_progress, missing_dir=missing_dir, parse_error=parse_error)


def main() -> None:
    out_root = Path(os.environ.get("SWEEP_OUT_ROOT", os.environ.get("OPS_REMOTE_OUTPUTS_DIR", "/mnt/pod_artifacts/outputs")))
    csv_path = Path(os.environ.get("SWEEP_CSV", "infra_scripts/sweeps/fineweb10B_full_sweep.csv"))
    if not csv_path.is_file():
        # also accept the copied sweep manifest in out_root
        alt = out_root / "fineweb10B_full_sweep.csv"
        if alt.is_file():
            csv_path = alt

    if not csv_path.is_file():
        raise SystemExit(f"missing CSV: {csv_path}")

    run_ids = load_run_ids(csv_path)
    st = compute_status(out_root, run_ids)

    print(f"out_root={out_root}")
    print(f"csv={csv_path}")
    print(f"rows={len(run_ids)}")
    print(f"ok={len(st.ok)} failed={len(st.failed)} in_progress={len(st.in_progress)} missing_dir={len(st.missing_dir)} parse_error={len(st.parse_error)}")

    if st.failed:
        print("\nFAILED (first 10):")
        for rid in st.failed[:10]:
            print(rid)

    if st.in_progress:
        print("\nIN_PROGRESS (first 10):")
        for rid in st.in_progress[:10]:
            print(rid)


if __name__ == "__main__":
    main()

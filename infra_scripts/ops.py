#!/usr/bin/env python3
from __future__ import annotations

import argparse

# Standard durable ops volume is "my_volume" (mounted at /mnt on pods).
import json
import os
import shlex
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class CommandResult:
    stdout: str
    stderr: str
    returncode: int


def shell_join(command: list[str]) -> str:
    return shlex.join(command)


def run_command(command: list[str], *, dry_run: bool) -> CommandResult:
    if dry_run:
        return CommandResult(stdout=shell_join(command), stderr="", returncode=0)
    process = subprocess.run(command, capture_output=True, text=True, check=False)
    return CommandResult(
        stdout=process.stdout.strip(),
        stderr=process.stderr.strip(),
        returncode=process.returncode,
    )


def write_json(payload: dict[str, Any], *, pretty: bool) -> None:
    if pretty:
        print(json.dumps(payload, indent=2))
    else:
        print(json.dumps(payload))


def resolve_host(args: argparse.Namespace) -> str:
    return args.host or os.getenv("OPS_DEFAULT_HOST", "lium")


def default_remote_outputs_dir() -> str:
    return os.getenv("OPS_REMOTE_OUTPUTS_DIR", "/mnt/pod_artifacts/outputs")


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def normalize_base_url(raw_url: str) -> str:
    base_url = raw_url.rstrip("/")
    if not base_url.endswith("/v1"):
        base_url = f"{base_url}/v1"
    return base_url


def normalize_value(value: Any) -> str:
    if isinstance(value, (dict, list)):
        return json.dumps(value)
    return str(value)


def flag_for_key(key: str) -> str:
    return f"--{key.replace('_', '-')}"


def build_eval_command(config: dict[str, Any]) -> list[str]:
    args: list[str] = ["python", "inference/eval_gsm8k.py"]
    for key in sorted(config.keys()):
        if key in {"run_id", "label"}:
            continue
        value = config[key]
        if value is None:
            continue
        if isinstance(value, bool):
            if value:
                args.append(flag_for_key(key))
            continue
        args.extend([flag_for_key(key), normalize_value(value)])
    return args


def load_config(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def make_run_id(config: dict[str, Any]) -> str:
    env_id = str(config.get("env_id", "env"))
    model_id = str(config.get("model_id", "model"))
    num_examples = config.get("num_examples", 0)
    rollouts = config.get("rollouts_per_example", 0)
    best_of = config.get("best_of", 0) or 0
    seed = config.get("seed", 0)
    safe_env = "".join(ch if ch.isalnum() or ch in "._-" else "-" for ch in env_id)
    safe_model = "".join(ch if ch.isalnum() or ch in "._-" else "-" for ch in model_id)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    return f"{timestamp}_{safe_env}_{safe_model}_n{num_examples}_r{rollouts}_b{best_of}_seed{seed}"


def artifacts_archive(args: argparse.Namespace) -> int:
    host = resolve_host(args)
    run_id = args.run_id
    remote_outputs = args.remote_outputs_dir or default_remote_outputs_dir()
    remote_dir = f"{remote_outputs.rstrip('/')}/{run_id}"
    command = [
        "ssh",
        host,
        f"mkdir -p {remote_dir} && cp /mnt/eval_* {remote_dir}/",
    ]
    result = run_command(command, dry_run=args.dry_run)
    if result.returncode != 0:
        payload = {
            "ok": False,
            "host": host,
            "error": result.stderr or result.stdout,
        }
        write_json(payload, pretty=args.pretty)
        return result.returncode

    payload = {
        "ok": True,
        "host": host,
        "remote_dir": remote_dir,
        "command": result.stdout if args.dry_run else None,
    }
    write_json(payload, pretty=args.pretty)
    return 0


def artifacts_fetch(args: argparse.Namespace) -> int:
    host = resolve_host(args)
    run_id = args.run_id
    local_root = Path(args.local_root)
    local_dir = local_root / run_id
    ensure_dir(local_dir)

    remote_outputs = args.remote_outputs_dir or default_remote_outputs_dir()
    remote_dir = f"{remote_outputs.rstrip('/')}/{run_id}/"
    command = [
        "scp",
        "-r",
        f"{host}:{remote_dir}",
        str(local_dir),
    ]
    result = run_command(command, dry_run=args.dry_run)
    if result.returncode != 0:
        payload = {
            "ok": False,
            "host": host,
            "error": result.stderr or result.stdout,
        }
        write_json(payload, pretty=args.pretty)
        return result.returncode

    payload = {
        "ok": True,
        "host": host,
        "local_dir": str(local_dir),
        "remote_dir": remote_dir,
        "command": result.stdout if args.dry_run else None,
    }
    write_json(payload, pretty=args.pretty)
    return 0


def pod_status(args: argparse.Namespace) -> int:
    host = resolve_host(args)
    lium_result = run_command(["lium", "ps"], dry_run=args.dry_run)
    mnt_result = run_command(["ssh", host, "ls /mnt"], dry_run=args.dry_run)

    payload = {
        "ok": lium_result.returncode == 0 and mnt_result.returncode == 0,
        "host": host,
        "lium_ps": None if args.dry_run else lium_result.stdout,
        "mnt_ok": mnt_result.returncode == 0,
        "mnt_error": None
        if mnt_result.returncode == 0
        else (mnt_result.stderr or mnt_result.stdout),
        "commands": [lium_result.stdout, mnt_result.stdout] if args.dry_run else None,
    }
    write_json(payload, pretty=args.pretty)
    return 0 if payload["ok"] else 1


def vllm_status(args: argparse.Namespace) -> int:
    host = resolve_host(args)
    base_url = normalize_base_url(args.api_base_url)
    status_cmd = [
        "ssh",
        host,
        f"curl -sS -o /dev/null -w '%{{http_code}}' {base_url}/models",
    ]
    result = run_command(status_cmd, dry_run=args.dry_run)
    status_code = None
    if not args.dry_run and result.returncode == 0:
        try:
            status_code = int(result.stdout.strip())
        except ValueError:
            status_code = None
    ok = status_code is not None and 200 <= status_code < 500
    payload = {
        "ok": ok if not args.dry_run else True,
        "host": host,
        "base_url": base_url,
        "status_code": status_code,
        "command": result.stdout if args.dry_run else None,
        "error": None
        if ok
        else (result.stderr or result.stdout if not args.dry_run else None),
    }
    write_json(payload, pretty=args.pretty)
    return 0 if payload["ok"] else 1


def vllm_start(args: argparse.Namespace) -> int:
    host = resolve_host(args)
    cmd: list[str] = [args.vllm_bin]
    if args.vllm_bin.endswith("python"):
        cmd.extend(["-m", "vllm.entrypoints.openai.api_server"])
    else:
        cmd.append("serve")
    cmd.append(args.model_id)
    cmd.extend(
        [
            "--host",
            args.vllm_host,
            "--port",
            str(args.port),
            "--tensor-parallel-size",
            str(args.tensor_parallel_size),
        ]
    )
    if args.pipeline_parallel_size and args.pipeline_parallel_size > 1:
        cmd.extend(["--pipeline-parallel-size", str(args.pipeline_parallel_size)])
    if args.gpu_memory_utilization is not None:
        cmd.extend(["--gpu-memory-utilization", str(args.gpu_memory_utilization)])
    if args.max_model_len:
        cmd.extend(["--max-model-len", str(args.max_model_len)])
    if args.dtype:
        cmd.extend(["--dtype", args.dtype])
    if args.quantization:
        cmd.extend(["--quantization", args.quantization])
    if args.trust_remote_code:
        cmd.append("--trust-remote-code")

    session = args.session
    vllm_cmd = shell_join(cmd)
    remote_cmd = (
        f"tmux has-session -t {shlex.quote(session)} 2>/dev/null || "
        f"tmux new-session -d -s {shlex.quote(session)} {shlex.quote(vllm_cmd)}"
    )
    result = run_command(["ssh", host, remote_cmd], dry_run=args.dry_run)

    payload = {
        "ok": result.returncode == 0,
        "host": host,
        "session": session,
        "command": result.stdout if args.dry_run else None,
        "error": None if result.returncode == 0 else (result.stderr or result.stdout),
    }
    write_json(payload, pretty=args.pretty)
    return 0 if payload["ok"] else 1


def vllm_stop(args: argparse.Namespace) -> int:
    host = resolve_host(args)
    session = args.session
    remote_cmd = f"tmux kill-session -t {shlex.quote(session)}"
    result = run_command(["ssh", host, remote_cmd], dry_run=args.dry_run)
    payload = {
        "ok": result.returncode == 0,
        "host": host,
        "session": session,
        "command": result.stdout if args.dry_run else None,
        "error": None if result.returncode == 0 else (result.stderr or result.stdout),
    }
    write_json(payload, pretty=args.pretty)
    return 0 if payload["ok"] else 1


def runs_submit(args: argparse.Namespace) -> int:
    host = resolve_host(args)
    config = load_config(Path(args.config))
    defaults = config.get("defaults", {})
    runs = config.get("runs", [])
    remote_repo = config.get("remote_repo") or args.remote_repo or os.getenv("OPS_REMOTE_REPO")
    remote_outputs = (
        config.get("remote_outputs_dir")
        or args.remote_outputs_dir
        or default_remote_outputs_dir()
    )
    tmux_session = config.get("tmux_session", "pilots") if not args.no_tmux else None

    queued: list[str] = []
    skipped: list[str] = []
    commands: list[str] = []

    if not isinstance(runs, list):
        write_json({"ok": False, "error": "runs must be a list"}, pretty=args.pretty)
        return 2

    if not remote_repo:
        write_json(
            {
                "ok": False,
                "error": "remote_repo not set. Provide in config, --remote-repo, or OPS_REMOTE_REPO.",
            },
            pretty=args.pretty,
        )
        return 2

    for run in runs:
        if not isinstance(run, dict):
            continue
        merged = {**defaults, **run}
        run_id = merged.get("run_id") or make_run_id(merged)
        run_dir = merged.get("run_dir") or f"{remote_outputs.rstrip('/')}/{run_id}"
        merged["run_dir"] = run_dir
        cmd = build_eval_command(merged)
        cmd_str = shell_join(cmd)
        stdout_log = f"{run_dir.rstrip('/')}/stdout.log"
        base_cmd = (
            f"mkdir -p {shlex.quote(run_dir)} && cd {shlex.quote(remote_repo)} && "
            f"{cmd_str} | tee {shlex.quote(stdout_log)}"
        )

        if not args.force and not args.dry_run:
            check = run_command(
                ["ssh", host, f"test -f {shlex.quote(run_dir)}/summary.json"],
                dry_run=False,
            )
            if check.returncode == 0:
                skipped.append(str(run_id))
                continue

        if tmux_session:
            remote_cmd = (
                f"tmux has-session -t {shlex.quote(tmux_session)} 2>/dev/null || "
                f"tmux new-session -d -s {shlex.quote(tmux_session)}; "
                f"tmux send-keys -t {shlex.quote(tmux_session)} {shlex.quote(base_cmd)} C-m"
            )
        else:
            remote_cmd = base_cmd
        result = run_command(["ssh", host, remote_cmd], dry_run=args.dry_run)
        commands.append(result.stdout if args.dry_run else remote_cmd)
        if result.returncode != 0:
            write_json(
                {
                    "ok": False,
                    "host": host,
                    "error": result.stderr or result.stdout,
                },
                pretty=args.pretty,
            )
            return result.returncode
        queued.append(str(run_id))

    payload = {
        "ok": True,
        "host": host,
        "queued": queued,
        "skipped": skipped,
        "commands": commands if args.dry_run else None,
        "tmux_session": tmux_session,
    }
    write_json(payload, pretty=args.pretty)
    return 0


def runs_status(args: argparse.Namespace) -> int:
    host = resolve_host(args)
    run_id = args.run_id
    remote_outputs = args.remote_outputs_dir or default_remote_outputs_dir()
    run_dir = f"{remote_outputs.rstrip('/')}/{run_id}"
    summary_cmd = ["ssh", host, f"cat {shlex.quote(run_dir)}/summary.json"]
    stdout_cmd = [
        "ssh",
        host,
        f"tail -n {int(args.tail_lines)} {shlex.quote(run_dir)}/stdout.log",
    ]

    summary_result = run_command(summary_cmd, dry_run=args.dry_run)
    stdout_result = run_command(stdout_cmd, dry_run=args.dry_run)

    summary_payload = None
    if not args.dry_run and summary_result.returncode == 0:
        try:
            summary_payload = json.loads(summary_result.stdout)
        except json.JSONDecodeError:
            summary_payload = None

    payload = {
        "ok": summary_result.returncode == 0,
        "host": host,
        "run_id": run_id,
        "summary": summary_payload,
        "stdout_tail": None if args.dry_run else stdout_result.stdout,
        "commands": [summary_result.stdout, stdout_result.stdout]
        if args.dry_run
        else None,
        "error": None
        if summary_result.returncode == 0
        else (summary_result.stderr or summary_result.stdout),
    }
    write_json(payload, pretty=args.pretty)
    return 0 if payload["ok"] else 1


def validate_runs(args: argparse.Namespace) -> int:
    root = Path(args.root)
    required = ["command.sh", "run_metadata.json", "summary.json", "stdout.log"]
    missing: dict[str, list[str]] = {}
    complete: list[str] = []

    if not root.exists():
        write_json(
            {"ok": False, "error": f"Root not found: {root}"}, pretty=args.pretty
        )
        return 2

    for entry in sorted(root.iterdir()):
        if not entry.is_dir():
            continue
        missing_files = [name for name in required if not (entry / name).exists()]
        if missing_files:
            missing[entry.name] = missing_files
        else:
            complete.append(entry.name)

    payload = {
        "ok": True,
        "root": str(root),
        "complete": complete,
        "missing": missing,
    }
    write_json(payload, pretty=args.pretty)
    return 0


def report_runs(args: argparse.Namespace) -> int:
    root = Path(args.root)
    rows: list[dict[str, Any]] = []

    if not root.exists():
        write_json(
            {"ok": False, "error": f"Root not found: {root}"}, pretty=args.pretty
        )
        return 2

    for entry in sorted(root.iterdir()):
        if not entry.is_dir():
            continue
        summary_path = entry / "summary.json"
        if not summary_path.exists():
            continue
        try:
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        run_meta = summary.get("run_metadata")
        if not isinstance(run_meta, dict):
            run_meta = {}
        rows.append(
            {
                "run_id": entry.name,
                "env_id": run_meta.get("env_id"),
                "model_id": run_meta.get("model_id"),
                "num_examples": run_meta.get("num_examples"),
                "rollouts": run_meta.get("rollouts_per_example"),
                "best_of": run_meta.get("best_of"),
                "avg_reward": summary.get("avg_reward"),
                "macro_avg_reward": summary.get("macro_avg_reward"),
            }
        )

    header = [
        "run_id",
        "env_id",
        "model_id",
        "num_examples",
        "rollouts",
        "best_of",
        "avg_reward",
        "macro_avg_reward",
    ]
    lines = [
        "| " + " | ".join(header) + " |",
        "| " + " | ".join(["---"] * len(header)) + " |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(str(row.get(key, "")) for key in header) + " |")
    markdown = "\n".join(lines)

    payload = {
        "ok": True,
        "root": str(root),
        "count": len(rows),
        "rows": rows,
        "markdown": markdown,
    }
    write_json(payload, pretty=args.pretty)
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Ops helper CLI")
    parser.add_argument(
        "--json",
        dest="pretty",
        action="store_false",
        help="Emit compact JSON output",
    )
    parser.add_argument(
        "--pretty",
        dest="pretty",
        action="store_true",
        help="Emit pretty JSON output",
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.set_defaults(pretty=True)

    args, remaining = parser.parse_known_args(argv)
    if not remaining:
        parser.print_help()
        return 2

    command = remaining[0]
    subargs = remaining[1:]

    def apply_globals(target: argparse.Namespace) -> argparse.Namespace:
        target.pretty = args.pretty
        target.dry_run = args.dry_run
        return target

    if command == "artifacts":
        if not subargs:
            print("Usage: ops artifacts <archive|fetch> [options]")
            return 2
        subcommand = subargs[0]
        if subcommand == "archive":
            sub_parser = argparse.ArgumentParser(prog="ops artifacts archive")
            sub_parser.add_argument("--host")
            sub_parser.add_argument("--run-id", required=True)
            sub_parser.add_argument("--remote-outputs-dir")
            return artifacts_archive(apply_globals(sub_parser.parse_args(subargs[1:])))
        if subcommand == "fetch":
            sub_parser = argparse.ArgumentParser(prog="ops artifacts fetch")
            sub_parser.add_argument("--host")
            sub_parser.add_argument("--run-id", required=True)
            sub_parser.add_argument("--remote-outputs-dir")
            sub_parser.add_argument("--local-root", default="artifacts/pod_logs")
            return artifacts_fetch(apply_globals(sub_parser.parse_args(subargs[1:])))
        print("Usage: ops artifacts <archive|fetch> [options]")
        return 2

    if command == "pod":
        if not subargs or subargs[0] != "status":
            print("Usage: ops pod status [--host HOST]")
            return 2
        sub_parser = argparse.ArgumentParser(prog="ops pod status")
        sub_parser.add_argument("--host")
        return pod_status(apply_globals(sub_parser.parse_args(subargs[1:])))

    if command == "vllm":
        if not subargs:
            print("Usage: ops vllm <status|start|stop> [options]")
            return 2
        subcommand = subargs[0]
        if subcommand == "status":
            sub_parser = argparse.ArgumentParser(prog="ops vllm status")
            sub_parser.add_argument("--host")
            sub_parser.add_argument(
                "--api-base-url",
                default=os.getenv("VLLM_BASE_URL")
                or os.getenv("OPENAI_API_BASE")
                or "http://127.0.0.1:8000/v1",
            )
            return vllm_status(apply_globals(sub_parser.parse_args(subargs[1:])))
        if subcommand == "start":
            sub_parser = argparse.ArgumentParser(prog="ops vllm start")
            sub_parser.add_argument("--host")
            sub_parser.add_argument("--model-id", required=True)
            sub_parser.add_argument("--vllm-bin", default="vllm")
            sub_parser.add_argument("--vllm-host", default="127.0.0.1")
            sub_parser.add_argument("--port", type=int, default=8000)
            sub_parser.add_argument("--tensor-parallel-size", type=int, default=1)
            sub_parser.add_argument("--pipeline-parallel-size", type=int, default=1)
            sub_parser.add_argument("--gpu-memory-utilization", type=float)
            sub_parser.add_argument("--max-model-len", type=int)
            sub_parser.add_argument("--dtype", default="auto")
            sub_parser.add_argument("--quantization")
            sub_parser.add_argument("--trust-remote-code", action="store_true")
            sub_parser.add_argument("--session", default="vllm")
            return vllm_start(apply_globals(sub_parser.parse_args(subargs[1:])))
        if subcommand == "stop":
            sub_parser = argparse.ArgumentParser(prog="ops vllm stop")
            sub_parser.add_argument("--host")
            sub_parser.add_argument("--session", default="vllm")
            return vllm_stop(apply_globals(sub_parser.parse_args(subargs[1:])))
        print("Usage: ops vllm <status|start|stop> [options]")
        return 2

    if command == "runs":
        if not subargs:
            print("Usage: ops runs <submit|status> [options]")
            return 2
        subcommand = subargs[0]
        if subcommand == "submit":
            sub_parser = argparse.ArgumentParser(prog="ops runs submit")
            sub_parser.add_argument("--host")
            sub_parser.add_argument("--config", required=True)
            sub_parser.add_argument("--remote-repo")
            sub_parser.add_argument("--remote-outputs-dir")
            sub_parser.add_argument("--force", action="store_true")
            sub_parser.add_argument("--no-tmux", action="store_true")
            return runs_submit(apply_globals(sub_parser.parse_args(subargs[1:])))
        if subcommand == "status":
            sub_parser = argparse.ArgumentParser(prog="ops runs status")
            sub_parser.add_argument("--host")
            sub_parser.add_argument("--run-id", required=True)
            sub_parser.add_argument("--remote-outputs-dir")
            sub_parser.add_argument("--tail-lines", type=int, default=60)
            return runs_status(apply_globals(sub_parser.parse_args(subargs[1:])))
        print("Usage: ops runs <submit|status> [options]")
        return 2

    if command == "validate":
        sub_parser = argparse.ArgumentParser(prog="ops validate")
        sub_parser.add_argument("--root", default="artifacts/pod_logs")
        return validate_runs(apply_globals(sub_parser.parse_args(subargs)))

    if command == "report":
        sub_parser = argparse.ArgumentParser(prog="ops report")
        sub_parser.add_argument("--root", default="artifacts/pod_logs")
        return report_runs(apply_globals(sub_parser.parse_args(subargs)))

    parser.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

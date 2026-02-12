#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path


PHASE_CONTRACTS: dict[str, dict[str, object]] = {
    "P00": {
        "intent": "Precheck constitutional prerequisites before any remote mutation.",
        "laws": ["LAW_1_CANONICAL_CONFIG", "LAW_2_SINGLE_CANONICAL_LIFECYCLE", "LAW_4_NONINTERACTIVE_SAFETY", "LAW_6_PROVENANCE", "LAW_9_PHASE_END_CONSTITUTIONAL_VALIDATION"],
        "commands": ["flow-precheck"],
    },
    "P10": {
        "intent": "Provision pod deterministically or explicitly mark policy skip.",
        "laws": ["LAW_3_TARGET_RESOLUTION", "LAW_4_NONINTERACTIVE_SAFETY", "LAW_5_PHASE_CONTRACT", "LAW_6_PROVENANCE", "LAW_9_PHASE_END_CONSTITUTIONAL_VALIDATION"],
        "commands": ["pod-up", "provision-policy"],
    },
    "P20": {
        "intent": "Resolve and lock a legal execution target for remaining phases.",
        "laws": ["LAW_3_TARGET_RESOLUTION", "LAW_5_PHASE_CONTRACT", "LAW_6_PROVENANCE", "LAW_9_PHASE_END_CONSTITUTIONAL_VALIDATION"],
        "commands": ["target-bind"],
    },
    "P30": {
        "intent": "Prove remote target is reachable and pod is ready.",
        "laws": ["LAW_5_PHASE_CONTRACT", "LAW_6_PROVENANCE", "LAW_9_PHASE_END_CONSTITUTIONAL_VALIDATION"],
        "commands": ["pod-status"],
    },
    "P40": {
        "intent": "Satisfy bootstrap prerequisites and helper initialization policy.",
        "laws": ["LAW_5_PHASE_CONTRACT", "LAW_6_PROVENANCE", "LAW_9_PHASE_END_CONSTITUTIONAL_VALIDATION"],
        "commands": ["bootstrap"],
    },
    "P50": {
        "intent": "Checkout repository and validate torch/data contracts for training readiness.",
        "laws": ["LAW_5_PHASE_CONTRACT", "LAW_6_PROVENANCE", "LAW_8_DOC_SCRIPT_CONSISTENCY", "LAW_9_PHASE_END_CONSTITUTIONAL_VALIDATION"],
        "commands": ["checkout"],
    },
    "P60": {
        "intent": "Start, resume-check, or policy-skip sweep in a declared mode.",
        "laws": ["LAW_5_PHASE_CONTRACT", "LAW_6_PROVENANCE", "LAW_9_PHASE_END_CONSTITUTIONAL_VALIDATION"],
        "commands": ["sweep-start", "sweep-status", "sweep-policy"],
    },
    "P70": {
        "intent": "Monitor sweep completion state via wait or snapshot path.",
        "laws": ["LAW_5_PHASE_CONTRACT", "LAW_6_PROVENANCE", "LAW_9_PHASE_END_CONSTITUTIONAL_VALIDATION"],
        "commands": ["sweep-wait", "sweep-status"],
    },
    "P80": {
        "intent": "Fetch artifacts according to explicit fetch policy.",
        "laws": ["LAW_5_PHASE_CONTRACT", "LAW_6_PROVENANCE", "LAW_9_PHASE_END_CONSTITUTIONAL_VALIDATION"],
        "commands": ["fetch-policy", "fetch-all", "fetch-run"],
    },
    "P90": {
        "intent": "Apply explicit teardown policy without implicit destruction.",
        "laws": ["LAW_7_EXPLICIT_DESTRUCTION", "LAW_5_PHASE_CONTRACT", "LAW_6_PROVENANCE", "LAW_9_PHASE_END_CONSTITUTIONAL_VALIDATION"],
        "commands": ["teardown-policy", "pod-delete"],
    },
    "P99": {
        "intent": "Emit final constitutional summary only after all prior phases are known.",
        "laws": ["LAW_5_PHASE_CONTRACT", "LAW_6_PROVENANCE", "LAW_9_PHASE_END_CONSTITUTIONAL_VALIDATION"],
        "commands": ["flow-summary"],
    },
}


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def validate_evidence(evidence: dict, expected_phase: str) -> tuple[list[str], list[str]]:
    violations: list[str] = []
    laws: set[str] = set()

    phase_contract = PHASE_CONTRACTS.get(expected_phase)
    if phase_contract is None:
        violations.append("unknown_phase_contract")
        laws.add("LAW_5_PHASE_CONTRACT")
        return violations, sorted(laws)

    required_fields = [
        "flow_id",
        "phase_id",
        "active_config_path",
        "active_config_sha256",
        "command_name",
        "command_rc",
        "phase_status",
        "transport_hint",
        "intent_mode",
        "contract_intent",
        "applicable_laws",
        "flow_start_artifact",
    ]

    for field in required_fields:
        if field not in evidence:
            violations.append(f"missing_field:{field}")
            laws.add("LAW_6_PROVENANCE")

    phase_id = str(evidence.get("phase_id", ""))
    if expected_phase and phase_id != expected_phase:
        violations.append("phase_mismatch")
        laws.add("LAW_5_PHASE_CONTRACT")

    intent_mode = str(evidence.get("intent_mode", "")).strip()
    if intent_mode != "mandated_contract_or_die":
        violations.append("intent_mode_violation")
        laws.add("LAW_5_PHASE_CONTRACT")

    expected_intent = str(phase_contract["intent"])
    contract_intent = str(evidence.get("contract_intent", "")).strip()
    if contract_intent != expected_intent:
        violations.append("contract_intent_mismatch")
        laws.add("LAW_5_PHASE_CONTRACT")

    command_name = str(evidence.get("command_name", "")).strip()
    allowed_commands = {str(v) for v in phase_contract["commands"]}
    if command_name not in allowed_commands:
        violations.append("intent_command_mismatch")
        laws.add("LAW_5_PHASE_CONTRACT")

    applicable_laws = evidence.get("applicable_laws")
    if not isinstance(applicable_laws, list):
        violations.append("applicable_laws_not_list")
        laws.add("LAW_6_PROVENANCE")
        applicable_law_set: set[str] = set()
    else:
        applicable_law_set = {str(v).strip() for v in applicable_laws if str(v).strip()}
    expected_laws = {str(v) for v in phase_contract["laws"]}
    missing_laws = sorted(expected_laws - applicable_law_set)
    if missing_laws:
        violations.extend([f"missing_applicable_law:{law}" for law in missing_laws])
        laws.update(expected_laws)

    phase_status = str(evidence.get("phase_status", ""))
    if phase_status != "ok":
        violations.append("phase_status_not_ok")
        laws.add("LAW_5_PHASE_CONTRACT")

    try:
        command_rc = int(evidence.get("command_rc", 1))
    except Exception:
        command_rc = 1
    if command_rc != 0:
        violations.append("command_rc_non_zero")
        laws.add("LAW_5_PHASE_CONTRACT")

    config_sha = str(evidence.get("active_config_sha256", "")).strip()
    if not config_sha:
        violations.append("missing_config_sha256")
        laws.add("LAW_6_PROVENANCE")

    flow_start_raw = str(evidence.get("flow_start_artifact", "")).strip()
    flow_start_path = Path(flow_start_raw) if flow_start_raw else Path()
    flow_start_payload: dict = {}
    if not flow_start_raw:
        violations.append("missing_flow_start_artifact")
        laws.add("LAW_6_PROVENANCE")
    elif not flow_start_path.exists():
        violations.append("flow_start_missing")
        laws.add("LAW_6_PROVENANCE")
    else:
        try:
            flow_start_payload = json.loads(flow_start_path.read_text())
        except Exception:
            violations.append("flow_start_invalid_json")
            laws.add("LAW_6_PROVENANCE")

    if flow_start_payload:
        start_flow_id = str(flow_start_payload.get("flow_id", "")).strip()
        if start_flow_id and start_flow_id != str(evidence.get("flow_id", "")).strip():
            violations.append("flow_id_mismatch")
            laws.add("LAW_6_PROVENANCE")

        start_config_sha = str(flow_start_payload.get("active_config_sha256", "")).strip()
        if start_config_sha and config_sha and start_config_sha != config_sha:
            violations.append("config_sha_drift")
            laws.add("LAW_1_CANONICAL_CONFIG")

        if phase_id in {"P20", "P30", "P40", "P50", "P60", "P70", "P80", "P90", "P99"}:
            start_target = str(flow_start_payload.get("lium_target", "")).strip()
            current_target = str(evidence.get("lium_target", "")).strip()
            if start_target and current_target and start_target != current_target:
                violations.append("target_drift_from_flow_start")
                laws.add("LAW_3_TARGET_RESOLUTION")

            start_fallback = str(flow_start_payload.get("ops_default_host", "")).strip()
            current_fallback = str(evidence.get("ops_default_host", "")).strip()
            if start_fallback and current_fallback and start_fallback != current_fallback:
                violations.append("fallback_host_drift_from_flow_start")
                laws.add("LAW_3_TARGET_RESOLUTION")

    if phase_id == "P20":
        lium_target = str(evidence.get("lium_target", "")).strip()
        fallback_host = str(evidence.get("ops_default_host", "")).strip()
        if not lium_target and not fallback_host:
            violations.append("target_not_resolved")
            laws.add("LAW_3_TARGET_RESOLUTION")

    if phase_id in {"P50", "P60"}:
        repo_url = str(evidence.get("repo_url", "")).strip()
        if not repo_url:
            violations.append("repo_url_missing")
            laws.add("LAW_5_PHASE_CONTRACT")

    if phase_id == "P90":
        teardown_mode = str(evidence.get("teardown_mode", "")).strip()
        if teardown_mode not in {"keep", "delete"}:
            violations.append("invalid_teardown_mode")
            laws.add("LAW_7_EXPLICIT_DESTRUCTION")

    return violations, sorted(laws)


def main() -> int:
    parser = argparse.ArgumentParser(description="Constitutional phase auditor")
    parser.add_argument("--evidence", required=True, help="Path to phase evidence JSON")
    parser.add_argument("--output", required=True, help="Path to write constitutional verdict JSON")
    parser.add_argument("--phase", required=True, help="Expected phase id")
    args = parser.parse_args()

    evidence_path = Path(args.evidence)
    output_path = Path(args.output)

    payload: dict
    if not evidence_path.exists():
        payload = {
            "phase": args.phase,
            "status": "unverified",
            "pass": False,
            "violations": ["missing_evidence_file"],
            "violated_laws": ["LAW_6_PROVENANCE"],
            "checked_at": now_utc(),
            "engine": "workflow_phase_court.py",
            "remediation": "re-run the failed phase to regenerate evidence",
        }
        output_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        return 0

    try:
        evidence = json.loads(evidence_path.read_text())
    except Exception:
        payload = {
            "phase": args.phase,
            "status": "unverified",
            "pass": False,
            "violations": ["invalid_evidence_json"],
            "violated_laws": ["LAW_6_PROVENANCE"],
            "checked_at": now_utc(),
            "engine": "workflow_phase_court.py",
            "remediation": "fix evidence writer and re-run flow",
        }
        output_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        return 0

    violations, violated_laws = validate_evidence(evidence, args.phase)
    ok = len(violations) == 0

    payload = {
        "phase": args.phase,
        "status": "pass" if ok else "fail",
        "pass": ok,
        "violations": violations,
        "violated_laws": violated_laws,
        "checked_at": now_utc(),
        "engine": "workflow_phase_court.py",
        "evidence": str(evidence_path),
        "remediation": "inspect phase verdict artifacts and rerun flow" if not ok else "none",
    }
    output_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

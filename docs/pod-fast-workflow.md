# Pod Fast-Path Workflow (Legacy)

Canonical workflow (config-driven): `docs/remote-experiment-workflow.md`.

This repo now standardizes on:
- `infra_scripts/workflow.env` as the single place for platform/user/project-specific knobs.
- `infra_scripts/workflow.sh` as the single entrypoint for pod bootstrap, checkout, tmux sweeps, monitoring, and fetching artifacts.

Older multi-script pod notes and tooling (if any) live under `infra_scripts/` and are not guaranteed to be current.

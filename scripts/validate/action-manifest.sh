#!/usr/bin/env bash
# Validate that action.yml is a loadable composite-action manifest.
#
# Beyond the top-level required keys, this asserts EVERY composite step
# carries exactly one of `run` or `uses` (and `shell` whenever it has
# `run`). GitHub rejects a step with neither at job setup with
# "Required property is missing: run" — a failure a plain YAML syntax
# check does NOT catch, because the document still parses. That gap once
# let a dropped `run:` retag the floating major tag and break every
# consumer of the action; this check is the gate that makes it
# impossible to repeat.
#
# Usage: action-manifest.sh [path]   (defaults to ./action.yml)
set -euo pipefail

manifest="${1:-action.yml}"

python3 - "$manifest" <<'PY'
import sys
import yaml

path = sys.argv[1]
with open(path) as f:
    data = yaml.safe_load(f)

errors = []

for key in ("name", "description", "runs"):
    if key not in data:
        errors.append(f"missing required top-level key: {key}")

runs = data.get("runs", {}) or {}
using = runs.get("using")
if using != "composite":
    errors.append(f"expected runs.using=composite, got {using!r}")

steps = runs.get("steps", []) or []
for i, step in enumerate(steps):
    label = step.get("name", f"<unnamed step #{i}>")
    has_run = "run" in step
    has_uses = "uses" in step
    if not has_run and not has_uses:
        errors.append(f"step {label!r}: has neither `run` nor `uses`")
    if has_run and has_uses:
        errors.append(f"step {label!r}: has both `run` and `uses` (pick one)")
    if has_run and "shell" not in step:
        errors.append(f"step {label!r}: `run` step missing required `shell`")

if errors:
    print(f"{path}: INVALID composite-action manifest:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)

print(f"{path}: OK — {len(steps)} composite steps, all with run-or-uses (+ shell where run)")
PY

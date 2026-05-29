#!/usr/bin/env bash
# Emit a JSON matrix of { os, target, artifact } derived from anodizer's
# configured build targets, for consumers that fan out build jobs from
# `.anodizer.yaml`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/gha.sh"

if ! command -v anodizer > /dev/null 2>&1; then
    gha_set_output matrix ""
    exit 0
fi

if targets=$(anodizer targets --json 2>/dev/null); then
    gha_set_output matrix "$targets"
    gha_notice "split-matrix output populated from anodizer targets --json"
else
    gha_set_output matrix ""
fi

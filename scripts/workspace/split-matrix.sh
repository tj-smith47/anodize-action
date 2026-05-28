#!/usr/bin/env bash
# Emit a JSON matrix of { os, target, artifact } derived from anodizer's
# configured build targets, for consumers that fan out build jobs from
# `.anodizer.yaml`.
set -euo pipefail

if ! command -v anodizer > /dev/null 2>&1; then
    echo "matrix=" >> "$GITHUB_OUTPUT"
    exit 0
fi

if targets=$(anodizer targets --json 2>/dev/null); then
    echo "matrix=$targets" >> "$GITHUB_OUTPUT"
    echo "::notice::split-matrix output populated from anodizer targets --json"
else
    echo "matrix=" >> "$GITHUB_OUTPUT"
fi

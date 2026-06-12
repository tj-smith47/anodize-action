#!/usr/bin/env bash
# Emit a JSON matrix of { os, target, artifact } derived from anodizer's
# configured build targets, for consumers that fan out build jobs from
# `.anodizer.yaml`.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/gha.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"

command -v anodizer > /dev/null 2>&1 \
    || gha_fail "split-matrix: anodizer not found on PATH — the install step must run before the matrix can be derived"

# No config and no Cargo.toml fallback means there are no targets to derive
# — an `install-only: true` step in a config-less workdir is a legitimate
# "just install the binary" use, not a probe failure.
if ! find_anodizer_config > /dev/null && [ ! -f Cargo.toml ]; then
    gha_notice "split-matrix: no anodizer config (or Cargo.toml fallback) in the workdir; emitting an empty matrix"
    gha_set_output matrix ""
    exit 0
fi

# stderr flows to the CI log so a config error is debuggable; an empty
# matrix is emitted only when the tool legitimately reports no targets.
targets=$(anodizer targets --json) \
    || gha_fail "split-matrix: 'anodizer targets --json' failed — cannot derive the build matrix"
gha_set_output matrix "$targets"
gha_notice "split-matrix output populated from anodizer targets --json"

#!/usr/bin/env bash
# determinism-resolve-targets.sh — derive the per-shard target CSV for the
# determinism harness.
#
# Inputs (env):
#   RUNNER_OS   — Linux | macOS | Windows (set automatically by GitHub Actions)
#   OVERRIDE    — optional explicit target CSV; bypasses derivation when set
#   ANODIZE_BIN — optional `anodize` invocation (defaults to `anodize`). Tests
#                 stub this to feed a fixture JSON without spawning the real
#                 binary.
#
# Outputs:
#   `csv=<comma-joined-triples>` appended to $GITHUB_OUTPUT (when set).
#   The same CSV is also printed to stdout so callers without a
#   GITHUB_OUTPUT (e.g. tests) can capture it.
#
# Exits non-zero with a clear error when:
#   - RUNNER_OS is unsupported,
#   - the targets JSON is missing/empty for the runner,
#   - jq cannot parse the output.
#
# Filters `anodize targets --json` (which emits a GitHub-Actions matrix-style
# `{"include": [{"os": "ubuntu-latest", "target": "...", "artifact": "..."}]}`)
# by mapping RUNNER_OS to its runner label.

set -euo pipefail

: "${RUNNER_OS:?RUNNER_OS is required}"
OVERRIDE="${OVERRIDE:-}"
ANODIZE_BIN="${ANODIZE_BIN:-anodize}"

emit_csv() {
    local csv="$1"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        echo "csv=$csv" >> "$GITHUB_OUTPUT"
    fi
    printf '%s\n' "$csv"
}

if [ -n "$OVERRIDE" ]; then
    echo "::notice::Determinism targets (override): $OVERRIDE"
    emit_csv "$OVERRIDE"
    exit 0
fi

case "$RUNNER_OS" in
    Linux)   want=ubuntu-latest ;;
    macOS)   want=macos-latest ;;
    Windows) want=windows-latest ;;
    *)
        echo "::error::Unsupported RUNNER_OS for determinism: $RUNNER_OS"
        exit 1
        ;;
esac

# `anodize targets --json` emits `{"include": [{"os":..., "target":..., ...}]}`.
# Filter to entries whose `os` matches the runner label for this shard.
if ! json=$($ANODIZE_BIN targets --json 2>/dev/null); then
    echo "::error::\`$ANODIZE_BIN targets --json\` failed; is anodize installed and is .anodizer.yaml present?"
    exit 1
fi

csv=$(printf '%s' "$json" \
    | jq -r --arg w "$want" '
        # Accept both the matrix-style {"include": [...]} shape and a bare
        # array, for forward-compat with possible future schema simplification.
        (if type == "object" then .include else . end)
        | [.[] | select(.os == $w) | .target]
        | join(",")
    ')

if [ -z "$csv" ]; then
    echo "::error::No targets match RUNNER_OS=$RUNNER_OS (looked for os=$want in \`anodize targets --json\`)"
    exit 1
fi

echo "::notice::Determinism targets: $csv"
emit_csv "$csv"

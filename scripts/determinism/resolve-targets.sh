#!/usr/bin/env bash
# Derive the per-shard target CSV for the determinism harness by filtering
# `anodizer targets --json` (matrix-style `{"include": [...]}`) to entries
# whose `os` field matches RUNNER_OS's runner label.
#
# Inputs (env):
#   RUNNER_OS   — Linux | macOS | Windows (set by GitHub Actions)
#   OVERRIDE    — optional explicit target CSV; bypasses derivation when set
#   ANODIZE_BIN — optional `anodizer` invocation (defaults to `anodizer`).
#                 Tests stub this to feed fixture JSON.
#
# Outputs:
#   `csv=<comma-joined-triples>` appended to $GITHUB_OUTPUT (when set), and
#   the same CSV printed to stdout for callers without $GITHUB_OUTPUT.
#
# Exits non-zero on unsupported RUNNER_OS, missing/empty targets for the
# runner, or jq parse failure.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/gha.sh"

: "${RUNNER_OS:?RUNNER_OS is required}"
OVERRIDE="${OVERRIDE:-}"
ANODIZE_BIN="${ANODIZE_BIN:-anodizer}"

emit_csv() {
    local csv="$1"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        gha_set_output csv "$csv"
    else
        printf '%s\n' "$csv"
    fi
}

if [ -n "$OVERRIDE" ]; then
    anodizer::verb Resolving "determinism targets (override)"
    emit_csv "$OVERRIDE"
    exit 0
fi

anodizer::verb Resolving "determinism targets"

case "$RUNNER_OS" in
    Linux)   want=ubuntu-latest ;;
    macOS)   want=macos-latest ;;
    Windows) want=windows-latest ;;
    *)       gha_fail "Unsupported RUNNER_OS for determinism: $RUNNER_OS" ;;
esac

# `anodizer targets --json` emits `{"include": [{"os":..., "target":..., ...}]}`.
# Filter to entries whose `os` matches the runner label for this shard.
json=$($ANODIZE_BIN targets --json 2>/dev/null) \
    || gha_fail "\`$ANODIZE_BIN targets --json\` failed; is anodizer installed and is .anodizer.yaml present?"

csv=$(printf '%s' "$json" \
    | jq -r --arg w "$want" '
        # Accept both the matrix-style {"include": [...]} shape and a bare
        # array, for forward-compat with possible future schema simplification.
        (if type == "object" then .include else . end)
        | [.[] | select(.os == $w) | .target]
        | join(",")
    ')

[ -n "$csv" ] \
    || gha_fail "No targets match RUNNER_OS=$RUNNER_OS (looked for os=$want in \`anodizer targets --json\`)"

anodizer::kv targets "$csv" >&2
emit_csv "$csv"

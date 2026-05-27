#!/usr/bin/env bats
# crates-output.bats — tests for the `crates` step output.
#
# Covers the shell logic that parses `anodizer-output crates=...` lines from
# ANODIZER_STDOUT_LOG and emits the value to GITHUB_OUTPUT:
#
#   1. CLI emits the marker with a populated array → crates output matches.
#   2. CLI emits the marker with an empty array    → crates output is `[]`.
#   3. CLI emits no marker                         → crates output defaults to `[]`.
#   4. CLI emits the marker twice                  → last value wins.

load test_helper

# ---------------------------------------------------------------------------
# Helper: run the crates-parsing body from the "Collect outputs" step with a
# caller-supplied stdout log content.  Mirrors the production shell exactly.
# ---------------------------------------------------------------------------
_run_crates_parse() {
    local log_content="$1"
    local log_file="${_TEST_HOME}/anodizer-stdout.log"
    local github_output="${_TEST_HOME}/github-output"

    printf '%s\n' "$log_content" > "$log_file"
    : > "$github_output"

    ANODIZER_STDOUT_LOG="$log_file" GITHUB_OUTPUT="$github_output" \
        bash <<'BODY'
set -euo pipefail
crates="[]"
if [ -f "$ANODIZER_STDOUT_LOG" ]; then
  last=$(grep -oP '(?<=^anodizer-output crates=)\[.*\]' "$ANODIZER_STDOUT_LOG" | tail -1 || true)
  [ -n "$last" ] && crates="$last"
fi
echo "crates=${crates}" >> "$GITHUB_OUTPUT"
BODY

    grep '^crates=' "$github_output" | cut -d= -f2-
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "crates output: marker with populated array" {
    result="$(_run_crates_parse 'anodizer-output crates=["a","b"]')"
    [ "$result" = '["a","b"]' ]
}

@test "crates output: marker with empty array" {
    result="$(_run_crates_parse 'anodizer-output crates=[]')"
    [ "$result" = '[]' ]
}

@test "crates output: no marker present defaults to empty array" {
    result="$(_run_crates_parse 'some other output line')"
    [ "$result" = '[]' ]
}

@test "crates output: last occurrence wins when marker appears twice" {
    log="$(printf '%s\n%s\n' \
        'anodizer-output crates=["first"]' \
        'anodizer-output crates=["second","third"]')"
    result="$(_run_crates_parse "$log")"
    [ "$result" = '["second","third"]' ]
}

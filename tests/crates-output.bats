#!/usr/bin/env bats
# crates-output.bats — tests for the `crates` step output.
#
# Covers the shell logic that parses `anodizer-output crates=...` lines from
# ANODIZER_STDOUT_LOG and emits the value to GITHUB_OUTPUT, plus the run-step
# pipeline that produces the log:
#
#   1. CLI emits the marker with a populated array → crates output matches.
#   2. CLI emits the marker with an empty array    → crates output is `[]`.
#   3. CLI emits no marker                         → crates output defaults to `[]`.
#   4. CLI emits the marker twice                  → last value wins.
#   5. CLI emits the marker on stderr              → IGNORED (stdout-only contract).

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
# Helper: exercise the run-step's `anodizer | tee` pipeline with a stub that
# writes the supplied lines to the requested stream(s), then run the parser.
# Returns the crates output value via stdout.
#
# $1 — bash body executed inside the stub `anodizer`. Anything written to
#      stdout (echo / printf without redirection) feeds the tee'd log; anything
#      written to stderr (>&2) must NOT reach the log.
# ---------------------------------------------------------------------------
_run_pipeline_with_stub() {
    local stub_body="$1"
    local log_file="${_TEST_HOME}/anodizer-stdout.log"
    local github_output="${_TEST_HOME}/github-output"
    local fake_bin="${_TEST_HOME}/fake-bin"

    mkdir -p "$fake_bin"
    cat > "${fake_bin}/anodizer" <<STUB
#!/usr/bin/env bash
${stub_body}
STUB
    chmod +x "${fake_bin}/anodizer"
    : > "$github_output"

    PATH="${fake_bin}:${PATH}" ANODIZER_STDOUT_LOG="$log_file" \
        GITHUB_OUTPUT="$github_output" \
        bash <<'BODY'
set -euo pipefail
: > "$ANODIZER_STDOUT_LOG"
# Mirrors the production "Run anodizer" tee invocation exactly — stdout is
# captured to the log; stderr passes through untouched.
anodizer | tee -a "$ANODIZER_STDOUT_LOG" >/dev/null
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

@test "crates output: marker on stderr is ignored (stdout-only contract)" {
    # The stub writes a marker to STDERR and a non-marker line to STDOUT.
    # The production pipeline tees stdout only, so the stderr marker must
    # not reach the captured log and must not influence the parsed output.
    result="$(_run_pipeline_with_stub '
echo "regular progress output"
echo "anodizer-output crates=[\"sneaky\"]" >&2
')"
    [ "$result" = '[]' ]
}

@test "crates output: pipeline captures stdout marker through tee" {
    # Companion to the stderr-ignored test: confirm a marker emitted on
    # STDOUT through the real `anodizer | tee` pipeline still reaches the
    # parser. Guards against an over-zealous fix that breaks both channels.
    result="$(_run_pipeline_with_stub '
echo "starting"
echo "anodizer-output crates=[\"a\",\"b\"]"
echo "done"
')"
    [ "$result" = '["a","b"]' ]
}

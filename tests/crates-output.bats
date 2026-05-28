#!/usr/bin/env bats
# crates-output.bats — tests for the `crates` and `versions` step outputs.
#
# Covers the shell logic that parses `anodizer-output crates=...` and
# `anodizer-output versions=...` lines from ANODIZER_STDOUT_LOG and emits
# the values to GITHUB_OUTPUT, plus the run-step pipeline that produces the log:
#
#  crates:
#   1. CLI emits the marker with a populated array → crates output matches.
#   2. CLI emits the marker with an empty array    → crates output is `[]`.
#   3. CLI emits no marker                         → crates output defaults to `[]`.
#   4. CLI emits the marker twice                  → last value wins.
#   5. CLI emits the marker on stderr              → IGNORED (stdout-only contract).
#   6. Pipeline captures stdout marker through tee.
#   7. Marker with whitespace after `=`            → must NOT match.
#   8. Marker as substring of larger line          → must NOT match (^ anchor).
#   9. Malformed JSON value                        → falls back to `[]`.
#
#  versions:
#  10. CLI emits populated versions object         → output matches.
#  11. CLI emits empty versions object             → output is `{}`.
#  12. CLI emits no versions marker                → output defaults to `{}`.
#  13. Versions marker on stderr                   → IGNORED.
#  14. Both crates= and versions= present          → both surface correctly.
#  15. Malformed versions value                    → falls back to `{}`.

load test_helper

# ---------------------------------------------------------------------------
# Helper: run the full "Collect outputs" parsing body with a caller-supplied
# stdout log content. Mirrors the production shell exactly — including jq
# validation and the versions= sibling extraction.
# ---------------------------------------------------------------------------
_run_outputs_parse() {
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
  if [ -n "$last" ] && echo "$last" | jq -e . >/dev/null 2>&1; then
    crates="$last"
  fi
fi
echo "crates=${crates}" >> "$GITHUB_OUTPUT"

versions="{}"
if [ -f "$ANODIZER_STDOUT_LOG" ]; then
  last=$(grep -oP '(?<=^anodizer-output versions=)\{.*\}' "$ANODIZER_STDOUT_LOG" | tail -1 || true)
  if [ -n "$last" ] && echo "$last" | jq -e . >/dev/null 2>&1; then
    versions="$last"
  fi
fi
echo "versions=${versions}" >> "$GITHUB_OUTPUT"
BODY

    # Return both values as "crates=... versions=..." so callers can extract
    # whichever field they need.
    cat "$github_output"
}

# Convenience wrappers that extract a single field from _run_outputs_parse output.
_parse_crates() {
    _run_outputs_parse "$1" | grep '^crates=' | cut -d= -f2-
}

_parse_versions() {
    _run_outputs_parse "$1" | grep '^versions=' | cut -d= -f2-
}

# ---------------------------------------------------------------------------
# Helper: exercise the run-step's `anodizer | tee` pipeline with a stub that
# writes the supplied lines to the requested stream(s), then run the parser.
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
  if [ -n "$last" ] && echo "$last" | jq -e . >/dev/null 2>&1; then
    crates="$last"
  fi
fi
echo "crates=${crates}" >> "$GITHUB_OUTPUT"

versions="{}"
if [ -f "$ANODIZER_STDOUT_LOG" ]; then
  last=$(grep -oP '(?<=^anodizer-output versions=)\{.*\}' "$ANODIZER_STDOUT_LOG" | tail -1 || true)
  if [ -n "$last" ] && echo "$last" | jq -e . >/dev/null 2>&1; then
    versions="$last"
  fi
fi
echo "versions=${versions}" >> "$GITHUB_OUTPUT"
BODY

    cat "$github_output"
}

_pipeline_crates() { _run_pipeline_with_stub "$1" | grep '^crates=' | cut -d= -f2-; }
_pipeline_versions() { _run_pipeline_with_stub "$1" | grep '^versions=' | cut -d= -f2-; }

# ---------------------------------------------------------------------------
# crates= tests
# ---------------------------------------------------------------------------

@test "crates output: marker with populated array" {
    result="$(_parse_crates 'anodizer-output crates=["a","b"]')"
    [ "$result" = '["a","b"]' ]
}

@test "crates output: marker with empty array" {
    result="$(_parse_crates 'anodizer-output crates=[]')"
    [ "$result" = '[]' ]
}

@test "crates output: no marker present defaults to empty array" {
    result="$(_parse_crates 'some other output line')"
    [ "$result" = '[]' ]
}

@test "crates output: last occurrence wins when marker appears twice" {
    log="$(printf '%s\n%s\n' \
        'anodizer-output crates=["first"]' \
        'anodizer-output crates=["second","third"]')"
    result="$(_parse_crates "$log")"
    [ "$result" = '["second","third"]' ]
}

@test "crates output: marker on stderr is ignored (stdout-only contract)" {
    # The stub writes a marker to STDERR and a non-marker line to STDOUT.
    # The production pipeline tees stdout only, so the stderr marker must
    # not reach the captured log and must not influence the parsed output.
    result="$(_pipeline_crates '
echo "regular progress output"
echo "anodizer-output crates=[\"sneaky\"]" >&2
')"
    [ "$result" = '[]' ]
}

@test "crates output: pipeline captures stdout marker through tee" {
    # Companion to the stderr-ignored test: confirm a marker emitted on
    # STDOUT through the real `anodizer | tee` pipeline still reaches the
    # parser. Guards against an over-zealous fix that breaks both channels.
    result="$(_pipeline_crates '
echo "starting"
echo "anodizer-output crates=[\"a\",\"b\"]"
echo "done"
')"
    [ "$result" = '["a","b"]' ]
}

@test "crates output: whitespace after = does not match (contract: no spaces before value)" {
    # The regex uses a fixed lookbehind — `crates= [...]` (space before bracket)
    # must not match, documenting that the CLI emits no padding around `=`.
    result="$(_parse_crates 'anodizer-output crates= ["a"]')"
    [ "$result" = '[]' ]
}

@test "crates output: marker as substring of larger line does not match (^ anchor)" {
    # The ^ anchor in the production grep ensures a prefix before the marker
    # causes the line to be silently skipped. Guards against regex regression
    # if the lookbehind is ever relaxed.
    result="$(_parse_crates 'WARN: anodizer-output crates=["a"]')"
    [ "$result" = '[]' ]
}

@test "crates output: malformed JSON value falls back to empty array" {
    # A bracketed-but-invalid JSON value passes the regex but must be rejected
    # by the jq validation guard, preventing a silent fromJson() failure downstream.
    result="$(_parse_crates 'anodizer-output crates=[not valid json]')"
    [ "$result" = '[]' ]
}

# ---------------------------------------------------------------------------
# versions= tests
# ---------------------------------------------------------------------------

@test "versions output: populated object surfaces correctly" {
    result="$(_parse_versions 'anodizer-output versions={"a":"1.0.0","b":"2.0.0"}')"
    [ "$result" = '{"a":"1.0.0","b":"2.0.0"}' ]
}

@test "versions output: empty object emitted as-is" {
    result="$(_parse_versions 'anodizer-output versions={}')"
    [ "$result" = '{}' ]
}

@test "versions output: no marker defaults to empty object" {
    result="$(_parse_versions 'some other output line')"
    [ "$result" = '{}' ]
}

@test "versions output: marker on stderr is ignored (stdout-only contract)" {
    result="$(_pipeline_versions '
echo "regular progress output"
echo "anodizer-output versions={\"sneaky\":\"9.9.9\"}" >&2
')"
    [ "$result" = '{}' ]
}

@test "versions output: malformed JSON value falls back to empty object" {
    result="$(_parse_versions 'anodizer-output versions=[not valid]')"
    [ "$result" = '{}' ]
}

@test "crates and versions both present: both surface correctly" {
    log="$(printf '%s\n%s\n' \
        'anodizer-output crates=["cfgd-core","cfgd"]' \
        'anodizer-output versions={"cfgd-core":"0.4.0","cfgd":"1.0.0"}')"
    out="$(_run_outputs_parse "$log")"
    crates_val="$(printf '%s' "$out" | grep '^crates=' | cut -d= -f2-)"
    versions_val="$(printf '%s' "$out" | grep '^versions=' | cut -d= -f2-)"
    [ "$crates_val" = '["cfgd-core","cfgd"]' ]
    [ "$versions_val" = '{"cfgd-core":"0.4.0","cfgd":"1.0.0"}' ]
}

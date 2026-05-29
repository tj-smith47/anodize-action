#!/usr/bin/env bats
# colors-verb-stderr.bats — regression guard for the verb→stderr contract.
#
# The action's stdout is the clean marker/value channel (see
# scripts/run/anodizer.sh stdout-only contract). Pure-diagnostic helpers
# must therefore write to stderr so a caller that captures a function's
# stdout via $(...) never ingests an ANSI-colored diagnostic line. The
# regression that motivated this: `resolve_max_retries` calls
# anodizer::verb before its `echo <N>`, and its stdout is captured as
# `max_retries=$(resolve_max_retries)`. When verb printed to stdout with
# color forced on (CI), the capture became the colored verb line PLUS the
# integer, blowing up the numeric `[ $attempt -le $max_retries ]` test.

load test_helper

COLORS="${REPO_ROOT}/scripts/lib/colors.sh"

@test "anodizer::verb writes to stderr, not stdout (color forced on)" {
    run bash -c "ANODIZER_COLOR=always source '$COLORS'; anodizer::verb Installing thing 2>/dev/null"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "anodizer::verb content lands on stderr (color forced on)" {
    run bash -c "ANODIZER_COLOR=always source '$COLORS'; anodizer::verb Installing thing 1>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *Installing* ]]
    [[ "$output" == *thing* ]]
}

@test "run/anodizer.sh: stateful-mode capture stays numeric (color forced on)" {
    # Drives the real script end-to-end. Stub `anodizer` exits 0 on first
    # call so the retry loop never sleeps. With color forced on, the verb
    # diagnostic emitted inside resolve_max_retries must NOT contaminate the
    # `max_retries=$(resolve_max_retries)` capture — otherwise the numeric
    # `[ $attempt -le $max_retries ]` test in main() explodes.
    local fake_bin="${_TEST_HOME}/fake-bin"
    mkdir -p "$fake_bin"
    cat > "${fake_bin}/anodizer" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "${fake_bin}/anodizer"

    ANODIZER_COLOR=always \
    GITHUB_ACTION_PATH="${REPO_ROOT}" \
    ANODIZER_ARGS='release --publish-only' \
    ANODIZER_STDOUT_LOG="${_TEST_HOME}/stdout.log" \
    PATH="${fake_bin}:${PATH}" \
        run bash "${REPO_ROOT}/scripts/run/anodizer.sh"

    [ "$status" -eq 0 ]
    # On regression the contaminated capture makes `[ $attempt -le
    # $max_retries ]` choke; bash reports "integer expected" (wording
    # varies by build, hence the broad match on the test-builtin's name).
    [[ "$output" != *"integer expected"* ]]
    [[ "$output" != *"integer expression expected"* ]]
}

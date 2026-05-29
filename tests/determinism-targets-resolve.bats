#!/usr/bin/env bats
# determinism-targets-resolve.bats — unit tests for
# scripts/determinism/resolve-targets.sh.
#
# Stubs `anodizer targets --json` via the ANODIZE_BIN env hook so the script
# never spawns a real binary. Covers RUNNER_OS → target-CSV derivation,
# override passthrough, and the two loud-fail paths (no matching entries,
# bad RUNNER_OS).

load test_helper

SCRIPT="${REPO_ROOT}/scripts/determinism/resolve-targets.sh"

# A representative `anodizer targets --json` payload. Mirrors the real shape
# (matrix-style {"include": [...]} with os = runner labels).
FIXTURE_JSON='{
  "include": [
    {"os":"ubuntu-latest","target":"x86_64-unknown-linux-gnu","artifact":"dist-Linux"},
    {"os":"ubuntu-latest","target":"aarch64-unknown-linux-gnu","artifact":"dist-Linux"},
    {"os":"macos-latest","target":"x86_64-apple-darwin","artifact":"dist-macOS"},
    {"os":"macos-latest","target":"aarch64-apple-darwin","artifact":"dist-macOS"},
    {"os":"windows-latest","target":"x86_64-pc-windows-msvc","artifact":"dist-Windows"},
    {"os":"windows-latest","target":"aarch64-pc-windows-msvc","artifact":"dist-Windows"}
  ]
}'

setup() {
    common_setup

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    # Stub: `fake-anodizer targets --json` prints the fixture JSON. The
    # script is invoked with ANODIZE_BIN=fake-anodizer so the real binary
    # never enters the test.
    cat > "${FAKE_BIN}/fake-anodizer" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "targets" ] && [ "\$2" = "--json" ]; then
    cat <<'JSON'
${FIXTURE_JSON}
JSON
    exit 0
fi
exit 2
STUB
    chmod +x "${FAKE_BIN}/fake-anodizer"

    # Empty-payload variant for the "no matching entries" test.
    cat > "${FAKE_BIN}/fake-anodizer-empty" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "targets" ] && [ "$2" = "--json" ]; then
    printf '{"include":[]}\n'
    exit 0
fi
exit 2
STUB
    chmod +x "${FAKE_BIN}/fake-anodizer-empty"

    PATH="${FAKE_BIN}:${PATH}"
    export PATH

    # GITHUB_OUTPUT lets us verify the action-contract side-effect too.
    GITHUB_OUTPUT="${_TEST_HOME}/github-output"
    : > "$GITHUB_OUTPUT"
    export GITHUB_OUTPUT
}

teardown() {
    common_teardown
}

@test "override passthrough — explicit CSV wins regardless of RUNNER_OS" {
    RUNNER_OS=Linux OVERRIDE='custom-triple-1,custom-triple-2' \
        ANODIZE_BIN=fake-anodizer \
        run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"custom-triple-1,custom-triple-2"* ]]
    grep -qx 'csv=custom-triple-1,custom-triple-2' "$GITHUB_OUTPUT"
}

@test "RUNNER_OS=Linux → joins ubuntu-latest entries" {
    RUNNER_OS=Linux ANODIZE_BIN=fake-anodizer run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx 'csv=x86_64-unknown-linux-gnu,aarch64-unknown-linux-gnu' "$GITHUB_OUTPUT"
}

@test "RUNNER_OS=macOS → joins macos-latest (darwin) entries" {
    RUNNER_OS=macOS ANODIZE_BIN=fake-anodizer run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx 'csv=x86_64-apple-darwin,aarch64-apple-darwin' "$GITHUB_OUTPUT"
}

@test "RUNNER_OS=Windows → joins windows-latest entries" {
    RUNNER_OS=Windows ANODIZE_BIN=fake-anodizer run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx 'csv=x86_64-pc-windows-msvc,aarch64-pc-windows-msvc' "$GITHUB_OUTPUT"
}

@test "no matching entries → exit 1 with explanatory error" {
    RUNNER_OS=Linux ANODIZE_BIN=fake-anodizer-empty run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No targets match RUNNER_OS=Linux"* ]]
}

@test "unsupported RUNNER_OS → exit 1 before invoking anodizer" {
    RUNNER_OS=FreeBSD ANODIZE_BIN=fake-anodizer run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unsupported RUNNER_OS for determinism: FreeBSD"* ]]
}

@test "bare-array JSON shape is also accepted (forward-compat)" {
    cat > "${_TEST_HOME}/fake-bin/fake-anodizer-bare" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "targets" ] && [ "$2" = "--json" ]; then
    printf '[{"os":"ubuntu-latest","target":"only-one","artifact":"dist-Linux"}]\n'
    exit 0
fi
exit 2
STUB
    chmod +x "${_TEST_HOME}/fake-bin/fake-anodizer-bare"
    RUNNER_OS=Linux ANODIZE_BIN=fake-anodizer-bare run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx 'csv=only-one' "$GITHUB_OUTPUT"
}

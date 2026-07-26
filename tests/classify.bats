#!/usr/bin/env bats
# classify.bats — unit tests for scripts/install/classify.sh, the single
# source of truth that turns the action inputs into the install-plan
# booleans (install_method / needs_rust / needs_cargo_cache / needs_sccache /
# run_anodizer) consumed via `steps.plan.outputs.*` in action.yml.
#
# The classifier reads its inputs from env (all optional, empty when unset)
# and writes `key=value` lines to $GITHUB_OUTPUT. Each test runs it with one
# input tuple and asserts the emitted plan. No network, no toolchain — the
# script is pure input arithmetic.
#
# Coverage centers on the toolchain-gating invariant: every install_method
# that compiles anodizer (source, branch) MUST also set needs_rust=true, or
# the Rust toolchain is never installed and the build fails. The from-source
# tuple (test "from-source alone …") is the regression guard for the bug
# where needs_rust omitted FROM_SOURCE while install_method=source.

load test_helper

setup() {
    common_setup
    export GITHUB_OUTPUT="${_TEST_HOME}/github_output"
    : > "$GITHUB_OUTPUT"
}

teardown() {
    common_teardown
}

# Run classify.sh with the given env assignments (e.g. FROM_SOURCE=true).
# Every input the script reads is defaulted to empty here so an unset var
# under `set -u` never aborts the run and each test only sets what it varies.
_run_classify() {
    run env \
        FROM_ARTIFACT="" FROM_BRANCH="" FROM_SOURCE="" \
        DETERMINISM="" VERSION="" INSTALL_RUST="" INSTALL_ONLY="" ARGS="" \
        GITHUB_OUTPUT="${GITHUB_OUTPUT}" \
        NO_COLOR=1 \
        "$@" \
        bash "${REPO_ROOT}/scripts/install/classify.sh"
}

# Assert a `key=value` line is present in $GITHUB_OUTPUT.
_assert_output_kv() {
    local key="$1" value="$2"
    if ! grep -qx "${key}=${value}" "$GITHUB_OUTPUT"; then
        echo "expected '${key}=${value}' in GITHUB_OUTPUT; got:" >&2
        cat "$GITHUB_OUTPUT" >&2
        return 1
    fi
}

# ── Default tuple → plain release download, no toolchain ───────────────────

@test "classify: all-default inputs -> release, no rust/cache/sccache" {
    _run_classify
    [ "$status" -eq 0 ]
    _assert_output_kv install_method release
    _assert_output_kv needs_rust false
    _assert_output_kv needs_cargo_cache false
    _assert_output_kv needs_sccache false
    _assert_output_kv run_anodizer false
}

# ── Regression guard: from-source alone must install Rust ──────────────────
# install_method=source compiles anodizer and REQUIRES the toolchain; before
# the fix needs_rust omitted FROM_SOURCE and stayed false, so the build ran
# on a runner without Rust and failed. needs_cargo_cache / needs_sccache
# already included FROM_SOURCE — needs_rust is now consistent with them.

@test "classify: from-source alone -> source AND needs_rust=true (toolchain provisioned)" {
    _run_classify FROM_SOURCE="true"
    [ "$status" -eq 0 ]
    _assert_output_kv install_method source
    _assert_output_kv needs_rust true
    _assert_output_kv needs_cargo_cache true
    _assert_output_kv needs_sccache true
}

# ── determinism (version unpinned) → source build, full toolchain ──────────

@test "classify: determinism + unpinned version -> source, full toolchain" {
    _run_classify DETERMINISM="true"
    [ "$status" -eq 0 ]
    _assert_output_kv install_method source
    _assert_output_kv needs_rust true
    _assert_output_kv needs_cargo_cache true
    _assert_output_kv needs_sccache true
    # Determinism never runs anodizer post-install (the harness owns the run).
    _assert_output_kv run_anodizer false
}

# ── determinism + a pinned (non-latest) version → release download ─────────

@test "classify: determinism + pinned version -> release (downloads the pinned tag)" {
    _run_classify DETERMINISM="true" VERSION="v1.2.3"
    [ "$status" -eq 0 ]
    _assert_output_kv install_method release
    # Rust is still wanted under determinism (harness rebuilds), even though
    # the initial install is a download.
    _assert_output_kv needs_rust true
}

# ── from-branch → branch build, needs_rust + caches ────────────────────────

@test "classify: from-branch -> branch AND needs_rust=true" {
    _run_classify FROM_BRANCH="main"
    [ "$status" -eq 0 ]
    _assert_output_kv install_method branch
    _assert_output_kv needs_rust true
    _assert_output_kv needs_cargo_cache true
    # sccache does not include from-branch — assert it stays false so the
    # gating tables stay distinct.
    _assert_output_kv needs_sccache false
}

# ── install-rust input alone forces the toolchain without a source build ───

@test "classify: install-rust input -> needs_rust=true while install_method stays release" {
    _run_classify INSTALL_RUST="true"
    [ "$status" -eq 0 ]
    _assert_output_kv install_method release
    _assert_output_kv needs_rust true
    _assert_output_kv needs_cargo_cache false
    _assert_output_kv needs_sccache false
}

# ── precedence: artifact wins over every other method ──────────────────────

@test "classify: artifact-id outranks from-source/branch for install_method" {
    _run_classify FROM_ARTIFACT="123" FROM_SOURCE="true" FROM_BRANCH="main"
    [ "$status" -eq 0 ]
    _assert_output_kv install_method artifact
    # FROM_SOURCE/FROM_BRANCH still drive the toolchain booleans regardless
    # of which method ultimately won.
    _assert_output_kv needs_rust true
}

# ── run_anodizer gating: args present, not install-only, not determinism ───

@test "classify: args + not install-only + not determinism -> run_anodizer=true" {
    _run_classify ARGS="release --clean"
    [ "$status" -eq 0 ]
    _assert_output_kv run_anodizer true
}

@test "classify: install-only suppresses run_anodizer even with args" {
    _run_classify ARGS="release --clean" INSTALL_ONLY="true"
    [ "$status" -eq 0 ]
    _assert_output_kv run_anodizer false
}

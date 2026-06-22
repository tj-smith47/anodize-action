#!/usr/bin/env bats
# auto-detect-linux-pkg-os-gate.bats — unit tests for the OS gating of the
# Linux-only package deps in scripts/install/auto-detect-deps.sh.
#
# nfpm (deb/rpm/apk), makeself (.run self-extractor), snapcraft (snap) and
# rpmbuild (source RPM) all produce Linux-only package formats. They must be
# emitted on Linux and SKIPPED (with a warning, not a failure) on macOS/Windows
# — mirroring flatpaks/appimages. Regression: a Windows determinism shard with
# auto-install emitted `nfpm` unconditionally, the dispatcher tried
# `choco install nfpm` (no choco package exists), and the install hard-failed
# before anodizer ran — sinking the whole release pipeline at the determinism
# gate.

load test_helper

setup() {
    common_setup
    export GITHUB_OUTPUT="${_TEST_HOME}/github_output"
    : > "$GITHUB_OUTPUT"
}

teardown() {
    common_teardown
}

_run_auto_detect() {
    local cfg_body="$1" runner_os="${2:-Linux}" cfg_name="${3:-.anodizer.yaml}"
    local workdir="${_TEST_HOME}/workdir"
    rm -rf "$workdir"
    mkdir -p "$workdir"
    printf '%s\n' "$cfg_body" > "${workdir}/${cfg_name}"
    run env \
        GITHUB_OUTPUT="${GITHUB_OUTPUT}" \
        NO_COLOR=1 \
        RUNNER_OS="$runner_os" \
        bash -c "cd '${workdir}' && bash '${REPO_ROOT}/scripts/install/auto-detect-deps.sh'"
}

# ── nfpm ───────────────────────────────────────────────────────────────────

@test "linux-pkg-gate: nfpm config emits nfpm on Linux" {
    _run_auto_detect $'nfpm:\n  - package_name: probe' Linux
    [ "$status" -eq 0 ]
    grep -qE '^deps=.*nfpm' "$GITHUB_OUTPUT"
}

@test "linux-pkg-gate: nfpm config is SKIPPED on Windows (no choco install nfpm)" {
    _run_auto_detect $'nfpm:\n  - package_name: probe' Windows
    [ "$status" -eq 0 ]
    ! grep -qE '^deps=.*nfpm' "$GITHUB_OUTPUT"
}

@test "linux-pkg-gate: nfpm config is SKIPPED on macOS" {
    _run_auto_detect $'nfpm:\n  - package_name: probe' macOS
    [ "$status" -eq 0 ]
    ! grep -qE '^deps=.*nfpm' "$GITHUB_OUTPUT"
}

# ── makeself / snapcraft / rpmbuild ─────────────────────────────────────────

@test "linux-pkg-gate: makeselfs/snapcrafts/srpm emit on Linux" {
    _run_auto_detect $'makeselfs:\n  - id: a\nsnapcrafts:\n  - id: b\nsrpm:\n  enabled: true' Linux
    [ "$status" -eq 0 ]
    grep -qE '^deps=.*makeself' "$GITHUB_OUTPUT"
    grep -qE '^deps=.*snapcraft' "$GITHUB_OUTPUT"
    grep -qE '^deps=.*rpmbuild' "$GITHUB_OUTPUT"
}

@test "linux-pkg-gate: makeselfs/snapcrafts/srpm are SKIPPED on Windows" {
    _run_auto_detect $'makeselfs:\n  - id: a\nsnapcrafts:\n  - id: b\nsrpm:\n  enabled: true' Windows
    [ "$status" -eq 0 ]
    ! grep -qE '^deps=.*makeself' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=.*snapcraft' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=.*rpmbuild' "$GITHUB_OUTPUT"
}

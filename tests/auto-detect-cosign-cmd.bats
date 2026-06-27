#!/usr/bin/env bats
# auto-detect-cosign-cmd.bats — unit tests for the cmd-based cosign detection
# in scripts/install/auto-detect-deps.sh.
#
# anodizer's per-block default signing `cmd:` differs by sign type (verified
# against crates/core/src/signing.rs):
#   - `signs:` / `binary_signs:` (SignConfig) default to GPG when `cmd:` is
#     unset → cosign installs ONLY when a block sets `cmd: cosign`.
#   - `docker_signs:` (DockerSignConfig) has a STATIC cosign default
#     (DEFAULT_CMD = "cosign") → cosign installs even with no `cmd:` line.
# GPG is preinstalled on every runner, so a gpg block must pull NOTHING.
#
# Covers (YAML, then the same contract spelled in TOML):
#   1. signs: with cmd: cosign            → cosign emitted
#   2. binary_signs: with cmd: cosign     → cosign emitted
#   3. docker_signs: with no cmd:         → cosign emitted (static default)
#   4. binary_signs: with cmd: gpg        → cosign NOT emitted
#   5. signs: with no cmd: (gpg default)  → cosign NOT emitted
#   6. [[signs]] with cmd = "cosign"      → cosign emitted
#   7. [[docker_signs]] with no cmd       → cosign emitted (static default)
#   8. [[binary_signs]] with cmd = "gpg"  → cosign NOT emitted

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

@test "cosign-cmd: signs: with cmd: cosign emits cosign" {
    _run_auto_detect $'signs:\n  - artifacts: all\n    cmd: cosign'
    [ "$status" -eq 0 ]
    grep -q '^deps=.*cosign' "$GITHUB_OUTPUT"
}

@test "cosign-cmd: binary_signs: with cmd: cosign emits cosign" {
    _run_auto_detect $'binary_signs:\n  - artifacts: binary\n    cmd: cosign'
    [ "$status" -eq 0 ]
    grep -q '^deps=.*cosign' "$GITHUB_OUTPUT"
}

# B2/W3: a single-quoted YAML scalar (`cmd: 'cosign'`) is valid and must pull
# cosign just like the double-quoted/bare forms — has_kv accepts either quote.
@test "cosign-cmd: signs: with single-quoted cmd: 'cosign' emits cosign" {
    _run_auto_detect $'signs:\n  - artifacts: all\n    cmd: \'cosign\''
    [ "$status" -eq 0 ]
    grep -q '^deps=.*cosign' "$GITHUB_OUTPUT"
}

# B2/W3 (TOML): a single-quoted TOML literal string is equally valid.
@test "cosign-cmd: TOML [[signs]] with single-quoted cmd = 'cosign' emits cosign" {
    _run_auto_detect $'[[signs]]\nartifacts = "all"\ncmd = \'cosign\'' Linux .anodizer.toml
    [ "$status" -eq 0 ]
    grep -q '^deps=.*cosign' "$GITHUB_OUTPUT"
}

@test "cosign-cmd: docker_signs: with no cmd: emits cosign (static default)" {
    _run_auto_detect $'docker_signs:\n  - artifacts: all'
    [ "$status" -eq 0 ]
    grep -q '^deps=.*cosign' "$GITHUB_OUTPUT"
}

@test "cosign-cmd: binary_signs: with cmd: gpg does NOT emit cosign" {
    _run_auto_detect $'binary_signs:\n  - artifacts: binary\n    cmd: gpg'
    [ "$status" -eq 0 ]
    grep -q '^deps=' "$GITHUB_OUTPUT"
    ! grep -q 'cosign' "$GITHUB_OUTPUT"
}

@test "cosign-cmd: signs: with no cmd: (gpg default) does NOT emit cosign" {
    _run_auto_detect $'signs:\n  - artifacts: all'
    [ "$status" -eq 0 ]
    grep -q '^deps=' "$GITHUB_OUTPUT"
    ! grep -q 'cosign' "$GITHUB_OUTPUT"
}

@test "cosign-cmd: TOML [[signs]] with cmd = \"cosign\" emits cosign" {
    _run_auto_detect $'[[signs]]\nartifacts = "all"\ncmd = "cosign"' Linux .anodizer.toml
    [ "$status" -eq 0 ]
    grep -q '^deps=.*cosign' "$GITHUB_OUTPUT"
}

@test "cosign-cmd: TOML [[docker_signs]] with no cmd emits cosign (static default)" {
    _run_auto_detect $'[[docker_signs]]\nartifacts = "all"' Linux .anodizer.toml
    [ "$status" -eq 0 ]
    grep -q '^deps=.*cosign' "$GITHUB_OUTPUT"
}

@test "cosign-cmd: TOML [[binary_signs]] with cmd = \"gpg\" does NOT emit cosign" {
    _run_auto_detect $'[[binary_signs]]\nartifacts = "binary"\ncmd = "gpg"' Linux .anodizer.toml
    [ "$status" -eq 0 ]
    grep -q '^deps=' "$GITHUB_OUTPUT"
    ! grep -q 'cosign' "$GITHUB_OUTPUT"
}

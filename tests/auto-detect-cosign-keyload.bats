#!/usr/bin/env bats
# auto-detect-cosign-keyload.bats — unit tests for the preflight KEY-LOAD arm
# of cosign detection in scripts/install/auto-detect-deps.sh (F1).
#
# `release --preflight-secrets` offline load-verifies EVERY cosign key the
# config references (crates/cli/src/commands/preflight.rs::cosign_key_refs →
# one KeyEnv{Cosign} per `env://VAR` ref under a cosign-cmd sign block, emitted
# by crates/stage-sign/src/lib.rs::entry_env_requirements). When cosign is
# absent the load check WARN-skips — a silent false-green that lets a bad
# COSIGN_PASSWORD slip past the pre-tag gate. anodizer's `is_cosign_cmd`
# (crates/stage-sign/src/process.rs) matches any `cosign*` BASENAME, so a
# `cmd: cosign-fips` (or any variant) bearing an `env://` key is a cosign key
# reference the exact `has_kv cmd cosign` probe misses.
#
# Contract: cosign is emitted whenever a cosign-VARIANT cmd co-occurs with an
# `env://` key ref (the full `cosign_key_refs()` set), and NOT emitted when the
# config has zero cosign key references. The exact-`cmd: cosign` and
# `docker_signs:` arms (auto-detect-cosign-cmd.bats) are unaffected.

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

# ── cosign-variant cmd + env:// key → cosign emitted ─────────────────────────

@test "cosign-keyload: cmd cosign-fips with env:// key emits cosign" {
    _run_auto_detect $'binary_signs:\n  - cmd: cosign-fips\n    args: ["sign-blob", "--key=env://COSIGN_KEY"]'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*cosign(,|$)' "$GITHUB_OUTPUT"
}

@test "cosign-keyload: signs: cmd cosign with env:// key emits cosign" {
    _run_auto_detect $'signs:\n  - cmd: cosign\n    args: ["--key=env://COSIGN_KEY"]'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*cosign(,|$)' "$GITHUB_OUTPUT"
}

@test "cosign-keyload: env:// in env: block under cosign cmd emits cosign" {
    _run_auto_detect $'signs:\n  - cmd: cosign-custom\n    env: ["COSIGN_KEY=env://COSIGN_KEY"]'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*cosign(,|$)' "$GITHUB_OUTPUT"
}

@test "cosign-keyload: nested (per-crate) cosign-variant + env:// key emits cosign" {
    _run_auto_detect $'crates:\n  - id: anodizer\n    binary_signs:\n      - cmd: cosign-fips\n        args: ["--key=env://COSIGN_KEY"]'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*cosign(,|$)' "$GITHUB_OUTPUT"
}

# B2/W3: a single-quoted cosign-variant cmd scalar must still register as a
# cosign cmd (has_cosign_variant_cmd accepts either quote), so a co-occurring
# env:// key ref pulls cosign.
@test "cosign-keyload: single-quoted cmd: 'cosign-fips' + env:// key emits cosign" {
    _run_auto_detect $'signs:\n  - cmd: \'cosign-fips\'\n    args: ["--key=env://COSIGN_KEY"]'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*cosign(,|$)' "$GITHUB_OUTPUT"
}

# W5: the cosign-variant-cmd and env://-ref probes are decoupled whole-file
# greps, so a cosign-variant cmd in ONE block plus an env:// ref in an
# UNRELATED block triggers the cosign install. This over-install is INTENTIONAL
# and consistent with the bare `cmd: cosign` whole-file rule (idempotent, cheap;
# block-scoping would make this probe asymmetrically stricter). Pin it so the
# behavior is codified, not accidental.
@test "cosign-keyload: cosign-variant cmd + env:// ref in unrelated block emits cosign (intentional over-install)" {
    _run_auto_detect $'binary_signs:\n  - cmd: cosign-fips\nblobs:\n  - kms_key: env://KMS_KEY'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*cosign(,|$)' "$GITHUB_OUTPUT"
}

# ── zero cosign key references → cosign NOT emitted ──────────────────────────

@test "cosign-keyload: cosign-foo with NO env:// key does NOT emit cosign" {
    _run_auto_detect $'binary_signs:\n  - cmd: cosign-foo'
    [ "$status" -eq 0 ]
    grep -q '^deps=' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*cosign(,|$)' "$GITHUB_OUTPUT"
}

@test "cosign-keyload: gpg cmd with an env:// key does NOT emit cosign" {
    # env:// is cosign-key-specific; a gpg block must never pull cosign even if
    # some value happened to carry the scheme (no cosign cmd → no cosign key).
    _run_auto_detect $'binary_signs:\n  - cmd: gpg\n    args: ["--key=env://GPG_KEY"]'
    [ "$status" -eq 0 ]
    grep -q '^deps=' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*cosign(,|$)' "$GITHUB_OUTPUT"
}

@test "cosign-keyload: cosign-variant cmd WITHOUT any env:// ref does NOT emit cosign" {
    _run_auto_detect $'signs:\n  - cmd: cosign-fips\n    args: ["sign-blob"]'
    [ "$status" -eq 0 ]
    grep -q '^deps=' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*cosign(,|$)' "$GITHUB_OUTPUT"
}

@test "cosign-keyload: a config with no sign blocks at all emits no cosign" {
    _run_auto_detect $'sboms:\n  - cmd: syft'
    [ "$status" -eq 0 ]
    ! grep -qE '^deps=([^,]*,)*cosign(,|$)' "$GITHUB_OUTPUT"
}

# ── TOML shape ───────────────────────────────────────────────────────────────

@test "cosign-keyload: TOML [[binary_signs]] cosign-variant + env:// emits cosign" {
    _run_auto_detect $'[[binary_signs]]\ncmd = "cosign-fips"\nargs = ["--key=env://COSIGN_KEY"]' Linux .anodizer.toml
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*cosign(,|$)' "$GITHUB_OUTPUT"
}

@test "cosign-keyload: TOML cosign-variant WITHOUT env:// does NOT emit cosign" {
    _run_auto_detect $'[[binary_signs]]\ncmd = "cosign-fips"\nargs = ["sign-blob"]' Linux .anodizer.toml
    [ "$status" -eq 0 ]
    grep -q '^deps=' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*cosign(,|$)' "$GITHUB_OUTPUT"
}

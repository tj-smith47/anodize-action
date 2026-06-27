#!/usr/bin/env bats
# auto-detect-sbom-cmd.bats — unit tests for per-generator sbom tool detection
# in scripts/install/auto-detect-deps.sh (F3).
#
# anodizer's sbom generator is per-block (crates/stage-sbom/src/lib.rs +
# crates/core/src/config/sbom.rs):
#   - NO `cmd:` AND NO `args:`  → BUILTIN Cargo.lock generator
#     (`use_builtin = cmd.is_none() && args.is_none()`); shells out to nothing,
#     so NO external tool is installed.
#   - `cmd: <X>`                → anodizer spawns `<X>` verbatim
#     (`resolved_cmd()`); install THAT binary (e.g. syft, cyclonedx).
#   - `args:` present, no `cmd:` → `resolved_cmd()` falls back to default `syft`.
#
# Before F3 the probe emitted `syft` for ANY `sboms:` block, so a builtin
# config wrongly pulled syft and a `cmd: cyclonedx` config installed the wrong
# tool. This file pins the per-block contract.

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

# ── builtin (no cmd:, no args:) → NO external tool ───────────────────────────

@test "sbom-cmd: builtin sbom (no cmd/args) installs NO tool" {
    _run_auto_detect $'sboms:\n  - id: cargo'
    [ "$status" -eq 0 ]
    grep -q '^deps=' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*syft(,|$)' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*cyclonedx(,|$)' "$GITHUB_OUTPUT"
}

@test "sbom-cmd: builtin sbom with only documents: still installs NO tool" {
    _run_auto_detect $'sboms:\n  - documents: ["sbom.cdx.json"]'
    [ "$status" -eq 0 ]
    ! grep -qE '^deps=([^,]*,)*syft(,|$)' "$GITHUB_OUTPUT"
}

# ── cmd: syft → syft ─────────────────────────────────────────────────────────

@test "sbom-cmd: cmd: syft installs syft" {
    _run_auto_detect $'sboms:\n  - cmd: syft'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*syft(,|$)' "$GITHUB_OUTPUT"
}

# ── cmd: <other> → that tool, NOT syft ──────────────────────────────────────

@test "sbom-cmd: cmd: cyclonedx installs cyclonedx and NOT syft" {
    _run_auto_detect $'sboms:\n  - cmd: cyclonedx'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*cyclonedx(,|$)' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*syft(,|$)' "$GITHUB_OUTPUT"
}

# W4: a trailing ` # …` YAML inline comment must be stripped before trimming,
# or the dep name becomes `cyclonedx # comment` and never installs.
@test "sbom-cmd: cmd: cyclonedx with inline comment resolves to cyclonedx (comment stripped)" {
    _run_auto_detect $'sboms:\n  - cmd: cyclonedx # gen the sbom'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*cyclonedx(,|$)' "$GITHUB_OUTPUT"
    ! grep -q 'cyclonedx #' "$GITHUB_OUTPUT"
    ! grep -q 'comment' "$GITHUB_OUTPUT"
}

# W4 (TOML): the TOML `cmd = "X" # comment` form is equally comment-stripped.
@test "sbom-cmd: TOML cmd = cyclonedx with inline comment resolves to cyclonedx" {
    _run_auto_detect $'[[sboms]]\ncmd = "cyclonedx" # gen the sbom' Linux .anodizer.toml
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*cyclonedx(,|$)' "$GITHUB_OUTPUT"
    ! grep -q 'cyclonedx #' "$GITHUB_OUTPUT"
}

# S6: a FLOW-style sbom block (`sboms: [{cmd: cyclonedx}]`) is not parsed by the
# `- `-marker splitter, so it resolves to ZERO tools. Rather than silently
# installing nothing (→ runtime failure when the stage spawns its generator),
# fall back to the default generator syft so SOME generator is on PATH.
@test "sbom-cmd: flow-style sboms block falls back to syft (does not silently install nothing)" {
    _run_auto_detect $'sboms: [{cmd: cyclonedx}]'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*syft(,|$)' "$GITHUB_OUTPUT"
}

# ── args: present, no cmd: → default syft ────────────────────────────────────

@test "sbom-cmd: args: present with no cmd: falls back to syft" {
    _run_auto_detect $'sboms:\n  - args: ["scan", "."]'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*syft(,|$)' "$GITHUB_OUTPUT"
}

# ── multiple sbom entries → each distinct generator ──────────────────────────

@test "sbom-cmd: mixed builtin + cyclonedx emits only cyclonedx" {
    _run_auto_detect $'sboms:\n  - id: builtin\n  - cmd: cyclonedx'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*cyclonedx(,|$)' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*syft(,|$)' "$GITHUB_OUTPUT"
}

@test "sbom-cmd: syft + cyclonedx entries emit BOTH (deduped)" {
    _run_auto_detect $'sboms:\n  - cmd: syft\n  - cmd: cyclonedx'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*syft(,|$)' "$GITHUB_OUTPUT"
    grep -qE '^deps=([^,]*,)*cyclonedx(,|$)' "$GITHUB_OUTPUT"
}

# ── per-crate nested sboms ───────────────────────────────────────────────────

@test "sbom-cmd: nested (per-crate) cmd: cyclonedx installs cyclonedx" {
    _run_auto_detect $'crates:\n  - id: anodizer\n    sboms:\n      - cmd: cyclonedx'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*cyclonedx(,|$)' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*syft(,|$)' "$GITHUB_OUTPUT"
}

@test "sbom-cmd: nested (per-crate) builtin sbom installs NO tool" {
    _run_auto_detect $'crates:\n  - id: anodizer\n    sboms:\n      - id: cargo'
    [ "$status" -eq 0 ]
    ! grep -qE '^deps=([^,]*,)*syft(,|$)' "$GITHUB_OUTPUT"
}

# ── no sboms: block at all → nothing ─────────────────────────────────────────

@test "sbom-cmd: no sboms block emits no sbom tool" {
    _run_auto_detect $'upx: {}'
    [ "$status" -eq 0 ]
    ! grep -qE '^deps=([^,]*,)*syft(,|$)' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*cyclonedx(,|$)' "$GITHUB_OUTPUT"
}

# ── TOML shape ───────────────────────────────────────────────────────────────

@test "sbom-cmd: TOML [[sboms]] cmd = cyclonedx installs cyclonedx not syft" {
    _run_auto_detect $'[[sboms]]\ncmd = "cyclonedx"' Linux .anodizer.toml
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*cyclonedx(,|$)' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*syft(,|$)' "$GITHUB_OUTPUT"
}

@test "sbom-cmd: TOML [[sboms]] builtin (no cmd/args) installs NO tool" {
    _run_auto_detect $'[[sboms]]\nid = "cargo"' Linux .anodizer.toml
    [ "$status" -eq 0 ]
    ! grep -qE '^deps=([^,]*,)*syft(,|$)' "$GITHUB_OUTPUT"
}

@test "sbom-cmd: TOML [[sboms]] args only falls back to syft" {
    _run_auto_detect $'[[sboms]]\nargs = ["scan", "."]' Linux .anodizer.toml
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*syft(,|$)' "$GITHUB_OUTPUT"
}

@test "sbom-cmd: TOML nested [[crates.foo.sboms]] cmd = cyclonedx installs cyclonedx" {
    _run_auto_detect $'[[crates.foo.sboms]]\ncmd = "cyclonedx"' Linux .anodizer.toml
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*cyclonedx(,|$)' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*syft(,|$)' "$GITHUB_OUTPUT"
}

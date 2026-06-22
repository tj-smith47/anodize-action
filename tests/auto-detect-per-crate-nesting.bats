#!/usr/bin/env bats
# auto-detect-per-crate-nesting.bats — unit tests for nested (workspace
# per-crate) installer/packager block detection in
# scripts/install/auto-detect-deps.sh.
#
# anodizer's own config is a WORKSPACE PER-CRATE config: installer blocks
# (nsis, msis, pkgs, dmgs, nfpm, …) are declared NESTED under a `crates:`
# list entry, indented several spaces — not at column 0. The presence probe
# used to anchor every block at column 0 (`^nsis:` / `^msis:`), so these
# nested blocks were NEVER detected: makensis was never provisioned and the
# determinism shards hard-failed at the fail-loud installer gate
# ("installer stage(s) requested via --stages but their tool is not on PATH:
# nsis (needs makensis)") — sinking the v0.12.0 release.
#
# A block must be detected whether it sits top-level (single-crate flat
# config) OR nested under a crate entry (any leading indentation), and the
# OS gate must still compose (a nested Linux-only block on Windows/macOS is
# skipped, not provisioned).

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

# A workspace per-crate config: nsis nested under crates[].id.
_PERCRATE_NSIS=$'crates:\n  - id: anodizer\n    nsis:\n      - id: installer\n        script: setup.nsi'

# nsis nested under a crate entry, mixed with sibling blocks at the same depth.
_PERCRATE_MULTI=$'crates:\n  - id: anodizer\n    app_bundles:\n      - id: app\n    pkgs:\n      - id: p\n    nsis:\n      - id: installer'

# ── nsis (the exact v0.12.0 regression) ──────────────────────────────────────

@test "per-crate-nesting: nested nsis emits nsis on Windows (v0.12.0 regression)" {
    _run_auto_detect "$_PERCRATE_NSIS" Windows
    [ "$status" -eq 0 ]
    grep -qE '^deps=.*nsis' "$GITHUB_OUTPUT"
}

@test "per-crate-nesting: nested nsis emits nsis on Linux" {
    _run_auto_detect "$_PERCRATE_NSIS" Linux
    [ "$status" -eq 0 ]
    grep -qE '^deps=.*nsis' "$GITHUB_OUTPUT"
}

@test "per-crate-nesting: nested nsis alongside sibling blocks emits nsis + pkgbuild" {
    _run_auto_detect "$_PERCRATE_MULTI" Linux
    [ "$status" -eq 0 ]
    grep -qE '^deps=.*nsis' "$GITHUB_OUTPUT"
    grep -qE '^deps=.*pkgbuild' "$GITHUB_OUTPUT"
}

# ── nested msis → dialect-aware token ────────────────────────────────────────

@test "per-crate-nesting: nested msis with version v3 emits wix3 on Windows" {
    _run_auto_detect $'crates:\n  - id: anodizer\n    msis:\n      - version: v3' Windows
    [ "$status" -eq 0 ]
    grep -qE '^deps=.*wix3' "$GITHUB_OUTPUT"
}

@test "per-crate-nesting: nested msis with version v4 emits wix on Windows" {
    _run_auto_detect $'crates:\n  - id: anodizer\n    msis:\n      - version: v4' Windows
    [ "$status" -eq 0 ]
    grep -qE '^deps=.*wix' "$GITHUB_OUTPUT"
    # v4-only block must NOT pull the v3 toolchain.
    ! grep -qE '^deps=.*wix3' "$GITHUB_OUTPUT"
}

@test "per-crate-nesting: nested msis with no version defaults to wix on Windows" {
    _run_auto_detect $'crates:\n  - id: anodizer\n    msis:\n      - wxs: app.wxs' Windows
    [ "$status" -eq 0 ]
    grep -qE '^deps=.*wix' "$GITHUB_OUTPUT"
}

@test "per-crate-nesting: two crates with different msis dialects emit BOTH wix3 and wix" {
    _run_auto_detect $'crates:\n  - id: alpha\n    msis:\n      - version: v3\n  - id: beta\n    msis:\n      - version: v4' Windows
    [ "$status" -eq 0 ]
    grep -qE '^deps=.*wix3' "$GITHUB_OUTPUT"
    # The v4 crate must also pull the v4 toolchain (token `wix`, distinct from wix3).
    grep -qE '^deps=([^,]*,)*wix(,|$)' "$GITHUB_OUTPUT"
}

@test "per-crate-nesting: one crate with BOTH nsis and msis emits nsis + wix dialect" {
    _run_auto_detect $'crates:\n  - id: anodizer\n    nsis:\n      - id: installer\n    msis:\n      - version: v3' Windows
    [ "$status" -eq 0 ]
    grep -qE '^deps=.*nsis' "$GITHUB_OUTPUT"
    grep -qE '^deps=.*wix3' "$GITHUB_OUTPUT"
}

# ── OS gate composes with nested detection ───────────────────────────────────

@test "per-crate-nesting: nested nfpm is SKIPPED on Windows (OS gate composes)" {
    _run_auto_detect $'crates:\n  - id: anodizer\n    nfpm:\n      - package_name: probe' Windows
    [ "$status" -eq 0 ]
    ! grep -qE '^deps=.*nfpm' "$GITHUB_OUTPUT"
}

@test "per-crate-nesting: nested nfpm IS emitted on Linux" {
    _run_auto_detect $'crates:\n  - id: anodizer\n    nfpm:\n      - package_name: probe' Linux
    [ "$status" -eq 0 ]
    grep -qE '^deps=.*nfpm' "$GITHUB_OUTPUT"
}

# ── no regression: flat single-crate config still detects ────────────────────

@test "per-crate-nesting: top-level (flat) nsis still detected" {
    _run_auto_detect $'nsis:\n  - id: installer' Windows
    [ "$status" -eq 0 ]
    grep -qE '^deps=.*nsis' "$GITHUB_OUTPUT"
}

@test "per-crate-nesting: top-level (flat) msis still detected with dialect" {
    _run_auto_detect $'msis:\n  - version: v3' Windows
    [ "$status" -eq 0 ]
    grep -qE '^deps=.*wix3' "$GITHUB_OUTPUT"
}

# ── anchoring: a longer key must NOT match a shorter block key ────────────────

@test "per-crate-nesting: nested binary_signs (cmd gpg) does NOT pull cosign via signs match" {
    _run_auto_detect $'crates:\n  - id: anodizer\n    binary_signs:\n      - cmd: gpg' Linux
    [ "$status" -eq 0 ]
    ! grep -qE '^deps=.*cosign' "$GITHUB_OUTPUT"
}

@test "per-crate-nesting: cmd cosignx must NOT pull cosign (has_kv value anchored)" {
    _run_auto_detect $'crates:\n  - id: anodizer\n    binary_signs:\n      - cmd: cosignx' Linux
    [ "$status" -eq 0 ]
    ! grep -qE '^deps=([^,]*,)*cosign(,|$)' "$GITHUB_OUTPUT"
}

@test "per-crate-nesting: cmd cosign-foo must NOT pull cosign (has_kv value anchored)" {
    _run_auto_detect $'crates:\n  - id: anodizer\n    binary_signs:\n      - cmd: cosign-foo' Linux
    [ "$status" -eq 0 ]
    ! grep -qE '^deps=([^,]*,)*cosign(,|$)' "$GITHUB_OUTPUT"
}

@test "per-crate-nesting: cmd cosign (exact) still pulls cosign" {
    _run_auto_detect $'crates:\n  - id: anodizer\n    binary_signs:\n      - cmd: cosign' Linux
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*cosign(,|$)' "$GITHUB_OUTPUT"
}

# ── TOML workspace per-crate shape ───────────────────────────────────────────

@test "per-crate-nesting: TOML nested [[crates.anodizer.nsis]] emits nsis on Windows" {
    _run_auto_detect $'[[crates.anodizer.nsis]]\nid = "installer"' Windows .anodizer.toml
    [ "$status" -eq 0 ]
    grep -qE '^deps=.*nsis' "$GITHUB_OUTPUT"
}

@test "per-crate-nesting: TOML nested [[crates.anodizer.nfpm]] is SKIPPED on Windows" {
    _run_auto_detect $'[[crates.anodizer.nfpm]]\npackage_name = "probe"' Windows .anodizer.toml
    [ "$status" -eq 0 ]
    ! grep -qE '^deps=.*nfpm' "$GITHUB_OUTPUT"
}

@test "per-crate-nesting: TOML nested [[crates.foo.msis]] emits BOTH wix3 and wix (safe superset)" {
    _run_auto_detect $'[[crates.foo.msis]]\nversion = "v3"' Windows .anodizer.toml
    [ "$status" -eq 0 ]
    # The YAML dialect resolver can't read TOML, so both majors ship to
    # guarantee the v3 consumer's toolchain (candle+light) is on PATH.
    grep -qE '^deps=.*wix3' "$GITHUB_OUTPUT"
    grep -qE '^deps=([^,]*,)*wix(,|$)' "$GITHUB_OUTPUT"
}

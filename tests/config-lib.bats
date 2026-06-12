#!/usr/bin/env bats
# config-lib.bats — unit tests for scripts/lib/config.sh, the shared
# anodizer config discovery + dist-dir resolver sourced by outputs.sh,
# attest-subjects.sh, anodizer.sh, verify-split.sh, split-matrix.sh,
# auto-detect-deps.sh, and resolve-dist-dir.sh.
#
# Contract under test:
#  1. find_anodizer_config walks the SAME six candidates in the SAME
#     priority order as the binary (.anodizer.yaml, .anodizer.yml,
#     .anodizer.toml, anodizer.yaml, anodizer.yml, anodizer.toml) and
#     returns rc=1 echoing nothing when none exist.
#  2. anodizer_config_is_toml dispatches purely on the .toml extension.
#  3. anodizer_config_dist_value reads top-level `dist:` (YAML) /
#     `dist =` (TOML): quotes (single/double/none) stripped, surrounding
#     whitespace trimmed, trailing inline comments dropped; commented-out
#     and indented lines never match; missing key echoes nothing (rc=0).
#  4. resolve_dist_dir falls back to "dist" when the key or the whole
#     config is missing, and passes through relative AND absolute values.

load test_helper

setup() {
    common_setup
    WORKDIR="${_TEST_HOME}/workdir"
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"
}

teardown() {
    common_teardown
}

# Run a snippet inside the test workdir with the lib sourced.
_lib() {
    run bash -c "cd '${WORKDIR}' && source '${REPO_ROOT}/scripts/lib/config.sh' && $1"
}

_write() {
    printf '%s\n' "$2" > "${WORKDIR}/$1"
}

# ── find_anodizer_config: discovery order ────────────────────────────

@test "config-lib: all six candidates present -> .anodizer.yaml wins" {
    for f in .anodizer.yaml .anodizer.yml .anodizer.toml anodizer.yaml anodizer.yml anodizer.toml; do
        _write "$f" 'dist: x'
    done
    _lib find_anodizer_config
    [ "$status" -eq 0 ]
    [ "$output" = ".anodizer.yaml" ]
}

@test "config-lib: without .anodizer.yaml -> .anodizer.yml wins" {
    for f in .anodizer.yml .anodizer.toml anodizer.yaml anodizer.yml anodizer.toml; do
        _write "$f" 'dist: x'
    done
    _lib find_anodizer_config
    [ "$status" -eq 0 ]
    [ "$output" = ".anodizer.yml" ]
}

@test "config-lib: dotted TOML outranks un-dotted YAML (binary order)" {
    for f in .anodizer.toml anodizer.yaml anodizer.yml anodizer.toml; do
        _write "$f" 'dist = "x"'
    done
    _lib find_anodizer_config
    [ "$status" -eq 0 ]
    [ "$output" = ".anodizer.toml" ]
}

@test "config-lib: un-dotted candidates keep yaml > yml > toml order" {
    for f in anodizer.yaml anodizer.yml anodizer.toml; do
        _write "$f" 'dist: x'
    done
    _lib find_anodizer_config
    [ "$status" -eq 0 ]
    [ "$output" = "anodizer.yaml" ]

    rm "${WORKDIR}/anodizer.yaml"
    _lib find_anodizer_config
    [ "$status" -eq 0 ]
    [ "$output" = "anodizer.yml" ]

    rm "${WORKDIR}/anodizer.yml"
    _lib find_anodizer_config
    [ "$status" -eq 0 ]
    [ "$output" = "anodizer.toml" ]
}

@test "config-lib: no config -> rc=1, echoes nothing" {
    _lib find_anodizer_config
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# ── anodizer_config_is_toml ──────────────────────────────────────────

@test "config-lib: is_toml true for both TOML candidates" {
    _lib 'anodizer_config_is_toml .anodizer.toml'
    [ "$status" -eq 0 ]
    _lib 'anodizer_config_is_toml anodizer.toml'
    [ "$status" -eq 0 ]
}

@test "config-lib: is_toml false for YAML candidates" {
    _lib 'anodizer_config_is_toml .anodizer.yaml'
    [ "$status" -eq 1 ]
    _lib 'anodizer_config_is_toml .anodizer.yml'
    [ "$status" -eq 1 ]
}

# ── anodizer_config_dist_value: YAML shapes ──────────────────────────

@test "config-lib: YAML unquoted dist value" {
    _write .anodizer.yaml 'dist: build-out'
    _lib 'anodizer_config_dist_value .anodizer.yaml'
    [ "$status" -eq 0 ]
    [ "$output" = "build-out" ]
}

@test "config-lib: YAML double-quoted dist value" {
    _write .anodizer.yaml 'dist: "build-out"'
    _lib 'anodizer_config_dist_value .anodizer.yaml'
    [ "$status" -eq 0 ]
    [ "$output" = "build-out" ]
}

@test "config-lib: YAML single-quoted dist value" {
    _write .anodizer.yaml "dist: 'build-out'"
    _lib 'anodizer_config_dist_value .anodizer.yaml'
    [ "$status" -eq 0 ]
    [ "$output" = "build-out" ]
}

@test "config-lib: YAML extra whitespace around dist value" {
    _write .anodizer.yaml 'dist:     build-out   '
    _lib 'anodizer_config_dist_value .anodizer.yaml'
    [ "$status" -eq 0 ]
    [ "$output" = "build-out" ]
}

@test "config-lib: YAML trailing inline comment stripped" {
    _write .anodizer.yaml 'dist: build-out # the output tree'
    _lib 'anodizer_config_dist_value .anodizer.yaml'
    [ "$status" -eq 0 ]
    [ "$output" = "build-out" ]
}

@test "config-lib: YAML commented-out dist line does NOT match" {
    _write .anodizer.yaml $'# dist: nope\nproject_name: x'
    _lib 'anodizer_config_dist_value .anodizer.yaml'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "config-lib: YAML indented (non-top-level) dist does NOT match" {
    _write .anodizer.yaml $'archives:\n  dist: nope'
    _lib 'anodizer_config_dist_value .anodizer.yaml'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "config-lib: YAML missing dist key echoes nothing (rc=0)" {
    _write .anodizer.yaml 'project_name: x'
    _lib 'anodizer_config_dist_value .anodizer.yaml'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── anodizer_config_dist_value: TOML shapes ──────────────────────────

@test "config-lib: TOML double-quoted dist value" {
    _write .anodizer.toml 'dist = "out-toml"'
    _lib 'anodizer_config_dist_value .anodizer.toml'
    [ "$status" -eq 0 ]
    [ "$output" = "out-toml" ]
}

@test "config-lib: TOML single-quoted (literal string) dist value" {
    _write .anodizer.toml "dist = 'out-toml'"
    _lib 'anodizer_config_dist_value .anodizer.toml'
    [ "$status" -eq 0 ]
    [ "$output" = "out-toml" ]
}

@test "config-lib: TOML extra whitespace around = and value" {
    _write .anodizer.toml 'dist   =    "out-toml"   '
    _lib 'anodizer_config_dist_value .anodizer.toml'
    [ "$status" -eq 0 ]
    [ "$output" = "out-toml" ]
}

@test "config-lib: TOML trailing inline comment stripped" {
    _write .anodizer.toml 'dist = "out-toml" # comment'
    _lib 'anodizer_config_dist_value .anodizer.toml'
    [ "$status" -eq 0 ]
    [ "$output" = "out-toml" ]
}

@test "config-lib: TOML commented-out dist line does NOT match" {
    _write .anodizer.toml $'# dist = "nope"\nproject_name = "x"'
    _lib 'anodizer_config_dist_value .anodizer.toml'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "config-lib: TOML dist inside a table does NOT match" {
    _write .anodizer.toml $'project_name = "x"\n[archives]\ndist = "nope"'
    _lib 'anodizer_config_dist_value .anodizer.toml'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "config-lib: TOML top-level dist before tables still matches" {
    _write .anodizer.toml $'dist = "out-toml"\n[archives]\ndist = "nope"'
    _lib 'anodizer_config_dist_value .anodizer.toml'
    [ "$status" -eq 0 ]
    [ "$output" = "out-toml" ]
}

@test "config-lib: TOML missing dist key echoes nothing (rc=0)" {
    _write .anodizer.toml 'project_name = "x"'
    _lib 'anodizer_config_dist_value .anodizer.toml'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── resolve_dist_dir ─────────────────────────────────────────────────

@test "config-lib: resolve falls back to dist when key missing" {
    _write .anodizer.yaml 'project_name: x'
    _lib resolve_dist_dir
    [ "$status" -eq 0 ]
    [ "$output" = "dist" ]
}

@test "config-lib: resolve falls back to dist when no config exists" {
    _lib resolve_dist_dir
    [ "$status" -eq 0 ]
    [ "$output" = "dist" ]
}

@test "config-lib: resolve returns relative YAML dist value" {
    _write .anodizer.yaml 'dist: build/out'
    _lib resolve_dist_dir
    [ "$status" -eq 0 ]
    [ "$output" = "build/out" ]
}

@test "config-lib: resolve returns absolute dist path untouched" {
    _write .anodizer.yaml 'dist: /abs/dist-tree'
    _lib resolve_dist_dir
    [ "$status" -eq 0 ]
    [ "$output" = "/abs/dist-tree" ]
}

@test "config-lib: resolve reads TOML dist value" {
    _write .anodizer.toml 'dist = "out-toml"'
    _lib resolve_dist_dir
    [ "$status" -eq 0 ]
    [ "$output" = "out-toml" ]
}

@test "config-lib: resolve honors discovery order (.anodizer.yaml over TOML)" {
    _write .anodizer.yaml 'dist: from-yaml'
    _write .anodizer.toml 'dist = "from-toml"'
    _lib resolve_dist_dir
    [ "$status" -eq 0 ]
    [ "$output" = "from-yaml" ]
}

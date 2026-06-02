#!/usr/bin/env bats
# attest-subjects.bats — tests for scripts/run/attest-subjects.sh, which
# flattens anodizer's attestation subjects manifest(s) into a sha256sum-format
# checksums file for actions/attest-build-provenance's `subject-checksums`.
#
# Contract under test:
#  1. One manifest                  → `<hex>  <name>` lines (two-space sha256sum
#                                     format), `count` + absolute `checksums` path.
#  2. No manifest                   → checksums output empty, count 0, exit 0 (the
#                                     attest step gates itself off).
#  3. dist/ present but no manifest  → same gate-off behavior.
#  4. Multiple (crate-prefixed) manifests → merged into one file.
#  5. Duplicate subject across manifests  → de-duplicated (sort -u).
#
# These run the REAL script in a throwaway workdir so the test tracks
# production behavior, not a copied snippet.

load test_helper

# 64-hex-char digests (length is what the attest action keys sha256 on).
SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
SHA_C="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

# Write a subjects manifest ([{name,digest.sha256}] array) from name=sha pairs.
_write_manifest() {
    local file="$1"; shift
    {
        printf '[\n'
        local first=1 pair name sha
        for pair in "$@"; do
            name="${pair%%=*}"; sha="${pair#*=}"
            [ "$first" -eq 1 ] || printf ',\n'
            first=0
            printf '  { "name": "%s", "digest": { "sha256": "%s" } }' "$name" "$sha"
        done
        printf '\n]\n'
    } > "$file"
}

# Run the real script in $1 (a workdir holding dist/); echo GITHUB_OUTPUT.
_run_attest() {
    local workdir="$1"
    local github_output="${_TEST_HOME}/github-output"
    : > "$github_output"
    (
        cd "$workdir"
        GITHUB_OUTPUT="$github_output" \
            bash "${BATS_TEST_DIRNAME}/../scripts/run/attest-subjects.sh"
    )
    cat "$github_output"
}

_field() { grep "^$1=" | tail -1 | cut -d= -f2-; }

@test "single manifest: subjects flattened to two-space sha256sum format" {
    local wd="${_TEST_HOME}/repo"; mkdir -p "$wd/dist"
    _write_manifest "$wd/dist/attestation-subjects.json" \
        "app-1.0.tar.gz=$SHA_A" "checksums.txt=$SHA_B"

    out="$(_run_attest "$wd")"
    [ "$(printf '%s' "$out" | _field count)" = '2' ]

    local cks; cks="$(printf '%s' "$out" | _field checksums)"
    # Absolute path so the attest step (run at $GITHUB_WORKSPACE) can resolve it.
    [ "$cks" = "$wd/dist/attestation-subjects.sha256" ]
    # Exact `sha256sum` shape: digest, two spaces, name.
    grep -qx "$SHA_A  app-1.0.tar.gz" "$cks"
    grep -qx "$SHA_B  checksums.txt" "$cks"
    [ "$(wc -l < "$cks" | tr -d ' ')" = '2' ]
}

@test "no manifest: checksums output empty, count 0, exit 0 (gate-off)" {
    local wd="${_TEST_HOME}/repo"; mkdir -p "$wd/dist"

    run _run_attest "$wd"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | _field checksums)" = '' ]
    [ "$(printf '%s' "$output" | _field count)" = '0' ]
    [ ! -f "$wd/dist/attestation-subjects.sha256" ]
}

@test "dist present but no subjects manifest: still gates off" {
    local wd="${_TEST_HOME}/repo"; mkdir -p "$wd/dist"
    : > "$wd/dist/checksums.txt"  # unrelated dist content

    out="$(_run_attest "$wd")"
    [ "$(printf '%s' "$out" | _field checksums)" = '' ]
    [ "$(printf '%s' "$out" | _field count)" = '0' ]
}

@test "multiple crate-prefixed manifests are merged" {
    local wd="${_TEST_HOME}/repo"; mkdir -p "$wd/dist"
    _write_manifest "$wd/dist/core.attestation-subjects.json" "core.crate=$SHA_A"
    _write_manifest "$wd/dist/cli.attestation-subjects.json" \
        "cli.tar.gz=$SHA_B" "cli.tar.gz.sha256=$SHA_C"

    out="$(_run_attest "$wd")"
    [ "$(printf '%s' "$out" | _field count)" = '3' ]

    local cks; cks="$(printf '%s' "$out" | _field checksums)"
    grep -qx "$SHA_A  core.crate" "$cks"
    grep -qx "$SHA_B  cli.tar.gz" "$cks"
    grep -qx "$SHA_C  cli.tar.gz.sha256" "$cks"
}

@test "duplicate subject across manifests is de-duplicated" {
    local wd="${_TEST_HOME}/repo"; mkdir -p "$wd/dist"
    _write_manifest "$wd/dist/a.attestation-subjects.json" "shared.tar.gz=$SHA_A"
    _write_manifest "$wd/dist/b.attestation-subjects.json" \
        "shared.tar.gz=$SHA_A" "other.tar.gz=$SHA_B"

    out="$(_run_attest "$wd")"
    # shared.tar.gz appears in both manifests but is counted once.
    [ "$(printf '%s' "$out" | _field count)" = '2' ]
    local cks; cks="$(printf '%s' "$out" | _field checksums)"
    [ "$(grep -c "shared.tar.gz" "$cks")" = '1' ]
}

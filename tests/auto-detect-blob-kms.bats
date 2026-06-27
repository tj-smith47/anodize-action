#!/usr/bin/env bats
# auto-detect-blob-kms.bats — unit tests for blob KMS cloud-CLI detection in
# scripts/install/auto-detect-deps.sh (F5).
#
# A `blobs:` target with a `kms_key:` whose value carries a URL scheme drives
# CLIENT-SIDE KMS encryption, which shells out to a cloud CLI before upload
# (crates/stage-blob/src/kms.rs: parse_kms_provider + kms_cli_program):
#   - `awskms://…`        → aws
#   - `gcpkms://…`        → gcloud
#   - `azurekeyvault://…` → az
# A plain key ARN/ID with NO scheme means SERVER-SIDE SSE-KMS (S3 encrypts), so
# no CLI is provisioned. The cloud CLI runs on any runner OS (no OS guard).

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

# ── scheme → CLI ─────────────────────────────────────────────────────────────

@test "blob-kms: awskms:// emits aws" {
    _run_auto_detect $'blobs:\n  - provider: s3\n    bucket: b\n    kms_key: awskms://my-key-id'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*aws(,|$)' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*gcloud(,|$)' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*az(,|$)' "$GITHUB_OUTPUT"
}

@test "blob-kms: gcpkms:// emits gcloud" {
    _run_auto_detect $'blobs:\n  - provider: gs\n    bucket: b\n    kms_key: gcpkms://projects/p/locations/l/keyRings/r/cryptoKeys/k'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*gcloud(,|$)' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*aws(,|$)' "$GITHUB_OUTPUT"
}

@test "blob-kms: azurekeyvault:// emits az" {
    _run_auto_detect $'blobs:\n  - provider: azblob\n    bucket: b\n    kms_key: azurekeyvault://vault/keys/k'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*az(,|$)' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*aws(,|$)' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*gcloud(,|$)' "$GITHUB_OUTPUT"
}

@test "blob-kms: quoted kms_key value still resolves scheme" {
    _run_auto_detect $'blobs:\n  - provider: s3\n    bucket: b\n    kms_key: "awskms://my-key-id"'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*aws(,|$)' "$GITHUB_OUTPUT"
}

# B2/W3: a SINGLE-quoted kms_key scalar is valid YAML and must resolve its
# scheme too — has_kv accepts either quote.
@test "blob-kms: single-quoted kms_key value still resolves scheme" {
    _run_auto_detect $'blobs:\n  - provider: s3\n    bucket: b\n    kms_key: \'awskms://my-key-id\''
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*aws(,|$)' "$GITHUB_OUTPUT"
}

# ── plain ARN (no scheme) → server-side, NO CLI ──────────────────────────────

@test "blob-kms: plain ARN (server-side SSE-KMS) emits no cloud CLI" {
    _run_auto_detect $'blobs:\n  - provider: s3\n    bucket: b\n    kms_key: arn:aws:kms:us-east-1:111122223333:key/abc'
    [ "$status" -eq 0 ]
    grep -q '^deps=' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*aws(,|$)' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*gcloud(,|$)' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*az(,|$)' "$GITHUB_OUTPUT"
}

@test "blob-kms: blobs with no kms_key emits no cloud CLI" {
    _run_auto_detect $'blobs:\n  - provider: s3\n    bucket: b'
    [ "$status" -eq 0 ]
    ! grep -qE '^deps=([^,]*,)*aws(,|$)' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*gcloud(,|$)' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*az(,|$)' "$GITHUB_OUTPUT"
}

@test "blob-kms: no blobs block at all emits no cloud CLI" {
    _run_auto_detect $'upx: {}'
    [ "$status" -eq 0 ]
    ! grep -qE '^deps=([^,]*,)*aws(,|$)' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*gcloud(,|$)' "$GITHUB_OUTPUT"
    ! grep -qE '^deps=([^,]*,)*az(,|$)' "$GITHUB_OUTPUT"
}

# ── multiple blob targets, different schemes ─────────────────────────────────

@test "blob-kms: two targets with aws + gcp schemes emit both clis" {
    _run_auto_detect $'blobs:\n  - provider: s3\n    bucket: a\n    kms_key: awskms://k1\n  - provider: gs\n    bucket: b\n    kms_key: gcpkms://projects/p/k'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*aws(,|$)' "$GITHUB_OUTPUT"
    grep -qE '^deps=([^,]*,)*gcloud(,|$)' "$GITHUB_OUTPUT"
}

# ── per-crate nested blobs ───────────────────────────────────────────────────

@test "blob-kms: nested (per-crate) awskms:// emits aws" {
    _run_auto_detect $'crates:\n  - id: anodizer\n    blobs:\n      - provider: s3\n        bucket: b\n        kms_key: awskms://k'
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*aws(,|$)' "$GITHUB_OUTPUT"
}

# ── TOML shape ───────────────────────────────────────────────────────────────

@test "blob-kms: TOML [[blobs]] awskms:// emits aws" {
    _run_auto_detect $'[[blobs]]\nprovider = "s3"\nbucket = "b"\nkms_key = "awskms://my-key-id"' Linux .anodizer.toml
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*aws(,|$)' "$GITHUB_OUTPUT"
}

@test "blob-kms: TOML [[blobs]] gcpkms:// emits gcloud" {
    _run_auto_detect $'[[blobs]]\nprovider = "gs"\nbucket = "b"\nkms_key = "gcpkms://projects/p/k"' Linux .anodizer.toml
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*gcloud(,|$)' "$GITHUB_OUTPUT"
}

@test "blob-kms: TOML [[blobs]] plain ARN emits no cloud CLI" {
    _run_auto_detect $'[[blobs]]\nprovider = "s3"\nbucket = "b"\nkms_key = "arn:aws:kms:us:1:key/x"' Linux .anodizer.toml
    [ "$status" -eq 0 ]
    ! grep -qE '^deps=([^,]*,)*aws(,|$)' "$GITHUB_OUTPUT"
}

@test "blob-kms: TOML nested [[crates.foo.blobs]] azurekeyvault:// emits az" {
    _run_auto_detect $'[[crates.foo.blobs]]\nprovider = "azblob"\nbucket = "b"\nkms_key = "azurekeyvault://v/keys/k"' Linux .anodizer.toml
    [ "$status" -eq 0 ]
    grep -qE '^deps=([^,]*,)*az(,|$)' "$GITHUB_OUTPUT"
}

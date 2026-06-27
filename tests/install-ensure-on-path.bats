#!/usr/bin/env bats
# install-ensure-on-path.bats — unit tests for the ensure-on-PATH dispatch
# route in scripts/install/deps.sh.
#
# Environment-provided externals — the cloud KMS CLIs (aws/gcloud/az, emitted
# by auto-detect from a `blobs.kms_key:` URL scheme) and an arbitrary
# `sboms.cmd:` generator binary (e.g. cyclonedx) — have no anodizer-bundled
# installer. They are expected on the runner image. The dispatcher routes them
# to `ensure_on_path`:
#   - present on PATH → success no-op (the stage will spawn the tool)
#   - absent          → `gha_fail` with an ACTIONABLE message naming the config
#                       field that demanded the tool (never the opaque
#                       "Unknown dependency", never a silent skip).
# syft (the default/auto-installable SBOM generator) keeps its real installer;
# cosign/nfpm and the rest dispatch unchanged.

load test_helper

setup() {
    common_setup

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    export GITHUB_PATH="${_TEST_HOME}/github_path"
    : > "$GITHUB_PATH"
    export GITHUB_OUTPUT="${_TEST_HOME}/github_output"
    : > "$GITHUB_OUTPUT"
}

teardown() {
    common_teardown
}

# Source deps.sh, override the real installer helpers with logging stubs (so a
# dispatch test never touches the network), then run dispatch_install over the
# requested dep list. `$1` is a comma-free, space-separated dep list.
_run_dispatch() {
    local deps="$1" runner_os="${2:-Linux}"
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        GITHUB_OUTPUT="${GITHUB_OUTPUT}" \
        RUNNER_OS="$runner_os" \
        NO_COLOR=1 \
        ANODIZER_VERBOSE=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        DISPATCH_DEPS="$deps" \
        DISPATCH_LOG="${_TEST_HOME}/dispatch.log" \
        bash -c '
            source "${GITHUB_ACTION_PATH}/scripts/install/deps.sh"
            # Replace real installers with stubs that log the call, so the
            # dispatch routing is observable without installing anything.
            for fn in install_cosign install_syft install_nfpm install_upx; do
                eval "${fn}() { echo \"${fn}\" >> \"\$DISPATCH_LOG\"; }"
            done
            read -r -a DEPS <<< "$DISPATCH_DEPS"
            dispatch_install
        '
}

# Same as _run_dispatch but forces the on-PATH probe to report ABSENT, so a
# tool genuinely installed on the dev box / CI image (e.g. gcloud) can't leak
# in and make an "absent" assertion falsely pass. Overriding `_tool_on_path`
# (the single probe seam, mirroring `_squashfs_tools_available`) keeps the full
# PATH for the sourced libs while making the absence deterministic.
_run_dispatch_absent() {
    local deps="$1" runner_os="${2:-Linux}"
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        GITHUB_OUTPUT="${GITHUB_OUTPUT}" \
        RUNNER_OS="$runner_os" \
        NO_COLOR=1 \
        ANODIZER_VERBOSE=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        DISPATCH_DEPS="$deps" \
        DISPATCH_LOG="${_TEST_HOME}/dispatch.log" \
        bash -c '
            source "${GITHUB_ACTION_PATH}/scripts/install/deps.sh"
            _tool_on_path() { return 1; }
            read -r -a DEPS <<< "$DISPATCH_DEPS"
            dispatch_install
        '
}

# Drop a fake executable named $1 into FAKE_BIN so _tool_on_path finds it.
_provide_tool() {
    printf '#!/usr/bin/env bash\nexit 0\n' > "${FAKE_BIN}/$1"
    chmod +x "${FAKE_BIN}/$1"
}

# ── cloud KMS CLIs: present → no-op ──────────────────────────────────────────

@test "ensure-on-path: aws present dispatches as a no-op (exit 0)" {
    _provide_tool aws
    _run_dispatch "aws"
    [ "$status" -eq 0 ]
    [[ "$output" == *"aws already on PATH"* ]]
    [[ "$output" == *"awskms://"* ]]
}

@test "ensure-on-path: gcloud present dispatches as a no-op (exit 0)" {
    _provide_tool gcloud
    _run_dispatch "gcloud"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gcloud already on PATH"* ]]
    [[ "$output" == *"gcpkms://"* ]]
}

@test "ensure-on-path: az present dispatches as a no-op (exit 0)" {
    _provide_tool az
    _run_dispatch "az"
    [ "$status" -eq 0 ]
    [[ "$output" == *"az already on PATH"* ]]
    [[ "$output" == *"azurekeyvault://"* ]]
}

# ── cloud KMS CLIs: absent → actionable fail (not "Unknown dependency") ──────

@test "ensure-on-path: aws absent fails with an actionable kms message" {
    _run_dispatch_absent "aws"
    [ "$status" -ne 0 ]
    [[ "$output" == *"aws required by blobs.kms_key (awskms://) but not on PATH"* ]]
    [[ "$output" == *"install it on the runner"* ]]
    # The old opaque error must NOT appear.
    [[ "$output" != *"Unknown dependency"* ]]
}

@test "ensure-on-path: gcloud absent fails with an actionable kms message" {
    _run_dispatch_absent "gcloud"
    [ "$status" -ne 0 ]
    [[ "$output" == *"gcloud required by blobs.kms_key (gcpkms://) but not on PATH"* ]]
    [[ "$output" != *"Unknown dependency"* ]]
}

@test "ensure-on-path: az absent fails with an actionable kms message" {
    _run_dispatch_absent "az"
    [ "$status" -ne 0 ]
    [[ "$output" == *"az required by blobs.kms_key (azurekeyvault://) but not on PATH"* ]]
    [[ "$output" != *"Unknown dependency"* ]]
}

# ── arbitrary sboms.cmd generator (catch-all) ────────────────────────────────

@test "ensure-on-path: non-syft sbom cmd present dispatches as a no-op" {
    _provide_tool cyclonedx
    _run_dispatch "cyclonedx"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cyclonedx already on PATH"* ]]
    [[ "$output" == *"sboms.cmd"* ]]
}

@test "ensure-on-path: non-syft sbom cmd absent fails with an actionable sbom message" {
    _run_dispatch_absent "cyclonedx"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cyclonedx required by sboms.cmd but not on PATH"* ]]
    [[ "$output" == *"install it on the runner"* ]]
    [[ "$output" != *"Unknown dependency"* ]]
}

# ── regression: known installers still dispatch to their real handler ────────

@test "ensure-on-path: cosign still routes to install_cosign (not ensure-on-path)" {
    _run_dispatch "cosign"
    [ "$status" -eq 0 ]
    grep -q '^install_cosign$' "${_TEST_HOME}/dispatch.log"
    [[ "$output" != *"already on PATH"* ]]
}

@test "ensure-on-path: syft still routes to install_syft (the default generator)" {
    _run_dispatch "syft"
    [ "$status" -eq 0 ]
    grep -q '^install_syft$' "${_TEST_HOME}/dispatch.log"
    # syft must NOT fall through to ensure-on-path even when absent from PATH.
    [[ "$output" != *"required by sboms.cmd"* ]]
}

@test "ensure-on-path: nfpm still routes to install_nfpm" {
    _run_dispatch "nfpm"
    [ "$status" -eq 0 ]
    grep -q '^install_nfpm$' "${_TEST_HOME}/dispatch.log"
}

# ── mixed list: a real installer + an ensure-on-path external coexist ─────────

@test "ensure-on-path: syft + present cyclonedx both succeed in one dispatch" {
    _provide_tool cyclonedx
    _run_dispatch "syft cyclonedx"
    [ "$status" -eq 0 ]
    grep -q '^install_syft$' "${_TEST_HOME}/dispatch.log"
    [[ "$output" == *"cyclonedx already on PATH"* ]]
}

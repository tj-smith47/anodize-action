#!/usr/bin/env bats
# install-nfpm.bats — unit tests for the nfpm installer in
# scripts/install/deps.sh.
#
# nfpm drives anodizer's deb/rpm/apk publishers. On Linux it installs via a
# direct, checksum-verified GitHub-release download (mirroring cosign/syft) so
# no third-party apt repo and no extra `apt-get update` are introduced; macOS
# uses the goreleaser brew tap and Windows uses choco.
#
# Stubs curl, sha256sum, tar, brew, and choco so no network or root is needed.
# Covers:
#
#   1. Linux x86_64 → tarball + checksums.txt fetched, sha verified against
#      checksums.txt, nfpm extracted onto PATH, exits 0
#   2. Linux arm64  → the asymmetric arch name (arm64, not aarch64) is used
#   3. NFPM_VERSION override → forwarded into the download URL + tarball name
#   4. macOS  → goreleaser/tap/nfpm via brew
#   5. Windows → choco install nfpm

load test_helper

setup() {
    common_setup

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    export GITHUB_PATH="${_TEST_HOME}/github_path"
    : > "$GITHUB_PATH"
    export RUNNER_TEMP="${_TEST_HOME}/runner-temp"
    mkdir -p "$RUNNER_TEMP"

    CURL_LOG="${_TEST_HOME}/curl.log"

    # ── Stub: curl — log the request, write a deterministic checksums.txt
    #    (matching whatever tarball was last requested) or placeholder bytes. ──
    cat > "${FAKE_BIN}/curl" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "${CURL_LOG}"
out="" url=""
for arg; do
    case "\$prev" in -o) out="\$arg" ;; esac
    case "\$arg" in https://*) url="\$arg" ;; esac
    prev="\$arg"
done
[ -n "\$out" ] || exit 0
case "\$url" in
    *checksums.txt)
        # The installer greps for "<sha>  <tarball>"; emit a line whose
        # filename matches the tarball asset for this version/arch.
        tb=\$(basename "\$(dirname "\$url")")  # unused; keep grep stable below
        printf 'feedface  %s\n' "\${NFPM_EXPECT_TARBALL}" > "\$out"
        ;;
    *)
        printf 'nfpm-bin' > "\$out"
        ;;
esac
exit 0
STUB
    chmod +x "${FAKE_BIN}/curl"

    # ── Stub: sha256sum -c reads "HASH  FILE" from stdin and returns 0 ───
    cat > "${FAKE_BIN}/sha256sum" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"-c"* ]]; then
    read -r line
    echo "${line##* }": OK
    exit 0
fi
exit 1
STUB
    chmod +x "${FAKE_BIN}/sha256sum"

    # ── Stub: tar — materialize the extracted `nfpm` binary in -C dir ─────
    cat > "${FAKE_BIN}/tar" <<'STUB'
#!/usr/bin/env bash
dir=""
for arg; do
    case "$prev" in -C) dir="$arg" ;; esac
    prev="$arg"
done
[ -n "$dir" ] && printf 'nfpm-bin' > "${dir}/nfpm"
exit 0
STUB
    chmod +x "${FAKE_BIN}/tar"

    # ── Stub: brew / choco — record the invocation to a log AND echo it.
    #    The installer wraps these in anodizer::run_quiet, which swallows
    #    stdout on success, so assert on the log file (a side-effect
    #    run_quiet cannot suppress), not on captured output. ─
    export BREW_LOG="${_TEST_HOME}/brew.log"
    export CHOCO_LOG="${_TEST_HOME}/choco.log"
    cat > "${FAKE_BIN}/brew" <<'STUB'
#!/usr/bin/env bash
echo "brew $*" >> "$BREW_LOG"
echo "brew $*"
exit 0
STUB
    chmod +x "${FAKE_BIN}/brew"
    cat > "${FAKE_BIN}/choco" <<'STUB'
#!/usr/bin/env bash
echo "choco $*" >> "$CHOCO_LOG"
echo "choco $*"
exit 0
STUB
    chmod +x "${FAKE_BIN}/choco"
}

teardown() {
    common_teardown
}

_run_install_nfpm() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        GITHUB_PATH="${GITHUB_PATH}" \
        RUNNER_TEMP="${RUNNER_TEMP}" \
        CURL_LOG="${CURL_LOG}" \
        BREW_LOG="${BREW_LOG}" \
        CHOCO_LOG="${CHOCO_LOG}" \
        NO_COLOR=1 \
        PATH="${FAKE_BIN}:${PATH}" \
        "$@" \
        bash -c "
            source '${REPO_ROOT}/scripts/install/deps.sh'
            install_nfpm
        "
}

# ── Test 1: Linux x86_64 → direct download + checksum verify, on PATH ──────

@test "nfpm: Linux x86_64 downloads + checksum-verifies + installs onto PATH" {
    _run_install_nfpm RUNNER_OS="Linux" RUNNER_ARCH="X64" \
        NFPM_EXPECT_TARBALL="nfpm_2.46.3_Linux_x86_64.tar.gz"
    [ "$status" -eq 0 ]
    # The pinned-version x86_64 tarball + the release checksums.txt were fetched.
    grep -q 'nfpm_2.46.3_Linux_x86_64.tar.gz' "$CURL_LOG"
    grep -q 'checksums.txt' "$CURL_LOG"
    # No apt repo / apt-get is involved (the whole point of the change).
    [[ "$output" != *"apt-get"* ]]
    # The binary landed and its dir was added to PATH.
    [ -x "${RUNNER_TEMP}/nfpm/nfpm" ]
    grep -q "${RUNNER_TEMP}/nfpm" "$GITHUB_PATH"
    [[ "$output" == *"nfpm 2.46.3"* ]]
}

# ── Test 2: Linux arm64 → asymmetric arch name (arm64, not aarch64) ────────

@test "nfpm: Linux arm64 uses the arm64 asset name" {
    _run_install_nfpm RUNNER_OS="Linux" RUNNER_ARCH="ARM64" \
        NFPM_EXPECT_TARBALL="nfpm_2.46.3_Linux_arm64.tar.gz"
    [ "$status" -eq 0 ]
    # Positive: the arm64 asset was fetched. Negative: aarch64 appears NOWHERE
    # in the request log (nfpm's Linux asset is named arm64, not aarch64). A
    # bare `grep -qv` here would be a tautology — the checksums.txt request line
    # never contains "aarch64", so it would pass even if the tarball line did.
    grep -q 'nfpm_2.46.3_Linux_arm64.tar.gz' "$CURL_LOG"
    ! grep -q 'aarch64' "$CURL_LOG"
}

# ── Test 3: NFPM_VERSION override flows into the URL + tarball name ────────

@test "nfpm: NFPM_VERSION override is used for the download" {
    _run_install_nfpm RUNNER_OS="Linux" RUNNER_ARCH="X64" \
        NFPM_VERSION="2.40.0" \
        NFPM_EXPECT_TARBALL="nfpm_2.40.0_Linux_x86_64.tar.gz"
    [ "$status" -eq 0 ]
    grep -q 'releases/download/v2.40.0/' "$CURL_LOG"
    grep -q 'nfpm_2.40.0_Linux_x86_64.tar.gz' "$CURL_LOG"
}

# ── Test 4: macOS → goreleaser tap via brew ───────────────────────────────

@test "nfpm: macOS installs via the goreleaser brew tap" {
    _run_install_nfpm RUNNER_OS="macOS" RUNNER_ARCH="ARM64"
    [ "$status" -eq 0 ]
    grep -q "brew install goreleaser/tap/nfpm" "$BREW_LOG"
}

# ── Test 5: Windows → choco ───────────────────────────────────────────────

@test "nfpm: Windows installs via choco" {
    _run_install_nfpm RUNNER_OS="Windows" RUNNER_ARCH="X64"
    [ "$status" -eq 0 ]
    grep -q "choco install nfpm" "$CHOCO_LOG"
}

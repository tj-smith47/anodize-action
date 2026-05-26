#!/usr/bin/env bats
# from-branch.bats — tests for the from-branch install path.
#
# Covers:
#   1. Mutual exclusion: version + from-branch → validation step fires
#   2. Mutual exclusion: from-source + from-branch → validation step fires
#   3. Mutual exclusion: from-artifact + from-branch → validation step fires
#   4. Happy path: git clone command shape and env wiring
#
# The action steps themselves cannot be driven by bats (they require a full
# GitHub Actions runner context).  Instead, the tests exercise the shell
# logic extracted from each step in a controlled sub-shell, using the same
# stub-bin technique as the other bats suites in this directory.

load test_helper

# ---------------------------------------------------------------------------
# Helper: run the validation-step shell body with the given env vars set.
# Mirrors the logic in the "Validate install-path inputs" step exactly.
# ---------------------------------------------------------------------------
_run_validation() {
    # Accepts env vars via caller-set exports; the body mirrors the step shell.
    bash <<'EOF'
set -euo pipefail
active=()
[ -n "${FROM_BRANCH:-}" ]                                          && active+=("from-branch: '${FROM_BRANCH}'")
[ "${FROM_SOURCE:-}" = "true" ]                                    && active+=("from-source: true")
[ -n "${FROM_ARTIFACT:-}" ]                                        && active+=("from-artifact: '${FROM_ARTIFACT}'")
[ -n "${VERSION:-}" ] && [ "${VERSION:-}" != "latest" ]            && active+=("version: '${VERSION}'")

# The step only runs (and this body executes) when the if: condition is true,
# meaning at least two paths are active.  Mirror the same early-exit.
if [ "${#active[@]}" -lt 2 ]; then
  exit 0
fi
echo "ERROR: only one install path may be active; got: ${active[*]}" >&2
exit 1
EOF
}

# ---------------------------------------------------------------------------
# Helper: run the clone-step shell body with git stubbed.
# ---------------------------------------------------------------------------
_run_clone_step() {
    local branch="$1"
    # Stubs git so no network is used; records the clone argv in CLONE_ARGS_FILE.
    bash <<BODY
set -euo pipefail
export FROM_BRANCH="${branch}"
export RUNNER_TEMP="${_TEST_HOME}/runner-tmp"
export GITHUB_OUTPUT="${_TEST_HOME}/github-output"
mkdir -p "\${RUNNER_TEMP}"
: > "\${GITHUB_OUTPUT}"

# Stub git — record argv and create the destination directory.
export PATH="${_TEST_HOME}/fake-bin:\${PATH}"

clone_dest="\${RUNNER_TEMP}/anodizer-src"
repo_url="https://github.com/tj-smith47/anodizer.git"

# Body mirrors the "Clone anodizer branch" step exactly.
git clone --depth 1 --branch "\${FROM_BRANCH}" --single-branch "\${repo_url}" "\${clone_dest}"

echo "clone_dest=\${clone_dest}" >> "\${GITHUB_OUTPUT}"
BODY
}

# ---------------------------------------------------------------------------
# Helper: run the clone-step shell body with a git stub that exits 128.
# Models a non-existent remote branch.
# ---------------------------------------------------------------------------
_run_clone_step_fail() {
    local branch="$1"
    bash <<BODY
set -euo pipefail
export FROM_BRANCH="${branch}"
export RUNNER_TEMP="${_TEST_HOME}/runner-tmp"
export GITHUB_OUTPUT="${_TEST_HOME}/github-output"
mkdir -p "\${RUNNER_TEMP}"
: > "\${GITHUB_OUTPUT}"

# Stub git — exits 128 with an error message on stderr, mimicking
# "Remote branch <name> not found in upstream origin".
export PATH="${_TEST_HOME}/fake-bin-fail:\${PATH}"

clone_dest="\${RUNNER_TEMP}/anodizer-src"
repo_url="https://github.com/tj-smith47/anodizer.git"

git clone --depth 1 --branch "\${FROM_BRANCH}" --single-branch "\${repo_url}" "\${clone_dest}"

echo "clone_dest=\${clone_dest}" >> "\${GITHUB_OUTPUT}"
BODY
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

setup() {
    common_setup

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    # Stub git: record the full argv to CLONE_ARGS_FILE and create the
    # destination directory so downstream steps don't fail on a missing dir.
    CLONE_ARGS_FILE="${_TEST_HOME}/git-clone-args"
    cat > "${FAKE_BIN}/git" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${CLONE_ARGS_FILE}"
# Create destination dir (last positional arg) so tests can assert it exists.
dest=""
for arg; do dest="\$arg"; done
[ -n "\$dest" ] && mkdir -p "\$dest"
exit 0
STUB
    chmod +x "${FAKE_BIN}/git"

    # Stub git (fail variant): exits 128 with a "Remote branch not found" message.
    FAKE_BIN_FAIL="${_TEST_HOME}/fake-bin-fail"
    mkdir -p "$FAKE_BIN_FAIL"
    cat > "${FAKE_BIN_FAIL}/git" <<STUB
#!/usr/bin/env bash
echo "error: Remote branch \$5 not found in upstream origin" >&2
exit 128
STUB
    chmod +x "${FAKE_BIN_FAIL}/git"

    # GITHUB_OUTPUT
    GITHUB_OUTPUT="${_TEST_HOME}/github-output"
    : > "$GITHUB_OUTPUT"
    export GITHUB_OUTPUT
}

teardown() {
    common_teardown
}

# ---------------------------------------------------------------------------
# Mutual-exclusion tests
# ---------------------------------------------------------------------------

@test "version + from-branch → validation body exits non-zero" {
    FROM_BRANCH="my-feature" FROM_SOURCE="" FROM_ARTIFACT="" VERSION="v1.2.3" \
        run _run_validation
    [ "$status" -ne 0 ]
    [[ "$output" == *"from-branch"* ]]
    [[ "$output" == *"version"* ]]
}

@test "from-source + from-branch → validation body exits non-zero" {
    FROM_BRANCH="my-feature" FROM_SOURCE="true" FROM_ARTIFACT="" VERSION="" \
        run _run_validation
    [ "$status" -ne 0 ]
    [[ "$output" == *"from-branch"* ]]
    [[ "$output" == *"from-source"* ]]
}

@test "from-artifact + from-branch → validation body exits non-zero" {
    FROM_BRANCH="my-feature" FROM_SOURCE="" FROM_ARTIFACT="anodizer-linux" VERSION="" \
        run _run_validation
    [ "$status" -ne 0 ]
    [[ "$output" == *"from-branch"* ]]
    [[ "$output" == *"from-artifact"* ]]
}

@test "only from-branch set → validation body exits 0" {
    FROM_BRANCH="my-feature" FROM_SOURCE="" FROM_ARTIFACT="" VERSION="" \
        run _run_validation
    [ "$status" -eq 0 ]
}

@test "only version set → validation body exits 0" {
    FROM_BRANCH="" FROM_SOURCE="" FROM_ARTIFACT="" VERSION="v1.2.3" \
        run _run_validation
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Clone step tests
# ---------------------------------------------------------------------------

@test "clone step: git called with correct flags" {
    run _run_clone_step "my-feature"
    [ "$status" -eq 0 ]
    # git was called with the expected argv (one arg per line).
    grep -qx 'clone'                                  "${CLONE_ARGS_FILE}"
    grep -qx -- '--depth'                             "${CLONE_ARGS_FILE}"
    grep -qx '1'                                      "${CLONE_ARGS_FILE}"
    grep -qx -- '--branch'                            "${CLONE_ARGS_FILE}"
    grep -qx 'my-feature'                             "${CLONE_ARGS_FILE}"
    grep -qx -- '--single-branch'                     "${CLONE_ARGS_FILE}"
    grep -qx 'https://github.com/tj-smith47/anodizer.git' "${CLONE_ARGS_FILE}"
}

@test "clone step: clone_dest written to GITHUB_OUTPUT" {
    run _run_clone_step "my-feature"
    [ "$status" -eq 0 ]
    grep -q 'clone_dest=' "${GITHUB_OUTPUT}"
}

@test "clone step: destination is under RUNNER_TEMP/anodizer-src" {
    run _run_clone_step "my-feature"
    [ "$status" -eq 0 ]
    grep -q "clone_dest=.*/anodizer-src$" "${GITHUB_OUTPUT}"
}

@test "clone step: branch name passed through verbatim" {
    run _run_clone_step "feature/some-slash"
    [ "$status" -eq 0 ]
    grep -qx 'feature/some-slash' "${CLONE_ARGS_FILE}"
}

# ---------------------------------------------------------------------------
# Failure-path test — non-existent branch
# ---------------------------------------------------------------------------

@test "clone step: git failure propagates non-zero exit and error message" {
    run _run_clone_step_fail "no-such-branch"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]] || [[ "$output" == *"Remote branch"* ]]
}

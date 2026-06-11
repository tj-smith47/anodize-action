#!/usr/bin/env bats
# resolve-artifact-run.bats — unit tests for
# scripts/install/resolve-artifact-run.sh.
#
# Stubs `gh` on PATH so no API call ever leaves the test. Covers the
# exact-SHA fast path, the API-based parent walk (must work without local
# git history — checkout runs at fetch-depth 1), and the regression where
# ::notice:: diagnostics emitted inside a resolver leaked into the resolved
# run id (the runner then queried runs/NaN/artifacts).

load test_helper

SCRIPT="${REPO_ROOT}/scripts/install/resolve-artifact-run.sh"

HEAD_SHA="e3d2b022d4839f5b81ecfe66dbb522de4c65e5b7"
PARENT_SHA="ae61e8410000000000000000000000000000aaaa"
RUN_FOR_PARENT="27322178041"

setup() {
    common_setup

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"

    # `gh api` stub: success run exists only for PARENT_SHA; the commits
    # endpoint serves the HEAD -> PARENT chain. Driven by the jq filter and
    # endpoint shape the script actually uses.
    cat > "${FAKE_BIN}/gh" <<STUB
#!/usr/bin/env bash
endpoint="\$2"
case "\$endpoint" in
    repos/*/actions/workflows/*/runs)
        jq_expr="\$4"
        if [[ "\$jq_expr" == *'.conclusion=="success"'* && "\$jq_expr" == *"${PARENT_SHA}"* ]]; then
            echo "${RUN_FOR_PARENT}"
        else
            echo "null"
        fi
        ;;
    repos/*/commits/${HEAD_SHA})
        echo "${PARENT_SHA}"
        ;;
    repos/*/commits/*)
        echo ""
        ;;
    *)
        echo "null"
        ;;
esac
STUB
    chmod +x "${FAKE_BIN}/gh"

    export PATH="${FAKE_BIN}:${PATH}"
    export GITHUB_ACTION_PATH="$REPO_ROOT"
    export GITHUB_OUTPUT="${_TEST_HOME}/gh-output"
    : > "$GITHUB_OUTPUT"
    export ARTIFACT_WORKFLOW="ci.yml"
    export FROM_ARTIFACT="anodizer-linux"
    export REPO="tj-smith47/anodizer"
}

@test "parent walk resolves via API when exact SHA has no run (shallow checkout)" {
    # cwd is a directory with no git history at all — rev-parse would fail.
    cd "$_TEST_HOME"
    export COMMIT_SHA="$HEAD_SHA"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    grep -q "^run_id=${RUN_FOR_PARENT}\$" "$GITHUB_OUTPUT"
}

@test "resolved run id contains no workflow-command text" {
    cd "$_TEST_HOME"
    export COMMIT_SHA="$HEAD_SHA"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    ! grep -q "::notice" "$GITHUB_OUTPUT"
    value=$(awk -F= '/^run_id=/{print $2}' "$GITHUB_OUTPUT")
    [[ "$value" =~ ^[0-9]+$ ]]
}

@test "fast path resolves an exact-SHA success run without touching parents" {
    cd "$_TEST_HOME"
    # Point the stub's success run at HEAD itself.
    sed -i "s/${PARENT_SHA}/${HEAD_SHA}/g" "${FAKE_BIN}/gh"
    export COMMIT_SHA="$HEAD_SHA"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    grep -q "^run_id=${RUN_FOR_PARENT}\$" "$GITHUB_OUTPUT"
    [[ "$output" != *"checking parent commits"* ]]
}

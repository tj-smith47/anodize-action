#!/usr/bin/env bats
# validate-action-manifest.bats — tests for scripts/validate/action-manifest.sh,
# the gate that asserts action.yml is a loadable composite-action manifest:
# every step carries run-or-uses (+ shell where run). Runs the REAL script.
#
# Regression anchor: a dropped `run:` once parsed as valid YAML, the floating
# major tag was retagged to it, and every consumer broke at job setup with
# "Required property is missing: run". The negative cases reproduce that exact
# shape so the gate that closes it can never silently regress.

load test_helper

setup() {
    common_setup
    # The validator is a python3 + PyYAML program; without the interpreter it
    # exits 127 and every assertion below would report the wrong failure.
    require_tool python3 "action-manifest.sh is a python3 + PyYAML program"
}
teardown() { common_teardown; }

VALIDATE="scripts/validate/action-manifest.sh"

# Write a minimal composite manifest whose steps body is the given YAML into
# the redirected HOME and echo its path.
_manifest() {
    local body="$1"
    local path="${_TEST_HOME}/action.yml"
    cat > "$path" <<YAML
name: "Test Action"
description: "fixture"
runs:
  using: "composite"
  steps:
${body}
YAML
    printf '%s' "$path"
}

@test "the repo's real action.yml passes" {
    run bash "${REPO_ROOT}/${VALIDATE}" "${REPO_ROOT}/action.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"all with run-or-uses"* ]]
}

@test "a step missing run: is rejected (the v1-break shape)" {
    local m
    m="$(_manifest "    - name: broken
      shell: bash")"
    run bash "${REPO_ROOT}/${VALIDATE}" "$m"
    [ "$status" -ne 0 ]
    [[ "$output" == *"neither"* ]]
}

@test "a step with both run and uses is rejected" {
    local m
    m="$(_manifest "    - name: both
      uses: actions/checkout@v6
      shell: bash
      run: echo hi")"
    run bash "${REPO_ROOT}/${VALIDATE}" "$m"
    [ "$status" -ne 0 ]
    [[ "$output" == *"both"* ]]
}

@test "a run step missing shell is rejected" {
    local m
    m="$(_manifest "    - name: noshell
      run: echo hi")"
    run bash "${REPO_ROOT}/${VALIDATE}" "$m"
    [ "$status" -ne 0 ]
    [[ "$output" == *"shell"* ]]
}

@test "a non-composite action is rejected" {
    local path="${_TEST_HOME}/action.yml"
    cat > "$path" <<YAML
name: "x"
description: "y"
runs:
  using: "node20"
  main: "index.js"
YAML
    run bash "${REPO_ROOT}/${VALIDATE}" "$path"
    [ "$status" -ne 0 ]
    [[ "$output" == *"composite"* ]]
}

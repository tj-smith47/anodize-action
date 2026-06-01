#!/usr/bin/env bats
# tag-output.bats — tests for the `new-tag` / `old-tag` / `part` / `tagged` /
# `head-sha` step outputs parsed by scripts/run/outputs.sh.
#
# `anodizer tag` (single-crate / lockstep path) prints bare `new_tag=`,
# `old_tag=`, `part=` lines. The action surfaces them so a workflow_run release
# pipeline can gate on `tagged` without re-deriving the signal from git.
#
# These run the REAL outputs.sh in a throwaway git repo (not a copied snippet)
# so the test tracks production behavior, including the `git rev-parse HEAD`
# head-sha emission.

load test_helper

# Run the real outputs.sh against a caller-supplied stdout log, inside a fresh
# git repo (so `git rev-parse HEAD` resolves). Echoes the resulting
# GITHUB_OUTPUT contents.
_run_outputs() {
    local log_content="$1"
    local workdir="${_TEST_HOME}/repo"
    local log_file="${_TEST_HOME}/stdout.log"
    local github_output="${_TEST_HOME}/github-output"

    rm -rf "$workdir"
    mkdir -p "$workdir"
    git -C "$workdir" init -q
    git -C "$workdir" config user.email t@t
    git -C "$workdir" config user.name t
    git -C "$workdir" commit -q --allow-empty -m init

    printf '%s\n' "$log_content" > "$log_file"
    : > "$github_output"

    (
        cd "$workdir"
        ANODIZER_STDOUT_LOG="$log_file" GITHUB_OUTPUT="$github_output" \
            bash "${BATS_TEST_DIRNAME}/../scripts/run/outputs.sh"
    )
    cat "$github_output"
}

_field() { grep "^$1=" | tail -1 | cut -d= -f2-; }

@test "tag outputs: a normal bump surfaces new-tag/old-tag/part and tagged=true" {
    out="$(_run_outputs "$(printf 'new_tag=v1.2.3\nold_tag=v1.2.2\npart=minor\n')")"
    [ "$(printf '%s' "$out" | _field new-tag)" = 'v1.2.3' ]
    [ "$(printf '%s' "$out" | _field old-tag)" = 'v1.2.2' ]
    [ "$(printf '%s' "$out" | _field part)" = 'minor' ]
    [ "$(printf '%s' "$out" | _field tagged)" = 'true' ]
}

@test "tag outputs: no-op run (new == old) is tagged=false" {
    out="$(_run_outputs "$(printf 'new_tag=v1.2.2\nold_tag=v1.2.2\npart=none\n')")"
    [ "$(printf '%s' "$out" | _field tagged)" = 'false' ]
}

@test "tag outputs: first release (empty old-tag) is tagged=true" {
    out="$(_run_outputs "$(printf 'new_tag=v0.1.0\nold_tag=\npart=minor\n')")"
    [ "$(printf '%s' "$out" | _field new-tag)" = 'v0.1.0' ]
    [ "$(printf '%s' "$out" | _field tagged)" = 'true' ]
}

@test "tag outputs: a run with no tag lines (e.g. release) is tagged=false" {
    out="$(_run_outputs "$(printf 'some unrelated progress line\n')")"
    [ "$(printf '%s' "$out" | _field new-tag)" = '' ]
    [ "$(printf '%s' "$out" | _field tagged)" = 'false' ]
}

@test "tag outputs: last new_tag line wins (retry-loop safe)" {
    out="$(_run_outputs "$(printf 'new_tag=v1.0.0\nold_tag=v0.9.0\nnew_tag=v1.1.0\nold_tag=v1.0.0\n')")"
    [ "$(printf '%s' "$out" | _field new-tag)" = 'v1.1.0' ]
    [ "$(printf '%s' "$out" | _field old-tag)" = 'v1.0.0' ]
}

@test "tag outputs: head-sha is the repo HEAD" {
    out="$(_run_outputs "$(printf 'new_tag=v1.0.0\nold_tag=\npart=minor\n')")"
    expected="$(git -C "${_TEST_HOME}/repo" rev-parse HEAD)"
    [ "$(printf '%s' "$out" | _field head-sha)" = "$expected" ]
}

#!/usr/bin/env bats
# irreversibly-published-output.bats — tests for the `irreversibly_published`
# step output parsed by scripts/run/outputs.sh from dist/run-*/summary.json.
#
# `anodizer release` writes a run summary (`dist/run-<id>/summary.json`,
# or `dist/<crate>/run-<id>/summary.json` per crate in per-crate
# workspaces) carrying a top-level `irreversibly_published` flag plus
# per-publisher group/status rows. The action folds that into
# `irreversibly_published` so a workflow's rollback step can refuse to
# destroy a release whose version is already burned at a one-way-door
# registry (crates.io, chocolatey, winget, snapcraft, ...) — those never
# accept the same version twice, so rollback can't enable a re-cut.
# Reversible publishers (github-release assets, blobs, tap/bucket/index
# commits) must NOT set it: their state is deletable and the same
# version can be re-cut.
#
# These run the REAL outputs.sh in a throwaway git repo (same pattern as
# tag-output.bats) so the tests track production behavior.

load test_helper

# Run the real outputs.sh inside a fresh git repo whose dist/ the caller
# has populated via _write_summary. Echoes the resulting GITHUB_OUTPUT.
_run_outputs() {
    local workdir="${_TEST_HOME}/repo"
    local log_file="${_TEST_HOME}/stdout.log"
    local github_output="${_TEST_HOME}/github-output"

    : > "$log_file"
    : > "$github_output"

    (
        cd "$workdir"
        ANODIZER_STDOUT_LOG="$log_file" GITHUB_OUTPUT="$github_output" \
            bash "${BATS_TEST_DIRNAME}/../scripts/run/outputs.sh"
    )
    cat "$github_output"
}

_init_repo() {
    local workdir="${_TEST_HOME}/repo"
    rm -rf "$workdir"
    mkdir -p "$workdir"
    git -C "$workdir" init -q
    git -C "$workdir" config user.email t@t
    git -C "$workdir" config user.name t
    git -C "$workdir" commit -q --allow-empty -m init
}

# Write a summary.json under the repo's dist tree. $1 is the run-dir
# path relative to dist (e.g. "run-v1.0.0" or "mycrate/run-v1.0.0"),
# $2 is the JSON body.
_write_summary() {
    local rel="$1" body="$2"
    local dir="${_TEST_HOME}/repo/dist/${rel}"
    mkdir -p "$dir"
    printf '%s\n' "$body" > "${dir}/summary.json"
}

_field() { grep "^$1=" | tail -1 | cut -d= -f2-; }

@test "irreversibly_published: no dist directory at all is false" {
    _init_repo
    out="$(_run_outputs)"
    [ "$(printf '%s' "$out" | _field irreversibly_published)" = 'false' ]
}

@test "irreversibly_published: top-level flag true wins" {
    _init_repo
    _write_summary "run-v1.0.0" '{"irreversibly_published": true, "results": []}'
    out="$(_run_outputs)"
    [ "$(printf '%s' "$out" | _field irreversibly_published)" = 'true' ]
}

@test "irreversibly_published: reversible-only successes stay false" {
    # Assets + Manager publishers all succeeded — every one of them is
    # deletable, so the version is NOT burned and rollback stays open.
    _init_repo
    _write_summary "run-v1.0.0" '{"irreversibly_published": false, "results": [
        {"name": "github-release", "group": "Assets", "status": "succeeded"},
        {"name": "homebrew", "group": "Manager", "status": "succeeded"},
        {"name": "blob", "group": "Assets", "status": "succeeded"}
    ]}'
    out="$(_run_outputs)"
    [ "$(printf '%s' "$out" | _field irreversibly_published)" = 'false' ]
}

@test "irreversibly_published: legacy summary without the flag falls back to Submitter rows" {
    # Summaries from anodizer versions predating irreversibly_published:
    # a landed Submitter row must still flip true.
    _init_repo
    _write_summary "run-v1.0.0" '{"results": [
        {"name": "github-release", "group": "Assets", "status": "succeeded"},
        {"name": "cargo", "group": "Submitter", "status": "succeeded"}
    ]}'
    out="$(_run_outputs)"
    [ "$(printf '%s' "$out" | _field irreversibly_published)" = 'true' ]
}

@test "irreversibly_published: failed or skipped Submitter rows do not burn" {
    _init_repo
    _write_summary "run-v1.0.0" '{"results": [
        {"name": "cargo", "group": "Submitter", "status": "failed"},
        {"name": "chocolatey", "group": "Submitter", "status": "skipped-submitter-gated"},
        {"name": "winget", "group": "Submitter", "status": "skipped-not-configured"}
    ]}'
    out="$(_run_outputs)"
    [ "$(printf '%s' "$out" | _field irreversibly_published)" = 'false' ]
}

@test "irreversibly_published: pending-moderation Submitter counts as burned" {
    # Chocolatey-style moderation queues are one-way doors; the version
    # is out of our hands even before approval.
    _init_repo
    _write_summary "run-v1.0.0" '{"results": [{"name": "chocolatey", "group": "Submitter", "status": "pending-moderation"}]}'
    out="$(_run_outputs)"
    [ "$(printf '%s' "$out" | _field irreversibly_published)" = 'true' ]
}

@test "irreversibly_published: rolled-back Submitter still counts as burned" {
    # cargo yank withdraws the artifact but the version slot stays
    # burned — a same-version re-publish is rejected by crates.io.
    _init_repo
    _write_summary "run-v1.0.0" '{"results": [{"name": "cargo", "group": "Submitter", "status": "rolled-back"}]}'
    out="$(_run_outputs)"
    [ "$(printf '%s' "$out" | _field irreversibly_published)" = 'true' ]
}

@test "irreversibly_published: rollback-failed Submitter counts as burned" {
    _init_repo
    _write_summary "run-v1.0.0" '{"results": [{"name": "cargo", "group": "Submitter", "status": "rollback-failed"}]}'
    out="$(_run_outputs)"
    [ "$(printf '%s' "$out" | _field irreversibly_published)" = 'true' ]
}

@test "irreversibly_published: per-crate layout (dist/<crate>/run-*) is scanned" {
    _init_repo
    _write_summary "mycrate/run-mycrate-v1.0.0" '{"irreversibly_published": true, "results": []}'
    out="$(_run_outputs)"
    [ "$(printf '%s' "$out" | _field irreversibly_published)" = 'true' ]
}

@test "irreversibly_published: any burned crate among several flips true (per-crate OR-fold)" {
    _init_repo
    _write_summary "crate-a/run-crate-a-v1.0.0" '{"irreversibly_published": false, "results": []}'
    _write_summary "crate-b/run-crate-b-v1.0.0" '{"irreversibly_published": false, "results": [
        {"name": "cargo", "group": "Submitter", "status": "succeeded"}
    ]}'
    out="$(_run_outputs)"
    [ "$(printf '%s' "$out" | _field irreversibly_published)" = 'true' ]
}

@test "irreversibly_published: malformed summary JSON is tolerated as false" {
    _init_repo
    _write_summary "run-v1.0.0" 'this is not json {'
    out="$(_run_outputs)"
    [ "$(printf '%s' "$out" | _field irreversibly_published)" = 'false' ]
}

@test "irreversibly_published: empty results and no flag is false" {
    _init_repo
    _write_summary "run-v1.0.0" '{"results": []}'
    out="$(_run_outputs)"
    [ "$(printf '%s' "$out" | _field irreversibly_published)" = 'false' ]
}

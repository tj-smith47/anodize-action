#!/usr/bin/env bash
# resolve-artifact-run.sh — resolve the workflow run ID to cross-download an
# anodize artifact from, with tolerance for CI↔release overlap races.
#
# The common race: release.yml is triggered on a tag push from ci.yml's tag
# job, but ci.yml itself is still in progress when release.yml starts. A
# naive query for runs with conclusion=="success" won't find the target run.
#
# Strategy:
#  1. Fast path: look for a completed successful run matching the commit SHA
#     (or the dereferenced commit SHA, for annotated tags).
#  2. Parent walk: if no run exists for the exact SHA, walk up to 5 parent
#     commits. Handles version_sync commits where the tag points to a commit
#     CI never built, but the parent has a successful run.
#  3. Slow path: poll for up to ~5 min, accepting in-progress runs whose
#     artifact has already been uploaded (the snapshot job runs well before
#     the tag job, so the artifact exists long before ci.yml completes).
#  4. Fail fast if a matching run has failed or been cancelled — no point
#     waiting on something that will never publish.
#
# Required env vars:
#   ARTIFACT_WORKFLOW — workflow filename (e.g. ci.yml)
#   FROM_ARTIFACT     — artifact name (e.g. anodize-linux)
#   REPO              — owner/name of the repository hosting the workflow
#   COMMIT_SHA        — commit SHA to search for
#   GH_TOKEN          — gh CLI token
#
# Writes `run_id=<id>` to $GITHUB_OUTPUT on success.
set -euo pipefail

# shellcheck source=./lib-colors.sh
source "$(dirname "$0")/lib-colors.sh"

: "${ARTIFACT_WORKFLOW:?ARTIFACT_WORKFLOW is required}"
: "${FROM_ARTIFACT:?FROM_ARTIFACT is required}"
: "${REPO:?REPO is required}"
: "${COMMIT_SHA:?COMMIT_SHA is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

anodize::section "Resolving ${ARTIFACT_WORKFLOW} artifact"
anodize::kv commit "${COMMIT_SHA}"
anodize::kv artifact "${FROM_ARTIFACT}"

echo "::group::Resolving $ARTIFACT_WORKFLOW run for $COMMIT_SHA"

# Dereference the SHA once up front so annotated tag SHAs work too.
deref_sha=$(git rev-parse "${COMMIT_SHA}^{commit}" 2>/dev/null || echo "$COMMIT_SHA")

# Query the most recent run matching either SHA whose status matches a jq
# filter. Returns the run id on stdout, or empty on no match.
find_run() {
    local status_filter="$1"
    local sha id
    for sha in "$COMMIT_SHA" "$deref_sha"; do
        [ -z "$sha" ] && continue
        id=$(gh api "repos/${REPO}/actions/workflows/${ARTIFACT_WORKFLOW}/runs" \
            --jq "[.workflow_runs[] | select(.head_sha==\"${sha}\" and ${status_filter})][0].id" \
            2>/dev/null || echo "")
        if [ -n "$id" ] && [ "$id" != "null" ]; then
            echo "$id"
            return 0
        fi
    done
    echo ""
}

# True if the given run already has an artifact with name $FROM_ARTIFACT.
run_has_artifact() {
    local id="$1"
    local count
    count=$(gh api "repos/${REPO}/actions/runs/${id}/artifacts" \
        --jq "[.artifacts[] | select(.name==\"${FROM_ARTIFACT}\")] | length" \
        2>/dev/null || echo "0")
    [ "$count" != "0" ]
}

# Fast path — completed successful run.
run_id=$(find_run '.conclusion=="success"')

# Parent walk — when the tagged commit is a version_sync commit (e.g.
# "chore: bump crates/foo to 1.2.3"), CI never ran on that SHA. Walk up to
# 5 parent commits to find the one CI actually built.
if [ -z "$run_id" ]; then
    echo "::notice::No CI run for exact SHA; checking parent commits"
    for depth in 1 2 3 4 5; do
        parent_sha=$(git rev-parse "${deref_sha}~${depth}" 2>/dev/null || echo "")
        [ -z "$parent_sha" ] && break
        # Temporarily override the SHAs used by find_run.
        orig_commit="$COMMIT_SHA"; orig_deref="$deref_sha"
        COMMIT_SHA="$parent_sha"; deref_sha="$parent_sha"
        run_id=$(find_run '.conclusion=="success"')
        COMMIT_SHA="$orig_commit"; deref_sha="$orig_deref"
        if [ -n "$run_id" ]; then
            echo "::notice::Found CI run ${run_id} at parent ~${depth} (${parent_sha})"
            break
        fi
    done
fi

if [ -z "$run_id" ]; then
    # Slow path — poll with exponential backoff (5s → 10s → 20s → 30s cap).
    # 20 attempts × mostly 30s ≈ 9 min max wait (generous for CI overlap).
    max_attempts=20
    sleep_secs=5
    attempt=1
    while [ $attempt -le $max_attempts ]; do
        run_id=$(find_run '.conclusion=="success"')
        if [ -n "$run_id" ]; then
            break
        fi

        # Fail fast on a matching failed/cancelled run.
        failed=$(find_run '(.conclusion=="failure" or .conclusion=="cancelled")')
        if [ -n "$failed" ]; then
            echo "::error::${ARTIFACT_WORKFLOW} run ${failed} for ${COMMIT_SHA} failed or was cancelled"
            exit 1
        fi

        # Accept an in-progress run whose artifact has already been uploaded.
        in_progress=$(find_run '(.status=="in_progress" or .status=="queued") and (.conclusion==null or .conclusion=="")')
        if [ -n "$in_progress" ] && run_has_artifact "$in_progress"; then
            run_id="$in_progress"
            echo "::notice::Accepting in-progress run $run_id (artifact $FROM_ARTIFACT already uploaded)"
            break
        fi

        echo "::notice::Waiting for ${ARTIFACT_WORKFLOW} run on ${COMMIT_SHA} (attempt ${attempt}/${max_attempts}, next check in ${sleep_secs}s)"
        sleep "$sleep_secs"
        attempt=$((attempt + 1))
        next=$((sleep_secs * 2))
        sleep_secs=$((next > 30 ? 30 : next))
    done
fi

if [ -z "$run_id" ] || [ "$run_id" = "null" ]; then
    echo "::error::Could not find a successful or artifact-ready ${ARTIFACT_WORKFLOW} run for ${COMMIT_SHA}"
    anodize::err "no successful or artifact-ready ${ARTIFACT_WORKFLOW} run for ${COMMIT_SHA}"
    exit 1
fi

echo "::notice::Resolved artifact-run-id=auto to run ${run_id}"
echo "::endgroup::"
anodize::ok "resolved to run ${run_id}"
echo "run_id=$run_id" >> "$GITHUB_OUTPUT"

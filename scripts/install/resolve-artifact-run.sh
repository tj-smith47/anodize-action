#!/usr/bin/env bash
# resolve-artifact-run.sh — resolve the workflow run ID to cross-download an
# anodizer artifact from, with tolerance for CI↔release overlap races.
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
#   FROM_ARTIFACT     — artifact name (e.g. anodizer-linux)
#   REPO              — owner/name of the repository hosting the workflow
#   COMMIT_SHA        — commit SHA to search for
#   GH_TOKEN          — gh CLI token
#
# Writes `run_id=<id>` to $GITHUB_OUTPUT on success.
set -euo pipefail

source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"

: "${ARTIFACT_WORKFLOW:?ARTIFACT_WORKFLOW is required}"
: "${FROM_ARTIFACT:?FROM_ARTIFACT is required}"
: "${REPO:?REPO is required}"
: "${COMMIT_SHA:?COMMIT_SHA is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

# Query the actions API for the first run on `sha` matching `status_filter`
# (a jq predicate on the run object). Echos run id or empty string. The two
# SHAs (raw tag SHA + dereferenced commit SHA) are tried in order so
# annotated-tag SHAs also resolve.
find_run() {
    local status_filter="$1" sha1="$2" sha2="${3:-}" sha id
    for sha in "$sha1" "$sha2"; do
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

run_has_artifact() {
    local id="$1" count
    count=$(gh api "repos/${REPO}/actions/runs/${id}/artifacts" \
        --jq "[.artifacts[] | select(.name==\"${FROM_ARTIFACT}\")] | length" \
        2>/dev/null || echo "0")
    [ "$count" != "0" ]
}

# Phase 1 — exact-SHA fast path.
resolve_fast() {
    find_run '.conclusion=="success"' "$COMMIT_SHA" "$deref_sha"
}

# Phase 2 — walk up to 5 parents looking for a successful run.
resolve_parents() {
    local depth parent_sha id
    gha_notice "No CI run for exact SHA; checking parent commits"
    for depth in 1 2 3 4 5; do
        parent_sha=$(git rev-parse "${deref_sha}~${depth}" 2>/dev/null || echo "")
        [ -z "$parent_sha" ] && break
        id=$(find_run '.conclusion=="success"' "$parent_sha" "")
        if [ -n "$id" ]; then
            gha_notice "Found CI run ${id} at parent ~${depth} (${parent_sha})"
            echo "$id"
            return 0
        fi
    done
    echo ""
}

# Phase 3 — exponential-backoff poll. Accepts an in-progress run once its
# artifact appears (the snapshot job uploads well before the tag job).
# 20 attempts × mostly 30s ≈ 9 min max wait (generous for CI overlap).
resolve_polling() {
    local max_attempts=20 sleep_secs=5 attempt=1 next id failed in_progress
    while [ $attempt -le $max_attempts ]; do
        id=$(find_run '.conclusion=="success"' "$COMMIT_SHA" "$deref_sha")
        if [ -n "$id" ]; then
            echo "$id"
            return 0
        fi

        failed=$(find_run '(.conclusion=="failure" or .conclusion=="cancelled")' "$COMMIT_SHA" "$deref_sha")
        [ -n "$failed" ] \
            && gha_fail "${ARTIFACT_WORKFLOW} run ${failed} for ${COMMIT_SHA} failed or was cancelled"

        in_progress=$(find_run '(.status=="in_progress" or .status=="queued") and (.conclusion==null or .conclusion=="")' "$COMMIT_SHA" "$deref_sha")
        if [ -n "$in_progress" ] && run_has_artifact "$in_progress"; then
            gha_notice "Accepting in-progress run $in_progress (artifact $FROM_ARTIFACT already uploaded)"
            echo "$in_progress"
            return 0
        fi

        gha_notice "Waiting for ${ARTIFACT_WORKFLOW} run on ${COMMIT_SHA} (attempt ${attempt}/${max_attempts}, next check in ${sleep_secs}s)"
        sleep "$sleep_secs"
        attempt=$((attempt + 1))
        next=$((sleep_secs * 2))
        sleep_secs=$((next > 30 ? 30 : next))
    done
    echo ""
}

gha_section Resolving "${ARTIFACT_WORKFLOW} artifact for ${COMMIT_SHA}"
anodizer::kv commit "${COMMIT_SHA}"
anodizer::kv artifact "${FROM_ARTIFACT}"

# Dereference once up front so annotated tag SHAs work too.
deref_sha=$(git rev-parse "${COMMIT_SHA}^{commit}" 2>/dev/null || echo "$COMMIT_SHA")

run_id=$(resolve_fast)
[ -z "$run_id" ] && run_id=$(resolve_parents)
[ -z "$run_id" ] && run_id=$(resolve_polling)

if [ -z "$run_id" ] || [ "$run_id" = "null" ]; then
    gha_fail "Could not find a successful or artifact-ready ${ARTIFACT_WORKFLOW} run for ${COMMIT_SHA}"
fi

gha_notice "Resolved artifact-run-id=auto to run ${run_id}"
gha_group_end
anodizer::ok "resolved to run ${run_id}"
gha_set_output run_id "$run_id"

#!/usr/bin/env bash
# Invoke `anodizer $ANODIZER_ARGS` with a retry loop for transient
# failures (registry rate limits, network timeouts, Docker push auth
# expiry).
#
# Deterministic failures (config errors, compile failures) fail
# identically on every attempt; the cost of two extra 10s waits is low
# vs. a flaky release.
#
# `--publish-only` is exempt from retries. It is intrinsically stateful:
# a partial success writes `dist/run-<run_id>/report.json`, and a blind
# retry would either (a) trip the publish-stage rerun guard and bail, or
# (b) — if forced past the guard — open duplicate PRs against PR-based
# publishers (homebrew, scoop, nix, krew, MCP). Recovery from a partial
# publish-only failure is operator-driven via
# `anodizer release --rollback-only --from-run=<id>`, not a wrapper
# retry.
#
# Stdout (only) is teed to $ANODIZER_STDOUT_LOG so the outputs step can
# parse `anodizer-output` markers without losing log visibility in the
# GHA UI. Stderr is NOT captured anywhere — it flows directly to the
# CI log on every attempt so transient and final failures are both
# debuggable in real time. The marker channel contract is stdout-only,
# so mixing stderr into the captured file would let an error line that
# resembles a marker contaminate the parsed output.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"
source "${GITHUB_ACTION_PATH}/scripts/lib/config.sh"

# The configured output tree (default `dist`); custom `dist:` values must
# steer the retry cleanup too, or a retry would wipe the wrong directory.
dist_dir=$(resolve_dist_dir)

# Predicate: is the dist tree holding context manifests we must preserve
# across a retry? `context.json` (or `context-<shard>.json`) at root or in
# any first-level subdir signals a split-build input / per-crate
# preserved-dist tree consumed by `release --merge` /
# `release --publish-only`; wiping it would turn a transient failure into
# an unrecoverable one.
has_preserved_context() {
    [ -d "$dist_dir" ] || return 1
    [ -f "${dist_dir}/context.json" ] && return 0
    ls "${dist_dir}"/context-*.json >/dev/null 2>&1 && return 0
    local d
    for d in "${dist_dir}"/*/; do
        [ -d "$d" ] || continue
        ls "${d}context"*.json >/dev/null 2>&1 && return 0
    done
    return 1
}

# Wipe generated artifacts between retries, leaving the dist tree GENUINELY
# empty: anodizer's dist-not-empty guard counts ANY directory entry, so a
# leftover empty `run-<id>/` subdir (or an undeleted symlink) makes every
# retry die with "dist directory is not empty" instead of rebuilding.
# Files and symlinks are removed at every depth, then empty dirs are pruned
# depth-first. `find` does not follow symlinks (no -L): a symlink is deleted
# as a link, never descended into — deletion cannot escape the tree. The
# whole function is skipped when preserved-dist manifests are present (see
# caller), so --publish-only inputs are never touched.
cleanup_dist() {
    [ -d "$dist_dir" ] || return 0
    find "$dist_dir" -mindepth 1 \( -type f -o -type l \) -delete 2>/dev/null || true
    find "$dist_dir" -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true
}

resolve_max_retries() {
    # Stateful modes must run exactly once. A blind whole-pipeline retry of a
    # stateful failure either no-ops into a FALSE-GREEN or double-acts.
    # case-glob matches the flag anywhere in the arg list.
    case " $ANODIZER_ARGS " in
        *" --publish-only "*|*" --rollback-only "*|*" tag rollback "*)
            anodizer::warn "retry disabled for stateful mode (--publish-only / --rollback-only / tag rollback)"
            echo 1
            return
            ;;
    esac
    # A plain `release` cuts the tag, creates the GitHub release, runs the
    # publishers, and on failure rolls back — DELETING the tag. A retry then
    # finds no release tag at HEAD, short-circuits "nothing to do", and exits 0,
    # turning a FAILED release GREEN (the brontes/cfgd pre-tagged pattern:
    # workflow triggered by a tag push, release job's rollback removes it).
    # Transient per-publisher failures (rate limits, network, auth expiry) are
    # retried INSIDE anodizer — the only layer that can retry without
    # re-running rollback. Build-only / preview / orchestrated legs stay
    # retryable: --snapshot / --nightly / --dry-run build no upstream state (or
    # self-tag, so a retry genuinely re-cuts rather than no-opping), --merge
    # consumes a preserved dist behind anodizer's own publish-rerun guard, and
    # --preflight / --prepare / --split mutate nothing upstream.
    case " $ANODIZER_ARGS " in
        *" release "*)
            case " $ANODIZER_ARGS " in
                *" --snapshot "*|*" --nightly "*|*" --dry-run "*|*" --merge "*|*" --preflight "*|*" --preflight-secrets "*|*" --prepare "*|*" --split "*|*" --announce-only "*)
                    echo 3
                    ;;
                *)
                    anodizer::warn "retry disabled for a stateful release (cuts a tag + publishes, rolls back on failure; a blind retry would false-green). Transient failures retry inside anodizer."
                    echo 1
                    ;;
            esac
            return
            ;;
    esac
    echo 3
}

run_attempt() {
    # shellcheck disable=SC2086
    # ANODIZER_ARGS is intentionally unquoted: users pass multiple flags
    # separated by whitespace via `inputs.args` and rely on word splitting
    # to forward them as distinct argv entries.
    anodizer $ANODIZER_ARGS | tee -a "$ANODIZER_STDOUT_LOG"
}

main() {
    anodizer::verb Running "anodizer"

    local max_retries attempt=1
    max_retries=$(resolve_max_retries)
    : > "$ANODIZER_STDOUT_LOG"

    while [ $attempt -le $max_retries ]; do
        if run_attempt; then
            return 0
        fi
        if [ $attempt -eq $max_retries ]; then
            if [ $max_retries -eq 1 ]; then
                anodizer::err "anodizer failed (no retry for stateful modes)"
            else
                anodizer::err "anodizer failed after ${max_retries} attempts"
            fi
            exit 1
        fi
        anodizer::warn "attempt ${attempt}/${max_retries} failed; retrying in 10s..."

        if has_preserved_context; then
            anodizer::warn "preserved-dist context manifests present (root or per-crate subdir); skipping ALL retry cleanup to keep --publish-only inputs intact"
        else
            cleanup_dist
        fi
        # Overridable so the bats suite can exercise the retry loop without
        # real 10s waits.
        sleep "${ANODIZER_RETRY_DELAY:-10}"
        attempt=$((attempt + 1))
    done
}

main "$@"

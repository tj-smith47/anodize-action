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
# Deterministic failures are exempt too, by a different mechanism: anodizer
# classifies them (exit code 2 / a stderr marker line) and the loop stops on
# the first attempt rather than burning the budget on an identical failure.
#
# Stdout (only) is teed to $ANODIZER_STDOUT_LOG so the outputs step can
# parse `anodizer-output` markers without losing log visibility in the
# GHA UI. Stderr flows to the CI log live on every attempt so transient and
# final failures are both debuggable in real time; it is additionally teed
# into a private per-attempt file that only the deterministic classifier
# reads. That file is deliberately NOT $ANODIZER_STDOUT_LOG: the
# `anodizer-output` marker channel is stdout-only, so an error line that
# resembles a marker must never reach the parsed output.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"
source "${GITHUB_ACTION_PATH}/scripts/lib/config.sh"

# anodizer's deterministic-error contract (crates/core/src/error_class.rs):
# EXIT_DETERMINISTIC plus a CLASS_MARKER line on stderr. Either signal alone
# is authoritative — the marker also classifies an anodizer old enough to
# still exit 1 on its deterministic paths, and the exit code still classifies
# a run whose stderr never made it back.
anodizer_exit_deterministic=2
anodizer_class_marker='anodizer-error-class: deterministic'

# Per-attempt stderr capture, truncated at the start of every attempt so the
# classifier can never inherit a previous attempt's marker.
attempt_stderr="$(mktemp)"
trap 'rm -f "$attempt_stderr"' EXIT

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
    # A `tag` invocation that mutates the remote (--push pushes the bump commit
    # + the new tag; --changelog refreshes CHANGELOG.md into that pushed bump
    # commit) is single-shot stateful: a partial push retried fails on the
    # now-existing tag, or — if it got past the bump commit — double-applies the
    # version writeback. Local-only `tag` forms (bare auto-tag, --dry-run,
    # --push-dry-run, --no-push) mutate nothing on the remote, so they stay
    # retryable. (`tag rollback` is already handled by the stateful-mode case
    # above.)
    #
    # LEADING-ANCHORED on the subcommand: the subcommand is always the FIRST
    # token of ANODIZER_ARGS. Matching a bare ` tag ` anywhere would misroute
    # `release --workspace tag` (`tag` is also a stage name) — dangerously
    # flipping a stateful release to 3×-retryable — so we only match `tag` when
    # it leads the arg string.
    case "$ANODIZER_ARGS " in
        "tag "*)
            case " $ANODIZER_ARGS " in
                *" --push "*|*" --changelog "*)
                    anodizer::warn "retry disabled for a stateful tag (--push / --changelog push a bump commit + a new tag; a blind retry fails on the existing tag or double-applies the writeback)."
                    echo 1
                    ;;
                *)
                    echo 3
                    ;;
            esac
            return
            ;;
    esac
    # `publish` and `continue` run the SAME stateful release / publish / blob
    # chain as `release --publish-only` against the SAME PR-based publishers
    # (homebrew, scoop, nix, krew, MCP) — they just lack the `--publish-only`
    # literal the stateful-mode case above keys off. A blind whole-pipeline
    # retry of a transient per-publisher failure re-runs the publish and opens
    # DUPLICATE PRs. Treat them like a stateful release: run once, surface the
    # real failure, let transient per-publisher failures retry INSIDE anodizer.
    # The build-only / preview leg (--dry-run, side-effect-free) and the
    # merge-resume leg (--merge, which sits behind anodizer's own publish-rerun
    # guard, identical to `release --merge`) stay retryable.
    #
    # LEADING-ANCHORED like the tag case: `publish` / `continue` are also stage
    # names, so `release --skip publish` and `release --snapshot --workspace
    # continue` must NOT match here — only a leading `publish `/`continue `
    # subcommand does.
    case "$ANODIZER_ARGS " in
        "publish "*|"continue "*)
            case " $ANODIZER_ARGS " in
                *" --dry-run "*|*" --merge "*)
                    echo 3
                    ;;
                *)
                    anodizer::warn "retry disabled for a stateful publish/continue (runs the publish + blob chain against PR-based publishers; a blind retry would open duplicate PRs). Transient failures retry inside anodizer."
                    echo 1
                    ;;
            esac
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

# Returns anodizer's OWN exit status, not a tee's. `set -o pipefail` (the
# repo-wide idiom; no script here reaches for PIPESTATUS) makes both the inner
# and the outer pipeline report the failing member, and both tees are pipeline
# members — so the shell has reaped and flushed them before the status is read.
# A `2> >(tee …)` process substitution would stream the same bytes but race the
# marker grep, since the shell does not wait for it.
run_attempt() {
    : > "$attempt_stderr"
    # fd 3 carries stdout past the stderr tee; stderr then takes stdout's place
    # in the inner pipeline, landing in the capture file and on the CI log.
    # shellcheck disable=SC2086
    # ANODIZER_ARGS is intentionally unquoted: users pass multiple flags
    # separated by whitespace via `inputs.args` and rely on word splitting
    # to forward them as distinct argv entries.
    { anodizer $ANODIZER_ARGS 2>&1 1>&3 3>&- | tee -a "$attempt_stderr" >&2; } 3>&1 \
        | tee -a "$ANODIZER_STDOUT_LOG"
}

is_deterministic_failure() {
    if [ "$1" -eq "$anodizer_exit_deterministic" ]; then
        return 0
    fi
    grep -qF -- "$anodizer_class_marker" "$attempt_stderr"
}

main() {
    anodizer::verb Running "anodizer"

    local max_retries attempt=1 status
    max_retries=$(resolve_max_retries)
    : > "$ANODIZER_STDOUT_LOG"

    while [ $attempt -le $max_retries ]; do
        status=0
        run_attempt || status=$?
        if [ "$status" -eq 0 ]; then
            return 0
        fi
        if is_deterministic_failure "$status"; then
            anodizer::err "anodizer failed with a deterministic error (exit ${status}); retrying cannot help — fix the reported config/usage error and re-run"
            exit 1
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

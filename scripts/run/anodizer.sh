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
source "${GITHUB_ACTION_PATH}/scripts/lib/colors.sh"

anodizer::section "anodizer"

# Detect --publish-only / --rollback-only — both are stateful and must
# run exactly once. case-glob matches the flag anywhere in the arg list.
case " $ANODIZER_ARGS " in
    *" --publish-only "*|*" --rollback-only "*)
        max_retries=1
        anodizer::verb retry "disabled for stateful mode (--publish-only / --rollback-only)"
        ;;
    *)
        max_retries=3
        ;;
esac

attempt=1
: > "$ANODIZER_STDOUT_LOG"
while [ $attempt -le $max_retries ]; do
    # shellcheck disable=SC2086
    # ANODIZER_ARGS is intentionally unquoted: users pass multiple flags
    # separated by whitespace via `inputs.args` and rely on word splitting
    # to forward them as distinct argv entries.
    if anodizer $ANODIZER_ARGS | tee -a "$ANODIZER_STDOUT_LOG"; then
        break
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

    # Clean generated artifacts between retries to prevent "already exists"
    # collisions. Any subdir of dist/ that holds a context manifest
    # (`context.json` or `context-<shard>.json`) is a split-build input or
    # per-crate preserved-dist tree consumed by `release --merge` /
    # `release --publish-only` — wiping it turns a transient failure into
    # an unrecoverable one. When any such marker is present at the root
    # or in any first-level subdir, skip cleanup entirely.
    if [ -d "./dist" ]; then
        preserved=false
        if [ -f "./dist/context.json" ] || ls ./dist/context-*.json >/dev/null 2>&1; then
            preserved=true
        else
            for d in ./dist/*/; do
                [ -d "$d" ] || continue
                if ls "${d}context"*.json >/dev/null 2>&1; then
                    preserved=true
                    break
                fi
            done
        fi

        if [ "$preserved" = "true" ]; then
            anodizer::warn "preserved-dist context manifests present (root or per-crate subdir); skipping ALL retry cleanup to keep --publish-only inputs intact"
        else
            find ./dist -maxdepth 1 -type f -delete 2>/dev/null || true
            for d in ./dist/*/; do
                [ -d "$d" ] || continue
                find "$d" -type f -delete 2>/dev/null || true
            done
        fi
    fi
    sleep 10
    attempt=$((attempt + 1))
done

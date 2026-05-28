#!/usr/bin/env bash
# Probe the sccache GHA backend before arming RUSTC_WRAPPER.
#
# Earlier probes used `--start-server` + `--show-stats`, both of which
# return success even when the upstream cache is 503ing — the failure
# only surfaces later, inside a real rustc call. Exercise a cache-bound
# call here (`sccache rustc -vV` is what cargo itself uses to probe the
# compiler) and only enable the wrapper if THAT survives. On failure
# fall back to bare rustc — slower, but green.
set -euo pipefail

export SCCACHE_GHA_ENABLED=true
if sccache "$(rustup which rustc)" -vV >/dev/null 2>&1; then
    echo "::notice::sccache backend reachable; wrapping rustc"
    echo "SCCACHE_GHA_ENABLED=true" >> "$GITHUB_ENV"
    echo "RUSTC_WRAPPER=sccache" >> "$GITHUB_ENV"
else
    echo "::warning::sccache backend unreachable (likely GHA cache outage); building without wrapper"
fi

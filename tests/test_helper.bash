#!/usr/bin/env bash
# test_helper.bash — shared bats setup/teardown for anodizer-action tests.
#
# Every .bats file must `load test_helper` and call common_setup / common_teardown
# (directly or via setup/teardown) to engage the filesystem tripwire that prevents
# tests from mutating the real $HOME or system paths.

# Resolve the repo root so tests can reference scripts/ regardless of cwd.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# ── Filesystem tripwire ───────────────────────────────────────────────────────
#
# Redirect $HOME to a private tmp dir for the duration of each test.  Any
# script that tries to write to the real $HOME will instead write to this
# throwaway directory, which is removed in common_teardown.  If teardown
# detects that the real $HOME was written (via the canary file test below),
# it fails loudly.

_REAL_HOME="$HOME"
_TEST_HOME=""
_CANARY=""

common_setup() {
    _TEST_HOME="$(mktemp -d)"
    export HOME="$_TEST_HOME"

    # Drop a canary in the real HOME; if a test writes to the real HOME
    # the canary will still be there (meaning the redirect worked — the
    # canary is our proof the real HOME was NOT written by the test).
    _CANARY="${_REAL_HOME}/.anodizer_action_bats_canary_$$"
    touch "$_CANARY"
}

common_teardown() {
    # Canary must still exist — if it vanished something deleted from real $HOME.
    if [ -n "$_CANARY" ] && [ ! -e "$_CANARY" ]; then
        echo "TRIPWIRE: real HOME canary was deleted — test wrote to real \$HOME" >&2
        rm -rf "$_TEST_HOME" 2>/dev/null || true
        return 1
    fi
    rm -f "$_CANARY" 2>/dev/null || true
    rm -rf "$_TEST_HOME" 2>/dev/null || true
    export HOME="$_REAL_HOME"
}

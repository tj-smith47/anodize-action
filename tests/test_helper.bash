#!/usr/bin/env bash
# test_helper.bash — shared bats setup/teardown for anodizer-action tests.
#
# FILESYSTEM ISOLATION: every test must run with HOME redirected into
# _TEST_HOME so nothing can write to the developer's real shell rc files,
# config dirs, or caches.  Past sessions polluted real ~/.bashrc with stray
# PATH / completion lines from CLI bootstrap scripts run inside unguarded
# tests.  Never remove the HOME redirect.
#
# TRIPWIRE: HOME redirect is policy; the tripwire is enforcement.  Every
# test snapshots a fixed list of "real-user files that must never change
# during a test run" at common_setup, then compares (size + sha256) at
# common_teardown.  If any drift, the test fails — even if every assertion
# in the test body passed.  The list is real-$HOME paths captured BEFORE
# HOME is redirected.  Tests that need to watch additional real-FS paths
# (e.g. a bin under /usr/local/bin) call `tripwire_watch <abs-path>` after
# common_setup.  There is no opt-out — if a test legitimately needs to
# write under real $HOME (it shouldn't), it must be redesigned, not
# excluded.
#
# Ported from /opt/repos/task-cli/tests/test_helper.bash (canonical pattern).

# Resolve the repo root so tests can reference scripts/ regardless of cwd.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# Default watchset — files under the developer's real $HOME that no test
# may touch.  Add to this list when new shell rc / config conventions
# appear; do not remove entries.
_TRIPWIRE_DEFAULT_PATHS=(
    ".bashrc" ".bash_profile" ".bash_login" ".bash_aliases" ".bash_logout"
    ".profile" ".inputrc"
    ".zshrc" ".zprofile" ".zlogin" ".zshenv" ".zlogout"
    ".gitconfig" ".gitconfig.local"
    ".ssh/config" ".ssh/known_hosts" ".ssh/authorized_keys"
)

_tripwire_hash() {
    # Stream-hash a file via stdin so trailing-newline / sparse handling is
    # consistent with how the rest of the helper compares content.  Prints
    # "MISSING\tMISSING" when the path doesn't exist so the snapshot
    # distinguishes absent-then-created from changed-content.
    local path="$1"
    if [ -e "$path" ]; then
        local sha size
        sha="$(sha256sum < "$path" 2>/dev/null | awk '{print $1}')" || sha="UNREADABLE"
        size="$(stat -c '%s' "$path" 2>/dev/null || echo "UNREADABLE")"
        printf '%s\t%s' "$size" "$sha"
    else
        printf 'MISSING\tMISSING'
    fi
}

_tripwire_record() {
    # Append one snapshot line: "<absolute-path>\t<size>\t<sha256>"
    local path="$1"
    local rec
    rec="$(_tripwire_hash "$path")"
    printf '%s\t%s\n' "$path" "$rec" >> "$TRIPWIRE_SNAPSHOT"
}

tripwire_watch() {
    # Public helper — tests call this with an absolute path after
    # common_setup to extend the watchset for that single test.
    local path="$1"
    case "$path" in
        /*) ;;
        *)  printf 'tripwire_watch: path must be absolute (got %q)\n' "$path" >&2
            return 64 ;;
    esac
    _tripwire_record "$path"
}

_tripwire_init() {
    # Snapshot every default path under the captured real $HOME.  Idempotent —
    # overwrites the snapshot file referenced by $TRIPWIRE_SNAPSHOT.
    TRIPWIRE_SNAPSHOT="${TRIPWIRE_SNAPSHOT:-$_TEST_HOME/.tripwire-snapshot}"
    : > "$TRIPWIRE_SNAPSHOT"
    local p
    for p in "${_TRIPWIRE_DEFAULT_PATHS[@]}"; do
        _tripwire_record "$_REAL_HOME/$p"
    done
}

_tripwire_check() {
    # Re-hash every recorded path and fail loudly on drift.  Called from
    # common_teardown.  Returns 1 when any path drifted; in bats 1.5+ a
    # non-zero return from teardown marks the test failed.
    [ -f "${TRIPWIRE_SNAPSHOT:-}" ] || return 0
    local violations=()
    local path before_size before_sha after_rec after_size after_sha
    while IFS=$'\t' read -r path before_size before_sha; do
        after_rec="$(_tripwire_hash "$path")"
        after_size="${after_rec%%$'\t'*}"
        after_sha="${after_rec##*$'\t'}"
        if [ "$before_size" != "$after_size" ] || [ "$before_sha" != "$after_sha" ]; then
            violations+=("$path: size ${before_size}->${after_size}  sha ${before_sha:0:12}->${after_sha:0:12}")
        fi
    done < "$TRIPWIRE_SNAPSHOT"
    if [ "${#violations[@]}" -gt 0 ]; then
        {
            printf '\n'
            printf '!!! FILESYSTEM TRIPWIRE — real-user files mutated by this test !!!\n'
            printf 'test:  %s\n' "${BATS_TEST_NAME:-unknown}"
            printf 'file:  %s\n' "${BATS_TEST_FILENAME:-unknown}"
            printf 'real $HOME: %s\n' "$_REAL_HOME"
            printf 'drift detected:\n'
            printf '  %s\n' "${violations[@]}"
            printf 'fix: tests must keep HOME redirected to _TEST_HOME (common_setup does this).\n'
            printf '     if a child process restores HOME (env -i, sudo -E, etc), pass\n'
            printf '     HOME="$HOME" explicitly through that boundary.\n'
        } >&2
        return 1
    fi
    return 0
}

# ── Public API ───────────────────────────────────────────────────────────────

_REAL_HOME=""
_TEST_HOME=""

common_setup() {
    # Capture real $HOME BEFORE we mutate it — tripwire compares against
    # this anchor, not the redirected HOME.
    _REAL_HOME="${HOME:?HOME must be set before common_setup}"
    _TEST_HOME="$(mktemp -d)"
    export HOME="$_TEST_HOME"
    TRIPWIRE_SNAPSHOT="$_TEST_HOME/.tripwire-snapshot"
    _tripwire_init
}

common_teardown() {
    local tripwire_rc=0
    _tripwire_check || tripwire_rc=$?
    if [ -n "${_TEST_HOME:-}" ] && [ -d "$_TEST_HOME" ]; then
        rm -rf "$_TEST_HOME"
    fi
    export HOME="$_REAL_HOME"
    return "$tripwire_rc"
}

# Default setup/teardown — bats files that don't define their own pick these up.
setup() {
    common_setup
}

teardown() {
    common_teardown
}

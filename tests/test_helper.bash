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

path_shim() {
    # Publish a tool into stub-PATH directory $1 under the name $2, as an
    # executable shim that execs the real binary in place.  $3 is the real
    # binary's path; it defaults to `command -v $2`, and the call is a no-op
    # returning non-zero when the tool is absent from the caller's PATH.
    #
    # A symlink cannot be used here.  MSYS/Git-Bash has no POSIX symlinks by
    # default, so `ln -s` silently COPIES the .exe; a copied MSYS binary then
    # resolves msys-2.0.dll relative to its own image directory, which the stub
    # dir does not contain.  Tests that additionally sanitize the environment
    # (`env -i PATH=<stub dir>`) drop the one PATH entry that would have found
    # the runtime, so every copied tool — `bash` included — dies with 127
    # before the code under test ever runs.  Copying is also ruinously slow for
    # a whole-directory curation: /usr/bin is hundreds of megabytes of real
    # binaries, versus a few kilobytes of shims.  A shim keeps the real binary
    # at its real location beside its runtime, on every platform, while the
    # stub dir still contains nothing but the named tools.
    local dir="$1" name="$2" real="${3:-}"
    if [ -z "$real" ]; then
        real="$(command -v "$name")" || return 1
    fi
    _write_shim "${dir}/${name}" "$real"
    chmod +x "${dir}/${name}"
}

_write_shim() {
    # Write (but do not chmod) a shim at $1 that execs $2. The interpreter is
    # resolved once per bats process — a shim's #! must be an absolute path,
    # since the whole point is to work where PATH cannot find bash.
    printf '#!%s\nexec %q "$@"\n' "${_SHIM_BASH:=$(command -v bash)}" "$2" > "$1"
}

curated_bin() {
    # Build a stub-PATH directory holding a shim for every tool in the standard
    # bin dirs EXCEPT the space-separated names in $1, and echo the directory.
    # Callers use it to prove a `command -v <tool>` fast path in the code under
    # test is genuinely unsatisfiable, without starving that code of every
    # other tool it legitimately needs. One bulk chmod rather than one per
    # entry keeps the cost to a single fork over the whole directory.
    #
    # The result is cached per bats file, keyed by the exclusion set. Building
    # it walks a few thousand entries, and bats runs every command in the test
    # body under a DEBUG trap — which turned a 0.1s loop into 4s and made this
    # helper the single largest cost in the suite. The directory holds nothing
    # but shims and no test writes into it, so one build per exclusion set is
    # indistinguishable from one per test.
    local exclude=" ${1:-} "
    local key="${1:-none}"
    local dir="${BATS_FILE_TMPDIR:-$_TEST_HOME}/curated-bin-${key//[^a-zA-Z0-9]/-}"
    if [ -d "$dir" ]; then
        printf '%s' "$dir"
        return 0
    fi
    mkdir -p "$dir"
    local d f base
    # /mingw64/bin is where Git-Bash keeps git, curl, gpg and the rest of the
    # MSYS toolchain — omitting it curated away the very tools the code under
    # test probes for, and the arms that need them died on a `requires git on
    # PATH` guard instead of running.
    for d in /usr/bin /bin /usr/local/bin /mingw64/bin; do
        [ -d "$d" ] || continue
        for f in "$d"/*; do
            base="${f##*/}"
            case "$exclude" in *" $base "*) continue ;; esac
            [ -e "${dir}/${base}" ] && continue
            _write_shim "${dir}/${base}" "$f"
        done
    done
    chmod +x "$dir"/* 2> /dev/null || true
    printf '%s' "$dir"
}

_exec_bit_representable() {
    # Git-Bash mounts NTFS `noacl`, where chmod cannot set the POSIX x bit at
    # all: Cygwin instead INFERS executability from file content (a `#!` line
    # or an `MZ` header).  A stub payload of arbitrary bytes therefore stays
    # mode 644 no matter what the code under test chmods.
    local probe="${_TEST_HOME}/.exec-bit-probe"
    printf 'probe' > "$probe"
    chmod +x "$probe"
    [ -x "$probe" ]
}

assert_installed_executable() {
    # Assert an installer placed $1 and marked it executable.  The x bit is
    # only checked where the filesystem can represent it (see
    # _exec_bit_representable); asserting it elsewhere would fail for a reason
    # that has nothing to do with the installer.  Forcing it to hold by giving
    # the stub payload `#!`/`MZ` content would be worse: the assertion would
    # then pass whether or not the installer ever chmodded anything.
    local path="$1"
    if [ ! -f "$path" ]; then
        printf 'expected installed file: %s\n' "$path" >&2
        return 1
    fi
    if _exec_bit_representable && [ ! -x "$path" ]; then
        printf 'installed but not executable: %s\n' "$path" >&2
        return 1
    fi
}

resolve_python3() {
    # Echo the path of a Python 3 interpreter under either spelling, or return
    # non-zero when the host has none.  Windows CPython ships no `python3.exe`
    # — only `python` — so probing the POSIX name alone reports "no
    # interpreter" on a host that has one, and every test guarded on it drops
    # out as a skip.  Code under test still spells it `python3`; callers
    # publish the resolved binary under that name with `path_shim`.
    command -v python3 2> /dev/null || command -v python 2> /dev/null
}

provide_python3() {
    # Publish a host Python 3 interpreter into stub-PATH directory $1 under the
    # POSIX name `python3` and prepend that directory to PATH, so a script that
    # invokes `python3` runs unmodified on a host that only has `python`.
    # Returns non-zero (publishing nothing) when no interpreter resolves.
    local dir="$1" real
    real="$(resolve_python3)" || return 1
    mkdir -p "$dir"
    path_shim "$dir" python3 "$real"
    PATH="${dir}:${PATH}"
    export PATH
}

# Default setup/teardown — bats files that don't define their own pick these up.
setup() {
    common_setup
}

teardown() {
    common_teardown
}

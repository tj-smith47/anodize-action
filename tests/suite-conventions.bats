#!/usr/bin/env bats
# suite-conventions.bats — invariants the test suite itself must hold, so a
# convention slip cannot silently disable coverage.

load test_helper

# bats encodes each `@test` title into a shell function name, hex-escaping
# every non-alphanumeric BYTE. A multi-byte UTF-8 character survives that pass
# as a raw byte embedded in the identifier, and MSYS/Git-Bash cannot round-trip
# a lone invalid byte through a child process's argv — bats-exec-test receives
# a mangled name, reports `unknown test name`, and the test never runs. Linux
# passes the byte through argv untouched, so the loss is invisible there: a
# non-ASCII title reads as green on CI while running nothing on Windows.
@test "every @test title is ASCII so bats can address it on every platform" {
    local offenders
    offenders="$(LC_ALL=C grep -n '^@test .*[^ -~]' "${BATS_TEST_DIRNAME}"/*.bats || true)"
    if [ -n "$offenders" ]; then
        printf 'non-ASCII @test titles are unrunnable under Git-Bash/MSYS:\n%s\n' \
            "$offenders" >&2
        return 1
    fi
}

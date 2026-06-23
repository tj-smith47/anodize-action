#!/usr/bin/env bats
# reclaim-disk.bats — unit tests for scripts/platform/reclaim-disk.sh.
#
# Every test runs with a CONTROLLED PATH (fake-bin + /usr/bin:/bin) so the
# stubbed sudo/rm/df are the ones the script reaches, and so NOTHING real is
# ever deleted. The rm-stub (invoked via the sudo-stub, which records and
# forwards) appends its argv to RM_LOG, which the assertions inspect.
#
# Covers six behaviours:
#
#   1. RECLAIM_DISK=false                       → exit 0, no rm
#   2. auto + self-hosted                       → exit 0, no rm (CRITICAL guard)
#   3. auto + self-hosted + verbose             → prints "skipped: not github-hosted"
#   4. auto + github-hosted + macOS             → rm targets CoreSimulator runtimes
#   5. true + RUNNER_ENVIRONMENT unset + Linux  → forces; rm targets /usr/local/lib/android
#   6. RECLAIM_DISK=bogus                        → non-zero exit (gha_fail)

load test_helper

setup() {
    common_setup

    FAKE_BIN="${_TEST_HOME}/fake-bin"
    mkdir -p "$FAKE_BIN"
    CONTROLLED_PATH="${FAKE_BIN}:/usr/bin:/bin"

    RM_LOG="${_TEST_HOME}/rm.log"
    : > "$RM_LOG"

    # ── Stub: rm — record argv, delete nothing ───────────────────────────
    cat > "${FAKE_BIN}/rm" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$RM_LOG"
exit 0
STUB
    chmod +x "${FAKE_BIN}/rm"

    # ── Stub: sudo — drop the `sudo` prefix and exec the rest under the
    #    controlled PATH so `sudo rm -rf X` reaches the rm-stub above ──────
    cat > "${FAKE_BIN}/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
    chmod +x "${FAKE_BIN}/sudo"

    # ── Stub: df — stable single-line output so the freed-space summary is
    #    deterministic (after > before by a >100MB margin) ────────────────
    DF_AFTER_FILE="${_TEST_HOME}/df_after"
    : > "$DF_AFTER_FILE"
    cat > "${FAKE_BIN}/df" <<'STUB'
#!/usr/bin/env bash
# First call (before) reports a smaller Avail; once DF_AFTER_FILE is touched
# (the script's reclaims have run) report a larger Avail so freed_mb >= 100.
if [ -s "$DF_AFTER_FILE" ]; then
    avail=2000000
else
    avail=1000000
    printf 'x' >> "$DF_AFTER_FILE"
fi
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n'
printf '/dev/disk1 10000000 5000000 %s 50%%%% /\n' "$avail"
STUB
    chmod +x "${FAKE_BIN}/df"
}

teardown() {
    common_teardown
}

# Shared invocation: run reclaim-disk.sh as a real subprocess under the
# controlled PATH with the given environment.
_run_reclaim() {
    run env \
        GITHUB_ACTION_PATH="${REPO_ROOT}" \
        NO_COLOR=1 \
        RM_LOG="${RM_LOG}" \
        DF_AFTER_FILE="${DF_AFTER_FILE}" \
        PATH="${CONTROLLED_PATH}" \
        "$@" \
        "${REPO_ROOT}/scripts/platform/reclaim-disk.sh"
}

# ── Test 1: false → no-op ────────────────────────────────────────────────

@test "reclaim: RECLAIM_DISK=false is a no-op, exits 0, no rm" {
    _run_reclaim RECLAIM_DISK="false" RUNNER_OS="Linux" RUNNER_ENVIRONMENT="github-hosted"
    [ "$status" -eq 0 ]
    [ ! -s "$RM_LOG" ]
}

# ── Test 2: auto + self-hosted → CRITICAL guard, no rm ──────────────────

@test "reclaim: auto on self-hosted reclaims nothing (self-hosted guard)" {
    _run_reclaim RECLAIM_DISK="auto" RUNNER_OS="Linux" RUNNER_ENVIRONMENT="self-hosted"
    [ "$status" -eq 0 ]
    [ ! -s "$RM_LOG" ]
}

# ── Test 3: auto + self-hosted + verbose → prints the skip line ─────────

@test "reclaim: auto on self-hosted prints the skip line under verbose" {
    _run_reclaim RECLAIM_DISK="auto" RUNNER_OS="Linux" RUNNER_ENVIRONMENT="self-hosted" \
        ANODIZER_VERBOSE=1
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped: not github-hosted"* ]]
    [ ! -s "$RM_LOG" ]
}

# ── Test 4: auto + github-hosted + macOS → simulator runtimes reclaimed ──

@test "reclaim: auto on github-hosted macOS reclaims CoreSimulator runtimes" {
    _run_reclaim RECLAIM_DISK="auto" RUNNER_OS="macOS" RUNNER_ENVIRONMENT="github-hosted"
    [ "$status" -eq 0 ]
    grep -q 'CoreSimulator/Profiles/Runtimes' "$RM_LOG"
}

# ── Test 5: true + RUNNER_ENVIRONMENT unset + Linux → forces ────────────

@test "reclaim: true forces reclamation regardless of RUNNER_ENVIRONMENT" {
    # RUNNER_ENVIRONMENT deliberately unset — `true` must reclaim anyway.
    _run_reclaim RECLAIM_DISK="true" RUNNER_OS="Linux"
    [ "$status" -eq 0 ]
    grep -q '/usr/local/lib/android' "$RM_LOG"
}

# ── Test 6: invalid mode → loud fail ────────────────────────────────────

@test "reclaim: invalid RECLAIM_DISK value fails loudly" {
    _run_reclaim RECLAIM_DISK="bogus" RUNNER_OS="Linux" RUNNER_ENVIRONMENT="github-hosted"
    [ "$status" -ne 0 ]
    [[ "$output" == *"RECLAIM_DISK"* ]]
}

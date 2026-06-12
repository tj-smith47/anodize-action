#!/usr/bin/env bats
# run-anodizer-retry.bats — tests for scripts/run/anodizer.sh's retry loop
# and its between-attempt dist hygiene.
#
# Contract under test:
#  1. After a failed attempt, cleanup leaves the dist tree GENUINELY empty
#     (files, symlinks, hidden subdirs, and the then-empty dirs themselves),
#     so a retry passes anodizer's dist-not-empty guard. The guard counts
#     ANY directory entry — a leftover empty `run-<id>/` dir poisons every
#     retry (Nightly run 27396951395).
#  2. Symlink deletion removes the link only; the target outside dist
#     survives.
#  3. Preserved-dist context manifests (root context.json) skip cleanup
#     entirely, keeping --merge / --publish-only inputs intact.
#  4. Stateful modes (--publish-only) run exactly once, no retry.
#
# These run the REAL script with a stub `anodizer` binary that litters dist
# on attempt 1 and emulates the binary's dist-not-empty guard on attempt 2+.

load test_helper

setup() {
    common_setup
    WORKDIR="$(mktemp -d)"
    STUB_BIN="$WORKDIR/bin"
    mkdir -p "$STUB_BIN"
    export PATH="$STUB_BIN:$PATH"
    export GITHUB_ACTION_PATH="$REPO_ROOT"
    export ANODIZER_STDOUT_LOG="$WORKDIR/stdout.log"
    export ANODIZER_RETRY_DELAY=0
    cd "$WORKDIR"
    printf 'dist: ./dist\n' > .anodizer.yaml
}

teardown() {
    cd /
    rm -rf "$WORKDIR"
    common_teardown
}

# Stub anodizer: attempt 1 litters dist the way a mid-build failure does
# (run-dir manifest, top-level file, hidden cache dir, symlink out of the
# tree) and fails; attempt 2+ replays the binary's dist-not-empty guard.
_write_stub() {
    cat > "$STUB_BIN/anodizer" <<STUB
#!/usr/bin/env bash
set -u
count_file="$WORKDIR/attempts"
n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "\$count_file"
if [ "\$n" -eq 1 ]; then
    mkdir -p ./dist/run-12345 ./dist/.cache
    echo '{}' > ./dist/run-12345/summary.json
    echo man > ./dist/anodizer.1
    echo cached > ./dist/.cache/probe
    ln -s "$WORKDIR/outside-target" ./dist/link-out
    exit 1
fi
if [ -d ./dist ] && [ -n "\$(ls -A ./dist)" ]; then
    echo "Error: dist directory './dist' is not empty; use --clean to remove it first"
    exit 1
fi
exit 0
STUB
    chmod +x "$STUB_BIN/anodizer"
}

@test "retry cleanup empties dist (dirs, hidden dirs, symlinks) so attempt 2 passes the guard" {
    _write_stub
    echo keepme > "$WORKDIR/outside-target"
    export ANODIZER_ARGS="release --nightly"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 0 ]
    [ "$(cat "$WORKDIR/attempts")" = "2" ]
    # Symlink deletion must remove the link, never the target.
    [ -f "$WORKDIR/outside-target" ]
    [ "$(cat "$WORKDIR/outside-target")" = "keepme" ]
    [[ "$output" == *"attempt 1/3 failed"* ]]
    [[ "$output" != *"is not empty"* ]]
}

@test "preserved-dist context manifest skips cleanup entirely" {
    cat > "$STUB_BIN/anodizer" <<STUB
#!/usr/bin/env bash
count_file="$WORKDIR/attempts"
n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "\$count_file"
mkdir -p ./dist
echo '{"shard":"x"}' > ./dist/context.json
exit 1
STUB
    chmod +x "$STUB_BIN/anodizer"
    export ANODIZER_ARGS="release --merge"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "3" ]
    # The manifest survives every retry.
    [ -f "$WORKDIR/dist/context.json" ]
    [[ "$output" == *"skipping ALL retry cleanup"* ]]
}

@test "stateful --publish-only runs exactly once" {
    cat > "$STUB_BIN/anodizer" <<STUB
#!/usr/bin/env bash
count_file="$WORKDIR/attempts"
n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "\$count_file"
exit 1
STUB
    chmod +x "$STUB_BIN/anodizer"
    export ANODIZER_ARGS="release --publish-only"

    run "$REPO_ROOT/scripts/run/anodizer.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$WORKDIR/attempts")" = "1" ]
    [[ "$output" == *"retry disabled for stateful mode"* ]]
}

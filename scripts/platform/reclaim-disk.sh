#!/usr/bin/env bash
# Reclaim large, build-irrelevant runner caches before heavy build/packaging.
#
# The two-build determinism harness assembles installers twice plus hdiutil
# scratch volumes; on the disk-tight macOS runner `hdiutil create` intermittently
# fails with "No space left on device". Deleting the preinstalled caches a Rust
# release pipeline never touches (iOS/tvOS/watchOS simulator runtimes, large
# preinstalled SDKs) buys back tens of GB so packaging has room to breathe.
#
# Mode comes from RECLAIM_DISK (auto|true|false):
#   false → no-op.
#   auto  → reclaim ONLY on a GitHub-hosted runner. A self-hosted runner (the
#           release pipeline's arc-anodizer host) is left untouched — its disk is
#           not disposable and must never be reclaimed.
#   true  → force, regardless of RUNNER_ENVIRONMENT.
#
# Every reclaim is best-effort: a missing path is normal, a failed delete never
# fails the build, and the happy path always exits 0.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/gha.sh"

mode="${RECLAIM_DISK:-auto}"
case "$mode" in
    auto|true|false) ;;
    *) gha_fail "RECLAIM_DISK must be one of auto|true|false (got '$mode')" ;;
esac

if [ "$mode" = "false" ]; then
    exit 0
fi

if [ "$mode" = "auto" ] && [ "${RUNNER_ENVIRONMENT:-}" != "github-hosted" ]; then
    anodizer::vdetail "disk reclaim skipped: not github-hosted (RUNNER_ENVIRONMENT=${RUNNER_ENVIRONMENT:-unset})"
    exit 0
fi

# Delete a path as root when possible. `rm -rf` is itself a no-op on an absent
# path and the `|| true` swallows any failure, so reclamation can never fail the
# build (no pre-existence guard — the absent-path case is rm's own no-op, which
# also keeps every target observable to a test rm-stub).
_rm() {
    anodizer::vstep "reclaiming $1"
    if command -v sudo >/dev/null 2>&1; then
        sudo rm -rf "$1" 2>/dev/null || true
    else
        rm -rf "$1" 2>/dev/null || true
    fi
}

# df -k may parse cleanly (Linux/macOS) or hand back something non-integer on
# Windows git-bash; only emit the freed-space summary when both reads are
# integers and the delta is meaningful.
before=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')
before_h=$(df -h / 2>/dev/null | awk 'NR==2{print $4}') || true

case "${RUNNER_OS:-}" in
    macOS)
        # iOS/tvOS/watchOS simulator runtimes + caches — tens of GB. Native
        # macOS builds never use them; hdiutil/pkgbuild/codesign live in /usr/bin
        # and are untouched.
        _rm "/Library/Developer/CoreSimulator/Profiles/Runtimes"
        _rm "${HOME}/Library/Developer/CoreSimulator/Caches"
        _rm "${HOME}/Library/Developer/CoreSimulator/Devices"
        # The preinstalled /Applications/Xcode*.app bundles are the single biggest
        # reclaimable items on a GitHub macOS runner (~12–15 GB each, several
        # shipped). A native Rust release pipeline needs only the active developer
        # dir's SDK + linker (resolved via `xcode-select -p`) plus the system
        # hdiutil/pkgbuild/codesign in /usr/bin; every non-active Xcode is dead
        # weight. Keep the active one, delete the rest.
        active_dir=$(xcode-select -p 2>/dev/null || true)
        keep_app=""
        case "$active_dir" in
            */Applications/*.app/*) keep_app="${active_dir%%.app/*}.app" ;;
        esac
        # Only sweep when the active Xcode was positively identified; if the
        # selected toolchain is CommandLineTools or unresolved, leave every
        # bundle alone rather than risk deleting the one the build links against.
        # RECLAIM_XCODE_DIR overrides /Applications ONLY so the bats test can point
        # at a fake Applications dir; production always uses /Applications.
        if [ -n "$keep_app" ]; then
            apps_dir="${RECLAIM_XCODE_DIR:-/Applications}"
            for app in "$apps_dir"/Xcode*.app; do
                [ -e "$app" ] || continue
                [ "$app" = "$keep_app" ] && continue
                _rm "$app"
            done
        fi
        # Large preinstalled cross-platform toolchains a Rust release/installer
        # pipeline never links against — the active Xcode SDK + /usr/bin tools
        # are all it needs. Freeing these (~13 GB Android, several GB .NET/GHC,
        # plus stale DerivedData) gives `hdiutil create` reliable headroom so
        # the first DMG of the two-build determinism harness stops landing on
        # the disk-full edge. Never touch ~/.rustup, ~/.cargo, sccache, or the
        # active Xcode.
        [ -n "${ANDROID_SDK_ROOT:-}" ] && _rm "$ANDROID_SDK_ROOT"
        [ -n "${ANDROID_HOME:-}" ] && _rm "$ANDROID_HOME"
        _rm "/Users/runner/Library/Android"
        _rm "/Users/runner/.dotnet"
        _rm "/usr/local/share/dotnet"
        _rm "/Users/runner/Library/Developer/Xcode/DerivedData"
        _rm "/Users/runner/.ghcup"
        ;;
    Linux)
        # Large preinstalled SDKs a Rust release pipeline never compiles against.
        _rm "/usr/local/lib/android"
        _rm "/opt/hostedtoolcache/CodeQL"
        _rm "/usr/share/swift"
        ;;
    Windows)
        # Best-effort only: no sudo, and the Android SDK may not be present.
        _rm "/c/Android"
        _rm "/c/Program Files/Android"
        ;;
esac

after=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')
after_h=$(df -h / 2>/dev/null | awk 'NR==2{print $4}') || true

# Surface the absolute free-disk numbers at DEFAULT level — when "No space left
# on device" strikes the harness, the failing run must show the real before/after
# available, not hide it behind RUNNER_DEBUG. Best-effort: only when both
# human-readable reads are non-empty (Windows git-bash df can be unreliable).
if [ -n "${before_h:-}" ] && [ -n "${after_h:-}" ]; then
    anodizer::kv "disk free" "${before_h} → ${after_h} available" || true
fi

# Both -k reads must be plain integers (Windows git-bash df can be unreliable —
# skip the freed summary silently rather than error). Report only a meaningful gain.
if [[ "$before" =~ ^[0-9]+$ ]] && [[ "$after" =~ ^[0-9]+$ ]] && [ "$after" -gt "$before" ]; then
    freed_mb=$(( (after - before) / 1024 ))
    if [ "$freed_mb" -ge 100 ]; then
        anodizer::kv reclaimed "${freed_mb} MB freed"
    fi
fi

exit 0

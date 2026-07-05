#!/usr/bin/env bash
# Build anodizer from source in the current working-directory and stage
# the resulting binary on $PATH.
#
# When $FROM_BRANCH is set the build runs against a remote clone with no
# cache reuse, so any inherited RUSTC_WRAPPER (e.g. a consumer
# workflow's `env: RUSTC_WRAPPER: sccache`) is pure overhead AND exposes
# the build to GHA cache backend outages. The sccache-probe step already
# skips arming the wrapper for from-branch; sanitize again here so an
# inherited value from the caller's workflow env doesn't slip through.
# determinism + from-source paths keep whatever wrapper the consumer set
# — those builds benefit from cache reuse.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"
# shellcheck source=deps.sh
source "${GITHUB_ACTION_PATH}/scripts/install/deps.sh"

command -v cargo > /dev/null 2>&1 \
    || gha_fail "Rust is required; set install-rust: true (or use from-branch which auto-installs Rust)"

if [ -n "$FROM_BRANCH" ]; then
    unset RUSTC_WRAPPER
    unset SCCACHE_GHA_ENABLED
fi

# anodizer itself pulls in aws-lc-sys transitively (octocrab's aws-lc-rs JWT
# provider — see the root Cargo.toml's `jwt-aws-lc-rs` comment), which
# hard-requires nasm on windows-msvc (see install_nasm in deps.sh). This
# build runs before the "Install dependencies" step — where the
# determinism-deps/auto-detect `nasm` token would otherwise land — so
# provision it here directly rather than depending on that later step.
[ "$RUNNER_OS" = "Windows" ] && install_nasm

gha_section Building "anodizer from source"
cargo build --release -p anodizer
install_dir="${RUNNER_TOOL_CACHE}/anodizer/source"
mkdir -p "$install_dir"
cp "target/release/${BIN}" "${install_dir}/${BIN}"
chmod +x "${install_dir}/${BIN}" 2>/dev/null || true
gha_add_path "$install_dir"
gha_group_end
anodizer::ok "anodizer built from source"
anodizer::detail "${install_dir}/${BIN}"

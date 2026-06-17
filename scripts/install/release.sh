#!/usr/bin/env bash
# Download and install an anodizer release archive from GitHub Releases.
#
# Caches under $RUNNER_TOOL_CACHE/anodizer/<version>/; a cache hit skips
# the download entirely. The download retries up to 3 times with linear
# backoff (1s, 2s) to ride out transient github.com hiccups.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"

version="${TAG#v}"
install_dir="${RUNNER_TOOL_CACHE}/anodizer/${version}"

if [ -x "${install_dir}/${BIN}" ]; then
    gha_add_path "$install_dir"
    anodizer::verb Installing "anodizer ${TAG}"
    anodizer::ok "anodizer ${TAG} already cached at ${install_dir}"
    exit 0
fi

archive="anodizer-${version}-${OS}-${ARCH}.${EXT}"
url="https://github.com/tj-smith47/anodizer/releases/download/${TAG}/${archive}"

gha_section Downloading "${archive}"
anodizer::detail "${url}"
tmpdir=$(mktemp -d)
downloaded=false
for attempt in 1 2 3; do
    if curl -fsSL "$url" -o "${tmpdir}/${archive}"; then
        downloaded=true
        break
    fi
    gha_warning "Download attempt ${attempt}/3 failed, retrying in ${attempt}s..."
    anodizer::warn "download attempt ${attempt}/3 failed, retrying in ${attempt}s..."
    sleep "$attempt"
done
[ "$downloaded" = "true" ] \
    || gha_fail "Failed to download anodizer ${TAG} from ${url} after 3 attempts"
gha_group_end

gha_section Extracting "${archive}"
mkdir -p "$install_dir"
if [ "$EXT" = "zip" ]; then
    unzip -q -o "${tmpdir}/${archive}" -d "$install_dir"
else
    tar -xzf "${tmpdir}/${archive}" -C "$install_dir"
fi
rm -rf "$tmpdir"
gha_group_end

chmod +x "${install_dir}/${BIN}" 2>/dev/null || true
gha_add_path "$install_dir"
anodizer::ok "anodizer ${TAG} installed"
anodizer::detail "${install_dir}/${BIN}"

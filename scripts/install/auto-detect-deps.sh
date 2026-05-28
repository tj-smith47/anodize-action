#!/usr/bin/env bash
# Parse .anodizer.yaml in the workdir and emit `deps=<csv>` listing the
# build/pipeline dependencies the configured stages need.
set -euo pipefail

deps=()
cfg=""
for candidate in .anodizer.yaml .anodizer.yml anodizer.yaml anodizer.yml; do
    if [ -f "$candidate" ]; then
        cfg="$candidate"
        break
    fi
done
if [ -z "$cfg" ]; then
    echo "::warning::auto-install: no anodizer config found, skipping"
    echo "deps=" >> "$GITHUB_OUTPUT"
    exit 0
fi

grep -qE '^nfpm:|^  - name: anodizer-stage-nfpm' "$cfg" && deps+=("nfpm") || true
grep -qE '^makeselfs:' "$cfg" && deps+=("makeself") || true
grep -qE '^snapcrafts:' "$cfg" && deps+=("snapcraft") || true
grep -qE '^srpm:' "$cfg" && deps+=("rpmbuild") || true
grep -qE '^binary_signs:|^docker_signs:' "$cfg" && deps+=("cosign") || true
grep -qE '^sboms:' "$cfg" && deps+=("syft") || true
grep -qE '^upx:' "$cfg" && deps+=("upx") || true
grep -qE '^nsis:' "$cfg" && deps+=("nsis") || true
grep -qE '^dmgs:' "$cfg" && deps+=("create-dmg") || true
grep -qE '^flatpaks:' "$cfg" && deps+=("flatpak") || true
# alejandra is only needed when the nix publisher opts into it as the
# formatter (the alternative, `nixfmt`, has no auto-installer here yet).
grep -qE '^[[:space:]]+formatter:[[:space:]]*alejandra[[:space:]]*$' "$cfg" && deps+=("alejandra") || true

# pkgs/msis can't be cross-built — warn (don't fail) when config asks for
# them on the wrong runner; the build will fail later with a better error.
if grep -qE '^pkgs:' "$cfg" && [ "${RUNNER_OS:-}" != "macOS" ]; then
    echo "::warning::auto-install: pkgs: requires macOS runner (got ${RUNNER_OS:-unset}); skipping"
fi
if grep -qE '^msis:' "$cfg" && [ "${RUNNER_OS:-}" != "Windows" ]; then
    echo "::warning::auto-install: msis: requires Windows runner (got ${RUNNER_OS:-unset}); skipping"
fi

grep -qE '^[[:space:]]*cross:[[:space:]]*(auto|zigbuild)[[:space:]]*$' "$cfg" && deps+=("zig" "cargo-zigbuild") || true

joined=$(IFS=','; echo "${deps[*]}")
echo "::notice::auto-install detected: ${joined:-none}"
echo "deps=$joined" >> "$GITHUB_OUTPUT"

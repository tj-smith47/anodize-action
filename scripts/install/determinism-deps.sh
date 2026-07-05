#!/usr/bin/env bash
# Emit the per-OS dependency set the determinism harness needs for the
# default stage list.
#
# Linux adds nfpm because its default stage list includes nfpm. zig and
# cargo-zigbuild are Linux-only — cross-compile from non-Linux runners
# isn't supported by the matrix. cosign / syft are pre-installed even
# when sign / sbom would skip; both are cheap and the determinism
# default exercises both.
#
# Windows adds clang-cl: the harness hard-requires it on PATH for
# windows-msvc builds, pinning it as the C/C++ compiler to fix an
# intermittent cl.exe C-object codegen non-determinism. It is windows-only —
# macOS determinism has no such requirement.
#
# Windows also adds nasm: aws-lc-sys (a real transitive dep the harness's
# windows-msvc build compiles — see install_nasm in deps.sh) hard-requires it
# on PATH to assemble its perlasm .asm, panicking with no fallback otherwise.
# It is windows-only — Linux/macOS aws-lc-sys builds use their platform's own
# assembler, not nasm.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/gha.sh"

if [ "$RUNNER_OS" = "Linux" ]; then
    gha_set_output deps "zig,cargo-zigbuild,upx,nfpm,makeself,snapcraft,syft,cosign"
elif [ "$RUNNER_OS" = "Windows" ]; then
    gha_set_output deps "upx,syft,cosign,clang-cl,nasm"
else
    gha_set_output deps "upx,syft,cosign"
fi

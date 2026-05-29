#!/usr/bin/env bash
# Map RUNNER_OS / RUNNER_ARCH to (os, arch, bin, ext) step outputs.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/gha.sh"

case "$RUNNER_OS" in
    Linux)   os=linux ;;
    macOS)   os=darwin ;;
    Windows) os=windows ;;
    *)       gha_fail "Unsupported OS: $RUNNER_OS" ;;
esac

case "$RUNNER_ARCH" in
    X64)   arch=amd64 ;;
    ARM64) arch=arm64 ;;
    *)     gha_fail "Unsupported arch: $RUNNER_ARCH" ;;
esac

gha_set_output os "$os"
gha_set_output arch "$arch"
if [ "$os" = "windows" ]; then
    gha_set_output bin anodizer.exe
    gha_set_output ext zip
else
    gha_set_output bin anodizer
    gha_set_output ext tar.gz
fi

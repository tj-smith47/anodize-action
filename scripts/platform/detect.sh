#!/usr/bin/env bash
# Map RUNNER_OS / RUNNER_ARCH to (os, arch, bin, ext) step outputs.
set -euo pipefail

case "$RUNNER_OS" in
    Linux)   os=linux ;;
    macOS)   os=darwin ;;
    Windows) os=windows ;;
    *)       echo "::error::Unsupported OS: $RUNNER_OS"; exit 1 ;;
esac

case "$RUNNER_ARCH" in
    X64)   arch=amd64 ;;
    ARM64) arch=arm64 ;;
    *)     echo "::error::Unsupported arch: $RUNNER_ARCH"; exit 1 ;;
esac

echo "os=$os" >> "$GITHUB_OUTPUT"
echo "arch=$arch" >> "$GITHUB_OUTPUT"
if [ "$os" = "windows" ]; then
    echo "bin=anodizer.exe" >> "$GITHUB_OUTPUT"
    echo "ext=zip" >> "$GITHUB_OUTPUT"
else
    echo "bin=anodizer" >> "$GITHUB_OUTPUT"
    echo "ext=tar.gz" >> "$GITHUB_OUTPUT"
fi

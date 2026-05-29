#!/usr/bin/env bash
# Provision apk signing keys for nfpm's apk packager.
#
# apk-tools uses RSA-PSS, not OpenPGP, so the GPG-armored block consumed
# by deb/rpm signing does not work here — a raw PEM RSA private key is
# required.
#
# The matching public key is derived via `openssl rsa -pubout` and
# copied into dist/ as `<repo>-apk-signing-key.rsa.pub` so anodizer's
# release.extra_files glob can attach it as a release asset. apk
# verifiers install that file under /etc/apk/keys/ before `apk add`-ing
# a signed package.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"
source "${GITHUB_ACTION_PATH}/scripts/lib/mask-secret.sh"

anodizer::mask_lines "$APK_PRIVATE_KEY_INPUT"

privfile="${RUNNER_TEMP}/anodizer-apk.rsa"
pubfile="${RUNNER_TEMP}/anodizer-apk.rsa.pub"
install -m 0600 /dev/null "$privfile"
printf '%s\n' "$APK_PRIVATE_KEY_INPUT" > "$privfile"
openssl rsa -in "$privfile" -pubout -out "$pubfile" 2>/dev/null
chmod 0644 "$pubfile"

# dist/ may not exist yet in single-shot release jobs; --merge jobs
# already have it populated by actions/download-artifact.
mkdir -p ./dist
cp "$pubfile" "./dist/${GITHUB_REPOSITORY##*/}-apk-signing-key.rsa.pub"

gha_set_env APK_PRIVATE_KEY_PATH "$privfile"
gha_set_env APK_PUBLIC_KEY_PATH "$pubfile"
gha_notice "apk signing keys written"
anodizer::ok "apk signing keys written (APK_PRIVATE_KEY_PATH for nfpm; pub key staged in dist/)"

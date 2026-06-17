#!/usr/bin/env bash
# Import a GPG private key into the runner keyring AND write it to a
# file path for nfpm signing.
#
# nfpm's deb/rpm/apk signers (rpmsign, dpkg-sig, abuild-sign) read the
# secret key directly off disk rather than going through gpg-agent, so
# anodizer's `nfpm.signature.key_file` needs a path. Same key material
# as the keyring import.
#
# The pinentry-loopback config is required for rpmsign / gpg to accept
# the passphrase from $GPG_PASSPHRASE non-interactively under CI.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"
source "${GITHUB_ACTION_PATH}/scripts/lib/mask-secret.sh"

anodizer::verb Importing "GPG signing key"
anodizer::mask_lines "$GPG_PRIVATE_KEY"

echo "$GPG_PRIVATE_KEY" | gpg --batch --import

gpg_key_file="${RUNNER_TEMP}/anodizer-signing.asc"
printf '%s' "$GPG_PRIVATE_KEY" > "$gpg_key_file"
chmod 600 "$gpg_key_file"
gha_set_env GPG_KEY_PATH "$gpg_key_file"

mkdir -p "${HOME}/.gnupg"
chmod 700 "${HOME}/.gnupg"
grep -qxF 'allow-loopback-pinentry' "${HOME}/.gnupg/gpg-agent.conf" 2>/dev/null \
    || echo 'allow-loopback-pinentry' >> "${HOME}/.gnupg/gpg-agent.conf"
grep -qxF 'pinentry-mode loopback' "${HOME}/.gnupg/gpg.conf" 2>/dev/null \
    || echo 'pinentry-mode loopback' >> "${HOME}/.gnupg/gpg.conf"
gpgconf --kill gpg-agent || true

anodizer::ok "GPG private key imported (keyring + GPG_KEY_PATH for nfpm)"

#!/usr/bin/env bash
# Write the cosign private key contents to ./cosign.key (mode 0600).
# Pair with COSIGN_PASSWORD in the env so cosign can decrypt at sign time.
set -euo pipefail
source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"
source "${GITHUB_ACTION_PATH}/scripts/lib/mask-secret.sh"

anodizer::verb Writing "cosign signing key"
anodizer::mask_lines "$COSIGN_KEY_CONTENTS"

printf '%s' "$COSIGN_KEY_CONTENTS" > cosign.key
chmod 600 cosign.key

anodizer::ok "cosign key written to cosign.key"

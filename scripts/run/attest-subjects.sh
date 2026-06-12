#!/usr/bin/env bash
# shellcheck shell=bash
# Flatten anodizer's attestation subjects manifest(s) into a sha256sum-format
# checksums file for `actions/attest-build-provenance`.
#
# In the default `subjects` attestation mode anodizer writes
# dist/attestation-subjects.json (single-crate / workspace-lockstep) or
# dist/<crate>.attestation-subjects.json (workspace per-crate) — each a
# [{name, digest:{sha256}}] array over every release-uploadable artifact. The
# attest action's `subject-checksums` input consumes a flat `<hex>  <name>`
# file (the format `sha256sum` writes; the digest algorithm is inferred from
# the 64-char hex length), so every manifest is flattened into one and its
# absolute path is emitted as the `checksums` step output.
#
# Producing the manifest IS the opt-in: no manifest means attestations were not
# enabled, so the output is left empty and the caller's attest step gates off.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/gha.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"

dist=$(resolve_dist_dir)

shopt -s nullglob
manifests=("${dist}"/*attestation-subjects.json)
if [ ${#manifests[@]} -eq 0 ]; then
    anodizer::step "no attestation subjects manifest in ${dist}/; attestations not enabled"
    gha_set_output checksums ""
    gha_set_output count 0
    exit 0
fi

# Absolute path: the attest step runs at $GITHUB_WORKSPACE, not this script's
# working-directory (inputs.workdir), so a relative dist path would not resolve.
case "$dist" in
    /*) checksums="${dist}/attestation-subjects.sha256" ;;
    *)  checksums="$(pwd)/${dist}/attestation-subjects.sha256" ;;
esac
{
    for m in "${manifests[@]}"; do
        jq -r '.[] | "\(.digest.sha256)  \(.name)"' "$m"
    done
} | sort -u > "$checksums"

count=$(wc -l < "$checksums" | tr -d ' ')
anodizer::ok "collected ${count} attestation subject(s) from ${#manifests[@]} manifest(s)"
gha_set_output checksums "$checksums"
gha_set_output count "$count"

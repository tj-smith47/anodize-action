#!/usr/bin/env bash
# shellcheck shell=bash
# GitHub Actions helpers — workflow commands (annotations, outputs, env,
# path) wrapped so callers don't open-code `echo "::error::..."` /
# `>> "$GITHUB_OUTPUT"` patterns. Centralising these eliminates wording
# drift across the ~30-site `::error:: + anodizer::err + exit 1`
# triplet that was duplicated verbatim across most validators and
# resolvers.
#
# Source-and-call (transitively sources colors.sh for diagnostic helpers):
#
#   source "${GITHUB_ACTION_PATH}/scripts/lib/gha.sh"
#   gha_set_output key "$value"
#   gha_fail "fatal: nope"   # emits ::error::, anodizer::err, exit 1

# shellcheck source=colors.sh
source "$(dirname "${BASH_SOURCE[0]}")/colors.sh"

gha_error()       { echo "::error::$*"; }
gha_warning()     { echo "::warning::$*"; }
gha_notice()      { echo "::notice::$*"; }
gha_group_begin() { echo "::group::$*"; }
gha_group_end()   { echo "::endgroup::"; }

# Fatal exit with both a GHA annotation AND a colored diagnostic line.
# Replaces the old triplet:
#   echo "::error::$msg"
#   anodizer::err "$msg"
#   exit 1
gha_fail() {
    gha_error "$*"
    anodizer::err "$*"
    exit 1
}

gha_set_output() { echo "$1=$2" >> "$GITHUB_OUTPUT"; }
gha_set_env()    { echo "$1=$2" >> "$GITHUB_ENV"; }
gha_add_path()   { echo "$1" >> "$GITHUB_PATH"; }

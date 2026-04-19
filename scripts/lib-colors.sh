#!/usr/bin/env bash
# lib-colors.sh — cargo-style verbs + goreleaser-style section markers.
#
# Source this from any composite-action step that wants colored output:
#
#   source "${GITHUB_ACTION_PATH}/scripts/lib-colors.sh"
#   anodizer::verb Installing "anodizer from ${URL}"
#   anodizer::step "downloading archive"
#   anodizer::ok "anodizer installed to ${install_dir}"
#
# GitHub Actions runners preserve ANSI escapes in log output and render them
# with color in the web UI. Color is disabled automatically when NO_COLOR is
# set or when stdout is not a TTY (matches cargo's CLI conventions). Use
# workflow commands (::group::, ::notice::, ::warning::, ::error::) for
# anything that should produce a PR annotation — those are GH-native and
# color-safe on their own.

# Only enable colors when output is interactive or when explicitly forced
# via ANODIZER_COLOR=always. CI=true (GitHub Actions) still gets color
# because Actions renders ANSI.
_anodizer_color_enabled() {
    if [ -n "${NO_COLOR:-}" ]; then
        return 1
    fi
    if [ "${ANODIZER_COLOR:-}" = "never" ]; then
        return 1
    fi
    if [ "${ANODIZER_COLOR:-}" = "always" ]; then
        return 0
    fi
    # Default: color on in Actions (CI=true) or on real TTY.
    if [ -n "${GITHUB_ACTIONS:-}" ] || [ -t 1 ]; then
        return 0
    fi
    return 1
}

if _anodizer_color_enabled; then
    _ANODIZER_RESET=$'\033[0m'
    _ANODIZER_DIM=$'\033[2m'
    _ANODIZER_BOLD=$'\033[1m'
    # Cargo uses bold + bright green (ANSI 92) for status verbs, emitted
    # as two separate escapes — not the combined `1;32` form. Match that
    # exactly so our verb lines render the same shade as `cargo build`.
    _ANODIZER_BOLD_GREEN=$'\033[1m\033[92m'
    _ANODIZER_CYAN=$'\033[36m'
    _ANODIZER_BOLD_CYAN=$'\033[1m\033[96m'
    _ANODIZER_BOLD_YELLOW=$'\033[1m\033[93m'
    _ANODIZER_BOLD_RED=$'\033[1m\033[91m'
else
    _ANODIZER_RESET=""
    _ANODIZER_DIM=""
    _ANODIZER_BOLD=""
    _ANODIZER_BOLD_GREEN=""
    _ANODIZER_CYAN=""
    _ANODIZER_BOLD_CYAN=""
    _ANODIZER_BOLD_YELLOW=""
    _ANODIZER_BOLD_RED=""
fi

# Cargo-style verb line: right-padded bold-green verb followed by detail.
#   anodizer::verb Installing "anodizer v0.1.0"
#   →   Installing anodizer v0.1.0
# The 12-column right-align matches `cargo`'s own output width.
anodizer::verb() {
    local verb="$1"
    shift
    printf "%s%12s%s %s\n" "${_ANODIZER_BOLD_GREEN}" "${verb}" "${_ANODIZER_RESET}" "$*"
}

# Goreleaser-style bullet for a sub-step inside a larger stage.
#   anodizer::step "downloading release archive"
#   → • downloading release archive
anodizer::step() {
    printf " %s•%s %s\n" "${_ANODIZER_CYAN}" "${_ANODIZER_RESET}" "$*"
}

# Success check — bold green ✓ with message.
anodizer::ok() {
    printf " %s✓%s %s\n" "${_ANODIZER_BOLD_GREEN}" "${_ANODIZER_RESET}" "$*"
}

# Warning — bold yellow, for non-annotation diagnostics. Use ::warning::
# separately when the message should appear as a GitHub annotation.
anodizer::warn() {
    printf " %s⚠%s %s\n" "${_ANODIZER_BOLD_YELLOW}" "${_ANODIZER_RESET}" "$*" >&2
}

# Error — bold red ✗ with message. Use ::error:: separately when the message
# should appear as a GitHub annotation.
anodizer::err() {
    printf " %s✗%s %s\n" "${_ANODIZER_BOLD_RED}" "${_ANODIZER_RESET}" "$*" >&2
}

# Dimmed detail line — for paths, versions, and subordinate info that
# should fade into the background (cargo's ` -> path/to/file` style).
anodizer::detail() {
    printf "   %s%s%s\n" "${_ANODIZER_DIM}" "$*" "${_ANODIZER_RESET}"
}

# Section header — bold cyan surrounded by horizontal rule. Use at the top
# of a new phase within an action step.
#   anodizer::section "Dependency installation"
anodizer::section() {
    local label="$*"
    printf "\n%s══ %s ══%s\n" "${_ANODIZER_BOLD_CYAN}" "${label}" "${_ANODIZER_RESET}"
}

# Dimmed key=value for debug/diagnostic output.
anodizer::kv() {
    local key="$1"
    shift
    printf "   %s%s%s = %s%s%s\n" \
        "${_ANODIZER_DIM}" "${key}" "${_ANODIZER_RESET}" \
        "${_ANODIZER_BOLD}" "$*" "${_ANODIZER_RESET}"
}

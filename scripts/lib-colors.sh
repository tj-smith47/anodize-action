#!/usr/bin/env bash
# lib-colors.sh — cargo-style verbs + goreleaser-style section markers.
#
# Source this from any composite-action step that wants colored output:
#
#   source "${GITHUB_ACTION_PATH}/scripts/lib-colors.sh"
#   anodize::verb Installing "anodize from ${URL}"
#   anodize::step "downloading archive"
#   anodize::ok "anodize installed to ${install_dir}"
#
# GitHub Actions runners preserve ANSI escapes in log output and render them
# with color in the web UI. Color is disabled automatically when NO_COLOR is
# set or when stdout is not a TTY (matches cargo's CLI conventions). Use
# workflow commands (::group::, ::notice::, ::warning::, ::error::) for
# anything that should produce a PR annotation — those are GH-native and
# color-safe on their own.

# Only enable colors when output is interactive or when explicitly forced
# via ANODIZE_COLOR=always. CI=true (GitHub Actions) still gets color
# because Actions renders ANSI.
_anodize_color_enabled() {
    if [ -n "${NO_COLOR:-}" ]; then
        return 1
    fi
    if [ "${ANODIZE_COLOR:-}" = "never" ]; then
        return 1
    fi
    if [ "${ANODIZE_COLOR:-}" = "always" ]; then
        return 0
    fi
    # Default: color on in Actions (CI=true) or on real TTY.
    if [ -n "${GITHUB_ACTIONS:-}" ] || [ -t 1 ]; then
        return 0
    fi
    return 1
}

if _anodize_color_enabled; then
    _ANODIZE_RESET=$'\033[0m'
    _ANODIZE_DIM=$'\033[2m'
    _ANODIZE_BOLD=$'\033[1m'
    # Cargo uses bold + bright green (ANSI 92) for status verbs, emitted
    # as two separate escapes — not the combined `1;32` form. Match that
    # exactly so our verb lines render the same shade as `cargo build`.
    _ANODIZE_BOLD_GREEN=$'\033[1m\033[92m'
    _ANODIZE_CYAN=$'\033[36m'
    _ANODIZE_BOLD_CYAN=$'\033[1m\033[96m'
    _ANODIZE_BOLD_YELLOW=$'\033[1m\033[93m'
    _ANODIZE_BOLD_RED=$'\033[1m\033[91m'
else
    _ANODIZE_RESET=""
    _ANODIZE_DIM=""
    _ANODIZE_BOLD=""
    _ANODIZE_BOLD_GREEN=""
    _ANODIZE_CYAN=""
    _ANODIZE_BOLD_CYAN=""
    _ANODIZE_BOLD_YELLOW=""
    _ANODIZE_BOLD_RED=""
fi

# Cargo-style verb line: right-padded bold-green verb followed by detail.
#   anodize::verb Installing "anodize v0.1.0"
#   →   Installing anodize v0.1.0
# The 12-column right-align matches `cargo`'s own output width.
anodize::verb() {
    local verb="$1"
    shift
    printf "%s%12s%s %s\n" "${_ANODIZE_BOLD_GREEN}" "${verb}" "${_ANODIZE_RESET}" "$*"
}

# Goreleaser-style bullet for a sub-step inside a larger stage.
#   anodize::step "downloading release archive"
#   → • downloading release archive
anodize::step() {
    printf " %s•%s %s\n" "${_ANODIZE_CYAN}" "${_ANODIZE_RESET}" "$*"
}

# Success check — bold green ✓ with message.
anodize::ok() {
    printf " %s✓%s %s\n" "${_ANODIZE_BOLD_GREEN}" "${_ANODIZE_RESET}" "$*"
}

# Warning — bold yellow, for non-annotation diagnostics. Use ::warning::
# separately when the message should appear as a GitHub annotation.
anodize::warn() {
    printf " %s⚠%s %s\n" "${_ANODIZE_BOLD_YELLOW}" "${_ANODIZE_RESET}" "$*" >&2
}

# Error — bold red ✗ with message. Use ::error:: separately when the message
# should appear as a GitHub annotation.
anodize::err() {
    printf " %s✗%s %s\n" "${_ANODIZE_BOLD_RED}" "${_ANODIZE_RESET}" "$*" >&2
}

# Dimmed detail line — for paths, versions, and subordinate info that
# should fade into the background (cargo's ` -> path/to/file` style).
anodize::detail() {
    printf "   %s%s%s\n" "${_ANODIZE_DIM}" "$*" "${_ANODIZE_RESET}"
}

# Section header — bold cyan surrounded by horizontal rule. Use at the top
# of a new phase within an action step.
#   anodize::section "Dependency installation"
anodize::section() {
    local label="$*"
    printf "\n%s══ %s ══%s\n" "${_ANODIZE_BOLD_CYAN}" "${label}" "${_ANODIZE_RESET}"
}

# Dimmed key=value for debug/diagnostic output.
anodize::kv() {
    local key="$1"
    shift
    printf "   %s%s%s = %s%s%s\n" \
        "${_ANODIZE_DIM}" "${key}" "${_ANODIZE_RESET}" \
        "${_ANODIZE_BOLD}" "$*" "${_ANODIZE_RESET}"
}

#!/usr/bin/env bash
# shellcheck shell=bash
# Console-output vocabulary for the composite action, kept cohesive with
# the anodizer CLI's "format B" scheme so action lines and CLI lines read
# as one log:
#
#   <bold-green present-participle verb> <title>      ← section header (left margin)
#      • detail / info                                 ← child line, 3-space indent
#      ✓ success
#      ✗ failure
#
# One helper per line-kind. Headers carry the human-readable title; the
# matching `::group::` collapsible is emitted by the same helper so the
# title can never drift between the two.
#
# Usage:
#   source "${GITHUB_ACTION_PATH}/scripts/lib/colors.sh"
#   anodizer::verb Installing "tools"     # plain header, no ::group::
#   anodizer::step "downloading archive"  # • detail
#   anodizer::ok   "anodizer installed"   # ✓ success
#
# Indentation encodes nesting depth only (2 spaces per level on top of the
# base 3-space child indent) — never word/verb length. For collapsible
# phases pair the header and its body with the gha_group_* helpers in
# gha.sh (or gha_section there, which wraps a header in a ::group::).
#
# GitHub Actions renders ANSI in the web UI; color is disabled when
# NO_COLOR is set or stdout is not a TTY. For PR annotations use the
# native workflow commands (::group::, ::notice::, ::warning::,
# ::error::) — those format independently of this lib.

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

# Path separators are normalized for display only — a Windows runner can
# hand us `C:\hostedtoolcache/.../anodizer.exe` with mixed separators.
# Collapse backslashes to forward slashes so child lines read consistently;
# never mutate a value used for filesystem access (display-only callers).
anodizer::norm_path() {
    printf '%s' "${1//\\//}"
}

# Child-line indent is depth-driven: a base 3-space margin plus 2 spaces per
# nesting level. Depth defaults to 0. Word/verb length never influences it.
_anodizer_indent() {
    local depth="${1:-0}" base="   " level
    for (( level = 0; level < depth; level++ )); do
        base+="  "
    done
    printf '%s' "$base"
}

# Section header (format B): a bold-green present-participle verb at the
# left margin, ONE space, then the title. The only thing at column 0.
#   anodizer::verb Building "source"
#   → Building source
# Diagnostic, so it writes to stderr: a sibling helper's stdout may be
# captured via $(...) and must not ingest this colored line.
anodizer::verb() {
    local verb="$1"
    shift
    printf "%s%s%s %s\n" "${_ANODIZER_BOLD_GREEN}" "${verb}" "${_ANODIZER_RESET}" "$*" >&2
}

# Detail / info child line — `•` marker, dimmed-cyan, optional dimmed
# trailing value. Pass an integer depth as $2 to nest deeper.
#   anodizer::step "downloading release archive"
#   →    • downloading release archive
anodizer::step() {
    printf "%s%s•%s %s\n" "$(_anodizer_indent "${2:-0}")" "${_ANODIZER_CYAN}" "${_ANODIZER_RESET}" "$1"
}

# Success child line — green `✓` marker.
#   anodizer::ok "anodizer built from source"
#   →    ✓ anodizer built from source
anodizer::ok() {
    printf "%s%s✓%s %s\n" "$(_anodizer_indent "${2:-0}")" "${_ANODIZER_BOLD_GREEN}" "${_ANODIZER_RESET}" "$1"
}

# Failure child line — red `✗` marker. Use ::error:: separately when the
# message should also surface as a GitHub annotation.
anodizer::err() {
    printf "%s%s✗%s %s\n" "$(_anodizer_indent "${2:-0}")" "${_ANODIZER_BOLD_RED}" "${_ANODIZER_RESET}" "$1" >&2
}

# Warning child line — bold-yellow `•`, kept in the child scheme. Use
# ::warning:: separately when the message should be a GitHub annotation.
anodizer::warn() {
    printf "%s%s•%s %s\n" "$(_anodizer_indent "${2:-0}")" "${_ANODIZER_BOLD_YELLOW}" "${_ANODIZER_RESET}" "$1" >&2
}

# Dimmed subordinate value (path / version) under a header — a `•` detail
# whose text is dimmed so it fades behind the success line above it.
# Backslashes are normalized to forward slashes for display consistency.
#   anodizer::detail "C:\\foo/bar"
#   →    • C:/foo/bar
anodizer::detail() {
    printf "%s%s•%s %s%s%s\n" \
        "$(_anodizer_indent "${2:-0}")" \
        "${_ANODIZER_CYAN}" "${_ANODIZER_RESET}" \
        "${_ANODIZER_DIM}" "$(anodizer::norm_path "$1")" "${_ANODIZER_RESET}"
}

# Run a noisy subprocess quietly: capture stdout+stderr, print nothing on
# success, and surface the full captured output only when the command fails
# (then propagate its exit status). This keeps the apt/curl/sha256sum/syft/
# cosign chatter out of a green run while preserving every byte for a red one.
#
# Escape hatch: when RUNNER_DEBUG=1 (GitHub Actions step-debug) or
# ANODIZER_VERBOSE is set, the command runs with its output passed straight
# through live — nothing is swallowed when a human is actively debugging.
#
#   anodizer::run_quiet sudo apt-get install -yq foo
anodizer::run_quiet() {
    if [ "${RUNNER_DEBUG:-}" = "1" ] || [ -n "${ANODIZER_VERBOSE:-}" ]; then
        "$@"
        return
    fi
    local log status=0
    # mktemp's default location honours $TMPDIR and always exists; don't pin
    # it under $RUNNER_TEMP, which may not be created yet on every runner.
    log=$(mktemp 2>/dev/null) || log=$(mktemp "${TMPDIR:-/tmp}/anodizer-run.XXXXXX")
    # Capture the command's own exit before the `if` overwrites $?.
    "$@" > "$log" 2>&1 || status=$?
    if [ "$status" -ne 0 ]; then
        cat "$log" >&2
    fi
    rm -f "$log"
    return "$status"
}

# Dimmed key/value detail child — a `•` line whose dimmed key is separated
# from the value by two spaces (no glyph), matching the CLI's `kv` row.
#   anodizer::kv targets "x86_64-unknown-linux-gnu"
#   →    • targets  x86_64-unknown-linux-gnu
anodizer::kv() {
    local key="$1"
    shift
    printf "%s%s•%s %s%s%s  %s\n" \
        "$(_anodizer_indent 0)" \
        "${_ANODIZER_CYAN}" "${_ANODIZER_RESET}" \
        "${_ANODIZER_DIM}" "${key}" "${_ANODIZER_RESET}" \
        "$*"
}

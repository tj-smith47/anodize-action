#!/usr/bin/env bash
# audit-output-discipline.sh — enforce the action's output-containment rule so
# the `info: component rust-std is up to date`-class leak cannot regress after
# a one-site fix.
#
# THE RULE: a chatty-on-success subprocess (one that prints progress/info to
# the terminal even when it succeeds, with no quiet-by-default) MUST be
# contained at the default verbosity. A line is "contained" when ANY holds:
#
#   • it runs through `anodizer::run_quiet` (captures, prints only on failure),
#   • it sits inside a `gha_section`/`gha_group_begin` … `gha_group_end` block
#     (its noise collapses into a ::group::),
#   • its output is redirected (`>/dev/null`, `2>&1`, `2>/dev/null`) or
#     captured / piped (`$(…)`, `| consumer`), so nothing reaches the log,
#   • it carries a trailing `# bare-ok: <why>` marker (an explicit, reviewed
#     escape hatch — the human asserts this invocation is intentionally bare).
#
# An unmarked, uncontained chatty command at command position is a violation.
# Libraries under scripts/lib/ are exempt: they DEFINE the primitives.
#
# Wired into `task lint` (precondition of `task commit`) and the Test workflow.
set -euo pipefail

root="${1:-scripts}"

# NUL-safe, sorted file list (deterministic output; tolerates spaces in paths).
mapfile -d '' -t files < <(find "$root" -name '*.sh' -print0 | sort -z)
[ ${#files[@]} -gt 0 ] || { echo "output-discipline audit: no scripts under '$root'" >&2; exit 1; }

awk '
function strip_comment(s,   q, i, c, out, instr) {
    # Drop a trailing # comment, but not a # that sits inside a quoted string
    # (URLs / messages). Walk the line tracking single/double quote state.
    instr = ""; out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (instr == "") {
            if (c == "\"" || c == "'\''") { instr = c }
            else if (c == "#") { break }
        } else if (c == instr) { instr = "" }
        out = out c
    }
    return out
}
function contained(code) {
    if (code ~ /anodizer::run_quiet/)   return 1   # the sanctioned wrapper
    if (code ~ /> ?\/dev\/null/)        return 1   # stdout discarded
    if (code ~ /2> ?\/dev\/null/)       return 1   # stderr discarded
    if (code ~ /2>&1/)                  return 1   # streams merged (usu. + capture)
    if (code ~ /\$\(/)                  return 1   # command substitution capture
    if (code ~ /[|][ \t]/)             return 1   # piped into a consumer
    return 0
}
BEGIN {
    # Command position: start of a simple command — line start, or right after
    # a shell operator / opener. Optional sudo / env VAR=val prefixes allowed.
    pre  = "(^|;|&|[|]|\\(|\\{|`|\\$\\()[ \t]*(sudo[ \t]+)?(env([ \t]+[A-Za-z_][A-Za-z0-9_]*=[^ \t]+)+[ \t]+)?"
    # Chatty-on-success tools with no quiet-by-default — the leak-prone set.
    # Trailing boundary is an explicit non-word class (NOT \b: gawk reads \b in
    # a regex as a literal backspace, which silently disables the match). This
    # also excludes longer tokens — `make` must not fire on `makeself`/`makensis`.
    deny = "(rustup|cargo[ \t]+(build|install)|apt-get|brew[ \t]+install|choco[ \t]+install|npm[ \t]+(install|ci)|pipx[ \t]+install|pip[ \t]+install|snap[ \t]+install|make|git[ \t]+clone|gpg[ \t]+--import)([^A-Za-z0-9_]|$)"
    rx   = pre deny
    fails = 0
}
FNR == 1 { depth = 0; cont = ""; startline = 0 }
{
    raw = $0
    if (cont == "") startline = FNR
    # Join line-continuations into one logical line (run_quiet often leads a
    # continued invocation).
    if (raw ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", raw); cont = cont raw " "; next }
    logical = cont raw; cont = ""

    # libs define the primitives, and this auditor necessarily embeds the
    # denylisted tool names in its own pattern strings — neither is auditable.
    if (FILENAME ~ /\/lib\// || FILENAME ~ /output-discipline\.sh$/) next

    # Explicit, reviewed escape hatch.
    if (logical ~ /#[ \t]*bare-ok:/) next

    code = strip_comment(logical)
    if (code ~ /^[ \t]*$/) next

    # Track collapsible-group depth on real (command-position) directives only,
    # so a comment mentioning gha_section cannot skew the count.
    if (code ~ /^[ \t]*(gha_section|gha_group_begin)([ \t]|$)/) { depth++; next }
    if (code ~ /^[ \t]*gha_group_end([ \t]|$)/) { if (depth > 0) depth--; next }
    if (depth > 0) next            # inside a ::group:: — noise is contained

    if (match(code, rx) && !contained(code)) {
        sub(/^[ \t]+/, "", code)
        printf "%s:%d: bare chatty subprocess — route via anodizer::run_quiet, a gha_section group, redirect/capture, or annotate `# bare-ok: <why>`\n      %s\n", FILENAME, startline, code > "/dev/stderr"
        fails++
    }
}
END {
    if (fails > 0) {
        printf "\noutput-discipline audit: %d violation(s) — see scripts/lib/colors.sh::anodizer::run_quiet\n", fails > "/dev/stderr"
        exit 1
    }
    print "output-discipline audit: clean"
}
' "${files[@]}"

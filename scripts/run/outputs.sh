#!/usr/bin/env bash
# Surface anodizer's build outputs as step outputs:
#   - artifacts / metadata: full JSON files from dist/, framed with a
#     heredoc-style delimiter so a missing trailing newline doesn't
#     break GHA's output parser.
#   - release-url:          extracted from metadata.json.release_url.
#   - crates / versions:    parsed from `anodizer-output` markers tee'd
#     to $ANODIZER_STDOUT_LOG. Last marker wins so retry-loop
#     re-emissions overwrite earlier partials. Values are jq-validated
#     before acceptance — an invalid JSON value would fail silently in
#     downstream `fromJson()` callers.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/gha.sh"

# Heredoc-frame a file into a multi-line step output. Caller passes the
# output key and the file path.
emit_file_output() {
    local key="$1" file="$2"
    {
        echo "${key}<<ANODIZER_EOF"
        cat "$file"
        echo ""
        echo "ANODIZER_EOF"
    } >> "$GITHUB_OUTPUT"
}

# Extract the last `anodizer-output <key>=<value>` marker matching `pattern`
# from the captured stdout log; emit `<key>=<value>` (or default) as a step
# output. Last-wins overwrites retry-loop partials; jq -e rejects malformed
# JSON before it can break downstream `fromJson()`.
emit_marker_output() {
    local key="$1" default="$2" pattern="$3" value="$default" last
    if [ -f "$ANODIZER_STDOUT_LOG" ]; then
        last=$(grep -oP "(?<=^anodizer-output ${key}=)${pattern}" "$ANODIZER_STDOUT_LOG" | tail -1 || true)
        if [ -n "$last" ] && echo "$last" | jq -e . >/dev/null 2>&1; then
            value="$last"
        fi
    fi
    gha_set_output "$key" "$value"
}

resolve_dist_dir() {
    local cfg d
    for cfg in .anodizer.yaml .anodizer.yml anodizer.yaml anodizer.yml; do
        [ -f "$cfg" ] || continue
        d=$(grep -E '^dist:' "$cfg" | head -1 | sed 's/^dist:\s*//' | tr -d '"' | tr -d "'")
        [ -n "$d" ] && { echo "$d"; return; }
        break
    done
    echo "dist"
}

dist=$(resolve_dist_dir)

[ -f "${dist}/artifacts.json" ] && emit_file_output artifacts "${dist}/artifacts.json"

if [ -f "${dist}/metadata.json" ]; then
    emit_file_output metadata "${dist}/metadata.json"
    url=$(jq -r '.release_url // empty' "${dist}/metadata.json" 2>/dev/null || echo "")
    gha_set_output release-url "$url"
fi

emit_marker_output crates   "[]" '\[.*\]'
emit_marker_output versions "{}" '\{.*\}'

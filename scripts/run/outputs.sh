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
    local key="$1" default="$2" pattern="$3" last
    local value="$default"
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

# `anodizer tag` (single-crate / lockstep path) prints bare `new_tag=`,
# `old_tag=`, and `part=` lines — the github-tag-action-compatible format,
# distinct from the per-crate `anodizer-output` markers above. Surfacing them
# lets a workflow_run-style release pipeline gate on whether a tag was cut
# straight from the action instead of re-deriving it from git. Last line wins.
read_bare_marker() {
    [ -f "$ANODIZER_STDOUT_LOG" ] || { printf ''; return; }
    grep -oP "(?<=^$1=).*" "$ANODIZER_STDOUT_LOG" | tail -1 || true
}
new_tag=$(read_bare_marker new_tag)
old_tag=$(read_bare_marker old_tag)
gha_set_output new-tag "$new_tag"
gha_set_output old-tag "$old_tag"
gha_set_output part    "$(read_bare_marker part)"

# tagged: a new tag was actually cut. True when new-tag is non-empty and differs
# from the previous tag (covers first release where old-tag is empty, and custom
# tags); false on a no-op run where anodizer prints new_tag == old_tag.
if [ -n "$new_tag" ] && [ "$new_tag" != "$old_tag" ]; then
    gha_set_output tagged true
else
    gha_set_output tagged false
fi

# HEAD after `anodizer tag --push` is the tag target (the version-sync bump
# commit, or the original HEAD when no bump was needed), so downstream jobs can
# check out exactly what the tag points at.
gha_set_output head-sha "$(git rev-parse HEAD 2>/dev/null || true)"

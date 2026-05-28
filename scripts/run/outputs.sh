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

dist="dist"
for cfg in .anodizer.yaml .anodizer.yml anodizer.yaml anodizer.yml; do
    if [ -f "$cfg" ]; then
        d=$(grep -E '^dist:' "$cfg" | head -1 | sed 's/^dist:\s*//' | tr -d '"' | tr -d "'")
        [ -n "$d" ] && dist="$d"
        break
    fi
done

if [ -f "${dist}/artifacts.json" ]; then
    {
        echo "artifacts<<ANODIZER_EOF"
        cat "${dist}/artifacts.json"
        echo ""
        echo "ANODIZER_EOF"
    } >> "$GITHUB_OUTPUT"
fi

if [ -f "${dist}/metadata.json" ]; then
    {
        echo "metadata<<ANODIZER_EOF"
        cat "${dist}/metadata.json"
        echo ""
        echo "ANODIZER_EOF"
    } >> "$GITHUB_OUTPUT"

    url=$(jq -r '.release_url // empty' "${dist}/metadata.json" 2>/dev/null || echo "")
    echo "release-url=${url}" >> "$GITHUB_OUTPUT"
fi

crates="[]"
if [ -f "$ANODIZER_STDOUT_LOG" ]; then
    last=$(grep -oP '(?<=^anodizer-output crates=)\[.*\]' "$ANODIZER_STDOUT_LOG" | tail -1 || true)
    if [ -n "$last" ] && echo "$last" | jq -e . >/dev/null 2>&1; then
        crates="$last"
    fi
fi
echo "crates=${crates}" >> "$GITHUB_OUTPUT"

versions="{}"
if [ -f "$ANODIZER_STDOUT_LOG" ]; then
    last=$(grep -oP '(?<=^anodizer-output versions=)\{.*\}' "$ANODIZER_STDOUT_LOG" | tail -1 || true)
    if [ -n "$last" ] && echo "$last" | jq -e . >/dev/null 2>&1; then
        versions="$last"
    fi
fi
echo "versions=${versions}" >> "$GITHUB_OUTPUT"

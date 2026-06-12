#!/usr/bin/env bash
# shellcheck shell=bash
# Anodizer config discovery + dist-dir resolution, shared by every script
# that reads or writes the build output tree.
#
# The anodizer binary discovers six config filenames — YAML and TOML — in
# a fixed priority order (crates/cli/src/pipeline/config_loader.rs in the
# anodizer repo). Probing a subset here would silently degrade
# TOML-configured projects, so the candidate list and order must mirror
# the binary exactly.
#
# Source-and-call:
#
#   source "${GITHUB_ACTION_PATH}/scripts/lib/config.sh"
#   cfg=$(find_anodizer_config)   # first match in binary order; rc=1 if none
#   dist=$(resolve_dist_dir)      # configured `dist` value, default "dist"

ANODIZER_CONFIG_CANDIDATES=(
    .anodizer.yaml
    .anodizer.yml
    .anodizer.toml
    anodizer.yaml
    anodizer.yml
    anodizer.toml
)

# Echo the first config candidate present in the current directory.
# Returns 1 (echoing nothing) when no config exists.
find_anodizer_config() {
    local candidate
    for candidate in "${ANODIZER_CONFIG_CANDIDATES[@]}"; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# True when the config file (`$1`) is TOML, by extension — the same
# dispatch the binary uses.
anodizer_config_is_toml() {
    case "$1" in
        *.toml) return 0 ;;
        *) return 1 ;;
    esac
}

# Echo the top-level `dist` value from config `$1` (YAML `dist:` /
# TOML `dist =`), comments and quotes stripped. Echoes nothing when unset.
anodizer_config_dist_value() {
    local cfg="$1" d=""
    if anodizer_config_is_toml "$cfg"; then
        # TOML top-level keys must precede the first table header, so the
        # scan stops at the first `[...]` line — a `dist =` inside a table
        # like `[archives]` must never be mistaken for the top-level key.
        d=$(sed -n '/^[[:space:]]*\[/q;p' "$cfg" \
            | grep -E '^dist[[:space:]]*=' | head -1 \
            | sed -E 's/^dist[[:space:]]*=[[:space:]]*//')
    else
        d=$(grep -E '^dist:' "$cfg" | head -1 \
            | sed -E 's/^dist:[[:space:]]*//')
    fi
    d="${d%%#*}"
    d=$(echo "$d" | tr -d '"' | tr -d "'" | xargs)
    if [ -n "$d" ]; then
        echo "$d"
    fi
}

# Echo the dist directory the anodizer run will use in the current
# directory: the configured `dist` value when a config sets one, else the
# binary's default "dist".
resolve_dist_dir() {
    local cfg d
    if cfg=$(find_anodizer_config); then
        d=$(anodizer_config_dist_value "$cfg")
        if [ -n "$d" ]; then
            echo "$d"
            return
        fi
    fi
    echo "dist"
}

#!/usr/bin/env bash
# Parse the anodizer config in the workdir (YAML or TOML — the binary
# discovers both) and emit `deps=<csv>` listing the build/pipeline
# dependencies the configured stages need.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/gha.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"

anodizer::verb Detecting "pipeline dependencies"

deps=()
if ! cfg=$(find_anodizer_config); then
    gha_warning "auto-install: no anodizer config found, skipping"
    anodizer::warn "no anodizer config found; nothing to auto-install"
    gha_set_output deps ""
    exit 0
fi

is_toml=false
anodizer_config_is_toml "$cfg" && is_toml=true

# True when the config declares the installer/packager BLOCK `$1` either at
# top level (single-crate flat config) OR nested under a crate entry
# (workspace per-crate config: `crates:` → crate → indented `key:` in YAML,
# `[[crates.<name>.key]]` / `[crates.<name>.key]` table headers in TOML).
# The key is anchored right after the leading whitespace (YAML) or bracket /
# `crates.<name>.` prefix (TOML) so e.g. `signs` never matches `binary_signs:`
# / `docker_signs:` and `pkgs` never matches a longer key like `app_bundles:`.
has_cfg_block() {
    if [ "$is_toml" = true ]; then
        grep -qE "^${1}[[:space:]]*=|^\[\[?${1}[].]|^\[\[?crates\.[^]]*\.${1}[].]" "$cfg"
    else
        grep -qE "^[[:space:]]*${1}:" "$cfg"
    fi
}

# True when `$1` is assigned value `$2` anywhere in the config — YAML
# `key: value` / TOML `key = "value"` — at any nesting depth. The value is
# end-anchored (closing quote, whitespace, or EOL) so a prefix match never
# fires: `cmd: cosignx` / `cmd: cosign-foo` must NOT pull `cosign`. Either
# quote style is accepted: a single-quoted YAML scalar (`cmd: 'cosign'`) is as
# valid as double-quoted, so the optional leading quote and the closing-quote
# end-anchor both admit `'` and `"`.
has_kv() {
    if [ "$is_toml" = true ]; then
        grep -qE "${1}[[:space:]]*=[[:space:]]*['\"]?${2}(['\"]|[[:space:]]|$)" "$cfg"
    else
        grep -qE "${1}:[[:space:]]*['\"]?${2}(['\"]|[[:space:]]|$)" "$cfg"
    fi
}

# nfpm (deb/rpm/apk), makeself (.run self-extractor), snapcraft (snap) and
# rpmbuild (source RPM) all produce Linux-only package formats and are
# provisioned via Linux package managers — none has a Windows path, and the
# determinism Windows/macOS shards never run these stages. Emit the dep on
# Linux; warn (don't fail) elsewhere, mirroring flatpaks/appimages. (A Windows
# shard with auto-install previously emitted `nfpm` unconditionally, which the
# dispatcher tried to `choco install` — nfpm has no choco package — and the
# install hard-failed before anodizer ran.)
add_linux_pkg_dep() {
    if [ "${RUNNER_OS:-}" = "Linux" ]; then
        deps+=("$1")
    else
        anodizer::vdetail "skipped $1: Linux-only package format (got ${RUNNER_OS:-unset})"
    fi
}
if has_cfg_block nfpm || has_kv name anodizer-stage-nfpm; then add_linux_pkg_dep nfpm; fi
has_cfg_block makeselfs && add_linux_pkg_dep makeself || true
has_cfg_block snapcrafts && add_linux_pkg_dep snapcraft || true
has_cfg_block srpm && add_linux_pkg_dep rpmbuild || true
# True when the config sets a `cmd:` whose value is `cosign` or a `cosign-*`
# variant (e.g. `cosign-fips`). Mirrors anodizer's `is_cosign_cmd` in
# crates/stage-sign/src/process.rs, which tests the cmd BASENAME with
# `starts_with("cosign")` — so `cosign-foo` is a cosign binary too. A bare
# `cosign` is also a variant of itself. The value is anchored so `cosignx`
# (no separator) still matches the `cosign` prefix per `is_cosign_cmd`, while a
# DIFFERENT tool like `gpg` never does. Used only by the preflight key-LOAD
# detection below, where a co-occurring `env://` ref is the discriminator —
# the bare-tool install logic keeps its stricter exact `has_kv cmd cosign`.
has_cosign_variant_cmd() {
    if [ "$is_toml" = true ]; then
        grep -qE "cmd[[:space:]]*=[[:space:]]*['\"]?cosign" "$cfg"
    else
        grep -qE "cmd:[[:space:]]*['\"]?cosign" "$cfg"
    fi
}

# True when the config references cosign key material via the `env://VAR`
# scheme (verified against crates/core/src/env_preflight.rs::env_scheme_refs,
# which scans for the literal `env://`). In an anodizer config this scheme is
# cosign-key-specific — it only appears in a sign block's args/env/stdin/
# certificate — so its presence alongside a cosign cmd reconstructs exactly the
# `cosign_key_refs()` set `release --preflight-secrets` load-verifies.
config_has_env_scheme_ref() {
    grep -qF 'env://' "$cfg"
}

# cosign falls into the dep set for two distinct reasons; both resolve here.
#
# (1) SIGN-STAGE TOOL — cosign must be on PATH because the sign stage will spawn
#     it. anodizer's per-block default `cmd:` differs by sign type (verified
#     against crates/core/src/signing.rs + crates/stage-sign/src/helpers.rs):
#       - `signs:` / `binary_signs:` (SignConfig) DEFAULT TO GPG when `cmd:` is
#         unset — default_sign_cmd reads `git config gpg.program`, falling back
#         to literal `gpg`. They need cosign only when `cmd: cosign` is set.
#       - `docker_signs:` (DockerSignConfig) has a STATIC cosign default
#         (DEFAULT_CMD = "cosign") — it needs cosign even with no `cmd:` line.
#     So: install cosign when any block sets exactly `cmd: cosign`, OR when a
#     `docker_signs:` block is present at all. GPG needs no installer (it is
#     pre-installed on every runner image), so `binary_signs:` with `cmd: gpg`
#     correctly pulls nothing.
#
# (2) PREFLIGHT KEY-LOAD — when the action runs `release --preflight-secrets`,
#     preflight offline load-verifies EVERY cosign key the config references
#     (crates/cli/src/commands/preflight.rs::cosign_key_refs → a `KeyEnv{Cosign}`
#     per `env://VAR` ref under a cosign-cmd block, emitted by stage-sign's
#     entry_env_requirements). If cosign is absent the check WARN-skips
#     (silent false-green: a bad COSIGN_PASSWORD slips past the pre-tag gate).
#     anodizer's `is_cosign_cmd` matches any `cosign*` BASENAME, so a
#     `cmd: cosign-fips` (or any variant) bearing an `env://` key is a cosign
#     key reference the exact `has_kv cmd cosign` probe above misses. Cover the
#     full set: install cosign whenever a cosign-variant cmd co-occurs with an
#     `env://` key ref — exactly the shapes `cosign_key_refs()` enumerates.
#
#     Both probes are decoupled WHOLE-FILE greps, so a `cosign-*` cmd in one
#     block plus an `env://` ref in an UNRELATED block also triggers the
#     install. That over-install is INTENTIONAL and kept consistent with the
#     bare `has_kv cmd cosign` rule above (itself a whole-file value match): a
#     cosign install is idempotent and cheap, so block-scoping this one probe
#     would make it stricter than its sibling — an inconsistent asymmetry that
#     buys no real safety while adding awk block-extraction complexity. Pinned
#     by the cosign-keyload bats suite so the behavior is codified, not accident.
need_cosign=""
has_kv cmd cosign && need_cosign=1
[ -z "$need_cosign" ] && has_cfg_block docker_signs && need_cosign=1
[ -z "$need_cosign" ] && has_cosign_variant_cmd && config_has_env_scheme_ref && need_cosign=1
[ -n "$need_cosign" ] && deps+=("cosign") || true

# Print only the lines belonging to a `sboms:` block, whether top-level
# (single-crate flat config) or nested under a crate entry (workspace
# per-crate config). The block runs from the `sboms:` header to the next line
# indented at or below the header's own indentation. Mirrors `msis_block`.
sboms_block() {
    awk '
        !inblock && /^[[:space:]]*sboms:/ {
            match($0, /^[[:space:]]*/); hdr = RLENGTH
            inblock = 1; next
        }
        inblock {
            match($0, /^[[:space:]]*/)
            if ($0 ~ /[^[:space:]]/ && RLENGTH <= hdr) { inblock = 0 }
        }
        inblock { print }
    ' "$cfg"
}

# Resolve the generator tool a SINGLE `sboms:` list entry needs, mirroring
# crates/stage-sbom/src/lib.rs (`use_builtin = cmd.is_none() && args.is_none()`)
# + crates/core/src/config/sbom.rs (`resolved_cmd()` defaults to `syft`):
#   - entry has a `cmd:` line   → echo its value verbatim (the spawned binary)
#   - entry has `args:` but no `cmd:` → echo `syft` (the default generator)
#   - entry has neither          → builtin generator, echo nothing
# `$1` is the entry's text. Reads the YAML shape (anodizer's sboms: is YAML in
# practice); the TOML path is resolved separately below.
detect_sbom_entry_tool() {
    local entry="$1" cmd
    # Strip a trailing ` # …` YAML inline comment before trimming, or the
    # comment text leaks into the dep name (`cmd: cyclonedx # gen` → `cyclonedx`).
    cmd=$(printf '%s\n' "$entry" \
        | grep -E '^[[:space:]]*(-[[:space:]]+)?cmd:[[:space:]]*' \
        | sed -E 's/^[[:space:]]*(-[[:space:]]+)?cmd:[[:space:]]*//' \
        | sed -E 's/[[:space:]]+#.*$//' \
        | tr -d '"' | tr -d "'" | head -1 | xargs || true)
    if [ -n "$cmd" ]; then
        echo "$cmd"
        return
    fi
    if printf '%s\n' "$entry" | grep -qE '^[[:space:]]*(-[[:space:]]+)?args:'; then
        echo "syft"
    fi
    # Neither cmd: nor args: → builtin generator, no external tool.
}

# Resolve the DISTINCT generator tools the whole `sboms:` config needs. Splits
# the YAML block on `- ` list markers (one entry per generator), or scopes each
# TOML `[[sboms]]` / `[[crates.<n>.sboms]]` table, resolves each, and prints
# every distinct tool on its own line. A builtin-only config prints nothing.
detect_sbom_tools() {
    has_cfg_block sboms || return 0
    local seen=""
    local tool
    if [ "$is_toml" = true ]; then
        # Per TOML sbom table: read `cmd = "X"` (→ X) else `args = …` (→ syft)
        # else builtin (→ nothing). awk scopes each table from its `[[…sboms]]`
        # header to the next table header.
        while IFS= read -r tool; do
            [ -z "$tool" ] && continue
            case ",$seen," in *",$tool,"*) continue ;; esac
            seen="${seen:+$seen,}$tool"
            echo "$tool"
        done < <(
            awk '
                /^\[\[?([^]]*\.)?sboms[].]/ {
                    if (intable) emit()
                    intable = 1; cmd = ""; hasargs = 0; next
                }
                /^\[/ { if (intable) { emit(); intable = 0 } }
                intable && /^[[:space:]]*cmd[[:space:]]*=/ {
                    line = $0
                    sub(/^[[:space:]]*cmd[[:space:]]*=[[:space:]]*/, "", line)
                    # Strip a trailing ` # …` inline comment before quote/space
                    # trimming, or `cmd = "cyclonedx" # gen` leaks the comment.
                    sub(/[[:space:]]+#.*$/, "", line)
                    gsub(/"/, "", line); gsub(/\047/, "", line)
                    sub(/[[:space:]]+$/, "", line)
                    cmd = line
                }
                intable && /^[[:space:]]*args[[:space:]]*=/ { hasargs = 1 }
                END { if (intable) emit() }
                function emit() {
                    if (cmd != "") print cmd
                    else if (hasargs) print "syft"
                }
            ' "$cfg"
        )
        return 0
    fi
    local block entry
    block=$(sboms_block)
    while IFS= read -r tool; do
        [ -z "$tool" ] && continue
        case ",$seen," in *",$tool,"*) continue ;; esac
        seen="${seen:+$seen,}$tool"
        echo "$tool"
    done < <(
        printf '%s\n' "$block" | awk '
            /^[[:space:]]*-[[:space:]]/ {
                if (entry != "") print entry "\036"
                entry = $0 "\n"; next
            }
            { entry = entry $0 "\n" }
            END { if (entry != "") print entry "\036" }
        ' | while IFS= read -r -d $'\036' entry; do
            [ -n "$entry" ] && detect_sbom_entry_tool "$entry"
        done
    )
    # The block/entry splitter keys off the `- ` block-style list marker; it
    # does NOT parse FLOW-style YAML (`sboms: [{cmd: cyclonedx}]`), so such a
    # block resolves to ZERO tools and would silently install nothing — a
    # configured generator absent at runtime. When the list is declared inline-
    # flow on the `sboms:` header (a `[` immediately after the colon) yet the
    # resolver found none, fall back to the default generator `syft` so the
    # stage has SOME generator on PATH rather than failing mid-run. The probe is
    # anchored to the header (not a bare `[` anywhere in the block) so a block-
    # style entry whose VALUE is a flow scalar — e.g. `documents: ["x.json"]` on
    # a builtin entry — does NOT spuriously trigger the fallback. (Full flow-
    # style parsing is out of scope; a custom `cmd:` inside flow YAML still needs
    # explicit `install:`. sboms_block consumes the header line, so probe $cfg.)
    if [ -z "$seen" ] && grep -qE '^[[:space:]]*sboms:[[:space:]]*\[' "$cfg"; then
        echo "syft"
    fi
}

# notarize.macos:[] drives the CROSS-PLATFORM signing/notarization path, which
# shells out to `rcodesign` (the apple-codesign project) — verified against
# crates/stage-notarize/src/run.rs (spawns "rcodesign") and
# crates/core/src/config/notarize.rs (NotarizeConfig.macos →
# MacOSSignNotarizeConfig, rcodesign-based, works on ANY OS). The sibling
# `notarize.macos_native:[]` path uses codesign + xcrun notarytool — present on
# macOS runners, no installer needed — so only `macos:` triggers rcodesign.
# YAML nests both keys (indented) under a top-level `notarize:` block; TOML
# spells the same shape as `[[notarize.macos]]` / `[notarize.macos]` headers,
# a dotted `notarize.macos =` key, or a bare `macos =` inside `[notarize]`.
# Every regex requires a non-word char right after `macos`, so `macos_native`
# never matches. rcodesign runs cross-platform; no OS guard.
notarize_macos_configured() {
    if [ "$is_toml" = true ]; then
        grep -qE '^\[\[?notarize\.macos[].]' "$cfg" && return 0
        grep -qE '^notarize\.macos[[:space:]]*=' "$cfg" && return 0
        grep -qE '^\[notarize\]' "$cfg" && grep -qE '^[[:space:]]*macos[[:space:]]*=' "$cfg" && return 0
        return 1
    fi
    grep -qE '^notarize:' "$cfg" && grep -qE '^[[:space:]]+macos:[[:space:]]*$' "$cfg"
}
if notarize_macos_configured; then
    deps+=("rcodesign")
fi
# npms: publishes an npm metapackage via `npm publish` (Trusted Publishing
# OIDC), which needs node/npm on PATH. npm publish runs on any runner OS, so
# no OS guard.
has_cfg_block npms && deps+=("node") || true
# sboms: the generator is per-block (verified against
# crates/stage-sbom/src/lib.rs + crates/core/src/config/sbom.rs):
#   - NO `cmd:` AND NO `args:`  → the BUILTIN Cargo.lock generator runs
#     (`use_builtin = cmd.is_none() && args.is_none()`); it shells out to
#     nothing, so NO external tool is installed.
#   - `cmd: <X>`                → anodizer spawns `<X>` verbatim
#     (`resolved_cmd()`); install THAT binary (syft when `cmd: syft`, the
#     named tool otherwise — e.g. `cyclonedx`).
#   - `args:` present, no `cmd:` → `resolved_cmd()` falls back to the default
#     `syft` (DEFAULT_CMD), so syft is installed.
# Emits one dep per distinct generator the block(s) request; a builtin-only
# config emits nothing here.
while IFS= read -r _sbom_tool; do
    [ -n "$_sbom_tool" ] && deps+=("$_sbom_tool")
done < <(detect_sbom_tools)
# blobs: a `kms_key:` with a URL scheme drives CLIENT-SIDE KMS encryption,
# which shells out to a cloud CLI before upload (verified against
# crates/stage-blob/src/kms.rs: parse_kms_provider + kms_cli_program):
#   - `awskms://…`        → aws
#   - `gcpkms://…`        → gcloud
#   - `azurekeyvault://…` → az
# A plain key ARN/ID with NO scheme means SERVER-SIDE SSE-KMS (S3 does the
# encryption), so no CLI is provisioned. The cloud CLI runs on any runner OS,
# so no OS guard. `kms_key:` only appears inside a `blobs:` block, so a direct
# value probe is sufficient — no block scoping needed.
if has_cfg_block blobs; then
    if has_kv kms_key 'awskms://[^[:space:]"]*'; then deps+=("aws"); fi
    if has_kv kms_key 'gcpkms://[^[:space:]"]*'; then deps+=("gcloud"); fi
    if has_kv kms_key 'azurekeyvault://[^[:space:]"]*'; then deps+=("az"); fi
fi
has_cfg_block upx && deps+=("upx") || true
# nsis builds on every platform (makensis: nsis apt on Linux, brew on macOS,
# choco on Windows), so it emits unconditionally.
has_cfg_block nsis && deps+=("nsis") || true
# dmgs: a .dmg builds on macOS (hdiutil) and Linux (genisoimage) but has no
# Windows path — warn (don't fail) and omit there, like pkgs.
if has_cfg_block dmgs; then
    if [ "${RUNNER_OS:-}" = "Windows" ]; then
        anodizer::vdetail "skipped dmgs: needs macOS hdiutil or Linux genisoimage (got Windows)"
    else
        deps+=("create-dmg")
    fi
fi
# flatpaks: Flatpak is Linux-only — emit on Linux, warn (don't fail) elsewhere,
# like appimages.
if has_cfg_block flatpaks; then
    if [ "${RUNNER_OS:-}" = "Linux" ]; then
        deps+=("flatpak")
    else
        anodizer::vdetail "skipped flatpaks: requires a Linux runner (got ${RUNNER_OS:-unset})"
    fi
fi
# appimages: shells out to linuxdeploy + its appimage output plugin, both
# Linux-only AppImages — emit the dep on Linux, warn (don't fail) elsewhere.
if has_cfg_block appimages; then
    if [ "${RUNNER_OS:-}" = "Linux" ]; then
        deps+=("linuxdeploy")
    else
        anodizer::vdetail "skipped appimages: requires a Linux runner (got ${RUNNER_OS:-unset})"
    fi
fi
# alejandra is only needed when the nix publisher opts into it as the
# formatter (the alternative, `nixfmt`, has no auto-installer here yet).
if [ "$is_toml" = true ]; then
    grep -qE "^[[:space:]]*formatter[[:space:]]*=[[:space:]]*['\"]?alejandra['\"]?[[:space:]]*\$" "$cfg" && deps+=("alejandra") || true
else
    grep -qE '^[[:space:]]+formatter:[[:space:]]*alejandra[[:space:]]*$' "$cfg" && deps+=("alejandra") || true
fi

# pkgs: builds macOS .pkg installers — native pkgbuild on macOS, the Linux flat
# XAR toolchain (xar + mkbom) on Linux. Either host can produce the artifact, so
# emit the dep on both; only Windows lacks a path.
if has_cfg_block pkgs; then
    if [ "${RUNNER_OS:-}" = "Windows" ]; then
        anodizer::vdetail "skipped pkgs: needs macOS pkgbuild or the Linux flat-package toolchain (got Windows)"
    else
        deps+=("pkgbuild")
    fi
fi
# Print only the lines belonging to a `msis:` block, whether it sits at the
# top level (single-crate flat config) or nested under a crate entry (workspace
# per-crate config). The block runs from the `msis:` header to the next line
# indented at or below the header's own indentation, so a `version:` or `wxs:`
# sniff cannot pick up a sibling block's key. The leading-whitespace anchor
# requires `msis:` immediately after the indent, so a longer key never matches.
msis_block() {
    awk '
        !inblock && /^[[:space:]]*msis:/ {
            match($0, /^[[:space:]]*/); hdr = RLENGTH
            inblock = 1; next
        }
        inblock {
            match($0, /^[[:space:]]*/)
            if ($0 ~ /[^[:space:]]/ && RLENGTH <= hdr) { inblock = 0 }
        }
        inblock { print }
    ' "$cfg"
}

# Resolve the WiX dialect of a SINGLE `msis:` list entry, mirroring
# crates/stage-msi's WixVersion logic so the Windows install matches the
# toolchain the stage actually runs:
#   - explicit `version: v3` / `wixl` / `linux`  → `wix3` (candle+light)
#   - explicit `version: v4`                     → `wix`  (v4 `wix build`)
#   - no version → sniff the referenced `wxs:` file's XML namespace:
#       `http://schemas.microsoft.com/wix/2006/wi` (v3) → `wix3`, else `wix`
# Linux installs `wixl` for either token, so the distinction only changes the
# Windows toolchain. anodizer's msis: is a YAML-only block in practice, so the
# sniff reads the YAML shape. `$1` is the entry's text (version/wxs lines).
detect_entry_dialect() {
    local entry="$1" version wxs
    # Strip a trailing ` # …` YAML inline comment before trimming so a comment
    # never leaks into the resolved dialect token (`version: v3 # legacy`).
    version=$(printf '%s\n' "$entry" \
        | grep -E '^[[:space:]]*(-[[:space:]]+)?version:[[:space:]]*' \
        | sed -E 's/^[[:space:]]*(-[[:space:]]+)?version:[[:space:]]*//' \
        | sed -E 's/[[:space:]]+#.*$//' \
        | tr -d '"' | tr -d "'" | head -1 | xargs || true)
    case "$(printf '%s' "$version" | tr '[:upper:]' '[:lower:]')" in
        v3|3|wixl|linux) echo "wix3"; return ;;
        v4|4)            echo "wix";  return ;;
    esac
    # No explicit version — sniff the referenced .wxs namespace.
    wxs=$(printf '%s\n' "$entry" \
        | grep -E '^[[:space:]]*(-[[:space:]]+)?wxs:[[:space:]]*' \
        | sed -E 's/^[[:space:]]*(-[[:space:]]+)?wxs:[[:space:]]*//' \
        | sed -E 's/[[:space:]]+#.*$//' \
        | tr -d '"' | tr -d "'" | head -1 | xargs || true)
    if [ -n "$wxs" ] && [ -f "$wxs" ] \
        && grep -q 'http://schemas.microsoft.com/wix/2006/wi' "$wxs"; then
        echo "wix3"; return
    fi
    # v4 namespace, unknown, or unreadable .wxs all default to v4, matching
    # WixVersion::detect_from_wxs.
    echo "wix"
}

# Resolve the DISTINCT WiX dialect tokens the whole `msis:` block needs. anodizer
# resolves WiX version per `msis:` entry (crates/stage-msi env_requirements loops
# per entry), so a mixed v3+v4 block needs BOTH toolchains. Split the block on
# the YAML `- ` list markers, resolve each entry, and print each distinct token
# (`wix` and/or `wix3`) on its own line. The dispatch loop + _APT_BATCHED_DEPS
# tolerate both.
detect_msi_dialects() {
    local block emitted_wix="" emitted_wix3=""
    block=$(msis_block)
    # Group the block into per-entry chunks: a line starting (after indent) with
    # the `- ` list marker opens a new entry; intervening indented lines belong
    # to it. A block with no `- ` marker is treated as a single entry.
    local token
    while IFS= read -r token; do
        case "$token" in
            wix3) emitted_wix3=1 ;;
            wix)  emitted_wix=1 ;;
        esac
    done < <(
        printf '%s\n' "$block" | awk '
            /^[[:space:]]*-[[:space:]]/ {
                if (entry != "") print entry "\036"
                entry = $0 "\n"; next
            }
            { entry = entry $0 "\n" }
            END { if (entry != "") print entry "\036" }
        ' | while IFS= read -r -d $'\036' entry; do
            [ -n "$entry" ] && detect_entry_dialect "$entry"
        done
    )
    [ -n "$emitted_wix3" ] && echo "wix3"
    [ -n "$emitted_wix" ] && echo "wix"
}

# msis: builds MSIs. WiX itself is Windows-only and EULA-gated, so on Linux the
# msi stage uses `wixl` (msitools) from the v3-dialect .wxs. Both Windows (WiX)
# and Linux (wixl) can produce the artifact; only macOS lacks a path. The
# emitted token is dialect-aware (wix3 = v3 candle+light, wix = v4 wix build).
if has_cfg_block msis; then
    if [ "${RUNNER_OS:-}" = "macOS" ]; then
        anodizer::vdetail "skipped msis: needs WiX (Windows) or wixl (Linux) (got macOS)"
    elif [ "$is_toml" = true ]; then
        # The per-entry dialect resolver is YAML-shaped (`version:` / `wxs:`),
        # so a TOML `[[crates.<n>.msis]]` block's dialect can't be read here;
        # emit BOTH WiX majors so whichever the stage selects is on PATH (Linux
        # uses wixl for either, so the superset only adds one Windows install).
        deps+=("wix3" "wix")
    else
        # A mixed-dialect block emits both tokens (one per line); append each.
        while IFS= read -r _msi_tok; do
            [ -n "$_msi_tok" ] && deps+=("$_msi_tok")
        done < <(detect_msi_dialects)
    fi
fi

if [ "$is_toml" = true ]; then
    grep -qE "^[[:space:]]*cross[[:space:]]*=[[:space:]]*['\"]?(auto|zigbuild)['\"]?[[:space:]]*\$" "$cfg" && deps+=("zig" "cargo-zigbuild") || true
else
    grep -qE '^[[:space:]]*cross:[[:space:]]*(auto|zigbuild)[[:space:]]*$' "$cfg" && deps+=("zig" "cargo-zigbuild") || true
fi

joined=$(IFS=','; echo "${deps[*]}")
anodizer::kv detected "${joined:-none}"
gha_set_output deps "$joined"

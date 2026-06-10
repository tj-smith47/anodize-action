# Anodizer Action

GitHub Action for [Anodizer](https://github.com/tj-smith47/anodizer), a
Rust-native release automation tool inspired by GoReleaser.

The action installs anodizer (cached per version), auto-installs pipeline
dependencies (nfpm, makeself, snapcraft, rpmbuild, cosign, zig,
cargo-zigbuild, upx, nsis, create-dmg, flatpak, linuxdeploy, rcodesign, wix)
based on your
`.anodizer.yaml`, imports signing keys, logs in to container registries,
handles split/merge artifact plumbing, and runs any anodizer subcommand —
all in one step.

## Usage

### Basic release

```yaml
- uses: tj-smith47/anodizer-action@v1
  with:
    args: release --clean
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Publisher tokens

A release that only publishes back to **its own** repository — create the
GitHub Release, upload assets — works with the default `GITHUB_TOKEN`.

Publishers that open a pull request against **another** repository need a token
with write access to that repo; the default `GITHUB_TOKEN` cannot push to other
repositories. Provision a personal access token (classic `public_repo`, or a
fine-grained PAT scoped to the target repos) as a secret and pass it via `env:`.
Each publisher reads its own variable first, then falls back to
`ANODIZER_GITHUB_TOKEN`, then `GITHUB_TOKEN`:

| Publisher | Token env var | Target |
|-----------|---------------|--------|
| Homebrew | `HOMEBREW_TAP_TOKEN` | your tap repo |
| krew | `KREW_INDEX_TOKEN` | krew-index fork → PR |
| Scoop | `SCOOP_BUCKET_TOKEN` | your bucket repo |
| winget | `WINGET_PKGS_TOKEN` | winget-pkgs fork → PR |
| Nix | `NIX_PKGS_TOKEN` | your nix repo |
| SchemaStore | `SCHEMASTORE_TOKEN` | SchemaStore fork → PR |

```yaml
- uses: tj-smith47/anodizer-action@v1
  with:
    args: release
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}          # same-repo release
    SCHEMASTORE_TOKEN: ${{ secrets.SCHEMASTORE_PAT }}  # fork push + SchemaStore PR
```

The SchemaStore publisher pushes the updated catalog/schema to a fork of
`SchemaStore/schemastore` and opens a PR upstream, so `SCHEMASTORE_TOKEN` (or the
`ANODIZER_GITHUB_TOKEN` / `GITHUB_TOKEN` fallback) must be a PAT that can push to
your fork and open a pull request against the upstream repository.

### Rollback on release failure

The action does not provide an opt-in input for rollback — it's a separate step
you add to your workflow. This keeps the action's scope small and lets you
control the exact recovery shape (mode, scope, branch override).

```yaml
- name: Run anodizer release
  id: release
  uses: tj-smith47/anodizer-action@v1
  with:
    args: release
    # ... other inputs ...

- name: Rollback on release failure
  if: (failure() || cancelled()) && steps.release.outcome != 'skipped'
  env:
    GH_TOKEN: ${{ secrets.GH_PAT }}
    GITHUB_TOKEN: ${{ secrets.GH_PAT }}
  run: anodizer tag rollback "$GITHUB_SHA"
```

- `id: release` is required so the rollback step's `if:` can reference
  `steps.release.outcome`.
- The condition fires on both `failure()` and `cancelled()` — a cancelled run
  may have left a half-published tag behind.
- `anodizer tag rollback "$GITHUB_SHA"` auto-derives the branch from the bump
  SHA, so no `--branch` flag is needed in the common case (a release workflow
  triggered by an `anodizer tag` push).
- For multi-job workflows where the release runs against a tagged bump commit
  produced by an earlier job, pass the SHA explicitly (e.g.
  `${{ needs.tag.outputs.head-sha }}`, mapping the action's `head-sha` output
  through the tag job's `outputs:`) instead of `$GITHUB_SHA`.

### Auto-install dependencies from config

```yaml
- uses: tj-smith47/anodizer-action@v1
  with:
    auto-install: true
    gpg-private-key: ${{ secrets.GPG_PRIVATE_KEY }}
    args: release --clean
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    GPG_FINGERPRINT: ${{ secrets.GPG_FINGERPRINT }}
    COSIGN_KEY: ${{ secrets.COSIGN_KEY }}
    COSIGN_PASSWORD: ${{ secrets.COSIGN_PASSWORD }}
```

### Split/merge cross-platform build

`upload-dist` and `download-dist` replace the manual
`actions/upload-artifact` / `actions/download-artifact` pair for split
builds.

```yaml
jobs:
  build:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - uses: tj-smith47/anodizer-action@v1
        with:
          install-rust: true
          install: zig,cargo-zigbuild,upx
          upload-dist: true                 # uploads dist/ as dist-$RUNNER_OS
          args: release --split --clean
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

  release:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - uses: tj-smith47/anodizer-action@v1
        with:
          auto-install: true
          download-dist: true               # downloads + merges dist-* artifacts
          gpg-private-key: ${{ secrets.GPG_PRIVATE_KEY }}
          args: release --merge
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          GPG_FINGERPRINT: ${{ secrets.GPG_FINGERPRINT }}
          COSIGN_KEY: ${{ secrets.COSIGN_KEY }}
          COSIGN_PASSWORD: ${{ secrets.COSIGN_PASSWORD }}
```

### Tag-triggered monorepo release (resolve tag → crate)

```yaml
on:
  push:
    tags: ["*-v*"]

jobs:
  resolve:
    runs-on: ubuntu-latest
    outputs:
      crate: ${{ steps.a.outputs.workspace }}
      has-builds: ${{ steps.a.outputs.has-builds }}
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - uses: tj-smith47/anodizer-action@v1
        id: a
        with:
          resolve-workspace: true
          install-only: true

  release:
    needs: resolve
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - uses: tj-smith47/anodizer-action@v1
        with:
          auto-install: true
          docker-registry: ghcr.io
          docker-password: ${{ secrets.GITHUB_TOKEN }}
          args: release --crate ${{ needs.resolve.outputs.crate }} --clean
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Reuse CI-built binary across workflows

```yaml
# ci.yml — build and upload anodizer once per commit
- uses: actions/checkout@v6
- uses: dtolnay/rust-toolchain@stable
- run: cargo build --release -p anodizer
- uses: actions/upload-artifact@v4
  with:
    name: anodizer-linux
    path: target/release/anodizer

# release.yml — reuse the artifact
- uses: tj-smith47/anodizer-action@v1
  with:
    from-artifact: anodizer-linux
    artifact-run-id: auto                   # resolves latest ci.yml run for this SHA
    artifact-workflow: ci.yml
    auto-install: true
    args: release --clean
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Bootstrap from source

When `from-artifact` is only available for one platform and the current
runner needs a platform-native binary:

```yaml
- uses: tj-smith47/anodizer-action@v1
  with:
    install-rust: true
    from-source: true
    install: zig,cargo-zigbuild,upx
    args: release --split --clean
```

### Test an un-released branch of anodizer

For integration testing a downstream project against an in-flight anodizer
PR — or dogfooding a feature branch before it lands — use `from-branch`.
The action shallow-clones `tj-smith47/anodizer` at the branch you name,
builds it from source, and puts it on `PATH` for the rest of the job:

```yaml
- uses: actions/checkout@v6
- uses: tj-smith47/anodizer-action@v1
  with:
    from-branch: my-feature        # branch on tj-smith47/anodizer
    args: release --snapshot --clean
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

- Input accepts a **branch name only** — the repository is hardcoded to
  `tj-smith47/anodizer`. There is no `from-branch-repo` / `@ref` syntax.
- The Rust toolchain is auto-installed; you do not need `install-rust: true`.
- Cargo's `target/` directory is cached per branch via
  [`Swatinem/rust-cache`](https://github.com/Swatinem/rust-cache), so the
  second invocation of the same branch on a hot runner is fast.
- Clones to `${RUNNER_TEMP}/anodizer-src` — your `workdir:` is untouched.
- Mutually exclusive with `version:`, `from-artifact:`, and `from-source:`.

### Install only, drive anodizer yourself

Useful for multi-crate loops, tagging, and ad-hoc subcommands:

```yaml
- uses: tj-smith47/anodizer-action@v1
  with:
    install-only: true

- run: anodizer check
- run: anodizer healthcheck
- run: |
    for crate in my-core my-cli my-operator; do
      anodizer tag --crate "$crate" || true
    done
    git push origin HEAD
```

> ⚠️ **Legacy pattern.** The per-crate loop above predates the atomic
> workspace flow. New configs should prefer a single `args: tag` step (see
> [Workspace orchestration](#workspace-orchestration) below) which bumps,
> tags, and pushes every changed crate in one atomic commit. The loop is
> retained here only because operators on older configs may still be
> driving per-crate tagging by hand.

### Determinism harness (one-liner cross-platform shard)

`anodizer check determinism` rebuilds your pipeline N times in a hermetic
worktree and diffs the artifact digests, surfacing non-deterministic
inputs (timestamps, build-id, randomized symbol layout, …) before they
poison a release. With `determinism: true`, a 3-OS matrix collapses to
~10 lines per shard — the action handles Rust toolchain install,
cross-build deps (zig + cargo-zigbuild + upx on Linux; upx on
macOS/Windows) plus the harness's stage deps (syft for sbom, cosign for
sign), from-source build of anodizer, per-shard target-CSV derivation via
`anodizer targets --json`, `rustup target add` for each triple, and
harness invocation:

```yaml
determinism-check:
  name: Determinism Harness (${{ matrix.os }})
  strategy:
    fail-fast: false
    matrix:
      os: [ubuntu-latest, macos-latest, windows-latest]
  runs-on: ${{ matrix.os }}
  steps:
    - uses: actions/checkout@v6
      with:
        fetch-depth: 0
    - uses: tj-smith47/anodizer-action@v1
      with:
        determinism: true
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

Per-shard target lists are auto-derived from `.anodizer.yaml` (only
targets whose `os` matches the current runner are validated). The CSV
is logged as a notice so a shard's scope is visible in the run log.

To feed a downstream `release --publish-only` job from the harness's
byte-stable dist, set `preserve-dist: 'true'` and pass an explicit
`shard-label` per matrix entry. The action renames each shard's
manifests with that suffix so `merge-multiple` doesn't collide.

Tune with:

| Input | Default | Purpose |
|-------|---------|---------|
| `determinism-runs` | `2` | N for `--runs=N`. |
| `determinism-stages` | `build,archive,sbom,checksum` | Stages to diff per run. `sign` is excluded by default (shards lack keys); pass `build,archive,sbom,sign,checksum` to opt in when keys are provisioned. |
| `determinism-targets` | (auto) | Override the target CSV; useful on non-standard runner labels. |

The harness step does **not** retry on failure — it gates release
quality, so a flaky retry would mask drift. `determinism: true` is
mutually exclusive with `args:` (the action invokes the harness
directly).

### Nightly builds

Anodizer publishes immutable nightly tags shaped `vX.Y.Z-<sha>-nightly`
(e.g. `v0.2.0-7fe10db-nightly`) — every nightly is its own permanent
release rather than a moving `nightly` tag. Mirrors goreleaser-action ≥
v7.2.0.

```yaml
- uses: tj-smith47/anodizer-action@v1
  with:
    version: nightly                       # newest *-nightly tag
```

The action lists releases newest-first and installs the first non-draft
tag whose name ends in `-nightly`. Pin a specific nightly by passing the
exact tag instead:

```yaml
- uses: tj-smith47/anodizer-action@v1
  with:
    version: v0.2.0-7fe10db-nightly        # exact pin, won't drift
```

## Inputs

### Installation source

| Input | Default | Description |
|-------|---------|-------------|
| `version` | `latest` | Anodizer version to install from GitHub releases — exact tag (e.g. `v0.1.1`), the literal `latest` (newest stable release), or the literal `nightly` (newest release whose tag matches `vX.Y.Z-<sha>-nightly`). **No semver ranges** (`~> v2`) — pass an explicit tag or one of the aliases. Ignored when `from-artifact`, `from-source`, or `from-branch` is set. |
| `from-artifact` | | Artifact name to download instead of a release binary (e.g. `anodizer-linux`). Pair with `artifact-run-id` for cross-workflow downloads. |
| `artifact-run-id` | | Workflow run ID for the artifact. Use `auto` to resolve the latest successful run of `artifact-workflow` for the current commit. Use a numeric ID for explicit control. Omit to download from the current workflow run. |
| `artifact-workflow` | `ci.yml` | Workflow filename to search when `artifact-run-id` is `auto`. |
| `from-source` | `false` | Build anodizer from source in the workdir. Requires a Rust toolchain (`install-rust: true`). |
| `from-branch` | | Shallow-clone `tj-smith47/anodizer` at the given branch (e.g. `my-feature`) and build it from source. Accepts a branch name only — the repo is hardcoded. Auto-installs the stable Rust toolchain; you don't need `install-rust: true`. Mutually exclusive with `version`, `from-artifact`, and `from-source`. |

### Dependency setup

| Input | Default | Description |
|-------|---------|-------------|
| `install` | | Comma-separated deps: `nfpm`, `makeself`, `snapcraft`, `rpmbuild`, `cosign`, `zig`, `cargo-zigbuild`, `upx`, `nsis`, `create-dmg`, `flatpak`, `linuxdeploy`, `rcodesign`, `wix`. |
| `auto-install` | `false` | Parse `.anodizer.yaml` and auto-install whatever the configured stages need. |
| `install-rust` | `false` | Install the stable Rust toolchain. |

When `auto-install: true`, the action scans `.anodizer.yaml` for the
following top-level keys and installs the matching tool:

| `.anodizer.yaml` key | Installs | Notes |
|---------------------|----------|-------|
| `nfpm:` | `nfpm` | |
| `makeselfs:` | `makeself` | Linux, macOS (skipped on Windows). |
| `snapcrafts:` | `snapcraft` | Linux, macOS (skipped on Windows). Linux installs via snap; runners without snapd (e.g. containerised self-hosted) fall back to a pip install pinned by `SNAPCRAFT_VERSION` (default `8.14.5`) — upload-capable, but packing snaps still needs snapd. |
| `srpm:` | `rpmbuild` | Linux, macOS (skipped on Windows). |
| `cmd: cosign` (any sign block) / `docker_signs:` | `cosign` | `signs:`/`binary_signs:` default to GPG (preinstalled); cosign installs only when a block sets `cmd: cosign`, plus always for `docker_signs:` (which defaults to cosign). |
| `upx:` | `upx` | |
| `nsis:` | `nsis` | All platforms; macOS installs `makensis`. |
| `dmgs:` | `create-dmg` | macOS only (warns on other runners). |
| `flatpaks:` | `flatpak-builder` | Linux only (warns on other runners). |
| `appimages:` | `linuxdeploy` + appimage plugin | Linux only (warns on other runners). |
| `notarize.macos:` | `rcodesign` | Cross-platform (Linux/macOS pinned binary; Windows builds via `cargo install apple-codesign`). `notarize.macos_native:` needs nothing (uses macOS-runner `codesign`/`xcrun`). |
| `pkgs:` | _none_ | Warns if runner is not macOS. |
| `msis:` | `wix` (Windows) | WiX v4 `wix` dotnet global tool. Warns if runner is not Windows. |
| `cross: auto` / `cross: zigbuild` | `zig` + `cargo-zigbuild` | Cross-compilation via zigbuild. |

### Workspace resolution (monorepo)

| Input | Default | Description |
|-------|---------|-------------|
| `resolve-workspace` | `false` | Run `anodizer resolve-tag $GITHUB_REF_NAME` and expose the result via the `workspace`, `crate-path`, and `has-builds` outputs. |

### Docker setup

When `docker-registry` is set, the action logs in to the registry, configures QEMU (for emulated platforms), and sets up Docker Buildx (for multi-platform builds).

| Input | Default | Description |
|-------|---------|-------------|
| `docker-registry` | | Container registry hostname (e.g. `ghcr.io`, `docker.io`). |
| `docker-username` | `github.actor` | Registry username. |
| `docker-password` | | Registry password or token (commonly `secrets.GITHUB_TOKEN` for ghcr.io). |

### Split / merge artifact management

| Input | Default | Description |
|-------|---------|-------------|
| `upload-dist` | `false` | After running anodizer, upload `dist/` as a workflow artifact named `dist-$RUNNER_OS`. |
| `download-dist` | `false` | Before running anodizer, download all `dist-*` artifacts and merge them into `dist/`. Fails if no split context files are found. |
| `preserve-dist` | `false` | When `determinism: true`, preserve the harness's byte-stable dist tree to `./preserved-dist/` for downstream `release --publish-only` consumption. Requires `shard-label`. |
| `shard-label` | | Per-shard suffix for preserved-dist manifests (`context-<shard-label>.json`, etc.). The caller (matrix) names each shard explicitly; required when `preserve-dist: 'true'`. |

### Key material

| Input | Description |
|-------|-------------|
| `gpg-private-key` | GPG private key contents. Imported into the keyring via `gpg --batch --import` (used by `signs:` blocks). The same key is also written to `$RUNNER_TEMP/anodizer-signing.asc` and exported as `GPG_KEY_PATH` for nfpm package signing — `rpmsign` / `dpkg-sig` / `abuild-sign` read the key directly off disk. Loopback pinentry is enabled so any `GPG_PASSPHRASE` works non-interactively. |
| `apk-private-key` | PEM-format RSA private key for nfpm's apk packager. apk-tools uses RSA-PSS, not OpenPGP, so the `gpg-private-key` value does not satisfy apk signing. The private key is written to `$RUNNER_TEMP/anodizer-apk.rsa` with mode `0600` and exported as `APK_PRIVATE_KEY_PATH`. Reference from `.anodizer.yaml` via `apk.signature.key_file: "{{ .Env.APK_PRIVATE_KEY_PATH }}"`. The matching public key is derived via `openssl rsa -pubout`, exported as `APK_PUBLIC_KEY_PATH`, and copied into `./dist/` as `anodizer-apk-signing-key.rsa.pub` so it can be attached to the GitHub Release via `release.extra_files` (apk verifiers need it under `/etc/apk/keys/`). |
| `cosign-key` | Cosign private key contents. Written to `cosign.key` with mode `0600`. Pair with `COSIGN_PASSWORD` in env. |

### Execution

| Input | Default | Description |
|-------|---------|-------------|
| `args` | | Arguments to pass to anodizer (e.g. `release --snapshot`). |
| `workdir` | `.` | Working directory (relative to repo root). |
| `install-only` | `false` | Only install anodizer (and any requested dependencies/keys); skip running. |

### Determinism harness

| Input | Default | Description |
|-------|---------|-------------|
| `determinism` | `false` | Run `anodizer check determinism` on this shard. Auto-enables Rust toolchain install, from-source build, and the determinism dep set (zig + cargo-zigbuild + upx + syft + cosign on Linux; upx + syft + cosign on macOS/Windows). Mutually exclusive with `args`. |
| `determinism-runs` | `2` | N for `anodizer check determinism --runs=N`. |
| `determinism-stages` | `build,archive,sbom,checksum` | Stages to validate (comma-separated). `sign` is opt-in only — pass `build,archive,sbom,sign,checksum` when GPG/cosign keys are provisioned. |
| `determinism-targets` | | Explicit target CSV override. When unset, derived from `anodizer targets --json` by filtering on the current runner label. |

## Outputs

| Output | Description |
|--------|-------------|
| `artifacts` | Contents of `dist/artifacts.json` |
| `metadata` | Contents of `dist/metadata.json` |
| `release-url` | URL of the created GitHub release (extracted from metadata) |
| `workspace` | Crate name resolved from the triggering tag (requires `resolve-workspace: true`) |
| `crate-path` | Path to the resolved crate directory (requires `resolve-workspace: true`) |
| `has-builds` | Whether the resolved crate has binary builds configured (requires `resolve-workspace: true`) |
| `split-matrix` | JSON matrix for `strategy.matrix` covering configured build targets (requires `install-only: true`) |
| `crates` | JSON array of crate names that received a new tag (e.g. `["core","bin-a"]`). Set when `args: tag` is used on a per-crate workspace. Empty array (`[]`) when nothing changed. |
| `versions` | JSON object mapping crate name to new version (e.g. `{"core":"1.2.0","bin-a":"0.5.1"}`). Set when `args: tag` is used on a per-crate workspace. |
| `new-tag` | New tag `anodizer tag` created (e.g. `v1.2.3`), for single-crate and lockstep-workspace repos. Empty when no tag was cut. (Per-crate workspaces use `crates`/`versions` instead.) |
| `old-tag` | Previous tag `anodizer tag` bumped from. Empty on a first release. |
| `part` | Semver part bumped: `major` / `minor` / `patch` / `none` / `custom`. |
| `tagged` | `'true'` when this run cut a new tag (`new-tag` non-empty and differs from `old-tag`), `'false'` on a no-op. Gate downstream release jobs on this for single-crate / lockstep repos. |
| `head-sha` | Commit at HEAD after `anodizer tag --push` (the tag target). Check this out in downstream jobs so the tree matches the tag. |

## Build provenance (SLSA attestations)

When your `.anodizer.yaml` enables `attestations` in the default `subjects`
mode, anodizer writes a subjects manifest (`dist/attestation-subjects.json`, or
`dist/<crate>.attestation-subjects.json` in per-crate workspaces) listing every
release-uploadable artifact and its sha256. After anodizer runs, this action
flattens those manifests into a checksums file and mints a GitHub-trusted,
OIDC-backed SLSA build-provenance attestation over them via
[`actions/attest-build-provenance`][abp] — no attestation key is ever held by
anodizer or stored as a release asset.

It is automatic: producing the manifest is the opt-in, so you only set
`attestations.enabled: true` in your config. The step is a no-op when no
manifest is present. The calling workflow must grant the two permissions the
attestation API needs (alongside `contents: write` for the release itself):

```yaml
permissions:
  contents: write       # create the release / upload assets
  id-token: write       # OIDC identity for keyless attestation (and cosign)
  attestations: write   # write the SLSA provenance attestation
```

Consumers verify an artifact against its provenance with:

```bash
gh attestation verify <artifact> --repo <owner>/<repo>
```

[abp]: https://github.com/actions/attest-build-provenance

## Workspace orchestration

`anodizer tag` (without `--crate`) detects which crates in the workspace have changed since their last tag, bumps their versions, creates all per-crate tags in one bump commit, and pushes everything atomically. Two step outputs carry the result into downstream jobs:

| Output | Shape | Purpose |
|--------|-------|---------|
| `crates` | `["core","bin-a","bin-b"]` | Gate downstream jobs; drive a determinism matrix |
| `versions` | `{"core":"1.2.0","bin-a":"0.5.1"}` | Display, release-note generation, or conditional logic |

Skip all downstream jobs when nothing changed:

```yaml
jobs:
  tag:
    outputs:
      crates: ${{ steps.t.outputs.crates }}
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
          token: ${{ secrets.GH_PAT }}
      - name: Configure git identity
        run: |
          git config user.name  "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
      - uses: tj-smith47/anodizer-action@v1
        id: t
        with:
          args: tag
        env:
          GITHUB_TOKEN: ${{ secrets.GH_PAT }}

  determinism-check:
    needs: tag
    if: needs.tag.outputs.crates != '[]'
    strategy:
      matrix:
        crate: ${{ fromJson(needs.tag.outputs.crates) }}
        shard: [linux, macos, windows-x86_64, windows-aarch64]
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - uses: tj-smith47/anodizer-action@v1
        with:
          determinism: true
          preserve-dist: "true"
          shard-label: ${{ matrix.crate }}-${{ matrix.shard }}
          determinism-crate: ${{ matrix.crate }}
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

  release:
    needs: [tag, determinism-check]
    if: needs.tag.outputs.crates != '[]'
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - uses: tj-smith47/anodizer-action@v1
        with:
          auto-install: true
          download-dist: true
          args: release --publish-only
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          CARGO_REGISTRY_TOKEN: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

The `determinism-crate` input scopes the harness to one crate per matrix entry, so each shard validates only the targets that belong to that crate. `release --publish-only` consumes all preserved-dist subdirs and publishes in topological order.

For the full decision tree (single-crate, lockstep workspace, per-crate workspace, hybrid groupings, split-CI governance) and copy-pasteable YAML for every strategy, see the [Release Workflow Strategies](https://tj-smith47.github.io/anodizer/docs/ci/release-workflows/) page in the anodize docs.

## Retry behavior

The `Run anodizer` step retries up to 3 times for transient failures (registry
rate limits, Docker push auth expiry, network blips). Between retries it
prunes generated artifacts from `dist/` while preserving split context files
(`dist/*/context.json`) so `--merge` can still find them.

`--publish-only`, `--rollback-only`, and `tag rollback` invocations skip the
retry layer — they are stateful and re-running them would either duplicate
state changes or fight with concurrent operations.

## License

MIT

# Anodizer Action

GitHub Action for [Anodizer](https://github.com/tj-smith47/anodizer), a
Rust-native release automation tool inspired by GoReleaser.

The action installs anodizer (cached per version), auto-installs pipeline
dependencies (nfpm, makeself, snapcraft, rpmbuild, cosign, zig,
cargo-zigbuild, upx, nsis, create-dmg, flatpak) based on your
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
      - uses: actions/checkout@v4
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
      - uses: actions/checkout@v4
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
      - uses: actions/checkout@v4
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
      - uses: actions/checkout@v4
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
- uses: actions/checkout@v4
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
    - uses: actions/checkout@v4
      with:
        fetch-depth: 0
    - uses: tj-smith47/anodizer-action@v1
      with:
        determinism: true
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

Per-shard target lists are auto-derived from `.anodizer.yaml` (only
targets whose `os` matches the current runner are validated, mirroring
how `build:` shards split work). The CSV is logged as a notice so a
shard's scope is visible in the run log.

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
| `version` | `latest` | Anodizer version to install from GitHub releases — exact tag (e.g. `v0.1.1`), the literal `latest` (newest stable release), or the literal `nightly` (newest release whose tag matches `vX.Y.Z-<sha>-nightly`). **No semver ranges** (`~> v2`) — pass an explicit tag or one of the aliases. Ignored when `from-artifact` or `from-source` is set. |
| `from-artifact` | | Artifact name to download instead of a release binary (e.g. `anodizer-linux`). Pair with `artifact-run-id` for cross-workflow downloads. |
| `artifact-run-id` | | Workflow run ID for the artifact. Use `auto` to resolve the latest successful run of `artifact-workflow` for the current commit. Use a numeric ID for explicit control. Omit to download from the current workflow run. |
| `artifact-workflow` | `ci.yml` | Workflow filename to search when `artifact-run-id` is `auto`. |
| `from-source` | `false` | Build anodizer from source in the workdir. Requires a Rust toolchain (`install-rust: true`). |

### Dependency setup

| Input | Default | Description |
|-------|---------|-------------|
| `install` | | Comma-separated deps: `nfpm`, `makeself`, `snapcraft`, `rpmbuild`, `cosign`, `zig`, `cargo-zigbuild`, `upx`, `nsis`, `create-dmg`, `flatpak`. |
| `auto-install` | `false` | Parse `.anodizer.yaml` and auto-install whatever the configured stages need. |
| `install-rust` | `false` | Install the stable Rust toolchain. |

When `auto-install: true`, the action scans `.anodizer.yaml` for the
following top-level keys and installs the matching tool:

| `.anodizer.yaml` key | Installs | Notes |
|---------------------|----------|-------|
| `nfpm:` | `nfpm` | |
| `makeselfs:` | `makeself` | Linux, macOS (skipped on Windows). |
| `snapcrafts:` | `snapcraft` | Linux, macOS (skipped on Windows). |
| `srpm:` | `rpmbuild` | Linux, macOS (skipped on Windows). |
| `binary_signs:` / `docker_signs:` | `cosign` | |
| `upx:` | `upx` | |
| `nsis:` | `nsis` | All platforms; macOS installs `makensis`. |
| `dmgs:` | `create-dmg` | macOS only (warns on other runners). |
| `flatpaks:` | `flatpak-builder` | Linux only (warns on other runners). |
| `pkgs:` | _none_ | Warns if runner is not macOS. |
| `msis:` | _none_ | Warns if runner is not Windows. |
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

## Retry behavior

The `Run anodizer` step retries up to 3 times for transient failures (registry
rate limits, Docker push auth expiry, network blips). Between retries it
prunes generated artifacts from `dist/` while preserving split context files
(`dist/*/context.json`) so `--merge` can still find them.

## License

MIT

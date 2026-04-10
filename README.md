# Anodize Action

GitHub Action for [Anodize](https://github.com/tj-smith47/anodize), a
Rust-native release automation tool inspired by GoReleaser.

The action installs anodize, sets up any dependencies your release pipeline
needs (nfpm, makeself, snapcraft, rpmbuild, cosign, zig, upx...), imports
signing keys, and runs anodize — all in one step.

## Usage

### Basic release

```yaml
- uses: tj-smith47/anodize-action@v1
  with:
    args: release --clean
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Full release with auto-installed dependencies

Let the action parse your `.anodize.yaml` and install everything you need:

```yaml
- uses: tj-smith47/anodize-action@v1
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

### Explicit dependency list

```yaml
- uses: tj-smith47/anodize-action@v1
  with:
    install: nfpm,makeself,snapcraft,rpmbuild,cosign
    gpg-private-key: ${{ secrets.GPG_PRIVATE_KEY }}
    args: release --merge
```

### Cross-compile build jobs

```yaml
- uses: tj-smith47/anodize-action@v1
  with:
    install-rust: true
    install: zig,cargo-zigbuild,upx
    args: release --split --clean
```

### Specific version

```yaml
- uses: tj-smith47/anodize-action@v1
  with:
    version: v0.1.1
    args: release
```

### Install only

```yaml
- uses: tj-smith47/anodize-action@v1
  with:
    install-only: true

- run: anodize check
- run: anodize release --snapshot
```

### Reuse CI-built binary (cross-workflow)

If your CI workflow builds and uploads anodize binaries per platform, a
separate Release workflow (e.g. triggered by a tag) can download them instead
of rebuilding from source. Set `artifact-run-id: auto` to automatically find
the latest successful CI run for the current commit:

```yaml
# CI workflow (ci.yml) — test + upload a reusable anodize binary
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo test --workspace
      - run: cargo build --release -p anodize
      - uses: actions/upload-artifact@v4
        with:
          name: anodize-linux
          path: target/release/anodize
```

```yaml
# Release workflow (release.yml) — reuse CI binary, then run release
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: tj-smith47/anodize-action@v1
        with:
          from-artifact: anodize-linux
          artifact-run-id: auto
          artifact-workflow: ci.yml
          auto-install: true
          gpg-private-key: ${{ secrets.GPG_PRIVATE_KEY }}
          args: release --clean
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Bootstrap from source

When you need anodize built on the current runner (e.g. the CI-provided
artifact is for a different platform) set `from-source: true`:

```yaml
- uses: tj-smith47/anodize-action@v1
  with:
    install-rust: true
    from-source: true
    install: zig,cargo-zigbuild,upx
    args: release --split --clean
```

### Split/merge cross-platform release

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
      - uses: tj-smith47/anodize-action@v1
        with:
          install-rust: true
          install: zig,cargo-zigbuild,upx
          args: release --split --clean
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      - uses: actions/upload-artifact@v4
        with:
          name: dist-${{ runner.os }}
          path: dist/

  release:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: actions/download-artifact@v4
        with:
          path: dist/
          pattern: dist-*
          merge-multiple: true
      - uses: tj-smith47/anodize-action@v1
        with:
          auto-install: true
          gpg-private-key: ${{ secrets.GPG_PRIVATE_KEY }}
          args: release --merge
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          COSIGN_KEY: ${{ secrets.COSIGN_KEY }}
          COSIGN_PASSWORD: ${{ secrets.COSIGN_PASSWORD }}
```

## Inputs

### Installation source (choose one)

| Input | Default | Description |
|-------|---------|-------------|
| `version` | `latest` | Anodize version to install from GitHub releases (e.g. `v0.1.1`). |
| `from-artifact` | | Download pre-built binary from a workflow artifact instead of releases. |
| `artifact-run-id` | | Workflow run ID for cross-workflow downloads. Use `auto` to resolve from the current commit SHA. |
| `artifact-workflow` | `ci.yml` | Workflow filename to search when `artifact-run-id` is `auto`. |
| `from-source` | `false` | Build anodize from source in the workdir. Requires Rust (`install-rust: true`). |

### Dependency setup

| Input | Default | Description |
|-------|---------|-------------|
| `install` | | Comma-separated deps to install: `nfpm`, `makeself`, `snapcraft`, `rpmbuild`, `cosign`, `zig`, `cargo-zigbuild`, `upx`. |
| `auto-install` | `false` | Parse `.anodize.yaml` and auto-install whatever the configured stages need. |
| `install-rust` | `false` | Install the stable Rust toolchain. |

### Key material

| Input | Description |
|-------|-------------|
| `gpg-private-key` | GPG private key contents to import. |
| `cosign-key` | Cosign private key contents (written to `cosign.key`). |

### Execution

| Input | Default | Description |
|-------|---------|-------------|
| `args` | | Arguments to pass to anodize (e.g. `release --snapshot`). |
| `workdir` | `.` | Working directory. |
| `install-only` | `false` | Only install, don't run. |

## Outputs

| Output | Description |
|--------|-------------|
| `artifacts` | Contents of `dist/artifacts.json` |
| `metadata` | Contents of `dist/metadata.json` |
| `release-url` | URL of the created GitHub release (from metadata) |
| `split-matrix` | JSON matrix for `strategy.matrix` covering configured build targets |

## License

MIT

# Anodize Action

GitHub Action for [Anodize](https://github.com/tj-smith47/anodize), a Rust-native release automation tool.

## Usage

### Basic release

```yaml
- uses: tj-smith47/anodize-action@v1
  with:
    args: release
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Snapshot (no publish)

```yaml
- uses: tj-smith47/anodize-action@v1
  with:
    args: release --snapshot --clean
```

### Specific version

```yaml
- uses: tj-smith47/anodize-action@v1
  with:
    version: v0.1.1
    args: release
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Install only (multi-step workflows)

```yaml
- uses: tj-smith47/anodize-action@v1
  with:
    install-only: true

- run: anodize check
- run: anodize release --snapshot
```

### Reuse CI-built binary (same workflow)

Upload the binary in your build job, then download it in the release job:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo build --release -p anodize
      - uses: actions/upload-artifact@v4
        with:
          name: anodize-linux
          path: target/release/anodize

  release:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: tj-smith47/anodize-action@v1
        with:
          from-artifact: anodize-linux
          args: release
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Reuse CI-built binary (cross-workflow)

If your CI workflow builds and uploads anodize binaries per platform, a separate
Release workflow (e.g. triggered by a tag) can download them instead of
rebuilding from source. This is especially useful for skipping slow builds
(e.g. ~15 min on Windows).

Set `artifact-run-id: auto` to automatically find the latest successful CI run
for the current commit:

```yaml
# CI workflow (ci.yml) — builds and uploads per-platform binaries
jobs:
  test:
    strategy:
      matrix:
        include:
          - os: ubuntu-latest
            artifact: anodize-linux
            bin: target/release/anodize
          - os: macos-latest
            artifact: anodize-macos
            bin: target/release/anodize
          - os: windows-latest
            artifact: anodize-windows
            bin: target/release/anodize.exe
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - run: cargo test --workspace
      - run: cargo build --release -p anodize
      - uses: actions/upload-artifact@v4
        with:
          name: ${{ matrix.artifact }}
          path: ${{ matrix.bin }}
```

```yaml
# Release workflow (release.yml) — downloads pre-built binaries
jobs:
  build:
    strategy:
      matrix:
        include:
          - os: ubuntu-latest
            artifact: anodize-linux
          - os: macos-latest
            artifact: anodize-macos
          - os: windows-latest
            artifact: anodize-windows
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      # Download anodize from CI instead of rebuilding (~15 min saved on Windows)
      - uses: tj-smith47/anodize-action@v1
        with:
          from-artifact: ${{ matrix.artifact }}
          artifact-run-id: auto
          artifact-workflow: ci.yml
          install-only: true
      - run: anodize release --split --clean
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
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
          args: release --merge
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `version` | `latest` | Anodize version from GitHub releases (e.g. `v0.1.1`). Ignored when `from-artifact` is set. |
| `from-artifact` | | Download pre-built binary from a workflow artifact instead of releases. |
| `artifact-run-id` | | Workflow run ID for cross-workflow artifact downloads. Use `auto` to resolve from the current commit SHA. |
| `artifact-workflow` | `ci.yml` | Workflow filename to search when `artifact-run-id` is `auto`. |
| `args` | | Arguments to pass to anodize. |
| `workdir` | `.` | Working directory. |
| `install-only` | `false` | Only install, don't run. |

## Outputs

| Output | Description |
|--------|-------------|
| `artifacts` | Contents of `dist/artifacts.json` |
| `metadata` | Contents of `dist/metadata.json` |

## License

MIT

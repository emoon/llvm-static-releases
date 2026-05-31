# llvm-static-releases

Prebuilt static LLVM archives, suitable for projects that want to link against LLVM without a `libLLVM-NN.{so,dylib,dll}` runtime dependency and don't need clang / lldb / lld along for the ride.

The CMake flag set produces a minimal install:

- Targets: X86 + AArch64 only.
- No clang, lldb, lld, or other LLVM projects.
- Static archives only (`BUILD_SHARED_LIBS=OFF`, `LLVM_BUILD_LLVM_DYLIB=OFF`, `LLVM_LINK_LLVM_DYLIB=OFF`).
- No LTO or remarks shared libraries (`LLVM_TOOL_LTO_BUILD=OFF`, `LLVM_TOOL_REMARKS_SHLIB_BUILD=OFF`).
- Assertions off, `zstd` / `libxml2` / `terminfo` off. `zlib` on for Linux/macOS (system zlib links fine); off for Windows, which has no system zlib — see below.
- A belt-and-suspenders post-install sweep removes any `*.so` / `*.dylib` that slipped through.

The full flag list lives in [`scripts/build_llvm.sh`](scripts/build_llvm.sh) (Linux/macOS); that script is the single source of truth for what "minimal static LLVM" means here. [`scripts/build_llvm.ps1`](scripts/build_llvm.ps1) is the Windows/MSVC parallel — same pinned constants and CMake flag set, installing under `%LOCALAPPDATA%\llvm-static-releases\`. The two must be kept in lockstep when bumping LLVM, with one deliberate divergence: `LLVM_ENABLE_ZLIB` is `FORCE_ON` on Linux/macOS but `OFF` on Windows. Windows has no system zlib, and satisfying it from vcpkg would bake an unsatisfiable `ZLIB::ZLIB` into `LLVMSupport`'s exported link interface, breaking downstream consumers; zlib only gates optional debug-info compression, which the prebuilt doesn't need. The `build_llvm.ps1` header documents this.

## How to build

[`.github/workflows/build-llvm.yml`](.github/workflows/build-llvm.yml) runs on `workflow_dispatch` only. Inputs:

- `llvm_version` — the LLVM version (e.g. `22.1.5`). Becomes the release tag. Must match the `LLVM_VERSION` pin in `scripts/build_llvm.sh` (the workflow verifies this up front and fails fast on mismatch).
- `os` — which triples to build/publish: `all` (default), `linux`, `macos`, or `windows`. Each asset is published independently, so a re-build overwrites only that triple's asset (with a possibly-different SHA256). Use a single OS to fix or re-cut one triple without disturbing the others' pinned assets.

On dispatch the workflow runs `scripts/build_llvm.sh`, tars the install prefix as `llvm-${llvm_version}-x86_64-unknown-linux-gnu.tar.xz`, and publishes (or extends) the GitHub Release tagged `<llvm_version>`. Each asset's SHA256 is recorded in the release notes so consumers can pin against it.

## Bumping LLVM

1. Edit `LLVM_VERSION`, `LLVM_SHA256`, and `LLVM_URL` at the top of `scripts/build_llvm.sh`. Push.
2. Dispatch the workflow with the new `llvm_version`.
3. Wait for the prebuilt to appear on the new release tag.

## License

This repository's contents (workflow, scripts, docs) are Apache-2.0 — see [`LICENSE`](LICENSE). LLVM itself, redistributed inside the published archives, is governed by its own [Apache-2.0-with-LLVM-exceptions license](https://github.com/llvm/llvm-project/blob/main/LICENSE.TXT), included as `LICENSE.TXT` inside each tarball alongside the static archives.

#!/usr/bin/env bash
# Builds a minimal static LLVM and installs it into
# ${XDG_CACHE_HOME:-$HOME/.cache}/llvm-static-releases/llvm-${LLVM_VERSION}/.
#
# Minimal here means: X86 + AArch64 only, no clang / lldb / lld, no shared
# libraries, no LTO/remarks shlibs, assertions off, no zstd / libxml2 /
# terminfo. The build is reproducible byte-for-byte for a given
# (LLVM_VERSION, LLVM_SHA256, CMake flag set) tuple — bumping LLVM is a
# three-constant edit at the top of this file.
set -euo pipefail

LLVM_VERSION=22.1.5
LLVM_SHA256=7972b87b705a003ce70ab55f9f0fb495d156887cba0eb296d284731139118e2c
LLVM_URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/llvm-project-${LLVM_VERSION}.src.tar.xz"

CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}/llvm-static-releases"
PREFIX="${CACHE_BASE}/llvm-${LLVM_VERSION}"
BUILD_DIR="${CACHE_BASE}/llvm-${LLVM_VERSION}-build"
TARBALL="${CACHE_BASE}/llvm-project-${LLVM_VERSION}.src.tar.xz"
SRC_TOPLEVEL="${BUILD_DIR}/llvm-project-${LLVM_VERSION}.src"
SRC_DIR="${SRC_TOPLEVEL}/llvm"
BUILD_TREE="${BUILD_DIR}/build"

# Idempotency: if the install marker is already in place, exit.
if [ -f "${PREFIX}/lib/libLLVMCore.a" ]; then
    echo "llvm ${LLVM_VERSION}: already installed at ${PREFIX}"
    exit 0
fi

mkdir -p "${CACHE_BASE}"

case "$(uname -s)" in
    Linux)
        : "${CC:=$(command -v clang || command -v gcc)}"
        : "${CXX:=$(command -v clang++ || command -v g++)}"
        SHA256SUM=(sha256sum)
        ;;
    Darwin)
        : "${CC:=$(xcrun -f clang)}"
        : "${CXX:=$(xcrun -f clang++)}"
        # Stock macOS ships `shasum`, not `sha256sum`. `shasum -a 256` produces
        # the same `<hash>  <file>` lines `sha256sum -c -` consumes.
        SHA256SUM=(shasum -a 256)
        ;;
    *)
        echo "error: unsupported host $(uname -s); only Linux and macOS are supported here." >&2
        exit 1
        ;;
esac
export CC CXX

for tool in cmake ninja tar curl "${SHA256SUM[0]}"; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "error: required tool '${tool}' not found in PATH." >&2
        exit 1
    fi
done

# Download (resumable) and verify.
if [ ! -f "${TARBALL}" ]; then
    echo "downloading ${LLVM_URL}"
    curl -fL --retry 3 -o "${TARBALL}.partial" "${LLVM_URL}"
    mv "${TARBALL}.partial" "${TARBALL}"
fi

echo "verifying sha256"
echo "${LLVM_SHA256}  ${TARBALL}" | "${SHA256SUM[@]}" -c -

# Fresh build tree.
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "extracting ${TARBALL}"
tar -xJf "${TARBALL}" -C "${BUILD_DIR}"

mkdir -p "${BUILD_TREE}"

echo "configuring cmake (Ninja, Release, static)"
cmake -S "${SRC_DIR}" -B "${BUILD_TREE}" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DCMAKE_C_COMPILER="${CC}" \
    -DCMAKE_CXX_COMPILER="${CXX}" \
    -DLLVM_TARGETS_TO_BUILD="X86;AArch64" \
    -DLLVM_ENABLE_PROJECTS="" \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLVM_BUILD_LLVM_DYLIB=OFF \
    -DLLVM_LINK_LLVM_DYLIB=OFF \
    -DLLVM_TOOL_LTO_BUILD=OFF \
    -DLLVM_TOOL_REMARKS_SHLIB_BUILD=OFF \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_ZLIB=FORCE_ON

echo "building llvm (this is the long step)"
cmake --build "${BUILD_TREE}"

echo "installing to ${PREFIX}"
rm -rf "${PREFIX}"
cmake --install "${BUILD_TREE}"

# Place the upstream license next to the install so consumers find it
# alongside the static archives in the tarball.
install -m 0644 "${SRC_TOPLEVEL}/LICENSE.TXT" "${PREFIX}/LICENSE.TXT"

# Belt-and-suspenders: sweep the install for any shared-library artifacts.
# The whole point of the static build is no libLLVM*.so / *.dylib at run
# time; if a future LLVM version adds a new shared-output tool not yet
# disabled above, this catches it deterministically.
find "${PREFIX}/lib" \( -name "*.so" -o -name "*.so.*" -o -name "*.dylib" \) -delete

# Build scratch (~10-20 GB) is no longer needed after install.
echo "cleaning build scratch ${BUILD_DIR}"
rm -rf "${BUILD_DIR}"

echo "done. installed: ${PREFIX}"

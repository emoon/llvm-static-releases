#!/usr/bin/env pwsh
# Builds a minimal static LLVM and installs it into
# $env:LOCALAPPDATA\llvm-static-releases\llvm-${LLVM_VERSION}\.
#
# Windows / MSVC parallel to scripts/build_llvm.sh — the bash script covers
# Linux and macOS, this covers the x86_64-pc-windows-msvc host. The two must
# stay in lockstep on the three pinned constants and the CMake flag set:
# the prebuilt for every triple is meant to be the same minimal static LLVM,
# differing only in object format.
#
# Minimal here means: X86 + AArch64 only, no clang / lldb / lld, no shared
# libraries, no LTO/remarks shlibs, assertions off, no zstd / libxml2 /
# terminfo. Bumping LLVM is a three-constant edit at the top of this file
# (in lockstep with build_llvm.sh).
#
# Toolchain assumption: this script does NOT bootstrap MSVC. The caller is
# expected to have entered a Developer PowerShell environment first — i.e. run
# `Enter-VsDevShell` (or a `vcvarsall.bat` shim) so that `cl.exe`, the Windows
# SDK, Ninja, and CMake are on PATH. On a `windows-latest` GitHub Actions
# runner this is `ilammy/msvc-dev-cmd` (or `microsoft/setup-msbuild` +
# `Enter-VsDevShell`). The required-tools check below fails loudly if cl/ninja/
# cmake/tar are missing, which is the usual symptom of a missing dev shell.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LLVM_VERSION = '22.1.5'
$LLVM_SHA256  = '7972b87b705a003ce70ab55f9f0fb495d156887cba0eb296d284731139118e2c'
$LLVM_URL     = "https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/llvm-project-${LLVM_VERSION}.src.tar.xz"

$CacheBase   = Join-Path $env:LOCALAPPDATA 'llvm-static-releases'
$Prefix      = Join-Path $CacheBase "llvm-${LLVM_VERSION}"
$BuildDir    = Join-Path $CacheBase "llvm-${LLVM_VERSION}-build"
$Tarball     = Join-Path $CacheBase "llvm-project-${LLVM_VERSION}.src.tar.xz"
$SrcTopLevel = Join-Path $BuildDir "llvm-project-${LLVM_VERSION}.src"
$SrcDir      = Join-Path $SrcTopLevel 'llvm'
$BuildTree   = Join-Path $BuildDir 'build'

# Run a native executable and fail loudly on a non-zero exit, since PowerShell
# does not treat that as a terminating error the way `set -e` does for bash.
function Invoke-Native {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "command failed (exit ${LASTEXITCODE}): $Exe $($Arguments -join ' ')"
    }
}

# Idempotency: if the install marker is already in place, exit. The MSVC
# static archive is LLVMCore.lib (vs libLLVMCore.a on the bash side).
if (Test-Path (Join-Path $Prefix 'lib\LLVMCore.lib')) {
    Write-Host "llvm ${LLVM_VERSION}: already installed at $Prefix"
    exit 0
}

New-Item -ItemType Directory -Force -Path $CacheBase | Out-Null

# Toolchain comes from the Developer PowerShell environment (see header).
# CMake auto-detects cl.exe from PATH with the Ninja generator; we pin it
# explicitly so a stray gcc/clang on PATH can't win.
foreach ($tool in 'cmake', 'ninja', 'tar', 'cl') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "required tool '$tool' not found in PATH. Did you enter a Visual Studio Developer PowerShell (Enter-VsDevShell)?"
    }
}

# Download (with retry) and verify.
if (-not (Test-Path $Tarball)) {
    Write-Host "downloading $LLVM_URL"
    $partial = "${Tarball}.partial"
    $ProgressPreference = 'SilentlyContinue'  # progress bar makes IWR ~10x slower
    $ok = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -Uri $LLVM_URL -OutFile $partial -UseBasicParsing
            $ok = $true
            break
        } catch {
            Write-Warning "download attempt $attempt failed: $($_.Exception.Message)"
        }
    }
    if (-not $ok) { throw "failed to download $LLVM_URL after 3 attempts" }
    Move-Item -Force $partial $Tarball
}

Write-Host 'verifying sha256'
$actual = (Get-FileHash -Algorithm SHA256 -Path $Tarball).Hash
if ($actual -ne $LLVM_SHA256.ToUpperInvariant()) {
    throw "sha256 mismatch for ${Tarball}: expected $LLVM_SHA256, got $($actual.ToLowerInvariant())"
}

# Fresh build tree.
if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir }
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

Write-Host "extracting $Tarball"
# Windows' bundled tar (bsdtar/libarchive) auto-detects xz from the content.
Invoke-Native -Exe 'tar' -Arguments @('-xf', $Tarball, '-C', $BuildDir)

New-Item -ItemType Directory -Force -Path $BuildTree | Out-Null

Write-Host 'configuring cmake (Ninja, Release, static)'
Invoke-Native -Exe 'cmake' -Arguments @(
    '-S', $SrcDir,
    '-B', $BuildTree,
    '-G', 'Ninja',
    '-DCMAKE_BUILD_TYPE=Release',
    "-DCMAKE_INSTALL_PREFIX=$Prefix",
    '-DCMAKE_C_COMPILER=cl',
    '-DCMAKE_CXX_COMPILER=cl',
    '-DLLVM_TARGETS_TO_BUILD=X86;AArch64',
    '-DLLVM_ENABLE_PROJECTS=',
    '-DLLVM_INCLUDE_TESTS=OFF',
    '-DLLVM_INCLUDE_EXAMPLES=OFF',
    '-DLLVM_INCLUDE_BENCHMARKS=OFF',
    '-DLLVM_INCLUDE_DOCS=OFF',
    '-DBUILD_SHARED_LIBS=OFF',
    '-DLLVM_BUILD_LLVM_DYLIB=OFF',
    '-DLLVM_LINK_LLVM_DYLIB=OFF',
    '-DLLVM_TOOL_LTO_BUILD=OFF',
    '-DLLVM_TOOL_REMARKS_SHLIB_BUILD=OFF',
    '-DLLVM_ENABLE_ASSERTIONS=OFF',
    '-DLLVM_ENABLE_TERMINFO=OFF',
    '-DLLVM_ENABLE_ZSTD=OFF',
    '-DLLVM_ENABLE_LIBXML2=OFF',
    '-DLLVM_ENABLE_ZLIB=FORCE_ON'
)

Write-Host 'building llvm (this is the long step)'
Invoke-Native -Exe 'cmake' -Arguments @('--build', $BuildTree)

Write-Host "installing to $Prefix"
if (Test-Path $Prefix) { Remove-Item -Recurse -Force $Prefix }
Invoke-Native -Exe 'cmake' -Arguments @('--install', $BuildTree)

# Place the upstream license next to the install so consumers find it
# alongside the static archives in the tarball.
Copy-Item -Force (Join-Path $SrcTopLevel 'LICENSE.TXT') (Join-Path $Prefix 'LICENSE.TXT')

# Belt-and-suspenders: sweep the install for any shared-library artifacts.
# The whole point of the static build is no LLVM-*.dll at run time; if a
# future LLVM version adds a new shared-output tool not yet disabled above,
# this catches it deterministically. On Windows the DLLs land in bin (not
# lib), so sweep both.
foreach ($dir in (Join-Path $Prefix 'lib'), (Join-Path $Prefix 'bin')) {
    if (Test-Path $dir) {
        Get-ChildItem -Path $dir -Filter '*.dll' -Recurse -File | Remove-Item -Force
    }
}

# Build scratch (~10-20 GB) is no longer needed after install.
Write-Host "cleaning build scratch $BuildDir"
Remove-Item -Recurse -Force $BuildDir

Write-Host "done. installed: $Prefix"

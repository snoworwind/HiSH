$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$base = Join-Path $root '.temp/source-build'
$sdk = 'D:/D Program Files/DevEco Studio/sdk/default/openharmony/native'
$qemuSource = @{}
Get-Content (Join-Path $root 'deps/libqemu/source.env') | ForEach-Object {
  if ($_ -match '^([A-Z_]+)=(.+)$') { $qemuSource[$Matches[1]] = $Matches[2] }
}
$inputs = Get-ChildItem "$base/downloads" -File | Where-Object { $_.Name -match '\.(tar\.(gz|xz)|whl)$|^kernel-config$' } | ForEach-Object {
  @{ file=$_.Name; sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(); bytes=$_.Length }
}
function Get-Artifacts([string]$dir) {
  if (-not (Test-Path $dir)) { return @() }
  Get-ChildItem $dir -File -Recurse | Where-Object { $_.Name -match '\.(a|so)(\.|$)|^kernel_aarch64$|^kernel.config$' -and -not $_.LinkType } | ForEach-Object {
    @{ file=$_.FullName.Substring($base.Length+1).Replace('\','/'); sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(); bytes=$_.Length }
  }
}
$outputs = Get-Artifacts "$base/install"
$linuxOutputs = Get-Artifacts "$base/linux"
$linuxX64Outputs = Get-Artifacts "$base/linux-x86_64"
$imageFiles = if (Test-Path "$base/images") {
  Get-ChildItem "$base/images" -File | ForEach-Object {
    @{ file=$_.FullName.Substring($base.Length+1).Replace('\','/'); sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(); bytes=$_.Length }
  }
} else { @() }
$kernelRelease = if (Test-Path "$base/logs/kernel-release.txt") { (Get-Content "$base/logs/kernel-release.txt" -Raw).Trim() } else { '' }
$packages = Get-ChildItem "$root/product" -Directory | ForEach-Object {
  Get-ChildItem $_.FullName -Recurse -Filter '*.hap' -ErrorAction SilentlyContinue | ForEach-Object {
    @{ file=$_.FullName.Substring($root.Length+1).Replace('\','/'); sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(); bytes=$_.Length; signed=(-not $_.Name.Contains('-unsigned')) }
  }
}
$installedLibs = Get-ChildItem "$root/feature/hish_main/libs" -Recurse -File -Filter '*.so*' -ErrorAction SilentlyContinue | ForEach-Object {
  @{ file=$_.FullName.Substring($root.Length+1).Replace('\','/'); sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(); bytes=$_.Length }
}
$patchFiles = @(
  'deps/zstd/0001-qsort.diff',
  'deps/glib/0001-ohos-netlink-sockaddr.patch',
  'deps/glib/0002-windows-host-gdb-autoload.patch'
)
$patches = $patchFiles | ForEach-Object {
  @{ file=$_; sha256=(Get-FileHash (Join-Path $root $_) -Algorithm SHA256).Hash.ToLower() }
}
$manifest = @{
  recordedAt=(Get-Date -Format o)
  target='HarmonyOS arm64-v8a native libraries; ARM64 Linux guest kernel'
  sdk=(Get-Content "$sdk/oh-uni-package.json" -Raw | ConvertFrom-Json)
  linuxToolchain=@{
    name='OpenHarmony release SDK for Linux, native-linux-x64 6.1.0.31-Release'
    url='https://repo.huaweicloud.com/openharmony/os/6.1-Release/ohos-sdk-windows_linux-public.tar.gz'
    sha256='b833b75a64ee46bbd7880921abbb49b733ec5c8171b6684c9b524d57f624cee0'
    localPath='/root/ohos-sdk/linux/native (WSL)'
    note='Used inside WSL to cross-build the aarch64-linux-ohos libraries and QEMU. It ships the same clang 15.0.4 driver as the DevEco Windows SDK but is a different LLVM commit.'
  }
  sourceUrls=@{
    zlib='https://zlib.net/fossils/zlib-1.3.1.tar.gz'
    zstd='https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz'
    pcre2='https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.45/pcre2-10.45.tar.gz'
    pixman='https://cairographics.org/releases/pixman-0.42.2.tar.gz'
    libffi='https://gitlab.freedesktop.org/gstreamer/meson-ports/libffi.git (revision meson)'
    proxyLibintl='https://github.com/frida/proxy-libintl.git (tag 0.4)'
    glib='https://download.gnome.org/sources/glib/2.82/glib-2.82.0.tar.xz'
    qemu="$($qemuSource.QEMU_REPOSITORY) (branch $($qemuSource.QEMU_BRANCH), QEMU $($qemuSource.QEMU_VERSION))"
    linux='https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.tar.xz'
    kernelConfig='https://raw.githubusercontent.com/harmoninux/linux-config/refs/heads/master/arm64_virt'
  }
  sourceCommits=@{
    libffi='83d0cfd00d7d37af4b4349511d29f1f0512621b3'
    proxyLibintl='c03e1a74b17fa7ec467e110130775409e4828a4c'
    qemu=$qemuSource.QEMU_REVISION
  }
  patches=$patches
  inputs=$inputs
  outputs=$outputs
  linuxOutputs=$linuxOutputs
  linuxX64Outputs=$linuxX64Outputs
  images=$imageFiles
  kernelRelease=$kernelRelease
  packages=$packages
  installedLibs=$installedLibs
  installedLibsNote='feature/hish_main/libs/arm64-v8a and feature/hish_main/libs/x86_64 hold the libraries built by scripts/build-source-linux.sh (QEMU 11.1.3 from the pinned snoworwind/qemu-ohos fork plus statically linked zlib/PCRE2/GLib). arm64-v8a is built with TARGET_ARCH=aarch64 (default); x86_64 with TARGET_ARCH=x86_64.'
  packagesNote='HAP entries describe files found at recording time. Rebuild after component changes; inspect packaged libraries and verify signatures independently. Presence of a HAP does not establish runtime validation.'
  vmImages=@{
    kernel='feature/hish_main/src/main/resources/rawfile/vm/kernel_aarch64'
    rootfs='feature/hish_main/src/main/resources/rawfile/vm/rootfs_aarch64.qcow2'
    rootfsDistro='Alpine 3.24.4 (v3.24), 34 apk packages, ext4 4K blocks on a 128 GiB sparse image'
    rootfsPackagesFile='.temp/source-build/images/rootfs_aarch64.qcow2.packages.txt'
    originalsBackup='.temp/source-build/original-images'
    doc='docs/vm-images-2026-11-14.md'
  }
  rootfsPackagesNote='Package list is generated by scripts/build-source-rootfs.sh. The packages come from the Alpine v3.24 main/community repositories and are verified by apk against the Alpine keys at install time; the binaries themselves are Alpine builds, not compiled by this repository (documented exception, see docs/build-from-source.md).'
  note='Hashes record downloaded inputs and produced files; they are not independent upstream signature verification. Compilation does not imply runtime validation or reproducibility.'
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content "$base/manifest.json" -Encoding utf8
Write-Output "Recorded $($outputs.Count) Windows-toolchain and $($linuxOutputs.Count) Linux-toolchain artifacts in $base/manifest.json"

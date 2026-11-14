#!/usr/bin/env bash
#
# Build an aarch64 Linux kernel Image for the HiSH VM from kernel.org source.
#
# Usage:
#   KERNEL_VERSION=6.12.117 scripts/build-source-kernel.sh
#   KERNEL_VERSION=6.12.117 OUT=/tmp/kernel_aarch64 scripts/build-source-kernel.sh
#
# Defaults: latest 6.12 LTS tested with the harness at the time of writing.
# The configuration is the project's arm64_virt config (downloads/kernel-config),
# refreshed with olddefconfig so new symbols of the target release get defaults.
set -euo pipefail

version=${KERNEL_VERSION:-6.12.117}
root=$(cd "$(dirname "$0")/.." && pwd)
base="$root/.temp/source-build"
downloads="$base/downloads"
logs="$base/logs"
out=${OUT:-$base/images/kernel_aarch64}
config_in=${KERNEL_CONFIG:-$downloads/kernel-config}
cross=${CROSS_COMPILE:-aarch64-linux-gnu-}
jobs=${JOBS:-$(nproc)}

mkdir -p "$downloads" "$logs" "$(dirname "$out")"

major=${version%%.*}
minor=${version#*.}
series="${major}.${minor%%.*}"
tarball="$downloads/linux-$version.tar.xz"
url="https://cdn.kernel.org/pub/linux/kernel/v${major}.x/linux-$version.tar.xz"

log() { printf '== %s\n' "$*"; }

if [ ! -f "$tarball" ]; then
  log "download $url"
  curl -fL --retry 3 -o "$tarball.part" "$url"
  mv "$tarball.part" "$tarball"
fi

log "verify $tarball against kernel.org signed checksums"
sums="$downloads/sha256sums-${major}.x.asc"
if [ ! -f "$sums" ]; then
  curl -fsSL --retry 3 -o "$sums" "https://cdn.kernel.org/pub/linux/kernel/v${major}.x/sha256sums.asc"
fi
if command -v gpg >/dev/null 2>&1 && gpg --verify "$sums" >/dev/null 2>&1; then
  log "   sha256sums.asc PGP signature verified"
elif command -v gpg >/dev/null 2>&1; then
  log "   WARNING: sha256sums.asc PGP signature not verified (kernel.org key not in keyring)"
  log "   import it once with: gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 632D3A06589DA6B1"
fi
expected=$(grep " linux-$version.tar.xz\$" "$sums" | awk '{print $1}')
[ -n "$expected" ] || { echo "release $version not found in $sums" >&2; exit 1; }
actual=$(sha256sum "$tarball" | awk '{print $1}')
[ "$expected" = "$actual" ] || { echo "sha256 mismatch for $tarball" >&2; exit 1; }
printf '   sha256 %s\n' "$actual"

taskdir=$(mktemp -d /tmp/hish-kernel-XXXXXX)
printf '%s\n' "$taskdir" > "$base/kernel-workdir.txt"
log "extract to $taskdir"
tar -xf "$tarball" -C "$taskdir"
cd "$taskdir/linux-$version"

cp "$config_in" .config
export KBUILD_BUILD_TIMESTAMP=${KBUILD_BUILD_TIMESTAMP:-'2026-11-14 00:00:00 UTC'}
export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-hish-builder}
export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-hish-build}
log "configure $version (arm64_virt base config, olddefconfig)"
make ARCH=arm64 CROSS_COMPILE="$cross" olddefconfig > "$logs/kernel-configure.log" 2>&1
log "build Image"
make ARCH=arm64 CROSS_COMPILE="$cross" -j"$jobs" Image > "$logs/kernel-build.log" 2>&1

cp arch/arm64/boot/Image "$out"
cp .config "$(dirname "$out")/kernel.config"
"${cross}gcc" --version > "$logs/kernel-compiler.txt"
make ARCH=arm64 CROSS_COMPILE="$cross" kernelrelease > "$logs/kernel-release.txt" 2>/dev/null || true

log "built $out"
printf '  release: %s\n' "$(cat "$logs/kernel-release.txt")"
printf '  bytes  : %s\n' "$(stat -c %s "$out")"
printf '  sha256 : %s\n' "$(sha256sum "$out" | awk '{print $1}')"

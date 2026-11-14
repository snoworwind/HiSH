#!/usr/bin/env bash
# Build HiSH's QEMU dependency chain from pinned sources with the OpenHarmony
# Linux host native toolchain (the WSL counterpart of scripts/build-source-deps.ps1
# and scripts/build-source-meson.ps1).
#
# The toolchain is the public OpenHarmony release SDK, not the HarmonyOS SDK
# bundled with DevEco Studio; see docs/source-build-2026-11-14.md.
#
# Sources are taken from .temp/source-build/src and copied to a native Linux
# filesystem before building, because compiling on the 9p mount is slow.
# Results are copied back to .temp/source-build/linux/.
#
# Usage: OHOS_SDK_HOME=/root/ohos-sdk/linux scripts/build-source-linux.sh deps|qemu|all
#        TARGET_ARCH=x86_64 ... (default aarch64; x86_64 is for the HarmonyOS emulator)
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
base="$root/.temp/source-build"
sdk=${OHOS_SDK_HOME:-/root/ohos-sdk/linux}
native="$sdk/native"
work=${HISH_WORK:-/root/hish-build}
arch=${TARGET_ARCH:-aarch64}
case "$arch" in
  aarch64) cmake_arch=arm64-v8a; lse_flag='-D__ARM_LSE_ATOMIC_INLINES'; stage="$base/linux"; archwork="$work" ;;
  x86_64)  cmake_arch=x86_64;    lse_flag='';                             stage="$base/linux-x86_64"; archwork="$work/x86_64" ;;
  *) echo "unsupported TARGET_ARCH: $arch (use aarch64 or x86_64)" >&2; exit 2 ;;
esac
ohos_target="$arch-linux-ohos"
src="$work/src"
install="$archwork/install"
cross="$archwork/ohos-$arch.ini"
logs="$base/logs"
jobs=${JOBS:-$(nproc)}
source "$root/deps/libqemu/source.env"
qemu_src="$work/src/qemu-$QEMU_REVISION"
qemu_mode=${QEMU_TCI:-0}
qemu_suffix=
[ "$qemu_mode" = 1 ] && qemu_suffix=-tci

log() { printf '== %s\n' "$*"; }

require_sdk() {
  for f in "$native/llvm/bin/clang" "$native/sysroot/usr/include" "$native/build/cmake/ohos.toolchain.cmake"; do
    if [ ! -e "$f" ]; then
      echo "OpenHarmony Linux SDK incomplete: missing $f" >&2
      echo "Set OHOS_SDK_HOME to the directory that contains native/." >&2
      exit 1
    fi
  done
}

prepare_sources() {
  mkdir -p "$work"
  if [ -f "$work/.sources-ready" ]; then
    return
  fi
  mkdir -p "$src"
  for d in "$base/src"/*; do
    name=$(basename "$d")
    [[ "$name" = qemu* ]] && continue
    cp -a "$d" "$src/$name"
  done
  touch "$work/.sources-ready"
}

write_cross_file() {
  mkdir -p "$archwork"
  cat > "$cross" <<EOF
[binaries]
c = ['$native/llvm/bin/clang', '--target=$ohos_target', '--sysroot=$native/sysroot']
cpp = ['$native/llvm/bin/clang++', '--target=$ohos_target', '--sysroot=$native/sysroot']
ar = '$native/llvm/bin/llvm-ar'
strip = '$native/llvm/bin/llvm-strip'
pkg-config = 'pkg-config'
[host_machine]
system = 'linux'
cpu_family = '$arch'
cpu = '$arch'
endian = 'little'
[properties]
needs_exe_wrapper = true
[built-in options]
c_args = ['-fPIC', '-Wno-unused-command-line-argument', '-I$install/include']
c_link_args = ['-L$install/lib', '-fuse-ld=lld']
EOF
}

cmake_build() {
  local name=$1 srcdir=$2; shift 2
  local build="$archwork/build/$name" logfile="$logs/$name-linux.log"
  mkdir -p "$build"
  log "cmake configure $name"
  cmake -S "$srcdir" -B "$build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$native/build/cmake/ohos.toolchain.cmake" \
    -DOHOS_ARCH=$cmake_arch -DOHOS_PLATFORM=OHOS \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_FLAGS=-Wno-unused-command-line-argument -U HAVE_VISIBILITY \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_INSTALL_PREFIX="$install" "$@" > "$logfile" 2>&1
  log "cmake build $name"
  cmake --build "$build" --parallel "$jobs" >> "$logfile" 2>&1
  cmake --install "$build" >> "$logfile" 2>&1
}

meson_build() {
  local name=$1 srcdir=$2; shift 2
  local build="$archwork/build/$name" logfile="$logs/$name-linux.log"
  mkdir -p "$build"
  log "meson setup $name"
  meson setup --reconfigure "$build" "$srcdir" --cross-file "$cross" \
    --prefix "$install" --libdir lib --buildtype release --default-library static \
    --wrap-mode nodownload "$@" > "$logfile" 2>&1
  log "meson compile $name"
  meson compile -C "$build" -j "$jobs" >> "$logfile" 2>&1
  meson install -C "$build" >> "$logfile" 2>&1
}

build_deps() {
  require_sdk
  prepare_sources
  write_cross_file
  mkdir -p "$install" "$logs"
  export PKG_CONFIG_LIBDIR="$install/lib/pkgconfig:$install/share/pkgconfig"

  # zlib and PCRE2 are linked statically into libqemu-system-aarch64.so so the
  # shipped library keeps the dependency contract of the released build
  # (libslirp.so.0 and libc.so only, which the HAP and the system provide).
  cmake_build zlib "$src/zlib-1.3.1" -DBUILD_SHARED_LIBS=OFF
  # zlib 1.3.1's CMakeLists always builds the shared library as well; drop it so
  # the final link resolves -lz to the static archive.
  rm -f "$install"/lib/libz.so*
  cmake_build zstd "$src/zstd-1.5.7/build/cmake" \
    -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_SHARED=OFF \
    -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF
  cmake_build pcre2 "$src/pcre2-10.45" \
    -DPCRE2_BUILD_PCRE2_32=ON -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
    -DPCRE2_BUILD_PCRE2GREP=OFF -DPCRE2_BUILD_TESTS=OFF
  meson_build pixman "$src/pixman-0.42.2" \
    -Dgtk=disabled -Dlibpng=disabled -Dtests=disabled \
    -Dneon=disabled -Da64-neon=disabled -Darm-simd=disabled
  meson_build libffi "$src/libffi"
  meson_build glib "$src/glib-2.82.0" \
    -Dselinux=disabled -Dlibmount=disabled -Dlibelf=disabled -Dsysprof=disabled \
    -Dtests=false -Dinstalled_tests=false -Ddocumentation=false \
    -Dintrospection=disabled -Dnls=disabled
}

prepare_qemu() {
  local checkout="$base/src/qemu-ohos"
  if [ ! -d "$checkout/.git" ]; then
    git clone --no-checkout --depth 1 --branch "$QEMU_BRANCH" "$QEMU_REPOSITORY" "$checkout"
  fi
  if ! git -c safe.directory="$checkout" -C "$checkout" cat-file -e "$QEMU_REVISION^{commit}" 2>/dev/null; then
    git -c safe.directory="$checkout" -C "$checkout" fetch --depth 1 "$QEMU_REPOSITORY" "$QEMU_REVISION"
  fi
  # Export the pinned object, not the checkout's mutable HEAD or working tree.
  if [ ! -f "$qemu_src/.hish-source-revision" ]; then
    mkdir -p "$qemu_src"
    git -c safe.directory="$checkout" -c core.autocrlf=false -C "$checkout" archive --format=tar "$QEMU_REVISION" | tar -x -C "$qemu_src"
    printf '%s\n' "$QEMU_REVISION" > "$qemu_src/.hish-source-revision"
  fi
  test "$(cat "$qemu_src/.hish-source-revision")" = "$QEMU_REVISION"
}

build_qemu() {
  require_sdk
  prepare_qemu
  mkdir -p "$logs"
  local build="$archwork/build/qemu-$QEMU_REVISION$qemu_suffix"
  local logfile="$logs/qemu-$arch$qemu_suffix-linux.log"
  log "QEMU $QEMU_VERSION $QEMU_REVISION ($arch, TCI=$qemu_mode)"
  OHOS_SDK_HOME="$sdk" OHOS_DEPS_PREFIX="$install" TARGET_ARCH="$arch" \
    QEMU_TCI="$qemu_mode" BUILD_DIR="$build" JOBS="$jobs" \
    bash "$qemu_src/scripts/ohos/build.sh" > "$logfile" 2>&1
  bash "$qemu_src/scripts/ohos/verify.sh" "$build" "$arch" >> "$logfile" 2>&1
  log "qemu artifacts built in $build"
}

sync_results() {
  mkdir -p "$stage"
  rsync -a --delete "$install/" "$stage/install/"
  local build="$archwork/build/qemu-$QEMU_REVISION$qemu_suffix"
  if [ -d "$build" ]; then
    mkdir -p "$stage/qemu-build"
    if [ "$qemu_mode" = 1 ]; then
      cp -f "$build/libqemu-system-aarch64-tci.so" "$stage/qemu-build/"
    else
      cp -f "$build/libqemu-system-aarch64.so" "$build/libqemu-img.so" "$stage/qemu-build/"
      cp -f "$build/subprojects/slirp/libslirp.so.0.4.0" "$stage/qemu-build/"
    fi
    printf '%s\n' "$QEMU_REVISION" > "$stage/qemu-build/source-revision$qemu_suffix.txt"
  fi
  log "results copied to $stage"
}

case "${1:-}" in
  deps) build_deps; sync_results ;;
  qemu) build_qemu; sync_results ;;
  all) build_deps; build_qemu; sync_results ;;
  *) echo "usage: $0 deps|qemu|all" >&2; exit 2 ;;
esac

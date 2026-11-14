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
    [ "$name" = qemu ] && continue
    cp -a "$d" "$src/$name"
  done
  # Export QEMU from its git object store: a plain copy from the Windows
  # checkout carries CRLF line endings into the shell scripts. The tree is
  # pinned by the commit recorded in docs/source-build-2026-11-14.md.
  mkdir -p "$src/qemu"
  git -c safe.directory='*' -C "$base/src/qemu" archive --format=tar HEAD | tar -x -C "$src/qemu"
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

build_qemu() {
  require_sdk
  prepare_sources
  local build="$archwork/build/qemu" logfile="$logs/qemu-linux.log"
  mkdir -p "$build"
  cd "$build"
  # Use the code generators that belong to the GLib being linked. Ubuntu's
  # system gdbus-codegen is newer than 2.82 and emits calls to API that 2.82
  # does not provide.
  export PATH="$install/bin:$PATH"
  log "qemu configure"
  # LDFLAGS hides the statically linked dependency symbols so the library
  # exports the same surface as the released build instead of re-exporting
  # zlib, PCRE2, libffi and GLib internals.
  PKG_CONFIG_PATH= \
  PKG_CONFIG_LIBDIR="$install/lib/pkgconfig:$install/share/pkgconfig" \
  CFLAGS="$lse_flag -D_UAPI_LINUX_VIRTIO_VSOCK_H -D_UAPI_LINUX_VIRTIO_TYPES_H -D_UAPI_LINUX_VIRTIO_RING_H -D_UAPI_LINUX_VIRTIO_PMEM_H -D_UAPI_LINUX_VIRTIO_NET_H -D_UAPI_LINUX_VIRTIO_IOMMU_H -D_UAPI_LINUX_VIRTIO_FS_H -D_UAPI_LINUX_VIRTIO_CONSOLE_H -D_UAPI_LINUX_VIRTIO_CONFIG_H -D_LINUX_SYSINFO_H -UHAVE_OPENAT2_H -D__user= -D__force= -Wno-unused-command-line-argument -I$install/include/glib-2.0 -I$install/lib/glib-2.0/include -I$install/include/pixman-1 -L$install/lib" \
  LDFLAGS="-Wl,--exclude-libs,libglib-2.0.a -Wl,--exclude-libs,libgio-2.0.a -Wl,--exclude-libs,libgobject-2.0.a -Wl,--exclude-libs,libgmodule-2.0.a -Wl,--exclude-libs,libgthread-2.0.a -Wl,--exclude-libs,libgirepository-2.0.a -Wl,--exclude-libs,libz.a -Wl,--exclude-libs,libpcre2-8.a -Wl,--exclude-libs,libffi.a -Wl,--exclude-libs,libintl.a" \
  CC="$native/llvm/bin/$arch-unknown-linux-ohos-clang" \
  CXX="$native/llvm/bin/$arch-unknown-linux-ohos-clang++" \
  "$src/qemu/configure" --target-list=aarch64-softmmu --cross-prefix= --host-cc=cc \
    --disable-kvm --disable-xen --disable-rust --disable-docs --disable-werror \
    --enable-tcg --enable-lto --enable-strip --with-coroutine=sigaltstack \
    --enable-trace-backends=nop --disable-qom-cast-debug --disable-stack-protector \
    --disable-bsd-user --disable-guest-agent --disable-gcrypt --disable-debug-info \
    --disable-debug-tcg --enable-attr --disable-brlapi --disable-linux-aio \
    --disable-bzip2 --disable-cap-ng --disable-curl --disable-glusterfs \
    --disable-gnutls --disable-nettle --disable-gtk --disable-rdma --disable-libiscsi \
    --disable-vnc-jpeg --disable-lzo --disable-curses --disable-libnfs --disable-numa \
    --disable-opengl --disable-rbd --disable-vnc-sasl --disable-sdl --disable-seccomp \
    --disable-smartcard --disable-snappy --disable-spice --disable-libusb \
    --disable-usb-redir --disable-vde --disable-vhost-net --disable-virglrenderer \
    --disable-vte --disable-xen-pci-passthrough --enable-tools --disable-libudev \
    --disable-passt --enable-pixman --enable-vnc --enable-slirp --enable-virtfs \
    > "$logfile" 2>&1
  log "qemu make"
  make libqemu-system-aarch64.so -j "$jobs" >> "$logfile" 2>&1
  make libqemu-img.so -j "$jobs" >> "$logfile" 2>&1
  log "qemu artifacts built in $build"
}

sync_results() {
  mkdir -p "$stage"
  rsync -a --delete "$install/" "$stage/install/"
  if [ -d "$archwork/build/qemu" ]; then
    mkdir -p "$stage/qemu-build"
    cp -f "$archwork/build/qemu/libqemu-system-aarch64.so" "$stage/qemu-build/" 2>/dev/null || true
    cp -f "$archwork/build/qemu/libqemu-img.so" "$stage/qemu-build/" 2>/dev/null || true
    cp -f "$archwork/build/qemu/subprojects/slirp/libslirp.so.0.4.0" "$stage/qemu-build/" 2>/dev/null || true
  fi
  log "results copied to $stage"
}

case "${1:-}" in
  deps) build_deps; sync_results ;;
  qemu) build_qemu; sync_results ;;
  all) build_deps; build_qemu; sync_results ;;
  *) echo "usage: $0 deps|qemu|all" >&2; exit 2 ;;
esac

#!/usr/bin/env bash
#
# build-source-rootfs.sh —— 为 HiSH 构建 Alpine aarch64 rootfs（ext4 -> qcow2）
#
# 结构和预装镜像一致：openrc、自动登录 root、串口 ttyAMA0、9p 共享目录
# /mnt/share、DHCP 网络、qemu-guest-agent。
#
# 用法：
#   scripts/build-source-rootfs.sh                       # Alpine 3.24.4，128G 虚拟盘
#   ALPINE_VER=3.24.4 SIZE=16G OUT=./small.qcow2 scripts/build-source-rootfs.sh
#   EXTRA_PACKAGES="openssh docker" scripts/build-source-rootfs.sh
#
# 依赖（Debian/Ubuntu/WSL）：e2fsprogs qemu-utils qemu-user-static fakeroot curl
#
# 注意：LAB 必须是支持稀疏文件的 Linux 文件系统（ext4/xfs/btrfs）。放在
# /mnt/c、/mnt/d 这类 drvfs 挂载上会因不支持 sparse 而直接占满磁盘。
set -euo pipefail

ALPINE_VER="${ALPINE_VER:-3.24.4}"
ALPINE_BRANCH="${ALPINE_BRANCH:-v3.24}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
SIZE="${SIZE:-128G}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LAB="${LAB:-$HOME/.cache/hish-rootfs-lab}"
OUT="${OUT:-$HERE/.temp/source-build/images/rootfs_aarch64.qcow2}"
HOST_NAME="${HOST_NAME:-hish}"
TZNAME="${TZNAME:-Asia/Shanghai}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
KEEP_RAW="${KEEP_RAW:-0}"

# 烧进镜像的软件源（构建时仍用官方 CDN 下载）
APK_REPOS="${APK_REPOS:-https://mirrors.aliyun.com/alpine/${ALPINE_BRANCH}/main
https://mirrors.aliyun.com/alpine/${ALPINE_BRANCH}/community}"

ROOT="$LAB/root"
RAW="$LAB/rootfs.raw"
TGZ="$LAB/alpine-minirootfs-${ALPINE_VER}-aarch64.tar.gz"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for t in curl tar mke2fs qemu-img fakeroot; do
  command -v "$t" >/dev/null 2>&1 || die "缺少命令: $t"
done
HOST_ARCH=$(uname -m)
if [ "$HOST_ARCH" != "aarch64" ]; then
  command -v qemu-aarch64-static >/dev/null 2>&1 \
    || die "x86_64 主机需要 qemu-aarch64-static（apt install qemu-user-static）"
fi

mkdir -p "$LAB" "$(dirname "$OUT")"

TGZ_URL="$ALPINE_MIRROR/${ALPINE_BRANCH}/releases/aarch64/alpine-minirootfs-${ALPINE_VER}-aarch64.tar.gz"
if [ ! -f "$TGZ" ]; then
  log "下载 Alpine ${ALPINE_VER} aarch64 minirootfs"
  curl -fL --retry 3 -o "$TGZ.part" "$TGZ_URL"
  mv "$TGZ.part" "$TGZ"
fi

if [ "${VERIFY_MINIROOTFS:-1}" = "1" ]; then
  log "校验 minirootfs SHA256"
  if [ -n "${MINIROOTFS_SHA256:-}" ]; then
    printf '%s  %s\n' "$MINIROOTFS_SHA256" "$(basename "$TGZ")" > "$TGZ.sha256"
  else
    curl -fsSL --retry 3 -o "$TGZ.sha256" "$TGZ_URL.sha256" \
      || die "无法获取 $TGZ_URL.sha256"
  fi
  ( cd "$LAB" && sha256sum -c "$(basename "$TGZ").sha256" ) || die "minirootfs SHA256 校验失败"
fi

log "解包 minirootfs -> $ROOT"
rm -rf "$ROOT"
mkdir -p "$ROOT"
tar -xzf "$TGZ" -C "$ROOT" --no-same-owner

apk() {
  if [ "$HOST_ARCH" = "aarch64" ]; then
    "$ROOT/sbin/apk" --root "$ROOT" --no-scripts --no-cache "$@"
  else
    qemu-aarch64-static -L "$ROOT" "$ROOT/sbin/apk" --root "$ROOT" --no-scripts --no-cache "$@"
  fi
}

log "安装软件包（openrc / 网络栈 / qemu-guest-agent）"
# shellcheck disable=SC2086
apk add openrc openrc-user busybox-mdev-openrc ifupdown-ng bridge \
        qemu-guest-agent qemu-guest-agent-openrc $EXTRA_PACKAGES

log "写入 HiSH 定制文件"

cat > "$ROOT/init" <<'EOF'
#!/bin/sh
exec /sbin/init
EOF
chmod 755 "$ROOT/init"

cat > "$ROOT/usr/sbin/autologin" <<'EOF'
#!/bin/sh
clear
resize > /dev/null
echo -e "Uptime $(cut -d' ' -f1 /proc/uptime)s\n"
exec login -f root
EOF
chmod 755 "$ROOT/usr/sbin/autologin"

# tty1（VNC/本地控制台）与 ttyAMA0（QEMU 串口）都自动登录 root
cat > "$ROOT/etc/inittab" <<'EOF'
# /etc/inittab

::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

# Set up a couple of getty's
tty1::respawn:/sbin/getty -n -l /usr/sbin/autologin 38400 tty1 linux
#tty1::respawn:/sbin/getty 38400 tty1
#tty2::respawn:/sbin/getty 38400 tty2
#tty3::respawn:/sbin/getty 38400 tty3
#tty4::respawn:/sbin/getty 38400 tty4
#tty5::respawn:/sbin/getty 38400 tty5
#tty6::respawn:/sbin/getty 38400 tty6

# Put a getty on the serial port
ttyAMA0::respawn:/sbin/getty -L 0 ttyAMA0 xterm -n -l /usr/sbin/autologin

# Stuff to do for the 3-finger salute
::ctrlaltdel:/sbin/reboot

# Stuff to do before rebooting
::shutdown:/sbin/openrc shutdown

EOF

cat > "$ROOT/etc/motd" <<'EOF'
Welcome to Alpine Linux of HiSH!

You can install packages with: apk add <package>

EOF

printf '%s\n' "$HOST_NAME" > "$ROOT/etc/hostname"

cat > "$ROOT/etc/fstab" <<'EOF'
#/dev/cdrom	/media/cdrom	iso9660	noauto,ro 0 0
#/dev/usbdisk	/media/usb	vfat	noauto,ro 0 0
/dev/sda     /           ext4    defaults,noatime,nodiratime,errors=remount-ro             0  1
proc         /proc       proc    defaults,nosuid,nodev,noexec                              0  0
sysfs        /sys        sysfs   defaults,nosuid,nodev,noexec                              0  0
tmpfs        /tmp        tmpfs   defaults,noatime,nosuid,nodev,mode=1777,size=128M         0  0
tmpfs        /run        tmpfs   defaults,noatime,nosuid,nodev,mode=0755,size=64M          0  0
tmpfs        /dev/shm    tmpfs   defaults,noatime,nosuid,nodev,mode=1777,size=64M          0  0
none /dev/pts devpts gid=5,mode=620 0 0
hostshare /mnt/share 9p trans=virtio,version=9p2000.L 0 0
EOF

cat > "$ROOT/etc/network/interfaces" <<'EOF'
auto eth0
iface eth0 inet dhcp
EOF

# QEMU user-mode 网络的 DNS
printf 'nameserver 10.0.2.3\n' > "$ROOT/etc/resolv.conf"

printf '%s\n' "$APK_REPOS" > "$ROOT/etc/apk/repositories"

cat > "$ROOT/etc/sysctl.conf" <<'EOF'
# content of this file will override /etc/sysctl.d/*
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 3000
vm.vfs_cache_pressure = 200
vm.swappiness = 60
vm.min_free_kbytes = 16384
net.ipv4.tcp_fastopen = 3
EOF

mkdir -p "$ROOT/mnt/share"
: > "$ROOT/root/.profile"

if [ -f "/usr/share/zoneinfo/$TZNAME" ]; then
  cp "/usr/share/zoneinfo/$TZNAME" "$ROOT/etc/localtime"
else
  log "警告: 主机缺少 /usr/share/zoneinfo/$TZNAME，镜像保持 UTC"
fi

# 与预装镜像相同的 runlevel：sysinit=hwdrivers+mdev, default=networking+qemu-ga
mkdir -p "$ROOT/etc/runlevels"/{sysinit,boot,shutdown,default,nonetwork}
ln -sf /etc/init.d/hwdrivers        "$ROOT/etc/runlevels/sysinit/hwdrivers"
ln -sf /etc/init.d/mdev             "$ROOT/etc/runlevels/sysinit/mdev"
ln -sf /etc/init.d/networking       "$ROOT/etc/runlevels/default/networking"
ln -sf /etc/init.d/qemu-guest-agent "$ROOT/etc/runlevels/default/qemu-guest-agent"

# 精简 world，保持与预装镜像同样的“基础包 + qemu-guest-agent”形态
{
  cat <<'EOF'
alpine-baselayout
alpine-keys
alpine-release
apk-tools
busybox
busybox-mdev-openrc
libc-utils
openrc
qemu-guest-agent
EOF
  for p in $EXTRA_PACKAGES; do printf '%s\n' "$p"; done
} > "$ROOT/etc/apk/world"

log "生成 ext4 镜像（$SIZE，4K 块）"
rm -f "$RAW"
export ROOT RAW SIZE
fakeroot -- bash -c '
  set -e
  chown -R 0:0 "$ROOT"
  chmod 640 "$ROOT/etc/shadow"
  chmod 700 "$ROOT/root"
  truncate -s "$SIZE" "$RAW"
  mke2fs -q -F -t ext4 -O ^orphan_file,^metadata_csum_seed -d "$ROOT" "$RAW"
'

log "转换为 qcow2 -> $OUT"
qemu-img convert -p -O qcow2 "$RAW" "$OUT"
[ "$KEEP_RAW" = "1" ] || rm -f "$RAW"

PKG_COUNT=$(grep -c '^P:' "$ROOT/lib/apk/db/installed")
PKG_LIST="$OUT.packages.txt"
{
  printf '# Alpine %s (%s); generated by scripts/build-source-rootfs.sh\n' "$ALPINE_VER" "$ALPINE_BRANCH"
  printf '# repositories: %s\n' "$(printf '%s' "$APK_REPOS" | tr '\n' ' ')"
  printf '# packages: %s\n' "$PKG_COUNT"
  if [ "$HOST_ARCH" = "aarch64" ]; then
    "$ROOT/sbin/apk" --root "$ROOT" info -v 2>/dev/null
  else
    qemu-aarch64-static -L "$ROOT" "$ROOT/sbin/apk" --root "$ROOT" info -v 2>/dev/null
  fi | sort
} > "$PKG_LIST"
log "完成：$OUT"
printf '  sha256  : %s\n' "$(sha256sum "$OUT" | cut -d' ' -f1)"
printf '  包数量  : %s\n' "$PKG_COUNT"
printf '  包清单  : %s\n' "$PKG_LIST"
printf '  发行版  : Alpine %s (%s)\n' "$ALPINE_VER" "$ALPINE_BRANCH"
printf '  主机名  : %s\n' "$HOST_NAME"
qemu-img info "$OUT" | sed 's/^/  /'

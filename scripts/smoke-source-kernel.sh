#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
base="$root/.temp/source-build"
set +e
timeout 45s qemu-system-aarch64 \
  -machine virt -cpu max -accel tcg -smp 2 -m 512 -nographic \
  -kernel "$base/install/kernel_aarch64" \
  -append 'console=ttyAMA0 root=/dev/sda rw rootwait rootfstype=ext4 init=/sbin/init' \
  -drive "if=none,id=root,file=$root/feature/hish_main/src/main/resources/rawfile/vm/rootfs_aarch64.qcow2,format=qcow2" \
  -device virtio-scsi-pci,id=scsi0 -device scsi-hd,drive=root,bus=scsi0.0 \
  -nic none -snapshot > "$base/logs/kernel-boot.log" 2>&1
status=$?
set -e
printf 'QEMU exit status: %s (124 means bounded smoke-test timeout)\n' "$status"
if grep -q 'Kernel panic' "$base/logs/kernel-boot.log"; then
  echo 'Kernel panic detected; inspect kernel-boot.log'
  exit 1
fi
if ! grep -Eq 'login:|Welcome to Alpine|Starting.*init|Run /sbin/init' "$base/logs/kernel-boot.log"; then
  echo 'No userspace startup marker found; inspect kernel-boot.log'
  exit 1
fi
echo 'ARM64 kernel reached userspace startup; image writes were temporary (-snapshot), networking disabled'

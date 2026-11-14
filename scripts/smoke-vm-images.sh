#!/usr/bin/env bash
#
# Boot the rebuilt kernel and rootfs with the same QEMU devices the app uses and
# check that the guest reaches user space with the expected release, prompts,
# 9p share, network interface and QEMU guest agent.
#
# Usage:
#   scripts/smoke-vm-images.sh
#   KERNEL=... ROOTFS=... TIMEOUT=150 scripts/smoke-vm-images.sh
#
# Runs under WSL/Linux with qemu-system-aarch64 installed. The rootfs is opened
# with -snapshot, so the image file is never modified.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
base="$root/.temp/source-build"
kernel=${KERNEL:-$base/images/kernel_aarch64}
rootfs=${ROOTFS:-$base/images/rootfs_aarch64.qcow2}
log=${LOG:-$base/logs/vm-smoke.log}
timeout_s=${TIMEOUT:-140}
boot_wait=${BOOT_WAIT:-35}
expected_release=${EXPECTED_RELEASE:-6.12.117}
expected_alpine=${EXPECTED_ALPINE:-3.24.4}

[ -f "$kernel" ] || { echo "missing kernel: $kernel" >&2; exit 1; }
[ -f "$rootfs" ] || { echo "missing rootfs: $rootfs" >&2; exit 1; }
command -v qemu-system-aarch64 >/dev/null || { echo "qemu-system-aarch64 not found" >&2; exit 1; }

share=$(mktemp -d /tmp/hish-share-XXXXXX)
sockets=$(mktemp -d /tmp/hish-sockets-XXXXXX)
printf 'from host\n' > "$share/from-host.txt"
qga="$sockets/qga.sock"
qga_out="$sockets/qga-reply.json"
bios_dir="$root/feature/hish_main/src/main/resources/rawfile/vm"

# Ask the guest agent for its version through the same virtio-serial port the
# app connects to. Connection attempts start early and retry: connecting before
# the guest agent opens the port makes QEMU drop the client when it does.
python3 - "$qga" "$qga_out" "$((boot_wait - 8))" 30 <<'PY' &
import json, socket, sys, time
path, out, start, window = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
time.sleep(start)
deadline = time.time() + window
last = "no attempt"
while time.time() < deadline:
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(8)
        s.connect(path)
        # QGA does not greet first: synchronise, then ask for its version.
        s.sendall(json.dumps({"execute": "guest-sync", "arguments": {"id": 42}}).encode() + b"\n")
        s.recv(65536)
        s.sendall(json.dumps({"execute": "guest-info"}).encode() + b"\n")
        reply = s.recv(65536)
        if b"supported_commands" in reply:
            open(out, "wb").write(reply)
            raise SystemExit(0)
        last = reply.decode(errors="replace")[:200]
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 - recorded for the caller to inspect
        last = f"{type(exc).__name__}: {exc}"
    time.sleep(2)
open(out, "w").write(f"probe failed: {last}\n")
PY
probe_pid=$!

(
  sleep "$boot_wait"
  echo 'echo MARKER-RELEASE; uname -r'
  echo 'echo MARKER-ALPINE; cat /etc/alpine-release'
  echo 'echo MARKER-SHARE; mount | grep /mnt/share; ls /mnt/share'
  echo 'echo MARKER-NET; ip -4 addr show eth0 | grep inet'
  echo 'echo MARKER-AGENT; rc-service qemu-guest-agent status'
  sleep 30
  echo 'echo MARKER-DONE; poweroff -f'
) | timeout "$timeout_s" qemu-system-aarch64 \
  -machine virt,acpi=on,gic-version=max,iommu=none,its=off,usb=off,virtualization=off,memory-backend=mem0,compact-highmem=on,dump-guest-core=off,mem-merge=off,hmat=off \
  -cpu max,pauth-impdef=on,sve=off,pmu=off -accel tcg,thread=multi,tb-size=2048 \
  -smp 2 -object memory-backend-ram,id=mem0,size=1024M,merge=off,prealloc=off -m 1024M \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci-non-transitional,rng=rng0 \
  -L "$bios_dir" \
  -kernel "$kernel" \
  -device virtio-net-pci-non-transitional,netdev=eth0 -netdev user,id=eth0 \
  -fsdev local,security_model=mapped-file,id=fsdev0,path="$share" \
  -device virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=hostshare \
  -global virtio-blk-pci.scsi=off \
  -drive if=none,format=qcow2,file="$rootfs",id=hd0,cache=writeback,aio=threads,discard=unmap \
  -device virtio-scsi-pci-non-transitional,id=scsi0 \
  -device scsi-hd,drive=hd0,bus=scsi0.0,logical_block_size=4096,physical_block_size=4096,rotation_rate=1,bootindex=1 \
  -append "root=/dev/sda rw rootfstype=ext4 rootwait console=ttyAMA0 consoleblank=0 init=/init mitigations=off audit=0 panic=1" \
  -chardev socket,path="$qga",server=on,wait=off,id=qga0 \
  -device virtio-serial-pci-non-transitional,id=virtio-serial0 \
  -device virtserialport,chardev=qga0,bus=virtio-serial0.0,name=org.qemu.guest_agent.0 \
  -snapshot -nographic > "$log" 2>&1 || true

wait "$probe_pid" 2>/dev/null || true

fail=0
check() {
  local label=$1 pattern=$2
  if grep -qE "$pattern" "$log"; then
    printf 'PASS  %s\n' "$label"
  else
    printf 'FAIL  %s (pattern: %s)\n' "$label" "$pattern"
    fail=1
  fi
}

check 'kernel release line'      "Linux version ${expected_release//./\\.}"
check 'kernel uname in guest'    "MARKER-RELEASE"$'\r?\n'"${expected_release//./\\.}"
check 'Alpine release'           "MARKER-ALPINE"$'\r?\n'"${expected_alpine//./\\.}"
check '9p share mounted'         "hostshare on /mnt/share type 9p"
check 'host file visible'        "from-host\\.txt"
check 'eth0 has address'         "MARKER-NET"$'\r?\n'"inet "
check 'guest agent service'      "status: started"
check 'shell prompt'             "hish:~#"

if grep -q '"supported_commands"' "$qga_out" 2>/dev/null; then
  printf 'PASS  QGA guest-info over virtio-serial (%s)\n' "$(grep -o '"version": *"[^"]*"' "$qga_out" | head -1)"
else
  printf 'FAIL  QGA guest-info over virtio-serial: %s\n' "$(cat "$qga_out" 2>/dev/null | head -1)"
  fail=1
fi

rm -rf "$share" "$sockets"
printf 'log: %s\n' "$log"
exit "$fail"

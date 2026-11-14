# HiSH

[GitHub](https://github.com/harmoninux/HiSH) | [GitCode](https://gitcode.com/realhackeris/HiSH) | [Gitee](https://gitee.com/hackeris/HiSH) | [中文](README.md)

Run Linux Shell on HarmonyOS devices! Based on [qemu-ohos](https://github.com/harmoninux/qemu), both 2in1(PC), Tablet and Phone are supported.

![On multiple devices](docs/images/devices.png)

## How to get

You can try one of following methods to get HiSH:

- Install from [AppGallery](https://appgallery.huawei.com/app/detail?id=app.hackeris.hish) (JIT not supported, run slower)
- Download hap from [Releases page](https://github.com/harmoninux/HiSH/releases) and signed by yourself, then install to your device or emulator (JIT suported, runs faster)
- Build from source code in DevEco Studio, see [Build and install HAP](#build-hap) (JIT suported, runs faster)

## Core Features

- Complete arm64 Linux kernel
- Networking with port forwarding
- Alpine Linux rootfs
- Virtual Keys (Tab/Ctrl/Esc/Up/Down/Left/Right)
- Shared Folder
- JIT (enabled for dev builds through the debug profile ACL; the AppGallery build uses TCI because of store policy)
- Image import（[Ubuntu24.04](https://github.com/harmoninux/linux-config/releases/download/rootfs-20251213/ubuntu-base-24.04.zip) / [Debian12](https://github.com/harmoninux/linux-config/releases/download/release-20251129-debian/debian12.zip)）

# How to build

**Source builds are the default.** QEMU, its dependencies and the Linux kernel are built by the scripts in `scripts/` from pinned sources; the root filesystem is assembled by script (packages from the official Alpine repositories are used as-is). Downloaded prebuilt artifacts are fallbacks only. The full policy, pinned versions and the checks required for every change are in [docs/build-from-source.md](docs/build-from-source.md).

- HAP bundle
- libqemu-system
- Linux kernel (latest 6.12 LTS)
- rootfs (self-built)

## Build HAP

- Download and install [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)
- Clone this repo to local and run `git submodule update --init --recursive` in HiSH directory
- Copy `build-profile.template.json5` to `build-profile.json5`
- Produce the dependencies with the default source builds:
  - `libqemu-system`: see [Build libqemu-system](#build-libqemu-system)
  - kernel: see [Build Linux kernel](#build-linux-kernel)
  - rootfs: see [Build rootfs for Linux](#build-rootfs-for-linux)
- Build project in DevEco Studio
- Sign and run in your device or emulator. See [Running Your App on a Local Real Device](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ide-run-device) | [Signing an App Not Associated with a Registered App](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ide-signing#section151231211105010)

If you only need a quick local test without source builds, the following prebuilt artifacts can be used. **Record their source URL, version and SHA-256 under `docs/` and mark them as not built from source.**

- [libs.zip](https://github.com/harmoninux/qemu/releases/download/hish-20260110/libs.zip) (extract to `feature/hish_main/libs`)
- [kernel_aarch64](https://github.com/harmoninux/linux-config/releases/download/kernel-20260228/kernel_aarch64)
- [rootfs_aarch64.qcow2](https://github.com/harmoninux/linux-config/releases/download/rootfs-20260117/rootfs_aarch64.qcow2)

## Build libqemu-system

Build your own `libqemu-system-aarch64.so` for `feature/hish_main/libs/<abi>/` on Ubuntu (or WSL2 on Windows).

- Install dependencies
```shell
sudo apt install -y build-essential cmake curl wget unzip python3 libncurses-dev \
		git flex bison bash make autoconf libcurl4-openssl-dev tcl \
		gettext zip pigz meson
```
- Download "Command Line Tools" for Linux from https://developer.huawei.com/consumer/cn/download/ (the public OpenHarmony Release SDK also works; differences are documented in the build policy)
- Extract downloaded zip and set TOOL_HOME env variable to `command-line-tools` directory
- Change current directory to `deps` and run `make`, for x86_64 emulator default
  - For real devices(aarch64), you can run `make aarch64`
  - For Phone devices where JIT is unavailable, run `make aarch64-tci` to build QEMU with the TCG interpreter (TCI), producing `libqemu-system-aarch64-tci.so`. This is slower than JIT, but does not require JIT support.
```shell
cd deps
make
```
- See `*.so` files in `deps/output`

The repository also ships a validated WSL pipeline, `scripts/build-source-linux.sh`, which builds GLib, Pixman, zlib, zstd, PCRE2, libffi, libslirp and QEMU from pinned sources and records the artifact hashes; `arm64-v8a` (devices) is the default, `TARGET_ARCH=x86_64` builds the emulator variant. See [docs/source-build-2026-11-14.md](docs/source-build-2026-11-14.md).

## Build Linux kernel

By default the kernel comes from the **latest 6.12 stable release on kernel.org** (currently 6.12.117). The script downloads the source, checks its SHA-256 against kernel.org's `sha256sums.asc`, verifies that file's PGP signature when the kernel signing key is in the local keyring, and builds `Image` with the project's `arm64_virt` configuration:

```shell
# one-time import of the checksum signing key (optional but recommended)
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 632D3A06589DA6B1

# Run in WSL/Linux; without KERNEL_VERSION the script uses its current default
KERNEL_VERSION=6.12.117 scripts/build-source-kernel.sh
```

The image is written to `.temp/source-build/images/kernel_aarch64`; copy it to `feature/hish_main/src/main/resources/rawfile/vm/kernel_aarch64`. When bumping the version, update the version, SHA-256 and PGP verification result recorded under `docs/`.

A manual build is also possible (needs `aarch64-linux-gnu-gcc`, `bc`, `bison`, `flex`, `libssl-dev`, `libelf-dev`):

```shell
git clone --depth=1 -b v6.12 https://github.com/torvalds/linux
cd linux
curl https://raw.githubusercontent.com/harmoninux/linux-config/refs/heads/master/arm64_virt > .config
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image
```

Manual builds are for experimenting with the configuration; published images should come from the script so they can be reproduced and recorded.

## Build rootfs for Linux

By default the rootfs is assembled by script from the Alpine stable branch (currently 3.24.4) minirootfs plus `apk` packages, with HiSH's auto-login, serial console, 9p share, DHCP and guest agent configuration, then turned into ext4 and qcow2:

```shell
# Run in WSL/Linux; LAB must be on a filesystem that supports sparse files
scripts/build-source-rootfs.sh
```

The image is written to `.temp/source-build/images/rootfs_aarch64.qcow2`; copy it to `feature/hish_main/src/main/resources/rawfile/vm/rootfs_aarch64.qcow2`. The script also writes `rootfs_aarch64.qcow2.packages.txt` (distribution, repositories, the 34 packages and their versions), which is recorded in `manifest.json`. Tunables (`ALPINE_VER`, `SIZE`, `EXTRA_PACKAGES`, `OUT`, ...) are documented at the top of the script.

The packages inside the image come from the official Alpine `main`/`community` repositories and are signature-checked by `apk` at install time. Per the build policy, those official packages are used as-is and do not require a source rebuild.

You can unpack or mount the generated image to adjust its contents by hand, but images that go into a release must be reproducible from the script; manual edits are for experiments only.

## Verify the artifacts

Before committing images or libraries, run at least:

```shell
python scripts/verify-source-build.py     # ELF arch, Image/qcow2 headers, QEMU entry points, and committed images vs manifest
scripts/smoke-vm-images.sh                # boot the new kernel and rootfs, 9 runtime checks
```

Then update `.temp/source-build/manifest.json` with `powershell -File scripts/record-source-build.ps1` and add a dated build record under `docs/`.

# Star History

[![Star History Chart](https://star-history.dera.page/svg?repos=harmoninux/hish&type=Date)](https://star-history.dera.page/#harmoninux/hish&Date)

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

HiSH is a HarmonyOS application that runs a Linux Shell using QEMU. It's based on qemu-ohos and supports 2in1 (PC), tablet, and phone devices. The app provides a complete arm64 Linux kernel with network support, Alpine Linux root filesystem, virtual keys, shared folders, and VNC support.

The repository uses a single shared implementation module (`feature/hish_main`) with thin product modules under `product/phone` and `product/tablet`. The application bundle name is `dev.snoworwind.hish` (`AppScope/app.json5`).

## Source Build Policy (default)

Every component that ships in the HAP or in the guest image must be built from pinned sources, except the Huawei SDK, toolchain, NDK, and packages from the official Alpine `main`/`community` repositories (used as-is, no source rebuild required). Prebuilt downloads (`libs.zip`, `kernel_aarch64`, `rootfs_aarch64.qcow2`) are fallbacks only and must be documented with source URL, version and SHA-256. The full rules are in [docs/build-from-source.md](docs/build-from-source.md).

| Component | Default command | Output |
| --- | --- | --- |
| QEMU + native deps | `OHOS_SDK_HOME=/path/to/ohos-sdk/linux scripts/build-source-linux.sh all` (`TARGET_ARCH=x86_64` for the emulator ABI) | `.temp/source-build/linux/qemu-build/*.so` and `.temp/source-build/linux-x86_64/qemu-build/*.so`, copied to `feature/hish_main/libs/<abi>/` |
| Windows-toolchain deps | `scripts/build-source-deps.ps1`, `scripts/build-source-meson.ps1 -Only pixman\|glib` | `.temp/source-build/install/` |
| Linux kernel | `KERNEL_VERSION=<latest 6.12 LTS> scripts/build-source-kernel.sh` | `.temp/source-build/images/kernel_aarch64`, copied to `feature/hish_main/src/main/resources/rawfile/vm/kernel_aarch64` |
| rootfs | `scripts/build-source-rootfs.sh` | `.temp/source-build/images/rootfs_aarch64.qcow2`, copied to `feature/hish_main/src/main/resources/rawfile/vm/rootfs_aarch64.qcow2` |
| Format checks | `python scripts/verify-source-build.py` | exit status |
| Boot checks | `scripts/smoke-vm-images.sh` | 9 runtime checks, log in `.temp/source-build/logs/vm-smoke.log` |
| Provenance record | `powershell -File scripts/record-source-build.ps1` | `.temp/source-build/manifest.json` |

Version rules: kernel = latest 6.12 longterm on kernel.org (currently 6.12.117); rootfs = latest Alpine stable branch (currently 3.24.4), whose official `main`/`community` packages are used as-is (no source rebuild required) and recorded in `docs/rootfs-packages-*.txt` plus the manifest; QEMU = `harmoninux/qemu` branch `hish-libqemu` pinned to `50ce7096`; QEMU deps pinned per `manifest.json`. Bumping the kernel or rootfs requires `scripts/smoke-vm-images.sh` to pass before committing the images. Build details and the reasons behind the portability patches: [docs/source-build-2026-11-14.md](docs/source-build-2026-11-14.md) and [docs/vm-images-2026-11-14.md](docs/vm-images-2026-11-14.md).

## Build Commands

### Build HAP (HarmonyOS Application Package)

Use DevEco Studio to build the project:
- Install DevEco Studio from https://developer.huawei.com/consumer/cn/deveco-studio/
- Clone the repo and run `git submodule update --init --recursive`
- Copy `build-profile.template.json5` to `build-profile.json5`
- Produce the dependencies with the source builds above (`feature/hish_main/libs/<abi>/` and `feature/hish_main/src/main/resources/rawfile/vm/`)
- Build in DevEco Studio and sign for installation

`build-profile.json5` contains both `product/tablet` and `product/phone`; pick the product you need in DevEco Studio.

Signing: DevEco automatic signing writes a `signingConfigs` block into `build-profile.json5` (gitignored, passwords encrypted by the IDE) pointing at `~/.ohos/config/default_HiSH_*`; builds then emit `*-signed.hap`. Verify a package with `java -jar <sdk>/toolchains/lib/hap-sign-tool.jar verify-app -inFile <hap> -outCertChain <cer> -outProfile <p7b>`.

CLI equivalent (signed automatically when `signingConfigs` is present):

```powershell
$env:DEVECO_SDK_HOME='D:/D Program Files/DevEco Studio/sdk'
$env:NODE_HOME='D:/D Program Files/DevEco Studio/tools/node'
$env:JAVA_HOME='D:/D Program Files/DevEco Studio/jbr'
& 'D:/D Program Files/DevEco Studio/tools/node/node.exe' `
  'D:/D Program Files/DevEco Studio/tools/hvigor/bin/hvigorw.js' `
  --mode module -p product=default -p module=phone@default -p buildMode=debug assembleHap --no-daemon
```

### Build libqemu-system (Native QEMU Library)

The project's own build uses the HarmonyOS Linux Command Line Tools (Ubuntu or Windows WSL2):

```bash
# Install dependencies
sudo apt install -y build-essential cmake curl wget unzip python3 libncurses-dev \
    git flex bison bash make autoconf libcurl4-openssl-dev tcl \
    gettext zip pigz meson

# Download HarmonyOS Command Line Tools and set TOOL_HOME
export TOOL_HOME=/path/to/commandline/tools

cd deps
make            # x86_64 emulator
make aarch64    # arm64-v8a device
make aarch64-tci  # TCI build for devices without JIT
make clean
```

Build outputs are placed in `deps/output/` and copied to `feature/hish_main/libs/<abi>/` automatically. The alternative, hash-recording pipeline is `scripts/build-source-linux.sh` (see the policy section).

### Linting

The project uses `.clang-format` for C++ code formatting. Apply with:
```bash
clang-format -i feature/hish_main/src/main/cpp/**/*.cpp
```

## Architecture

### Application Entry Points
- `feature/hish_main/src/main/ets/entryability/EntryAbility.ets` - Shared ability that:
  - Loads user preferences
  - Extracts kernel, rootfs, BIOS ROM and keymaps from rawfile on first run, when `versionCode` changes, or for `dev.*` bundles
  - Prepares shared folders
  - Starts the default emulator VM
  - Handles background running state
- `product/phone/src/main/ets/entryability/EntryAbility.ets`, `product/tablet/...` - Product entry points re-exporting the shared ability

### UI Structure
- `feature/hish_main/src/main/ets/pages/Index.ets` - Main page, renders different layouts based on device type:
  - `PcIndex` - Full desktop layout with toolbar, terminal, and management dialogs
  - `PhoneOrTablet` - Mobile layout with terminal and optional status bar
- `feature/hish_main/src/main/ets/components/` - Reusable UI components:
  - `WebTerminal.ets` - xterm.js-based terminal interface with virtual keys
  - `VmStatusBar.ets` - VM resource monitoring display
  - `EmulatorListGrid.ets`, `EditEmulatorContent.ets` - Emulator management
  - `RootfsManagementContent.ets` - Root filesystem management
  - `SharedFolderContent.ets` - Shared folder file browser
  - `SettingsContent.ets` - Application settings

### Data Models (`feature/hish_main/src/main/ets/model/`)
- `Emulator.ets` - Core data structures:
  - `Emulator` - VM configuration (CPU, memory, port mapping, init path, etc.)
  - `PortMapping` - Network port forwarding rules
  - `RootFilesystem` - Available root filesystem images
  - `defaultEmulator`, `defaultRootfs` - Default configurations
- `appOption.ets` - Application-wide settings and preferences keys

### VM Management (`feature/hish_main/src/main/ets/lib/`)
- `startVm.ets` - Builds QEMU command line arguments and starts the VM:
  - Constructs QEMU args for machine, CPU, memory, kernel, network, drives, 9p shares, QMP/QGA sockets and VNC
  - Picks JIT vs TCI by bundle name: the marketplace bundles (`app.hackeris.hish`, `app.snoworwind.hish`) use `libqemu-system-aarch64-tci.so`, all other bundles (including `dev.snoworwind.hish`) use the JIT library
  - Calls native `napi.startVM()` via `libhish_main.so`
- `QemuAgent.ets`, `QemuAgentManager.ets` - QMP (QEMU Monitor Protocol) communication for VM control
- `terminalVirtualKeys.ets` - Virtual keyboard handling for mobile devices

### Native Layer (`feature/hish_main/src/main/cpp/`)
- `napi_init.cpp` - N-API bindings between ArkTS and native code:
  - `startVM()` - `dlopen()`s `libqemu-system-aarch64.so` (or the TCI variant) and `libqemu-img.so`, resolves `qemu_system_entry` / `qemu_img_entry`, and runs the VM on its own thread
  - `checkPortUsed()` - Checks if a port is in use
  - Serial output worker bridging the guest ttyAMA0 Unix socket to ArkTS callbacks

### VNC Subsystem (`feature/hish_main/src/main/cpp/`)
Three-thread architecture for VNC display rendering:

- **`napi_vnc.cpp`** - N-API bindings and poll thread management:
  - Poll thread: `WaitForMessage` + `HandleRFBServerMessage` loop (protected by `socketMutex_`)
  - TSFN notifications to JS for resize (status=1) and disconnect (status=-1)
  - Frame updates go directly to render thread via `markDirty()` (no TSFN)
  - **Critical**: Do NOT send duplicate `SendFramebufferUpdateRequest` or `SendIncrementalFramebufferUpdateRequest` — `rfbInitConnection` and `HandleRFBServerMessage` already send these; duplicates cause QEMU stream desync

- **`vnc_client.cpp`** / **`include/vnc_client.hpp`** - libvncclient wrapper:
  - RGB565 pixel format (16bpp, redMax=0x1f, greenMax=0x3f, blueMax=0x1f, shifts 11/5/0)
  - Encodings: zrle ultra hextile zlib copyrect raw (when LIBZ available)
  - `readTimeout=0` (infinite): non-zero causes spurious timeouts during ZRLE/zlib decode
  - `useRemoteCursor=FALSE`: QEMU cursor pseudo-encodings may cause stream desync
  - All socket I/O serialized via `socketMutex_` (libvncclient is NOT thread-safe)
  - `rfbClientLog`/`rfbClientErr` redirected to HiLog

- **`vnc_renderer.cpp`** / **`include/vnc_renderer.hpp`** - OpenGL ES renderer:
  - Render thread owns EGL context (JS thread releases after `init()`)
  - Condition variable wakeup on `markDirty()` or `surfaceResized_`
  - GLES 3.0 with GLES 2.0 fallback (VAO available on GLES 3.0)
  - Letterbox viewport via `calcViewport()` for aspect ratio preservation
  - `updateTexture()`: full `glTexImage2D` on resize, partial `glTexSubImage2D` for dirty regions (GLES 3.0), full fallback (GLES 2.0)

- **`utils.cpp`** / **`include/utils.hpp`** - HarmonyOS keycode to RFB keysym mapping

### Resources
- `feature/hish_main/src/main/resources/rawfile/vm/` - Kernel (`kernel_aarch64`), root filesystem (`rootfs_aarch64.qcow2`), BIOS ROM and keymaps
- `feature/hish_main/src/main/resources/rawfile/term/` - xterm.js terminal emulator (`term.html`, fonts, assets)
- `feature/hish_main/src/main/resources/rawfile/guide/` - User guide documentation
- `feature/hish_main/src/main/resources/rawfile/pages/` - Static pages such as `license.html`
- `feature/hish_main/libs/<abi>/` - `libqemu-system-aarch64.so`, `libqemu-img.so`, `libslirp.so.0`

### Dependencies (`deps/`)
Each dependency has its own Makefile. The main `deps/Makefile` orchestrates builds:
- `zstd`, `zlib` - Compression libraries
- `pcre2`, `libglib` - QEMU dependencies
- `pixman` - Graphics library
- `libqemu/` - QEMU source and build configuration
- `glib/` - Portability patches applied when building GLib for the OHOS target

## Key Technical Details

- **Device Detection**: Uses `deviceInfo.deviceType` to render appropriate UI ('2in1', 'tablet', 'phone')
- **Shared Folders**: Implemented via virtio-9p with 9p filesystem protocol (`hostshare`, plus `usershare` on 2in1)
- **Network**: User-mode networking with configurable port forwarding
- **VNC**: Optional VNC server with WebSocket support for GUI access
- **Storage**: Uses `@ohos.data.preferences` for persistent settings
- **Native Integration**: libhish_main.so provides the QEMU runtime interface via N-API
- **Guest images**: Kernel 6.12 LTS and an Alpine rootfs assembled by script; the guest auto-logs in as root on tty1 and ttyAMA0

## Native Build Requirements
- HarmonyOS Command Line Tools (set `TOOL_HOME` environment variable) or the public OpenHarmony SDK for Linux
- `OHOS_ARCH`: x86_64 (emulator) or aarch64 (device)
- `OHOS_ABI`: x86_64 or arm64-v8a
- Linux kernel builds: `aarch64-linux-gnu-gcc`, `bc`, `bison`, `flex`, `libssl-dev`, `libelf-dev`
- rootfs builds: `e2fsprogs`, `qemu-utils`, `qemu-user-static`, `fakeroot`; work directory on a sparse-file-capable filesystem

# 手机 ARM64 源码构建记录（2026-11-14）

本次从源码构建的产物保存在 `.temp/source-build/`，没有覆盖仓库里已下载的 QEMU 库、内核镜像或此前生成的 HAP。

| 目录 | 内容 |
| --- | --- |
| `.temp/source-build/install/` | 用 DevEco Studio 自带 Windows 版 Native SDK 交叉编译的库和内核 |
| `.temp/source-build/linux/install/` | 用 OpenHarmony Linux 版 Native SDK 在 WSL 中重新编译的同一批库 |
| `.temp/source-build/linux/qemu-build/` | 从源码构建的 `libqemu-system-aarch64.so`、`libqemu-img.so`、`libslirp.so.0.4.0` |
| `.temp/source-build/logs/` | 各组件构建日志、内核启动日志、工具链下载哈希 |

## 完成的组件

| 组件 | 版本 | 源码 | 产物 |
| --- | --- | --- | --- |
| zlib | 1.3.1 | zlib.net 源码包 | `lib/libz.a`（Linux 侧仅静态）、Windows 侧 `libz.so.1.3.1` |
| zstd | 1.5.7 | GitHub 发布包，应用仓库的 `deps/zstd/0001-qsort.diff` | `lib/libzstd.a` |
| PCRE2 | 10.45 | GitHub 发布包 | 静态库；Windows 侧另有 8/32 位共享库和 POSIX 包装库 |
| Pixman | 0.42.2 | cairographics 源码包 | `lib/libpixman-1.a` |
| libffi | meson-ports 分支 `meson`（`83d0cfd0`） | GLib 自带 `libffi.wrap` 指向的仓库 | `lib/libffi.a` |
| proxy-libintl | 0.4（`c03e1a74`） | GLib 自带 `proxy-libintl.wrap` 指向的 frida 仓库 | `lib/libintl.a` |
| GLib | 2.82.0 | download.gnome.org 源码包 | `libglib-2.0.a`、`libgio-2.0.a`、`libgobject-2.0.a`、`libgmodule-2.0.a`、`libgthread-2.0.a` |
| QEMU | 10.2.0（`hish-libqemu` 分支，`50ce7096`） | `github.com/harmoninux/qemu` | `libqemu-system-aarch64.so`（45,017,688 字节）、`libqemu-img.so`（4,612,448 字节） |
| libslirp | QEMU `slirp.wrap` 指定的 `26be815b` | gitlab.freedesktop.org/slirp | `libslirp.so.0.4.0` |
| Linux | 6.12.117 | kernel.org 源码 + README 指定的 `arm64_virt` 配置 | `images/kernel_aarch64`、`images/kernel.config`（旧的 6.12.0 构建仍在 `install/`） |

原生库的目标都是 `aarch64-linux-ohos`，在 x86_64 主机上交叉编译；Linux 客户机内核由 WSL 的 `aarch64-linux-gnu-gcc` 15.2.0 构建。

客户机内核后来升级到 6.12 最新长期支持版 6.12.117，并配上了自构建的 rootfs，详见 [vm-images-2026-11-14.md](vm-images-2026-11-14.md)。

## QEMU 构建

配置参数复制自 `deps/libqemu/Makefile`：`--target-list=aarch64-softmmu`、`--enable-tcg`、`--enable-vnc`、`--enable-slirp`、`--enable-virtfs`、`--with-coroutine=sigaltstack`，其余可选项按 Makefile 关闭。编译器使用 OpenHarmony Linux SDK 的 `aarch64-unknown-linux-ohos-clang`，链接器为 `ld.lld`，产物是和上游一致的共享库形式（`shared_library` 目标）。

真机用的 `arm64-v8a` 和模拟器用的 `x86_64` 都从同一份源码构建：默认 `TARGET_ARCH=aarch64`，模拟器版本加 `TARGET_ARCH=x86_64`，两套产物分别落在 `.temp/source-build/linux/qemu-build/` 和 `.temp/source-build/linux-x86_64/qemu-build/`。`libqemu-system-aarch64.so` 在两种 ABI 下的动态依赖都只有 `libslirp.so.0` 和 `libc.so`，并导出 `qemu_system_entry`。

`libqemu-system-aarch64.so` 的动态依赖为 `libslirp.so.0`、`libc.so`，并导出 `qemu_system_entry`；仓库当前预编译库依赖 `libslirp.so.0`、`libz.so`、`libc.so`。为保持这个依赖约定，zlib 和 PCRE2 在 Linux 侧只保留静态库，直接链进 QEMU 共享库，安装包里依然只需额外放 `libslirp.so.0`。

链接时用 `--exclude-libs` 隐藏 zlib、PCRE2、libffi、GLib 这些静态依赖的符号，避免新库额外导出几千个依赖内部符号。新库导出 21,275 个符号，预编译库为 22,332 个；两者都包含 `qemu_system_entry` 和（`libqemu-img.so` 的）`qemu_img_entry`，`libhish_main.so` 也只通过 `dlsym` 取这两个入口。差额是预编译库额外导出的依赖内部符号。

### 工具链来源

WSL 中使用的不是华为 HarmonyOS SDK，而是公开的 OpenHarmony 6.1 Release SDK：

- 下载地址：`https://repo.huaweicloud.com/openharmony/os/6.1-Release/ohos-sdk-windows_linux-public.tar.gz`
- 压缩包 SHA-256：`b833b75a64ee46bbd7880921abbb49b733ec5c8171b6684c9b524d57f624cee0`
- 使用其中的 `linux/native-linux-x64-6.1.0.31-Release.zip`

两套 SDK 的 clang 版本号都是 15.0.4，但 LLVM 提交号不同（Windows SDK 为 `99548401`，OpenHarmony SDK 为 `feef13a3`）。因此 Linux 侧产物可以证明“源码可编译”，但不能当作与 DevEco 工具链逐字节等价的产物。

## 遇到并修复的问题

- **GLib 缺 libffi 与 intl**：GLib 的 `libffi.wrap`、`proxy-libintl.wrap` 指向的源码分别检出到 `src/libffi` 和 `subprojects/proxy-libintl`，并把 Meson 的 wrap 模式从 `nofallback` 改为 `nodownload`，让本地子项目参与构建。
- **OHOS sysroot 的 `sockaddr_storage` 重复定义**：`sys/socket.h` 与 bionic 派生的 `linux/socket.h` 各定义一次，`gio/gnetworkmonitornetlink.c` 同时包含两者导致编译失败。新增补丁 `deps/glib/0001-ohos-netlink-sockaddr.patch`，在该编译单元跳过 `linux/socket.h` 并补上 `__kernel_sa_family_t`。
- **Windows 主机上 Meson 安装 gdb 脚本失败**：GLib 只为 `host_system == 'windows'` 跳过 gdb auto-load 脚本，交叉编译时目标系统是 linux，但安装路径带盘符冒号，Meson 报 WinError 123。新增补丁 `deps/glib/0002-windows-host-gdb-autoload.patch`，在构建机为 Windows 时同样跳过这两个调试脚本。
- **gdbus-codegen 版本不一致**：QEMU 用 PATH 上的 `gdbus-codegen` 生成 D-Bus 代码，Ubuntu 自带版本比 GLib 2.82 新，生成了 `g_variant_builder_init_static`，链接时报未定义符号。构建脚本改为优先使用 `install/bin/gdbus-codegen`，即与所链接 GLib 同版本的生成器。
- **Windows 检出的 CRLF 破坏 QEMU 脚本**：从 `/mnt/d` 直接复制源码会保留 CRLF，`configure` 报 `#!/bin/sh^M`。WSL 侧改为用 `git archive` 从对象库导出 LF 源码树。
- **zlib 的 CMake 总是同时构建共享库**：删除安装目录中的 `libz.so*`，让最终链接解析到 `libz.a`。

## 验证

`python scripts/verify-source-build.py` 的输出：

- 12 个共享库具备 ELF64、小端、AArch64 标识；
- `kernel_aarch64` 带合法的 Linux arm64 Image 头，声明大小 11,993,088 字节；
- `libqemu-system-aarch64.so` 为 AArch64 共享对象，导出 `qemu_system_entry`，`libqemu-img.so` 同样为 AArch64；
- x86_64 版本为 ELF x86-64 共享对象，同样导出 `qemu_system_entry` 和 `qemu_img_entry`；
- 两种 ABI 的动态依赖都只有 `libslirp.so.0` 和 `libc.so`；
- 与仓库原有预编译库对比，`qemu_system_entry`、`qemu_img_entry` 都在，且 `vnc_`、`slirp_`、`qemu_chr_`、`tcg_` 等符号组数量一致。

上一轮已完成的内核启动测试仍然有效：WSL QEMU 以 TCG、禁用网络、`-snapshot` 临时磁盘写入方式启动新内核和原有根文件系统，日志出现 `Welcome to Alpine Linux of HiSH!`、root 登录及 `hish:~#` 提示符，原始镜像未被修改。

这些检查证明产物格式和符号正确。新库已经替换进 `feature/hish_main/libs/arm64-v8a/` 和 `feature/hish_main/libs/x86_64/`，打进了 `phone`、`tablet` 的 HAP，并在 HarmonyOS 真机上安装启动验证通过（详见 [vm-images-2026-11-14.md](vm-images-2026-11-14.md)）。

## 使用这些产物

源码构建的库已经按下面的对应关系替换进仓库并打包：

1. `feature/hish_main/libs/arm64-v8a/libqemu-system-aarch64.so` ← `.temp/source-build/linux/qemu-build/libqemu-system-aarch64.so`
2. `feature/hish_main/libs/arm64-v8a/libqemu-img.so` ← `.temp/source-build/linux/qemu-build/libqemu-img.so`
3. `feature/hish_main/libs/arm64-v8a/libslirp.so.0` ← `.temp/source-build/linux/qemu-build/libslirp.so.0.4.0`
4. `feature/hish_main/libs/x86_64/` 下的同三个文件 ← `.temp/source-build/linux-x86_64/qemu-build/`
5. 内核来自 `scripts/build-source-kernel.sh`，见 [vm-images-2026-11-14.md](vm-images-2026-11-14.md)

替换后用 hvigor 重新构建 `product/phone` 和 `product/tablet`；打包时 hvigor 会对 `.so` 做 strip，因此 HAP 里的文件比源文件小。构建出的包仍未签名，也没有在设备上验证运行。

## 日志与来源

`.temp/source-build/manifest.json` 记录源码地址、下载包 SHA-256、补丁哈希、源码提交、SDK 信息和产物哈希；`logs/` 保存每个组件的构建日志、`kernel-boot.log`、`sdk-sha256.txt`。

这些哈希是本次下载和构建记录，并非上游签名验证，也不证明可复现或源码无恶意。

## 重新构建

默认构建规则和版本要求见 [源码构建策略](build-from-source.md)；下面是本次用到的脚本。

- `scripts/build-source-deps.ps1`：Windows 工具链构建 zlib、zstd、PCRE2。
- `scripts/build-source-meson.ps1 -Only pixman|libffi|glib`：Windows 工具链构建 Meson 项目。
- `OHOS_SDK_HOME=/root/ohos-sdk/linux scripts/build-source-linux.sh deps|qemu|all`：WSL 中用 OpenHarmony Linux SDK 重建依赖和 QEMU；`TARGET_ARCH=x86_64` 构建模拟器用的版本。
- `scripts/build-source-kernel.sh`：在 WSL 中构建客户机内核（当前为 6.12.117）。
- `scripts/build-source-rootfs.sh`：在 WSL 中组装 Alpine rootfs 并生成 qcow2。
- `scripts/smoke-source-kernel.sh`：旧内核的限时启动测试，原始磁盘不落盘写入。
- `scripts/smoke-vm-images.sh`：同时启动当前内核与 rootfs，检查串口、9p、网络和 guest agent。
- `scripts/record-source-build.ps1`、`scripts/verify-source-build.py`：更新记录与校验产物。

这些脚本依赖已准备好的源码目录，不是完整的一键下载或可复现构建系统。

## 尚未完成

- 已在 HarmonyOS 真机安装并启动验证：内核、rootfs 和 QEMU 库都能正常加载，虚拟机进入 Alpine 用户态；尚未做负载、VNC 图形等压力测试。
- 只构建了 JIT（TCG）变体；商店版使用的 TCI 变体需要额外加 `--enable-tcg-interpreter`，本轮没有构建。
- 根文件系统已改为自行组装（见 [vm-images-2026-11-14.md](vm-images-2026-11-14.md)）；其中的 Alpine 官方软件包按策略直接使用、无需源码重建。终端前端 `xterm.js` 等发布资源尚未从源码重建。
- 没有做两次独立构建的产物比对，因此不能声称可复现构建。
- 内核使用 6.12 源码配合标注为 6.12.60 的配置，是“6.12 源码构建”，不是发布版内核的复现。

# 源码构建策略（默认）

本文规定 HiSH 的默认构建方式。除华为官方 SDK、工具链、NDK，以及 Alpine 官方仓库的软件包之外，**进入 HAP 的组件和客户机镜像都从固定版本的源码构建**，并记录来源、校验和产物哈希。

仓库不再把下载的 `libs.zip`、`kernel_aarch64`、`rootfs_aarch64.qcow2` 当作默认依赖。这些预编译产物只能作为快速回退：使用时必须在文档里登记来源、版本和 SHA-256，并标明“未从源码构建”。

## 默认流水线

构建在 Linux（或 Windows WSL2）中执行，部分依赖脚本也可直接在 Windows PowerShell 中运行，脚本都放在 `scripts/`。产物默认写到 `.temp/source-build/`，随后复制进仓库。

| 步骤 | 命令 | 产物与去向 |
| --- | --- | --- |
| 1. 原生依赖与 QEMU | `OHOS_SDK_HOME=/path/to/ohos-sdk/linux scripts/build-source-linux.sh all`；模拟器的 x86_64 版本加 `TARGET_ARCH=x86_64` | `.temp/source-build/linux/qemu-build/` 或 `.temp/source-build/linux-x86_64/qemu-build/` 下的 `libqemu-system-aarch64.so`、`libqemu-img.so`、`libslirp.so.0.4.0`，手动复制到 `feature/hish_main/libs/<abi>/` |
| 1b. Windows 工具链备选 | `scripts/build-source-deps.ps1`、`scripts/build-source-meson.ps1 -Only pixman\|glib` | `.temp/source-build/install/` |
| 2. 内核 | `KERNEL_VERSION=<6.12 最新 LTS> scripts/build-source-kernel.sh` | `.temp/source-build/images/kernel_aarch64`，手动复制到 `feature/hish_main/src/main/resources/rawfile/vm/kernel_aarch64` |
| 3. 根文件系统 | `scripts/build-source-rootfs.sh` | `.temp/source-build/images/rootfs_aarch64.qcow2`，手动复制到 `feature/hish_main/src/main/resources/rawfile/vm/rootfs_aarch64.qcow2` |
| 4. 格式校验 | `python scripts/verify-source-build.py` | 检查 ELF 架构、内核 Image 头、qcow2 头、QEMU 入口符号，并比对 `rawfile/vm/` 镜像与 manifest 哈希 |
| 5. 启动验证 | `scripts/smoke-vm-images.sh` | 启动新内核与 rootfs，串口、9p、网络、guest agent 共 9 项检查 |
| 6. 记录 | `powershell -File scripts/record-source-build.ps1` | 更新 `.temp/source-build/manifest.json`；同时在 `docs/` 新增一份带日期的构建记录 |

替换仓库内镜像前先备份原文件，例如 `.temp/source-build/original-images/`。

## 当前状态

- 内核 6.12.117 与 Alpine 3.24.4 rootfs 已按本策略生成并替换进 `feature/hish_main/src/main/resources/rawfile/vm/`。
- QEMU 及其依赖已按本策略从源码构建，替换进 `feature/hish_main/libs/arm64-v8a/` 和 `feature/hish_main/libs/x86_64/`，并随 `phone`、`tablet` 的 HAP 一起打包（打包时由 hvigor 做 strip）。arm64-v8a 用默认参数构建，x86_64 用 `TARGET_ARCH=x86_64` 构建。已在 HarmonyOS 真机上安装并启动验证，内核、rootfs 和 QEMU 库都被正确加载（见 `docs/vm-images-2026-11-14.md` 的“真机验证”一节）。
- `phone`、`tablet` 的 HAP 已在 DevEco Studio 里用自动签名完成签名，签名材料位于 `~/.ohos/config`，`build-profile.json5` 在 `.gitignore` 中；`hap-sign-tool verify-app` 验证通过。
- `scripts/verify-source-build.py` 会比对 `rawfile/vm/` 中镜像与 `manifest.json` 记录的哈希，防止镜像被悄悄换回来源不明的版本。

## 版本规则

- **内核**：始终使用 kernel.org 上 6.12 系列最新的长期支持版本（当前 6.12.117），不要用 `master` 或未发布的 rc 快照。下载 kernel.org 的压缩包并对照 `sha256sums.asc` 校验 SHA-256；本地导入了内核校验和签名公钥（`gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 632D3A06589DA6B1`）时，脚本同时校验该文件的 PGP 签名，构建记录里要写明是否完成了签名校验。
- **根文件系统**：使用 Alpine 最新稳定分支（当前 3.24.4），从官方 minirootfs 加 `apk` 包组装，结构和定制项由 `scripts/build-source-rootfs.sh` 固定。
- **QEMU**：`github.com/harmoninux/qemu` 的 `hish-libqemu` 分支，固定提交（当前 `50ce7096`），不跟随分支更新。`arm64-v8a`（真机）与 `x86_64`（模拟器）都从同一提交构建。
- **QEMU 依赖**：GLib、Pixman、zlib、zstd、PCRE2、libffi 使用固定源码包版本，具体见 `.temp/source-build/manifest.json` 与 `docs/source-build-2026-11-14.md`。
- **华为工具链**：允许使用官方发行的 DevEco Studio、HarmonyOS SDK 和签名工具。Linux 侧使用公开的 OpenHarmony SDK 时，必须在文档中写明与华为 SDK 的差异（clang 版本、LLVM 提交等）。

## 客户机用户态（rootfs 内的软件）

Alpine 官方仓库（`main` / `community`）提供的软件包属于允许的可信基础，**不需要从源码编译**。镜像本身仍由本仓库脚本生成，只有包内容是 Alpine 的二进制。

当前镜像预装 34 个这样的包，完整清单由脚本输出到 `rootfs_aarch64.qcow2.packages.txt`、记入 `manifest.json`，并提交为 `docs/rootfs-packages-2026-11-14.txt`：musl、busybox、openrc、apk-tools、ifupdown-ng、qemu-guest-agent，以及 glib、pcre2、zlib、libffi、openssl 等依赖。安装时由 `apk` 用镜像内的 `alpine-devel@lists.alpinelinux.org-*.rsa.pub` 验签。

默认规则：

- 只允许 Alpine 官方 `main` / `community` 仓库；启用第三方仓库或使用其他来源的二进制时，仍然需要从源码构建或单独登记来源与哈希。
- 包集合只能由 `scripts/build-source-rootfs.sh` 生成，不允许手工往镜像里拷贝二进制。
- 发行版分支固定在脚本的 `ALPINE_VER` / `ALPINE_BRANCH`；每次构建都输出包清单，并与镜像一起记录哈希。
- 同一分支内 Alpine 会更新补丁版本，重新构建可能得到不同的包版本，所以“能重建”不等于“字节可复现”；要固定版本需要锁定具体包版本或仓库快照。

## 每次变更的强制要求

1. 不提交来源不明的 `.so`、`.a`、内核或磁盘镜像。确需预编译产物时，必须登记来源 URL、版本、SHA-256、使用原因，并在文档中写明未从源码构建。
2. 构建脚本必须可重复执行：版本固定、下载后校验哈希、失败立即退出。
3. 升级内核或 rootfs 后，必须跑通 `scripts/smoke-vm-images.sh` 才允许提交镜像。
4. 产物哈希写入 `manifest.json`，并新增一份 `docs/*-<日期>.md` 记录本次构建。
5. 客户机内由用户后续 `apk add` 安装的软件不在本策略范围内；但发布镜像里预装的软件包必须由脚本生成，不能手工拷贝。

## 已知例外

- 鸿蒙侧 `libentry.so`、VNC 客户端等随 HAP 编译，依赖华为 NDK，属于允许的可信基础。
- 终端前端 `xterm.js`（`feature/hish_main/src/main/resources/rawfile/term/`）仍是仓库内的发布文件，尚未从源码重建，列为待办。
- 内核配置沿用项目的 `arm64_virt` 配置（`docs/vm-images-2026-11-14.md` 有说明），没有逐项安全审查。

## 参考记录

- `docs/source-build-2026-11-14.md`：QEMU 与原生依赖、内核的源码构建过程、修复过的问题与验证证据。
- `docs/vm-images-2026-11-14.md`：当前内核 6.12.117 与自构建 Alpine 3.24.4 rootfs 的详细信息。

## English summary

By default every component that ships in the HAP or in the guest image must be built from pinned sources, except the Huawei SDK, toolchain and NDK, and packages from the official Alpine `main`/`community` repositories. Those Alpine packages are used as-is (signature-checked by `apk` at install time) and do not need a source rebuild; the image itself is still assembled by `scripts/build-source-rootfs.sh`, and the exact package set is recorded in `docs/rootfs-packages-*.txt` and the manifest. The `scripts/` pipeline builds QEMU and its dependencies plus the latest 6.12 LTS kernel, verifies the artifacts (`verify-source-build.py`) and boots them (`smoke-vm-images.sh`). Prebuilt downloads are fallbacks only, and must be documented with source URL, version and SHA-256. Every build updates `.temp/source-build/manifest.json` and adds a dated record under `docs/`.

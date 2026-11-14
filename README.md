# HiSH

[GitHub](https://github.com/harmoninux/HiSH) | [GitCode](https://gitcode.com/realhackeris/HiSH) | [Gitee](https://gitee.com/hackeris/HiSH) | [English](README_EN.md)

在HarmonyOS设备上运行Linux Shell。基于[qemu-ohos](https://github.com/snoworwind/qemu-ohos)，支持2in1(PC)、平板和手机。

当前 QEMU 组件为自维护的 [qemu-ohos](https://github.com/snoworwind/qemu-ohos)，基于官方稳定版 **11.1.3**；来源和提交固定在 `deps/libqemu/source.env`。手机、平板和 PC 的开发版默认使用 **JIT**，TCI 仅作显式兼容选项。构建与迁移记录见 [QEMU 组件升级](docs/qemu-component-2026-11-14.md)。

![多设备运行](docs/images/devices.png)

## 如何获取

可以选择下面任一方法获取HiSH：

- 通过[应用市场](https://appgallery.huawei.com/app/detail?id=app.hackeris.hish)安装（因应用市场政策限制，不支持JIT，运行效率一般）
- 从[Releases](https://github.com/harmoninux/HiSH/releases)下载hap文件，自行签名后安装到设备或模拟器（支持JIT，运行效率更高。安装方法见：[使用教程](https://github.com/harmoninux/HiSH/discussions/130)）
- 使用 DevEco Studio 编译源码安装，参考 [构建并安装HAP](#构建hap)（支持JIT，运行效率更高）

## 核心功能

- 完整的arm64 Linux内核
- 网络支持，并支持端口转发
- Alpine Linux根文件系统
- 虚拟按键（Tab/Ctrl/Esc/Shift/Fn/方向键）
- 共享文件夹
- JIT（开发版通过调试 Profile 的 ACL 权限启用；商店版受应用市场政策限制使用 TCI）
- 镜像导入（[Ubuntu24.04镜像](https://github.com/harmoninux/linux-config/releases/download/rootfs-20251213/ubuntu-base-24.04.zip) / [Debian12镜像](https://github.com/harmoninux/linux-config/releases/download/release-20251129-debian/debian12.zip)）

## 使用指南

参考 [使用指南](docs/guide)

## 讨论交流

QQ群二维码

<img src="docs/images/qq_group.jpg" width="200"/>

## 授权许可

使用本项目代码，按照[惯例](https://www.n.cn/share/r1/d256b59a563047a3a052e58042ae2547)需在软件本体"关于"中注明基于本项目（HiSH）以及本项目的仓库地址。

# 构建指南

**默认从源码构建**：QEMU 及其依赖、Linux 内核都由 `scripts/` 从固定源码构建，根文件系统由脚本组装（其中 Alpine 官方仓库的软件包直接使用）；下载的预编译产物只作为快速回退。完整规则、版本要求和每次变更的强制检查见 [源码构建策略](docs/build-from-source.md)。

- HAP包
- libqemu-system库
- Linux内核（6.12 最新 LTS）
- 根文件系统（自建）

## 构建HAP

* 下载安装 [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)
* 克隆代码到本地，并执行 `git submodule update --init --recursive` 拉取子模块代码
* 复制`build-profile.template.json5`到`build-profile.json5`
* 按默认策略生成依赖：
  * `libqemu-system` 库：参考 [构建libqemu-system](#构建libqemu-system)
  * 内核：参考 [构建Linux内核](#构建linux内核)
  * 根文件系统：参考 [构建Linux根文件系统](#构建linux根文件系统)
* 在DevEco Studio中构建项目（`build-profile.json5` 中同时包含 `product/tablet` 和 `product/phone`，构建时选择需要的 product）
* 签名后在设备或模拟器上运行。参考 [本地真机运行应用](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-run-device) | [自动签名-未关联注册应用](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing#section151231211105010)

如果只是临时验证、不走源码构建，可以从下面地址下载预编译产物；**使用后必须在 `docs/` 中登记来源、版本和 SHA-256，并注明未从源码构建**：

- [libs.zip](https://github.com/harmoninux/qemu/releases/download/hish-20260110/libs.zip)（解压到`feature/hish_main/libs`）
- [kernel_aarch64](https://github.com/harmoninux/linux-config/releases/download/kernel-20260228/kernel_aarch64)
- [rootfs_aarch64.qcow2](https://github.com/harmoninux/linux-config/releases/download/rootfs-20260117/rootfs_aarch64.qcow2)

## 构建libqemu-system

在Ubuntu或Windows的WSL2环境下构建自定义的`libqemu-system-aarch64.so`，产物放到 `feature/hish_main/libs/<abi>/`。

* 安装依赖：

```shell
sudo apt install -y build-essential cmake curl wget unzip python3 libncurses-dev \
    git flex bison bash make autoconf libcurl4-openssl-dev tcl \
    gettext zip pigz meson
```

* 从[华为开发者官网](https://developer.huawei.com/consumer/cn/download/)下载Linux版"Command Line Tools"（国内网络也可使用公开的 OpenHarmony Release SDK，差异见 [源码构建策略](docs/build-from-source.md)）
* 解压后将`TOOL_HOME`环境变量设置为解压目录
* 进入`deps`目录运行`make`（默认针对x86_64模拟器）：
    * 针对真机的构建（arm64-v8a），需要执行`make aarch64`
    * 针对不支持JIT的Phone设备，可执行`make aarch64-tci`，使用QEMU TCG解释器（TCI）构建，并生成`libqemu-system-aarch64-tci.so`。TCI性能低于JIT，但不依赖JIT支持。
```shell
cd deps
make
```
* 构建产物位于`deps/output`目录

本仓库另外提供了一条已验证的 WSL 流水线：`scripts/build-source-linux.sh`，它从固定版本的源码构建 GLib、Pixman、zlib、zstd、PCRE2、libffi、libslirp 和 QEMU，并记录每次构建的哈希；真机的 `arm64-v8a` 用默认参数，模拟器的 `x86_64` 加 `TARGET_ARCH=x86_64`。说明见 [docs/source-build-2026-11-14.md](docs/source-build-2026-11-14.md)。

## 构建Linux内核

默认使用 kernel.org 上 **6.12 系列最新的长期支持版本**（当前 6.12.117）从源码构建。脚本会下载源码、对照 kernel.org 的 `sha256sums.asc` 校验 SHA-256，本地已导入内核签名公钥时还会校验该文件的 PGP 签名，然后用项目的 `arm64_virt` 配置生成 `Image`：

```shell
# 一次性导入校验和签名公钥（可选，但推荐）
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 632D3A06589DA6B1

# 在 WSL/Linux 中执行；不指定 KERNEL_VERSION 时使用脚本内的当前默认版本
KERNEL_VERSION=6.12.117 scripts/build-source-kernel.sh
```

产物位于 `.temp/source-build/images/kernel_aarch64`，复制到 `feature/hish_main/src/main/resources/rawfile/vm/kernel_aarch64`。升级版本时同时更新 `docs/` 里记录的版本、SHA-256 和 PGP 校验结果。

也可以手工构建（需要 `aarch64-linux-gnu-gcc`、`bc`、`bison`、`flex`、`libssl-dev`、`libelf-dev`）：

```shell
git clone --depth=1 -b v6.12 https://github.com/torvalds/linux
cd linux
curl https://raw.githubusercontent.com/harmoninux/linux-config/refs/heads/master/arm64_virt > .config
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image
```

手工构建只用于调试配置；提交的镜像应当来自上面的脚本，便于复现和记录。

## 构建Linux根文件系统

默认用脚本从 Alpine 最新稳定分支（当前 3.24.4）的 minirootfs 加 `apk` 包组装，写入 HiSH 的自动登录、串口控制台、9p 共享目录、DHCP 和 guest agent 配置，再生成 ext4 和 qcow2：

```shell
# 在 WSL/Linux 中执行；LAB 目录必须位于支持稀疏文件的文件系统上
scripts/build-source-rootfs.sh
```

产物位于 `.temp/source-build/images/rootfs_aarch64.qcow2`，复制到 `feature/hish_main/src/main/resources/rawfile/vm/rootfs_aarch64.qcow2`。脚本同时输出包清单 `rootfs_aarch64.qcow2.packages.txt`（发行版、软件源、34 个包及版本），该清单会写入 `manifest.json`。可调参数（`ALPINE_VER`、`SIZE`、`EXTRA_PACKAGES`、`OUT` 等）写在脚本头部。

镜像里的软件包来自 Alpine 官方 `main`/`community` 仓库，由 `apk` 验签安装；按 [源码构建策略](docs/build-from-source.md)，这些官方包直接使用，不要求从源码重建。

需要手工调整镜像内容时，可以解包或挂载脚本生成的镜像修改，但发布用的镜像必须能由脚本重新生成；手工修改只用于试验。

## 校验构建产物

提交镜像或库之前，至少跑完下面两项：

```shell
python scripts/verify-source-build.py     # ELF 架构、Image/qcow2 头、QEMU 入口符号，并比对镜像与 manifest 记录
scripts/smoke-vm-images.sh                # 启动新内核与 rootfs，9 项运行检查
```

随后用 `powershell -File scripts/record-source-build.ps1` 更新 `.temp/source-build/manifest.json` 的产物哈希，并在 `docs/` 新增本次构建记录。

# Star history

[![星标历史图表](https://star-history.dera.page/svg?repos=harmoninux/hish&type=Date)](https://star-history.dera.page/#harmoninux/hish&Date)

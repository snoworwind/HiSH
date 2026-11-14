# HiSH QEMU 组件升级：11.1.3 鸿蒙定制版

HiSH 的默认 QEMU 来源已从 `harmoninux/qemu` 10.2.0 切换到自维护的
[snoworwind/qemu-ohos](https://github.com/snoworwind/qemu-ohos)，使用 `ohos-11.1`
分支上的固定提交 `dc9805c171d93e095bcd7611933fadc8ab847abd`。
该提交基于官方稳定标签 `v11.1.3`，包含参考旧定制版移植的共享库入口、正常关机返回、
OHOS JIT 权限处理、9p mapped-file 兼容修改，以及 OHOS Clang 15 的 i.MX 初始化兼容修复。

## 默认行为

- 开发版在手机、平板、PC 上均使用 JIT，库名仍为 `libqemu-system-aarch64.so`。
- 应用市场分发包按原有包名规则选择 TCI；可选库名为 `libqemu-system-aarch64-tci.so`。
- `qemu_system_entry` / `qemu_img_entry` 接口保持兼容，不修改客户机内核、rootfs 或用户数据。
- 两种宿主 ABI 均模拟 AArch64 客户机：`arm64-v8a` 用于真机，`x86_64` 用于模拟器。

## 固定来源与构建

`deps/libqemu/source.env` 是版本配置的唯一来源。Linux 流水线和旧 Make 入口均读取它，
从固定 Git 对象导出源码，不使用可变的分支 HEAD。源码导出和构建目录包含提交号，
避免旧缓存阻止新组件生效。平台构建参数由组件自身的 `scripts/ohos/build.sh` 维护。

已有源码依赖安装在 `$HISH_WORK/install`（默认 `/root/hish-build/install`）时：

```sh
OHOS_SDK_HOME=/root/ohos-sdk/linux scripts/build-source-linux.sh qemu
TARGET_ARCH=x86_64 OHOS_SDK_HOME=/root/ohos-sdk/linux scripts/build-source-linux.sh qemu
# 可选兼容版本，不覆盖默认 JIT 产物
QEMU_TCI=1 OHOS_SDK_HOME=/root/ohos-sdk/linux scripts/build-source-linux.sh qemu
```

首次准备依赖使用 `all` 代替 `qemu`；依赖源码包沿用现有固定版本流水线。
构建日志位于 `.temp/source-build/logs/qemu-<arch>[-tci]-linux.log`。

构建完成后，在 Windows 项目目录执行：

```powershell
python scripts/install-qemu-libs.py
pwsh -NoProfile -File scripts/record-source-build.ps1
python scripts/verify-source-build.py
```

安装脚本在替换前验证两套 ABI 的 ELF 类型和源码提交号，并将旧库备份到
`.temp/source-build/backups/qemu-<时间>/`。默认 JIT 库不会被 TCI 产物覆盖。
已有的旧版本 TCI 库若没有对应的新构建，会先备份再移出打包目录。
其余依赖文件不受替换影响。

`feature/hish_main/libs/<abi>/` 是打包输入目录，其中二进制按仓库既有规则被 Git 忽略；
复现安装依赖本次提交的来源配置和脚本，不需要把二进制强制加入 Git。
产物 SHA-256 和已安装库清单记录在 `.temp/source-build/manifest.json`。

## 验证范围

组件仓库已完成 ARM64 JIT、x86_64 JIT、ARM64 TCI 的交叉编译、导出接口及动态依赖检查，
JIT 权限切换的 errno 保留回归测试也已通过。本仓库升级后会再次通过正式流水线重建，
并检查已安装库与构建产物一致。

旧文档中的 10.2.0 真机启动记录只适用于旧组件。交叉编译和 HAP 打包成功不能替代真机验证，
下面的记录来自 11.1.3 组件本身。

## 真机验证（2026-11-14）

设备：HUAWEI SGT-AL10（`deviceType=phone`，HarmonyOS API 26）。安装 `phone` 开发版 HAP
（`dev.snoworwind.hish`，hvigor debug 自动签名）后冷启动，结果：

- 日志确认 `Loading QEMU: libqemu-system-aarch64.so (JIT)`，`qemu_system_entry` 解析成功；
  没有 JIT 权限、`mmap`/`mprotect` 或 9p 断言失败。
- guest 约 9 秒进入 Alpine 登录提示，tty1 与 ttyAMA0 均自动 root 登录；
  `uname -a` 返回 `Linux hish 6.12.117 #1 SMP ... aarch64 GNU/Linux`。
- 9p：`hostshare on /mnt/share type 9p (rw,relatime,access=client,trans=virtio)`，
  guest 内创建文件成功，覆盖了 mapped-file 兼容修改的路径。
- 网络：`eth0 10.0.2.15/24`；`ping 10.0.2.2` 与 `ping 223.5.5.5` 均无丢包，
  DNS 经 `10.0.2.3` 正常解析 `dl-cdn.alpinelinux.org`。
- discard：`fstrim -v /` 回报 `134124658688 bytes trimmed`，`discard=unmap`
  从 guest 到 qcow2 的链路有效。
- 运行约 6 分钟内没有 HiSH 相关错误，主进程与 render 进程持续稳定。

截图与启动日志保存在 `.temp/qemu-ohos-artifacts/`（`hish-cold.jpeg`、`hish-cmd*.jpeg`、
`hish-startup-stream.log`）。

仍未验证：VNC/WebSocket 画面、TCI 库的实际加载路径、`tablet` 与 `2in1` 设备、
性能对比和长时间稳定性；安装用的是 debug 签名，不等于发布签名。

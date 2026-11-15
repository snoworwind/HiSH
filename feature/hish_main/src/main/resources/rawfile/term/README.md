# Terminal 渲染引擎说明 (xterm.js)

本文档说明本项目中终端渲染引擎（xterm.js）的版本、Unicode 宽度处理、渲染器选择以及数据通路。

## 1. 版本与组成

终端页 `term.html` 加载以下随包资源（均已 vendored 到 `rawfile/term/`）：

| 文件 | 版本 | 作用 |
| --- | --- | --- |
| `xterm.js` / `xterm.css` | `@xterm/xterm` 6.0.0 | 终端核心（VT 解析、缓冲区、DOM 渲染器） |
| `xterm-addon-fit.js` | `@xterm/addon-fit` 0.11.0 | 按容器尺寸计算行列数 |
| `xterm-addon-webgl.js` | `@xterm/addon-webgl` 0.19.0 | GPU 渲染器（保留但默认不启用，见第 3 节） |
| `xterm-addon-unicode-graphemes.js` | `@xterm/addon-unicode-graphemes` 0.4.0 | Unicode 15 + 字素簇（grapheme）宽度 |

## 2. 中文 / Emoji 宽度

`unicode-graphemes` addon 加载后 `term.unicode.activeVersion` 为 `15-graphemes`：

* 半角字符占 1 格；CJK 等全角字符占 2 格；
* Emoji（含 VS16、keycap、ZWJ 组合）按字素簇计算，整体占 2 格，与 Node 侧 `string-width`（Claude Code、Ink 等 TUI 使用）一致；
* 组合字符（如 `e` + U+0301）占 1 格。

仍有一类差异是终端与应用侧宽度模型的固有差异：`string-width` 把部分符号（例如 `⏺` U+23FA）按 Emoji 计为 2 格，而 wcwidth 标准的终端（xterm、kitty、以及本项目）计为 1 格。这是应用侧假设与终端标准不一致，不是渲染缺陷；因为它更窄，不会造成额外换行，只可能出现字形贴到相邻单元格的观感。

## 3. 渲染器

xterm.js 6 的核心只带 DOM 渲染器；WebGL 由 addon 提供，但本项目的
`ENABLE_WEBGL` 固定为 `false`，**始终使用 DOM 渲染器**：

* 原因：触摸设备的长按取词/复制依赖浏览器对 DOM 文本的原生选择，WebGL 渲染器没有可选择的文本节点（xterm 6 也未实现触摸选择）；部分设备上 WebGL 还出现过镜像/花屏；
* 性能补偿：数据通路已去掉 hex 转义（载荷约降到 1/4），并升级到 Unicode 15 字素宽度；
* 需要重新评估 WebGL 时，把 `term.js` 顶部的 `ENABLE_WEBGL` 改为 `true`：加载失败或上下文丢失会自动回退 DOM，关闭斜体时也会回退 DOM。

## 4. 数据通路（VM → 终端）

串口输出现在按**原始字节**转发：

```
serial socket → serial_output_worker (raw bytes) → NAPI ArrayBuffer
  → ArkTS 合并 16ms → base64 → WebView exports.writeBase64()
  → atob → Uint8Array → term.write()
```

历史实现会在 native 侧把控制字节展开成字面量 `\x1b`（最多 4 倍膨胀），再在 JS 侧用正则还原；该层已移除，载荷从约 5.3 倍降到 1.33 倍（base64），也省掉了每帧一次的大正则。

## 5. 键盘输入与交互

1. 捕获：`xterm.js` 监听键盘事件；
2. 编码：转换为标准 VT/ANSI 转义序列或 UTF-8 字符流；
3. 传输：`term.onData(data)` → `native.sendInput(data)` → 串口写入 VM。

Insert 键发送 `\x1b[2~`；粘贴通过 `exports.paste()` 转 UTF-8 字节发送，Shift+Insert 在 ArkTS 层拦截。

触摸滚动由 `term.js` 自己实现：xterm.js 6 的 scrollable 没有可滚动的 DOM，触摸拖动不会自动滚动，因此拖动时按像素累计换算成 `term.scrollLines()`，松手后按采样速度做指数衰减的惯性滚动；只有“非文本选择”手势才会触发，长按取词仍交给浏览器。

## 6. 尺寸同步

xterm fit 后通过 `term.onResize`（以及启动时一次显式调用）通知 ArkTS，再由 QGA 在 guest 内执行
`stty -F /dev/ttyAMA0 rows/cols`，让全屏程序收到 `SIGWINCH` 重排。详见
`docs/` 与 `QemuAgentManager.applyTerminalSize()`。

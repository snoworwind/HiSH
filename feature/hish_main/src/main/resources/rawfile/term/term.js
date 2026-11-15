// Initialize xterm.js
// The Terminal instance is created lazily in initialize() (see createTerminal),
// because renderer options depend on native preferences (ligatures / italic).
var term = null;

// Tracks the currently selected font family so user fonts can re-apply it
// once their FontFace finishes loading asynchronously.
var currentFontFamily = 'Default';

// 渲染器选择：固定使用 DOM 渲染器。
//
// xterm.js 6 的核心只带 DOM 渲染器，WebGL 是 addon；这里保留 addon 与切换代码，
// 但默认/当前固定关闭，原因：
//   1. 触摸设备的长按取词/复制依赖浏览器对 DOM 文本的原生选择，WebGL 渲染器
//      没有可选择的文本节点（xterm 6 也没有触摸选择实现）；
//   2. 部分设备上 WebGL 出现过镜像/花屏，DOM 渲染最稳。
// 需要重新评估 WebGL 时，把 ENABLE_WEBGL 改为 true 即可（加载失败/上下文丢失
// 会自动回退 DOM；关闭斜体时也会回退 DOM）。
let ENABLE_WEBGL = false;
let webglAddonInstance = null;
// 用户是否允许斜体（DOM 渲染器下由 term.css 的 italics-off 控制；WebGL 下
// 无法用 CSS 关掉斜体，因此关闭斜体时直接退回 DOM 渲染器）。
let italicsEnabled = true;

function enableWebGLRenderer() {
    if (!ENABLE_WEBGL || webglAddonInstance || !term || typeof WebglAddon === 'undefined') {
        return;
    }
    try {
        const addon = new WebglAddon.WebglAddon();
        addon.onContextLoss(() => {
            console.warn('WebGL context lost, falling back to DOM renderer');
            try { addon.dispose(); } catch (e) { /* ignore */ }
            if (webglAddonInstance === addon) {
                webglAddonInstance = null;
            }
        });
        term.loadAddon(addon);
        webglAddonInstance = addon;
        console.log('WebGL renderer loaded');
    } catch (e) {
        console.warn('WebGL renderer failed to load, falling back to DOM', e);
    }
}

function disableWebGLRenderer() {
    if (!webglAddonInstance) {
        return;
    }
    try {
        webglAddonInstance.dispose();
    } catch (e) {
        console.warn('WebGL renderer dispose failed', e);
    }
    webglAddonInstance = null;
}

// Initialize Addons (constructed upfront; attached to term in createTerminal)
const fitAddon = new FitAddon.FitAddon();
// Unicode 15 + 字素簇（grapheme）宽度：让 emoji、ZWJ 组合、VS16 等占用
// 与现代终端（以及 Node 侧 string-width）一致的单元格数。
let unicodeGraphemesAddon = null;
try {
    if (typeof UnicodeGraphemesAddon !== 'undefined') {
        unicodeGraphemesAddon = new UnicodeGraphemesAddon.UnicodeGraphemesAddon();
    }
} catch (e) {
    console.warn('Unicode graphemes addon unavailable', e);
}

// Initialize exports for ArkTS to call
window.exports = {};

// Helper for decoding Latin1/Binary string from ArkTS to UTF-8
const decoder = new TextDecoder('utf-8');
const encoder = new TextEncoder();

function setupImeGuard() {
    if (!term.textarea) {
        return;
    }
    const textarea = term.textarea;
    textarea.setAttribute('autocomplete', 'off');
    textarea.setAttribute('autocorrect', 'off');
    textarea.setAttribute('spellcheck', 'false');
    textarea.setAttribute('autocapitalize', 'off');
}

// Detects which monospace fonts are actually available in the WebView.
// Uses Canvas measureText: compares "CandidateFont, monospace" against
// pure "monospace" baseline. If a font doesn't exist, the browser falls
// back to monospace and the widths match → it gets filtered out.
function detectAvailableMonospaceFonts() {
    var testNarrow = 'iiiiilllll';
    var testWide = 'WWWWWmmmmm';
    var baseFont = 'monospace';

    // Comprehensive list of monospace fonts commonly available across
    // HarmonyOS / Android / Linux systems
    var candidates = [
        'Droid Sans Mono',
        'Noto Sans Mono',
        'Roboto Mono',
        'Source Code Pro',
        'Cascadia Code',
        'Fira Code',
        'JetBrains Mono',
        'Courier New',
        'Courier',
        'Consolas',
        'Menlo',
        'DejaVu Sans Mono',
        'Liberation Mono',
        'Ubuntu Mono',
        'Monaco',
    ];

    var canvas = document.createElement('canvas');
    var ctx = canvas.getContext('2d');
    var testFontSize = '16px';

    function measure(fontStack, text) {
        ctx.font = testFontSize + ' ' + fontStack;
        return ctx.measureText(text).width;
    }

    // Baseline with pure monospace (the browser's default monospace font)
    var monoNarrow = measure(baseFont, testNarrow);
    var monoWide = measure(baseFont, testWide);

    return candidates.filter(function(font) {
        // Measure with candidate + monospace fallback.
        // If the candidate font does NOT exist, the browser falls back
        // to monospace → same metrics as baseline → detected as unavailable.
        // If it DOES exist → different metrics → detected as available.
        var fontStack = '"' + font + '", ' + baseFont;
        var narrow = measure(fontStack, testNarrow);
        var wide = measure(fontStack, testWide);

        // Font is distinct from default monospace (it actually exists and differs)
        var narrowDiff = Math.abs(narrow - monoNarrow);
        var wideDiff = Math.abs(wide - monoWide);
        var isDistinct = narrowDiff > 0.5 || wideDiff > 0.5;

        // Font is monospace: narrow and wide chars have equal width
        // (1px tolerance for sub-pixel rendering differences)
        var monoDiff = Math.abs(narrow - wide);
        var isMonospace = monoDiff <= 1;

        return isDistinct && isMonospace;
    });
}

// Maps user-friendly font family name to CSS font-family stack.
// 'Default' uses the system monospace fallback chain;
// named fonts include a monospace fallback for safety.
function mapFontFamily(family) {
    if (!family || family === 'Default') {
        return 'monospace, "Droid Sans Mono", "Courier New", "Courier", monospace';
    }
    return '"' + family + '", monospace';
}

// Function to convert "binary string" (where charCode < 256) to Uint8Array
// ArkTS sends data as a string where each char is a byte.
function strToUint8Array(str) {
    const buf = new Uint8Array(str.length);
    for (let i = 0; i < str.length; i++) {
        buf[i] = str.charCodeAt(i);
    }
    return buf;
}

// Creates the xterm.js Terminal instance.
// xterm.js 6 ships only the DOM renderer in core; the WebGL renderer is an
// addon (loaded later, with DOM fallback). Ligature and italic suppression are
// still handled purely via CSS classes on <body> — see term.css.
function createTerminal() {
    var ligatures = false;
    var italic = true;
    try {
        if (window.native && native.getLigatures) {
            ligatures = !!native.getLigatures();
        }
        if (window.native && native.getItalic) {
            italic = !!native.getItalic();
        }
    } catch (e) {
        console.warn('Failed to read renderer prefs', e);
    }

    if (!ligatures) {
        document.body.classList.add('ligatures-off');
    }
    if (!italic) {
        document.body.classList.add('italics-off');
    }
    italicsEnabled = italic;

    var options = {
        cursorBlink: true,
        allowProposedApi: true, // Needed for some addons
        allowTransparency: true, // User preference: Transparency supported
        fontFamily: 'monospace, "Droid Sans Mono", "Courier New", "Courier", monospace',
        fontSize: 14, // Default, will be overridden by native.getFontSize()
        theme: {
            background: 'rgba(0, 0, 0, 0)', // Transparent by default to show effects behind
            foreground: '#ffffff',
            cursor: '#ffffff'
        },
        screenReaderMode: false, // Disabled to fix touch scrolling issues (was conflicting with native selection)
        scrollback: 3000, // [Optimization] Limit scrollback to 3000 lines (Ring Buffer) to prevent memory overflow
    };

    term = new Terminal(options);
    term.loadAddon(fitAddon);

    // Unicode 15 + 字素簇宽度（emoji/组合字符）。加载后 xterm 会自动把
    // activeVersion 切到 "15-graphemes"；失败时保持默认 Unicode 6 表。
    if (unicodeGraphemesAddon) {
        try {
            term.loadAddon(unicodeGraphemesAddon);
            console.log('Unicode width provider: ' + term.unicode.activeVersion);
        } catch (e) {
            console.warn('Unicode graphemes addon failed to load', e);
        }
    }

    // Link clicks
    term.options.linkHandler = {
        activate: (e, text) => {
            if (native && native.openLink) native.openLink(text);
        }
    };

    // Setup global term object for debugging if needed
    window.term = term;
}

// Main initialization function
window.onload = function () {
    // Retry mechanism for native object injection
    let retryCount = 0;
    const maxRetries = 10;

    function initialize() {
        // Check if native is ready
        if (!window.native && retryCount < maxRetries) {
            console.log(`Waiting for native object... (${retryCount + 1}/${maxRetries})`);
            retryCount++;
            setTimeout(initialize, 200);
            return;
        }

        // Initial fit with a slight delay to ensure container is ready
        setTimeout(() => {
            // 0. Create terminal and open it
            try {
                createTerminal();
                term.open(document.getElementById('terminal'));
                setupImeGuard();
            } catch (e) {
                console.error("Failed to create terminal", e);
                return;
            }

            // 1. Setup event listeners BEFORE syncing preferences:
            //    syncPrefs() 里的 setFontFamily 会调用 fitAddon.fit()，如果
            //    onResize 还没注册，首次 fit 就不会通知 native，guest 的 tty
            //    尺寸会一直停留在开机时 busybox resize 的值。
            try {
                setupEventListeners();
                syncPrefs();
            } catch (e) {
                console.error("Error during setup", e);
            }

            // 2. Detect available monospace fonts
            //    Preload bundled fonts first to ensure they're detected
            try {
                // Bundled fonts — always available, loaded via fonts.css @font-face
                var bundledFonts = ['JetBrains Mono', 'Fira Code', 'Source Code Pro'];
                var preloadPromises = [];
                if (document.fonts && document.fonts.load) {
                    for (var b = 0; b < bundledFonts.length; b++) {
                        preloadPromises.push(
                            document.fonts.load('14px "' + bundledFonts[b] + '"')
                                .catch(function() { /* ignore individual load failures */ })
                        );
                    }
                }
                // Run detection after preload (with timeout fallback)
                var doDetection = function() {
                    var availableFonts = detectAvailableMonospaceFonts();
                    // Ensure bundled fonts are always present (their woff2 files are baked in)
                    for (var k = 0; k < bundledFonts.length; k++) {
                        if (availableFonts.indexOf(bundledFonts[k]) === -1) {
                            availableFonts.push(bundledFonts[k]);
                        }
                    }
                    console.log('Detected monospace fonts: ' + availableFonts.join(', '));
                    if (native.onAvailableFontsDetected) {
                        native.onAvailableFontsDetected(JSON.stringify(availableFonts));
                    }
                };
                if (preloadPromises.length > 0) {
                    // Wait up to 2s for fonts to load, then run detection
                    Promise.race([
                        Promise.all(preloadPromises),
                        new Promise(function(r) { setTimeout(r, 2000); })
                    ]).then(doDetection);
                } else {
                    doDetection();
                }
            } catch (e) {
                console.warn('Font detection failed', e);
            }

            // 3. Fit Terminal (now onResize listener is ready to capture this)
            try {
                fitAddon.fit();
                console.log(`Terminal size after fit: ${term.cols}x${term.rows}`);

                // If fit failed (size 0), force a default size
                if (term.cols < 2 || term.rows < 2) {
                    term.resize(80, 24);
                    console.log("Forced resize to 80x24");
                }
            } catch (e) {
                console.error("Fit failed", e);
                term.resize(80, 24); // Fallback
            }

            // 3.1 显式同步一次尺寸：如果初始尺寸恰好没变化，term.onResize 不会
            //     触发，这里保证 guest 的 tty 尺寸在启动阶段就与 xterm 对齐。
            if (native && native.resize) {
                native.resize(term.cols, term.rows);
            }

            // 4. Load WebGL renderer (addon; falls back to DOM on failure/loss)
            if (ENABLE_WEBGL && italicsEnabled) {
                enableWebGLRenderer();
            }

            // 5. Initialize and Start Shell
            try {
                // Restore HiSH Startup Logo
                term.writeln(
                    'HiSH is starting...\r\n\r\n' +
                    '     |  | _)   __|  |  |\r\n' +
                    '     __ |  | \\__ \\  __ |\r\n' +
                    '    _| _| _| ____/ _| _|\r\n'
                );

                // Notify native that we are ready
                if (window.native && native.load) {
                    native.load();
                } else {
                    console.error("Native object still missing after retries");
                    term.writeln('\r\nError: Native bridge failed to initialize.\r\n');
                }
            } catch (e) {
                console.error("Error during init/load", e);
            }

        }, 300); // 300ms delay to ensure container is ready
    }

    // Start initialization
    initialize();
};

function syncPrefs() {
    try {
        if (native.getFontSize) {
            const fs = native.getFontSize();
            if (fs) term.options.fontSize = fs;
        }
        if (native.getFontFamily) {
            const ff = native.getFontFamily();
            if (ff) exports.setFontFamily(ff);
        }
        if (native.getCursorBlink) {
            const blink = native.getCursorBlink();
            if (blink) term.options.cursorBlink = blink;
        }
        if (native.getCursorShape) {
            const shape = native.getCursorShape();
            if (shape) exports.setCursorShape(shape); // Use our adapter logic
        }
        if (native.getBackgroundColor) {
            const bg = native.getBackgroundColor();
            if (bg) exports.setBackgroundColor(bg);
        }
        if (native.getBackgroundImage) {
            const img = native.getBackgroundImage();
            if (img) exports.setBackgroundImage(img);
        }
        if (native.getBackgroundBlur) {
            const blur = native.getBackgroundBlur();
            if (blur) exports.setBackgroundBlur(blur);
        }
        if (native.getUserFonts) {
            const fontsJson = native.getUserFonts();
            if (fontsJson) registerUserFonts(fontsJson);
        }
    } catch (e) {
        console.warn("Failed to sync prefs", e);
    }
}

// Registers user-uploaded fonts (JSON array of {name, dataUrl}) via FontFace.
function registerUserFonts(json) {
    try {
        var fonts = JSON.parse(json);
        for (var i = 0; i < fonts.length; i++) {
            exports.addUserFont(fonts[i].name, fonts[i].dataUrl);
        }
    } catch (e) {
        console.warn('registerUserFonts failed', e);
    }
}
exports.registerUserFonts = registerUserFonts;

function setupEventListeners() {
    // 1. Input from User (Keyboard/Mouse) -> Send to VM
    term.onData(data => {
        // Pass data directly to native (matching original hterm behavior)
        if (native && native.sendInput) {
            native.sendInput(data);
        }
    });

    // 2. Resize -> Notify Native
    term.onResize(size => {
        if (native && native.resize) {
            native.resize(size.cols, size.rows);
        }
    });

    // 3. Selection Change -> Notify Native
    term.onSelectionChange(() => {
        const text = term.getSelection();
        if (native && native.onSelectionChange) {
            native.onSelectionChange(text);
        }
    });

    // 4. Handle Window Resize
    window.addEventListener('resize', () => {
        setTimeout(() => fitAddon.fit(), 100);
    });

    // 5. Prevent default browser behaviors that might interfere
    document.addEventListener('keydown', (e) => {
        // Allow some system shortcuts if needed, but generally intercept
        if (e.ctrlKey || e.altKey || (e.keyCode >= 112 && e.keyCode <= 123)) {
            // Let xterm handle it or prevent default
        }
    }, { passive: false });

    // --- Touch gesture arbitration + fling (momentum) scrolling ---
    // xterm.js 6 内部用 scrollable/scrollLines 管理滚动（不是 DOM scrollTop）。
    // 它的 touchmove 处理器负责普通拖动滚动；当拖动从可选中的文字上开始
    // （user-select: text 用于长按复制）时，WebView 可能把手势判给文本选择并
    // 取消 touch 流，导致滑动发涩。
    //
    // 仲裁：
    //   - 滑动超过 slop → preventDefault() 抢下手势，阻止浏览器把它变成选择/平移，
    //     xterm 自己的处理器仍然能收到事件并滚动。
    //   - 手势中途出现选择（长按）→ 把流交还浏览器，保留取词 + 复制。
    //   - 多指（缩放）不处理。
    //
    // Fling：滚动手势期间采样触点，松手后按指数衰减的速度继续滚动（rAF），
    // 通过 term.scrollLines() 驱动（xterm.js 5/6 都可用）。
    var touchStartX = 0;
    var touchStartY = 0;
    var lastTouchY = 0;      // 上一次 touchmove 的 Y，用于拖动滚动
    var scrollCarryPx = 0;   // 拖动时未满一行的像素余量
    var touchHadSelection = false;
    var gestureDecided = false;
    var isScrollGesture = false;
    var TOUCH_SLOP = 8;

    var touchSamples = []; // [{y, t}] recent scroll-gesture positions
    var flingRafId = 0;
    var FLING_SAMPLE_MS = 100;    // velocity estimation window
    var FLING_MIN_VELOCITY = 0.1; // px/ms; slower release counts as a stop
    var FLING_MAX_VELOCITY = 5;   // px/ms safety cap
    var FLING_FRICTION_MS = 350;  // decay time constant (Android-like feel)
    var FLING_MIN_SPEED = 0.01;   // px/ms stop threshold

    function stopFling() {
        if (flingRafId) {
            cancelAnimationFrame(flingRafId);
            flingRafId = 0;
        }
    }

    // xterm.js 6 用内部 scrollable/scrollLines 管理滚动，viewport.scrollTop 不再
    // 有效；惯性滚动统一走 term.scrollLines()。
    function cellHeightPx() {
        if (!term || term.rows <= 0) return 0;
        var screen = document.querySelector('#terminal .xterm-screen');
        if (!screen) return 0;
        var h = screen.getBoundingClientRect().height;
        return h > 0 ? h / term.rows : 0;
    }

    function startFling(velocity) {
        if (!term) return;
        stopFling();
        var v = velocity;              // px/ms，正值 = 手指上滑 = 向下滚动
        var carry = 0;                 // 未满一行的像素余量
        var lastTime = performance.now();
        var step = function (now) {
            var dt = now - lastTime;
            lastTime = now;
            var cellH = cellHeightPx();
            if (cellH <= 0) {
                flingRafId = 0;
                return;
            }
            carry += v * dt;
            var lines = Math.trunc(carry / cellH);
            var before = term.buffer.active.viewportY;
            if (lines !== 0) {
                carry -= lines * cellH;
                term.scrollLines(lines);
            }
            // 滚动位置没变 → 已到顶/底（或没有 scrollback）
            if (lines !== 0 && term.buffer.active.viewportY === before) {
                flingRafId = 0;
                return;
            }
            v *= Math.exp(-dt / FLING_FRICTION_MS);
            if (Math.abs(v) > FLING_MIN_SPEED) {
                flingRafId = requestAnimationFrame(step);
            } else {
                flingRafId = 0;
            }
        };
        flingRafId = requestAnimationFrame(step);
    }

    function nativeSelectionActive() {
        var s = window.getSelection();
        return !!(s && !s.isCollapsed);
    }

    document.addEventListener('touchstart', (e) => {
        stopFling();
        touchSamples = [];
        if (e.touches.length !== 1) {
            gestureDecided = true;
            isScrollGesture = false;
            return;
        }
        touchStartX = e.touches[0].clientX;
        touchStartY = e.touches[0].clientY;
        lastTouchY = touchStartY;
        scrollCarryPx = 0;
        touchHadSelection = nativeSelectionActive();
        gestureDecided = false;
        isScrollGesture = false;
    }, { passive: true });

    document.addEventListener('touchmove', (e) => {
        if (e.touches.length !== 1) return; // Allow pinch zoom if not handled by CSS
        var x = e.touches[0].clientX;
        var y = e.touches[0].clientY;
        if (!gestureDecided) {
            if (Math.abs(x - touchStartX) < TOUCH_SLOP && Math.abs(y - touchStartY) < TOUCH_SLOP) {
                return;
            }
            gestureDecided = true;
            if (!touchHadSelection && nativeSelectionActive()) {
                // A long-press selection engaged during this touch: let the
                // browser keep the stream for selection dragging.
                isScrollGesture = false;
                return;
            }
            isScrollGesture = true;
        }
        if (isScrollGesture) {
            // Claim the gesture before the browser can classify it as a text
            // selection drag.
            e.preventDefault();
            // xterm.js 6 的 scrollable 不再有可滚动的 DOM，触摸拖动需要自己
            // 转成 term.scrollLines()（xterm 5 是浏览器原生滚动 viewport）。
            var cellH = cellHeightPx();
            if (cellH > 0) {
                scrollCarryPx += (lastTouchY - y); // 手指上滑 → 正 → 向下滚
                lastTouchY = y;
                var lines = Math.trunc(scrollCarryPx / cellH);
                if (lines !== 0) {
                    scrollCarryPx -= lines * cellH;
                    term.scrollLines(lines);
                }
            } else {
                lastTouchY = y;
            }
            touchSamples.push({ y: y, t: e.timeStamp });
            while (touchSamples.length > 2 && e.timeStamp - touchSamples[0].t > FLING_SAMPLE_MS) {
                touchSamples.shift();
            }
        }
    }, { passive: false });

    var resetTouchGesture = function () {
        gestureDecided = false;
        isScrollGesture = false;
        touchSamples = [];
    };

    document.addEventListener('touchend', () => {
        // Fling on release, using the velocity of the last ~100ms of dragging.
        // Finger up (y decreases) → (first.y - last.y) > 0 → scroll down.
        if (isScrollGesture && touchSamples.length > 1) {
            var first = touchSamples[0];
            var last = touchSamples[touchSamples.length - 1];
            if (last.t > first.t) {
                var v = (first.y - last.y) / (last.t - first.t);
                v = Math.max(-FLING_MAX_VELOCITY, Math.min(FLING_MAX_VELOCITY, v));
                if (Math.abs(v) > FLING_MIN_VELOCITY) {
                    startFling(v);
                }
            }
        }
        resetTouchGesture();
    }, { passive: true });
    document.addEventListener('touchcancel', resetTouchGesture, { passive: true });

    // --- EVENT SHIELD: Force Native Context Menu (Global Capture) ---
    // This listener runs in the CAPTURE phase on the DOCUMENT.
    // It intercepts the 'contextmenu' event BEFORE it reaches xterm.js.
    // We stop it from propagating to xterm, but allow the default browser behavior (menu).

    document.addEventListener('contextmenu', (e) => {
        // Only intercept if inside the terminal
        if (e.target.closest('#terminal')) {
            e.stopImmediatePropagation(); // Kill it before xterm sees it
            // e.preventDefault(); // DO NOT CALL THIS! We want the menu!
            return true;
        }
    }, true); // true = Capture Phase

    console.log("Global ContextMenu Interceptor activated");
}

// Fix for mouse/touch coordinates when the terminal is visually flipped
function setupMirroredInputFix(termEl) {
    const fixEvent = (e) => {
        if (!termEl.classList.contains('webgl-mobile-fix')) return;

        // If the event was already fixed, skip
        if (e._fixed) return;

        const rect = termEl.getBoundingClientRect();
        let clientY = e.clientY;
        if (e.touches && e.touches.length > 0) {
            clientY = e.touches[0].clientY;
        }

        // Calculate relative Y and flip it
        const relativeY = clientY - rect.top;
        const flippedY = rect.height - relativeY;
        const newClientY = rect.top + flippedY;

        // We can't easily modify clientY of a native event, 
        // but xterm.js uses offsetX/offsetY or calculates from clientX/Y.
        // This is a complex area. A simpler way is to use a proxy element or 
        // just warn the user that touch selection might be inverted.
        console.log("Input coordinates might need inversion due to WebGL fix");
    };

    // termEl.addEventListener('mousedown', fixEvent, true);
    // termEl.addEventListener('touchstart', fixEvent, true);
}

// --- Implementation of exports matching term.js.bak ---

// exports.write(data) - Write data from VM to terminal
exports.write = (data, applicationMode) => {
    // legacy hterm code imply data is Binary String (UTF-8/Latin1 bytes)
    try {
        const uint8 = strToUint8Array(data);
        term.write(uint8);
        if (term.modes.applicationCursorKeysMode !== applicationMode) {
            native.setApplicationMode(term.modes.applicationCursorKeysMode)
        }
    } catch (e) {
        console.error("exports.write failed", e);
    }
};

// 数据从 native 侧以原始字节（base64）送来，直接解码写入即可。
// 旧实现还会把 "\x1b" 这类字面量转义还原成字节，那是 hterm 时代的遗留；
// 现已去掉 native 侧的 hex 转义，这里不再做二次解码（省掉每帧一次大正则）。
exports.writeBase64 = (base64Data, applicationMode) => {
    try {
        const binaryString = atob(base64Data);
        const uint8 = new Uint8Array(binaryString.length);
        for (let i = 0; i < binaryString.length; i++) {
            uint8[i] = binaryString.charCodeAt(i);
        }
        term.write(uint8);

        // Sync Application Cursor Mode using xterm.js state
        if (term.modes.applicationCursorKeysMode !== applicationMode) {
            if (native && native.setApplicationMode) {
                native.setApplicationMode(term.modes.applicationCursorKeysMode);
            }
        }
    } catch (e) {
        console.error("exports.writeBase64 failed", e);
    }
};

exports.paste = (data) => {
    if (native && native.sendInput) {
        // If data is already binary string (UTF-8 bytes as chars), just send it.
        native.sendInput(data);
    }
};

exports.copy = () => {
    // xmm.js selection API
    return term.getSelection();
};

exports.setFontSize = (size) => {
    term.options.fontSize = size;
    fitAddon.fit();
};

exports.setFontFamily = (family) => {
    currentFontFamily = family || 'Default';
    var newFamily = mapFontFamily(family);
    term.options.fontFamily = newFamily;

    // Resize to current dimensions to force xterm.js to
    // re-layout with the new font metrics, then re-fit.
    if (term.cols > 0 && term.rows > 0) {
        term.resize(term.cols, term.rows);
    }
    fitAddon.fit();
};

exports.setCursorShape = (shape) => {
    // hterm: BLOCK, BEAM, UNDERLINE
    // xterm: block, bar, underline
    switch (shape) {
        case 'BEAM': term.options.cursorStyle = 'bar'; break;
        case 'UNDERLINE': term.options.cursorStyle = 'underline'; break;
        default: term.options.cursorStyle = 'block'; break;
    }
};

exports.setCursorBlink = (blink) => {
    term.options.cursorBlink = blink;
};

// Ligature / italic toggles: this build always uses the DOM renderer,
// so both are pure CSS switches applied live without reloading.
exports.setLigatures = (enabled) => {
    document.body.classList.toggle('ligatures-off', !enabled);
};

exports.setItalic = (enabled) => {
    document.body.classList.toggle('italics-off', !enabled);
    italicsEnabled = !!enabled;
    // WebGL 渲染器无法用 CSS 关闭斜体，所以关闭斜体时退回 DOM 渲染器
    if (!italicsEnabled) {
        disableWebGLRenderer();
    } else if (ENABLE_WEBGL) {
        enableWebGLRenderer();
    }
};

// --- Terminal appearance: background color / image / gaussian blur ---

exports.setBackgroundColor = (color) => {
    if (!color) return;
    document.body.style.backgroundColor = color;
};

exports.setBackgroundImage = (dataUrl) => {
    var bg = document.getElementById('terminal-bg');
    if (!bg) return;
    bg.style.backgroundImage = dataUrl ? 'url("' + dataUrl + '")' : 'none';
};

exports.setBackgroundBlur = (px) => {
    var bg = document.getElementById('terminal-bg');
    if (!bg) return;
    var radius = parseInt(px, 10) || 0;
    if (radius > 0) {
        bg.style.filter = 'blur(' + radius + 'px)';
        // Slightly upscale so the blurred edges stay covered
        bg.style.transform = 'scale(' + (1 + radius / 100) + ')';
    } else {
        bg.style.filter = 'none';
        bg.style.transform = 'none';
    }
};

// Registers a user-uploaded font into the document via the FontFace API.
// dataUrl is a base64 data URL of the font file (ttf/otf/woff/woff2).
exports.addUserFont = (name, dataUrl) => {
    if (!name || !dataUrl || typeof FontFace === 'undefined') return;
    try {
        var face = new FontFace(name, 'url("' + dataUrl + '")');
        face.load().then(function (loaded) {
            document.fonts.add(loaded);
            console.log('User font loaded: ' + name);
            // Re-apply in case this font is the currently selected one
            if (currentFontFamily === name) {
                exports.setFontFamily(name);
            }
        }).catch(function (e) {
            console.error('User font load failed: ' + name, e);
        });
    } catch (e) {
        console.error('addUserFont failed: ' + name, e);
    }
};

exports.setFocused = (focus) => {
    if (focus) {
        setupImeGuard();
        term.focus();
    } else {
        term.blur();
    }
};

// Mock hterm.openUrl for compatibility if something calls it directly
window.hterm = {
    openUrl: (url) => {
        if (native && native.openLink) native.openLink(url);
    }
};

exports.selectAll = () => {
    term.selectAll();
};

// Clears the whole terminal buffer (viewport + scrollback)
exports.clearScreen = () => {
    term.clear();
};

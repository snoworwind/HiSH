param([string]$NativeSdk = 'D:/D Program Files/DevEco Studio/sdk/default/openharmony/native', [string]$Only = '')
$ErrorActionPreference = 'Stop'
$root = (Split-Path $PSScriptRoot -Parent).Replace('\','/')
$base = "$root/.temp/source-build"
$env:PYTHONPATH = "$base/python-tools"
$env:PATH = "$NativeSdk/build-tools/cmake/bin;" + $env:PATH
$env:PKG_CONFIG_LIBDIR = "$base/install/lib/pkgconfig;$base/install/share/pkgconfig"
$cross = "$base/ohos-arm64.ini"
$wslBase = (& wsl -d Ubuntu -- wslpath -a $base).Trim()
@"
[binaries]
c = ['$NativeSdk/llvm/bin/clang.exe', '--target=aarch64-linux-ohos', '--sysroot=$NativeSdk/sysroot']
cpp = ['$NativeSdk/llvm/bin/clang++.exe', '--target=aarch64-linux-ohos', '--sysroot=$NativeSdk/sysroot']
ar = '$NativeSdk/llvm/bin/llvm-ar.exe'
strip = '$NativeSdk/llvm/bin/llvm-strip.exe'
pkg-config = ['C:/Windows/System32/wsl.exe', '-d', 'Ubuntu', '--', 'env', 'PKG_CONFIG_LIBDIR=$wslBase/install/lib/pkgconfig:$wslBase/install/share/pkgconfig', 'pkg-config']
[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
[properties]
needs_exe_wrapper = true
[built-in options]
c_args = ['-fPIC', '-Wno-unused-command-line-argument', '-I$base/install/include']
c_link_args = ['-L$base/install/lib', '-fuse-ld=lld']
"@ | Set-Content $cross
foreach ($pkg in @(
 @{ Name='libffi'; Source='libffi'; Options=@() },
 @{ Name='pixman'; Source='pixman-0.42.2'; Options=@('-Dgtk=disabled','-Dlibpng=disabled','-Dtests=disabled','-Dneon=disabled','-Da64-neon=disabled','-Darm-simd=disabled') },
 @{ Name='glib'; Source='glib-2.82.0'; Options=@('-Dselinux=disabled','-Dlibmount=disabled','-Dlibelf=disabled','-Dsysprof=disabled','-Dtests=false','-Dinstalled_tests=false','-Ddocumentation=false','-Dintrospection=disabled','-Dnls=disabled') }
)) {
 if ($Only -and $pkg.Name -ne $Only) { continue }
 $build = "$base/build/$($pkg.Name)"
 $log = "$base/logs/$($pkg.Name).log"
 & python -u -m mesonbuild.mesonmain setup --reconfigure $build "$base/src/$($pkg.Source)" --cross-file $cross --prefix "$base/install" --libdir lib --buildtype release --default-library static --wrap-mode nodownload @($pkg.Options) *> $log
 if ($LASTEXITCODE) { throw "Configure failed: $log" }
 & python -m mesonbuild.mesonmain compile -C $build -j 8 *>> $log
 if ($LASTEXITCODE) { throw "Build failed: $log" }
 & python -m mesonbuild.mesonmain install -C $build *>> $log
 if ($LASTEXITCODE) { throw "Install failed: $log" }
 Write-Output "Built $($pkg.Name) for HarmonyOS arm64-v8a"
}

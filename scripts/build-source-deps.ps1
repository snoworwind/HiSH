param(
  [string]$NativeSdk = 'D:/D Program Files/DevEco Studio/sdk/default/openharmony/native'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$base = Join-Path $root '.temp/source-build'
$cmake = Join-Path $NativeSdk 'build-tools/cmake/bin/cmake.exe'
$ninja = Join-Path $NativeSdk 'build-tools/cmake/bin/ninja.exe'
$toolchain = Join-Path $NativeSdk 'build/cmake/ohos.toolchain.cmake'
$install = Join-Path $base 'install'
foreach ($pkg in @(
  @{ Name='zlib'; Source='zlib-1.3.1'; Options=@('-DBUILD_SHARED_LIBS=ON') },
  @{ Name='zstd'; Source='zstd-1.5.7/build/cmake'; Options=@('-DZSTD_BUILD_STATIC=ON','-DZSTD_BUILD_SHARED=OFF','-DZSTD_BUILD_PROGRAMS=OFF','-DZSTD_BUILD_TESTS=OFF') },
  @{ Name='pcre2'; Source='pcre2-10.45'; Options=@('-DPCRE2_BUILD_PCRE2_32=ON','-DBUILD_SHARED_LIBS=ON','-DBUILD_STATIC_LIBS=ON','-DPCRE2_BUILD_PCRE2GREP=OFF','-DPCRE2_BUILD_TESTS=OFF') }
)) {
  $build = Join-Path $base ('build/' + $pkg.Name)
  $log = Join-Path $base ('logs/' + $pkg.Name + '.log')
  $args = @('-S',(Join-Path $base ('src/' + $pkg.Source)),'-B',$build,'-G','Ninja',
    "-DCMAKE_MAKE_PROGRAM=$ninja","-DCMAKE_TOOLCHAIN_FILE=$toolchain",'-DOHOS_ARCH=arm64-v8a',
    '-DOHOS_PLATFORM=OHOS','-DCMAKE_BUILD_TYPE=Release','-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
    '-DCMAKE_C_FLAGS=-Wno-unused-command-line-argument','-U','HAVE_VISIBILITY',
    "-DCMAKE_INSTALL_PREFIX=$install") + $pkg.Options
  & $cmake @args *> $log
  if ($LASTEXITCODE) { throw "Configure failed: $log" }
  & $cmake --build $build --parallel 8 *>> $log
  if ($LASTEXITCODE) { throw "Build failed: $log" }
  & $cmake --install $build *>> $log
  if ($LASTEXITCODE) { throw "Install failed: $log" }
  Write-Output "Built $($pkg.Name) for HarmonyOS arm64-v8a"
}

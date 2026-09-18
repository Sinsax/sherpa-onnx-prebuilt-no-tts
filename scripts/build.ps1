<#
.SYNOPSIS
  sherpa-onnx-prebuilt-no-tts 全流程构建：配置 → 构建 → 安装 → 对齐 13 项清单 → 组装归档 → 过门禁。

.DESCRIPTION
  产物是 TTS 关闭的 win-x64 静态库归档。归档名与内部结构是消费方
  sherpa-onnx-sys crate 写死的契约，见 README 第 3 节。

  流程中会做三处硬性校验，任一不过就停：
    - 配置后立刻查 CMakeCache，确认 SHERPA_ONNX_ENABLE_TTS=OFF
      （这是本仓存在的唯一理由，不能只靠信任参数拼写）
    - onnxruntime 预置包的 sha256
    - 组装完调 verify-archive.ps1 过发布门禁

.PARAMETER WorkDir
  工作目录，默认 <repo>\build。上游源码、CMake 构建树、安装树都在下面。

.PARAMETER OutDir
  归档输出目录，默认 <repo>\dist。

.PARAMETER SkipBuild
  跳过配置/构建/安装，直接用已有 install\lib 重新组装归档并过门禁。
  调归档结构、反复验门禁时用，省一次编译。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\build.ps1
#>
[CmdletBinding()]
param(
  [string]$WorkDir,
  [string]$OutDir,
  [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$RepoRoot = Get-RepoRoot $PSScriptRoot
if (-not $WorkDir) { $WorkDir = Join-Path $RepoRoot "build" }
if (-not $OutDir)   { $OutDir   = Join-Path $RepoRoot "dist" }

# ---------------------------------------------------------------- 配置来源
$v = Read-VersionsToml (Join-Path $RepoRoot "versions.toml")

$version  = $v["upstream.version"]
$repoUrl  = $v["upstream.repo"]
$commit   = $v["upstream.commit"]
$archive  = $v["archive.name"]
$topDir   = $v["archive.top_dir"]
$expected = Get-ExpectedLibs -RepoRoot $RepoRoot -Versions $v

$ortName = $v["prebuilt_deps.onnxruntime.filename"]
$ortUrl  = $v["prebuilt_deps.onnxruntime.url"]
$ortSha  = $v["prebuilt_deps.onnxruntime.sha256"]

if (-not $version) { throw "versions.toml 里没读到 [upstream] version" }
if (-not $archive) { throw "versions.toml 里没读到 [archive] name" }
if (-not $topDir)  { throw "versions.toml 里没读到 [archive] top_dir" }

if ($topDir -ne ($archive -replace '\.tar\.bz2$', '')) {
  throw "[archive] top_dir 必须等于 name 去掉 .tar.bz2：name=$archive top_dir=$topDir"
}
if ($expected.Count -ne 13) {
  throw "expected_libs.list 应为 13 项（与 crate 的链接清单一致），实际 $($expected.Count) 项"
}

$cmake = Get-CMakeExe
$cm = Read-CMakeArgsFile (Join-Path $RepoRoot "cmake\args.cmake")

Write-Host "== sherpa-onnx v$version  ->  $archive" -ForegroundColor Cyan
Write-Host "   工作目录: $WorkDir"
Write-Host "   输出目录: $OutDir"
Write-Host "   生效的 CMake 参数: $($cm.Args -join ' ')"
Write-Host "   generator: $($cm.Generator) / $($cm.Platform)"

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
New-Item -ItemType Directory -Force -Path $OutDir  | Out-Null

$buildDir = Join-Path $WorkDir "cmake-build"
$srcDir   = Join-Path $WorkDir "upstream-src"
$libDir   = Join-Path $buildDir "install\lib"

if (-not $SkipBuild) {
  # ------------------------------------------------------------ 上游源码
  if (-not (Test-Path (Join-Path $srcDir "CMakeLists.txt"))) {
    Write-Host "== clone 上游 v$version ..." -ForegroundColor Cyan
    git clone --depth 1 --branch "v$version" $repoUrl $srcDir
    if ($LASTEXITCODE -ne 0) { throw "git clone 失败" }
  } else {
    Write-Host "== 复用已 clone 的上游源码: $srcDir"
  }

  $actualCommit = (git -C $srcDir rev-parse HEAD).Trim()
  if ($commit -and ($actualCommit -ne $commit)) {
    throw "上游 commit 不符：versions.toml 记录 $commit，实际 $actualCommit。tag 可能被移动过，先查清再编。"
  }
  Write-Host "   上游 commit: $actualCommit"

  # ------------------------------------------------------------ onnxruntime 预置
  New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
  $ortTarget = Join-Path $buildDir $ortName
  if (-not (Test-Path $ortTarget)) {
    Write-Host "== 下载 onnxruntime $ortName ..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $ortUrl -OutFile $ortTarget
  }
  $ortActual = (Get-FileHash -Algorithm SHA256 -Path $ortTarget).Hash.ToLower()
  if ($ortActual -ne $ortSha) {
    Remove-Item -Force $ortTarget
    throw "onnxruntime 归档 sha256 不匹配：期望 $ortSha，实际 $ortActual（已删除，重跑即可）"
  }
  Write-Host "   onnxruntime sha256 校验通过"

  # ------------------------------------------------------------ 配置 / 构建 / 安装
  # 必须在构建目录里跑 cmake：args.cmake 里的 -DCMAKE_INSTALL_PREFIX=./install
  # 是相对路径，CMake 按「调用时的 cwd」解析（上游工作流同样先 cd build）。
  # 否则安装树会掉到 <WorkDir>\install 而不是 <WorkDir>\cmake-build\install。
  Push-Location $buildDir
  try {
    Write-Host "== 配置 ..." -ForegroundColor Cyan
    & $cmake -S $srcDir -B $buildDir -G $cm.Generator -A $cm.Platform @($cm.Args)
    if ($LASTEXITCODE -ne 0) { throw "cmake 配置失败" }

    $cache = Get-Content (Join-Path $buildDir "CMakeCache.txt") -Encoding UTF8
    if (-not ($cache -match '^SHERPA_ONNX_ENABLE_TTS:BOOL=OFF$')) {
      throw "CMakeCache 显示 SHERPA_ONNX_ENABLE_TTS 不是 OFF —— 停下，否则产物会带上 espeak-ng"
    }
    Write-Host "   已确认 SHERPA_ONNX_ENABLE_TTS=OFF" -ForegroundColor Green

    Write-Host "== 构建 ..." -ForegroundColor Cyan
    & $cmake --build $buildDir --config Release
    if ($LASTEXITCODE -ne 0) { throw "构建失败" }

    Write-Host "== 安装到 <build>\install ..." -ForegroundColor Cyan
    & $cmake --build $buildDir --config Release --target install
    if ($LASTEXITCODE -ne 0) { throw "install 失败" }
  } finally { Pop-Location }
} else {
  Write-Host "== -SkipBuild：跳过编译，直接用已有 $libDir" -ForegroundColor Yellow
}

if (-not (Test-Path $libDir)) { throw "找不到 $libDir" }

# ---------------------------------------------------------------- 对齐 13 项清单
Write-Host "== 对齐链接清单 ..." -ForegroundColor Cyan
$produced = @(Get-ChildItem -Path $libDir -Filter *.lib | ForEach-Object { $_.BaseName })
Write-Host "   构建产出 $($produced.Count) 个 .lib: $($produced -join ', ')"

$missing = @($expected | Where-Object { $produced -notcontains $_ })
if ($missing.Count -gt 0) {
  Write-Host "   缺 $($missing.Count) 项，补空库: $($missing -join ', ')" -ForegroundColor Yellow
  & (Join-Path $PSScriptRoot "make-empty-lib.ps1") -Name ($missing -join ',') -OutDir $libDir
} else {
  Write-Host "   清单已齐，无需补空库"
}

# ---------------------------------------------------------------- 组装归档
Write-Host "== 组装归档 ..." -ForegroundColor Cyan
$stageRoot = Join-Path $OutDir "_stage"
if (Test-Path $stageRoot) { Remove-Item -Recurse -Force $stageRoot }
$stageTop = Join-Path $stageRoot $topDir
$stageLib = Join-Path $stageTop "lib"
New-Item -ItemType Directory -Force -Path $stageLib | Out-Null

# 只放 .lib：清单 13 项 + （若产出）sherpa-onnx-cxx-api.lib，
# 与官方归档的 14 个文件一致。
Get-ChildItem -Path $libDir -Filter *.lib | ForEach-Object { Copy-Item $_.FullName $stageLib }

$archivePath = Join-Path $OutDir $archive
if (Test-Path $archivePath) { Remove-Item -Force $archivePath }

New-TarBz2Archive -TarExe (Get-TarExe) -Bzip2Exe (Get-Bzip2Exe) `
  -StageRoot $stageRoot -EntryName $topDir -OutFile $archivePath

Remove-Item -Recurse -Force $stageRoot
Write-Host "== 归档已生成: $archivePath" -ForegroundColor Green

# ---------------------------------------------------------------- 发布门禁
& (Join-Path $PSScriptRoot "verify-archive.ps1") -Archive $archivePath
if ($LASTEXITCODE -ne 0) { throw "门禁未通过，归档不该发布: $archivePath" }

Write-Host "== 下一步：scripts\publish.ps1 打 tag 并上传" -ForegroundColor Green

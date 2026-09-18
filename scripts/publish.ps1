<#
.SYNOPSIS
  发布：跑门禁 → 写 checksums → 打 tag →（可选）上传 Release 资产。

.DESCRIPTION
  顺序是刻意的：门禁不过就什么都不发。
  归档本身不进 git（109 MB），只走 Release 资产；进 git 的只有 checksums 文本。

.PARAMETER Archive
  归档路径，默认 dist\<versions.toml 里的归档名>。

.PARAMETER Remote
  git remote 名，默认 origin。

.PARAMETER SkipUpload
  只打 tag，不上传 Release 资产（没装 gh 或想手动上传时用）。

.PARAMETER SkipPush
  本地打 tag 但不 push，也不上传。用于先本地检查。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\publish.ps1 -SkipPush
#>
[CmdletBinding()]
param(
  [string]$Archive,
  [string]$Remote = "origin",
  [switch]$SkipUpload,
  [switch]$SkipPush
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$RepoRoot = Get-RepoRoot $PSScriptRoot

# ---------------------------------------------------------------- 读 versions.toml
$v = Read-VersionsToml (Join-Path $RepoRoot "versions.toml")
$version     = $v["upstream.version"]
$commit      = $v["upstream.commit"]
$archiveName = $v["archive.name"]

if (-not $version)     { throw "versions.toml 里没读到 [upstream] version" }
if (-not $archiveName) { throw "versions.toml 里没读到 [archive] name" }

$tag = "v$version"

if (-not $Archive) { $Archive = Join-Path $RepoRoot "dist\$archiveName" }
if (-not (Test-Path $Archive)) { throw "归档不存在: $Archive（先跑 scripts\build.ps1）" }
$Archive = (Resolve-Path -Path $Archive).Path

# ---------------------------------------------------------------- 门禁不过就不发
Write-Host "== 先跑发布门禁 ..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot "verify-archive.ps1") -Archive $Archive
if ($LASTEXITCODE -ne 0) { throw "门禁未通过，终止发布" }

$sha     = (Get-FileHash -Algorithm SHA256 -Path $Archive).Hash.ToLower()
$size    = (Get-Item $Archive).Length
$builtOn = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

# ---------------------------------------------------------------- checksums
$checksumDir = Join-Path $RepoRoot "checksums"
New-Item -ItemType Directory -Force -Path $checksumDir | Out-Null
$checksumPath = Join-Path $checksumDir "$tag.txt"

@"
# sherpa-onnx-prebuilt-no-tts
# 这份库与 k2-fsa / 上游官方发布无隶属关系（unofficial build）。
archive:    $archiveName
sha256:     $sha
size:       $size
upstream:   v$version ($commit)
variant:    TTS disabled, SHERPA_ONNX_ENABLE_TTS=OFF
toolchain:  MSVC, static CRT /MT (SHERPA_ONNX_USE_STATIC_CRT=ON)
build:      static (BUILD_SHARED_LIBS=OFF), Release, win-x64
built_on:   $builtOn
gate:       espeak-ng/piper 特有标记命中 0（裸子串 espeak 会误命中 OfflineSpeaker）
gate:       13 项链接清单全覆盖；文件名与顶层目录名符合 crate 契约
"@ | Set-Content -Path $checksumPath -Encoding UTF8

Write-Host "== checksums 已写入: $checksumPath" -ForegroundColor Green
Get-Content $checksumPath | ForEach-Object { Write-Host "   $_" }

# ---------------------------------------------------------------- git
Push-Location $RepoRoot
try {
  $status = git status --porcelain
  if ($status) {
    Write-Host "== 工作树有改动，提交 checksums ..." -ForegroundColor Cyan
    git add checksums | Out-Null
    git commit -m "record sha256 for $tag"
  } else {
    Write-Host "== 工作树干净，跳过提交"
  }

  if ((git tag -l $tag)) {
    throw "tag $tag 已存在。上游升版本时请改 versions.toml 后再发新 tag，不要复用旧 tag。"
  }
  git tag -a $tag -m "sherpa-onnx v$version, TTS disabled, win-x64 static MT Release"
  Write-Host "== 已打 tag: $tag" -ForegroundColor Green

  if ($SkipPush) {
    Write-Host "== -SkipPush：不 push、不上传。归档与 checksum 都在本地。" -ForegroundColor Yellow
    return
  }

  git push $Remote $tag
  if ($LASTEXITCODE -ne 0) { throw "git push tag 失败" }
  Write-Host "== tag 已推送" -ForegroundColor Green
} finally {
  Pop-Location
}

# ---------------------------------------------------------------- Release 资产
if ($SkipUpload) {
  Write-Host "== -SkipUpload：请手动把归档传到 Release $tag" -ForegroundColor Yellow
  return
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Write-Host "== 没装 gh，跳过自动上传。手动上传这一步：" -ForegroundColor Yellow
  Write-Host "   gh release upload $tag `"$Archive`" `"$checksumPath`""
  return
}

# Release 已存在就直接传资产，否则新建
gh release view $tag 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  gh release create $tag --title "sherpa-onnx v$version (win-x64 static, no TTS)" `
    --notes "TTS-disabled static libs for win-x64, drop-in for the official ``sherpa-onnx-v$version-win-x64-static-MT-Release-lib.tar.bz2`` filename. espeak-ng is NOT linked. sha256 in checksums/$tag.txt."
}

gh release upload $tag $Archive $checksumPath --clobber
if ($LASTEXITCODE -ne 0) { throw "gh release upload 失败" }
Write-Host "== 已上传归档与 checksum 到 Release $tag" -ForegroundColor Green

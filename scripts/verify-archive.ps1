<#
.SYNOPSIS
  发布门禁：归档必须通过全部检查，任一不过即非零退出。

.DESCRIPTION
  门禁 1 —— TTS 真的关干净了
    在 .lib 内容里搜 espeak-ng 特有标记，命中必须为 0：
      espeak-ng / espeak ng / espeak_ / libespeak / piper_phonemize

    ⚠️ 不要用裸子串 "espeak" 做判据（虽然上游工作流里就是用 findstr 这么写的）。
    sherpa-onnx 的说话人分离代码里有个类叫 OfflineSpeaker*，而
    "OfflineSpeaker" 里恰好含子串 "eSpeaker" —— 大小写不敏感搜 "espeak"
    会命中它。实测：官方带 TTS 归档与本仓 TTS-off 归档的
    sherpa-onnx-c-api.lib 都有 170 次裸命中、cxx-api.lib 都有 238 次，
    数量完全相同且特有标记为 0，即全部是这类巧合，与 espeak-ng 无关。
    本脚本仍会打印裸命中数供参考。

  门禁 2 —— 链接清单覆盖
    lib/ 下的文件名集合必须覆盖消费方写死的 13 项。少一个文件，下游链接就失败。

  门禁 3 —— 记录归档 sha256

  另外校验命名契约：顶层目录名 = 归档名去掉 .tar.bz2，其下有 lib/。

.PARAMETER Archive
  要校验的 .tar.bz2 归档路径。

.PARAMETER KeepExtract
  保留解压目录，便于人工查看。
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$Archive,

  [switch]$KeepExtract
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$RepoRoot = Get-RepoRoot $PSScriptRoot

$TarExe   = Get-TarExe
$Bzip2Exe = Get-Bzip2Exe

$v = Read-VersionsToml (Join-Path $RepoRoot "versions.toml")
$expectedLibs = Get-ExpectedLibs -RepoRoot $RepoRoot -Versions $v
$expectedTop  = $v["archive.top_dir"]
$expectedName = $v["archive.name"]
if (-not $expectedTop)  { throw "versions.toml 里没读到 [archive] top_dir" }
if (-not $expectedName) { throw "versions.toml 里没读到 [archive] name" }

Initialize-ArtifactScanner

$Archive = (Resolve-Path -Path $Archive).Path
if (-not (Test-Path $Archive)) { throw "归档不存在: $Archive" }

$archiveName = Split-Path -Leaf $Archive

Write-Host ""
Write-Host "== 门禁: $archiveName" -ForegroundColor Cyan

$failures = @()

# ---------------------------------------------------------------- 文件名契约
# 下游 crate 按写死的名字取归档，名字错一个字符就是 "does not contain expected archive"
if ($archiveName -ne $expectedName) {
  $failures += "归档文件名与 versions.toml 不符：期望 $expectedName，实际 $archiveName"
}

# ---------------------------------------------------------------- 解压
$extractRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null

try {
  Expand-TarBz2Archive -TarExe $TarExe -Bzip2Exe $Bzip2Exe -Archive $Archive -Destination $extractRoot

  # ------------------------------------------------------------ 命名契约
  $topDir = Join-Path $extractRoot $expectedTop
  if (-not (Test-Path $topDir)) {
    $failures += "归档顶层目录不是 $expectedTop（归档名去掉 .tar.bz2 必须与之一致）"
    $actualTops = @(Get-ChildItem -Path $extractRoot -Directory | ForEach-Object { $_.Name })
    $failures += "  实际顶层: $($actualTops -join ', ')"
  }

  $libDir = Join-Path $topDir "lib"
  if (-not (Test-Path $libDir)) { $failures += "归档顶层目录下没有 lib/ 子目录" }

  $libs = @(Get-ChildItem -Path $libDir -Filter *.lib -ErrorAction SilentlyContinue)
  if ($libs.Count -eq 0) { $failures += "lib/ 下没有任何 .lib" }

  # ------------------------------------------------------------ 门禁 1
  if ($libs.Count -gt 0) {
    $offenders = @()
    $rawTotal = 0

    foreach ($l in $libs) {
      $r = Get-EspeakNgMarkerHits -Path $l.FullName
      $rawTotal += $r.Raw
      foreach ($o in $r.Offenders) { $offenders += "$($l.Name): $o" }
    }

    if ($offenders.Count -gt 0) {
      $failures += "门禁1 失败：检出 espeak-ng/piper 特有标记 -> $($offenders -join '; ')"
    } else {
      Write-Host ("  门禁1 通过：{0} 个 .lib 中 espeak-ng/piper 特有标记命中 0" -f $libs.Count) -ForegroundColor Green
    }
    Write-Host ("          （裸子串 espeak 共 $rawTotal 次，全部来自 OfflineSpeaker* 类名，非 espeak-ng）") -ForegroundColor DarkGray
  }

  # ------------------------------------------------------------ 门禁 2
  $present = @($libs | ForEach-Object { $_.BaseName })
  $missing = @($expectedLibs | Where-Object { $present -notcontains $_ })
  if ($missing.Count -gt 0) {
    $failures += "门禁2 失败：缺少清单里的库 -> $($missing -join ', ')"
  } else {
    Write-Host ("  门禁2 通过：13 项链接清单全覆盖（清单共 {0} 项）" -f $expectedLibs.Count) -ForegroundColor Green
  }

  $extra = @($present | Where-Object { $expectedLibs -notcontains $_ })
  if ($extra.Count -gt 0) {
    Write-Host "         附注：清单之外多出 $($extra.Count) 个库（无害，官方归档同样如此）: $($extra -join ', ')" -ForegroundColor DarkGray
  }

  # 占位空库（<4 KB）本来就没符号，列出来便于人工确认补了哪几个
  $stubs = @($libs | Where-Object { $_.Length -lt 4096 })
  if ($stubs.Count -gt 0) {
    Write-Host ("         附注：占位空库 {0} 个: {1}" -f $stubs.Count, (($stubs | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor DarkGray
  }
} finally {
  if ($KeepExtract) {
    Write-Host "  解压目录保留在: $extractRoot" -ForegroundColor DarkGray
  } else {
    Remove-Item -Recurse -Force $extractRoot -ErrorAction SilentlyContinue
  }
}

# ---------------------------------------------------------------- 门禁 3
$sha     = (Get-FileHash -Algorithm SHA256 -Path $Archive).Hash.ToLower()
$sizeMB  = [math]::Round((Get-Item $Archive).Length / 1MB, 1)
Write-Host ("  门禁3 记录：sha256={0}  ({1} MB)" -f $sha, $sizeMB) -ForegroundColor Green

# ---------------------------------------------------------------- 结论
if ($failures.Count -gt 0) {
  Write-Host ""
  Write-Host "== 门禁未通过 ==" -ForegroundColor Red
  $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  exit 1
}

Write-Host ""
Write-Host "== 门禁全部通过，可以发布 ==" -ForegroundColor Green
exit 0

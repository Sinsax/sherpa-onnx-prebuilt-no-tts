<#
.SYNOPSIS
  扫任意产物（exe / dll / .lib / .a），断言里面没有 espeak-ng。

.DESCRIPTION
  这是给**消费方**用的检查。它是防「忘了设 SHERPA_ONNX_ARCHIVE_DIR、静默回退官方
  归档」的唯一保险 —— 那种失败不会有任何报错，只能靠扫产物发现。

  判据是 espeak-ng / piper 的**特有标记**，不是裸子串 "espeak"：
    espeak-ng   espeak ng   espeak_   libespeak   piper_phonemize

  为什么不能用裸子串：sherpa-onnx 的说话人分离代码里有个类叫 OfflineSpeaker*，
  而 "OfflineSpeaker" 恰好含子串 "eSpeaker"。实测官方带 TTS 的归档里，
  c-api / cxx-api 两库的裸命中数是 170 / 238，而 espeak-ng 特有标记是 0 —— 全是
  这个类名的巧合。按裸子串判定会把一份正确的 ASR-only 产物误判为含 GPL 代码。

.EXAMPLE
  # 单个文件
  powershell -File scripts\scan-artifact.ps1 -Path target\release\myapp.exe

  # 整个目录（递归扫 exe/dll/lib/a）
  powershell -File scripts\scan-artifact.ps1 -Path target\release

  # 退出码：0 = 干净；1 = 检出 espeak-ng
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$Path,

  # 附带打印裸 "espeak" 命中数（默认不打印，因为必然非 0 且无意义）
  [switch]$ShowRaw
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

Initialize-ArtifactScanner

if (-not (Test-Path $Path)) { throw "路径不存在: $Path" }

$item = Get-Item $Path
if ($item.PSIsContainer) {
  $files = @(Get-ChildItem -Path $item.FullName -Recurse -File |
             Where-Object { $_.Extension -in @(".exe", ".dll", ".lib", ".a", ".so", ".dylib") })
  if ($files.Count -eq 0) { throw "$Path 下没找到可扫的产物（exe/dll/lib/a/so/dylib）" }
} else {
  $files = @($item)
}

Write-Host ""
Write-Host "== 扫 espeak-ng：$($files.Count) 个文件" -ForegroundColor Cyan

$bad = @()
foreach ($f in $files) {
  $r = Get-EspeakNgMarkerHits -Path $f.FullName
  $suffix = ""
  if ($ShowRaw) { $suffix = "  (裸 espeak: $($r.Raw) 次，其中含 OfflineSpeaker 类名)" }

  if ($r.Offenders.Count -gt 0) {
    Write-Host ("  [检出] {0}: {1}" -f $f.Name, ($r.Offenders -join ', ')) -ForegroundColor Red
    $bad += $f.FullName
  } else {
    Write-Host ("  [干净] {0}{1}" -f $f.Name, $suffix) -ForegroundColor Green
  }
}

Write-Host ""
if ($bad.Count -gt 0) {
  Write-Host "== 失败：$($bad.Count) 个产物含 espeak-ng ==" -ForegroundColor Red
  Write-Host "   检查构建时 SHERPA_ONNX_ARCHIVE_DIR / SHERPA_ONNX_LIB_DIR 是否真的指向了 TTS-off 的库，" -ForegroundColor Red
  Write-Host "   以及依赖里解析到的 sherpa-onnx-sys 版本是否与本仓归档名一致。" -ForegroundColor Red
  exit 1
}

Write-Host "== 通过：全部产物中 espeak-ng 特有标记命中 0 ==" -ForegroundColor Green
exit 0

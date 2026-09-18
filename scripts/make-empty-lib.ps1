<#
.SYNOPSIS
  造一个空 .lib，用于补链接清单里「TTS 关闭后不再产出」的库名。

.DESCRIPTION
  链接清单写死在消费方 sherpa-onnx-sys/build.rs 顶部，逐个
  cargo:rustc-link-lib=static=<name>，不是 whole-archive：
    - 清单里的库文件不存在 → 链接失败
    - 文件存在但没有任何符号被引用 → 链接器不会从中取任何东西

  所以「空库」满足存在性要求，又不会引入任何代码。
  它的失败模式是响亮的链接错误（TTS 若没关干净就会出现未定义符号），
  不是静默污染。

  需要 VS 开发者环境（cl.exe / lib.exe）。请在本脚本内先调 vcvars64.bat，
  或从「x64 Native Tools Command Prompt」运行。

.PARAMETER Name
  要生成的库名（不含 .lib），逗号分隔，例如 "espeak-ng,piper_phonemize"。
  用逗号而非空格，是因为 powershell.exe -File 会把空格分隔的实参
  整个当成一个字符串传进来。

.PARAMETER OutDir
  输出目录，默认当前目录。
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$Name,

  [string]$OutDir = "."
)

$ErrorActionPreference = "Stop"

$libNames = @($Name -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($libNames.Count -eq 0) { throw "-Name 为空" }

if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
  $vcvars = Join-Path ${env:ProgramFiles} "Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
  if (-not (Test-Path $vcvars)) {
    $vcvars = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
  }
  if (-not (Test-Path $vcvars)) {
    throw "找不到 vcvars64.bat，请从 x64 Native Tools Command Prompt 运行本脚本。"
  }
  Write-Host "导入 MSVC 环境: $vcvars"
  cmd /c "`"$vcvars`" >nul 2>&1 && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
  }
}

$OutDir = (New-Item -ItemType Directory -Force -Path $OutDir).FullName
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("empty-lib-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# 一个完全空的翻译单元。MSVC 对空 .c 也能产出合法 .obj。
$emptyC = Join-Path $tmp "empty.c"
Set-Content -Path $emptyC -Value "" -NoNewline -Encoding ascii
$emptyObj = Join-Path $tmp "empty.obj"

& cl.exe /nologo /c "/Fo$emptyObj" $emptyC | Out-Null
if (-not (Test-Path $emptyObj)) { throw "cl.exe 未能产出 empty.obj" }

foreach ($n in $libNames) {
  $lib = Join-Path $OutDir "$n.lib"
  & lib.exe /nologo "/out:$lib" $emptyObj | Out-Null
  if (-not (Test-Path $lib)) { throw "lib.exe 未能产出 $lib" }
  Write-Host ("  空库已生成: {0} ({1} 字节)" -f $lib, (Get-Item $lib).Length)
}

Remove-Item -Recurse -Force $tmp

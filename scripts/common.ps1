<#
  scripts/common.ps1 —— 三个脚本共用的读取/工具函数。

  重要：Windows PowerShell 5.1 的 Get-Content -Raw 默认按系统 ANSI 代码页
  （简体中文机器上是 GBK）解码。用 UTF-8 存的中文注释会被解成乱码，
  而且 GBK 是双字节编码，乱码过程会「吃掉」后面的字符 —— 实测会把
  注释行与下一行合并，导致 versions.toml 的键丢失、段头失配。
  所以这里所有读取都显式带 -Encoding UTF8，不要省。
#>

function Read-VersionsToml {
  <#
    只解析本仓 versions.toml 用到的那点结构：段头 [a.b]、字符串键、整数键、
    以及 expected_libs.list 这个多行数组。不追求完整 TOML 支持。
    返回 hashtable，键形如 "archive.name"、"upstream.version"。
  #>
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path $Path)) { throw "找不到 $Path" }

  $text = Get-Content -Raw -Path $Path -Encoding UTF8
  $cfg = @{}
  $section = ""

  foreach ($line in ($text -split "`r?`n")) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith("#")) { continue }

    if ($t -match '^\[(.+)\]$') { $section = $matches[1]; continue }

    if ($t -match '^([A-Za-z0-9_]+)\s*=\s*"([^"]*)"') {
      $cfg["$section.$($matches[1])"] = $matches[2]
      continue
    }
    if ($t -match '^([A-Za-z0-9_]+)\s*=\s*([0-9]+)$') {
      $cfg["$section.$($matches[1])"] = $matches[2]
    }
  }

  # 多行数组单独整段取，避免逐行状态机
  if ($text -match '(?s)\[expected_libs\]\s*list\s*=\s*\[(.*?)\]') {
    $cfg["expected_libs.list"] = @(
      $matches[1] -split ',' |
        ForEach-Object { $_.Trim().Trim('"') } |
        Where-Object { $_ }
    )
  }

  return $cfg
}

function Get-RepoRoot {
  param([Parameter(Mandatory = $true)][string]$ScriptRoot)
  return (Split-Path -Parent $ScriptRoot)
}

function Get-ExpectedLibs {
  param([Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][hashtable]$Versions)

  $list = @($Versions["expected_libs.list"])
  if ($list.Count -eq 0) { throw "versions.toml 里没读到 [expected_libs] list" }
  return $list
}

function Get-TarExe {
  <#
    必须用 Windows 自带的 bsdtar（System32\tar.exe）。若 PATH 里先进来的是
    Git Bash 的 GNU tar，它会把 "F:\..." 里的冒号当成远程主机语法，
    报 "Cannot connect to F: ... resolve failed"。
  #>
  $sys = Join-Path $env:SystemRoot "System32\tar.exe"
  if (Test-Path $sys) { return $sys }
  return "tar"
}

function Get-Bzip2Exe {
  $b = (Get-Command bzip2.exe -ErrorAction SilentlyContinue).Source
  if ($b) { return $b }
  throw "找不到 bzip2.exe。装 Git for Windows 即可（它带一份在 mingw64\bin 下）。"
}

function New-TarBz2Archive {
  <#
    打 .tar.bz2。分成两步是刻意的：bsdtar 用 -j 时会去拉外部 bzip2 子进程，
    在 Windows 这套环境里那个子进程会挂死（现象是输出 0 字节、永不返回）。
    所以让 tar 只打不压缩的包，再直接调 bzip2.exe。

    在 $StageRoot 里打包 $EntryName 这个条目，产出 $OutFile。
  #>
  param(
    [Parameter(Mandatory = $true)][string]$TarExe,
    [Parameter(Mandatory = $true)][string]$Bzip2Exe,
    [Parameter(Mandatory = $true)][string]$StageRoot,
    [Parameter(Mandatory = $true)][string]$EntryName,
    [Parameter(Mandatory = $true)][string]$OutFile
  )

  $tmpTar = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N") + ".tar")

  Push-Location $StageRoot
  try {
    & $TarExe -cf $tmpTar $EntryName
    if ($LASTEXITCODE -ne 0) { throw "tar 打包失败" }
  } finally { Pop-Location }

  # bzip2 直接读写文件。别用 PowerShell 的 > 重定向接二进制流，PS 5.1 会按文本处理弄坏它。
  & $Bzip2Exe -9 -f -- $tmpTar
  if ($LASTEXITCODE -ne 0) { throw "bzip2 压缩失败" }

  $produced = "$tmpTar.bz2"
  if (-not (Test-Path $produced)) { throw "bzip2 未产出 $produced" }

  Move-Item -Force $produced $OutFile
  Remove-Item -Force $tmpTar -ErrorAction SilentlyContinue
}

function Expand-TarBz2Archive {
  <#
    解 .tar.bz2 到 $Destination。同样避开 bsdtar 的 -j（见上）。
    先把归档复制到临时目录再解，不碰调用方的文件。
  #>
  param(
    [Parameter(Mandatory = $true)][string]$TarExe,
    [Parameter(Mandatory = $true)][string]$Bzip2Exe,
    [Parameter(Mandatory = $true)][string]$Archive,
    [Parameter(Mandatory = $true)][string]$Destination
  )

  $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("extract-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null

  try {
    $copy = Join-Path $tmpDir (Split-Path -Leaf $Archive)
    Copy-Item -Force $Archive $copy

    & $Bzip2Exe -d -f -- $copy
    if ($LASTEXITCODE -ne 0) { throw "bzip2 解压失败: $Archive" }

    $tarFile = $copy -replace '\.bz2$', ''
    if (-not (Test-Path $tarFile)) { throw "bzip2 未产出 $tarFile" }

    & $TarExe -xf $tarFile -C $Destination
    if ($LASTEXITCODE -ne 0) { throw "tar 解包失败: $tarFile" }
  } finally {
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
  }
}

function Get-CMakeExe {
  $cm = (Get-Command cmake.exe -ErrorAction SilentlyContinue).Source
  if ($cm) { return $cm }

  $cands = @(
    (Join-Path ${env:ProgramFiles} "Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"),
    (Join-Path ${env:ProgramFiles} "Microsoft Visual Studio\2022\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"),
    (Join-Path ${env:ProgramFiles} "Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe")
  )
  foreach ($c in $cands) { if (Test-Path $c) { return $c } }

  throw "找不到 cmake。请安装 CMake >= 3.20，或 VS 2022（自带一份）。"
}

function Import-MsvcEnv {
  <#
    在需要 cl.exe / lib.exe 时把 MSVC 环境变量导进来。
    已经能用 cl.exe 就什么都不做。
  #>
  if (Get-Command cl.exe -ErrorAction SilentlyContinue) { return }

  $cands = @(
    (Join-Path ${env:ProgramFiles} "Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"),
    (Join-Path ${env:ProgramFiles} "Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"),
    (Join-Path ${env:ProgramFiles} "Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"),
    (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat")
  )

  $vcvars = $null
  foreach ($c in $cands) { if (Test-Path $c) { $vcvars = $c; break } }
  if (-not $vcvars) {
    throw "找不到 vcvars64.bat。请从 x64 Native Tools Command Prompt 运行，或安装 VS 2022 生成工具。"
  }

  Write-Host "   导入 MSVC 环境: $vcvars"
  cmd /c "`"$vcvars`" >nul 2>&1 && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
  }
}

function Read-CMakeArgsFile {
  <#
    读 cmake\args.cmake，取出 generator / platform / 参数列表。
    同一个文件里读，保证 build.ps1 与 CI 用的是同一份冻结配方。
  #>
  param([Parameter(Mandatory = $true)][string]$Path)

  $generator = $null
  $platform  = $null
  $args = @()
  $inArgs = $false

  foreach ($line in (Get-Content $Path -Encoding UTF8)) {
    $t = $line.Trim()
    if ($t -match 'set\(SHERPA_ONNX_PREBUILT_GENERATOR\s+"(.+)"\)') { $generator = $matches[1]; continue }
    if ($t -match 'set\(SHERPA_ONNX_PREBUILT_PLATFORM\s+"(.+)"\)')  { $platform  = $matches[1]; continue }
    if ($t -match '^set\(SHERPA_ONNX_PREBUILT_CMAKE_ARGS\s*$') { $inArgs = $true; continue }
    if ($inArgs) {
      if ($t -match '^\)') { $inArgs = $false; continue }
      if ($t) { $args += $t }
    }
  }

  if (-not $generator) { throw "$Path 里没读到 SHERPA_ONNX_PREBUILT_GENERATOR" }

  return @{ Generator = $generator; Platform = $platform; Args = $args }
}

# ---------------------------------------------------------------- 产物扫描器
#
# 判据是 espeak-ng / piper 的「特有标记」，不是裸子串 "espeak"。
# 原因：sherpa-onnx 的说话人分离代码里有 OfflineSpeaker* 这个类名，
# "OfflineSpeaker" 恰好含子串 "eSpeaker"，大小写不敏感搜 "espeak" 会命中它。
# 实测：官方带 TTS 归档与本仓 TTS-off 归档的 c-api/cxx-api 裸命中数完全相同
# （170 / 238）且特有标记都是 0，全部是这类巧合。用裸子串会误杀正确产物。
$EspeakNgMarkers = @("espeak-ng", "espeak ng", "espeak_", "libespeak", "piper_phonemize")

function Initialize-ArtifactScanner {
  <#
    内联一段 C# 编译成原生速度的分块扫描器。
    纯 PowerShell 逐字节循环扫 800 MB 的 onnxruntime.lib 太慢。
    用类型存在性做守卫：同一进程里被多次 dot-source 时不会重复 Add-Type。
  #>
  if ("ArtifactScanner" -as [type]) { return }

  Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;

public static class ArtifactScanner
{
    // needle 按大小写不敏感做 ASCII 比较，返回出现次数。
    public static long CountAsciiIgnoreCase(string path, string needle)
    {
        byte[] pat = new byte[needle.Length];
        for (int i = 0; i < needle.Length; i++)
        {
            byte b = (byte)needle[i];
            if (b >= 65 && b <= 90) b = (byte)(b + 32);
            pat[i] = b;
        }

        int n = pat.Length;
        if (n == 0) return 0;

        const int Chunk = 1 << 20;
        byte[] buf = new byte[Chunk + n];
        int carry = 0;
        long count = 0;

        using (FileStream fs = File.OpenRead(path))
        {
            while (true)
            {
                int read = fs.Read(buf, carry, Chunk);
                if (read <= 0) break;

                int len = carry + read;
                int limit = len - n;

                for (int i = 0; i <= limit; i++)
                {
                    bool hit = true;
                    for (int j = 0; j < n; j++)
                    {
                        byte b = buf[i + j];
                        if (b >= 65 && b <= 90) b = (byte)(b + 32);
                        if (b != pat[j]) { hit = false; break; }
                    }
                    if (hit) { count++; i += n - 1; }
                }

                // 末尾 n-1 字节留到下一块，避免漏掉跨块匹配
                carry = n - 1;
                if (carry > len) carry = len;
                Buffer.BlockCopy(buf, len - carry, buf, 0, carry);
            }
        }

        return count;
    }

    // 自检：整个门禁都压在这个函数上，万一它永远返回 0 就成了摆设。
    public static bool SelfTest()
    {
        string tmp = Path.GetTempFileName();
        try
        {
            using (FileStream fs = File.Create(tmp))
            {
                byte[] payload = Encoding.ASCII.GetBytes("xxx eSpeak NG xxx ESpeak_Initialize xxx");
                fs.Write(payload, 0, payload.Length);
            }
            bool a = CountAsciiIgnoreCase(tmp, "espeak ng") == 1;
            bool b = CountAsciiIgnoreCase(tmp, "espeak_") == 1;
            bool c = CountAsciiIgnoreCase(tmp, "no-such-marker") == 0;
            return a && b && c;
        }
        finally { File.Delete(tmp); }
    }
}
"@ -ErrorAction Stop

  if (-not [ArtifactScanner]::SelfTest()) {
    throw "扫描器自检失败 —— 结果不可信，终止。"
  }
}

function Get-EspeakNgMarkerHits {
  <#
    扫一个文件，返回 @{ Raw=裸espeak次数; Markers=@{标记=次数} ; Offenders=@("标记 x次数") }
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string[]]$Markers = $EspeakNgMarkers
  )

  $hits = @{}
  $offenders = @()
  foreach ($m in $Markers) {
    $c = [ArtifactScanner]::CountAsciiIgnoreCase($Path, $m)
    if ($c -gt 0) { $hits[$m] = $c; $offenders += "$m x$c" }
  }

  return @{
    Raw       = [ArtifactScanner]::CountAsciiIgnoreCase($Path, "espeak")
    Markers   = $hits
    Offenders = $offenders
  }
}

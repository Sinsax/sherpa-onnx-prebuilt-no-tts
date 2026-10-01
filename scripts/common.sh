#!/usr/bin/env bash
#
# scripts/common.sh —— linux-x64 目标（bash 套件）共用的读取/工具函数。
#
# 与 PowerShell 套件的关系（两个目标、两套工具链、互不干扰）：
#
#   scripts/*.ps1  -> win-x64   ，契约读 [archive] / [prebuilt_deps.onnxruntime]
#   scripts/*.sh   -> linux-x64 ，契约读 [targets.linux-x64] / [prebuilt_deps.onnxruntime-linux-x64]
#
# 两边的归档名都必须是消费方 sherpa-onnx-sys/build.rs 里 archive_name() 的输出，
# 逐字符一致；差一个字符下游就是 "does not contain expected archive"。
#
# 本文件只定义函数与常量，不执行动作。调用方负责 set -euo pipefail。
# 依赖：bash 4+、python3 3.11+（标准库 tomllib）、grep/tar；造空库还需要 gcc 与 ar。

# shellcheck shell=bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# linux-x64 的契约所在段（versions.toml）
LINUX_TARGET_SECTION="targets.linux-x64"
LINUX_ORT_SECTION="prebuilt_deps.onnxruntime-linux-x64"
EXPECTED_LIBS_SECTION="expected_libs"

# espeak-ng / piper 的「特有标记」。
# ⚠️ 判据不是裸子串 "espeak"：sherpa-onnx 的说话人分离代码里有 OfflineSpeaker*，
# 而 "OfflineSpeaker" 含子串 "eSpeaker"，大小写不敏感搜 espeak 会命中它。
# 理由与实测数据见 README 第 5 节。
ESPEAK_NG_MARKERS=(espeak-ng "espeak ng" espeak_ libespeak piper_phonemize)

# 裸子串 espeak —— 只打印计数供参考，绝不当判据用。
ESPEAK_RAW_MARKER="espeak"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33m   %s\033[0m\n' "$*"; }
ok() { printf '\033[32m   %s\033[0m\n' "$*"; }
note() { printf '\033[90m   %s\033[0m\n' "$*"; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "找不到命令 $c（bash 套件需要 bash 4+/python3 3.11+/tar/bzip2；造空库还需要 gcc 与 ar）"
  done
}

# ---------------------------------------------------------------- versions.toml
#
# 用 python3 标准库 tomllib 解析，不手搓 sed/grep：
# name / top_dir 必须逐字符准确，解析错一个字符下游就取不到归档。

toml_get() { # <dotted.section> <key>  -> 打印值（不存在则什么都不打印）
  python3 - "${REPO_ROOT}/versions.toml" "$1" "$2" <<'PY'
import sys, tomllib
path, section, key = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "rb") as f:
    doc = tomllib.load(f)
node = doc
for part in section.split("."):
    if not isinstance(node, dict) or part not in node:
        node = None
        break
    node = node[part]
if isinstance(node, dict) and key in node:
    value = node[key]
    if isinstance(value, str):
        print(value)
    elif isinstance(value, bool):
        print("true" if value else "false")
    elif isinstance(value, (int, float)):
        print(value)
PY
}

toml_list() { # <dotted.section> <key>  -> 每行一项
  python3 - "${REPO_ROOT}/versions.toml" "$1" "$2" <<'PY'
import sys, tomllib
path, section, key = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "rb") as f:
    doc = tomllib.load(f)
node = doc
for part in section.split("."):
    if not isinstance(node, dict) or part not in node:
        node = None
        break
    node = node[part]
value = node.get(key) if isinstance(node, dict) else None
if isinstance(value, list):
    for item in value:
        print(item)
PY
}

# 读 cmake/args-linux.cmake 的 set(SHERPA_ONNX_PREBUILT_CMAKE_ARGS ...)，
# 每行一个参数。与 build.ps1 读 cmake/args.cmake 对应：配方只有一份。
read_cmake_args_file() { # <path>
  python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"set\(SHERPA_ONNX_PREBUILT_CMAKE_ARGS\s*(.*?)\)", text, re.S)
if not m:
    sys.exit("args 文件里没有 set(SHERPA_ONNX_PREBUILT_CMAKE_ARGS ...): " + sys.argv[1])
for line in m.group(1).splitlines():
    line = line.strip()
    if line and not line.startswith("#"):
        print(line)
PY
}

sha256_of() { # <file>
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum -- "$1")"
  elif command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 -- "$1")"
  else
    die "找不到 sha256sum / shasum"
  fi
  printf '%s' "${out%% *}"
}

file_size() { # <file>
  if stat -c %s -- "$1" >/dev/null 2>&1; then
    stat -c %s -- "$1"
  else
    stat -f %z -- "$1"
  fi
}

# ---------------------------------------------------------------- .tar.bz2
#
# Linux 上 GNU tar 的 -j 直接调 bzip2，没有 Windows bsdtar 那个挂死问题，
# 所以这里一步到位；PowerShell 套件分两步是 Windows 专属的原因。

pack_tarbz2() { # <stage_root> <entry_name> <out_file>
  local stage_root="$1" entry="$2" out="$3"
  rm -f -- "$out"
  ( cd "$stage_root" && tar -cjf "$out" "$entry" )
  [[ -f "$out" ]] || die "tar 未产出 $out"
}

extract_tarbz2() { # <archive> <dest_dir>（目标目录不存在则建）
  mkdir -p "$2"
  tar -xjf "$1" -C "$2"
}

# ---------------------------------------------------------------- 产物扫描器
#
# 判据：espeak-ng / piper 的「特有标记」命中必须为 0。
# LC_ALL=C 做 ASCII 大小写折叠，与 PowerShell 套件里内联 C# 扫描器的语义一致。

count_marker() { # <file> <needle>  -> 出现次数
  local file="$1" needle="$2" tmp st n
  [[ -r "$file" ]] || die "扫描器读不了 $file"
  tmp="$(mktemp)"
  st=0
  LC_ALL=C grep -a -o -i -F -- "$needle" "$file" >"$tmp" 2>/dev/null || st=$?
  # grep：0=有命中 1=无命中 其它=真错误。把错误当 0 会让门禁变成摆设。
  if (( st > 1 )); then
    rm -f "$tmp"
    die "扫描 $file 失败（grep 退出码 $st）—— 结果不可信，门禁终止"
  fi
  n="$(wc -l <"$tmp")"
  rm -f "$tmp"
  printf '%s' "$(( n ))"
}

# 自检：整个门禁都压在这个函数上，万一它永远返回 0 就成了摆设。
scanner_self_test() {
  local tmp hits
  tmp="$(mktemp)"
  printf 'xxx eSpeak NG xxx ESpeak_Initialize xxx piper_phonemize xxx' >"$tmp"
  hits="$(count_marker "$tmp" 'espeak ng')"
  (( hits == 1 )) || { rm -f "$tmp"; die "扫描器自检失败：'espeak ng' 期望 1，实得 $hits"; }
  hits="$(count_marker "$tmp" 'espeak_')"
  (( hits == 1 )) || { rm -f "$tmp"; die "扫描器自检失败：'espeak_' 期望 1，实得 $hits"; }
  hits="$(count_marker "$tmp" 'piper_phonemize')"
  (( hits == 1 )) || { rm -f "$tmp"; die "扫描器自检失败：'piper_phonemize' 期望 1，实得 $hits"; }
  hits="$(count_marker "$tmp" 'no-such-marker')"
  (( hits == 0 )) || { rm -f "$tmp"; die "扫描器自检失败：不存在的标记期望 0，实得 $hits"; }
  rm -f "$tmp"
  ok "扫描器自检通过（大小写折叠 / 逐次计数 / 零命中都对）"
}

# ---------------------------------------------------------------- 契约校验

# 读 linux-x64 的契约到全局变量（只读一次，避免各处重复解析）。
load_linux_contract() {
  LINUX_VERSION="$(toml_get upstream version)"
  LINUX_REPO="$(toml_get upstream repo)"
  LINUX_COMMIT="$(toml_get upstream commit)"
  LINUX_ARCHIVE_NAME="$(toml_get "$LINUX_TARGET_SECTION" name)"
  LINUX_TOP_DIR="$(toml_get "$LINUX_TARGET_SECTION" top_dir)"
  LINUX_BUILDER_IMAGE="$(toml_get "$LINUX_TARGET_SECTION" builder_image)"
  LINUX_BUILDER_DOCKERFILE="$(toml_get "$LINUX_TARGET_SECTION" builder_dockerfile)"
  LINUX_BUILD_TYPE="$(toml_get "$LINUX_TARGET_SECTION" build_type)"
  LINUX_ORT_FILENAME="$(toml_get "$LINUX_ORT_SECTION" filename)"
  LINUX_ORT_URL="$(toml_get "$LINUX_ORT_SECTION" url)"
  LINUX_ORT_SHA256="$(toml_get "$LINUX_ORT_SECTION" sha256)"

  [[ -n "$LINUX_VERSION" ]] || die "versions.toml 里没读到 [upstream] version"
  [[ -n "$LINUX_COMMIT" ]] || die "versions.toml 里没读到 [upstream] commit"
  [[ -n "$LINUX_ARCHIVE_NAME" ]] || die "versions.toml 里没读到 [$LINUX_TARGET_SECTION] name"
  [[ -n "$LINUX_TOP_DIR" ]] || die "versions.toml 里没读到 [$LINUX_TARGET_SECTION] top_dir"
  [[ -n "$LINUX_ORT_FILENAME" ]] || die "versions.toml 里没读到 [$LINUX_ORT_SECTION] filename"
  [[ -n "$LINUX_ORT_SHA256" ]] || die "versions.toml 里没读到 [$LINUX_ORT_SECTION] sha256"

  local expect_top="${LINUX_ARCHIVE_NAME%.tar.bz2}"
  [[ "$LINUX_TOP_DIR" == "$expect_top" ]] ||
    die "[$LINUX_TARGET_SECTION] top_dir 必须等于 name 去掉 .tar.bz2：name=$LINUX_ARCHIVE_NAME top_dir=$LINUX_TOP_DIR"

  # 归档名里嵌的版本号必须与 [upstream] version 一致（crate 用 CARGO_PKG_VERSION 拼名字）
  [[ "$LINUX_ARCHIVE_NAME" == *"v$LINUX_VERSION"* ]] ||
    die "归档名里没有 v$LINUX_VERSION：$LINUX_ARCHIVE_NAME"
}

load_expected_libs() { # 填充 EXPECTED_LIBS 数组
  mapfile -t EXPECTED_LIBS < <(toml_list "$EXPECTED_LIBS_SECTION" list)
  (( ${#EXPECTED_LIBS[@]} > 0 )) || die "versions.toml 里没读到 [$EXPECTED_LIBS_SECTION] list"
}

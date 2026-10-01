#!/usr/bin/env bash
#
# scripts/make-empty-lib.sh —— 造空 .a，补链接清单里「TTS 关闭后不再产出」的库名。
#
#   ./scripts/make-empty-lib.sh espeak-ng,piper_phonemize,ucd <out_dir>
#
# 为什么需要它：链接清单写死在消费方 sherpa-onnx-sys/build.rs 顶部，逐个
# cargo:rustc-link-lib=static=<name>，不是 whole-archive：
#   文件不存在        -> 链接失败
#   存在但无符号引用  -> 链接器不会从中取任何东西
# 所以空库满足存在性要求，又不会引入任何代码。失败模式是响亮的链接错误
# （TTS 若没关干净就会出现未定义符号），不是静默污染。
#
# Linux 上 rustc 的 static=<name> 会去找 lib<name>.a，
# 所以这里的文件名是 lib<name>.a（Windows 套件对应 .lib）。
#
# 与 make-empty-lib.ps1 的差别：不需要 cl.exe/lib.exe，用 gcc + ar。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/common.sh"

usage() {
  cat >&2 <<'EOF'
用法: make-empty-lib.sh <name[,name...]> <out_dir>

  name     库名（不含 lib 前缀与 .a 后缀），逗号分隔，例如 espeak-ng,piper_phonemize,ucd
  out_dir  输出目录（不存在则创建）

为什么用逗号而不是空格：与 make-empty-lib.ps1 的 -Name 一致，便于两边互相搬运。
EOF
  exit 2
}

(( $# == 2 )) || usage
NAMES_ARG="$1"
OUT_DIR="$2"
[[ -n "$NAMES_ARG" ]] || usage

require_cmd gcc ar mktemp

IFS=',' read -r -a lib_names <<<"$NAMES_ARG"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 一个完全空的翻译单元。GCC 对空 .c 也能产出合法的 .o（无任何符号）。
: >"$tmp/empty.c"
gcc -c -o "$tmp/empty.o" "$tmp/empty.c"

mkdir -p "$OUT_DIR"

created=0
for n in "${lib_names[@]}"; do
  n="${n// /}"
  [[ -n "$n" ]] || continue
  lib="$OUT_DIR/lib$n.a"
  rm -f -- "$lib"
  # rcs = 替换 + 建索引（s）。空库只有索引，没有成员符号。
  ar rcs "$lib" "$tmp/empty.o"
  [[ -f "$lib" ]] || die "ar 未能产出 $lib"
  printf '  空库已生成: %s (%s 字节)\n' "$lib" "$(file_size "$lib")"
  created=$((created + 1))
done

(( created > 0 )) || die "没有解析出任何库名: '$NAMES_ARG'"

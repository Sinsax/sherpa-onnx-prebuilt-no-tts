#!/usr/bin/env bash
#
# scripts/link-smoke-linux.sh —— linux-x64 归档的**端到端链接冒烟测试**。
#
#   ./scripts/link-smoke-linux.sh                      # 测 dist/ 里的归档
#   ./scripts/link-smoke-linux.sh --lib-dir <dir>      # 测解压后的 lib 目录
#
# 门禁（verify-archive.sh）只能证明「归档里没有 espeak-ng、13 项清单齐全」，
# 证明不了「这份库真的能链接进一个程序」。本脚本补上这一步：
#
#   1. 用消费方 sherpa-onnx-sys/build.rs 里**同样的顺序**把 13 个静态库
#      -l 一遍（静态链接对顺序敏感，顺序错了就会报未定义符号），
#      外加 build.rs 在 linux 上加的 -lstdc++ -lm -pthread -ldl；
#   2. 链接一个只调用 SherpaOnnxGetVersionStr() 的 C 程序 —— 这个符号只在
#      libsherpa-onnx-c-api.a 里，能链上就说明 c-api → core → 各依赖这条链是通的；
#   3. 扫链接出来的二进制，espeak-ng/piper 特有标记必须为 0；
#   4. 跑起来，必须有版本字符串输出（证明链进来的是能执行的真实代码，
#      不是「链接通过但一跑就崩」的空壳）。
#
# 为什么这才是对消费方有意义的验证：下游拿到的是 .a，唯一的用法就是链接。
#
# 注意：这里用的是**宿主机**工具链（本机 Arch 的 gcc/ld）。容器里编出来的 .a
# 带着 glibc 2.35 的符号引用，宿主机更新的 glibc 能提供，所以链接成立；
# 反过来（在旧机器上链新基线产物）才是不成立的 —— 这正是归档必须在
# 固定基线容器里编、而不是在滚更发行版上直编的原因。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/common.sh"

usage() {
  cat >&2 <<'EOF'
用法: link-smoke-linux.sh [选项]

  --archive PATH   要测的 .tar.bz2 归档，默认 dist/<versions.toml 里的 linux 归档名>
  --lib-dir DIR    直接测解压后的 lib 目录（与 --archive 二选一）
  -h, --help       显示本帮助
EOF
  exit 2
}

Archive=""
LibDir=""
while (( $# > 0 )); do
  case "$1" in
    --archive) Archive="$2"; shift 2 ;;
    --lib-dir) LibDir="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "未知参数: $1（-h 看用法）" ;;
  esac
done

require_cmd gcc grep python3 mktemp
load_linux_contract
load_expected_libs
scanner_self_test

[[ -n "$LibDir" ]] || [[ -n "$Archive" ]] || Archive="$REPO_ROOT/dist/$LINUX_ARCHIVE_NAME"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [[ -z "$LibDir" ]]; then
  [[ -f "$Archive" ]] || die "归档不存在: $Archive（先跑 scripts/build-linux.sh）"
  info "解压归档 $Archive ..."
  extract_tarbz2 "$Archive" "$tmp/extract"
  LibDir="$tmp/extract/$LINUX_TOP_DIR/lib"
fi
[[ -d "$LibDir" ]] || die "找不到 lib 目录: $LibDir"

# 先确认 13 项都在：缺了必然链接失败，先给出清晰的报错而不是满屏 undefined reference
for name in "${EXPECTED_LIBS[@]}"; do
  [[ -f "$LibDir/lib$name.a" ]] || die "少了 lib$name.a —— 归档不完整，先过 verify-archive.sh"
done

info "编译并链接冒烟程序 ...（#include 都不用，直接声明那一个 C API）"
cat >"$tmp/smoke.c" <<'EOF'
#include <stdio.h>

/* sherpa-onnx 的 C API（真实声明见 c-api.h；这里只用一个不依赖任何模型的函数） */
extern const char *SherpaOnnxGetVersionStr(void);

int main(void) {
  const char *v = SherpaOnnxGetVersionStr();
  if (v == NULL) {
    fprintf(stderr, "SherpaOnnxGetVersionStr() returned NULL\n");
    return 2;
  }
  printf("%s\n", v);
  return 0;
}
EOF

# 与消费方 build.rs 的 emit_static_link_directives("linux") 逐项对齐：
# 先按 SHERPA_ONNX_STATIC_LIBS 的顺序逐个 static，再是 linux 上的系统库。
link_args=()
for name in "${EXPECTED_LIBS[@]}"; do
  link_args+=("-l$name")
done
link_args+=(-lstdc++ -lm -pthread -ldl)

gcc "$tmp/smoke.c" -o "$tmp/smoke" -L"$LibDir" "${link_args[@]}"
ok "链接通过（13 个静态库 + stdc++/m/pthread/dl）"

# 链接出来的二进制里不能有 espeak-ng / piper 的特有标记
offenders=()
for m in "${ESPEAK_NG_MARKERS[@]}"; do
  c="$(count_marker "$tmp/smoke" "$m")"
  (( c == 0 )) || offenders+=("$m x$c")
done
if (( ${#offenders[@]} > 0 )); then
  die "链接产物里检出 espeak-ng/piper 特有标记：${offenders[*]}（TTS 没关干净）"
fi
raw="$(count_marker "$tmp/smoke" "$ESPEAK_RAW_MARKER")"
ok "二进制 espeak-ng/piper 特有标记 0（裸子串 espeak $raw 次，来自 OfflineSpeaker*）"

info "运行冒烟程序 ..."
version_out="$("$tmp/smoke")"
printf '   输出: %s\n' "$version_out"
[[ -n "$version_out" ]] || die "冒烟程序没有输出"
[[ "$version_out" == "$LINUX_VERSION" ]] ||
  die "版本字符串不符：期望 $LINUX_VERSION，实际 $version_out（归档里的库与 versions.toml 对不上？）"

printf '\n\033[32m== 冒烟测试通过：归档能链接、能运行、且不含 espeak-ng ==\033[0m\n'

#!/usr/bin/env bash
#
# scripts/verify-archive.sh —— linux-x64 的发布门禁，任一不过即非零退出。
#
#   ./scripts/verify-archive.sh dist/sherpa-onnx-v1.13.3-linux-x64-static-lib.tar.bz2
#
# 与 verify-archive.ps1 一一对应（win-x64 那套），判据、顺序、退出码语义都相同：
#
#   门禁 1 —— TTS 真的关干净了
#     在归档内所有 .a 的内容里搜 espeak-ng / piper 的「特有标记」，命中必须为 0。
#     ⚠️ 不要用裸子串 "espeak" 做判据（上游工作流里 findstr 就是这么写的）：
#     sherpa-onnx 的说话人分离代码里有 OfflineSpeaker*，"OfflineSpeaker" 含子串
#     "eSpeaker"，大小写不敏感搜 espeak 会命中它。实测官方带 TTS 归档与本仓
#     TTS-off 归档的 c-api/cxx-api 裸命中数完全相同（170 / 238）且特有标记为 0。
#     本脚本仍打印裸命中数供参考。
#
#   门禁 2 —— 链接清单覆盖
#     lib/ 下的文件名集合必须覆盖消费方写死的 13 项，且占位空库必须真的是空库
#     （真 espeak-ng.a 有 800+ KB；这里超过 4 KB 就说明发出去的是 GPL 二进制）。
#
#   门禁 3 —— 记录归档 sha256 与体积
#
#   另：命名契约（归档名 / 顶层目录名 / lib 子目录）与扫描器自检。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/common.sh"

# TTS 关闭后不再产出的三个库，必须由空库占位。
# 真库远超这个阈值（官方 espeak-ng.lib 是 823,674 字节），
# 所以「大于阈值」= 归档里混进了真 GPL 库。
STUB_MAX_BYTES=4096
STUB_LIBS=(espeak-ng piper_phonemize ucd)

usage() {
  cat >&2 <<'EOF'
用法: verify-archive.sh <archive.tar.bz2> [--keep-extract]

  archive        要校验的归档（默认名字必须与 versions.toml 的 [targets.linux-x64] name 一致）
  --keep-extract 保留解压目录，便于人工查看
EOF
  exit 2
}

ARCHIVE=""
KEEP_EXTRACT=0
while (( $# > 0 )); do
  case "$1" in
    --keep-extract) KEEP_EXTRACT=1; shift ;;
    -h|--help) usage ;;
    -*) die "未知参数: $1" ;;
    *) ARCHIVE="$1"; shift ;;
  esac
done
[[ -n "$ARCHIVE" ]] || usage

require_cmd tar bzip2 grep sha256sum mktemp
load_linux_contract
load_expected_libs
scanner_self_test

[[ -f "$ARCHIVE" ]] || die "归档不存在: $ARCHIVE"
# 用绝对路径：后面要 cd 到别处
ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"
ARCHIVE_BASENAME="$(basename "$ARCHIVE")"

printf '\n'
info "门禁: $ARCHIVE_BASENAME"

failures=()

# ---------------------------------------------------------------- 文件名契约
# 下游 crate 按写死的名字取归档，错一个字符就是 "does not contain expected archive"
if [[ "$ARCHIVE_BASENAME" != "$LINUX_ARCHIVE_NAME" ]]; then
  failures+=("归档文件名与 versions.toml 不符：期望 $LINUX_ARCHIVE_NAME，实际 $ARCHIVE_BASENAME")
fi

extract_root="$(mktemp -d)"
cleanup() {
  if (( KEEP_EXTRACT )); then
    note "解压目录保留在: $extract_root"
  else
    rm -rf "$extract_root"
  fi
}
trap cleanup EXIT

extract_tarbz2 "$ARCHIVE" "$extract_root"

# ---------------------------------------------------------------- 命名契约
top_dir="$extract_root/$LINUX_TOP_DIR"
if [[ ! -d "$top_dir" ]]; then
  failures+=("归档顶层目录不是 $LINUX_TOP_DIR（归档名去掉 .tar.bz2 必须与之一致）")
  actual_tops="$(find "$extract_root" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null || true)"
  failures+=("  实际顶层: $actual_tops")
fi

lib_dir="$top_dir/lib"
[[ -d "$lib_dir" ]] || failures+=("归档顶层目录下没有 lib/ 子目录")

libs=()
if [[ -d "$lib_dir" ]]; then
  shopt -s nullglob
  libs=("$lib_dir"/lib*.a)
  shopt -u nullglob
fi
(( ${#libs[@]} > 0 )) || failures+=("lib/ 下没有任何 .a")

# ---------------------------------------------------------------- 门禁 1
if (( ${#libs[@]} > 0 )); then
  offenders=()
  raw_total=0
  printf '   %-34s %8s %8s\n' "库" "裸espeak" "特有标记"
  for lib in "${libs[@]}"; do
    raw="$(count_marker "$lib" "$ESPEAK_RAW_MARKER")"
    raw_total=$((raw_total + raw))
    marker_sum=0
    for m in "${ESPEAK_NG_MARKERS[@]}"; do
      c="$(count_marker "$lib" "$m")"
      if (( c > 0 )); then
        offenders+=("$(basename "$lib"): $m x$c")
        marker_sum=$((marker_sum + c))
      fi
    done
    printf '   %-34s %8s %8s\n' "$(basename "$lib")" "$raw" "$marker_sum"
  done

  if (( ${#offenders[@]} > 0 )); then
    failures+=("门禁1 失败：检出 espeak-ng/piper 特有标记 -> ${offenders[*]}")
  else
    ok "门禁1 通过：${#libs[@]} 个 .a 中 espeak-ng/piper 特有标记命中 0"
  fi
  note "裸子串 espeak 共 $raw_total 次，全部来自 OfflineSpeaker* 类名，非 espeak-ng"
fi

# ---------------------------------------------------------------- 门禁 2
if [[ -d "$lib_dir" ]]; then
  missing=()
  for name in "${EXPECTED_LIBS[@]}"; do
    [[ -f "$lib_dir/lib$name.a" ]] || missing+=("$name")
  done
  if (( ${#missing[@]} > 0 )); then
    failures+=("门禁2 失败：缺少清单里的库 -> ${missing[*]}")
  else
    ok "门禁2 通过：${#EXPECTED_LIBS[@]} 项链接清单全覆盖"
  fi

  # 占位空库必须真的是空库
  for name in "${STUB_LIBS[@]}"; do
    stub="$lib_dir/lib$name.a"
    [[ -f "$stub" ]] || continue
    size="$(file_size "$stub")"
    if (( size > STUB_MAX_BYTES )); then
      failures+=("门禁2 失败：$(basename "$stub") 有 $size 字节，超过占位上限 $STUB_MAX_BYTES —— 这是真库，不是空库")
    fi
  done

  # 清单之外多出来的库：无害（官方归档同样如此，例如 cxx-api / cargs），列出来
  extras=()
  for lib in "${libs[@]}"; do
    base="$(basename "$lib")"
    name="${base#lib}"
    name="${name%.a}"
    found=0
    for e in "${EXPECTED_LIBS[@]}"; do
      [[ "$e" == "$name" ]] && { found=1; break; }
    done
    (( found )) || extras+=("$name")
  done
  if (( ${#extras[@]} > 0 )); then
    note "清单之外多出 ${#extras[@]} 个库（无害）: ${extras[*]}"
  fi
fi

# ---------------------------------------------------------------- 门禁 3
sha="$(sha256_of "$ARCHIVE")"
size="$(file_size "$ARCHIVE")"
size_mb="$(awk -v s="$size" 'BEGIN { printf "%.1f", s / 1048576 }')"
ok "门禁3 记录：sha256=$sha  ($size 字节 / $size_mb MiB)"

# ---------------------------------------------------------------- 结论
if (( ${#failures[@]} > 0 )); then
  printf '\n\033[31m== 门禁未通过 ==\033[0m\n'
  for f in "${failures[@]}"; do printf '  - %s\n' "$f" >&2; done
  exit 1
fi

printf '\n\033[32m== 门禁全部通过，可以发布 ==\033[0m\n'

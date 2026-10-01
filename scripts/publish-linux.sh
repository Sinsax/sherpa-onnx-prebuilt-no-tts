#!/usr/bin/env bash
#
# scripts/publish-linux.sh —— 发布 linux-x64 归档：门禁 → 写 checksums → 提交 → 上传 Release 资产。
#
# 与 publish.ps1（win-x64）的差别：
#   * win-x64 发布时要打 tag；linux-x64 是**给同一个 tag 补资产**（v1.13.3 的 Release
#     已经存在，里面是 win-x64 归档），所以这里不打新 tag、不动旧资产。
#   * 上传走 GitHub REST API（curl），因为很多 Linux 构建机上没有 gh。
#     认证读 GITHUB_TOKEN 或 GH_TOKEN 环境变量。
#
# 顺序是刻意的：门禁不过就什么都不发。
#
# 用法:
#   ./scripts/publish-linux.sh                  # 门禁 + 写 checksum + 提交 + 上传
#   ./scripts/publish-linux.sh --skip-upload    # 只到「写 checksum + 提交」
#   ./scripts/publish-linux.sh --update-notes   # 顺带把 Release 说明改成覆盖两个目标

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/common.sh"

usage() {
  cat >&2 <<'EOF'
用法: publish-linux.sh [选项]

  --archive PATH    要发布的归档，默认 dist/<versions.toml 里的 linux 归档名>
  --skip-upload     只写 checksum 并提交，不上传 Release 资产
  --update-notes    同时刷新 Release 说明（覆盖两个目标的说明文本）
  -h, --help        显示本帮助

环境变量:
  GITHUB_TOKEN / GH_TOKEN   上传资产所需的 token（repo 权限）
EOF
  exit 2
}

Archive=""
SkipUpload=0
UpdateNotes=0
while (( $# > 0 )); do
  case "$1" in
    --archive) Archive="$2"; shift 2 ;;
    --skip-upload) SkipUpload=1; shift ;;
    --update-notes) UpdateNotes=1; shift ;;
    -h|--help) usage ;;
    *) die "未知参数: $1（-h 看用法）" ;;
  esac
done

require_cmd git python3 curl sha256sum
load_linux_contract

[[ -n "$Archive" ]] || Archive="$REPO_ROOT/dist/$LINUX_ARCHIVE_NAME"
[[ -f "$Archive" ]] || die "归档不存在: $Archive（先跑 scripts/build-linux.sh）"
Archive="$(cd "$(dirname "$Archive")" && pwd)/$(basename "$Archive")"

Tag="v$LINUX_VERSION"

# ---------------------------------------------------------------- 门禁不过就不发
info "先跑发布门禁 ..."
"$HERE/verify-archive.sh" "$Archive" || die "门禁未通过，终止发布"

sha="$(sha256_of "$Archive")"
size="$(file_size "$Archive")"
# built_on 取归档本身的 mtime（= 真正打包的时间），不是「写 checksum 的时间」：
# 用后者的话，每次重跑 publish 都会因为时间戳变化产生一个内容无意义的新提交。
built_on="$(date -u -r "$Archive" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

# 工具链信息由 build-linux.sh 在配置阶段记到构建树里；没有就写 unknown
toolchain="unknown"
toolchain_file="$REPO_ROOT/build/cmake-build/toolchain.txt"
if [[ -f "$toolchain_file" ]]; then
  # toolchain.txt 是「一行一项」，压成一行便于写进 checksum；tr 只做一对一映射，
  # 所以分隔符用 ';' 再补空格，别指望 tr '\n' '; ' 能塞两个字符
  toolchain="$(tr '\n' ';' <"$toolchain_file" | sed -E 's/;+$//; s/;/; /g')"
fi

builder="$LINUX_BUILDER_IMAGE"
[[ -n "$builder" ]] || builder="native（宿主工具链，非发布口径）"

# ---------------------------------------------------------------- checksums
checksum_dir="$REPO_ROOT/checksums"
mkdir -p "$checksum_dir"
checksum_path="$checksum_dir/$Tag-linux-x64.txt"

cat >"$checksum_path" <<EOF
# sherpa-onnx-prebuilt-no-tts
# 这份库与 k2-fsa / 上游官方发布无隶属关系（unofficial build）。
archive:    $LINUX_ARCHIVE_NAME
sha256:     $sha
size:       $size
upstream:   $Tag ($LINUX_COMMIT)
variant:    TTS disabled, SHERPA_ONNX_ENABLE_TTS=OFF
toolchain:  $toolchain
build:      static (BUILD_SHARED_LIBS=OFF), $LINUX_BUILD_TYPE, linux-x64
builder:    $builder
built_on:   $built_on
gate:       espeak-ng/piper 特有标记命中 0（裸子串 espeak 会误命中 OfflineSpeaker）
gate:       13 项链接清单全覆盖；占位空库 <4 KB；文件名与顶层目录名符合 crate 契约
EOF

ok "checksums 已写入: $checksum_path"
note "sha256=$sha"
note "size=$size"

# ---------------------------------------------------------------- git（只提交 checksum，归档不进 git）
info "提交 checksum ..."
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain -- checksums)" ]]; then
  author_name="$(git -C "$REPO_ROOT" config user.name || true)"
  author_email="$(git -C "$REPO_ROOT" config user.email || true)"
  if [[ -z "$author_name" || -z "$author_email" ]]; then
    # 本机没配身份时，沿用本仓最近一次提交的作者，避免 commit 直接失败。
    # 分两次取值：用 %x00 之类分隔符做一次取值会被命令替换吃掉 NUL 字节。
    author_name="$(git -C "$REPO_ROOT" log -1 --format='%an' 2>/dev/null || true)"
    author_email="$(git -C "$REPO_ROOT" log -1 --format='%ae' 2>/dev/null || true)"
  fi
  git -C "$REPO_ROOT" add checksums
  git -C "$REPO_ROOT" -c user.name="$author_name" -c user.email="$author_email" \
    commit -m "record linux-x64 sha256 for $Tag"
  ok "已提交 checksums/$Tag-linux-x64.txt"
else
  note "checksums 没有变化，跳过提交"
fi

if (( SkipUpload )); then
  warn "--skip-upload：不上传。请手动把归档与 checksum 传到 Release $Tag"
  exit 0
fi

# ---------------------------------------------------------------- Release 上传
token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [[ -z "$token" ]]; then
  die "没有 GITHUB_TOKEN / GH_TOKEN，无法上传。
   手动上传这一步：
     gh release upload $Tag \"$Archive\" \"$checksum_path\" --clobber
   或者设好 token 后重跑本脚本。"
fi

remote_url="$(git -C "$REPO_ROOT" remote get-url origin)"
slug="${remote_url#https://github.com/}"
slug="${slug%.git}"
[[ "$slug" == */* ]] || die "从 origin 解析不出 owner/repo: $remote_url"
api="https://api.github.com/repos/$slug"

gh_api() { # <method> <url> [curl 额外参数...]
  local method="$1" url="$2"; shift 2
  curl -fsS -X "$method" \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@" "$url"
}

info "查询 Release $Tag ..."
release_json="$(gh_api GET "$api/releases/tags/$Tag" || true)"
if [[ -z "$release_json" ]]; then
  info "Release $Tag 不存在，创建 ..."
  release_json="$(gh_api POST "$api/releases" \
    -H 'Content-Type: application/json' \
    -d "{\"tag_name\":\"$Tag\",\"name\":\"sherpa-onnx $Tag (TTS disabled, prebuilt)\"}")"
fi

upload_url="$(printf '%s' "$release_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["upload_url"].split("{")[0])')"
release_id="$(printf '%s' "$release_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
[[ -n "$upload_url" ]] || die "Release $Tag 里没读到 upload_url"

upload_asset() { # <file>
  local file="$1" name existing_id
  name="$(basename "$file")"
  # 同名资产先删：API 不允许重名，--clobber 的等价物就是「删了再传」
  existing_id="$(printf '%s' "$release_json" | python3 -c '
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)
for a in data.get("assets", []):
    if a.get("name") == name:
        print(a["id"]); break
' "$name")"
  if [[ -n "$existing_id" ]]; then
    gh_api DELETE "$api/releases/assets/$existing_id" >/dev/null
    note "已删除同名旧资产: $name"
  fi
  curl -fsS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@$file" \
    "$upload_url?name=$name" >/dev/null
  ok "已上传: $name"
}

info "上传归档与 checksum 到 Release $Tag ..."
upload_asset "$Archive"
upload_asset "$checksum_path"

if (( UpdateNotes )); then
  info "刷新 Release 说明 ..."
  notes="TTS-disabled (SHERPA_ONNX_ENABLE_TTS=OFF) static libs, unofficial builds of sherpa-onnx $Tag.

- win-x64:   \`sherpa-onnx-v$LINUX_VERSION-win-x64-static-MT-Release-lib.tar.bz2\` — MSVC /MT, drop-in for the official filename.
- linux-x64: \`sherpa-onnx-v$LINUX_VERSION-linux-x64-static-lib.tar.bz2\` — GCC, manylinux2014 (glibc 2.17) baseline, drop-in for the official filename.

espeak-ng is NOT linked in either. sha256 in \`checksums/\`."
  gh_api PATCH "$api/releases/$release_id" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"body": sys.argv[1]}))' "$notes")" >/dev/null
  ok "Release 说明已更新"
fi

printf '\n'
ok "发布完成: Release $Tag"

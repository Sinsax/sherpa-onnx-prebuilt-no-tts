#!/usr/bin/env bash
#
# scripts/build-linux.sh —— linux-x64 目标全流程：
#   配置 → 校验 TTS=OFF → 构建 → 安装 → 对齐 13 项清单（缺的补空库）→ 组装归档 → 过门禁。
#
# 与 build.ps1（win-x64）对应，产物契约见 README 第 2 节。
# 产物归档名：sherpa-onnx-v<版本>-linux-x64-static-lib.tar.bz2
#   —— 这是消费方 sherpa-onnx-sys/build.rs 里 archive_name() 对
#      (static, linux, x86_64) 的输出，必须逐字符一致。
#
# 流程里有三处硬性校验，任一不过就停（与 build.ps1 相同）：
#   1) 配置后立刻查 CMakeCache，确认 SHERPA_ONNX_ENABLE_TTS=OFF 且 BUILD_SHARED_LIBS=OFF
#      （本仓存在的唯一理由，不能只靠信任参数拼写）
#   2) onnxruntime 预置包的 sha256
#   3) 组装完调 verify-archive.sh 过发布门禁
#
# 为什么默认在容器里编（--native 可覆盖）：
#   归档是发给别人链接的静态库，glibc 基线决定它能用在哪些发行版上。
#   在滚更发行版上本地编出来的 .a 会带上新的 GLIBC 符号引用
#   （例如 glibc 2.38 的 __isoc23_strtol），旧发行版上直接链接失败。
#   所以发布归档必须走固定基线的容器：镜像定义在 docker/Dockerfile.linux-x64
#   （ubuntu:22.04 + GCC 11，glibc 2.35；上游同代的编译器是 devtoolset-11）。
#   --native 只用于本机快速迭代（产物不要发出去）。
#
# 环境变量:
#   SHERPA_ONNX_BUILDER_IMAGE       覆盖构建镜像（例如指到 manylinux2014 复刻上游基线）
#   SHERPA_ONNX_BUILDER_APT_MIRROR  构建镜像时替换 Ubuntu apt 源（archive.ubuntu.com 不通时用）
#   SHERPA_ONNX_DOCKER_NETWORK      构建容器的 docker 网络，默认 host
#                                   （构建容器只要出网下载依赖；有些环境里 bridge 没有
#                                     NAT/出网，host 直接就通；要隔离就设成 bridge 或 none）
#
# 用法:
#   ./scripts/build-linux.sh                 # 容器 + 全流程
#   ./scripts/build-linux.sh --skip-build    # 复用 install/lib，只重打包 + 过门禁
#   ./scripts/build-linux.sh --native        # 用宿主工具链编译（仅供本地迭代）

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/common.sh"

usage() {
  cat >&2 <<'EOF'
用法: build-linux.sh [选项]

  --work-dir DIR   工作目录（上游源码 / CMake 构建树 / install 树），默认 <repo>/build
  --out-dir DIR    归档输出目录，默认 <repo>/dist
  --skip-build     跳过配置/构建/安装，直接用已有 install/lib 重新组装归档并过门禁
  --native         不用容器，用宿主机的 cmake/gcc（仅供本地迭代；发布归档别用它）
  -h, --help       显示本帮助

环境变量:
  JOBS=N           并行编译任务数，默认 min(nproc, 8)
EOF
  exit 2
}

WorkDir=""
OutDir=""
SkipBuild=0
Builder="container"

while (( $# > 0 )); do
  case "$1" in
    --work-dir) WorkDir="$2"; shift 2 ;;
    --out-dir) OutDir="$2"; shift 2 ;;
    --skip-build) SkipBuild=1; shift ;;
    --native) Builder="native"; shift ;;
    -h|--help) usage ;;
    *) die "未知参数: $1（-h 看用法）" ;;
  esac
done

[[ -n "$WorkDir" ]] || WorkDir="$REPO_ROOT/build"
[[ -n "$OutDir" ]] || OutDir="$REPO_ROOT/dist"

require_cmd git curl python3 tar bzip2 sha256sum mktemp
[[ "$Builder" == "container" ]] && require_cmd docker
[[ "$Builder" == "native" ]] && require_cmd cmake gcc g++ ar

load_linux_contract
load_expected_libs

# 与 build.ps1 一样：清单项数写死对齐 crate（13 项），多一项少一项都停下问清楚
(( ${#EXPECTED_LIBS[@]} == 13 )) ||
  die "expected_libs.list 应为 13 项（与 crate 的链接清单一致），实际 ${#EXPECTED_LIBS[@]} 项"

SrcDir="$WorkDir/upstream-src"
BuildDir="$WorkDir/cmake-build"
InstallLibDir="$BuildDir/install/lib"
OrtZip="$BuildDir/$LINUX_ORT_FILENAME"

JOBS="${JOBS:-$(nproc)}"
(( JOBS > 8 )) && JOBS=8

# 构建容器只需要出网：默认 host 网络。这不是性能选择 —— 有些环境下 docker 的默认
# bridge 没有 NAT，容器里连 github/apt 源都连不上，而 host 网络直接可用。
DOCKER_NETWORK="${SHERPA_ONNX_DOCKER_NETWORK:-host}"

CMAKE_ARGS_FILE="$REPO_ROOT/cmake/args-linux.cmake"
[[ -f "$CMAKE_ARGS_FILE" ]] || die "找不到 $CMAKE_ARGS_FILE"
mapfile -t CMAKE_ARGS < <(read_cmake_args_file "$CMAKE_ARGS_FILE")
(( ${#CMAKE_ARGS[@]} > 0 )) || die "$CMAKE_ARGS_FILE 里没读到 CMake 参数"

BuilderImage=""
if [[ "$Builder" == "container" ]]; then
  [[ -n "$LINUX_BUILDER_IMAGE" ]] || die "versions.toml 里没读到 [$LINUX_TARGET_SECTION] builder_image"
  BuilderImage="$LINUX_BUILDER_IMAGE"
  # 覆盖口：想复刻上游的 manylinux2014 基线（glibc 2.17），或本地镜像站另有搬运，
  # 都从环境变量换，不用改仓里的配方。
  if [[ -n "${SHERPA_ONNX_BUILDER_IMAGE:-}" ]]; then
    BuilderImage="$SHERPA_ONNX_BUILDER_IMAGE"
  fi
  BuilderLabel="docker: $BuilderImage"
else
  BuilderLabel="native: $(command -v cmake) / gcc $(gcc -dumpversion 2>/dev/null || echo '?')"
fi

info "sherpa-onnx v$LINUX_VERSION ($LINUX_COMMIT)  ->  $LINUX_ARCHIVE_NAME"
printf '   工作目录: %s\n' "$WorkDir"
printf '   输出目录: %s\n' "$OutDir"
printf '   构建者:   %s\n' "$BuilderLabel"
printf '   并行度:   %s\n' "$JOBS"
printf '   生效的 CMake 参数: %s\n' "${CMAKE_ARGS[*]}"

mkdir -p "$WorkDir" "$OutDir"

# ---------------------------------------------------------------- 构建者在哪跑
# 容器里路径是 /work/...，宿主机是 $WorkDir/...；两条路径指向同一个目录。
in_builder() { # <shell 脚本片段>（在构建目录下执行）
  local script="$1"
  if [[ "$Builder" == "container" ]]; then
    docker run --rm \
      --network "$DOCKER_NETWORK" \
      --user "$(id -u):$(id -g)" \
      --env HOME=/tmp \
      --volume "$WorkDir:/work" \
      --workdir /work/cmake-build \
      "$BuilderImage" \
      bash -c "set -euo pipefail
$script"
  else
    ( cd "$BuildDir" && bash -c "set -euo pipefail
$script" )
  fi
}

if [[ "$Builder" == "container" ]]; then
  if [[ -n "${SHERPA_ONNX_BUILDER_IMAGE:-}" ]]; then
    # 外部指定的镜像：直接用（不在本地则拉），不碰仓里的 Dockerfile
    if ! docker image inspect "$BuilderImage" >/dev/null 2>&1; then
      info "本地没有 $BuilderImage，拉取 ..."
      docker pull "$BuilderImage"
    fi
  elif ! docker image inspect "$BuilderImage" >/dev/null 2>&1; then
    [[ -n "$LINUX_BUILDER_DOCKERFILE" ]] || die "versions.toml 里没读到 [$LINUX_TARGET_SECTION] builder_dockerfile"
    dockerfile="$REPO_ROOT/$LINUX_BUILDER_DOCKERFILE"
    [[ -f "$dockerfile" ]] || die "找不到构建镜像的定义: $dockerfile"
    build_args=()
    if [[ -n "${SHERPA_ONNX_BUILDER_APT_MIRROR:-}" ]]; then
      build_args+=(--build-arg "UBUNTU_MIRROR=$SHERPA_ONNX_BUILDER_APT_MIRROR")
      note "apt 源替换为 $SHERPA_ONNX_BUILDER_APT_MIRROR"
    fi
    info "构建构建镜像 $BuilderImage ...（首次一分钟量级）"
    # 构建上下文用 Dockerfile 所在目录（里面只有这一个文件，不需要 .dockerignore）
    # 镜像构建里的 apt-get 同样需要出网，所以网络参数对 docker build 也成立
    docker build --network "$DOCKER_NETWORK" -f "$dockerfile" -t "$BuilderImage" \
      "${build_args[@]+"${build_args[@]}"}" "$(dirname "$dockerfile")"
  else
    note "复用已有构建镜像 $BuilderImage"
  fi
  SrcIn="/work/upstream-src"
  BuildIn="/work/cmake-build"
else
  SrcIn="$SrcDir"
  BuildIn="$BuildDir"
fi

if (( ! SkipBuild )); then
  mkdir -p "$BuildDir"

  # ------------------------------------------------------------ 上游源码
  if [[ ! -f "$SrcDir/CMakeLists.txt" ]]; then
    info "clone 上游 v$LINUX_VERSION ..."
    git clone --depth 1 --branch "v$LINUX_VERSION" "$LINUX_REPO" "$SrcDir"
  else
    info "复用已 clone 的上游源码: $SrcDir"
  fi

  actual_commit="$(git -C "$SrcDir" rev-parse HEAD | tr -d '[:space:]')"
  if [[ -n "$LINUX_COMMIT" && "$actual_commit" != "$LINUX_COMMIT" ]]; then
    die "上游 commit 不符：versions.toml 记录 $LINUX_COMMIT，实际 $actual_commit。tag 可能被移动过，先查清再编。"
  fi
  printf '   上游 commit: %s\n' "$actual_commit"

  # ------------------------------------------------------------ onnxruntime 预置
  # 放在 CMAKE_BINARY_DIR 下：上游 cmake/onnxruntime-linux-x86_64-static.cmake 会在
  # CMAKE_BINARY_DIR 里找同名文件，找到就跳过下载，而且我们能先校验 sha256。
  if [[ ! -f "$OrtZip" ]]; then
    info "下载 onnxruntime $LINUX_ORT_FILENAME ..."
    curl -fSL --retry 3 -o "$OrtZip.part" "$LINUX_ORT_URL"
    mv "$OrtZip.part" "$OrtZip"
  fi
  ort_actual="$(sha256_of "$OrtZip")"
  if [[ "$ort_actual" != "$LINUX_ORT_SHA256" ]]; then
    rm -f "$OrtZip"
    die "onnxruntime 归档 sha256 不匹配：期望 $LINUX_ORT_SHA256，实际 $ort_actual（已删除，重跑即可）"
  fi
  ok "onnxruntime sha256 校验通过"

  # ------------------------------------------------------------ 配置
  info "配置 ..."
  in_builder "cmake -S '$SrcIn' -B '$BuildIn' ${CMAKE_ARGS[*]}"

  cache="$BuildDir/CMakeCache.txt"
  [[ -f "$cache" ]] || die "配置后没有 $cache"
  grep -q '^SHERPA_ONNX_ENABLE_TTS:BOOL=OFF$' "$cache" ||
    die "CMakeCache 显示 SHERPA_ONNX_ENABLE_TTS 不是 OFF —— 停下，否则产物会带上 espeak-ng"
  grep -q '^BUILD_SHARED_LIBS:BOOL=OFF$' "$cache" ||
    die "CMakeCache 显示 BUILD_SHARED_LIBS 不是 OFF —— 归档名里的 static 就不成立了"
  ok "已确认 SHERPA_ONNX_ENABLE_TTS=OFF / BUILD_SHARED_LIBS=OFF"

  # 记工具链版本，供 publish-linux.sh 写进 checksum（归档是二进制再分发，
  # 谁在什么工具链下编的必须可追溯）
  info "记录工具链 ..."
  in_builder "gcc --version | head -1; cmake --version | head -1" | tee "$BuildDir/toolchain.txt"

  # ------------------------------------------------------------ 构建 + 安装
  info "构建 ...（首次是几十分钟量级）"
  in_builder "cmake --build '$BuildIn' -j $JOBS"

  info "安装到 <build>/install ..."
  in_builder "cmake --build '$BuildIn' --target install -j $JOBS"
else
  warn "--skip-build：跳过编译，直接用已有 $InstallLibDir"
fi

[[ -d "$InstallLibDir" ]] || die "找不到 $InstallLibDir"

# ---------------------------------------------------------------- 对齐 13 项清单
info "对齐链接清单 ..."
shopt -s nullglob
produced_files=("$InstallLibDir"/lib*.a)
shopt -u nullglob
(( ${#produced_files[@]} > 0 )) || die "$InstallLibDir 下没有任何 lib*.a"

produced=()
for f in "${produced_files[@]}"; do
  b="$(basename "$f")"
  b="${b#lib}"
  produced+=("${b%.a}")
done
printf '   构建产出 %s 个库: %s\n' "${#produced[@]}" "${produced[*]}"

missing=()
for name in "${EXPECTED_LIBS[@]}"; do
  found=0
  for p in "${produced[@]}"; do
    [[ "$p" == "$name" ]] && { found=1; break; }
  done
  (( found )) || missing+=("$name")
done

if (( ${#missing[@]} > 0 )); then
  warn "缺 ${#missing[@]} 项，补空库: ${missing[*]}"
  missing_csv="$(printf '%s,' "${missing[@]}")"
  "$HERE/make-empty-lib.sh" "${missing_csv%,}" "$InstallLibDir"
else
  ok "清单已齐，无需补空库"
fi

# ---------------------------------------------------------------- 组装归档
info "组装归档 ..."
stage_root="$OutDir/_stage"
rm -rf "$stage_root"
mkdir -p "$stage_root/$LINUX_TOP_DIR/lib"

shopt -s nullglob
stage_src=("$InstallLibDir"/lib*.a)
shopt -u nullglob

for f in "${stage_src[@]}"; do
  # 上游的 linux-x64 -lib 归档同样剔掉 libcargs.a：那是给可执行文件用的参数解析库，
  # crate 的链接清单里没有它，装上只是白占体积。
  [[ "$(basename "$f")" == "libcargs.a" ]] && { note "跳过 libcargs.a（上游归档同样剔除）"; continue; }
  cp -p "$f" "$stage_root/$LINUX_TOP_DIR/lib/"
done

archive_path="$OutDir/$LINUX_ARCHIVE_NAME"
pack_tarbz2 "$stage_root" "$LINUX_TOP_DIR" "$archive_path"
rm -rf "$stage_root"
ok "归档已生成: $archive_path"

# ---------------------------------------------------------------- 发布门禁
"$HERE/verify-archive.sh" "$archive_path" || die "门禁未通过，归档不该发布: $archive_path"

printf '\n'
info "下一步：scripts/publish-linux.sh 把归档挂到已有 Release v$LINUX_VERSION 上"

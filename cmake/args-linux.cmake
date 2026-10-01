# sherpa-onnx-prebuilt-no-tts —— 冻结的 CMake 参数（linux-x64 目标）
#
# 与 cmake/args.cmake（win-x64 目标）对应。三个「目的性」开关两边完全一致，
# 因为它们直接决定归档契约：
#   SHERPA_ONNX_ENABLE_TTS=OFF     —— 本仓存在的唯一理由（上游默认 ON）
#   BUILD_SHARED_LIBS=OFF          —— 归档名里的 static
#   CMAKE_BUILD_TYPE=Release       —— 归档名里的 Release
#
# linux-x64 与 win-x64 的差异（逐条给理由）：
#   * 不设 SHERPA_ONNX_USE_STATIC_CRT：上游 CMakeLists.txt:87 写明该开关
#     "For Windows only"，Linux 上无意义，设了也不影响产物。
#   * 不设 generator / platform：WIN 上用 "Visual Studio 17 2022" + x64，
#     Linux 用默认的 Unix Makefiles。
#   * SHERPA_ONNX_ENABLE_PORTAUDIO=OFF 的理由与 Windows 相同，另外在 Linux 上
#     还省掉 alsa-lib 依赖：上游只有 SHERPA_ONNX_ENABLE_BINARY=ON 时才真的
#     编 portaudio（CMakeLists.txt:549），而下面 BINARY=OFF，所以本来也编不到。
#
# 与官方工作流一样的另外两处刻意差异（都不影响 lib/*.a 的内容）：
#   -DSHERPA_ONNX_ENABLE_BINARY=OFF        只跳过可执行文件，库的 install 规则不受影响
#   -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF 同上
#
# 注意：-DCMAKE_INSTALL_PREFIX=./install 是相对路径，CMake 按「调用 cmake 时的 cwd」
# 解析；scripts/build-linux.sh 始终在构建目录里调用，所以安装树落在 <build>/install。

set(SHERPA_ONNX_PREBUILT_CMAKE_ARGS
  -DSHERPA_ONNX_ENABLE_TTS=OFF
  -DCMAKE_BUILD_TYPE=Release
  -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF
  -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_INSTALL_PREFIX=./install
  -DBUILD_ESPEAK_NG_EXE=OFF
  -DSHERPA_ONNX_ENABLE_BINARY=OFF
  -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF
)

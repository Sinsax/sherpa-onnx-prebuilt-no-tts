# sherpa-onnx-prebuilt-no-tts —— 冻结的 CMake 参数
#
# 唯一的「目的性」开关是 SHERPA_ONNX_ENABLE_TTS=OFF（上游默认是 ON）。
# 其余开关与上游 .github/workflows/windows-x64.yaml 里
# shared_lib=OFF / use_static_crt=ON / build_type=Release 那一格保持一致，
# 这样产出的库与官方 static-MT-Release 同源可替换。
#
# 归档名的三段后缀 static-MT-Release 正是由下面三个开关决定：
#   BUILD_SHARED_LIBS=OFF          → static
#   SHERPA_ONNX_USE_STATIC_CRT=ON  → MT  （关闭则 /MD，即 MD）
#   CMAKE_BUILD_TYPE=Release       → Release
#
# 与官方工作流的两处刻意差异（都不影响 lib/*.lib 的内容）：
#   -DSHERPA_ONNX_ENABLE_BINARY=OFF        只跳过可执行文件，库的 install 规则不受影响
#   -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF 同上

set(SHERPA_ONNX_PREBUILT_GENERATOR "Visual Studio 17 2022")
set(SHERPA_ONNX_PREBUILT_PLATFORM  "x64")

set(SHERPA_ONNX_PREBUILT_CMAKE_ARGS
  -DSHERPA_ONNX_ENABLE_TTS=OFF
  -DSHERPA_ONNX_USE_STATIC_CRT=ON
  -DCMAKE_BUILD_TYPE=Release
  -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF
  -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_INSTALL_PREFIX=./install
  -DBUILD_ESPEAK_NG_EXE=OFF
  -DSHERPA_ONNX_ENABLE_BINARY=OFF
  -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF
)

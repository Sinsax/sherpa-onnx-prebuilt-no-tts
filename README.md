# sherpa-onnx-prebuilt-no-tts

**Unofficial。本仓与 k2-fsa / sherpa-onnx 及其官方发布无任何隶属关系。**
本仓只做一件事：把上游 sherpa-onnx 编成 **TTS 关闭**的静态库，打包成
**文件名与官方完全一致**的归档，供下游不修改代码直接顶替使用。

目前两个目标，工具链与脚本各成一套：

| 目标 | 工具链 | 脚本 | 归档名 |
|---|---|---|---|
| win-x64 | MSVC /MT（VS 2022） | `scripts/*.ps1` | `sherpa-onnx-v1.13.3-win-x64-static-MT-Release-lib.tar.bz2` |
| linux-x64 | GCC 11 / glibc 2.35 基线（容器） | `scripts/*.sh` | `sherpa-onnx-v1.13.3-linux-x64-static-lib.tar.bz2` |

本仓自身以 **Apache-2.0** 发布（见 [LICENSE](LICENSE)）。但归档是上游代码的二进制再分发，
其内含组件的许可义务由分发方履行 —— 组件清单与需随附的声明全文见
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。

---

## 1. 为什么需要它

上游预编译静态包默认**无条件包含 espeak-ng**（GPL-3.0-or-later）。espeak-ng 是
TTS 的音素化库，只做 ASR 的下游项目根本不调用它 —— 它属于死依赖，却因为被静态链
进来，让整个二进制变成 GPL 组合作品。

上游 CMake 有开关：

```cmake
option(SHERPA_ONNX_ENABLE_TTS "Whether to build TTS related code" ON)   # 默认 ON
```

关掉之后 espeak-ng 与 piper-phonemize 不再编译。本仓产出的就是这么一份库。

**但消费方走不通这条路**：官方 `sherpa-onnx-sys` crate 只有 `static` / `shared`
两个 feature，没有关 TTS 的开关，且它在 `build.rs` 里写死了要下载的文件名。上游
其实**也发布** TTS-off 的归档，只是叫 `...-static-MT-Release-no-tts-lib.tar.bz2`
—— crate 不认识这个名字。

所以本仓做的事是：用 TTS=OFF 编出库，**发布到那个「带 TTS」的官方文件名上**，
做一个 drop-in 顶替。

---

## 2. 归档契约（本仓最重要的产出约定）

归档名不是随便起的：`sherpa-onnx-sys/build.rs` 的 `archive_name()` 按
（链接方式, 目标 OS, 目标架构）拼出唯一文件名，本仓必须逐字符对齐。

**win-x64**

| 项 | 值 |
|---|---|
| 归档名 | `sherpa-onnx-v1.13.3-win-x64-static-MT-Release-lib.tar.bz2` |
| 顶层目录 | `sherpa-onnx-v1.13.3-win-x64-static-MT-Release-lib`（= 归档名去掉 `.tar.bz2`） |
| 目录结构 | `<顶层>/lib/*.lib` |
| 内部文件数 | 14（13 项链接清单 + `sherpa-onnx-cxx-api.lib`） |

**linux-x64**

| 项 | 值 |
|---|---|
| 归档名 | `sherpa-onnx-v1.13.3-linux-x64-static-lib.tar.bz2` |
| 顶层目录 | `sherpa-onnx-v1.13.3-linux-x64-static-lib`（= 归档名去掉 `.tar.bz2`） |
| 目录结构 | `<顶层>/lib/*.a` |
| 内部文件数 | 14（13 项链接清单 + `libsherpa-onnx-cxx-api.a`） |
| 编译基线 | GCC 11.4 / glibc 2.35（见第 4 节的 Linux 小节） |

归档名里的版本号来自 **`sherpa-onnx-sys`** 的 `CARGO_PKG_VERSION`（不是
`sherpa-onnx` 的）。两者通常同号，但 `sherpa-onnx` 对 sys 用的是插入符依赖，
所以 cargo 有可能把 sys 解析到更新的 1.13.x —— 详见第 3 节的处置。

链接清单写死在 `sherpa-onnx-sys/build.rs` 顶部，共 **13 项**：

```
sherpa-onnx-c-api          sherpa-onnx-core           kaldi-decoder-core
sherpa-onnx-kaldifst-core  sherpa-onnx-fstfar         sherpa-onnx-fst
kaldi-native-fbank-core    kissfft-float              piper_phonemize
espeak-ng                  ucd                        onnxruntime
ssentencepiece_core
```

链接**不是** whole-archive，而是逐个 `cargo:rustc-link-lib=static=<name>`：

- 清单里的库文件**不存在** → 链接失败
- 文件**存在但没有符号被引用** → 链接器不会从中取任何东西

后一条正是「空库占位」之所以成立的原因。

这 13 个**名字**两个平台共用，但落到文件上不同：Windows 是
`<name>.lib`，Linux 是 `lib<name>.a`（rustc 在 Linux 上找 `lib<name>.a`）。
所以两个目标的空库文件名也必须分别正确，否则链接照样失败。

---

## 3. 怎么用（消费方）

下游通过 crate 的现成后门消费本仓产物，**crate 代码一行都不用改**：

```bash
# 把归档放进一个目录，构建时指过去
export SHERPA_ONNX_ARCHIVE_DIR=/path/to/dir/containing/the/archive
cargo build --release
```

也可以直接指向解压后的 lib 目录（这条路径连归档都不看）：

```bash
export SHERPA_ONNX_LIB_DIR=/path/to/extracted/lib
```

按平台放对应名字的那一个即可 —— crate 只会去找 `archive_name()` 算出来的文件名：
win-x64 找 `sherpa-onnx-v1.13.3-win-x64-static-MT-Release-lib.tar.bz2`，
linux-x64 找 `sherpa-onnx-v1.13.3-linux-x64-static-lib.tar.bz2`。
同一个目录里两个都放也没问题。

⚠️ **构建后务必断言产物里没有 espeak-ng**。这一条是防「忘了设环境变量、
静默回退官方归档」的唯一保险 —— 那种失败**不会有任何报错**。本仓给了现成的扫描器：

```powershell
# 单个文件，或整个输出目录（递归扫 exe/dll/lib/a/so/dylib）
powershell -File scripts\scan-artifact.ps1 -Path target\release
# 退出码 0 = 干净；1 = 检出 espeak-ng
```

扫的是 espeak-ng 的**特有标记**而非裸子串 `espeak`，理由见第 5 节 —— 用裸子串会把
正确的 ASR-only 产物误判为含 GPL 代码。

### 消费方必须把 sherpa-onnx-sys 钉在与本仓相同的版本

归档名里嵌的是 **`sherpa-onnx-sys` 的版本号**（`CARGO_PKG_VERSION`），不是
`sherpa-onnx` 的。而 `sherpa-onnx` 对 `sherpa-onnx-sys` 用的是**插入符依赖**
（1.13.3 的 crate 写的是 `sherpa-onnx-sys = "1.13.3"`），所以没有锁文件时
cargo 会解析到更新的 1.13.x —— 实测解析到 `1.13.6`，然后报：

```
SHERPA_ONNX_ARCHIVE_DIR does not contain expected archive:
  .../sherpa-onnx-v1.13.6-win-x64-static-MT-Release-lib.tar.bz2
```

这个报错是清晰的，不会静默用错库。处置：

- 消费方有提交的 `Cargo.lock` 且其中 `sherpa-onnx-sys` 就是本仓对应的版本
  （V-Trim 正是如此，锁着 1.13.3）→ 无需任何额外操作；
- 没有锁文件或锁到了别的版本 → 显式钉住：`sherpa-onnx-sys = "=1.13.3"`。

---

## 4. 怎么构建

### Windows（win-x64）

前置：VS 2022（MSVC + Windows SDK）、CMake ≥ 3.20、约 30 GB 空闲磁盘、
能访问 github.com（依赖由 CMake 在配置期下载；若走代理，请先设好
`http_proxy` / `https_proxy` 环境变量 —— CMake 用 libcurl，不读 git 的 proxy 配置）。

```powershell
# 全流程：clone 上游 → 下载 onnxruntime → 配置 → 构建 → 安装 → 补空库 → 打包 → 过门禁
powershell -ExecutionPolicy Bypass -File scripts\build.ps1

# 只重新打包并过门禁（复用已有 install\lib，不重新编译）
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -SkipBuild
```

| 文件 | 作用 |
|---|---|
| `versions.toml` | 上游版本 / 归档名 / 目标平台 / 期望库清单 / onnxruntime 来源 |
| `cmake/args.cmake` | 冻结的 CMake 参数（含 `-DSHERPA_ONNX_ENABLE_TTS=OFF`） |
| `scripts/common.ps1` | 共用的 TOML 读取、tar/cmake/MSVC 定位 |
| `scripts/build.ps1` | 全流程构建 |
| `scripts/make-empty-lib.ps1` | 造空库占位 |
| `scripts/verify-archive.ps1` | 发布门禁 |
| `scripts/scan-artifact.ps1` | 扫任意产物断言无 espeak-ng（**给消费方用的**） |
| `scripts/publish.ps1` | 门禁 → 写 checksums → 打 tag → 上传 Release |
| `cmake/args-linux.cmake` | linux 冻结的 CMake 参数（同样含 `-DSHERPA_ONNX_ENABLE_TTS=OFF`） |
| `docker/Dockerfile.linux-x64` | linux 发布口径的构建镜像（ubuntu:22.04 + GCC 11） |
| `scripts/common.sh` | bash 套件共用函数：TOML 读取 / 扫描器 / tar 打包 |
| `scripts/build-linux.sh` | linux 全流程构建 |
| `scripts/make-empty-lib.sh` | linux 造空库占位（`lib<name>.a`） |
| `scripts/verify-archive.sh` | linux 发布门禁 |
| `scripts/link-smoke-linux.sh` | 按 crate 的链接顺序做端到端冒烟测试 |
| `scripts/publish-linux.sh` | linux 发布：门禁 → 写 checksums → 上传 Release 资产 |

`build.ps1` 有三处硬性校验，任一不过就停：配置后立刻查 `CMakeCache.txt` 确认
`SHERPA_ONNX_ENABLE_TTS=OFF`（不靠信任参数拼写）、onnxruntime 预置包的 sha256、
组装后的发布门禁。

### Linux（linux-x64）

前置：Docker、能访问 github.com 与 Ubuntu apt 源、约 5 GB 空闲磁盘；
宿主需要 bash 4+ 与 python3 3.11+（脚本用标准库 `tomllib` 读 `versions.toml`，
不用 sed 手搓 —— 归档名错一个字符下游就取不到）。

```bash
# 全流程：构建镜像 → clone 上游 → 下载 onnxruntime → 配置 → 构建 → 安装 → 补空库 → 打包 → 过门禁
./scripts/build-linux.sh

# 只重新打包并过门禁（复用已有 install/lib，不重新编译）
./scripts/build-linux.sh --skip-build

# 端到端冒烟：按 crate 的链接顺序把归档链进一个小程序，再跑起来
./scripts/link-smoke-linux.sh

# 发布：门禁 → 写 checksums → 提交 → 上传 Release 资产
GITHUB_TOKEN=... ./scripts/publish-linux.sh
```

**为什么必须在容器里编**：归档是发给别人**链接**的静态库，`.a` 里的目标文件记着
自己引用的是哪个 glibc 版本的符号。在 Arch 这类滚更发行版上直编，产物会引用只有
新 glibc 才有的符号（例如 glibc 2.38 的 `__isoc23_strtol`），下游在 Ubuntu 22.04 /
Debian 12 上链接直接失败。所以发布口径固定在 `docker/Dockerfile.linux-x64`：
ubuntu:22.04（glibc 2.35）+ jammy 的 GCC 11.4 —— 编译器与上游 manylinux2014 里用的
devtoolset-11 同代。要复刻上游更宽的 glibc 2.17 基线，用
`SHERPA_ONNX_BUILDER_IMAGE` 指到 manylinux2014 镜像即可，不用改仓里的配方。

| 环境变量 | 作用 |
|---|---|
| `JOBS=N` | 并行任务数，默认 min(nproc, 8) |
| `SHERPA_ONNX_BUILDER_IMAGE` | 覆盖构建镜像（如指到 manylinux2014） |
| `SHERPA_ONNX_BUILDER_APT_MIRROR` | 构建镜像时替换 Ubuntu apt 源（`archive.ubuntu.com` 不通时用） |
| `SHERPA_ONNX_DOCKER_NETWORK` | 构建容器的 docker 网络，默认 `host` |

`build-linux.sh` 与 `build.ps1` 一样有三处硬性校验：CMakeCache 里
`SHERPA_ONNX_ENABLE_TTS=OFF` **且** `BUILD_SHARED_LIBS=OFF`（不靠信任参数拼写）、
onnxruntime 归档的 sha256（与上游 `cmake/onnxruntime-linux-x86_64-static.cmake`
里的 `onnxruntime_HASH` 一致）、以及组装后的发布门禁。

### TTS 关闭后缺哪几个库

实测（v1.13.3，win-x64 static MT Release），上游源码树产出 **11** 个库，
清单 13 项里缺 **3** 项：

| 缺失库 | 处置 |
|---|---|
| `espeak-ng` | 空库占位 |
| `piper_phonemize` | 空库占位 |
| `ucd` | 空库占位（espeak-ng 的 Unicode 数据依赖，官方归档里它的内容含 `espeak_` 符号） |

`ssentencepiece_core` **不在**缺失之列 —— 它被 ASR 用到，照常产出。
这正是为什么要以实际产出为准，不能凭猜。

空库的失败模式是**响亮的链接错误**（TTS 若没关干净就会出现未定义符号），
不是静默污染。

---

## 5. 发布门禁：怎么判定「TTS 真的关干净了」

### ⚠️ 不要用裸子串 `espeak` 做判据

上游工作流里用的是 `findstr /m /i /c:"espeak"`，**这个判据会误杀正确产物**。

sherpa-onnx 的说话人分离代码里有个类叫 `OfflineSpeaker*`，而
`OfflineSpeaker` 恰好含子串 `eSpeaker` —— 大小写不敏感搜 `espeak` 会命中它。

实测对照（v1.13.3 归档）：

| 库 | 官方带 TTS 的裸命中 | 官方带 TTS 的特有标记 | 本仓 TTS-off 的裸命中 | 本仓 TTS-off 的特有标记 |
|---|---|---|---|---|
| `sherpa-onnx-c-api.lib` | 170 | 0 | 170 | 0 |
| `sherpa-onnx-cxx-api.lib` | 238 | 0 | 238 | 0 |
| `sherpa-onnx-core.lib` | 1563 | 10 | 1451 | **0** |

`c-api` / `cxx-api` 两个版本的裸命中数**完全相同**，且特有标记都是 0 —— 证明它们
全部来自 `OfflineSpeaker` 类名，与 espeak-ng 无关。若按裸子串判定，一份
完全正确的 TTS-off 归档会被判失败。

### 正确的判据

搜 espeak-ng / piper **特有**标记（大小写不敏感），命中必须为 0：

```
espeak-ng      espeak ng      espeak_      libespeak      piper_phonemize
```

`espeak_` 覆盖 `espeak_Initialize` / `_espeak_*` / `ESPEAK_*` 这类符号与字符串；
`espeak ng` 覆盖注册表键 `Software\eSpeak NG`。

`scripts/verify-archive.ps1` 实现了这个判据，三条门禁一起跑：

1. 归档内所有 `.lib` 的内容里 espeak-ng 特有标记命中 **0**（并附打印裸命中数供参考）
2. `lib/` 下文件名集合覆盖 13 项链接清单
3. 记录 sha256

另外校验命名契约（文件名、顶层目录名、`lib/` 子目录），并对扫描器本身做自检
（防止扫描器永远返回 0 让门禁变成摆设）。

Linux 上的实现是 `scripts/verify-archive.sh`（判据、顺序、退出码语义完全一致），
并多一条：TTS 关闭后不再产出的 `libespeak-ng.a` / `libpiper_phonemize.a` /
`libucd.a` 必须是 **<4 KB 的空库**（真库是 80 万字节量级）—— 这一条直接排除
「把 GPL 二进制换个地方发」。

门禁证明不了「这份库真的能链接」。这一步由 `scripts/link-smoke-linux.sh` 补：
按 `sherpa-onnx-sys/build.rs` 里**同样的顺序**把 13 个静态库 `-l` 一遍，
外加 `-lstdc++ -lm -pthread -ldl`，链一个只调用 `SherpaOnnxGetVersionStr()`
的 C 程序，再扫链接产物、跑起来。实测结果见第 8 节。

---

## 6. 版本升级

1. 改 `versions.toml`：`[upstream]` 的 `version` / `commit`，以及两个目标各自的
   归档名与顶层目录 —— win-x64 在 `[archive]`，linux-x64 在
   `[targets.linux-x64]`（`top_dir` 必须等于 `name` 去掉 `.tar.bz2`）；
2. 若上游换了 onnxruntime 版本，同步改两个依赖段：`[prebuilt_deps.onnxruntime]`
   （win，sha256 在上游 `cmake/onnxruntime-win-x64-static.cmake`）与
   `[prebuilt_deps.onnxruntime-linux-x64]`（linux，sha256 在上游
   `cmake/onnxruntime-linux-x86_64-static.cmake` 的 `onnxruntime_HASH`）；
3. 重跑 `scripts\build.ps1`（win-x64）与 `scripts/build-linux.sh`（linux-x64）；
4. Windows 侧 `scripts\publish.ps1` 发新 tag + 新 checksum；Linux 侧
   `scripts/publish-linux.sh` 把新归档挂到同一个 tag 的 Release 上；
5. **旧 tag 与旧资产保留** —— 下游可能仍锁着旧版本。

---

## 7. 明确不做

- **不把归档提交进 git**（约 106 MB）—— 一律走 Release 资产。
- **不做 cargo 包发布**（不发 `-sys` fork 到 registry）：下游用环境变量消费即可。
- 不引入任何下游项目的代码或依赖。
- 归档里**绝不放上游那两个真库**（`espeak-ng.lib`、`piper_phonemize.lib`）——
  放了就等于「把 GPL 二进制换个地方发」，前功尽弃。

---

## 8. 实测记录（v1.13.3）

| 项 | 值 |
|---|---|
| 上游 | sherpa-onnx v1.13.3，commit `330609dab49be6ee8b30702918ca7abbbad1286a` |
| onnxruntime | 1.24.4，静态 CRT /MT，sha256 `abe61a1a6094c6ed69ae1c81a3acf6dfa65d6ee2ef5b4a73a55660a6f6072ecc` |
| 构建产出 | 11 个 `.lib`，补 3 个空库后共 14 个 |
| 归档 | 106.3 MiB（111,446,628 字节）；sha256 见 `checksums/v1.13.3.txt` |
| `sherpa-onnx-core.lib` | 本仓 51.0 MB（官方 66.0 MB） |

### 与上游 TTS-off 构建的对照

上游自己发布的 `...-no-tts-lib.tar.bz2` 也是 **11 个库**，缺的正是
`espeak-ng` / `piper_phonemize` / `ucd`，各库体积与本仓构建几乎逐字节一致
（如 `sherpa-onnx-core.lib`：上游 51,009,826 B vs 本仓 51,008,780 B）。
两者的 espeak 标记画像也完全相同（`c-api` 裸 170 / 特有 0，`core` 裸 1451 / 特有 0，
`cxx-api` 裸 238 / 特有 0）。

**注意**：上游那个 no-tts 归档缺这 3 个库文件，直接拿来顶替会让下游**链接失败**，
而且它的文件名也不在 crate 的期望之列。所以本仓的「补空库 + 顶替文件名」两步都是必要的。

### 端到端 A/B（同一份消费方代码，只换归档）

消费方只调用 ASR 路径（`OfflineRecognizer::create` / `VoiceActivityDetector::create`），
经 `SHERPA_ONNX_ARCHIVE_DIR` 消费归档，构建 debug 二进制后扫描：

| 归档 | 二进制里裸 `espeak` | espeak-ng 特有标记 |
|---|---|---|
| 官方 `...-lib.tar.bz2`（带 TTS） | 65 | `espeak-ng`=7, `espeak ng`=2, `espeak_`=51 |
| 本仓 `...-lib.tar.bz2`（TTS-off） | **0** | **0** |

官方那一列的 65 处裸命中，与本文档原始调研中「下游二进制命中 67 处」的量级一致。
两根轴都归零，说明 espeak-ng 确实没有被链接进产物 —— 而且二进制能正常运行
（会按预期报出模型配置缺失的运行时错误，证明链接进来的是可执行的真实代码）。

### linux-x64（本次新增）

| 项 | 值 |
|---|---|
| 上游 | sherpa-onnx v1.13.3，commit `330609dab49be6ee8b30702918ca7abbbad1286a` |
| onnxruntime | 1.24.4 linux-x64 static，sha256 `4244051e004612f5e83a41d02c22c23ad5b2e97eab49bc83fd20832567cb9f70` |
| 构建镜像 | ubuntu:22.04 + GCC 11.4.0 + CMake 3.22.1（glibc 2.35 基线） |
| 构建产出 | 11 个 `.a`，补 3 个空库（`libespeak-ng.a` / `libpiper_phonemize.a` / `libucd.a`，各 1,068 B）后共 14 个 |
| 归档 | 18.1 MiB（18,984,422 字节）；sha256 见 `checksums/v1.13.3-linux-x64.txt` |
| 门禁 1 | 14 个 `.a` 中 espeak-ng/piper 特有标记 **0**；裸子串 espeak 共 369（`core` 263 / `c-api` 62 / `cxx-api` 44，全部来自 `OfflineSpeaker*`） |
| 门禁 2 | 13 项链接清单全覆盖；三个占位空库均 <4 KB |
| 冒烟 | 按 crate 顺序链接通过；二进制特有标记 **0**（裸 145）；运行输出 `1.13.3` |
| `libsherpa-onnx-core.a` | 12.8 MB |
| `libonnxruntime.a` | 99.1 MB（上游预编译包原样） |

与 win-x64 同源：同一份上游源码、同一组 CMake 开关（`TTS=OFF` /
`BUILD_SHARED_LIBS=OFF`），差别只在编译器与平台 ABI；库清单也一致 ——
11 个真库 + 同样那 3 个空库占位。

---

## 9. 许可

- **本仓自身**：Apache-2.0，见 [LICENSE](LICENSE)。选它是因为它与归档内每个组件都兼容，
  且其归属机制正好承载再分发所需的声明义务。
- **归档**：是上游代码的**二进制再分发**，义务由被编译进去的组件决定，不由本仓声明的协议决定。
  完整组件清单（含版本与来源）与需随附的许可声明全文见
  [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。

实测本次构建编译进去的组件许可构成：Apache-2.0（sherpa-onnx、openfst、kaldi-*、
kaldifst、simple-sentencepiece）、MIT（ONNX Runtime、nlohmann/json）、BSD-3-Clause
（kissfft、websocketpp）、BSD-2-Clause（fastcluster）、Boost-1.0（Asio）、
MPL-2.0（Eigen）。**没有任何 GPL / LGPL / AGPL。**

唯一带「提供源码」义务的是 **Eigen 的 MPL-2.0**，而它要求提供的是 **Eigen 自己的源码**
（公开可得），不是你的项目源码；MPL-2.0 §3.3 也明确允许把它作为 Larger Work 以不同条款分发。
也就是说，**消费方可以据此闭源发布自己的二进制**。

⚠️ 反过来说：一旦把 espeak-ng 加回来（改用官方归档、或 TTS=ON 构建），
**GPL-3.0-or-later 的义务会立刻回来**，整份声明都要重做。这就是第 3 节那个
「构建后必须断言」的意义。

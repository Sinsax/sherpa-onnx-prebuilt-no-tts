# sherpa-onnx-prebuilt-no-tts

**Unofficial。本仓与 k2-fsa / sherpa-onnx 及其官方发布无任何隶属关系。**
本仓只做一件事：把上游 sherpa-onnx 编成 **TTS 关闭**的 win-x64 静态库，打包成
**文件名与官方完全一致**的归档，供下游不修改代码直接顶替使用。

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

| 项 | 值 |
|---|---|
| 归档名 | `sherpa-onnx-v1.13.3-win-x64-static-MT-Release-lib.tar.bz2` |
| 顶层目录 | `sherpa-onnx-v1.13.3-win-x64-static-MT-Release-lib`（= 归档名去掉 `.tar.bz2`） |
| 目录结构 | `<顶层>/lib/*.lib` |
| 内部文件数 | 14（13 项链接清单 + `sherpa-onnx-cxx-api.lib`） |

归档名里的版本号必须与消费方 `Cargo.toml` 里 `sherpa-onnx = "x.y.z"` 完全一致。

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

⚠️ **构建后务必断言产物里没有 espeak-ng**（第 5 节给了判据）。这一条是防
「忘了设环境变量、静默回退官方归档」的唯一保险 —— 那种失败**不会有任何报错**。

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
| `scripts/publish.ps1` | 门禁 → 写 checksums → 打 tag → 上传 Release |

`build.ps1` 有三处硬性校验，任一不过就停：配置后立刻查 `CMakeCache.txt` 确认
`SHERPA_ONNX_ENABLE_TTS=OFF`（不靠信任参数拼写）、onnxruntime 预置包的 sha256、
组装后的发布门禁。

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

---

## 6. 版本升级

1. 改 `versions.toml`：`[upstream]` 的 `version` / `commit`，以及 `[archive]` 的
   `name` / `top_dir`（两处都要带上新版本号）；
2. 若上游换了 onnxruntime 版本，同步改 `[prebuilt_deps.onnxruntime]`
   （版本、文件名、URL、sha256 —— sha256 在上游 `cmake/onnxruntime-win-x64-static.cmake`
   里能查到）；
3. 重跑 `scripts\build.ps1`；
4. `scripts\publish.ps1` 发新 tag + 新 checksum；
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
| `sherpa-onnx-core.lib` | 本仓 51.0 MB（官方 66.0 MB） |
| espeak-ng 特有标记 | 本仓 0；官方带 TTS 归档仅 core/c-api/cxx-api 之外的部分就有 534 + 50 + 6 处 |

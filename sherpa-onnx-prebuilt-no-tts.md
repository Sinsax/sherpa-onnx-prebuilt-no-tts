# sherpa-onnx-prebuilt-no-tts —— 自建 sherpa-onnx 原生库分发仓

> 本文件是**自包含交接文档**：复制到新目录即可作为一个独立仓库的运营手册，不依赖任何外部对话上下文。

---

## 1. 仓库定位

**做**：把上游 sherpa-onnx 编成 **TTS 关闭（不带 espeak-ng）的静态库** → 打包归档 → 发布 → 记录校验和。

**不做**：不引用任何下游项目、不认识 Cargo workspace、不放业务代码。本仓只有"构建配方 + 产出物"。

- **仓库名：`sherpa-onnx-prebuilt-no-tts`**
- **tag 命名：`v<上游版本>`，例如 `v1.13.3`**（变体已进仓库名，tag 只表版本）
- 两条命名轴分工：**变体 → 仓库名**，**版本 → tag / 归档名**
- 备选名（若要一个仓容纳多变体）：`sherpa-onnx-prebuilt` + tag 带变体后缀（`v1.13.3-no-tts`）。仅在确定会有第二个变体时才这样做
- ⚠️ README 首行必须写明 **unofficial，与 k2-fsa 及其官方发布无隶属关系**，避免被误认为官方产物

---

## 2. 为什么需要它

上游 sherpa-onnx 的**预编译静态包无条件包含 espeak-ng（GPL-3.0-or-later）**，而 espeak-ng 是 **TTS（语音合成）的音素化库**。只做 ASR 的下游项目根本不会调用它 —— 它属于**死依赖**，却因为被静态链进来，让整个二进制变成 GPL 组合作品，一旦分发就必须随附源码。

实测证据：一个**只做 ASR、零 TTS 调用**的下游程序，其发行二进制里 `espeak` 字符串命中 **67 处**（含 espeak-ng 自己的报错串与注册表键 `Software\eSpeak NG`）。也就是说那些目标文件确实被拉进了链接。

而上游 CMake 提供了关闭开关：

```
option(SHERPA_ONNX_ENABLE_TTS "Whether to build TTS related code" ON)
```

默认是 **ON**；关掉之后，**espeak-ng 与 piper-phonemize 不会被编译，也不会被拉入**。本仓产出的就是这么一份库。

---

## 3. 与消费方的接口契约（本仓最重要的产出约定）

下游通过官方 `sherpa-onnx-sys` crate 的现成后门消费本仓产物，**它的代码一行都不用改**：

| 后门 | 行为 |
|---|---|
| `SHERPA_ONNX_ARCHIVE_DIR` | 指向一个目录，crate 从中按**固定文件名**取归档（不下载）。文件名不匹配会报 `does not contain expected archive` |
| `SHERPA_ONNX_LIB_DIR` | 直接指向 lib 目录，**只检查是不是目录**，无任何清单校验 |
| （隐式）缓存短路 | `target/sherpa-onnx-prebuilt/<归档名去扩展名>/lib/` 存在即直接返回，连归档都不用 |

因此归档有两个**必须逐字符对齐**的约定：

1. **归档文件名**：`sherpa-onnx-v<版本>-win-x64-static-MT-Release-lib.tar.bz2`
   （例：`sherpa-onnx-v1.13.3-win-x64-static-MT-Release-lib.tar.bz2`）
2. **归档内部结构**：顶层目录名 = 归档名去掉 `.tar.bz2`，其下为 `lib/*.lib`

```
sherpa-onnx-v1.13.3-win-x64-static-MT-Release-lib/
└── lib/
    ├── sherpa-onnx-c-api.lib
    ├── sherpa-onnx-core.lib
    └── …（见 §5.2 清单）
```

版本号必须与消费方 `Cargo.toml` 里的 `sherpa-onnx = "x.y.z"` **完全一致** —— 归档名里就嵌着它。

---

## 4. 已核实的事实（可采信，不必重查）

| 项 | 值 |
|---|---|
| 参考版本 | sherpa-onnx **v1.13.3**（按消费方当前锁定版本） |
| crate 的静态链接清单 | 写死在 `sherpa-onnx-sys/build.rs` 顶部，共 **13 项**（见 §5.2） |
| 是否 whole-archive | **否**。逐个 `cargo:rustc-link-lib=static=<name>`。所以：清单里的库**文件不存在会链接失败**，**存在但无符号引用则不会被取用** |
| crate 的 features | 只有 `static` / `shared`，**没有**关 TTS 的开关 —— 所以必须自建原生库，而不是改 crate 配置 |
| 官方归档体积 | 压缩 **109 MB**；解压后 `onnxruntime.lib` **779 MB**、`sherpa-onnx-core.lib` **63 MB**、`espeak-ng.lib` **808 KB**、`piper_phonemize.lib` **784 KB**、`ucd.lib` **240 KB** |
| 官方归档实际文件数 | **14 个** = 上述 13 项 + `sherpa-onnx-cxx-api.lib`（不在链接清单里，留着无害） |

---

## 5. 构建配方

**前置**：VS Build Tools（MSVC + Windows SDK）、CMake ≥ 3.20、约 30 GB 空闲磁盘（`onnxruntime.lib` 解压后就近 800 MB，构建中间产物更大）。首次编译预计几十分钟。

### 5.1 配置与构建

```bash
cmake -S <sherpa-onnx-src> -B build -G "Visual Studio 17 2022" -A x64 \
  -DSHERPA_ONNX_ENABLE_TTS=OFF \
  -DBUILD_SHARED_LIBS=OFF \
  -DSHERPA_ONNX_ENABLE_C_API=ON \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

关键就是 `-DSHERPA_ONNX_ENABLE_TTS=OFF`（**默认是 ON，必须显式关**）。

### 5.2 对齐库清单（这一步不能凭猜）

把产出的 `.lib` 与下面 13 项逐一对照，**缺哪个补哪个**：

```
sherpa-onnx-c-api          sherpa-onnx-core           kaldi-decoder-core
sherpa-onnx-kaldifst-core  sherpa-onnx-fstfar         sherpa-onnx-fst
kaldi-native-fbank-core    kissfft-float              piper_phonemize
espeak-ng                  ucd                        onnxruntime
ssentencepiece_core
```

TTS 关掉后**至少**会缺 `espeak-ng` 与 `piper_phonemize`，很可能还缺 `ucd`、`ssentencepiece_core` —— 以实际产出为准。

**补空库**（在 VS 开发者命令提示符里执行，或先调 `vcvars64.bat`）：

```bash
echo. > empty.c
cl /c /Foempty.obj empty.c
lib /out:espeak-ng.lib empty.obj
```

空库之所以成立：链接清单里有这个名字，文件必须存在；而 TTS 关闭后**没有任何目标文件引用 espeak 的符号**，链接器不会从中取任何东西。它的失败模式是**响亮的链接错误**（若哪天 TTS 关不干净就会出现未定义符号），**不是静默污染**。

### 5.3 组装归档

```bash
# 目录名必须与归档名严格对应
tar -cjf sherpa-onnx-v1.13.3-win-x64-static-MT-Release-lib.tar.bz2 \
    sherpa-onnx-v1.13.3-win-x64-static-MT-Release-lib
```

### 5.4 自检门禁（必须通过才允许发布）

1. 归档内所有 `.lib` 的 `espeak` 字样命中 **0**：
   ```
   findstr /m /i /c:"espeak" lib\*.lib     # 无输出 = 通过
   ```
2. `lib/` 下的文件名集合覆盖 §5.2 的 13 项；
3. 记录 `sha256`（`certutil -hashfile <归档> SHA256`）。

---

## 6. 仓库结构

```
sherpa-onnx-prebuilt-no-tts/
├── README.md                  # 首行 unofficial 声明；为什么存在；怎么用；归档契约（§3）
├── versions.toml              # 上游版本 / 归档名 / 目标平台 / 期望库清单
├── cmake/args.cmake           # 固定的 CMake 参数（含 -DSHERPA_ONNX_ENABLE_TTS=OFF）
├── scripts/
│   ├── build.ps1              # §5 全流程：配置 → 构建 → 对齐清单 → 组装归档
│   ├── make-empty-lib.ps1     # 造空库（§5.2）
│   ├── verify-archive.ps1     # §5.4 三条门禁，任一不过就非零退出
│   └── publish.ps1            # 打 tag、上传资产、写 checksums
├── checksums/v1.13.3.txt      # 归档名 + sha256 + 上游版本
└── .github|.gitea/workflows/build.yml   # 可选：workflow_dispatch 手动触发
```

`versions.toml` 建议形态：

```toml
[upstream]
version = "1.13.3"
archive = "sherpa-onnx-v1.13.3-win-x64-static-MT-Release-lib.tar.bz2"
target  = "win-x64"
cmake_flags = ["-DSHERPA_ONNX_ENABLE_TTS=OFF", "-DBUILD_SHARED_LIBS=OFF", "-DSHERPA_ONNX_ENABLE_C_API=ON"]

[expected_libs]   # 与 crate 写死的清单一致，verify 脚本据此核对
list = ["sherpa-onnx-c-api", "sherpa-onnx-core", "kaldi-decoder-core",
        "sherpa-onnx-kaldifst-core", "sherpa-onnx-fstfar", "sherpa-onnx-fst",
        "kaldi-native-fbank-core", "kissfft-float", "piper_phonemize",
        "espeak-ng", "ucd", "onnxruntime", "ssentencepiece_core"]
```

---

## 7. 运作流程

### 首次建立（一次性）
1. 建仓、写 README（含 unofficial 声明）与 `versions.toml`；
2. **本机编通**（§5），拿到可用归档 —— 这是唯一有技术风险的环节；
3. 跑 §5.4 门禁，通过后发 Release tag `v1.13.3`，附归档 + `checksums/v1.13.3.txt`；
4. 本机编通之后，再把流程抽成 CI（CI 里跑的是已验证的配方，而不是未知实验）。

### 版本升级（每次上游升级）
1. 改 `versions.toml` 的 `version` / `archive`（两处必须一起改）；
2. 重跑 §5；
3. 发新 tag（如 `v1.13.4`）+ 新 checksum 文件；
4. **旧 tag 与旧资产保留**（下游可能仍锁着旧版本）。

### CI（可选）
- 有 runner 就用 `workflow_dispatch` 手动触发；**自托管 runner 尤其是这类构建的好选择**（增量缓存留得住：首次几十分钟、之后很快）。
- 没有 CI 也行：本机编 + 手动上传 Release 资产，脚本化即可。

---

## 8. 明确不做

- **不把归档提交进 git**（109 MB）—— 一律走 Release 资产。
- **不做 cargo 包的对外发布**（不发 `-sys` fork 到 registry）：下游用环境变量消费即可。
- 不在本仓引入任何下游项目的代码或依赖。
- 归档里**绝不放上游那两个真库**（`espeak-ng.lib` 808 KB、`piper_phonemize.lib` 784 KB）——放了就等于"把 GPL 二进制换个地方发"，前功尽弃。

---

## 9. 风险与退路

| 风险 | 处置 |
|---|---|
| CMake 编不过 / 大面积缺符号 | 记录**具体缺失的符号**，判断是"TTS 没关干净"还是需要补充 `-DSHERPA_ONNX_ENABLE_*` 开关 |
| TTS=OFF 结构上不可行（仍有 TTS 目标文件被引用） | 放弃空库方案，改为自建一个精简 `-sys` crate：fork `sherpa-onnx-sys`，从 build.rs 的清单里删掉 TTS 相关库名，build.rs 用 `cmake` crate 自行构建（参照 `sherpa-rs-sys` 的写法：`if cfg!(feature="tts") { define("ON") } else { define("OFF") }`）。代价：crate 版本号须与上游一致、每次全新环境都要重编 C++ |
| MSVC 拒绝空 obj | 改用"最小非空 obj"（一个空函数）造库 |
| 上游将来改用 whole-archive | 空库方案仍成立（没有符号可冲突）；若出现未定义符号会链接报错，可及时发现 |

---

## 10. 任务清单

- [ ] 建仓 `sherpa-onnx-prebuilt-no-tts`，写 README（unofficial 声明 + §3 归档契约）与 `versions.toml`
- [ ] clone 上游 v1.13.3，按 §5.1 编出 TTS-off 静态库
- [ ] 按 §5.2 对齐 13 项清单，缺失项造空库
- [ ] 按 §5.3 组装归档（目录名与文件名严格对齐）
- [ ] 按 §5.4 过三条门禁（无 espeak 字样 / 清单覆盖 / sha256）
- [ ] 发 Release tag `v1.13.3`，提交 `checksums/v1.13.3.txt`
- [ ] 本机编通后，抽 `workflow_dispatch` CI（可选）

---

## 附：给消费方的一句话

消费方（任何用官方 `sherpa-onnx-sys` 的项目）只需要：把归档放进一个目录 → 构建时设 `SHERPA_ONNX_ARCHIVE_DIR` 指向它 → **构建后断言产物里 `espeak` 命中为 0**（这一条是防"忘了设变量、静默回退官方归档"的唯一保险）。

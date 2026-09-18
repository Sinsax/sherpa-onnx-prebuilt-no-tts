# 第三方组件与许可

本仓（`sherpa-onnx-prebuilt-no-tts`）自身以 **Apache-2.0** 发布，见 [LICENSE](LICENSE)。

但请注意：**本仓发布的归档是上游代码的二进制再分发**。因此随 Release 资产一起发出的
`.tar.bz2` 里，包含了下面第一、二节所列的全部组件。无论本仓声明什么许可，这些组件各自的
条款都由**分发该归档的人**负责履行。

> 本文档按事实性说明编写，不构成法律意见。各组件条款以各自上游的许可原文为准。

---

## 一、归档里实际编译进去的组件

以下清单来自 v1.13.3 这次构建的**实际配置日志**（不是从上游文档抄的），即真正被下载、
编译并装进 `lib/*.lib` 的东西。

### Apache-2.0

| 组件 | 版本 / 来源 |
|---|---|
| sherpa-onnx | v1.13.3，`github.com/k2-fsa/sherpa-onnx` |
| openfst | v1.8.5-2026-04-11，`github.com/csukuangfj/openfst` |
| kaldi-decoder | v0.3.0，`github.com/k2-fsa/kaldi-decoder` |
| kaldi-native-fbank | v1.22.3，`github.com/csukuangfj/kaldi-native-fbank` |
| kaldifst | v1.8.0，`github.com/k2-fsa/kaldifst` |
| simple-sentencepiece | v0.7，`github.com/pkufool/simple-sentencepiece` |

Apache-2.0 要求向接收者提供一份许可证副本 —— 这由本仓根目录的 [LICENSE](LICENSE) 满足。
这些组件上游都**没有**附带 `NOTICE` 文件，因此 Apache-2.0 §4(d) 不触发。

### MIT

| 组件 | 版本 / 来源 |
|---|---|
| ONNX Runtime | 1.24.4（预编译静态库，`github.com/csukuangfj/onnxruntime-libs`） |
| nlohmann/json | v3.12.0 |

### BSD-3-Clause

| 组件 | 版本 / 来源 |
|---|---|
| kissfft | commit `febd4ca`，`github.com/mborgerding/kissfft` |
| websocketpp | commit `b9aeec6`，`github.com/zaphoyd/websocketpp` |

### BSD-2-Clause

| 组件 | 版本 / 来源 |
|---|---|
| fastcluster（`hclust-cpp`） | tag `2026-02-25`，`github.com/csukuangfj/hclust-cpp` |

### Boost Software License 1.0

| 组件 | 版本 / 来源 |
|---|---|
| Asio | `asio-1-24-0`，`github.com/chriskohlhoff/asio` |

### MPL-2.0

| 组件 | 版本 / 来源 |
|---|---|
| Eigen | 5.0.1，`gitlab.com/libeigen/eigen` |

Eigen 的说明单列在第四节。

---

## 二、**不在**归档里的组件（本仓与前缀 `no-tts` 的关键区别）

上游官方预编译静态包中，以下三个组件会被无条件链入；**本仓的归档里没有它们**：

| 组件 | 上游许可 | 状态 |
|---|---|---|
| **espeak-ng** | **GPL-3.0-or-later** | 未下载、未编译、未链接 |
| piper-phonemize | （依赖 espeak-ng） | 未下载、未编译、未链接 |
| ucd | espeak-ng 的 Unicode 数据依赖 | 未下载、未编译、未链接 |

依据：上游 `CMakeLists.txt` 在 `SHERPA_ONNX_ENABLE_TTS=OFF` 时跳过
`include(espeak-ng-for-piper)` 与 `include(piper-phonemize)`；本次构建的配置日志中，
这三者从未出现在任何下载行里。

**注意**：归档内仍有名为 `espeak-ng.lib`、`piper_phonemize.lib`、`ucd.lib` 的文件，
但它们是本仓用空翻译单元造的**占位归档（各 896 字节，零符号）**，纯属为了满足下游
`sherpa-onnx-sys` 写死的链接清单。它们不含任何 espeak-ng 代码。

验证方法见本仓 `scripts/verify-archive.ps1`（扫归档内所有 `.lib` 的
`espeak-ng` / `espeak ng` / `espeak_` / `libespeak` / `piper_phonemize` 特有标记，必须为 0），
以及给消费方用的 `scripts/scan-artifact.ps1`（在自己构建出的二进制上做同样断言）。

---

## 三、需要随二进制随附的许可声明全文

### ONNX Runtime（MIT）

```
MIT License

Copyright (c) Microsoft Corporation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

> ⚠️ ONNX Runtime 的预编译包（`onnxruntime-win-x64-static_lib-MT-Release-1.24.4.tar.bz2`）
> **只含 `include/` 与 `lib/`，不含任何许可文件**。所以上面这段声明必须由分发方自行补上 ——
> 本仓在这里补，消费方在再分发自己的二进制时也要一并带上。

### nlohmann/json（MIT）

```
MIT License

Copyright (c) 2013-2025 Niels Lohmann

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### kissfft（BSD-3-Clause）

```
Copyright (c) 2003-2010 Mark Borgerding. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright notice,
    this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright notice,
    this list of conditions and the following disclaimer in the documentation
    and/or other materials provided with the distribution.
  * Neither the name of the author nor the names of its contributors may be
    used to endorse or promote products derived from this software without
    specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

### websocketpp（BSD-3-Clause）

```
Copyright (c) 2014, Peter Thorson. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the WebSocket++ Project nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL PETER THORSON BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### fastcluster / hclust-cpp（BSD-2-Clause 风格）

```
Copyright:
  * fastcluster_dm.cpp & fastcluster_R_dm.cpp:
     (c) 2011 Daniel Mullner <http://danifold.net>
  * fastcluster.(h|cpp) & demo.cpp & plotresult.r:
     (c) 2018 Christoph Dalitz <http://www.hsnr.de/ipattern/>
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright notice,
    this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

### Asio（Boost Software License 1.0）

```
Boost Software License - Version 1.0 - August 17th, 2003

Permission is hereby granted, free of charge, to any person or organization
obtaining a copy of the software and accompanying documentation covered by
this license (the "Software") to use, reproduce, display, distribute,
execute, and transmit the Software, and to prepare derivative works of the
Software, and to permit third-parties to whom the Software is furnished to
do so, all subject to the following:

The copyright notices in the Software and this entire statement, including
the above license grant, this restriction and the following disclaimer,
must be included in all copies of the Software, in whole or in part, and
all derivative works of the Software, unless such copies or derivative
works are solely in the form of machine-executable object code generated by
a source language processor.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

> 附带说明：BSL-1.0 的声明义务对「纯机器可执行目标码形式」的副本是豁免的。
> 上面这段在纯二进制分发场景下并非强制，此处一并列出以求完整。

---

## 四、Eigen（MPL-2.0）—— 本条链上唯一带「提供源码」义务的组件

Eigen 以 **MPL-2.0** 为主（部分文件为 BSD 或其它 MPL2 兼容许可）。它是 header-only 库，
本次构建确有编译（`eigen.cc`），因此其代码可能在 `sherpa-onnx-core.lib` 中。

MPL-2.0 §3.2 规定：以可执行形式分发时，该组件**自身**的源码必须可获取，且须告知接收者获取方式。

**要点：这项义务的对象是 Eigen 的源码，不是你的项目源码。** MPL-2.0 §3.3 也明确允许把
它作为 Larger Work 以不同条款分发。所以它不妨碍闭源分发。

本仓的履行方式：Eigen 未被修改，其源码公开可得 ——
<https://gitlab.com/libeigen/eigen>（本构建使用的版本：5.0.1）。
完整许可文本见 <https://www.mozilla.org/MPL/2.0/>。

---

## 五、给再分发者的提示

如果你把本仓的归档（或含它的二进制）再分发出去，需要注意：

1. 上面的归属声明要**一并带上**，别只发一个 `.tar.bz2`；
2. 自己构建出的产物，用 `scripts/scan-artifact.ps1` 断言一次 espeak-ng 命中为 0 ——
   这是防「忘了设环境变量、静默回退到官方带 espeak-ng 的归档」的唯一保险，
   那种失败**不会有任何报错**；
3. 若你把 `espeak-ng` 加回来（即改用官方归档或 TTS=ON 构建），**GPL-3.0-or-later 义务会立刻回来**，
   整份声明都需要重做。

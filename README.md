# llamacpp-metal-amd

在 macOS 上为 **AMD / Intel 独立显卡**构建 Metal 加速的 llama.cpp。

官方 llama.cpp 的 Metal 后端在独显上跑不起来：它用 `newBufferWithBytesNoCopy`
把权重映射成共享内存（`MTLResourceStorageModeShared`），独显每算一次都要通过
PCIe 从系统内存重新搬权重，带宽被卡死，最后触发
`kIOAccelCommandBufferCallbackErrorTimeout`（GPU 超时），输出变成 `@@@@` 之类的乱码。
这个问题被官方关闭为 not planned
（[issue #15228](https://github.com/ggml-org/llama.cpp/issues/15228)）。

ToshLLM 的补丁系列重建了整个 Metal 后端，让这类显卡能真正用起来。这个仓库把它做成
可复现的构建：pin 住版本、一条命令编译、一条命令自检。

## 用法

```bash
git clone --recurse-submodules https://github.com/imhun/llamacpp-metal-amd.git
cd llamacpp-metal-amd
./scripts/build.sh
```

忘记 `--recurse-submodules` 也没关系，脚本会自己补拉。

首次编译 5-15 分钟，之后重复执行会跳过已完成的部分。产物：

```
tmp/llama.cpp/build-metal/bin/llama-mtmd-cli
```

用起来就是标准的 llama.cpp 命令行：

```bash
tmp/llama.cpp/build-metal/bin/llama-mtmd-cli \
  -m 模型.gguf --mmproj mmproj.gguf --image 页面.png -p "提取图中所有文字"
```

常用参数：

```bash
./scripts/build.sh --rebuild      # 重编（保留源码和补丁）
./scripts/build.sh --clean        # 从 clone 开始重来
./scripts/build.sh -j 8           # 限制并行度
./scripts/build.sh --help
```

## 自检

```bash
./scripts/verify.sh
```

不需要模型，几秒钟出结果。判据是启动日志里的两行：

```
ggml_metal: device 0: AMD Radeon Pro 5500M (peer group 0, not bridged)
            probed SIMD-group width = 32 (32 = Apple/AMD RDNA, 64 = AMD GCN/Vega)
```

`probed SIMD-group width` 是补丁引入的，官方构建的二进制里连这个字符串都没有
（`strings llama-mtmd-cli | grep 'probed SIMD-group'` 返回空）。所以这一行在不在，
就是补丁有没有生效的硬判据——光看「Metal 设备已识别」不够，官方版也会识别设备，
只是算不对。

带上模型可以顺便跑一次真实推理：

```bash
./scripts/verify.sh --model 模型.gguf --mmproj mmproj.gguf
```

## 这个补丁能带来什么

在一台 2019 款 MacBook Pro 16（i9-9880H + Radeon Pro 5500M 8GB）上跑视觉语言模型，
视觉编码阶段的耗时：

| 后端 | 耗时 | 输出 |
| --- | --- | --- |
| CPU（Accelerate） | 159 s | 正确 |
| Metal（官方构建） | 39.4 s | GPU 超时，`@@@@` 乱码 |
| Vulkan（MoltenVK） | ~27 s | 输出全为 `1`，原因未定位 |
| **Metal（打上这批补丁）** | **4.8 s** | 正确 |

完整记录见 [ovisocr2-mac](https://github.com/imhun/ovisocr2-mac)。

## pin 的版本

版本是联动的，都写在 `versions.env`：

| 项 | 值 |
| --- | --- |
| llama.cpp | `9575389609d6f8437de0b205561a4824d217c409` |
| ToshLLM | `8af5d379d720560c1f0a6d7e38468b5b78a673db`（v0.87.13） |
| 补丁 | 119 个，系列 SHA-256 `0d81290b…d4038` |

补丁是针对这个 llama.cpp commit 验证的，换 commit 要重新适配。构建脚本每次都会核对
补丁数量和系列哈希，对不上直接停下，不会拿错的补丁去编译。

升级到更新的 ToshLLM：

```bash
cd third_party/toshllm && git fetch && git checkout <新版本>
cd ../.. && git add third_party/toshllm
# 再更新 versions.env 里的 TOSHLLM_COMMIT、PATCH_COUNT、PATCH_SERIES_SHA256
./scripts/build.sh --clean
```

## 关于显卡和分辨率

补丁同时支持 RDNA（SIMD 组宽 32）和 GCN / Vega（组宽 64），启动日志会打印探测结果。
Intel 核显不需要这套补丁，官方 Metal 后端在统一内存架构上本来就是对的。

macOS 的 GPU watchdog 有个硬限制：单次 command buffer 执行时间超标就掐掉，输出直接
损坏。实测在 5500M 上，图像长边 2000 以内安全，2400 开始出现超时，2800 以上必坏。
纯文本推理不受影响，用视觉模型时要控制输入分辨率。

## 授权

本仓库自己的脚本是 MIT（见 `LICENSE`）。

补丁来自 [engeldlgado/toshllm](https://github.com/engeldlgado/toshllm)，通过 git
submodule 引用，**不在本仓库内分发**。它们是 GPL-3.0-or-later，版权归 Engelbert
Delgado 所有，声明见 `third_party/toshllm/patches/COPYRIGHT`。因此用这些补丁编译出来的
llama.cpp 二进制属于 GPL-3.0-or-later 的衍生作品，再分发时要遵守 GPL 的要求。

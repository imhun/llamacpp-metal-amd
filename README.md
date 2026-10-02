# llamacpp-metal-amd

在 macOS 上为 **AMD / Intel 独立显卡**构建 Metal 加速的 llama.cpp，编译一次可以装到
全局给多个项目共用。

## 为什么需要它

官方 llama.cpp 的 Metal 后端在独显上跑不出正确结果。

前置事实：Homebrew 版 llama.cpp 在 Intel Mac 上**没有编译 Metal**（`--list-devices`
只有 `BLAS: Accelerate`），因为 Homebrew 自 2026 年 9 月起不再支持 Intel x86_64 macOS，
不再提供 bottle。所以下面几个后端都得自己编译。

### Metal（官方构建，`-DGGML_METAL=ON`）

设备能被正确识别：

```
Available devices:
  MTL0: AMD Radeon Pro 5500M (8176 MiB, 8175 MiB free)
  BLAS: Accelerate (0 MiB, 0 MiB free)
```

速度也确实起来了（视觉编码 159s → 39.4s），但**输出完全损坏**：

```
E ggml_metal_synchronize: error: command buffer 0 failed with status 5
E error: Caused GPU Timeout Error (00000002:kIOAccelCommandBufferCallbackErrorTimeout)
...
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@...
```

根因（对应 [issue #15228](https://github.com/ggml-org/llama.cpp/issues/15228)）：
Metal 后端用 `newBufferWithBytesNoCopy(... options:MTLResourceStorageModeShared ...)`
把权重映射成共享内存（`ggml/src/ggml-metal/ggml-metal-device.m:2214`）。在独显上，
这意味着 GPU 每次推理都要通过 PCIe 从系统内存重新读权重，带宽被卡死，最终触发 GPU
超时。该 issue 已被官方关闭为 **not planned**。

### Vulkan（MoltenVK）

依赖 `molten-vk` + `vulkan-loader` + `shaderc`(glslc) + `spirv-headers` + `glslang`，
设备同样能识别：

```
Vulkan0: AMD Radeon Pro 5500M (8176 MiB)
Vulkan1: Intel(R) UHD Graphics 630 (65536 MiB)
```

输出乱码其实是**两个独立的问题**叠在一起。

#### 一、不指定设备时，这个构建会同时用 Metal 和 Vulkan

二进制里 Metal 和 Vulkan 两个后端都在，`-ngl 99` 不带 `-dev` 时调度器会把 25 层拆开：

```
I load_tensors:  MTL0_Mapped model buffer size =   159.35 MiB
I load_tensors:      Vulkan0 model buffer size =   334.98 MiB
```

跨后端跑文本推理就是整屏 `@@@@`。**只要显式锁一个设备，文本部分完全正确**：

```bash
llama-cli -m models/OvisOCR2-Q4_K_M.gguf -ngl 99 -dev Vulkan0 -p "The capital of France is"
# → The capital of France is / Paris   （正确）
```

`-dev Vulkan1`（Intel 核显）更糟，连 compute pipeline 都建不起来
（`ErrorInitializationFailed`），视觉编码放上去直接 `device lost` 崩溃。

#### 二、视觉编码器在 Vulkan 上确实算错，和文本路径无关

锁定 `-dev Vulkan0 -mmdev Vulkan0` 之后语言模型正常，但把 mmproj 交给 GPU 就退化：

| 视觉编码执行位置 | 整页输出 |
| --- | --- |
| Vulkan0（默认） | `1 1 1 1…` / `## 1` / `The quick brown fox…` 死循环 |
| 补丁版 Metal | 正确 |
| CPU（`--no-mmproj-offload`） | 正确，且与 Metal 参考**逐字节一致** |

用 `llama-mtmd-debug -p encode` 把两侧每个视觉张量 dump 出来比对（每个张量块末尾带
`sum =` 校验值，可以全量对齐，不受 `...` 省略影响），误差随图像边长单调放大：

| 图像边长 n | `Vcur-1`（第 1 个注意力块的 V 投影）相对差 | 投影器输出相对差 |
| --- | --- | --- |
| 256 | 0.76% | 1.74% |
| 512 | 1.19% | 0.87% |
| 1024 | 4.60% | 0.23% |
| 1600 | **544%** | **75%** |

小图那点误差还是 f16 累加的正常抖动，1024 起就超出正常范围，1600 则整段编码器从第一个
注意力块开始就废了。真实页面是 9440 个图像 token（约合 n≈1552），必然命中。

已经排除的：

- **不是单个算子的数值错**：`test-backend-ops -b Vulkan0` 全部 13688 项通过。
- **不是 CLIP 算子回退告警**：打补丁的 Metal 后端有完全相同的列表（`SOFT_MAX` / `CONT` /
  `PERMUTE` / `ROPE` / `VIEW` / `MUL_MAT` / `MUL` / `ADD`，只有尺寸随分辨率变化），输出却是
  正确的。它只说明这些算子回退到 CPU、性能打折。
- **不是 pinned memory 告警**：`Failed to allocate pinned memory` 之后
  `ggml-vulkan.cpp` 会回退到 CPU buffer，纯文本推理也报这条，结果照样正确。
- **不是竞态**：贪心解码（`--temp 0 --seed 42`）下坏输出稳定复现，两次逐字节相同。
- **开关都无效**：`GGML_VK_DISABLE_F16` / `DISABLE_GRAPH_OPTIMIZE` / `DISABLE_FUSION` /
  `PREFER_HOST_MEMORY` / `DISABLE_ASYNC` / `SERIALIZE_SUBMISSIONS` / `DISABLE_MMVQ` /
  `FORCE_MMVQ` / `DISABLE_INTEGER_DOT_PRODUCT` / `MAX_NODES_PER_SUBMIT=1` 逐个试过，全是乱码。

所以根因（MoltenVK/AMD 驱动侧，还是 ggml-vulkan 大尺寸 kernel 的数值问题）仍未定位，
只能确认症状与 [issue #20104](https://github.com/ggml-org/llama.cpp/issues/20104)
（Vulkan on Intel Macs produce gibberish）一致，该 issue 被标记为 #20029 的重复项。

#### 能用的 Vulkan 配置：文本上 GPU，视觉编码回退 CPU

```bash
export VK_ICD_FILENAMES=/usr/local/etc/vulkan/icd.d/MoltenVK_icd.json
llama-mtmd-cli -m models/OvisOCR2-Q4_K_M.gguf --mmproj models/mmproj-F16.gguf \
  --image page.png -p "…" -ngl 99 -dev Vulkan0 --no-mmproj-offload
```

1240×1754 的整页实测 45 s（同页补丁 Metal 15 s）。比全 CPU 快，可以当作独立于
Metal 补丁的第二条路。

### 打上 ToshLLM 补丁之后

[ToshLLM](https://github.com/engeldlgado/toshllm) 的补丁系列重建了整个 Metal 后端。
同一个模型、同一台机器（i9-9880H + Radeon Pro 5500M 8GB），视觉编码阶段：

| 后端 | 视觉编码 | 总耗时 | 输出 |
| --- | --- | --- | --- |
| CPU（Accelerate） | 159 s | — | 正确但慢 |
| Metal（官方构建） | 39.4 s | 崩溃 | `@@@@@@` + GPU Timeout |
| Vulkan（MoltenVK，视觉也上 GPU） | ~27 s | 41 s | 视觉编码算错，输出全为 `1` |
| **Vulkan（MoltenVK，视觉回退 CPU）** | — | **45 s** | **正确，与 Metal 参考逐字节一致** |
| **Metal（打上补丁）** | **6.2 s** | **15 s** | **完全正确** |

稳定性：连续 3 次均为 12 s、0 乱码、视觉编码 5.63 s。

## 用法

```bash
git clone --recurse-submodules https://github.com/imhun/llamacpp-metal-amd.git
cd llamacpp-metal-amd
./scripts/build.sh
```

忘记 `--recurse-submodules` 也没关系，脚本会自己补拉补丁。

首次编译 5-15 分钟，之后重复执行会跳过已完成的部分。产物：

```
tmp/llama.cpp/build-metal/bin/llama-mtmd-cli
```

```bash
./scripts/build.sh --rebuild      # 重编（保留源码和补丁）
./scripts/build.sh --clean        # 从 clone 开始重来
./scripts/build.sh --patches-only # 只准备源码并打完补丁
./scripts/build.sh -j 8           # 限制并行度
./scripts/build.sh --help
```

## 装到全局，多个项目共用

编译出来的二进制是自包含的（只依赖系统框架，Metal 库已内嵌），可以直接拷到别处运行。
装到全局之后，其他项目不用再各自编译一份：

```bash
./scripts/install.sh              # 装到 /usr/local
./scripts/install.sh --prefix ~/.local
./scripts/install.sh --dry-run    # 只看会做什么
./scripts/install.sh --uninstall
```

装完得到一个命令 `llama-mtmd-cli-amd`，以及一份记录版本的元数据：

```
/usr/local/bin/llama-mtmd-cli-amd -> /usr/local/lib/llamacpp-metal-amd/llama-mtmd-cli
/usr/local/lib/llamacpp-metal-amd/BUILD-INFO
```

`BUILD-INFO` 里记着 llama.cpp commit、ToshLLM commit、补丁数量与系列哈希、构建时间，
排查「装的到底是哪一版」时用得上。

**名字故意不叫 `llama-mtmd-cli`**：brew 装的官方版就叫这个名字，覆盖它会破坏 brew
自己的记录，而且那个版本在独显上输出是坏的。安装脚本还会拒绝没有 SIMD 探测代码的
二进制，避免把官方构建装进 PATH。

用起来就是标准的 llama.cpp 命令行：

```bash
llama-mtmd-cli-amd -m 模型.gguf --mmproj mmproj.gguf --image 页面.png -p "提取图中所有文字"
```

## 自检

```bash
./scripts/verify.sh                          # 查默认构建
./scripts/verify.sh /path/to/llama-mtmd-cli  # 查指定二进制
./scripts/verify.sh --model m.gguf --mmproj p.gguf   # 顺便跑一次真实推理
```

不需要模型，几秒钟出结果。判据是启动日志里的两行：

```
ggml_metal: device 0: AMD Radeon Pro 5500M (peer group 0, not bridged)
            probed SIMD-group width = 32 (32 = Apple/AMD RDNA, 64 = AMD GCN/Vega)
```

`probed SIMD-group width` 是补丁引入的，官方构建的二进制里连这个字符串都没有
（`grep -a "probed SIMD-group" llama-mtmd-cli` 返回空）。所以这一行在不在，就是补丁
有没有生效的硬判据——光看「Metal 设备已识别」不够，官方版也会识别设备，只是算不对。

补丁同时支持 RDNA（组宽 32）和 GCN / Vega（组宽 64）。Intel 核显不需要这套补丁，
官方 Metal 后端在统一内存架构上本来就是对的。

## 分辨率上限

macOS 的 GPU watchdog 有条硬限制：单次 command buffer 执行时间超标就掐掉，输出直接
损坏。实测在 5500M 上：

| 图像长边 | 视觉编码 | 结果 |
| --- | --- | --- |
| 1600 | 3.1 s | 正常 |
| 2000 | 7.6 s | 正常 |
| 2400 | 18.2 s | 出现 GPU timeout，这次侥幸正确 |
| 2800+ | 18.4 s | 输出损坏 |
| 3508 | 18.6 s | 输出损坏 |

这个限制绕不过去：`sysctl debug.iogpu.*` 在这台机器上不存在，`nvram boot-args` 是空的，
`-ub 128` 把 batch 调小也没用。纯文本推理不受影响，用视觉模型时要控制输入分辨率。

纯 CPU 回退时视觉编码耗时与分辨率成正比，缩图能线性省时间：

| 预处理长边 | 视觉编码耗时 | 相对原图 |
| --- | --- | --- |
| 1754（原图） | 159 s | 1× |
| 1000 | 26 s | 6× 加速 |

## pin 的版本

版本是联动的，都写在 `versions.env`：

| 项 | 值 |
| --- | --- |
| llama.cpp | `9575389609d6f8437de0b205561a4824d217c409` |
| ToshLLM | `8af5d379d720560c1f0a6d7e38468b5b78a673db`（v0.87.13） |
| 补丁 | 119 个，系列 SHA-256 `0d81290b…d4038` |

补丁是针对这个 llama.cpp commit 验证的，换 commit 要重新适配。构建脚本每次都会核对
补丁数量和系列哈希，对不上直接停下，不会拿错的补丁去编译。

补丁体系本身很大：`patches/llama/` 下 119 个文件，光 `0001` 和 `0002` 两个就有 15788 行，
等于把整个 Metal 后端重写了一遍。

升级到更新的 ToshLLM：

```bash
cd third_party/toshllm && git fetch && git checkout <新版本>
cd ../.. && git add third_party/toshllm
# 再更新 versions.env 里的 TOSHLLM_COMMIT、PATCH_COUNT、PATCH_SERIES_SHA256
./scripts/build.sh --clean
```

> 另有一个 issue #15228 的早期 gist（`ggml-metal-optimized-4.m`），针对 2025-08 的
> `ggml-metal.m` 结构，在当前代码上已经无法直接套用。

## 参考

- ToshLLM：https://github.com/engeldlgado/toshllm
- Metal / 独显问题：https://github.com/ggml-org/llama.cpp/issues/15228
- Vulkan 输出乱码：https://github.com/ggml-org/llama.cpp/issues/20104
- 完整实测记录（OvisOCR2 文档解析场景）：https://github.com/imhun/ovisocr2-mac

## 授权

本仓库自己的脚本是 MIT（见 `LICENSE`）。

补丁来自 [engeldlgado/toshllm](https://github.com/engeldlgado/toshllm)，通过 git
submodule 引用，**不在本仓库内分发**。它们是 GPL-3.0-or-later，版权归 Engelbert
Delgado 所有，声明见 `third_party/toshllm/patches/COPYRIGHT`。因此用这些补丁编译出来的
llama.cpp 二进制属于 GPL-3.0-or-later 的衍生作品，再分发时要遵守 GPL 的要求。

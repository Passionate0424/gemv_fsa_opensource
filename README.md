# GEMV-FSA：支持 FlashAttention 的推理加速 SoC

面向边缘端 LLM 推理的双模式脉动阵列加速器：同一套 32-PE 阵列，用输出驻留（OS）数据流加速
线性层 GEMV，用权重驻留（WS）+ FlashAttention-2 在线 softmax 加速注意力。

本仓库是 **2026 年全国大学生集成电路创新创业大赛（集创赛）龙芯中科杯总决赛**参赛作品
《支持 FlashAttention 的推理加速 SoC 设计》的前端设计部分开源发布。

| | |
|---|---|
| 赛事 | 2026 年全国大学生集成电路创新创业大赛（集创赛） |
| 赛题 | 龙芯中科杯 |
| 阶段 | 总决赛 |
| 队伍编号 | **CICC1001054** |
| 作品名称 | 支持 FlashAttention 的推理加速 SoC 设计 |

## 项目背景

LLaMA2 这类 decoder-only Transformer 在推理时有两类形态截然不同、但都逃不掉的矩阵运算：
自回归解码阶段的 GEMV（矩阵-向量乘），以及 attention 阶段的 FlashAttention-2（分块矩阵乘 +
在线 softmax）。二者的数据复用模式完全相反——GEMV 权重体量大且层层不同、只流过一次即弃，
attention 则需要 Q 驻留、K/V 流入并与 CMP 反复交互。若各自单独做一套阵列，在资源有限的边缘
FPGA 上会造成浪费。

竞赛平台龙芯 OpenLA500 是**单核标量、且无硬件浮点单元**的嵌入式处理器（LoongArch32，
33 MHz）：乘加只能串行执行，非线性算子（RMSNorm、RoPE、SiLU）全靠软浮点模拟，单 token 解码
需上亿周期（约 3.3 秒）。本项目从两个方向补齐算力短板：

1. **双模式脉动阵列加速 IP** —— 同一套 32-PE 阵列通过可重构分组（4×8 / 2×16 / 1×32）
   同时覆盖 GEMV 与 FlashAttention 注意力，把注意力访存复杂度由 $O(N^2)$ 降至 $O(N)$；
2. **CPU 硬件浮点扩展** —— 为原本无 FPU 的 CPU 挂上 CVFPU 协处理器，消除非线性算子的
   软浮点模拟开销。

二者经 AXI 互联组成完整的推理加速 SoC，在 FPGA 上跑通 llama2.c + stories260K 的端到端
自回归推理。

| 项目 | 内容 |
|------|------|
| 目标平台 | Xilinx Artix-7 `xc7a200tfbg676-1` |
| 工作频率 | 加速器 `sys_clk` 50 MHz / CPU `cpu_clk` 33 MHz |
| 核心架构 | 32-PE 一维脉动阵列，可重构为 4组×8 / 2组×16 / 1组×32 |
| 数据格式 | IEEE 754 FP32 |
| 接口 | AXI4 Slave（CSR，20 个寄存器） + AXI4 Master（DMA） |
| 目标模型 | llama2.c / stories260K（5 层，dim=64，8 头，vocab=512，GQA） |
| SoC 平台 | 龙芯 OpenLA500（LoongArch32）+ CVFPU + 本加速器，AXI 总线加宽至 64 位 |

## 性能与精度

端到端口径为完整 SoC 逐 token 推理耗时（覆盖 GEMV、FSA 与 CPU 调度全流程），
在 stories260K、256-token 序列上实测：

| 配置 | cycles/token | 相对纯软基线 |
|------|-------------:|-------------|
| 纯 CPU 软浮点基线 | 107,535,372 | 1× |
| + 双模式加速器（含 DMA/流水/uncached/outstanding 等优化） | 3,899,347 | **27.6×** |
| + CPU 侧 FPU、GQA、SiLU 融合、跨调用预取、64 位总线 | 511,431 | **210×** |

精度方面：

- **exp2 单算子**：8 段分段线性（PWL）近似，系数取 **Chebyshev 节点**拟合（RTL 内即为该组
  系数，见 [FPAccUnit_pipe.sv](rtl/fsa/FPAccUnit_pipe.sv)），全量扫描 32000 个 fp32 负值输入
  对照 fp64，MRE 0.0286%、最大相对误差 0.048%——已贴近同段数下 minimax 下界 0.047%。
- **端到端 FlashAttention**：以 fp64 标准 softmax 为 golden，MAE 1.17×10⁻³、MRE 0.0985%。
- **GEMV**：以 bit-exact 为目标，绝大多数输出与 fp64 参考完全一致，约 0.05% 出现 ULP 级偏差
  （FP32 并行累加顺序与串行参考不同所致）。
- **生成质量**：硬件版与纯 CPU 版在 256-token 序列上 greedy 解码**逐 token 一致**，
  next-token logit 差异仅 10⁻³ 量级，不改变 argmax。

## 验证状态

UVM 1.2 + 约束随机 + 覆盖率驱动，仿真工具 Synopsys VCS。顶层以加速器为黑盒经 AXI 驱动、
用 DPI-C 黄金模型逐输出比对；单元级对 PE、exp2、CMP、accumulator 做 ULP 级比对。

| 类别 | 结果 |
|------|------|
| UVM 测试点 | 约 590 个，功能类全 PASS（18 个 test，覆盖 directed/random/stress/错误注入/中途复位/容量边界六类） |
| 代码覆盖率 | Line 91.08% / Condition 86.57% / Toggle 95.35% / FSM 90.10% / Branch 86.18%（16 test 合并，原始值） |
| 功能覆盖率 | 95.19% |
| Directed TB | FSA E2E 三种分组模式各跑一轮（含 GQA 用例与 bit-accurate golden 对照）、GEMV tiling 定向回归 |

FSM 覆盖率距 95% 目标差约 4.9%，未覆盖的是 1~2 拍极短状态到 `S_IDLE` 的复位转移对，属结构性
不可测转移，已列入 waiver（详见 [覆盖率 waiver](uvm/docs/coverage_waivers.md)）。

## 综合成果

- **逻辑综合（DC）**：Nangate45 开源工艺库（typical，1.1 V），时钟约束 5.0 ns（200 MHz），
  OS/FSA 两种模式均时序收敛，关键路径 4.86 ns、Setup WNS/TNS 均为 0。
- **FPGA 布线后资源**（`xc7a200t`）：Slice LUTs 94,037（70.28%）、Slice Registers 49,535
  （18.51%）、DSP48E1 85 个（11.49%）、RAMB18E1 118 个（16.16%）。DSP 占用低印证了
  一维阵列换取可控资源占用的设计权衡。
- **FPGA 时序**：`sys_clk`（50 MHz）布线后 WNS ≈ +0.50 ns、TNS = 0。

> 说明：ASIC 后端物理实现（P&R、签核）不在本仓库开源范围内。

## 目录结构

```
gemv_fsa/
├── rtl/                        # 加速器 RTL 源代码
│   ├── CB_top_v2.sv            # 顶层模块
│   ├── cb_controll_v2.sv       # 控制器（CSR + GEMV/FSA 双模式 DMA 调度 + 预取 FSM）
│   ├── mac_top_v2.sv           # MAC 引擎顶层（PE 阵列 + FSA 数据通路）
│   ├── PE_core_v2.sv           # 32-PE 阵列（OS/WS 双模式）
│   ├── axi_dma_controller.sv   # AXI4 DMA 控制器（多笔 outstanding）
│   ├── PE/                     # PE 单元（Chisel 生成后手工重定时）
│   ├── fsa/                    # FlashAttention 专用模块
│   │   ├── fsa_ctrl_fsm.sv     # FSA 控制 FSM
│   │   ├── fsa_transposer.sv   # K 矩阵转置引擎
│   │   ├── fsa_accumulator.sv  # 在线 softmax 累加器
│   │   ├── FPAccUnit_pipe.sv   # 含 exp2 8 段 PWL（Chebyshev 系数）
│   │   └── silu_ctrl_fsm.sv    # SiLU 激活融合控制
│   └── fsa_gen/chisel_fsa_fp32/ # Chisel 生成的 FP 运算单元（CMP/比较器等）
│
├── tb/                          # Directed Testbench
│   ├── tb_fsa_e2e.sv            # FSA 端到端验证（含 GQA、bit-accurate golden）
│   ├── tb_CB_top_v2_gemv.sv     # GEMV tiling 回归
│   ├── dpi/                     # DPI-C 黄金模型（fp64 softmax + bit-accurate 转录）
│   ├── golden/                  # Python 侧 golden 生成
│   └── board_data/              # 板上抓取数据（用于回归对比）
│
├── uvm/                         # UVM 1.2 验证环境
│   ├── docs/                    # 验证报告、验证计划、环境架构、覆盖率 waiver
│   ├── agents/                  # AXI Slave Agent / DDR backdoor mem_model
│   ├── ral/                     # UVM RAL 寄存器模型
│   └── env/ sequences/ tests/ interfaces/ dpi/ top/
│
├── soc/                         # SoC 集成（集创赛龙芯杯平台）
│   ├── rtl/ip/open-la500/       # 龙芯 OpenLA500 CPU（含 cvfpu 浮点扩展，Mulan PSL v2）
│   ├── rtl/ip/gemv_accel/       # 加速器 RTL 的同步副本（见下方说明，非独立实现）
│   ├── rtl/ip/Bus_interconnects/ # AXI 互联（64 位 crossbar wrapper + SRAM 桥）
│   └── sdk/software/apps/       # llama2.c 推理固件（runc 系列）+ bsp
│
├── third_party/                 # vendored 第三方开源 RTL（pulp-platform axi / common_verification）
├── tools/                       # TB 用到的 C 侧 golden/eval 小工具
├── scripts/                     # filelist、Vivado 综合/bitgen tcl、工具链构建脚本
├── docs/spec/                   # 设计规格（FSA 编程手册、各模块设计 plan）
├── docs/summary/                # 早期评估记录（见下方说明）
├── LICENSE                      # Apache-2.0
├── Makefile.vcs                 # VCS 本地编译/运行入口
└── README.md
```

`soc/rtl/ip/gemv_accel/` 与 `rtl/` 下的加速器源码内容相同——由 `.githooks/pre-commit` 在提交时
自动同步（安装见 `scripts/install_git_hooks.ps1`），不是两套独立实现；改动只需在 `rtl/` 下做。

> `docs/summary/` 下的两份评估报告是**早期版本的记录**：写于 exp2 换用 Chebyshev 系数、
> CPU 侧补 FPU、64 位总线等优化之前，其中的加速比（15.9×）与 exp2 精度（0.0626%）均已被
> 上文表格中的最新数据取代，保留仅作迭代过程参考。

## 快速开始

### 环境要求
- Synopsys VCS（O-2018.09+ 或 R-2020.12+）+ UVM 1.2（VCS 内置）
- 本仓库不含交叉编译工具链本体：如需构建 SoC 软件，先用
  `scripts/build_gcc_ilp32f_multilib.sh` / `scripts/build_picolibc_hwfp.sh` 在本地构建，
  产物放在 `soc/sdk/toolchains/` 下（已 gitignore）。

### Directed TB

```bash
# GEMV tiling 回归
make -f Makefile.vcs TOP=tb_CB_top_v2_gemv FILELIST=./scripts/cb_top_v2_gemv_filelist.f run_gemv_all

# FSA 端到端（依次跑 4×8 / 2×16 / 1×32 三种分组模式）
make -f Makefile.vcs TOP=tb_fsa_e2e FILELIST=./scripts/fsa_e2e_filelist.f run_fsa_all

# FSA 位级 golden 回归（对照逐条转录 RTL 的 bit-accurate golden，FAIL 必须为 0）
make -f Makefile.vcs TOP=tb_fsa_e2e FILELIST=./scripts/fsa_e2e_filelist.f run_fsa_bitacc
```

### UVM

```bash
# 单个 test
make -f Makefile.vcs run_uvm UVM_TEST=gemv_sanity_test

# 带代码覆盖率（产物在 cov_report/）
make -f Makefile.vcs run_uvm_cov UVM_TEST=fsa_soak_test
```

日常回归（11 test）：`csr_access_test` `gemv_sanity_test` `gemv_regression_test`
`silu_sanity_test` `silu_bypass_test` `pf_sanity_test` `pf_bypass_test` `fsa_sanity_test`
`fsa_regression_test` `fsa_gqa_test` `dual_mode_stress_test`

全量回归在上述基础上追加：`gemv_random_test` `gemv_random_bigrow_test`
`silu_regression_test` `silu_random_test` `pf_regression_test` `pf_random_test`
`fsa_random_test` `fsa_gqa_random_test` `error_injection_test` `mid_op_reset_test`
`precise_fsm_reset_test` `special_fp_test` `fsa_residue_impact_test` `fsa_soak_test`
`fsa_hd64_test` `fsa_hd48_test` `perf_limit_test`

逐个跑 `make -f Makefile.vcs run_uvm UVM_TEST=<name>` 即可。

### SoC / 板上 demo

`soc/README.md`、`soc/build_sw.sh` 是 llama2.c 固件的构建入口；FPGA bitstream 通过
`scripts/run_vivado_synth.tcl` + `scripts/run_soc_bitgen*.tcl`（Vivado batch 模式本地跑）生成。

## 关键设计文档

- [FSA 编程手册](docs/spec/fsa_programmer_guide.md) — CSR 寄存器、DDR 布局、配置流程
- [UVM 验证报告](uvm/docs/verification_report.md) — 完整验证结果与覆盖率
- [UVM 验证计划](uvm/docs/verification_plan.md) / [环境架构](uvm/docs/uvm_architecture.md)
- [控制 FSM 规格](docs/spec/control_fsm_spec.md)、[PE OS/WS 重构方案](docs/spec/pe_ws_os_reconfig_plan.md)

## 参考

- Dao et al., *FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness*, NeurIPS 2022.
- Dao, *FlashAttention-2: Faster Attention with Better Parallelism and Work Partitioning*, 2023.
- Lin et al., *SystolicAttention: Fusing FlashAttention within a Single Systolic Array*, 2025.
  （FSA 模式的脉动阵列映射思路参考自该工作；GEMV 模式的 OS 数据流为本项目独立设计）

## 许可证

本仓库以 [Apache-2.0](LICENSE) 许可发布。`third_party/`（pulp-platform axi /
common_verification）沿用其原有的 Solderpad Hardware License v0.51（基于 Apache-2.0，条款兼容），
`soc/rtl/ip/open-la500/` 沿用其原有的木兰宽松许可证第 2 版（Mulan PSL v2），
各自的 LICENSE 文件均已随目录一同保留。

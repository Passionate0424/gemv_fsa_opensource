# GEMV-FSA 硬件加速器

双模式矩阵计算加速器，支持 GEMV（矩阵-向量乘法）和 FlashAttention-2（FSA），面向 LLaMA2 类模型的边缘推理加速。

## 项目背景

LLaMA2 这类 decoder-only Transformer 在推理时有两类形态截然不同、但都逃不掉的矩阵运算：
逐 token 生成阶段的 GEMV（矩阵-向量乘），以及 attention 阶段的 FlashAttention-2（分块矩阵乘 + 在线
softmax）。二者的数据流、复用模式完全不同，若各自单独做一套 PE 阵列，会在资源有限的边缘 FPGA 上
造成浪费。本项目的核心思路是让同一套 32-PE 脉动阵列通过运行时重构（OS/WS 双模式、4×8 / 2×16 / 1×32
可配置分组）同时覆盖这两种算子，用一套硬件伺候一次完整的 LLaMA2 推理。

这个仓库开源的是**前端设计部分**：加速器 RTL、Directed TB、UVM 验证环境，以及把加速器集成进
LoongSon 杯 SoC 平台、跑通 LLaMA2 板上 demo 所需的 SoC 集成代码。**不包含** ASIC backend/PD
（后端物理实现、TSMC 28nm PDK 相关内容）——那部分涉及 foundry 保密协议，不能公开。

| 项目 | 内容 |
|------|------|
| 目标平台 | Xilinx xc7a200t FPGA |
| 工作频率 | 50MHz |
| 核心架构 | 32 PE 脉动阵列，4组×8 / 2组×16 / 1组×32 可配置 |
| 数据格式 | IEEE 754 FP32 |
| 接口 | AXI4 Slave（CSR） + AXI4 Master（DMA） |
| 验证 | UVM 1.2 + 88 FSA directed + 14 GEMV directed + 250 random + soak |
| 板上验证 | LLaMA2-7B 256 token 推理，15.9x 加速 |
| SoC 平台 | LoongSon 杯 open-la500（LoongArch32R）CPU + 本加速器 |

## 目录结构

```
gemv_fsa/
├── rtl/                        # 加速器 RTL 源代码
│   ├── CB_top_v2.sv            # 顶层模块
│   ├── cb_controll_v2.sv       # 控制器（CSR + GEMV/FSA双模式DMA调度）
│   ├── mac_top_v2.sv           # MAC引擎顶层（PE阵列+FSA数据通路）
│   ├── PE_core_v2.sv           # 32-PE阵列（OS/WS双模式）
│   ├── axi_dma_controller.sv   # AXI4 DMA控制器
│   ├── PE/                     # PE单元（Chisel生成）
│   ├── fsa/                    # FlashAttention专用模块（控制FSM、转置引擎、在线softmax累加器等）
│   └── fsa_gen/chisel_fsa_fp32/ # Chisel生成的FP运算单元（FMA/CMP/Div等）
│
├── tb/                          # Directed Testbench
│   ├── tb_fsa_e2e.sv            # FSA端到端验证（88 cases）
│   ├── tb_CB_top_v2_gemv.sv     # GEMV回归验证（14 cases）
│   ├── dpi/                     # DPI-C golden model（FP64 softmax）
│   ├── golden/                  # Python侧golden向量
│   └── board_data/              # 板上抓取数据（用于回归对比）
│
├── uvm/                         # UVM验证环境
│   ├── docs/                    # 验证文档（verification_report/plan、架构、覆盖率waiver等）
│   ├── agents/                  # AXI Slave Agent / DDR backdoor mem_model
│   ├── ral/                     # UVM RAL寄存器模型（18 CSR）
│   ├── env/ sequences/ tests/ interfaces/ dpi/ top/
│
├── soc/                         # SoC集成（LoongSon杯平台）
│   ├── rtl/ip/open-la500/       # open-la500 CPU（Mulan PSL v2 许可）
│   ├── rtl/ip/gemv_accel/       # 加速器RTL的同步副本（见下方说明，不是独立实现）
│   ├── rtl/ip/Bus_interconnects/ # AXI 总线互联（含third_party AXI crossbar的wrapper）
│   └── sdk/software/apps/       # LLaMA2 runc 系列固件源码 + bsp
│
├── third_party/                 # vendored 第三方开源RTL（pulp-platform axi/common_verification，Solderpad v0.51）
│
├── tools/                       # TB用到的C侧golden/eval小工具
│
├── scripts/                     # 编译/综合/评估脚本（filelist、Vivado/Vitis tcl、工具链构建脚本）
│
├── docs/
│   ├── spec/                    # 设计规格文档（FSA编程手册、各模块设计plan等）
│   └── summary/                 # 评估结果（FPGA E2E评估、精度评估）
│
├── LICENSE                      # Apache-2.0
├── Makefile.vcs                 # VCS本地编译/运行入口
└── README.md                    # 本文件
```

`soc/rtl/ip/gemv_accel/` 与 `rtl/` 下的加速器源码内容相同——由 `.githooks/pre-commit` 在提交时
自动同步（见 `scripts/install_git_hooks.ps1`），不是两套独立实现；改动只需要在 `rtl/` 下做。

## 快速开始

### 环境要求
- Synopsys VCS（O-2018.09+ 或 R-2020.12+）+ UVM 1.2（VCS内置）
- 本仓库不含交叉编译工具链本体：如需构建 SoC 软件，先用
  `scripts/build_gcc_ilp32f_multilib.sh` / `scripts/build_picolibc_hwfp.sh` 在本地构建，
  产物放在 `soc/sdk/toolchains/` 下（已 gitignore）。

### Directed TB（本地直连，不依赖任何远程脚本）

```bash
# GEMV 14 cases
make -f Makefile.vcs TOP=tb_CB_top_v2_gemv FILELIST=./scripts/cb_top_v2_gemv_filelist.f run_gemv_all

# FSA 88 cases
make -f Makefile.vcs TOP=tb_fsa_e2e FILELIST=./scripts/fsa_e2e_filelist.f run_fsa_all
```

### UVM

```bash
# 单个test
make -f Makefile.vcs run_uvm UVM_TEST=gemv_sanity_test

# 带覆盖率
make -f Makefile.vcs run_uvm_cov UVM_TEST=fsa_soak_test
```

日常回归（11 test）：`csr_access_test` `gemv_sanity_test` `gemv_regression_test`
`silu_sanity_test` `silu_bypass_test` `pf_sanity_test` `pf_bypass_test` `fsa_sanity_test`
`fsa_regression_test` `fsa_gqa_test` `dual_mode_stress_test`

全量回归（27 test，与 `uvm/docs/verification_report.md` 口径一致）在上述基础上追加：
`gemv_random_test` `gemv_random_bigrow_test` `silu_regression_test` `silu_random_test`
`pf_regression_test` `pf_random_test` `fsa_random_test` `fsa_gqa_random_test`
`error_injection_test` `mid_op_reset_test` `precise_fsm_reset_test` `special_fp_test`
`fsa_residue_impact_test` `fsa_soak_test` `fsa_hd64_test` `fsa_hd48_test`

逐个跑 `make -f Makefile.vcs run_uvm UVM_TEST=<name>` 即可；覆盖率回归把 `run_uvm` 换成
`run_uvm_cov`，产物在 `cov_report/`（`urg` 文本报告）。

### SoC / 板上 demo

`soc/README.md`、`soc/build_sw.sh` 是 LLaMA2 固件的构建入口；FPGA bitstream 通过
`scripts/run_vivado_synth.tcl` + `scripts/run_soc_bitgen*.tcl`（Vivado batch 模式本地跑）生成。

## 验证状态

| 类别 | 结果 |
|------|------|
| Directed TB | GEMV 14 + FSA 88 = 102 cases PASS |
| UVM Regression | 27 tests，~530测试点全PASS |
| 覆盖率 | Line 88.7%, Cond 82.7%, Toggle 91.3%, FSM 92.5%, Branch 85.7% |
| 功能覆盖率 | 95.19% |
| 板上验证 | LLaMA2 256 token推理正确 |

## 关键设计文档

- [FSA编程手册](docs/spec/fsa_programmer_guide.md) — CSR寄存器、DDR布局、配置流程
- [UVM验证报告](uvm/docs/verification_report.md) — 完整验证结果
- [FPGA端到端评估](docs/summary/fpga_e2e_evaluation.md)
- [精度评估](docs/summary/accuracy_evaluation.md)

## 许可证

本仓库以 [Apache-2.0](LICENSE) 许可发布。`third_party/`（pulp-platform axi / common_verification）
沿用其原有的 Solderpad Hardware License v0.51（基于 Apache-2.0，条款兼容），`soc/rtl/ip/open-la500/`
沿用其原有的木兰宽松许可证第2版（Mulan PSL v2），各自的 LICENSE 文件均已随目录一同保留。

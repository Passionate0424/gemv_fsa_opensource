# FSA FlashAttention 集成方案

> 创建日期：2026/05/14
> 最后更新：2026/05/18
> 状态：**全部完成**（端到端10/10 PASS + OS 14-case回归PASS）
> 软件编程接口：见 `docs/spec/fsa_programmer_guide.md`

---

## 1. 架构概述

CB_top_v2是一个双模式硬件加速器（GEMV + FlashAttention），基于32-PE 1D脉动阵列：

```
CB_top_v2
├── cb_controll_v2（CSR + GEMV/FSA双模式DMA调度）
├── mac_top_v2
│     ├── PE_core_v2（32 PE_retimed，4组×8，OS/WS双模式）
│     ├── Input SRAM（32 bank × 32b × 64深）
│     ├── Vector SRAM（4 bank × 32b × 16深）
│     ├── Output SRAM（4 bank × 32b × 8深）
│     ├── fsa_transposer × 4（8×8转置，每组1个）
│     ├── CMP × 4（online softmax，每组1个）
│     ├── fsa_accumulator × 4（rescale + PV累加，每组1个）
│     ├── fsa_acc_sram × 4（O中间结果 + rowsum）
│     ├── fsa_ctrl_fsm（25状态FSA控制）
│     └── write_out_v2（OS模式结果序列化）
├── axi_dma_controller（AXI4 Master）
└── AXI Slave（CSR访问）
```

### 1.1 阵列分组

物理1D链，逻辑4组×8PE：
- Group 0: PE[0..7] → head 0
- Group 1: PE[8..15] → head 1
- Group 2: PE[16..23] → head 2
- Group 3: PE[24..31] → head 3

### 1.2 FSA算法

硬件实现FlashAttention-2 online softmax，使用8段PWL exp2近似。
详见 `fsa_programmer_guide.md` §5 算法说明。

---

## 2. 文件组织

```
rtl/
  CB_top_v2.v              -- 顶层集成
  cb_controll_v2.v         -- 控制器（CSR + DMA调度）
  mac_top_v2.v             -- 统一计算顶层（FSA/GEMV MUX）
  PE_core_v2.v             -- 32 PE阵列（延迟匹配 + vertical链）
  write_out_v2.v           -- OS模式结果序列化
  fpmul_seq_pipeline.v     -- FP32乘法器（2拍流水）
  fpadd_seq.v              -- FP32加法器（1拍）
  sram.v                   -- 通用同步SRAM模型
rtl/PE/
  PE_retimed.sv            -- PE单元（OS/WS双模式，4拍MAC流水）
  FPMacUnit.sv             -- FP32 MAC + EXP2段匹配
  RawFloat_MulAddExp2.sv   -- FMA + exp2整数部分缩放
  RawFloat_FMA.sv          -- FMA wrapper（fpmul+fpadd）
  RawFloat_SplitIF.sv      -- 整数/小数分离（Chisel生成）
rtl/fsa/
  fsa_ctrl_fsm.v           -- FSA控制状态机（25状态）
  fsa_transposer.v         -- 8×8双缓冲转置引擎
  fsa_accumulator.v        -- Accumulator wrapper（单通道FPAccUnit）
  fsa_acc_sram.v           -- ACC SRAM（单通道×9深）
  FPAccUnit_pipe.sv        -- 流水化FP累加单元（3拍FMA+exp2）
  RawFloat_Div.sv          -- 迭代FP32除法器
rtl/fsa_gen/chisel_fsa_fp32/
  CMP.sv                   -- Chisel生成的CMP（online softmax）
  FPCmpUnit.sv             -- CMP内部比较单元
```

---

## 3. SRAM映射

| 数据 | 存储位置 | FSA模式映射 |
|------|----------|-------------|
| Q | Vector SRAM（4 bank × 16深） | bank[g] addr[0..d-1] = Q_head_g |
| K/V | Input SRAM（32 bank × 64深） | bank[g*8+row] addr[col] = K_head_g[row][col] |
| O中间 | ACC SRAM（4组 × 9深） | addr[0..7]=O[dim], addr[8]=rowsum |
| O输出 | Output SRAM（4 bank × 8深） | bank[g] addr[col] = O_head_g[col] |

---

## 4. FSA数据流

### 4.1 QK阶段（上行累加）

```
Input SRAM bank[g*8+row] → Transposer[g] → 转置 → PE[g*8+p].l_input = K[row][p]
PE[p].reg = Q[p]，MAC: Q[p]*K[row][p] + partial_sum
PE[7].u_output → CMP[g]：score[row] = Q·K[row]^T
```

### 4.2 Softmax阶段（下行传播）

```
SCORE_RESTREAM: score从CMP回流到PE.reg
SUBTRACT: PE.reg = score - newMax（CMP输出-newMax广播）
SCALE: PE.reg = (score-max) × ATTN_SCALE
EXP2: 8段PWL，PE.reg = exp2(scaled_score) = P
ROWSUM: P×1纵向累加 → rowsum
```

### 4.3 PV阶段（下行累加，V行反向）

```
Input SRAM bank[g*8+k] addr[col] → PE[p].l_input = V[7-p][col]（行反向）
PE[p].reg = P[p]，MAC: P[p]*V[7-p][col] + partial_sum
PE[7].d_output → Accumulator[g]：O[col] += P·V[:,col]
```

### 4.4 Rescale + 归一化

```
EXP_S1: scale = delta_m × ATTN_SCALE
EXP_S2: scale = exp2(scale)（rescale factor b）
ACC_SA: new_O[col] = b × old_O[col] + local_O[col]
RECIPROCAL: scale = 1/rowsum
NORM: O_final[col] = O[col] × (1/rowsum)
```

---

## 5. 关键设计参数

| 参数 | 当前值 | 可配置性 |
|------|--------|----------|
| ARRAY_SIZE | 32 | 编译时 |
| GROUP_SIZE | 8 | 编译时 |
| NUM_GROUPS | 4 | 编译时 |
| MAC_LATENCY | 4 | 编译时 |
| HEAD_DIM | 8 | CSR运行时（需匹配GROUP_SIZE） |
| ATTN_SCALE | log2(e)/√d | CSR运行时（REG_ATTN_SCALE 0x0050） |
| SEQ_LEN | 任意 | CSR运行时（最后tile自动mask） |

---

## 6. 实施阶段（全部完成）

| Phase | 内容 | 状态 |
|-------|------|------|
| 1 | PE_core_v2 + fsa_ctrl_fsm | ✅ |
| 2 | fsa_transposer（8×8双缓冲） | ✅ |
| 3 | CMP在线softmax | ✅ |
| 4 | Accumulator + Reciprocal + NORM | ✅ |
| 5 | mac_top_v2系统集成（2-tile DPI-C验证） | ✅ |
| 6 | CB_top_v2顶层集成 + 端到端验证 | ✅ |

### 6.1 已修复的关键bug

| Bug | 根因 | 修复文件 |
|-----|------|----------|
| EXP2 exp2Done不sticky | 伪匹配覆盖正确P值 | PE_retimed.sv |
| EXP2 mac_cmd未经S0延迟 | 边界拍时序错 | PE_retimed.sv |
| EXP2_SLOPES顺序错误 | 未反序匹配Chisel .reverse | mac_top_v2.v |
| c_exp_msb_pipe过度延迟 | 3级→1级 | FPMacUnit.sv |
| 4组共享K/V | 单Transposer广播 | mac_top_v2.v |
| PV_MAC SRAM时序 | ctrl_valid未对齐SRAM读延迟 | fsa_ctrl_fsm.v |
| FP32乘法器指数下溢 | 8位无符号exp回绕255→NaN | fpmul_seq_pipeline.v |
| EXP2极端输入溢出 | SplitIF isInf未正确处理 | RawFloat_MulAddExp2.sv |
| Accumulator LOG2E常量 | 0.33 vs 正确0.51 | fsa_accumulator.v |

---

## 7. 验证覆盖

| TB | 层级 | 覆盖 |
|----|------|------|
| tb_fsa_auto_compare | mac_top_v2 | 逐阶段DPI-C精确比对（ULP级） |
| tb_fsa_e2e | CB_top_v2 | 端到端黑盒（fp64标准softmax golden，10 case） |
| tb_mac_top_v2_os_regression | mac_top_v2 | OS模式14-case全量回归 |
| tb_CB_top_v2_gemv | CB_top_v2 | GEMV模式14-case回归 |

---

## 8. 后续扩展方向

1. **可配置head_dim（16/32）：** CSR接口已就绪（ATTN_SCALE），需要PE阵列GROUP_SIZE参数化
2. **多batch调度：** 软件分批调用（每批4 head），硬件无需改动
3. **KV cache增量更新：** 利用KV_STRIDE支持非连续tile布局

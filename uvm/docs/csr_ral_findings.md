# UVM RAL CSR验证发现记录

## 概述

通过UVM RAL内置sequence（`uvm_reg_hw_reset_seq` + `uvm_reg_bit_bash_seq`）对CB_top_v2的18个CSR寄存器进行自动化验证，发现以下RTL实现与文档假设的差异。

---

## 发现1：ATTN_SCALE寄存器复位值非零

| 项目 | 内容 |
|------|------|
| 寄存器 | REG_ATTN_SCALE (0x0050) |
| 发现方式 | `uvm_reg_hw_reset_seq` |
| 现象 | 复位后读回值=0x3F0293EE，RAL期望复位值=0x00000000 |
| 分析 | RTL中该寄存器有硬编码默认值（对应head_dim=8的ATTN_SCALE=log2(e)/√8≈0.51） |
| 影响 | 功能无影响（软件启动前必须配置此寄存器），但与"所有CSR复位为0"的文档描述不一致 |
| 状态 | 待确认：是RTL设计意图还是遗漏 |
| 建议 | 若为设计意图，更新RAL reset value和programmer guide；若为遗漏，RTL修复为0 |

---

## 发现2：GROUP_MODE寄存器只有bit[1:0]有效

| 项目 | 内容 |
|------|------|
| 寄存器 | REG_GROUP_MODE (0x0054) |
| 发现方式 | `uvm_reg_bit_bash_seq` |
| 现象 | 写入bit[2:31]后读回为0，只有bit[1:0]保持写入值 |
| 分析 | RTL只实现了2位宽的寄存器（值域0/1/2），高位未连接 |
| 影响 | 功能无影响（合法值只有0/1/2），但RAL模型需要反映实际位宽 |
| 状态 | 已修复RAL模型（group_mode改为2-bit RW + 30-bit RO reserved） |
| 建议 | 确认其他"32位RW"寄存器是否也有类似截断（如HEAD_DIM只需5位、SEQ_LEN只需8位等） |

---

## 发现3：STATUS寄存器bit_bash异常

| 项目 | 内容 |
|------|------|
| 寄存器 | REG_STATUS (0x0004) |
| 发现方式 | `uvm_reg_bit_bash_seq` |
| 现象 | busy位(bit[0])在bit_bash期间读回为1，与预期的0不符 |
| 根因分析 | **非RTL bug**。RTL中STATUS无写入路径（纯硬件驱动RO）。bit_bash先测了CTRL寄存器，写入start=1触发FSM离开IDLE，导致`busy=(state!=S_IDLE)=1`。读回的1是硬件状态变化，不是写入生效。 |
| RTL证据 | `cb_controll_v2.v` 行773: `csr_status[BUSY_BIT] <= (state != S_IDLE);` 无软件写入路径 |
| 影响 | 无功能影响，STATUS写保护正确 |
| 状态 | 已确认非bug，是bit_bash测试顺序导致的预期行为 |
| 建议 | 可在csr_access_test中对STATUS单独做复位后立即读取验证（不经过CTRL写入） |

---

## 后续验证计划

1. 逐个确认上述发现的RTL根因
2. 对HEAD_DIM/SEQ_LEN/NUM_HEADS等寄存器确认实际有效位宽
3. 修正RAL模型使其精确匹配RTL实现
4. 修正后重跑csr_access_test达到0 UVM_ERROR

---

## 发现4：FSA连续操作（不复位）输出错误

| 项目 | 内容 |
|------|------|
| 发现方式 | `fsa_regression_test` — 多个FSA case连续执行不复位 |
| 现象 | Case 0（seq_len=1）PASS，Case 1（seq_len=4）起输出误差25%-582% |
| 严重程度 | 低（当前软件使用模式不触发） |

### 根因分析（已确认）

RTL代码审计确认以下内部状态在FSA DONE→IDLE→再次启动时**未被清零**：

| 模块 | 残留状态 | 影响 |
|------|----------|------|
| **fsa_acc_sram** | `mem[0:8]`（旧O向量 + rowsum） | 第2次FSA的tile_idx=0首次ACC_SA累加到旧值上 |
| **fsa_accumulator** | `scale_sign/exp/mantissa`寄存器 | 上次FSA结束时scale=1/l，第2次FSA首tile的ACC_SA用错误scale |
| **fsa_transposer** | `initialized`, `wr_col`, `rd_row`, `active_buf` | 指针可能未对齐（风险较低，TRANSPOSE_K会重新填满buffer） |

### CMP_RESET状态行为

`fsa_ctrl_fsm.sv` S_CMP_RESET状态**仅发送CMP复位命令**，清零CMP模块的max/状态寄存器。
不触及acc_sram内容、accumulator scale、transposer指针。

### 为什么dual_mode_stress_test PASS

GEMV模式完全不访问acc_sram（acc_sram_rd_en/wr_en仅由FSA FSM驱动）。
dual_mode_stress PASS是因为每个FSA sequence有hw_reset。
板上LLaMA推理PASS是因为每次FSA只做1个head，NORM阶段覆盖了acc_sram大部分地址。

### 推荐修复方案

**方案A（推荐）：在FSM中加S_ACC_CLEAR状态**

在S_CMP_RESET → S_DMA_K之间插入清零状态：
1. 循环写0到acc_sram全部地址（0~eff_group_size）
2. 复位accumulator scale=1.0（发ACC_SET_SCALE命令）
3. 清零transposer initialized标志

代价：增加9-33个时钟周期（取决于group_mode），对总延迟影响<1%。

**涉及RTL文件：**
- `rtl/fsa/fsa_ctrl_fsm.sv` — FSM主逻辑，新增状态
- `rtl/fsa/fsa_acc_sram.sv` — 需要加force_clear写端口
- `rtl/fsa/fsa_accumulator.sv` — scale寄存器需要复位路径
- `rtl/mac_top_v2.sv` — acc_sram写控制MUX适配

### 当前状态

- UVM验证中用hw_reset规避
- 软件当前使用模式不触发（FSA之间有GEMV隔开）
- 建议后续版本修复，提高硬件通用性

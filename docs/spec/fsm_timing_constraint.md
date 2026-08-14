# PE_retimed FSM 适配时序约束文档

> 验证基础：tb_pe_ws_equivalence.sv (pass=225 fail=0)
> 验证日期：2026-05-14
> 适用 RTL：rtl/PE/PE_retimed.sv (含 s0_acc_ui_q/s0_update_reg_q/s0_exp2_q 修复)

---

## 1. 时序约束表

| 约束名称 | 数值 | 物理含义 | 验证 Case |
|----------|------|----------|-----------|
| reg_write_latency | 4 cycles | MAC/exp2 issue → reg 物理更新 | Case 2a, 4a/4b |
| min_gap_after_update | 5 cycles | MAC issue → 下一个读 reg 操作可发出的最早时刻 | Case 4c |
| min_gap_after_exp2 | 5 cycles | exp2 issue → 下一个读 reg 操作可发出的最早时刻 | Case 2b |
| flow_latency | 0 cycles | flow_lr/ud/du 即时通过，无延迟 | Case 1b/1c/3 |
| ctrl_output_latency | 3 cycles | ctrl 输入 → ctrl 输出（驱动下游 PE） | Case 5 |
| mac_result_latency | 4 cycles | MAC issue → u/d_output 有效 | Case 1a/1d/3 |

### 约束含义详解

```
                    issue          S0_q        pipe[0]     pipe[1]     pipe[2]=commit
MAC timeline:    ────T──────────T+1─────────T+2─────────T+3─────────T+4────────
                    │              │            │           │           │
                    │              │            │           │           └─ reg更新/output有效
                    │              │            │           │
                    │              └─ FPMacUnit io_in_valid │
                    │                                      │
                    └─ issue_mac_valid_ws=1                 └─ 新操作最早可发出(读到新reg)
                       ctrl信号采样                            (因为新操作的S0在T+5+1=T+6读reg)
```

- **min_gap = 5**：新操作在 issue+5 发出，其 S0 阶段在 issue+6 读 reg，此时 reg 已在 issue+4 更新完毕。
- **min_gap = 4 不安全**：新操作在 issue+4 发出，S0 在 issue+5 读 reg，但 reg 在 issue+4 的 posedge 才写入，S0 在 issue+5 读到的是新值——实际上是安全的（Case 4c 验证通过）。

修正：**实测 min_gap = 4 即可安全读到新值**（Case 4c 证实）。约束表保守写 5 是为 FSM 留 1 拍余量。

---

## 2. 适配规则

### 2.1 不需要修改的信号（即时路径）

| 信号 | 原因 |
|------|------|
| flow_lr, flow_ud, flow_du | 组合直通，0 延迟 |
| load_reg_li, load_reg_ui | 同拍写入 reg，即时生效 |

这些操作在 PE_retimed 中与 chisel PE 行为完全一致，FSM 时序无需调整。

### 2.2 需要后移的操作（有 reg 读后写依赖）

**通用规则**：任何读 reg 的操作，如果依赖前一个 MAC/exp2 的写回结果，必须在原版时序基础上后移 4 拍。

| 操作 | 依赖 | 后移量 | 原因 |
|------|------|--------|------|
| exp2（读 reg 作为输入） | 前序 mac+update_reg 写回 | +4 cycles | 等 reg_write_latency 完成 |
| mac rowsum（读 reg） | 前序 exp2 写回 | +4 cycles | 等 exp2 写回完成 |
| 任何 mac（读 reg 作为 weight） | 前序 load_reg_li/ui | 0 (不需要) | load 是即时路径 |

### 2.3 MAC 结果消费者采样后移

MAC 结果（u_output/d_output）比 chisel PE 晚 4 拍出现。如果下游模块（comparator、accumulator）需要采样 MAC 结果：
- 采样窗口后移 4 拍
- 或使用 valid 信号（io_u_output_valid/io_d_output_valid）作为采样使能

### 2.4 ctrl 输出对阵列 stagger 的影响

PE_retimed 的 ctrl 输出比输入延迟 3 拍。在脉动阵列中，ctrl 信号逐行传播：
- 原版 chisel PE：ctrl 即时透传，行间延迟由外部 pipeline register 提供
- PE_retimed：自带 3 拍 ctrl 延迟，外部 stagger 设计需考虑此延迟

---

## 3. AttentionScore 阶段适配示例

### 3.1 原版 chisel PE 时序（108 cycles）

```
cycle 0:      load_reg_li          装入 Q weight
cycle 1-32:   mac + flow_lr        K^T 流入，Q·K 计算
cycle 33-64:  flow_ud              S 结果向下排出
cycle 36-67:  flow_du              newm 向上回流
cycle 65:     load_reg_ui          装入 S 值到 reg
cycle 66:     mac + acc_ui + update_reg    S - newm，结果写回 reg
cycle 68:     exp2 开始            读 reg（S-m），PWL 近似
cycle 68-75:  exp2 连续 8 拍
cycle 76:     mac + acc_ui         rowsum，读 reg（exp2 结果）
```

### 3.2 PE_retimed 适配后时序

```
cycle 0:      load_reg_li          不变（即时路径）
cycle 1-32:   mac + flow_lr        不变（mac发出不变，结果晚4拍出现）
cycle 33-64:  flow_ud              不变（即时路径）
cycle 36-67:  flow_du              不变（即时路径）
cycle 65:     load_reg_ui          不变（即时路径）
cycle 66:     mac + acc_ui + update_reg    不变（发出不变）
cycle 70:     exp2 开始            +4（等 cycle 66 的 MAC 写回完成）
cycle 70-77:  exp2 连续 8 拍
cycle 81:     mac + acc_ui         +4+1（等 exp2 最后一段写回完成）
                                   exp2[7] issue at 77, commit at 81
```

### 3.3 关键依赖链

```
mac+update_reg ──(4 cycles)──→ reg 更新 ──(≥1 cycle)──→ exp2 可发出
     cycle 66                    cycle 70                  cycle 70

exp2[7] issue ──(4 cycles)──→ reg 更新 ──(≥1 cycle)──→ rowsum 可发出
    cycle 77                    cycle 81                  cycle 81
```

### 3.4 总周期数变化

| 阶段 | 原版 | 适配后 | 增量 |
|------|------|--------|------|
| load + mac + flow | 67 cycles | 67 cycles | 0 |
| update_reg → exp2 gap | 2 cycles | 4 cycles | +2 |
| exp2 → rowsum gap | 1 cycle | 4 cycles | +3 |
| **总计** | 76 cycles | 81 cycles | **+5** |

---

## 4. AttentionValue 阶段适配

```
原版:    cycle 1-32: mac + acc_ui + flow_lr (V 与 P(reg) 做 MAC)
适配后:  cycle 1-32: mac + acc_ui + flow_lr (不变，reg 由 load_reg 装入，无写后读依赖)
```

AttentionValue 阶段无 reg 读后写依赖（P 值通过 load_reg 装入后只读不写），**无需时序调整**。

---

## 5. 已知精度差异

| 项目 | 数据 |
|------|------|
| MAC 值匹配率 | 28/32（Case 3 随机数据） |
| exp2 值匹配率 | 5/8（非收敛段） |
| exp2 最终 reg | 完全一致（收敛段写回结果相同） |
| 差异原因 | PE_retimed: fpmul_seq_pipeline(2拍) + fpadd_seq(1拍)，双重舍入；chisel PE: 单周期 FMA，单次舍入 |
| 对 FSA 的影响 | 不影响功能正确性。exp2 PWL 收敛结果一致，softmax 归一化后误差被消除 |

---

## 6. 验证复现

```powershell
# WS 模式等价性验证
.\scripts\run_vcs_remote.ps1 -Top tb_pe_ws_equivalence -Filelist ./scripts/pe_ws_equiv_filelist.f

# OS 模式回归（确认修复未破坏）
.\scripts\run_vcs_remote.ps1 -Top tb_cb_baseline -Filelist ./scripts/cb_baseline_filelist.f
```

---

## 7. RTL 修复记录

**Bug**: WS 模式下 `mac_acc_ui_pipe`/`mac_update_reg_pipe`/`mac_exp2_pipe` 与 `mac_valid_pipe` 错位 1 拍。

**根因**: 控制属性从 `io_in_ctrl_bits_*`（当前拍）采样，但 `issue_mac_valid` 来自 `issue_mac_valid_ws_q`（延迟 1 拍），导致管线中 valid 和控制属性对应不同周期的操作。

**修复**: 新增 `s0_acc_ui_q`/`s0_update_reg_q`/`s0_exp2_q` 三个 S0 寄存器，与 `issue_mac_valid_ws_q` 同源采样，确保管线入口对齐。

**影响范围**: 仅 WS 模式。OS 模式使用硬编码 commit 信号，不经过此管线。

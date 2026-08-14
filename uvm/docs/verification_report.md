# CB_top_v2 UVM验证报告

## 1. 验证概述

| 项目 | 内容 |
|------|------|
| DUT | CB_top_v2 — 双模式加速器（GEMV Output-Stationary + FSA FlashAttention-2） |
| 验证方法 | UVM 1.2 + Constrained Random + Coverage-Driven |
| 仿真工具 | Synopsys VCS O-2018.09-SP2-3 / R-2020.12-SP1 |
| 验证周期 | 2026-05-31 起（覆盖率数据更新至 2026-06-03） |
| 验证结论 | **PASS**（所有功能验证通过，2个RTL bug已修复） |

---

## 2. 测试结果汇总

| # | Test | 测试点数 | 结果 | 说明 |
|---|------|---------|------|------|
| 1 | csr_access_test | 18 regs | PASS | RAL hw_reset + bit_bash |
| 2 | gemv_sanity_test | 1 | PASS | 32×64单tile |
| 3 | gemv_regression_test | 14 | PASS | 所有tiling边界 |
| 4 | gemv_random_test | 100 | PASS | Constrained random |
| 5 | fsa_sanity_test | 1 | PASS | dim=8, seq=8, 4×8 |
| 6 | fsa_regression_test | 96 | PASS | 3种group_mode全覆盖（34+31+31），seq_len含1~511 |
| 7 | fsa_random_test | 150 | PASS | Constrained random |
| 8 | fsa_hd64_test | 3 | PASS | head_dim=64双chunk（fulltile/2tile/partial） |
| 9 | fsa_hd48_test | 3 | PASS | head_dim=48，chunk2需DMA padding |
| 10 | dual_mode_stress_test | 10 rounds | PASS | GEMV↔FSA交替 |
| 11 | error_injection_test | 4 | PASS | 非法配置不hang |
| 12 | mid_op_reset_test | 46 | PASS | 23点×2模式中途复位 |
| 13 | precise_fsm_reset_test | 33 | PASS | 14 GEMV + 19 FSA状态精准复位 |
| 14 | special_fp_test | 4 + NF-01~08 | PASS | subnormal/inf/NaN/±0/max溢出 + exp2 PWL分段 |
| 15 | fsa_residue_impact_test | 3 rounds | PASS | FSA→GEMV→FSA不复位 |
| 16 | fsa_soak_test | 50 rounds | PASS | 3种mode交替压力 |
| 17 | perf_limit_test | PL-01~07 | PASS | 容量/位宽上限边界（seq_len/rows/cols/head_dim/group_mode） |
| **合计** | | **~570** | **全PASS** | |

---

## 3. 覆盖率结果

### 3.1 代码覆盖率（16 test合并，最新口径 2026-07-11）

| 类型 | 原始值 | 目标 | 状态 |
|------|--------|------|------|
| Line | 91.08% | >90% | ✓ 首次达标 |
| Condition | 86.57% | >80% | ✓ |
| Toggle | 95.35% | >70% | ✓ |
| FSM | 90.10% | >95% | 接近（差4.9%，见W-002） |
| Branch | 86.18% | >85% | ✓ |
| Score（总分） | 90.74% | — | — |

> 注：本轮新增 perf_limit_test（PL-01~07 容量/位宽边界）+ special_fp 扩展（NF-01~08 数值域边界）
> 后重新收集。相比上一轮（12-test，Line 89.34%/Toggle 91.34%）：
> - **Line 89.34%→91.08%**（首次过90%）：NF 的 inf/NaN 传播路径 + PL-07 GROUP_MODE=3 default分支被覆盖
> - **Toggle 91.34%→95.35%**（+4.01）：NF 的 inf/NaN/max 激活 `multiplication_normaliser` 归一化逻辑各bit翻转
> - FSM 91.67%→90.10%：方案A 在 S_IDLE 新增 `num_tiles=0→S_DONE` 转移，分母变大所致

### 3.2 功能覆盖率

| Covergroup | 值 | 目标 | 状态 |
|------------|-----|------|------|
| cg_mode_config | 100% | 100% | ✓ |
| cg_gemv_dims (cross) | >90% | 90% | ✓ |
| cg_fsa_config (cross) | >95% | 95% | ✓ |
| cg_csr_access | 100% | 100% | ✓ |
| cg_stress | 100% | 80% | ✓ |
| **合并** | **95.19%** | >90% | ✓ |

### 3.3 Waiver说明

| ID | 模块 | 行/转移数 | 原因 |
|----|------|----------|------|
| W-001 | axi_dma_controller | 23行 | 参数化死代码（32位配置不触发窄传输） |
| W-002 | CB_Controller/fsa_ctrl_fsm | ~7%转移 | 极短状态(1-2拍)复位转移不可测 |

---

## 4. RTL Bug发现与修复

### Bug 6: FSA acc_sram残留（严重）

| 项目 | 内容 |
|------|------|
| 发现方式 | UVM fsa_residue_impact_test |
| 影响 | 连续FSA操作精度错误(MRE 30%+)，板上254/1275元素fail |
| 根因 | acc_sram和scale寄存器在FSA完成后未清零 |
| 修复 | 新增S_ACC_CLEAR状态（循环写零acc_sram + SET_SCALE复位scale） |
| 代价 | 9-33 cycles/次FSA启动（<1%性能） |

### Bug 6b: Scale残留Inf（group_mode切换）

| 项目 | 内容 |
|------|------|
| 发现方式 | UVM fsa_soak_test（50轮3种mode交替） |
| 影响 | 1×32→4×8切换后head1输出±Inf |
| 根因 | 1×32 RECIPROCAL对非活跃group做1/0=Inf，scale残留 |
| 修复 | S_ACC_CLEAR发ACC_SET_SCALE + sram_in MUX为1.0 |

### Bug 7: seq_len=0/4096 导致 FSM HANG（健壮性）

| 项目 | 内容 |
|------|------|
| 发现方式 | UVM perf_limit_test PL-02（seq_len=4096边界）|
| 影响 | seq_len=0（含4096因`[11:0]`截断回绕成0）时 num_kv_tiles=0，FSA FSM 卡在 S_FSA_WAIT_K（门槛`tile_idx < num_kv_tiles`永假不发DMA、fsa_done永不来）→ 死锁 |
| 根因 | `csr_seq_len[11:0]` 12位截断 + 无 num_tiles=0 保护 |
| 修复 | 方案A：S_IDLE 检测 mode_fsa 且 num_kv_tiles_w=0 时直接跳 S_DONE，不进 FSA 流程 |
| 性质 | seq_len 合法范围 1~4095（文档已明确），0/4096 为越界输入；此为健壮性防御，非规格bug |

### 边界能力确认（perf_limit_test / 硬件真实上限）

| 项 | 结论 |
|------|------|
| GEMV 列宽上限 | **≤511**（`cmd_len`/`cmd_stride` 均 11-bit=2047B=511元素，自洽设计上限）。cols≥512 时 stride 溢出→行地址回绕→计算错误。文档原"COLS无限制"是过度承诺，已订正为 ≤511 |
| FSA tile 数上限 | 127 tiles（1×32, seq_len=4064）FSM 正常收尾，13-bit tile 计数器不溢出 |
| GEMV rows | 256 行可正常处理（自动32行分块，无X传播）|
| head_dim=65 / GROUP_MODE=3 | 越界/非法输入，DUT 无X传播、能响应（行为记录，软件契约保证不触发）|

### 其他发现（非bug）

| 发现 | 结论 |
|------|------|
| ATTN_SCALE复位值非零 | 设计意图（默认head_dim=8），已更新文档 |
| GROUP_MODE只有2bit有效 | RTL只实现2位（合法值0/1/2），已修正RAL |
| STATUS bit_bash异常 | 测试顺序导致FSM状态变化，非bug |
| perf_limit首轮"全X" | **误报澄清**：test 用了超1MB仿真DDR的地址（越界backdoor返回X），扩DDR模型 MEM_AW 18→24(64MB) 后消失，非RTL缺陷 |

---

## 5. 验证环境架构

```
tb_top
  +-- CB_top_v2 (DUT)
  +-- tb_axi_ram_sp_ext (DDR模型)
  +-- UVM env
        +-- axi_slv_agent (Active, CSR驱动)
        +-- mem_model (backdoor DDR访问)
        +-- cb_csr_reg_block (UVM RAL, 18 regs)
        +-- cb_axi_reg_adapter + uvm_reg_predictor
        +-- cb_func_coverage (5 covergroups)
```

---

## 6. 自动化脚本

| 命令 | 用途 |
|------|------|
| `run_uvm_remote.ps1 -Mode single -Test xxx` | 单个test |
| `run_uvm_remote.ps1 -Mode regression` | 日常回归(6 tests) |
| `run_uvm_remote.ps1 -Mode full` | 全量回归(14 tests，~25min) |
| `run_uvm_remote.ps1 -Mode coverage` | 覆盖率回归(14 tests合并 + urg报告) |
| `run_uvm_remote.ps1 -Mode compile` | 仅编译 |

---

## 7. 遗留项

| 项目 | 优先级 | 说明 |
|------|--------|------|
| Verdi .el文件生成 | P2 | 需在EDA服务器交互式操作（教程已写） |
| axi_mst_monitor | P2 | DMA被动监控（当前未实现） |
| scoreboard独立组件 | P2 | 当前比对在sequence中（功能等价） |
| multiplication_normaliser toggle | P3 | 结构性限制，flush-to-zero后不可达 |

---

## 8. 结论

CB_top_v2加速器通过UVM验证，功能正确性和复位安全性均已确认：
- **功能验证**：14个directed test + 250次random + 50轮soak全PASS
- **精度验证**：GEMV max_rel_err<0.01%, FSA max_rel_err<1%
- **鲁棒性验证**：4种错误注入不hang + 极端FP值不crash + 33状态复位安全
- **覆盖率**：所有类型达标（waiver后）
- **RTL修复**：2个精度bug已修复并验证，板上254/1275 fail预期消除

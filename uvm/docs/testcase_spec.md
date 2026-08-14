# 测试用例规格说明 — CB_top_v2 UVM验证

> 本文档反映当前 `uvm/tests/` 下实际存在的 test（16个）。历史版本曾记录9个test/88 FSA case，
> 已随RTL演进（head_dim>32 chunk机制、seq_len扩宽、新增reset/soak/residue系列）更新。

## 1. 测试层次结构

```
cb_top_base_test (所有test的基类)
  |
  +-- gemv_sanity_test          — GEMV快速冒烟（32×64）
  +-- gemv_regression_test      — GEMV 14个directed case
  +-- gemv_random_test          — GEMV constrained random（默认100次）
  +-- fsa_sanity_test           — FSA快速冒烟（dim=8, seq=8, 4×8）
  +-- fsa_regression_test       — FSA 96个directed case（34+31+31）
  +-- fsa_random_test           — FSA constrained random（默认150次）
  +-- fsa_hd64_test             — head_dim=64双chunk定向（3 case）
  +-- fsa_hd48_test             — head_dim=48 chunk2 padding定向（3 case）
  +-- csr_access_test           — CSR寄存器读写验证（RAL）
  +-- dual_mode_stress_test     — GEMV/FSA交替压力（10 rounds）
  +-- error_injection_test      — 错误注入（4 sub-case）
  +-- mid_op_reset_test         — 中途复位（23点×2模式=46）
  +-- precise_fsm_reset_test    — 精准FSM状态复位（14 GEMV + 19 FSA=33）
  +-- special_fp_test           — 极端FP值鲁棒性（GEMV+FSA）
  +-- fsa_residue_impact_test   — FSA→GEMV→FSA残留验证（3 round）
  +-- fsa_soak_test             — 3种mode交替长时压力（50 round）
```

---

## 2. 基类：cb_top_base_test

### 职责
- 构建cb_top_env（axi_slv_agent + mem_model + RAL + coverage）
- 执行复位序列，注册virtual sequencer
- 提供公共utility：`hw_reset()`、`wait_done()`、`csr_write/read`、`ddr_write/read`、`rand_fp32()`

### 复位序列
```
1. rst_n = 0
2. 等待若干clk上升沿
3. rst_n = 1
4. 等待内部状态稳定
```

---

## 3. GEMV测试用例

### 3.1 gemv_sanity_test
| 项目 | 内容 |
|------|------|
| 目的 | 验证GEMV单tile 32×64矩阵向量乘 |
| 判定 | 32元素bit-exact匹配golden=PASS |

### 3.2 gemv_regression_test（14 cases）

代码实测参数（`uvm/tests/gemv_tests.sv`）：

| Case | Name | Rows | Cols | Seed | 验证重点 |
|------|------|------|------|------|----------|
| 1 | TC_Sanity | 32 | 64 | 42 | 单tile基本功能 |
| 2 | TC_Identity | 32 | 32 | 0 | 方阵 |
| 3 | TC_TwoRowTile | 64 | 64 | 100 | 2行tile |
| 4 | TC_ThreeColTile | 32 | 172 | 200 | 3列tile累加（64+64+44） |
| 5 | TC_Row33 | 33 | 64 | 300 | 行边界 32+1 |
| 6 | TC_Row48 | 48 | 64 | 400 | 行边界 32+16 |
| 7 | TC_Col65 | 32 | 65 | 500 | 列边界 64+1 |
| 8 | TC_Col128 | 32 | 128 | 600 | 2列tile精确 |
| 9 | TC_Large | 64 | 128 | 700 | 2行×2列tile |
| 10 | TC_Max | 64 | 172 | 800 | 最大支持尺寸 |
| 11 | TC_SingleRow | 1 | 64 | 900 | 最小行数 |
| 12 | TC_Small | 8 | 32 | 1000 | 小矩阵 |
| 13 | TC_Odd | 17 | 100 | 1100 | 非对齐维度 |
| 14 | TC_Stress | 32 | 64 | 1200 | 连续执行（不复位） |

判定：全部bit-exact匹配=PASS。

### 3.3 gemv_random_test
| 项目 | 内容 |
|------|------|
| 迭代 | 默认100次（`+num_iterations=N`可调），seed=`i*7919+12345` |
| Constraint | rows∈[1:64]，cols∈[1:172]，边界值加权 |
| 判定 | 每次bit-exact匹配 |

---

## 4. FSA测试用例

### 4.1 fsa_sanity_test
| 项目 | 内容 |
|------|------|
| 参数 | head_dim=8, seq_len=8, num_heads=4, group_mode=0 |
| 判定 | 32个输出 rel_err<5%（vs fp64 golden），无NaN/Inf |

### 4.2 fsa_regression_test（96 cases）

代码实测（`uvm/tests/fsa_tests.sv`）：3种group_mode × 多种seq_len。

**4×8模式（group_mode=0, head_dim=8, num_heads=4）— 34 cases，seed=1001+i：**
```
seq_len = {1,4,8,9,10,12,15,16,17,20, 24,25,30,32,33,40,48,50,60,64,
           72,80,96,100,120,128,140,150,155,160, 255,256,300,511}
```

**2×16模式（group_mode=1, head_dim=16, num_heads=2）— 31 cases，seed=2001+i：**
```
seq_len = {1,8,16,17,20,24,30,32,33,40, 48,50,60,64,72,80,90,96,100,110,
           120,128,130,140,144,150,155,158,160, 255,511}
```

**1×32模式（group_mode=2, head_dim=32, num_heads=1）— 31 cases，seed=3001+i：**
```
seq_len = {1,16,32,33,40,48,50,60,64,65, 72,80,90,96,100,110,120,128,130,140,
           144,150,155,158,160, 33,65,97,129,255,511}
```

判定：全部 rel_err<5%=PASS。已知PWL精度边界失败（seq≥250多tile，golden接近0）按
`docs/agent/constrain.md` 清单豁免——见第11节。

### 4.3 fsa_random_test
| 项目 | 内容 |
|------|------|
| 迭代 | 默认150次（`+num_iterations=N`可调），seed=`i*6271+54321` |
| Constraint | group_mode∈{0,1,2}，seq_len∈[1:160]，head_dim/num_heads由group_mode派生 |

### 4.4 fsa_hd64_test（head_dim=64双chunk，3 cases）

head_dim>32触发dual_chunk_mode（chunk1=前32维，chunk2=后32维）。group_mode=2, num_heads=1。

| Case | Name | seq_len | Seed |
|------|------|---------|------|
| 1 | hd64_fulltile | 64 | 640001 |
| 2 | hd64_2tile | 128 | 640002 |
| 3 | hd64_partial | 100 | 640003 |

### 4.5 fsa_hd48_test（head_dim=48，chunk2需DMA padding，3 cases）

head_dim=48 → chunk2_width=16，走DMA padding路径（区别于hd64的对齐路径）。

| Case | Name | seq_len | Seed |
|------|------|---------|------|
| 1 | hd48_fulltile | 48 | 480001 |
| 2 | hd48_2tile | 96 | 480002 |
| 3 | hd48_partial | 70 | 480003 |

---

## 5. 通用/鲁棒性测试用例

### 5.1 csr_access_test
UVM RAL自动化：`uvm_reg_hw_reset_seq`（复位值）+ `uvm_reg_bit_bash_seq`（逐bit读写）。
STATUS等RO寄存器的bit_bash因触发FSM状态变化被排除（非bug，见csr_ral_findings.md）。

### 5.2 dual_mode_stress_test
| 项目 | 内容 |
|------|------|
| 循环 | 10 rounds（仅初始复位一次） |
| 每round | GEMV(32×64) + FSA(dim=8,seq=16,4×8)，仅重配CSR不复位 |
| 判定 | 20次计算全PASS=无状态泄漏 |

### 5.3 error_injection_test（4 sub-case）
| Sub-case | 操作 | 期望 |
|----------|------|------|
| err_zero_rows | ROWS=0启动GEMV | 不hang |
| err_zero_cols | COLS=0启动GEMV | 不hang |
| err_start_while_busy | 启动后立即再start | 不hang，正常收尾 |
| err_invalid_group_mode | GROUP_MODE=3 | 不hang |

判定：TIMEOUT内完成=PASS，hang=FAIL。（注：此test只验"不hang"，未断言结果正确性。）

### 5.4 mid_op_reset_test（46点）
23个reset延迟点 `{3,5,8,12,15,20,30,40,50,70,100,130,150,200,300,400,500,700,1000,1500,2000,3000,5000}`
× 2模式（GEMV/FSA）。每点：启动操作→延迟N cycle触发复位→验证复位后能正常完成新操作。
覆盖FSM各阶段的中途复位安全性。

### 5.5 precise_fsm_reset_test（33状态）
通过backdoor监控fsm_state，在目标状态活跃时精确触发复位：
- GEMV FSM：14个状态（DMA_VI/WAIT_VI/.../CHECK_LOOP）
- FSA FSM：19个状态（LOAD_Q_BUF/.../DMA_O）

覆盖所有 `S_XXX→S_IDLE` 复位转移，是FSM转移覆盖率从~55%提升到92%的关键。

### 5.6 special_fp_test
注入极端FP32值（subnormal/denormal/±0/±inf/最大正规数）验证不crash：
- GEMV：special混合值、all-subnormal、large-values
- FSA：tiny-values（验证softmax收敛到均匀分布）

### 5.7 fsa_residue_impact_test（3 round）
精准复现板上调用模式，验证Bug 6修复（acc_sram残留）：
| Round | 操作 | 目的 |
|-------|------|------|
| 1 | FSA(seq=8) | 首次基线 |
| — | GEMV(32×64) | 模拟板上matmul隔离 |
| 2 | FSA(seq=16, 不复位) | 验证无残留（修复前MRE 30%） |
| — | GEMV | 二次隔离 |
| 3 | FSA(seq=24, 不复位) | 累积验证 |

### 5.8 fsa_soak_test（50 round）
3种group_mode轮流（round%3）交替 + 每round随机seq_len∈[2:151]，FSA→GEMV，全程不复位。
验证Bug 6b修复（1×32→4×8切换scale残留Inf）。`+soak_rounds=N`可调轮数。
判定：无残留（0xDEADBEEF未覆盖）且无NaN/Inf。

---

## 6. CSR寄存器表

| 地址 | 寄存器 | 复位值 | 属性 | 说明 |
|------|--------|--------|------|------|
| 0x0000 | CTRL | 0x0 | RW | [0]=start [1]=mode(0=GEMV,1=FSA) |
| 0x0004 | STATUS | 0x0 | RO | [0]=busy [1]=done |
| 0x0008 | ERR_CODE | 0x0 | RO | 保留（当前无错误检测逻辑写入） |
| 0x0010 | VI_BASE | 0x0 | RW | GEMV输入向量基址 |
| 0x0014 | MI_BASE | 0x0 | RW | GEMV矩阵基址 |
| 0x0018 | VO_BASE | 0x0 | RW | GEMV输出基址 |
| 0x0020 | ROWS | 0x0 | RW | GEMV行数 |
| 0x0024 | COLS | 0x0 | RW | GEMV列数 |
| 0x0030 | Q_BASE | 0x0 | RW | FSA Q基址 |
| 0x0034 | K_BASE | 0x0 | RW | FSA K基址 |
| 0x0038 | V_BASE | 0x0 | RW | FSA V基址 |
| 0x003C | O_BASE | 0x0 | RW | FSA O基址 |
| 0x0040 | HEAD_DIM | 0x0 | RW | head维度（用低8位） |
| 0x0044 | SEQ_LEN | 0x0 | RW | 序列长度（计算用低12位） |
| 0x0048 | KV_STRIDE | 0x0 | RW | K/V tile间DDR步长 |
| 0x004C | NUM_HEADS | 0x0 | RW | head数 |
| 0x0050 | ATTN_SCALE | 硬编码默认 | RW | log2(e)/sqrt(d) |
| 0x0054 | GROUP_MODE | 0x0 | RW | 仅低2位（0/1/2合法） |

---

## 7. ATTN_SCALE预计算值

| head_dim | ATTN_SCALE (hex) | 公式 |
|----------|------------------|------|
| 8 | 0x3F0293EE | log2(e)/sqrt(8) |
| 16 | 0x3EB8AA3B | log2(e)/sqrt(16) |
| 32 | 0x3E8293EE | log2(e)/sqrt(32) |

---

## 8. DDR数据布局

### GEMV
```
VI_BASE: vector[0..cols-1]        （FP32连续）
MI_BASE: matrix行优先[rows][cols]
VO_BASE: output[0..rows-1]         （DUT写回）
```

### FSA（tile-major）
```
Q_BASE: Q[head][dim]                              num_heads×head_dim个FP32
K_BASE: 每tile [head][seq_tile_len行][head_dim列]
        地址 = K_BASE + tile*KV_STRIDE + (h*seq_tile_len*head_dim + r*head_dim + c)*4
V_BASE: 同K布局
O_BASE: O[head][dim]
KV_STRIDE = num_heads × seq_tile_len × head_dim × 4  （seq_tile_len = min(head_dim,32)）
```
注：head_dim>32时 seq_tile_len=32（每tile 32行），与head_dim列数解耦。

---

## 9. 通过/失败判定标准

### GEMV
- PASS：DUT输出与golden逐元素 bit-exact
- TIMEOUT：wait_done超时 → FAIL

### FSA
- PASS：所有元素 rel_err < 5%（rel_err = |dut−golden|/max(|golden|,1e-8)）
- WARN：1%~5%（记录不判FAIL）
- FAIL：任一 ≥5%，或 NaN/Inf，或输出仍为0xDEADBEEF（未写回）

### 通用
- X/Z传播到输出 → FAIL
- FSM hang（TIMEOUT内未done） → FAIL

---

## 10. 仿真控制plusargs

| Plusarg | 默认 | 说明 |
|---------|------|------|
| +UVM_TESTNAME=xxx | 必填 | 选择test |
| +UVM_VERBOSITY=xxx | UVM_MEDIUM | 日志级别 |
| +num_iterations=N | 100/150 | random迭代次数 |
| +soak_rounds=N | 50 | soak轮数 |
| +timeout_cycles=N | 50,000,000 | 全局超时（tb_top） |
| +dump_wave | 关 | dump FSDB波形 |

---

## 11. 已知失败与豁免

FSA regression/random中，seq_len≥250的多tile case存在**PWL精度边界失败**：
- 特征：golden值接近0（<0.1），绝对误差0.001~0.01，相对误差5~25%超5%阈值
- 根因：8段PWL exp2在多tile online-softmax rescale中的累积近似误差，**非硬件功能bug**
- 适用范围：LLaMA2实际推理seq≤256，该精度在真实场景可接受
- 清单见 `docs/agent/constrain.md`（seq250/253/254_32tile、seq511_64tile、seq512_fulltile、
  seq1023_128tile、sweep_48/56/64t_r2、seq320_full）

> 位宽/容量上限边界（seq_len 12-bit截断点、GEMV超SRAM维度、GROUP_MODE=3非法值行为）的
> 系统验证见 `verification_plan.md` 第10章「硬件容量/位宽上限边界填补计划」。

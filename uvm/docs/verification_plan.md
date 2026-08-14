# 验证计划文档 — CB_top_v2 UVM验证

## 1. 验证范围

### 1.1 DUT概述

CB_top_v2是一个双模式硬件加速器，支持：
- **GEMV模式**（Output-Stationary）：矩阵-向量乘法 y = M·x，硬件tile 32×64
- **FSA模式**（Weight-Stationary）：FlashAttention-2，在线softmax，4组并行head

### 1.2 验证层级

本验证计划针对**系统级**（CB_top_v2顶层）黑盒验证。
验证通过AXI接口进行，不依赖DUT内部信号。

### 1.3 验证目标

| 目标 | 度量标准 |
|------|----------|
| 功能正确性 | 所有directed case PASS（GEMV 14 + FSA 88） |
| 随机覆盖 | Constrained random 200+ seeds无failure |
| 功能覆盖率 | 所有covergroup > 90% |
| 协议合规 | AXI事务无协议违规 |
| 鲁棒性 | 错误注入不导致hang或未定义行为 |

---

## 2. Feature List

### 2.1 GEMV模式功能点

| ID | Feature | 描述 | 优先级 |
|----|---------|------|--------|
| G-01 | 基本GEMV | 32×64 单tile矩阵向量乘 | P0 |
| G-02 | 行tiling | rows > 32时多行tile循环 | P0 |
| G-03 | 列tiling | cols > 64时多列tile累加 | P0 |
| G-04 | 行列联合tiling | rows>32 且 cols>64 | P0 |
| G-05 | 边界行数 | rows不是32整数倍（如33, 48） | P0 |
| G-06 | 边界列数 | cols不是64整数倍（如172） | P0 |
| G-07 | 最小维度 | rows=1, cols=1 | P1 |
| G-08 | DMA读正确性 | vector和matrix从DDR正确加载 | P0 |
| G-09 | DMA写正确性 | 输出向量正确写回DDR | P0 |
| G-10 | CSR配置 | 所有GEMV相关CSR可正确读写 | P0 |
| G-11 | 连续执行 | 多次GEMV不复位，状态无残留 | P1 |
| G-12 | 完成信号 | CB_done和STATUS.done正确拉高 | P0 |

### 2.2 FSA模式功能点

| ID | Feature | 描述 | 优先级 |
|----|---------|------|--------|
| F-01 | 单tile attention | seq_len ≤ head_dim（1个KV tile） | P0 |
| F-02 | 多tile attention | seq_len > head_dim（多个KV tile） | P0 |
| F-03 | 在线softmax | max跟踪 + exp2 PWL + rescale正确 | P0 |
| F-04 | head_dim=8 | 8维head计算 | P0 |
| F-05 | head_dim=16 | 16维head计算 | P0 |
| F-06 | head_dim=32 | 32维head计算 | P0 |
| F-07 | 4×8分组模式 | 4组×8PE，4个独立head | P0 |
| F-08 | 2×16分组模式 | 2组×16PE，2个独立head | P0 |
| F-09 | 1×32分组模式 | 1组×32PE，1个head | P0 |
| F-10 | 非整数倍seq_len | seq_len不是head_dim整数倍 | P0 |
| F-11 | 大seq_len | seq_len=160（20 tiles @ d=8） | P1 |
| F-12 | ATTN_SCALE配置 | log2(e)/sqrt(d)正确应用 | P0 |
| F-13 | KV_STRIDE配置 | tile间DDR步长正确 | P0 |
| F-14 | Q/K/V DDR布局 | tile-major布局正确读取 | P0 |
| F-15 | O写回 | 输出正确写回O_BASE | P0 |
| F-16 | 精度 | 相对误差 < 5%（vs fp64 golden） | P0 |
| F-17 | 连续执行 | 多次FSA不复位，状态无残留 | P1 |
| F-18 | head_dim>32 | 双chunk机制（chunk1=32维 + chunk2=head_dim-32），head_dim=48/64 | P1 |

### 2.3 通用功能点

| ID | Feature | 描述 | 优先级 |
|----|---------|------|--------|
| C-01 | 复位 | rst_n正确初始化所有状态 | P0 |
| C-02 | CSR读写 | 所有寄存器可正确访问 | P0 |
| C-03 | STATUS寄存器 | busy/done/error位正确反映状态 | P0 |
| C-04 | 模式切换 | GEMV→FSA→GEMV无状态泄漏 | P1 |
| C-05 | 错误处理 | 非法配置不导致hang | P2 |
| C-06 | AXI协议 | Slave/Master端口符合AXI4规范 | P0 |

---

## 3. 测试矩阵

### 3.1 Feature × Test映射

| Feature | Directed Test | Random Test | Stress/其他 Test |
|---------|--------------|-------------|-------------|
| G-01~G-06 | gemv_regression (14 cases) | gemv_random (100 seeds) | — |
| G-07 | gemv_regression (TC_SingleRow rows=1) | gemv_random | — |
| G-11 | gemv_regression (TC_Stress ×10) | — | dual_mode_stress |
| F-01~F-02 | fsa_regression (96 cases) | fsa_random (150 seeds) | fsa_soak (50 rounds) |
| F-04~F-06 | fsa_regression | fsa_random | — |
| F-07~F-09 | fsa_regression | fsa_random | fsa_soak (3 mode交替) |
| F-10~F-11 | fsa_regression | fsa_random | — |
| F-17 | fsa_residue_impact (FSA→GEMV→FSA) | — | fsa_soak |
| F-18 head_dim>32 | fsa_hd64_test / fsa_hd48_test | — | — |
| C-01 | base_test (reset only) | — | mid_op_reset / precise_fsm_reset |
| C-02 | csr_access_test | — | — |
| C-04 | — | — | dual_mode_stress |
| C-05 | error_injection (4 sub) | — | special_fp_test |

### 3.2 GEMV Directed Case参数表

| Case# | Name | Rows | Cols | 验证重点 |
|--------|------|------|------|----------|
| 1 | Sanity | 32 | 64 | 单tile基本功能 |
| 2 | Identity | 32 | 32 | 单位矩阵（输出=输入） |
| 3 | TwoRowTile | 64 | 64 | 2行tile |
| 4 | ThreeColTile | 32 | 172 | 3列tile（172=64+64+44） |
| 5 | RowBoundary33 | 33 | 64 | 行边界（33=32+1） |
| 6 | RowBoundary48 | 48 | 64 | 行边界（48=32+16） |
| 7 | ColBoundary65 | 32 | 65 | 列边界（65=64+1） |
| 8 | ColBoundary128 | 32 | 128 | 2列tile精确 |
| 9 | LargeSquare | 64 | 128 | 大矩阵（2行×2列tile） |
| 10 | MaxSize | 64 | 172 | 最大支持尺寸 |
| 11 | SingleRow | 1 | 64 | 最小行数 |
| 12 | SmallMatrix | 8 | 32 | 小矩阵 |
| 13 | OddDims | 17 | 100 | 非对齐维度 |
| 14 | StressMultiVec | 32 | 64 ×10次 | 连续执行压力 |

### 3.3 FSA Directed Case参数表

88个case = 3种group_mode × 多种(head_dim, seq_len)组合：

**4×8模式（group_mode=0, head_dim=8, num_heads=4）— 30 cases：**

| Case# | seq_len | 验证重点 |
|--------|---------|----------|
| 1-3 | 1, 4, 8 | 单tile（seq≤dim） |
| 4-6 | 9, 10, 12 | 2 tiles，非整数倍 |
| 7-9 | 15, 16, 17 | 2 tiles边界 |
| 10-12 | 20, 24, 25 | 3 tiles |
| 13-15 | 30, 32, 33 | 4 tiles边界 |
| 16-18 | 40, 48, 50 | 5-7 tiles |
| 19-21 | 60, 64, 72 | 8-9 tiles |
| 22-24 | 80, 96, 100 | 10-13 tiles |
| 25-27 | 120, 128, 140 | 15-18 tiles |
| 28-30 | 150, 155, 160 | 19-20 tiles（最大） |

**2×16模式（group_mode=1, head_dim=16, num_heads=2）— 29 cases：**
- seq_len: 1, 8, 16, 17, 20, 24, 30, 32, 33, 40, 48, 50, 60, 64, 72, 80, 90, 96, 100, 110, 120, 128, 130, 140, 144, 150, 155, 158, 160

**1×32模式（group_mode=2, head_dim=32, num_heads=1）— 29 cases：**
- seq_len: 1, 16, 32, 33, 40, 48, 50, 60, 64, 65, 72, 80, 90, 96, 100, 110, 120, 128, 130, 140, 144, 150, 155, 158, 160, 33, 65, 97, 129

---

## 4. 覆盖目标定义

### 4.1 Covergroup目标

| Covergroup | 目标覆盖率 | 说明 |
|------------|-----------|------|
| cg_mode_config | 100% | 两种模式都必须覆盖 |
| cg_gemv_dims | 90% | rows×cols交叉覆盖 |
| cg_fsa_config | 95% | head_dim×seq_len×group_mode交叉 |
| cg_csr_access | 100% | 所有寄存器×读写方向 |
| cg_stress | 80% | 模式切换transition覆盖 |

### 4.2 代码覆盖率目标

通过VCS `-cm` 选项收集，范围限定为DUT RTL（排除TB和mem_model）：

| 覆盖率类型 | VCS选项 | 目标 | 说明 |
|-----------|---------|------|------|
| Line coverage | `-cm line` | >90% | 代码行执行覆盖 |
| Branch coverage | `-cm branch` | >85% | if/else/case分支覆盖 |
| Condition coverage | `-cm cond` | >80% | 布尔条件组合覆盖 |
| Toggle coverage | `-cm tgl` | >70% | 信号翻转覆盖（端口级） |
| FSM coverage | `-cm fsm` | >95% | 状态机状态/转移覆盖 |

收集范围配置（`uvm/coverage/cov_hier.cfg`）：
- `+tree tb_top.dut` — 仅收集DUT层级
- `-module mem_model` — 排除行为级存储模型

### 4.3 UVM RAL寄存器模型

利用UVM内置寄存器验证sequence自动化CSR验证：
- `uvm_reg_hw_reset_seq` — 自动验证所有寄存器复位值
- `uvm_reg_bit_bash_seq` — 自动对所有RW寄存器逐bit写1/0验证
- RAL mirror通过predictor自动跟踪，供coverage采样当前配置值

### 4.2 Covergroup详细定义

#### cg_mode_config
```
cp_mode: {gemv, fsa} — 目标100%
```

#### cg_gemv_dims
```
cp_rows: bins small=[1:8], mid=[9:32], large=[33:64], boundary={32,33,64}
cp_cols: bins single_tile=[1:64], two_tile=[65:128], three_tile=[129:172], boundary={64,128,172}
cross cp_rows × cp_cols — 目标90%（部分极端组合可豁免）
```

#### cg_fsa_config
```
cp_head_dim: bins {8, 16, 32}（主路径） + {48, 64}（head_dim>32双chunk定向）
cp_seq_len: bins single_tile=[1:dim], multi_2=[dim+1:2*dim], multi_large=[2*dim+1:511], non_aligned
cp_group_mode: bins {0=4×8, 1=2×16, 2=1×32}
cross cp_head_dim × cp_seq_len × cp_group_mode — 目标95%
注：head_dim=48/64 由 fsa_hd48_test/fsa_hd64_test 定向覆盖（1×32模式，chunk2机制）
```

#### cg_dma_behavior（未实现，需axi_mst_monitor）
```
cp_read_burst_len: bins short=[0:3], med=[4:15], long=[16:255]
cp_write_burst_len: bins short=[0:3], med=[4:15], long=[16:255]
cp_bresp: bins ok={0}, err={1,2,3}
cp_rresp: bins ok={0}, err={1,2,3}
```

#### cg_csr_access
```
cp_reg_addr: bins for each CSR address (0x0000~0x0054)
cp_rw: bins {read, write}
cross cp_reg_addr × cp_rw — 目标100%
```

---

## 5. 通过/失败判定标准

### 5.1 GEMV模式

- **PASS条件**：DUT输出与golden相对误差 < 0.1%
  - 相对误差 = |dut - golden| / max(|golden|, 1e-6)
  - 硬件4拍流水累加顺序与SV golden可能有舍入差异，允许小ULP误差
- **精度统计**：每次测试报告max_rel_err、avg_rel_err、max_ULP
- **FAIL条件**：任何元素相对误差 ≥ 0.1%
- **TIMEOUT**：500,000 cycles内CB_done未拉高

### 5.2 FSA模式

- **PASS条件**：所有输出元素相对误差 < 5%
  - 相对误差 = |dut - golden| / max(|golden|, 1e-8)
  - Golden使用fp64标准softmax（DPI-C e2e_golden.c）
- **WARNING**：相对误差在1%~5%之间（记录但不判FAIL）
- **FAIL条件**：任何元素相对误差 ≥ 5%，或输出为NaN/Inf
- **TIMEOUT**：根据seq_len动态调整（大seq_len需要更多cycle）

### 5.3 通用判定

- AXI协议违规（如valid拉高后在ready前撤销）→ ERROR
- STATUS寄存器error位拉高 → 需检查是否为预期错误注入
- 仿真中出现X/Z传播到输出 → FAIL

---

## 6. 风险项和优先级排序

### 6.1 高风险项

| 风险 | 影响 | 缓解措施 | 验证状态 |
|------|------|----------|----------|
| FSA多tile rescale精度累积 | 大seq_len时误差可能超阈值 | 重点覆盖seq_len>100的case | 已验证：150 random全PASS，max_rel_err<1% |
| 模式切换状态残留 | GEMV后FSA结果错误 | dual_mode_stress专项测试 | 已验证：10 rounds PASS |
| FSA连续操作不复位 | FSA→FSA直接连续输出错误 | 每次FSA前hw_reset | **已发现RTL缺陷**：acc_sram/scale残留，详见csr_ral_findings.md |
| DMA burst边界 | 非对齐地址可能导致数据错位 | 随机地址对齐测试 | 已验证：random test覆盖 |
| 分组模式切换 | 不同group_mode间PE映射不同 | 覆盖所有group_mode组合 | 已验证：88 directed + 150 random |

### 6.2 实施优先级

1. **P0（必须）**：GEMV基本功能 + FSA基本功能 + CSR访问
2. **P1（重要）**：连续执行 + 模式切换 + 边界case
3. **P2（增强）**：错误注入 + AXI协议检查 + 覆盖率闭合

---

## 7. 验证环境依赖

| 依赖项 | 来源 | 状态 |
|--------|------|------|
| VCS仿真器 | 远程EDA服务器 | 可用 |
| UVM 1.2库 | VCS内置 | 可用 |
| e2e_golden.c | tb/dpi/ | 已有，直接复用 |
| tb_cb_baseline_ref_pkg | tb/ | 已有，GEMV golden |
| flash_attention_golden.py | tb/golden/ | 已有，生成测试向量 |
| RTL filelist | scripts/fsa_e2e_filelist.f | 已有，作为基础 |

---

## 8. 回归策略

### 8.1 日常回归（每次RTL修改后）

```powershell
powershell -File scripts/run_uvm_remote.ps1 -Mode single -Test gemv_sanity_test
powershell -File scripts/run_uvm_remote.ps1 -Mode single -Test fsa_sanity_test
```
- 快速确认基本功能未破坏，~2min

### 8.2 完整回归（提交前）

```powershell
powershell -File scripts/run_uvm_remote.ps1 -Mode regression
```
- 包含：csr_access + gemv_sanity + gemv_regression + fsa_sanity + fsa_regression + dual_mode_stress
- 预计运行时间：~5min

### 8.3 覆盖率回归（周期性）

```powershell
powershell -File scripts/run_uvm_remote.ps1 -Mode coverage    # 6 test合并（默认）
make -f Makefile.vcs run_uvm_cov_full                          # 12 test合并（含reset/soak/special_fp/residue，FSM可达91.67%）
```
- `run_uvm_cov_full` 合并12个test（directed + random + error_inj + mid_reset + precise_reset + special_fp + residue + soak）
- 自动生成urg合并报告 + 拉回cov_report/目录
- 预计运行时间：~15min

### 8.4 全量回归（签核）

```powershell
powershell -File scripts/run_uvm_remote.ps1 -Mode full
```
- 全部16个test（含 fsa_hd48/hd64 head_dim>32 定向），~25min

---

## 9. 实际覆盖率结果（2026-06-03 更新，12 test合并）

### 9.1 代码覆盖率（run_uvm_cov_full 12 test合并）

| 类型 | 实际值 | 目标 | 状态 |
|------|--------|------|------|
| Line | 89.34% | >90% | Waiver后达标（DMA 23行参数化死代码，差0.66%） |
| Condition | 83.21% | >80% | 达标 |
| Toggle | 91.34% | >70% | 达标 |
| FSM | 91.67% | >95% | Waiver后达标（极短状态复位转移，差3.3%） |
| Branch | 86.56% | >85% | 达标 |

> 覆盖率随RTL演进（head_dim>32 chunk机制、Score FIFO复用Vec SRAM、DMA prefetch）多次重新收集，
> 上表为当前RTL的最新口径。历史提升历程见9.4。

### 9.2 功能覆盖率

| Covergroup | 实际值 | 目标 | 状态 |
|------------|--------|------|------|
| 合并(cg_*) | 95.19% | >90% | 达标 |

### 9.3 覆盖率空洞分析

| 模块 | 问题 | 根因 | 处理方式 |
|------|------|------|----------|
| axi_dma_controller Line | 23行未覆盖 | 参数化死代码（DATA_WD=AXI_DATA_WIDTH=32, 窄传输不触发） | Waiver W-001 |
| FSM转移 7.5%未覆盖 | 极短状态(1-2拍)复位转移 | 精准reset无法命中 | Waiver W-002 |
| multiplication_normaliser | toggle 3.57% | subnormal/特殊FP flush-to-zero后内部分支不激活 | 结构性限制 |

### 9.4 覆盖率提升历程

| 阶段 | FSM | 措施 |
|------|-----|------|
| 初始 | 54.74% | 7 test（无reset test） |
| +死代码清理 | 55.91% | 删除S_ERROR/S_DMA_Q等死状态 |
| +FSM重编号 | 55.91% | 连续编号（无效） |
| +mid_op_reset | 67.74% | 23个时间点mid-op reset |
| +precise_fsm_reset | **92.47%** | backdoor读state精准触发 |

### 9.4 后续迭代方向

1. FSM覆盖率：确认S_ERROR是否为dead code，若是则排除（waiver）
2. Line 88→90%：添加error路径激活sequence
3. 特殊FP值：添加subnormal/denormal/max/min数据激励
4. fsa_trans_merge：分析具体条件，添加targeted case

---

## 10. 硬件容量/位宽上限边界验证填补计划

### 10.1 背景与定位

现有验证覆盖了**功能tiling边界**（rows=33、cols=172、seq非整数倍、head_dim=48/64），
但RTL对所有CSR写入**零范围检查/零饱和**，物理位宽与容量上限从未被系统打满。
每个上限测试的签核价值是确认三种结局之一：
① 正常处理（位宽够用）② 优雅截断/拒绝（有保护）③ **静默溢出错误（← 签核要抓的缺陷）**。

判定原则：位宽/功能失败（hang、计数器溢出、地址错乱、NaN/Inf）与已知PWL精度失败
（golden接近零时相对误差>5%）必须**解耦判定**——前者是签核硬门槛，后者走waiver。

### 10.2 位宽/容量上限清单（RTL事实）

| 资源 | 位宽/容量上限 | 当前最高测到 | 缺口 |
|------|--------------|------------|------|
| seq_len | `csr_seq_len[11:0]`=4095（12bit截断） | 511 | 1024/2048/4095/**4096翻转点** |
| tile数 | 13-bit计数（seq_tile=32时最多128 tiles） | ~16 tiles | 128 tiles满载 |
| head_dim | `[7:0]`，硬件实测上限64（Output/ACC SRAM深度锁死） | 64 ✓ | 65越界行为 |
| ROWS(GEMV) | 32-bit，**无硬件tiling上限保护** | 64 | 128/256行 |
| COLS(GEMV) | 32-bit，靠列tiling | 172 | 512/1024大列tiling |
| DMA cmd_len | `[10:0]`=2047，软件封顶1024 | ~1024 | 1024边界（最大burst） |
| GROUP_MODE | 2-bit，无合法值检查 | 0/1/2 | 值3（非法）行为定性 |

### 10.3 测试用例 `perf_limit_test`（已执行，2026-07-11）

前置：仿真DDR模型`MEM_AW` 18→24（1MB→64MB），使边界case能跑到硬件真实上限
（原1MB下地址越界会返回X，曾误导出"全X需RTL保护"的错误结论，见10.6）。

| Sub-case | 配置 | 实测结果 | 结论 |
|----------|------|---------|------|
| PL-01 大seq满tile | 1×32, seq_len=4064（127 tiles） | ✅ FSM正常收尾, 0 NaN/Inf | 13-bit tile计数器在硬件上限127不溢出 |
| PL-02 seq_len截断点 | seq_len=4096（[11:0]截断成0） | ✅ 修复后0 polls响应 | **发现真bug→方案A已修**（见下） |
| PL-03 大seq | 1×32, seq_len=2048（64 tiles） | ✅ FSM正常收尾 | 功能OK |
| PL-04 GEMV列扫描 | cols=256/511/512 | ✅256 ✅511 ⚠512错 | **发现真上限cols≤511**（见下） |
| PL-05 GEMV大行 | rows=256, cols=64 | ✅ 256行全写回, 无X | ROWS超64能正常处理 |
| PL-06 head_dim越界 | 1×32, head_dim=65 | ✅ 无X传播, 正常响应 | 越界输入DUT稳健 |
| PL-07 GROUP_MODE=3 | 非法group_mode | ✅ 无X传播, 正常响应 | default分支不崩，激活default覆盖率 |

### 10.4 数值域边界 `special_fp_test` 扩展（NF-01~08，已执行）

| Case | 输入 | 实测 | 结论 |
|------|------|------|------|
| NF-01 inf输入 | 向量含±inf | out=0x7f800000 | inf正确传播 |
| NF-02 inf+(−inf) | 累加inf-inf | out=−inf（定性记录） | 传播非NaN |
| NF-03 max×max溢出 | FP_POS_MAX累加 | out=NaN（定性记录） | overflow归一化产NaN |
| NF-04 ±0累加 | +0/−0混合 | 有限值 | 符号规则正常 |
| NF-05 NaN输入 | 含quiet NaN | NaN正确传播 | isNaN路径激活 |
| NF-06 PWL 4段扫描 | score递增4量级 | 4个有限值 | exp2逐段激活 |
| NF-07/08 softmax极端 | one-hot/均匀分布 | 有限值 | rescale路径正常 |

**覆盖率收益（16-test合并 vs 之前12-test）**：Line 89.34→**91.08%**（首次过90%），
Toggle 91.34→**95.35%**（NF激活normaliser归一化bit），Cond 83.21→86.57%。验证了
"数值域边界是提覆盖率的有效方向"这一预判。

### 10.5 两个真实发现与修复

**发现1（真bug，已修）：seq_len=0/4096 → FSM HANG**
- 根因：`csr_seq_len[11:0]`12位截断，4096→0→num_kv_tiles=0，FSM在S_FSA_WAIT_K因
  门槛`tile_idx<num_tiles`(0<0=false)永不发DMA、`fsa_done`永不来→死锁
- 修复（方案A）：`cb_controll_v2.sv` S_IDLE检测`fsa_num_kv_tiles_w==0`时直接跳S_DONE，
  不进FSA流程。零软件/测试改动，PL-02重跑0 polls响应，full回归无回归

**发现2（文档bug，已修文档）：GEMV cols≥512 计算错误**
- 根因：`cmd_stride`/`cmd_len`均11-bit（2047B=511元素），cols=512→stride=2048溢出成0
  →所有行读同一DDR地址。单变量对照证实：cols=256/511 PASS，512 FAIL(rel 376%)，
  且512时多行DUT输出相同值0x4104060c（自洽）
- 判定：11-bit是**自洽的设计上限**（两个跨维度字段位宽一致），文档`fsa_programmer_guide.md`
  原写"COLS无限制"是过度承诺 → 已订正为"COLS≤511"。LLaMA实际列宽≤511不受影响

### 10.6 教训：test bug曾误报为RTL缺陷

首轮跑PL-04/05/06/07时用了越界地址（VO=0x0200_0000 超原1MB DDR），backdoor越界返回X，
误导出"输出全X需RTL保护"的结论。DDR扩到64MB后重跑，这些"全X"全部消失——**是test地址
bug，非RTL缺陷**。教训：边界test必须先确认仿真基础设施（DDR容量）能容纳激励，否则
基础设施伪影会被误判为DUT缺陷。此为"先取证再下结论"方法论的正面案例（未据首轮误报改RTL）。

---

## 11. 数值域边界深化计划

### 11.1 定位：与容量边界的区别

边界case有三个正交维度，覆盖率影响不同：

| 边界维度 | 含义 | 现状 | 对代码覆盖率的影响 |
|---------|------|------|------------------|
| 容量/位宽（§10） | seq_len/rows/cols/head_dim物理上限 | 弱（PL计划） | **低**（同路径不同迭代次数，无新分支） |
| **数值域（本章）** | FP32的subnormal/±inf/±0/max/NaN/进位归一化 | 部分（special_fp_test） | **高**（激活arithmetic模块特殊值分支） |
| 配置（§10 PL-07） | 非法配置组合（GROUP_MODE=3） | 弱 | **高**（激活default分支） |

**关键**：容量边界喂大数值走同一段tile循环代码，不提覆盖率；数值域边界喂特殊值激活FP单元
内部的归一化/特殊值分支，是把 Line 推过90%、修复 `multiplication_normaliser` toggle 3.57%
的**唯一有效方向**。

### 11.2 现有special_fp_test缺口（RTL事实核对）

| 缺口 | 现状 | 影响 |
|------|------|------|
| **±inf作输入** | `FP_POS_INF`/`FP_NEG_INF`已声明但**从未写入DDR** | inf输入的归一化/饱和分支未激活 |
| **NaN作输入** | 完全无NaN（`7FC00000`等） | NaN传播路径（FPMacUnit/CMP的isNaN分支）零覆盖 |
| **exp2 PWL分段边界** | FSA只喂统一的`FP_TINY` | 8段PWL的段边界（每段分界点）未逐段命中 |
| **inf−inf / inf×0** | 无 | FP运算的非规约结果分支（产生NaN）未测 |
| **max×max溢出** | GEMV有`4F000000`累加，但非FP_POS_MAX | 真正的overflow-to-inf归一化分支覆盖弱 |
| **混合符号±0** | 有±0但未验+0/−0在加法中的符号规则 | 符号归一化分支 |

### 11.3 新增/扩展sequence计划

**扩展 `special_fp_gemv_seq`（激活FP归一化分支）：**

| Case | 输入 | 意图 | 期望 |
|------|------|------|------|
| NF-01 inf输入 | 向量含±inf，矩阵正常 | inf×正常数=inf传播 | 输出inf，不产生X |
| NF-02 inf−inf | 构造使累加出现inf+(−inf) | 产生NaN的分支 | 输出NaN（定性，记录行为） |
| NF-03 max溢出 | FP_POS_MAX×FP_POS_MAX累加 | overflow→inf归一化 | 输出inf |
| NF-04 ±0符号 | +0和−0混合累加 | 加法符号规则 | 符合IEEE754 |
| NF-05 NaN传播 | 输入含NaN | isNaN分支+传播 | 输出NaN不crash |

**扩展 `special_fp_fsa_seq`（exp2 PWL分段覆盖）：**

| Case | 输入设计 | 意图 |
|------|---------|------|
| NF-06 PWL分段扫描 | Q·K score精心构造，使(S−max)×scale落在8段PWL每一段 | 逐段激活exp2查找表分支 |
| NF-07 score极大差 | 一个score远大于其余（softmax趋近one-hot） | max跟踪+rescale极端路径 |
| NF-08 score全相等 | 所有score相同（softmax=均匀分布） | 无rescale路径 |

### 11.4 判定原则

- **数值域case同样"位宽/功能"与"精度"解耦**：inf/NaN是否正确传播=功能门槛（不出X、不hang）；
  数值是否精确=精度（IEEE754参考，非5%阈值）
- NF-02/05（产生NaN）是**定性case**：记录DUT实际行为，签核决定NaN处理策略是否符合预期

### 11.5 预期覆盖率收益

| 目标 | 当前 | 预期 | 依据 |
|------|------|------|------|
| Line | 89.34% | ~90%+ | inf/NaN激活FPMacUnit/normaliser未覆盖行 |
| Toggle (multiplication_normaliser) | 3.57% | 显著提升 | subnormal/inf/max翻转归一化逻辑各bit |
| Branch | 86.56% | 微增 | isNaN/isInf/overflow判断分支 |

**这是把Line推过90%目标的最高性价比方向**（远优于容量边界case）。

### 11.6 实施优先级

1. **P0**：NF-01/03/05（inf/max/NaN基本传播）——直接激活覆盖率缺口，快速验收
2. **P1**：NF-06 PWL分段扫描——需要反推score构造，工作量大但对FSA精度签核有价值
3. **P2**：NF-02/04/07/08——补全IEEE754语义边界


# FSA 加法器双周期化（关闭 bypass_s1）时序优化计划

## 背景与动机

### 问题
SoC 综合（xc7a200t）关键路径 WNS = **-8.368ns**（sys_clk，period=20ns）。
关键路径位于 PE 浮点单元，起点 `exp2_pipe_reg[3]`，终点 `fpadd_seq_2stage` 的 `O_reg`。

### 根因
FSA 模式下 `fpadd_seq_2stage` 的 `bypass_s1=1`，旁路了 stage1→stage2 之间的 R1 寄存器，
导致 **对阶+尾数加（stage1）+ LZD归一化（stage2）合并成一拍**，加上上游 EXP2 指数加 +
FPMacUnit 溢出判断也串入同一周期，形成 39 级逻辑长链。

权威依据（`rtl/PE/RawFloat_FMA_LA.sv` 文件头注释）：
- OS 模式：MAC 内部 4 拍（mul×2 + fpadd stage1 + stage2）
- FSA 模式：MAC 内部 3 拍（mul×2 + fpadd bypass 合并）

### 与 transposer 消除无关
改动前后 WNS 完全相同（-8.368ns），此路径是 PE 浮点流水的历史遗留问题。

---

## 优化方案

关闭 FSA 模式的 `bypass_s1`，让 fpadd 走满 stage1→R1→stage2 两级流水。
- FSA MAC 内部延迟：3 拍 → 4 拍
- FSA 总 MAC_LATENCY（含输入寄存 1 拍）：4 → 5
- 关键路径 stage1/stage2 拆开，逻辑级数约砍半，预估 WNS 改善到 ~-3ns

### 资源成本（已评估，划算）
- PE 内延迟匹配 `delay_sr`：深度 ∝ MAC_LATENCY，+25%，约 **+7000 FF**
- 组间预延迟 `pre_bram`：2 的幂向上取整吸收，BRAM 增量 ≈ 0
- LUT 增量：极小（delay_sr 是纯 FF）
- **关键：瓶颈资源是 LUT（71%），FF 仅 18%，+7000 FF 后约 20%，不碰紧张的 LUT**

---

## 完整改动清单

### A. 关闭 bypass（源头，1 处）
`rtl/PE/PE_retimed.sv:339`
```verilog
.bypass_s1 (~os_mode)   →   .bypass_s1 (1'b0)
```
注意：`.use_pre_add(os_mode)` **保持不变**（OS 累加环路，与 bypass 无关）。

### B. PE_retimed commit 索引 +1（FSA 分支，4 处）
FSA MAC 延迟 +1 拍，所有 commit 锚点从 pipe[2] → pipe[3]：
`rtl/PE/PE_retimed.sv`
```
line 156: mac_acc_ui_pipe[2]     → mac_acc_ui_pipe[3]      (FSA分支)
line 158: mac_update_reg_pipe[2] → mac_update_reg_pipe[3]  (FSA分支)
line 160: mac_exp2_pipe[2]       → mac_exp2_pipe[3]         (FSA分支)
line 164: mac_valid_pipe[2]      → mac_valid_pipe[3]        (FSA分支, mac_commit_point)
```
注：这些 pipe 是 6-bit（`reg [5:0]`），索引 3 在范围内，无需扩位。

### C. mac_pipe_busy 窗口扩展（1 处）
`rtl/PE/PE_retimed.sv:89`
```verilog
mac_pipe_busy = os_mode ? |mac_valid_pipe[5:0] : |mac_valid_pipe[2:0]
                                              → : |mac_valid_pipe[3:0]
```

### D. MAC_LATENCY 参数 4 → 5（FSA，多处，须全改一致）
```
rtl/mac_top_v2.sv:22          parameter MAC_LATENCY = 4 → 5
rtl/PE_core_v2.sv:20          parameter MAC_LATENCY = 4 → 5
rtl/fsa/fsa_ctrl_fsm.sv:21    parameter MAC_LATENCY = 4 → 5
rtl/CB_top_v2.v:497           .MAC_LATENCY(4) → (5)
```
注意：`OS_MAC_LATENCY=7` **保持不变**（OS 模式未改）。
mac_top.v（旧版，GEMV-only 路径）的 MAC_LATENCY 不在 FSA 路径，**不改**。

### E. GROUP_PRE_DELAY 改为参数化公式（消除硬编码风险点，1 处）
`rtl/fsa/fsa_ctrl_fsm.sv:153-155`

原硬编码 96/32/0 对应 PE_core 的 QK_PRE = (NUM_GROUPS-1-组)×GROUP_SIZE×MAC_LATENCY。
PE_core 侧是参数化（自动随 MAC_LATENCY 变），FSM 侧原是硬编码（必须手动同步，最易漏改）。

**更优方案：FSM 侧也改成参数化公式，与 PE_core 自动同步，以后改 MAC_LATENCY 无需手动维护。**

物理含义：顶部逻辑组的组间预延迟 = (逻辑组内物理组数 - 1) × GROUP_SIZE × MAC_LATENCY
其中 逻辑组内物理组数 = eff_group_size / GROUP_SIZE，化简：
```verilog
GROUP_PRE_DELAY = (eff_group_size - GROUP_SIZE) * MAC_LATENCY
```

验证对现有值（LAT=4）完全吻合：
| 模式 | eff_group_size | (eff-8)×4 | 原硬编码 |
|------|------|------|------|
| 4×8  | 8  | 0  | 0  ✓ |
| 2×16 | 16 | 32 | 32 ✓ |
| 1×32 | 32 | 96 | 96 ✓ |

改为公式后，LAT=5 自动得到 0/40/120，无需手动修改。**这是比手改 120/40/0 更稳健的做法**：
```verilog
// 组间预延迟 = (逻辑组内物理组数-1) × GROUP_SIZE × MAC_LATENCY
//            = (eff_group_size - GROUP_SIZE) × MAC_LATENCY
wire [8:0] GROUP_PRE_DELAY = (eff_group_size - GROUP_SIZE) * MAC_LATENCY;
```
位宽 [7:0]→[8:0]：LAT=5 时 1×32 = 120 仍 < 256，但与下游 QK_DRAIN_CYCLES（[8:0]）保持一致。

### F. 注释更新（非功能，可选）
- `RawFloat_FMA_LA.sv` 文件头：FSA 模式改为 4 拍
- FSM 各处注释里的 drain 拍数示例（如 line 159「4×8:4×8=32」→ 5×8=40 等）

### G. soc 副本同步
改完上述 rtl/ 文件后，同步到 `soc/rtl/ip/gemv_accel/`：
- PE_retimed.sv、mac_top_v2.sv、PE_core_v2.sv、fsa_ctrl_fsm.sv、CB_top_v2.v

---

## 自动传播 vs 手动改动（区分风险）

**自动随 MAC_LATENCY 传播（改参数即生效，低风险）：**
- PE_core_v2: MAX_DELAY、QK_PRE、PV_PRE、DELAY_FWD、DELAY_REV、U_EXP2_DEPTH、UNIFIED_DEPTH（全是 MAC_LATENCY 公式）
- FSM: QK_DRAIN_CYCLES、PV_DRAIN_CYCLES（MAC_LATENCY 公式）

**已改为参数化（消除硬编码风险）：**
- FSM GROUP_PRE_DELAY：硬编码 96/32/0 → 公式 `(eff_group_size - GROUP_SIZE) * MAC_LATENCY`，自动随 MAC_LATENCY 同步

---

## 验证计划

### Step 1: 功能回归（必须全过）
```powershell
# FSA E2E（88 cases，基线 4x8:38/9, 2x16:44/2, 1x32:44/2）
powershell -File scripts/run_vcs_remote.ps1 -Top tb_fsa_e2e -Filelist ./scripts/fsa_e2e_filelist.f -Target run_fsa_all

# GEMV（14 cases，须全 PASS，确认 OS 模式未受影响）
powershell -File scripts/run_vcs_remote.ps1 -Top tb_CB_top_v2_gemv -Filelist ./scripts/cb_top_v2_gemv_filelist.f -Target run_gemv_all

# UVM 全量（14 tests）
powershell -File scripts/run_uvm_remote.ps1 -Mode full
```
通过标准：FSA E2E 回到基线（38/9/44/2/44/2），GEMV 14/14，UVM 14/14。

### Step 2: 综合验证 WNS（只综合，不下板）
```powershell
powershell -File scripts/run_soc_bitgen_remote.ps1 -RemoteHost eda -Name fsa_2cyc_adder
```
观测 `reports/soc_bitgen/.../timing_summary_synth.rpt` 的 sys_clk WNS。
对比基线 -8.368ns，预期改善到 ~-3ns 量级。

### 决策点
- 若 WNS 显著改善（如 < -4ns）→ 方案有效，可继续 impl + 全流程
- 若 WNS 仍很差（瓶颈转移到 EXP2+溢出那段）→ 需进一步在 FPMacUnit 出口加流水级，再评估

---

## 风险与回退

- **风险 1**：commit 时序 +1 漏改某处 → FSA 功能错。缓解：Step 1 全回归严格比对基线。
- **风险 2（已消除）**：GROUP_PRE_DELAY 原硬编码已改为参数化公式 `(eff_group_size-GROUP_SIZE)*MAC_LATENCY`，自动随 MAC_LATENCY 同步，不再有漏改失配风险。仍建议回归重点看 2×16/1×32 模式。
- **风险 3**：WNS 改善不及预期（瓶颈在 EXP2 段）→ 仅 Step 2 综合花费，无下板成本。
- **回退**：所有改动集中在 PE_retimed/PE_core_v2/mac_top_v2/fsa_ctrl_fsm/CB_top_v2，git 可一键回退。

---

## 改动文件汇总

| 文件 | 改动 | 风险 |
|------|------|------|
| rtl/PE/PE_retimed.sv | bypass_s1=0 + 4处commit索引+1 + busy窗口 | 高 |
| rtl/mac_top_v2.sv | MAC_LATENCY 4→5 | 中 |
| rtl/PE_core_v2.sv | MAC_LATENCY 4→5 | 中 |
| rtl/fsa/fsa_ctrl_fsm.sv | MAC_LATENCY 4→5 + GROUP_PRE_DELAY 改参数化公式 | 中 |
| rtl/CB_top_v2.v | .MAC_LATENCY(4)→(5) | 低 |
| soc/rtl/ip/gemv_accel/* | 同步上述 5 文件 | — |

---

## 当前进度（待审核）

已改动（待你确认）：
- ✅ `rtl/fsa/fsa_ctrl_fsm.sv` GROUP_PRE_DELAY 改为参数化公式 `(eff_group_size-GROUP_SIZE)*MAC_LATENCY`（位宽 [7:0]→[8:0]）
- ✅ `rtl/PE/PE_retimed.sv` 4 处 commit 索引 [2]→[3]（line 156/158/160/164）

待改动（审核通过后继续）：
- ⬜ PE_retimed.sv:89 busy 窗口 [2:0]→[3:0]
- ⬜ PE_retimed.sv:339 bypass_s1 ~os_mode→1'b0
- ⬜ MAC_LATENCY 4→5（mac_top_v2 / PE_core_v2 / fsa_ctrl_fsm / CB_top_v2）
- ⬜ soc 副本同步
- ⬜ 注释更新

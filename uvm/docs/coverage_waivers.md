# 覆盖率Waiver记录

## 概述

本文档记录所有覆盖率exclusion（waiver），说明排除原因和正当性。
所有waiver必须有明确的技术理由，不得用于掩盖真实功能缺陷。

---

## 1. Line Coverage Waiver — axi_dma_controller窄传输路径

| 项目 | 内容 |
|------|------|
| 模块 | axi_dma_controller |
| 行号 | 479-527（23行） |
| 功能 | 窄传输strobe生成（cmd_size=2/4/8/16时的wstrb分拍逻辑）+ w_trans_num递增 |
| 排除原因 | **参数化死代码**。系统配置DATA_WD=32, AXI_DATA_WIDTH=32，TRANS_PER_DATA=1，一个字只需1拍传输。cmd_size始终=1，w_trans_num永远不递增，wstrb分拍逻辑永远不触发。 |
| 正当性 | DMA控制器是通用参数化设计，支持64/128位总线配置。在当前32位配置下这些路径不可达，不是功能遗漏。 |
| 影响 | 排除后Line从88.73%提升至~90%+ |

---

## 2. FSM Coverage Waiver — 极短状态复位转移

| 项目 | 内容 |
|------|------|
| 模块 | CB_Controller_v2, fsa_ctrl_fsm |
| 转移 | 剩余`S_XXX→S_IDLE`复位转移（精准FSM reset无法命中的极短状态） |
| 排除原因 | **结构性不可测**。某些状态持续时间极短（1-2拍），即使用精准定时reset（backdoor读state后立即复位），由于uvm_hdl_deposit的延迟仍可能miss。这些转移在功能上等价于其他已验证的复位转移（复位逻辑对所有状态统一处理）。 |
| 正当性 | (1) 复位逻辑是统一的`if(!rst_n) state<=S_IDLE`，不区分源状态。(2) mid_op_reset_test已验证9个GEMV + 9个FSA时间点全PASS。(3) precise_fsm_reset_test精确命中大部分状态验证。 |
| 前提条件 | precise_fsm_reset_test必须先PASS，确认可命中状态的复位行为正确 |

---

## 3. 不做Waiver的项目（需要通过激励改进覆盖）

| 项目 | 当前覆盖 | 改进方向 |
|------|----------|----------|
| multiplication_normaliser toggle | 3.57% | 添加特殊FP值激励（subnormal/denorm） |
| fsa_trans_merge condition | 0% | 分析具体未覆盖条件组合 |

---

## Waiver审批

| 日期 | Waiver# | 审批人 | 状态 |
|------|---------|--------|------|
| 2026-05-31 | W-001 DMA窄传输 | 待确认 | 提出 |
| 2026-05-31 | W-002 极短状态复位 | 待确认 | 提出（依赖precise_fsm_reset_test结果） |

---

## 附录：如何通过Verdi生成.el排除文件

### 前置条件
- 已有覆盖率数据库（`simv_uvm_cov.vdb`）
- 远程EDA服务器上有Verdi license

### 操作步骤

#### Step 1: 启动Verdi Coverage模式

```bash
cd ~/gemv_fsa_uvm
verdi -cov -covdir simv_uvm_cov.vdb &
```

如果需要X11转发（从Windows连接）：
```powershell
# 本地先启动X server（如MobaXterm/VcXsrv）
ssh -X eda
cd ~/gemv_fsa_uvm
verdi -cov -covdir simv_uvm_cov.vdb &
```

#### Step 2: 查看Line Coverage

1. 左侧面板选择 **Coverage → Line**
2. 在模块树中展开 `tb_top → dut → u_axi_dma_controller`
3. 右侧代码视图中，**红色行** = 未覆盖，**绿色行** = 已覆盖

#### Step 3: 排除（Exclude）目标行

1. 选中未覆盖的红色行（可按住Shift多选479-527行）
2. 右键 → **Exclude**（或菜单 Coverage → Exclude Selected）
3. 弹出对话框填写：
   - **Reason**: `参数化死代码: DATA_WD=AXI_DATA_WIDTH=32, TRANS_PER_DATA=1, 窄传输逻辑不可达`
   - **Comment**: `W-001`
4. 点击 OK

#### Step 4: 排除FSM转移

1. 左侧面板选择 **Coverage → FSM**
2. 展开 `CB_Controller_v2 → state`
3. 在Transition表格中找到 `Not Covered` 的行（如 `S_ACCUMULATE→S_IDLE`）
4. 右键 → **Exclude**
5. Reason: `极短状态复位转移: 该状态持续<3拍, 精准reset无法命中, 复位逻辑统一验证已覆盖`

#### Step 5: 导出.el文件

1. 菜单 **Coverage → Save Exclusion File...**
2. 保存路径: `~/gemv_fsa_uvm/uvm/coverage/cov_exclusion.el`
3. 勾选 **All Exclusions**
4. 点击 Save

#### Step 6: 验证排除效果

```bash
cd ~/gemv_fsa_uvm
urg -dir simv_uvm_cov.vdb -elfile ./uvm/coverage/cov_exclusion.el -report cov_report_waived -format text
cat cov_report_waived/dashboard.txt
```

预期效果：
- Line: 88.33% → >90%（排除23行DMA死代码）
- FSM: 92.47% → >95%（排除极短状态复位转移）

#### Step 7: 拉回.el文件到本地

```powershell
scp eda:~/gemv_fsa_uvm/uvm/coverage/cov_exclusion.el uvm/coverage/cov_exclusion.el
git add uvm/coverage/cov_exclusion.el
git commit -m "coverage: Verdi导出的exclusion file（W-001 DMA + W-002 FSM）"
```

### 常用Verdi Coverage快捷操作

| 操作 | 方法 |
|------|------|
| 查看未覆盖行 | Coverage → Line → 点击模块 → 红色行 |
| 查看未覆盖转移 | Coverage → FSM → Transition Tab → Not Covered |
| 批量排除 | 多选 → 右键 → Exclude |
| 撤销排除 | 右键已排除项 → Include |
| 查看排除列表 | Coverage → Show Exclusions |
| 导出报告 | Coverage → Generate Report → Text/HTML |

### 注意事项

1. `.el`文件是二进制格式（VCS版本相关），不要手动编辑
2. 每次RTL改动后需要重新生成覆盖率数据库，旧的.el文件可能行号失效
3. 排除前务必确认该行确实不可达（不是激励不足），避免虚假waiver
4. 所有排除必须在`coverage_waivers.md`中有对应的文字记录和理由

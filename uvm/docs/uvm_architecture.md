# UVM验证环境架构文档 — CB_top_v2

## 1. 概述

本文档描述CB_top_v2双模式加速器（GEMV + FlashAttention）的UVM验证环境架构。
验证目标是在系统级（CB_top_v2顶层）进行黑盒验证，通过AXI接口驱动配置和观测DMA行为，
复用已有DPI-C golden model进行结果比对。

---

## 2. 环境组件层次图

```
uvm_test (cb_top_base_test)
  |
  +-- cb_top_env (uvm_env)
  |     |
  |     +-- axi_slv_agent (Active)
  |     |     +-- axi_slv_sequencer
  |     |     +-- axi_slv_driver        ← 驱动AXI Slave端口（模拟CPU写CSR）
  |     |     +-- axi_slv_monitor       ← 监控CSR事务
  |     |
  |     +-- mem_model (Reactive AXI Slave)
  |     |     +-- 关联数组存储           ← 行为级DDR
  |     |     +-- AXI响应逻辑           ← 响应DUT DMA读/写请求
  |     |     +-- backdoor API          ← 供sequence预加载/读取数据
  |     |
  |     +-- axi_mst_monitor (Passive)
  |     |     +-- DMA事务捕获           ← 监控Master端口AR/R/AW/W/B
  |     |     +-- analysis_port         ← 发布到coverage/scoreboard
  |     |
  |     +-- cb_csr_reg_block (UVM RAL)
  |     |     +-- 18个uvm_reg实例      ← CSR寄存器抽象模型
  |     |     +-- default_map           ← 地址映射（0x0000~0x0054）
  |     |
  |     +-- cb_axi_reg_adapter
  |     |     +-- reg2bus / bus2reg     ← uvm_reg_bus_op ↔ axi_slv_seq_item
  |     |
  |     +-- uvm_reg_predictor #(axi_slv_seq_item)
  |     |     +-- bus_in               ← 接收monitor AP，自动更新RAL mirror
  |     |
  |     +-- cb_top_scoreboard (uvm_scoreboard)
  |     |     +-- gemv_checker          ← FP32 bit-exact比对
  |     |     +-- fsa_checker           ← FP64容差比对（rel_err < 5%）
  |     |     +-- ref_model接口         ← 调用DPI-C golden
  |     |
  |     +-- cb_top_ref_model (uvm_component)
  |     |     +-- DPI-C wrapper         ← 封装e2e_golden.c / gemv_golden
  |     |
  |     +-- cb_func_coverage (uvm_subscriber)
  |     |     +-- cg_mode_config        ← 模式覆盖（gemv/fsa）
  |     |     +-- cg_gemv_dims          ← GEMV rows×cols交叉
  |     |     +-- cg_fsa_config         ← FSA head_dim×seq_len×group_mode交叉
  |     |     +-- cg_csr_access         ← CSR地址×读写方向
  |     |     +-- cg_stress             ← 模式切换transition bins
  |     |
  |     +-- cb_top_virtual_seqr (uvm_sequencer)
  |           +-- axi_slv_seqr handle   ← 统一调度CSR sequence
  |           +-- mem_model handle      ← 数据预加载接口
  |
  +-- cb_top_config (uvm_object)        ← 环境配置（容差、模式、超时）
```

---

## 3. 数据流图

### 3.1 激励路径（Stimulus Path）

```
Test
  |
  v
Virtual Sequence (gemv_base_seq / fsa_base_seq)
  |
  |-- (1) 通过mem_model backdoor预加载DDR数据（matrix/vector 或 Q/K/V）
  |
  |-- (2) 通过axi_slv_sequencer发送CSR写sequence
  |         |
  |         v
  |     axi_slv_driver → AXI Slave端口 → DUT (cb_controll_v2 CSR)
  |
  |-- (3) 写CTRL寄存器启动计算
  |
  |-- (4) 轮询STATUS或等待CB_done
  |
  v
DUT开始DMA读写 → mem_model响应读请求（返回预加载数据）
                → mem_model捕获写请求（存储输出结果）
```

### 3.2 检查路径（Checking Path）

```
CB_done拉高 / STATUS.done=1
  |
  v
Scoreboard触发比对
  |
  |-- (1) 从mem_model backdoor读取O_BASE区域的DUT输出
  |
  |-- (2) 调用ref_model计算golden期望值
  |         |
  |         +-- GEMV: matvec_golden_dense(matrix, vector, rows, cols)
  |         +-- FSA:  dpi_e2e_compute() → dpi_e2e_compare()
  |
  |-- (3) 逐元素比对
  |         |
  |         +-- GEMV: bit-exact (==)
  |         +-- FSA:  |dut - golden| / |golden| < 0.05
  |
  v
报告PASS/FAIL + 精度统计
```

### 3.3 覆盖率采集路径（Coverage Path）

```
axi_slv_monitor → analysis_port → reg_predictor（自动更新RAL mirror）
                                → cb_func_coverage（功能覆盖率采样）

采样时机：
  cg_csr_access: 每笔CSR事务都采样（addr × rw）
  cg_mode_config/cg_gemv_dims/cg_fsa_config/cg_stress:
    仅在写CTRL.start=1时采样，从RAL mirror读取当前配置值

代码覆盖率（VCS内置，编译时-cm选项开启）：
  line + branch + cond + tgl + fsm → 仅收集DUT RTL（cov_hier.cfg排除TB）
```

---

## 4. 各组件职责说明

### 4.1 cb_top_env

顶层环境容器，负责：
- 实例化所有agent、scoreboard、coverage、ref_model
- 通过config_db传递配置
- 连接analysis port（monitor → scoreboard/coverage）

### 4.2 axi_slv_agent（Active）

模拟CPU侧，通过AXI Slave端口访问DUT的CSR寄存器。

| 子组件 | 职责 |
|--------|------|
| axi_slv_seq_item | 事务对象：addr, data, rw, burst, len, id, resp |
| axi_slv_driver | 驱动AXI写（AW+W→B）和读（AR→R）握手时序 |
| axi_slv_monitor | 被动采样所有CSR事务，发布到analysis_port |
| axi_slv_sequencer | 标准UVM sequencer，接收sequence产生的item |

Driver时序参考现有TB中的`axi_write`/`axi_read` task：
- 写：AW valid→ready握手 → W valid→ready握手 → 等B valid
- 读：AR valid→ready握手 → 等R valid，采样rdata

### 4.3 mem_model（Reactive AXI Slave）

行为级DDR存储模型，连接在DUT的AXI Master端口上。

职责：
- 响应DUT发起的DMA读请求（AR→R通道），返回预加载数据
- 接收DUT发起的DMA写请求（AW+W→B通道），存储输出数据
- 提供backdoor API：
  - `write_word(addr, data)` — sequence预加载输入
  - `read_word(addr)` → data — scoreboard读取输出
  - `load_region(base, size, data_array)` — 批量加载
- 支持burst传输（INCR burst，len可配置）

实现方式：SV关联数组 `logic [31:0] mem[int unsigned]`，按字地址索引。

### 4.4 axi_mst_monitor（Passive）

被动监控DUT Master端口的DMA事务。

职责：
- 捕获AR/R通道事务（DMA读：加载Q/K/V/matrix/vector）
- 捕获AW/W/B通道事务（DMA写：写回O/output）
- 发布transaction到analysis_port供coverage采集
- 不驱动任何信号

### 4.5 cb_top_scoreboard

双模式结果检查器。

| 模式 | 比对方法 | 容差 | Golden来源 |
|------|----------|------|-----------|
| GEMV | bit-exact | 0 | matvec_golden_dense（SV函数或DPI-C） |
| FSA | 相对误差 | 5% (fail), 1% (warn) | dpi_e2e_compute + dpi_e2e_compare |

工作流程：
1. 接收CSR monitor的配置事务 → 解析mode/dims/addresses
2. 等待CB_done事件（通过cb_top_if监控）
3. 从mem_model backdoor读取输出区域数据
4. 调用ref_model计算期望值
5. 逐元素比对，统计error_count
6. 报告结果

### 4.6 cb_top_ref_model

DPI-C golden model的UVM封装。

FSA golden接口（复用e2e_golden.c）：
```c
void dpi_e2e_init(int head_dim, int seq_len, int num_heads);
void dpi_e2e_set_q(int head, int idx, int val);
void dpi_e2e_set_k(int head, int row, int col, int val);
void dpi_e2e_set_v(int head, int row, int col, int val);
void dpi_e2e_compute();
int  dpi_e2e_compare(int head, int idx, int dut_val);
void dpi_e2e_report();
```

GEMV golden接口（新封装）：
```c
void dpi_gemv_init(int rows, int cols);
void dpi_gemv_set_matrix(int row, int col, int val);
void dpi_gemv_set_vector(int idx, int val);
void dpi_gemv_compute();
int  dpi_gemv_get_result(int idx);  // 返回fp32 bit pattern
```

### 4.7 cb_top_coverage

功能覆盖率采集器，通过analysis_port接收事务并采样covergroup。

详见验证计划文档中的Coverage模型章节。

### 4.8 cb_top_virtual_seqr

虚拟sequencer，持有axi_slv_sequencer和mem_model的handle，
使virtual sequence能同时操作CSR配置和DDR数据加载。

---

## 5. Interface与DUT端口映射

### 5.1 axi_slv_if ↔ DUT AXI Slave端口

| Interface信号 | DUT端口 | 方向(相对DUT) | 说明 |
|--------------|---------|--------------|------|
| awid[4:0] | s_awid | input | 写地址ID |
| awaddr[31:0] | s_awaddr | input | CSR写地址 |
| awlen[7:0] | s_awlen | input | 固定0（单拍） |
| awsize[2:0] | s_awsize | input | 固定3'b010（4字节） |
| awburst[1:0] | s_awburst | input | 固定2'b01（INCR） |
| awlock | s_awlock | input | 固定0 |
| awcache[3:0] | s_awcache | input | 固定0 |
| awprot[2:0] | s_awprot | input | 固定0 |
| awvalid | s_awvalid | input | 写地址有效 |
| awready | s_awready | output | 写地址就绪 |
| wdata[31:0] | s_wdata | input | 写数据 |
| wstrb[3:0] | s_wstrb | input | 固定4'hF |
| wlast | s_wlast | input | 固定1（单拍） |
| wvalid | s_wvalid | input | 写数据有效 |
| wready | s_wready | output | 写数据就绪 |
| bid[4:0] | s_bid | output | 写响应ID |
| bresp[1:0] | s_bresp | output | 写响应 |
| bvalid | s_bvalid | output | 写响应有效 |
| bready | s_bready | input | 写响应就绪 |
| arid[4:0] | s_arid | input | 读地址ID |
| araddr[31:0] | s_araddr | input | CSR读地址 |
| arlen[7:0] | s_arlen | input | 固定0 |
| arsize[2:0] | s_arsize | input | 固定3'b010 |
| arburst[1:0] | s_arburst | input | 固定2'b01 |
| arlock | s_arlock | input | 固定0 |
| arcache[3:0] | s_arcache | input | 固定0 |
| arprot[2:0] | s_arprot | input | 固定0 |
| arvalid | s_arvalid | input | 读地址有效 |
| arready | s_arready | output | 读地址就绪 |
| rid[4:0] | s_rid | output | 读数据ID |
| rdata[31:0] | s_rdata | output | 读数据 |
| rresp[1:0] | s_rresp | output | 读响应 |
| rlast | s_rlast | output | 读最后一拍 |
| rvalid | s_rvalid | output | 读数据有效 |
| rready | s_rready | input | 读数据就绪 |

### 5.2 axi_mst_if ↔ DUT AXI Master端口

| Interface信号 | DUT端口 | 方向(相对DUT) | 说明 |
|--------------|---------|--------------|------|
| awid[3:0] | m_awid | output | DMA写地址ID |
| awaddr[31:0] | m_awaddr | output | DMA写目标地址 |
| awlen[7:0] | m_awlen | output | burst长度 |
| awsize[2:0] | m_awsize | output | 固定3'b010 |
| awburst[1:0] | m_awburst | output | INCR |
| awlock | m_awlock | output | |
| awcache[3:0] | m_awcache | output | |
| awprot[2:0] | m_awprot | output | |
| awvalid | m_awvalid | output | |
| awready | m_awready | input | mem_model驱动 |
| wdata[31:0] | m_wdata | output | DMA写数据 |
| wstrb[3:0] | m_wstrb | output | |
| wlast | m_wlast | output | |
| wvalid | m_wvalid | output | |
| wready | m_wready | input | mem_model驱动 |
| bid[3:0] | m_bid | input | mem_model驱动 |
| bresp[1:0] | m_bresp | input | mem_model驱动 |
| bvalid | m_bvalid | input | mem_model驱动 |
| bready | m_bready | output | |
| arid[3:0] | m_arid | output | DMA读地址ID |
| araddr[31:0] | m_araddr | output | DMA读源地址 |
| arlen[7:0] | m_arlen | output | burst长度 |
| arsize[2:0] | m_arsize | output | |
| arburst[1:0] | m_arburst | output | |
| arlock | m_arlock | output | |
| arcache[3:0] | m_arcache | output | |
| arprot[2:0] | m_arprot | output | |
| arvalid | m_arvalid | output | |
| arready | m_arready | input | mem_model驱动 |
| rid[3:0] | m_rid | input | mem_model驱动 |
| rdata[31:0] | m_rdata | input | mem_model驱动 |
| rresp[1:0] | m_rresp | input | mem_model驱动 |
| rlast | m_rlast | input | mem_model驱动 |
| rvalid | m_rvalid | input | mem_model驱动 |
| rready | m_rready | output | |

### 5.3 cb_top_if ↔ DUT杂项信号

| Interface信号 | DUT端口 | 方向 | 说明 |
|--------------|---------|------|------|
| CB_done | CB_done | output | 任务完成标志 |
| debug_state[3:0] | debug_state | output | FSM状态调试 |
| debug_data[15:0] | debug_data | output | 调试数据 |

注：clk和rst_n由tb_top直接生成，通过interface的clocking block传递。

---

## 6. tb_top连接示意

```systemverilog
module tb_top;
  import uvm_pkg::*;
  import cb_top_test_pkg::*;

  logic clk, rst_n;

  // 时钟生成
  initial clk = 0;
  always #10 clk = ~clk;  // 50MHz

  // 接口实例化
  axi_slv_if  axi_s_if (.clk(clk), .rst_n(rst_n));
  axi_mst_if  axi_m_if (.clk(clk), .rst_n(rst_n));
  cb_top_if   cb_if    (.clk(clk), .rst_n(rst_n));

  // DUT实例化
  CB_top_v2 dut (
    .clk(clk), .rst_n(rst_n), .CB_done(cb_if.CB_done),
    // AXI Slave
    .s_awid(axi_s_if.awid), .s_awaddr(axi_s_if.awaddr), ...
    // AXI Master
    .m_awid(axi_m_if.awid), .m_awaddr(axi_m_if.awaddr), ...
    // Debug
    .debug_state(cb_if.debug_state), .debug_data(cb_if.debug_data)
  );

  // 注册interface到config_db
  initial begin
    uvm_config_db#(virtual axi_slv_if)::set(null, "*", "axi_slv_vif", axi_s_if);
    uvm_config_db#(virtual axi_mst_if)::set(null, "*", "axi_mst_vif", axi_m_if);
    uvm_config_db#(virtual cb_top_if)::set(null, "*", "cb_top_vif", cb_if);
    run_test();
  end
endmodule
```

---

## 7. Package依赖关系

```
dpi_pkg.sv                    ← DPI-C import声明
  |
axi_slv_agent_pkg.sv         ← seq_item, driver, monitor, sequencer, agent
  |
mem_model_pkg.sv              ← mem_model组件
  |
cb_top_env_pkg.sv             ← env, scoreboard, ref_model, coverage, virtual_seqr
  |                              (import axi_slv_agent_pkg, mem_model_pkg, dpi_pkg)
  |
cb_top_seq_pkg.sv             ← 所有sequence（import cb_top_env_pkg）
  |
cb_top_test_pkg.sv            ← 所有test（import cb_top_seq_pkg）
```

编译顺序：dpi_pkg → agent_pkg → mem_model_pkg → env_pkg → seq_pkg → test_pkg → tb_top

---

## 8. 关键设计决策

| 决策 | 理由 |
|------|------|
| AXI Slave Agent为Active | DUT的Slave端口接收CPU配置，UVM环境模拟CPU侧主动驱动 |
| AXI Master端不用Agent，用mem_model + passive monitor | DUT主动发起DMA，我们只需响应和观测，不需要驱动 |
| 行为级mem_model而非RTL DDR模型 | 仿真速度快，backdoor方便，协议时序由mem_model内部AXI FSM保证 |
| 复用DPI-C golden而非SV重写 | e2e_golden.c已验证正确（fp64精度），避免重复开发和精度差异 |
| GEMV bit-exact，FSA容差比对 | GEMV累加顺序确定可精确匹配；FSA有PWL exp2近似，必须容差 |
| Virtual sequencer统一调度 | 一个virtual sequence同时控制DDR加载和CSR配置，流程清晰 |

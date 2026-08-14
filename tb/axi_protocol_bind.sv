// =============================================================================
// axi_protocol_bind —— 把 axi_protocol_checker 绑到新互连的各个 AXI 口
// =============================================================================
// plan 第 2 步。只在 tb 里编译，**不进交付 RTL**（filelist 分开，见
// scripts/soc_filelist.f 里的 AXI_CHK 段），与竞赛规则无关。
//
// 绑三个口，覆盖本轮改动的全部边界：
//   · CPU master（32 位窄侧，升宽器之前）—— 查 CPU 那 1 笔 outstanding 的顺序与稳定性
//   · DMA master（64 位宽侧，直连不经升宽）—— 查本轮改过两次的 arlen/awlen
//   · RAM slave（64 位宽侧）—— 查 axi2sram_sp_ext 的 skid 缓冲有没有在背压下改数据
//
// 外设四个口不绑：都是单拍寄存器 slave、无突发，`axi2apb`/`confreg`/`axi_dvi` 各自
// 无条件 `rlast<=1`，协议面没有可查的状态。要查的话第一优先仍是上面三个。
//
// 用 `bind` 而不是在 soc_top 里例化：交付 RTL 一行不改是硬要求，bind 是唯一能做到
// "从外部往设计里插检查器"的语法。
// =============================================================================

`ifndef SYNTHESIS

// ---- CPU master：32 位窄侧，ID 4 位 ----
bind soc_top axi_protocol_checker #(
    .ADDR_W (32), .DATA_W (32), .ID_W (4), .NAME ("cpu_mst")
) u_axi_chk_cpu (
    .aclk    (sys_clk),      .aresetn (sys_resetn),
    .awvalid (cpu_sync_awvalid), .awready (cpu_sync_awready),
    .awid    (cpu_sync_awid),    .awaddr  (cpu_sync_awaddr),
    .awlen   (cpu_sync_awlen),   .awsize  (cpu_sync_awsize),
    .awburst (cpu_sync_awburst),
    .wvalid  (cpu_sync_wvalid),  .wready  (cpu_sync_wready),
    .wdata   (cpu_sync_wdata),   .wstrb   (cpu_sync_wstrb),
    .wlast   (cpu_sync_wlast),
    .bvalid  (cpu_sync_bvalid),  .bready  (cpu_sync_bready),
    .bid     (cpu_sync_bid),     .bresp   (cpu_sync_bresp),
    .arvalid (cpu_sync_arvalid), .arready (cpu_sync_arready),
    .arid    (cpu_sync_arid),    .araddr  (cpu_sync_araddr),
    .arlen   (cpu_sync_arlen),   .arsize  (cpu_sync_arsize),
    .arburst (cpu_sync_arburst),
    .rvalid  (cpu_sync_rvalid),  .rready  (cpu_sync_rready),
    .rid     (cpu_sync_rid),     .rdata   (cpu_sync_rdata),
    .rresp   (cpu_sync_rresp),   .rlast   (cpu_sync_rlast)
);

// ---- DMA master：64 位宽侧，不经升宽器，ID 4 位 ----
// 本轮改动最密集的口：arlen/awlen 向上取整、写侧末拍 wstrb 屏蔽、读侧非对齐首拍，
// 每一条都直接体现在这里的拍数与 len 一致性上。
bind soc_top axi_protocol_checker #(
    .ADDR_W (32), .DATA_W (64), .ID_W (4), .NAME ("dma_mst")
) u_axi_chk_dma (
    .aclk    (sys_clk),      .aresetn (sys_resetn),
    .awvalid (dma_m_awvalid), .awready (dma_m_awready),
    .awid    (dma_m_awid),    .awaddr  (dma_m_awaddr),
    .awlen   (dma_m_awlen),   .awsize  (dma_m_awsize),
    .awburst (dma_m_awburst),
    .wvalid  (dma_m_wvalid),  .wready  (dma_m_wready),
    .wdata   (dma_m_wdata),   .wstrb   (dma_m_wstrb),
    .wlast   (dma_m_wlast),
    .bvalid  (dma_m_bvalid),  .bready  (dma_m_bready),
    .bid     (dma_m_bid),     .bresp   (dma_m_bresp),
    .arvalid (dma_m_arvalid), .arready (dma_m_arready),
    .arid    (dma_m_arid),    .araddr  (dma_m_araddr),
    .arlen   (dma_m_arlen),   .arsize  (dma_m_arsize),
    .arburst (dma_m_arburst),
    .rvalid  (dma_m_rvalid),  .rready  (dma_m_rready),
    .rid     (dma_m_rid),     .rdata   (dma_m_rdata),
    .rresp   (dma_m_rresp),   .rlast   (dma_m_rlast)
);

// ---- RAM slave：64 位宽侧，ID 5 位（xbar 前缀了 master 索引）----
// axi2sram_sp_ext 的 skid 缓冲就在这个口后面。它在突发中间隔拍背压时要把在途拍
// 暂存起来，写错就会在 rvalid 举着的时候改 rdata——正是握手稳定性断言要抓的。
bind soc_top axi_protocol_checker #(
    .ADDR_W (32), .DATA_W (64), .ID_W (5), .NAME ("ram_slv")
) u_axi_chk_ram (
    .aclk    (sys_clk),   .aresetn (sys_resetn),
    .awvalid (ram_awvalid), .awready (ram_awready),
    .awid    (ram_awid),    .awaddr  (ram_awaddr),
    .awlen   (ram_awlen),   .awsize  (ram_awsize),
    .awburst (ram_awburst),
    .wvalid  (ram_wvalid),  .wready  (ram_wready),
    .wdata   (ram_wdata),   .wstrb   (ram_wstrb),
    .wlast   (ram_wlast),
    .bvalid  (ram_bvalid),  .bready  (ram_bready),
    .bid     (ram_bid),     .bresp   (ram_bresp),
    .arvalid (ram_arvalid), .arready (ram_arready),
    .arid    (ram_arid),    .araddr  (ram_araddr),
    .arlen   (ram_arlen),   .arsize  (ram_arsize),
    .arburst (ram_arburst),
    .rvalid  (ram_rvalid),  .rready  (ram_rready),
    .rid     (ram_rid),     .rdata   (ram_rdata),
    .rresp   (ram_rresp),   .rlast   (ram_rlast)
);

`endif

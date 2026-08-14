`timescale 1ns / 1ps

// UVM验证环境顶层模块
// 实例化DUT、tb_axi_ram_sp_ext（已验证的DDR模型）、interface、启动UVM
module tb_top;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // ============================================================
  // 时钟和复位
  // ============================================================
  logic clk;
  logic rst_n;

  initial clk = 0;
  always #10 clk = ~clk;  // 50MHz, 周期20ns

  initial begin
    rst_n = 0;
    #100;
    rst_n = 1;
  end

  // ============================================================
  // Interface实例化
  // ============================================================
  axi_slv_if axi_s_if (.clk(clk), .rst_n(rst_n));
  axi_mst_if axi_m_if (.clk(clk), .rst_n(rst_n));
  cb_top_if  cb_if    (.clk(clk), .rst_n(rst_n));

  // DDR ID宽度适配（DUT master 4-bit → DDR model 5-bit）
  logic [4:0] ddr_awid, ddr_bid, ddr_arid, ddr_rid;
  assign ddr_awid = {1'b0, axi_m_if.awid};
  assign ddr_arid = {1'b0, axi_m_if.arid};
  assign axi_m_if.bid = ddr_bid[3:0];
  assign axi_m_if.rid = ddr_rid[3:0];

  // ============================================================
  // DUT实例化
  // ============================================================
  CB_top_v2 dut (
    .clock      (clk),
    .rst_n      (rst_n),
    .CB_done    (cb_if.CB_done),

    // AXI Slave (CSR配置端口)
    .s_awid     (axi_s_if.awid),
    .s_awaddr   (axi_s_if.awaddr),
    .s_awlen    (axi_s_if.awlen),
    .s_awsize   (axi_s_if.awsize),
    .s_awburst  (axi_s_if.awburst),
    .s_awlock   (axi_s_if.awlock),
    .s_awcache  (axi_s_if.awcache),
    .s_awprot   (axi_s_if.awprot),
    .s_awvalid  (axi_s_if.awvalid),
    .s_awready  (axi_s_if.awready),
    .s_wdata    (axi_s_if.wdata),
    .s_wstrb    (axi_s_if.wstrb),
    .s_wlast    (axi_s_if.wlast),
    .s_wvalid   (axi_s_if.wvalid),
    .s_wready   (axi_s_if.wready),
    .s_bid      (axi_s_if.bid),
    .s_bresp    (axi_s_if.bresp),
    .s_bvalid   (axi_s_if.bvalid),
    .s_bready   (axi_s_if.bready),
    .s_arid     (axi_s_if.arid),
    .s_araddr   (axi_s_if.araddr),
    .s_arlen    (axi_s_if.arlen),
    .s_arsize   (axi_s_if.arsize),
    .s_arburst  (axi_s_if.arburst),
    .s_arlock   (axi_s_if.arlock),
    .s_arcache  (axi_s_if.arcache),
    .s_arprot   (axi_s_if.arprot),
    .s_arvalid  (axi_s_if.arvalid),
    .s_arready  (axi_s_if.arready),
    .s_rid      (axi_s_if.rid),
    .s_rdata    (axi_s_if.rdata),
    .s_rresp    (axi_s_if.rresp),
    .s_rlast    (axi_s_if.rlast),
    .s_rvalid   (axi_s_if.rvalid),
    .s_rready   (axi_s_if.rready),

    // AXI Master (DMA端口) → 连接到DDR模型
    .m_awid     (axi_m_if.awid),
    .m_awaddr   (axi_m_if.awaddr),
    .m_awlen    (axi_m_if.awlen),
    .m_awsize   (axi_m_if.awsize),
    .m_awburst  (axi_m_if.awburst),
    .m_awlock   (axi_m_if.awlock),
    .m_awcache  (axi_m_if.awcache),
    .m_awprot   (axi_m_if.awprot),
    .m_awvalid  (axi_m_if.awvalid),
    .m_awready  (axi_m_if.awready),
    .m_wdata    (axi_m_if.wdata),
    .m_wstrb    (axi_m_if.wstrb),
    .m_wlast    (axi_m_if.wlast),
    .m_wvalid   (axi_m_if.wvalid),
    .m_wready   (axi_m_if.wready),
    .m_bid      (axi_m_if.bid),
    .m_bresp    (axi_m_if.bresp),
    .m_bvalid   (axi_m_if.bvalid),
    .m_bready   (axi_m_if.bready),
    .m_arid     (axi_m_if.arid),
    .m_araddr   (axi_m_if.araddr),
    .m_arlen    (axi_m_if.arlen),
    .m_arsize   (axi_m_if.arsize),
    .m_arburst  (axi_m_if.arburst),
    .m_arlock   (axi_m_if.arlock),
    .m_arcache  (axi_m_if.arcache),
    .m_arprot   (axi_m_if.arprot),
    .m_arvalid  (axi_m_if.arvalid),
    .m_arready  (axi_m_if.arready),
    .m_rid      (axi_m_if.rid),
    .m_rdata    (axi_m_if.rdata),
    .m_rresp    (axi_m_if.rresp),
    .m_rlast    (axi_m_if.rlast),
    .m_rvalid   (axi_m_if.rvalid),
    .m_rready   (axi_m_if.rready),

    // Debug
    .debug_state (cb_if.debug_state),
    .debug_data  (cb_if.debug_data)
  );

  // ============================================================
  // DDR模型（复用已验证的tb_axi_ram_sp_ext）
  // ============================================================
  // MEM_AW=24 → 64MB DDR，容纳边界test的完整硬件上限（127 tiles / 大列GEMV）
  tb_axi_ram_sp_ext #(.Init_File("none"), .MEM_AW(24)) u_ddr (
    .aclk(clk), .aresetn(rst_n),
    .axi_arid(ddr_arid), .axi_araddr(axi_m_if.araddr), .axi_arlen(axi_m_if.arlen),
    .axi_arsize(axi_m_if.arsize), .axi_arburst(axi_m_if.arburst),
    .axi_arlock({1'b0, axi_m_if.arlock}),
    .axi_arcache(axi_m_if.arcache), .axi_arprot(axi_m_if.arprot),
    .axi_arvalid(axi_m_if.arvalid), .axi_arready(axi_m_if.arready),
    .axi_rid(ddr_rid), .axi_rdata(axi_m_if.rdata), .axi_rresp(axi_m_if.rresp),
    .axi_rlast(axi_m_if.rlast), .axi_rvalid(axi_m_if.rvalid), .axi_rready(axi_m_if.rready),
    .axi_awid(ddr_awid), .axi_awaddr(axi_m_if.awaddr), .axi_awlen(axi_m_if.awlen),
    .axi_awsize(axi_m_if.awsize), .axi_awburst(axi_m_if.awburst),
    .axi_awlock({1'b0, axi_m_if.awlock}),
    .axi_awcache(axi_m_if.awcache), .axi_awprot(axi_m_if.awprot),
    .axi_awvalid(axi_m_if.awvalid), .axi_awready(axi_m_if.awready),
    .axi_wdata(axi_m_if.wdata), .axi_wstrb(axi_m_if.wstrb),
    .axi_wlast(axi_m_if.wlast), .axi_wvalid(axi_m_if.wvalid), .axi_wready(axi_m_if.wready),
    .axi_bid(ddr_bid), .axi_bresp(axi_m_if.bresp),
    .axi_bvalid(axi_m_if.bvalid), .axi_bready(axi_m_if.bready)
  );

  // ============================================================
  // UVM config_db注册 & 启动
  // ============================================================
  initial begin
    uvm_config_db#(virtual axi_slv_if)::set(null, "uvm_test_top.*", "axi_slv_vif", axi_s_if);
    uvm_config_db#(virtual axi_mst_if)::set(null, "uvm_test_top.*", "axi_mst_vif", axi_m_if);
    uvm_config_db#(virtual cb_top_if)::set(null, "uvm_test_top.*", "cb_top_vif", cb_if);
    run_test();
  end

  // ============================================================
  // 波形dump控制（通过plusarg开启）
  // ============================================================
  initial begin
    if ($test$plusargs("dump_wave")) begin
      $fsdbDumpfile("dump.fsdb");
      $fsdbDumpvars(0, tb_top);
      $fsdbDumpMDA();
    end
  end

  // ============================================================
  // 全局超时保护
  // ============================================================
  initial begin
    int timeout_cycles = 50_000_000;
    if ($value$plusargs("timeout_cycles=%d", timeout_cycles));
    repeat (timeout_cycles) @(posedge clk);
    `uvm_fatal("TIMEOUT", $sformatf("全局超时: %0d cycles", timeout_cycles))
  end

endmodule

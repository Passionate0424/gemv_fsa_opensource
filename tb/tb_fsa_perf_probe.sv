`timescale 1ns/1ps
//======================================================================
// tb_fsa_perf_probe —— FSA 单次调用周期数探针（性能回归定标用）
//----------------------------------------------------------------------
// 目的：只测"一次 FSA 启动到 CB_done 的周期数"，不做 golden 校验。
//   用于在两版 RTL（GQA 前/后）间对比拍数，定位性能回归的落点。
//   数据内容不影响拍数（FSA 是定长流水 + 固定 tile 循环），故 DDR 留零即可。
//
// 配置固定为上板实测场景（stories260K）：4×8 分组、head_dim=8、num_heads=4(MHA)，
// 扫多个 seq_len 观察增量随 tile 数的变化：
//   增量随 tile 数线性增长 → 每 tile 的 DMA/搬运多花了拍
//   增量恒定             → 每次启动的固定开销（配置/握手/收尾）
//
// 与 tb_fsa_e2e 共用 DUT 例化与 DDR 模型接线，仅去掉 golden 与数据填充。
//======================================================================
module tb_fsa_perf_probe;

  localparam logic [31:0] Q_BASE_ADDR = 32'h0000_1000;
  localparam logic [31:0] K_BASE_ADDR = 32'h0000_2000;
  localparam logic [31:0] V_BASE_ADDR = 32'h0001_0000;
  localparam logic [31:0] O_BASE_ADDR = 32'h0002_0000;

  localparam logic [31:0] REG_CTRL       = 32'h0000;
  localparam logic [31:0] REG_Q_BASE     = 32'h0030;
  localparam logic [31:0] REG_K_BASE     = 32'h0034;
  localparam logic [31:0] REG_V_BASE     = 32'h0038;
  localparam logic [31:0] REG_O_BASE     = 32'h003C;
  localparam logic [31:0] REG_HEAD_DIM   = 32'h0040;
  localparam logic [31:0] REG_SEQ_LEN    = 32'h0044;
  localparam logic [31:0] REG_KV_STRIDE  = 32'h0048;
  localparam logic [31:0] REG_NUM_HEADS  = 32'h004C;
  localparam logic [31:0] REG_ATTN_SCALE = 32'h0050;
  localparam logic [31:0] REG_GROUP_MODE = 32'h0054;

  // 上板同款配置
  localparam int HEAD_DIM   = 8;
  localparam int NUM_HEADS  = 4;    // MHA：num_kv_heads=num_active_heads=4
  localparam int GROUP_MODE = 0;    // 4×8

  logic clk, rst_n, CB_done;

  // AXI Slave (CSR)
  logic [4:0]  s_awid;    logic [31:0] s_awaddr;  logic [7:0]  s_awlen;
  logic [2:0]  s_awsize;  logic [1:0]  s_awburst; logic        s_awlock;
  logic [3:0]  s_awcache; logic [2:0]  s_awprot;  logic        s_awvalid, s_awready;
  logic [31:0] s_wdata;   logic [3:0]  s_wstrb;   logic        s_wlast, s_wvalid, s_wready;
  logic [4:0]  s_bid;     logic [1:0]  s_bresp;   logic        s_bvalid, s_bready;
  logic [4:0]  s_arid;    logic [31:0] s_araddr;  logic [7:0]  s_arlen;
  logic [2:0]  s_arsize;  logic [1:0]  s_arburst; logic        s_arlock;
  logic [3:0]  s_arcache; logic [2:0]  s_arprot;  logic        s_arvalid, s_arready;
  logic [4:0]  s_rid;     logic [31:0] s_rdata;   logic [1:0]  s_rresp;
  logic        s_rlast, s_rvalid, s_rready;

  // AXI Master (DDR)
  logic [3:0]  m_awid;    logic [31:0] m_awaddr;  logic [7:0]  m_awlen;
  logic [2:0]  m_awsize;  logic [1:0]  m_awburst; logic        m_awlock;
  logic [3:0]  m_awcache; logic [2:0]  m_awprot;  logic        m_awvalid, m_awready;
  logic [31:0] m_wdata;   logic [3:0]  m_wstrb;   logic        m_wlast, m_wvalid, m_wready;
  logic [3:0]  m_bid;     logic [1:0]  m_bresp;   logic        m_bvalid, m_bready;
  logic [3:0]  m_arid;    logic [31:0] m_araddr;  logic [7:0]  m_arlen;
  logic [2:0]  m_arsize;  logic [1:0]  m_arburst; logic        m_arlock;
  logic [3:0]  m_arcache; logic [2:0]  m_arprot;  logic        m_arvalid, m_arready;
  logic [3:0]  m_rid;     logic [31:0] m_rdata;   logic [1:0]  m_rresp;
  logic        m_rlast, m_rvalid, m_rready;

  logic [3:0]  debug_state;
  logic [15:0] debug_data;

  logic [4:0] ddr_awid, ddr_bid, ddr_arid, ddr_rid;
  assign ddr_awid = {1'b0, m_awid};
  assign ddr_arid = {1'b0, m_arid};
  assign m_bid = ddr_bid[3:0];
  assign m_rid = ddr_rid[3:0];

  CB_top_v2 dut (
      .clock(clk), .rst_n(rst_n), .CB_done(CB_done),
      .s_awid(s_awid), .s_awaddr(s_awaddr), .s_awlen(s_awlen),
      .s_awsize(s_awsize), .s_awburst(s_awburst), .s_awlock(s_awlock),
      .s_awcache(s_awcache), .s_awprot(s_awprot), .s_awvalid(s_awvalid), .s_awready(s_awready),
      .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
      .s_wvalid(s_wvalid), .s_wready(s_wready),
      .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
      .s_arid(s_arid), .s_araddr(s_araddr), .s_arlen(s_arlen),
      .s_arsize(s_arsize), .s_arburst(s_arburst), .s_arlock(s_arlock),
      .s_arcache(s_arcache), .s_arprot(s_arprot), .s_arvalid(s_arvalid), .s_arready(s_arready),
      .s_rid(s_rid), .s_rdata(s_rdata), .s_rresp(s_rresp),
      .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
      .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen),
      .m_awsize(m_awsize), .m_awburst(m_awburst), .m_awlock(m_awlock),
      .m_awcache(m_awcache), .m_awprot(m_awprot), .m_awvalid(m_awvalid), .m_awready(m_awready),
      .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast),
      .m_wvalid(m_wvalid), .m_wready(m_wready),
      .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
      .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen),
      .m_arsize(m_arsize), .m_arburst(m_arburst), .m_arlock(m_arlock),
      .m_arcache(m_arcache), .m_arprot(m_arprot), .m_arvalid(m_arvalid), .m_arready(m_arready),
      .m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp),
      .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready),
      .debug_state(debug_state), .debug_data(debug_data)
  );

  tb_axi_ram_sp_ext #(.Init_File("none"), .MEM_AW(20)) u_ddr (
      .aclk(clk), .aresetn(rst_n),
      .axi_arid(ddr_arid), .axi_araddr(m_araddr), .axi_arlen(m_arlen),
      .axi_arsize(m_arsize), .axi_arburst(m_arburst), .axi_arlock({1'b0, m_arlock}),
      .axi_arcache(m_arcache), .axi_arprot(m_arprot), .axi_arvalid(m_arvalid), .axi_arready(m_arready),
      .axi_rid(ddr_rid), .axi_rdata(m_rdata), .axi_rresp(m_rresp),
      .axi_rlast(m_rlast), .axi_rvalid(m_rvalid), .axi_rready(m_rready),
      .axi_awid(ddr_awid), .axi_awaddr(m_awaddr), .axi_awlen(m_awlen),
      .axi_awsize(m_awsize), .axi_awburst(m_awburst), .axi_awlock({1'b0, m_awlock}),
      .axi_awcache(m_awcache), .axi_awprot(m_awprot), .axi_awvalid(m_awvalid), .axi_awready(m_awready),
      .axi_wdata(m_wdata), .axi_wstrb(m_wstrb), .axi_wlast(m_wlast),
      .axi_wvalid(m_wvalid), .axi_wready(m_wready),
      .axi_bid(ddr_bid), .axi_bresp(m_bresp), .axi_bvalid(m_bvalid), .axi_bready(m_bready)
  );

  initial clk = 0;
  always #5 clk = ~clk;

  // 周期计数器（复位后自由运行，用差值取单次调用拍数）
  longint unsigned cyc;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) cyc <= 0;
    else        cyc <= cyc + 1;
  end

  task automatic init_bus;
    s_awid=0; s_awaddr=0; s_awlen=0; s_awsize=3'b010; s_awburst=2'b01;
    s_awlock=0; s_awcache=0; s_awprot=0; s_awvalid=0;
    s_wdata=0; s_wstrb=4'hF; s_wlast=1; s_wvalid=0; s_bready=1;
    s_arid=0; s_araddr=0; s_arlen=0; s_arsize=3'b010; s_arburst=2'b01;
    s_arlock=0; s_arcache=0; s_arprot=0; s_arvalid=0; s_rready=1;
  endtask

  task automatic axi_write(input logic [31:0] addr, input logic [31:0] data);
    @(posedge clk);
    s_awid <= 5'd1; s_awaddr <= addr; s_awlen <= 8'd0;
    s_awsize <= 3'b010; s_awburst <= 2'b01; s_awvalid <= 1'b1;
    while (!s_awready) @(posedge clk);
    @(posedge clk); s_awvalid <= 1'b0;
    s_wdata <= data; s_wstrb <= 4'hF; s_wlast <= 1'b1; s_wvalid <= 1'b1;
    while (!s_wready) @(posedge clk);
    @(posedge clk); s_wvalid <= 1'b0;
    wait (s_bvalid === 1'b1); @(posedge clk);
  endtask

  // 跑一次 FSA，返回 START 到 CB_done 的周期数
  task automatic run_once(input int seq_len, output longint unsigned cycles);
    longint unsigned t0;
    int kv_stride;
    kv_stride = NUM_HEADS * HEAD_DIM * HEAD_DIM * 4;  // DDR 每 tile 物理 KV 头数×r×d×4

    axi_write(REG_Q_BASE,     Q_BASE_ADDR);
    axi_write(REG_K_BASE,     K_BASE_ADDR);
    axi_write(REG_V_BASE,     V_BASE_ADDR);
    axi_write(REG_O_BASE,     O_BASE_ADDR);
    axi_write(REG_HEAD_DIM,   HEAD_DIM);
    axi_write(REG_SEQ_LEN,    seq_len);
    axi_write(REG_KV_STRIDE,  kv_stride);
    axi_write(REG_NUM_HEADS,  NUM_HEADS);
    axi_write(REG_GROUP_MODE, GROUP_MODE);
    axi_write(REG_ATTN_SCALE, 32'h3F0293EE);

    @(posedge clk);
    t0 = cyc;
    axi_write(REG_CTRL, 32'h3);              // START | MODE_FSA
    wait (CB_done === 1'b1);
    @(posedge clk);
    cycles = cyc - t0;
    axi_write(REG_CTRL, 32'h0);              // 清 START，准备下一次
    repeat (20) @(posedge clk);
  endtask

  // ---- GEMV 探针：workload 真正的大头(每层 7 个矩阵乘)，必须一并定标 ----
  localparam logic [31:0] REG_VI_BASE = 32'h0010;
  localparam logic [31:0] REG_MI_BASE = 32'h0014;
  localparam logic [31:0] REG_VO_BASE = 32'h0018;
  localparam logic [31:0] REG_ROWS    = 32'h0020;
  localparam logic [31:0] REG_COLS    = 32'h0024;

  task automatic run_gemv_once(input int rows, input int cols, output longint unsigned cycles);
    longint unsigned t0;
    axi_write(REG_VI_BASE, Q_BASE_ADDR);
    axi_write(REG_MI_BASE, K_BASE_ADDR);
    axi_write(REG_VO_BASE, O_BASE_ADDR);
    axi_write(REG_ROWS,    rows);
    axi_write(REG_COLS,    cols);

    @(posedge clk);
    t0 = cyc;
    axi_write(REG_CTRL, 32'h1);              // START，MODE=GEMV
    wait (CB_done === 1'b1);
    @(posedge clk);
    cycles = cyc - t0;
    axi_write(REG_CTRL, 32'h0);
    repeat (20) @(posedge clk);
  endtask

  longint unsigned c8, c64, c128, c256;
  longint unsigned g64x64, g256x64, g64x256;

  initial begin
    init_bus();
    rst_n = 0;
    repeat (10) @(posedge clk);
    rst_n = 1;
    repeat (10) @(posedge clk);

    run_once(8,   c8);
    run_once(64,  c64);
    run_once(128, c128);
    run_once(256, c256);

    run_gemv_once(64,  64,  g64x64);    // dim×dim（wq/wk/wv/wo 量级）
    run_gemv_once(256, 64,  g256x64);   // hidden×dim（w1/w3 量级）
    run_gemv_once(64,  256, g64x256);   // dim×hidden（w2 量级）

    $display("");
    $display("========== FSA PERF PROBE (4x8, head_dim=%0d, num_heads=%0d) ==========", HEAD_DIM, NUM_HEADS);
    $display("[PERF] seq=8    tiles=1   cycles=%0d", c8);
    $display("[PERF] seq=64   tiles=8   cycles=%0d", c64);
    $display("[PERF] seq=128  tiles=16  cycles=%0d", c128);
    $display("[PERF] seq=256  tiles=32  cycles=%0d", c256);
    $display("[PERF] per-tile slope (256-128)/16 = %0d", (c256 - c128) / 16);
    $display("---------- GEMV (workload 大头) ----------");
    $display("[PERF] gemv d=64  n=64   cycles=%0d", g64x64);
    $display("[PERF] gemv d=256 n=64   cycles=%0d", g256x64);
    $display("[PERF] gemv d=64  n=256  cycles=%0d", g64x256);
    $display("=====================================================================");
    $finish;
  end

  initial begin
    #20_000_000;
    $display("[PERF] [FAIL] timeout");
    $finish;
  end

endmodule

`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// tb_fsa_e2e
// Filelist: scripts/fsa_e2e_filelist.f
// 运行: run_vcs_remote.ps1 -Top tb_fsa_e2e -Filelist scripts/fsa_e2e_filelist.f
//
// CB_top_v2 的 FSA 端到端黑盒验证TB
// 通过 CSR 配置、DDR 装载、启动任务、等待完成和读回 O，
// 再与 DPI-C golden 做 fp64 标准 softmax 比对。
//
// 覆盖 case:
//   1. 基础 seq_len
//   2. 非整数倍 seq_len
//   3. 多 seed 随机覆盖
////////////////////////////////////////////////////////////////

import "DPI-C" function void dpi_e2e_init(input int head_dim, input int seq_len, input int num_heads);
import "DPI-C" function void dpi_e2e_set_q(input int head, input int idx, input int val);
import "DPI-C" function void dpi_e2e_set_k(input int head, input int row, input int col, input int val);
import "DPI-C" function void dpi_e2e_set_v(input int head, input int row, input int col, input int val);
import "DPI-C" function void dpi_e2e_compute();
import "DPI-C" function int  dpi_e2e_compare(input int head, input int idx, input int dut_val);
import "DPI-C" function void dpi_e2e_report();
// golden模型选择：0=fp64理想(默认,现有回归基线) / 1=bit-accurate(fp32+PWL+online softmax)
// 加 +GOLDEN_BITACC 切到后者，用于区分"PWL近似误差"与"RTL实现bug"
import "DPI-C" function void dpi_e2e_set_mode(input int mode);

module tb_fsa_e2e;

  // 可通过plusarg配置的参数（支持多分组模式验证）
  int HEAD_DIM = 8;
  int NUM_HEADS = 4;
  int GROUP_MODE = 0;  // 0=4×8, 1=2×16, 2=1×32

  // K tile 0 预取模式（+PF_MODE=n）。0=不预取（原行为）。
  // 非0时在start之前先把tile 0的K搬进SRAM，验证不同通路——但**结果判定完全不变**，
  // 仍与 bit-accurate golden 逐位对照。预取只该改变数据什么时候到，不该改变算出什么。
  //   1 = 正常命中：S_FSA_WAIT_K 的 tile 0 不再发DMA，直接进V阶段
  //   2 = 失效：预取后重写REG_K_BASE，pf_valid必须清零、回退正常搬运
  //   3 = target不符：以GEMV权重为target预取，FSA任务不得命中
  int PF_MODE = 0;
  int pf_completed;   // 观测到PF_VALID置起的次数，防"预取压根没发生"的假通过
  // k_base 是 run_case 里的 automatic 局部量，do_fsa_prefetch 够不着，
  // 这里留一份模块级镜像供失效通路重写用
  logic [31:0] k_base_saved;
  localparam int MAX_SEQ_LEN = 2048;
  localparam int TIMEOUT_CYCLES = 200000;

  // GQA 验证用 static 缓存（模块级，避免 automatic task 内大数组栈溢出）：
  // q_data 逐 Q head，k_data/v_data 逐唯一 KV head（最多 4 份）。fp32 位模式存储。
  localparam int MAX_HEADS = 4;
  localparam int MAX_HEAD_DIM = 64;
  logic [31:0] q_data [0:MAX_HEADS-1][0:MAX_HEAD_DIM-1];
  logic [31:0] k_data [0:MAX_HEADS-1][0:MAX_SEQ_LEN-1][0:MAX_HEAD_DIM-1];
  logic [31:0] v_data [0:MAX_HEADS-1][0:MAX_SEQ_LEN-1][0:MAX_HEAD_DIM-1];

  // DDR地址布局（与编程手册一致）
  localparam logic [31:0] Q_BASE_ADDR  = 32'h0000_1000;
  localparam logic [31:0] K_BASE_ADDR  = 32'h0000_2000;
  localparam logic [31:0] V_BASE_ADDR  = 32'h0001_0000;
  localparam logic [31:0] O_BASE_ADDR  = 32'h0002_0000;

  // CSR地址
  localparam logic [31:0] REG_CTRL      = 32'h0000;
  localparam logic [31:0] REG_STATUS    = 32'h0004;
  localparam logic [31:0] REG_Q_BASE    = 32'h0030;
  localparam logic [31:0] REG_K_BASE    = 32'h0034;
  localparam logic [31:0] REG_V_BASE    = 32'h0038;
  localparam logic [31:0] REG_O_BASE    = 32'h003C;
  localparam logic [31:0] REG_HEAD_DIM  = 32'h0040;
  localparam logic [31:0] REG_SEQ_LEN   = 32'h0044;
  localparam logic [31:0] REG_KV_STRIDE = 32'h0048;
  localparam logic [31:0] REG_NUM_HEADS = 32'h004C;
  localparam logic [31:0] REG_ATTN_SCALE = 32'h0050;
  localparam logic [31:0] REG_GROUP_MODE = 32'h0054;
  localparam logic [31:0] REG_PF_CTRL    = 32'h005C;  // [0]=start脉冲 [1]=target
  localparam int PF_STATUS_VALID_BIT = 2;             // STATUS[2]=pf_valid

  logic clk, rst_n, CB_done;

  // AXI Slave (CSR)
  logic [4:0]  s_awid;    logic [31:0] s_awaddr;  logic [7:0]  s_awlen;
  logic [2:0]  s_awsize;  logic [1:0]  s_awburst; logic        s_awlock;
  logic [3:0]  s_awcache; logic [2:0]  s_awprot;  logic        s_awvalid, s_awready;
  logic [63:0] s_wdata;   logic [7:0]  s_wstrb;   logic        s_wlast, s_wvalid, s_wready;
  logic [4:0]  s_bid;     logic [1:0]  s_bresp;   logic        s_bvalid, s_bready;
  logic [4:0]  s_arid;    logic [31:0] s_araddr;  logic [7:0]  s_arlen;
  logic [2:0]  s_arsize;  logic [1:0]  s_arburst; logic        s_arlock;
  logic [3:0]  s_arcache; logic [2:0]  s_arprot;  logic        s_arvalid, s_arready;
  logic [4:0]  s_rid;     logic [63:0] s_rdata;   logic [1:0]  s_rresp;
  logic        s_rlast, s_rvalid, s_rready;

  // AXI Master (DDR)
  logic [3:0]  m_awid;    logic [31:0] m_awaddr;  logic [7:0]  m_awlen;
  logic [2:0]  m_awsize;  logic [1:0]  m_awburst; logic        m_awlock;
  logic [3:0]  m_awcache; logic [2:0]  m_awprot;  logic        m_awvalid, m_awready;
  logic [63:0] m_wdata;   logic [7:0]  m_wstrb;   logic        m_wlast, m_wvalid, m_wready;
  logic [3:0]  m_bid;     logic [1:0]  m_bresp;   logic        m_bvalid, m_bready;
  logic [3:0]  m_arid;    logic [31:0] m_araddr;  logic [7:0]  m_arlen;
  logic [2:0]  m_arsize;  logic [1:0]  m_arburst; logic        m_arlock;
  logic [3:0]  m_arcache; logic [2:0]  m_arprot;  logic        m_arvalid, m_arready;
  logic [3:0]  m_rid;     logic [63:0] m_rdata;   logic [1:0]  m_rresp;
  logic        m_rlast, m_rvalid, m_rready;

  logic [3:0] debug_state;
  logic [15:0] debug_data;

  // DDR ID宽度适配
  logic [4:0] ddr_awid, ddr_bid, ddr_arid, ddr_rid;
  assign ddr_awid = {1'b0, m_awid};
  assign ddr_arid = {1'b0, m_arid};
  assign m_bid = ddr_bid[3:0];
  assign m_rid = ddr_rid[3:0];

  // DUT
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

  // DDR模型
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

  // 时钟
  initial clk = 0;
  always #5 clk = ~clk;

  // ============================================================
  // 基础任务
  // ============================================================

  task automatic init_bus;
    s_awid=0; s_awaddr=0; s_awlen=0; s_awsize=3'b010; s_awburst=2'b01;
    s_awlock=0; s_awcache=0; s_awprot=0; s_awvalid=0;
    s_wdata=0; s_wstrb=8'h0F; s_wlast=1; s_wvalid=0; s_bready=1;
    s_arid=0; s_araddr=0; s_arlen=0; s_arsize=3'b010; s_arburst=2'b01;
    s_arlock=0; s_arcache=0; s_arprot=0; s_arvalid=0; s_rready=1;
  endtask

  task automatic axi_write(input logic [31:0] addr, input logic [31:0] data);
    @(posedge clk);
    s_awid <= 5'd1; s_awaddr <= addr; s_awlen <= 8'd0;
    s_awsize <= 3'b010; s_awburst <= 2'b01; s_awvalid <= 1'b1;
    while (!s_awready) @(posedge clk);
    @(posedge clk); s_awvalid <= 1'b0;
    // 总线 64 位而 CSR 是 32 位寄存器，数据要落在 addr[2] 指定的那半数据道
    s_wdata <= {2{data}}; s_wstrb <= addr[2] ? 8'hF0 : 8'h0F; s_wlast <= 1'b1; s_wvalid <= 1'b1;
    while (!s_wready) @(posedge clk);
    @(posedge clk); s_wvalid <= 1'b0;
    wait (s_bvalid === 1'b1); @(posedge clk);
  endtask

  task automatic axi_read(input logic [31:0] addr, output logic [31:0] data);
    @(posedge clk);
    s_arid <= 5'd2; s_araddr <= addr; s_arlen <= 8'd0;
    s_arsize <= 3'b010; s_arburst <= 2'b01; s_arvalid <= 1'b1;
    while (!s_arready) @(posedge clk);
    @(posedge clk); s_arvalid <= 1'b0;
    wait (s_rvalid === 1'b1); data = addr[2] ? s_rdata[63:32] : s_rdata[31:0]; @(posedge clk);
  endtask

  function automatic logic [31:0] ddr_read(input logic [31:0] byte_addr);
    ddr_read = u_ddr.mem[byte_addr >> 2];
  endfunction

  task automatic ddr_write(input logic [31:0] byte_addr, input logic [31:0] data);
    u_ddr.mem[byte_addr >> 2] = data;
  endtask

  // ============================================================
  // PRNG（LCG，可控seed）
  // ============================================================
  int unsigned prng_state;

  function automatic logic [31:0] prng_next();
    prng_state = prng_state * 32'd1664525 + 32'd1013904223;
    return prng_state;
  endfunction

  // 生成指定范围的随机fp32: [-range, +range]
  function automatic logic [31:0] rand_fp32(input real range);
    logic [31:0] raw;
    real val;
    raw = prng_next();
    // 映射到[-1,1]再乘range
    val = ($itor($signed(raw)) / 2147483648.0) * range;
    return $shortrealtobits(shortreal'(val));
  endfunction

  // ============================================================
  // 测试流程
  // ============================================================

  // 发起一次 K tile 0 预取并按 PF_MODE 验证对应通路。
  // 调用前 FSA 的 CSR 必须已配好——预取用的就是那份配置，硬件不另存影子寄存器。
  // 正确性边界：tile 0 覆盖 seq 位置 0~seq_tile_len-1，只有 num_tiles>=2 时它才
  // 不含"当前正在写入的那一格"。num_tiles==1 时调用方不该发预取。
  task automatic do_fsa_prefetch(input int mode);
    logic [31:0] st;
    int poll_cnt;

    // mode3 用 GEMV 权重做 target，而本次跑的是 FSA 任务，硬件应因模式不符拒绝命中。
    // 先给 GEMV 那组 CSR 配合法值，让预取真的执行完：rows/cols 为0会触发硬件的
    // 尺寸非法保护而根本不发预取，那样这条规则就成了空验。
    if (mode == 3) begin
      axi_write(32'h0020, 32'd32);          // ROWS
      axi_write(32'h0024, 32'd64);          // COLS
      axi_write(32'h0014, k_base_saved);    // MI_BASE 复用K区，那里有真实数据
    end
    axi_write(REG_PF_CTRL, (mode == 3) ? 32'h1 : 32'h3);

    poll_cnt = 0;
    st = 32'h0;
    while (st[PF_STATUS_VALID_BIT] !== 1'b1 && poll_cnt < 4000) begin
      axi_read(REG_STATUS, st);
      poll_cnt++;
    end

    if (st[PF_STATUS_VALID_BIT] !== 1'b1)
      $display("[E2E] [FAIL] PF(mode%0d): PF_VALID never asserted after %0d polls",
               mode, poll_cnt);
    else
      pf_completed++;

    // 失效通路：重写决定"搬什么"的 K_BASE，pf_valid 必须当场清掉
    if (mode == 2) begin
      axi_write(REG_K_BASE, k_base_saved);
      axi_read(REG_STATUS, st);
      if (st[PF_STATUS_VALID_BIT] !== 1'b0)
        $display("[E2E] [FAIL] PF(mode2): PF_VALID must clear after rewriting K_BASE");
      else
        $display("[E2E] PF(mode2): invalidation on K_BASE write OK");
    end
  endtask

  task automatic run_case(
    input string name,
    input int seq_len,
    input int seed,
    input real val_range
  );
    int kv_stride;
    int num_tiles;
    int seq_tile_len;
    int errors;
    logic [31:0] status;
    logic [31:0] dut_val;
    int unsigned start_cycle;
    int kv_footprint;
    logic [31:0] k_base;
    logic [31:0] v_base;
    logic [31:0] o_base;

    // K/V DMA一次只搬32行（硬件cmd_block_count恒为31），tile的"行数"
    // (seq_tile_len)和"列数"(HEAD_DIM)是两个独立的量：HEAD_DIM<=32时两者相等
    // （现有4×8/2×16/1×32场景，d×d方tile），HEAD_DIM>32时tile仍是32行、
    // HEAD_DIM列的矩形tile，不能再假设K/V是HEAD_DIM×HEAD_DIM的方阵
    seq_tile_len = (HEAD_DIM > 32) ? 32 : HEAD_DIM;
    num_tiles = (seq_len + seq_tile_len - 1) / seq_tile_len;
    kv_stride = NUM_HEADS * seq_tile_len * HEAD_DIM * 4;
    // 动态计算非重叠BASE地址（避免K/V空间冲突）
    kv_footprint = num_tiles * kv_stride;
    k_base = 32'h0000_2000;
    v_base = k_base + kv_footprint;
    o_base = v_base + kv_footprint;

    $display("\n[E2E] ========== Case: %s (seq=%0d, tiles=%0d, seed=%0d, range=%.1f) ==========",
      name, seq_len, num_tiles, seed, val_range);

    // 复位硬件
    rst_n = 0;
    repeat(5) @(posedge clk);
    rst_n = 1;
    repeat(5) @(posedge clk);

    // 初始化golden
    dpi_e2e_init(HEAD_DIM, seq_len, NUM_HEADS);

    // 生成随机数据并写入DDR + golden
    prng_state = seed;
    for (int h = 0; h < NUM_HEADS; h++)
      for (int i = 0; i < HEAD_DIM; i++) begin
        logic [31:0] val = rand_fp32(val_range);
        ddr_write(Q_BASE_ADDR + (h * HEAD_DIM + i) * 4, val);
        dpi_e2e_set_q(h, i, val);
`ifdef WB_TRACE
        // 与 CB_top_v2 的 [QW] 埋点对照
        if (h < 2) $display("[QREF] h=%0d i=%0d val=0x%08h", h, i, val);
`endif
      end

    // K/V按tile-major布局：tile j的4个head连续存放，每个tile是
    // seq_tile_len行 × HEAD_DIM列（HEAD_DIM<=32时seq_tile_len==HEAD_DIM，退化成
    // 原有的d×d方tile；HEAD_DIM>32时是32行×HEAD_DIM列的矩形tile）
    // addr = BASE + tile * KV_STRIDE + head * seq_tile_len*d*4 + row_in_tile * d*4 + col*4
    for (int tile = 0; tile < num_tiles; tile++)
      for (int h = 0; h < NUM_HEADS; h++)
        for (int r = 0; r < seq_tile_len; r++)
          for (int c = 0; c < HEAD_DIM; c++) begin
            logic [31:0] val = rand_fp32(val_range);
            ddr_write(k_base + tile * kv_stride + (h * seq_tile_len * HEAD_DIM + r * HEAD_DIM + c) * 4, val);
            dpi_e2e_set_k(h, tile * seq_tile_len + r, c, val);
`ifdef WB_TRACE
            // 与 CB_top_v2 的 [WW] K 埋点对照：搬进 Input SRAM 的值应与这里逐字相同
            if (tile == 0 && h == 0 && r < 2)
              $display("[KREF] tile=%0d h=%0d r=%0d c=%0d val=0x%08h", tile, h, r, c, val);
`endif
          end

    for (int tile = 0; tile < num_tiles; tile++)
      for (int h = 0; h < NUM_HEADS; h++)
        for (int r = 0; r < seq_tile_len; r++)
          for (int c = 0; c < HEAD_DIM; c++) begin
            logic [31:0] val = rand_fp32(val_range);
            ddr_write(v_base + tile * kv_stride + (h * seq_tile_len * HEAD_DIM + r * HEAD_DIM + c) * 4, val);
            dpi_e2e_set_v(h, tile * seq_tile_len + r, c, val);
`ifdef WB_TRACE
            // 与 CB_top_v2 的 [WW] V 埋点对照
            if (tile == 0 && h == 0 && r < 2)
              $display("[VREF] tile=%0d h=%0d r=%0d c=%0d val=0x%08h", tile, h, r, c, val);
`endif
          end

    // O区域标记
    for (int i = 0; i < NUM_HEADS * HEAD_DIM; i++)
      ddr_write(o_base + i * 4, 32'hDEAD_BEEF);

    // 计算golden
    dpi_e2e_compute();

    // CSR配置
    axi_write(REG_Q_BASE, Q_BASE_ADDR);
    axi_write(REG_K_BASE, k_base);
    axi_write(REG_V_BASE, v_base);
    axi_write(REG_O_BASE, o_base);
    axi_write(REG_HEAD_DIM, HEAD_DIM);
    axi_write(REG_SEQ_LEN, seq_len);
    axi_write(REG_KV_STRIDE, kv_stride);
    axi_write(REG_NUM_HEADS, NUM_HEADS);
    axi_write(REG_GROUP_MODE, GROUP_MODE);
    // ATTN_SCALE = log2(e)/sqrt(head_dim)，按head_dim选择
    case (HEAD_DIM)
      8:  axi_write(REG_ATTN_SCALE, 32'h3F0293EE);  // 1.4427/2.828 ≈ 0.5100
      16: axi_write(REG_ATTN_SCALE, 32'h3EB8AA3B);  // 1.4427/4.0 ≈ 0.3607
      32: axi_write(REG_ATTN_SCALE, 32'h3E8293EE);  // log2(e)/sqrt(32) = 0.25503
      48: axi_write(REG_ATTN_SCALE, 32'h3E553B95);  // log2(e)/sqrt(48) = 0.20824
      64: axi_write(REG_ATTN_SCALE, 32'h3E38AA3B);  // log2(e)/sqrt(64) = 0.18034
      default: axi_write(REG_ATTN_SCALE, 32'h3F0293EE);
    endcase

    // K tile 0 预取。必须夹在CSR配置和start之间——硬件用的就是刚配好的这份。
    // num_tiles==1 时 tile 0 就是唯一那块、也是"当前token所在"的那块，
    // 真实软件场景下它还没写完，所以那种情况不发预取（与run.c的pos>=head_size同理）
    k_base_saved = k_base;
    if (PF_MODE != 0 && num_tiles >= 2) do_fsa_prefetch(PF_MODE);

    // 启动（MODE=FSA, START=1）
    start_cycle = $time / 10;
    axi_write(REG_CTRL, 32'h0000_0003);

    // 等待完成
    for (int cyc = 0; cyc < TIMEOUT_CYCLES; cyc++) begin
      @(posedge clk);
      if (CB_done) break;
      if (cyc == TIMEOUT_CYCLES - 1) begin
        $display("[E2E] [FAIL] TIMEOUT case=%s", name);
        return;
      end
    end
    @(posedge clk); @(posedge clk);

    // 从DDR读O，逐元素比对
    errors = 0;
    for (int h = 0; h < NUM_HEADS; h++)
      for (int i = 0; i < HEAD_DIM; i++) begin
        dut_val = ddr_read(o_base + (h * HEAD_DIM + i) * 4);
        errors += dpi_e2e_compare(h, i, dut_val);
      end

    // 精度统计报告（比对完成后打印）
    dpi_e2e_report();

    if (errors == 0)
      $display("[E2E] PASS case=%s", name);
    else
      $display("[E2E] [FAIL] case=%s errors=%0d", name, errors);
  endtask

  // ============================================================
  // GQA/MQA 端到端验证
  // ============================================================
  // 验证硬件的 KV fanout：DDR 只摆 kv_heads 份唯一 K/V，硬件读一次后广播到
  // NUM_HEADS 个 Q 组。黑盒构造思路（与设计解耦）：
  //   - golden 仍按 NUM_HEADS 个逻辑 head 建模标准 attention，但让共享同一
  //     KV 的多个 Q head 填入**完全相同**的 K/V 数据（golden 里 head h 用
  //     kv_head = h/ratio 的那份），于是 golden 输出天然是"每个 Q head 用其
  //     组共享 KV"的正确结果。
  //   - DUT 侧 DDR 只摆 kv_heads 份（按 kv_head 索引连续存放），配
  //     REG_NUM_HEADS=kv_heads 和缩小的 KV_STRIDE，交给硬件 fanout 补齐。
  // 若 fanout 掩码/组基址/组内反转错，某些 Q head 的 O 会对不上 → 精确定位。
  // ratio = NUM_HEADS / kv_heads（每个 KV 头 fanout 到几个 Q 组）。
  task automatic run_case_gqa(
    input string name,
    input int seq_len,
    input int kv_heads,
    input int seed,
    input real val_range
  );
    int kv_stride;
    int num_tiles;
    int seq_tile_len;
    int ratio;
    int errors;
    logic [31:0] status;
    logic [31:0] dut_val;
    logic [31:0] k_base;
    logic [31:0] v_base;
    logic [31:0] o_base;
    int kv_footprint;
    // 数据缓存用模块级 static 数组 gqa_k_data/gqa_v_data/gqa_q_data（见模块顶部声明）：
    // 若在此声明为 automatic task 局部大数组会在栈上分配数 MB → 栈溢出，故上提到模块级。

    seq_tile_len = (HEAD_DIM > 32) ? 32 : HEAD_DIM;
    num_tiles = (seq_len + seq_tile_len - 1) / seq_tile_len;
    ratio = NUM_HEADS / kv_heads;
    // GQA 下 DDR 每 tile 只摆 kv_heads 份 → KV_STRIDE 相应缩小
    kv_stride = kv_heads * seq_tile_len * HEAD_DIM * 4;
    kv_footprint = num_tiles * kv_stride;
    k_base = 32'h0000_2000;
    v_base = k_base + kv_footprint;
    o_base = v_base + kv_footprint;

    $display("\n[E2E] ===== GQA Case: %s (seq=%0d, kv_heads=%0d, ratio=%0d, tiles=%0d, seed=%0d) =====",
      name, seq_len, kv_heads, ratio, num_tiles, seed);

    rst_n = 0;
    repeat(5) @(posedge clk);
    rst_n = 1;
    repeat(5) @(posedge clk);

    dpi_e2e_init(HEAD_DIM, seq_len, NUM_HEADS);

    // Q：每个 Q head 独立随机（Q 侧不共享，仍是 NUM_HEADS 份）
    prng_state = seed;
    for (int h = 0; h < NUM_HEADS; h++)
      for (int i = 0; i < HEAD_DIM; i++) begin
        q_data[h][i] = rand_fp32(val_range);
        ddr_write(Q_BASE_ADDR + (h * HEAD_DIM + i) * 4, q_data[h][i]);
        dpi_e2e_set_q(h, i, q_data[h][i]);
      end

    // K/V：先为 kv_heads 份唯一 KV 生成随机数据
    for (int kv = 0; kv < kv_heads; kv++)
      for (int r = 0; r < seq_len; r++)
        for (int c = 0; c < HEAD_DIM; c++) begin
          k_data[kv][r][c] = rand_fp32(val_range);
          v_data[kv][r][c] = rand_fp32(val_range);
        end

    // golden：NUM_HEADS 个 head，head h 用 kv_head = h/ratio 的数据（共享组填相同）
    for (int h = 0; h < NUM_HEADS; h++)
      for (int r = 0; r < seq_len; r++)
        for (int c = 0; c < HEAD_DIM; c++) begin
          dpi_e2e_set_k(h, r, c, k_data[h / ratio][r][c]);
          dpi_e2e_set_v(h, r, c, v_data[h / ratio][r][c]);
        end

    // DDR：只摆 kv_heads 份（tile-major，每 tile 内 kv_heads 份连续），
    // 硬件按 REG_NUM_HEADS=kv_heads 读入后 fanout 到 NUM_HEADS 组
    for (int tile = 0; tile < num_tiles; tile++)
      for (int kv = 0; kv < kv_heads; kv++)
        for (int r = 0; r < seq_tile_len; r++)
          for (int c = 0; c < HEAD_DIM; c++) begin
            int grow = tile * seq_tile_len + r;
            logic [31:0] kval = (grow < seq_len) ? k_data[kv][grow][c] : 32'h0;
            logic [31:0] vval = (grow < seq_len) ? v_data[kv][grow][c] : 32'h0;
            ddr_write(k_base + tile * kv_stride + (kv * seq_tile_len * HEAD_DIM + r * HEAD_DIM + c) * 4, kval);
            ddr_write(v_base + tile * kv_stride + (kv * seq_tile_len * HEAD_DIM + r * HEAD_DIM + c) * 4, vval);
          end

    for (int i = 0; i < NUM_HEADS * HEAD_DIM; i++)
      ddr_write(o_base + i * 4, 32'hDEAD_BEEF);

    dpi_e2e_compute();

    axi_write(REG_Q_BASE, Q_BASE_ADDR);
    axi_write(REG_K_BASE, k_base);
    axi_write(REG_V_BASE, v_base);
    axi_write(REG_O_BASE, o_base);
    axi_write(REG_HEAD_DIM, HEAD_DIM);
    axi_write(REG_SEQ_LEN, seq_len);
    axi_write(REG_KV_STRIDE, kv_stride);
    axi_write(REG_NUM_HEADS, kv_heads);       // 关键：告诉硬件本趟只有 kv_heads 份唯一 KV
    axi_write(REG_GROUP_MODE, GROUP_MODE);
    case (HEAD_DIM)
      8:  axi_write(REG_ATTN_SCALE, 32'h3F0293EE);
      16: axi_write(REG_ATTN_SCALE, 32'h3EB8AA3B);
      32: axi_write(REG_ATTN_SCALE, 32'h3E8293EE);
      48: axi_write(REG_ATTN_SCALE, 32'h3E553B95);
      64: axi_write(REG_ATTN_SCALE, 32'h3E38AA3B);
      default: axi_write(REG_ATTN_SCALE, 32'h3F0293EE);
    endcase

    axi_write(REG_CTRL, 32'h0000_0003);

    for (int cyc = 0; cyc < TIMEOUT_CYCLES; cyc++) begin
      @(posedge clk);
      if (CB_done) break;
      if (cyc == TIMEOUT_CYCLES - 1) begin
        $display("[E2E] [FAIL] TIMEOUT case=%s", name);
        return;
      end
    end
    @(posedge clk); @(posedge clk);

    errors = 0;
    for (int h = 0; h < NUM_HEADS; h++)
      for (int i = 0; i < HEAD_DIM; i++) begin
        dut_val = ddr_read(o_base + (h * HEAD_DIM + i) * 4);
        errors += dpi_e2e_compare(h, i, dut_val);
      end

    dpi_e2e_report();

    if (errors == 0)
      $display("[E2E] PASS case=%s", name);
    else
      $display("[E2E] [FAIL] case=%s errors=%0d", name, errors);
  endtask

  // ============================================================
  // 从hex文件加载板上数据的回放case
  // 用于复现板上Inf bug，数据由 scripts/parse_board_dump.py 生成
  // ============================================================

  task automatic run_case_from_file(
    input string name,
    input int    seq_len,
    input string q_file,
    input string k_file,
    input string v_file
  );
    int kv_stride;
    int num_tiles;
    int errors;
    logic [31:0] status;
    logic [31:0] dut_val;
    // 本地BASE别名（与run_case一致，便于统一修改）
    logic [31:0] k_base = K_BASE_ADDR;
    logic [31:0] v_base = V_BASE_ADDR;
    logic [31:0] o_base = O_BASE_ADDR;

    // 本地存储：用于$readmemh加载
    // 最大Q容量: 4 heads × 8 dim = 32
    localparam int Q_TOTAL = 32;
    logic [31:0] q_mem [0:Q_TOTAL-1];
    // K/V最大容量: 20 tiles × 4 heads × 8 rows × 8 cols = 5120
    localparam int KV_TOTAL = 20 * 4 * 8 * 8;
    logic [31:0] k_mem [0:KV_TOTAL-1];
    logic [31:0] v_mem [0:KV_TOTAL-1];

    num_tiles = (seq_len + HEAD_DIM - 1) / HEAD_DIM;
    kv_stride = NUM_HEADS * HEAD_DIM * HEAD_DIM * 4;

    $display("\n[E2E] ========== Case: %s (FILE REPLAY, seq=%0d, tiles=%0d) ==========",
      name, seq_len, num_tiles);

    // 加载hex文件
    $readmemh(q_file, q_mem);
    $readmemh(k_file, k_mem);
    $readmemh(v_file, v_mem);
    $display("[E2E] Loaded Q from %s, K from %s, V from %s", q_file, k_file, v_file);

    // 复位硬件
    rst_n = 0;
    repeat(5) @(posedge clk);
    rst_n = 1;
    repeat(5) @(posedge clk);

    // 初始化golden模型
    dpi_e2e_init(HEAD_DIM, seq_len, NUM_HEADS);

    // 写入Q到DDR和golden
    for (int h = 0; h < NUM_HEADS; h++)
      for (int i = 0; i < HEAD_DIM; i++) begin
        logic [31:0] val;
        val = q_mem[h * HEAD_DIM + i];
        ddr_write(Q_BASE_ADDR + (h * HEAD_DIM + i) * 4, val);
        dpi_e2e_set_q(h, i, val);
      end

    // 写入K到DDR和golden
    // hex文件布局: tile × head × row_in_tile × col（与DDR一致）
    for (int tile = 0; tile < num_tiles; tile++)
      for (int h = 0; h < NUM_HEADS; h++)
        for (int r = 0; r < HEAD_DIM; r++)
          for (int c = 0; c < HEAD_DIM; c++) begin
            logic [31:0] val;
            int flat_idx;
            int global_row;
            flat_idx = tile * (NUM_HEADS * HEAD_DIM * HEAD_DIM)
                     + h * (HEAD_DIM * HEAD_DIM)
                     + r * HEAD_DIM + c;
            val = k_mem[flat_idx];
            ddr_write(k_base + tile * kv_stride + (h * HEAD_DIM * HEAD_DIM + r * HEAD_DIM + c) * 4, val);
            // golden使用全局行号
            global_row = tile * HEAD_DIM + r;
            if (global_row < seq_len)
              dpi_e2e_set_k(h, global_row, c, val);
          end

    // 写入V到DDR和golden
    for (int tile = 0; tile < num_tiles; tile++)
      for (int h = 0; h < NUM_HEADS; h++)
        for (int r = 0; r < HEAD_DIM; r++)
          for (int c = 0; c < HEAD_DIM; c++) begin
            logic [31:0] val;
            int flat_idx;
            int global_row;
            flat_idx = tile * (NUM_HEADS * HEAD_DIM * HEAD_DIM)
                     + h * (HEAD_DIM * HEAD_DIM)
                     + r * HEAD_DIM + c;
            val = v_mem[flat_idx];
            ddr_write(v_base + tile * kv_stride + (h * HEAD_DIM * HEAD_DIM + r * HEAD_DIM + c) * 4, val);
            global_row = tile * HEAD_DIM + r;
            if (global_row < seq_len)
              dpi_e2e_set_v(h, global_row, c, val);
          end

    // O区域标记
    for (int i = 0; i < NUM_HEADS * HEAD_DIM; i++)
      ddr_write(o_base + i * 4, 32'hDEAD_BEEF);

    // 计算golden
    dpi_e2e_compute();

    // CSR配置
    axi_write(REG_Q_BASE, Q_BASE_ADDR);
    axi_write(REG_K_BASE, k_base);
    axi_write(REG_V_BASE, v_base);
    axi_write(REG_O_BASE, o_base);
    axi_write(REG_HEAD_DIM, HEAD_DIM);
    axi_write(REG_SEQ_LEN, seq_len);
    axi_write(REG_KV_STRIDE, kv_stride);
    axi_write(REG_NUM_HEADS, NUM_HEADS);
    axi_write(REG_GROUP_MODE, GROUP_MODE);
    case (HEAD_DIM)
      8:  axi_write(REG_ATTN_SCALE, 32'h3F0293EE);
      16: axi_write(REG_ATTN_SCALE, 32'h3EB8AA3B);
      32: axi_write(REG_ATTN_SCALE, 32'h3E8293EE);
      default: axi_write(REG_ATTN_SCALE, 32'h3F0293EE);
    endcase

    // 启动（MODE=FSA, START=1）
    axi_write(REG_CTRL, 32'h0000_0003);

    // 等待完成
    for (int cyc = 0; cyc < TIMEOUT_CYCLES; cyc++) begin
      @(posedge clk);
      if (CB_done) break;
      if (cyc == TIMEOUT_CYCLES - 1) begin
        $display("[E2E] [FAIL] TIMEOUT case=%s", name);
        return;
      end
    end
    @(posedge clk); @(posedge clk);

    // 从DDR读O，逐元素比对
    errors = 0;
    for (int h = 0; h < NUM_HEADS; h++)
      for (int i = 0; i < HEAD_DIM; i++) begin
        dut_val = ddr_read(o_base + (h * HEAD_DIM + i) * 4);
        errors += dpi_e2e_compare(h, i, dut_val);
      end

    // 精度统计报告
    dpi_e2e_report();

    if (errors == 0)
      $display("[E2E] PASS case=%s", name);
    else
      $display("[E2E] [FAIL] case=%s errors=%0d", name, errors);
  endtask

  // ============================================================
  // 主测试序列
  // ============================================================
  initial begin
    // plusarg解析（支持多分组模式）
    if ($value$plusargs("HEAD_DIM=%d", HEAD_DIM)) ;
    if ($value$plusargs("NUM_HEADS=%d", NUM_HEADS)) ;
    if ($value$plusargs("GROUP_MODE=%d", GROUP_MODE)) ;
    // K tile 0 预取模式。判据不变：仍与golden逐位对照，预取只该改变数据何时到达
    if ($value$plusargs("PF_MODE=%d", PF_MODE))
      $display("[E2E] K-prefetch mode PF_MODE=%0d", PF_MODE);
    // 默认沿用fp64理想golden，保持现有139-case基线与豁免清单判定不变
    if ($test$plusargs("GOLDEN_BITACC")) begin
      dpi_e2e_set_mode(1);
      $display("[E2E] golden = BIT-ACCURATE (fp32 + PWL exp2 + online softmax)");
    end else begin
      dpi_e2e_set_mode(0);
      $display("[E2E] golden = IDEAL fp64");
    end
    $display("[E2E] Config: HEAD_DIM=%0d NUM_HEADS=%0d GROUP_MODE=%0d", HEAD_DIM, NUM_HEADS, GROUP_MODE);
    // synopsys translate_off
    $fsdbDumpfile("tb_fsa_e2e.fsdb");
    $fsdbDumpvars(0, tb_fsa_e2e);
    // synopsys translate_on

    // 配置合法性检查
    case (GROUP_MODE)
      0: if (HEAD_DIM != 8 || NUM_HEADS != 4) begin
           $display("[E2E] [FAIL] GROUP_MODE=0 requires HEAD_DIM=8, NUM_HEADS=4");
           $finish;
         end
      1: if (HEAD_DIM != 16 || NUM_HEADS != 2) begin
           $display("[E2E] [FAIL] GROUP_MODE=1 requires HEAD_DIM=16, NUM_HEADS=2");
           $finish;
         end
      2: if ((HEAD_DIM != 32 && HEAD_DIM != 48 && HEAD_DIM != 64) || NUM_HEADS != 1) begin
           $display("[E2E] [FAIL] GROUP_MODE=2 requires HEAD_DIM=32/48/64, NUM_HEADS=1");
           $finish;
         end
      default: begin
        $display("[E2E] [FAIL] Invalid GROUP_MODE=%0d", GROUP_MODE);
        $finish;
      end
    endcase

    init_bus;
    rst_n = 0;
    #50;
    rst_n = 1;
    repeat(5) @(posedge clk);

    // 基本功能（满tile优先验证核心逻辑）
    run_case("fulltile_16", 16, 42, 5.0);
    run_case("2tile_mid", 16, 123, 5.0);
    run_case("4tile_mid", 32, 456, 5.0);
    run_case("1tile_large", 8, 1001, 20.0);
    run_case("2tile_large", 16, 2002, 20.0);
    run_case("1tile_small", 8, 3003, 0.1);

    // 边界条件（极短序列）
    run_case("seq1_boundary", 1, 7001, 5.0);
    run_case("seq2_boundary", 2, 7002, 5.0);
    run_case("seq3_boundary", 3, 7003, 5.0);

    // 最大序列长度（8 tiles）
    run_case("seq64_max", 64, 8001, 5.0);

    // 非整数倍seq_len（最后tile不满）
    run_case("seq5_partial", 5, 5001, 5.0);
    run_case("seq11_partial", 11, 5002, 5.0);
    run_case("seq13_partial", 13, 5003, 10.0);
    run_case("seq7_partial", 7, 5004, 8.0);

    // 多seed覆盖（range=10）
    run_case("2tile_seed0", 16, 10000, 10.0);
    run_case("2tile_seed1", 16, 20000, 10.0);
    run_case("2tile_seed2", 16, 30000, 10.0);
    run_case("2tile_seed3", 16, 40000, 10.0);
    run_case("2tile_seed4", 16, 50000, 10.0);
    run_case("2tile_seed5", 16, 60000, 10.0);
    run_case("2tile_seed6", 16, 70000, 10.0);
    run_case("2tile_seed7", 16, 80000, 10.0);
    run_case("2tile_seed8", 16, 90000, 10.0);
    run_case("2tile_seed9", 16, 99999, 10.0);

    // 板上数据回放（仅4×8模式，hex数据是HEAD_DIM=8）
    if (GROUP_MODE == 0) begin
      run_case_from_file(
        "board_replay_pos154",
        155,
        "tb/board_data/q.hex",
        "tb/board_data/k.hex",
        "tb/board_data/v.hex"
      );
    end

    // 长序列大range：复现板上pos=154 head3 Inf问题
    run_case("long_large_s1", 155, 154001, 20.0);
    run_case("long_large_s2", 155, 154002, 20.0);
    run_case("long_large_s3", 155, 154003, 20.0);
    run_case("long_large_s4", 155, 154004, 25.0);
    run_case("long_large_s5", 155, 154005, 25.0);
    // 诊断：全last_tile_valid覆盖（32tile + last=0..7）
    run_case("seq256_33tile", 256, 256001, 5.0);  // last=0(满)
    run_case("seq249_32tile", 249, 249001, 5.0);  // last=1
    run_case("seq250_32tile", 250, 250001, 5.0);  // last=2
    run_case("seq251_32tile", 251, 251001, 5.0);  // last=3
    run_case("seq252_32tile", 252, 252001, 5.0);  // last=4
    run_case("seq253_32tile", 253, 253001, 5.0);  // last=5
    run_case("seq254_32tile", 254, 254001, 5.0);  // last=6
    run_case("seq255_32tile", 255, 255001, 5.0);  // last=7
    // 注：seq≥257且非满最后tile时触发score masking bug（head2/head3）
    //     与seq_len扩宽无关，是预存在的硬件bug，需单独修复
    run_case("seq511_64tile", 511, 511001, 2.0);  // 9-bit边界
    run_case("seq1023_128tile", 1023, 1023001, 2.0); // 10-bit边界
    // ---- 控制变量诊断（隔离 seq511 FAIL 根因）----
    // A. 满tile vs 非满tile：seq512=64满tile，与seq511唯一差别=最后tile满
    run_case("seq512_fulltile", 512, 512001, 2.0);
    // B. 数据范围：seq511 用 range=5.0（与seq256一致），隔离 range 变量
    run_case("seq511_r5", 511, 511001, 5.0);
    // C. 高tile数+满tile+大range：40满tile，验证"tile>32但满tile"是否坏
    run_case("seq320_full", 320, 320001, 5.0);
    // D. tile数悬崖扫描（统一range=2.0，全满tile，解耦tile数 vs range）
    run_case("sweep_40t_r2", 320, 320002, 2.0);  // 40 tiles
    run_case("sweep_48t_r2", 384, 384002, 2.0);  // 48 tiles
    run_case("sweep_56t_r2", 448, 448002, 2.0);  // 56 tiles
    run_case("sweep_64t_r2", 512, 512002, 2.0);  // 64 tiles

    // head_dim>32定向测试（chunk1+chunk2第一次真实执行，仅在对应HEAD_DIM的
    // invocation里跑，跟其余0/1/2x32现有case互不影响）
    // head_dim=64：chunk2_width=32，K-chunk2不需要DMA padding
    if (HEAD_DIM == 64) begin
      run_case("hd64_fulltile", 64, 640001, 5.0);  // 单tile：验证chunk1+chunk2在一个tile内拼出完整64维score
      run_case("hd64_2tile", 128, 640002, 5.0);    // 多tile：chunk1/chunk2在tile循环中重复执行+online-softmax rescale
      run_case("hd64_partial", 100, 640003, 5.0);  // 非整tile边界（last_tile_valid!=0）
    end
    // head_dim=48：chunk2_width=16，K-chunk2需要DMA padding（cmd_padding_en/cmd_padding_words
    // 第一次被真实触发），覆盖跟head_dim=64不同的代码分支
    if (HEAD_DIM == 48) begin
      run_case("hd48_fulltile", 48, 480001, 5.0);
      run_case("hd48_2tile", 96, 480002, 5.0);
      run_case("hd48_partial", 70, 480003, 5.0);
    end

    // ===== GQA/MQA fanout 定向测试 =====
    // 只在标准 MHA 配置（4×8: HEAD_DIM=8/NUM_HEADS=4；2×16: HEAD_DIM=16/NUM_HEADS=2）
    // 下跑，与 head_dim>32 单头场景无关（1×32 单头无 GQA 意义）。
    // 每档覆盖：单 tile（基础 fanout）/ 多 tile（online-softmax rescale + tile 间计数器回绕）
    // / 非满 tile（last_tile mask）。ratio=NUM_HEADS/kv_heads。
    if (GROUP_MODE == 0) begin
      // 4×8：kv_heads ∈ {1(MQA,ratio4), 2(GQA,ratio2), 4(MHA,ratio1回归)}
      run_case_gqa("gqa4x8_kv2_1tile",  8, 2, 610001, 5.0);   // GQA ratio2 单tile
      run_case_gqa("gqa4x8_kv2_2tile",  16, 2, 610002, 5.0);  // GQA ratio2 多tile
      run_case_gqa("gqa4x8_kv2_partial", 13, 2, 610003, 5.0); // GQA ratio2 非满tile
      run_case_gqa("mqa4x8_kv1_1tile",  8, 1, 611001, 5.0);   // MQA ratio4 单tile
      run_case_gqa("mqa4x8_kv1_2tile",  16, 1, 611002, 5.0);  // MQA ratio4 多tile
      run_case_gqa("mqa4x8_kv1_partial", 11, 1, 611003, 5.0); // MQA ratio4 非满tile
      run_case_gqa("mha4x8_kv4_regr",   16, 4, 612001, 5.0);  // MHA ratio1（fanout退化单热的回归）
    end
    if (GROUP_MODE == 1) begin
      // 2×16：kv_heads ∈ {1(共享,ratio2), 2(MHA,ratio1回归)}
      run_case_gqa("gqa2x16_kv1_1tile",  16, 1, 620001, 5.0);  // 2组共享1份 ratio2 单tile
      run_case_gqa("gqa2x16_kv1_2tile",  32, 1, 620002, 5.0);  // ratio2 多tile
      run_case_gqa("gqa2x16_kv1_partial", 20, 1, 620003, 5.0); // ratio2 非满tile
      run_case_gqa("mha2x16_kv2_regr",   32, 2, 621001, 5.0);  // MHA ratio1 回归
    end

    $display("\n[E2E] ========== ALL CASES DONE ==========");
    $finish;
  end

endmodule

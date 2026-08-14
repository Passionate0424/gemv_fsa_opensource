`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// tb_CB_top_v2_gemv
// Filelist: scripts/cb_top_v2_gemv_filelist.f
// 运行: run_vcs_remote.ps1 -Top tb_CB_top_v2_gemv -Filelist scripts/cb_top_v2_gemv_filelist.f
//
// CB_top_v2 的 GEMV 端到端回归TB
// 通过 CSR 回读、DMA 读写、done/status、DDR 输出比对和
// AXI 响应检查，验证 GEMV 黑盒链路是否按 spec 工作。
//
// golden 来自软件参考模型，不依赖 DUT 内部实现。
////////////////////////////////////////////////////////////////
module tb_CB_top_v2_gemv;

  import tb_cb_baseline_ref_pkg::*;

  localparam int MAX_ROWS = REF_MAX_ROWS;
  localparam int MAX_COLS = REF_MAX_COLS;
  localparam int TIMEOUT_CYCLES = 100000;

  localparam logic [31:0] REG_CTRL_ADDR   = 32'h0000_0000;
  localparam logic [31:0] REG_STATUS_ADDR = 32'h0000_0004;
  localparam logic [31:0] REG_VI_BASE     = 32'h0000_0010;
  localparam logic [31:0] REG_MI_BASE     = 32'h0000_0014;
  localparam logic [31:0] REG_VO_BASE     = 32'h0000_0018;
  localparam logic [31:0] REG_ROWS_ADDR   = 32'h0000_0020;
  localparam logic [31:0] REG_COLS_ADDR   = 32'h0000_0024;
  localparam logic [31:0] REG_ACT_CTRL    = 32'h0000_0058;
  localparam logic [31:0] REG_PF_CTRL     = 32'h0000_005C;

  localparam int CSR_STATUS_BUSY_BIT = 0;
  localparam int CSR_STATUS_DONE_BIT = 1;
  localparam int CSR_STATUS_PF_VALID = 2;
  localparam int CSR_STATUS_PF_TGT   = 3;

  localparam logic [31:0] VI_BASE_ADDR = 32'h0000_1000;
  localparam logic [31:0] MI_BASE_ADDR = 32'h0000_4000;
  localparam logic [31:0] VO_BASE_ADDR = 32'h0001_0000;

  localparam fp32_t FP32_ZERO = 32'h0000_0000;

  logic clk;
  logic rst_n;
  logic CB_done;

  logic [4:0]  s_awid;
  logic [31:0] s_awaddr;
  logic [7:0]  s_awlen;
  logic [2:0]  s_awsize;
  logic [1:0]  s_awburst;
  logic        s_awlock;
  logic [3:0]  s_awcache;
  logic [2:0]  s_awprot;
  logic        s_awvalid;
  logic        s_awready;

  logic [63:0] s_wdata;
  logic [7:0]  s_wstrb;
  logic        s_wlast;
  logic        s_wvalid;
  logic        s_wready;

  logic [4:0]  s_bid;
  logic [1:0]  s_bresp;
  logic        s_bvalid;
  logic        s_bready;

  logic [4:0]  s_arid;
  logic [31:0] s_araddr;
  logic [7:0]  s_arlen;
  logic [2:0]  s_arsize;
  logic [1:0]  s_arburst;
  logic        s_arlock;
  logic [3:0]  s_arcache;
  logic [2:0]  s_arprot;
  logic        s_arvalid;
  logic        s_arready;

  logic [4:0]  s_rid;
  logic [63:0] s_rdata;
  logic [1:0]  s_rresp;
  logic        s_rlast;
  logic        s_rvalid;
  logic        s_rready;

  logic [3:0]  m_awid;
  logic [31:0] m_awaddr;
  logic [7:0]  m_awlen;
  logic [2:0]  m_awsize;
  logic [1:0]  m_awburst;
  logic        m_awlock;
  logic [3:0]  m_awcache;
  logic [2:0]  m_awprot;
  logic        m_awvalid;
  logic        m_awready;

  logic [63:0] m_wdata;
  logic [7:0]  m_wstrb;
  logic        m_wlast;
  logic        m_wvalid;
  logic        m_wready;

  logic [3:0]  m_bid;
  logic [1:0]  m_bresp;
  logic        m_bvalid;
  logic        m_bready;

  logic [3:0]  m_arid;
  logic [31:0] m_araddr;
  logic [7:0]  m_arlen;
  logic [2:0]  m_arsize;
  logic [1:0]  m_arburst;
  logic        m_arlock;
  logic [3:0]  m_arcache;
  logic [2:0]  m_arprot;
  logic        m_arvalid;
  logic        m_arready;

  logic [3:0]  m_rid;
  logic [63:0] m_rdata;
  logic [1:0]  m_rresp;
  logic        m_rlast;
  logic        m_rvalid;
  logic        m_rready;

  logic [4:0]  debug_state;
  logic [15:0] debug_data;

  logic [4:0] ddr_awid;
  logic [4:0] ddr_bid;
  logic [4:0] ddr_arid;
  logic [4:0] ddr_rid;

  fp32_t matrix   [0:MAX_ROWS-1][0:MAX_COLS-1];
  fp32_t vector   [0:MAX_COLS-1];
  fp32_t expected [0:MAX_ROWS-1];

  string case_name;
  int case_rows;
  int case_cols;
  int error_count;
  int unsigned cycle_count;
  int unsigned case_start_cycle;
  int unsigned random_seed_used;

  // 权重预取模式（+PF_MODE=n）。0=不预取（原行为）。非0时在启动前先发一次预取，
  // 每种模式验证一条不同的通路，但**结果都必须与基线逐位相同**——命中要算对，
  // 失效回退也要算对。这样14个现有case各自都能当预取的对照，比另写几个专门case
  // 覆盖得更实在。
  //   1 = 正常命中：预取后直接start，硬件应跳过首块DMA
  //   2 = 失效规则1(ROWS)：预取后重写REG_ROWS，pf_valid必须被清、回退正常搬运
  //   3 = 失效规则1(MI_BASE)：同上，验另一个触发寄存器
  //   4 = 失效规则3(target不符)：以FSA为target预取，GEMV任务启动时不得命中
  int pf_mode;
  int pf_hit_observed;   // 统计实际观测到的PF_VALID置起次数，防"预取根本没发生"的假通过

  int vec_read_addr_hs;
  int mat_read_addr_hs;
  int out_write_addr_hs;
  int read_data_beats;
  int write_data_beats;
  int bresp_error_count;
  int rresp_error_count;
  bit cb_done_seen;
  bit monitor_enable;

  logic [4:0]  dbg_prev_state;
  logic [15:0]  dbg_prev_tile_cnt;
  logic [31:0]  dbg_prev_row_offset;
  logic         dbg_prev_row_tile_start;
  logic         dbg_prev_pe_result_valid;
  logic         dbg_prev_write_done;
  logic         dbg_prev_aw_hs;
  logic         dbg_prev_w_hs;
  logic [3:0]   dbg_row_tile_start_count;
  bit           dbg_pe0_focus_active;
  int unsigned  dbg_pe0_focus_count;

  assign ddr_awid = {1'b0, m_awid};
  assign ddr_arid = {1'b0, m_arid};
  assign m_bid = ddr_bid[3:0];
  assign m_rid = ddr_rid[3:0];

  CB_top_v2 dut (
      .clock(clk),
      .rst_n(rst_n),
      .CB_done(CB_done),
      .s_awid(s_awid),
      .s_awaddr(s_awaddr),
      .s_awlen(s_awlen),
      .s_awsize(s_awsize),
      .s_awburst(s_awburst),
      .s_awlock(s_awlock),
      .s_awcache(s_awcache),
      .s_awprot(s_awprot),
      .s_awvalid(s_awvalid),
      .s_awready(s_awready),
      .s_wdata(s_wdata),
      .s_wstrb(s_wstrb),
      .s_wlast(s_wlast),
      .s_wvalid(s_wvalid),
      .s_wready(s_wready),
      .s_bid(s_bid),
      .s_bresp(s_bresp),
      .s_bvalid(s_bvalid),
      .s_bready(s_bready),
      .s_arid(s_arid),
      .s_araddr(s_araddr),
      .s_arlen(s_arlen),
      .s_arsize(s_arsize),
      .s_arburst(s_arburst),
      .s_arlock(s_arlock),
      .s_arcache(s_arcache),
      .s_arprot(s_arprot),
      .s_arvalid(s_arvalid),
      .s_arready(s_arready),
      .s_rid(s_rid),
      .s_rdata(s_rdata),
      .s_rresp(s_rresp),
      .s_rlast(s_rlast),
      .s_rvalid(s_rvalid),
      .s_rready(s_rready),
      .m_awid(m_awid),
      .m_awaddr(m_awaddr),
      .m_awlen(m_awlen),
      .m_awsize(m_awsize),
      .m_awburst(m_awburst),
      .m_awlock(m_awlock),
      .m_awcache(m_awcache),
      .m_awprot(m_awprot),
      .m_awvalid(m_awvalid),
      .m_awready(m_awready),
      .m_wdata(m_wdata),
      .m_wstrb(m_wstrb),
      .m_wlast(m_wlast),
      .m_wvalid(m_wvalid),
      .m_wready(m_wready),
      .m_bid(m_bid),
      .m_bresp(m_bresp),
      .m_bvalid(m_bvalid),
      .m_bready(m_bready),
      .m_arid(m_arid),
      .m_araddr(m_araddr),
      .m_arlen(m_arlen),
      .m_arsize(m_arsize),
      .m_arburst(m_arburst),
      .m_arlock(m_arlock),
      .m_arcache(m_arcache),
      .m_arprot(m_arprot),
      .m_arvalid(m_arvalid),
      .m_arready(m_arready),
      .m_rid(m_rid),
      .m_rdata(m_rdata),
      .m_rresp(m_rresp),
      .m_rlast(m_rlast),
      .m_rvalid(m_rvalid),
      .m_rready(m_rready),
      .debug_state(debug_state),
      .debug_data(debug_data)
  );

  tb_axi_ram_sp_ext #(
      .Init_File("none")
  ) u_ddr_mem (
      .aclk(clk),
      .aresetn(rst_n),
      .axi_arid(ddr_arid),
      .axi_araddr(m_araddr),
      .axi_arlen(m_arlen),
      .axi_arsize(m_arsize),
      .axi_arburst(m_arburst),
      .axi_arlock({1'b0, m_arlock}),
      .axi_arcache(m_arcache),
      .axi_arprot(m_arprot),
      .axi_arvalid(m_arvalid),
      .axi_arready(m_arready),
      .axi_rid(ddr_rid),
      .axi_rdata(m_rdata),
      .axi_rresp(m_rresp),
      .axi_rlast(m_rlast),
      .axi_rvalid(m_rvalid),
      .axi_rready(m_rready),
      .axi_awid(ddr_awid),
      .axi_awaddr(m_awaddr),
      .axi_awlen(m_awlen),
      .axi_awsize(m_awsize),
      .axi_awburst(m_awburst),
      .axi_awlock({1'b0, m_awlock}),
      .axi_awcache(m_awcache),
      .axi_awprot(m_awprot),
      .axi_awvalid(m_awvalid),
      .axi_awready(m_awready),
      .axi_wdata(m_wdata),
      .axi_wstrb(m_wstrb),
      .axi_wlast(m_wlast),
      .axi_wvalid(m_wvalid),
      .axi_wready(m_wready),
      .axi_bid(ddr_bid),
      .axi_bresp(m_bresp),
      .axi_bvalid(m_bvalid),
      .axi_bready(m_bready)
  );

  initial begin
    clk = 1'b0;
  end

  always #5 clk = ~clk;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cycle_count <= 0;
    end else begin
      cycle_count <= cycle_count + 1;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vec_read_addr_hs   <= 0;
      mat_read_addr_hs   <= 0;
      out_write_addr_hs  <= 0;
      read_data_beats    <= 0;
      write_data_beats   <= 0;
      bresp_error_count  <= 0;
      rresp_error_count  <= 0;
      cb_done_seen       <= 1'b0;
    end else if (!monitor_enable) begin
      vec_read_addr_hs   <= 0;
      mat_read_addr_hs   <= 0;
      out_write_addr_hs  <= 0;
      read_data_beats    <= 0;
      write_data_beats   <= 0;
      bresp_error_count  <= 0;
      rresp_error_count  <= 0;
      cb_done_seen       <= 1'b0;
    end else begin
      if (m_arvalid && m_arready) begin
        if (m_araddr == VI_BASE_ADDR) begin
          vec_read_addr_hs <= vec_read_addr_hs + 1;
        end else if ((m_araddr >= MI_BASE_ADDR) &&
                     (m_araddr < (MI_BASE_ADDR + (MAX_ROWS * MAX_COLS * 4)))) begin
          mat_read_addr_hs <= mat_read_addr_hs + 1;
        end
      end

      if (m_awvalid && m_awready && (m_awaddr == VO_BASE_ADDR)) begin
        out_write_addr_hs <= out_write_addr_hs + 1;
      end

      if (m_rvalid && m_rready) begin
        read_data_beats <= read_data_beats + 1;
        if (m_rresp != 2'b00) begin
          rresp_error_count <= rresp_error_count + 1;
        end
      end

      if (m_wvalid && m_wready) begin
        write_data_beats <= write_data_beats + 1;
      end

      if (m_bvalid && m_bready && (m_bresp != 2'b00)) begin
        bresp_error_count <= bresp_error_count + 1;
      end

      if (CB_done) begin
        cb_done_seen <= 1'b1;
      end
    end
  end

  function automatic string ctrl_state_name(input logic [4:0] state);
    begin
      case (state)
        5'd0:  ctrl_state_name = "IDLE";
        5'd1:  ctrl_state_name = "DMA_VI";
        5'd2:  ctrl_state_name = "WAIT_VI";
        5'd3:  ctrl_state_name = "LOOP_START";
        5'd4:  ctrl_state_name = "DMA_MI_INIT";
        5'd5:  ctrl_state_name = "DMA_MI_ISSUE";
        5'd6:  ctrl_state_name = "DMA_MI_WAIT";
        5'd7:  ctrl_state_name = "COMPUTE";
        5'd8:  ctrl_state_name = "WAIT_COMPUTE";
        5'd9:  ctrl_state_name = "DMA_VO";
        5'd10: ctrl_state_name = "WAIT_VO";
        5'd11: ctrl_state_name = "UPDATE_OFFSET";
        5'd12: ctrl_state_name = "DONE";
        5'd13: ctrl_state_name = "ERROR";
        5'd14: ctrl_state_name = "DMA_VO_INIT";
        5'd15: ctrl_state_name = "ACCUMULATE";
        5'd16: ctrl_state_name = "CHECK_LOOP";
        default: ctrl_state_name = "UNK";
      endcase
    end
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dbg_prev_state         <= 5'd31;
      dbg_prev_tile_cnt      <= 16'hffff;
      dbg_prev_row_offset    <= 32'hffff_ffff;
      dbg_prev_row_tile_start <= 1'b0;
      dbg_prev_pe_result_valid <= 1'bx;
      dbg_prev_write_done    <= 1'bx;
      dbg_prev_aw_hs         <= 1'b0;
      dbg_prev_w_hs          <= 1'b0;
      dbg_row_tile_start_count <= '0;
      dbg_pe0_focus_active   <= 1'b0;
      dbg_pe0_focus_count    <= 0;
    end else begin
      /* DBG_TRACE block removed for PE_core_new_githead compatibility. */
    end
  end

  initial begin
    if (!$test$plusargs("NO_WAVE")) begin
      $fsdbDumpfile("tb_CB_top_v2_gemv.fsdb");
      $fsdbDumpvars(0, tb_CB_top_v2_gemv);
    end
  end

  function automatic fp32_t ddr_read_word(input logic [31:0] byte_addr);
    int unsigned word_addr;
    begin
      word_addr = byte_addr >> 2;
      ddr_read_word = u_ddr_mem.mem[word_addr];
    end
  endfunction

  task automatic ddr_write_word(input logic [31:0] byte_addr, input fp32_t data);
    int unsigned word_addr;
    begin
      word_addr = byte_addr >> 2;
      u_ddr_mem.mem[word_addr] = data;
    end
  endtask

  task automatic ddr_fill_words(
      input logic [31:0] base_addr,
      input int word_count,
      input fp32_t value
  );
    int idx;
    begin
      for (idx = 0; idx < word_count; idx = idx + 1) begin
        ddr_write_word(base_addr + (idx * 4), value);
      end
    end
  endtask

  task automatic init_host_bus;
    begin
      s_awid    = 5'd0;
      s_awaddr  = 32'd0;
      s_awlen   = 8'd0;
      s_awsize  = 3'b010;
      s_awburst = 2'b01;
      s_awlock  = 1'b0;
      s_awcache = 4'd0;
      s_awprot  = 3'd0;
      s_awvalid = 1'b0;

      s_wdata   = 64'd0;
      s_wstrb   = 8'h0F;
      s_wlast   = 1'b1;
      s_wvalid  = 1'b0;
      s_bready  = 1'b1;

      s_arid    = 5'd0;
      s_araddr  = 32'd0;
      s_arlen   = 8'd0;
      s_arsize  = 3'b010;
      s_arburst = 2'b01;
      s_arlock  = 1'b0;
      s_arcache = 4'd0;
      s_arprot  = 3'd0;
      s_arvalid = 1'b0;
      s_rready  = 1'b1;
    end
  endtask

  task automatic clear_case_arrays;
    int r;
    int c;
    begin
      for (r = 0; r < MAX_ROWS; r = r + 1) begin
        expected[r] = FP32_ZERO;
        for (c = 0; c < MAX_COLS; c = c + 1) begin
          matrix[r][c] = FP32_ZERO;
        end
      end

      for (c = 0; c < MAX_COLS; c = c + 1) begin
        vector[c] = FP32_ZERO;
      end
    end
  endtask

  task automatic note_fail(input string message);
    begin
      error_count = error_count + 1;
      $display("[FAIL] case=%0s %0s", case_name, message);
    end
  endtask

  task automatic note_mismatch(
      input string kind,
      input int index,
      input logic [31:0] expected_value,
      input logic [31:0] actual_value
  );
    begin
      error_count = error_count + 1;
      $display(
          "[MISMATCH] case=%0s kind=%0s index=%0d expected=0x%08h actual=0x%08h",
          case_name,
          kind,
          index,
          expected_value,
          actual_value
      );
    end
  endtask

  task automatic populate_random_dense_inputs(
      input int rows,
      input int cols,
      input int unsigned seed_base
  );
    int r;
    int c;
    int signed sample_value;
    int unsigned prng_state;
    begin
      prng_state = seed_base;

      for (c = 0; c < cols; c = c + 1) begin
        prng_state = (prng_state * 32'd1664525) + 32'd1013904223;
        sample_value = int'(prng_state % 7) - 3;
        vector[c] = fp32_from_real(sample_value);
      end

      for (r = 0; r < rows; r = r + 1) begin
        for (c = 0; c < cols; c = c + 1) begin
          prng_state = (prng_state * 32'd1664525) + 32'd1013904223;
          sample_value = int'(prng_state % 7) - 3;
          matrix[r][c] = fp32_from_real(sample_value);
        end
      end

      // Avoid a degenerate all-zero lead element so the round always exercises MAC activity.
      vector[0] = fp32_from_real((seed_base % 3) + 1);
      matrix[0][0] = fp32_from_real(1.0);
    end
  endtask

  task automatic setup_case_data;
    int idx;
    int parsed_seed;
    int parsed_rows;
    int parsed_cols;
    begin
      clear_case_arrays();
      random_seed_used = 32'd0;

      if (case_name == "TC_Sanity_Check") begin
        case_rows = 4;
        case_cols = 4;

        vector[0] = fp32_from_real(1.0);
        vector[1] = fp32_from_real(2.0);
        vector[2] = fp32_from_real(4.0);
        vector[3] = fp32_from_real(8.0);

        matrix[0][0] = fp32_from_real(1.0);

        matrix[1][1] = fp32_from_real(1.0);
        matrix[1][2] = fp32_from_real(1.0);

        matrix[2][0] = fp32_from_real(2.0);
        matrix[2][3] = fp32_from_real(-1.0);

        matrix[3][3] = fp32_from_real(4.0);
      end else if (case_name == "TC_Identity_Matrix") begin
        case_rows = 32;
        case_cols = 32;

        for (idx = 0; idx < 32; idx = idx + 1) begin
          vector[idx] = fp32_from_real(idx + 1);
          matrix[idx][idx] = fp32_from_real(1.0);
        end
      end else if (case_name == "TC_Small_8x8") begin
        case_rows = 8;
        case_cols = 8;

        for (idx = 0; idx < 8; idx = idx + 1) begin
          vector[idx] = fp32_from_real(idx + 1);
          matrix[idx][idx] = fp32_from_real(1.0);
        end
      end else if (case_name == "TC_Zero_Matrix") begin
        case_rows = 32;
        case_cols = 64;

        for (idx = 0; idx < 64; idx = idx + 1) begin
          vector[idx] = fp32_from_real(idx + 1);
        end
      end else if (case_name == "TC_Boundary_NoTiling") begin
        case_rows = 32;
        case_cols = 64;

        for (idx = 0; idx < 64; idx = idx + 1) begin
          vector[idx] = fp32_from_real(idx + 1);
        end

        for (idx = 0; idx < 32; idx = idx + 1) begin
          matrix[idx][idx]      = fp32_from_real(1.0);
          matrix[idx][idx + 32] = fp32_from_real(1.0);
        end
      end else if (case_name == "TC_OS_Row_Shift64") begin
        case_rows = 32;
        case_cols = 64;

        for (idx = 0; idx < 64; idx = idx + 1) begin
          vector[idx] = fp32_from_real(idx + 1);
        end

        for (idx = 0; idx < 32; idx = idx + 1) begin
          matrix[idx][idx] = fp32_from_real(1.0);
        end
      end else if (case_name == "TC_OS_Drain_LastColumn") begin
        case_rows = 32;
        case_cols = 64;

        for (idx = 0; idx < 64; idx = idx + 1) begin
          vector[idx] = fp32_from_real(idx + 1);
        end

        for (idx = 0; idx < 32; idx = idx + 1) begin
          matrix[idx][63] = fp32_from_real(idx + 1);
        end
      end else if (case_name == "TC_OS_TwoTile_128") begin
        case_rows = 32;
        case_cols = 128;

        for (idx = 0; idx < 128; idx = idx + 1) begin
          vector[idx] = fp32_from_real(idx + 1);
        end

        for (idx = 0; idx < 32; idx = idx + 1) begin
          matrix[idx][idx]      = fp32_from_real(1.0);
          matrix[idx][idx + 32] = fp32_from_real(1.0);
          matrix[idx][idx + 64] = fp32_from_real(1.0);
          matrix[idx][idx + 96] = fp32_from_real(1.0);
        end
      end else if (case_name == "TC_OS_SingleTile_64x64") begin
        case_rows = 64;
        case_cols = 64;

        for (idx = 0; idx < 64; idx = idx + 1) begin
          vector[idx] = fp32_from_real(idx + 1);
          matrix[idx][idx] = fp32_from_real(1.0);
        end
      end else if (case_name == "TC_OS_RowTile_64x128") begin
        case_rows = 64;
        case_cols = 128;

        for (idx = 0; idx < 128; idx = idx + 1) begin
          vector[idx] = fp32_from_real(idx + 1);
        end

        for (idx = 0; idx < 64; idx = idx + 1) begin
          matrix[idx][idx]       = fp32_from_real(1.0);
          matrix[idx][idx + 64]  = fp32_from_real(1.0);
        end
      end else if (case_name == "TC_OS_RowTile_33x64") begin
        case_rows = 33;
        case_cols = 64;

        for (idx = 0; idx < 64; idx = idx + 1) begin
          vector[idx] = fp32_from_real(idx + 1);
        end

        for (idx = 0; idx < 32; idx = idx + 1) begin
          matrix[idx][idx] = fp32_from_real(1.0);
        end
        matrix[32][0] = fp32_from_real(1.0);
      end else if (case_name == "TC_OS_RowTile_33x128") begin
        case_rows = 33;
        case_cols = 128;

        for (idx = 0; idx < 128; idx = idx + 1) begin
          vector[idx] = fp32_from_real(idx + 1);
        end

        for (idx = 0; idx < 32; idx = idx + 1) begin
          matrix[idx][idx]       = fp32_from_real(1.0);
          matrix[idx][idx + 64]  = fp32_from_real(1.0);
        end
        matrix[32][0] = fp32_from_real(1.0);
        matrix[32][64] = fp32_from_real(1.0);
      end else if (case_name == "TC_OS_RowCol_33x172") begin
        case_rows = 33;
        case_cols = 172;

        for (idx = 0; idx < 172; idx = idx + 1) begin
          vector[idx] = fp32_from_real(idx + 1);
        end

        for (idx = 0; idx < 32; idx = idx + 1) begin
          matrix[idx][idx]       = fp32_from_real(1.0);
          matrix[idx][idx + 64]  = fp32_from_real(1.0);
          matrix[idx][idx + 128] = fp32_from_real(1.0);
        end
        matrix[32][0]   = fp32_from_real(1.0);
        matrix[32][64]  = fp32_from_real(1.0);
        matrix[32][128] = fp32_from_real(1.0);
      end else if (case_name == "TC_OS_RowCol_64x172") begin
        case_rows = 64;
        case_cols = 172;

        for (idx = 0; idx < 172; idx = idx + 1) begin
          vector[idx] = fp32_from_real(idx + 1);
        end

        for (idx = 0; idx < 64; idx = idx + 1) begin
          matrix[idx][idx]       = fp32_from_real(1.0);
          matrix[idx][idx + 64]  = fp32_from_real(1.0);
          matrix[idx][idx + 128] = fp32_from_real(1.0);
        end
      end else if (case_name == "TC_OS_Stress_MultiVec") begin
        // 压力测试：固定weight，每次迭代随机化vector，连续跑200次
        // 模拟推理中同一层权重不变、输入向量每次不同的场景
        // 使用多tile维度（64x172=3 col tiles）复现板上多tile累积错误
        if (!$value$plusargs("RAND_SEED=%d", parsed_seed)) begin
          parsed_seed = 42;
        end
        if (!$value$plusargs("RAND_ROWS=%d", parsed_rows)) begin
          parsed_rows = 64;
        end
        if (!$value$plusargs("RAND_COLS=%d", parsed_cols)) begin
          parsed_cols = 172;
        end
        case_rows = parsed_rows;
        case_cols = parsed_cols;
        random_seed_used = parsed_seed;
        populate_random_dense_inputs(case_rows, case_cols, random_seed_used);

      end else if (case_name == "TC_OS_Random") begin
        if (!$value$plusargs("RAND_ROWS=%d", parsed_rows)) begin
          parsed_rows = 32;
        end
        if (!$value$plusargs("RAND_COLS=%d", parsed_cols)) begin
          parsed_cols = 64;
        end
        if (!$value$plusargs("RAND_SEED=%d", parsed_seed)) begin
          parsed_seed = 1;
        end

        case_rows = parsed_rows;
        case_cols = parsed_cols;
        random_seed_used = parsed_seed;

        if ((case_rows <= 0) || (case_rows > MAX_ROWS)) begin
          note_fail($sformatf("invalid RAND_ROWS=%0d", case_rows));
        end
        if (!((case_cols == 64) || (case_cols == 128) || (case_cols == 172))) begin
          note_fail($sformatf("RAND_COLS=%0d unsupported; use 64, 128 or 172", case_cols));
        end

        if (error_count == 0) begin
          populate_random_dense_inputs(case_rows, case_cols, random_seed_used);
        end
      end else begin
        case_rows = 0;
        case_cols = 0;
        note_fail($sformatf("unknown CASE plusarg: %0s", case_name));
      end

      if (case_rows > 0 && case_cols > 0) begin
        matvec_golden_dense(case_rows, case_cols, matrix, vector, expected);
      end
    end
  endtask

  task automatic preload_ddr_dense_inputs;
    int r;
    int c;
    logic [31:0] matrix_addr;
    begin
      ddr_fill_words(VI_BASE_ADDR, MAX_COLS, FP32_ZERO);
      ddr_fill_words(MI_BASE_ADDR, MAX_ROWS * MAX_COLS, FP32_ZERO);
      ddr_fill_words(VO_BASE_ADDR, MAX_ROWS, 32'hDEAD_BEEF);

      for (c = 0; c < case_cols; c = c + 1) begin
        ddr_write_word(VI_BASE_ADDR + (c * 4), vector[c]);
      end

      for (r = 0; r < case_rows; r = r + 1) begin
        for (c = 0; c < case_cols; c = c + 1) begin
          matrix_addr = MI_BASE_ADDR + (((r * case_cols) + c) * 4);
          ddr_write_word(matrix_addr, matrix[r][c]);
        end
      end
    end
  endtask

  task automatic axi_csr_write(input logic [31:0] addr, input logic [31:0] data);
    begin
      @(posedge clk);
      s_awid    <= 5'd1;
      s_awaddr  <= addr;
      s_awlen   <= 8'd0;
      s_awsize  <= 3'b010;
      s_awburst <= 2'b01;
      s_awlock  <= 1'b0;
      s_awcache <= 4'd0;
      s_awprot  <= 3'd0;
      s_awvalid <= 1'b1;

      while (!s_awready) begin
        @(posedge clk);
      end

      @(posedge clk);
      s_awvalid <= 1'b0;
      s_awaddr  <= 32'd0;

      // 总线 64 位而 CSR 是 32 位寄存器，数据要落在 addr[2] 指定的那半数据道
      s_wdata  <= {2{data}};
      s_wstrb  <= addr[2] ? 8'hF0 : 8'h0F;
      s_wlast  <= 1'b1;
      s_wvalid <= 1'b1;

      while (!s_wready) begin
        @(posedge clk);
      end

      @(posedge clk);
      s_wvalid <= 1'b0;
      s_wdata  <= 64'd0;

      wait (s_bvalid === 1'b1);
      @(posedge clk);
    end
  endtask

  task automatic axi_csr_read(input logic [31:0] addr, output logic [31:0] data);
    begin
      @(posedge clk);
      s_arid    <= 5'd2;
      s_araddr  <= addr;
      s_arlen   <= 8'd0;
      s_arsize  <= 3'b010;
      s_arburst <= 2'b01;
      s_arlock  <= 1'b0;
      s_arcache <= 4'd0;
      s_arprot  <= 3'd0;
      s_arvalid <= 1'b1;

      while (!s_arready) begin
        @(posedge clk);
      end

      @(posedge clk);
      s_arvalid <= 1'b0;
      s_araddr  <= 32'd0;

      wait (s_rvalid === 1'b1);
      data = addr[2] ? s_rdata[63:32] : s_rdata[31:0];
      @(posedge clk);
    end
  endtask

  // 发起一次权重预取并按pf_mode验证对应的通路。
  // 前提：调用前CSR已由configure_dut()配好——预取用的就是这份配置，硬件不另存
  // 一套影子寄存器，这也正是"重写配置即作废"那条规则的由来。
  task automatic do_prefetch(input int mode);
    logic [31:0] st;
    int poll_cnt;
    begin
      if (mode == 4) begin
        // target=FSA的K，而本次跑的是GEMV任务，硬件应因模式不符而拒绝命中。
        // 先给FSA那组CSR配合法值，让预取真的执行完：head_dim/seq_len为0会触发
        // 硬件的尺寸非法保护而根本不发预取，那样这条规则就成了空验。
        // K源复用矩阵区（有真实数据），GEMV自己的rows/cols/mi_base不受影响。
        axi_csr_write(32'h0040, 32'd8);            // HEAD_DIM
        axi_csr_write(32'h0044, 32'd8);            // SEQ_LEN
        axi_csr_write(32'h0048, 32'd256);          // KV_STRIDE = 8*8*4
        axi_csr_write(32'h004C, 32'd1);            // NUM_HEADS
        axi_csr_write(32'h0034, MI_BASE_ADDR);     // K_BASE
        axi_csr_write(REG_PF_CTRL, 32'h0000_0003); // [1:0] = {target=1, start=1}
      end else begin
        axi_csr_write(REG_PF_CTRL, 32'h0000_0001); // target=0(GEMV权重), start=1
      end

      // 轮询STATUS[2]=PF_VALID等预取的DMA跑完。等到置起才说明数据已在SRAM里，
      // 后续的"命中"才有意义；超时未置起直接判失败，不让case静默滑过去。
      poll_cnt = 0;
      st = 32'd0;
      while (st[CSR_STATUS_PF_VALID] !== 1'b1 && poll_cnt < 4000) begin
        axi_csr_read(REG_STATUS_ADDR, st);
        poll_cnt = poll_cnt + 1;
      end

      if (mode == 4) begin
        // target=FSA时pf_valid照样会置起（预取本身成功了），只是GEMV任务不该用它
        if (st[CSR_STATUS_PF_VALID] !== 1'b1) begin
          note_fail("PF(mode4): FSA-target prefetch never completed");
        end else begin
          if (st[CSR_STATUS_PF_TGT] !== 1'b1)
            note_fail("PF(mode4): STATUS.PF_TGT should mirror target=1");
          // 计入完成数：这次预取本身是成功的，只是随后因target与任务模式不符
          // 而不会被采用。pf_hit_observed统计的是"预取完成"而非"被命中采用"。
          pf_hit_observed = pf_hit_observed + 1;
        end
      end else if (st[CSR_STATUS_PF_VALID] !== 1'b1) begin
        note_fail($sformatf("PF(mode%0d): PF_VALID never asserted after %0d polls",
                            mode, poll_cnt));
      end else begin
        pf_hit_observed = pf_hit_observed + 1;
      end

      // 失效通路：重写决定"搬什么/搬多少"的CSR，pf_valid必须当场清掉
      if (mode == 2 || mode == 3) begin
        if (mode == 2) axi_csr_write(REG_ROWS_ADDR, case_rows);
        else           axi_csr_write(REG_MI_BASE,   MI_BASE_ADDR);
        axi_csr_read(REG_STATUS_ADDR, st);
        if (st[CSR_STATUS_PF_VALID] !== 1'b0)
          note_fail($sformatf(
              "PF(mode%0d): PF_VALID must clear after rewriting %0s",
              mode, (mode == 2) ? "ROWS" : "MI_BASE"));
        else
          $display("[INFO] PF(mode%0d): invalidation on config write OK", mode);
      end
    end
  endtask

  task automatic check_csr_readback(
      input string reg_name,
      input logic [31:0] addr,
      input logic [31:0] expected_value
  );
    logic [31:0] actual_value;
    begin
      axi_csr_read(addr, actual_value);
      if (actual_value !== expected_value) begin
        error_count = error_count + 1;
        $display(
            "[MISMATCH] case=%0s kind=CSR name=%0s expected=0x%08h actual=0x%08h",
            case_name,
            reg_name,
            expected_value,
            actual_value
        );
      end
    end
  endtask

  task automatic configure_dut;
    begin
      axi_csr_write(REG_VI_BASE, VI_BASE_ADDR);
      check_csr_readback("VI_BASE", REG_VI_BASE, VI_BASE_ADDR);

      axi_csr_write(REG_MI_BASE, MI_BASE_ADDR);
      check_csr_readback("MI_BASE", REG_MI_BASE, MI_BASE_ADDR);

      axi_csr_write(REG_VO_BASE, VO_BASE_ADDR);
      check_csr_readback("VO_BASE", REG_VO_BASE, VO_BASE_ADDR);

      axi_csr_write(REG_ROWS_ADDR, case_rows);
      check_csr_readback("ROWS", REG_ROWS_ADDR, case_rows);

      axi_csr_write(REG_COLS_ADDR, case_cols);
      check_csr_readback("COLS", REG_COLS_ADDR, case_cols);
    end
  endtask

  task automatic wait_for_done_status(
      output bit busy_seen,
      output bit done_seen,
      output bit timeout_hit,
      output logic [31:0] last_status
  );
    logic [31:0] status_value;
    int unsigned deadline_cycle;
    begin
      busy_seen = 1'b0;
      done_seen = 1'b0;
      timeout_hit = 1'b0;
      last_status = 32'd0;
      deadline_cycle = case_start_cycle + TIMEOUT_CYCLES;

      while (!done_seen && (cycle_count < deadline_cycle)) begin
        axi_csr_read(REG_STATUS_ADDR, status_value);
        last_status = status_value;
        if (status_value[CSR_STATUS_BUSY_BIT]) begin
          busy_seen = 1'b1;
        end
        if (status_value[CSR_STATUS_DONE_BIT]) begin
          done_seen = 1'b1;
        end
      end

      if (!done_seen) begin
        timeout_hit = 1'b1;
      end
    end
  endtask

  task automatic compare_outputs;
    int row;
    fp32_t actual_word;
    begin
      for (row = 0; row < case_rows; row = row + 1) begin
        actual_word = ddr_read_word(VO_BASE_ADDR + (row * 4));
        if (actual_word !== expected[row]) begin
          note_mismatch("OUTPUT", row, expected[row], actual_word);
        end
      end
    end
  endtask

  task automatic validate_dma_activity;
    begin
      if (vec_read_addr_hs <= 0) begin
        note_fail("vector DMA read transaction was not observed");
      end
      if (mat_read_addr_hs <= 0) begin
        note_fail("matrix DMA read transaction was not observed");
      end

      // 矩阵AR事务总数可精确预测，且四条预取通路各有不同的预期值——这是判断
      // 预取是否真正生效的黑盒判据。结果正确性本身区分不出"命中跳过首块"和
      // "预取白搬一趟再照常搬全部"，但AR总数能：
      //   命中   → 预取那趟替代首块，总数与不预取时相同
      //   失效   → 预取白搬一个首块，总数多出首块的AR数
      //   不符   → 预取搬的是FSA的K，总数多出K tile0的AR数
      // 任务本身的AR数口径随tile路径而异：cols>64走多tile，cmd_block_count恒为
      // HW_ROWS-1，每个行块固定搬32行（尾块多搬的由padding兜住）；cols<=64的
      // 单tile路径按current_rows搬实际行数。
      begin
        int task_ar;        // 任务本身要搬的AR数
        int first_block_ar; // 一个首块的AR数
        int pf_extra;       // 预取带来的额外AR数

        if (case_cols > 64) begin
          task_ar        = ((case_rows + 31) / 32) * 32 * ((case_cols + 63) / 64);
          first_block_ar = 32;
        end else begin
          task_ar        = case_rows;
          first_block_ar = (case_rows > 32) ? 32 : case_rows;
        end

        case (pf_mode)
          0, 1:    pf_extra = 0;               // 不预取，或命中后预取替代了首块
          2, 3:    pf_extra = first_block_ar;  // 配置被改写，预取作废、白搬一趟
          // target不符：预取搬的是FSA的K tile0，do_prefetch按head_dim=8、
          // num_kv_heads=1配置，故block_count=1×8-1=7，共8笔AR
          4:       pf_extra = 8;
          default: pf_extra = 0;
        endcase

        if (mat_read_addr_hs != task_ar + pf_extra) begin
          note_fail($sformatf(
              "matrix AR count=%0d expected=%0d (task=%0d pf_extra=%0d rows=%0d cols=%0d pf_mode=%0d)",
              mat_read_addr_hs, task_ar + pf_extra, task_ar, pf_extra,
              case_rows, case_cols, pf_mode));
        end
      end
      if (out_write_addr_hs <= 0) begin
        note_fail("output DMA write transaction was not observed");
      end
      if (rresp_error_count != 0) begin
        note_fail("non-zero RRESP observed on AXI read channel");
      end
      if (bresp_error_count != 0) begin
        note_fail("non-zero BRESP observed on AXI write response channel");
      end
    end
  endtask

  task automatic run_selected_case;
    bit busy_seen;
    bit done_seen;
    bit timeout_hit;
    logic [31:0] status_value;
    begin
      error_count = 0;
      monitor_enable = 1'b0;

      setup_case_data();
      if (error_count != 0) begin
        return;
      end

      preload_ddr_dense_inputs();
      configure_dut();

      if (case_name == "TC_OS_Random") begin
        $display(
            "[INFO] case=%0s seed=%0d rows=%0d cols=%0d",
            case_name,
            random_seed_used,
            case_rows,
            case_cols
        );
      end

      // monitor在预取之前打开，把预取那趟DMA也纳入统计。这样mat_reads的语义是
      // "本次任务搬矩阵的总次数"：命中时预取替代首块，总数与不预取的基线相同；
      // 若命中失效变成额外多搬一趟，总数会比基线多1——这是判断预取是否真正
      // 生效的黑盒判据（结果正确性本身区分不出这两种情况）。
      monitor_enable = 1'b1;
      case_start_cycle = cycle_count;

      // 预取必须在start之前、configure_dut之后发——它用的就是那份CSR配置
      if (pf_mode != 0) do_prefetch(pf_mode);

      axi_csr_write(REG_CTRL_ADDR, 32'h0000_0001);
      check_csr_readback("CTRL", REG_CTRL_ADDR, 32'h0000_0001);

      wait_for_done_status(busy_seen, done_seen, timeout_hit, status_value);

      if (!busy_seen) begin
        note_fail("busy bit never asserted after start");
      end
      if (timeout_hit) begin
        note_fail($sformatf(
            "TIMEOUT waiting for done; cycle=%0d state=0x%0h status=0x%08h debug=0x%04h",
            cycle_count,
            debug_state,
            status_value,
            debug_data
        ));
      end
      if (!done_seen) begin
        note_fail("done bit was not observed in status register");
      end
      if (!cb_done_seen) begin
        note_fail("CB_done output was never observed");
      end

      validate_dma_activity();
      compare_outputs();

      $display(
          "[INFO] case=%0s rows=%0d cols=%0d cycles=%0d vec_reads=%0d mat_reads=%0d read_beats=%0d out_writes=%0d write_beats=%0d",
          case_name,
          case_rows,
          case_cols,
          (cycle_count - case_start_cycle),
          vec_read_addr_hs,
          mat_read_addr_hs,
          read_data_beats,
          out_write_addr_hs,
          write_data_beats
      );
    end
  endtask

  initial begin
    init_host_bus();
    rst_n = 1'b0;
    case_name = "TC_Sanity_Check";
    monitor_enable = 1'b0;
    error_count = 0;
    pf_mode = 0;
    pf_hit_observed = 0;

    if ($value$plusargs("CASE=%s", case_name)) begin
      $display("[INFO] selected CASE=%0s", case_name);
    end else begin
      $display("[INFO] CASE plusarg not provided, defaulting to %0s", case_name);
    end

    // +PF_MODE=n 让同一个case在预取通路上重跑一遍。判据不是"跑通"，而是
    // 结果与PF_MODE=0的基线逐位相同——命中要算对，失效回退也要算对。
    if ($value$plusargs("PF_MODE=%d", pf_mode)) begin
      $display("[INFO] prefetch mode PF_MODE=%0d", pf_mode);
    end

    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (10) @(posedge clk);

    run_selected_case();

    // Back-to-back测试：模拟板上连续matmul调用（不重新加载DDR，最小间隔）
    if (error_count == 0 && case_name != "TC_OS_Stress_MultiVec") begin
      bit b2b_busy, b2b_done, b2b_timeout;
      logic [31:0] b2b_status;
      $display("[INFO] back-to-back: minimal-gap re-run (no DDR reload)...");
      // 清除DONE状态
      axi_csr_write(REG_CTRL_ADDR, 32'h0000_0000);
      // 毒化output区域，确保能检测到新写入
      ddr_fill_words(VO_BASE_ADDR, MAX_ROWS, 32'hDEAD_BEEF);
      // 立即重新启动（不重新配置CSR，不重新加载DDR）
      monitor_enable = 1'b1;
      case_start_cycle = cycle_count;
      axi_csr_write(REG_CTRL_ADDR, 32'h0000_0001);
      wait_for_done_status(b2b_busy, b2b_done, b2b_timeout, b2b_status);
      if (b2b_timeout) begin
        note_fail("back-to-back TIMEOUT");
      end else begin
        compare_outputs();
      end
      // 防假通过：开了预取模式却一次都没观测到PF_VALID置起，说明预取压根没发生，
      // 那这一轮"通过"只是走了原路径，没验证到任何东西
      if (pf_mode != 0 && pf_hit_observed == 0) begin
        note_fail($sformatf("PF_MODE=%0d but prefetch never completed once", pf_mode));
      end
      if (error_count == 0) begin
        $display("[PASS] case=%0s (back-to-back x2, minimal gap) pf_mode=%0d pf_seen=%0d",
                 case_name, pf_mode, pf_hit_observed);
      end else begin
        $display("[FAIL] case=%0s back-to-back errors=%0d (PE residual!) pf_mode=%0d",
                 case_name, error_count, pf_mode);
      end
    end else begin
      $display("[FAIL] case=%0s errors=%0d", case_name, error_count);
    end

    // Stress MultiVec测试：连续200次不同向量的GEMV，检测NaN
    if (error_count == 0 && case_name == "TC_OS_Stress_MultiVec") begin
      int stress_iter;
      int unsigned stress_seed;
      int unsigned prng;
      int signed sv;
      int nan_detected;
      logic [31:0] out_word;

      nan_detected = 0;
      stress_seed = random_seed_used;

      $display("[INFO] stress: starting 200 iterations with different vectors...");

      for (stress_iter = 1; stress_iter <= 200 && nan_detected == 0; stress_iter = stress_iter + 1) begin
        // 每隔5次迭代插入一次FSA模式切换（模拟真实推理的FSA→GEMV交替）
        if (stress_iter % 5 == 0) begin
          // 配置FSA参数（最小配置，head_dim=8, seq_len=1）
          axi_csr_write(32'h0040, 32'h0000_0008); // head_dim=8
          axi_csr_write(32'h0044, 32'h0000_0001); // seq_len=1
          axi_csr_write(32'h0048, 32'h0000_0400); // kv_stride
          axi_csr_write(32'h0030, VI_BASE_ADDR);  // Q base (reuse vector area)
          axi_csr_write(32'h0034, MI_BASE_ADDR);  // K base (reuse matrix area)
          axi_csr_write(32'h0038, MI_BASE_ADDR);  // V base
          axi_csr_write(32'h003C, VO_BASE_ADDR);  // O base
          axi_csr_write(32'h0050, 32'h3f02_93ee); // attn_scale
          // 启动FSA模式
          axi_csr_write(REG_CTRL_ADDR, 32'h0000_0003);
          // 等待完成
          begin
            bit f_busy, f_done, f_timeout;
            logic [31:0] f_status;
            case_start_cycle = cycle_count;
            wait_for_done_status(f_busy, f_done, f_timeout, f_status);
            if (f_timeout) begin
              $display("[FAIL] stress iter=%0d FSA TIMEOUT", stress_iter);
              nan_detected = 1;
            end
          end
          // 清除done
          axi_csr_write(REG_CTRL_ADDR, 32'h0000_0000);
        end

        // 每次迭代用不同seed生成新向量
        prng = stress_seed + stress_iter * 32'd7919;
        for (int c = 0; c < case_cols; c = c + 1) begin
          prng = (prng * 32'd1664525) + 32'd1013904223;
          sv = int'(prng % 7) - 3;
          vector[c] = fp32_from_real(sv);
        end
        vector[0] = fp32_from_real((stress_iter % 3) + 1);

        // 重新计算golden
        matvec_golden_dense(case_rows, case_cols, matrix, vector, expected);

        // 只重新加载vector到DDR（weight不变）
        for (int c = 0; c < case_cols; c = c + 1) begin
          ddr_write_word(VI_BASE_ADDR + (c * 4), vector[c]);
        end
        // 毒化output
        ddr_fill_words(VO_BASE_ADDR, case_rows, 32'hDEAD_BEEF);

        // 清除DONE + 重新启动
        axi_csr_write(REG_CTRL_ADDR, 32'h0000_0000);

        axi_csr_write(REG_CTRL_ADDR, 32'h0000_0001);

        // 重置超时基准（每次迭代独立计时）
        case_start_cycle = cycle_count;

        // 等待完成（加超时打印）
        begin
          bit s_busy, s_done, s_timeout;
          logic [31:0] s_status;
          wait_for_done_status(s_busy, s_done, s_timeout, s_status);
          if (s_timeout) begin
            $display("[FAIL] stress iter=%0d TIMEOUT status=0x%08h t=%0t", stress_iter, s_status, $time);
            $display("[FAIL] debug_state=%0d CB_done=%b", debug_state, dut.CB_done);
            $display("[FAIL] DMA: m_arvalid=%b m_arready=%b m_rvalid=%b m_rlast=%b",
                     m_arvalid, m_arready, m_rvalid, m_rlast);
            $display("[FAIL] DMA: m_awvalid=%b m_awready=%b m_wvalid=%b m_wlast=%b m_bvalid=%b",
                     m_awvalid, m_awready, m_wvalid, m_wlast, m_bvalid);
            $display("[FAIL] ctrl: cmd_valid=%b cmd_ready=%b dma_done=%b",
                     dut.u_controller.cmd_valid, dut.u_controller.cmd_ready,
                     dut.u_controller.dma_done);
            $display("[FAIL] dma: r_cmd_ready=%b read_All_finish=%b write_finish=%b read_active=%b",
                     dut.u_axi_dma_controller.r_cmd_ready,
                     dut.u_axi_dma_controller.read_All_finish,
                     dut.u_axi_dma_controller.write_finish,
                     dut.u_axi_dma_controller.read_active);
            $display("[FAIL] dma: finished_block_cnt=%0d r_cmd_block_count=%0d r_read_cnt=%0d",
                     dut.u_axi_dma_controller.finished_block_cnt,
                     dut.u_axi_dma_controller.r_cmd_block_count,
                     dut.u_axi_dma_controller.r_read_cnt);
            $display("[FAIL] dma: r_m_axi_rready=%b padding_active=%b r_cmd_padding=%b r_cmd_block_size=%0d",
                     dut.u_axi_dma_controller.r_m_axi_rready,
                     dut.u_axi_dma_controller.padding_active,
                     dut.u_axi_dma_controller.r_cmd_padding,
                     dut.u_axi_dma_controller.r_cmd_block_size);
            $display("[FAIL] bridge: req_o=%b we_o=%b arready=%b rvalid=%b",
                     u_ddr_mem.sram_req,
                     u_ddr_mem.sram_we,
                     u_ddr_mem.axi_arready,
                     u_ddr_mem.axi_rvalid);
            $display("[FAIL] bridge_int: state=%0d cnt=%0d s_rready=%b ax_req_q_len=%0d",
                     u_ddr_mem.u_axi_sram_sp_ext.state_q,
                     u_ddr_mem.u_axi_sram_sp_ext.cnt_q,
                     u_ddr_mem.u_axi_sram_sp_ext.s_rready,
                     u_ddr_mem.u_axi_sram_sp_ext.ax_req_q_len);
            $display("[FAIL] bridge_addr: req_addr_q=0x%08h addr_o=0x%08h",
                     u_ddr_mem.u_axi_sram_sp_ext.req_addr_q,
                     u_ddr_mem.u_axi_sram_sp_ext.addr_o);
            $display("[FAIL] dma_ar: r_m_axi_araddr=0x%08h r_m_axi_arlen=%0d r_m_axi_arvalid=%b",
                     dut.u_axi_dma_controller.r_m_axi_araddr,
                     dut.u_axi_dma_controller.r_m_axi_arlen,
                     dut.u_axi_dma_controller.r_m_axi_arvalid);
            $display("[FAIL] dma_src: r_cmd_src_addr=0x%08h r_cmd_stride=%0d",
                     dut.u_axi_dma_controller.r_cmd_src_addr,
                     dut.u_axi_dma_controller.r_cmd_stride);
            nan_detected = 1;
          end
        end

        // 检查输出是否有NaN
        if (!nan_detected) begin
          for (int r = 0; r < case_rows; r = r + 1) begin
            out_word = u_ddr_mem.mem[(VO_BASE_ADDR >> 2) + r];
            if (out_word[30:23] == 8'hFF && out_word[22:0] != 0) begin
              $display("[NaN] stress iter=%0d row=%0d out=0x%08h", stress_iter, r, out_word);
              $display("[NaN] expected=0x%08h vector[0]=0x%08h", expected[r], vector[0]);
              nan_detected = 1;
              break;
            end
            // 检查数据正确性（与golden比对）
            if (out_word !== expected[r]) begin
              $display("[MISMATCH] stress iter=%0d row=%0d got=0x%08h exp=0x%08h",
                       stress_iter, r, out_word, expected[r]);
              if (r < 5 || r == case_rows-1) begin
                $display("  detail: got=%f exp=%f", $bitstoreal({out_word, 32'b0}), $bitstoreal({expected[r], 32'b0}));
              end
              nan_detected = 1;
              break;
            end
          end
        end

        // 每20次打印进度
        if (stress_iter % 20 == 0 && !nan_detected) begin
          $display("[INFO] stress iter=%0d/200 OK", stress_iter);
        end
      end

      if (nan_detected) begin
        $display("[FAIL] TC_OS_Stress_MultiVec: NaN detected at iter=%0d", stress_iter-1);
        error_count = error_count + 1;
      end else begin
        $display("[PASS] TC_OS_Stress_MultiVec: 200 iterations, no NaN");
      end
    end

    repeat (10) @(posedge clk);
    $finish;
  end

endmodule

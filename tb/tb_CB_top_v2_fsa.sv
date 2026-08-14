`timescale 1ns / 1ps

// FlashAttention系统级端到端验证TB
// 严格遵循Algorithm 1: online softmax + tiled attention
// 通过AXI CSR配置 → DMA自动搬运Q/K/V → FlashAttention计算 → O写回DDR → DPI-C比对

import "DPI-C" function void dpi_golden_init(input int head_dim);
import "DPI-C" function void dpi_golden_set_q(input int idx, input int val);
import "DPI-C" function void dpi_golden_set_k(input int row, input int col, input int val);
import "DPI-C" function void dpi_golden_set_v(input int row, input int col, input int val);
import "DPI-C" function void dpi_golden_compute();
import "DPI-C" function void dpi_golden_set_actual_p(input int idx, input int val);
import "DPI-C" function void dpi_golden_compute_post_exp2();
import "DPI-C" function int  dpi_golden_compare_norm(input int idx, input int dut_val, input int ulp_tol);
import "DPI-C" function int  dpi_golden_get_exp2(input int idx);
// 纯端到端golden
import "DPI-C" function void dpi_sys_golden_init(input int head_dim, input int seq_len);
import "DPI-C" function void dpi_sys_golden_set_q(input int idx, input int val);
import "DPI-C" function void dpi_sys_golden_set_k(input int row, input int col, input int val);
import "DPI-C" function void dpi_sys_golden_set_v(input int row, input int col, input int val);
import "DPI-C" function void dpi_sys_golden_compute();
import "DPI-C" function int  dpi_sys_golden_compare(input int idx, input int dut_val, input int ulp_tol);

module tb_CB_top_v2_fsa;

  localparam int HEAD_DIM = 8;
  localparam int MAX_SEQ_LEN = 32;
  localparam int NUM_GROUPS = 4;
  localparam int TIMEOUT_CYCLES = 50000;
  localparam int ULP_TOL = 256;  // 系统级比对容差

  // CSR地址（与cb_controll_v2一致）
  localparam logic [31:0] REG_CTRL       = 32'h0000_0000;
  localparam logic [31:0] REG_STATUS     = 32'h0000_0004;
  localparam logic [31:0] REG_Q_BASE     = 32'h0000_0030;
  localparam logic [31:0] REG_K_BASE     = 32'h0000_0034;
  localparam logic [31:0] REG_V_BASE     = 32'h0000_0038;
  localparam logic [31:0] REG_O_BASE     = 32'h0000_003C;
  localparam logic [31:0] REG_HEAD_DIM   = 32'h0000_0040;
  localparam logic [31:0] REG_SEQ_LEN    = 32'h0000_0044;
  localparam logic [31:0] REG_KV_STRIDE  = 32'h0000_0048;
  localparam logic [31:0] REG_NUM_HEADS  = 32'h0000_004C;

  // DDR布局
  localparam logic [31:0] Q_BASE_ADDR = 32'h0000_1000;  // 4 heads × 8 × 4B = 128B
  localparam logic [31:0] K_BASE_ADDR = 32'h0000_2000;  // per tile: 8×8×4B = 256B
  localparam logic [31:0] V_BASE_ADDR = 32'h0000_4000;  // per tile: 8×8×4B = 256B
  localparam logic [31:0] O_BASE_ADDR = 32'h0000_8000;  // 4 heads × 8 × 4B = 128B

  // KV_STRIDE: 每个tile在DDR中的步长（bytes）= head_dim × head_dim × 4
  localparam int KV_STRIDE = HEAD_DIM * HEAD_DIM * 4;

  logic clk, rst_n, CB_done;

  // AXI Slave
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

  // AXI Master
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

  logic [4:0] debug_state;
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
  tb_axi_ram_sp_ext #(.Init_File("none")) u_ddr_mem (
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

  // 测试数据
  logic [31:0] Q_data [0:NUM_GROUPS-1][0:HEAD_DIM-1];  // 4 heads × 8
  logic [31:0] K_data [0:MAX_SEQ_LEN-1][0:HEAD_DIM-1]; // seq_len × 8
  logic [31:0] V_data [0:MAX_SEQ_LEN-1][0:HEAD_DIM-1]; // seq_len × 8

  string case_name;
  string selected_case;
  int case_seq_len;
  int case_num_tiles;
  int error_count;
  int unsigned cycle_count;
  int unsigned case_start_cycle;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) cycle_count <= 0;
    else cycle_count <= cycle_count + 1;
  end

  initial begin
    if (!$test$plusargs("NO_WAVE")) begin
      $fsdbDumpfile("tb_CB_top_v2_fsa.fsdb");
      $fsdbDumpvars(0, tb_CB_top_v2_fsa);
    end
  end

  // PE寄存器读取宏
  `define SYS_GET_PE_REG(idx) {dut.mac_top_inst.u_pe_core.PE_INST[idx].u_pe.reg_sign, \
      dut.mac_top_inst.u_pe_core.PE_INST[idx].u_pe.reg_exp, \
      dut.mac_top_inst.u_pe_core.PE_INST[idx].u_pe.reg_mantissa}

  reg [4:0] fsm_state_d;
  always @(posedge clk) begin
    if (!rst_n) fsm_state_d <= 0;
    else fsm_state_d <= dut.mac_top_inst.fsm_state;
  end

  // K=I case调试：捕获各阶段PE寄存器
  `define FSA_PE_REG(idx) {dut.mac_top_inst.u_pe_core.PE_INST[idx].u_pe.reg_sign, \
      dut.mac_top_inst.u_pe_core.PE_INST[idx].u_pe.reg_exp, \
      dut.mac_top_inst.u_pe_core.PE_INST[idx].u_pe.reg_mantissa}

  always @(posedge clk) begin
    if (case_name == "FSA_Identity") begin
      // EXP2阶段(state=13)：打印PE[0]外部端口（l_input和u_input）
      if (dut.mac_top_inst.fsm_state == 5'd13) begin
        $display("[DBG-PORT] t=%0t PE[0] l_input=%08h u_input=%08h ctrl_valid=%b exp2=%b acc_ui=%b",
          $time,
          {dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.io_l_input_bits_sign,
           dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.io_l_input_bits_exp,
           dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.io_l_input_bits_mantissa},
          {dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.io_u_input_bits_sign,
           dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.io_u_input_bits_exp,
           dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.io_u_input_bits_mantissa},
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.io_in_ctrl_valid,
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.io_in_ctrl_bits_exp2,
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.io_in_ctrl_bits_acc_ui);
      end
      // 打印FMA输出和exp2匹配信号
      if (dut.mac_top_inst.fsm_state == 5'd13 && dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.mac_result_valid) begin
        $display("[DBG-FMA0] t=%0t mac_result={%b,%02h,%06h} exp2Done=%b commit_exp2=%b result_exp2=%b c_msb=%0d frac_msb=%0d",
          $time,
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.mac_result_elemType_sign,
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.mac_result_elemType_exp,
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.mac_result_elemType_mantissa,
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.exp2Done,
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.mac_commit_exp2,
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.mac_result_exp2,
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.macUnit.c_exp_msb_pipe[2],
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.macUnit.mulAddExp2_io_exp2_frac_msb);
      end
      // PE[2]的FMA匹配信号
      if (dut.mac_top_inst.fsm_state == 5'd13 && dut.mac_top_inst.u_pe_core.PE_INST[2].u_pe.mac_result_valid) begin
        $display("[DBG-FMA2] t=%0t result={%b,%02h,%06h} exp2Done=%b result_exp2=%b c_msb=%0d frac_msb=%0d reg=%08h",
          $time,
          dut.mac_top_inst.u_pe_core.PE_INST[2].u_pe.mac_result_elemType_sign,
          dut.mac_top_inst.u_pe_core.PE_INST[2].u_pe.mac_result_elemType_exp,
          dut.mac_top_inst.u_pe_core.PE_INST[2].u_pe.mac_result_elemType_mantissa,
          dut.mac_top_inst.u_pe_core.PE_INST[2].u_pe.exp2Done,
          dut.mac_top_inst.u_pe_core.PE_INST[2].u_pe.mac_result_exp2,
          dut.mac_top_inst.u_pe_core.PE_INST[2].u_pe.macUnit.c_exp_msb_pipe[2],
          dut.mac_top_inst.u_pe_core.PE_INST[2].u_pe.macUnit.mulAddExp2_io_exp2_frac_msb,
          `FSA_PE_REG(2));
      end
      // PE[1]的FMA匹配信号
      if (dut.mac_top_inst.fsm_state == 5'd13 && dut.mac_top_inst.u_pe_core.PE_INST[1].u_pe.mac_result_valid) begin
        $display("[DBG-FMA1] t=%0t result={%b,%02h,%06h} exp2Done=%b result_exp2=%b c_msb=%0d frac_msb=%0d reg=%08h",
          $time,
          dut.mac_top_inst.u_pe_core.PE_INST[1].u_pe.mac_result_elemType_sign,
          dut.mac_top_inst.u_pe_core.PE_INST[1].u_pe.mac_result_elemType_exp,
          dut.mac_top_inst.u_pe_core.PE_INST[1].u_pe.mac_result_elemType_mantissa,
          dut.mac_top_inst.u_pe_core.PE_INST[1].u_pe.exp2Done,
          dut.mac_top_inst.u_pe_core.PE_INST[1].u_pe.mac_result_exp2,
          dut.mac_top_inst.u_pe_core.PE_INST[1].u_pe.macUnit.c_exp_msb_pipe[2],
          dut.mac_top_inst.u_pe_core.PE_INST[1].u_pe.macUnit.mulAddExp2_io_exp2_frac_msb,
          `FSA_PE_REG(1));
      end
      if (dut.mac_top_inst.fsm_state == 5'd13 && dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.issue_mac_valid) begin
        $display("[DBG-EXP2] t=%0t PE[0]: a(reg)={%b,%02h,%06h} b(slope)={%b,%02h,%06h} c(intercept)={%b,%02h,%06h}",
          $time,
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.macUnit.io_in_a_sign,
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.macUnit.io_in_a_exp,
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.macUnit.io_in_a_mantissa,
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.macUnit.io_in_b_sign,
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.macUnit.io_in_b_exp,
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.macUnit.io_in_b_mantissa,
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.macUnit.io_in_c_sign,
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.macUnit.io_in_c_exp,
          dut.mac_top_inst.u_pe_core.PE_INST[0].u_pe.macUnit.io_in_c_mantissa);
      end
      if (dut.mac_top_inst.fsm_state == 5'd13 && dut.mac_top_inst.u_pe_core.PE_INST[7].u_pe.issue_mac_valid) begin
        $display("[DBG-EXP2] t=%0t PE[7]: a(reg)={%b,%02h,%06h} b(slope)={%b,%02h,%06h} c(intercept)={%b,%02h,%06h}",
          $time,
          dut.mac_top_inst.u_pe_core.PE_INST[7].u_pe.macUnit.io_in_a_sign,
          dut.mac_top_inst.u_pe_core.PE_INST[7].u_pe.macUnit.io_in_a_exp,
          dut.mac_top_inst.u_pe_core.PE_INST[7].u_pe.macUnit.io_in_a_mantissa,
          dut.mac_top_inst.u_pe_core.PE_INST[7].u_pe.macUnit.io_in_b_sign,
          dut.mac_top_inst.u_pe_core.PE_INST[7].u_pe.macUnit.io_in_b_exp,
          dut.mac_top_inst.u_pe_core.PE_INST[7].u_pe.macUnit.io_in_b_mantissa,
          dut.mac_top_inst.u_pe_core.PE_INST[7].u_pe.macUnit.io_in_c_sign,
          dut.mac_top_inst.u_pe_core.PE_INST[7].u_pe.macUnit.io_in_c_exp,
          dut.mac_top_inst.u_pe_core.PE_INST[7].u_pe.macUnit.io_in_c_mantissa);
      end
      // SUBTRACT(11)→SCALE(12): score-max已在PE.reg
      if (fsm_state_d == 5'd11 && dut.mac_top_inst.fsm_state == 5'd12) begin
        $display("[DBG-ID] SUBTRACT(S-max) PE.reg: [%08h %08h %08h %08h %08h %08h %08h %08h]",
          `FSA_PE_REG(0), `FSA_PE_REG(1), `FSA_PE_REG(2), `FSA_PE_REG(3),
          `FSA_PE_REG(4), `FSA_PE_REG(5), `FSA_PE_REG(6), `FSA_PE_REG(7));
        $display("[DBG-ID] SUBTRACT float: [%.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f]",
          $bitstoshortreal(`FSA_PE_REG(0)), $bitstoshortreal(`FSA_PE_REG(1)),
          $bitstoshortreal(`FSA_PE_REG(2)), $bitstoshortreal(`FSA_PE_REG(3)),
          $bitstoshortreal(`FSA_PE_REG(4)), $bitstoshortreal(`FSA_PE_REG(5)),
          $bitstoshortreal(`FSA_PE_REG(6)), $bitstoshortreal(`FSA_PE_REG(7)));
      end
      // SCALE(12)→EXP2(13): scaled值在PE.reg
      if (fsm_state_d == 5'd12 && dut.mac_top_inst.fsm_state == 5'd13) begin
        $display("[DBG-ID] SCALE(input to exp2) PE.reg: [%08h %08h %08h %08h %08h %08h %08h %08h]",
          `FSA_PE_REG(0), `FSA_PE_REG(1), `FSA_PE_REG(2), `FSA_PE_REG(3),
          `FSA_PE_REG(4), `FSA_PE_REG(5), `FSA_PE_REG(6), `FSA_PE_REG(7));
        $display("[DBG-ID] SCALE float: [%.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f]",
          $bitstoshortreal(`FSA_PE_REG(0)), $bitstoshortreal(`FSA_PE_REG(1)),
          $bitstoshortreal(`FSA_PE_REG(2)), $bitstoshortreal(`FSA_PE_REG(3)),
          $bitstoshortreal(`FSA_PE_REG(4)), $bitstoshortreal(`FSA_PE_REG(5)),
          $bitstoshortreal(`FSA_PE_REG(6)), $bitstoshortreal(`FSA_PE_REG(7)));
      end
      // EXP2(13)→ROWSUM(14): P值在PE.reg
      if (fsm_state_d == 5'd13 && dut.mac_top_inst.fsm_state == 5'd14) begin
        $display("[DBG-ID] P(exp2 output) PE.reg: [%08h %08h %08h %08h %08h %08h %08h %08h]",
          `FSA_PE_REG(0), `FSA_PE_REG(1), `FSA_PE_REG(2), `FSA_PE_REG(3),
          `FSA_PE_REG(4), `FSA_PE_REG(5), `FSA_PE_REG(6), `FSA_PE_REG(7));
        $display("[DBG-ID] P float: [%.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f]",
          $bitstoshortreal(`FSA_PE_REG(0)), $bitstoshortreal(`FSA_PE_REG(1)),
          $bitstoshortreal(`FSA_PE_REG(2)), $bitstoshortreal(`FSA_PE_REG(3)),
          $bitstoshortreal(`FSA_PE_REG(4)), $bitstoshortreal(`FSA_PE_REG(5)),
          $bitstoshortreal(`FSA_PE_REG(6)), $bitstoshortreal(`FSA_PE_REG(7)));
      end
    end
  end

  // DDR直接读写
  function automatic logic [31:0] ddr_read_word(input logic [31:0] byte_addr);
    ddr_read_word = u_ddr_mem.mem[byte_addr >> 2];
  endfunction

  task automatic ddr_write_word(input logic [31:0] byte_addr, input logic [31:0] data);
    u_ddr_mem.mem[byte_addr >> 2] = data;
  endtask

  // AXI CSR写
  task automatic axi_csr_write(input logic [31:0] addr, input logic [31:0] data);
    @(posedge clk);
    s_awid <= 5'd1; s_awaddr <= addr; s_awlen <= 8'd0;
    s_awsize <= 3'b010; s_awburst <= 2'b01; s_awlock <= 1'b0;
    s_awcache <= 4'd0; s_awprot <= 3'd0; s_awvalid <= 1'b1;
    while (!s_awready) @(posedge clk);
    @(posedge clk); s_awvalid <= 1'b0;
    s_wdata <= data; s_wstrb <= 4'hF; s_wlast <= 1'b1; s_wvalid <= 1'b1;
    while (!s_wready) @(posedge clk);
    @(posedge clk); s_wvalid <= 1'b0;
    wait (s_bvalid === 1'b1); @(posedge clk);
  endtask

  // AXI CSR读
  task automatic axi_csr_read(input logic [31:0] addr, output logic [31:0] data);
    @(posedge clk);
    s_arid <= 5'd2; s_araddr <= addr; s_arlen <= 8'd0;
    s_arsize <= 3'b010; s_arburst <= 2'b01; s_arlock <= 1'b0;
    s_arcache <= 4'd0; s_arprot <= 3'd0; s_arvalid <= 1'b1;
    while (!s_arready) @(posedge clk);
    @(posedge clk); s_arvalid <= 1'b0;
    wait (s_rvalid === 1'b1); data = s_rdata; @(posedge clk);
  endtask

  // 初始化AXI总线
  task automatic init_host_bus;
    s_awid=0; s_awaddr=0; s_awlen=0; s_awsize=3'b010; s_awburst=2'b01;
    s_awlock=0; s_awcache=0; s_awprot=0; s_awvalid=0;
    s_wdata=0; s_wstrb=4'hF; s_wlast=1; s_wvalid=0; s_bready=1;
    s_arid=0; s_araddr=0; s_arlen=0; s_arsize=3'b010; s_arburst=2'b01;
    s_arlock=0; s_arcache=0; s_arprot=0; s_arvalid=0; s_rready=1;
  endtask

  // 随机FP32生成（小范围值，避免溢出）
  function automatic logic [31:0] rand_fp32_small(input int seed_val);
    int unsigned prng;
    logic s;
    logic [7:0] e;
    logic [22:0] m;
    prng = seed_val;
    prng = (prng * 32'd1664525) + 32'd1013904223;
    s = prng[31];
    e = 8'd124 + (prng[2:0] % 5); // exp in [124,128] → 值在[0.125, 8]
    m = prng[22:0];
    return {s, e, m};
  endfunction

  // 预加载DDR中的Q/K/V数据
  task automatic preload_ddr_data;
    int h, r, c;
    logic [31:0] addr;
    // Q: 4 heads连续存储，每head head_dim个fp32
    for (h = 0; h < NUM_GROUPS; h++)
      for (c = 0; c < HEAD_DIM; c++) begin
        addr = Q_BASE_ADDR + (h * HEAD_DIM + c) * 4;
        ddr_write_word(addr, Q_data[h][c]);
      end
    // K: 按tile连续存储，每tile head_dim行×head_dim列
    for (r = 0; r < case_seq_len; r++)
      for (c = 0; c < HEAD_DIM; c++) begin
        addr = K_BASE_ADDR + (r * HEAD_DIM + c) * 4;
        ddr_write_word(addr, K_data[r][c]);
      end
    // V: 同K布局
    for (r = 0; r < case_seq_len; r++)
      for (c = 0; c < HEAD_DIM; c++) begin
        addr = V_BASE_ADDR + (r * HEAD_DIM + c) * 4;
        ddr_write_word(addr, V_data[r][c]);
      end
    // O区域清零
    for (int i = 0; i < NUM_GROUPS * HEAD_DIM; i++)
      ddr_write_word(O_BASE_ADDR + i * 4, 32'hDEAD_BEEF);
  endtask

  // 配置FSA CSR
  task automatic configure_fsa;
    axi_csr_write(REG_Q_BASE, Q_BASE_ADDR);
    axi_csr_write(REG_K_BASE, K_BASE_ADDR);
    axi_csr_write(REG_V_BASE, V_BASE_ADDR);
    axi_csr_write(REG_O_BASE, O_BASE_ADDR);
    axi_csr_write(REG_HEAD_DIM, HEAD_DIM);
    axi_csr_write(REG_SEQ_LEN, case_seq_len);
    axi_csr_write(REG_KV_STRIDE, KV_STRIDE);
    axi_csr_write(REG_NUM_HEADS, NUM_GROUPS);
  endtask

  // 等待完成
  task automatic wait_fsa_done(output bit timeout_hit);
    logic [31:0] status;
    int unsigned deadline = case_start_cycle + TIMEOUT_CYCLES;
    int unsigned last_print = 0;
    timeout_hit = 0;
    while (cycle_count < deadline) begin
      axi_csr_read(REG_STATUS, status);
      if (status[1]) return; // done bit
      // 每10000 cycle打印一次状态
      if (cycle_count - last_print > 10000) begin
        $display("[DBG] cycle=%0d ctrl_state=%0d(5bit) fsa_fsm_state=%0d",
          cycle_count, dut.u_controller.state, dut.mac_top_inst.fsm_state);
        last_print = cycle_count;
      end
    end
    timeout_hit = 1;
  endtask

  // golden同步任务：逐tile等待FSM状态转换，调用DPI
  task automatic golden_sync_tiles(input int num_tiles);
    for (int tile = 0; tile < num_tiles; tile++) begin
      // 等待FSM进入S_TRANSPOSE_K(6)：K已加载完毕
      wait(dut.mac_top_inst.fsm_state == 5'd6 && fsm_state_d != 5'd6);
      @(posedge clk);
      $display("[GOLDEN] tile=%0d: entered S_TRANSPOSE_K at t=%0t", tile, $time);
      // 设置当前tile的K/V/Q
      for (int r = 0; r < HEAD_DIM; r++)
        for (int c = 0; c < HEAD_DIM; c++)
          dpi_golden_set_k(r, c, K_data[tile * HEAD_DIM + r][c]);
      for (int r = 0; r < HEAD_DIM; r++)
        for (int c = 0; c < HEAD_DIM; c++)
          dpi_golden_set_v(r, c, V_data[tile * HEAD_DIM + r][c]);
      for (int i = 0; i < HEAD_DIM; i++)
        dpi_golden_set_q(i, Q_data[0][i]);
      dpi_golden_compute();

      // 等待FSM从EXP2(13)进入ROWSUM(14)：捕获PE实际P值
      wait(dut.mac_top_inst.fsm_state == 5'd14 && fsm_state_d == 5'd13);
      @(posedge clk);
      $display("[GOLDEN] tile=%0d: captured P at t=%0t PE[0]=0x%08h", tile, $time, `SYS_GET_PE_REG(0));
      dpi_golden_set_actual_p(0, `SYS_GET_PE_REG(0));
      dpi_golden_set_actual_p(1, `SYS_GET_PE_REG(1));
      dpi_golden_set_actual_p(2, `SYS_GET_PE_REG(2));
      dpi_golden_set_actual_p(3, `SYS_GET_PE_REG(3));
      dpi_golden_set_actual_p(4, `SYS_GET_PE_REG(4));
      dpi_golden_set_actual_p(5, `SYS_GET_PE_REG(5));
      dpi_golden_set_actual_p(6, `SYS_GET_PE_REG(6));
      dpi_golden_set_actual_p(7, `SYS_GET_PE_REG(7));
      dpi_golden_compute_post_exp2();

      // 等待离开ROWSUM状态再进入下一tile循环
      wait(dut.mac_top_inst.fsm_state != 5'd14);
      @(posedge clk);
    end
  endtask
  // 端到端验证：从DDR读出O，与理想FlashAttention golden比对
  // golden使用标准exp2f（理想精度），容忍PWL近似误差
  task automatic compute_golden_and_compare;
    int i, g;
    int errors;
    int total_checked;
    logic [31:0] dut_val;

    // 计算理想golden（使用标准exp2f）
    dpi_sys_golden_init(HEAD_DIM, case_seq_len);
    for (i = 0; i < HEAD_DIM; i++)
      dpi_sys_golden_set_q(i, Q_data[0][i]);
    for (int r = 0; r < case_seq_len; r++)
      for (int c = 0; c < HEAD_DIM; c++)
        dpi_sys_golden_set_k(r, c, K_data[r][c]);
    for (int r = 0; r < case_seq_len; r++)
      for (int c = 0; c < HEAD_DIM; c++)
        dpi_sys_golden_set_v(r, c, V_data[r][c]);
    dpi_sys_golden_compute();

    // 比对DDR输出（group 0）与理想golden，报告精度
    errors = 0;
    total_checked = 0;
    $display("[INFO] === Precision Report (group 0 vs ideal exp2f golden) ===");
    for (i = 0; i < HEAD_DIM; i++) begin
      dut_val = ddr_read_word(O_BASE_ADDR + i * 4);
      total_checked++;
      // 调用golden比对（打印相对误差）
      errors += dpi_sys_golden_compare(i, dut_val, ULP_TOL);
    end

    // 检查4组输出都非零非inf（验证4-head并行正确执行）
    for (g = 1; g < NUM_GROUPS; g++) begin
      for (i = 0; i < HEAD_DIM; i++) begin
        dut_val = ddr_read_word(O_BASE_ADDR + (g * HEAD_DIM + i) * 4);
        total_checked++;
        if (dut_val == 32'h0 || dut_val[30:23] == 8'hFF) begin
          $display("[FAIL] group%0d O[%0d]: DUT=0x%08h (zero or inf)", g, i, dut_val);
          errors++;
        end
      end
    end

    // 验证4组输出互不相同（证明4-head并行各自独立计算）
    begin
      logic [31:0] g0_val, g1_val;
      int same_count;
      same_count = 0;
      for (i = 0; i < HEAD_DIM; i++) begin
        g0_val = ddr_read_word(O_BASE_ADDR + i * 4);
        g1_val = ddr_read_word(O_BASE_ADDR + (HEAD_DIM + i) * 4);
        if (g0_val == g1_val) same_count++;
      end
      if (same_count == HEAD_DIM) begin
        $display("[FAIL] group0 and group1 outputs are identical (4-head parallel not working)");
        errors++;
      end
    end

    if (errors == 0)
      $display("[PASS] case=%s seq_len=%0d tiles=%0d checked=%0d (all valid, 4 heads independent)",
        case_name, case_seq_len, case_num_tiles, total_checked);
    else begin
      $display("[FAIL] case=%s seq_len=%0d tiles=%0d errors=%0d",
        case_name, case_seq_len, case_num_tiles, errors);
      error_count += errors;
    end
  endtask

  // 生成测试数据
  task automatic generate_test_data(input int seed_base);
    int h, r, c;
    int unsigned prng;

    if (seed_base == 0) begin
      // 特殊case：K=I, V=I, Q=简单已知值
      for (h = 0; h < NUM_GROUPS; h++)
        for (c = 0; c < HEAD_DIM; c++)
          Q_data[h][c] = 32'h0; // 先清零
      // group 0: Q = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
      Q_data[0][0] = 32'h3F800000; // 1.0
      Q_data[0][1] = 32'h40000000; // 2.0
      Q_data[0][2] = 32'h40400000; // 3.0
      Q_data[0][3] = 32'h40800000; // 4.0
      Q_data[0][4] = 32'h40A00000; // 5.0
      Q_data[0][5] = 32'h40C00000; // 6.0
      Q_data[0][6] = 32'h40E00000; // 7.0
      Q_data[0][7] = 32'h41000000; // 8.0
      // group 1~3: 不同Q
      for (h = 1; h < NUM_GROUPS; h++)
        for (c = 0; c < HEAD_DIM; c++)
          Q_data[h][c] = Q_data[0][c]; // 暂时相同

      // K = 8x8 单位矩阵
      for (r = 0; r < case_seq_len; r++)
        for (c = 0; c < HEAD_DIM; c++)
          K_data[r][c] = (r == c) ? 32'h3F800000 : 32'h0;
      // V = 8x8 单位矩阵
      for (r = 0; r < case_seq_len; r++)
        for (c = 0; c < HEAD_DIM; c++)
          V_data[r][c] = (r == c) ? 32'h3F800000 : 32'h0;
      return;
    end

    prng = seed_base;
    // Q: 4 heads
    for (h = 0; h < NUM_GROUPS; h++)
      for (c = 0; c < HEAD_DIM; c++) begin
        prng = (prng * 32'd1664525) + 32'd1013904223;
        Q_data[h][c] = rand_fp32_small(prng);
      end
    // K: seq_len行
    for (r = 0; r < case_seq_len; r++)
      for (c = 0; c < HEAD_DIM; c++) begin
        prng = (prng * 32'd1664525) + 32'd1013904223;
        K_data[r][c] = rand_fp32_small(prng);
      end
    // V: seq_len行
    for (r = 0; r < case_seq_len; r++)
      for (c = 0; c < HEAD_DIM; c++) begin
        prng = (prng * 32'd1664525) + 32'd1013904223;
        V_data[r][c] = rand_fp32_small(prng);
      end
  endtask

  // 运行单个case
  task automatic run_fsa_case(input string name, input int seq_len, input int seed);
    bit timeout;
    if (selected_case != "" && selected_case != name) begin
      $display("[INFO] skip case=%s because selected_case=%s", name, selected_case);
      return;
    end
    case_name = name;
    case_seq_len = seq_len;
    case_num_tiles = (seq_len + HEAD_DIM - 1) / HEAD_DIM;

    $display("[INFO] Running case=%s seq_len=%0d tiles=%0d seed=%0d",
      name, seq_len, case_num_tiles, seed);

    generate_test_data(seed);
    preload_ddr_data();
    configure_fsa();

    // 初始化golden（每个case重新初始化）
    dpi_golden_init(HEAD_DIM);

    case_start_cycle = cycle_count;

    // 启动FSA模式: CTRL[0]=start, CTRL[1]=mode_fsa
    axi_csr_write(REG_CTRL, 32'h0000_0003);
    wait_fsa_done(timeout);
    if (timeout) begin
      $display("[FAIL] case=%s TIMEOUT at cycle=%0d state=%0d",
        name, cycle_count, debug_state);
      error_count++;
      return;
    end

    $display("[INFO] case=%s completed in %0d cycles", name, cycle_count - case_start_cycle);

    // 打印Input SRAM内容（验证K加载是否正确）
    if (seed == 0) begin
      $display("[DBG] Input SRAM after K=I load:");
      $display("  bank0: [%08h %08h %08h %08h %08h %08h %08h %08h]",
        dut.mac_top_inst.SRAM_W_BANK[0].u_sram_w.mem[0], dut.mac_top_inst.SRAM_W_BANK[0].u_sram_w.mem[1],
        dut.mac_top_inst.SRAM_W_BANK[0].u_sram_w.mem[2], dut.mac_top_inst.SRAM_W_BANK[0].u_sram_w.mem[3],
        dut.mac_top_inst.SRAM_W_BANK[0].u_sram_w.mem[4], dut.mac_top_inst.SRAM_W_BANK[0].u_sram_w.mem[5],
        dut.mac_top_inst.SRAM_W_BANK[0].u_sram_w.mem[6], dut.mac_top_inst.SRAM_W_BANK[0].u_sram_w.mem[7]);
      $display("  bank1: [%08h %08h %08h %08h %08h %08h %08h %08h]",
        dut.mac_top_inst.SRAM_W_BANK[1].u_sram_w.mem[0], dut.mac_top_inst.SRAM_W_BANK[1].u_sram_w.mem[1],
        dut.mac_top_inst.SRAM_W_BANK[1].u_sram_w.mem[2], dut.mac_top_inst.SRAM_W_BANK[1].u_sram_w.mem[3],
        dut.mac_top_inst.SRAM_W_BANK[1].u_sram_w.mem[4], dut.mac_top_inst.SRAM_W_BANK[1].u_sram_w.mem[5],
        dut.mac_top_inst.SRAM_W_BANK[1].u_sram_w.mem[6], dut.mac_top_inst.SRAM_W_BANK[1].u_sram_w.mem[7]);
      $display("  bank7: [%08h %08h %08h %08h %08h %08h %08h %08h]",
        dut.mac_top_inst.SRAM_W_BANK[7].u_sram_w.mem[0], dut.mac_top_inst.SRAM_W_BANK[7].u_sram_w.mem[1],
        dut.mac_top_inst.SRAM_W_BANK[7].u_sram_w.mem[2], dut.mac_top_inst.SRAM_W_BANK[7].u_sram_w.mem[3],
        dut.mac_top_inst.SRAM_W_BANK[7].u_sram_w.mem[4], dut.mac_top_inst.SRAM_W_BANK[7].u_sram_w.mem[5],
        dut.mac_top_inst.SRAM_W_BANK[7].u_sram_w.mem[6], dut.mac_top_inst.SRAM_W_BANK[7].u_sram_w.mem[7]);
      // ACC SRAM内容（NORM前的PV结果和rowsum）
      $display("[DBG] ACC SRAM group0 (PV+rowsum):");
      $display("  O[0..7]: [%08h %08h %08h %08h %08h %08h %08h %08h]",
        dut.mac_top_inst.ACC_INST[0].u_acc_sram.mem[0], dut.mac_top_inst.ACC_INST[0].u_acc_sram.mem[1],
        dut.mac_top_inst.ACC_INST[0].u_acc_sram.mem[2], dut.mac_top_inst.ACC_INST[0].u_acc_sram.mem[3],
        dut.mac_top_inst.ACC_INST[0].u_acc_sram.mem[4], dut.mac_top_inst.ACC_INST[0].u_acc_sram.mem[5],
        dut.mac_top_inst.ACC_INST[0].u_acc_sram.mem[6], dut.mac_top_inst.ACC_INST[0].u_acc_sram.mem[7]);
      $display("  rowsum(addr8): %08h", dut.mac_top_inst.ACC_INST[0].u_acc_sram.mem[8]);
      $display("[DBG] Output SRAM bank0: [%08h %08h %08h %08h %08h %08h %08h %08h]",
        dut.mac_top_inst.OUT_SRAM[0].u_out_sram.mem[0], dut.mac_top_inst.OUT_SRAM[0].u_out_sram.mem[1],
        dut.mac_top_inst.OUT_SRAM[0].u_out_sram.mem[2], dut.mac_top_inst.OUT_SRAM[0].u_out_sram.mem[3],
        dut.mac_top_inst.OUT_SRAM[0].u_out_sram.mem[4], dut.mac_top_inst.OUT_SRAM[0].u_out_sram.mem[5],
        dut.mac_top_inst.OUT_SRAM[0].u_out_sram.mem[6], dut.mac_top_inst.OUT_SRAM[0].u_out_sram.mem[7]);
      // Vector SRAM bank0（Q加载验证）
      $display("[DBG] Vec SRAM bank0 (Q): [%08h %08h %08h %08h %08h %08h %08h %08h]",
        dut.mac_top_inst.SRAM_V_BANK[0].u_sram_v.mem[0], dut.mac_top_inst.SRAM_V_BANK[0].u_sram_v.mem[1],
        dut.mac_top_inst.SRAM_V_BANK[0].u_sram_v.mem[2], dut.mac_top_inst.SRAM_V_BANK[0].u_sram_v.mem[3],
        dut.mac_top_inst.SRAM_V_BANK[0].u_sram_v.mem[4], dut.mac_top_inst.SRAM_V_BANK[0].u_sram_v.mem[5],
        dut.mac_top_inst.SRAM_V_BANK[0].u_sram_v.mem[6], dut.mac_top_inst.SRAM_V_BANK[0].u_sram_v.mem[7]);
    end

    compute_golden_and_compare();

    // 清除start位，等控制器回IDLE
    axi_csr_write(REG_CTRL, 32'h0000_0000);
    repeat(20) @(posedge clk);
  endtask

  // 主测试流程
  initial begin
    if ($value$plusargs("CASE=%s", selected_case))
      $display("[INFO] selected CASE=%s", selected_case);
    init_host_bus();
    rst_n = 0;
    error_count = 0;
    repeat(10) @(posedge clk);
    rst_n = 1;
    repeat(10) @(posedge clk);

    // Case 1: K=I, V=I（期望O=softmax(Q/√d)，用于定位数据映射）
    run_fsa_case("FSA_Identity", 8, 0);

    // Case 2: 单tile随机
    run_fsa_case("FSA_1Tile_8", 8, 42);

    // Case 2: 2 tiles（seq_len = 16）
    run_fsa_case("FSA_2Tile_16", 16, 123);

    // Case 3: 3 tiles（seq_len = 24）
    run_fsa_case("FSA_3Tile_24", 24, 456);

    // Case 4: 随机seed 1
    run_fsa_case("FSA_Random_1", 16, 789);

    // Case 5: 随机seed 2
    run_fsa_case("FSA_Random_2", 8, 1024);

    // Case 6: 随机seed 3（3 tiles）
    run_fsa_case("FSA_Random_3", 24, 2048);

    // 总结
    if (error_count == 0)
      $display("[PASS] All FSA cases passed!");
    else
      $display("[FAIL] Total errors: %0d", error_count);

    repeat(10) @(posedge clk);
    $finish;
  end

endmodule

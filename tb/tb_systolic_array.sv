`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// tb_systolic_array
//
// 1D systolic array 顶层验证TB
// 以 PE 阵列和控制链路为核心，检查阵列级数据流、控制流和
// 关键输出在不同回归 case 下的行为。
//
// 主要服务于阵列集成和 PE 替换后的联调验证。
////////////////////////////////////////////////////////////////

`define SA_CTRL_CONN(i) \
    .io_pe_ctrl_``i``_valid       (pe_ctrl_valid[i]), \
    .io_pe_ctrl_``i``_bits_mac    (pe_ctrl_mac[i]), \
    .io_pe_ctrl_``i``_bits_acc_ui (pe_ctrl_acc_ui[i]), \
    .io_pe_ctrl_``i``_bits_load_reg_li(pe_ctrl_load_reg_li[i]), \
    .io_pe_ctrl_``i``_bits_load_reg_ui(pe_ctrl_load_reg_ui[i]), \
    .io_pe_ctrl_``i``_bits_flow_lr (pe_ctrl_flow_lr[i]), \
    .io_pe_ctrl_``i``_bits_flow_ud (pe_ctrl_flow_ud[i]), \
    .io_pe_ctrl_``i``_bits_flow_du (pe_ctrl_flow_du[i]), \
    .io_pe_ctrl_``i``_bits_update_reg(pe_ctrl_update_reg[i]), \
    .io_pe_ctrl_``i``_bits_exp2   (pe_ctrl_exp2[i])

`define SA_DATA_CONN(i) \
    .io_pe_data_``i``_sign        (pe_data_sign[i]), \
    .io_pe_data_``i``_exp         (pe_data_exp[i]), \
    .io_pe_data_``i``_mantissa    (pe_data_mantissa[i])

`define SA_ACC_CONN(i) \
    .io_acc_out_``i``_valid       (acc_out_valid[i]), \
    .io_acc_out_``i``_bits_sign   (acc_out_sign[i]), \
    .io_acc_out_``i``_bits_exp    (acc_out_exp[i]), \
    .io_acc_out_``i``_bits_mantissa(acc_out_mantissa[i])

module systolicarray_harness(
  input  logic clk,
  input  logic rst_n,
  input  logic cmp_ctrl_valid,
  input  logic [2:0] cmp_ctrl_cmd,
  input  logic [7:0] cmp_ctrl_causalCounter,

  input  logic pe_ctrl_valid [0:31],
  input  logic pe_ctrl_mac [0:31],
  input  logic pe_ctrl_acc_ui [0:31],
  input  logic pe_ctrl_load_reg_li [0:31],
  input  logic pe_ctrl_load_reg_ui [0:31],
  input  logic pe_ctrl_flow_lr [0:31],
  input  logic pe_ctrl_flow_ud [0:31],
  input  logic pe_ctrl_flow_du [0:31],
  input  logic pe_ctrl_update_reg [0:31],
  input  logic pe_ctrl_exp2 [0:31],

  input  logic pe_data_sign [0:31],
  input  logic [7:0] pe_data_exp [0:31],
  input  logic [22:0] pe_data_mantissa [0:31],

  output logic acc_out_valid [0:31],
  output logic acc_out_sign [0:31],
  output logic [7:0] acc_out_exp [0:31],
  output logic [22:0] acc_out_mantissa [0:31],

  output logic mesh00_r_valid,
  output logic [31:0] mesh00_r_word,
  output logic mesh00_u_valid,
  output logic [31:0] mesh00_u_word,
  output logic mesh00_d_valid,
  output logic [31:0] mesh00_d_word,
  output logic mesh00_out_ctrl_valid,
  output logic [31:0] mesh00_out_ctrl_word,

  output logic mesh310_d_valid,
  output logic [31:0] mesh310_d_word,
  output logic mesh0031_r_valid,
  output logic [31:0] mesh0031_r_word,
  output logic mesh0031_d_valid,
  output logic [31:0] mesh0031_d_word,
  output logic acc0_pipe_valid,
  output logic [31:0] acc0_pipe_word
);
  SystolicArray u_dut (
    .clock(clk),
    .reset(!rst_n),
    .io_cmp_ctrl_valid(cmp_ctrl_valid),
    .io_cmp_ctrl_bits_cmd(cmp_ctrl_cmd),
    .io_cmp_ctrl_bits_causalCounter(cmp_ctrl_causalCounter),
    `SA_CTRL_CONN(0),
    `SA_CTRL_CONN(1),
    `SA_CTRL_CONN(2),
    `SA_CTRL_CONN(3),
    `SA_CTRL_CONN(4),
    `SA_CTRL_CONN(5),
    `SA_CTRL_CONN(6),
    `SA_CTRL_CONN(7),
    `SA_CTRL_CONN(8),
    `SA_CTRL_CONN(9),
    `SA_CTRL_CONN(10),
    `SA_CTRL_CONN(11),
    `SA_CTRL_CONN(12),
    `SA_CTRL_CONN(13),
    `SA_CTRL_CONN(14),
    `SA_CTRL_CONN(15),
    `SA_CTRL_CONN(16),
    `SA_CTRL_CONN(17),
    `SA_CTRL_CONN(18),
    `SA_CTRL_CONN(19),
    `SA_CTRL_CONN(20),
    `SA_CTRL_CONN(21),
    `SA_CTRL_CONN(22),
    `SA_CTRL_CONN(23),
    `SA_CTRL_CONN(24),
    `SA_CTRL_CONN(25),
    `SA_CTRL_CONN(26),
    `SA_CTRL_CONN(27),
    `SA_CTRL_CONN(28),
    `SA_CTRL_CONN(29),
    `SA_CTRL_CONN(30),
    `SA_CTRL_CONN(31),
    `SA_DATA_CONN(0),
    `SA_DATA_CONN(1),
    `SA_DATA_CONN(2),
    `SA_DATA_CONN(3),
    `SA_DATA_CONN(4),
    `SA_DATA_CONN(5),
    `SA_DATA_CONN(6),
    `SA_DATA_CONN(7),
    `SA_DATA_CONN(8),
    `SA_DATA_CONN(9),
    `SA_DATA_CONN(10),
    `SA_DATA_CONN(11),
    `SA_DATA_CONN(12),
    `SA_DATA_CONN(13),
    `SA_DATA_CONN(14),
    `SA_DATA_CONN(15),
    `SA_DATA_CONN(16),
    `SA_DATA_CONN(17),
    `SA_DATA_CONN(18),
    `SA_DATA_CONN(19),
    `SA_DATA_CONN(20),
    `SA_DATA_CONN(21),
    `SA_DATA_CONN(22),
    `SA_DATA_CONN(23),
    `SA_DATA_CONN(24),
    `SA_DATA_CONN(25),
    `SA_DATA_CONN(26),
    `SA_DATA_CONN(27),
    `SA_DATA_CONN(28),
    `SA_DATA_CONN(29),
    `SA_DATA_CONN(30),
    `SA_DATA_CONN(31),
    `SA_ACC_CONN(0),
    `SA_ACC_CONN(1),
    `SA_ACC_CONN(2),
    `SA_ACC_CONN(3),
    `SA_ACC_CONN(4),
    `SA_ACC_CONN(5),
    `SA_ACC_CONN(6),
    `SA_ACC_CONN(7),
    `SA_ACC_CONN(8),
    `SA_ACC_CONN(9),
    `SA_ACC_CONN(10),
    `SA_ACC_CONN(11),
    `SA_ACC_CONN(12),
    `SA_ACC_CONN(13),
    `SA_ACC_CONN(14),
    `SA_ACC_CONN(15),
    `SA_ACC_CONN(16),
    `SA_ACC_CONN(17),
    `SA_ACC_CONN(18),
    `SA_ACC_CONN(19),
    `SA_ACC_CONN(20),
    `SA_ACC_CONN(21),
    `SA_ACC_CONN(22),
    `SA_ACC_CONN(23),
    `SA_ACC_CONN(24),
    `SA_ACC_CONN(25),
    `SA_ACC_CONN(26),
    `SA_ACC_CONN(27),
    `SA_ACC_CONN(28),
    `SA_ACC_CONN(29),
    `SA_ACC_CONN(30),
    `SA_ACC_CONN(31)
  );

  assign mesh00_r_valid = u_dut.mesh_0_0.io_r_output_valid;
  assign mesh00_r_word = {
    u_dut.mesh_0_0.io_r_output_bits_sign,
    u_dut.mesh_0_0.io_r_output_bits_exp,
    u_dut.mesh_0_0.io_r_output_bits_mantissa
  };

  assign mesh00_u_valid = u_dut.mesh_0_0.io_u_output_valid;
  assign mesh00_u_word = {
    u_dut.mesh_0_0.io_u_output_bits_sign,
    u_dut.mesh_0_0.io_u_output_bits_exp,
    u_dut.mesh_0_0.io_u_output_bits_mantissa
  };

  assign mesh00_d_valid = u_dut.mesh_0_0.io_d_output_valid;
  assign mesh00_d_word = {
    u_dut.mesh_0_0.io_d_output_bits_sign,
    u_dut.mesh_0_0.io_d_output_bits_exp,
    u_dut.mesh_0_0.io_d_output_bits_mantissa
  };

  assign mesh00_out_ctrl_valid = u_dut.mesh_0_0.io_out_ctrl_valid;
  assign mesh00_out_ctrl_word = {
    u_dut.mesh_0_0.io_out_ctrl_bits_mac,
    u_dut.mesh_0_0.io_out_ctrl_bits_acc_ui,
    u_dut.mesh_0_0.io_out_ctrl_bits_load_reg_li,
    u_dut.mesh_0_0.io_out_ctrl_bits_load_reg_ui,
    u_dut.mesh_0_0.io_out_ctrl_bits_flow_lr,
    u_dut.mesh_0_0.io_out_ctrl_bits_flow_ud,
    u_dut.mesh_0_0.io_out_ctrl_bits_flow_du,
    u_dut.mesh_0_0.io_out_ctrl_bits_update_reg,
    u_dut.mesh_0_0.io_out_ctrl_bits_exp2,
    23'b0
  };

  assign mesh310_d_valid = u_dut.mesh_31_0.io_d_output_valid;
  assign mesh310_d_word = {
    u_dut.mesh_31_0.io_d_output_bits_sign,
    u_dut.mesh_31_0.io_d_output_bits_exp,
    u_dut.mesh_31_0.io_d_output_bits_mantissa
  };

  assign mesh0031_r_valid = u_dut.mesh_0_31.io_r_output_valid;
  assign mesh0031_r_word = {
    u_dut.mesh_0_31.io_r_output_bits_sign,
    u_dut.mesh_0_31.io_r_output_bits_exp,
    u_dut.mesh_0_31.io_r_output_bits_mantissa
  };

  assign mesh0031_d_valid = u_dut.mesh_0_31.io_d_output_valid;
  assign mesh0031_d_word = {
    u_dut.mesh_0_31.io_d_output_bits_sign,
    u_dut.mesh_0_31.io_d_output_bits_exp,
    u_dut.mesh_0_31.io_d_output_bits_mantissa
  };

  assign acc0_pipe_valid = u_dut.io_acc_out_0_pipe_v;
  assign acc0_pipe_word = {
    u_dut.io_acc_out_0_pipe_b_sign,
    u_dut.io_acc_out_0_pipe_b_exp,
    u_dut.io_acc_out_0_pipe_b_mantissa
  };
endmodule

module tb_systolic_array;
  import tb_cb_baseline_ref_pkg::*;

  localparam int MAC_LATENCY = 4;
  localparam int TIMEOUT_CYCLES = 256;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  logic cmp_ctrl_valid;
  logic [2:0] cmp_ctrl_cmd;
  logic [7:0] cmp_ctrl_causalCounter;

  logic pe_ctrl_valid [0:31];
  logic pe_ctrl_mac [0:31];
  logic pe_ctrl_acc_ui [0:31];
  logic pe_ctrl_load_reg_li [0:31];
  logic pe_ctrl_load_reg_ui [0:31];
  logic pe_ctrl_flow_lr [0:31];
  logic pe_ctrl_flow_ud [0:31];
  logic pe_ctrl_flow_du [0:31];
  logic pe_ctrl_update_reg [0:31];
  logic pe_ctrl_exp2 [0:31];

  logic pe_data_sign [0:31];
  logic [7:0] pe_data_exp [0:31];
  logic [22:0] pe_data_mantissa [0:31];

  logic acc_out_valid [0:31];
  logic acc_out_sign [0:31];
  logic [7:0] acc_out_exp [0:31];
  logic [22:0] acc_out_mantissa [0:31];

  logic mesh00_r_valid;
  logic [31:0] mesh00_r_word;
  logic mesh00_u_valid;
  logic [31:0] mesh00_u_word;
  logic mesh00_d_valid;
  logic [31:0] mesh00_d_word;
  logic mesh00_out_ctrl_valid;
  logic [31:0] mesh00_out_ctrl_word;

  logic mesh310_d_valid;
  logic [31:0] mesh310_d_word;
  logic mesh0031_r_valid;
  logic [31:0] mesh0031_r_word;
  logic mesh0031_d_valid;
  logic [31:0] mesh0031_d_word;
  logic acc0_pipe_valid;
  logic [31:0] acc0_pipe_word;
  int unsigned cycle_count;
  string case_name;
  logic [31:0] mesh00_force_u_word;
  logic [31:0] mesh00_force_d_word;
  logic [31:0] mesh310_force_u_word;

  systolicarray_harness dut (
    .clk(clk),
    .rst_n(rst_n),
    .cmp_ctrl_valid(cmp_ctrl_valid),
    .cmp_ctrl_cmd(cmp_ctrl_cmd),
    .cmp_ctrl_causalCounter(cmp_ctrl_causalCounter),
    .pe_ctrl_valid(pe_ctrl_valid),
    .pe_ctrl_mac(pe_ctrl_mac),
    .pe_ctrl_acc_ui(pe_ctrl_acc_ui),
    .pe_ctrl_load_reg_li(pe_ctrl_load_reg_li),
    .pe_ctrl_load_reg_ui(pe_ctrl_load_reg_ui),
    .pe_ctrl_flow_lr(pe_ctrl_flow_lr),
    .pe_ctrl_flow_ud(pe_ctrl_flow_ud),
    .pe_ctrl_flow_du(pe_ctrl_flow_du),
    .pe_ctrl_update_reg(pe_ctrl_update_reg),
    .pe_ctrl_exp2(pe_ctrl_exp2),
    .pe_data_sign(pe_data_sign),
    .pe_data_exp(pe_data_exp),
    .pe_data_mantissa(pe_data_mantissa),
    .acc_out_valid(acc_out_valid),
    .acc_out_sign(acc_out_sign),
    .acc_out_exp(acc_out_exp),
    .acc_out_mantissa(acc_out_mantissa),
    .mesh00_r_valid(mesh00_r_valid),
    .mesh00_r_word(mesh00_r_word),
    .mesh00_u_valid(mesh00_u_valid),
    .mesh00_u_word(mesh00_u_word),
    .mesh00_d_valid(mesh00_d_valid),
    .mesh00_d_word(mesh00_d_word),
    .mesh00_out_ctrl_valid(mesh00_out_ctrl_valid),
    .mesh00_out_ctrl_word(mesh00_out_ctrl_word),
    .mesh310_d_valid(mesh310_d_valid),
    .mesh310_d_word(mesh310_d_word),
    .mesh0031_r_valid(mesh0031_r_valid),
    .mesh0031_r_word(mesh0031_r_word),
    .mesh0031_d_valid(mesh0031_d_valid),
    .mesh0031_d_word(mesh0031_d_word),
    .acc0_pipe_valid(acc0_pipe_valid),
    .acc0_pipe_word(acc0_pipe_word)
  );

  typedef struct packed {
    logic valid;
    logic acc_ui;
    logic [31:0] word;
  } mac_expect_t;

  mac_expect_t mac_pipe [0:MAC_LATENCY];
  logic mac_issue_valid;
  logic mac_issue_acc_ui;
  logic [31:0] mac_issue_word;
  logic [31:0] mesh310_prev_word;
  logic mesh310_prev_valid;

  function automatic logic [31:0] pack_fp32(
    input logic sign,
    input logic [7:0] exp,
    input logic [22:0] mantissa
  );
    pack_fp32 = {sign, exp, mantissa};
  endfunction

  function automatic logic [31:0] rand_finite_fp32();
    logic [31:0] rnd;
    logic [7:0] exp;
    begin
      rnd = $urandom();
      exp = ((rnd[7:0] % 254) + 1);
      rand_finite_fp32 = {rnd[31], exp, rnd[22:0]};
    end
  endfunction

  function automatic logic [31:0] ctrl_word(
    input logic mac,
    input logic acc_ui,
    input logic load_reg_li,
    input logic load_reg_ui,
    input logic flow_lr,
    input logic flow_ud,
    input logic flow_du,
    input logic update_reg,
    input logic exp2
  );
    ctrl_word = {
      mac,
      acc_ui,
      load_reg_li,
      load_reg_ui,
      flow_lr,
      flow_ud,
      flow_du,
      update_reg,
      exp2,
      23'b0
    };
  endfunction

  function automatic logic [31:0] fp32_mac_expected(
    input logic [31:0] a,
    input logic [31:0] b,
    input logic [31:0] c
  );
    fp32_mac_expected = fp32_add(fp32_mul(a, b), c);
  endfunction

  task automatic clear_all_inputs();
    int i;
    begin
      cmp_ctrl_valid = 1'b0;
      cmp_ctrl_cmd = 3'b0;
      cmp_ctrl_causalCounter = 8'h00;
      mac_issue_valid = 1'b0;
      mac_issue_acc_ui = 1'b0;
      mac_issue_word = 32'h0;

      for (i = 0; i < 32; i++) begin
        pe_ctrl_valid[i] = 1'b0;
        pe_ctrl_mac[i] = 1'b0;
        pe_ctrl_acc_ui[i] = 1'b0;
        pe_ctrl_load_reg_li[i] = 1'b0;
        pe_ctrl_load_reg_ui[i] = 1'b0;
        pe_ctrl_flow_lr[i] = 1'b0;
        pe_ctrl_flow_ud[i] = 1'b0;
        pe_ctrl_flow_du[i] = 1'b0;
        pe_ctrl_update_reg[i] = 1'b0;
        pe_ctrl_exp2[i] = 1'b0;
        pe_data_sign[i] = 1'b0;
        pe_data_exp[i] = 8'h00;
        pe_data_mantissa[i] = 23'h0;
      end
    end
  endtask

  task automatic force_mesh00_inputs(
    input logic [31:0] u_word,
    input logic [31:0] d_word
  );
    begin
      mesh00_force_u_word = u_word;
      mesh00_force_d_word = d_word;
      force dut.u_dut.cmp_out_pipe_b_sign = mesh00_force_u_word[31];
      force dut.u_dut.cmp_out_pipe_b_exp = mesh00_force_u_word[30:23];
      force dut.u_dut.cmp_out_pipe_b_mantissa = mesh00_force_u_word[22:0];
      force dut.u_dut.pipe_b_2142_sign = mesh00_force_d_word[31];
      force dut.u_dut.pipe_b_2142_exp = mesh00_force_d_word[30:23];
      force dut.u_dut.pipe_b_2142_mantissa = mesh00_force_d_word[22:0];
    end
  endtask

  task automatic force_mesh310_u_input(
    input logic [31:0] u_word
  );
    begin
      mesh310_force_u_word = u_word;
      force dut.u_dut.pipe_b_2110_sign = mesh310_force_u_word[31];
      force dut.u_dut.pipe_b_2110_exp = mesh310_force_u_word[30:23];
      force dut.u_dut.pipe_b_2110_mantissa = mesh310_force_u_word[22:0];
    end
  endtask

  task automatic release_mesh00_inputs();
    begin
      release dut.u_dut.cmp_out_pipe_b_sign;
      release dut.u_dut.cmp_out_pipe_b_exp;
      release dut.u_dut.cmp_out_pipe_b_mantissa;
      release dut.u_dut.pipe_b_2142_sign;
      release dut.u_dut.pipe_b_2142_exp;
      release dut.u_dut.pipe_b_2142_mantissa;
    end
  endtask

  task automatic release_mesh310_u_input();
    begin
      release dut.u_dut.pipe_b_2110_sign;
      release dut.u_dut.pipe_b_2110_exp;
      release dut.u_dut.pipe_b_2110_mantissa;
    end
  endtask

  task automatic tick();
    begin
      @(posedge clk);
      #1ps;
    end
  endtask

  task automatic expect_word(
    input string tag,
    input logic got_valid,
    input logic [31:0] got_word,
    input logic exp_valid,
    input logic [31:0] exp_word
  );
    begin
      if (got_valid !== exp_valid || got_word !== exp_word) begin
        $fatal(
          1,
          "[%s] mismatch got_valid=%0b got=%08h exp_valid=%0b exp=%08h",
          tag,
          got_valid,
          got_word,
          exp_valid,
          exp_word
        );
      end
    end
  endtask

  task automatic expect_ctrl_passthrough(
    input string tag,
    input logic valid,
    input logic mac,
    input logic acc_ui,
    input logic load_reg_li,
    input logic load_reg_ui,
    input logic flow_lr,
    input logic flow_ud,
    input logic flow_du,
    input logic update_reg,
    input logic exp2
  );
    logic [31:0] exp_word;
    begin
      exp_word = ctrl_word(mac, acc_ui, load_reg_li, load_reg_ui, flow_lr, flow_ud, flow_du, update_reg, exp2);
      expect_word(tag, mesh00_out_ctrl_valid, mesh00_out_ctrl_word, valid, exp_word);
    end
  endtask

  task automatic load_reg_li_case(input logic [31:0] word);
    begin
      clear_all_inputs();
      pe_data_sign[0] = word[31];
      pe_data_exp[0] = word[30:23];
      pe_data_mantissa[0] = word[22:0];
      force_mesh00_inputs(rand_finite_fp32(), rand_finite_fp32());

      pe_ctrl_valid[0] = 1'b1;
      pe_ctrl_load_reg_li[0] = 1'b1;
      tick();

      expect_word("load_reg_li/r_output", mesh00_r_valid, mesh00_r_word, 1'b1, word);
      expect_ctrl_passthrough("load_reg_li/ctrl", 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);
      release_mesh00_inputs();
    end
  endtask

  task automatic load_reg_ui_case(input logic [31:0] word);
    logic [31:0] u_word;
    logic [31:0] d_word;
    begin
      clear_all_inputs();
      u_word = rand_finite_fp32();
      d_word = rand_finite_fp32();
      pe_data_sign[0] = u_word[31];
      pe_data_exp[0] = u_word[30:23];
      pe_data_mantissa[0] = u_word[22:0];
      force_mesh00_inputs(word, d_word);

      pe_ctrl_valid[0] = 1'b1;
      pe_ctrl_load_reg_ui[0] = 1'b1;
      tick();

      expect_word("load_reg_ui/r_output", mesh00_r_valid, mesh00_r_word, 1'b0, 32'h0);
      if ({dut.u_dut.mesh_0_0.reg_sign, dut.u_dut.mesh_0_0.reg_exp, dut.u_dut.mesh_0_0.reg_mantissa} !== word) begin
        $fatal(
          1,
          "[load_reg_ui/reg] mismatch got=%08h exp=%08h",
          {dut.u_dut.mesh_0_0.reg_sign, dut.u_dut.mesh_0_0.reg_exp, dut.u_dut.mesh_0_0.reg_mantissa},
          word
        );
      end
      expect_ctrl_passthrough("load_reg_ui/ctrl", 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);
      release_mesh00_inputs();
    end
  endtask

  task automatic flow_lr_case(input logic [31:0] word);
    begin
      clear_all_inputs();
      pe_data_sign[0] = word[31];
      pe_data_exp[0] = word[30:23];
      pe_data_mantissa[0] = word[22:0];
      force_mesh00_inputs(rand_finite_fp32(), rand_finite_fp32());

      pe_ctrl_valid[0] = 1'b1;
      pe_ctrl_flow_lr[0] = 1'b1;
      tick();

      expect_word("flow_lr/r_output", mesh00_r_valid, mesh00_r_word, 1'b1, word);
      expect_ctrl_passthrough("flow_lr/ctrl", 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0);
      release_mesh00_inputs();
    end
  endtask

  task automatic flow_du_case(input logic [31:0] word);
    logic [31:0] l_word;
    begin
      clear_all_inputs();
      l_word = rand_finite_fp32();
      force_mesh00_inputs(l_word, word);
      pe_data_sign[0] = l_word[31];
      pe_data_exp[0] = l_word[30:23];
      pe_data_mantissa[0] = l_word[22:0];

      pe_ctrl_valid[0] = 1'b1;
      pe_ctrl_flow_du[0] = 1'b1;
      tick();

      expect_word("flow_du/u_output", mesh00_u_valid, mesh00_u_word, 1'b1, word);
      expect_ctrl_passthrough("flow_du/ctrl", 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0);
      release_mesh00_inputs();
    end
  endtask

  task automatic flow_ud_and_acc_pipe_case(input logic [31:0] word);
    logic [31:0] prev_pipe_word;
    logic prev_pipe_valid;
    logic [31:0] l_word;
    begin
      clear_all_inputs();
      force_mesh310_u_input(word);

      l_word = rand_finite_fp32();
      pe_data_sign[31] = l_word[31];
      pe_data_exp[31] = l_word[30:23];
      pe_data_mantissa[31] = l_word[22:0];

      pe_ctrl_valid[31] = 1'b1;
      pe_ctrl_flow_ud[31] = 1'b1;
      tick();

      expect_word("flow_ud/d_output", mesh310_d_valid, mesh310_d_word, 1'b1, word);
      prev_pipe_word = mesh310_d_word;
      prev_pipe_valid = mesh310_d_valid;

      clear_all_inputs();
      tick();

      expect_word("acc_pipe", acc0_pipe_valid, acc0_pipe_word, prev_pipe_valid, prev_pipe_word);
      release_mesh310_u_input();
    end
  endtask

  task automatic flow_lr_chain_case();
    int i;
    logic [31:0] history [0:31];
    logic [31:0] word;
    begin
      clear_all_inputs();
      force_mesh00_inputs(rand_finite_fp32(), rand_finite_fp32());

      for (i = 0; i < 32; i++) begin
        word = rand_finite_fp32();
        history[i] = word;
        force_mesh00_inputs(word, rand_finite_fp32());
        pe_data_sign[0] = word[31];
        pe_data_exp[0] = word[30:23];
        pe_data_mantissa[0] = word[22:0];

        pe_ctrl_valid[0] = 1'b1;
        pe_ctrl_flow_lr[0] = 1'b1;
        tick();

        expect_word("flow_lr_chain/near", mesh00_r_valid, mesh00_r_word, 1'b1, word);
        if (i >= 31) begin
          expect_word("flow_lr_chain/far", mesh0031_r_valid, mesh0031_r_word, 1'b1, history[i-31]);
        end
      end

      for (i = 0; i < 31; i++) begin
        clear_all_inputs();
        tick();
        expect_word("flow_lr_chain/drain", mesh0031_r_valid, mesh0031_r_word, 1'b1, history[31-i]);
      end

      release_mesh00_inputs();
    end
  endtask

  task automatic flow_ud_chain_case();
    int i;
    logic [31:0] history [0:31];
    logic [31:0] word;
    begin
      clear_all_inputs();
      force_mesh00_inputs(rand_finite_fp32(), rand_finite_fp32());

      for (i = 0; i < 32; i++) begin
        word = rand_finite_fp32();
        history[i] = word;
        force_mesh00_inputs(word, rand_finite_fp32());
        pe_data_sign[0] = word[31];
        pe_data_exp[0] = word[30:23];
        pe_data_mantissa[0] = word[22:0];

        for (int j = 0; j < 32; j++) begin
          pe_ctrl_valid[j] = 1'b1;
          pe_ctrl_flow_ud[j] = 1'b1;
        end
        tick();

        expect_word("flow_ud_chain/near", mesh00_d_valid, mesh00_d_word, 1'b1, word);
        if (i >= 31) begin
          expect_word("flow_ud_chain/far", mesh310_d_valid, mesh310_d_word, 1'b1, history[i-31]);
        end
      end

      for (i = 0; i < 31; i++) begin
        clear_all_inputs();
        force_mesh00_inputs(history[31-i], rand_finite_fp32());
        for (int j = 0; j < 32; j++) begin
          pe_ctrl_valid[j] = 1'b1;
          pe_ctrl_flow_ud[j] = 1'b1;
        end
        tick();
        expect_word("flow_ud_chain/drain", mesh310_d_valid, mesh310_d_word, 1'b1, history[31-i]);
      end

      release_mesh00_inputs();
    end
  endtask

  task automatic paper_phase_trace_case();
    begin
      load_reg_li_case(pack_fp32(1'b0, 8'h7f, 23'h400000));
      flow_lr_chain_case();
      flow_ud_chain_case();
      flow_du_case(pack_fp32(1'b0, 8'h82, 23'h300000));
      flow_ud_and_acc_pipe_case(pack_fp32(1'b0, 8'h83, 23'h123456));
      mac_burst_case(32);

      clear_all_inputs();
      force_mesh00_inputs(rand_finite_fp32(), rand_finite_fp32());
      pe_ctrl_valid[0] = 1'b1;
      pe_ctrl_mac[0] = 1'b1;
      pe_ctrl_acc_ui[0] = 1'b1;
      pe_ctrl_exp2[0] = 1'b1;
      tick();
      expect_ctrl_passthrough("paper/exp2_ctrl", 1'b1, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1);
      clear_all_inputs();
      tick();
      tick();
      tick();
      tick();
      if (!mesh00_u_valid && !mesh00_d_valid) begin
        $fatal(1, "[paper/exp2_ctrl] expected exp2 launch to produce a routed result");
      end
      release_mesh00_inputs();
    end
  endtask

  task automatic mac_burst_case(input int count);
    int i;
    logic [31:0] weight_word;
    logic [31:0] vec_word;
    logic [31:0] c_word;
    logic [31:0] exp_word;
    logic acc_ui_sel;
    logic [31:0] rand_sel_word;
    begin
      clear_all_inputs();

      for (i = 0; i < count; i++) begin
        weight_word = rand_finite_fp32();
        vec_word = rand_finite_fp32();
        c_word = rand_finite_fp32();
        rand_sel_word = $urandom();
        acc_ui_sel = rand_sel_word[0];

        pe_data_sign[0] = weight_word[31];
        pe_data_exp[0] = weight_word[30:23];
        pe_data_mantissa[0] = weight_word[22:0];

        pe_ctrl_valid[0] = 1'b1;
        pe_ctrl_load_reg_li[0] = 1'b1;
        tick();

        expect_word("mac_burst/load", mesh00_r_valid, mesh00_r_word, 1'b1, weight_word);
        expect_ctrl_passthrough("mac_burst/load_ctrl", 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);

        clear_all_inputs();
        force_mesh00_inputs(c_word, c_word);
        pe_data_sign[0] = vec_word[31];
        pe_data_exp[0] = vec_word[30:23];
        pe_data_mantissa[0] = vec_word[22:0];

        pe_ctrl_valid[0] = 1'b1;
        pe_ctrl_mac[0] = 1'b1;
        pe_ctrl_acc_ui[0] = acc_ui_sel;
        pe_ctrl_update_reg[0] = 1'b1;

        exp_word = fp32_mac_expected(weight_word, vec_word, c_word);

        mac_issue_valid = 1'b1;
        mac_issue_acc_ui = acc_ui_sel;
        mac_issue_word = exp_word;
        tick();
        mac_issue_valid = 1'b0;

        if (mac_pipe[MAC_LATENCY].valid) begin
          if (mac_pipe[MAC_LATENCY].acc_ui) begin
            expect_word("mac_burst/d", mesh00_d_valid, mesh00_d_word, 1'b1, mac_pipe[MAC_LATENCY].word);
          end else begin
            expect_word("mac_burst/u", mesh00_u_valid, mesh00_u_word, 1'b1, mac_pipe[MAC_LATENCY].word);
          end
        end
      end

      for (i = 0; i < MAC_LATENCY + 1; i++) begin
        clear_all_inputs();
        tick();
        if (mac_pipe[MAC_LATENCY].valid) begin
          if (mac_pipe[MAC_LATENCY].acc_ui) begin
            expect_word("mac_burst/d_tail", mesh00_d_valid, mesh00_d_word, 1'b1, mac_pipe[MAC_LATENCY].word);
          end else begin
            expect_word("mac_burst/u_tail", mesh00_u_valid, mesh00_u_word, 1'b1, mac_pipe[MAC_LATENCY].word);
          end
        end
      end

      release_mesh00_inputs();
    end
  endtask

  always @(posedge clk or negedge rst_n) begin
    int j;
    if (!rst_n) begin
      cycle_count <= 0;
      for (j = 0; j <= MAC_LATENCY; j++) begin
        mac_pipe[j].valid <= 1'b0;
        mac_pipe[j].acc_ui <= 1'b0;
        mac_pipe[j].word <= 32'h0;
      end
      mesh310_prev_word <= 32'h0;
      mesh310_prev_valid <= 1'b0;
    end else begin
      for (j = MAC_LATENCY; j > 0; j--) begin
        mac_pipe[j] <= mac_pipe[j-1];
      end
      mac_pipe[0].valid <= mac_issue_valid;
      mac_pipe[0].acc_ui <= mac_issue_acc_ui;
      mac_pipe[0].word <= mac_issue_word;
      mesh310_prev_word <= mesh310_d_word;
      mesh310_prev_valid <= mesh310_d_valid;
      cycle_count <= cycle_count + 1;
      if (cycle_count > TIMEOUT_CYCLES) begin
        $fatal(1, "[TB] timeout after %0d cycles", cycle_count);
      end
    end
  end

  always #5 clk = ~clk;

  initial begin
    int unsigned seed_word;
    if (!$value$plusargs("CASE=%s", case_name)) begin
      case_name = "baseline";
    end
    seed_word = $urandom();
    clear_all_inputs();
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) tick();

    if (case_name == "paper") begin
      paper_phase_trace_case();
    end else begin
      load_reg_li_case(pack_fp32(1'b0, 8'h7f, 23'h400000));
      load_reg_ui_case(pack_fp32(1'b0, 8'h80, 23'h100000));
      flow_lr_case(pack_fp32(1'b0, 8'h81, 23'h200000));
      flow_du_case(pack_fp32(1'b0, 8'h82, 23'h300000));
      flow_ud_and_acc_pipe_case(pack_fp32(1'b0, 8'h83, 23'h123456));
      mac_burst_case(8);
    end

    $display("[TB] PASS systolic array harness");
    $finish;
  end
endmodule

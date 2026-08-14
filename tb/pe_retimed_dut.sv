`timescale 1ns / 1ps

module PE_retimed_dut(
  input         clock,
                rstn,
                mode_sel,
                io_in_ctrl_valid,
                io_in_ctrl_bits_mac,
                io_in_ctrl_bits_acc_ui,
                io_in_ctrl_bits_load_reg_li,
                io_in_ctrl_bits_load_reg_ui,
                io_in_ctrl_bits_flow_lr,
                io_in_ctrl_bits_flow_ud,
                io_in_ctrl_bits_flow_du,
                io_in_ctrl_bits_update_reg,
                io_in_ctrl_bits_exp2,
  output        io_out_ctrl_valid,
                io_out_ctrl_bits_mac,
                io_out_ctrl_bits_acc_ui,
                io_out_ctrl_bits_load_reg_li,
                io_out_ctrl_bits_load_reg_ui,
                io_out_ctrl_bits_flow_lr,
                io_out_ctrl_bits_flow_ud,
                io_out_ctrl_bits_flow_du,
                io_out_ctrl_bits_update_reg,
                io_out_ctrl_bits_exp2,
  input         io_u_input_bits_sign,
  input  [7:0]  io_u_input_bits_exp,
  input  [22:0] io_u_input_bits_mantissa,
  output        io_u_output_valid,
                io_u_output_bits_sign,
  output [7:0]  io_u_output_bits_exp,
  output [22:0] io_u_output_bits_mantissa,
  input         io_d_input_bits_sign,
  input  [7:0]  io_d_input_bits_exp,
  input  [22:0] io_d_input_bits_mantissa,
  input  [31:0] io_partial_sum_in,
  input         io_rst_acc,
  output        io_d_output_valid,
                io_d_output_bits_sign,
  output [7:0]  io_d_output_bits_exp,
  output [22:0] io_d_output_bits_mantissa,
  input         io_l_input_bits_sign,
  input  [7:0]  io_l_input_bits_exp,
  input  [22:0] io_l_input_bits_mantissa,
  output        io_r_output_valid,
                io_r_output_bits_sign,
  output [7:0]  io_r_output_bits_exp,
  output [22:0] io_r_output_bits_mantissa
);

  reg         mode_q;
  wire        os_mode;
  wire        issue_mac_valid_ws;
  wire        issue_mac_valid_os;
  wire        issue_mac_valid;
  wire        mac_commit_acc_ui;
  wire        mac_commit_update_reg;
  wire        mac_commit_exp2;
  wire        os_commit_acc_ui;
  wire        os_commit_update_reg;
  wire        os_commit_exp2;
  wire        mac_result_valid;
  wire        mac_result_accType_sign;
  wire [7:0]  mac_result_accType_exp;
  wire [22:0] mac_result_accType_mantissa;
  wire        mac_result_elemType_sign;
  wire [7:0]  mac_result_elemType_exp;
  wire [22:0] mac_result_elemType_mantissa;
  wire        mac_result_exp2;
  wire        commit_to_u;
  wire        commit_to_d;
  wire        flow_to_u;
  wire        flow_to_d;
  wire        flow_to_r;
  wire        mode_switch_idle;
  reg         reg_sign;
  reg  [7:0]  reg_exp;
  reg  [22:0] reg_mantissa;
  reg         exp2Done;
  reg  [3:0]  mac_valid_pipe;
  reg  [3:0]  mac_acc_ui_pipe;
  reg  [3:0]  mac_update_reg_pipe;
  reg  [3:0]  mac_exp2_pipe;
  reg  [3:0]  ctrl_valid_pipe;
  reg  [3:0]  ctrl_mac_pipe;
  reg  [3:0]  ctrl_acc_ui_pipe;
  reg  [3:0]  ctrl_load_reg_li_pipe;
  reg  [3:0]  ctrl_load_reg_ui_pipe;
  reg  [3:0]  ctrl_flow_lr_pipe;
  reg  [3:0]  ctrl_flow_ud_pipe;
  reg  [3:0]  ctrl_flow_du_pipe;
  reg  [3:0]  ctrl_update_reg_pipe;
  reg  [3:0]  ctrl_exp2_pipe;
  wire        mac_pipe_busy = |mac_valid_pipe;

  wire [31:0] reg_word = {reg_sign, reg_exp, reg_mantissa};
  wire [31:0] l_word = {io_l_input_bits_sign, io_l_input_bits_exp, io_l_input_bits_mantissa};
  wire [31:0] u_word = {io_u_input_bits_sign, io_u_input_bits_exp, io_u_input_bits_mantissa};
  wire [31:0] d_word = {io_d_input_bits_sign, io_d_input_bits_exp, io_d_input_bits_mantissa};
  wire [31:0] psum_word = io_partial_sum_in;
  wire        os_seed_acc = os_mode & io_rst_acc;
  wire [31:0] os_a_word = l_word;
  wire [31:0] os_b_word = u_word;
  wire [31:0] os_c_word = reg_word;
  wire [31:0] ws_a_word =
    io_in_ctrl_bits_load_reg_li ? l_word
      : io_in_ctrl_bits_load_reg_ui ? u_word
      : reg_word;
  wire [31:0] ws_b_word = l_word;
  wire [31:0] ws_c_word = io_in_ctrl_bits_acc_ui ? u_word : d_word;
  wire [31:0] mac_a_word = os_mode ? os_a_word : ws_a_word;
  wire [31:0] mac_b_word = os_mode ? os_b_word : ws_b_word;
  wire [31:0] mac_c_word = os_mode ? os_c_word : ws_c_word;
  wire        mac_cmd = os_mode ? 1'b0 : io_in_ctrl_bits_exp2;
  wire        mac_commit_fire = mac_result_valid;

  assign os_mode = mode_q;
  assign issue_mac_valid_ws = io_in_ctrl_valid & (io_in_ctrl_bits_mac | io_in_ctrl_bits_exp2);
  assign issue_mac_valid_os = io_in_ctrl_valid;
  assign issue_mac_valid = os_mode ? issue_mac_valid_os : issue_mac_valid_ws;

  assign os_commit_acc_ui = 1'b0;
  assign os_commit_update_reg = 1'b1;
  assign os_commit_exp2 = 1'b0;
  assign mac_commit_acc_ui = os_mode ? os_commit_acc_ui : mac_acc_ui_pipe[3];
  assign mac_commit_update_reg = os_mode ? os_commit_update_reg : mac_update_reg_pipe[3];
  assign mac_commit_exp2 = os_mode ? os_commit_exp2 : mac_exp2_pipe[3];
  assign mode_switch_idle = !mac_pipe_busy && (mode_q != mode_sel);

  assign commit_to_u = mac_result_valid & ~mac_commit_acc_ui;
  assign commit_to_d = mac_result_valid & mac_commit_acc_ui;
  assign flow_to_u = os_mode ? 1'b0 : io_in_ctrl_valid & io_in_ctrl_bits_flow_du;
  assign flow_to_d = os_mode ? 1'b0 : io_in_ctrl_valid & io_in_ctrl_bits_flow_ud;
  assign flow_to_r = os_mode ? 1'b0 : io_in_ctrl_valid & (io_in_ctrl_bits_load_reg_li | io_in_ctrl_bits_flow_lr);
  always @(posedge clock or negedge rstn) begin
    if (!rstn) begin
      mode_q <= 1'b0;
      mac_valid_pipe <= 4'h0;
      mac_acc_ui_pipe <= 4'h0;
      mac_update_reg_pipe <= 4'h0;
      mac_exp2_pipe <= 4'h0;
    end else begin
      if (!mac_pipe_busy) begin
        mode_q <= mode_sel;
      end
      mac_valid_pipe <= {mac_valid_pipe[2:0], issue_mac_valid};
      mac_acc_ui_pipe <= {mac_acc_ui_pipe[2:0], issue_mac_valid & io_in_ctrl_bits_acc_ui};
      mac_update_reg_pipe <= {mac_update_reg_pipe[2:0], issue_mac_valid & io_in_ctrl_bits_update_reg};
      mac_exp2_pipe <= {mac_exp2_pipe[2:0], issue_mac_valid & io_in_ctrl_bits_exp2};
      ctrl_valid_pipe <= {ctrl_valid_pipe[2:0], io_in_ctrl_valid};
      ctrl_mac_pipe <= {ctrl_mac_pipe[2:0], io_in_ctrl_bits_mac};
      ctrl_acc_ui_pipe <= {ctrl_acc_ui_pipe[2:0], io_in_ctrl_bits_acc_ui};
      ctrl_load_reg_li_pipe <= {ctrl_load_reg_li_pipe[2:0], io_in_ctrl_bits_load_reg_li};
      ctrl_load_reg_ui_pipe <= {ctrl_load_reg_ui_pipe[2:0], io_in_ctrl_bits_load_reg_ui};
      ctrl_flow_lr_pipe <= {ctrl_flow_lr_pipe[2:0], io_in_ctrl_bits_flow_lr};
      ctrl_flow_ud_pipe <= {ctrl_flow_ud_pipe[2:0], io_in_ctrl_bits_flow_ud};
      ctrl_flow_du_pipe <= {ctrl_flow_du_pipe[2:0], io_in_ctrl_bits_flow_du};
      ctrl_update_reg_pipe <= {ctrl_update_reg_pipe[2:0], io_in_ctrl_bits_update_reg};
      ctrl_exp2_pipe <= {ctrl_exp2_pipe[2:0], io_in_ctrl_bits_exp2};
    end
  end

  always @(posedge clock or negedge rstn) begin
    if (!rstn) begin
      reg_sign <= 1'b0;
      reg_exp <= 8'h00;
      reg_mantissa <= 23'h0;
      exp2Done <= 1'b0;
    end else begin
    // Result/commit closes on the same edge that the 4-cycle MAC token retires.
    // WS preserves legacy control semantics; OS always commits back into the
    // internal accumulator path.
    if (os_seed_acc) begin
      reg_sign <= io_partial_sum_in[31];
      reg_exp <= io_partial_sum_in[30:23];
      reg_mantissa <= io_partial_sum_in[22:0];
      exp2Done <= 1'b0;
    end else if (mac_result_valid) begin
      if (mac_commit_update_reg || (mac_commit_exp2 & mac_result_exp2)) begin
        reg_sign <= mac_result_elemType_sign;
        reg_exp <= mac_result_elemType_exp;
        reg_mantissa <= mac_result_elemType_mantissa;
      end
      if (mac_commit_exp2) begin
        exp2Done <= mac_result_exp2;
      end else begin
        exp2Done <= 1'b0;
      end
    end else if (io_in_ctrl_valid && !os_mode) begin
      if (io_in_ctrl_bits_load_reg_li) begin
        reg_sign <= io_l_input_bits_sign;
        reg_exp <= io_l_input_bits_exp;
        reg_mantissa <= io_l_input_bits_mantissa;
        exp2Done <= 1'b0;
      end else if (io_in_ctrl_bits_load_reg_ui) begin
        reg_sign <= io_u_input_bits_sign;
        reg_exp <= io_u_input_bits_exp;
        reg_mantissa <= io_u_input_bits_mantissa;
        exp2Done <= 1'b0;
      end
    end else if (mode_switch_idle) begin
      reg_sign <= 1'b0;
      reg_exp <= 8'h00;
      reg_mantissa <= 23'h0;
      exp2Done <= 1'b0;
    end
    end
  end

  initial begin
    reg_sign = 1'b0;
    reg_exp = 8'h00;
    reg_mantissa = 23'h0;
    exp2Done = 1'b0;
    mode_q = 1'b0;
    mac_valid_pipe = 4'h0;
    mac_acc_ui_pipe = 4'h0;
    mac_update_reg_pipe = 4'h0;
    mac_exp2_pipe = 4'h0;
    ctrl_valid_pipe = 4'h0;
    ctrl_mac_pipe = 4'h0;
    ctrl_acc_ui_pipe = 4'h0;
    ctrl_load_reg_li_pipe = 4'h0;
    ctrl_load_reg_ui_pipe = 4'h0;
    ctrl_flow_lr_pipe = 4'h0;
    ctrl_flow_ud_pipe = 4'h0;
    ctrl_flow_du_pipe = 4'h0;
    ctrl_update_reg_pipe = 4'h0;
    ctrl_exp2_pipe = 4'h0;
  end

  FPMacUnit macUnit (
    .clock                  (clock),
    .io_in_valid            (issue_mac_valid),
    .io_in_a_sign           (mac_a_word[31]),
    .io_in_a_exp            (mac_a_word[30:23]),
    .io_in_a_mantissa       (mac_a_word[22:0]),
    .io_in_b_sign           (mac_b_word[31]),
    .io_in_b_exp            (mac_b_word[30:23]),
    .io_in_b_mantissa       (mac_b_word[22:0]),
    .io_in_c_sign           (mac_c_word[31]),
    .io_in_c_exp            (mac_c_word[30:23]),
    .io_in_c_mantissa       (mac_c_word[22:0]),
    .io_in_cmd              (mac_cmd),
    .io_out_valid            (mac_result_valid),
    .io_out_accType_sign    (mac_result_accType_sign),
    .io_out_accType_exp     (mac_result_accType_exp),
    .io_out_accType_mantissa(mac_result_accType_mantissa),
    .io_out_elemType_sign   (mac_result_elemType_sign),
    .io_out_elemType_exp    (mac_result_elemType_exp),
    .io_out_elemType_mantissa(mac_result_elemType_mantissa),
    .io_out_exp2           (mac_result_exp2)
  );

  assign io_out_ctrl_valid = ctrl_valid_pipe[3];
  assign io_out_ctrl_bits_mac = ctrl_mac_pipe[3];
  assign io_out_ctrl_bits_acc_ui = ctrl_acc_ui_pipe[3];
  assign io_out_ctrl_bits_load_reg_li = ctrl_load_reg_li_pipe[3];
  assign io_out_ctrl_bits_load_reg_ui = ctrl_load_reg_ui_pipe[3];
  assign io_out_ctrl_bits_flow_lr = ctrl_flow_lr_pipe[3];
  assign io_out_ctrl_bits_flow_ud = ctrl_flow_ud_pipe[3];
  assign io_out_ctrl_bits_flow_du = ctrl_flow_du_pipe[3];
  assign io_out_ctrl_bits_update_reg = ctrl_update_reg_pipe[3];
  assign io_out_ctrl_bits_exp2 = ctrl_exp2_pipe[3];

  assign io_u_output_valid = commit_to_u | flow_to_u;
  assign io_u_output_bits_sign =
    commit_to_u ? mac_result_accType_sign : io_d_input_bits_sign;
  assign io_u_output_bits_exp =
    commit_to_u ? mac_result_accType_exp : io_d_input_bits_exp;
  assign io_u_output_bits_mantissa =
    commit_to_u ? mac_result_accType_mantissa : io_d_input_bits_mantissa;

  assign io_d_output_valid = commit_to_d | flow_to_d;
  assign io_d_output_bits_sign =
    commit_to_d ? mac_result_accType_sign : io_u_input_bits_sign;
  assign io_d_output_bits_exp =
    commit_to_d ? mac_result_accType_exp : io_u_input_bits_exp;
  assign io_d_output_bits_mantissa =
    commit_to_d ? mac_result_accType_mantissa : io_u_input_bits_mantissa;

  assign io_r_output_valid = flow_to_r;
  assign io_r_output_bits_sign =
    io_in_ctrl_bits_load_reg_li ? reg_sign : io_l_input_bits_sign;
  assign io_r_output_bits_exp =
    io_in_ctrl_bits_load_reg_li ? reg_exp : io_l_input_bits_exp;
  assign io_r_output_bits_mantissa =
    io_in_ctrl_bits_load_reg_li ? reg_mantissa : io_l_input_bits_mantissa;

endmodule

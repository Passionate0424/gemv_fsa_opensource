`timescale 1ns / 1ps

module PE(
  input         clock,
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
  function automatic logic [31:0] fp32_mac32(
    input logic [31:0] a,
    input logic [31:0] b,
    input logic [31:0] c
  );
    shortreal sr_a;
    shortreal sr_b;
    shortreal sr_c;
    shortreal sr_y;
    begin
      sr_a = $bitstoshortreal(a);
      sr_b = $bitstoshortreal(b);
      sr_c = $bitstoshortreal(c);
      sr_y = sr_a * sr_b + sr_c;
      fp32_mac32 = $shortrealtobits(sr_y);
    end
  endfunction

  logic [31:0] reg_word;
  logic [31:0] result_pipe [0:3];
  logic        valid_pipe [0:3];
  logic        acc_ui_pipe [0:3];

  wire [31:0] l_word = {io_l_input_bits_sign, io_l_input_bits_exp, io_l_input_bits_mantissa};
  wire [31:0] u_word = {io_u_input_bits_sign, io_u_input_bits_exp, io_u_input_bits_mantissa};
  wire [31:0] d_word = {io_d_input_bits_sign, io_d_input_bits_exp, io_d_input_bits_mantissa};
  wire [31:0] res_word = fp32_mac32(reg_word, l_word, io_in_ctrl_bits_acc_ui ? u_word : d_word);

  integer i;

  always @(posedge clock) begin
    for (i = 3; i > 0; i = i - 1) begin
      result_pipe[i] <= result_pipe[i-1];
      valid_pipe[i] <= valid_pipe[i-1];
      acc_ui_pipe[i] <= acc_ui_pipe[i-1];
    end
    result_pipe[0] <= 32'h0;
    valid_pipe[0] <= 1'b0;
    acc_ui_pipe[0] <= 1'b0;

    if (io_in_ctrl_valid) begin
      if (io_in_ctrl_bits_load_reg_li) begin
        reg_word <= l_word;
      end else if (io_in_ctrl_bits_load_reg_ui) begin
        reg_word <= u_word;
      end else if (io_in_ctrl_bits_mac) begin
        result_pipe[0] <= res_word;
        valid_pipe[0] <= 1'b1;
        acc_ui_pipe[0] <= io_in_ctrl_bits_acc_ui;
        if (io_in_ctrl_bits_update_reg) begin
          reg_word <= res_word;
        end
      end
    end
  end

  initial begin
    reg_word = 32'h00000000;
    for (i = 0; i < 4; i = i + 1) begin
      result_pipe[i] = 32'h00000000;
      valid_pipe[i] = 1'b0;
      acc_ui_pipe[i] = 1'b0;
    end
  end

  assign io_out_ctrl_valid = io_in_ctrl_valid;
  assign io_out_ctrl_bits_mac = io_in_ctrl_bits_mac;
  assign io_out_ctrl_bits_acc_ui = io_in_ctrl_bits_acc_ui;
  assign io_out_ctrl_bits_load_reg_li = io_in_ctrl_bits_load_reg_li;
  assign io_out_ctrl_bits_load_reg_ui = io_in_ctrl_bits_load_reg_ui;
  assign io_out_ctrl_bits_flow_lr = io_in_ctrl_bits_flow_lr;
  assign io_out_ctrl_bits_flow_ud = io_in_ctrl_bits_flow_ud;
  assign io_out_ctrl_bits_flow_du = io_in_ctrl_bits_flow_du;
  assign io_out_ctrl_bits_update_reg = io_in_ctrl_bits_update_reg;
  assign io_out_ctrl_bits_exp2 = io_in_ctrl_bits_exp2;

  assign io_u_output_valid = valid_pipe[3] & ~acc_ui_pipe[3];
  assign io_u_output_bits_sign = result_pipe[3][31];
  assign io_u_output_bits_exp = result_pipe[3][30:23];
  assign io_u_output_bits_mantissa = result_pipe[3][22:0];

  assign io_d_output_valid = valid_pipe[3] & acc_ui_pipe[3];
  assign io_d_output_bits_sign = result_pipe[3][31];
  assign io_d_output_bits_exp = result_pipe[3][30:23];
  assign io_d_output_bits_mantissa = result_pipe[3][22:0];

  assign io_r_output_valid = io_in_ctrl_valid & io_in_ctrl_bits_load_reg_li;
  assign io_r_output_bits_sign = io_l_input_bits_sign;
  assign io_r_output_bits_exp = io_l_input_bits_exp;
  assign io_r_output_bits_mantissa = io_l_input_bits_mantissa;
endmodule

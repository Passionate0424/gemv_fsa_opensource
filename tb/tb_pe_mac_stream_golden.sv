`timescale 1ns / 1ps

// Golden test for PE_retimed OS MAC dataflow.
// Verifies software a*b+c matches the PE output after 4 cycles of latency,
// with continuous issue traffic, vec on io_u_input, and c on partial_sum_in.
module tb_pe_mac_stream_golden;
  logic clk = 1'b0;
  always #1 clk = ~clk;

  logic ctrl_valid;
  logic ctrl_mac;
  logic ctrl_acc_ui;
  logic ctrl_load_reg_li;
  logic ctrl_load_reg_ui;
  logic ctrl_flow_lr;
  logic ctrl_flow_ud;
  logic ctrl_flow_du;
  logic ctrl_update_reg;
  logic ctrl_exp2;

  logic u_sign;
  logic [7:0] u_exp;
  logic [22:0] u_man;
  logic d_sign;
  logic [7:0] d_exp;
  logic [22:0] d_man;
  logic [31:0] partial_sum_in;
  logic rst_acc;
  logic l_sign;
  logic [7:0] l_exp;
  logic [22:0] l_man;

  wire pe_out_ctrl_valid;
  wire pe_u_valid;
  wire pe_u_sign;
  wire [7:0] pe_u_exp;
  wire [22:0] pe_u_man;
  wire pe_d_valid;
  wire pe_d_sign;
  wire [7:0] pe_d_exp;
  wire [22:0] pe_d_man;
  wire pe_r_valid;
  wire pe_r_sign;
  wire [7:0] pe_r_exp;
  wire [22:0] pe_r_man;

  logic rstn;

  PE dut (
    .clock(clk),
    .mode_sel(1'b1),
    .io_in_ctrl_valid(ctrl_valid),
    .io_in_ctrl_bits_mac(ctrl_mac),
    .io_in_ctrl_bits_acc_ui(ctrl_acc_ui),
    .io_in_ctrl_bits_load_reg_li(ctrl_load_reg_li),
    .io_in_ctrl_bits_load_reg_ui(ctrl_load_reg_ui),
    .io_in_ctrl_bits_flow_lr(ctrl_flow_lr),
    .io_in_ctrl_bits_flow_ud(ctrl_flow_ud),
    .io_in_ctrl_bits_flow_du(ctrl_flow_du),
    .io_in_ctrl_bits_update_reg(ctrl_update_reg),
    .io_in_ctrl_bits_exp2(ctrl_exp2),
    .io_out_ctrl_valid(pe_out_ctrl_valid),
    .io_out_ctrl_bits_mac(),
    .io_out_ctrl_bits_acc_ui(),
    .io_out_ctrl_bits_load_reg_li(),
    .io_out_ctrl_bits_load_reg_ui(),
    .io_out_ctrl_bits_flow_lr(),
    .io_out_ctrl_bits_flow_ud(),
    .io_out_ctrl_bits_flow_du(),
    .io_out_ctrl_bits_update_reg(),
    .io_out_ctrl_bits_exp2(),
    .io_u_input_bits_sign(u_sign),
    .io_u_input_bits_exp(u_exp),
    .io_u_input_bits_mantissa(u_man),
    .io_u_output_valid(pe_u_valid),
    .io_u_output_bits_sign(pe_u_sign),
    .io_u_output_bits_exp(pe_u_exp),
    .io_u_output_bits_mantissa(pe_u_man),
    .io_d_input_bits_sign(d_sign),
    .io_d_input_bits_exp(d_exp),
    .io_d_input_bits_mantissa(d_man),
    .io_partial_sum_in(partial_sum_in),
    .io_rst_acc(rst_acc),
    .io_d_output_valid(pe_d_valid),
    .io_d_output_bits_sign(pe_d_sign),
    .io_d_output_bits_exp(pe_d_exp),
    .io_d_output_bits_mantissa(pe_d_man),
    .io_l_input_bits_sign(l_sign),
    .io_l_input_bits_exp(l_exp),
    .io_l_input_bits_mantissa(l_man),
    .io_r_output_valid(pe_r_valid),
    .io_r_output_bits_sign(pe_r_sign),
    .io_r_output_bits_exp(pe_r_exp),
    .io_r_output_bits_mantissa(pe_r_man)
  );

  localparam int NUM_ISSUES = 8;
  localparam int TOTAL_CYCLES = NUM_ISSUES + 5;

  logic [31:0] a_seq [0:NUM_ISSUES-1];
  logic [31:0] b_seq [0:NUM_ISSUES-1];
  logic [31:0] exp_result [0:NUM_ISSUES-1];
  logic [31:0] gold_c;
  int idx;

  function automatic logic [31:0] sw_mac32(
    input logic [31:0] a_bits,
    input logic [31:0] b_bits,
    input logic [31:0] c_bits
  );
    shortreal a_sr;
    shortreal b_sr;
    shortreal c_sr;
    shortreal y_sr;
    begin
      a_sr = $bitstoshortreal(a_bits);
      b_sr = $bitstoshortreal(b_bits);
      c_sr = $bitstoshortreal(c_bits);
      y_sr = a_sr * b_sr + c_sr;
      sw_mac32 = $shortrealtobits(y_sr);
    end
  endfunction

  function automatic logic [31:0] pe_u_word();
    pe_u_word = {pe_u_sign, pe_u_exp, pe_u_man};
  endfunction

  task automatic drive_idle();
    begin
      ctrl_valid = 1'b0;
      ctrl_mac = 1'b0;
      ctrl_acc_ui = 1'b0;
      ctrl_load_reg_li = 1'b0;
      ctrl_load_reg_ui = 1'b0;
      ctrl_flow_lr = 1'b0;
      ctrl_flow_ud = 1'b0;
      ctrl_flow_du = 1'b0;
      ctrl_update_reg = 1'b0;
      ctrl_exp2 = 1'b0;
      u_sign = 1'b0; u_exp = 8'h0; u_man = 23'h0;
      d_sign = 1'b0; d_exp = 8'h0; d_man = 23'h0;
      partial_sum_in = 32'h0;
      rst_acc = 1'b0;
      l_sign = 1'b0; l_exp = 8'h0; l_man = 23'h0;
    end
  endtask

  task automatic init_vectors();
    begin
      a_seq[0] = 32'h3fc00000; // 1.5
      a_seq[1] = 32'h40200000; // 2.5
      a_seq[2] = 32'h3f000000; // 0.5
      a_seq[3] = 32'h40400000; // 3.0
      a_seq[4] = 32'h3f800000; // 1.0
      a_seq[5] = 32'h40000000; // 2.0
      a_seq[6] = 32'h3fc00000; // 1.5
      a_seq[7] = 32'h3e800000; // 0.25

      b_seq[0] = 32'h40000000; // 2.0
      b_seq[1] = 32'h40800000; // 4.0
      b_seq[2] = 32'h41000000; // 8.0
      b_seq[3] = 32'h3f800000; // 1.0
      b_seq[4] = 32'h3f800000; // 1.0
      b_seq[5] = 32'h40000000; // 2.0
      b_seq[6] = 32'h40000000; // 2.0
      b_seq[7] = 32'h41800000; // 16.0
    end
  endtask

  initial begin
    int i;

    init_vectors();
    drive_idle();
    gold_c = 32'h0;

    rstn = 1'b0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rstn = 1'b1;
    drive_idle();

    for (i = 0; i < TOTAL_CYCLES; i = i + 1) begin
      @(negedge clk);
      drive_idle();
      rst_acc = 1'b0;

      if (i == 0) begin
        ctrl_valid = 1'b0;
        rst_acc = 1'b1;
        partial_sum_in = gold_c;
      end else if (i <= NUM_ISSUES) begin
        idx = i - 1;
        ctrl_valid = 1'b1;
        ctrl_mac = 1'b1;
        ctrl_acc_ui = 1'b0;
        ctrl_load_reg_li = 1'b0;
        ctrl_load_reg_ui = 1'b0;
        ctrl_flow_lr = 1'b0;
        ctrl_flow_ud = 1'b0;
        ctrl_flow_du = 1'b0;
        ctrl_update_reg = 1'b1;
        ctrl_exp2 = 1'b0;
        u_sign = b_seq[idx][31];
        u_exp = b_seq[idx][30:23];
        u_man = b_seq[idx][22:0];
        d_sign = 1'b0;
        d_exp = 8'h0;
        d_man = 23'h0;
        partial_sum_in = 32'h0;
        l_sign = a_seq[idx][31];
        l_exp = a_seq[idx][30:23];
        l_man = a_seq[idx][22:0];
        exp_result[idx] = sw_mac32(a_seq[idx], b_seq[idx], gold_c);
        $display(
          "[ISSUE] idx=%0d a=%08h b=%08h c=%08h exp=%08h",
          idx, a_seq[idx], b_seq[idx], gold_c, exp_result[idx]
        );
        gold_c = exp_result[idx];
      end

      @(posedge clk);
      #1ps;

      if (i >= 5 && (i - 5) < NUM_ISSUES) begin
        if (!pe_u_valid) begin
          $fatal(1, "[OUT ] idx=%0d valid dropped unexpectedly", i);
        end
        if (pe_u_word() !== exp_result[i - 5]) begin
          $fatal(
            1,
            "[OUT ] idx=%0d got=%08h exp=%08h",
            i,
          pe_u_word(),
          exp_result[i - 5]
          );
        end
        $display(
          "[RET ] idx=%0d out=%08h gold_c=%08h",
          i,
          pe_u_word(),
          exp_result[i - 5]
        );
      end else if (i < 5) begin
        if (pe_u_valid) begin
          $fatal(1, "[OUT ] idx=%0d output valid too early", i);
        end
      end
    end

    if (gold_c !== exp_result[NUM_ISSUES-1]) begin
      $fatal(1, "[FINAL] gold state did not settle as expected");
    end

    $display("[PASS] tb_pe_mac_stream_golden completed");
    $finish;
  end
endmodule

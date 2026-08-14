`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// tb_pe_retimed
//
// PE_retimed 参考验证TB
// 对单个 PE 的控制信号、上下游数据通路和寄存状态做定向检查，
// 用于验证重定时后的 PE 行为与预期一致。
//
// 重点关注控制传播、寄存更新和输出可见性。
////////////////////////////////////////////////////////////////
module tb_pe_retimed;
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
  logic l_sign;
  logic [7:0] l_exp;
  logic [22:0] l_man;

  wire pe_out_ctrl_valid;
  wire pe_out_ctrl_mac;
  wire pe_out_ctrl_acc_ui;
  wire pe_out_ctrl_load_reg_li;
  wire pe_out_ctrl_load_reg_ui;
  wire pe_out_ctrl_flow_lr;
  wire pe_out_ctrl_flow_ud;
  wire pe_out_ctrl_flow_du;
  wire pe_out_ctrl_update_reg;
  wire pe_out_ctrl_exp2;

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

  PE dut_pe (
    .clock(clk),
    .mode_sel(1'b0),
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
    .io_out_ctrl_bits_mac(pe_out_ctrl_mac),
    .io_out_ctrl_bits_acc_ui(pe_out_ctrl_acc_ui),
    .io_out_ctrl_bits_load_reg_li(pe_out_ctrl_load_reg_li),
    .io_out_ctrl_bits_load_reg_ui(pe_out_ctrl_load_reg_ui),
    .io_out_ctrl_bits_flow_lr(pe_out_ctrl_flow_lr),
    .io_out_ctrl_bits_flow_ud(pe_out_ctrl_flow_ud),
    .io_out_ctrl_bits_flow_du(pe_out_ctrl_flow_du),
    .io_out_ctrl_bits_update_reg(pe_out_ctrl_update_reg),
    .io_out_ctrl_bits_exp2(pe_out_ctrl_exp2),
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

  int cycle = 0;
  always @(posedge clk) cycle <= cycle + 1;

  function automatic logic [31:0] pe_u_word();
    pe_u_word = {pe_u_sign, pe_u_exp, pe_u_man};
  endfunction

  function automatic logic [31:0] pe_d_word();
    pe_d_word = {pe_d_sign, pe_d_exp, pe_d_man};
  endfunction

  function automatic logic [31:0] pe_r_word();
    pe_r_word = {pe_r_sign, pe_r_exp, pe_r_man};
  endfunction

  function automatic logic [31:0] pe_reg_word();
    pe_reg_word = {dut_pe.reg_sign, dut_pe.reg_exp, dut_pe.reg_mantissa};
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
      u_sign = 1'b0; u_exp = 8'h00; u_man = 23'h0;
      d_sign = 1'b0; d_exp = 8'h00; d_man = 23'h0;
      l_sign = 1'b0; l_exp = 8'h00; l_man = 23'h0;
    end
  endtask

  task automatic apply_word_to_pe(
    input logic [31:0] uw,
    input logic [31:0] dw,
    input logic [31:0] lw
  );
    begin
      u_sign = uw[31];
      u_exp = uw[30:23];
      u_man = uw[22:0];
      d_sign = dw[31];
      d_exp = dw[30:23];
      d_man = dw[22:0];
      l_sign = lw[31];
      l_exp = lw[30:23];
      l_man = lw[22:0];
    end
  endtask

  task automatic load_weight(input logic [31:0] weight);
    begin
      @(negedge clk);
      drive_idle();
      apply_word_to_pe(32'h0, 32'h0, weight);
      ctrl_valid = 1'b1;
      ctrl_load_reg_li = 1'b1;
      @(posedge clk);
      #1ps;
      if (pe_reg_word() !== weight) begin
        $fatal(1, "[LOAD] register mismatch got=%08h exp=%08h", pe_reg_word(), weight);
      end
      if (dut_pe.exp2Done !== 1'b0) begin
        $fatal(1, "[LOAD] exp2Done should stay cleared");
      end
      $display(
        "[LOAD ] cycle=%0d ctrl=%0b load=%0b%0b flow=%0b%0b%0b r_valid=%0b reg=%08h exp2Done=%0b",
        cycle,
        pe_out_ctrl_valid,
        pe_out_ctrl_load_reg_li,
        pe_out_ctrl_load_reg_ui,
        pe_out_ctrl_flow_lr,
        pe_out_ctrl_flow_ud,
        pe_out_ctrl_flow_du,
        pe_r_valid,
        pe_reg_word(),
        dut_pe.exp2Done
      );
    end
  endtask

  task automatic mac_timing_case(
    input logic [31:0] weight,
    input logic [31:0] vec,
    input logic [31:0] psum,
    input logic acc_ui,
    input logic update_reg,
    input logic exp2_cmd
  );
    int wait_cycles;
    logic exp2_shadow;
    logic [31:0] commit_word;
    logic [31:0] reg_at_commit;
    logic [31:0] reg_at_post;
    logic exp2_at_post;
    begin
      load_weight(weight);

      @(negedge clk);
      drive_idle();
      if (acc_ui) begin
        apply_word_to_pe(psum, vec, vec);
      end else begin
        apply_word_to_pe(vec, psum, vec);
      end
      ctrl_valid = 1'b1;
      ctrl_mac = 1'b1;
      ctrl_acc_ui = acc_ui;
      ctrl_update_reg = update_reg;
      ctrl_exp2 = exp2_cmd;

      @(posedge clk);
      #1ps;
      if (pe_out_ctrl_valid !== 1'b0) begin
        $fatal(1, "[ISSUE] output valid should stay low on issue");
      end
      if (dut_pe.mac_commit_fire !== 1'b0) begin
        $fatal(1, "[ISSUE] commit fired too early");
      end
      if (pe_reg_word() !== weight) begin
        $fatal(1, "[ISSUE] register changed too early got=%08h exp=%08h", pe_reg_word(), weight);
      end
      $display(
        "[ISSUE] cycle=%0d ctrl=%0b mac=%0b acc_ui=%0b load=%0b%0b flow=%0b%0b%0b upd=%0b exp2=%0b commit=%0b reg=%08h exp2Done=%0b",
        cycle,
        pe_out_ctrl_valid,
        pe_out_ctrl_mac,
        pe_out_ctrl_acc_ui,
        pe_out_ctrl_load_reg_li,
        pe_out_ctrl_load_reg_ui,
        pe_out_ctrl_flow_lr,
        pe_out_ctrl_flow_ud,
        pe_out_ctrl_flow_du,
        pe_out_ctrl_update_reg,
        pe_out_ctrl_exp2,
        dut_pe.mac_commit_fire,
        pe_reg_word(),
        dut_pe.exp2Done
      );

      @(negedge clk);
      drive_idle();

      wait_cycles = 0;
      while (dut_pe.mac_commit_fire !== 1'b1) begin
        @(posedge clk);
        #1ps;
        wait_cycles++;
        if (wait_cycles > 8) begin
          $fatal(1, "[COMMIT] commit never arrived");
        end
      end
      reg_at_commit = pe_reg_word();
      if (acc_ui ? !pe_d_valid : !pe_u_valid) begin
        $fatal(1, "[COMMIT] selected lane not valid");
      end
      if (acc_ui ? pe_u_valid : pe_d_valid) begin
        $fatal(1, "[COMMIT] non-selected lane unexpectedly valid");
      end
      commit_word = acc_ui ? pe_d_word() : pe_u_word();
      exp2_shadow = dut_pe.mac_commit_exp2 & dut_pe.mac_result_exp2;
      if (reg_at_commit !== weight) begin
        $fatal(1, "[COMMIT] register changed too early got=%08h exp=%08h", reg_at_commit, weight);
      end
      if (exp2_cmd && dut_pe.exp2Done !== 1'b0) begin
        $fatal(1, "[COMMIT] exp2Done changed too early got=%0b", dut_pe.exp2Done);
      end
      @(posedge clk);
      #1ps;
      reg_at_post = pe_reg_word();
      exp2_at_post = dut_pe.exp2Done;
      if (dut_pe.mac_commit_fire !== 1'b0) begin
        $fatal(1, "[POST ] commit should be a single-cycle pulse");
      end
      if (dut_pe.mac_commit_update_reg || exp2_shadow) begin
        if (reg_at_post !== commit_word) begin
          $fatal(1, "[WB] register did not update on commit+1 got=%08h exp=%08h", reg_at_post, commit_word);
        end
      end else if (reg_at_post !== weight) begin
        $fatal(1, "[WB] register should hold old weight got=%08h exp=%08h", reg_at_post, weight);
      end
      if (exp2_cmd) begin
        if (exp2_at_post !== exp2_shadow) begin
          $fatal(1, "[WB] exp2Done did not update on commit+1 got=%0b exp=%0b", exp2_at_post, exp2_shadow);
        end
      end else if (exp2_at_post !== 1'b0) begin
        $fatal(1, "[WB] exp2Done should remain cleared");
      end
      $display(
        "[COMMIT] cycle=%0d latency=%0d ctrl=%0b mac=%0b acc_ui=%0b load=%0b%0b flow=%0b%0b%0b upd=%0b exp2=%0b commit=%0b reg=%08h out=%08h exp2Done=%0b",
        cycle,
        wait_cycles,
        pe_out_ctrl_valid,
        pe_out_ctrl_mac,
        pe_out_ctrl_acc_ui,
        pe_out_ctrl_load_reg_li,
        pe_out_ctrl_load_reg_ui,
        pe_out_ctrl_flow_lr,
        pe_out_ctrl_flow_ud,
        pe_out_ctrl_flow_du,
        pe_out_ctrl_update_reg,
        pe_out_ctrl_exp2,
        dut_pe.mac_commit_fire,
        pe_reg_word(),
        commit_word,
        dut_pe.exp2Done
      );
      $display(
        "[POST ] cycle=%0d latency=%0d ctrl=%0b mac=%0b acc_ui=%0b load=%0b%0b flow=%0b%0b%0b upd=%0b exp2=%0b commit=%0b reg=%08h exp2Done=%0b",
        cycle,
        wait_cycles,
        pe_out_ctrl_valid,
        pe_out_ctrl_mac,
        pe_out_ctrl_acc_ui,
        pe_out_ctrl_load_reg_li,
        pe_out_ctrl_load_reg_ui,
        pe_out_ctrl_flow_lr,
        pe_out_ctrl_flow_ud,
        pe_out_ctrl_flow_du,
        pe_out_ctrl_update_reg,
        pe_out_ctrl_exp2,
        dut_pe.mac_commit_fire,
        pe_reg_word(),
        dut_pe.exp2Done
      );
    end
  endtask

  initial begin
    drive_idle();

    mac_timing_case(
      32'h3f800000,
      32'h40000000,
      32'h40400000,
      1'b0,
      1'b1,
      1'b1
    );

    $finish;
  end
endmodule

`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// tb_pe_dualflow
//
// PE 级双流数据通路验证TB
// 对比 PE 在上下左右输入输出上的控制信号传播，
// 覆盖 OS / WS 相关的数据流联动行为。
//
// 用于确认单个 PE 的控制转发与寄存行为。
////////////////////////////////////////////////////////////////
module tb_pe_dualflow;
  logic clk = 1'b0;
  always #1 clk = ~clk;

  logic rstn = 1'b0;
  initial begin
    repeat (3) @(posedge clk);
    rstn = 1'b1;
  end

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

  logic ref_en;
  logic ref_rst_acc;
  logic ref_cmd_exp2;
  logic [31:0] ref_weight_in;
  logic [31:0] ref_vec_in;
  logic [31:0] ref_partial_sum_in;
  wire [31:0] ref_vec_out;
  wire [31:0] ref_result;

  // Reference wrapper exposes the MAC result on the same compare edge.
  // The DUT's io_out_valid/result are observed after the clock edge settles,
  // so the reference must not wait an extra register stage before becoming visible.
  fp_mac_pipelined_acc_ref dut_ref (
    .clk(clk),
    .rstn(rstn),
    .en(ref_en),
    .rst_acc(ref_rst_acc),
    .cmd_exp2(ref_cmd_exp2),
    .weight_in(ref_weight_in),
    .vec_in(ref_vec_in),
    .partial_sum_in(ref_partial_sum_in),
    .vec_out(ref_vec_out),
    .result(ref_result)
  );

  int unsigned seed = 32'h1a2b3c4d;
  int load_pass = 0;
  int mac_pass = 0;
  int chain_pass = 0;
  int flow_pass = 0;
  int exp2_pass = 0;
  int burst_pass = 0;
  int bubble_pass = 0;
  int special_pass = 0;

  function automatic [31:0] pack_fp32(input logic s, input logic [7:0] e, input logic [22:0] m);
    pack_fp32 = {s, e, m};
  endfunction

  function automatic logic [31:0] rand_finite_fp32();
    logic [31:0] rnd;
    logic s;
    logic [7:0] e;
    logic [22:0] m;
    begin
      rnd = $urandom(seed);
      s = rnd[0];
      e = 8'((rnd % 254) + 1);
      m = rnd[22:0];
      rand_finite_fp32 = {s, e, m};
    end
  endfunction

  task automatic drive_idle();
    begin
      ctrl_valid = 1'b1;
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
      ref_en = 1'b0;
      ref_rst_acc = 1'b0;
      ref_cmd_exp2 = 1'b0;
      ref_weight_in = 32'h0;
      ref_vec_in = 32'h0;
      ref_partial_sum_in = 32'h0;
    end
  endtask

  task automatic drive_bubble();
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
      ref_en = 1'b0;
      ref_rst_acc = 1'b0;
      ref_cmd_exp2 = 1'b0;
      ref_weight_in = 32'h0;
      ref_vec_in = 32'h0;
      ref_partial_sum_in = 32'h0;
    end
  endtask

  task automatic clear_ctrl_inputs();
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
      u_exp  = uw[30:23];
      u_man  = uw[22:0];
      d_sign = dw[31];
      d_exp  = dw[30:23];
      d_man  = dw[22:0];
      l_sign = lw[31];
      l_exp  = lw[30:23];
      l_man  = lw[22:0];
    end
  endtask

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

  function automatic logic [31:0] pack_rawfloat_fma(
    input logic out_isZero,
    input logic out_isInf,
    input logic out_isNaN,
    input logic out_sign,
    input logic [10:0] out_exp,
    input logic [25:0] out_mantissa
  );
    logic [23:0] rounded_mantissa;
    logic [11:0] out_exp_12;
    logic [11:0] rounded_exp;
    logic overflow;
    logic underflow;
    logic res_exp_t;
    logic res_mantissa_t;
    begin
      rounded_mantissa =
        {1'h0, out_mantissa[24:2]}
        + {23'h0,
           (out_mantissa[1] & out_mantissa[0])
             | (out_mantissa[1] & ~out_mantissa[0] & out_mantissa[2])};
      out_exp_12 = {out_exp[10], out_exp};
      rounded_exp = out_exp_12 + {11'h0, rounded_mantissa[23]};
      overflow = $signed(rounded_exp) > 12'sh7F;
      underflow = $signed(rounded_exp) < -12'sh7E;
      res_exp_t = out_isInf | out_isNaN;
      res_mantissa_t = out_isZero | out_isInf;
      pack_rawfloat_fma =
        {
          out_sign & ~out_isNaN,
          res_exp_t | overflow
            ? 8'hFF
            : out_isZero | underflow
              ? 8'h0
              : rounded_exp[7:0] + 8'h7F,
          out_isNaN
            ? 23'h400000
            : res_mantissa_t | underflow | overflow
              ? 23'h0
              : rounded_mantissa[22:0]
      };
    end
  endfunction

  function automatic bit is_fp32_zero(input logic [31:0] w);
    return (w[30:23] == 8'h00) && (w[22:0] == 23'h0);
  endfunction

  function automatic bit is_fp32_inf(input logic [31:0] w);
    return (w[30:23] == 8'hFF) && (w[22:0] == 23'h0);
  endfunction

  function automatic bit is_fp32_nan(input logic [31:0] w);
    return (w[30:23] == 8'hFF) && (w[22:0] != 23'h0);
  endfunction

  function automatic logic [31:0] fp32_mac_expected(
    input logic [31:0] a,
    input logic [31:0] b,
    input logic [31:0] c
  );
    shortreal sr_a;
    shortreal sr_b;
    shortreal sr_c;
    shortreal sr_y;
    logic [31:0] result;
    logic prod_sign;
    begin
      if (is_fp32_nan(a) || is_fp32_nan(b) || is_fp32_nan(c)) begin
        result = 32'h7fc00000;
      end else if (is_fp32_inf(a) || is_fp32_inf(b)) begin
        prod_sign = a[31] ^ b[31];
        if (is_fp32_inf(c) && (c[31] != prod_sign)) begin
          result = 32'h7fc00000;
        end else begin
          result = {prod_sign, 8'hFF, 23'h0};
        end
      end else if (is_fp32_inf(c)) begin
        result = {c[31], 8'hFF, 23'h0};
      end else begin
        sr_a = $bitstoshortreal(a);
        sr_b = $bitstoshortreal(b);
        sr_c = $bitstoshortreal(c);
        sr_y = sr_a * sr_b + sr_c;
        result = $shortrealtobits(sr_y);
        if (is_fp32_nan(result)) begin
          result = 32'h7fc00000;
        end
      end
      fp32_mac_expected = result;
    end
  endfunction

  task automatic wait_cycles(input int n);
    int k;
    begin
      for (k = 0; k < n; k++) @(posedge clk);
    end
  endtask

  task automatic capture_ref_result(output logic [31:0] word);
    begin
      #1ps;
      word = ref_result;
    end
  endtask

  task automatic load_weight_cycle(
    input logic [31:0] weight,
    input bit load_from_ui
  );
    begin
      @(negedge clk);
      drive_idle();
      if (load_from_ui) begin
        apply_word_to_pe(weight, 32'h0, 32'h0);
        ctrl_load_reg_ui = 1'b1;
      end else begin
        apply_word_to_pe(32'h0, 32'h0, weight);
        ctrl_load_reg_li = 1'b1;
      end
      ctrl_valid = 1'b1;
      @(posedge clk);
      #1ps;
    end
  endtask

  task automatic issue_mac_cycle(
    input logic [31:0] vec,
    input logic [31:0] psum,
    input logic acc_ui,
    input logic exp2_cmd,
    input logic update_reg
  );
    begin
      @(negedge clk);
      clear_ctrl_inputs();
      if (acc_ui) begin
        apply_word_to_pe(psum, vec, vec);
      end else begin
        apply_word_to_pe(vec, psum, vec);
      end
      ctrl_mac = 1'b1;
      ctrl_acc_ui = acc_ui;
      ctrl_update_reg = update_reg;
      ctrl_exp2 = exp2_cmd;
      ctrl_valid = 1'b1;
      @(posedge clk);
    end
  endtask

  task automatic load_only_case(
    input logic [31:0] li_word,
    input logic [31:0] ui_word,
    input bit load_from_ui
  );
    logic [31:0] reg_expect;
    logic [31:0] reg_before;
    logic [31:0] reg_got;
    begin
      reg_expect = load_from_ui ? ui_word : li_word;
      reg_before = pe_reg_word();
      @(negedge clk);
      drive_idle();
      if (load_from_ui) begin
        apply_word_to_pe(ui_word, 32'h0, 32'h0);
        ctrl_load_reg_ui = 1'b1;
      end else begin
        apply_word_to_pe(32'h0, 32'h0, li_word);
        ctrl_load_reg_li = 1'b1;
      end
      ctrl_valid = 1'b1;
      @(posedge clk);

      if (pe_out_ctrl_valid !== 1'b1) begin
        $fatal(1, "[LOAD] control valid did not passthrough");
      end
      if (pe_out_ctrl_mac !== 1'b0 || pe_out_ctrl_acc_ui !== 1'b0
          || pe_out_ctrl_load_reg_li !== (load_from_ui ? 1'b0 : 1'b1)
          || pe_out_ctrl_load_reg_ui !== (load_from_ui ? 1'b1 : 1'b0)
          || pe_out_ctrl_flow_lr !== 1'b0 || pe_out_ctrl_flow_ud !== 1'b0
          || pe_out_ctrl_flow_du !== 1'b0 || pe_out_ctrl_update_reg !== 1'b0
          || pe_out_ctrl_exp2 !== 1'b0) begin
        $fatal(1, "[LOAD] control passthrough mismatch");
      end
      if (pe_u_valid !== 1'b0 || pe_d_valid !== 1'b0) begin
        $fatal(1, "[LOAD] result lanes should stay idle");
      end
      if (!load_from_ui) begin
        if (pe_r_valid !== 1'b1 || pe_r_word() !== reg_before) begin
          $fatal(1, "[LOAD] li row bridge mismatch got=%08h exp=%08h", pe_r_word(), reg_before);
        end
      end else begin
        if (pe_r_valid !== 1'b0) begin
          $fatal(1, "[LOAD] ui load should not drive r_output");
        end
      end
      #1ps;
      reg_got = pe_reg_word();
      if (reg_got !== reg_expect) begin
        $fatal(1, "[LOAD] register mismatch got=%08h exp=%08h", reg_got, reg_expect);
      end
      if (dut_pe.exp2Done !== 1'b0) begin
        $fatal(1, "[LOAD] exp2Done should stay cleared");
      end

      #1ps;
      load_pass++;
      @(negedge clk);
      drive_idle();
      @(posedge clk);
    end
  endtask

  task automatic mac_from_current_reg_case(
    input logic [31:0] expected_weight,
    input logic [31:0] vec,
    input logic [31:0] psum,
    input logic acc_ui,
    input bit update_reg,
    input bit exp2_cmd
  );
    logic [31:0] pe_expect;
    logic [31:0] pe_got;
    logic [31:0] reg_before;
    logic [31:0] reg_after;
    begin
      reg_before = pe_reg_word();
      if (reg_before !== expected_weight) begin
        $fatal(1, "[MAC] preloaded register mismatch got=%08h exp=%08h", reg_before, expected_weight);
      end

      ref_en = 1'b1;
      ref_rst_acc = 1'b1;
      ref_cmd_exp2 = exp2_cmd;
      ref_weight_in = expected_weight;
      ref_vec_in = vec;
      ref_partial_sum_in = psum;
      issue_mac_cycle(vec, psum, acc_ui, exp2_cmd, update_reg);

      if (pe_out_ctrl_valid !== 1'b0) begin
        $fatal(1, "[MAC] issue cycle should not expose a control result token");
      end
      #1ps;
      clear_ctrl_inputs();
      ref_en = 1'b0;
      ref_rst_acc = 1'b0;
      ref_cmd_exp2 = 1'b0;
      wait_cycles(3);
      #1ps;
      if (pe_out_ctrl_valid !== 1'b1 || pe_out_ctrl_mac !== 1'b1
          || pe_out_ctrl_acc_ui !== acc_ui
          || pe_out_ctrl_load_reg_li !== 1'b0 || pe_out_ctrl_load_reg_ui !== 1'b0
          || pe_out_ctrl_flow_lr !== 1'b0 || pe_out_ctrl_flow_ud !== 1'b0
          || pe_out_ctrl_flow_du !== 1'b0
          || pe_out_ctrl_update_reg !== update_reg
          || pe_out_ctrl_exp2 !== exp2_cmd) begin
        $fatal(1, "[MAC] delayed control result token mismatch");
      end
      capture_ref_result(pe_expect);

      if (dut_pe.mac_commit_valid !== dut_pe.mac_result_valid) begin
        $fatal(1, "[MAC] commit token and result valid are misaligned");
      end
      if (dut_pe.mac_commit_acc_ui !== acc_ui) begin
        $fatal(1, "[MAC] acc_ui token misaligned");
      end
      if (dut_pe.mac_commit_update_reg !== update_reg) begin
        $fatal(
          1,
          "[MAC] update_reg token misaligned got=%0b exp=%0b (acc_ui=%0b exp2=%0b commit_valid=%0b result_valid=%0b)",
          dut_pe.mac_commit_update_reg,
          update_reg,
          acc_ui,
          exp2_cmd,
          dut_pe.mac_commit_valid,
          dut_pe.mac_result_valid
        );
      end
      if (dut_pe.mac_commit_exp2 !== exp2_cmd) begin
        $fatal(1, "[MAC] exp2 token misaligned");
      end
      if (dut_pe.mac_commit_fire !== 1'b1) begin
        $fatal(1, "[MAC] commit did not fire at compare point");
      end

      pe_got = acc_ui ? pe_d_word() : pe_u_word();
      if (acc_ui ? !pe_d_valid : !pe_u_valid) begin
        $fatal(1, "[MAC] PE result not valid at compare point");
      end
      if (acc_ui ? pe_u_valid : pe_d_valid) begin
        $fatal(1, "[MAC] non-selected lane unexpectedly valid");
      end
      if (pe_got !== pe_expect) begin
        $fatal(
          1,
          "[MAC] mismatch PE=%08h REF=%08h (weight=%08h vec=%08h psum=%08h acc_ui=%0b load_weight=%08h reg_before=%08h reg_after=%08h mac_acc=%08h a=%08h b=%08h c=%08h update=%0b exp2=%0b)",
          pe_got,
          pe_expect,
          expected_weight,
          vec,
          psum,
          acc_ui,
          expected_weight,
          reg_before,
          pe_reg_word(),
          {dut_pe.mac_result_accType_sign, dut_pe.mac_result_accType_exp, dut_pe.mac_result_accType_mantissa},
          {dut_pe.macUnit.io_in_a_sign, dut_pe.macUnit.io_in_a_exp, dut_pe.macUnit.io_in_a_mantissa},
          {dut_pe.macUnit.io_in_b_sign, dut_pe.macUnit.io_in_b_exp, dut_pe.macUnit.io_in_b_mantissa},
          {dut_pe.macUnit.io_in_c_sign, dut_pe.macUnit.io_in_c_exp, dut_pe.macUnit.io_in_c_mantissa},
          update_reg,
          exp2_cmd
        );
      end

      if (update_reg || exp2_cmd) begin
        if (dut_pe.mac_commit_update_fire !== 1'b1) begin
          $fatal(1, "[MAC] update_fire missing for committed MAC");
        end
      end else if (dut_pe.mac_commit_update_fire !== 1'b0) begin
        $fatal(1, "[MAC] update_fire should stay low");
      end

      @(negedge clk);
      drive_idle();
      @(posedge clk);
      #1ps;
      $display(
        "[MAC-DBG0] commit=%0b wb_q=%0b wb_qq=%0b result_valid=%0b result_acc=%08h result_elem=%08h hold=%08h reg=%08h ref=%08h",
        dut_pe.mac_commit_fire,
        dut_pe.mac_wb_fire_q,
        dut_pe.mac_wb_fire_qq,
        dut_pe.mac_result_valid,
        {dut_pe.mac_result_accType_sign, dut_pe.mac_result_accType_exp, dut_pe.mac_result_accType_mantissa},
        {dut_pe.mac_result_elemType_sign, dut_pe.mac_result_elemType_exp, dut_pe.mac_result_elemType_mantissa},
        {dut_pe.mac_wb_result_elemType_sign_q, dut_pe.mac_wb_result_elemType_exp_q, dut_pe.mac_wb_result_elemType_mantissa_q},
        pe_reg_word(),
        pe_expect
      );
      @(negedge clk);
      drive_idle();
      @(posedge clk);
      #1ps;
      $display(
        "[MAC-DBG1] commit=%0b wb_q=%0b wb_qq=%0b result_valid=%0b result_acc=%08h result_elem=%08h hold=%08h reg=%08h ref=%08h",
        dut_pe.mac_commit_fire,
        dut_pe.mac_wb_fire_q,
        dut_pe.mac_wb_fire_qq,
        dut_pe.mac_result_valid,
        {dut_pe.mac_result_accType_sign, dut_pe.mac_result_accType_exp, dut_pe.mac_result_accType_mantissa},
        {dut_pe.mac_result_elemType_sign, dut_pe.mac_result_elemType_exp, dut_pe.mac_result_elemType_mantissa},
        {dut_pe.mac_wb_result_elemType_sign_q, dut_pe.mac_wb_result_elemType_exp_q, dut_pe.mac_wb_result_elemType_mantissa_q},
        pe_reg_word(),
        pe_expect
      );

      @(negedge clk);
      drive_idle();
      @(posedge clk);
      #1ps;
      $display(
        "[MAC-DBG2] commit=%0b wb_q=%0b wb_qq=%0b result_valid=%0b result_acc=%08h result_elem=%08h hold=%08h reg=%08h ref=%08h",
        dut_pe.mac_commit_fire,
        dut_pe.mac_wb_fire_q,
        dut_pe.mac_wb_fire_qq,
        dut_pe.mac_result_valid,
        {dut_pe.mac_result_accType_sign, dut_pe.mac_result_accType_exp, dut_pe.mac_result_accType_mantissa},
        {dut_pe.mac_result_elemType_sign, dut_pe.mac_result_elemType_exp, dut_pe.mac_result_elemType_mantissa},
        {dut_pe.mac_wb_result_elemType_sign_q, dut_pe.mac_wb_result_elemType_exp_q, dut_pe.mac_wb_result_elemType_mantissa_q},
        pe_reg_word(),
        pe_expect
      );

      reg_after = pe_reg_word();
      if ((update_reg || exp2_cmd) && reg_after !== pe_expect) begin
        $display(
          "[DBG] commit=%0b wb_q=%0b wb_up=%0b wb_exp2=%0b result_valid=%0b result_acc=%08h result_elem=%08h hold_reg=%08h",
          dut_pe.mac_commit_fire,
          dut_pe.mac_wb_fire_q,
          dut_pe.mac_wb_update_reg_q,
          dut_pe.mac_wb_exp2_q,
          dut_pe.mac_result_valid,
          {dut_pe.mac_result_accType_sign, dut_pe.mac_result_accType_exp, dut_pe.mac_result_accType_mantissa},
          {dut_pe.mac_result_elemType_sign, dut_pe.mac_result_elemType_exp, dut_pe.mac_result_elemType_mantissa},
          reg_after
        );
        $fatal(1, "[MAC] register did not capture committed result got=%08h exp=%08h", reg_after, pe_expect);
      end
      if (!(update_reg || exp2_cmd) && reg_after !== expected_weight) begin
        $fatal(1, "[MAC] register should have held weight got=%08h exp=%08h", reg_after, expected_weight);
      end
      if (exp2_cmd) begin
        if (dut_pe.exp2Done !== dut_pe.mac_wb_result_exp2_q) begin
          $fatal(
            1,
            "[MAC] exp2Done mismatch after writeback got=%0b exp=%0b",
            dut_pe.exp2Done,
            dut_pe.mac_wb_result_exp2_q
          );
        end
      end else if (dut_pe.exp2Done !== 1'b0) begin
        $fatal(1, "[MAC] exp2Done should stay cleared got=%0b", dut_pe.exp2Done);
      end
      mac_pass++;

      @(negedge clk);
      drive_idle();
      @(posedge clk);
    end
  endtask

  task automatic mac_compare_case(
    input logic [31:0] weight,
    input logic [31:0] vec,
    input logic [31:0] psum,
    input logic acc_ui,
    input bit load_from_ui,
    input bit update_reg
  );
    begin
      load_weight_cycle(weight, load_from_ui);
      if (pe_reg_word() !== weight) begin
        $fatal(1, "[MAC] load path did not capture weight got=%08h exp=%08h", pe_reg_word(), weight);
      end
      if (dut_pe.exp2Done !== 1'b0) begin
        $fatal(1, "[MAC] exp2Done should be cleared before MAC");
      end
      mac_from_current_reg_case(weight, vec, psum, acc_ui, update_reg, 1'b0);
    end
  endtask

  task automatic exp2_case(
    input logic [31:0] weight,
    input logic [31:0] vec,
    input logic [31:0] psum,
    input logic acc_ui,
    input bit load_from_ui
  );
    begin
      load_weight_cycle(weight, load_from_ui);
      mac_from_current_reg_case(weight, vec, psum, acc_ui, 1'b1, 1'b1);
      exp2_pass++;
    end
  endtask

  task automatic load_priority_case(
    input logic [31:0] li_word,
    input logic [31:0] ui_word,
    input logic [31:0] vec,
    input logic [31:0] psum
  );
    logic [31:0] prio_expect;
    logic [31:0] reg_before;
    begin
      reg_before = pe_reg_word();
      @(negedge clk);
      drive_idle();
      apply_word_to_pe(ui_word, 32'h0, li_word);
      ctrl_load_reg_li = 1'b1;
      ctrl_load_reg_ui = 1'b1;
      ctrl_valid = 1'b1;
      @(posedge clk);

      if (pe_out_ctrl_valid !== 1'b1 || pe_out_ctrl_load_reg_li !== 1'b1
          || pe_out_ctrl_load_reg_ui !== 1'b1 || pe_out_ctrl_mac !== 1'b0) begin
        $fatal(1, "[PRIO] load control passthrough mismatch");
      end
      if (pe_r_valid !== 1'b1 || pe_r_word() !== reg_before) begin
        $fatal(1, "[PRIO] load_reg_li row bridge mismatch got=%08h exp=%08h", pe_r_word(), reg_before);
      end
      #1ps;
      if (pe_reg_word() !== li_word) begin
        $fatal(1, "[PRIO] register did not keep load_reg_li value");
      end

      @(negedge clk);
      drive_idle();
      apply_word_to_pe(vec, psum, vec);
      ref_en = 1'b1;
      ref_rst_acc = 1'b1;
      ref_cmd_exp2 = 1'b0;
      ref_weight_in = li_word;
      ref_vec_in = vec;
      ref_partial_sum_in = psum;
      ctrl_mac = 1'b1;
      ctrl_acc_ui = 1'b0;
      ctrl_update_reg = 1'b1;
      ctrl_valid = 1'b1;
      @(posedge clk);
      ref_rst_acc = 1'b0;

      if (pe_out_ctrl_valid !== 1'b1 || pe_out_ctrl_mac !== 1'b1
          || pe_out_ctrl_update_reg !== 1'b1 || pe_out_ctrl_acc_ui !== 1'b0) begin
        $fatal(1, "[PRIO] MAC control passthrough mismatch");
      end
      if (pe_r_valid !== 1'b0) begin
        $fatal(1, "[PRIO] r_output should be idle on the MAC issue cycle");
      end
      #1ps;
      clear_ctrl_inputs();
      ref_en = 1'b0;
      ref_rst_acc = 1'b0;
      ref_cmd_exp2 = 1'b0;
      wait_cycles(3);
      capture_ref_result(prio_expect);

      if (pe_u_word() !== prio_expect) begin
        $fatal(1, "[PRIO] load_reg_li priority mismatch got=%08h exp=%08h", pe_u_word(), prio_expect);
      end
      if (!pe_u_valid || pe_d_valid) begin
        $fatal(1, "[PRIO] lane validity mismatch");
      end

      @(negedge clk);
      drive_idle();
      @(posedge clk);
      #1ps;
      $display(
        "[PRIO-DBG0] commit=%0b wb_q=%0b wb_qq=%0b result_valid=%0b result_acc=%08h result_elem=%08h reg=%08h ref=%08h",
        dut_pe.mac_commit_fire,
        dut_pe.mac_wb_fire_q,
        dut_pe.mac_wb_fire_qq,
        dut_pe.mac_result_valid,
        {dut_pe.mac_result_accType_sign, dut_pe.mac_result_accType_exp, dut_pe.mac_result_accType_mantissa},
        {dut_pe.mac_result_elemType_sign, dut_pe.mac_result_elemType_exp, dut_pe.mac_result_elemType_mantissa},
        pe_reg_word(),
        prio_expect
      );
      @(negedge clk);
      drive_idle();
      @(posedge clk);
      #1ps;
      $display(
        "[PRIO-DBG1] commit=%0b wb_q=%0b wb_qq=%0b result_valid=%0b result_acc=%08h result_elem=%08h reg=%08h ref=%08h",
        dut_pe.mac_commit_fire,
        dut_pe.mac_wb_fire_q,
        dut_pe.mac_wb_fire_qq,
        dut_pe.mac_result_valid,
        {dut_pe.mac_result_accType_sign, dut_pe.mac_result_accType_exp, dut_pe.mac_result_accType_mantissa},
        {dut_pe.mac_result_elemType_sign, dut_pe.mac_result_elemType_exp, dut_pe.mac_result_elemType_mantissa},
        pe_reg_word(),
        prio_expect
      );

      @(negedge clk);
      drive_idle();
      @(posedge clk);
      #1ps;
      if (pe_reg_word() !== prio_expect) begin
        $display(
          "[DBG-PRIO] commit=%0b wb_q=%0b wb_up=%0b wb_exp2=%0b result_valid=%0b result_acc=%08h result_elem=%08h hold=%08h reg=%08h ref=%08h",
          dut_pe.mac_commit_fire,
          dut_pe.mac_wb_fire_q,
          dut_pe.mac_wb_update_reg_q,
          dut_pe.mac_wb_exp2_q,
          dut_pe.mac_result_valid,
          {dut_pe.mac_result_accType_sign, dut_pe.mac_result_accType_exp, dut_pe.mac_result_accType_mantissa},
          {dut_pe.mac_result_elemType_sign, dut_pe.mac_result_elemType_exp, dut_pe.mac_result_elemType_mantissa},
          {dut_pe.mac_wb_result_elemType_sign_q, dut_pe.mac_wb_result_elemType_exp_q, dut_pe.mac_wb_result_elemType_mantissa_q},
          pe_reg_word(),
          prio_expect
        );
      end
      if (pe_reg_word() !== prio_expect) begin
        $fatal(1, "[PRIO] register did not capture MAC result");
      end
      chain_pass++;

      @(negedge clk);
      drive_idle();
      @(posedge clk);
    end
  endtask

  task automatic flow_case(
    input logic [31:0] uw,
    input logic [31:0] dw,
    input logic [31:0] lw,
    input bit flow_lr,
    input bit flow_ud,
    input bit flow_du
  );
    logic [31:0] reg_before;
    begin
      reg_before = pe_reg_word();
      @(negedge clk);
      drive_idle();
      apply_word_to_pe(uw, dw, lw);
      ctrl_flow_lr = flow_lr;
      ctrl_flow_ud = flow_ud;
      ctrl_flow_du = flow_du;
      ctrl_valid = 1'b1;
      @(posedge clk);

      if (pe_out_ctrl_valid !== 1'b1 || pe_out_ctrl_mac !== 1'b0
          || pe_out_ctrl_load_reg_li !== 1'b0 || pe_out_ctrl_load_reg_ui !== 1'b0
          || pe_out_ctrl_flow_lr !== flow_lr || pe_out_ctrl_flow_ud !== flow_ud
          || pe_out_ctrl_flow_du !== flow_du || pe_out_ctrl_update_reg !== 1'b0
          || pe_out_ctrl_exp2 !== 1'b0) begin
        $fatal(1, "[FLOW] control passthrough mismatch");
      end
      if (flow_lr) begin
        if (!pe_r_valid || pe_r_word() !== lw) begin
          $fatal(1, "[FLOW] r_output mismatch got=%08h exp=%08h", pe_r_word(), lw);
        end
      end else if (pe_r_valid) begin
        $fatal(1, "[FLOW] r_output should be idle");
      end
      if (flow_ud) begin
        if (!pe_d_valid || pe_d_word() !== uw) begin
          $fatal(1, "[FLOW] d_output mismatch got=%08h exp=%08h", pe_d_word(), uw);
        end
      end else if (pe_d_valid) begin
        $fatal(1, "[FLOW] d_output should be idle");
      end
      if (flow_du) begin
        if (!pe_u_valid || pe_u_word() !== dw) begin
          $fatal(1, "[FLOW] u_output mismatch got=%08h exp=%08h", pe_u_word(), dw);
        end
      end else if (pe_u_valid) begin
        $fatal(1, "[FLOW] u_output should be idle");
      end
      if (pe_reg_word() !== reg_before) begin
        $fatal(1, "[FLOW] flow transaction should not modify the register");
      end
      if (dut_pe.mac_commit_valid !== 1'b0 || dut_pe.mac_result_valid !== 1'b0) begin
        $fatal(1, "[FLOW] flow transaction should not launch MAC");
      end
      if (dut_pe.exp2Done !== 1'b0) begin
        $fatal(1, "[FLOW] exp2Done should stay cleared");
      end
      flow_pass++;

      @(negedge clk);
      drive_idle();
      @(posedge clk);
    end
  endtask

  task automatic bubble_case();
    logic [31:0] reg_before;
    begin
      reg_before = pe_reg_word();
      @(negedge clk);
      drive_bubble();
      apply_word_to_pe(rand_finite_fp32(), rand_finite_fp32(), rand_finite_fp32());
      ctrl_mac = 1'b1;
      ctrl_flow_lr = 1'b1;
      ctrl_flow_ud = 1'b1;
      ctrl_flow_du = 1'b1;
      ctrl_update_reg = 1'b1;
      ctrl_exp2 = 1'b1;
      @(posedge clk);
      if (pe_out_ctrl_valid !== 1'b0 || pe_u_valid !== 1'b0 || pe_d_valid !== 1'b0 || pe_r_valid !== 1'b0) begin
        $fatal(1, "[BUBBLE] invalid cycle should not emit outputs");
      end
      if (pe_reg_word() !== reg_before) begin
        $fatal(1, "[BUBBLE] invalid cycle should not change register state");
      end
      if (dut_pe.mac_commit_valid !== 1'b0 || dut_pe.mac_result_valid !== 1'b0) begin
        $fatal(1, "[BUBBLE] invalid cycle should not launch MAC");
      end
      bubble_pass++;

      @(negedge clk);
      drive_idle();
      @(posedge clk);
    end
  endtask

  task automatic mac_burst_case(input int burst_len);
    int k;
    int unsigned burst_seed_word;
    logic [31:0] weight;
    logic [31:0] vec;
    logic [31:0] psum;
    logic acc_ui;
    logic [31:0] current_lane_word;
    begin
      weight = rand_finite_fp32();
      load_weight_cycle(weight, 1'b0);
      if (pe_reg_word() !== weight) begin
        $fatal(1, "[BURST] weight load mismatch got=%08h exp=%08h", pe_reg_word(), weight);
      end

    for (k = 0; k < burst_len + 3; k++) begin
        @(negedge clk);
        drive_idle();
        if (k < burst_len) begin
          vec = rand_finite_fp32();
          psum = rand_finite_fp32();
          burst_seed_word = $urandom(seed);
          acc_ui = burst_seed_word[0];
          apply_word_to_pe(acc_ui ? psum : vec, acc_ui ? vec : psum, vec);
          ctrl_mac = 1'b1;
          ctrl_acc_ui = acc_ui;
          ctrl_update_reg = 1'b0;
          ctrl_valid = 1'b1;
          ref_en = 1'b1;
          ref_rst_acc = 1'b1;
          ref_cmd_exp2 = 1'b0;
          ref_weight_in = weight;
          ref_vec_in = vec;
          ref_partial_sum_in = psum;
        end else begin
          drive_bubble();
          ref_en = 1'b1;
          ref_rst_acc = 1'b1;
          ref_cmd_exp2 = 1'b0;
          ref_weight_in = weight;
          ref_vec_in = 32'h0;
          ref_partial_sum_in = 32'h0;
        end
        @(posedge clk);
        #1ps;

        if (k < 3) begin
          if (dut_pe.mac_commit_fire !== 1'b0) begin
            $fatal(1, "[BURST] commit fired too early at cycle %0d", k);
          end
          if (pe_u_valid || pe_d_valid) begin
            $fatal(1, "[BURST] result should stay idle before latency fills");
          end
        end else begin
          if (dut_pe.mac_commit_fire !== 1'b1) begin
            $fatal(1, "[BURST] commit missing at cycle %0d", k);
          end
          if (dut_pe.mac_commit_acc_ui ? !pe_d_valid : !pe_u_valid) begin
            $fatal(1, "[BURST] selected lane not valid at cycle %0d", k);
          end
          if (dut_pe.mac_commit_acc_ui ? pe_u_valid : pe_d_valid) begin
            $fatal(1, "[BURST] non-selected lane should stay idle at cycle %0d", k);
          end
          current_lane_word = dut_pe.mac_commit_acc_ui ? pe_d_word() : pe_u_word();
          if (current_lane_word !== ref_result) begin
            $fatal(
              1,
              "[BURST] mismatch at cycle %0d got=%08h exp=%08h acc_ui=%0b mac_valid=%0b mac_acc=%08h",
              k,
              current_lane_word,
              ref_result,
              dut_pe.mac_commit_acc_ui,
              dut_pe.mac_result_valid,
              {dut_pe.mac_result_accType_sign, dut_pe.mac_result_accType_exp, dut_pe.mac_result_accType_mantissa}
            );
          end
          if (dut_pe.mac_commit_update_reg !== 1'b0 || dut_pe.mac_commit_exp2 !== 1'b0) begin
            $fatal(1, "[BURST] burst should only exercise plain MAC");
          end
        end
      end

      ref_en = 1'b0;
      ref_rst_acc = 1'b0;
      ref_cmd_exp2 = 1'b0;
      burst_pass++;
      @(negedge clk);
      drive_idle();
      @(posedge clk);
    end
  endtask

  task automatic directed_cases();
    begin
      load_only_case(32'h3f800000, 32'h40000000, 1'b0);
      load_only_case(32'h3f800000, 32'h40000000, 1'b1);

      flow_case(32'h3f800000, 32'h40000000, 32'h40400000, 1'b1, 1'b0, 1'b0);
      flow_case(32'h3f800000, 32'h40000000, 32'h40400000, 1'b0, 1'b1, 1'b0);
      flow_case(32'h3f800000, 32'h40000000, 32'h40400000, 1'b0, 1'b0, 1'b1);
      flow_case(32'h3f800000, 32'h40000000, 32'h40400000, 1'b1, 1'b1, 1'b1);

      bubble_case();

      mac_compare_case(32'h3f800000, 32'h40000000, 32'h40400000, 1'b0, 1'b0, 1'b1);
      special_pass++;
      mac_compare_case(32'hbf800000, 32'h40000000, 32'h40400000, 1'b1, 1'b0, 1'b1);
      special_pass++;
      mac_compare_case(32'h00000000, 32'h3f800000, 32'h40000000, 1'b0, 1'b1, 1'b1);
      special_pass++;
      mac_compare_case(32'h3f800000, 32'h40000000, 32'h40400000, 1'b1, 1'b1, 1'b1);
      mac_compare_case(32'h00000000, 32'h3f800000, 32'h40400000, 1'b0, 1'b0, 1'b1);
      mac_compare_case(32'h7f800000, 32'h00000000, 32'h3f800000, 1'b0, 1'b0, 1'b1);
      mac_compare_case(32'h7fc00001, 32'h3f800000, 32'h40000000, 1'b1, 1'b0, 1'b1);

      load_priority_case(32'h3f800000, 32'h40000000, 32'h40400000, 32'h40800000);

      mac_compare_case(32'h3f800000, 32'h40000000, 32'h40400000, 1'b0, 1'b0, 1'b0);
      mac_from_current_reg_case(32'h3f800000, 32'h40000000, 32'h40400000, 1'b0, 1'b0, 1'b0);
      chain_pass++;

      mac_compare_case(32'h3f800000, 32'h40000000, 32'h40400000, 1'b0, 1'b0, 1'b1);
      mac_from_current_reg_case(pe_reg_word(), 32'h40000000, 32'h40400000, 1'b0, 1'b1, 1'b0);
      chain_pass++;

      exp2_case(32'h7f800000, 32'h3f800000, 32'h40000000, 1'b1, 1'b0);
      mac_from_current_reg_case(pe_reg_word(), 32'h40000000, 32'h40400000, 1'b1, 1'b1, 1'b0);
      chain_pass++;
      exp2_case(32'h7fc00001, 32'h3f800000, 32'h40000000, 1'b0, 1'b1);
      special_pass++;
    end
  endtask

  initial begin
    int unsigned seed_word;
    logic rand_acc_ui;
    logic rand_update_reg;
    logic rand_flow_lr;
    logic rand_flow_ud;
    logic rand_flow_du;
    seed_word = $urandom(seed);
    drive_idle();
    wait_cycles(2);
    wait_cycles(2);

    directed_cases();

    mac_burst_case(16);

    repeat (64) begin
      seed_word = $urandom(seed);
      rand_acc_ui = seed_word[0];
      rand_update_reg = seed_word[2];
      mac_compare_case(
        rand_finite_fp32(),
        rand_finite_fp32(),
        rand_finite_fp32(),
        rand_acc_ui,
        seed_word[1],
        rand_update_reg
      );
    end

    repeat (32) begin
      seed_word = $urandom(seed);
      rand_flow_lr = seed_word[0];
      rand_flow_ud = seed_word[1];
      rand_flow_du = seed_word[2];
      if (!(rand_flow_lr || rand_flow_ud || rand_flow_du)) begin
        rand_flow_lr = 1'b1;
      end
      flow_case(
        rand_finite_fp32(),
        rand_finite_fp32(),
        rand_finite_fp32(),
        rand_flow_lr,
        rand_flow_ud,
        rand_flow_du
      );
    end

    $display(
      "[TB] PASS load=%0d mac=%0d chain=%0d flow=%0d exp2=%0d burst=%0d bubble=%0d special=%0d",
      load_pass,
      mac_pass,
      chain_pass,
      flow_pass,
      exp2_pass,
      burst_pass,
      bubble_pass,
      special_pass
    );
    $finish;
  end

endmodule

module fp_mac_pipelined_acc_ref(
  input         clk,
  input         rstn,
  input         en,
  input         rst_acc,
  input         cmd_exp2,
  input  [31:0] weight_in,
  input  [31:0] vec_in,
  input  [31:0] partial_sum_in,
  output logic [31:0] vec_out,
  output logic [31:0] result
);
  wire        core_valid;
  wire        core_sign;
  wire [7:0]  core_exp;
  wire [22:0] core_man;
  wire        core_elem_sign;
  wire [7:0]  core_elem_exp;
  wire [22:0] core_elem_man;
  wire        core_exp2;
  wire [31:0] core_acc_word = {core_sign, core_exp, core_man};
  logic [31:0] result_q;
  logic [31:0] vec_q;

  FPMacUnit core (
    .clock(clk),
    .io_in_valid(en),
    .io_in_a_sign(weight_in[31]),
    .io_in_a_exp(weight_in[30:23]),
    .io_in_a_mantissa(weight_in[22:0]),
    .io_in_b_sign(vec_in[31]),
    .io_in_b_exp(vec_in[30:23]),
    .io_in_b_mantissa(vec_in[22:0]),
    .io_in_c_sign(partial_sum_in[31]),
    .io_in_c_exp(partial_sum_in[30:23]),
    .io_in_c_mantissa(partial_sum_in[22:0]),
    .io_in_cmd(cmd_exp2),
    .io_out_valid(core_valid),
    .io_out_accType_sign(core_sign),
    .io_out_accType_exp(core_exp),
    .io_out_accType_mantissa(core_man),
    .io_out_elemType_sign(core_elem_sign),
    .io_out_elemType_exp(core_elem_exp),
    .io_out_elemType_mantissa(core_elem_man),
    .io_out_exp2(core_exp2)
  );

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      result_q <= 32'h0000_0000;
      vec_q <= 32'h0000_0000;
    end else begin
      if (core_valid) begin
        result_q <= core_acc_word;
      end
      if (en) begin
        vec_q <= vec_in;
      end
    end
  end

  assign vec_out = vec_q;
  assign result = core_valid ? core_acc_word : result_q;

endmodule

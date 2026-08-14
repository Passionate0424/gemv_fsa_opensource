// CB_top_v2 基础虚拟Sequence
// 所有具体test sequence的基类，提供CSR读写和等待完成的公共方法
class cb_top_base_seq extends uvm_sequence;

  `uvm_object_utils(cb_top_base_seq)
  `uvm_declare_p_sequencer(cb_top_virtual_seqr)

  function new(string name = "cb_top_base_seq");
    super.new(name);
  endfunction

  // CSR写操作
  task csr_write(input logic [31:0] addr, input logic [31:0] data);
    axi_slv_seq_item item = axi_slv_seq_item::type_id::create("wr_item");
    item.constraint_mode(0);
    start_item(item, -1, p_sequencer.axi_slv_sqr);
    item.rw    = axi_slv_seq_item::AXI_WRITE;
    item.addr  = addr;
    item.wdata = data;
    finish_item(item);
  endtask

  // CSR读操作
  task csr_read(input logic [31:0] addr, output logic [31:0] data);
    axi_slv_seq_item item = axi_slv_seq_item::type_id::create("rd_item");
    item.constraint_mode(0);
    start_item(item, -1, p_sequencer.axi_slv_sqr);
    item.rw   = axi_slv_seq_item::AXI_READ;
    item.addr = addr;
    finish_item(item);
    data = item.rdata;
  endtask

  // 轮询STATUS寄存器等待done（每次CSR读本身消耗若干周期作为间隔）
  task wait_done(input int timeout_cycles = 200000);
    logic [31:0] status;
    int poll_count = timeout_cycles / 10;
    for (int i = 0; i < poll_count; i++) begin
      csr_read(32'h0004, status);
      if (status[1]) return;
    end
    `uvm_error("TIMEOUT", $sformatf("等待done超时: %0d polls", poll_count))
  endtask

  // DDR写入单字（通过mem_model backdoor）
  function void ddr_write(input int unsigned byte_addr, input logic [31:0] data);
    p_sequencer.mem.write_word(byte_addr, data);
  endfunction

  // DDR读取单字
  function logic [31:0] ddr_read(input int unsigned byte_addr);
    return p_sequencer.mem.read_word(byte_addr);
  endfunction

  // 硬件复位（与现有directed TB行为一致：rst_n拉低5拍→拉高→等5拍稳定）
  task hw_reset();
    uvm_hdl_deposit("tb_top.rst_n", 0);
    #100;  // 5 clk cycles @ 20ns
    uvm_hdl_deposit("tb_top.rst_n", 1);
    #100;  // 等待稳定
  endtask

  // PRNG（LCG，与现有TB一致）— 公共方法，子类复用
  function automatic logic [31:0] rand_fp32(ref int unsigned state, input real range);
    real val;
    state = state * 32'd1664525 + 32'd1013904223;
    val = ($itor($signed(state)) / 2147483648.0) * range;
    return $shortrealtobits(shortreal'(val));
  endfunction

  // ============================================================
  // 硬件位精确FP32原语：照抄rtl/fpmul_seq_pipeline.sv和rtl/fpadd_seq.sv
  // 的比特操作（纯截断，无round-to-nearest），不是IEEE标准舍入的
  // shortreal运算。GEMV的OS模式累加器用"超前计算"(look-ahead)实现，
  // 求和顺序与朴素顺序累加不同，FP32不满足结合律，只有严格复现硬件的
  // 截断算术+超前递归顺序，golden才能与DUT逐bit对齐（详见worklog）
  // ============================================================

  // 硬件FP32乘法器：对应fpmul_seq_pipeline.sv，尾数乘积取[45:23]截断
  function automatic logic [31:0] hw_fp_mul(logic [31:0] A, logic [31:0] B);
    logic a_sign, b_sign;
    logic [7:0] a_exp_raw, b_exp_raw;
    logic [22:0] a_frac, b_frac;
    logic is_nan, is_inf, is_zero, sign;
    logic [7:0] a_e, b_e;
    logic [23:0] a_m, b_m;
    logic [47:0] product;
    logic signed [9:0] exp_sum;
    logic prod_overflow;
    logic [47:0] shifted_product;
    logic signed [9:0] shifted_exp;
    logic need_norm;
    logic [47:0] final_product;
    logic signed [9:0] final_exp;

    a_sign = A[31]; b_sign = B[31];
    a_exp_raw = A[30:23]; b_exp_raw = B[30:23];
    a_frac = A[22:0]; b_frac = B[22:0];

    is_nan  = (a_exp_raw==8'hFF && a_frac!=0) || (b_exp_raw==8'hFF && b_frac!=0);
    is_inf  = (a_exp_raw==8'hFF) || (b_exp_raw==8'hFF);
    is_zero = (a_exp_raw==8'h0 && a_frac==0) || (b_exp_raw==8'h0 && b_frac==0);
    sign    = a_sign ^ b_sign;

    a_e = (a_exp_raw==8'h0) ? 8'd1 : a_exp_raw;
    b_e = (b_exp_raw==8'h0) ? 8'd1 : b_exp_raw;
    a_m = (a_exp_raw==8'h0) ? {1'b0,a_frac} : {1'b1,a_frac};
    b_m = (b_exp_raw==8'h0) ? {1'b0,b_frac} : {1'b1,b_frac};

    product = a_m * b_m;
    exp_sum = {2'b0,a_e} + {2'b0,b_e} - 10'sd127;

    if (is_nan)  return 32'h7FC00000;
    if (is_inf)  return {sign, 8'hFF, 23'd0};
    if (is_zero) return {sign, 31'd0};

    prod_overflow = product[47];
    if (prod_overflow) begin
      shifted_product = product >> 1;
      shifted_exp = exp_sum + 10'sd1;
    end else begin
      shifted_product = product;
      shifted_exp = exp_sum;
    end

    need_norm = (!prod_overflow) && (!product[46]) && (exp_sum > 0);
    if (need_norm) begin
      // multiplication_normaliser的LZD左移，与RTL的if-elif优先级一致
      if (product[46:41]==6'b000001) begin
        final_exp = exp_sum - 10'sd5; final_product = product << 5;
      end else if (product[46:42]==5'b00001) begin
        final_exp = exp_sum - 10'sd4; final_product = product << 4;
      end else if (product[46:43]==4'b0001) begin
        final_exp = exp_sum - 10'sd3; final_product = product << 3;
      end else if (product[46:44]==3'b001) begin
        final_exp = exp_sum - 10'sd2; final_product = product << 2;
      end else if (product[46:45]==2'b01) begin
        final_exp = exp_sum - 10'sd1; final_product = product << 1;
      end else begin
        final_exp = exp_sum; final_product = product;
      end
    end else begin
      final_product = shifted_product;
      final_exp = shifted_exp;
    end

    if (final_exp <= 0)   return {sign, 31'd0};
    if (final_exp >= 255) return {sign, 8'hFF, 23'd0};
    return {sign, final_exp[7:0], final_product[45:23]};
  endfunction

  // 硬件FP32加法器：对应fpadd_seq_2stage.sv的Stage1对阶/尾数加减
  // + addition_normaliser的LZD左移归一化（纯截断，无舍入）
  function automatic logic [31:0] hw_fp_add(logic [31:0] A, logic [31:0] B);
    logic a_sign, b_sign;
    logic [7:0] a_exp_raw, b_exp_raw;
    logic [22:0] a_frac, b_frac;
    logic a_is_nan, b_is_nan, a_is_zero, b_is_zero, a_is_inf, b_is_inf;
    logic [7:0] a_e, b_e;
    logic [23:0] a_m, b_m;
    logic o_sign;
    logic [7:0] o_exp;
    logic [24:0] o_man;
    logic [7:0] diff;
    logic [23:0] tmp_man;
    logic is_zero_r, overflow, normalized;
    logic [7:0] ne;
    logic [24:0] nm;

    a_sign = A[31]; b_sign = B[31];
    a_exp_raw = A[30:23]; b_exp_raw = B[30:23];
    a_frac = A[22:0]; b_frac = B[22:0];

    a_is_nan  = (a_exp_raw==8'hFF) && (a_frac!=0);
    b_is_nan  = (b_exp_raw==8'hFF) && (b_frac!=0);
    a_is_zero = (a_exp_raw==8'h0) && (a_frac==0);
    b_is_zero = (b_exp_raw==8'h0) && (b_frac==0);
    a_is_inf  = (a_exp_raw==8'hFF) && (a_frac==0);
    b_is_inf  = (b_exp_raw==8'hFF) && (b_frac==0);

    if (a_is_nan || (b_is_zero && !b_is_nan)) return A;
    if (b_is_nan || (a_is_zero && !a_is_nan)) return B;
    if (a_is_inf || b_is_inf) return {a_sign^b_sign, 8'hFF, 23'd0};

    a_e = (a_exp_raw==8'h0) ? 8'd1 : a_exp_raw;
    b_e = (b_exp_raw==8'h0) ? 8'd1 : b_exp_raw;
    a_m = (a_exp_raw==8'h0) ? {1'b0,a_frac} : {1'b1,a_frac};
    b_m = (b_exp_raw==8'h0) ? {1'b0,b_frac} : {1'b1,b_frac};

    if (a_e == b_e) begin
      o_exp = a_e;
      if (a_sign == b_sign) begin
        o_man = {1'b0,a_m} + {1'b0,b_m};
        o_sign = a_sign;
      end else begin
        if (a_m > b_m) begin o_man = {1'b0,a_m} - {1'b0,b_m}; o_sign = a_sign; end
        else            begin o_man = {1'b0,b_m} - {1'b0,a_m}; o_sign = b_sign; end
      end
    end else if (a_e > b_e) begin
      o_exp = a_e; o_sign = a_sign;
      diff = a_e - b_e;
      tmp_man = b_m >> diff;
      o_man = (a_sign==b_sign) ? ({1'b0,a_m}+{1'b0,tmp_man}) : ({1'b0,a_m}-{1'b0,tmp_man});
    end else begin
      o_exp = b_e; o_sign = b_sign;
      diff = b_e - a_e;
      tmp_man = a_m >> diff;
      o_man = (a_sign==b_sign) ? ({1'b0,b_m}+{1'b0,tmp_man}) : ({1'b0,b_m}-{1'b0,tmp_man});
    end

    is_zero_r = (o_man == 25'd0);
    overflow  = o_man[24];
    if (is_zero_r) begin
      o_sign = 1'b0; o_exp = 8'd0;
    end else if (overflow) begin
      o_exp = o_exp + 8'd1;
      o_man = o_man >> 1;
    end

    normalized = o_man[23] || overflow || is_zero_r;

    if (is_zero_r)  return 32'd0;
    if (normalized) return {o_sign, o_exp, o_man[22:0]};

    if (o_exp != 8'd0) begin
      // addition_normaliser的LZD左移，与RTL的if-elif优先级一致
      if      (o_man[23:3] ==21'b0000000000000000_00001) begin ne=o_exp-20; nm=o_man<<20; end
      else if (o_man[23:4] ==20'b000000000000000_00001)  begin ne=o_exp-19; nm=o_man<<19; end
      else if (o_man[23:5] ==19'b00000000000000_00001)   begin ne=o_exp-18; nm=o_man<<18; end
      else if (o_man[23:6] ==18'b0000000000000_00001)    begin ne=o_exp-17; nm=o_man<<17; end
      else if (o_man[23:7] ==17'b000000000000_00001)     begin ne=o_exp-16; nm=o_man<<16; end
      else if (o_man[23:8] ==16'b00000000000_00001)      begin ne=o_exp-15; nm=o_man<<15; end
      else if (o_man[23:9] ==15'b0000000000_00001)       begin ne=o_exp-14; nm=o_man<<14; end
      else if (o_man[23:10]==14'b000000000_00001)        begin ne=o_exp-13; nm=o_man<<13; end
      else if (o_man[23:11]==13'b00000000_00001)         begin ne=o_exp-12; nm=o_man<<12; end
      else if (o_man[23:12]==12'b0000000_00001)          begin ne=o_exp-11; nm=o_man<<11; end
      else if (o_man[23:13]==11'b000000_00001)           begin ne=o_exp-10; nm=o_man<<10; end
      else if (o_man[23:14]==10'b00000_00001)            begin ne=o_exp-9;  nm=o_man<<9;  end
      else if (o_man[23:15]==9'b0000_00001)              begin ne=o_exp-8;  nm=o_man<<8;  end
      else if (o_man[23:16]==8'b000_00001)               begin ne=o_exp-7;  nm=o_man<<7;  end
      else if (o_man[23:17]==7'b00_00001)                begin ne=o_exp-6;  nm=o_man<<6;  end
      else if (o_man[23:18]==6'b0_00001)                 begin ne=o_exp-5;  nm=o_man<<5;  end
      else if (o_man[23:19]==5'b00001)                   begin ne=o_exp-4;  nm=o_man<<4;  end
      else if (o_man[23:20]==4'b0001)                    begin ne=o_exp-3;  nm=o_man<<3;  end
      else if (o_man[23:21]==3'b001)                     begin ne=o_exp-2;  nm=o_man<<2;  end
      else if (o_man[23:22]==2'b01)                      begin ne=o_exp-1;  nm=o_man<<1;  end
      else begin ne=o_exp; nm=o_man; end

      if (ne == 8'd0 || ne > o_exp) return 32'd0;
      return {o_sign, ne, nm[22:0]};
    end
    return {o_sign, o_exp, o_man[22:0]};
  endfunction

  // GEMV软件黄金模型：位精确复现硬件OS模式累加器的"超前计算"(look-ahead)
  // 求和顺序 —— 环外两两滑动窗口预加(s[n]=x[n-1]+x[n]) + 环内隔2拍交织
  // 递归(y[n]=y[n-2]+s[n])，边界处最后一项因fp_pre_add的mul_out_d比
  // mul_out晚1拍清零而被单独再吸收一次，最终取y[HW_COLS_TILE]。
  // FP32不满足结合律，这个求和顺序与朴素顺序累加会有几个ULP差异，
  // 只有严格复现才能与DUT逐bit对齐（详见worklog中round=7的定位过程）。
  //
  // cols>HW_COLS_TILE时（cb_controll_v2.sv的HW_COLS=64），硬件按64列一块
  // 分tile处理，块间通过acc_en/partial_sum_in把上一块的结果作为下一块
  // y[-2]/y[-1]的种子（load_init同时装载R1和R2），不是从0重新开始。
  // 单tile(cols<=64)部分已用实测硬件波形逐bit验证；多tile的块间进位部分
  // 是按cb_controll_v2.sv的S_ACCUMULATE/acc_en结构推导，未有实测波形验证，
  // 如后续多tile(cols>64)用例比对异常需回头补验证。
  //
  // 公共方法，凡是需要验证GEMV数值正确性的sequence统一调用这一份。
  function automatic void compute_gemv_golden(
    input  logic [31:0] matrix [],
    input  logic [31:0] vector [],
    input  int rows,
    input  int cols,
    output logic [31:0] golden []
  );
    int HW_COLS_TILE;
    int ARRAY_SIZE;
    HW_COLS_TILE = 64;   // 与cb_controll_v2.sv的HW_COLS一致；函数体内不能用localparam(VCS语法限制)
    ARRAY_SIZE = 32;     // PE阵列宽度(cb_controll_v2.sv的HW_ROWS)
    golden = new[rows];
    for (int r = 0; r < rows; r++) begin
      logic [31:0] seed;
      int col_off;
      int cap_off;
      // 超前计算把累加拆成奇/偶两条交织链，硬件在固定的RESULT_CAPTURE_CYCLE
      // 捕获其中一条；捕获哪条由该行对应的PE索引(r % ARRAY_SIZE)的奇偶性决定
      // ——每个PE[gi]的weight有gi级skew延迟，把它完成累加的时刻相对全局捕获
      // 时刻移了gi拍，于是偶PE捕获y[tile_cols]、奇PE捕获y[tile_cols-1]。两条链
      // 只差1~2 ULP，平时被0.1%阈值放过，只有严重抵消的行(如bigrow的row153)
      // 才把它放大成可见误差。cap_off=1时取y[tile_cols-1]，否则取y[tile_cols]。
      cap_off = (r % ARRAY_SIZE) % 2;
      seed = 32'd0;
      col_off = 0;
      while (col_off < cols) begin
        int tile_cols;
        logic [31:0] x [];
        logic [31:0] y_prev2, y_prev1, y_cur, s;
        tile_cols = ((cols - col_off) < HW_COLS_TILE) ? (cols - col_off) : HW_COLS_TILE;
        x = new[tile_cols];
        for (int c = 0; c < tile_cols; c++)
          x[c] = hw_fp_mul(matrix[r*cols + col_off + c], vector[col_off + c]);

        y_prev2 = seed;  // y[-2]：首块为0，后续块为上一块的结果
        y_prev1 = seed;  // y[-1]：load_init同时装载R1和R2，两者种子相同
        for (int n = 0; n <= tile_cols; n++) begin
          if (n == tile_cols)
            s = x[tile_cols-1];                  // 边界：最后一项单独再吸收一次
          else if (n == 0)
            s = x[0];                             // 边界：x[-1]视为0（本块起点）
          else
            s = hw_fp_add(x[n-1], x[n]);
          y_cur = hw_fp_add(y_prev2, s);
          y_prev2 = y_prev1;   // 循环结束后 y_prev2=y[tile_cols-1]
          y_prev1 = y_cur;     // 循环结束后 y_prev1=y[tile_cols]
        end
        // 按PE奇偶捕获对应的交织链：偶取y[tile_cols]，奇取y[tile_cols-1]
        seed = (cap_off == 0) ? y_prev1 : y_prev2;
        col_off += tile_cols;
      end
      golden[r] = seed;
    end
  endfunction

  // GEMV输出比对：相对误差容差0.1%（与gemv_base_seq判定阈值一致），返回错误个数
  function automatic int compare_gemv_output(
    input logic [31:0] dut_out [],
    input logic [31:0] golden [],
    input int rows,
    input string label = "GEMV_CMP"
  );
    int errs = 0;
    for (int i = 0; i < rows; i++) begin
      shortreal dut_f = $bitstoshortreal(dut_out[i]);
      shortreal gld_f = $bitstoshortreal(golden[i]);
      real abs_err = (dut_f - gld_f) < 0 ? -(dut_f - gld_f) : (dut_f - gld_f);
      real denom = (gld_f < 0 ? -gld_f : gld_f) > 1e-6 ? (gld_f < 0 ? -gld_f : gld_f) : 1e-6;
      real rel_err = abs_err / denom;
      if (rel_err > 0.001) begin
        errs++;
        `uvm_error(label, $sformatf("row[%0d]: DUT=0x%08h, Golden=0x%08h, rel_err=%.4f%%",
                   i, dut_out[i], golden[i], rel_err*100.0))
      end
    end
    return errs;
  endfunction

endclass

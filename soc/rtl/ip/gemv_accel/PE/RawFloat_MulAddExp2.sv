`timescale 1ns / 1ps

module RawFloat_MulAddExp2_pipe(
  input         clock,
  input         rst_n,
  input         io_in_valid,
  input         io_in_exp2,
  input         io_in_a_isZero,
                io_in_a_isInf,
                io_in_a_isNaN,
                io_in_a_sign,
  input  [8:0]  io_in_a_exp,
  input  [23:0] io_in_a_mantissa,
  input         io_in_b_isZero,
                io_in_b_isInf,
                io_in_b_isNaN,
                io_in_b_sign,
  input  [8:0]  io_in_b_exp,
  input  [23:0] io_in_b_mantissa,
  input         io_in_c_isZero,
                io_in_c_isInf,
                io_in_c_isNaN,
                io_in_c_sign,
  input  [8:0]  io_in_c_exp,
  input  [23:0] io_in_c_mantissa,
  // 超前计算透传端口
  input         bypass_s1,
  input         use_pre_add,
  input  [31:0] pre_add_in,
  input  [31:0] init_val,
  input         load_init,
  output [31:0] mul_out_port,
  // 原有输出
  output        io_out_valid,
  output        io_out_isZero,
                io_out_isInf,
                io_out_isNaN,
                io_out_sign,
  output [10:0] io_out_exp,
  output [25:0] io_out_mantissa,
  output [2:0]  io_exp2_frac_msb
);

  wire [8:0]  split_io_outInt;
  wire [2:0]  split_io_outFracMSBs;
  wire        split_io_outRawFloat_isZero;
  wire        split_io_outRawFloat_isInf;
  wire        split_io_outRawFloat_isNaN;
  wire        split_io_outRawFloat_sign;
  wire [8:0]  split_io_outRawFloat_exp;
  wire [23:0] split_io_outRawFloat_mantissa;
  wire        fma_io_out_valid;
  wire        fma_io_out_isZero;
  wire        fma_io_out_isInf;
  wire        fma_io_out_isNaN;
  wire        fma_io_out_sign;
  wire [10:0] fma_io_out_exp;
  wire [25:0] fma_io_out_mantissa;

  // exp2辅助信号延迟链（OS模式4级，FSA模式3级）
  reg  [8:0]  split_int_pipe [0:3];
  reg  [2:0]  split_frac_pipe [0:3];
  reg         exp2_pipe [0:3];

  // exp2模式下SplitIF输出isInf表示|x|超出范围，exp2(x)应为0
  wire exp2_overflow = io_in_exp2 & split_io_outRawFloat_isInf;

  RawFloat_FMA_LA_pipe fma (
    .clock           (clock),
    .rst_n           (rst_n),
    .io_in_valid     (io_in_valid),
    .io_a_isZero     (io_in_exp2 ? (split_io_outRawFloat_isZero | exp2_overflow) : io_in_a_isZero),
    .io_a_isInf      (io_in_exp2 ? 1'b0 : io_in_a_isInf),
    .io_a_isNaN      (io_in_exp2 ? split_io_outRawFloat_isNaN : io_in_a_isNaN),
    .io_a_sign       (io_in_exp2 ? split_io_outRawFloat_sign : io_in_a_sign),
    .io_a_exp        (io_in_exp2 ? split_io_outRawFloat_exp : io_in_a_exp),
    .io_a_mantissa   (io_in_exp2 ? split_io_outRawFloat_mantissa : io_in_a_mantissa),
    .io_b_isZero     (io_in_b_isZero),
    .io_b_isInf      (io_in_b_isInf),
    .io_b_isNaN      (io_in_b_isNaN),
    .io_b_sign       (io_in_b_sign),
    .io_b_exp        (io_in_b_exp),
    .io_b_mantissa   (io_in_b_mantissa),
    .io_c_isZero     (exp2_overflow ? 1'b1 : io_in_c_isZero),
    .io_c_isInf      (io_in_c_isInf),
    .io_c_isNaN      (io_in_c_isNaN),
    .io_c_sign       (io_in_c_sign),
    .io_c_exp        (io_in_c_exp),
    .io_c_mantissa   (io_in_c_mantissa),
    // 超前计算端口
    .bypass_s1       (bypass_s1),
    .use_pre_add     (use_pre_add),
    .pre_add_in      (pre_add_in),
    .init_val        (init_val),
    .load_init       (load_init),
    .mul_out_port    (mul_out_port),
    // 输出
    .io_out_valid    (fma_io_out_valid),
    .io_out_isZero   (fma_io_out_isZero),
    .io_out_isInf    (fma_io_out_isInf),
    .io_out_isNaN    (fma_io_out_isNaN),
    .io_out_sign     (fma_io_out_sign),
    .io_out_exp      (fma_io_out_exp),
    .io_out_mantissa (fma_io_out_mantissa)
  );

  RawFloat_SplitIF split (
    .io_in_isZero            (io_in_a_isZero),
    .io_in_isInf             (io_in_a_isInf),
    .io_in_isNaN             (io_in_a_isNaN),
    .io_in_sign              (io_in_a_sign),
    .io_in_exp               (io_in_a_exp),
    .io_in_mantissa          (io_in_a_mantissa),
    .io_outInt               (split_io_outInt),
    .io_outFracMSBs          (split_io_outFracMSBs),
    .io_outRawFloat_isZero   (split_io_outRawFloat_isZero),
    .io_outRawFloat_isInf    (split_io_outRawFloat_isInf),
    .io_outRawFloat_isNaN    (split_io_outRawFloat_isNaN),
    .io_outRawFloat_sign     (split_io_outRawFloat_sign),
    .io_outRawFloat_exp      (split_io_outRawFloat_exp),
    .io_outRawFloat_mantissa (split_io_outRawFloat_mantissa)
  );

  // 输出选择：根据bypass_s1选择对应延迟级的辅助信号
  wire [2:0] pipe_idx = bypass_s1 ? 2 : 3;

  assign io_out_valid = fma_io_out_valid;
  assign io_out_isZero = exp2_pipe[pipe_idx] ? fma_io_out_isInf : fma_io_out_isZero;
  assign io_out_isInf = ~exp2_pipe[pipe_idx] & fma_io_out_isInf;
  assign io_out_isNaN = fma_io_out_isNaN;
  assign io_out_sign = ~exp2_pipe[pipe_idx] & fma_io_out_sign;
  assign io_out_exp = exp2_pipe[pipe_idx]
    ? {{2{split_int_pipe[pipe_idx][8]}}, split_int_pipe[pipe_idx]} + fma_io_out_exp
    : fma_io_out_exp;
  assign io_out_mantissa = fma_io_out_mantissa;
  assign io_exp2_frac_msb = split_frac_pipe[pipe_idx];

  integer i;
  always @(posedge clock) begin
    if (!rst_n) begin
      for (i = 0; i < 4; i = i + 1) begin
        exp2_pipe[i] <= 1'b0;
        split_int_pipe[i] <= 9'h0;
        split_frac_pipe[i] <= 3'h0;
      end
    end else begin
      exp2_pipe[0] <= io_in_valid & io_in_exp2;
      split_int_pipe[0] <= split_io_outInt;
      split_frac_pipe[0] <= split_io_outFracMSBs;
      for (i = 1; i < 4; i = i + 1) begin
        exp2_pipe[i] <= exp2_pipe[i-1];
        split_int_pipe[i] <= split_int_pipe[i-1];
        split_frac_pipe[i] <= split_frac_pipe[i-1];
      end
    end
  end

endmodule

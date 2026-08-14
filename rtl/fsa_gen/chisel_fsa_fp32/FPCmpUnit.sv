// FPCmpUnit - 分离比较器和减法器
// 快速比较器（~4ns）用于max反馈环路，generalAdder用于diff前向路径
module FPCmpUnit(
  input         io_in_a_sign,
  input  [7:0]  io_in_a_exp,
  input  [22:0] io_in_a_mantissa,
  input         io_in_b_sign,
  input  [7:0]  io_in_b_exp,
  input  [22:0] io_in_b_mantissa,
  output        io_out_max_sign,
  output [7:0]  io_out_max_exp,
  output [22:0] io_out_max_mantissa,
  output        io_out_diff_sign,
  output [7:0]  io_out_diff_exp,
  output [22:0] io_out_diff_mantissa
);

  wire [31:0] a_word = {io_in_a_sign, io_in_a_exp, io_in_a_mantissa};
  wire [31:0] b_word = {io_in_b_sign, io_in_b_exp, io_in_b_mantissa};

  // 快速比较器：判断 a >= b（用于max选择，~4ns）
  wire a_ge_b;
  fp32_comparator u_cmp (
    .a      (a_word),
    .b      (b_word),
    .a_ge_b (a_ge_b)
  );

  // max输出：比较器直接选择（快速路径，反馈环路用）
  assign io_out_max_sign     = a_ge_b ? io_in_a_sign     : io_in_b_sign;
  assign io_out_max_exp      = a_ge_b ? io_in_a_exp      : io_in_b_exp;
  assign io_out_max_mantissa = a_ge_b ? io_in_a_mantissa : io_in_b_mantissa;

  // diff输出：generalAdder减法（慢速路径，前向到cmp_d_output_r）
  // a - b = a + (-b)
  wire [31:0] sub_out;
  generalAdder u_sub (
    .a   (a_word),
    .b   ({~io_in_b_sign, io_in_b_exp, io_in_b_mantissa}),
    .out (sub_out)
  );

  assign io_out_diff_sign     = sub_out[31];
  assign io_out_diff_exp      = sub_out[30:23];
  assign io_out_diff_mantissa = sub_out[22:0];

endmodule

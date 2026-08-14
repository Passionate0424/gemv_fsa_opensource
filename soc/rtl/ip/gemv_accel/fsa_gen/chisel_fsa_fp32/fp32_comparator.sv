`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////
// fp32_comparator - 快速FP32大小比较器（纯组合）
//
// 判断 a >= b，不做减法运算。
// 延迟: ~4ns（符号+指数+尾数级联比较）
// 用于CMP模块的max tracking反馈环路，替代generalAdder。
//////////////////////////////////////////////////////////////

module fp32_comparator(
    input  [31:0] a,
    input  [31:0] b,
    output        a_ge_b   // 1: a >= b, 0: a < b
);

    wire a_sign = a[31];
    wire b_sign = b[31];
    wire [7:0] a_exp = a[30:23];
    wire [7:0] b_exp = b[30:23];
    wire [22:0] a_man = a[22:0];
    wire [22:0] b_man = b[22:0];

    // 零值特殊处理（+0 == -0）
    wire a_is_zero = (a[30:0] == 31'h0);
    wire b_is_zero = (b[30:0] == 31'h0);

    // 无符号幅值比较（exp优先，exp相等比man）
    wire a_mag_gt_b = (a_exp > b_exp) || (a_exp == b_exp && a_man > b_man);
    wire a_mag_eq_b = (a_exp == b_exp) && (a_man == b_man);
    wire a_mag_ge_b = a_mag_gt_b | a_mag_eq_b;

    // FP32大小比较
    // 规则：正数 > 负数；同为正数幅值大的大；同为负数幅值小的大
    assign a_ge_b =
        (a_is_zero && b_is_zero) ? 1'b1 :           // +0 == -0
        (!a_sign && b_sign) ? 1'b1 :                 // a正 b负
        (a_sign && !b_sign) ? 1'b0 :                 // a负 b正
        (!a_sign && !b_sign) ? a_mag_ge_b :          // 都正: 幅值大的大
        (a_sign && b_sign) ? !a_mag_gt_b : 1'b0;    // 都负: 幅值小的大(>=)

endmodule

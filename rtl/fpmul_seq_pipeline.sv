`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////
// FP32 Pipelined Multiplier (2-Stage, 正确切分)
//
// Pipeline Stages:
// - Stage 0 (组合): 输入解包 + 24×24尾数乘法(DSP48) + 指数求和
// - Stage 1 (寄存器): 打拍 product/exp_sum/sign/special flags
// - Stage 1→O (组合+寄存器): 归一化 + 溢出检测 + special case → O
//
// 切分依据: DSP48乘法是路径中最大延迟源(~5.4ns)，
//   将其与后续归一化(multiplication_normaliser)分到两拍，
//   平衡每级组合逻辑深度。
//
// Total Latency: 2 clock cycles (与原设计一致).
////////////////////////////////////////////////////////////////

module fpmul_seq_pipeline(
    input clk,
    input rst_n,
    input [31:0] A,
    input [31:0] B,
    output reg [31:0] O
);

    // ================================================================
    // Stage 0: 输入解包 + 尾数乘法 + 指数求和 (组合逻辑)
    // ================================================================
    wire a_sign = A[31];
    wire b_sign = B[31];
    wire [7:0] a_exp_raw = A[30:23];
    wire [7:0] b_exp_raw = B[30:23];
    wire [22:0] a_frac = A[22:0];
    wire [22:0] b_frac = B[22:0];

    // subnormal处理
    wire [7:0] a_exponent = (a_exp_raw == 0) ? 8'd1 : a_exp_raw;
    wire [7:0] b_exponent = (b_exp_raw == 0) ? 8'd1 : b_exp_raw;
    wire [23:0] a_mantissa = (a_exp_raw == 0) ? {1'b0, a_frac} : {1'b1, a_frac};
    wire [23:0] b_mantissa = (b_exp_raw == 0) ? {1'b0, b_frac} : {1'b1, b_frac};

    // 尾数乘法 (映射到DSP48)
    wire [47:0] product_raw = a_mantissa * b_mantissa;

    // 指数求和
    wire signed [9:0] exp_sum_raw = {2'b0, a_exponent} + {2'b0, b_exponent} - 10'sd127;

    // special case 检测
    wire is_nan = (a_exp_raw == 8'hFF && a_frac != 0) ||
                  (b_exp_raw == 8'hFF && b_frac != 0);
    wire is_inf = (a_exp_raw == 8'hFF || b_exp_raw == 8'hFF);
    wire is_zero = (a_exp_raw == 0 && a_frac == 0) ||
                   (b_exp_raw == 0 && b_frac == 0);
    wire sign_xor = a_sign ^ b_sign;

    // ================================================================
    // Stage 0 → Stage 1 寄存器 (DSP48输出后切分)
    // ================================================================
    reg [47:0] s1_product;
    reg signed [9:0] s1_exp_sum;
    reg s1_sign;
    reg s1_is_nan, s1_is_inf, s1_is_zero;

    always @(posedge clk) begin
        if (!rst_n) begin
            s1_product <= 48'd0;
            s1_exp_sum <= 10'sd0;
            s1_sign    <= 1'b0;
            s1_is_nan  <= 1'b0;
            s1_is_inf  <= 1'b0;
            s1_is_zero <= 1'b0;
        end else begin
            s1_product <= product_raw;
            s1_exp_sum <= exp_sum_raw;
            s1_sign    <= sign_xor;
            s1_is_nan  <= is_nan;
            s1_is_inf  <= is_inf;
            s1_is_zero <= is_zero;
        end
    end

    // ================================================================
    // Stage 1 → O: 归一化 + 溢出检测 + special case (组合→寄存器)
    // ================================================================
    // 归一化: product[47]为1时右移，否则用normaliser左移
    // product[47]==1: 乘积溢出，右移1位，指数+1
    wire prod_overflow = s1_product[47];

    wire [47:0] shifted_product = prod_overflow ? (s1_product >> 1) : s1_product;
    wire signed [9:0] shifted_exp = prod_overflow ? (s1_exp_sum + 1) : s1_exp_sum;

    // product[46]==0 且 exp>0: 需要左移归一化
    wire need_norm = !prod_overflow && !s1_product[46] && (s1_exp_sum > 0);

    wire [7:0] norm_out_e;
    wire [47:0] norm_out_m;
    multiplication_normaliser norm1 (
        .in_e (s1_exp_sum[7:0]),
        .in_m (s1_product),
        .out_e(norm_out_e),
        .out_m(norm_out_m)
    );

    wire [47:0] final_product = need_norm ? norm_out_m : shifted_product;
    wire signed [9:0] final_exp = need_norm ? {2'b0, norm_out_e} : shifted_exp;

    // 溢出/下溢检测 + 最终结果组装
    reg [31:0] s2_result;
    always @(*) begin
        if (s1_is_nan)
            s2_result = 32'h7FC00000;
        else if (s1_is_inf)
            s2_result = {s1_sign, 8'hFF, 23'd0};
        else if (s1_is_zero)
            s2_result = {s1_sign, 31'd0};
        else if (final_exp <= 0)
            s2_result = {s1_sign, 8'd0, 23'd0};
        else if (final_exp >= 255)
            s2_result = {s1_sign, 8'hFF, 23'd0};
        else
            s2_result = {s1_sign, final_exp[7:0], final_product[45:23]};
    end

    // Stage 1 → O 输出寄存器
    always @(posedge clk) begin
        if (!rst_n)
            O <= 32'd0;
        else
            O <= s2_result;
    end

    initial begin
        s1_product = 48'd0;
        s1_exp_sum = 10'sd0;
        s1_sign    = 1'b0;
        s1_is_nan  = 1'b0;
        s1_is_inf  = 1'b0;
        s1_is_zero = 1'b0;
        O          = 32'd0;
    end

endmodule


// =================================================================
// gMultiplier: FP32乘法全组合逻辑 (保留，供参考/其他例化)
// =================================================================
module gMultiplier(a, b, out);
    input  [31:0] a, b;
    output [31:0] out;

    wire [31:0] out;
    reg a_sign;
    reg [7:0] a_exponent;
    reg [23:0] a_mantissa;
    reg b_sign;
    reg [7:0] b_exponent;
    reg [23:0] b_mantissa;

    reg o_sign;
    reg [7:0] o_exponent;
    reg [24:0] o_mantissa;

    reg [47:0] product;

    assign out[31] = o_sign;
    assign out[30:23] = o_exponent;
    assign out[22:0] = o_mantissa[22:0];

    reg  [7:0] i_e;
    reg  [47:0] i_m;
    wire [7:0] o_e;
    wire [47:0] o_m;

    multiplication_normaliser norm1 (
        .in_e(i_e),
        .in_m(i_m),
        .out_e(o_e),
        .out_m(o_m)
    );

    reg signed [9:0] exp_sum;

    always @ ( * ) begin
        i_e = 8'd0;
        i_m = 48'd0;
        a_sign = a[31];
        if(a[30:23] == 0) begin
            a_exponent = 8'b00000001;
            a_mantissa = {1'b0, a[22:0]};
        end else begin
            a_exponent = a[30:23];
            a_mantissa = {1'b1, a[22:0]};
        end

        b_sign = b[31];
        if(b[30:23] == 0) begin
            b_exponent = 8'b00000001;
            b_mantissa = {1'b0, b[22:0]};
        end else begin
            b_exponent = b[30:23];
            b_mantissa = {1'b1, b[22:0]};
        end

        o_sign = a_sign ^ b_sign;
        exp_sum = {2'b0, a_exponent} + {2'b0, b_exponent} - 10'sd127;
        product = a_mantissa * b_mantissa;

        if(product[47] == 1) begin
            exp_sum = exp_sum + 1;
            product = product >> 1;
        end else if((product[46] != 1) && (exp_sum > 0)) begin
            i_e = exp_sum[7:0];
            i_m = product;
            exp_sum = {2'b0, o_e};
            product = o_m;
        end

        if (exp_sum <= 0) begin
            o_exponent = 8'd0;
            o_mantissa = 25'd0;
        end else if (exp_sum >= 255) begin
            o_exponent = 8'hFF;
            o_mantissa = 25'd0;
        end else begin
            o_exponent = exp_sum[7:0];
            o_mantissa = product[47:23];
        end
    end
endmodule


// =================================================================
// multiplication_normaliser: 前导零检测+左移归一化 (纯组合逻辑)
// =================================================================
module multiplication_normaliser(in_e, in_m, out_e, out_m);
    input [7:0] in_e;
    input [47:0] in_m;
    output reg [7:0] out_e;
    output reg [47:0] out_m;

    always @ ( * ) begin
        if (in_m[46:41] == 6'b000001) begin
            out_e = in_e - 5;
            out_m = in_m << 5;
        end else if (in_m[46:42] == 5'b00001) begin
            out_e = in_e - 4;
            out_m = in_m << 4;
        end else if (in_m[46:43] == 4'b0001) begin
            out_e = in_e - 3;
            out_m = in_m << 3;
        end else if (in_m[46:44] == 3'b001) begin
            out_e = in_e - 2;
            out_m = in_m << 2;
        end else if (in_m[46:45] == 2'b01) begin
            out_e = in_e - 1;
            out_m = in_m << 1;
        end else begin
            out_e = in_e;
            out_m = in_m;
        end
    end
endmodule

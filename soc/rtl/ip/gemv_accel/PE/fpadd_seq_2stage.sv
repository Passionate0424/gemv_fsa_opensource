`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////
// fpadd_seq_2stage - 2级流水FP32加法器
//
// 基于generalAdder拆分，用于超前计算(look-ahead)优化PE反馈环路。
//
// Stage1 (R1): 指数提取 + 对阶移位 + 尾数加减 + 溢出右移
// Stage2 (R2): LZD前导零检测 + 桶形移位归一化 + 下溢检测
//
// bypass_s1=1时R1透传（FSA模式，无反馈环路，单周期完成）
// load_init=1时R1和R2同时加载init_val（超前计算初始化）
//////////////////////////////////////////////////////////////

module fpadd_seq_2stage(
    input         clock,
    input         rst_n,
    input  [31:0] A,
    input  [31:0] B,
    input         bypass_s1,   // 1=R1透传(FSA), 0=R1寄存(OS)
    input  [31:0] init_val,    // 累加器初始值
    input         load_init,   // 加载init_val到R1和R2
    output reg [31:0] O        // R2输出
);

    // ============================================================
    // Stage1: 指数提取 + 对阶 + 尾数加减 + 溢出归一化
    // ============================================================
    reg        s1_a_sign, s1_b_sign;
    reg [7:0]  s1_a_exp, s1_b_exp;
    reg [23:0] s1_a_man, s1_b_man;
    reg        s1_o_sign;
    reg [7:0]  s1_o_exp;
    reg [24:0] s1_o_man;
    reg [7:0]  s1_diff;
    reg [23:0] s1_tmp_man;

    // Stage1组合逻辑输出
    reg        s1_out_sign;
    reg [7:0]  s1_out_exp;
    reg [24:0] s1_out_man;
    reg        s1_out_is_zero;    // 结果为零
    reg        s1_out_overflow;   // mantissa[24]=1，已右移

    // 特殊值标志（用于corner case直通）
    wire       a_is_nan = (A[30:23] == 8'hFF) && (A[22:0] != 23'h0);
    wire       b_is_nan = (B[30:23] == 8'hFF) && (B[22:0] != 23'h0);
    wire       a_is_zero = (A[30:23] == 8'h0) && (A[22:0] == 23'h0);
    wire       b_is_zero = (B[30:23] == 8'h0) && (B[22:0] == 23'h0);
    wire       a_is_inf = (A[30:23] == 8'hFF) && (A[22:0] == 23'h0);
    wire       b_is_inf = (B[30:23] == 8'hFF) && (B[22:0] == 23'h0);

    // corner case: 直接输出（不经过正常计算路径）
    reg        s1_corner_hit;
    reg [31:0] s1_corner_val;

    always @(*) begin
        // 默认值
        s1_out_sign = 1'b0;
        s1_out_exp = 8'd0;
        s1_out_man = 25'd0;
        s1_out_is_zero = 1'b0;
        s1_out_overflow = 1'b0;
        s1_corner_hit = 1'b0;
        s1_corner_val = 32'd0;

        // corner case处理（与原fpadd_seq一致）
        if (a_is_nan || (b_is_zero && !b_is_nan)) begin
            s1_corner_hit = 1'b1;
            s1_corner_val = A;
        end else if (b_is_nan || (a_is_zero && !a_is_nan)) begin
            s1_corner_hit = 1'b1;
            s1_corner_val = B;
        end else if (a_is_inf || b_is_inf) begin
            s1_corner_hit = 1'b1;
            s1_corner_val = {A[31] ^ B[31], 8'hFF, 23'h0};
        end else begin
            // 正常计算路径
            s1_a_sign = A[31];
            if (A[30:23] == 0) begin
                s1_a_exp = 8'd1;
                s1_a_man = {1'b0, A[22:0]};
            end else begin
                s1_a_exp = A[30:23];
                s1_a_man = {1'b1, A[22:0]};
            end

            s1_b_sign = B[31];
            if (B[30:23] == 0) begin
                s1_b_exp = 8'd1;
                s1_b_man = {1'b0, B[22:0]};
            end else begin
                s1_b_exp = B[30:23];
                s1_b_man = {1'b1, B[22:0]};
            end

            // 对阶 + 尾数加减
            if (s1_a_exp == s1_b_exp) begin
                s1_out_exp = s1_a_exp;
                if (s1_a_sign == s1_b_sign) begin
                    s1_out_man = {1'b0, s1_a_man} + {1'b0, s1_b_man};
                    s1_out_sign = s1_a_sign;
                end else begin
                    if (s1_a_man > s1_b_man) begin
                        s1_out_man = s1_a_man - s1_b_man;
                        s1_out_sign = s1_a_sign;
                    end else begin
                        s1_out_man = s1_b_man - s1_a_man;
                        s1_out_sign = s1_b_sign;
                    end
                end
            end else if (s1_a_exp > s1_b_exp) begin
                s1_out_exp = s1_a_exp;
                s1_out_sign = s1_a_sign;
                s1_diff = s1_a_exp - s1_b_exp;
                s1_tmp_man = s1_b_man >> s1_diff;
                if (s1_a_sign == s1_b_sign)
                    s1_out_man = s1_a_man + s1_tmp_man;
                else
                    s1_out_man = s1_a_man - s1_tmp_man;
            end else begin
                s1_out_exp = s1_b_exp;
                s1_out_sign = s1_b_sign;
                s1_diff = s1_b_exp - s1_a_exp;
                s1_tmp_man = s1_a_man >> s1_diff;
                if (s1_a_sign == s1_b_sign)
                    s1_out_man = s1_b_man + s1_tmp_man;
                else
                    s1_out_man = s1_b_man - s1_tmp_man;
            end

            // 溢出归一化（mantissa[24]=1时右移1）
            if (s1_out_man == 25'd0) begin
                s1_out_sign = 1'b0;
                s1_out_exp = 8'd0;
                s1_out_is_zero = 1'b1;
            end else if (s1_out_man[24]) begin
                s1_out_exp = s1_out_exp + 8'd1;
                s1_out_man = s1_out_man >> 1;
                s1_out_overflow = 1'b1;
            end
        end
    end

    // ============================================================
    // R1寄存器（OS模式寄存，FSA模式bypass）
    // ============================================================
    reg        r1_sign;
    reg [7:0]  r1_exp;
    reg [24:0] r1_man;
    reg        r1_is_zero;
    reg        r1_normalized;  // mantissa[23]=1，无需LZD归一化
    reg        r1_corner_hit;
    reg [31:0] r1_corner_val;

    always_ff @(posedge clock) begin
        if (!rst_n) begin
            r1_sign       <= 1'b0;
            r1_exp        <= 8'd0;
            r1_man        <= 25'd0;
            r1_is_zero    <= 1'b1;
            r1_normalized <= 1'b0;
            r1_corner_hit <= 1'b0;
            r1_corner_val <= 32'd0;
        end else if (load_init) begin
            r1_sign       <= init_val[31];
            r1_exp        <= init_val[30:23];
            r1_man        <= {1'b1, init_val[22:0], 1'b0};
            r1_is_zero    <= (init_val[30:0] == 31'd0);
            r1_normalized <= 1'b1;
            r1_corner_hit <= 1'b0;
            r1_corner_val <= 32'd0;
        end else begin
            r1_sign       <= s1_out_sign;
            r1_exp        <= s1_out_exp;
            r1_man        <= s1_out_man;
            r1_is_zero    <= s1_out_is_zero;
            r1_normalized <= s1_out_man[23] | s1_out_overflow | s1_out_is_zero;
            r1_corner_hit <= s1_corner_hit;
            r1_corner_val <= s1_corner_val;
        end
    end

    // R1 bypass MUX（FSA模式直通）
    wire        s2_in_sign       = bypass_s1 ? s1_out_sign    : r1_sign;
    wire [7:0]  s2_in_exp        = bypass_s1 ? s1_out_exp     : r1_exp;
    wire [24:0] s2_in_man        = bypass_s1 ? s1_out_man     : r1_man;
    wire        s2_in_is_zero    = bypass_s1 ? s1_out_is_zero : r1_is_zero;
    wire        s2_in_normalized = bypass_s1 ? (s1_out_man[23] | s1_out_overflow | s1_out_is_zero) : r1_normalized;
    wire        s2_in_corner_hit = bypass_s1 ? s1_corner_hit  : r1_corner_hit;
    wire [31:0] s2_in_corner_val = bypass_s1 ? s1_corner_val  : r1_corner_val;

    // ============================================================
    // Stage2: LZD归一化 + 下溢检测 + 输出
    // ============================================================
    wire [7:0]  norm_out_e;
    wire [24:0] norm_out_m;

    addition_normaliser norm1 (
        .in_e(s2_in_exp),
        .in_m(s2_in_man),
        .out_e(norm_out_e),
        .out_m(norm_out_m)
    );

    // Stage2组合逻辑
    reg [31:0] s2_result;
    always @(*) begin
        if (s2_in_corner_hit) begin
            s2_result = s2_in_corner_val;
        end else if (s2_in_is_zero) begin
            s2_result = 32'd0;
        end else if (s2_in_normalized) begin
            // mantissa[23]=1，已归一化，直接输出
            s2_result = {s2_in_sign, s2_in_exp, s2_in_man[22:0]};
        end else if (s2_in_exp != 8'd0) begin
            // 需要LZD归一化
            if (norm_out_e == 8'd0 || norm_out_e > s2_in_exp) begin
                // 下溢：归零
                s2_result = 32'd0;
            end else begin
                s2_result = {s2_in_sign, norm_out_e, norm_out_m[22:0]};
            end
        end else begin
            s2_result = {s2_in_sign, s2_in_exp, s2_in_man[22:0]};
        end
    end

    // ============================================================
    // R2输出寄存器
    // ============================================================
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            O <= 32'd0;
        end else if (load_init) begin
            O <= init_val;
        end else begin
            O <= s2_result;
        end
    end

endmodule

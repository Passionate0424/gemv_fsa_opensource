`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// FPAccUnit_pipe
//
// 流水化版本的FPAccUnit，复用rtl/PE/RawFloat_MulAddExp2_pipe
// 替代原版组合逻辑FPAccUnit，提供更好的时序性能。
//
// 延迟：4拍（从输入到输出）
//   Stage 0: 输入格式转换 + SplitIF + LUT查表 + MUX → 寄存器切割
//   Stage 1~3: RawFloat_MulAddExp2_pipe (fpmul 2拍 + fpadd 1拍)
//
// 功能：与原版FPAccUnit完全一致
//   - 普通模式(cmd=0): out = a × b + c
//   - exp2模式(cmd=1): out = exp2(a) (PWL近似)
//   - reciprocal: 多周期迭代除法 1/a
////////////////////////////////////////////////////////////////
module FPAccUnit_pipe(
    input         clock,
    input         rst_n,
    input         io_in_valid,
    input         io_in_a_sign,
    input  [7:0]  io_in_a_exp,
    input  [22:0] io_in_a_mantissa,
    input         io_in_b_sign,
    input  [7:0]  io_in_b_exp,
    input  [22:0] io_in_b_mantissa,
    input         io_in_c_sign,
    input  [7:0]  io_in_c_exp,
    input  [22:0] io_in_c_mantissa,
    input         io_in_cmd,       // 0=FMA, 1=exp2
    output        io_out_valid,
    output        io_out_accType_sign,
    output [7:0]  io_out_accType_exp,
    output [22:0] io_out_accType_mantissa,
    input         multiCycleIO_reciprocal_in_valid,
    output        multiCycleIO_reciprocal_out_valid
);

    // ============================================================
    // Stage 0: 输入格式转换 + SplitIF + LUT + MUX（纯组合）
    // ============================================================

    // RawFloat格式转换：IEEE754 exp → 有符号exp
    wire        a_isZero = (io_in_a_exp == 8'h0);
    wire        a_isInf  = (&io_in_a_exp) & ~(|io_in_a_mantissa);
    wire        a_isNaN  = (&io_in_a_exp) & (|io_in_a_mantissa);
    wire [8:0]  a_exp    = {1'h0, io_in_a_exp} - 9'h7F;
    wire [23:0] a_man    = {1'h1, io_in_a_mantissa};

    wire        b_isZero = (io_in_b_exp == 8'h0);
    wire        b_isInf  = (&io_in_b_exp) & ~(|io_in_b_mantissa);
    wire        b_isNaN  = (&io_in_b_exp) & (|io_in_b_mantissa);
    wire [8:0]  b_exp    = {1'h0, io_in_b_exp} - 9'h7F;
    wire [23:0] b_man    = {1'h1, io_in_b_mantissa};

    wire        c_isZero = (io_in_c_exp == 8'h0);
    wire        c_isInf  = (&io_in_c_exp) & ~(|io_in_c_mantissa);
    wire        c_isNaN  = (&io_in_c_exp) & (|io_in_c_mantissa);
    wire [8:0]  c_exp    = {1'h0, io_in_c_exp} - 9'h7F;
    wire [23:0] c_man    = {1'h1, io_in_c_mantissa};

    // exp2模式预处理：SplitIF + LUT查表
    wire [8:0]  split_outInt;
    wire [2:0]  split_outFracMSBs;
    wire        split_outRF_isZero, split_outRF_isInf, split_outRF_isNaN;
    wire        split_outRF_sign;
    wire [8:0]  split_outRF_exp;
    wire [23:0] split_outRF_mantissa;

    RawFloat_SplitIF split (
        .io_in_isZero           (a_isZero),
        .io_in_isInf            (a_isInf),
        .io_in_isNaN            (a_isNaN),
        .io_in_sign             (io_in_a_sign),
        .io_in_exp              (a_exp),
        .io_in_mantissa         (a_man),
        .io_outInt              (split_outInt),
        .io_outFracMSBs         (split_outFracMSBs),
        .io_outRawFloat_isZero  (split_outRF_isZero),
        .io_outRawFloat_isInf   (split_outRF_isInf),
        .io_outRawFloat_isNaN   (split_outRF_isNaN),
        .io_outRawFloat_sign    (split_outRF_sign),
        .io_outRawFloat_exp     (split_outRF_exp),
        .io_outRawFloat_mantissa(split_outRF_mantissa)
    );

    // PWL exp2 LUT（Chebyshev优化8段系数）
    wire [31:0] exp2_intercept_lut [0:7];
    wire [31:0] exp2_slope_lut [0:7];
    assign exp2_intercept_lut[0] = 32'h3f7fe21f;
    assign exp2_intercept_lut[1] = 32'h3f7e2064;
    assign exp2_intercept_lut[2] = 32'h3f7ae614;
    assign exp2_intercept_lut[3] = 32'h3f7674cd;
    assign exp2_intercept_lut[4] = 32'h3f7105dd;
    assign exp2_intercept_lut[5] = 32'h3f6acb35;
    assign exp2_intercept_lut[6] = 32'h3f63f03a;
    assign exp2_intercept_lut[7] = 32'h3f5c9a86;
    assign exp2_slope_lut[0] = 32'h3f29f2fb;
    assign exp2_slope_lut[1] = 32'h3f1bd814;
    assign exp2_slope_lut[2] = 32'h3f0ee8dd;
    assign exp2_slope_lut[3] = 32'h3f030c78;
    assign exp2_slope_lut[4] = 32'h3ef05829;
    assign exp2_slope_lut[5] = 32'h3edc6593;
    assign exp2_slope_lut[6] = 32'h3eca1acf;
    assign exp2_slope_lut[7] = 32'h3eb954b3;

    wire [31:0] exp2_slope     = exp2_slope_lut[split_outFracMSBs];
    wire [31:0] exp2_intercept = exp2_intercept_lut[split_outFracMSBs];

    // exp2模式下b=slope, c=intercept（从LUT）；普通模式下b/c来自外部
    wire        fma_b_isZero  = io_in_cmd ? (exp2_slope[30:23] == 8'h0)     : b_isZero;
    wire        fma_b_isInf   = io_in_cmd ? (&exp2_slope[30:23]) & ~(|exp2_slope[22:0]) : b_isInf;
    wire        fma_b_isNaN   = io_in_cmd ? (&exp2_slope[30:23]) & (|exp2_slope[22:0])  : b_isNaN;
    wire        fma_b_sign    = io_in_cmd ? exp2_slope[31]        : io_in_b_sign;
    wire [8:0]  fma_b_exp     = io_in_cmd ? ({1'h0, exp2_slope[30:23]} - 9'h7F) : b_exp;
    wire [23:0] fma_b_man     = io_in_cmd ? {1'h1, exp2_slope[22:0]}   : b_man;

    wire        fma_c_isZero  = io_in_cmd ? (exp2_intercept[30:23] == 8'h0) : c_isZero;
    wire        fma_c_isInf   = io_in_cmd ? (&exp2_intercept[30:23]) & ~(|exp2_intercept[22:0]) : c_isInf;
    wire        fma_c_isNaN   = io_in_cmd ? (&exp2_intercept[30:23]) & (|exp2_intercept[22:0])  : c_isNaN;
    wire        fma_c_sign    = io_in_cmd ? exp2_intercept[31]        : io_in_c_sign;
    wire [8:0]  fma_c_exp     = io_in_cmd ? ({1'h0, exp2_intercept[30:23]} - 9'h7F) : c_exp;
    wire [23:0] fma_c_man     = io_in_cmd ? {1'h1, exp2_intercept[22:0]}   : c_man;

    // a输入MUX（exp2模式用SplitIF输出的小数部分RawFloat）
    wire exp2_overflow = io_in_cmd & split_outRF_isInf;
    wire        fma_a_isZero = io_in_cmd ? (split_outRF_isZero | exp2_overflow) : a_isZero;
    wire        fma_a_isInf  = io_in_cmd ? 1'b0 : a_isInf;
    wire        fma_a_isNaN  = io_in_cmd ? split_outRF_isNaN : a_isNaN;
    wire        fma_a_sign   = io_in_cmd ? split_outRF_sign : io_in_a_sign;
    wire [8:0]  fma_a_exp    = io_in_cmd ? split_outRF_exp : a_exp;
    wire [23:0] fma_a_man    = io_in_cmd ? split_outRF_mantissa : a_man;

    // ============================================================
    // Stage 0 → Stage 1 寄存器切割（切断前端组合路径）
    // ============================================================
    reg         s0_valid;
    reg         s0_cmd;
    // a通道
    reg         s0_a_isZero, s0_a_isInf, s0_a_isNaN, s0_a_sign;
    reg  [8:0]  s0_a_exp;
    reg  [23:0] s0_a_man;
    // b通道
    reg         s0_b_isZero, s0_b_isInf, s0_b_isNaN, s0_b_sign;
    reg  [8:0]  s0_b_exp;
    reg  [23:0] s0_b_man;
    // c通道
    reg         s0_c_isZero, s0_c_isInf, s0_c_isNaN, s0_c_sign;
    reg  [8:0]  s0_c_exp;
    reg  [23:0] s0_c_man;
    // exp2辅助信号
    reg  [8:0]  s0_split_int;

    always_ff @(posedge clock) begin
        if (!rst_n) begin
            s0_valid        <= 1'b0;
            s0_cmd          <= 1'b0;
            s0_a_isZero     <= 1'b1;
            s0_a_isInf      <= 1'b0;
            s0_a_isNaN      <= 1'b0;
            s0_a_sign       <= 1'b0;
            s0_a_exp        <= 9'h0;
            s0_a_man        <= 24'h0;
            s0_b_isZero     <= 1'b1;
            s0_b_isInf      <= 1'b0;
            s0_b_isNaN      <= 1'b0;
            s0_b_sign       <= 1'b0;
            s0_b_exp        <= 9'h0;
            s0_b_man        <= 24'h0;
            s0_c_isZero     <= 1'b1;
            s0_c_isInf      <= 1'b0;
            s0_c_isNaN      <= 1'b0;
            s0_c_sign       <= 1'b0;
            s0_c_exp        <= 9'h0;
            s0_c_man        <= 24'h0;
            s0_split_int    <= 9'h0;
        end else begin
            s0_valid        <= io_in_valid;
            s0_cmd          <= io_in_cmd;
            s0_a_isZero     <= fma_a_isZero;
            s0_a_isInf      <= fma_a_isInf;
            s0_a_isNaN      <= fma_a_isNaN;
            s0_a_sign       <= fma_a_sign;
            s0_a_exp        <= fma_a_exp;
            s0_a_man        <= fma_a_man;
            s0_b_isZero     <= fma_b_isZero;
            s0_b_isInf      <= fma_b_isInf;
            s0_b_isNaN      <= fma_b_isNaN;
            s0_b_sign       <= fma_b_sign;
            s0_b_exp        <= fma_b_exp;
            s0_b_man        <= fma_b_man;
            s0_c_isZero     <= exp2_overflow ? 1'b1 : fma_c_isZero;
            s0_c_isInf      <= fma_c_isInf;
            s0_c_isNaN      <= fma_c_isNaN;
            s0_c_sign       <= fma_c_sign;
            s0_c_exp        <= fma_c_exp;
            s0_c_man        <= fma_c_man;
            s0_split_int    <= split_outInt;
        end
    end

    // ============================================================
    // c输入延迟链：2拍延迟，对齐乘法器输出。切割点在FMA前，故延迟不受管道深度变化影响
    // ============================================================
    reg         fma_c_isZero_q1, fma_c_isZero_q2;
    reg         fma_c_isInf_q1, fma_c_isInf_q2;
    reg         fma_c_isNaN_q1, fma_c_isNaN_q2;
    reg         fma_c_sign_q1, fma_c_sign_q2;
    reg  [8:0]  fma_c_exp_q1, fma_c_exp_q2;
    reg  [23:0] fma_c_man_q1, fma_c_man_q2;
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            fma_c_isZero_q1 <= 1'b1; fma_c_isZero_q2 <= 1'b1;
            fma_c_isInf_q1  <= 1'b0; fma_c_isInf_q2  <= 1'b0;
            fma_c_isNaN_q1  <= 1'b0; fma_c_isNaN_q2  <= 1'b0;
            fma_c_sign_q1   <= 1'b0; fma_c_sign_q2   <= 1'b0;
            fma_c_exp_q1    <= 9'h0; fma_c_exp_q2    <= 9'h0;
            fma_c_man_q1    <= 24'h0; fma_c_man_q2   <= 24'h0;
        end else begin
            fma_c_isZero_q1 <= s0_c_isZero; fma_c_isZero_q2 <= fma_c_isZero_q1;
            fma_c_isInf_q1  <= s0_c_isInf;  fma_c_isInf_q2  <= fma_c_isInf_q1;
            fma_c_isNaN_q1  <= s0_c_isNaN;  fma_c_isNaN_q2  <= fma_c_isNaN_q1;
            fma_c_sign_q1   <= s0_c_sign;   fma_c_sign_q2   <= fma_c_sign_q1;
            fma_c_exp_q1    <= s0_c_exp;    fma_c_exp_q2    <= fma_c_exp_q1;
            fma_c_man_q1    <= s0_c_man;    fma_c_man_q2    <= fma_c_man_q1;
        end
    end

    // ============================================================
    // RawFloat_FMA_LA_pipe: 4拍流水FMA（复用PE已验证的LA版本，bypass_s1=0）
    // 从s0寄存器输出驱动，exp2后处理用s0寄存的split信号
    // ============================================================
    wire        fma_out_valid;
    wire        fma_out_isZero;
    wire        fma_out_isInf;
    wire        fma_out_isNaN;
    wire        fma_out_sign;
    wire [10:0] fma_out_exp;
    wire [25:0] fma_out_mantissa;

    RawFloat_FMA_LA_pipe fma (
        .clock           (clock),
        .rst_n           (rst_n),
        .io_in_valid     (s0_valid),
        .io_a_isZero     (s0_a_isZero),
        .io_a_isInf      (s0_a_isInf),
        .io_a_isNaN      (s0_a_isNaN),
        .io_a_sign       (s0_a_sign),
        .io_a_exp        (s0_a_exp),
        .io_a_mantissa   (s0_a_man),
        .io_b_isZero     (s0_b_isZero),
        .io_b_isInf      (s0_b_isInf),
        .io_b_isNaN      (s0_b_isNaN),
        .io_b_sign       (s0_b_sign),
        .io_b_exp        (s0_b_exp),
        .io_b_mantissa   (s0_b_man),
        .io_c_isZero     (fma_c_isZero_q2),
        .io_c_isInf      (fma_c_isInf_q2),
        .io_c_isNaN      (fma_c_isNaN_q2),
        .io_c_sign       (fma_c_sign_q2),
        .io_c_exp        (fma_c_exp_q2),
        .io_c_mantissa   (fma_c_man_q2),
        // bypass_s1=0: 始终2级流水加法器
        .bypass_s1       (1'b0),
        .use_pre_add     (1'b0),
        .pre_add_in      (32'h0),
        .init_val        (32'h0),
        .load_init       (1'b0),
        .mul_out_port    (),
        .io_out_valid    (fma_out_valid),
        .io_out_isZero   (fma_out_isZero),
        .io_out_isInf    (fma_out_isInf),
        .io_out_isNaN    (fma_out_isNaN),
        .io_out_sign     (fma_out_sign),
        .io_out_exp      (fma_out_exp),
        .io_out_mantissa (fma_out_mantissa)
    );

    // exp2辅助信号延迟链（与FMA_LA 4拍对齐）
    reg  [8:0]  split_int_pipe [0:3];
    reg         exp2_pipe [0:3];

    integer i;
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            for (i = 0; i < 4; i = i + 1) begin
                exp2_pipe[i]       <= 1'b0;
                split_int_pipe[i]  <= 9'h0;
            end
        end else begin
            exp2_pipe[0]       <= s0_valid & s0_cmd;
            split_int_pipe[0]  <= s0_split_int;
            for (i = 1; i < 4; i = i + 1) begin
                exp2_pipe[i]       <= exp2_pipe[i-1];
                split_int_pipe[i]  <= split_int_pipe[i-1];
            end
        end
    end

    // FMA输出 + exp2后处理（pipe[3]对齐4拍FMA_LA）
    wire        mulAdd_out_valid  = fma_out_valid;
    wire        mulAdd_out_isZero = exp2_pipe[3] ? fma_out_isInf : fma_out_isZero;
    wire        mulAdd_out_isInf  = ~exp2_pipe[3] & fma_out_isInf;
    wire        mulAdd_out_isNaN  = fma_out_isNaN;
    wire        mulAdd_out_sign   = ~exp2_pipe[3] & fma_out_sign;
    wire [10:0] mulAdd_out_exp    = exp2_pipe[3]
        ? {{2{split_int_pipe[3][8]}}, split_int_pipe[3]} + fma_out_exp
        : fma_out_exp;
    wire [25:0] mulAdd_out_mantissa = fma_out_mantissa;

    // ============================================================
    // RawFloat_Div: 迭代除法（多周期）
    // Div启动时锁存输入数据，使其不依赖外部持续保持cmd=5
    // ============================================================
    wire        div_out_valid;
    wire        div_out_isZero;
    wire        div_out_isInf;
    wire        div_out_isNaN;
    wire        div_out_sign;
    wire [9:0]  div_out_exp;
    wire [25:0] div_out_mantissa;

    // Div输入锁存：recip_cmd_r脉冲时采样，之后保持稳定
    reg         div_in_isZero_q;
    reg         div_in_isInf_q;
    reg         div_in_isNaN_q;
    reg         div_in_sign_q;
    reg  [8:0]  div_in_exp_q;
    reg  [23:0] div_in_man_q;
    reg         div_in_valid_q;  // valid延迟1拍，等锁存数据就绪
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            div_in_isZero_q <= 1'b1;
            div_in_isInf_q  <= 1'b0;
            div_in_isNaN_q  <= 1'b0;
            div_in_sign_q   <= 1'b0;
            div_in_exp_q    <= 9'h0;
            div_in_man_q    <= 24'h0;
            div_in_valid_q    <= 1'b0;
        end else begin
            div_in_valid_q <= multiCycleIO_reciprocal_in_valid;
            if (multiCycleIO_reciprocal_in_valid) begin
                div_in_isZero_q <= a_isZero;
                div_in_isInf_q  <= a_isInf;
                div_in_isNaN_q  <= a_isNaN;
                div_in_sign_q   <= io_in_a_sign;
                div_in_exp_q    <= a_exp;
                div_in_man_q    <= a_man;
            end
        end
    end

    RawFloat_Div div (
        .clock                 (clock),
        .reset                 (!rst_n),
        .io_in_valid           (div_in_valid_q),
        .io_in_bits_b_isZero   (div_in_isZero_q),
        .io_in_bits_b_isInf    (div_in_isInf_q),
        .io_in_bits_b_isNaN    (div_in_isNaN_q),
        .io_in_bits_b_sign     (div_in_sign_q),
        .io_in_bits_b_exp      (div_in_exp_q),
        .io_in_bits_b_mantissa (div_in_man_q),
        .io_out_valid          (div_out_valid),
        .io_out_bits_isZero    (div_out_isZero),
        .io_out_bits_isInf     (div_out_isInf),
        .io_out_bits_isNaN     (div_out_isNaN),
        .io_out_bits_sign      (div_out_sign),
        .io_out_bits_exp       (div_out_exp),
        .io_out_bits_mantissa  (div_out_mantissa)
    );

    // ============================================================
    // 输出MUX + IEEE754格式转换
    // div优先（reciprocal结果必须正确写入scale）
    // ============================================================
    wire [10:0] raw_out_exp = div_out_valid
        ? {div_out_exp[9], div_out_exp} : mulAdd_out_exp;
    wire [24:0] raw_out_mantissa = div_out_valid
        ? div_out_mantissa[24:0] : mulAdd_out_mantissa[24:0];
    wire        raw_out_is_inf  = div_out_valid ? div_out_isInf  : mulAdd_out_isInf;
    wire        raw_out_is_nan  = div_out_valid ? div_out_isNaN  : mulAdd_out_isNaN;
    wire        raw_out_is_zero = div_out_valid ? div_out_isZero : mulAdd_out_isZero;
    wire        raw_out_sign   = div_out_valid ? div_out_sign   : mulAdd_out_sign;

    // 舍入
    wire [23:0] rounded_mantissa = {1'h0, raw_out_mantissa[24:2]}
        + {23'h0, raw_out_mantissa[1] & raw_out_mantissa[0]
            | raw_out_mantissa[1] & ~raw_out_mantissa[0] & raw_out_mantissa[2]};
    wire [11:0] rounded_exp = {raw_out_exp[10], raw_out_exp}
        + {11'h0, rounded_mantissa[23]};
    wire overflow  = $signed(rounded_exp) > 12'sh7F;
    wire underflow = $signed(rounded_exp) < -12'sh7E;

    // 输出
    assign io_out_valid = mulAdd_out_valid | div_out_valid;
    assign io_out_accType_sign = raw_out_sign & ~raw_out_is_nan;
    assign io_out_accType_exp = (raw_out_is_inf | raw_out_is_nan | overflow)
        ? 8'hFF : (raw_out_is_zero | underflow)
            ? 8'h0 : rounded_exp[7:0] + 8'h7F;
    assign io_out_accType_mantissa = raw_out_is_nan
        ? 23'h400000 : (raw_out_is_zero | raw_out_is_inf | underflow | overflow)
            ? 23'h0 : rounded_mantissa[22:0];
    assign multiCycleIO_reciprocal_out_valid = div_out_valid;

endmodule

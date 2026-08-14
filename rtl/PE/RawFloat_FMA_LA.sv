`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// RawFloat_FMA - FP32 MAC 模块（超前计算版本）
//
// 实现: fpmul_seq_pipeline (2拍乘法) + fpadd_seq_2stage (1或2拍加法)
//
// 数据流（OS模式，MAC内部4拍）:
//   S1: fpmul 第1拍
//   S2: fpmul 第2拍 → mul_out（暴露给外部pre_add）
//   S3: fpadd_seq_2stage stage1 (对阶+尾数加) → R1
//   S4: fpadd_seq_2stage stage2 (归一化) → R2 = add_out
//
// 数据流（FSA模式，MAC内部3拍，R1 bypass）:
//   S1: fpmul 第1拍
//   S2: fpmul 第2拍 → mul_out
//   S3: fpadd_seq_2stage stage1+stage2 (bypass R1) → R2 = add_out
//
// 接口保持原有分解格式，内部转换为32bit进行计算
////////////////////////////////////////////////////////////////////////////////
module RawFloat_FMA_LA_pipe(
    input         clock,
    input         rst_n,
    input         io_in_valid,
    input         io_a_isZero,
                  io_a_isInf,
                  io_a_isNaN,
                  io_a_sign,
    input  [8:0]  io_a_exp,
    input  [23:0] io_a_mantissa,
    input         io_b_isZero,
                  io_b_isInf,
                  io_b_isNaN,
                  io_b_sign,
    input  [8:0]  io_b_exp,
    input  [23:0] io_b_mantissa,
    input         io_c_isZero,
                  io_c_isInf,
                  io_c_isNaN,
                  io_c_sign,
    input  [8:0]  io_c_exp,
    input  [23:0] io_c_mantissa,
    // 超前计算新增端口
    input         bypass_s1,      // 1=FSA模式R1透传, 0=OS模式R1寄存
    input         use_pre_add,    // 1=OS模式用pre_add输出作为加法器A
    input  [31:0] pre_add_in,     // 预求和结果 s[n]
    input  [31:0] init_val,       // 累加器初始值(psum)
    input         load_init,      // 加载init_val到加法器R1和R2
    output [31:0] mul_out_port,   // 暴露乘法器输出给外部pre_add
    // 原有输出
    output        io_out_valid,
    output        io_out_isZero,
                  io_out_isInf,
                  io_out_isNaN,
                  io_out_sign,
    output [10:0] io_out_exp,
    output [25:0] io_out_mantissa
);

    // RawFloat → IEEE754格式转换
    wire [8:0] io_a_exp_tmp = io_a_exp + 9'sd127;
    wire [7:0] io_a_exp_uint = io_a_exp_tmp[7:0];
    wire [31:0] io_a = io_a_isZero ? 32'h0 : {io_a_sign, io_a_exp_uint, io_a_mantissa[22:0]};

    wire [8:0] io_b_exp_tmp = io_b_exp + 9'sd127;
    wire [7:0] io_b_exp_uint = io_b_exp_tmp[7:0];
    wire [31:0] io_b = io_b_isZero ? 32'h0 : {io_b_sign, io_b_exp_uint, io_b_mantissa[22:0]};

    wire [8:0] io_c_exp_tmp = io_c_exp + 9'sd127;
    wire [7:0] io_c_exp_uint = io_c_exp_tmp[7:0];
    wire [31:0] io_c = io_c_isZero ? 32'h0 : {io_c_sign, io_c_exp_uint, io_c_mantissa[22:0]};

    // 乘法器输出 (2拍延迟)
    wire [31:0] mul_out;
    assign mul_out_port = mul_out;

    // 加法器A输入MUX: OS模式用pre_add结果，FSA模式用mul_out
    wire [31:0] add_a = use_pre_add ? pre_add_in : mul_out;

    // 加法器输出（提前声明，供反馈路径引用）
    wire [31:0] add_out;

    // 加法器B输入: OS模式直接从R2反馈（消除外部格式往返）
    // R2.Q是寄存器输出，环路R1+R2=2级，维持y[n]=y[n-2]+s[n]
    // FSA模式用外部io_c
    wire [31:0] add_b = use_pre_add ? add_out : io_c;

    // valid延迟链（OS模式4级，FSA模式3级）
    // 强制映射到 FDRE：这条链直出 io_out_valid，没有任何别的信号再限定它，
    // 一旦被推成无复位端的 SRL，上电后的随机 1 会当作一次真实结果提交出去。
    (* srl_style = "register" *)
    reg [3:0] valid_pipe;

    // 例化乘法器: 2拍延迟
    fpmul_seq_pipeline u_mul (
        .clk    (clock),
        .rst_n  (rst_n),
        .A      (io_a),
        .B      (io_b),
        .O      (mul_out)
    );

    // 例化2级流水加法器
    fpadd_seq_2stage u_add (
        .clock      (clock),
        .rst_n      (rst_n),
        .A          (add_a),
        .B          (add_b),
        .bypass_s1  (bypass_s1),
        .init_val   (init_val),
        .load_init  (load_init),
        .O          (add_out)
    );

    // valid延迟链
    always @(posedge clock) begin
        if (!rst_n) begin
            valid_pipe <= 4'b0;
        end else begin
            valid_pipe[0] <= io_in_valid;
            valid_pipe[1] <= valid_pipe[0];
            valid_pipe[2] <= valid_pipe[1];
            valid_pipe[3] <= valid_pipe[2];
        end
    end

    // 输出valid: FSA模式3拍(bypass R1), OS模式4拍
    assign io_out_valid = bypass_s1 ? valid_pipe[2] : valid_pipe[3];

    // IEEE754 → RawFloat格式转换
    assign io_out_sign = add_out[31];
    assign io_out_exp  = {3'b0, add_out[30:23]} - 11'h7F;
    assign io_out_mantissa = {1'b1, add_out[22:0], 2'b00};

    // special case flags
    wire add_out_isInf  = (add_out[30:23] == 8'hFF) && (add_out[22:0] == 23'h0);
    wire add_out_isNaN  = (add_out[30:23] == 8'hFF) && (add_out[22:0] != 23'h0);
    wire add_out_isZero = (add_out[30:23] == 8'h00) && (add_out[22:0] == 23'h0);

    assign io_out_isZero = add_out_isZero;
    assign io_out_isInf  = add_out_isInf;
    assign io_out_isNaN  = add_out_isNaN;

endmodule

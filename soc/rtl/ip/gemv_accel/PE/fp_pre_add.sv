`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////
// fp_pre_add - 超前计算环外预求和模块
//
// 计算 s[n] = x[n-1] + x[n]，用于look-ahead变换。
// OS模式下将相邻两拍乘法结果预先求和，送入环内加法器。
// FSA模式下mul_out_d保持0，输出直通mul_out。
//
// 使用fpadd_seq_2stage（2级流水），占2拍延迟。
//////////////////////////////////////////////////////////////

module fp_pre_add(
    input         clock,
    input         rst_n,
    input  [31:0] mul_out,        // 当前乘法结果 x[n]
    input         mul_out_valid,  // 乘法结果有效
    input         os_mode,        // OS模式使能
    input         rst_acc,        // 首次累加（清除历史）
    output [31:0] pre_add_out     // 2级流水输出 s[n]
);

    // x[n-1]寄存器
    reg [31:0] mul_out_d;

    always_ff @(posedge clock) begin
        if (!rst_n) begin
            mul_out_d <= 32'h0;
        end else if (rst_acc) begin
            mul_out_d <= 32'h0;
        end else if (os_mode && mul_out_valid) begin
            mul_out_d <= mul_out;
        end else if (!os_mode) begin
            mul_out_d <= 32'h0;
        end
    end

    // 2级流水FP32加法（bypass_s1=0，始终2级）
    fpadd_seq_2stage u_pre_adder (
        .clock        (clock),
        .rst_n      (rst_n),
        .A          (mul_out_d),
        .B          (mul_out),
        .bypass_s1  (1'b0),
        .init_val   (32'h0),
        .load_init  (1'b0),
        .O          (pre_add_out)
    );

endmodule

`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// fsa_accumulator
//
// 8通道Accumulator wrapper，复用FPAccUnit_pipe。
// 每组1个实例（共4组，在mac_top_v2中例化4个fsa_accumulator）。
//
// 命令编码（与原版Accumulator一致）：
//   0: EXP_S1   - scale = sa_in × log2e_const
//   1: EXP_S2   - scale = exp2(scale × sram_in)
//   2: ACC_SA   - out = scale × sram_in + sa_in
//   3: ACC_NORM  - out = scale × sram_in
//   4: SET_SCALE - scale ← sram_in
//   5: RECIPROCAL - scale ← 1/scale（多周期）
//
// ACC_LATENCY: 从输入到输出的总流水延迟（含输入寄存器+FPAccUnit_pipe）
//   默认5拍 = 1拍输入寄存器 + 4拍FPAccUnit_pipe
////////////////////////////////////////////////////////////////
module fsa_accumulator #(
    parameter NUM_CH       = 8,
    parameter DATA_WIDTH   = 32,
    parameter ACC_LATENCY  = 6   // 总流水延迟（输入寄存器1 + FPAccUnit 5）
)(
    input  clock,
    input  rst_n,

    // 控制
    input        ctrl_valid,
    input  [2:0] ctrl_cmd,

    // ATTENTION_SCALE = log2(e)/sqrt(head_dim)，运行时由CSR配置
    input  [31:0] attn_scale,

    // 数据输入
    input  [NUM_CH*DATA_WIDTH-1:0] sa_in,     // 来自PE阵列d_output
    input  [NUM_CH*DATA_WIDTH-1:0] sram_in,   // 来自ACC SRAM

    // 数据输出
    output [NUM_CH*DATA_WIDTH-1:0] sram_out,  // 写回ACC SRAM
    output sram_out_valid,

    // 多周期操作状态
    output reciprocal_done
);

    // ============================================================
    // Stage 0: 输入寄存器（切断PE→ACC组合路径）
    // ============================================================
    reg        ctrl_valid_q;
    reg [2:0]  ctrl_cmd_q;
    reg [NUM_CH*DATA_WIDTH-1:0] sa_in_q;
    reg [NUM_CH*DATA_WIDTH-1:0] sram_in_q;
    reg [31:0] attn_scale_q;

    always_ff @(posedge clock) begin
        if (!rst_n) begin
            ctrl_valid_q <= 1'b0;
            ctrl_cmd_q   <= 3'd0;
            sa_in_q      <= '0;
            sram_in_q    <= '0;
            attn_scale_q <= 32'h0;
        end else begin
            ctrl_valid_q <= ctrl_valid;
            ctrl_cmd_q   <= ctrl_cmd;
            sa_in_q      <= sa_in;
            sram_in_q    <= sram_in;
            attn_scale_q <= attn_scale;
        end
    end

    // reciprocal命令延迟1拍对齐输入寄存器
    reg recip_cmd_q;
    always_ff @(posedge clock) begin
        if (!rst_n)
            recip_cmd_q <= 1'b0;
        else
            recip_cmd_q <= ctrl_valid & (ctrl_cmd == 3'd5);
    end

    // ============================================================
    // 命令解码（使用寄存后的信号）
    // ============================================================
    wire exp_s1  = (ctrl_cmd_q == 3'd0);
    wire exp_s2  = (ctrl_cmd_q == 3'd1);
    wire acc_sa  = (ctrl_cmd_q == 3'd2);
    wire set_cmd = (ctrl_cmd_q == 3'd4);

    // ATTENTION_SCALE从寄存后的端口获取
    wire [7:0]  LOG2E_EXP = attn_scale_q[30:23];
    wire [22:0] LOG2E_MAN = attn_scale_q[22:0];

    // ============================================================
    // 8通道 scale寄存器 + FPAccUnit例化
    // ============================================================
    wire [NUM_CH-1:0] ch_reciprocal_done;
    wire [NUM_CH-1:0] ch_out_valid;
    assign reciprocal_done = ch_reciprocal_done[0];

    // sram_out_valid: 仅ACC_SA(cmd=2)的流水输出才写回SRAM
    // 延迟链深度 = ACC_LATENCY - 1（输入寄存器已消耗1拍）
    // cmd_pipe深度 = FPAccUnit_pipe内部延迟(4拍: s0寄存器+3拍FMA)
    localparam PIPE_DEPTH = ACC_LATENCY - 1;
    // cmd_pipe 与 ch_out_valid 一起构成 sram_out_valid（累加器 SRAM 的写使能），
    // 被推成无复位端的 SRL 后上电即随机——配上同样落在 SRL 上的 acc_sram_addr_pipe，
    // 可能在复位释放后的头几拍往随机地址写进一笔垃圾。强制映射到 FDRE。
    (* srl_style = "register" *)
    reg [2:0] cmd_pipe [0:PIPE_DEPTH-1];
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            for (int i = 0; i < PIPE_DEPTH; i = i + 1)
                cmd_pipe[i] <= 3'd0;
        end else begin
            cmd_pipe[0] <= ctrl_valid_q ? ctrl_cmd_q : 3'd7;  // 无效标记
            for (int i = 1; i < PIPE_DEPTH; i = i + 1)
                cmd_pipe[i] <= cmd_pipe[i-1];
        end
    end
    wire cmd_is_acc = (cmd_pipe[PIPE_DEPTH-1] == 3'd2) || (cmd_pipe[PIPE_DEPTH-1] == 3'd3);
    assign sram_out_valid = (ch_out_valid[0] & cmd_is_acc) | ch_reciprocal_done[0];

    genvar ch;
    generate
        for (ch = 0; ch < NUM_CH; ch = ch + 1) begin : ACC_CH
            // 通道数据拆分（使用寄存后的信号）
            wire [31:0] sa_word   = sa_in_q[ch*DATA_WIDTH +: DATA_WIDTH];
            wire [31:0] sram_word = sram_in_q[ch*DATA_WIDTH +: DATA_WIDTH];

            // scale寄存器
            reg        scale_sign;
            reg [7:0]  scale_exp;
            reg [22:0] scale_mantissa;

            // FPAccUnit输出
            wire        acc_out_valid;
            wire        acc_out_sign;
            wire [7:0]  acc_out_exp;
            wire [22:0] acc_out_mantissa;
            wire        acc_recip_done;

            // FPAccUnit输入MUX（与原版Accumulator逻辑一致）
            // a: EXP_S1时用sa_in，否则用scale
            wire        in_a_sign     = exp_s1 ? sa_word[31]   : scale_sign;
            wire [7:0]  in_a_exp      = exp_s1 ? sa_word[30:23]: scale_exp;
            wire [22:0] in_a_mantissa = exp_s1 ? sa_word[22:0] : scale_mantissa;

            // b: EXP_S1时用log2e常量，否则用sram_in
            wire        in_b_sign     = ~exp_s1 & sram_word[31];
            wire [7:0]  in_b_exp      = exp_s1 ? LOG2E_EXP : sram_word[30:23];
            wire [22:0] in_b_mantissa = exp_s1 ? LOG2E_MAN : sram_word[22:0];

            // c: ACC_SA时用sa_in，否则为0
            wire        in_c_sign     = acc_sa & sa_word[31];
            wire [7:0]  in_c_exp      = acc_sa ? sa_word[30:23] : 8'h0;
            wire [22:0] in_c_mantissa = acc_sa ? sa_word[22:0]  : 23'h0;

            // scale更新pending标志：EXP_S1/S2命令发出后等待流水结果
            // 延迟深度 = PIPE_DEPTH（与FPAccUnit_pipe延迟对齐）
            reg [PIPE_DEPTH-1:0] scale_update_pipe;
            wire scale_update_pending = scale_update_pipe[PIPE_DEPTH-1];
            always_ff @(posedge clock) begin
                if (!rst_n)
                    scale_update_pipe <= '0;
                else begin
                    scale_update_pipe[0] <= ctrl_valid_q & (exp_s1 | exp_s2);
                    for (int j = 1; j < PIPE_DEPTH; j = j + 1)
                        scale_update_pipe[j] <= scale_update_pipe[j-1];
                end
            end

            // scale寄存器更新逻辑
            always_ff @(posedge clock) begin
                if (!rst_n) begin
                    scale_sign     <= 1'b0;
                    scale_exp      <= 8'h7F;   // 1.0的指数
                    scale_mantissa <= 23'h0;   // 1.0的尾数
                end else begin
                    if (acc_recip_done) begin
                        scale_sign     <= acc_out_sign;
                        scale_exp      <= acc_out_exp;
                        scale_mantissa <= acc_out_mantissa;
                    end else if (acc_out_valid & scale_update_pending) begin
                        scale_sign     <= acc_out_sign;
                        scale_exp      <= acc_out_exp;
                        scale_mantissa <= acc_out_mantissa;
                    end else if (ctrl_valid_q & set_cmd) begin
                        scale_sign     <= sram_word[31];
                        scale_exp      <= sram_word[30:23];
                        scale_mantissa <= sram_word[22:0];
                    end
                end
            end

            // FPAccUnit_pipe例化（4拍流水）
            FPAccUnit_pipe u_acc (
                .clock                             (clock),
                .rst_n                             (rst_n),
                .io_in_valid                       (ctrl_valid_q),
                .io_in_a_sign                      (in_a_sign),
                .io_in_a_exp                       (in_a_exp),
                .io_in_a_mantissa                  (in_a_mantissa),
                .io_in_b_sign                      (in_b_sign),
                .io_in_b_exp                       (in_b_exp),
                .io_in_b_mantissa                  (in_b_mantissa),
                .io_in_c_sign                      (in_c_sign),
                .io_in_c_exp                       (in_c_exp),
                .io_in_c_mantissa                  (in_c_mantissa),
                .io_in_cmd                         (exp_s2),
                .io_out_valid                      (acc_out_valid),
                .io_out_accType_sign               (acc_out_sign),
                .io_out_accType_exp                (acc_out_exp),
                .io_out_accType_mantissa           (acc_out_mantissa),
                .multiCycleIO_reciprocal_in_valid  (recip_cmd_q),
                .multiCycleIO_reciprocal_out_valid (acc_recip_done)
            );

            assign ch_reciprocal_done[ch] = acc_recip_done;
            assign ch_out_valid[ch] = acc_out_valid;

            // 输出：accUnit的结果
            assign sram_out[ch*DATA_WIDTH +: DATA_WIDTH] = {acc_out_sign, acc_out_exp, acc_out_mantissa};
        end
    endgenerate

    // 多通道同步断言：所有通道的out_valid和reciprocal_done应同步
    // synthesis translate_off
    always @(posedge clock) begin
        if (rst_n && |ch_out_valid)
            assert (ch_out_valid == {NUM_CH{ch_out_valid[0]}})
                else $error("ch_out_valid desync: %b", ch_out_valid);
        if (rst_n && |ch_reciprocal_done)
            assert (ch_reciprocal_done == {NUM_CH{ch_reciprocal_done[0]}})
                else $error("ch_reciprocal_done desync: %b", ch_reciprocal_done);
    end
    // synthesis translate_on

endmodule

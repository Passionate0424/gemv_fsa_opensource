`timescale 1ns / 1ps

module PE_retimed (
    input         clock,
    rst_n,
    mode_sel,
    io_in_ctrl_valid,
    io_in_ctrl_bits_mac,
    io_in_ctrl_bits_acc_ui,
    io_in_ctrl_bits_load_reg_li,
    io_in_ctrl_bits_load_reg_ui,
    io_in_ctrl_bits_flow_lr,
    io_in_ctrl_bits_flow_ud,
    io_in_ctrl_bits_flow_du,
    io_in_ctrl_bits_update_reg,
    io_in_ctrl_bits_exp2,
    input         io_u_input_bits_sign,
    input  [ 7:0] io_u_input_bits_exp,
    input  [22:0] io_u_input_bits_mantissa,
    output        io_u_output_valid,
    io_u_output_bits_sign,
    output [ 7:0] io_u_output_bits_exp,
    output [22:0] io_u_output_bits_mantissa,
    input         io_d_input_bits_sign,
    input  [ 7:0] io_d_input_bits_exp,
    input  [22:0] io_d_input_bits_mantissa,
    input  [31:0] io_partial_sum_in,
    input         io_rst_acc,
    output        io_d_output_valid,
    io_d_output_bits_sign,
    output [ 7:0] io_d_output_bits_exp,
    output [22:0] io_d_output_bits_mantissa,
    input         io_l_input_bits_sign,
    input  [ 7:0] io_l_input_bits_exp,
    input  [22:0] io_l_input_bits_mantissa,
    output        io_r_output_valid,
    io_r_output_bits_sign,
    output [ 7:0] io_r_output_bits_exp,
    output [22:0] io_r_output_bits_mantissa
);

    (* DONT_TOUCH = "TRUE" *) reg mode_q;
    wire os_mode;
    wire issue_mac_valid_ws;
    wire issue_mac_valid_os;
    wire issue_mac_valid;
    wire mac_commit_acc_ui;
    wire mac_commit_update_reg;
    wire mac_commit_exp2;
    wire os_commit_acc_ui;
    wire os_commit_update_reg;
    wire os_commit_exp2;
    wire mac_result_valid;
    wire mac_result_sign;
    wire [7:0] mac_result_exp;
    wire [22:0] mac_result_mantissa;
    wire mac_result_exp2;
    wire commit_to_u;
    wire commit_to_d;
    wire flow_to_u;
    wire flow_to_d;
    wire flow_to_r;
    wire mode_switch_idle;
    reg reg_sign;
    reg [7:0] reg_exp;
    reg [22:0] reg_mantissa;
    reg exp2_done_q;
    // flow bypass pipe寄存器
    reg flow_to_d_valid_q;
    reg flow_to_d_sign_q;
    reg [7:0] flow_to_d_exp_q;
    reg [22:0] flow_to_d_mantissa_q;
    reg flow_to_u_valid_q;
    reg flow_to_u_sign_q;
    reg [7:0] flow_to_u_exp_q;
    reg [22:0] flow_to_u_mantissa_q;
    // OS模式S0延迟的valid信号
    reg issue_mac_valid_os_q;
    reg issue_mac_valid_ws_q;
    // 扩展到6-bit: OS模式需要5级shift（S1~S5），FSA模式用前3级（S1~S3）
    // 四条链全部钉在带复位的触发器上。mac_valid_pipe 被 mac_pipe_busy 多点抽头、
    // 本来就推不成 SRL；另外三条属性链只有单点抽头，实测会被推成 SRL2（无复位端），
    // 它们直接决定 commit 走 U 还是 D、要不要更新寄存器，随机初值等于一次伪提交。
    (* srl_style = "register" *)
    reg [5:0] mac_valid_pipe;
    (* srl_style = "register" *)
    reg [5:0] mac_acc_ui_pipe;
    (* srl_style = "register" *)
    reg [5:0] mac_update_reg_pipe;
    (* srl_style = "register" *)
    reg [5:0] mac_exp2_pipe;
    // S0阶段寄存的WS控制属性
    reg s0_acc_ui_q, s0_update_reg_q, s0_exp2_q;

    // mac_pipe_busy: OS模式检查[5:0]（6级），FSA模式检查[3:0]（4级，关bypass后+1）
    wire mac_pipe_busy = os_mode ? |mac_valid_pipe[5:0] : |mac_valid_pipe[3:0];

    wire [31:0] reg_word = {reg_sign, reg_exp, reg_mantissa};
    wire [31:0] l_word = {io_l_input_bits_sign, io_l_input_bits_exp, io_l_input_bits_mantissa};
    wire [31:0] u_word = {io_u_input_bits_sign, io_u_input_bits_exp, io_u_input_bits_mantissa};
    wire [31:0] d_word = {io_d_input_bits_sign, io_d_input_bits_exp, io_d_input_bits_mantissa};
    wire [31:0] psum_word = io_partial_sum_in;
    wire os_seed_acc = os_mode & io_rst_acc;

    // WS模式数据延迟链
    reg [31:0] ws_b_pipe0;
    reg [31:0] ws_c_pipe0;
    reg [31:0] ws_c_pipe1;
    reg [31:0] ws_c_pipe2;

    // OS模式 S0 输入寄存
    reg [31:0] os_a_q;
    reg [31:0] os_b_q;

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            ws_b_pipe0 <= 32'h0;
            ws_c_pipe0 <= 32'h0;
            ws_c_pipe1 <= 32'h0;
            ws_c_pipe2 <= 32'h0;
            os_a_q <= 32'h0;
            os_b_q <= 32'h0;
        end else begin
            if (os_mode & issue_mac_valid_os) begin
                os_a_q <= l_word;
                os_b_q <= u_word;
            end
            if (!os_mode & issue_mac_valid_ws) begin
                ws_b_pipe0 <= l_word;
                ws_c_pipe0 <= io_in_ctrl_bits_acc_ui ? u_word : d_word;
            end
            ws_c_pipe1 <= ws_c_pipe0;
            ws_c_pipe2 <= ws_c_pipe1;
        end
    end

    // acc_reg = mac_result（组合逻辑，反馈值自然是y[n-2]因为环路有R1+R2）
    wire [31:0] acc_reg = {mac_result_sign, mac_result_exp, mac_result_mantissa};

    // OS模式: c = rst_acc时装入psum_word，否则用acc_reg
    wire [31:0] os_c_word = io_rst_acc ? psum_word : acc_reg;

    wire [31:0] os_a_word = os_a_q;
    wire [31:0] os_b_word = os_b_q;
    wire [31:0] ws_a_word = reg_word;
    wire [31:0] ws_b_word = ws_b_pipe0;
    wire [31:0] ws_c_word = ws_c_pipe2;
    wire [31:0] mac_a_word = os_mode ? os_a_word : ws_a_word;
    wire [31:0] mac_b_word = os_mode ? os_b_word : ws_b_word;
    wire [31:0] mac_c_word = os_mode ? os_c_word : ws_c_word;
    wire mac_cmd = os_mode ? 1'b0 : s0_exp2_q;

    assign os_mode = mode_q;
    assign issue_mac_valid_ws = io_in_ctrl_valid & (io_in_ctrl_bits_mac | io_in_ctrl_bits_exp2);
    assign issue_mac_valid_os = io_in_ctrl_valid;
    assign issue_mac_valid = os_mode ? issue_mac_valid_os_q : issue_mac_valid_ws_q;

    assign os_commit_acc_ui = 1'b0;
    assign os_commit_update_reg = 1'b1;
    assign os_commit_exp2 = 1'b0;
    // commit属性: OS模式用pipe[4]对应的属性，FSA模式用pipe[3]
    // FSA MAC延迟5拍(关bypass后fpadd走满2级)：输入寄存1 + mul×2 + fpadd×2，commit锚pipe[3]
    assign mac_commit_acc_ui = os_mode ? os_commit_acc_ui :
        mac_acc_ui_pipe[3];
    assign mac_commit_update_reg = os_mode ? os_commit_update_reg :
        mac_update_reg_pipe[3];
    assign mac_commit_exp2 = os_mode ? os_commit_exp2 :
        mac_exp2_pipe[3];
    assign mode_switch_idle = !mac_pipe_busy && (mode_q != mode_sel);

    // commit点: OS模式pipe[5]，FSA模式pipe[3]（关bypass后fpadd 2级，延迟+1）
    wire mac_commit_point = os_mode ? mac_valid_pipe[5] : mac_valid_pipe[3];
    assign commit_to_u = mac_commit_point & ~mac_commit_acc_ui;
    assign commit_to_d = mac_commit_point & mac_commit_acc_ui;
    assign flow_to_u = os_mode ? 1'b0 : io_in_ctrl_valid & io_in_ctrl_bits_flow_du;
    assign flow_to_d = os_mode ? 1'b0 : io_in_ctrl_valid & io_in_ctrl_bits_flow_ud;
    assign flow_to_r = os_mode ? 1'b0 :
        io_in_ctrl_valid & (io_in_ctrl_bits_load_reg_li | io_in_ctrl_bits_flow_lr);

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            mode_q              <= 1'b0;
            mac_valid_pipe      <= 6'h0;
            mac_acc_ui_pipe     <= 6'h0;
            mac_update_reg_pipe <= 6'h0;
            mac_exp2_pipe       <= 6'h0;
        end
        else begin
            if (!mac_pipe_busy) begin
                mode_q <= mode_sel;
            end
            mac_valid_pipe <= {mac_valid_pipe[4:0], issue_mac_valid};
            mac_acc_ui_pipe <= {mac_acc_ui_pipe[4:0], issue_mac_valid & s0_acc_ui_q};
            mac_update_reg_pipe <= {
                mac_update_reg_pipe[4:0], issue_mac_valid & s0_update_reg_q
            };
            mac_exp2_pipe <= {mac_exp2_pipe[4:0], issue_mac_valid & s0_exp2_q};
        end
    end

    reg os_seed_acc_q;
    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            os_seed_acc_q <= 1'b0;
        end
        else begin
            os_seed_acc_q <= io_rst_acc;
        end
    end

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            issue_mac_valid_os_q <= 1'b0;
            issue_mac_valid_ws_q <= 1'b0;
            s0_acc_ui_q          <= 1'b0;
            s0_update_reg_q      <= 1'b0;
            s0_exp2_q            <= 1'b0;
        end
        else begin
            issue_mac_valid_os_q <= issue_mac_valid_os;
            issue_mac_valid_ws_q <= issue_mac_valid_ws;
            s0_acc_ui_q     <= issue_mac_valid_ws & io_in_ctrl_bits_acc_ui;
            s0_update_reg_q <= issue_mac_valid_ws & io_in_ctrl_bits_update_reg;
            s0_exp2_q       <= issue_mac_valid_ws & io_in_ctrl_bits_exp2;
        end
    end

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            reg_sign     <= 1'b0;
            reg_exp      <= 8'h00;
            reg_mantissa <= 23'h0;
            exp2_done_q     <= 1'b0;
        end
        else begin
            if (os_seed_acc) begin
                reg_sign     <= io_partial_sum_in[31];
                reg_exp      <= io_partial_sum_in[30:23];
                reg_mantissa <= io_partial_sum_in[22:0];
                exp2_done_q     <= 1'b0;
            end
            else if (!os_mode && io_in_ctrl_valid && io_in_ctrl_bits_load_reg_li) begin
                reg_sign     <= io_l_input_bits_sign;
                reg_exp      <= io_l_input_bits_exp;
                reg_mantissa <= io_l_input_bits_mantissa;
                exp2_done_q     <= 1'b0;
            end
            else if (!os_mode && io_in_ctrl_valid && io_in_ctrl_bits_load_reg_ui) begin
                reg_sign     <= flow_to_d_sign_q;
                reg_exp      <= flow_to_d_exp_q;
                reg_mantissa <= flow_to_d_mantissa_q;
                exp2_done_q     <= 1'b0;
            end
            else if (mac_result_valid) begin
                if (mac_commit_update_reg || (mac_commit_exp2 & mac_result_exp2 & ~exp2_done_q)) begin
                    reg_sign     <= mac_result_sign;
                    reg_exp      <= mac_result_exp;
                    reg_mantissa <= (mac_result_exp == 8'h0) ? 23'h0 : mac_result_mantissa;
                end
                if (mac_commit_exp2) begin
                    exp2_done_q <= exp2_done_q | mac_result_exp2;
                end
                else begin
                    exp2_done_q <= 1'b0;
                end
            end
            else if (mode_switch_idle) begin
                reg_sign     <= 1'b0;
                reg_exp      <= 8'h00;
                reg_mantissa <= 23'h0;
                exp2_done_q     <= 1'b0;
            end
        end
    end

    initial begin
        reg_sign              = 1'b0;
        reg_exp               = 8'h00;
        reg_mantissa          = 23'h0;
        exp2_done_q              = 1'b0;
        flow_to_d_valid_q     = 1'b0;
        flow_to_d_sign_q      = 1'b0;
        flow_to_d_exp_q       = 8'h0;
        flow_to_d_mantissa_q  = 23'h0;
        flow_to_u_valid_q     = 1'b0;
        flow_to_u_sign_q      = 1'b0;
        flow_to_u_exp_q       = 8'h0;
        flow_to_u_mantissa_q  = 23'h0;
        issue_mac_valid_os_q  = 1'b0;
        issue_mac_valid_ws_q  = 1'b0;
        mode_q                = 1'b0;
        mac_valid_pipe        = 6'h0;
        mac_acc_ui_pipe       = 6'h0;
        mac_update_reg_pipe   = 6'h0;
        mac_exp2_pipe         = 6'h0;
        ws_b_pipe0            = 32'h0;
        ws_c_pipe0            = 32'h0;
        ws_c_pipe1            = 32'h0;
        ws_c_pipe2            = 32'h0;
        os_a_q              = 32'h0;
        os_b_q              = 32'h0;
    end

    // ============================================================
    // 超前计算: fp_pre_add（环外预求和）
    // ============================================================
    wire [31:0] mul_out_exposed;
    wire [31:0] pre_add_result;

    fp_pre_add u_pre_add (
        .clock        (clock),
        .rst_n        (rst_n),
        .mul_out      (mul_out_exposed),
        .mul_out_valid(mac_valid_pipe[1]),  // mul完成时刻（pipe[1]=S2 valid）
        .os_mode      (os_mode),
        .rst_acc      (os_seed_acc_q),
        .pre_add_out  (pre_add_result)
    );

    // load_init: rst_acc延迟2拍（S0延迟1拍 + pre_add占1拍后，对齐加法器输入时刻）
    reg os_seed_acc_q2;
    always @(posedge clock or negedge rst_n) begin
        if (!rst_n)
            os_seed_acc_q2 <= 1'b0;
        else
            os_seed_acc_q2 <= os_seed_acc_q;
    end

    // ============================================================
    // FPMacUnit例化（含超前计算端口）
    // ============================================================
    FPMacUnit_pipe macUnit (
        .clock                   (clock),
        .rst_n                   (rst_n),
        .io_in_valid             (issue_mac_valid),
        .io_in_a_sign            (mac_a_word[31]),
        .io_in_a_exp             (mac_a_word[30:23]),
        .io_in_a_mantissa        (mac_a_word[22:0]),
        .io_in_b_sign            (mac_b_word[31]),
        .io_in_b_exp             (mac_b_word[30:23]),
        .io_in_b_mantissa        (mac_b_word[22:0]),
        .io_in_c_sign            (mac_c_word[31]),
        .io_in_c_exp             (mac_c_word[30:23]),
        .io_in_c_mantissa        (mac_c_word[22:0]),
        .io_in_cmd               (mac_cmd),
        // 超前计算端口
        .bypass_s1               (1'b0),             // 两模式都走R1（FSA加法器双周期化，时序优化）
        .use_pre_add             (os_mode),          // OS模式用pre_add
        .pre_add_in              (pre_add_result),   // 预求和结果
        .init_val                (psum_word),        // 累加器初始值
        .load_init               (os_seed_acc_q2 & os_mode),   // 仅OS模式加载初始值
        .mul_out_port            (mul_out_exposed),  // 暴露mul_out
        // 原有输出
        .io_out_valid            (mac_result_valid),
        .io_out_sign     (mac_result_sign),
        .io_out_exp      (mac_result_exp),
        .io_out_mantissa (mac_result_mantissa),
        .io_out_exp2             (mac_result_exp2)
    );

    // flow bypass路径寄存器
    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            flow_to_d_valid_q    <= 1'b0;
            flow_to_d_sign_q     <= 1'b0;
            flow_to_d_exp_q      <= 8'h0;
            flow_to_d_mantissa_q <= 23'h0;
            flow_to_u_valid_q    <= 1'b0;
            flow_to_u_sign_q     <= 1'b0;
            flow_to_u_exp_q      <= 8'h0;
            flow_to_u_mantissa_q <= 23'h0;
        end else begin
            flow_to_d_valid_q    <= flow_to_d;
            flow_to_u_valid_q    <= flow_to_u;
            flow_to_d_sign_q     <= io_u_input_bits_sign;
            flow_to_d_exp_q      <= io_u_input_bits_exp;
            flow_to_d_mantissa_q <= io_u_input_bits_mantissa;
            flow_to_u_sign_q     <= io_d_input_bits_sign;
            flow_to_u_exp_q      <= io_d_input_bits_exp;
            flow_to_u_mantissa_q <= io_d_input_bits_mantissa;
        end
    end

    assign io_u_output_valid = commit_to_u | flow_to_u_valid_q;
    assign io_u_output_bits_sign = commit_to_u ? mac_result_sign : flow_to_u_sign_q;
    assign io_u_output_bits_exp = commit_to_u ? mac_result_exp : flow_to_u_exp_q;
    assign io_u_output_bits_mantissa = commit_to_u ? mac_result_mantissa :
        flow_to_u_mantissa_q;

    assign io_d_output_valid = commit_to_d | flow_to_d_valid_q;
    assign io_d_output_bits_sign = commit_to_d ? mac_result_sign : flow_to_d_sign_q;
    assign io_d_output_bits_exp = commit_to_d ? mac_result_exp : flow_to_d_exp_q;
    assign io_d_output_bits_mantissa = commit_to_d ? mac_result_mantissa :
        flow_to_d_mantissa_q;

    wire os_r_commit = os_mode & mac_result_valid;
    assign io_r_output_valid = os_r_commit | flow_to_r;
    assign io_r_output_bits_sign = os_r_commit ? mac_result_sign :
        (io_in_ctrl_bits_load_reg_li ? reg_sign : io_l_input_bits_sign);
    assign io_r_output_bits_exp = os_r_commit ? mac_result_exp :
        (io_in_ctrl_bits_load_reg_li ? reg_exp : io_l_input_bits_exp);
    assign io_r_output_bits_mantissa = os_r_commit ? mac_result_mantissa :
        (io_in_ctrl_bits_load_reg_li ? reg_mantissa : io_l_input_bits_mantissa);

endmodule

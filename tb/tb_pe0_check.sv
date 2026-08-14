`timescale 1ns/1ps

////////////////////////////////////////////////////////////////
// tb_pe0_check
//
// PE_retimed 的定点检查TB
// 直接观察单个 PE 的寄存器与输出，验证 load_reg / flow 路径
// 在特定激励下是否正确更新。
//
// 适合快速确认单点行为，不作为大回归入口。
////////////////////////////////////////////////////////////////
module tb_pe0_check;
    logic clk=0; always #1 clk=~clk;
    logic rstn=0;
    logic ctrl_valid, ctrl_mac, ctrl_acc_ui, ctrl_load_reg_li, ctrl_load_reg_ui;
    logic ctrl_flow_lr, ctrl_flow_ud, ctrl_flow_du, ctrl_update_reg, ctrl_exp2;
    logic [31:0] u_word, l_word, d_word;
    wire [31:0] pe_reg;

    PE_retimed u_pe (
        .clock(clk), .rst_n(rstn), .mode_sel(1'b0),
        .io_in_ctrl_valid(ctrl_valid),
        .io_in_ctrl_bits_mac(ctrl_mac), .io_in_ctrl_bits_acc_ui(ctrl_acc_ui),
        .io_in_ctrl_bits_load_reg_li(ctrl_load_reg_li), .io_in_ctrl_bits_load_reg_ui(ctrl_load_reg_ui),
        .io_in_ctrl_bits_flow_lr(ctrl_flow_lr), .io_in_ctrl_bits_flow_ud(ctrl_flow_ud),
        .io_in_ctrl_bits_flow_du(ctrl_flow_du), .io_in_ctrl_bits_update_reg(ctrl_update_reg),
        .io_in_ctrl_bits_exp2(ctrl_exp2),
        .io_u_input_bits_sign(u_word[31]), .io_u_input_bits_exp(u_word[30:23]), .io_u_input_bits_mantissa(u_word[22:0]),
        .io_d_input_bits_sign(d_word[31]), .io_d_input_bits_exp(d_word[30:23]), .io_d_input_bits_mantissa(d_word[22:0]),
        .io_l_input_bits_sign(l_word[31]), .io_l_input_bits_exp(l_word[30:23]), .io_l_input_bits_mantissa(l_word[22:0]),
        .io_u_output_valid(), .io_u_output_bits_sign(), .io_u_output_bits_exp(), .io_u_output_bits_mantissa(),
        .io_d_output_valid(), .io_d_output_bits_sign(), .io_d_output_bits_exp(), .io_d_output_bits_mantissa(),
        .io_partial_sum_in(32'h0), .io_rst_acc(1'b0),
        .io_out_ctrl_valid(), .io_out_ctrl_bits_mac(), .io_out_ctrl_bits_acc_ui(),
        .io_out_ctrl_bits_load_reg_li(), .io_out_ctrl_bits_load_reg_ui(),
        .io_out_ctrl_bits_flow_lr(), .io_out_ctrl_bits_flow_ud(), .io_out_ctrl_bits_flow_du(),
        .io_out_ctrl_bits_update_reg(), .io_out_ctrl_bits_exp2(),
        .io_r_output_valid(), .io_r_output_bits_sign(), .io_r_output_bits_exp(), .io_r_output_bits_mantissa()
    );

    assign pe_reg = {u_pe.reg_sign, u_pe.reg_exp, u_pe.reg_mantissa};

    initial begin
        ctrl_valid=0; ctrl_mac=0; ctrl_acc_ui=0; ctrl_load_reg_li=0; ctrl_load_reg_ui=0;
        ctrl_flow_lr=0; ctrl_flow_ud=0; ctrl_flow_du=0; ctrl_update_reg=0; ctrl_exp2=0;
        u_word=0; l_word=0; d_word=0;
        rstn=0; #10; rstn=1;
        repeat(3) @(posedge clk);

        // Check os_mode
        $display("os_mode=%b mode_q=%b", u_pe.os_mode, u_pe.mode_q);

        // Step 1: flow_ud with score=36.0 on u_input (simulates SCORE_RESTREAM)
        u_word = 32'h42100000;
        ctrl_valid=1; ctrl_flow_ud=1;
        @(posedge clk); #1ps;
        $display("During flow_ud: flow_to_d=%b u_word=%08h", u_pe.flow_to_d, u_word);
        @(posedge clk); #1ps;
        ctrl_valid=0; ctrl_flow_ud=0; u_word=0;
        $display("After flow_ud posedge: ftd_valid_q=%b ftd_sign=%b ftd_exp=%08h ftd_mant=%06h pe_reg=%08h",
            u_pe.flow_to_d_valid_q, u_pe.flow_to_d_sign_q, u_pe.flow_to_d_exp_q, u_pe.flow_to_d_mantissa_q, pe_reg);
        @(posedge clk); #1ps;

        // Step 2: load_reg_ui
        ctrl_valid=1; ctrl_load_reg_ui=1;
        @(posedge clk); #1ps;
        $display("During load_reg_ui: ctrl_valid=%b load_reg_ui=%b os_mode=%b",
            ctrl_valid, ctrl_load_reg_ui, u_pe.os_mode);
        ctrl_valid=0; ctrl_load_reg_ui=0;
        @(posedge clk); #1ps;

        $display("After load_reg_ui: pe_reg=%08h", pe_reg);

        if (pe_reg == 32'h42100000)
            $display("PASS: load_reg_ui correctly loaded score from flow_to_d_q");
        else
            $display("FAIL: pe_reg=%08h, expected 42100000", pe_reg);

        $finish;
    end
endmodule

`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// tb_pe_triplet_compare
//
// PE_retimed / 旧版 PE / 新版 MAC 的三方对比TB
// 在相同激励下比较三条实现路径的输出与内部阶段结果，
// 用于确认 retimed 版本与 legacy / new 实现之间的一致性。
//
// 适合做结构重构后的等价性回归。
////////////////////////////////////////////////////////////////
module tb_pe_triplet_compare;
    localparam int OS_LEN = 12;
    localparam int WS_LEN = 8;

    logic clk = 1'b0;
    always #1 clk = ~clk;

    logic        rstn = 1'b0;
    logic        pe_mode_sel = 1'b0;
    int unsigned cycle = 0;
    always @(posedge clk) cycle <= cycle + 1;

    initial begin
        if (!$test$plusargs("NO_WAVE")) begin
            $fsdbDumpfile("tb_pe_triplet_compare.fsdb");
            $fsdbDumpvars(0, tb_pe_triplet_compare);
        end
    end

    logic        ret_valid;
    logic        ret_mac;
    logic        ret_acc_ui;
    logic        ret_load_reg_li;
    logic        ret_load_reg_ui;
    logic        ret_flow_lr;
    logic        ret_flow_ud;
    logic        ret_flow_du;
    logic        ret_update_reg;
    logic        ret_exp2;
    logic        ret_rst_acc;

    logic        ret_u_sign;
    logic [ 7:0] ret_u_exp;
    logic [22:0] ret_u_man;
    logic        ret_d_sign;
    logic [ 7:0] ret_d_exp;
    logic [22:0] ret_d_man;
    logic        ret_l_sign;
    logic [ 7:0] ret_l_exp;
    logic [22:0] ret_l_man;

    logic        leg_valid;
    logic        leg_mac;
    logic        leg_acc_ui;
    logic        leg_load_reg_li;
    logic        leg_load_reg_ui;
    logic        leg_flow_lr;
    logic        leg_flow_ud;
    logic        leg_flow_du;
    logic        leg_update_reg;
    logic        leg_exp2;

    logic        leg_u_sign;
    logic [ 7:0] leg_u_exp;
    logic [22:0] leg_u_man;
    logic        leg_d_sign;
    logic [ 7:0] leg_d_exp;
    logic [22:0] leg_d_man;
    logic        leg_l_sign;
    logic [ 7:0] leg_l_exp;
    logic [22:0] leg_l_man;

    logic        new_en;
    logic        new_rst_acc;
    logic [31:0] new_weight_in;
    logic [31:0] new_vec_in;
    logic [31:0] new_partial_sum_in;
    wire  [31:0] new_result;
    logic [31:0] ret_partial_sum_in;

    wire         ret_u_valid;
    wire         ret_u_sign_o;
    wire  [ 7:0] ret_u_exp_o;
    wire  [22:0] ret_u_man_o;
    wire         ret_out_ctrl_valid;
    wire         ret_out_ctrl_mac;
    wire         ret_out_ctrl_acc_ui;
    wire         ret_out_ctrl_load_reg_li;
    wire         ret_out_ctrl_load_reg_ui;
    wire         ret_out_ctrl_flow_lr;
    wire         ret_out_ctrl_flow_ud;
    wire         ret_out_ctrl_flow_du;
    wire         ret_out_ctrl_update_reg;
    wire         ret_out_ctrl_exp2;
    wire         ret_d_valid;
    wire         ret_d_sign_o;
    wire  [ 7:0] ret_d_exp_o;
    wire  [22:0] ret_d_man_o;
    wire         ret_r_valid;
    wire         ret_r_sign_o;
    wire  [ 7:0] ret_r_exp_o;
    wire  [22:0] ret_r_man_o;

    wire         leg_u_valid;
    wire         leg_u_sign_o;
    wire  [ 7:0] leg_u_exp_o;
    wire  [22:0] leg_u_man_o;
    wire         leg_out_ctrl_valid;
    wire         leg_out_ctrl_mac;
    wire         leg_out_ctrl_acc_ui;
    wire         leg_out_ctrl_load_reg_li;
    wire         leg_out_ctrl_load_reg_ui;
    wire         leg_out_ctrl_flow_lr;
    wire         leg_out_ctrl_flow_ud;
    wire         leg_out_ctrl_flow_du;
    wire         leg_out_ctrl_update_reg;
    wire         leg_out_ctrl_exp2;
    wire         leg_d_valid;
    wire         leg_d_sign_o;
    wire  [ 7:0] leg_d_exp_o;
    wire  [22:0] leg_d_man_o;
    wire         leg_r_valid;
    wire         leg_r_sign_o;
    wire  [ 7:0] leg_r_exp_o;
    wire  [22:0] leg_r_man_o;

    PE_retimed dut_retimed (
        .clock                       (clk),
        .rstn                        (rstn),
        .mode_sel                    (pe_mode_sel),
        .io_in_ctrl_valid            (ret_valid),
        .io_in_ctrl_bits_mac         (ret_mac),
        .io_in_ctrl_bits_acc_ui      (ret_acc_ui),
        .io_in_ctrl_bits_load_reg_li (ret_load_reg_li),
        .io_in_ctrl_bits_load_reg_ui (ret_load_reg_ui),
        .io_in_ctrl_bits_flow_lr     (ret_flow_lr),
        .io_in_ctrl_bits_flow_ud     (ret_flow_ud),
        .io_in_ctrl_bits_flow_du     (ret_flow_du),
        .io_in_ctrl_bits_update_reg  (ret_update_reg),
        .io_in_ctrl_bits_exp2        (ret_exp2),
        .io_out_ctrl_valid           (ret_out_ctrl_valid),
        .io_out_ctrl_bits_mac        (ret_out_ctrl_mac),
        .io_out_ctrl_bits_acc_ui     (ret_out_ctrl_acc_ui),
        .io_out_ctrl_bits_load_reg_li(ret_out_ctrl_load_reg_li),
        .io_out_ctrl_bits_load_reg_ui(ret_out_ctrl_load_reg_ui),
        .io_out_ctrl_bits_flow_lr    (ret_out_ctrl_flow_lr),
        .io_out_ctrl_bits_flow_ud    (ret_out_ctrl_flow_ud),
        .io_out_ctrl_bits_flow_du    (ret_out_ctrl_flow_du),
        .io_out_ctrl_bits_update_reg (ret_out_ctrl_update_reg),
        .io_out_ctrl_bits_exp2       (ret_out_ctrl_exp2),
        .io_u_input_bits_sign        (ret_u_sign),
        .io_u_input_bits_exp         (ret_u_exp),
        .io_u_input_bits_mantissa    (ret_u_man),
        .io_u_output_valid           (ret_u_valid),
        .io_u_output_bits_sign       (ret_u_sign_o),
        .io_u_output_bits_exp        (ret_u_exp_o),
        .io_u_output_bits_mantissa   (ret_u_man_o),
        .io_d_input_bits_sign        (ret_d_sign),
        .io_d_input_bits_exp         (ret_d_exp),
        .io_d_input_bits_mantissa    (ret_d_man),
        .io_partial_sum_in           (ret_partial_sum_in),
        .io_rst_acc                  (ret_rst_acc),
        .io_d_output_valid           (ret_d_valid),
        .io_d_output_bits_sign       (ret_d_sign_o),
        .io_d_output_bits_exp        (ret_d_exp_o),
        .io_d_output_bits_mantissa   (ret_d_man_o),
        .io_l_input_bits_sign        (ret_l_sign),
        .io_l_input_bits_exp         (ret_l_exp),
        .io_l_input_bits_mantissa    (ret_l_man),
        .io_r_output_valid           (ret_r_valid),
        .io_r_output_bits_sign       (ret_r_sign_o),
        .io_r_output_bits_exp        (ret_r_exp_o),
        .io_r_output_bits_mantissa   (ret_r_man_o)
    );

    PE dut_legacy (
        .clock                       (clk),
        .io_in_ctrl_valid            (leg_valid),
        .io_in_ctrl_bits_mac         (leg_mac),
        .io_in_ctrl_bits_acc_ui      (leg_acc_ui),
        .io_in_ctrl_bits_load_reg_li (leg_load_reg_li),
        .io_in_ctrl_bits_load_reg_ui (leg_load_reg_ui),
        .io_in_ctrl_bits_flow_lr     (leg_flow_lr),
        .io_in_ctrl_bits_flow_ud     (leg_flow_ud),
        .io_in_ctrl_bits_flow_du     (leg_flow_du),
        .io_in_ctrl_bits_update_reg  (leg_update_reg),
        .io_in_ctrl_bits_exp2        (leg_exp2),
        .io_out_ctrl_valid           (leg_out_ctrl_valid),
        .io_out_ctrl_bits_mac        (leg_out_ctrl_mac),
        .io_out_ctrl_bits_acc_ui     (leg_out_ctrl_acc_ui),
        .io_out_ctrl_bits_load_reg_li(leg_out_ctrl_load_reg_li),
        .io_out_ctrl_bits_load_reg_ui(leg_out_ctrl_load_reg_ui),
        .io_out_ctrl_bits_flow_lr    (leg_out_ctrl_flow_lr),
        .io_out_ctrl_bits_flow_ud    (leg_out_ctrl_flow_ud),
        .io_out_ctrl_bits_flow_du    (leg_out_ctrl_flow_du),
        .io_out_ctrl_bits_update_reg (leg_out_ctrl_update_reg),
        .io_out_ctrl_bits_exp2       (leg_out_ctrl_exp2),
        .io_u_input_bits_sign        (leg_u_sign),
        .io_u_input_bits_exp         (leg_u_exp),
        .io_u_input_bits_mantissa    (leg_u_man),
        .io_u_output_valid           (leg_u_valid),
        .io_u_output_bits_sign       (leg_u_sign_o),
        .io_u_output_bits_exp        (leg_u_exp_o),
        .io_u_output_bits_mantissa   (leg_u_man_o),
        .io_d_input_bits_sign        (leg_d_sign),
        .io_d_input_bits_exp         (leg_d_exp),
        .io_d_input_bits_mantissa    (leg_d_man),
        .io_d_output_valid           (leg_d_valid),
        .io_d_output_bits_sign       (leg_d_sign_o),
        .io_d_output_bits_exp        (leg_d_exp_o),
        .io_d_output_bits_mantissa   (leg_d_man_o),
        .io_l_input_bits_sign        (leg_l_sign),
        .io_l_input_bits_exp         (leg_l_exp),
        .io_l_input_bits_mantissa    (leg_l_man),
        .io_r_output_valid           (leg_r_valid),
        .io_r_output_bits_sign       (leg_r_sign_o),
        .io_r_output_bits_exp        (leg_r_exp_o),
        .io_r_output_bits_mantissa   (leg_r_man_o)
    );

    fp_mac_pipelined_acc_new dut_new (
        .clk           (clk),
        .rstn          (rstn),
        .en            (new_en),
        .rst_acc       (new_rst_acc),
        .weight_in     (new_weight_in),
        .vec_in        (new_vec_in),
        .partial_sum_in(new_partial_sum_in),
        .vec_out       (),
        .result        (new_result)
    );

    function automatic bit is_fp32_nan(input logic [31:0] w);
        return (w[30:23] == 8'hFF) && (w[22:0] != 23'h0);
    endfunction

    function automatic bit is_fp32_inf(input logic [31:0] w);
        return (w[30:23] == 8'hFF) && (w[22:0] == 23'h0);
    endfunction

    function automatic logic [31:0] sw_mac32(input logic [31:0] a_bits, input logic [31:0] b_bits,
                                             input logic [31:0] c_bits);
        shortreal        a_sr;
        shortreal        b_sr;
        shortreal        c_sr;
        shortreal        y_sr;
        logic     [31:0] result;
        logic            prod_sign;
        begin
            if (is_fp32_nan(a_bits) || is_fp32_nan(b_bits) || is_fp32_nan(c_bits)) begin
                result = 32'h7fc00000;
            end
            else if (is_fp32_inf(a_bits) || is_fp32_inf(b_bits)) begin
                prod_sign = a_bits[31] ^ b_bits[31];
                if (is_fp32_inf(c_bits) && (c_bits[31] != prod_sign)) begin
                    result = 32'h7fc00000;
                end
                else begin
                    result = {prod_sign, 8'hFF, 23'h0};
                end
            end
            else if (is_fp32_inf(c_bits)) begin
                result = {c_bits[31], 8'hFF, 23'h0};
            end
            else begin
                a_sr   = $bitstoshortreal(a_bits);
                b_sr   = $bitstoshortreal(b_bits);
                c_sr   = $bitstoshortreal(c_bits);
                y_sr   = a_sr * b_sr + c_sr;
                result = $shortrealtobits(y_sr);
                if (is_fp32_nan(result)) begin
                    result = 32'h7fc00000;
                end
            end
            sw_mac32 = result;
        end
    endfunction

    function automatic logic [31:0] ret_u_word();
        ret_u_word = {ret_u_sign_o, ret_u_exp_o, ret_u_man_o};
    endfunction

    function automatic logic [31:0] leg_u_word();
        leg_u_word = {leg_u_sign_o, leg_u_exp_o, leg_u_man_o};
    endfunction

    function automatic logic [31:0] leg_d_word();
        leg_d_word = {leg_d_sign_o, leg_d_exp_o, leg_d_man_o};
    endfunction

    function automatic logic [31:0] ret_d_word();
        ret_d_word = {ret_d_sign_o, ret_d_exp_o, ret_d_man_o};
    endfunction

    function automatic logic [31:0] ret_r_word();
        ret_r_word = {ret_r_sign_o, ret_r_exp_o, ret_r_man_o};
    endfunction

    function automatic logic [31:0] leg_r_word();
        leg_r_word = {leg_r_sign_o, leg_r_exp_o, leg_r_man_o};
    endfunction

    task automatic drive_idle();
        begin
            ret_valid          = 1'b0;
            ret_mac            = 1'b0;
            ret_acc_ui         = 1'b0;
            ret_load_reg_li    = 1'b0;
            ret_load_reg_ui    = 1'b0;
            ret_flow_lr        = 1'b0;
            ret_flow_ud        = 1'b0;
            ret_flow_du        = 1'b0;
            ret_update_reg     = 1'b0;
            ret_exp2           = 1'b0;
            ret_rst_acc        = 1'b0;
            ret_u_sign         = 1'b0;
            ret_u_exp          = 8'h00;
            ret_u_man          = 23'h0;
            ret_d_sign         = 1'b0;
            ret_d_exp          = 8'h00;
            ret_d_man          = 23'h0;
            ret_l_sign         = 1'b0;
            ret_l_exp          = 8'h00;
            ret_l_man          = 23'h0;
            ret_partial_sum_in = 32'h0;

            leg_valid          = 1'b0;
            leg_mac            = 1'b0;
            leg_acc_ui         = 1'b0;
            leg_load_reg_li    = 1'b0;
            leg_load_reg_ui    = 1'b0;
            leg_flow_lr        = 1'b0;
            leg_flow_ud        = 1'b0;
            leg_flow_du        = 1'b0;
            leg_update_reg     = 1'b0;
            leg_exp2           = 1'b0;
            leg_u_sign         = 1'b0;
            leg_u_exp          = 8'h00;
            leg_u_man          = 23'h0;
            leg_d_sign         = 1'b0;
            leg_d_exp          = 8'h00;
            leg_d_man          = 23'h0;
            leg_l_sign         = 1'b0;
            leg_l_exp          = 8'h00;
            leg_l_man          = 23'h0;

            new_en             = 1'b0;
            new_rst_acc        = 1'b0;
            new_weight_in      = 32'h0;
            new_vec_in         = 32'h0;
            new_partial_sum_in = 32'h0;
        end
    endtask

    task automatic wait_cycles(input int n);
        int i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge clk);
        end
    endtask

    task automatic enter_mode(input bit os_mode);
        begin
            @(negedge clk);
            pe_mode_sel = os_mode;
            drive_idle();
            // 等待足够周期让mac_pipe排空并完成mode_q切换
            @(posedge clk);
            @(posedge clk);
            #1ps;
        end
    endtask

    function automatic logic is_close(logic [31:0] a, logic [31:0] b);
        logic [31:0] abs_a;
        logic [31:0] abs_b;
        int          diff;
        begin
            if (a === b) return 1'b1;
            abs_a = a & 32'h7FFFFFFF;
            abs_b = b & 32'h7FFFFFFF;
            if (a[31] != b[31]) begin
                diff = abs_a + abs_b;
            end
            else begin
                diff = (abs_a > abs_b) ? (abs_a - abs_b) : (abs_b - abs_a);
            end
            return (diff <= 2);
        end
    endfunction

    task automatic check_word(input string tag, input logic valid, input logic [31:0] got,
                              input logic [31:0] exp);
        begin
            if (!valid) begin
                $fatal(1, "[%s] valid dropped", tag);
            end
            if (!is_close(got, exp)) begin
                $fatal(1, "[%s] got=%08h exp=%08h", tag, got, exp);
            end
        end
    endtask

    task automatic check_ctrl_bits(
        input string tag,
        input logic valid,
        input logic mac,
        input logic acc_ui,
        input logic load_reg_li,
        input logic load_reg_ui,
        input logic flow_lr,
        input logic flow_ud,
        input logic flow_du,
        input logic update_reg,
        input logic exp2,
        input logic exp_valid,
        input logic exp_mac,
        input logic exp_acc_ui,
        input logic exp_load_reg_li,
        input logic exp_load_reg_ui,
        input logic exp_flow_lr,
        input logic exp_flow_ud,
        input logic exp_flow_du,
        input logic exp_update_reg,
        input logic exp_exp2
    );
        begin
            if (valid !== exp_valid || mac !== exp_mac || acc_ui !== exp_acc_ui ||
                load_reg_li !== exp_load_reg_li || load_reg_ui !== exp_load_reg_ui ||
                flow_lr !== exp_flow_lr || flow_ud !== exp_flow_ud ||
                flow_du !== exp_flow_du || update_reg !== exp_update_reg || exp2 !== exp_exp2) begin
                $fatal(1,
                    "[%s] got v/m/a/li/ui/lr/ud/du/up/e=%b%b%b%b%b%b%b%b%b%b exp=%b%b%b%b%b%b%b%b%b%b",
                    tag, valid, mac, acc_ui, load_reg_li, load_reg_ui, flow_lr, flow_ud, flow_du,
                    update_reg, exp2, exp_valid, exp_mac, exp_acc_ui, exp_load_reg_li,
                    exp_load_reg_ui, exp_flow_lr, exp_flow_ud, exp_flow_du, exp_update_reg,
                    exp_exp2);
            end
        end
    endtask

    function automatic logic [31:0] rand_finite_fp32();
        logic [31:0] rnd;
        logic [ 7:0] e;
        begin
            rnd              = $urandom();
            e                = (($urandom() % 254) + 1);
            rand_finite_fp32 = {rnd[31], e, rnd[22:0]};
        end
    endfunction

    // WS乘法操作数: 限制指数[1,190]，避免weight*vec指数溢出
    function automatic logic [31:0] rand_mul_operand();
        logic [31:0] rnd;
        logic [ 7:0] e;
        begin
            rnd             = $urandom();
            e               = (($urandom() % 190) + 1);
            rand_mul_operand = {rnd[31], e, rnd[22:0]};
        end
    endfunction

    // WS psum操作数: 限制指数[1,200]，避免mul_result+psum加法溢出到infinity
    function automatic logic [31:0] rand_psum_operand();
        logic [31:0] rnd;
        logic [ 7:0] e;
        begin
            rnd              = $urandom();
            e                = (($urandom() % 200) + 1);
            rand_psum_operand = {rnd[31], e, rnd[22:0]};
        end
    endfunction

    initial begin
        logic [31:0] os_a     [0:OS_LEN-1];
        logic [31:0] os_b     [0:OS_LEN-1];
        logic [31:0] os_exp   [0:OS_LEN-1];
        logic [31:0] os_acc;
        logic [31:0] ws_weight[0:WS_LEN-1];
        logic [31:0] ws_vec   [0:WS_LEN-1];
        logic [31:0] ws_psum  [0:WS_LEN-1];
        logic [31:0] ws_exp;
        logic [31:0] ui_weight;
        logic [31:0] ui_vec;
        logic [31:0] ui_psum;
        logic [31:0] acc_ui_weight;
        logic [31:0] acc_ui_vec;
        logic [31:0] acc_ui_psum;
        logic [31:0] flow_l;
        logic [31:0] flow_u;
        logic [31:0] flow_d;
        int          i;

        drive_idle();
        repeat (2) @(posedge clk);
        rstn = 1'b1;
        drive_idle();

        enter_mode(1'b1);
        os_acc = 32'h00000000;
        for (i = 0; i < OS_LEN; i = i + 1) begin
            os_a[i] = rand_finite_fp32();
            os_b[i] = rand_finite_fp32();
        end

        for (i = 0; i < OS_LEN + 4; i = i + 1) begin
            @(negedge clk);
            drive_idle();
            pe_mode_sel = 1'b1;
            if (i == 0) begin
                ret_rst_acc        = 1'b1;
                ret_partial_sum_in = os_acc;

                new_rst_acc        = 1'b1;
                new_partial_sum_in = os_acc;
            end
            else if (i <= OS_LEN) begin
                int idx;
                idx                = i - 1;
                ret_valid          = 1'b1;
                ret_mac            = 1'b1;
                ret_acc_ui         = 1'b0;
                ret_load_reg_ui    = 1'b0;
                ret_rst_acc        = 1'b0;
                ret_u_sign         = os_b[idx][31];
                ret_u_exp          = os_b[idx][30:23];
                ret_u_man          = os_b[idx][22:0];
                ret_d_sign         = 1'b0;
                ret_d_exp          = 8'h00;
                ret_d_man          = 23'h0;
                ret_l_sign         = os_a[idx][31];
                ret_l_exp          = os_a[idx][30:23];
                ret_l_man          = os_a[idx][22:0];
                ret_partial_sum_in = os_acc;

                new_en             = 1'b1;
                new_rst_acc        = 1'b0;
                new_weight_in      = os_a[idx];
                new_vec_in         = os_b[idx];
                new_partial_sum_in = os_acc;

                os_exp[idx]        = sw_mac32(os_a[idx], os_b[idx], os_acc);
                os_acc             = os_exp[idx];
            end

            @(posedge clk);
            #1ps;
            if (i >= 4) begin
                if (!ret_u_valid) begin
                    $fatal(1, "[OS/retimed] valid dropped unexpectedly");
                end
                if (!is_close(ret_u_word(), os_exp[i-4])) begin
                    $fatal(1, "[OS/retimed] got=%08h exp=%08h", ret_u_word(), os_exp[i-4]);
                end
                if (!is_close(new_result, os_exp[i-4])) begin
                    $fatal(1, "[OS/new] got=%08h exp=%08h", new_result, os_exp[i-4]);
                end
            end
            else begin
                if (ret_u_valid) begin
                    $fatal(1, "[OS/retimed] valid too early");
                end
            end
        end

        enter_mode(1'b0);
        for (i = 0; i < WS_LEN; i = i + 1) begin
            ws_weight[i] = rand_mul_operand();
            ws_vec[i]    = rand_mul_operand();
            ws_psum[i]   = rand_psum_operand();
        end

        for (i = 0; i < WS_LEN; i = i + 1) begin
            @(negedge clk);
            drive_idle();
            pe_mode_sel        = 1'b0;
            ret_valid          = 1'b1;
            ret_load_reg_li    = 1'b1;
            ret_rst_acc        = 1'b0;
            ret_l_sign         = ws_weight[i][31];
            ret_l_exp          = ws_weight[i][30:23];
            ret_l_man          = ws_weight[i][22:0];
            ret_partial_sum_in = 32'h0;

            leg_valid          = 1'b1;
            leg_load_reg_li    = 1'b1;
            leg_l_sign         = ws_weight[i][31];
            leg_l_exp          = ws_weight[i][30:23];
            leg_l_man          = ws_weight[i][22:0];

            @(posedge clk);
            #1ps;
            if (ret_u_valid || leg_u_valid) begin
                $fatal(1, "[WS/load] unexpected MAC output");
            end

            @(negedge clk);
            drive_idle();
            pe_mode_sel        = 1'b0;
            ret_valid          = 1'b1;
            ret_mac            = 1'b1;
            ret_acc_ui         = 1'b0;
            ret_update_reg     = 1'b1;
            ret_rst_acc        = 1'b1;
            ret_l_sign         = ws_vec[i][31];
            ret_l_exp          = ws_vec[i][30:23];
            ret_l_man          = ws_vec[i][22:0];
            ret_d_sign         = ws_psum[i][31];
            ret_d_exp          = ws_psum[i][30:23];
            ret_d_man          = ws_psum[i][22:0];
            ret_partial_sum_in = 32'h0;

            leg_valid          = 1'b1;
            leg_mac            = 1'b1;
            leg_acc_ui         = 1'b0;
            leg_update_reg     = 1'b1;
            leg_l_sign         = ws_vec[i][31];
            leg_l_exp          = ws_vec[i][30:23];
            leg_l_man          = ws_vec[i][22:0];
            leg_d_sign         = ws_psum[i][31];
            leg_d_exp          = ws_psum[i][30:23];
            leg_d_man          = ws_psum[i][22:0];

            new_en             = 1'b1;
            new_rst_acc        = 1'b1;
            new_weight_in      = ws_weight[i];
            new_vec_in         = ws_vec[i];
            new_partial_sum_in = ws_psum[i];

            ws_exp             = sw_mac32(ws_weight[i], ws_vec[i], ws_psum[i]);

            // chisel PE是组合逻辑，negedge驱动后立即有结果（reg仍为weight）
            #1ps;
            $display("[WS i=%0d] leg_v=%b leg=%08h exp=%08h",
                i, leg_u_valid, leg_u_word(), ws_exp);
            check_word("WS/legacy", leg_u_valid, leg_u_word(), ws_exp);

            // 等待retimed PE流水线出结果 (4拍)
            @(posedge clk); #1ps;  // T+0
            @(posedge clk); #1ps;  // T+1
            @(posedge clk); #1ps;  // T+2: fpadd已捕获输入，释放rst_acc让result显示add结果
            new_rst_acc = 1'b0;
            @(posedge clk); #1ps;  // T+3
            $display("[WS i=%0d T+3] ret_v=%b ret=%08h exp=%08h",
                i, ret_u_valid, ret_u_word(), ws_exp);
            check_word("WS/retimed", ret_u_valid, ret_u_word(), ws_exp);
            if (!is_close(new_result, ws_exp)) begin
                $fatal(1, "[WS/new] got=%08h exp=%08h", new_result, ws_exp);
            end
            // 撤销信号并等待retimed流水线排空
            @(negedge clk);
            drive_idle();
            pe_mode_sel = 1'b0;
            wait_cycles(3);
        end

        enter_mode(1'b0);
        ui_weight = rand_finite_fp32();
        ui_vec    = rand_mul_operand();
        ui_psum   = rand_psum_operand();
        ws_exp    = sw_mac32(ui_weight, ui_vec, ui_psum);

        @(negedge clk);
        drive_idle();
        pe_mode_sel       = 1'b0;
        ret_valid         = 1'b1;
        ret_load_reg_ui   = 1'b1;
        ret_u_sign        = ui_weight[31];
        ret_u_exp         = ui_weight[30:23];
        ret_u_man         = ui_weight[22:0];

        leg_valid         = 1'b1;
        leg_load_reg_ui   = 1'b1;
        leg_u_sign        = ui_weight[31];
        leg_u_exp         = ui_weight[30:23];
        leg_u_man         = ui_weight[22:0];

        @(posedge clk);
        #1ps;
        check_ctrl_bits("CTRL/load_ui/T0", ret_out_ctrl_valid, ret_out_ctrl_mac, ret_out_ctrl_acc_ui,
            ret_out_ctrl_load_reg_li, ret_out_ctrl_load_reg_ui, ret_out_ctrl_flow_lr,
            ret_out_ctrl_flow_ud, ret_out_ctrl_flow_du, ret_out_ctrl_update_reg,
            ret_out_ctrl_exp2, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);

        @(posedge clk);
        #1ps;
        check_ctrl_bits("CTRL/load_ui/T1", ret_out_ctrl_valid, ret_out_ctrl_mac, ret_out_ctrl_acc_ui,
            ret_out_ctrl_load_reg_li, ret_out_ctrl_load_reg_ui, ret_out_ctrl_flow_lr,
            ret_out_ctrl_flow_ud, ret_out_ctrl_flow_du, ret_out_ctrl_update_reg,
            ret_out_ctrl_exp2, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);

        @(posedge clk);
        #1ps;
        check_ctrl_bits("CTRL/load_ui/T2", ret_out_ctrl_valid, ret_out_ctrl_mac, ret_out_ctrl_acc_ui,
            ret_out_ctrl_load_reg_li, ret_out_ctrl_load_reg_ui, ret_out_ctrl_flow_lr,
            ret_out_ctrl_flow_ud, ret_out_ctrl_flow_du, ret_out_ctrl_update_reg,
            ret_out_ctrl_exp2, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0);
        if (leg_out_ctrl_valid !== 1'b1 || leg_out_ctrl_load_reg_ui !== 1'b1) begin
            $fatal(1, "[CTRL/legacy/load_ui] legacy ctrl unexpected");
        end

        @(negedge clk);
        drive_idle();
        pe_mode_sel        = 1'b0;
        ret_valid          = 1'b1;
        ret_mac            = 1'b1;
        ret_update_reg     = 1'b1;
        ret_l_sign         = ui_vec[31];
        ret_l_exp          = ui_vec[30:23];
        ret_l_man          = ui_vec[22:0];
        ret_d_sign         = ui_psum[31];
        ret_d_exp          = ui_psum[30:23];
        ret_d_man          = ui_psum[22:0];

        leg_valid          = 1'b1;
        leg_mac            = 1'b1;
        leg_update_reg     = 1'b1;
        leg_l_sign         = ui_vec[31];
        leg_l_exp          = ui_vec[30:23];
        leg_l_man          = ui_vec[22:0];
        leg_d_sign         = ui_psum[31];
        leg_d_exp          = ui_psum[30:23];
        leg_d_man          = ui_psum[22:0];

        #1ps;
        check_word("WS/load_ui/legacy", leg_u_valid, leg_u_word(), ws_exp);

        wait_cycles(4);
        #1ps;
        check_word("WS/load_ui/retimed", ret_u_valid, ret_u_word(), ws_exp);

        @(negedge clk);
        drive_idle();
        pe_mode_sel   = 1'b0;
        wait_cycles(3);

        acc_ui_weight = rand_finite_fp32();
        acc_ui_vec    = rand_mul_operand();
        acc_ui_psum   = rand_psum_operand();
        ws_exp        = sw_mac32(acc_ui_weight, acc_ui_vec, acc_ui_psum);

        @(negedge clk);
        drive_idle();
        pe_mode_sel        = 1'b0;
        ret_valid          = 1'b1;
        ret_load_reg_li    = 1'b1;
        ret_l_sign         = acc_ui_weight[31];
        ret_l_exp          = acc_ui_weight[30:23];
        ret_l_man          = acc_ui_weight[22:0];

        leg_valid          = 1'b1;
        leg_load_reg_li    = 1'b1;
        leg_l_sign         = acc_ui_weight[31];
        leg_l_exp          = acc_ui_weight[30:23];
        leg_l_man          = acc_ui_weight[22:0];

        @(posedge clk);
        #1ps;

        @(negedge clk);
        drive_idle();
        pe_mode_sel        = 1'b0;
        ret_valid          = 1'b1;
        ret_mac            = 1'b1;
        ret_acc_ui         = 1'b1;
        ret_update_reg     = 1'b1;
        ret_l_sign         = acc_ui_vec[31];
        ret_l_exp          = acc_ui_vec[30:23];
        ret_l_man          = acc_ui_vec[22:0];
        ret_u_sign         = acc_ui_psum[31];
        ret_u_exp          = acc_ui_psum[30:23];
        ret_u_man          = acc_ui_psum[22:0];

        leg_valid          = 1'b1;
        leg_mac            = 1'b1;
        leg_acc_ui         = 1'b1;
        leg_update_reg     = 1'b1;
        leg_l_sign         = acc_ui_vec[31];
        leg_l_exp          = acc_ui_vec[30:23];
        leg_l_man          = acc_ui_vec[22:0];
        leg_u_sign         = acc_ui_psum[31];
        leg_u_exp          = acc_ui_psum[30:23];
        leg_u_man          = acc_ui_psum[22:0];

        #1ps;
        check_word("WS/acc_ui/legacy", leg_d_valid, leg_d_word(), ws_exp);
        if (leg_u_valid) begin
            $fatal(1, "[WS/acc_ui/legacy] unexpected U valid");
        end

        wait_cycles(4);
        #1ps;
        check_word("WS/acc_ui/retimed", ret_d_valid, ret_d_word(), ws_exp);
        if (ret_u_valid) begin
            $fatal(1, "[WS/acc_ui/retimed] unexpected U valid");
        end

        @(negedge clk);
        drive_idle();
        pe_mode_sel = 1'b0;
        wait_cycles(3);

        flow_l = rand_finite_fp32();
        flow_u = rand_finite_fp32();
        flow_d = rand_finite_fp32();

        @(negedge clk);
        drive_idle();
        pe_mode_sel     = 1'b0;
        ret_valid       = 1'b1;
        ret_flow_ud     = 1'b1;
        ret_u_sign      = flow_u[31];
        ret_u_exp       = flow_u[30:23];
        ret_u_man       = flow_u[22:0];

        leg_valid       = 1'b1;
        leg_flow_ud     = 1'b1;
        leg_u_sign      = flow_u[31];
        leg_u_exp       = flow_u[30:23];
        leg_u_man       = flow_u[22:0];

        #1ps;
        check_word("WS/flow_ud/legacy", leg_d_valid, leg_d_word(), flow_u);
        check_word("WS/flow_ud/retimed", ret_d_valid, ret_d_word(), flow_u);

        @(negedge clk);
        drive_idle();
        pe_mode_sel     = 1'b0;
        ret_valid       = 1'b1;
        ret_flow_du     = 1'b1;
        ret_d_sign      = flow_d[31];
        ret_d_exp       = flow_d[30:23];
        ret_d_man       = flow_d[22:0];

        leg_valid       = 1'b1;
        leg_flow_du     = 1'b1;
        leg_d_sign      = flow_d[31];
        leg_d_exp       = flow_d[30:23];
        leg_d_man       = flow_d[22:0];

        #1ps;
        check_word("WS/flow_du/legacy", leg_u_valid, leg_u_word(), flow_d);
        check_word("WS/flow_du/retimed", ret_u_valid, ret_u_word(), flow_d);

        @(negedge clk);
        drive_idle();
        pe_mode_sel     = 1'b0;
        ret_valid       = 1'b1;
        ret_flow_lr     = 1'b1;
        ret_l_sign      = flow_l[31];
        ret_l_exp       = flow_l[30:23];
        ret_l_man       = flow_l[22:0];

        leg_valid       = 1'b1;
        leg_flow_lr     = 1'b1;
        leg_l_sign      = flow_l[31];
        leg_l_exp       = flow_l[30:23];
        leg_l_man       = flow_l[22:0];

        #1ps;
        check_word("WS/flow_lr/legacy", leg_r_valid, leg_r_word(), flow_l);
        check_word("WS/flow_lr/retimed", ret_r_valid, ret_r_word(), flow_l);

        @(negedge clk);
        drive_idle();
        pe_mode_sel = 1'b0;
        wait_cycles(2);

        $display("[TB] PASS triplet compare completed");
        $finish;
    end
endmodule

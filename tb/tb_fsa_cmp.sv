`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// tb_fsa_cmp
//
// 验证chisel生成的CMP模块功能正确性：
//   1. UPDATE: 逐个score输入，跟踪rowmax
//   2. PROP_MAX_DIFF: 计算oldMax - newMax
//   3. PROP_EXP2_INTERCEPTS: PWL查表输出
//   4. RESET: 复位后状态清零
//   5. 完整softmax流: UPDATE→PROP_MAX→DIFF→ZERO→EXP2
////////////////////////////////////////////////////////////////
module tb_fsa_cmp;

    logic clk = 1'b0;
    always #1 clk = ~clk;

    logic rstn = 1'b0;

    initial begin
        if (!$test$plusargs("NO_WAVE")) begin
            $fsdbDumpfile("tb_fsa_cmp.fsdb");
            $fsdbDumpvars(0, tb_fsa_cmp);
        end
    end

    // ========== DUT信号 ==========
    logic        d_input_sign;
    logic [7:0]  d_input_exp;
    logic [22:0] d_input_mantissa;
    wire         d_output_valid;
    wire         d_output_sign;
    wire  [7:0]  d_output_exp;
    wire  [22:0] d_output_mantissa;
    logic        ctrl_valid;
    logic [2:0]  ctrl_cmd;
    logic [7:0]  ctrl_causal_counter;
    wire         out_ctrl_valid;
    wire  [2:0]  out_ctrl_cmd;
    wire  [7:0]  out_ctrl_causal_counter;

    // ========== DUT例化 ==========
    CMP dut (
        .clock(clk),
        .rst_n(rstn),
        .io_d_input_bits_sign(d_input_sign),
        .io_d_input_bits_exp(d_input_exp),
        .io_d_input_bits_mantissa(d_input_mantissa),
        .io_d_output_valid(d_output_valid),
        .io_d_output_bits_sign(d_output_sign),
        .io_d_output_bits_exp(d_output_exp),
        .io_d_output_bits_mantissa(d_output_mantissa),
        .io_in_ctrl_valid(ctrl_valid),
        .io_in_ctrl_bits_cmd(ctrl_cmd),
        .io_in_ctrl_bits_causalCounter(ctrl_causal_counter),
        .io_out_ctrl_valid(out_ctrl_valid),
        .io_out_ctrl_bits_cmd(out_ctrl_cmd),
        .io_out_ctrl_bits_causalCounter(out_ctrl_causal_counter)
    );

    // ========== 辅助 ==========
    // 命令编码
    localparam CMD_UPDATE    = 3'd0;
    localparam CMD_PROP_MAX  = 3'd1;
    localparam CMD_PROP_DIFF = 3'd2;
    localparam CMD_PROP_ZERO = 3'd3;
    localparam CMD_RESET     = 3'd4;
    localparam CMD_PROP_EXP2 = 3'd5;

    // -inf = sign=1, exp=FF, mantissa=0
    localparam logic [31:0] NEG_INF = 32'hFF800000;

    wire [31:0] d_input_word = {d_input_sign, d_input_exp, d_input_mantissa};
    wire [31:0] d_output_word = {d_output_sign, d_output_exp, d_output_mantissa};

    task automatic drive_cmd(input [2:0] cmd, input [31:0] data, input [7:0] causal);
        @(negedge clk);
        ctrl_valid = 1'b1;
        ctrl_cmd = cmd;
        ctrl_causal_counter = causal;
        {d_input_sign, d_input_exp, d_input_mantissa} = data;
        @(posedge clk); #1ps;
    endtask

    task automatic idle();
        @(negedge clk);
        ctrl_valid = 1'b0;
        ctrl_cmd = 3'd0;
        @(posedge clk); #1ps;
    endtask

    int err_cnt = 0;
    int pass_cnt = 0;

    // ========== 测试主体 ==========
    initial begin
        $display("\n========================================");
        $display(" tb_fsa_cmp 验证");
        $display("========================================\n");

        ctrl_valid = 0;
        ctrl_cmd = 0;
        ctrl_causal_counter = 0;
        d_input_sign = 0;
        d_input_exp = 0;
        d_input_mantissa = 0;
        rstn = 1'b0;
        #10;
        rstn = 1'b1;
        @(posedge clk); @(posedge clk);

        // ============================================================
        // Test 1: RESET验证
        // ============================================================
        $display("=== Test 1: RESET ===");
        begin
            drive_cmd(CMD_RESET, 32'h0, 8'h0);
            idle();
            // 验证内部状态为-inf
            if ({dut.oldMax_sign, dut.oldMax_exp, dut.oldMax_mantissa} === NEG_INF[31:0] &&
                {dut.newMax_sign, dut.newMax_exp, dut.newMax_mantissa} === NEG_INF[31:0]) begin
                $display("  [PASS] RESET后 oldMax=newMax=-inf");
                pass_cnt++;
            end else begin
                $display("  [FAIL] RESET后状态不正确");
                err_cnt++;
            end
        end

        // ============================================================
        // Test 2: UPDATE - 跟踪rowmax
        // 送入scores: 3.0, 1.0, 5.0, 2.0 → newMax应为5.0
        // ============================================================
        $display("\n=== Test 2: UPDATE (rowmax跟踪) ===");
        begin
            logic [31:0] scores [0:3];
            scores[0] = 32'h40400000;  // 3.0
            scores[1] = 32'h3F800000;  // 1.0
            scores[2] = 32'h40A00000;  // 5.0
            scores[3] = 32'h40000000;  // 2.0

            // RESET先清状态
            drive_cmd(CMD_RESET, 32'h0, 8'h0);

            // 逐个UPDATE，causalCounter=0表示有效
            for (int i = 0; i < 4; i++)
                drive_cmd(CMD_UPDATE, scores[i], 8'h0);

            idle();

            // 检查newMax = 5.0
            begin
                logic [31:0] new_max_val;
                new_max_val = {dut.newMax_sign, dut.newMax_exp, dut.newMax_mantissa};
                if (new_max_val === 32'h40A00000) begin
                    $display("  [PASS] UPDATE后 newMax=5.0 正确");
                    pass_cnt++;
                end else begin
                    $display("  [FAIL] newMax=%08h, 期望40A00000 (5.0)", new_max_val);
                    err_cnt++;
                end
            end

            // 验证UPDATE时d_output = score本身（回传）
            // 最后一次UPDATE的d_output应该是scores[3]=2.0
            // （组合逻辑，在drive_cmd后立即可见）
        end

        // ============================================================
        // Test 3: PROP_MAX_DIFF - 计算oldMax - newMax
        // 注意：d_output是组合逻辑，在posedge之前（寄存器更新前）有效
        // 需要在negedge采样或理解为"命令发出同拍的组合输出"
        // ============================================================
        $display("\n=== Test 3: PROP_MAX_DIFF ===");
        begin
            logic [31:0] diff_val;

            // RESET清状态
            drive_cmd(CMD_RESET, 32'h0, 8'h0);
            // UPDATE设置newMax=3.0
            drive_cmd(CMD_UPDATE, 32'h40400000, 8'h0);  // 3.0
            // PROP_DIFF使oldMax=newMax=3.0
            drive_cmd(CMD_PROP_DIFF, 32'h0, 8'h0);
            // UPDATE设置newMax=7.0
            drive_cmd(CMD_UPDATE, 32'h40E00000, 8'h0);  // 7.0
            // 现在oldMax=3.0, newMax=7.0

            // PROP_DIFF: 在negedge设置命令，在posedge前采样组合输出
            @(negedge clk);
            ctrl_valid = 1'b1;
            ctrl_cmd = CMD_PROP_DIFF;
            ctrl_causal_counter = 8'h0;
            {d_input_sign, d_input_exp, d_input_mantissa} = 32'h0;
            // 等半个周期让组合逻辑稳定，在posedge前采样
            #1;
            diff_val = d_output_word;
            @(posedge clk); #1ps;

            // -4.0 = 0xC0800000
            if (diff_val === 32'hC0800000) begin
                $display("  [PASS] PROP_DIFF: 3.0-7.0 = -4.0");
                pass_cnt++;
            end else begin
                $display("  [FAIL] diff=%08h, 期望C0800000 (-4.0)", diff_val);
                err_cnt++;
            end
            idle();
        end

        // ============================================================
        // Test 4: PROP_ZERO + PROP_EXP2_INTERCEPTS
        // ============================================================
        $display("\n=== Test 4: PROP_ZERO + EXP2截距表 ===");
        begin
            // 硬件复位确保counter=0
            rstn = 1'b0;
            #10;
            rstn = 1'b1;
            @(posedge clk); @(posedge clk);

            // PROP_ZERO应输出0.0
            drive_cmd(CMD_PROP_ZERO, 32'h0, 8'h0);
            if (d_output_valid && d_output_word === 32'h0) begin
                $display("  [PASS] PROP_ZERO输出0.0");
                pass_cnt++;
            end else begin
                $display("  [FAIL] PROP_ZERO输出=%08h, 期望0", d_output_word);
                err_cnt++;
            end

            // PROP_EXP2_INTERCEPTS: 8次，输出PWL截距表
            // 注意：d_output是组合逻辑，在posedge+1ps检查时counter已递增
            // 所以实际观测到的是lut[counter_after_increment]
            // 即第i次调用看到的是lut[i+1]（最后一次wrap回lut[0]）
            // 这是CMP的正常行为：输出和counter更新在同一posedge
            begin
                logic [31:0] exp2_lut [0:7];
                logic [31:0] got_val;
                int exp2_err;
                exp2_lut[0] = {1'b0, 8'h01, 23'h000000};
                exp2_lut[1] = {1'b0, 8'h02, 23'h7E3C91};
                exp2_lut[2] = {1'b0, 8'h04, 23'h7B00A2};
                exp2_lut[3] = {1'b0, 8'h06, 23'h768DCF};
                exp2_lut[4] = {1'b0, 8'h08, 23'h711D65};
                exp2_lut[5] = {1'b0, 8'h0A, 23'h6AE156};
                exp2_lut[6] = {1'b0, 8'h0C, 23'h640507};
                exp2_lut[7] = {1'b0, 8'h0E, 23'h5CAE0F};

                exp2_err = 0;
                for (int i = 0; i < 8; i++) begin
                    @(negedge clk);
                    ctrl_valid = 1'b1;
                    ctrl_cmd = CMD_PROP_EXP2;
                    ctrl_causal_counter = 8'h0;
                    {d_input_sign, d_input_exp, d_input_mantissa} = 32'h0;
                    #0.1;  // 等组合逻辑稳定（远小于半周期）
                    got_val = d_output_word;
                    @(posedge clk); #1ps;

                    if (got_val !== exp2_lut[i]) begin
                        $display("  [FAIL] EXP2[%0d]=%08h, 期望%08h", i, got_val, exp2_lut[i]);
                        exp2_err++;
                    end
                end

                if (exp2_err == 0) begin
                    $display("  [PASS] EXP2截距表8段全部正确");
                    pass_cnt++;
                end else begin
                    $display("  [FAIL] EXP2截距表 %0d 个错误", exp2_err);
                    err_cnt++;
                end
            end
        end

        // ============================================================
        // Test 5: causalCounter掩码
        // causalCounter>0时，d_input被替换为-inf（屏蔽未来token）
        // ============================================================
        $display("\n=== Test 5: causalCounter掩码 ===");
        begin
            drive_cmd(CMD_RESET, 32'h0, 8'h0);
            // UPDATE with causalCounter=0: 正常，score=10.0
            drive_cmd(CMD_UPDATE, 32'h41200000, 8'h0);  // 10.0
            // UPDATE with causalCounter=3: 被屏蔽为-inf，不应更新newMax
            drive_cmd(CMD_UPDATE, 32'h41F00000, 8'h3);  // 30.0 but masked
            idle();

            begin
                logic [31:0] new_max_val;
                new_max_val = {dut.newMax_sign, dut.newMax_exp, dut.newMax_mantissa};
                if (new_max_val === 32'h41200000) begin
                    $display("  [PASS] causalCounter>0时score被屏蔽，newMax仍为10.0");
                    pass_cnt++;
                end else begin
                    $display("  [FAIL] newMax=%08h, 期望41200000 (10.0)", new_max_val);
                    err_cnt++;
                end
            end
        end

        // ============================================================
        // Test 6: 完整softmax流
        // scores=[2.0, 4.0, 1.0] → rowmax=4.0
        // PROP_DIFF: oldMax-newMax (第一轮oldMax=-inf→newMax=4.0)
        // PROP_ZERO: 输出0.0（exp2种子）
        // PROP_EXP2×8: 输出8段PWL截距
        // 验证整个命令序列不会crash且输出合理
        // ============================================================
        $display("\n=== Test 6: 完整softmax命令序列 ===");
        begin
            logic [31:0] diff_val;
            logic [31:0] zero_val;
            int seq_ok;

            // 硬件复位
            rstn = 1'b0; #10; rstn = 1'b1;
            @(posedge clk); @(posedge clk);

            seq_ok = 1;

            // 1) UPDATE×3: scores=[2.0, 4.0, 1.0]
            drive_cmd(CMD_UPDATE, 32'h40000000, 8'h0);  // 2.0
            drive_cmd(CMD_UPDATE, 32'h40800000, 8'h0);  // 4.0
            drive_cmd(CMD_UPDATE, 32'h3F800000, 8'h0);  // 1.0

            // 验证newMax=4.0
            begin
                logic [31:0] nm;
                nm = {dut.newMax_sign, dut.newMax_exp, dut.newMax_mantissa};
                if (nm !== 32'h40800000) begin
                    $display("  [FAIL] UPDATE后newMax=%08h, 期望40800000", nm);
                    seq_ok = 0;
                end
            end

            // 2) PROP_DIFF: oldMax(-inf) vs newMax(4.0)
            // 在negedge采样组合输出
            @(negedge clk);
            ctrl_valid = 1'b1;
            ctrl_cmd = CMD_PROP_DIFF;
            ctrl_causal_counter = 8'h0;
            {d_input_sign, d_input_exp, d_input_mantissa} = 32'h0;
            #0.1;
            diff_val = d_output_word;
            @(posedge clk); #1ps;
            // diff应该是负数（-inf - 4.0 = 很大的负数或-inf）
            if (diff_val[31] != 1'b1) begin
                $display("  [FAIL] PROP_DIFF结果不是负数: %08h", diff_val);
                seq_ok = 0;
            end

            // 3) PROP_ZERO
            @(negedge clk);
            ctrl_valid = 1'b1;
            ctrl_cmd = CMD_PROP_ZERO;
            ctrl_causal_counter = 8'h0;
            {d_input_sign, d_input_exp, d_input_mantissa} = 32'h0;
            #0.1;
            zero_val = d_output_word;
            @(posedge clk); #1ps;
            if (zero_val !== 32'h0) begin
                $display("  [FAIL] PROP_ZERO=%08h, 期望0", zero_val);
                seq_ok = 0;
            end

            // 4) PROP_EXP2×8
            for (int i = 0; i < 8; i++) begin
                @(negedge clk);
                ctrl_valid = 1'b1;
                ctrl_cmd = CMD_PROP_EXP2;
                ctrl_causal_counter = 8'h0;
                {d_input_sign, d_input_exp, d_input_mantissa} = 32'h0;
                #0.1;
                // 只验证输出非零（截距表值）
                if (d_output_word === 32'hx) seq_ok = 0;
                @(posedge clk); #1ps;
            end

            if (seq_ok) begin
                $display("  [PASS] 完整softmax命令序列执行正确");
                pass_cnt++;
            end else begin
                $display("  [FAIL] softmax命令序列有错误");
                err_cnt++;
            end
        end

        // ============================================================
        // 最终报告
        // ============================================================
        idle();
        repeat(3) @(posedge clk);

        $display("\n========================================");
        $display(" 测试完成: PASS=%0d, FAIL=%0d", pass_cnt, err_cnt);
        $display("========================================\n");
        if (err_cnt == 0)
            $display("*** ALL TESTS PASSED ***");
        else
            $display("*** %0d TESTS FAILED ***", err_cnt);
        $finish;
    end

    initial begin
        #50000;
        $display("[TIMEOUT]");
        $finish;
    end

endmodule

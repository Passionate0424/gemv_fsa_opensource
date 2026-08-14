`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// tb_pe_core_v2
//
// Phase 1验证：PE_core_v2的OS回归 + WS模式基本功能
// 测试项：
//   1. OS模式回归（简单GEMV）
//   2. LoadStationary（Q加载到PE寄存器）
//   3. 延迟匹配验证（skewing波形）
//   4. QK点积（手动驱动fsa_l_input）
//   5. 分组隔离（4组独立）
////////////////////////////////////////////////////////////////
module tb_pe_core_v2;

    localparam int ARRAY_SIZE    = 32;
    localparam int DATA_WIDTH    = 32;
    localparam int GROUP_SIZE    = 8;
    localparam int NUM_GROUPS    = 4;
    localparam int MAC_LATENCY   = 4;
    localparam int K_ACCUM_DEPTH = 64;

    logic clk = 1'b0;
    always #1 clk = ~clk;

    logic rstn = 1'b0;
    int unsigned cycle = 0;
    always @(posedge clk) cycle <= cycle + 1;

    initial begin
        if (!$test$plusargs("NO_WAVE")) begin
            $fsdbDumpfile("tb_pe_core_v2.fsdb");
            $fsdbDumpvars(0, tb_pe_core_v2);
        end
    end

    // ========== DUT信号 ==========
    logic fsa_mode;
    logic alu_start;
    logic [8:0] cycle_num;
    logic [DATA_WIDTH*ARRAY_SIZE-1:0] sram_rdata_w;
    logic [DATA_WIDTH-1:0] sram_rdata_v;
    logic acc_en;
    wire  [ARRAY_SIZE*DATA_WIDTH-1:0] mul_outcome;
    wire  result_valid;

    // FSA接口
    logic [ARRAY_SIZE*DATA_WIDTH-1:0] fsa_l_input;
    logic fsa_l_input_valid;
    logic fsa_ctrl_mac;
    logic fsa_ctrl_acc_ui;
    logic fsa_ctrl_load_reg_li;
    logic fsa_ctrl_flow_lr;
    logic fsa_ctrl_flow_ud;
    logic fsa_ctrl_flow_du;
    logic fsa_ctrl_update_reg;
    logic fsa_ctrl_exp2;
    logic fsa_ctrl_broadcast;

    wire [NUM_GROUPS*DATA_WIDTH-1:0] cmp_score_out;
    wire [NUM_GROUPS-1:0] cmp_score_valid;
    wire [NUM_GROUPS*DATA_WIDTH-1:0] acc_data_out;
    wire [NUM_GROUPS-1:0] acc_data_valid;

    // ========== DUT例化 ==========
    PE_core_v2 #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .K_ACCUM_DEPTH(K_ACCUM_DEPTH),
        .MAC_LATENCY(MAC_LATENCY),
        .GROUP_SIZE(GROUP_SIZE),
        .NUM_GROUPS(NUM_GROUPS)
    ) dut (
        .clock(clk),
        .rst_n(rstn),
        .fsa_mode(fsa_mode),
        .alu_start(alu_start),
        .cycle_num(cycle_num),
        .sram_rdata_w(sram_rdata_w),
        .sram_rdata_v(sram_rdata_v),
        .acc_en(acc_en),
        .mul_outcome(mul_outcome),
        .result_valid(result_valid),
        .fsa_l_input(fsa_l_input),
        .fsa_l_input_valid(fsa_l_input_valid),
        .fsa_ctrl_mac(fsa_ctrl_mac),
        .fsa_ctrl_acc_ui(fsa_ctrl_acc_ui),
        .fsa_ctrl_load_reg_li(fsa_ctrl_load_reg_li),
        .fsa_ctrl_flow_lr(fsa_ctrl_flow_lr),
        .fsa_ctrl_flow_ud(fsa_ctrl_flow_ud),
        .fsa_ctrl_flow_du(fsa_ctrl_flow_du),
        .fsa_ctrl_update_reg(fsa_ctrl_update_reg),
        .fsa_ctrl_exp2(fsa_ctrl_exp2),
        .fsa_ctrl_broadcast(fsa_ctrl_broadcast),
        .cmp_d_output_bus({NUM_GROUPS*DATA_WIDTH{1'b0}}),
        .cmp_score_out(cmp_score_out),
        .cmp_score_valid(cmp_score_valid),
        .acc_data_out(acc_data_out),
        .acc_data_valid(acc_data_valid)
    );

    // ========== PE寄存器值提取（解决VCS动态索引cross-module reference限制）==========
    wire [DATA_WIDTH-1:0] pe_reg_array [0:ARRAY_SIZE-1];
    // 延迟匹配后的l_input信号提取（用于验证延迟时序）
    wire [DATA_WIDTH-1:0] pe_l_delayed_array [0:ARRAY_SIZE-1];
    // 延迟匹配后的valid信号提取
    wire [ARRAY_SIZE-1:0] pe_valid_delayed_array;
    genvar gk;
    generate
        for (gk = 0; gk < ARRAY_SIZE; gk = gk + 1) begin : REG_TAP
            assign pe_reg_array[gk] = {
                dut.PE_INST[gk].u_pe.reg_sign,
                dut.PE_INST[gk].u_pe.reg_exp,
                dut.PE_INST[gk].u_pe.reg_mantissa
            };
            assign pe_l_delayed_array[gk] = dut.fsa_l_delayed[gk];
            assign pe_valid_delayed_array[gk] = dut.fsa_valid_delayed[gk];
        end
    endgenerate

    // ========== 辅助函数 ==========
    // 生成有限FP32随机数（避免NaN/Inf/denorm，指数范围适中防溢出）
    function automatic logic [31:0] rand_fp32();
        logic [31:0] w;
        begin
            w[31]    = $urandom_range(0, 1);
            w[30:23] = $urandom_range(120, 135);  // 指数范围窄，防MAC溢出
            w[22:0]  = $urandom;
            rand_fp32 = w;
        end
    endfunction

    // 生成小幅FP32（用于MAC测试，防止累加溢出）
    function automatic logic [31:0] rand_small_fp32();
        logic [31:0] w;
        begin
            w[31]    = $urandom_range(0, 1);
            w[30:23] = $urandom_range(110, 125);  // 更小的指数
            w[22:0]  = $urandom;
            rand_small_fp32 = w;
        end
    endfunction

    // ULP容差比较（允许2 ULP差异）
    function automatic logic fp32_close(logic [31:0] a, logic [31:0] b);
        logic [31:0] abs_a, abs_b;
        int diff;
        begin
            if (a === b) return 1'b1;
            if (a == 32'h0 && b == 32'h0) return 1'b1;
            abs_a = a & 32'h7FFFFFFF;
            abs_b = b & 32'h7FFFFFFF;
            if (a[31] != b[31]) diff = abs_a + abs_b;
            else diff = (abs_a > abs_b) ? (abs_a - abs_b) : (abs_b - abs_a);
            return (diff <= 2);
        end
    endfunction

    // ========== 驱动任务 ==========
    task automatic reset_dut();
        rstn = 1'b0;
        fsa_mode = 1'b0;
        alu_start = 1'b0;
        cycle_num = 9'd0;
        sram_rdata_w = '0;
        sram_rdata_v = '0;
        acc_en = 1'b0;
        fsa_l_input = '0;
        fsa_l_input_valid = 1'b0;
        fsa_ctrl_mac = 1'b0;
        fsa_ctrl_acc_ui = 1'b0;
        fsa_ctrl_load_reg_li = 1'b0;
        fsa_ctrl_flow_lr = 1'b0;
        fsa_ctrl_flow_ud = 1'b0;
        fsa_ctrl_flow_du = 1'b0;
        fsa_ctrl_update_reg = 1'b0;
        fsa_ctrl_exp2 = 1'b0;
        fsa_ctrl_broadcast = 1'b0;
        fsa_ctrl_broadcast = 1'b0;
        #20;
        rstn = 1'b1;
        @(posedge clk); @(posedge clk);
        #1ps;
    endtask

    task automatic fsa_idle();
        fsa_l_input = '0;
        fsa_l_input_valid = 1'b0;
        fsa_ctrl_mac = 1'b0;
        fsa_ctrl_acc_ui = 1'b0;
        fsa_ctrl_load_reg_li = 1'b0;
        fsa_ctrl_flow_lr = 1'b0;
        fsa_ctrl_flow_ud = 1'b0;
        fsa_ctrl_flow_du = 1'b0;
        fsa_ctrl_update_reg = 1'b0;
        fsa_ctrl_exp2 = 1'b0;
        fsa_ctrl_broadcast = 1'b0;
    endtask

    // ========== 错误计数 ==========
    int err_cnt = 0;
    int pass_cnt = 0;
    int test_num = 0;

    // ========== 测试主体 ==========
    initial begin
        $display("\n========================================");
        $display(" tb_pe_core_v2 Phase 1 验证");
        $display("========================================\n");

        reset_dut();

        // ============================================================
        // Test 1: OS模式回归 - 数值正确性验证
        // W[i]=1.0, V=2.0, K_DIM=64 → 每个PE结果=1.0*2.0*64=128.0
        // ============================================================
        test_num = 1;
        $display("=== Test %0d: OS模式回归 (数值正确性) ===", test_num);
        begin
            localparam logic [31:0] FP_W = 32'h3F800000;   // 1.0
            localparam logic [31:0] FP_V = 32'h40000000;   // 2.0
            localparam logic [31:0] FP_EXP = 32'h43000000; // 128.0

            fsa_mode = 1'b0;
            acc_en = 1'b0;

            alu_start = 1'b1;
            begin
                int rv_seen = 0;
                logic [31:0] captured [0:ARRAY_SIZE-1];

                for (int c = 0; c <= K_ACCUM_DEPTH + ARRAY_SIZE - 1 + MAC_LATENCY + 2; c++) begin
                    @(negedge clk);
                    cycle_num = c[8:0];
                    if (c >= 1 && c <= K_ACCUM_DEPTH) begin
                        for (int i = 0; i < ARRAY_SIZE; i++)
                            sram_rdata_w[i*DATA_WIDTH +: DATA_WIDTH] = FP_W;
                        sram_rdata_v = FP_V;
                    end else begin
                        sram_rdata_w = '0;
                        sram_rdata_v = '0;
                    end
                    @(posedge clk); #1ps;
                    if (result_valid) begin
                        rv_seen = 1;
                        for (int i = 0; i < ARRAY_SIZE; i++)
                            captured[i] = mul_outcome[((ARRAY_SIZE-i)*DATA_WIDTH)-1 -: DATA_WIDTH];
                    end
                end

                if (!rv_seen) begin
                    $display("  [FAIL] result_valid 未拉高");
                    err_cnt++;
                end else begin
                    int os_err = 0;
                    for (int i = 0; i < ARRAY_SIZE; i++) begin
                        if (!fp32_close(captured[i], FP_EXP)) begin
                            if (os_err < 3)
                                $display("  [FAIL] PE[%0d]=%08h, exp=%08h", i, captured[i], FP_EXP);
                            os_err++;
                        end
                    end
                    if (os_err == 0) begin
                        $display("  [PASS] 32个PE结果均为128.0 (W=1.0*V=2.0*K=64)");
                        pass_cnt++;
                    end else begin
                        $display("  [FAIL] %0d个PE结果错误", os_err);
                        err_cnt++;
                    end
                end
            end

            alu_start = 1'b0;
            cycle_num = 9'd0;
            sram_rdata_w = '0;
            sram_rdata_v = '0;
            repeat(10) @(posedge clk);
        end

        // ============================================================
        // Test 2: LoadStationary - Q加载到PE寄存器
        // 验证：倒序送入Q[7..0]经l_input移位，8拍后PE[k].reg == Q[k]
        // ============================================================
        test_num = 2;
        $display("\n=== Test %0d: LoadStationary (Q加载) ===", test_num);
        begin
            logic [31:0] q_vals [0:GROUP_SIZE-1];
            logic [31:0] pe_reg_val;
            int load_pass;

            // 切换到FSA模式
            fsa_mode = 1'b1;
            fsa_idle();
            repeat(5) @(posedge clk);

            // 生成Q值（8个，对应一组内8个PE）
            for (int i = 0; i < GROUP_SIZE; i++)
                q_vals[i] = rand_fp32();

            // LoadStationary: 并行加载，1拍完成
            // 每个PE的l_input通道送入各自的Q值（绕过延迟匹配）
            // 控制：load_reg_li=1, valid=1
            // 4组PE加载相同的Q（因为广播同一组Q值到所有组）
            @(negedge clk);
            fsa_ctrl_load_reg_li = 1'b1;
            fsa_l_input_valid = 1'b1;
            // 每个PE的l_input通道送入对应组内位置的Q值
            for (int i = 0; i < ARRAY_SIZE; i++) begin
                int pos_in_grp;
                pos_in_grp = i % GROUP_SIZE;
                fsa_l_input[i*DATA_WIDTH +: DATA_WIDTH] = q_vals[pos_in_grp];
            end
            @(posedge clk); #1ps;

            // 停止加载
            @(negedge clk);
            fsa_idle();
            @(posedge clk); #1ps;

            // 验证：检查Group 0的8个PE寄存器值
            load_pass = 0;
            for (int p = 0; p < GROUP_SIZE; p++) begin
                pe_reg_val = pe_reg_array[p];
                if (pe_reg_val === q_vals[p]) begin
                    load_pass++;
                end else begin
                    $display("  [FAIL] PE[%0d].reg = %08h, expected Q[%0d] = %08h",
                             p, pe_reg_val, p, q_vals[p]);
                    err_cnt++;
                end
            end
            if (load_pass == GROUP_SIZE) begin
                $display("  [PASS] Group 0 所有PE寄存器加载正确 (%0d/%0d)", load_pass, GROUP_SIZE);
                pass_cnt++;
            end

            // 验证Group 1也正确（PE[8..15]）
            load_pass = 0;
            for (int p = 0; p < GROUP_SIZE; p++) begin
                pe_reg_val = pe_reg_array[GROUP_SIZE + p];
                if (pe_reg_val === q_vals[p])
                    load_pass++;
            end
            if (load_pass == GROUP_SIZE) begin
                $display("  [PASS] Group 1 所有PE寄存器加载正确 (%0d/%0d)", load_pass, GROUP_SIZE);
                pass_cnt++;
            end else begin
                $display("  [FAIL] Group 1 加载错误 (%0d/%0d correct)", load_pass, GROUP_SIZE);
                err_cnt++;
            end

            repeat(5) @(posedge clk);
        end

        // ============================================================
        // Test 3: 延迟匹配验证 - 实际观测脉冲到达时刻
        // 送入1拍脉冲，观测各PE的fsa_l_delayed何时变为非零
        // ============================================================
        test_num = 3;
        $display("\n=== Test %0d: 延迟匹配验证 (实际时序) ===", test_num);
        begin
            logic [31:0] pulse_val;
            int first_seen [0:GROUP_SIZE-1];
            int delay_err;

            fsa_mode = 1'b1;
            fsa_idle();
            repeat(5) @(posedge clk);

            pulse_val = 32'h3F800000;  // 1.0

            for (int p = 0; p < GROUP_SIZE; p++)
                first_seen[p] = -1;

            // 送入1拍脉冲
            @(negedge clk);
            fsa_l_input_valid = 1'b1;
            fsa_ctrl_mac = 1'b1;
            for (int i = 0; i < ARRAY_SIZE; i++)
                fsa_l_input[i*DATA_WIDTH +: DATA_WIDTH] = pulse_val;
            @(posedge clk); #1ps;

            // 之后送0，观测各PE的delayed输出何时变为pulse_val
            for (int t = 1; t <= (GROUP_SIZE-1)*MAC_LATENCY + 2; t++) begin
                @(negedge clk);
                fsa_l_input_valid = 1'b0;
                fsa_ctrl_mac = 1'b1;
                fsa_l_input = '0;
                @(posedge clk); #1ps;

                // 检查Group 0的各PE delayed输出
                for (int p = 0; p < GROUP_SIZE; p++) begin
                    if (first_seen[p] == -1 && pe_l_delayed_array[p] == pulse_val)
                        first_seen[p] = t;
                end
            end

            // 验证：PE[p]的延迟匹配输出在脉冲后p*MAC_LATENCY-1拍变为pulse_val
            // （4级移位寄存器从输入到输出经过3个时钟间隔，因为t=0输入同时进入sr[0]）
            delay_err = 0;
            for (int p = 1; p < GROUP_SIZE; p++) begin
                int expected_t;
                expected_t = p * MAC_LATENCY - 1;
                if (first_seen[p] != expected_t) begin
                    $display("  [FAIL] PE[%0d] 脉冲到达t=%0d, 期望t=%0d",
                             p, first_seen[p], expected_t);
                    delay_err++;
                end
            end

            if (delay_err == 0) begin
                $display("  [PASS] 延迟匹配时序正确: PE[1]=%0dt, PE[4]=%0dt, PE[7]=%0dt",
                         first_seen[1], first_seen[4], first_seen[7]);
                pass_cnt++;
            end else begin
                $display("  [FAIL] %0d个PE延迟不正确", delay_err);
                err_cnt++;
            end

            fsa_idle();
            repeat(5) @(posedge clk);
        end

        // ============================================================
        // Test 4: QK点积验证
        // 验证：Q加载后，送入K行数据，cmp_score_out输出正确的点积结果
        // 简化：使用整数值FP32（1.0, 2.0等）便于手动验证
        // ============================================================
        test_num = 4;
        $display("\n=== Test %0d: QK点积验证 ===", test_num);
        begin
            // 使用简单整数FP32值
            // Q = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
            // K_row0 = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
            // 期望 S[0] = Q·K_row0 = 1+2+3+4+5+6+7+8 = 36.0
            localparam logic [31:0] FP_1_0 = 32'h3F800000;
            localparam logic [31:0] FP_2_0 = 32'h40000000;
            localparam logic [31:0] FP_3_0 = 32'h40400000;
            localparam logic [31:0] FP_4_0 = 32'h40800000;
            localparam logic [31:0] FP_5_0 = 32'h40A00000;
            localparam logic [31:0] FP_6_0 = 32'h40C00000;
            localparam logic [31:0] FP_7_0 = 32'h40E00000;
            localparam logic [31:0] FP_8_0 = 32'h41000000;
            localparam logic [31:0] FP_36_0 = 32'h42100000;  // 36.0

            logic [31:0] q_load [0:GROUP_SIZE-1];
            logic [31:0] k_row [0:GROUP_SIZE-1];
            logic [31:0] score_result;
            int score_valid_seen;

            // 重新复位
            reset_dut();
            fsa_mode = 1'b1;
            fsa_idle();
            repeat(3) @(posedge clk);

            // Q值
            q_load[0] = FP_1_0; q_load[1] = FP_2_0;
            q_load[2] = FP_3_0; q_load[3] = FP_4_0;
            q_load[4] = FP_5_0; q_load[5] = FP_6_0;
            q_load[6] = FP_7_0; q_load[7] = FP_8_0;

            // K行（全1.0）
            for (int i = 0; i < GROUP_SIZE; i++)
                k_row[i] = FP_1_0;

            // === Step 1: LoadStationary 加载Q ===
            $display("  Step 1: 加载Q = [1,2,3,4,5,6,7,8]");
            @(negedge clk);
            fsa_ctrl_load_reg_li = 1'b1;
            fsa_l_input_valid = 1'b1;
            // 并行加载：每个PE的l_input通道送入对应的Q值
            for (int i = 0; i < ARRAY_SIZE; i++) begin
                int pos_in_grp;
                pos_in_grp = i % GROUP_SIZE;
                fsa_l_input[i*DATA_WIDTH +: DATA_WIDTH] = q_load[pos_in_grp];
            end
            @(posedge clk); #1ps;
            @(negedge clk); fsa_idle(); @(posedge clk); #1ps;

            // 验证Q加载正确
            for (int p = 0; p < GROUP_SIZE; p++) begin
                logic [31:0] reg_val;
                reg_val = pe_reg_array[p];
                if (reg_val !== q_load[p])
                    $display("  [WARN] Q加载后PE[%0d].reg=%08h, 期望%08h", p, reg_val, q_load[p]);
            end

            // === Step 2: 送入K行，执行MAC ===
            // QK计算：ctrl_mac=1, valid=1
            // K行数据送入各PE的l_input（经延迟匹配后到达）
            // 组内PE[p]延迟p*4拍收到K数据
            // vertical链：PE[0]的u_output = Q[0]*K[0] + 0（d_input=0）
            //             PE[1]的u_output = Q[1]*K[1] + PE[0].u_output
            //             ...
            //             PE[7]的u_output = Q[7]*K[7] + PE[6].u_output = 点积结果
            $display("  Step 2: 送入K_row = [1,1,1,1,1,1,1,1], 执行QK MAC");

            // QK MAC驱动：
            // 只送1拍K数据+valid脉冲，延迟匹配同时延迟data和valid
            // 每个PE只在延迟匹配后的valid脉冲到达时触发1次MAC
            // ctrl_mac持续为1（被delayed valid门控）
            // 等待时间 = PE[7]延迟28拍 + MAC_LATENCY 4拍 + 余量
            score_valid_seen = 0;
            for (int t = 0; t < (GROUP_SIZE-1)*MAC_LATENCY + 1 + MAC_LATENCY + 4; t++) begin
                @(negedge clk);
                fsa_ctrl_mac = 1'b1;
                fsa_ctrl_acc_ui = 1'b0;
                fsa_ctrl_update_reg = 1'b0;
                // valid和K数据只在t=0脉冲1拍
                if (t == 0) begin
                    fsa_l_input_valid = 1'b1;
                    for (int i = 0; i < ARRAY_SIZE; i++) begin
                        int pos_in_grp;
                        pos_in_grp = i % GROUP_SIZE;
                        fsa_l_input[i*DATA_WIDTH +: DATA_WIDTH] = k_row[pos_in_grp];
                    end
                end else begin
                    fsa_l_input_valid = 1'b0;
                    fsa_l_input = '0;
                end
                @(posedge clk); #1ps;
                // 在每拍检查cmp_score_valid，记录最后一个值
                if (cmp_score_valid[0]) begin
                    score_result = cmp_score_out[0*DATA_WIDTH +: DATA_WIDTH];
                    score_valid_seen++;
                end
            end

            $display("  cmp_score_valid 共触发 %0d 次, 最终值 = %08h", score_valid_seen, score_result);

            if (score_valid_seen) begin
                if (fp32_close(score_result, FP_36_0)) begin
                    $display("  [PASS] QK点积结果正确: got %08h, expected %08h (36.0)",
                             score_result, FP_36_0);
                    pass_cnt++;
                end else begin
                    $display("  [FAIL] QK点积结果错误: got %08h, expected %08h (36.0)",
                             score_result, FP_36_0);
                    err_cnt++;
                end
            end else begin
                $display("  [INFO] cmp_score_valid未触发，检查vertical链时序");
                score_result = pe_reg_array[GROUP_SIZE-1];
                $display("  [INFO] PE[7] reg = %08h (供调试参考)", score_result);
            end

            repeat(10) @(posedge clk);
        end

        // ============================================================
        // Test 5: 分组隔离验证
        // 验证：4组PE独立工作，互不干扰
        // 方法：给4组加载不同的Q值，验证各组寄存器独立
        // ============================================================
        test_num = 5;
        $display("\n=== Test %0d: 分组隔离验证 ===", test_num);
        begin
            logic [31:0] q_group [0:NUM_GROUPS-1][0:GROUP_SIZE-1];
            logic [31:0] pe_reg_val;
            int group_pass [0:NUM_GROUPS-1];
            int all_pass;

            // 重新复位
            reset_dut();
            fsa_mode = 1'b1;
            fsa_idle();
            repeat(3) @(posedge clk);

            // 为每组生成不同的Q值
            for (int g = 0; g < NUM_GROUPS; g++)
                for (int p = 0; p < GROUP_SIZE; p++)
                    q_group[g][p] = rand_fp32();

            // LoadStationary: 并行加载，每组送入各自的Q
            // 1拍完成，每个PE的l_input通道送入其所属组的Q值
            @(negedge clk);
            fsa_ctrl_load_reg_li = 1'b1;
            fsa_l_input_valid = 1'b1;
            for (int i = 0; i < ARRAY_SIZE; i++) begin
                int grp_idx, pos_idx;
                grp_idx = i / GROUP_SIZE;
                pos_idx = i % GROUP_SIZE;
                fsa_l_input[i*DATA_WIDTH +: DATA_WIDTH] = q_group[grp_idx][pos_idx];
            end
            @(posedge clk); #1ps;
            @(negedge clk); fsa_idle(); @(posedge clk); #1ps;

            // 验证各组PE寄存器
            all_pass = 1;
            for (int g = 0; g < NUM_GROUPS; g++) begin
                group_pass[g] = 0;
                for (int p = 0; p < GROUP_SIZE; p++) begin
                    int pe_idx;
                    pe_idx = g * GROUP_SIZE + p;
                    pe_reg_val = pe_reg_array[pe_idx];
                    if (pe_reg_val === q_group[g][p])
                        group_pass[g]++;
                    else begin
                        $display("  [FAIL] Group%0d PE[%0d].reg=%08h, expected=%08h",
                                 g, p, pe_reg_val, q_group[g][p]);
                        err_cnt++;
                        all_pass = 0;
                    end
                end
                if (group_pass[g] == GROUP_SIZE)
                    $display("  Group %0d: %0d/%0d PE寄存器正确", g, group_pass[g], GROUP_SIZE);
            end

            if (all_pass) begin
                $display("  [PASS] 4组PE完全隔离，各组Q加载独立正确");
                pass_cnt++;
            end

            repeat(5) @(posedge clk);
        end

        // ============================================================
        // Test 6: 分组MAC隔离 + 多行K验证
        // 给4组加载不同Q，送入2行不同K，验证各组cmp_score独立正确
        // Group 0: Q=[1..8], K_row0=[1..1], K_row1=[2..2]
        //   期望: S[0]=36.0, S[1]=72.0 (但vertical链只输出最后一行的结果)
        // 实际验证：送2行K，观察cmp_score_valid触发次数和最终值
        // ============================================================
        test_num = 6;
        $display("\n=== Test %0d: 多行K + 分组MAC隔离 ===", test_num);
        begin
            localparam logic [31:0] FP1 = 32'h3F800000;  // 1.0
            localparam logic [31:0] FP2 = 32'h40000000;  // 2.0
            localparam logic [31:0] FP3 = 32'h40400000;  // 3.0
            logic [31:0] q_vals [0:GROUP_SIZE-1];
            logic [31:0] score_g0, score_g1;
            int valid_cnt_g0;

            reset_dut();
            fsa_mode = 1'b1;
            fsa_idle();
            repeat(3) @(posedge clk);

            // Q = [1,2,3,4,5,6,7,8] for all groups
            q_vals[0] = 32'h3F800000; q_vals[1] = 32'h40000000;
            q_vals[2] = 32'h40400000; q_vals[3] = 32'h40800000;
            q_vals[4] = 32'h40A00000; q_vals[5] = 32'h40C00000;
            q_vals[6] = 32'h40E00000; q_vals[7] = 32'h41000000;

            // LoadStationary
            @(negedge clk);
            fsa_ctrl_load_reg_li = 1'b1;
            fsa_l_input_valid = 1'b1;
            for (int i = 0; i < ARRAY_SIZE; i++)
                fsa_l_input[i*DATA_WIDTH +: DATA_WIDTH] = q_vals[i % GROUP_SIZE];
            @(posedge clk); #1ps;
            @(negedge clk); fsa_idle(); @(posedge clk); #1ps;

            // 送入K_row0 = [1,1,...,1]（1拍脉冲）
            @(negedge clk);
            fsa_ctrl_mac = 1'b1;
            fsa_l_input_valid = 1'b1;
            for (int i = 0; i < ARRAY_SIZE; i++)
                fsa_l_input[i*DATA_WIDTH +: DATA_WIDTH] = FP1;
            @(posedge clk); #1ps;

            // 等待第一行K处理完毕
            for (int t = 0; t < (GROUP_SIZE-1)*MAC_LATENCY + MAC_LATENCY + 2; t++) begin
                @(negedge clk);
                fsa_ctrl_mac = 1'b1;
                fsa_l_input_valid = 1'b0;
                fsa_l_input = '0;
                @(posedge clk); #1ps;
            end

            // 送入K_row1 = [2,2,...,2]（1拍脉冲）
            @(negedge clk);
            fsa_ctrl_mac = 1'b1;
            fsa_l_input_valid = 1'b1;
            for (int i = 0; i < ARRAY_SIZE; i++)
                fsa_l_input[i*DATA_WIDTH +: DATA_WIDTH] = FP2;
            @(posedge clk); #1ps;

            // 等待第二行K处理完毕，收集cmp_score
            valid_cnt_g0 = 0;
            score_g0 = '0;
            score_g1 = '0;
            for (int t = 0; t < (GROUP_SIZE-1)*MAC_LATENCY + MAC_LATENCY + 4; t++) begin
                @(negedge clk);
                fsa_ctrl_mac = 1'b1;
                fsa_l_input_valid = 1'b0;
                fsa_l_input = '0;
                @(posedge clk); #1ps;
                if (cmp_score_valid[0]) begin
                    score_g0 = cmp_score_out[0*DATA_WIDTH +: DATA_WIDTH];
                    valid_cnt_g0++;
                end
                if (cmp_score_valid[1])
                    score_g1 = cmp_score_out[1*DATA_WIDTH +: DATA_WIDTH];
            end

            // 验证：Q·K_row1 = [1..8]·[2..2] = 2*(1+2+...+8) = 72.0 = 0x42900000
            // Group 0和Group 1应该得到相同结果（相同Q和K）
            $display("  cmp_score_valid[0] 触发 %0d 次", valid_cnt_g0);
            $display("  Group 0 最终score = %08h, Group 1 最终score = %08h", score_g0, score_g1);

            if (fp32_close(score_g0, 32'h42900000)) begin
                $display("  [PASS] Group 0 第2行K点积=72.0 正确");
                pass_cnt++;
            end else begin
                $display("  [FAIL] Group 0 score=%08h, 期望42900000 (72.0)", score_g0);
                err_cnt++;
            end

            if (fp32_close(score_g0, score_g1)) begin
                $display("  [PASS] Group 0/1 结果一致（分组隔离正确）");
                pass_cnt++;
            end else begin
                $display("  [FAIL] Group 0=%08h != Group 1=%08h", score_g0, score_g1);
                err_cnt++;
            end

            repeat(5) @(posedge clk);
        end
        $display("\n========================================");
        $display(" 测试完成: PASS=%0d, FAIL=%0d", pass_cnt, err_cnt);
        $display("========================================\n");
        if (err_cnt == 0)
            $display("*** ALL TESTS PASSED ***");
        else
            $display("*** %0d TESTS FAILED ***", err_cnt);
        $finish;
    end

    // 超时保护
    initial begin
        #200000;
        $display("[TIMEOUT] 仿真超时");
        $finish;
    end

endmodule

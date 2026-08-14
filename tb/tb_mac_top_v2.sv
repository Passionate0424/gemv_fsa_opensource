`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// tb_mac_top_v2
//
// 系统级验证：FSA模式QK点积端到端
// 通过DMA接口加载Q和K，FSM驱动完整QK_MAC流程，
// 验证cmp_score_out输出正确的点积结果。
//
// 简化：只验证到QK_MAC阶段（不含softmax后续流程）
// Q=[1,2,3,4,5,6,7,8], K=全1矩阵(8×8)
// 期望：每行score = 1+2+...+8 = 36.0
////////////////////////////////////////////////////////////////
module tb_mac_top_v2;

    localparam ARRAY_SIZE = 32;
    localparam DATA_WIDTH = 32;
    localparam K_ACCUM_DEPTH = 64;
    localparam MAC_LATENCY = 4;
    localparam GROUP_SIZE = 8;
    localparam NUM_GROUPS = 4;

    logic clk = 1'b0;
    always #1 clk = ~clk;
    logic rstn = 1'b0;

    initial begin
        if (!$test$plusargs("NO_WAVE")) begin
            $fsdbDumpfile("tb_mac_top_v2.fsdb");
            $fsdbDumpvars(0, tb_mac_top_v2);
        end
    end

    // DUT信号
    logic fsa_mode;
    logic os_start;
    logic dma_access_mode;
    logic [ARRAY_SIZE-1:0] dma_w_sram_bank_we;
    logic [$clog2(K_ACCUM_DEPTH)-1:0] dma_w_sram_waddr;
    logic [DATA_WIDTH-1:0] dma_w_sram_wdata;
    logic dma_v_sram_we;
    logic [$clog2(K_ACCUM_DEPTH)-1:0] dma_v_sram_waddr;
    logic [DATA_WIDTH-1:0] dma_v_sram_wdata;
    logic acc_en;
    logic w_mem_rst, v_mem_rst;
    wire  os_processing_done;

    logic fsa_start;
    logic [7:0] head_dim;
    logic [7:0] seq_tile_len;
    logic [7:0] num_kv_tiles;
    logic dma_done_sig;
    wire  fsa_dma_req_valid;
    wire  [1:0] fsa_dma_target;
    wire  fsa_dma_rw;
    wire  fsa_done_sig;

    // DUT例化
    mac_top_v2 #(
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
        .os_start(os_start),
        .dma_access_mode(dma_access_mode),
        .dma_w_sram_bank_we(dma_w_sram_bank_we),
        .dma_w_sram_waddr(dma_w_sram_waddr),
        .dma_w_sram_wdata(dma_w_sram_wdata),
        .dma_v_sram_we(dma_v_sram_we),
        .dma_v_sram_waddr(dma_v_sram_waddr),
        .dma_v_sram_wdata(dma_v_sram_wdata),
        .dma_v_sram_bank_sel(2'b00),
        .acc_en(acc_en),
        .w_mem_rst(w_mem_rst),
        .v_mem_rst(v_mem_rst),
        .os_processing_done(os_processing_done),
        .fsa_start(fsa_start),
        .head_dim(head_dim),
        .seq_tile_len(seq_tile_len),
        .num_kv_tiles(num_kv_tiles),
        .last_tile_valid(8'd0),.attn_scale(32'h3F0293EE),
        .dma_done(dma_done_sig),
        .fsa_dma_req_valid(fsa_dma_req_valid),
        .fsa_dma_target(fsa_dma_target),
        .fsa_dma_rw(fsa_dma_rw),
        .fsa_done(fsa_done_sig),
        .dma_o_sram_raddr(3'd0),
        .dma_o_sram_rdata()
    );

    // FP32常量
    localparam logic [31:0] FP_1 = 32'h3F800000;
    localparam logic [31:0] FP_2 = 32'h40000000;
    localparam logic [31:0] FP_3 = 32'h40400000;
    localparam logic [31:0] FP_4 = 32'h40800000;
    localparam logic [31:0] FP_5 = 32'h40A00000;
    localparam logic [31:0] FP_6 = 32'h40C00000;
    localparam logic [31:0] FP_7 = 32'h40E00000;
    localparam logic [31:0] FP_8 = 32'h41000000;
    localparam logic [31:0] FP_36 = 32'h42100000;

    logic [31:0] q_vals [0:7];
    initial begin
        q_vals[0]=FP_1; q_vals[1]=FP_2; q_vals[2]=FP_3; q_vals[3]=FP_4;
        q_vals[4]=FP_5; q_vals[5]=FP_6; q_vals[6]=FP_7; q_vals[7]=FP_8;
    end

    // DMA写入任务
    task automatic dma_write_vec_sram(input int addr, input logic [31:0] data);
        @(negedge clk);
        dma_v_sram_we = 1'b1;
        dma_v_sram_waddr = addr[$clog2(K_ACCUM_DEPTH)-1:0];
        dma_v_sram_wdata = data;
        @(posedge clk); #1ps;
        @(negedge clk);
        dma_v_sram_we = 1'b0;
    endtask

    task automatic dma_write_weight_sram(input int bank, input int addr, input logic [31:0] data);
        @(negedge clk);
        dma_w_sram_bank_we = (1 << bank);
        dma_w_sram_waddr = addr[$clog2(K_ACCUM_DEPTH)-1:0];
        dma_w_sram_wdata = data;
        @(posedge clk); #1ps;
        @(negedge clk);
        dma_w_sram_bank_we = '0;
    endtask

    // 模拟DMA完成响应
    task automatic respond_dma_done(input int delay);
        // 等待FSM发出DMA请求
        while (!fsa_dma_req_valid) @(posedge clk);
        repeat(delay) @(posedge clk);
        @(negedge clk); dma_done_sig = 1'b1;
        @(posedge clk); #1ps;
        @(negedge clk); dma_done_sig = 1'b0;
    endtask

    int err_cnt = 0;
    int pass_cnt = 0;

    // ULP比较
    function automatic logic fp_close(logic [31:0] a, logic [31:0] b);
        int diff;
        logic [31:0] abs_a, abs_b;
        if (a === b) return 1'b1;
        abs_a = a & 32'h7FFFFFFF;
        abs_b = b & 32'h7FFFFFFF;
        if (a[31] != b[31]) return (abs_a == 0 && abs_b == 0);
        diff = (abs_a > abs_b) ? (abs_a - abs_b) : (abs_b - abs_a);
        return (diff <= 4);
    endfunction

    initial begin
        $display("\n========================================");
        $display(" tb_mac_top_v2 系统级验证");
        $display("========================================\n");

        // 初始化
        fsa_mode = 1'b1;
        os_start = 1'b0;
        dma_access_mode = 1'b1;  // DMA加载模式
        dma_w_sram_bank_we = '0;
        dma_w_sram_waddr = '0;
        dma_w_sram_wdata = '0;
        dma_v_sram_we = 1'b0;
        dma_v_sram_waddr = '0;
        dma_v_sram_wdata = '0;
        acc_en = 1'b0;
        w_mem_rst = 1'b0;
        v_mem_rst = 1'b0;
        fsa_start = 1'b0;
        head_dim = 8;
        seq_tile_len = 8;
        num_kv_tiles = 1;
        dma_done_sig = 1'b0;

        rstn = 1'b0;
        #20;
        rstn = 1'b1;
        @(posedge clk); @(posedge clk);

        // ============================================================
        // Step 1: DMA加载Q到Vector SRAM
        // Q = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
        // ============================================================
        $display("Step 1: 加载Q到Vector SRAM");
        for (int i = 0; i < 8; i++)
            dma_write_vec_sram(i, q_vals[i]);

        // ============================================================
        // Step 2: DMA加载K到Input SRAM (Weight SRAM)
        // K = 8×8全1矩阵，bank[j]的addr[k]=1.0
        // ============================================================
        $display("Step 2: 加载K到Input SRAM (全1矩阵)");
        for (int bank = 0; bank < 8; bank++)
            for (int addr = 0; addr < 8; addr++)
                dma_write_weight_sram(bank, addr, FP_1);

        // 切换到计算模式
        @(negedge clk);
        dma_access_mode = 1'b0;
        @(posedge clk); #1ps;
        repeat(3) @(posedge clk);

        // ============================================================
        // Step 3: 启动FSA
        // ============================================================
        $display("Step 3: 启动FSA模式");
        @(negedge clk); fsa_start = 1'b1;
        @(posedge clk); #1ps;

        // 响应DMA请求（FSM会依次请求DMA_Q和DMA_K，都直接回done）
        fork
            begin
                respond_dma_done(2);  // DMA_Q完成
                respond_dma_done(2);  // DMA_K完成
            end
        join_none

        // ============================================================
        // Step 4: 等待并观察cmp_score_out
        // ============================================================
        $display("Step 4: 等待QK_MAC完成，观察cmp_score_out");
        begin
            logic [31:0] score_g0;
            int score_cnt;
            int trans_valid_cnt;
            score_cnt = 0;
            trans_valid_cnt = 0;
            score_g0 = '0;

            for (int t = 0; t < 500; t++) begin
                @(posedge clk); #1ps;

                // 跟踪transposer输出
                if (dut.trans_out_valid)
                    trans_valid_cnt++;

                // 跟踪PE[7]的delayed valid和MAC issue
                if (t >= 15 && t <= 70) begin
                    automatic logic pe7_valid_delayed = dut.u_pe_core.fsa_valid_delayed[7];
                    automatic logic pe7_ctrl_valid = dut.u_pe_core.pe_ctrl_valid[7];
                    automatic logic pe0_valid_delayed = dut.u_pe_core.fsa_valid_delayed[0];
                    automatic logic [31:0] pe7_l_input = dut.u_pe_core.pe_l_input_muxed[7];
                    automatic logic [31:0] pe7_d_input = dut.u_pe_core.pe_d_input_muxed[7];
                    if (pe7_valid_delayed || pe0_valid_delayed || dut.cmp_score_valid[0])
                        $display("  [WAV] t=%0d: pe0_vd=%b pe7_vd=%b pe7_cv=%b pe7_l=%08h pe7_d=%08h cmp_sv=%b score=%08h fsm=%0d",
                            t, pe0_valid_delayed, pe7_valid_delayed, pe7_ctrl_valid,
                            pe7_l_input, pe7_d_input,
                            dut.cmp_score_valid[0], dut.cmp_score_out[0*DATA_WIDTH +: DATA_WIDTH],
                            dut.fsm_state);
                end

                // 跟踪PE reg（Q加载是否正确）
                if (t == 20) begin
                    $display("  [DBG] t=%0d: PE[0].reg=%08h PE[1].reg=%08h PE[7].reg=%08h fsm_state=%0d",
                        t,
                        {dut.u_pe_core.PE_INST[0].u_pe.reg_sign,
                         dut.u_pe_core.PE_INST[0].u_pe.reg_exp,
                         dut.u_pe_core.PE_INST[0].u_pe.reg_mantissa},
                        {dut.u_pe_core.PE_INST[1].u_pe.reg_sign,
                         dut.u_pe_core.PE_INST[1].u_pe.reg_exp,
                         dut.u_pe_core.PE_INST[1].u_pe.reg_mantissa},
                        {dut.u_pe_core.PE_INST[7].u_pe.reg_sign,
                         dut.u_pe_core.PE_INST[7].u_pe.reg_exp,
                         dut.u_pe_core.PE_INST[7].u_pe.reg_mantissa},
                        dut.fsm_state);
                end

                // 跟踪transposer输出内容
                if (dut.trans_out_valid && trans_valid_cnt <= 2) begin
                    $display("  [DBG] trans_out[0]=%08h trans_out[1]=%08h (cnt=%0d)",
                        dut.trans_out_col[0*32 +: 32],
                        dut.trans_out_col[1*32 +: 32],
                        trans_valid_cnt);
                end

                // 跟踪PE[7]的u_output（cmp_score来源）
                // 只在QK_DRAIN(6)或CMP_UPDATE(7)阶段捕获有效score
                if (dut.cmp_score_valid[0]) begin
                    if (dut.fsm_state == 6 || dut.fsm_state == 7) begin
                        score_g0 = dut.cmp_score_out[0*DATA_WIDTH +: DATA_WIDTH];
                        score_cnt++;
                    end
                    if (score_cnt <= 8)
                        $display("  [DBG] cmp_score[0]=%08h (cnt=%0d, t=%0d, fsm=%0d)",
                            dut.cmp_score_out[0*DATA_WIDTH +: DATA_WIDTH], score_cnt, t, dut.fsm_state);
                end
            end

            $display("  trans_out_valid触发 %0d 次", trans_valid_cnt);
            $display("  cmp_score_valid触发 %0d 次, 最终score_g0 = %08h", score_cnt, score_g0);

            if (score_cnt > 0 && fp_close(score_g0, FP_36)) begin
                $display("  [PASS] QK点积端到端正确: 36.0");
                pass_cnt++;
            end else if (score_cnt > 0) begin
                $display("  [FAIL] QK点积错误: got %08h, exp %08h (36.0)", score_g0, FP_36);
                err_cnt++;
            end else begin
                $display("  [INFO] 未观察到cmp_score_valid，FSM state=%0d", dut.fsm_state);
                $display("  [INFO] 这可能是因为FSM的QK_MAC→CMP_UPDATE时序需要调试");
                err_cnt++;
            end
        end

        // ============================================================
        // 最终报告
        // ============================================================
        @(negedge clk); fsa_start = 1'b0;
        repeat(10) @(posedge clk);

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
        #500000;
        $display("[TIMEOUT] state=%0d", dut.fsm_state);
        $finish;
    end

endmodule

`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// tb_fsa_ctrl_fsm
//
// FSM状态转移功能验证：
//   1. 完整状态序列：IDLE→LOAD_Q→DMA_K→...→DONE
//   2. tile循环：多tile时正确回到DMA_K
//   3. 各状态持续拍数正确
//   4. 控制信号在正确状态输出
////////////////////////////////////////////////////////////////
module tb_fsa_ctrl_fsm;

    localparam GROUP_SIZE  = 8;
    localparam MAC_LATENCY = 4;
    localparam DATA_WIDTH  = 32;

    logic clk = 1'b0;
    always #1 clk = ~clk;
    logic rstn = 1'b0;

    initial begin
        if (!$test$plusargs("NO_WAVE")) begin
            $fsdbDumpfile("tb_fsa_ctrl_fsm.fsdb");
            $fsdbDumpvars(0, tb_fsa_ctrl_fsm);
        end
    end

    // DUT信号
    logic fsa_start;
    logic [7:0] head_dim;
    logic [7:0] seq_tile_len;
    logic [7:0] num_kv_tiles;
    logic [DATA_WIDTH-1:0] vec_sram_rdata;
    logic dma_done;
    logic acc_reciprocal_done;
    logic cmp_score_valid_in;

    wire ctrl_mac, ctrl_acc_ui, ctrl_load_reg_li;
    wire ctrl_flow_lr, ctrl_flow_ud, ctrl_flow_du;
    wire ctrl_update_reg, ctrl_exp2, ctrl_broadcast, ctrl_valid;
    wire [GROUP_SIZE*DATA_WIDTH-1:0] q_buf_out;
    wire q_buf_fire;
    wire trans_wr_en;
    wire [2:0] trans_wr_col;
    wire input_sram_rd_en;
    wire [5:0] input_sram_rd_addr;
    wire vec_sram_rd_en;
    wire [5:0] vec_sram_addr;
    wire cmp_ctrl_valid;
    wire [2:0] cmp_ctrl_cmd;
    wire [7:0] cmp_causal_counter;
    wire acc_ctrl_valid;
    wire [2:0] acc_ctrl_cmd;
    wire dma_req_valid;
    wire [1:0] dma_target;
    wire dma_rw;
    wire fsm_busy, fsm_done;
    wire [4:0] fsm_state;

    // DUT例化
    fsa_ctrl_fsm #(
        .GROUP_SIZE(GROUP_SIZE),
        .MAC_LATENCY(MAC_LATENCY),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clock(clk), .rst_n(rstn),
        .fsa_start(fsa_start),
        .head_dim(head_dim),
        .seq_tile_len(seq_tile_len),
        .num_kv_tiles(num_kv_tiles),
        .last_tile_valid(8'd0),
        .vec_sram_rdata(vec_sram_rdata),
        .ctrl_mac(ctrl_mac),
        .ctrl_acc_ui(ctrl_acc_ui),
        .ctrl_load_reg_li(ctrl_load_reg_li),
        .ctrl_flow_lr(ctrl_flow_lr),
        .ctrl_flow_ud(ctrl_flow_ud),
        .ctrl_flow_du(ctrl_flow_du),
        .ctrl_update_reg(ctrl_update_reg),
        .ctrl_exp2(ctrl_exp2),
        .ctrl_broadcast(ctrl_broadcast),
        .ctrl_valid(ctrl_valid),
        .q_buf_out(q_buf_out),
        .q_buf_fire(q_buf_fire),
        .trans_wr_en(trans_wr_en),
        .trans_wr_col(trans_wr_col),
        .input_sram_rd_en(input_sram_rd_en),
        .input_sram_rd_addr(input_sram_rd_addr),
        .vec_sram_rd_en(vec_sram_rd_en),
        .vec_sram_addr(vec_sram_addr),
        .cmp_ctrl_valid(cmp_ctrl_valid),
        .cmp_ctrl_cmd(cmp_ctrl_cmd),
        .cmp_causal_counter(cmp_causal_counter),
        .cmp_score_valid_in(cmp_score_valid_in),
        .acc_ctrl_valid(acc_ctrl_valid),
        .acc_ctrl_cmd(acc_ctrl_cmd),
        .acc_sram_rd_en(),
        .acc_sram_rd_addr(),
        .acc_sram_wr_en(),
        .acc_sram_wr_addr(),
        .dma_req_valid(dma_req_valid),
        .dma_target(dma_target),
        .dma_rw(dma_rw),
        .dma_done(dma_done),
        .acc_reciprocal_done(acc_reciprocal_done),
        .fsm_busy(fsm_busy),
        .fsm_done(fsm_done),
        .fsm_state(fsm_state)
    );

    // 状态名称（调试用）
    function automatic string state_name(input [4:0] s);
        case (s)
            0: return "IDLE";
            1: return "DMA_Q";
            2: return "LOAD_Q_BUF";
            3: return "LOAD_Q_FIRE";
            4: return "CMP_RESET";
            5: return "DMA_K";
            6: return "TRANSPOSE_K";
            7: return "QK_MAC";
            8: return "QK_DRAIN";
            9: return "CMP_UPDATE";
            10: return "CMP_PROP";
            11: return "SUBTRACT";
            12: return "SCALE";
            13: return "EXP2";
            14: return "ROWSUM";
            15: return "DMA_V";
            16: return "TRANSPOSE_V";
            17: return "PV_MAC";
            18: return "PV_DRAIN";
            19: return "ACC_CORRECT";
            20: return "TILE_CHECK";
            21: return "RECIPROCAL";
            22: return "NORM";
            23: return "DMA_O";
            24: return "DONE";
            default: return "UNKNOWN";
        endcase
    endfunction

    // 等待进入指定状态
    task automatic wait_state(input [4:0] target, input int timeout);
        int cnt = 0;
        while (fsm_state !== target && cnt < timeout) begin
            @(posedge clk); #1ps;
            cnt++;
        end
        if (fsm_state !== target)
            $display("  [TIMEOUT] 等待状态%s超时(%0d拍)", state_name(target), timeout);
    endtask

    // 模拟DMA完成（延迟几拍后拉高dma_done 1拍）
    task automatic sim_dma_done(input int delay);
        repeat(delay) @(posedge clk);
        @(negedge clk); dma_done = 1'b1;
        @(posedge clk); #1ps;
        @(negedge clk); dma_done = 1'b0;
    endtask

    int err_cnt = 0;
    int pass_cnt = 0;

    // ========== 测试主体 ==========
    initial begin
        $display("\n========================================");
        $display(" tb_fsa_ctrl_fsm 验证");
        $display("========================================\n");

        fsa_start = 0;
        head_dim = 8;
        seq_tile_len = 8;
        num_kv_tiles = 2;
        vec_sram_rdata = 32'h3F800000;
        dma_done = 0;
        acc_reciprocal_done = 0;
        cmp_score_valid_in = 0;

        rstn = 0; #10; rstn = 1;
        @(posedge clk); @(posedge clk);

        // ============================================================
        // Test 1: 完整状态序列（单tile简化：num_kv_tiles=1）
        // ============================================================
        $display("=== Test 1: 完整状态序列 (1 tile) ===");
        begin
            int state_log [0:31];
            int state_cnt = 0;
            int prev_state = -1;

            num_kv_tiles = 1;
            @(negedge clk); fsa_start = 1'b1;
            @(posedge clk); #1ps;

            // 记录状态转移序列
            fork
                // DMA_Q完成
                begin
                    wait_state(1, 10);  // DMA_Q
                    sim_dma_done(3);
                end
                // DMA_K完成
                begin
                    wait_state(5, 30);  // DMA_K
                    sim_dma_done(3);
                end
                // CMP_UPDATE：模拟8个score到达
                begin
                    wait_state(9, 500);  // CMP_UPDATE
                    repeat(2) @(posedge clk);
                    for (int i = 0; i < 8; i++) begin
                        @(negedge clk); cmp_score_valid_in = 1'b1;
                        @(posedge clk); #1ps;
                        @(negedge clk); cmp_score_valid_in = 1'b0;
                        @(posedge clk); #1ps;
                    end
                end
                // DMA_V完成
                begin
                    wait_state(15, 800);  // DMA_V
                    sim_dma_done(3);
                end
                // RECIPROCAL完成
                begin
                    wait_state(21, 1200);  // RECIPROCAL
                    repeat(14) @(posedge clk);
                    @(negedge clk); acc_reciprocal_done = 1'b1;
                    @(posedge clk); #1ps;
                    @(negedge clk); acc_reciprocal_done = 1'b0;
                end
                // DMA_O完成
                begin
                    wait_state(23, 1500);  // DMA_O
                    sim_dma_done(3);
                end
            join_none

            // 等待FSM完成
            wait_state(24, 2000);  // DONE

            if (fsm_state == 24) begin
                $display("  [PASS] FSM完整走完所有状态到DONE");
                pass_cnt++;
            end else begin
                $display("  [FAIL] FSM未到达DONE，停在状态%s(%0d)", state_name(fsm_state), fsm_state);
                err_cnt++;
            end

            // 清理
            @(negedge clk); fsa_start = 1'b0;
            repeat(5) @(posedge clk);
        end

        // ============================================================
        // Test 2: tile循环（2 tiles）
        // ============================================================
        $display("\n=== Test 2: tile循环 (2 tiles) ===");
        begin
            int dma_k_cnt = 0;

            // 复位
            rstn = 0; #10; rstn = 1;
            @(posedge clk); @(posedge clk);

            num_kv_tiles = 2;
            @(negedge clk); fsa_start = 1'b1;
            @(posedge clk); #1ps;

            fork
                // DMA_Q + DMA_K响应
                begin
                    forever begin
                        @(posedge clk); #1ps;
                        if ((fsm_state == 1 || fsm_state == 5) && dma_req_valid) begin
                            if (fsm_state == 5) dma_k_cnt++;
                            sim_dma_done(3);
                        end
                    end
                end
                // DMA_V完成
                begin
                    forever begin
                        @(posedge clk); #1ps;
                        if (fsm_state == 15 && dma_req_valid) begin
                            sim_dma_done(3);
                        end
                    end
                end
                // CMP_UPDATE：模拟score到达
                begin
                    forever begin
                        @(posedge clk); #1ps;
                        if (fsm_state == 9) begin
                            repeat(2) @(posedge clk);
                            for (int i = 0; i < seq_tile_len; i++) begin
                                @(negedge clk); cmp_score_valid_in = 1'b1;
                                @(posedge clk); #1ps;
                                @(negedge clk); cmp_score_valid_in = 1'b0;
                                @(posedge clk); #1ps;
                            end
                        end
                    end
                end
                // RECIPROCAL完成
                begin
                    wait_state(21, 4000);
                    repeat(14) @(posedge clk);
                    @(negedge clk); acc_reciprocal_done = 1'b1;
                    @(posedge clk); #1ps;
                    @(negedge clk); acc_reciprocal_done = 1'b0;
                end
                // DMA_O完成
                begin
                    wait_state(23, 5000);
                    sim_dma_done(3);
                end
                // 超时保护
                begin
                    wait_state(24, 5000);
                end
            join_any
            disable fork;

            // 等待FSM到达DONE
            if (fsm_state != 24) begin
                // 等到DMA_O状态再发dma_done
                wait_state(23, 100);
                if (fsm_state == 23) sim_dma_done(2);
                wait_state(24, 100);
            end

            if (fsm_state == 24 && dma_k_cnt == 2) begin
                $display("  [PASS] 2 tiles循环正确 (DMA_K进入%0d次)", dma_k_cnt);
                pass_cnt++;
            end else begin
                $display("  [FAIL] tiles=%0d(期望2), state=%s", dma_k_cnt, state_name(fsm_state));
                err_cnt++;
            end

            @(negedge clk); fsa_start = 1'b0;
            repeat(5) @(posedge clk);
        end

        // ============================================================
        // Test 3: 关键状态持续拍数验证
        // ============================================================
        $display("\n=== Test 3: 状态持续拍数 ===");
        begin
            int load_q_buf_cycles, transpose_k_cycles, cmp_prop_cycles;

            rstn = 0; #10; rstn = 1;
            @(posedge clk); @(posedge clk);

            num_kv_tiles = 1;
            @(negedge clk); fsa_start = 1'b1;
            @(posedge clk); #1ps;

            // DMA_Q完成
            wait_state(1, 10); sim_dma_done(2);

            // 测量LOAD_Q_BUF持续拍数（state=2）
            wait_state(2, 10);
            load_q_buf_cycles = 0;
            while (fsm_state == 2) begin
                @(posedge clk); #1ps;
                load_q_buf_cycles++;
            end

            // DMA_K完成（state=5）
            fork
                begin wait_state(5, 10); sim_dma_done(2); end
            join_none

            // 测量TRANSPOSE_K持续拍数（state=6）
            wait_state(6, 20);
            transpose_k_cycles = 0;
            while (fsm_state == 6) begin
                @(posedge clk); #1ps;
                transpose_k_cycles++;
            end

            // CMP_UPDATE：模拟score（state=9）
            fork
                begin
                    wait_state(9, 200);
                    repeat(2) @(posedge clk);
                    for (int i = 0; i < 8; i++) begin
                        @(negedge clk); cmp_score_valid_in = 1'b1;
                        @(posedge clk); #1ps;
                        @(negedge clk); cmp_score_valid_in = 1'b0;
                        @(posedge clk); #1ps;
                    end
                end
            join_none

            // 等到CMP_PROP（state=10）
            wait_state(10, 300);
            cmp_prop_cycles = 0;
            while (fsm_state == 10) begin
                @(posedge clk); #1ps;
                cmp_prop_cycles++;
            end

            // 完成剩余流程
            fork
                begin wait_state(15, 500); sim_dma_done(2); end  // DMA_V
                begin
                    wait_state(21, 1000);  // RECIPROCAL
                    repeat(14) @(posedge clk);
                    @(negedge clk); acc_reciprocal_done = 1'b1;
                    @(posedge clk); #1ps;
                    @(negedge clk); acc_reciprocal_done = 1'b0;
                end
                begin wait_state(23, 1500); sim_dma_done(2); end  // DMA_O
            join_none
            wait_state(24, 2000);
            disable fork;

            $display("  LOAD_Q_BUF: %0d拍 (期望%0d)", load_q_buf_cycles, head_dim + 1);
            $display("  TRANSPOSE_K: %0d拍 (期望%0d)", transpose_k_cycles, head_dim);
            $display("  CMP_PROP: %0d拍 (期望10)", cmp_prop_cycles);

            if (load_q_buf_cycles == head_dim + 1 &&
                transpose_k_cycles == head_dim &&
                cmp_prop_cycles == 10) begin
                $display("  [PASS] 关键状态持续拍数正确");
                pass_cnt++;
            end else begin
                $display("  [FAIL] 持续拍数不匹配");
                err_cnt++;
            end

            @(negedge clk); fsa_start = 1'b0;
            repeat(5) @(posedge clk);
        end

        // ============================================================
        // Test 4: broadcast信号验证
        // ============================================================
        $display("\n=== Test 4: broadcast信号 ===");
        begin
            int subtract_broadcast, scale_broadcast, exp2_broadcast;

            rstn = 0; #10; rstn = 1;
            @(posedge clk); @(posedge clk);

            num_kv_tiles = 1;
            @(negedge clk); fsa_start = 1'b1;
            @(posedge clk); #1ps;

            // 响应DMA和CMP事件
            fork
                begin wait_state(1, 10); sim_dma_done(2); end  // DMA_Q
                begin wait_state(5, 30); sim_dma_done(2); end  // DMA_K
                begin
                    wait_state(9, 300);  // CMP_UPDATE
                    repeat(2) @(posedge clk);
                    for (int i = 0; i < 8; i++) begin
                        @(negedge clk); cmp_score_valid_in = 1'b1;
                        @(posedge clk); #1ps;
                        @(negedge clk); cmp_score_valid_in = 1'b0;
                        @(posedge clk); #1ps;
                    end
                end
            join_none

            // 等待SUBTRACT状态（state=11），检查broadcast
            wait_state(11, 500);
            subtract_broadcast = ctrl_broadcast;

            wait_state(12, 20);
            scale_broadcast = ctrl_broadcast;

            wait_state(13, 20);
            exp2_broadcast = ctrl_broadcast;

            // 完成剩余
            fork
                begin wait_state(15, 500); sim_dma_done(2); end  // DMA_V
                begin
                    wait_state(21, 1500);  // RECIPROCAL
                    repeat(14) @(posedge clk);
                    @(negedge clk); acc_reciprocal_done = 1'b1;
                    @(posedge clk); #1ps;
                    @(negedge clk); acc_reciprocal_done = 1'b0;
                end
                begin wait_state(23, 2000); sim_dma_done(2); end  // DMA_O
            join_none
            wait_state(24, 2500);
            disable fork;

            if (subtract_broadcast && scale_broadcast && exp2_broadcast) begin
                $display("  [PASS] SUBTRACT/SCALE/EXP2状态broadcast=1");
                pass_cnt++;
            end else begin
                $display("  [FAIL] broadcast: SUB=%0d SCALE=%0d EXP2=%0d",
                         subtract_broadcast, scale_broadcast, exp2_broadcast);
                err_cnt++;
            end

            @(negedge clk); fsa_start = 1'b0;
            repeat(5) @(posedge clk);
        end

        // ============================================================
        // 最终报告
        // ============================================================
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
        #200000;
        $display("[TIMEOUT] 仿真超时");
        $finish;
    end

endmodule

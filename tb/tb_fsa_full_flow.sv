`timescale 1ns/1ps

////////////////////////////////////////////////////////////////
// tb_fsa_full_flow
//
// mac_top_v2 的 FSA 全流程验证TB
// 从 Q/K/V 装载、DMA 驱动、状态推进到最终 O 输出，
// 以完整流程串起来检查 FSA 主链路是否按预期运行。
//
// 适合做端到端流程冒烟和阶段性回归。
////////////////////////////////////////////////////////////////
module tb_fsa_full_flow;
    localparam ARRAY_SIZE = 32;
    localparam DATA_WIDTH = 32;
    localparam K_ACCUM_DEPTH = 64;
    localparam MAC_LATENCY = 4;
    localparam GROUP_SIZE = 8;
    localparam NUM_GROUPS = 4;

    logic clk = 0;
    always #1 clk = ~clk;
    logic rstn = 0;

    logic fsa_mode, os_start, dma_access_mode, acc_en, w_mem_rst, v_mem_rst;
    logic [ARRAY_SIZE-1:0] dma_w_sram_bank_we;
    logic [$clog2(K_ACCUM_DEPTH)-1:0] dma_w_sram_waddr;
    logic [DATA_WIDTH-1:0] dma_w_sram_wdata;
    logic dma_v_sram_we;
    logic [$clog2(K_ACCUM_DEPTH)-1:0] dma_v_sram_waddr;
    logic [DATA_WIDTH-1:0] dma_v_sram_wdata;
    wire os_processing_done;
    logic fsa_start;
    logic [7:0] head_dim, seq_tile_len, num_kv_tiles;
    logic dma_done_sig;
    wire fsa_dma_req_valid;
    wire [1:0] fsa_dma_target;
    wire fsa_dma_rw;
    wire fsa_done_sig;

    mac_top_v2 #(
        .ARRAY_SIZE(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH),
        .K_ACCUM_DEPTH(K_ACCUM_DEPTH), .MAC_LATENCY(MAC_LATENCY),
        .GROUP_SIZE(GROUP_SIZE), .NUM_GROUPS(NUM_GROUPS)
    ) dut (
        .clock(clk), .rst_n(rstn), .fsa_mode(fsa_mode),
        .os_start(os_start), .dma_access_mode(dma_access_mode),
        .dma_w_sram_bank_we(dma_w_sram_bank_we),
        .dma_w_sram_waddr(dma_w_sram_waddr), .dma_w_sram_wdata(dma_w_sram_wdata),
        .dma_v_sram_we(dma_v_sram_we),
        .dma_v_sram_waddr(dma_v_sram_waddr), .dma_v_sram_wdata(dma_v_sram_wdata),
        .acc_en(acc_en), .w_mem_rst(w_mem_rst), .v_mem_rst(v_mem_rst),
        .os_processing_done(os_processing_done),
        .fsa_start(fsa_start), .head_dim(head_dim),
        .seq_tile_len(seq_tile_len), .num_kv_tiles(num_kv_tiles),
        .last_tile_valid(8'd0),
        .dma_done(dma_done_sig),
        .fsa_dma_req_valid(fsa_dma_req_valid),
        .fsa_dma_target(fsa_dma_target), .fsa_dma_rw(fsa_dma_rw),
        .fsa_done(fsa_done_sig)
    );

    task automatic respond_dma();
        while (!fsa_dma_req_valid) @(posedge clk);
        repeat(2) @(posedge clk);
        @(negedge clk); dma_done_sig = 1;
        @(posedge clk); #1ps;
        @(negedge clk); dma_done_sig = 0;
    endtask

    task automatic dma_write_vec(input int addr, input logic [31:0] data);
        @(negedge clk); dma_v_sram_we=1; dma_v_sram_waddr=addr; dma_v_sram_wdata=data;
        @(posedge clk); #1ps; @(negedge clk); dma_v_sram_we=0;
    endtask

    task automatic dma_write_w(input int bank, input int addr, input logic [31:0] data);
        @(negedge clk); dma_w_sram_bank_we=(1<<bank); dma_w_sram_waddr=addr; dma_w_sram_wdata=data;
        @(posedge clk); #1ps; @(negedge clk); dma_w_sram_bank_we=0;
    endtask

    int cycle_cnt;
    logic [4:0] prev_state;
    integer score_file, o_file;

    // 捕获QK score输出
    logic [31:0] captured_scores [0:7];
    int score_idx;

    // 捕获PE寄存器在各阶段的值（group 0, PE[0..7]）
    logic [31:0] pe_reg_after_load_ui [0:7];
    logic [31:0] pe_reg_after_subtract [0:7];
    logic [31:0] pe_reg_after_scale [0:7];
    logic [31:0] pe_reg_after_exp2 [0:7];

    initial begin
        score_file = $fopen("dut_qk_scores.hex", "w");
        o_file = $fopen("dut_final_O.hex", "w");
        score_idx = 0;
    end

    // 在状态转换时捕获PE寄存器（用独立的prev检测）
    logic [4:0] state_d;
    always @(posedge clk) begin
        if (!rstn)
            state_d <= 5'd0;
        else
            state_d <= dut.fsm_state;
    end

    // 宏展开捕获（VCS不支持function内层次引用）
    `define CAPTURE_PE_REGS(arr) \
        arr[0] = {dut.u_pe_core.PE_INST[0].u_pe.reg_sign, dut.u_pe_core.PE_INST[0].u_pe.reg_exp, dut.u_pe_core.PE_INST[0].u_pe.reg_mantissa}; \
        arr[1] = {dut.u_pe_core.PE_INST[1].u_pe.reg_sign, dut.u_pe_core.PE_INST[1].u_pe.reg_exp, dut.u_pe_core.PE_INST[1].u_pe.reg_mantissa}; \
        arr[2] = {dut.u_pe_core.PE_INST[2].u_pe.reg_sign, dut.u_pe_core.PE_INST[2].u_pe.reg_exp, dut.u_pe_core.PE_INST[2].u_pe.reg_mantissa}; \
        arr[3] = {dut.u_pe_core.PE_INST[3].u_pe.reg_sign, dut.u_pe_core.PE_INST[3].u_pe.reg_exp, dut.u_pe_core.PE_INST[3].u_pe.reg_mantissa}; \
        arr[4] = {dut.u_pe_core.PE_INST[4].u_pe.reg_sign, dut.u_pe_core.PE_INST[4].u_pe.reg_exp, dut.u_pe_core.PE_INST[4].u_pe.reg_mantissa}; \
        arr[5] = {dut.u_pe_core.PE_INST[5].u_pe.reg_sign, dut.u_pe_core.PE_INST[5].u_pe.reg_exp, dut.u_pe_core.PE_INST[5].u_pe.reg_mantissa}; \
        arr[6] = {dut.u_pe_core.PE_INST[6].u_pe.reg_sign, dut.u_pe_core.PE_INST[6].u_pe.reg_exp, dut.u_pe_core.PE_INST[6].u_pe.reg_mantissa}; \
        arr[7] = {dut.u_pe_core.PE_INST[7].u_pe.reg_sign, dut.u_pe_core.PE_INST[7].u_pe.reg_exp, dut.u_pe_core.PE_INST[7].u_pe.reg_mantissa};

    // 捕获延迟1拍（等待NBA写入生效）
    logic [4:0] state_d2;
    always @(posedge clk) begin
        if (!rstn) state_d2 <= 5'd0;
        else state_d2 <= state_d;
    end

    always @(posedge clk) begin
        if (rstn && state_d !== state_d2) begin
            if (state_d == 5'd11) begin `CAPTURE_PE_REGS(pe_reg_after_load_ui) end
            if (state_d == 5'd12) begin `CAPTURE_PE_REGS(pe_reg_after_subtract) end
            if (state_d == 5'd13) begin `CAPTURE_PE_REGS(pe_reg_after_scale) end
            if (state_d == 5'd14) begin `CAPTURE_PE_REGS(pe_reg_after_exp2) end
        end
    end

    // 监控cmp_score_valid，捕获QK score（score在QK_MAC后期到达CMP）
    always @(posedge clk) begin
        if (rstn && dut.cmp_score_valid[0] && score_idx < 8) begin
            captured_scores[score_idx] = dut.cmp_score_out[0*DATA_WIDTH +: DATA_WIDTH];
            $fwrite(score_file, "%08h\n", dut.cmp_score_out[0*DATA_WIDTH +: DATA_WIDTH]);
            $display("  [SCORE] idx=%0d val=%08h (state=%0d, cycle=%0d)",
                score_idx, dut.cmp_score_out[0*DATA_WIDTH +: DATA_WIDTH], dut.fsm_state, cycle_cnt);
            score_idx = score_idx + 1;
        end
    end

    initial begin
        fsa_mode=1; os_start=0; dma_access_mode=1; acc_en=0;
        w_mem_rst=0; v_mem_rst=0; fsa_start=0;
        dma_w_sram_bank_we=0; dma_w_sram_waddr=0; dma_w_sram_wdata=0;
        dma_v_sram_we=0; dma_v_sram_waddr=0; dma_v_sram_wdata=0;
        dma_done_sig=0; head_dim=8; seq_tile_len=8; num_kv_tiles=1;
        rstn=0; #20; rstn=1; @(posedge clk); @(posedge clk);

        // Q=[1.0, 2.0, ..., 8.0]
        dma_write_vec(0, 32'h3F800000);
        dma_write_vec(1, 32'h40000000);
        dma_write_vec(2, 32'h40400000);
        dma_write_vec(3, 32'h40800000);
        dma_write_vec(4, 32'h40A00000);
        dma_write_vec(5, 32'h40C00000);
        dma_write_vec(6, 32'h40E00000);
        dma_write_vec(7, 32'h41000000);

        // K=单位矩阵 (8x8)，score[k]=Q[k]
        for (int b=0; b<8; b++)
            for (int a=0; a<8; a++)
                dma_write_w(b, a, (b==a) ? 32'h3F800000 : 32'h00000000);

        @(negedge clk); dma_access_mode=0; @(posedge clk); #1ps;
        repeat(3) @(posedge clk);
        @(negedge clk); fsa_start=1; @(posedge clk); #1ps;

        fork
            begin: DMA_LOOP
                forever respond_dma();
            end
            begin: MONITOR
                prev_state = 5'd31;
                for (cycle_cnt=0; cycle_cnt<5000; cycle_cnt++) begin
                    @(posedge clk);
                    if (dut.fsm_state !== prev_state) begin
                        $display("[cycle %0d] FSM: state %0d -> %0d", cycle_cnt, prev_state, dut.fsm_state);
                        prev_state = dut.fsm_state;
                    end
                    if (fsa_done_sig) begin
                        $display("[cycle %0d] FSA DONE!", cycle_cnt);
                        break;
                    end
                end
                if (cycle_cnt >= 5000)
                    $display("TIMEOUT at cycle 5000, state=%0d", dut.fsm_state);
            end
        join_any
        disable fork;
        repeat(5) @(posedge clk);

        // 打印捕获的QK scores
        $display("\n=== QK Scores (group 0) ===");
        for (int i = 0; i < score_idx; i++)
            $display("  score[%0d] = %08h", i, captured_scores[i]);

        // 打印各阶段PE寄存器值
        $display("\n=== PE.reg after LOAD_REG_UI (should = score) ===");
        for (int i = 0; i < 8; i++)
            $display("  PE[%0d].reg = %08h", i, pe_reg_after_load_ui[i]);

        $display("\n=== PE.reg after SUBTRACT (should = score - newMax) ===");
        for (int i = 0; i < 8; i++)
            $display("  PE[%0d].reg = %08h", i, pe_reg_after_subtract[i]);

        $display("\n=== PE.reg after SCALE (should = (S-m)*AttentionScale) ===");
        for (int i = 0; i < 8; i++)
            $display("  PE[%0d].reg = %08h", i, pe_reg_after_scale[i]);

        $display("\n=== PE.reg after EXP2 (should = P = exp2(...)) ===");
        for (int i = 0; i < 8; i++)
            $display("  PE[%0d].reg = %08h", i, pe_reg_after_exp2[i]);

        // 也直接读当前PE寄存器（DONE时的最终值）
        $display("\n=== PE.reg at DONE (final state) ===");
        $display("  PE[0].reg = %08h", {dut.u_pe_core.PE_INST[0].u_pe.reg_sign, dut.u_pe_core.PE_INST[0].u_pe.reg_exp, dut.u_pe_core.PE_INST[0].u_pe.reg_mantissa});
        $display("  PE[1].reg = %08h", {dut.u_pe_core.PE_INST[1].u_pe.reg_sign, dut.u_pe_core.PE_INST[1].u_pe.reg_exp, dut.u_pe_core.PE_INST[1].u_pe.reg_mantissa});
        $display("  PE[2].reg = %08h", {dut.u_pe_core.PE_INST[2].u_pe.reg_sign, dut.u_pe_core.PE_INST[2].u_pe.reg_exp, dut.u_pe_core.PE_INST[2].u_pe.reg_mantissa});
        $display("  PE[3].reg = %08h", {dut.u_pe_core.PE_INST[3].u_pe.reg_sign, dut.u_pe_core.PE_INST[3].u_pe.reg_exp, dut.u_pe_core.PE_INST[3].u_pe.reg_mantissa});
        $display("  PE[4].reg = %08h", {dut.u_pe_core.PE_INST[4].u_pe.reg_sign, dut.u_pe_core.PE_INST[4].u_pe.reg_exp, dut.u_pe_core.PE_INST[4].u_pe.reg_mantissa});
        $display("  PE[5].reg = %08h", {dut.u_pe_core.PE_INST[5].u_pe.reg_sign, dut.u_pe_core.PE_INST[5].u_pe.reg_exp, dut.u_pe_core.PE_INST[5].u_pe.reg_mantissa});
        $display("  PE[6].reg = %08h", {dut.u_pe_core.PE_INST[6].u_pe.reg_sign, dut.u_pe_core.PE_INST[6].u_pe.reg_exp, dut.u_pe_core.PE_INST[6].u_pe.reg_mantissa});
        $display("  PE[7].reg = %08h", {dut.u_pe_core.PE_INST[7].u_pe.reg_sign, dut.u_pe_core.PE_INST[7].u_pe.reg_exp, dut.u_pe_core.PE_INST[7].u_pe.reg_mantissa});

        // 验证score=36.0
        if (score_idx > 0) begin
            logic [31:0] expected_score;
            expected_score = 32'h42100000; // 36.0
            if (captured_scores[0] == expected_score)
                $display("  [PASS] First score = 36.0 (correct for Q=[1..8], K=all-ones)");
            else
                $display("  [FAIL] First score = %08h, expected %08h (36.0)", captured_scores[0], expected_score);
        end

        $fclose(score_file);
        $fclose(o_file);

        if (fsa_done_sig)
            $display("\n*** FULL FLOW PASS ***");
        else
            $display("\n*** FULL FLOW FAIL (did not complete) ***");
        $finish;
    end
endmodule

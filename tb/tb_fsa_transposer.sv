`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// tb_fsa_transposer
//
// 验证fsa_transposer的转置正确性：
//   1. 基本转置：写入已知8×8矩阵，验证输出为转置
//   2. 连续tile：连续输入多个tile，验证流水无气泡
//   3. 单位矩阵：I的转置=I
//   4. 随机矩阵：随机数据与golden对比
////////////////////////////////////////////////////////////////
module tb_fsa_transposer;

    localparam int DIM = 8;
    localparam int DATA_WIDTH = 32;

    logic clk = 1'b0;
    always #1 clk = ~clk;

    logic rstn = 1'b0;
    int unsigned cycle = 0;
    always @(posedge clk) cycle <= cycle + 1;

    initial begin
        if (!$test$plusargs("NO_WAVE")) begin
            $fsdbDumpfile("tb_fsa_transposer.fsdb");
            $fsdbDumpvars(0, tb_fsa_transposer);
        end
    end

    // ========== DUT信号 ==========
    logic [DIM*DATA_WIDTH-1:0] in_row;
    logic in_valid;
    wire  in_ready;
    wire  [DIM*DATA_WIDTH-1:0] out_col;
    wire  out_valid;

    // ========== DUT例化 ==========
    fsa_transposer #(
        .DIM(DIM),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clock(clk),
        .rst_n(rstn),
        .in_row(in_row),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .out_col(out_col),
        .out_valid(out_valid)
    );

    // ========== 辅助函数 ==========
    function automatic logic [31:0] pack_val(int row, int col);
        // 编码行列信息便于调试：高16位=row，低16位=col
        pack_val = {16'(row), 16'(col)};
    endfunction

    // ========== 错误计数 ==========
    int err_cnt = 0;
    int pass_cnt = 0;

    // ========== 测试主体 ==========
    initial begin
        $display("\n========================================");
        $display(" tb_fsa_transposer 验证");
        $display("========================================\n");

        in_valid = 1'b0;
        in_row = '0;
        rstn = 1'b0;
        #20;
        rstn = 1'b1;
        @(posedge clk); @(posedge clk);
        #1ps;

        // ============================================================
        // Test 1: 基本转置验证
        // 写入矩阵A[r][c] = (r+1)*10 + (c+1)，验证输出为A^T
        // ============================================================
        $display("=== Test 1: 基本转置验证 ===");
        begin
            logic [31:0] matrix_a [0:DIM-1][0:DIM-1];
            logic [31:0] expected_t [0:DIM-1][0:DIM-1];
            logic [31:0] got_row [0:DIM-1];
            int out_row_idx;
            int t1_err;

            // 构造测试矩阵
            // 输入按列送入A，期望输出按行读出A（列→行重排=转置操作）
            for (int r = 0; r < DIM; r++)
                for (int c = 0; c < DIM; c++) begin
                    matrix_a[r][c] = (r+1)*10 + (c+1);
                    expected_t[r][c] = matrix_a[r][c];  // 输出第j行 = A的第j行
                end

            // 第一轮：填充grid（LEFT阶段，输出无效）
            for (int t = 0; t < DIM; t++) begin
                @(negedge clk);
                in_valid = 1'b1;
                for (int r = 0; r < DIM; r++)
                    in_row[r*DATA_WIDTH +: DATA_WIDTH] = matrix_a[r][t];
                @(posedge clk); #1ps;
            end

            // 第二轮：送入dummy数据（UP阶段），同时读出转置结果
            t1_err = 0;
            out_row_idx = 0;
            for (int t = 0; t < DIM; t++) begin
                @(negedge clk);
                in_valid = 1'b1;
                // 送入全0作为dummy
                in_row = '0;
                @(posedge clk); #1ps;

                if (out_valid) begin
                    for (int c = 0; c < DIM; c++) begin
                        got_row[c] = out_col[c*DATA_WIDTH +: DATA_WIDTH];
                        if (got_row[c] !== expected_t[out_row_idx][c]) begin
                            $display("  [FAIL] T[%0d][%0d]: got %0d, expected %0d",
                                     out_row_idx, c, got_row[c], expected_t[out_row_idx][c]);
                            t1_err++;
                        end
                    end
                    out_row_idx++;
                end
            end

            if (t1_err == 0 && out_row_idx == DIM) begin
                $display("  [PASS] 8x8矩阵转置正确");
                pass_cnt++;
            end else begin
                $display("  [FAIL] 转置错误 (errors=%0d, rows_out=%0d)", t1_err, out_row_idx);
                err_cnt++;
            end
        end

        // 停止输入几拍
        @(negedge clk); in_valid = 1'b0; @(posedge clk);
        repeat(3) @(posedge clk);

        // ============================================================
        // Test 2: 连续tile验证
        // 连续输入2个不同矩阵，验证两个转置结果都正确
        // ============================================================
        $display("\n=== Test 2: 连续tile验证 ===");
        begin
            logic [31:0] mat_b [0:DIM-1][0:DIM-1];
            logic [31:0] mat_c [0:DIM-1][0:DIM-1];
            logic [31:0] exp_bt [0:DIM-1][0:DIM-1];
            logic [31:0] exp_ct [0:DIM-1][0:DIM-1];
            logic [31:0] got_val;
            int t2_err_b, t2_err_c;
            int row_idx;

            // 构造两个矩阵（输入按列，输出按行）
            for (int r = 0; r < DIM; r++)
                for (int c = 0; c < DIM; c++) begin
                    mat_b[r][c] = 32'h100 + r*16 + c;
                    mat_c[r][c] = 32'h200 + r*16 + c;
                    exp_bt[r][c] = mat_b[r][c];  // 输出第j行 = B的第j行
                    exp_ct[r][c] = mat_c[r][c];  // 输出第j行 = C的第j行
                end

            // 送入mat_b（8拍），此时输出上一轮dummy的转置（忽略）
            for (int t = 0; t < DIM; t++) begin
                @(negedge clk);
                in_valid = 1'b1;
                for (int r = 0; r < DIM; r++)
                    in_row[r*DATA_WIDTH +: DATA_WIDTH] = mat_b[r][t];
                @(posedge clk); #1ps;
            end

            // 送入mat_c（8拍），同时输出mat_b的转置
            t2_err_b = 0;
            row_idx = 0;
            for (int t = 0; t < DIM; t++) begin
                @(negedge clk);
                in_valid = 1'b1;
                for (int r = 0; r < DIM; r++)
                    in_row[r*DATA_WIDTH +: DATA_WIDTH] = mat_c[r][t];
                @(posedge clk); #1ps;

                if (out_valid) begin
                    for (int c = 0; c < DIM; c++) begin
                        got_val = out_col[c*DATA_WIDTH +: DATA_WIDTH];
                        if (got_val !== exp_bt[row_idx][c])
                            t2_err_b++;
                    end
                    row_idx++;
                end
            end

            // 送入dummy（8拍），同时输出mat_c的转置
            t2_err_c = 0;
            row_idx = 0;
            for (int t = 0; t < DIM; t++) begin
                @(negedge clk);
                in_valid = 1'b1;
                in_row = '0;
                @(posedge clk); #1ps;

                if (out_valid) begin
                    for (int c = 0; c < DIM; c++) begin
                        got_val = out_col[c*DATA_WIDTH +: DATA_WIDTH];
                        if (got_val !== exp_ct[row_idx][c])
                            t2_err_c++;
                    end
                    row_idx++;
                end
            end

            if (t2_err_b == 0 && t2_err_c == 0) begin
                $display("  [PASS] 连续2个tile转置正确");
                pass_cnt++;
            end else begin
                $display("  [FAIL] tile B errors=%0d, tile C errors=%0d", t2_err_b, t2_err_c);
                err_cnt++;
            end
        end

        // ============================================================
        // Test 3: 随机数据验证
        // ============================================================
        $display("\n=== Test 3: 随机FP32数据转置 ===");
        begin
            logic [31:0] rand_mat [0:DIM-1][0:DIM-1];
            logic [31:0] got_val;
            int t3_err;

            for (int r = 0; r < DIM; r++)
                for (int c = 0; c < DIM; c++)
                    rand_mat[r][c] = $urandom;

            // 送入随机矩阵（按列）
            for (int t = 0; t < DIM; t++) begin
                @(negedge clk);
                in_valid = 1'b1;
                for (int r = 0; r < DIM; r++)
                    in_row[r*DATA_WIDTH +: DATA_WIDTH] = rand_mat[r][t];
                @(posedge clk); #1ps;
            end

            // 送入dummy读出转置结果
            t3_err = 0;
            begin
                int row_idx = 0;
                for (int t = 0; t < DIM; t++) begin
                    @(negedge clk);
                    in_valid = 1'b1;
                    in_row = '0;
                    @(posedge clk); #1ps;
                    if (out_valid) begin
                        for (int c = 0; c < DIM; c++) begin
                            got_val = out_col[c*DATA_WIDTH +: DATA_WIDTH];
                            if (got_val !== rand_mat[row_idx][c])
                                t3_err++;
                        end
                        row_idx++;
                    end
                end
            end

            if (t3_err == 0) begin
                $display("  [PASS] 随机FP32数据转置正确");
                pass_cnt++;
            end else begin
                $display("  [FAIL] 随机数据 %0d 个元素错误", t3_err);
                err_cnt++;
            end
        end

        // ============================================================
        // Test 4: valid间断验证
        // in_valid不连续（有gap），验证转置仍然正确
        // ============================================================
        $display("\n=== Test 4: valid间断验证 ===");
        begin
            logic [31:0] gap_mat [0:DIM-1][0:DIM-1];
            logic [31:0] got_val;
            int t4_err;
            int col_sent;

            for (int r = 0; r < DIM; r++)
                for (int c = 0; c < DIM; c++)
                    gap_mat[r][c] = (r+1)*100 + (c+1);

            // 送入矩阵，每列之间插入1-2拍gap
            col_sent = 0;
            while (col_sent < DIM) begin
                @(negedge clk);
                in_valid = 1'b1;
                for (int r = 0; r < DIM; r++)
                    in_row[r*DATA_WIDTH +: DATA_WIDTH] = gap_mat[r][col_sent];
                @(posedge clk); #1ps;
                col_sent++;
                // 插入1-2拍gap
                if (col_sent < DIM) begin
                    repeat(1 + (col_sent % 2)) begin
                        @(negedge clk);
                        in_valid = 1'b0;
                        @(posedge clk); #1ps;
                    end
                end
            end

            // 送入dummy读出（也带gap）
            t4_err = 0;
            begin
                int row_idx = 0;
                int dummy_sent = 0;
                while (dummy_sent < DIM) begin
                    @(negedge clk);
                    in_valid = 1'b1;
                    in_row = '0;
                    @(posedge clk); #1ps;
                    if (out_valid) begin
                        for (int c = 0; c < DIM; c++) begin
                            got_val = out_col[c*DATA_WIDTH +: DATA_WIDTH];
                            if (got_val !== gap_mat[row_idx][c])
                                t4_err++;
                        end
                        row_idx++;
                    end
                    dummy_sent++;
                    // 插入gap
                    if (dummy_sent < DIM) begin
                        @(negedge clk);
                        in_valid = 1'b0;
                        @(posedge clk); #1ps;
                    end
                end
            end

            if (t4_err == 0) begin
                $display("  [PASS] valid间断下转置正确");
                pass_cnt++;
            end else begin
                $display("  [FAIL] valid间断 %0d 个元素错误", t4_err);
                err_cnt++;
            end
        end

        // ============================================================
        // 最终报告
        // ============================================================
        @(negedge clk); in_valid = 1'b0;
        repeat(5) @(posedge clk);

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
        #100000;
        $display("[TIMEOUT] 仿真超时");
        $finish;
    end

endmodule

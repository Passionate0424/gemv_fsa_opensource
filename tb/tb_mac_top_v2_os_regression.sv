`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// [DEPRECATED] tb_mac_top_v2_os_regression
// 已被tb_CB_top_v2_gemv替代（走完整DMA路径，端到端验证）
// 因为sram.v之前错误使用全局复位建模，才能使本tb通过，现在已修正，本测试不通过不代表错误。
// 本TB直接写SRAM接口绕过DMA，不代表真实硬件行为
//
// DUT: mac_top_v2 (OS模式)
// 验证: 复用cb_baseline全量case的矩阵生成和golden比对逻辑
// 直接驱动mac_top_v2的SRAM接口，不经过AXI/DMA控制器
//
// 支持的case（通过+CASE=xxx选择）：
//   TC_Sanity_Check, TC_Identity_Matrix, TC_Zero_Matrix,
//   TC_Boundary_NoTiling, TC_OS_Row_Shift64, TC_OS_Drain_LastColumn,
//   TC_OS_TwoTile_128, TC_OS_SingleTile_64x64, TC_OS_RowTile_64x128,
//   TC_OS_RowTile_33x64, TC_OS_RowTile_33x128, TC_OS_RowCol_33x172,
//   TC_OS_RowCol_64x172, TC_OS_Random
////////////////////////////////////////////////////////////////
module tb_mac_top_v2_os_regression;

    import tb_cb_baseline_ref_pkg::*;

    localparam int ARRAY_SIZE = 32;
    localparam int DATA_WIDTH = 32;
    localparam int K_ACCUM_DEPTH = 64;
    localparam int MAC_LATENCY = 4;
    localparam int GROUP_SIZE = 8;
    localparam int NUM_GROUPS = 4;
    localparam int MAX_ROWS = REF_MAX_ROWS;
    localparam int MAX_COLS = REF_MAX_COLS;

    logic clk = 0;
    always #1 clk = ~clk;
    logic rstn = 0;

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
    logic [7:0] head_dim_cfg, seq_tile_len_cfg, num_kv_tiles_cfg;
    logic dma_done_sig;
    wire  fsa_dma_req_valid, fsa_dma_rw, fsa_done_sig;
    wire  [1:0] fsa_dma_target;

    mac_top_v2 #(
        .ARRAY_SIZE(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH),
        .K_ACCUM_DEPTH(K_ACCUM_DEPTH), .MAC_LATENCY(MAC_LATENCY),
        .GROUP_SIZE(GROUP_SIZE), .NUM_GROUPS(NUM_GROUPS)
    ) dut (
        .clock(clk), .rst_n(rstn), .fsa_mode(fsa_mode), .os_start(os_start),
        .dma_access_mode(dma_access_mode),
        .dma_w_sram_bank_we(dma_w_sram_bank_we),
        .dma_w_sram_waddr(dma_w_sram_waddr), .dma_w_sram_wdata(dma_w_sram_wdata),
        .dma_v_sram_we(dma_v_sram_we),
        .dma_v_sram_waddr(dma_v_sram_waddr), .dma_v_sram_wdata(dma_v_sram_wdata),
        .dma_v_sram_bank_sel(dma_v_sram_waddr[5:4]),
        .acc_en(acc_en), .w_mem_rst(w_mem_rst), .v_mem_rst(v_mem_rst),
        .os_processing_done(os_processing_done),
        .fsa_start(fsa_start), .head_dim(head_dim_cfg),
        .seq_tile_len(seq_tile_len_cfg), .num_kv_tiles(num_kv_tiles_cfg),
        .last_tile_valid(8'd0),.attn_scale(32'h3F0293EE),
        .dma_done(dma_done_sig),
        .fsa_dma_req_valid(fsa_dma_req_valid), .fsa_dma_target(fsa_dma_target),
        .fsa_dma_rw(fsa_dma_rw), .fsa_done(fsa_done_sig),
        .dma_o_sram_raddr(3'd0), .dma_o_sram_rdata()
    );

    // 读取OS模式结果（层次化访问内部wire）
    wire [ARRAY_SIZE*DATA_WIDTH-1:0] result_bus = dut.pe_mul_outcome;
    wire result_valid = dut.pe_result_valid;

    // 测试数据
    fp32_t matrix   [0:MAX_ROWS-1][0:MAX_COLS-1];
    fp32_t vector   [0:MAX_COLS-1];
    fp32_t expected [0:MAX_ROWS-1];
    fp32_t actual   [0:ARRAY_SIZE-1];

    string case_name;
    int case_rows, case_cols;
    int error_count, pass_count;
    int unsigned random_seed;

    // DMA写入任务
    task automatic load_vector(input int cols);
        @(negedge clk); dma_access_mode = 1;
        for (int i = 0; i < cols && i < K_ACCUM_DEPTH; i++) begin
            @(negedge clk);
            dma_v_sram_we = 1;
            dma_v_sram_waddr = i[$clog2(K_ACCUM_DEPTH)-1:0];
            dma_v_sram_wdata = vector[i];
            @(posedge clk); #1ps;
        end
        @(negedge clk); dma_v_sram_we = 0;
    endtask

    // 加载权重矩阵的一个列tile（最多K_ACCUM_DEPTH列）
    task automatic load_weight_tile(input int row_start, input int row_end, input int col_start, input int col_end);
        int num_cols = col_end - col_start;
        @(negedge clk); dma_access_mode = 1;
        for (int r = row_start; r < row_end && (r - row_start) < ARRAY_SIZE; r++) begin
            int bank = r - row_start;
            for (int c = col_start; c < col_end && (c - col_start) < K_ACCUM_DEPTH; c++) begin
                int addr = c - col_start;
                @(negedge clk);
                dma_w_sram_bank_we = (1 << bank);
                dma_w_sram_waddr = addr[$clog2(K_ACCUM_DEPTH)-1:0];
                dma_w_sram_wdata = matrix[r][c];
                @(posedge clk); #1ps;
            end
        end
        @(negedge clk); dma_w_sram_bank_we = 0; dma_access_mode = 0;
    endtask

    // 加载向量tile（列偏移）
    task automatic load_vector_tile(input int col_start, input int col_end);
        @(negedge clk); dma_access_mode = 1;
        for (int c = col_start; c < col_end && (c - col_start) < K_ACCUM_DEPTH; c++) begin
            @(negedge clk);
            dma_v_sram_we = 1;
            dma_v_sram_waddr = (c - col_start);
            dma_v_sram_wdata = vector[c];
            @(posedge clk); #1ps;
        end
        @(negedge clk); dma_v_sram_we = 0; dma_access_mode = 0;
    endtask

    // 执行一次OS计算并等待结果
    task automatic run_os_compute();
        @(negedge clk); dma_access_mode = 0;
        @(posedge clk); @(posedge clk);
        @(negedge clk); os_start = 1;
        // 等待processing_done
        begin
            int timeout = 0;
            while (!os_processing_done && timeout < 50000) begin
                @(posedge clk);
                timeout++;
            end
            if (timeout >= 50000)
                $display("[ERROR] OS compute timeout, alu_start=%b cycle_num=%0d",
                    dut.u_pe_core.alu_start, dut.u_pe_core.cycle_num);
        end
        // 立即拉低os_start防止alu_start重启
        @(negedge clk); os_start = 0;
        @(posedge clk);
        // 捕获结果
        capture_results();
    endtask

    // 捕获结果到actual数组（PE_core_v2中PE[i]存在MSB端）
    task automatic capture_results();
        for (int i = 0; i < ARRAY_SIZE; i++)
            actual[i] = result_bus[((ARRAY_SIZE-i)*DATA_WIDTH)-1 -: DATA_WIDTH];
    endtask

    // 比对结果
    function automatic int check_results(input int row_start, input int num_rows);
        int errs = 0;
        for (int i = 0; i < num_rows; i++) begin
            fp32_t got = actual[i];
            fp32_t exp_val = expected[row_start + i];
            if (!fp32_close(got, exp_val)) begin
                $display("[FAIL] row=%0d: got=%08h exp=%08h", row_start+i, got, exp_val);
                errs++;
            end
        end
        return errs;
    endfunction

    // ULP比较（容忍4 ULP）
    function automatic logic fp32_close(input fp32_t a, input fp32_t b);
        int diff;
        logic [31:0] abs_a, abs_b;
        if (a === b) return 1;
        abs_a = a & 32'h7FFFFFFF;
        abs_b = b & 32'h7FFFFFFF;
        if (a[31] != b[31]) return (abs_a == 0 && abs_b == 0);
        diff = (abs_a > abs_b) ? (abs_a - abs_b) : (abs_b - abs_a);
        return (diff <= 4);
    endfunction

    // 执行完整GEMV（支持行/列tiling）
    task automatic run_gemv(input int rows, input int cols);
        int col_tiles = (cols + K_ACCUM_DEPTH - 1) / K_ACCUM_DEPTH;
        int row_tiles = (rows + ARRAY_SIZE - 1) / ARRAY_SIZE;

        for (int rt = 0; rt < row_tiles; rt++) begin
            int r_start = rt * ARRAY_SIZE;
            int r_end = (r_start + ARRAY_SIZE > rows) ? rows : r_start + ARRAY_SIZE;
            int num_rows = r_end - r_start;

            for (int ct = 0; ct < col_tiles; ct++) begin
                int c_start = ct * K_ACCUM_DEPTH;
                int c_end = (c_start + K_ACCUM_DEPTH > cols) ? cols : c_start + K_ACCUM_DEPTH;

                // 清除SRAM
                @(negedge clk); w_mem_rst = 1; v_mem_rst = 1;
                @(posedge clk); #1ps;
                @(negedge clk); w_mem_rst = 0; v_mem_rst = 0;
                @(posedge clk);

                // 加载权重和向量tile
                load_weight_tile(r_start, r_end, c_start, c_end);
                load_vector_tile(c_start, c_end);

                // 设置acc_en（列tile>0时累加）
                acc_en = (ct > 0) ? 1'b1 : 1'b0;

                // 执行计算
                run_os_compute();
                capture_results();
            end

            // 最后一个列tile完成后比对该行tile的结果
            error_count += check_results(r_start, num_rows);
        end
    endtask

    // 生成golden
    task automatic compute_golden(input int rows, input int cols);
        matvec_golden_dense(rows, cols, matrix, vector, expected);
    endtask

    // 生成测试数据（与cb_baseline完全一致）
    task automatic setup_case();
        // 默认清零
        for (int r = 0; r < MAX_ROWS; r++)
            for (int c = 0; c < MAX_COLS; c++)
                matrix[r][c] = 32'h0;
        for (int c = 0; c < MAX_COLS; c++)
            vector[c] = 32'h0;

        case (case_name)
            "TC_Sanity_Check": begin
                case_rows = 4; case_cols = 4;
                vector[0] = fp32_from_real(1.0);
                vector[1] = fp32_from_real(2.0);
                vector[2] = fp32_from_real(4.0);
                vector[3] = fp32_from_real(8.0);
                matrix[0][0] = fp32_from_real(1.0);
                matrix[1][1] = fp32_from_real(1.0);
                matrix[1][2] = fp32_from_real(1.0);
                matrix[2][0] = fp32_from_real(2.0);
                matrix[2][3] = fp32_from_real(-1.0);
                matrix[3][3] = fp32_from_real(4.0);
            end
            "TC_Identity_Matrix": begin
                case_rows = 32; case_cols = 32;
                for (int i = 0; i < 32; i++) begin
                    vector[i] = fp32_from_real(real'(i + 1));
                    matrix[i][i] = fp32_from_real(1.0);
                end
            end
            "TC_Zero_Matrix": begin
                case_rows = 32; case_cols = 64;
                for (int i = 0; i < 64; i++)
                    vector[i] = fp32_from_real(real'(i + 1));
            end
            "TC_Boundary_NoTiling": begin
                case_rows = 32; case_cols = 64;
                for (int i = 0; i < 64; i++)
                    vector[i] = fp32_from_real(real'(i + 1));
                for (int i = 0; i < 32; i++) begin
                    matrix[i][i] = fp32_from_real(1.0);
                    matrix[i][i + 32] = fp32_from_real(1.0);
                end
            end
            "TC_OS_Row_Shift64": begin
                case_rows = 32; case_cols = 64;
                for (int i = 0; i < 64; i++)
                    vector[i] = fp32_from_real(real'(i + 1));
                for (int i = 0; i < 32; i++)
                    matrix[i][i] = fp32_from_real(1.0);
            end
            "TC_OS_Drain_LastColumn": begin
                case_rows = 32; case_cols = 64;
                for (int i = 0; i < 64; i++)
                    vector[i] = fp32_from_real(real'(i + 1));
                for (int i = 0; i < 32; i++)
                    matrix[i][63] = fp32_from_real(real'(i + 1));
            end
            "TC_OS_TwoTile_128": begin
                case_rows = 32; case_cols = 128;
                for (int i = 0; i < 128; i++)
                    vector[i] = fp32_from_real(real'(i + 1));
                for (int i = 0; i < 32; i++) begin
                    matrix[i][i] = fp32_from_real(1.0);
                    matrix[i][i + 32] = fp32_from_real(1.0);
                    matrix[i][i + 64] = fp32_from_real(1.0);
                    matrix[i][i + 96] = fp32_from_real(1.0);
                end
            end
            "TC_OS_SingleTile_64x64": begin
                case_rows = 64; case_cols = 64;
                for (int i = 0; i < 64; i++) begin
                    vector[i] = fp32_from_real(real'(i + 1));
                    matrix[i][i] = fp32_from_real(1.0);
                end
            end
            "TC_OS_RowTile_64x128": begin
                case_rows = 64; case_cols = 128;
                for (int i = 0; i < 128; i++)
                    vector[i] = fp32_from_real(real'(i + 1));
                for (int i = 0; i < 64; i++) begin
                    matrix[i][i] = fp32_from_real(1.0);
                    matrix[i][i + 64] = fp32_from_real(1.0);
                end
            end
            "TC_OS_RowTile_33x64": begin
                case_rows = 33; case_cols = 64;
                for (int i = 0; i < 64; i++)
                    vector[i] = fp32_from_real(real'(i + 1));
                for (int i = 0; i < 32; i++)
                    matrix[i][i] = fp32_from_real(1.0);
                matrix[32][0] = fp32_from_real(1.0);
            end
            "TC_OS_RowTile_33x128": begin
                case_rows = 33; case_cols = 128;
                for (int i = 0; i < 128; i++)
                    vector[i] = fp32_from_real(real'(i + 1));
                for (int i = 0; i < 32; i++) begin
                    matrix[i][i] = fp32_from_real(1.0);
                    matrix[i][i + 64] = fp32_from_real(1.0);
                end
                matrix[32][0] = fp32_from_real(1.0);
                matrix[32][64] = fp32_from_real(1.0);
            end
            "TC_OS_RowCol_33x172": begin
                case_rows = 33; case_cols = 172;
                for (int i = 0; i < 172; i++)
                    vector[i] = fp32_from_real(real'(i + 1));
                for (int i = 0; i < 32; i++) begin
                    matrix[i][i] = fp32_from_real(1.0);
                    matrix[i][i + 64] = fp32_from_real(1.0);
                    matrix[i][i + 128] = fp32_from_real(1.0);
                end
                matrix[32][0] = fp32_from_real(1.0);
                matrix[32][64] = fp32_from_real(1.0);
                matrix[32][128] = fp32_from_real(1.0);
            end
            "TC_OS_RowCol_64x172": begin
                case_rows = 64; case_cols = 172;
                for (int i = 0; i < 172; i++)
                    vector[i] = fp32_from_real(real'(i + 1));
                for (int i = 0; i < 64; i++) begin
                    matrix[i][i] = fp32_from_real(1.0);
                    matrix[i][i + 64] = fp32_from_real(1.0);
                    matrix[i][i + 128] = fp32_from_real(1.0);
                end
            end
            "TC_OS_Random": begin
                case_rows = 32; case_cols = 64;
                random_seed = 1;
                // 与cb_baseline一致的LCG伪随机（值域[-3,3]整数）
                begin
                    int unsigned prng_state = random_seed;
                    int signed sample_value;
                    for (int c = 0; c < case_cols; c++) begin
                        prng_state = (prng_state * 32'd1664525) + 32'd1013904223;
                        sample_value = int'(prng_state % 7) - 3;
                        vector[c] = fp32_from_real(real'(sample_value));
                    end
                    for (int r = 0; r < case_rows; r++)
                        for (int c = 0; c < case_cols; c++) begin
                            prng_state = (prng_state * 32'd1664525) + 32'd1013904223;
                            sample_value = int'(prng_state % 7) - 3;
                            matrix[r][c] = fp32_from_real(real'(sample_value));
                        end
                    vector[0] = fp32_from_real(real'((random_seed % 3) + 1));
                    matrix[0][0] = fp32_from_real(1.0);
                end
            end
            default: begin
                $display("[FAIL] Unknown case: %s", case_name);
                $finish;
            end
        endcase
    endtask

    initial begin
        // 初始化
        fsa_mode = 0;  // OS模式
        os_start = 0;
        dma_access_mode = 1;
        dma_w_sram_bank_we = 0;
        dma_w_sram_waddr = 0;
        dma_w_sram_wdata = 0;
        dma_v_sram_we = 0;
        dma_v_sram_waddr = 0;
        dma_v_sram_wdata = 0;
        acc_en = 0;
        w_mem_rst = 0;
        v_mem_rst = 0;
        fsa_start = 0;
        head_dim_cfg = 8;
        seq_tile_len_cfg = 8;
        num_kv_tiles_cfg = 1;
        dma_done_sig = 0;
        error_count = 0;
        pass_count = 0;

        case_name = "TC_Sanity_Check";
        if ($value$plusargs("CASE=%s", case_name))
            $display("[INFO] selected CASE=%s", case_name);

        rstn = 0; #20; rstn = 1;
        @(posedge clk); @(posedge clk);

        $display("\n========================================");
        $display(" tb_mac_top_v2_os_regression: %s", case_name);
        $display("========================================\n");

        // 生成测试数据
        setup_case();
        $display("[INFO] rows=%0d cols=%0d", case_rows, case_cols);

        // 计算golden
        compute_golden(case_rows, case_cols);

        // 执行GEMV
        run_gemv(case_rows, case_cols);

        // 报告
        $display("\n========================================");
        if (error_count == 0) begin
            $display(" [PASS] case=%s rows=%0d cols=%0d", case_name, case_rows, case_cols);
        end else begin
            $display(" [FAIL] case=%s errors=%0d", case_name, error_count);
        end
        $display("========================================\n");
        $finish;
    end

    // 超时保护
    initial begin
        #200000000;
        $display("[TIMEOUT] case=%s state=%0d", case_name, dut.fsm_state);
        $finish;
    end

endmodule

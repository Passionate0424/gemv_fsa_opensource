`timescale 1ns/1ps

////////////////////////////////////////////////////////////////
// tb_fsa_auto_compare
// Filelist: scripts/fsa_auto_compare_filelist.f
// 运行: run_vcs_remote.ps1 -Top tb_fsa_auto_compare -Filelist scripts/fsa_auto_compare_filelist.f
//
// mac_top_v2 的 FSA/OS 逐阶段自动比对TB
// 通过 DPI-C golden 对 PE 寄存器、rowsum、PV、norm 等阶段结果
// 做自动检查，定位 FSA 数据流和时序是否与参考实现一致。
//
// 覆盖单组与多组 FSA 参考路径。
////////////////////////////////////////////////////////////////

// DPI-C函数声明
import "DPI-C" function void dpi_golden_init(input int head_dim);
import "DPI-C" function void dpi_golden_set_q(input int idx, input int val);
import "DPI-C" function void dpi_golden_set_k(input int row, input int col, input int val);
import "DPI-C" function void dpi_golden_set_v(input int row, input int col, input int val);
import "DPI-C" function void dpi_golden_compute();
import "DPI-C" function void dpi_golden_set_actual_p(input int idx, input int val);
import "DPI-C" function void dpi_golden_compute_post_exp2();
import "DPI-C" function int  dpi_golden_compare(input int stage, input int pe_idx, input int dut_val, input int ulp_tol);
import "DPI-C" function int  dpi_golden_compare_rowsum(input int dut_val, input int ulp_tol);
import "DPI-C" function int  dpi_golden_compare_pv(input int idx, input int dut_val, input int ulp_tol);
import "DPI-C" function int  dpi_golden_compare_norm(input int idx, input int dut_val, input int ulp_tol);
import "DPI-C" function void dpi_golden_print_stage(input int stage, input int errors);
import "DPI-C" function void dpi_golden_dump();
// 多组golden API
import "DPI-C" function void dpi_mg_set_q(input int group, input int idx, input int val);
import "DPI-C" function void dpi_mg_set_actual_p(input int group, input int idx, input int val);
import "DPI-C" function void dpi_mg_compute_post_exp2(input int group);
import "DPI-C" function int  dpi_mg_compare_norm(input int group, input int idx, input int dut_val, input int ulp_tol);

module tb_fsa_auto_compare;
    localparam ARRAY_SIZE=32, DATA_WIDTH=32, K_ACCUM_DEPTH=64;
    localparam MAC_LATENCY=4, GROUP_SIZE=8, NUM_GROUPS=4;
    localparam ULP_TOL = 128;
    localparam ULP_TOL_MG = 300000; // 多组容差（PWL累积误差）

    logic clk=0; always #1 clk=~clk;
    logic rstn=0;
    logic fsa_mode,os_start,dma_access_mode,acc_en,w_mem_rst,v_mem_rst;
    logic [ARRAY_SIZE-1:0] dma_w_sram_bank_we;
    logic [$clog2(K_ACCUM_DEPTH)-1:0] dma_w_sram_waddr;
    logic [DATA_WIDTH-1:0] dma_w_sram_wdata;
    logic dma_v_sram_we;
    logic [$clog2(K_ACCUM_DEPTH)-1:0] dma_v_sram_waddr;
    logic [DATA_WIDTH-1:0] dma_v_sram_wdata;
    wire os_processing_done;
    logic fsa_start; logic [7:0] head_dim_cfg,seq_tile_len,num_kv_tiles;
    logic dma_done_sig;
    wire fsa_dma_req_valid; wire [1:0] fsa_dma_target; wire fsa_dma_rw,fsa_done_sig;

    mac_top_v2 #(.ARRAY_SIZE(ARRAY_SIZE),.DATA_WIDTH(DATA_WIDTH),
        .K_ACCUM_DEPTH(K_ACCUM_DEPTH),.MAC_LATENCY(MAC_LATENCY),
        .GROUP_SIZE(GROUP_SIZE),.NUM_GROUPS(NUM_GROUPS)
    ) dut (
        .clock(clk),.rst_n(rstn),.fsa_mode(fsa_mode),.os_start(os_start),
        .dma_access_mode(dma_access_mode),.dma_w_sram_bank_we(dma_w_sram_bank_we),
        .dma_w_sram_waddr(dma_w_sram_waddr),.dma_w_sram_wdata(dma_w_sram_wdata),
        .dma_v_sram_we(dma_v_sram_we),.dma_v_sram_waddr(dma_v_sram_waddr),
        .dma_v_sram_wdata(dma_v_sram_wdata),.dma_v_sram_bank_sel(2'b00),
        .acc_en(acc_en),.w_mem_rst(w_mem_rst),
        .v_mem_rst(v_mem_rst),.os_processing_done(os_processing_done),
        .fsa_start(fsa_start),.head_dim(head_dim_cfg),.seq_tile_len(seq_tile_len),
        .num_kv_tiles(num_kv_tiles),.last_tile_valid(8'd0),.attn_scale(32'h3F0293EE),.dma_done(dma_done_sig),
        .fsa_dma_req_valid(fsa_dma_req_valid),.fsa_dma_target(fsa_dma_target),
        .fsa_dma_rw(fsa_dma_rw),.fsa_done(fsa_done_sig),
        .dma_o_sram_raddr(3'd0),.dma_o_sram_rdata()
    );

    // 随机激励数据（声明在task之前）
    logic [31:0] Q_vals [0:7];
    logic [31:0] Q_vals_g1 [0:7];  // group 1的Q
    logic [31:0] Q_vals_g2 [0:7];  // group 2的Q
    logic [31:0] Q_vals_g3 [0:7];  // group 3的Q
    logic [31:0] K_vals [0:7][0:7];
    logic [31:0] V_vals [0:7][0:7];
    logic [31:0] K2_vals [0:7][0:7];  // 第2个tile的K
    logic [31:0] V2_vals [0:7][0:7];  // 第2个tile的V
    int seed;

    int dma_req_cnt;  // 跟踪DMA请求次数
    int dma_w_req_cnt; // 跟踪weight DMA请求次数（K1=1, V1=2, K2=3, V2=4）

    task automatic respond_dma();
        while(!fsa_dma_req_valid) @(posedge clk);
        dma_req_cnt++;
        if (fsa_dma_target == 2'b01) dma_w_req_cnt++;
        // DMA_V请求：写入V到Input SRAM（4组各自8个bank）
        if (fsa_dma_target == 2'b01 && (dma_w_req_cnt == 2 || dma_w_req_cnt == 4)) begin
            @(negedge clk); dma_access_mode = 1;
            for (int g = 0; g < 4; g++)
                for (int b = 0; b < 8; b++)
                    for (int a = 0; a < 8; a++) begin
                        if (dma_w_req_cnt == 2)
                            dma_write_w(g*8+b, a, V_vals[b][a]);
                        else
                            dma_write_w(g*8+b, a, V2_vals[b][a]);
                    end
            @(negedge clk); dma_access_mode = 0;
        end
        // DMA_K第2个tile：写入K2（4组各自8个bank）
        if (fsa_dma_target == 2'b01 && dma_w_req_cnt == 3) begin
            @(negedge clk); dma_access_mode = 1;
            for (int g = 0; g < 4; g++)
                for (int b = 0; b < 8; b++)
                    for (int a = 0; a < 8; a++)
                        dma_write_w(g*8+b, a, K2_vals[b][a]);
            @(negedge clk); dma_access_mode = 0;
        end
        repeat(2) @(posedge clk); @(negedge clk); dma_done_sig=1;
        @(posedge clk); #1ps; @(negedge clk); dma_done_sig=0;
    endtask
    task automatic dma_write_vec(input int addr, input logic [31:0] data);
        @(negedge clk); dma_v_sram_we=1; dma_v_sram_waddr=addr; dma_v_sram_wdata=data;
        @(posedge clk); #1ps; @(negedge clk); dma_v_sram_we=0;
    endtask
    task automatic dma_write_w(input int bank, input int addr, input logic [31:0] data);
        @(negedge clk); dma_w_sram_bank_we=(1<<bank); dma_w_sram_waddr=addr; dma_w_sram_wdata=data;
        @(posedge clk); #1ps; @(negedge clk); dma_w_sram_bank_we=0;
    endtask

    `define GET_PE_REG(idx) {dut.u_pe_core.PE_INST[idx].u_pe.reg_sign, \
        dut.u_pe_core.PE_INST[idx].u_pe.reg_exp, \
        dut.u_pe_core.PE_INST[idx].u_pe.reg_mantissa}

    // 读acc_sram第0组的指定地址、指定通道
    `define GET_ACC_SRAM(addr, ch) dut.ACC_INST[0].u_acc_sram.mem[addr][(ch)*32 +: 32]

    logic [4:0] state_d, state_d2;
    int total_errors;
    int cycle_cnt;
    always @(posedge clk) begin
        if (!rstn) begin state_d <= 0; state_d2 <= 0; end
        else begin state_d <= dut.fsm_state; state_d2 <= state_d; end
    end

    // 自动比对任务：等待目标状态，读PE.reg，调DPI比对
    task automatic compare_stage(input int stage_id, input int target_state);
        int errors;
        logic [31:0] pe_val;
        wait(state_d == target_state[4:0] && state_d != state_d2);
        @(posedge clk); @(posedge clk);

        errors = 0;
        pe_val = `GET_PE_REG(0); errors += dpi_golden_compare(stage_id, 0, pe_val, ULP_TOL);
        pe_val = `GET_PE_REG(1); errors += dpi_golden_compare(stage_id, 1, pe_val, ULP_TOL);
        pe_val = `GET_PE_REG(2); errors += dpi_golden_compare(stage_id, 2, pe_val, ULP_TOL);
        pe_val = `GET_PE_REG(3); errors += dpi_golden_compare(stage_id, 3, pe_val, ULP_TOL);
        pe_val = `GET_PE_REG(4); errors += dpi_golden_compare(stage_id, 4, pe_val, ULP_TOL);
        pe_val = `GET_PE_REG(5); errors += dpi_golden_compare(stage_id, 5, pe_val, ULP_TOL);
        pe_val = `GET_PE_REG(6); errors += dpi_golden_compare(stage_id, 6, pe_val, ULP_TOL);
        pe_val = `GET_PE_REG(7); errors += dpi_golden_compare(stage_id, 7, pe_val, ULP_TOL);
        dpi_golden_print_stage(stage_id, errors);
    endtask

    // EXP2后读取DUT实际P值，传给golden用于后续阶段计算
    // EXP2有延迟匹配（PE[0]延迟28拍），需要等PE寄存器全部稳定
    task automatic capture_actual_p();
        logic [31:0] pe_val;
        // 等待ROWSUM阶段的ctrl_valid（此时PE寄存器已被ROWSUM的load_reg覆盖前的最后稳定值）
        // 实际上需要在LOAD_REG_UI(state=10)之后、SUBTRACT(state=11)开始时捕获
        // 但当前流程是在进入ROWSUM(14)后捕获，此时EXP2结果已经通过flow_down到达所有PE
        // 多等几拍确保延迟匹配完成
        repeat(4) @(posedge clk);
        pe_val = `GET_PE_REG(0); dpi_golden_set_actual_p(0, pe_val); dpi_mg_set_actual_p(0, 0, pe_val);
        pe_val = `GET_PE_REG(1); dpi_golden_set_actual_p(1, pe_val); dpi_mg_set_actual_p(0, 1, pe_val);
        pe_val = `GET_PE_REG(2); dpi_golden_set_actual_p(2, pe_val); dpi_mg_set_actual_p(0, 2, pe_val);
        pe_val = `GET_PE_REG(3); dpi_golden_set_actual_p(3, pe_val); dpi_mg_set_actual_p(0, 3, pe_val);
        pe_val = `GET_PE_REG(4); dpi_golden_set_actual_p(4, pe_val); dpi_mg_set_actual_p(0, 4, pe_val);
        pe_val = `GET_PE_REG(5); dpi_golden_set_actual_p(5, pe_val); dpi_mg_set_actual_p(0, 5, pe_val);
        pe_val = `GET_PE_REG(6); dpi_golden_set_actual_p(6, pe_val); dpi_mg_set_actual_p(0, 6, pe_val);
        pe_val = `GET_PE_REG(7); dpi_golden_set_actual_p(7, pe_val); dpi_mg_set_actual_p(0, 7, pe_val);
        // group 1 (PE[8~15])
        dpi_mg_set_actual_p(1, 0, `GET_PE_REG(8));
        dpi_mg_set_actual_p(1, 1, `GET_PE_REG(9));
        dpi_mg_set_actual_p(1, 2, `GET_PE_REG(10));
        dpi_mg_set_actual_p(1, 3, `GET_PE_REG(11));
        dpi_mg_set_actual_p(1, 4, `GET_PE_REG(12));
        dpi_mg_set_actual_p(1, 5, `GET_PE_REG(13));
        dpi_mg_set_actual_p(1, 6, `GET_PE_REG(14));
        dpi_mg_set_actual_p(1, 7, `GET_PE_REG(15));
        // group 2 (PE[16~23])
        dpi_mg_set_actual_p(2, 0, `GET_PE_REG(16));
        dpi_mg_set_actual_p(2, 1, `GET_PE_REG(17));
        dpi_mg_set_actual_p(2, 2, `GET_PE_REG(18));
        dpi_mg_set_actual_p(2, 3, `GET_PE_REG(19));
        dpi_mg_set_actual_p(2, 4, `GET_PE_REG(20));
        dpi_mg_set_actual_p(2, 5, `GET_PE_REG(21));
        dpi_mg_set_actual_p(2, 6, `GET_PE_REG(22));
        dpi_mg_set_actual_p(2, 7, `GET_PE_REG(23));
        // group 3 (PE[24~31])
        dpi_mg_set_actual_p(3, 0, `GET_PE_REG(24));
        dpi_mg_set_actual_p(3, 1, `GET_PE_REG(25));
        dpi_mg_set_actual_p(3, 2, `GET_PE_REG(26));
        dpi_mg_set_actual_p(3, 3, `GET_PE_REG(27));
        dpi_mg_set_actual_p(3, 4, `GET_PE_REG(28));
        dpi_mg_set_actual_p(3, 5, `GET_PE_REG(29));
        dpi_mg_set_actual_p(3, 6, `GET_PE_REG(30));
        dpi_mg_set_actual_p(3, 7, `GET_PE_REG(31));
        dpi_golden_compute_post_exp2();
        dpi_mg_compute_post_exp2(0);
        dpi_mg_compute_post_exp2(1);
        dpi_mg_compute_post_exp2(2);
        dpi_mg_compute_post_exp2(3);
        $display("[DPI] Captured actual P from DUT for all 4 groups");
    endtask

    // ROWSUM + PV比对：等待TILE_CHECK状态（ACC_CORRECT已完成写入acc_sram）
    task automatic compare_rowsum_pv();
        int errors;
        logic [31:0] sram_val;
        // 等待进入TILE_CHECK状态（state=19，ACC_CORRECT已写回acc_sram）
        wait(state_d == 5'd19 && state_d != state_d2);
        @(posedge clk); @(posedge clk);
        $display("[DBG] compare_rowsum_pv at t=%0t: sram[8]=%08x tile_idx=%0d",
            $time, `GET_ACC_SRAM(8, 0), dut.u_fsm.tile_idx);

        // ROWSUM比对
        errors = 0;
        sram_val = `GET_ACC_SRAM(8, 0);
        errors += dpi_golden_compare_rowsum(sram_val, ULP_TOL);
        if (errors == 0)
            $display("[DPI] ROWSUM: PASS (val=%.6f)", $bitstoshortreal(sram_val));
        else
            $display("[DPI] ROWSUM: FAIL");

        // PV比对：acc_sram[0..7]
        errors = 0;
        sram_val = `GET_ACC_SRAM(0, 0); errors += dpi_golden_compare_pv(0, sram_val, ULP_TOL);
        sram_val = `GET_ACC_SRAM(1, 0); errors += dpi_golden_compare_pv(1, sram_val, ULP_TOL);
        sram_val = `GET_ACC_SRAM(2, 0); errors += dpi_golden_compare_pv(2, sram_val, ULP_TOL);
        sram_val = `GET_ACC_SRAM(3, 0); errors += dpi_golden_compare_pv(3, sram_val, ULP_TOL);
        sram_val = `GET_ACC_SRAM(4, 0); errors += dpi_golden_compare_pv(4, sram_val, ULP_TOL);
        sram_val = `GET_ACC_SRAM(5, 0); errors += dpi_golden_compare_pv(5, sram_val, ULP_TOL);
        sram_val = `GET_ACC_SRAM(6, 0); errors += dpi_golden_compare_pv(6, sram_val, ULP_TOL);
        sram_val = `GET_ACC_SRAM(7, 0); errors += dpi_golden_compare_pv(7, sram_val, ULP_TOL);
        dpi_golden_print_stage(5, errors);
    endtask

    // NORM比对：等待DMA_O状态（NORM已完成写回Output SRAM 4 bank）
    task automatic compare_norm();
        int errors;
        logic [31:0] sram_val;
        // 等待进入DMA_O状态（state=22）
        wait(state_d == 5'd22 && state_d != state_d2);
        @(posedge clk); @(posedge clk);

        // Group 0（bank0）— 使用原有golden
        errors = 0;
        sram_val = dut.OUT_SRAM[0].u_out_sram.mem[0]; errors += dpi_golden_compare_norm(0, sram_val, ULP_TOL);
        sram_val = dut.OUT_SRAM[0].u_out_sram.mem[1]; errors += dpi_golden_compare_norm(1, sram_val, ULP_TOL);
        sram_val = dut.OUT_SRAM[0].u_out_sram.mem[2]; errors += dpi_golden_compare_norm(2, sram_val, ULP_TOL);
        sram_val = dut.OUT_SRAM[0].u_out_sram.mem[3]; errors += dpi_golden_compare_norm(3, sram_val, ULP_TOL);
        sram_val = dut.OUT_SRAM[0].u_out_sram.mem[4]; errors += dpi_golden_compare_norm(4, sram_val, ULP_TOL);
        sram_val = dut.OUT_SRAM[0].u_out_sram.mem[5]; errors += dpi_golden_compare_norm(5, sram_val, ULP_TOL);
        sram_val = dut.OUT_SRAM[0].u_out_sram.mem[6]; errors += dpi_golden_compare_norm(6, sram_val, ULP_TOL);
        sram_val = dut.OUT_SRAM[0].u_out_sram.mem[7]; errors += dpi_golden_compare_norm(7, sram_val, ULP_TOL);
        if (errors == 0)
            $display("[DPI] NORM group0: 8/8 PASS");
        else
            $display("[DPI] NORM group0: %0d ERRORS out of 8", errors);
        total_errors += errors;

        // Group 1~3（bank1~3）— 使用多组golden（VCS不支持变量索引generate块）
        errors = 0;
        for (int i = 0; i < 8; i++) begin
            sram_val = dut.OUT_SRAM[1].u_out_sram.mem[i];
            errors += dpi_mg_compare_norm(1, i, sram_val, ULP_TOL_MG);
        end
        if (errors == 0) $display("[DPI] NORM group1: 8/8 PASS");
        else $display("[DPI] NORM group1: %0d ERRORS out of 8", errors);
        total_errors += errors;

        errors = 0;
        for (int i = 0; i < 8; i++) begin
            sram_val = dut.OUT_SRAM[2].u_out_sram.mem[i];
            errors += dpi_mg_compare_norm(2, i, sram_val, ULP_TOL_MG);
        end
        if (errors == 0) $display("[DPI] NORM group2: 8/8 PASS");
        else $display("[DPI] NORM group2: %0d ERRORS out of 8", errors);
        total_errors += errors;

        errors = 0;
        for (int i = 0; i < 8; i++) begin
            sram_val = dut.OUT_SRAM[3].u_out_sram.mem[i];
            errors += dpi_mg_compare_norm(3, i, sram_val, ULP_TOL_MG);
        end
        if (errors == 0) $display("[DPI] NORM group3: 8/8 PASS");
        else $display("[DPI] NORM group3: %0d ERRORS out of 8", errors);
        total_errors += errors;
    endtask

    // 随机激励生成
    function automatic logic [31:0] rand_fp32(input int s);
        int raw = $urandom(s) & 32'h3FFFFFFF;
        logic [7:0] exp_val = 8'd126 + (raw[7:0] % 3);
        logic sign = raw[31];
        return {sign, exp_val, raw[22:0]};
    endfunction

    initial begin
        fsa_mode=1;os_start=0;dma_access_mode=1;acc_en=0;w_mem_rst=0;v_mem_rst=0;fsa_start=0;
        dma_w_sram_bank_we=0;dma_w_sram_waddr=0;dma_w_sram_wdata=0;
        dma_v_sram_we=0;dma_v_sram_waddr=0;dma_v_sram_wdata=0;
        dma_done_sig=0;head_dim_cfg=8;seq_tile_len=8;num_kv_tiles=2;
        total_errors=0; seed=42; dma_req_cnt=0; dma_w_req_cnt=0;
        if ($value$plusargs("SEED=%d", seed))
            $display("[INFO] Using seed=%0d", seed);
        else
            $display("[INFO] Default seed=42");
        rstn=0; #20; rstn=1; @(posedge clk); @(posedge clk);

        // 初始化DPI golden
        dpi_golden_init(8);

        // 生成随机Q（4组各自不同）和K
        for (int i=0; i<8; i++) begin
            Q_vals[i] = rand_fp32(seed + i);
            dpi_golden_set_q(i, Q_vals[i]);
            dpi_mg_set_q(0, i, Q_vals[i]);
        end
        for (int i=0; i<8; i++) begin
            Q_vals_g1[i] = rand_fp32(seed + 500 + i);
            dpi_mg_set_q(1, i, Q_vals_g1[i]);
        end
        for (int i=0; i<8; i++) begin
            Q_vals_g2[i] = rand_fp32(seed + 600 + i);
            dpi_mg_set_q(2, i, Q_vals_g2[i]);
        end
        for (int i=0; i<8; i++) begin
            Q_vals_g3[i] = rand_fp32(seed + 700 + i);
            dpi_mg_set_q(3, i, Q_vals_g3[i]);
        end
        for (int r=0; r<8; r++)
            for (int c=0; c<8; c++) begin
                K_vals[r][c] = rand_fp32(seed + 100 + r*8 + c);
                dpi_golden_set_k(r, c, K_vals[r][c]);
            end

        // 生成随机V（后续DMA_V阶段写入）
        for (int r=0; r<8; r++)
            for (int c=0; c<8; c++) begin
                V_vals[r][c] = rand_fp32(seed + 200 + r*8 + c);
                dpi_golden_set_v(r, c, V_vals[r][c]);
            end

        // 生成第2个tile的随机K2和V2
        for (int r=0; r<8; r++)
            for (int c=0; c<8; c++)
                K2_vals[r][c] = rand_fp32(seed + 300 + r*8 + c);
        for (int r=0; r<8; r++)
            for (int c=0; c<8; c++)
                V2_vals[r][c] = rand_fp32(seed + 400 + r*8 + c);

        // 计算golden（QK→SUBTRACT→SCALE→EXP2）
        dpi_golden_compute();
        dpi_golden_dump();

        // DMA写入Q（4组各自不同，写入4个bank）
        // FSA模式bank选择: addr[4:3]=bank, addr[2:0]=bank内地址
        for (int i=0; i<8; i++)
            dma_write_vec(i, Q_vals[i]);         // bank0: addr 0~7
        for (int i=0; i<8; i++)
            dma_write_vec(8+i, Q_vals_g1[i]);    // bank1: addr 8~15
        for (int i=0; i<8; i++)
            dma_write_vec(16+i, Q_vals_g2[i]);   // bank2: addr 16~23
        for (int i=0; i<8; i++)
            dma_write_vec(24+i, Q_vals_g3[i]);   // bank3: addr 24~31

        // DMA写入K（4组各自8个bank，当前TB用同一份K）
        for (int g=0; g<4; g++)
            for (int b=0; b<8; b++)
                for (int a=0; a<8; a++)
                    dma_write_w(g*8+b, a, K_vals[b][a]);

        @(negedge clk); dma_access_mode=0; @(posedge clk); #1ps;
        repeat(3) @(posedge clk);
        @(negedge clk); fsa_start=1; @(posedge clk); #1ps;

        fork
            begin forever respond_dma(); end
            begin
                // === Tile 0 ===
                $display("[AUTO] === Tile 0 ===");
                compare_stage(0, 11);
                compare_stage(1, 12);
                compare_stage(2, 13);
                compare_stage(3, 14);
                capture_actual_p();
                compare_rowsum_pv();

                // === Tile 1: 更新golden的K/V ===
                $display("[AUTO] === Tile 1 ===");
                for (int r=0; r<8; r++)
                    for (int c=0; c<8; c++)
                        dpi_golden_set_k(r, c, K2_vals[r][c]);
                for (int r=0; r<8; r++)
                    for (int c=0; c<8; c++)
                        dpi_golden_set_v(r, c, V2_vals[r][c]);
                dpi_golden_compute();

                compare_stage(0, 11);
                compare_stage(1, 12);
                compare_stage(2, 13);
                compare_stage(3, 14);
                capture_actual_p();
                compare_rowsum_pv();

                // NORM比对（最终归一化）
                compare_norm();
                $display("[AUTO] All comparisons done");
            end
            begin
                for (cycle_cnt=0; cycle_cnt<16000; cycle_cnt++) begin
                    @(posedge clk);
                end
                $display("[AUTO] TIMEOUT at %0d cycles", cycle_cnt);
            end
        join_any
        disable fork;

        repeat(5) @(posedge clk);
        $display("\n========================================");
        $display(" AUTO COMPARE COMPLETE");
        $display("========================================\n");
        $finish;
    end

endmodule

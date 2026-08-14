`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// tb_silu_unit
//
// DUT: mac_top_v2 的 SiLU 融合通路（silu_ctrl_fsm + 4 个 fsa_accumulator 通道）
//
// 验证什么：GEMV 模式下拉 silu_start 后，Output SRAM 里的 32 个值是否被就地
// 换成了 silu(x)，且逐位等于 tb/dpi/fp_bitlevel.h 里 silu_bits() 的输出。
//
// 为什么用层次化赋值注入激励：SiLU 的输入来自 Output SRAM，而那块 SRAM 平时
// 只能由 write_out_v2(PE 结果) 或 FSA 的 NORM 阶段写入——要用正常激励喂进去
// 就得先跑一整趟 GEMV，那样出错时分不清是 GEMV 还是 SiLU 的问题。直接往
// mem 数组写测试向量，才能把 SiLU 通路单独隔离出来。
//
// 输出：silu_hw_results.txt，每行 "输入hex 输出hex"，离线与位级模型比对。
// 这与 tb_exp2_unit / tb_recip_unit 是同一套做法——模块级真实输入输出对是
// 位级建模唯一可靠的校准手段。
////////////////////////////////////////////////////////////////
module tb_silu_unit;

    localparam DATA_WIDTH = 32;
    localparam ACC_LATENCY = 6;

    reg clock = 0;
    reg rst_n = 0;
    always #5 clock = ~clock;

    // --- DUT 输入（GEMV 模式下与 SiLU 无关的端口全部置常量）---
    reg         silu_start = 0;
    reg  [5:0]  silu_num_elem = 6'd32;
    wire        silu_done;
    reg  [3:0]  dma_o_sram_raddr = 0;
    wire [4*DATA_WIDTH-1:0] dma_o_sram_rdata;

    mac_top_v2 #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_LATENCY(ACC_LATENCY)
    ) dut (
        .clock(clock),
        .rst_n(rst_n),
        .fsa_mode(1'b0),              // GEMV 模式，SiLU 才生效
        .os_start(1'b0),
        .dma_access_mode(1'b0),
        .dma_w_sram_bank_we(32'b0),
        .dma_w_sram_waddr(6'b0),
        .dma_w_sram_wdata(32'b0),
        .dma_v_sram_we(1'b0),
        .dma_v_sram_waddr(6'b0),
        .dma_v_sram_wdata(32'b0),
        .dma_v_sram_bank_sel(2'b0),
        .acc_en(1'b0),
        .w_mem_rst(1'b0),
        .v_mem_rst(1'b0),
        .os_processing_done(),
        .fsa_start(1'b0),
        .head_dim(8'd8),
        .seq_tile_len(8'd8),
        .num_kv_tiles(13'd1),
        .last_tile_valid(8'd0),
        .attn_scale(32'h3FB8AA3B),    // log2(e)——SiLU 借用这个端口做 EXP_S1 的乘数
        .group_mode(2'b00),
        .dma_done(1'b0),
        .fsa_done(),
        .fsa_k_read_done(),
        .fsa_v_read_done(),
        .dma_o_sram_raddr(dma_o_sram_raddr),
        .dma_o_sram_rdata(dma_o_sram_rdata),
        .silu_start(silu_start),
        .silu_num_elem(silu_num_elem),
        .silu_done(silu_done)
    );

    // ---- 调试打印：定位微程序哪一步没生效 ----
    // 只打印开头一段，避免 288 个 case 淹没日志
    // 只在最后一批（批次2：0/denormal/饱和/段边界等特殊值）打印，前面 8 批
    // 常规扫描已经验证过，不必刷屏
    reg dbg_on = 0;
    integer dbg_cnt = 0;
    always @(posedge clock) begin
        if (rst_n && dbg_on) begin
            if (dut.u_silu_fsm.acc_ctrl_valid) begin
                $display("[CMD ] t=%0t state=%0d cmd=%0d sa_negx=%b sa_one=%b src=%0d | sa_in=%08x sram_in=%08x",
                         $time, dut.u_silu_fsm.state, dut.u_silu_fsm.acc_ctrl_cmd,
                         dut.u_silu_fsm.sa_sel_negx, dut.u_silu_fsm.sa_sel_one, dut.u_silu_fsm.sram_src,
                         dut.ACC_INST[0].acc_sa_in_muxed, dut.ACC_INST[0].acc_sram_rd_data);
                dbg_cnt = dbg_cnt + 1;
            end
            if (dut.acc_sram_out_valid[0]) begin
                $display("[OUT ] t=%0t state=%0d out0=%08x  scale=%b_%02x_%06x",
                         $time, dut.u_silu_fsm.state, dut.acc_sram_out[31:0],
                         dut.ACC_INST[0].u_acc.ACC_CH[0].scale_sign,
                         dut.ACC_INST[0].u_acc.ACC_CH[0].scale_exp,
                         dut.ACC_INST[0].u_acc.ACC_CH[0].scale_mantissa);
                dbg_cnt = dbg_cnt + 1;
            end
            if (dut.u_silu_fsm.cap_x || dut.u_silu_fsm.cap_num_neg_only || dut.u_silu_fsm.cap_den ||
                dut.u_silu_fsm.osram_wr_en) begin
                $display("[CAP ] t=%0t capx=%b capnum=%b capden=%b wr=%b addr=%0d | x0=%08x num0=%08x den0=%08x",
                         $time, dut.u_silu_fsm.cap_x, dut.u_silu_fsm.cap_num_neg_only,
                         dut.u_silu_fsm.cap_den, dut.u_silu_fsm.osram_wr_en, dut.u_silu_fsm.osram_addr,
                         dut.silu_x_reg[0], dut.silu_num_reg[0], dut.silu_den_reg[0]);
                dbg_cnt = dbg_cnt + 1;
            end
        end
    end

    integer fh;
    integer i, b, a;
    integer n_case;
    real    xr;
    reg [31:0] xin  [0:3][0:7];   // [bank][addr]
    reg [31:0] xout [0:3][0:7];

    // 把一个 float 值写进 Output SRAM 的指定 bank/addr
    task automatic poke(input integer bank, input integer addr, input [31:0] val);
        begin
            case (bank)
                0: dut.OUT_SRAM[0].u_out_sram.mem[addr] = val;
                1: dut.OUT_SRAM[1].u_out_sram.mem[addr] = val;
                2: dut.OUT_SRAM[2].u_out_sram.mem[addr] = val;
                3: dut.OUT_SRAM[3].u_out_sram.mem[addr] = val;
            endcase
        end
    endtask

    task automatic peek(input integer bank, input integer addr, output [31:0] val);
        begin
            case (bank)
                0: val = dut.OUT_SRAM[0].u_out_sram.mem[addr];
                1: val = dut.OUT_SRAM[1].u_out_sram.mem[addr];
                2: val = dut.OUT_SRAM[2].u_out_sram.mem[addr];
                3: val = dut.OUT_SRAM[3].u_out_sram.mem[addr];
            endcase
        end
    endtask

    // 跑一批 32 个值（4 bank × 8 addr）
    task automatic run_batch;
        integer bb, aa;
        reg [31:0] v;
        begin
            for (bb = 0; bb < 4; bb = bb + 1)
                for (aa = 0; aa < 8; aa = aa + 1)
                    poke(bb, aa, xin[bb][aa]);

            @(posedge clock);
            silu_start <= 1'b1;
            @(posedge clock);
            silu_start <= 1'b0;

            // 等完成，加超时保护避免死等
            fork : wait_blk
                begin
                    wait (silu_done == 1'b1);
                    disable wait_blk;
                end
                begin
                    repeat (20000) @(posedge clock);
                    $display("[SILU] TIMEOUT waiting silu_done");
                    disable wait_blk;
                end
            join

            repeat (4) @(posedge clock);   // 让最后一次写回落盘

            for (bb = 0; bb < 4; bb = bb + 1)
                for (aa = 0; aa < 8; aa = aa + 1) begin
                    peek(bb, aa, v);
                    xout[bb][aa] = v;
                    $fwrite(fh, "%08x %08x\n", xin[bb][aa], v);
                    n_case = n_case + 1;
                end
        end
    endtask

    // float -> IEEE754 bits
    function [31:0] f2b(input real r);
        begin
            f2b = $shortrealtobits(r);
        end
    endfunction

    initial begin
        fh = $fopen("silu_hw_results.txt", "w");
        n_case = 0;

        repeat (5) @(posedge clock);
        rst_n = 1;
        repeat (5) @(posedge clock);

        // --- 批次1：正常区间 [-8, 8] 扫描 ---
        for (i = 0; i < 8; i = i + 1) begin
            for (b = 0; b < 4; b = b + 1)
                for (a = 0; a < 8; a = a + 1) begin
                    xr = -8.0 + 16.0 * ((i*32 + b*8 + a) / 255.0);
                    xin[b][a] = f2b(xr);
                end
            run_batch();
        end

        // --- 批次2：边界与特殊值 ---
        // 0、极小值、饱和区（|x|>=177 触发 exp2 溢出保护）、PWL 段边界附近
        dbg_on = 1;                // 从这批开始打印，用于定位零符号差异
        xin[0][0] = 32'h00000000;  // +0
        xin[0][1] = 32'h80000000;  // -0
        xin[0][2] = f2b(1.0e-30);
        xin[0][3] = f2b(-1.0e-30);
        xin[0][4] = f2b(177.0);
        xin[0][5] = f2b(-177.0);
        xin[0][6] = f2b(1000.0);
        xin[0][7] = f2b(-1000.0);
        for (a = 0; a < 8; a = a + 1) begin
            // x*log2e 的小数部分落在 8 段 PWL 的分界上，验选段无 off-by-one
            xin[1][a] = f2b(-(a + 1) / 1.4426950408889634 / 8.0);
            xin[2][a] = f2b(-(a + 1) * 1.0 / 1.4426950408889634);
            xin[3][a] = f2b((a + 1) * 0.5);
        end
        run_batch();

        // --- 批次3：num_elem=1（对应 GEMV 尾块只剩1行）---
        // UVM 上 rows=1 与 rows=33 的 row[32] 都表现为"SiLU 未生效"，
        // 两者共同点就是 current_rows=1，这里单独复现
        begin
            reg [31:0] v1;
            for (b = 0; b < 4; b = b + 1)
                for (a = 0; a < 8; a = a + 1)
                    poke(b, a, f2b(-3.0));       // 全填同一个值，便于看哪些被处理
            silu_num_elem = 6'd1;
            @(posedge clock);
            silu_start <= 1'b1; @(posedge clock); silu_start <= 1'b0;
            fork : w1
                begin wait (silu_done == 1'b1); disable w1; end
                begin repeat (20000) @(posedge clock); $display("[SILU1] TIMEOUT"); disable w1; end
            join
            repeat (4) @(posedge clock);
            peek(0, 0, v1);
            $display("[SILU1] num_elem=1: bank0addr0 in=%08x out=%08x (期望 silu(-3)=0xbdf0a2b0 附近)",
                     f2b(-3.0), v1);
            peek(1, 0, v1);
            $display("[SILU1] num_elem=1: bank1addr0 out=%08x", v1);
            peek(0, 1, v1);
            $display("[SILU1] num_elem=1: bank0addr1 out=%08x (应保持原值 %08x)", v1, f2b(-3.0));
            silu_num_elem = 6'd32;
        end

        $display("[SILU] dumped %0d cases -> silu_hw_results.txt", n_case);
        $fclose(fh);
        $finish;
    end

endmodule

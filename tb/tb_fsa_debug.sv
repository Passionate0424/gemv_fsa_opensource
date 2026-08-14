`timescale 1ns/1ps

////////////////////////////////////////////////////////////////
// tb_fsa_debug
//
// mac_top_v2 的 FSA 调试TB
// 用于观察关键状态机、DMA 握手和 PE 内部寄存器变化，
// 方便定位 FSA 流程中的时序和数据流问题。
//
// 主要用于手工调试和波形分析，不是回归型用例。
////////////////////////////////////////////////////////////////
module tb_fsa_debug;
    localparam ARRAY_SIZE=32, DATA_WIDTH=32, K_ACCUM_DEPTH=64, MAC_LATENCY=4, GROUP_SIZE=8, NUM_GROUPS=4;
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
    logic fsa_start; logic [7:0] head_dim,seq_tile_len,num_kv_tiles;
    logic dma_done_sig;
    wire fsa_dma_req_valid; wire [1:0] fsa_dma_target; wire fsa_dma_rw,fsa_done_sig;

    mac_top_v2 #(.ARRAY_SIZE(ARRAY_SIZE),.DATA_WIDTH(DATA_WIDTH),.K_ACCUM_DEPTH(K_ACCUM_DEPTH),
        .MAC_LATENCY(MAC_LATENCY),.GROUP_SIZE(GROUP_SIZE),.NUM_GROUPS(NUM_GROUPS)
    ) dut (.clock(clk),.rst_n(rstn),.fsa_mode(fsa_mode),.os_start(os_start),
        .dma_access_mode(dma_access_mode),.dma_w_sram_bank_we(dma_w_sram_bank_we),
        .dma_w_sram_waddr(dma_w_sram_waddr),.dma_w_sram_wdata(dma_w_sram_wdata),
        .dma_v_sram_we(dma_v_sram_we),.dma_v_sram_waddr(dma_v_sram_waddr),
        .dma_v_sram_wdata(dma_v_sram_wdata),.acc_en(acc_en),.w_mem_rst(w_mem_rst),
        .v_mem_rst(v_mem_rst),.os_processing_done(os_processing_done),
        .fsa_start(fsa_start),.head_dim(head_dim),.seq_tile_len(seq_tile_len),
        .num_kv_tiles(num_kv_tiles),.last_tile_valid(8'd0),.dma_done(dma_done_sig),
        .fsa_dma_req_valid(fsa_dma_req_valid),.fsa_dma_target(fsa_dma_target),
        .fsa_dma_rw(fsa_dma_rw),.fsa_done(fsa_done_sig));

    task automatic respond_dma();
        while(!fsa_dma_req_valid) @(posedge clk);
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

    int cyc;
    initial begin
        fsa_mode=1;os_start=0;dma_access_mode=1;acc_en=0;w_mem_rst=0;v_mem_rst=0;fsa_start=0;
        dma_w_sram_bank_we=0;dma_w_sram_waddr=0;dma_w_sram_wdata=0;
        dma_v_sram_we=0;dma_v_sram_waddr=0;dma_v_sram_wdata=0;
        dma_done_sig=0;head_dim=8;seq_tile_len=8;num_kv_tiles=1;
        rstn=0; #20; rstn=1; @(posedge clk); @(posedge clk);
        dma_write_vec(0,32'h3F800000); dma_write_vec(1,32'h40000000);
        dma_write_vec(2,32'h40400000); dma_write_vec(3,32'h40800000);
        dma_write_vec(4,32'h40A00000); dma_write_vec(5,32'h40C00000);
        dma_write_vec(6,32'h40E00000); dma_write_vec(7,32'h41000000);
        for(int b=0;b<8;b++) for(int a=0;a<8;a++) dma_write_w(b,a,32'h3F800000);
        @(negedge clk); dma_access_mode=0; @(posedge clk); #1ps;
        repeat(3) @(posedge clk); @(negedge clk); fsa_start=1; @(posedge clk); #1ps;
        fork
            begin forever respond_dma(); end
            begin
                for(cyc=0;cyc<400;cyc++) begin
                    @(posedge clk); #1ps;
                    if(dut.fsm_state==8 || dut.fsm_state==9 || dut.fsm_state==10) begin
                        $display("c%0d st=%0d fifo_rd=%b ptr=%0d bus0=%08h cmp_pipe=%08h pe0_ftd_q=%08h chain0=%b chain1=%b flow_ud=%b ctrl_valid=%b",
                            cyc, dut.fsm_state,
                            dut.score_fifo_rd_active, dut.score_fifo_rd_ptr,
                            dut.cmp_d_output_bus[31:0],
                            dut.u_pe_core.PE_INST[0].TOP_IN_GROUP.cmp_d_pipe,
                            {dut.u_pe_core.PE_INST[0].u_pe.flow_to_d_sign_q,dut.u_pe_core.PE_INST[0].u_pe.flow_to_d_exp_q,dut.u_pe_core.PE_INST[0].u_pe.flow_to_d_mantissa_q},
                            dut.u_pe_core.fsa_ctrl_valid_chain[0],
                            dut.u_pe_core.fsa_ctrl_valid_chain[1],
                            dut.u_pe_core.fsa_ctrl_flow_ud,
                            dut.u_pe_core.pe_ctrl_valid[0]);
                    end
                    if(fsa_done_sig) begin $display("DONE at c%0d",cyc); break; end
                end
            end
        join_any
        disable fork;
        $finish;
    end
endmodule

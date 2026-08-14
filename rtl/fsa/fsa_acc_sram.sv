`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// fsa_acc_sram
//
// ACC SRAM: 简单寄存器阵列实现
// 每组1个实例，8通道×9深度（8行O + 1行rowsum）
// 支持单端口读写（同一拍不能同时读写同一地址）
////////////////////////////////////////////////////////////////
module fsa_acc_sram #(
    parameter NUM_CH    = 8,
    parameter DEPTH     = 9,
    parameter DATA_WIDTH = 32
)(
    input  clock,
    input  rst_n,

    // 读端口
    input  rd_en,
    input  [$clog2(DEPTH)-1:0] rd_addr,
    output reg [NUM_CH*DATA_WIDTH-1:0] rd_data,

    // 写端口
    input  wr_en,
    input  [$clog2(DEPTH)-1:0] wr_addr,
    input  [NUM_CH*DATA_WIDTH-1:0] wr_data
);

    // BRAM推断：综合时去掉mem的reset（BRAM不支持整体清零）
    // 仿真时保留reset确保确定性（避免X传播）
    (* ram_style = "block" *) reg [NUM_CH*DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // 读（1拍延迟）
    always_ff @(posedge clock) begin
        if (!rst_n)
            rd_data <= '0;
        else if (rd_en)
            rd_data <= mem[rd_addr];
    end

    // 写
    integer i;
    always_ff @(posedge clock) begin
`ifdef SYNTHESIS
        if (wr_en)
            mem[wr_addr] <= wr_data;
`else
        if (!rst_n) begin
            for (i = 0; i < DEPTH; i = i + 1)
                mem[i] <= '0;
        end else if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
`endif
    end

endmodule

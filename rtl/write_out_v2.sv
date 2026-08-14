`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// write_out_v2
//
// OS模式结果序列化：将32个PE并行结果分配到4 bank Output SRAM
// bank0=PE[0~7], bank1=PE[8~15], bank2=PE[16~23], bank3=PE[24~31]
// 每bank逐拍写addr 0~7（8拍完成）
////////////////////////////////////////////////////////////////
module write_out_v2 #(
    parameter ARRAY_SIZE = 32,
    parameter DATA_WIDTH = 32
)(
    input  clock,
    input  rst_n,
    input  result_valid,
    input  [(ARRAY_SIZE*DATA_WIDTH)-1:0] parallel_data_in,

    output reg [3:0] bank_wr_en,
    output reg [2:0] wr_addr,
    output reg [DATA_WIDTH-1:0] wr_data_0,
    output reg [DATA_WIDTH-1:0] wr_data_1,
    output reg [DATA_WIDTH-1:0] wr_data_2,
    output reg [DATA_WIDTH-1:0] wr_data_3,
    output reg write_done
);

    reg [2:0] cnt;
    reg writing;
    // 锁存并行数据
    reg [(ARRAY_SIZE*DATA_WIDTH)-1:0] data_latch;

    always_ff @(posedge clock) begin
        if (!rst_n) begin
            bank_wr_en <= 4'b0;
            wr_addr    <= 3'd0;
            wr_data_0  <= '0;
            wr_data_1  <= '0;
            wr_data_2  <= '0;
            wr_data_3  <= '0;
            write_done <= 1'b0;
            cnt        <= 3'd0;
            writing    <= 1'b0;
            data_latch <= '0;
        end else begin
            write_done <= 1'b0;
            if (result_valid && !writing) begin
                // 锁存数据，开始写入
                data_latch <= parallel_data_in;
                writing    <= 1'b1;
                cnt        <= 3'd0;
                bank_wr_en <= 4'b1111;
            end else if (writing) begin
                bank_wr_en <= 4'b1111;
                wr_addr    <= cnt;
                // PE_core_v2中PE[i]存在MSB端: mul_outcome[((ARRAY_SIZE-i)*DW)-1 -: DW]
                // bank0=PE[0~7], bank1=PE[8~15], bank2=PE[16~23], bank3=PE[24~31]
                wr_data_0 <= data_latch[((ARRAY_SIZE - cnt)*DATA_WIDTH)-1 -: DATA_WIDTH];         // PE[cnt]
                wr_data_1 <= data_latch[((ARRAY_SIZE - 8 - cnt)*DATA_WIDTH)-1 -: DATA_WIDTH];     // PE[8+cnt]
                wr_data_2 <= data_latch[((ARRAY_SIZE - 16 - cnt)*DATA_WIDTH)-1 -: DATA_WIDTH];    // PE[16+cnt]
                wr_data_3 <= data_latch[((ARRAY_SIZE - 24 - cnt)*DATA_WIDTH)-1 -: DATA_WIDTH];    // PE[24+cnt]

                if (cnt == 3'd7) begin
                    writing    <= 1'b0;
                    write_done <= 1'b1;
                end
                cnt <= cnt + 3'd1;
            end else begin
                bank_wr_en <= 4'b0;
            end
        end
    end

endmodule

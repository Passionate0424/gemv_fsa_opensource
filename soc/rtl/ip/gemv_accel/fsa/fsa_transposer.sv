`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// fsa_transposer
//
// 8×MAX_COL转置引擎（单缓冲版本）：
//   - WRITE阶段(in_valid)：按列写入8×active_cols寄存器阵列
//   - READ阶段(rd_en)：按行读出（实现列→行转置）
//   - 读写完全解耦，不共享同一使能信号
//
// 相比双缓冲版本：
//   - 寄存器阵列减半（buf1去掉）
//   - `fire`不再同时驱动读写，避免不必要的写操作
//   - LUT≈-2K, FF≈-4K（参考trans_single_buf实验）
//
// 接口语义：
//   - 输入：每拍1个8元素向量（K的一列，从SRAM并行读出）
//   - 输出：每拍1个8元素向量（K的一行，送入PE阵列的l_input）
//   - active_cols控制实际使用列数（8/16/32）
////////////////////////////////////////////////////////////////
module fsa_transposer #(
    parameter DIM       = 8,
    parameter MAX_COL   = 32,
    parameter DATA_WIDTH = 32
)(
    input  clock,
    input  rst_n,

    // 配置
    input  [5:0] active_cols,  // 实际使用列数（8/16/32）

    // 写入接口（TRANSPOSE_K阶段使用）
    input  [DIM*DATA_WIDTH-1:0] in_row,
    input  in_valid,

    // 读出接口（QK_MAC阶段使用，独立控制）
    input  rd_en,
    output [MAX_COL*DATA_WIDTH-1:0] out_col,
    output out_valid
);

    // ============================================================
    // 单缓冲寄存器阵列：8行×MAX_COL列
    // ============================================================
    reg [DATA_WIDTH-1:0] mem [0:DIM-1][0:MAX_COL-1];

    reg [4:0] wr_col;          // 写入列指针 (0..MAX_COL-1)
    reg [4:0] rd_row;          // 读出行指针 (0..DIM-1)
    reg       initialized;     // 首轮写满后置位（允许读出）

    // ============================================================
    // 写入控制：按列写入
    // ============================================================
    integer r;

    always_ff @(posedge clock) begin
        if (!rst_n) begin
            wr_col <= 5'd0;
            initialized <= 1'b0;
        end else if (in_valid) begin
            for (r = 0; r < DIM; r = r + 1)
                mem[r][wr_col] <= in_row[r*DATA_WIDTH +: DATA_WIDTH];
            if (wr_col == active_cols - 1) begin
                wr_col <= 5'd0;
                initialized <= 1'b1;
            end else
                wr_col <= wr_col + 5'd1;
        end
    end

    // ============================================================
    // 读出控制：按行读出（rd_en独立）
    // ============================================================
    always_ff @(posedge clock) begin
        if (!rst_n)
            rd_row <= 5'd0;
        else if (rd_en) begin
            if (rd_row == DIM - 1)
                rd_row <= 5'd0;
            else
                rd_row <= rd_row + 5'd1;
        end
    end

    // ============================================================
    // 输出寄存器（在rd_en时锁存该行数据）
    // ============================================================
    reg [MAX_COL*DATA_WIDTH-1:0] out_reg;
    reg out_valid_reg;
    integer c;

    always_ff @(posedge clock) begin
        if (!rst_n) begin
            out_reg <= '0;
            out_valid_reg <= 1'b0;
        end else begin
            out_valid_reg <= initialized & rd_en;
            if (rd_en) begin
                for (c = 0; c < MAX_COL; c = c + 1)
                    out_reg[c*DATA_WIDTH +: DATA_WIDTH] <= mem[rd_row][c];
            end
        end
    end

    assign out_col = out_reg;
    assign out_valid = out_valid_reg;

endmodule

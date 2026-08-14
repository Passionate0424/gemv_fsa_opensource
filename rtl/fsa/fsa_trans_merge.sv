`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// fsa_trans_merge
//
// 4个fsa_transposer的输出合并wrapper
// 时间先后MUX：2×16模式前8拍选Trans[0]，后8拍选Trans[1]
//
// 4×8模式: 4组并行，各取out[0..7]
// 2×16模式: 时间MUX，每8拍切换Trans，取out[0..15]分给16个PE
// 1×32模式: 时间MUX，每8拍切换Trans，取out[0..31]分给32个PE
////////////////////////////////////////////////////////////////
module fsa_trans_merge #(
    parameter DIM        = 8,
    parameter MAX_COL    = 32,
    parameter DATA_WIDTH = 32,
    parameter NUM_GROUPS = 4,
    parameter ARRAY_SIZE = 32
)(
    input  clock,
    input  rst_n,

    input  [1:0]  group_mode,
    input  [5:0]  active_cols,

    // 写入接口（TRANSPOSE_K阶段）
    input  [NUM_GROUPS-1:0] wr_valid,
    input  [DIM*DATA_WIDTH-1:0] wr_data [0:NUM_GROUPS-1],

    // 读出接口（QK_MAC阶段，独立控制）
    input  rd_en,

    // 输出接口
    output [ARRAY_SIZE*DATA_WIDTH-1:0] col_out,
    output [NUM_GROUPS-1:0] col_valid
);

    // 4个Transposer实例（MAX_COL宽输出）
    wire [MAX_COL*DATA_WIDTH-1:0] trans_out [0:NUM_GROUPS-1];
    wire [NUM_GROUPS-1:0] trans_valid;

    genvar g;
    generate
        for (g = 0; g < NUM_GROUPS; g = g + 1) begin : TRANS_INST
            fsa_transposer #(
                .DIM(DIM),
                .MAX_COL(MAX_COL),
                .DATA_WIDTH(DATA_WIDTH)
            ) u_trans (
                .clock(clock),
                .rst_n(rst_n),
                .active_cols(active_cols),
                .in_row(wr_data[g]),
                .in_valid(wr_valid[g]),
                .rd_en(rd_en),
                .out_col(trans_out[g]),
                .out_valid(trans_valid[g])
            );
        end
    endgenerate

    // 时间MUX计数器：每DIM拍切换active_trans
    reg [2:0] rd_cycle_cnt;  // 0..DIM-1
    reg [1:0] active_trans;  // 当前选择的Trans编号

    always_ff @(posedge clock) begin
        if (!rst_n) begin
            rd_cycle_cnt <= 3'd0;
            active_trans <= 2'd0;
        end else if (trans_valid[0]) begin
            if (rd_cycle_cnt == DIM - 1) begin
                rd_cycle_cnt <= 3'd0;
                case (group_mode)
                    2'b01: active_trans <= active_trans ^ 2'd1; // 2×16: 0↔1
                    2'b10: active_trans <= (active_trans == 2'd3) ? 2'd0 : active_trans + 2'd1;
                    default: active_trans <= 2'd0;
                endcase
            end else
                rd_cycle_cnt <= rd_cycle_cnt + 3'd1;
        end else begin
            // 非输出期间复位
            rd_cycle_cnt <= 3'd0;
            active_trans <= 2'd0;
        end
    end

    // 输出MUX
    reg [ARRAY_SIZE*DATA_WIDTH-1:0] col_out_w;
    reg [NUM_GROUPS-1:0] col_valid_w;

    integer p;
    always_comb begin
        col_out_w = '0;
        col_valid_w = '0;
        case (group_mode)
            2'b00: begin
                // 4×8: 4组并行，各取out[0..DIM-1]
                for (p = 0; p < DIM; p = p + 1) begin
                    col_out_w[(0*DIM+p)*DATA_WIDTH +: DATA_WIDTH] = trans_out[0][p*DATA_WIDTH +: DATA_WIDTH];
                    col_out_w[(1*DIM+p)*DATA_WIDTH +: DATA_WIDTH] = trans_out[1][p*DATA_WIDTH +: DATA_WIDTH];
                    col_out_w[(2*DIM+p)*DATA_WIDTH +: DATA_WIDTH] = trans_out[2][p*DATA_WIDTH +: DATA_WIDTH];
                    col_out_w[(3*DIM+p)*DATA_WIDTH +: DATA_WIDTH] = trans_out[3][p*DATA_WIDTH +: DATA_WIDTH];
                end
                col_valid_w = trans_valid;
            end
            2'b01: begin
                // 2×16: 逻辑组A取Trans[active_trans]的out[0..15]分给PE[0..15]
                //        逻辑组B取Trans[2|active_trans[0]]的out[0..15]分给PE[16..31]
                for (p = 0; p < DIM; p = p + 1) begin
                    col_out_w[(0*DIM+p)*DATA_WIDTH +: DATA_WIDTH] = trans_out[active_trans][p*DATA_WIDTH +: DATA_WIDTH];
                    col_out_w[(1*DIM+p)*DATA_WIDTH +: DATA_WIDTH] = trans_out[active_trans][(DIM+p)*DATA_WIDTH +: DATA_WIDTH];
                    col_out_w[(2*DIM+p)*DATA_WIDTH +: DATA_WIDTH] = trans_out[2|active_trans[0]][p*DATA_WIDTH +: DATA_WIDTH];
                    col_out_w[(3*DIM+p)*DATA_WIDTH +: DATA_WIDTH] = trans_out[2|active_trans[0]][(DIM+p)*DATA_WIDTH +: DATA_WIDTH];
                end
                col_valid_w = {4{trans_valid[0]}};
            end
            2'b10: begin
                // 1×32: 取Trans[active_trans]的out[0..31]分给PE[0..31]
                for (p = 0; p < ARRAY_SIZE; p = p + 1)
                    col_out_w[p*DATA_WIDTH +: DATA_WIDTH] = trans_out[active_trans][p*DATA_WIDTH +: DATA_WIDTH];
                col_valid_w = {4{trans_valid[0]}};
            end
            default: col_valid_w = '0;
        endcase
    end

    assign col_out = col_out_w;
    assign col_valid = col_valid_w;

endmodule

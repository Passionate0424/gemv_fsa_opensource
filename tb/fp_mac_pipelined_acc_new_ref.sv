`timescale 1ns / 1ps

module fp_mac_pipelined_acc_new (
    input         clk,
    input         rstn,
    input         en,
    input         rst_acc,
    input  [31:0] weight_in,
    input  [31:0] vec_in,
    input  [31:0] partial_sum_in,
    output [31:0] vec_out,
    output [31:0] result
);
    wire [31:0] mul_out_wire;
    wire [31:0] add_out_wire;

    reg [31:0] weight_reg;
    reg [31:0] vec_reg;
    reg [31:0] acc_reg;

    fpmul_seq_pipeline u_multiplier (
        .clk  (clk),
        .rst_n(rstn),
        .A    (weight_reg),
        .B    (vec_reg),
        .O    (mul_out_wire)
    );

    fpadd_seq u_adder (
        .clk  (clk),
        .rst_n(rstn),
        .A    (mul_out_wire),
        .B    (acc_reg),
        .O    (add_out_wire)
    );

    always_ff @(posedge clk) begin
        if (!rstn) begin
            weight_reg <= 32'b0;
            vec_reg    <= 32'b0;
        end else if (en) begin
            weight_reg <= weight_in;
            vec_reg    <= vec_in;
        end else begin
            weight_reg <= 32'b0;
            vec_reg    <= 32'b0;
        end
    end

    always @(*) begin
        if (!rstn) begin
            acc_reg = 32'b0;
        end else if (rst_acc) begin
            acc_reg = partial_sum_in;
        end else begin
            acc_reg = add_out_wire;
        end
    end

    assign vec_out = vec_reg;
    assign result  = acc_reg;
endmodule

module fpu_regfile(
    input         clk,
    // READ PORT 1 (fj)
    input  [ 4:0] raddr1,
    output [31:0] rdata1,
    // READ PORT 2 (fk)
    input  [ 4:0] raddr2,
    output [31:0] rdata2,
    // READ PORT 3 (fa, 仅 fmadd/fmsub 4R 格式使用)
    input  [ 4:0] raddr3,
    output [31:0] rdata3,
    // WRITE PORT 1 (From Integer Pipeline: fld, movgr2fr)
    input         we1,
    input  [ 4:0] waddr1,
    input  [31:0] wdata1,
    // WRITE PORT 2 (From FPU Decoupled Writeback)
    input         we2,
    input  [ 4:0] waddr2,
    input  [31:0] wdata2
);

reg [31:0] rf[31:0];

// WRITE
always @(posedge clk) begin
    if (we1) rf[waddr1] <= wdata1;
    if (we2 && !(we1 && waddr1 == waddr2)) rf[waddr2] <= wdata2;
end

// READ OUT 1
assign rdata1 = ((raddr1==waddr1) && we1) ? wdata1 : 
                ((raddr1==waddr2) && we2) ? wdata2 : rf[raddr1];

// READ OUT 2
assign rdata2 = ((raddr2==waddr1) && we1) ? wdata1 :
                ((raddr2==waddr2) && we2) ? wdata2 : rf[raddr2];

// READ OUT 3 (与端口1/2 相同的写优先旁路)
assign rdata3 = ((raddr3==waddr1) && we1) ? wdata1 :
                ((raddr3==waddr2) && we2) ? wdata2 : rf[raddr3];

endmodule

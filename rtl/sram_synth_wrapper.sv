// 综合专用sram wrapper，接口与rtl/sram.sv一致
// 内部用fpga_sram_dp实现BRAM推断
module sram #(
    parameter DATA_WIDTH = 512,
    parameter ADDR_WIDTH = 6,
    parameter INIT_FILE = ""
)
(
    input clk,
    input csb,
    input wsb,
    input rst,
    input [DATA_WIDTH-1:0] wdata,
    input [ADDR_WIDTH-1:0] waddr,
    input [ADDR_WIDTH-1:0] raddr,
    output [DATA_WIDTH-1:0] rdata
);

    localparam NUM_BANKS = DATA_WIDTH / 32;

    wire wen_active = ~csb & ~wsb;
    wire ren_active = ~csb;

    genvar gi;
    generate
        for (gi = 0; gi < NUM_BANKS; gi = gi + 1) begin : BANK
            fpga_sram_dp #(
                .AW(ADDR_WIDTH)
            ) u_bram (
                .CLK      (clk),
                .ram_raddr(raddr),
                .ram_rdata(rdata[gi*32 +: 32]),
                .ram_ren  (ren_active),
                .ram_waddr(waddr),
                .ram_wdata(wdata[gi*32 +: 32]),
                .ram_wen  ({4{wen_active}})
            );
        end
    endgenerate

endmodule

// 综合专用sram_w2 wrapper，接口与rtl/sram.sv的sram_w2一致
// 内部用两块 fpga_sram_dp 拼出双字 entry：lo 存偶地址 word、hi 存奇地址 word，
// 深度各为 word 深度的一半，总位数与原 sram 相同。
// 与上面的 sram 用同一个存储原语，理由有三：
//   1. 与 ASIC 侧 sram_w2 的结构一致（那边同样是 u_ram_lo/u_ram_hi 两块 macro），
//      同一个 bug 在两条流程里表现相同，不会一边过一边挂；
//   2. fpga_sram_dp 带 syn_ramstyle 综合属性与 Init_File，raw 推断拿不到；
//   3. ram_wen[3:0] 的字节使能粒度得以保留。
// 读侧 raddr[0] 选高低半字，这级 mux 挂在 BRAM 输出之后，是本方案的时序风险点。
module sram_w2 #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 6
)
(
    input clk,
    input csb,
    input wsb,
    input rst,
    input [2*DATA_WIDTH-1:0] wdata,
    input                    wdual,
    input                    whalf,
    input [ADDR_WIDTH-1:0] waddr,
    input [ADDR_WIDTH-1:0] raddr,
    output [DATA_WIDTH-1:0] rdata
);

    localparam ENTRY_AW  = ADDR_WIDTH - 1;
    localparam NUM_BANKS = DATA_WIDTH / 32;

    // wen/ren 的取法与上面的 sram wrapper 保持一致（同样不看 rst）
    wire wen_active = ~csb & ~wsb;
    wire ren_active = ~csb;

    wire [ENTRY_AW-1:0] w_entry = waddr[ADDR_WIDTH-1:1];
    wire [ENTRY_AW-1:0] r_entry = raddr[ADDR_WIDTH-1:1];

    // wdual=1 时两块同时写；否则只写 waddr[0] 选中的那块，
    // 写进去的 word 由 whalf 从 beat 的两半里挑
    wire [DATA_WIDTH-1:0] w_half = whalf ? wdata[2*DATA_WIDTH-1:DATA_WIDTH]
                                         : wdata[DATA_WIDTH-1:0];
    wire en_lo = wen_active & (wdual | ~waddr[0]);
    wire en_hi = wen_active & (wdual |  waddr[0]);

    // 半字选择位与 macro 的 1 拍读延迟对齐
    reg r_half_q;
    always @(posedge clk) begin
        if (ren_active) r_half_q <= raddr[0];
    end

    genvar gi;
    generate
        for (gi = 0; gi < NUM_BANKS; gi = gi + 1) begin : BANK
            wire [31:0] rd_lo, rd_hi;

            fpga_sram_dp #(.AW(ENTRY_AW)) u_bram_lo (
                .CLK      (clk),
                .ram_raddr(r_entry),
                .ram_rdata(rd_lo),
                .ram_ren  (ren_active),
                .ram_waddr(w_entry),
                .ram_wdata(wdual ? wdata[gi*32 +: 32] : w_half[gi*32 +: 32]),
                .ram_wen  ({4{en_lo}})
            );

            fpga_sram_dp #(.AW(ENTRY_AW)) u_bram_hi (
                .CLK      (clk),
                .ram_raddr(r_entry),
                .ram_rdata(rd_hi),
                .ram_ren  (ren_active),
                .ram_waddr(w_entry),
                .ram_wdata(wdual ? wdata[DATA_WIDTH + gi*32 +: 32] : w_half[gi*32 +: 32]),
                .ram_wen  ({4{en_hi}})
            );

            assign rdata[gi*32 +: 32] = r_half_q ? rd_hi : rd_lo;
        end
    endgenerate

endmodule

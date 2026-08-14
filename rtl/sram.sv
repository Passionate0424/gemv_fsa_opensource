//****************************************************************************
// Description:
// A generic synchronous SRAM model matching real BRAM behavior.
// rst only resets output register, NOT memory contents (BRAM has no content reset).
//****************************************************************************
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
    output reg [DATA_WIDTH-1:0] rdata
);

    localparam DEPTH = 1 << ADDR_WIDTH;

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    // 写端口：rst期间不写入（与BRAM行为一致）
    always @(posedge clk) begin
        if (~csb && ~wsb && ~rst) begin
            mem[waddr] <= wdata;
        end
    end

    // 读端口：rst只清输出寄存器，不清mem内容
    always @(posedge clk) begin
        if (rst) begin
            rdata <= {DATA_WIDTH{1'b0}};
        end else if (~csb) begin
            rdata <= mem[raddr];
        end
    end

endmodule

//****************************************************************************
// sram_w2 —— 双字 entry 版 SRAM，端口与上面的 sram 完全一致，可直接替换。
//
// 差别只在内部组织：
//   sram   ：DEPTH   个 entry，每 entry 1 个 word
//   sram_w2：DEPTH/2 个 entry，每 entry 2 个 word（低半=偶地址，高半=奇地址）
// 总存储位数不变，word 地址到 (entry, 半字) 的映射是双射，行为逐位等价。
//
// 为什么要这个形状：DMA 通路要加宽到 64 位，一个 beat 带 2 个 word，而 32 个
// bank 共用一根 waddr / 一根 wdata（见 mac_top_v2.sv 的 Input SRAM 例化），
// 原形状下一拍只能进 1 个 word。GEMV 与 FSA-V 的连续两个 word 是同 bank 的
// addr / addr+1，做成双字 entry 后正好落进同一个 entry 的高低半，一拍写完。
//
// 写口两种粒度，由 wdual 选：
//   wdual=1：一拍写满一个 entry 的高低半，用于 GEMV/FSA-V 那种"连续两 word 同 bank
//            addr/addr+1"的几何，此时 waddr[0] 不参与（beat 天然双字对齐）。
//   wdual=0：只写半个 entry，与 sram 逐位等价。用于 FSA-K 那种"连续两 word 落相邻两
//            bank、同 addr"的几何——两个 bank 各取 beat 的一半，靠 whalf 区分谁拿哪半。
// 32 个 bank 共用一根 64 位 wdata，per-bank 只多一位 whalf；若改成 per-bank wdata
// 则要拉 32×64=2048 位数据总线，代价差一个数量级。
//
// 读侧 MAC 每拍只要 1 个 word，用 raddr[0] 选高低半，吞吐不变。
//****************************************************************************
module sram_w2 #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 6      // 仍是 word 粒度地址位宽，对外与 sram 一致
)
(
    input clk,
    input csb,
    input wsb,
    input rst,
    input [2*DATA_WIDTH-1:0] wdata,   // 一个 beat 的两个 word：低半=先来的
    input                    wdual,   // 1=整 entry 一拍写完；0=只写半个 entry
    input                    whalf,   // wdual=0 时本 bank 取 beat 的哪一半
    input [ADDR_WIDTH-1:0] waddr,
    input [ADDR_WIDTH-1:0] raddr,
    output reg [DATA_WIDTH-1:0] rdata
);

    localparam ENTRY_AW = ADDR_WIDTH - 1;      // entry 地址位宽（深度减半）
    localparam ENTRIES  = 1 << ENTRY_AW;

    reg [2*DATA_WIDTH-1:0] mem [0:ENTRIES-1];

    wire [ENTRY_AW-1:0] w_entry = waddr[ADDR_WIDTH-1:1];
    wire [ENTRY_AW-1:0] r_entry = raddr[ADDR_WIDTH-1:1];

    // 写端口：rst期间不写入（与BRAM行为一致）
    wire [DATA_WIDTH-1:0] w_half = whalf ? wdata[2*DATA_WIDTH-1:DATA_WIDTH]
                                         : wdata[DATA_WIDTH-1:0];
    always @(posedge clk) begin
        if (~csb && ~wsb && ~rst) begin
            if (wdual)         mem[w_entry]                            <= wdata;
            else if (waddr[0]) mem[w_entry][2*DATA_WIDTH-1:DATA_WIDTH] <= w_half;
            else               mem[w_entry][DATA_WIDTH-1:0]            <= w_half;
        end
    end

`ifndef SYNTHESIS
    // wdual 的契约：写地址必须偶数对齐。否则 mem[waddr>>1] 覆盖的是
    // word 地址 waddr-1 与 waddr，整块数据错位一个 word——这类错位不会挂死，
    // 只会算错，必须在写入的瞬间拦下而不是等结果对不上再倒查。
    //
    // rst_seen 门控：跑 `+vcs+initreg+random`（随机化未初始化寄存器，用来暴露
    // "设计依赖未复位状态"这类缺陷）时，复位树上的同步寄存器也会被随机成
    // "已退出复位"，于是 0 时刻就有随机的 csb/wsb/wdual/waddr 组合把这条断言打爆。
    // 那是随机化的产物不是设计违约——真实硬件上这些触发器上电取 INIT=0、复位
    // 能正常传播。只有确实见过一次复位之后，这条契约才谈得上成立。
    reg rst_seen;
    initial rst_seen = 1'b0;
    always @(posedge clk) if (rst) rst_seen <= 1'b1;

    always @(posedge clk) begin
        if (rst_seen && ~csb && ~wsb && ~rst && wdual && waddr[0])
            $fatal(1, "[sram_w2] wdual write at odd waddr=%0d: double-word writes must be even-aligned",
                   waddr);
    end
`endif

    // 读端口：rst只清输出寄存器，不清mem内容。raddr[0] 选 entry 的高/低半字
    always @(posedge clk) begin
        if (rst) begin
            rdata <= {DATA_WIDTH{1'b0}};
        end else if (~csb) begin
            rdata <= raddr[0] ? mem[r_entry][2*DATA_WIDTH-1:DATA_WIDTH]
                              : mem[r_entry][DATA_WIDTH-1:0];
        end
    end

endmodule

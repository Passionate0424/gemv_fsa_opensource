/*------------------------------------------------------------------------------
--------------------------------------------------------------------------------
Copyright (c) 2016, Loongson Technology Corporation Limited.

All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this 
list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, 
this list of conditions and the following disclaimer in the documentation and/or
other materials provided with the distribution.

3. Neither the name of Loongson Technology Corporation Limited nor the names of 
its contributors may be used to endorse or promote products derived from this 
software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND 
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED 
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE 
DISCLAIMED. IN NO EVENT SHALL LOONGSON TECHNOLOGY CORPORATION LIMITED BE LIABLE
TO ANY PARTY FOR DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE 
GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) 
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
--------------------------------------------------------------------------------
------------------------------------------------------------------------------*/
//1f00_0000 apb
//1f10_0000 dvi
//1f20_0000 confreg
//1f30_0000 dma

`include "config.h"

module soc_top #(parameter SIMULATION=1'b0)
(
    input           clk,
    input           reset,

    //图像输出信号
    output [2:0]    video_red,          //红色像素，3位
    output [2:0]    video_green,        //绿色像素，3位
    output [1:0]    video_blue,         //蓝色像素，2位
    output          video_hsync,        //行同步（水平同步）信号
    output          video_vsync,        //场同步（垂直同步）信号
    output          video_clk,          //像素时钟输出
    output          video_de,           //行数据有效信号，用于区分消隐区

    input  [3:0]    touch_btn,          //BTN1~BTN4，按钮开关，按下时为1
    input  [31:0]   dip_sw,             //32位拨码开关，拨到“ON”时为1
    output [15:0]   leds,               //16位LED，输出时1点亮
    output [7:0]    dpy0,               //数码管低位信号，包括小数点，输出1点亮
    output [7:0]    dpy1,               //数码管高位信号，包括小数点，输出1点亮

    //BaseRAM信号
    inout  [31:0]   base_ram_data,      //BaseRAM数据，低8位与CPLD串口控制器共享
    output [19:0]   base_ram_addr,      //BaseRAM地址
    output [ 3:0]   base_ram_be_n,      //BaseRAM字节使能，低有效。如果不使用字节使能，请保持为0
    output          base_ram_ce_n,      //BaseRAM片选，低有效
    output          base_ram_oe_n,      //BaseRAM读使能，低有效
    output          base_ram_we_n,      //BaseRAM写使能，低有效
    //ExtRAM信号
    inout  [31:0]   ext_ram_data,       //ExtRAM数据
    output [19:0]   ext_ram_addr,       //ExtRAM地址
    output [ 3:0]   ext_ram_be_n,       //ExtRAM字节使能，低有效。如果不使用字节使能，请保持为0
    output          ext_ram_ce_n,       //ExtRAM片选，低有效
    output          ext_ram_oe_n,       //ExtRAM读使能，低有效
    output          ext_ram_we_n,       //ExtRAM写使能，低有效

    //------uart-------
    inout           UART_RX,            //串口RX接收
    inout           UART_TX             //串口TX发送
);

wire cpu_clk;
wire cpu_resetn;
wire sys_clk;
wire sys_resetn;
wire pll_locked;

generate if(SIMULATION) begin: sim_clk
    //simulation clk.
    reg clk_sim;
    initial begin
        clk_sim = 1'b0;
    end
    always #15 clk_sim = ~clk_sim;

    assign cpu_clk = clk_sim;
    assign sys_clk = clk;
    rst_sync u_rst_sys(
        .clk(sys_clk),
        .rst_n_in(~reset),
        .rst_n_out(sys_resetn)
    );
    rst_sync u_rst_cpu(
        .clk(cpu_clk),
        .rst_n_in(sys_resetn),
        .rst_n_out(cpu_resetn)
    );
end
else begin: pll_clk
    clk_pll u_clk_pll(
        .cpu_clk    (cpu_clk),
        .sys_clk    (sys_clk),
        .resetn     (~reset),
        .locked     (pll_locked),
        .clk_in1    (clk)
    );
    rst_sync u_rst_sys(
        .clk(sys_clk),
        .rst_n_in(pll_locked),
        .rst_n_out(sys_resetn)
    );
    rst_sync u_rst_cpu(
        .clk(cpu_clk),
        .rst_n_in(sys_resetn),
        .rst_n_out(cpu_resetn)
    );
end
endgenerate

//debug signals
wire [31:0] debug_wb_pc;
wire [31:0] debug_wb_inst;
wire [3 :0] debug_wb_rf_wen;
wire [4 :0] debug_wb_rf_wnum;
wire [31:0] debug_wb_rf_wdata;

//cpu axi
wire [3 :0] cpu_arid   ;
wire [31:0] cpu_araddr ;
wire [7 :0] cpu_arlen  ;
wire [2 :0] cpu_arsize ;
wire [1 :0] cpu_arburst;
wire [1 :0] cpu_arlock ;
wire [3 :0] cpu_arcache;
wire [2 :0] cpu_arprot ;
wire        cpu_arvalid;
wire        cpu_arready;
wire [3 :0] cpu_rid    ;
wire [31:0] cpu_rdata  ;
wire [1 :0] cpu_rresp  ;
wire        cpu_rlast  ;
wire        cpu_rvalid ;
wire        cpu_rready ;
wire [3 :0] cpu_awid   ;
wire [31:0] cpu_awaddr ;
wire [7 :0] cpu_awlen  ;
wire [2 :0] cpu_awsize ;
wire [1 :0] cpu_awburst;
wire [1 :0] cpu_awlock ;
wire [3 :0] cpu_awcache;
wire [2 :0] cpu_awprot ;
wire        cpu_awvalid;
wire        cpu_awready;
wire [3 :0] cpu_wid    ;
wire [31:0] cpu_wdata  ;
wire [3 :0] cpu_wstrb  ;
wire        cpu_wlast  ;
wire        cpu_wvalid ;
wire        cpu_wready ;
wire [3 :0] cpu_bid    ;
wire [1 :0] cpu_bresp  ;
wire        cpu_bvalid ;
wire        cpu_bready ;
wire        cpu_sync_awid_4 ;
wire        cpu_bid_4  ;
wire        cpu_sync_arid_4 ;
wire        cpu_rid_4  ;

//cpu axi sync
wire [3 :0] cpu_sync_arid   ;
wire [31:0] cpu_sync_araddr ;
wire [7 :0] cpu_sync_arlen  ;
wire [2 :0] cpu_sync_arsize ;
wire [1 :0] cpu_sync_arburst;
wire        cpu_sync_arlock ;
wire [3 :0] cpu_sync_arcache;
wire [2 :0] cpu_sync_arprot ;
wire        cpu_sync_arvalid;
wire        cpu_sync_arready;
wire [3 :0] cpu_sync_rid    ;
wire [31:0] cpu_sync_rdata  ;
wire [1 :0] cpu_sync_rresp  ;
wire        cpu_sync_rlast  ;
wire        cpu_sync_rvalid ;
wire        cpu_sync_rready ;
wire [3 :0] cpu_sync_awid   ;
wire [31:0] cpu_sync_awaddr ;
wire [7 :0] cpu_sync_awlen  ;
wire [2 :0] cpu_sync_awsize ;
wire [1 :0] cpu_sync_awburst;
wire        cpu_sync_awlock ;
wire [3 :0] cpu_sync_awcache;
wire [2 :0] cpu_sync_awprot ;
wire        cpu_sync_awvalid;
wire        cpu_sync_awready;
wire [3 :0] cpu_sync_wid    ;
wire [31:0] cpu_sync_wdata  ;
wire [3 :0] cpu_sync_wstrb  ;
wire        cpu_sync_wlast  ;
wire        cpu_sync_wvalid ;
wire        cpu_sync_wready ;
wire [3 :0] cpu_sync_bid    ;
wire [1 :0] cpu_sync_bresp  ;
wire        cpu_sync_bvalid ;
wire        cpu_sync_bready ;

//axi ram
wire [4 :0] ram_arid   ;
wire [31:0] ram_araddr ;
wire [7 :0] ram_arlen  ;
wire [2 :0] ram_arsize ;
wire [1 :0] ram_arburst;
wire        ram_arlock ;
wire [3 :0] ram_arcache;
wire [2 :0] ram_arprot ;
wire        ram_arvalid;
wire        ram_arready;
wire [4 :0] ram_rid    ;
wire [63:0] ram_rdata  ;   // RAM 侧并宽：两片 SRAM 合成一条 64 位总线
wire [1 :0] ram_rresp  ;
wire        ram_rlast  ;
wire        ram_rvalid ;
wire        ram_rready ;
wire [4 :0] ram_awid   ;
wire [31:0] ram_awaddr ;
wire [7 :0] ram_awlen  ;
wire [2 :0] ram_awsize ;
wire [1 :0] ram_awburst;
wire        ram_awlock ;
wire [3 :0] ram_awcache;
wire [2 :0] ram_awprot ;
wire        ram_awvalid;
wire        ram_awready;
wire [4 :0] ram_wid    ;
wire [63:0] ram_wdata  ;
wire [7 :0] ram_wstrb  ;
wire        ram_wlast  ;
wire        ram_wvalid ;
wire        ram_wready ;
wire [4 :0] ram_bid    ;
wire [1 :0] ram_bresp  ;
wire        ram_bvalid ;
wire        ram_bready ;

//uart axi
wire  uart_arready;
wire  [ 4:0]  uart_rid;
wire  [63:0]  uart_rdata;
wire  [ 1:0]  uart_rresp;
wire  uart_rlast;
wire  uart_rvalid;
wire  uart_awready;
wire  uart_wready;
wire  [ 4:0]  uart_bid;
wire  [ 1:0]  uart_bresp;
wire  uart_bvalid;
wire  [ 4:0]  uart_arid;
wire  [31:0]  uart_araddr;
wire  [ 7:0]  uart_arlen;
wire  [ 2:0]  uart_arsize;
wire  [ 1:0]  uart_arburst;
wire          uart_arlock;
wire  [ 3:0]  uart_arcache;
wire  [ 2:0]  uart_arprot;
wire  uart_arvalid;
wire  uart_rready;
wire  [ 4:0]  uart_awid;
wire  [31:0]  uart_awaddr;
wire  [ 7:0]  uart_awlen;
wire  [ 2:0]  uart_awsize;
wire  [ 1:0]  uart_awburst;
wire          uart_awlock;
wire  [ 3:0]  uart_awcache;
wire  [ 2:0]  uart_awprot;
wire  uart_awvalid;
wire  [ 4:0]  uart_wid;
wire  [63:0]  uart_wdata;
wire  [ 7:0]  uart_wstrb;
wire  uart_wlast;
wire  uart_wvalid;
wire  uart_bready;
wire  irq_rx;

//uart
wire UART_CTS,   UART_RTS;
wire UART_DTR,   UART_DSR;
wire UART_RI,    UART_DCD;
assign UART_CTS = 1'b0;
assign UART_DSR = 1'b0;
assign UART_DCD = 1'b0;
assign UART_RI  = 1'b0;
wire uart0_int   ;
wire uart0_txd_o ;
wire uart0_txd_i ;
wire uart0_txd_oe;
wire uart0_rxd_o ;
wire uart0_rxd_i ;
wire uart0_rxd_oe;
wire uart0_rts_o ;
wire uart0_cts_i ;
wire uart0_dsr_i ;
wire uart0_dcd_i ;
wire uart0_dtr_o ;
wire uart0_ri_i  ;
assign     UART_RX     = uart0_rxd_oe ? 1'bz : uart0_rxd_o ;
assign     UART_TX     = uart0_txd_oe ? 1'bz : uart0_txd_o ;
assign     UART_RTS    = uart0_rts_o ;
assign     UART_DTR    = uart0_dtr_o ;
assign     uart0_txd_i = UART_TX;
assign     uart0_rxd_i = UART_RX;
assign     uart0_cts_i = UART_CTS;
assign     uart0_dcd_i = UART_DCD;
assign     uart0_dsr_i = UART_DSR;
assign     uart0_ri_i  = UART_RI ;

//dma master axi
wire [3 :0] dma_m_arid   ;
wire [31:0] dma_m_araddr ;
wire [7 :0] dma_m_arlen  ;
wire [2 :0] dma_m_arsize ;
wire [1 :0] dma_m_arburst;
wire        dma_m_arlock ;
wire [3 :0] dma_m_arcache;
wire [2 :0] dma_m_arprot ;
wire        dma_m_arvalid;
wire        dma_m_arready;
wire [3 :0] dma_m_rid    ;
wire [63:0] dma_m_rdata  ;
wire [1 :0] dma_m_rresp  ;
wire        dma_m_rlast  ;
wire        dma_m_rvalid ;
wire        dma_m_rready ;
wire [3 :0] dma_m_awid   ;
wire [31:0] dma_m_awaddr ;
wire [7 :0] dma_m_awlen  ;
wire [2 :0] dma_m_awsize ;
wire [1 :0] dma_m_awburst;
wire        dma_m_awlock ;
wire [3 :0] dma_m_awcache;
wire [2 :0] dma_m_awprot ;
wire        dma_m_awvalid;
wire        dma_m_awready;
wire [3 :0] dma_m_wid    ;
wire [63:0] dma_m_wdata  ;
wire [7 :0] dma_m_wstrb  ;
wire        dma_m_wlast  ;
wire        dma_m_wvalid ;
wire        dma_m_wready ;
wire [3 :0] dma_m_bid    ;
wire [1 :0] dma_m_bresp  ;
wire        dma_m_bvalid ;
wire        dma_m_bready ;

// DMA master信号由CB_top_v2驱动（AXI3 wid信号需单独tie-off）
assign dma_m_wid = 4'b0;  // AXI3 write channel ID, CB_top_v2是AXI4无此端口

wire [4 :0] dma_s_arid   ;
wire [31:0] dma_s_araddr ;
wire [7 :0] dma_s_arlen  ;
wire [2 :0] dma_s_arsize ;
wire [1 :0] dma_s_arburst;
wire        dma_s_arlock ;
wire [3 :0] dma_s_arcache;
wire [2 :0] dma_s_arprot ;
wire        dma_s_arvalid;
wire        dma_s_arready;
wire [4 :0] dma_s_rid    ;
wire [63:0] dma_s_rdata  ;
wire [1 :0] dma_s_rresp  ;
wire        dma_s_rlast  ;
wire        dma_s_rvalid ;
wire        dma_s_rready ;
wire [4 :0] dma_s_awid   ;
wire [31:0] dma_s_awaddr ;
wire [7 :0] dma_s_awlen  ;
wire [2 :0] dma_s_awsize ;
wire [1 :0] dma_s_awburst;
wire        dma_s_awlock ;
wire [3 :0] dma_s_awcache;
wire [2 :0] dma_s_awprot ;
wire        dma_s_awvalid;
wire        dma_s_awready;
wire [63:0] dma_s_wdata  ;
wire [7 :0] dma_s_wstrb  ;
wire        dma_s_wlast  ;
wire        dma_s_wvalid ;
wire        dma_s_wready ;
wire [4 :0] dma_s_bid    ;
wire [1 :0] dma_s_bresp  ;
wire        dma_s_bvalid ;
wire        dma_s_bready ;
wire        dma_finish   ;

// DMA slave信号由CB_top_v2驱动

// ============================================================================
// CB_top_v2 加速器（GEMV + FSA双模式）
// ============================================================================
wire CB_done;

CB_top_v2 u_cb_top_v2 (
    .clock      (sys_clk    ),
    .rst_n      (sys_resetn ),
    .CB_done    (CB_done    ),

    // AXI Slave (CSR访问, crossbar slave 4, 地址0x1F300000)
    .s_awid     (dma_s_awid   ),
    .s_awaddr   (dma_s_awaddr ),
    .s_awlen    (dma_s_awlen  ),
    .s_awsize   (dma_s_awsize ),
    .s_awburst  (dma_s_awburst),
    .s_awlock   (dma_s_awlock ),
    .s_awcache  (dma_s_awcache),
    .s_awprot   (dma_s_awprot ),
    .s_awvalid  (dma_s_awvalid),
    .s_awready  (dma_s_awready),
    .s_wdata    (dma_s_wdata  ),
    .s_wstrb    (dma_s_wstrb  ),
    .s_wlast    (dma_s_wlast  ),
    .s_wvalid   (dma_s_wvalid ),
    .s_wready   (dma_s_wready ),
    .s_bid      (dma_s_bid    ),
    .s_bresp    (dma_s_bresp  ),
    .s_bvalid   (dma_s_bvalid ),
    .s_bready   (dma_s_bready ),
    .s_arid     (dma_s_arid   ),
    .s_araddr   (dma_s_araddr ),
    .s_arlen    (dma_s_arlen  ),
    .s_arsize   (dma_s_arsize ),
    .s_arburst  (dma_s_arburst),
    .s_arlock   (dma_s_arlock ),
    .s_arcache  (dma_s_arcache),
    .s_arprot   (dma_s_arprot ),
    .s_arvalid  (dma_s_arvalid),
    .s_arready  (dma_s_arready),
    .s_rid      (dma_s_rid    ),
    .s_rdata    (dma_s_rdata  ),
    .s_rresp    (dma_s_rresp  ),
    .s_rlast    (dma_s_rlast  ),
    .s_rvalid   (dma_s_rvalid ),
    .s_rready   (dma_s_rready ),

    // AXI Master (DMA读写外部存储, crossbar master 1)
    .m_awid     (dma_m_awid   ),
    .m_awaddr   (dma_m_awaddr ),
    .m_awlen    (dma_m_awlen  ),
    .m_awsize   (dma_m_awsize ),
    .m_awburst  (dma_m_awburst),
    .m_awlock   (dma_m_awlock ),
    .m_awcache  (dma_m_awcache),
    .m_awprot   (dma_m_awprot ),
    .m_awvalid  (dma_m_awvalid),
    .m_awready  (dma_m_awready),
    .m_wdata    (dma_m_wdata  ),
    .m_wstrb    (dma_m_wstrb  ),
    .m_wlast    (dma_m_wlast  ),
    .m_wvalid   (dma_m_wvalid ),
    .m_wready   (dma_m_wready ),
    .m_bid      (dma_m_bid    ),
    .m_bresp    (dma_m_bresp  ),
    .m_bvalid   (dma_m_bvalid ),
    .m_bready   (dma_m_bready ),
    .m_arid     (dma_m_arid   ),
    .m_araddr   (dma_m_araddr ),
    .m_arlen    (dma_m_arlen  ),
    .m_arsize   (dma_m_arsize ),
    .m_arburst  (dma_m_arburst),
    .m_arlock   (dma_m_arlock ),
    .m_arcache  (dma_m_arcache),
    .m_arprot   (dma_m_arprot ),
    .m_arvalid  (dma_m_arvalid),
    .m_arready  (dma_m_arready),
    .m_rid      (dma_m_rid    ),
    .m_rdata    (dma_m_rdata  ),
    .m_rresp    (dma_m_rresp  ),
    .m_rlast    (dma_m_rlast  ),
    .m_rvalid   (dma_m_rvalid ),
    .m_rready   (dma_m_rready ),

    // Debug
    .debug_state(             ),
    .debug_data (             )
);

// CB_done(CB_top_v2输出，sys_clk域)跨到cpu_clk域喂给CPU中断，在集成层同步，
// 手法与下方confreg_int、Axi_CDC一致。CB_done是保持型电平(FSM在S_DONE停留到
// 软件清REG_CTRL_ADDR才撤销)，2级同步不会丢事件。
//
// 源侧**必须**先寄存一拍再跨域。这是板上"CPU 从 idle 假唤醒后读到加速器尚未
// 写完的输出"那个缺陷的硬件源头，链条如下（每环都有实证，详见 worklog）：
//   1. soc.xdc:233 用 set_clock_groups -asynchronous 把 cpu_clk/sys_clk 声明成异步，
//      这条跨域路径**STA 完全不分析**，没有任何 setup 保证；
//   2. CB_done 追到 cb_controll_v2:330 是 `assign ctrl_done = (state == 5'd12)`，
//      即 5 位状态寄存器的**组合译码**，状态位到达时刻不同就会瞬时译出 01100。
//      顺序编码下 S_DONE=12=01100，而 S_COMPUTE(00111)→S_WAIT_COMPUTE(01000)
//      与 S_ACCUMULATE(01110)→S_WAIT_COMPUTE(01000) 的中间态都能凑出 01100——
//      前者每个行块都要走一次，机会极多；
//   3. 同步器第一级采到毛刺，cpu_clk 域凭空得到一拍 CB_done_sync，
//      经 csr.v:404 的 `csr_estat[9:2] <= interrupt` 变成一拍 IS[3]，再变成一拍 has_int；
//   4. 这一拍足以清掉 CPU 的 idle_lock 让流水线重启(if_stage.v:180)，却在指令走到
//      异常点之前就撤销，**中断根本不会被取走**——软件侧表现为 idle 返回但 ISR 没跑。
//   5. 板上实测：假唤醒当场读 ESTAT 恒为 0（无任何中断挂起）而 CRMD.IE=1，6/6 一致；
//      触发率约 0.4%（736 次等待中 3~4 次）。
// 寄存之后跨域的是干净电平，毛刺不再有机会被采样。
reg CB_done_q;
always @(posedge sys_clk or negedge sys_resetn) begin
    if (!sys_resetn) CB_done_q <= 1'b0;
    else             CB_done_q <= CB_done;
end

// ASYNC_REG 让工具把这两级摆在同一 slice 里、布线最短，提高亚稳态收敛裕度。
// 它约束的是**寄存器摆放**，与上面那拍源侧寄存解决的"组合毛刺"是两回事，都要有。
// 本设计里它是这条跨域路径**唯一实际起作用**的约束手段——XDC 那条
// set_clock_groups -asynchronous 会盖掉任何 set_max_delay（详见 soc.xdc 的说明）。
// 布线后实测 Data Path Delay = 0.544ns、Logic Levels = 0，余量充足。
(* ASYNC_REG = "TRUE" *) reg CB_done_meta, CB_done_sync;
always @(posedge cpu_clk or negedge cpu_resetn) begin
    if (!cpu_resetn) begin
        CB_done_meta <= 1'b0;
        CB_done_sync <= 1'b0;
    end else begin
        CB_done_meta <= CB_done_q;
        CB_done_sync <= CB_done_meta;
    end
end

// reserved


//axi dvi
wire [4 :0] dvi_arid   ;
wire [31:0] dvi_araddr ;
wire [7 :0] dvi_arlen  ;
wire [2 :0] dvi_arsize ;
wire [1 :0] dvi_arburst;
wire [0 :0] dvi_arlock ;  // AXI4 AxLOCK为1位（AXI3才2位）；原误写[1:0]导致DC link位宽不匹配将AxiCrossbar_2x8黑盒化，bit[1]为死位，仅用[0]
wire [3 :0] dvi_arcache;
wire [2 :0] dvi_arprot ;
wire        dvi_arvalid;
wire        dvi_arready;
wire [4 :0] dvi_rid    ;
wire [63:0] dvi_rdata  ;
wire [1 :0] dvi_rresp  ;
wire        dvi_rlast  ;
wire        dvi_rvalid ;
wire        dvi_rready ;
wire [4 :0] dvi_awid   ;
wire [31:0] dvi_awaddr ;
wire [7 :0] dvi_awlen  ;
wire [2 :0] dvi_awsize ;
wire [1 :0] dvi_awburst;
wire [0 :0] dvi_awlock ;  // AXI4 AxLOCK为1位（AXI3才2位）；原误写[1:0]导致DC link位宽不匹配将AxiCrossbar_2x8黑盒化，bit[1]为死位，仅用[0]
wire [3 :0] dvi_awcache;
wire [2 :0] dvi_awprot ;
wire        dvi_awvalid;
wire        dvi_awready;
wire [4 :0] dvi_wid    ;
wire [63:0] dvi_wdata  ;
wire [7 :0] dvi_wstrb  ;
wire        dvi_wlast  ;
wire        dvi_wvalid ;
wire        dvi_wready ;
wire [4 :0] dvi_bid    ;
wire [1 :0] dvi_bresp  ;
wire        dvi_bvalid ;
wire        dvi_bready ;

// DVI slave signals driven by axi_dvi instance below

//axi confreg
wire [4 :0] confreg_arid   ;
wire [31:0] confreg_araddr ;
wire [7 :0] confreg_arlen  ;
wire [2 :0] confreg_arsize ;
wire [1 :0] confreg_arburst;
wire        confreg_arlock ;
wire [3 :0] confreg_arcache;
wire [2 :0] confreg_arprot ;
wire        confreg_arvalid;
wire        confreg_arready;
wire [4 :0] confreg_rid    ;
wire [63:0] confreg_rdata  ;
wire [1 :0] confreg_rresp  ;
wire        confreg_rlast  ;
wire        confreg_rvalid ;
wire        confreg_rready ;
wire [4 :0] confreg_awid   ;
wire [31:0] confreg_awaddr ;
wire [7 :0] confreg_awlen  ;
wire [2 :0] confreg_awsize ;
wire [1 :0] confreg_awburst;
wire        confreg_awlock ;
wire [3 :0] confreg_awcache;
wire [2 :0] confreg_awprot ;
wire        confreg_awvalid;
wire        confreg_awready;
wire [4 :0] confreg_wid    ;
wire [63:0] confreg_wdata  ;
wire [7 :0] confreg_wstrb  ;
wire        confreg_wlast  ;
wire        confreg_wvalid ;
wire        confreg_wready ;
wire [4 :0] confreg_bid    ;
wire [1 :0] confreg_bresp  ;
wire        confreg_bvalid ;
wire        confreg_bready ;

//slave 6 FFT/IFFT

//slave 7

wire confreg_int;

// 互连换成 pulp-platform/axi 的 axi_xbar（经 axi_xbar_2x8_wrap 拍平端口）。
// 端口表与原 AxiCrossbar_2x8 逐字对齐，故下方连线一行未改，实例名也保持不变，
// 便于用 git worktree 做"换件 vs 不换件"的单变量性能定标。
// DATA_W 现为 32（与原件逐位等价）；64 位加宽时只改这一个参数。
// OLD_XBAR：临时实验开关，切回旧 crossbar 但**保留新 filelist**（pulp 照编、
// common_cells 仍指 cvfpu、dedup 仍在）。用途：commit e4fa45b 同时改了 soc_top
// 和 soc_filelist 两件事，而先前的 A/B 把两个文件一起回退了，从未真正隔离过。
// 两者端口表逐字相同（已核对 352=352），所以只需切模块名。实验完删掉。
`ifdef OLD_XBAR
AxiCrossbar_2x8  u_AxiCrossbar_2x8 (
`else
// CPU / DMA / 外设都留在 32 位，只有 RAM 那一路是 64 位——DMA 的加宽要与加速器写口
// 开双字一起做（它的 DATA_WD 同时决定 AXI 侧与片上 SRAM 写口位宽），是下一步的事。
axi_xbar_2x8_wrap #(.DATA_W(32), .DATA_W_WIDE(64)) u_AxiCrossbar_2x8 (
`endif
    .clk                     ( sys_clk             ),
    .resetn                  ( sys_resetn          ),
    
    //master 0
    //aw
    .axiIn_0_awvalid         ( cpu_sync_awvalid    ),
    .axiIn_0_awready         ( cpu_sync_awready    ),
    .axiIn_0_awaddr          ( cpu_sync_awaddr     ),
    .axiIn_0_awid            ( cpu_sync_awid       ),
    .axiIn_0_awlen           ( cpu_sync_awlen      ),
    .axiIn_0_awsize          ( cpu_sync_awsize     ),
    .axiIn_0_awburst         ( cpu_sync_awburst    ),
    .axiIn_0_awlock          ( cpu_sync_awlock     ),
    .axiIn_0_awcache         ( cpu_sync_awcache    ),
    .axiIn_0_awprot          ( cpu_sync_awprot     ),
    //w
    .axiIn_0_wvalid          ( cpu_sync_wvalid     ),
    .axiIn_0_wready          ( cpu_sync_wready     ),
    .axiIn_0_wdata           ( cpu_sync_wdata      ),
    .axiIn_0_wstrb           ( cpu_sync_wstrb      ),
    .axiIn_0_wlast           ( cpu_sync_wlast      ),
    //b
    .axiIn_0_bready          ( cpu_sync_bready     ),
    .axiIn_0_bvalid          ( cpu_sync_bvalid     ),
    .axiIn_0_bid             ( cpu_sync_bid        ),
    .axiIn_0_bresp           ( cpu_sync_bresp      ),
    //ar
    .axiIn_0_arvalid         ( cpu_sync_arvalid    ),
    .axiIn_0_arready         ( cpu_sync_arready    ),
    .axiIn_0_araddr          ( cpu_sync_araddr     ),
    .axiIn_0_arid            ( cpu_sync_arid       ),
    .axiIn_0_arlen           ( cpu_sync_arlen      ),
    .axiIn_0_arsize          ( cpu_sync_arsize     ),
    .axiIn_0_arburst         ( cpu_sync_arburst    ),
    .axiIn_0_arlock          ( cpu_sync_arlock     ),
    .axiIn_0_arcache         ( cpu_sync_arcache    ),
    .axiIn_0_arprot          ( cpu_sync_arprot     ),
    //r
    .axiIn_0_rvalid          ( cpu_sync_rvalid     ),
    .axiIn_0_rready          ( cpu_sync_rready     ),
    .axiIn_0_rdata           ( cpu_sync_rdata      ),
    .axiIn_0_rid             ( cpu_sync_rid        ),
    .axiIn_0_rresp           ( cpu_sync_rresp      ),
    .axiIn_0_rlast           ( cpu_sync_rlast      ),

    //master 1
    //aw
    .axiIn_1_awvalid         ( dma_m_awvalid       ),
    .axiIn_1_awready         ( dma_m_awready       ),
    .axiIn_1_awaddr          ( dma_m_awaddr        ),
    .axiIn_1_awid            ( dma_m_awid          ),
    .axiIn_1_awlen           ( dma_m_awlen         ),
    .axiIn_1_awsize          ( dma_m_awsize        ),
    .axiIn_1_awburst         ( dma_m_awburst       ),
    .axiIn_1_awlock          ( dma_m_awlock        ),
    .axiIn_1_awcache         ( dma_m_awcache       ),
    .axiIn_1_awprot          ( dma_m_awprot        ),
    //w
    .axiIn_1_wvalid          ( dma_m_wvalid        ),
    .axiIn_1_wready          ( dma_m_wready        ),
    .axiIn_1_wdata           ( dma_m_wdata         ),
    .axiIn_1_wstrb           ( dma_m_wstrb         ),
    .axiIn_1_wlast           ( dma_m_wlast         ),
    //b
    .axiIn_1_bready          ( dma_m_bready        ),
    .axiIn_1_bvalid          ( dma_m_bvalid        ),
    .axiIn_1_bid             ( dma_m_bid           ),
    .axiIn_1_bresp           ( dma_m_bresp         ),
    //ar
    .axiIn_1_arvalid         ( dma_m_arvalid       ),
    .axiIn_1_arready         ( dma_m_arready       ),
    .axiIn_1_araddr          ( dma_m_araddr        ),
    .axiIn_1_arid            ( dma_m_arid          ),
    .axiIn_1_arlen           ( dma_m_arlen         ),
    .axiIn_1_arsize          ( dma_m_arsize        ),
    .axiIn_1_arburst         ( dma_m_arburst       ),
    .axiIn_1_arlock          ( dma_m_arlock        ),
    .axiIn_1_arcache         ( dma_m_arcache       ),
    .axiIn_1_arprot          ( dma_m_arprot        ),
    //r
    .axiIn_1_rvalid          ( dma_m_rvalid        ),
    .axiIn_1_rready          ( dma_m_rready        ),
    .axiIn_1_rdata           ( dma_m_rdata         ),
    .axiIn_1_rid             ( dma_m_rid           ),
    .axiIn_1_rresp           ( dma_m_rresp         ),
    .axiIn_1_rlast           ( dma_m_rlast         ),

    //slave 0
    //aw
    .axiOut_0_awvalid        ( ram_awvalid   ),
    .axiOut_0_awready        ( ram_awready   ),
    .axiOut_0_awaddr         ( ram_awaddr    ),
    .axiOut_0_awid           ( ram_awid      ),
    .axiOut_0_awlen          ( ram_awlen     ),
    .axiOut_0_awsize         ( ram_awsize    ),
    .axiOut_0_awburst        ( ram_awburst   ),
    .axiOut_0_awlock         ( ram_awlock    ),
    .axiOut_0_awcache        ( ram_awcache   ),
    .axiOut_0_awprot         ( ram_awprot    ),
    //w
    .axiOut_0_wvalid         ( ram_wvalid    ),
    .axiOut_0_wready         ( ram_wready    ),
    .axiOut_0_wdata          ( ram_wdata     ),
    .axiOut_0_wstrb          ( ram_wstrb     ),
    .axiOut_0_wlast          ( ram_wlast     ),
    //b
    .axiOut_0_bready         ( ram_bready    ),
    .axiOut_0_bvalid         ( ram_bvalid    ),
    .axiOut_0_bid            ( ram_bid       ),
    .axiOut_0_bresp          ( ram_bresp     ),
    //ar
    .axiOut_0_arvalid        ( ram_arvalid   ),
    .axiOut_0_arready        ( ram_arready   ),
    .axiOut_0_araddr         ( ram_araddr    ),
    .axiOut_0_arid           ( ram_arid      ),
    .axiOut_0_arlen          ( ram_arlen     ),
    .axiOut_0_arsize         ( ram_arsize    ),
    .axiOut_0_arburst        ( ram_arburst   ),
    .axiOut_0_arlock         ( ram_arlock    ),
    .axiOut_0_arcache        ( ram_arcache   ),
    .axiOut_0_arprot         ( ram_arprot    ),
    //r
    .axiOut_0_rvalid         ( ram_rvalid    ),
    .axiOut_0_rready         ( ram_rready    ),
    .axiOut_0_rdata          ( ram_rdata     ),
    .axiOut_0_rid            ( ram_rid       ),
    .axiOut_0_rresp          ( ram_rresp     ),
    .axiOut_0_rlast          ( ram_rlast     ),

    //slave 2
    //aw
    .axiOut_1_awvalid        ( uart_awvalid   ),
    .axiOut_1_awready        ( uart_awready   ),
    .axiOut_1_awaddr         ( uart_awaddr    ),
    .axiOut_1_awid           ( uart_awid      ),
    .axiOut_1_awlen          ( uart_awlen     ),
    .axiOut_1_awsize         ( uart_awsize    ),
    .axiOut_1_awburst        ( uart_awburst   ),
    .axiOut_1_awlock         ( uart_awlock    ),
    .axiOut_1_awcache        ( uart_awcache   ),
    .axiOut_1_awprot         ( uart_awprot    ),
    //w
    .axiOut_1_wvalid         ( uart_wvalid    ),
    .axiOut_1_wready         ( uart_wready    ),
    .axiOut_1_wdata          ( uart_wdata     ),
    .axiOut_1_wstrb          ( uart_wstrb     ),
    .axiOut_1_wlast          ( uart_wlast     ),
    //b
    .axiOut_1_bready         ( uart_bready    ),
    .axiOut_1_bvalid         ( uart_bvalid    ),
    .axiOut_1_bid            ( uart_bid       ),
    .axiOut_1_bresp          ( uart_bresp     ),
    //ar
    .axiOut_1_arvalid        ( uart_arvalid   ),
    .axiOut_1_arready        ( uart_arready   ),
    .axiOut_1_araddr         ( uart_araddr    ),
    .axiOut_1_arid           ( uart_arid      ),
    .axiOut_1_arlen          ( uart_arlen     ),
    .axiOut_1_arsize         ( uart_arsize    ),
    .axiOut_1_arburst        ( uart_arburst   ),
    .axiOut_1_arlock         ( uart_arlock    ),
    .axiOut_1_arcache        ( uart_arcache   ),
    .axiOut_1_arprot         ( uart_arprot    ),
    //r
    .axiOut_1_rvalid         ( uart_rvalid    ),
    .axiOut_1_rready         ( uart_rready    ),
    .axiOut_1_rdata          ( uart_rdata     ),
    .axiOut_1_rid            ( uart_rid       ),
    .axiOut_1_rresp          ( uart_rresp     ),
    .axiOut_1_rlast          ( uart_rlast     ),

    //slave 3
    //aw
    .axiOut_2_awvalid        ( dvi_awvalid   ),
    .axiOut_2_awready        ( dvi_awready   ),
    .axiOut_2_awaddr         ( dvi_awaddr    ),
    .axiOut_2_awid           ( dvi_awid      ),
    .axiOut_2_awlen          ( dvi_awlen     ),
    .axiOut_2_awsize         ( dvi_awsize    ),
    .axiOut_2_awburst        ( dvi_awburst   ),
    .axiOut_2_awlock         ( dvi_awlock    ),
    .axiOut_2_awcache        ( dvi_awcache   ),
    .axiOut_2_awprot         ( dvi_awprot    ),
    //w
    .axiOut_2_wvalid         ( dvi_wvalid    ),
    .axiOut_2_wready         ( dvi_wready    ),
    .axiOut_2_wdata          ( dvi_wdata     ),
    .axiOut_2_wstrb          ( dvi_wstrb     ),
    .axiOut_2_wlast          ( dvi_wlast     ),
    //b
    .axiOut_2_bready         ( dvi_bready    ),
    .axiOut_2_bvalid         ( dvi_bvalid    ),
    .axiOut_2_bid            ( dvi_bid       ),
    .axiOut_2_bresp          ( dvi_bresp     ),
    //ar
    .axiOut_2_arvalid        ( dvi_arvalid   ),
    .axiOut_2_arready        ( dvi_arready   ),
    .axiOut_2_araddr         ( dvi_araddr    ),
    .axiOut_2_arid           ( dvi_arid      ),
    .axiOut_2_arlen          ( dvi_arlen     ),
    .axiOut_2_arsize         ( dvi_arsize    ),
    .axiOut_2_arburst        ( dvi_arburst   ),
    .axiOut_2_arlock         ( dvi_arlock    ),
    .axiOut_2_arcache        ( dvi_arcache   ),
    .axiOut_2_arprot         ( dvi_arprot    ),
    //r
    .axiOut_2_rvalid         ( dvi_rvalid    ),
    .axiOut_2_rready         ( dvi_rready    ),
    .axiOut_2_rdata          ( dvi_rdata     ),
    .axiOut_2_rid            ( dvi_rid       ),
    .axiOut_2_rresp          ( dvi_rresp     ),
    .axiOut_2_rlast          ( dvi_rlast     ),


    //slave 4
    //aw
    .axiOut_3_awvalid        ( confreg_awvalid   ),
    .axiOut_3_awready        ( confreg_awready   ),
    .axiOut_3_awaddr         ( confreg_awaddr    ),
    .axiOut_3_awid           ( confreg_awid      ),
    .axiOut_3_awlen          ( confreg_awlen     ),
    .axiOut_3_awsize         ( confreg_awsize    ),
    .axiOut_3_awburst        ( confreg_awburst   ),
    .axiOut_3_awlock         ( confreg_awlock    ),
    .axiOut_3_awcache        ( confreg_awcache   ),
    .axiOut_3_awprot         ( confreg_awprot    ),
    //w
    .axiOut_3_wvalid         ( confreg_wvalid    ),
    .axiOut_3_wready         ( confreg_wready    ),
    .axiOut_3_wdata          ( confreg_wdata     ),
    .axiOut_3_wstrb          ( confreg_wstrb     ),
    .axiOut_3_wlast          ( confreg_wlast     ),
    //b
    .axiOut_3_bready         ( confreg_bready    ),
    .axiOut_3_bvalid         ( confreg_bvalid    ),
    .axiOut_3_bid            ( confreg_bid       ),
    .axiOut_3_bresp          ( confreg_bresp     ),
    //ar
    .axiOut_3_arvalid        ( confreg_arvalid   ),
    .axiOut_3_arready        ( confreg_arready   ),
    .axiOut_3_araddr         ( confreg_araddr    ),
    .axiOut_3_arid           ( confreg_arid      ),
    .axiOut_3_arlen          ( confreg_arlen     ),
    .axiOut_3_arsize         ( confreg_arsize    ),
    .axiOut_3_arburst        ( confreg_arburst   ),
    .axiOut_3_arlock         ( confreg_arlock    ),
    .axiOut_3_arcache        ( confreg_arcache   ),
    .axiOut_3_arprot         ( confreg_arprot    ),
    //r
    .axiOut_3_rvalid         ( confreg_rvalid    ),
    .axiOut_3_rready         ( confreg_rready    ),
    .axiOut_3_rdata          ( confreg_rdata     ),
    .axiOut_3_rid            ( confreg_rid       ),
    .axiOut_3_rresp          ( confreg_rresp     ),
    .axiOut_3_rlast          ( confreg_rlast     ),

    //slave 5
    //aw
    .axiOut_4_awvalid        ( dma_s_awvalid   ),
    .axiOut_4_awready        ( dma_s_awready   ),
    .axiOut_4_awaddr         ( dma_s_awaddr    ),
    .axiOut_4_awid           ( dma_s_awid      ),
    .axiOut_4_awlen          ( dma_s_awlen     ),
    .axiOut_4_awsize         ( dma_s_awsize    ),
    .axiOut_4_awburst        ( dma_s_awburst   ),
    .axiOut_4_awlock         ( dma_s_awlock    ),
    .axiOut_4_awcache        ( dma_s_awcache   ),
    .axiOut_4_awprot         ( dma_s_awprot    ),
    //w
    .axiOut_4_wvalid         ( dma_s_wvalid    ),
    .axiOut_4_wready         ( dma_s_wready    ),
    .axiOut_4_wdata          ( dma_s_wdata     ),
    .axiOut_4_wstrb          ( dma_s_wstrb     ),
    .axiOut_4_wlast          ( dma_s_wlast     ),
    //b
    .axiOut_4_bready         ( dma_s_bready    ),
    .axiOut_4_bvalid         ( dma_s_bvalid    ),
    .axiOut_4_bid            ( dma_s_bid       ),
    .axiOut_4_bresp          ( dma_s_bresp     ),
    //ar
    .axiOut_4_arvalid        ( dma_s_arvalid   ),
    .axiOut_4_arready        ( dma_s_arready   ),
    .axiOut_4_araddr         ( dma_s_araddr    ),
    .axiOut_4_arid           ( dma_s_arid      ),
    .axiOut_4_arlen          ( dma_s_arlen     ),
    .axiOut_4_arsize         ( dma_s_arsize    ),
    .axiOut_4_arburst        ( dma_s_arburst   ),
    .axiOut_4_arlock         ( dma_s_arlock    ),
    .axiOut_4_arcache        ( dma_s_arcache   ),
    .axiOut_4_arprot         ( dma_s_arprot    ),
    //r
    .axiOut_4_rvalid         ( dma_s_rvalid    ),
    .axiOut_4_rready         ( dma_s_rready    ),
    .axiOut_4_rdata          ( dma_s_rdata     ),
    .axiOut_4_rid            ( dma_s_rid       ),
    .axiOut_4_rresp          ( dma_s_rresp     ),
    .axiOut_4_rlast          ( dma_s_rlast     )

);

// add your code
// ============================================================================
// 1. OpenLA500 CPU Core
// ============================================================================
core_top u_cpu(
    .intrpt             ({6'b0, CB_done_sync, confreg_int}), // HWI1=CB_done(已同步cpu_clk), HWI0=confreg
    .aclk               (cpu_clk            ),
    .aresetn            (cpu_resetn         ),
    .arid               (cpu_arid           ),
    .araddr             (cpu_araddr         ),
    .arlen              (cpu_arlen          ),
    .arsize             (cpu_arsize         ),
    .arburst            (cpu_arburst        ),
    .arlock             (cpu_arlock         ),
    .arcache            (cpu_arcache        ),
    .arprot             (cpu_arprot         ),
    .arvalid            (cpu_arvalid        ),
    .arready            (cpu_arready        ),
    .rid                (cpu_rid            ),
    .rdata              (cpu_rdata          ),
    .rresp              (cpu_rresp          ),
    .rlast              (cpu_rlast          ),
    .rvalid             (cpu_rvalid         ),
    .rready             (cpu_rready         ),
    .awid               (cpu_awid           ),
    .awaddr             (cpu_awaddr         ),
    .awlen              (cpu_awlen          ),
    .awsize             (cpu_awsize         ),
    .awburst            (cpu_awburst        ),
    .awlock             (cpu_awlock         ),
    .awcache            (cpu_awcache        ),
    .awprot             (cpu_awprot         ),
    .awvalid            (cpu_awvalid        ),
    .awready            (cpu_awready        ),
    .wid                (cpu_wid            ),
    .wdata              (cpu_wdata          ),
    .wstrb              (cpu_wstrb          ),
    .wlast              (cpu_wlast          ),
    .wvalid             (cpu_wvalid         ),
    .wready             (cpu_wready         ),
    .bid                (cpu_bid            ),
    .bresp              (cpu_bresp          ),
    .bvalid             (cpu_bvalid         ),
    .bready             (cpu_bready         ),
    .break_point        (1'b0               ),
    .infor_flag         (1'b0               ),
    .reg_num            (5'b0               ),
    .ws_valid           (                   ),
    .rf_rdata           (                   ),
    .debug0_wb_pc       (debug_wb_pc        ),
    .debug0_wb_inst     (debug_wb_inst      ),
    .debug0_wb_rf_wen   (debug_wb_rf_wen    ),
    .debug0_wb_rf_wnum  (debug_wb_rf_wnum   ),
    .debug0_wb_rf_wdata (debug_wb_rf_wdata  )
);

// ============================================================================
// 2. AXI Clock Domain Crossing (cpu_clk -> sys_clk)
// ============================================================================
Axi_CDC u_axi_cdc(
    .axiInClk           (cpu_clk            ),
    .axiInRstn           (cpu_resetn         ),
    .axiOutClk          (sys_clk            ),
    .axiOutRstn          (sys_resetn         ),
    .axiIn_awvalid      (cpu_awvalid        ),
    .axiIn_awready      (cpu_awready        ),
    .axiIn_awaddr       (cpu_awaddr         ),
    .axiIn_awid         ({1'b0, cpu_awid}   ),
    .axiIn_awlen        (cpu_awlen          ),
    .axiIn_awsize       (cpu_awsize         ),
    .axiIn_awburst      (cpu_awburst        ),
    .axiIn_awlock       (cpu_awlock[0]      ),
    .axiIn_awcache      (cpu_awcache        ),
    .axiIn_awprot       (cpu_awprot         ),
    .axiIn_wvalid       (cpu_wvalid         ),
    .axiIn_wready       (cpu_wready         ),
    .axiIn_wdata        (cpu_wdata          ),
    .axiIn_wstrb        (cpu_wstrb          ),
    .axiIn_wlast        (cpu_wlast          ),
    .axiIn_bvalid       (cpu_bvalid         ),
    .axiIn_bready       (cpu_bready         ),
    .axiIn_bid          ({cpu_bid_4, cpu_bid}   ),
    .axiIn_bresp        (cpu_bresp          ),
    .axiIn_arvalid      (cpu_arvalid        ),
    .axiIn_arready      (cpu_arready        ),
    .axiIn_araddr       (cpu_araddr         ),
    .axiIn_arid         ({1'b0, cpu_arid}   ),
    .axiIn_arlen        (cpu_arlen          ),
    .axiIn_arsize       (cpu_arsize         ),
    .axiIn_arburst      (cpu_arburst        ),
    .axiIn_arlock       (cpu_arlock[0]      ),
    .axiIn_arcache      (cpu_arcache        ),
    .axiIn_arprot       (cpu_arprot         ),
    .axiIn_rvalid       (cpu_rvalid         ),
    .axiIn_rready       (cpu_rready         ),
    .axiIn_rdata        (cpu_rdata          ),
    .axiIn_rid          ({cpu_rid_4, cpu_rid}     ),
    .axiIn_rresp        (cpu_rresp          ),
    .axiIn_rlast        (cpu_rlast          ),
    .axiOut_awvalid     (cpu_sync_awvalid   ),
    .axiOut_awready     (cpu_sync_awready   ),
    .axiOut_awaddr      (cpu_sync_awaddr    ),
    .axiOut_awid        ({cpu_sync_awid_4, cpu_sync_awid}   ),
    .axiOut_awlen       (cpu_sync_awlen     ),
    .axiOut_awsize      (cpu_sync_awsize    ),
    .axiOut_awburst     (cpu_sync_awburst   ),
    .axiOut_awlock      (cpu_sync_awlock    ),
    .axiOut_awcache     (cpu_sync_awcache   ),
    .axiOut_awprot      (cpu_sync_awprot    ),
    .axiOut_wvalid      (cpu_sync_wvalid    ),
    .axiOut_wready      (cpu_sync_wready    ),
    .axiOut_wdata       (cpu_sync_wdata     ),
    .axiOut_wstrb       (cpu_sync_wstrb     ),
    .axiOut_wlast       (cpu_sync_wlast     ),
    .axiOut_bvalid      (cpu_sync_bvalid    ),
    .axiOut_bready      (cpu_sync_bready    ),
    .axiOut_bid         ({1'b0, cpu_sync_bid}    ),
    .axiOut_bresp       (cpu_sync_bresp     ),
    .axiOut_arvalid     (cpu_sync_arvalid   ),
    .axiOut_arready     (cpu_sync_arready   ),
    .axiOut_araddr      (cpu_sync_araddr    ),
    .axiOut_arid        ({cpu_sync_arid_4, cpu_sync_arid}     ),
    .axiOut_arlen       (cpu_sync_arlen     ),
    .axiOut_arsize      (cpu_sync_arsize    ),
    .axiOut_arburst     (cpu_sync_arburst   ),
    .axiOut_arlock      (cpu_sync_arlock    ),
    .axiOut_arcache     (cpu_sync_arcache   ),
    .axiOut_arprot      (cpu_sync_arprot    ),
    .axiOut_rvalid      (cpu_sync_rvalid    ),
    .axiOut_rready      (cpu_sync_rready    ),
    .axiOut_rdata       (cpu_sync_rdata     ),
    .axiOut_rid         ({1'b0, cpu_sync_rid}   ),
    .axiOut_rresp       (cpu_sync_rresp     ),
    .axiOut_rlast       (cpu_sync_rlast     )
);

// ============================================================================
// 3. SRAM 控制器
// ============================================================================
axi_wrap_ram_sp_external u_axi_ram (
    .aclk               (sys_clk            ),
    .aresetn            (sys_resetn         ),
    .axi_arid           (ram_arid           ),
    .axi_araddr         (ram_araddr         ),
    .axi_arlen          (ram_arlen          ),
    .axi_arsize         (ram_arsize         ),
    .axi_arburst        (ram_arburst        ),
    .axi_arlock         (ram_arlock         ), // 端口1位，原{1'b0,..}拼成2位致DC link不匹配将axi_wrap_ram黑盒化；ram_arlock本就是1位，去掉死位拼接
    .axi_arcache        (ram_arcache        ),
    .axi_arprot         (ram_arprot         ),
    .axi_arvalid        (ram_arvalid        ),
    .axi_arready        (ram_arready        ),
    .axi_rid            (ram_rid            ),
    .axi_rdata          (ram_rdata          ),
    .axi_rresp          (ram_rresp          ),
    .axi_rlast          (ram_rlast          ),
    .axi_rvalid         (ram_rvalid         ),
    .axi_rready         (ram_rready         ),
    .axi_awid           (ram_awid           ),
    .axi_awaddr         (ram_awaddr         ),
    .axi_awlen          (ram_awlen          ),
    .axi_awsize         (ram_awsize         ),
    .axi_awburst        (ram_awburst        ),
    .axi_awlock         (ram_awlock         ), // 端口1位，原{1'b0,..}拼成2位致DC link不匹配将axi_wrap_ram黑盒化；ram_awlock本就是1位，去掉死位拼接
    .axi_awcache        (ram_awcache        ),
    .axi_awprot         (ram_awprot         ),
    .axi_awvalid        (ram_awvalid        ),
    .axi_awready        (ram_awready        ),
    .axi_wdata          (ram_wdata          ),
    .axi_wstrb          (ram_wstrb          ),
    .axi_wlast          (ram_wlast          ),
    .axi_wvalid         (ram_wvalid         ),
    .axi_wready         (ram_wready         ),
    .axi_bid            (ram_bid            ),
    .axi_bresp          (ram_bresp          ),
    .axi_bvalid         (ram_bvalid         ),
    .axi_bready         (ram_bready         ),
    .base_ram_data      (base_ram_data      ),
    .base_ram_addr      (base_ram_addr      ),
    .base_ram_be_n      (base_ram_be_n      ),
    .base_ram_ce_n      (base_ram_ce_n      ),
    .base_ram_oe_n      (base_ram_oe_n      ),
    .base_ram_we_n      (base_ram_we_n      ),
    .ext_ram_data       (ext_ram_data       ),
    .ext_ram_addr       (ext_ram_addr       ),
    .ext_ram_be_n       (ext_ram_be_n       ),
    .ext_ram_ce_n       (ext_ram_ce_n       ),
    .ext_ram_oe_n       (ext_ram_oe_n       ),
    .ext_ram_we_n       (ext_ram_we_n       )
);

// ============================================================================
// 4. UART 控制器
// ============================================================================
axi_uart_controller u_axi_uart_controller (
    .clk                (sys_clk            ),
    .rst_n              (sys_resetn         ),
    .axi_s_awid         (uart_awid          ),
    .axi_s_awaddr       (uart_awaddr        ),
    .axi_s_awlen        (uart_awlen         ),
    .axi_s_awsize       (uart_awsize        ),
    .axi_s_awburst      (uart_awburst       ),
    .axi_s_awlock       ({1'b0, uart_awlock}),
    .axi_s_awcache      (uart_awcache       ),
    .axi_s_awprot       (uart_awprot        ),
    .axi_s_awvalid      (uart_awvalid       ),
    .axi_s_awready      (uart_awready       ),
    .axi_s_wid          (uart_awid          ),
    .axi_s_wdata        (uart_wdata         ),
    .axi_s_wstrb        (uart_wstrb         ),
    .axi_s_wlast        (uart_wlast         ),
    .axi_s_wvalid       (uart_wvalid        ),
    .axi_s_wready       (uart_wready        ),
    .axi_s_bid          (uart_bid           ),
    .axi_s_bresp        (uart_bresp         ),
    .axi_s_bvalid       (uart_bvalid        ),
    .axi_s_bready       (uart_bready        ),
    .axi_s_arid         (uart_arid          ),
    .axi_s_araddr       (uart_araddr        ),
    .axi_s_arlen        (uart_arlen         ),
    .axi_s_arsize       (uart_arsize        ),
    .axi_s_arburst      (uart_arburst       ),
    .axi_s_arlock       ({1'b0, uart_arlock}),
    .axi_s_arcache      (uart_arcache       ),
    .axi_s_arprot       (uart_arprot        ),
    .axi_s_arvalid      (uart_arvalid       ),
    .axi_s_arready      (uart_arready       ),
    .axi_s_rid          (uart_rid           ),
    .axi_s_rdata        (uart_rdata         ),
    .axi_s_rresp        (uart_rresp         ),
    .axi_s_rlast        (uart_rlast         ),
    .axi_s_rvalid       (uart_rvalid        ),
    .axi_s_rready       (uart_rready        ),
    // dma信号不用，填0
    .apb_rw_dma         (1'b0               ),
    .apb_psel_dma       (1'b0               ),
    .apb_enab_dma       (1'b0               ),
    .apb_addr_dma       (20'b0              ),
    .apb_valid_dma      (1'b0               ),
    .apb_wdata_dma      (32'b0              ),
    .apb_rdata_dma      (                   ),
    .apb_ready_dma      (                   ),
    .dma_grant          (                   ),
    .dma_req_o          (                   ),
    .dma_ack_i          (1'b0               ),
    .uart0_txd_i        (uart0_txd_i        ),
    .uart0_txd_o        (uart0_txd_o        ),
    .uart0_txd_oe       (uart0_txd_oe       ),
    .uart0_rxd_i        (uart0_rxd_i        ),
    .uart0_rxd_o        (uart0_rxd_o        ),
    .uart0_rxd_oe       (uart0_rxd_oe       ),
    .uart0_rts_o        (uart0_rts_o        ),
    .uart0_dtr_o        (uart0_dtr_o        ),
    .uart0_cts_i        (uart0_cts_i        ),
    .uart0_dsr_i        (uart0_dsr_i        ),
    .uart0_dcd_i        (uart0_dcd_i        ),
    .uart0_ri_i         (uart0_ri_i         ),
    .uart0_int          (uart0_int          )
);

// ============================================================================
// 5. Confreg 外设
// ============================================================================
confreg #(.SIMULATION(SIMULATION)) u_confreg (
    .aclk               (sys_clk            ),
    .aresetn            (sys_resetn         ),
    .cpu_clk            (cpu_clk            ),
    .cpu_resetn         (cpu_resetn         ),
    .s_awid             (confreg_awid       ),
    .s_awaddr           (confreg_awaddr     ),
    .s_awlen            (confreg_awlen      ),
    .s_awsize           (confreg_awsize     ),
    .s_awburst          (confreg_awburst    ),
    .s_awlock           (confreg_awlock     ),
    .s_awcache          (confreg_awcache    ),
    .s_awprot           (confreg_awprot     ),
    .s_awvalid          (confreg_awvalid    ),
    .s_awready          (confreg_awready    ),
    .s_wid              (confreg_awid       ),
    .s_wdata_i          (confreg_wdata      ),
    .s_wstrb_i          (confreg_wstrb      ),
    .s_wlast            (confreg_wlast      ),
    .s_wvalid           (confreg_wvalid     ),
    .s_wready           (confreg_wready     ),
    .s_bid              (confreg_bid        ),
    .s_bresp            (confreg_bresp      ),
    .s_bvalid           (confreg_bvalid     ),
    .s_bready           (confreg_bready     ),
    .s_arid             (confreg_arid       ),
    .s_araddr           (confreg_araddr     ),
    .s_arlen            (confreg_arlen      ),
    .s_arsize           (confreg_arsize     ),
    .s_arburst          (confreg_arburst    ),
    .s_arlock           (confreg_arlock     ),
    .s_arcache          (confreg_arcache    ),
    .s_arprot           (confreg_arprot     ),
    .s_arvalid          (confreg_arvalid    ),
    .s_arready          (confreg_arready    ),
    .s_rid              (confreg_rid        ),
    .s_rdata_o          (confreg_rdata      ),
    .s_rresp            (confreg_rresp      ),
    .s_rlast            (confreg_rlast      ),
    .s_rvalid           (confreg_rvalid     ),
    .s_rready           (confreg_rready     ),
    .switch             (dip_sw             ),
    .touch_btn          (touch_btn          ),
    .led                (leds               ),
    .dpy0               (dpy0               ),
    .dpy1               (dpy1               ),
    .confreg_int        (confreg_int        )
);

// ============================================================================
// 6. DVI 显示控制器
// ============================================================================
axi_dvi u_axi_dvi (
    .aclk               (sys_clk            ),
    .aresetn            (sys_resetn         ),
    .s_awvalid          (dvi_awvalid        ),
    .s_awready          (dvi_awready        ),
    .s_awaddr           (dvi_awaddr         ),
    .s_awid             (dvi_awid           ),
    .s_awlen            (dvi_awlen          ),
    .s_awsize           (dvi_awsize         ),
    .s_awburst          (dvi_awburst        ),
    .s_awlock           (dvi_awlock[0]      ),
    .s_awcache          (dvi_awcache        ),
    .s_awprot           (dvi_awprot         ),
    .s_wvalid           (dvi_wvalid         ),
    .s_wready           (dvi_wready         ),
    .s_wdata_i          (dvi_wdata          ),
    .s_wstrb_i          (dvi_wstrb          ),
    .s_wlast            (dvi_wlast          ),
    .s_bvalid           (dvi_bvalid         ),
    .s_bready           (dvi_bready         ),
    .s_bid              (dvi_bid            ),
    .s_bresp            (dvi_bresp          ),
    .s_arvalid          (dvi_arvalid        ),
    .s_arready          (dvi_arready        ),
    .s_araddr           (dvi_araddr         ),
    .s_arid             (dvi_arid           ),
    .s_arlen            (dvi_arlen          ),
    .s_arsize           (dvi_arsize         ),
    .s_arburst          (dvi_arburst        ),
    .s_arlock           (dvi_arlock[0]      ),
    .s_arcache          (dvi_arcache        ),
    .s_arprot           (dvi_arprot         ),
    .s_rvalid           (dvi_rvalid         ),
    .s_rready           (dvi_rready         ),
    .s_rdata_o          (dvi_rdata          ),
    .s_rid              (dvi_rid            ),
    .s_rresp            (dvi_rresp          ),
    .s_rlast            (dvi_rlast          ),
    .video_clk          (video_clk          ),
    .hsync              (video_hsync        ),
    .vsync              (video_vsync        ),
    .data_enable        (video_de           ),
    .video_red          (video_red          ),
    .video_green        (video_green        ),
    .video_blue         (video_blue         )
);


endmodule


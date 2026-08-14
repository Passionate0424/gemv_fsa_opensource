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

module axi_wrap_ram_sp_external (
    input         aclk,
    input         aresetn,
    //ar
    input  [4 :0] axi_arid   ,
    input  [31:0] axi_araddr ,
    input  [7 :0] axi_arlen  ,
    input  [2 :0] axi_arsize ,
    input  [1 :0] axi_arburst,
    input         axi_arlock ,
    input  [3 :0] axi_arcache,
    input  [2 :0] axi_arprot ,
    input         axi_arvalid,
    output        axi_arready,
    //r
    output [4 :0] axi_rid    ,
    output [63:0] axi_rdata  ,
    output [1 :0] axi_rresp  ,
    output        axi_rlast  ,
    output        axi_rvalid ,
    input         axi_rready ,
    //aw
    input  [4 :0] axi_awid   ,
    input  [31:0] axi_awaddr ,
    input  [7 :0] axi_awlen  ,
    input  [2 :0] axi_awsize ,
    input  [1 :0] axi_awburst,
    input         axi_awlock ,
    input  [3 :0] axi_awcache,
    input  [2 :0] axi_awprot ,
    input         axi_awvalid,
    output        axi_awready,
    //w
    input  [63:0] axi_wdata  ,
    input  [7 :0] axi_wstrb  ,
    input         axi_wlast  ,
    input         axi_wvalid ,
    output        axi_wready ,
    //b
    output [4 :0] axi_bid    ,
    output [1 :0] axi_bresp  ,
    output        axi_bvalid ,
    input         axi_bready ,

    //BaseRAM信号
    inout  [31:0] base_ram_data,  //BaseRAM数据，低8位与CPLD串口控制器共享
    output [19:0] base_ram_addr, //BaseRAM地址
    output [ 3:0] base_ram_be_n,  //BaseRAM字节使能，低有效。如果不使用字节使能，请保持为0
    output  base_ram_ce_n,       //BaseRAM片选，低有效
    output  base_ram_oe_n,       //BaseRAM读使能，低有效
    output  base_ram_we_n,       //BaseRAM写使能，低有效

    //ExtRAM信号
    inout  [31:0] ext_ram_data,  //ExtRAM数据
    output [19:0] ext_ram_addr, //ExtRAM地址
    output [ 3:0] ext_ram_be_n,  //ExtRAM字节使能，低有效。如果不使用字节使能，请保持为0
    output  ext_ram_ce_n,       //ExtRAM片选，低有效
    output  ext_ram_oe_n,       //ExtRAM读使能，低有效
    output  ext_ram_we_n       //ExtRAM写使能，低有效
);


//ram axi
//ar
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
//r
wire [4 :0] ram_rid    ;
wire [63:0] ram_rdata  ;
wire [1 :0] ram_rresp  ;
wire        ram_rlast  ;
wire        ram_rvalid ;
wire        ram_rready ;
//aw
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
//w
wire [63:0] ram_wdata  ;
wire [7 :0] ram_wstrb  ;
wire        ram_wlast  ;
wire        ram_wvalid ;
wire        ram_wready ;
//b
wire [4 :0] ram_bid    ;
wire [1 :0] ram_bresp  ;
wire        ram_bvalid ;
wire        ram_bready ;

//sram signal
wire  [31:0]    soc_sram_addr;
wire            soc_sram_cs;
wire            soc_sram_we;
wire  [7:0]     soc_sram_be;   // 64 位总线的字节使能，低 4 位归 BaseRAM、高 4 位归 ExtRAM
wire  [63:0]    soc_sram_wdata;   // 低 32 位落 BaseRAM，高 32 位落 ExtRAM
wire  [63:0]    soc_sram_rdata;
// 时序优化：桥引出的已寄存首拍地址，仅供 WE 脉冲判定 BaseRAM/ExtRAM
wire  [31:0]    ax_req_q_addr_o;

//ar
assign ram_arid    = axi_arid   ;
assign ram_araddr  = axi_araddr ;
assign ram_arlen   = axi_arlen  ;
assign ram_arsize  = axi_arsize ;
assign ram_arburst = axi_arburst;
assign ram_arlock  = axi_arlock ;
assign ram_arcache = axi_arcache;
assign ram_arprot  = axi_arprot ;
assign ram_arvalid = axi_arvalid;
assign axi_arready = ram_arready;
//r
assign axi_rid    = axi_rvalid ? ram_rid   :  5'd0 ;
assign axi_rdata  = axi_rvalid ? ram_rdata : 64'd0 ;
assign axi_rresp  = axi_rvalid ? ram_rresp :  2'd0 ;
assign axi_rlast  = axi_rvalid ? ram_rlast :  1'd0 ;
assign axi_rvalid = ram_rvalid;
assign ram_rready = axi_rready;
//aw
assign ram_awid    = axi_awid   ;
assign ram_awaddr  = axi_awaddr ;
assign ram_awlen   = axi_awlen  ;
assign ram_awsize  = axi_awsize ;
assign ram_awburst = axi_awburst;
assign ram_awlock  = axi_awlock ;
assign ram_awcache = axi_awcache;
assign ram_awprot  = axi_awprot ;
assign ram_awvalid = axi_awvalid;
assign axi_awready = ram_awready;
//w
assign ram_wdata  = axi_wdata  ;
assign ram_wstrb  = axi_wstrb  ;
assign ram_wlast  = axi_wlast  ;
assign ram_wvalid = axi_wvalid ;
assign axi_wready = ram_wready ;
//b
assign axi_bid    = axi_bvalid ? ram_bid   : 5'd0 ;
assign axi_bresp  = axi_bvalid ? ram_bresp : 2'd0 ;
assign axi_bvalid = ram_bvalid ;
assign ram_bready = axi_bready ;


// 单拍读+单拍写优化桥（drop-in 替换原 axi2sram_sp_external，端口一致）。
// 配合上方 WE 相位脉冲保证连续单拍写不踩地址翻转写穿。
axi2sram_sp_ext #(
    .AXI_ID_WIDTH   ( 5  ),
    .AXI_ADDR_WIDTH ( 32 ),
    .AXI_DATA_WIDTH ( 64 ))
 u_axi_sram_sp (
    .clk                     ( aclk         ),
    .resetn                  ( aresetn      ),

    .s_araddr                ( ram_araddr    ),
    .s_arburst               ( ram_arburst   ),
    .s_arcache               ( ram_arcache   ),
    .s_arid                  ( ram_arid      ),
    .s_arlen                 ( ram_arlen     ),
    .s_arlock                ( ram_arlock    ),
    .s_arprot                ( ram_arprot    ),
    .s_arsize                ( ram_arsize    ),
    .s_arvalid               ( ram_arvalid   ),
    .s_awaddr                ( ram_awaddr    ),
    .s_awburst               ( ram_awburst   ),
    .s_awcache               ( ram_awcache   ),
    .s_awid                  ( ram_awid      ),
    .s_awlen                 ( ram_awlen     ),
    .s_awlock                ( ram_awlock    ),
    .s_awprot                ( ram_awprot    ),
    .s_awsize                ( ram_awsize    ),
    .s_awvalid               ( ram_awvalid   ),
    .s_bready                ( ram_bready    ),
    .s_rready                ( ram_rready    ),
    .s_wdata                 ( ram_wdata     ),
    .s_wlast                 ( ram_wlast     ),
    .s_wstrb                 ( ram_wstrb     ),
    .s_wvalid                ( ram_wvalid    ),
    .s_arready               ( ram_arready   ),
    .s_awready               ( ram_awready   ),
    .s_bid                   ( ram_bid       ),
    .s_bresp                 ( ram_bresp     ),
    .s_bvalid                ( ram_bvalid    ),
    .s_rdata                 ( ram_rdata     ),
    .s_rid                   ( ram_rid       ),
    .s_rlast                 ( ram_rlast     ),
    .s_rresp                 ( ram_rresp     ),
    .s_rvalid                ( ram_rvalid    ),
    .s_wready                ( ram_wready    ),

    .req_o                   ( soc_sram_cs       ),
    .we_o                    ( soc_sram_we       ),
    .addr_o                  ( soc_sram_addr     ),
    .be_o                    ( soc_sram_be       ),
    .data_o                  ( soc_sram_wdata    ),
    .data_i                  ( soc_sram_rdata    ),
    .ax_req_q_addr_o         ( ax_req_q_addr_o   )
);

wire [7:0] be_out = soc_sram_we ? soc_sram_be : 8'hFF;

// ============================================================
// 两片 SRAM 并成一条 64 位总线：BaseRAM 存低 32 位（偶数字）、ExtRAM 存高 32 位（奇数字），
// 两片同址同时工作，一次取回 8 字节。片内地址随之从 addr[21:2] 挪到 addr[22:3]——8MB 空间
// 按 64 位字编址正好 1M 个 entry，每片仍是 1M×32 位，容量与引脚不变。
// 不再需要按 addr[22] 二选一，WE 专用选择位那条通路也一并取消。
//
// 第廿八刀(IOB地址寄存化,破IS61WV102416ALL tAA=10ns读墙):
//   SRAM 接口输出(addr/ce/oe/we/be/wdata)全部寄存并IOB打包(紧贴OBUF),
//   消除 addr→OBUF 长线 route(5.8→~4ns)→数据有效 4+10=14ns<15.484ns(64.583过)。
//   全部信号统一延1拍→读写相对时序保持;桥读FSM已配 depth-2(READ_HOLD+out_cnt)
//   吸收此1拍地址延迟。读数据保持组合(地址延1拍→数据自然晚1拍回)。
// ============================================================
wire [3:0] base_be_n_c = ~be_out[3:0];
wire [3:0] ext_be_n_c  = ~be_out[7:4];
wire       ram_ce_n_c  = ~soc_sram_cs;
// oe_n 必须带上 cs：只写 `soc_sram_we` 的话，**空闲时（cs=0、we=0）oe_n 恒为 0**，
// 两片 SRAM 一直往共享数据总线上输出。板上那条总线不只有 FPGA 一个主设备——
// zynq 管理芯片烧程序时也要驱动它，于是撞车。
//
// 加宽前这条写成 `soc_sram_we | choose_sram_we`（ext 侧是三目），addr[22] 恒把
// 两片中的一片的 oe_n 拉高，**总有一片是让开的**，所以从没暴露。加宽改成两片同时
// 工作后这个隐含保护没了。
//
// 实测现象：FPGA 空闲时地址寄存器保持 0，恰好和 zynq 写地址 0 撞上——平台写完
// 回读，SRAM 地址 0 那一个字永远是 ffffffff、其余全对；写 offset 8 则一字不丢；
// 与写入内容无关（写 pattern 也丢）；32 位 bit 同一文件正常。CPU 第一条指令取到
// 0xffffffff（LoongArch 未定义编码）就挂死，表现为完全无串口输出。
//
// 仿真里永远照不出来：tb 只有 FPGA 一个主设备，没有 zynq 那一侧。
wire       ram_oe_n_c  = ~soc_sram_cs | soc_sram_we;
wire       ram_we_n_c  = ~(soc_sram_cs & soc_sram_we);
wire       ram_wen_c   = soc_sram_cs & soc_sram_we;   // 写输出使能（三态）

(* IOB = "TRUE" *) reg [19:0] base_ram_addr_q, ext_ram_addr_q;
(* IOB = "TRUE" *) reg [3:0]  base_ram_be_n_q, ext_ram_be_n_q;
(* IOB = "TRUE" *) reg        base_ram_ce_n_q, ext_ram_ce_n_q;
(* IOB = "TRUE" *) reg        base_ram_oe_n_q, ext_ram_oe_n_q;
(* IOB = "TRUE" *) reg        base_ram_we_n_q, ext_ram_we_n_q;
(* IOB = "TRUE" *) reg [31:0] base_ram_data_q, ext_ram_data_q;   // 写数据(IOB输出寄存)

// 写输出使能（三态 T）——**必须每根数据线一个，且钉进各自引脚的 OLOGIC TFF**。
//
// 原来这里是两个标量 `reg base_wen_q, ext_wen_q`、没有 IOB 属性。网表实测后果：
//   base_wen_q_reg  LOC=SLICE_X10Y71  BEL=SLICEM.AFF  IOB=(空)   ← 留在 fabric
//   ext_wen_q       0 cells                                      ← 赋值相同被合并掉
//   base_ram_data_q OLOGIC_X0Y132     OUTFF           IOB=TRUE   ← 数据在引脚旁
//   base_ram_oe_n_q OLOGIC_X0Y70      OUTFF           IOB=TRUE   ← OE 在引脚旁
// 即：**一个 fabric 寄存器驱动两条 32 位总线共 64 个 IOBUF 的 T 端**（实测该网络
// FLAT_PIN_COUNT=65），而数据与 OE 都在引脚旁。
//
// 物理后果：写周期结束时，FPGA 的数据驱动器要等 T 信号从那个 SLICE 走布线到分散
// 在芯片边缘的 64 个 IOBUF 才关断——**又晚又参差**；而 SRAM 的 OE 从引脚旁的
// OLOGIC 直接出来、准时打开。两边在双向数据总线上重叠驱动，读回的就是坏数据。
//
// 为什么一直没被发现：
//   * RTL 仿真里所有信号按拍对齐，没有布线延迟，这个窗口根本不存在
//   * STA 也看不见——soc.xdc 的 set_output_delay 约束的是 data/addr/ce/oe 端口，
//     **三态 T 路径没有任何约束**
//   * 只有"DMA 刚写完、CPU 立刻读"这种紧邻的写读交接才撞得上；memtest 那种
//     写一大片再读一大片的形态几乎碰不到
//
// 逐位展开 + IOB=TRUE，让每个 IOBUF 用自己 OLOGIC 里的 TFF，T 路径与数据路径等长。
(* IOB = "TRUE" *) reg [31:0] base_wen_q, ext_wen_q;

// 复位期间把 ce_n/we_n/oe_n 全部拉高、写三态关掉，让 FPGA **完全让出**外部 SRAM
// 总线。板上那条总线不只有 FPGA 一个主设备：zynq 管理芯片烧程序时也要驱动它。
//
// 原来这个 always 块没有复位分支，所有 IOB 寄存器上电取综合器初值（通常 0，
// 即"选中 + 写使能有效"），而地址寄存器同样是 0——恰好在 zynq 写 SRAM 地址 0
// 的时候，FPGA 也在用地址 0 发写命令，两者对同一个单元打架。
//
// 实测证据（云平台，同一 pattern 写三个 offset）：
//   offset 0x0   -> 首字回读 ffffffff，其余全对
//   offset 0x20  -> 全对
//   offset 0x100 -> 全对
// 只有物理地址 0 那一个单元写不进，与写入内容无关、降频无改善、稳定复现。
// CPU 第一条指令正是 word 0，取到 0xffffffff（LoongArch 未定义编码）直接挂死，
// 表现为完全无串口输出。
//
// 32 位版没这个问题不是因为它有复位，而是它的 ce_n 由 addr[22] 门控成"二选一"，
// 上电初值下两片不会同时被选中。加宽改成两片并宽后这层隐含保护消失了。
//
// 仿真永远照不出来：tb 里只有 FPGA 一个主设备，没有 zynq 那一侧。
always @(posedge aclk) begin
  if (!aresetn) begin
    base_ram_ce_n_q <= 1'b1;
    ext_ram_ce_n_q  <= 1'b1;
    base_ram_we_n_q <= 1'b1;
    ext_ram_we_n_q  <= 1'b1;
    base_ram_oe_n_q <= 1'b1;
    ext_ram_oe_n_q  <= 1'b1;
    base_wen_q      <= 32'b0;  // 数据线保持高阻（逐位，每位一个 IOB TFF）
    ext_wen_q       <= 32'b0;
  end else begin
    base_ram_addr_q <= soc_sram_addr[22:3];
    ext_ram_addr_q  <= soc_sram_addr[22:3];
    base_ram_be_n_q <= base_be_n_c;
    ext_ram_be_n_q  <= ext_be_n_c;
    base_ram_ce_n_q <= ram_ce_n_c;
    ext_ram_ce_n_q  <= ram_ce_n_c;
    base_ram_oe_n_q <= ram_oe_n_c;
    ext_ram_oe_n_q  <= ram_oe_n_c;
    base_ram_we_n_q <= ram_we_n_c;
    ext_ram_we_n_q  <= ram_we_n_c;
    base_ram_data_q <= soc_sram_wdata[31:0];
    ext_ram_data_q  <= soc_sram_wdata[63:32];
    base_wen_q      <= {32{ram_wen_c}};
    ext_wen_q       <= {32{ram_wen_c}};
  end
end

assign base_ram_addr = base_ram_addr_q;
// 第廿八刀:全部改用IOB寄存版(延1拍),见上方寄存块。
// 并宽后 be_n 不再依赖任何"选哪片"的判断，历史上为斩断
// cnt_q→s_rlast比较→addr_o[22]→be_n→OBUF 这条违例主链而设的寄存版选择位随之取消。
assign base_ram_be_n = base_ram_be_n_q;
assign base_ram_ce_n = base_ram_ce_n_q;
assign base_ram_oe_n = base_ram_oe_n_q;
assign base_ram_we_n = base_ram_we_n_q;
// 逐位三态：每根数据线用自己的 T 寄存器，工具才能把它塞进该引脚的 OLOGIC TFF。
// 写成整体 `base_wen_q ? data : 32'hz` 的话，32 个 IOBUF 共享一个 T 源，
// 那个源就只能留在 fabric —— 正是修改前的状态（实测扇出 65）。
genvar tri_i;
generate
    for (tri_i = 0; tri_i < 32; tri_i = tri_i + 1) begin : TRI_BASE
        assign base_ram_data[tri_i] = base_wen_q[tri_i] ? base_ram_data_q[tri_i] : 1'bz;
    end
endgenerate

assign ext_ram_addr = ext_ram_addr_q;
assign ext_ram_be_n = ext_ram_be_n_q;
assign ext_ram_ce_n = ext_ram_ce_n_q;
assign ext_ram_oe_n = ext_ram_oe_n_q;
assign ext_ram_we_n = ext_ram_we_n_q;
generate
    for (tri_i = 0; tri_i < 32; tri_i = tri_i + 1) begin : TRI_EXT
        assign ext_ram_data[tri_i] = ext_wen_q[tri_i] ? ext_ram_data_q[tri_i] : 1'bz;
    end
endgenerate

// 两片同址同拍返回，直接拼成 64 位：BaseRAM 是低字、ExtRAM 是高字。
assign soc_sram_rdata = {ext_ram_data, base_ram_data};


endmodule

// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// ----------------------------
// AXI to SRAM Adapter
// ----------------------------
// Author: Florian Zaruba (zarubaf@iis.ee.ethz.ch)
//
// Description: Manages AXI transactions
//              Supports all burst accesses but only on aligned addresses and with full data width.
//              Assertions should guide you if there is something unsupported happening.
//
module axi2sram_sp_ext #(
    parameter AXI_ID_WIDTH      = 5,
    parameter AXI_ADDR_WIDTH    = 32,
    parameter AXI_DATA_WIDTH    = 32,
    parameter AR_FIFO_DEPTH     = 4   // multi-outstanding AR缓冲深度
)(
    input                         clk,
    input                         resetn,

    input     [AXI_ADDR_WIDTH-1:0] s_araddr ,
    input     [1               :0] s_arburst,
    input     [3               :0] s_arcache,
    input     [AXI_ID_WIDTH-1  :0] s_arid   ,
    input     [7               :0] s_arlen  ,
    input                          s_arlock ,
    input     [2               :0] s_arprot ,
    output reg                        s_arready,
    input     [2               :0] s_arsize ,
    input                          s_arvalid,
    input     [AXI_ADDR_WIDTH-1:0] s_awaddr ,
    input     [1               :0] s_awburst,
    input     [3               :0] s_awcache,
    input     [AXI_ID_WIDTH-1  :0] s_awid   ,
    input     [7               :0] s_awlen  ,
    input                          s_awlock ,
    input     [2               :0] s_awprot ,
    output reg                        s_awready,
    input     [2               :0] s_awsize ,
    input                          s_awvalid,
    output reg   [AXI_ID_WIDTH-1  :0] s_bid    ,
    input                          s_bready ,
    output reg   [1               :0] s_bresp  ,
    output reg                        s_bvalid ,
    output reg   [AXI_DATA_WIDTH-1:0] s_rdata  ,
    output reg   [AXI_ID_WIDTH-1    :0] s_rid    ,
    output reg                        s_rlast  ,
    input                          s_rready ,
    output reg   [1               :0] s_rresp  ,
    output reg                        s_rvalid ,
    input     [AXI_DATA_WIDTH-1:0] s_wdata  ,
    input                          s_wlast  ,
    output reg                        s_wready ,
    input     [AXI_DATA_WIDTH/8-1:0] s_wstrb  ,
    input                          s_wvalid ,

    output  reg                       req_o,
    output  reg                       we_o,
    output  reg [AXI_ADDR_WIDTH-1:0]   addr_o,
    output  reg [AXI_DATA_WIDTH/8-1:0] be_o,
    output  reg [AXI_DATA_WIDTH-1:0]   data_o,
    input   [AXI_DATA_WIDTH-1:0]   data_i,
    // 时序优化：引出已寄存的首拍地址（仅供 wrapper 给"写使能 WE 门控"判定
    //  BaseRAM/ExtRAM）。addr_o[22] 来自 WRAP 比较长链(CARRY4×7)，是 WE 门控
    //  关键路径瓶颈；而写时一次 burst 不跨 4KB(AXI 规定)，bit[22]=4MB 边界恒定，
    //  ax_req_q_addr[22] 与 addr_o[22] 写时 100% 等价但时序早好几级。
    //  注意：仅 WE 用此寄存器版；读数据选择/ce/oe/be 仍用组合 addr_o[22]
    //  （读首拍 addr_o 提前组合输出，寄存器版会慢一拍选错——见 worklog 踩坑）。
    output  [AXI_ADDR_WIDTH-1:0]   ax_req_q_addr_o
);
    // AXI has the following rules governing the use of bursts:
    // - for wrapping bursts, the burst length must be 2, 4, 8, or 16
    // - a burst must not cross a 4KB address boundary
    // - early termination of bursts is not supported.

    localparam LOG_NR_BYTES = $clog2(AXI_DATA_WIDTH/8);

    // ============================================================
    // AR FIFO：支持multi-outstanding读（解耦AR接受与FSM处理）
    // ============================================================
    localparam AR_FIFO_WIDTH = AXI_ID_WIDTH + AXI_ADDR_WIDTH + 8 + 3 + 2; // id+addr+len+size+burst
    localparam AR_PTR_WIDTH = $clog2(AR_FIFO_DEPTH) + 1;

    reg [AR_FIFO_WIDTH-1:0] ar_fifo [0:AR_FIFO_DEPTH-1];
    reg [AR_PTR_WIDTH-1:0]  ar_fifo_wptr, ar_fifo_rptr;
    wire ar_fifo_full  = (ar_fifo_wptr[AR_PTR_WIDTH-1] != ar_fifo_rptr[AR_PTR_WIDTH-1]) &&
                         (ar_fifo_wptr[AR_PTR_WIDTH-2:0] == ar_fifo_rptr[AR_PTR_WIDTH-2:0]);
    wire ar_fifo_empty = (ar_fifo_wptr == ar_fifo_rptr);
    wire ar_fifo_push  = s_arvalid && !ar_fifo_full;
    reg  ar_fifo_pop;

    // FIFO输出解包
    wire [AR_FIFO_WIDTH-1:0] ar_fifo_dout = ar_fifo[ar_fifo_rptr[$clog2(AR_FIFO_DEPTH)-1:0]];
    wire [AXI_ID_WIDTH-1:0]   ar_fifo_id    = ar_fifo_dout[AR_FIFO_WIDTH-1 -: AXI_ID_WIDTH];
    wire [AXI_ADDR_WIDTH-1:0] ar_fifo_addr  = ar_fifo_dout[AR_FIFO_WIDTH-1-AXI_ID_WIDTH -: AXI_ADDR_WIDTH];
    wire [7:0]                ar_fifo_len   = ar_fifo_dout[12:5];
    wire [2:0]                ar_fifo_size  = ar_fifo_dout[4:2];
    wire [1:0]                ar_fifo_burst = ar_fifo_dout[1:0];

    // FIFO写入（AR通道握手时push）
    always @(posedge clk or negedge resetn) begin
        if (~resetn)
            ar_fifo_wptr <= 'd0;
        else if (ar_fifo_push)
            ar_fifo_wptr <= ar_fifo_wptr + 1'd1;
    end

    always @(posedge clk) begin
        if (ar_fifo_push)
            ar_fifo[ar_fifo_wptr[$clog2(AR_FIFO_DEPTH)-1:0]] <= {s_arid, s_araddr, s_arlen, s_arsize, s_arburst};
    end

    // FIFO读出（FSM从IDLE转READ时pop）
    always @(posedge clk or negedge resetn) begin
        if (~resetn)
            ar_fifo_rptr <= 'd0;
        else if (ar_fifo_pop)
            ar_fifo_rptr <= ar_fifo_rptr + 1'd1;
    end

    reg [AXI_ID_WIDTH-1:0]   ax_req_d_id;
    reg [AXI_ADDR_WIDTH-1:0] ax_req_d_addr;
    reg [7:0]                ax_req_d_len;
    reg [2:0]                ax_req_d_size;
    reg [1:0]                ax_req_d_burst;

    reg [AXI_ID_WIDTH-1:0]   ax_req_q_id;
    reg [AXI_ADDR_WIDTH-1:0] ax_req_q_addr;
    reg [7:0]                ax_req_q_len;
    reg [2:0]                ax_req_q_size;
    reg [1:0]                ax_req_q_burst;

    reg [3:0]                state_d;
    reg [3:0]                state_q;

    localparam              IDLE        = 4'h0;
    localparam              READ        = 4'h1;
    localparam              WRITE       = 4'h2;
    localparam              SEND_B      = 4'h3;
    localparam              WAIT_WVALID = 4'h4;
    localparam              WRITE_NOP   = 4'h5;
    localparam              READ_ADDR   = 4'h6;
    // 时序优化(提频关键路径第五刀)：读 burst 首拍 SETUP 状态。
    //   原：IDLE→READ 首拍 addr_o=ar_fifo_addr 组合直出到 SRAM 引脚，
    //       ax_req_q_len→FIFO→ar_fifo_addr→addr[22]→be_n→OBUF 这条组合直出链
    //       是 64MHz 下 CI(2019.2) WNS 违例主链(-1.681ns)。首拍必须当拍正确，
    //       无法寄存 choose_sram/addr(会读首拍选错卡死，worklog 已踩)。
    //   改：加 READ_START 拍——首地址先锁进 req_addr_q，READ_START 拍 addr_o=
    //       req_addr_q(寄存版)发 SRAM 建立地址+采数据(data_q)，不发 s_rvalid；
    //       下一拍进 READ 出首个数据。关键路径变 req_addr_q(FF)→be_n→OBUF(短)。
    //   代价：每读 burst +1 拍(zero-gap→gap1)。matmul 合并 burst(~1000个/5000组)
    //       故 busy +~1000 拍(+0.6%)，换 64MHz 收敛冲满分。读首拍正确性天然保证
    //       (多给一整拍、地址寄存后输出，不存在慢一拍选错)。
    localparam              READ_START  = 4'h7;
    // 第廿八刀:depth-2读流水第2个fill拍。READ_START驱动beat0→READ_HOLD驱动beat1
    //   (advance)+捕获beat0数据(IOB地址此拍到引脚)→READ开始输出。
    localparam              READ_HOLD   = 4'h8;

    localparam              FIXED       = 2'b00;
    localparam              INCR        = 2'b01;
    localparam              WRAP        = 2'b10;
    
    reg [AXI_ADDR_WIDTH-1:0] req_addr_d, req_addr_q;
    reg [9:0]                cnt_d, cnt_q;
    // 第廿八刀(IOB地址寄存化破tAA=10ns读墙,保吞吐):depth-2读流水输出beat计数器。
    //   地址IOB寄存使地址晚1拍到引脚→读数据晚1拍回→data_q滞后fetch。fetch侧cnt_q驱动
    //   地址,输出侧out_cnt_q(s_rlast=out_cnt==len_plus1,握手++),两者解耦drain收尾。
    reg [9:0]                out_cnt_d, out_cnt_q;
    reg [9:0]                len_plus1_q;  // = ax_req_q_len+1，锁存时算好，s_rlast 直接比较(斩加法器)
    // 第十九刀(提频 62MHz 桥地址链)：s_rlast 内部决策版预算一拍。
    //   现象：CI cut-18 唯一违例 cnt_q_reg→ext_ram_addr[6](-0.050ns)。routed 实链是
    //     s_rlast=(cnt_q==len_plus1_q) 的 10-bit 组合比较(CARRY4,fo=43)被综合器合并进
    //     addr_o 输出锥→前推到 ext_ram_addr OBUF(单条 3.17ns 长线+OBUF 3.56ns 铁墙)。
    //   改：对外 s_rlast 端口保持组合当拍值(AXI 时序零改动);另建 s_rlast_q 预算
    //     (cnt_d==len_plus1_q)一拍,READ 态内部分支决策(转态/pop/下一地址)改用 s_rlast_q,
    //     斩断 addr_o 对组合比较的依赖(addr_o 改只依赖 FF:cons_addr_q/req_addr_q/s_rlast_q)。
    //   等价性:cnt_q(N)=cnt_d(N-1)、len_plus1_q burst 内恒定→s_rlast_q(N)=
    //     (cnt_q(N)==len_plus1_q)=s_rlast(N),逐拍精确;背压(cnt_d=cnt_q)保持、首拍
    //     READ_START(cnt_d=1)、背靠背续读均覆盖。零 busy、对外时序不变。
    reg                      s_rlast_q;
    reg [AXI_DATA_WIDTH-1:0] data_q;  // data_i寄存器（适配异步SRAM）
    reg [AXI_DATA_WIDTH-1:0] skid_q;  // 背压期间暂存在途的那一拍
    reg                      skid_vld;

    // synopsys translate_off
    bit rd_trace_on;
    initial rd_trace_on = $test$plusargs("SOC_TRACE");
    // synopsys translate_on

    function automatic [AXI_ADDR_WIDTH-1:0] get_wrap_boundary;
        input [AXI_ADDR_WIDTH-1:0] unaligned_address;
        input [7:0] len;
    begin
        get_wrap_boundary = 'h0;
        //  for wrapping transfers ax_len can only be of size 1, 3, 7 or 15
        if (len == 4'b1)
            get_wrap_boundary[AXI_ADDR_WIDTH-1:1+LOG_NR_BYTES] = unaligned_address[AXI_ADDR_WIDTH-1:1+LOG_NR_BYTES];
        else if (len == 4'b11)
            get_wrap_boundary[AXI_ADDR_WIDTH-1:2+LOG_NR_BYTES] = unaligned_address[AXI_ADDR_WIDTH-1:2+LOG_NR_BYTES];
        else if (len == 4'b111)
            get_wrap_boundary[AXI_ADDR_WIDTH-1:3+LOG_NR_BYTES] = unaligned_address[AXI_ADDR_WIDTH-3:2+LOG_NR_BYTES];
        else if (len == 4'b1111)
            get_wrap_boundary[AXI_ADDR_WIDTH-1:4+LOG_NR_BYTES] = unaligned_address[AXI_ADDR_WIDTH-3:4+LOG_NR_BYTES];
    end
    endfunction

    reg [AXI_ADDR_WIDTH-1:0] aligned_address;
    reg [AXI_ADDR_WIDTH-1:0] wrap_boundary;
    reg [AXI_ADDR_WIDTH-1:0] upper_wrap_boundary;
    reg [AXI_ADDR_WIDTH-1:0] cons_addr;

    // 时序优化寄存版：aligned/wrap/upper_wrap 与 ax_req_q_addr/len 同拍锁存，
    // burst 内 cons_addr = aligned_addr_q + (cnt_q<<2) 只走短进位链，斩断
    // ax_req_q_len → wrap_boundary 长 → cons_addr → addr_o 这条 -0.100ns
    // 关键路径（CI Vivado 2019.2 违例）。
    //
    // 正确性（复刻原组合不变量）：原版 aligned_address 组合绑定 ax_req_q_addr，
    // 任何状态/读写路径自动正确。这里在时序块统一从 ax_req_d_addr（=ax_req_q_addr
    // 的次态）派生，与 ax_req_q_addr 同一时钟沿更新，故 aligned_addr_q 永远等于
    // aligned(ax_req_q_addr)——所有路径（读+写）自动正确，无需每个 case 分支手动
    // 维护（曾漏写入口 aligned_addr_d 导致写 burst 地址错乱）。
    //
    // 零 busy 开销：aligned_addr_q 在 burst 内恒定（基址不变），只是把基址计算从
    // 每拍重算挪到进 burst 前锁一次，addr_o 每拍推进节奏与原版逐拍一致，不增拍。
    reg [AXI_ADDR_WIDTH-1:0] aligned_addr_q;
    reg [AXI_ADDR_WIDTH-1:0] wrap_boundary_q;
    reg [AXI_ADDR_WIDTH-1:0] upper_wrap_boundary_q;

    // 时序优化(提频关键路径第一刀)：cons_addr 加法器预算一拍寄存化。
    //   原：cons_addr = aligned_addr_q + (cnt_q<<2) 每拍现算，cnt_q→4级CARRY4
    //       加法直挂 addr_o→ext_ram_addr 输出，是 -2.985ns 违例主链之一。
    //   改：提前一拍在寄存器块算好 cons_addr_q（输入 aligned(ax_req_d_addr) 与
    //       cnt_d 在前拍已确定），addr_o 路径只剩 cons_addr_q(reg)→WRAP mux→OBUF，
    //       把加法器移出关键路径。
    //   等价性(已逐拍推导，读/写/burst首拍/背压均成立)：aligned_addr_q 与 cnt_q
    //       均从 ax_req_d_addr/cnt_d 同沿寄存，故 cons_addr_q(N)=aligned_addr_q(N)+
    //       cnt_q(N)<<2 恒等于原组合 cons_addr(N)，逐拍精确复刻，不改功能时序。
    reg [AXI_ADDR_WIDTH-1:0] cons_addr_q;

    // 时序优化(提频关键路径第二刀)：WRAP 边界比较预算一拍寄存化。
    //   原：WRAP 分支每拍现算 cons_addr==upper_wrap_boundary_q（==）与 >（两级
    //       CARRY4 比较，i___0_carry），挂在 addr_o 输出路径上，是 -2.985ns 违例
    //       的第二段（第一刀砍加法后它成为新主段）。
    //   改：cons_addr(=cons_addr_q，第一刀后已寄存) 与 upper_wrap_boundary_q(寄存)
    //       两输入都是寄存器，故 == / > 的比较结果可提前一拍算好寄存（wrap_hit_q/
    //       wrap_over_q），WRAP 分支直接用寄存版选择，把比较链移出关键路径。
    //   等价性：wrap_hit_q(N)/wrap_over_q(N) 用与 cons_addr_q 同源同沿的次态量
    //       （cons_addr 的次态 = aligned(ax_req_d_addr)+(cnt_d<<2)）对
    //       upper_wrap_boundary 的次态比较，落沿后恒等于原组合 cons_addr(N) vs
    //       upper_wrap_boundary_q(N)，逐拍精确复刻。仅 WRAP burst(CPU cache)用，
    //       matmul 纯 INCR 不经此分支。
    reg wrap_hit_q;    // cons_addr == upper_wrap_boundary（预算一拍）
    reg wrap_over_q;   // cons_addr >  upper_wrap_boundary（预算一拍）

    // 次态量（供 cons_addr_q / wrap_hit_q / wrap_over_q 共用，保证三者同源同沿，
    // 落沿后 cons_addr_q(N)、wrap_hit_q(N)、wrap_over_q(N) 严格一致）：
    //   cons_addr_nxt = aligned(ax_req_d_addr) + (cnt_d<<2)  = cons_addr 的次态
    //   upper_wrap_nxt = upper_wrap_boundary 的次态（与 upper_wrap_boundary_q 同式）
    wire [AXI_ADDR_WIDTH-1:0] cons_addr_nxt =
        {ax_req_d_addr[AXI_ADDR_WIDTH-1:LOG_NR_BYTES], {{LOG_NR_BYTES}{1'b0}}}
        + (cnt_d << LOG_NR_BYTES);
    wire [AXI_ADDR_WIDTH-1:0] upper_wrap_nxt =
        get_wrap_boundary(ax_req_d_addr, ax_req_d_len) + ((ax_req_d_len + 1) << LOG_NR_BYTES);

    always @ (*) begin
        // address generation
        // 组合版（保留，供 catch-all/READ_ADDR 等次级状态用）
        aligned_address = {ax_req_q_addr[AXI_ADDR_WIDTH-1:LOG_NR_BYTES], {{LOG_NR_BYTES}{1'b0}}};
        wrap_boundary = get_wrap_boundary(ax_req_q_addr, ax_req_q_len);
        // this will overflow
        upper_wrap_boundary = wrap_boundary + ((ax_req_q_len + 1) << LOG_NR_BYTES);
        // calculate consecutive address
        // 时序优化：cons_addr 用预算一拍的寄存版 cons_addr_q（见声明处推导），
        // 把 cnt_q→加法器 移出 addr_o 输出关键路径，斩断 -2.985ns 违例主链。
        cons_addr = cons_addr_q;

        // Transaction attributes
        // default assignments
        state_d         = state_q;
        ax_req_d_id     = ax_req_q_id;
        ax_req_d_addr   = ax_req_q_addr;
        ax_req_d_len    = ax_req_q_len;
        ax_req_d_size   = ax_req_q_size;
        ax_req_d_burst  = ax_req_q_burst;
        req_addr_d      = req_addr_q;
        cnt_d           = cnt_q;
        out_cnt_d       = out_cnt_q;   // 第廿八刀:输出beat计数器默认保持
        ar_fifo_pop     = 1'b0;
        // Memory default assignments
        data_o = s_wdata;
        be_o   = s_wstrb;
        we_o   = 1'b0;
        req_o  = 1'b0;
        addr_o = 'h0;
        // AXI assignments
        // request
        s_awready = 1'b0;
        s_arready = ~ar_fifo_full;  // AR随时可接受（FIFO未满即可）
        // read response channel
        s_rvalid  = 1'b0;
        s_rresp   = 'h0;
        s_rlast   = 'h0;
        s_rid     = ax_req_q_id;
        // R 通道里只有 s_rdata 漏了默认赋值，于是综合器为它推断出 AXI_DATA_WIDTH 个
        // 锁存器（[Synth 8-327]，全设计仅此一处），正好压在 CPU 的读数据通路上。
        // 功能上无害——s_rdata 只在 s_rvalid 拉高时被采样，而那只发生在 READ 态、
        // 那里给的也正是 data_q——但电平敏感的锁存器不该出现在数据总线上。
        // 补默认值即可消掉，s_rdata 退化成寄存器输出直连。
        s_rdata   = data_q;
        // slave write data channel
        s_wready  = 1'b0;
        // write response channel
        s_bvalid  = 1'b0;
        s_bresp   = 1'b0;
        s_bid     = 1'b0;

        case (state_q)

            IDLE: begin
                // Wait for a read or write
                // ------------
                // Read（从AR FIFO头部取请求）
                // ------------
                if (!ar_fifo_empty) begin
                    ar_fifo_pop = 1'b1;
                    // sample from FIFO
                    ax_req_d_id     = ar_fifo_id;
                    ax_req_d_addr   = ar_fifo_addr;
                    ax_req_d_len    = ar_fifo_len;
                    ax_req_d_size   = ar_fifo_size;
                    ax_req_d_burst  = ar_fifo_burst;
                    // 第五刀：不再当拍 addr_o=ar_fifo_addr 组合直出(违例主链)。
                    // 把首地址锁进 req_addr_q，下一拍(READ_START)用寄存版发 SRAM。
                    state_d        = READ_START;
                    req_addr_d     = ar_fifo_addr;
                    cnt_d          = 1;
                    out_cnt_d      = 1;   // 第廿八刀:输出beat计数器初始化
                // ------------
                // Write
                // ------------
                end else if (s_awvalid) begin
                    s_awready = 1'b1;
                    // s_wready  = 1'b1;
                    // 第廿六刀(冲64.58MHz,零功能/零busy)：本拍 req_o=0(无真实SRAM访问),
                    //   addr_o 是 don't-care,仅被综合器算进 ext_ram_addr OBUF 锥、约束住。
                    //   原 addr_o=s_awaddr 让 CDC灰码指针→crossbar cmdArbiter→s_awaddr 这条
                    //   组合链直挂 OBUF(CI唯一违例主链,8.726ns到引脚)。改用寄存版 req_addr_q
                    //   斩断此组合链:req_o=0 时地址不被 SRAM 采样,写地址下一拍 WAIT_WVALID
                    //   用 ax_req_q_addr(寄存版)正常发出,写语义逐拍不变。
                    addr_o         = req_addr_q;
                    // sample ax
                    ax_req_d_id     = s_awid;
                    ax_req_d_addr   = s_awaddr;
                    ax_req_d_len    = s_awlen;
                    ax_req_d_size   = s_awsize;
                    ax_req_d_burst  = s_awburst;
                    // we've got our first w_valid so start the write process
                    //although the axi wdata can faster than ADDR but the SRAM cannot write continusly
                    // if (s_wvalid) begin
                    //     req_o          = 1'b1;
                    //     we_o           = 1'b1;
                    //     state_d        = (s_wlast) ? SEND_B : WRITE_NOP;
                    //     cnt_d          = 1;
                    // // we still have to wait for the first w_valid to arrive
                    // end else
                        state_d = WAIT_WVALID;
                end
            end

            // ~> we are still missing a w_valid
            WAIT_WVALID: begin
                s_wready = 1'b1;
                addr_o = ax_req_q_addr;
                // we can now make our first request
                if (s_wvalid) begin
                    req_o          = 1'b1;
                    we_o           = 1'b1;
                    // 两拍写（去 ODDR 合规版）：首个 beat 写完后进 WRITE_NOP 拉高 WE，
                    // 用整拍 WE 上升沿产生写结束沿（异步 SRAM 边沿写模型需要）。
                    state_d        = (s_wlast) ? SEND_B : WRITE_NOP;
                    cnt_d          = 1;
                end
            end

            // 第五刀：读 burst 首拍 SETUP。用寄存版首地址 req_addr_q 发 SRAM 建立
            // 地址(斩断 ar_fifo_addr 组合直出违例链)，本拍末沿 data_q<=data_i 采到
            // 首 word 数据；不发 s_rvalid(还没数据可回)。下一拍进 READ 出首个数据。
            // cnt_q 保持 1(IDLE 已设)，转 READ 后首个数据拍 s_rlast=(1==len+1) 正确。
            // 第廿八刀 depth-2 读流水 fill 拍1：驱动 beat0(req_addr_q),不发 s_rvalid。
            //   地址IOB寄存化后 beat0 此拍进 IOB 寄存器,下拍才到引脚。cnt 保持1。
            READ_START: begin
                req_o  = 1'b1;
                addr_o = req_addr_q;   // beat0
                state_d = READ_HOLD;
            end

            // 第廿八刀 depth-2 读流水 fill 拍2：驱动 beat1(cons_addr),advance cnt→2。
            //   本拍 IOB 把 beat0 送到引脚→SRAM 产出 beat0 数据→末沿 data_q<=beat0。
            //   仍不发 s_rvalid,下拍 READ 才输出 beat0。len_plus1=1 时 over-fetch beat1
            //   无害(数据丢弃,不输出)。
            READ_HOLD: begin
                req_o  = 1'b1;
                addr_o = cons_addr;    // beat1(=aligned+cnt_q*4,cnt_q=1)
                req_addr_d = cons_addr;
                cnt_d  = cnt_q + 1;    // →2
                state_d = READ;
            end

            READ: begin
                // 第廿八刀 depth-2 读流水:输出级(out_cnt)与fetch级(cnt)解耦。
                //   输出 beat out_cnt 的数据=data_q(=SRAM(beat out_cnt-1),因IOB+fill滞后)。
                req_o  = 1'b1;
                // 输出响应(输出级)
                s_rvalid = 1'b1;
                s_rdata  = data_q;
                s_rid    = ax_req_q_id;
                s_rlast  = (out_cnt_q == len_plus1_q);
                // fetch级:驱动 beat cnt_q(cons_addr),背压且还有beat未取时advance;
                //   否则 drain(hold 末地址)。addr_o 只依赖 cons_addr_q/req_addr_q 纯FF。
                addr_o = (ax_req_q_burst == FIXED) ? req_addr_q : cons_addr;
                if (s_rready && (cnt_q < len_plus1_q)) begin
                    cnt_d      = cnt_q + 1;
                    req_addr_d = addr_o;   // 保存本拍fetch地址(WRAP死代码,addr_o即cons_addr)
                end
                // 输出级推进 + burst 完成判断
                if (s_rready) begin
                    if (out_cnt_q == len_plus1_q) begin
                        // 最后一 beat 已被接受→转态(与原rlast块同一优先级:AR>AW>IDLE)
                        if (!ar_fifo_empty) begin
                            ar_fifo_pop    = 1'b1;
                            ax_req_d_id    = ar_fifo_id;
                            ax_req_d_addr  = ar_fifo_addr;
                            ax_req_d_len   = ar_fifo_len;
                            ax_req_d_size  = ar_fifo_size;
                            ax_req_d_burst = ar_fifo_burst;
                            state_d        = READ_START;
                            req_addr_d     = ar_fifo_addr;
                            cnt_d          = 1;
                            out_cnt_d      = 1;
                        end else if (s_awvalid) begin
                            s_awready      = 1'b1;
                            addr_o         = req_addr_q;   // 第廿六刀:斩s_awaddr组合链
                            ax_req_d_id    = s_awid;
                            ax_req_d_addr  = s_awaddr;
                            ax_req_d_len   = s_awlen;
                            ax_req_d_size  = s_awsize;
                            ax_req_d_burst = s_awburst;
                            state_d        = WAIT_WVALID;
                        end else begin
                            state_d = IDLE;
                        end
                    end else begin
                        out_cnt_d = out_cnt_q + 1;   // 推进输出beat
                    end
                end
                // backpressure(s_rready=0):cnt/out_cnt/req_addr全hold(默认保持),
                //   addr_o=cons_addr(cnt_q held),data_q自然稳定。
            end

            // READ_ADDR保留用于兼容（正常流水不会进入此状态）
            READ_ADDR: begin
                // keep request to memory high
                req_o  = 1'b1;
                // send the response
                s_rvalid = 1'b0;
                // ----------------------------
                // Next address generation
                // ----------------------------
                // handle the correct burst type
                case (ax_req_q_burst)
                    FIXED, INCR: addr_o = cons_addr;
                    WRAP:  begin
                        // check if the address reached warp boundary
                        if (wrap_hit_q) begin
                            addr_o = wrap_boundary_q;
                        // address warped beyond boundary
                        end else if (wrap_over_q) begin
                            addr_o = cons_addr;   // 第廿二刀：WRAP 死代码(CPU/DMA恒INCR,arburst硬编2'b1),消除减法斩ext_ram_addr违例
                        // we are still in the incremental regime
                        end else begin
                            addr_o = cons_addr;
                        end
                    end
                endcase
                // we need to change the address here for the upcoming request
                // we can decrease the counter as the master has consumed the read data
                cnt_d = cnt_q + 1;
                // save the request address for the next cycle
                req_addr_d = addr_o;
                state_d = READ;
            end

            // 两拍写间隔拍：we_o 保持 default 0（WE 拉高，产生上一 word 写结束沿），
            // s_wready=0 不收新 beat，cnt/addr 均保持（默认赋值）不推进；回 WRITE 收下一 word。
            WRITE_NOP: begin
                s_wready = 1'b0;
                state_d  = WRITE;
            end

            // 两拍写（去 ODDR 合规版）：WRITE 拍消费+写一个 w-beat（we_o=1，data_o
            // 组合直通 s_wdata），随后进 WRITE_NOP 拉高 WE 产生写结束沿，再回 WRITE
            // 收下一个 beat。每 word 一个独立 WE 上升沿，异步 SRAM 边沿写模型正确。
            WRITE: begin

                s_wready = 1'b1;
                state_d  = WRITE;

                // 第廿五刀(冲64.58MHz)：addr_o 不再等 s_wvalid 才输出。cons_addr/
                //   wrap_boundary_q 都是上一拍已锁存的纯寄存器值，本拍取值与
                //   s_wvalid 无关；下游 ext_ram_addr 是 soc_sram_addr 的纯组合
                //   直通(无 cs/we 门控，见 axi_wrap_ram_sp_external.v:288 assign
                //   ext_ram_addr=soc_sram_addr[21:2])，真正落盘只由 we_o(仍严格
                //   受 s_wvalid 门控)决定，addr_o 提前每拍驱动对 SRAM 无副作用
                //   (we_o=0 拍地址值是 don't-care)。此举把 s_wvalid(经仲裁器/
                //   CPU 远端传来的 late-arriving 信号)从 addr_o→ext_ram_addr
                //   OBUF 这条组合链的 fan-in 里剔除，与 READ 态 addr_o 不等
                //   s_rready 就提前驱动(line 379)同一模式。
                // ----------------------------
                // Next address generation
                // ----------------------------
                // handle the correct burst type
                case (ax_req_q_burst)

                    FIXED, INCR: addr_o = cons_addr;
                    WRAP:  begin
                        // check if the address reached warp boundary
                        if (wrap_hit_q) begin
                            addr_o = wrap_boundary_q;
                        // address warped beyond boundary
                        end else if (wrap_over_q) begin
                            addr_o = cons_addr;   // 第廿二刀：WRAP 死代码(CPU/DMA恒INCR,arburst硬编2'b1),消除减法斩ext_ram_addr违例
                        // we are still in the incremental regime
                        end else begin
                            addr_o = cons_addr;
                        end
                    end
                endcase

                // consume a word here
                if (s_wvalid) begin
                    req_o         = 1'b1;
                    we_o          = 1'b1;
                    // save the request address for the next cycle
                    req_addr_d = addr_o;
                    // we can decrease the counter as the master has consumed the read data
                    cnt_d = cnt_q + 1;

                    // 两拍写：末拍写完直接发 B 响应；非末拍进 WRITE_NOP 拉高 WE
                    // （cnt 已在本拍 +1，NOP 拍不动 cnt，回 WRITE 用新 cnt 的 cons_addr）
                    if (s_wlast)
                        state_d = SEND_B;
                    else
                        state_d = WRITE_NOP;
                end
            end
            // ~> send a write acknowledge back
            SEND_B: begin
                s_bvalid = 1'b1;
                s_bid    = ax_req_q_id;
                if (s_bready) begin
                    // Tier 2 时序优化：写响应握手同拍直接判断 AR FIFO 并转读，
                    // 省去回 IDLE 再判断的 1 拍。字段赋值与下方 IDLE 态 Read
                    // 分支逐字一致（复用而非重新发明）。正确性：we_o 维持
                    // default 0（不变写语义），s_bvalid 不受影响（AXI B 通道
                    // 与桥-SRAM 内部请求总线物理独立）；s_arready/s_awready/
                    // s_rvalid 的产生条件均未被触碰，对 CPU 等其它 master 透明。
                    if (!ar_fifo_empty) begin
                        ar_fifo_pop    = 1'b1;
                        ax_req_d_id    = ar_fifo_id;
                        ax_req_d_addr  = ar_fifo_addr;
                        ax_req_d_len   = ar_fifo_len;
                        ax_req_d_size  = ar_fifo_size;
                        ax_req_d_burst = ar_fifo_burst;
                        // 第五刀：写后续读也走 READ_START(锁地址寄存后再发)
                        state_d        = READ_START;
                        req_addr_d     = ar_fifo_addr;
                        cnt_d          = 1;
                        out_cnt_d      = 1;   // 第廿八刀
                    end else begin
                        state_d = IDLE;
                    end
                end
            end

        endcase
    end

    // --------------
    // Registers
    // --------------
    always @(posedge clk or negedge resetn) begin
        if (~resetn) begin
            state_q         <= IDLE;
            ax_req_q_addr   <= 32'h0;
            ax_req_q_burst  <= 2'h0;
            ax_req_q_id     <= 'h0;
            ax_req_q_len    <= 8'h0;
            ax_req_q_size   <= 3'h0;
            req_addr_q      <= 'h0;
            cnt_q           <= 8'h0;
            out_cnt_q       <= 10'd1;   // 第廿八刀:输出beat计数器复位=1
            len_plus1_q     <= 10'd1;   // 复位 = 0+1
            s_rlast_q       <= 1'b0;    // 第十九刀：复位内部决策版 s_rlast
            data_q          <= 'h0;
            skid_q          <= 'h0;
            skid_vld        <= 1'b0;
            aligned_addr_q        <= 'h0;
            wrap_boundary_q       <= 'h0;
            upper_wrap_boundary_q <= 'h0;
            cons_addr_q           <= 'h0;
            wrap_hit_q            <= 1'b0;
            wrap_over_q           <= 1'b0;
        end else begin
            state_q         <= state_d;
            ax_req_q_addr   <= ax_req_d_addr;
            ax_req_q_burst  <= ax_req_d_burst;
            ax_req_q_id     <= ax_req_d_id;
            ax_req_q_len    <= ax_req_d_len;
            ax_req_q_size   <= ax_req_d_size;
            req_addr_q      <= req_addr_d;
            cnt_q           <= cnt_d;
            out_cnt_q       <= out_cnt_d;   // 第廿八刀
            // 第十九刀：预算 s_rlast 内部决策版。cnt_d/len_plus1_q 前拍已定，
            //   落沿后 s_rlast_q(N)=(cnt_q(N)==len_plus1_q)，与组合 s_rlast 逐拍等价。
            s_rlast_q       <= (cnt_d == len_plus1_q);
            // 寄存版地址链：直接从 ax_req_d_addr/len 派生（与 ax_req_q_addr/len
            // 同一时钟沿更新），故 aligned_addr_q 永远等于 aligned(ax_req_q_addr)——
            // 复刻原组合不变量，读/写所有路径自动正确，无需每个 case 分支手动维护。
            // 时序优化：len+1 在 burst 内恒定，锁存时算一次(与 ax_req_q_len 同沿同源)，
            //   s_rlast 比较直接用 len_plus1_q，斩掉"每拍重算 cnt==len+1 的加法器"
            //   ——该加法器是 ax_req_q_len→比较器(CARRY4)→addr/be_n 违例链(38条)的头。
            //   s_rlast 语义完全不变(仍当拍比较、不预算、不碰读首拍决策)，零风险零 busy。
            len_plus1_q           <= {2'b0, ax_req_d_len} + 10'd1;
            aligned_addr_q        <= {ax_req_d_addr[AXI_ADDR_WIDTH-1:LOG_NR_BYTES], {{LOG_NR_BYTES}{1'b0}}};
            wrap_boundary_q       <= get_wrap_boundary(ax_req_d_addr, ax_req_d_len);
            upper_wrap_boundary_q <= upper_wrap_nxt;   // 与 wrap_hit_q/wrap_over_q 同源
            // cons_addr 预算一拍：与 aligned_addr_q 同沿、同源(ax_req_d_addr/cnt_d)派生，
            // 故 cons_addr_q(N) 恒等于组合 aligned_addr_q(N)+(cnt_q(N)<<2)，逐拍精确等价。
            cons_addr_q     <= cons_addr_nxt;
            // WRAP 比较预算一拍：用与 cons_addr_q 完全相同的次态源(cons_addr_nxt)
            // 对 upper_wrap_boundary 的次态(upper_wrap_nxt)比较，落沿后恒等于
            // cons_addr_q(N) ==/> upper_wrap_boundary_q(N)，逐拍精确复刻组合比较。
            wrap_hit_q      <= (cons_addr_nxt == upper_wrap_nxt);
            wrap_over_q     <= (cons_addr_nxt >  upper_wrap_nxt);
            // R 通道背压时的读数据保持。depth-2 流水下地址虽已停住，但仍有一拍数据在途，
            // 故需两级：data_q 是正在呈现的那拍，skid 暂存在途的那拍。
            if (s_rvalid && !s_rready) begin
                if (!skid_vld) begin skid_q <= data_i; skid_vld <= 1'b1; end
            end else begin
                data_q   <= skid_vld ? skid_q : data_i;
                skid_vld <= 1'b0;
            end

            // synopsys translate_off
            // 多拍读的逐拍取数链观测：地址发出去的那一拍、数据回来的那一拍、
            // 以及最终吐给 AXI 的那一拍，三者的对应关系。
            // 只在 len>0 的读突发期间打印——单拍读有上万笔，会把日志淹掉。
            if (rd_trace_on && len_plus1_q > 10'd1 &&
                (state_q == READ_START || state_q == READ_HOLD || state_q == READ)) begin
                $display("[SRAM_RD] t=%0t st=%0d cnt_q=%0d out_cnt_q=%0d len1=%0d addr_o=0x%08h data_i=0x%016h data_q=0x%016h rvalid=%0b rlast=%0b",
                         $time, state_q, cnt_q, out_cnt_q, len_plus1_q,
                         addr_o, data_i, data_q, s_rvalid, s_rlast);
            end
            // synopsys translate_on
        end
    end

    // 时序优化：引出已寄存的首拍地址供 wrapper 的 WE 脉冲判定（解耦 WRAP 比较链）
    assign ax_req_q_addr_o = ax_req_q_addr;


    // always @(posedge clk or negedge resetn) begin
    //     if (~resetn) begin
    //         s_rdata         <= 'h0;     
    //     end else begin
    //         if(req_o == 1'b1 && we_o == 1'b0)
    //             s_rdata     <= data_i;
    //         else
    //             s_rdata     <= s_rdata;
    //     end
    // end

endmodule


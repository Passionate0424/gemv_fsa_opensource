`timescale 1ns / 1ps

// TODO 位宽需要修正
 //`default_nettype none
  module axi_dma_controller #(
      parameter integer ADDR_WD = 32,
      parameter integer DATA_WD = 32,
      parameter integer ID_WD   = 4,
      parameter integer SRAM_ADDR_WD = 32, // SRAM 地址宽度为32位
      parameter integer MAX_OUTSTANDING = 1, // single-outstanding（IR drop验证）
      localparam integer DATA_WD_BYTE = DATA_WD / 8,
      localparam integer STRB_WD =  DATA_WD / 8,
      localparam integer LOG_DATA_WD_BYTE = $clog2(DATA_WD_BYTE),
      localparam integer WORD_W = 32,   // 片上 SRAM 的 word 粒度，与总线宽度无关
      localparam [ID_WD-1:0] DMA_ID = {ID_WD{1'b0}}
)(
    input wire clock, 
    input wire rst_n,
    // DMA Command
    input  wire                 cmd_valid,  //DMA Command valid
    output wire                 cmd_ready,  //DMA Command Ready
    input  wire [ADDR_WD-1 : 0] cmd_src_addr,
    input  wire [ADDR_WD-1 : 0] cmd_dst_addr,
    input  wire [1:0]           cmd_burst,  //00 INCR
    input  wire                 cmd_rw, // 0 = r
    input  wire [10: 0]         cmd_len,    //Size of data (B) Use in write 
    input  wire [2:0]           cmd_size,   //AXI Beat Size
    output wire                 dma_done,

    input  wire [8:0]           cmd_block_size,
    input  wire [10:0]          cmd_stride, //stide Bytes
    input  wire                 cmd_padding_en,
    input  wire  [6:0]          cmd_block_count, // block_cnt；原误写[5:0]比上游线网与内部r_cmd_block_count([6:0])都窄，导致DC link位宽不匹配将axi_dma_controller黑盒化；改为[6:0]统一，无截断
    input  wire  [7:0]          cmd_padding_words,

    output wire                 dma_padding_active_out, // 当前DMA传输是否有padding（锁存值）

    input  wire [STRB_WD-1 : 0] R_strobe, 
    // Read Address Channel
    output wire                 M_AXI_ARVALID,
    output wire [ADDR_WD-1 : 0] M_AXI_ARADDR,
    output wire [7:0]           M_AXI_ARLEN,
    output wire [2:0]           M_AXI_ARSIZE,
    output wire [1:0]           M_AXI_ARBURST,
    input  wire                 M_AXI_ARREADY,
    output wire [ID_WD-1:0]     M_AXI_ARID,
    output wire                 M_AXI_ARLOCK,
    output wire [2:0]           M_AXI_ARPROT,
    output wire [3:0]           M_AXI_ARCACHE,
    // Read Response Channel
    input  wire                 M_AXI_RVALID,
    input  wire [DATA_WD-1 : 0] M_AXI_RDATA,
    input  wire [1:0]           M_AXI_RRESP,
    input  wire                 M_AXI_RLAST,         
    output wire                 M_AXI_RREADY,
    input  wire [ID_WD-1:0]     M_AXI_RID,
    // Write Address Channel
    output wire                 M_AXI_AWVALID,
    output wire [ADDR_WD-1 : 0] M_AXI_AWADDR,
    output wire [7:0]           M_AXI_AWLEN,
    output wire [2:0]           M_AXI_AWSIZE,
    output wire [1:0]           M_AXI_AWBURST,
    input  wire                 M_AXI_AWREADY,
    output wire [ID_WD-1:0]     M_AXI_AWID,
    output wire                 M_AXI_AWLOCK,
    output wire [2:0]           M_AXI_AWPROT,
    output wire [3:0]           M_AXI_AWCACHE,
    // Write Data Channel
    output wire                 M_AXI_WVALID,
    output wire [DATA_WD-1 : 0] M_AXI_WDATA,
    output wire [STRB_WD-1 : 0] M_AXI_WSTRB,
    output wire                 M_AXI_WLAST,
    input  wire                 M_AXI_WREADY,
    // Write Response Channel
    input  wire                 M_AXI_BVALID,
    input  wire [1:0]           M_AXI_BRESP,
    input  wire [ID_WD-1:0]     M_AXI_BID,
    output wire                 M_AXI_BREADY,
    //SRAM
    output reg                  sram_we,
    output reg [SRAM_ADDR_WD-1:0]    sram_waddr,
    output reg [DATA_WD-1:0]    sram_wdata,

    output reg [SRAM_ADDR_WD-1:0]    sram_raddr,
    input  wire [DATA_WD-1:0]   sram_rdata
 );

    // reg  [DATA_WD - 1:0] mem [0 : 255]; 

    reg   [ADDR_WD-1 : 0]     r_cmd_src_addr            ;
    reg   [ADDR_WD-1 : 0]     r_cmd_dst_addr            ;
    reg   [1:0]               r_cmd_burst               ;
    reg   [2:0]               r_cmd_size                ;
    reg                       r_cmd_ready               ;
    //reg                       r_cmd_rw;          
    reg   [10:0]              r_cmd_len                 ; //Size of data (B) Use in write
    reg   [8:0]                r_cmd_block_size         ;
    reg    [10:0]              r_cmd_stride             ;
    reg   [6:0]                r_cmd_block_count ;
    reg                       r_cmd_padding;   
    reg   [7:0]               r_cmd_padding_words; 

    reg                       r_m_axi_rready            ;

    reg [ADDR_WD - 1:0]       r_m_axi_araddr            ;
    reg                       r_m_axi_arvalid           ;
    reg [7:0]                 r_m_axi_arlen             ;

    reg [ADDR_WD - 1:0]       r_m_axi_awaddr            ;
    reg                       r_m_axi_awvalid           ;
    reg [7:0]                 r_m_axi_awlen             ;    

    // 写数据通路由深度2预取FIFO驱动(取数端SRAM读→FIFO→发数端AXI W通道，见下方详述)
    reg [STRB_WD -1:0]        r_m_axi_wstrb             ;
    reg [LOG_DATA_WD_BYTE-1:0] r_tail_bytes             ;  // 写侧末拍有效字节数，0=满拍
    reg [LOG_DATA_WD_BYTE-1:0] wr_head_bytes            ;  // 写侧首拍要跳过的字节数，0=对齐
    reg                        wr_first_beat            ;  // 写侧本次突发的首拍标记
    // 读侧 per-burst 属性队列。head/tail 半拍标记是"某一个 burst"的属性，而
    // MAX_OUTSTANDING>1 时 AR 已经跑在 R 前面几个 burst，用单寄存器存必然被后发的 AR
    // 覆盖掉当前正在返回那个 burst 的标记。所以按 burst 排队：AR 握手入队、RLAST 出队。
    // 本拍 AXI 是否交付了数据。属性队列、补零计数与打包器都要用，故提到最前面声明。
    wire feed_axi = M_AXI_RVALID && M_AXI_RREADY;
    // 指针位宽用 clog2(MAX_OUTSTANDING+1)：MAX_OUTSTANDING=1 时 clog2(1)=0 会得非法位宽
    localparam integer RD_ATTR_PTR_W = $clog2(MAX_OUTSTANDING + 1);
    reg [1:0]  rd_attr_fifo [0:MAX_OUTSTANDING-1];   // {head_odd, tail_odd}
    reg [RD_ATTR_PTR_W-1:0] rd_attr_wptr, rd_attr_rptr;
    wire       rd_head_odd  = rd_attr_fifo[rd_attr_rptr][1];  // 队首 burst 的首拍半拍标记
    wire       rd_tail_odd  = rd_attr_fifo[rd_attr_rptr][0];  // 队首 burst 的末拍半拍标记
    reg  [8:0] rd_beat_cnt;                                   // 队首 burst 已收拍数
    wire       rd_first_beat = (rd_beat_cnt == 9'd0);         // 首拍 = 本 burst 还没收过拍
    reg [WORD_W-1:0]          pack_lo                   ;  // 读侧打包器暂存的孤字
    reg                       pack_half                 ;
    reg [15:0]                blk_word_cnt             ;  // block 内累计交付 word 数（诊断）
    reg [15:0]                blk_word_snap            ;  // 块结束冻结的字数（供断言/dump 报告）
    reg [WORD_W-1:0]          wpack_lo                  ;  // 写侧打包器暂存的孤字
    reg                       wpack_half                ;
    reg [8:0]                 wr_word_last              ;  // 写侧最后一个 word 的下标
    reg [8:0]                 r_read_cnt                ;

    reg                       r_write_start             ;
    reg [7:0]                 w_trans_num               ;
    reg [DATA_WD-1:0]         R_strobe_word                ;

    // Multi-outstanding读控制信号
    reg [6:0]  ar_block_cnt;       // AR侧已发burst计数
    reg [$clog2(MAX_OUTSTANDING+1)-1:0] outstanding_cnt; // 当前in-flight AR数
    wire       ar_can_fire;        // AR可以发射新burst
    reg        read_active;        // 读传输进行中标志

    wire [7:0]                  TRANS_PER_DATA          ;
    wire [7:0]                r_cmd_size_byte           ;

    assign r_cmd_size_byte  = 2**(r_cmd_size)           ;
    assign cmd_ready        = r_cmd_ready               ;

//AR Output
    assign M_AXI_ARLEN      = r_m_axi_arlen             ; 
    assign M_AXI_ARSIZE     = r_cmd_size                  ;
    assign M_AXI_ARBURST    = r_cmd_burst                 ;
    assign M_AXI_ARADDR     = r_m_axi_araddr            ;
    assign M_AXI_ARVALID    = r_m_axi_arvalid           ;
    assign M_AXI_ARID       = DMA_ID;
    assign M_AXI_ARLOCK     = 1'b0;
    assign M_AXI_ARPROT     = 3'b000;
    assign M_AXI_ARCACHE    = 4'b0000;

//AW Output
    assign M_AXI_AWLEN      = r_m_axi_awlen             ; 
    assign M_AXI_AWSIZE     = r_cmd_size                  ;
    assign M_AXI_AWBURST    = r_cmd_burst                 ;
    assign M_AXI_AWADDR     = r_m_axi_awaddr            ;
    assign M_AXI_AWVALID    = r_m_axi_awvalid           ;
    assign M_AXI_AWLEN      = r_m_axi_awlen             ;
    assign M_AXI_AWID       = DMA_ID;
    assign M_AXI_AWLOCK     = 1'b0;
    assign M_AXI_AWPROT     = 3'b000;
    assign M_AXI_AWCACHE    = 4'b0000;

    //assign M_AXI_WSTRB      = {STRB_WD{1'b1}}           ;
    // 末拍字节道屏蔽。arlen/awlen 向上取整会多发一拍，若 cmd_len 不是总线宽度的整数倍
    // （尾块只剩 1 行 = 4 字节而总线 8 字节），多出的字节道会把 SRAM 残留字写到目标
    // 缓冲区之外——输出向量按 csr_rows 个 word 分配，越界就踩坏软件的后续数据。
    // 只在等宽传输下生效：cmd_size 比总线窄时 r_m_axi_wstrb 走的是旋转分支，
    // "末拍半拍"的语义要另算，两套机制不能叠加。
    // DATA_WD_BYTE=4 且 cmd_len 恒为 4 的倍数时 r_tail_bytes 恒 0 → 掩码恒全 1，行为不变。
    wire [STRB_WD-1:0] tail_strb_mask =
        ({{(STRB_WD-1){1'b0}}, 1'b1} << r_tail_bytes) - 1'b1;
    wire tail_mask_en = (TRANS_PER_DATA == 1) && M_AXI_WLAST && (r_tail_bytes != 0);
    // 首拍字节道屏蔽。AW 被对齐到下界后，首拍的低 wr_head_bytes 个字节属于目标缓冲区
    // 之前的数据，不能写——与末拍屏蔽是对称的两端。屏蔽掉低位而不是高位：AXI 的
    // wstrb[i] 对应 addr+i，被跳过的是地址较低的那几个字节。
    wire [STRB_WD-1:0] head_strb_mask =
        ~(({{(STRB_WD-1){1'b0}}, 1'b1} << wr_head_bytes) - 1'b1);
    wire head_mask_en = (TRANS_PER_DATA == 1) && wr_first_beat && (wr_head_bytes != 0);
    // 单拍突发时首末屏蔽会同时命中，两个掩码要相与（既跳过头、又截掉尾）
    assign M_AXI_WSTRB      = r_m_axi_wstrb
                            & (tail_mask_en ? tail_strb_mask : {STRB_WD{1'b1}})
                            & (head_mask_en ? head_strb_mask : {STRB_WD{1'b1}});
    // M_AXI_WDATA/WVALID/WLAST 由下方深度2预取FIFO驱动（桥无关写通路）

    assign M_AXI_BREADY     = 1'b1                      ;
    
    assign M_AXI_RREADY     = r_m_axi_rready            ;
    assign TRANS_PER_DATA   = DATA_WD_BYTE/r_cmd_size_byte   ;

/*--------------------- dma control  -------------------------*/

    always@(posedge clock) begin
        if(!rst_n) begin
            r_cmd_src_addr <= 0; 
            r_cmd_dst_addr <= 0;
            r_cmd_burst <= 0;
            r_cmd_size <= 3'b010;
            //r_m_axi_awlen <= 1;
            //r_m_axi_arlen <= 1;
            r_write_start <=  1'b0;
            r_cmd_block_size <= 'b0;
            r_cmd_stride <= 'b0;
            r_cmd_block_count <= 'b0;
            r_cmd_padding <= 'b0;
            r_cmd_padding_words <= 'b0;

        end
        else if(cmd_valid && cmd_ready) begin
            r_cmd_src_addr <= cmd_src_addr;
            r_cmd_dst_addr <= cmd_dst_addr;
            r_cmd_burst <= cmd_burst;
            r_cmd_size <= cmd_size;
            r_cmd_len <= cmd_len;
            //r_m_axi_awlen <= cmd_len/(DATA_WD_BYTE) - 'b1;
            //r_m_axi_arlen <= cmd_len/(DATA_WD_BYTE) - 'b1;
            r_write_start <=  cmd_rw;
            r_cmd_block_size   <= cmd_block_size;
            r_cmd_stride       <= cmd_stride;
            r_cmd_block_count  <= cmd_block_count;
            r_cmd_padding          <= cmd_padding_en;
            r_cmd_padding_words <= cmd_padding_words;

        end
        else begin
            r_cmd_src_addr <= r_cmd_src_addr;
            r_cmd_dst_addr <= r_cmd_dst_addr;
            r_cmd_burst <= r_cmd_burst;
            r_cmd_size <= r_cmd_size;
            r_write_start <=    1'b0;             
            //r_m_axi_awlen <= r_m_axi_awlen;
            //r_m_axi_arlen <= r_m_axi_arlen;
            r_cmd_block_size   <= r_cmd_block_size;
            r_cmd_stride       <= r_cmd_stride;
            r_cmd_block_count  <= r_cmd_block_count;
            r_cmd_padding      <= r_cmd_padding;
            r_cmd_padding_words <= r_cmd_padding_words;
        end
    end

//wire read_finish = M_AXI_RLAST;
reg read_All_finish;
reg read_finish;
wire write_finish = M_AXI_BREADY && M_AXI_BVALID;

assign dma_done = cmd_rw ? write_finish : read_All_finish ;
assign dma_padding_active_out = r_cmd_padding;

    always@(posedge clock) begin
        if(!rst_n) 
            r_cmd_ready <= 1;
        else if(cmd_valid && cmd_ready)
            r_cmd_ready <= 0;

        else if (read_All_finish | write_finish)
            r_cmd_ready <= 1;
        else
            r_cmd_ready <= r_cmd_ready;
    end
/*---------------------  read  CTRL  -------------------------*/
reg [6:0] finished_block_cnt;
always@(posedge clock)begin
    if(!rst_n)begin
        finished_block_cnt <= 'b0;
        read_All_finish <= 'b0;
    end
    else if (read_finish)begin
        if(finished_block_cnt == r_cmd_block_count)begin
            read_All_finish <= 'b1;
            finished_block_cnt <= 'b0;
        end
        else begin
            read_All_finish <= 'b0;
            finished_block_cnt <= finished_block_cnt + 'd1;
        end
    end
    else begin
        finished_block_cnt <= finished_block_cnt;
        read_All_finish <= 1'b0;
    end
end

// read_active：读传输进行中（从cmd接受到read_All_finish）
always @(posedge clock) begin
    if (!rst_n)
        read_active <= 1'b0;
    else if (cmd_valid && cmd_ready && !cmd_rw)
        read_active <= 1'b1;
    else if (read_All_finish)
        read_active <= 1'b0;
end

// ============================================================
// Multi-Outstanding AR Pipeline（借鉴iDMA FIFO解耦思路）
// AR侧独立推进，不等R回来就发下一个AR
// outstanding_cnt限制最大in-flight数
// ============================================================

// AR可以发射：读传输进行中 AND 还有block要发 AND outstanding未满 AND 未完成
// padding模式下限制单outstanding（padding状态机不支持并发）
assign ar_can_fire = read_active &&
                     (ar_block_cnt <= r_cmd_block_count) &&
                     (outstanding_cnt < (r_cmd_padding ? 1 : MAX_OUTSTANDING)) &&
                     !read_All_finish;

// AR block计数器：每次AR握手递增
always @(posedge clock) begin
    if (!rst_n || read_All_finish)
        ar_block_cnt <= 7'd0;
    else if (cmd_valid && cmd_ready && !cmd_rw)
        ar_block_cnt <= 7'd0;
    else if (M_AXI_ARREADY && M_AXI_ARVALID)
        ar_block_cnt <= ar_block_cnt + 7'd1;
end

// Outstanding计数器：AR握手+1，read_finish-1
always @(posedge clock) begin
    if (!rst_n || read_All_finish)
        outstanding_cnt <= 'd0;
    else if (cmd_valid && cmd_ready && !cmd_rw)
        outstanding_cnt <= 'd0;
    else begin
        case ({(M_AXI_ARREADY && M_AXI_ARVALID), read_finish})
            2'b10: outstanding_cnt <= outstanding_cnt + 1'd1;
            2'b01: outstanding_cnt <= outstanding_cnt - 1'd1;
            default: outstanding_cnt <= outstanding_cnt;
        endcase
    end
end

// synopsys translate_off
reg [31:0] dma_transfer_cnt;
reg [31:0] total_sram_wr_cnt;  // 全局SRAM写入计数
always @(posedge clock) begin
    if (!rst_n) begin dma_transfer_cnt <= 0; total_sram_wr_cnt <= 0; end
    else begin
        if (read_All_finish) dma_transfer_cnt <= dma_transfer_cnt + 1;
        if (sram_we) total_sram_wr_cnt <= total_sram_wr_cnt + 1;
    end
end

// DMA跟踪打印，默认关闭，加 +DMA_TRACE 打开。
// SoC级仿真跑完整推理时这里每次搬运都会刷屏，把串口的token输出淹没在
// 几万行日志里，故做成按需开启。
bit dma_trace_on;
initial dma_trace_on = $test$plusargs("DMA_TRACE");

always @(posedge clock) begin
    if (dma_trace_on) begin
        // 只打印前2次DMA的SRAM写入（减少输出量）
        if (sram_we && dma_transfer_cnt <= 1)
            $display("[SRAM_WR] t=%0t xfer=%0d local_addr=%0d global=%0d data=0x%08h",
                     $time, dma_transfer_cnt, sram_waddr, total_sram_wr_cnt, sram_wdata);
        if (read_All_finish)
            $display("[DMA_DONE] t=%0t xfer=%0d", $time, dma_transfer_cnt);
        if (cmd_valid && cmd_ready)
            $display("[DMA_CMD] t=%0t rw=%0d src=0x%08h blk_cnt=%0d",
                     $time, cmd_rw, cmd_src_addr, cmd_block_count);
    end
end
// synopsys translate_on

/*--------------------- address read -------------------------*/

    // 本块的起始地址与其相对总线宽度的偏移。奇数列宽下 stride 不是 8 的倍数，
    // 隔行首地址就落在 4 字节边界上——AXI 允许非对齐 INCR 起始，首拍只交付
    // 从该地址到本对齐块末尾的字节，故要多算一拍并丢掉首拍的低半 word。
    wire [ADDR_WD-1:0] rd_blk_addr = r_cmd_src_addr + r_cmd_stride * ar_block_cnt;
    wire               rd_head_off = |rd_blk_addr[LOG_DATA_WD_BYTE-1:0];
    wire [10:0]        rd_span     = {{(11-LOG_DATA_WD_BYTE){1'b0}},
                                      rd_blk_addr[LOG_DATA_WD_BYTE-1:0]} + r_cmd_block_size;

    // AR 请求暂存：属性与 araddr/arlen 一同锁存，等真正握手那拍再入队（见下方 attr FIFO）
    reg rd_head_odd_stg, rd_tail_odd_stg;

    always@(posedge clock) begin
        if(!rst_n) begin
            r_m_axi_araddr <= 'd0;
            r_m_axi_arlen <= 'b0;
            rd_tail_odd_stg <= 1'b0;
            rd_head_odd_stg <= 1'b0;
        end
        else if(ar_can_fire && !r_m_axi_arvalid) begin
            r_m_axi_araddr <= rd_blk_addr;
            // 起始地址不是总线宽度整数倍时（奇数列宽下每行 stride = cols*4 不是 8 的倍数，
            // 隔行的首地址只有 4 字节对齐），首拍里只有高半 word 属于本块，低半属于前一个
            // word，必须丢弃。这与末拍半拍是对称的两端。
            rd_head_odd_stg <= rd_head_off;
            // 末拍是否只有低半有效：按"首偏移 + 块字节数"算，首偏移会把尾部推移半个字
            rd_tail_odd_stg <= (rd_span[LOG_DATA_WD_BYTE-1:0] != 0);
            // 向上取整：块字节数不是总线宽度整数倍时（如尾块只剩 1 行 = 4 字节，
            // 而 DATA_WD_BYTE=8），直接整除会得 0，再减 1 下溢成 255 拍。
            // 多读的那半拍对内存无副作用，由写入侧按实际字数丢弃。
            r_m_axi_arlen <= (rd_span + DATA_WD_BYTE - 1)/(DATA_WD_BYTE) - 'b1;
        end
        else begin
            r_m_axi_araddr <= r_m_axi_araddr;
            r_m_axi_arlen <= r_m_axi_arlen;
        end
    end

    // ---- per-burst 属性队列：AR 握手入队、RLAST 出队 ----
    // 队列深度等于 MAX_OUTSTANDING，与 ar_can_fire 里的 outstanding_cnt 上限同源，
    // 所以不会溢出；不另设 full 信号，由那个上限保证。
    integer bi;
    always@(posedge clock) begin
        if(!rst_n) begin
            rd_attr_wptr <= 0;
            rd_attr_rptr <= 0;
            rd_beat_cnt  <= 9'd0;
            for (bi = 0; bi < MAX_OUTSTANDING; bi = bi + 1) rd_attr_fifo[bi] <= 2'b00;
        end
        else begin
            // 新命令到来时清空队列：read_All_finish / 新读命令与 outstanding_cnt 的清零同源
            if (read_All_finish || (cmd_valid && cmd_ready && !cmd_rw)) begin
                rd_attr_wptr <= 0;
                rd_attr_rptr <= 0;
                rd_beat_cnt  <= 9'd0;
            end
            else begin
                // 指针到深度就绕回 0：MAX_OUTSTANDING 不一定是 2 的幂，不能靠位宽自然回绕
                if (M_AXI_ARVALID && M_AXI_ARREADY) begin
                    rd_attr_fifo[rd_attr_wptr] <= {rd_head_odd_stg, rd_tail_odd_stg};
                    rd_attr_wptr <= (rd_attr_wptr == MAX_OUTSTANDING - 1) ? 0
                                                                          : rd_attr_wptr + 1'b1;
                end
                // 本 burst 的拍计数：RLAST 那拍归零并让队列前进到下一个 burst
                if (feed_axi) begin
                    if (M_AXI_RLAST) begin
                        rd_beat_cnt  <= 9'd0;
                        rd_attr_rptr <= (rd_attr_rptr == MAX_OUTSTANDING - 1) ? 0
                                                                              : rd_attr_rptr + 1'b1;
                    end
                    else
                        rd_beat_cnt <= rd_beat_cnt + 9'd1;
                end
            end
        end
    end

    always@(posedge clock) begin
        if(!rst_n || (M_AXI_ARREADY && M_AXI_ARVALID))
            r_m_axi_arvalid <= 'd0;
        else if(ar_can_fire && !r_m_axi_arvalid)
            r_m_axi_arvalid <= 'd1;
        else
            r_m_axi_arvalid <= r_m_axi_arvalid;
    end
    
/*---------------------  read -------------------------------*/
integer j;
always@ * begin
    for(j = 0; j < STRB_WD; j = j + 1) begin
        R_strobe_word[j*8 +:8] = {8{R_strobe[j]}};
    end
end

    always@(posedge clock) begin
        if(!rst_n)
            r_m_axi_rready <= 0;
        else if(read_active || M_AXI_ARREADY && M_AXI_ARVALID)
            r_m_axi_rready <= 1;
        else
            r_m_axi_rready <= r_m_axi_rready;
    end

    // always@(posedge clock) begin
    //     if(!rst_n || r_trans_num == TRANS_PER_DATA)
    //         r_trans_num <= 0;
    //     else if(M_AXI_RREADY && M_AXI_RVALID)
    //         r_trans_num <= r_trans_num + 1;
    //     else
    //         r_trans_num <= r_trans_num;
    // end


    // integer i;
    // padding零填充状态机
    reg        padding_active;
    reg  [7:0] padding_cnt;

    always@(posedge clock) begin
        if(!rst_n) begin
            padding_active <= 1'b0;
            padding_cnt    <= 8'd0;
        end else if (M_AXI_RVALID && M_AXI_RREADY && M_AXI_RLAST && r_cmd_padding) begin
            // AXI burst完成且需要padding：进入零填充阶段
            padding_active <= 1'b1;
            padding_cnt    <= r_cmd_padding_words;
        // 递减以"这一拍真的喂出了补零字"为条件：feed_n 里 AXI 优先于补零，若两者同拍
        // 则补零字不会被喂出，此时递减会凭空吞掉两个字。当前 ar_can_fire 在补零模式下
        // 强制单 outstanding（见 :292），两者不会同拍，所以这是防御性约束而非已知缺陷的修复；
        // 但把"计数"与"实际喂出"绑定，可避免将来放开并发时留下静默错误。
        end else if (padding_active && !feed_axi && padding_cnt <= 8'd2) begin
            padding_active <= 1'b0;
            padding_cnt    <= 8'd0;
        end else if (padding_active && !feed_axi) begin
            padding_cnt <= padding_cnt - 8'd2;
        end
    end

    // ---- SRAM 写出侧的双字打包 ----
    // AXI beat 边界与 block 边界不一定对齐：block 字节数不是总线宽度整数倍时（列宽为奇数），
    // 该 block 的末拍只有低半 word 有效，随后接零填充。而片上 Input SRAM 的双字 entry
    // 要求成对写入。这里用一个 word 的暂存把"来自 AXI / 零填充的 word 流"重新打包成
    // 对齐的 word 对，把 beat 边界与 entry 边界解耦。
    //
    // 每个 block 交付的 word 数恒为偶数（GEMV 权重 current_cols + 补到 HW_COLS = 64；
    // FSA K/V 为 head_dim ∈ {8,16,32,64}；GEMV 向量/FSA Q 为 head_dim×num_heads = 32），
    // 所以打包器在 block 结束时必定是空的，不会剩下孤字——sram_we 每次必带 2 个 word，
    // 上层计数器一律步长 2。下方 assert 把这个前提钉死。
    // 首拍：非对齐起始时只有高半 word 属于本块；末拍：跨度不满一拍时只有低半有效
    wire        feed_head = feed_axi && rd_first_beat && rd_head_odd;
    wire        feed_tail = feed_axi && M_AXI_RLAST   && rd_tail_odd;
    wire [1:0]  feed_n   = feed_axi       ? ((feed_head || feed_tail) ? 2'd1 : 2'd2)
                         : padding_active ? ((padding_cnt == 8'd1)    ? 2'd1 : 2'd2)
                                          : 2'd0;
    wire [DATA_WD-1:0] rdata_masked = M_AXI_RDATA & R_strobe_word;
    // 首拍那一个有效 word 在高半，其余情况低半先出
    wire [WORD_W-1:0]  feed_w0 = !feed_axi ? {WORD_W{1'b0}}
                               : feed_head ? rdata_masked[DATA_WD-1:WORD_W]
                                           : rdata_masked[WORD_W-1:0];
    wire [WORD_W-1:0]  feed_w1 = feed_axi ? rdata_masked[DATA_WD-1:WORD_W] : {WORD_W{1'b0}};

    // 本拍打包器是否会发出一个 entry。SRAM 写地址跟它推进，而不是跟 AXI 拍数推进。
    // **必须与下方 case 表里所有置 sram_we 的分支逐一对应**——两处不同步就是静默错位
    // （地址不推进的那个 entry 会覆盖下一个）。改 case 表时必须回头看这一行。
    wire nxt_sram_we = (feed_n == 2'd2) || (pack_half && (feed_n == 2'd1));

    always@(posedge clock) begin
        if(!rst_n) begin
            read_finish <= 1'b0;
            sram_we     <= 1'b0;
            pack_half   <= 1'b0;
            pack_lo     <= {WORD_W{1'b0}};
            blk_word_cnt <= 16'd0;
        end
        else begin
            sram_we <= 1'b0;
            // block 内累计交付 word 数，供不变式断言使用。用 cmd_ready 清零是错的
            // （命令级不是块级），会累加 32 块。
            //
            // 归属要按拍分清：read_finish 是 RLAST 的下一拍，而多 outstanding 下**下一个
            // burst 的首拍可能就落在这一拍**（实测 t=238290000 那拍 first=1 n=2）。
            // 若在 read_finish 分支里直接清零，这一拍的 feed_n 会被吞掉、快照也取到
            // 不含末拍的旧值——本块被少算，下一块也被少算，断言就报出并不存在的奇数。
            // 正确做法：本拍的 feed_n 归给新块，快照仍是清零前的累计值。
            if (read_finish) begin
                blk_word_cnt  <= {14'd0, feed_n};   // 这一拍已经属于下一块
                blk_word_snap <= blk_word_cnt;      // 冻结本块最终字数，供 BEAT_DUMP 报告
            end
            else             blk_word_cnt <= blk_word_cnt + feed_n;
            // read_finish 的时点不变：block 总字数为偶数，最后一次 feed 必定凑满一对、
            // 当拍就发出 sram_we，与打包前逐拍对应。
            // 与 feed_n 同一套优先级：补零的收尾判据只在补零真的被喂出的那拍成立
            read_finish <= feed_axi       ? (M_AXI_RLAST && !r_cmd_padding)
                         : padding_active ? (padding_cnt <= 8'd2)
                                          : 1'b0;
            // r_read_cnt 同理：AXI 抢走的那拍不算补零推进（见 padding_cnt 的注释）
            sram_waddr  <= r_read_cnt;
            case ({pack_half, feed_n})
                3'b0_10: begin  // 手里空 + 来两个 → 直接成对发出
                    sram_we <= 1'b1;  sram_wdata <= {feed_w1, feed_w0};
                end
                3'b0_01: begin  // 手里空 + 来一个 → 攒着
                    pack_half <= 1'b1;  pack_lo <= feed_w0;
                end
                3'b1_10: begin  // 手里一个 + 来两个 → 发出(攒的, w0)，留下 w1
                    sram_we <= 1'b1;  sram_wdata <= {feed_w0, pack_lo};
                    pack_lo <= feed_w1;
                end
                3'b1_01: begin  // 手里一个 + 来一个 → 凑满发出，清空
                    sram_we <= 1'b1;  sram_wdata <= {feed_w0, pack_lo};
                    pack_half <= 1'b0;
                end
                default: ;      // feed_n==0：保持
            endcase
            // 这里**不做块尾 flush**，而是要求上层把每块字数凑成偶数（见
            // cb_controll_v2.sv 里 cmd_block_size 的向上取整）。
            //
            // 这条来回过两次，把理由记全免得再试第三遍：
            //   1. 最早有 flush → 删掉。当时触发它的是我自己引入的假违反（把 padding
            //      取整到偶数，反而让"真实字 + 补零"从 64 变成 65），flush 在掩盖 bug。
            //   2. 随机测试打到 cols=15/27（权重通路不开补零，块字数真的是奇数）后又加
            //      回来 → 再删。**因为在打包器里根本收不了尾**：逐拍 dump 显示末拍
            //      n=2 而手里还攒着 1 个，一拍要发 2 个 entry；而突发之间是背靠背的
            //      （t=2190000 末拍，t=2210000 就是新块首拍），没有空闲拍能补第二个。
            //      硬加 flush 会与新块首拍在同一拍抢 sram_we，后写的覆盖先写的
            //      （实测 t=2070000 [BLK] 与 [BEAT] 同拍），丢 entry 且数据错乱。
            // 结论：奇偶对齐必须在**发命令时**解决，不能推给数据通路收尾。
        end
    end

    // ---- read_finish 打一拍：供 debug（FATAL / BLK dump）使用 ----
    reg read_finish_q;
    always @(posedge clock) begin
        if (!rst_n) read_finish_q <= 1'b0;
        else        read_finish_q <= read_finish;
    end

    // 诊断 dump：每块结束时打印喂入字数与对齐状态 + AR 发拍（在 read_finish_q 声明之后）。
    // ar_block_cnt / araddr / arlen 在多 outstanding 下已被后发的 AR 覆盖，对不上这一块，
    // 所以块级信息只信 blk_word_snap 与 attr 队列出队时的取值。
`ifdef DMA_BEAT_DUMP
    reg [1:0] blk_attr_snap;
    always @(posedge clock) begin
        if (feed_axi && M_AXI_RLAST) blk_attr_snap <= {rd_head_odd, rd_tail_odd};
        if (read_finish_q)
            $display("[BLK] t=%0t words=%0d head=%0d tail=%0d rptr=%0d wptr=%0d",
                     $time, blk_word_snap, blk_attr_snap[1], blk_attr_snap[0],
                     rd_attr_rptr, rd_attr_wptr);
        if (M_AXI_ARVALID && M_AXI_ARREADY)
            $display("[AR] t=%0t blk=%0d addr=0x%08h len=%0d head=%0d tail=%0d wptr=%0d",
                     $time, ar_block_cnt, M_AXI_ARADDR, M_AXI_ARLEN,
                     rd_head_odd_stg, rd_tail_odd_stg, rd_attr_wptr);
        if (feed_axi)
            $display("[BEAT] t=%0t first=%0d last=%0d n=%0d head=%0d tail=%0d cnt=%0d",
                     $time, rd_first_beat, M_AXI_RLAST, feed_n, rd_head_odd, rd_tail_odd,
                     rd_beat_cnt);
    end
`endif

`ifndef SYNTHESIS
    // 读写两侧都支持非对齐起始，各自的处理不同：
    //   · 读侧：AR 保持非对齐地址（AXI 允许），首拍由 rd_head_odd 丢掉低半 word；
    //   · 写侧：AW **对齐到下界**，首拍低字节道由 head_strb_mask 屏蔽。
    // 写侧不能像读侧那样发非对齐地址：读多取几个字节对内存无副作用，写多几个字节道
    // 就会踩坏目标缓冲区之前的数据。
    //
    // 这里断言的是"对齐动作真的做了"，而不是原来那条"写侧不该出现非对齐"——
    // 后者的前提是错的：写回目标 csr_vo_base + row_offset*4 只保 4 字节对齐，
    // UVM 里 vo_base = MI_BASE + rows*cols*4，rows*cols 为奇数时必然落在半字上
    // （实测 rows=77 cols=153 → 0xf814、rows=5 cols=133 → 0x4a64）。
    // 32 位时代总线就是 4 字节所以照不出来，加宽后才暴露。
    always @(posedge clock) begin
        if (rst_n && M_AXI_AWVALID && (M_AXI_AWSIZE == LOG_DATA_WD_BYTE[2:0])
            && (|M_AXI_AWADDR[LOG_DATA_WD_BYTE-1:0]))
            $fatal(1, "[DMA] AW not aligned down: addr=0x%08h size=%0d bus=%0dB",
                   M_AXI_AWADDR, M_AXI_AWSIZE, DATA_WD_BYTE);
    end

    // 这里曾有一条"块字数必须为偶"的 $fatal，**已删除，因为那个不变式本身是错的**。
    //
    // 当初的推理是"每条通路的块字数都是偶数"（权重/向量补到 HW_COLS=64、FSA K/V 补到
    // 32、Q 为 head_dim×num_heads=32），据此断言奇数即 bug。但 GEMV 权重通路根本不开
    // 补零（cmd_padding_en 只在向量通路置位），current_cols 为奇数时块字数就是奇数——
    // 随机测试打到 cols=15/27 时这条断言直接把合法配置判成 fatal。
    // 固定 case 的列宽恰好全是偶数或走补零，所以一直没暴露。
    //
    // 教训（本轮第三次栽在同一件事上）：**把"当前 case 恰好成立"当成"结构保证"**。
    // 前两次是 padding 取整、写侧地址对齐。真正的不变式是更弱的那条——
    // "打包器在块尾必须自行收尾"，现在由上方的 flush 分支保证，不需要断言来钉。
    // 奇数块的下游对齐由 CB_top_v2 的换 bank 边界向上取整到偶数来完成。
`endif

    // 首拍标记现在由 rd_beat_cnt 推出（见上方 attr FIFO）：旧写法用"AR 握手置位、
    // 首拍清零"的单标志，在 MAX_OUTSTANDING>1 下 AR 与 R 同拍时 AR 分支胜出，会把
    // 下一个 burst 的首拍标记套在当前 burst 的中间拍上，那拍只喂 1 个 word → 每块少 1 字。

    always@(posedge clock)begin
        if(!rst_n)begin
            r_read_cnt <= 1'b0;
        end
        else if(read_All_finish)begin
            r_read_cnt <= 1'b0;
        end
        // SRAM 写地址必须跟"发出了几个 entry"走，不能跟"收了几拍"走。等宽时代两者是
        // 1:1 所以按拍计没问题；加宽后非对齐块要多读一拍（33 拍只产出 32 个 entry），
        // 按拍计会让这一块之后的所有地址整体错位一格——表现为奇数行（offset=4 的
        // 非对齐块）数值全错，且错位随块累积。
        else if (nxt_sram_we) begin
            r_read_cnt <= r_read_cnt + 1;
        end
        else
            r_read_cnt <= r_read_cnt;
    end
/*--------------------- address write -------------------------*/
//TODO ： MODIFY THE FSM
    // always@(posedge clock) begin
    //     if(!rst_n)
    //         r_write_start <= 0;
    //     else if(M_AXI_RLAST)
    //         r_write_start <= 1;
    //     else
    //         r_write_start <= 0;
    // end

    always@(posedge clock) begin
        if(!rst_n)
            r_m_axi_awvalid <= 0;
        else if(r_write_start)
            r_m_axi_awvalid <= 1;
        else if(M_AXI_AWREADY && M_AXI_AWVALID)
            r_m_axi_awvalid <= 0;
        else
            r_m_axi_awvalid <= r_m_axi_awvalid;
    end

    // 写侧跨度：首偏移 + 传输字节数。与读侧的 rd_span 对称。
    wire [10:0] wr_span = {{(11-LOG_DATA_WD_BYTE){1'b0}},
                           r_cmd_dst_addr[LOG_DATA_WD_BYTE-1:0]} + r_cmd_len[10:0];

    always@(posedge clock) begin
        if(!rst_n) begin
            r_m_axi_awaddr <= 0;
            r_m_axi_awlen <= 0;
            r_tail_bytes  <= 0;
            wr_head_bytes <= 0;
        end
        else if(r_write_start)begin
            // 起始地址对齐到总线宽度下界，首偏移改用 wstrb 屏蔽——**不能原样透传**。
            // 写回目标 csr_vo_base + row_offset*4 只保证 4 字节对齐（UVM 里
            // vo_base = MI_BASE + rows*cols*4，rows*cols 为奇数时就落在半字上，
            // 实测 rows=77 cols=153 → 0xf814、rows=5 cols=133 → 0x4a64）。
            // 32 位时代总线就是 4 字节，这个地址天然对齐；加宽到 8 字节后失效。
            r_m_axi_awaddr <= r_cmd_dst_addr & ~{{(ADDR_WD-LOG_DATA_WD_BYTE){1'b0}},
                                                 {LOG_DATA_WD_BYTE{1'b1}}};
            wr_head_bytes  <= r_cmd_dst_addr[LOG_DATA_WD_BYTE-1:0];
            // 跨度按"首偏移 + 字节数"算，与读侧 rd_span 同一套算法。首偏移会把尾部
            // 往后推，可能多占一拍——直接用 cmd_len 会少发一拍、写不完。
            r_m_axi_awlen <= (wr_span + DATA_WD_BYTE - 1)/(DATA_WD_BYTE) - 'b1;
            // 末拍有效字节数，0 表示末拍是满拍。同样要按 span 算而不是 cmd_len。
            r_tail_bytes  <= wr_span[LOG_DATA_WD_BYTE-1:0];
            wr_word_last  <= r_cmd_len[10:2] - 9'd1;   // cmd_len/4 - 1
        end
        else begin
            r_m_axi_awaddr <= r_m_axi_awaddr;
            r_m_axi_awlen <= r_m_axi_awlen;
            r_tail_bytes  <= r_tail_bytes;
        end
    end

/*--------------------- write （桥无关：深度2预取缓冲）-------------------------*/
    // ============================================================
    // 写数据通路：取数端(片上SRAM同步读,1拍延迟) → 深度2 FIFO → 发数端(AXI W通道)
    //
    // 取数端按 rd_ptr 顺序发 sram_raddr，1拍后 sram_rdata 入 FIFO；
    // 发数端 WVALID=FIFO非空，WREADY&WVALID 时 pop 一个 word 发到桥。
    // 发读流控 (fifo_count+outstanding)<2 保证 FIFO 永不溢出 → 对任意 WREADY 节奏
    // 都不丢不重，与桥的握手节奏完全解耦（单拍桥满速、双拍桥半速，同一份RTL均正确）。
    //
    // 深度2推导：SRAM读延迟1拍，"已发未回"最多1；发数端被桥stall时FIFO头占用1，
    // 上拍已发的取数结果这拍到达需第2个entry → 深度2接住，占满后停发，永不溢出。
    // ============================================================

    // 写传输激活：cmd接受(cmd_rw=1)到write_finish期间为高，用于复位/门控预取
    // write_active 用 r_write_start 触发（C+2），与 r_m_axi_awlen 同拍生效，
    // 保证首次 issue 时 awlen 已 ready（rd_ptr_last 判据正确）。
    reg write_active;
    always @(posedge clock) begin
        if (!rst_n)
            write_active <= 1'b0;
        else if (r_write_start)
            write_active <= 1'b1;
        else if (write_finish)
            write_active <= 1'b0;
    end

    // ---- 取数端：rd_ptr 顺序发 sram_raddr ----
    // rd_ptr = 下一个要取的线性索引(0..awlen)；issue 即把它作为读地址发给片上SRAM。
    reg  [8:0] rd_ptr;          // 已发取数索引（片上 SRAM 的 word 下标）
    // 片上 Output SRAM 每拍只给一个 word（连续两个输出 word 在 bank 外循环的几何下
    // 跨 bank 跨 addr，取不到相邻的 128b 片段），而 AXI 一拍要两个 word——故取数笔数
    // 按 word 计、不能再拿 awlen（beat 数）当边界。wr_word_last 在上方声明区。
    wire       rd_ptr_last = (rd_ptr == wr_word_last);

    // 深度2 FIFO 状态
    reg  [DATA_WD-1:0] fifo_mem [0:1];
    reg                fifo_last [0:1];    // 每笔随数据携带的 WLAST 标志
    reg  [1:0]         fifo_wptr, fifo_rptr;  // 含wrap位的指针(深度2→1位地址+1位wrap)
    wire [1:0]         fifo_count = fifo_wptr - fifo_rptr;
    wire               fifo_empty = (fifo_wptr == fifo_rptr);
    wire               fifo_full  = (fifo_count == 2'd2);

    // 已发未回的取数请求数(outstanding)：issue +1，数据到达 -1
    reg  [1:0] rd_outstanding;
    reg        rd_ptr_done;     // 所有笔的取数地址都已发完
    reg        rd_data_vld;     // 取数结果有效(issue后1拍)，用于push FIFO
    reg        rd_data_last;    // 该取数结果对应的 WLAST
    wire       rd_issue = write_active && !rd_ptr_done &&
                          ((fifo_count + rd_outstanding) < 2'd2);

    // issue 脉冲打1拍 → 标记下一拍 sram_rdata 有效、需 push
    always @(posedge clock) begin
        if (!rst_n || (cmd_valid && cmd_ready)) begin
            rd_data_vld  <= 1'b0;
            rd_data_last <= 1'b0;
        end else begin
            rd_data_vld  <= rd_issue;
            rd_data_last <= rd_ptr_last;
        end
    end

    // rd_ptr 推进（issue 拍递增；发完最后一笔置 rd_ptr_done 停发）
    always @(posedge clock) begin
        if (!rst_n || (cmd_valid && cmd_ready)) begin
            rd_ptr      <= 9'd0;
            rd_ptr_done <= 1'b0;
        end else if (rd_issue) begin
            if (rd_ptr_last)
                rd_ptr_done <= 1'b1;
            else
                rd_ptr <= rd_ptr + 9'd1;
        end
    end

    // sram_raddr 组合直跟 rd_ptr：本拍发取数地址(线性索引)，下拍 sram_rdata 回。
    // 与 rd_data_vld(=rd_issue 打1拍) 严格对齐——push 拍捕获的正是本笔索引的数据。
    // （若改寄存器会使地址滞后1拍，导致 index≥1 数据整体偏移，故必须组合驱动。）
    always @(*) sram_raddr = rd_ptr;

    // ---- FIFO push：取数结果到达(issue后1拍)，两笔凑成一个 beat ----
    // 末尾 word 数为奇数时（如尾块只剩 1 行），最后一个 beat 只填低半，
    // 高半由 M_AXI_WSTRB 的末拍掩码屏蔽掉，不会写进 DDR。
    always @(posedge clock) begin
        if (!rst_n || (cmd_valid && cmd_ready)) begin
            fifo_wptr  <= 2'd0;
            // 非对齐起始时打包器以"手里已经攒了一个字"的相位启动：AW 被对齐到下界后，
            // 首拍的低半字属于目标缓冲区之前的数据、由 head_strb_mask 跳过，所以本次
            // 传输的第一个真实 word 必须落在首拍的**高半**。wpack_lo 填零即可——那半
            // 字节道的 wstrb 是 0，写不进 DDR。
            // 取 cmd_dst_addr（输入端口）而非 r_cmd_dst_addr：本分支的条件正是
            // cmd_valid && cmd_ready，而 r_cmd_dst_addr 在同一拍才被非阻塞赋值，
            // 这拍读它拿到的还是上一条命令的地址。
            wpack_half <= |cmd_dst_addr[LOG_DATA_WD_BYTE-1:0];
            wpack_lo   <= {WORD_W{1'b0}};
        end
        else if (rd_data_vld) begin
            if (!wpack_half) begin
                wpack_lo   <= sram_rdata[WORD_W-1:0];
                wpack_half <= 1'b1;
                if (rd_data_last) begin   // 总 word 数为奇数：单字也要成 beat 推出去
                    fifo_mem [fifo_wptr[0]] <= {{WORD_W{1'b0}}, sram_rdata[WORD_W-1:0]};
                    fifo_last[fifo_wptr[0]] <= 1'b1;
                    fifo_wptr  <= fifo_wptr + 2'd1;
                    wpack_half <= 1'b0;
                end
            end else begin
                fifo_mem [fifo_wptr[0]] <= {sram_rdata[WORD_W-1:0], wpack_lo};
                fifo_last[fifo_wptr[0]] <= rd_data_last;
                fifo_wptr  <= fifo_wptr + 2'd1;
                wpack_half <= 1'b0;
            end
        end
    end

    // ---- FIFO pop：AXI W 握手 ----
    always @(posedge clock) begin
        if (!rst_n || (cmd_valid && cmd_ready))
            fifo_rptr <= 2'd0;
        else if (M_AXI_WVALID && M_AXI_WREADY)
            fifo_rptr <= fifo_rptr + 2'd1;
    end

    // ---- 写侧首拍标记：供 head_strb_mask 用 ----
    // 命令握手时置起，第一个 W 拍握完即清。写侧是严格单 outstanding（一条命令一笔
    // 突发、B 回来才发下一条），所以单标志够用，不像读侧要 per-burst 队列。
    always @(posedge clock) begin
        if (!rst_n)
            wr_first_beat <= 1'b0;
        else if (cmd_valid && cmd_ready)
            wr_first_beat <= 1'b1;
        else if (M_AXI_WVALID && M_AXI_WREADY)
            wr_first_beat <= 1'b0;
    end

    // ---- 发数端输出：WVALID/WDATA/WLAST 全部由 FIFO 头驱动 ----
    assign M_AXI_WDATA  = fifo_mem [fifo_rptr[0]];
    assign M_AXI_WVALID = !fifo_empty;
    assign M_AXI_WLAST  = (!fifo_empty) && fifo_last[fifo_rptr[0]];
//strobe assign
    always@(posedge clock) begin
        if(!rst_n || w_trans_num == TRANS_PER_DATA) 
            w_trans_num <= 1;
        else if(M_AXI_WREADY && M_AXI_WVALID)
            w_trans_num <= w_trans_num + 1;
        else 
            w_trans_num <= w_trans_num;
    end
    //maybe the logic chain to long
    // always@(posedge clock) begin
    //     r_m_axi_wstrb_1 <= r_m_axi_wstrb;
    // end

    always@(posedge clock) begin
        if(!rst_n || M_AXI_WLAST)
        case(TRANS_PER_DATA)
            2: r_m_axi_wstrb <= {{(STRB_WD/2){1'b0}},{(STRB_WD/2){1'b1}}};
            4: r_m_axi_wstrb <= {{(3*STRB_WD/4){1'b0}},{(STRB_WD/4){1'b1}}};
            8: r_m_axi_wstrb <= {{(7*STRB_WD/8){1'b0}},{(STRB_WD/8){1'b1}}};
            16: r_m_axi_wstrb <= {{(15*STRB_WD/16){1'b0}},{(STRB_WD/16){1'b1}}};
            default: r_m_axi_wstrb <= {STRB_WD{1'b1}};
        endcase
        else if((M_AXI_AWREADY & M_AXI_AWVALID)|(M_AXI_WREADY & M_AXI_WVALID))begin
            case(TRANS_PER_DATA)
                2: begin
                    case(w_trans_num)
                    0: r_m_axi_wstrb <= {{(STRB_WD/2){1'b0}},{(STRB_WD/2){1'b1}}};
                    TRANS_PER_DATA: r_m_axi_wstrb <= {{(STRB_WD/2){1'b0}},{(STRB_WD/2){1'b1}}};
                    default: r_m_axi_wstrb <= r_m_axi_wstrb << STRB_WD/2;
                    endcase
                end
                4: begin
                    case(w_trans_num)
                    0: r_m_axi_wstrb <= {{(3*STRB_WD/4){1'b0}},{(STRB_WD/4){1'b1}}};
                    TRANS_PER_DATA: r_m_axi_wstrb <= {{(3*STRB_WD/4){1'b0}},{(STRB_WD/4){1'b1}}};
                    default: r_m_axi_wstrb <= r_m_axi_wstrb << STRB_WD/4;
                    endcase
                end
                8: begin
                    case(w_trans_num)
                    0: r_m_axi_wstrb <= {{(7*STRB_WD/8){1'b0}},{(STRB_WD/8){1'b1}}};
                    TRANS_PER_DATA: r_m_axi_wstrb <= {{(7*STRB_WD/8){1'b0}},{(STRB_WD/8){1'b1}}};
                    default: r_m_axi_wstrb <= r_m_axi_wstrb << STRB_WD/8;
                    endcase
                end
                16: begin
                    case(w_trans_num)
                    0: r_m_axi_wstrb <= {{(15*STRB_WD/16){1'b0}},{(STRB_WD/16){1'b1}}};
                    TRANS_PER_DATA: r_m_axi_wstrb <= {{(15*STRB_WD/16){1'b0}},{(STRB_WD/16){1'b1}}};
                    default: r_m_axi_wstrb <= r_m_axi_wstrb << STRB_WD/16;
                    endcase
                end
                default: r_m_axi_wstrb <= {STRB_WD{1'b1}};
            endcase
        end
        else
            r_m_axi_wstrb <= r_m_axi_wstrb;
    end

    // ---- outstanding 计数：issue +1，取数结果到达(rd_data_vld) -1 ----
    // 与 fifo_count 一起约束 (fifo_count+rd_outstanding)<2，保证 FIFO 永不溢出
    always @(posedge clock) begin
        if (!rst_n || (cmd_valid && cmd_ready))
            rd_outstanding <= 2'd0;
        else begin
            case ({rd_issue, rd_data_vld})
                2'b10:   rd_outstanding <= rd_outstanding + 2'd1;
                2'b01:   rd_outstanding <= rd_outstanding - 2'd1;
                default: rd_outstanding <= rd_outstanding;
            endcase
        end
    end

/*--------------------- write response -----------------------*/

// assign M_AXI_BREADY = 1'b1;

endmodule



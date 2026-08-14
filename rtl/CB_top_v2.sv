//Defines
// CB_top_v2: 顶层集成，支持GEMV(OS)和FSA(WS)双模式
// 例化mac_top_v2 + CB_Controller_v2 + axi_dma_controller


module CB_top_v2 #(
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_ID_WIDTH   = 4,
    parameter MAC_SRAM_W_ADDR_WIDTH = 6,
    parameter MAC_SRAM_V_ADDR_WIDTH = 6,
    parameter MAC_SRAM_O_ADDR_WIDTH = 4,  // Output SRAM 16深（支持head_dim=64的O列输出）
    parameter MAC_SRAM_W_DATA_WIDTH = 32,
    parameter MAC_SRAM_V_DATA_WIDTH = 32,
    parameter MAC_SRAM_O_DATA_WIDTH = 128, // 4 bank × 32b
    parameter ADDR_WD = 32,
    parameter MAC_SRAM_W_BANK_NUM = 32, // 假设有32个SRAM bank
    parameter K_ACCUM_DEPTH = 64, // 假设累加深度为64
    parameter DATA_WD = 64  // DMA数据宽度（AXI 侧与片上 SRAM 写口同宽，一拍两个 word）
)
(
    
//clock & rst
    input clock,
    input rst_n,
    output CB_done,

//AXI Slave bus
    //aw
    input  [4 :0]   s_awid,
    input  [31:0]   s_awaddr,
    input  [7 :0]   s_awlen,
    input  [2 :0]   s_awsize,
    input  [1 :0]   s_awburst,
    input           s_awlock,
    input  [3 :0]   s_awcache,
    input  [2 :0]   s_awprot,
    input           s_awvalid,
    output          s_awready,
    //w
    input  [63:0]   s_wdata,
    input  [7 :0]   s_wstrb,
    input           s_wlast,
    input           s_wvalid,
    output          s_wready,
    //b
    output [4 :0]   s_bid,
    output [1 :0]   s_bresp,
    output          s_bvalid,
    input           s_bready,
    //ar
    input  [4 :0]   s_arid,
    input  [31:0]   s_araddr,
    input  [7 :0]   s_arlen,
    input  [2 :0]   s_arsize,
    input  [1 :0]   s_arburst,
    input           s_arlock,
    input  [3 :0]   s_arcache,
    input  [2 :0]   s_arprot,
    input           s_arvalid,
    output          s_arready,
    //r
    output [4 :0]   s_rid,
    output [63:0]   s_rdata,
    output [1 :0]   s_rresp,
    output          s_rlast,
    output          s_rvalid,
    input           s_rready,


//AXI Master (for DMA)
    // Write address channel (AW)
    output [3 :0]  m_awid,
    output [31:0]  m_awaddr,
    output [7 :0]  m_awlen,
    output [2 :0]  m_awsize,
    output [1 :0]  m_awburst,
    output         m_awlock,
    output [3 :0]  m_awcache,
    output [2 :0]  m_awprot,
    output         m_awvalid,
    input          m_awready,

// Write data channel (W)
    output [63:0]  m_wdata,
    output [7 :0]  m_wstrb,
    output         m_wlast,
    output         m_wvalid,
    input          m_wready,

// Write response channel (B)
    input  [3 :0]  m_bid,
    input  [1 :0]  m_bresp,
    input          m_bvalid,
    output         m_bready,

// Read address channel (AR)
    output [3 :0]  m_arid,
    output [31:0]  m_araddr,
    output [7 :0]  m_arlen,
    output [2 :0]  m_arsize,
    output [1 :0]  m_arburst,
    output         m_arlock,
    output [3 :0]  m_arcache,
    output [2 :0]  m_arprot,
    output         m_arvalid,
    input          m_arready,

// Read data channel (R)
    input  [3 :0]  m_rid,
    input  [63:0]  m_rdata,
    input  [1 :0]  m_rresp,
    input          m_rlast,
    input          m_rvalid,
    output         m_rready,


//Debug
    // FSM状态观测口，与cb_controll_v2的state同宽（5位/26个编码）
    output [4:0]  debug_state,
    output [15:0] debug_data



);

//MAC
wire mac_start, mac_done;
wire acc_en;    //从controller送到mac的累加信号
wire w_mem_rst; // 内存复位信号
wire v_mem_rst; // 内存复位信号

wire [31:0] current_cols; // 当前列数

assign debug_data = 16'd0; // 预留调试端口

// wire mat_write_finished;
// assign mat_write_finished = (mac_w_sram_waddr == 63) ? 1'b1 : 1'b0; // 假设写入完成条件为地址到达63

wire                       ctrl_done;       // 控制器完成信号
assign CB_done = ctrl_done;

//DMA
wire                       cmd_valid;       // DMA 命令有效
wire                       cmd_ready;       // 控制器就绪

wire [31:0]                cmd_src_addr;    // 源地址
wire [31:0]                cmd_dst_addr;    // 目的地址
wire [1:0]                 cmd_burst;       // 00=INCR, 01=FIXED, 10=WRAP
wire                       cmd_rw;          // 0=读, 1=写
wire [10:0]                cmd_len;         // 传输字节数
wire [2:0]                 cmd_size;        // AXI beat 大小 (0=1B,1=2B,2=4B,…)
wire                       dma_done; 
wire [8:0]                 cmd_block_size;
wire [10:0]                cmd_stride; // stride Bytes
wire                       cmd_padding_en;
wire [6:0]                 cmd_block_count; // block_cnt -1
wire [7:0]                 cmd_padding_words;
//wire [STRB_WD-1:0]         R_strobe;        // 读通道 byte-enable（不需可接全 1）

    wire [1:0]                 dma_target_sram; // 00=Vec, 01=Weight, 10=Output, 11=Reserved
    wire                       mac_access_mode; // 0=计算模式, 1=DMA访问模式

    // 来自 DMA 的 SRAM 接口信号
    wire dma_sram_we;
    wire [ADDR_WD-1:0] dma_sram_waddr;
    wire [DATA_WD-1:0] dma_sram_wdata;
    wire [ADDR_WD-1:0] dma_sram_raddr;
    wire [DATA_WD-1:0] dma_sram_rdata; // 从 MAC 输入到 DMA
    wire dma_padding_active;  // DMA当前传输是否有padding

    // 连接到mac_top的Weight SRAM的写端口
    reg  [MAC_SRAM_W_BANK_NUM-1:0]   mac_w_sram_bank_we;
    reg  [MAC_SRAM_W_ADDR_WIDTH-1:0] mac_w_sram_waddr;
    // 一个 DMA beat 的两个 word（低半=先来的）。
    //   wdual=1：两 word 同 bank、addr n/n+1 → 落进同一 entry 的高低半（GEMV 权重、FSA-V）
    //   wdual=0：两 word 落相邻两 bank、同 addr → 各取一半，由 whalf 逐 bank 指定（FSA-K）
    reg  [2*MAC_SRAM_W_DATA_WIDTH-1:0] mac_w_sram_wdata;
    reg                                mac_w_sram_wdual;
    reg  [MAC_SRAM_W_BANK_NUM-1:0]     mac_w_sram_whalf;
    reg  [4:0] dma_w_bank_sel_cnt;       // 5位, 用于选择目标 Bank (0-31)
    reg  [5:0] dma_w_addr_in_bank_cnt;   // 6位, 用于 Bank 内的地址 (0-63)

    // FSA列主序DMA写入计数器（col inner, row middle, group_base outer）
    reg  [4:0] dma_col_cnt;              // 0..head_dim-1（bank偏移）
    reg  [5:0] dma_row_cnt;              // 0..seq_tile_len-1（SRAM地址）
    reg  [4:0] dma_group_base;           // 组基址: 0, hd, 2*hd, 3*hd

    // dma_sram_we上升沿检测（FSA计数器burst开始时清零）
    reg  dma_sram_we_d;
    wire dma_sram_we_rise = dma_sram_we && !dma_sram_we_d;

    // 连接到mac_top的Vector SRAM的写端口
    reg  mac_v_sram_we;
    reg  [MAC_SRAM_V_ADDR_WIDTH-1:0] mac_v_sram_waddr;
    reg  [2*MAC_SRAM_V_DATA_WIDTH-1:0] mac_v_sram_wdata;  // 一个 beat 的两个 word
    // Vector SRAM本地地址计数器（饱和计数，防止DMA padding覆盖有效数据）
    reg  [6:0] dma_v_addr_cnt;  // 7位，饱和在32/64不回绕

    reg  mac_w_sram_w_flop; // 用于控制写使能的寄存器

    // 连接到mac_top_v2的Output SRAM读端口（wire在mac_top_v2例化处声明）
    wire [MAC_SRAM_O_ADDR_WIDTH-1:0] mac_o_sram_raddr;
    wire [MAC_SRAM_O_DATA_WIDTH-1:0] mac_o_sram_rdata;

    // DMA 写 (SRAM -> 主存) 路径：Output SRAM 4bank×16深 = 64 word（深度8→16支持head_dim=64）
    // 桥无关架构：DMA 用 6-bit 线性索引(dma_sram_raddr)寻址，CB_top 只做几何解码——
    // 低4位=行地址(0..15)组合喂SRAM，高2位=bank。SRAM 同步读1拍，故 bank 打1拍对齐
    // 读出数据。地址领先/握手对齐等相位问题全部收敛到 DMA 内部的深度2预取FIFO，
    // CB_top 不再含任何 AXI 握手节奏假设（原 rd_lead/rd_data 双相位已删）。
    reg  [1:0] bank_sel_d;   // bank 选择打1拍，匹配 Output SRAM 1拍读延迟

    // 连接到 DMA 的 sram_rdata 的 MUX 输出
    wire [DATA_WD-1:0] muxed_sram_rdata;
assign cmd_size = 3'b011;   // 8 字节/拍，与 64 位总线等宽


// --- 路径 1: DMA 读 (DDR -> SRAM)，数据写入本地 SRAM ---
// FSA信号前向声明（用于DMA写入逻辑中的模式判断）
wire fsa_mode_early;
wire [7:0] fsa_head_dim_early;
wire [7:0] fsa_seq_tile_len_early;
wire fsa_dma_is_v_w;   // FSA模式当前DMA搬运V（高=V行主序，低=K列主序）
wire [1:0] fsa_group_mode_early;  // 前向声明，供Output SRAM读出几何解码使用（下方在真实信号声明前就要用）
// GQA/MQA：本趟硬件读进的唯一 KV 头数（由 cb_controll_v2 导出）。用于把 K/V 的
// 单热 bank_we 扩成多热 fanout 掩码——一份 KV 广播进 ratio 个 Q 组。
wire [2:0] fsa_num_kv_heads_early;
// head_dim>32的K-DMA分chunk1/chunk2两次传输，dma_col_cnt换行边界（一行实际收
// 多少个词才算写完）改用这个信号，不能直接读fsa_head_dim_early。非dual_chunk_mode
// 时=head_dim，跟改动前一致；dual_chunk_mode时chunk1/chunk2都固定32——chunk2列数
// 不足32时DMA会在同一行内自动补零凑满32，换行边界必须按补零后的总词数算
wire [7:0] fsa_k_dma_col_width_w;

// eff_group_size本地派生（由已有的fsa_group_mode_early，不需要新引跨模块的线）：
// 4×8=8, 2×16=16, 1×32=32
wire [5:0] fsa_eff_group_size_early = (fsa_group_mode_early == 2'b10) ? 6'd32 :
                                       (fsa_group_mode_early == 2'b01) ? 6'd16 : 6'd8;

// V-DMA写入bank组内反转（取代原PV_MAC读出端按group_mode做的反转MUX）：
// 组内反转 = 同组内"行号取反"，bank=row直接映射成bank=反转后的row。
// 用eff_group_size（这一逻辑组有多少行，由GROUP_MODE决定）而不是head_dim——
// head_dim<=32时两者数值相同，等价替换；head_dim=64时才会分岔：head_dim=64时
// 如果还用head_dim-1算mask会反转出32~63这种不存在的bank号（物理上只有32个bank）
wire [5:0] v_group_mask    = fsa_eff_group_size_early - 6'd1;          // 7/15/31
wire [5:0] v_row_in_group  = {1'b0, dma_w_bank_sel_cnt} & v_group_mask;
wire [5:0] v_group_base    = {1'b0, dma_w_bank_sel_cnt} & ~v_group_mask;
wire [5:0] v_reversed_bank = v_group_base | (v_group_mask - v_row_in_group);

// K/V地址分区：K占addr[0, seq_tile_len)，V紧随其后占addr[seq_tile_len, +head_dim)。
// 分区前两者都从addr 0起、V覆盖K，outer FSM因此必须"等对方读完才敢搬自己"，
// 使得K的搬运只能排在上一tile算完之后、全程暴露。分区后各占各的地址段，
// 每块缓冲区的重填只等自己被消费完，K得以与上一tile的EXP2/PV_MAC重叠。
//
// 容量：SRAM深度64，head_dim<=32时 seq_tile_len==head_dim，最坏32+32=64正好放下；
// head_dim>32(dual_chunk)时 seq_tile_len(32)+head_dim(48/64)=80/96 超了，退回原
// 重叠布局（此时两道读完门槛仍然保留，行为与分区前逐位一致）。
// fsa_ctrl_fsm.sv 的读侧有同一份推导（v_addr_base），两处必须一致。
wire       fsa_partition_en  = (fsa_head_dim_early <= 8'd32);
wire [5:0] fsa_v_addr_base   = fsa_partition_en ? fsa_seq_tile_len_early[5:0] : 6'd0;

// ================= GQA/MQA fanout（写 Input SRAM 时把一份 K/V 广播进多个 Q 组）=================
// 本模块把 DMA 顺序吐出的一份 K/V 数据，一拍点亮多个 bank 的 write-enable，
// 让 num_kv_heads 份唯一数据填满 num_active_heads 个 Q 组。计算主路径完全不感知。
//
// 几何前提（沿用现有 group_mode 布局）：
//   4×8 ：4 个 Q 组，组基址 bank 0/8/16/24，组步长=eff_group_size=8
//   2×16：2 个 Q 组，组基址 bank 0/16，   组步长=eff_group_size=16
//   1×32：1 个 Q 组，组步长=32
// 组步长恒等于 eff_group_size，所以第 g 份复制体的 bank 偏移 = g×eff_group_size。
//
// ratio = num_active_heads / num_kv_heads（每个 KV 头要 fanout 到几个 Q 组）。
// num_active_heads 由 group_mode 推导（4/2/1）。num_kv_heads=num_active 时 ratio=1，
// 掩码退化为单热，与改动前逐位一致 → MHA 零回归。
wire [2:0] fsa_num_active_early = (fsa_group_mode_early == 2'b10) ? 3'd1 :
                                  (fsa_group_mode_early == 2'b01) ? 3'd2 : 3'd4;
// ratio = num_active / num_kv_heads，软件契约保证 num_kv_heads∈{1,2,4} 且整除
// num_active（见 fsa_programmer_guide 约束表），故合法组合只有下列几种，直接查表
// 译码——不用运行时除法器（省面积、无除零 X），也不替软件兜任何非法值。
wire [2:0] fsa_fanout_ratio =
    (fsa_num_active_early == 3'd4) ? ((fsa_num_kv_heads_early == 3'd1) ? 3'd4 :
                                      (fsa_num_kv_heads_early == 3'd2) ? 3'd2 : 3'd1) :
    (fsa_num_active_early == 3'd2) ? ((fsa_num_kv_heads_early == 3'd1) ? 3'd2 : 3'd1) :
                                     3'd1;  // num_active=1（1×32）：单头无 fanout

// K fanout 掩码：当前正写 KV 头（起始 bank=dma_group_base）的第 dma_col_cnt 列，
// 广播到 ratio 个 Q 组，第 g 组的目标 bank = dma_group_base + g×eff_group_size + dma_col_cnt。
// 用固定 4 项 OR（ratio≤4）；g≥ratio 的项用全 0 不点亮。逐位移位保证综合成静态译码。
wire [4:0] k_fanout_step = fsa_eff_group_size_early[4:0];  // 组步长（8/16/32）

// 组基址、fanout 比例、组步长必须作为显式参数传入：函数体里隐式读取的模块信号
// 不进连续赋值的敏感表，`dma_group_base` 变化时掩码不会重算——头切换后的第一拍
// 会沿用上一个头的 bank，把数据写到别人的组里（实测 gbase=8 时掩码仍是 0x03）。
function automatic [31:0] k_bank_mask(input [5:0] col, input [4:0] gbase,
                                      input [2:0] ratio, input [4:0] step);
    k_bank_mask =
          ( (32'b1 << (gbase + col)) )
        | ( (ratio > 3'd1) ? (32'b1 << (gbase + step      + col)) : 32'b0 )
        | ( (ratio > 3'd2) ? (32'b1 << (gbase + (step<<1) + col)) : 32'b0 )
        | ( (ratio > 3'd3) ? (32'b1 << (gbase + (step*3)  + col)) : 32'b0 );
endfunction

// 一个 64 位 beat 带两个 word = 同一行的相邻两列 → 落到相邻两 bank 的同一 addr。
// 低半 word 给 col、高半给 col+1，故 whalf 掩码就是 col+1 那组 bank。
wire [31:0] k_bank_we_c0    = k_bank_mask({1'b0, dma_col_cnt},
                                          dma_group_base, fsa_fanout_ratio, k_fanout_step);
wire [31:0] k_bank_we_c1    = k_bank_mask({1'b0, dma_col_cnt} + 6'd1,
                                          dma_group_base, fsa_fanout_ratio, k_fanout_step);
wire [31:0] k_fanout_bank_we = k_bank_we_c0 | k_bank_we_c1;
wire [31:0] k_fanout_whalf   = k_bank_we_c1;

// V fanout 掩码：V 写入按"组内行号取反"存储（v_reversed_bank）。
// 与 K 不同，V 的组信息不是显式寄存器，而是从连续递增的 dma_w_bank_sel_cnt 派生：
//   MHA 下 seq_tile_len=eff_group_size，一个 KV 头恰好占一个物理组（8/16 行），
//   v_group_base = bank_sel & ~mask = kv_head_idx × eff_group_size。
// GQA 下 DMA 只交付 num_kv_heads 头，bank_sel 连续，但每个 KV 头要占 ratio 个物理组，
// 相邻 KV 头的物理组间距是 ratio×eff_group_size。因此第一份复制体的组基址必须放大
// 到 v_group_base × ratio（把"按 KV 头紧排"的 bank_sel 拉伸到"按物理组分散"的布局），
// 否则第 2 个 KV 头会跟第 1 个 KV 头的 fanout 复制体撞 bank。
// 组内反转偏移 v_rev_off 各复制体一致；每份复制体再 +g×eff_group_size。
// ratio=1 时 v_group_base×1=v_group_base，与改动前 v_reversed_bank 逐位一致 → MHA 零回归。
wire [5:0] v_rev_off        = v_group_mask - v_row_in_group;      // 组内反转后的行偏移
wire [5:0] v_fanout_base    = v_group_base * fsa_fanout_ratio;    // 拉伸后的首组基址

// V 每 tile 实际交付的行数 = num_kv_heads × seq_tile_len。原设计靠"每 tile 恰 32 行 →
// dma_w_bank_sel_cnt 5-bit 自然回绕"在 tile 间归零；GQA 下只交付 <32 行，计不满 32
// 不会自然回绕，第 2 个 tile 会从上一 tile 的残值继续 → 写错 bank。故显式在此边界回绕。
// MHA(num_kv=num_active) 时该乘积=32，边界回绕与原 5-bit 溢出逐位等价 → 零回归。
wire [6:0] v_rows_per_tile   = fsa_num_kv_heads_early * fsa_seq_tile_len_early[6:0];
wire [31:0] v_fanout_bank_we =
      ( (32'b1 << (v_fanout_base + v_rev_off)) )
    | ( (fsa_fanout_ratio > 3'd1) ? (32'b1 << (v_fanout_base + k_fanout_step     + v_rev_off)) : 32'b0 )
    | ( (fsa_fanout_ratio > 3'd2) ? (32'b1 << (v_fanout_base + (k_fanout_step<<1) + v_rev_off)) : 32'b0 )
    | ( (fsa_fanout_ratio > 3'd3) ? (32'b1 << (v_fanout_base + (k_fanout_step*3)  + v_rev_off)) : 32'b0 );

always @(posedge clock or negedge rst_n) begin
    if (!rst_n) begin
        // --- 复位信号 ---
        mac_v_sram_we          <= 1'b0;
        mac_v_sram_waddr       <= 0;
        mac_v_sram_wdata       <= 0;
        dma_v_addr_cnt         <= 0;

        mac_w_sram_bank_we     <= 32'b0;
        mac_w_sram_waddr       <= 0;
        mac_w_sram_wdata       <= 0;
        mac_w_sram_wdual       <= 1'b0;
        mac_w_sram_whalf       <= 32'b0;

        // 复位Bank选择和地址计数器
        dma_w_bank_sel_cnt     <= 0;
        dma_w_addr_in_bank_cnt <= 0;
        dma_col_cnt            <= 0;
        dma_row_cnt            <= 0;
        dma_group_base         <= 0;
        dma_sram_we_d          <= 1'b0;

    end else begin
        // dma_sram_we上升沿检测（用于FSA计数器burst清零）
        dma_sram_we_d <= dma_sram_we;
        mac_w_sram_bank_we <= 32'b0;
        mac_v_sram_we      <= 1'b0;

        if (dma_sram_we) begin
            case (dma_target_sram)
                2'b00: begin // 目标: Vector SRAM（用本地计数器递增地址）
                    // 只写前64个word（4 bank × 16深），超出部分为DMA padding不写入。
                    // 一拍两 word：翻转后的映射下它们落到相邻两 bank 的同一 addr。
                    if (dma_v_addr_cnt < 7'd64) begin
                        mac_v_sram_we    <= 1'b1;
                        mac_v_sram_waddr <= dma_v_addr_cnt[5:0];
                        mac_v_sram_wdata <= dma_sram_wdata;
                        dma_v_addr_cnt   <= dma_v_addr_cnt + 7'd2;
                    end
                end
                
                2'b01: begin // 目标: Weight/Input SRAM
                    if (fsa_mode_early && !fsa_dma_is_v_w) begin
                        // ================================================
                        // FSA模式 K-DMA：列主序写入（bank=col, addr=row）
                        // 替代原硬件transposer：读同一addr时32 bank天然输出转置后的K行
                        // 三层计数器：col内循环 → row中循环 → group_base外循环
                        // GQA fanout：k_fanout_bank_we 一拍点亮 ratio 个 Q 组的同名 bank，
                        // 把当前 KV 头的这一列广播进 ratio 个组（ratio=1 时退化单热=现状）。
                        // ================================================
                        // 一拍写两列：相邻两 bank 同 addr，各取 beat 的一半
                        mac_w_sram_bank_we <= k_fanout_bank_we;
                        mac_w_sram_whalf   <= k_fanout_whalf;
                        mac_w_sram_wdual   <= 1'b0;
                        mac_w_sram_waddr   <= dma_row_cnt;
                        mac_w_sram_wdata   <= dma_sram_wdata;

                        // 计数器更新：换行边界用fsa_k_dma_col_width_w（本次DMA实际列宽），
                        // 不是全局fsa_head_dim_early——chunk1/chunk2两次传输的列宽不同
                        if (dma_col_cnt == fsa_k_dma_col_width_w[4:0] - 5'd2) begin
                            dma_col_cnt <= 5'd0;
                            if (dma_row_cnt == fsa_seq_tile_len_early[5:0] - 6'd1) begin
                                dma_row_cnt    <= 6'd0;
                                // 换到下一个 KV 头：跳过本头已 fanout 覆盖的 ratio 个组，
                                // 前进 ratio×eff_group_size。MHA(ratio=1) 时 eff_group_size
                                // ==fsa_k_dma_col_width_w(=head_dim)，与改动前逐位一致。
                                dma_group_base <= dma_group_base +
                                                  (fsa_fanout_ratio * k_fanout_step);
                            end else
                                dma_row_cnt <= dma_row_cnt + 6'd1;
                        end else
                            dma_col_cnt <= dma_col_cnt + 5'd2;
                    end else if (fsa_mode_early && fsa_dma_is_v_w) begin
                        // ================================================
                        // FSA模式 V-DMA：行主序写入（bank=row, addr=col）
                        // V不经transposer，PV_MAC直接读：读addr=c时32 bank输出V各行第c列
                        // 计数器复用GEMV的 addr-inner/bank-outer 逻辑，按head_dim换bank
                        // V-DMA写入时按组内行号取反存储（v_reversed_bank）：
                        // PV_MAC读出时地址已对齐逻辑顺序，无需额外反转MUX
                        // GQA fanout：v_fanout_bank_we 把当前 KV 头这一行广播进 ratio 个
                        // Q 组，各组的组内反转偏移一致、组基址相差 eff_group_size
                        // （ratio=1 时 v_fanout_bank_we 逐位等于 (1<<v_reversed_bank)=现状）。
                        // ================================================
                        // 一拍写两列：同 bank 的 addr n/n+1 → 同一 entry 的高低半
                        mac_w_sram_bank_we <= v_fanout_bank_we;
                        mac_w_sram_wdual   <= 1'b1;
                        mac_w_sram_whalf   <= 32'b0;
                        // 加fsa_v_addr_base把V整体挪到K之后（dual_chunk时该基址为0，
                        // 退化成与K重叠的原布局）
                        mac_w_sram_waddr   <= dma_w_addr_in_bank_cnt + fsa_v_addr_base;
                        mac_w_sram_wdata   <= dma_sram_wdata;

                        // addr内循环0..head_dim-1，满后换bank（行主序：bank=序列行）
                        // 换 bank 时在 tile 边界（交付满 v_rows_per_tile 行）显式回绕，
                        // 不再依赖 5-bit 自然溢出——GQA 每 tile <32 行时溢出不会发生。
                        if (dma_w_addr_in_bank_cnt == fsa_head_dim_early[5:0] - 6'd2) begin
                            dma_w_addr_in_bank_cnt <= 0;
                            if (dma_w_bank_sel_cnt == v_rows_per_tile[4:0] - 5'd1)
                                dma_w_bank_sel_cnt <= 5'd0;
                            else
                                dma_w_bank_sel_cnt <= dma_w_bank_sel_cnt + 5'd1;
                        end else
                            dma_w_addr_in_bank_cnt <= dma_w_addr_in_bank_cnt + 2;
                    end else begin
                        // ================================================
                        // GEMV模式：保持原有 addr-inner/bank-outer 逻辑
                        // ================================================
                        // 一拍写两个 word：同 bank 的 addr n/n+1 → 同一 entry 的高低半
                        mac_w_sram_bank_we <= (1 << dma_w_bank_sel_cnt);
                        mac_w_sram_wdual   <= 1'b1;
                        mac_w_sram_whalf   <= 32'b0;
                        mac_w_sram_waddr   <= dma_w_addr_in_bank_cnt;
                        mac_w_sram_wdata   <= dma_sram_wdata;

                        // 换 bank 边界：开了补零时 DMA 会把每个 bank 填满到 K_ACCUM_DEPTH，
                        // 没开时一块就只有 current_cols 个字。两者**不等价**——权重 DMA 并不
                        // 开补零（cmd_padding_en 只在向量那条通路置位），不能简化成固定值。
                        //
                        // 向上取整到偶数，**与 cb_controll_v2 里 cmd_block_size 的取整是
                        // 同一个数**：那边把每块读取字数凑成 (cols+1)&~1（奇数块在打包器
                        // 里收不了尾，见 axi_dma_controller 的长注释），这边的换 bank 边界
                        // 必须匹配同一个字数，否则计数器与实际收到的 entry 数对不上。
                        // 若只改一边：边界偏小会提前换 bank，偏大则永远命中不了
                        // （计数器步长 2 只走偶数值，奇数边界跳过去了）——两种都是静默错位。
                        // 偶数列宽下 ((cols+1)&~1)-2 == cols-2，与改动前逐位一致。
                        if (dma_w_addr_in_bank_cnt ==
                            (dma_padding_active ? K_ACCUM_DEPTH - 2
                                                : (((current_cols + 1) & ~32'd1) - 2))) begin
                            dma_w_addr_in_bank_cnt <= 0;
                            dma_w_bank_sel_cnt     <= dma_w_bank_sel_cnt + 1;
                        end else begin
                            dma_w_addr_in_bank_cnt <= dma_w_addr_in_bank_cnt + 2;
                        end
                    end
                end
            endcase
        end else if (CB_done || w_mem_rst) begin
            dma_w_bank_sel_cnt <= 0;
            dma_w_addr_in_bank_cnt <= 0;
            dma_col_cnt        <= 0;
            dma_row_cnt        <= 0;
            dma_group_base     <= 0;
            dma_v_addr_cnt     <= 0;
        end
    end
end


// --- 路径 2: DMA 写 (SRAM -> DDR)，从Output SRAM读取数据 ---

// Output SRAM读地址由DMA控制器的线性索引驱动（dma_sram_raddr）

// 数据锁存和切片控制：每地址读出128b(4×32b)，逐个送DMA
// GEMV模式读出顺序：bank0全部地址 → bank1全部地址 → ...
// 即 bank(高位)为外循环，addr(低位)为内循环

// 几何解码：写入端按group_mode用了不同的bank/offset切分（4×8每bank仅用前8深，
// 2×16只用bank0/bank2各16深，1×32用bank0-3各16深），读出端必须逐一对应，
// 不能用统一的[5:4]/[3:0]套所有模式——否则4×8/2×16会读到错误的bank或越界进未写入的偏移。
// GEMV模式不受Output SRAM深度8→16影响（write_out_v2仍只写每bank的前8深，沿用原3位offset几何）。
wire [1:0] fsa_out_bank_idx_comb =
    (!fsa_mode_early)                       ? dma_sram_raddr[4:3] :          // GEMV：4bank各8深，原几何不变
    (fsa_group_mode_early == 2'b00)         ? dma_sram_raddr[4:3] :          // 4×8：4bank各8深，原几何不变
    (fsa_group_mode_early == 2'b01)         ? (dma_sram_raddr[4] ? 2'd2 : 2'd0) : // 2×16：仅bank0/bank2，各16深
                                               dma_sram_raddr[5:4];           // 1×32：bank0-3，各16深

wire [3:0] fsa_out_offset_comb =
    (!fsa_mode_early || fsa_group_mode_early == 2'b00) ? {1'b0, dma_sram_raddr[2:0]} : // GEMV/4×8：3位offset(0-7)
                                                           dma_sram_raddr[3:0];          // 2×16/1×32：4位offset(0-15)

always @(posedge clock) begin
    if (!rst_n)
        bank_sel_d <= 2'd0;
    else
        bank_sel_d <= fsa_out_bank_idx_comb;
end

// Part C: 数据选择 MUX (组合逻辑)
// Output SRAM 128b = {bank3, bank2, bank1, bank0}
// bank 用打1拍后的 bank_sel_d 选择，与 SRAM 读出数据同拍对齐。
// Output SRAM 每拍只给一个 word；DMA 的写侧打包器只取低半，高半是 don't-care
assign muxed_sram_rdata = (dma_target_sram == 2'b10)
                        ? {32'b0, mac_o_sram_rdata[bank_sel_d * 32 +: 32]}
                        : {32'b0, 32'hDEADBEEF};

// ---------------------------------------------------------------------------
// DMA↔片上 SRAM 通路取证（编译期开关：-ExtraDefine WB_TRACE）
// ---------------------------------------------------------------------------
// 加宽到"一拍两 word"后，错位类缺陷的表现是输出 X 或错值，从结果反推极难。
// 这两条埋点把"写进去的"与"读出来的"分别摊开，判读方式：
//   [WW] 每个 bank 的写入次数 ≠ K_ACCUM_DEPTH/2（或 current_cols/2）
//        → 换 bank 边界算错，数据挤在少数 bank 里（曾据此定位到边界被误简化）
//   [WW] addr 序列不是 0,2,4,… → 计数器步长没跟上双字
//   [WW] gbase 已切换但 we 掩码仍指向上一组的 bank
//        → 掩码表达式的敏感表没包含 gbase（曾据此定位到函数隐式读模块信号的坑）
//   [WB] o_rdata 为 X 而 muxed 也为 X → Output SRAM 该位置从未被写，问题在计算侧
//   [WB] o_rdata 有值但 muxed 取错 → bank_d/off 的几何解码错
// 配套：tb_fsa_e2e.sv 同一开关下打 [KREF]/[VREF]/[QREF]，与这里的写入值逐字对照，
// 可一刀切开"搬错了"与"搬对了但写错地方"——本轮正是靠这一步把范围逼到头切换边界。
`ifdef WB_TRACE
// Q/激活向量写入取证（Vector SRAM）
always @(posedge clock) begin
    if (dma_sram_we && dma_target_sram == 2'b00)
        $display("[QW] t=%0t cnt=%0d waddr=%0d data=0x%016h", $time,
                 dma_v_addr_cnt, dma_v_addr_cnt[5:0], dma_sram_wdata);
end

// 权重/K/V 写入取证：每次 DMA 往 Input SRAM 写时打印 bank 掩码 / 地址 / 半字选择 / 数据
always @(posedge clock) begin
    if (dma_sram_we && dma_target_sram == 2'b01) begin
        if (!fsa_mode_early)
            $display("[WW] t=%0t GEMV bank=%0d addr=%0d data=0x%016h", $time,
                     dma_w_bank_sel_cnt, dma_w_addr_in_bank_cnt, dma_sram_wdata);
        else if (!fsa_dma_is_v_w)
            $display("[WW] t=%0t K gbase=%0d col=%0d row=%0d we=0x%08h half=0x%08h data=0x%016h",
                     $time, dma_group_base, dma_col_cnt, dma_row_cnt,
                     k_fanout_bank_we, k_fanout_whalf, dma_sram_wdata);
        else
            $display("[WW] t=%0t V bsel=%0d addr=%0d we=0x%08h data=0x%016h", $time,
                     dma_w_bank_sel_cnt, dma_w_addr_in_bank_cnt + fsa_v_addr_base,
                     v_fanout_bank_we, dma_sram_wdata);
    end
end

// 写回通路取证：逐拍打印 DMA 取数索引、几何解码结果与取回的数据
always @(posedge clock) begin
    if (dma_target_sram == 2'b10)
        $display("[WB] t=%0t raddr=%0d bank_c=%0d bank_d=%0d off=%0d o_rdata=0x%032h muxed=0x%08h",
                 $time, dma_sram_raddr, fsa_out_bank_idx_comb, bank_sel_d,
                 fsa_out_offset_comb, mac_o_sram_rdata, muxed_sram_rdata[31:0]);
end
`endif

assign dma_sram_rdata = muxed_sram_rdata;


    // FSA模式信号（必须在例化之前声明，避免隐式1位wire）
    wire fsa_mode_w;
    wire fsa_start_w;
    wire [7:0] fsa_head_dim_w, fsa_seq_tile_len_w;
    wire [12:0] fsa_num_kv_tiles_w; // 匹配cb_controll_v2输出[12:0]与mac_top_v2输入[12:0]；原误写[7:0]截断FSASeqLen>256时的大tile数
    wire [7:0] fsa_last_tile_valid_w;
    wire [31:0] fsa_attn_scale_w;
    wire [1:0]  fsa_group_mode_w;
    wire fsa_dma_done_w;
    wire fsa_k_read_done_w;
    wire fsa_v_read_done_w;
    wire fsa_k_preloaded_w;   // tile 0的K已被预取搬好（电平，来自控制器）
    wire fsa_k_buf_loaded_w;  // K缓冲区已装载（电平，控制器维护，见cb_controll_v2）
    wire fsa_v_buf_loaded_w;  // V缓冲区已装载（同上）
    wire fsa_done_w;
    wire [2:0] dma_o_sram_raddr_w;

    // 前向声明连接
    wire [2:0] fsa_num_kv_heads_w;  // 控制器导出：单趟唯一 KV 头数（GQA fanout 用）
    assign fsa_mode_early = fsa_mode_w;
    assign fsa_head_dim_early = fsa_head_dim_w;
    assign fsa_seq_tile_len_early = fsa_seq_tile_len_w;
    assign fsa_group_mode_early = fsa_group_mode_w;
    assign fsa_num_kv_heads_early = fsa_num_kv_heads_w;
    wire [127:0] dma_o_sram_rdata_w;

    // SiLU融合：控制器发start/收done，微程序序列在mac_top_v2内的silu_ctrl_fsm里跑
    wire        silu_start_w;
    wire [5:0]  silu_num_elem_w;
    wire        silu_done_w;
    wire [1:0] dma_v_sram_bank_sel_w;

    // CSR 总线 64 位而寄存器组按 32 位组织。CSR 只有单拍访问，位宽适配退化成"选半字"：
    // 写侧按 wstrb 定位有效半字（与数据同拍到达，不依赖 AW/W 两通道的先后），
    // 读侧两半填同值、由 master 按 addr[2] 取。
    wire        csr_w_hi   = |s_wstrb[7:4];
    wire [31:0] csr_wdata  = csr_w_hi ? s_wdata[63:32] : s_wdata[31:0];
    wire [3 :0] csr_wstrb  = csr_w_hi ? s_wstrb[7:4]   : s_wstrb[3:0];
    wire [31:0] csr_rdata;
    assign s_rdata = {csr_rdata, csr_rdata};

CB_Controller_v2 u_controller(
    .clock(clock),
    .rst_n(rst_n),
    //Debug
    .debug_state(debug_state),
    .current_cols(current_cols),

    .cmd_valid      (cmd_valid),
    .cmd_ready      (cmd_ready),
    .cmd_src_addr   (cmd_src_addr),
    .cmd_dst_addr   (cmd_dst_addr),
    .cmd_burst      (cmd_burst),
    .cmd_rw         (cmd_rw),
    .cmd_len        (cmd_len),
    .dma_done       (dma_done),
    .ctrl_done      (ctrl_done),
    .cmd_block_size (cmd_block_size),
    .cmd_stride     (cmd_stride),
    .cmd_padding_en (cmd_padding_en),
    .cmd_padding_words(cmd_padding_words),
    .cmd_block_count(cmd_block_count),

    // MAC Engine (GEMV模式)
    .mac_start(mac_start),
    .mac_done(mac_done),
    .mac_access_mode(mac_access_mode),
    .dma_target_sram(dma_target_sram),
    .acc_en(acc_en),
    .w_mem_rst(w_mem_rst),
    .v_mem_rst(v_mem_rst),

    // FSA模式接口
    .fsa_mode(fsa_mode_w),
    .fsa_start(fsa_start_w),
    .fsa_head_dim(fsa_head_dim_w),
    .fsa_seq_tile_len(fsa_seq_tile_len_w),
    .fsa_num_kv_tiles(fsa_num_kv_tiles_w),
    .fsa_last_tile_valid(fsa_last_tile_valid_w),
    .fsa_attn_scale(fsa_attn_scale_w),
    .fsa_group_mode(fsa_group_mode_w),
    .fsa_dma_done(fsa_dma_done_w),
    .fsa_k_preloaded(fsa_k_preloaded_w),
    .fsa_k_buf_loaded(fsa_k_buf_loaded_w),
    .fsa_v_buf_loaded(fsa_v_buf_loaded_w),
    .fsa_k_read_done(fsa_k_read_done_w),
    .fsa_v_read_done(fsa_v_read_done_w),
    .fsa_dma_is_v(fsa_dma_is_v_w),
    .fsa_k_dma_col_width(fsa_k_dma_col_width_w),
    .fsa_num_kv_heads(fsa_num_kv_heads_w),
    .fsa_done(fsa_done_w),
    .dma_o_sram_raddr(dma_o_sram_raddr_w),
    .dma_o_sram_rdata(dma_o_sram_rdata_w),
    // SiLU融合握手（GEMV模式）
    .silu_start(silu_start_w),
    .silu_num_elem(silu_num_elem_w),
    .silu_done(silu_done_w),
    .dma_v_sram_bank_sel(dma_v_sram_bank_sel_w),
    //AXI Slave bus

    .s_awid     (s_awid),
    .s_awaddr   (s_awaddr),
    .s_awlen    (s_awlen),
    .s_awsize   (s_awsize),
    .s_awburst  (s_awburst),
    .s_awlock   (s_awlock),
    .s_awcache  (s_awcache),
    .s_awprot   (s_awprot),
    .s_awvalid  (s_awvalid),
    .s_awready  (s_awready),

    .s_wdata    (csr_wdata),
    .s_wstrb    (csr_wstrb),
    .s_wlast    (s_wlast),
    .s_wvalid   (s_wvalid),
    .s_wready   (s_wready),

    .s_bid      (s_bid),
    .s_bresp    (s_bresp),
    .s_bvalid   (s_bvalid),
    .s_bready   (s_bready),

    .s_arid     (s_arid),
    .s_araddr   (s_araddr),
    .s_arlen    (s_arlen),
    .s_arsize   (s_arsize),
    .s_arburst  (s_arburst),
    .s_arlock   (s_arlock),
    .s_arcache  (s_arcache),
    .s_arprot   (s_arprot),
    .s_arvalid  (s_arvalid),
    .s_arready  (s_arready),

    .s_rid      (s_rid),
    .s_rdata    (csr_rdata),
    .s_rresp    (s_rresp),
    .s_rlast    (s_rlast),
    .s_rvalid   (s_rvalid),
    .s_rready   (s_rready)
);


    mac_top_v2 #(
        .ARRAY_SIZE(32),
        .DATA_WIDTH(32),
        .K_ACCUM_DEPTH(K_ACCUM_DEPTH),
        .MAC_LATENCY(5),
        .OS_MAC_LATENCY(7),
        .ACC_LATENCY(6),
        .GROUP_SIZE(8),
        .NUM_GROUPS(4)
    ) mac_top_inst (
        .clock(clock),
        .rst_n(rst_n),
        .fsa_mode(fsa_mode_w),
        .os_start(mac_start),
        .dma_access_mode(mac_access_mode),
        .dma_w_sram_bank_we(mac_w_sram_bank_we),
        .dma_w_sram_waddr(mac_w_sram_waddr),
        .dma_w_sram_wdata(mac_w_sram_wdata),
        .dma_w_sram_wdual(mac_w_sram_wdual),
        .dma_w_sram_whalf(mac_w_sram_whalf),
        .dma_v_sram_we(mac_v_sram_we),
        .dma_v_sram_waddr(mac_v_sram_waddr),
        .dma_v_sram_wdata(mac_v_sram_wdata),
        .dma_v_sram_bank_sel(dma_v_sram_bank_sel_w),
        .acc_en(acc_en),
        .w_mem_rst(w_mem_rst),
        .v_mem_rst(v_mem_rst),
        .os_processing_done(mac_done),
        .fsa_start(fsa_start_w),
        .head_dim(fsa_head_dim_w),
        .seq_tile_len(fsa_seq_tile_len_w),
        .num_kv_tiles(fsa_num_kv_tiles_w),
        .last_tile_valid(fsa_last_tile_valid_w),
        .attn_scale(fsa_attn_scale_w),
        .group_mode(fsa_group_mode_w),
        .dma_done(fsa_dma_done_w),
        .k_tile0_preloaded(fsa_k_preloaded_w),
        .k_buf_loaded(fsa_k_buf_loaded_w),
        .v_buf_loaded(fsa_v_buf_loaded_w),
        .fsa_done(fsa_done_w),
        .fsa_k_read_done(fsa_k_read_done_w),
        .fsa_v_read_done(fsa_v_read_done_w),
        .dma_o_sram_raddr(mac_o_sram_raddr),
        .dma_o_sram_rdata(dma_o_sram_rdata_w),
        .silu_start(silu_start_w),
        .silu_num_elem(silu_num_elem_w),
        .silu_done(silu_done_w)
    );

    // Output SRAM读端口连接：复用上面按mode/group_mode区分的几何解码（fsa_out_offset_comb）
    assign mac_o_sram_raddr = fsa_out_offset_comb;
    assign mac_o_sram_rdata = dma_o_sram_rdata_w;

// assign cmd_block_size = cmd_len;
// // assign cmd_block_size = 'd88;
// assign cmd_block_count = 'd0;
// assign cmd_padding_en =1'd0;
// assign cmd_padding_words = 'd0;
// assign cmd_stride ='d0;


    axi_dma_controller #(
        .ADDR_WD (32),
        .DATA_WD (64),
        .ID_WD   (4),
        .MAX_OUTSTANDING (4)
    ) u_axi_dma_controller (
    //-------------------------------------------------
    // Global
    //-------------------------------------------------
    .clock            (clock),
    .rst_n          (rst_n),

    //-------------------------------------------------
    // DMA Command interface
    //-------------------------------------------------
    .cmd_valid      (cmd_valid),
    .cmd_ready      (cmd_ready),
    .cmd_src_addr   (cmd_src_addr),
    .cmd_dst_addr   (cmd_dst_addr),
    .cmd_burst      (cmd_burst),
    .cmd_rw         (cmd_rw),      // 0 = read, 1 = write
    .cmd_len        (cmd_len),     // 单位：Byte Use in write 
    .cmd_size       (cmd_size),    // AXI beat size
    .R_strobe       (8'hFF),      // 读通道 byte-enable
    .dma_done       (dma_done), 
    .cmd_block_size (cmd_block_size), // 单位：Byte e.g. 32 32bits-floating should be 32*32/8=128 (B)
    .cmd_stride     (cmd_stride),// ADDR, e.g 32 float is 32*4 = 128, 
    .cmd_padding_en (cmd_padding_en),
    .cmd_padding_words(cmd_padding_words),
    .cmd_block_count(cmd_block_count),//block_cnt -1 ,e.g. transmit by once , this signal should be 0
    .dma_padding_active_out(dma_padding_active),
    //-------------------------------------------------
    // AXI-4 Read Address Channel
    //-------------------------------------------------
    .M_AXI_ARVALID  (m_arvalid),
    .M_AXI_ARADDR   (m_araddr),
    .M_AXI_ARLEN    (m_arlen),
    .M_AXI_ARSIZE   (m_arsize),
    .M_AXI_ARBURST  (m_arburst),
    .M_AXI_ARREADY  (m_arready),
    .M_AXI_ARID     (m_arid),
    .M_AXI_ARLOCK   (m_arlock),
    .M_AXI_ARPROT   (m_arprot),
    .M_AXI_ARCACHE  (m_arcache),

    //-------------------------------------------------
    // AXI-4 Read Data Channel
    //-------------------------------------------------
    .M_AXI_RVALID   (m_rvalid),
    .M_AXI_RDATA    (m_rdata),
    .M_AXI_RRESP    (m_rresp),
    .M_AXI_RLAST    (m_rlast),
    .M_AXI_RREADY   (m_rready),
    .M_AXI_RID      (m_rid),

    //-------------------------------------------------
    // AXI-4 Write Address Channel
    //-------------------------------------------------
    .M_AXI_AWVALID  (m_awvalid),
    .M_AXI_AWADDR   (m_awaddr),
    .M_AXI_AWLEN    (m_awlen),
    .M_AXI_AWSIZE   (m_awsize),
    .M_AXI_AWBURST  (m_awburst),
    .M_AXI_AWREADY  (m_awready),
    .M_AXI_AWID     (m_awid),
    .M_AXI_AWLOCK   (m_awlock),
    .M_AXI_AWPROT   (m_awprot),
    .M_AXI_AWCACHE  (m_awcache),

    //-------------------------------------------------
    // AXI-4 Write Data Channel
    //-------------------------------------------------
    .M_AXI_WVALID   (m_wvalid),
    .M_AXI_WDATA    (m_wdata),
    .M_AXI_WSTRB    (m_wstrb),
    .M_AXI_WLAST    (m_wlast),
    .M_AXI_WREADY   (m_wready),

    //-------------------------------------------------
    // AXI-4 Write Response Channel
    //-------------------------------------------------
    .M_AXI_BVALID   (m_bvalid),
    .M_AXI_BRESP    (m_bresp),
    .M_AXI_BID      (m_bid),
    .M_AXI_BREADY   (m_bready),
    //-------------------------------------------------
    // DMA Target SRAM Interface
    //-------------------------------------------------
    .sram_we(dma_sram_we),
    .sram_waddr(dma_sram_waddr),
    .sram_wdata(dma_sram_wdata),
    .sram_raddr(dma_sram_raddr), // 读写地址共用
    .sram_rdata(dma_sram_rdata)
);

`ifndef SYNTHESIS
// ---- 双字写口的偶数契约 ----
// 加宽后 DMA 一拍交付两个 word，三条 DMA 写分支的计数器一律步长 2，换行/换 bank 边界
// 写成 "宽度 - 2"。宽度若为奇数，`cnt == W-2` 会与步长 2 的计数序列错过（cnt 走偶数、
// W-2 是奇数），边界永远命中不了、计数器一路跑飞——**不报错、不挂死，只把数据写进
// 错误的 bank**，是典型的静默错误。
//
// **GEMV 那条不设断言**：`current_cols` 为奇数是合法配置（随机测试打到 cols=15/27，
// 权重通路不开补零，块字数就是奇数），已由 :456 的边界向上取整到偶数正面支持，
// 配合 DMA 打包器的块尾 flush。曾在这里加过一条 "current_cols 必须为偶" 的 $fatal，
// 把合法配置判成 fatal——那是把"当前固定 case 恰好都是偶数"当成了结构保证，已删。
//
// FSA K 那条保留：`fsa_k_dma_col_width_w` 来自 head_dim / chunk2 宽度，当前取值
// （8/16/32/64、chunk2 由 32 减出来）确实恒为偶，且 K 通路的列主序写入没有做奇数支持
// （不像 GEMV 分支那样只是一个边界取整就能覆盖，K 要同时动 bank fanout 与 whalf）。
// 所以这里断言的是一个**真实存在且未被支持**的前提，将来加 head_dim=48 之类的配置
// 会立刻命中，提示需要先把 K 通路的奇数支持补上。
//
// 只在 DMA 实际搬运时查：空闲期这些宽度寄存器可能是复位值或上一次的残留。
always @(posedge clock) begin
    if (rst_n && dma_sram_we && dma_target_sram == 2'b01
        && fsa_mode_early && !fsa_dma_is_v_w && fsa_k_dma_col_width_w[0])
        $fatal(1, "[CB] FSA K-DMA col width must be even: got %0d",
               fsa_k_dma_col_width_w);
end
`endif

endmodule

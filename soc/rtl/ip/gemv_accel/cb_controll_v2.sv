//======================================================================
//==                              功能描述                             ==
//======================================================================
// CB_Controller_v2: 支持GEMV(OS)和FSA(WS)双模式的控制器
// GEMV模式: 复用原版cb_controll逻辑（行/列tiling + DMA调度）
// FSA模式: 新增FlashAttention DMA调度（Q/K/V搬运 + O写回）
//
// CSR[0x00].CTRL[1]: mode位 0=GEMV, 1=FSA

//======================================================================
//==                       Register Address Map                       ==
//======================================================================
`define REG_CTRL_ADDR      16'h0000  // Control Register (RW) [0]=start [1]=mode
`define REG_STATUS_ADDR    16'h0004  // Status Register (RO)
`define REG_ERR_CODE_ADDR  16'h0008  // Error Code Register (RO, reserved)
// GEMV参数
`define REG_VI_BASE_ADDR   16'h0010  // Input Vector Base Address (RW)
`define REG_MI_BASE_ADDR   16'h0014  // Input Matrix Base Address (RW)
`define REG_VO_BASE_ADDR   16'h0018  // Output Vector Base Address (RW)
`define REG_ROWS_ADDR      16'h0020  // Matrix Rows Count (RW)
`define REG_COLS_ADDR      16'h0024  // Matrix Columns Count (RW)
// FSA参数
`define REG_Q_BASE_ADDR    16'h0030  // FSA Q DDR基地址 (RW)
`define REG_K_BASE_ADDR    16'h0034  // FSA K DDR基地址 (RW)
`define REG_V_BASE_ADDR    16'h0038  // FSA V DDR基地址 (RW)
`define REG_O_BASE_ADDR    16'h003C  // FSA O DDR基地址 (RW)
`define REG_HEAD_DIM_ADDR  16'h0040  // head维度 (RW)
`define REG_SEQ_LEN_ADDR   16'h0044  // 序列长度 (RW)
`define REG_KV_STRIDE_ADDR 16'h0048  // K/V tile间DDR步长 (RW)
`define REG_NUM_HEADS_ADDR 16'h004C  // 总head数 (RW)
`define REG_ATTN_SCALE_ADDR 16'h0050 // Attention缩放因子 log2(e)/sqrt(d) (RW)
`define REG_GROUP_MODE_ADDR 16'h0054 // FSA分组模式 (RW) 0=4×8, 1=2×16, 2=1×32
`define REG_ACT_CTRL_ADDR   16'h0058 // 激活函数融合控制 (RW) [0]=silu_en，仅GEMV模式有效
`define REG_PF_CTRL_ADDR    16'h005C // 权重预取触发 (WO) [0]=start脉冲 [1]=target(0=GEMV权重,1=FSA的K)

//======================================================================
//==                  Control/Status Register Bit Fields              ==
//======================================================================
// --- csr_ctrl (RW) ---
`define CSR_CTRL_START_BIT    0   // [0]: Write 1 to start the engine.
`define CSR_CTRL_MODE_BIT     1   // [1]: 0=GEMV, 1=FSA

// --- csr_status (RO) ---
`define CSR_STATUS_BUSY_BIT     0   // [0]: 1 if the engine is busy, 0 if idle.
`define CSR_STATUS_DONE_BIT     1   // [1]: 1 if the engine has finished one task (sticky).
`define CSR_STATUS_PF_VALID_BIT 2   // [2]: 预取数据在SRAM里有效（RO，供UVM/软件观测）
`define CSR_STATUS_PF_TGT_BIT   3   // [3]: 预取的目标 0=GEMV权重 1=FSA的K

// --- csr_pf_ctrl (WO) ---
`define CSR_PF_START_BIT      0   // [0]: 写1触发一次预取（脉冲型，不保持）
`define CSR_PF_TARGET_BIT     1   // [1]: 0=GEMV权重首块, 1=FSA的K tile 0



module CB_Controller_v2 (
    // Global Clock and Reset
    input               clock,
    input               rst_n,

    //Debug Interface
    // FSM状态观测口，位宽必须与state一致（当前26个编码0~25，需5位）。
    // 窄于state会截断高位，让FSA段(16~22)、S_SILU(23)、预取段(24~25)与
    // GEMV段的低编码状态混淆，TB据此定位死锁位置会被带偏。
    output  [4:0]       debug_state,
    output wire [31:0]  current_cols,

    // --- Interfaces to Internal Engines ---
    // DMA Controller Interface
    output  reg             cmd_valid,
    input   wire            cmd_ready,
    output  reg     [31: 0] cmd_src_addr,
    output  reg     [31: 0] cmd_dst_addr,
    output  reg     [1:0]   cmd_burst,
    output  reg             cmd_rw,
    output  reg     [10:0]  cmd_len,
    input   wire            dma_done,
    output  wire            ctrl_done,
    output reg [8:0] cmd_block_size,
    output reg [6:0] cmd_block_count,
    output reg [10:0] cmd_stride,
    output reg cmd_padding_en,
    output reg [7:0] cmd_padding_words,

    // MAC Engine Interface (GEMV模式)
    output reg          mac_start,
    input               mac_done,
    output reg          mac_access_mode,
    output reg  [1:0]   dma_target_sram,
    output reg          acc_en,
    output reg          w_mem_rst,
    output reg          v_mem_rst,

    // FSA模式接口（连接mac_top_v2）
    output reg          fsa_mode,
    output reg          fsa_start,
    output reg  [7:0]   fsa_head_dim,
    output reg  [7:0]   fsa_seq_tile_len,
    output reg  [12:0]  fsa_num_kv_tiles,
    output reg  [7:0]   fsa_last_tile_valid,  // 最后tile有效行数（0=满tile）
    output      [31:0]  fsa_attn_scale,       // ATTENTION_SCALE = log2(e)/sqrt(d)
    output      [1:0]   fsa_group_mode,       // FSA分组模式: 0=4×8, 1=2×16, 2=1×32
    output reg          fsa_dma_done,
    // tile 0的K已被预取搬好（电平，保持到K被QK_MAC读完）
    output wire         fsa_k_preloaded,
    // K/V缓冲区已装载（电平）。inner无法从共用的dma_done分辨这一笔是K还是V，
    // 而outer按自己停在S_FSA_WAIT_K还是S_FSA_WAIT_V一清二楚，故由outer给出。
    output reg          fsa_k_buf_loaded,
    output reg          fsa_v_buf_loaded,
    input               fsa_k_read_done,
    input               fsa_v_read_done,
    input               fsa_done,
    // Output SRAM读出
    output reg  [2:0]   dma_o_sram_raddr,
    input       [127:0] dma_o_sram_rdata,
    // SiLU融合（GEMV模式）：计算完成后、DMA写回之前，把Output SRAM里的结果
    // 就地过一遍silu()。顶层只做start/done握手，命令序列由mac_top_v2内的
    // silu_ctrl_fsm负责
    output reg          silu_start,
    output      [5:0]   silu_num_elem,   // 最大32，需6位
    input               silu_done,
    // Vector SRAM bank选择（FSA模式Q加载）
    output reg  [1:0]   dma_v_sram_bank_sel,
    // FSA模式K/V判别：1=当前DMA搬运V（行主序写入），0=搬运K（列主序写入）
    output reg          fsa_dma_is_v,
    // head_dim>32时K拆成chunk1+chunk2两次DMA，告诉CB_top_v2.sv这次DMA的写入端
    // 一行实际要收多少个词才换行（非dual_chunk_mode时=fsa_head_dim，跟现状一致；
    // dual_chunk_mode时chunk1/chunk2都固定32——chunk2列数不足32的部分由DMA的
    // padding机制在同一行内补零凑满32，换行边界必须按"补零后的总词数"算，不能用
    // 真实列数fsa_chunk2_width，否则补零词会被误判成下一行的开头）。CB_top_v2.sv
    // 的dma_col_cnt换行边界改用这个信号，不能直接读全局fsa_head_dim寄存器
    output reg  [7:0]   fsa_k_dma_col_width,
    // GQA/MQA：单趟硬件处理的唯一 KV 头数，喂给 CB_top_v2 生成 Input SRAM 写 fanout 掩码。
    // =num_active_heads 时退化为 MHA（现状），CB_top 侧据此把单热 bank_we 扩成多热。
    output      [2:0]   fsa_num_kv_heads,

    // --- AXI4-Lite Slave Bus ---
    //aw
    input       [4:0]   s_awid,
    input       [31:0]  s_awaddr,
    input       [7:0]   s_awlen,
    input       [2:0]   s_awsize,
    input       [1:0]   s_awburst,
    input               s_awlock,
    input       [3:0]   s_awcache,
    input       [2:0]   s_awprot,
    input               s_awvalid,
    output              s_awready,
    //w
    input       [31:0]  s_wdata,
    input       [3:0]   s_wstrb,
    input               s_wlast,
    input               s_wvalid,
    output reg          s_wready,
    //b
    output      [4:0]   s_bid,
    output      [1:0]   s_bresp,
    output reg          s_bvalid,
    input               s_bready,
    //ar
    input       [4:0]   s_arid,
    input       [31:0]  s_araddr,
    input       [7:0]   s_arlen,
    input       [2:0]   s_arsize,
    input       [1:0]   s_arburst,
    input               s_arlock,
    input       [3:0]   s_arcache,
    input       [2:0]   s_arprot,
    input               s_arvalid,
    output              s_arready,
    //r
    output      [4:0]   s_rid,
    output reg  [31:0]  s_rdata,
    output      [1:0]   s_rresp,
    output reg          s_rlast,  
    output reg          s_rvalid,
    input               s_rready
);

//======================================================================
//==                 Control and Status Registers (CSRs)              ==
//======================================================================
reg [31:0] csr_ctrl, csr_status, csr_err_code;
reg [31:0] csr_vi_base, csr_mi_base, csr_vo_base;
reg [31:0] csr_rows, csr_cols;
// FSA CSR
reg [31:0] csr_q_base, csr_k_base, csr_v_base, csr_o_base;
reg [31:0] csr_head_dim, csr_seq_len, csr_kv_stride, csr_num_heads;
reg [31:0] csr_attn_scale;
reg [1:0]  csr_group_mode;  // FSA分组模式: 0=4×8, 1=2×16, 2=1×32
reg [31:0] csr_act_ctrl;    // 激活函数融合: [0]=silu_en

// FSA的K/V搬运跟踪打印开关，默认关闭，加 +FSA_TRACE 打开。
// SoC级仿真跑完整推理时每个tile都会刷几行，会把串口的token输出淹没在几万行里。
// synopsys translate_off
bit fsa_trace_on;
initial fsa_trace_on = $test$plusargs("FSA_TRACE");
// synopsys translate_on

wire start_signal = csr_ctrl[`CSR_CTRL_START_BIT];
wire mode_fsa = csr_ctrl[`CSR_CTRL_MODE_BIT];
// SiLU 融合只在 GEMV 模式下有意义：FSA 模式的累加器正被 fsa_ctrl_fsm 占用
wire silu_en = csr_act_ctrl[0] & ~mode_fsa;

// FSA派生参数
// K/V DMA一次只搬32行（cmd_block_count恒为31，= num_active_heads × min(head_dim,32)，
// 4×8/2×16/1×32三种现有模式下head_dim<=32本来就等于这个值，head_dim>32时硬件
// 仍只搬32行——tile的"行数"(seq_tile_len)和"列数"(head_dim/Q维度)是两个独立的量，
// 不能再混用head_dim，否则head_dim=64时FSM会去等64行K但DMA只给了32行
wire [7:0] fsa_seq_tile_len_w = (csr_head_dim > 32'd32) ? 8'd32 : csr_head_dim[7:0];
wire [12:0] fsa_num_kv_tiles_w = ({1'b0, csr_seq_len[11:0]} + {1'b0, fsa_seq_tile_len_w} - 13'd1) / fsa_seq_tile_len_w;
// 活跃head数（由group_mode决定）
wire [2:0] num_active_heads = (csr_group_mode == 2'b10) ? 3'd1 :
                              (csr_group_mode == 2'b01) ? 3'd2 : 3'd4;
// Q bank选择跳步（2×16跳2，其他跳1）
wire [1:0] q_bank_step = (csr_group_mode == 2'b01) ? 2'd2 : 2'd1;

// ---- GQA/MQA：单趟硬件处理的唯一 KV 头数（复活 REG_NUM_HEADS 承载）----
// 语义：DDR 里只摆 num_kv_heads 份唯一 K/V，硬件读一次后在写 Input SRAM 时
// fanout（广播）到 num_active_heads 个 Q 组。csr_num_heads 由软件配置：
//   =num_active_heads → MHA（每组各一份，退化为现状，fanout ratio=1）
//   =num_active_heads/2 → GQA（相邻两组共享一份）
//   =1 → MQA（全部组共享一份）
// 硬件忠实执行软件配的值，不做合法性兜底——REG_NUM_HEADS 与 HEAD_DIM/SEQ_LEN 同级，
// 是 FSA 启动前的**必配寄存器**（见 programmer_guide 4.6），软件契约保证写入合法值
// （4×8∈{1,2,4}，2×16∈{1,2}，1×32=1，且整除 num_active_heads）。非法值/漏配是软件
// 违约，行为未定义，硬件不替软件优雅退化（避免写投机兜底逻辑）。
wire [2:0] num_kv_heads = csr_num_heads[2:0];
assign fsa_num_kv_heads = num_kv_heads;  // 导出给 CB_top_v2 生成 fanout 掩码

// K/V DMA 本趟实际搬运的行数 = num_kv_heads × seq_tile_len（原恒为 num_active×seq_tile=32）。
// GQA 下少读的那几份靠硬件 fanout 补齐 → 真正的 DDR 读带宽下降就发生在这里。
// num_kv_heads≤num_active_heads 且 num_active×seq_tile=32，故乘积≤32，block_count≤31 不溢出。
wire [6:0] fsa_kv_block_count = (num_kv_heads * fsa_seq_tile_len_w[6:0]) - 7'd1;

// FSA tile计数器
reg [12:0] fsa_tile_idx;
// FSA Q bank加载计数器（循环4次，每次加载1个head的Q到对应bank）
reg [1:0] fsa_q_bank_cnt;
// FSA DMA已发出标志（区分"等待请求"和"等待完成"两个阶段）
(* mark_debug = "true" *) reg fsa_dma_issued;

// head_dim>32：K拆成chunk1(前32维)+chunk2(后fsa_chunk2_width维)两次DMA。
// fsa_head_dim<=32时dual_chunk_mode恒为0，chunk分支永不触发，单次DMA行为不变
wire dual_chunk_mode = (fsa_head_dim > 8'd32);
wire [7:0] fsa_chunk2_width = fsa_head_dim - 8'd32;

// K/V地址分区使能。分区后K占Input SRAM的addr[0, seq_tile_len)、V占其后的
// addr[seq_tile_len, +head_dim)，互不覆盖。head_dim>32时两段合计80/96 > SRAM深度64
// 放不下，退回原来的重叠布局（此时下面两道"等对方读完"的门槛照旧生效）。
// 写侧地址在CB_top_v2.sv(fsa_v_addr_base)、读侧在fsa_ctrl_fsm.sv(v_addr_base)。
wire fsa_partition_en = !dual_chunk_mode;
// 当前K-DMA处于chunk1还是chunk2（非dual模式下恒为0，无意义）
(* mark_debug = "true" *) reg fsa_k_chunk_sel;

// read_done的上一拍值，用于取上升沿清 fsa_k/v_buf_loaded（见下方注释）
reg fsa_k_read_done_q;
reg fsa_v_read_done_q;

// --- 硬件能力参数 (Hardware Capability) ---
localparam HW_ROWS = 32; // 硬件引擎一次能处理的行数
localparam HW_COLS = 64; // 硬件引擎一次能处理的列数

// --- 动态计算和控制寄存器 ---
reg [15:0] num_tiles_reg;        // 锁存当前任务需要的块数
reg [15:0] tile_cnt;             // 当前处理的是第几个块 (外循环计数器)
// wire [HW_ROWS * 32 - 1:0] adder_result = mac_result + partial_sum_buffer;


//======================================================================
//==                         硬件分块寄存器                            ==
//======================================================================

//TODO 当前情况建立在cpu停顿不会继续写入任务参数，因此可以直接使用csr参数
// 如果cpu非停顿，则需要锁存参数

reg [31:0] row_offset_counter; // 已处理的行数偏移量

// 当前块的动态参数
wire [31:0] remaining_rows = csr_rows - row_offset_counter;
wire [31:0] remaining_cols = csr_cols - (tile_cnt * HW_COLS); // 当前块剩余列数
wire [31:0] current_rows;
// wire [31:0] current_cols;

// 计算当前块的行数，处理最后不足32行的边界情况
assign current_rows = (remaining_rows >= HW_ROWS) ? HW_ROWS : remaining_rows;
assign current_cols = (remaining_cols >= HW_COLS) ? HW_COLS : remaining_cols;

// 计算当前块的地址
wire [31:0] current_mi_addr = csr_mi_base + (row_offset_counter * csr_cols * 4) + (tile_cnt * HW_COLS * 4);   //单位为字节数
wire [31:0] current_vi_addr = csr_vi_base + (tile_cnt * HW_COLS * 4); //单位为字节数
wire [31:0] current_vo_addr = csr_vo_base + (row_offset_counter * 4); //单位为字节数

//DMA分块所需寄存器
reg [31:0] dma_bytes_total;       // 当前DMA任务需要传输的总字节数
reg [31:0] dma_bytes_transferred; // 在当前DMA任务中已传输的字节数
reg [31:0] dma_current_src_addr;  // 当前DMA传输块的源地址
reg [31:0] dma_current_dst_addr;  // 当前DMA传输块的目的地址

wire [31:0] dma_bytes_remaining = dma_bytes_total - dma_bytes_transferred;
wire [10:0]  dma_chunk_len;         // 本次DMA传输的长度 (Chunk)

localparam MAX_DMA_LEN = 1024;  //单次最多传输128个浮点数，即512字节
// 动态计算本次小块传输的长度
assign dma_chunk_len = (dma_bytes_remaining >= MAX_DMA_LEN) ? MAX_DMA_LEN : dma_bytes_remaining[10:0];
//======================================================================
//==                  AXI4-Lite Slave Interface Logic                 ==
//======================================================================
//Axi interface state
//Axi_R_or_W read true
reg Axi_busy,Axi_write,Axi_R_or_W;

reg [31:0] rdata_d;

//addr hs
wire ar_enter = s_arvalid & s_arready;
wire aw_enter = s_awvalid & s_awready;

wire r_retire = s_rvalid & s_rready & s_rlast;
wire w_enter  = s_wvalid & s_wready & s_wlast;
wire b_retire = s_bvalid & s_bready;

//only one transaction inflight
assign s_arready = ~Axi_busy & (!Axi_R_or_W| !s_awvalid);
assign s_awready = ~Axi_busy & ( Axi_R_or_W| !s_arvalid);

// Declare FSM state before first reference in ctrl_done.
(* mark_debug = "true" *) reg [4:0] state;
reg [4:0] next_state;

assign ctrl_done = (state == 5'd12) ? 1 : 0;

//outstanding transaction
always@(posedge clock)
    if(~rst_n) Axi_busy <= 1'b0;
    else if(ar_enter|aw_enter) Axi_busy <= 1'b1;
    else if(r_retire|b_retire) Axi_busy <= 1'b0;

//information buffer
reg [4 :0] buf_id;
reg [31:0] buf_addr;


always@(posedge clock)
    if(~rst_n) begin
        Axi_R_or_W  <= 1'b0;
        buf_id      <= 'b0;
        buf_addr    <= 'b0;
    end
    else
    if(ar_enter | aw_enter) begin
        Axi_R_or_W  <= ar_enter;
        buf_id      <= ar_enter ? s_arid   : s_awid   ;
        buf_addr    <= ar_enter ? s_araddr : s_awaddr ;
    end

always@(posedge clock)
    if(~rst_n) Axi_write <= 1'b0;
    else if(aw_enter) Axi_write <= 1'b1;
    else if(ar_enter)  Axi_write <= 1'b0;

always@(posedge clock)
    if(~rst_n) s_wready <= 1'b0;
    else if(aw_enter) s_wready <= 1'b1;
    else if(w_enter & s_wlast) s_wready <= 1'b0;

always@(posedge clock)
    if(~rst_n) begin
        s_rdata  <= 'b0;
        s_rvalid <= 1'b0;
        s_rlast  <= 1'b0;
    end
    else if(Axi_busy & !Axi_write & !r_retire)
    begin
        s_rdata <= rdata_d;
        s_rvalid <= 1'b1;
        s_rlast <= 1'b1; 
    end
    else if(r_retire)
    begin
        s_rvalid <= 1'b0;
        s_rlast  <= 1'b0;
    end

always@(posedge clock)   
    if(~rst_n) s_bvalid <= 1'b0;
    else if(w_enter) s_bvalid <= 1'b1;
    else if(b_retire) s_bvalid <= 1'b0;

assign s_rid   = buf_id;
assign s_bid   = buf_id;
assign s_bresp = 2'b0;
assign s_rresp = 2'b0;
assign fsa_attn_scale = csr_attn_scale;
assign fsa_group_mode = csr_group_mode;

//======================================================================
//==              Core Finite State Machine (FSM)                     ==
//======================================================================
parameter   S_IDLE         = 5'd0,
            S_DMA_VI       = 5'd1,
            S_WAIT_VI_DONE = 5'd2,
            S_LOOP_START   = 5'd3,
            S_DMA_MI_INIT  = 5'd4,
            S_DMA_MI_ISSUE = 5'd5,
            S_DMA_MI_WAIT  = 5'd6,
            S_COMPUTE      = 5'd7,
            S_WAIT_COMPUTE = 5'd8,
            S_DMA_VO       = 5'd9,
            S_WAIT_VO_DONE = 5'd10,
            S_UPDATE_OFFSET = 5'd11,
            S_DONE         = 5'd12,
            S_DMA_VO_INIT  = 5'd13,
            S_ACCUMULATE   = 5'd14,
            S_CHECK_LOOP   = 5'd15,
            // FSA模式状态
            S_FSA_DMA_Q      = 5'd16,
            S_FSA_WAIT_Q     = 5'd17,
            S_FSA_START      = 5'd18,
            S_FSA_WAIT_K     = 5'd19,
            S_FSA_WAIT_V     = 5'd20,
            S_FSA_DMA_O      = 5'd21,
            S_FSA_WAIT_O     = 5'd22,
            // SiLU融合：纯握手状态，不发任何累加器命令（那属于silu_ctrl_fsm那一层）
            S_SILU           = 5'd23,
            // 权重预取：CPU在算rmsnorm/RoPE/SwiGLU时，DMA先把下一次任务的第一块
            // 数据搬进权重SRAM。此时SRAM本就空闲（上一次任务已结束），不需要双缓冲。
            S_PF_ISSUE       = 5'd24,
            S_PF_WAIT        = 5'd25;

// (start_signal/mode_fsa/fsa_num_kv_tiles_w/fsa_tile_idx已在前面声明)

always @(posedge clock or negedge rst_n) begin
    if (!rst_n) state <= S_IDLE;
    else state <= next_state;
end

// SiLU要处理的元素数=本行块的行数（每行一个GEMV输出），尾块不足32行时自动收窄。
//
// 寄存器化而非直接 assign current_rows[5:0]：current_rows 位于
// row_offset_counter → 32位减法 → 比较 → MUX 这条深组合链的末端，同一条链还要喂
// cmd_len（再过DSP乘法）；把它引出成模块输出端口会给这条路径再挂一份fanout。
// 该值只在 S_SILU 被 silu_ctrl_fsm 读取，那时 current_rows 已稳定多拍。
// S_SILU 期间冻结属防御性设计：当前FSM下 row_offset_counter 要到 S_UPDATE_OFFSET
// 才变、本就恒定，但显式冻结可避免将来改FSM时微程序跑一半被改掉元素数。
// 放在这里而非 current_rows 定义处，是因为要用到下面才声明的 state/S_SILU。
reg [5:0] silu_num_elem_r;
always @(posedge clock or negedge rst_n) begin
    if (!rst_n)
        silu_num_elem_r <= 6'd0;
    else if (state != S_SILU)
        silu_num_elem_r <= current_rows[5:0];
end
assign silu_num_elem = silu_num_elem_r;

//======================================================================
//==            权重预取（CPU算rmsnorm/RoPE/SwiGLU时后台搬数据）      ==
//======================================================================
// 思路：一次任务结束后权重SRAM就空闲了，下一次任务的第一块数据完全可以提前搬进来，
// 不需要双缓冲。CPU那边写完CSR立刻返回去算它的，DMA在后台跑。
//
// 命中判定故意做得极简（pf_valid && pf_target==mode_fsa，无任何比较器）：
// 正确性靠"配置一变就作废"保证，而不是靠比对预取参数与实际参数。这样既省掉3个
// 32位比较器（关键路径slack只有0.557ns），又天然自防御——将来若在预取与start之间
// 插进别的硬件调用，那个调用必然写自己的基址寄存器，pf_valid自动清零、安全回退。
reg pf_req;      // 预取请求锁存：REG_PF_CTRL是脉冲型，而next_state是组合逻辑，
                 // 单拍脉冲会被错过，必须锁存到FSM接走为止
reg pf_target;   // 0=GEMV权重首块, 1=FSA的K tile 0
reg pf_valid;    // 预取数据已在SRAM里，下一次任务可直接用

wire pf_cmd_wr = w_enter && (buf_addr[15:0] == `REG_PF_CTRL_ADDR)
                         && s_wdata[`CSR_PF_START_BIT];

// 失效规则1/2：决定"搬什么、搬多少"的CSR被改写，预取的数据就不再对应本次任务。
// GEMV看 MI_BASE/ROWS/COLS，FSA看 K_BASE/HEAD_DIM/NUM_HEADS/KV_STRIDE。
// 不分target一律清——保守且省逻辑，代价只是软件必须遵守"预取后别重复配CSR"。
wire pf_kill_cfg = w_enter &&
     ((buf_addr[15:0] == `REG_MI_BASE_ADDR)   ||
      (buf_addr[15:0] == `REG_ROWS_ADDR)      ||
      (buf_addr[15:0] == `REG_COLS_ADDR)      ||
      (buf_addr[15:0] == `REG_K_BASE_ADDR)    ||
      (buf_addr[15:0] == `REG_HEAD_DIM_ADDR)  ||
      (buf_addr[15:0] == `REG_NUM_HEADS_ADDR) ||
      (buf_addr[15:0] == `REG_KV_STRIDE_ADDR));

// 失效规则3：预取的目标与本次任务模式不符。两种预取共用同一块权重SRAM，
// GEMV任务要用整块、FSA任务的K/V也会覆盖它，任何一方跑起来都让另一方的预取作废。
wire pf_mode_mismatch = (state == S_IDLE) && start_signal && (pf_target != mode_fsa);

// 命中：GEMV看首块（row/tile计数器都还没动），FSA看tile 0。
// head_dim>32要走dual_chunk两次传输，第一版预取不支持，老实走原路径。
wire pf_hit_gemv = pf_valid && !pf_target && !mode_fsa &&
                   (row_offset_counter == 32'd0) && (tile_cnt == 16'd0);
wire pf_hit_fsa_tile0 = pf_valid && pf_target && mode_fsa &&
                        (fsa_tile_idx == 13'd0) && !dual_chunk_mode;

// 失效规则4：首块/tile0已被消费。预取只对第一块有效，后续块仍走正常DMA。
wire pf_consumed = ((state == S_LOOP_START) && pf_hit_gemv) ||
                   ((state == S_FSA_WAIT_K) && pf_hit_fsa_tile0);

// 告诉fsa_ctrl_fsm：tile 0的K已在Input SRAM里，S_ACC_CLEAR不必再等K的DMA。
// 电平型，覆盖"预取命中→K被QK_MAC读完"这整段窗口：预取在fsa_start之前完成，
// 而inner FSM要走过LOAD_Q/CMP_RESET/ACC_CLEAR共十几拍才检查这个条件。
reg fsa_k_preloaded_r;
always @(posedge clock or negedge rst_n) begin
    if (!rst_n)
        fsa_k_preloaded_r <= 1'b0;
    else if (state == S_FSA_WAIT_K && pf_hit_fsa_tile0)
        fsa_k_preloaded_r <= 1'b1;
    // K被消费后撤掉；新任务启动时一并清零，确保这个"数据已就绪"的断言
    // 不会跨任务残留到K尚未到位的下一次S_ACC_CLEAR
    else if (fsa_k_read_done || (state == S_IDLE && start_signal))
        fsa_k_preloaded_r <= 1'b0;
end
assign fsa_k_preloaded = fsa_k_preloaded_r;

// 正在从IDLE进入预取——下面的计数器/FSA参数初始化块要靠它区分"启动任务"和"发起预取"
wire entering_pf = (state == S_IDLE) && (next_state == S_PF_ISSUE);
wire pf_is_fsa   = entering_pf && pf_target;

// 预取用的是当前CSR配置，而软件可能在目标模式的寄存器还没配好时就发预取
// （例如target指向FSA但head_dim/seq_len仍是复位值0）。零尺寸算出的
// block_size/block_count全为0，DMA收到这种命令不会回dma_done，S_PF_WAIT
// 将一直等下去。此时不发DMA也不置pf_valid，静默退回IDLE让任务走正常搬运。
// 与S_IDLE里 fsa_num_kv_tiles_w==0 的非法seq_len保护同属一类兜底。
wire pf_size_invalid = pf_target ? ((csr_head_dim == 32'd0) || (csr_seq_len == 32'd0))
                                 : ((csr_rows     == 32'd0) || (csr_cols    == 32'd0));

// 注：不设"w_mem_rst则失效"这条规则。sram.sv的rst只清读输出寄存器、不清mem内容
// （见sram.sv注释"BRAM has no content reset"），预取的数据不会被冲掉；而S_IDLE在
// start_signal时正好会拉w_mem_rst，若据此清pf_valid，命中判定就永远不成立了。
always @(posedge clock or negedge rst_n) begin
    if (!rst_n) begin
        pf_req    <= 1'b0;
        pf_target <= 1'b0;
        pf_valid  <= 1'b0;
    end else begin
        if (pf_cmd_wr) begin
            pf_req    <= 1'b1;
            pf_target <= s_wdata[`CSR_PF_TARGET_BIT];
        end else if (state == S_PF_ISSUE) begin
            pf_req    <= 1'b0;   // FSM已接走这次请求
        end

        // synopsys translate_off
        // 预取生命周期埋点：SoC级实测FSA侧预取从未命中（ATTN.hw不降反升），
        // 而IP级run_fsa_pf全过——差异只能在软件时序上，靠这三条定位是"没置起"
        // 还是"置起后被谁杀掉"。
        if (fsa_trace_on) begin
            // 发预取那一刻 FSM 在哪、start_signal 是否还压着：S_IDLE 里真任务优先于预取，
            // start 未清则 pf_req 一直排队等不到服务。
            if (pf_cmd_wr)
                $display("[PF_CMD] t=%0t state=%0d start_signal=%0b pf_req=%0b tgt=%0b",
                         $time, state, start_signal, pf_req, s_wdata[`CSR_PF_TARGET_BIT]);
            if (entering_pf)
                $display("[PF_ENTER] t=%0t 进入 S_PF_ISSUE", $time);
            if (pf_kill_cfg && pf_valid)
                $display("[PF_KILL_CFG] t=%0t addr=0x%04h tgt=%0d", $time, buf_addr[15:0], pf_target);
            if ((state == S_PF_WAIT) && dma_done)
                $display("[PF_SET] t=%0t tgt=%0d dual=%0d", $time, pf_target, dual_chunk_mode);
            if (pf_mode_mismatch && pf_valid)
                $display("[PF_KILL_MODE] t=%0t tgt=%0d mode_fsa=%0d", $time, pf_target, mode_fsa);
            if (pf_consumed)
                $display("[PF_HIT] t=%0t tgt=%0d state=%0d", $time, pf_target, state);
        end
        // synopsys translate_on

        if (pf_kill_cfg)
            pf_valid <= 1'b0;
        // head_dim>32的K要拆chunk1/chunk2两次传输，而S_PF_ISSUE只发了chunk1，
        // 搬进来的数据不完整，这种情况不置valid、让任务走原路径完整重搬
        else if ((state == S_PF_WAIT) && dma_done)
            pf_valid <= !(pf_target && dual_chunk_mode);
        else if (pf_consumed || pf_mode_mismatch)
            pf_valid <= 1'b0;
    end
end

always @(posedge clock or negedge rst_n) begin
    if (!rst_n) begin
        row_offset_counter <= 32'h0;
        dma_bytes_transferred <= 32'h0;
        dma_current_src_addr <= 32'h0;
        dma_current_dst_addr <= 32'h0;
        tile_cnt <= 0;
        acc_en <= 1'b0;
        num_tiles_reg <= 1'b0;
        fsa_tile_idx <= 13'd0;
        fsa_mode <= 1'b0;
        fsa_start <= 1'b0;
        fsa_dma_done <= 1'b0;
        fsa_head_dim <= 8'd0;
        fsa_seq_tile_len <= 8'd0;
        fsa_num_kv_tiles <= 8'd0;
        fsa_last_tile_valid <= 8'd0;
        dma_v_sram_bank_sel <= 2'd0;
        dma_o_sram_raddr <= 3'd0;
        fsa_q_bank_cnt <= 2'd0;
        fsa_dma_issued <= 1'b0;
        fsa_k_buf_loaded <= 1'b0;
        fsa_v_buf_loaded <= 1'b0;
        fsa_k_read_done_q <= 1'b0;
        fsa_v_read_done_q <= 1'b0;
        // 这一条以前漏在复位表外。仿真上没影响（它在 S_IDLE→非 IDLE 那拍就被清零，
        // 真正被用到时值已经是对的），但综合后果很实在：一个身处
        // `always @(posedge clock or negedge rst_n)` 却不在复位分支里赋值的寄存器，
        // Vivado 只能用"复位期间保持原值"来实现它 —— 于是生成一个 LDC 锁存器，
        // 并由组合逻辑去驱动它的门控端。全设计仅有的一条 gated clock
        // （DRC PDRC-153）就是它，组合驱动的时钟网络有毛刺风险且不被 STA 分析，
        // 属于"仿真看不见、只在板上发作"的那一类。补上复位即可消掉整个结构。
        fsa_k_chunk_sel <= 1'b0;

    end else begin
        if (state == S_DMA_MI_INIT) begin
            num_tiles_reg      <= (csr_cols + HW_COLS - 1) / HW_COLS;
            dma_bytes_transferred <= 32'h0; // 初始化DMA传输计数器
            dma_current_src_addr <= current_mi_addr; // 初始化源地址
        end 
        else if ((state == S_DMA_MI_WAIT) && (next_state == S_DMA_MI_ISSUE)) begin  //第一个信号传输完毕
            dma_bytes_transferred <= dma_bytes_transferred + dma_chunk_len;
            // dma_current_src_addr <= dma_current_src_addr + dma_chunk_len;   //TODO 开始地址
        end

        // if (state == S_WAIT_COMPUTE) begin
        //     // 等待计算完成
        //     if (mac_done) begin
        //         mem_rst <= 1'b1;    // 计算完成后复位内存
        //     end
        // end

        if (state == S_ACCUMULATE) begin
            acc_en <= 1'b1; // 开始累加
        end

        if (state == S_CHECK_LOOP) begin
            if (tile_cnt < num_tiles_reg - 1) begin
                tile_cnt <= tile_cnt + 1; // 增加块计数器
            end else begin
                tile_cnt <= 0; // 重置块计数器
            end
        end

        if (state == S_DMA_VO_INIT) begin   //1次即可输出完毕
            dma_current_dst_addr <= current_vo_addr; // 输出向量的地址
        end

        if (state == S_IDLE && next_state != S_IDLE) begin
            // 从IDLE启动新任务、或发起预取时，清零计数器。
            // 预取时FSA相关配置必须按pf_target决定而不是mode_fsa：那一刻软件还没写
            // REG_CTRL的start/mode位，csr_ctrl里是上一次任务的遗留值。若照抄mode_fsa，
            // 预取FSA的K会被当成GEMV权重按行主序写进SRAM，数据全部错位。
            row_offset_counter <= 32'h0;
            fsa_tile_idx <= 13'd0;
            fsa_mode <= entering_pf ? pf_target : mode_fsa;
            // GEMV预取会让首块跳过S_DMA_MI_INIT，而num_tiles_reg正是在那里算的，
            // S_CHECK_LOOP又要靠它判断tile边界——必须在这里补上，否则多tile矩阵
            // 会拿上一次任务的tile数去判循环，提前退出或多跑一轮
            if (entering_pf && !pf_target)
                num_tiles_reg <= (csr_cols + HW_COLS - 1) / HW_COLS;
            fsa_start <= 1'b0;
            fsa_dma_done <= 1'b0;
            fsa_k_chunk_sel <= 1'b0;
            if (mode_fsa || pf_is_fsa) begin
                fsa_head_dim <= csr_head_dim[7:0];
                fsa_seq_tile_len <= fsa_seq_tile_len_w;
                fsa_num_kv_tiles <= fsa_num_kv_tiles_w;
                // last_tile_valid: seq_len % seq_tile_len（行数取余，不是head_dim），0表示满tile
                fsa_last_tile_valid <= csr_seq_len[7:0] % fsa_seq_tile_len_w;
            end
        end else if (state == S_UPDATE_OFFSET) begin
            row_offset_counter <= row_offset_counter + current_rows;
            acc_en <= 1'b0;
        end

        // FSA模式控制信号
        if (state == S_FSA_START) begin
            fsa_start <= 1'b1;
        end else if (state != S_FSA_START && fsa_start) begin
            fsa_start <= 1'b0; // 1拍脉冲
        end

        // FSA Q bank加载：每次DMA完成后递增bank_sel
        // 4×8: 循环4次，bank=0,1,2,3
        // 2×16: 循环2次，bank=0,2
        // 1×32: 循环1次，bank=0
        if (state == S_IDLE && next_state != S_IDLE && mode_fsa) begin
            fsa_q_bank_cnt <= 2'd0;
            dma_v_sram_bank_sel <= 2'd0;
            fsa_dma_issued <= 1'b0;
        end else if (state == S_FSA_WAIT_Q && dma_done) begin
            if (fsa_q_bank_cnt < num_active_heads - 1) begin
                fsa_q_bank_cnt <= fsa_q_bank_cnt + 2'd1;
                dma_v_sram_bank_sel <= (fsa_q_bank_cnt + 2'd1) * q_bank_step;
            end
        end

        // chunk1的K-DMA刚完成、且还要发chunk2：state不变(仍是S_FSA_WAIT_K)，
        // 必须额外清一次fsa_dma_issued，否则"!fsa_dma_issued"门控永远不会再打开
        if (state == S_FSA_WAIT_K && dual_chunk_mode && !fsa_k_chunk_sel &&
            fsa_dma_issued && dma_done)
            fsa_k_chunk_sel <= 1'b1;
        else if (state == S_FSA_WAIT_K && next_state == S_FSA_WAIT_V)
            fsa_k_chunk_sel <= 1'b0;  // 进入V前复位，给下一个tile的chunk1用

        // fsa_dma_issued: 进入新FSA状态时清零，DMA命令被接受后置1
        // S_FSA_DMA_O中用作预热标志（第1拍=0预热SRAM，第2拍=1发DMA命令）
        if (state != next_state) begin
            fsa_dma_issued <= 1'b0;
        end else if (state == S_FSA_WAIT_K && dual_chunk_mode && !fsa_k_chunk_sel &&
                     fsa_dma_issued && dma_done) begin
            fsa_dma_issued <= 1'b0;  // chunk1完成，立刻为chunk2的DMA请求重新开门
        end else if ((state == S_FSA_WAIT_K || state == S_FSA_WAIT_V) && cmd_valid && cmd_ready) begin
            fsa_dma_issued <= 1'b1;
        end else if (state == S_FSA_DMA_O && !fsa_dma_issued) begin
            fsa_dma_issued <= 1'b1; // 预热1拍后允许发DMA命令
        end

        // FSA DMA done脉冲：只在fsa_dma_issued=1且dma_done时才pulse
        // tile_idx在WAIT_V完成时递增（WAIT_V固定处理V DMA）
        if ((state == S_FSA_WAIT_K || state == S_FSA_WAIT_V) && fsa_dma_issued && dma_done) begin
            fsa_dma_done <= 1'b1;
            if (state == S_FSA_WAIT_V)
                fsa_tile_idx <= fsa_tile_idx + 13'd1;
            // synopsys translate_off
            if (fsa_trace_on) begin
                if (state == S_FSA_WAIT_V)
                    $display("[CB_DMA_DONE_V] t=%0t tile=%0d state=%0d", $time, fsa_tile_idx, state);
                else
                    $display("[CB_DMA_DONE_K] t=%0t tile=%0d state=%0d", $time, fsa_tile_idx, state);
            end
            // synopsys translate_on
        end else if (dma_done && !fsa_dma_issued && (state == S_FSA_WAIT_K || state == S_FSA_WAIT_V)) begin
            // synopsys translate_off
            $display("[CB_DMA_DONE_MISSED!] t=%0t state=%0d issued=%0d tile=%0d",
                     $time, state, fsa_dma_issued, fsa_tile_idx);
            // synopsys translate_on
            fsa_dma_done <= 1'b0;
        end else begin
            fsa_dma_done <= 1'b0;
        end

        // ---- K/V缓冲区装载标志（地址分区的核心状态）----
        // 分区后K和V各占Input SRAM的一段地址，互不覆盖，于是"能不能搬下一份"
        // 只取决于自己那份被读完没有，与对方无关：
        //   loaded=1 → SRAM里躺着一份还没被消费的数据，不能再往里写
        //   loaded=0 → 缓冲区空闲，可以发DMA
        // 它同时是喂给inner的"数据已就绪"电平。必须是电平不是脉冲——inner可能
        // 在DMA完成时还停在别的状态，脉冲会被整个错过（预取那轮的bug 4就是这个）。
        //
        // 清零用read_done的**上升沿**而不是电平：fsa_k_read_done是inner里的寄存器
        // 电平，从QK_MAC读完一直保持到inner进S_DMA_K/S_ACC_CLEAR才落，而下一tile的
        // K DMA很可能在它还高着的时候就完成了——用电平清会把刚到的新数据judge成
        // "已消费"，直接读到旧K。上升沿每tile只出现一次，没有这个问题。
        fsa_k_read_done_q <= fsa_k_read_done;
        fsa_v_read_done_q <= fsa_v_read_done;

        if (state == S_IDLE && next_state != S_IDLE) begin
            fsa_k_buf_loaded <= 1'b0;
            fsa_v_buf_loaded <= 1'b0;
        end else begin
            // 置位优先于清零：两者同拍时，DMA完成说的是刚到的这一份，
            // read_done说的是上一份，新数据应当赢
            if (state == S_FSA_WAIT_K && fsa_dma_issued && dma_done &&
                !(dual_chunk_mode && !fsa_k_chunk_sel))
                fsa_k_buf_loaded <= 1'b1;   // dual_chunk下chunk1不算齐，要等chunk2
            else if (state == S_FSA_WAIT_K && pf_hit_fsa_tile0)
                fsa_k_buf_loaded <= 1'b1;   // tile0的K由权重预取搬好，没有真DMA可等
            else if (fsa_k_read_done && !fsa_k_read_done_q)
                fsa_k_buf_loaded <= 1'b0;   // 被QK_MAC读完

            if (state == S_FSA_WAIT_V && fsa_dma_issued && dma_done)
                fsa_v_buf_loaded <= 1'b1;
            else if (fsa_v_read_done && !fsa_v_read_done_q)
                fsa_v_buf_loaded <= 1'b0;   // 被PV_MAC读完
        end

    end
end

always @(*) begin
    // Default assignments
    next_state   = state;
    cmd_valid    = 1'b0;
    cmd_src_addr = dma_current_src_addr;
    cmd_dst_addr = dma_current_dst_addr;
    cmd_rw       = 1'b0; // Default to read
    cmd_burst    = 2'b01; // INCR
    cmd_len      = dma_chunk_len;   //TODO: 目前传输32字节,8个浮点
    mac_start    = 1'b0;
    mac_access_mode = 1'b0; // mac_access_mode 0的时候进行计算操作并将结果写到ram中，以及从主存写到ram中，1的时候从outram中读数据，将数据写入2个buffer
    dma_target_sram = 2'b00; // 00=Vec
    fsa_dma_is_v    = 1'b0;  // 默认搬K（列主序）；V阶段在S_FSA_WAIT_V拉高
    dma_bytes_total = 32'h0; // 初始化DMA总字节数
    w_mem_rst = 1'b0; // 内存复位信号
    v_mem_rst = 1'b0; // 内存复位信号
    cmd_block_size = 0;
    cmd_block_count = 0;
    cmd_stride = 0;
    cmd_padding_en = 1'b0; // 不需要填充
    cmd_padding_words = 0; // 不需要填充
    fsa_k_dma_col_width = csr_head_dim[7:0]; // 默认=现状行为，S_FSA_WAIT_K按chunk覆写
    silu_start = 1'b0; // 仅S_SILU拉高

    case (state)
        S_IDLE: begin
            if (start_signal) begin
                w_mem_rst = 1'b1;
                v_mem_rst = 1'b1;
                // 非法seq_len保护：seq_len=0（或4096等12-bit回绕成0）时num_kv_tiles=0，
                // 无tile可跑。若进FSA流程会在S_FSA_WAIT_K死锁（门槛fsa_tile_idx<num_tiles
                // 恒假、fsa_done永不来）。此处直接跳S_DONE，拉done退出而非HANG。
                if (mode_fsa && fsa_num_kv_tiles_w == 13'd0)
                    next_state = S_DONE;
                else if (mode_fsa)
                    next_state = S_FSA_DMA_Q;
                else
                    next_state = S_DMA_VI;
            end else if (pf_req) begin
                // 真任务优先于预取：start_signal是电平型，只要它高就走正常流程，
                // 预取请求继续在pf_req里等着（下次回IDLE再处理）
                next_state = S_PF_ISSUE;
            end
        end
        // 向量加载仅在开始的时候加载一次即可
        S_DMA_VI: begin
            mac_access_mode = 1'b1; // 取数据
            dma_target_sram = 2'b00; // 00=Vec
            cmd_valid = 1'b1;
            cmd_src_addr = current_vi_addr; //ddr中的地址
            cmd_rw = 1'b0;  //read
            cmd_len = current_cols * 4; // cols个32位浮点数
            cmd_block_size = current_cols * 4; // cols个32位浮点数
            cmd_block_count = 0; // 计算需要多少个块
            cmd_stride = 0; // 目前不需要步长
            // 最后tile不足64时零填充，防止SRAM残留旧数据
            // 注意补零字数本身不必是偶数：DMA 打包器要求的是"块内真实字 + 补零字"之和为偶，
            // 而这里补的目标 HW_COLS=64 恒为偶数，和自然成立。强行把 padding 取整到偶数
            // 反而会让总字数变奇（曾导致 TC_Col65 每块多写一个 entry、溢进下一 bank）。
            if (current_cols < HW_COLS) begin
                cmd_padding_en = 1'b1;
                cmd_padding_words = HW_COLS - current_cols;
            end else begin
                cmd_padding_en = 1'b0;
                cmd_padding_words = 0;
            end
            if (cmd_ready) begin //dma控制器准备
                next_state = S_WAIT_VI_DONE;
            end
        end
        S_WAIT_VI_DONE: begin
            mac_access_mode = 1'b1; // 取数据
            dma_target_sram = 2'b00; // 00=Vec
            if (dma_done) begin //remove error
                next_state = S_LOOP_START; // 进入循环处理状态
            end
        end

        S_LOOP_START: begin // 每次循环的起点
            if (row_offset_counter >= csr_rows) begin
                next_state = S_DONE; // 所有行都已处理完毕，任务完成
            end else if (pf_hit_gemv) begin
                // 预取命中：首块权重已经躺在SRAM里，直接开算，跳过整段
                // S_DMA_MI_INIT/ISSUE/WAIT。只有首块能命中，后续块照常搬
                next_state = S_COMPUTE;
            end else begin
                next_state = S_DMA_MI_INIT; // 还有行需要处理，开始加载下一个权重块
            end
        end

        S_DMA_MI_INIT: begin
            mac_access_mode = 1'b1; // 取数据
            dma_target_sram = 2'b01; // 01=Weight
            dma_bytes_total = current_rows * current_cols * 4; // 当前块的总字节数
            // dma_current_src_addr = current_mi_addr;
            next_state = S_DMA_MI_ISSUE; // 进入DMA传输状态
        end
        S_DMA_MI_ISSUE: begin
            mac_access_mode = 1'b1; // 取数据
            dma_target_sram = 2'b01; // 01=Weight
            dma_bytes_total = current_rows * current_cols * 4;
            
            cmd_valid = 1'b1;
            cmd_rw = 1'b0; // Read from DDR
                
            if (csr_cols > 64) begin
                cmd_block_size = current_cols * 4; // 当前块的总字节数
                cmd_block_count = HW_ROWS-1; // 计算需要多少个块
                cmd_stride = csr_cols * 4; // 目前不需要步长
                if (current_cols < HW_COLS) begin
                    cmd_padding_en = 1'b1; // 需要填充
                    // 补到 num_tiles×64（偶），与真实字数之和恒为偶，无需再取整
                    cmd_padding_words = num_tiles_reg * HW_COLS - csr_cols; // 需要填充的字数
                end
                else begin
                    cmd_padding_en = 1'b0; // 不需要填充
                    cmd_padding_words = 0; // 不需要填充
                end
            end else begin
                // cols <= 64 时按软件的紧密 row-major 布局搬运，不再假设每行物理补到 64 列。
                //
                // 每块读取的字数向上取整到偶数：DMA 加宽后一拍交付两个 word，块字数为奇
                // 时打包器会在块尾剩一个孤字。收尾需要额外一拍，但突发之间是背靠背的
                // （实测末拍 n=2 且手里攒着 1 个 = 3 个 word 要发 2 个 entry，下一拍就是
                // 新块首拍，没有空闲拍），**在打包器里补不了**。从源头把块凑成偶数最省事。
                //
                // 多读的那一个 word 是下一行的首元素（紧密布局），或最后一行之后的 4 字节；
                // 读操作对内存无副作用，且它落在 SRAM 里超出 current_cols 的那一列上、
                // 不参与计算（与 arlen 向上取整多读半拍是同一个道理）。
                // 偶数列宽时 ((cols+1)&~1) == cols，与改动前逐位一致。
                cmd_block_size = ((current_cols + 1) & ~32'd1) * 4;
                cmd_block_count = current_rows - 1; // 按当前行块深度逐行搬运
                cmd_stride = current_cols * 4; // 紧密布局，行间步长等于真实列宽
                cmd_padding_en = 1'b0; // 不需要填充
                cmd_padding_words = 0; // 不需要填充
            end

            if (cmd_ready) next_state = S_DMA_MI_WAIT; // 等待DMA传输完成
        end
        S_DMA_MI_WAIT: begin
            mac_access_mode = 1'b1; // 取数据
            dma_target_sram = 2'b01;
            dma_bytes_total = current_rows * csr_cols * 4;
            // cmd_len = current_rows * csr_cols * 4; // 128字节，32个浮点数
            if (dma_done) begin //remove error
                next_state = S_COMPUTE;
            end
        end
        S_COMPUTE: begin
            dma_target_sram = 2'b01; // TODO 待修改
            mac_access_mode = 1'b0; // 计算模式
            mac_start = 1'b1; 
            next_state = S_WAIT_COMPUTE;
        end
        S_WAIT_COMPUTE: begin
            mac_start = 1'b1; // 保持os_start为高，PE阵列持续计算
            if (mac_done && csr_cols > 64) begin
                w_mem_rst = 1'b1; // 计算完成后复位内存
                v_mem_rst = 1'b1; // 计算完成后复位内存
                next_state = S_ACCUMULATE;
            end
            else if (mac_done) begin
                // mem_rst = 1'b1; // 计算完成后复位内存
                w_mem_rst = 1'b1; // 计算完成后复位内存
                //由于需要复用，不清除vmem
                // 单tile路径：结果已是最终值，可以过激活
                next_state = silu_en ? S_SILU : S_DMA_VO_INIT;
            end
        end
        S_ACCUMULATE: begin
            next_state = S_CHECK_LOOP; // 累加完成后进入输出状态
        end
        S_CHECK_LOOP: begin
            // 检查是否需要继续循环处理
            // 多tile路径：只有最后一个tile累加完，结果才是最终值，此时才允许过激活；
            // 中间部分和过激活会得到完全错误的结果
            if (tile_cnt >= num_tiles_reg - 1) next_state = silu_en ? S_SILU : S_DMA_VO_INIT;
            else next_state = S_DMA_VI;
        end

        S_SILU: begin
            // 纯握手：拉起silu_start，等mac_top_v2内silu_ctrl_fsm跑完7步微程序×
            // 所有地址。本状态不发任何累加器命令——那是silu_ctrl_fsm那一层的职责。
            silu_start = 1'b1;
            if (silu_done) next_state = S_DMA_VO_INIT;
        end

        // ============================================================
        // 权重预取：把下一次任务的第一块数据提前搬进权重SRAM。
        // 此时SRAM本就空闲（上一次任务已结束），不需要双缓冲。
        // 两种target的DMA参数各自照抄正常路径的算法，不新写地址计算。
        // ============================================================
        S_PF_ISSUE: begin
            mac_access_mode = 1'b1;   // 取数据
            dma_target_sram = 2'b01;  // 01=Weight（GEMV权重与FSA的K都进这块SRAM）
            cmd_valid       = !pf_size_invalid;  // 尺寸非法就别发这条命令
            cmd_rw          = 1'b0;   // read
            // CB_top_v2的DMA写地址计数器(dma_w_bank_sel_cnt/dma_col_cnt/
            // dma_group_base等)只在 CB_done||w_mem_rst 时归零，而预取路径
            // S_IDLE→S_PF_ISSUE→S_PF_WAIT→S_IDLE 不经过这两者，需在此显式归零，
            // 否则连续两次预取的第二次会接着上一次的终值写、数据整体错位。
            // 本状态仅发命令、DMA数据尚未回流，拉rst不会丢写；sram.sv的rst
            // 也只清读输出寄存器，不动mem内容。
            w_mem_rst       = 1'b1;
            if (pf_target) begin
                // FSA的K tile 0：照S_FSA_WAIT_K的head_dim<=32分支，tile_idx恒0。
                // head_dim>32要拆chunk1/chunk2两次传输，第一版不支持（见S_PF_WAIT）
                cmd_src_addr        = csr_k_base;
                cmd_len             = csr_head_dim * csr_head_dim * num_kv_heads * 4;
                cmd_block_size      = csr_head_dim * 4;
                cmd_block_count     = fsa_kv_block_count;
                cmd_stride          = csr_head_dim * 4;
                fsa_k_dma_col_width = csr_head_dim[7:0];
            end else begin
                // GEMV权重首块：照S_DMA_MI_ISSUE。此刻row_offset_counter/tile_cnt
                // 已在进入本状态时被清零，current_rows/current_cols即首块的尺寸
                cmd_src_addr = csr_mi_base;
                if (csr_cols > 64) begin
                    cmd_block_size  = current_cols * 4;
                    cmd_block_count = HW_ROWS - 1;
                    cmd_stride      = csr_cols * 4;
                    if (current_cols < HW_COLS) begin
                        cmd_padding_en    = 1'b1;
                        cmd_padding_words = num_tiles_reg * HW_COLS - csr_cols;
                    end
                end else begin
                    // 与 S_DMA_MI_ISSUE 的同名分支**必须逐字一致**：预取搬的就是那一块
                    // 权重，只是提前搬。块字数同样要向上取整到偶数（见那边的长注释），
                    // 漏改这一处的表现是"不开预取全对、开了预取窄奇数列出错"
                    // （实测 pf_mode=1 cols=7 时 31 处数值错，而 gemv_random 同样的
                    // cols=15/29/53 全对）。改一处必须回头看另一处。
                    cmd_block_size  = ((current_cols + 1) & ~32'd1) * 4;
                    cmd_block_count = current_rows - 1;
                    cmd_stride      = current_cols * 4;
                end
            end
            // 尺寸非法：静默退回IDLE，pf_valid保持0，任务照常走正常搬运
            if (pf_size_invalid)   next_state = S_IDLE;
            else if (cmd_ready)    next_state = S_PF_WAIT;
        end
        S_PF_WAIT: begin
            mac_access_mode = 1'b1;
            dma_target_sram = 2'b01;
            if (pf_target) fsa_k_dma_col_width = csr_head_dim[7:0];
            // 必须等DMA传完才走：中途退出会在SRAM里留下半块数据，且未完成的AXI事务
            // 会和后续正常DMA命令打架。start_signal即使此刻到了也让它等——等完回IDLE
            // 时pf_valid刚好置位，正常流程接着就能命中，一拍不浪费。
            if (dma_done) next_state = S_IDLE;
        end
        S_DMA_VO_INIT: begin    //从out sram写到主存
            mac_access_mode = 1'b1; // 取数据
            dma_target_sram = 2'b10; // 10=Output
            cmd_len      = current_rows * 4; // 当前块的总字节数
            // 等2拍让Output SRAM读出数据锁存到buffer后再发DMA命令
            next_state = S_DMA_VO;
        end
        S_DMA_VO: begin
            mac_access_mode = 1'b1; // 输出模式
            dma_target_sram = 2'b10; // 10=Output
            cmd_valid    = 1'b1;
            // cmd_dst_addr = current_vo_addr;
            cmd_len      = current_rows * 4; // 输出行数 * 4字节
            cmd_rw       = 1'b1; // Write to DDR
            if (cmd_ready) begin
                next_state = S_WAIT_VO_DONE;
            end
        end
        S_WAIT_VO_DONE: begin
            mac_access_mode = 1'b1; // 保持输出模式，buffer持续锁存
            dma_target_sram = 2'b10; // 10=Output
            cmd_rw       = 1'b1; // Write to DDR
            if (dma_done) begin //TODO 增加循环判断
                next_state = S_UPDATE_OFFSET;
            end
        end

        S_UPDATE_OFFSET: begin
            if (csr_cols > 64) begin
                next_state = S_DMA_VI; // 重新加载向量
            end else begin
                next_state = S_LOOP_START; // 返回循环起点
            end
        end

        S_DONE: begin
            if (!start_signal) begin
                next_state = S_IDLE;
            end
        end

        // ============================================================
        // FSA模式状态
        // ============================================================
        S_FSA_DMA_Q: begin
            // DMA搬Q到Vector SRAM（按num_active_heads加载）
            mac_access_mode = 1'b1;
            dma_target_sram = 2'b00; // Vec
            cmd_valid = 1'b1;
            cmd_src_addr = csr_q_base;
            cmd_rw = 1'b0;
            cmd_len = csr_head_dim * num_active_heads * 4; // num_heads × head_dim个fp32
            cmd_block_size = csr_head_dim * num_active_heads * 4; // 单block传输
            cmd_block_count = 0;
            cmd_stride = 0;
            if (cmd_ready)
                next_state = S_FSA_WAIT_Q;
        end
        S_FSA_WAIT_Q: begin
            mac_access_mode = 1'b1;
            dma_target_sram = 2'b00;
            if (dma_done)
                next_state = S_FSA_START;
        end
        S_FSA_START: begin
            // 启动fsa_ctrl_fsm
            next_state = S_FSA_WAIT_K;
        end
        S_FSA_WAIT_K: begin
            // K DMA完全自主：首tile进入即发，后续tile等fsa_v_read_done
            // head_dim>32时拆两次发：chunk1(前32列，无padding)，chunk2(后
            // fsa_chunk2_width列，偏移128字节，padding补到32)。fsa_k_dma_col_width
            // 告诉CB_top_v2.sv这次DMA实际传了多少列，驱动dma_col_cnt换行——
            // 不能让它直接读全局fsa_head_dim，否则chunk1只传32列时计数器还在
            // 等(head_dim-32)列才换行，数据会写错地址。
            // chunk2固定填32（不是fsa_chunk2_width！）：DMA硬件的padding机制会在
            // chunk2_width个真实词之后，从同一个写口紧接着再送(32-chunk2_width)个
            // 补零词，一行实际写32次，不是chunk2_width次——换行边界必须用32，否则
            // 真实词和补零词会被错误拆成两行，且都只写进bank0~(chunk2_width-1)，
            // bank(chunk2_width)~31永远没被写到
            mac_access_mode = 1'b1;
            dma_target_sram = 2'b01;
            fsa_k_dma_col_width = dual_chunk_mode ? 8'd32 : csr_head_dim[7:0];
            if (fsa_done) begin
                next_state = S_FSA_DMA_O;
            end else if (pf_hit_fsa_tile0) begin
                // 预取命中：tile 0的K已经在SRAM里，不发DMA直接进V阶段。
                // 下面的fsa_dma_done会补一拍伪done，让fsa_ctrl_fsm的S_ACC_CLEAR
                // 放行（它等的是dma_done||k_dma_done_q，真DMA早在S_PF_WAIT就完了，
                // 那时内部FSM还没启动、锁存不到）。pf_consumed同拍清pf_valid，
                // 所以这个分支只成立一拍，后续tile照常走自主DMA
                next_state = S_FSA_WAIT_V;
            end else if (!fsa_dma_issued) begin
                // 分区模式：K只等自己那块缓冲被QK_MAC读完（fsa_k_buf_loaded落），
                // 与V无关。这正是收益来源——原来要等tile尾部的fsa_v_read_done，
                // K的搬运只能排在上一tile算完之后、全程暴露；现在QK_MAC一读完就能发，
                // 与本tile剩下的EXP2/ROWSUM/PV_MAC重叠。
                //
                // 非分区(dual_chunk)保持原判据：fsa_v_read_done是瞬时脉冲(inner FSM
                // 离开S_PV_MAC就掉0)，tile_idx>0时chunk1的请求能蹭上这个脉冲（紧接上一
                // tile的WAIT_V完成），但chunk2要等chunk1完整DMA传输完才发，那时脉冲早已
                // 消失——必须额外用fsa_k_chunk_sel旁路：它为1说明这个tile的K阶段已经
                // "开过门"（chunk1已发出），chunk2不该被同一个门槛二次拦截，否则永久卡住
                if ((fsa_partition_en ? !fsa_k_buf_loaded
                                      : (fsa_tile_idx == 0 || fsa_v_read_done || fsa_k_chunk_sel))
                    && fsa_tile_idx < fsa_num_kv_tiles) begin
                    cmd_valid = 1'b1;
                    cmd_rw = 1'b0;
                    // GQA：本趟只读 num_kv_heads 份 K（原 num_active_heads），少读的靠 CB_top fanout 补齐。
                    // cmd_len 是写通路参数（读通路实际用 block_size/count/stride），此处同步保持语义一致。
                    cmd_len = csr_head_dim * csr_head_dim * num_kv_heads * 4;
                    if (dual_chunk_mode && !fsa_k_chunk_sel) begin
                        // chunk1：前32维，列宽固定32，不需要padding
                        // dual_chunk 仅 1×32（num_kv_heads 恒=1），fsa_kv_block_count=1×32-1=31，与原值一致
                        cmd_src_addr = csr_k_base + fsa_tile_idx * csr_kv_stride;
                        cmd_block_size = 9'd32 * 4;
                        cmd_block_count = fsa_kv_block_count;
                        cmd_stride = csr_head_dim * 4;
                    end else if (dual_chunk_mode && fsa_k_chunk_sel) begin
                        // chunk2：后fsa_chunk2_width维，偏移128字节(=32列×4字节)，
                        // 列数不足32时padding补零到32，凑齐PE阵列需要的宽度
                        cmd_src_addr = csr_k_base + fsa_tile_idx * csr_kv_stride + 32'd128;
                        cmd_block_size = {1'b0, fsa_chunk2_width} * 4;
                        cmd_block_count = fsa_kv_block_count;
                        cmd_stride = csr_head_dim * 4;
                        cmd_padding_en = (fsa_chunk2_width < 8'd32);
                        cmd_padding_words = 8'd32 - fsa_chunk2_width;
                    end else begin
                        // head_dim<=32：GQA 时 block_count=num_kv_heads×seq_tile_len-1（<31），
                        // 只搬 num_kv_heads 份 → DDR 读带宽真正下降的落点
                        cmd_src_addr = csr_k_base + fsa_tile_idx * csr_kv_stride;
                        cmd_block_size = csr_head_dim * 4;
                        cmd_block_count = fsa_kv_block_count;
                        cmd_stride = csr_head_dim * 4;
                    end
                    // synopsys translate_off
                    if (fsa_trace_on)
                        $display("[CB_ACCEPT_K] t=%0t tile=%0d chunk_sel=%0d src=0x%08x",
                                 $time, fsa_tile_idx, fsa_k_chunk_sel, cmd_src_addr);
                    // synopsys translate_on
                end
            end else if (fsa_dma_issued) begin
                // chunk1完成后(dual模式)留在本状态发chunk2，不前进到WAIT_V
                if (dma_done && !(dual_chunk_mode && !fsa_k_chunk_sel))
                    next_state = S_FSA_WAIT_V;
            end
        end
        S_FSA_WAIT_V: begin
            // 分区模式：V只等自己那块缓冲被PV_MAC读完（fsa_v_buf_loaded落），与K无关；
            // tile 0时它复位为0，V可以在K还在被QK_MAC读的时候就搬进来。
            // 非分区(dual_chunk)保持原判据"看到fsa_k_read_done即发V"——那时V写的
            // 是K同一片地址，必须等K被读完才敢覆盖。
            mac_access_mode = 1'b1;
            dma_target_sram = 2'b01;
            fsa_dma_is_v    = 1'b1;  // 搬V：DMA写逻辑恢复行主序（V不转置）
            if (fsa_done) begin
                next_state = S_FSA_DMA_O;
            end else if (!fsa_dma_issued) begin
                if (fsa_partition_en ? !fsa_v_buf_loaded : fsa_k_read_done) begin
                    cmd_valid = 1'b1;
                    cmd_src_addr = csr_v_base + fsa_tile_idx * csr_kv_stride;
                    cmd_rw = 1'b0;
                    // GQA：只读 num_kv_heads 份唯一 V，硬件 fanout 到各 Q 组
                    cmd_len = csr_head_dim * csr_head_dim * num_kv_heads * 4;
                    cmd_block_size = csr_head_dim * 4;
                    cmd_block_count = fsa_kv_block_count;
                    cmd_stride = csr_head_dim * 4;
                    // synopsys translate_off
                    if (fsa_trace_on)
                        $display("[CB_ACCEPT_V] t=%0t tile=%0d src=0x%08x",
                                 $time, fsa_tile_idx, csr_v_base + fsa_tile_idx * csr_kv_stride);
                    // synopsys translate_on
                end
            end else if (fsa_dma_issued) begin
                if (dma_done)
                    next_state = S_FSA_WAIT_K;
            end
        end
        S_FSA_DMA_O: begin
            // DMA写回Output SRAM到DDR（4 bank × head_dim深 × 4字节）
            // 第一拍预热SRAM读（fsa_dma_issued=0），第二拍发DMA命令
            mac_access_mode = 1'b1;
            dma_target_sram = 2'b10; // Out
            cmd_dst_addr = csr_o_base;
            cmd_rw = 1'b1; // Write to DDR
            cmd_len = csr_head_dim * num_active_heads * 4; // num_heads × head_dim个fp32
            if (fsa_dma_issued) begin
                cmd_valid = 1'b1;
                if (cmd_ready)
                    next_state = S_FSA_WAIT_O;
            end
        end
        S_FSA_WAIT_O: begin
            mac_access_mode = 1'b1;
            dma_target_sram = 2'b10;
            cmd_rw = 1'b1;
            if (dma_done)
                next_state = S_DONE;
        end

        default: next_state = S_IDLE;
    endcase
end

//======================================================================
//==                       CSR Read/Write Logic                       ==
//======================================================================

// --- CSR Status Updates ---
always @(posedge clock or negedge rst_n) begin
    if (!rst_n) begin
        csr_status <= 32'h0;
    end else begin
        // Update BUSY bit
        csr_status[`CSR_STATUS_BUSY_BIT] <= (state != S_IDLE);
        // 预取状态镜像到RO的STATUS里，供软件/UVM观测命中与否（触发寄存器本身是WO）
        csr_status[`CSR_STATUS_PF_VALID_BIT] <= pf_valid;
        csr_status[`CSR_STATUS_PF_TGT_BIT]   <= pf_target;

        // Set DONE bit
        if ((state == S_DONE) && (start_signal == 1)) csr_status[`CSR_STATUS_DONE_BIT] <= 1'b1;

        // Clear sticky DONE bit when CPU writes to CTRL register
        if (w_enter && buf_addr[15:0] == `REG_CTRL_ADDR) begin
            csr_status[`CSR_STATUS_DONE_BIT]     <= 1'b0;
        end
    end
end

// --- CSR Read Mux ---
always @(*) begin
    case(buf_addr[15:0])
        `REG_CTRL_ADDR     : rdata_d = csr_ctrl;
        `REG_STATUS_ADDR   : rdata_d = csr_status;
        `REG_ERR_CODE_ADDR : rdata_d = csr_err_code;
        `REG_VI_BASE_ADDR  : rdata_d = csr_vi_base;
        `REG_MI_BASE_ADDR  : rdata_d = csr_mi_base;
        `REG_VO_BASE_ADDR  : rdata_d = csr_vo_base;
        `REG_ROWS_ADDR     : rdata_d = csr_rows;
        `REG_COLS_ADDR     : rdata_d = csr_cols;
        `REG_Q_BASE_ADDR   : rdata_d = csr_q_base;
        `REG_K_BASE_ADDR   : rdata_d = csr_k_base;
        `REG_V_BASE_ADDR   : rdata_d = csr_v_base;
        `REG_O_BASE_ADDR   : rdata_d = csr_o_base;
        `REG_HEAD_DIM_ADDR : rdata_d = csr_head_dim;
        `REG_SEQ_LEN_ADDR  : rdata_d = csr_seq_len;
        `REG_KV_STRIDE_ADDR: rdata_d = csr_kv_stride;
        `REG_NUM_HEADS_ADDR: rdata_d = csr_num_heads;
        `REG_ATTN_SCALE_ADDR: rdata_d = csr_attn_scale;
        `REG_GROUP_MODE_ADDR: rdata_d = {30'b0, csr_group_mode};
        `REG_ACT_CTRL_ADDR  : rdata_d = csr_act_ctrl;
        // 预取触发寄存器是WO：写bit[0]触发一次、bit[1]选target，读回恒0。
        // 预取状态要观测请读REG_STATUS的[2]/[3]，那边本来就是RO，RAL模型干净
        `REG_PF_CTRL_ADDR   : rdata_d = 32'h0;
        default: rdata_d = 32'h0;
    endcase
end

// --- CSR Write Logic ---
always @(posedge clock or negedge rst_n) begin
    if (!rst_n) begin
        csr_ctrl    <= 32'h0;
        csr_vi_base <= 32'h0;
        csr_mi_base <= 32'h0;
        csr_vo_base <= 32'h0;
        csr_rows    <= 32'h0;
        csr_cols    <= 32'h0;
        csr_err_code<= 32'h0;
        csr_q_base  <= 32'h0;
        csr_k_base  <= 32'h0;
        csr_v_base  <= 32'h0;
        csr_o_base  <= 32'h0;
        csr_head_dim <= 32'h0;
        csr_seq_len  <= 32'h0;
        csr_kv_stride<= 32'h0;
        csr_num_heads<= 32'h0;
        csr_attn_scale<= 32'h3F0293EE;  // 默认head_dim=8
        csr_group_mode <= 2'b00;  // 默认4×8模式
        csr_act_ctrl   <= 32'h0;  // 默认关闭SiLU融合，行为与改动前一致
    end else if (w_enter) begin
        case(buf_addr[15:0])
            `REG_CTRL_ADDR     : csr_ctrl    <= s_wdata;
            `REG_VI_BASE_ADDR  : csr_vi_base <= s_wdata;
            `REG_MI_BASE_ADDR  : csr_mi_base <= s_wdata;
            `REG_VO_BASE_ADDR  : csr_vo_base <= s_wdata;
            `REG_ROWS_ADDR     : csr_rows    <= s_wdata;
            `REG_COLS_ADDR     : csr_cols    <= s_wdata;
            `REG_Q_BASE_ADDR   : csr_q_base  <= s_wdata;
            `REG_K_BASE_ADDR   : csr_k_base  <= s_wdata;
            `REG_V_BASE_ADDR   : csr_v_base  <= s_wdata;
            `REG_O_BASE_ADDR   : csr_o_base  <= s_wdata;
            `REG_HEAD_DIM_ADDR : csr_head_dim <= s_wdata;
            `REG_SEQ_LEN_ADDR  : csr_seq_len  <= s_wdata;
            `REG_KV_STRIDE_ADDR: csr_kv_stride<= s_wdata;
            `REG_NUM_HEADS_ADDR: csr_num_heads<= s_wdata;
            `REG_ATTN_SCALE_ADDR: csr_attn_scale<= s_wdata;
            `REG_GROUP_MODE_ADDR: csr_group_mode <= s_wdata[1:0];
            // 只有bit[0]是实现位，高位恒零（与group_mode同风格）。若整字写入，
            // RAL的bit-bash会因为高位可写而报错——RAL声明[31:1]为RO，两边必须一致
            `REG_ACT_CTRL_ADDR  : csr_act_ctrl   <= {31'b0, s_wdata[0]};
            default : ;
        endcase
    end
end

//Debug signal
assign debug_state = state;


endmodule

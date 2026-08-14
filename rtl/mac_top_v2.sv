`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// mac_top_v2
//
// 统一顶层，支持OS(GEMV)和WS(FSA)双模式。
// FSA外围模块直接挂载，与PE_core_v2共享32个PE_retimed。
//
// 模块层次：
//   PE_core_v2 (32 PE_retimed, OS/WS双模式)
//   fsa_ctrl_fsm (FSA控制状态机)
//   fsa_transposer (8×8转置引擎)
//   CMP × 4 (在线softmax)
//   fsa_accumulator × 4 (8通道累加器)
//   Input SRAM (32 bank × 32b × 64)
//   Vector SRAM (1 bank × 32b × 64)
////////////////////////////////////////////////////////////////
module mac_top_v2 #(
    parameter ARRAY_SIZE      = 32,
    parameter DATA_WIDTH      = 32,
    parameter K_ACCUM_DEPTH   = 64,
    parameter MAC_LATENCY     = 5,
    parameter OS_MAC_LATENCY  = 7,   // OS模式总延迟（含pre_add×2+2级加法器）
    parameter ACC_LATENCY     = 6,   // fsa_accumulator总流水延迟（输入寄存器1 + FPAccUnit 5）
    parameter GROUP_SIZE      = 8,
    parameter NUM_GROUPS      = 4,
    parameter SRAM_W_DEPTH    = K_ACCUM_DEPTH,
    parameter SRAM_V_DEPTH    = K_ACCUM_DEPTH
)(
    input  clock,
    input  rst_n,

    // === 模式选择 ===
    input  fsa_mode,  // 0=GEMV(OS), 1=FSA(WS)

    // === OS模式接口（与mac_top一致）===
    input  os_start,
    input  dma_access_mode,
    input  [ARRAY_SIZE-1:0] dma_w_sram_bank_we,
    input  [$clog2(SRAM_W_DEPTH)-1:0] dma_w_sram_waddr,
    // 一个 64 位 beat 的两个 word。wdual=1 时整 entry 一拍写完（GEMV/FSA-V：同 bank
    // addr/addr+1）；wdual=0 时相邻两 bank 各取一半，由 whalf 逐 bank 指定取哪半
    // （FSA-K：不同 bank 同 addr）。
    input  [2*DATA_WIDTH-1:0] dma_w_sram_wdata,
    input                     dma_w_sram_wdual,
    input  [ARRAY_SIZE-1:0]   dma_w_sram_whalf,
    input  dma_v_sram_we,
    input  [$clog2(SRAM_V_DEPTH)-1:0] dma_v_sram_waddr,
    // 一个 beat 的两个 word。翻转后的映射下它们落到相邻两 bank 的同一 addr，
    // 由 waddr[1:0] 指定低半 word 去哪个 bank（waddr 恒为偶数，故 +1 不跨 addr）。
    input  [2*DATA_WIDTH-1:0] dma_v_sram_wdata,
    input  [1:0] dma_v_sram_bank_sel,  // Vector SRAM bank选择（FSA模式由外部指定）
    input  acc_en,
    input  w_mem_rst,
    input  v_mem_rst,
    output os_processing_done,

    // === FSA模式接口 ===
    input  fsa_start,
    input  [7:0] head_dim,
    input  [7:0] seq_tile_len,
    input  [12:0] num_kv_tiles,
    input  [7:0] last_tile_valid,  // 最后tile有效行数（0=满tile）
    input  [31:0] attn_scale,     // ATTENTION_SCALE = log2(e)/sqrt(head_dim)
    input  [1:0]  group_mode,     // FSA分组模式: 0=4×8, 1=2×16, 2=1×32
    input  dma_done,
    // tile 0的K已被预取搬好（电平，保持到K被读完）——透传给fsa_ctrl_fsm
    input  k_tile0_preloaded,
    // K/V缓冲区已装载（电平，由cb_controll_v2维护后透传给fsa_ctrl_fsm）
    input  k_buf_loaded,
    input  v_buf_loaded,
    output fsa_done,
    output fsa_k_read_done,
    output fsa_v_read_done,

    // === Output SRAM DMA读出接口 ===
    input  [3:0] dma_o_sram_raddr,
    output [4*DATA_WIDTH-1:0] dma_o_sram_rdata,  // 4 bank并行读出

    // === SiLU 融合接口（仅 GEMV 模式）===
    // 顶层 FSM 在计算完成、DMA 写回之前拉 silu_start，把 Output SRAM 里的
    // 32 个 GEMV 结果就地过一遍 silu()，复用 4 个 fsa_accumulator 通道。
    input  silu_start,
    input  [5:0] silu_num_elem,   // 本次有效元素数（GEMV 的 current_rows，最大32）
    output silu_done
);

    // ============================================================
    // 内部信号
    // ============================================================

    // FSM状态编码（本地副本，与fsa_ctrl_fsm连续编号一致）

    // --- PE_core_v2 信号 ---
    wire [ARRAY_SIZE*DATA_WIDTH-1:0] pe_sram_rdata_w;
    wire [DATA_WIDTH-1:0] pe_sram_rdata_v;
    wire [ARRAY_SIZE*DATA_WIDTH-1:0] pe_mul_outcome;
    wire pe_result_valid;
    wire wo_write_done; // write_out_v2完成信号（前向声明）

    wire [ARRAY_SIZE*DATA_WIDTH-1:0] pe_fsa_l_input;
    wire pe_fsa_l_input_valid;
    wire pe_ctrl_mac, pe_ctrl_acc_ui, pe_ctrl_load_reg_li, pe_ctrl_load_reg_ui;
    wire pe_ctrl_flow_lr, pe_ctrl_flow_ud, pe_ctrl_flow_du;
    wire pe_ctrl_update_reg, pe_ctrl_exp2;
    wire pe_ctrl_delay_rev;
    wire pe_acc_latch_delta;

    wire [NUM_GROUPS*DATA_WIDTH-1:0] cmp_score_out;
    wire [NUM_GROUPS-1:0] cmp_score_valid;

    // CMP输入寄存器（切断PE→CMP组合路径的前半段）
    reg [NUM_GROUPS*DATA_WIDTH-1:0] cmp_score_out_r;
    reg [NUM_GROUPS-1:0] cmp_score_valid_r;
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            cmp_score_out_r <= '0;
            cmp_score_valid_r <= '0;
        end else begin
            cmp_score_out_r <= cmp_score_out;
            cmp_score_valid_r <= cmp_score_valid;
        end
    end
    wire [NUM_GROUPS*DATA_WIDTH-1:0] acc_data_out;
    wire [NUM_GROUPS-1:0] acc_data_valid;

    // --- FSM信号 ---
    wire fsm_q_buf_fire;
    wire fsm_input_sram_rd_en;
    wire [5:0] fsm_input_sram_rd_addr;

    // fsa_ctrl_fsm 的语义化状态输出。本模块不再自己抄一份状态编码去译码 fsm_state
    // ——那份 LS_* 副本与 FSM 里的 localparam 是"改一处漏一处就静默算错"的隐式契约。
    wire       fsm_score_wr_idx_rst;
    wire       fsm_score_restream;
    wire       fsm_score_bus_hold;
    wire       fsm_q_buf_load_win;
    wire       fsm_exp2_active;
    wire       fsm_broadcast_active;
    wire [1:0] fsm_broadcast_sel;
    wire       fsm_pe_load_q;
    wire       fsm_pe_mac_stream;
    wire       fsm_acc_wr_blocked;
    wire       fsm_out_wr_active;
    wire fsm_vec_sram_rd_en;
    wire [5:0] fsm_vec_sram_addr;
    wire [DATA_WIDTH-1:0] vec_sram_rdata;
    wire fsm_cmp_ctrl_valid;
    wire [2:0] fsm_cmp_ctrl_cmd;
    wire [7:0] fsm_cmp_causal_counter;
    // 累加器命令有两个来源：FSA 模式来自 fsa_ctrl_fsm，GEMV 模式来自 silu_ctrl_fsm
    // （SiLU 融合）。两者由 fsa_mode 互斥选择，不会同时驱动。
    wire fsa_acc_ctrl_valid;
    wire [2:0] fsa_acc_ctrl_cmd;
    wire silu_acc_ctrl_valid;
    wire [2:0] silu_acc_ctrl_cmd;
    wire fsm_acc_ctrl_valid      = fsa_mode ? fsa_acc_ctrl_valid : silu_acc_ctrl_valid;
    wire [2:0] fsm_acc_ctrl_cmd  = fsa_mode ? fsa_acc_ctrl_cmd   : silu_acc_ctrl_cmd;
    wire fsm_acc_clear_en;
    wire [6:0] fsm_acc_clear_addr;  // 7位：rowsum地址=head_dim可达64（Fix C）
    wire fsm_score_fifo_wr_en;
    wire fsm_score_fifo_masked;
    wire [4:0] fsm_state;
    wire fsm_busy;
    wire fsm_chunk1_sel;  // head_dim>32的chunk2(S_QK_MAC)期间为高，驱动PE[31]的d_input mux

    // --- CMP信号 ---
    wire [DATA_WIDTH-1:0] cmp_d_output [0:NUM_GROUPS-1];
    wire [NUM_GROUPS-1:0] cmp_d_output_valid;

    // --- Score FIFO：QK_MAC期间缓存score，SCORE_RESTREAM期间逐拍输出到下行pipe ---
    // 4个GROUP_SIZE(8)深bank，跟Q Buffer同一套"小深度基准+地址位拼接"语言：
    // 4×8模式下4个bank各自独立存自己组的真实score流；2×16/1×32模式下只有
    // group0（以及2×16下的group2）是CMP的"逻辑顶部"、产出真实score
    // （PE_core_v2.sv的cmp_idx译码证实其余物理组在这些模式下的bus位置不会
    // 被下游消费），故把那些原本浪费的bank挪用为真实流的深度扩展：
    // 2×16把group0流拆进bank0/1、group2流拆进bank2/3；1×32把group0流拆进bank0~3
    reg [5:0] score_fifo_wr_idx;
    wire [2:0] score_fifo_wr_local = score_fifo_wr_idx[2:0];

    localparam [31:0] FP32_NEG_INF = 32'hFF800000;
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            score_fifo_wr_idx <= 6'd0;
        end else if (fsm_score_fifo_wr_en) begin
            score_fifo_wr_idx <= score_fifo_wr_idx + 6'd1;
        end else if (fsm_score_wr_idx_rst) begin
            // 每个tile进QK_MAC前清零score写指针：
            // tile0经ACC_CLEAR复位计数器，tile1+经DMA_K复位。
            // 理由：acc累加器跨tile保留（不清零），tile1+需在DMA_K时做一次复位保证score地址正确
            score_fifo_wr_idx <= 6'd0;
        end
    end

    // 按group_mode决定本次写入命中哪个bank、数据取自哪个物理组的真实score流
    reg [NUM_GROUPS-1:0]      score_fifo_bank_we;
    reg [DATA_WIDTH-1:0]      score_fifo_bank_wdata [0:NUM_GROUPS-1];
    always_comb begin
        score_fifo_bank_we = '0;
        for (int g = 0; g < NUM_GROUPS; g = g + 1)
            score_fifo_bank_wdata[g] = '0;
        case (group_mode)
            2'b00: begin // 4×8：4个bank各自独立写自己组的真实score（8深正好用满）
                score_fifo_bank_we = 4'b1111;
                score_fifo_bank_wdata[0] = cmp_score_out_r[0*DATA_WIDTH +: DATA_WIDTH];
                score_fifo_bank_wdata[1] = cmp_score_out_r[1*DATA_WIDTH +: DATA_WIDTH];
                score_fifo_bank_wdata[2] = cmp_score_out_r[2*DATA_WIDTH +: DATA_WIDTH];
                score_fifo_bank_wdata[3] = cmp_score_out_r[3*DATA_WIDTH +: DATA_WIDTH];
            end
            2'b01: begin // 2×16：group0流拆bank0/1、group2流拆bank2/3，wr_idx[3]选前8/后8
                score_fifo_bank_we[score_fifo_wr_idx[3] ? 1 : 0] = 1'b1;
                score_fifo_bank_we[score_fifo_wr_idx[3] ? 3 : 2] = 1'b1;
                score_fifo_bank_wdata[score_fifo_wr_idx[3] ? 1 : 0] = cmp_score_out_r[0*DATA_WIDTH +: DATA_WIDTH];
                score_fifo_bank_wdata[score_fifo_wr_idx[3] ? 3 : 2] = cmp_score_out_r[2*DATA_WIDTH +: DATA_WIDTH];
            end
            default: begin // 1×32：单一group0流按wr_idx[4:3]拆到4个bank
                score_fifo_bank_we[score_fifo_wr_idx[4:3]] = 1'b1;
                score_fifo_bank_wdata[score_fifo_wr_idx[4:3]] = cmp_score_out_r[0*DATA_WIDTH +: DATA_WIDTH];
            end
        endcase
    end

    // SCORE_RESTREAM期间：逐拍从FIFO读出
    reg [5:0] score_fifo_rd_cnt;
    wire score_fifo_rd_active = fsm_score_restream && (score_fifo_rd_cnt < score_fifo_wr_idx);
    wire [2:0] score_fifo_rd_local = score_fifo_rd_cnt[2:0];

    always_ff @(posedge clock) begin
        if (!rst_n) begin
            score_fifo_rd_cnt <= 6'd0;
        end else if (fsm_score_restream) begin
            if (score_fifo_rd_cnt < score_fifo_wr_idx)
                score_fifo_rd_cnt <= score_fifo_rd_cnt + 6'd1;
        end else begin
            score_fifo_rd_cnt <= 6'd0;
        end
    end

    // 读出时选哪个bank拼回"逻辑顶部"的bus位置0/2，跟写入端用同一组地址位、
    // 自限幅性质让4×8/2×16/1×32三种模式共用同一条公式不需要按模式分支：
    // 4×8下rd_cnt结构性≤7，[4:3]/[3]恒为0，自然退化成bank0/bank2直读，跟改动前一致
    reg [1:0] score_fifo_bank_sel0_d, score_fifo_bank_sel2_d;
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            score_fifo_bank_sel0_d <= 2'd0;
            score_fifo_bank_sel2_d <= 2'd2;
        end else begin
            score_fifo_bank_sel0_d <= score_fifo_rd_cnt[4:3];
            score_fifo_bank_sel2_d <= {1'b1, score_fifo_rd_cnt[3]};
        end
    end

    // Score读出：S_SCORE_RESTREAM期间Vec SRAM读口输出即为score数据
    // Vec SRAM内部已有1拍读寄存器（sram.sv），等效原score_fifo_mem的BRAM读延迟
    // 直接用vec_sram_rdata_bank作为score输出，不额外打拍
    // 注：score_fifo_out_reg实际定义在Vec SRAM实例化之后（前向声明）
    wire [DATA_WIDTH-1:0] score_fifo_out_reg [0:NUM_GROUPS-1];

    reg score_fifo_out_valid;
    always_ff @(posedge clock) begin
        if (!rst_n)
            score_fifo_out_valid <= 1'b0;
        else
            score_fifo_out_valid <= score_fifo_rd_active;
    end

    // CMP d_output bus MUX：
    // SCORE_RESTREAM: 始终用FIFO寄存器输出（保持最后值，不切换到CMP/0）
    // 其他状态用CMP实际输出（已寄存2拍，切断generalAdder组合路径）
    //
    // CMP输出寄存器：2级流水切断CMP generalAdder→PE组合路径
    reg [DATA_WIDTH-1:0] cmp_d_output_r1 [0:NUM_GROUPS-1];
    reg [NUM_GROUPS-1:0] cmp_d_output_valid_r1;
    reg [DATA_WIDTH-1:0] cmp_d_output_r2 [0:NUM_GROUPS-1];
    reg [NUM_GROUPS-1:0] cmp_d_output_valid_r2;
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            for (int g = 0; g < NUM_GROUPS; g = g + 1) begin
                cmp_d_output_r1[g] <= '0;
                cmp_d_output_r2[g] <= '0;
            end
            cmp_d_output_valid_r1 <= '0;
            cmp_d_output_valid_r2 <= '0;
        end else begin
            for (int g = 0; g < NUM_GROUPS; g = g + 1) begin
                cmp_d_output_r1[g] <= cmp_d_output[g];
                cmp_d_output_r2[g] <= cmp_d_output_r1[g];
            end
            cmp_d_output_valid_r1 <= cmp_d_output_valid;
            cmp_d_output_valid_r2 <= cmp_d_output_valid_r1;
        end
    end

    // bus位置0/2读"逻辑顶部"流，需要按score_fifo_bank_sel0/2_d从对应bank拼回；
    // 位置1/3在4×8模式下直读自己的bank（其唯一被消费的模式），2×16/1×32下不被
    // 下游消费，直读即可，不需要额外选择
    wire [NUM_GROUPS*DATA_WIDTH-1:0] cmp_d_output_bus;
    assign cmp_d_output_bus[0*DATA_WIDTH +: DATA_WIDTH] =
        fsm_score_bus_hold ?
            score_fifo_out_reg[score_fifo_bank_sel0_d] : cmp_d_output_r2[0];
    assign cmp_d_output_bus[1*DATA_WIDTH +: DATA_WIDTH] =
        fsm_score_bus_hold ?
            score_fifo_out_reg[1] : cmp_d_output_r2[1];
    assign cmp_d_output_bus[2*DATA_WIDTH +: DATA_WIDTH] =
        fsm_score_bus_hold ?
            score_fifo_out_reg[score_fifo_bank_sel2_d] : cmp_d_output_r2[2];
    assign cmp_d_output_bus[3*DATA_WIDTH +: DATA_WIDTH] =
        fsm_score_bus_hold ?
            score_fifo_out_reg[3] : cmp_d_output_r2[3];

    // --- Accumulator信号 ---
    wire [NUM_GROUPS*DATA_WIDTH-1:0] acc_sram_out;
    wire [NUM_GROUPS-1:0] acc_sram_out_valid;
    wire [NUM_GROUPS-1:0] acc_reciprocal_done;

    // FSM的ACC SRAM控制信号（必须在FSM例化前声明）
    wire acc_sram_rd_en;
    wire [6:0] acc_sram_rd_addr;  // 7位：rowsum地址=head_dim可达64（Fix C）

    // --- SRAM信号 ---
    wire [31:0] sram_w_rdata_bank [0:ARRAY_SIZE-1];
    wire [ARRAY_SIZE*DATA_WIDTH-1:0] sram_w_bus;

    // ============================================================
    // OS模式控制逻辑（复用自mac_top）
    // ============================================================
    reg alu_start_reg;
    reg [8:0] cycle_num_reg;
    reg processing_done_reg;

    localparam integer RESULT_CAPTURE_CYCLE = K_ACCUM_DEPTH + ARRAY_SIZE - 1 + OS_MAC_LATENCY;

    always_ff @(posedge clock) begin
        if (!rst_n) begin
            alu_start_reg <= 1'b0;
            cycle_num_reg <= 9'd0;
            processing_done_reg <= 1'b0;
        end else if (!fsa_mode) begin
            if (os_start && !dma_access_mode) begin
                alu_start_reg <= 1'b1;
                if (alu_start_reg)
                    cycle_num_reg <= cycle_num_reg + 9'd1;
                if (wo_write_done) begin
                    processing_done_reg <= 1'b1;
                    alu_start_reg <= 1'b0;
                    cycle_num_reg <= 9'd0;
                end
            end else begin
                alu_start_reg <= 1'b0;
                cycle_num_reg <= 9'd0;
                if (!os_start) processing_done_reg <= 1'b0;
            end
        end
    end

    assign os_processing_done = processing_done_reg;

    // ============================================================
    // Input SRAM (32 bank × 32b × 64深)
    // 用 sram_w2（双字 entry：32深 × 64b）而不是 sram。对外仍是 word 粒度地址，
    // 行为逐位等价；换形状是为了后续 DMA 加宽到 64 位时，一个 beat 的两个 word
    // 能落进同一个 entry 的高低半、一拍写完（32 bank 共用 waddr/wdata，原形状
    // 下一拍只能进 1 个 word）。详见 rtl/sram.sv 里 sram_w2 的注释。
    // ============================================================
    wire [$clog2(SRAM_W_DEPTH)-1:0] sram_w_raddr;
    assign sram_w_raddr = fsa_mode ? fsm_input_sram_rd_addr[$clog2(SRAM_W_DEPTH)-1:0]
                                   : cycle_num_reg[$clog2(SRAM_W_DEPTH)-1:0];

    genvar gi;
    generate
        for (gi = 0; gi < ARRAY_SIZE; gi = gi + 1) begin : SRAM_W_BANK
            sram_w2 #(
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_WIDTH($clog2(SRAM_W_DEPTH))
            ) u_sram_w (
                .clk(clock),
                .csb(1'b0),
                .wsb(~dma_w_sram_bank_we[gi]),
                .rst(w_mem_rst),
                .waddr(dma_w_sram_waddr),
                .wdata(dma_w_sram_wdata),
                .wdual(dma_w_sram_wdual),
                .whalf(dma_w_sram_whalf[gi]),
                .raddr(sram_w_raddr),
                .rdata(sram_w_rdata_bank[gi])
            );
            assign sram_w_bus[gi*DATA_WIDTH +: DATA_WIDTH] = sram_w_rdata_bank[gi];
        end
    endgenerate

    // ============================================================
    // Vector SRAM (4 bank × 32b × 32深)
    // addr 0~15: Q数据（跨tile持久驻留）
    // addr 16~23: Score FIFO区（S_QK_MAC写入，S_SCORE_RESTREAM读出）
    // FSA模式: 4 bank并行读各自Q / Score
    // GEMV模式: 4 bank拼接为64深，addr[5:4]选bank（仅用前16深）
    // ============================================================
    localparam SRAM_V_BANK_DEPTH = 32;
    localparam SRAM_V_BANK_AW = 5;
    localparam SCORE_ADDR_BASE = 5'd16;  // Score区起始地址

    wire [SRAM_V_BANK_AW-1:0] sram_v_raddr_bank;
    wire [1:0] sram_v_rd_bank_sel;
    wire [DATA_WIDTH-1:0] vec_sram_rdata_bank [0:3];

    // Score读地址：S_SCORE_RESTREAM期间从addr 16+offset读
    wire [SRAM_V_BANK_AW-1:0] score_rd_addr = SCORE_ADDR_BASE + {2'b0, score_fifo_rd_local};

    // 读地址mux：S_SCORE_RESTREAM用score区地址，其他FSA状态用Q区地址，GEMV用cycle_num
    assign sram_v_raddr_bank = (!fsa_mode) ? {1'b0, cycle_num_reg[3:0]} :
                               (score_fifo_rd_active) ? score_rd_addr :
                               {1'b0, fsm_vec_sram_addr[3:0]};
    assign sram_v_rd_bank_sel = cycle_num_reg[5:4];

    // 写地址和bank选择
    // 两种写入来源（时间互斥）：
    //   1. DMA写Q：attention开头一次性预装（dma_v_sram_we有效）
    //   2. Score写入：S_QK_MAC期间CMP输出score（fsm_score_fifo_wr_en有效）
    // GEMV模式: 4 bank拼接64深，bank=addr[5:4], bank_addr=addr[3:0]
    // FSA 4×8: 4 heads各8深，bank=addr[4:3], bank_addr=addr[2:0]
    // FSA 2×16: 2 heads各16深，bank=addr[4]选bank0/bank2, bank_addr=addr[3:0]
    // FSA 1×32: 1 head 32深，bank=addr[5:4]选bank, bank_addr=addr[3:0]
    reg [SRAM_V_BANK_AW-1:0] sram_v_waddr_bank;
    reg [NUM_GROUPS-1:0] sram_v_bank_we;  // per-bank写使能
    // per-bank写数据，一拍两个 word。DMA 写（GEMV 与 FSA Q 都是 addr 内循环）用
    // wdual=1 一拍写满 entry；Score 写是单 word，wdual=0 并放在低半。
    reg [2*DATA_WIDTH-1:0] sram_v_wdata_bank [0:NUM_GROUPS-1];
    reg sram_v_wdual;

    // Score写地址（统一：addr 16 + bank内偏移）
    wire [SRAM_V_BANK_AW-1:0] score_wr_addr = SCORE_ADDR_BASE + {2'b0, score_fifo_wr_local};

    always_comb begin
        sram_v_bank_we = '0;
        sram_v_waddr_bank = '0;
        sram_v_wdual = dma_v_sram_we;   // DMA 写双字，Score 写单字
        for (int g = 0; g < NUM_GROUPS; g = g + 1)
            sram_v_wdata_bank[g] = dma_v_sram_wdata;

        if (fsm_score_fifo_wr_en) begin
            // Score写入：地址固定在score区，bank选择和数据按group_mode决定
            sram_v_waddr_bank = score_wr_addr;
            sram_v_bank_we = score_fifo_bank_we;
            sram_v_wdual = 1'b0;   // 单 word，靠 waddr[0] 选 entry 的半字
            for (int g = 0; g < NUM_GROUPS; g = g + 1)
                sram_v_wdata_bank[g] = {DATA_WIDTH'(0), fsm_score_fifo_masked ?
                    FP32_NEG_INF : score_fifo_bank_wdata[g]};
        end else if (dma_v_sram_we) begin
            // DMA写Q
            if (!fsa_mode) begin
                sram_v_waddr_bank = {1'b0, dma_v_sram_waddr[3:0]};
                sram_v_bank_we = 4'b1 << dma_v_sram_waddr[5:4];
            end else begin
                case (group_mode)
                    2'b01: begin
                        sram_v_waddr_bank = {1'b0, dma_v_sram_waddr[3:0]};
                        sram_v_bank_we = dma_v_sram_waddr[4] ? 4'b0100 : 4'b0001;
                    end
                    2'b10: begin
                        sram_v_waddr_bank = {1'b0, dma_v_sram_waddr[3:0]};
                        sram_v_bank_we = 4'b1 << dma_v_sram_waddr[5:4];
                    end
                    default: begin
                        sram_v_waddr_bank = {2'b0, dma_v_sram_waddr[2:0]};
                        sram_v_bank_we = 4'b1 << dma_v_sram_waddr[4:3];
                    end
                endcase
            end
        end
    end

    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : SRAM_V_BANK
            // 与 Input SRAM 同一套双字 entry：DMA 的一个 64 位 beat 带两个 word，
            // 而 GEMV 与 FSA Q 的写入都是 addr 内循环（同 bank、连续 addr），
            // 正好落进同一 entry 的高低半，wdual=1 一拍写完。读侧仍是 word 粒度。
            sram_w2 #(
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_WIDTH(SRAM_V_BANK_AW)
            ) u_sram_v (
                .clk(clock),
                .csb(1'b0),
                .wsb(~sram_v_bank_we[gi]),
                .rst(v_mem_rst),
                .waddr(sram_v_waddr_bank),
                .wdata(sram_v_wdata_bank[gi]),
                .wdual(sram_v_wdual),
                .whalf(1'b0),
                .raddr(sram_v_raddr_bank),
                .rdata(vec_sram_rdata_bank[gi])
            );
        end
    endgenerate

    // Score FIFO输出：直接取Vec SRAM各bank的读口（score区地址已在raddr_bank mux中处理）
    assign score_fifo_out_reg[0] = vec_sram_rdata_bank[0];
    assign score_fifo_out_reg[1] = vec_sram_rdata_bank[1];
    assign score_fifo_out_reg[2] = vec_sram_rdata_bank[2];
    assign score_fifo_out_reg[3] = vec_sram_rdata_bank[3];

    // 读数据MUX: GEMV模式4选1（延迟1拍对齐SRAM读延迟），FSA模式从bank0读（送FSM）
    // 1×32模式：地址高2位选bank（4选1，打1拍对齐SRAM读延迟）——head_dim<=32时地址≤31，
    // addr[5]恒为0，自然只在bank0/1间选，跟改动前2选1的行为完全一致；这是给head_dim=64
    // 的chunk2预先打通的读地址通路（chunk2要读Q的32~63号元素），本步不引入任何新行为，
    // 4×8/2×16模式不受影响（vec_sram_sel_bank在这两种模式下恒为0，沿用原"从bank0读"逻辑）
    reg [1:0] sram_v_rd_bank_sel_d;
    reg [1:0] fsa_vec_addr_bank_d;
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            sram_v_rd_bank_sel_d <= 2'd0;
            fsa_vec_addr_bank_d <= 2'd0;
        end else begin
            sram_v_rd_bank_sel_d <= sram_v_rd_bank_sel;
            fsa_vec_addr_bank_d <= fsm_vec_sram_addr[5:4];
        end
    end
    wire [1:0] vec_sram_sel_bank = (group_mode == 2'b10) ? fsa_vec_addr_bank_d : 2'd0;
    assign vec_sram_rdata = fsa_mode ?
        vec_sram_rdata_bank[vec_sram_sel_bank] :
        vec_sram_rdata_bank[sram_v_rd_bank_sel_d];
    assign pe_sram_rdata_v = vec_sram_rdata;

    // ============================================================
    // 统一Q Buffer：4个物理组各自独立GROUP_SIZE(8)深bank，跟Vector SRAM/
    // Output SRAM同一套"小深度基准+地址位拼接"语言（原FSM内部q_buf[0:31]+
    // 本文件q_buf_bank1/2/3[0:31]四块分裂、各自浪费的存储已合并到这里）
    // 写时序：S_LOAD_Q_BUF期间，SRAM 1拍读延迟后采样（沿用原ext_q_buf_wr_idx/pending）
    // 4×8: 4路并行写，bank[g]直接对应物理组g自己的Vector SRAM bank（8深正好用满）
    // 2×16: 2路并行写（仅用vec_sram bank0/bank2两个源），每路16个元素按
    //       wr_idx[3]拆到2个bank（构成1个16宽逻辑组），bank索引=源bank+wr_idx[3]
    // 1×32: 1路顺序写（vec_sram_rdata已按addr[4]在物理bank0/1间选好），
    //       32个元素按wr_idx[4:3]拆到4个bank
    // 读出侧因此对三种模式都是直读bank[g]，不需要按group_mode做读出MUX——
    // 写入端已经把数据路由进了"物理组g该拿到的那一段"
    // ============================================================

    // q_buf物理只有32深(4组×8)，head_dim>32时chunk1[0:31]/chunk2[32:63]两段Q
    // 故意复用同一组槽位（不新增存储）：S_LOAD_Q_BUF装chunk1段(vec_sram addr 0~31)，
    // S_QK_MAC_CHUNK1_DOWN执行期间并行预取chunk2段(addr 32~63)原地覆写。下面case
    // 分支只取idx[4:0]（5位，最大用到[4:3]+[2:0]）做槽位选择，addr的bit[5]不参与
    // 选址——这正是让addr=32和addr=0落到同一槽位的关键，不是疏漏
    reg [4:0] ext_q_buf_wr_idx;
    reg       ext_q_buf_wr_pending;
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            ext_q_buf_wr_idx <= 5'd0;
            ext_q_buf_wr_pending <= 1'b0;
        end else begin
            // 窗口由FSM的q_buf_load_win给出，覆盖三段：tile起始装chunk1段Q（或非dual
            // 模式的完整head_dim个）；dual模式chunk1执行期间并行预取chunk2段Q；
            // dual模式PV_MAC执行期间并行预取下一个tile要用的chunk1段Q
            // （vec_sram_rd_en只有dual模式才会在PV_MAC期间被FSM拉高，非dual模式
            // PV_MAC从不读vec_sram，这条OR分支天然不会误触发）
            ext_q_buf_wr_pending <= fsm_vec_sram_rd_en &&
                fsm_q_buf_load_win;
            ext_q_buf_wr_idx <= fsm_vec_sram_addr[4:0];
        end
    end

    reg [DATA_WIDTH-1:0] q_buf_bank [0:NUM_GROUPS-1][0:GROUP_SIZE-1];

    always_ff @(posedge clock) begin
        if (!rst_n) begin
            for (int g = 0; g < NUM_GROUPS; g = g + 1)
                for (int i = 0; i < GROUP_SIZE; i = i + 1)
                    q_buf_bank[g][i] <= '0;
        end else if (ext_q_buf_wr_pending) begin
            case (group_mode)
                2'b00: begin // 4×8: 4个物理组各自的Vector SRAM bank直接写自己的Q buffer
                    q_buf_bank[0][ext_q_buf_wr_idx[2:0]] <= vec_sram_rdata_bank[0];
                    q_buf_bank[1][ext_q_buf_wr_idx[2:0]] <= vec_sram_rdata_bank[1];
                    q_buf_bank[2][ext_q_buf_wr_idx[2:0]] <= vec_sram_rdata_bank[2];
                    q_buf_bank[3][ext_q_buf_wr_idx[2:0]] <= vec_sram_rdata_bank[3];
                end
                2'b01: begin // 2×16: bank0源拆bank0/1，bank2源拆bank2/3，wr_idx[3]选前8/后8
                    q_buf_bank[ext_q_buf_wr_idx[3] ? 1 : 0][ext_q_buf_wr_idx[2:0]] <= vec_sram_rdata_bank[0];
                    q_buf_bank[ext_q_buf_wr_idx[3] ? 3 : 2][ext_q_buf_wr_idx[2:0]] <= vec_sram_rdata_bank[2];
                end
                default: begin // 1×32: 单一顺序流，按wr_idx[4:3]拆到4个bank
                    q_buf_bank[ext_q_buf_wr_idx[4:3]][ext_q_buf_wr_idx[2:0]] <= vec_sram_rdata;
                end
            endcase
        end
    end

    // 4组Q buffer并行输出：写入端已按模式路由好数据，读出端三种模式统一直读bank[g]
    wire [GROUP_SIZE*DATA_WIDTH-1:0] q_buf_out_g [0:NUM_GROUPS-1];
    generate
        for (gi = 0; gi < GROUP_SIZE; gi = gi + 1) begin : Q_BUF_OUT_E
            assign q_buf_out_g[0][gi*DATA_WIDTH +: DATA_WIDTH] = q_buf_bank[0][gi];
            assign q_buf_out_g[1][gi*DATA_WIDTH +: DATA_WIDTH] = q_buf_bank[1][gi];
            assign q_buf_out_g[2][gi*DATA_WIDTH +: DATA_WIDTH] = q_buf_bank[2][gi];
            assign q_buf_out_g[3][gi*DATA_WIDTH +: DATA_WIDTH] = q_buf_bank[3][gi];
        end
    endgenerate

    // ============================================================
    // fsa_ctrl_fsm
    // ============================================================
    fsa_ctrl_fsm #(
        .GROUP_SIZE(GROUP_SIZE),
        .MAC_LATENCY(MAC_LATENCY),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_PIPE_LATENCY(ACC_LATENCY)
    ) u_fsm (
        .clock(clock),
        .rst_n(rst_n),
        .fsa_start(fsa_start),
        .head_dim(head_dim),
        .group_mode(group_mode),
        .seq_tile_len(seq_tile_len),
        .num_kv_tiles(num_kv_tiles),
        .last_tile_valid(last_tile_valid),
        .ctrl_mac(pe_ctrl_mac),
        .ctrl_acc_ui(pe_ctrl_acc_ui),
        .ctrl_load_reg_li(pe_ctrl_load_reg_li),
        .ctrl_load_reg_ui(pe_ctrl_load_reg_ui),
        .ctrl_flow_lr(pe_ctrl_flow_lr),
        .ctrl_flow_ud(pe_ctrl_flow_ud),
        .ctrl_flow_du(pe_ctrl_flow_du),
        .ctrl_update_reg(pe_ctrl_update_reg),
        .ctrl_exp2(pe_ctrl_exp2),
        .ctrl_delay_rev(pe_ctrl_delay_rev),
        .ctrl_valid(pe_fsa_l_input_valid),
        .acc_latch_delta(pe_acc_latch_delta),
        .q_buf_fire(fsm_q_buf_fire),
        .input_sram_rd_en(fsm_input_sram_rd_en),
        .input_sram_rd_addr(fsm_input_sram_rd_addr),
        .score_wr_idx_rst(fsm_score_wr_idx_rst),
        .score_restream(fsm_score_restream),
        .score_bus_hold(fsm_score_bus_hold),
        .q_buf_load_win(fsm_q_buf_load_win),
        .exp2_active(fsm_exp2_active),
        .broadcast_active(fsm_broadcast_active),
        .broadcast_sel(fsm_broadcast_sel),
        .pe_load_q(fsm_pe_load_q),
        .pe_mac_stream(fsm_pe_mac_stream),
        .acc_wr_blocked(fsm_acc_wr_blocked),
        .out_wr_active(fsm_out_wr_active),
        .vec_sram_rd_en(fsm_vec_sram_rd_en),
        .vec_sram_addr(fsm_vec_sram_addr),
        .cmp_ctrl_valid(fsm_cmp_ctrl_valid),
        .cmp_ctrl_cmd(fsm_cmp_ctrl_cmd),
        .cmp_causal_counter(fsm_cmp_causal_counter),
        .cmp_score_valid_in(cmp_score_valid_r[0]),
        .score_fifo_wr_en(fsm_score_fifo_wr_en),
        .score_fifo_masked(fsm_score_fifo_masked),
        .acc_ctrl_valid(fsa_acc_ctrl_valid),
        .acc_ctrl_cmd(fsa_acc_ctrl_cmd),
        .acc_sram_rd_en(acc_sram_rd_en),
        .acc_sram_rd_addr(acc_sram_rd_addr),
        .dma_done(dma_done),
        .k_tile0_preloaded(k_tile0_preloaded),
        .k_buf_loaded(k_buf_loaded),
        .v_buf_loaded(v_buf_loaded),
        .acc_reciprocal_done(acc_reciprocal_done[0]),
        .fsm_busy(fsm_busy),
        .fsm_done(fsa_done),
        .fsm_state(fsm_state),
        .fsa_k_read_done(fsa_k_read_done),
        .fsa_v_read_done(fsa_v_read_done),
        .acc_clear_en(fsm_acc_clear_en),
        .acc_clear_addr(fsm_acc_clear_addr),
        .chunk1_sel(fsm_chunk1_sel)
    );

    // ============================================================
    // PE_core_v2 fsa_l_input数据源MUX
    // ============================================================
    // 常量定义（三层架构）
    // 第一层：字面常量
    localparam [31:0] FP32_ONE  = 32'h3F800000;  // 1.0
    localparam [31:0] FP32_ZERO = 32'h00000000;  // 0.0
    // 第二层：配置常量（由CSR配置）
    // ATTENTION_SCALE从外部attn_scale端口传入
    // 第三层：共享ROM（一份，4组共用）- Chebyshev优化8段系数
    wire [31:0] EXP2_SLOPES [0:7];
    assign EXP2_SLOPES[0] = 32'h3f29f2fb;
    assign EXP2_SLOPES[1] = 32'h3f1bd814;
    assign EXP2_SLOPES[2] = 32'h3f0ee8dd;
    assign EXP2_SLOPES[3] = 32'h3f030c78;
    assign EXP2_SLOPES[4] = 32'h3ef05829;
    assign EXP2_SLOPES[5] = 32'h3edc6593;
    assign EXP2_SLOPES[6] = 32'h3eca1acf;
    assign EXP2_SLOPES[7] = 32'h3eb954b3;

    // FSM状态编码（与fsa_ctrl_fsm一致）
    // EXP2段计数器（FSM驱动）
    reg [2:0] exp2_seg_cnt;
    always_ff @(posedge clock) begin
        if (!rst_n || !fsm_exp2_active)
            exp2_seg_cnt <= 3'd0;
        else if (pe_fsa_l_input_valid)
            exp2_seg_cnt <= exp2_seg_cnt + 3'd1;
    end

    // 标量广播值预计算（SUBTRACT/ROWSUM/SCALE/EXP2共用，减少per-PE MUX扇入）
    reg [DATA_WIDTH-1:0] broadcast_val;
    always_comb begin
        case (fsm_broadcast_sel)
            2'd1:    broadcast_val = attn_scale;
            2'd2:    broadcast_val = EXP2_SLOPES[exp2_seg_cnt];
            default: broadcast_val = FP32_ONE;
        endcase
    end

    reg [ARRAY_SIZE*DATA_WIDTH-1:0] fsa_l_input_mux;

    always_comb begin
        if (fsm_broadcast_active) begin
            // 标量广播：同一值复制到所有PE（综合为wire fanout，无per-PE MUX）
            fsa_l_input_mux = {ARRAY_SIZE{broadcast_val}};
        end else begin
            fsa_l_input_mux = '0;
            if (fsm_pe_load_q) begin
                for (int g = 0; g < NUM_GROUPS; g = g + 1)
                    for (int p = 0; p < GROUP_SIZE; p = p + 1)
                        fsa_l_input_mux[(g*GROUP_SIZE+p)*DATA_WIDTH +: DATA_WIDTH] =
                            q_buf_out_g[g][p*DATA_WIDTH +: DATA_WIDTH];
            end else if (fsm_pe_mac_stream) begin
                // 直接使用SRAM 32-bank并行读出，无需time-MUX
                // PV_MAC的V行组内反转已挪到CB_top_v2.sv的V-DMA写入端（v_reversed_bank），
                // 这里读出来的sram_w_bus已经是反转后的顺序，不需要再做一次读出端MUX
                // chunk1跟chunk2同样需要K从SRAM进l_input，
                // 否则l_input读到默认值0(K缺失)，乘以reg里的Q恒得0，部分和全错
                fsa_l_input_mux = sram_w_bus;
            end
        end
    end

    assign pe_fsa_l_input = fsa_l_input_mux;
    assign pe_sram_rdata_w = sram_w_bus;

    // QK_MAC/PV_MAC等所有阶段统一由FSM的ctrl_valid驱动（SRAM 1拍延迟由FSM内部cnt偏移补偿）
    wire pe_fsa_l_input_valid_final;
    assign pe_fsa_l_input_valid_final = pe_fsa_l_input_valid;

    // chunk1 ACC_SRAM读出信号前向声明（真正的驱动逻辑在后面的ACC SRAM段，
    // 但PE_core_v2例化在文件里位置更早，需要先声明避免VCS报"未声明的标识符"）
    wire [DATA_WIDTH-1:0] acc_sram_rd_data_raw [0:NUM_GROUPS-1];
    reg [1:0] acc_rd_bank_sel0_d;

    // ============================================================
    // PE_core_v2
    // ============================================================
    PE_core_v2 #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .K_ACCUM_DEPTH(K_ACCUM_DEPTH),
        .MAC_LATENCY(MAC_LATENCY),
        .OS_MAC_LATENCY(OS_MAC_LATENCY),
        .GROUP_SIZE(GROUP_SIZE),
        .NUM_GROUPS(NUM_GROUPS)
    ) u_pe_core (
        .clock(clock),
        .rst_n(rst_n),
        .fsa_mode(fsa_mode),
        .group_mode(group_mode),
        .alu_start(alu_start_reg),
        .cycle_num(cycle_num_reg),
        .sram_rdata_w(pe_sram_rdata_w),
        .sram_rdata_v(pe_sram_rdata_v),
        .acc_en(acc_en),
        .mul_outcome(pe_mul_outcome),
        .result_valid(pe_result_valid),
        .fsa_l_input(pe_fsa_l_input),
        .fsa_l_input_valid(pe_fsa_l_input_valid_final),
        .fsa_ctrl_mac(pe_ctrl_mac),
        .fsa_ctrl_acc_ui(pe_ctrl_acc_ui),
        .fsa_ctrl_load_reg_li(pe_ctrl_load_reg_li),
        .fsa_ctrl_load_reg_ui(pe_ctrl_load_reg_ui),
        .fsa_ctrl_flow_lr(pe_ctrl_flow_lr),
        .fsa_ctrl_flow_ud(pe_ctrl_flow_ud),
        .fsa_ctrl_flow_du(pe_ctrl_flow_du),
        .fsa_ctrl_update_reg(pe_ctrl_update_reg),
        .fsa_ctrl_exp2(pe_ctrl_exp2),
        .fsa_ctrl_delay_rev(pe_ctrl_delay_rev),
        .fsa_exp2_cmp_active(cmp_d_output_valid_r2[0]),
        .fsa_chunk1_sel(fsm_chunk1_sel),
        .fsa_chunk1_acc_in(acc_sram_rd_data_raw[acc_rd_bank_sel0_d]),
        .cmp_d_output_bus(cmp_d_output_bus),
        .cmp_score_out(cmp_score_out),
        .cmp_score_valid(cmp_score_valid),
        .acc_data_out(acc_data_out),
        .acc_data_valid(acc_data_valid)
    );

    // ============================================================
    // CMP × 4（每组1个，多分组模式下复用）
    // ============================================================
    // CMP ctrl输入寄存器（切断FSM→CMP组合路径）
    reg        cmp_ctrl_valid_r;
    reg [2:0]  cmp_ctrl_cmd_r;
    reg [7:0]  cmp_causal_counter_r;
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            cmp_ctrl_valid_r    <= 1'b0;
            cmp_ctrl_cmd_r      <= 3'd0;
            cmp_causal_counter_r <= 8'd0;
        end else begin
            cmp_ctrl_valid_r    <= fsm_cmp_ctrl_valid;
            cmp_ctrl_cmd_r      <= fsm_cmp_ctrl_cmd;
            cmp_causal_counter_r <= fsm_cmp_causal_counter;
        end
    end

    // CMP输入：每个CMP直接接对应物理组PE[0]的score
    // vertical chain串联后，逻辑组顶部PE[0]的score已是完整点积
    // 非逻辑组顶部的CMP置idle（输入0，valid=0）
    wire [DATA_WIDTH-1:0] cmp_input_score [0:NUM_GROUPS-1];
    wire [NUM_GROUPS-1:0] cmp_input_valid;

    // 判断每个物理组是否为逻辑组顶部
    wire [NUM_GROUPS-1:0] cmp_is_logical_top;
    assign cmp_is_logical_top[0] = 1'b1;  // 组0在所有模式下都是逻辑顶部
    assign cmp_is_logical_top[1] = (group_mode == 2'b00);  // 仅4×8模式
    assign cmp_is_logical_top[2] = (group_mode == 2'b00) || (group_mode == 2'b01);  // 4×8或2×16
    assign cmp_is_logical_top[3] = (group_mode == 2'b00);  // 仅4×8模式

    generate
        for (gi = 0; gi < NUM_GROUPS; gi = gi + 1) begin : CMP_MUX
            assign cmp_input_score[gi] = cmp_is_logical_top[gi] ?
                cmp_score_out_r[gi*DATA_WIDTH +: DATA_WIDTH] : {DATA_WIDTH{1'b0}};
            assign cmp_input_valid[gi] = cmp_is_logical_top[gi] ?
                cmp_score_valid_r[gi] : 1'b0;
        end
    endgenerate

    generate
        for (gi = 0; gi < NUM_GROUPS; gi = gi + 1) begin : CMP_INST
            wire cmp_out_ctrl_valid;
            wire [2:0] cmp_out_ctrl_cmd;
            wire [7:0] cmp_out_causal_counter;

            CMP u_cmp (
                .clock(clock),
                .rst_n(rst_n),
                .io_d_input_bits_sign(cmp_input_score[gi][31]),
                .io_d_input_bits_exp(cmp_input_score[gi][23 +: 8]),
                .io_d_input_bits_mantissa(cmp_input_score[gi][22:0]),
                .io_d_output_valid(cmp_d_output_valid[gi]),
                .io_d_output_bits_sign(cmp_d_output[gi][31]),
                .io_d_output_bits_exp(cmp_d_output[gi][30:23]),
                .io_d_output_bits_mantissa(cmp_d_output[gi][22:0]),
                .io_in_ctrl_valid(cmp_input_valid[gi] | cmp_ctrl_valid_r),
                .io_in_ctrl_bits_cmd(cmp_ctrl_cmd_r),
                .io_in_ctrl_bits_causalCounter(cmp_causal_counter_r),
                .io_out_ctrl_valid(cmp_out_ctrl_valid),
                .io_out_ctrl_bits_cmd(cmp_out_ctrl_cmd),
                .io_out_ctrl_bits_causalCounter(cmp_out_causal_counter)
            );
        end
    endgenerate

    // ============================================================
    // fsa_acc_sram × 4 + fsa_accumulator × 4（每组1个，单通道）
    // ============================================================
    wire acc_sram_wr_en;
    wire [6:0] acc_sram_wr_addr;  // 7位：rowsum地址=head_dim可达64（Fix C）

    // ACC SRAM写控制：
    // S_ACC_CLEAR期间：FSM强制写零清除残留
    // 其他时候：由Accumulator的sram_out_valid驱动
    wire acc_wr_blocked = fsm_acc_wr_blocked;
    assign acc_sram_wr_en = fsm_acc_clear_en ? 1'b1 :
                            (acc_sram_out_valid[0] & ~acc_wr_blocked);

    // 地址延迟链：SRAM读延迟(1) + ACC_LATENCY = 总延迟
    localparam ACC_ADDR_DELAY = 1 + ACC_LATENCY;
    reg [6:0] acc_sram_addr_pipe [0:ACC_ADDR_DELAY-1];  // 7位（Fix C）
    integer adi;
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            for (adi = 0; adi < ACC_ADDR_DELAY; adi = adi + 1)
                acc_sram_addr_pipe[adi] <= '0;
        end else begin
            acc_sram_addr_pipe[0] <= acc_sram_rd_addr;
            for (adi = 1; adi < ACC_ADDR_DELAY; adi = adi + 1)
                acc_sram_addr_pipe[adi] <= acc_sram_addr_pipe[adi-1];
        end
    end
    assign acc_sram_wr_addr = fsm_acc_clear_en ? fsm_acc_clear_addr :
                              acc_sram_addr_pipe[ACC_ADDR_DELAY-1];

    // ============================================================
    // rowsum独立寄存器：从ACC_SRAM地址空间拆出来（原33深=32列O+1行rowsum，
    // "+1"这个rowsum地址正是导致深度不是2的幂、需要比较器译码的根源）。
    // FSM(fsa_ctrl_fsm.sv)读/写"rowsum"的地址是ROWSUM_ADDR=head_dim（O有多少列，
    // rowsum就存在那之后），这里在ACC_SRAM边界处把命中该地址的读写重定向到独立
    // 寄存器，对FSM透明——本地复现同一个head_dim公式（由本模块已有的head_dim端口
    // 直接派生，不需要新引一根跨模块的线）
    // ============================================================
    wire [6:0] mt_rowsum_addr = head_dim[6:0];  // 7位：head_dim=64时rowsum地址=64，不再截断成0（Fix C）
    wire acc_wr_hits_rowsum = (acc_sram_wr_addr == mt_rowsum_addr);

    reg [DATA_WIDTH-1:0] rowsum_reg [0:NUM_GROUPS-1];
    integer rsi;
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            for (rsi = 0; rsi < NUM_GROUPS; rsi = rsi + 1)
                rowsum_reg[rsi] <= '0;
        end else if (acc_sram_wr_en && acc_wr_hits_rowsum) begin
            for (rsi = 0; rsi < NUM_GROUPS; rsi = rsi + 1)
                rowsum_reg[rsi] <= fsm_acc_clear_en ? {DATA_WIDTH{1'b0}} :
                    acc_sram_out[rsi*DATA_WIDTH +: DATA_WIDTH];
        end
    end

    // 读侧：命中rowsum地址时，打1拍匹配SRAM 1拍读延迟，决定sram_in该取SRAM还是rowsum_reg
    reg rowsum_rd_sel_d;
    always_ff @(posedge clock) begin
        if (!rst_n)
            rowsum_rd_sel_d <= 1'b0;
        else
            rowsum_rd_sel_d <= acc_sram_rd_en && (acc_sram_rd_addr == mt_rowsum_addr);
    end

    // ============================================================
    // chunk1部分和FIFO地址译码：head_dim>32时chunk1的逐行部分和暂存和O列累加器
    // 如果共用同一段地址(0~31)，tile1+时O列已持久化跨tile结果，chunk1的暂存写入
    // 会把它冲掉。固定从地址65开始单独开一段FIFO区(65~96，
    // 对应seq_tile_len最多32个槽位)——65是因为rowsum地址=head_dim，head_dim
    // 最大64，65往后保证跟O列(0~63)和rowsum(<=64)都不重叠，不随head_dim变化。
    // bank分配：4个bank各分8深，紧跟在每个bank现有16深O列之后(bank内地址
    // 16~23)，每个fsa_acc_sram实例DEPTH相应从16扩到24
    // ============================================================
    localparam [6:0] ACC_FIFO_BASE = 7'd65;
    wire acc_addr_is_fifo_wr = (acc_sram_wr_addr >= ACC_FIFO_BASE);
    wire acc_addr_is_fifo_rd = (acc_sram_rd_addr >= ACC_FIFO_BASE);
    // 先做全宽度减法再截取低5位：地址最大96(7'b1100000)，若先截[4:0]会把高位
    // 减没，算出错误的偏移
    wire [6:0] fifo_idx_wr_full = acc_sram_wr_addr - ACC_FIFO_BASE;
    wire [6:0] fifo_idx_rd_full = acc_sram_rd_addr - ACC_FIFO_BASE;
    wire [4:0] fifo_idx_wr = fifo_idx_wr_full[4:0];  // 0~31
    wire [4:0] fifo_idx_rd = fifo_idx_rd_full[4:0];
    wire [1:0] fifo_bank_wr = fifo_idx_wr[4:3];
    wire [1:0] fifo_bank_rd = fifo_idx_rd[4:3];
    // bank内本地地址(5位，0~23)：O列直接用原有[3:0]补0；FIFO用16+偏移(2'b10前缀)
    wire [4:0] acc_local_addr_wr = acc_addr_is_fifo_wr ?
        {2'b10, fifo_idx_wr[2:0]} : {1'b0, acc_sram_wr_addr[3:0]};
    wire [4:0] acc_local_addr_rd = acc_addr_is_fifo_rd ?
        {2'b10, fifo_idx_rd[2:0]} : {1'b0, acc_sram_rd_addr[3:0]};

    // O列bank写入：rowsum地址已重定向掉，这里只处理O列（地址<eff_group_size）
    // 4×8/2×16：每个bank各自写自己组的真实O列结果（地址天然≤15，不拼接）
    // 1×32：只有Acc[0]真实，按wr_addr[5:4]两位拼到4个bank（挪用Acc[1]/[2]/[3]原本会
    //   写入自己无意义数据的bank）——head_dim<=32时地址≤31，addr[5]恒为0，自然只在
    //   bank0/1间选，跟上一版2-bank combine行为完全一致；head_dim=64时四个bank都用上，
    //   构成64深拼接
    wire acc_wr_active = acc_sram_wr_en && !acc_wr_hits_rowsum;
    reg [NUM_GROUPS-1:0] acc_bank_we;
    reg [DATA_WIDTH-1:0] acc_bank_wdata [0:NUM_GROUPS-1];
    integer abi;
    always_comb begin
        acc_bank_we = '0;
        for (abi = 0; abi < NUM_GROUPS; abi = abi + 1)
            acc_bank_wdata[abi] = '0;
        if (group_mode == 2'b10) begin // 1×32
            if (acc_addr_is_fifo_wr) begin
                // chunk1的FIFO写：只在dual_chunk_mode(head_dim>32，必为1×32)下发生，
                // bank由fifo_bank_wr选(跟O列bank-select是同一路2选4mux，只是bank
                // index来源不同)。fsm_acc_clear_en为真时是chunk1每个tile自带的
                // "锚定槎位清零"(FSM每次进CHUNK1_DOWN都显式清一次FIFO首槎位，不依赖
                // tile0专属的S_ACC_CLEAR，因为tile1+会跳过它)，要写literal 0
                acc_bank_we[fifo_bank_wr] = acc_wr_active;
                acc_bank_wdata[fifo_bank_wr] =
                    fsm_acc_clear_en ? {DATA_WIDTH{1'b0}} : acc_sram_out[0*DATA_WIDTH +: DATA_WIDTH];
            end else begin
                acc_bank_we[acc_sram_wr_addr[5:4]] = acc_wr_active;
                acc_bank_wdata[acc_sram_wr_addr[5:4]] =
                    fsm_acc_clear_en ? {DATA_WIDTH{1'b0}} : acc_sram_out[0*DATA_WIDTH +: DATA_WIDTH];
            end
        end else begin // 4×8, 2×16
            for (abi = 0; abi < NUM_GROUPS; abi = abi + 1) begin
                acc_bank_we[abi] = acc_wr_active;
                acc_bank_wdata[abi] = fsm_acc_clear_en ? {DATA_WIDTH{1'b0}} :
                    acc_sram_out[abi*DATA_WIDTH +: DATA_WIDTH];
            end
        end
    end

    // 读侧bank选择：只有Acc[0]在1×32模式需要跨bank读取(借bank1~3延伸到32/64深)，
    // 其余gi始终读自己的bank——跟写侧对称，打1拍匹配BRAM读延迟
    // （声明已前向挪到PE_core_v2例化之前，这里只保留驱动逻辑）
    always_ff @(posedge clock) begin
        if (!rst_n)
            acc_rd_bank_sel0_d <= 2'd0;
        else
            acc_rd_bank_sel0_d <= (group_mode == 2'b10) ?
                (acc_addr_is_fifo_rd ? fifo_bank_rd : acc_sram_rd_addr[5:4]) : 2'd0;
    end

    // delta_m锁存寄存器（per-group）
    // 逻辑组→物理组映射表（CMP顶部和PE底部共用索引逻辑）
    // Acc[la]的CMP源 = 逻辑组la的顶部物理组
    // Acc[la]的PE底部源 = 逻辑组la的底部物理组
    wire [1:0] logical_cmp_src [0:NUM_GROUPS-1];  // delta_m用：逻辑Acc[la]←CMP[src]
    wire [1:0] logical_bot_src [0:NUM_GROUPS-1];  // acc_logical_bot用：Acc[la]←acc_data_out[src]
    assign logical_cmp_src[0] = 2'd0;  // 所有模式：逻辑组0的CMP=物理组0
    assign logical_cmp_src[1] = (group_mode == 2'b01) ? 2'd2 : 2'd1;
    assign logical_cmp_src[2] = 2'd2;
    assign logical_cmp_src[3] = 2'd3;
    assign logical_bot_src[0] = (group_mode == 2'b10) ? 2'd3 :
                                 (group_mode == 2'b01) ? 2'd1 : 2'd0;
    assign logical_bot_src[1] = (group_mode == 2'b01) ? 2'd3 : 2'd1;
    assign logical_bot_src[2] = 2'd2;
    assign logical_bot_src[3] = 2'd3;

    reg [DATA_WIDTH-1:0] delta_m_reg [0:NUM_GROUPS-1];
    integer dmi;
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            for (dmi = 0; dmi < NUM_GROUPS; dmi = dmi + 1)
                delta_m_reg[dmi] <= '0;
        end else if (pe_acc_latch_delta) begin
            for (dmi = 0; dmi < NUM_GROUPS; dmi = dmi + 1)
                delta_m_reg[dmi] <= cmp_d_output_bus[logical_cmp_src[dmi]*DATA_WIDTH +: DATA_WIDTH];
        end
    end

    // ============================================================
    // SiLU 微序列（GEMV 模式复用这 4 个累加器通道，零新增算术单元）
    //
    // 数据来源与去向都是 Output SRAM：GEMV 算完后 write_out_v2 已把 32 个 PE
    // 结果序列化成 4 bank × 8 拍写进去，这里逐地址读出→过 7 步微程序→原地写回，
    // 之后才由 DMA 搬回 DDR。4 个 bank 与 4 个累加器通道天然一一对应。
    //
    // 中间量用寄存器而非 fsa_acc_sram 暂存：每通道只要 x/num/den 三个 32bit
    // 寄存器，省掉一整套地址管理与 SRAM 读延迟对齐。
    // ============================================================
    // 常数 1.0 复用上文 :633 已声明的 FP32_ONE
    //
    // EXP_S1 的乘数在 FSA 模式下取 attn_scale(=log2(e)/sqrt(head_dim))，但 SiLU
    // 需要的是纯 log2(e)。不能让软件在跑 GEMV 前额外写一次 REG_ATTN_SCALE：那会把
    // 两种模式耦合到同一个寄存器上，忘配就静默算错（实测复位值 0x3F0293EE 对应
    // head_dim=8，会把 exp2 的输入缩掉 2.83 倍，结果全错）。这里按模式直接选常数，
    // 软件侧无需感知。
    localparam [31:0] FP32_LOG2E = 32'h3FB8AA3B;   // log2(e) = 1.4426950408889634
    wire [31:0] acc_attn_scale = fsa_mode ? attn_scale : FP32_LOG2E;

    wire silu_sa_sel_negx, silu_sa_sel_one;
    wire [1:0] silu_sram_src;
    wire silu_cap_x, silu_cap_num_neg_only, silu_cap_den;
    wire silu_osram_rd_en, silu_osram_wr_en;
    wire [3:0] silu_osram_addr;

    reg [DATA_WIDTH-1:0] silu_x_reg   [0:3];   // 从 Output SRAM 读回的原始 x
    reg [DATA_WIDTH-1:0] silu_num_reg [0:3];   // 分子：x>=0 时为 x，x<0 时为 t*x
    reg [DATA_WIDTH-1:0] silu_den_reg [0:3];   // 分母：1+t

    silu_ctrl_fsm #(
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_LATENCY(ACC_LATENCY)
    ) u_silu_fsm (
        .clock            (clock),
        .rst_n            (rst_n),
        .silu_start       (silu_start & ~fsa_mode),   // FSA 模式下彻底禁用
        .num_elem         (silu_num_elem),
        .silu_done        (silu_done),
        .acc_recip_done   (acc_reciprocal_done[0]),
        .acc_ctrl_valid   (silu_acc_ctrl_valid),
        .acc_ctrl_cmd     (silu_acc_ctrl_cmd),
        .sa_sel_negx      (silu_sa_sel_negx),
        .sa_sel_one       (silu_sa_sel_one),
        .sram_src         (silu_sram_src),
        .cap_x            (silu_cap_x),
        .cap_num_neg_only (silu_cap_num_neg_only),
        .cap_den          (silu_cap_den),
        .osram_rd_en      (silu_osram_rd_en),
        .osram_wr_en      (silu_osram_wr_en),
        .osram_addr       (silu_osram_addr)
    );

    // sa_in MUX: EXP_S1时用delta_m_reg，其他时候用acc_data_out
    wire acc_sa_in_sel_delta = fsm_acc_ctrl_valid & (fsm_acc_ctrl_cmd == 3'd0); // EXP_S1

    generate
        for (gi = 0; gi < NUM_GROUPS; gi = gi + 1) begin : ACC_INST
            // ACC SRAM：O列存储(16深，rowsum已拆到独立寄存器) + chunk1部分和FIFO
            // (8深，地址16~23)，合计24深。4×8/2×16模式下本地地址≤15
            // 天然不溢出，FIFO段不会被触达(dual_chunk_mode必为1×32)；1×32模式下
            // Acc[0]的O地址16-31和FIFO地址16-23都由acc_bank_we/wdata路由进这个
            // bank，本bank自己只需读写本地5位地址(acc_local_addr_wr/rd)
            fsa_acc_sram #(
                .NUM_CH(1),
                .DEPTH(24),
                .DATA_WIDTH(DATA_WIDTH)
            ) u_acc_sram (
                .clock(clock),
                .rst_n(rst_n),
                .rd_en(acc_sram_rd_en),
                .rd_addr(acc_local_addr_rd),
                .rd_data(acc_sram_rd_data_raw[gi]),
                .wr_en(acc_bank_we[gi]),
                .wr_addr(acc_local_addr_wr),
                .wr_data(acc_bank_wdata[gi])
            );

            // sa_in: EXP_S1时用delta_m_reg，其他用逻辑组底部PE的d_output
            wire [DATA_WIDTH-1:0] acc_logical_bot = acc_data_out[logical_bot_src[gi]*DATA_WIDTH +: DATA_WIDTH];

            // FSA 模式沿用原逻辑；GEMV+SiLU 模式按微程序取 -|x|（步骤1）或 1.0（步骤4）。
            // -|x| 就是把符号位强制拉高，不需要真的做减法。
            wire [DATA_WIDTH-1:0] acc_sa_in_fsa = acc_sa_in_sel_delta ?
                delta_m_reg[gi] : acc_logical_bot;
            wire [DATA_WIDTH-1:0] acc_sa_in_silu =
                silu_sa_sel_negx ? {1'b1, silu_x_reg[gi][DATA_WIDTH-2:0]} :
                silu_sa_sel_one  ? FP32_ONE : {DATA_WIDTH{1'b0}};
            wire [DATA_WIDTH-1:0] acc_sa_in_muxed = fsa_mode ? acc_sa_in_fsa : acc_sa_in_silu;

            // sram_in: rowsum命中→rowsum_reg；Acc[0]在1×32模式按bank_sel0跨bank
            // 读取(借用gi=1~3的bank延伸到32/64深)；其余gi始终读自己的bank
            wire [DATA_WIDTH-1:0] acc_sram_rd_data_fsa =
                rowsum_rd_sel_d ? rowsum_reg[gi] :
                (gi == 0) ? acc_sram_rd_data_raw[acc_rd_bank_sel0_d] :
                acc_sram_rd_data_raw[gi];
            // SiLU 模式下 sram_in 不来自 ACC SRAM，而是微程序的中间量寄存器
            wire [DATA_WIDTH-1:0] acc_sram_rd_data_silu =
                (silu_sram_src == 2'd0) ? silu_x_reg[gi]   :
                (silu_sram_src == 2'd1) ? silu_num_reg[gi] :
                (silu_sram_src == 2'd2) ? silu_den_reg[gi] : FP32_ONE;
            wire [DATA_WIDTH-1:0] acc_sram_rd_data =
                fsa_mode ? acc_sram_rd_data_fsa : acc_sram_rd_data_silu;

            // Accumulator（单通道）
            fsa_accumulator #(
                .NUM_CH(1),
                .DATA_WIDTH(DATA_WIDTH),
                .ACC_LATENCY(ACC_LATENCY)
            ) u_acc (
                .clock(clock),
                .rst_n(rst_n),
                .attn_scale(acc_attn_scale),   // FSA用CSR值，GEMV+SiLU用固定log2(e)
                .ctrl_valid(fsm_acc_ctrl_valid),
                .ctrl_cmd(fsm_acc_ctrl_cmd),
                .sa_in(acc_sa_in_muxed),
                .sram_in(fsm_acc_clear_en ? 32'h3F800000 : acc_sram_rd_data),
                .sram_out(acc_sram_out[gi*DATA_WIDTH +: DATA_WIDTH]),
                .sram_out_valid(acc_sram_out_valid[gi]),
                .reciprocal_done(acc_reciprocal_done[gi])
            );
        end
    endgenerate

    // ============================================================
    // Output SRAM (4 bank × 32b × 16深) + write_out_v2
    // FSA模式: NORM阶段Accumulator输出写入
    // OS模式: write_out_v2序列化PE结果写入
    // 深度从8改成16是为支持head_dim=64（O有64列，4bank×16=64，地址从5位扩到6位）
    // ============================================================
    wire [3:0] out_sram_wr_en;
    wire [3:0] out_sram_wr_addr;
    wire [DATA_WIDTH-1:0] out_sram_wr_data [0:3];

    // write_out_v2（OS模式）
    wire [3:0] wo_bank_wr_en;
    wire [2:0] wo_wr_addr;
    wire [DATA_WIDTH-1:0] wo_wr_data_0, wo_wr_data_1, wo_wr_data_2, wo_wr_data_3;

    write_out_v2 #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_write_out (
        .clock(clock),
        .rst_n(rst_n),
        .result_valid(pe_result_valid),
        .parallel_data_in(pe_mul_outcome),
        .bank_wr_en(wo_bank_wr_en),
        .wr_addr(wo_wr_addr),
        .wr_data_0(wo_wr_data_0),
        .wr_data_1(wo_wr_data_1),
        .wr_data_2(wo_wr_data_2),
        .wr_data_3(wo_wr_data_3),
        .write_done(wo_write_done)
    );

    // FSA NORM写入信号
    wire fsa_out_wr_en = acc_sram_out_valid[0] & fsm_out_wr_active;

    // Output SRAM写MUX: FSA模式用NORM输出，OS模式用write_out_v2
    // 多分组模式下，活跃Acc的输出按地址高位路由到不同bank
    // 深度16之后2×16模式恰好1个bank装满16元素，不再需要addr[3]在bank对之间切换
    wire [1:0] fsa_out_bank_sel = acc_sram_wr_addr[5:4];  // 地址高位选bank
    wire [3:0] fsa_out_bank_addr = acc_sram_wr_addr[3:0]; // 地址低位为bank内偏移（16深）

    // 4×8模式: 4个Acc各写各自bank（原行为，只用每个16深bank的前8）
    // 2×16/1×32模式Output SRAM写入
    // 4×8: 4个Acc同时写4个bank，addr=acc_sram_wr_addr[2:0]（仅用前8深度）
    // 2×16: NORM输出16元素，每个Acc独占一个完整16深bank：Acc[0]→bank0, Acc[1]→bank2（bank1/3不用）
    // 1×32: NORM输出32列(head_dim<=32)或64列(head_dim=64)，addr[5:4]选bank（统一2位译码，
    //   head_dim<=32时地址≤31，addr[5]恒为0，自然只用到bank0/1；head_dim=64时用满bank0-3）
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : OUT_WR_MUX
            // GEMV 模式下若 SiLU 正在回写，数据取对应通道的累加器输出（原地覆盖）；
            // 否则仍是 write_out_v2 的 PE 结果。
            assign out_sram_wr_data[gi] = fsa_mode ?
                ((group_mode == 2'b00) ? acc_sram_out[gi*DATA_WIDTH +: DATA_WIDTH] :
                 (group_mode == 2'b01) ? acc_sram_out[(gi/2)*DATA_WIDTH +: DATA_WIDTH] :
                 acc_sram_out[0*DATA_WIDTH +: DATA_WIDTH]) :
                (silu_osram_wr_en ? acc_sram_out[gi*DATA_WIDTH +: DATA_WIDTH] :
                (gi == 0 ? wo_wr_data_0 : gi == 1 ? wo_wr_data_1 :
                 gi == 2 ? wo_wr_data_2 : wo_wr_data_3));
        end
    endgenerate

    assign out_sram_wr_en = fsa_mode ?
        ((group_mode == 2'b00) ? {4{fsa_out_wr_en}} :
         (group_mode == 2'b01) ? (fsa_out_wr_en ? 4'b0101 : 4'b0000) :
         (fsa_out_wr_en ? (4'b0001 << acc_sram_wr_addr[5:4]) : 4'b0000)) :
        (silu_osram_wr_en ? 4'b1111 : wo_bank_wr_en);
    assign out_sram_wr_addr = fsa_mode ?
        acc_sram_wr_addr[3:0] :
        (silu_osram_wr_en ? silu_osram_addr : wo_wr_addr);

    // Output SRAM 4 bank例化（深度8→16，支持head_dim=64时O的64列）
    wire [DATA_WIDTH-1:0] out_sram_rdata [0:3];
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : OUT_SRAM
            sram #(
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_WIDTH(4)
            ) u_out_sram (
                .clk(clock),
                .csb(1'b0),
                .wsb(~out_sram_wr_en[gi]),
                .rst(~rst_n),
                .waddr(out_sram_wr_addr),
                .wdata(out_sram_wr_data[gi]),
                // SiLU 期间读口被微序列借用；其余时间归 DMA 读出
                .raddr(silu_osram_rd_en ? silu_osram_addr : dma_o_sram_raddr),
                .rdata(out_sram_rdata[gi])
            );
        end
    endgenerate

    assign dma_o_sram_rdata = {out_sram_rdata[3], out_sram_rdata[2],
                               out_sram_rdata[1], out_sram_rdata[0]};

    // ============================================================
    // SiLU 中间量寄存器更新
    // 放在这里是因为要用 out_sram_rdata 与 acc_sram_out，两者都在上文定义。
    // ============================================================
    integer si;
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            for (si = 0; si < 4; si = si + 1) begin
                silu_x_reg[si]   <= '0;
                silu_num_reg[si] <= '0;
                silu_den_reg[si] <= '0;
            end
        end else begin
            // 读回的 x 同时作为 num 的初值——x>=0 的通道后面不再更新 num，
            // 分子就是 x 本身
            if (silu_cap_x) begin
                for (si = 0; si < 4; si = si + 1) begin
                    silu_x_reg[si]   <= out_sram_rdata[si];
                    silu_num_reg[si] <= out_sram_rdata[si];
                end
            end
            // 步骤3：命令是广播的，4 路都算了 t*x，但只有 x<0 的通道捕获结果。
            // 分支落在这个写使能上，不落在命令序列上。
            if (silu_cap_num_neg_only) begin
                for (si = 0; si < 4; si = si + 1)
                    if (silu_x_reg[si][DATA_WIDTH-1])
                        silu_num_reg[si] <= acc_sram_out[si*DATA_WIDTH +: DATA_WIDTH];
            end
            // 步骤4：1+t
            if (silu_cap_den) begin
                for (si = 0; si < 4; si = si + 1)
                    silu_den_reg[si] <= acc_sram_out[si*DATA_WIDTH +: DATA_WIDTH];
            end
        end
    end

endmodule

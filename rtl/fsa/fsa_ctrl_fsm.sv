`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// fsa_ctrl_fsm
//
// FSA控制状态机，驱动完整FlashAttention流程。
// 包含：DMA_Q→LOAD_Q→CMP_RESET→[tile循环]→RECIPROCAL→NORM→DMA_O
//
// 关键设计：
//   - 双向数据流：上行(QK, delay_rev=0)和下行(SUBTRACT/SCALE/EXP2/ROWSUM/PV, delay_rev=1)
//   - bypass模式：仅LOAD_Q和LOAD_REG_UI绕过延迟匹配
//   - SCORE_RESTREAM: score从CMP回流到PE，锁存到score_buf
//   - LOAD_REG_UI: PE.reg ← score_buf
//   - SUBTRACT: CMP PROP_MAX输出-newMax，MAC(score,1,-newMax)=S-m
//   - delta_m直接从CMP锁存（acc_latch_delta信号）
//   - 事件驱动CMP_UPDATE：由cmp_score_valid触发
//   - ACC SRAM地址控制：O[0~7] + rowsum[8]
////////////////////////////////////////////////////////////////
module fsa_ctrl_fsm #(
    parameter GROUP_SIZE  = 8,
    parameter MAC_LATENCY = 5,
    parameter DATA_WIDTH  = 32,
    parameter ACC_PIPE_LATENCY = 6,
    parameter CMP_OUT_LATENCY = 3,  // CMP总延迟（ctrl输入寄存器1 + 输出寄存器2）
    parameter ACC_SRAM_DEPTH = 9
)(
    input  clock,
    input  rst_n,

    // 启动与配置
    input  fsa_start,
    input  [7:0] head_dim,
    input  [1:0] group_mode,  // FSA分组模式: 0=4×8, 1=2×16, 2=1×32
    input  [7:0] seq_tile_len,
    input  [12:0] num_kv_tiles,
    input  [7:0] last_tile_valid,  // 最后tile有效行数（0=满tile）

    // 输出控制信号（送PE_core_v2）
    output reg ctrl_mac,
    output reg ctrl_acc_ui,
    output reg ctrl_load_reg_li,
    output reg ctrl_load_reg_ui,    // LOAD_REG_UI: PE.reg ← u_input(pipe中残留的score)
    output reg ctrl_flow_lr,
    output reg ctrl_flow_ud,
    output reg ctrl_flow_du,
    output reg ctrl_update_reg,
    output reg ctrl_exp2,
    output reg ctrl_delay_rev,  // 反向延迟匹配（flow_down阶段用）
    output reg ctrl_valid,

    // delta_m锁存信号（送Accumulator）
    output reg acc_latch_delta,

    // Q缓冲加载完成脉冲（实际存储已搬到mac_top_v2.sv统一的4×8深bank）
    output reg q_buf_fire,

    // Input SRAM读控制
    output reg input_sram_rd_en,
    output reg [5:0] input_sram_rd_addr,

    // Vector SRAM控制
    output reg vec_sram_rd_en,
    output reg [5:0] vec_sram_addr,

    // CMP控制
    output reg cmp_ctrl_valid,
    output reg [2:0] cmp_ctrl_cmd,
    output reg [7:0] cmp_causal_counter,

    // CMP score输入（事件驱动CMP_UPDATE）
    input  cmp_score_valid_in,
    // score FIFO写使能（仅QK_MAC有效score窗口，排除跨tile残留）
    output wire score_fifo_wr_en,
    output wire score_fifo_masked,  // 当前score需要被mask为-inf

    // Accumulator控制
    output reg acc_ctrl_valid,
    output reg [2:0] acc_ctrl_cmd,

    // ACC SRAM控制
    output reg acc_sram_rd_en,
    output reg [6:0] acc_sram_rd_addr,

    // DMA完成信号（outer FSM自主发DMA后通知inner）
    input  dma_done,

    // K/V缓冲区已装载（电平，由outer维护）。dma_done是K/V/O共用的一根脉冲，
    // inner分辨不出这一笔属于谁，只能靠状态窗口去猜——地址分区后K和V的DMA窗口
    // 会重叠，猜法必然失效。outer按自己停在WAIT_K还是WAIT_V一清二楚，故由它给。
    input  k_buf_loaded,
    input  v_buf_loaded,

    // tile 0的K已由权重预取提前搬进Input SRAM。电平型，从预取命中一直保持到
    // K被QK_MAC读完——预取发生在fsa_start之前，本FSM那时尚未启动，只有电平
    // 才能被后来走到S_ACC_CLEAR的自己看见。
    input  k_tile0_preloaded,

    // Accumulator状态
    input  acc_reciprocal_done,

    // 状态输出
    output reg fsm_busy,
    output reg fsm_done,
    output reg [4:0] fsm_state,
    // ---- 语义化状态输出 ----
    // mac_top_v2 原本自己抄一份状态编码(LS_*)去译码 fsm_state，那份副本与这里的
    // localparam 是"改一处漏一处就静默算错、没有任何机制会报"的隐式契约，而且它只抄
    // 了用得到的子集（缺 5'd9/15/17），中间插新状态时编号一移就悄悄错位。改由本模块
    // 直接给出语义信号，编码只此一份。全部是 state 的纯组合译码，不改变任何相位。
    output wire       score_wr_idx_rst,  // 每tile进QK_MAC前清score写指针
    output wire       score_restream,    // score从FIFO回流阶段
    output wire       score_bus_hold,    // cmp输出总线改取FIFO寄存器（回流期保持最后值）
    output wire       q_buf_load_win,    // q_buf可装载/预取的窗口
    output wire       exp2_active,       // EXP2段（分段计数器的计数窗口）
    output wire       broadcast_active,  // 向PE广播常数的段
    output wire [1:0] broadcast_sel,     // 0=1.0  1=attn_scale  2=exp2斜率
    output wire       pe_load_q,         // PE的l_input取q_buf
    output wire       pe_mac_stream,     // PE的l_input取Input SRAM的32bank并行读
    output wire       acc_wr_blocked,    // RECIPROCAL/NORM期间禁止acc_sram写
    output wire       out_wr_active,     // NORM段，累加器结果写回Output SRAM

    output wire fsa_k_read_done,  // K DMA完成，outer FSM可安全发V DMA
    output wire fsa_v_read_done,  // V数据已被PV_MAC读完，outer FSM可安全发下一tile K DMA

    // ACC SRAM清零控制（S_ACC_CLEAR阶段使用）
    output reg acc_clear_en,
    output reg [6:0] acc_clear_addr,

    // head_dim>32两段QK chunk：S_QK_MAC(chunk2)期间为高，告诉PE[31].d_input
    // 改读chunk1暂存在ACC_SRAM里的部分和（而非硬接0）。head_dim<=32时
    // dual_chunk_mode恒为0，本信号恒为0，PE[31]退化为原硬接0，不影响现有行为
    output wire chunk1_sel
);

    // ============================================================
    // 状态编码（连续编号，无空洞）
    // ============================================================
    localparam S_IDLE          = 5'd0;
    localparam S_LOAD_Q_BUF    = 5'd1;
    localparam S_LOAD_Q_FIRE   = 5'd2;
    localparam S_CMP_RESET     = 5'd3;
    localparam S_ACC_CLEAR     = 5'd4;   // 清零acc_sram（解决连续FSA残留问题）
    localparam S_DMA_K         = 5'd5;
    // S_QK_MAC_CHUNK1_DOWN: head_dim>32时chunk1(前32维)的下行链QK乘积，
    // 编码5'd6驱动PE.ctrl_delay_rev反向延迟匹配，chunk2通过S_QK_MAC完成
    localparam S_QK_MAC_CHUNK1_DOWN = 5'd6;
    localparam S_QK_MAC        = 5'd7;
    localparam S_SCORE_RESTREAM = 5'd8;
    localparam S_ZERO_FLOWDU   = 5'd9;
    localparam S_LOAD_REG_UI   = 5'd10;
    localparam S_SUBTRACT      = 5'd11;
    localparam S_SCALE         = 5'd12;
    localparam S_EXP2          = 5'd13;
    localparam S_ROWSUM        = 5'd14;
    localparam S_DMA_V         = 5'd15;
    localparam S_PV_MAC        = 5'd16;
    localparam S_TILE_CHECK    = 5'd17;
    localparam S_RECIPROCAL    = 5'd18;
    localparam S_NORM          = 5'd19;
    localparam S_DMA_O         = 5'd20;
    localparam S_DONE          = 5'd21;

    // CMP命令编码
    localparam CMP_UPDATE    = 3'd0;
    localparam CMP_PROP_MAX  = 3'd1;
    localparam CMP_PROP_DIFF = 3'd2;
    localparam CMP_PROP_ZERO = 3'd3;
    localparam CMP_RESET     = 3'd4;
    localparam CMP_PROP_EXP2 = 3'd5;

    // Accumulator命令编码
    localparam ACC_EXP_S1    = 3'd0;
    localparam ACC_EXP_S2    = 3'd1;
    localparam ACC_ACC_SA    = 3'd2;
    localparam ACC_ACC       = 3'd3;
    localparam ACC_SET_SCALE = 3'd4;
    localparam ACC_RECIPROCAL= 3'd5;

    // chunk1部分和FIFO基址（跟mac_top_v2.sv保持一致）：固定65，
    // 不随head_dim变化（head_dim<=64时rowsum地址<=64，65往后保证不重叠）
    localparam [6:0] ACC_FIFO_BASE = 7'd65;

    // ACC SRAM地址常量
    // drain拍数（运行时由group_mode决定有效组大小）
    wire [5:0] eff_group_size = (group_mode == 2'b10) ? 6'd32 :
                                (group_mode == 2'b01) ? 6'd16 : 6'd8;
    // 组间预延迟（QK方向顶部组的延迟拍数）
    // 参数化公式：(逻辑组内物理组数-1) × GROUP_SIZE × MAC_LATENCY
    //          = (eff_group_size - GROUP_SIZE) × MAC_LATENCY
    // 自动随 MAC_LATENCY 跟随，避免硬编码失配。验证(LAT=4)：4×8=0, 2×16=32, 1×32=96
    wire [8:0] GROUP_PRE_DELAY = (eff_group_size - GROUP_SIZE[5:0]) * MAC_LATENCY;
    wire [8:0] QK_DRAIN_CYCLES = (eff_group_size - 1) * MAC_LATENCY + MAC_LATENCY + GROUP_PRE_DELAY;
    // PV_MAC/ROWSUM的drain：逻辑组底部PE的commit延迟
    // = MAC_LATENCY × 逻辑组PE数 = MAC_LATENCY × eff_group_size
    // 4×8: 4×8=32, 2×16: 4×16=64, 1×32: 4×32=128
    wire [8:0] PV_DRAIN_CYCLES = eff_group_size * MAC_LATENCY;

    // head_dim>32：拆成chunk1(前32维，走下行链)+chunk2(后32维，走上行链=原S_QK_MAC)
    // head_dim<=32时(当前HEAD_DIM寄存器合法范围)恒为0，新状态/chunk1_sel永不触发
    wire dual_chunk_mode = (head_dim > 8'd32);

    // V在Input SRAM里的起始地址。K占addr[0, seq_tile_len)，V紧随其后——两者分区后
    // 互不覆盖，outer FSM才敢在上一tile还在算的时候就搬下一tile的K。
    // dual_chunk时 seq_tile_len(32)+head_dim(48/64) 超过SRAM深度64，放不下，基址取0
    // 退回与K重叠的原布局。CB_top_v2.sv 的写侧有同一份推导（fsa_v_addr_base），
    // 两处必须一致。
    wire [5:0] v_addr_base = dual_chunk_mode ? 6'd0 : seq_tile_len[5:0];

    // rowsum地址 = head_dim（O有多少列，rowsum就存在那之后；head_dim<=32时
    // 数值上等于eff_group_size，对现有场景是等价替换，head_dim>32时才会分岔）
    // 必须用7位：head_dim=64时6位会截断成0、跟O[0]地址碰撞（Fix C）
    wire [6:0] ROWSUM_ADDR = head_dim[6:0];

    // ============================================================
    // 内部寄存器
    // ============================================================
    (* mark_debug = "true" *) reg [4:0] state;
    reg [4:0] state_next;

    // S_QK_MAC(chunk2)期间为高，告诉PE[31].d_input改读chunk1暂存的部分和
    assign chunk1_sel = (state == S_QK_MAC) && dual_chunk_mode;

    (* mark_debug = "true" *) reg [8:0] cnt;
    reg [8:0] cnt_next;
    reg [12:0] tile_idx, tile_idx_next;
    reg [7:0] score_cnt, score_cnt_next;  // CMP_UPDATE事件计数
    reg v_dma_done_q;  // V DMA提前完成锁存（ROWSUM期间预取V用）
    reg k_dma_done_q;  // K DMA提前完成锁存（PV_MAC drain期间预取K用）
    reg input_sram_k_read_done;  // Input SRAM中K数据已被TRANSPOSE_K读完，V可安全写入
    // head_dim>32时，本tile的chunk1是否已完成。S_DMA_K/S_ACC_CLEAR会等K DMA完成后
    // 决定进chunk1还是chunk2，必须用这个标志区分"等chunk1的K"和"等chunk2的K"两种语境，
    // 否则chunk2的K到了之后会被误判成"还没做chunk1"，重新跳回CHUNK1_DOWN，永久死循环
    // （chunk2的K完成→S_DMA_K→无条件回CHUNK1_DOWN→chunk1再跑一遍→又回S_DMA_K→
    // 没有新的dma_done→永久卡死，V DMA永远不会被outer FSM发起）
    reg chunk1_done_q;

    // K/V数据就绪判据。分区模式用outer给的电平；dual_chunk模式逐字保留原判据
    // （K要两笔DMA、V的提前到位靠v_dma_done_q锁存），保证hd48/hd64零回归。
    // 三个而不是两个：S_ROWSUM尾部问的是"V是否已提前到位、可以跳过等待"，
    // S_DMA_V问的是"V到了没"，dual模式下这两者用的信号本就不同。
    //
    // 分区模式下 k_dma_done_q/v_dma_done_q 不再参与判定。k_dma_done_q 本身是死逻辑
    // （锁存窗口 state>=S_PV_MAC(16) && state<=S_LOAD_Q_FIRE(2) 跨回绕误用&&，恒假；
    // 就算改成||，清零条件含 state_next==S_DMA_K 也会在进消费点的同一个沿把它清掉），
    // 这里不去修它——修了会改变 dual_chunk 的行为，破坏"逐位不变"这条判据。
    // 它想覆盖的场景在分区模式下由 k_buf_loaded 正确处理。
    wire k_ready       = dual_chunk_mode ? (dma_done || k_dma_done_q) : k_buf_loaded;
    wire v_ready_early = dual_chunk_mode ? v_dma_done_q               : v_buf_loaded;
    wire v_ready       = dual_chunk_mode ? dma_done                   : v_buf_loaded;

    // score FIFO写使能：QK_MAC期间有效score
    assign score_fifo_wr_en = (state == S_QK_MAC) && cmp_score_valid_in;

    // score mask：最后tile超出有效行的score需要被mask为-inf
    wire score_is_masked = (tile_idx == num_kv_tiles - 8'd1) && (last_tile_valid != 8'd0)
                           && (score_cnt >= last_tile_valid);
    assign score_fifo_masked = score_is_masked;

    // ============================================================
    // 状态寄存器
    // ============================================================
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            cnt       <= 8'd0;
            tile_idx  <= 8'd0;
            score_cnt <= 8'd0;
            v_dma_done_q <= 1'b0;
            k_dma_done_q <= 1'b0;
            input_sram_k_read_done <= 1'b0;
            chunk1_done_q <= 1'b0;
        end else begin
            state     <= state_next;
            cnt       <= cnt_next;
            tile_idx  <= tile_idx_next;
            score_cnt <= score_cnt_next;
            // V DMA完成锁存（限制在计算阶段，排除DMA_O写回的dma_done）
            if (input_sram_k_read_done && dma_done &&
                state >= S_QK_MAC && state <= S_DMA_V) begin
                v_dma_done_q <= 1'b1;
            end
            else if (state_next == S_PV_MAC || state_next == S_DMA_V)
                v_dma_done_q <= 1'b0;
            // K DMA完成锁存（outer FSM预取K完成时，inner在PV_MAC/TILE_CHECK/LOAD_Q等状态）
            if (!k_dma_done_q && dma_done &&
                state >= S_PV_MAC && state <= S_LOAD_Q_FIRE) begin
                k_dma_done_q <= 1'b1;
            end
            else if (state_next == S_QK_MAC || state_next == S_DMA_K)
                k_dma_done_q <= 1'b0;
            // Input SRAM K读取完毕标志：K行全被PE消费后置位，V DMA可安全发起
            // QK_MAC在cnt=seq_tile_len时读完全部K行（最后有效数据在cnt=seq_tile_len时被PE消费）
            if (state == S_QK_MAC && cnt == seq_tile_len)
                input_sram_k_read_done <= 1'b1;
            else if (state_next == S_ACC_CLEAR || state_next == S_DMA_K)
                input_sram_k_read_done <= 1'b0;
            // chunk1完成标志：每个tile从S_LOAD_Q_FIRE进入时清零（覆盖tile0经ACC_CLEAR
            // 和tile1+经DMA_K两条路径，两条都必经S_LOAD_Q_FIRE），CHUNK1_DOWN转到
            // S_DMA_K时置1，让S_DMA_K下一次能正确识别"该等chunk2的K"而不是重新等chunk1
            if (state == S_LOAD_Q_FIRE)
                chunk1_done_q <= 1'b0;
            else if (state == S_QK_MAC_CHUNK1_DOWN && state_next == S_DMA_K)
                chunk1_done_q <= 1'b1;
        end
    end

    assign fsm_state = state;

    // 语义化状态输出（见端口处说明）。纯组合译码，与原 mac_top_v2 里的 LS_* 判断逐条等价。
    assign score_wr_idx_rst = (state == S_ACC_CLEAR) || (state == S_DMA_K);
    assign score_restream   = (state == S_SCORE_RESTREAM);
    assign score_bus_hold   = (state == S_SCORE_RESTREAM) || (state == S_LOAD_REG_UI);
    assign q_buf_load_win   = (state == S_LOAD_Q_BUF) || (state == S_QK_MAC_CHUNK1_DOWN) ||
                              (state == S_PV_MAC);
    assign exp2_active      = (state == S_EXP2);
    assign broadcast_active = (state == S_SUBTRACT) || (state == S_ROWSUM) ||
                              (state == S_SCALE)    || (state == S_EXP2);
    assign broadcast_sel    = (state == S_SCALE) ? 2'd1 :
                              (state == S_EXP2)  ? 2'd2 : 2'd0;
    assign pe_load_q        = (state == S_LOAD_Q_FIRE);
    assign pe_mac_stream    = (state == S_QK_MAC) || (state == S_QK_MAC_CHUNK1_DOWN) ||
                              (state == S_PV_MAC);
    assign acc_wr_blocked   = (state == S_RECIPROCAL) || (state == S_NORM);
    assign out_wr_active    = (state == S_NORM);
    assign fsa_k_read_done = input_sram_k_read_done;
    // PV_MAC读循环边界已改成head_dim（见下方S_PV_MAC），这里跟着同步，
    // 否则head_dim>seq_tile_len时会在V还没读完时就提前告知outer FSM"V已读完"
    assign fsa_v_read_done = (state == S_PV_MAC) && (cnt >= head_dim);

    // ============================================================
    // 状态转移与输出逻辑
    // ============================================================
    always_comb begin
        // 默认值
        state_next      = state;
        cnt_next        = cnt;
        tile_idx_next   = tile_idx;
        score_cnt_next  = score_cnt;

        ctrl_mac        = 1'b0;
        ctrl_acc_ui     = 1'b0;
        ctrl_load_reg_li = 1'b0;
        ctrl_load_reg_ui = 1'b0;
        ctrl_flow_lr    = 1'b0;
        ctrl_flow_ud    = 1'b0;
        ctrl_flow_du    = 1'b0;
        ctrl_update_reg = 1'b0;
        ctrl_exp2       = 1'b0;
        ctrl_delay_rev  = 1'b0;
        ctrl_valid      = 1'b0;
        q_buf_fire      = 1'b0;

        input_sram_rd_en = 1'b0;
        input_sram_rd_addr = 6'd0;
        vec_sram_rd_en  = 1'b0;
        vec_sram_addr   = 6'd0;

        cmp_ctrl_valid  = 1'b0;
        cmp_ctrl_cmd    = 3'd0;
        cmp_causal_counter = 8'd0;

        acc_ctrl_valid  = 1'b0;
        acc_ctrl_cmd    = 3'd0;
        acc_latch_delta = 1'b0;
        acc_clear_en    = 1'b0;
        acc_clear_addr  = 7'd0;

        acc_sram_rd_en  = 1'b0;
        acc_sram_rd_addr = 7'd0;


        fsm_busy        = 1'b1;
        fsm_done        = 1'b0;

        case (state)
            // ========================================
            S_IDLE: begin
                fsm_busy = 1'b0;
                cnt_next = 8'd0;
                tile_idx_next = 8'd0;
                score_cnt_next = 8'd0;
                if (fsa_start)
                    state_next = S_LOAD_Q_BUF; // Q已由控制器预加载到Vector SRAM，跳过DMA_Q
            end

            // ========================================
            // Q加载：读Vector SRAM到缓冲 + 1拍等待
            // ========================================
            S_LOAD_Q_BUF: begin
                // dual模式：q_buf只有32深，这里只装chunk1段Q[0:31]（偏移固定0）；
                // chunk2段Q[32:63]改在S_QK_MAC_CHUNK1_DOWN执行期间并行预取进q_buf
                // （input_sram读K和vec_sram读Q是两个独立端口，互不冲突，省掉chunk1
                // 做完后再串行等一次装载的周期）。非dual模式：行为不变
                if (dual_chunk_mode) begin
                    if (cnt < 8'd32) begin
                        vec_sram_rd_en = 1'b1;
                        vec_sram_addr  = cnt[5:0];
                    end
                    if (cnt == 8'd32) begin
                        state_next = S_LOAD_Q_FIRE;
                        cnt_next   = 8'd0;
                    end else
                        cnt_next = cnt + 8'd1;
                end else begin
                    if (cnt < head_dim) begin
                        vec_sram_rd_en = 1'b1;
                        vec_sram_addr  = cnt[5:0];
                    end
                    if (cnt == head_dim) begin
                        state_next = S_LOAD_Q_FIRE;
                        cnt_next   = 8'd0;
                    end else
                        cnt_next = cnt + 8'd1;
                end
            end

            // Q并行加载到PE
            S_LOAD_Q_FIRE: begin
                ctrl_load_reg_li = 1'b1;
                ctrl_valid       = 1'b1;
                q_buf_fire       = 1'b1;
                // chunk1_done_q这一拍仍读到"刚做完chunk1"的值（下面的寄存器更新本周期
                // 末才清零）：为真时说明q_buf已在chunk1期间被并行换成chunk2段Q，这次
                // S_LOAD_Q_FIRE只是把它推进PE.reg，直接进S_QK_MAC（chunk2）
                if (chunk1_done_q)
                    state_next = S_QK_MAC;
                // 首tile需要CMP_RESET，后续tile跳过（保留oldMax用于delta_m计算）
                else if (tile_idx == 8'd0)
                    state_next = S_CMP_RESET;
                else
                    state_next = S_DMA_K;
                cnt_next   = 8'd0;
            end

            // ========================================
            // CMP复位
            // ========================================
            S_CMP_RESET: begin
                cmp_ctrl_valid = 1'b1;
                cmp_ctrl_cmd   = CMP_RESET;
                state_next = S_ACC_CLEAR;
                cnt_next   = 8'd0;
            end

            // ========================================
            // 清零acc_sram + 复位accumulator scale + 同时发起DMA_K
            // acc_sram清零和DMA_K使用不同资源，可并行执行
            // ========================================
            S_ACC_CLEAR: begin
                // ACC SRAM清零（逐地址写0）
                // 边界用head_dim而非eff_group_size：head_dim>32时O列有33~63、rowsum在
                // 地址head_dim，必须全部显式清零，否则这些地址从复位起从未写过、读出X，
                // 后续ACC_SA的SET_SCALE=0锚定在行为级浮点乘法里可能把X传播出来（Fix C）。
                // head_dim<=32时head_dim==eff_group_size，对现有场景是等价替换
                if (cnt <= head_dim) begin
                    acc_clear_en   = 1'b1;
                    acc_clear_addr = cnt[6:0];
                end
                // 复位scale（在清零最后一拍）
                if (cnt == head_dim) begin
                    acc_ctrl_valid = 1'b1;
                    acc_ctrl_cmd   = ACC_SET_SCALE;
                end
                // 等待K DMA完成（outer FSM已自主发出）+ acc清零完成
                // chunk1_done_q刚被S_LOAD_Q_FIRE清零，dual模式下这里一定走CHUNK1_DOWN
                // （ACC_CLEAR只在tile0、每个tile的chunk1开始前才会经过，不会是等chunk2）
                // 三个放行来源：本tile的K DMA刚完成(dma_done)、更早完成时被锁存
                // (k_dma_done_q)、或tile 0的K由预取提前搬好(k_tile0_preloaded)。
                // 最后一种没有真DMA发生，因而也等不到dma_done。
                if (cnt > head_dim && (k_ready || k_tile0_preloaded)) begin
                    state_next = (dual_chunk_mode && !chunk1_done_q) ? S_QK_MAC_CHUNK1_DOWN : S_QK_MAC;
                    cnt_next   = 8'd0;
                end else if (cnt <= head_dim) begin
                    cnt_next = cnt + 1;
                end
                // cnt > head_dim后不再递增，防止溢出
            end

            // ========================================
            // 等待K DMA完成（outer FSM自主调度）
            // ========================================
            S_DMA_K: begin
                // dual模式下S_DMA_K依chunk1_done_q走两条路径：0→CHUNK1_DOWN(等chunk1的K)；
                // 1→LOAD_Q_FIRE(等chunk2的K，顺带把预取好的chunk2段Q推进PE.reg)。
                // 必须靠chunk1_done_q区分，否则chunk2的K完成后会被误送回CHUNK1_DOWN重做
                // chunk1，永远等不到新dma_done，死循环卡死
                if (k_ready) begin
                    state_next = (dual_chunk_mode && !chunk1_done_q) ? S_QK_MAC_CHUNK1_DOWN :
                                 (dual_chunk_mode ? S_LOAD_Q_FIRE : S_QK_MAC);
                    cnt_next   = 8'd0;
                end
            end

            // ========================================
            // QK_MAC_CHUNK1_DOWN：head_dim>32时chunk1(前32维)的Q·K reduction。
            // 跟chunk2(下面的S_QK_MAC)是镜像结构——同样逐行流过K(cnt=0..seq_tile_len-1，
            // K的bank=col/addr=row布局不变)，但走下行链(u_input→d_output)：
            // ctrl_acc_ui/flow_ud/delay_rev全部置1(对齐PV_MAC/ROWSUM那条链的方向，
            // delay网络相对chunk2是反过来的)，CMP用CMP_PROP_ZERO持续播种0(同PV_MAC手法，
            // 不触发真实rowmax折算)。结果按行drain出来后用ACC_SA写入ACC_FIFO区
            // （地址ACC_FIFO_BASE起，不是O列地址——见下方SET_SCALE锚定和drain写入的
            // 具体实现），完成后回到S_DMA_K等chunk2的K数据DMA完成，再进入chunk2/
            // S_QK_MAC，那里的PE[31].d_input会读回这里写入的部分和(chunk1_sel)
            // ========================================
            S_QK_MAC_CHUNK1_DOWN: begin
                ctrl_mac       = 1'b1;
                ctrl_flow_lr   = 1'b1;
                ctrl_acc_ui    = 1'b1;
                ctrl_flow_ud   = 1'b1;
                ctrl_delay_rev = 1'b1;
                cmp_ctrl_valid = 1'b1;
                cmp_ctrl_cmd   = CMP_PROP_ZERO;
                // K逐行流过：cnt=0..seq_tile_len-1（跟S_QK_MAC同一套地址序）
                if (cnt < seq_tile_len) begin
                    input_sram_rd_en   = 1'b1;
                    input_sram_rd_addr = cnt[5:0];
                end
                if (cnt >= 1 && cnt <= seq_tile_len)
                    ctrl_valid = 1'b1;
                // 并行预取chunk2段Q[32:63]进q_buf：vec_sram读口跟上面K用的
                // input_sram读口是两个独立端口，互不冲突；PE.reg此刻仍持有chunk1的Q，
                // 不受q_buf被覆写影响（reg早已在进CHUNK1_DOWN前由S_LOAD_Q_FIRE锁定）。
                // 本状态drain拍数(PV_DRAIN_CYCLES=eff_group_size*MAC_LATENCY，1×32模式
                // 下eff_group_size=32)远超32拍，足够覆盖这个预取窗口
                if (cnt < 8'd32) begin
                    vec_sram_rd_en = 1'b1;
                    vec_sram_addr  = cnt[5:0] + 6'd32;
                end
                // SET_SCALE=0锚定：不能读O列地址0——O列地址0对tile1+持久存着上一个
                // tile的真实O值，不是0，会把污染的非零值锚成scale，进而让下面的ACC_SA
                // 把陈旧O值错误叠加进chunk1的暂存写入。改成显式清零FIFO首槎位
                // (ACC_FIFO_BASE)再读回，不依赖S_ACC_CLEAR(tile1+会跳过它)，每个tile
                // 独立保证锚定为真0：cnt=0清零→cnt=1发起读→cnt=2读数据有效，发SET_SCALE
                if (cnt == 8'd0) begin
                    acc_clear_en   = 1'b1;
                    acc_clear_addr = ACC_FIFO_BASE;
                end
                if (cnt == 8'd1) begin
                    acc_sram_rd_en   = 1'b1;
                    acc_sram_rd_addr = ACC_FIFO_BASE;
                end
                if (cnt == 8'd2) begin
                    acc_ctrl_valid = 1'b1;
                    acc_ctrl_cmd   = ACC_SET_SCALE;
                end
                // drain：逻辑组底部PE commit时刻，按行写回FIFO区(ACC_FIFO_BASE+行号，
                // 不用裸行号0~31，避免撞上O列同一段地址)
                if (cnt >= PV_DRAIN_CYCLES && cnt < seq_tile_len + PV_DRAIN_CYCLES) begin
                    acc_sram_rd_en   = 1'b1;
                    acc_sram_rd_addr = ACC_FIFO_BASE + (cnt - PV_DRAIN_CYCLES);
                end
                if (cnt >= PV_DRAIN_CYCLES + 1 && cnt < seq_tile_len + PV_DRAIN_CYCLES + 1) begin
                    acc_ctrl_valid = 1'b1;
                    acc_ctrl_cmd   = ACC_ACC_SA;
                end
                if (cnt == seq_tile_len + PV_DRAIN_CYCLES + ACC_PIPE_LATENCY + 1) begin
                    state_next = S_DMA_K;  // 等chunk2(后32维)的K DMA完成
                    cnt_next   = 8'd0;
                end else
                    cnt_next = cnt + 8'd1;
            end

            // ========================================
            // QK MAC：直接SRAM读K行，flow_lr正向延迟，连续发射N行K + drain
            // ========================================
            S_QK_MAC: begin
                ctrl_mac     = 1'b1;
                ctrl_flow_lr = 1'b1;
                // SRAM读地址：cnt=0..seq_tile_len-1
                if (cnt < seq_tile_len) begin
                    input_sram_rd_en   = 1'b1;
                    input_sram_rd_addr = cnt[5:0];
                end
                // dual模式chunk2：读回chunk1暂存在ACC_SRAM的逐行部分和，喂给PE[31]的
                // d_input（fsa_chunk1_sel mux），把两段32宽reduction拼成完整score。
                // 与input_sram读同cnt：ACC读口和input SRAM都是1拍读延迟，chunk1部分和
                // 与K[r]在cnt+1同拍到达PE[31]（PE[31]为上行链底部，DELAY_FWD=0）。
                // 不发则PE[31].d_input读到未驱动的ACC口=X，score全X。地址加
                // ACC_FIFO_BASE偏移：chunk1的drain写入用的就是这段FIFO区，这里
                // 读回必须用同一套地址，不能再用裸行号
                if (dual_chunk_mode && cnt < seq_tile_len) begin
                    acc_sram_rd_en   = 1'b1;
                    acc_sram_rd_addr = ACC_FIFO_BASE + {1'b0, cnt[5:0]};
                end
                // ctrl_valid：cnt=1..seq_tile_len（对齐SRAM 1拍读延迟）
                if (cnt >= 1 && cnt <= seq_tile_len)
                    ctrl_valid = 1'b1;
                // CMP UPDATE：事件驱动，score到达CMP时
                if (cmp_score_valid_in) begin
                    cmp_ctrl_valid = 1'b1;
                    cmp_ctrl_cmd   = CMP_UPDATE;
                    // 最后tile且last_tile_valid≠0时，超出有效行的score用causalCounter mask
                    // score_cnt从0开始计数，>=last_tile_valid的score需要mask
                    if (tile_idx == num_kv_tiles - 8'd1 && last_tile_valid != 8'd0
                        && score_cnt >= last_tile_valid)
                        cmp_causal_counter = 8'd1;  // 非零即mask
                    else
                        cmp_causal_counter = 8'd0;
                    score_cnt_next = score_cnt + 8'd1;
                end
                // drain阶段：等待所有score到达CMP并写入FIFO
                // +2拍确保最后score在state 7内完成写入
                if (cnt == seq_tile_len + QK_DRAIN_CYCLES + 2) begin
                    state_next = S_SCORE_RESTREAM;
                    cnt_next   = 8'd0;
                    score_cnt_next = 8'd0;
                end else
                    cnt_next = cnt + 8'd1;
            end

            // ========================================
            // SCORE_RESTREAM：score从CMP回流（PE间pipe链移位寄存器）
            // CMP UPDATE已在QK_MAC阶段全部完成
            // ========================================
            S_SCORE_RESTREAM: begin
                ctrl_flow_ud = 1'b1;   // 持续保持pipe链连接
                // ctrl_valid只在FIFO有效输出期间为1（前seq_tile_len拍）
                if (cnt < seq_tile_len)
                    ctrl_valid = 1'b1;
                // score进入pipe后立即LOAD_REG_UI（不等预延迟，flow_ud chain不经过预延迟SR）
                if (cnt == seq_tile_len + 1) begin
                    state_next = S_LOAD_REG_UI;
                    cnt_next   = 8'd0;
                end else
                    cnt_next = cnt + 8'd1;
            end

            // ========================================
            // ZERO_FLOWDU：零值上行清除残留
            // ========================================
            S_ZERO_FLOWDU: begin
                ctrl_flow_du = 1'b1;
                if (cnt == 8'd0)
                    ctrl_valid = 1'b1;
                if (cnt == QK_DRAIN_CYCLES) begin
                    state_next = S_SUBTRACT;
                    cnt_next   = 8'd0;
                end else
                    cnt_next = cnt + 8'd1;
            end

            // ========================================
            // LOAD_REG_UI：PE.reg ← flow_to_d_q（pipe中残留的score）
            // 保持flow_ud=1防止无条件采样覆盖pipe
            // ========================================
            S_LOAD_REG_UI: begin
                ctrl_flow_ud     = 1'b1;  // 保持pipe链连接
                if (cnt == 8'd0) begin
                    ctrl_load_reg_ui = 1'b1;
                    ctrl_valid       = 1'b1;
                end
                if (cnt == 8'd1) begin
                    cmp_ctrl_valid   = 1'b1;
                    cmp_ctrl_cmd     = CMP_PROP_MAX;
                    state_next = S_ZERO_FLOWDU;
                    cnt_next   = 8'd0;
                end else
                    cnt_next = cnt + 8'd1;
            end

            // ========================================
            // SUBTRACT：S-m (flow_down，反向延迟，1+drain拍)
            // MAC(score, ONE, -newMax) = score - newMax
            // -newMax通过cmp_d_output_bus广播到所有PE的u_input（不走pipe链）
            // 原版mac=0(组合MAC+update_reg)，我们必须mac=1(流水MAC)
            // flow_ud=0: 防止MAC结果覆盖-newMax的pipe传播
            // ========================================
            S_SUBTRACT: begin
                ctrl_delay_rev  = 1'b1;
                // ctrl信号持续整个阶段
                ctrl_mac        = 1'b1;
                ctrl_acc_ui     = 1'b1;   // c来自u_input(-newMax广播)
                ctrl_update_reg = 1'b1;
                ctrl_flow_lr    = 1'b1;
                // flow_ud=0: -newMax不走pipe链，直接广播
                // CMP持续输出-newMax
                cmp_ctrl_valid  = 1'b1;
                cmp_ctrl_cmd    = CMP_PROP_MAX;
                // ctrl_valid延迟CMP_OUT_LATENCY拍（等CMP输出寄存器数据就绪）
                if (cnt == CMP_OUT_LATENCY)
                    ctrl_valid  = 1'b1;   // 1拍valid脉冲进入延迟匹配链
                // SUBTRACT结束时发PROP_MAX_DIFF，锁存delta_m延迟CMP_OUT_LATENCY拍
                if (cnt == PV_DRAIN_CYCLES) begin
                    cmp_ctrl_cmd    = CMP_PROP_DIFF;
                end
                if (cnt == PV_DRAIN_CYCLES + CMP_OUT_LATENCY) begin
                    acc_latch_delta = 1'b1;
                    state_next = S_SCALE;
                    cnt_next   = 8'd0;
                end else
                    cnt_next = cnt + 8'd1;
            end

            // ========================================
            // SCALE：(S-m)*AttentionScale (flow_down，反向延迟，1+drain拍)
            // MAC(S-m, AttentionScale, 0)
            // ========================================
            S_SCALE: begin
                ctrl_delay_rev  = 1'b1;
                // ctrl信号持续整个阶段
                ctrl_mac        = 1'b1;
                ctrl_update_reg = 1'b1;
                ctrl_flow_lr    = 1'b1;
                if (cnt == 8'd0)
                    ctrl_valid  = 1'b1;   // 1拍valid脉冲
                if (cnt == PV_DRAIN_CYCLES) begin
                    state_next = S_EXP2;
                    cnt_next   = 8'd0;
                end else
                    cnt_next = cnt + 8'd1;
            end

            // ========================================
            // EXP2：8段PWL (flow_down，反向延迟，8+drain拍)
            // intercept通过CMP广播（flow_ud=0, acc_ui=1），与slope的×1 tap对齐
            // ========================================
            S_EXP2: begin
                ctrl_delay_rev = 1'b1;
                // ctrl信号持续整个阶段
                ctrl_exp2       = 1'b1;
                ctrl_acc_ui     = 1'b1;
                ctrl_flow_lr    = 1'b1;
                // ctrl_valid延迟CMP_OUT_LATENCY拍（等CMP输出寄存器intercept就绪）
                if (cnt >= CMP_OUT_LATENCY && cnt < head_dim + eff_group_size - 1 + CMP_OUT_LATENCY) begin
                    ctrl_valid  = 1'b1;
                end
                // CMP输出intercept：8段PWL循环输出，持续到覆盖所有PE的pre-delay
                // 4×8: 8拍, 2×16: 8+32=40拍, 1×32: 8+96=104拍
                // CMP内部3位counter自然wrap，循环输出8段intercept
                if (cnt < GROUP_SIZE + GROUP_PRE_DELAY) begin
                    cmp_ctrl_valid  = 1'b1;
                    cmp_ctrl_cmd    = CMP_PROP_EXP2;
                end
                // 等待PE[7]完成最后一段的MAC commit（多等CMP_OUT_LATENCY拍）
                if (cnt == head_dim + eff_group_size - 1 - 1 + QK_DRAIN_CYCLES + CMP_OUT_LATENCY) begin
                    // 提前发CMP_PROP_ZERO，让cmp_d_pipe在ROWSUM开始时已为0
                    cmp_ctrl_valid = 1'b1;
                    cmp_ctrl_cmd   = CMP_PROP_ZERO;
                    ctrl_flow_ud   = 1'b1;  // 使cmp_d_pipe采样更新
                    state_next = S_ROWSUM;
                    cnt_next   = 8'd0;
                end else
                    cnt_next = cnt + 8'd1;
            end

            // ========================================
            // ROWSUM：P×1+累加 (flow_down，反向延迟，1+drain拍)
            // PE[7]在cnt=QK_DRAIN_CYCLES时commit出rowsum
            // tile_idx>0时：drain期间重叠执行EXP_S1/EXP_S2设置scale
            // V DMA请求从QK_MAC开始持续发出（见组合逻辑末尾），此处只做退出判断
            // ========================================
            S_ROWSUM: begin
                ctrl_delay_rev = 1'b1;
                ctrl_mac       = 1'b1;
                ctrl_acc_ui    = 1'b1;
                ctrl_flow_lr   = 1'b1;
                ctrl_flow_ud   = 1'b1;  // vertical链下行累加
                if (cnt == 8'd0) begin
                    ctrl_valid = 1'b1;
                    cmp_ctrl_valid = 1'b1;
                    cmp_ctrl_cmd   = CMP_PROP_ZERO;
                end
                // tile_idx>0: drain期间重叠执行EXP_S1/EXP_S2（设置rescale因子）
                if (tile_idx > 8'd0) begin
                    if (cnt == 8'd1) begin
                        acc_ctrl_valid = 1'b1;
                        acc_ctrl_cmd   = ACC_EXP_S1;
                    end else if (cnt == 1 + ACC_PIPE_LATENCY + 1) begin
                        acc_ctrl_valid = 1'b1;
                        acc_ctrl_cmd   = ACC_EXP_S2;
                    end
                end
                // 逻辑组底部PE commit时刻（1拍valid的drain）
                // 提前1拍读acc_sram[ROWSUM_ADDR]
                if (cnt == PV_DRAIN_CYCLES - 1) begin
                    acc_sram_rd_en   = 1'b1;
                    acc_sram_rd_addr = ROWSUM_ADDR;
                end
                // 逻辑组底部PE commit时发ACC_SA
                if (cnt == PV_DRAIN_CYCLES) begin
                    acc_ctrl_valid = 1'b1;
                    acc_ctrl_cmd   = ACC_ACC_SA;
                end
                // 等待写回完成后：V已完成则直接跳PV_MAC，否则正常S_DMA_V
                if (cnt == PV_DRAIN_CYCLES + ACC_PIPE_LATENCY + 1) begin
                    if (v_ready_early)
                        state_next = S_PV_MAC;
                    else
                        state_next = S_DMA_V;
                    cnt_next   = 8'd0;
                end else
                    cnt_next = cnt + 8'd1;
            end

            // ========================================
            // 等待V DMA完成（outer FSM自主调度）
            // ========================================
            S_DMA_V: begin
                if (v_ready) begin
                    state_next = S_PV_MAC;
                    cnt_next   = 8'd0;
                end
            end

            // ========================================
            // PV MAC：flow_down，反向延迟，直接从SRAM读V行送PE
            // 时序：cnt=0发addr，cnt=1 SRAM输出有效，ctrl_valid从cnt=1开始
            // 逻辑组底部PE commit时刻 = 1 + GROUP_PRE_DELAY + GROUP_SIZE*MAC_LATENCY
            // ========================================
            S_PV_MAC: begin
                ctrl_mac       = 1'b1;
                ctrl_acc_ui    = 1'b1;
                ctrl_flow_lr   = 1'b1;
                ctrl_flow_ud   = 1'b1;
                ctrl_delay_rev = 1'b1;
                cmp_ctrl_valid = 1'b1;
                cmp_ctrl_cmd   = CMP_PROP_ZERO;
                // SRAM读地址：cnt=0..head_dim-1（PV_MAC读的是V的列=O的列，
                // 边界是head_dim不是seq_tile_len——head_dim<=32时两者数值相同，
                // 等价替换；head_dim=64时才会分岔，读完V的全部64列）
                if (cnt < head_dim) begin
                    input_sram_rd_en   = 1'b1;
                    // 加v_addr_base：V已被写侧整体挪到K之后（dual_chunk时基址为0）
                    input_sram_rd_addr = cnt[5:0] + v_addr_base;
                end
                // ctrl_valid：cnt=1..head_dim（对齐SRAM 1拍读延迟）
                if (cnt >= 1 && cnt <= head_dim) begin
                    ctrl_valid  = 1'b1;
                end
                // dual模式：并行预取下一个tile要用的chunk1段Q[0:31]进q_buf，跟
                // S_QK_MAC_CHUNK1_DOWN预取chunk2段Q是同一个技巧——本状态用input_sram
                // 读V，vec_sram读口完全空闲，借这个窗口提前把q_buf刷新回chunk1段，
                // 这样S_TILE_CHECK就不用再绕一次S_LOAD_Q_BUF串行等装载。本状态drain
                // 拍数远超32拍，预取窗口绰绰有余；最后一个tile也会跑这段预取，但
                // 之后不会再有tile用到q_buf，多余的预取无副作用
                if (dual_chunk_mode && cnt < 8'd32) begin
                    vec_sram_rd_en = 1'b1;
                    vec_sram_addr  = cnt[5:0];
                end
                // 逻辑组底部PE首个commit的drain偏移
                // = GROUP_PRE_DELAY + GROUP_SIZE*MAC_LATENCY
                // 4×8: 0+32=32, 2×16: 32+32=64, 1×32: 96+32=128
                // acc_sram预读（对齐逻辑组底部PE commit）
                if (cnt >= PV_DRAIN_CYCLES && cnt < head_dim + PV_DRAIN_CYCLES) begin
                    acc_sram_rd_en   = 1'b1;
                    acc_sram_rd_addr = cnt - PV_DRAIN_CYCLES;
                end
                // ACC_SA（对齐逻辑组底部PE commit）
                if (cnt >= PV_DRAIN_CYCLES + 1 && cnt < head_dim + PV_DRAIN_CYCLES + 1) begin
                    acc_ctrl_valid = 1'b1;
                    acc_ctrl_cmd   = ACC_ACC_SA;
                end
                // 等待最后一笔ACC_SA写回
                if (cnt == head_dim + PV_DRAIN_CYCLES + ACC_PIPE_LATENCY + 1) begin
                    state_next = S_TILE_CHECK;
                    cnt_next   = 8'd0;
                end else
                    cnt_next = cnt + 8'd1;
            end

            // ========================================
            // ========================================
            // TILE_CHECK
            // ========================================
            S_TILE_CHECK: begin
                tile_idx_next = tile_idx + 8'd1;
                if (tile_idx + 1 < num_kv_tiles) begin
                    // 后续tile需要重新加载Q（PV_MAC后PE.reg持有P，不再是Q）。dual模式下
                    // q_buf已经在刚结束的S_PV_MAC期间并行刷新回chunk1段Q[0:31]（借
                    // input_sram读V时vec_sram空闲的窗口），不用再绕S_LOAD_Q_BUF，
                    // 两种模式都直接重新触发S_LOAD_Q_FIRE
                    state_next = S_LOAD_Q_FIRE;
                end else
                    state_next = S_RECIPROCAL;
                cnt_next = 8'd0;
            end

            // ========================================
            // RECIPROCAL：ACC SRAM读rowsum → 1/l
            // ========================================
            S_RECIPROCAL: begin
                if (cnt == 8'd0) begin
                    acc_sram_rd_en = 1'b1;
                    acc_sram_rd_addr = ROWSUM_ADDR;
                end else if (cnt == 8'd1) begin
                    acc_ctrl_valid = 1'b1;
                    acc_ctrl_cmd   = ACC_SET_SCALE;
                end else if (cnt == 8'd2) begin
                    acc_ctrl_valid = 1'b1;
                    acc_ctrl_cmd   = ACC_RECIPROCAL;
                end

                if (acc_reciprocal_done) begin
                    state_next = S_NORM;
                    cnt_next   = 8'd0;
                end else
                    cnt_next = cnt + 8'd1;
            end

            // ========================================
            // NORM：ACC SRAM读O → 乘1/l → Outcome SRAM
            // 使用ACC(cmd=3): out = scale × sram_in（scale已是1/l）
            // ========================================
            S_NORM: begin
                if (cnt == 8'd0) begin
                    // CMP RESET为下一次attention准备
                    cmp_ctrl_valid = 1'b1;
                    cmp_ctrl_cmd   = CMP_RESET;
                end
                // 提前1拍读acc_sram（1拍读延迟，对齐accumulator输入）
                if (cnt < head_dim) begin
                    acc_sram_rd_en = 1'b1;
                    acc_sram_rd_addr = cnt[6:0];  // addr 0~head_dim-1（head_dim=64时需7位）
                end
                // ACC命令延后1拍（等sram_rd_data有效）
                if (cnt >= 8'd1 && cnt <= head_dim) begin
                    acc_ctrl_valid = 1'b1;
                    acc_ctrl_cmd   = ACC_ACC;  // ACC(cmd=3): out = scale × sram_in
                end
                // 等待最后一笔写回完成（最后ctrl在cnt=head_dim, 加ACC_PIPE_LATENCY拍流水延迟）
                if (cnt == head_dim + ACC_PIPE_LATENCY) begin
                    state_next = S_DMA_O;
                    cnt_next   = 8'd0;
                end else
                    cnt_next = cnt + 8'd1;
            end

            // ========================================
            // DMA写回结果（由outer FSM的S_FSA_DMA_O处理）
            // ========================================
            S_DMA_O: begin
                state_next = S_DONE;
                cnt_next   = 8'd0;
            end

            // ========================================
            S_DONE: begin
                fsm_done = 1'b1;
                fsm_busy = 1'b0;
                if (!fsa_start)
                    state_next = S_IDLE;
            end

            default: state_next = S_IDLE;
        endcase
    end

endmodule

`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// PE_core_v2
//
// 升级自PE_core_new，支持OS/WS双模式：
// - OS模式：GEMV计算，与PE_core_new行为一致
// - WS模式：FSA FlashAttention，8×4分组，延迟匹配+vertical累加
//
// 8×4分组：4组×8PE，每组独立计算一个head
// 延迟匹配：组内PE[p]的l_input延迟p×4拍（梯形输入）
// vertical链：QK部分和通过u_output上行到CMP
////////////////////////////////////////////////////////////////
module PE_core_v2 #(
    parameter ARRAY_SIZE     = 32,
    parameter DATA_WIDTH     = 32,
    parameter SRAM_DATA_WIDTH = 32,
    parameter K_ACCUM_DEPTH  = 64,
    parameter OUTCOME_WIDTH  = 32,
    parameter MAC_LATENCY    = 5,
    parameter OS_MAC_LATENCY = 7,   // OS模式总延迟（含pre_add×2+2级加法器）
    parameter GROUP_SIZE     = 8,    // 每组PE数（8×4模式）
    parameter NUM_GROUPS     = 4     // 组数
)(
    input  clock,
    input  rst_n,

    // === 模式选择 ===
    input  fsa_mode,  // 0=GEMV(OS), 1=FSA(WS)
    input  [1:0] group_mode,  // FSA分组模式: 0=4×8, 1=2×16, 2=1×32

    // === OS模式接口（与PE_core_new一致）===
    input  alu_start,
    input  [8:0] cycle_num,
    input  [SRAM_DATA_WIDTH * ARRAY_SIZE - 1:0] sram_rdata_w,
    input  [DATA_WIDTH-1:0] sram_rdata_v,
    input  acc_en,
    output [(ARRAY_SIZE * OUTCOME_WIDTH) - 1:0] mul_outcome,
    output reg result_valid,

    // === WS/FSA模式接口 ===
    // 转置后的K/V行数据，并行送入各PE的l_input
    input  [ARRAY_SIZE * DATA_WIDTH - 1:0] fsa_l_input,
    input  fsa_l_input_valid,

    // FSA控制信号（广播到所有PE）
    input  fsa_ctrl_mac,
    input  fsa_ctrl_acc_ui,
    input  fsa_ctrl_load_reg_li,
    input  fsa_ctrl_load_reg_ui,   // LOAD_REG_UI: PE.reg ← u_input(pipe中残留的score)
    input  fsa_ctrl_flow_lr,
    input  fsa_ctrl_flow_ud,
    input  fsa_ctrl_flow_du,
    input  fsa_ctrl_update_reg,
    input  fsa_ctrl_exp2,
    input  fsa_ctrl_delay_rev, // 反向延迟匹配（SUBTRACT/SCALE/EXP2/ROWSUM/PV用）
    input  fsa_exp2_cmp_active, // EXP2阶段CMP输出intercept有效（门控u_delay_sr采样）

    // head_dim>32的QK两段chunk：PE[31].d_input平时硬接0(chunk1/上行链起点)，
    // chunk2时改读chunk1暂存在ACC_SRAM里的部分和(mac_top_v2.sv侧combine译码后的
    // 合并读数据)，把两个32宽的reduction结果累加成完整head_dim宽的score
    input  fsa_chunk1_sel,
    input  [DATA_WIDTH-1:0] fsa_chunk1_acc_in,

    // CMP下行输入：各组CMP的d_output（下行链顶部数据源）
    input  [NUM_GROUPS * DATA_WIDTH - 1:0] cmp_d_output_bus,

    // CMP输出：各组顶部PE的u_output（QK部分和上行终点）
    output [NUM_GROUPS * DATA_WIDTH - 1:0] cmp_score_out,
    output [NUM_GROUPS - 1:0] cmp_score_valid,

    // Accumulator输出：各组底部PE的d_output（PV结果下行终点）
    output [NUM_GROUPS * DATA_WIDTH - 1:0] acc_data_out,
    output [NUM_GROUPS - 1:0] acc_data_valid
);

    // ================================================================
    // 内部信号声明
    // ================================================================

    localparam integer RESULT_CAPTURE_CYCLE = K_ACCUM_DEPTH + ARRAY_SIZE - 1 + OS_MAC_LATENCY;

    integer i;

    // --- OS模式信号 ---
    reg [ARRAY_SIZE * DATA_WIDTH - 1:0] partial_sum_in;
    reg [ARRAY_SIZE * OUTCOME_WIDTH - 1:0] mul_outcome_reg;
    // 累加清零脉冲，广播到全部 32 个 PE（每个 PE 内部再分发，实测负载 65 个）。
    // 这是纯广播型控制信号，逻辑深度极浅而布线跨越整个 PE 阵列——bitgen 里它单条网络
    // 就占掉关键路径 19.088ns 中的 15.375ns（逻辑仅 0.903ns）。限制扇出让工具复制驱动
    // 寄存器，各副本就近驱动一组 PE；复制出的寄存器逻辑完全等价，不改变任何行为。
    // 该属性只对 Vivado 有效，DC 会忽略（ASIC 侧用 set_max_fanout 另行控制）。
    (* max_fanout = 8 *) reg rst_acc_pulse;
    reg result_latched;

    wire feed_data = alu_start && (cycle_num >= 9'd1) && (cycle_num <= K_ACCUM_DEPTH);
    wire [DATA_WIDTH-1:0] vec_inject = feed_data ? sram_rdata_v : {DATA_WIDTH{1'b0}};

    wire [DATA_WIDTH-1:0] weight_source [0:ARRAY_SIZE-1];
    wire [DATA_WIDTH-1:0] weight_aligned [0:ARRAY_SIZE-1];
    wire [DATA_WIDTH-1:0] vec_chain [0:ARRAY_SIZE];
    wire [OUTCOME_WIDTH-1:0] mac_results_wire [0:ARRAY_SIZE-1];

    // --- WS/FSA模式信号 ---
    wire [DATA_WIDTH-1:0] fsa_l_delayed [0:ARRAY_SIZE-1];  // 延迟匹配后的l_input
    wire [DATA_WIDTH-1:0] fsa_u_delayed [0:ARRAY_SIZE-1];  // 延迟匹配后的u_input(EXP2 intercept)
    wire [ARRAY_SIZE-1:0] fsa_valid_delayed;               // 延迟匹配后的ctrl_valid
    wire [DATA_WIDTH-1:0] pe_u_output [0:ARRAY_SIZE-1];    // 各PE的u_output
    wire [DATA_WIDTH-1:0] pe_d_output [0:ARRAY_SIZE-1];    // 各PE的d_output
    wire [ARRAY_SIZE-1:0] pe_u_output_valid;
    wire [ARRAY_SIZE-1:0] pe_d_output_valid;

    // --- PE输入MUX后的信号 ---
    wire [DATA_WIDTH-1:0] pe_l_input_muxed [0:ARRAY_SIZE-1];
    wire [DATA_WIDTH-1:0] pe_u_input_muxed [0:ARRAY_SIZE-1];
    wire [DATA_WIDTH-1:0] pe_d_input_muxed [0:ARRAY_SIZE-1];
    wire pe_mode_sel [0:ARRAY_SIZE-1];
    wire pe_ctrl_valid [0:ARRAY_SIZE-1];
    // 9个控制信号对所有PE相同，单份广播（减少冗余MUX）
    wire pe_ctrl_mac         = fsa_mode ? fsa_ctrl_mac : 1'b1;
    wire pe_ctrl_acc_ui      = fsa_mode ? fsa_ctrl_acc_ui : 1'b0;
    wire pe_ctrl_load_reg_li = fsa_mode ? fsa_ctrl_load_reg_li : 1'b0;
    wire pe_ctrl_load_reg_ui = fsa_mode ? fsa_ctrl_load_reg_ui : 1'b0;
    wire pe_ctrl_flow_lr     = fsa_mode ? fsa_ctrl_flow_lr : 1'b0;
    wire pe_ctrl_flow_ud     = fsa_mode ? fsa_ctrl_flow_ud : 1'b0;
    wire pe_ctrl_flow_du     = fsa_mode ? fsa_ctrl_flow_du : 1'b0;
    wire pe_ctrl_update_reg  = fsa_mode ? fsa_ctrl_update_reg : 1'b1;
    wire pe_ctrl_exp2        = fsa_mode ? fsa_ctrl_exp2 : 1'b0;

    // ================================================================
    // OS模式逻辑（复用自PE_core_new）
    // ================================================================

    // 累加器初值
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            partial_sum_in <= '0;
        end else if (acc_en) begin
            partial_sum_in <= mul_outcome_reg;
        end else begin
            partial_sum_in <= '0;
        end
    end

    // rst_acc脉冲
    always_ff @(posedge clock) begin
        if (!rst_n)
            rst_acc_pulse <= 1'b0;
        else
            rst_acc_pulse <= (cycle_num == 9'd0);
    end

    // 权重源
    genvar gi;
    generate
        for (gi = 0; gi < ARRAY_SIZE; gi = gi + 1) begin : W_SRC
            assign weight_source[gi] = feed_data
                ? sram_rdata_w[gi*DATA_WIDTH +: DATA_WIDTH]
                : {DATA_WIDTH{1'b0}};
        end
    endgenerate

    assign vec_chain[0] = vec_inject;

    // ================================================================
    // 统一延迟链：OS weight skew + FSA delay matching 复用
    // OS模式：PE[gi]需要gi级延迟做weight对齐
    // FSA模式：每PE需要MAX_DELAY(28)级，从不同tap取数据
    // 两模式互斥，共享同一组移位寄存器
    // ================================================================

    localparam integer MAX_DELAY = (GROUP_SIZE - 1) * MAC_LATENCY;  // 28

    // bypass信号：LOAD_Q/LOAD_REG_UI绕过延迟匹配
    wire fsa_load_bypass = fsa_ctrl_load_reg_li | fsa_ctrl_load_reg_ui;

    // ================================================================
    // 组间预延迟SR（多分组模式扩展）
    // 4×8模式: 无额外延迟（pre_tap=0直通）
    // 2×16/1×32模式: 物理组间需要额外延迟对齐逻辑组内时序
    // 每个PE独立一条预延迟SR（因为各PE接收不同的Transposer数据）
    // ================================================================
    wire [DATA_WIDTH-1:0] fsa_l_pre_delayed [0:ARRAY_SIZE-1];
    wire [ARRAY_SIZE-1:0] fsa_valid_pre_delayed;

    generate
        for (gi = 0; gi < ARRAY_SIZE; gi = gi + 1) begin : GROUP_PRE_DELAY
            localparam integer GROUP_IDX = gi / GROUP_SIZE;
            // QK方向预延迟：组0最大，组3=0
            localparam integer QK_PRE = (NUM_GROUPS - 1 - GROUP_IDX) * GROUP_SIZE * MAC_LATENCY;
            // PV方向预延迟：组0=0，组3最大
            localparam integer PV_PRE = GROUP_IDX * GROUP_SIZE * MAC_LATENCY;
            localparam integer PRE_DEPTH = (QK_PRE > PV_PRE) ? QK_PRE : PV_PRE;

            wire [DATA_WIDTH-1:0] l_raw_in = fsa_l_input[gi*DATA_WIDTH +: DATA_WIDTH];

            if (PRE_DEPTH == 0) begin : NO_PRE_DELAY
                assign fsa_l_pre_delayed[gi] = l_raw_in;
                assign fsa_valid_pre_delayed[gi] = fsa_l_input_valid;
            end else begin : HAS_PRE_DELAY
                // SCORE_RESTREAM bypass：score回流不经预延迟（两个分支共用）
                wire score_restream_bypass = (group_mode != 2'b00) & fsa_ctrl_flow_ud & ~fsa_ctrl_mac & ~fsa_ctrl_exp2;

                localparam integer QK_PRE_2x16 = (GROUP_IDX % 2 == 0) ? GROUP_SIZE * MAC_LATENCY : 0;
                localparam integer PV_PRE_2x16 = (GROUP_IDX % 2 == 1) ? GROUP_SIZE * MAC_LATENCY : 0;

`ifdef ASIC_TARGET
                // ASIC: 定长移位寄存器 + 常量抽头mux
                // pre_tap对固定的某个PE只会在QK_PRE/PV_PRE/QK_PRE_2x16/PV_PRE_2x16这
                // 几个编译期常量间切换（由group_mode/delay_rev选择），不需要支持任意
                // 运行时地址的循环buffer——省掉地址译码逻辑，深度也不用向上取整到2的幂
                reg [DATA_WIDTH-1:0] pre_shift [0:PRE_DEPTH-1];
                // 同 valid_sr：valid 链禁止推断成 SRL（无复位端），见下方长注释
                (* srl_style = "register" *)
                reg [PRE_DEPTH-1:0] pre_valid_sr;
                integer pd;

                always_ff @(posedge clock) begin
                    if (!rst_n) begin
                        for (pd = 0; pd < PRE_DEPTH; pd = pd + 1)
                            pre_shift[pd] <= '0;
                        pre_valid_sr <= '0;
                    end else if (fsa_mode) begin
                        pre_shift[0] <= l_raw_in;
                        for (pd = 1; pd < PRE_DEPTH; pd = pd + 1)
                            pre_shift[pd] <= pre_shift[pd-1];
                        pre_valid_sr <= {pre_valid_sr[PRE_DEPTH-2:0], fsa_l_input_valid & ~fsa_load_bypass};
                    end
                end

                // 常量抽头选择：跟原pre_tap的选择结构完全同构，只是选的是移位寄存器
                // 里的固定下标（综合为硬连线），不是运行时算出来的地址
                wire [DATA_WIDTH-1:0] pre_tap_data =
                    (group_mode == 2'b00) ? l_raw_in :
                    (group_mode == 2'b01) ?
                        (fsa_ctrl_delay_rev ?
                            ((PV_PRE_2x16 == 0) ? l_raw_in : pre_shift[PV_PRE_2x16-1]) :
                            ((QK_PRE_2x16 == 0) ? l_raw_in : pre_shift[QK_PRE_2x16-1])) :
                        (fsa_ctrl_delay_rev ?
                            ((PV_PRE == 0) ? l_raw_in : pre_shift[PV_PRE-1]) :
                            ((QK_PRE == 0) ? l_raw_in : pre_shift[QK_PRE-1]));

                wire valid_tap_data =
                    (group_mode == 2'b00) ? fsa_l_input_valid :
                    (group_mode == 2'b01) ?
                        (fsa_ctrl_delay_rev ?
                            ((PV_PRE_2x16 == 0) ? fsa_l_input_valid : pre_valid_sr[PV_PRE_2x16-1]) :
                            ((QK_PRE_2x16 == 0) ? fsa_l_input_valid : pre_valid_sr[QK_PRE_2x16-1])) :
                        (fsa_ctrl_delay_rev ?
                            ((PV_PRE == 0) ? fsa_l_input_valid : pre_valid_sr[PV_PRE-1]) :
                            ((QK_PRE == 0) ? fsa_l_input_valid : pre_valid_sr[QK_PRE-1]));

                assign fsa_l_pre_delayed[gi] = score_restream_bypass ? l_raw_in : pre_tap_data;
                assign fsa_valid_pre_delayed[gi] = score_restream_bypass ? fsa_l_input_valid : valid_tap_data;
`else
                // 组间预延迟：BRAM循环buffer实现
                // FPGA: ram_style="block"推断BRAM，地址译码不消耗LUT
                // 深度向上取整到2的幂，地址wrap用位掩码
                localparam integer PRE_DEPTH_POW2 = (PRE_DEPTH <= 32) ? 32 :
                                                    (PRE_DEPTH <= 64) ? 64 : 128;
                localparam integer PRE_AW = $clog2(PRE_DEPTH_POW2);

                (* ram_style = "block" *) reg [DATA_WIDTH-1:0] pre_bram [0:PRE_DEPTH_POW2-1];
                reg [PRE_AW-1:0] pre_wr_ptr;
                reg [DATA_WIDTH-1:0] pre_rd_data;

                // valid仍用移位寄存器（1bit宽，LUT开销可忽略）
                // 同 valid_sr：valid 链禁止推断成 SRL（无复位端），见下方长注释
                (* srl_style = "register" *)
                reg [PRE_DEPTH-1:0] pre_valid_sr;
                integer pd;

                wire [6:0] pre_tap = (group_mode == 2'b00) ? 7'd0 :
                                     (group_mode == 2'b01) ?
                                         (fsa_ctrl_delay_rev ? PV_PRE_2x16[6:0] : QK_PRE_2x16[6:0]) :
                                         (fsa_ctrl_delay_rev ? PV_PRE[6:0] : QK_PRE[6:0]);

                // 读地址 = (wr_ptr - pre_tap + 1) & mask（+1补偿BRAM 1拍读延迟）
                wire [PRE_AW-1:0] pre_rd_addr = (pre_wr_ptr - pre_tap[PRE_AW-1:0] + 1) & (PRE_DEPTH_POW2 - 1);

                always_ff @(posedge clock) begin
                    if (!rst_n) begin
                        pre_wr_ptr <= '0;
                        pre_valid_sr <= '0;
                    end else if (fsa_mode) begin
                        pre_bram[pre_wr_ptr] <= l_raw_in;
                        pre_wr_ptr <= (pre_wr_ptr + 1) & (PRE_DEPTH_POW2 - 1);
                        pre_rd_data <= pre_bram[pre_rd_addr];
                        pre_valid_sr <= {pre_valid_sr[PRE_DEPTH-2:0], fsa_l_input_valid & ~fsa_load_bypass};
                    end
                end

                assign fsa_l_pre_delayed[gi] = (pre_tap == 7'd0 || score_restream_bypass) ? l_raw_in : pre_rd_data;
                assign fsa_valid_pre_delayed[gi] = (pre_tap == 7'd0 || score_restream_bypass) ? fsa_l_input_valid : pre_valid_sr[pre_tap - 1];
`endif
            end
        end
    endgenerate

    // ================================================================
    // ctrl逐级传递链（等效原版pipe_no_reset(pe.io.out_ctrl)）
    // flow操作时ctrl从PE[0]逐级传到PE[7]，每级1拍延迟
    // MAC操作时ctrl走l_input延迟匹配链（4拍/级）
    // ================================================================
    // 判断当前是否为纯flow操作（ctrl走逐级链而非延迟匹配）
    // flow_du走ctrl chain，flow_ud(SCORE_RESTREAM)走广播
    // 纯flow模式valid走逐级chain：flow_du（ZERO_FLOWDU）或 flow_ud无MAC无ACC_UI（SCORE_RESTREAM）
    wire fsa_ctrl_is_flow = (fsa_ctrl_flow_du | (fsa_ctrl_flow_ud & ~fsa_ctrl_acc_ui)) & ~fsa_ctrl_mac & ~fsa_ctrl_exp2;

    // 逐级ctrl_valid链：每组内逐级延迟1拍
    // flow_ud(下行): 从组顶PE[0]向PE[7]传播
    // flow_du(上行): 从组底PE[7]向PE[0]传播
    wire [ARRAY_SIZE-1:0] fsa_ctrl_valid_chain;

    // 逻辑组顶部/底部判断（per-PE，CTRL_CHAIN和PE_INST共用）
    wire [ARRAY_SIZE-1:0] pe_is_logical_top;
    wire [ARRAY_SIZE-1:0] pe_is_logical_bottom;
    generate
        for (gi = 0; gi < ARRAY_SIZE; gi = gi + 1) begin : LOGICAL_POS
            localparam integer GI = gi / GROUP_SIZE;
            assign pe_is_logical_top[gi] = (group_mode == 2'b00) ||
                (group_mode == 2'b01 && (GI % 2 == 0)) ||
                (group_mode == 2'b10 && GI == 0);
            assign pe_is_logical_bottom[gi] = (group_mode == 2'b00) ||
                (group_mode == 2'b01 && (GI % 2 == 1)) ||
                (group_mode == 2'b10 && GI == 3);
        end
    endgenerate

    generate
        for (gi = 0; gi < ARRAY_SIZE; gi = gi + 1) begin : CTRL_CHAIN
            localparam integer POS_IN_GROUP = gi % GROUP_SIZE;

            reg ctrl_chain_q;
            always_ff @(posedge clock) begin
                if (!rst_n)
                    ctrl_chain_q <= 1'b0;
                else if (fsa_ctrl_flow_ud) begin
                    if (POS_IN_GROUP == 0 && pe_is_logical_top[gi])
                        ctrl_chain_q <= fsa_l_input_valid;
                    else if (gi == 0)
                        ctrl_chain_q <= fsa_l_input_valid;
                    else
                        ctrl_chain_q <= fsa_ctrl_valid_chain[gi - 1];
                end else if (fsa_ctrl_flow_du) begin
                    if (POS_IN_GROUP == GROUP_SIZE - 1 && pe_is_logical_bottom[gi])
                        ctrl_chain_q <= fsa_l_input_valid;
                    else if (gi == ARRAY_SIZE - 1)
                        ctrl_chain_q <= fsa_l_input_valid;
                    else
                        ctrl_chain_q <= fsa_ctrl_valid_chain[gi + 1];
                end else begin
                    ctrl_chain_q <= 1'b0;
                end
            end
            assign fsa_ctrl_valid_chain[gi] = ctrl_chain_q;
        end
    endgenerate

    // 预计算每组的CMP输出（4份代替32份动态part-select MUX）
    wire [DATA_WIDTH-1:0] cmp_per_group [0:NUM_GROUPS-1];
    generate
        for (gi = 0; gi < NUM_GROUPS; gi = gi + 1) begin : CMP_PRE
            wire [1:0] cmp_idx = (group_mode == 2'b00) ? gi[1:0] :
                                 (group_mode == 2'b01) ? {gi[1], 1'b0} :
                                 2'd0;
            assign cmp_per_group[gi] = cmp_d_output_bus[cmp_idx*DATA_WIDTH +: DATA_WIDTH];
        end
    endgenerate

    generate
        for (gi = 0; gi < ARRAY_SIZE; gi = gi + 1) begin : DELAY_MATCH
            localparam integer POS_IN_GROUP = gi % GROUP_SIZE;
            localparam integer DELAY_FWD = (GROUP_SIZE - 1 - POS_IN_GROUP) * MAC_LATENCY;
            localparam integer DELAY_REV = POS_IN_GROUP * MAC_LATENCY;
            // 精确深度：取OS(gi级)、FSA FWD、FSA REV三者最大值
            localparam integer MAX_FSA = (DELAY_FWD > DELAY_REV) ? DELAY_FWD : DELAY_REV;
            localparam integer UNIFIED_DEPTH = (gi > MAX_FSA) ? gi : MAX_FSA;

            wire [DATA_WIDTH-1:0] fsa_l_raw = fsa_l_pre_delayed[gi];

            // bypass模式时屏蔽延迟链输入
            wire delay_chain_valid_in = fsa_valid_pre_delayed[gi] & ~fsa_load_bypass;

            // begin : HAS_DELAY (commented for DC R-2020.09 compat)
                // 统一移位寄存器链（OS weight skew + FSA delay matching共享）
                reg [DATA_WIDTH-1:0] delay_sr [0:UNIFIED_DEPTH-1];
                // **valid 链必须落在带复位的触发器上，不能让工具推断成 SRL**。
                // SRL16E/SRLC32E 这类原语没有复位端，RTL 里写的 `if(!rst_n) valid_sr<='0`
                // 对被推成 SRL 的那几位是无效的——上电后它们是随机值。
                // valid 是控制流：随机的假 valid 会把流水线里的垃圾数据当成有效数据推进
                // 计算，且**每次上电（每次重下 bit）初值不同 -> 每次结果不同**。
                // 实测：同一 bit 同一程序连跑，输出文本与 total_cycles 都在变；
                // 降频到 25MHz 无改善（与频率无关，正是"初值随机"而非"时序不够"的特征）；
                // 仿真永远照不出来（reg 有确定初值，且 tb 每次都从复位开始）。
                // 综合报告佐证：全设计 3535 个 SRL 全部落在 u_pe_core 里，
                // valid_sr 被拆成 SRL16E（中段，无复位）+ FDRE（首尾，有复位）混合实现。
                (* srl_style = "register" *)
                reg [UNIFIED_DEPTH-1:0] valid_sr;
                integer d;

                // 输入MUX：OS用weight_source，FSA用fsa_l_raw
                wire [DATA_WIDTH-1:0] sr_input = fsa_mode ? fsa_l_raw : weight_source[gi];
                // 使能：OS仅alu_start时移位（否则清零），FSA始终移位
                wire sr_enable = fsa_mode | alu_start;

                always_ff @(posedge clock) begin
                    if (!rst_n) begin
                        for (d = 0; d < UNIFIED_DEPTH; d = d + 1)
                            delay_sr[d] <= '0;
                        valid_sr <= '0;
                    end else if (sr_enable) begin
                        delay_sr[0] <= sr_input;
                        for (d = 1; d < UNIFIED_DEPTH; d = d + 1)
                            delay_sr[d] <= delay_sr[d-1];
                        valid_sr <= {valid_sr[UNIFIED_DEPTH-2:0], delay_chain_valid_in};
                    end else begin
                        // OS模式不活跃时清零（防止残留数据影响下次计算）
                        for (d = 0; d < UNIFIED_DEPTH; d = d + 1)
                            delay_sr[d] <= '0;
                        valid_sr <= '0;
                    end
                end

                // OS输出：PE[0]直通，其余取第gi-1级
                if (gi == 0) begin : W_ALIGN_0
                    assign weight_aligned[gi] = weight_source[gi];
                end else begin : W_ALIGN_N
                    assign weight_aligned[gi] = delay_sr[gi-1];
                end

                // u_input ×1延迟链（CMP输出，EXP2 intercept用）
                localparam integer GROUP_IDX_L = gi / GROUP_SIZE;
                wire [DATA_WIDTH-1:0] cmp_raw = cmp_per_group[GROUP_IDX_L];

                // EXP2 intercept延迟对齐（×1延迟SR）
                // 深度 = POS_IN_GROUP + 逻辑组内pre-delay偏移（1×32最大）
                localparam integer U_EXP2_DEPTH = POS_IN_GROUP + GROUP_IDX_L * GROUP_SIZE * MAC_LATENCY;

                // 运行时tap：4×8仅POS_IN_GROUP，2×16/1×32加上PV方向pre-delay
                wire [6:0] u_exp2_tap = POS_IN_GROUP[6:0] +
                    ((group_mode == 2'b01) ? (GROUP_IDX_L % 2) * GROUP_SIZE * MAC_LATENCY :
                     (group_mode == 2'b10) ? GROUP_IDX_L * GROUP_SIZE * MAC_LATENCY : 0);

                // u_exp2_tap对固定的某个PE只在以下3个编译期常量间切换（由group_mode选择）
                localparam integer TAP_MODE00 = POS_IN_GROUP;
                localparam integer TAP_MODE01 = POS_IN_GROUP + (GROUP_IDX_L % 2) * GROUP_SIZE * MAC_LATENCY;
                localparam integer TAP_MODE10 = POS_IN_GROUP + GROUP_IDX_L * GROUP_SIZE * MAC_LATENCY;

                wire [DATA_WIDTH-1:0] data_u_exp2;
                if (U_EXP2_DEPTH == 0) begin : U_EXP2_ZERO
                    assign data_u_exp2 = cmp_raw;
                end else if (U_EXP2_DEPTH < 32 || POS_IN_GROUP < 2) begin : U_EXP2_SR
                    // 浅深度或小tap：保留移位寄存器（BRAM读写地址可能重叠）
                    reg [DATA_WIDTH-1:0] u_delay_sr [0:U_EXP2_DEPTH-1];
                    integer ud;
                    always_ff @(posedge clock) begin
                        if (!rst_n) begin
                            for (ud = 0; ud < U_EXP2_DEPTH; ud = ud + 1)
                                u_delay_sr[ud] <= '0;
                        end else begin
                            u_delay_sr[0] <= fsa_exp2_cmp_active ? cmp_raw : '0;
                            for (ud = 1; ud < U_EXP2_DEPTH; ud = ud + 1)
                                u_delay_sr[ud] <= u_delay_sr[ud-1];
                        end
                    end
`ifdef ASIC_TARGET
                    // ASIC: u_exp2_tap只在TAP_MODE00/01/10这几个常量间切换，
                    // 用常量抽头mux代替动态下标u_delay_sr[u_exp2_tap-1]（消除N选1 mux）
                    assign data_u_exp2 =
                        (group_mode == 2'b00) ? ((TAP_MODE00 == 0) ? cmp_raw : u_delay_sr[TAP_MODE00-1]) :
                        (group_mode == 2'b01) ? ((TAP_MODE01 == 0) ? cmp_raw : u_delay_sr[TAP_MODE01-1]) :
                                                 ((TAP_MODE10 == 0) ? cmp_raw : u_delay_sr[TAP_MODE10-1]);
`else
                    assign data_u_exp2 = (u_exp2_tap == 7'd0) ? cmp_raw : u_delay_sr[u_exp2_tap - 1];
`endif
                end else begin : U_EXP2_BRAM
`ifdef ASIC_TARGET
                    // ASIC: 定长移位寄存器（深度=U_EXP2_DEPTH，不取整到2的幂）+ 常量抽头mux
                    // 取代循环buffer+地址译码，原因同GROUP_PRE_DELAY
                    reg [DATA_WIDTH-1:0] u_shift [0:U_EXP2_DEPTH-1];
                    integer ud;
                    always_ff @(posedge clock) begin
                        if (!rst_n) begin
                            for (ud = 0; ud < U_EXP2_DEPTH; ud = ud + 1)
                                u_shift[ud] <= '0;
                        end else begin
                            u_shift[0] <= fsa_exp2_cmp_active ? cmp_raw : '0;
                            for (ud = 1; ud < U_EXP2_DEPTH; ud = ud + 1)
                                u_shift[ud] <= u_shift[ud-1];
                        end
                    end
                    assign data_u_exp2 =
                        (group_mode == 2'b00) ? ((TAP_MODE00 == 0) ? cmp_raw : u_shift[TAP_MODE00-1]) :
                        (group_mode == 2'b01) ? ((TAP_MODE01 == 0) ? cmp_raw : u_shift[TAP_MODE01-1]) :
                                                 ((TAP_MODE10 == 0) ? cmp_raw : u_shift[TAP_MODE10-1]);
`else
                    // 深深度（>=32）：BRAM循环buffer（tap>=32保证读写不重叠）
                    localparam integer U_DEPTH_POW2 = (U_EXP2_DEPTH <= 32) ? 32 :
                                                      (U_EXP2_DEPTH <= 64) ? 64 : 128;
                    localparam integer U_AW = $clog2(U_DEPTH_POW2);

                    (* ram_style = "block" *) reg [DATA_WIDTH-1:0] u_bram [0:U_DEPTH_POW2-1];
                    reg [U_AW-1:0] u_wr_ptr;
                    reg [DATA_WIDTH-1:0] u_rd_data;

                    wire [U_AW-1:0] u_rd_addr = (u_wr_ptr - u_exp2_tap[U_AW-1:0] + 1) & (U_DEPTH_POW2 - 1);

                    always_ff @(posedge clock) begin
                        if (!rst_n)
                            u_wr_ptr <= '0;
                        else begin
                            u_bram[u_wr_ptr] <= fsa_exp2_cmp_active ? cmp_raw : '0;
                            u_wr_ptr <= (u_wr_ptr + 1) & (U_DEPTH_POW2 - 1);
                            u_rd_data <= u_bram[u_rd_addr];
                        end
                    end
                    assign data_u_exp2 = (u_exp2_tap == 7'd0) ? cmp_raw : u_rd_data;
`endif
                end
                assign fsa_u_delayed[gi] = data_u_exp2;

                // 正向tap（QK用，×4延迟）
                wire [DATA_WIDTH-1:0] data_fwd;
                wire valid_fwd;
                if (DELAY_FWD == 0) begin : FWD_ZERO
                    assign data_fwd = fsa_l_raw;
                    assign valid_fwd = delay_chain_valid_in;
                end else begin : FWD_TAP
                    assign data_fwd = delay_sr[DELAY_FWD - 1];
                    assign valid_fwd = valid_sr[DELAY_FWD - 1];
                end

                // 反向tap（PV/SUBTRACT/SCALE用，×4延迟）
                wire [DATA_WIDTH-1:0] data_rev;
                wire valid_rev;
                if (DELAY_REV == 0) begin : REV_ZERO
                    assign data_rev = fsa_l_raw;
                    assign valid_rev = delay_chain_valid_in;
                end else begin : REV_TAP
                    assign data_rev = delay_sr[DELAY_REV - 1];
                    assign valid_rev = valid_sr[DELAY_REV - 1];
                end

                // EXP2 tap（×1延迟：PE[p]从tap[p-1]取，与u_input pipe链对齐）
                // cmp_d_pipe和valid_sr都有1拍延迟，自然对齐
                localparam integer DELAY_EXP2 = POS_IN_GROUP;  // 0,1,2,...,7
                wire [DATA_WIDTH-1:0] data_exp2;
                wire valid_exp2;
                if (DELAY_EXP2 == 0) begin : EXP2_ZERO
                    assign data_exp2 = fsa_l_raw;
                    assign valid_exp2 = delay_chain_valid_in;
                end else begin : EXP2_TAP
                    assign data_exp2 = delay_sr[DELAY_EXP2 - 1];
                    assign valid_exp2 = valid_sr[DELAY_EXP2 - 1];
                end

                // MUX选择：EXP2用×1 tap，其他用×4 tap
                assign fsa_l_delayed[gi] = fsa_ctrl_exp2 ? data_exp2 :
                    (fsa_ctrl_delay_rev ? data_rev : data_fwd);
                assign fsa_valid_delayed[gi] = fsa_ctrl_exp2 ? valid_exp2 :
                    (fsa_ctrl_delay_rev ? valid_rev : valid_fwd);
            // end (matching HAS_DELAY, commented for DC compat)
        end
    endgenerate

    // ================================================================
    // WS/FSA模式：vertical部分和链 + 模式MUX + PE例化
    // QK阶段：部分和通过d_input→u_output上行（PE[0]在底，PE[7]在顶）
    // 组内首PE(底部) d_input=0，末PE(顶部) u_output→CMP
    // ================================================================

    generate
        for (gi = 0; gi < ARRAY_SIZE; gi = gi + 1) begin : PE_INST
            localparam integer GROUP_IDX    = gi / GROUP_SIZE;
            localparam integer POS_IN_GROUP = gi % GROUP_SIZE;

            // 逻辑CMP输出：直接用预计算结果（静态索引，无MUX）
            wire [DATA_WIDTH-1:0] my_cmp_output = cmp_per_group[GROUP_IDX];

            // --- vertical链连接（多分组模式支持组间串联）---
            // 4×8: 每组独立，PE[7].d_input=0, PE[0].u_input=CMP
            // 2×16: 两组串联，PE[7]↔PE[8]（组0+组1=逻辑组A，组2+组3=逻辑组B）
            // 1×32: 四组串联，PE[7]↔PE[8], PE[15]↔PE[16], PE[23]↔PE[24]

            // 上行链：PE底部的d_input
            wire [DATA_WIDTH-1:0] fsa_d_input_wire;
            if (POS_IN_GROUP == GROUP_SIZE - 1) begin : BOTTOM_IN_GROUP
                if (gi == ARRAY_SIZE - 1) begin : LAST_PE
                    // 最后一个PE，gi+1越界，平时置0(chunk1/上行链起点)；
                    // chunk2时改读chunk1暂存的部分和，把两段32宽reduction拼成完整score
                    assign fsa_d_input_wire = fsa_chunk1_sel ? fsa_chunk1_acc_in : {DATA_WIDTH{1'b0}};
                end else begin : NOT_LAST
                    assign fsa_d_input_wire = pe_is_logical_bottom[gi] ? {DATA_WIDTH{1'b0}} : pe_u_output[gi + 1];
                end
            end else begin : CHAIN_UP
                assign fsa_d_input_wire = pe_u_output[gi + 1];
            end

            // 下行链：PE顶部的u_input
            wire [DATA_WIDTH-1:0] fsa_u_input_wire;
            if (POS_IN_GROUP == 0) begin : TOP_IN_GROUP
                // CMP→PE[0]之间1拍pipe寄存器（逻辑组顶部用）
                reg [DATA_WIDTH-1:0] cmp_d_pipe;
                always_ff @(posedge clock) begin
                    if (!rst_n)
                        cmp_d_pipe <= '0;
                    else if (fsa_ctrl_flow_ud)
                        cmp_d_pipe <= my_cmp_output;
                end

                // 逻辑组顶部：接CMP；非顶部：接上一组PE[7]的d_output
                wire [DATA_WIDTH-1:0] cmp_source = fsa_ctrl_flow_ud ? cmp_d_pipe :
                    (fsa_ctrl_exp2 ? fsa_u_delayed[gi] :
                     (fsa_ctrl_acc_ui ? my_cmp_output :
                      {DATA_WIDTH{1'b0}}));

                if (gi == 0) begin : FIRST_PE
                    // 第一个PE，gi-1越界，始终用cmp_source
                    assign fsa_u_input_wire = cmp_source;
                end else begin : NOT_FIRST
                    wire [DATA_WIDTH-1:0] chain_source = fsa_ctrl_flow_ud ?
                        pe_d_output[gi - 1] :
                        (fsa_ctrl_exp2 ? fsa_u_delayed[gi] :
                         (fsa_ctrl_acc_ui ? my_cmp_output :
                          {DATA_WIDTH{1'b0}}));
                    assign fsa_u_input_wire = pe_is_logical_top[gi] ? cmp_source : chain_source;
                end
            end else begin : CHAIN_DOWN
                // 非顶部PE：flow_ud=1时走pipe链（前一级PE的d_output）
                // acc_ui时用逻辑组CMP输出（不是物理GROUP_IDX）
                assign fsa_u_input_wire = fsa_ctrl_flow_ud ?
                    pe_d_output[gi - 1] :
                    (fsa_ctrl_exp2 ? fsa_u_delayed[gi] :
                     (fsa_ctrl_acc_ui ?
                        my_cmp_output :
                        {DATA_WIDTH{1'b0}}));
            end

            // --- 模式MUX：选择OS或WS信号送入PE ---
            // l_input: OS=weight_aligned, WS=bypass时直接用原始值，MAC时用延迟匹配后的值
            wire [DATA_WIDTH-1:0] fsa_l_raw_pe = fsa_l_input[gi*DATA_WIDTH +: DATA_WIDTH];
            assign pe_l_input_muxed[gi] = fsa_mode ?
                (fsa_load_bypass ? fsa_l_raw_pe : fsa_l_delayed[gi]) : weight_aligned[gi];

            // u_input: OS=vec_chain, WS=下行链（CMP pipe输出或前一PE的d_output pipe）
            // LOAD_REG_UI时u_input自然来自pipe寄存器中残留的score（与原版一致）
            assign pe_u_input_muxed[gi] = fsa_mode ? fsa_u_input_wire : vec_chain[gi];

            // d_input: OS=0, WS=vertical链
            assign pe_d_input_muxed[gi] = fsa_mode ? fsa_d_input_wire : {DATA_WIDTH{1'b0}};

            // mode_sel: OS=1, WS=0
            assign pe_mode_sel[gi] = fsa_mode ? 1'b0 : 1'b1;

            // 控制信号MUX
            // ctrl_valid选择：
            //   bypass(LOAD_Q/LOAD_REG_UI): 广播valid
            //   纯flow(flow_ud/flow_du无MAC): 逐级链valid
            //   MAC操作: 延迟匹配后的valid
            assign pe_ctrl_valid[gi]       = fsa_mode ?
                (fsa_load_bypass ? fsa_l_input_valid :
                 fsa_ctrl_is_flow ? fsa_ctrl_valid_chain[gi] :
                 fsa_valid_delayed[gi]) : alu_start;
            // pe_ctrl_valid 仍然 per-PE（因为有延迟匹配）

            // --- OS模式结果线 ---
            wire r_out_sign;
            wire [7:0] r_out_exp;
            wire [22:0] r_out_mantissa;
            assign mac_results_wire[gi] = {r_out_sign, r_out_exp, r_out_mantissa};

            // --- u_output/d_output捕获 ---
            wire u_out_sign, u_out_valid;
            wire [7:0] u_out_exp;
            wire [22:0] u_out_mantissa;
            wire d_out_sign, d_out_valid;
            wire [7:0] d_out_exp;
            wire [22:0] d_out_mantissa;

            // --- vec链延迟寄存器（OS模式用，显式清零防止tile间残留）---
            reg [DATA_WIDTH-1:0] vec_delay_q;
            always_ff @(posedge clock) begin
                if (!rst_n)
                    vec_delay_q <= '0;
                else if (alu_start & ~fsa_mode)
                    vec_delay_q <= vec_chain[gi];
                else if (~fsa_mode)
                    vec_delay_q <= '0;
            end
            assign vec_chain[gi+1] = vec_delay_q;

            assign pe_u_output[gi] = {u_out_sign, u_out_exp, u_out_mantissa};
            assign pe_u_output_valid[gi] = u_out_valid;
            assign pe_d_output[gi] = {d_out_sign, d_out_exp, d_out_mantissa};
            assign pe_d_output_valid[gi] = d_out_valid;

            // --- PE_retimed例化 ---
            PE_retimed u_pe (
                .clock                       (clock),
                .rst_n                        (rst_n),
                .mode_sel                    (pe_mode_sel[gi]),
                .io_in_ctrl_valid            (pe_ctrl_valid[gi]),
                .io_in_ctrl_bits_mac         (pe_ctrl_mac),
                .io_in_ctrl_bits_acc_ui      (pe_ctrl_acc_ui),
                .io_in_ctrl_bits_load_reg_li (pe_ctrl_load_reg_li),
                .io_in_ctrl_bits_load_reg_ui (pe_ctrl_load_reg_ui),
                .io_in_ctrl_bits_flow_lr     (pe_ctrl_flow_lr),
                .io_in_ctrl_bits_flow_ud     (pe_ctrl_flow_ud),
                .io_in_ctrl_bits_flow_du     (pe_ctrl_flow_du),
                .io_in_ctrl_bits_update_reg  (pe_ctrl_update_reg),
                .io_in_ctrl_bits_exp2        (pe_ctrl_exp2),
                .io_l_input_bits_sign        (pe_l_input_muxed[gi][31]),
                .io_l_input_bits_exp         (pe_l_input_muxed[gi][30:23]),
                .io_l_input_bits_mantissa    (pe_l_input_muxed[gi][22:0]),
                .io_u_input_bits_sign        (pe_u_input_muxed[gi][31]),
                .io_u_input_bits_exp         (pe_u_input_muxed[gi][30:23]),
                .io_u_input_bits_mantissa    (pe_u_input_muxed[gi][22:0]),
                .io_u_output_valid           (u_out_valid),
                .io_u_output_bits_sign       (u_out_sign),
                .io_u_output_bits_exp        (u_out_exp),
                .io_u_output_bits_mantissa   (u_out_mantissa),
                .io_d_input_bits_sign        (pe_d_input_muxed[gi][31]),
                .io_d_input_bits_exp         (pe_d_input_muxed[gi][30:23]),
                .io_d_input_bits_mantissa    (pe_d_input_muxed[gi][22:0]),
                .io_partial_sum_in           (partial_sum_in[((ARRAY_SIZE-gi)*DATA_WIDTH)-1 -: DATA_WIDTH]),
                .io_rst_acc                  (rst_acc_pulse),
                .io_d_output_valid           (d_out_valid),
                .io_d_output_bits_sign       (d_out_sign),
                .io_d_output_bits_exp        (d_out_exp),
                .io_d_output_bits_mantissa   (d_out_mantissa),
                .io_r_output_valid           (),
                .io_r_output_bits_sign       (r_out_sign),
                .io_r_output_bits_exp        (r_out_exp),
                .io_r_output_bits_mantissa   (r_out_mantissa)
            );
        end
    endgenerate

    // ================================================================
    // CMP/Accumulator输出端口：各组顶部/底部PE
    // ================================================================

    generate
        for (gi = 0; gi < NUM_GROUPS; gi = gi + 1) begin : GROUP_OUT
            localparam integer TOP_PE = gi * GROUP_SIZE;                      // 组顶PE（PE[0]连CMP）
            localparam integer BOT_PE = gi * GROUP_SIZE + (GROUP_SIZE - 1);  // 组底PE（PE[7]连Accumulator）

            assign cmp_score_out[gi*DATA_WIDTH +: DATA_WIDTH] = pe_u_output[TOP_PE];
            assign cmp_score_valid[gi] = pe_u_output_valid[TOP_PE];

            assign acc_data_out[gi*DATA_WIDTH +: DATA_WIDTH] = pe_d_output[BOT_PE];
            assign acc_data_valid[gi] = pe_d_output_valid[BOT_PE];
        end
    endgenerate

    // ================================================================
    // OS模式结果捕获（与PE_core_new一致）
    // ================================================================

    always_ff @(posedge clock) begin
        if (!rst_n) begin
            mul_outcome_reg <= '0;
            result_valid <= 1'b0;
            result_latched <= 1'b0;
        end else begin
            result_valid <= 1'b0;
            if (!alu_start) begin
                result_latched <= 1'b0;
            end else if (!result_latched && (cycle_num == RESULT_CAPTURE_CYCLE)) begin
                for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                    mul_outcome_reg[((ARRAY_SIZE-i)*OUTCOME_WIDTH)-1 -: OUTCOME_WIDTH] <= mac_results_wire[i];
                end
                result_valid <= 1'b1;
                result_latched <= 1'b1;
            end
        end
    end

    assign mul_outcome = mul_outcome_reg;

endmodule

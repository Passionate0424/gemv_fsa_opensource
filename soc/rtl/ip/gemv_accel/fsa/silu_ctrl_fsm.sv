`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// silu_ctrl_fsm
//
// SiLU 微序列状态机：把 GEMV 结果就地过一遍 silu(x)=x*sigmoid(x)，
// 复用已有的 4 个 fsa_accumulator 通道（每通道内含 exp2 + FMA + 除法），
// 零新增算术单元。与 fsa_ctrl_fsm 并列同层——发累加器命令属于这一层的职责，
// 顶层 cb_controll_v2 只做 start/done 握手。
//
// 数据来源与去向都是 Output SRAM：GEMV 算完后 write_out_v2 已把 32 个 PE 结果
// 序列化成 4 bank × 8 拍写进去，本状态机再逐地址读出→算→原地写回，然后才由
// DMA 搬回 DDR。4 个 bank 正好对应 4 个累加器通道，不需要额外仲裁或重排。
//
// 微程序（对应 fsa_accumulator 的 6 条命令，每元素 7 步）：
//   1 EXP_S1     scale = sa_in x attn_scale        sa_in = -|x|, attn_scale 需写成 log2e
//   2 EXP_S2     scale = exp2(scale) = t           t = exp(-|x|) 恒在 (0,1]
//   3 ACC_NORM   num   = scale x sram_in = t*x     只有 x<0 才捕获，x>=0 保持 num=x
//   4 ACC_SA     den   = scale x sram_in + sa_in = t*1.0 + 1.0
//   5 SET_SCALE  scale = den
//   6 RECIPROCAL scale = 1/(1+t)                   多周期，等 acc_recip_done
//   7 ACC_NORM   out   = scale x num = silu(x)
//
// 为什么取 -|x| 而不是 -x：这是恒等变换(x<0 时分子分母同乘 e^x)，不是近似。
//   x>=0: sigma = 1/(1+t)      x<0: sigma = t/(1+t)
// 硬件上必须这么做，因为 exp2 的 LUT 只覆盖负半轴（实测 exp2(0.5) 给 1.176 而非
// 1.414），且 |输入|>=256 时 SplitIF 会置 isInf 把输出强制成 0。锁在负半轴后连
// 饱和行为都自动正确：x 很大正 -> t->0 -> silu->x；很大负 -> t->0 -> silu->0。
//
// 命令是广播给 4 个通道的，所以第 3 步 4 路都会执行，靠 cap_num_neg_only 让
// x>=0 的通道不捕获结果——分支落在写使能上，不落在命令序列上。
//
// 中间量用寄存器而不是 fsa_acc_sram 暂存：每通道只需 x/num/den 三个 32bit 寄存器，
// 比走 SRAM 省掉一整套地址管理与读延迟对齐。
//
// 输出全部是语义化、寄存器化的控制信号，不对外暴露状态编码——上层无需
// localparam 副本去译码，改本模块内部编码不会静默影响调用方。
////////////////////////////////////////////////////////////////
module silu_ctrl_fsm #(
    parameter DATA_WIDTH  = 32,
    parameter ACC_LATENCY = 6    // fsa_accumulator 从 ctrl_valid 到 sram_out_valid 的拍数
)(
    input  clock,
    input  rst_n,

    // 与顶层 FSM 的握手
    input  silu_start,           // 单拍脉冲或电平，S_IDLE 下有效即启动
    input  [5:0] num_elem,       // 本次要处理的元素个数（GEMV 的 current_rows，1~32）
    output reg silu_done,        // 单拍脉冲

    // 累加器多周期握手
    input  acc_recip_done,

    // ---- 累加器命令（经 mode MUX 送 fsa_accumulator）----
    output reg acc_ctrl_valid,
    output reg [2:0] acc_ctrl_cmd,

    // ---- 数据通路选择（语义化命名）----
    output reg sa_sel_negx,      // sa_in 取 -|x|（步骤1）
    output reg sa_sel_one,       // sa_in 取常数 1.0（步骤4）
    output reg [1:0] sram_src,   // sram_in 来源：0=x_reg 1=num_reg 2=den_reg 3=常数1.0

    // ---- 中间量捕获（把累加器输出打进对应寄存器）----
    output reg cap_x,            // Output SRAM 读出的 x -> x_reg，同时 num_reg 初值=x
    output reg cap_num_neg_only, // 累加器输出 -> num_reg，仅 x<0 的通道（步骤3）
    output reg cap_den,          // 累加器输出 -> den_reg（步骤4）

    // ---- Output SRAM 读写 ----
    output reg osram_rd_en,
    output reg osram_wr_en,      // 把最终结果写回同一地址
    output [3:0] osram_addr      // 直接是 addr_cnt 寄存器的输出，见下方说明
);

    // 命令编码（与 fsa_accumulator.sv:9-16 一致）
    localparam CMD_EXP_S1    = 3'd0;
    localparam CMD_EXP_S2    = 3'd1;
    localparam CMD_ACC_SA    = 3'd2;
    localparam CMD_ACC_NORM  = 3'd3;
    localparam CMD_SET_SCALE = 3'd4;
    localparam CMD_RECIP     = 3'd5;

    // sram_in 来源编码
    localparam SRC_X   = 2'd0;
    localparam SRC_NUM = 2'd1;
    localparam SRC_DEN = 2'd2;
    localparam SRC_ONE = 2'd3;

    localparam S_IDLE    = 4'd0;
    localparam S_RD      = 4'd1;   // 发 Output SRAM 读
    localparam S_LATCH   = 4'd2;   // SRAM 读延迟1拍后锁存 x
    localparam S_EXP1    = 4'd3;   // 发 EXP_S1
    localparam S_EXP1_W  = 4'd4;
    localparam S_EXP2    = 4'd5;   // 发 EXP_S2
    localparam S_EXP2_W  = 4'd6;
    localparam S_NUM     = 4'd7;   // 发 ACC_NORM 算 t*x
    localparam S_NUM_W   = 4'd8;
    localparam S_DEN     = 4'd9;   // 发 ACC_SA 算 1+t
    localparam S_DEN_W   = 4'd10;
    localparam S_SET     = 4'd11;  // 发 SET_SCALE
    localparam S_SET_W   = 4'd12;
    localparam S_RECIP   = 4'd13;  // 发 RECIPROCAL，等 done
    localparam S_OUT     = 4'd14;  // 发 ACC_NORM 算 scale*num
    localparam S_OUT_W   = 4'd15;

    reg [3:0] state, next_state;
    reg [3:0] wait_cnt;            // 等待累加器流水的拍数
    reg [3:0] addr_cnt;            // 当前处理的 Output SRAM 地址
    reg [3:0] addr_last;           // 最后一个地址（num_elem 换算，4 bank 并行）

    // start 取上升沿，不能用电平。顶层 S_SILU 里 silu_start 是电平常高，而本 FSM
    // 跑完回 S_IDLE 的那一拍顶层还停在 S_SILU（要看到 silu_done 后再下一拍才转走），
    // 若按电平判定就会立刻重启第二轮，对已经是 silu(x) 的值再算一次，并与 DMA
    // 读回构成竞态。
    reg silu_start_d;
    always_ff @(posedge clock) begin
        if (!rst_n) silu_start_d <= 1'b0;
        else        silu_start_d <= silu_start;
    end
    wire silu_start_rise = silu_start & ~silu_start_d;

    // 地址数 = min(8, num_elem)，不是 ceil(num_elem/4)。
    //
    // Output SRAM 的布局由 write_out_v2 决定：bank 是 PE 组、addr 是组内偏移
    //   bank0=PE[0~7], bank1=PE[8~15], bank2=PE[16~23], bank3=PE[24~31]
    // 即元素 i 落在 bank[i/8] 的 addr[i%8]。一个 addr 上的 4 个 bank 对应的是
    // PE[a]、PE[8+a]、PE[16+a]、PE[24+a]——彼此相隔 8，不是连续的 4 个元素。
    // 所以要覆盖 PE[0..num_elem-1]，需要走完 addr 0..min(7, num_elem-1)。
    //
    // 早先按 ceil(num_elem/4) 算，num_elem=7 时只跑了 addr 0~1，PE[2~6] 完全
    // 没过 SiLU，DDR 里留着 GEMV 原值（UVM 的 rows=7 用例上 row[3]/row[5] 失败）。
    wire [4:0] addr_total = (num_elem >= 6'd8) ? 5'd8 : {1'b0, num_elem[3:0]};
    wire wait_done  = (wait_cnt == ACC_LATENCY[3:0] - 4'd1);
    wire addr_done  = (addr_cnt >= addr_last);

    // 捕获时刻要比状态跳转早一拍：累加器的 acc_sram_out 在命令后第 ACC_LATENCY
    // 拍有效，而 cap_* 是 Moore 型寄存器输出、置起后要下一拍才生效。若挂在
    // wait_done 上，等 cap_* 真正有效时 acc_sram_out 已经翻篇，会捕获到错误数据
    // （实测表现：den_reg 收到的不是 1+t，SET_SCALE 读到 0，RECIP(0)=Inf，最终输出 -Inf）。
    wire cap_tick = (wait_cnt == ACC_LATENCY[3:0] - 4'd2);

    // 地址直接就是 addr_cnt 这个寄存器的输出——不再单独打一拍，也不预测它的下一拍值。
    // 非阻塞赋值天然把读写两拍分开：
    //   拍 N   : S_OUT_W && wait_done，addr_cnt 的自增在拍末生效；此刻 osram_wr_en
    //            有效，读到的 addr_cnt 还是旧值，正是要写回的当前地址
    //   拍 N+1 : 进入 S_RD，addr_cnt 已是新值，读地址同步更新
    // 早先版本给 osram_addr 单独打一拍，结果它永远慢 addr_cnt 一拍，S_RD 读回的
    // 是刚写完结果的上一个地址（表现为每轮都在对上一轮输出再算一次 SiLU，逐个减半）。
    // 用组合逻辑去"预测"下一拍的 addr_cnt 同样不可取：那等于把自增条件复制一份，
    // 两处逻辑必须永远保持一致，改一处漏一处就会静默错位。
    assign osram_addr = addr_cnt;

    // ---------------- 第一段：状态寄存 ----------------
    always_ff @(posedge clock) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    // ---------------- 第二段：次态组合 ----------------
    always_comb begin
        next_state = state;
        case (state)
            S_IDLE   : if (silu_start_rise && num_elem != 6'd0) next_state = S_RD;
            S_RD     : next_state = S_LATCH;
            S_LATCH  : next_state = S_EXP1;
            S_EXP1   : next_state = S_EXP1_W;
            S_EXP1_W : if (wait_done) next_state = S_EXP2;
            S_EXP2   : next_state = S_EXP2_W;
            S_EXP2_W : if (wait_done) next_state = S_NUM;
            S_NUM    : next_state = S_NUM_W;
            S_NUM_W  : if (wait_done) next_state = S_DEN;
            S_DEN    : next_state = S_DEN_W;
            S_DEN_W  : if (wait_done) next_state = S_SET;
            S_SET    : next_state = S_SET_W;
            // SET_SCALE 只是把 sram_in 打进 scale 寄存器，无需等满流水
            S_SET_W  : next_state = S_RECIP;
            S_RECIP  : if (acc_recip_done) next_state = S_OUT;
            S_OUT    : next_state = S_OUT_W;
            S_OUT_W  : if (wait_done) next_state = addr_done ? S_IDLE : S_RD;
            default  : next_state = S_IDLE;
        endcase
    end

    // ---------------- 计数器 ----------------
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            wait_cnt  <= 4'd0;
            addr_cnt  <= 4'd0;
            addr_last <= 4'd0;
        end else begin
            // 等待计数：进入 *_W 状态清零，停留期间累加
            if (state != next_state) wait_cnt <= 4'd0;
            else                     wait_cnt <= wait_cnt + 4'd1;

            if (state == S_IDLE) begin
                addr_cnt  <= 4'd0;
                // 锁存本次任务的地址上限，避免过程中 num_elem 变化
                addr_last <= (addr_total == 5'd0) ? 4'd0 : (addr_total[3:0] - 4'd1);
            end else if (state == S_OUT_W && wait_done && !addr_done) begin
                addr_cnt <= addr_cnt + 4'd1;
            end
        end
    end

    // ---------------- 第三段：输出寄存 ----------------
    // 全部 Moore 型寄存器输出：调用方直接连线，不需要按状态译码，
    // 也把状态寄存器到数据通路 MUX 的组合路径切断（DC 200MHz 下这条路径不该再加长）。
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            acc_ctrl_valid   <= 1'b0;
            acc_ctrl_cmd     <= 3'd0;
            sa_sel_negx      <= 1'b0;
            sa_sel_one       <= 1'b0;
            sram_src         <= SRC_X;
            cap_x            <= 1'b0;
            cap_num_neg_only <= 1'b0;
            cap_den          <= 1'b0;
            osram_rd_en      <= 1'b0;
            osram_wr_en      <= 1'b0;
            silu_done        <= 1'b0;
        end else begin
            // 默认全部拉低，只在对应次态置起（单拍脉冲语义）
            acc_ctrl_valid   <= 1'b0;
            sa_sel_negx      <= 1'b0;
            sa_sel_one       <= 1'b0;
            cap_x            <= 1'b0;
            cap_num_neg_only <= 1'b0;
            cap_den          <= 1'b0;
            osram_rd_en      <= 1'b0;
            osram_wr_en      <= 1'b0;
            silu_done        <= 1'b0;


            case (next_state)
                S_RD: begin
                    osram_rd_en <= 1'b1;
                end
                // SRAM 读延迟1拍，此时 rdata 有效，锁进 x_reg（num_reg 同时初始化为 x）
                S_LATCH: begin
                    cap_x <= 1'b1;
                end
                // 步骤1：scale = (-|x|) x attn_scale(=log2e)
                // sram_src 这步用不到（EXP_S1 的 b 操作数取 attn_scale），但仍显式
                // 归位，免得残留上一轮的值让波形难读
                S_EXP1: begin
                    acc_ctrl_valid <= 1'b1;
                    acc_ctrl_cmd   <= CMD_EXP_S1;
                    sa_sel_negx    <= 1'b1;
                    sram_src       <= SRC_X;
                end
                // 步骤2：scale = exp2(scale) = t
                // cmd=1 时 SplitIF 只吃 a 操作数，b 被 LUT slope 顶替，故无需给 sram_in
                S_EXP2: begin
                    acc_ctrl_valid <= 1'b1;
                    acc_ctrl_cmd   <= CMD_EXP_S2;
                end
                // 步骤3：num = t*x。4 路都算，但只有 x<0 的通道捕获
                S_NUM: begin
                    acc_ctrl_valid <= 1'b1;
                    acc_ctrl_cmd   <= CMD_ACC_NORM;
                    sram_src       <= SRC_X;
                end
                // 步骤4：den = t*1.0 + 1.0
                S_DEN: begin
                    acc_ctrl_valid <= 1'b1;
                    acc_ctrl_cmd   <= CMD_ACC_SA;
                    sram_src       <= SRC_ONE;
                    sa_sel_one     <= 1'b1;
                end
                // 步骤5：scale <- den
                S_SET: begin
                    acc_ctrl_valid <= 1'b1;
                    acc_ctrl_cmd   <= CMD_SET_SCALE;
                    sram_src       <= SRC_DEN;
                end
                // 步骤6：scale <- 1/(1+t)
                // 只在从 S_SET_W 转进来的那一拍发命令。RECIPROCAL 是多周期的，
                // 本状态要停留等 acc_recip_done，若不加限定会每拍重发一次命令，
                // 把正在迭代的除法器打断。其余步骤的状态只停留一拍，不存在这个问题。
                S_RECIP: begin
                    if (state == S_SET_W) begin
                        acc_ctrl_valid <= 1'b1;
                        acc_ctrl_cmd   <= CMD_RECIP;
                    end
                end
                // 步骤7：out = scale x num
                S_OUT: begin
                    acc_ctrl_valid <= 1'b1;
                    acc_ctrl_cmd   <= CMD_ACC_NORM;
                    sram_src       <= SRC_NUM;
                end
                default: ;
            endcase

            // 步骤3 的结果捕获：流水出结果时打进 num_reg（仅负数通道）
            if (state == S_NUM_W && cap_tick) cap_num_neg_only <= 1'b1;
            // 步骤4 的结果捕获：1+t -> den_reg
            if (state == S_DEN_W && cap_tick) cap_den <= 1'b1;
            // 步骤7 的结果写回 Output SRAM 原地址
            if (state == S_OUT_W && cap_tick) osram_wr_en <= 1'b1;
            // 全部地址处理完（done 用 wait_done，此时写回已经落盘）
            if (state == S_OUT_W && wait_done && addr_done) silu_done <= 1'b1;
        end
    end

endmodule

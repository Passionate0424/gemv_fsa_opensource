// FPU Top-level wrapper
// [AI FPU Refactor] Decoupled Valid/Ready interface with CVFPU integration

// Tag structure for CVFPU to pass along side the pipeline
typedef struct packed {
    logic [4:0]  dest;          // 目标寄存器
    logic        tag;           // Epoch 冲刷标签
    logic        is_fcmp;       // 是否为比较指令
    logic [4:0]  fcmp_cond;     // 阶段2: 手册 cond 原值(5-bit, 22 种)
    // 龙芯 NaN 传播(见 ISA 3.1.1.3): CVFPU 把 NaN 一律规范化为 0x7fc00000, 不符合龙芯
    // "源含 NaN 时传播 payload" 的要求。请求时按龙芯规则预先算好传播候选值随 tag 流过
    // 流水线, 输出时若本运算应传播则用候选值覆盖 CVFPU 结果。
    logic        nan_prop_en;   // 本算术运算源含 NaN, 结果应传播(覆盖 CVFPU 规范化)
    logic [31:0] nan_prop_val;  // 龙芯规则下应传播的 NaN 位模式
    // 阶段2: fcmp 22 种 cond 用"基础谓词 P(CVFPU CMP 出) + 本地无序位 un + combine 模式"组合。
    //   CVFPU CMP 只出单个谓词(rm 选 LT/EQ/LE), 无法直接表达 CAF/CUN/COR/CNE, 故引入 combine:
    //     0=FALSE(恒0)  1=PASS(P)  2=OR_UN(P|un)  3=NEG(!P)  4=NEG_ORD(!P&!un)  5=UN(un)  6=NOT_UN(!un)
    //   真值表(手册§3.2.2.1)推导, 可证明覆盖全部 22 种。un=任一源 NaN。
    logic [2:0]  cmp_combine;   // fcmp 结果组合模式
    logic        cmp_unordered; // 本次比较两源是否无序(任一 NaN)
    // 阶段2b: fmaxa/fmina/fclass 走"本地覆盖旁路"—— CVFPU 出不了这些结果(MINMAX 只按数值比、
    //   CLASSIFY 结果在独立 class_mask_o 端口未接 result_o)。请求时本地组合算好结果随 tag 流过,
    //   输出段用 alt_val 覆盖 CVFPU 结果(复用 nan_prop 同款覆盖机制, 保握手/valid 时序)。
    //   请求侧走 dummy op(SGNJ, NONCOMP 单周期), 仅借其流水时序, 结果被 alt_val 覆盖。
    logic        alt_en;        // 本地覆盖使能(fmaxa/fmina/fclass)
    logic [31:0] alt_val;       // 本地组合算出的结果
    logic        alt_nv;        // fmaxa/fmina 的 sNaN 置 NV(fclass 不置标志)
} fpu_tag_t;

// fcmp combine 模式常量
`define CMPC_FALSE   3'd0
`define CMPC_PASS    3'd1
`define CMPC_OR_UN   3'd2
`define CMPC_NEG     3'd3
`define CMPC_NEG_ORD 3'd4
`define CMPC_UN      3'd5
`define CMPC_NOT_UN  3'd6

module fpu_top(
    input  wire        clk,
    input  wire        reset,
    input  wire        flush,      // 流水线冲刷，取消 CVFPU 中的 stale 操作

    // Request
    input  wire        fpu_req_valid,
    output wire        fpu_req_ready,
    input  wire [ 4:0] fpu_req_op,
    input  wire [31:0] fpu_req_a,
    input  wire [31:0] fpu_req_b,
    input  wire [31:0] fpu_req_c,   // fmadd/fmsub 第三源 fa
    input  wire [ 4:0] fpu_req_dest,
    input  wire        fpu_req_tag,
    input  wire [ 2:0] fpu_req_rm,

    // Response
    input  wire        fpu_rsp_ready,
    output wire        fpu_rsp_valid,
    output wire [31:0] fpu_rsp_result,
    output wire [ 4:0] fpu_rsp_dest,
    output wire        fpu_rsp_tag,
    output wire [ 4:0] fpu_rsp_flags,

    // Comparison condition (valid when op == fcmp)
    input  wire [ 4:0] fcmp_cond,    // 阶段2: 透传 inst[19:15] 手册 cond 原值(5-bit), 涵盖 22 种
    output wire        fcmp_out,
    output wire        fpu_rsp_is_fcmp
);

// FPU operation codes (阶段2: 4→5bit, 保持 00001~01110 原编码不变, 与 id_stage fpu_op 表一致)
localparam FPU_ADD   = 5'b00001;
localparam FPU_SUB   = 5'b00010;
localparam FPU_MUL   = 5'b00011;
localparam FPU_DIV   = 5'b00100;
localparam FPU_FTINT = 5'b00101;
localparam FPU_FFINT = 5'b00110;
localparam FPU_FCMP  = 5'b00111;
localparam FPU_FMOV   = 5'b01000;  // 位拷贝, 走 NONCOMP SGNJ
localparam FPU_FNEG   = 5'b01001;  // 符号翻转, 走 NONCOMP SGNJN
localparam FPU_FRECIP = 5'b01010;  // 1.0/fj, 走 DIVSQRT DIV
localparam FPU_FMADD  = 5'b01011;  // fj*fk+fa, 走 ADDMUL FMADD
localparam FPU_FMSUB  = 5'b01100;  // fj*fk-fa, 走 ADDMUL FMADD + op_mod
localparam FPU_FABS      = 5'b01101;  // |fj|, 走 NONCOMP SGNJ(rm=RDN, 即 fsgnjx fj,fj)
localparam FPU_FCOPYSIGN = 5'b01110;  // copysign(fj,fk), 走 NONCOMP SGNJ(rm=RNE, fj 数值/fk 符号)
// 阶段2 新增 (走 CVFPU):
localparam FPU_FSQRT  = 5'b01111;  // sqrt(fj), 走 DIVSQRT SQRT (TH32 原生开方)
localparam FPU_FMAX   = 5'b10000;  // max(fj,fk), 走 NONCOMP MINMAX rm=RTZ
localparam FPU_FMIN   = 5'b10001;  // min(fj,fk), 走 NONCOMP MINMAX rm=RNE
localparam FPU_FMAXA  = 5'b10010;  // 绝对值 max, MINMAX + 清符号预处理
localparam FPU_FMINA  = 5'b10011;  // 绝对值 min
localparam FPU_FNMADD = 5'b10100;  // -(fj*fk+fa), CVFPU FNMSUB + op_mod=1 (翻转 A 和 C)
localparam FPU_FNMSUB = 5'b10101;  // -(fj*fk-fa), CVFPU FNMSUB + op_mod=0 (仅翻转 A)
localparam FPU_FCLASS = 5'b10110;  // class(fj), 走 NONCOMP CLASSIFY (mask 需位重排对齐手册)
localparam FPU_FTINTRM  = 5'b10111;  // 向-inf 取整, F2I 强制 rm=RDN
localparam FPU_FTINTRP  = 5'b11000;  // 向+inf 取整, F2I 强制 rm=RUP
localparam FPU_FTINTRNE = 5'b11001;  // 就近取整, F2I 强制 rm=RNE

fpnew_pkg::operation_e cvfpu_op;
logic cvfpu_op_mod;
fpnew_pkg::roundmode_e cvfpu_rm;

always_comb begin
    cvfpu_op = fpnew_pkg::ADD;
    cvfpu_op_mod = 1'b0;
    cvfpu_rm = fpnew_pkg::roundmode_e'(fpu_req_rm);

    case (fpu_req_op)
        FPU_ADD: begin
            cvfpu_op = fpnew_pkg::ADD;
            cvfpu_op_mod = 1'b0;
        end
        FPU_SUB: begin
            cvfpu_op = fpnew_pkg::ADD;
            cvfpu_op_mod = 1'b1; // SUB is ADD with op_mod=1
        end
        FPU_MUL: begin
            cvfpu_op = fpnew_pkg::MUL;
            cvfpu_op_mod = 1'b0;
        end
        FPU_DIV: begin
            cvfpu_op = fpnew_pkg::DIV;
            cvfpu_op_mod = 1'b0;
        end
        FPU_FTINT: begin
            cvfpu_op = fpnew_pkg::F2I;
            cvfpu_op_mod = 1'b0;
        end
        FPU_FFINT: begin
            cvfpu_op = fpnew_pkg::I2F;
            cvfpu_op_mod = 1'b0;
        end
        FPU_FCMP: begin
            // 阶段2: 22 种 cond 全集。CVFPU CMP 只出单一基础谓词(LT/EQ/LE), 无法直接表达
            //   恒假/纯无序/有序/有序不等, 故改为: CMP 出基础谓词 P, 输出段按 cmp_combine
            //   把本地自测的无序位 un 组合进去(见输出段 fcmp_bool)。
            //   基础谓词由 rm 选: RTZ=LT, RDN=EQ, RNE=LE (op_mod 恒 0, 不用取反)。
            //   cmp_combine 编码(输出段 fcmp_bool 用):
            //     0 PASS   : 结果 = P            (CLT/CEQ/CLE)
            //     1 OR_UN  : 结果 = P | un       (CULT/CUEQ/CULE)
            //     2 FALSE  : 结果 = 0            (CAF)
            //     3 UN     : 结果 = un           (CUN)
            //     4 NOT_UN : 结果 = ~un          (COR)
            //     5 NEG_ORD: 结果 = ~P & ~un     (CNE=有序不等, NaN→假)
            //     6 NEG_UN : 结果 = ~P | un      (CUNE=~EQ 或无序; ~EQ 在有序时=GTLT)
            //   手册值(§3.2.2.1, bit0=S signaling 布尔同 quiet): CAF0x0 CLT0x2 CEQ0x4 CLE0x6
            //     CUN0x8 CULT0xa CUEQ0xc CULE0xe CNE0x10 COR0x14 CUNE0x18。
            cvfpu_op = fpnew_pkg::CMP;
            cvfpu_op_mod = 1'b0;
            case (fcmp_cond[4:1])   // 忽略 bit0(S/quiet 布尔相同)
                4'h1: cvfpu_rm = fpnew_pkg::RTZ; // CLT/SLT: LT
                4'h2: cvfpu_rm = fpnew_pkg::RDN; // CEQ/SEQ: EQ
                4'h3: cvfpu_rm = fpnew_pkg::RNE; // CLE/SLE: LE
                4'h5: cvfpu_rm = fpnew_pkg::RTZ; // CULT: LT | un
                4'h6: cvfpu_rm = fpnew_pkg::RDN; // CUEQ: EQ | un
                4'h7: cvfpu_rm = fpnew_pkg::RNE; // CULE: LE | un
                4'h8: cvfpu_rm = fpnew_pkg::RDN; // CNE : ~EQ & ~un (有序不等)
                4'hc: cvfpu_rm = fpnew_pkg::RDN; // CUNE: ~EQ | un
                default: cvfpu_rm = fpnew_pkg::RDN; // CAF/CUN/COR: 谓词不用, 由 combine 决定
            endcase
        end
        FPU_FMOV: begin
            // fmov.s: 纯位拷贝。SGNJ(rm=RNE) 取 operand_b 的符号 + operand_a 的尾数指数;
            //         operand_a=operand_b=fj(见下方操作数路由), 结果即 fj 原值。
            cvfpu_op = fpnew_pkg::SGNJ;
            cvfpu_op_mod = 1'b0;
            cvfpu_rm = fpnew_pkg::RNE;
        end
        FPU_FNEG: begin
            // fneg.s: 翻转符号位。SGNJN(rm=RTZ) 取 ~operand_b.sign + operand_a 其余位。
            cvfpu_op = fpnew_pkg::SGNJ;
            cvfpu_op_mod = 1'b0;
            cvfpu_rm = fpnew_pkg::RTZ;
        end
        FPU_FRECIP: begin
            // frecip.s: 1.0/fj。映射为 DIV(operands[0]=1.0, operands[1]=fj), 舍入用 FCSR rm。
            cvfpu_op = fpnew_pkg::DIV;
            cvfpu_op_mod = 1'b0;
        end
        FPU_FMADD: begin
            // fmadd.s: fj*fk+fa = operands[0]*operands[1]+operands[2], 一次舍入。
            cvfpu_op = fpnew_pkg::FMADD;
            cvfpu_op_mod = 1'b0;
        end
        FPU_FMSUB: begin
            // fmsub.s: fj*fk-fa。FMADD + op_mod=1(反转 operand C 符号)。
            cvfpu_op = fpnew_pkg::FMADD;
            cvfpu_op_mod = 1'b1;
        end
        FPU_FABS: begin
            // fabs.s: |fj| = 清符号位。SGNJ(rm=RDN, fsgnjx) 取 operand_a.sign XOR operand_b.sign;
            //         operand_a=operand_b=fj → sign=0, 即 |fj|。NaN 不规范化(仅清符号位, 保留 payload)。
            cvfpu_op = fpnew_pkg::SGNJ;
            cvfpu_op_mod = 1'b0;
            cvfpu_rm = fpnew_pkg::RDN;
        end
        FPU_FCOPYSIGN: begin
            // fcopysign.s: fd = {fk[31], fj[30:0]}。SGNJ(rm=RNE, fsgnj) 取 operand_b 的符号 +
            //              operand_a 的数值; operand_a=fj(数值源), operand_b=fk(符号源)。
            cvfpu_op = fpnew_pkg::SGNJ;
            cvfpu_op_mod = 1'b0;
            cvfpu_rm = fpnew_pkg::RNE;
        end
        // ---- 阶段2: 新增运算类 ----
        FPU_FSQRT: begin
            // fsqrt.s: sqrt(fj)。DIVSQRT/SQRT (TH32 原生开方通路), 舍入用 FCSR rm。
            //   operand 路由: SQRT 用 operands[0]=fj (见下方 is_sqrt)。
            cvfpu_op = fpnew_pkg::SQRT;
            cvfpu_op_mod = 1'b0;
        end
        FPU_FMAX: begin
            // fmax.s: 数值最大。NONCOMP/MINMAX, rm=RTZ 选 MAX (见 fpnew_noncomp.sv:241)。
            //   NaN 语义与手册 maxNum 逐条吻合(一 NaN 返回另一操作数, 双 NaN qNaN, sNaN 置 NV)。
            cvfpu_op = fpnew_pkg::MINMAX;
            cvfpu_op_mod = 1'b0;
            cvfpu_rm = fpnew_pkg::RTZ;
        end
        FPU_FMIN: begin
            // fmin.s: 数值最小。rm=RNE 选 MIN。
            cvfpu_op = fpnew_pkg::MINMAX;
            cvfpu_op_mod = 1'b0;
            cvfpu_rm = fpnew_pkg::RNE;
        end
        // 注: fmaxa/fmina (绝对值最值) 拆到阶段2b —— CVFPU MINMAX 按数值比且返回原操作数,
        //     无法表达"按绝对值比、返回原值", 需本地绝对值比较器 + 原值选择通路。
        FPU_FNMADD: begin
            // 手册 fnmadd.s = -(fj*fk+fa)。CVFPU 无 FNMADD 算子, 用 FNMSUB+op_mod=1
            //   (fpnew_fma.sv:178-179: FNMSUB op_mod=1 翻转 product A 与 addend C 符号 → -(A*B)-C=-(A*B+C))。
            cvfpu_op = fpnew_pkg::FNMSUB;
            cvfpu_op_mod = 1'b1;
        end
        FPU_FNMSUB: begin
            // 手册 fnmsub.s = -(fj*fk-fa)。CVFPU FNMSUB+op_mod=0 (仅翻转 product A → -(A*B)+C)。
            cvfpu_op = fpnew_pkg::FNMSUB;
            cvfpu_op_mod = 1'b0;
        end
        // 注: fclass (CLASSIFY) 拆到阶段2b —— CVFPU 分类结果走独立 class_mask_o 端口,
        //   未连到 result_o(result_d=DONT_CARE), 需额外引出或本地判类, 是特殊数据通路。
        FPU_FTINTRM, FPU_FTINTRP, FPU_FTINTRNE: begin
            // ftintrm/rp/rne.w.s: F2I, 舍入模式由指令强制(非 FCSR)。
            cvfpu_op = fpnew_pkg::F2I;
            cvfpu_op_mod = 1'b0;
            cvfpu_rm = (fpu_req_op == FPU_FTINTRM) ? fpnew_pkg::RDN :  // 向 -inf
                       (fpu_req_op == FPU_FTINTRP) ? fpnew_pkg::RUP :  // 向 +inf
                                                     fpnew_pkg::RNE;   // 就近
        end
        FPU_FMAXA, FPU_FMINA, FPU_FCLASS: begin
            // 阶段2b: 本地覆盖旁路。走 dummy SGNJ(NONCOMP 单周期, 借流水时序), 结果由 alt_val 覆盖。
            //   SGNJ 不会置异常标志(fmaxa/fmina 的 sNaN NV 由本地 alt 逻辑另置, 见输出段)。
            cvfpu_op = fpnew_pkg::SGNJ;
            cvfpu_op_mod = 1'b0;
            cvfpu_rm = fpnew_pkg::RNE;
        end
        default: cvfpu_op = fpnew_pkg::ADD;
    endcase
end

// CVFPU 三操作数映射(见 fpnew_fma.sv 操作数准备约定):
//   ADD/SUB: operand_a 被内部置为 +1.0, 实际计算 operands[1] ± operands[2],
//            故加减法的两个源操作数必须放到 [1]、[2];
//   MUL/DIV: 计算 operands[0] * / operands[1], 源操作数放 [0]、[1];
//   CMP/CONV: 使用 operands[0]、operands[1]。
// 因此 ADD/SUB 与其余运算的操作数位置不同, 必须按操作类型区分。
wire is_addsub = (fpu_req_op == FPU_ADD) || (fpu_req_op == FPU_SUB);
// is_sgnj: 单源 SGNJ, operand_a/operand_b 均取 fj (fmov/fneg/fabs)。
//   fcopysign 虽也走 SGNJ, 但符号源是 fk → 不并入此处, 用默认路由 [0]=fj/[1]=fk。
wire is_sgnj   = (fpu_req_op == FPU_FMOV) || (fpu_req_op == FPU_FNEG) || (fpu_req_op == FPU_FABS);
wire is_recip  = (fpu_req_op == FPU_FRECIP);                            // 1.0/fj
wire is_fma    = (fpu_req_op == FPU_FMADD) || (fpu_req_op == FPU_FMSUB) ||
                 (fpu_req_op == FPU_FNMADD) || (fpu_req_op == FPU_FNMSUB); // 三源 fj*fk±fa (含 nm 变体)
logic [2:0][31:0] operands_i;
assign operands_i[0] = is_addsub ? 32'b0          :  // ADD/SUB 时 [0] 被内部覆盖为 1.0, 填 0 即可
                       is_recip  ? 32'h3f80_0000  :  // frecip: 被除数 = 1.0
                                   fpu_req_a;          // MUL/DIV/CMP/CONV/SGNJ/FMA/fcopysign: operand0=fj
assign operands_i[1] = is_addsub          ? fpu_req_a :
                       (is_sgnj|is_recip) ? fpu_req_a :  // sgnj 符号源 / frecip 除数 均为 fj
                                            fpu_req_b;   // FMA: operand1=fk; fcopysign: 符号源 fk; CMP: fk
assign operands_i[2] = is_addsub ? fpu_req_b  :
                       is_fma    ? fpu_req_c  :          // FMA: operand2=fa (加数/被减数)
                                   32'b0;

// ---- fcmp 无序检测 + combine 模式 (阶段2: 22 种 cond 全集) ----
// 无序 = 任一源为 NaN(指数全 1 且尾数非 0)。fcmp 的 fj=fpu_req_a, fk=fpu_req_b。
wire cmp_a_nan      = (fpu_req_a[30:23] == 8'hff) && (fpu_req_a[22:0] != 23'b0);
wire cmp_b_nan      = (fpu_req_b[30:23] == 8'hff) && (fpu_req_b[22:0] != 23'b0);
wire cmp_unordered  = (fpu_req_op == FPU_FCMP) && (cmp_a_nan || cmp_b_nan);
// combine 模式(输出段 fcmp_bool 用), 由 fcmp_cond[4:1] 决定(bit0=S 布尔相同):
//   手册值: CAF0x0 CLT0x2 CEQ0x4 CLE0x6 CUN0x8 CULT0xa CUEQ0xc CULE0xe CNE0x10 COR0x14 CUNE0x18
//   0 PASS: P | 1 OR_UN: P|un | 2 FALSE: 0 | 3 UN: un | 4 NOT_UN: ~un | 5 NEG_ORD: ~P&~un | 6 NEG_UN: ~P|un
logic [2:0] cmp_combine;
always_comb begin
    case (fcmp_cond[4:1])
        4'h0: cmp_combine = 3'd2; // CAF/SAF : FALSE
        4'h1: cmp_combine = 3'd0; // CLT/SLT : P(LT)
        4'h2: cmp_combine = 3'd0; // CEQ/SEQ : P(EQ)
        4'h3: cmp_combine = 3'd0; // CLE/SLE : P(LE)
        4'h4: cmp_combine = 3'd3; // CUN/SUN : UN
        4'h5: cmp_combine = 3'd1; // CULT    : P(LT)|un
        4'h6: cmp_combine = 3'd1; // CUEQ    : P(EQ)|un
        4'h7: cmp_combine = 3'd1; // CULE    : P(LE)|un
        4'h8: cmp_combine = 3'd5; // CNE/SNE : ~P(EQ)&~un (有序不等)
        4'ha: cmp_combine = 3'd4; // COR/SOR : ~un
        4'hc: cmp_combine = 3'd6; // CUNE    : ~P(EQ)|un
        default: cmp_combine = 3'd0;
    endcase
end

// ---- 龙芯 NaN 传播预计算 (ISA 3.1.1.3) ----
// 源操作数: fj=fpu_req_a, fk=fpu_req_b, 优先级 fj>fk。
//   情况一 源含 SNaN: 取优先级最高的 SNaN, 尾数最高位置 1(quiet)、其余位保持。
//   情况二 无 SNaN 有 QNaN: 取优先级最高的 QNaN 原样。
//   其它(源无 NaN 但运算生成 NaN, 如 0/0、Inf-Inf): 用缺省 0x7FC00000, CVFPU 本身即如此, 无需覆盖。
// 仅算术(fadd/fsub/fmul/fdiv)结果为浮点时才传播; fcmp/转换不走此路。
// 源使用情况按操作类型区分(req_b/req_c 在非对应操作时为垃圾, 不可参与 NaN 判定):
//   two_src(fadd/fsub/fmul/fdiv): 用 fj,fk;  frecip: 仅 fj;  fma(fmadd/fmsub): 用 fj,fk,fa。
wire two_src = (fpu_req_op == FPU_ADD) || (fpu_req_op == FPU_SUB) ||
               (fpu_req_op == FPU_MUL) || (fpu_req_op == FPU_DIV);
wire uses_b  = two_src || is_fma;        // fk 是真实源
wire uses_c  = is_fma;                    // fa 是真实源
wire a_is_nan = (fpu_req_a[30:23] == 8'hff) && (fpu_req_a[22:0] != 23'b0);
wire b_is_nan = uses_b && (fpu_req_b[30:23] == 8'hff) && (fpu_req_b[22:0] != 23'b0);
wire c_is_nan = uses_c && (fpu_req_c[30:23] == 8'hff) && (fpu_req_c[22:0] != 23'b0);
wire a_is_snan = a_is_nan && ~fpu_req_a[22];
wire b_is_snan = b_is_nan && ~fpu_req_b[22];
wire c_is_snan = c_is_nan && ~fpu_req_c[22];
// frecip / fma / fsqrt 也遵循龙芯算术 NaN 传播; fma 优先级 fj>fk>fa; fsqrt 单源仅 fj。
wire is_fp_arith = two_src || (fpu_req_op == FPU_FRECIP) || is_fma || (fpu_req_op == FPU_FSQRT);
wire        nan_prop_en  = is_fp_arith && (a_is_nan || b_is_nan || c_is_nan);
wire [31:0] nan_prop_val = a_is_snan ? (fpu_req_a | 32'h0040_0000) :  // quiet fj (最高优先 SNaN)
                           b_is_snan ? (fpu_req_b | 32'h0040_0000) :  // quiet fk
                           c_is_snan ? (fpu_req_c | 32'h0040_0000) :  // quiet fa (仅 fma)
                           a_is_nan  ?  fpu_req_a                   :  // fj 为 QNaN, 原样
                           b_is_nan  ?  fpu_req_b                   :  // fk 为 QNaN, 原样
                                        fpu_req_c;                     // fa 为 QNaN, 原样 (仅 fma)

// ---- 阶段2b: fmaxa/fmina/fclass 本地结果 (走 dummy SGNJ, 输出段用 alt_val 覆盖) ----
// fmaxa/fmina: maxNumMag/minNumMag —— 按绝对值比, 返回绝对值大/小的【原操作数(保符号)】。
//   非 NaN 的 FP32 绝对值序 = 低 31 位无符号整数序(清符号后 指数||尾数 的整数比较即绝对值比较)。
//   NaN 规则同 maxNum/minNum: 一个 NaN 返回另一非 NaN 操作数; 双 NaN 返回 canonical qNaN(0x7fc00000);
//   sNaN 置 NV。绝对值相等(如 +x 与 -x)时手册 maxNumMag/minNumMag 未强制符号, 取 fj(与常见实现一致)。
wire is_maxa = (fpu_req_op == FPU_FMAXA);
wire is_mina = (fpu_req_op == FPU_FMINA);
wire is_maxmina = is_maxa || is_mina;
wire mag_a_nan = (fpu_req_a[30:23] == 8'hff) && (fpu_req_a[22:0] != 23'b0);
wire mag_b_nan = (fpu_req_b[30:23] == 8'hff) && (fpu_req_b[22:0] != 23'b0);
wire mag_a_snan = mag_a_nan && ~fpu_req_a[22];
wire mag_b_snan = mag_b_nan && ~fpu_req_b[22];
wire [30:0] mag_a = fpu_req_a[30:0];   // 清符号后的绝对值位模式
wire [30:0] mag_b = fpu_req_b[30:0];
wire a_mag_ge_b = (mag_a >= mag_b);    // |fj| >= |fk|
// 选原操作数: maxa 取绝对值大者, mina 取绝对值小者; 相等时 (a_mag_ge_b 为真) 取 fj。
wire [31:0] maxmina_pick = is_maxa ? (a_mag_ge_b ? fpu_req_a : fpu_req_b)
                                   : (a_mag_ge_b ? fpu_req_b : fpu_req_a);
wire [31:0] maxmina_val =
    (mag_a_nan && mag_b_nan) ? 32'h7fc0_0000 :          // 双 NaN → canonical qNaN
    mag_a_nan                ? fpu_req_b       :          // 仅 fj NaN → 返回 fk
    mag_b_nan                ? fpu_req_a       :          // 仅 fk NaN → 返回 fj
                               maxmina_pick;              // 均非 NaN → 按绝对值选原值

// fclass.s: 手册 §3.2.1.8 输出 10-bit class mask 到 fd。bit 含义(FR[fd][9:0]):
//   [0]=-inf [1]=-normal [2]=-subnormal [3]=-zero [4]=+inf [5]=+normal [6]=+subnormal [7]=+zero
//   [8]=snan(signaling NaN) [9]=qnan(quiet NaN)。本地直接判类, 不走 CVFPU CLASSIFY(其结果在独立端口)。
wire        cls_sign = fpu_req_a[31];
wire [7:0]  cls_exp  = fpu_req_a[30:23];
wire [22:0] cls_man  = fpu_req_a[22:0];
wire cls_exp_zero = (cls_exp == 8'h00);
wire cls_exp_ones = (cls_exp == 8'hff);
wire cls_is_zero    = cls_exp_zero && (cls_man == 23'b0);
wire cls_is_subnorm = cls_exp_zero && (cls_man != 23'b0);
wire cls_is_inf     = cls_exp_ones && (cls_man == 23'b0);
wire cls_is_nan     = cls_exp_ones && (cls_man != 23'b0);
wire cls_is_snan    = cls_is_nan && ~cls_man[22];
wire cls_is_qnan    = cls_is_nan &&  cls_man[22];
wire cls_is_normal  = ~cls_exp_zero && ~cls_exp_ones;
wire [31:0] fclass_val = {22'b0,
    cls_is_qnan,                        // [9]
    cls_is_snan,                        // [8]
    ~cls_sign & cls_is_zero,            // [7] +0
    ~cls_sign & cls_is_subnorm,         // [6] +subnormal
    ~cls_sign & cls_is_normal,          // [5] +normal
    ~cls_sign & cls_is_inf,             // [4] +inf
     cls_sign & cls_is_zero,            // [3] -0
     cls_sign & cls_is_subnorm,         // [2] -subnormal
     cls_sign & cls_is_normal,          // [1] -normal
     cls_sign & cls_is_inf};            // [0] -inf

wire        alt_en  = is_maxmina || (fpu_req_op == FPU_FCLASS);
wire [31:0] alt_val = (fpu_req_op == FPU_FCLASS) ? fclass_val : maxmina_val;
// fmaxa/fmina 的 sNaN 置 NV (fclass 不置任何异常标志)。
wire        alt_nv  = is_maxmina && (mag_a_snan || mag_b_snan);

fpu_tag_t tag_i;
assign tag_i = '{
    dest:         fpu_req_dest,
    tag:          fpu_req_tag,
    is_fcmp:      (fpu_req_op == FPU_FCMP),
    fcmp_cond:    fcmp_cond,
    nan_prop_en:  nan_prop_en,
    nan_prop_val: nan_prop_val,
    cmp_combine:  cmp_combine,
    cmp_unordered: cmp_unordered,
    alt_en:       alt_en,
    alt_val:      alt_val,
    alt_nv:       alt_nv
};

fpnew_pkg::status_t status_o;
fpu_tag_t tag_o;
wire [31:0] cvfpu_result;   // CVFPU 原始结果(在实例化前声明, 避免隐式 1-bit 网络截断)
wire        cvfpu_valid;    // CVFPU 原始 out_valid_o(组合, 见下方输出寄存器说明)

wire rst_ni = ~reset;

localparam fpnew_pkg::fpu_implementation_t FPU_IMPL = '{
    PipeRegs:   '{default: 2},
    UnitTypes:  '{'{default: fpnew_pkg::PARALLEL}, // ADDMUL
                  '{default: fpnew_pkg::MERGED},   // DIVSQRT
                  '{default: fpnew_pkg::PARALLEL}, // NONCOMP
                  '{default: fpnew_pkg::MERGED}},  // CONV
    PipeConfig: fpnew_pkg::DISTRIBUTED
};

fpnew_top #(
    .Features       ( fpnew_pkg::RV32F ),
    .Implementation ( FPU_IMPL ),
    // DivSqrtSel: PULP 的 div_sqrt_mvp 除法器舍入不符合 IEEE-754(上游 issue#17 确认为
    // by-design, 末位 1-ULP 截断), 违反龙芯 ISA"除法遵循 754"的要求。改用 T-Head E906
    // 的 TH32 除法器(上游官方推荐的合规路径, FP32-only, vendor/opene906)。
    .DivSqrtSel     ( fpnew_pkg::TH32  ),
    .TagType        ( fpu_tag_t )
) u_cvfpu (
    .clk_i          ( clk ),
    .rst_ni         ( rst_ni ),
    .operands_i     ( operands_i ),
    .rnd_mode_i     ( cvfpu_rm ),
    .op_i           ( cvfpu_op ),
    .op_mod_i       ( cvfpu_op_mod ),
    .src_fmt_i      ( fpnew_pkg::FP32 ),
    .dst_fmt_i      ( fpnew_pkg::FP32 ),
    .int_fmt_i      ( fpnew_pkg::INT32 ),
    .vectorial_op_i ( 1'b0 ),
    .tag_i          ( tag_i ),
    .simd_mask_i    ( '1 ),
    .in_valid_i     ( fpu_req_valid ),
    .in_ready_o     ( fpu_req_ready ),
    .flush_i        ( flush ),
    .result_o       ( cvfpu_result ),
    .status_o       ( status_o ),
    .tag_o          ( tag_o ),
    .out_valid_o    ( cvfpu_valid ),
    .out_ready_i    ( fpu_rsp_ready ),
    .busy_o         ( ),
    .early_valid_o  ( )
);

// ---- fcmp 结果组合 (阶段2: 22 cond 全集) ----
// CVFPU CMP 出基础谓词 P = cvfpu_result[0] (LT/EQ/LE 之一, 由 rm 选; NaN 时 P=0)。
// un = tag_o.cmp_unordered (本次比较两源任一 NaN)。按 cmp_combine 组合出手册布尔:
//   0 PASS   = P              (CLT/CEQ/CLE)
//   1 OR_UN  = P | un         (CULT/CUEQ/CULE)
//   2 FALSE  = 0              (CAF)
//   3 UN     = un             (CUN)
//   4 NOT_UN = ~un            (COR)
//   5 NEG_ORD= ~P & ~un       (CNE 有序不等, NaN→0)
//   6 NEG_UN = ~P | un        (CUNE ~EQ 或无序)
wire cmp_P  = cvfpu_result[0];
wire cmp_un = tag_o.cmp_unordered;
reg  cmp_bool;
always_comb begin
    case (tag_o.cmp_combine)
        3'd0: cmp_bool = cmp_P;
        3'd1: cmp_bool = cmp_P | cmp_un;
        3'd2: cmp_bool = 1'b0;
        3'd3: cmp_bool = cmp_un;
        3'd4: cmp_bool = ~cmp_un;
        3'd5: cmp_bool = ~cmp_P & ~cmp_un;
        3'd6: cmp_bool = ~cmp_P | cmp_un;
        default: cmp_bool = cmp_P;
    endcase
end
// fcmp 时结果 = {31'b0, cmp_bool}; 非 fcmp 时用 CVFPU 原始结果。
wire [31:0] cvfpu_result_cmp = tag_o.is_fcmp ? {31'b0, cmp_bool} : cvfpu_result;
// 龙芯 NaN 传播: 若本算术运算源含 NaN, 用随 tag 传来的传播值覆盖 CVFPU 的规范化 0x7fc00000。
//   fcmp/转换 nan_prop_en=0, 不受影响。
wire [31:0] fpu_rsp_result_comb = tag_o.nan_prop_en ? tag_o.nan_prop_val : cvfpu_result_cmp;

// ---- 输出寄存器 ----
// CVFPU 的 PipeRegs=2/DISTRIBUTED 配置下, 最后一级流水寄存器之后的归一化/舍入/打包逻辑
// 全是组合逻辑(result_o/tag_o/status_o 直接是组合输出), 这里加一级寄存器把它和外部消费者
// (id_stage 的分支重定向/scoreboard 等逻辑)隔开, 避免组合链跨边界一路通到下游时序敏感路径。
// fpu_rsp_ready 在 mycpu_top.v 中恒为 1'b1(下游从不反压 CVFPU 的 out_ready_i), 故此处可以
// 无条件每拍捕获, 不需要额外的 skid buffer; 纯粹把 FPU 响应的可见延迟从 N 拍变成 N+1 拍。
logic        fpu_rsp_valid_r;
logic [31:0] fpu_rsp_result_r;
logic [ 4:0] fpu_rsp_dest_r;
logic        fpu_rsp_tag_r;
logic        fpu_rsp_is_fcmp_r;
logic [ 4:0] fpu_rsp_flags_r;

always_ff @(posedge clk) begin
    if (reset) begin
        fpu_rsp_valid_r <= 1'b0;
    end else begin
        fpu_rsp_valid_r   <= cvfpu_valid;
        fpu_rsp_result_r  <= fpu_rsp_result_comb;
        fpu_rsp_dest_r    <= tag_o.dest;
        fpu_rsp_tag_r     <= tag_o.tag;
        fpu_rsp_is_fcmp_r <= tag_o.is_fcmp;
        fpu_rsp_flags_r   <= {status_o.NV | tag_o.alt_nv, status_o.DZ, status_o.OF, status_o.UF, status_o.NX};
    end
end

assign fpu_rsp_valid   = fpu_rsp_valid_r;
assign fpu_rsp_result  = fpu_rsp_result_r;
assign fpu_rsp_dest    = fpu_rsp_dest_r;
assign fpu_rsp_tag     = fpu_rsp_tag_r;
assign fpu_rsp_is_fcmp = fpu_rsp_is_fcmp_r;
assign fpu_rsp_flags   = fpu_rsp_flags_r;
assign fcmp_out        = fpu_rsp_result_r[0];

endmodule

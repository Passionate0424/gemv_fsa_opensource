#ifndef FP_BITLEVEL_H
#define FP_BITLEVEL_H
/*
 * fp_bitlevel.h —— GEMV-FSA 硬件浮点通路的位级参考模型
 *
 * 作用：把 RTL 里的 fp32 运算逐条转录成整数位运算，让 C 侧能得到与硬件
 * **逐位相同**的结果。硬件每一级都是纯截断（fpmul 取 final_product[45:23]、
 * fpadd 取 man[22:0]，都没有 round/sticky/guard），任何 C 浮点舍入模式都
 * 复现不了，所以这里全部走 uint32_t 位操作。
 *
 * 验证状态（真实硬件输入输出对离线比对，不是推断）：
 *   exp2_hw    : 31999/31999 逐位一致（tb_exp2_unit 抓的 32000 组）
 *   recip_bits :   6000/6000 逐位一致（tb_recip_unit 抓的 6000 组）
 *   fpmul/fpadd: 作为上述两者的底座间接验证
 *
 * 使用者：
 *   tb/dpi/e2e_golden.c   —— +GOLDEN_BITACC 模式的 FSA bit-accurate golden
 *   tools/lut_eval.c      —— 新算子 LUT 方案的精度评估台
 * 新增硬件算子前，先在这里把方案搭出来评精度，再写 RTL。
 *
 * 对应 RTL：rtl/fpmul_seq_pipeline.sv, rtl/PE/fpadd_seq_2stage.sv,
 *           rtl/fsa/FPAccUnit_pipe.sv, rtl/fsa/RawFloat_Div.sv
 */
#include <stdint.h>
#include <string.h>

// 8段PWL exp2，系数直接取自 rtl/fsa/FPAccUnit_pipe.sv:91-106 的
// exp2_intercept_lut / exp2_slope_lut，按 split_outFracMSBs（|frac|高3位）索引。
//
// 这里必须用RTL的bit pattern，不能沿用 tb/dpi/golden_compare.c 里那份：实测两者
// 每一段都差 3e-4~4.6e-4，因为RTL用的是minimax均衡系数（八段中点相对误差恒为
// 4.69e-4），而golden_compare.c用的是端点插值理论值（intercept[0]恰好是2^0=1.0，
// 误差集中在段中点）。拿后者建模等于在硬件误差之上再叠一层自己的误差。
//
// 注意：这里没有 x < -8 的截断。tb/dpi/golden_compare.c 里有那么一条，但用
// tb_exp2_unit 抓的32000组真实硬件输入输出对验证过——硬件对 x 一路到 -25 都正常
// 输出（32000个样本里只有1个零，还是流水线首拍的无效数据），根本不存在这个截断。
// 加上它反而会在softmax里错误地丢弃 exp(y) 中 y < -5.545 的项。
//
// 同一批数据也确认了：用本函数（RTL原始LUT系数 + 下面这个公式）复现硬件，
// 平均相对偏差 3.6e-8（低于fp32 ULP 1.19e-7），58%的样本逐位相同，剩余差异
// 来自RTL内部26位中间尾数转IEEE 24位的两步舍入。
// ===== bit-level primitives transcribed from RTL =====
// Verified 100% bit-exact (31999/31999) against hardware pairs captured
// by tb_exp2_unit. Pure integer bit manipulation -- no C float arithmetic,
// because the hardware truncates at every stage (fpmul takes
// final_product[45:23], fpadd takes man[22:0], neither has round/sticky)
// and no C rounding mode can reproduce that.
#include <stdint.h>
/* ---------- fpmul_seq_pipeline.sv ---------- */
static uint32_t fpmul_bits(uint32_t A, uint32_t B)
{
    uint32_t a_exp_raw = (A >> 23) & 0xFF, b_exp_raw = (B >> 23) & 0xFF;
    uint32_t a_frac = A & 0x7FFFFF,        b_frac = B & 0x7FFFFF;
    uint32_t sign = ((A >> 31) ^ (B >> 31)) & 1;

    int a_is_zero = (a_exp_raw == 0 && a_frac == 0);
    int b_is_zero = (b_exp_raw == 0 && b_frac == 0);
    int a_is_inf  = (a_exp_raw == 0xFF && a_frac == 0);
    int b_is_inf  = (b_exp_raw == 0xFF && b_frac == 0);
    int a_is_nan  = (a_exp_raw == 0xFF && a_frac != 0);
    int b_is_nan  = (b_exp_raw == 0xFF && b_frac != 0);
    if (a_is_nan || b_is_nan) return 0x7FC00000u;
    if (a_is_inf || b_is_inf) return (sign << 31) | 0x7F800000u;
    if (a_is_zero || b_is_zero) return sign << 31;

    /* subnormal handling: leading bit is 0 when biased exp == 0 */
    uint64_t a_man = (a_exp_raw == 0) ? a_frac : (0x800000u | a_frac);
    uint64_t b_man = (b_exp_raw == 0) ? b_frac : (0x800000u | b_frac);
    uint64_t product = a_man * b_man;                     /* 48-bit exact */
    int32_t  exp_sum = (int32_t)a_exp_raw + (int32_t)b_exp_raw - 127;

    int prod_overflow = (product >> 47) & 1;
    uint64_t shifted  = prod_overflow ? (product >> 1) : product;
    int32_t  sh_exp   = prod_overflow ? exp_sum + 1 : exp_sum;

    int need_norm = !prod_overflow && !((product >> 46) & 1) && (exp_sum > 0);
    uint64_t fin_m = shifted;
    int32_t  fin_e = sh_exp;
    if (need_norm) {
        /* multiplication_normaliser: LZD over in_m[46:41], max 5 left shifts */
        uint64_t m = product; int32_t e = exp_sum;
        int sh = 0;
        if      (((m >> 41) & 0x3F) == 0x01) sh = 5;
        else if (((m >> 42) & 0x1F) == 0x01) sh = 4;
        else if (((m >> 43) & 0x0F) == 0x01) sh = 3;
        else if (((m >> 44) & 0x07) == 0x01) sh = 2;
        else if (((m >> 45) & 0x03) == 0x01) sh = 1;
        fin_m = (m << sh) & 0xFFFFFFFFFFFFull;
        fin_e = e - sh;
    }

    if (fin_e <= 0)   return sign << 31;
    if (fin_e >= 255) return (sign << 31) | 0x7F800000u;
    /* s2_result = {sign, exp[7:0], final_product[45:23]} -- pure truncation */
    return (sign << 31) | (((uint32_t)fin_e & 0xFF) << 23)
         | (uint32_t)((fin_m >> 23) & 0x7FFFFF);
}

/* ---------- fpadd_seq_2stage.sv ---------- */
static uint32_t fpadd_bits(uint32_t A, uint32_t B)
{
    uint32_t ae = (A >> 23) & 0xFF, be = (B >> 23) & 0xFF;
    uint32_t af = A & 0x7FFFFF,     bf = B & 0x7FFFFF;
    int a_nan = (ae == 0xFF && af != 0), b_nan = (be == 0xFF && bf != 0);
    int a_zero = (ae == 0 && af == 0),   b_zero = (be == 0 && bf == 0);
    int a_inf = (ae == 0xFF && af == 0), b_inf = (be == 0xFF && bf == 0);

    /* corner cases, exactly in RTL's priority order */
    if (a_nan || (b_zero && !b_nan)) return A;
    if (b_nan || (a_zero && !a_nan)) return B;
    if (a_inf || b_inf) return (((A >> 31) ^ (B >> 31)) << 31) | 0x7F800000u;

    uint32_t a_sign = A >> 31, b_sign = B >> 31;
    uint32_t a_exp = (ae == 0) ? 1u : ae;
    uint32_t a_man = (ae == 0) ? af : (0x800000u | af);
    uint32_t b_exp = (be == 0) ? 1u : be;
    uint32_t b_man = (be == 0) ? bf : (0x800000u | bf);

    uint32_t out_sign = 0, out_exp = 0, out_man = 0;   /* out_man is 25-bit */
    if (a_exp == b_exp) {
        out_exp = a_exp;
        if (a_sign == b_sign) { out_man = a_man + b_man; out_sign = a_sign; }
        else if (a_man > b_man) { out_man = a_man - b_man; out_sign = a_sign; }
        else                    { out_man = b_man - a_man; out_sign = b_sign; }
    } else if (a_exp > b_exp) {
        out_exp = a_exp; out_sign = a_sign;
        uint32_t d = a_exp - b_exp;
        uint32_t t = (d >= 32) ? 0 : (b_man >> d);      /* truncate, no guard/sticky */
        out_man = (a_sign == b_sign) ? (a_man + t) : (a_man - t);
    } else {
        out_exp = b_exp; out_sign = b_sign;
        uint32_t d = b_exp - a_exp;
        uint32_t t = (d >= 32) ? 0 : (a_man >> d);
        out_man = (a_sign == b_sign) ? (b_man + t) : (b_man - t);
    }
    out_man &= 0x1FFFFFFu;                              /* 25-bit wrap */

    int is_zero = 0, overflow = 0;
    if (out_man == 0) { out_sign = 0; out_exp = 0; is_zero = 1; }
    else if ((out_man >> 24) & 1) { out_exp += 1; out_man >>= 1; overflow = 1; }

    int normalized = ((out_man >> 23) & 1) | overflow | is_zero;

    if (is_zero) return 0;
    if (normalized) return (out_sign << 31) | ((out_exp & 0xFF) << 23) | (out_man & 0x7FFFFF);
    if (out_exp != 0) {
        /* addition_normaliser: LZD on in_m[23:x], shift up to 20 */
        int sh = 0;
        for (int k = 20; k >= 1; k--) {
            if ((out_man >> (23 - k + 1)) == 0 && ((out_man >> (23 - k)) & 1)) { sh = k; break; }
        }
        if (sh == 0) {                       /* already has a bit at [23] or all-zero low */
            return (out_sign << 31) | ((out_exp & 0xFF) << 23) | (out_man & 0x7FFFFF);
        }
        uint32_t ne = out_exp - sh;
        uint32_t nm = (out_man << sh) & 0x1FFFFFFu;
        if (ne == 0 || ne > out_exp) return 0;           /* underflow -> zero */
        return (out_sign << 31) | ((ne & 0xFF) << 23) | (nm & 0x7FFFFF);
    }
    return (out_sign << 31) | ((out_exp & 0xFF) << 23) | (out_man & 0x7FFFFF);
}

/* ---------- LUT (FPAccUnit_pipe.sv:91-106) ---------- */
static const uint32_t LUT_ICPT[8] = {0x3f7fe21fu,0x3f7e2064u,0x3f7ae614u,0x3f7674cdu,
                                     0x3f7105ddu,0x3f6acb35u,0x3f63f03au,0x3f5c9a86u};
static const uint32_t LUT_SLOPE[8]= {0x3f29f2fbu,0x3f1bd814u,0x3f0ee8ddu,0x3f030c78u,
                                     0x3ef05829u,0x3edc6593u,0x3eca1acfu,0x3eb954b3u};

/* ---------- full exp2 path ---------- */
static uint32_t exp2_hw(uint32_t xb)
{
    uint32_t sign = xb >> 31;
    uint32_t eb   = (xb >> 23) & 0xFF;
    uint32_t fr   = xb & 0x7FFFFF;
    int isZero = (eb == 0 && fr == 0);
    int32_t  in_exp = (int32_t)eb - 127;              /* RawFloat exp, 9-bit signed */
    uint32_t in_man = 0x800000u | fr;                 /* 24-bit with implicit 1 */

    /* exp2 溢出保护：SplitIF 在 |x|>=256 (io_in_exp[7:3]非零) 时置 isInf
       (RawFloat_SplitIF.sv:81)，FPAccUnit 据此拉 exp2_overflow，把 FMA 的 a 和 c
       同时强制为零 (FPAccUnit_pipe.sv:127,193)，于是输出恒为 0。
       漏掉这条会让大值域用例算出 -3264*slope+icpt 这类垃圾值喂进 softmax——
       实测 val_range=20.0 的 8 个 case 全崩(errors=31/32)，加上后恢复。 */
    /* 溢出时必须保留输入符号，不能直接返回 +0：硬件只把 FMA 的 a/c 的 isZero
       标志拉起(FPAccUnit_pipe.sv:128)，io_in_a_sign 原样保留，于是
       mul=fpmul(-0,slope>0)=-0、add=fpadd(-0,+0) 走 b_zero 分支返回 A=-0，
       最终输出 -0。写成 return 0 会在 |x|>=177 的饱和区把零的符号弄反，
       由 tb_silu_unit 的 x=-177/-1000/-0 三个 case 实测暴露。 */
    if (eb == 0xFF || in_exp >= 8) return sign << 31;

    /* --- RawFloat_SplitIF --- */
    int GEN = (in_exp < 0);
    int32_t rsa = -1 - in_exp;                        /* 9'h1FF - io_in_exp */
    uint32_t fracAligned = in_man >> ((uint32_t)rsa & 3u);
    uint64_t shifted = ((uint64_t)in_man) << ((uint32_t)in_exp & 7u);
    uint32_t GEN0 = (uint32_t)((shifted >> 23) & 0xFF);
    int hi_exp_set = ((in_exp >> 3) & 0x1F) != 0 && !GEN;   /* |io_in_exp[7:3] for positive exp */
    if (in_exp >= 0) hi_exp_set = (((uint32_t)in_exp >> 3) & 0x1F) != 0;
    int GEN1 = GEN || hi_exp_set;
    int GEN2 = ((shifted & 0x7FFFFF) == 0);

    int32_t split_int = GEN1 ? 0 : (sign ? -(int32_t)GEN0 : (int32_t)GEN0);

    uint32_t fracMSBs;
    if (GEN) fracMSBs = (rsa < 3) ? ((fracAligned >> 21) & 7u) : 0u;
    else     fracMSBs = hi_exp_set ? 0u : (uint32_t)((shifted >> 20) & 7u);

    /* frac as RawFloat */
    int32_t  frac_exp; uint32_t frac_man;
    if (GEN1) { frac_exp = in_exp; frac_man = in_man; }
    else if (GEN2) { frac_exp = 0; frac_man = 0; }
    else {
        uint32_t low = (uint32_t)(shifted & 0x7FFFFF);
        int lzc = 0;
        for (int k = 22; k >= 2; k--) { if ((low >> k) & 1) { lzc = 23 - k; break; } }
        if (lzc == 0) lzc = ((low >> 1) & 1) ? 22 : 23;
        frac_exp = -lzc;
        frac_man = (uint32_t)(((uint64_t)low << lzc) & 0xFFFFFFu);
    }
    int frac_isZero = (!GEN1 && GEN2) || isZero;

    /* --- RawFloat -> IEEE for the three FMA operands --- */
    /* frac 为零时同样要带上符号：硬件这里只是把 isZero 标志送进 FMA，
       io_in_a_sign 一路保留（与溢出保护那条路径同理）。写成 0u 会丢掉 -0，
       在 x=-0 这类输入上把最终结果的零符号弄反。 */
    uint32_t a_ieee = frac_isZero ? (sign << 31)
                    : ((sign << 31) | ((((uint32_t)(frac_exp + 127)) & 0xFF) << 23)
                       | (frac_man & 0x7FFFFF));
    uint32_t b_ieee = LUT_SLOPE[fracMSBs];
    uint32_t c_ieee = LUT_ICPT[fracMSBs];

    /* --- mul then add (separate units, each truncating) --- */
    uint32_t mul_out = fpmul_bits(a_ieee, b_ieee);
    uint32_t add_out = fpadd_bits(mul_out, c_ieee);

    /* --- IEEE -> RawFloat, then exponent add, then output rounding --- */
    int32_t  fma_exp = (int32_t)((add_out >> 23) & 0xFF) - 127;
    uint32_t raw_man25 = ((add_out & 0x7FFFFF) << 2) & 0x1FFFFFFu;  /* {add[22:0],2'b00} */
    int32_t  raw_exp = split_int + fma_exp;
    uint32_t raw_sign = (add_out >> 31) & 1;
    int raw_zero = (((add_out >> 23) & 0xFF) == 0) && ((add_out & 0x7FFFFF) == 0);

    uint32_t g = (raw_man25 >> 1) & 1, s = raw_man25 & 1, l = (raw_man25 >> 2) & 1;
    uint32_t rounded_man = ((raw_man25 >> 2) & 0xFFFFFF) + ((g & s) | (g & (~s & 1) & l));
    int32_t  rounded_exp = raw_exp + (int32_t)((rounded_man >> 23) & 1);
    int overflow  = rounded_exp > 127;
    int underflow = rounded_exp < -126;

    uint32_t out_exp = (overflow) ? 0xFFu
                     : (raw_zero || underflow) ? 0u
                     : (uint32_t)((rounded_exp + 127) & 0xFF);
    uint32_t out_man = (raw_zero || underflow || overflow) ? 0u : (rounded_man & 0x7FFFFF);
    return (raw_sign << 31) | (out_exp << 23) | out_man;
}

// float wrapper so the existing online-softmax code needs no change
static float e2e_pwl_exp2(float x) {
    uint32_t xb, rb; float r;
    memcpy(&xb, &x, 4);
    rb = exp2_hw(xb);
    memcpy(&r, &rb, 4);
    return r;
}

/* 位级辅助：符号取反 / 比较 / IEEE bits 与 double 互转 */
static uint32_t f2b_(double d) { float f = (float)d; uint32_t b; memcpy(&b, &f, 4); return b; }
static double   b2d_(uint32_t b) { float f; memcpy(&f, &b, 4); return (double)f; }
static uint32_t fneg_(uint32_t b) { return b ^ 0x80000000u; }
static int      fgt_(uint32_t a, uint32_t b) { float x, y; memcpy(&x,&a,4); memcpy(&y,&b,4); return x > y; }

/* RawFloat_Div.sv：恢复余数法求 1/b。13 次迭代，每次出 2 位商，末位为 sticky。
   硬件的归一化不是除法而是 RECIPROCAL(算 1/l) + ACC_NORM(乘)，浮点下这与
   直接除法不等价（倒数一次舍入、乘法再一次），所以必须照抄这条路径。 */
static uint32_t recip_bits(uint32_t b_ieee)
{
    uint32_t eb = (b_ieee >> 23) & 0xFF, fr = b_ieee & 0x7FFFFF;
    uint32_t sign = b_ieee >> 31;
    if (eb == 0 && fr == 0) return (sign << 31) | (0xFFu << 23);   /* 1/0 -> inf */
    if (eb == 0xFF)         return (sign << 31);                   /* 1/inf -> 0 */

    int32_t  b_exp = (int32_t)eb - 127;
    uint32_t b_man = 0x800000u | fr;                 /* 24 bits */

    /* 每一步都要按 Verilog 的位宽截断：g1-b_man 在 g1<b_man 时下溢，硬件里被
       24 位自然截断，C 的 uint32 不会——漏掉这些掩码会让整个迭代跑偏。
       本实现已用 tb_recip_unit 抓的 6000 组真实输入输出对验证：sign/exp/mantissa
       全部逐位一致（6000/6000）。 */
    uint32_t quotient = 0, reminder = 0x800000u;     /* 26b / 25b */
    for (int it = 0; it < 13; it++) {
        uint32_t q  = (reminder >= b_man) ? 1u : 0u;
        uint32_t rn = q ? ((reminder & 0xFFFFFFu) - b_man) : (reminder & 0xFFFFFFu);
        uint32_t q1 = (((rn << 1) & 0x1FFFFFFu) >= b_man) ? 1u : 0u;
        uint32_t g1 = ((rn & 0x7FFFFFu) << 1) & 0xFFFFFFu;
        quotient = (((quotient & 0xFFFFFFu) << 2) | (q << 1) | q1) & 0x3FFFFFFu;
        reminder = (((q1 ? ((g1 - b_man) & 0xFFFFFFu) : g1) << 1)) & 0x1FFFFFFu;
    }
    uint32_t adj = ((quotient >> 25) & 1) ? quotient : ((quotient << 1) & 0x3FFFFFFu);
    int32_t  r_exp = -b_exp - (int32_t)(((quotient >> 25) & 1) ? 0 : 1);
    uint32_t r_man26 = ((adj >> 1) << 1) | (((adj & 1) | (reminder != 0)) ? 1u : 0u);

    /* 与 exp2 输出走同一条 accType 转换（raw 25 位 + RNE） */
    uint32_t raw25 = r_man26 & 0x1FFFFFFu;
    uint32_t g = (raw25 >> 1) & 1, s = raw25 & 1, lb = (raw25 >> 2) & 1;
    uint32_t rman = ((raw25 >> 2) & 0xFFFFFFu) + ((g & s) | (g & (~s & 1u) & lb));
    int32_t  rexp = r_exp + (int32_t)((rman >> 23) & 1);
    if (rexp >  127) return (sign << 31) | (0xFFu << 23);
    if (rexp < -126) return (sign << 31);
    return (sign << 31) | ((((uint32_t)(rexp + 127)) & 0xFF) << 23) | (rman & 0x7FFFFF);
}

/* ------------------------------------------------------------------------
 * SiLU 硬件微程序的位级模型
 *
 * 复用 fsa_accumulator 的 6 条命令拼出 silu(x)=x*sigmoid(x)，零新增算术单元。
 * 这里的运算顺序必须与硬件微程序逐条对应——顺序不同则截断点不同，验证的就不
 * 是将要实现的那个电路了。对应关系：
 *
 *   1 EXP_S1     scale = sa_in x attn_scale     sa_in=-|x|, attn_scale 写成 log2e
 *   2 EXP_S2     scale = exp2(scale) = t        cmd=1 时 SplitIF 只吃 a 操作数，
 *                                               b 被 LUT slope 顶替，故无 "x sram_in"
 *   3 ACC_NORM   num   = scale x sram_in = t*x  仅 x<0 走这步，x>=0 时 num=x
 *   4 ACC_SA     den   = scale x sram_in + sa_in = t*1.0 + 1.0
 *   5 SET_SCALE  scale = den
 *   6 RECIPROCAL scale = 1/(1+t)
 *   7 ACC_NORM   out   = scale x num
 *
 * 取 -|x| 而非 -x 是恒等变换(x<0 时分子分母同乘 e^x)，不是近似。目的有二：
 * 一是硬件 exp2 的 LUT 只覆盖负半轴(实测 exp2(0.5) 给 1.176 而非 1.414)；
 * 二是 |输入|>=256 时 SplitIF 置 isInf 会把输出强制成 0，锁在负半轴后饱和
 * 行为自动正确(x 很大正 -> silu->x；x 很大负 -> silu->0)。
 * ------------------------------------------------------------------------ */
#define FPBL_ONE    0x3F800000u   /* 1.0f   —— mac_top_v2.sv:1028 已有这条常数通路 */
#define FPBL_LOG2E  0x3FB8AA3Bu   /* log2(e) = 1.4426950408889634 */

static uint32_t silu_bits(uint32_t x_b)
{
    uint32_t neg = x_b >> 31;

    /* 1: scale = (-|x|) x log2e */
    uint32_t scale = fpmul_bits(x_b | 0x80000000u, FPBL_LOG2E);
    /* 2: scale = exp2(scale) = exp(-|x|) */
    uint32_t t     = exp2_hw(scale);
    /* 3: num = t*x (仅 x<0)；x>=0 时分子就是 x */
    uint32_t num   = neg ? fpmul_bits(t, x_b) : x_b;
    /* 4: den = t*1.0 + 1.0 —— 乘 1.0 这一拍不能省，硬件确实走了一次 fpmul */
    uint32_t den   = fpadd_bits(fpmul_bits(t, FPBL_ONE), FPBL_ONE);
    /* 5-6: scale = 1/(1+t) */
    uint32_t inv   = recip_bits(den);
    /* 7: out = scale x num */
    return fpmul_bits(inv, num);
}

#endif /* FP_BITLEVEL_H */

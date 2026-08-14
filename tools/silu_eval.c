/*
 * silu_eval.c —— SiLU 硬件微程序的位级精度评估台
 *
 * 目的：在动 RTL 之前，先量出"复用 fsa_accumulator 的 7 步微程序算 SiLU"
 *       到底有多准。判据：mean_rel < 1e-5 且 max_rel < 1e-3。
 *
 * 为什么必须位级模拟而不能用 C 的 float 近似算：硬件每一级都是纯截断，
 * fpmul 取 final_product[45:23]、fpadd 取 man[22:0]，都没有 round/sticky/guard，
 * 没有任何 C 舍入模式能复现（实测 fmaf RNE 只有 58% 逐位命中）。所以这里
 * 直接复用 tb/dpi/fp_bitlevel.h —— 那套原语是逐条转录 RTL 的，其中 exp2 对
 * tb_exp2_unit 抓的 32000 组真实硬件数据 100% bit-exact，recip 对 tb_recip_unit
 * 抓的 6000 组 100% bit-exact。
 *
 * 微程序（对应 fsa_accumulator 的 6 条命令，详见 plan §2.2）：
 *   1 EXP_S1     scale = (-|x|) x attn_scale     attn_scale 借 CSR 写成 log2e
 *   2 EXP_S2     scale = exp2(scale) = t         t = exp(-|x|) 恒在 (0,1]
 *   3 ACC_NORM   num   = t x x                   仅 x<0 走这步；x>=0 时 num = x
 *   4 ACC_SA     den   = t x 1.0 + 1.0 = 1+t
 *   5 SET_SCALE  scale = den
 *   6 RECIPROCAL scale = 1/(1+t)
 *   7 ACC_NORM   out   = scale x num = silu(x)
 *
 * 编译： gcc -O2 -o silu_eval tools/silu_eval.c -lm
 * 运行： ./silu_eval
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>

#include "../tb/dpi/fp_bitlevel.h"

static float  b2f(uint32_t b) { float f; memcpy(&f, &b, 4); return f; }
static uint32_t f2b(float f)  { uint32_t b; memcpy(&b, &f, 4); return b; }

/* 微程序本体在 fp_bitlevel.h 的 silu_bits()——run.c 的 SILU_APPROX 走的是同一份。
   不在这里另写一份：运算顺序不同则截断点不同，两份实现一旦漂移，评估的就不是
   将要实现的那个电路了。 */
#define silu_hw(x) silu_bits(x)

/* fp64 参考实现 */
static double silu_ref(double x)
{
    return x / (1.0 + exp(-x));
}

/* ------------------------------------------------------------------
 * 统计
 * ------------------------------------------------------------------ */
typedef struct {
    const char *name;
    long   n;
    double sum_rel;
    double max_rel;
    float  max_rel_x;      /* 最差点的输入 */
    double max_rel_hw;
    double max_rel_ref;
    long   ulp_bucket[5];  /* 0, <=1, <=4, <=16, >16 */
    long   n_nan;          /* 输出 NaN/Inf 的次数 */
} stat_t;

static void stat_init(stat_t *s, const char *name)
{
    memset(s, 0, sizeof(*s));
    s->name = name;
}

/* 输入本身是否为 NaN/Inf——喂非法输入得到非法输出是正确行为，不该计入精度统计 */
static int is_bad_input(uint32_t b)
{
    return (((b >> 23) & 0xFF) == 0xFF);
}

static void stat_add(stat_t *s, uint32_t x_b)
{
    if (is_bad_input(x_b)) return;

    float    xf   = b2f(x_b);
    uint32_t hw_b = silu_hw(x_b);
    double   hw   = (double)b2f(hw_b);
    double   ref  = silu_ref((double)xf);

    /* 输出健康性：不该出 NaN/Inf */
    uint32_t e = (hw_b >> 23) & 0xFF;
    if (e == 0xFF) { s->n_nan++; }

    s->n++;

    /* 相对误差：ref 接近零时改用相对于 |x| 的误差，避免小分母放大成假信号
       （silu 在 x→0 时本身趋于 0，此处绝对误差才是有意义的量） */
    double denom = fabs(ref) > 1e-6 ? fabs(ref) : (fabs((double)xf) > 1e-6 ? fabs((double)xf) : 1.0);
    double rel   = fabs(hw - ref) / denom;

    s->sum_rel += rel;
    if (rel > s->max_rel) {
        s->max_rel     = rel;
        s->max_rel_x   = xf;
        s->max_rel_hw  = hw;
        s->max_rel_ref = ref;
    }

    /* ULP 距离：把 fp64 参考按 fp32 舍入后比 bit 距离 */
    uint32_t ref_b = f2b((float)ref);
    long ulp = labs((long)(int32_t)(hw_b & 0x7FFFFFFF) - (long)(int32_t)(ref_b & 0x7FFFFFFF));
    if ((hw_b >> 31) != (ref_b >> 31) && ref != 0.0) ulp = 1 << 30;   /* 符号都错 */
    if      (ulp == 0)  s->ulp_bucket[0]++;
    else if (ulp <= 1)  s->ulp_bucket[1]++;
    else if (ulp <= 4)  s->ulp_bucket[2]++;
    else if (ulp <= 16) s->ulp_bucket[3]++;
    else                s->ulp_bucket[4]++;
}

static void stat_print(const stat_t *s)
{
    if (s->n == 0) return;
    printf("  %-22s n=%-7ld mean_rel=%.3e  max_rel=%.3e", s->name, s->n,
           s->sum_rel / (double)s->n, s->max_rel);
    if (s->n_nan) printf("  [NaN/Inf x%ld]", s->n_nan);
    printf("\n");
    printf("      worst @ x=%-14.6g hw=%-14.6g ref=%-14.6g\n",
           s->max_rel_x, s->max_rel_hw, s->max_rel_ref);
    printf("      ULP: exact=%ld  <=1:%ld  <=4:%ld  <=16:%ld  >16:%ld\n",
           s->ulp_bucket[0], s->ulp_bucket[1], s->ulp_bucket[2],
           s->ulp_bucket[3], s->ulp_bucket[4]);
}

int main(void)
{
    stat_t all, pos, neg, sat, tiny, edge;
    stat_init(&all,  "TOTAL");
    stat_init(&pos,  "x in [0,10]");
    stat_init(&neg,  "x in [-10,0)");
    stat_init(&sat,  "saturation |x|>=177");
    stat_init(&tiny, "tiny |x|<1e-30");
    stat_init(&edge, "PWL segment edges");

    /* ---- 1. 主区间密集扫描：FFN 的 hb 实际就落在这个范围 ---- */
    const int N = 200000;
    for (int i = 0; i <= N; i++) {
        double   x   = -10.0 + 20.0 * (double)i / (double)N;
        uint32_t x_b = f2b((float)x);
        stat_add(&all, x_b);
        stat_add(b2f(x_b) < 0.0f ? &neg : &pos, x_b);
    }

    /* ---- 2. PWL 段边界：x*log2e 的小数部分恰为 -k/8，验选段无 off-by-one ---- */
    for (int k = 0; k <= 8; k++) {
        for (int intpart = -12; intpart <= 12; intpart++) {
            /* 构造 y = x*log2e 落在段边界上，反解 x */
            double y = (double)intpart - (double)k / 8.0;
            double x = y / 1.4426950408889634;
            for (int d = -2; d <= 2; d++) {          /* 边界左右各取几个 ULP */
                uint32_t xb = f2b((float)x);
                xb = (uint32_t)((int32_t)xb + d);
                stat_add(&all,  xb);
                stat_add(&edge, xb);
            }
        }
    }

    /* ---- 3. 饱和区：触发 exp2 溢出保护（|输入|>=256 即 |x|>=177） ---- */
    const double sat_pts[] = { 177.0, 200.0, 1000.0, 1e6, 1e30, 3.4e38 };
    for (unsigned i = 0; i < sizeof(sat_pts) / sizeof(sat_pts[0]); i++) {
        for (int sgn = 0; sgn < 2; sgn++) {
            uint32_t xb = f2b((float)(sgn ? -sat_pts[i] : sat_pts[i]));
            stat_add(&all, xb);
            stat_add(&sat, xb);
        }
    }

    /* ---- 4. 极小值 / denormal：silu(x) ~ x/2，不应出 NaN ---- */
    const double tiny_pts[] = { 1e-30, 1e-38, 1e-40, 1e-44, 0.0 };
    for (unsigned i = 0; i < sizeof(tiny_pts) / sizeof(tiny_pts[0]); i++) {
        for (int sgn = 0; sgn < 2; sgn++) {
            uint32_t xb = f2b((float)(sgn ? -tiny_pts[i] : tiny_pts[i]));
            stat_add(&all,  xb);
            stat_add(&tiny, xb);
        }
    }

    printf("=== SiLU 微程序位级精度评估 ===\n");
    printf("(位级原语来自 tb/dpi/fp_bitlevel.h：exp2 与 recip 均已对真实硬件数据 100%% bit-exact)\n\n");
    stat_print(&all);
    printf("\n--- 分区间 ---\n");
    stat_print(&pos);
    stat_print(&neg);
    stat_print(&edge);
    stat_print(&sat);
    stat_print(&tiny);

    /* ---- 判据 ---- */
    double mean_rel = all.sum_rel / (double)all.n;
    printf("\n=== 判定 (mean_rel < 1e-5 且 max_rel < 1e-3) ===\n");
    printf("  mean_rel = %.3e   %s\n", mean_rel, mean_rel < 1e-5 ? "PASS" : "FAIL");
    printf("  max_rel  = %.3e   %s\n", all.max_rel, all.max_rel < 1e-3 ? "PASS" : "FAIL");
    printf("  NaN/Inf  = %ld       %s\n", all.n_nan, all.n_nan == 0 ? "PASS" : "FAIL");

    int ok = (mean_rel < 1e-5) && (all.max_rel < 1e-3) && (all.n_nan == 0);
    printf("\n  => %s\n", ok ? "达标，可以进入 RTL 实现" : "未达标，不动 RTL");

    /* ---- 抽样打印，便于人工核对 ---- */
    printf("\n--- 抽样 ---\n");
    printf("  %-10s %-14s %-14s %-10s\n", "x", "hw(bitlevel)", "ref(fp64)", "rel");
    const double show[] = { -8, -4, -2, -1, -0.5, 0, 0.5, 1, 2, 4, 8 };
    for (unsigned i = 0; i < sizeof(show) / sizeof(show[0]); i++) {
        uint32_t xb = f2b((float)show[i]);
        double hw  = (double)b2f(silu_hw(xb));
        double ref = silu_ref((double)b2f(xb));
        double den = fabs(ref) > 1e-6 ? fabs(ref) : 1.0;
        printf("  %-10.4g %-14.8g %-14.8g %.2e\n", show[i], hw, ref, fabs(hw - ref) / den);
    }
    return ok ? 0 : 1;
}

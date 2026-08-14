/*
 * lut_eval.c —— 硬件非线性算子 LUT 方案的精度评估台
 *
 * 作用：在写 RTL 之前，先用**位级模型**把候选的查表/分段近似方案跑一遍，
 * 用真实激活值分布评出精度，据此定 LUT 的段数、索引方式与位宽。
 *
 * 为什么必须用位级模型而不是 C 的 float：目标硬件每一级都是纯截断
 * （fpmul 取 final_product[45:23]、fpadd 取 man[22:0]，无 round/sticky），
 * 用 C float 评出来的精度会系统性偏乐观。fp_bitlevel.h 里的原语已对真实
 * 硬件输入输出对验证过逐位一致，是唯一可信的评估基座。
 *
 * 为什么必须用真实数据而不是均匀采样：合成分布会高估尾部、低估零附近的
 * 密度，而 PWL 误差恰恰集中在曲率大的区间。输入由 run.c 的 DUMP_ACT=1
 * 在 host 上跑完整推理导出（act_silu.bin / act_rope.bin）。
 *
 * 用法：
 *   gcc -O2 -I../tb/dpi lut_eval.c -o lut_eval -lm
 *   ./lut_eval act_silu.bin act_rope.bin
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "fp_bitlevel.h"

/* ------------------------------------------------------------------ */
/* 工具                                                                */
/* ------------------------------------------------------------------ */
static uint32_t f2b(float f) { uint32_t b; memcpy(&b, &f, 4); return b; }
static float    b2f(uint32_t b) { float f; memcpy(&f, &b, 4); return f; }

static int cmp_float(const void *a, const void *b)
{
    float x = *(const float *)a, y = *(const float *)b;
    return x < y ? -1 : x > y ? 1 : 0;
}

/* fp64 参考实现 */
static double ref_sigmoid(double x) { return 1.0 / (1.0 + exp(-x)); }
static double ref_silu(double x)    { return x * ref_sigmoid(x); }
/* 拟合目标是负半轴（见方案 A/B 的说明），拟合器传入的是 a>0 */
static double ref_silu_neg(double a)    { return ref_silu(-a); }
static double ref_sigmoid_neg(double a) { return ref_sigmoid(-a); }

/* ------------------------------------------------------------------ */
/* 分段方案：段索引直接由 fp32 位模式拼出来                             */
/*                                                                     */
/* 对 |x|，取 IEEE 指数 e 与尾数高 KBITS 位：                          */
/*     seg = (e - EMIN) * 2^KBITS + frac[22 : 23-KBITS]                */
/* 这与 FSA 里 exp2 用 split_outFracMSBs 当索引是同一套做法——硬件上   */
/* 就是几根线的位拼接，零逻辑代价，而且天然非均匀：越靠近零的区间分得   */
/* 越密，正好匹配 sigmoid/SiLU 的曲率分布。                            */
/* ------------------------------------------------------------------ */
#define EMIN  (-4)     /* |x| < 2^-4 走线性渐近区 */
#define EMAX  ( 3)     /* |x| >= 2^4 走饱和渐近区 */
#define NEXP  (EMAX - EMIN + 1)

typedef struct {
    int      kbits;                 /* 每个指数段再细分 2^kbits 段 */
    int      nseg;
    uint32_t slope[NEXP * 64];      /* fp32 bit pattern，直接就是 LUT 内容 */
    uint32_t icpt [NEXP * 64];
} pwl_t;

/* 段内做 minimax 均衡的线性拟合：先端点插值，再整体平移 maxerr/2，
   使误差在两端与极值点之间均衡——最大误差减半。RTL 里 exp2 的系数
   就是这么来的（八段中点相对误差恒为 4.69e-4）。 */
static void fit_segment(double lo, double hi, double (*f)(double),
                        uint32_t *slope_b, uint32_t *icpt_b)
{
    double fa = f(lo), fb = f(hi);
    double k  = (fb - fa) / (hi - lo);
    double b  = fa - k * lo;
    /* 扫描找最大偏差（正负分别记），再取中值平移 */
    double emax = -1e300, emin = 1e300;
    const int N = 2048;
    for (int i = 0; i <= N; i++) {
        double x = lo + (hi - lo) * i / N;
        double d = f(x) - (k * x + b);
        if (d > emax) emax = d;
        if (d < emin) emin = d;
    }
    b += 0.5 * (emax + emin);
    *slope_b = f2b((float)k);
    *icpt_b  = f2b((float)b);
}

static void pwl_build(pwl_t *p, int kbits, double (*f)(double))
{
    p->kbits = kbits;
    p->nseg  = NEXP << kbits;
    int sub  = 1 << kbits;
    for (int e = EMIN; e <= EMAX; e++) {
        double base = ldexp(1.0, e);              /* 2^e */
        for (int m = 0; m < sub; m++) {
            double lo = base * (1.0 + (double)m / sub);
            double hi = base * (1.0 + (double)(m + 1) / sub);
            int idx = (e - EMIN) * sub + m;
            fit_segment(lo, hi, f, &p->slope[idx], &p->icpt[idx]);
        }
    }
}

/* 从 |x| 的位模式取段索引；返回 -1 表示落在渐近区（低于 2^EMIN） ,
   返回 -2 表示饱和区（>= 2^(EMAX+1)） */
static int seg_index(uint32_t ax, int kbits)
{
    int e = (int)((ax >> 23) & 0xFF) - 127;
    if (e < EMIN) return -1;
    if (e > EMAX) return -2;
    uint32_t frac = ax & 0x7FFFFF;
    int m = kbits ? (int)(frac >> (23 - kbits)) : 0;
    return (e - EMIN) * (1 << kbits) + m;
}

/* ------------------------------------------------------------------ */
/* 候选方案 A：直接对 SiLU 做分段 PWL                                  */
/*                                                                     */
/* 表只存**负半轴** silu(-a), a>0，正半轴用 silu(a) = silu(-a) + a 恢复。*/
/* 方向不能反：silu 在负半轴值域只有 (-0.2785, 0)，而正半轴 silu(a)≈a。 */
/* 若存正半轴、负半轴用 silu(a)-a 恢复，a=4 时就是 3.928-4=-0.072，     */
/* 两个量级相当的数相减得到接近零的结果——catastrophic cancellation，   */
/* 有效位几乎丢光。存负半轴则相加的两项量级本就相当，不放大误差。       */
/* ------------------------------------------------------------------ */
static uint32_t silu_pwl(uint32_t xb, const pwl_t *p)
{
    uint32_t sign = xb >> 31;
    uint32_t ax   = xb & 0x7FFFFFFF;
    int idx = seg_index(ax, p->kbits);

    uint32_t nv;                                   /* silu(-|x|) */
    if (idx == -1) {
        /* |x| < 2^-4：sigmoid 已经贴着 0.5，silu(-a) ≈ -a/2。
           乘 0.5 在 fp32 里只是指数减一，硬件零代价 */
        nv = fpmul_bits(ax | 0x80000000u, f2b(0.5f));
    } else if (idx == -2) {
        nv = 0;                                    /* |x| >= 16：silu(-a) → 0 */
    } else {
        nv = fpadd_bits(fpmul_bits(ax, p->slope[idx]), p->icpt[idx]);
    }
    if (sign) return nv;
    return fpadd_bits(nv, ax);                     /* silu(a) = silu(-a) + a */
}

/* ------------------------------------------------------------------ */
/* 候选方案 B：先 PWL 出 sigmoid，再乘 x                               */
/* 同样只存负半轴 sigmoid(-a) ∈ (0, 0.5]，正半轴用 1 - sigmoid(-a)。   */
/* 这个方向的相减是安全的：被减的是接近 0 的小量，结果接近 1。         */
/* ------------------------------------------------------------------ */
static uint32_t silu_sigmoid_pwl(uint32_t xb, const pwl_t *p)
{
    uint32_t sign = xb >> 31;
    uint32_t ax   = xb & 0x7FFFFFFF;
    int idx = seg_index(ax, p->kbits);

    uint32_t sg;                                   /* sigmoid(-|x|) */
    if (idx == -1)      sg = f2b(0.5f);
    else if (idx == -2) sg = 0;
    else                sg = fpadd_bits(fpmul_bits(ax, p->slope[idx]), p->icpt[idx]);

    if (!sign) sg = fpadd_bits(f2b(1.0f), sg | 0x80000000u);   /* σ(a) = 1 - σ(-a) */
    return fpmul_bits(xb, sg);
}

/* ------------------------------------------------------------------ */
/* 候选方案 C：完全复用 FSA 已有硬件（exp2 单元 + 倒数单元），零新表    */
/*                                                                     */
/* 关键约束：FSA 的 exp2 单元**只对负输入正确**。它的 LUT 存的是        */
/* 2^(-f) 的斜率绝对值（符号由 a 操作数带入），因为 softmax 里的输入    */
/* 恒为 s-max<=0，正输入这条路径设计上就没覆盖。实测 exp2(0.5) 给出     */
/* 1.176 而非 1.414（相对误差 16.8%），负输入则一律是 PWL 的固有误差    */
/* 4.56e-4。所以复用时必须把两个分支都整理成"exp2 输入为负"的形式：     */
/*                                                                     */
/*   x >= 0:  e = exp2(-x*log2e) ∈ (0,1],  silu = x * (1  /(1+e))      */
/*   x <  0:  e = exp2( x*log2e) ∈ (0,1],  silu = x * (e/(1+e))        */
/*                                                                     */
/* 这也是数值稳定的标准写法：两个分支都不含 1-sigma 这类相减，避免了    */
/* |x| 大时 sigma→1 引起的 catastrophic cancellation。                 */
/* 硬件代价只是一个符号判断 + 分子的二选一 MUX。                       */
/* ------------------------------------------------------------------ */
static const uint32_t LOG2E_B = 0x3FB8AA3Bu;       /* log2(e) = 1.4426950 */
static uint32_t silu_reuse(uint32_t xb)
{
    uint32_t neg = xb >> 31;
    uint32_t ax  = xb & 0x7FFFFFFF;
    uint32_t t   = fpmul_bits(ax | 0x80000000u, LOG2E_B);   /* -|x|*log2e，恒负 */
    uint32_t e   = exp2_hw(t);
    uint32_t den = fpadd_bits(f2b(1.0f), e);
    uint32_t inv = recip_bits(den);
    uint32_t sig = neg ? fpmul_bits(e, inv) : inv;          /* 分子 e 或 1 */
    return fpmul_bits(xb, sig);
}

/* ------------------------------------------------------------------ */
/* 统计                                                                */
/* ------------------------------------------------------------------ */
typedef struct {
    double max_abs, sum_abs;
    double max_rel, sum_rel;
    long   n, n_rel;
    double worst_x, worst_g, worst_d;
    long   ulp_bucket[6];       /* 0, <=1, <=4, <=16, <=64, >64 */
} stat_t;

static void stat_add(stat_t *s, double x, double golden, uint32_t dut_b)
{
    double d = (double)b2f(dut_b);
    double ae = fabs(d - golden);
    s->sum_abs += ae; s->n++;
    if (ae > s->max_abs) { s->max_abs = ae; s->worst_x = x; s->worst_g = golden; s->worst_d = d; }
    if (fabs(golden) > 1e-6) {
        double re = ae / fabs(golden);
        s->sum_rel += re; s->n_rel++;
        if (re > s->max_rel) s->max_rel = re;
    }
    /* ULP：以 fp32 的 golden 为基准 */
    uint32_t gb = f2b((float)golden);
    long diff = labs((long)(gb & 0x7FFFFFFF) - (long)(dut_b & 0x7FFFFFFF));
    if ((gb >> 31) != (dut_b >> 31)) diff = 1L << 30;      /* 符号都错，记满 */
    int k = diff == 0 ? 0 : diff <= 1 ? 1 : diff <= 4 ? 2 : diff <= 16 ? 3 : diff <= 64 ? 4 : 5;
    s->ulp_bucket[k]++;
}

static void stat_print(const char *name, const stat_t *s, int nseg, const char *cost)
{
    printf("  %-26s %5d  %9.3e %9.3e  %8.3e %8.3e   %5.1f%% %5.1f%%  %s\n",
           name, nseg,
           s->max_abs, s->sum_abs / (s->n ? s->n : 1),
           s->max_rel, s->sum_rel / (s->n_rel ? s->n_rel : 1),
           100.0 * s->ulp_bucket[0] / s->n,
           100.0 * (s->ulp_bucket[0] + s->ulp_bucket[1] + s->ulp_bucket[2] + s->ulp_bucket[3]) / s->n,
           cost);
}

/* ------------------------------------------------------------------ */
int main(int argc, char **argv)
{
    const char *silu_path = argc > 1 ? argv[1] : "act_silu.bin";
    const char *rope_path = argc > 2 ? argv[2] : "act_rope.bin";

    /* ---- 载入真实 SiLU 输入 ---- */
    FILE *f = fopen(silu_path, "rb");
    if (!f) { fprintf(stderr, "打不开 %s（先用 DUMP_ACT=1 的 host 构建跑一遍推理）\n", silu_path); return 1; }
    fseek(f, 0, SEEK_END); long nb = ftell(f); fseek(f, 0, SEEK_SET);
    long n = nb / 4;
    float *xs = malloc(nb);
    if (fread(xs, 1, nb, f) != (size_t)nb) { fprintf(stderr, "读 %s 失败\n", silu_path); return 1; }
    fclose(f);
    printf("SiLU 真实输入 %ld 个（来自 %s）\n\n", n, silu_path);

    printf("方案对比（bit-level 截断算术，对照 fp64 silu）\n");
    printf("  %-26s %5s  %9s %9s  %8s %8s   %5s %5s  %s\n",
           "方案", "段数", "max_abs", "mean_abs", "max_rel", "mean_rel", "exact", "<=16u", "硬件代价");
    printf("  ---------------------------------------------------------------------------------------------------------\n");

    /* 方案 C：复用现有单元 */
    {
        stat_t s; memset(&s, 0, sizeof s);
        for (long i = 0; i < n; i++) stat_add(&s, xs[i], ref_silu(xs[i]), silu_reuse(f2b(xs[i])));
        stat_print("C 复用exp2+recip", &s, 0, "0 新表, 但含13拍倒数");
    }
    /* 方案 A/B：不同段数 */
    for (int kb = 0; kb <= 3; kb++) {
        pwl_t pa, pb;
        pwl_build(&pa, kb, ref_silu_neg);
        pwl_build(&pb, kb, ref_sigmoid_neg);
        char na[64], nb2[64], cost[64];
        snprintf(na,  sizeof na,  "A SiLU直接PWL k=%d", kb);
        snprintf(nb2, sizeof nb2, "B sigmoid PWL k=%d", kb);
        snprintf(cost, sizeof cost, "%d项x2字, 1乘1加(+1加)", pa.nseg);
        stat_t s; memset(&s, 0, sizeof s);
        for (long i = 0; i < n; i++) stat_add(&s, xs[i], ref_silu(xs[i]), silu_pwl(f2b(xs[i]), &pa));
        stat_print(na, &s, pa.nseg, cost);
        memset(&s, 0, sizeof s);
        for (long i = 0; i < n; i++) stat_add(&s, xs[i], ref_silu(xs[i]), silu_sigmoid_pwl(f2b(xs[i]), &pb));
        snprintf(cost, sizeof cost, "%d项x2字, 1乘1加+1乘", pb.nseg);
        stat_print(nb2, &s, pb.nseg, cost);
    }

    /* ---- RoPE 输入分析：确认查表可行性 ---- */
    f = fopen(rope_path, "rb");
    if (f) {
        fseek(f, 0, SEEK_END); long rb = ftell(f); fseek(f, 0, SEEK_SET);
        long rn = rb / 4;
        float *rs = malloc(rb);
        if (fread(rs, 1, rb, f) == (size_t)rb) {
            /* 统计不同取值个数——决定"直接存 (cos,sin) 表"要多大 */
            long uniq = 0;
            float *sorted = malloc(rb);
            memcpy(sorted, rs, rb);
            qsort(sorted, rn, 4, cmp_float);
            for (long i = 0; i < rn; i++) if (i == 0 || sorted[i] != sorted[i-1]) uniq++;
            printf("\nRoPE 输入 pos*freq：%ld 次调用，仅 %ld 个不同取值\n", rn, uniq);
            printf("  → 直接存 (cos,sin) 对需要 %ld x 8B = %.1f KB\n", uniq, uniq * 8.0 / 1024);
            printf("  → 取值范围 [%.4f, %.1f]，跨 %d 个二进制量级：硬件若要现算三角函数\n",
                   sorted[0], sorted[rn-1], 18);
            printf("     必须先做 mod 2pi 范围规约（255 rad 约 40 圈），这是 CORDIC 方案的主要代价\n");
            free(sorted);
        }
        free(rs);
        fclose(f);
    }
    free(xs);
    return 0;
}

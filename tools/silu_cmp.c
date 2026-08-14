/*
 * silu_cmp.c —— tb_silu_unit 抓的真实硬件输出的双重对照
 *
 * 用法： gcc -O2 -o silu_cmp tools/silu_cmp.c -lm && ./silu_cmp silu_hw_results.txt
 *
 * 两层对照，回答两个不同的问题：
 *
 *   1) 对位级模型 silu_bits()  —— 回答"RTL 实现得对不对"
 *      判据：必须 100% bit-exact。位级模型的每个原语(exp2_hw/recip_bits/
 *      fpmul_bits/fpadd_bits)都已分别对真实硬件数据验证过逐位一致，所以只要
 *      微序列编排正确，两者就该完全相同。任何不一致都是实现问题(时序错位、
 *      操作数选错、捕获时机不对)，与精度无关。
 *
 *   2) 对 fp64 精确 golden   —— 回答"数值够不够准"
 *      这里必然有误差，来源是硬件既有的 8 段 PWL exp2(固有相对误差 4.69e-4)。
 *      判据不是"误差为零"，而是误差量级不超过 PWL 本身——若显著更大，说明
 *      微程序把误差放大了。
 *
 * 两层缺一不可：只比位级模型，无法发现"模型和 RTL 一起错"；只比 fp64，
 * 无法区分"实现 bug"和"近似误差"。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>

#include "../tb/dpi/fp_bitlevel.h"

static float b2f(uint32_t b) { float f; memcpy(&f, &b, 4); return f; }

/* fp64 精确参考 */
static double silu_ref(double x) { return x / (1.0 + exp(-x)); }

typedef struct {
    const char *name;
    long   n;
    double sum_rel;
    double max_rel;
    double max_rel_x;
} bucket_t;

static void bk_add(bucket_t *b, double x, double hw, double ref)
{
    /* ref 趋零时改用相对 |x| 的误差：silu(x)→0 时绝对误差才是有意义的量，
       否则小分母会把无害的末位差异放大成假信号 */
    double den = fabs(ref) > 1e-6 ? fabs(ref)
               : (fabs(x) > 1e-6 ? fabs(x) : 1.0);
    double rel = fabs(hw - ref) / den;
    b->n++;
    b->sum_rel += rel;
    if (rel > b->max_rel) { b->max_rel = rel; b->max_rel_x = x; }
}

static void bk_print(const bucket_t *b)
{
    if (!b->n) return;
    printf("    %-22s n=%-5ld mean_rel=%.3e  max_rel=%.3e @ x=%.6g\n",
           b->name, b->n, b->sum_rel / (double)b->n, b->max_rel, b->max_rel_x);
}

int main(int argc, char **argv)
{
    const char *path = (argc > 1) ? argv[1] : "silu_hw_results.txt";
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return 2; }

    long total = 0, exact = 0, shown = 0, first_bad = -1;
    bucket_t all  = {"TOTAL",0,0,0,0};
    bucket_t pos  = {"x>=0",0,0,0,0};
    bucket_t neg  = {"x<0",0,0,0,0};
    bucket_t sat  = {"|x|>=177 (饱和)",0,0,0,0};
    unsigned int xin, hw;
    long line = 0;

    printf("=== tb_silu_unit 双重对照 ===\n");
    printf("\n[1] 对位级模型 silu_bits()——判据 100%% bit-exact\n\n");

    while (fscanf(f, "%x %x", &xin, &hw) == 2) {
        line++;
        uint32_t model = silu_bits((uint32_t)xin);
        total++;
        if (model == (uint32_t)hw) exact++;
        else {
            if (first_bad < 0) first_bad = line;
            if (shown < 12) {
                printf("    MISMATCH line %-4ld x=%-13.6g hw=%08x  model=%08x\n",
                       line, (double)b2f((uint32_t)xin), hw, model);
                shown++;
            }
        }

        /* 第二层：对 fp64 精确 golden */
        double x   = (double)b2f((uint32_t)xin);
        double hwd = (double)b2f((uint32_t)hw);
        double ref = silu_ref(x);
        bk_add(&all, x, hwd, ref);
        if (fabs(x) >= 177.0)  bk_add(&sat, x, hwd, ref);
        else if (x < 0.0)      bk_add(&neg, x, hwd, ref);
        else                   bk_add(&pos, x, hwd, ref);
    }
    fclose(f);

    printf("\n    bit-exact: %ld/%ld (%.2f%%)  %s\n", exact, total,
           total ? 100.0 * (double)exact / (double)total : 0.0,
           exact == total ? "=> RTL 与位级模型完全一致" : "=> 存在实现差异");
    if (exact != total)
        printf("    首个不一致在第 %ld 行\n", first_bad);

    printf("\n[2] 对 fp64 精确 golden——判据：误差量级不超过 exp2 PWL 固有的 4.69e-4\n\n");
    bk_print(&all);
    bk_print(&pos);
    bk_print(&neg);
    bk_print(&sat);

    double mean = all.n ? all.sum_rel / (double)all.n : 0.0;
    printf("\n    PWL 固有相对误差 = 4.69e-04（八段中点，由 RTL 系数决定）\n");
    printf("    实测 mean_rel = %.3e  max_rel = %.3e\n", mean, all.max_rel);
    printf("    %s\n", all.max_rel <= 1.2e-3
           ? "=> 误差与 PWL 同量级，微程序未放大误差"
           : "=> 误差显著超过 PWL 固有值，需检查微程序");

    return (exact == total) ? 0 : 1;
}

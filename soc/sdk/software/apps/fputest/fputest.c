/*
 * CPU 硬件 FPU（cvfpu）板上自检
 *
 * 为什么要有这个：整机隔离实验已经把故障钉在 CPU 的硬件 FPU 上
 *   MODE=cpu   (软浮点, 无加速器)  三次逐字正确
 *   MODE=hw    (软浮点, 加速器全程工作) 三次逐字正确
 *   MODE=hw_fpu(硬件 FPU)          三次全错且各不相同
 * 但"LLM 输出乱了"是个很钝的判据——错误率多少、错在哪个运算、是否可复现，
 * 全都看不出来。这个程序把它换成确定性判据：逐位比对 golden。
 *
 * golden 表由主机上的 numpy.float32 生成（scratchpad/gen_fpu_vectors.py）。
 * IEEE754 要求 + - * / sqrt 全部正确舍入，所以只要板上每一步也严格是单精度，
 * 两边必须**逐位相同**——不存在"精度差异"这种解释空间，任何一位不同都是硬件错。
 *
 * 关键实现约束：每一步都经 volatile float 落地，防止编译器把中间结果留在更宽的
 * 寄存器里或做常量折叠（折叠掉就变成在测编译器而不是测 FPU）。
 */
#include <stdio.h>
#include <stdint.h>
#include "common_func.h"
#include "fpu_vectors.h"

unsigned long UART_BASE = 0xbf000000;

/* trap_handler.S 无条件引用它。本测试不用加速器中断，空实现即可。 */
void HWI1_IntrHandler(void) {}

static inline float u2f(uint32_t u)
{
    union { uint32_t u; float f; } c;
    c.u = u;
    return c.f;
}

static inline uint32_t f2u(float f)
{
    union { uint32_t u; float f; } c;
    c.f = f;
    return c.u;
}

/* NaN 的位模式在不同实现间可以合法地不同（payload/quiet 位），
 * 所以两边都是 NaN 时不算错。除此之外一律逐位比。 */
static inline int is_nan(uint32_t u)
{
    return ((u & 0x7F800000U) == 0x7F800000U) && (u & 0x007FFFFFU);
}

static int cmp(const char *op, int idx, uint32_t got, uint32_t exp,
               int *shown)
{
    if (got == exp) return 0;
    if (is_nan(got) && is_nan(exp)) return 0;
    if (*shown < 6) {
        printf("  [%s] vec=%d exp=%08x got=%08x xor=%08x\n",
               op, idx, exp, got, exp ^ got);
        (*shown)++;
    }
    return 1;
}

/* ---------------- 段二：流水线压力段 ----------------
 * 段一每步之间都有 volatile，每条 FP 指令都要等上一条写回，**FPU 流水线全程是空的**。
 * 真实负载（matmul 的 sum += w[i]*x[i]）是背靠背连续发射的，如果 bug 在流水线控制、
 * 记分板或 epoch tag 过滤上，段一永远撞不上——v1 板上 6.4 万次运算零错误就是这么来的。
 *
 * 这一段照 matmul 的形状写：从内存 fld.s 取数（段一是整数加载再位转换，走不到浮点访存）、
 * 4 个互相独立的累加器让发射不被数据相关卡住、显式 __builtin_fmaf 保证是融合乘加。 */
static float stream_buf[FPU_SN];

static int run_stream(uint32_t out[FPU_ACC])
{
    float acc[FPU_ACC];
    float coef[FPU_ACC];
    for (int k = 0; k < FPU_ACC; k++) {
        acc[k]  = 0.0f;
        coef[k] = u2f(fpu_stream_coef[k]);
    }
    for (int i = 0; i < FPU_SN; i += FPU_ACC) {
        /* 四路互不相关，可以同时在流水线里 */
        acc[0] = __builtin_fmaf(stream_buf[i + 0], coef[0], acc[0]);
        acc[1] = __builtin_fmaf(stream_buf[i + 1], coef[1], acc[1]);
        acc[2] = __builtin_fmaf(stream_buf[i + 2], coef[2], acc[2]);
        acc[3] = __builtin_fmaf(stream_buf[i + 3], coef[3], acc[3]);
    }
    int bad = 0;
    for (int k = 0; k < FPU_ACC; k++) {
        out[k] = f2u(acc[k]);
        if (out[k] != fpu_stream_gold[k]) bad++;
    }
    return bad;
}

#define ROUNDS 200

int main(void)
{
    printf("[FPUTEST] start nvec=%d sn=%d rounds=%d\n",
           FPU_NVEC, FPU_SN, ROUNDS);

    for (int i = 0; i < FPU_SN; i++)
        stream_buf[i] = u2f(fpu_stream_src[i]);

    long e_add = 0, e_sub = 0, e_mul = 0, e_div = 0, e_sqrt = 0, e_fma = 0;
    int s_add = 0, s_sub = 0, s_mul = 0, s_div = 0, s_sqrt = 0, s_fma = 0;
    long e_str = 0;
    int s_str = 0;

    for (int r = 0; r < ROUNDS; r++) {
        for (int i = 0; i < FPU_NVEC; i++) {
            volatile float a = u2f(fpu_vec[i].a);
            volatile float b = u2f(fpu_vec[i].b);
            volatile float c = u2f(fpu_vec[i].c);

            volatile float t;
            t = a + b;   e_add  += cmp("ADD",  i, f2u(t), fpu_vec[i].add,  &s_add);
            t = a - b;   e_sub  += cmp("SUB",  i, f2u(t), fpu_vec[i].sub,  &s_sub);
            t = a * b;   e_mul  += cmp("MUL",  i, f2u(t), fpu_vec[i].mul,  &s_mul);
            t = a / b;   e_div  += cmp("DIV",  i, f2u(t), fpu_vec[i].div_, &s_div);

            /* sqrt 的输入取 |a|，与生成脚本一致 */
            volatile float aa = (a < 0.0f) ? -a : a;
            t = __builtin_sqrtf(aa);
            e_sqrt += cmp("SQRT", i, f2u(t), fpu_vec[i].sqrt_, &s_sqrt);

            t = __builtin_fmaf(a, b, c);
            e_fma += cmp("FMA", i, f2u(t), fpu_vec[i].fma, &s_fma);
        }

        uint32_t got[FPU_ACC];
        int bad = run_stream(got);
        if (bad) {
            e_str += bad;
            if (s_str < 6) {
                printf("  [STREAM] round=%d bad=%d "
                       "got=%08x,%08x,%08x,%08x exp=%08x,%08x,%08x,%08x\n",
                       r, bad, got[0], got[1], got[2], got[3],
                       fpu_stream_gold[0], fpu_stream_gold[1],
                       fpu_stream_gold[2], fpu_stream_gold[3]);
                s_str++;
            }
        }

        if ((r % 50) == 0)
            printf("[FPUTEST] round %d (cum add=%ld sub=%ld mul=%ld div=%ld "
                   "sqrt=%ld fma=%ld stream=%ld)\n",
                   r, e_add, e_sub, e_mul, e_div, e_sqrt, e_fma, e_str);
    }

    long total = e_add + e_sub + e_mul + e_div + e_sqrt + e_fma + e_str;
    long ops = (long)ROUNDS * FPU_NVEC;
    printf("[FPUTEST] done ops_per_kind=%ld stream_rounds=%d total_errs=%ld "
           "(add=%ld sub=%ld mul=%ld div=%ld sqrt=%ld fma=%ld stream=%ld)\n",
           ops, ROUNDS, total,
           e_add, e_sub, e_mul, e_div, e_sqrt, e_fma, e_str);
    return 0;
}

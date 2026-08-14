/*
 * bench_profile —— 时间拆解累加器与报告输出（实现）
 *
 * 见 include/bench_profile.h 的模块说明。本文件在 BENCH_PROFILE=0 时不产生
 * 任何代码和数据，因此可以无条件加入 bsp 源码列表，不影响正式构建体积。
 */

#include "bench_profile.h"

/* 关闭时保持翻译单元非空，避免 ISO C 的"空翻译单元"告警 */
typedef int bp_translation_unit_not_empty_t;

#if BENCH_PROFILE

#include <stdio.h>

unsigned long long bp_cycles[BP_SLOT_NUM];
unsigned long long bp_hits[BP_SLOT_NUM];
unsigned long long bp_gemv_macs;
unsigned long long bp_gemv_bytes;
unsigned long long bp_gemv_calls;

/* 计时自身开销（一对MARK + 一次累加）。细粒度槽位调用次数极大
   （本模型下 ROPE_TRIG 要执行4万次以上），实测值里含 hits×ovh 的虚高，
   报告用它给出扣除后的净值，避免把探针开销当成算子开销去优化 */
static unsigned long long bp_probe_ovh;

/* 现场标定探针开销：用与BP_ACC完全相同的操作序列跑1024轮取平均。
   循环控制本身也被计入，因此结果是偏保守的上界估计 */
static unsigned long long bp_calibrate(unsigned long long *sink)
{
    unsigned long long acc = 0ull;
    unsigned long c0, c1;
    int i;

    c0 = bp_rdcnt();
    for (i = 0; i < 1024; i++) {
        unsigned long a = bp_rdcnt();
        unsigned long b = bp_rdcnt();
        acc += (unsigned long long)(b - a);
    }
    c1 = bp_rdcnt();

    *sink = acc;   /* 把累加结果传出去打印，防止整个循环被优化掉 */
    return (unsigned long long)(c1 - c0) / 1024ull;
}

/* 打印一个槽位。百分比用整数运算（放大1e4后拆成整数/小数两段打印），
   避免在软浮点构建里为了打印百分比把浮点printf链接进来。
   net = 实测值扣除探针开销后的估计值。

   sub 指定该槽位的子槽位（没有则传 BP_SLOT_NUM）：子槽位的探针是在父区间
   内部执行的，它那部分开销同样被计进了父槽位的实测值，所以父槽位扣净值时
   必须连子槽位的 hits 一起扣。这在本模型下不是小数：FFN_EXP 要执行22万次，
   若只扣 FFN_ACT 自己的1280次，会把两位数百万的探针开销误算成激活函数耗时 */
static void bp_line_sub(const char *name, bp_slot_t slot, bp_slot_t sub,
                        unsigned long long base)
{
    unsigned long long v    = bp_cycles[slot];
    unsigned long long hits = bp_hits[slot];
    unsigned long long cost, net, pct;

    if (sub < BP_SLOT_NUM)
        hits += bp_hits[sub];

    cost = hits * bp_probe_ovh;
    net  = (v > cost) ? (v - cost) : 0ull;
    pct  = base ? (net * 10000ull) / base : 0ull;

    printf("[BENCH]  %-11s %12llu  n=%-9llu net=%12llu (%3llu.%02llu%%)\n",
           name, v, bp_hits[slot], net, pct / 100ull, pct % 100ull);
}

/* 无子槽位的普通槽位 */
static void bp_line(const char *name, bp_slot_t slot, unsigned long long base)
{
    bp_line_sub(name, slot, BP_SLOT_NUM, base);
}

/* other 没有槽位，单独一行（无探针开销可扣） */
static void bp_line_raw(const char *name, unsigned long long v, unsigned long long base)
{
    unsigned long long pct = base ? (v * 10000ull) / base : 0ull;
    printf("[BENCH]  %-11s %12llu  %-11s %12llu (%3llu.%02llu%%)\n",
           name, v, "", v, pct / 100ull, pct % 100ull);
}

void bp_report(unsigned long long total_cycles, int tokens)
{
    unsigned long long sum = 0ull, probe_total = 0ull;
    unsigned long long other, dma_min, comp_min, hw, sink = 0ull;
    int i;

    bp_probe_ovh = bp_calibrate(&sink);

    /* 只对顶层槽位求和：子槽位是父槽位的内部细分，计入会导致 other 被重复扣除 */
    for (i = 0; i < BP_SLOT_TOP_NUM; i++)
        sum += bp_cycles[i];

    /* 探针总开销要把子槽位也算上：它虽然不单独占时间片（已含在父槽位里），
       但确实真实执行了，用于评估这次测量整体被污染了多少 */
    for (i = 0; i < BP_SLOT_NUM; i++)
        probe_total += bp_hits[i] * bp_probe_ovh;

    /* 未被任何顶层槽位覆盖的部分 = 尚未细分的CPU开销（循环控制/地址计算/
       memcpy embedding 等碎片）。计时本身有开销，sum可能略大于total，
       此时截为0而不是回绕成巨大值 */
    other = (total_cycles > sum) ? (total_cycles - sum) : 0ull;

    printf("\n[BENCH] ================ 时间拆解 ================\n");
    printf("[BENCH]  total=%llu cycles, tokens=%d, per_token=%llu\n",
           total_cycles, tokens,
           tokens > 0 ? total_cycles / (unsigned long long)tokens : 0ull);
    printf("[BENCH]  probe_ovh=%llu cycles/次, 顶层槽位探针总开销=%llu (%llu.%02llu%%), sink=%llu\n",
           bp_probe_ovh, probe_total,
           total_cycles ? (probe_total * 10000ull / total_cycles) / 100ull : 0ull,
           total_cycles ? (probe_total * 10000ull / total_cycles) % 100ull : 0ull,
           sink);

    printf("[BENCH] ---- 硬件段（占比按net算） ----\n");
    bp_line("GEMV.csr",   BP_GEMV_CSR,   total_cycles);
    bp_line("GEMV.flush", BP_GEMV_FLUSH, total_cycles);
    bp_line("GEMV.hw",    BP_GEMV_HW,    total_cycles);
    bp_line("GEMV.post",  BP_GEMV_POST,  total_cycles);
    bp_line("ATTN.csr",   BP_ATTN_CSR,   total_cycles);
    bp_line("ATTN.hw",    BP_ATTN_HW,    total_cycles);

    printf("[BENCH] ---- CPU算子段 ----\n");
    bp_line_sub("ROPE",    BP_ROPE,    BP_ROPE_TRIG, total_cycles);
    bp_line_sub("FFN.act", BP_FFN_ACT, BP_FFN_EXP,   total_cycles);
    bp_line("RMSNORM",    BP_RMSNORM,    total_cycles);
    bp_line("RESIDUAL",   BP_RESIDUAL,   total_cycles);
    bp_line("KVSTORE",    BP_KVSTORE,    total_cycles);
    bp_line("SAMPLE",     BP_SAMPLE,     total_cycles);
    bp_line("IO(uart)",   BP_IO,         total_cycles);
    bp_line_raw("other",  other,         total_cycles);

    /* 子槽位：父槽位内部的细分，与父槽位重复计时，只用于判断优化空间 */
    printf("[BENCH] ---- 子项（含在上面的父项内，不重复计入总和） ----\n");
    bp_line("  ROPE.trig", BP_ROPE_TRIG, total_cycles);
    bp_line("  FFN.exp",   BP_FFN_EXP,   total_cycles);
    printf("[BENCH]  note: ROPE.trig=powf/cosf/sinf，预计算查表可全部消除;\n");
    printf("[BENCH]        FFN.exp =expf，可用FSA同款exp2分段PWL近似替代\n");

    /* 硬件段效率：把实测的"等硬件"时间与两条理论下限对比，
       判断硬件到底卡在搬数据还是算数据——这是选优化方向的关键依据。
       dma_min/comp_min是在sys_clk域算的(DMA/PE阵列的真实时钟)，而hw是
       bp_rdcnt()量出的cpu_clk周期，两者时钟域不同不能直接比，
       必须先把sys_clk下限换算成cpu_clk等效周期 */
    hw       = bp_cycles[BP_GEMV_HW] - bp_hits[BP_GEMV_HW] * bp_probe_ovh;
    dma_min  = bp_gemv_bytes / (unsigned long long)BP_AXI_BYTES_PER_CYCLE;
    comp_min = bp_gemv_macs  / (unsigned long long)BP_PE_NUM;
    /* sys_clk cycles -> cpu_clk等效cycles: 乘以 CPU_MHZ/SYS_MHZ */
    dma_min  = (dma_min  * (unsigned long long)BP_CPU_CLK_MHZ) / (unsigned long long)BP_SYS_CLK_MHZ;
    comp_min = (comp_min * (unsigned long long)BP_CPU_CLK_MHZ) / (unsigned long long)BP_SYS_CLK_MHZ;

    printf("[BENCH] ---- GEMV硬件段效率 (calls=%llu, macs=%llu) ----\n",
           bp_gemv_calls, bp_gemv_macs);
    printf("[BENCH]  (下限已按 sys_clk=%dMHz -> cpu_clk=%dMHz 换算为等效周期)\n",
           BP_SYS_CLK_MHZ, BP_CPU_CLK_MHZ);
    printf("[BENCH]  hw_measured(net) %12llu\n", hw);
    printf("[BENCH]  dma_lower        %12llu  (%3llu.%02llu%%)\n", dma_min,
           hw ? (dma_min * 10000ull / hw) / 100ull : 0ull,
           hw ? (dma_min * 10000ull / hw) % 100ull : 0ull);
    printf("[BENCH]  comp_lower       %12llu  (%3llu.%02llu%%)\n", comp_min,
           hw ? (comp_min * 10000ull / hw) / 100ull : 0ull,
           hw ? (comp_min * 10000ull / hw) % 100ull : 0ull);
    printf("[BENCH]  note: dma_lower占比接近100%% => 被AXI带宽卡死(应加宽AXI/降精度);\n");
    printf("[BENCH]        comp_lower占比很低    => PE大量空闲(加PE/改数据流无收益)\n");
    printf("[BENCH] ==========================================\n");
}

#endif /* BENCH_PROFILE */

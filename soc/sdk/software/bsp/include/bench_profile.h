#ifndef BENCH_PROFILE_H
#define BENCH_PROFILE_H

/*
 * bench_profile —— LLM推理端到端时间拆解基础设施（bsp共用）
 *
 * 解决的问题：
 *   端到端只知道"每token多少周期"，无法判断该优化谁。本模块把一次推理拆成
 *   若干可归因的时间段（CPU配寄存器 / cache flush / 等硬件 / 纯CPU算子），
 *   并在报告里同时给出硬件段的理论下限，直接回答"硬件是被DMA带宽卡住还是
 *   被PE算力卡住"——这是决定后续优化方向（加宽AXI？加PE？改数据流？）的依据。
 *
 * 用法：
 *   1) 在被测区间两端各放一个 BP_MARK，再用 BP_ACC 把差值累加到对应槽位
 *   2) GEMV调用处用 BP_ADD_GEMV_SCALE 累加规模，供理论下限计算
 *   3) 推理结束后调用 bp_report() 打印拆解结果
 *
 * 开关：编译时 -DBENCH_PROFILE=1 开启（Makefile 的 BENCH=1）。关闭时所有宏
 *   展开为空、本模块不产生任何代码和数据，对正式构建零开销。
 *
 * 注意：计时本身有开销（每个MARK读一次计数器），分项之和会略大于真实值，
 *   因此结论应看"占比"而非绝对值。
 */

/* 计数器由本文件的 bp_rdcnt() 内联汇编直接读取，不依赖 confreg_time.h */

#ifndef BENCH_PROFILE
#define BENCH_PROFILE 0
#endif

#if BENCH_PROFILE

/* ---- 硬件规格常量：算理论下限用，改硬件时同步改这里 ---- */
#define BP_PE_NUM               32  /* PE阵列规模，每周期最多完成的MAC数 */
#define BP_AXI_BYTES_PER_CYCLE   4  /* AXI位宽DATA_WD=32bit，每周期搬4字节(sys_clk域) */

/* ---- 跨时钟域换算：rdcntvl.w数的是cpu_clk周期，但DMA/PE阵列
   跑在sys_clk域(soc_top.v: CB_top_v2挂sys_clk，CPU挂cpu_clk，中间有CDC桥，
   worklog记录过"CB_done跨时钟域漏同步")。dma_lower/comp_lower是在sys_clk
   周期下算的理论下限，必须换算成cpu_clk等效周期才能与hw_measured比较，
   否则会出现"理论下限>实测值"这种物理不可能的结果。
   当前值取自 rtl/ip/PLL_2019_2/clk_pll.xci 的 main 分支配置(CLKOUT1=33MHz
   即cpu_clk，CLKOUT2=50MHz即sys_clk)。若切到其他PLL配置(如实验分支
   feat/pll-44mhz-clk)，需同步改这两个值或改用 -D 覆盖 ---- */
#ifndef BP_CPU_CLK_MHZ
#define BP_CPU_CLK_MHZ 33
#endif
#ifndef BP_SYS_CLK_MHZ
#define BP_SYS_CLK_MHZ 50
#endif

/* 计时槽位。
 *
 * 分两类：
 *   顶层槽位（BP_SLOT_TOP_NUM 之前）互不重叠，共同瓜分 total_cycles，
 *     未被任何顶层槽位覆盖的剩余部分在报告里归入 other；
 *   子槽位（BP_SLOT_TOP_NUM 之后）是某个顶层槽位的内部细分，与父槽位
 *     重复计时，因此不参与 other 的求和，只单独列出用于回答"这段里
 *     有多少是某个具体开销"。
 */
typedef enum {
    /* ---- 硬件加速段 ---- */
    BP_GEMV_CSR = 0,  /* GEMV: 写基地址/维度/启动等CSR */
    BP_GEMV_FLUSH,    /* GEMV: cache_flush输入输出缓冲 */
    BP_GEMV_HW,       /* GEMV: 等硬件完成（DMA搬权重 + PE计算），纯硬件时间 */
    BP_GEMV_POST,     /* GEMV: 返回后的检查/后处理 */
    BP_ATTN_CSR,      /* FSA : 写Q/K/V/O地址等CSR */
    BP_ATTN_HW,       /* FSA : 等硬件完成 */

    /* ---- CPU算子段：把原先笼统的 other(CPU) 拆开 ---- */
    BP_ROPE,          /* RoPE旋转循环整体（含powf/cosf/sinf） */
    BP_FFN_ACT,       /* SwiGLU激活循环整体（含expf） */
    BP_RMSNORM,       /* rmsnorm，每层2次 + 末尾1次 */
    BP_RESIDUAL,      /* 两处残差累加 */
    BP_KVSTORE,       /* K/V写入tile-based cache，走uncached写 */
    BP_SAMPLE,        /* 采样：argmax 或 softmax+topp，规模为vocab_size */
    BP_IO,            /* decode + 串口输出 + fflush，阻塞式UART未必便宜 */

    BP_SLOT_TOP_NUM,  /* ↑ 以上为顶层槽位，参与 other 求和 ↑ */

    /* ---- 子槽位：父槽位的内部细分，不参与求和 ---- */
    BP_ROPE_TRIG = BP_SLOT_TOP_NUM,  /* ROPE中的powf+cosf+sinf：预计算查表能省掉的部分 */
    BP_FFN_EXP,                      /* FFN_ACT中的expf：PWL近似能省掉的部分 */

    BP_SLOT_NUM
} bp_slot_t;

/* 周期累加器：单次delta用32位读数相减（单次调用远小于2^32），累加进64位防溢出 */
extern unsigned long long bp_cycles[BP_SLOT_NUM];
/* 各槽位被计时的次数：用于扣除计时自身开销，判断细粒度槽位的实测值虚高多少 */
extern unsigned long long bp_hits[BP_SLOT_NUM];

/* GEMV规模累加：用于推算DMA/计算的理论下限 */
extern unsigned long long bp_gemv_macs;   /* Σ(n*d)，总乘加次数 */
extern unsigned long long bp_gemv_bytes;  /* Σ(n*d*4)，需从DDR读入的权重字节数 */
extern unsigned long long bp_gemv_calls;  /* GEMV调用次数 */

/* 直接用内联汇编读稳定计数器，不走 confreg_time.c 的 get_cpu_clock_count()。
   那是个独立编译单元里的普通函数，且本工程 CFLAGS 带 -fno-use-linker-plugin
   （关闭LTO）跨文件内联不了，每次探针都要付一整套函数调用开销。细粒度槽位
   （FFN_EXP 在本模型下要执行22万次、每次两个探针）下这笔开销会与被测对象同
   量级，把信噪比稀释掉。rdcntvl.w 是LoongArch的常频稳定计数器，一条指令读完。
   只取低32位，与原get_cpu_clock_count()一致：单个区间远小于2^32，相减不会错 */
static inline unsigned long bp_rdcnt(void)
{
    unsigned long v;
    __asm__ volatile("rdcntvl.w %0" : "=r"(v));
    return v;
}

#define BP_MARK(v)              unsigned long v = bp_rdcnt()
#define BP_ACC(slot, t0, t1)                                        \
    do {                                                            \
        bp_cycles[slot] += (unsigned long long)((t1) - (t0));       \
        bp_hits[slot]   += 1ull;                                    \
    } while (0)

/* 记录一次GEMV的规模：权重零复用，故读入字节数 = n*d*sizeof(float) */
#define BP_ADD_GEMV_SCALE(n, d)                                     \
    do {                                                            \
        unsigned long long _mac = (unsigned long long)(n) * (d);    \
        bp_gemv_macs  += _mac;                                      \
        bp_gemv_bytes += _mac * 4u;                                 \
        bp_gemv_calls += 1u;                                        \
    } while (0)

/* 打印拆解报告。total_cycles为端到端总周期，用于推算未被计时覆盖的纯CPU部分 */
void bp_report(unsigned long long total_cycles, int tokens);

#else  /* BENCH_PROFILE == 0：全部展开为空，正式构建零开销 */

#define BP_MARK(v)
#define BP_ACC(slot, t0, t1)
#define BP_ADD_GEMV_SCALE(n, d)
#define bp_report(total_cycles, tokens)

#endif /* BENCH_PROFILE */

#endif /* BENCH_PROFILE_H */

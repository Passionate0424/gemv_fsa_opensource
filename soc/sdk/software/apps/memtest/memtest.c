/*
 * 外部 SRAM 读通路验证
 *
 * 目的：区分「CPU 从外部 SRAM 读回来的数据本身就错」和「数据读对了、算错了」。
 * 平台的 flash_ram 回读走的是 zynq 直连 SRAM 引脚那条路，绕开了 FPGA 逻辑，
 * 所以它验过"内容正确"并不能说明 **FPGA 自己读**也正确——加宽后地址 IOB 寄存
 * 晚一拍到引脚、两片 tAA 各自独立，采样相位是否还对，只有让 CPU 亲自读才知道。
 *
 * 三组用例，从简到繁，能把错误定位到具体形态：
 *   1. 线性递增：每个 32 位字写自己的地址，检出「读到隔壁地址的数据」
 *   2. 交替 pattern：0xAAAA5555 / 0x5555AAAA 交替，检出「高低半字错配」
 *      （加宽后 base 存低 32 位、ext 存高 32 位，两片走线不同长）
 *   3. 连续突发：连续读同一区域两遍比对，检出「某拍数据重复上一拍」
 *      （字符重复的症状 ararary/thrrtt 正是这个形态）
 */
#include <stdio.h>
#include <stdint.h>
#include "common_func.h"

unsigned long UART_BASE = 0xbf000000;

/* trap_handler.S 无条件引用它。本测试不用加速器中断，给个空实现即可。 */
void HWI1_IntrHandler(void) {}

/* 地址必须落在 xbar 真正译码的 RAM 窗口内。
 * 换 pulp xbar 时把三个拉死的保留口连同规则一起去掉了，现在只剩
 *   0x1C00_0000–0x1C7F_FFFF = RAM（见 axi_xbar_2x8_wrap.sv 的 ADDR_MAP）
 * 低端 0x0000_0000–0x007F_FFFF 已无规则命中 → 落到 pulp 的 axi_err_slv，
 * 写被丢弃、读回常量 0xCA11AB1E_BADCAB1E。第一版这里照搬 MIPS 习惯写了
 * 0xa0400000（DMW0 直通到物理 0x0040_0000），整块测的其实是错误从机——
 * 四千个字全"错"，但和内存通路无关。
 * start.S 的 DMW0 把 VA 0x0000_0000–0x1FFF_FFFF 直通同址物理，程序本身就链接在
 * 0x1c000000；separate.lds 只声明到 4MB(isram 512K + dsram 3584K)，所以
 * 0x1c400000 起是安全的空闲区。 */
#define TEST_BASE  0x1c400000UL
#define TEST_WORDS 4096

/* DMW1 把 VA 0xA000_0000–0xBFFF_FFFF 映射到同一段物理，是 0x1cxxxxxx 的别名。
 * 两个窗口的 MAT 属性不同，走的缓存策略也就不同——同一块物理内存用两个别名各测
 * 一遍，能把"单拍访问错"和"突发填充错"分开。总线加宽改的正是突发返回通路
 * （64 位 RAM 喂 32 位 CPU，一个宽拍拆两个窄拍，中间必然隔拍背压走 skid）。 */
#define TEST_BASE_CACHED 0xbc400000UL

static volatile uint32_t *const mem  = (volatile uint32_t *)TEST_BASE;
/* 别名窗口。用例 4 已改成靠容量制造 miss，不再跨别名比对（那测的是一致性不是通路），
 * 这里保留声明供将来做一致性实验时用。 */
static volatile uint32_t *const memc __attribute__((unused)) =
    (volatile uint32_t *)TEST_BASE_CACHED;

static int check(const char *name, int errs, int shown)
{
    if (errs == 0) {
        printf("[MEMTEST] %s: PASS\n", name);
    } else {
        printf("[MEMTEST] %s: FAIL errs=%d (shown %d)\n", name, errs, shown);
    }
    return errs;
}

/* 用例 1：每个字写自己的字下标 */
static int test_linear(void)
{
    int errs = 0, shown = 0;
    for (int i = 0; i < TEST_WORDS; i++)
        mem[i] = (uint32_t)i;
    for (int i = 0; i < TEST_WORDS; i++) {
        uint32_t got = mem[i];
        if (got != (uint32_t)i) {
            errs++;
            if (shown < 8) {
                printf("  [L] idx=%d exp=%08x got=%08x\n", i, (uint32_t)i, got);
                shown++;
            }
        }
    }
    return check("linear", errs, shown);
}

/* 用例 2：交替 pattern——高低半字错配会立刻显形 */
static int test_alt(void)
{
    int errs = 0, shown = 0;
    for (int i = 0; i < TEST_WORDS; i++)
        mem[i] = (i & 1) ? 0x5555AAAAU : 0xAAAA5555U;
    for (int i = 0; i < TEST_WORDS; i++) {
        uint32_t exp = (i & 1) ? 0x5555AAAAU : 0xAAAA5555U;
        uint32_t got = mem[i];
        if (got != exp) {
            errs++;
            if (shown < 8) {
                printf("  [A] idx=%d exp=%08x got=%08x\n", i, exp, got);
                shown++;
            }
        }
    }
    return check("alt", errs, shown);
}

/* 用例 3：同一区域连读两遍，两遍之间不写——两遍不一致说明读通路本身不稳 */
static int test_reread(void)
{
    static uint32_t first[256];
    int errs = 0, shown = 0;
    for (int i = 0; i < 256; i++)
        first[i] = mem[i];
    for (int i = 0; i < 256; i++) {
        uint32_t got = mem[i];
        if (got != first[i]) {
            errs++;
            if (shown < 8) {
                printf("  [R] idx=%d pass1=%08x pass2=%08x\n", i, first[i], got);
                shown++;
            }
        }
    }
    return check("reread", errs, shown);
}

/* 用例 4：大区突发读写——本测试真正的判据。
 *
 * **不要用"写一个别名、读另一个别名"来制造 cache miss**：那测的是两个映射窗口之间的
 * 一致性，不是硬件通路。第一版就是这么写的，读回来的是上一个用例留在 SRAM 里的
 * pattern（exp=c0de0014 got=aaaa5555），看着像硬件错，其实是新值还压在 cache 里
 * 没落盘。同理，小于 cache 容量的测试区（4096 字 = 16KB，正好等于
 * index_depth 0x100 × way 4 × line 16B）很可能整轮都在 cache 里自洽，
 * **一次都没碰到外部 SRAM**——那三个 PASS 证明不了任何事。
 *
 * 靠容量而不是靠别名：测试区 256KB 远大于 16KB 的 dcache，同一个窗口写、同一个
 * 窗口读。每次读必然 miss、必然从 SRAM 取一整条 line（4 拍突发填充），脏行换出时
 * 必然写回（4 拍突发写）。这才真实覆盖加宽后的突发通路，且不依赖任何一致性假设。 */
#define BIG_WORDS (64 * 1024)          /* 256KB，16 倍于 dcache */

static int test_burst_big(void)
{
    int errs = 0, shown = 0;
    for (int i = 0; i < BIG_WORDS; i++)
        mem[i] = 0xC0DE0000U ^ (uint32_t)i;
    for (int i = 0; i < BIG_WORDS; i++) {
        uint32_t exp = 0xC0DE0000U ^ (uint32_t)i;
        uint32_t got = mem[i];
        if (got != exp) {
            errs++;
            if (shown < 8) {
                printf("  [B] idx=%d exp=%08x got=%08x\n", i, exp, got);
                shown++;
            }
        }
    }
    return check("burst_big", errs, shown);
}

/* 用例 5：同一大区连读两遍，中间不写。两遍不一致 = 读通路本身不稳定。
 * 与用例 3 的区别只在区域大小——这里每次读都是真的 cache miss 去 SRAM 取。 */
static int test_burst_reread(void)
{
    int errs = 0, shown = 0;
    /* 逐条 line 比对：先读一遍存进局部，再读一遍。局部数组不能开 256KB，
     * 所以分块做，块大小取 1024 字（4KB）——仍远小于测试区，块间必然换出。 */
    static uint32_t tmp[1024];
    for (int base = 0; base < BIG_WORDS; base += 1024) {
        for (int i = 0; i < 1024; i++)
            tmp[i] = mem[base + i];
        /* 中间扫一遍别处，把刚才那块从 cache 里挤出去 */
        volatile uint32_t sink = 0;
        for (int i = 0; i < BIG_WORDS; i += 1024)
            sink ^= mem[i];
        (void)sink;
        for (int i = 0; i < 1024; i++) {
            uint32_t got = mem[base + i];
            if (got != tmp[i]) {
                errs++;
                if (shown < 8) {
                    printf("  [R2] idx=%d pass1=%08x pass2=%08x\n",
                           base + i, tmp[i], got);
                    shown++;
                }
            }
        }
    }
    return check("burst_reread", errs, shown);
}

/* 单轮全过不代表没问题：板上的症状是**随机**的，几千个字跑一遍很可能撞不上。
 * 多轮累计，把"一次没错"和"确实没错"分开。 */
#define ROUNDS 16

int main(void)
{
    printf("[MEMTEST] start base=0x%08lx small_words=%d big_words=%d rounds=%d\n",
           (unsigned long)TEST_BASE, TEST_WORDS, BIG_WORDS, ROUNDS);

    int e_lin = 0, e_alt = 0, e_re = 0, e_big = 0, e_br = 0;
    for (int r = 0; r < ROUNDS; r++) {
        e_lin += test_linear();
        e_alt += test_alt();
        e_re  += test_reread();
        e_big += test_burst_big();
        e_br  += test_burst_reread();
        printf("[MEMTEST] round %d done (cum: lin=%d alt=%d re=%d big=%d br=%d)\n",
               r, e_lin, e_alt, e_re, e_big, e_br);
    }
    int total = e_lin + e_alt + e_re + e_big + e_br;

    printf("[MEMTEST] done rounds=%d total_errs=%d "
           "(linear=%d alt=%d reread=%d burst_big=%d burst_reread=%d)\n",
           ROUNDS, total, e_lin, e_alt, e_re, e_big, e_br);
    return 0;
}

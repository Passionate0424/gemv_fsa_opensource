/*
 * SoC集成冒烟测试: CSR读写 + 8×8 GEMV
 * 验证CB_top_v2通过AXI crossbar正确连接
 */
#include <stdio.h>
#include <stdint.h>
#include "common_func.h"
#include "hw_accelerator.h"

unsigned long UART_BASE = 0xbf000000;
unsigned long CB_BASE = 0xbf300000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

static inline void cpu_idle(void) {
    __asm__ __volatile__("idle 0" ::: "memory");
}

static inline void cache_flush(void *addr, unsigned long size) {
    unsigned long line = 1 << cache_offset_width;
    unsigned long start = ((unsigned long)addr) & ~(line - 1);
    unsigned long end = ((unsigned long)addr + size + line - 1) & ~(line - 1);
    for (unsigned long p = start; p < end; p += line) {
        __asm__ __volatile__("cacop 0x11, %0, 0" :: "r"(p) : "memory");
    }
    __asm__ __volatile__("dbar 0" ::: "memory");
}

static inline void cb_write(unsigned long offset, unsigned long value) {
    RegWrite(CB_BASE + offset, value);
}

static inline unsigned long cb_read(unsigned long offset) {
    return RegRead(CB_BASE + offset);
}

void HWI1_IntrHandler(void) {
    cb_write(REG_CTRL_ADDR, 0);
}

// 测试数据: 使用8×64矩阵（硬件最小支持COLS=64）
// W[8][64]: 每行i在列i位置为1，其余为0
// x[64] = {1,2,...,8, 0,...,0}
// 期望输出 xout[8] = {1,2,3,4,5,6,7,8}
static float test_matrix[512] __attribute__((aligned(16)));
static float test_vector[64] __attribute__((aligned(16)));
static float test_output[8] __attribute__((aligned(16)));

int pass_count = 0;
int fail_count = 0;

void check(const char* name, int cond) {
    if (cond) {
        printf("[PASS] %s\n", name);
        pass_count++;
    } else {
        printf("[FAIL] %s\n", name);
        fail_count++;
    }
}

// 测试1: CSR读写
void test_csr_readwrite(void) {
    printf("\n=== Test 1: CSR Read/Write ===\n");

    cb_write(REG_ROWS_ADDR, 8);
    unsigned long val = cb_read(REG_ROWS_ADDR);
    check("ROWS write/read", val == 8);

    cb_write(REG_COLS_ADDR, 64);
    val = cb_read(REG_COLS_ADDR);
    check("COLS write/read", val == 64);

    cb_write(REG_HEAD_DIM_ADDR, 8);
    val = cb_read(REG_HEAD_DIM_ADDR);
    check("HEAD_DIM write/read", val == 8);

    cb_write(REG_ATTN_SCALE_ADDR, 0x3F0293EE);
    val = cb_read(REG_ATTN_SCALE_ADDR);
    check("ATTN_SCALE write/read", val == 0x3F0293EE);
}

// 测试2: 8×64 GEMV（硬件最小支持COLS=64）
void test_gemv_identity(void) {
    printf("\n=== Test 2: 8x64 GEMV ===\n");

    // 初始化: W[8][64]每行i在列i位置为1，其余为0
    for (int i = 0; i < 512; i++) test_matrix[i] = 0.0f;
    for (int i = 0; i < 8; i++) test_matrix[i * 64 + i] = 1.0f;

    // x[64] = {1,2,...,8, 0,...,0}
    for (int i = 0; i < 64; i++) test_vector[i] = (i < 8) ? (float)(i + 1) : 0.0f;

    // 使用ExtRAM区域作为输出（物理地址bit22=1，避免与BaseRAM指令fetch冲突）
    // ExtRAM物理地址: 0x1c400000+
    static float ext_output[8] __attribute__((aligned(16)));
    unsigned long vo_phys = (unsigned long)test_output & 0x1FFFFFFF;

    // 初始化输出为-1标记
    for (int i = 0; i < 8; i++) test_output[i] = -1.0f;

    cache_flush(test_vector, 64 * sizeof(float));
    cache_flush(test_matrix, 512 * sizeof(float));
    cache_flush(test_output, 8 * sizeof(float));

    // DMA地址使用物理地址
    unsigned long mi_phys = (unsigned long)test_matrix & 0x1FFFFFFF;
    unsigned long vi_phys = (unsigned long)test_vector & 0x1FFFFFFF;

    cb_write(REG_MI_BASE_ADDR, mi_phys);
    cb_write(REG_VI_BASE_ADDR, vi_phys);
    cb_write(REG_VO_BASE_ADDR, vo_phys);
    cb_write(REG_ROWS_ADDR, 8);
    cb_write(REG_COLS_ADDR, 64);

    printf("  MI=0x%lx VI=0x%lx VO=0x%lx\n", mi_phys, vi_phys, vo_phys);

    cb_write(REG_CTRL_ADDR, CSR_CTRL_START_BIT);
    cpu_idle();
    HWI1_IntrHandler();

    cache_flush(test_output, 8 * sizeof(float));

    // 通过uncached地址读回结果，彻底排除cache问题
    volatile float* uncached_output = (volatile float*)(((unsigned long)test_output & 0x1FFFFFFF) | 0xA0000000);

    // 验证结果
    printf("  output: ");
    for (int i = 0; i < 8; i++) printf("%.2f ", uncached_output[i]);
    printf("\n  expect: ");
    for (int i = 0; i < 8; i++) printf("%.2f ", (float)(i+1));
    printf("\n");

    int all_match = 1;
    for (int i = 0; i < 8; i++) {
        float expected = (float)(i + 1);
        float actual = uncached_output[i];
        if (actual != expected) {
            printf("  MISMATCH [%d]: got %f, want %f\n", i, actual, expected);
            all_match = 0;
        }
    }
    check("GEMV identity result", all_match);
}

// 测试3: 32×64 GEMV（匹配LLaMA2实际使用的维度范围）
static float test_matrix2[32*64] __attribute__((aligned(16)));
static float test_vector2[64] __attribute__((aligned(16)));
static float test_output2[32] __attribute__((aligned(16)));

void test_gemv_64x64(void) {
    printf("\n=== Test 3: 32x64 GEMV ===\n");

    for (int i = 0; i < 32*64; i++) test_matrix2[i] = 0.0f;
    for (int i = 0; i < 64; i++) test_vector2[i] = 1.0f;
    // W[0][j] = 1.0 for all j → xout[0] = sum(x) = 64.0
    for (int j = 0; j < 64; j++) test_matrix2[j] = 1.0f;

    for (int i = 0; i < 32; i++) test_output2[i] = -1.0f;

    cache_flush(test_vector2, 64 * sizeof(float));
    cache_flush(test_matrix2, 32 * 64 * sizeof(float));
    cache_flush(test_output2, 32 * sizeof(float));

    unsigned long mi_phys = (unsigned long)test_matrix2 & 0x1FFFFFFF;
    unsigned long vi_phys = (unsigned long)test_vector2 & 0x1FFFFFFF;
    unsigned long vo_phys = (unsigned long)test_output2 & 0x1FFFFFFF;

    cb_write(REG_MI_BASE_ADDR, mi_phys);
    cb_write(REG_VI_BASE_ADDR, vi_phys);
    cb_write(REG_VO_BASE_ADDR, vo_phys);
    cb_write(REG_ROWS_ADDR, 32);
    cb_write(REG_COLS_ADDR, 64);

    cb_write(REG_CTRL_ADDR, CSR_CTRL_START_BIT);
    cpu_idle();
    HWI1_IntrHandler();

    cache_flush(test_output2, 32 * sizeof(float));

    volatile float* uncached_out = (volatile float*)(((unsigned long)test_output2 & 0x1FFFFFFF) | 0xA0000000);

    int ok = 1;
    if (uncached_out[0] != 64.0f) {
        printf("  output[0] = %f, expected 64.0\n", uncached_out[0]);
        ok = 0;
    }
    for (int i = 1; i < 32; i++) {
        if (uncached_out[i] != 0.0f) {
            printf("  output[%d] = %f, expected 0.0\n", i, uncached_out[i]);
            ok = 0;
            break;
        }
    }
    check("GEMV 32x64 result", ok);
}

// 测试4: FSA Attention（seq=8, 4 heads, head_dim=8）
// 数据静态初始化，编译进mif，避免运行时初始化开销
// K/V = 每个head一个8×8单位矩阵（tile格式: [h0:64][h1:64][h2:64][h3:64]）
static float fsa_q_test[4 * 8] __attribute__((aligned(16))) = {
    1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1
};
static float fsa_k_test[4 * 8 * 8] __attribute__((aligned(16))) = {
    // head 0: 8×8 identity
    1,0,0,0,0,0,0,0, 0,1,0,0,0,0,0,0, 0,0,1,0,0,0,0,0, 0,0,0,1,0,0,0,0,
    0,0,0,0,1,0,0,0, 0,0,0,0,0,1,0,0, 0,0,0,0,0,0,1,0, 0,0,0,0,0,0,0,1,
    // head 1: 8×8 identity
    1,0,0,0,0,0,0,0, 0,1,0,0,0,0,0,0, 0,0,1,0,0,0,0,0, 0,0,0,1,0,0,0,0,
    0,0,0,0,1,0,0,0, 0,0,0,0,0,1,0,0, 0,0,0,0,0,0,1,0, 0,0,0,0,0,0,0,1,
    // head 2: 8×8 identity
    1,0,0,0,0,0,0,0, 0,1,0,0,0,0,0,0, 0,0,1,0,0,0,0,0, 0,0,0,1,0,0,0,0,
    0,0,0,0,1,0,0,0, 0,0,0,0,0,1,0,0, 0,0,0,0,0,0,1,0, 0,0,0,0,0,0,0,1,
    // head 3: 8×8 identity
    1,0,0,0,0,0,0,0, 0,1,0,0,0,0,0,0, 0,0,1,0,0,0,0,0, 0,0,0,1,0,0,0,0,
    0,0,0,0,1,0,0,0, 0,0,0,0,0,1,0,0, 0,0,0,0,0,0,1,0, 0,0,0,0,0,0,0,1
};
static float fsa_v_test[4 * 8 * 8] __attribute__((aligned(16))) = {
    // head 0: 8×8 identity
    1,0,0,0,0,0,0,0, 0,1,0,0,0,0,0,0, 0,0,1,0,0,0,0,0, 0,0,0,1,0,0,0,0,
    0,0,0,0,1,0,0,0, 0,0,0,0,0,1,0,0, 0,0,0,0,0,0,1,0, 0,0,0,0,0,0,0,1,
    // head 1: 8×8 identity
    1,0,0,0,0,0,0,0, 0,1,0,0,0,0,0,0, 0,0,1,0,0,0,0,0, 0,0,0,1,0,0,0,0,
    0,0,0,0,1,0,0,0, 0,0,0,0,0,1,0,0, 0,0,0,0,0,0,1,0, 0,0,0,0,0,0,0,1,
    // head 2: 8×8 identity
    1,0,0,0,0,0,0,0, 0,1,0,0,0,0,0,0, 0,0,1,0,0,0,0,0, 0,0,0,1,0,0,0,0,
    0,0,0,0,1,0,0,0, 0,0,0,0,0,1,0,0, 0,0,0,0,0,0,1,0, 0,0,0,0,0,0,0,1,
    // head 3: 8×8 identity
    1,0,0,0,0,0,0,0, 0,1,0,0,0,0,0,0, 0,0,1,0,0,0,0,0, 0,0,0,1,0,0,0,0,
    0,0,0,0,1,0,0,0, 0,0,0,0,0,1,0,0, 0,0,0,0,0,0,1,0, 0,0,0,0,0,0,0,1
};
static float fsa_o_test[4 * 8] __attribute__((aligned(16)));

void test_fsa_attention(void) {
    printf("\n=== Test 4: FSA Attention (seq=8, 4heads) ===\n");

    int head_dim = 8;
    int n_heads = 4;
    int seq_len = 8;
    int kv_stride = n_heads * head_dim * head_dim * sizeof(float);  // 1024 bytes

    for (int i = 0; i < n_heads * head_dim; i++) fsa_o_test[i] = -1.0f;

    // 静态数据已在mif中，只需flush确保dcache不持有脏副本
    cache_flush(fsa_q_test, n_heads * head_dim * sizeof(float));
    cache_flush(fsa_k_test, kv_stride);
    cache_flush(fsa_v_test, kv_stride);
    cache_flush(fsa_o_test, n_heads * head_dim * sizeof(float));

    unsigned long q_phys = (unsigned long)fsa_q_test & 0x1FFFFFFF;
    unsigned long k_phys = (unsigned long)fsa_k_test & 0x1FFFFFFF;
    unsigned long v_phys = (unsigned long)fsa_v_test & 0x1FFFFFFF;
    unsigned long o_phys = (unsigned long)fsa_o_test & 0x1FFFFFFF;

    // ATTN_SCALE = log2(e)/sqrt(8) ≈ 0.5100
    unsigned int scale_bits = 0x3F0293EE;

    cb_write(REG_Q_BASE_ADDR, q_phys);
    cb_write(REG_K_BASE_ADDR, k_phys);
    cb_write(REG_V_BASE_ADDR, v_phys);
    cb_write(REG_O_BASE_ADDR, o_phys);
    cb_write(REG_HEAD_DIM_ADDR, head_dim);
    cb_write(REG_SEQ_LEN_ADDR, seq_len);
    cb_write(REG_KV_STRIDE_ADDR, kv_stride);
    cb_write(REG_ATTN_SCALE_ADDR, scale_bits);

    cb_write(REG_CTRL_ADDR, CSR_CTRL_START_BIT | CSR_CTRL_MODE_FSA);
    cpu_idle();
    HWI1_IntrHandler();

    // 读回结果前invalidate output cache
    cache_flush(fsa_o_test, n_heads * head_dim * sizeof(float));

    volatile float* uncached_o = (volatile float*)(((unsigned long)fsa_o_test & 0x1FFFFFFF) | 0xA0000000);

    // 验证: 每个元素应≈0.125 (1/8)，允许PWL近似误差
    int ok = 1;
    printf("  head0 O: ");
    for (int i = 0; i < 8; i++) printf("%.4f ", uncached_o[i]);
    printf("\n");

    for (int i = 0; i < n_heads * head_dim; i++) {
        float val = uncached_o[i];
        if (val < 0.10f || val > 0.15f) {
            printf("  MISMATCH O[%d] = %f, expected ~0.125\n", i, val);
            ok = 0;
            if (i > 3) break;  // 只打印前几个错误
        }
    }
    check("FSA attention result", ok);
}

// 测试5: Vec残留检测（LLaMA2实际维度，连续matmul对比）
// 用不同维度连续调用，第N次的残留可能影响第N+1次
static float res_matrix[172*64] __attribute__((aligned(16)));
static float res_vector[172] __attribute__((aligned(16)));
static float res_output[172] __attribute__((aligned(16)));

// 简单PRNG
static unsigned int prng_state = 12345;
static float prng_float(void) {
    prng_state = prng_state * 1664525u + 1013904223u;
    int val = (int)(prng_state % 7) - 3;  // [-3, 3]
    return (float)val;
}

void test_vec_residual(void) {
    printf("\n=== Test 5: Vec Residual (LLaMA2 dims, CPU golden) ===\n");

    unsigned long mi_phys = (unsigned long)res_matrix & 0x1FFFFFFF;
    unsigned long vi_phys = (unsigned long)res_vector & 0x1FFFFFFF;
    unsigned long vo_phys = (unsigned long)res_output & 0x1FFFFFFF;

    struct { int d; int n; } dims[] = {
        {64, 64}, {32, 64}, {32, 64},
        {172, 64}, {64, 172}, {172, 64},
        {64, 64},
    };
    int num_dims = sizeof(dims) / sizeof(dims[0]);

    int total_mismatches = 0;
    int total_calls = 0;
    prng_state = 42;

    // 跑200次连续matmul（模拟推理负载）
    for (int c = 0; c < 200; c++) {
        int idx = c % num_dims;
        int d = dims[idx].d;
        int n = dims[idx].n;

        for (int i = 0; i < d * n; i++) res_matrix[i] = prng_float();
        for (int i = 0; i < n; i++) res_vector[i] = prng_float();
        res_vector[0] = 3.0f;

        cache_flush(res_matrix, d * n * sizeof(float));
        cache_flush(res_vector, n * sizeof(float));
        for (int i = 0; i < d; i++) res_output[i] = -999.0f;
        cache_flush(res_output, d * sizeof(float));

        cb_write(REG_MI_BASE_ADDR, mi_phys);
        cb_write(REG_VI_BASE_ADDR, vi_phys);
        cb_write(REG_VO_BASE_ADDR, vo_phys);
        cb_write(REG_ROWS_ADDR, d);
        cb_write(REG_COLS_ADDR, n);
        cb_write(REG_CTRL_ADDR, CSR_CTRL_START_BIT);
        cpu_idle();
        HWI1_IntrHandler();

        cache_flush(res_output, d * sizeof(float));
        volatile float* unc = (volatile float*)(((unsigned long)res_output & 0x1FFFFFFF) | 0xA0000000);

        total_calls++;
        int call_mismatch = 0;
        for (int i = 0; i < d; i++) {
            float cpu_val = 0.0f;
            for (int j = 0; j < n; j++) cpu_val += res_matrix[i * n + j] * res_vector[j];
            float diff = unc[i] - cpu_val;
            if (diff > 0.1f || diff < -0.1f) {
                if (call_mismatch < 3 && total_mismatches < 30) {
                    float ratio = (cpu_val != 0.0f) ? unc[i] / cpu_val : 0.0f;
                    printf("  call#%d d=%d n=%d [%d] hw=%.4f cpu=%.4f ratio=%.2f pe=%d tile=%d\n",
                           c, d, n, i, unc[i], cpu_val, ratio, i%32, i/32);
                }
                call_mismatch++;
            }
        }
        if (call_mismatch > 0) {
            if (total_mismatches < 30)
                printf("  call#%d d=%d n=%d mismatches=%d\n", c, d, n, call_mismatch);
            total_mismatches += call_mismatch;
        }
    }

    printf("  Total: %d calls, %d mismatches\n", total_calls, total_mismatches);
    check("Vec residual (CPU golden compare)", total_mismatches == 0);
}

int main(void) {
    printf("\n[SMOKE] SoC Integration Smoke Test\n");
    printf("[SMOKE] CB_BASE = 0x%lx\n", CB_BASE);

    test_csr_readwrite();
    test_gemv_identity();
    test_gemv_64x64();
    test_vec_residual();
    test_fsa_attention();

    printf("\n[SMOKE] ========== SUMMARY ==========\n");
    printf("[SMOKE] PASS=%d FAIL=%d\n", pass_count, fail_count);
    if (fail_count == 0) {
        printf("[SMOKE] ALL TESTS PASSED\n");
    } else {
        printf("[SMOKE] SOME TESTS FAILED\n");
    }

    while(1);
    return 0;
}

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

// 端到端FlashAttention Golden Model（标准softmax，fp64精度）
// 完全独立于硬件实现，作为理想参考

#define MAX_DIM 64
#define MAX_SEQ 2048
#define MAX_HEADS 4

static double g_Q[MAX_HEADS][MAX_DIM];
static double g_K[MAX_HEADS][MAX_SEQ][MAX_DIM];
static double g_V[MAX_HEADS][MAX_SEQ][MAX_DIM];
static double g_O[MAX_HEADS][MAX_DIM];
static int g_dim;
static int g_seq_len;
static int g_num_heads;

static float bits_to_float_e2e(unsigned int bits) {
    float f;
    memcpy(&f, &bits, 4);
    return f;
}

static unsigned int float_to_bits_e2e(float f) {
    unsigned int bits;
    memcpy(&bits, &f, 4);
    return bits;
}

// 精度统计变量（每个case在dpi_e2e_init中重置）
static double g_sum_abs_err = 0.0;
static double g_sum_rel_err = 0.0;
static double g_max_abs_err = 0.0;
static double g_max_rel_err = 0.0;
/* 逐位一致统计（仅BITACC模式，只统计不判定） */
static long g_bitexact_total = 0;
static long g_bitexact_hit   = 0;
static long g_within_1ulp    = 0;
static int  g_max_ulp_diff   = 0;
static long g_ulp_bucket[7]  = {0};
static double g_worst_golden = 0, g_worst_dut = 0;

static int g_compare_total = 0;
static int g_compare_fail = 0;
static int g_compare_warn = 0;

void dpi_e2e_init(int head_dim, int seq_len, int num_heads) {
    g_dim = head_dim;
    g_seq_len = (seq_len > MAX_SEQ) ? MAX_SEQ : seq_len;
    g_num_heads = (num_heads > MAX_HEADS) ? MAX_HEADS : num_heads;
    memset(g_Q, 0, sizeof(g_Q));
    memset(g_K, 0, sizeof(g_K));
    memset(g_V, 0, sizeof(g_V));
    memset(g_O, 0, sizeof(g_O));
    // 重置精度统计（每个case独立统计）
    g_compare_total = 0;
    g_compare_fail = 0;
    g_compare_warn = 0;
    g_sum_abs_err = 0.0;
    g_sum_rel_err = 0.0;
    g_max_abs_err = 0.0;
    g_max_rel_err = 0.0;
}

void dpi_e2e_set_q(int head, int idx, unsigned int val) {
    if (head < g_num_heads && idx < MAX_DIM)
        g_Q[head][idx] = (double)bits_to_float_e2e(val);
}

void dpi_e2e_set_k(int head, int row, int col, unsigned int val) {
    if (head < g_num_heads && row < MAX_SEQ && col < MAX_DIM)
        g_K[head][row][col] = (double)bits_to_float_e2e(val);
}

void dpi_e2e_set_v(int head, int row, int col, unsigned int val) {
    if (head < g_num_heads && row < MAX_SEQ && col < MAX_DIM)
        g_V[head][row][col] = (double)bits_to_float_e2e(val);
}

// ============================================================================
// Golden模式选择：两个模型回答两个不同的问题，并存而非互相取代
//   MODE_IDEAL(0)  ：fp64标准softmax，回答"算法总误差有多大"。硬件用8段PWL
//                    近似exp2，与它比必然有系统性偏差，因此判定阈值是宽松的，
//                    并附带constrain.md里的已知精度边界豁免清单。
//   MODE_BITACC(1) ：fp32 + 同一套PWL系数 + 逐tile online softmax，复现硬件的
//                    数值行为，回答"RTL实现对不对"。期望是exact match，任何
//                    超差都应视为bug而不是近似误差——这样FAIL就不再需要人工
//                    对照豁免清单去判断性质。
// 由 dpi_e2e_set_mode() 切换，TB侧通过 +GOLDEN_BITACC 传入，默认保持IDEAL以
// 不改变现有139-case回归基线。
// ============================================================================
#define E2E_MODE_IDEAL   0
#define E2E_MODE_BITACC  1
static int g_golden_mode = E2E_MODE_IDEAL;

void dpi_e2e_set_mode(int mode) { g_golden_mode = mode; }

// 硬件的attn_scale：TB按head_dim写入CSR的正是这些fp32常量（tb_fsa_e2e.sv:305-310）。
// 这里必须复用同一份bit pattern而不是现算log2(e)/sqrt(d)——现算会引入一个ULP级
// 的差异，在128 tile的rescale链上会被累积放大，掩盖真正要找的实现偏差。
static float e2e_attn_scale(int dim) {
    unsigned int bits;
    switch (dim) {
        case 8:  bits = 0x3F0293EEu; break;
        case 16: bits = 0x3EB8AA3Bu; break;
        case 32: bits = 0x3E8293EEu; break;
        case 48: bits = 0x3E553B95u; break;
        case 64: bits = 0x3E38AA3Bu; break;
        default: bits = 0x3F0293EEu; break;
    }
    return bits_to_float_e2e(bits);
}

#include "fp_bitlevel.h"

// bit-accurate模型：复现硬件的逐tile online softmax
//
// 硬件不是"求全局max再一次性softmax"，而是按 seq_tile_len 分块流式处理：每来一个
// tile就更新running max，并把已累积的 rowsum(l) 和 PV累加(O) 按 exp2((m_old-m_new)*scale)
// 整体rescale一次。tile划分与TB一致：seq_tile_len = min(head_dim, 32)（tb_fsa_e2e.sv:234）。
//
// 为什么必须复现这个结构而不能只把fp64换成fp32+PWL：全局max会让大量 (s-max) 落到
// PWL的硬截断区 y<-5.545 被丢成0，而online softmax的running max使tile内动态范围
// 小得多、几乎不触发截断。用全局max+PWL做出来的模型，误差反而比硬件本身还大。

/* PV 链式累加方向：PE 阵列是下行链（CMP 在顶、底部 PE 出 PV 结果），而
   golden_compare.c 记有"PE顺序的score（倒序）"。fp32 加法不满足结合律，
   方向错了结果就不同，所以做成可切换、用实测判定。0=正序 1=倒序 */
static int g_pv_reverse = -1;   /* -1 = 未定，首次用时读环境变量 PV_REVERSE */
void dpi_e2e_set_pv_order(int rev) { g_pv_reverse = rev; }

static void e2e_compute_bitacc(void) {
    const int      tile_len = (g_dim > 32) ? 32 : g_dim;
    const uint32_t scale_b  = f2b_((double)e2e_attn_scale(g_dim));

    if (g_pv_reverse < 0) {
        const char *e = getenv("PV_REVERSE");
        g_pv_reverse = (e && e[0] == '1') ? 1 : 0;
    }

    for (int h = 0; h < g_num_heads; h++) {
        uint32_t m_b = 0, l_b = 0;
        uint32_t O_b[MAX_DIM];
        int      first_tile = 1;
        for (int i = 0; i < g_dim; i++) O_b[i] = 0;

        for (int base = 0; base < g_seq_len; base += tile_len) {
            int rows = g_seq_len - base;
            if (rows > tile_len) rows = tile_len;

            /* QK^T。注意这里用 float 而非位级链式乘加：位级版本实测把逐位命中率
               从 22.43% 拉低到 18.11%，说明我按"链式顺序累加"的推断与 PE 阵列的
               实际编排不符。在没有模块级 TB 抓到真实输入输出对之前，保守的 float
               反而更接近硬件——位级转录只有在编排正确时才占优。 */
            /* QK 位级开关：之前测位级 QK 更差(22.43%->18.11%)，但那次是在错误的
               累加结构下测的（当时还是逐行往O累加）。结构修正后重新受控对比。
               BITLVL_QK=1 启用位级链式乘加，对应 PE_core_v2 WS 模式的下行链：
               PE_i = fpmul(Q_i,K_i) + c_from_PE_{i-1}（PE_core_v2.sv:626,
               RawFloat_FMA_LA.sv:85 use_pre_add=0 时加法器B取外部c而非反馈）。 */
            static int bitlvl_qk = -1;
            if (bitlvl_qk < 0) {
                /* 默认启用：有RTL依据(PE_core_v2.sv:626 下行链 + FMA_LA.sv:85
                   use_pre_add=0时加法器B取外部c)，实测也略优。设0可退回float对照。 */
                const char *e = getenv("BITLVL_QK");
                bitlvl_qk = (e && e[0] == '0') ? 0 : 1;
            }
            uint32_t s_b[32];
            for (int r = 0; r < rows; r++) {
                if (bitlvl_qk) {
                    uint32_t acc = 0;
                    for (int k = 0; k < g_dim; k++)
                        acc = fpadd_bits(fpmul_bits(f2b_(g_Q[h][k]),
                                                    f2b_(g_K[h][base + r][k])), acc);
                    s_b[r] = acc;
                } else {
                    float acc = 0.0f;
                    for (int k = 0; k < g_dim; k++)
                        acc += (float)g_Q[h][k] * (float)g_K[h][base + r][k];
                    s_b[r] = f2b_((double)acc);
                }
            }

            uint32_t m_new = first_tile ? s_b[0] : m_b;
            for (int r = 0; r < rows; r++) if (fgt_(s_b[r], m_new)) m_new = s_b[r];

            /* rescale 与 PV 累加同样退回 float：位级版本未经独立验证，实测更差。
               exp2 本身保持位级（已用 32000 组硬件实测对验证到 100% bit-exact）。 */
            float lf, mf, mnf; memcpy(&lf, &l_b, 4);
            memcpy(&mf, &m_b, 4); memcpy(&mnf, &m_new, 4);
            float scale; memcpy(&scale, &scale_b, 4);
            float Of[MAX_DIM];
            for (int i = 0; i < g_dim; i++) memcpy(&Of[i], &O_b[i], 4);

            /* 硬件的 ACC_SA 是 out = fpadd(fpmul(scale, sram_in), sa_in)，其中
               sram_in 是 ACC SRAM 里的 O_old、sa_in 是 PE 阵列**已把整个 tile
               求和完毕**的 P·V。也就是说 rescale 与累加合并成一条指令，且每个
               tile 只对 O 做一次加法——不是逐行往 O 上累加。
               (rtl/fsa/fsa_accumulator.sv:139-151 的输入 MUX)
               逐行累加的舍入次数和位置都不同，这是结构性差异，不是顺序问题。 */
            /* exp2 的输入必须位级：硬件是 SUBTRACT -> SCALE -> EXP2 三个阶段，
               前两步各自截断（fpadd/fpmul 都没有 round/sticky）。用 C float 算
               (s-m)*scale 会带进舍入差异，而这个差异经指数函数放大后，影响远大于
               算子内部的舍入——这是此前只换算子却几乎无效果的原因。 */
            float pv[MAX_DIM], psum = 0.0f;
            for (int i = 0; i < g_dim; i++) pv[i] = 0.0f;
            /* tile 内 PV 求和方向：PE 阵列是下行链，但 golden_compare.c 记有
               "PE顺序的score（倒序）"。误差集中在抵消严重的小值上，顺序差异
               在那里会被放大，所以这是剩下最有嫌疑的变量。 */
            for (int rr = 0; rr < rows; rr++) {
                int r = g_pv_reverse ? (rows - 1 - rr) : rr;
                uint32_t d  = fpadd_bits(s_b[r], fneg_(m_new));   /* SUBTRACT */
                uint32_t sc = fpmul_bits(d, scale_b);             /* SCALE    */
                uint32_t pb = exp2_hw(sc);                        /* EXP2     */
                float p; memcpy(&p, &pb, 4);
                psum += p;                                   /* tile 内 rowsum */
                for (int i = 0; i < g_dim; i++)
                    pv[i] += p * (float)g_V[h][base + r][i]; /* tile 内 PV 求和 */
            }

            if (first_tile) {
                lf = psum;
                for (int i = 0; i < g_dim; i++) Of[i] = pv[i];
            } else {
                uint32_t dc  = fpadd_bits(m_b, fneg_(m_new));
                uint32_t scc = fpmul_bits(dc, scale_b);
                uint32_t cb  = exp2_hw(scc);
                float corr; memcpy(&corr, &cb, 4);
                lf = corr * lf + psum;                       /* 一次 ACC_SA */
                for (int i = 0; i < g_dim; i++)
                    Of[i] = corr * Of[i] + pv[i];
            }

            l_b = f2b_((double)lf);
            for (int i = 0; i < g_dim; i++) O_b[i] = f2b_((double)Of[i]);

            m_b = m_new;
            first_tile = 0;
        }

        /* 归一化：硬件是 RECIPROCAL(1/l) + ACC_NORM(乘)，不是直接除法。
           recip_bits 是新写且未单独验证过的代码，用 USE_RECIP=0 可退回 C 除法
           做对照，隔离出它是否是逐位命中率下降的原因。 */
        /* 默认走 C 除法：位级 recip_bits 实测把逐位命中率从 18.11% 拉到 10.59%，
           说明它有 bug（全新代码，从未用真实硬件输入输出对单独验证过）。
           设 USE_RECIP=1 可启用，供将来做完 RawFloat_Div 模块级验证后对照。 */
        static int use_recip = -1;
        if (use_recip < 0) {
            const char *e = getenv("USE_RECIP");
            use_recip = (e && e[0] == '1') ? 1 : 0;
        }
        if (use_recip) {
            uint32_t rl = recip_bits(l_b);
            for (int i = 0; i < g_dim; i++)
                g_O[h][i] = b2d_(fpmul_bits(O_b[i], rl));
        } else {
            float lf; memcpy(&lf, &l_b, 4);
            for (int i = 0; i < g_dim; i++) {
                float of; memcpy(&of, &O_b[i], 4);
                g_O[h][i] = (double)(of / lf);
            }
        }
    }
}

// 标准softmax attention（非tiled，fp64精度）
// O[h] = softmax(Q[h] × K[h]^T / sqrt(d)) × V[h]
void dpi_e2e_compute() {
    double scale = 1.0 / sqrt((double)g_dim);
    int h, i, j;

    if (g_golden_mode == E2E_MODE_BITACC) { e2e_compute_bitacc(); return; }

    for (h = 0; h < g_num_heads; h++) {
        // S = Q × K^T，S[j] = sum_k Q[k] * K[j][k]
        double S[MAX_SEQ];
        for (j = 0; j < g_seq_len; j++) {
            double sum = 0.0;
            for (int k = 0; k < g_dim; k++)
                sum += g_Q[h][k] * g_K[h][j][k];
            S[j] = sum * scale;
        }

        // softmax: P = exp(S - max(S)) / sum(exp(S - max(S)))
        double max_s = S[0];
        for (j = 1; j < g_seq_len; j++)
            if (S[j] > max_s) max_s = S[j];

        double P[MAX_SEQ];
        double sum_exp = 0.0;
        for (j = 0; j < g_seq_len; j++) {
            P[j] = exp(S[j] - max_s);
            sum_exp += P[j];
        }
        for (j = 0; j < g_seq_len; j++)
            P[j] /= sum_exp;

        // O = P × V，O[col] = sum_j P[j] * V[j][col]
        for (i = 0; i < g_dim; i++) {
            double sum = 0.0;
            for (j = 0; j < g_seq_len; j++)
                sum += P[j] * g_V[h][j][i];
            g_O[h][i] = sum;
        }
    }
}

// 比对单个输出元素，返回0=PASS，1=FAIL
// 同时累计MAE/MRE统计
int dpi_e2e_compare(int head, int idx, unsigned int dut_val) {
    if (head >= g_num_heads || idx >= g_dim) return 1;

    float dut_f = bits_to_float_e2e(dut_val);
    double dut_d = (double)dut_f;
    double golden = g_O[head][idx];

    /* 逐位一致统计：PASS 只代表落在5%阈值内，跟"与RTL输出完全对应"是两回事。
       这里单独统计 bit-exact 命中率，用来量化模型离真正逐位精确还差多远——
       目前 exp2 已是位级，但 QK/PV 累加与最后的 O/l 除法仍走 C 浮点，
       所以预期命中率远低于100%。只统计不参与判定。 */
    if (g_golden_mode == E2E_MODE_BITACC) {
        float gf = (float)golden;
        unsigned int gb; memcpy(&gb, &gf, 4);
        g_bitexact_total++;
        if (gb == dut_val) { g_bitexact_hit++; g_ulp_bucket[0]++; }
        else {
            int d = (int)gb - (int)dut_val; if (d < 0) d = -d;
            if (d <= 1) g_within_1ulp++;
            if (d > g_max_ulp_diff) {
                g_max_ulp_diff = d;
                g_worst_golden = golden; g_worst_dut = dut_d;
            }
            /* 误差分布：纯舍入累积应集中在小ULP（1023次加法约√1023≈32ULP），
               若出现大量>1000ULP的项则说明存在系统性偏差而非随机累积 */
            if      (d <= 1)     g_ulp_bucket[1]++;
            else if (d <= 10)    g_ulp_bucket[2]++;
            else if (d <= 100)   g_ulp_bucket[3]++;
            else if (d <= 1000)  g_ulp_bucket[4]++;
            else if (d <= 10000) g_ulp_bucket[5]++;
            else                 g_ulp_bucket[6]++;
        }
    }

    double abs_err = fabs(dut_d - golden);
    double rel_denom = fabs(golden) > 1e-8 ? fabs(golden) : 1e-8;
    double rel_err = abs_err / rel_denom;

    // 累计统计（排除近零值，避免小分母放大MRE）
    if (fabs(golden) >= 0.01) {
        g_compare_total++;
        g_sum_abs_err += abs_err;
        double real_rel = abs_err / fabs(golden);
        g_sum_rel_err += real_rel;
        if (abs_err > g_max_abs_err) g_max_abs_err = abs_err;
        if (real_rel > g_max_rel_err) g_max_rel_err = real_rel;
    }

    // 检查非零非inf
    unsigned int exp_field = (dut_val >> 23) & 0xFF;
    if (dut_val == 0 || exp_field == 0xFF) {
        printf("[E2E] FAIL head%d O[%d]: DUT=0x%08x (zero/inf/nan) GOLDEN=%.6f\n",
            head, idx, dut_val, golden);
        g_compare_fail++;
        return 1;
    }

    // 对接近零的值用绝对误差判定（避免小分母放大）
    if (fabs(golden) < 0.005) {
        if (abs_err > 0.02) {
            printf("[E2E] FAIL head%d O[%d]: DUT=%.6f GOLDEN=%.6f abs_err=%.6f (near-zero)\n",
                head, idx, dut_f, golden, abs_err);
            g_compare_fail++;
            return 1;
        }
        return 0;
    }

    int fail = (rel_err > 0.05);
    int warn = (rel_err > 0.01);

    if (fail) {
        printf("[E2E] FAIL head%d O[%d]: DUT=%.6f GOLDEN=%.6f rel_err=%.4f (%.2f%%)\n",
            head, idx, dut_f, golden, rel_err, rel_err * 100.0);
        g_compare_fail++;
    } else if (warn) {
        printf("[E2E] WARN head%d O[%d]: DUT=%.6f GOLDEN=%.6f rel_err=%.4f (%.2f%%)\n",
            head, idx, dut_f, golden, rel_err, rel_err * 100.0);
        g_compare_warn++;
    }

    return fail;
}

// 打印精度统计报告
void dpi_e2e_report() {
    printf("\n[E2E] ========== ACCURACY SUMMARY ==========\n");
    printf("[E2E] Total comparisons: %d\n", g_compare_total);
    printf("[E2E] Failed (rel>5%%): %d\n", g_compare_fail);
    printf("[E2E] Warned (rel>1%%):  %d\n", g_compare_warn);
    if (g_compare_total > 0) {
        double mae = g_sum_abs_err / g_compare_total;
        double mre = g_sum_rel_err / g_compare_total;
        printf("[E2E] MAE: %.6e\n", mae);
        printf("[E2E] MRE: %.6f (%.4f%%)\n", mre, mre * 100.0);
        printf("[E2E] Max abs err: %.6e\n", g_max_abs_err);
        printf("[E2E] Max rel err: %.6f (%.4f%%)\n", g_max_rel_err, g_max_rel_err * 100.0);
    }
    /* 逐位一致率：回答"模型输出与RTL是否完全对应"。PASS(阈值内)与bit-exact
       是两个概念，这里把后者单独量化出来。 */
    if (g_bitexact_total > 0) {
        printf("[E2E] BITEXACT: %ld/%ld (%.2f%%)  within_1ulp=%ld  max_ulp_diff=%d\n",
               g_bitexact_hit, g_bitexact_total,
               100.0 * (double)g_bitexact_hit / (double)g_bitexact_total,
               g_within_1ulp, g_max_ulp_diff);
        /* 误差分布：纯舍入累积应集中在小ULP（1023次加法约√1023≈32ULP）。
           若长尾延伸到1000+ULP，说明存在系统性偏差而非随机累积。
           同时给出最差项的绝对量级——若golden接近零，巨大的ULP数只是小分母
           的表象（接近零处1 ULP的绝对值极小），真实精度可能远好于ULP计数。 */
        printf("[E2E] ULPDIST exact=%ld le1=%ld le10=%ld le100=%ld le1k=%ld le10k=%ld gt10k=%ld\n",
               g_ulp_bucket[0], g_ulp_bucket[1], g_ulp_bucket[2], g_ulp_bucket[3],
               g_ulp_bucket[4], g_ulp_bucket[5], g_ulp_bucket[6]);
        printf("[E2E] WORST golden=%.9e dut=%.9e absdiff=%.3e\n",
               g_worst_golden, g_worst_dut, fabs(g_worst_golden - g_worst_dut));
    }
    printf("[E2E] =========================================\n");

    // 也打印golden参考值
    int h, i;
    printf("[E2E] === Golden Reference (fp64 standard softmax) ===\n");
    for (h = 0; h < g_num_heads; h++) {
        printf("[E2E] head%d O: [", h);
        for (i = 0; i < g_dim; i++)
            printf("%.4f%s", g_O[h][i], i < g_dim-1 ? ", " : "");
        printf("]\n");
    }
}

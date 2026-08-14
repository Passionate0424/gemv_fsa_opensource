/*
 * silu_dpi.c —— 把 SiLU 的位级模型暴露给 UVM 环境做 golden 对照
 *
 * 为什么 UVM 需要这个：SystemVerilog 侧只能用 $exp 算 fp64 的精确 silu()，
 * 那是"数学真值"，和硬件的 8 段 PWL 近似天然差 4.8e-4，只能做 0.1% 量级的
 * 宽松判定。而 silu_bits() 是逐条转录 RTL 的位级模型，可以做**逐位判定**——
 * 任何一位不同都说明实现有问题，而不是精度问题。两者结合才能把
 * "实现 bug" 和 "近似误差" 分开，这正是模块级调试时的关键手段
 * （tb_silu_unit 上靠它一轮定位了捕获时序和地址错位两个 bug）。
 *
 * 位级模型的原语(exp2_hw/recip_bits/fpmul_bits/fpadd_bits)都已分别对真实
 * 硬件数据验证过逐位一致，实测整条 SiLU 通路 286/288 bit-exact，
 * 剩余 2 个是模型把 ACC_NORM 简化成纯乘法(硬件是 FMA a*b+0)导致的零符号
 * 差异，数值等价。
 */
#include <stdint.h>
#include <string.h>
#include <math.h>

#include "fp_bitlevel.h"

/* 位级 golden：输入输出都是 IEEE754 bit pattern（SV 侧用 int 传递） */
int dpi_silu_bits(int x_bits)
{
    return (int)silu_bits((uint32_t)x_bits);
}

/* fp64 精确参考，用于统计相对误差（信息性指标，不做判定） */
int dpi_silu_ref(int x_bits)
{
    uint32_t xb = (uint32_t)x_bits;
    float xf;
    double r;
    float rf;
    uint32_t rb;

    memcpy(&xf, &xb, 4);
    r  = (double)xf / (1.0 + exp(-(double)xf));
    rf = (float)r;
    memcpy(&rb, &rf, 4);
    return (int)rb;
}

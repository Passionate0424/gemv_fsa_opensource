/*
 * larchintrin.h —— host 编译用的 stub
 *
 * 用途：让 run.c 能在 x86 host 上原样编成本地可执行文件，用于离线跑完整推理、
 *       导出真实激活值分布、以及对比"硬件近似算子是否改变生成的 token"。
 *
 * 为什么用 stub 而不是改 bsp 头文件：`soc/sdk/software/bsp/include/common_func.h`
 * 是上板代码的一部分，不该为了离线评估往里塞 host 分支。交叉编译时工具链自带
 * 的真 larchintrin.h 会优先命中，本文件只在 host 构建显式 -I tools/host_stub
 * 时才参与，两条路径互不干扰。
 *
 * 这里的实现全部返回 0：host 上根本不存在 LoongArch 的 CSR，而离线评估跑的是
 * CPU_ONLY 路径（-DCPU_ONLY_MATMUL=1 -DCPU_ONLY_ATTN=1），不碰这些寄存器。
 */
#ifndef LARCHINTRIN_HOST_STUB_H
#define LARCHINTRIN_HOST_STUB_H

static inline unsigned int __csrrd_w(unsigned int reg)
{
    (void)reg;
    return 0u;
}

static inline unsigned int __csrwr_w(unsigned int val, unsigned int reg)
{
    (void)val; (void)reg;
    return 0u;
}

static inline unsigned int __csrxchg_w(unsigned int val, unsigned int mask, unsigned int reg)
{
    (void)val; (void)mask; (void)reg;
    return 0u;
}

#endif /* LARCHINTRIN_HOST_STUB_H */

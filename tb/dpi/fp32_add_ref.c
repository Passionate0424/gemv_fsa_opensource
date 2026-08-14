#include <stdint.h>

// FP32加法参考模型（用C的float运算）
int fp32_add_c(int a_bits, int b_bits) {
    float a, b, c;
    uint32_t ua = (uint32_t)a_bits;
    uint32_t ub = (uint32_t)b_bits;
    uint32_t uc;
    // 位拷贝到float
    a = *(float*)&ua;
    b = *(float*)&ub;
    c = a + b;
    uc = *(uint32_t*)&c;
    return (int)uc;
}

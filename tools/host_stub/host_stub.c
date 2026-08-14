/*
 * host_stub.c —— 让 run.c 能在 x86 host 上链接成本地可执行文件
 *
 * 用途：离线跑完整推理，用来回答"硬件近似算子会不会改变生成的 token"。
 *       算子级的相对误差再小也只是中间量，唯一有意义的判据是最终输出。
 *
 * 这里只补 bsp 里那几个板级实现（confreg_time.c / common_func.c / uart），
 * 它们在 host 上没有对应物，也不影响 CPU_ONLY 路径的数值结果：
 *   - get_cpu_clock_count : host 上不做周期计时，返回 0 即可（BENCH 统计无意义）
 *   - uart_getchar        : 无串口输入，返回 -1 表示无字符
 *   - RegWrite            : 无 SoC 寄存器可写，空实现
 *
 * 数值路径（matmul / attention / rmsnorm / silu）全部走 run.c 里的纯 C 实现，
 * 与板上 MODE=cpu 完全一致，所以 host 跑出来的 token 序列可以直接和板上对照。
 */

unsigned long get_cpu_clock_count(void)
{
    return 0ul;
}

int uart_getchar(void)
{
    return -1;
}

void RegWrite(unsigned int addr, unsigned int var)
{
    (void)addr;
    (void)var;
}

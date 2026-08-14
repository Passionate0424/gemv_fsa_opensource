#ifndef HW_ACCELERATOR_H
#define HW_ACCELERATOR_H

//-------------------------------------------------
// 寄存器地址偏移量 (Register Offsets)
//-------------------------------------------------
// GEMV模式
#define REG_CTRL_ADDR       0x0000  // Control Register (RW)
#define REG_STATUS_ADDR     0x0004  // Status Register (RO)
#define REG_ERR_CODE_ADDR   0x0008  // Error Code Register (RO)
#define REG_VI_BASE_ADDR    0x0010  // Input Vector (x) Base Address (RW)
#define REG_MI_BASE_ADDR    0x0014  // Input Matrix (w) Base Address (RW)
#define REG_VO_BASE_ADDR    0x0018  // Output Vector (xout) Base Address (RW)
#define REG_ROWS_ADDR       0x0020  // Matrix Rows Count (d) (RW)
#define REG_COLS_ADDR       0x0024  // Matrix Columns Count (n) (RW)

// FSA模式
#define REG_Q_BASE_ADDR     0x0030  // Q向量DDR地址 (RW)
#define REG_K_BASE_ADDR     0x0034  // K矩阵DDR地址 (RW)
#define REG_V_BASE_ADDR     0x0038  // V矩阵DDR地址 (RW)
#define REG_O_BASE_ADDR     0x003C  // O输出DDR地址 (RW)
#define REG_HEAD_DIM_ADDR   0x0040  // head维度 (RW)
#define REG_SEQ_LEN_ADDR    0x0044  // KV序列长度 (RW)
#define REG_KV_STRIDE_ADDR  0x0048  // K/V tile间字节步长 (RW)
#define REG_NUM_HEADS_ADDR  0x004C  // 本趟硬件处理的唯一KV头数(GQA/MQA) (RW)
#define REG_ATTN_SCALE_ADDR 0x0050  // fp32 scale = log2(e)/sqrt(d) (RW)

// 激活函数融合（仅GEMV模式有效）
// 置1后硬件在GEMV结果写回DDR之前，就地把每个元素过一遍 silu(x)=x*sigmoid(x)，
// 复用FSA的4个累加器通道（exp2+FMA+除法）跑7步微程序，无新增算术单元。
// 电平型控制位：一次matmul用完必须清零，否则下一次GEMV会被误加激活。
#define REG_ACT_CTRL_ADDR   0x0058  // [0]=silu_en (RW)

// 权重预取触发（WO，读回恒0；预取状态请读REG_STATUS的[2]/[3]）
// 写1后硬件立刻用当前CSR配置发起一次DMA，把下一次任务的第一块数据搬进权重SRAM，
// CPU这边不阻塞、接着算它的。此时SRAM本就空闲（上一次任务已结束），无需双缓冲。
// 用法：先配全CSR → 写本寄存器 → 干CPU的活 → 只写REG_CTRL的start位启动。
// 注意：预取与start之间不能重写MI_BASE/ROWS/COLS/K_BASE/HEAD_DIM/NUM_HEADS/
// KV_STRIDE，否则硬件判定配置已变、预取作废（安全回退到正常搬运，不会算错）。
#define REG_PF_CTRL_ADDR    0x005C  // [0]=start脉冲 [1]=target

//-------------------------------------------------
// 控制寄存器位定义
//-------------------------------------------------
#define CSR_CTRL_START_BIT  (1 << 0)  // 写1启动
#define CSR_CTRL_MODE_FSA   (1 << 1)  // 0=GEMV, 1=FSA

//-------------------------------------------------
// 激活控制寄存器位定义
//-------------------------------------------------
#define CSR_ACT_SILU_EN     (1 << 0)  // GEMV结果写回前就地过silu()

//-------------------------------------------------
// 预取控制寄存器位定义
//-------------------------------------------------
#define CSR_PF_START_BIT    (1 << 0)  // 写1触发一次预取（脉冲型，不保持）
#define CSR_PF_TGT_GEMV     (0 << 1)  // 目标=GEMV权重首块
#define CSR_PF_TGT_FSA_K    (1 << 1)  // 目标=FSA的K tile 0（head_dim<=32才支持）

//-------------------------------------------------
// 状态寄存器位定义
//-------------------------------------------------
#define CSR_STATUS_BUSY_BIT (1 << 0)
#define CSR_STATUS_DONE_BIT (1 << 1)
#define CSR_STATUS_PF_VALID (1 << 2)  // 预取数据在SRAM里有效
#define CSR_STATUS_PF_TGT   (1 << 3)  // 预取目标 0=GEMV权重 1=FSA的K

#endif // HW_ACCELERATOR_H

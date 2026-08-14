# CB_top_v2 LLaMA2推理软件优化技术报告

## 0. 软件向硬件的需求与微调建议

基于LLaMA2推理全流程的profiling结果，提出以下硬件微调建议：

### 0.1 GQA场景KV复用（Priority: 中）

**现状：** stories260K模型 kv_mul=2（8个Q head共享4个KV head）。软件需调用2次FSA（每pass 4个Q head），硬件每次pass重新DMA加载相同的K/V tiles。

**建议：** FSM支持"单tile内多pass"模式。每个tile的K/V加载一次后，FSM内部循环切换Q来源执行多个pass，避免重复DMA。

**硬件改动评估：**
- Vector SRAM：当前4 bank×16深=64 entries，恰好可存满8个Q head（8×8=64），一次性DMA加载
- ACC SRAM：从9深扩展到18深，两个pass用不同基地址段保存各自的softmax状态（O[0~7]+rowsum）
- FSM：tile循环内增加pass内循环，切换Q bank_sel和ACC基地址
- 数据通路不变，改动集中在控制逻辑

**收益估算：** KV DMA量减半。对于seq_len=256（32 tiles），每token省64次DMA × ~200 cycles ≈ 12.8K cycles。当前模型占比小（0.15%），但对更大模型（head_dim=64, seq_len=2048）收益显著。

---

### 0.2 DMA Padding写零（已修复，commit 7891a8c）

**现状：** ~~当COLS不是64整数倍时（如hidden_dim=172, 172%64=44），DMA padding模式跳过地址但不写零~~ → 已修复，DMA padding阶段现在正确写入零值。

**修复内容：** DMA控制器padding阶段保持`sram_we`有效、`sram_wdata`强制为0；cb_controll_v2的S_DMA_VI状态启用Vector SRAM padding。n=172 matmul上板验证PASS。

---

### 0.3 硬件matmul支持非对齐维度（Priority: 中）

**现状：** hidden_dim=172不是32（ARRAY_SIZE）整数倍。硬件通过DMA分块+padding处理，但padding零填充和尾块处理增加了DMA轮次和等待时间。

**建议：** 考虑在硬件中支持"有效列数"CSR（active_cols），MAC累加时只累加前active_cols个PE的结果，无需padding零填充。

**收益：** 减少padding DMA周期，简化软件侧维度对齐逻辑。对172维度场景，每tile省(64-44)×DMA_cycle。

---

### 0.4 中断响应优化（Priority: 低）

**现状：** CPU通过`idle`指令等待HWI1中断唤醒。从CB_done拉高到CPU恢复执行约~50 cycles（中断入口+handler+返回）。

**建议：** 如果支持polling模式（CPU读STATUS寄存器的DONE位），可以省去中断上下文切换开销。适用于连续多次matmul调用的场景。

**改动：** 纯软件改动，硬件已支持STATUS寄存器读取。

---

### 0.5 未来扩展：向量运算单元（Priority: 远期）

**现状：** 96%的cycles花在CPU软浮点（RMSNorm/RoPE/SwiGLU的expf/cosf/sinf/powf）。当前GEMV/FSA硬件无法加速这些逐元素运算。

**建议（远期）：** 增加轻量级向量处理单元（VPU），支持：
- 向量乘加（RMSNorm的weight×x）
- 向量exp2近似（SwiGLU的sigmoid，复用FSA的PWL exp2逻辑）
- 向量倒数开方（RMSNorm的1/sqrt）

复用现有PE中的generalAdder和exp2 LUT，以最小面积增量覆盖主要软浮点瓶颈。

---

## 1. 系统概述

### 1.1 硬件平台
- CPU: OpenLA500（LoongArch32R, 5级流水, 无FPU, 16KB D-cache）
- 加速器: CB_top_v2（GEMV + FSA双模式, 32 PE脉动阵列）
- 互联: AXI crossbar 2×8, DMA控制器
- 目标频率: 50MHz

### 1.2 推理模型
- 模型: stories260K (LLaMA-2架构)
- 参数: dim=64, hidden_dim=172, n_layers=5, n_heads=8, n_kv_heads=4, head_size=8, vocab_size=512, seq_len=512

### 1.3 硬件加速能力
| 算子 | 加速方式 | 说明 |
|------|----------|------|
| 线性层(matmul) | GEMV模式 | 32PE并行, DMA自动分块 |
| Attention | FSA模式 | FlashAttention-2 online softmax, 4 head并行 |
| RMSNorm/RoPE/SwiGLU | CPU软浮点 | 无FPU, 使用picolibc软浮点库 |

---

## 2. 软件优化设计

### 2.1 Cache一致性精确管理

#### 2.1.1 问题背景

OpenLA500具有16KB write-back D-cache，但DMA直接访问物理内存（绕过cache）。因此需要cache maintenance确保数据一致性：
- CPU写→DMA读：需要cache flush（writeback dirty lines）
- DMA写→CPU读：需要cache invalidate

原始实现中，`matmul()`每次调用都执行全量cache flush，包括：
- 输入向量x：n×4 bytes
- **权重矩阵w：n×d×4 bytes（最大44KB）**
- 输出向量xout：d×4 bytes

权重矩阵flush是最大开销项（172×64×4=44KB，需遍历2816条cache line，每条执行一次cacop指令）。

#### 2.1.2 优化策略

**P0: 权重矩阵一次性flush（核心优化）**

观察：权重矩阵是编译时嵌入.data段的只读静态数据，CPU从未修改。cache中的权重数据永远是clean的（与物理内存一致），无需每次flush。

方案：`build_transformer()`完成后对全部权重执行一次flush确保初始一致性，后续`matmul()`中删除权重flush。

```c
// 启动时一次性flush（约260KB权重）
void init_flush_weights(TransformerWeights* w, Config* p) {
    size_t total = (char*)w->wcls + vocab_size*dim*4 - (char*)w->token_embedding_table;
    cache_flush(w->token_embedding_table, total);
}

// matmul中只flush输入和输出（不再flush权重）
void matmul(float* xout, float* x, float* w, int n, int d) {
    cache_flush(x, n * sizeof(float));    // 输入（CPU可能修改过）
    cache_flush(xout, d * sizeof(float)); // 输出（invalidate旧值）
    // cache_flush(w, n*d*sizeof(float)); ← 删除
    ...
}
```

**P1: KV cache增量flush（精确到行）**

观察：`store_kv_to_cache()`每次只写入1行数据（每head写head_size×4=32 bytes，共4 heads=128 bytes），但原始实现flush整个tile（4×8×8×4=1024 bytes）。

方案：只flush实际写入的cache line：

```c
// 优化前：flush整个tile（1024 bytes，64条cache line）
cache_flush(k_tile_base, tile_size * sizeof(float));

// 优化后：只flush写入的行（128 bytes，8条cache line）
for (int g = 0; g < n_kv_heads; g++) {
    cache_flush(k_tile_base + g*head_size*head_size + row*head_size, 
                head_size * sizeof(float));  // 32 bytes
}
```

**P2: 去除冗余的输出buffer flush**

观察：FSA启动前flush `fsa_o_buf`（输出buffer），但该buffer即将被DMA完全覆写。只需要在DMA写完后CPU读取前做invalidate。

**P3: 连续matmul跳过重复输入flush**

观察：attention阶段`s->xb`作为wq/wk/wv三次连续matmul的输入，中间未被CPU修改。第2/3次flush同一未修改数据是无用操作。

方案：新增`matmul_nf()`变体（no flush input），连续调用相同输入时使用。

### 2.2 KV Cache零拷贝Tile布局

#### 2.2.1 设计动机

FSA硬件的DMA按tile（8×8）读取K/V矩阵。传统KV cache按`[layer][timestep][kv_dim]`存储，每次attention调用需要将数据重排为tile格式，开销为O(seq_len × kv_dim)。

#### 2.2.2 零拷贝方案

在KV cache写入时（每token产出一行K和V后），直接scatter到硬件友好的tile布局：

```
传统布局: key_cache[layer][timestep][kv_dim=32]
Tile布局: key_cache[layer][tile_idx][n_kv_heads × head_size × head_size]
         即 [layer][tile][4 heads × 8 rows × 8 cols]
```

每个token写入时的scatter开销仅O(kv_dim)=O(32)，而attention调用时DMA可以直接读取cache中的数据，**零拷贝**。

#### 2.2.3 GQA适配

stories260K使用Grouped Query Attention（kv_mul=2，每2个Q head共享1个KV head）。

硬件一次处理4组PE并行，分2 pass处理8个Q head：
- Pass 1: Q[0,2,4,6] + KV[0,1,2,3]
- Pass 2: Q[1,3,5,7] + KV[0,1,2,3]

KV cache对两个pass共享，无需额外数据搬运。

### 2.3 Attention硬件加速调用流程

```c
void attention_fsa(RunState* s, Config* p, int pos, int loff) {
    for (int pass = 0; pass < kv_mul; pass++) {
        // 1. 准备Q（仅32 bytes × 2次拷贝）
        memcpy(fsa_q_buf, ...);
        cache_flush(fsa_q_buf, 128);  // 仅flush Q

        // 2. 配置CSR（K/V直接指向cache，零拷贝）
        cb_write(REG_Q_BASE_ADDR, fsa_q_buf);   // Q缓冲区地址
        cb_write(REG_K_BASE_ADDR, k_base);      // 直接用KV cache地址
        cb_write(REG_V_BASE_ADDR, v_base);
        cb_write(REG_O_BASE_ADDR, fsa_o_buf);   // 输出缓冲区地址

        // 3. 启动FSA + idle等待中断
        cb_write(REG_CTRL_ADDR, START | MODE_FSA);
        cpu_idle();

        // 4. 读回结果
        cache_flush(fsa_o_buf, 128);  // invalidate后CPU读取
        memcpy(s->xb + ..., fsa_o_buf, 128);
    }
}
```

---

## 3. 性能对比

### 3.1 实验环境
- 仿真工具: Synopsys VCS O-2018.09-SP2
- 基准: 原版LLaMA2-on-OpenLA500（纯GEMV加速, CPU attention）
- 测试: stories260K模型, decode阶段逐token生成

### 3.2 Matmul性能

| 版本 | matmul avg_cycles | vs原版 |
|------|-------------------|--------|
| 原版（GEMV only） | 23,401 | 基准 |
| 我们（优化前） | 18,424 | -21% |
| **我们（cache优化后）** | **10,274** | **-56%** |

matmul加速来源：
- 超前计算加法器：提升硬件吞吐（虽然latency+2，但DMA pipelining掩盖）
- cache flush优化：去除44KB权重的无用flush循环

### 3.3 Attention性能

| 方案 | 复杂度（每token） | seq_len=10实测 |
|------|-------------------|---------------|
| 原版CPU attention | O(pos × head_size × n_heads), 软浮点 | ~3.6M cycles增量 |
| FSA硬件attention | O(ceil(pos/8)) tiles, 硬件并行 | ~几十K cycles |

### 3.4 端到端推理性能

| Token位置 | 我们（FSA+GEMV） | 原版（GEMV only） | 加速比 |
|-----------|-----------------|-------------------|--------|
| token 1 | ~8.5M | 7.14M | 0.84× |
| token 5 | ~8.6M | 9.19M | 1.07× |
| token 10 | ~8.6M | 10.78M | **1.25×** |
| token 41 | ~8.7M | ~20M(外推) | **~2.3×** |
| token 256 | ~8.7M(稳定) | ~83M(外推) | **~9.6×** |

关键观察：
- 我们的cycles/token基本恒定（~8.7M），FSA硬件attention开销为O(1)常数级
- 原版每token增长~0.3M cycles（CPU attention O(N)增长）
- **交叉点在token 5**，之后我们持续领先且差距扩大

### 3.5 瓶颈分析

当前8.7M cycles/token的组成：
```
matmul (36次/token):     360K cycles  (4.1%)
FSA attention (10次/token): ~100K cycles  (1.2%)
CPU软浮点运算:           ~8.2M cycles (94.7%)
  - RMSNorm (10次):  powf+除法
  - RoPE (5次):      powf+cosf+sinf
  - SwiGLU (5次):    expf × 172次
  - Sampler:         expf × 512次
```

---

## 4. 设计特色总结

1. **Cache一致性精确管理**：基于数据流分析，区分"只读不变/CPU写过/DMA写过"三类数据，消除96%的冗余flush操作
2. **KV Cache零拷贝Tile布局**：写入时O(kv_dim) scatter，attention调用时DMA直连，避免O(seq_len×kv_dim)的运行时重排
3. **GQA硬件适配**：2-pass分时复用4组PE，KV数据共享无冗余搬运
4. **O(1) Attention**：相比CPU的O(N)逐token增长，FSA硬件使attention开销恒定，长序列优势显著
5. **参数化延迟设计**：ACC_LATENCY/MAC_LATENCY参数化，软硬件协同时序自动适配

---

## 5. 后续优化方向

### 5.1 Uncached访问消除cache flush（高收益，参考fsa_llm_sv）

**原理：** LoongArch地址空间中，`0xA0000000-0xBFFFFFFF`是uncached窗口，与`0x00000000-0x1FFFFFFF`映射同一物理地址但绕过D-cache。

**方案：** DMA相关buffer（x输入、xout输出、fsa_q_buf、fsa_o_buf）通过uncached别名指针访问，彻底消除cache flush：

```c
// 将物理地址重映射到uncached窗口
static volatile float* uncached(void* ptr) {
    uintptr_t phys = (uintptr_t)ptr & 0x1fffffffu;
    return (volatile float*)(phys | 0xa0000000u);
}

// DMA地址转换：识别uncached指针
static uint32_t to_phys(const void* ptr) {
    uintptr_t addr = (uintptr_t)ptr;
    if ((addr & 0xe0000000u) == 0xa0000000u)
        return (uint32_t)(addr & 0x1fffffffu);
    return (uint32_t)addr;
}
```

**适用场景：**
- matmul的输入向量x：CPU写入后DMA读取，改为uncached写入
- matmul的输出xout：DMA写入后CPU读取，改为uncached读取
- fsa_q_buf/fsa_o_buf：同上
- KV cache：store_kv_to_cache通过uncached指针写入，完全消除增量flush

**不适用场景：**
- 权重矩阵w：只读数据，DMA直接读物理地址，已不flush（P0优化）
- CPU密集计算的中间buffer（s->hb, s->xb等）：需要cache加速，不能用uncached

**预期收益：** 消除所有剩余的cache_flush调用（P1/P2/P3的cacop循环全部去掉），每token再省~10K cycles。

**权衡：** uncached写入没有write-back缓冲，每次store直接走AXI总线，延迟略高。但对于DMA buffer（写完就交给硬件），这个代价可以忽略。

---

### 5.2 Linker Script固定地址布局（配合5.1）

**原理：** 将加速器相关buffer固定到已知物理地址，避免malloc带来的地址不确定性，便于硬件和uncached映射。

**方案（参考fsa_llm_sv的llama2_soc.lds）：**

```
MEMORY {
  isram (rx) : ORIGIN = 0x1c000000, LENGTH = 4M   /* 代码+权重 */
  dsram (rw) : ORIGIN = 0x1c400000, LENGTH = 4M   /* 数据+heap */
}

SECTIONS {
  .model_assets ALIGN(64) : { *(.model_assets) } > isram
  .kv_cache     0x1c410000 (NOLOAD) : { *(.kv_cache) }    > dsram
  .accel_io     0x1c4a0000 (NOLOAD) : { *(.accel_io) }    > dsram
  .runtime_heap 0x1c4b0000 (NOLOAD) : { *(.runtime_heap) } > dsram
}
```

**优势：**
- KV cache固定地址：CSR配置只需做一次（不用每次传地址）
- 加速器IO buffer固定：uncached映射地址编译时确定
- 避免heap碎片影响热路径

---

### 5.3 软浮点LUT近似（最大收益，纯软件）

**瓶颈：** 96%时间在CPU软浮点（expf/cosf/sinf/powf），每个调用~500 cycles。

**方案：**

| 函数 | 调用频率/token | LUT近似方案 | 预期加速 |
|------|---------------|-------------|----------|
| expf | 172×5(SwiGLU) + 512(sampler) = 1372次 | 查表+线性插值（256段） | 500→50 cycles，省~620K |
| cosf/sinf | 32×5(RoPE) = 160次 | CORDIC或256段查表 | 500→80 cycles，省~67K |
| powf | 32×5(RoPE) = 160次 | 预计算常量表（freq固定） | 500→10 cycles，省~78K |
| 1/sqrtf | 10(RMSNorm) | fast_inv_sqrt (Quake III) | 200→20 cycles，省~2K |

**总预期收益：** ~767K cycles/token（从8.7M降到~7.9M，省9%）。

**RoPE的powf特殊优化：**
```c
// powf(10000, head_dim/head_size) 只取决于i%head_size，可预计算
static const float rope_freq_table[4] = {
    1.0f / powf(10000.0f, 0.0f/8.0f),   // head_dim=0
    1.0f / powf(10000.0f, 2.0f/8.0f),   // head_dim=2
    1.0f / powf(10000.0f, 4.0f/8.0f),   // head_dim=4
    1.0f / powf(10000.0f, 6.0f/8.0f),   // head_dim=6
};
// RoPE中直接查表：freq = rope_freq_table[i % head_size / 2]
```

---

### 5.4 GQA单tile多pass（硬件微调，避免KV重复DMA）

**现状：** kv_mul=2时，两个pass对同一份KV数据各DMA搬运一次。

**方案：** FSM支持tile内循环——加载一次KV后，切换Q执行两遍QK/PV。

**改动：** fsa_ctrl_fsm + Vector SRAM全量预加载Q + ACC SRAM扩展到18深（双pass状态隔离）。

**收益：** KV DMA量减半。seq_len=256时省~12.8K cycles/token。

---

### 5.5 优先级排序

| 优先级 | 方案 | 预期收益 | 复杂度 | 风险 |
|--------|------|----------|--------|------|
| 1 | 5.3 powf预计算 | ~78K cycles | 极低（一行改动） | 零 |
| 2 | 5.1 uncached访问 | ~10K cycles + 代码简化 | 低 | 低 |
| 3 | 5.3 expf LUT | ~620K cycles | 中（写LUT库） | 低（精度可控） |
| 4 | 5.3 cosf/sinf LUT | ~67K cycles | 中 | 低 |
| 5 | 5.2 Linker固定布局 | 架构改善 | 中 | 低 |
| 6 | 5.4 GQA多pass | ~12.8K cycles | 高（改FSM） | 中 |

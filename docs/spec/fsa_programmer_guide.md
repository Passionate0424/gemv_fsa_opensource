# CB_top_v2 硬件加速器 — 软件编程手册

## 1. 概述

CB_top_v2是一个双模式硬件加速器，支持：
- **GEMV模式（OS）：** 通用矩阵-向量乘法，支持大矩阵自动分块
- **FSA模式：** FlashAttention-2前向计算，`O = softmax(Q × K^T × scale) × V`

两种模式共享PE阵列（32个PE，4组×8个），通过CSR的MODE位切换。

---

## 2. CSR寄存器映射

基地址由SoC集成决定，以下为偏移地址。

### 2.1 通用寄存器

| 偏移 | 名称 | 读写 | 描述 |
|------|------|------|------|
| 0x0000 | CTRL | RW | 控制寄存器 |
| 0x0004 | STATUS | RO | 状态寄存器 |
| 0x0008 | ERR_CODE | RO | 错误码 |

**CTRL寄存器位域：**
| Bit | 名称 | 描述 |
|-----|------|------|
| [0] | START | 写1启动，硬件自动清零 |
| [1] | MODE | 0=GEMV模式，1=FSA模式 |

**STATUS寄存器位域：**
| Bit | 名称 | 描述 |
|-----|------|------|
| [0] | BUSY | 1=引擎忙，0=空闲 |
| [1] | DONE | 1=计算完成 |

### 2.2 GEMV模式寄存器

| 偏移 | 名称 | 读写 | 描述 |
|------|------|------|------|
| 0x0010 | VI_BASE | RW | 输入向量DDR基地址 |
| 0x0014 | MI_BASE | RW | 输入矩阵DDR基地址 |
| 0x0018 | VO_BASE | RW | 输出向量DDR基地址 |
| 0x0020 | ROWS | RW | 矩阵行数 |
| 0x0024 | COLS | RW | 矩阵列数 |

### 2.3 FSA模式寄存器

| 偏移 | 名称 | 读写 | 描述 |
|------|------|------|------|
| 0x0030 | Q_BASE | RW | Q向量DDR基地址 |
| 0x0034 | K_BASE | RW | K矩阵DDR基地址 |
| 0x0038 | V_BASE | RW | V矩阵DDR基地址 |
| 0x003C | O_BASE | RW | O输出DDR基地址 |
| 0x0040 | HEAD_DIM | RW | head维度（支持8/16/32/48/64，>32时硬件内部自动拆成两段QK reduction，见4.2/4.5/6.2节） |
| 0x0044 | SEQ_LEN | RW | KV序列长度 |
| 0x0048 | KV_STRIDE | RW | K/V相邻tile间的DDR字节步长 |
| 0x004C | NUM_HEADS | RW | **本趟硬件处理的唯一KV头数（GQA/MQA fanout）**，与HEAD_DIM/SEQ_LEN同级——**FSA启动前必配**，合法值1/2/4（须整除num_active_heads）。硬件不做合法性兜底，直接忠实执行配置值；未配置（复位值0）或非法值会导致block_count计算下溢/结果未定义，详见4.6节 |
| 0x0050 | ATTN_SCALE | RW | Attention缩放因子（fp32格式），复位默认值=0x3F0293EE |
| 0x0054 | GROUP_MODE | RW | FSA分组模式，有效位[1:0]，合法值: 0=4×8, 1=2×16, 2=1×32 |

**ATTN_SCALE说明：**

软件需要预计算 `log2(e) / sqrt(head_dim)` 并以IEEE 754 fp32格式写入。
RTL复位默认值为0x3F0293EE（对应head_dim=8），软件启动前必须根据实际head_dim重新配置。

| head_dim | ATTN_SCALE值 | FP32 hex |
|----------|-------------|----------|
| 8 | 0.51007 | 0x3F0293EE |
| 16 | 0.36067 | 0x3EB8AA3B |
| 32 | 0.25503 | 0x3E8293EE |
| 48 | 0.20825 | 0x3E553B95 |
| 64 | 0.18034 | 0x3E38AA3B |

> 注：硬件当前支持的HEAD_DIM上限是64（QK reduction最多拆两段32宽chunk，受CMP无法
> 暂存中间rowmax这一限制，见6.2节），128不是合法值，此处不再列出。

---

## 3. GEMV模式

### 3.1 功能

计算矩阵-向量乘法：`Y = M × X`

- X: 输入向量（COLS个fp32）
- M: 输入矩阵（ROWS × COLS，行主序）
- Y: 输出向量（ROWS个fp32）

硬件自动处理大矩阵分块（行方向32行/块，列方向64列/块），支持累加。

### 3.2 DDR数据布局

```
VI_BASE: [x0, x1, ..., x_{cols-1}]           共 cols×4 字节
MI_BASE: [M[0][0..cols-1], M[1][0..cols-1], ...]  共 rows×cols×4 字节（行主序）
VO_BASE: [y0, y1, ..., y_{rows-1}]           共 rows×4 字节
```

### 3.3 配置流程

```c
write_csr(VI_BASE, x_ddr_addr);
write_csr(MI_BASE, m_ddr_addr);
write_csr(VO_BASE, y_ddr_addr);
write_csr(ROWS, rows);
write_csr(COLS, cols);
write_csr(CTRL, 0x01);  // MODE=GEMV, START=1

while (read_csr(STATUS) & 0x1);  // 等待完成
```

### 3.4 约束

| 约束 | 值 | 说明 |
|------|-----|------|
| ROWS最大值 | 无限制 | 硬件自动分块（32行/块），实测rows=256正常 |
| COLS最大值 | **511** | 硬件自动分块（64列/块）。DMA的cmd_len/cmd_stride为11-bit（≤2047字节=511个fp32），cols≥512时行间步长(cols×4)溢出11-bit截断，矩阵读址错乱→结果错误。UVM perf_limit_test已验证cols=511 PASS、512 FAIL |
| 地址对齐 | 4字节 | fp32自然对齐 |
| 数据格式 | IEEE 754 fp32 | 单精度浮点 |

---

## 4. FSA模式

### 4.1 功能

计算单query的FlashAttention-2前向：

```
O = softmax(Q × K^T × attn_scale) × V
```

- Q: query向量（最多4个head并行，每head d维；并行head数由GROUP_MODE决定，见4.5节）
- K: key矩阵（同上head数，seq_len × d）
- V: value矩阵（同上head数，seq_len × d）
- O: 输出向量（同上head数，每head d维）

硬件自动将seq_len分tile处理，使用online softmax跨tile rescale。

### 4.2 DDR数据布局

**Q向量（输入）：**
```
Q_BASE + 0:          [head0: d个fp32]
Q_BASE + d*4:        [head1: d个fp32]
Q_BASE + 2*d*4:      [head2: d个fp32]
Q_BASE + 3*d*4:      [head3: d个fp32]
总大小: 4 * d * 4 字节
```

**K矩阵（输入）：**

K/V的每个tile是`r行 × d列`的矩形（行主序），**r和d是两个独立的量**，不要混用：
- `d` = HEAD_DIM，Q/K/V的特征维度（列数），就是CSR里配的那个值（8/16/32/48/64）。
- `r` = 单次tile能处理的最大行数（seq_len方向），硬件固定为`r = min(d, 32)`——
  K/V的DMA硬件一次最多搬32行，HEAD_DIM≤32时`r`刚好等于`d`（两者数值相同，历史上
  这个一直成立，容易被误认为是同一个量）；**HEAD_DIM>32时`r`固定是32，不等于`d`**，
  此时一个tile是`32行×d列`的矩形，不是正方形。

```
K_BASE + tile_j * KV_STRIDE:
  [head0: r×d 行主序]    (r*d*4 字节)
  [head1: r×d 行主序]
  [head2: r×d 行主序]
  [head3: r×d 行主序]
总大小 per tile: num_active_heads * r * d * 4 字节
```

K[head][row][col]的DDR地址（`row`范围`0..r-1`，`col`范围`0..d-1`）：
```
addr = K_BASE + tile_j * KV_STRIDE + head * r*d*4 + row * d*4 + col*4
```

HEAD_DIM>32时，硬件内部会把每行d列的K拆成两段DMA读取（前32列+后`d-32`列，
列数不足32的部分硬件自动补零），但**软件侧DDR布局不变**，仍按上面"`r行×d列`
行主序"摆放完整的d列数据，不需要预先拆分或补零——拆分和补零完全是硬件内部
处理细节，见6.2节供调试参考。

**V矩阵（输入）：** 布局与K完全相同（同样是`r行×d列`，`r=min(d,32)`）。

**O向量（输出）：**
```
O_BASE + 0:          [head0: d个fp32]
O_BASE + d*4:        [head1: d个fp32]
O_BASE + 2*d*4:      [head2: d个fp32]
O_BASE + 3*d*4:      [head3: d个fp32]
总大小: 4 * d * 4 字节
```

**KV_STRIDE：** 相邻tile在DDR中的字节间距。连续存放时：
```
KV_STRIDE = num_active_heads * r * d * 4    // r = min(HEAD_DIM, 32)
```
HEAD_DIM≤32时`r=d`，跟旧公式`4*d*d*4`（4个head时）数值相同；HEAD_DIM>32时
必须用`r=32`，不能再用`d*d`，否则相邻tile的地址会算错。

### 4.3 配置流程

```c
// 1. 预计算attention scale
float attn_scale = log2f(M_E) / sqrtf((float)head_dim);
uint32_t attn_scale_bits;
memcpy(&attn_scale_bits, &attn_scale, 4);

// 2. 配置CSR
int r = (head_dim > 32) ? 32 : head_dim;  // 单tile行数，见4.2节
write_csr(Q_BASE,     q_ddr_addr);
write_csr(K_BASE,     k_ddr_addr);
write_csr(V_BASE,     v_ddr_addr);
write_csr(O_BASE,     o_ddr_addr);
write_csr(HEAD_DIM,   head_dim);          // 8, 16, 32, 48, 或 64
write_csr(SEQ_LEN,    seq_len);
write_csr(KV_STRIDE,  4 * r * head_dim * 4);  // 4个head；HEAD_DIM>32时r=32≠head_dim
write_csr(NUM_HEADS,  num_active_heads);  // 必配！MHA下=num_active_heads（GQA/MQA见4.6节）
write_csr(ATTN_SCALE, attn_scale_bits);   // fp32格式
// GROUP_MODE: head_dim<=32时按需选0/1/2；head_dim>32时只能用2(1×32)
write_csr(GROUP_MODE, (head_dim > 32) ? 2 : group_mode);

// 3. 启动
write_csr(CTRL, 0x03);  // MODE=FSA, START=1

// 4. 等待完成
while (read_csr(STATUS) & 0x1);

// 5. 读取结果
float O[4][head_dim];
memcpy(O, (void*)o_ddr_addr, 4 * head_dim * 4);
```

### 4.4 多head处理（num_heads > 4）

硬件每次处理4个head（GROUP_MODE=4×8模式，NUM_HEADS=4，HEAD_DIM固定为8，
所以下面`d*d`等价于4.2节的`r*d`，不需要区分；HEAD_DIM>32时硬性要求
NUM_HEADS=1，不会用到这种多head分批场景）。软件分批调用：

```c
for (int batch = 0; batch < num_heads / 4; batch++) {
    int offset_q = batch * 4 * d * 4;
    int offset_kv = batch * 4 * d * d * num_tiles * 4;
    int offset_o = batch * 4 * d * 4;

    write_csr(Q_BASE, q_addr + offset_q);
    write_csr(K_BASE, k_addr + offset_kv);
    write_csr(V_BASE, v_addr + offset_kv);
    write_csr(O_BASE, o_addr + offset_o);
    // HEAD_DIM/SEQ_LEN/KV_STRIDE/ATTN_SCALE/GROUP_MODE/NUM_HEADS 沿用4.3节配置，
    // 各批不变时无需重写；每批只有Q/K/V/O_BASE偏移变化
    write_csr(CTRL, 0x03);
    while (read_csr(STATUS) & 0x1);
}
```

### 4.5 约束

| 约束 | 值 | 说明 |
|------|-----|------|
| HEAD_DIM | 8, 16, 32, 48, 64 | ≤32时GROUP_MODE按需选0/1/2匹配GROUP_SIZE；>32时GROUP_MODE只能配2(1×32) |
| 实际并行head数 | 由GROUP_MODE决定：4×8→4个head，2×16→2个head，1×32→1个head | 并行Q组数=`num_active_heads`完全由GROUP_MODE推导，与NUM_HEADS字段无关；HEAD_DIM>32时GROUP_MODE只能是1×32，因此并行head数固定为1（PE阵列全部4组都用于单head的两段QK reduction） |
| NUM_HEADS(kv_heads) | 1 / 2 / 4，须整除num_active_heads，**必须配置** | 本趟DDR摆放的唯一KV头数（GQA/MQA见4.6节）。=num_active_heads时退化为MHA（每组各一份K/V）；<num_active_heads时硬件把一份KV fanout到`ratio=num_active_heads/kv_heads`个连续Q组。合法组合：4×8→{1,2,4}，2×16→{1,2}，1×32→{1}。硬件不做合法性兜底，未配置（复位值0）或非法值直接导致block_count下溢/结果未定义 |
| SEQ_LEN | 1~4095 | 最后tile不满时硬件自动mask |
| SEQ_LEN最大值 | 4095 | `csr_seq_len`仅取低12位参与tile数计算；≥4096会被12位截断（4096→0） |
| SEQ_LEN=0保护 | 直接完成 | seq_len=0（含4096等回绕成0的越界值）时tile数=0，硬件在S_IDLE直接跳S_DONE拉高done，不进FSA流程（避免死锁）；输出无意义，软件不应配置此值 |
| 单tile行数r | min(HEAD_DIM, 32) | K/V DMA硬件一次最多搬32行，与HEAD_DIM列数是独立的量，见4.2节 |
| 地址对齐 | 4字节 | fp32自然对齐 |
| 数据格式 | IEEE 754 fp32 | 单精度浮点 |
| ATTN_SCALE | 必须配置 | 软件预计算log2(e)/√HEAD_DIM |

---

### 4.6 GQA/MQA 支持（KV head fanout）

GQA（Grouped-Query Attention）/ MQA（Multi-Query Attention）中，多个 Q head **共享同一份
K/V**。硬件通过 NUM_HEADS(0x004C) 配置"本趟唯一 KV 头数 `kv_heads`"，实现"一份 KV 从
DDR 只读一次，写 Input SRAM 时广播（fanout）到 `ratio = num_active_heads / kv_heads`
个连续 Q 组"。计算主路径完全不感知——每个 Q 组看到的 K/V 与 MHA 逐字节一致。

**收益：** DDR 的 KV 读带宽下降到 `kv_heads / num_active_heads`（如 4×8 下 kv_heads=2 省
50%，kv_heads=1 省 75%）。decode 阶段瓶颈正是 KV 读带宽，这是 GQA 的核心价值。

**DDR 布局（与 MHA 唯一的区别：每 tile 只摆 `kv_heads` 份，不是 `num_active_heads` 份）：**
```
K_BASE + tile_j * KV_STRIDE:
  [kv_head0: r×d 行主序]    (r*d*4 字节)
  [kv_head1: r×d 行主序]
  ... 共 kv_heads 份 ...
KV_STRIDE = kv_heads * r * d * 4    // r = min(HEAD_DIM, 32)
```

**Q head ↔ KV head 映射（连续分组，与标准 llama GQA 一致）：**
Q head `h` 使用 KV head `h / ratio`。即 kv_heads=2、num_active=4 时：
Q组0,1 → KV0；Q组2,3 → KV1。硬件 fanout 把 DDR 里第 `kvh` 份 KV 广播到
Q组 `{kvh*ratio .. kvh*ratio+ratio-1}`。

**配置差异（相对 4.3 节 MHA 流程，只多/改两行）：**
```c
int ratio    = num_active_heads / kv_heads;   // 每份KV复制到几个Q组
write_csr(KV_STRIDE, kv_heads * r * head_dim * 4);  // 缩小：只摆kv_heads份
write_csr(NUM_HEADS, kv_heads);                      // 新增：告诉硬件本趟唯一KV头数
// Q_BASE 仍摆 num_active_heads 份（Q 不共享），其余寄存器不变
```

**多趟场景（n_heads > num_active_heads）：** 软件按 KV 头分趟，每趟只读
`kv_heads = num_active_heads / kv_mul` 个唯一 KV 头（`kv_mul = n_heads / n_kv_heads`），
用 `K_BASE + pass * kv_heads * r*d*4` 定位本趟起始 KV 头，每趟显式配置
`NUM_HEADS = kv_heads`。参考驱动 `soc/sdk/software/apps/runc_board/run.c` 的
`attention_fsa()`。当参数不满足 fanout 分解条件（`kv_mul > num_active_heads` /
`n_heads < num_active_heads` / `num_active_heads % kv_mul != 0`）时，驱动自动
回退到"每趟读全部 n_kv_heads 头"的旧路径（正确但不省带宽），该路径下一趟仍是
`num_active_heads` 个独立组、`ratio=1`，故显式配置 `NUM_HEADS = n_kv_heads`
（此时数值等于 num_active_heads）。两条路径下 NUM_HEADS 均为必配项，硬件不做
任何兜底。

---

## 5. 算法说明（FSA模式）

硬件实现FlashAttention-2的online softmax算法：

```
对每个并行head h（数量由GROUP_MODE决定，见4.5节）:
  old_m = -inf, old_l = 0, old_O = 0

  对每个tile j (0..num_tiles-1):
    S = Q[h] × K[h][tile_j]^T              // 1×d dot d×r = 1×r（r=min(d,32)，见4.2节）
    local_m = max(S)
    new_m = max(old_m, local_m)
    delta_m = old_m - new_m
    b = exp2(ATTN_SCALE × delta_m)          // rescale factor (PWL 8段近似)
    N = S - new_m                           // shift to max
    P = exp2(ATTN_SCALE × N)               // softmax numerator (PWL 8段近似)，1×r
    local_l = sum(P)
    new_l = b * old_l + local_l
    local_O = P × V[h][tile_j]              // 1×r dot r×d = 1×d
    new_O = b * old_O + local_O
    old_m = new_m, old_l = new_l, old_O = new_O

  O[h] = old_O / old_l                     // 最终归一化，1×d
```

> 注：HEAD_DIM≤32时r=d，S和P的长度跟d相同，跟HEAD_DIM>32时r固定为32是同一套公式
> 的两种数值结果，不是两种算法。

**精度特性：**
- exp2使用8段PWL（分段线性）近似
- 经softmax归一化后，端到端输出相对误差典型 < 5%
- 对极端输入（|ATTN_SCALE × x| > 256），exp2输出精确0（硬件保护）

---

## 6. 硬件内部DMA行为（供调试参考）

### 6.1 GEMV模式

1. DMA读输入向量X到Vector SRAM
2. 循环每个列块：
   - DMA读矩阵块M到Weight SRAM
   - PE阵列计算部分和
   - 累加到partial_sum_buffer
3. DMA写输出向量Y到DDR
4. 循环下一个行块

### 6.2 FSA模式

1. **DMA Q:** 从Q_BASE读取到Vector SRAM（4 bank）
2. **循环每个tile:**
   - **DMA K:** 从K_BASE + tile×KV_STRIDE读取到Input SRAM（32 bank）。HEAD_DIM≤32时
     一次DMA搬完整行；**HEAD_DIM>32时拆成两次DMA**：chunk1搬前32列（无padding），
     chunk2搬后`HEAD_DIM-32`列（列数不足32时DMA自动补零凑满32）。
   - **计算（HEAD_DIM≤32）:** QK → rowmax → subtract → scale → exp2 → rowsum → rescale
   - **计算（HEAD_DIM>32）:** chunk1先做前32维的Q·K部分和（走下行链，暂存进ACC_SRAM
     独立FIFO区，不触碰CMP的rowmax），chunk2再做后32维部分和并读回chunk1暂存值相加，
     得到完整head_dim维的score（走上行链，真正触发CMP的rowmax折算），之后
     rowmax → subtract → scale → exp2 → rowsum → rescale跟HEAD_DIM≤32一致。
   - **DMA V:** 从V_BASE + tile×KV_STRIDE读取到Input SRAM（V不分chunk，一次按
     `min(HEAD_DIM,32)`行 × HEAD_DIM列读完，PV_MAC本身按HEAD_DIM列循环，不受
     32列上限限制）
   - **计算:** PV → accumulate → rescale O
3. **归一化:** O = accumulated_O / rowsum
4. **DMA O:** 从Output SRAM写回O_BASE

**HEAD_DIM>32的硬件约束（供理解原理参考，不影响软件编程接口）：**
- 两段chunk的拆分上限是HEAD_DIM=64（即2×32）——受CMP硬件限制，CMP只能"收到即折算"，
  没有"先收到中间值、不折算、等完整值再折算"的能力，因此最多支持两段拼接，HEAD_DIM
  超过64需要新的CMP设计，当前硬件不支持。
- K/V的DMA硬件本身一次只搬32行（与上面的列数拆分是两个独立约束），所以tile的"行数"
  固定是`min(HEAD_DIM,32)`，不随HEAD_DIM继续增长——这也是为什么4.2节强调DDR布局公式
  里"行数r"和"列数d=HEAD_DIM"不能混用。

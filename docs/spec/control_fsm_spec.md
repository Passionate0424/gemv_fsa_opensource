# 新IP 指令与控制状态机设计

本文是 `新IPspec.docx` 的控制层补充文档，重点说明：
但是本文档未确定启用，只是占位初步拟定。

1. 统一的 CSR / 指令编程模型
2. 顶层 Job FSM 的工作方式
3. GEMV(OS) 与 FlashAttention(WS) 的子状态机
4. DMA 与 Compute 的重叠策略

本文尽量沿用现有 spec 中的术语：

- `Input SRAM: 32 bank x 16b x 64`
- `Vector SRAM: 4 bank x 16b x 64`
- `ACC SRAM: 4 bank x 32b x 8 x 8`
- `Outcome SRAM: 4 bank x 16b x 8 x 4`

并沿用以下架构约定：

- GEMV 走 OS 数据流
- FlashAttention 走 WS 数据流
- `MODE` 描述“算什么”
- `OVERLAP_EN` 描述“怎么跑”

---

## 1. 设计目标

本 IP 的目标不是做一个单一算子加速器，而是做一个可复用的矩阵/注意力协处理器：

- 兼容 OpenLA500 风格的 GEMV 调度方式
- 吸收 FSA 风格的 FlashAttention 在线 softmax 思想
- 允许硬件内部做 DMA/Compute 重叠
- 允许阵列按 `4x8 / 2x16 / 1x32` 进行重构

设计原则如下：

- 软件接口尽量简单，适合 CPU 通过 CSR 配置
- 计算语义与执行策略分离
- 统一描述符优先，避免 GEMV 和 Attention 各自一套重复 CSR
- 所有“是否并行 / 是否重叠”的能力，都必须在硬件能力位和执行策略位中明确体现

---

## 2. 术语

| 术语 | 含义 |
|---|---|
| Job | 一次完整的硬件任务，例如一次 GEMV、一次 attention head tile 处理 |
| Tile | 硬件一次可处理的子块 |
| Group | 32 维阵列的逻辑重构分组，支持 `4x8 / 2x16 / 1x32` |
| Bank | SRAM 的并行访问通道，不等于“矩阵行”或“矩阵列”本身 |
| Descriptor | 一组描述输入/输出张量地址、步长、形状的寄存器 |
| Shadow CSR | 在 `start` 采样时锁存的内部副本，用于当前 job |
| Online Softmax | FlashAttention 的核心思想，不显式存完整 `P`，而是边算边维护 `m/l/O` |
| Overlap | DMA 与 Compute 的重叠执行策略，不属于算子语义本身 |

---

## 3. 总体控制架构

建议采用“三层控制”：

```text
CPU / AXI-Lite
    |
    v
CSR Decode + Shadow Latch
    |
    v
Top Job FSM
    |------------------------|
    |                        |
    v                        v
DMA Controller          Compute Controller
    |                        |
    v                        v
Input/Vector/Outcome SRAM    PE / CMP / ACC / Transposer
```

三层职责如下：

### 3.1 CSR 层

- 负责软件可见配置
- 负责模式、地址、形状、重叠策略配置
- 不负责每拍调度

### 3.2 Job FSM 层

- 负责一次任务的全局流程
- 决定当前是 GEMV 还是 Attention
- 决定当前是加载、计算、写回还是等待

### 3.3 Micro-control 层

- 负责 tile 级别的读写时序
- 负责 PE / CMP / ACC 的具体拍序
- 负责 DMA 与 Compute 是否允许重叠

---

## 4. 统一 CSR 设计

### 4.1 设计原则

统一 CSR 的核心思想是：

- 只保留一套“通用 operand 描述符”
- GEMV 和 Attention 通过 mode 解释同一组字段
- OpenLA500 的 `VI / MI / VO` 作为 GEMV 兼容别名
- Attention 使用 `Q / K / V / O` 作为语义别名

也就是说：

- `MODE=GEMV_OS` 时，`MI` 视为矩阵输入，`VI` 视为向量输入，`VO` 视为输出
- `MODE=ATTN_*` 时，`Q/K/V/O` 视为 attention operand

### 4.2 建议 CSR 分组

#### A. 基础控制寄存器

| 名称 | 位宽 | 作用 |
|---|---:|---|
| `CTRL` | 32 | 启动、复位、模式、重叠开关、输出转换开关 |
| `STATUS` | 32 | busy / done / error / dma_busy / compute_busy |
| `ERR_CODE` | 32 | 错误码 |
| `CAPS` | 32 | 硬件能力只读寄存器 |

#### B. 模式与策略寄存器

| 名称 | 位宽 | 作用 |
|---|---:|---|
| `MODE` | 32 | 任务类型：GEMV / GEMM / ATTN_SCORE / ATTN_VALUE |
| `LAYOUT` | 32 | 阵列分组、OS/WS、转置、repack 策略 |
| `POLICY` | 32 | 是否允许 overlap、是否允许预取、是否允许 ping-pong |

#### C. 通用张量描述符

| 名称 | 位宽 | 作用 |
|---|---:|---|
| `OP0_BASE` | 32 | operand 0 基地址 |
| `OP0_STRIDE` | 32 | operand 0 步长 |
| `OP0_SHAPE` | 32 | operand 0 形状 |
| `OP1_BASE` | 32 | operand 1 基地址 |
| `OP1_STRIDE` | 32 | operand 1 步长 |
| `OP1_SHAPE` | 32 | operand 1 形状 |
| `OP2_BASE` | 32 | operand 2 基地址 |
| `OP2_STRIDE` | 32 | operand 2 步长 |
| `OP2_SHAPE` | 32 | operand 2 形状 |
| `OP3_BASE` | 32 | operand 3 基地址 |
| `OP3_STRIDE` | 32 | operand 3 步长 |
| `OP3_SHAPE` | 32 | operand 3 形状 |

#### D. Attention 专用寄存器

| 名称 | 位宽 | 作用 |
|---|---:|---|
| `ATTN_CFG0` | 32 | `head_dim`, `q_heads`, `kv_heads` |
| `ATTN_CFG1` | 32 | `seq_len`, `tile_seq_len` |
| `ATTN_CFG2` | 32 | `causal_en`, `gqa_en`, `mask_mode` |
| `ATTN_SCALE` | 32 | softmax scale / sqrt(head_dim) |

#### E. GEMV 兼容寄存器别名

| 旧名 | 新名 |
|---|---|
| `VI_BASE` | `OP1_BASE` |
| `MI_BASE` | `OP0_BASE` |
| `VO_BASE` | `OP2_BASE` |
| `ROWS` | `OP0_SHAPE` 中的 row 维 |
| `COLS` | `OP0_SHAPE` 中的 col 维 |

说明：

- 兼容别名只保留软件习惯
- 硬件内部只建议保留一套 canonical 描述符

---

## 5. CSR 位域建议

### 5.1 `CTRL`

建议字段如下：

| 位域 | 名称 | 说明 |
|---|---|---|
| `[0]` | `start` | 写 1 启动一个 job |
| `[1]` | `soft_reset` | 清空当前 job 的内部状态 |
| `[3:2]` | `mode` | 算子模式 |
| `[4]` | `overlap_en` | 允许 DMA/Compute 重叠 |
| `[5]` | `prefetch_en` | 允许下一 tile 预取 |
| `[6]` | `cast_en` | 允许 fp32->fp16 输出转换 |
| `[7]` | `irq_en` | 完成后是否中断 |

### 5.2 `STATUS`

建议字段如下：

| 位域 | 名称 | 说明 |
|---|---|---|
| `[0]` | `busy` | 当前 job 正在运行 |
| `[1]` | `done` | 当前 job 完成，sticky |
| `[2]` | `dma_busy` | DMA 正忙 |
| `[3]` | `compute_busy` | Compute 正忙 |
| `[4]` | `overlap_active` | 当前存在有效重叠 |
| `[8]` | `error` | 错误 sticky 位 |

### 5.3 `CAPS`

建议只读字段如下：

| 位域 | 名称 | 说明 |
|---|---|---|
| `[0]` | `has_overlap` | 支持重叠调度 |
| `[1]` | `has_pingpong` | 支持 ping-pong 缓冲 |
| `[2]` | `has_dual_ctrl` | 支持 DMA/Compute 双控制器 |
| `[3]` | `has_transposer` | 支持阵列入口转置/repack |
| `[4]` | `has_fp16_io` | 支持 fp16 输入/输出 |
| `[5]` | `has_fp32_acc` | 支持 fp32 累加 |

---

## 6. 模式解释

### 6.1 GEMV_OS

目标：参考 OpenLA500 的高吞吐 GEMV 结构，使用 OS 数据流。

解释方式：

- `OP0` = Matrix
- `OP1` = Vector
- `OP2` = Output

适用场景：

- 线性层
- MLP 中的矩阵-向量乘
- 小批量 GEMM 可降维成多次 GEMV

### 6.2 GEMM_OS

目标：在硬件允许时，把 GEMV 扩展为小块 GEMM。

解释方式：

- `OP0` = A matrix
- `OP1` = B matrix / vector block
- `OP2` = C matrix

### 6.3 ATTN_SCORE

目标：计算 `QK^T`，并在线维护 softmax 前状态。

解释方式：

- `OP0` = Q
- `OP1` = K
- `OP2` = score / intermediate

### 6.4 ATTN_VALUE

目标：计算 `P V`，并完成注意力输出累加。

解释方式：

- `OP0` = P or online softmax state
- `OP1` = V
- `OP2` = partial O

### 6.5 OVERLAP

`OVERLAP` 不是 `MODE`，而是策略：

- `MODE` 决定算子语义
- `OVERLAP_EN` 决定执行是否允许重叠

---

## 7. 顶层 Job FSM

顶层 Job FSM 参考 OpenLA500 的“start / busy / done / error”形式，负责整个任务生命周期。

### 7.1 状态列表

| 状态 | 作用 |
|---|---|
| `S_IDLE` | 空闲，等待 start |
| `S_LATCH_CFG` | 锁存 CSR 到 shadow regs |
| `S_VALIDATE` | 检查 mode / shape / addr / align |
| `S_DISPATCH` | 分发到 GEMV 或 ATTN 子 FSM |
| `S_RUN` | 子 FSM 运行中 |
| `S_DRAIN` | 等待残余 DMA / compute / writeback 完成 |
| `S_DONE` | job 完成，done sticky |
| `S_ERROR` | 出错状态，等待软件清除 |

### 7.2 状态转移

#### `S_IDLE`

- 进入条件：复位后或 job 完成后
- 动作：清空临时状态
- 转移：
  - `start=1` -> `S_LATCH_CFG`

#### `S_LATCH_CFG`

- 动作：把 CSR 写入 shadow regs
- 说明：当前 job 使用锁存值，软件后续写 CSR 不影响当前 job
- 转移：
  - 立即 -> `S_VALIDATE`

#### `S_VALIDATE`

检查内容：

- `mode` 是否支持
- `head_dim` 是否与阵列分组兼容
- `seq_len`、`rows`、`cols` 是否非零
- 地址是否对齐
- bank / layout 是否允许当前 mode

转移：

- 合法 -> `S_DISPATCH`
- 非法 -> `S_ERROR`

#### `S_DISPATCH`

- 根据 `MODE` 决定进入 GEMV 或 ATTN 子 FSM
- 同时根据 `OVERLAP_EN` 设置 DMA/Compute 调度策略
- 转移：
  - GEMV -> `S_RUN`
  - ATTN -> `S_RUN`

#### `S_RUN`

- 由子 FSM 具体执行
- 只要子 FSM 未结束，就保持 busy

#### `S_DRAIN`

- 目的：等待最后一拍 compute、最后一拍 DMA、最后一拍写回都完全退休
- 这是避免写回边界问题的关键状态
- 转移：
  - 所有 in-flight 操作完成 -> `S_DONE`

#### `S_DONE`

- `done=1`
- 保持直到软件清除
- 软件写 `CTRL.start` 或 `CTRL.soft_reset` 后可回到 `S_IDLE`

#### `S_ERROR`

- `error=1`
- 保持 sticky
- 软件清除后回到 `S_IDLE`

---

## 8. GEMV 子 FSM

GEMV 子 FSM 主要参考 OpenLA500。

### 8.1 基本流程

```text
Load Vector -> Load Matrix Tile -> Compute -> Store Output -> Next Tile
```

### 8.2 状态列表

| 状态 | 作用 |
|---|---|
| `G_LOAD_VEC` | 加载输入向量到 Vector SRAM |
| `G_LOAD_MAT` | 加载矩阵块到 Input SRAM / Weight SRAM |
| `G_COMPUTE` | 启动 OS 计算 |
| `G_WAIT_COMP` | 等待阵列完成 |
| `G_STORE_OUT` | 写回输出 |
| `G_NEXT_TILE` | 更新 tile / row offset |
| `G_DONE` | GEMV 完成 |

### 8.3 关键行为

#### `G_LOAD_VEC`

- 向量通常只加载一次
- 若分块计算需要多次复用，则保留在 Vector SRAM

#### `G_LOAD_MAT`

- 按 `rows/cols` 分块
- 若 `cols > HW_COLS`，需要多次 col tile
- 若 `rows > HW_ROWS`，需要多次 row tile

#### `G_COMPUTE`

- 触发脉动阵列运行
- 采用 OS 数据流
- 结果写入 ACC / Outcome 路径

#### `G_STORE_OUT`

- 将 fp32 结果转换到 fp16
- 写入 Outcome SRAM
- 再由 DMA 写回主存

### 8.4 与 OpenLA500 的对应关系

| OpenLA500 概念 | 本文对应 |
|---|---|
| `VI_BASE` | `OP1_BASE` |
| `MI_BASE` | `OP0_BASE` |
| `VO_BASE` | `OP2_BASE` |
| `ROWS` | `OP0_SHAPE.row` |
| `COLS` | `OP0_SHAPE.col` |

---

## 9. Attention 子 FSM

Attention 子 FSM 参考 FSA 的 FlashAttention 思想。

### 9.1 基本目标

目标不是把完整 `P` 明确写入 SRAM，而是：

1. 计算 `QK^T`
2. 在线维护 softmax 的中间态
3. 计算 `PV`
4. 输出 fp32 累加结果，最后转 fp16

### 9.2 状态列表

| 状态 | 作用 |
|---|---|
| `A_LOAD_Q` | 加载当前 head / group 的 Q |
| `A_LOAD_K` | 加载 K tile 到 Input SRAM |
| `A_SCORE` | 计算 `QK^T` |
| `A_MASK` | 施加 causal / absolute position mask |
| `A_LSE` | 更新 row_max / row_sum / lse |
| `A_LOAD_V` | 将当前 tile 覆盖为 V |
| `A_VALUE` | 计算 `P V` |
| `A_ACCUM` | 累加 partial O |
| `A_NEXT_HEAD` | 切换到下一头 |
| `A_NEXT_TILE` | 切换到下一 seq tile |
| `A_STORE_OUT` | fp32 -> fp16 后写入 Outcome SRAM |
| `A_DONE` | attention 完成 |

### 9.3 状态解释

#### `A_LOAD_Q`

- Q 通常放在 Vector SRAM
- 对于同组多个 head，Q 可以并行装载
- Q 是 stationary 或半 stationary operand

#### `A_LOAD_K`

- K 进入 Input SRAM
- 采用当前阵列分组所匹配的 bank 组织
- 若硬件带 transposer/repacker，则在阵列入口完成局部重排

#### `A_SCORE`

- 执行 `QK^T`
- 计算每个 token 的 score
- 同时更新 row max

#### `A_MASK`

- 对 causal attention，屏蔽未来 token
- 对绝对位置掩码，按 `pos` / `tile_base` 做比较
- 这一步建议由 CMP / mask generator 完成，而不是软件逐点控制

#### `A_LSE`

- 在线 softmax 的核心状态
- 维护：
  - `row_max`
  - `row_sum`
  - `lse` / reciprocal 辅助值
- `row_max` 一般是小状态，可放在 CMP/寄存器中
- `partial O` 若较大，则放在 ACC SRAM

#### `A_LOAD_V`

- 将 K tile 覆盖为 V tile，或从另一 buffer set 读取 V tile
- 是否允许与 `A_SCORE` 重叠，取决于 `OVERLAP_EN` 和 bank/ping-pong 能力

#### `A_VALUE`

- 执行 `P V`
- 不显式存完整 `P`，而是使用在线 softmax 得到的权重流

#### `A_ACCUM`

- 更新 partial O
- 若采用 4 组并行，每组可维护自己的 accumulator slice

#### `A_STORE_OUT`

- `ACC` 中的 fp32 输出经 cast unit 转 fp16
- 写入 Outcome SRAM

### 9.4 Attention 的关键约束

| 约束 | 说明 |
|---|---|
| 不显式存完整 P | 避免额外 SRAM 占用 |
| row_max 不是大容量状态 | 更适合放 CMP / 寄存器 |
| partial O 可能需要 ACC SRAM | 取决于 tile 大小和并行 head 数 |
| V 阶段必须与 K 阶段解耦 | 便于重叠和 ping-pong |

---

## 10. Overlap 策略

### 10.1 原则

`OVERLAP_EN` 允许硬件在资源不冲突时重叠执行：

- DMA 预取下一 tile
- Compute 执行当前 tile
- Store 写回上一个 tile

### 10.2 推荐的重叠优先级

1. `DMA prefetch next tile` 与 `Compute current tile`
2. `Store current result` 与 `Prefetch next job`
3. `Load V` 与 `Softmax tail`

### 10.3 不建议的重叠

- 同一 bank group 的读写冲突
- 同一 ACC slice 的双写冲突
- 两个 compute slice 同时抢同一组控制信号

### 10.4 硬件要求

若要支持 overlap，至少需要以下之一：

- A/B ping-pong buffer set
- bank 级双端口或等效读写隔离
- 入口 repacker / transposer 有独立缓冲

---

## 11. DMA / Compute 调度规则

### 11.1 GEMV

- 向量优先加载一次
- 矩阵按 tile 加载
- 计算后直接写 Output

### 11.2 Attention

推荐顺序：

1. 加载 Q
2. 加载 K tile
3. 计算 score
4. 软最大化中间态
5. 加载 V tile
6. 计算 value
7. 累加 partial O
8. 下一 tile / 下一 head

### 11.3 重叠规则

| 当前阶段 | 可重叠阶段 | 条件 |
|---|---|---|
| `A_SCORE` | 预取下一 `K` | bank 不冲突或 ping-pong 可用 |
| `A_VALUE` | 预取下一 `V` | K/V 资源分离 |
| `A_STORE_OUT` | 预取下一 job 的 `Q` | 输出与输入通道独立 |

---

## 12. 软件编程顺序

软件建议按如下顺序配置：

1. 写 `MODE`
2. 写 `LAYOUT / POLICY`
3. 写 `SHAPE`
4. 写各 operand descriptor
5. 写 `ATTN_CFG` 或 GEMV 兼容字段
6. 置 `CTRL.start = 1`
7. 轮询 `STATUS.busy`
8. 读取 `STATUS.done` 或 `STATUS.error`

### 12.1 GEMV 例子

```text
MODE = GEMV_OS
OP0 = Matrix
OP1 = Vector
OP2 = Output
ROWS = M
COLS = N
start = 1
```

### 12.2 Attention 例子

```text
MODE = ATTN_SCORE / ATTN_VALUE / ATTN_FULL
Q_BASE = ...
K_BASE = ...
V_BASE = ...
O_BASE = ...
HEAD_CFG = head_dim, q_heads, kv_heads
SEQ_CFG = seq_len, tile_seq_len
POLICY.overlap_en = 1 or 0
start = 1
```

---

## 13. RTL 实现建议

建议 RTL 模块按以下职责拆分：

- `csr_decode`
  - 负责寄存器译码、shadow latch
- `job_fsm`
  - 负责顶层状态机
- `gemv_ctrl`
  - 负责 GEMV tile 调度
- `attention_ctrl`
  - 负责 attention tile 调度
- `dma_sched`
  - 负责 DMA 发起与完成跟踪
- `overlap_mgr`
  - 负责是否允许并行执行
- `layout_gen`
  - 负责 bank / group / transpose / repack 控制
- `cast_unit`
  - 负责 fp32 -> fp16 输出转换

---

## 14. 需要重点审核的风险点

1. `MODE` 与 `OVERLAP_EN` 不要混写
2. `row_max / row_sum` 不要当成大容量 SRAM 状态
3. 不要在 DMA 仍占用 Input SRAM 时强行启动同 bank 计算
4. `start` 采样后，当前 job 必须使用 shadow regs
5. `done` / `error` 必须是 sticky 位，直到软件清除
6. `P` 不建议显式落 SRAM
7. `cast` 必须在写 Outcome SRAM 前完成

---

## 15. 推荐的第一版实现边界

第一版建议只实现以下能力：

- GEMV_OS
- ATTN_SCORE + ATTN_VALUE
- 4x8 / 2x16 / 1x32 分组
- fp32 accumulator
- fp16 input/output
- 可选 overlap 开关

暂不建议第一版就做：

- 任意尺寸 GEMM
- 任意复杂的多级预取编排
- 全通用双控制器任意发射

这样可以先把主路径跑稳，再逐步增强调度自由度。


# PE 可重构微架构与 4 拍 MAC 流水改造方案

适用范围：

- `workspace/gemv_fsa/rtl/PE/PE.sv`
- `workspace/gemv_fsa/rtl/PE/FPMacUnit.sv`
- `workspace/gemv_fsa/rtl/PE/RawFloat_FMA.sv`
- `workspace/gemv_fsa/rtl/PE/RawFloat_MulAddExp2.sv`
- 参考实现：`workspace/gemv_fsa/rtl/PE_core.v`
- 当前复制验证目标：`workspace/gemv_fsa/rtl/PE_core_new.v`

本文目标不是再做一套并行 MAC，而是在**复用现有资源**的前提下，把 `workspace/gemv_fsa/rtl/PE/PE.sv` 按阵列中**单个 PE**的角色改造成一个可在 WS / OS 之间切换的数据通路，并把原来的纯组合 FMA 改成**内部打拍流水**，使其时序契约对齐 `PE_core.v` 中单个 `fp_mac_pipelined_acc` 的 `MAC_LATENCY=4`。

---

## 1. 目标

1. 复用一套 MAC 资源，不并行例化两套计算核。
2. 让 WS / OS 共用同一条 MAC 延迟契约。
3. 把关键组合路径切进 `RawFloat_FMA` / `RawFloat_MulAddExp2` 内部。
4. 让外部通过一个模式控制信号切换数据流。
5. 保持 `PE.sv` 的端口语义尽量兼容现有 mesh 连接方式，使其可作为阵列中单个 PE 原位替换 `fp_mac_pipelined_acc` 的实现基座。

---

## 2. 现状判断

### 2.1 `PE.sv` 现状

- 当前 `FPMacUnit` 是一次性纯组合计算。
- `reg_sign/reg_exp/reg_mantissa` 只是一组本地状态寄存器。
- `io_in_ctrl_bits_mac / acc_ui / load_reg_* / update_reg / exp2` 仍按当前拍直接参与选择。
- `io_out_ctrl_*` 直接透传，没有内部延迟对齐。

### 2.2 `RawFloat_FMA` 现状

`RawFloat_FMA` 里包含了完整的重组合路径：

- exponent 计算
- `ShiftRightJam`
- add/sub
- `lzc`
- normalization
- rounding / pack

这条路径太长，单纯在 `FPMacUnit` 外围加寄存器，不能真正缓解关键路径。

### 2.3 `PE_core.v` 参考意义

`PE_core.v` 已经把阵列里单个 PE 的 MAC 时序定义成 `MAC_LATENCY=4`。

因此这次改造的正确目标不是“WS 仍然 1 拍”，而是：

- WS 和 OS 都进入同一条 4 拍 MAC 契约
- 只是端口的语义映射不同

补一句容易混淆的边界：
- 这里的 `MAC_LATENCY=4` 是 `PE_core` / `fp_mac_pipelined_acc` 这一层的 PE 契约
- 所以下面的 4 拍对齐示意，描述的是 **单个 PE 的 MAC 级 4-cycle contract**，不是把底层乘法器误写成 4 拍

---

## 3. 总体策略

### 3.1 不做的事

- 不在 `PE.sv` 里同时例化 `FPMacUnit` 和 `fpmul_seq_pipeline/fpadd_seq`。
- 不只在模块最外层补寄存器来假装降时序。
- 不允许 mode 在流水中间随意跳变。

### 3.2 要做的事

- 在 `RawFloat_FMA` / `RawFloat_MulAddExp2` 内部加流水切片。
- 在 `FPMacUnit` 外围加 token / valid 对齐链。
- 在 `PE.sv` 内部把 operand capture、mode latch、result select 分开。
- 把 `acc_ui / update_reg / exp2` 等控制量在 issue 拍锁存为 token，并跟随 MAC 数据走完整个 4 拍流水。
- 对 OS 模式，外部只保留全局 `mode_sel` 与最小事务入口；其中 `io_u_input` 作为 `vec_in / b` 入口，并新增独立 `partial_sum_in` 与 `rst_acc` 接口用于 accumulator seed，真正进入 MAC 的 `c` 为内部 `reg_*`，其余细粒度控制语义由 PE 内部按固定模板生成，不再逐拍依赖外部 micro-op。
- 对 WS 模式，保留原版 `PE.sv` 的控制解释，只是把结果提交点后移到 4 拍对齐的位置。

### 3.3 模式定义

建议增加一个外部 `mode_sel`，并在 job / tile 边界锁存成 `mode_q`：

- `mode_sel = 1'b0`：WS
- `mode_sel = 1'b1`：OS

该信号不建议每拍乱跳，并应在流水排空前保持稳定。

模式职责进一步收敛为：

- `mode_q` 只负责 WS / OS 语义分流，不占用 MAC 的 4 拍延迟预算。
- `WS`：继续沿用外部 `acc_ui / update_reg / exp2 / flow_*` 的控制语义，只是结果/回写后移到 commit 点。
- `OS`：外部不再逐拍驱动算术路径选择，`acc_ui / update_reg / exp2 / exp2Done / flow_*` 由 PE 内部根据 `mode_q + issue token + 固定数据流模板` 自动生成；仅保留 `rst_acc + partial_sum_in` 作为 accumulator seed 合同。
- `mode_q` 本身不是 token，不需要跟着 4 拍流水移动。

---

## 4. 代码修改方案

### 4.1 `RawFloat_FMA.sv`

这是最关键的改动点。

建议把当前单拍组合逻辑拆成 3 个内部切片：

1. **预处理切片**
   - `prodExp`
   - `prodSign`
   - `prodIsZero`
   - `doSub`
   - `expDiff`
   - `alignShiftAmt`
   - 特殊值判定的早期结果

2. **对齐 / 求和切片**
   - `ShiftRightJam`
   - `add/sub`
   - `adderOutAbs`
   - `cAnchored`
   - `pAnchoredIsZero`

3. **归一化 / 舍入切片**
   - `lzc`
   - normalization
   - rounding
   - exp / mantissa pack
   - `isZero / isInf / isNaN / sign` 最终输出

要求：

- 模块外部接口尽量不变。
- 内部寄存器只承担流水切片，不引入新的功能分支。
- 每一级只保留下一阶段真正需要的中间量，避免无意义扩散。

### 4.2 `RawFloat_MulAddExp2.sv`

这个 wrapper 负责把 `exp2` 路径和普通 FMA 路径对齐。

建议改动：

- `io_in_exp2` 不能旁路到最终输出。
- `RawFloat_SplitIF` 的结果需要进入同一条 token 链。
- `io_exp2_frac_msb` 要和主 MAC 结果保持同样的延迟。

简单说：

- `exp2` 是一个 sideband，不是例外路径。
- 只要主 MAC 是 4 拍，`exp2` 相关输出也必须跟着 4 拍。

### 4.3 `FPMacUnit.sv`

建议把 `PE.sv` 的 MAC 路径定义成 **单个 PE（即 `fp_mac_pipelined_acc` 级）内部 4 级流水壳**，把 4 拍延迟完整归属到 MAC 单元内部。外层 `PE.sv` 只负责 mode / ctrl 锁存和输入选择，不再把数据寄存职责算在 PE 外层边界里。

**4拍层级划分原则**（对齐 `fp_mac_pipelined_acc_new` 结构）：

| Stage | 所属位置 | 主要功能 | 说明 |
|---|---|---|---|
| S0 | `FPMacUnit` 入口 | `a/b` 输入采样，`acc_reg` 反馈选择 | 输入寄存 + 累加器组合反馈 |
| S1 | `RawFloat_FMA` 内部 | 乘法第1拍：部分积生成与指数预处理 | 对应 `fpmul_seq_pipeline` 第1级 |
| S2 | `RawFloat_FMA` 内部 | 乘法第2拍：乘法结果输出 + 对齐准备 | 对应 `fpmul_seq_pipeline` 第2级 |
| S3 | `RawFloat_FMA` 内部 | 加法第1拍：对齐/求和 + 归一化/舍入/输出 | 对应 `fpadd_seq` |

**与 `fp_mac_pipelined_acc_new` 的对照**：

| 本方案 Stage | 对应模块 | 对应操作 | 延迟 |
|---|---|---|---|
| S0 | `FPMacUnit` | `weight_reg <= weight_in`, `vec_reg <= vec_in` | 1拍 |
| S1 | `RawFloat_FMA` 乘法第1级 | 部分积生成、指数相加 | 1拍 |
| S2 | `RawFloat_FMA` 乘法第2级 | 乘法结果输出 | 1拍 |
| S3 | `RawFloat_FMA` 加法级 | 对齐、加减、归一化、舍入 | 1拍 |
| **总计** | - | - | **4拍** |

**RawFloat_FMA 内部流水切分**：

- **S1（乘法第1级）**：`prodExp`计算、`prodSign`、`prodIsZero`、`doSub`、`expDiff`、`alignShiftAmt`、部分积
- **S2（乘法第2级）**：乘法结果输出、`ShiftRightJam`准备
- **S3（加法级）**：`add/sub`、`adderOutAbs`、前导零计数`lzc`、归一化、舍入、最终打包

**累加器反馈环路（OS模式关键）**：

参考 `fp_mac_pipelined_acc_new` 的设计，累加器采用**组合反馈**而非寄存器反馈：

```verilog
// S3 输出的加法结果立即反馈到 S0 的 c 输入（下一拍生效）
always @(*) begin
    if (rst_acc)      acc_reg = partial_sum_in;  // 装入初值
    else              acc_reg = adder_out;        // 反馈上一拍结果
end
```

- `acc_reg` 是**组合赋值**，其值在 S3 加法器输出后立即更新
- 下一拍 S0 采样时，`acc_reg` 已经是上一拍的累加结果
- 这样实现真正的流水累加：每拍都能启动一个新的 `a*b + acc_reg`

控制信号也必须同链 retime：

- `pipe_valid`
- `pipe_mode`
- `pipe_acc_ui`
- `pipe_update_reg`
- `pipe_exp2`

建议在这里明确一条原则：

- **`FPMacUnit` 的可见延迟就是 4 拍：S0（FPMacUnit入口）+ S1-S3（RawFloat_FMA内部，2拍乘法+1拍加法）**
- **PE 外层若还有 mode latch 或输入 mux，不计入这 4 拍的数据通路预算**
- **累加器反馈发生在 S3→S0 之间，是组合路径，不增加额外延迟**

### 4.4 `PE.sv`

这是模式切换和端口复用的落点。

建议改动分四部分：

#### 4.4.1 operand 边界下沉

不建议把现有 `reg_*` 再解释成两个外层 operand bank。更合理的边界是：

- `PE.sv` 只保留模式锁存、输入复用和最小控制整形
- 原来的数据寄存职责下沉到 `FPMacUnit` 内部的 `S0` 入口寄存和必要的反馈寄存

也就是说：

- `reg_*` 不应作为 PE 外层的架构名词继续扩张
- 如果保留这些信号名，更适合把它们视作 MAC 单元内部的 pipeline state

#### 4.4.2 mode-aware 输入选择

建议按模式解释端口：

- WS：
  - `l_input` / `reg_*` 作为左侧输入（**已驻留，直连 MAC `a`**）
  - `u_input` 作为上侧输入（**流动数据，S0 采样进 MAC `b`**）
  - `d_input` 或外部输入作为加数（**S0 采样 + 3拍延迟进 MAC `c`**，与 S3 乘法结果对齐）
  - `d_output` 由控制逻辑决定承载下行流动或 MAC 结果
  - `u_output` 由控制逻辑决定承载上行回送或 MAC 结果

- OS：
  - `l_input` 作为权重/驻留侧输入，对应 MAC 的 `a`
  - `u_input` 作为向量/流动侧输入，对应 MAC 的 `b`
  - 新增 `partial_sum_in` 作为 accumulator seed 输入，用于装载内部 `reg_*`
  - 新增 `rst_acc` 作为 seed 装载脉冲，只在 OS 模式下生效
  - 真正进入 MAC 的 `c` 为内部 `reg_*`
  - `u_output` 作为结果/回写侧输出，承载 MAC 返回值

重点是：

- 选择发生在 MAC 入口的轻量组合 mux
- 真正的寄存与时序切片属于 `FPMacUnit` 内部
- 不要把 mode 选择放进最重的 FMA 组合路径里

对应到控制位时，可以直接理解成：

- `load_reg_li` = 捕获 `l_input` 进入 MAC 内部 `reg_*` 驻留寄存器（**提前加载，后续直连**）
- `load_reg_ui` = 捕获 `u_input` 进入 MAC 内部入口寄存器 S0（**流动数据采样**）
- 在 WS 里，`reg_*` 作为驻留侧数据**直连** MAC `a`，`u_input` 采样后进 MAC `b`
- **关键：WS 模式下外部 `c` 输入需要 3 拍延迟才能与 S3 乘法结果对齐**（S0 采样 → S1 → S2 → S3 使用）
- 在 OS 里，`partial_sum_in` 只负责 seed 内部 accumulator，真正的 `c` 是 `acc_reg` 反馈
- `rst_acc` 是 OS 专用 seed 脉冲；`load_reg_ui` 不再承载这层语义

补一个容易漏的边界：

- `d_output` / `u_output` 都是方向口，不要写死成单一语义
- 它们在 flow 事务里承载 vec 传播，在 MAC 事务里承载 commit 后结果
- 真正需要固定的是“哪一拍、由什么控制、哪个方向口发出哪类数据”，而不是把某个端口永久绑死成流动或结果

#### 4.4.3 控制量 retime

以下控制量不能再直接拿当前拍的值去驱动最终 MAC 输出：

- `mac`
- `acc_ui`
- `update_reg`
- `exp2`
- `exp2Done`

建议做法：

- 用一条 `token` shift register 跟随 MAC 结果走完整个流水
- 这条 token 链应放在 `FPMacUnit` 内部，和 S0-S3 同步
- `acc_ui`、`update_reg`、`exp2` 作为 sideband 一起 retime
- `exp2Done` 和 `reg_*` 应在 commit 同拍写回，不额外引入架构上的 T5
- 对 OS 模式，上述 sideband 的外部采样只是兼容入口，真正生效的控制语义由内部 token 派生，不再依赖外部逐拍输入。

#### 4.4.4 bypass 与 MAC 分离

保留非 MAC 的直通流：

- `flow_lr`
- `flow_ud`
- `flow_du`

但是要把规则写清楚：

- 纯 bypass 事务可以继续低延迟
- 只要进入 MAC，就按 4 拍 token 对齐

#### 4.4.5 端口与控制映射

建议把 `PE` 的几何端口解释固定下来，避免把 `load_reg_*` 误写成外层独立 operand bank：

| 信号 | 建议语义 | 说明 |
|---|---|---|
| `io_l_input` | 权重/驻留侧输入 | 对应 MAC `a`，保留原 WS 端口语义 |
| `io_u_input` | 向量/流动侧输入 | 对应 MAC `b`，OS 模式下与 `partial_sum_in` 配对计算 |
| `io_d_input` | 下侧兼容/WS 输入 | 保留原版 `PE.sv` 的 `d_input` 语义；OS 主 MAC 数据流不再依赖它 |
| reg_* | 内部寄存器 | OS模式下作为acc_reg输入MAC的c值 |
| `partial_sum_in` | OS 累加输入 | 对应更新 PE.sv 内部的 `reg_*`，OS 模式下作为累加初值输入 |
| `rst_acc` | OS seed 脉冲 | 触发 `partial_sum_in -> reg_*` 装载，只在 OS 模式下生效 |
| `io_d_output` | 下侧流动链主口 | 承担 32x1 纵向阵列中的 vec 向下传递，不承载 MAC commit 结果 |
| `io_u_output` | MAC 结果链/回送口 | 承担 4 拍后返回的 MAC 结果契约，最终物理绑定按阵列方向决定 |
| `io_r_output` | 右侧兼容输出 | 保留横向兼容通路，最终 32x1 例化中大概率不作为主链使用 |
| `load_reg_li` | WS 左侧 capture | 保留原版 `PE.sv` 的左侧捕获语义 |
| `load_reg_ui` | WS 上侧 capture | 保留原版 `PE.sv` 的上侧捕获语义；OS 下不再作为 `c` 入口选择 |
| `mac` | MAC launch | 启动一笔 4 拍 MAC 事务 |
| `acc_ui` | WS 结果路由选择 | 决定当前 MAC 结果落到 `u_output` 还是 `d_output` |
| `update_reg` | 结果提交 | 仅在 MAC 结果对齐后提交内部状态；OS 下由固定模板驱动 |
| `exp2` | 特殊运算命令 | 也必须走同一条 4 拍 token 链 |

这里要特别强调：

- `load_reg_ui` 不是“多出一套 PE 外层寄存器”
- 它只是 `u_input` 在 MAC 内部入口 `S0` 的采样使能
- `load_reg_li` 也是同理，只是对应 `l_input`
- WS / OS 的差别来自控制器如何安排输入 lane 的语义，而不是修改 bundle 结构
- 在 OS 模式下，`acc_ui / update_reg / exp2 / flow_*` 的外部取值只作为兼容入口或观测信息，不能再作为数学路径的主决定因素。
- 在 WS 模式下，上述控制位仍保持原版 `PE.sv` 的功能语义，只是提交点后移到 4 拍对齐位置。

#### 4.4.7 exp2 功能流水线适配

`exp2` 是 FlashAttention 算法中的关键操作，需要与 MAC 数据流保持一致延迟。

**当前实现**：
- `io_in_cmd` 控制 exp2 模式选择
- `RawFloat_SplitIF` 从输入 `a` 提取 `io_exp2_frac_msb`（3位小数部分）
- `io_in_c_exp[3:1]` 与 `io_exp2_frac_msb` 比较，产生 `io_out_exp2`

**流水线改造要求**：

| 信号 | S0 | S1 | S2 | S3 | 说明 |
|---|---|---|---|---|---|
| `io_in_c_exp[3:1]` | 采样 | 传递 | 传递 | **比较** | 延迟3拍后与 `exp2_frac_msb` 对齐 |
| `io_exp2_frac_msb` | - | SplitIF产生 | 传递 | **使用** | 从S1开始，延迟到S3 |
| `io_in_cmd` (exp2) | 采样 | 传递 | 传递 | **使用** | 控制比较使能 |

**实现要点**：

1. **`io_in_c_exp[3:1]` 的延迟链**：
   - S0 采样 `io_in_c_exp[3:1]` 到寄存器
   - S1-S2 传递
   - S3 与 `io_exp2_frac_msb` 比较

2. **`io_exp2_frac_msb` 的产生与延迟**：
   - S1：`RawFloat_SplitIF` 从输入 `a` 提取 `io_exp2_frac_msb`
   - S2-S3：随数据流水传递
   - S3：用于最终比较

3. **最终比较（S3）**：
   ```verilog
   io_out_exp2 = pipe_exp2_s3 & (pipe_c_exp_s3[3:1] == pipe_exp2_frac_msb_s3);
   ```

4. **`exp2Done` 的生成**：
   - `exp2Done` 不是组合输出，而是跟随 token 链的寄存器
   - 在 S3 拍置位，与 MAC 结果同时可见
   - 需要显式清除条件（reset、job边界、mode drain）

建议把一次 MAC 事务的节拍写成下面这样，**特别强调累加器反馈发生在 S3→S0 的组合路径**：

```
时钟:     T0        T1        T2        T3        T4        T5
          ├─────────┼─────────┼─────────┼─────────┼─────────┤
S0:       a0,b0     a1,b1     a2,b2     a3,b3     ...
                    ↑         ↑         ↑         ↑
S1:                 a0,b0     a1,b1     a2,b2     ...
                              ↓         ↓         ↓
S2:                           a0,b0     a1,b1     ...
                                        ↓         ↓
S3:                                     a0*b0+acc0 → acc_reg
                                        ↑___________│ (组合反馈)
```

**OS 模式流水累加示例**（`rst_acc` 在 T0 装入初值）：

| Cycle | S0 采样 | S1 | S2 | S3 计算 | acc_reg 值 |
|---|---|---|---|---|---|
| T0 | a0,b0,c0=partial_sum | - | - | - | partial_sum (rst_acc=1) |
| T1 | a1,b1,c1=acc_reg | a0,b0 | - | - | 等 T3 后 = a0*b0+partial_sum |
| T2 | a2,b2,c2=acc_reg | a1,b1 | a0,b0 | - | 同上 |
| T3 | a3,b3,c3=acc_reg | a2,b2 | a1,b1 | a0*b0+partial_sum | **更新为累加结果** |
| T4 | a4,b4,c4=acc_reg | a3,b3 | a2,b2 | a1*b1+(a0*b0+partial_sum) | 再次更新 |

关键点：**S3 加法器输出组合反馈到加法器 B 输入（`acc_reg`），下一拍加法器采样时 B 输入已是上一拍累加结果，实现流水累加**。

**与 `fp_mac_pipelined_acc_new` 的对照**：

| 本方案 | `fp_mac_pipelined_acc_new` | 说明 |
|---|---|---|
| S0 (FPMacUnit) | `weight_reg/vec_reg` 采样 | 输入寄存 |
| S1 (RawFloat_FMA) | `fpmul_seq` 第1拍 | 乘法部分积 |
| S2 (RawFloat_FMA) | `fpmul_seq` 第2拍 | 乘法结果输出 |
| S3 (RawFloat_FMA) | `fpadd_seq` | 加法 + 归一化 |
| acc_reg 组合反馈 | `acc_reg = add_out_wire` | 立即反馈，下一拍生效 |

4拍延迟约定（从采样到结果可见）：

| 节拍 | PE 外层控制 | MAC 内部动作 | 累加器状态 | 可见结果 |
|---|---|---|---|---|
| T0 | `valid + mac (+ rst_acc if seed)` | S0 采样 `l_input/u_input`；若 `rst_acc=1` 则 `partial_sum_in → acc_reg` | acc_reg = 初值 | 无 |
| T1 | 继续发下一笔 | S1 预处理 | acc_reg 保持 | 无 |
| T2 | 继续发下一笔 | S2 对齐/求和 | acc_reg 保持 | 无 |
| T3 | 继续发下一笔 | S3 归一化/舍入，产生 `adder_out` | acc_reg 更新为 `adder_out` | 无 |
| T4 | `update_reg` 或消费结果 | - | acc_reg 已是新值 | MAC 结果可见 |

**T4 是结果对外可见的时刻**：
- 如果在 T4 采样 `result`，看到的是 T0 发起的事务结果
- `reg_*` / `exp2Done` 在 T4 时刻已更新（由 T3 的 S3 输出驱动）
- 真正的延迟是 T0→T4 这 **4 个周期**

### 4.5 顶层控制入口

如果当前顶层还没有 `mode_sel`，建议在控制层补一个轻量的 mode 位：

- 可以来自 `cb_controll.v`
- 也可以来自 job / CSR 的 `LAYOUT`
- 但必须满足“job 开始后锁存，job 中不乱改”

建议控制策略：

1. 写入 mode。
2. 触发 start。
3. PE 锁存 mode 到 `mode_q`。
4. 当前 job 结束前不允许切换。

### 4.6 FSA 控制逻辑适配

`MatrixControlFSM.sv` 和 `MatrixEngineController.sv` 当前已经在发统一的 PE micro-op bundle：

- `valid`
- `mac`
- `acc_ui`
- `load_reg_li`
- `load_reg_ui`
- `flow_lr`
- `flow_ud`
- `flow_du`
- `update_reg`
- `exp2`

因此，**新的 MAC 不需要改 bundle 宽度，也不需要另起一套协议**。真正需要改的是“这些控制位在 WS / OS 下如何解释，以及 MAC 结果何时可被后级消费”。

另外，现有控制层已经有 job / compute 级的节拍跟踪能力，比如 `computeTimer`、`io_busy`、`waitPrevAcc` 一类机制，所以这次改造的重点不是重写顶层控制 FSM，而是把现有等待语义和新的 MAC_LATENCY=4 对齐。

建议的适配原则如下：

1. `MatrixControlFSM` / `MatrixEngineController` 继续按现有节拍下发 micro-op。
2. `load_reg_li` / `load_reg_ui` 继续作为 lane capture 使能，只是它们现在只进入 `FPMacUnit` 内部 S0。
3. `mac` 触发一次 4 拍 MAC 事务，控制器不再假设当前拍就能得到结果。
4. `update_reg`、`exp2Done`、结果写回与 job completion 只能基于对齐后的 MAC 输出。
5. `mode_sel` / `LAYOUT` 由 job 级控制锁存，`MatrixControlFSM` 只负责选路与调度，不负责改 MAC 内部流水深度。

更具体地说，控制器需要遵守下面的三段式节拍：

- `ISSUE`：发出 `mac/load_reg_*`，启动一笔事务
- `IN_FLIGHT`：保持调度前进，但不要消费这笔事务的结果
- `COMMIT`：在 MAC_LATENCY=4 到点后，才允许 `update_reg`、结果写回、`exp2Done` 更新

如果现有状态机没有显式的 `IN_FLIGHT` 状态，就需要在上游调度里补等价的 bubble / wait 逻辑，而不是去改 PE 的 bundle 形状。

对这两个 generated 文件的实现建议是：

- 不直接手改生成结果作为长期方案
- 先改上游 Chisel / 控制调度源，再 regenerate
- 如果短期只能看 generated SV，则把它当成“控制协议事实”，不是最终代码归属地

### 4.7 `PE.sv` 到 `fp_mac_pipelined_acc` 的落地映射

如果把 `PE.sv` 作为阵列里单个 PE 的原位替代对象，那么它最终需要收敛成一层“模式 + 端口复用壳”，内部 MAC 语义要落到 `fp_mac_pipelined_acc` 这一层的接口风格上。建议把映射写成下面这样：

| `PE.sv` 语义 | `fp_mac_pipelined_acc` 语义 | 说明 |
|---|---|---|
| `io_l_input` | `weight_in` / resident operand | 在 WS 里作为驻留侧输入；在 OS 里作为乘法 `a` 侧 |
| `io_u_input` | `vec_in` / flowing operand | 在 OS 里作为乘法 `b` 侧，与内部 accumulator 链配对计算 |
| `io_d_input` | `legacy downward operand` | 在 WS 里保留原版 `PE.sv` 语义；OS 主 MAC 数据流不再依赖它 |
| `partial_sum_in` | `accumulator seed side` | 在 OS 里用于 seed/重装内部 accumulator，不直接作为 MAC `c` |
| `rst_acc` | `seed pulse` | 在 OS 里触发 `partial_sum_in -> reg_*` 装载 |
| `io_d_output` | `downward directional port` | 主下行方向口，按控制语义承载 vec 传播或 MAC 结果 |
| `io_u_output` | `upward directional port` | 上行方向口，按控制语义承载 vec 传播或 MAC 结果 |
| `io_r_output` | `horizontal bypass / reserved` | 保留左到右兼容通路，最终例化中大概率不使用 |
| `mac` | `en` | 触发一次 MAC 事务发起 |
| `load_reg_li` | `weight capture` | 把 `l_input` 采样进 PE 内部 MAC 入口寄存器 |
| `load_reg_ui` | `upper-lane capture` | WS 下把 `u_input` 采样进 PE 内部 MAC 入口寄存器；OS 下不再作为 seed / `c` 入口 |
| `acc_ui` | `result lane select` | 只选择 MAC 结果走结果链的哪一侧，不再描述 vec 流动方向 |
| `update_reg` | `result commit` | 在 MAC 结果返回后提交内部状态，不是发起拍信号 |
| `exp2` | `cmd` / special op | 进入同一条 4 拍 token 链，不允许旁路 |

这里的关键约束是：

- `load_reg_li` / `load_reg_ui` 只属于 **WS issue 期**
- `mac` 只负责 **launch**
- `update_reg` / `exp2Done` 只属于 **commit 期**
- `flow_ud / flow_du` 属于 **纵向流动期**
- `flow_lr` 属于 **横向兼容期**
- 对 OS 而言，`fp_mac_pipelined_acc` 的接口语义是主参考；外部 ctrl 在这一模式下更多是兼容输入，不再主导算术语义。
- 对 WS 而言，`PE.sv` 的原有功能仍是主参考，`mode_q` 只是在外层选择哪套解释生效。

也就是说，`PE.sv` 的最终实现不是“一个外壳外面再挂一个 MAC”，而是“一个 PE 壳内部包含两条契约”：一条是 `flow/commit directional contract`，一条是 `4 拍 token contract`。对这版 32x1 纵向阵列而言，`io_d_output` 是主下行方向口，`io_u_output` 是上行方向口，两者都要服从 `acc_ui` 与 `flow_*` 的控制解释，`io_r_output` 只保留兼容性，后续例化时可以不接或不使用。

### 4.8 控制信号时序整理

建议把控制时序收敛成三段：

1. `ISSUE`
   - `io_in_ctrl_valid=1`
   - `mac=1`
   - `load_reg_li/load_reg_ui` 选其一或同时为 1，完成输入捕获
   - WS 下，`acc_ui`、`exp2`、`flow_*` 在这一拍完成语义锁存
   - OS 下，外部只需完成事务发起；其余细粒度控制由内部模板生成

2. `IN_FLIGHT`
   - `io_in_ctrl_valid` 可以继续拉高，控制器可以继续发下一笔事务
   - 当前事务的结果不能被当拍消费
   - WS 下，`flow_*` 仍然可以走流动链，但 MAC 结果还未返回
   - OS 下，流动链与结果链由内部固定模板统一管理

3. `COMMIT`
   - 第 4 拍到点后，才允许把当前事务的 MAC 输出用于 `update_reg`
   - `exp2Done` 只跟随 commit token 更新，不看 issue 拍的 level
   - 如果控制器需要写回或切换下一阶段状态，必须等这一步

在这个约定下，最容易出错的点有三个：

- `acc_ui` 不能在结果返回前重新解释成新事务的路由
- `update_reg` 不能提前一拍去抓旧结果
- `exp2Done` 不能直接看 issue 拍的 `exp2`，必须看 commit 拍返回的结果 token
- `d_output` / `u_output` 不能再被写成固定的单语义端口，必须由控制位解释

补一条实现边界：

- `MAC 结果链` 在第 4 拍对外可见
- `reg_*` / `exp2Done` 由同一个 commit token 驱动，但对外可见的寄存器闭合点仍在下一拍
- 验证时要把“issue 拍的 token 采样”和“commit 拍的状态闭合”分开看，但 commit 本身应视作同一拍完成

补充几个容易漏掉的边界：

- `exp2Done` 的清除条件要单独写清楚，至少要覆盖 reset、job 边界和 mode drain；否则 commit token 可能已经换批，但 sticky 状态还留着上一批的尾巴
- `flow_chain` 和 `result_chain` 不能只拆名字，还要拆 valid 语义；`io_out_ctrl_valid` 只能代表控制流，不应被默认当成 MAC 结果有效
- `exp2` 事务在 flight 期间必须互斥，不能在旧 commit token 未返回前再发第二笔同类事务，否则 `exp2Done` 虽然“跟 token 走”，但 token 自己会串
- 如果后续希望上层显式感知 MAC 结果到达，最好再定义一个结果侧 valid / commit token 输出，而不是复用 `flow_*` 或 `io_out_ctrl_*`

如果后续要继续细化到实现，建议再补一张“`load_reg_li/load_reg_ui/mac/update_reg/exp2Done` 的 4 拍 token 对齐表”，把 issue 拍和 commit 拍之间的 token 编号固定下来，这样 `MatrixControlFSM` 和 `MatrixEngineController` 的 wait / bubble 逻辑就不会再含糊。

### 4.9 `MatrixControlFSM` / `MatrixEngineController` 的延迟匹配

新的 PE 不是靠改 bundle 宽度来接控制，而是靠**控制层发射节拍**去对齐 4 拍 commit 契约。

建议的匹配方式是：

1. **控制 bundle 保持不变**
   - `valid/mac/acc_ui/load_reg_li/load_reg_ui/flow_lr/flow_ud/flow_du/update_reg/exp2` 这 9 个控制位继续沿用
   - `MatrixControlFSM` 和 `MatrixEngineController` 不需要为了 4 拍另加一组 PE 协议
   - 其中 `OS` 模式下，`acc_ui / update_reg / exp2 / flow_*` 可退化为兼容输入或观测位，不再作为算术语义的主决定因素

2. **发射与提交分离**
   - `ISSUE` 拍只负责发 `mac` 和 `load_reg_*`
   - `COMMIT` 拍只负责 `update_reg`、`exp2Done`、结果写回
   - 中间 3 拍由 PE 内部 token 自己走完，不由 controller 去“猜结果”

3. **控制层保留一个 4-cycle age 约束**
   - `waitPrevAcc` / `io_busy` 必须覆盖“上一个 MAC 事务尚未 commit”这段窗口
   - controller 不能在 token age 未满 4 拍时发起会冲突的新事务
   - 如果要显式实现，可以在 controller 里把 `mac` 事务也做成 4 级 shift token，再在第 4 拍推出 commit sideband

4. **结果侧不要复用 issue 侧 level**
   - `exp2Done` 不能看 issue level
   - `update_reg` 不能提前一拍抢结果
   - 如果上游当前是用 `computeTimer` 直接拼窗口，那这些窗口要整体后移到 PE 的 commit 时刻

5. **对 generated RTL 的实际含义**
   - `MatrixControlFSM.sv` / `MatrixEngineController.sv` 已经把 PE 控制位按 cycle 展开了，所以新 PE 的延迟匹配，通常不是改端口，而是改“这些位在哪一拍为 1”
   - 最稳妥的做法是回到 Chisel 源头改节拍；如果短期只改 generated SV，也必须让 `update_reg/exp2Done` 的生成点后移 4 拍

6. **OS 与 WS 的控制分工**
   - `OS`：外部仅保留 `mode_sel`、事务发起和排空语义，算术控制由 PE 内部固定模板生成
   - `WS`：保留原版 `PE.sv` 的控制解释和功能覆盖，只调整内部打拍与 commit 对齐

这个匹配逻辑的本质是：

- PE 负责“4 拍后什么时候 commit”
- controller 负责“哪一拍 issue，哪一拍 bubble，哪一拍 release”
- 两边都不应该再把当前拍的 level 当成最终结果

---

## 5. 延迟契约

这次改造的核心不是“加多少个寄存器”，而是“把 4 拍明确归属到 MAC 内部哪一级”。

建议对外约定：

- 从 MAC 入口在某个 clock 边沿采样到操作数开始
- 到 MAC 结果在第 4 个 clock 边沿可被后级采样
- 固定为 `4` 拍

也就是：

- WS = 4 拍
- OS = 4 拍
- `exp2` = 4 拍

注意这里的 4 拍是 **单个 PE 的 MAC 级契约**，不是底层乘法器的延迟目标。
如果后续真的要把“修改后的 `PE.sv`”再包装成一个纯 `A/B -> O` 的 mul-only 单元去替换别的乘法器，那需要单独定义一个兼容外壳，不能直接拿当前 PE 的控制/旁路接口硬顶上去。

注意：

- 这 4 拍全部算在 `FPMacUnit` 内部
- PE 外层如果只做 mode latch / 输入 mux，不额外占用这 4 拍预算
- bypass 流不是这个契约的一部分
- 只有走 MAC 的那部分必须对齐

---

## 6. 推荐的实现顺序

### 第 1 步
先改 `RawFloat_FMA.sv` / `RawFloat_MulAddExp2.sv`

- 把重组合路径切成流水
- 让输出变成固定延迟结果

### 第 2 步
再改 `FPMacUnit.sv`

- 引入 token 对齐
- 让输出和控制一起延迟

### 第 3 步
再改 `PE.sv`

- 加 `mode_sel`
- 明确 `load_reg_li / load_reg_ui` 的 lane capture 映射
- 统一 WS / OS 的端口映射

### 第 4 步
最后补控制层

- 把 `mode_sel` 从 `cb_controll.v` / CSR / job 配置送进来
- 增加 mode switch 的排空约束

---

## 7. 主要风险

1. **mode 中途切换**
   - 风险：流水中的 token 混到不同模式。
   - 对策：只允许在 drain / idle 边界切换。

2. **`acc_ui` / `update_reg` 未对齐**
   - 风险：结果到了，但更新控制还在旧拍。
   - 对策：这些控制量必须和 MAC 结果同链 retime。

3. **`exp2Done` 误判**
   - 风险：exp2 结果和 sticky 状态错位。
   - 对策：`exp2` 不能旁路，必须进入同一条 token 链。

4. **generated RTL 被重新生成覆盖**
   - 风险：手改的流水切片丢失。
   - 对策：如果后续还走生成流，需要同步修上游源代码。

5. **时序切片不均衡**
   - 风险：某一级仍然过重。
   - 对策：优先观察 `prodExp/expDiff`、`shiftRightJam`、`lzc` 三处。

---

## 8. 验证建议

建议回归至少覆盖以下场景：

- 普通乘加
- `0 / inf / nan`
- `exp2` 模式
- WS 模式 4 拍输出
- OS 模式 4 拍输出
- mode 切换前后排空
- `acc_ui` 两个输出 lane 的选择
- `update_reg` 与 `exp2Done` 的同步性

验证目标很明确：

- 位级结果正确
- 延迟固定
- 模式切换不串流
- 旁路不被 MAC 打拍污染

---

## 9. 结论

这次改造的正确方向是：

1. **把组合大核切进内部流水**
2. **把控制 token 一起 retime**
3. **把 WS / OS 统一到同一条 4 拍 MAC 契约**
4. **保留一套 MAC 资源，不做双核并存**

这样做以后，`PE.sv` 就不再只是 WS 的一个变体，而是一个可以在 WS / OS 间重构的数据通路壳，且能更自然地对齐 `PE_core.v` 的 OS 时序。

---

## 10. 验证计划

这一节的目标不是“跑通一次就算过”，而是要证明：

1. `PE.sv` 改完后，在 **FSA 路径** 下控制功能正确、计算结果正确。
2. `PE_core.v` 这条 **参考路径** 下控制契约仍然正确。
3. 两条路径对同一组激励，在约定延迟后能给出一致的可比对结果。
4. WS / OS 切换、`exp2`、`update_reg`、`exp2Done`、`flow_*` 的时序没有串。

### 10.1 验证对象

- **DUT-A**：`workspace/gemv_fsa/rtl/PE/PE.sv`
- **DUT-B**：`workspace/gemv_fsa/rtl/PE_core_new.v`（由 `PE_core.v` 复制后做定向修改，保留原层级探针兼容）

这里不要只看最终数值，还要看：

- 控制位是否按 issue / commit 语义推进
- `load_reg_li / load_reg_ui / mac / update_reg / exp2Done` 是否对齐
- `d_output / u_output / r_output` 是否在不同模式下按预期方向传播
- `reg_*` 的写回是否在 commit 后下一拍完成

### 10.2 验证层次

#### A. 单元级 FPMac 验证

目标：先验证 MAC 内部 4 拍本身没有算错。

测试点：

- 普通 `a*b + c`
- `a=0` / `b=0`
- `Inf`
- `NaN`
- 正负号组合
- 大指数差 / 小指数差
- 需要 `exp2` 的事务

检查项：

- 输出数值和 Python/软件 golden 一致
- `exp2` 相关结果只在 commit 拍可见
- 4 拍延迟固定

#### B. PE 控制级验证

目标：验证 `PE.sv` 的端口复用和模式切换。

测试点：

- `mode_sel=WS`
- `mode_sel=OS`
- `load_reg_li`
- `load_reg_ui`
- `mac`
- `update_reg`
- `flow_lr / flow_ud / flow_du`
- `exp2Done`

检查项：

- WS 下 `l_input/u_input/d_output/u_output` 映射正确
- OS 下 `acc_ui` 和 commit lane 选择正确
- mode 切换只允许在 drain 后生效
- 结果链不会污染流动链

#### C. 顶层控制级验证

目标：验证 `MatrixControlFSM.sv` / `MatrixEngineController.sv` 的节拍和 PE 延迟匹配。

测试点：

- 连续 issue 事务
- 中间插 bubble
- job 边界 drain
- `waitPrevAcc`
- `io_busy`
- `computeTimer`
- `exp2Done` 清除 / 置位

检查项：

- 控制层发起拍与 PE commit 拍差 4 cycle
- 控制层不会在旧 token 未 commit 前发新冲突事务
- `exp2Done` 只跟 commit token 走

### 10.3 Directed Case 清单

建议至少覆盖以下定向用例：

1. **WS 基本流**
   - 固定一组 `l_input/u_input`
   - 连续发 `mac`
   - 检查 `d_output` 向下流动和 MAC 结果分离

2. **OS 基本累加**
   - 以独立 `partial_sum_in` 为主，`d_input` 仅保留 WS/兼容语义
   - 检查 `update_reg`、`acc_ui`、`result commit`

3. **边界值**
   - `0 + 0`
   - `0 * x`
   - `Inf * 0`
   - `NaN`

4. **指数极差**
   - 小数和大数混合
   - 触发最大右移
   - 触发归一化左移

5. **exp2 路径**
   - 只发 `exp2`
   - 连发 `exp2` + 普通 MAC
   - 检查 `exp2Done` 与 commit 对齐

6. **模式切换**
   - WS -> OS
   - OS -> WS
   - 只允许在 drain 后切换

7. **控制冲突**
   - `load_reg_li` / `load_reg_ui` / `mac` 同拍组合
   - `flow_*` 和 `mac` 同拍组合
   - 验证控制优先级和锁存边界

### 10.4 Random Regression 计划

随机激励建议分三层：

1. **随机数据**
   - 随机生成 IEEE754 FP32 操作数
   - 覆盖 normal / subnormal / zero / inf / nan

2. **随机控制**
   - 随机切换 `WS / OS`
   - 随机插入 `flow_*`
   - 随机插入 `exp2`
   - 随机插入 `load_reg_*`
   - 随机插入 bubble

3. **随机序列**
   - 长串事务
   - 同时检查 latency 和结果正确性
   - 连续多次 job / tile 边界切换

随机回归至少要做两类比对：

- **控制比对**：控制 token 是否按期到达
- **数值比对**：输出 FP32 是否与 golden 一致

### 10.5 Scoreboard 设计

建议 scoreboard 做成两条链：

1. **控制 scoreboard**
   - 记录 issue cycle
   - 记录 commit cycle
   - 检查是否严格满足 `commit = issue + 4`
   - 检查 `exp2Done`、`update_reg`、`io_busy` 关联关系

2. **数值 scoreboard**
   - 对每笔事务保存输入
   - 用 software golden 计算参考值
   - 在 commit cycle 比对 DUT 输出

对 `PE_core_new` 路径，可以直接把 `fp_mac_pipelined_acc` 当参考 golden；  
对 `FSA` 路径，建议仍然以同一套软件 golden 作为主参考，再把 `PE_core` 作为时序 contract 对照。

### 10.6 结果判定标准

至少满足以下条件才算通过：

- 控制信号无越界、无串流
- WS / OS 两种模式都能稳定出结果
- `exp2Done` 与 commit 对齐
- FSA 路径和 `PE_core` 路径在等价输入下结果一致
- 随机回归无 mismatch
- mode 切换无残留状态污染

### 10.7 建议落地方式

验证建议分三步做：

1. 先做单 PE directed
2. 再做单 PE random
3. 最后接到 controller / array 级联调

如果短期只想先做最小闭环，优先顺序是：

- `PE.sv` 单元级随机回归
- `PE_core.v` 参考路径对照
- `MatrixControlFSM.sv` / `MatrixEngineController.sv` 时序回归

这样能先把“算对”和“时序对”拆开验证，再合并成整条链。

### 10.8 当前验证状态

当前已经完成一次真实远程 VCS bring-up，结论如下：

- 远程脚本：`scripts/run_cb_baseline_remote.ps1`
- 回归对象：`TC_OS_RowCol_64x172`
- 结果：`PASS`
- 日志目录：`reports/vcs/remote_eda_tb_cb_baseline_TC_OS_RowCol_64x172_20260509_223534`

已确认：

- `mac_top.v` 已切到 `PE_core_new`
- 64x172 baseline 可以在新复制路径下正确跑通
- 原有层级探针命名仍保持兼容

补充一条论文级数值验证证据，避免把“原语级链路验证”和“完整 FlashAttention 结果验证”混为一谈：

- 远程脚本：`workspace/fsa_llm_sv/scripts/run_uvm_regression_remote.ps1 -Suite stage26-array-real-compute -NoFailover`
- 回归对象：`tb_stage26_array_datapath_real_compute_directed`
- 结果：`PASS`
- 日志目录：`workspace/fsa_llm_sv/reports/vcs/remote_eda_stage26-array-real-compute_20260510_015134`
- 覆盖范围：`LOAD_STATIONARY`、`ATTENTION_SCORE`、`ATTENTION_VALUE`、`ATTENTION_LSE_NORM_SCALE`、`ATTENTION_LSE_NORM`
- 结果判定：阶段链路与 `ref_result_tile` 对比通过，说明 FlashAttention 的关键数值链路已经有真实 golden 参考

当前仍需继续的项：

- `PE.sv` 自身的重构版已开始落到完整替换，但后续仍需要继续补齐更大范围控制场景与 controller 级联调
- controller 级适配与更大范围随机回归仍待后续推进
- 已新增 `scripts/systolic_array_newpe_filelist.f`，并用它把 `tb_systolic_array` 切到 `workspace/gemv_fsa/rtl/PE/*` 路径；该路径的 `baseline` / `paper` 已通过远程 VCS，说明新 PE 已能接入原 systolic 阵列回归壳。
- `tb_pe_dualflow` 已把 MAC 场景的 control token 检查改成 commit 周期对齐，说明 control/result 链分离已真正落到 RTL 和 TB。

### 10.9 论文级验证定义

如果目标提升到论文级验证，那么测试对象就不能只停留在单个 PE 或单个阵列原语，而要覆盖论文中 `SystolicAttention` 的完整阶段链：

1. `LoadStationary`
2. `AttentionScore`
3. `AttentionValue`
4. `AttentionLseNormScale`
5. `AttentionLseNorm`

论文级验证的核心不是“某个拍数能不能过”，而是以下三件事同时成立：

- **阶段节拍对齐**：控制 token 必须与 `ExecutionPlan.scala` 的阶段调度一致
- **数据流对齐**：`flow_lr / flow_ud / flow_du / mac / acc_ui / exp2` 的流动方向必须符合论文描述
- **结果对齐**：中间值和最终输出必须和软件 golden 一致

#### 10.9.1 论文级 scoreboard 划分

建议拆成两层 scoreboard：

- **阶段 scoreboard**
  - 输入：`ExecutionPlan` 的期望周期、方向、命令
  - 检查：控制是否在正确阶段发出
  - 重点：`exp2`、`update_reg`、`acc_ui`、`flow_*` 是否串拍

- **数值 scoreboard**
  - 输入：随机或定向的 `Q/K/V`
  - 检查：每个阶段的中间结果和最终 attention 输出
  - 重点：rowmax、exp2、rowsum、reciprocal、attention value 输出

#### 10.9.2 论文级定向用例

至少要覆盖以下 case：

1. **LoadStationary**
   - 验证 `Q` preload 的 row-stationary / weight-stationary 语义
   - 检查 `r_output` 仅作流动链，不污染 MAC 结果链

2. **AttentionScore**
   - 验证 `S = QK^T`
   - 检查 `rowmax` 的 upward 传播
   - 检查 `newm / oldm / diff / exp2` 的阶段顺序

3. **AttentionValue**
   - 验证 `O = PV`
   - 检查 downward 传播与 accumulator 合并

4. **AttentionLseNormScale**
   - 验证 `SET_SCALE + RECIPROCAL`
   - 检查 reciprocal 结果的 valid / latency

5. **AttentionLseNorm**
   - 验证 `ACC` 最终归一化
   - 检查 accumulator SRAM 输出与 golden 一致

#### 10.9.3 论文级随机回归

随机回归不能只随机 FP32 数据，还要随机控制阶段：

- 随机 tile 尺寸
- 随机 `Q/K/V`
- 随机 causal / non-causal
- 随机 `exp2` 分段输入
- 随机 bubble 插入
- 随机 phase 间隔

每个随机用例至少要比对：

- 中间阶段 token 是否按期到达
- 最终 attention 输出是否与软件 golden 一致
- 关键内部 sticky 状态是否在 job 边界清干净

#### 10.9.4 论文级通过标准

以下条件都满足，才算论文级验证通过：

- `ExecutionPlan` 定义的阶段顺序无偏移
- 控制 token 与结果 token 的拍点一致
- `rowmax / exp2 / rowsum / reciprocal / attention value` 的中间结果正确
- 最终 attention 输出与参考模型一致
- WS / OS 切换后没有状态串扰

当前实现备注：

- `tb/tb_systolic_array.sv` 已增加 `baseline` / `paper` 两种回归模式。
- `paper` 模式已经覆盖 `LoadStationary`、`AttentionScore`、`AttentionValue` 的链路与控制节拍自检，以及 `exp2` 控制 token 的对齐检查。
- 由于当前验证对象仍是 `SystolicArray.sv` 原语，`AttentionLseNormScale / AttentionLseNorm` 的完整 reciprocal / accumulator 结果还需要在更上层的完整 FSA top 上继续补验。

#### 10.9.5 已完成的完整数值验证

在 `workspace/fsa_llm_sv` 侧已经完成一轮更完整的 FlashAttention 数值验证，和本计划中的原语级 `SystolicArray.sv` 验证形成上下游对应关系：

- 该验证不是只看 dataflow，而是对真实计算结果做了 reference 对比
- 重点覆盖了论文级阶段链中的 `LOAD_STATIONARY`、`ATTENTION_SCORE`、`ATTENTION_VALUE`、`ATTENTION_LSE_NORM_SCALE`、`ATTENTION_LSE_NORM`
- 验证通过后，可以把它作为 `SystolicArray.sv` 原语级验证之外的结果级证据，避免把“链路可见”误当成“结果正确”

推荐后续在本计划中继续保持这种分层：

- `workspace/gemv_fsa` 负责 PE / SystolicArray 原语重构与时序契约
- `workspace/fsa_llm_sv` 负责更上层的完整 FlashAttention 数值闭环和 controller / top 级联调

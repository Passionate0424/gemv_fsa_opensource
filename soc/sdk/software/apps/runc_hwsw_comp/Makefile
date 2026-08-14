TARGET = run

CFLAGS += -O3 -g

#根据SIMU宏选择串口波特率,0：FPGA上板；1：仿真
CFLAGS += -DSIMU=0

# 精度/性能对比模式：
#   make MODE=hw     → 硬件加速（GEMV+FSA），CPU侧浮点仍走软浮点库
#   make MODE=cpu    → 纯CPU推理（golden reference），软浮点
#   make MODE=hw_fpu → 硬件加速 + CPU侧浮点改用硬件FPU(ilp32f ABI)，
#                       链接 picolibc-hwfp(同源picolibc 1.8.6硬浮点重编版，
#                       见 scripts/build_picolibc_hwfp.sh)，不与软浮点版混链。
MODE ?= hw
ifeq ($(MODE),cpu)
  CFLAGS += -DCPU_ONLY_MATMUL=1 -DCPU_ONLY_ATTN=1
  OBJDIR = obj_cpu
  OUTPUT_SUFFIX = _cpu
  PICOLIBC_DIR = ../../../toolchains/picolibc
  GCC_DIR = ../../../toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0
else ifeq ($(MODE),cpu_fpu)
  # 纯CPU推理 + 硬件FPU。用来补齐 2×2 隔离矩阵的左下角：
  #   cpu(软浮点,无加速器)=正确  hw(软浮点,有加速器)=正确  hw_fpu(硬浮点,有加速器)=错
  # 这一档单独打开硬件FPU、关掉加速器，判定"FPU 单独就错"还是"两者同时工作才错"。
  # 后者会把矛头指向中断/flush 与 FPU 在途状态的交互（加速器完成时发 HWI1）。
  CFLAGS += -DCPU_ONLY_MATMUL=1 -DCPU_ONLY_ATTN=1
  CFLAGS += -mabi=ilp32f -msingle-float
  CFLAGS += -fno-use-linker-plugin
  CFLAGS += -DHW_FPU=1
  OBJDIR = obj_cpu_fpu
  OUTPUT_SUFFIX = _cpu_fpu
  PICOLIBC_DIR = ../../../toolchains/picolibc-hwfp
  GCC_DIR = ../../../toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-multilib
else ifeq ($(MODE),hw_fpu)
  CFLAGS += -mabi=ilp32f -msingle-float
  CFLAGS += -fno-use-linker-plugin
  CFLAGS += -DHW_FPU=1  # 仅用于[HWSW]打印区分hw/hw_fpu，不影响实际ABI
  OBJDIR = obj_hw_fpu
  OUTPUT_SUFFIX = _hw_fpu
  PICOLIBC_DIR = ../../../toolchains/picolibc-hwfp
  # hw_fpu用支持ilp32s+ilp32f双ABI multilib的工具链(scripts/build_gcc_ilp32f_multilib.sh
  # 构建)，其它模式继续用官方v2.0发布包——避免link阶段找不到ilp32f版libgcc.a导致的
  # ABI错位bug(见docs/agent/worklog.md 2026-06-29记录)
  GCC_DIR = ../../../toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-multilib
else
  OBJDIR = obj_hw
  OUTPUT_SUFFIX = _hw
  PICOLIBC_DIR = ../../../toolchains/picolibc
  GCC_DIR = ../../../toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0
endif

# ============================================================================
# 可选开关：与 MODE 正交，可任意组合。默认全关，正式构建零开销。
#   make MODE=hw BENCH=1              → obj_hw_bench / run_hw_bench.bin
#   make MODE=hw_fpu BENCH=1 TOK_REPORT=32
# ============================================================================

# 时间拆解：把一次推理按 CSR配置/cache flush/等硬件/纯CPU 归因，并给出硬件段的
# DMA与计算理论下限，用于判断瓶颈在带宽还是算力。产物加_bench后缀与常规构建共存。
BENCH ?= 0
ifeq ($(BENCH),1)
  CFLAGS        += -DBENCH_PROFILE=1
  OBJDIR        := $(OBJDIR)_bench
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)_bench
endif

# SiLU硬件融合开关。默认开（硬件模式下GEMV结果写回DDR前就地过silu()）。
# SILU=0 关掉，得到"硬件GEMV + 软件expf激活"的对照组，产物加_nosilu后缀与
# 启用版共存——两版跑同一模型比 token 序列（验正确性）和 FFN.act 耗时（量收益）。
# 注意：MODE=cpu 下本开关无意义，那条路径本就没有硬件通路。
SILU ?= 1
ifeq ($(SILU),0)
  CFLAGS        += -DHW_SILU_FUSED=0
  OBJDIR        := $(OBJDIR)_nosilu
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)_nosilu
endif

# 权重预取开关。默认开（CPU算rmsnorm/SwiGLU时，DMA先把下一次matmul的第一个
# 权重行块搬进SRAM）。PREFETCH=0 关掉得到对照组，产物加_nopf后缀与启用版共存——
# 两版跑同一模型比 [BENCH] GEMV.csr 和 GEMV.hw 净值。GEMV.csr 更灵敏：预取版把
# 6次CSR写挪到了预取时，start只剩1次写，这一项的下降是预取生效的最早证据。
# 注意：预取期间CPU和DMA抢同一个AXI slave，净收益需上板实测确认，可能被抵消。
# FSA侧K tile0预取开关，**默认关**。RTL/TB/UVM都验过、实测40/40次全命中零失效，
# 但端到端是净退化 -1.09%（16 token受控实验：新RTL+旧软件482823 → +FSA预取488066）。
# 根因不是没命中，而是它把K的搬运从"CPU在cpu_idle()里睡着、总线全归DMA"的ATTN.hw段，
# 挪到了"CPU正在算RoPE/rmsnorm"的忙碌期——实测 ROPE +26163、RMSNORM +33994 的争用
# 代价，超过省下的那点搬运。GEMV预取同样是这个搬法却是净收益，差别在量级：GEMV首块
# 2048 word，FSA的K tile0只有256 word，小8倍，收益按搬运量缩水而争用代价没有。
# 等BaseRAM/ExtRAM双片并行读把带宽翻倍、争用消失后再打开重测。
FSA_PREFETCH ?= 0
ifeq ($(FSA_PREFETCH),1)
  CFLAGS        += -DHW_FSA_PREFETCH=1
  OBJDIR        := $(OBJDIR)_fsapf
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)_fsapf
endif

PREFETCH ?= 1
ifeq ($(PREFETCH),0)
  CFLAGS        += -DHW_PREFETCH=0
  OBJDIR        := $(OBJDIR)_nopf
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)_nopf
endif

# 生成token数。默认0=沿用run.c里的256（板上正式跑）。RTL仿真几百秒只跑得到
# 几十个token，推理不结束就等不到[BENCH]的分段归因报告；设 STEPS=16 编一个短
# 推理版本，让仿真里也能拿到 GEMV.csr / GEMV.hw / ROPE / FFN.act 这些分段数据。
# 产物加_sN后缀，与正式版共存。
STEPS ?= 0
ifneq ($(STEPS),0)
  CFLAGS        += -DGEN_STEPS=$(STEPS)
  OBJDIR        := $(OBJDIR)_s$(STEPS)
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)_s$(STEPS)
endif

# NaN/Inf检测：每次matmul额外扫描 n+2d 个元素并在命中时停机。开销随矩阵规模
# 线性增长，会明显拖慢推理并污染性能测量，仅在定位数值异常时打开。
NAN_CHECK ?= 0
ifeq ($(NAN_CHECK),1)
  CFLAGS += -DDEBUG_NAN_CHECK=1
endif

# CPU重算并逐元素比对硬件结果，用于功能正确性验证（极慢）
# **必须同时改 OBJDIR**：只加 CFLAGS 不改输出目录的话，VERIFY 版会把同名的普通版
# 原地覆盖掉——外面看目录名完全一样，实际装的是慢几十倍、还会刷 [VERIFY] 日志的
# 另一个程序。上板对照实验里踩过一次：以为在跑 hw_fpu 基准，其实跑的是 VERIFY 版。
VERIFY ?= 0
ifeq ($(VERIFY),1)
  CFLAGS        += -DVERIFY_MATMUL=1
  # golden 要跟着做 w1 那一路的融合 SiLU，需要位级实现 silu_bits()。
  # 它和 RTL 的 fsa_accumulator 逐条命令对应，与 tb 共用同一份，不另写。
  INCLUDES      += -I../../../../../tb/dpi
  OBJDIR        := $(OBJDIR)_verify
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)_verify
endif

# 诊断开关：把谓词循环里的 `idle 0` 停机指令去掉，退化成纯自旋（见 run.c cpu_idle）。
# 谓词循环上线之前它曾是唯一能出正确结果的配置——因为自旋天然带谓词复查，
# 恰好绕开了裸 idle 的假唤醒。现在两者都正确，留它只用于隔离停机指令本身的影响。
NO_IDLE ?= 0
ifeq ($(NO_IDLE),1)
  CFLAGS        += -DNO_IDLE_INSN=1
  OBJDIR        := $(OBJDIR)_noidle
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)_noidle
endif

# 诊断开关：RoPE 的三个超越函数退回"每层每两元素算一次"的优化前写法（见 run.c）。
# 用来在 idle 假唤醒修复后的干净基线上重新标定这一刀的净收益。
NO_ROPE_HOIST ?= 0
ifeq ($(NO_ROPE_HOIST),1)
  CFLAGS        += -DNO_ROPE_HOIST=1
  OBJDIR        := $(OBJDIR)_norope
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)_norope
endif

# 诊断开关：统计谓词循环转了几圈，区分"完成早于 idle"
# 与"idle 提前返回"两种竞态。见 run.c cpu_idle 里的判据说明。
IDLE_WAKECNT ?= 0
ifeq ($(IDLE_WAKECNT),1)
  CFLAGS        += -DIDLE_WAKECNT=1
  OBJDIR        := $(OBJDIR)_wcnt
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)_wcnt
endif

# 诊断开关：保留 idle 0，但唤醒后先空转 N 次整数循环再继续（见 run.c cpu_idle 注释）。
# 与 NO_IDLE 互斥使用——那个是消掉活动台阶，这个是保留台阶、只推迟浮点起点。
IDLE_WARMUP ?= 0
ifneq ($(IDLE_WARMUP),0)
  CFLAGS        += -DIDLE_WARMUP=$(IDLE_WARMUP)
  OBJDIR        := $(OBJDIR)_warm$(IDLE_WARMUP)
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)_warm$(IDLE_WARMUP)
endif

# 诊断开关：启动加速器之前空转 N 次（见 run.c matmul_inner 里的说明）。
# 与 IDLE_WARMUP 构成对照，用来分开"唤醒后的浮点运算"与"加速器操作间隔"两个变量。
# 诊断开关：唤醒后立刻读一遍输出、延迟后再读一遍并比对（见 run.c matmul_inner）。
# 目的是看清"错值是哪一种"——等于该地址上一次的值 / 别的地址的值 / 个别 bit 翻转，
# 三者指向完全不同的机制。开销极小（每次调用读 8 个字 + 2000 次空转），
# 不像 VERIFY 那样慢 12.7 倍把现象本身掩盖掉。
# 诊断开关：每 token/每层/每阶段之后记录残差流 x 的哈希，跑完一次性打印。
# 同一份二进制多跑几次比哈希序列，第一处不同即数据最早分叉的位置。
# 判据不依赖任何机制假设——不管根因是什么，"第一次变得不同的地方"总是存在。
# STAGE_HASH_FINE=1：在 FFN 内部再插 5 个记录点（rmsnorm/w1+SiLU/w3/SwiGLU/w2 之后），
# 把分叉定位从"FFN 阶段"细化到"哪一次运算之后"。需与 STAGE_HASH=1 同时开。
# 诊断开关：只把 FFN 的 w2 那一次矩阵乘改走纯 CPU，其余仍走加速器。
# w2 是全模型唯一列数非 32 整数倍的调用（n=172=5×32+12），而分阶段哈希把第一处
# 数据分叉 3/3 钉在它的输出上。
# CPU_W2 的等代价对照：w3 形状 n=64/d=172 与 w2 的 n=172/d=64 乘加次数相同，
# 搬到 CPU 的额外耗时也相同。用来分开"绕开 w2"与"整体变慢"两个效应。
# 只对 w2 那次调用做全向量双读比对（见 run.c）。w2 是"CPU 读加速器输出距离唤醒
# 最近"的一次，分阶段哈希三次都在它的输出上分叉。每层 1 次，开销约 2.5%。
# 唤醒后立刻读回 w1 输出（d=172，6 个 tile）找首个出错下标，用来区分 w2 那边的
# idx=32 是"第二个 tile"还是"最后一个 tile"（d=64 时两者重合，分不开）。
# 诊断：把 w2 的列数改成 160（5 个满列 tile，消掉部分列块）。数学会错，只用来看
# W2_READBACK 的早读/晚读是否还分叉，判定"部分列块"是不是触发条件。需配 W2_READBACK=1。
# 把 w2 零填充到 192 列（6 个满列块），数学结果逐位不变、只改列块结构。
# 这是检验"部分列块是否为触发条件"的唯一干净做法（直接改 n 的做法会污染数据分布）。
W2_PAD192 ?= 0
ifeq ($(W2_PAD192),1)
  CFLAGS        += -DW2_PAD192=1
  OBJDIR        := $(OBJDIR)_pad192
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)_pad192
endif

W2_NPAD ?= 0
ifneq ($(W2_NPAD),0)
  CFLAGS        += -DW2_NPAD=1 -DW2_NPAD_N=$(W2_NPAD)
  OBJDIR        := $(OBJDIR)_npad$(W2_NPAD)
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)_npad$(W2_NPAD)
endif

W1_READBACK ?= 0
ifeq ($(W1_READBACK),1)
  CFLAGS        += -DW1_READBACK=1
  OBJDIR        := $(OBJDIR)_w1rb
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)_w1rb
endif

W2_READBACK ?= 0
ifeq ($(W2_READBACK),1)
  CFLAGS        += -DW2_READBACK=1
  OBJDIR        := $(OBJDIR)_w2rb
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)_w2rb
endif

CPU_W3 ?= 0
ifeq ($(CPU_W3),1)
  CFLAGS        += -DCPU_W3=1
  OBJDIR        := $(OBJDIR)_cw3
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)_cw3
endif

CPU_W2 ?= 0
ifeq ($(CPU_W2),1)
  CFLAGS        += -DCPU_W2=1
  OBJDIR        := $(OBJDIR)_cw2
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)_cw2
endif

STAGE_HASH_FINE ?= 0
ifeq ($(STAGE_HASH_FINE),1)
  CFLAGS        += -DSTAGE_HASH_FINE=1
  OBJDIR        := $(OBJDIR)f
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)f
endif

STAGE_HASH ?= 0
ifeq ($(STAGE_HASH),1)
  CFLAGS        += -DSTAGE_HASH=1
  OBJDIR        := $(OBJDIR)_sh
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)_sh
endif

READBACK ?= 0
ifeq ($(READBACK),1)
  CFLAGS        += -DREADBACK_CHECK=1
  OBJDIR        := $(OBJDIR)_rbk
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)_rbk
endif

PRE_START_DELAY ?= 0
ifneq ($(PRE_START_DELAY),0)
  CFLAGS        += -DPRE_START_DELAY=$(PRE_START_DELAY)
  OBJDIR        := $(OBJDIR)_pre$(PRE_START_DELAY)
  OUTPUT_SUFFIX := $(OUTPUT_SUFFIX)_pre$(PRE_START_DELAY)
endif

# 导出token序列与logit序列，用于 cpu/hw 两种模式的一致率与PPL对比
DUMP ?= 0
ifeq ($(DUMP),1)
  CFLAGS += -DDUMP_TOKEN_SEQ=1 -DDUMP_LOGITS=1
endif

# 每次硬件调用完成打一行，bring-up阶段定位卡死用（输出量大）
TRACE ?= 0
ifeq ($(TRACE),1)
  CFLAGS += -DDEBUG_TRACE=1
endif

# 周期性进度报告：每N次matmul / 每N个token打印一次累计均值
MM_REPORT ?= 0
ifneq ($(MM_REPORT),0)
  CFLAGS += -DBENCH_MATMUL_REPORT_INTERVAL=$(MM_REPORT)
endif
TOK_REPORT ?= 0
ifneq ($(TOK_REPORT),0)
  CFLAGS += -DBENCH_TOKEN_REPORT_INTERVAL=$(TOK_REPORT)
endif

CFLAGS += $(CFLAGS_EXTRA)

COMMON_DIR = ../../bsp
CICIEC_WINDOWS_HOME ?= ../../../..

# syscalls.c（脱离调试器单板独立跑所需的sbrk/_read实现）挪到bsp共用，
# runc_board/runc_hwsw_comp都引用同一份，避免各自维护一份拷贝导致改一处漏一处
C_SRCS := $(wildcard ./*.c )
C_SRCS += $(COMMON_DIR)/drivers/syscalls.c

# 覆盖工具链命令为完整路径
LA32R_GCC     := $(GCC_DIR)/bin/loongarch32r-linux-gnusf-gcc
LA32R_AS      := $(GCC_DIR)/bin/loongarch32r-linux-gnusf-as
LA32R_OBJDUMP := $(GCC_DIR)/bin/loongarch32r-linux-gnusf-objdump
LA32R_OBJCOPY := $(GCC_DIR)/bin/loongarch32r-linux-gnusf-objcopy

include ../../bsp/common_runc.mk

# 编译后复制到带后缀的文件名，方便两版本共存
post_build:
	cp $(OBJDIR)/axi_ram.mif ./axi_ram$(OUTPUT_SUFFIX).mif
	cp $(OBJDIR)/run.bin ./run$(OUTPUT_SUFFIX).bin
	@echo "[done] Output: axi_ram$(OUTPUT_SUFFIX).mif / run$(OUTPUT_SUFFIX).bin"

TARGET = run

CFLAGS += -O3 -g

#根据SIMU宏选择串口波特率,0：FPGA上板；1：仿真
CFLAGS += -DSIMU=0
CFLAGS += -DVERIFY_MATMUL=0

# 硬件FPU加速（ilp32f ABI，CPU侧浮点用硬件FPU指令）
CFLAGS += -mabi=ilp32f -msingle-float
CFLAGS += -fno-use-linker-plugin
CFLAGS += $(CFLAGS_EXTRA)

OBJDIR = obj_hw_fpu
COMMON_DIR = ../../bsp
GCC_DIR=../../../toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-multilib
PICOLIBC_DIR=../../../toolchains/picolibc-hwfp
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

# 编译后复制到带后缀的文件名，方便多版本共存
post_build:
	cp $(OBJDIR)/axi_ram.mif ./axi_ram_fpu.mif
	cp $(OBJDIR)/run.bin ./run_fpu.bin
	@echo "[done] Output: axi_ram_fpu.mif / run_fpu.bin"

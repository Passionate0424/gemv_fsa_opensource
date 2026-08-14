TARGET = fputest

# 必须走硬浮点 ABI，否则 a+b 会被编译成软浮点库调用，测的就不是 FPU 了。
# 与 runc_hwsw_comp 的 MODE=hw_fpu 用同一套工具链与 libc。
CFLAGS += -O1 -g
CFLAGS += -mabi=ilp32f -msingle-float -fno-use-linker-plugin -DHW_FPU=1
# SIMU=0：上板独立跑，printf 走真串口（SIMU=1 会走 libsemihost 半主机 I/O，
# 板上一个字都不会出来）
CFLAGS += -DSIMU=0
LDFLAGS += -Wl,--start-group -lsemihost -lc -lm -lg -lgcc -Wl,--end-group

C_SRCS := $(wildcard ./*.c )
# 脱离调试器单板独立跑所需的 sbrk/_read/_write 实现
C_SRCS += ../../bsp/drivers/syscalls.c

OBJDIR = obj
COMMON_DIR = ../../bsp
GCC_DIR=../../../toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-multilib
PICOLIBC_DIR=../../../toolchains/picolibc-hwfp
CICIEC_WINDOWS_HOME ?= ../../../..

LA32R_GCC     := $(GCC_DIR)/bin/loongarch32r-linux-gnusf-gcc
LA32R_AS      := $(GCC_DIR)/bin/loongarch32r-linux-gnusf-as
LA32R_OBJDUMP := $(GCC_DIR)/bin/loongarch32r-linux-gnusf-objdump
LA32R_OBJCOPY := $(GCC_DIR)/bin/loongarch32r-linux-gnusf-objcopy

include ../../bsp/common_runc.mk

TARGET = memtest

CFLAGS += -O2 -g
# SIMU=0：上板独立跑。SIMU=1 时 printf 走 libsemihost 的半主机 I/O，需要调试器
# 接管，板上什么都不会从串口出来 —— 这个测试就是要在板上看输出的。
CFLAGS += -DSIMU=0
LDFLAGS += -Wl,--start-group -lsemihost -lc -lm -lg -lgcc -Wl,--end-group

C_SRCS := $(wildcard ./*.c )
# 脱离调试器单板独立跑所需的 sbrk/_read/_write 实现（printf 走真串口）
C_SRCS += ../../bsp/drivers/syscalls.c

OBJDIR = obj
COMMON_DIR = ../../bsp
GCC_DIR=../../../toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0
PICOLIBC_DIR=../../../toolchains/picolibc
CICIEC_WINDOWS_HOME ?= ../../../..

LA32R_GCC     := $(GCC_DIR)/bin/loongarch32r-linux-gnusf-gcc
LA32R_AS      := $(GCC_DIR)/bin/loongarch32r-linux-gnusf-as
LA32R_OBJDUMP := $(GCC_DIR)/bin/loongarch32r-linux-gnusf-objdump
LA32R_OBJCOPY := $(GCC_DIR)/bin/loongarch32r-linux-gnusf-objcopy

include ../../bsp/common_runc.mk

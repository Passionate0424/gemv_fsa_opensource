TARGET = smoke_test

CFLAGS += -O2 -g
CFLAGS += -DSIMU=1
LDFLAGS += -Wl,--start-group -lsemihost -lc -lm -lg -lgcc -Wl,--end-group

C_SRCS := $(wildcard ./*.c )

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

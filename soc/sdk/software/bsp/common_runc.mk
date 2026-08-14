
LA32R_GCC     ?= loongarch32r-linux-gnusf-gcc
LA32R_AS      ?= loongarch32r-linux-gnusf-as
LA32R_GXX     ?= loongarch32r-linux-gnusf-g++
LA32R_OBJDUMP ?= loongarch32r-linux-gnusf-objdump
LA32R_GDB     ?= loongarch32r-linux-gnusf-gdb
LA32R_AR      ?= loongarch32r-linux-gnusf-ar
LA32R_OBJCOPY ?= loongarch32r-linux-gnusf-objcopy
LA32R_READELF ?= loongarch32r-linux-gnusf-readelf

.PHONY: all
all: $(TARGET)

#TODO: 根据Cache实际情况调整has_cache宏，以在start.S中生成正确的Cache初始化代码
CFLAGS += -Dhas_cache=1
CFLAGS += -Dcache_index_depth=0x100 -Dcache_offset_width=0x4 -Dcache_way=4
CFLAGS += -ffunction-sections -fdata-sections
CFLAGS += -nostartfiles -nostdlib -nostdinc -static -fno-builtin 
CFLAGS += -DCLOCKS_PER_SEC=CORE_CLOCKS_PER_SEC -D_CLOCKS_PER_SEC_=CORE_CLOCKS_PER_SEC
CFLAGS += -DUSE_CPU_CLOCK_COUNT

#若使用 newlib , 将下面的 -lsemihost 替换为 -lgloss
LDFLAGS +=  	-T $(LINKER_SCRIPT) \
				-Wl,--gc-sections -Wl,--check-sections \
				-lsemihost -lc -lm -lg -lgcc -L$(PICOLIBC_DIR)/lib	#changed

LINKER_SCRIPT := $(COMMON_DIR)/env/separate.lds

ASM_SRCS += $(COMMON_DIR)/env/start.S 

ifeq ($(TARGET), RTThread_Nano)

else
ASM_SRCS += $(COMMON_DIR)/env/trap_handler.S 
endif

C_SRCS   += $(COMMON_DIR)/drivers/confreg_time.c
C_SRCS   += $(COMMON_DIR)/drivers/core_time.c
C_SRCS   += $(COMMON_DIR)/drivers/common_func.c
# 时间拆解基础设施：BENCH_PROFILE=0时本文件不产生任何代码，可无条件参与编译
C_SRCS   += $(COMMON_DIR)/drivers/bench_profile.c

INCLUDES += -I./ \
			-I$(COMMON_DIR)/include \
			-I$(PICOLIBC_DIR)/include \
			-I$(GCC_DIR)/lib/gcc/loongarch32r-linux-gnusf/8.3.0/include \
			-I$(GCC_DIR)/lib/gcc/loongarch32r-linux-gnusf/8.3.0/include-fixed

ASM_OBJS := $(ASM_SRCS:.S=.o)
C_OBJS := $(C_SRCS:.c=.o)

LINK_OBJS += $(ASM_OBJS) $(C_OBJS)
LINK_DEPS += $(LINKER_SCRIPT)

CLEAN_OBJS += $(OBJDIR)/$(TARGET).elf $(LINK_OBJS) $(OBJDIR)/$(TARGET).s $(OBJDIR)/$(TARGET).bin $(OBJDIR)/convert $(OBJDIR)/axi_ram.coe $(OBJDIR)/axi_ram.mif $(OBJDIR)/axi_ram_base.mif $(OBJDIR)/axi_ram_ext.mif $(OBJDIR)/run_base.bin $(OBJDIR)/run_ext.bin $(OBJDIR)/rom.vlog

$(TARGET): $(LINK_OBJS) $(LINK_DEPS) convert Makefile
	$(LA32R_GCC) $(CFLAGS) $(INCLUDES) $(LINK_OBJS) -o $(OBJDIR)/$@.elf $(LDFLAGS)
	$(LA32R_OBJCOPY) -O binary $(OBJDIR)/$@.elf $(OBJDIR)/$@.bin
	$(LA32R_OBJDUMP) --disassemble-all -S $(OBJDIR)/$@.elf > $(OBJDIR)/$@.s
	$(OBJDIR)/convert $@.bin $(OBJDIR)/
	cp ./$(OBJDIR)/axi_ram.mif ./$(OBJDIR)/axi_ram_base.mif ./$(OBJDIR)/axi_ram_ext.mif $(COMMON_DIR)/../../
	cp ./$(OBJDIR)/axi_ram.mif ./$(OBJDIR)/axi_ram_base.mif ./$(OBJDIR)/axi_ram_ext.mif $(CICIEC_WINDOWS_HOME)/sdk
	cp ./$(OBJDIR)/$@.bin $(COMMON_DIR)/../../
	cp ./$(OBJDIR)/$@.bin $(CICIEC_WINDOWS_HOME)/sdk
	# 上板烧录用的两个半片：总线加宽后两片外部 SRAM 按 addr[2] 交织（偶数字进 base、
	# 奇数字进 ext），**不再是加宽前按 addr[22] 二选一**。只烧 run_base.bin 会让 CPU
	# 每隔一条指令取到 ExtRAM 里的随机值、其余指令还整体错位，表现为完全无输出。
	# 加宽前程序不超过 4MB 时只烧 base 能跑，所以这个习惯很容易带过来。
	cp ./$(OBJDIR)/run_base.bin ./$(OBJDIR)/run_ext.bin $(COMMON_DIR)/../../
	cp ./$(OBJDIR)/run_base.bin ./$(OBJDIR)/run_ext.bin $(CICIEC_WINDOWS_HOME)/sdk
	rm -f $(LINK_OBJS)
	rm -f $(OBJDIR)/convert

$(ASM_OBJS): %.o: %.S
	$(LA32R_GCC) $(CFLAGS) $(INCLUDES) -c -o $@ $< 

$(C_OBJS): %.o: %.c
	$(LA32R_GCC) $(CFLAGS) $(INCLUDES) -c -o $@ $< 

convert: $(COMMON_DIR)/env/convert.c
	mkdir -p $(OBJDIR)/
	gcc -o $(OBJDIR)/convert $(COMMON_DIR)/env/convert.c

.PHONY: clean
clean:
	rm -f $(CLEAN_OBJS)

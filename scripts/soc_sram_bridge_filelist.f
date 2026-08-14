// SoC 外部 SRAM 访存链路(层0)定向 tb filelist
// 只含被优化的 SoC 桥 + wrapper(IOB+depth-2) + 外部 SRAM 模型 + tb
// 不含 CPU/FPU，故不受 cvfpu-VCS 兼容问题影响，秒级内环
./soc/rtl/ip/Bus_interconnects/axi2sram_sp_ext.sv
./soc/rtl/ip/ram_wrap/axi_wrap_ram_sp_external.v
./soc/sim/sram.v
./tb/tb_soc_sram_bridge.sv

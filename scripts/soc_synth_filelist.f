// SoC综合 filelist（仅RTL，不含TB）
// 路径相对于项目根目录

+incdir+./soc/rtl
+incdir+./soc/rtl/ip/open-la500
+incdir+./soc/rtl/ip/open-la500/fpu/cvfpu
+incdir+./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/include
+incdir+./soc/rtl/ip/open-la500/fpu/cvfpu/fpu_div_sqrt_mvp/hdl
+incdir+./soc/rtl/ip/APB_UART/URT
+incdir+./rtl/PE
+incdir+./soc/fpga/project/ipgen/clk_pll

// CPU宏定义
./soc/rtl/ip/open-la500/mycpu.h
./soc/rtl/ip/open-la500/csr.h

// PLL IP（纯RTL例化PLLE2_ADV）
./soc/fpga/project/ipgen/clk_pll/clk_pll.v
./soc/fpga/project/ipgen/clk_pll/clk_pll_clk_wiz.v

// SoC顶层
./soc/rtl/soc_top.v

// AXI互联
// 互连换成 pulp-platform/axi 的 axi_xbar（见 third_party/README.md）。
// 这里用嵌套 -f：run_vivado_synth.tcl 的 read_filelist_recursive 支持递归。
// 注意 VCS 的 soc_filelist.f 与 DC 的 soc_dc_filelist.f 都**不支持嵌套**，那两份是内联的。
-f ./scripts/pulp_axi_rtl_filelist.f
./soc/rtl/ip/Bus_interconnects/axi_xbar_2x8_wrap.sv
./soc/rtl/ip/Bus_interconnects/Axi_CDC.v
./soc/rtl/ip/Bus_interconnects/axi2sram_sp_ext.sv
./soc/rtl/ip/Bus_interconnects/axi2sram_sp.v
./soc/rtl/ip/Bus_interconnects/axi2sram_dp.v

// CPU核
./soc/rtl/ip/open-la500/mycpu_top.v
./soc/rtl/ip/open-la500/if_stage.v
./soc/rtl/ip/open-la500/id_stage.v
./soc/rtl/ip/open-la500/exe_stage.v
./soc/rtl/ip/open-la500/mem_stage.v
./soc/rtl/ip/open-la500/wb_stage.v
./soc/rtl/ip/open-la500/alu.v
./soc/rtl/ip/open-la500/mul.v
./soc/rtl/ip/open-la500/div.v
./soc/rtl/ip/open-la500/regfile.v
./soc/rtl/ip/open-la500/csr.v
./soc/rtl/ip/open-la500/icache.v
./soc/rtl/ip/open-la500/dcache.v
./soc/rtl/ip/open-la500/tlb_entry.v
./soc/rtl/ip/open-la500/addr_trans.v
./soc/rtl/ip/open-la500/btb.v
./soc/rtl/ip/open-la500/axi_bridge.v
./soc/rtl/ip/open-la500/tools.v
./soc/rtl/ip/open-la500/perf_counter.v
./soc/rtl/ip/open-la500/lacc_core.v
./soc/rtl/ip/open-la500/lacc_demo.v

// FPU浮点扩展（CVFPU / OpenHW FPnew + LoongArch适配）
// common_cells 通用基础库(package 最先)
./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/src/cf_math_pkg.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/src/lzc.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/src/rr_arb_tree.sv
// fpu_div_sqrt_mvp 除法/开方核(package 最先)
./soc/rtl/ip/open-la500/fpu/cvfpu/fpu_div_sqrt_mvp/hdl/defs_div_sqrt_mvp.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/fpu_div_sqrt_mvp/hdl/nrbd_nrsc_mvp.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/fpu_div_sqrt_mvp/hdl/preprocess_mvp.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/fpu_div_sqrt_mvp/hdl/iteration_div_sqrt_mvp.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/fpu_div_sqrt_mvp/hdl/norm_div_sqrt_mvp.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/fpu_div_sqrt_mvp/hdl/control_mvp.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/fpu_div_sqrt_mvp/hdl/div_sqrt_mvp_wrapper.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/fpu_div_sqrt_mvp/hdl/div_sqrt_top_mvp.sv
// T-Head E906 DivSqrt(TH32, 合规FP32除法器, vendor/opene906)
./soc/rtl/ip/open-la500/fpu/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/clk/rtl/gated_clk_cell.v
./soc/rtl/ip/open-la500/fpu/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_src_type.v
./soc/rtl/ip/open-la500/fpu/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_dp.v
./soc/rtl/ip/open-la500/fpu/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_frbus.v
./soc/rtl/ip/open-la500/fpu/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_ff1.v
./soc/rtl/ip/open-la500/fpu/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_prepare.v
./soc/rtl/ip/open-la500/fpu/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_srt_single.v
./soc/rtl/ip/open-la500/fpu/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_round_single.v
./soc/rtl/ip/open-la500/fpu/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_pack_single.v
./soc/rtl/ip/open-la500/fpu/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_special.v
./soc/rtl/ip/open-la500/fpu/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_ctrl.v
./soc/rtl/ip/open-la500/fpu/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_top.v
// CVFPU本体(fpnew_pkg必须最先)
./soc/rtl/ip/open-la500/fpu/cvfpu/fpnew_pkg.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/fpnew_classifier.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/fpnew_rounding.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/fpnew_fma.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/fpnew_fma_multi.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/fpnew_divsqrt_multi.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/fpnew_divsqrt_th_32.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/fpnew_noncomp.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/fpnew_cast_multi.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/fpnew_opgroup_fmt_slice.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/fpnew_opgroup_multifmt_slice.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/fpnew_opgroup_block.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/fpnew_top.sv
// FPU与流水线对接的本项目模块
./soc/rtl/ip/open-la500/fpu/fpu_regfile.v
./soc/rtl/ip/open-la500/fpu/fpu_ctl.v
./soc/rtl/ip/open-la500/fpu/fpu_top.sv

// 外设
./soc/rtl/ip/APB_UART/axi_uart_controller.v
./soc/rtl/ip/APB_UART/axi2apb.v
./soc/rtl/ip/APB_UART/apb_mux2.v
./soc/rtl/ip/APB_UART/URT/uart_top.v
./soc/rtl/ip/APB_UART/URT/uart_regs.v
./soc/rtl/ip/APB_UART/URT/uart_receiver.v
./soc/rtl/ip/APB_UART/URT/uart_transmitter.v
./soc/rtl/ip/APB_UART/URT/uart_rfifo.v
./soc/rtl/ip/APB_UART/URT/uart_tfifo.v
./soc/rtl/ip/APB_UART/URT/uart_sync_flops.v
./soc/rtl/ip/APB_UART/URT/raminfr.v
./soc/rtl/ip/DVI/axi_dvi.v
./soc/rtl/ip/confreg/confreg.v
./soc/rtl/ip/confreg/key_debounce.v
./soc/rtl/ip/confreg/digitaltube_controller.v

// RAM包装
./soc/rtl/ip/ram_wrap/axi_wrap_ram_sp_external.v
./soc/rtl/ip/ram_wrap/axi_wrap_ram_sp.v
./soc/rtl/ip/ram_wrap/axi_wrap_ram_dp.v
./soc/rtl/ip/ram_wrap/cache_sram.v
./soc/rtl/ip/ram_wrap/fpga_sram_sp.v
./soc/rtl/ip/ram_wrap/fpga_sram_dp.v

// 复位同步
./soc/rtl/ip/rst_sync/rst_sync.v

// CB_top_v2 加速器
./rtl/CB_top_v2.sv
./rtl/cb_controll_v2.sv
./rtl/mac_top_v2.sv
./rtl/PE_core_v2.sv
./rtl/write_out_v2.sv
./rtl/axi_dma_controller.sv
./rtl/fpmul_seq_pipeline.sv
./rtl/fpadd_seq.sv
./rtl/sram_synth_wrapper.sv

// FSA子模块
./rtl/fsa/fsa_ctrl_fsm.sv
./rtl/fsa/silu_ctrl_fsm.sv
./rtl/fsa/fsa_accumulator.sv
./rtl/fsa/fsa_acc_sram.sv
./rtl/fsa/FPAccUnit_pipe.sv
./rtl/fsa/RawFloat_Div.sv

// PE子模块
./rtl/PE/PE_retimed.sv
./rtl/PE/FPMacUnit.sv
./rtl/PE/RawFloat_MulAddExp2.sv
./rtl/PE/RawFloat_FMA_LA.sv
./rtl/PE/RawFloat_SplitIF.sv
./rtl/PE/fpadd_seq_2stage.sv
./rtl/PE/fp_pre_add.sv

// FSA CMP模块
./rtl/fsa_gen/chisel_fsa_fp32/CMP.sv
./rtl/fsa_gen/chisel_fsa_fp32/FPCmpUnit.sv
./rtl/fsa_gen/chisel_fsa_fp32/fp32_comparator.sv

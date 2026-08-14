// SoC集成 VCS编译 filelist
// 路径相对于远程工作目录

+incdir+./soc/rtl
+incdir+./soc/rtl/ip/open-la500
+incdir+./soc/rtl/ip/open-la500/fpu/cvfpu
+incdir+./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/include
+incdir+./soc/rtl/ip/open-la500/fpu/cvfpu/fpu_div_sqrt_mvp/hdl
+incdir+./soc/rtl/ip/APB_UART/URT
+incdir+./rtl/PE

// CPU宏定义（必须最先编译）
./soc/rtl/ip/open-la500/mycpu.h
./soc/rtl/ip/open-la500/csr.h

// SoC顶层
./soc/rtl/soc_top.v
./soc/sim/mycpu_tb.v
./soc/sim/sram.v

// AXI 协议检查器（plan 第 2 步）。只在仿真编译，`ifndef SYNTHESIS 包住，
// 且靠 bind 从外部插入——交付 RTL 一行不改。DC/Vivado 的 filelist 不含这两行。
// 原计划用 ZipCPU faxi_*，实测公开版是被截断的子集（端口列表末项悬空、VCS 语法
// 报错），且内部大量用 assume（仿真里只会默默通过）；改用 pulp axi_intf.sv 的
// 那套握手稳定性属性，另补拍数/len 一致与 4KB 边界三条事务级检查。
./tb/axi_protocol_checker.sv
./tb/axi_protocol_bind.sv

// 注：原 ODDR 单拍写方案已被 depth-2/IOB 两拍写(第廿八刀)取代，
//     wrapper 不再例化 ODDR，故移除 oddr_sim_model.v 死引用。

// AXI互联
// 互连换成 pulp-platform/axi 的 axi_xbar（见 third_party/README.md）。
// 此处**内联**而非 -f 嵌套：VCS 在 UUM 流程(-kdb -lca)下不接受 filelist 里再写 -f，
// DC 的 dc_compile.tcl 解析器也没有嵌套分支。顺序权威来源是 scripts/pulp_axi_rtl_filelist.f。
+incdir+./third_party/axi/include
// [dedup] +incdir+./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/include

// ---------- common_cells（被 axi 依赖，需先编） ----------
./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/src/cf_math_pkg.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/src/addr_decode.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/src/addr_decode_dync.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/src/delta_counter.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/src/counter.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/src/fifo_v3.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/src/lzc.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/src/onehot_to_bin.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/src/rr_arb_tree.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/src/spill_register_flushable.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/src/spill_register.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/src/stream_register.sv
./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/src/id_queue.sv

// ---------- axi Level 0 ----------
./third_party/axi/src/axi_pkg.sv

// ---------- axi Level 1 ----------
./third_party/axi/src/axi_intf.sv

// ---------- axi Level 2 ----------
./third_party/axi/src/axi_atop_filter.sv
./third_party/axi/src/axi_burst_splitter_gran.sv
./third_party/axi/src/axi_burst_unwrap.sv
./third_party/axi/src/axi_bus_compare.sv
./third_party/axi/src/axi_cdc_dst.sv
./third_party/axi/src/axi_cdc_src.sv
./third_party/axi/src/axi_cut.sv
./third_party/axi/src/axi_delayer.sv
./third_party/axi/src/axi_demux_simple.sv
./third_party/axi/src/axi_dw_downsizer.sv
./third_party/axi/src/axi_dw_upsizer.sv
./third_party/axi/src/axi_fifo.sv
./third_party/axi/src/axi_fifo_delay_dyn.sv
./third_party/axi/src/axi_id_remap.sv
./third_party/axi/src/axi_id_prepend.sv
./third_party/axi/src/axi_inval_filter.sv
./third_party/axi/src/axi_isolate.sv
./third_party/axi/src/axi_join.sv
./third_party/axi/src/axi_lite_demux.sv
./third_party/axi/src/axi_lite_dw_converter.sv
./third_party/axi/src/axi_lite_from_mem.sv
./third_party/axi/src/axi_lite_join.sv
./third_party/axi/src/axi_lite_lfsr.sv
./third_party/axi/src/axi_lite_mailbox.sv
./third_party/axi/src/axi_lite_mux.sv
./third_party/axi/src/axi_lite_regs.sv
./third_party/axi/src/axi_lite_to_apb.sv
./third_party/axi/src/axi_lite_to_axi.sv
./third_party/axi/src/axi_modify_address.sv
./third_party/axi/src/axi_mux.sv
./third_party/axi/src/axi_rw_join.sv
./third_party/axi/src/axi_rw_split.sv
./third_party/axi/src/axi_serializer.sv
./third_party/axi/src/axi_slave_compare.sv
./third_party/axi/src/axi_throttle.sv
./third_party/axi/src/axi_to_detailed_mem.sv

// ---------- axi Level 3 ----------
./third_party/axi/src/axi_burst_splitter.sv
./third_party/axi/src/axi_cdc.sv
./third_party/axi/src/axi_demux.sv
./third_party/axi/src/axi_err_slv.sv
./third_party/axi/src/axi_dw_converter.sv
./third_party/axi/src/axi_from_mem.sv
./third_party/axi/src/axi_id_serialize.sv
./third_party/axi/src/axi_lfsr.sv
./third_party/axi/src/axi_multicut.sv
./third_party/axi/src/axi_to_axi_lite.sv
./third_party/axi/src/axi_to_mem.sv
./third_party/axi/src/axi_zero_mem.sv

// ---------- axi Level 4 ----------
./third_party/axi/src/axi_interleaved_xbar.sv
./third_party/axi/src/axi_iw_converter.sv
./third_party/axi/src/axi_lite_xbar.sv
./third_party/axi/src/axi_xbar_unmuxed.sv
./third_party/axi/src/axi_to_mem_banked.sv
./third_party/axi/src/axi_to_mem_interleaved.sv
./third_party/axi/src/axi_to_mem_split.sv

// ---------- axi Level 5 ----------
./third_party/axi/src/axi_xbar.sv

// ---------- axi Level 6 ----------
./third_party/axi/src/axi_xp.sv
./soc/rtl/ip/Bus_interconnects/axi_xbar_2x8_wrap.sv
// 旧 crossbar 一并编进来：模块名不同不会冲突，未被例化时综合会自动裁掉。
// 供 `+define+OLD_XBAR` 做"只换 crossbar、不动 filelist"的单变量对照。
./soc/rtl/ip/Bus_interconnects/AxiCrossbar_2x8.v
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

// FPU浮点扩展（CVFPU / OpenHW FPnew + LoongArch适配）——SoC 仿真原缺此块，
//   hw_fpu 软件走硬件 FPU，CPU 无条件例化 fpu_top，补齐(顺序照 soc_synth_filelist.f)
// common_cells 通用基础库(package 最先)
// [dedup] ./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/src/cf_math_pkg.sv
// [dedup] ./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/src/lzc.sv
// [dedup] ./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/src/rr_arb_tree.sv
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

// PLL仿真模型
./soc/rtl/ip/PLL_2019_2/clk_pll_sim_netlist.v

// ============================================
// CB_top_v2 加速器
// ============================================
./rtl/CB_top_v2.sv
./rtl/cb_controll_v2.sv
./rtl/mac_top_v2.sv
./rtl/PE_core_v2.sv
./rtl/write_out_v2.sv
./rtl/axi_dma_controller.sv
./rtl/fpmul_seq_pipeline.sv
./rtl/fpadd_seq.sv
./rtl/sram.sv

// FSA子模块
./rtl/fsa/fsa_ctrl_fsm.sv
./rtl/fsa/silu_ctrl_fsm.sv
./rtl/fsa/fsa_accumulator.sv
./rtl/fsa/fsa_acc_sram.sv
./rtl/fsa/FPAccUnit_pipe.sv
./rtl/fsa/RawFloat_Div.sv

// PE子模块
./rtl/PE/PE_retimed.sv
./rtl/PE/fp_pre_add.sv
./rtl/PE/fpadd_seq_2stage.sv
./rtl/PE/FPMacUnit.sv
./rtl/PE/RawFloat_MulAddExp2.sv
./rtl/PE/RawFloat_FMA_LA.sv
./rtl/PE/RawFloat_SplitIF.sv

// FSA CMP模块（Chisel生成）
./rtl/fsa_gen/chisel_fsa_fp32/CMP.sv
./rtl/fsa_gen/chisel_fsa_fp32/FPCmpUnit.sv
./rtl/fsa_gen/chisel_fsa_fp32/fp32_comparator.sv

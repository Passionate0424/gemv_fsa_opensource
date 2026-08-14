// =============================================================================
// pulp_axi_rtl_filelist.f —— pulp-platform/axi 可综合部分的编译顺序
// =============================================================================
// 供 VCS 仿真、Vivado 综合、DC 共用。仿真专用的 VIP（axi_test.sv +
// common_verification）在 scripts/pulp_axi_vip_filelist.f，不要混进综合流程。
//
// axi 的顺序取自 third_party/axi/Bender.yml 里 level 0→6 的分组（同 level 内按
// 字母序）——那是本版本(v0.39.9)自己声明的依赖层级，不是照抄别处的 filelist。
// 姊妹工程 fsa_llm_sv 那份 filelist 对应的是更新的 master（多 axi_demux_id_counters.sv），
// 套到 v0.39.9 上会找不到文件。
//
// common_cells 只列 axi_xbar/axi_dw_converter 这条路真正用到的子集，不是全部 83 个。
// 若 VCS 报 "module not found"，按报的名字补进下面对应位置即可。
// =============================================================================

+incdir+./third_party/axi/include
+incdir+./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/include

// ---------- common_cells（被 axi 依赖，需先编） ----------
// 全仓库只有 CVFPU 自带这一份 common_cells，pulp axi 与 CPU 的 FPU 共用它。
// 不能再引入第二份：同名的 cf_math_pkg / lzc / rr_arb_tree 会重复定义，Vivado 在
// 覆盖 package 后会把引用旧定义的模块（axi_xbar 等）从库里剔除，最终以
// "module 'axi_xbar' not found" 的形式报出来，与真因隔了几十行日志。
// 版本上它比 axi v0.39.9 的 Bender.yml 所声明的 common_cells 1.37.0 更新，
// 升级 axi 时需确认新版仍与这份兼容。
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

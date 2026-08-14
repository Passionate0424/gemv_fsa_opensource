// pulp axi_xbar 编译冒烟测试 filelist（第 1 步的工具链判据）
// 只验"工具链吃不吃得下 pulp 的 SV"，不验功能。
//
// 注意：这里把 scripts/pulp_axi_rtl_filelist.f 的内容**内联**了一份，不是 -f 嵌套——
// VCS 在 UUM 流程（-debug_access+all -kdb -lca）下不接受 filelist 里再写 -f/-F，
// 会报 "The option '-f/-F' cannot be used in UUM flow"。
// 顺序的权威来源仍是 pulp_axi_rtl_filelist.f（取自 axi v0.39.9 的 Bender.yml 分层），
// 改动请以那份为准并同步过来。

+incdir+./third_party/axi/include
+incdir+./soc/rtl/ip/open-la500/fpu/cvfpu/common_cells/include

// ---------- common_cells ----------
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

// ---------- axi Level 0 / 1 ----------
./third_party/axi/src/axi_pkg.sv
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

// ---------- axi Level 5 / 6 ----------
./third_party/axi/src/axi_xbar.sv
./third_party/axi/src/axi_xp.sv

// ---------- tb ----------
./tb/tb_pulp_xbar_smoke.sv

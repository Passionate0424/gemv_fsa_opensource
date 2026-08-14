// UVM验证环境filelist
// 用法: vcs -ntb_opts uvm-1.2 -f uvm/top/uvm_filelist.f -top tb_top

// ============================================================
// RTL源文件（复用fsa_e2e_filelist.f中的RTL部分）
// ============================================================
rtl/fpmul_seq_pipeline.sv
rtl/fpadd_seq.sv
rtl/sram_synth_wrapper.sv
soc/rtl/ip/ram_wrap/fpga_sram_dp.v
rtl/PE/RawFloat_SplitIF.sv
rtl/PE/RawFloat_FMA_LA.sv
rtl/PE/RawFloat_MulAddExp2.sv
rtl/PE/FPMacUnit.sv
rtl/PE/PE_retimed.sv
rtl/PE/fpadd_seq_2stage.sv
rtl/PE/fp_pre_add.sv
rtl/PE_core_v2.sv
rtl/fsa/fsa_ctrl_fsm.sv
rtl/fsa/silu_ctrl_fsm.sv
rtl/fsa_gen/chisel_fsa_fp32/FPCmpUnit.sv
rtl/fsa_gen/chisel_fsa_fp32/fp32_comparator.sv
rtl/fsa_gen/chisel_fsa_fp32/CMP.sv
rtl/fsa/RawFloat_Div.sv
rtl/fsa/FPAccUnit_pipe.sv
rtl/fsa/fsa_accumulator.sv
rtl/fsa/fsa_acc_sram.sv
rtl/write_out_v2.sv
rtl/mac_top_v2.sv
rtl/cb_controll_v2.sv
rtl/axi_dma_controller.sv
rtl/axi2sram_sp_ext.sv
rtl/CB_top_v2.sv
tb/tb_axi_ram_sp_ext.sv

// ============================================================
// UVM验证环境
// ============================================================

// DPI-C源文件
tb/dpi/e2e_golden.c
tb/dpi/silu_dpi.c

// Interfaces
uvm/interfaces/cb_top_if.sv
uvm/interfaces/axi_slv_if.sv
uvm/interfaces/axi_mst_if.sv

// DPI package
uvm/dpi/dpi_pkg.sv

// Agent packages
+incdir+uvm/agents/axi_slv
+incdir+uvm/agents/mem_model
+incdir+uvm/ral
+incdir+uvm/coverage
+incdir+uvm/env
+incdir+uvm/sequences
+incdir+uvm/tests
+incdir+uvm/dpi

uvm/agents/axi_slv/axi_slv_agent_pkg.sv
uvm/agents/mem_model/mem_model_pkg.sv
uvm/ral/cb_ral_pkg.sv
uvm/coverage/cb_coverage_pkg.sv
uvm/env/cb_top_env_pkg.sv
uvm/sequences/cb_top_seq_pkg.sv
uvm/tests/cb_top_test_pkg.sv

// Top
uvm/top/tb_top.sv

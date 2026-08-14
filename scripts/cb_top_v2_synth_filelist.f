// CB_top_v2 加速器IP综合 filelist
+incdir+./rtl/PE

// 顶层
./rtl/CB_top_v2.sv
./rtl/cb_controll_v2.sv
./rtl/mac_top_v2.sv
./rtl/PE_core_v2.sv
./rtl/write_out_v2.sv
./rtl/axi_dma_controller.sv
./rtl/fpmul_seq_pipeline.sv
./rtl/fpadd_seq.sv
./soc/rtl/ip/ram_wrap/fpga_sram_dp.v
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

// FSA CMP模块（快速比较器+generalAdder减法）
./rtl/fsa_gen/chisel_fsa_fp32/CMP.sv
./rtl/fsa_gen/chisel_fsa_fp32/FPCmpUnit.sv
./rtl/fsa_gen/chisel_fsa_fp32/fp32_comparator.sv

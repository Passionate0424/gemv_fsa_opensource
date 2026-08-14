// CB_top_v2 加速器 RTL filelist
// 顶层
../../rtl/CB_top_v2.sv
../../rtl/cb_controll_v2.sv
../../rtl/mac_top_v2.v
../../rtl/PE_core_v2.v
../../rtl/write_out_v2.v

// DMA + 基础运算
../../rtl/axi_dma_controller.sv
../../rtl/fpmul_seq_pipeline.sv
../../rtl/fpadd_seq.sv
../../rtl/sram.sv

// FSA子模块
../../rtl/fsa/fsa_ctrl_fsm.v
../../rtl/fsa/fsa_transposer.v
../../rtl/fsa/fsa_accumulator.v
../../rtl/fsa/fsa_acc_sram.v
../../rtl/fsa/FPAccUnit_pipe.sv
../../rtl/fsa/RawFloat_Div.sv
../../rtl/fsa/RawFloat_FMA.sv
../../rtl/fsa/RawFloat_SplitIF_1.sv
../../rtl/fsa/ShiftRightJam.sv

// PE子模块（v2使用PE_retimed链路）
../../rtl/PE/PE_retimed.sv
../../rtl/PE/FPMacUnit.sv
../../rtl/PE/RawFloat_MulAddExp2.sv
../../rtl/PE/RawFloat_FMA.sv
../../rtl/PE/RawFloat_SplitIF.sv

// CB_top_v2 虚拟Sequencer
// 持有axi_slv_sequencer和mem_model的handle，供virtual sequence统一调度
class cb_top_virtual_seqr extends uvm_sequencer;

  axi_slv_sequencer axi_slv_sqr;
  mem_model         mem;

  `uvm_component_utils(cb_top_virtual_seqr)

  function new(string name = "cb_top_virtual_seqr", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass

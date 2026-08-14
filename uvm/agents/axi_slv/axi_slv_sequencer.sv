// AXI Slave Sequencer（标准UVM sequencer，无额外逻辑）
class axi_slv_sequencer extends uvm_sequencer #(axi_slv_seq_item);

  `uvm_component_utils(axi_slv_sequencer)

  function new(string name = "axi_slv_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass

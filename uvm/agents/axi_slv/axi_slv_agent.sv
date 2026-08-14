// AXI Slave Agent（Active模式）
// 封装driver + monitor + sequencer，模拟CPU侧CSR访问
class axi_slv_agent extends uvm_agent;

  axi_slv_driver    drv;
  axi_slv_monitor   mon;
  axi_slv_sequencer sqr;

  `uvm_component_utils(axi_slv_agent)

  function new(string name = "axi_slv_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon = axi_slv_monitor::type_id::create("mon", this);
    if (get_is_active() == UVM_ACTIVE) begin
      drv = axi_slv_driver::type_id::create("drv", this);
      sqr = axi_slv_sequencer::type_id::create("sqr", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (get_is_active() == UVM_ACTIVE) begin
      drv.seq_item_port.connect(sqr.seq_item_export);
    end
  endfunction

endclass

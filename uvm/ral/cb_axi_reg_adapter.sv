// AXI寄存器适配器
// 将UVM RAL的uvm_reg_bus_op转换为axi_slv_seq_item，反之亦然
class cb_axi_reg_adapter extends uvm_reg_adapter;
  `uvm_object_utils(cb_axi_reg_adapter)

  function new(string name = "cb_axi_reg_adapter");
    super.new(name);
    supports_byte_enable = 0;
    provides_responses   = 0;  // driver原地修改item的rdata/resp，无需put_response
  endfunction

  // RAL前门写/读 → 生成AXI事务
  virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
    axi_slv_seq_item item = axi_slv_seq_item::type_id::create("reg_item");
    item.constraint_mode(0);
    item.addr  = rw.addr;
    item.wdata = rw.data;
    item.rw    = (rw.kind == UVM_WRITE) ? axi_slv_seq_item::AXI_WRITE
                                        : axi_slv_seq_item::AXI_READ;
    return item;
  endfunction

  // AXI事务完成 → 回填RAL
  virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
    axi_slv_seq_item item;
    if (!$cast(item, bus_item))
      `uvm_fatal("CAST_FAIL", "bus2reg: cast to axi_slv_seq_item failed")
    rw.addr   = item.addr;
    rw.data   = (item.rw == axi_slv_seq_item::AXI_READ) ? item.rdata : item.wdata;
    rw.kind   = (item.rw == axi_slv_seq_item::AXI_WRITE) ? UVM_WRITE : UVM_READ;
    rw.status = (item.resp == 2'b00) ? UVM_IS_OK : UVM_NOT_OK;
  endfunction
endclass

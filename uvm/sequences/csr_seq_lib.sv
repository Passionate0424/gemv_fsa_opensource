// CSR Sequence Library
// 提供CSR读写的基本sequence，供其他sequence复用

// 单次CSR写sequence
class csr_write_seq extends uvm_sequence #(axi_slv_seq_item);

  logic [31:0] addr;
  logic [31:0] data;

  `uvm_object_utils(csr_write_seq)

  function new(string name = "csr_write_seq");
    super.new(name);
  endfunction

  task body();
    axi_slv_seq_item item = axi_slv_seq_item::type_id::create("item");
    start_item(item);
    item.rw    = axi_slv_seq_item::AXI_WRITE;
    item.addr  = addr;
    item.wdata = data;
    finish_item(item);
  endtask

endclass

// 单次CSR读sequence
class csr_read_seq extends uvm_sequence #(axi_slv_seq_item);

  logic [31:0] addr;
  logic [31:0] rdata;  // 读回数据

  `uvm_object_utils(csr_read_seq)

  function new(string name = "csr_read_seq");
    super.new(name);
  endfunction

  task body();
    axi_slv_seq_item item = axi_slv_seq_item::type_id::create("item");
    start_item(item);
    item.rw   = axi_slv_seq_item::AXI_READ;
    item.addr = addr;
    finish_item(item);
    rdata = item.rdata;
  endtask

endclass

// 轮询STATUS.done的sequence
class csr_poll_done_seq extends uvm_sequence #(axi_slv_seq_item);

  int timeout_cycles = 200000;
  bit done_flag = 0;

  `uvm_object_utils(csr_poll_done_seq)

  function new(string name = "csr_poll_done_seq");
    super.new(name);
  endfunction

  task body();
    axi_slv_seq_item item;
    for (int i = 0; i < timeout_cycles; i += 10) begin
      item = axi_slv_seq_item::type_id::create("item");
      start_item(item);
      item.rw   = axi_slv_seq_item::AXI_READ;
      item.addr = 32'h0004;  // REG_STATUS
      finish_item(item);
      if (item.rdata[1]) begin  // done bit
        done_flag = 1;
        return;
      end
      // 等待若干周期再轮询（减少AXI总线占用）
      #200;
    end
    `uvm_error("POLL_TIMEOUT", $sformatf("轮询STATUS.done超时: %0d cycles", timeout_cycles))
  endtask

endclass

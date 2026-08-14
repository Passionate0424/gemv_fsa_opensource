// AXI Slave Agent事务对象
// 描述一次CSR读或写操作
class axi_slv_seq_item extends uvm_sequence_item;

  // 事务类型
  typedef enum bit {AXI_WRITE = 0, AXI_READ = 1} axi_rw_e;

  rand axi_rw_e     rw;
  rand logic [31:0] addr;
  rand logic [31:0] wdata;    // 写数据（写操作时有效）
  logic [31:0]      rdata;    // 读数据（读操作完成后由driver填充）
  logic [1:0]       resp;     // 响应（driver填充）

  // CSR访问固定为单拍
  logic [4:0]  id    = 5'd1;
  logic [7:0]  len   = 8'd0;     // 单拍
  logic [2:0]  size  = 3'b010;   // 4字节
  logic [1:0]  burst = 2'b01;    // INCR
  logic [3:0]  strb  = 4'hF;    // 全字节有效

  `uvm_object_utils_begin(axi_slv_seq_item)
    `uvm_field_enum(axi_rw_e, rw, UVM_ALL_ON)
    `uvm_field_int(addr,  UVM_ALL_ON)
    `uvm_field_int(wdata, UVM_ALL_ON)
    `uvm_field_int(rdata, UVM_ALL_ON)
    `uvm_field_int(resp,  UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "axi_slv_seq_item");
    super.new(name);
  endfunction

  // 地址约束：CSR空间 0x0000~0x00FF
  constraint c_addr_align { addr[1:0] == 2'b00; }
  constraint c_addr_range { addr inside {[32'h0000:32'h00FF]}; }

endclass

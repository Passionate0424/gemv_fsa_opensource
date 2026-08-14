// AXI Slave Driver
// 驱动AXI Slave端口，模拟CPU侧发起CSR读写
// 使用直接信号驱动（与现有directed TB的axi_write/axi_read时序一致）
class axi_slv_driver extends uvm_driver #(axi_slv_seq_item);

  virtual axi_slv_if vif;

  `uvm_component_utils(axi_slv_driver)

  function new(string name = "axi_slv_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axi_slv_if)::get(this, "", "axi_slv_vif", vif))
      `uvm_fatal("NOVIF", "未获取到axi_slv_vif")
  endfunction

  task run_phase(uvm_phase phase);
    axi_slv_seq_item item;

    init_signals();
    wait(vif.rst_n === 1'b1);
    @(posedge vif.clk);

    forever begin
      seq_item_port.get_next_item(item);
      if (item.rw == axi_slv_seq_item::AXI_WRITE)
        drive_write(item);
      else
        drive_read(item);
      seq_item_port.item_done();
    end
  endtask

  task init_signals();
    vif.awvalid = 1'b0;
    vif.wvalid  = 1'b0;
    vif.bready  = 1'b1;
    vif.arvalid = 1'b0;
    vif.rready  = 1'b1;
  endtask

  // AXI写操作（时序与tb_fsa_e2e中的axi_write一致）
  task drive_write(axi_slv_seq_item item);
    // AW通道
    @(posedge vif.clk);
    vif.awid    <= item.id;
    vif.awaddr  <= item.addr;
    vif.awlen   <= item.len;
    vif.awsize  <= item.size;
    vif.awburst <= item.burst;
    vif.awlock  <= 1'b0;
    vif.awcache <= 4'h0;
    vif.awprot  <= 3'h0;
    vif.awvalid <= 1'b1;

    while (!vif.awready) @(posedge vif.clk);
    @(posedge vif.clk);
    vif.awvalid <= 1'b0;

    // W通道：总线 64 位而 CSR 是 32 位寄存器，数据要落在 addr[2] 指定的那半数据道
    vif.wdata  <= {2{item.wdata}};
    vif.wstrb  <= item.addr[2] ? {item.strb, 4'h0} : {4'h0, item.strb};
    vif.wlast  <= 1'b1;
    vif.wvalid <= 1'b1;

    while (!vif.wready) @(posedge vif.clk);
    @(posedge vif.clk);
    vif.wvalid <= 1'b0;

    // 等待B响应
    wait(vif.bvalid === 1'b1);
    item.resp = vif.bresp;
    @(posedge vif.clk);
  endtask

  // AXI读操作（时序与tb_fsa_e2e中的axi_read一致）
  task drive_read(axi_slv_seq_item item);
    @(posedge vif.clk);
    vif.arid    <= item.id;
    vif.araddr  <= item.addr;
    vif.arlen   <= item.len;
    vif.arsize  <= item.size;
    vif.arburst <= item.burst;
    vif.arlock  <= 1'b0;
    vif.arcache <= 4'h0;
    vif.arprot  <= 3'h0;
    vif.arvalid <= 1'b1;

    while (!vif.arready) @(posedge vif.clk);
    @(posedge vif.clk);
    vif.arvalid <= 1'b0;

    // 等待R响应
    wait(vif.rvalid === 1'b1);
    item.rdata = item.addr[2] ? vif.rdata[63:32] : vif.rdata[31:0];
    item.resp  = vif.rresp;
    @(posedge vif.clk);
  endtask

endclass

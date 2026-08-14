// AXI Slave Monitor
// 被动监控AXI Slave端口上的所有CSR事务
class axi_slv_monitor extends uvm_monitor;

  virtual axi_slv_if vif;

  uvm_analysis_port #(axi_slv_seq_item) ap;

  `uvm_component_utils(axi_slv_monitor)

  function new(string name = "axi_slv_monitor", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual axi_slv_if)::get(this, "", "axi_slv_vif", vif))
      `uvm_fatal("NOVIF", "未获取到axi_slv_vif")
  endfunction

  task run_phase(uvm_phase phase);
    wait(vif.rst_n === 1'b1);
    fork
      monitor_writes();
      monitor_reads();
    join
  endtask

  // 监控写事务：捕获AW+W+B完整握手
  task monitor_writes();
    axi_slv_seq_item item;
    forever begin
      // 等待AW握手（valid && ready同时为高）
      do @(vif.mon_cb); while (!(vif.mon_cb.awvalid && vif.mon_cb.awready));
      item = axi_slv_seq_item::type_id::create("wr_item");
      item.rw    = axi_slv_seq_item::AXI_WRITE;
      item.addr  = vif.mon_cb.awaddr;
      item.id    = vif.mon_cb.awid;

      // 等待W握手
      do @(vif.mon_cb); while (!(vif.mon_cb.wvalid && vif.mon_cb.wready));
      // 64 位总线上取 addr[2] 指定的那半数据道，还原成寄存器语义的 32 位值
      item.wdata = item.addr[2] ? vif.mon_cb.wdata[63:32] : vif.mon_cb.wdata[31:0];

      // 等待B握手（bvalid && bready）
      do @(vif.mon_cb); while (!(vif.mon_cb.bvalid && vif.mon_cb.bready));
      item.resp = vif.mon_cb.bresp;

      ap.write(item);
      `uvm_info("AXI_SLV_MON", $sformatf("WR addr=0x%08h data=0x%08h resp=%0d",
                item.addr, item.wdata, item.resp), UVM_HIGH)
    end
  endtask

  // 监控读事务：捕获AR+R完整握手
  task monitor_reads();
    axi_slv_seq_item item;
    forever begin
      // 等待AR握手
      do @(vif.mon_cb); while (!(vif.mon_cb.arvalid && vif.mon_cb.arready));
      item = axi_slv_seq_item::type_id::create("rd_item");
      item.rw   = axi_slv_seq_item::AXI_READ;
      item.addr = vif.mon_cb.araddr;
      item.id   = vif.mon_cb.arid;

      // 等待R握手（rvalid && rready）
      do @(vif.mon_cb); while (!(vif.mon_cb.rvalid && vif.mon_cb.rready));
      item.rdata = item.addr[2] ? vif.mon_cb.rdata[63:32] : vif.mon_cb.rdata[31:0];
      item.resp  = vif.mon_cb.rresp;

      ap.write(item);
      `uvm_info("AXI_SLV_MON", $sformatf("RD addr=0x%08h data=0x%08h resp=%0d",
                item.addr, item.rdata, item.resp), UVM_HIGH)
    end
  endtask

endclass

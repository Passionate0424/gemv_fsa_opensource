// AXI4 Master接口（连接DUT的m_axi端口，mem_model作为Slave响应）
// ID宽度4bit，数据/地址宽度32bit
interface axi_mst_if (input logic clk, input logic rst_n);

  // Write Address Channel (DUT驱动)
  logic [3:0]  awid;
  logic [31:0] awaddr;
  logic [7:0]  awlen;
  logic [2:0]  awsize;
  logic [1:0]  awburst;
  logic        awlock;
  logic [3:0]  awcache;
  logic [2:0]  awprot;
  logic        awvalid;
  logic        awready;   // mem_model驱动

  // Write Data Channel (DUT驱动)
  logic [63:0] wdata;
  logic [7:0]  wstrb;
  logic        wlast;
  logic        wvalid;
  logic        wready;    // mem_model驱动

  // Write Response Channel (mem_model驱动)
  logic [3:0]  bid;
  logic [1:0]  bresp;
  logic        bvalid;
  logic        bready;    // DUT驱动

  // Read Address Channel (DUT驱动)
  logic [3:0]  arid;
  logic [31:0] araddr;
  logic [7:0]  arlen;
  logic [2:0]  arsize;
  logic [1:0]  arburst;
  logic        arlock;
  logic [3:0]  arcache;
  logic [2:0]  arprot;
  logic        arvalid;
  logic        arready;   // mem_model驱动

  // Read Data Channel (mem_model驱动)
  logic [3:0]  rid;
  logic [63:0] rdata;
  logic [1:0]  rresp;
  logic        rlast;
  logic        rvalid;
  logic        rready;    // DUT驱动

  // mem_model驱动用clocking block（作为AXI Slave侧响应DUT请求）
  clocking slv_cb @(posedge clk);
    input  awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awvalid;
    output awready;
    input  wdata, wstrb, wlast, wvalid;
    output wready;
    output bid, bresp, bvalid;
    input  bready;
    input  arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arvalid;
    output arready;
    output rid, rdata, rresp, rlast, rvalid;
    input  rready;
  endclocking

  // Passive monitor clocking block
  clocking mon_cb @(posedge clk);
    input awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awvalid, awready;
    input wdata, wstrb, wlast, wvalid, wready;
    input bid, bresp, bvalid, bready;
    input arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arvalid, arready;
    input rid, rdata, rresp, rlast, rvalid, rready;
  endclocking

  modport slave   (clocking slv_cb, input rst_n);
  modport monitor (clocking mon_cb, input rst_n);

endinterface

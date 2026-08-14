// AXI4 Slave接口（连接DUT的s_axi端口，UVM环境作为Master驱动）
// ID宽度5bit，数据/地址宽度32bit
interface axi_slv_if (input logic clk, input logic rst_n);

  // Write Address Channel
  logic [4:0]  awid;
  logic [31:0] awaddr;
  logic [7:0]  awlen;
  logic [2:0]  awsize;
  logic [1:0]  awburst;
  logic        awlock;
  logic [3:0]  awcache;
  logic [2:0]  awprot;
  logic        awvalid;
  logic        awready;

  // Write Data Channel
  logic [63:0] wdata;
  logic [7:0]  wstrb;
  logic        wlast;
  logic        wvalid;
  logic        wready;

  // Write Response Channel
  logic [4:0]  bid;
  logic [1:0]  bresp;
  logic        bvalid;
  logic        bready;

  // Read Address Channel
  logic [4:0]  arid;
  logic [31:0] araddr;
  logic [7:0]  arlen;
  logic [2:0]  arsize;
  logic [1:0]  arburst;
  logic        arlock;
  logic [3:0]  arcache;
  logic [2:0]  arprot;
  logic        arvalid;
  logic        arready;

  // Read Data Channel
  logic [4:0]  rid;
  logic [63:0] rdata;
  logic [1:0]  rresp;
  logic        rlast;
  logic        rvalid;
  logic        rready;

  // Driver clocking block（UVM driver驱动，作为AXI Master侧）
  clocking drv_cb @(posedge clk);
    output awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awvalid;
    input  awready;
    output wdata, wstrb, wlast, wvalid;
    input  wready;
    input  bid, bresp, bvalid;
    output bready;
    output arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arvalid;
    input  arready;
    input  rid, rdata, rresp, rlast, rvalid;
    output rready;
  endclocking

  // Monitor clocking block（被动采样）
  clocking mon_cb @(posedge clk);
    input awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awvalid, awready;
    input wdata, wstrb, wlast, wvalid, wready;
    input bid, bresp, bvalid, bready;
    input arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arvalid, arready;
    input rid, rdata, rresp, rlast, rvalid, rready;
  endclocking

  modport driver  (clocking drv_cb, input rst_n);
  modport monitor (clocking mon_cb, input rst_n);

endinterface

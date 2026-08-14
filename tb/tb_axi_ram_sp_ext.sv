////////////////////////////////////////////////////////////////
// tb_axi_ram_sp_ext
//
// 通用 AXI 存储模型，供 TB 作为 DDR / SRAM 后端使用
// 支持读写握手、burst 访问和初始化文件加载。
//
// 这是 testbench helper，不是独立回归用例。
////////////////////////////////////////////////////////////////
module tb_axi_ram_sp_ext #(
    parameter Init_File = "none",
    parameter int MEM_AW = 18
) (
    input         aclk,
    input         aresetn,
    input  [4 :0] axi_arid,
    input  [31:0] axi_araddr,
    input  [7 :0] axi_arlen,
    input  [2 :0] axi_arsize,
    input  [1 :0] axi_arburst,
    input  [1 :0] axi_arlock,
    input  [3 :0] axi_arcache,
    input  [2 :0] axi_arprot,
    input         axi_arvalid,
    output        axi_arready,
    output [4 :0] axi_rid,
    output [63:0] axi_rdata,
    output [1 :0] axi_rresp,
    output        axi_rlast,
    output        axi_rvalid,
    input         axi_rready,
    input  [4 :0] axi_awid,
    input  [31:0] axi_awaddr,
    input  [7 :0] axi_awlen,
    input  [2 :0] axi_awsize,
    input  [1 :0] axi_awburst,
    input  [1 :0] axi_awlock,
    input  [3 :0] axi_awcache,
    input  [2 :0] axi_awprot,
    input         axi_awvalid,
    output        axi_awready,
    input  [63:0] axi_wdata,
    input  [7 :0] axi_wstrb,
    input         axi_wlast,
    input         axi_wvalid,
    output        axi_wready,
    output [4 :0] axi_bid,
    output [1 :0] axi_bresp,
    output        axi_bvalid,
    input         axi_bready
);

  localparam int MEM_DEPTH = (1 << MEM_AW);

  reg [31:0] mem [0:MEM_DEPTH-1];

  wire        sram_req;
  wire        sram_we;
  wire [31:0] sram_addr;
  wire [7 :0] sram_be;
  wire [63:0] sram_wdata;
  wire [63:0] sram_rdata;

  reg [MEM_AW-1:0] read_addr_q;

  integer init_idx;
  initial begin
    for (init_idx = 0; init_idx < MEM_DEPTH; init_idx = init_idx + 1) begin
      mem[init_idx] = 32'b0;
    end
    if (Init_File != "none") begin
      $readmemb(Init_File, mem);
    end
    read_addr_q = {MEM_AW{1'b0}};
  end

  axi2sram_sp_ext #(
      .AXI_ID_WIDTH(5),
      .AXI_ADDR_WIDTH(32),
      .AXI_DATA_WIDTH(64)
  ) u_axi_sram_sp_ext (
      .clock(aclk),
      .rst_n(aresetn),
      .s_araddr(axi_araddr),
      .s_arburst(axi_arburst),
      .s_arcache(axi_arcache),
      .s_arid(axi_arid),
      .s_arlen(axi_arlen),
      .s_arlock(axi_arlock[0]),
      .s_arprot(axi_arprot),
      .s_arready(axi_arready),
      .s_arsize(axi_arsize),
      .s_arvalid(axi_arvalid),
      .s_awaddr(axi_awaddr),
      .s_awburst(axi_awburst),
      .s_awcache(axi_awcache),
      .s_awid(axi_awid),
      .s_awlen(axi_awlen),
      .s_awlock(axi_awlock[0]),
      .s_awprot(axi_awprot),
      .s_awready(axi_awready),
      .s_awsize(axi_awsize),
      .s_awvalid(axi_awvalid),
      .s_bid(axi_bid),
      .s_bready(axi_bready),
      .s_bresp(axi_bresp),
      .s_bvalid(axi_bvalid),
      .s_rdata(axi_rdata),
      .s_rid(axi_rid),
      .s_rlast(axi_rlast),
      .s_rready(axi_rready),
      .s_rresp(axi_rresp),
      .s_rvalid(axi_rvalid),
      .s_wdata(axi_wdata),
      .s_wlast(axi_wlast),
      .s_wready(axi_wready),
      .s_wstrb(axi_wstrb),
      .s_wvalid(axi_wvalid),
      .req_o(sram_req),
      .we_o(sram_we),
      .addr_o(sram_addr),
      .be_o(sram_be),
      .data_o(sram_wdata),
      .data_i(sram_rdata)
  );

  // 总线 64 位，但 mem 仍按 32 位字组织——初始化文件是按 32 位字写的，改成 64 位 entry
  // 会让全部测试数据失效。一次 64 位访问 = 相邻两个字。
  //
  // 索引必须按 8 字节对齐取（addr[2] 强制为 0），不能直接 addr>>2：AXI 允许非对齐 INCR
  // 起始，master 发 araddr=…04 时协议规定首拍返回**包含该地址的那个对齐 8 字节**
  // （即 …00..…07），由 master 自己丢掉不属于它的半个字。若这里按 addr>>2 取，
  // 模型等于把数据替 master 对齐了一次，master 再丢一次高/低半就丢错了字——
  // 表现为奇数行（stride 非 8 倍数时 offset=4 的那些行）数值全错。
  wire [MEM_AW-1:0] w_idx0 = {sram_addr[MEM_AW+1:3], 1'b0};
  wire [MEM_AW-1:0] w_idx1 = w_idx0 + 1'b1;

  always @(posedge aclk) begin
    if (sram_req && sram_we) begin
      if (sram_be[0]) mem[w_idx0][7:0]   <= sram_wdata[7:0];
      if (sram_be[1]) mem[w_idx0][15:8]  <= sram_wdata[15:8];
      if (sram_be[2]) mem[w_idx0][23:16] <= sram_wdata[23:16];
      if (sram_be[3]) mem[w_idx0][31:24] <= sram_wdata[31:24];
      if (sram_be[4]) mem[w_idx1][7:0]   <= sram_wdata[39:32];
      if (sram_be[5]) mem[w_idx1][15:8]  <= sram_wdata[47:40];
      if (sram_be[6]) mem[w_idx1][23:16] <= sram_wdata[55:48];
      if (sram_be[7]) mem[w_idx1][31:24] <= sram_wdata[63:56];
    end
  end

  // 异步读（匹配板上外部SRAM行为：地址变→数据立即变）
  assign sram_rdata = {mem[w_idx1], mem[w_idx0]};

endmodule

// =============================================================================
// axi_xbar_2x8_wrap —— pulp-platform axi_xbar 的扁平端口 wrapper
// =============================================================================
// 端口表与 AxiCrossbar_2x8.v（SpinalHDL v1.10.1 生成物）**逐字对齐**，是 drop-in
// 替换件：soc_top.v 里只需把例化的模块名换掉，连线一行不用改。
//
// 为什么要 wrapper：pulp 的 axi_xbar 用 SystemVerilog struct 传通道，而 soc_top.v
// 是纯 Verilog、按扁平信号名连线，吃不了 struct。所以在这里把 struct 拍平。
// 姊妹工程 fsa_llm_sv 的 fsa_axi64_to_axi32_adapter.sv 是同一范式。
//
// **third_party/ 下的 pulp 源码一行都不改**，所有适配都收在本文件里（见
// third_party/README.md）。
//
// 位宽拓扑。axi_xbar 的 DataWidth 是全局参数、所有端口同宽，边缘的位宽差异只能靠
// 转换器抹平——本模块因此不只是 crossbar 的包装，master 侧还含升宽：
//
//   CPU(DATA_W) ─► dw_up ─┐                       ┌─► RAM      (DATA_W_WIDE)
//                          ├─► axi_xbar(WIDE) ────┤
//   DMA(DATA_W_WIDE) ─────┘                       └─► 外设 ×4  (DATA_W_WIDE)
//
// 只有 CPU 需要升宽：它的 core_top 数据总线在 mycpu_top.v 里写死 32 位、无位宽参数。
//
// slave 侧不放转换器：四个外设都只服务单拍寄存器访问，在各自模块边界按 wstrb/addr[2]
// 选半字就够了，比每口一个约 2700 LUT 的降宽器省得多。
// DATA_W_WIDE == DATA_W 时升宽器退化为直通，即回到纯等宽配置。
// master 侧 ID 4 位，slave 侧 5 位（xbar 自动前缀 master 索引）。
//
// LatencyMode = CUT_ALL_AX：只在 AW/AR 地址通道插 spill register，数据通道不插。
// CPU 只有 1 笔 outstanding、严格顺序，单拍访问延迟直接暴露在 ROPE/RMSNORM 段上，
// 不宜多插级；且这最接近原 SpinalHDL crossbar 的默认行为（地址通道有 valid pipe），
// 便于把"换件"当单一变量做性能定标。实测换件总代价 +0.84%，关键路径不在互连上。
// =============================================================================

`include "axi/typedef.svh"

// 模块头里显式 import：VCS 把所有文件编进同一作用域，不 import 也能解析 axi_pkg::，
// 但 Vivado 会报 'axi_pkg' is not declared。pulp 自己也是这么写的
// （见 axi_xbar.sv 的 `module axi_xbar import cf_math_pkg::idx_width;`）。
module axi_xbar_2x8_wrap
  import axi_pkg::*;
#(
  parameter int unsigned DATA_W      = 32,       // CPU 与外设侧（窄）
  // xbar 内核、RAM 与 DMA 侧。默认与 DATA_W 相等，即退化为一个普通的等宽 crossbar，
  // 两侧转换器直通——加宽是例化点的显式选择，不会因为默认值而被动生效。
  parameter int unsigned DATA_W_WIDE = DATA_W
) (
  // ---------------- master 0：CPU（经 Axi_CDC） ----------------
  input  wire                axiIn_0_awvalid,
  output wire                axiIn_0_awready,
  input  wire [31:0]         axiIn_0_awaddr,
  input  wire [3:0]          axiIn_0_awid,
  input  wire [7:0]          axiIn_0_awlen,
  input  wire [2:0]          axiIn_0_awsize,
  input  wire [1:0]          axiIn_0_awburst,
  input  wire [0:0]          axiIn_0_awlock,
  input  wire [3:0]          axiIn_0_awcache,
  input  wire [2:0]          axiIn_0_awprot,
  input  wire                axiIn_0_wvalid,
  output wire                axiIn_0_wready,
  input  wire [DATA_W-1:0]   axiIn_0_wdata,
  input  wire [DATA_W/8-1:0] axiIn_0_wstrb,
  input  wire                axiIn_0_wlast,
  output wire                axiIn_0_bvalid,
  input  wire                axiIn_0_bready,
  output wire [3:0]          axiIn_0_bid,
  output wire [1:0]          axiIn_0_bresp,
  input  wire                axiIn_0_arvalid,
  output wire                axiIn_0_arready,
  input  wire [31:0]         axiIn_0_araddr,
  input  wire [3:0]          axiIn_0_arid,
  input  wire [7:0]          axiIn_0_arlen,
  input  wire [2:0]          axiIn_0_arsize,
  input  wire [1:0]          axiIn_0_arburst,
  input  wire [0:0]          axiIn_0_arlock,
  input  wire [3:0]          axiIn_0_arcache,
  input  wire [2:0]          axiIn_0_arprot,
  output wire                axiIn_0_rvalid,
  input  wire                axiIn_0_rready,
  output wire [DATA_W-1:0]   axiIn_0_rdata,
  output wire [3:0]          axiIn_0_rid,
  output wire [1:0]          axiIn_0_rresp,
  output wire                axiIn_0_rlast,

  // ---------------- master 1：加速器 DMA ----------------
  input  wire                axiIn_1_awvalid,
  output wire                axiIn_1_awready,
  input  wire [31:0]         axiIn_1_awaddr,
  input  wire [3:0]          axiIn_1_awid,
  input  wire [7:0]          axiIn_1_awlen,
  input  wire [2:0]          axiIn_1_awsize,
  input  wire [1:0]          axiIn_1_awburst,
  input  wire [0:0]          axiIn_1_awlock,
  input  wire [3:0]          axiIn_1_awcache,
  input  wire [2:0]          axiIn_1_awprot,
  input  wire                axiIn_1_wvalid,
  output wire                axiIn_1_wready,
  input  wire [DATA_W_WIDE-1:0]   axiIn_1_wdata,
  input  wire [DATA_W_WIDE/8-1:0] axiIn_1_wstrb,
  input  wire                axiIn_1_wlast,
  output wire                axiIn_1_bvalid,
  input  wire                axiIn_1_bready,
  output wire [3:0]          axiIn_1_bid,
  output wire [1:0]          axiIn_1_bresp,
  input  wire                axiIn_1_arvalid,
  output wire                axiIn_1_arready,
  input  wire [31:0]         axiIn_1_araddr,
  input  wire [3:0]          axiIn_1_arid,
  input  wire [7:0]          axiIn_1_arlen,
  input  wire [2:0]          axiIn_1_arsize,
  input  wire [1:0]          axiIn_1_arburst,
  input  wire [0:0]          axiIn_1_arlock,
  input  wire [3:0]          axiIn_1_arcache,
  input  wire [2:0]          axiIn_1_arprot,
  output wire                axiIn_1_rvalid,
  input  wire                axiIn_1_rready,
  output wire [DATA_W_WIDE-1:0]   axiIn_1_rdata,
  output wire [3:0]          axiIn_1_rid,
  output wire [1:0]          axiIn_1_rresp,
  output wire                axiIn_1_rlast,

  // ---------------- slave 0..7 ----------------
  // w 是该口的数据位宽：全部 slave 口都以 DATA_W_WIDE 直连 xbar。
  `define XBAR_SLV_PORTS(n, w)                       \
  output wire                axiOut_``n``_awvalid,   \
  input  wire                axiOut_``n``_awready,   \
  output wire [31:0]         axiOut_``n``_awaddr,    \
  output wire [4:0]          axiOut_``n``_awid,      \
  output wire [7:0]          axiOut_``n``_awlen,     \
  output wire [2:0]          axiOut_``n``_awsize,    \
  output wire [1:0]          axiOut_``n``_awburst,   \
  output wire [0:0]          axiOut_``n``_awlock,    \
  output wire [3:0]          axiOut_``n``_awcache,   \
  output wire [2:0]          axiOut_``n``_awprot,    \
  output wire                axiOut_``n``_wvalid,    \
  input  wire                axiOut_``n``_wready,    \
  output wire [w-1:0]        axiOut_``n``_wdata,     \
  output wire [w/8-1:0]      axiOut_``n``_wstrb,     \
  output wire                axiOut_``n``_wlast,     \
  input  wire                axiOut_``n``_bvalid,    \
  output wire                axiOut_``n``_bready,    \
  input  wire [4:0]          axiOut_``n``_bid,       \
  input  wire [1:0]          axiOut_``n``_bresp,     \
  output wire                axiOut_``n``_arvalid,   \
  input  wire                axiOut_``n``_arready,   \
  output wire [31:0]         axiOut_``n``_araddr,    \
  output wire [4:0]          axiOut_``n``_arid,      \
  output wire [7:0]          axiOut_``n``_arlen,     \
  output wire [2:0]          axiOut_``n``_arsize,    \
  output wire [1:0]          axiOut_``n``_arburst,   \
  output wire [0:0]          axiOut_``n``_arlock,    \
  output wire [3:0]          axiOut_``n``_arcache,   \
  output wire [2:0]          axiOut_``n``_arprot,    \
  input  wire                axiOut_``n``_rvalid,    \
  output wire                axiOut_``n``_rready,    \
  input  wire [w-1:0]        axiOut_``n``_rdata,     \
  input  wire [4:0]          axiOut_``n``_rid,       \
  input  wire [1:0]          axiOut_``n``_rresp,     \
  input  wire                axiOut_``n``_rlast,

  `XBAR_SLV_PORTS(0, DATA_W_WIDE)   // RAM
  `XBAR_SLV_PORTS(1, DATA_W_WIDE)   // UART/APB
  `XBAR_SLV_PORTS(2, DATA_W_WIDE)   // DVI
  `XBAR_SLV_PORTS(3, DATA_W_WIDE)   // confreg
  `XBAR_SLV_PORTS(4, DATA_W_WIDE)   // 加速器 CSR

  input  wire clk,
  input  wire resetn
);

  // ---------------------------------------------------------------------------
  // 类型与配置
  // ---------------------------------------------------------------------------
  localparam int unsigned ADDR_W   = 32;
  localparam int unsigned STRB_W   = DATA_W / 8;
  localparam int unsigned ID_SLV_W = 4;   // master 侧
  localparam int unsigned USER_W   = 1;
  localparam int unsigned N_MST    = 2;   // 接 master 的口（pulp 叫 slave port）
  localparam int unsigned N_SLV    = 5;   // 接 slave 的口（pulp 叫 master port）
  localparam int unsigned ID_MST_W = ID_SLV_W + $clog2(N_MST);  // = 5

  typedef logic [ADDR_W-1:0]   addr_t;
  typedef logic [DATA_W-1:0]   data_t;
  typedef logic [STRB_W-1:0]   strb_t;
  typedef logic [ID_SLV_W-1:0] id_slv_t;
  typedef logic [ID_MST_W-1:0] id_mst_t;
  typedef logic [USER_W-1:0]   user_t;

  // 命名沿用 pulp 的口径：slv* 是"接 master 的口"（ID 4 位），mst* 是"接 slave 的口"
  // （ID 5 位，xbar 前缀了 master 索引）；后缀 w 表示宽侧。窄侧只有 master 那一套，
  // slave 侧全是宽的。
  localparam int unsigned STRBW_W = DATA_W_WIDE / 8;
  typedef logic [DATA_W_WIDE-1:0] dataw_t;
  typedef logic [STRBW_W-1:0]     strbw_t;

  `AXI_TYPEDEF_ALL(slv,  addr_t, id_slv_t, data_t,  strb_t,  user_t)
  `AXI_TYPEDEF_ALL(slvw, addr_t, id_slv_t, dataw_t, strbw_t, user_t)
  `AXI_TYPEDEF_ALL(mstw, addr_t, id_mst_t, dataw_t, strbw_t, user_t)

  // 送给 axi_xbar 的地址规则类型。布局与 axi_pkg::xbar_rule_32_t 逐位一致
  // （idx / start_addr / end_addr 各 32 位，共 96 位），唯一区别是 idx 用 logic
  // 而非 int unsigned：上游那份是 4-state packed struct 里夹一个 2-state 成员，
  // addr_decode_dync 的匹配循环以变量下标取 .idx 时 VCS R-2020.12 会读成 0，
  // 使所有外设地址一律译到 slave 0。rule_t 本就是 axi_xbar 的类型参数，
  // 由使用方自带规则类型是它的既定用法。
  typedef struct packed {
    logic [31:0] idx;
    logic [31:0] start_addr;
    logic [31:0] end_addr;
  } xbar_rule32_t;

  // 只保留真实存在的 slave。旧件那三个拉死的保留口（原 axiOut_1/6/7）连同它们的
  // 译码规则一并去掉——留着不只是浪费降宽器，xbar 内部还要为每个口配 demux 输出、
  // ID 计数器、spill register 和一个 mux。
  // 随之而来的行为变化：0x0000_0000–0x007F_FFFF 原本有规则指向拉死的口、访问会挂死，
  // 现在无规则命中 → 走 error slave 返回 SLVERR。挂死是最糟的失败模式，改成报错更好。
  localparam xbar_rule32_t [N_SLV-1:0] ADDR_MAP = '{
    '{idx: 32'd4, start_addr: 32'h1F30_0000, end_addr: 32'h1F40_0000},  // 加速器 CSR
    '{idx: 32'd3, start_addr: 32'h1F20_0000, end_addr: 32'h1F30_0000},  // confreg
    '{idx: 32'd2, start_addr: 32'h1F10_0000, end_addr: 32'h1F20_0000},  // DVI
    '{idx: 32'd1, start_addr: 32'h1F00_0000, end_addr: 32'h1F10_0000},  // UART/APB
    '{idx: 32'd0, start_addr: 32'h1C00_0000, end_addr: 32'h1C80_0000}   // RAM
  };

  localparam axi_pkg::xbar_cfg_t XBAR_CFG = '{
    NoSlvPorts:         N_MST,
    NoMstPorts:         N_SLV,
    MaxMstTrans:        4,      // DMA 读侧 MAX_OUTSTANDING=4，CPU 只有 1
    MaxSlvTrans:        4,
    FallThrough:        1'b0,
    LatencyMode:        axi_pkg::CUT_ALL_AX,
    PipelineStages:     0,
    AxiIdWidthSlvPorts: ID_SLV_W,
    AxiIdUsedSlvPorts:  ID_SLV_W,
    UniqueIds:          1'b0,   // CPU 用 rid[0] 区分 icache/dcache，ID 会复用
    AxiAddrWidth:       ADDR_W,
    AxiDataWidth:       DATA_W_WIDE,
    NoAddrRules:        N_SLV
  };

  // xbar 自身两侧全是宽通道
  slvw_req_t  [N_MST-1:0] mst_req;
  slvw_resp_t [N_MST-1:0] mst_resp;
  mstw_req_t  [N_SLV-1:0] slv_req;
  mstw_resp_t [N_SLV-1:0] slv_resp;

  // 边缘窄侧：只有 CPU 那一路需要升宽，DMA 与全部 slave 口都是宽口直连
  slv_req_t  [0:0] mnar_req;
  slv_resp_t [0:0] mnar_resp;

  // ---------------------------------------------------------------------------
  // 扁平端口 <-> struct 打包/解包
  // 用宏而不是手写 340 行赋值：逐条手写在这种规模下必然出错，而宏展开只需审一遍模板。
  // qos/region/atop/user 本设计全不用，恒 0（CPU 与 DMA 的 lock/cache/prot 也都硬接 0，
  // 但仍原样透传，保持与原 crossbar 行为一致）。
  // ---------------------------------------------------------------------------
  // treq/tresp 是这一路 master 在 wrapper 内部对应的结构体，两路共用这段字段对齐逻辑
  // ——字段名与位宽由结构体类型决定。
  //
  // AxCACHE[1]（Modifiable）允许互连改变事务形状，升宽器靠它决定是否把多拍窄传输
  // 打包成整拍宽传输。只对 RAM 段置位：外设是读敏感寄存器，一次访问拆成两次就丢数据。
  `define XBAR_MOD_ADDR(a)  ((a[31:23] == 9'h038))   /* 0x1C00_0000–0x1C7F_FFFF = RAM */

  `define XBAR_CONN_MST(i, treq, tresp)                             \
    always_comb begin                                               \
      treq            = '0;                                   \
      treq.aw.id      = axiIn_``i``_awid;                     \
      treq.aw.addr    = axiIn_``i``_awaddr;                   \
      treq.aw.len     = axiIn_``i``_awlen;                    \
      treq.aw.size    = axiIn_``i``_awsize;                   \
      treq.aw.burst   = axiIn_``i``_awburst;                  \
      treq.aw.lock    = axiIn_``i``_awlock[0];                \
      treq.aw.cache   = axiIn_``i``_awcache                    \
                        | {2'b0, `XBAR_MOD_ADDR(axiIn_``i``_awaddr), 1'b0}; \
      treq.aw.prot    = axiIn_``i``_awprot;                   \
      treq.aw_valid   = axiIn_``i``_awvalid;                  \
      treq.w.data     = axiIn_``i``_wdata;                    \
      treq.w.strb     = axiIn_``i``_wstrb;                    \
      treq.w.last     = axiIn_``i``_wlast;                    \
      treq.w_valid    = axiIn_``i``_wvalid;                   \
      treq.b_ready    = axiIn_``i``_bready;                   \
      treq.ar.id      = axiIn_``i``_arid;                     \
      treq.ar.addr    = axiIn_``i``_araddr;                   \
      treq.ar.len     = axiIn_``i``_arlen;                    \
      treq.ar.size    = axiIn_``i``_arsize;                   \
      treq.ar.burst   = axiIn_``i``_arburst;                  \
      treq.ar.lock    = axiIn_``i``_arlock[0];                \
      treq.ar.cache   = axiIn_``i``_arcache                    \
                        | {2'b0, `XBAR_MOD_ADDR(axiIn_``i``_araddr), 1'b0}; \
      treq.ar.prot    = axiIn_``i``_arprot;                   \
      treq.ar_valid   = axiIn_``i``_arvalid;                  \
      treq.r_ready    = axiIn_``i``_rready;                   \
    end                                                             \
    assign axiIn_``i``_awready = tresp.aw_ready;              \
    assign axiIn_``i``_wready  = tresp.w_ready;               \
    assign axiIn_``i``_bvalid  = tresp.b_valid;               \
    assign axiIn_``i``_bid     = tresp.b.id;                  \
    assign axiIn_``i``_bresp   = tresp.b.resp;                \
    assign axiIn_``i``_arready = tresp.ar_ready;              \
    assign axiIn_``i``_rvalid  = tresp.r_valid;               \
    assign axiIn_``i``_rdata   = tresp.r.data;                \
    assign axiIn_``i``_rid     = tresp.r.id;                  \
    assign axiIn_``i``_rresp   = tresp.r.resp;                \
    assign axiIn_``i``_rlast   = tresp.r.last;

  // sreq/sresp 同理：所有 slave 口都直接接 xbar 的宽端口。
  `define XBAR_CONN_SLV(n, sreq, sresp)                             \
    assign axiOut_``n``_awvalid = sreq.aw_valid;              \
    assign axiOut_``n``_awaddr  = sreq.aw.addr;               \
    assign axiOut_``n``_awid    = sreq.aw.id;                 \
    assign axiOut_``n``_awlen   = sreq.aw.len;                \
    assign axiOut_``n``_awsize  = sreq.aw.size;               \
    assign axiOut_``n``_awburst = sreq.aw.burst;              \
    assign axiOut_``n``_awlock  = sreq.aw.lock;               \
    assign axiOut_``n``_awcache = sreq.aw.cache;              \
    assign axiOut_``n``_awprot  = sreq.aw.prot;               \
    assign axiOut_``n``_wvalid  = sreq.w_valid;               \
    assign axiOut_``n``_wdata   = sreq.w.data;                \
    assign axiOut_``n``_wstrb   = sreq.w.strb;                \
    assign axiOut_``n``_wlast   = sreq.w.last;                \
    assign axiOut_``n``_bready  = sreq.b_ready;               \
    assign axiOut_``n``_arvalid = sreq.ar_valid;              \
    assign axiOut_``n``_araddr  = sreq.ar.addr;               \
    assign axiOut_``n``_arid    = sreq.ar.id;                 \
    assign axiOut_``n``_arlen   = sreq.ar.len;                \
    assign axiOut_``n``_arsize  = sreq.ar.size;               \
    assign axiOut_``n``_arburst = sreq.ar.burst;              \
    assign axiOut_``n``_arlock  = sreq.ar.lock;               \
    assign axiOut_``n``_arcache = sreq.ar.cache;              \
    assign axiOut_``n``_arprot  = sreq.ar.prot;               \
    assign axiOut_``n``_rready  = sreq.r_ready;               \
    always_comb begin                                               \
      sresp          = '0;                                    \
      sresp.aw_ready = axiOut_``n``_awready;                  \
      sresp.w_ready  = axiOut_``n``_wready;                   \
      sresp.b_valid  = axiOut_``n``_bvalid;                   \
      sresp.b.id     = axiOut_``n``_bid;                      \
      sresp.b.resp   = axiOut_``n``_bresp;                    \
      sresp.ar_ready = axiOut_``n``_arready;                  \
      sresp.r_valid  = axiOut_``n``_rvalid;                   \
      sresp.r.id     = axiOut_``n``_rid;                      \
      sresp.r.data   = axiOut_``n``_rdata;                    \
      sresp.r.resp   = axiOut_``n``_rresp;                    \
      sresp.r.last   = axiOut_``n``_rlast;                    \
    end

  `XBAR_CONN_MST(0, mnar_req[0],  mnar_resp[0])   // CPU：窄，经升宽器
  `XBAR_CONN_MST(1, mst_req[1],   mst_resp[1])    // DMA：宽，直连

  `XBAR_CONN_SLV(0, slv_req[0],   slv_resp[0])    // RAM
  `XBAR_CONN_SLV(1, slv_req[1],   slv_resp[1])    // UART/APB
  `XBAR_CONN_SLV(2, slv_req[2],   slv_resp[2])    // DVI
  `XBAR_CONN_SLV(3, slv_req[3],   slv_resp[3])    // confreg
  `XBAR_CONN_SLV(4, slv_req[4],   slv_resp[4])    // 加速器 CSR

  // ---------------------------------------------------------------------------
  // 边缘位宽转换
  // ---------------------------------------------------------------------------
  // 只有 CPU 侧需要升宽：它的 core_top 数据总线在 mycpu_top.v 里写死 32 位、无位宽参数，
  // 而 axi_xbar 的 DataWidth 是全局参数、所有端口同宽。DMA 已是 64 位 master，直连。
  // CPU 只有一笔 outstanding 且严格顺序，AxiMaxReads=1 足够，给多了只是白占 id_queue 面积。
  axi_dw_converter #(
    .AxiMaxReads         ( 1             ),
    .AxiSlvPortDataWidth ( DATA_W        ),
    .AxiMstPortDataWidth ( DATA_W_WIDE   ),
    .AxiAddrWidth        ( ADDR_W        ),
    .AxiIdWidth          ( ID_SLV_W      ),
    .aw_chan_t           ( slv_aw_chan_t ),
    .mst_w_chan_t        ( slvw_w_chan_t ),
    .slv_w_chan_t        ( slv_w_chan_t  ),
    .b_chan_t            ( slv_b_chan_t  ),
    .ar_chan_t           ( slv_ar_chan_t ),
    .mst_r_chan_t        ( slvw_r_chan_t ),
    .slv_r_chan_t        ( slv_r_chan_t  ),
    .axi_mst_req_t       ( slvw_req_t    ),
    .axi_mst_resp_t      ( slvw_resp_t   ),
    .axi_slv_req_t       ( slv_req_t     ),
    .axi_slv_resp_t      ( slv_resp_t    )
  ) u_dw_cpu (
    .clk_i      ( clk           ),
    .rst_ni     ( resetn        ),
    .slv_req_i  ( mnar_req[0]   ),
    .slv_resp_o ( mnar_resp[0]  ),
    .mst_req_o  ( mst_req[0]    ),
    .mst_resp_i ( mst_resp[0]   )
  );

  // 外设侧不再降宽：UART/DVI/confreg/CSR 都只服务单拍寄存器访问，各自在模块边界
  // 按 wstrb/addr[2] 选半字即可，比每口挂一个约 2700 LUT 的转换器省得多。

  // ---------------------------------------------------------------------------
  // crossbar 本体
  // ---------------------------------------------------------------------------
  axi_xbar #(
    .Cfg           ( XBAR_CFG                ),
    .ATOPs         ( 1'b0                    ),  // CPU/DMA 都不发原子操作
    .slv_aw_chan_t ( slvw_aw_chan_t          ),
    .mst_aw_chan_t ( mstw_aw_chan_t          ),
    .w_chan_t      ( slvw_w_chan_t           ),
    .slv_b_chan_t  ( slvw_b_chan_t           ),
    .mst_b_chan_t  ( mstw_b_chan_t           ),
    .slv_ar_chan_t ( slvw_ar_chan_t          ),
    .mst_ar_chan_t ( mstw_ar_chan_t          ),
    .slv_r_chan_t  ( slvw_r_chan_t           ),
    .mst_r_chan_t  ( mstw_r_chan_t           ),
    .slv_req_t     ( slvw_req_t              ),
    .slv_resp_t    ( slvw_resp_t             ),
    .mst_req_t     ( mstw_req_t              ),
    .mst_resp_t    ( mstw_resp_t             ),
    .rule_t        ( xbar_rule32_t           )
  ) u_xbar (
    .clk_i                 ( clk       ),
    .rst_ni                ( resetn    ),
    .test_i                ( 1'b0      ),
    .slv_ports_req_i       ( mst_req   ),
    .slv_ports_resp_o      ( mst_resp  ),
    .mst_ports_req_o       ( slv_req   ),
    .mst_ports_resp_i      ( slv_resp  ),
    .addr_map_i            ( ADDR_MAP  ),
    .en_default_mst_port_i ( '0        ),
    .default_mst_port_i    ( '0        )
  );

  `undef XBAR_SLV_PORTS
  `undef XBAR_CONN_MST
  `undef XBAR_CONN_SLV

endmodule

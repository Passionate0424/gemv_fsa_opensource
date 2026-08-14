// =============================================================================
// tb_xbar_equiv —— 新旧 crossbar 的独立等价性验证
// =============================================================================
// 把 AxiCrossbar_2x8（参考，SpinalHDL 生成物）与 axi_xbar_2x8_wrap（被测，pulp）
// **并排例化**，灌同一份激励，比对输出。两者端口表逐字相同，所以激励可以直接
// 一驱二。
//
// 比对粒度是**事务级**不是逐拍：pulp 的 LatencyMode=CUT_ALL_AX 比原件多几级流水，
// 逐拍比会全是假失败。判据是"同一笔请求，两边落到同一个 slave、返回同样的
// rid/rdata/rresp/rlast"，时序允许不同。
//
// 为什么需要这个：整机仿真里 CPU 用新互连完全不启动（旧的正常打印），
// 但整机不可观测——分不清是发不出请求、地址译码错、还是响应回不来。
// 这里每个通道都是白盒。
//
// 用法：
//   run_vcs_remote.ps1 -Top tb_xbar_equiv -Filelist ./scripts/xbar_equiv_filelist.f
// =============================================================================

`timescale 1ns/1ps

module tb_xbar_equiv;

  localparam int N_SLV = 8;

  logic clk = 1'b0;
  logic resetn = 1'b0;
  always #5 clk = ~clk;

  // ---------------------------------------------------------------------------
  // master 侧激励（一驱二：REF 与 DUT 收到完全相同的输入）
  // ---------------------------------------------------------------------------
  // AR
  // arvalid 必须**按 DUT 分别门控**：两侧 arready 时机不同（pulp 有 CUT_ALL_AX 流水级，
  // 握手更慢），若共享一根 arvalid 等到两边都 ready 才撤，快的那侧会在等待期间
  // 把同一笔请求重复接收多次，响应队列被打乱 —— 实测表现为参考侧 DECERR + 残留数据。
  logic        m_arvalid_ref, m_arvalid_dut;
  logic [31:0] m_araddr;  logic [3:0] m_arid;
  logic [7:0]  m_arlen;    logic [2:0]  m_arsize;  logic [1:0] m_arburst;
  // AW/W
  logic        m_awvalid_ref, m_awvalid_dut;
  logic [31:0] m_awaddr;  logic [3:0] m_awid;
  logic [7:0]  m_awlen;    logic [2:0]  m_awsize;  logic [1:0] m_awburst;
  logic        m_wvalid_ref, m_wvalid_dut;
  logic [31:0] m_wdata;   logic [3:0] m_wstrb;
  // wlast 同样按 DUT 门控：两侧 W 循环各自推进，共享一根必然错拍
  logic m_wlast_ref, m_wlast_dut;
  logic        m_bready, m_rready;

  // 两个 DUT 的 master 侧回程
  logic        ref_arready, dut_arready, ref_awready, dut_awready;
  logic        ref_wready,  dut_wready;
  logic        ref_rvalid,  dut_rvalid,  ref_rlast,  dut_rlast;
  logic [31:0] ref_rdata,   dut_rdata;
  logic [3:0]  ref_rid,     dut_rid;
  logic [1:0]  ref_rresp,   dut_rresp;
  logic        ref_bvalid,  dut_bvalid;
  logic [3:0]  ref_bid,     dut_bid;
  logic [1:0]  ref_bresp,   dut_bresp;

  // ---------------------------------------------------------------------------
  // slave 侧：每个 DUT 各挂 8 个同构的简单 AXI slave（带小存储）
  // 读数据 = {slave号, 地址低位} 便于一眼看出落到了哪个 slave
  // ---------------------------------------------------------------------------
  `define SLV_WIRES(pfx, n)                                                   \
    wire        pfx``_``n``_awvalid; logic       pfx``_``n``_awready;          \
    wire [31:0] pfx``_``n``_awaddr;  wire [4:0]  pfx``_``n``_awid;             \
    wire [7:0]  pfx``_``n``_awlen;   wire [2:0]  pfx``_``n``_awsize;           \
    wire [1:0]  pfx``_``n``_awburst; wire [0:0]  pfx``_``n``_awlock;           \
    wire [3:0]  pfx``_``n``_awcache; wire [2:0]  pfx``_``n``_awprot;           \
    wire        pfx``_``n``_wvalid;  logic       pfx``_``n``_wready;           \
    wire [31:0] pfx``_``n``_wdata;   wire [3:0]  pfx``_``n``_wstrb;            \
    wire        pfx``_``n``_wlast;                                            \
    logic       pfx``_``n``_bvalid;  wire        pfx``_``n``_bready;           \
    logic [4:0] pfx``_``n``_bid;     logic [1:0] pfx``_``n``_bresp;            \
    wire        pfx``_``n``_arvalid; logic       pfx``_``n``_arready;          \
    wire [31:0] pfx``_``n``_araddr;  wire [4:0]  pfx``_``n``_arid;             \
    wire [7:0]  pfx``_``n``_arlen;   wire [2:0]  pfx``_``n``_arsize;           \
    wire [1:0]  pfx``_``n``_arburst; wire [0:0]  pfx``_``n``_arlock;           \
    wire [3:0]  pfx``_``n``_arcache; wire [2:0]  pfx``_``n``_arprot;           \
    logic       pfx``_``n``_rvalid;  wire        pfx``_``n``_rready;           \
    logic [31:0] pfx``_``n``_rdata;  logic [4:0] pfx``_``n``_rid;              \
    logic [1:0] pfx``_``n``_rresp;   logic       pfx``_``n``_rlast;

  `define SLV_MODEL(pfx, n)                                                   \
    axi_slave_model #(.SLV_ID(n)) u_``pfx``_slv``n (                          \
      .clk(clk), .resetn(resetn),                                             \
      .awvalid(pfx``_``n``_awvalid), .awready(pfx``_``n``_awready),           \
      .awaddr (pfx``_``n``_awaddr),  .awid   (pfx``_``n``_awid),              \
      .awlen  (pfx``_``n``_awlen),   .awsize (pfx``_``n``_awsize),            \
      .wvalid (pfx``_``n``_wvalid),  .wready (pfx``_``n``_wready),            \
      .wdata  (pfx``_``n``_wdata),   .wlast  (pfx``_``n``_wlast),             \
      .wstrb  (pfx``_``n``_wstrb),                                            \
      .bvalid (pfx``_``n``_bvalid),  .bready (pfx``_``n``_bready),            \
      .bid    (pfx``_``n``_bid),     .bresp  (pfx``_``n``_bresp),             \
      .arvalid(pfx``_``n``_arvalid), .arready(pfx``_``n``_arready),           \
      .araddr (pfx``_``n``_araddr),  .arid   (pfx``_``n``_arid),              \
      .arlen  (pfx``_``n``_arlen),  .arsize (pfx``_``n``_arsize),             \
      .rvalid (pfx``_``n``_rvalid),  .rready (pfx``_``n``_rready),            \
      .rdata  (pfx``_``n``_rdata),   .rid    (pfx``_``n``_rid),               \
      .rresp  (pfx``_``n``_rresp),   .rlast  (pfx``_``n``_rlast));

  `SLV_WIRES(r, 0) `SLV_WIRES(r, 1) `SLV_WIRES(r, 2) `SLV_WIRES(r, 3)
  `SLV_WIRES(r, 4) `SLV_WIRES(r, 5) `SLV_WIRES(r, 6) `SLV_WIRES(r, 7)
  `SLV_WIRES(d, 0) `SLV_WIRES(d, 1) `SLV_WIRES(d, 2) `SLV_WIRES(d, 3)
  `SLV_WIRES(d, 4) `SLV_WIRES(d, 5) `SLV_WIRES(d, 6) `SLV_WIRES(d, 7)

  `SLV_MODEL(r, 0) `SLV_MODEL(r, 1) `SLV_MODEL(r, 2) `SLV_MODEL(r, 3)
  `SLV_MODEL(r, 4) `SLV_MODEL(r, 5) `SLV_MODEL(r, 6) `SLV_MODEL(r, 7)
  `SLV_MODEL(d, 0) `SLV_MODEL(d, 1) `SLV_MODEL(d, 2) `SLV_MODEL(d, 3)
  `SLV_MODEL(d, 4) `SLV_MODEL(d, 5) `SLV_MODEL(d, 6) `SLV_MODEL(d, 7)

  // master 1（DMA）本测试不驱动，静默即可
  `define TIE_M1(sig) .axiIn_1_``sig
  // 连接宏：把 master0 激励接到某个 DUT，master1 拉死，slave 侧接对应前缀
  `define XBAR_INST(MOD, PARAMS, INST, pfx, rdyp)                             \
    MOD PARAMS INST (                                                         \
      .axiIn_0_awvalid(m_awvalid_``rdyp), .axiIn_0_awready(rdyp``_awready),          \
      .axiIn_0_awaddr(m_awaddr), .axiIn_0_awid(m_awid),                       \
      .axiIn_0_awlen(m_awlen), .axiIn_0_awsize(m_awsize),                     \
      .axiIn_0_awburst(m_awburst), .axiIn_0_awlock(1'b0),                     \
      .axiIn_0_awcache(4'b0), .axiIn_0_awprot(3'b0),                          \
      .axiIn_0_wvalid(m_wvalid_``rdyp), .axiIn_0_wready(rdyp``_wready),              \
      .axiIn_0_wdata(m_wdata), .axiIn_0_wstrb(m_wstrb), .axiIn_0_wlast(m_wlast_``rdyp), \
      .axiIn_0_bvalid(rdyp``_bvalid), .axiIn_0_bready(m_bready),              \
      .axiIn_0_bid(rdyp``_bid), .axiIn_0_bresp(rdyp``_bresp),                 \
      .axiIn_0_arvalid(m_arvalid_``rdyp), .axiIn_0_arready(rdyp``_arready),   \
      .axiIn_0_araddr(m_araddr), .axiIn_0_arid(m_arid),                       \
      .axiIn_0_arlen(m_arlen), .axiIn_0_arsize(m_arsize),                     \
      .axiIn_0_arburst(m_arburst), .axiIn_0_arlock(1'b0),                     \
      .axiIn_0_arcache(4'b0), .axiIn_0_arprot(3'b0),                          \
      .axiIn_0_rvalid(rdyp``_rvalid), .axiIn_0_rready(m_rready),              \
      .axiIn_0_rdata(rdyp``_rdata), .axiIn_0_rid(rdyp``_rid),                 \
      .axiIn_0_rresp(rdyp``_rresp), .axiIn_0_rlast(rdyp``_rlast),             \
      .axiIn_1_awvalid(1'b0), .axiIn_1_awready(), .axiIn_1_awaddr(32'b0),     \
      .axiIn_1_awid(4'b0), .axiIn_1_awlen(8'b0), .axiIn_1_awsize(3'b010),     \
      .axiIn_1_awburst(2'b01), .axiIn_1_awlock(1'b0), .axiIn_1_awcache(4'b0), \
      .axiIn_1_awprot(3'b0), .axiIn_1_wvalid(1'b0), .axiIn_1_wready(),        \
      .axiIn_1_wdata(32'b0), .axiIn_1_wstrb(4'b0), .axiIn_1_wlast(1'b0),      \
      .axiIn_1_bvalid(), .axiIn_1_bready(1'b1), .axiIn_1_bid(), .axiIn_1_bresp(), \
      .axiIn_1_arvalid(1'b0), .axiIn_1_arready(), .axiIn_1_araddr(32'b0),     \
      .axiIn_1_arid(4'b0), .axiIn_1_arlen(8'b0), .axiIn_1_arsize(3'b010),     \
      .axiIn_1_arburst(2'b01), .axiIn_1_arlock(1'b0), .axiIn_1_arcache(4'b0), \
      .axiIn_1_arprot(3'b0), .axiIn_1_rvalid(), .axiIn_1_rready(1'b1),        \
      .axiIn_1_rdata(), .axiIn_1_rid(), .axiIn_1_rresp(), .axiIn_1_rlast(),   \
      `XB_SLV(pfx,0) `XB_SLV(pfx,1) `XB_SLV(pfx,2) `XB_SLV(pfx,3)             \
      `XB_SLV(pfx,4) `XB_SLV(pfx,5) `XB_SLV(pfx,6) `XB_SLV(pfx,7)             \
      .clk(clk), .resetn(resetn));

  `define XB_SLV(pfx, n)                                                      \
      .axiOut_``n``_awvalid(pfx``_``n``_awvalid), .axiOut_``n``_awready(pfx``_``n``_awready), \
      .axiOut_``n``_awaddr(pfx``_``n``_awaddr),   .axiOut_``n``_awid(pfx``_``n``_awid),       \
      .axiOut_``n``_awlen(pfx``_``n``_awlen),     .axiOut_``n``_awsize(pfx``_``n``_awsize),   \
      .axiOut_``n``_awburst(pfx``_``n``_awburst), .axiOut_``n``_awlock(pfx``_``n``_awlock),   \
      .axiOut_``n``_awcache(pfx``_``n``_awcache), .axiOut_``n``_awprot(pfx``_``n``_awprot),   \
      .axiOut_``n``_wvalid(pfx``_``n``_wvalid),   .axiOut_``n``_wready(pfx``_``n``_wready),   \
      .axiOut_``n``_wdata(pfx``_``n``_wdata),     .axiOut_``n``_wstrb(pfx``_``n``_wstrb),     \
      .axiOut_``n``_wlast(pfx``_``n``_wlast),                                                \
      .axiOut_``n``_bvalid(pfx``_``n``_bvalid),   .axiOut_``n``_bready(pfx``_``n``_bready),   \
      .axiOut_``n``_bid(pfx``_``n``_bid),         .axiOut_``n``_bresp(pfx``_``n``_bresp),     \
      .axiOut_``n``_arvalid(pfx``_``n``_arvalid), .axiOut_``n``_arready(pfx``_``n``_arready), \
      .axiOut_``n``_araddr(pfx``_``n``_araddr),   .axiOut_``n``_arid(pfx``_``n``_arid),       \
      .axiOut_``n``_arlen(pfx``_``n``_arlen),     .axiOut_``n``_arsize(pfx``_``n``_arsize),   \
      .axiOut_``n``_arburst(pfx``_``n``_arburst), .axiOut_``n``_arlock(pfx``_``n``_arlock),   \
      .axiOut_``n``_arcache(pfx``_``n``_arcache), .axiOut_``n``_arprot(pfx``_``n``_arprot),   \
      .axiOut_``n``_rvalid(pfx``_``n``_rvalid),   .axiOut_``n``_rready(pfx``_``n``_rready),   \
      .axiOut_``n``_rdata(pfx``_``n``_rdata),     .axiOut_``n``_rid(pfx``_``n``_rid),         \
      .axiOut_``n``_rresp(pfx``_``n``_rresp),     .axiOut_``n``_rlast(pfx``_``n``_rlast),

  `XBAR_INST(AxiCrossbar_2x8, , u_ref, r, ref)
  // DATA_W_WIDE 也给 32：两侧位宽转换器退化成直通，wrapper 回到与参考件同构的纯 32 位
  // 配置。本 tb 验的是"译码与仲裁行为是否等价"，不验加宽——加宽后 RAM/DMA 口变 64 位，
  // 端口表不再与参考件逐字相同，一驱二的前提就不成立了。
  `XBAR_INST(axi_xbar_2x8_wrap, #(.DATA_W(32), .DATA_W_WIDE(32)), u_dut, d, dut)

  // ---------------------------------------------------------------------------
  // 激励与比对
  // ---------------------------------------------------------------------------
  int errors = 0;
  int checks = 0;

  // 单笔读：两边各自等到 rlast，比对 rid/rdata/rresp。CPU 本来就是单笔 outstanding。
  task automatic do_read(input [31:0] addr, input [3:0] id, input [7:0] len,
                         input [2:0] sz, input string name);
    logic [31:0] rd_ref [$], rd_dut [$];
    logic [3:0]  id_ref, id_dut;
    logic [1:0]  rp_ref, rp_dut;
    int          to;
    begin
      checks++;
      @(negedge clk);
      m_araddr = addr; m_arid = id; m_arlen = len;
      m_arsize = sz; m_arburst = 2'b01;
      m_arvalid_ref = 1'b1; m_arvalid_dut = 1'b1;
      // 各自握手、各自撤 valid：绝不能共享一根 arvalid 等两边都 ready，
      // 那样快的一侧会重复接收同一笔请求
      m_rready = 1'b1;
      // 每侧一条独立流水：先自己握完 AR、立刻撤自己的 valid，再收自己的 R。
      // AR 与 R 必须并发——快的一侧可能在慢的一侧还没握完 AR 时就已返回数据，
      // 若把 R 收集放在"两侧 AR 都完成"之后，会漏掉已经发出的拍。
      fork
        begin : pipe_ref
          automatic int t_ref = 0;
          forever begin @(posedge clk); if (ref_arready) begin m_arvalid_ref = 1'b0; break; end end
          forever begin
            @(posedge clk);
            if (ref_rvalid) begin
              rd_ref.push_back(ref_rdata); id_ref = ref_rid; rp_ref = ref_rresp;
              if (ref_rlast) break;
            end
            if (++t_ref > 2000) begin $display("[EQUIV] TIMEOUT ref read %s", name); break; end
          end
        end
        begin : pipe_dut
          automatic int t_dut = 0;
          forever begin @(posedge clk); if (dut_arready) begin m_arvalid_dut = 1'b0; break; end end
          forever begin
            @(posedge clk);
            if (dut_rvalid) begin
              rd_dut.push_back(dut_rdata); id_dut = dut_rid; rp_dut = dut_rresp;
              if (dut_rlast) break;
            end
            if (++t_dut > 2000) begin $display("[EQUIV] TIMEOUT dut read %s", name); break; end
          end
        end
      join

      m_rready = 1'b0;

      if (rd_ref.size() != rd_dut.size()) begin
        errors++;
        $display("[EQUIV][FAIL] %s addr=%08h: beat count ref=%0d dut=%0d",
                 name, addr, rd_ref.size(), rd_dut.size());
      end else if (rd_ref.size() == 0) begin
        errors++;
        $display("[EQUIV][FAIL] %s addr=%08h: 两边都没有返回数据（挂死）", name, addr);
      end else begin
        foreach (rd_ref[i]) if (rd_ref[i] !== rd_dut[i]) begin
          errors++;
          $display("[EQUIV][FAIL] %s addr=%08h beat%0d: ref=%08h dut=%08h",
                   name, addr, i, rd_ref[i], rd_dut[i]);
        end
        if (id_ref !== id_dut) begin
          errors++;
          $display("[EQUIV][FAIL] %s addr=%08h: RID ref=%0h dut=%0h  <-- CPU 靠 rid[0] 分 icache/dcache",
                   name, addr, id_ref, id_dut);
        end
        if (rp_ref !== rp_dut) begin
          errors++;
          $display("[EQUIV][FAIL] %s addr=%08h: RRESP ref=%0h dut=%0h", name, addr, rp_ref, rp_dut);
        end
      end
    end
  endtask

  // 单笔写：AW/W 各自握手，收各自的 B，比对 bid/bresp。
  // 与 do_read 同理，valid 必须按 DUT 分别门控。
  task automatic do_write(input [31:0] addr, input [3:0] id, input [7:0] len,
                          input [31:0] data, input [2:0] sz, input [3:0] strb,
                          input string name);
    logic [3:0] bid_ref, bid_dut;
    logic [1:0] bp_ref,  bp_dut;
    bit         ok_ref,  ok_dut;
    begin
      checks++;
      ok_ref = 0; ok_dut = 0;
      @(negedge clk);
      m_awaddr = addr; m_awid = id; m_awlen = len;
      m_awsize = sz; m_awburst = 2'b01;
      m_wdata = data; m_wstrb = strb;
      m_wlast_ref = (len == 0); m_wlast_dut = (len == 0);
      m_awvalid_ref = 1'b1; m_awvalid_dut = 1'b1;
      // W 不与 AW 同时拉高：先各自握完 AW 再放 W。AXI 允许 W 先行，但旧 crossbar
      // 的写译码要等 AW 被接收后才放行 wready，同时拉高会死等（实测 TIMEOUT ref W）。
      m_wvalid_ref  = 1'b0; m_wvalid_dut  = 1'b0;
      m_bready = 1'b1;

      fork
        begin : wpipe_ref
          automatic int t = 0; automatic int beat = 0;
          forever begin @(posedge clk); if (ref_awready) begin m_awvalid_ref = 1'b0; break; end
            if (++t > 2000) begin $display("[EQUIV] TIMEOUT ref AW %s", name); break; end end
          t = 0;
          m_wvalid_ref = 1'b1;
          forever begin
            @(posedge clk);
            if (ref_wready) begin
              if (beat == len) begin m_wvalid_ref = 1'b0; break; end
              beat++;
              m_wlast_ref = (beat == len);
            end
            if (++t > 2000) begin $display("[EQUIV] TIMEOUT ref W %s", name); break; end
          end
          t = 0;
          forever begin
            @(posedge clk);
            if (ref_bvalid) begin bid_ref = ref_bid; bp_ref = ref_bresp; ok_ref = 1; break; end
            if (++t > 2000) begin $display("[EQUIV] TIMEOUT ref B %s", name); break; end
          end
        end
        begin : wpipe_dut
          automatic int t = 0; automatic int beat = 0;
          forever begin @(posedge clk); if (dut_awready) begin m_awvalid_dut = 1'b0; break; end
            if (++t > 2000) begin $display("[EQUIV] TIMEOUT dut AW %s", name); break; end end
          t = 0;
          m_wvalid_dut = 1'b1;
          forever begin
            @(posedge clk);
            if (dut_wready) begin
              if (beat == len) begin m_wvalid_dut = 1'b0; break; end
              beat++;
              m_wlast_dut = (beat == len);
            end
            if (++t > 2000) begin $display("[EQUIV] TIMEOUT dut W %s", name); break; end
          end
          t = 0;
          forever begin
            @(posedge clk);
            if (dut_bvalid) begin bid_dut = dut_bid; bp_dut = dut_bresp; ok_dut = 1; break; end
            if (++t > 2000) begin $display("[EQUIV] TIMEOUT dut B %s", name); break; end
          end
        end
      join
      m_bready = 1'b0;
      m_wlast_ref = 1'b0; m_wlast_dut = 1'b0;

      if (!ok_ref || !ok_dut) begin
        errors++;
        $display("[EQUIV][FAIL] %s addr=%08h: B 响应缺失 ref=%0d dut=%0d  <-- 写通路断了 CPU 会卡在 store 上",
                 name, addr, ok_ref, ok_dut);
      end else begin
        if (bid_ref !== bid_dut) begin
          errors++;
          $display("[EQUIV][FAIL] %s addr=%08h: BID ref=%0h dut=%0h", name, addr, bid_ref, bid_dut);
        end
        if (bp_ref !== bp_dut) begin
          errors++;
          $display("[EQUIV][FAIL] %s addr=%08h: BRESP ref=%0h dut=%0h", name, addr, bp_ref, bp_dut);
        end
      end

      // slave 侧实际收到什么：crossbar 若改动字节道或地址，只有在这里才看得见。
      // axi2apb 是按 wstrb 反推 APB 地址的，所以 wstrb 必须逐位一致。
      case (addr[31:20])
        12'h1F0: chk_wr(u_r_slv2.wstrb_q, u_d_slv2.wstrb_q, u_r_slv2.waddr_q, u_d_slv2.waddr_q,
                        u_r_slv2.awsize_q, u_d_slv2.awsize_q, name);
        12'h1F2: chk_wr(u_r_slv4.wstrb_q, u_d_slv4.wstrb_q, u_r_slv4.waddr_q, u_d_slv4.waddr_q,
                        u_r_slv4.awsize_q, u_d_slv4.awsize_q, name);
        default: chk_wr(u_r_slv0.wstrb_q, u_d_slv0.wstrb_q, u_r_slv0.waddr_q, u_d_slv0.waddr_q,
                        u_r_slv0.awsize_q, u_d_slv0.awsize_q, name);
      endcase
    end
  endtask

  task automatic chk_wr(input [3:0] sr, input [3:0] sd, input [31:0] ar, input [31:0] ad,
                        input [2:0] zr, input [2:0] zd, input string name);
    begin
      if (sr !== sd) begin
        errors++;
        $display("[EQUIV][FAIL] %s: slave 侧 WSTRB ref=%0h dut=%0h  <-- axi2apb 按 wstrb 反推 APB 地址",
                 name, sr, sd);
      end
      if (ar !== ad) begin
        errors++;
        $display("[EQUIV][FAIL] %s: slave 侧 AWADDR ref=%08h dut=%08h", name, ar, ad);
      end
      if (zr !== zd) begin
        errors++;
        $display("[EQUIV][FAIL] %s: slave 侧 AWSIZE ref=%0h dut=%0h", name, zr, zd);
      end
    end
  endtask

  initial begin
    m_arvalid_ref=0; m_arvalid_dut=0; m_awvalid_ref=0; m_awvalid_dut=0; m_wvalid_ref=0; m_wvalid_dut=0; m_bready=1; m_rready=0;
    m_araddr=0; m_arid=0; m_arlen=0; m_arsize=3'b010; m_arburst=2'b01;
    m_awaddr=0; m_awid=0; m_awlen=0; m_awsize=3'b010; m_awburst=2'b01;
    m_wdata=0; m_wstrb=4'hF; m_wlast_ref=0; m_wlast_dut=0;

    repeat (10) @(posedge clk);
    resetn = 1'b1;
    repeat (10) @(posedge clk);

    $display("[EQUIV] ===== 新旧 crossbar 等价性验证开始 =====");
    // 逐个地址区间打一发单拍读，看落到哪个 slave、回什么 ID
    do_read(32'h1C00_0000, 4'h0, 8'd0, 3'b010, "RAM_base_id0(inst)");
    do_read(32'h1C00_0004, 4'h1, 8'd0, 3'b010, "RAM_base_id1(data)");
    do_read(32'h1C7F_FFFC, 4'h1, 8'd0, 3'b010, "RAM_top");
    do_read(32'h0000_0000, 4'h0, 8'd0, 3'b010, "RAM_alias_boot");
    do_read(32'h1F00_0000, 4'h1, 8'd0, 3'b010, "UART");
    do_read(32'h1F10_0000, 4'h1, 8'd0, 3'b010, "DVI");
    do_read(32'h1F20_0000, 4'h1, 8'd0, 3'b010, "confreg");
    do_read(32'h1F30_0000, 4'h1, 8'd0, 3'b010, "accel_CSR");
    // CPU 的 cache 行填充：4 拍 INCR
    do_read(32'h1C00_0100, 4'h0, 8'd3, 3'b010, "RAM_cacheline_4beat");

    // 窄传输：uart_putchar 用 ld.bu 读 LSR（基址+5），对应 arsize=0、地址低位非零。
    // 之前只测了 arsize=010（4 字节），窄传输是完整的覆盖盲区，而整机正是卡在这条路上。
    do_read(32'h1F00_0000, 4'h1, 8'd0, 3'b000, "UART_byte_off0");
    do_read(32'h1F00_0001, 4'h1, 8'd0, 3'b000, "UART_byte_off1");
    do_read(32'h1F00_0005, 4'h1, 8'd0, 3'b000, "UART_byte_off5_LSR");
    do_read(32'h1F00_0007, 4'h1, 8'd0, 3'b000, "UART_byte_off7");
    do_read(32'h1F00_0002, 4'h1, 8'd0, 3'b001, "UART_half_off2");
    do_read(32'h1C00_0401, 4'h1, 8'd0, 3'b000, "RAM_byte_off1");
    do_read(32'h1C00_0403, 4'h1, 8'd0, 3'b000, "RAM_byte_off3");


    // 写通路：smoke_test 靠 UART 写输出，写断了 CPU 会卡在第一条 store 上
    do_write(32'h1C00_0200, 4'h1, 8'd0, 32'hA5A5_1234, 3'b010, 4'hF, "RAM_write_single");
    do_write(32'h1F00_0000, 4'h1, 8'd0, 32'h0000_0041, 3'b010, 4'hF, "UART_write");
    do_write(32'h1F20_0000, 4'h1, 8'd0, 32'hDEAD_BEEF, 3'b010, 4'hF, "confreg_write");
    do_write(32'h1C00_0300, 4'h1, 8'd3, 32'h1111_0000, 3'b010, 4'hF, "RAM_write_4beat");

    // 窄写：UART 初始化用 st.b 写配置寄存器，靠 wstrb 指明字节道，而 axi2apb
    // 是**按 wstrb 反推 APB 地址**的（axi2apb.v:225-245）。wstrb 若被 crossbar
    // 改动，配置就写到错误偏移、UART 从未被初始化 —— 与"LSR 的 THR-empty 位永不置"吻合。
    do_write(32'h1F00_0000, 4'h1, 8'd0, 32'h0000_0041, 3'b000, 4'h1, "UART_byte_off0");
    do_write(32'h1F00_0001, 4'h1, 8'd0, 32'h0000_4100, 3'b000, 4'h2, "UART_byte_off1");
    do_write(32'h1F00_0003, 4'h1, 8'd0, 32'h4100_0000, 3'b000, 4'h8, "UART_byte_off3");
    do_write(32'h1F00_0005, 4'h1, 8'd0, 32'h0000_4100, 3'b000, 4'h2, "UART_byte_off5");
    do_write(32'h1F00_0002, 4'h1, 8'd0, 32'h1234_0000, 3'b001, 4'hC, "UART_half_off2");
    do_write(32'h1C00_0501, 4'h1, 8'd0, 32'h0000_5500, 3'b000, 4'h2, "RAM_byte_off1");

    $display("[EQUIV] ===== 结束：checks=%0d errors=%0d =====", checks, errors);
    if (errors == 0) $display("[EQUIV] PASS");
    else             $display("[EQUIV] FAIL");
    $finish;
  end

  initial begin
    #2_000_000;
    $display("[EQUIV] GLOBAL TIMEOUT");
    $finish;
  end

endmodule

// =============================================================================
// 简单 AXI slave 模型：读返回 {SLV_ID, addr[15:0]} 便于一眼看出落到了哪个 slave
// =============================================================================
module axi_slave_model #(parameter int SLV_ID = 0) (
  input  logic clk, resetn,
  input  logic awvalid, output logic awready,
  input  logic [31:0] awaddr, input logic [4:0] awid, input logic [7:0] awlen,
  input  logic [2:0]  awsize,
  input  logic wvalid, output logic wready, input logic [31:0] wdata, input logic wlast,
  input  logic [3:0]  wstrb,
  output logic bvalid, input logic bready, output logic [4:0] bid, output logic [1:0] bresp,
  input  logic arvalid, output logic arready,
  input  logic [31:0] araddr, input logic [4:0] arid, input logic [7:0] arlen,
  input  logic [2:0]  arsize,
  output logic rvalid, input logic rready,
  output logic [31:0] rdata, output logic [4:0] rid, output logic [1:0] rresp, output logic rlast
);
  logic [7:0]  beats_left;
  logic [31:0] cur_addr;
  logic        busy_r;
  // AW 握手当拍锁存 awid：等到 wlast 再取已经晚了，那时 AW 早已握完、
  // awid 不保证还有效，两个 crossbar 握手后的保持行为不同就会露出假差异。
  logic [4:0]  awid_q;
  // aw_pending：本 slave 是否有一笔已接收、尚未回 B 的写事务。
  // 没有它的话，wready 恒 1 会让**从未收到 AW 的 slave** 也在看到 wvalid&&wlast 时
  // 吐一笔 awid_q=0 的假 B，pulp 的 demux 立刻判定"响应对不上任何未完成 AW"、
  // 断言 counter underflow 并 $finish。这是 tb 的协议违例，不是 crossbar 的问题。
  logic        aw_pending;
  // 捕获写事务的 wstrb / 地址 / 数据：简化模型本身不使用它们，但 axi2apb 是**按 wstrb
  // 反推 APB 地址**的（axi2apb.v:225-245），所以 wstrb 若被 crossbar 改动，UART 的
  // 配置寄存器就会写到错误偏移。不捕获就观测不到这类差异。
  logic [3:0]  wstrb_q;
  logic [31:0] waddr_q, wdata_q;
  logic [2:0]  awsize_q;

  assign awready = !aw_pending;          // 一次只受理一笔写
  assign wready  = aw_pending;           // 只在已收到对应 AW 后才收 W

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      arready <= 1'b1; rvalid <= 1'b0; rlast <= 1'b0; busy_r <= 1'b0;
      rid <= '0; rdata <= '0; rresp <= 2'b00; beats_left <= '0; cur_addr <= '0;
      bvalid <= 1'b0; bid <= '0; bresp <= 2'b00; awid_q <= '0; aw_pending <= 1'b0;
    end else begin
      if (awvalid && awready) begin
        awid_q <= awid; aw_pending <= 1'b1;
        waddr_q <= awaddr; awsize_q <= awsize;
      end
      if (aw_pending && wvalid && wready) begin
        wstrb_q <= wstrb; wdata_q <= wdata;
      end
      // 读通道
      if (!busy_r && arvalid && arready) begin
        busy_r <= 1'b1; arready <= 1'b0;
        cur_addr <= araddr; rid <= arid; beats_left <= arlen;
        rvalid <= 1'b1; rlast <= (arlen == 0);
        rdata <= {SLV_ID[7:0], 5'b0, arsize, araddr[15:0]};  // arsize 也编进来，被篡改能抓到
        rresp <= 2'b00;
      end else if (busy_r && rvalid && rready) begin
        if (rlast) begin
          busy_r <= 1'b0; rvalid <= 1'b0; rlast <= 1'b0; arready <= 1'b1;
        end else begin
          cur_addr   <= cur_addr + 4;
          beats_left <= beats_left - 1;
          rlast      <= (beats_left == 1);
          rdata      <= {SLV_ID[7:0], 5'b0, 3'b010, cur_addr[15:0] + 16'd4};
        end
      end
      // 写通道：收到 wlast 就回 B
      if (aw_pending && wvalid && wready && wlast) begin
        bvalid <= 1'b1; bid <= awid_q; bresp <= 2'b00;
      end else if (bvalid && bready) begin
        bvalid <= 1'b0; aw_pending <= 1'b0;   // B 握完才释放，避免下一笔 AW 抢跑
      end
    end
  end
endmodule

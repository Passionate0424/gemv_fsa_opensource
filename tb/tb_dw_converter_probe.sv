// =============================================================================
// tb_dw_converter_probe —— pulp axi_dw_converter 行为探针（64位加宽方案第3步门禁）
// =============================================================================
// DUT：两级串联的 axi_dw_converter，复刻 CPU 访问外设时的真实拓扑
//
//   32位 master ──► up(32→64) ──► 64位链路 ──► down(64→32) ──► 32位 slave
//
// 之所以要串两级：隐患不来自升宽本身，而来自"升宽之后又降回去"这个来回。
// CPU 访问 RAM 只有升宽（多读几个字节对内存无副作用），访问外设才会走完整来回。
//
// 三个待测行为，每一个都直接决定后续的架构选择：
//   [判据一] 一次 32 位单拍读，slave 侧看到几次访问？
//            1 次 → 外设可以挂 4 个降宽器（方案 B，外设一行不改）
//            2 次 → 外设必须整体加宽到 64 位（方案 A）
//            这是正确性级问题：UART 接收 FIFO 读一次弹一个字符，多访问一次就是丢数据。
//   [判据二] 4 拍 32 位 INCR，在中间那条 64 位链路上是 2 拍还是 4 拍？
//            打包成 2 拍 → CPU 的 cache 行填充访存次数减半，加宽对 CPU 有收益
//            仍是 4 拍（只填充不打包）→ CPU 侧收益归零，需重估是否值得给 CPU 加宽
//   [判据三] 窄传输（arsize < 总线宽度）能否原样穿过两级转换器。
//            第5步的 Vector SRAM / Output SRAM 通路要靠窄传输节流，依赖这条成立。
//
// 观测点全部放在两级之间的 64 位链路与 slave 侧，用计数器统计握手次数——
// "结果对不对"在这里不是判据，"发生了几次访问、每次几拍"才是。
// =============================================================================
`timescale 1ns / 1ps

`include "axi/typedef.svh"
`include "axi/assign.svh"

module tb_dw_converter_probe;

  localparam int unsigned ADDR_W  = 32;
  localparam int unsigned ID_W    = 4;
  localparam int unsigned USER_W  = 1;
  localparam int unsigned DW_NARROW = 32;
  localparam int unsigned DW_WIDE   = 64;

  typedef logic [ADDR_W-1:0]        addr_t;
  typedef logic [ID_W-1:0]          id_t;
  typedef logic [USER_W-1:0]        user_t;
  typedef logic [DW_NARROW-1:0]     data32_t;
  typedef logic [DW_NARROW/8-1:0]   strb32_t;
  typedef logic [DW_WIDE-1:0]       data64_t;
  typedef logic [DW_WIDE/8-1:0]     strb64_t;

  `AXI_TYPEDEF_ALL(n, addr_t, id_t, data32_t, strb32_t, user_t)  // 32 位一侧
  `AXI_TYPEDEF_ALL(w, addr_t, id_t, data64_t, strb64_t, user_t)  // 64 位一侧

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  // master(32) -> up -> mid(64) -> down -> slave(32)
  n_req_t  m_req;   n_resp_t m_resp;
  w_req_t  mid_req; w_resp_t mid_resp;
  n_req_t  s_req;   n_resp_t s_resp;

  axi_dw_converter #(
    .AxiMaxReads         ( 4          ),
    .AxiSlvPortDataWidth ( DW_NARROW  ),
    .AxiMstPortDataWidth ( DW_WIDE    ),
    .AxiAddrWidth        ( ADDR_W     ),
    .AxiIdWidth          ( ID_W       ),
    .aw_chan_t           ( n_aw_chan_t ),
    .mst_w_chan_t        ( w_w_chan_t  ),
    .slv_w_chan_t        ( n_w_chan_t  ),
    .b_chan_t            ( n_b_chan_t  ),
    .ar_chan_t           ( n_ar_chan_t ),
    .mst_r_chan_t        ( w_r_chan_t  ),
    .slv_r_chan_t        ( n_r_chan_t  ),
    .axi_mst_req_t       ( w_req_t     ),
    .axi_mst_resp_t      ( w_resp_t    ),
    .axi_slv_req_t       ( n_req_t     ),
    .axi_slv_resp_t      ( n_resp_t    )
  ) u_up (
    .clk_i (clk), .rst_ni (rst_n),
    .slv_req_i (m_req),   .slv_resp_o (m_resp),
    .mst_req_o (mid_req), .mst_resp_i (mid_resp)
  );

  axi_dw_converter #(
    .AxiMaxReads         ( 4          ),
    .AxiSlvPortDataWidth ( DW_WIDE    ),
    .AxiMstPortDataWidth ( DW_NARROW  ),
    .AxiAddrWidth        ( ADDR_W     ),
    .AxiIdWidth          ( ID_W       ),
    .aw_chan_t           ( w_aw_chan_t ),
    .mst_w_chan_t        ( n_w_chan_t  ),
    .slv_w_chan_t        ( w_w_chan_t  ),
    .b_chan_t            ( w_b_chan_t  ),
    .ar_chan_t           ( w_ar_chan_t ),
    .mst_r_chan_t        ( n_r_chan_t  ),
    .slv_r_chan_t        ( w_r_chan_t  ),
    .axi_mst_req_t       ( n_req_t     ),
    .axi_mst_resp_t      ( n_resp_t    ),
    .axi_slv_req_t       ( w_req_t     ),
    .axi_slv_resp_t      ( w_resp_t    )
  ) u_down (
    .clk_i (clk), .rst_ni (rst_n),
    .slv_req_i (mid_req), .slv_resp_o (mid_resp),
    .mst_req_o (s_req),   .mst_resp_i (s_resp)
  );

  // ---------------------------------------------------------------------------
  // 32 位 slave 模型：数据按地址生成（addr[15:0] 拼固定标记），便于核对取回的是哪一拍。
  // 计数 AR 握手次数与 R 拍数——判据一二三全靠这两个数。
  // ---------------------------------------------------------------------------
  int slv_ar_cnt, slv_r_beats, mid_ar_cnt, mid_r_beats;
  logic [7:0]  s_len_q;
  logic [2:0]  s_size_q;
  id_t         s_id_q;
  addr_t       s_addr_q;
  logic        s_busy;

  assign s_resp.aw_ready = 1'b0;   // 本探针只测读通路
  assign s_resp.w_ready  = 1'b0;
  assign s_resp.b_valid  = 1'b0;
  assign s_resp.ar_ready = !s_busy;

  // 用普通 always 而非 always_ff：计数器还要被激励侧的 reset_counters() 清零，
  // always_ff 的左值不允许有第二个过程驱动。
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_busy      <= 1'b0;
      s_resp.r_valid <= 1'b0;
      slv_ar_cnt  <= 0;
      slv_r_beats <= 0;
    end else begin
      if (!s_busy && s_req.ar_valid) begin
        s_busy   <= 1'b1;
        s_len_q  <= s_req.ar.len;
        s_size_q <= s_req.ar.size;
        s_id_q   <= s_req.ar.id;
        s_addr_q <= s_req.ar.addr;
        slv_ar_cnt <= slv_ar_cnt + 1;
        $display("[SLV_AR] #%0d t=%0t addr=0x%08h len=%0d size=%0d",
                 slv_ar_cnt + 1, $time, s_req.ar.addr, s_req.ar.len, s_req.ar.size);
      end else if (s_busy) begin
        s_resp.r_valid <= 1'b1;
        if (s_resp.r_valid && s_req.r_ready) begin
          slv_r_beats <= slv_r_beats + 1;
          if (s_len_q == 8'd0) begin
            s_busy         <= 1'b0;
            s_resp.r_valid <= 1'b0;
          end else begin
            s_len_q  <= s_len_q - 8'd1;
            s_addr_q <= s_addr_q + (1 << s_size_q);
          end
        end
      end
    end
  end

  assign s_resp.r.id   = s_id_q;
  assign s_resp.r.data = {16'hA5A5, s_addr_q[15:0]};
  assign s_resp.r.resp = 2'b00;
  assign s_resp.r.last = (s_len_q == 8'd0);
  assign s_resp.r.user = '0;

  // 中间 64 位链路的观测：判据二看的就是这里的 arlen/arsize 与实际拍数
  always @(posedge clk) begin
    if (rst_n) begin
      if (mid_req.ar_valid && mid_resp.ar_ready) begin
        mid_ar_cnt <= mid_ar_cnt + 1;
        $display("[MID_AR] #%0d t=%0t addr=0x%08h len=%0d size=%0d",
                 mid_ar_cnt + 1, $time, mid_req.ar.addr, mid_req.ar.len, mid_req.ar.size);
      end
      if (mid_resp.r_valid && mid_req.r_ready) mid_r_beats <= mid_r_beats + 1;
    end
  end

  // ---------------------------------------------------------------------------
  // 32 位 master 侧激励
  // ---------------------------------------------------------------------------
  int exp_slv_ar, exp_mid_ar;
  int errors = 0;

  task automatic reset_counters();
    slv_ar_cnt = 0; slv_r_beats = 0; mid_ar_cnt = 0; mid_r_beats = 0;
  endtask

  task automatic do_read(input addr_t addr, input logic [7:0] len, input logic [2:0] size);
    @(posedge clk);
    m_req.ar.id    <= 4'd1;
    m_req.ar.addr  <= addr;
    m_req.ar.len   <= len;
    m_req.ar.size  <= size;
    m_req.ar.burst <= 2'b01;   // INCR
    m_req.ar.lock  <= 1'b0;
    m_req.ar.cache <= 4'b0;
    m_req.ar.prot  <= 3'b0;
    m_req.ar.qos   <= 4'b0;
    m_req.ar.region<= 4'b0;
    m_req.ar.user  <= '0;
    m_req.ar_valid <= 1'b1;
    m_req.r_ready  <= 1'b1;
    do @(posedge clk); while (!m_resp.ar_ready);
    m_req.ar_valid <= 1'b0;
    // 等到 rlast
    forever begin
      @(posedge clk);
      if (m_resp.r_valid && m_req.r_ready && m_resp.r.last) break;
    end
    repeat (5) @(posedge clk);
  endtask

  task automatic check(input string name, input int got, input int exp_a, input int exp_b);
    if (got != exp_a && got != exp_b) begin
      $display("[PROBE] [FAIL] %s = %0d (期望 %0d 或 %0d)", name, got, exp_a, exp_b);
      errors++;
    end
  endtask

  initial begin
    m_req = '0;
    reset_counters();
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (10) @(posedge clk);

    $display("\n[PROBE] ================ 判据一：32 位单拍读 ================");
    reset_counters();
    do_read(32'h1F00_0000, 8'd0, 3'd2);
    $display("[PROBE] 单拍读结果：slave 侧 AR=%0d 次, R=%0d 拍 | 中间 64 位链路 AR=%0d 次, R=%0d 拍",
             slv_ar_cnt, slv_r_beats, mid_ar_cnt, mid_r_beats);
    $display("[PROBE] => slave AR=1 走方案B(外设挂降宽器)；AR=2 走方案A(外设加宽到64位)");

    $display("\n[PROBE] ================ 判据二：4 拍 32 位 INCR ================");
    reset_counters();
    do_read(32'h1C00_0000, 8'd3, 3'd2);
    $display("[PROBE] 4拍读结果：slave 侧 AR=%0d 次, R=%0d 拍 | 中间 64 位链路 AR=%0d 次, R=%0d 拍",
             slv_ar_cnt, slv_r_beats, mid_ar_cnt, mid_r_beats);
    $display("[PROBE] => 中间链路 R=2 拍即真打包(CPU 访存次数减半)；R=4 拍则只填充不打包，CPU 侧收益归零");

    $display("\n[PROBE] ================ 判据三：窄传输 ================");
    reset_counters();
    do_read(32'h1F00_0005, 8'd0, 3'd0);   // 字节读，模拟 UART LSR
    $display("[PROBE] 字节读结果：slave 侧 AR=%0d 次, R=%0d 拍, size 见上面 [SLV_AR]",
             slv_ar_cnt, slv_r_beats);
    reset_counters();
    do_read(32'h1C00_0010, 8'd7, 3'd3);   // 64 位 8 拍，模拟 DMA 加宽后的突发
    $display("[PROBE] 64位8拍结果：slave 侧 AR=%0d 次, R=%0d 拍",
             slv_ar_cnt, slv_r_beats);

    $display("\n[PROBE] ===== 结束：errors=%0d =====", errors);
    $display("[PROBE] %s", (errors == 0) ? "PASS" : "FAIL");
    $finish;
  end

  initial begin
    #500000;
    $display("[PROBE] [FAIL] timeout");
    $finish;
  end

endmodule

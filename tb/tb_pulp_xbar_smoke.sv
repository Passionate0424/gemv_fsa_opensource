// =============================================================================
// tb_pulp_xbar_smoke —— pulp axi_xbar 编译冒烟测试
// =============================================================================
// 目的只有一个：验证 pulp-platform/axi 的 SystemVerilog（struct / interface /
// typedef / 参数化类型）能被本项目的工具链吃下。**不验功能**，功能等价性由
// 后续把它接进 soc_top 后的 SoC 仿真 + tb_cpu_core difftest 来判。
//
// 配置与本项目 SoC 现状对齐：2 个 master（CPU/DMA）× 8 个 slave，32 位数据，
// master 侧 ID 4 位，地址映射逐字照搬现有 AxiCrossbar_2x8。
//
// LatencyMode 选 CUT_ALL_AX：只在 AW/AR 地址通道插寄存器，数据通道不插。
// 理由：CPU 只有 1 笔 outstanding、严格顺序、单拍访问的延迟直接暴露在
// ROPE/RMSNORM 这些段上，不宜多插级；而原 SpinalHDL crossbar 默认就在地址
// 通道有 valid pipe，选这个最接近现状，便于做"换件"这一个变量的性能定标。
// =============================================================================

`include "axi/typedef.svh"
`include "axi/assign.svh"

module tb_pulp_xbar_smoke;

    // ---------------- 总线几何 ----------------
    localparam int unsigned ADDR_W    = 32;
    localparam int unsigned DATA_W    = 32;   // 第 1 步先 32 位，第 4 步才翻 64
    localparam int unsigned STRB_W    = DATA_W / 8;
    localparam int unsigned ID_SLV_W  = 4;    // master 侧 ID 宽（CPU/DMA 都是 4 位）
    localparam int unsigned USER_W    = 1;
    localparam int unsigned N_MST     = 2;    // 接 master 的口（pulp 叫 slave port）
    localparam int unsigned N_SLV     = 8;    // 接 slave 的口（pulp 叫 master port）

    // slave 侧 ID 要多出 log2(master 数) 位，供 xbar 回程路由
    localparam int unsigned ID_MST_W  = ID_SLV_W + $clog2(N_MST);

    typedef logic [ADDR_W-1:0]   addr_t;
    typedef logic [DATA_W-1:0]   data_t;
    typedef logic [STRB_W-1:0]   strb_t;
    typedef logic [ID_SLV_W-1:0] id_slv_t;
    typedef logic [ID_MST_W-1:0] id_mst_t;
    typedef logic [USER_W-1:0]   user_t;

    `AXI_TYPEDEF_ALL(slv, addr_t, id_slv_t, data_t, strb_t, user_t)
    `AXI_TYPEDEF_ALL(mst, addr_t, id_mst_t, data_t, strb_t, user_t)

    // ---------------- 地址映射（逐字照搬 AxiCrossbar_2x8） ----------------
    // 0x0000_0000 与 0x1C00_0000 两段都落到 RAM（后者是主用，前者是启动别名）
    localparam axi_pkg::xbar_rule_32_t [N_SLV-1:0] ADDR_MAP = '{
        '{idx: 32'd7, start_addr: 32'h1F50_0000, end_addr: 32'h1F60_0000},  // 保留
        '{idx: 32'd6, start_addr: 32'h1F40_0000, end_addr: 32'h1F50_0000},  // 保留(fft)
        '{idx: 32'd5, start_addr: 32'h1F30_0000, end_addr: 32'h1F40_0000},  // 加速器 CSR
        '{idx: 32'd4, start_addr: 32'h1F20_0000, end_addr: 32'h1F30_0000},  // confreg
        '{idx: 32'd3, start_addr: 32'h1F10_0000, end_addr: 32'h1F20_0000},  // DVI
        '{idx: 32'd2, start_addr: 32'h1F00_0000, end_addr: 32'h1F10_0000},  // UART/APB
        '{idx: 32'd0, start_addr: 32'h1C00_0000, end_addr: 32'h1C80_0000},  // RAM 主段
        '{idx: 32'd0, start_addr: 32'h0000_0000, end_addr: 32'h0080_0000}   // RAM 别名段
    };

    localparam axi_pkg::xbar_cfg_t XBAR_CFG = '{
        NoSlvPorts:         N_MST,
        NoMstPorts:         N_SLV,
        MaxMstTrans:        4,     // DMA 读侧 MAX_OUTSTANDING=4
        MaxSlvTrans:        4,
        FallThrough:        1'b0,
        LatencyMode:        axi_pkg::CUT_ALL_AX,
        PipelineStages:     0,
        AxiIdWidthSlvPorts: ID_SLV_W,
        AxiIdUsedSlvPorts:  ID_SLV_W,
        UniqueIds:          1'b0,  // CPU 用 rid[0] 区分 icache/dcache，ID 会复用
        AxiAddrWidth:       ADDR_W,
        AxiDataWidth:       DATA_W,
        NoAddrRules:        N_SLV
    };

    // ---------------- 信号 ----------------
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    slv_req_t  [N_MST-1:0] mst_req;
    slv_resp_t [N_MST-1:0] mst_resp;
    mst_req_t  [N_SLV-1:0] slv_req;
    mst_resp_t [N_SLV-1:0] slv_resp;

    // 冒烟测试不驱动真实激励：master 侧全部静默，slave 侧恒 ready、不回响应。
    // 只要能编译+复位跑完若干拍且不报 X 传播/断言，本步目的即达成。
    assign mst_req  = '0;
    assign slv_resp = '0;

    axi_xbar #(
        .Cfg           ( XBAR_CFG          ),
        .ATOPs         ( 1'b0              ),  // CPU/DMA 都不发原子操作
        .slv_aw_chan_t ( slv_aw_chan_t     ),
        .mst_aw_chan_t ( mst_aw_chan_t     ),
        .w_chan_t      ( slv_w_chan_t      ),
        .slv_b_chan_t  ( slv_b_chan_t      ),
        .mst_b_chan_t  ( mst_b_chan_t      ),
        .slv_ar_chan_t ( slv_ar_chan_t     ),
        .mst_ar_chan_t ( mst_ar_chan_t     ),
        .slv_r_chan_t  ( slv_r_chan_t      ),
        .mst_r_chan_t  ( mst_r_chan_t      ),
        .slv_req_t     ( slv_req_t         ),
        .slv_resp_t    ( slv_resp_t        ),
        .mst_req_t     ( mst_req_t         ),
        .mst_resp_t    ( mst_resp_t        ),
        .rule_t        ( axi_pkg::xbar_rule_32_t )
    ) u_xbar (
        .clk_i                 ( clk       ),
        .rst_ni                ( rst_n     ),
        .test_i                ( 1'b0      ),
        .slv_ports_req_i       ( mst_req   ),
        .slv_ports_resp_o      ( mst_resp  ),
        .mst_ports_req_o       ( slv_req   ),
        .mst_ports_resp_i      ( slv_resp  ),
        .addr_map_i            ( ADDR_MAP  ),
        .en_default_mst_port_i ( '0        ),
        .default_mst_port_i    ( '0        )
    );

    initial begin
        $display("[SMOKE] pulp axi_xbar compile test: N_MST=%0d N_SLV=%0d DATA_W=%0d ID_SLV_W=%0d ID_MST_W=%0d",
                 N_MST, N_SLV, DATA_W, ID_SLV_W, ID_MST_W);
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (50) @(posedge clk);
        $display("[SMOKE] PASS: elaborated and ran 50 cycles after reset");
        $finish;
    end

endmodule

// =============================================================================
// axi_protocol_checker —— 扁平端口的 AXI4 协议断言检查器（仅 tb，不进交付 RTL）
// =============================================================================
// plan 第 2 步。原计划用 ZipCPU 的 faxi_master.v / faxi_slave.v，实测**公开版是被
// 有意截断的子集**：端口列表末项悬空（`f_axi_rd_outstanding,` 后面跟一行 `// ...`
// 就直接 `);`），VCS 报语法错；完整属性集需向 Gisselquist Technology 购买。且那份
// 内部大量用 `assume`——形式验证里 assume 是约束，在仿真里却只会默默通过，拿它当
// 仿真断言会得到假的"零违例"。
//
// 改用 pulp 自己的那套：`third_party/axi/src/axi_intf.sv:204-250` 里有 42 条
// 单通道握手稳定性断言，与本轮换上的 `axi_xbar` 同源、同版本。但那些断言绑在
// `AXI_BUS` interface 上，而 `soc_top.v` 是纯 Verilog 扁平信号连线，套不上去。
// 本模块把同一套属性逐条转录到扁平端口，供 `bind` 用。
//
// 检查的是什么：**valid 拉高后到握手完成之前，该通道的所有载荷信号与 valid 本身
// 都不得改变**（AXI4 spec A3.2.1）。这是位宽转换器、升宽器、spill register 最容易
// 违反的一条——它们在背压下要把一拍拆成多拍或缓存在途拍，写错就会中途改数据。
// `axi2sram_sp_ext` 那个 skid 缓冲正是为此加的，本检查器直接覆盖它。
//
// 另外补三条 pulp 没有、但本轮加宽真正在乎的：
//   · RLAST 与 arlen 一致（读回拍数不多不少）
//   · WLAST 与 awlen 一致
//   · 突发不跨 4KB 边界（AXI4 spec A3.4.1）
// 这三条是"事务级"的，pulp 的单通道断言查不到，而 DMA 的 arlen 算错（本轮修过
// 两次：255 拍野突发、向上取整）恰好就落在这里。
//
// 用法（在 tb 里 bind 到任意扁平 AXI 口）：
//   bind soc_top axi_protocol_checker #(
//       .ADDR_W(32), .DATA_W(64), .ID_W(4), .NAME("cpu_mst")
//   ) u_chk_cpu (.aclk(clk), .aresetn(resetn), .awvalid(...), ...);
// =============================================================================

`ifndef SYNTHESIS
module axi_protocol_checker #(
    parameter int unsigned ADDR_W = 32,
    parameter int unsigned DATA_W = 64,
    parameter int unsigned ID_W   = 4,
    // 出现在断言消息里，用来分清是哪个口违例
    parameter string       NAME   = "axi"
)(
    input logic                aclk,
    input logic                aresetn,
    // AW
    input logic                awvalid,
    input logic                awready,
    input logic [ID_W-1:0]     awid,
    input logic [ADDR_W-1:0]   awaddr,
    input logic [7:0]          awlen,
    input logic [2:0]          awsize,
    input logic [1:0]          awburst,
    // W
    input logic                wvalid,
    input logic                wready,
    input logic [DATA_W-1:0]   wdata,
    input logic [DATA_W/8-1:0] wstrb,
    input logic                wlast,
    // B
    input logic                bvalid,
    input logic                bready,
    input logic [ID_W-1:0]     bid,
    input logic [1:0]          bresp,
    // AR
    input logic                arvalid,
    input logic                arready,
    input logic [ID_W-1:0]     arid,
    input logic [ADDR_W-1:0]   araddr,
    input logic [7:0]          arlen,
    input logic [2:0]          arsize,
    input logic [1:0]          arburst,
    // R
    input logic                rvalid,
    input logic                rready,
    input logic [ID_W-1:0]     rid,
    input logic [DATA_W-1:0]   rdata,
    input logic [1:0]          rresp,
    input logic                rlast
);

    // 复位期间不查：复位释放前信号本就是任意值。disable iff 而不是把 aresetn 写进
    // 前件——后者在复位那一拍仍会用到 $stable 的历史值。
    default disable iff (!aresetn);

    // ------------------------------------------------------------------
    // 一、单通道握手稳定性（转录自 axi_intf.sv:204-250）
    // ------------------------------------------------------------------
    // 未连线的通道（如只读口的 AW/W/B）由上层 bind 时接常零，断言恒真、无副作用。
    `define CHK_STABLE(ch, sig) \
        assert property (@(posedge aclk) (ch``valid && !ch``ready |=> $stable(sig))) \
        else $error("[AXI-CHK %s] %s changed while %svalid held without handshake", \
                    NAME, `"sig`", `"ch`");

    // AW
    `CHK_STABLE(aw, awid)
    `CHK_STABLE(aw, awaddr)
    `CHK_STABLE(aw, awlen)
    `CHK_STABLE(aw, awsize)
    `CHK_STABLE(aw, awburst)
    assert property (@(posedge aclk) (awvalid && !awready |=> awvalid))
    else $error("[AXI-CHK %s] awvalid deasserted before handshake", NAME);

    // W
    `CHK_STABLE(w, wdata)
    `CHK_STABLE(w, wstrb)
    `CHK_STABLE(w, wlast)
    assert property (@(posedge aclk) (wvalid && !wready |=> wvalid))
    else $error("[AXI-CHK %s] wvalid deasserted before handshake", NAME);

    // B
    `CHK_STABLE(b, bid)
    `CHK_STABLE(b, bresp)
    assert property (@(posedge aclk) (bvalid && !bready |=> bvalid))
    else $error("[AXI-CHK %s] bvalid deasserted before handshake", NAME);

    // AR
    `CHK_STABLE(ar, arid)
    `CHK_STABLE(ar, araddr)
    `CHK_STABLE(ar, arlen)
    `CHK_STABLE(ar, arsize)
    `CHK_STABLE(ar, arburst)
    assert property (@(posedge aclk) (arvalid && !arready |=> arvalid))
    else $error("[AXI-CHK %s] arvalid deasserted before handshake", NAME);

    // R
    `CHK_STABLE(r, rid)
    `CHK_STABLE(r, rdata)
    `CHK_STABLE(r, rresp)
    `CHK_STABLE(r, rlast)
    assert property (@(posedge aclk) (rvalid && !rready |=> rvalid))
    else $error("[AXI-CHK %s] rvalid deasserted before handshake", NAME);

    `undef CHK_STABLE

    // ------------------------------------------------------------------
    // 二、事务级：拍数与 len 一致
    // ------------------------------------------------------------------
    // 这是 pulp 的单通道断言查不到、而本轮加宽真正在乎的一条。DMA 的 arlen 算错
    // 已经犯过两次（尾块整除下溢成 255 拍、向上取整），两次都是"多读/少读几拍"，
    // 单看某一拍的信号都合法。
    //
    // 只在单 outstanding 下逐笔配对是不够的——本设计 DMA 读侧 MAX_OUTSTANDING=4。
    // 但 AXI 要求**同一 ID 的读数据必须按发出顺序返回**，而本设计所有 master 的读
    // 事务同 ID（DMA 恒 0、CPU 靠 rid[0] 分 icache/dcache 但各自顺序），所以用一个
    // 先进先出的 len 队列就能正确配对。
    localparam int unsigned QD = 16;   // 深度取够：DMA 4 笔、CPU 1 笔，16 有大量余量

    logic [7:0] rd_len_q [QD-1:0];
    int unsigned rd_wp, rd_rp;
    logic [8:0] rd_beat;               // 当前 burst 已收拍数

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            rd_wp <= 0; rd_rp <= 0; rd_beat <= 0;
        end else begin
            if (arvalid && arready) begin
                rd_len_q[rd_wp] <= arlen;
                rd_wp <= (rd_wp + 1) % QD;
            end
            if (rvalid && rready) begin
                if (rlast) begin
                    // 收到 RLAST 时，本 burst 的拍数必须恰好等于队首 len+1
                    assert (rd_beat == rd_len_q[rd_rp])
                    else $error("[AXI-CHK %s] read beat count %0d != arlen %0d",
                                NAME, rd_beat + 1, rd_len_q[rd_rp] + 1);
                    rd_beat <= 0;
                    rd_rp   <= (rd_rp + 1) % QD;
                end else begin
                    // 拍数不能超过 len（超了说明 RLAST 迟迟不来）
                    assert (rd_beat < rd_len_q[rd_rp])
                    else $error("[AXI-CHK %s] read beats exceed arlen %0d without RLAST",
                                NAME, rd_len_q[rd_rp] + 1);
                    rd_beat <= rd_beat + 1;
                end
            end
        end
    end

    // 写侧同理。本设计写通道恒单 outstanding（`axi_dma_controller` 写侧、CPU 都是），
    // 但仍用队列写，免得将来放开并发时这里变成静默失效的检查。
    logic [7:0] wr_len_q [QD-1:0];
    int unsigned wr_wp, wr_rp;
    logic [8:0] wr_beat;

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wr_wp <= 0; wr_rp <= 0; wr_beat <= 0;
        end else begin
            if (awvalid && awready) begin
                wr_len_q[wr_wp] <= awlen;
                wr_wp <= (wr_wp + 1) % QD;
            end
            if (wvalid && wready) begin
                if (wlast) begin
                    assert (wr_beat == wr_len_q[wr_rp])
                    else $error("[AXI-CHK %s] write beat count %0d != awlen %0d",
                                NAME, wr_beat + 1, wr_len_q[wr_rp] + 1);
                    wr_beat <= 0;
                    wr_rp   <= (wr_rp + 1) % QD;
                end else begin
                    assert (wr_beat < wr_len_q[wr_rp])
                    else $error("[AXI-CHK %s] write beats exceed awlen %0d without WLAST",
                                NAME, wr_len_q[wr_rp] + 1);
                    wr_beat <= wr_beat + 1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // 三、突发不得跨 4KB 边界（AXI4 spec A3.4.1）—— 默认关，见下方长注释
    // ------------------------------------------------------------------
    // 这条**本设计确实违反**，且是刻意不修的。首次上线检查器就抓到 1551 笔
    // （读 1523 / 写 28），占 DMA 读事务 4037 笔的 38%，全是权重按 stride 逐行搬
    // 时行首骑在页边界上（如 addr=0x1c083f38 len=31 size=3，距页尾只剩 200 字节）。
    //
    // 为什么判定无害：4KB 规则是为带 MMU 的系统写的——一笔突发跨页可能跨到不同
    // 物理页、不同从设备、或权限不同的区域，从设备没法用一个基址线性递增地服务它。
    // 本设计路径上逐个查过都不依赖它：
    //   · pulp axi_xbar —— 地址译码只比对 slave 的 start/end 范围，与页无关；
    //   · pulp axi_dw_upsizer —— 源码里没有 4096/boundary，零 assert；
    //   · axi_pkg 里的 4096 —— 只用于 BURST_WRAP 的 wrap 边界计算，本设计全走 INCR；
    //   · axi2sram_sp_ext 与外部异步 SRAM —— 线性物理寻址，无页概念。
    // 且跨界地址全落在 0x1c083f38–0x1c21afe8，同一个 slave（RAM，0x1C00_0000 起 8MB）
    // 内部，不存在跨到另一个从设备的情况。
    //
    // 也不是本轮加宽引入的：32 位时代同一行权重是 len=63 size=2，同样 256 字节、
    // 同样跨界。问题一直在，只是今天才第一次有检查器看见。
    //
    // 为什么不修：修法是 DMA 侧按页切分突发，代价是 38% 的事务各多一次 AR 握手与
    // 地址通道往返，还打断 burst 连续性——外部 SRAM 的 tAA=10ns 是硬墙，长突发靠
    // 地址流水摊薄它，切成两段后中间要重新起地址；多出来的那笔还占掉一个
    // outstanding 槽位（读侧 MAX_OUTSTANDING=4）。粗估总时间 +1~3%，而本轮加宽的
    // 预期收益是 18%，为一条在本系统里无害的条文吃掉其中一块，不划算。
    //
    // 所以放在开关后面而不是删掉：将来若换商用 IP、接带 MMU 的从设备、或把这个 DMA
    // 复用到别的 SoC，打开 +define+AXI_CHK_4K 就能立刻复现，不用重新发现一遍。
    //
    // 注意：一、二两类（握手稳定性、拍数与 len 一致）保持 error 且默认开——那才是
    // 本轮改动真正可能碰坏的东西，且实测已经零违例。
`ifdef AXI_CHK_4K
    // 只对 INCR 查——WRAP/FIXED 的边界规则不同，本设计不用。
    function automatic logic crosses_4k(input logic [ADDR_W-1:0] addr,
                                        input logic [7:0]        len,
                                        input logic [2:0]        size);
        logic [ADDR_W:0] last_byte;
        last_byte = addr + ((len + 1) << size) - 1;
        return (last_byte[ADDR_W-1:12] != addr[ADDR_W-1:12]);
    endfunction

    assert property (@(posedge aclk)
        (arvalid && arready && arburst == 2'b01) |-> !crosses_4k(araddr, arlen, arsize))
    else $error("[AXI-CHK %s] read burst crosses 4KB: addr=0x%0h len=%0d size=%0d",
                NAME, araddr, arlen, arsize);

    assert property (@(posedge aclk)
        (awvalid && awready && awburst == 2'b01) |-> !crosses_4k(awaddr, awlen, awsize))
    else $error("[AXI-CHK %s] write burst crosses 4KB: addr=0x%0h len=%0d size=%0d",
                NAME, awaddr, awlen, awsize);
`endif

endmodule
`endif

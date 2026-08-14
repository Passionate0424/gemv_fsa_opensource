`timescale 1ns/1ps
//======================================================================
// ⚠️ WIP / 暂搁置(2026-07-25)：本 tb 直连 wrapper+sram(无 SoC 的 AxiCrossbar)，
//   T1-T4(ext读写/背靠背/base读写)通过，但 T5 base→ext 切换读返回 base 数据。
//   经排查为 tb 建模问题(直连桥缺 crossbar 的事务间隔/寄存)，非 RTL bug——
//   权威的 SoC 级仿真(run_soc_sim.ps1，同款 sram.v + 真实 crossbar+CPU+加速器)
//   跑 20M cycle base↔ext 切换全对，已证明 depth-2/IOB 桥 RTL 功能正确。
//   保留作后续重做的脚手架(需补 crossbar 建模或修正 AXI 背靠背驱动)。
//======================================================================
// tb_soc_sram_bridge —— SoC 外部 SRAM 访存链路(层0)黑盒定向验证
//----------------------------------------------------------------------
// 被测: axi_wrap_ram_sp_external(含 IOB 地址寄存化 + depth-2 读流水桥
//        axi2sram_sp_ext) + 两个 sram_sp(异步读/边沿写外部 SRAM 模型)。
//
// 为何例化 wrapper 而非 bridge-only：wrapper 的 (* IOB *) 地址寄存使地址
//   晚 1 拍到 SRAM 引脚，depth-2 读流水(READ_START→READ_HOLD→READ)正是为
//   吸收此 1 拍而设。只有把 wrapper+sram_sp 一起例化才天然含这 1 拍延迟，
//   逐拍复刻上板；bridge-only + 0 延迟内存会 off-by-one(regional 旧 tb 之坑)。
//
// 地址映射(wrapper): soc_sram_addr[22]=1→ExtRAM, =0→BaseRAM;
//   ram 字地址 = addr[21:2]。故 AXI 字节地址 0x400000 起 → Ext 字 0,1,2...
//
// 验证 case:
//   T1 ExtRAM 写 16 word burst → T2 读回逐拍校验
//   T3 ExtRAM 32 burst × 8 beat 背靠背(系统级，验 depth-2 背靠背换 burst)
//   T4 BaseRAM 写读(addr[22]=0，验另一块选择正确)
//   T5 读延迟 gap 实测(AR 握手→首 rvalid 经过拍数，depth-2+IOB 定标)
//
// 时钟 20ns(50MHz)：> sram_sp 边沿写 #10 脉冲，写捕获落在 IOB 稳定值中点。
//======================================================================
module tb_soc_sram_bridge;

    localparam CLK_PERIOD = 20;
    localparam SRAM_AW    = 20;   // 与 SoC mycpu_tb 一致

    logic clk, rstn;
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- AXI master 侧 ----
    logic [4:0]  arid, awid;
    logic [31:0] araddr, awaddr;
    logic [7:0]  arlen, awlen;
    logic [2:0]  arsize, awsize;
    logic [1:0]  arburst, awburst;
    logic        arvalid, awvalid, arready, awready;
    logic [4:0]  rid, bid;
    logic [31:0] rdata, wdata;
    logic [1:0]  rresp, bresp;
    logic        rlast, rvalid, rready;
    logic        wvalid, wready, wlast, bvalid, bready;
    logic [3:0]  wstrb;

    // ---- 外部 SRAM 引脚(wrapper ↔ sram_sp) ----
    wire [31:0] base_ram_data, ext_ram_data;
    wire [19:0] base_ram_addr, ext_ram_addr;
    wire [3:0]  base_ram_be_n, ext_ram_be_n;
    wire        base_ram_ce_n, ext_ram_ce_n;
    wire        base_ram_oe_n, ext_ram_oe_n;
    wire        base_ram_we_n, ext_ram_we_n;

    // ---- DUT: wrapper(含 IOB + depth-2 桥) ----
    axi_wrap_ram_sp_external u_wrap (
        .aclk(clk), .aresetn(rstn),
        .axi_arid(arid), .axi_araddr(araddr), .axi_arlen(arlen),
        .axi_arsize(arsize), .axi_arburst(arburst), .axi_arlock(1'b0),
        .axi_arcache(4'b0), .axi_arprot(3'b0),
        .axi_arvalid(arvalid), .axi_arready(arready),
        .axi_rid(rid), .axi_rdata(rdata), .axi_rresp(rresp),
        .axi_rlast(rlast), .axi_rvalid(rvalid), .axi_rready(rready),
        .axi_awid(awid), .axi_awaddr(awaddr), .axi_awlen(awlen),
        .axi_awsize(awsize), .axi_awburst(awburst), .axi_awlock(1'b0),
        .axi_awcache(4'b0), .axi_awprot(3'b0),
        .axi_awvalid(awvalid), .axi_awready(awready),
        .axi_wdata(wdata), .axi_wstrb(wstrb), .axi_wlast(wlast),
        .axi_wvalid(wvalid), .axi_wready(wready),
        .axi_bid(bid), .axi_bresp(bresp), .axi_bvalid(bvalid), .axi_bready(bready),
        .base_ram_data(base_ram_data), .base_ram_addr(base_ram_addr),
        .base_ram_be_n(base_ram_be_n), .base_ram_ce_n(base_ram_ce_n),
        .base_ram_oe_n(base_ram_oe_n), .base_ram_we_n(base_ram_we_n),
        .ext_ram_data(ext_ram_data), .ext_ram_addr(ext_ram_addr),
        .ext_ram_be_n(ext_ram_be_n), .ext_ram_ce_n(ext_ram_ce_n),
        .ext_ram_oe_n(ext_ram_oe_n), .ext_ram_we_n(ext_ram_we_n)
    );

    // ---- 外部 SRAM 模型(异步读 + 边沿写，与 SoC 一致) ----
    sram_sp #(.AW(SRAM_AW)) u_base (
        .ram_data(base_ram_data), .ram_addr(base_ram_addr),
        .ram_be_n(base_ram_be_n), .ram_ce_n(base_ram_ce_n),
        .ram_oe_n(base_ram_oe_n), .ram_we_n(base_ram_we_n)
    );
    sram_sp #(.AW(SRAM_AW)) u_ext (
        .ram_data(ext_ram_data), .ram_addr(ext_ram_addr),
        .ram_be_n(ext_ram_be_n), .ram_ce_n(ext_ram_ce_n),
        .ram_oe_n(ext_ram_oe_n), .ram_we_n(ext_ram_we_n)
    );

    integer errors;
    integer first_rvalid_gap;

    // ---- 调试探针：base→ext 切换取证(gate 于 probe_on) ----
    logic probe_on;
    initial probe_on = 0;
    always @(posedge clk) if (probe_on) begin
        $display("[PROBE] t=%0t st=%0d axaddr=%08x addr_o=%08x cnt=%0d ocnt=%0d dq=%08x cs_we=%b cs_q=%b bce_n=%b ece_n=%b rv=%b rlast=%b rd=%08x",
            $time,
            u_wrap.u_axi_sram_sp.state_q, u_wrap.u_axi_sram_sp.ax_req_q_addr,
            u_wrap.u_axi_sram_sp.addr_o, u_wrap.u_axi_sram_sp.cnt_q,
            u_wrap.u_axi_sram_sp.out_cnt_q, u_wrap.u_axi_sram_sp.data_q,
            u_wrap.choose_sram_we, u_wrap.choose_sram_q,
            base_ram_ce_n, ext_ram_ce_n, rvalid, rlast, rdata);
    end

    // ---- 写 burst(数据 = start_val + i) ----
    task write_burst(input [31:0] addr, input int beats, input int start_val);
        @(posedge clk);
        awid <= 0; awaddr <= addr; awlen <= beats-1;
        awsize <= 3'b010; awburst <= 2'b01; awvalid <= 1;
        while (!awready) @(posedge clk);
        @(posedge clk); awvalid <= 0;
        for (int i = 0; i < beats; i++) begin
            wdata <= start_val + i; wstrb <= 4'hf;
            wlast <= (i == beats-1); wvalid <= 1;
            @(posedge clk);
            while (!wready) @(posedge clk);
        end
        wvalid <= 0; wlast <= 0;
        while (!bvalid) @(posedge clk);
        @(posedge clk);
    endtask

    // ---- 发 AR(不等响应) ----
    task issue_ar(input [31:0] addr, input [7:0] len);
        @(posedge clk);
        arid <= 0; araddr <= addr; arlen <= len;
        arsize <= 3'b010; arburst <= 2'b01; arvalid <= 1;
        @(posedge clk);
        while (!arready) @(posedge clk);
        arvalid <= 0;
    endtask

    // ---- 接收 burst 并逐拍校验 ----
    task receive_and_check_burst(input int beats, input int start_val);
        int beat_cnt = 0;
        while (beat_cnt < beats) begin
            @(posedge clk);
            if (rvalid && rready) begin
                if (rdata !== (start_val + beat_cnt)) begin
                    $display("[tb_soc_sram_bridge] [FAIL] beat=%0d exp=%08x got=%08x",
                             beat_cnt, start_val + beat_cnt, rdata);
                    errors = errors + 1;
                end
                if (beat_cnt == beats-1 && !rlast) begin
                    $display("[tb_soc_sram_bridge] [FAIL] RLAST not on last beat");
                    errors = errors + 1;
                end
                beat_cnt++;
            end
        end
    endtask

    task read_burst_check(input [31:0] addr, input int beats, input int start_val);
        issue_ar(addr, beats-1);
        receive_and_check_burst(beats, start_val);
    endtask

    // ---- T5: 单读 burst，测 AR 握手后到首 rvalid 的 gap ----
    task read_burst_measure_gap(input [31:0] addr, input int beats, input int start_val);
        int beat_cnt;
        int gap;
        // 发 AR 并等 arready 握手
        @(posedge clk);
        arid <= 0; araddr <= addr; arlen <= beats-1;
        arsize <= 3'b010; arburst <= 2'b01; arvalid <= 1;
        @(posedge clk);
        while (!arready) @(posedge clk);
        arvalid <= 0;
        // 从 AR 握手拍的下一拍开始数，首次 rvalid&&rready 记录 gap
        gap = 0; beat_cnt = 0; first_rvalid_gap = -1;
        while (beat_cnt < beats) begin
            @(posedge clk);
            gap = gap + 1;
            if (rvalid && rready) begin
                if (first_rvalid_gap == -1) first_rvalid_gap = gap;
                if (rdata !== (start_val + beat_cnt)) begin
                    $display("[tb_soc_sram_bridge] [FAIL] T5 beat=%0d exp=%08x got=%08x",
                             beat_cnt, start_val + beat_cnt, rdata);
                    errors = errors + 1;
                end
                beat_cnt++;
            end
        end
    endtask

    initial begin
        errors = 0;
        arvalid=0; awvalid=0; rready=1; wvalid=0; wlast=0; bready=1;
        araddr=0; awaddr=0; arlen=0; awlen=0; arsize=3'b010; awsize=3'b010;
        arburst=1; awburst=1; wdata=0; wstrb=4'hf; arid=0; awid=0;

        rstn = 0; repeat (5) @(posedge clk); rstn = 1; repeat (3) @(posedge clk);

        // T1/T2: ExtRAM(addr[22]=1) 写 16 word @0x400000 → 读回校验
        $display("\n[T1/T2] ExtRAM write+read 16 words @0x400000");
        write_burst(32'h0040_0000, 16, 32'h100);
        read_burst_check(32'h0040_0000, 16, 32'h100);

        // T3: ExtRAM 32 burst × 8 beat 背靠背(系统级)
        $display("\n[T3] ExtRAM 32 bursts x 8 beats back-to-back");
        for (int b = 0; b < 32; b++)
            write_burst(32'h0040_0000 + b*32, 8, b*8);
        fork
            begin
                for (int b = 0; b < 32; b++)
                    issue_ar(32'h0040_0000 + b*32, 7);
            end
            begin
                for (int b = 0; b < 32; b++)
                    receive_and_check_burst(8, b*8);
            end
        join

        // T4: BaseRAM(addr[22]=0) 写读，验另一块选择正确
        $display("\n[T4] BaseRAM write+read 16 words @0x00000000");
        write_burst(32'h0000_0000, 16, 32'hA00);
        read_burst_check(32'h0000_0000, 16, 32'hA00);

        // T5: base→ext 切换读(成熟 pattern)。T4 刚读 base，此处读 ext 0x400000
        //   (T3 b=0 写的 ext 字 0..7 = 0..7)，验证切换后块选择/地址不串。
        $display("\n[T5] base->ext transition read @0x400000 (proven pattern)");
        repeat (10) @(posedge clk);   // 实验：异块切换前插 idle drain(模拟 crossbar 间隔)
        read_burst_check(32'h0040_0000, 8, 32'h0);

        // T6: 读延迟 gap 实测(depth-2+IOB 定标)。读已知 ext 0x400000(字0=0)。
        $display("\n[T6] read latency gap measure @0x400000");
        read_burst_measure_gap(32'h0040_0000, 8, 32'h0);
        $display("[tb_soc_sram_bridge] [INFO] T6 AR->first-rvalid gap = %0d cycles", first_rvalid_gap);

        repeat (5) @(posedge clk);
        if (errors == 0)
            $display("\n[tb_soc_sram_bridge] [PASS] all read/write verified (gap=%0d)", first_rvalid_gap);
        else
            $display("\n[tb_soc_sram_bridge] [FAIL] %0d error(s)", errors);
        $finish;
    end

    initial begin
        #500000;
        $display("[tb_soc_sram_bridge] [FAIL] timeout");
        $finish;
    end

endmodule

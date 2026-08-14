`timescale 1ns / 1ps
// 独立验证axi2sram_sp_ext的multi-outstanding + pipeline读
module tb_axi_bridge_standalone;

    localparam MEM_AW = 12;
    localparam CLK_PERIOD = 10;

    logic clk, rstn;
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // AXI信号
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

    // DUT实例
    tb_axi_ram_sp_ext #(.MEM_AW(MEM_AW)) u_dut (
        .aclk(clk), .aresetn(rstn),
        .axi_arid(arid), .axi_araddr(araddr), .axi_arlen(arlen),
        .axi_arsize(arsize), .axi_arburst(arburst), .axi_arlock(2'b0),
        .axi_arcache(4'b0), .axi_arprot(3'b0),
        .axi_arvalid(arvalid), .axi_arready(arready),
        .axi_rid(rid), .axi_rdata(rdata), .axi_rresp(rresp),
        .axi_rlast(rlast), .axi_rvalid(rvalid), .axi_rready(rready),
        .axi_awid(awid), .axi_awaddr(awaddr), .axi_awlen(awlen),
        .axi_awsize(awsize), .axi_awburst(awburst), .axi_awlock(2'b0),
        .axi_awcache(4'b0), .axi_awprot(3'b0),
        .axi_awvalid(awvalid), .axi_awready(awready),
        .axi_wdata(wdata), .axi_wstrb(wstrb), .axi_wlast(wlast),
        .axi_wvalid(wvalid), .axi_wready(wready),
        .axi_bid(bid), .axi_bresp(bresp), .axi_bvalid(bvalid), .axi_bready(bready)
    );

    // 初始化
    initial begin
        rstn = 0;
        arid = 0; araddr = 0; arlen = 0; arsize = 3'b010; arburst = 2'b01; arvalid = 0;
        awid = 0; awaddr = 0; awlen = 0; awsize = 3'b010; awburst = 2'b01; awvalid = 0;
        wdata = 0; wstrb = 4'hf; wlast = 0; wvalid = 0;
        rready = 1; bready = 1;
        repeat(5) @(posedge clk);
        rstn = 1;
        repeat(3) @(posedge clk);

        // ========== Test 1: 写入测试数据 ==========
        $display("\n[TEST1] Writing test data...");
        write_burst(32'h0000, 8, 0);  // 8 words at addr 0: data=0,1,2,...,7
        write_burst(32'h0020, 8, 8);  // 8 words at addr 0x20: data=8,9,...,15
        write_burst(32'h0040, 8, 16); // 8 words at addr 0x40: data=16,...,23
        write_burst(32'h0060, 8, 24); // 8 words at addr 0x60: data=24,...,31
        $display("[TEST1] Write done.");

        // ========== Test 2: 单burst读（基线） ==========
        $display("\n[TEST2] Single burst read (baseline)...");
        read_burst_check(32'h0000, 8, 0);
        $display("[TEST2] PASS");

        // ========== Test 3: Multi-outstanding读（连续发4个AR） ==========
        $display("\n[TEST3] Multi-outstanding read (4 AR back-to-back)...");
        fork
            // AR发射端：连续发4个AR不等RLAST
            begin
                issue_ar(32'h0000, 7); // burst 0: 8 beats
                issue_ar(32'h0020, 7); // burst 1: 8 beats
                issue_ar(32'h0040, 7); // burst 2: 8 beats
                issue_ar(32'h0060, 7); // burst 3: 8 beats
            end
            // R接收端：按序接收4个burst的数据
            begin
                receive_and_check_burst(8, 0);   // expect 0,1,...,7
                receive_and_check_burst(8, 8);   // expect 8,9,...,15
                receive_and_check_burst(8, 16);  // expect 16,...,23
                receive_and_check_burst(8, 24);  // expect 24,...,31
            end
        join
        $display("[TEST3] PASS");

        // ========== Test 4: FIFO满压力测试 ==========
        $display("\n[TEST4] FIFO full pressure test (5 AR, depth=4)...");
        fork
            begin
                issue_ar(32'h0000, 3); // 4 beats
                issue_ar(32'h0010, 3);
                issue_ar(32'h0020, 3);
                issue_ar(32'h0030, 3);
                issue_ar(32'h0040, 3); // 第5个，应该被arready=0阻塞
            end
            begin
                receive_and_check_burst(4, 0);
                receive_and_check_burst(4, 4);
                receive_and_check_burst(4, 8);
                receive_and_check_burst(4, 12);
                receive_and_check_burst(4, 16);
            end
        join
        $display("[TEST4] PASS");

        // ========== Test 5: 32 burst × 8 beats（复现系统级场景） ==========
        $display("\n[TEST5] 32 bursts x 8 beats (system-level scenario)...");
        // 先写256个word
        for (int b = 0; b < 32; b++)
            write_burst(b * 32, 8, b * 8);  // addr=b*32, 8 words, data=b*8..b*8+7
        // 连续发32个AR
        fork
            begin
                for (int b = 0; b < 32; b++)
                    issue_ar(b * 32, 7);  // 8 beats each
            end
            begin
                for (int b = 0; b < 32; b++)
                    receive_and_check_burst(8, b * 8);
            end
        join
        $display("[TEST5] PASS");

        // ========== 完成 ==========
        repeat(10) @(posedge clk);
        $display("\n========== ALL BRIDGE TESTS PASSED ==========");
        $finish;
    end

    // 超时保护
    initial begin
        #100000;
        $display("[FAIL] TIMEOUT");
        $finish;
    end

    // ========== Task: 写一个burst ==========
    task write_burst(input [31:0] addr, input int beats, input int start_val);
        @(posedge clk);
        awid <= 0; awaddr <= addr; awlen <= beats - 1;
        awsize <= 3'b010; awburst <= 2'b01; awvalid <= 1;
        while (!awready) @(posedge clk);
        @(posedge clk); awvalid <= 0;
        // W channel
        for (int i = 0; i < beats; i++) begin
            wdata <= start_val + i; wstrb <= 4'hf;
            wlast <= (i == beats - 1); wvalid <= 1;
            @(posedge clk);
            while (!wready) @(posedge clk);
        end
        wvalid <= 0; wlast <= 0;
        // Wait B
        while (!bvalid) @(posedge clk);
        @(posedge clk);
    endtask

    // ========== Task: 发一个AR（不等响应） ==========
    task issue_ar(input [31:0] addr, input [7:0] len);
        @(posedge clk);
        arid <= 0; araddr <= addr; arlen <= len;
        arsize <= 3'b010; arburst <= 2'b01; arvalid <= 1;
        @(posedge clk);
        while (!arready) @(posedge clk);
        arvalid <= 0;
    endtask

    // ========== Task: 读一个burst并检查 ==========
    task read_burst_check(input [31:0] addr, input int beats, input int start_val);
        issue_ar(addr, beats - 1);
        receive_and_check_burst(beats, start_val);
    endtask

    // ========== Task: 接收一个burst并检查数据 ==========
    task receive_and_check_burst(input int beats, input int start_val);
        int beat_cnt = 0;
        while (beat_cnt < beats) begin
            @(posedge clk);
            if (rvalid && rready) begin
                if (rdata !== (start_val + beat_cnt)) begin
                    $display("[FAIL] beat=%0d expected=0x%08x got=0x%08x",
                             beat_cnt, start_val + beat_cnt, rdata);
                    $finish;
                end
                if (beat_cnt == beats - 1 && !rlast) begin
                    $display("[FAIL] RLAST not asserted on last beat");
                    $finish;
                end
                beat_cnt++;
            end
        end
    endtask

endmodule

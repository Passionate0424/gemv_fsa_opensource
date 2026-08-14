`timescale 1ns / 1ps

// 模块级TB：验证FPAccUnit_pipe的exp2模式输出
// Filelist: scripts/exp2_unit_filelist.f
// 运行: run_vcs_remote.ps1 -Top tb_exp2_unit -Filelist scripts/exp2_unit_filelist.f
module tb_exp2_unit;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    // FPAccUnit_pipe接口（RawFloat格式）
    reg         io_in_valid;
    reg         io_in_cmd;       // 1=exp2模式
    reg         io_in_a_sign;
    reg  [7:0]  io_in_a_exp;
    reg  [22:0] io_in_a_mantissa;
    reg         io_in_b_sign;
    reg  [7:0]  io_in_b_exp;
    reg  [22:0] io_in_b_mantissa;
    reg         io_in_c_sign;
    reg  [7:0]  io_in_c_exp;
    reg  [22:0] io_in_c_mantissa;
    wire        io_out_valid;
    wire        io_out_accType_sign;
    wire [7:0]  io_out_accType_exp;
    wire [22:0] io_out_accType_mantissa;

    FPAccUnit_pipe dut (
        .clock(clk),
        .rst_n(rst_n),
        .io_in_valid(io_in_valid),
        .io_in_cmd(io_in_cmd),
        .io_in_a_sign(io_in_a_sign),
        .io_in_a_exp(io_in_a_exp),
        .io_in_a_mantissa(io_in_a_mantissa),
        .io_in_b_sign(io_in_b_sign),
        .io_in_b_exp(io_in_b_exp),
        .io_in_b_mantissa(io_in_b_mantissa),
        .io_in_c_sign(io_in_c_sign),
        .io_in_c_exp(io_in_c_exp),
        .io_in_c_mantissa(io_in_c_mantissa),
        .io_out_valid(io_out_valid),
        .io_out_accType_sign(io_out_accType_sign),
        .io_out_accType_exp(io_out_accType_exp),
        .io_out_accType_mantissa(io_out_accType_mantissa),
        .multiCycleIO_reciprocal_in_valid(1'b0),
        .multiCycleIO_reciprocal_out_valid()
    );

    // IEEE754 → RawFloat转换
    task automatic ieee_to_raw(input [31:0] ieee,
                               output reg sign, output reg [7:0] exp, output reg [22:0] man);
        sign = ieee[31];
        if (ieee[30:23] == 8'h00) begin
            // zero/subnormal
            exp = 8'h00;
            man = {1'b0, ieee[22:1]};
        end else if (ieee[30:23] == 8'hFF) begin
            // inf/nan
            exp = 8'hFF;
            man = {1'b1, ieee[21:0]};
        end else begin
            // 正规数：RawFloat exp = biased_exp - 127（有符号），mantissa含隐含1
            exp = ieee[30:23] - 8'd127;
            man = {1'b1, ieee[22:1]};  // 隐含1 + mantissa高22位
        end
    endtask

    // RawFloat → IEEE754转换
    function [31:0] raw_to_ieee(input sign, input [7:0] exp, input [22:0] man);
        reg [7:0] biased_exp;
        if (man == 0) begin
            raw_to_ieee = {sign, 31'h0};  // zero
        end else begin
            biased_exp = exp + 8'd127;
            if (biased_exp >= 8'd255) begin
                raw_to_ieee = {sign, 8'hFF, 23'h0};  // inf
            end else if (biased_exp == 0 || $signed({1'b0, exp}) < -126) begin
                raw_to_ieee = {sign, 31'h0};  // flush to zero
            end else begin
                raw_to_ieee = {sign, biased_exp, man[21:0]};  // 去掉隐含1
            end
        end
    endfunction

    // 测试数据：全量扫描
    integer fd_out;
    integer i;
    reg [31:0] test_inputs [0:31999];
    integer num_inputs;
    integer out_cnt;
    integer in_cnt;

    initial begin
        // 全量扫描：覆盖[-25, 0)区间，32000个点
        // 均匀采样fp32值
        for (i = 0; i < 8000; i = i + 1)
            test_inputs[i] = $shortrealtobits(shortreal'(-0.000125) * shortreal'(i + 1)); // (-1, 0)
        for (i = 8000; i < 16000; i = i + 1)
            test_inputs[i] = $shortrealtobits(shortreal'(-1.0) - shortreal'(0.0005) * shortreal'(i - 8000)); // (-5, -1)
        for (i = 16000; i < 24000; i = i + 1)
            test_inputs[i] = $shortrealtobits(shortreal'(-5.0) - shortreal'(0.001125) * shortreal'(i - 16000)); // (-14, -5)
        for (i = 24000; i < 32000; i = i + 1)
            test_inputs[i] = $shortrealtobits(shortreal'(-14.0) - shortreal'(0.001375) * shortreal'(i - 24000)); // (-25, -14)
        num_inputs = 32000;
    end

    initial begin
        fd_out = $fopen("exp2_hw_results.txt", "w");
        if (fd_out == 0) begin
            $display("[ERROR] Cannot open output file");
            $finish;
        end

        rst_n = 0;
        io_in_valid = 0;
        io_in_cmd = 0;
        io_in_a_sign = 0;
        io_in_a_exp = 0;
        io_in_a_mantissa = 0;
        io_in_b_sign = 0;
        io_in_b_exp = 0;
        io_in_b_mantissa = 0;
        io_in_c_sign = 0;
        io_in_c_exp = 0;
        io_in_c_mantissa = 0;

        #100;
        rst_n = 1;
        #20;

        out_cnt = 0;
        in_cnt = 0;

        // 逐个喂入（每拍一个）
        for (in_cnt = 0; in_cnt < num_inputs; in_cnt = in_cnt + 1) begin
            @(posedge clk);
            io_in_valid = 1;
            io_in_cmd = 1;  // exp2模式
            // 直接传IEEE754字段（模块内部自行加隐含1和去bias）
            io_in_a_sign = test_inputs[in_cnt][31];
            io_in_a_exp = test_inputs[in_cnt][30:23];
            io_in_a_mantissa = test_inputs[in_cnt][22:0];
            // b和c在exp2模式下由内部LUT覆盖
            io_in_b_sign = 0;
            io_in_b_exp = 0;
            io_in_b_mantissa = 0;
            io_in_c_sign = 0;
            io_in_c_exp = 0;
            io_in_c_mantissa = 0;
        end
        @(posedge clk);
        io_in_valid = 0;
        io_in_cmd = 0;

        // 等待所有输出flush
        repeat(30) @(posedge clk);

        $fclose(fd_out);
        $display("[TB] Done. %0d inputs, %0d outputs written", num_inputs, out_cnt);
        if (out_cnt != num_inputs)
            $display("[WARN] Output count mismatch!");
        $finish;
    end

    // 捕获输出
    always @(posedge clk) begin
        if (io_out_valid && rst_n) begin
            // 直接从IEEE754字段组装输出
            reg [31:0] out_ieee;
            out_ieee = {io_out_accType_sign, io_out_accType_exp, io_out_accType_mantissa};
            $fwrite(fd_out, "%08h %08h\n", test_inputs[out_cnt], out_ieee);
            out_cnt = out_cnt + 1;
        end
    end

endmodule

`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////
// tb_recip_unit
// Filelist: scripts/recip_unit_filelist.f
//
// DUT: rtl/fsa/RawFloat_Div.sv —— FSA归一化阶段用的迭代倒数器(1/b)。
//      恢复余数法，13次迭代每次出2位商，末位为sticky。
//
// 验证内容：把大量真实输入喂给DUT并把(输入, 输出)成对导出，用于离线校准
//      C位级模型 recip_bits()。这是照搬 tb_exp2_unit 的做法——那次靠32000组
//      真实输入输出对把exp2模型做到了100% bit-exact，而累加/除法环节此前
//      没有任何独立验证手段，只能靠读RTL推断编排，推错了反而比浮点近似更差。
//
// 输出文件 recip_hw_results.txt：每行 "输入IEEE  输出RawFloat(sign|exp|mant)"
//      输出按 {sign, exp[9:0], mantissa[25:0]} 拼成37位，用十六进制打印，
//      保留RawFloat原始形态，不在TB里做IEEE转换——转换属于FPAccUnit_pipe的
//      输出级，已在exp2那条链上验证过，此处要隔离的是迭代器本身。
//
// 注意：DUT的 reset 是高有效。
////////////////////////////////////////////////////////////////
module tb_recip_unit;

    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;

    reg         io_in_valid;
    reg         b_isZero, b_isInf, b_isNaN, b_sign;
    reg  [8:0]  b_exp;
    reg  [23:0] b_mantissa;

    wire        o_valid, o_isZero, o_isInf, o_isNaN, o_sign;
    wire [9:0]  o_exp;
    wire [25:0] o_mantissa;

    RawFloat_Div dut (
        .clock                 (clk),
        .reset                 (reset),
        .io_in_valid           (io_in_valid),
        .io_in_bits_b_isZero   (b_isZero),
        .io_in_bits_b_isInf    (b_isInf),
        .io_in_bits_b_isNaN    (b_isNaN),
        .io_in_bits_b_sign     (b_sign),
        .io_in_bits_b_exp      (b_exp),
        .io_in_bits_b_mantissa (b_mantissa),
        .io_out_valid          (o_valid),
        .io_out_bits_isZero    (o_isZero),
        .io_out_bits_isInf     (o_isInf),
        .io_out_bits_isNaN     (o_isNaN),
        .io_out_bits_sign      (o_sign),
        .io_out_bits_exp       (o_exp),
        .io_out_bits_mantissa  (o_mantissa)
    );

    integer fd;
    integer i;
    reg [31:0] test_in;
    reg [36:0] out_raw;

    // IEEE754 -> RawFloat 分解
    task automatic drive_one(input [31:0] ieee);
        begin
            b_sign     = ieee[31];
            b_exp      = {1'b0, ieee[30:23]} - 9'd127;
            b_mantissa = {1'b1, ieee[22:0]};
            b_isZero   = (ieee[30:23] == 8'h00) && (ieee[22:0] == 23'h0);
            b_isInf    = (ieee[30:23] == 8'hFF) && (ieee[22:0] == 23'h0);
            b_isNaN    = (ieee[30:23] == 8'hFF) && (ieee[22:0] != 23'h0);
            @(negedge clk);
            io_in_valid = 1;
            @(negedge clk);
            io_in_valid = 0;
            // 等迭代完成（13次迭代，留足余量）
            wait (o_valid);
            @(posedge clk);
            out_raw = {o_sign, o_exp, o_mantissa};
            $fwrite(fd, "%08h %010h\n", ieee, out_raw);
            // 复位状态机准备下一次
            @(negedge clk);
            reset = 1;
            @(negedge clk);
            reset = 0;
        end
    endtask

    // 覆盖 softmax 归一化里 l 的实际取值范围：l 是若干 exp2 结果之和，
    // 恒为正，量级从接近 1（单行 tile）到上千（长序列多 tile）
    real rv;
    initial begin
        fd = $fopen("recip_hw_results.txt", "w");
        io_in_valid = 0;
        b_isZero = 0; b_isInf = 0; b_isNaN = 0; b_sign = 0;
        b_exp = 0; b_mantissa = 0;
        repeat (4) @(negedge clk);
        reset = 0;
        @(negedge clk);

        // 1) 稠密扫描 [1, 2)：尾数全覆盖，指数固定，暴露迭代器本身的精度
        for (i = 0; i < 2000; i = i + 1) begin
            test_in = {1'b0, 8'd127, i[22:0] * 23'd4194};   // frac 均匀铺开
            drive_one(test_in);
        end

        // 2) 跨指数扫描：2^-4 .. 2^12，覆盖 l 的真实量级
        for (i = 0; i < 2000; i = i + 1) begin
            test_in = {1'b0, 8'd123 + i[3:0], (i * 32'd7919) % 23'h7FFFFF};
            drive_one(test_in);
        end

        // 3) 随机
        for (i = 0; i < 2000; i = i + 1) begin
            rv = 0.5 + 2000.0 * (($urandom % 100000) / 100000.0);
            test_in = $shortrealtobits(rv);
            drive_one(test_in);
        end

        $fclose(fd);
        $display("[TB] Done. %0d vectors written to recip_hw_results.txt", 6000);
        $finish;
    end

endmodule

`timescale 1ns / 1ps

// generalAdder单元测试：对比原版和双路径版本（bit-exact）
module tb_general_adder;

  reg [31:0] a, b;
  wire [31:0] out_orig;  // 原版
  wire [31:0] out_dual;  // 双路径版本

  // 原版（golden）
  generalAdder_orig u_orig (.a(a), .b(b), .out(out_orig));
  // 双路径版本（DUT）
  generalAdder u_dut (.a(a), .b(b), .out(out_dual));

  integer errors;

  task test_close_path_diff1;
    reg [7:0] exp_a, exp_b;
    reg [22:0] man_a, man_b;
    integer j;
    begin
      $display("[TEST] Close path diff==1 opposite signs (a>b)...");
      for (j = 0; j < 50000; j = j + 1) begin
        exp_a = $urandom_range(2, 253);
        exp_b = exp_a - 1;
        man_a = $urandom;
        man_b = $urandom;
        a = {1'b0, exp_a, man_a};
        b = {1'b1, exp_b, man_b};
        #1;
        if (out_dual !== out_orig) begin
          $display("[MISMATCH] a=0x%08h b=0x%08h DUAL=0x%08h ORIG=0x%08h (diff=1,a>b,opp)",
            a, b, out_dual, out_orig);
          errors = errors + 1;
          if (errors > 10) return;
        end
      end
      $display("[TEST] Close path diff==1 opposite signs (b>a)...");
      for (j = 0; j < 50000; j = j + 1) begin
        exp_b = $urandom_range(2, 253);
        exp_a = exp_b - 1;
        man_a = $urandom;
        man_b = $urandom;
        a = {1'b0, exp_a, man_a};
        b = {1'b1, exp_b, man_b};
        #1;
        if (out_dual !== out_orig) begin
          $display("[MISMATCH] a=0x%08h b=0x%08h DUAL=0x%08h ORIG=0x%08h (diff=1,b>a,opp)",
            a, b, out_dual, out_orig);
          errors = errors + 1;
          if (errors > 10) return;
        end
      end
      $display("[TEST] Close path diff==0 opposite signs...");
      for (j = 0; j < 50000; j = j + 1) begin
        exp_a = $urandom_range(2, 253);
        man_a = $urandom;
        man_b = $urandom;
        a = {1'b0, exp_a, man_a};
        b = {1'b1, exp_a, man_b};
        #1;
        if (out_dual !== out_orig) begin
          $display("[MISMATCH] a=0x%08h b=0x%08h DUAL=0x%08h ORIG=0x%08h (diff=0,opp)",
            a, b, out_dual, out_orig);
          errors = errors + 1;
          if (errors > 10) return;
        end
      end
      $display("[TEST] Close path diff<=1 same signs...");
      for (j = 0; j < 50000; j = j + 1) begin
        exp_a = $urandom_range(2, 253);
        exp_b = exp_a - $urandom_range(0, 1);
        man_a = $urandom;
        man_b = $urandom;
        a = {1'b0, exp_a, man_a};
        b = {1'b0, exp_b, man_b};
        #1;
        if (out_dual !== out_orig) begin
          $display("[MISMATCH] a=0x%08h b=0x%08h DUAL=0x%08h ORIG=0x%08h (diff<=1,same)",
            a, b, out_dual, out_orig);
          errors = errors + 1;
          if (errors > 10) return;
        end
      end
    end
  endtask

  task test_far_path;
    integer j;
    begin
      $display("[TEST] Far path (diff>1) random...");
      for (j = 0; j < 100000; j = j + 1) begin
        a = $urandom;
        b = $urandom;
        if (a[30:23] == 8'hFF || a[30:23] == 8'h00) a[30:23] = 8'h7F;
        if (b[30:23] == 8'hFF || b[30:23] == 8'h00) b[30:23] = 8'h7F;
        // 确保diff > 1
        if (a[30:23] > b[30:23] && (a[30:23] - b[30:23]) <= 1) a[30:23] = a[30:23] + 2;
        if (b[30:23] > a[30:23] && (b[30:23] - a[30:23]) <= 1) b[30:23] = b[30:23] + 2;
        #1;
        if (out_dual !== out_orig) begin
          $display("[MISMATCH] a=0x%08h b=0x%08h DUAL=0x%08h ORIG=0x%08h (far)",
            a, b, out_dual, out_orig);
          errors = errors + 1;
          if (errors > 10) return;
        end
      end
    end
  endtask

  task test_random;
    integer j;
    begin
      $display("[TEST] Full random (200000 cases)...");
      for (j = 0; j < 200000; j = j + 1) begin
        a = $urandom;
        b = $urandom;
        if (a[30:23] == 8'hFF || a[30:23] == 8'h00) a[30:23] = 8'h7F;
        if (b[30:23] == 8'hFF || b[30:23] == 8'h00) b[30:23] = 8'h7F;
        #1;
        if (out_dual !== out_orig) begin
          $display("[MISMATCH] a=0x%08h b=0x%08h DUAL=0x%08h ORIG=0x%08h (random)",
            a, b, out_dual, out_orig);
          errors = errors + 1;
          if (errors > 10) return;
        end
      end
    end
  endtask

  initial begin
    errors = 0;
    test_close_path_diff1;
    test_far_path;
    test_random;
    if (errors == 0)
      $display("[PASS] All generalAdder tests passed (450000 cases)");
    else
      $display("[FAIL] %0d mismatches found", errors);
    $finish;
  end

endmodule

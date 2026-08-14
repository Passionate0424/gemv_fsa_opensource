`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////
// FP32 Adder 

// https://github.com/danshanley/FPU/blob/master/fpu.v

// Format: 1-bit signed, 8-bit exponents, 23-bit fractions

// NOTE: MORE VERIFICATION NEEDED
/////////////////////////////////////////////////////////////

module fpadd_seq(clk, rst_n, A, B, O);

  input [31:0] A, B;
  input clk;
  input rst_n;
  output reg [31:0] O;

  wire a_sign;
  wire b_sign;
  wire [7:0] a_exponent;
  wire [7:0] b_exponent; 
  wire [23:0] a_mantissa; // plus one bit
  wire [23:0] b_mantissa; // plus one bit 
             
  reg o_sign;
  reg [7:0] o_exponent;
  reg [24:0] o_mantissa;  // plus two bits
	
  wire [31:0] adder_a_in;
  wire [31:0] adder_b_in;
  wire [31:0] adder_out;
                   

  assign a_sign = A[31];
  assign a_exponent[7:0] = A[30:23];
  assign a_mantissa[23:0] = {1'b1, A[22:0]};
  assign b_sign = B[31];
  assign b_exponent[7:0] = B[30:23];
  assign b_mantissa[23:0] = {1'b1, B[22:0]};

  generalAdder gAdder (
    .a(adder_a_in),
    .b(adder_b_in),
    .out(adder_out)
  );

  assign adder_a_in = A;
  assign adder_b_in = B;
  
  //covers corner cases and uses general adder logic
  always @ ( posedge clk ) begin
	if (rst_n == 1'b0) begin
		O = 32'd0;
	end else begin
		//If a is NaN or b is zero return a
		if ((a_exponent == 255 && a_mantissa[22:0] != 0) || (b_exponent == 0) && (b_mantissa[22:0] == 0)) begin
			o_sign = a_sign;
			o_exponent = a_exponent;
			o_mantissa = a_mantissa;
			O = {o_sign, o_exponent, o_mantissa[22:0]};
		//If b is NaN or a is zero return b
		end else if ((b_exponent == 255 && b_mantissa[22:0] != 0) || (a_exponent == 0) && (a_mantissa[22:0] == 0)) begin
			o_sign = b_sign;
			o_exponent = b_exponent;
			o_mantissa = b_mantissa;
			O = {o_sign, o_exponent, o_mantissa[22:0]};
		//if a and b is inf return inf
		end else if ((a_exponent == 255) || (b_exponent == 255)) begin
			o_sign = a_sign ^ b_sign;
			o_exponent = 255;
			o_mantissa = 0;
			O = {o_sign, o_exponent, o_mantissa[22:0]};
		end else begin // Passed all corner cases
			//adder_a_in = A;
			//adder_b_in = B;
			o_sign = adder_out[31];
			o_exponent = adder_out[30:23];
			o_mantissa = adder_out[22:0];
			O = {o_sign, o_exponent, o_mantissa[22:0]};
		end
	end
  end

  initial begin
    O = 32'd0;
  end

endmodule

//general adder - 双路径FP32加法器（与原版bit-exact）
// Far path (|exp_diff|>1): 无需LZD
// Close path (|exp_diff|<=1): 完整LZD但对齐只需0或1位
module generalAdder(a, b, out);
  input [31:0] a, b;
  output [31:0] out;
  wire [31:0] out;

  reg a_sign, b_sign;
  reg [7:0] a_exponent, b_exponent;
  reg [23:0] a_mantissa, b_mantissa;
  reg [7:0] diff;

  // Close path信号
  reg        close_sign;
  reg [7:0]  close_exp;
  reg [24:0] close_man;
  reg [7:0]  close_i_e;
  reg [24:0] close_i_m;
  wire [7:0]  close_o_e;
  wire [24:0] close_o_m;
  reg [23:0] close_tmp;

  // Far path信号
  reg        far_sign;
  reg [7:0]  far_exp;
  reg [24:0] far_man;
  reg [23:0] far_tmp;

  // 输出
  reg        o_sign;
  reg [7:0]  o_exponent;
  reg [24:0] o_mantissa;

  // Close path LZD
  addition_normaliser norm1(.in_e(close_i_e), .in_m(close_i_m), .out_e(close_o_e), .out_m(close_o_m));

  assign out[31] = o_sign;
  assign out[30:23] = o_exponent;
  assign out[22:0] = o_mantissa[22:0];

  always @(*) begin
    o_sign = 1'b0; o_exponent = 8'd0; o_mantissa = 25'd0;
    close_sign = 1'b0; close_exp = 8'd0; close_man = 25'd0;
    close_i_e = 8'd0; close_i_m = 25'd0; close_tmp = 24'd0;
    far_sign = 1'b0; far_exp = 8'd0; far_man = 25'd0; far_tmp = 24'd0;
    diff = 8'd0;

    // 输入解析
    a_sign = a[31];
    if (a[30:23] == 0) begin a_exponent = 8'd1; a_mantissa = {1'b0, a[22:0]}; end
    else begin a_exponent = a[30:23]; a_mantissa = {1'b1, a[22:0]}; end
    b_sign = b[31];
    if (b[30:23] == 0) begin b_exponent = 8'd1; b_mantissa = {1'b0, b[22:0]}; end
    else begin b_exponent = b[30:23]; b_mantissa = {1'b1, b[22:0]}; end

    // 指数差
    if (a_exponent >= b_exponent) diff = a_exponent - b_exponent;
    else diff = b_exponent - a_exponent;

    // ============ Close path (diff <= 1) ============
    // 与原版逻辑完全一致
    if (a_exponent == b_exponent) begin
      close_exp = a_exponent;
      if (a_sign == b_sign) begin
        close_man = {1'b0, a_mantissa} + {1'b0, b_mantissa};
        close_sign = a_sign;
      end else begin
        if (a_mantissa > b_mantissa) begin
          close_man = a_mantissa - b_mantissa; close_sign = a_sign;
        end else begin
          close_man = b_mantissa - a_mantissa; close_sign = b_sign;
        end
      end
    end else if (a_exponent > b_exponent) begin
      // diff==1, a bigger
      close_exp = a_exponent; close_sign = a_sign;
      close_tmp = b_mantissa >> 1;
      if (a_sign == b_sign) close_man = a_mantissa + close_tmp;
      else close_man = a_mantissa - close_tmp;
    end else begin
      // diff==1, b bigger
      close_exp = b_exponent; close_sign = b_sign;
      close_tmp = a_mantissa >> 1;
      if (a_sign == b_sign) close_man = b_mantissa + close_tmp;
      else close_man = b_mantissa - close_tmp;
    end
    // Close path归一化（与原版一致）
    if (close_man == 25'd0) begin
      close_sign = 1'b0; close_exp = 8'd0;
    end else if (close_man[24]) begin
      close_exp = close_exp + 1; close_man = close_man >> 1;
    end else if (!close_man[23] && close_exp != 0) begin
      close_i_e = close_exp; close_i_m = close_man;
      if (close_o_e == 0 || close_o_e > close_i_e) begin
        close_exp = 8'd0; close_man = 25'd0;
      end else begin
        close_exp = close_o_e; close_man = close_o_m;
      end
    end

    // ============ Far path (diff > 1) ============
    // 与原版逻辑一致但不调用LZD（diff>1时结果一定已归一化或溢出）
    if (a_exponent > b_exponent) begin
      far_exp = a_exponent; far_sign = a_sign;
      far_tmp = b_mantissa >> diff;
      if (a_sign == b_sign) far_man = a_mantissa + far_tmp;
      else far_man = a_mantissa - far_tmp;
    end else begin
      far_exp = b_exponent; far_sign = b_sign;
      far_tmp = a_mantissa >> diff;
      if (a_sign == b_sign) far_man = b_mantissa + far_tmp;
      else far_man = b_mantissa - far_tmp;
    end
    // Far path归一化：零、溢出、或最多1-bit左移（diff>=2时不可能有更多前导零）
    if (far_man == 25'd0) begin
      far_sign = 1'b0; far_exp = 8'd0;
    end else if (far_man[24]) begin
      far_exp = far_exp + 1; far_man = far_man >> 1;
    end else if (!far_man[23] && far_exp != 0) begin
      far_exp = far_exp - 1; far_man = far_man << 1;
    end

    // ============ 输出选择 ============
    if (diff <= 8'd1) begin
      o_sign = close_sign; o_exponent = close_exp; o_mantissa = close_man;
    end else begin
      o_sign = far_sign; o_exponent = far_exp; o_mantissa = far_man;
    end
  end
endmodule 

module addition_normaliser(in_e, in_m, out_e, out_m);
  input [7:0] in_e;
  input [24:0] in_m;
  output [7:0] out_e;
  output [24:0] out_m;
  
  wire [7:0] in_e;
  wire [24:0] in_m;
  reg [7:0] out_e;
  reg [24:0] out_m;
  
  
  always @ ( * ) begin
    if (in_m[23:3] == 21'b000000000000000000001) begin
	  out_e = in_e - 20;
	  out_m = in_m << 20;
	end else if (in_m[23:4] == 20'b00000000000000000001) begin
	  out_e = in_e - 19;
	  out_m = in_m << 19;
	end else if (in_m[23:5] == 19'b0000000000000000001) begin
	  out_e = in_e - 18;
	  out_m = in_m << 18;
	end else if (in_m[23:6] == 18'b000000000000000001) begin
	  out_e = in_e - 17;
	  out_m = in_m << 17;
	end else if (in_m[23:7] == 17'b00000000000000001) begin
	  out_e = in_e - 16;
	  out_m = in_m << 16;
	end else if (in_m[23:8] == 16'b0000000000000001) begin
	  out_e = in_e - 15;
	  out_m = in_m << 15;
	end else if (in_m[23:9] == 15'b000000000000001) begin
	  out_e = in_e - 14;
	  out_m = in_m << 14;
	end else if (in_m[23:10] == 14'b00000000000001) begin
	  out_e = in_e - 13;
	  out_m = in_m << 13;
	end else if (in_m[23:11] == 13'b0000000000001) begin
	  out_e = in_e - 12;
	  out_m = in_m << 12;
	end else if (in_m[23:12] == 12'b000000000001) begin
	  out_e = in_e - 11;
	  out_m = in_m << 11;
	end else if (in_m[23:13] == 11'b00000000001) begin
	  out_e = in_e - 10;
      out_m = in_m << 10;
	end else if (in_m[23:14] == 10'b0000000001) begin
	  out_e = in_e - 9;
	  out_m = in_m << 9;
	end else if (in_m[23:15] == 9'b000000001) begin
	  out_e = in_e - 8;
	  out_m = in_m << 8;
	end else if (in_m[23:16] == 8'b00000001) begin
	  out_e = in_e - 7;
	  out_m = in_m << 7;
	end else if (in_m[23:17] == 7'b0000001) begin
	  out_e = in_e - 6;
      out_m = in_m << 6;
	end else if (in_m[23:18] == 6'b000001) begin
	  out_e = in_e - 5;
	  out_m = in_m << 5;
	end else if (in_m[23:19] == 5'b00001) begin
	  out_e = in_e - 4;
	  out_m = in_m << 4;
	end else if (in_m[23:20] == 4'b0001) begin
	  out_e = in_e - 3;
	  out_m = in_m << 3;
	end else if (in_m[23:21] == 3'b001) begin
	  out_e = in_e - 2;
	  out_m = in_m << 2;
	end else if (in_m[23:22] == 2'b01) begin
	  out_e = in_e - 1;
	  out_m = in_m << 1;
	end else begin
	  out_e = in_e;
	  out_m = in_m;
	end
  end
endmodule

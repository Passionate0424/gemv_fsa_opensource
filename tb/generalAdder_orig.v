// 原版generalAdder（作为golden参考）
module generalAdder_orig(a, b, out);
  input [31:0] a, b;
  output [31:0] out;
  wire [31:0] out;
  reg a_sign, b_sign;
  reg [7:0] a_exponent, b_exponent;
  reg [23:0] a_mantissa, b_mantissa;
  reg o_sign;
  reg [7:0] o_exponent;
  reg [24:0] o_mantissa;
  reg [7:0] diff;
  reg [23:0] tmp_mantissa;
  reg [7:0] i_e;
  reg [24:0] i_m;
  wire [7:0] o_e;
  wire [24:0] o_m;

  addition_normaliser norm1(.in_e(i_e), .in_m(i_m), .out_e(o_e), .out_m(o_m));

  assign out[31] = o_sign;
  assign out[30:23] = o_exponent;
  assign out[22:0] = o_mantissa[22:0];

  always @(*) begin
    o_sign = 1'b0; o_exponent = 8'd0; o_mantissa = 25'd0;
    diff = 8'd0; tmp_mantissa = 24'd0; i_e = 8'd0; i_m = 25'd0;
    a_sign = a[31];
    if (a[30:23] == 0) begin a_exponent = 8'd1; a_mantissa = {1'b0, a[22:0]}; end
    else begin a_exponent = a[30:23]; a_mantissa = {1'b1, a[22:0]}; end
    b_sign = b[31];
    if (b[30:23] == 0) begin b_exponent = 8'd1; b_mantissa = {1'b0, b[22:0]}; end
    else begin b_exponent = b[30:23]; b_mantissa = {1'b1, b[22:0]}; end

    if (a_exponent == b_exponent) begin
      o_exponent = a_exponent;
      if (a_sign == b_sign) begin
        o_mantissa = {1'b0, a_mantissa} + {1'b0, b_mantissa};
        o_sign = a_sign;
      end else begin
        if (a_mantissa > b_mantissa) begin
          o_mantissa = a_mantissa - b_mantissa; o_sign = a_sign;
        end else begin
          o_mantissa = b_mantissa - a_mantissa; o_sign = b_sign;
        end
      end
    end else begin
      if (a_exponent > b_exponent) begin
        o_exponent = a_exponent; o_sign = a_sign;
        diff = a_exponent - b_exponent;
        tmp_mantissa = b_mantissa >> diff;
        if (a_sign == b_sign) o_mantissa = a_mantissa + tmp_mantissa;
        else o_mantissa = a_mantissa - tmp_mantissa;
      end else begin
        o_exponent = b_exponent; o_sign = b_sign;
        diff = b_exponent - a_exponent;
        tmp_mantissa = a_mantissa >> diff;
        if (a_sign == b_sign) o_mantissa = b_mantissa + tmp_mantissa;
        else o_mantissa = b_mantissa - tmp_mantissa;
      end
    end

    if (o_mantissa == 25'd0) begin
      o_sign = 1'b0; o_exponent = 8'd0; o_mantissa = 25'd0;
    end else if (o_mantissa[24]) begin
      o_exponent = o_exponent + 1; o_mantissa = o_mantissa >> 1;
    end else if (!o_mantissa[23] && o_exponent != 0) begin
      i_e = o_exponent; i_m = o_mantissa;
      if (o_e == 0 || o_e > i_e) begin o_exponent = 8'd0; o_mantissa = 25'd0; end
      else begin o_exponent = o_e; o_mantissa = o_m; end
    end
  end
endmodule

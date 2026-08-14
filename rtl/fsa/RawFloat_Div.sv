
`ifndef RANDOMIZE
  `ifdef RANDOMIZE_REG_INIT
    `define RANDOMIZE
  `endif
`endif
`ifndef SYNTHESIS
  `ifndef ENABLE_INITIAL_REG_
    `define ENABLE_INITIAL_REG_
  `endif
`endif

`ifndef RANDOM
  `define RANDOM $random
`endif

`ifndef INIT_RANDOM
  `define INIT_RANDOM
`endif

`ifndef RANDOMIZE_DELAY
  `define RANDOMIZE_DELAY 0.002
`endif

`ifndef INIT_RANDOM_PROLOG_
  `ifdef RANDOMIZE
    `ifdef VERILATOR
      `define INIT_RANDOM_PROLOG_ `INIT_RANDOM
    `else
      `define INIT_RANDOM_PROLOG_ `INIT_RANDOM #`RANDOMIZE_DELAY begin end
    `endif
  `else
    `define INIT_RANDOM_PROLOG_
  `endif
`endif
module RawFloat_Div(
  input         clock,
                reset,
                io_in_valid,
                io_in_bits_b_isZero,
                io_in_bits_b_isInf,
                io_in_bits_b_isNaN,
                io_in_bits_b_sign,
  input  [8:0]  io_in_bits_b_exp,
  input  [23:0] io_in_bits_b_mantissa,
  output        io_out_valid,
                io_out_bits_isZero,
                io_out_bits_isInf,
                io_out_bits_isNaN,
                io_out_bits_sign,
  output [9:0]  io_out_bits_exp,
  output [25:0] io_out_bits_mantissa
);

  reg  [25:0] quotient;
  reg  [24:0] reminder;
  reg  [1:0]  state;
  reg  [3:0]  iterCount;
  wire [25:0] _adjustedQuotient_T_2 = quotient[25] ? quotient : {quotient[24:0], 1'h0};
  always @(posedge clock) begin
    automatic logic _GEN;
    _GEN = state == 2'h1;
    if (state == 2'h0) begin
      if (io_in_valid) begin
        quotient <= 26'h0;
        reminder <= 25'h800000;
      end
    end
    else if (_GEN) begin
      automatic logic [24:0] _GEN_0 = {1'h0, io_in_bits_b_mantissa};
      automatic logic        q;
      automatic logic [23:0] _remNext_T_2;
      automatic logic        q_1;
      automatic logic [23:0] _GEN_1;
      q = reminder >= _GEN_0;
      _remNext_T_2 = q ? reminder[23:0] - io_in_bits_b_mantissa : reminder[23:0];
      q_1 = {_remNext_T_2, 1'h0} >= _GEN_0;
      _GEN_1 = {_remNext_T_2[22:0], 1'h0};
      quotient <= {quotient[23:0], q, q_1};
      reminder <= {q_1 ? _GEN_1 - io_in_bits_b_mantissa : _GEN_1, 1'h0};
    end
    if (reset) begin
      state <= 2'h0;
      iterCount <= 4'h0;
    end
    else begin
      automatic logic            wrap_wrap;
      automatic logic [3:0][1:0] _GEN_2;
      wrap_wrap = iterCount == 4'hC;
      _GEN_2 =
        {{state},
         {2'h0},
         {_GEN & wrap_wrap ? 2'h2 : state},
         {io_in_valid ? 2'h1 : state}};
      state <= _GEN_2[state];
      if (_GEN)
        iterCount <= wrap_wrap ? 4'h0 : iterCount + 4'h1;
    end
  end
  `ifdef ENABLE_INITIAL_REG_
    `ifdef FIRRTL_BEFORE_INITIAL
      `FIRRTL_BEFORE_INITIAL
    `endif
    initial begin
      automatic logic [31:0] _RANDOM[0:1];
      `ifdef INIT_RANDOM_PROLOG_
        `INIT_RANDOM_PROLOG_
      `endif
      `ifdef RANDOMIZE_REG_INIT
        for (logic [1:0] i = 2'h0; i < 2'h2; i += 2'h1) begin
          _RANDOM[i[0]] = `RANDOM;
        end
        quotient = _RANDOM[1'h0][25:0];
        reminder = {_RANDOM[1'h0][31:26], _RANDOM[1'h1][18:0]};
        state = _RANDOM[1'h1][20:19];
        iterCount = _RANDOM[1'h1][24:21];
      `endif
    end
    `ifdef FIRRTL_AFTER_INITIAL
      `FIRRTL_AFTER_INITIAL
    `endif
  `endif
  assign io_out_valid = state == 2'h2;
  assign io_out_bits_isZero = io_in_bits_b_isInf;
  assign io_out_bits_isInf = io_in_bits_b_isZero;
  assign io_out_bits_isNaN = io_in_bits_b_isNaN;
  assign io_out_bits_sign = io_in_bits_b_sign;
  assign io_out_bits_exp =
    10'h0 - {io_in_bits_b_exp[8], io_in_bits_b_exp} - {9'h0, ~(quotient[25])};
  assign io_out_bits_mantissa =
    {_adjustedQuotient_T_2[25:1], |{_adjustedQuotient_T_2[0], |reminder}};
endmodule


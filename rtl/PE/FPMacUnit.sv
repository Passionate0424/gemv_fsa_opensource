`timescale 1ns / 1ps

module FPMacUnit_pipe(
  input         clock,
  input         rst_n,
  input         io_in_valid,
  input         io_in_a_sign,
  input  [7:0]  io_in_a_exp,
  input  [22:0] io_in_a_mantissa,
  input         io_in_b_sign,
  input  [7:0]  io_in_b_exp,
  input  [22:0] io_in_b_mantissa,
  input         io_in_c_sign,
  input  [7:0]  io_in_c_exp,
  input  [22:0] io_in_c_mantissa,
  input         io_in_cmd,
  // 超前计算端口
  input         bypass_s1,
  input         use_pre_add,
  input  [31:0] pre_add_in,
  input  [31:0] init_val,
  input         load_init,
  output [31:0] mul_out_port,
  // 输出（统一精度，fp32→fp32无需区分accType/elemType）
  output        io_out_valid,
  output        io_out_sign,
  output [7:0]  io_out_exp,
  output [22:0] io_out_mantissa,
  output        io_out_exp2
);

  wire        mulAddExp2_io_out_valid;
  wire        mulAddExp2_io_out_isZero;
  wire        mulAddExp2_io_out_isInf;
  wire        mulAddExp2_io_out_isNaN;
  wire        mulAddExp2_io_out_sign;
  wire [10:0] mulAddExp2_io_out_exp;
  wire [25:0] mulAddExp2_io_out_mantissa;
  wire [2:0]  mulAddExp2_io_exp2_frac_msb;

  // valid/cmd延迟链（OS模式4级，FSA模式3级）
  // **控制链必须落在带复位的触发器上**：SRL16E/SRLC32E 没有复位端，被推成 SRL 的位
  // 上电后是随机值，下面 `if(!rst_n)` 那段对它们静默无效。valid/cmd 都直接参与
  // 下游的写使能与命令译码，随机初值会造成一次伪写。数据链可以进 SRL，这两条不行。
  (* srl_style = "register" *)
  reg         valid_pipe [0:3];
  (* srl_style = "register" *)
  reg         cmd_pipe [0:3];
  reg [2:0]   c_exp_msb_pipe;

  RawFloat_MulAddExp2_pipe mulAddExp2 (
    .clock           (clock),
    .rst_n           (rst_n),
    .io_in_valid     (io_in_valid),
    .io_in_exp2      (io_in_cmd),
    .io_in_a_isZero  (io_in_a_exp == 8'h0),
    .io_in_a_isInf   ((&io_in_a_exp) & ~(|io_in_a_mantissa)),
    .io_in_a_isNaN   ((&io_in_a_exp) & (|io_in_a_mantissa)),
    .io_in_a_sign    (io_in_a_sign),
    .io_in_a_exp     ({1'h0, io_in_a_exp} - 9'h7F),
    .io_in_a_mantissa({1'h1, io_in_a_mantissa}),
    .io_in_b_isZero  (io_in_b_exp == 8'h0),
    .io_in_b_isInf   ((&io_in_b_exp) & ~(|io_in_b_mantissa)),
    .io_in_b_isNaN   ((&io_in_b_exp) & (|io_in_b_mantissa)),
    .io_in_b_sign    (io_in_b_sign),
    .io_in_b_exp     ({1'h0, io_in_b_exp} - 9'h7F),
    .io_in_b_mantissa({1'h1, io_in_b_mantissa}),
    .io_in_c_isZero  (~io_in_cmd & (io_in_c_exp == 8'h0)),
    .io_in_c_isInf   (~io_in_cmd & (&io_in_c_exp) & ~(|io_in_c_mantissa)),
    .io_in_c_isNaN   (~io_in_cmd & (&io_in_c_exp) & (|io_in_c_mantissa)),
    .io_in_c_sign    (io_in_c_sign),
    .io_in_c_exp
      (io_in_cmd ? {8'h3F, io_in_c_exp[0]} - 9'h7F : {1'h0, io_in_c_exp} - 9'h7F),
    .io_in_c_mantissa({1'h1, io_in_c_mantissa}),
    // 超前计算透传
    .bypass_s1       (bypass_s1),
    .use_pre_add     (use_pre_add),
    .pre_add_in      (pre_add_in),
    .init_val        (init_val),
    .load_init       (load_init),
    .mul_out_port    (mul_out_port),
    // 输出
    .io_out_valid    (mulAddExp2_io_out_valid),
    .io_out_isZero   (mulAddExp2_io_out_isZero),
    .io_out_isInf    (mulAddExp2_io_out_isInf),
    .io_out_isNaN    (mulAddExp2_io_out_isNaN),
    .io_out_sign     (mulAddExp2_io_out_sign),
    .io_out_exp      (mulAddExp2_io_out_exp),
    .io_out_mantissa (mulAddExp2_io_out_mantissa),
    .io_exp2_frac_msb(mulAddExp2_io_exp2_frac_msb)
  );

  wire [23:0] roundedMantissa =
    {1'h0, mulAddExp2_io_out_mantissa[24:2]}
    + {23'h0,
       mulAddExp2_io_out_mantissa[1] & mulAddExp2_io_out_mantissa[0]
         | mulAddExp2_io_out_mantissa[1] & ~mulAddExp2_io_out_mantissa[0]
         & mulAddExp2_io_out_mantissa[2]};
  wire [11:0] s3_exp_12 =
    {mulAddExp2_io_out_exp[10], mulAddExp2_io_out_exp};
  wire [11:0] roundedExp =
    s3_exp_12 + {11'h0, roundedMantissa[23]};
  wire        out_overflow = $signed(roundedExp) > 12'sd127;
  wire        out_underflow = $signed(roundedExp) < -12'sd126;
  wire        out_isInf = mulAddExp2_io_out_isInf;
  wire        resExp_T = out_isInf | mulAddExp2_io_out_isNaN;
  wire        resMantissa_T = mulAddExp2_io_out_isZero | out_isInf;

  // 输出valid: FSA模式pipe[2], OS模式pipe[3]
  assign io_out_valid = bypass_s1 ? valid_pipe[2] : valid_pipe[3];
  assign io_out_sign = mulAddExp2_io_out_sign & ~mulAddExp2_io_out_isNaN;
  assign io_out_exp =
    resExp_T | out_overflow
      ? 8'hFF
      : mulAddExp2_io_out_isZero | out_underflow
          ? 8'h0
          : roundedExp[7:0] + 8'h7F;
  assign io_out_mantissa =
    mulAddExp2_io_out_isNaN
      ? 23'h400000
      : resMantissa_T | out_underflow | out_overflow
          ? 23'h0
          : roundedMantissa[22:0];

  // 段匹配：bypass=0时比较点从cmd_pipe[2]→cmd_pipe[3]延后1拍，
  // c_exp_msb需额外延迟1级，否则被下一trial的intercept覆盖导致错位
  reg [2:0] c_exp_msb_pipe_d;  // 额外1级延迟，供bypass=0使用
  wire [2:0] c_exp_msb_sel = bypass_s1 ? c_exp_msb_pipe : c_exp_msb_pipe_d;

  assign io_out_exp2 = bypass_s1
    ? (cmd_pipe[2] & (c_exp_msb_sel == mulAddExp2_io_exp2_frac_msb) & valid_pipe[2])
    : (cmd_pipe[3] & (c_exp_msb_sel == mulAddExp2_io_exp2_frac_msb) & valid_pipe[3]);

  integer i;
  always @(posedge clock) begin
    if (!rst_n) begin
      for (i = 0; i < 4; i = i + 1) begin
        valid_pipe[i] <= 1'b0;
        cmd_pipe[i] <= 1'b0;
      end
      c_exp_msb_pipe   <= 3'h0;
      c_exp_msb_pipe_d <= 3'h0;
    end else begin
      valid_pipe[0] <= io_in_valid;
      cmd_pipe[0] <= io_in_valid & io_in_cmd;
      c_exp_msb_pipe   <= io_in_c_exp[3:1];
      c_exp_msb_pipe_d <= c_exp_msb_pipe;  // 延迟1拍对齐cmd_pipe[3]
      for (i = 1; i < 4; i = i + 1) begin
        valid_pipe[i] <= valid_pipe[i-1];
        cmd_pipe[i] <= cmd_pipe[i-1];
      end
    end
  end

endmodule

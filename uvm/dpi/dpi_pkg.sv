// DPI-C Package
// 声明所有DPI-C导入函数，供UVM环境使用
package dpi_pkg;

  // FSA golden model（复用tb/dpi/e2e_golden.c）
  import "DPI-C" function void dpi_e2e_init(input int head_dim, input int seq_len, input int num_heads);
  import "DPI-C" function void dpi_e2e_set_q(input int head, input int idx, input int val);
  import "DPI-C" function void dpi_e2e_set_k(input int head, input int row, input int col, input int val);
  import "DPI-C" function void dpi_e2e_set_v(input int head, input int row, input int col, input int val);
  import "DPI-C" function void dpi_e2e_compute();
  import "DPI-C" function int  dpi_e2e_compare(input int head, input int idx, input int dut_val);
  import "DPI-C" function void dpi_e2e_report();

  // SiLU位级golden（复用tb/dpi/silu_dpi.c → fp_bitlevel.h的silu_bits）
  // 用它而不是SV的$exp：$exp给的是数学真值，与硬件的8段PWL近似天然差4.8e-4，
  // 只能做0.1%量级的宽松判定；位级模型可以做逐位判定，任何一位不同都是实现
  // 问题而非精度问题。dpi_silu_ref提供fp64参考，仅用于统计相对误差不做判定。
  import "DPI-C" function int dpi_silu_bits(input int x_bits);
  import "DPI-C" function int dpi_silu_ref (input int x_bits);

endpackage

// CB_top_v2 Sequence Package
package cb_top_seq_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import axi_slv_agent_pkg::*;
  import mem_model_pkg::*;
  import cb_top_env_pkg::*;
  import dpi_pkg::*;

  `include "cb_top_base_seq.sv"
  `include "csr_seq_lib.sv"
  `include "gemv_seq_lib.sv"
  `include "silu_seq_lib.sv"     // 依赖 gemv_seq_lib 的 gemv_base_seq，必须放它之后
  `include "prefetch_seq_lib.sv" // 同上，也建在 gemv_base_seq 之上
  `include "fsa_seq_lib.sv"
  `include "error_seq_lib.sv"
  `include "mid_op_reset_seq_lib.sv"
  `include "precise_fsm_reset_seq_lib.sv"
  `include "special_fp_seq_lib.sv"
  `include "perf_limit_seq_lib.sv"

endpackage

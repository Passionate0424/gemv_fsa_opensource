// CB_top_v2 环境Package
package cb_top_env_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import axi_slv_agent_pkg::*;
  import mem_model_pkg::*;
  import cb_ral_pkg::*;
  import cb_coverage_pkg::*;

  `include "cb_top_virtual_seqr.sv"
  `include "cb_top_env.sv"

endpackage

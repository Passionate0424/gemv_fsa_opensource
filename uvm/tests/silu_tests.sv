// SiLU融合测试
//
// 验证GEMV通路上的SiLU算子融合（CSR 0x0058 bit[0]=silu_en）。
// golden走DPI-C位级模型（tb/dpi/silu_dpi.c），已复现硬件的8段PWL行为，
// 所以判定阈值不必为近似误差放宽——残余误差只来自GEMV累加本身。

// ------------------------------------------------------------------
// Sanity：最基本的32×64单tile通路
// ------------------------------------------------------------------
class silu_sanity_test extends cb_top_base_test;

  `uvm_component_utils(silu_sanity_test)

  function new(string name = "silu_sanity_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    silu_sanity_seq seq = silu_sanity_seq::type_id::create("seq");
    `uvm_info("SILU_SANITY", "启动SiLU Sanity Test (32x64, silu_en=1)", UVM_MEDIUM)
    seq.start(env.vseqr);
  endtask

endclass

// ------------------------------------------------------------------
// Regression：定向覆盖 tiling 与数值边界
// ------------------------------------------------------------------
class silu_regression_test extends cb_top_base_test;

  `uvm_component_utils(silu_regression_test)

  function new(string name = "silu_regression_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    // 覆盖重点：
    //   rows 非32倍数 -> silu_num_elem 收窄，尾块 addr_total 不足8
    //   cols > 64     -> 多tile累加，SiLU只能在最后一个tile之后做一次
    //   data_range    -> 零附近/常规/接近饱和/深饱和四档
    int    case_rows [12] = '{32,  1,   7,  33,  63,  64,  32,  32,  48,  17,  96,  32};
    int    case_cols [12] = '{64, 64,  64,  64,  64,  64,  65, 128, 172, 100,  64,  32};
    int    case_seed [12] = '{42, 43,  44,  45,  46,  47,  48,  49,  50,  51,  52,  53};
    real   case_rng  [12] = '{2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 0.5, 8.0, 20.0};
    string case_name [12] = '{
      "TC_SiLU_Base32x64",   "TC_SiLU_SingleRow",   "TC_SiLU_Row7_尾块极小",
      "TC_SiLU_Row33_跨块",  "TC_SiLU_Row63_尾块满", "TC_SiLU_Row64_双块",
      "TC_SiLU_Col65_双tile", "TC_SiLU_Col128",      "TC_SiLU_Col172_三tile",
      "TC_SiLU_近零区0.5",    "TC_SiLU_近饱和8.0",    "TC_SiLU_深饱和20.0"
    };

    int total_errors = 0;

    `uvm_info("SILU_REG", "启动SiLU Regression Test (12 cases)", UVM_MEDIUM)

    for (int i = 0; i < 12; i++) begin
      silu_directed_seq seq = silu_directed_seq::type_id::create($sformatf("silu_seq_%0d", i));
      seq.rows       = case_rows[i];
      seq.cols       = case_cols[i];
      seq.seed       = case_seed[i];
      seq.data_range = case_rng[i];
      `uvm_info("SILU_REG", $sformatf("[%0d/12] %s: rows=%0d cols=%0d range=%.1f",
                i+1, case_name[i], seq.rows, seq.cols, seq.data_range), UVM_MEDIUM)
      seq.start(env.vseqr);
      total_errors += seq.error_count;
    end

    if (total_errors == 0)
      `uvm_info("SILU_REG", "SiLU Regression 全部通过", UVM_MEDIUM)
    else
      `uvm_error("SILU_REG", $sformatf("SiLU Regression 共 %0d 个错误", total_errors))
  endtask

endclass

// ------------------------------------------------------------------
// 旁路与粘连：最能暴露"SiLU改动污染原有通路"的两类场景
// ------------------------------------------------------------------
class silu_bypass_test extends cb_top_base_test;

  `uvm_component_utils(silu_bypass_test)

  function new(string name = "silu_bypass_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    silu_bypass_pair_seq  bp = silu_bypass_pair_seq::type_id::create("bp");
    silu_sticky_check_seq st = silu_sticky_check_seq::type_id::create("st");

    `uvm_info("SILU_BYPASS", "旁路对照：同数据 silu_en=0 / =1 各一趟", UVM_MEDIUM)
    bp.start(env.vseqr);

    `uvm_info("SILU_BYPASS", "粘连检查：先开后关，验证 silu_en 不残留", UVM_MEDIUM)
    st.start(env.vseqr);
  endtask

endclass

// ------------------------------------------------------------------
// Random：约束随机，rows/cols/seed/data_range 全随机
// ------------------------------------------------------------------
class silu_random_test extends cb_top_base_test;

  `uvm_component_utils(silu_random_test)

  int num_iterations = 20;

  function new(string name = "silu_random_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    int total_errors = 0;

    void'($value$plusargs("SILU_RAND_ITER=%d", num_iterations));
    `uvm_info("SILU_RAND", $sformatf("启动SiLU Random Test (%0d 轮)", num_iterations), UVM_MEDIUM)

    for (int i = 0; i < num_iterations; i++) begin
      silu_random_seq seq = silu_random_seq::type_id::create($sformatf("silu_rand_%0d", i));
      if (!seq.randomize())
        `uvm_fatal("SILU_RAND", "randomize 失败")
      `uvm_info("SILU_RAND", $sformatf("[%0d/%0d] rows=%0d cols=%0d seed=%0d range=%.1f",
                i+1, num_iterations, seq.rows, seq.cols, seq.seed, seq.data_range), UVM_MEDIUM)
      seq.start(env.vseqr);
      total_errors += seq.error_count;
    end

    if (total_errors == 0)
      `uvm_info("SILU_RAND", "SiLU Random 全部通过", UVM_MEDIUM)
    else
      `uvm_error("SILU_RAND", $sformatf("SiLU Random 共 %0d 个错误", total_errors))
  endtask

endclass

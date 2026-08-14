// GEMV Sanity Test
// 验证GEMV模式最基本的32×64单tile矩阵向量乘
class gemv_sanity_test extends cb_top_base_test;

  `uvm_component_utils(gemv_sanity_test)

  function new(string name = "gemv_sanity_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    gemv_sanity_seq seq = gemv_sanity_seq::type_id::create("seq");
    `uvm_info("GEMV_SANITY", "启动GEMV Sanity Test (32x64)", UVM_MEDIUM)
    seq.start(env.vseqr);
  endtask

endclass

// GEMV Regression Test
// 执行14个directed case覆盖所有tiling边界
class gemv_regression_test extends cb_top_base_test;

  `uvm_component_utils(gemv_regression_test)

  function new(string name = "gemv_regression_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    // 14个directed case参数
    int case_rows [14] = '{32, 32, 64, 32, 33, 48, 32, 32, 64, 64, 1, 8, 17, 32};
    int case_cols [14] = '{64, 32, 64, 172, 64, 64, 65, 128, 128, 172, 64, 32, 100, 64};
    int case_seeds[14] = '{42, 0, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1100, 1200};
    string case_names[14] = '{
      "TC_Sanity", "TC_Identity", "TC_TwoRowTile", "TC_ThreeColTile",
      "TC_Row33", "TC_Row48", "TC_Col65", "TC_Col128",
      "TC_Large", "TC_Max", "TC_SingleRow", "TC_Small",
      "TC_Odd", "TC_Stress"
    };

    int total_errors = 0;

    `uvm_info("GEMV_REG", "启动GEMV Regression Test (14 cases)", UVM_MEDIUM)

    for (int i = 0; i < 14; i++) begin
      gemv_directed_seq seq = gemv_directed_seq::type_id::create($sformatf("seq_%0d", i));
      seq.rows = case_rows[i];
      seq.cols = case_cols[i];
      seq.seed = case_seeds[i];

      `uvm_info("GEMV_REG", $sformatf("Case[%0d] %s: rows=%0d, cols=%0d",
                i, case_names[i], seq.rows, seq.cols), UVM_MEDIUM)

      seq.start(env.vseqr);
      total_errors += seq.error_count;
    end

    if (total_errors == 0)
      `uvm_info("GEMV_REG", "全部14个case PASS", UVM_MEDIUM)
    else
      `uvm_error("GEMV_REG", $sformatf("Regression FAIL: 共%0d errors", total_errors))
  endtask

endclass

// GEMV Random Test
// Constrained random覆盖更多参数组合
class gemv_random_test extends cb_top_base_test;

  `uvm_component_utils(gemv_random_test)

  function new(string name = "gemv_random_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    int num_iterations = 100;
    int total_errors = 0;

    if ($value$plusargs("num_iterations=%d", num_iterations));

    `uvm_info("GEMV_RAND", $sformatf("启动GEMV Random Test (%0d iterations)", num_iterations), UVM_MEDIUM)

    for (int i = 0; i < num_iterations; i++) begin
      gemv_random_seq seq = gemv_random_seq::type_id::create($sformatf("seq_%0d", i));
      if (!seq.randomize() with { rand_seed == i * 7919 + 12345; })
        `uvm_fatal("RAND_FAIL", "gemv_random_seq randomize失败")

      `uvm_info("GEMV_RAND", $sformatf("Iter[%0d]: rows=%0d, cols=%0d, seed=%0d",
                i, seq.rand_rows, seq.rand_cols, seq.rand_seed), UVM_HIGH)

      seq.start(env.vseqr);
      total_errors += seq.error_count;
    end

    if (total_errors == 0)
      `uvm_info("GEMV_RAND", $sformatf("全部%0d iterations PASS", num_iterations), UVM_MEDIUM)
    else
      `uvm_error("GEMV_RAND", $sformatf("Random FAIL: 共%0d errors", total_errors))
  endtask

endclass

// GEMV Random Big-Row Test
// 补 rows>64 此前从未做过golden验证的空白（此前只有PL-05在rows=256单点验证过）
class gemv_random_bigrow_test extends cb_top_base_test;

  `uvm_component_utils(gemv_random_bigrow_test)

  function new(string name = "gemv_random_bigrow_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    int num_iterations = 20;
    int total_errors = 0;

    if ($value$plusargs("num_iterations=%d", num_iterations));

    `uvm_info("GEMV_RAND_BIGROW", $sformatf("启动GEMV Random Big-Row Test (%0d iterations, rows∈[65,511])", num_iterations), UVM_MEDIUM)

    for (int i = 0; i < num_iterations; i++) begin
      gemv_random_bigrow_seq seq = gemv_random_bigrow_seq::type_id::create($sformatf("seq_%0d", i));
      if (!seq.randomize() with { rand_seed == i * 7919 + 54321; })
        `uvm_fatal("RAND_FAIL", "gemv_random_bigrow_seq randomize失败")

      `uvm_info("GEMV_RAND_BIGROW", $sformatf("Iter[%0d]: rows=%0d, cols=%0d, seed=%0d",
                i, seq.rand_rows, seq.rand_cols, seq.rand_seed), UVM_HIGH)

      seq.start(env.vseqr);
      total_errors += seq.error_count;
    end

    if (total_errors == 0)
      `uvm_info("GEMV_RAND_BIGROW", $sformatf("全部%0d iterations PASS", num_iterations), UVM_MEDIUM)
    else
      `uvm_error("GEMV_RAND_BIGROW", $sformatf("Random Big-Row FAIL: 共%0d errors", total_errors))
  endtask

endclass

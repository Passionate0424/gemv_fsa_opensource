// 权重预取测试
//
// 验证GEMV通路上的权重预取（CSR 0x005C：[0]=start脉冲，[1]=target）。
// 判定核心：无论命中还是失效回退，结果都必须与不预取时逐位一致——golden不改，
// 沿用 gemv_base_seq 原有的比对与阈值。预取只该改变"数据什么时候到"，
// 绝不该改变"算出什么"。

// ------------------------------------------------------------------
// Sanity：最基本的32×64命中通路
// ------------------------------------------------------------------
class pf_sanity_test extends cb_top_base_test;

  `uvm_component_utils(pf_sanity_test)

  function new(string name = "pf_sanity_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    pf_sanity_seq seq = pf_sanity_seq::type_id::create("seq");
    `uvm_info("PF_SANITY", "启动预取 Sanity Test (32x64, pf_mode=1)", UVM_MEDIUM)
    seq.start(env.vseqr);
    if (seq.pf_completed == 0)
      `uvm_error("PF_SANITY", "预取一次都没完成，本次通过不能算数")
  endtask

endclass

// ------------------------------------------------------------------
// Regression：定向覆盖 tiling 边界 × 四条预取通路
// ------------------------------------------------------------------
class pf_regression_test extends cb_top_base_test;

  `uvm_component_utils(pf_regression_test)

  function new(string name = "pf_regression_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    // 覆盖重点：
    //   rows 非32倍数 -> 首块行数 min(32,d) 的边界
    //   cols > 64     -> 多tile路径，命中只该发生在 tile_cnt==0 那一次；
    //                    且跳过 S_DMA_MI_INIT 后 num_tiles_reg 必须已被补算
    //   pf_mode       -> 命中 / 两条失效回退 / target不符
    int    case_rows [10] = '{32,  1,   7,  33,  64,  32,  32, 172,  96,  48};
    int    case_cols [10] = '{64, 64,  64,  64,  64,  65, 172,  64,  64, 128};
    int    case_seed [10] = '{61, 62,  63,  64,  65,  66,  67,  68,  69,  70};
    int    case_mode [10] = '{ 1,  1,   1,   1,   1,   1,   1,   2,   3,   4};
    string case_name [10] = '{
      "TC_PF_Base32x64",      "TC_PF_SingleRow",     "TC_PF_Row7_尾块极小",
      "TC_PF_Row33_跨块",     "TC_PF_Row64_双块",     "TC_PF_Col65_双tile",
      "TC_PF_Col172_三tile",  "TC_PF_失效_重写ROWS", "TC_PF_失效_重写MIBASE",
      "TC_PF_target不符"
    };

    int total_errors = 0;
    int total_pf     = 0;

    `uvm_info("PF_REG", "启动预取 Regression Test (10 cases)", UVM_MEDIUM)

    for (int i = 0; i < 10; i++) begin
      pf_directed_seq seq = pf_directed_seq::type_id::create($sformatf("pf_seq_%0d", i));
      seq.rows    = case_rows[i];
      seq.cols    = case_cols[i];
      seq.seed    = case_seed[i];
      seq.pf_mode = case_mode[i];
      `uvm_info("PF_REG", $sformatf("[%0d/10] %s: rows=%0d cols=%0d pf_mode=%0d",
                i+1, case_name[i], seq.rows, seq.cols, seq.pf_mode), UVM_MEDIUM)
      seq.start(env.vseqr);
      total_errors += seq.error_count;
      total_pf     += seq.pf_completed;
    end

    // 防假通过：10个case一次预取都没成功，说明根本没验到预取
    if (total_pf == 0)
      `uvm_error("PF_REG", "全部case中预取一次都没完成，回归结果不可信")

    if (total_errors == 0)
      `uvm_info("PF_REG", $sformatf("预取 Regression 全部通过 (prefetch完成%0d次)", total_pf),
                UVM_MEDIUM)
    else
      `uvm_error("PF_REG", $sformatf("预取 Regression 共 %0d 个错误", total_errors))
  endtask

endclass

// ------------------------------------------------------------------
// 旁路对照 + 失效遍历 + 连发两次：最能暴露"预取污染原有通路"的三类场景
// ------------------------------------------------------------------
class pf_bypass_test extends cb_top_base_test;

  `uvm_component_utils(pf_bypass_test)

  function new(string name = "pf_bypass_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    pf_bypass_pair_seq   bp = pf_bypass_pair_seq::type_id::create("bp");
    pf_invalidate_seq    iv = pf_invalidate_seq::type_id::create("iv");
    pf_double_issue_seq  di = pf_double_issue_seq::type_id::create("di");
    pf_with_silu_seq     ws = pf_with_silu_seq::type_id::create("ws");

    `uvm_info("PF_BYPASS", "旁路对照：同数据 pf_mode=0 / =1 各一趟，结果须逐位相同",
              UVM_MEDIUM)
    bp.start(env.vseqr);

    `uvm_info("PF_BYPASS", "失效遍历：四条通路各跑一趟，每趟都要算对", UVM_MEDIUM)
    iv.start(env.vseqr);

    // 这条专打DMA写地址计数器不复位的bug（详见 prefetch_seq_lib.sv 的说明）
    `uvm_info("PF_BYPASS", "连发两次预取而中间无start", UVM_MEDIUM)
    di.start(env.vseqr);

    `uvm_info("PF_BYPASS", "预取 + SiLU 共存", UVM_MEDIUM)
    ws.start(env.vseqr);

    if (bp.error_count + iv.error_count + di.error_count + ws.error_count != 0)
      `uvm_error("PF_BYPASS", "旁路/失效/连发/共存 组合测试存在错误")
  endtask

endclass

// ------------------------------------------------------------------
// 随机：随机 rows/cols/seed/pf_mode，扫定向case漏掉的组合
// ------------------------------------------------------------------
class pf_random_test extends cb_top_base_test;

  `uvm_component_utils(pf_random_test)

  int num_iterations = 20;

  function new(string name = "pf_random_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    int total_errors = 0;
    int total_pf     = 0;

    void'($value$plusargs("PF_RAND_ITER=%d", num_iterations));
    `uvm_info("PF_RAND", $sformatf("启动预取随机测试 (%0d iterations)", num_iterations),
              UVM_MEDIUM)

    for (int i = 0; i < num_iterations; i++) begin
      pf_random_seq seq = pf_random_seq::type_id::create($sformatf("pf_rand_%0d", i));
      if (!seq.randomize())
        `uvm_fatal("PF_RAND", "randomize失败")
      seq.start(env.vseqr);
      total_errors += seq.error_count;
      total_pf     += seq.pf_completed;
    end

    if (total_pf == 0)
      `uvm_error("PF_RAND", "随机测试中预取一次都没完成，结果不可信")

    if (total_errors == 0)
      `uvm_info("PF_RAND", $sformatf("预取随机测试全部通过 (prefetch完成%0d次)", total_pf),
                UVM_MEDIUM)
    else
      `uvm_error("PF_RAND", $sformatf("预取随机测试共 %0d 个错误", total_errors))
  endtask

endclass

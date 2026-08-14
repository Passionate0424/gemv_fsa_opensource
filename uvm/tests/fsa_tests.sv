// FSA Tests
// FSA模式的sanity、regression和random测试

// FSA Sanity Test（单tile，4×8模式）
class fsa_sanity_test extends cb_top_base_test;

  `uvm_component_utils(fsa_sanity_test)

  function new(string name = "fsa_sanity_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    fsa_sanity_seq seq = fsa_sanity_seq::type_id::create("seq");
    `uvm_info("FSA_SANITY", "启动FSA Sanity Test (dim=8, seq=8, 4x8)", UVM_MEDIUM)
    seq.start(env.vseqr);
  endtask

endclass

// FSA Regression Test（88个directed case）
class fsa_regression_test extends cb_top_base_test;

  `uvm_component_utils(fsa_regression_test)

  function new(string name = "fsa_regression_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    int total_errors = 0;
    int case_idx = 0;

    // 4×8模式（group_mode=0, head_dim=8, num_heads=4）— 30 cases
    int seq_lens_4x8[34] = '{1, 4, 8, 9, 10, 12, 15, 16, 17, 20,
                              24, 25, 30, 32, 33, 40, 48, 50, 60, 64,
                              72, 80, 96, 100, 120, 128, 140, 150, 155, 160, 255, 256, 300, 511};

    // 2×16模式（group_mode=1, head_dim=16, num_heads=2）— 29 cases
    int seq_lens_2x16[31] = '{1, 8, 16, 17, 20, 24, 30, 32, 33, 40,
                               48, 50, 60, 64, 72, 80, 90, 96, 100, 110,
                               120, 128, 130, 140, 144, 150, 155, 158, 160, 255, 511};

    // 1×32模式（group_mode=2, head_dim=32, num_heads=1）— 29 cases
    int seq_lens_1x32[31] = '{1, 16, 32, 33, 40, 48, 50, 60, 64, 65,
                               72, 80, 90, 96, 100, 110, 120, 128, 130, 140,
                               144, 150, 155, 158, 160, 33, 65, 97, 129, 255, 511};

    `uvm_info("FSA_REG", "启动FSA Regression Test (88 cases)", UVM_MEDIUM)

    // 4×8模式
    for (int i = 0; i < 34; i++) begin
      fsa_directed_seq seq = fsa_directed_seq::type_id::create($sformatf("seq_4x8_%0d", i));
      seq.group_mode = 0;
      seq.seq_len    = seq_lens_4x8[i];
      seq.seed       = 1001 + i;

      `uvm_info("FSA_REG", $sformatf("Case[%0d] 4x8: seq_len=%0d", case_idx, seq.seq_len), UVM_MEDIUM)
      seq.start(env.vseqr);
      total_errors += seq.error_count;
      case_idx++;
    end

    // 2×16模式
    for (int i = 0; i < 31; i++) begin
      fsa_directed_seq seq = fsa_directed_seq::type_id::create($sformatf("seq_2x16_%0d", i));
      seq.group_mode = 1;
      seq.seq_len    = seq_lens_2x16[i];
      seq.seed       = 2001 + i;

      `uvm_info("FSA_REG", $sformatf("Case[%0d] 2x16: seq_len=%0d", case_idx, seq.seq_len), UVM_MEDIUM)
      seq.start(env.vseqr);
      total_errors += seq.error_count;
      case_idx++;
    end

    // 1×32模式
    for (int i = 0; i < 31; i++) begin
      fsa_directed_seq seq = fsa_directed_seq::type_id::create($sformatf("seq_1x32_%0d", i));
      seq.group_mode = 2;
      seq.seq_len    = seq_lens_1x32[i];
      seq.seed       = 3001 + i;

      `uvm_info("FSA_REG", $sformatf("Case[%0d] 1x32: seq_len=%0d", case_idx, seq.seq_len), UVM_MEDIUM)
      seq.start(env.vseqr);
      total_errors += seq.error_count;
      case_idx++;
    end

    if (total_errors == 0)
      `uvm_info("FSA_REG", $sformatf("全部%0d cases PASS", case_idx), UVM_MEDIUM)
    else
      `uvm_error("FSA_REG", $sformatf("Regression FAIL: 共%0d errors in %0d cases", total_errors, case_idx))
  endtask

endclass

// FSA Random Test
class fsa_random_test extends cb_top_base_test;

  `uvm_component_utils(fsa_random_test)

  function new(string name = "fsa_random_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    int num_iterations = 150;
    int total_errors = 0;

    if ($value$plusargs("num_iterations=%d", num_iterations));

    `uvm_info("FSA_RAND", $sformatf("启动FSA Random Test (%0d iterations)", num_iterations), UVM_MEDIUM)

    for (int i = 0; i < num_iterations; i++) begin
      fsa_random_seq seq = fsa_random_seq::type_id::create($sformatf("seq_%0d", i));
      if (!seq.randomize() with { rand_seed == i * 6271 + 54321; })
        `uvm_fatal("RAND_FAIL", "fsa_random_seq randomize失败")

      `uvm_info("FSA_RAND", $sformatf("Iter[%0d]: group_mode=%0d, seq_len=%0d, seed=%0d",
                i, seq.rand_group_mode, seq.rand_seq_len, seq.rand_seed), UVM_HIGH)

      seq.start(env.vseqr);
      total_errors += seq.error_count;
    end

    if (total_errors == 0)
      `uvm_info("FSA_RAND", $sformatf("全部%0d iterations PASS", num_iterations), UVM_MEDIUM)
    else
      `uvm_error("FSA_RAND", $sformatf("Random FAIL: 共%0d errors", total_errors))
  endtask

endclass

// FSA head_dim=64定向Test（阶段2.10补充：chunk1+chunk2第一次真实执行，
// chunk2_width=32，不需要DMA padding）
class fsa_hd64_test extends cb_top_base_test;

  `uvm_component_utils(fsa_hd64_test)

  function new(string name = "fsa_hd64_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    int total_errors = 0;
    string names[3] = '{"hd64_fulltile", "hd64_2tile", "hd64_partial"};
    int unsigned seq_lens[3] = '{64, 128, 100};
    int unsigned seeds[3] = '{640001, 640002, 640003};

    `uvm_info("FSA_HD64", "启动FSA head_dim=64 Test", UVM_MEDIUM)

    for (int i = 0; i < 3; i++) begin
      fsa_directed_seq seq = fsa_directed_seq::type_id::create($sformatf("seq_hd64_%0d", i));
      seq.group_mode = 2;
      seq.head_dim   = 64;
      seq.num_heads  = 1;
      seq.seq_len    = seq_lens[i];
      seq.seed       = seeds[i];

      `uvm_info("FSA_HD64", $sformatf("Case[%0d] %s: seq_len=%0d", i, names[i], seq.seq_len), UVM_MEDIUM)
      seq.start(env.vseqr);
      total_errors += seq.error_count;
    end

    if (total_errors == 0)
      `uvm_info("FSA_HD64", "全部case PASS", UVM_MEDIUM)
    else
      `uvm_error("FSA_HD64", $sformatf("FAIL: 共%0d errors", total_errors))
  endtask

endclass

// FSA head_dim=48定向Test（阶段2.10补充：chunk2_width=16，需要DMA padding路径，
// 跟head_dim=64覆盖不同的代码分支）
class fsa_hd48_test extends cb_top_base_test;

  `uvm_component_utils(fsa_hd48_test)

  function new(string name = "fsa_hd48_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    int total_errors = 0;
    string names[3] = '{"hd48_fulltile", "hd48_2tile", "hd48_partial"};
    int unsigned seq_lens[3] = '{48, 96, 70};
    int unsigned seeds[3] = '{480001, 480002, 480003};

    `uvm_info("FSA_HD48", "启动FSA head_dim=48 Test", UVM_MEDIUM)

    for (int i = 0; i < 3; i++) begin
      fsa_directed_seq seq = fsa_directed_seq::type_id::create($sformatf("seq_hd48_%0d", i));
      seq.group_mode = 2;
      seq.head_dim   = 48;
      seq.num_heads  = 1;
      seq.seq_len    = seq_lens[i];
      seq.seed       = seeds[i];

      `uvm_info("FSA_HD48", $sformatf("Case[%0d] %s: seq_len=%0d", i, names[i], seq.seq_len), UVM_MEDIUM)
      seq.start(env.vseqr);
      total_errors += seq.error_count;
    end

    if (total_errors == 0)
      `uvm_info("FSA_HD48", "全部case PASS", UVM_MEDIUM)
    else
      `uvm_error("FSA_HD48", $sformatf("FAIL: 共%0d errors", total_errors))
  endtask

endclass

// FSA GQA/MQA Test（KV fanout：DDR只摆kv_heads份，硬件广播到num_heads个Q组）
// 覆盖4×8(kv=2 GQA / kv=1 MQA / kv=4 MHA退化) 和 2×16(kv=1 GQA / kv=2 MHA退化)，
// 每个配置含单tile/多tile(online-softmax rescale)/非满tile(mask)三种seq_len。
class fsa_gqa_test extends cb_top_base_test;

  `uvm_component_utils(fsa_gqa_test)

  function new(string name = "fsa_gqa_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    int total_errors = 0;
    int case_idx = 0;

    // {group_mode, kv_heads, seq_len, seed}，与 tb_fsa_e2e.sv 的 run_case_gqa 逐一对齐：
    //   4×8(gm=0)：kv=2 GQA×3(单/多/非满) + kv=1 MQA×3 + kv=4 MHA退化×1
    //   2×16(gm=1)：kv=1 GQA×3 + kv=2 MHA退化×1
    // 合法性：ratio=num_heads/kv_heads 必须为正整数——gm=0 num_heads=4 允许 kv∈{1,2,4}，
    // gm=1 num_heads=2 只允许 kv∈{1,2}，绝不能出现 gm=1×kv=4（ratio=0 会在 golden 的
    // h/ratio 处整数除零崩溃）。
    int cfg_gm  [11] = '{0, 0, 0,    0, 0, 0,    0,     1, 1, 1,    1};
    int cfg_kv  [11] = '{2, 2, 2,    1, 1, 1,    4,     1, 1, 1,    2};
    int cfg_seq [11] = '{8, 16, 13,  8, 16, 11,  16,    16, 32, 20, 32};
    int cfg_seed[11] = '{610001, 610002, 610003,
                         611001, 611002, 611003,
                         612001,
                         620001, 620002, 620003,
                         621001};

    `uvm_info("FSA_GQA_TEST", "启动FSA GQA/MQA Test (11 cases)", UVM_MEDIUM)

    for (int i = 0; i < 11; i++) begin
      fsa_gqa_seq seq = fsa_gqa_seq::type_id::create($sformatf("gqa_seq_%0d", i));
      seq.group_mode = cfg_gm[i];
      seq.kv_heads   = cfg_kv[i];
      seq.seq_len    = cfg_seq[i];
      seq.seed       = cfg_seed[i];

      `uvm_info("FSA_GQA_TEST", $sformatf("Case[%0d] gm=%0d kv_heads=%0d seq_len=%0d",
                case_idx, seq.group_mode, seq.kv_heads, seq.seq_len), UVM_MEDIUM)
      seq.start(env.vseqr);
      total_errors += seq.error_count;
      case_idx++;
    end

    if (total_errors == 0)
      `uvm_info("FSA_GQA_TEST", $sformatf("全部%0d cases PASS", case_idx), UVM_MEDIUM)
    else
      `uvm_error("FSA_GQA_TEST", $sformatf("GQA FAIL: 共%0d errors in %0d cases", total_errors, case_idx))
  endtask

endclass

// FSA GQA Random Test（constrained random 覆盖 KV fanout 路径）
// 把 group_mode/kv_heads/seq_len 随机化，撞定向case覆盖不到的组合边界
// （ratio × tile数 × 非满tile 的交叉）。默认100轮，可用+num_iterations覆盖。
class fsa_gqa_random_test extends cb_top_base_test;

  `uvm_component_utils(fsa_gqa_random_test)

  function new(string name = "fsa_gqa_random_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    int num_iterations = 100;
    int total_errors = 0;

    if ($value$plusargs("num_iterations=%d", num_iterations));

    `uvm_info("FSA_GQA_RAND", $sformatf("启动FSA GQA Random Test (%0d iterations)", num_iterations), UVM_MEDIUM)

    for (int i = 0; i < num_iterations; i++) begin
      fsa_gqa_random_seq seq = fsa_gqa_random_seq::type_id::create($sformatf("gqa_rand_%0d", i));
      if (!seq.randomize() with { rand_seed == i * 7919 + 12345; })
        `uvm_fatal("RAND_FAIL", "fsa_gqa_random_seq randomize失败")

      `uvm_info("FSA_GQA_RAND", $sformatf("Iter[%0d]: gm=%0d kv_heads=%0d seq_len=%0d",
                i, seq.rand_group_mode, seq.rand_kv_heads, seq.rand_seq_len), UVM_HIGH)

      seq.start(env.vseqr);
      total_errors += seq.error_count;
    end

    if (total_errors == 0)
      `uvm_info("FSA_GQA_RAND", $sformatf("全部%0d iterations PASS", num_iterations), UVM_MEDIUM)
    else
      `uvm_error("FSA_GQA_RAND", $sformatf("GQA Random FAIL: 共%0d errors", total_errors))
  endtask

endclass

// Dual Mode Stress Test
// 验证GEMV和FSA模式交替执行时无状态泄漏
class dual_mode_stress_test extends cb_top_base_test;

  `uvm_component_utils(dual_mode_stress_test)

  function new(string name = "dual_mode_stress_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    int num_rounds = 10;
    int total_errors = 0;

    if ($value$plusargs("num_iterations=%d", num_rounds));

    `uvm_info("STRESS", $sformatf("启动Dual Mode Stress Test (%0d rounds)", num_rounds), UVM_MEDIUM)

    for (int i = 0; i < num_rounds; i++) begin
      // 执行一次GEMV
      begin
        gemv_directed_seq gemv_seq = gemv_directed_seq::type_id::create($sformatf("gemv_%0d", i));
        gemv_seq.rows = 32;
        gemv_seq.cols = 64;
        gemv_seq.seed = 5000 + i * 2;
        `uvm_info("STRESS", $sformatf("Round[%0d] GEMV: rows=32, cols=64", i), UVM_MEDIUM)
        gemv_seq.start(env.vseqr);
        total_errors += gemv_seq.error_count;
      end

      // 执行一次FSA
      begin
        fsa_directed_seq fsa_seq = fsa_directed_seq::type_id::create($sformatf("fsa_%0d", i));
        fsa_seq.group_mode = 0;
        fsa_seq.seq_len    = 16;
        fsa_seq.seed       = 5001 + i * 2;
        `uvm_info("STRESS", $sformatf("Round[%0d] FSA: dim=8, seq=16, 4x8", i), UVM_MEDIUM)
        fsa_seq.start(env.vseqr);
        total_errors += fsa_seq.error_count;
      end
    end

    if (total_errors == 0)
      `uvm_info("STRESS", $sformatf("全部%0d rounds (GEMV+FSA) PASS", num_rounds), UVM_MEDIUM)
    else
      `uvm_error("STRESS", $sformatf("Stress FAIL: 共%0d errors", total_errors))
  endtask

endclass

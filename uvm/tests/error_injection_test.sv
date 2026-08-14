// Error Injection Test
// 验证非法配置不导致DUT hang或未定义行为
class error_injection_test extends cb_top_base_test;

  `uvm_component_utils(error_injection_test)

  function new(string name = "error_injection_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    int error_count = 0;

    `uvm_info("ERR_TEST", "启动Error Injection Test (4 sub-cases)", UVM_MEDIUM)

    // Sub-case 1: ROWS=0
    begin
      err_zero_rows_seq seq = err_zero_rows_seq::type_id::create("seq_zero_rows");
      seq.start(env.vseqr);
    end

    // Sub-case 2: COLS=0
    begin
      err_zero_cols_seq seq = err_zero_cols_seq::type_id::create("seq_zero_cols");
      seq.start(env.vseqr);
    end

    // Sub-case 3: start while busy
    begin
      err_start_while_busy_seq seq = err_start_while_busy_seq::type_id::create("seq_start_busy");
      seq.start(env.vseqr);
    end

    // Sub-case 4: invalid group_mode
    begin
      err_invalid_group_mode_seq seq = err_invalid_group_mode_seq::type_id::create("seq_inv_gmode");
      seq.start(env.vseqr);
    end

    `uvm_info("ERR_TEST", "Error Injection Test完成", UVM_MEDIUM)
  endtask

endclass

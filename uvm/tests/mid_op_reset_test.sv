// Mid-Operation Reset Test
// 验证DUT在任意FSM状态下被复位后能正确恢复
// 策略：启动操作后在不同延迟点触发复位，验证复位后能正常完成新操作
class mid_op_reset_test extends cb_top_base_test;

  `uvm_component_utils(mid_op_reset_test)

  function new(string name = "mid_op_reset_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    // 密集reset点：覆盖FSM各阶段（DMA/COMPUTE/TRANSPOSE/QK/SCORE/EXP2/PV等）
    int reset_delays[] = '{3, 5, 8, 12, 15, 20, 30, 40, 50, 70, 100, 130, 150,
                           200, 300, 400, 500, 700, 1000, 1500, 2000, 3000, 5000};
    int error_count = 0;

    `uvm_info("RESET_TEST", $sformatf("启动Mid-Operation Reset Test (%0d reset points)", reset_delays.size()), UVM_MEDIUM)

    // GEMV mid-operation reset
    for (int i = 0; i < reset_delays.size(); i++) begin
      mid_op_reset_gemv_seq seq = mid_op_reset_gemv_seq::type_id::create($sformatf("gemv_rst_%0d", i));
      seq.reset_delay_cycles = reset_delays[i];
      seq.start(env.vseqr);
      error_count += seq.error_count;
    end

    // FSA mid-operation reset
    for (int i = 0; i < reset_delays.size(); i++) begin
      mid_op_reset_fsa_seq seq = mid_op_reset_fsa_seq::type_id::create($sformatf("fsa_rst_%0d", i));
      seq.reset_delay_cycles = reset_delays[i];
      seq.start(env.vseqr);
      error_count += seq.error_count;
    end

    if (error_count == 0)
      `uvm_info("RESET_TEST", $sformatf("全部%0d个reset point PASS", reset_delays.size() * 2), UVM_MEDIUM)
    else
      `uvm_error("RESET_TEST", $sformatf("FAIL: %0d errors", error_count))
  endtask

endclass

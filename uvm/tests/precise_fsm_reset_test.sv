// 精准FSM Reset Test
// 对每个FSM状态精确触发复位，覆盖所有S_XXX→S_IDLE转移
class precise_fsm_reset_test extends cb_top_base_test;

  `uvm_component_utils(precise_fsm_reset_test)

  function new(string name = "precise_fsm_reset_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    int error_count = 0;

    // CB_Controller_v2状态（需要覆盖的复位转移）
    int gemv_states[] = '{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14, 15};
    string gemv_names[] = '{"DMA_VI", "WAIT_VI", "LOOP_START", "DMA_MI_INIT",
                            "DMA_MI_ISSUE", "DMA_MI_WAIT", "COMPUTE", "WAIT_COMPUTE",
                            "DMA_VO", "WAIT_VO", "UPDATE_OFFSET", "DMA_VO_INIT",
                            "ACCUMULATE", "CHECK_LOOP"};

    // fsa_ctrl_fsm状态（需要覆盖的复位转移）
    int fsa_states[] = '{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19};
    string fsa_names[] = '{"LOAD_Q_BUF", "LOAD_Q_FIRE", "CMP_RESET", "DMA_K",
                           "TRANSPOSE_K", "QK_MAC", "SCORE_RESTREAM", "ZERO_FLOWDU",
                           "LOAD_REG_UI", "SUBTRACT", "SCALE", "EXP2", "ROWSUM",
                           "DMA_V", "PV_MAC", "TILE_CHECK", "RECIPROCAL", "NORM", "DMA_O"};

    `uvm_info("PREC_FSM", $sformatf("启动Precise FSM Reset Test: %0d GEMV + %0d FSA states",
              gemv_states.size(), fsa_states.size()), UVM_MEDIUM)

    // GEMV FSM精准复位
    for (int i = 0; i < gemv_states.size(); i++) begin
      precise_gemv_fsm_reset_seq seq = precise_gemv_fsm_reset_seq::type_id::create($sformatf("gemv_s%0d", i));
      seq.target_state = gemv_states[i];
      seq.state_name = gemv_names[i];
      seq.start(env.vseqr);
      error_count += seq.error_count;
    end

    // FSA FSM精准复位
    for (int i = 0; i < fsa_states.size(); i++) begin
      precise_fsa_fsm_reset_seq seq = precise_fsa_fsm_reset_seq::type_id::create($sformatf("fsa_s%0d", i));
      seq.target_state = fsa_states[i];
      seq.state_name = fsa_names[i];
      seq.start(env.vseqr);
      error_count += seq.error_count;
    end

    if (error_count == 0)
      `uvm_info("PREC_FSM", $sformatf("全部%0d个精准复位 PASS",
                gemv_states.size() + fsa_states.size()), UVM_MEDIUM)
    else
      `uvm_error("PREC_FSM", $sformatf("FAIL: %0d errors", error_count))
  endtask

endclass

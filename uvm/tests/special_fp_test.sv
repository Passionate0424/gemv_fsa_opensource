// Special FP Value Test
// 注入极端浮点值验证DUT不crash，同时提升arithmetic模块覆盖率
class special_fp_test extends cb_top_base_test;

  `uvm_component_utils(special_fp_test)

  function new(string name = "special_fp_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    int error_count = 0;

    `uvm_info("SP_FP_TEST", "启动Special FP Value Test", UVM_MEDIUM)

    begin
      special_fp_gemv_seq seq = special_fp_gemv_seq::type_id::create("gemv_sp");
      seq.start(env.vseqr);
      error_count += seq.error_count;
    end

    begin
      special_fp_fsa_seq seq = special_fp_fsa_seq::type_id::create("fsa_sp");
      seq.start(env.vseqr);
      error_count += seq.error_count;
    end

    // NF-01~05: inf/NaN/max/±0数值域边界（GEMV）
    begin
      nf_special_fp_seq seq = nf_special_fp_seq::type_id::create("nf_gemv");
      seq.start(env.vseqr);
      error_count += seq.error_count;
    end

    // NF-06~08: exp2 PWL分段 + softmax极端分布（FSA）
    begin
      nf_fsa_pwl_seq seq = nf_fsa_pwl_seq::type_id::create("nf_fsa");
      seq.start(env.vseqr);
      error_count += seq.error_count;
    end

    if (error_count == 0)
      `uvm_info("SP_FP_TEST", "Special FP Value Test PASS", UVM_MEDIUM)
    else
      `uvm_error("SP_FP_TEST", $sformatf("FAIL: %0d errors", error_count))
  endtask

endclass

// CB_top_v2 基础Test
// 所有test的基类：构建env、执行复位
class cb_top_base_test extends uvm_test;

  cb_top_env env;

  `uvm_component_utils(cb_top_base_test)

  function new(string name = "cb_top_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = cb_top_env::type_id::create("env", this);
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this, "base_test运行中");

    // 等待复位完成（tb_top中initial block已执行复位）
    #200;
    `uvm_info("BASE_TEST", "复位完成，环境就绪", UVM_MEDIUM)

    // 子类覆盖此方法执行具体测试
    run_test_body(phase);

    phase.drop_objection(this, "base_test完成");
  endtask

  // 子类覆盖此虚方法实现具体测试逻辑
  virtual task run_test_body(uvm_phase phase);
    `uvm_info("BASE_TEST", "base_test: 无具体测试逻辑（仅验证环境搭建）", UVM_MEDIUM)
  endtask

  function void report_phase(uvm_phase phase);
    uvm_report_server svr = uvm_report_server::get_server();
    if (svr.get_severity_count(UVM_FATAL) + svr.get_severity_count(UVM_ERROR) > 0)
      `uvm_info("RESULT", "========== TEST FAILED ==========", UVM_NONE)
    else
      `uvm_info("RESULT", "========== TEST PASSED ==========", UVM_NONE)
  endfunction

endclass

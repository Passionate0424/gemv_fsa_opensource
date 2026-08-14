// CB_top_v2 UVM顶层环境
class cb_top_env extends uvm_env;

  // 原有组件
  axi_slv_agent       axi_slv_agt;
  mem_model           mem;
  cb_top_virtual_seqr vseqr;
  virtual cb_top_if   cb_vif;

  // RAL组件
  cb_csr_reg_block                       ral;
  cb_axi_reg_adapter                     reg_adapter;
  uvm_reg_predictor #(axi_slv_seq_item)  reg_predictor;

  // 覆盖率
  cb_func_coverage    func_cov;

  `uvm_component_utils(cb_top_env)

  function new(string name = "cb_top_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // 原有组件
    axi_slv_agt = axi_slv_agent::type_id::create("axi_slv_agt", this);
    mem = mem_model::type_id::create("mem", this);
    vseqr = cb_top_virtual_seqr::type_id::create("vseqr", this);

    // RAL
    ral = cb_csr_reg_block::type_id::create("ral");
    ral.build();
    reg_adapter = cb_axi_reg_adapter::type_id::create("reg_adapter");
    reg_predictor = uvm_reg_predictor#(axi_slv_seq_item)::type_id::create("reg_predictor", this);

    // 覆盖率
    func_cov = cb_func_coverage::type_id::create("func_cov", this);

    // cb_top_if
    if (!uvm_config_db#(virtual cb_top_if)::get(this, "", "cb_top_vif", cb_vif))
      `uvm_fatal("NOVIF", "未获取到cb_top_vif")
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    // Virtual sequencer连接
    vseqr.axi_slv_sqr = axi_slv_agt.sqr;
    vseqr.mem          = mem;

    // RAL: default_map绑定到sequencer和adapter
    ral.default_map.set_sequencer(axi_slv_agt.sqr, reg_adapter);
    ral.default_map.set_auto_predict(0);

    // Predictor: monitor AP → predictor（自动更新RAL mirror）
    reg_predictor.map     = ral.default_map;
    reg_predictor.adapter = reg_adapter;
    axi_slv_agt.mon.ap.connect(reg_predictor.bus_in);

    // Coverage: monitor AP → func_cov
    axi_slv_agt.mon.ap.connect(func_cov.analysis_export);
    func_cov.ral = ral;
  endfunction

endclass

// Performance/Capacity Limit Test
// 打满硬件容量/位宽上限边界（seq_len/rows/cols/head_dim/group_mode），
// 确认DUT行为为三种结局之一：① 正常 ② 优雅拒绝 ③ 静默溢出（签核缺陷）。
// PL-01/03/04功能case期望正常；PL-02/05/06/07定性case记录行为供签核。
class perf_limit_test extends cb_top_base_test;

  `uvm_component_utils(perf_limit_test)

  function new(string name = "perf_limit_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    `uvm_info("PERF_LIMIT", "启动Performance/Capacity Limit Test (7 sub-cases)", UVM_MEDIUM)

    // PL-01 大seq满tile（127 tiles）
    begin
      pl_big_seq_tiles_seq seq = pl_big_seq_tiles_seq::type_id::create("pl01");
      seq.start(env.vseqr);
    end

    // PL-02 seq_len截断点（4096→0）【定性】
    begin
      pl_seqlen_trunc_seq seq = pl_seqlen_trunc_seq::type_id::create("pl02");
      seq.start(env.vseqr);
    end

    // PL-03 seq_len满值（4095）
    begin
      pl_seqlen_max_seq seq = pl_seqlen_max_seq::type_id::create("pl03");
      seq.start(env.vseqr);
    end

    // PL-04 GEMV大列（cols=1024）
    begin
      pl_gemv_bigcol_seq seq = pl_gemv_bigcol_seq::type_id::create("pl04");
      seq.start(env.vseqr);
    end

    // PL-05 GEMV大行（rows=256）【定性】
    begin
      pl_gemv_bigrow_seq seq = pl_gemv_bigrow_seq::type_id::create("pl05");
      seq.start(env.vseqr);
    end

    // PL-06 head_dim越界（65）【定性】
    begin
      pl_headdim_oob_seq seq = pl_headdim_oob_seq::type_id::create("pl06");
      seq.start(env.vseqr);
    end

    // PL-07 GROUP_MODE=3非法值【定性】
    begin
      pl_group_mode3_seq seq = pl_group_mode3_seq::type_id::create("pl07");
      seq.start(env.vseqr);
    end

    `uvm_info("PERF_LIMIT", "Performance/Capacity Limit Test完成", UVM_MEDIUM)
  endtask

endclass

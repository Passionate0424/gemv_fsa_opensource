// 权重预取 Sequence Library
//
// 验证GEMV通路上的权重预取（CSR 0x005C：[0]=start脉冲，[1]=target）。
// CPU在算rmsnorm/SwiGLU这类纯计算时，硬件先把下一次matmul的第一个权重行块
// 搬进权重SRAM；那时SRAM本就空闲（上一次任务已结束），不需要双缓冲。
//
// 全部复用 gemv_base_seq 的流程与比对基础设施，只设 pf_mode——
// **golden一个字节都不用改**。这正是本组case的判定核心：无论走命中还是失效
// 回退，结果都必须和不预取时逐位一致。命中要算对，回退也要算对。
//
// pf_mode 的四条通路（见 gemv_base_seq.do_prefetch）：
//   1 = 正常命中，硬件跳过首块DMA
//   2 = 失效规则1：预取后重写REG_ROWS
//   3 = 失效规则1：预取后重写REG_MI_BASE
//   4 = 失效规则3：以FSA为target预取，GEMV任务不得命中

`ifndef PREFETCH_SEQ_LIB_SV
`define PREFETCH_SEQ_LIB_SV

// ------------------------------------------------------------------
// Sanity：32×64单tile命中，最基本的通路验证
// ------------------------------------------------------------------
class pf_sanity_seq extends gemv_base_seq;
  `uvm_object_utils(pf_sanity_seq)

  function new(string name = "pf_sanity_seq");
    super.new(name);
    rows    = 32;
    cols    = 64;
    seed    = 42;
    pf_mode = 1;
  endfunction
endclass

// ------------------------------------------------------------------
// Directed：参数化，由 test 侧填 rows/cols/seed/pf_mode 驱动边界场景
// ------------------------------------------------------------------
class pf_directed_seq extends gemv_base_seq;
  `uvm_object_utils(pf_directed_seq)

  function new(string name = "pf_directed_seq");
    super.new(name);
    pf_mode = 1;
  endfunction
endclass

// ------------------------------------------------------------------
// 旁路对照：同一组数据先不预取、再预取各跑一次，两趟结果必须完全一致。
// 这是最能暴露"预取改动污染了原有通路"的一类case——与SiLU那次的
// silu_bypass_pair_seq 同一思路。
// ------------------------------------------------------------------
class pf_bypass_pair_seq extends gemv_base_seq;
  `uvm_object_utils(pf_bypass_pair_seq)

  logic [31:0] baseline_out [];

  function new(string name = "pf_bypass_pair_seq");
    super.new(name);
    rows = 32;
    cols = 64;
    seed = 7;
  endfunction

  task body();
    // 第一趟：不预取，等价于原有GEMV行为，留作基线
    pf_mode = 0;
    `uvm_info("PF_SEQ", "pass1: pf_mode=0 (baseline)", UVM_MEDIUM)
    super.body();
    baseline_out = new[rows];
    for (int i = 0; i < rows; i++)
      baseline_out[i] = ddr_read(vo_base_addr + i * 4);

    // 第二趟：同样的数据走预取命中通路，结果必须与基线逐位相同
    pf_mode = 1;
    `uvm_info("PF_SEQ", "pass2: pf_mode=1 (prefetch hit)", UVM_MEDIUM)
    super.body();
    for (int i = 0; i < rows; i++) begin
      logic [31:0] v = ddr_read(vo_base_addr + i * 4);
      if (v !== baseline_out[i])
        `uvm_error("PF_SEQ", $sformatf(
            "prefetch changed result at [%0d]: baseline=0x%08h prefetched=0x%08h",
            i, baseline_out[i], v))
    end
  endtask
endclass

// ------------------------------------------------------------------
// 失效规则遍历：同一组数据把4条通路全走一遍，每趟都必须算对。
// mode2/3还会在seq内部断言PF_VALID确实被配置写清掉了。
// ------------------------------------------------------------------
class pf_invalidate_seq extends gemv_base_seq;
  `uvm_object_utils(pf_invalidate_seq)

  function new(string name = "pf_invalidate_seq");
    super.new(name);
    rows = 32;
    cols = 64;
    seed = 11;
  endfunction

  task body();
    for (int m = 1; m <= 4; m++) begin
      pf_mode = m;
      `uvm_info("PF_SEQ", $sformatf("invalidate sweep: pf_mode=%0d", m), UVM_MEDIUM)
      super.body();
    end
  endtask
endclass

// ------------------------------------------------------------------
// 连发两次预取而中间没有start。
// 这条专打一个真实存在过的bug：CB_top_v2的DMA写地址计数器
// (dma_w_bank_sel_cnt/dma_col_cnt/dma_group_base) 只在 CB_done||w_mem_rst
// 时归零，而预取路径 S_IDLE→S_PF_ISSUE→S_PF_WAIT→S_IDLE 两者都不经过；
// 若不在S_PF_ISSUE补一次复位，第二次预取会接着上一次的终值往下写，
// 数据整体错位。修复后本case必须通过。
// ------------------------------------------------------------------
class pf_double_issue_seq extends gemv_base_seq;
  `uvm_object_utils(pf_double_issue_seq)

  function new(string name = "pf_double_issue_seq");
    super.new(name);
    rows = 32;
    cols = 64;
    seed = 23;
  endfunction

  task do_prefetch();
    logic [31:0] st;
    int poll_cnt;
    // 连发两次，每次都等它真的搬完
    for (int k = 0; k < 2; k++) begin
      csr_write(REG_PF_CTRL, 32'h1);
      poll_cnt = 0;
      st = 32'h0;
      while (st[PF_STATUS_VALID_BIT] !== 1'b1 && poll_cnt < 4000) begin
        csr_read(REG_STATUS, st);
        poll_cnt++;
      end
      if (st[PF_STATUS_VALID_BIT] !== 1'b1)
        `uvm_error("PF_SEQ", $sformatf("double-issue: prefetch #%0d never completed", k))
      else
        pf_completed++;
    end
  endtask
endclass

// ------------------------------------------------------------------
// 预取 + SiLU 融合共存：两个特性都动GEMV输出通路，必须互不干扰
// ------------------------------------------------------------------
class pf_with_silu_seq extends gemv_base_seq;
  `uvm_object_utils(pf_with_silu_seq)

  function new(string name = "pf_with_silu_seq");
    super.new(name);
    rows    = 32;
    cols    = 64;
    seed    = 31;
    silu_en = 1;
    pf_mode = 1;
  endfunction
endclass

// ------------------------------------------------------------------
// 随机：随机rows/cols/seed/pf_mode，找定向case漏掉的组合
// ------------------------------------------------------------------
class pf_random_seq extends gemv_base_seq;
  `uvm_object_utils(pf_random_seq)

  rand int unsigned rand_rows;
  rand int unsigned rand_cols;
  rand int unsigned rand_seed;
  rand int unsigned rand_pf_mode;

  // rows覆盖尾块(非32整数倍)与多行块；cols跨过64这条多tile分界
  constraint c_rows { rand_rows inside {[1:200]}; }
  constraint c_cols { rand_cols inside {[1:200]}; }
  constraint c_mode { rand_pf_mode inside {[1:4]}; }

  function new(string name = "pf_random_seq");
    super.new(name);
  endfunction

  task body();
    rows    = rand_rows;
    cols    = rand_cols;
    seed    = rand_seed;
    pf_mode = rand_pf_mode;
    `uvm_info("PF_SEQ", $sformatf("random: rows=%0d cols=%0d seed=%0d pf_mode=%0d",
                                  rows, cols, seed, pf_mode), UVM_MEDIUM)
    super.body();
  endtask
endclass

`endif // PREFETCH_SEQ_LIB_SV

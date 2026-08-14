// SiLU融合Sequence Library
//
// 验证GEMV通路上的SiLU算子融合（CSR 0x0058 bit[0]=silu_en）。
// 硬件在GEMV算完、DMA写回DDR之前，把Output SRAM里的结果就地过一遍
// silu(x)=x*sigmoid(x)，复用4个fsa_accumulator通道跑7步微程序。
//
// 全部复用 gemv_base_seq 的流程与比对基础设施，只把 silu_en 置1——
// golden 侧会自动对结果做同样的后处理（见 gemv_seq_lib.sv 的 silu_of）。
//
// 精度说明：硬件的 exp2 是8段PWL近似，固有相对误差4.69e-4，实测整条SiLU
// 通路 mean_rel=1.48e-4 / max_rel=4.81e-4，都在 gemv_base_seq 的0.1%
// FAIL阈值内，所以直接沿用该阈值，不额外放宽。

`ifndef SILU_SEQ_LIB_SV
`define SILU_SEQ_LIB_SV

// ------------------------------------------------------------------
// Sanity：32×64单tile，最基本的通路验证
// ------------------------------------------------------------------
class silu_sanity_seq extends gemv_base_seq;
  `uvm_object_utils(silu_sanity_seq)

  function new(string name = "silu_sanity_seq");
    super.new(name);
    rows    = 32;
    cols    = 64;
    seed    = 42;
    silu_en = 1;
  endfunction
endclass

// ------------------------------------------------------------------
// Directed：参数化，由 test 侧填 rows/cols/seed/data_range 驱动边界场景
// ------------------------------------------------------------------
class silu_directed_seq extends gemv_base_seq;
  `uvm_object_utils(silu_directed_seq)

  function new(string name = "silu_directed_seq");
    super.new(name);
    silu_en = 1;
  endfunction
endclass

// ------------------------------------------------------------------
// 旁路对照：同一组数据先 silu_en=0 再 silu_en=1 各跑一次。
// 前者必须与不带SiLU的基线完全一致（证明旁路无副作用），后者验证功能。
// 这是最能暴露"SiLU改动污染了原有通路"的一类case。
// ------------------------------------------------------------------
class silu_bypass_pair_seq extends gemv_base_seq;
  `uvm_object_utils(silu_bypass_pair_seq)

  function new(string name = "silu_bypass_pair_seq");
    super.new(name);
    rows = 32;
    cols = 64;
    seed = 7;
  endfunction

  task body();
    // 第一趟：关闭SiLU，等价于原有GEMV行为
    silu_en = 0;
    `uvm_info("SILU_SEQ", "旁路对照 pass1: silu_en=0（应与原GEMV基线一致）", UVM_MEDIUM)
    super.body();

    // 第二趟：同样的数据开启SiLU
    silu_en = 1;
    `uvm_info("SILU_SEQ", "旁路对照 pass2: silu_en=1", UVM_MEDIUM)
    super.body();
  endtask
endclass

// ------------------------------------------------------------------
// 粘连检查：连续两次GEMV，第一次开SiLU、第二次关。
// 验证 silu_en 不会在调用之间残留——CSR是电平型的，若FSM或使能有粘连，
// 第二次会被错误地再过一遍激活。
// ------------------------------------------------------------------
class silu_sticky_check_seq extends gemv_base_seq;
  `uvm_object_utils(silu_sticky_check_seq)

  function new(string name = "silu_sticky_check_seq");
    super.new(name);
    rows = 32;
    cols = 64;
    seed = 11;
  endfunction

  task body();
    silu_en = 1;
    `uvm_info("SILU_SEQ", "粘连检查 pass1: silu_en=1", UVM_MEDIUM)
    super.body();

    silu_en = 0;
    seed    = 12;   // 换数据，避免与上一趟结果混淆
    `uvm_info("SILU_SEQ", "粘连检查 pass2: silu_en=0（不应残留激活）", UVM_MEDIUM)
    super.body();
  endtask
endclass

// ------------------------------------------------------------------
// Random：约束随机。重点覆盖三类边界——
//   1) rows 非32整数倍（尾块不满，silu_num_elem 会收窄）
//   2) cols > 64（多tile累加，SiLU只能在最后一个tile之后做一次）
//   3) data_range 跨越正常区/接近零/饱和区
// ------------------------------------------------------------------
class silu_random_seq extends gemv_base_seq;
  rand int unsigned rand_rows;
  rand int unsigned rand_cols;
  rand int unsigned rand_seed;
  rand int unsigned range_sel;

  // rows 覆盖尾块不满的各种余数：1~31 是单块不满，33~63 是两块且尾块不满
  constraint c_rows { rand_rows inside {[1:96]}; }
  constraint c_rows_dist {
    rand_rows dist {
      [1:7]    := 20,   // 尾块远不满，addr_total 只有1~2
      [8:31]   := 25,
      32       := 10,   // 正好一块
      [33:63]  := 20,   // 两块，尾块不满
      64       := 10,   // 正好两块
      [65:96]  := 15
    };
  }

  // cols 跨过64这个tile边界，触发多tile累加路径
  constraint c_cols { rand_cols inside {[1:172]}; }
  constraint c_cols_dist {
    rand_cols dist {
      [1:63]   := 30,
      64       := 15,   // 正好一个tile
      [65:128] := 30,   // 两个tile
      [129:172]:= 25    // 三个tile
    };
  }

  constraint c_seed  { rand_seed inside {[1:100000]}; }
  constraint c_range { range_sel inside {[0:3]}; }

  `uvm_object_utils(silu_random_seq)

  function new(string name = "silu_random_seq");
    super.new(name);
    silu_en = 1;
  endfunction

  function void post_randomize();
    rows = rand_rows;
    cols = rand_cols;
    seed = rand_seed;
    // data_range 决定激活值落在哪个区间：
    //   0.5 -> 集中在零附近，silu 近似线性，且相对误差分母小、最敏感
    //   2.0 -> 常规区间
    //   8.0 -> 负半轴已接近饱和（silu→0），正半轴接近 silu→x
    //   20.0-> 深饱和，验证 exp2 的下溢与符号处理
    case (range_sel)
      0: data_range = 0.5;
      1: data_range = 2.0;
      2: data_range = 8.0;
      default: data_range = 20.0;
    endcase
  endfunction
endclass

`endif // SILU_SEQ_LIB_SV

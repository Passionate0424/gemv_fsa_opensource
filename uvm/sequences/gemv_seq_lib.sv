// GEMV模式Sequence Library
// 提供GEMV测试的完整流程sequence

// CSR地址定义（本地使用）
`ifndef GEMV_SEQ_LIB_SV
`define GEMV_SEQ_LIB_SV

// GEMV基础Sequence：加载DDR → 配置CSR → 启动 → 等待完成
class gemv_base_seq extends cb_top_base_seq;

  // 测试参数
  int unsigned rows = 32;
  int unsigned cols = 64;
  int unsigned seed = 42;
  real data_range   = 2.0;

  // DDR地址
  // vo_base_addr不能是固定localparam：矩阵区[MI_BASE_ADDR, MI_BASE_ADDR+rows*cols*4)
  // 大小随rows*cols变化，rows*cols偏大时会写穿固定的0x1_0000，覆盖到输出区（bigrow
  // 测试rows达511时实测触发，与fsa_seq_lib.sv历史上K/V固定base覆盖是同一类bug，
  // 这里比照那次的动态base思路修复：VO紧跟在矩阵区之后，按实际大小动态摆放）
  localparam int unsigned VI_BASE_ADDR = 32'h0000_1000;
  localparam int unsigned MI_BASE_ADDR = 32'h0000_4000;
  logic [31:0] vo_base_addr;

  // CSR地址
  localparam logic [31:0] REG_CTRL    = 32'h0000;
  localparam logic [31:0] REG_STATUS  = 32'h0004;
  localparam logic [31:0] REG_VI_BASE = 32'h0010;
  localparam logic [31:0] REG_MI_BASE = 32'h0014;
  localparam logic [31:0] REG_VO_BASE = 32'h0018;
  localparam logic [31:0] REG_ROWS    = 32'h0020;
  localparam logic [31:0] REG_COLS    = 32'h0024;
  localparam logic [31:0] REG_ACT_CTRL= 32'h0058;   // [0]=silu_en
  localparam logic [31:0] REG_PF_CTRL = 32'h005C;   // [0]=start脉冲 [1]=target

  localparam int PF_STATUS_VALID_BIT = 2;           // STATUS[2]=pf_valid
  localparam int PF_STATUS_TGT_BIT   = 3;           // STATUS[3]=pf_target

  // SiLU融合开关。默认0，现有全部GEMV case行为不变；置1时硬件在结果写回DDR
  // 之前就地过一遍silu()，golden也相应做同样的后处理。
  bit silu_en = 0;

  // 权重预取模式。默认0=不预取，现有全部case行为不变。
  // 非0时在start之前先发一次预取，各模式验证一条不同通路，但**结果判定完全不变**
  // ——命中要算对，失效回退也要算对，golden一个字节都不用改。
  //   1 = 正常命中（硬件跳过首块DMA）
  //   2 = 失效规则1：预取后重写REG_ROWS，pf_valid必须清零、回退正常搬运
  //   3 = 失效规则1：预取后重写REG_MI_BASE
  //   4 = 失效规则3：以FSA为target预取，GEMV任务不得命中
  int pf_mode = 0;
  int pf_completed;   // 观测到PF_VALID置起的次数，防"预取压根没发生"的假通过

  // 存储golden结果
  logic [31:0] golden_output [];
  logic [31:0] golden_pre_silu [];   // SiLU前的GEMV原值，供fp64精确对照统计用
  int error_count;

  `uvm_object_utils(gemv_base_seq)

  function new(string name = "gemv_base_seq");
    super.new(name);
  endfunction

  // silu golden：走DPI-C的位级模型（tb/dpi/silu_dpi.c → fp_bitlevel.h）。
  // 不能用SV的$exp——那是数学真值，与硬件的8段PWL近似天然差4.8e-4，拿它当
  // golden就只能设0.1%量级的宽松阈值，实现bug会被近似误差掩盖。位级模型是
  // 逐条转录RTL的，可以做严格判定：不一致即实现问题，与精度无关。
  function logic [31:0] silu_of(logic [31:0] xb);
    return dpi_pkg::dpi_silu_bits(xb);
  endfunction

  // fp64精确参考，仅用于统计相对误差（信息性，不参与FAIL判定）
  function logic [31:0] silu_ref_of(logic [31:0] xb);
    return dpi_pkg::dpi_silu_ref(xb);
  endfunction

  // 发起一次权重预取，并按pf_mode验证对应通路。
  // 调用前CSR必须已配好——预取用的就是那份配置，这也正是"重写配置即作废"的由来。
  // virtual：pf_double_issue_seq要覆盖它来验"连发两次预取"那条路径
  virtual task do_prefetch();
    logic [31:0] st;
    int poll_cnt;

    // mode4用FSA做target，而本次跑的是GEMV任务，硬件应因模式不符拒绝命中。
    // 先给FSA那组CSR配合法值，让预取真的执行完：head_dim/seq_len为0会触发
    // 硬件的尺寸非法保护而根本不发预取，那样这条规则就成了空验。
    if (pf_mode == 4) begin
      csr_write(32'h0040, 32'd8);          // HEAD_DIM
      csr_write(32'h0044, 32'd8);          // SEQ_LEN
      csr_write(32'h0048, 32'd256);        // KV_STRIDE = 8*8*4
      csr_write(32'h004C, 32'd1);          // NUM_HEADS
      csr_write(32'h0034, MI_BASE_ADDR);   // K_BASE 复用矩阵区，那里有真实数据
    end
    csr_write(REG_PF_CTRL, (pf_mode == 4) ? 32'h3 : 32'h1);

    // 等预取的DMA真的跑完。必须等到PF_VALID置起才算数，否则后面谈"命中"没有意义。
    //
    // 已知问题：本循环在 pf_bypass_test 里从未等到 PF_VALID，而 [PF_SET] 总在循环放弃
    // 之后才出现，且完成时刻与传输量无关（mode=4 只搬 64 个字，与 mode=1 搬 2048 个字
    // 表现相同）。已排除两种解释：不是轮询次数不够（加大只会等更久），也不是轮询占满
    // 总线（每次读之间插 200ns 空闲、总线 71% 时间空闲，结果不变）。
    // directed TB 侧 run_gemv_pf 56/56 且 pf_seen 全为 1，说明预取通路本身正常，
    // 问题在本环境下 CSR 访问与预取之间的某种互斥，机制待查。
    poll_cnt = 0;
    st = 32'h0;
    while (st[PF_STATUS_VALID_BIT] !== 1'b1 && poll_cnt < 4000) begin
      csr_read(REG_STATUS, st);
      poll_cnt++;
    end

    if (st[PF_STATUS_VALID_BIT] !== 1'b1) begin
      `uvm_error("PF_SEQ", $sformatf("pf_mode=%0d: PF_VALID never asserted after %0d polls",
                                     pf_mode, poll_cnt))
    end else begin
      pf_completed++;
      if (pf_mode == 4 && st[PF_STATUS_TGT_BIT] !== 1'b1)
        `uvm_error("PF_SEQ", "pf_mode=4: STATUS.PF_TGT should mirror target=1")
    end

    // 失效通路：重写决定"搬什么/搬多少"的CSR，pf_valid必须当场清掉
    if (pf_mode == 2 || pf_mode == 3) begin
      if (pf_mode == 2) csr_write(REG_ROWS, rows);
      else              csr_write(REG_MI_BASE, MI_BASE_ADDR);
      csr_read(REG_STATUS, st);
      if (st[PF_STATUS_VALID_BIT] !== 1'b0)
        `uvm_error("PF_SEQ", $sformatf("pf_mode=%0d: PF_VALID must clear after rewriting %s",
                                       pf_mode, (pf_mode == 2) ? "ROWS" : "MI_BASE"))
      else
        `uvm_info("PF_SEQ", $sformatf("pf_mode=%0d: invalidation on config write OK", pf_mode),
                  UVM_MEDIUM)
    end
  endtask

  task body();
    logic [31:0] matrix [];
    logic [31:0] vector [];
    int unsigned prng_state;

    `uvm_info("GEMV_SEQ", $sformatf("开始GEMV测试: rows=%0d, cols=%0d, seed=%0d",
              rows, cols, seed), UVM_MEDIUM)

    // 初始化PRNG
    prng_state = seed;

    // VO紧跟在矩阵区之后动态摆放，按4字节对齐留够rows*cols*4的空间，
    // 避免固定地址被大rows*cols的矩阵数据写穿覆盖
    vo_base_addr = MI_BASE_ADDR + rows * cols * 4;

    // 分配数组
    matrix = new[rows * cols];
    vector = new[cols];
    golden_output = new[rows];

    // 生成随机向量
    for (int i = 0; i < cols; i++) begin
      vector[i] = rand_fp32(prng_state, data_range);
    end

    // 生成随机矩阵
    for (int r = 0; r < rows; r++)
      for (int c = 0; c < cols; c++) begin
        matrix[r * cols + c] = rand_fp32(prng_state, data_range);
      end

    // 计算golden（FP32精确累加，顺序与硬件一致）
    compute_gemv_golden(matrix, vector, rows, cols, golden_output);

    // SiLU融合：硬件在GEMV结果写回DDR之前就地过一遍silu()，golden同步后处理。
    // 注意只对最终结果做，不对中间部分和做——cols>64走多tile累加时，硬件也是
    // 等所有tile累加完才进S_SILU的
    if (silu_en) begin
      golden_pre_silu = new[rows];
      for (int i = 0; i < rows; i++) begin
        golden_pre_silu[i] = golden_output[i];   // 留一份GEMV原值供fp64对照用
        golden_output[i]   = silu_of(golden_output[i]);
      end
    end

    // 加载DDR
    for (int i = 0; i < cols; i++)
      ddr_write(VI_BASE_ADDR + i * 4, vector[i]);

    for (int r = 0; r < rows; r++)
      for (int c = 0; c < cols; c++)
        ddr_write(MI_BASE_ADDR + (r * cols + c) * 4, matrix[r * cols + c]);

    // 清除输出区域
    for (int i = 0; i < rows; i++)
      ddr_write(vo_base_addr + i * 4, 32'hDEAD_BEEF);

    // 配置CSR
    csr_write(REG_VI_BASE, VI_BASE_ADDR);
    csr_write(REG_MI_BASE, MI_BASE_ADDR);
    csr_write(REG_VO_BASE, vo_base_addr);
    csr_write(REG_ROWS, rows);
    csr_write(REG_COLS, cols);
    csr_write(REG_ACT_CTRL, silu_en ? 32'h1 : 32'h0);

    // 清 start 必须在预取之前：上一趟任务结束后 FSM 停在 S_DONE 等软件清 start，
    // 而 S_IDLE 里真任务优先于预取，start 不清则 pf_req 一直排队、PF_VALID 永远等不到。
    csr_write(REG_CTRL, 32'h0000_0000);

    // 预取夹在CSR配置和start之间——硬件用的就是刚配好的这份，不另存影子寄存器
    if (pf_mode != 0) do_prefetch();

    csr_write(REG_CTRL, 32'h0000_0001);

    // 等待完成：超时预算按行块×列tile数动态扩展，而不是固定200000。
    // 固定预算对rows/cols较大（需要多行块×多列tile）的场景不够用——
    // 实测rows=498,cols=170(16行块×3列tile=48次计算)超时后残留状态会
    // 拖累同一seq里紧邻的下一轮GEMV（级联失败），放宽到10倍后48次
    // 计算实际只用了约11000次poll，远小于放宽后的预算，验证并非硬件
    // 卡死，只是固定预算对大规模场景留的余量不够
    begin
      int num_row_blocks = (rows + 31) / 32;   // HW_ROWS=32
      int num_col_tiles  = (cols + 63) / 64;   // HW_COLS=64
      int timeout_cycles = 200000;
      int scaled_timeout = num_row_blocks * num_col_tiles * 50000;
      if (scaled_timeout > timeout_cycles) timeout_cycles = scaled_timeout;
      wait_done(timeout_cycles);
    end

    // 比对结果（相对误差容差 + 精度统计）
    error_count = 0;
    begin
      real max_rel_err = 0.0;
      real sum_rel_err = 0.0;
      int max_ulp = 0;
      for (int i = 0; i < rows; i++) begin
        logic [31:0] dut_val = ddr_read(vo_base_addr + i * 4);
        shortreal dut_f = $bitstoshortreal(dut_val);
        shortreal gld_f = $bitstoshortreal(golden_output[i]);
        real abs_err = (dut_f - gld_f) < 0 ? -(dut_f - gld_f) : (dut_f - gld_f);
        real denom = (gld_f < 0 ? -gld_f : gld_f) > 1e-6 ? (gld_f < 0 ? -gld_f : gld_f) : 1e-6;
        real rel_err = abs_err / denom;
        int ulp = fp32_ulp_diff(dut_val, golden_output[i]);

        if (rel_err > max_rel_err) max_rel_err = rel_err;
        sum_rel_err += rel_err;
        if (ulp > max_ulp) max_ulp = ulp;

        // FAIL阈值：相对误差>0.1%（GEMV精度要求高于FSA）
        if (rel_err > 0.001) begin
          error_count++;
          `uvm_error("GEMV_MISMATCH", $sformatf(
            "row[%0d]: DUT=0x%08h, Golden=0x%08h, rel_err=%.4f%%, ULP=%0d",
            i, dut_val, golden_output[i], rel_err*100.0, ulp))
        end
      end
      `uvm_info("GEMV_PRECISION", $sformatf(
        "精度统计: max_rel_err=%.6f%%, avg_rel_err=%.6f%%, max_ULP=%0d",
        max_rel_err*100.0, (sum_rel_err/rows)*100.0, max_ulp), UVM_MEDIUM)

      // SiLU附加统计：与fp64精确silu的偏差（信息性，不参与判定）。
      // 上面的判定用的是位级golden——它已经复现了硬件的PWL行为，所以残余误差
      // 只来自GEMV累加；这里再对fp64量一次，是为了确认PWL近似本身没有跑偏
      // （应落在4.69e-4量级，与算子级评估一致）。
      if (silu_en) begin
        real silu_max_rel = 0.0;
        real silu_sum_rel = 0.0;
        for (int i = 0; i < rows; i++) begin
          logic [31:0] dut_val = ddr_read(vo_base_addr + i * 4);
          shortreal dut_f = $bitstoshortreal(dut_val);
          shortreal ref_f = $bitstoshortreal(silu_ref_of(golden_pre_silu[i]));
          real d = (dut_f - ref_f) < 0 ? -(dut_f - ref_f) : (dut_f - ref_f);
          real den = (ref_f < 0 ? -ref_f : ref_f) > 1e-6 ? (ref_f < 0 ? -ref_f : ref_f) : 1e-6;
          real rr = d / den;
          if (rr > silu_max_rel) silu_max_rel = rr;
          silu_sum_rel += rr;
        end
        `uvm_info("SILU_PRECISION", $sformatf(
          "对fp64精确silu: max_rel=%.6f%%, avg_rel=%.6f%% (PWL固有约0.0469%%)",
          silu_max_rel*100.0, (silu_sum_rel/rows)*100.0), UVM_MEDIUM)
      end
    end

    if (error_count == 0)
      `uvm_info("GEMV_SEQ", $sformatf("PASS: rows=%0d, cols=%0d", rows, cols), UVM_MEDIUM)
    else
      `uvm_error("GEMV_SEQ", $sformatf("FAIL: %0d errors", error_count))
  endtask

  // ULP差值计算
  function automatic int fp32_ulp_diff(logic [31:0] a, logic [31:0] b);
    int signed ia, ib;
    ia = $signed(a);
    ib = $signed(b);
    // 处理负数的补码表示
    if (ia < 0) ia = 32'h80000000 - ia;
    if (ib < 0) ib = 32'h80000000 - ib;
    return (ia > ib) ? (ia - ib) : (ib - ia);
  endfunction

  // ULP容差比对
  function automatic bit fp32_ulp_match(logic [31:0] dut, logic [31:0] golden, int max_ulp);
    if (dut === golden) return 1;
    return fp32_ulp_diff(dut, golden) <= max_ulp;
  endfunction

endclass

// GEMV Sanity Sequence（32×64单tile）
class gemv_sanity_seq extends gemv_base_seq;

  `uvm_object_utils(gemv_sanity_seq)

  function new(string name = "gemv_sanity_seq");
    super.new(name);
    rows = 32;
    cols = 64;
    seed = 42;
  endfunction

endclass

// GEMV Directed Sequence（参数化，支持14个case）
class gemv_directed_seq extends gemv_base_seq;

  `uvm_object_utils(gemv_directed_seq)

  function new(string name = "gemv_directed_seq");
    super.new(name);
  endfunction

endclass

// GEMV Random Sequence（constrained random）
class gemv_random_seq extends gemv_base_seq;

  rand int unsigned rand_rows;
  rand int unsigned rand_cols;
  rand int unsigned rand_seed;

  constraint c_rows { rand_rows inside {[1:64]}; }
  constraint c_cols { rand_cols inside {[1:172]}; }

  constraint c_rows_dist {
    rand_rows dist {
      [1:8]   := 20,
      [9:31]  := 30,
      32      := 15,
      33      := 10,
      [34:63] := 15,
      64      := 10
    };
  }

  constraint c_cols_dist {
    rand_cols dist {
      [1:63]    := 20,
      64        := 15,
      [65:127]  := 20,
      128       := 10,
      [129:171] := 20,
      172       := 15
    };
  }

  `uvm_object_utils(gemv_random_seq)

  function new(string name = "gemv_random_seq");
    super.new(name);
  endfunction

  task body();
    rows = rand_rows;
    cols = rand_cols;
    seed = rand_seed;
    super.body();
  endtask

endclass

// GEMV Random Sequence（大行数区间：rows>64此前只在PL-05单点验证过，
// 这里补几个随机行数样本，覆盖65~511这段之前完全没做过golden验证的区间）
class gemv_random_bigrow_seq extends gemv_base_seq;

  rand int unsigned rand_rows;
  rand int unsigned rand_cols;
  rand int unsigned rand_seed;

  constraint c_rows { rand_rows inside {[65:511]}; }
  constraint c_cols { rand_cols inside {[1:172]}; }

  `uvm_object_utils(gemv_random_bigrow_seq)

  function new(string name = "gemv_random_bigrow_seq");
    super.new(name);
  endfunction

  task body();
    rows = rand_rows;
    cols = rand_cols;
    seed = rand_seed;
    super.body();
  endtask

endclass

`endif

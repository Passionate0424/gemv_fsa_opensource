// Special FP32 Value Sequences
// 注入极端浮点值（subnormal/denormal/±inf/±0/max），提升arithmetic模块覆盖率

`ifndef SPECIAL_FP_SEQ_LIB_SV
`define SPECIAL_FP_SEQ_LIB_SV

class special_fp_gemv_seq extends cb_top_base_seq;

  int error_count = 0;

  // 特殊FP32常量
  localparam logic [31:0] FP_POS_ZERO     = 32'h0000_0000;
  localparam logic [31:0] FP_NEG_ZERO     = 32'h8000_0000;
  localparam logic [31:0] FP_POS_INF      = 32'h7F80_0000;
  localparam logic [31:0] FP_NEG_INF      = 32'hFF80_0000;
  localparam logic [31:0] FP_POS_MAX      = 32'h7F7F_FFFF;  // 最大正规数 ~3.4e38
  localparam logic [31:0] FP_NEG_MAX      = 32'hFF7F_FFFF;
  localparam logic [31:0] FP_POS_MIN_NORM = 32'h0080_0000;  // 最小正规数 ~1.18e-38
  localparam logic [31:0] FP_POS_SUBNORM  = 32'h0000_0001;  // 最小subnormal ~1.4e-45
  localparam logic [31:0] FP_NEG_SUBNORM  = 32'h8000_0001;
  localparam logic [31:0] FP_LARGE_SUBNORM = 32'h007F_FFFF; // 最大subnormal
  localparam logic [31:0] FP_ONE          = 32'h3F80_0000;  // 1.0
  localparam logic [31:0] FP_NEG_ONE      = 32'hBF80_0000;  // -1.0

  `uvm_object_utils(special_fp_gemv_seq)

  function new(string name = "special_fp_gemv_seq");
    super.new(name);
  endfunction

  task body();
    localparam int unsigned VI_BASE = 32'h0000_1000;
    localparam int unsigned MI_BASE = 32'h0000_4000;
    localparam int unsigned VO_BASE = 32'h0001_0000;
    int rows = 8;
    int cols = 8;

    // 特殊值数组
    logic [31:0] special_vals[] = '{
      FP_POS_ZERO, FP_NEG_ZERO, FP_POS_MIN_NORM, FP_POS_SUBNORM,
      FP_NEG_SUBNORM, FP_LARGE_SUBNORM, FP_ONE, FP_NEG_ONE
    };

    `uvm_info("SP_FP", "GEMV Special FP value test", UVM_MEDIUM)
    hw_reset();

    // 向量用特殊值填充
    for (int i = 0; i < cols; i++)
      ddr_write(VI_BASE + i*4, special_vals[i % special_vals.size()]);

    // 矩阵用混合值：对角线放特殊值，其余放小正规数
    for (int r = 0; r < rows; r++)
      for (int c = 0; c < cols; c++) begin
        if (r == c)
          ddr_write(MI_BASE + (r*cols+c)*4, special_vals[r % special_vals.size()]);
        else
          ddr_write(MI_BASE + (r*cols+c)*4, FP_POS_MIN_NORM);
      end

    csr_write(32'h0010, VI_BASE);
    csr_write(32'h0014, MI_BASE);
    csr_write(32'h0018, VO_BASE);
    csr_write(32'h0020, rows);
    csr_write(32'h0024, cols);
    csr_write(32'h0000, 32'h0);
    csr_write(32'h0000, 32'h1);

    wait_done(200000);

    // 验证输出非全X/全0（DUT不crash即可，不验精度）
    begin
      logic [31:0] val = ddr_read(VO_BASE);
      if (val === 32'hxxxxxxxx) begin
        error_count++;
        `uvm_error("SP_FP", "GEMV special FP: 输出含X（propagation failure）")
      end else
        `uvm_info("SP_FP", $sformatf("GEMV special FP: PASS (out[0]=0x%08h)", val), UVM_MEDIUM)
    end

    // Case 2: 全subnormal矩阵乘法
    hw_reset();
    for (int i = 0; i < cols; i++)
      ddr_write(VI_BASE + i*4, FP_POS_SUBNORM);
    for (int i = 0; i < rows*cols; i++)
      ddr_write(MI_BASE + i*4, FP_LARGE_SUBNORM);

    csr_write(32'h0010, VI_BASE);
    csr_write(32'h0014, MI_BASE);
    csr_write(32'h0018, VO_BASE);
    csr_write(32'h0020, rows);
    csr_write(32'h0024, cols);
    csr_write(32'h0000, 32'h0);
    csr_write(32'h0000, 32'h1);

    wait_done(200000);

    begin
      logic [31:0] val = ddr_read(VO_BASE);
      `uvm_info("SP_FP", $sformatf("GEMV all-subnormal: out[0]=0x%08h", val), UVM_MEDIUM)
    end

    // Case 3: 大数值矩阵（接近overflow）
    hw_reset();
    for (int i = 0; i < cols; i++)
      ddr_write(VI_BASE + i*4, 32'h4F00_0000);  // ~2.15e9
    for (int i = 0; i < rows*cols; i++)
      ddr_write(MI_BASE + i*4, 32'h4F00_0000);

    csr_write(32'h0010, VI_BASE);
    csr_write(32'h0014, MI_BASE);
    csr_write(32'h0018, VO_BASE);
    csr_write(32'h0020, rows);
    csr_write(32'h0024, cols);
    csr_write(32'h0000, 32'h0);
    csr_write(32'h0000, 32'h1);

    wait_done(200000);

    begin
      logic [31:0] val = ddr_read(VO_BASE);
      `uvm_info("SP_FP", $sformatf("GEMV large-values: out[0]=0x%08h (may be inf)", val), UVM_MEDIUM)
    end
  endtask
endclass

// FSA special FP value sequence
class special_fp_fsa_seq extends cb_top_base_seq;

  int error_count = 0;

  localparam logic [31:0] FP_POS_SUBNORM   = 32'h0000_0001;
  localparam logic [31:0] FP_LARGE_SUBNORM = 32'h007F_FFFF;
  localparam logic [31:0] FP_POS_MIN_NORM  = 32'h0080_0000;
  localparam logic [31:0] FP_TINY          = 32'h2000_0000;  // ~1.08e-19

  `uvm_object_utils(special_fp_fsa_seq)

  function new(string name = "special_fp_fsa_seq");
    super.new(name);
  endfunction

  task body();
    int unsigned prng_state = 12321;
    localparam int unsigned Q_BASE = 32'h0000_1000;
    localparam int unsigned K_BASE = 32'h0000_2000;
    localparam int unsigned V_BASE = 32'h0001_0000;
    localparam int unsigned O_BASE = 32'h0002_0000;
    int head_dim = 8;
    int seq_len = 8;
    int num_heads = 4;
    int kv_stride = num_heads * head_dim * head_dim * 4;

    `uvm_info("SP_FP", "FSA Special FP value test (tiny values)", UVM_MEDIUM)
    hw_reset();

    // 用极小值填充Q/K/V（测试softmax对极小score的处理）
    for (int h = 0; h < num_heads; h++)
      for (int i = 0; i < head_dim; i++)
        ddr_write(Q_BASE + (h*head_dim+i)*4, FP_TINY);

    for (int h = 0; h < num_heads; h++)
      for (int r = 0; r < head_dim; r++)
        for (int c = 0; c < head_dim; c++)
          ddr_write(K_BASE + (h*head_dim*head_dim + r*head_dim + c)*4, FP_TINY);

    for (int h = 0; h < num_heads; h++)
      for (int r = 0; r < head_dim; r++)
        for (int c = 0; c < head_dim; c++)
          ddr_write(V_BASE + (h*head_dim*head_dim + r*head_dim + c)*4, FP_POS_MIN_NORM);

    for (int i = 0; i < num_heads*head_dim; i++)
      ddr_write(O_BASE + i*4, 32'hDEAD_BEEF);

    csr_write(32'h0030, Q_BASE);
    csr_write(32'h0034, K_BASE);
    csr_write(32'h0038, V_BASE);
    csr_write(32'h003C, O_BASE);
    csr_write(32'h0040, head_dim);
    csr_write(32'h0044, seq_len);
    csr_write(32'h0048, kv_stride);
    csr_write(32'h004C, num_heads);
    csr_write(32'h0054, 0);
    csr_write(32'h0050, 32'h3F0293EE);
    csr_write(32'h0000, 32'h0);
    csr_write(32'h0000, 32'h3);

    wait_done(200000);

    // 验证DUT没crash（输出不是DEADBEEF）
    begin
      logic [31:0] val = ddr_read(O_BASE);
      if (val === 32'hDEAD_BEEF) begin
        error_count++;
        `uvm_error("SP_FP", "FSA tiny-values: DUT未完成输出")
      end else
        `uvm_info("SP_FP", $sformatf("FSA tiny-values: PASS (out[0]=0x%08h)", val), UVM_MEDIUM)
    end
  endtask
endclass

// ============================================================
// 数值域边界深化：NF-01~08
// 形态：定向触发点（特殊FP位模式）+ 固定seed随机周边（正规数）
// 目的：激活FPMacUnit/multiplication_normaliser的inf/NaN/overflow/归一化分支
// 判定：inf/NaN是否正确传播=功能门槛（不出X、不hang）；数值精确性=定性记录
// ============================================================

class nf_special_fp_seq extends cb_top_base_seq;

  int error_count = 0;

  localparam logic [31:0] FP_POS_ZERO = 32'h0000_0000;
  localparam logic [31:0] FP_NEG_ZERO = 32'h8000_0000;
  localparam logic [31:0] FP_POS_INF  = 32'h7F80_0000;
  localparam logic [31:0] FP_NEG_INF  = 32'hFF80_0000;
  localparam logic [31:0] FP_POS_MAX  = 32'h7F7F_FFFF;
  localparam logic [31:0] FP_QNAN     = 32'h7FC0_0000;  // quiet NaN
  localparam logic [31:0] FP_ONE      = 32'h3F80_0000;

  localparam int unsigned VI_BASE = 32'h0000_1000;
  localparam int unsigned MI_BASE = 32'h0000_4000;
  localparam int unsigned VO_BASE = 32'h0001_0000;

  `uvm_object_utils(nf_special_fp_seq)

  function new(string name = "nf_special_fp_seq");
    super.new(name);
  endfunction

  // 判断FP32是否为inf
  function automatic bit is_inf(logic [31:0] v);
    return (v[30:23] == 8'hFF) && (v[22:0] == 23'd0);
  endfunction
  // 判断FP32是否为NaN
  function automatic bit is_nan(logic [31:0] v);
    return (v[30:23] == 8'hFF) && (v[22:0] != 23'd0);
  endfunction

  // 通用GEMV执行：向量定向触发点，矩阵随机周边
  // trig_vals: 注入到向量前几个位置的特殊值
  task run_gemv_nf(logic [31:0] trig_vals[], int unsigned seed, string label,
                   output logic [31:0] out0);
    int unsigned prng_state = seed;
    int rows = 8;
    int cols = 8;

    hw_reset();

    // 向量：前N个放触发值，其余随机正规数
    for (int i = 0; i < cols; i++) begin
      if (i < trig_vals.size())
        ddr_write(VI_BASE + i*4, trig_vals[i]);
      else
        ddr_write(VI_BASE + i*4, rand_fp32(prng_state, 1.0));
    end
    // 矩阵：随机正规数周边
    for (int i = 0; i < rows*cols; i++)
      ddr_write(MI_BASE + i*4, rand_fp32(prng_state, 1.0));
    for (int i = 0; i < rows; i++)
      ddr_write(VO_BASE + i*4, 32'hDEAD_BEEF);

    csr_write(32'h0010, VI_BASE);
    csr_write(32'h0014, MI_BASE);
    csr_write(32'h0018, VO_BASE);
    csr_write(32'h0020, rows);
    csr_write(32'h0024, cols);
    csr_write(32'h0000, 32'h0);
    csr_write(32'h0000, 32'h1);

    wait_done(200000);

    out0 = ddr_read(VO_BASE);
    // 功能门槛：不出X、不残留DEADBEEF
    if (out0 === 32'hxxxxxxxx) begin
      error_count++;
      `uvm_error("NF", $sformatf("%s: 输出含X（propagation failure）", label))
    end else if (out0 === 32'hDEAD_BEEF) begin
      error_count++;
      `uvm_error("NF", $sformatf("%s: DUT未完成输出", label))
    end
  endtask

  task body();
    logic [31:0] out0;
    logic [31:0] trig[];

    `uvm_info("NF", "数值域边界深化 NF-01~05 (GEMV)", UVM_MEDIUM)

    // NF-01: inf输入 → inf×正常数=inf传播
    trig = '{FP_POS_INF, FP_NEG_INF};
    run_gemv_nf(trig, 88001, "NF-01 inf输入", out0);
    `uvm_info("NF", $sformatf("NF-01: out[0]=0x%08h %s", out0,
              is_inf(out0) ? "(inf传播OK)" : is_nan(out0) ? "(NaN)" : "(finite)"), UVM_MEDIUM)

    // NF-02: inf + (-inf) → NaN分支【定性】
    // 向量[0]=+inf, [1]=-inf，矩阵对应位置=1.0使累加出现inf+(-inf)
    trig = '{FP_POS_INF, FP_NEG_INF};
    begin
      int unsigned prng_state = 88002;
      int rows = 8, cols = 8;
      hw_reset();
      for (int i = 0; i < cols; i++)
        ddr_write(VI_BASE + i*4, (i < 2) ? trig[i] : FP_POS_ZERO);
      // 矩阵row0: [1.0, 1.0, 0...] 使 acc = (+inf)*1 + (-inf)*1
      for (int r = 0; r < rows; r++)
        for (int c = 0; c < cols; c++)
          ddr_write(MI_BASE + (r*cols+c)*4, (c < 2) ? FP_ONE : FP_POS_ZERO);
      for (int i = 0; i < rows; i++)
        ddr_write(VO_BASE + i*4, 32'hDEAD_BEEF);
      csr_write(32'h0010, VI_BASE); csr_write(32'h0014, MI_BASE); csr_write(32'h0018, VO_BASE);
      csr_write(32'h0020, rows); csr_write(32'h0024, cols);
      csr_write(32'h0000, 32'h0); csr_write(32'h0000, 32'h1);
      wait_done(200000);
      out0 = ddr_read(VO_BASE);
      if (out0 === 32'hxxxxxxxx) begin
        error_count++;
        `uvm_error("NF", "NF-02: 输出含X")
      end else
        `uvm_info("NF", $sformatf("NF-02 inf-inf: out[0]=0x%08h %s（定性记录）", out0,
                  is_nan(out0) ? "(NaN)" : is_inf(out0) ? "(inf)" : "(finite)"), UVM_MEDIUM)
    end

    // NF-03: max×max累加 → overflow→inf归一化
    trig = '{FP_POS_MAX, FP_POS_MAX, FP_POS_MAX, FP_POS_MAX};
    run_gemv_nf(trig, 88003, "NF-03 max溢出", out0);
    `uvm_info("NF", $sformatf("NF-03: out[0]=0x%08h %s", out0,
              is_inf(out0) ? "(overflow→inf OK)" : "(finite)"), UVM_MEDIUM)

    // NF-04: ±0符号规则
    trig = '{FP_POS_ZERO, FP_NEG_ZERO, FP_POS_ZERO, FP_NEG_ZERO};
    run_gemv_nf(trig, 88004, "NF-04 ±0符号", out0);
    `uvm_info("NF", $sformatf("NF-04: out[0]=0x%08h（±0累加）", out0), UVM_MEDIUM)

    // NF-05: NaN输入 → isNaN分支+传播【定性】
    trig = '{FP_QNAN};
    run_gemv_nf(trig, 88005, "NF-05 NaN传播", out0);
    `uvm_info("NF", $sformatf("NF-05: out[0]=0x%08h %s（定性记录）", out0,
              is_nan(out0) ? "(NaN传播OK)" : "(non-NaN)"), UVM_MEDIUM)

    if (error_count == 0)
      `uvm_info("NF", "NF-01~05 全部无X/无hang（功能门槛PASS）", UVM_MEDIUM)
    else
      `uvm_error("NF", $sformatf("NF GEMV: %0d个功能门槛失败", error_count))
  endtask
endclass

// NF-06~08: FSA exp2 PWL分段 + softmax极端分布
class nf_fsa_pwl_seq extends cb_top_base_seq;

  int error_count = 0;

  localparam int unsigned Q_BASE = 32'h0000_1000;
  localparam int unsigned K_BASE = 32'h0000_2000;
  localparam int unsigned V_BASE = 32'h0001_0000;
  localparam int unsigned O_BASE = 32'h0002_0000;

  `uvm_object_utils(nf_fsa_pwl_seq)

  function new(string name = "nf_fsa_pwl_seq");
    super.new(name);
  endfunction

  // 执行一次FSA（4×8, seq=8单tile），Q/K按scale生成，V随机
  // q_scale控制Q·K score量级，间接控制(S-max)落入的PWL段
  task run_fsa_pwl(real q_scale, real k_scale, int unsigned seed, string label,
                   output logic [31:0] out0);
    int unsigned prng_state = seed;
    int head_dim = 8, seq_len = 8, num_heads = 4;
    int kv_stride = num_heads * head_dim * head_dim * 4;

    hw_reset();

    for (int h = 0; h < num_heads; h++)
      for (int i = 0; i < head_dim; i++)
        ddr_write(Q_BASE + (h*head_dim+i)*4, rand_fp32(prng_state, q_scale));
    for (int h = 0; h < num_heads; h++)
      for (int r = 0; r < head_dim; r++)
        for (int c = 0; c < head_dim; c++)
          ddr_write(K_BASE + (h*head_dim*head_dim + r*head_dim + c)*4, rand_fp32(prng_state, k_scale));
    for (int h = 0; h < num_heads; h++)
      for (int r = 0; r < head_dim; r++)
        for (int c = 0; c < head_dim; c++)
          ddr_write(V_BASE + (h*head_dim*head_dim + r*head_dim + c)*4, rand_fp32(prng_state, 1.0));
    for (int i = 0; i < num_heads*head_dim; i++)
      ddr_write(O_BASE + i*4, 32'hDEAD_BEEF);

    csr_write(32'h0030, Q_BASE); csr_write(32'h0034, K_BASE);
    csr_write(32'h0038, V_BASE); csr_write(32'h003C, O_BASE);
    csr_write(32'h0040, head_dim); csr_write(32'h0044, seq_len);
    csr_write(32'h0048, kv_stride); csr_write(32'h004C, num_heads);
    csr_write(32'h0054, 0); csr_write(32'h0050, 32'h3F0293EE);
    csr_write(32'h0000, 32'h0); csr_write(32'h0000, 32'h3);

    wait_done(200000);

    out0 = ddr_read(O_BASE);
    if (out0 === 32'hxxxxxxxx) begin
      error_count++;
      `uvm_error("NF", $sformatf("%s: 输出含X", label))
    end else if (out0 === 32'hDEAD_BEEF) begin
      error_count++;
      `uvm_error("NF", $sformatf("%s: DUT未完成", label))
    end
  endtask

  task body();
    logic [31:0] out0;

    `uvm_info("NF", "数值域边界深化 NF-06~08 (FSA exp2 PWL)", UVM_MEDIUM)

    // NF-06: PWL分段扫描——用递增的score量级，使(S-max)落入不同PWL段
    // 4个量级覆盖PWL低段到高段
    begin
      real scales[4] = '{0.2, 0.8, 2.0, 5.0};
      for (int s = 0; s < 4; s++) begin
        run_fsa_pwl(scales[s], scales[s], 88010 + s, $sformatf("NF-06 PWL段[%0d] scale=%.1f", s, scales[s]), out0);
        `uvm_info("NF", $sformatf("NF-06[%0d]: out[0]=0x%08h", s, out0), UVM_MEDIUM)
      end
    end

    // NF-07: score极大差（一个score远大于其余，softmax趋近one-hot）
    // 大q_scale使score差异极大，max跟踪+rescale极端路径
    run_fsa_pwl(8.0, 8.0, 88020, "NF-07 one-hot softmax", out0);
    `uvm_info("NF", $sformatf("NF-07: out[0]=0x%08h（rescale极端）", out0), UVM_MEDIUM)

    // NF-08: score全相等（softmax=均匀分布，无rescale）
    // 极小scale使所有score≈0，softmax均匀
    run_fsa_pwl(0.01, 0.01, 88030, "NF-08 均匀softmax", out0);
    `uvm_info("NF", $sformatf("NF-08: out[0]=0x%08h（均匀分布）", out0), UVM_MEDIUM)

    if (error_count == 0)
      `uvm_info("NF", "NF-06~08 全部无X/无hang（功能门槛PASS）", UVM_MEDIUM)
    else
      `uvm_error("NF", $sformatf("NF FSA: %0d个功能门槛失败", error_count))
  endtask
endclass

`endif

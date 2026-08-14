// 硬件容量/位宽上限边界Sequence Library
// 打满seq_len/rows/cols/head_dim的物理位宽与容量上限，确认三种结局之一：
//   ① 正常处理 ② 优雅截断/拒绝 ③ 静默溢出错误（签核要抓的缺陷）
// 定性case（PL-02/05/06/07）：记录DUT实际行为，仅在hang或X传播时判FAIL。
// 功能case（PL-01/03/04）：期望正常完成（不hang、不出X）。
//
// 地址约束：仿真DDR模型（tb_axi_ram_sp_ext）MEM_AW=24 → 深度2^24 word = 64MB
//   字节空间（byte_addr ≤ 0x3FFFFFF）。tb_top实例化时已将MEM_AW覆写为24，
//   足以容纳硬件真实上限（127 tiles 1×32 K+V约1MB、GEMV大列大行）。地址映射：
//     Q/VI = 0x00010000, K/MI = 0x00100000, V = 0x00800000, O/VO = 0x01000000

`ifndef PERF_LIMIT_SEQ_LIB_SV
`define PERF_LIMIT_SEQ_LIB_SV

// 统一地址映射（64MB DDR内，各区间隔足够大避免K/V/O重叠）
`define PL_Q_BASE  32'h0001_0000
`define PL_K_BASE  32'h0010_0000
`define PL_V_BASE  32'h0080_0000
`define PL_O_BASE  32'h0100_0000

// ============================================================
// PL-01: 大seq_len多tile（1×32, seq_len=4064 → 127 tiles）
// 意图：tile计数器（13-bit）在硬件真实上限127 tiles时不溢出、FSM正常收尾，
// 且127 tile累加下的输出仍与软件黄金模型数值一致（原实现只查NaN/Inf/未写回，
// 现补上DPI-C golden比对，填补seq_len>511后再无精确验证的空白）
// ============================================================
class pl_big_seq_tiles_seq extends cb_top_base_seq;
  `uvm_object_utils(pl_big_seq_tiles_seq)

  function new(string name = "pl_big_seq_tiles_seq");
    super.new(name);
  endfunction

  task body();
    int unsigned prng_state = 77001;
    int head_dim = 32;
    int num_heads = 1;
    int seq_tile_len = 32;
    int seq_len = 4064;  // 127 tiles（硬件真实上限）
    int num_tiles = (seq_len + seq_tile_len - 1) / seq_tile_len;
    int kv_stride = num_heads * seq_tile_len * head_dim * 4;  // 4096B/tile
    logic [31:0] val;
    int deadbeef_cnt = 0;
    int errs = 0;

    `uvm_info("PL", $sformatf("PL-01 大seq多tile: seq_len=%0d, tiles=%0d (1x32)", seq_len, num_tiles), UVM_MEDIUM)
    hw_reset();

    dpi_e2e_init(head_dim, seq_len, num_heads);

    for (int i = 0; i < head_dim; i++) begin
      val = rand_fp32(prng_state, 0.3);
      ddr_write(`PL_Q_BASE + i*4, val);
      dpi_e2e_set_q(0, i, val);
    end

    for (int t = 0; t < num_tiles; t++)
      for (int r = 0; r < seq_tile_len; r++)
        for (int c = 0; c < head_dim; c++) begin
          logic [31:0] kv;
          kv = rand_fp32(prng_state, 0.3);
          ddr_write(`PL_K_BASE + t*kv_stride + (r*head_dim + c)*4, kv);
          dpi_e2e_set_k(0, t*seq_tile_len+r, c, kv);
          kv = rand_fp32(prng_state, 0.3);
          ddr_write(`PL_V_BASE + t*kv_stride + (r*head_dim + c)*4, kv);
          dpi_e2e_set_v(0, t*seq_tile_len+r, c, kv);
        end

    for (int i = 0; i < head_dim; i++)
      ddr_write(`PL_O_BASE + i*4, 32'hDEAD_BEEF);

    dpi_e2e_compute();

    csr_write(32'h0030, `PL_Q_BASE);
    csr_write(32'h0034, `PL_K_BASE);
    csr_write(32'h0038, `PL_V_BASE);
    csr_write(32'h003C, `PL_O_BASE);
    csr_write(32'h0040, head_dim);
    csr_write(32'h0044, seq_len);
    csr_write(32'h0048, kv_stride);
    csr_write(32'h004C, num_heads);
    csr_write(32'h0054, 2);              // 1×32
    csr_write(32'h0050, 32'h3E8293EE);   // ATTN_SCALE for dim=32
    csr_write(32'h0000, 32'h0);
    csr_write(32'h0000, 32'h3);

    wait_done(20000000);

    for (int i = 0; i < head_dim; i++) begin
      val = ddr_read(`PL_O_BASE + i*4);
      if (val === 32'hDEAD_BEEF) deadbeef_cnt++;
    end
    if (deadbeef_cnt > 0) begin
      `uvm_error("PL", $sformatf("PL-01: %0d/%0d 输出未写回（FSM未收尾，疑似tile计数器问题）", deadbeef_cnt, head_dim))
    end else begin
      for (int i = 0; i < head_dim; i++) begin
        logic [31:0] dut_val = ddr_read(`PL_O_BASE + i*4);
        errs += dpi_e2e_compare(0, i, dut_val);
      end
      dpi_e2e_report();
      if (errs == 0)
        `uvm_info("PL", "PL-01 完成: FSM正常收尾, 127 tile累加结果与golden一致", UVM_MEDIUM)
      else
        `uvm_error("PL", $sformatf("PL-01: FAIL %0d 处与golden不符（127 tile累加误差）", errs))
    end
  endtask
endclass

// ============================================================
// PL-02: seq_len截断点（seq_len=4096 → [11:0]截断成0）【定性】
// 意图：12-bit截断陷阱，观察DUT对"截断后seq_len=0"的行为
// ============================================================
class pl_seqlen_trunc_seq extends cb_top_base_seq;
  `uvm_object_utils(pl_seqlen_trunc_seq)

  function new(string name = "pl_seqlen_trunc_seq");
    super.new(name);
  endfunction

  task body();
    int unsigned prng_state = 77002;
    logic [31:0] status;
    int timeout = 100000;
    bit responded = 0;

    `uvm_info("PL", "PL-02 seq_len截断点: SEQ_LEN=4096 (0x1000, [11:0]截断为0)【定性】", UVM_MEDIUM)
    hw_reset();

    // 提供1 tile的合法数据（截断后行为未定，仍需地址合法避免越界X干扰）
    for (int i = 0; i < 32; i++)
      ddr_write(`PL_Q_BASE + i*4, rand_fp32(prng_state, 0.3));
    for (int r = 0; r < 32; r++)
      for (int c = 0; c < 32; c++) begin
        ddr_write(`PL_K_BASE + (r*32+c)*4, rand_fp32(prng_state, 0.3));
        ddr_write(`PL_V_BASE + (r*32+c)*4, rand_fp32(prng_state, 0.3));
      end

    csr_write(32'h0030, `PL_Q_BASE);
    csr_write(32'h0034, `PL_K_BASE);
    csr_write(32'h0038, `PL_V_BASE);
    csr_write(32'h003C, `PL_O_BASE);
    csr_write(32'h0040, 32'd32);         // head_dim=32
    csr_write(32'h0044, 32'd4096);       // SEQ_LEN=4096 → [11:0]=0
    csr_write(32'h0048, 32'd4096);
    csr_write(32'h004C, 32'd1);
    csr_write(32'h0054, 32'd2);
    csr_write(32'h0050, 32'h3E8293EE);
    csr_write(32'h0000, 32'h0);
    csr_write(32'h0000, 32'h3);

    for (int i = 0; i < timeout; i++) begin
      csr_read(32'h0004, status);
      if (status[1] || status[0] == 0) begin
        responded = 1;
        `uvm_info("PL", $sformatf("PL-02: DUT响应 (status=0x%08h) after %0d polls — 记录行为供签核", status, i), UVM_MEDIUM)
        break;
      end
    end
    if (!responded)
      `uvm_error("PL", "PL-02: DUT HANG（seq_len截断为0导致死锁，需RTL保护）")
  endtask
endclass

// ============================================================
// PL-03: 大seq_len（seq_len=2048 → 64 tiles，覆盖11-bit位宽满值附近）
// 意图：验证11→12 bit边界附近的tile计数功能正确
// ============================================================
class pl_seqlen_max_seq extends cb_top_base_seq;
  `uvm_object_utils(pl_seqlen_max_seq)

  function new(string name = "pl_seqlen_max_seq");
    super.new(name);
  endfunction

  task body();
    int unsigned prng_state = 77003;
    int head_dim = 32;
    int seq_tile_len = 32;
    int seq_len = 2048;  // 64 tiles（11-bit边界，仿真可容纳）
    int num_tiles = (seq_len + seq_tile_len - 1) / seq_tile_len;
    int kv_stride = seq_tile_len * head_dim * 4;
    logic [31:0] val;
    bit any_written = 0;

    `uvm_info("PL", $sformatf("PL-03 大seq: seq_len=2048, tiles=%0d (11-bit边界)", num_tiles), UVM_MEDIUM)
    hw_reset();

    for (int i = 0; i < head_dim; i++)
      ddr_write(`PL_Q_BASE + i*4, rand_fp32(prng_state, 0.3));
    for (int t = 0; t < num_tiles; t++)
      for (int r = 0; r < seq_tile_len; r++)
        for (int c = 0; c < head_dim; c++) begin
          ddr_write(`PL_K_BASE + t*kv_stride + (r*head_dim + c)*4, rand_fp32(prng_state, 0.3));
          ddr_write(`PL_V_BASE + t*kv_stride + (r*head_dim + c)*4, rand_fp32(prng_state, 0.3));
        end
    for (int i = 0; i < head_dim; i++)
      ddr_write(`PL_O_BASE + i*4, 32'hDEAD_BEEF);

    csr_write(32'h0030, `PL_Q_BASE);
    csr_write(32'h0034, `PL_K_BASE);
    csr_write(32'h0038, `PL_V_BASE);
    csr_write(32'h003C, `PL_O_BASE);
    csr_write(32'h0040, head_dim);
    csr_write(32'h0044, seq_len);
    csr_write(32'h0048, kv_stride);
    csr_write(32'h004C, 32'd1);
    csr_write(32'h0054, 32'd2);
    csr_write(32'h0050, 32'h3E8293EE);
    csr_write(32'h0000, 32'h0);
    csr_write(32'h0000, 32'h3);

    wait_done(20000000);

    for (int i = 0; i < head_dim; i++) begin
      val = ddr_read(`PL_O_BASE + i*4);
      if (val !== 32'hDEAD_BEEF) any_written = 1;
    end
    if (!any_written)
      `uvm_error("PL", "PL-03: 输出全未写回（FSM未收尾）")
    else
      `uvm_info("PL", "PL-03: FSM正常收尾（64 tiles功能OK）", UVM_MEDIUM)
  endtask
endclass

// ============================================================
// PL-04: GEMV大列（cols扫描到硬件真实上限）
// 意图：确认GEMV列tiling的真实cols上限（stride 11-bit=2047B → cols≤511）
// ============================================================
class pl_gemv_bigcol_seq extends cb_top_base_seq;
  `uvm_object_utils(pl_gemv_bigcol_seq)

  function new(string name = "pl_gemv_bigcol_seq");
    super.new(name);
  endfunction

  // 参数化GEMV：跑指定cols，返回error_count（rel_err>1%的行数）+ x_cnt
  // expect_fail=1时（cols>511越界），误差用info记录而非uvm_error（预期越界，不判FAIL）
  task run_gemv_cols(int cols, string label, bit expect_fail, output int error_count, output int x_cnt);
    int unsigned prng_state = 77004 + cols;
    int rows = 32;
    logic [31:0] matrix [];
    logic [31:0] vector [];
    logic [31:0] golden [];
    real max_rel_err = 0.0;
    error_count = 0;
    x_cnt = 0;

    `uvm_info("PL", $sformatf("%s: rows=%0d, cols=%0d (stride_bytes=%0d)", label, rows, cols, cols*4), UVM_MEDIUM)
    hw_reset();

    matrix = new[rows*cols];
    vector = new[cols];
    golden = new[rows];

    for (int i = 0; i < cols; i++)
      vector[i] = rand_fp32(prng_state, 1.0);
    for (int r = 0; r < rows; r++)
      for (int c = 0; c < cols; c++)
        matrix[r*cols + c] = rand_fp32(prng_state, 1.0);

    for (int r = 0; r < rows; r++) begin
      shortreal acc = 0.0;
      for (int c = 0; c < cols; c++)
        acc = acc + $bitstoshortreal(matrix[r*cols+c]) * $bitstoshortreal(vector[c]);
      golden[r] = $shortrealtobits(acc);
    end

    for (int i = 0; i < cols; i++)
      ddr_write(`PL_Q_BASE + i*4, vector[i]);
    for (int r = 0; r < rows; r++)
      for (int c = 0; c < cols; c++)
        ddr_write(`PL_K_BASE + (r*cols+c)*4, matrix[r*cols+c]);
    for (int i = 0; i < rows; i++)
      ddr_write(`PL_O_BASE + i*4, 32'hDEAD_BEEF);

    csr_write(32'h0010, `PL_Q_BASE);   // VI
    csr_write(32'h0014, `PL_K_BASE);   // MI
    csr_write(32'h0018, `PL_O_BASE);   // VO
    csr_write(32'h0020, rows);
    csr_write(32'h0024, cols);
    csr_write(32'h0000, 32'h0);
    csr_write(32'h0000, 32'h1);

    wait_done(2000000);

    for (int i = 0; i < rows; i++) begin
      logic [31:0] dut_val = ddr_read(`PL_O_BASE + i*4);
      shortreal dut_f, gld_f;
      real abs_err, denom, rel_err;
      if (dut_val === 32'hxxxxxxxx) begin
        x_cnt++;
        continue;
      end
      dut_f = $bitstoshortreal(dut_val);
      gld_f = $bitstoshortreal(golden[i]);
      abs_err = (dut_f - gld_f) < 0 ? -(dut_f - gld_f) : (dut_f - gld_f);
      denom = (gld_f < 0 ? -gld_f : gld_f) > 1e-6 ? (gld_f < 0 ? -gld_f : gld_f) : 1e-6;
      rel_err = abs_err / denom;
      if (rel_err > max_rel_err) max_rel_err = rel_err;
      if (rel_err > 0.01) begin
        error_count++;
        if (error_count <= 3) begin
          if (expect_fail)
            `uvm_info("PL", $sformatf("%s row[%0d]: DUT=0x%08h Golden=0x%08h rel=%.4f%%（预期越界，cols>511）",
                      label, i, dut_val, golden[i], rel_err*100.0), UVM_MEDIUM)
          else
            `uvm_error("PL", $sformatf("%s row[%0d]: DUT=0x%08h Golden=0x%08h rel=%.4f%%",
                       label, i, dut_val, golden[i], rel_err*100.0))
        end
      end
    end
    `uvm_info("PL", $sformatf("%s: err=%0d x=%0d max_rel_err=%.4f%%", label, error_count, x_cnt, max_rel_err*100.0), UVM_MEDIUM)
  endtask

  task body();
    int err_256, x_256, err_511, x_511, err_512, x_512;

    // cols扫描：256/511（stride<2048安全）vs 512（stride=2048溢出11-bit）
    `uvm_info("PL", "PL-04 GEMV大列cols扫描: 256 / 511(安全) / 512(触发stride溢出)", UVM_MEDIUM)

    run_gemv_cols(256, "PL-04a cols=256", 1'b0, err_256, x_256);
    run_gemv_cols(511, "PL-04b cols=511", 1'b0, err_511, x_511);
    run_gemv_cols(512, "PL-04c cols=512", 1'b1, err_512, x_512);  // cols>511越界，预期FAIL

    `uvm_info("PL", $sformatf("对照: cols=256[err=%0d x=%0d] 511[err=%0d x=%0d] 512[err=%0d x=%0d]",
              err_256, x_256, err_511, x_511, err_512, x_512), UVM_MEDIUM)
    if ((err_511 == 0 && x_511 == 0) && (err_512 > 0 || x_512 > 0))
      `uvm_info("PL", "PL-04 结论: 511 PASS / 512 FAIL → cmd_stride 11-bit位宽上限=511列（真实容量边界）", UVM_MEDIUM)
  endtask
endclass

// ============================================================
// PL-05: GEMV大行（rows=256, cols=64）
// 意图：ROWS无硬件tiling上限保护，验证256行时结果与软件黄金模型逐行一致
// （原实现只查X传播、不比对数值，"验证正确性"名不副实，现补上golden比对）
// ============================================================
class pl_gemv_bigrow_seq extends cb_top_base_seq;
  `uvm_object_utils(pl_gemv_bigrow_seq)

  function new(string name = "pl_gemv_bigrow_seq");
    super.new(name);
  endfunction

  task body();
    int unsigned prng_state = 77005;
    int rows = 256;
    int cols = 64;
    logic [31:0] vector [] = new[cols];
    logic [31:0] matrix [] = new[rows*cols];
    logic [31:0] golden [];
    logic [31:0] dut_out [] = new[rows];
    int x_cnt = 0;
    int errs;

    `uvm_info("PL", "PL-05 GEMV大行: rows=256, cols=64（ROWS无硬件上限保护，验证数值正确性）", UVM_MEDIUM)
    hw_reset();

    for (int i = 0; i < cols; i++) begin
      vector[i] = rand_fp32(prng_state, 1.0);
      ddr_write(`PL_Q_BASE + i*4, vector[i]);
    end
    for (int i = 0; i < rows*cols; i++) begin
      matrix[i] = rand_fp32(prng_state, 1.0);
      ddr_write(`PL_K_BASE + i*4, matrix[i]);
    end
    for (int i = 0; i < rows; i++)
      ddr_write(`PL_O_BASE + i*4, 32'hDEAD_BEEF);
    compute_gemv_golden(matrix, vector, rows, cols, golden);

    csr_write(32'h0010, `PL_Q_BASE);
    csr_write(32'h0014, `PL_K_BASE);
    csr_write(32'h0018, `PL_O_BASE);
    csr_write(32'h0020, rows);
    csr_write(32'h0024, cols);
    csr_write(32'h0000, 32'h0);
    csr_write(32'h0000, 32'h1);

    wait_done(2000000);

    for (int i = 0; i < rows; i++) begin
      dut_out[i] = ddr_read(`PL_O_BASE + i*4);
      if (dut_out[i] === 32'hxxxxxxxx) x_cnt++;
    end
    if (x_cnt > 0) begin
      `uvm_error("PL", $sformatf("PL-05: %0d个输出含X（未定义行为，需RTL保护）", x_cnt))
    end else begin
      errs = compare_gemv_output(dut_out, golden, rows, "PL-05_GEMV_256ROW");
      if (errs == 0)
        `uvm_info("PL", "PL-05: PASS（256行与golden逐行一致）", UVM_MEDIUM)
      else
        `uvm_error("PL", $sformatf("PL-05: FAIL %0d/%0d 行与golden不符", errs, rows))
    end
  endtask
endclass

// ============================================================
// PL-06: head_dim越界（1×32, head_dim=65 > SRAM深度64）【定性】
// ============================================================
class pl_headdim_oob_seq extends cb_top_base_seq;
  `uvm_object_utils(pl_headdim_oob_seq)

  function new(string name = "pl_headdim_oob_seq");
    super.new(name);
  endfunction

  task body();
    int unsigned prng_state = 77006;
    int head_dim = 65;    // 越界（硬件上限64）
    int seq_len = 65;
    int seq_tile_len = 32;
    int num_tiles = (seq_len + seq_tile_len - 1) / seq_tile_len;
    int kv_stride = seq_tile_len * head_dim * 4;
    logic [31:0] status;
    int timeout = 500000;
    bit responded = 0;
    int x_cnt = 0;
    logic [31:0] val;

    `uvm_info("PL", "PL-06 head_dim越界: head_dim=65 (>SRAM深度64)【定性】", UVM_MEDIUM)
    hw_reset();

    for (int i = 0; i < head_dim; i++)
      ddr_write(`PL_Q_BASE + i*4, rand_fp32(prng_state, 0.3));
    for (int t = 0; t < num_tiles; t++)
      for (int r = 0; r < seq_tile_len; r++)
        for (int c = 0; c < head_dim; c++) begin
          ddr_write(`PL_K_BASE + t*kv_stride + (r*head_dim+c)*4, rand_fp32(prng_state, 0.3));
          ddr_write(`PL_V_BASE + t*kv_stride + (r*head_dim+c)*4, rand_fp32(prng_state, 0.3));
        end
    for (int i = 0; i < head_dim; i++)
      ddr_write(`PL_O_BASE + i*4, 32'hDEAD_BEEF);

    csr_write(32'h0030, `PL_Q_BASE);
    csr_write(32'h0034, `PL_K_BASE);
    csr_write(32'h0038, `PL_V_BASE);
    csr_write(32'h003C, `PL_O_BASE);
    csr_write(32'h0040, head_dim);
    csr_write(32'h0044, seq_len);
    csr_write(32'h0048, kv_stride);
    csr_write(32'h004C, 32'd1);
    csr_write(32'h0054, 32'd2);
    csr_write(32'h0050, 32'h3E8293EE);
    csr_write(32'h0000, 32'h0);
    csr_write(32'h0000, 32'h3);

    for (int i = 0; i < timeout; i++) begin
      csr_read(32'h0004, status);
      if (status[1] || status[0] == 0) begin
        responded = 1;
        break;
      end
    end

    if (!responded) begin
      `uvm_error("PL", "PL-06: DUT HANG（head_dim越界导致死锁，需RTL保护）")
    end else begin
      for (int i = 0; i < head_dim; i++) begin
        val = ddr_read(`PL_O_BASE + i*4);
        if (val === 32'hxxxxxxxx) x_cnt++;
      end
      if (x_cnt > 0)
        `uvm_error("PL", $sformatf("PL-06: %0d个输出含X（未定义行为）", x_cnt))
      else
        `uvm_info("PL", "PL-06: DUT响应无X传播（行为记录供签核）", UVM_MEDIUM)
    end
  endtask
endclass

// ============================================================
// PL-07: GROUP_MODE=3（非法值）【定性】
// 意图：default分支自相矛盾（控制维度按4×8、数据bank按1×32）
// ============================================================
class pl_group_mode3_seq extends cb_top_base_seq;
  `uvm_object_utils(pl_group_mode3_seq)

  function new(string name = "pl_group_mode3_seq");
    super.new(name);
  endfunction

  task body();
    int unsigned prng_state = 77007;
    int head_dim = 8;
    int seq_len = 16;
    int num_heads = 4;
    int kv_stride = num_heads * head_dim * head_dim * 4;
    int num_tiles = (seq_len + head_dim - 1) / head_dim;
    logic [31:0] status;
    int timeout = 500000;
    bit responded = 0;
    int x_cnt = 0;
    logic [31:0] val;

    `uvm_info("PL", "PL-07 GROUP_MODE=3非法值【定性，激活default分支】", UVM_MEDIUM)
    hw_reset();

    for (int h = 0; h < num_heads; h++)
      for (int i = 0; i < head_dim; i++)
        ddr_write(`PL_Q_BASE + (h*head_dim+i)*4, rand_fp32(prng_state, 0.5));
    for (int t = 0; t < num_tiles; t++)
      for (int h = 0; h < num_heads; h++)
        for (int r = 0; r < head_dim; r++)
          for (int c = 0; c < head_dim; c++) begin
            ddr_write(`PL_K_BASE + t*kv_stride + (h*head_dim*head_dim + r*head_dim + c)*4, rand_fp32(prng_state, 0.5));
            ddr_write(`PL_V_BASE + t*kv_stride + (h*head_dim*head_dim + r*head_dim + c)*4, rand_fp32(prng_state, 0.5));
          end
    for (int i = 0; i < num_heads*head_dim; i++)
      ddr_write(`PL_O_BASE + i*4, 32'hDEAD_BEEF);

    csr_write(32'h0030, `PL_Q_BASE);
    csr_write(32'h0034, `PL_K_BASE);
    csr_write(32'h0038, `PL_V_BASE);
    csr_write(32'h003C, `PL_O_BASE);
    csr_write(32'h0040, head_dim);
    csr_write(32'h0044, seq_len);
    csr_write(32'h0048, kv_stride);
    csr_write(32'h004C, num_heads);
    csr_write(32'h0054, 32'd3);          // GROUP_MODE=3 非法
    csr_write(32'h0050, 32'h3F0293EE);
    csr_write(32'h0000, 32'h0);
    csr_write(32'h0000, 32'h3);

    for (int i = 0; i < timeout; i++) begin
      csr_read(32'h0004, status);
      if (status[1] || status[0] == 0) begin
        responded = 1;
        break;
      end
    end

    if (!responded) begin
      `uvm_error("PL", "PL-07: DUT HANG（GROUP_MODE=3导致死锁，需RTL保护）")
    end else begin
      for (int i = 0; i < num_heads*head_dim; i++) begin
        val = ddr_read(`PL_O_BASE + i*4);
        if (val === 32'hxxxxxxxx) x_cnt++;
      end
      if (x_cnt > 0)
        `uvm_error("PL", $sformatf("PL-07: %0d个输出含X（未定义行为，需RTL保护）", x_cnt))
      else
        `uvm_info("PL", "PL-07: DUT响应无X传播（default分支行为记录供签核）", UVM_MEDIUM)
    end
  endtask
endclass

`endif

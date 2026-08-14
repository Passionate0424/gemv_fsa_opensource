// FSA Soak Test — 长时间压力测试
// 验证S_ACC_CLEAR修复后连续大量FSA/GEMV操作无累积误差

class fsa_soak_seq extends cb_top_base_seq;

  `uvm_object_utils(fsa_soak_seq)

  localparam int unsigned Q_BASE  = 32'h0000_1000;
  localparam int unsigned K_BASE  = 32'h0000_2000;
  localparam int unsigned V_BASE  = 32'h0001_0000;
  localparam int unsigned O_BASE  = 32'h0002_0000;
  localparam int unsigned VI_BASE = 32'h0003_0000;
  localparam int unsigned MI_BASE = 32'h0003_1000;
  localparam int unsigned VO_BASE = 32'h0004_0000;

  int unsigned prng_state;

  function new(string name = "fsa_soak_seq");
    super.new(name);
  endfunction

  task body();
    int num_rounds = 50;
    int fsa_errors = 0;
    int gemv_errors = 0;

    if ($value$plusargs("soak_rounds=%d", num_rounds));

    hw_reset();

    `uvm_info("SOAK", $sformatf("Soak Test: %0d rounds (FSA->GEMV, no reset)", num_rounds), UVM_MEDIUM)

    for (int round = 0; round < num_rounds; round++) begin
      int seq_len;
      int head_dim, num_heads, group_mode, kv_stride;

      prng_state = round * 9973 + 42;
      case (round % 3)
        0: begin group_mode = 0; head_dim = 8;  num_heads = 4; end
        1: begin group_mode = 1; head_dim = 16; num_heads = 2; end
        2: begin group_mode = 2; head_dim = 32; num_heads = 1; end
      endcase
      kv_stride = num_heads * head_dim * head_dim * 4;

      prng_state = prng_state * 1664525 + 1013904223;
      seq_len = (prng_state[7:0] % 150) + 2;

      // FSA
      begin
        int err;
        run_fsa(head_dim, seq_len, num_heads, group_mode, kv_stride, $sformatf("R%0d", round), err);
        fsa_errors += err;
      end

      // GEMV隔离——同样跟golden比对，累积误差在GEMV侧也可能出现
      begin
        int err;
        run_gemv(32, 64, err);
        gemv_errors += err;
      end

      if (round % 10 == 9)
        `uvm_info("SOAK", $sformatf("  progress: %0d/%0d rounds done", round+1, num_rounds), UVM_MEDIUM)
    end

    if (fsa_errors == 0 && gemv_errors == 0)
      `uvm_info("SOAK", $sformatf("Soak PASS: %0d rounds, 0 errors", num_rounds), UVM_MEDIUM)
    else
      `uvm_error("SOAK", $sformatf("Soak FAIL: FSA %0d errors, GEMV %0d errors in %0d rounds",
                 fsa_errors, gemv_errors, num_rounds))
  endtask

  task run_fsa(int dim, int seq_len, int heads, int gmode, int kv_stride, string label, output int errors);
    int num_tiles = (seq_len + dim - 1) / dim;
    errors = 0;

    dpi_e2e_init(dim, seq_len, heads);

    for (int h = 0; h < heads; h++)
      for (int i = 0; i < dim; i++) begin
        logic [31:0] val = rand_fp32(prng_state, 1.0);
        ddr_write(Q_BASE + (h*dim+i)*4, val);
        dpi_e2e_set_q(h, i, val);
      end

    for (int t = 0; t < num_tiles; t++)
      for (int h = 0; h < heads; h++)
        for (int r = 0; r < dim; r++)
          for (int c = 0; c < dim; c++) begin
            logic [31:0] val = rand_fp32(prng_state, 0.5);
            ddr_write(K_BASE + t*kv_stride + (h*dim*dim + r*dim + c)*4, val);
            dpi_e2e_set_k(h, t*dim+r, c, val);
          end

    for (int t = 0; t < num_tiles; t++)
      for (int h = 0; h < heads; h++)
        for (int r = 0; r < dim; r++)
          for (int c = 0; c < dim; c++) begin
            logic [31:0] val = rand_fp32(prng_state, 0.5);
            ddr_write(V_BASE + t*kv_stride + (h*dim*dim + r*dim + c)*4, val);
            dpi_e2e_set_v(h, t*dim+r, c, val);
          end

    for (int i = 0; i < heads*dim; i++)
      ddr_write(O_BASE + i*4, 32'hDEAD_BEEF);

    dpi_e2e_compute();

    csr_write(32'h0030, Q_BASE);
    csr_write(32'h0034, K_BASE);
    csr_write(32'h0038, V_BASE);
    csr_write(32'h003C, O_BASE);
    csr_write(32'h0040, dim);
    csr_write(32'h0044, seq_len);
    csr_write(32'h0048, kv_stride);
    csr_write(32'h004C, heads);
    csr_write(32'h0054, gmode);
    case (dim)
      8:  csr_write(32'h0050, 32'h3F0293EE);
      16: csr_write(32'h0050, 32'h3EB8AA3B);
      32: csr_write(32'h0050, 32'h3E8293EE);
    endcase
    csr_write(32'h0000, 32'h0);
    csr_write(32'h0000, 32'h3);

    wait_done(500000);

    // 逐head/逐维跟DPI-C黄金模型比对——这才是"无累积误差"这个测试目标真正要
    // 检查的东西，而不是只看有没有NaN/Inf/未写回
    for (int h = 0; h < heads; h++)
      for (int i = 0; i < dim; i++) begin
        logic [31:0] dut_val = ddr_read(O_BASE + (h*dim+i)*4);
        int cmp = dpi_e2e_compare(h, i, dut_val);
        if (cmp != 0) begin
          errors++;
          if (errors <= 2)
            `uvm_error("SOAK", $sformatf("%s: O[head=%0d,i=%0d]=0x%08h 与golden不符", label, h, i, dut_val))
        end
      end
    dpi_e2e_report();
  endtask

  task run_gemv(int rows, int cols, output int errors);
    logic [31:0] vector [] = new[cols];
    logic [31:0] matrix [] = new[rows*cols];
    logic [31:0] golden [];
    logic [31:0] dut_out [] = new[rows];

    for (int i = 0; i < cols; i++) begin
      vector[i] = rand_fp32(prng_state, 1.0);
      ddr_write(VI_BASE + i*4, vector[i]);
    end
    for (int i = 0; i < rows*cols; i++) begin
      matrix[i] = rand_fp32(prng_state, 1.0);
      ddr_write(MI_BASE + i*4, matrix[i]);
    end
    compute_gemv_golden(matrix, vector, rows, cols, golden);

    csr_write(32'h0010, VI_BASE);
    csr_write(32'h0014, MI_BASE);
    csr_write(32'h0018, VO_BASE);
    csr_write(32'h0020, rows);
    csr_write(32'h0024, cols);
    csr_write(32'h0000, 32'h0);
    csr_write(32'h0000, 32'h1);

    wait_done(200000);

    // 隔离用的GEMV轮次同样跟软件黄金模型比对，而不是跑完就丢
    for (int i = 0; i < rows; i++)
      dut_out[i] = ddr_read(VO_BASE + i*4);
    errors = compare_gemv_output(dut_out, golden, rows, "SOAK_GEMV");
  endtask

endclass

class fsa_soak_test extends cb_top_base_test;

  `uvm_component_utils(fsa_soak_test)

  function new(string name = "fsa_soak_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    fsa_soak_seq seq = fsa_soak_seq::type_id::create("seq");
    seq.start(env.vseqr);
  endtask

endclass

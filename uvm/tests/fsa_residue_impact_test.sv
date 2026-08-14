// FSA Residue Impact Test
// 精准模拟板上调用模式：FSA→GEMV→FSA（不复位）
// 目的：确认acc_sram残留在真实使用场景下是否导致精度损失及其大小

class fsa_residue_seq extends cb_top_base_seq;

  `uvm_object_utils(fsa_residue_seq)

  localparam int unsigned Q_BASE  = 32'h0000_1000;
  localparam int unsigned K_BASE  = 32'h0000_2000;
  localparam int unsigned V_BASE  = 32'h0001_0000;
  localparam int unsigned O_BASE  = 32'h0002_0000;
  localparam int unsigned VI_BASE = 32'h0003_0000;
  localparam int unsigned MI_BASE = 32'h0003_1000;
  localparam int unsigned VO_BASE = 32'h0004_0000;

  int unsigned prng_state;

  function new(string name = "fsa_residue_seq");
    super.new(name);
  endfunction

  task body();
    int head_dim = 8;
    int num_heads = 4;
    int kv_stride = num_heads * head_dim * head_dim * 4;

    hw_reset();

    `uvm_info("RESIDUE", "=== Round 1: FSA (seq=8) ===", UVM_MEDIUM)
    prng_state = 10001;
    run_fsa(head_dim, 8, num_heads, kv_stride, "FSA_1st");

    `uvm_info("RESIDUE", "=== GEMV (隔离) ===", UVM_MEDIUM)
    prng_state = 20001;
    run_gemv(32, 64);

    `uvm_info("RESIDUE", "=== Round 2: FSA (seq=16, 不复位) ===", UVM_MEDIUM)
    prng_state = 30001;
    run_fsa(head_dim, 16, num_heads, kv_stride, "FSA_2nd");

    `uvm_info("RESIDUE", "=== GEMV (第二次隔离) ===", UVM_MEDIUM)
    prng_state = 40001;
    run_gemv(32, 64);

    `uvm_info("RESIDUE", "=== Round 3: FSA (seq=24, 不复位) ===", UVM_MEDIUM)
    prng_state = 50001;
    run_fsa(head_dim, 24, num_heads, kv_stride, "FSA_3rd");
  endtask

  task run_fsa(int dim, int seq_len, int heads, int kv_stride, string label);
    int num_tiles = (seq_len + dim - 1) / dim;
    int errors = 0;

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
            logic [31:0] val = rand_fp32(prng_state, 1.0);
            ddr_write(K_BASE + t*kv_stride + (h*dim*dim + r*dim + c)*4, val);
            dpi_e2e_set_k(h, t*dim+r, c, val);
          end

    for (int t = 0; t < num_tiles; t++)
      for (int h = 0; h < heads; h++)
        for (int r = 0; r < dim; r++)
          for (int c = 0; c < dim; c++) begin
            logic [31:0] val = rand_fp32(prng_state, 1.0);
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
    csr_write(32'h0054, 0);
    csr_write(32'h0050, 32'h3F0293EE);
    csr_write(32'h0000, 32'h0);
    csr_write(32'h0000, 32'h3);

    wait_done(200000);

    for (int h = 0; h < heads; h++)
      for (int i = 0; i < dim; i++) begin
        logic [31:0] dut_val = ddr_read(O_BASE + (h*dim+i)*4);
        int cmp = dpi_e2e_compare(h, i, dut_val);
        if (cmp != 0) errors++;
      end

    dpi_e2e_report();

    if (errors == 0)
      `uvm_info("RESIDUE", $sformatf("%s: PASS (0 errors, seq=%0d)", label, seq_len), UVM_MEDIUM)
    else
      `uvm_error("RESIDUE", $sformatf("%s: FAIL %0d/%0d errors (seq=%0d)", label, errors, heads*dim, seq_len))
  endtask

  task run_gemv(int rows, int cols);
    for (int i = 0; i < cols; i++)
      ddr_write(VI_BASE + i*4, rand_fp32(prng_state, 1.0));
    for (int i = 0; i < rows*cols; i++)
      ddr_write(MI_BASE + i*4, rand_fp32(prng_state, 1.0));

    csr_write(32'h0010, VI_BASE);
    csr_write(32'h0014, MI_BASE);
    csr_write(32'h0018, VO_BASE);
    csr_write(32'h0020, rows);
    csr_write(32'h0024, cols);
    csr_write(32'h0000, 32'h0);
    csr_write(32'h0000, 32'h1);

    wait_done(200000);
    `uvm_info("RESIDUE", "GEMV completed", UVM_HIGH)
  endtask

endclass

class fsa_residue_impact_test extends cb_top_base_test;

  `uvm_component_utils(fsa_residue_impact_test)

  function new(string name = "fsa_residue_impact_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    `uvm_info("RESIDUE", "启动FSA Residue Impact Test（模拟板上调用模式）", UVM_MEDIUM)
    begin
      fsa_residue_seq seq = fsa_residue_seq::type_id::create("seq");
      seq.start(env.vseqr);
    end
  endtask

endclass

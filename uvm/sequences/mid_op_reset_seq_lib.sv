// Mid-Operation Reset Sequences
// 在操作执行中途触发复位，验证复位后能正常完成新操作

`ifndef MID_OP_RESET_SEQ_LIB_SV
`define MID_OP_RESET_SEQ_LIB_SV

// GEMV mid-operation reset sequence
class mid_op_reset_gemv_seq extends cb_top_base_seq;
  int reset_delay_cycles = 100;
  int error_count = 0;

  `uvm_object_utils(mid_op_reset_gemv_seq)

  function new(string name = "mid_op_reset_gemv_seq");
    super.new(name);
  endfunction

  task body();
    int unsigned prng_state = 77777;
    localparam int unsigned VI_BASE = 32'h0000_1000;
    localparam int unsigned MI_BASE = 32'h0000_4000;
    localparam int unsigned VO_BASE = 32'h0001_0000;
    int rows = 32;
    int cols = 64;

    `uvm_info("RESET_SEQ", $sformatf("GEMV mid-op reset @ %0d cycles", reset_delay_cycles), UVM_MEDIUM)

    // Phase 1: 启动GEMV操作
    hw_reset();
    for (int i = 0; i < cols; i++)
      ddr_write(VI_BASE + i*4, rand_fp32(prng_state, 1.0));
    for (int i = 0; i < rows*cols; i++)
      ddr_write(MI_BASE + i*4, rand_fp32(prng_state, 1.0));

    csr_write(32'h0010, VI_BASE);
    csr_write(32'h0014, MI_BASE);
    csr_write(32'h0018, VO_BASE);
    csr_write(32'h0020, rows);
    csr_write(32'h0024, cols);
    csr_write(32'h0000, 32'h0000_0000);
    csr_write(32'h0000, 32'h0000_0001);

    // Phase 2: 等待指定cycle后复位（中途打断）
    #(reset_delay_cycles * 20);
    hw_reset();

    // Phase 3: 复位后重新执行完整GEMV，验证能正常完成且结果数值正确
    prng_state = 88888;
    begin
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
      csr_write(32'h0000, 32'h0000_0000);
      csr_write(32'h0000, 32'h0000_0001);

      // Phase 4: 等待完成
      wait_done(200000);

      // Phase 5: 逐行跟软件黄金模型比对（而不是只看第0个输出是不是DEADBEEF）
      for (int i = 0; i < rows; i++)
        dut_out[i] = ddr_read(VO_BASE + i*4);
      error_count = compare_gemv_output(dut_out, golden, rows,
                     $sformatf("RESET_SEQ_GEMV@%0d", reset_delay_cycles));

      if (error_count == 0)
        `uvm_info("RESET_SEQ", $sformatf("GEMV reset@%0d: PASS (%0d行与golden一致)",
                  reset_delay_cycles, rows), UVM_HIGH)
      else
        `uvm_error("RESET_SEQ", $sformatf("GEMV reset@%0d: FAIL %0d/%0d行与golden不符",
                   reset_delay_cycles, error_count, rows))
    end
  endtask
endclass

// FSA mid-operation reset sequence
class mid_op_reset_fsa_seq extends cb_top_base_seq;
  int reset_delay_cycles = 100;
  int error_count = 0;

  `uvm_object_utils(mid_op_reset_fsa_seq)

  function new(string name = "mid_op_reset_fsa_seq");
    super.new(name);
  endfunction

  task body();
    int unsigned prng_state = 99999;
    localparam int unsigned Q_BASE = 32'h0000_1000;
    localparam int unsigned K_BASE = 32'h0000_2000;
    localparam int unsigned V_BASE = 32'h0001_0000;
    localparam int unsigned O_BASE = 32'h0002_0000;
    int head_dim = 8;
    int seq_len = 16;
    int num_heads = 4;
    int kv_stride = num_heads * head_dim * head_dim * 4;
    int num_tiles = (seq_len + head_dim - 1) / head_dim;

    `uvm_info("RESET_SEQ", $sformatf("FSA mid-op reset @ %0d cycles", reset_delay_cycles), UVM_MEDIUM)

    // Phase 1: 启动FSA操作
    hw_reset();
    for (int h = 0; h < num_heads; h++)
      for (int i = 0; i < head_dim; i++)
        ddr_write(Q_BASE + (h*head_dim+i)*4, rand_fp32(prng_state, 1.0));

    for (int t = 0; t < num_tiles; t++)
      for (int h = 0; h < num_heads; h++)
        for (int r = 0; r < head_dim; r++)
          for (int c = 0; c < head_dim; c++)
            ddr_write(K_BASE + t*kv_stride + (h*head_dim*head_dim + r*head_dim + c)*4,
                      rand_fp32(prng_state, 1.0));

    for (int t = 0; t < num_tiles; t++)
      for (int h = 0; h < num_heads; h++)
        for (int r = 0; r < head_dim; r++)
          for (int c = 0; c < head_dim; c++)
            ddr_write(V_BASE + t*kv_stride + (h*head_dim*head_dim + r*head_dim + c)*4,
                      rand_fp32(prng_state, 1.0));

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
    csr_write(32'h0000, 32'h0000_0000);
    csr_write(32'h0000, 32'h0000_0003);

    // Phase 2: 等待指定cycle后复位
    #(reset_delay_cycles * 20);
    hw_reset();

    // Phase 3: 复位后重新执行完整FSA，验证能正常完成且结果数值正确
    prng_state = 11111;
    dpi_e2e_init(head_dim, seq_len, num_heads);

    for (int h = 0; h < num_heads; h++)
      for (int i = 0; i < head_dim; i++) begin
        logic [31:0] val = rand_fp32(prng_state, 1.0);
        ddr_write(Q_BASE + (h*head_dim+i)*4, val);
        dpi_e2e_set_q(h, i, val);
      end

    for (int t = 0; t < num_tiles; t++)
      for (int h = 0; h < num_heads; h++)
        for (int r = 0; r < head_dim; r++)
          for (int c = 0; c < head_dim; c++) begin
            logic [31:0] val = rand_fp32(prng_state, 1.0);
            ddr_write(K_BASE + t*kv_stride + (h*head_dim*head_dim + r*head_dim + c)*4, val);
            dpi_e2e_set_k(h, t*head_dim+r, c, val);
          end

    for (int t = 0; t < num_tiles; t++)
      for (int h = 0; h < num_heads; h++)
        for (int r = 0; r < head_dim; r++)
          for (int c = 0; c < head_dim; c++) begin
            logic [31:0] val = rand_fp32(prng_state, 1.0);
            ddr_write(V_BASE + t*kv_stride + (h*head_dim*head_dim + r*head_dim + c)*4, val);
            dpi_e2e_set_v(h, t*head_dim+r, c, val);
          end

    for (int i = 0; i < num_heads*head_dim; i++)
      ddr_write(O_BASE + i*4, 32'hDEAD_BEEF);

    dpi_e2e_compute();

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
    csr_write(32'h0000, 32'h0000_0000);
    csr_write(32'h0000, 32'h0000_0003);

    // Phase 4: 等待完成
    wait_done(200000);

    // Phase 5: 逐head/逐维跟DPI-C黄金模型比对（而不是只看O[0]是不是DEADBEEF）
    error_count = 0;
    for (int h = 0; h < num_heads; h++)
      for (int i = 0; i < head_dim; i++) begin
        logic [31:0] dut_val = ddr_read(O_BASE + (h*head_dim+i)*4);
        error_count += dpi_e2e_compare(h, i, dut_val);
      end
    dpi_e2e_report();

    if (error_count == 0)
      `uvm_info("RESET_SEQ", $sformatf("FSA reset@%0d: PASS (与golden一致)", reset_delay_cycles), UVM_HIGH)
    else
      `uvm_error("RESET_SEQ", $sformatf("FSA reset@%0d: FAIL %0d 处与golden不符", reset_delay_cycles, error_count))
  endtask
endclass

`endif

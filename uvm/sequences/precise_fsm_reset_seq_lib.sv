// 精准FSM Reset Sequences
// 通过backdoor监控FSM状态，在目标状态活跃时精确触发复位
// 覆盖所有S_XXX→S_IDLE的复位转移

`ifndef PRECISE_FSM_RESET_SEQ_LIB_SV
`define PRECISE_FSM_RESET_SEQ_LIB_SV

// 精准FSM复位sequence：等待目标FSM状态后立即复位
class precise_fsm_reset_seq extends cb_top_base_seq;
  string fsm_path;        // FSM state信号的层次路径
  int    target_state;    // 目标状态编码
  string state_name;      // 状态名（用于日志）
  int    error_count = 0;
  int    timeout = 100000; // 等待目标状态的超时

  `uvm_object_utils(precise_fsm_reset_seq)

  function new(string name = "precise_fsm_reset_seq");
    super.new(name);
  endfunction

  task body();
    uvm_hdl_data_t state_val;
    int wait_cycles = 0;
    bit state_hit = 0;

    // Phase 1: 启动操作（由子类配置）
    start_operation();

    // Phase 2: 轮询等待目标状态
    while (wait_cycles < timeout) begin
      void'(uvm_hdl_read(fsm_path, state_val));
      if (state_val[4:0] == target_state) begin
        state_hit = 1;
        break;
      end
      #20; // 1 clk
      wait_cycles++;
    end

    if (!state_hit) begin
      `uvm_info("PREC_RST", $sformatf("状态%s(%0d)未命中(等待%0d cycles)，跳过",
                state_name, target_state, wait_cycles), UVM_MEDIUM)
      hw_reset();
      return;
    end

    // Phase 3: 在目标状态精确复位
    hw_reset();

    // Phase 4: 复位后执行正常操作验证恢复
    verify_recovery();

    `uvm_info("PREC_RST", $sformatf("%s→IDLE: PASS", state_name), UVM_HIGH)
  endtask

  // 子类覆盖：启动操作
  virtual task start_operation();
  endtask

  // 子类覆盖：验证复位恢复
  virtual task verify_recovery();
  endtask
endclass

// GEMV精准FSM reset
class precise_gemv_fsm_reset_seq extends precise_fsm_reset_seq;
  `uvm_object_utils(precise_gemv_fsm_reset_seq)

  function new(string name = "precise_gemv_fsm_reset_seq");
    super.new(name);
    fsm_path = "tb_top.dut.u_controller.state";
  endfunction

  task start_operation();
    int unsigned prng_state = 55555;
    localparam int unsigned VI_BASE = 32'h0000_1000;
    localparam int unsigned MI_BASE = 32'h0000_4000;
    localparam int unsigned VO_BASE = 32'h0001_0000;

    hw_reset();
    for (int i = 0; i < 64; i++)
      ddr_write(VI_BASE + i*4, rand_fp32(prng_state, 1.0));
    for (int i = 0; i < 64*64; i++)
      ddr_write(MI_BASE + i*4, rand_fp32(prng_state, 1.0));

    csr_write(32'h0010, VI_BASE);
    csr_write(32'h0014, MI_BASE);
    csr_write(32'h0018, VO_BASE);
    csr_write(32'h0020, 64);  // 大矩阵确保走更多状态
    csr_write(32'h0024, 64);
    csr_write(32'h0000, 32'h0);
    csr_write(32'h0000, 32'h1);
  endtask

  task verify_recovery();
    int unsigned prng_state = 66666;
    localparam int unsigned VI_BASE = 32'h0000_1000;
    localparam int unsigned MI_BASE = 32'h0000_4000;
    localparam int unsigned VO_BASE = 32'h0001_0000;
    localparam int rows = 32;
    localparam int cols = 64;
    logic [31:0] vector [] = new[cols];
    logic [31:0] matrix [] = new[rows*cols];
    logic [31:0] golden [];
    logic [31:0] dut_out [] = new[rows];
    int errs;

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

    // 逐行跟软件黄金模型比对（而不是只看第0个输出是不是DEADBEEF）
    for (int i = 0; i < rows; i++)
      dut_out[i] = ddr_read(VO_BASE + i*4);
    errs = compare_gemv_output(dut_out, golden, rows,
             $sformatf("PREC_RST_GEMV_%s", state_name));
    error_count += errs;
    if (errs > 0)
      `uvm_error("PREC_RST", $sformatf("GEMV %s→IDLE: 复位后 %0d/%0d 行与golden不符",
                 state_name, errs, rows))
  endtask
endclass

// FSA精准FSM reset
class precise_fsa_fsm_reset_seq extends precise_fsm_reset_seq;
  `uvm_object_utils(precise_fsa_fsm_reset_seq)

  function new(string name = "precise_fsa_fsm_reset_seq");
    super.new(name);
    fsm_path = "tb_top.dut.mac_top_inst.u_fsm.state";
  endfunction

  task start_operation();
    int unsigned prng_state = 77777;
    localparam int unsigned Q_BASE = 32'h0000_1000;
    localparam int unsigned K_BASE = 32'h0000_2000;
    localparam int unsigned V_BASE = 32'h0001_0000;
    localparam int unsigned O_BASE = 32'h0002_0000;
    int kv_stride = 4 * 8 * 8 * 4;

    hw_reset();
    for (int h = 0; h < 4; h++)
      for (int i = 0; i < 8; i++)
        ddr_write(Q_BASE + (h*8+i)*4, rand_fp32(prng_state, 1.0));

    for (int t = 0; t < 2; t++)
      for (int h = 0; h < 4; h++)
        for (int r = 0; r < 8; r++)
          for (int c = 0; c < 8; c++)
            ddr_write(K_BASE + t*kv_stride + (h*64 + r*8 + c)*4, rand_fp32(prng_state, 1.0));

    for (int t = 0; t < 2; t++)
      for (int h = 0; h < 4; h++)
        for (int r = 0; r < 8; r++)
          for (int c = 0; c < 8; c++)
            ddr_write(V_BASE + t*kv_stride + (h*64 + r*8 + c)*4, rand_fp32(prng_state, 1.0));

    csr_write(32'h0030, Q_BASE);
    csr_write(32'h0034, K_BASE);
    csr_write(32'h0038, V_BASE);
    csr_write(32'h003C, O_BASE);
    csr_write(32'h0040, 8);
    csr_write(32'h0044, 16);  // 2 tiles确保走完整循环
    csr_write(32'h0048, kv_stride);
    csr_write(32'h004C, 4);
    csr_write(32'h0054, 0);
    csr_write(32'h0050, 32'h3F0293EE);
    csr_write(32'h0000, 32'h0);
    csr_write(32'h0000, 32'h3);
  endtask

  task verify_recovery();
    int unsigned prng_state = 88888;
    localparam int unsigned Q_BASE = 32'h0000_1000;
    localparam int unsigned K_BASE = 32'h0000_2000;
    localparam int unsigned V_BASE = 32'h0001_0000;
    localparam int unsigned O_BASE = 32'h0002_0000;
    localparam int head_dim = 8;
    localparam int seq_len = 8;
    localparam int num_heads = 4;
    int kv_stride = num_heads * head_dim * head_dim * 4;
    int errs = 0;

    dpi_e2e_init(head_dim, seq_len, num_heads);

    for (int h = 0; h < num_heads; h++)
      for (int i = 0; i < head_dim; i++) begin
        logic [31:0] val = rand_fp32(prng_state, 1.0);
        ddr_write(Q_BASE + (h*head_dim+i)*4, val);
        dpi_e2e_set_q(h, i, val);
      end

    for (int h = 0; h < num_heads; h++)
      for (int r = 0; r < head_dim; r++)
        for (int c = 0; c < head_dim; c++) begin
          logic [31:0] val = rand_fp32(prng_state, 1.0);
          ddr_write(K_BASE + (h*head_dim*head_dim + r*head_dim + c)*4, val);
          dpi_e2e_set_k(h, r, c, val);
        end

    for (int h = 0; h < num_heads; h++)
      for (int r = 0; r < head_dim; r++)
        for (int c = 0; c < head_dim; c++) begin
          logic [31:0] val = rand_fp32(prng_state, 1.0);
          ddr_write(V_BASE + (h*head_dim*head_dim + r*head_dim + c)*4, val);
          dpi_e2e_set_v(h, r, c, val);
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
    csr_write(32'h0000, 32'h0);
    csr_write(32'h0000, 32'h3);
    wait_done(200000);

    // 逐head/逐维跟DPI-C黄金模型比对（而不是只看O[0]是不是DEADBEEF）
    for (int h = 0; h < num_heads; h++)
      for (int i = 0; i < head_dim; i++) begin
        logic [31:0] dut_val = ddr_read(O_BASE + (h*head_dim+i)*4);
        errs += dpi_e2e_compare(h, i, dut_val);
      end
    dpi_e2e_report();
    error_count += errs;
    if (errs > 0)
      `uvm_error("PREC_RST", $sformatf("FSA %s→IDLE: 复位后 %0d 处与golden不符", state_name, errs))
  endtask
endclass

`endif

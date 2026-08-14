// 错误注入Sequence Library
// 测试非法配置不导致DUT hang或未定义行为

`ifndef ERROR_SEQ_LIB_SV
`define ERROR_SEQ_LIB_SV

// 零行数GEMV测试
class err_zero_rows_seq extends cb_top_base_seq;
  `uvm_object_utils(err_zero_rows_seq)

  function new(string name = "err_zero_rows_seq");
    super.new(name);
  endfunction

  task body();
    logic [31:0] status;
    int timeout = 50000;

    `uvm_info("ERR_SEQ", "err_zero_rows: ROWS=0, COLS=64", UVM_MEDIUM)
    hw_reset();

    csr_write(32'h0010, 32'h0000_1000);  // VI_BASE
    csr_write(32'h0014, 32'h0000_4000);  // MI_BASE
    csr_write(32'h0018, 32'h0001_0000);  // VO_BASE
    csr_write(32'h0020, 32'h0);          // ROWS = 0
    csr_write(32'h0024, 32'd64);         // COLS = 64
    csr_write(32'h0000, 32'h0000_0000);
    csr_write(32'h0000, 32'h0000_0001);  // start GEMV

    // 等待done或超时（不应hang）
    for (int i = 0; i < timeout; i++) begin
      csr_read(32'h0004, status);
      if (status[1] || status[0] == 0) begin
        `uvm_info("ERR_SEQ", $sformatf("err_zero_rows: DUT responded (status=0x%08h) after %0d polls", status, i), UVM_MEDIUM)
        return;
      end
    end
    `uvm_error("ERR_SEQ", "err_zero_rows: DUT HANG (timeout)")
  endtask
endclass

// 零列数GEMV测试
class err_zero_cols_seq extends cb_top_base_seq;
  `uvm_object_utils(err_zero_cols_seq)

  function new(string name = "err_zero_cols_seq");
    super.new(name);
  endfunction

  task body();
    logic [31:0] status;
    int timeout = 50000;

    `uvm_info("ERR_SEQ", "err_zero_cols: ROWS=32, COLS=0", UVM_MEDIUM)
    hw_reset();

    csr_write(32'h0010, 32'h0000_1000);
    csr_write(32'h0014, 32'h0000_4000);
    csr_write(32'h0018, 32'h0001_0000);
    csr_write(32'h0020, 32'd32);         // ROWS = 32
    csr_write(32'h0024, 32'h0);          // COLS = 0
    csr_write(32'h0000, 32'h0000_0000);
    csr_write(32'h0000, 32'h0000_0001);

    for (int i = 0; i < timeout; i++) begin
      csr_read(32'h0004, status);
      if (status[1] || status[0] == 0) begin
        `uvm_info("ERR_SEQ", $sformatf("err_zero_cols: DUT responded (status=0x%08h) after %0d polls", status, i), UVM_MEDIUM)
        return;
      end
    end
    `uvm_error("ERR_SEQ", "err_zero_cols: DUT HANG (timeout)")
  endtask
endclass

// 启动期间再次写start
class err_start_while_busy_seq extends cb_top_base_seq;
  `uvm_object_utils(err_start_while_busy_seq)

  function new(string name = "err_start_while_busy_seq");
    super.new(name);
  endfunction

  task body();
    logic [31:0] status;
    int unsigned prng_state = 99;

    `uvm_info("ERR_SEQ", "err_start_while_busy: start then re-start immediately", UVM_MEDIUM)
    hw_reset();

    // 加载一些数据让GEMV有活干
    for (int i = 0; i < 64; i++) begin
      ddr_write(32'h0000_1000 + i*4, rand_fp32(prng_state, 1.0));
    end
    for (int i = 0; i < 32*64; i++) begin
      ddr_write(32'h0000_4000 + i*4, rand_fp32(prng_state, 1.0));
    end

    // 配置并启动第一次
    csr_write(32'h0010, 32'h0000_1000);
    csr_write(32'h0014, 32'h0000_4000);
    csr_write(32'h0018, 32'h0001_0000);
    csr_write(32'h0020, 32'd32);
    csr_write(32'h0024, 32'd64);
    csr_write(32'h0000, 32'h0000_0000);
    csr_write(32'h0000, 32'h0000_0001);

    // 立即再写start（DUT应该忽略或正常完成第一次）
    csr_write(32'h0000, 32'h0000_0000);
    csr_write(32'h0000, 32'h0000_0001);

    // 等待至少一次done
    wait_done(200000);
    `uvm_info("ERR_SEQ", "err_start_while_busy: DUT completed without hang", UVM_MEDIUM)
  endtask
endclass

// 非法group_mode值
class err_invalid_group_mode_seq extends cb_top_base_seq;
  `uvm_object_utils(err_invalid_group_mode_seq)

  function new(string name = "err_invalid_group_mode_seq");
    super.new(name);
  endfunction

  task body();
    logic [31:0] status;
    int timeout = 50000;

    `uvm_info("ERR_SEQ", "err_invalid_group_mode: GROUP_MODE=3 (illegal)", UVM_MEDIUM)
    hw_reset();

    // 配置FSA但用非法group_mode
    csr_write(32'h0030, 32'h0000_1000);  // Q_BASE
    csr_write(32'h0034, 32'h0000_2000);  // K_BASE
    csr_write(32'h0038, 32'h0001_0000);  // V_BASE
    csr_write(32'h003C, 32'h0002_0000);  // O_BASE
    csr_write(32'h0040, 32'd8);          // HEAD_DIM
    csr_write(32'h0044, 32'd8);          // SEQ_LEN
    csr_write(32'h0048, 32'd1024);       // KV_STRIDE
    csr_write(32'h004C, 32'd4);          // NUM_HEADS
    csr_write(32'h0054, 32'd3);          // GROUP_MODE = 3 (illegal!)
    csr_write(32'h0050, 32'h3F0293EE);   // ATTN_SCALE
    csr_write(32'h0000, 32'h0000_0000);
    csr_write(32'h0000, 32'h0000_0003);  // start FSA

    for (int i = 0; i < timeout; i++) begin
      csr_read(32'h0004, status);
      if (status[1] || status[0] == 0) begin
        `uvm_info("ERR_SEQ", $sformatf("err_invalid_group_mode: DUT responded (status=0x%08h) after %0d polls", status, i), UVM_MEDIUM)
        return;
      end
    end
    `uvm_error("ERR_SEQ", "err_invalid_group_mode: DUT HANG (timeout)")
  endtask
endclass

`endif

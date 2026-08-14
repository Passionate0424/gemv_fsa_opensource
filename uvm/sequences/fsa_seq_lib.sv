// FSA模式Sequence Library
// 提供FlashAttention测试的完整流程sequence

`ifndef FSA_SEQ_LIB_SV
`define FSA_SEQ_LIB_SV

// FSA基础Sequence：加载Q/K/V → 配置CSR → 启动 → 等待完成 → 比对
class fsa_base_seq extends cb_top_base_seq;

  // 测试参数
  int unsigned head_dim    = 8;
  int unsigned seq_len     = 8;
  int unsigned num_heads   = 4;
  int unsigned group_mode  = 0;   // 0=4×8, 1=2×16, 2=1×32
  int unsigned seed        = 42;
  real data_range          = 1.0;

  // DDR地址布局
  // Q固定（仅占num_heads×head_dim，很小）；K/V/O改为动态非重叠布局
  // （K实际占用=num_tiles×kv_stride随seq增长，固定间距在seq≥511时K会覆盖V_BASE，
  //  与tb_fsa_e2e.sv保持一致的动态base计算，避免地址重叠污染）
  localparam int unsigned Q_BASE_ADDR = 32'h0000_1000;

  // CSR地址
  localparam logic [31:0] REG_CTRL       = 32'h0000;
  localparam logic [31:0] REG_STATUS     = 32'h0004;
  localparam logic [31:0] REG_Q_BASE     = 32'h0030;
  localparam logic [31:0] REG_K_BASE     = 32'h0034;
  localparam logic [31:0] REG_V_BASE     = 32'h0038;
  localparam logic [31:0] REG_O_BASE     = 32'h003C;
  localparam logic [31:0] REG_HEAD_DIM   = 32'h0040;
  localparam logic [31:0] REG_SEQ_LEN    = 32'h0044;
  localparam logic [31:0] REG_KV_STRIDE  = 32'h0048;
  localparam logic [31:0] REG_NUM_HEADS  = 32'h004C;
  localparam logic [31:0] REG_ATTN_SCALE = 32'h0050;
  localparam logic [31:0] REG_GROUP_MODE = 32'h0054;

  // 结果
  int error_count;

  `uvm_object_utils(fsa_base_seq)

  function new(string name = "fsa_base_seq");
    super.new(name);
  endfunction

  task body();
    int unsigned kv_stride;
    int unsigned num_tiles;
    int unsigned prng_state;
    logic [31:0] attn_scale;
    int unsigned kv_footprint;
    int unsigned k_base;
    int unsigned v_base;
    int unsigned o_base;
    int unsigned seq_tile_len;

    // 根据group_mode设置派生参数
    apply_group_mode();

    // K/V DMA硬件单次tile固定搬32行（cmd_block_count硬编码31），
    // head_dim>32时tile行数与head_dim列数不再相等，须各自独立计算
    seq_tile_len = (head_dim > 32) ? 32 : head_dim;
    num_tiles = (seq_len + seq_tile_len - 1) / seq_tile_len;
    kv_stride = num_heads * seq_tile_len * head_dim * 4;

    // 动态计算非重叠K/V/O base地址（与tb_fsa_e2e.sv一致）
    // 固定base下K占用随seq_len增长，seq≥511时K尾部会覆盖V_BASE导致V被污染
    kv_footprint = num_tiles * kv_stride;
    k_base = 32'h0000_2000;
    v_base = k_base + kv_footprint;
    o_base = v_base + kv_footprint;

    `uvm_info("FSA_SEQ", $sformatf(
      "开始FSA测试: head_dim=%0d, seq_len=%0d, num_heads=%0d, group_mode=%0d, tiles=%0d, seed=%0d",
      head_dim, seq_len, num_heads, group_mode, num_tiles, seed), UVM_MEDIUM)

    // 初始化golden
    dpi_e2e_init(head_dim, seq_len, num_heads);

    // 初始化PRNG
    prng_state = seed;

    // 生成Q并写入DDR + golden
    for (int h = 0; h < num_heads; h++)
      for (int i = 0; i < head_dim; i++) begin
        logic [31:0] val = rand_fp32(prng_state, data_range);
        ddr_write(Q_BASE_ADDR + (h * head_dim + i) * 4, val);
        dpi_e2e_set_q(h, i, val);
      end

    // 生成K并写入DDR + golden（tile-major布局，每tile固定seq_tile_len行×head_dim列）
    for (int tile = 0; tile < num_tiles; tile++)
      for (int h = 0; h < num_heads; h++)
        for (int r = 0; r < seq_tile_len; r++)
          for (int c = 0; c < head_dim; c++) begin
            logic [31:0] val = rand_fp32(prng_state, data_range);
            ddr_write(k_base + tile * kv_stride +
                      (h * seq_tile_len * head_dim + r * head_dim + c) * 4, val);
            dpi_e2e_set_k(h, tile * seq_tile_len + r, c, val);
          end

    // 生成V并写入DDR + golden（布局同K）
    for (int tile = 0; tile < num_tiles; tile++)
      for (int h = 0; h < num_heads; h++)
        for (int r = 0; r < seq_tile_len; r++)
          for (int c = 0; c < head_dim; c++) begin
            logic [31:0] val = rand_fp32(prng_state, data_range);
            ddr_write(v_base + tile * kv_stride +
                      (h * seq_tile_len * head_dim + r * head_dim + c) * 4, val);
            dpi_e2e_set_v(h, tile * seq_tile_len + r, c, val);
          end

    // 标记O区域
    for (int i = 0; i < num_heads * head_dim; i++)
      ddr_write(o_base + i * 4, 32'hDEAD_BEEF);

    // 计算golden
    dpi_e2e_compute();

    // 获取ATTN_SCALE
    attn_scale = get_attn_scale(head_dim);

    // CSR配置
    csr_write(REG_Q_BASE, Q_BASE_ADDR);
    csr_write(REG_K_BASE, k_base);
    csr_write(REG_V_BASE, v_base);
    csr_write(REG_O_BASE, o_base);
    csr_write(REG_HEAD_DIM, head_dim);
    csr_write(REG_SEQ_LEN, seq_len);
    csr_write(REG_KV_STRIDE, kv_stride);
    csr_write(REG_NUM_HEADS, num_heads);
    csr_write(REG_GROUP_MODE, group_mode);
    csr_write(REG_ATTN_SCALE, attn_scale);

    // 启动FSA（先清start确保0→1触发，再写mode=1+start=1）
    csr_write(REG_CTRL, 32'h0000_0000);
    csr_write(REG_CTRL, 32'h0000_0003);

    // 等待完成
    wait_done(200000);

    // 比对结果
    error_count = 0;
    for (int h = 0; h < num_heads; h++)
      for (int i = 0; i < head_dim; i++) begin
        logic [31:0] dut_val = ddr_read(o_base + (h * head_dim + i) * 4);
        int cmp_result = dpi_e2e_compare(h, i, dut_val);
        error_count += cmp_result;
      end

    // 打印精度报告
    dpi_e2e_report();

    if (error_count == 0)
      `uvm_info("FSA_SEQ", $sformatf("PASS: dim=%0d, seq=%0d, mode=%0d",
                head_dim, seq_len, group_mode), UVM_MEDIUM)
    else
      `uvm_error("FSA_SEQ", $sformatf("FAIL: %0d errors (dim=%0d, seq=%0d, mode=%0d)",
                 error_count, head_dim, seq_len, group_mode))
  endtask

  // 根据group_mode设置head_dim和num_heads
  // head_dim>32的子类(fsa_hd64_test/fsa_hd48_test/fsa_random_seq的rand_hd_variant)
  // 会在调用body()前显式把head_dim设成64/48——这里要跳过，不能被自动派生覆盖回32
  function void apply_group_mode();
    if (head_dim == 64 || head_dim == 48) return;
    case (group_mode)
      0: begin head_dim = 8;  num_heads = 4; end
      1: begin head_dim = 16; num_heads = 2; end
      2: begin head_dim = 32; num_heads = 1; end
      default: begin head_dim = 8; num_heads = 4; end
    endcase
  endfunction

  // ATTN_SCALE = log2(e) / sqrt(head_dim)
  function logic [31:0] get_attn_scale(input int dim);
    case (dim)
      8:  return 32'h3F0293EE;  // ≈ 0.5100
      16: return 32'h3EB8AA3B;  // ≈ 0.3607
      32: return 32'h3E8293EE;  // ≈ 0.2550
      48: return 32'h3E553B95;  // ≈ 0.2082
      64: return 32'h3E38AA3B;  // ≈ 0.1803
      default: return 32'h3F0293EE;
    endcase
  endfunction

endclass

// FSA Sanity Sequence（单tile，4×8模式）
class fsa_sanity_seq extends fsa_base_seq;

  `uvm_object_utils(fsa_sanity_seq)

  function new(string name = "fsa_sanity_seq");
    super.new(name);
    group_mode = 0;
    seq_len    = 8;
    seed       = 42;
  endfunction

endclass

// FSA Directed Sequence（参数化，支持88个case）
class fsa_directed_seq extends fsa_base_seq;

  `uvm_object_utils(fsa_directed_seq)

  function new(string name = "fsa_directed_seq");
    super.new(name);
  endfunction

endclass

// ============================================================
// FSA GQA/MQA Sequence
// ============================================================
// 验证硬件KV fanout：DDR只摆kv_heads份唯一K/V，硬件读一次广播到num_heads个Q组。
// 与tb_fsa_e2e.sv的run_case_gqa同构的黑盒构造：
//   - golden按num_heads个逻辑head建模，但共享同一KV的Q head填**相同**K/V
//     （golden里head h用kv_head=h/ratio那份）→ golden天然是"每组用其共享KV"的正确结果。
//   - DUT侧DDR只摆kv_heads份（按kv_head索引连续），配REG_NUM_HEADS=kv_heads
//     和缩小的KV_STRIDE，交硬件fanout补齐。
// kv_heads<num_heads触发真正的fanout（ratio>1）；kv_heads==num_heads退化MHA。
class fsa_gqa_seq extends fsa_base_seq;

  int unsigned kv_heads = 2;   // 本case的唯一KV头数（1=MQA, 2=GQA, =num_heads=MHA）

  // 唯一KV数据缓存（类成员在堆上，不占栈）
  logic [31:0] k_uniq[4][2048][64];
  logic [31:0] v_uniq[4][2048][64];

  `uvm_object_utils(fsa_gqa_seq)

  function new(string name = "fsa_gqa_seq");
    super.new(name);
  endfunction

  task body();
    int unsigned seq_tile_len;
    int unsigned num_tiles;
    int unsigned kv_stride;
    int unsigned kv_footprint;
    int unsigned k_base;
    int unsigned v_base;
    int unsigned o_base;
    int unsigned prng_state;
    int unsigned ratio;
    logic [31:0] attn_scale;

    apply_group_mode();  // 派生head_dim/num_heads（4×8→4, 2×16→2, 1×32→1）

    ratio        = num_heads / kv_heads;
    seq_tile_len = (head_dim > 32) ? 32 : head_dim;
    num_tiles    = (seq_len + seq_tile_len - 1) / seq_tile_len;
    // GQA下DDR每tile只摆kv_heads份 → KV_STRIDE相应缩小
    kv_stride    = kv_heads * seq_tile_len * head_dim * 4;
    kv_footprint = num_tiles * kv_stride;
    k_base = 32'h0000_2000;
    v_base = k_base + kv_footprint;
    o_base = v_base + kv_footprint;

    `uvm_info("FSA_GQA", $sformatf(
      "GQA测试: head_dim=%0d seq_len=%0d num_heads=%0d kv_heads=%0d ratio=%0d group_mode=%0d tiles=%0d seed=%0d",
      head_dim, seq_len, num_heads, kv_heads, ratio, group_mode, num_tiles, seed), UVM_MEDIUM)

    dpi_e2e_init(head_dim, seq_len, num_heads);
    prng_state = seed;

    // Q：每个Q head独立随机（Q侧不共享）
    for (int h = 0; h < num_heads; h++)
      for (int i = 0; i < head_dim; i++) begin
        logic [31:0] val = rand_fp32(prng_state, data_range);
        ddr_write(Q_BASE_ADDR + (h * head_dim + i) * 4, val);
        dpi_e2e_set_q(h, i, val);
      end

    // 先为kv_heads份唯一KV生成随机数据
    for (int kv = 0; kv < kv_heads; kv++)
      for (int r = 0; r < seq_len; r++)
        for (int c = 0; c < head_dim; c++) begin
          k_uniq[kv][r][c] = rand_fp32(prng_state, data_range);
          v_uniq[kv][r][c] = rand_fp32(prng_state, data_range);
        end

    // golden：num_heads个head，head h用kv_head=h/ratio的数据（共享组填相同）
    for (int h = 0; h < num_heads; h++)
      for (int r = 0; r < seq_len; r++)
        for (int c = 0; c < head_dim; c++) begin
          dpi_e2e_set_k(h, r, c, k_uniq[h / ratio][r][c]);
          dpi_e2e_set_v(h, r, c, v_uniq[h / ratio][r][c]);
        end

    // DDR：只摆kv_heads份（tile-major，每tile内kv_heads份连续），
    // 超出seq_len的padding行补0（与硬件last-tile mask一致）
    for (int tile = 0; tile < num_tiles; tile++)
      for (int kv = 0; kv < kv_heads; kv++)
        for (int r = 0; r < seq_tile_len; r++)
          for (int c = 0; c < head_dim; c++) begin
            int grow = tile * seq_tile_len + r;
            logic [31:0] kval = (grow < seq_len) ? k_uniq[kv][grow][c] : 32'h0;
            logic [31:0] vval = (grow < seq_len) ? v_uniq[kv][grow][c] : 32'h0;
            ddr_write(k_base + tile * kv_stride +
                      (kv * seq_tile_len * head_dim + r * head_dim + c) * 4, kval);
            ddr_write(v_base + tile * kv_stride +
                      (kv * seq_tile_len * head_dim + r * head_dim + c) * 4, vval);
          end

    for (int i = 0; i < num_heads * head_dim; i++)
      ddr_write(o_base + i * 4, 32'hDEAD_BEEF);

    dpi_e2e_compute();
    attn_scale = get_attn_scale(head_dim);

    csr_write(REG_Q_BASE, Q_BASE_ADDR);
    csr_write(REG_K_BASE, k_base);
    csr_write(REG_V_BASE, v_base);
    csr_write(REG_O_BASE, o_base);
    csr_write(REG_HEAD_DIM, head_dim);
    csr_write(REG_SEQ_LEN, seq_len);
    csr_write(REG_KV_STRIDE, kv_stride);
    csr_write(REG_NUM_HEADS, kv_heads);   // 关键：告诉硬件本趟只有kv_heads份唯一KV
    csr_write(REG_GROUP_MODE, group_mode);
    csr_write(REG_ATTN_SCALE, attn_scale);

    csr_write(REG_CTRL, 32'h0000_0000);
    csr_write(REG_CTRL, 32'h0000_0003);

    wait_done(200000);

    error_count = 0;
    for (int h = 0; h < num_heads; h++)
      for (int i = 0; i < head_dim; i++) begin
        logic [31:0] dut_val = ddr_read(o_base + (h * head_dim + i) * 4);
        error_count += dpi_e2e_compare(h, i, dut_val);
      end

    dpi_e2e_report();

    if (error_count == 0)
      `uvm_info("FSA_GQA", $sformatf("PASS: dim=%0d seq=%0d kv_heads=%0d mode=%0d",
                head_dim, seq_len, kv_heads, group_mode), UVM_MEDIUM)
    else
      `uvm_error("FSA_GQA", $sformatf("FAIL: %0d errors (dim=%0d seq=%0d kv_heads=%0d mode=%0d)",
                 error_count, head_dim, seq_len, kv_heads, group_mode))
  endtask

endclass

// FSA Random Sequence（constrained random）
class fsa_random_seq extends fsa_base_seq;

  rand int unsigned rand_group_mode;
  rand int unsigned rand_seq_len;
  rand int unsigned rand_seed;
  // 仅在rand_group_mode==2时起作用：0=32(现状), 1=48, 2=64
  // 让head_dim>32的chunk1/chunk2路径（包括48的DMA padding分支）随机覆盖进
  // 既有的fsa_random_test，而不是只靠几个孤立的定向case
  rand int unsigned rand_hd_variant;

  constraint c_group_mode { rand_group_mode inside {[0:2]}; }
  constraint c_seq_len    { rand_seq_len inside {[1:160]}; }
  constraint c_hd_variant_range { rand_hd_variant inside {[0:2]}; }
  constraint c_hd_variant_dist  { rand_hd_variant dist { 0 := 50, 1 := 25, 2 := 25 }; }

  constraint c_seq_dist {
    rand_seq_len dist {
      [1:8]     := 15,
      [9:32]    := 25,
      [33:80]   := 30,
      [81:160]  := 30
    };
  }

  `uvm_object_utils(fsa_random_seq)

  function new(string name = "fsa_random_seq");
    super.new(name);
  endfunction

  task body();
    group_mode = rand_group_mode;
    seq_len    = rand_seq_len;
    seed       = rand_seed;
    if (rand_group_mode == 2) begin
      case (rand_hd_variant)
        1: begin head_dim = 48; num_heads = 1; end
        2: begin head_dim = 64; num_heads = 1; end
        default: ; // 0：维持32，走原有apply_group_mode()派生
      endcase
    end
    super.body();
  endtask

endclass

// FSA GQA Random Sequence（constrained random 覆盖 fanout 路径）
// 继承 fsa_gqa_seq（DDR只摆kv_heads份+golden共享填充），随机化 group_mode/kv_heads/
// seq_len，把 KV fanout 纳入 constrained-random——定向case只是几个固定点，随机才能
// 撞出组合边界（如 ratio×tile×非满tile 的交叉）。约束保证 kv_heads 整除 num_heads：
//   gm=0(4×8,num_heads=4) → kv∈{1,2,4}；gm=1(2×16,num_heads=2) → kv∈{1,2}。
// 排除 gm=2(1×32单头，GQA无意义)。seq_len 放宽到[1:160]覆盖深多tile累积误差与seq=1边界。
class fsa_gqa_random_seq extends fsa_gqa_seq;

  rand int unsigned rand_group_mode;
  rand int unsigned rand_kv_heads;
  rand int unsigned rand_seq_len;
  rand int unsigned rand_seed;

  // 只在 4×8 / 2×16 做 GQA（1×32 单头无共享意义）
  constraint c_group_mode { rand_group_mode inside {0, 1}; }
  // kv_heads 必须整除该模式的 num_heads：gm=0→4头允许{1,2,4}，gm=1→2头允许{1,2}
  constraint c_kv_heads {
    (rand_group_mode == 0) -> rand_kv_heads inside {1, 2, 4};
    (rand_group_mode == 1) -> rand_kv_heads inside {1, 2};
  }
  // 偏向真正触发 fanout（ratio>1）的配置，同时保留 MHA 退化点做回归
  constraint c_kv_dist {
    rand_kv_heads dist { 1 := 40, 2 := 40, 4 := 20 };
  }
  constraint c_seq_len { rand_seq_len inside {[1:160]}; }
  // 覆盖 seq=1 边界、单tile、多tile rescale、深多tile累积误差
  constraint c_seq_dist {
    rand_seq_len dist {
      1         := 8,    // seq=1 边界
      [2:16]    := 22,   // 单~2 tile
      [17:64]   := 30,   // 多 tile rescale
      [65:160]  := 40    // 深多 tile 累积误差
    };
  }

  `uvm_object_utils(fsa_gqa_random_seq)

  function new(string name = "fsa_gqa_random_seq");
    super.new(name);
  endfunction

  task body();
    group_mode = rand_group_mode;
    kv_heads   = rand_kv_heads;
    seq_len    = rand_seq_len;
    seed       = rand_seed;
    super.body();  // fsa_gqa_seq.body() 内 apply_group_mode() 会据 group_mode 派生 head_dim/num_heads
  endtask

endclass

`endif

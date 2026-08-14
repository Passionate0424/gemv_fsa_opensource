// 功能覆盖率收集器
// 订阅axi_slv_monitor AP，采样CSR事务和配置覆盖率
// 在写CTRL.start=1时从RAL mirror读取当前配置值采样功能覆盖
class cb_func_coverage extends uvm_subscriber #(axi_slv_seq_item);
  `uvm_component_utils(cb_func_coverage)

  cb_csr_reg_block ral;

  // 采样变量
  logic [31:0] sampled_addr;
  bit          sampled_is_write;
  int          sampled_mode;
  int          sampled_rows, sampled_cols;
  int          sampled_head_dim, sampled_seq_len, sampled_group_mode;
  int          sampled_silu_en;   // GEMV时的SiLU融合使能（CSR 0x0058 bit0）

  // 预取采样。CSR事务里看不到"命中"这个事实（它是硬件内部判定），但能从
  // 事务序列推断：发过预取 + 之后没重写决定搬运的配置 => 应当命中。
  int          sampled_pf_issued;  // 本次任务启动前发过预取
  int          sampled_pf_target;  // 预取的target：0=GEMV权重 1=FSA的K
  int          sampled_pf_killed;  // 预取后又写了配置寄存器 => 预取会失效
  // pending_*：跨事务累积，在CTRL(start=1)那一刻转成sampled_*并清零
  int          pending_pf_issued;
  int          pending_pf_target;
  int          pending_pf_killed;

  // --- cg_csr_access: CSR地址 × 读写方向 ---
  covergroup cg_csr_access;
    cp_addr: coverpoint sampled_addr {
      bins ctrl       = {32'h0000};
      bins status     = {32'h0004};
      bins err_code   = {32'h0008};
      bins vi_base    = {32'h0010};
      bins mi_base    = {32'h0014};
      bins vo_base    = {32'h0018};
      bins rows       = {32'h0020};
      bins cols       = {32'h0024};
      bins q_base     = {32'h0030};
      bins k_base     = {32'h0034};
      bins v_base     = {32'h0038};
      bins o_base     = {32'h003C};
      bins head_dim   = {32'h0040};
      bins seq_len    = {32'h0044};
      bins kv_stride  = {32'h0048};
      bins num_heads  = {32'h004C};
      bins attn_scale = {32'h0050};
      bins group_mode = {32'h0054};
      bins act_ctrl   = {32'h0058};
      bins pf_ctrl    = {32'h005C};
    }
    cp_rw: coverpoint sampled_is_write { bins wr = {1}; bins rd = {0}; }
    // PF_CTRL是WO，读回恒0，读方向那格永远不会被有意义地访问——
    // 排除掉，免得它挂在覆盖率报告里当永久缺口
    cx_addr_rw: cross cp_addr, cp_rw {
      ignore_bins pf_ctrl_read = binsof(cp_addr.pf_ctrl) && binsof(cp_rw.rd);
    }
  endgroup

  // --- cg_mode_config: 运行模式 ---
  covergroup cg_mode_config;
    cp_mode: coverpoint sampled_mode { bins gemv = {0}; bins fsa = {1}; }
  endgroup

  // --- cg_gemv_dims: GEMV rows × cols ---
  covergroup cg_gemv_dims;
    cp_rows: coverpoint sampled_rows {
      bins r_small  = {[1:8]};
      bins r_mid    = {[9:32]};
      bins r_large  = {[33:64]};
      bins r_bnd_32 = {32};
      bins r_bnd_33 = {33};
      bins r_bnd_64 = {64};
    }
    cp_cols: coverpoint sampled_cols {
      bins c_single_tile = {[1:64]};
      bins c_two_tile    = {[65:128]};
      bins c_three_tile  = {[129:172]};
      bins c_bnd_64      = {64};
      bins c_bnd_128     = {128};
      bins c_bnd_172     = {172};
    }
    cx_dims: cross cp_rows, cp_cols;
  endgroup

  // --- cg_silu: SiLU融合使能 × GEMV维度边界 ---
  // 交叉的意义：SiLU微程序按 ceil(rows/4) 个地址循环，rows 非32倍数时尾块
  // 会收窄；cols>64 走多tile累加时 SiLU 只能在最后一个tile之后做一次。
  // 这两条边界与 silu_en 的交叉才是真正需要覆盖的组合。
  covergroup cg_silu;
    cp_silu_en: coverpoint sampled_silu_en { bins off = {0}; bins on = {1}; }
    cp_silu_rows: coverpoint sampled_rows {
      bins r_tail_tiny = {[1:7]};    // 尾块极小，addr_total 只有1~2
      bins r_tail_part = {[8:31]};   // 尾块不满
      bins r_exact32   = {32};       // 正好一块
      bins r_cross     = {[33:63]};  // 两块且尾块不满
      bins r_exact64   = {64};
      bins r_big       = {[65:512]};
    }
    cp_silu_cols: coverpoint sampled_cols {
      bins c_one_tile   = {[1:64]};
      bins c_two_tile   = {[65:128]};
      bins c_three_tile = {[129:172]};
    }
    cx_silu_rows: cross cp_silu_en, cp_silu_rows;
    cx_silu_cols: cross cp_silu_en, cp_silu_cols;
  endgroup

  // --- cg_prefetch: 权重预取 × 目标 × 是否被配置写作废 × 维度边界 ---
  // 交叉的意义：预取只对"首块"有效，所以尾块(rows非32倍数)和多tile(cols>64)
  // 这两条边界最容易出问题——命中后跳过了S_DMA_MI_INIT，num_tiles_reg必须
  // 已被补算，否则S_CHECK_LOOP会拿上一次任务的tile数去判循环。
  // pf_killed那一维覆盖失效回退路径：作废后必须老实走正常搬运，结果照样要对。
  covergroup cg_prefetch;
    cp_pf_issued: coverpoint sampled_pf_issued { bins no = {0}; bins yes = {1}; }
    cp_pf_target: coverpoint sampled_pf_target {
      bins tgt_gemv = {0};
      bins tgt_fsa  = {1};
    }
    cp_pf_killed: coverpoint sampled_pf_killed {
      bins live   = {0};   // 预取有效，应命中
      bins killed = {1};   // 被配置写作废，应回退
    }
    cp_pf_rows: coverpoint sampled_rows {
      bins r_tail_tiny = {[1:7]};    // 首块行数 min(32,d) 极小
      bins r_tail_part = {[8:31]};
      bins r_exact32   = {32};       // 首块正好占满
      bins r_cross     = {[33:63]};  // 首块命中 + 后续块正常搬
      bins r_exact64   = {64};
      bins r_big       = {[65:512]};
    }
    cp_pf_cols: coverpoint sampled_cols {
      bins c_one_tile   = {[1:64]};
      bins c_two_tile   = {[65:128]};
      bins c_three_tile = {[129:172]};
    }
    // 只在真发了预取时交叉才有意义
    cx_pf_rows:   cross cp_pf_issued, cp_pf_rows;
    cx_pf_cols:   cross cp_pf_issued, cp_pf_cols;
    cx_pf_kill:   cross cp_pf_issued, cp_pf_killed;
    cx_pf_target: cross cp_pf_issued, cp_pf_target;
  endgroup

  // --- cg_fsa_config: head_dim × seq_len × group_mode ---
  covergroup cg_fsa_config;
    cp_head_dim: coverpoint sampled_head_dim { bins d8 = {8}; bins d16 = {16}; bins d32 = {32}; }
    cp_seq_len: coverpoint sampled_seq_len {
      bins s_small  = {[1:8]};
      bins s_mid    = {[9:32]};
      bins s_large  = {[33:80]};
      bins s_xlarge = {[81:160]};
    }
    cp_group_mode: coverpoint sampled_group_mode { bins m0 = {0}; bins m1 = {1}; bins m2 = {2}; }
    cx_fsa: cross cp_head_dim, cp_seq_len, cp_group_mode;
  endgroup

  // --- cg_stress: 模式切换transition ---
  covergroup cg_stress;
    cp_switch: coverpoint sampled_mode {
      bins gemv_to_fsa  = (0 => 1);
      bins fsa_to_gemv  = (1 => 0);
      bins gemv_to_gemv = (0 => 0);
      bins fsa_to_fsa   = (1 => 1);
    }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_csr_access  = new();
    cg_mode_config = new();
    cg_gemv_dims   = new();
    cg_fsa_config  = new();
    cg_silu        = new();
    cg_prefetch    = new();
    cg_stress      = new();
  endfunction

  // 每次monitor广播事务时调用
  virtual function void write(axi_slv_seq_item t);
    sampled_addr     = t.addr;
    sampled_is_write = (t.rw == axi_slv_seq_item::AXI_WRITE);

    // 每笔CSR事务采样地址覆
    cg_csr_access.sample();

    // 预取触发（0x005C bit[0]=start脉冲，bit[1]=target）
    if (t.addr == 32'h005C && sampled_is_write && t.wdata[0]) begin
      pending_pf_issued = 1;
      pending_pf_target = t.wdata[1];
      pending_pf_killed = 0;   // 新预取覆盖旧的，失效标记重新计时
    end

    // 预取之后又写了"决定搬什么/搬多少"的寄存器 => 硬件会判定预取作废。
    // 这几个地址与RTL里pf_kill_cfg的判定列表严格一致，改一处必须改另一处。
    if (pending_pf_issued && sampled_is_write &&
        (t.addr == 32'h0014 ||   // MI_BASE
         t.addr == 32'h0020 ||   // ROWS
         t.addr == 32'h0024 ||   // COLS
         t.addr == 32'h0034 ||   // K_BASE
         t.addr == 32'h0040 ||   // HEAD_DIM
         t.addr == 32'h0048 ||   // KV_STRIDE
         t.addr == 32'h004C))    // NUM_HEADS
      pending_pf_killed = 1;

    // 写CTRL且start=1时，采样配置覆盖率
    if (t.addr == 32'h0000 && sampled_is_write && t.wdata[0]) begin
      if (ral == null) return;

      sampled_mode = t.wdata[1];  // mode位直接从写数据获取
      cg_mode_config.sample();
      cg_stress.sample();

      if (sampled_mode == 0) begin
        sampled_rows = ral.rows.get_mirrored_value();
        sampled_cols = ral.cols.get_mirrored_value();
        cg_gemv_dims.sample();
        sampled_silu_en = ral.act_ctrl.get_mirrored_value() & 32'h1;
        cg_silu.sample();

        // 预取覆盖率：把累积到这一刻的预取状态定格采样，随后清零——
        // 预取只对紧接着的这一次任务有效，不能跨任务累积
        sampled_pf_issued = pending_pf_issued;
        sampled_pf_target = pending_pf_target;
        sampled_pf_killed = pending_pf_killed;
        cg_prefetch.sample();
        pending_pf_issued = 0;
        pending_pf_target = 0;
        pending_pf_killed = 0;
      end else begin
        sampled_head_dim   = ral.head_dim.get_mirrored_value();
        sampled_seq_len    = ral.seq_len.get_mirrored_value();
        sampled_group_mode = ral.group_mode.get_mirrored_value();
        cg_fsa_config.sample();
        // FSA任务同样会消费/作废预取，这里必须一并清零。不采样cg_prefetch是因为
        // 它的rows/cols维度对FSA没有意义，采了只会把上一次GEMV的维度混进来。
        // cp_pf_target的tgt_fsa那个bin靠"GEMV任务前发FSA-target预取"(pf_mode=4)
        // 那条失效规则3的用例来覆盖。
        pending_pf_issued = 0;
        pending_pf_target = 0;
        pending_pf_killed = 0;
      end
    end
  endfunction

endclass

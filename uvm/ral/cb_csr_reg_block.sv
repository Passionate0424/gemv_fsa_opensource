// CB_top_v2 CSR寄存器抽象层（UVM RAL）
// 包含18个CSR寄存器的字段定义和地址映射

// ============================================================
// 寄存器类定义
// ============================================================

// CTRL寄存器: [0]=start, [1]=mode
class cb_reg_ctrl extends uvm_reg;
  `uvm_object_utils(cb_reg_ctrl)
  rand uvm_reg_field start_bit;
  rand uvm_reg_field mode;
  rand uvm_reg_field reserved;

  function new(string name = "cb_reg_ctrl");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    start_bit = uvm_reg_field::type_id::create("start_bit");
    start_bit.configure(this, 1, 0, "RW", 0, 1'b0, 1, 1, 0);
    mode = uvm_reg_field::type_id::create("mode");
    mode.configure(this, 1, 1, "RW", 0, 1'b0, 1, 1, 0);
    reserved = uvm_reg_field::type_id::create("reserved");
    reserved.configure(this, 30, 2, "RW", 0, 30'h0, 1, 1, 0);
  endfunction
endclass

// STATUS寄存器: [0]=busy, [1]=done, [2]=pf_valid, [3]=pf_target,
//               [8]=dma_err, [9]=mac_err (只读)
class cb_reg_status extends uvm_reg;
  `uvm_object_utils(cb_reg_status)
  rand uvm_reg_field busy;
  rand uvm_reg_field done;
  rand uvm_reg_field pf_valid;
  rand uvm_reg_field pf_target;
  rand uvm_reg_field reserved_1;
  rand uvm_reg_field dma_err;
  rand uvm_reg_field mac_err;
  rand uvm_reg_field reserved_2;

  function new(string name = "cb_reg_status");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    busy = uvm_reg_field::type_id::create("busy");
    busy.configure(this, 1, 0, "RO", 0, 1'b0, 1, 0, 0);
    done = uvm_reg_field::type_id::create("done");
    done.configure(this, 1, 1, "RO", 0, 1'b0, 1, 0, 0);
    // 预取状态镜像位。必须从reserved_1里拆出来单独声明——RTL已经在驱动它们，
    // 若仍算作"恒0的保留位"，RAL的mirror/predict会把正常的预取状态判成不一致
    pf_valid = uvm_reg_field::type_id::create("pf_valid");
    pf_valid.configure(this, 1, 2, "RO", 0, 1'b0, 1, 0, 0);
    pf_target = uvm_reg_field::type_id::create("pf_target");
    pf_target.configure(this, 1, 3, "RO", 0, 1'b0, 1, 0, 0);
    reserved_1 = uvm_reg_field::type_id::create("reserved_1");
    reserved_1.configure(this, 4, 4, "RO", 0, 4'h0, 1, 0, 0);
    dma_err = uvm_reg_field::type_id::create("dma_err");
    dma_err.configure(this, 1, 8, "RO", 0, 1'b0, 1, 0, 0);
    mac_err = uvm_reg_field::type_id::create("mac_err");
    mac_err.configure(this, 1, 9, "RO", 0, 1'b0, 1, 0, 0);
    reserved_2 = uvm_reg_field::type_id::create("reserved_2");
    reserved_2.configure(this, 22, 10, "RO", 0, 22'h0, 1, 0, 0);
  endfunction
endclass

// 通用32位RW寄存器（用于地址/维度/配置类寄存器）
class cb_reg_generic_rw extends uvm_reg;
  `uvm_object_utils(cb_reg_generic_rw)
  rand uvm_reg_field value;

  function new(string name = "cb_reg_generic_rw");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    value = uvm_reg_field::type_id::create("value");
    value.configure(this, 32, 0, "RW", 0, 32'h0, 1, 1, 0);
  endfunction
endclass

// 通用32位RO寄存器（ERR_CODE）
class cb_reg_generic_ro extends uvm_reg;
  `uvm_object_utils(cb_reg_generic_ro)
  rand uvm_reg_field value;

  function new(string name = "cb_reg_generic_ro");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    value = uvm_reg_field::type_id::create("value");
    value.configure(this, 32, 0, "RO", 0, 32'h0, 1, 0, 0);
  endfunction
endclass

// GROUP_MODE寄存器：只有bit[1:0]有效（RTL只实现2位）
class cb_reg_group_mode extends uvm_reg;
  `uvm_object_utils(cb_reg_group_mode)
  rand uvm_reg_field mode;
  rand uvm_reg_field reserved;

  function new(string name = "cb_reg_group_mode");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    mode = uvm_reg_field::type_id::create("mode");
    mode.configure(this, 2, 0, "RW", 0, 2'h0, 1, 1, 0);
    reserved = uvm_reg_field::type_id::create("reserved");
    reserved.configure(this, 30, 2, "RO", 0, 30'h0, 1, 0, 0);
  endfunction
endclass

// ACT_CTRL寄存器（0x0058）：激活函数融合控制，只有bit[0]=silu_en有效
// SiLU融合只在GEMV模式下生效，RTL侧用 csr_act_ctrl[0] & ~mode_fsa 做门控
class cb_reg_act_ctrl extends uvm_reg;
  `uvm_object_utils(cb_reg_act_ctrl)
  rand uvm_reg_field silu_en;
  rand uvm_reg_field reserved;

  function new(string name = "cb_reg_act_ctrl");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    silu_en = uvm_reg_field::type_id::create("silu_en");
    silu_en.configure(this, 1, 0, "RW", 0, 1'h0, 1, 1, 0);
    reserved = uvm_reg_field::type_id::create("reserved");
    reserved.configure(this, 31, 1, "RO", 0, 31'h0, 1, 0, 0);
  endfunction
endclass

// PF_CTRL寄存器（0x005C）：权重预取触发，WO。
// [0]=start是脉冲型——写1触发一次搬运，硬件不保持这个值；[1]=target选GEMV权重
// 还是FSA的K。读回恒0，所以全部字段声明为WO，别让bit-bash去比对读回值；
// 预取的实际状态在STATUS[2]/[3]那两个RO位上看。
class cb_reg_pf_ctrl extends uvm_reg;
  `uvm_object_utils(cb_reg_pf_ctrl)
  rand uvm_reg_field start;
  rand uvm_reg_field target;
  rand uvm_reg_field reserved;

  function new(string name = "cb_reg_pf_ctrl");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    start = uvm_reg_field::type_id::create("start");
    start.configure(this, 1, 0, "WO", 0, 1'h0, 1, 1, 0);
    target = uvm_reg_field::type_id::create("target");
    target.configure(this, 1, 1, "WO", 0, 1'h0, 1, 1, 0);
    reserved = uvm_reg_field::type_id::create("reserved");
    reserved.configure(this, 30, 2, "WO", 0, 30'h0, 1, 0, 0);
  endfunction
endclass

// ============================================================
// 寄存器块
// ============================================================
class cb_csr_reg_block extends uvm_reg_block;
  `uvm_object_utils(cb_csr_reg_block)

  // 寄存器实例
  cb_reg_ctrl        ctrl;
  cb_reg_status      status;
  cb_reg_generic_ro  err_code;
  cb_reg_generic_rw  vi_base;
  cb_reg_generic_rw  mi_base;
  cb_reg_generic_rw  vo_base;
  cb_reg_generic_rw  rows;
  cb_reg_generic_rw  cols;
  cb_reg_generic_rw  q_base;
  cb_reg_generic_rw  k_base;
  cb_reg_generic_rw  v_base;
  cb_reg_generic_rw  o_base;
  cb_reg_generic_rw  head_dim;
  cb_reg_generic_rw  seq_len;
  cb_reg_generic_rw  kv_stride;
  cb_reg_generic_rw  num_heads;
  cb_reg_generic_rw  attn_scale;
  cb_reg_group_mode  group_mode;
  cb_reg_act_ctrl    act_ctrl;
  cb_reg_pf_ctrl     pf_ctrl;

  uvm_reg_map default_map;

  function new(string name = "cb_csr_reg_block");
    super.new(name, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    // 创建地址映射：基地址0，字节宽度4，小端
    default_map = create_map("default_map", 'h0, 4, UVM_LITTLE_ENDIAN);

    // CTRL (0x0000)
    ctrl = cb_reg_ctrl::type_id::create("ctrl");
    ctrl.configure(this, null, "");
    ctrl.build();
    default_map.add_reg(ctrl, 'h0000, "RW");

    // STATUS (0x0004)
    status = cb_reg_status::type_id::create("status");
    status.configure(this, null, "");
    status.build();
    default_map.add_reg(status, 'h0004, "RO");

    // ERR_CODE (0x0008)
    err_code = cb_reg_generic_ro::type_id::create("err_code");
    err_code.configure(this, null, "");
    err_code.build();
    default_map.add_reg(err_code, 'h0008, "RO");

    // GEMV参数
    vi_base = cb_reg_generic_rw::type_id::create("vi_base");
    vi_base.configure(this, null, "");
    vi_base.build();
    default_map.add_reg(vi_base, 'h0010, "RW");

    mi_base = cb_reg_generic_rw::type_id::create("mi_base");
    mi_base.configure(this, null, "");
    mi_base.build();
    default_map.add_reg(mi_base, 'h0014, "RW");

    vo_base = cb_reg_generic_rw::type_id::create("vo_base");
    vo_base.configure(this, null, "");
    vo_base.build();
    default_map.add_reg(vo_base, 'h0018, "RW");

    rows = cb_reg_generic_rw::type_id::create("rows");
    rows.configure(this, null, "");
    rows.build();
    default_map.add_reg(rows, 'h0020, "RW");

    cols = cb_reg_generic_rw::type_id::create("cols");
    cols.configure(this, null, "");
    cols.build();
    default_map.add_reg(cols, 'h0024, "RW");

    // FSA参数
    q_base = cb_reg_generic_rw::type_id::create("q_base");
    q_base.configure(this, null, "");
    q_base.build();
    default_map.add_reg(q_base, 'h0030, "RW");

    k_base = cb_reg_generic_rw::type_id::create("k_base");
    k_base.configure(this, null, "");
    k_base.build();
    default_map.add_reg(k_base, 'h0034, "RW");

    v_base = cb_reg_generic_rw::type_id::create("v_base");
    v_base.configure(this, null, "");
    v_base.build();
    default_map.add_reg(v_base, 'h0038, "RW");

    o_base = cb_reg_generic_rw::type_id::create("o_base");
    o_base.configure(this, null, "");
    o_base.build();
    default_map.add_reg(o_base, 'h003C, "RW");

    head_dim = cb_reg_generic_rw::type_id::create("head_dim");
    head_dim.configure(this, null, "");
    head_dim.build();
    default_map.add_reg(head_dim, 'h0040, "RW");

    seq_len = cb_reg_generic_rw::type_id::create("seq_len");
    seq_len.configure(this, null, "");
    seq_len.build();
    default_map.add_reg(seq_len, 'h0044, "RW");

    kv_stride = cb_reg_generic_rw::type_id::create("kv_stride");
    kv_stride.configure(this, null, "");
    kv_stride.build();
    default_map.add_reg(kv_stride, 'h0048, "RW");

    num_heads = cb_reg_generic_rw::type_id::create("num_heads");
    num_heads.configure(this, null, "");
    num_heads.build();
    default_map.add_reg(num_heads, 'h004C, "RW");

    attn_scale = cb_reg_generic_rw::type_id::create("attn_scale");
    attn_scale.configure(this, null, "");
    attn_scale.build();
    attn_scale.value.set_reset(32'h3F0293EE);  // RTL默认值（head_dim=8）
    default_map.add_reg(attn_scale, 'h0050, "RW");

    group_mode = cb_reg_group_mode::type_id::create("group_mode");
    group_mode.configure(this, null, "");
    group_mode.build();
    default_map.add_reg(group_mode, 'h0054, "RW");

    // ACT_CTRL (0x0058) - SiLU融合使能
    act_ctrl = cb_reg_act_ctrl::type_id::create("act_ctrl");
    act_ctrl.configure(this, null, "");
    act_ctrl.build();
    default_map.add_reg(act_ctrl, 'h0058, "RW");

    // PF_CTRL (0x005C) - 权重预取触发（WO，读回恒0）
    pf_ctrl = cb_reg_pf_ctrl::type_id::create("pf_ctrl");
    pf_ctrl.configure(this, null, "");
    pf_ctrl.build();
    default_map.add_reg(pf_ctrl, 'h005C, "WO");

    lock_model();
  endfunction
endclass

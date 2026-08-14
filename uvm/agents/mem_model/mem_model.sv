// 行为级DDR存储模型（纯Backdoor访问层）
// AXI时序由tb_top中的tb_axi_ram_sp_ext RTL模块处理
// 本组件通过uvm_hdl_deposit/uvm_hdl_read做backdoor访问DDR mem数组
class mem_model extends uvm_component;

  virtual axi_mst_if vif;

  // DDR mem的层次路径（在tb_top中的tb_axi_ram_sp_ext实例）
  string mem_path = "tb_top.u_ddr.mem";

  `uvm_component_utils(mem_model)

  function new(string name = "mem_model", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axi_mst_if)::get(this, "", "axi_mst_vif", vif))
      `uvm_fatal("NOVIF", "未获取到axi_mst_vif")
  endfunction

  // ============================================================
  // Backdoor API（通过uvm_hdl DPI访问tb_axi_ram_sp_ext的mem数组）
  // ============================================================

  // 写入单个字（按字节地址）
  function void write_word(input int unsigned byte_addr, input logic [31:0] data);
    string path;
    path = $sformatf("%s[%0d]", mem_path, byte_addr >> 2);
    void'(uvm_hdl_deposit(path, data));
  endfunction

  // 读取单个字（按字节地址）
  function logic [31:0] read_word(input int unsigned byte_addr);
    string path;
    uvm_hdl_data_t value;
    path = $sformatf("%s[%0d]", mem_path, byte_addr >> 2);
    void'(uvm_hdl_read(path, value));
    return value[31:0];
  endfunction

  // 批量加载数据
  function void load_region(input int unsigned base_addr, input logic [31:0] data[], input int size);
    for (int i = 0; i < size; i++)
      write_word(base_addr + i * 4, data[i]);
  endfunction

  // 清除指定区域
  function void clear_region(input int unsigned base_addr, input int num_words);
    for (int i = 0; i < num_words; i++)
      write_word(base_addr + i * 4, 32'h0);
  endfunction

endclass

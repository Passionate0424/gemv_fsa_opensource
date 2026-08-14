// CSR Access Test
// 利用UVM RAL内置sequence验证所有CSR寄存器的复位值和读写功能
class csr_access_test extends cb_top_base_test;

  `uvm_component_utils(csr_access_test)

  function new(string name = "csr_access_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_test_body(uvm_phase phase);
    uvm_status_e   status;
    uvm_reg_data_t value;

    `uvm_info("CSR_TEST", "启动CSR寄存器访问测试", UVM_MEDIUM)

    // 1) 复位值检查：读所有寄存器，验证与RAL reset值一致
    begin
      uvm_reg_hw_reset_seq reset_seq;
      reset_seq = uvm_reg_hw_reset_seq::type_id::create("reset_seq");
      reset_seq.model = env.ral;
      reset_seq.start(null);
      `uvm_info("CSR_TEST", "hw_reset_seq完成", UVM_MEDIUM)
    end

    // 2) Bit-bash：对所有RW寄存器逐bit写1/0验证
    //    排除STATUS：bit_bash测CTRL时写start=1触发FSM，STATUS.busy被硬件拉高
    //    这是硬件正常行为，不是bug，但会导致bit_bash误报
    begin
      uvm_reg_bit_bash_seq bash_seq;
      uvm_resource_db#(bit)::set({"REG::", env.ral.status.get_full_name()},
                                  "NO_REG_BIT_BASH_TEST", 1, this);
      // PF_CTRL必须排除：它是WO触发寄存器，bit_bash往bit[0]写1会真的发起一次
      // 权重预取DMA，而那时CSR里是bit_bash自己写进去的垃圾地址/维度。轻则搬一堆
      // 无意义数据污染权重SRAM，重则DMA访问非法地址不返回、S_PF_WAIT死等dma_done
      // 直接把测试挂死。预取通路的验证在 pf_* 那组test里，不该由bit_bash来碰。
      uvm_resource_db#(bit)::set({"REG::", env.ral.pf_ctrl.get_full_name()},
                                  "NO_REG_BIT_BASH_TEST", 1, this);
      bash_seq = uvm_reg_bit_bash_seq::type_id::create("bash_seq");
      bash_seq.model = env.ral;
      bash_seq.start(null);
      `uvm_info("CSR_TEST",
                "bit_bash_seq完成（STATUS排除：硬件动态状态；PF_CTRL排除：写1有DMA副作用）",
                UVM_MEDIUM)
    end

    `uvm_info("CSR_TEST", "CSR寄存器访问测试全部完成", UVM_MEDIUM)
  endtask

endclass

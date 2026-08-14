## 设计审核问题（2026/05/14提出）

1. ✅ Accumulator代码没使用4拍流水后的FMA模块rtl\PE\RawFloat_FMA.sv，时序性能有风险
   → 决策：Phase 5替换为4拍流水版本。流水实现下连续发射不降吞吐，只需延迟匹配。

2. ✅ fsm未实现fsa的flashattention算子的循环分块累加
   → 决策：采用显式状态机（非逐拍控制表），完整tile循环已设计。见plan §9.1。

3. ✅ 延迟匹配skew网络不是复用的，而是每种模式单独genvar一遍，寄存器没有复用
   → 决策：后续实施"最大延迟链+MUX tap"方案。当前8×4模式先不改。

4. ✅ 输入的k矩阵行维度小于bank深度时的放置问题
   → 决策：复用现有DMA紧密搬运模式（current_cols=head_dim=8），不需要padding。
   → 验证：CB_top.v中dma_w_addr_in_bank_cnt在写满current_cols后切换bank，完全兼容。

5. 绝对位置因果掩码

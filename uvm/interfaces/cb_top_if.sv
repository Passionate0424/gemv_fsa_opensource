// CB_top_v2 杂项信号接口（done/debug）
interface cb_top_if (input logic clk, input logic rst_n);

  logic        CB_done;
  logic [4:0]  debug_state;
  logic [15:0] debug_data;

  // Scoreboard用：等待done拉高
  clocking mon_cb @(posedge clk);
    input CB_done;
    input debug_state;
    input debug_data;
  endclocking

  modport monitor (clocking mon_cb, input rst_n);

endinterface

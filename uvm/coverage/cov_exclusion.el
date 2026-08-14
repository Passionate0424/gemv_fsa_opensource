// VCS Coverage Exclusion File
// 排除参数化死代码（当前32位配置不可达路径）
// 使用: urg -dir simv_uvm_cov.vdb -elfile uvm/coverage/cov_exclusion.el

MODULE: axi_dma_controller
Line 479 "w_trans_num: TRANS_PER_DATA=1, else if分支不触发"
Line 481 "w_trans_num: WREADY&&WVALID递增不触发"
Line 482 "w_trans_num: 递增逻辑死路径"
Line 484 "w_trans_num: else保持逻辑死路径"
Line 494 "wstrb: cmd_size=2 不可达"
Line 495 "wstrb: cmd_size=4 不可达"
Line 496 "wstrb: cmd_size=8 不可达"
Line 497 "wstrb: cmd_size=16 不可达"
Line 503 "wstrb: cmd_size=2 case 不可达"
Line 504 "wstrb: cmd_size=2 case0 不可达"
Line 505 "wstrb: cmd_size=2 TRANS_PER_DATA 不可达"
Line 506 "wstrb: cmd_size=2 default 不可达"
Line 510 "wstrb: cmd_size=4 case 不可达"
Line 511 "wstrb: cmd_size=4 case0 不可达"
Line 512 "wstrb: cmd_size=4 TRANS_PER_DATA 不可达"
Line 513 "wstrb: cmd_size=4 default 不可达"
Line 517 "wstrb: cmd_size=8 case 不可达"
Line 518 "wstrb: cmd_size=8 case0 不可达"
Line 519 "wstrb: cmd_size=8 TRANS_PER_DATA 不可达"
Line 520 "wstrb: cmd_size=8 default 不可达"
Line 524 "wstrb: cmd_size=16 case 不可达"
Line 525 "wstrb: cmd_size=16 case0 不可达"
Line 526 "wstrb: cmd_size=16 TRANS_PER_DATA 不可达"
Line 527 "wstrb: cmd_size=16 default 不可达"

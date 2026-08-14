open_checkpoint reports/soc_bitgen/soc_top_synth.dcp
set f [open reports/soc_bitgen/debug_nets.txt w]
puts $f "=== clock nets ==="
foreach n [get_nets -hier -filter {NAME =~ *sys_clk*}] { puts $f $n }
puts $f "=== controller state ==="
foreach n [get_nets -hier -filter {NAME =~ *u_controller/state_reg*}] { puts $f $n }
puts $f "=== fsm state ==="
foreach n [get_nets -hier -filter {NAME =~ *u_fsm/state*}] { puts $f $n }
puts $f "=== done/valid ==="
foreach n [get_nets -hier -filter {NAME =~ *dma_done*}] { puts $f $n }
foreach n [get_nets -hier -filter {NAME =~ *fsa_done*}] { puts $f $n }
foreach n [get_nets -hier -filter {NAME =~ *ctrl_done*}] { puts $f $n }
puts $f "=== seq_len ==="
foreach n [get_nets -hier -filter {NAME =~ *csr_seq_len*}] { puts $f $n }
close $f
close_design

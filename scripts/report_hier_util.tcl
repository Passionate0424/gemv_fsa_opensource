# =============================================================================
# report_hier_util.tcl - 从已布线的 DCP 出层次化资源报告
# =============================================================================
# 用途：回答"某个子模块占了多少 LUT/FF"这类问题。常规 bitgen 出的
# utilization_routed.rpt 只有全芯片总量，拆不到实例级——例如评估
# "把 AxiCrossbar 从32位改成64位放不放得下"就必须先知道它现在占多少。
#
# 用法（远程）：
#   vivado -mode batch -source scripts/report_hier_util.tcl \
#          -tclargs <routed.dcp> <输出.rpt>
# =============================================================================

if {$argc < 2} {
    puts "ERROR: usage: -tclargs <routed.dcp> <out.rpt>"
    exit 1
}
set dcp  [lindex $argv 0]
set out  [lindex $argv 1]

if {![file exists $dcp]} {
    puts "ERROR: dcp not found: $dcp"
    exit 1
}

puts "\[step\] open $dcp"
open_checkpoint $dcp

puts "\[step\] report_utilization -hierarchical -> $out"
report_utilization -hierarchical -hierarchical_depth 3 -file $out

puts "\[done\] $out"

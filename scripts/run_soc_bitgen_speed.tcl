# =============================================================================
# run_soc_bitgen.tcl - SoC全流程bitstream生成（非项目模式）
# =============================================================================
# 用法:
#   vivado -mode batch -source scripts/run_soc_bitgen.tcl
#   vivado -mode batch -source scripts/run_soc_bitgen.tcl -tclargs -filelist=scripts/soc_synth_filelist.f
#
# 关键策略:
#   综合: PerformanceOptimized + retiming（面积紧张，retiming优化PE FMA环路）
#   布局: ExtraTimingOpt（时序驱动）
#   物理优化: AggressiveExplore + AggressiveFanoutOpt（双轮）
#   布线: AggressiveExplore
#   后布线: AggressiveExplore + Explore（双轮post-route phys_opt）
#
# 关键约束:
#   - set_case_analysis 1 on mode_q: opt_design后加（综合不删FSA逻辑，P&R只分析OS路径）
#   - set_clock_uncertainty 0.5ns: P&R期间加紧目标，报告前移除显示真实WNS
#   - set_multicycle_path 2 on CSR: 静态配置路径允许2周期
#   - set_clock_groups -asynchronous: cpu_clk vs sys_clk（RTL中有Axi_CDC处理）
#
# 注意:
#   - PE_retimed的flow_to_d_*_q寄存器加了DONT_TOUCH防止retiming移动
#   - 不在XDC中放set_case_analysis（会导致综合删FSA逻辑）
# =============================================================================

set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ..]]

# 默认参数
set top_name "soc_top"
set filelist_rel "scripts/soc_synth_filelist.f"
set part_name "xc7a200tfbg676-1"
set xdc_rel "soc/fpga/constraints/soc.xdc"
set out_rel "reports/soc_bitgen"

# 命令行参数解析
foreach arg $argv {
  if {[regexp {^-top=(.+)$} $arg -> val]} {
    set top_name $val
  } elseif {[regexp {^-filelist=(.+)$} $arg -> val]} {
    set filelist_rel $val
  } elseif {[regexp {^-part=(.+)$} $arg -> val]} {
    set part_name $val
  } elseif {[regexp {^-xdc=(.+)$} $arg -> val]} {
    set xdc_rel $val
  } elseif {[regexp {^-out=(.+)$} $arg -> val]} {
    set out_rel $val
  }
}

set out_dir [file normalize [file join $repo_root $out_rel]]
file mkdir $out_dir

# =============================================================================
# Filelist解析（复用run_vivado_synth.tcl逻辑）
# =============================================================================
set src_files {}
set inc_dirs {}
set defines {}

proc normalize_entry {entry base_dir repo_root} {
  set entry [string trim $entry]
  if {[file pathtype $entry] eq "absolute"} {
    return [file normalize $entry]
  }
  if {[string match "./*" $entry]} {
    return [file normalize [file join $repo_root $entry]]
  }
  return [file normalize [file join $base_dir $entry]]
}

proc read_filelist_recursive {file_path repo_root src_var inc_var def_var} {
  upvar $src_var src_files
  upvar $inc_var inc_dirs
  upvar $def_var defines

  set file_path [file normalize $file_path]
  set base_dir [file dirname $file_path]
  set fh [open $file_path r]

  while {[gets $fh line] >= 0} {
    set line [string trim $line]
    if {$line eq ""} { continue }
    if {[string match "#*" $line] || [string match "//*" $line]} { continue }
    set comment_pos [string first " #" $line]
    if {$comment_pos >= 0} {
      set line [string trim [string range $line 0 $comment_pos]]
    }

    if {[string match "+incdir+*" $line]} {
      set inc [string range $line 8 end]
      lappend inc_dirs [normalize_entry $inc $base_dir $repo_root]
    } elseif {[string match "+define+*" $line]} {
      foreach def [split [string range $line 8 end] "+"] {
        if {$def ne ""} { lappend defines $def }
      }
    } elseif {[regexp {^-f\s+(.+)$} $line -> nested]} {
      set nested_path [normalize_entry $nested $base_dir $repo_root]
      read_filelist_recursive $nested_path $repo_root src_files inc_dirs defines
    } else {
      lappend src_files [normalize_entry $line $base_dir $repo_root]
    }
  }
  close $fh
}

set filelist_path [file normalize [file join $repo_root $filelist_rel]]
read_filelist_recursive $filelist_path $repo_root src_files inc_dirs defines

set src_files [lsort -unique $src_files]
set inc_dirs [lsort -unique $inc_dirs]
set defines [lsort -unique $defines]

puts "INFO: repo_root=$repo_root"
puts "INFO: top=$top_name"
puts "INFO: part=$part_name"
puts "INFO: filelist=$filelist_path"
puts "INFO: source_count=[llength $src_files]"
puts "INFO: include_count=[llength $inc_dirs]"
puts "INFO: out_dir=$out_dir"

# =============================================================================
# 综合
# =============================================================================
if {[llength $inc_dirs]} {
  set_property include_dirs $inc_dirs [current_fileset]
}
if {[llength $defines]} {
  set_property verilog_define $defines [current_fileset]
}
read_verilog -sv $src_files

# 读取约束
set xdc_path [file normalize [file join $repo_root $xdc_rel]]
read_xdc $xdc_path

# 综合（SIMULATION=0，使用PLL，面积优化）
synth_design -top $top_name -part $part_name \
  -flatten_hierarchy rebuilt -directive PerformanceOptimized -retiming \
  -generic "SIMULATION=1'b0"

# 综合后报告
report_utilization -file [file join $out_dir utilization_synth.rpt]
report_timing_summary -delay_type max -max_paths 10 -file [file join $out_dir timing_summary_synth.rpt]
write_checkpoint -force [file join $out_dir ${top_name}_synth.dcp]

set synth_wns [get_property SLACK [get_timing_paths -max_paths 1 -delay_type max]]
puts "INFO: Post-synth WNS = $synth_wns"

# =============================================================================
# 时序例外约束（综合后）
# =============================================================================
# CSR配置路径是静态的（计算期间不变），允许2周期
set csr_src [get_cells -quiet -hier -filter {NAME =~ */u_controller/csr_*_reg*}]
if {[llength $csr_src] > 0} {
  set_multicycle_path 2 -setup -from $csr_src
  set_multicycle_path 1 -hold -from $csr_src
  puts "INFO: set_multicycle_path 2 on [llength $csr_src] CSR source cells"
}

# =============================================================================
# 实现（Place & Route）
# =============================================================================
puts "INFO: Starting implementation..."

opt_design

# set_case_analysis放在opt_design之后：opt不会删逻辑，place/route用于时序分析
set mode_pins [get_pins -quiet -hier -filter {NAME =~ */mode_q_reg/Q}]
if {[llength $mode_pins] > 0} {
  set_case_analysis 1 $mode_pins
  puts "INFO: set_case_analysis 1 on [llength $mode_pins] mode_q pins (post-opt, for P&R timing)"
} else {
  puts "WARNING: mode_q pins not found for case_analysis"
}

# 增加setup时钟不确定度，为PVT波动预留余量（500ps），仅setup不影响hold
set_clock_uncertainty -setup 0.5 [get_clocks sys_clk]
puts "INFO: set_clock_uncertainty -setup 0.5ns on sys_clk (PVT margin)"

place_design -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
phys_opt_design -directive AggressiveFanoutOpt
route_design -directive AggressiveExplore
# 多轮post-route优化
phys_opt_design -directive AggressiveExplore
phys_opt_design -directive Explore

# 移除uncertainty查看真实WNS
set_clock_uncertainty -setup 0 [get_clocks sys_clk]

# 实现后报告
report_timing_summary -delay_type max -max_paths 20 -file [file join $out_dir timing_summary_routed.rpt]
report_utilization -file [file join $out_dir utilization_routed.rpt]
report_route_status -file [file join $out_dir route_status.rpt]
report_design_analysis -congestion -file [file join $out_dir congestion.rpt]
write_checkpoint -force [file join $out_dir ${top_name}_routed.dcp]

set impl_wns [get_property SLACK [get_timing_paths -max_paths 1 -delay_type max]]
puts "INFO: Post-route WNS = $impl_wns"

# =============================================================================
# 生成Bitstream
# =============================================================================
puts "INFO: Generating bitstream..."
write_bitstream -force [file join $out_dir ${top_name}.bit]

puts "INFO: ============================================"
puts "INFO: Bitstream generated: [file join $out_dir ${top_name}.bit]"
puts "INFO: Post-synth WNS  = $synth_wns"
puts "INFO: Post-route WNS  = $impl_wns"
puts "INFO: ============================================"

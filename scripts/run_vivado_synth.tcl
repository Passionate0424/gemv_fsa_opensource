###############################################################################
# run_vivado_synth.tcl - 本地/远程 Vivado 综合入口脚本
###############################################################################
# 用途:
#   读取综合相关环境变量或命令行参数，组织 filelist、include dir 和
#   约束参数后，驱动 Vivado 对指定 top 做综合。
#
# 典型用法:
#   vivado -mode batch -source scripts/run_vivado_synth.tcl
#   vivado -mode batch -source scripts/run_vivado_synth.tcl -top=CB_top_v2 -filelist=scripts/cb_top_v2_synth_filelist.f
#
# 参数:
#   -top           综合顶层模块名
#   -filelist      RTL filelist 路径
#   -part          FPGA 器件型号
#   -clock_port    时钟端口名
#   -clock_period  时钟周期
#   -out           输出目录
###############################################################################

set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ..]]

set top_name "fsa_axi_top"
set filelist_rel "sim/filelist.rtl.f"
set part_name "xc7a200tfbg676-1"
set clock_port "clk"
set clock_period "20.000"
set out_rel "reports/synth/fsa_axi_top_vivado"

if {[info exists ::env(FSA_SYNTH_TOP)] && $::env(FSA_SYNTH_TOP) ne ""} {
  set top_name $::env(FSA_SYNTH_TOP)
}
if {[info exists ::env(FSA_SYNTH_FILELIST)] && $::env(FSA_SYNTH_FILELIST) ne ""} {
  set filelist_rel $::env(FSA_SYNTH_FILELIST)
}
if {[info exists ::env(FSA_SYNTH_PART)] && $::env(FSA_SYNTH_PART) ne ""} {
  set part_name $::env(FSA_SYNTH_PART)
}
if {[info exists ::env(FSA_SYNTH_CLOCK_PORT)] && $::env(FSA_SYNTH_CLOCK_PORT) ne ""} {
  set clock_port $::env(FSA_SYNTH_CLOCK_PORT)
}
if {[info exists ::env(FSA_SYNTH_CLOCK_PERIOD)] && $::env(FSA_SYNTH_CLOCK_PERIOD) ne ""} {
  set clock_period $::env(FSA_SYNTH_CLOCK_PERIOD)
}
if {[info exists ::env(FSA_SYNTH_OUT)] && $::env(FSA_SYNTH_OUT) ne ""} {
  set out_rel $::env(FSA_SYNTH_OUT)
}

foreach arg $argv {
  if {[regexp {^-top=(.+)$} $arg -> val]} {
    set top_name $val
  } elseif {[regexp {^-filelist=(.+)$} $arg -> val]} {
    set filelist_rel $val
  } elseif {[regexp {^-part=(.+)$} $arg -> val]} {
    set part_name $val
  } elseif {[regexp {^-clock_port=(.+)$} $arg -> val]} {
    set clock_port $val
  } elseif {[regexp {^-clock_period=(.+)$} $arg -> val]} {
    set clock_period $val
  } elseif {[regexp {^-out=(.+)$} $arg -> val]} {
    set out_rel $val
  }
}

set out_dir [file normalize [file join $repo_root $out_rel]]
file mkdir $out_dir

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

proc normalize_filelist_entry {entry base_dir repo_root} {
  set entry [string trim $entry]
  if {[file pathtype $entry] eq "absolute"} {
    return [file normalize $entry]
  }
  set repo_relative [file normalize [file join $repo_root $entry]]
  if {[file exists $repo_relative]} {
    return $repo_relative
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
    if {$line eq ""} {
      continue
    }
    if {[string match "#*" $line] || [string match "//*" $line]} {
      continue
    }
    set comment_pos [string first " #" $line]
    if {$comment_pos >= 0} {
      set line [string trim [string range $line 0 $comment_pos]]
    }

    if {[string match "+incdir+*" $line]} {
      set inc [string range $line 8 end]
      lappend inc_dirs [normalize_entry $inc $base_dir $repo_root]
    } elseif {[string match "+define+*" $line]} {
      foreach def [split [string range $line 8 end] "+"] {
        if {$def ne ""} {
          lappend defines $def
        }
      }
    } elseif {[regexp {^-f\s+(.+)$} $line -> nested]} {
      set nested_path [normalize_filelist_entry $nested $base_dir $repo_root]
      read_filelist_recursive $nested_path $repo_root src_files inc_dirs defines
    } else {
      lappend src_files [normalize_entry $line $base_dir $repo_root]
    }
  }
  close $fh
}

set filelist_path [file normalize [file join $repo_root $filelist_rel]]
read_filelist_recursive $filelist_path $repo_root src_files inc_dirs defines

# 源文件列表必须**保序**去重，不能用 lsort -unique。
# 纯 Verilog 下模块顺序无所谓，但 SystemVerilog 的 package 必须先于使用者编译；
# 按字母序重排会把 axi_pkg.sv 打散到 axi_atop_filter.sv 等文件之后，
# 导致 Vivado 报 "'axi_pkg' is not declared"（VCS 不受影响，它把所有文件编进同一作用域）。
proc unique_keep_order {lst} {
  set seen [dict create]
  set out {}
  foreach item $lst {
    if {![dict exists $seen $item]} {
      dict set seen $item 1
      lappend out $item
    }
  }
  return $out
}
set src_files [unique_keep_order $src_files]
set inc_dirs [lsort -unique $inc_dirs]
set defines [lsort -unique $defines]

puts "INFO: repo_root=$repo_root"
puts "INFO: top=$top_name"
puts "INFO: part=$part_name"
puts "INFO: filelist=$filelist_path"
puts "INFO: source_count=[llength $src_files]"
puts "INFO: include_count=[llength $inc_dirs]"
puts "INFO: define_count=[llength $defines]"
puts "INFO: out_dir=$out_dir"

set rpt_sources [open [file join $out_dir sources.txt] w]
foreach inc $inc_dirs {
  puts $rpt_sources "+incdir+$inc"
}
foreach def $defines {
  puts $rpt_sources "+define+$def"
}
foreach src $src_files {
  puts $rpt_sources $src
}
close $rpt_sources

if {[llength $inc_dirs]} {
  # Vivado 2024.2 rejects read_verilog -i unless fileset compile-unit mode is
  # enabled. Keep the include dirs on the fileset and let read_verilog ingest
  # the explicit source list directly.
  set_property include_dirs $inc_dirs [current_fileset]
}
if {[llength $defines]} {
  # Vivado 2024.2 only accepts Verilog defines through compile-unit mode or
  # fileset properties, so attach them to the fileset before reading sources.
  set_property verilog_define $defines [current_fileset]
  read_verilog -sv $src_files
} else {
  read_verilog -sv $src_files
}

synth_design -top $top_name -part $part_name -flatten_hierarchy rebuilt -directive default -retiming

if {[llength [get_ports -quiet $clock_port]]} {
  create_clock -period $clock_period -name $clock_port [get_ports $clock_port]
} else {
  puts "WARNING: clock port '$clock_port' not found; timing report may be unconstrained."
}

# CSR配置路径是静态的（计算期间不变），允许2周期
set csr_src [get_cells -quiet -hier -filter {NAME =~ u_controller/csr_*_reg*}]
if {[llength $csr_src] > 0} {
  set_multicycle_path 2 -setup -from $csr_src
  set_multicycle_path 1 -hold -from $csr_src
  puts "INFO: set_multicycle_path 2 on [llength $csr_src] CSR source cells"
}

check_timing -file [file join $out_dir check_timing.rpt]
report_utilization -file [file join $out_dir utilization.rpt]
report_utilization -hierarchical -file [file join $out_dir utilization_hier.rpt]
report_timing_summary -delay_type max -report_unconstrained -check_timing_verbose -max_paths 20 -file [file join $out_dir timing_summary.rpt]
report_timing -delay_type max -sort_by group -max_paths 20 -file [file join $out_dir timing_paths.rpt]
report_clock_utilization -file [file join $out_dir clock_utilization.rpt]
write_checkpoint -force [file join $out_dir ${top_name}_synth.dcp]

# ============================================================
# Implementation (Place & Route)
# ============================================================
if {[info exists ::env(FSA_SYNTH_IMPL)] && $::env(FSA_SYNTH_IMPL) eq "1"} {
  # 参数化directive（支持并行跑不同策略）
  set place_dir "Explore"
  set phys_dir  "AggressiveExplore"
  set route_dir "Explore"
  if {[info exists ::env(FSA_PLACE_DIR)]} { set place_dir $::env(FSA_PLACE_DIR) }
  if {[info exists ::env(FSA_PHYS_DIR)]}  { set phys_dir  $::env(FSA_PHYS_DIR) }
  if {[info exists ::env(FSA_ROUTE_DIR)]} { set route_dir $::env(FSA_ROUTE_DIR) }

  puts "INFO: Running implementation: place=$place_dir phys=$phys_dir route=$route_dir"
  opt_design

  # set_case_analysis放在opt_design之后：不删逻辑，仅用于P&R时序分析
  set mode_pins [get_pins -quiet -hier -filter {NAME =~ */mode_q_reg/Q}]
  if {[llength $mode_pins] > 0} {
    set_case_analysis 1 $mode_pins
    puts "INFO: set_case_analysis 1 on [llength $mode_pins] mode_q pins (post-opt)"
  }

  place_design -directive ExtraTimingOpt
  phys_opt_design -directive AggressiveExplore
  phys_opt_design -directive AggressiveFanoutOpt
  # 多轮phys_opt（如果指定了第二轮directive）
  if {[info exists ::env(FSA_PHYS_DIR2)] && $::env(FSA_PHYS_DIR2) ne ""} {
    phys_opt_design -directive $::env(FSA_PHYS_DIR2)
    puts "INFO: phys_opt round 2: $::env(FSA_PHYS_DIR2)"
  }
  route_design -directive AggressiveExplore
  # post-route优化：尝试最后收敛
  phys_opt_design -directive AggressiveExplore

  report_timing_summary -delay_type max -report_unconstrained -max_paths 20 -file [file join $out_dir timing_summary_routed.rpt]
  report_timing -delay_type max -sort_by group -max_paths 20 -file [file join $out_dir timing_paths_routed.rpt]
  report_utilization -file [file join $out_dir utilization_routed.rpt]
  report_route_status -file [file join $out_dir route_status.rpt]
  report_design_analysis -congestion -file [file join $out_dir congestion.rpt]
  report_design_analysis -timing -file [file join $out_dir design_analysis_timing.rpt]
  write_checkpoint -force [file join $out_dir ${top_name}_routed.dcp]
  puts "INFO: Implementation complete."
}

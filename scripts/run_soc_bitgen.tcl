# =============================================================================
# run_soc_bitgen.tcl - SoC全流程bitstream生成（非项目模式）
# =============================================================================
# 用法:
#   vivado -mode batch -source scripts/run_soc_bitgen.tcl
#   vivado -mode batch -source scripts/run_soc_bitgen.tcl -tclargs -filelist=scripts/soc_synth_filelist.f
#
# 关键策略（对齐GUI项目soc/fpga/project/Loongson_Soc.xpr的runme.log实测参数，
# 2026-06-25验证：同样在Vivado 2024.2下，此前的AreaOptimized_medium+fanout_limit+
# pblock_cmp+ExtraTimingOpt组合WNS=0.208ns，对齐GUI参数后WNS=0.505ns，几乎追平
# GUI项目本身在Vivado 2019.2下的0.517ns——版本差异不是WNS差距的主因，参数才是）:
#   综合: AreaOptimized_medium + retiming，不加fanout_limit/flatten_hierarchy
#   布局: Explore（时序驱动）
#   物理优化: AggressiveFanoutOpt + AggressiveExplore（place后，按此顺序）
#   布线: AggressiveExplore
#   后布线: AggressiveExplore + Explore + AddRetime（三轮，不需要pblock_cmp）
#
# 关键约束:
#   - mode_q双模式各自闭合（关键修复，2026-07-01）：
#     mode_q是运行时模式选择(PE_core_v2.sv: pe_mode_sel=fsa_mode?0:1,
#     mode_q=pe_mode_sel)，case 0=FSA(WS)、case 1=GEMV/OS，两模式时间互斥。
#     STA无法自行知道模式互斥，只有set_case_analysis能把这信息喂给它。
#     历史bug: 此处只施加 set_case_analysis 0(注释误标"GEMV mode"，实为FSA)，
#     导致GEMV/OS模式(mode_q=1)专属通路全程从未被STA分析、也从未被phys_opt修
#     hold。2026-07-01用routed.dcp翻case_analysis复查证实OS口径有3条hold违例
#     (worst -0.061ns，集中在partial_sum_in→PE reg的OS载入通路)，正是"同
#     bitstream每次上电结果随机"的根因(hold违例对PVT敏感、降频救不了)。
#     修法不是删case_analysis(那会让mode_q变自由变量、跨模式假路径全回来)，
#     也不是手写false_path(误判真路径为假会重演本盲区)，而是"两个模式各闭合
#     一遍"——每遍STA只看一个模式的真实路径，跨模式假路径在任一遍里都不存在:
#       主P&R在case0(FSA，更难的模式)下闭合setup+hold; OS的setup在这份布线上
#       顺带即+0.507(已复查); 再追加一遍case1(OS)的post-route phys_opt专修OS
#       hold(只加延迟、对FSA无害); 结尾对两模式各报一次setup+hold确认都干净。
#   - set_clock_uncertainty 0.5ns: P&R期间加紧目标，报告前移除显示真实WNS
#   - set_multicycle_path 2 on CSR: 静态配置路径允许2周期
#   - set_clock_groups -asynchronous: cpu_clk vs sys_clk（RTL中有Axi_CDC处理）
#
# 注意:
#   - PE_retimed的flow_to_d_*_q寄存器加了DONT_TOUCH防止retiming移动
#   - 不在XDC中放set_case_analysis（会导致综合删FSA逻辑）
#   - 不再使用pblock_cmp（曾在WNS仍为负值的早期阶段加入，当时只换来0.02ns
#     改善；现在设计资源占用已大不相同，对照实验显示去掉它WNS反而更好）
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

# src_files 必须保持 filelist 的原始顺序去重——SystemVerilog package（如 fpnew_pkg）
# 必须在引用它的模块之前 read_verilog，lsort 字母排序会把 fpnew_pkg.sv 排到
# fpnew_cast_multi.sv 之后，导致 Vivado 2023.1 严格单趟编译时报 'fpnew_pkg is not
# declared'（2024.2 多趟 elaboration 能容忍乱序，故此前在 eda 上未暴露）。故这里只
# 保序去重，不排序。inc_dirs/defines 与顺序无关，保留 lsort 无害。
set seen [dict create]
set ordered {}
foreach f $src_files {
  if {![dict exists $seen $f]} {
    dict set seen $f 1
    lappend ordered $f
  }
}
set src_files $ordered
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

# 综合（SIMULATION默认值本来就是1'b0，不需要显式指定；不加fanout_limit/
# flatten_hierarchy——对照GUI项目实测两者都不加WNS更好）
synth_design -top $top_name -part $part_name \
  -directive AreaOptimized_medium -retiming

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

# 主P&R在case0(FSA/WS，更难更密的模式)下闭合：opt不删逻辑，place/route/phys_opt
# 全程针对FSA真实路径优化setup+hold。OS模式的hold在下面追加的case1 pass里单独修
# （见文件头"关键约束"的双模式闭合说明）。
set mode_pins [get_pins -quiet -hier -filter {NAME =~ */mode_q_reg/Q}]
if {[llength $mode_pins] > 0} {
  set_case_analysis 0 $mode_pins
  puts "INFO: set_case_analysis 0 (FSA/WS mode) on [llength $mode_pins] mode_q pins for main P&R"
} else {
  puts "WARNING: mode_q pins not found for case_analysis"
}

# 增加setup时钟不确定度，为PVT波动预留余量（500ps，同时逼迫P&R更激进优化）
set_clock_uncertainty -setup 0.5 [get_clocks sys_clk]
puts "INFO: set_clock_uncertainty -setup 0.5ns on sys_clk (PVT margin)"

# 增加hold时钟不确定度，逼迫P&R给Hold临界路径多留余量（80ps）。
# 根因: GUI工程report_timing_summary实测查到WHS仅0.015ns，最薄弱的10条路径里
# 9条集中在u_cb_top_v2/mac_top_inst/u_pe_core（DELAY_MATCH移位寄存器链+
# ws_c_pipe0/1/2纯打拍链，Logic Levels=0，余量完全靠布局布线物理距离撑住），
# 跟"printf bug修复后字符仍随机性出错"的现象吻合。
# 参数取值经实测权衡：hold=0.15时WHS提到0.049ns但把cpu_clk的WNS从+0.527挤到
# +0.283ns（瓶颈是DTLB实时查询链，38级组合逻辑）；hold=0回到+0.527但WHS只剩
# 0.015ns。取0.08这个折中值，目标是让setup/hold两边都拿到健康正余量。
# 跟setup uncertainty同样的套路：P&R期间加紧迫使工具给这些路径多塞延迟/换更优
# 布局，报告前移除显示真实裕量（不是报告造假，是让工具"以为"要求更严从而做得
# 更好，最终报告的是这个更优结果的真实值）。
set_clock_uncertainty -hold 0.08 [get_clocks sys_clk]
puts "INFO: set_clock_uncertainty -hold 0.08ns on sys_clk (Hold margin, balanced with setup)"

# 布局策略可从命令行覆盖：vivado ... -tclargs 或 -mode batch 前 set env(PLACE_DIRECTIVE)。
# 用途是做"同一份 RTL、不同布局"的对照实验：板上有个只在特定条件下发作的错误，
# 换布局后若消失 → 是某条具体的临界路径（可以两版网表对比着找）；
# 换布局后照旧 → 与具体路径无关，是系统性的（供电/平台），在设计里找不到。
if {[info exists ::env(PLACE_DIRECTIVE)]} {
    set place_dir $::env(PLACE_DIRECTIVE)
} else {
    set place_dir "Explore"
}
puts "INFO: place_design -directive $place_dir"
place_design -directive $place_dir
phys_opt_design -directive AggressiveFanoutOpt
phys_opt_design -directive AggressiveExplore
route_design -directive AggressiveExplore
# post-route优化（三轮，对齐GUI项目实测顺序）——此时case0=FSA，闭合FSA setup+hold
phys_opt_design -directive AggressiveExplore
phys_opt_design -directive Explore
phys_opt_design -directive AddRetime

# =============================================================================
# OS模式(case1)专属hold闭合
# =============================================================================
# 切到GEMV/OS模式：mode_q由0覆盖为1（同session内覆盖有效，已用check_os_mode_timing.tcl
# 验证：翻case后WHS从+0.018变-0.061）。此时STA只看OS模式真实路径，跨模式假路径不存在。
# 上面FSA闭合完成的布线里，OS的setup顺带即+0.5、只有hold欠余量(3条-0.061)，用post-route
# phys_opt给这些OS短路径加延迟修复；hold修复只加延迟、不动setup，对FSA闭合无害（结尾会
# 回case0复核确认FSA未退化）。hold uncertainty(0.08)仍在，逼工具给OS hold多留余量。
if {[llength $mode_pins] > 0} {
  set_case_analysis 1 $mode_pins
  puts "INFO: set_case_analysis 1 (GEMV/OS mode) on [llength $mode_pins] mode_q pins for OS hold closure"
  set os_whs_before [get_property SLACK [get_timing_paths -max_paths 1 -delay_type min]]
  puts "INFO: OS-mode WHS before hold-fix pass = $os_whs_before"
  phys_opt_design -directive AggressiveExplore
  phys_opt_design -directive Explore
  set os_whs_after [get_property SLACK [get_timing_paths -max_paths 1 -delay_type min]]
  puts "INFO: OS-mode WHS after hold-fix pass  = $os_whs_after"
}

# 移除uncertainty查看真实WNS/WHS
set_clock_uncertainty -setup 0 [get_clocks sys_clk]
set_clock_uncertainty -hold 0 [get_clocks sys_clk]

# 实现后报告——两个模式各报一次setup+hold。
# 注意: -delay_type max 只报Setup, -delay_type min 才报Hold。历史盲区正是只报了
# 一个模式(FSA)的setup、既漏了另一个模式(OS)、又长期没单独报hold。这里两个模式
# 的setup/hold全报，任一模式任一项违例都能在报告里看到。
#
# --- OS模式(case1，当前生效) ---
report_timing_summary -delay_type max -max_paths 20 -file [file join $out_dir timing_summary_os_setup.rpt]
report_timing_summary -delay_type min -max_paths 20 -file [file join $out_dir timing_summary_os_hold.rpt]
set os_wns [get_property SLACK [get_timing_paths -max_paths 1 -delay_type max]]
set os_whs [get_property SLACK [get_timing_paths -max_paths 1 -delay_type min]]

# --- FSA模式(case0，切回复核未退化) ---
if {[llength $mode_pins] > 0} {
  set_case_analysis 0 $mode_pins
  puts "INFO: switched back to set_case_analysis 0 (FSA/WS) for final FSA report"
}
report_timing_summary -delay_type max -max_paths 20 -file [file join $out_dir timing_summary_fsa_setup.rpt]
report_timing_summary -delay_type min -max_paths 20 -file [file join $out_dir timing_summary_fsa_hold.rpt]
set fsa_wns [get_property SLACK [get_timing_paths -max_paths 1 -delay_type max]]
set fsa_whs [get_property SLACK [get_timing_paths -max_paths 1 -delay_type min]]

report_utilization -file [file join $out_dir utilization_routed.rpt]
report_route_status -file [file join $out_dir route_status.rpt]
report_design_analysis -congestion -file [file join $out_dir congestion.rpt]
write_checkpoint -force [file join $out_dir ${top_name}_routed.dcp]

puts "INFO: ============================================"
puts "INFO: FSA mode (case0)  WNS=$fsa_wns  WHS=$fsa_whs"
puts "INFO: OS  mode (case1)  WNS=$os_wns  WHS=$os_whs"
puts "INFO: ============================================"

# =============================================================================
# 生成Bitstream
# =============================================================================
puts "INFO: Generating bitstream..."
write_bitstream -force [file join $out_dir ${top_name}.bit]

puts "INFO: ============================================"
puts "INFO: Bitstream generated: [file join $out_dir ${top_name}.bit]"
puts "INFO: Post-synth WNS      = $synth_wns"
puts "INFO: FSA mode WNS/WHS    = $fsa_wns / $fsa_whs"
puts "INFO: OS  mode WNS/WHS    = $os_wns / $os_whs"
puts "INFO: ============================================"

# 退出码必须由这里显式决定。脚本跑完自然结束时 Vivado 返回 1，与成败无关——
# 调用方若据此判断，一次成功的 bitgen 会被当成失败。判据取实打实的三样：
# 比特流文件已产出、两个模式的 setup 与 hold 裕量均为正。
set bit_file [file join $out_dir ${top_name}.bit]
set ok 1
if {![file exists $bit_file]} { puts "ERROR: bitstream not found: $bit_file"; set ok 0 }
foreach {nm val} [list fsa_wns $fsa_wns fsa_whs $fsa_whs os_wns $os_wns os_whs $os_whs] {
    if {$val <= 0} { puts "ERROR: timing violated: $nm = $val"; set ok 0 }
}
if {$ok} { puts "INFO: BITGEN_OK"; exit 0 } else { puts "ERROR: BITGEN_FAILED"; exit 1 }

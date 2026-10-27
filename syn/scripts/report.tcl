#==============================================================================
# report.tcl —— 综合后报告与结果导出
#==============================================================================

#----------------------------- 报告 -------------------------------------------
redirect rpt/qor.rpt        { report_qor }
redirect rpt/check_post.rpt { check_design }

# 只列与签核相关的违例（时序、transition、电容、扇出）
redirect rpt/constraint.rpt {
    report_constraint -all_violators -nosplit \
        -max_delay -max_transition -max_capacitance -max_fanout
}

# 最差路径：每个路径组 10 条，带 transition / 电容便于分析
# 路径组：clk（reg2reg）、in2reg、reg2out、in2out，见 constraints.tcl
set PATH_GROUPS [lsearch -all -inline -not [get_object_name [get_path_groups *]] {\*\*default\*\*}]
file delete -force rpt/timing.rpt
foreach g $PATH_GROUPS {
    redirect -append rpt/timing.rpt {
        report_timing -delay_type max -max_paths 10 -group $g \
                      -transition_time -capacitance -input_pins -nosplit
    }
}

redirect rpt/area.rpt       { report_area -nosplit }
redirect rpt/area_hier.rpt  { report_area -hierarchy -nosplit }
redirect rpt/reference.rpt  { report_reference -nosplit }
# 未加载开关活动文件，功耗按工具默认翻转率估算，仅作量级参考
redirect rpt/power.rpt      { report_power -hierarchy -levels 2 -nosplit }

#----------------------------- 汇总 -------------------------------------------
# 最差 slack 取各路径组最差路径的最小值；TNS 为所有负 slack 端点之和
set wns ""
foreach g $PATH_GROUPS {
    set p [get_timing_paths -delay_type max -group $g -max_paths 1]
    if {[sizeof_collection $p] == 0} { continue }
    set s [get_attribute $p slack]
    if {$wns eq "" || $s < $wns} { set wns $s }
}
set tns 0.0
foreach_in_collection p [get_timing_paths -delay_type max -max_paths 100000 -slack_lesser_than 0] {
    set tns [expr {$tns + [get_attribute $p slack]}]
}
# 无线负载模型时 DC 不给出总面积，取 report_area 的 Total cell area
regexp {Total cell area:\s+([0-9.]+)} [exec cat rpt/area.rpt] -> area
set cells [sizeof_collection [get_cells -hierarchical -filter "is_hierarchical == false"]]
set regs  [sizeof_collection [all_registers]]

set fh [open rpt/summary.rpt w]
puts $fh [format "%-12s %s"        "Design"     $TOP]
puts $fh [format "%-12s %s"        "Parameters" $ELAB_PARAMS]
puts $fh [format "%-12s %s"        "Library"    $LIB_NAME]
puts $fh [format "%-12s %.3f ns (%.1f MHz)" "Clock" $CLK_PERIOD [expr {1000.0 / $CLK_PERIOD}]]
puts $fh [format "%-12s %.3f ns"   "WNS"        $wns]
puts $fh [format "%-12s %.3f ns"   "TNS"        $tns]
puts $fh [format "%-12s %.1f um^2" "Cell area"  $area]
puts $fh [format "%-12s %d"        "Cells"      $cells]
puts $fh [format "%-12s %d"        "Registers"  $regs]
puts $fh [format "%-12s %s"        "Status"     [expr {$wns < 0 ? "TIMING VIOLATED" : "TIMING MET"}]]
close $fh
puts [exec cat rpt/summary.rpt]

#----------------------------- 导出 -------------------------------------------
# 网表命名规整为 Verilog 合法标识符；三态网络以 wire 输出
set_app_var verilogout_no_tri true
change_names -rules verilog -hierarchy

write_file -format verilog -hierarchy -output out/${TOP}.v
write_file -format ddc     -hierarchy -output out/${TOP}.ddc
write_sdc  out/${TOP}.sdc
# SDF 仅门级时序仿真需要，文件较大（256 位约 170 MB），按需开启
if {$WRITE_SDF} {
    write_sdf out/${TOP}.sdf
}

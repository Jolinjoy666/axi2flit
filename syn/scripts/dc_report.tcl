#==============================================================================
# dc_report.tcl —— 只重出报告：读入已综合的 out/<TOP>.ddc，不重新综合
#
# 由 syn/Makefile 的 report 目标在 syn/run/<配置名>/ 下调用，变量同 dc_run.tcl。
# 用于报告脚本更新后刷新旧结果；约束沿用 ddc 中保存的那一版。
#==============================================================================

file mkdir rpt out

source -echo $SYN_DIR/scripts/setup.tcl

if {![file exists out/${TOP}.ddc]} {
    puts "\nERROR: 找不到 out/${TOP}.ddc，请先运行 make syn"
    exit 1
}
read_ddc out/${TOP}.ddc
current_design $TOP
link

# summary.rpt 中记录的参数，与 read_rtl.tcl 的写法一致
set ELAB_PARAMS "DATA_WIDTH=$DATA_WIDTH,RP_COUNT=$RP_COUNT"
if {$EXTRA_PARAMS ne ""} {
    append ELAB_PARAMS ",$EXTRA_PARAMS"
}

source -echo $SYN_DIR/scripts/report.tcl
exit

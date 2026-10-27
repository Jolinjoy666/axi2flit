#==============================================================================
# dc_run.tcl —— Design Compiler 综合主流程
#
# 由 syn/Makefile 在运行目录 syn/run/<配置名>/ 下调用，下列变量经 dc_shell -x 传入：
#   SYN_DIR PROJ_DIR TOP DATA_WIDTH RP_COUNT EXTRA_PARAMS CLK_PERIOD IO_RATIO CORES GATE_CLOCK WRITE_SDF
#
# 流程：setup → read_rtl → constraints → compile_ultra → report/导出
# 产物：log/ 日志   rpt/ 报告   out/ 网表、ddc、sdc、svf（可选 sdf）
#==============================================================================

file mkdir rpt out

# 关键步骤失败时立即退出（返回非零，make 随之报错），避免带着错误继续跑出无效报告
proc abort_on_fail {ok step} {
    if {!$ok} {
        puts "\nERROR: $step 失败，综合中止。详见 log/dc.log"
        exit 1
    }
}

#----------------------------- 约束参数默认值 ---------------------------------
set CLK_UNCERTAINTY 0.10  ;# ns，setup 余量
set CLK_TRANSITION  0.05  ;# ns，理想时钟的边沿
set MAX_TRANSITION  0.20  ;# ns
set MAX_FANOUT      32

#----------------------------- 1. 环境 ----------------------------------------
puts "\n========== \[1/5\] Setup library =========="
source -echo $SYN_DIR/scripts/setup.tcl

# 记录综合过程中的结构变换，供 Formality 做 RTL 与网表的等价性检查
set_svf out/${TOP}.svf

#----------------------------- 2. 读入设计 ------------------------------------
puts "\n========== \[2/5\] Read & elaborate RTL =========="
source -echo $SYN_DIR/scripts/read_rtl.tcl
redirect rpt/check_pre.rpt { check_design }

#----------------------------- 3. 约束 ----------------------------------------
puts "\n========== \[3/5\] Apply constraints =========="
source -echo $SYN_DIR/scripts/constraints.tcl
redirect rpt/check_timing.rpt { check_timing }

#----------------------------- 4. 综合 ----------------------------------------
puts "\n========== \[4/5\] compile_ultra =========="
# -no_autoungroup：保留模块层次，面积/功耗可按子模块查看
set COMPILE_OPTS "-no_autoungroup"
if {$GATE_CLOCK} {
    # 插入时钟门控（库中 CLKLAN* 等 ICG 单元），降低寄存器翻转功耗
    append COMPILE_OPTS " -gate_clock"
}
puts "INFO: compile_ultra $COMPILE_OPTS"
abort_on_fail [eval compile_ultra $COMPILE_OPTS] compile_ultra

#----------------------------- 5. 报告与导出 ----------------------------------
puts "\n========== \[5/5\] Report & write outputs =========="
source -echo $SYN_DIR/scripts/report.tcl

set_svf -off
exit

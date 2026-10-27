#==============================================================================
# read_rtl.tcl —— 读入 RTL、按参数 elaborate 顶层
#
#   DC 预定义宏 SYNTHESIS，RTL 中 `ifndef SYNTHESIS 包住的仿真检查不会被综合。
#==============================================================================

#----------------------------- 文件表 -----------------------------------------
# 顺序与 rtl/README.md 一致：package 必须最先分析
set RTL_DIR "$PROJ_DIR/rtl"
set RTL_FILES [list \
    $RTL_DIR/aou_pkg.sv         \
    $RTL_DIR/aou_sync_fifo.sv   \
    $RTL_DIR/aou_chunk_fifo.sv  \
    $RTL_DIR/aou_flit_tx.sv     \
    $RTL_DIR/aou_flit_rx.sv     \
    $RTL_DIR/aou_transport.sv   \
    $RTL_DIR/aou_target_core.sv \
    $RTL_DIR/axi2flit_soc.sv    \
    $RTL_DIR/flit2hif_target.sv \
]

#----------------------------- 分析与展开 -------------------------------------
abort_on_fail [analyze -format sverilog $RTL_FILES] analyze

# 顶层参数：数据位宽、RP 数，外加 Makefile 透传的 PARAMS（逗号分隔的 NAME=VALUE）
set ELAB_PARAMS "DATA_WIDTH=$DATA_WIDTH,RP_COUNT=$RP_COUNT"
if {$EXTRA_PARAMS ne ""} {
    append ELAB_PARAMS ",$EXTRA_PARAMS"
}
puts "INFO: elaborate $TOP -parameters \"$ELAB_PARAMS\""
abort_on_fail [elaborate $TOP -parameters $ELAB_PARAMS] elaborate

# elaborate 后的设计名带参数后缀，改回顶层名，使网表/报告命名统一
rename_design [current_design] $TOP
current_design $TOP

abort_on_fail [link] link
uniquify

# 避免网表出现 assign：多端口共用一根线、端口直连、常量输出均插 buffer
set_fix_multiple_port_nets -all -buffer_constants

# 保存未映射的设计，出问题时可直接 read_ddc 复现
write_file -format ddc -hierarchy -output out/${TOP}_elab.ddc

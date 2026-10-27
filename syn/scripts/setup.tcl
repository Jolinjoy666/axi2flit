#==============================================================================
# setup.tcl —— 工艺库与工具环境
#
#   link_library   : 解析设计中引用的所有单元（"*" 表示内存中已有的设计）
#   target_library : 映射时可选用的标准单元
#   synthetic_library : DesignWare 库，提供 +、-、*、比较器等算子的实现
#==============================================================================

#----------------------------- 工艺库 -----------------------------------------
# SMIC 28nm SCC28NHKCP 高密度 RVT 标准单元，FF 工艺角 / 0.88 V / 0 ℃
# 注：该库不含线负载模型（wire_load），DC 按零线负载估算，结果偏乐观，
#     仅用于评估逻辑深度与面积，最终时序以后端为准。
set LIB_NAME   "scc28nhkcp_hdc30p140_rvt_ff_v0p88_0c_basic"
set DB_LIB_DIR "/mnt/d/PDK/SCC28NHKCP_HDC30P140_RVT_V0p2/liberty/0.8v"
set DW_LIB_DIR "/home/cfy/eda/synopsys2025/syn/X-2025.06-SP4/libraries/syn"

set_app_var search_path       "$search_path $DB_LIB_DIR $DW_LIB_DIR"
set_app_var target_library    "${LIB_NAME}.db"
set_app_var synthetic_library "dw_foundation.sldb"
set_app_var link_library      "* $target_library $synthetic_library"

# 约束中引用的库单元（输入驱动 / 输出负载）
set DRIVE_CELL "BUFV4_140P7T30R"
set DRIVE_PIN  "Z"
set LOAD_CELL  "BUFV4_140P7T30R"
set LOAD_PIN   "I"

#----------------------------- 工具设置 ---------------------------------------
set_host_options -max_cores $CORES

# 中间库放在本次运行目录，避免不同配置互相覆盖
define_design_lib WORK -path ./work

# 综合时检查异步复位的 recovery/removal
set_app_var enable_recovery_removal_arcs true

# 网表中保留未连接引脚，便于后端/形式验证核对
set_app_var verilogout_show_unconnected_pins true

# 屏蔽已确认无害、但数量巨大的提示：
#   VER-318  有符号/无符号转换（RTL 中 int 与 logic 混算，已显式转换）
#   UID-401  set_driving_cell 时把驱动单元的 DRC 属性带到端口（每个输入端口一条）
suppress_message {VER-318 UID-401}

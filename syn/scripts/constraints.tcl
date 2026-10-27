#==============================================================================
# constraints.tcl —— 时序与设计规则约束
#
#   两个顶层都是单时钟 clk + 低有效异步复位 rst_n，约束相同。
#   端口时序按"外部逻辑占用时钟周期的固定比例"估算（IO_RATIO）。
#==============================================================================

set CLK_PORT [get_ports clk]
set RST_PORT [get_ports rst_n]

#----------------------------- 时钟 -------------------------------------------
create_clock -name clk -period $CLK_PERIOD $CLK_PORT

# 时钟树由后端综合，DC 中视为理想网络
set_ideal_network        $CLK_PORT
set_dont_touch_network   [get_clocks clk]

# uncertainty = skew + jitter + 余量；DC 阶段 hold 不做修复，仅随 SDC 一起导出
set_clock_uncertainty -setup $CLK_UNCERTAINTY [get_clocks clk]
set_clock_uncertainty -hold  0.05             [get_clocks clk]
set_clock_transition         $CLK_TRANSITION  [get_clocks clk]

#----------------------------- 复位 -------------------------------------------
# 异步复位：释放沿的同步由 SoC 复位控制器保证，复位网络交给后端插 buffer
set_ideal_network   $RST_PORT
set_false_path -from $RST_PORT

#----------------------------- 输入输出 ---------------------------------------
set DATA_INPUTS [remove_from_collection [all_inputs] [list $CLK_PORT $RST_PORT]]
set IO_DELAY    [expr {$CLK_PERIOD * $IO_RATIO}]

# 不区分 -max/-min，同时作为 setup 与 hold 分析的端口延迟
set_input_delay  $IO_DELAY -clock clk $DATA_INPUTS
set_output_delay $IO_DELAY -clock clk [all_outputs]

# 输入由一个中等驱动的 buffer 驱动，输出接 4 个同类 buffer 的输入负载
set_driving_cell -library $LIB_NAME -lib_cell $DRIVE_CELL -pin $DRIVE_PIN $DATA_INPUTS
set_load [expr {4 * [load_of $LIB_NAME/$LOAD_CELL/$LOAD_PIN]}] [all_outputs]

#----------------------------- 设计规则 ---------------------------------------
set_max_transition $MAX_TRANSITION [current_design]
set_max_fanout     $MAX_FANOUT     [current_design]

#----------------------------- 路径分组 ---------------------------------------
# 分组后各类路径单独优化、单独报告，便于判断瓶颈在内部还是在端口。
# 只按端口划分（寄存器在优化中会被删除/合并，不宜作为分组锚点）；
# 未归入下列三组的路径即 reg2reg，留在时钟默认组 clk 中。
group_path -name in2reg  -from $DATA_INPUTS
group_path -name reg2out -to   [all_outputs]
group_path -name in2out  -from $DATA_INPUTS -to [all_outputs]

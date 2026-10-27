# 逻辑综合（Design Compiler）

对 `rtl/` 下的两个交付顶层做 DC 综合，评估面积与 500 MHz 时序。

- 工具：Synopsys Design Compiler X-2025.06-SP4（`dc_shell`）
- 工艺：SMIC 28nm `scc28nhkcp_hdc30p140_rvt`，FF / 0.88 V / 0 ℃（`basic` NLDM 库）
- 顶层：`axi2flit_soc`（SoC 侧）、`flit2hif_target`（存储侧），均为单时钟 `clk` + 低有效异步复位 `rst_n`

## 用法

```bash
cd syn
make                                    # axi2flit_soc，DATA_WIDTH=256，RP=1，2.0 ns
make TOP=flit2hif_target                # 存储侧顶层
make all                                # 依次综合两个顶层
make WIDTH=256 RP=2 PERIOD=1.6          # 其他位宽 / RP 数 / 周期
make PARAMS="TX_DEPTH=4" TAG=soc_tx4    # 透传其他顶层参数，自定 TAG 避免覆盖
make report                             # 不重新综合，用已有 ddc 重出报告
make summary                            # 打印所有配置的汇总
make clean                              # 删除 run/
```

| 变量 | 默认 | 含义 |
|---|---|---|
| `TOP` | `axi2flit_soc` | 顶层模块 |
| `WIDTH` | `256` | `DATA_WIDTH`（256/512/1024） |
| `RP` | `1` | `RP_COUNT`（1～4） |
| `PARAMS` | 空 | 其他顶层参数，逗号分隔 `NAME=VALUE` |
| `PERIOD` | `2.0` | 时钟周期 ns |
| `IO_RATIO` | `0.3` | 端口输入/输出外部延迟占周期的比例 |
| `GATE_CLOCK` | `0` | 置 1 时 `compile_ultra -gate_clock` |
| `WRITE_SDF` | `0` | 置 1 时额外导出 SDF（门级时序仿真用，256 位约 170 MB） |
| `CORES` | `8` | DC 多核数 |
| `TAG` | `<TOP>_w<WIDTH>_rp<RP>_p<PERIOD>` | 运行目录名 |

## 目录

```
syn/
├── Makefile              入口：参数 → dc_shell -x 变量
├── scripts/
│   ├── dc_run.tcl        主流程：setup → read_rtl → constraints → compile_ultra → report
│   ├── dc_report.tcl     只重出报告：read_ddc → report
│   ├── setup.tcl         工艺库、DesignWare、工具选项
│   ├── read_rtl.tcl      RTL 文件表、analyze / elaborate（带参数）/ link
│   ├── constraints.tcl   时钟、复位、IO 延迟、驱动/负载、DRC、路径分组
│   └── report.tcl        报告、summary、网表/ddc/sdc/sdf 导出
└── run/<TAG>/            每个配置一个目录（不入库）
    ├── log/dc.log        完整日志
    ├── rpt/              见下表
    └── out/              <TOP>.v / .ddc / .sdc / .svf（可选 .sdf），<TOP>_elab.ddc（未映射）
```

| 报告 | 内容 |
|---|---|
| `summary.rpt` | WNS / TNS / 面积 / 单元数 / 寄存器数，先看这个 |
| `qor.rpt` | 各路径组时序、面积、DRC 概览 |
| `timing.rpt` | 每个路径组最差 10 条路径（`clk` 组即 reg2reg） |
| `constraint.rpt` | 所有违例（时序与 DRC） |
| `area.rpt` / `area_hier.rpt` | 总面积 / 按模块层次面积 |
| `power.rpt` | 默认翻转率下的功耗估算（仅量级参考） |
| `reference.rpt` | 顶层引用单元统计 |
| `check_pre.rpt` / `check_post.rpt` / `check_timing.rpt` | 综合前后设计检查、约束完整性检查 |

## 约束说明

- 时钟 `clk`：周期 `PERIOD`，setup uncertainty 0.10 ns，理想网络（时钟树留给后端）。
- 复位 `rst_n`：理想网络 + false path，释放沿同步由 SoC 复位控制器保证。
- 端口：输入/输出外部延迟均为 `IO_RATIO × PERIOD`；输入由 `BUFV4` 驱动，输出负载为 4 个 `BUFV4` 输入电容。
- DRC：max_transition 0.20 ns，max_fanout 32。
- 路径分组：`in2reg / reg2out / in2out` 按端口划分，其余（reg2reg）留在时钟组 `clk`，分别优化与报告。
- 综合保留模块层次（`-no_autoungroup`），便于按模块看面积。

上述数值集中在 `scripts/dc_run.tcl` 开头与 `Makefile`，按项目实际 IO 预算调整。

## 注意

- 运行时间：`axi2flit_soc` 256 位约 40 分钟（8 核）；位宽越大越久。日志看 `run/<TAG>/log/dc.log`。
- 关键步骤（analyze / elaborate / link / compile_ultra）失败时脚本以非零状态退出。

- 该工艺库没有线负载模型，DC 按零线负载计算，时序偏乐观；FF 角也是快角。结果用于评估逻辑深度和面积，
  不能作为时序签核，签核应在 SS 角并带物理信息（DC-Topo/ICC2）完成。
- 所有 FIFO / 缓冲均综合为寄存器阵列，大位宽、深缓冲配置下面积以存储为主；后续可替换为 SRAM 宏。
- DC 预定义宏 `SYNTHESIS`，RTL 中 `` `ifndef SYNTHESIS `` 的仿真检查不参与综合。
- HDL Compiler 不支持对函数返回值直接取结构体成员（如 `f(x).field`），RTL 中需先赋给中间变量。

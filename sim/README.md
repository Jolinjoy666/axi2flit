# RTL 仿真入口

在仓库根目录运行 `make -C sim check`，或在本目录运行 `make check`。

- `run WIDTH=256 RP=1`：端到端功能、空载时延和联合复位。
- `negative`：非法 AXI/Flit/MC 响应和 credit 越界检测。
- `fifo-all`：FIFO 深度 1/3/8 × FWFT 关/开的边界测试；单项可运行 `make fifo DEPTH=3 FWFT=1`。
- `test-all`：三位宽 × RP1/2/4 的 lint、正常与异常回归。
- `perf-all`：三位宽 RP1 的读/写完成吞吐，不用 SystemC 性能结果替代。
- `checker-negative`：破坏期望读数据，要求记分板明确检出。
- `run ARGS=--trace`：保存 VCD 波形。
- `codec-all`：独立 TX/RX 逐字节及每周期一条消息的吞吐门限，含跨帧、背压、深度 2/3 和半消息复位。
- `scenario WIDTH=1024 SCENARIO=saturated ARGS='--min-efficiency 0.90'`：满载及 90% 门限。
- `SCENARIO=ideal`：移除链路限速，测 RTL 周期能力；`baseline` 保留原激励；`physical` 需指定岸线/密度；`backpressure` 加入压力。
- `run ARGS=--help`：列出运行参数；完整示例及 credit 公式见 [吞吐与配置说明](../doc/RTL吞吐优化与场景配置.md)。

源码在 `tb/`，构建在 `build/`，日志/波形在 `results/`；后两者不提交 Git。依赖 Verilator、C++17 编译器、make、SystemC；SystemC 只供 C++ 测试使用，RTL 自身不依赖它。默认库位置可由 `SYSTEMC_HOME` 覆盖。

[验证说明](../doc/RTL协议桥验证说明.md)给出详细判据和实测结果；[设计说明](../doc/RTL协议桥设计与接口说明.md)定义 AXI、Flit、MC 三个边界。当前 TB 的 FIFO 链路和 MC 字节内存均为验证后端，不是实际 UCIe/MC/DFI 实现。

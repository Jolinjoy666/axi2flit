# RTL 协议桥验证说明

日期：2026-09-29。对象为 `rtl/axi2flit_soc.sv`、`rtl/flit2mc_target.sv` 及公共模块，接口契约见 [RTL 设计说明](RTL协议桥设计与接口说明.md)。本文结果来自时钟驱动 RTL 仿真，不是原有 SystemC 性能报告。

## 1. 环境与复现

本次使用 Verilator 5.052、C++17、SystemC 2.3.4。Verilator 负责执行 RTL；SystemC 库仅支持 TB 调用已有纯消息编解码函数，不用行为桥代替 DUT。

在仓库根目录执行：

```bash
make -C sim lint WIDTH=256 RP=1
make -C sim run WIDTH=256 RP=1
make -C sim negative WIDTH=256 RP=1
make -C sim run WIDTH=256 RP=1 ARGS=--trace

make -C sim fifo-all          # 深度 1/3/8 × FWFT 关/开的公共 FIFO 单元测试
make -C sim codec-all         # 双帧解析/组帧每拍一条消息、背压与跨帧边界
make -C sim test-all          # 三位宽 × RP1/2/4：双顶层 lint、功能/复位、异常检测
make -C sim perf-all          # 三位宽、RP1 的持续吞吐测试
make -C sim checker-negative  # 故意破坏期望数据，检查记分板会不会漏报
make -C sim check             # 上述完整回归入口
```

工具路径可覆盖，例如：

```bash
make -C sim VERILATOR=/opt/verilator/bin/verilator SYSTEMC_HOME=/opt/systemc run
```

`WIDTH` 支持 256/512/1024，`RP` 支持 1～4。源码、测试、Makefile 分别在 `rtl/`、`sim/tb/`、`sim/`；构建目录为 `sim/build/w<WIDTH>_rp<RP>/`，日志和波形在 `sim/results/`。这些再生产物已加入 `sim/.gitignore`，需要交付原始证据时另行归档，不能只提交日志链接。

Lint 使用 `--assert` 并保留一般诊断为错误；当前对宽整数循环/切片相关的 `WIDTHEXPAND/WIDTHTRUNC` 做了统一关闭。这不是已完成所有严格 lint 规则或全部位宽告警逐项签核。

## 2. 验证结构与判据

| 文件/检查层 | 做什么 | 如何判断错误 |
|---|---|---|
| [tb_rtl_bridge.sv](../sim/tb/tb_rtl_bridge.sv) | 连接两个 RTL 顶层、两个有限 Flit FIFO、故障注入入口 | 对 Flit、AXI R/B、MC 命令施加背压稳定性 SVA |
| [tb_rtl_bridge.cpp](../sim/tb/tb_rtl_bridge.cpp) 的 AXI 记分板 | 从 AW/W/AR 握手建立独立期望内存和响应队列 | 比较 ID、USER、RESP、LAST、所有数据字节；检查遗漏/重复 |
| 同文件的 MC 记分板 | 从 AXI 期望构建每拍命令，与 MC 接口逐次比较 | 检查地址、SIZE、LEN、beat、first/last、属性、数据、选通、WUSER 及 tag 唯一性 |
| 同文件的线上检查 | 用现有 `MsgBuilder` 生成期望，用 `AouStreamDecoder` 解析 RTL 实际 Flit | 比较整条消息字节与 granule 数；跨帧重组后仍须完全相同 |
| 同文件的独立 credit 账本 | 在实际发送握手观察对端授信，每个 MsgStart 扣整消息长度 | 不得出现负 credit；覆盖缺 credit 后恢复 |
| [tb_fifo.cpp](../sim/tb/tb_fifo.cpp) | 以软件队列验证实际 RTL FIFO | 两种 FWFT 模式下检查空队列直通、背压、数据顺序、level、满时同拍替换、回绕、复位 |

AXI 参考内存由主机握手更新，MC 模型的实际内存由 MC 命令更新，两份内存相互独立。结束时比较完整内存、检查所有事务和期望消息排空。MC 可提前返回后发命令，Target 必须缓存在 ROB 中，不能借此破坏 AXI 顺序。

链路 FIFO 深度可通过 LINK_DEPTH 配置，默认 64 帧，设为 2 可复现原基线。可选 physical 场景加入串行发送、传播/PHY/CDC 延迟及岸线检查，不包含实际 UCIe CRC、重放和物理训练。正常用例的全部功能检查保持启用；异常注入用例关闭正常记分板，要求指定端的 `protocol_error` 在有限周期内出现。

通过条件是命令退出码为 0，且具有对应 PASS 输出；`RTL PASS` 一行不能替代后续 `RESET PASS` 和整个进程的成功退出。C++ 错误产生非零退出码，Makefile 使用 `pipefail`，不会被 `tee` 隐藏。

### 2.1 事务守恒关系

排空后，正常支持范围内必须满足：

```text
N_AW = N_WREQ = N_B
N_AR = N_RREQ
N_MC_write = N_W = Σ(AWLEN+1)
N_MC_read  = N_R = Σ(ARLEN+1)
N_MC_response = N_MC_write + N_MC_read
```

每条 MC 命令返回一次完成，不是整笔写只返回一次。B 是 Target 收集该 burst 全部写完成后聚合生成。除了计数，还必须满足逐字节映射、顺序和掩码检查。

## 3. 本次覆盖与结果

完整入口：`make -C sim check`。

| 验证项 | 本次结果/覆盖 |
|---|---|
| FIFO 单元 | 深度 1、3、8 × FWFT 关/开均通过；覆盖空队列直通、背压、满时同拍出入、非 2 次幂回绕和非空复位 |
| 编解码单元 | 三位宽深度 2、1024 位深度 3；六类消息 × 无背压/有背压共 48 项，另有 4 组延后续帧/起点冲突/半消息复位检查 |
| 双顶层 lint | 256/512/1024 × RP1/2/4，9 组配置均通过上述规则 |
| RTL 闭环功能 | 9 组配置全部通过；每组包含下列正常/压力场景 |
| 联合复位 | 每组在读响应受阻且仍有事务在途时，联合清空两端/链路/MC 后重新授信，新的读写通过 |
| 异常检测 | 256/512 位每组 11 项，1024 位每组 10 项，共 96 个配置内异常用例通过 |
| 持续吞吐 | 三位宽、RP1 的读/写基线通过数据及排空检查；check 另以 1024 位 saturated 场景检查相对 45GB/s 基准的 90% 下限 |
| 记分板负向控制 | 故意翻转期望读数据一位，指定 `R data mismatch` 且退出码为 1；外层测试确认检出后通过 |

正常场景包括：单拍读写、写后读、2/4/16 拍及全宽 4KB 内最大突发；部分/全零 WSTRB；4B 窄访问、非零 lane、256 拍窄突发；错误地址、LOCK 拒绝、中间写拍失败但末拍成功时的 B 错误聚合；多 ID、多 RP、同 ID 多笔同 RP；同 ID 跨 RP 入口背压；读写同时在途；跨帧；MC 乱序完成；AXI、MC 和链路长时间停顿及恢复。

异常场景为：非 INCR、跨 4KB、未对齐、SIZE 超总线能力、WLAST 错位、坏 PH、非法 DLENGTH、重叠 MsgStart、未知 MC tag、无请求的 R 响应、重复授信导致 credit 数值越界。1024 位下三位 SIZE 的最大值就是合法的 128B，不运行“SIZE 超总线”项。测试计数是配置内用例数，不是 96 种不同功能。

日志路径：`results/rtl_<位宽>_rp<RP>.log`、`negative_<位宽>_rp<RP>.log`、`fifo_<深度>_fwft<0|1>.log`。正常日志的 `spanning`、`out_of_order_MC`、`stall_cycles` 必须非零，避免用未真正发生的压力场景宣称覆盖。

目前为定向场景和确定性组合停顿，尚非长时间多随机种子回归；RP3、非默认顶层队列/ROB 容量未纳入完整闭环矩阵。未知 tag 有覆盖，所有 tag 重复/回绕/同拍边界的穷举、严格 AXI VIP、形式验证、CDC/RDC、X 传播及综合后验证仍待补充。

## 4. 转换延迟：测量点和结果

时钟周期 2ns，初始化授信已结束、下游无外加停顿。每组用两个单拍读、一个单拍写测量，所有时间戳取真实接口握手，不使用首次拉高 valid 的时刻。

```text
L_SOC_TX_read  = t(RREQ 完整离开 SoC) - t(AR 接受)
L_SOC_TX_write = t(WDATA 最后片段离开 SoC) - t(WLAST 接受)
L_SOC_RX       = t(R/B 交付 AXI) - t(对应响应最后片段进入 SoC)
L_TARGET_req   = t(MC 命令接受) - t(所需 RREQ 或 WREQ/WDATA 完整进入 Target)
L_TARGET_ret   = t(对应 RDATA/WRESP 完整离开 Target) - t(MC 响应接受)
```

写请求所需到齐时刻取 WREQ 和相应 WDATA 的较晚者。跨帧响应按最后片段进入算完整消息可用，不能遗漏在前一帧已发生的等待；本节空载单拍样本未跨帧，压力跨帧不套用此门限。

| 位宽 | SoC TX 样本最大 | SoC RX 样本最大 | Target 请求最大 | Target 返回最大 |
|---:|---:|---:|---:|---:|
| 256 | 6ns | 6ns | 8ns | 8ns |
| 512 | 6ns | 6ns | 8ns | 8ns |
| 1024 | 6ns | 6ns | 8ns | 8ns |

RP1/2/4 的上述样本结果相同。自动门限检查 SoC 的 `max(TX)+max(RX)≤20ns`、Target 的 `max(req)+max(ret)≤20ns`，实测分别为 12ns、16ns。没有包含链路传输、MC 服务时间或外部无限背压，不代表所有负载最坏延迟。

若验收的 20ns 指 **两端往返转换总和**，四段样本保守合计为 28ns，不能用“每端各自小于 20ns”宣布总和通过。应先明确验收边界，再据此调整门限/流水；也不能以仿真时钟设为 2ns 证明 RTL 已经综合达到 500MHz。

## 5. 持续吞吐：1024 位已接近当前协议与链路预算上限

条件：RP1、16 拍全宽、全选通，两个方向分别按 48GB/s 物理速率预算限制，每帧计 256B；MC 两周期返回、可流水接受命令；纯读或纯写分别运行。此处 baseline 激励仍按 AW 后 W 发事务；默认预热至少 2000 周期、测量至少 20000 周期，按实际窗口长度计算。新增 saturated 场景独立推进 AW/W，详见 [吞吐与场景配置](RTL吞吐优化与场景配置.md)。

读按 R 握手有效字节计数，写按 B 成功返回关联的 16 拍数据计数，不以 W 接收字节冒充写完成字节。窗口结束后停止加压并排空，检查数据与事务；排空耗时不计入稳态窗口。

```text
B_raw     = 48 GB/s
B_payload = 48 × 240/256 = 45 GB/s
D         = 窗口内已完成的应用数据字节
B_app     = D / 实际窗口时长(ns)                单位 GB/s，等同 B/ns
η_time    = B_app / 45
消息区填充率 = 逐粒度统计的消息区占用 / (数据方向帧数 × 48)
```

| 位宽 | 读 GB/s | 写完成 GB/s | 读/写时间利用率 |
|---:|---:|---:|---:|
| 256 | 16.0000 | 15.0588 | 35.5556% / 33.4641% |
| 512 | 32.0000 | 30.1176 | 71.1111% / 66.9281% |
| 1024 | 42.6667 | 42.3745 | 94.8148% / 94.1656% |

1024 位原始记录：

| 方向 | 窗口 ns | 完成字节 | 数据方向帧数 | 消息区填充率 |
|---|---:|---:|---:|---:|
| 读 | 40032 | 1708032 | 7506 | 100% |
| 写 | 40018 | 1695744 | 7503 | 100% |

消息区填满包含消息头，不等于应用数据占满物理帧。窗口完成字节和窗口帧计数存在边界错位，实测可略高于理论稳态上限，报告不裁剪数值。再生成证据见 `sim/results/perf_<位宽>_rp1.log`。

256/512 位 AXI 在 2ns 时钟下本身只有 16/32GB/s 理论容量，不能达到 45GB/s 的 90%。1024 位在当前条件下已接近读 42.6667GB/s、写 42.3724GB/s 的协议上限；`--min-efficiency 0.90` 可对指定基准设置实际失败门限。

本次加入 RX 双帧拼接、编解码器独立周期检查、credit 容量预算、停顿计数、可配置 MC 延迟与物理链路场景。仍需在真实 UCIe/MC 路径下重新确定基准与性能，已有 SystemC 结果不替代 RTL 证据。

## 6. 能交付什么，不能据此宣布什么

已经形成可复现的 SoC AXI↔Flit RTL、Flit↔逐拍 MC RTL、接口文档与自检环境；消息字节和 MC 命令映射已有独立检查，背压稳定性已有时钟断言。

本测试的 45GB/s 基准下已超过 90%，尚不能据此宣布真实存储阵列的合同指标完成、实际 UCIe/MC/DFI 联调完成、完整 AXI/DFI 合规、500MHz 综合通过或工艺后仿通过。外部接口接入和性能/综合验收应使用明确的测量边界。

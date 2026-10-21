# RTL 吞吐优化与场景配置

日期：2026-09-29。范围为真实 RTL 编解码器、协议桥与可配置 C++ 验证后端。性能优先，未进行面积优化。2ns 为仿真时钟假设，尚无综合/布局布线时序证据。

## 1. 已实现的数据通路

```mermaid
flowchart LR
    I[250B Flit 输入] --> Q[双槽帧 FIFO]
    Q --> H[当前帧和下一帧视图]
    H --> M[起点搜索与跨帧拼接 MUX]
    M --> R[完整消息 REG]
    R --> D[RP/类型解码]
    D --> F[消息 FIFO]
    F --> A[AXI 响应或 MC 请求]
    I --> C[PH credit 单次入账]
```

帧 FIFO 默认两槽，最大消息 30 个粒度小于单帧 48 个粒度，因此完整消息最多涉及两帧。解析器可同时读前两帧，一拍拼接一条完整消息。最后一条消息消费当前帧后立即切换队首，无搬运/装载空拍；满 FIFO 支持同拍出入。前半帧单独到达时等待后半帧，不输出半条消息。

`aou_transport` 将 PH 授信与消息路由分为两个组合块，避免输入 ready 经授信计算回到输出 ready 的工具级组合环。授信、消息接收、消费者释放仍各记一次；额外帧缓存不扩大对端可用的消息 credit。

TX 原有在建帧、输出寄存器及 spill 接续已经支持每拍一条新消息。本次通过独立参考组帧实测确认该上限，未为提高吞吐修改线上协议。

## 2. 上限、周期与实测

单元测试对 WREQ/RREQ/WDATAFULL/RDATA/WRESP/掩码 WDATA 分别发送 96 条消息。256/512/1024 位下，无背压时 TX 首末消息接受区间为 96 周期，RX 首末消息交付区间同为 96 周期，包括跨帧；深度 3 也验证指针回绕。首帧到首消息的流水填充时间单独存在。

这证明的是稳态每拍一条消息，不能把它理解成所有 Flit 均只有一拍封装延迟：一个帧可以装多条消息，TX 需要等消息到达；RX 对一帧中的多条消息逐拍输出。空帧、部分帧尾部扫描、缺下一帧、缺 credit、下游背压仍可能停顿。

设每拍数据为 D 字节，突发长度 B，数据消息为 g 个 5B 粒度，物理单向预算为 L GB/s：

```text
读消息区总量 S_r = B × 5g
写消息区总量 S_w = 15 + B × 5g（全选通）
读链路上限 = L × 240/256 × (B×D/S_r)
写链路上限 = L × 240/256 × (B×D/S_w)
读编解码上限 = D / Tclk
写编解码上限 = D / Tclk × B/(B+1)
MC 上限 = D / (Tclk × mc_interval)
报告理论上限 = min(编解码上限, MC 上限, 已启用的链路上限)
```

最后一项是乐观上界，未扣小包/纯 credit 帧、反向控制流竞争及外加背压；小突发或高延迟场景可能达不到它。

1024 位、16 拍、Tclk=2ns、L=48GB/s：读协议上限 42.6667GB/s，写协议上限 42.3724GB/s。原单帧逐片段 RX 的读/写基线为 31.0303/29.9906GB/s。当前 2000 周期预热、约 20000 周期测量的 `baseline` 为 42.6667/42.3745GB/s；`saturated` 为 42.6688/42.3936GB/s。差异来自测量窗口内在途事务边界，未裁剪超过 100% 的数值。

不限速 `ideal` 场景读为 64.0000GB/s，写为 60.2112GB/s，分别对应 64 和 64×16/17=60.2353GB/s 上限。这是桥的测试能力，不代表物理 UCIe 达到该带宽。

当前默认基准 `--target-gbps 45`，1024 位读写均超过其 90%。合同中的“存储阵列利用率”必须用实际约定的存储带宽作分母；45GB/s 来自消息区容量，不能自动等同真实存储阵列。256/512 位在本时钟下只有 16/32GB/s 入口容量。

## 3. 可直接运行的场景

```bash
# 全部原有功能/异常/FIFO回归和独立编解码器测试
make -C sim check
make -C sim codec-all

# 满载：AW/W 独立推进，MC 每拍接收和返回；90% 门限不通过即报错
make -C sim scenario WIDTH=1024 SCENARIO=saturated ARGS='--min-efficiency 0.90'

# 去除链路限速，测 RTL 固有上限；仍执行有限 FIFO/credit/ROB 和全部数据检查
make -C sim scenario WIDTH=1024 SCENARIO=ideal

# 保留原 AW 后 W 的激励和两帧链路深度，复现同条件基线
make -C sim scenario WIDTH=1024 LINK_DEPTH=2 SCENARIO=baseline \
  ARGS='--warmup 1500 --cycles 4000'

# 长 MC 延迟，但每拍仍可收发；扩大在途容量以覆盖流水线
make -C sim scenario WIDTH=1024 MC_SLOTS=64 RX_DEPTH=64 WDATA_DEPTH=64 \
  SCENARIO=ideal ARGS='--mc-latency 32 --mc-interval 1 --target-gbps 64 --min-efficiency 0.90'

# 指定方向、突发长度与测量窗口
make -C sim scenario WIDTH=1024 SCENARIO=saturated \
  ARGS='--direction read --burst 4 --warmup 4000 --cycles 40000'

# 确定性 AXI/MC/链路背压和乱序返回
make -C sim scenario WIDTH=1024 SCENARIO=backpressure

# 物理假设示例：S x16，每 lane 原始 32Gb/s；岸线/密度仅为用户给定示例
make -C sim scenario WIDTH=1024 LINK_DEPTH=64 SCENARIO=physical \
  ARGS='--package S --lanes 16 --modules 1 --lane-gbps 32 --link-gbps 48 --shoreline-mm 1 --density-gbps-mm 64 --phy-ns 2 --prop-ns 0.2 --cdc-ns 2'

# 全部参数帮助
make -C sim run ARGS=--help
```

物理示例数值不是本项目已取得的封装证据。`--scenario functional/negative` 也可选择原有功能/异常集；原 `--perf/--negative/--trace/--corrupt-read` 保留。`--trace` 用于功能场景。

编译参数：WIDTH、RP、LINK_DEPTH、RX_DEPTH、WDATA_DEPTH、REQUEST_DEPTH、RESPONSE_DEPTH、MC_SLOTS；运行参数由 `--help` 列出。改变编译参数需要重新 make，直接运行旧可执行文件不会改变硬件容量。MC tag 宽度随槽数推导。

测试结束时继续保持尚未握手的地址，发完已接收 AW 对应的 W，再排空全部 R/B；收尾时间不放入稳态窗口。

## 4. credit 理论计算

需要区分链路帧 credit 与本工程 AoU 消息 credit。本工程不是“一个 credit 一帧”，而是 **每 RP、每消息类、一个 credit=5B**；发送完整消息时一次扣 g，跨帧不再次扣。

对第 k 类消息：

```text
lambda_k = 每周期目标消息条数
R_k = 从发送扣 credit 到返还 credit 可再次使用的周期上界
C_k >= ceil(lambda_k × R_k × g_k) + 安全余量（单位 5B 粒度）
depth_k >= ceil(C_k / min_granules_k)
```

固定长度场景可整条取整：`depth >= ceil(lambda × R) + 2`，代码报告这一更便于配置的保守条数；混合长度必须使用 `min_granules` 公布容量、按实际长度扣减。12 位计数限制 `depth × min_granules <=4095`。

例如 1024 位读、42.6667GB/s 时 lambda=42.6667×2/128=2/3 条/周期，g=27。假定 **完整 credit 周转上界** R=32 周期，则 depth≥ceil(64/3)+2=24 条，容量 648 个粒度；当前 32 条公布 864 个粒度，满足该预算。`--credit-rtt-cycles 32` 明确标记为预算假设，不是已实测最大 RTT。不限速读 lambda=1，同一预算需要 34 条；默认 32 条仍可能跑满，因为实际周转时间可能短于预算，不能反推预算已获证明。

WREQ/RREQ 的 lambda 为数据 beat 速率/B；WRESP 同样按每 burst 一条计算。**请求 FIFO 到最后一个 beat 发出才释放**，其 R 必须包含整笔 burst 的驻留时间，不能直接套用 RDATA 的 R。任意长的下游背压使 R 无上界，此时任何有限 FIFO 都不能保证不停顿。

R 包含：发送等待、消息到达/解析、接收 FIFO 驻留、消费者服务、返还调度、反向链路、PH 登记。多 RP 的授信轮询和反向链路占用也应计入。可先根据系统合同给 R 上界，再用停顿统计及压力用例检查预算；本次不假装从 PHY 单程延迟就能推导所有消息类的 R。

MC 同样应用流水线容量公式：`MC_SLOTS >= ceil(目标命令/周期 × 从发出到退休的周期上界) + 余量`。只增大 MC 响应延迟而不给足在途槽位，将测到容量限制而非存储固有带宽。

## 5. 物理模型纪律与引用修正

```text
B_raw = lanes × modules × lane_gbps / 8
B_budget = min(B_raw, --link-gbps)
t_serial = 256 / B_raw                       单位 ns
t_flight = t_serial + phy_ns + prop_ns + cdc_ns + adapter_ns
```

初始化检查 B_raw 不得超过 `shoreline_mm × density_gbps_mm`。物理场景必须显式提供岸线和密度；没有厂商/封装证据时不能用默认封装表宣布物理可实现。支持的参数组合为 S/x16 和 A/x64；3D 的不同传输机制需另建模型。

序列化调度和到达时间分别记录。两方向各有发送时刻与帧到达队列；不会把整个 t_flight 当作相邻帧间隔。到达时间不早于发送时间加 t_flight，再量化到 RTL 时钟沿。仿真 Flit 端口本身最多每 2ns 传一帧，即 128GB/s 原始接口容量，选择更快物理链路不自动放宽这个限制。

PHY/CDC/adapter 参数均是一方向两端合计。RTL 已经执行的消息打包/解包不再人工加一次；adapter_ns 只容纳当前 RTL 外的额外处理。没有真实 CRC/FEC/replay、训练、低功耗、动态重校准实现，本次也不注入这些随机事件。

参考材料中两点需修正：

- PCIe 6.0 标称 64GT/s 不能再因 PAM4 乘二成 128Gb/s/lane。[PCI-SIG 官方说明](https://pcisig.com/why-does-pcie-60-specification-utilize-pam4-signaling-over-nrz-signaling)给出的 x16 双向总带宽为 256GB/s，折合单向每 lane 原始 64Gb/s。本模型使用明确的原始 Gbps，避免 GT/s 与波特率混用。
- 2ns、5.5ns 不是所有配置的通用实测常量。[UCIe 官方问答](https://www.uciexpress.org/post/introduction-to-ucie-webinar-q-a-recap)中的 2ns 有特定 FDI-to-bump 往返边界和速率前提。应按选定 IP 的边界填写参数，不把不同边界的数字相加后强行校准到 5.5ns。

如果另建链路帧 credit，可用 `N >= ceil(B_raw × R_link /256)`。例如 256GB/s ×11ns /256B=11 帧，在理想连续时间模型下是最低数量；真实离散周期和调度通常需要余量。这个 11 帧不能代替本工程每类消息的 credit 计算。

## 6. 输出与判据

- `GBps`：读按 AXI R 完成字节、写按 B 返回关联字节计算；全宽、全选通性能场景才适用这种字节计法。
- `target_percent`：实测/用户指定基准。`--min-efficiency 0.90` 为真实失败门限。
- `theoretical_upper_GBps / upper_percent`：上述结构与协议上界及其利用率。
- `message_area_fill_percent`：从帧 MsgStart 与跨帧剩余量逐粒度统计的精确消息区占用，包括消息头；不能当作应用数据比例。
- `empty_frames`：没有消息粒度的帧，包括纯 PH credit 帧。
- `CREDIT`：以指定 R 预算计算的数据类建议条数和当前硬件容量，不是动态实测 RTT。
- `STALL_CYCLES(nonexclusive)`：各原因独立计数，允许重叠。credit_wait 表示存在待发消息缺 credit，即使其他消息本拍仍能发送也计数；不能把它直接当作总吞吐损失。ROB 峰值只覆盖测量窗。

有限窗口中，完成事务可能跨越窗口边界；写按整 burst 计数尤其明显。上限健全性检查保留两笔事务/窗口时长的容差，目标下限检查不作补偿；建议延长窗口比较，不能用四舍五入或裁剪制造达标。

## 7. 验证边界

功能、异常、独立字节记分板、AXI/Flit/MC 背压 SVA、编解码器周期门限由 Verilator 执行。外部工具的实际结果优先于结构推导。

技能公开门禁：compile 采用 Verilator；ast 及严格 readability/comment/naming/profile 自动检查受本机 Python 3.8 导入 `dict[str,...]` 错误阻断，未通过；SystemVerilog 保持项目约定，不套用必须改为 Verilog-2001 的规则。testbench/toolchain 记录实际运行的仿真证据，未执行综合、时序签核、CDC/RDC、形式等价或工艺后仿。手工 spec 与 WaveJSON 随代码提供，自动 spec 生成及 SVG 渲染未完成，未声称技能严格门禁通过。

# 端到端延迟、带宽与 credit 容量分析

本文根据当前源码及实际仿真分析延迟、速率、BDP、credit 和缓冲容量。核对日期为 2026-09-20，主仓库基线为 `c169ee8`；链路使用本地已安装接入补丁的 `reference/ucie-model`。除本文及文档入口外，分析没有修改正式模型源码。

## 1. 先明确结论与测量边界

当前实际全链路为：

```text
AXI BFM ⇄ Axi2Flit ⇄ UcieAouAdapter ⇄ UcieLink ⇄ AouTarget ⇄ SimpleBurstMemory
  AXI信号          帧握手             FDI FIFO          整突发请求/响应 FIFO
```

`reference/mem_sim` 尚未接入该测试，因此本次内存延迟来自 `SimpleBurstMemory`，不能作为同事的存储模型或真实 DRAM 的延迟。

| 问题 | 当前结论 |
|---|---|
| 链路单向空载延迟 | FDI 发射至对端 FDI 交付约 **6ns**，不包括两端时钟采样、桥和内存 |
| AXI 端到端读延迟 | 默认 256 位、单拍、无背压实例为 **48ns**，从 AR 握手到 R 握手 |
| AXI 端到端写延迟 | 同一配置的单拍实例为 **52ns**，从 AW 握手到 B 握手；从 WLAST 握手起算为 **48ns** |
| 裸带宽 | 默认 x16、24 G符号/s/lane、NRZ，**单向 48GB/s**，双向合计 96GB/s |
| 帧内消息区域带宽 | 扣除 16B 固定帧开销，满帧时 **45GB/s**；还没有扣除消息头、掩码、填充、credit 帧等 |
| 实际应用带宽 | 与位宽、负载、credit、后端及背压有关，不是固定 48GB/s；第 5 节给出实测 |
| credit 预算 | 代码采用 `40ns + 3 × 5.333ns = 56ns` 的容量预算，并非实际链路设置了 40ns 延迟 |
| credit 是否足够 | 功能回归通过；但实际持续负载中，**Target 的 64 个写数据 credit 与 SoC 的默认读响应窗口均限制吞吐**，见扩大窗口的对照实验 |

“端到端”必须标注起止事件。本项目适合使用以下三个口径：

1. **链路单程**：一帧开始序列化，到对端收到完整 FDI 帧。
2. **读事务**：ARVALID 与 ARREADY 握手，到首个 R 握手或最后一个 RLAST 握手。
3. **写事务**：AW 握手到 B 握手；另列 WLAST 握手到 B 握手，区分主机送写数据的时间。

若从主机拉高 VALID 开始计时，还要加入口等待 READY 的时间。`perf-all` 的报告标签写作 `ARVALID→Flit`、`Flit→RVALID/BVALID`，但源码时间戳实际记录的是 AXI 和帧接口的握手时刻，应以源码采样点为准，不能按这些标签理解为首次拉高 VALID。

## 2. 如何使用所提供文章中的分析方法

文章的“封包、序列化、PHY、传播、解包、跨时钟域、排队”拆分方法适合分析本项目，但不能直接把文中的参考数值当成本项目参数。

- **5.5ns 不是通用校准常数**：配置的 lane 数、帧大小、速率和测量边界不同，延迟自然不同。本项目单程约 6ns 是代码参数计算结果。
- **CRC 算法执行不等于模拟了 CRC 硬件耗时**：当前编码、CRC 和解码函数主要在同一个仿真时间点完成；只有显式等待和时钟级间交付才增加仿真时间。
- **BDP 是维持目标吞吐所需窗口的估算**，不是所有情况下的“在途上限”。实际窗口由 credit、重放缓冲、事务槽和队列共同限制。
- **带宽和容量单位必须一致**：物理帧 BDP 用裸带宽与物理帧大小；消息 credit 用消息字节速率与 5B 粒度；不能拿纯应用数据带宽直接除以 256B 来计算本项目的消息 credit。
- **GT/s 不能跨模型机械乘 2**：本地 `lane_rate_gtps` 实际按符号率使用，另乘 `bits_per_ui()`。文章中“PCIe 6.0 的 64GT/s 因 PAM4 变成单 lane 128Gb/s”的例子不正确。PCI-SIG 给出 x16 双向 256GB/s，折算单向、单 lane 是 64Gb/s，不能再翻倍。[PCI-SIG 官方说明](https://pcisig.com/why-does-pcie-60-specification-utilize-pam4-signaling-over-nrz-signaling)

本地模型没有岸线长度、封装带宽密度、独立 CDC 电路或 L1/L2 退出延迟参数。下面只计算已建模部分；“没有单独建模”不表示真实硬件耗时为零。

## 3. 当前延迟由哪些部分构成

### 3.1 默认参数

| 参数 | 当前全链路普通测试值 | 定义位置 |
|---|---:|---|
| AXI/桥/Target 时钟 | 2ns，500MHz | `tb_full_link.cpp` |
| lane 数 | 16 | `link_config.h` |
| 每 lane 符号率 | 24 G符号/s | `link_config.h` |
| 每符号位数 | 1，NRZ | `make_aou_ucie_config()` |
| 物理帧 | 256B，2048bit | `aou_types.h`、UCIe `Config` |
| 一帧序列化 | 128UI | `Config::serialize_ui()` |
| TX 流水 | 4UI | UCIe `Config::tx_pipe_ui` |
| 通道传播 | 8UI | UCIe `Config::channel_ui` |
| RX 流水 | 4UI | UCIe `Config::rx_pipe_ui` |
| lane skew | 普通全链路测试明确设为 0 | `tb_full_link.cpp`，不是 `Config` 的原始默认值 |
| ACK/NAK 反馈 | 32UI | `Config::feedback_ui` |
| 初始训练 | 512UI | `Config::train_ui` |
| 内存固定访问 | 20ns | `SimpleBurstMemory` 的 `access_` |
| 内存每拍附加时间 | 2ns | `SimpleBurstMemory` 的 `per_beat_` |

源码入口：[速率配置](../systemc/include/link_config.h)、[链路适配器](../systemc/integration/ucie_aou_adapter.h)、[UCIe 配置](../reference/ucie-model/src/ucie_common.h)、[全链路测试](../systemc/tb/tb_full_link.cpp)。

### 3.2 序列化、PHY 与链路传播

按模型定义：

```text
UI = 1 / 24 GHz = 0.0416666667ns
每 UI 搬运位数 = lanes × bits_per_symbol = 16 × 1 = 16bit
serialize_UI = ceil(256 × 8 / 16) = 128

t_ser     = 128UI = 5.333333333ns
t_phy_TX  =   4UI = 0.166666667ns
t_prop    =   8UI = 0.333333333ns
t_phy_RX  =   4UI = 0.166666667ns
t_skew    =   0UI = 0ns

L_FDI = t_ser + t_phy_TX + t_prop + t_skew + t_phy_RX = 6ns
```

执行路径在 [ucie_link.h](../reference/ucie-model/src/ucie_link.h)：

1. `TxAdapter::send_one()` 构造物理帧、计算 CRC，然后 `wait(serialize_ui × UI)`。
2. `PhyChannel` 计算误码行为，把帧交付时刻安排在 `tx_pipe_ui + channel_ui + max_skew_ui + rx_pipe_ui` 之后。
3. `RxAdapter` 检查 CRC、序号，向目的 FDI FIFO 写入数据，再发送 ACK。

PHY 延迟采用可重叠流水安排，因此无背压时**相邻帧间隔是 5.333ns，不是 6ns**。前一帧在传播/RX 流水中时，后一帧可以序列化。不要将 6ns 再加一次所谓“链路传输延迟”，那会重复计算。

普通测试时间分辨率为 1fs，`UI` 被量化为 41,667fs。因此实际记录是：

```text
t_ser = 5.333376ns
t_phy_TX + t_prop + t_phy_RX = 0.666672ns
L_FDI = 6.000048ns
```

这个很小的量化误差有时会把事件推到时钟沿之后，导致后续模块等到下一个 2ns 时钟沿。因此不能把全部分项四舍五入以后再推断握手时刻。

### 3.3 封包、解包和时钟交付

| 环节 | 模型中的具体行为 | 是否有独立固定延迟 |
|---|---|---|
| AXI 请求编码 | 握手沿写入桥内消息 FIFO | 编码函数无额外 `wait()` |
| `FlitPacker` 封包 | 后续时钟沿取消息，最多每次起 8 条消息；通过输出寄存器交付帧 | 有时钟级间交付；默认攒包超时为 0，不代表总延迟为 0 |
| `UcieAouAdapter` TX | 帧握手沿编码 250B，写 FDI FIFO | 编码无额外耗时，受 FIFO 背压影响 |
| CRC 生成/检查 | C++ 函数在当前时间点完成 | 没有单独的 CRC 流水周期参数 |
| Target 接收、解包 | 在 2ns 时钟沿读取 FDI，解析消息、组装写数据、尝试提交内存 | 到达至采样存在相位等待；可在同一时钟沿完成多个逻辑步骤 |
| Target 返回封包 | 取整笔内存响应后按 credit 装帧、写反向 FDI FIFO | 没有额外固定 1～2 拍的封包等待；拥塞时需要排队 |
| `UcieAouAdapter` RX | 在时钟沿读反向 FDI，保持输出，最早在下一桥时钟沿握手 | 至少包含一个输出交付周期，另有到达相位等待 |
| 桥解包至 AXI | Unpacker 分发消息到 FIFO，R/B 线程再取出并驱动响应 | 下游 READY 为高时，接收帧握手至 AXI 响应握手通常还有 2 拍 |
| 真正的异步 CDC | 没有双时钟 FIFO、同步器或亚稳态模型 | 不能声称已经测得真实 CDC 电路延迟 |

SystemC 的 delta cycle 用于同一时间点更新信号与 FIFO，不应额外按一个 2ns 周期收费。需要等待下一个时钟沿时，才产生相应的仿真时间。

### 3.4 一个可逐项相加的实际读事务

默认 256 位、RP1、普通测试 TC1：读取一个 32B 数据拍，RREADY 为高，没有其他业务排队。

本次在 `/tmp` 中对源码副本增加时间日志，记录以下事件；插桩没有增加 `wait()`，且插桩版完整 AXI CSV 与未插桩版逐字节一致。

| 时间 ns | 事件 | 距上个事件 ns |
|---:|---|---:|
| 230 | AR 握手 | — |
| 234 | 桥出站帧握手，进入 FDI 并开始序列化 | 4 |
| 239.333376 | 正向序列化结束 | 5.333376 |
| 240.000048 | 正向 FDI 交付 | 0.666672 |
| 242 | Target 采样、解包、提交内存；内存开始服务 | 1.999952 |
| 264 | 内存完成；Target 取得响应并开始反向发送 | 22 |
| 269.333376 | 反向序列化结束 | 5.333376 |
| 270.000048 | 反向 FDI 交付 | 0.666672 |
| 272 | Adapter 采样响应，驱动桥入站帧信号 | 1.999952 |
| 274 | 桥入站帧握手，Unpacker 分发读响应 | 2 |
| 276 | 桥 R 通道驱动 RVALID/数据 | 2 |
| 278 | AXI R 握手 | 2 |

由此：

```text
L_read = 4 + 6.000048 + 1.999952 + 22
           + 6.000048 + 1.999952 + 2 + 2 + 2
       = 48ns
```

按功能合并，分别是：发送封包与交付 4ns，双向序列化约 10.667ns，双向 TX/RX PHY 流水约 0.667ns，双向传播约 0.667ns，两次到达相位等待约 4ns，内存 22ns，Adapter 输出保持与桥响应交付共 6ns。

**不能再叠加文章中的“PHY 2ns”“CDC 1～2 周期”“封包 1～2 周期”**：部分环节已经包含在上述路径中，另一些没有单独建模。

### 3.5 突发、写事务和排队

简单内存一次只处理一笔完整请求：

```text
T_mem(N) = 20ns + 2ns × N
N=1 → 22ns；N=16 → 52ns；N=256 → 532ns
```

写请求必须先收齐整个突发才能提交；读请求要等整个内存服务结束后才拿到整笔响应。当前模型不是 DRAM 首拍一到就立即向链路转发的流式内存。

一般公式应写成：

```text
读首拍延迟 = 请求编码/封包 + 正向排队/传输 + Target 接收/提交
           + 内存排队/服务 + 响应封包/反向排队/传输 + SoC 接收/交付
读整笔延迟 = 读首拍延迟 + 剩余拍到达/AXI 排空时间

写总延迟 = AW 到最后写数据的输入与传输/组装过程
         + 内存排队/服务 + B 响应封包/排队/传输/交付
```

多个帧、AXI 送数、Target 组装可能重叠，不能把“全部 W 输入时间”和“全部 W 链路传输时间”机械相加。读返回也可能同时序列化后续帧、输出已有数据拍。

本次正式 `full-link-all` CSV 的部分结果如下，单位 ns；都是既定功能用例中的测量值，不是普适最小值。

| AXI 位宽 | 突发 | AR→首 R | AR→最后 R | AW→B | WLAST→B |
|---:|---|---:|---:|---:|---:|
| 256 | 1 拍，全宽 | 48 | 48 | 52 | 48 |
| 256 | 4 拍，全宽 | 54 | 60 | 86 | 76 |
| 256 | 16 拍，全宽 | 78 | 108 | 190 | 156 |
| 512 | 1 拍，全宽 | 48 | 48 | 58 | 54 |
| 512 | 16 拍，全宽 | 78 | 108 | 270 | 236 |
| 1024 | 1 拍，全宽 | 48 | 48 | 62 | 58 |
| 1024 | 16 拍，全宽 | 78 | 122 | 446 | 412 |
| 1024 | 256 拍，每拍访问 4B | 558 | 1758 | 4638 | 812 |

最后一行应用数据只有 1024B，但当前消息仍按 1024 位总线拍编码，不能按“只传了 1024B”估算线上流量。AW→B 很长而 WLAST→B 较短，说明入口送 W 数据也受 credit 和排队反压影响。

普通测试的内存访问为 20ns；`--stress` 改为 80ns，并同时缩小 FIFO、延长反馈、施加主机背压，因此压力测试不能只在普通延迟上加 60ns。

初始训练约 `512UI = 21.333504ns`，测试还等待复位释放和初始 credit 交换。上表从业务握手计时，未包含启动过程。错误重放、运行中背压和训练恢复也不能用固定空载延迟覆盖。

### 3.6 单独看 SoC 协议桥：与 20ns 指标的对照

若“协议桥接单元引入延迟不超过 20ns”指 `Axi2Flit` 自身的转换开销，应在它的 AXI 接口与帧握手接口之间测量，不计 UCIe 序列化、PHY、对端 Target 和内存访问时间。

当前 `tb_axi2flit_perf.cpp` 的 PERF-3 在 2ns 时钟、RP1、单拍事务、初始化完成后测量，每种位宽分别采集 20 次读和 20 次写：

| AXI 位宽 | 读 TX：AR 握手→请求帧握手 | 写 TX：WLAST 握手→对应数据帧握手 | RX：响应帧握手→R/B 握手 | TX+RX 的观测上界 |
|---:|---:|---:|---:|---:|
| 256 | 4ns | 4ns | 4ns | 8ns |
| 512 | 4ns | 4ns | 4ns | 8ns |
| 1024 | 4～8ns | 4～8ns | 4ns | 12ns |

最后一列用同类 TX、RX 的样本最大值相加，是已测样本的保守上界，不是无限负载空间的最坏情况证明。1024 位读 TX 平均 7.80ns、写 TX 平均 4.20ns；两者观察到的最大值均为 8ns。

因此，**按当前空载、单拍、2ns 时钟下的桥转换延迟口径，测量结果满足 20ns**。即使把请求发送和响应接收两次经过本桥的开销相加，样本上界 12ns 也低于 20ns。20ns 在当前时钟下相当于 10 个周期，而观察到的合计上界为 6 个周期。

简化测试还报告约 10～14ns 的完整往返，它包含简化对端交付的调度开销，不应全部归为桥延迟；第 3.4 节的 48ns 则包含实际链路和内存，更不应拿来与“桥接单元引入延迟”直接比较。

正式验收仍须明确以下边界：

- 20ns 是每个转换方向的上限，还是 TX+RX 的合计上限；单元是否包含 `UcieAouAdapter`。当前 PERF-3 不实例化该适配器。
- 是首拍/每拍的转换延迟，还是一整笔突发完成时间。流式桥能够边收边发，不能把长突发的全部输入与输出时间直接等同于桥新增延迟。
- 是无拥塞固有延迟，还是包含 credit 耗尽、队列等待和外部背压的墙钟时间。若下游可无限期不接收，任何有限缓冲桥都不能承诺所有事务 20ns 内交付。
- 指标是否要求最大值。当前自动门限只检查 TX 平均值≤12ns、RX 平均值≤8ns，虽然打印了最大值，但没有自动断言每个样本 TX+RX≤20ns，也未穷尽多 RP、跨帧和拥塞场景。

可复核的验收口径示例是：初始化及初始 credit 交换完成、指定时钟/位宽和负载、排除外部背压时，按接口实际握手记录桥转换延迟，对每个样本及最大值检查 20ns 门限；若需要包含背压，则另行明确最大停顿及负载约束。目前结论属于 SystemC 模型测量，不替代 RTL 时序或硅实现验收。

## 4. 通道速率是多少，怎样调整

### 4.1 计算公式

本模型把 `lane_rate_gtps` 当作 G符号/s：

```text
B_raw [GB/s] = lanes × lane_rate_gtps × bits_per_symbol / 8
B_AXI [GB/s] = AXI_DATA_BYTES / clock_period_ns
```

这里 GB/s 为十进制单位，数值与 B/ns 相同。默认 NRZ 单 lane 24Gb/s，16 lane 合计 384Gb/s，即单向 48GB/s。

| 配置示例 | 裸带宽，单向 | 256B 序列化时间 |
|---|---:|---:|
| x16、24 G符号/s、NRZ | 48GB/s | 5.333ns |
| x16、32 G符号/s、NRZ | 64GB/s | 4ns |
| x8、24 G符号/s、PAM4 | 48GB/s | 5.333ns |
| x16、24 G符号/s、PAM4 | 96GB/s | 2.667ns |

表中是本地模型数学配置，不代表已经验证了对应真实封装、PHY 或标准实现。

### 4.2 修改入口

在项目根目录，例如：

```bash
make full-link WIDTH=1024 \
  EXTRA_CXXFLAGS='-DAOU_LINK_LANES=16 -DAOU_LINK_RATE_GTPS=32.0 -DAOU_LINK_BITS_PER_SYMBOL=1'
```

`make_aou_ucie_config()` 将上述参数同步给 UCIe；适配器会检查桥和链路的速率、调制、格式是否一致。不能只改 UCIe 原始 `Config` 的默认值。

| 想调整的内容 | 调整位置与注意事项 |
|---|---|
| lane、符号率、NRZ/PAM4 | `AOU_LINK_LANES`、`AOU_LINK_RATE_GTPS`、`AOU_LINK_BITS_PER_SYMBOL` |
| AXI 位宽 | `WIDTH=256/512/1024`，会改变消息粒度及 SoC 接收 FIFO 深度 |
| credit 容量预算 | `AOU_LINK_TAT_NS`，只参与容量计算，不会自动给实际链路增加相同延迟 |
| PHY、传播、ACK 延迟 | 顶层传给 `UcieLink` 的 `Config`：`tx_pipe_ui/rx_pipe_ui/channel_ui/feedback_ui`；当前全链路命令行没有这些选项 |
| 时钟周期 | 全链路顶层 `sc_clock`；同时复核容量公式中的 `MODEL_CLK_PERIOD_NS=2.0` 等时钟假设 |
| 外部帧/内存 FIFO | `tb_full_link.cpp` 的构造参数，不能用 `Config::fdi_queue_size` 替代 |
| Target 接收 credit | `REQUEST_SLOTS`、`WDATA_GRANULES`，当前不会随链路速率自动扩容 |
| 内存服务时间 | `SimpleBurstMemory` 构造参数；`Config::memory_delay_ui` 属于链路独立测试入口，不控制当前内存 |

由于 PHY/传播延迟以 UI 配置，保持 UI 数不变而提高符号率，会同时缩短其 ns 延迟。若目标是“只提高带宽，保持传播时间不变”，必须重新换算这些 UI 参数。

## 5. 有效带宽是多少

### 5.1 逐层扣除开销

当前帧大小关系为：

```text
256B 物理帧 = 2B 链路帧头 + 4B CRC + 10B 协议头 + 240B 消息区域
250B FDI 内容 = 10B 协议头 + 240B 消息区域
```

因此：

```text
FDI 内容带宽上限 = 48 × 250/256 = 46.875GB/s
消息区域带宽上限 = 48 × 240/256 = 45GB/s
应用带宽 = 消息区域带宽 × 应用数据/消息字节
           × 实际填充与调度效率 × 有效新传输占比
```

还应计算空闲、纯 credit 帧、重放、请求/响应混合、掩码屏蔽和窄访问的影响；各效率项必须使用不重叠的统计口径。

例如 1024 位读响应每拍承载 128B 应用数据，消息占 27 个 granule，即 135B：

```text
B_read_ideal = 45 × 128/135 = 42.6667GB/s
```

16 拍全 strobe 写，计入同方向的 15B 写请求头：

```text
B_write_ideal = 45 × (16×128)/(15 + 16×135)
              = 42.3724GB/s
```

这是长时间平均、充分聚合下的协议上限估算。有限测量窗口可能把请求头放在窗口外，所以回归记录的 42.40GB/s 与该估算略有差异，不构成超越物理上限。

| AXI 位宽 | AXI 数据通道上限 | 充分聚合的读数据协议上限 | 简单内存 16 拍纯服务上限 |
|---:|---:|---:|---:|
| 256 | 16GB/s | 36GB/s | `512/52 = 9.846GB/s` |
| 512 | 32GB/s | 41.143GB/s | `1024/52 = 19.692GB/s` |
| 1024 | 64GB/s | 42.667GB/s | `2048/52 = 39.385GB/s` |

纯服务上限还没有扣除请求间空隙、credit 等待、帧填充与队列背压。持续读写混合时，内存的串行服务能力由读写共同分享。

### 5.2 正式桥基线与实际全链路不能混用

本次 `make perf-all` 通过，持续读/写结果为：

| AXI 位宽 | 桥基线读 | 桥基线写 |
|---:|---:|---:|
| 256 | 16.00GB/s | 16.00GB/s |
| 512 | 32.00GB/s | 32.00GB/s |
| 1024 | 42.66GB/s | 42.40GB/s |

这些测试使用简化对端和 `LinkPacer`，未实例化上述真实 `UcieLink + AouTarget + SimpleBurstMemory` 全链路。其零飞行配置的约 10ns 单事务延迟，也不能用作完整链路延迟。

`full-link-all` 是功能用例集，含显式等待、错误地址、窄访问及长背压。直接用全部字节除以整个测试总时长，只能得到该用例集平均速率，不能表示稳态能力。

### 5.3 本次补充的实际全链路持续负载实验

为补齐这一缺口，本次在 `/tmp` 中复用完整链路与原记分板，替换测试激励：

- 1024 位、RP1、2ns 时钟、x16 NRZ 24 G符号/s；普通 FIFO 深度和默认无误码参数。
- 先连续提交 512 笔读，再排空并连续提交 512 笔全 strobe 写；每笔 16 拍、2048B。
- 地址在 16 个 4KB 页起点间循环，均落在内存窗口内；读阶段在写阶段之前，检查零初始化读数据。
- RREADY/BREADY 保持高；发出下一笔时不等待上一笔响应，允许在途请求。
- 每阶段取第 128 笔完成到第 384 笔完成之间的 256 笔作为测量窗口，避开启动和排空。
- 读以 RLAST 握手计完成，写以 B 握手计完成，分子均为 `256×2048=524288B`。

默认源码的测量结果：

| 方向 | 窗口开始 ns | 窗口结束 ns | 窗口时间 ns | 应用带宽 |
|---|---:|---:|---:|---:|
| 读 | 10452 | 30932 | 20480 | **25.60GB/s** |
| 写 | 96692 | 207284 | 110592 | **4.74074GB/s** |

该实验完成 512 读、512 写，记分板错误为 0。它是明确负载下的补充实测，不是已经加入项目的正式性能门限，也不是所有负载的绝对峰值。

为验证瓶颈，在临时副本中**仅把 Target 的 WDATA credit 从 64 增加到 512**，其余不变：读保持 25.60GB/s，写上升到 **22.58888GB/s**。这说明默认写 credit 窗口确实是显著瓶颈；扩大该窗口仍不足以让整个系统达到 42GB/s。

在上述副本上，再将 SoC 每 RP 的 RDATA FIFO 从 23 条扩大到 96 条，对应 RDATA credit 从 621 增至 2592，结果如下：

| 临时实验配置 | 读 GB/s | 写 GB/s | 记分板错误 |
|---|---:|---:|---:|
| 正式默认：WDATA 64，RDATA 23 条 | 25.60 | 4.74074 | 0 |
| 仅增大 WDATA：512，RDATA 23 条 | 25.60 | 22.58888 | 0 |
| WDATA 512，RDATA 96 条 | 39.38462 | 22.58888 | 0 |

第三组读窗口为 6956～20268ns，`524288/13312 = 39.38462GB/s`，达到当前串行内存的 16 拍纯服务上限；`Target.response_credit_stalls` 也从前两组的 8221 次降为 0。由此可以确认默认读响应窗口/credit 回收过程也限制了这个实际负载。

96 条是用于定位瓶颈的对照值，未搜索最小深度；512 个 WDATA credit 同样不是已验证的最优配置。正式模型仍保持原值。扩大两类窗口后写带宽仍低于内存上限，说明还需要分析归还帧排队、组装/提交节奏等限制，不能把剩余差距全部归因于物理链路。

## 6. credit 是什么机制

### 6.1 业务消息 credit

[CreditManager](../systemc/include/credit_manager.h) 按 `(RP, 消息类别)` 独立计数，**一个 credit 表示 5B 的消息接收资源承诺**，不是一个 AXI beat，也不是一个 256B flit。

类别为 `WREQ / RREQ / WDATA / RDATA / WRESP`。同一类别下消息占多少 granule，发送时就扣多少 credit。

流程为：

1. 接收端根据可用容量公布初始 credit，发送端初始可用 credit 为 0。
2. 发送端在开始封装一条消息前，检查并一次性扣除整条消息需要的 credit；即使跨帧，也不是按每个分片重新扣。
3. 消息进入接收端后，只有相应资源被释放才能归还 credit。
4. 归还量随普通帧的头部发送；桥没有业务帧时经过空闲计数发送专用 `CrdtGrant`。Target 可以直接发送仅头部有 credit 的帧。
5. 对端解出 credit 后更新可用计数，恢复发送。

资源释放点并不相同：

| 接收端/类别 | 当前归还时机 |
|---|---|
| SoC 桥 RDATA | AXI R 实际握手，不能仅在消息进入 R FIFO 时归还 |
| SoC 桥 WRESP | AXI B 实际握手 |
| Target WDATA | 数据从暂存队列转入已预留的整突发写请求空间 |
| Target WREQ/RREQ | 整笔请求成功提交到内存请求 FIFO |

Target 的全局未完成事务槽另受 `MAX_OUTSTANDING=8` 限制，最后响应消息全部写入链路发送 FIFO 后才释放；它与请求接收 credit 是两套资源。

这也解释了 256 拍写为什么不会因为 64 个 WDATA credit 永远做不完：Target 逐拍把数据搬入整突发缓冲并及时归还 credit，允许后续数据继续进入。

### 6.2 编码会影响归还速度

大部分 credit 字段一次只能表达：`0、1、4、8、16、32、64、128`；WRESP 字段一次最大表达 8。

例如单独归还 27 个 credit，若没有新归还量合并，贪心编码需要 `16+8+1+1+1` 多次发送。一个普通头部一次只携带一个 RP 的 credit；多 RP 之间轮转。

“收到一次消息就能在一个返回帧中完整归还全部 credit”并不总成立。空载与满载下合并程度不同，credit 往返排队也不同。纯 credit 帧虽然不带应用数据，仍占完整 256B 物理帧和序列化时间。

### 6.3 不要与 ACK/NAK 重放窗口混淆

UCIe 发送端另外维护 `retry_buffer_size`，单位是**未确认的物理帧数量**。CRC/序号正确后产生 ACK，发送端据此释放重放副本；出错则 NAK/超时触发重放。

业务 credit 防止对端协议资源溢出，ACK/NAK 保证链路交付可靠。ACK 不表示内存访问完成，也不等于归还业务 credit。当前反馈通过独立的 `FeedbackPath` 传输，没有模拟它与反向业务帧共享线上带宽；业务 credit 则确实经过业务链路。

## 7. BDP 应该怎么算

### 7.1 统一原则

```text
BDP = 目标发送速率 × 从占用资源到资源可再次使用的时间
```

RTT 必须对应所分析的资源。AXI 读完成的 48ns、UCIe ACK 往返和消息 credit 回收周期不是同一个时间。

### 7.2 链路 ACK / 重放窗口

无背压、无错误时，从开始序列化到 ACK 回来约为：

```text
RTT_ACK = (128 + 4 + 8 + 4 + 32)UI
        ≈ 7.333ns
BDP_ACK ≈ 48B/ns × 7.333ns = 352B
最低连续发送窗口 ≈ ceil(352/256) = 2 帧
```

默认重放窗口为 64 帧，约 16KiB 物理帧副本，远大于这个理想值。压力配置为 8 帧、反馈 256UI，理想 ACK 周期约 16.667ns，至少需要约 4 帧。

这些是理想下限。接收 FDI 堵塞时，RX 线程写出数据后才 ACK，实际窗口占用时间会变长；重放、超时也会改变结果。不能据此把所有配置都缩为 2 帧。

### 7.3 当前业务 credit 的设计预算

[aou_types.h](../systemc/include/aou_types.h) 定义：

```text
T_flit = 256 / 48 = 5.333333ns
CREDIT_LOOP_NS = LINK_TAT_NS + 3 × T_flit
               = 40 + 16 = 56ns

BDP_raw = 48 × 56 = 2688B = 2.625KiB
        = 10.5 个 256B 帧；若按帧计，向上取整为 11 帧

BDP_message = 45 × 56 = 2520B
            = 504 个 5B credit
```

504 是假设消息区域满速、单类消息独占时的基础窗口，还要按整条消息取整并保留流水余量。它不是所有类型各自实际都要同时发送 45GB/s，也不是只有 504 字节。

本次单拍读中，Target 在 264ns 扣除 RDATA credit，SoC 在 278ns 接受数据，携带相应归还量的帧在 292ns 被 Target 接收，示例环路为 28ns。这个空载例子小于 56ns，**不证明持续负载的最坏环路也小于 56ns**；排队、归还编码、主机停顿都会拉长周期。

## 8. 当前两端有多少 buffer，是否够用

### 8.1 SoC 桥接收侧

代码使用消息折算物理字节来计算 RDATA FIFO：

```text
message_wire_bytes(g) = g × 5 × 256/240
RDATA_depth = floor(56 × 48 / message_wire_bytes(g)) + 1 + 4
RDATA_credit = RDATA_depth × g

WRESP_depth = floor(56 / 2) + 4 = 32
WRESP_credit = 32 × 1 = 32
```

额外的 `+1` 即使整除也保留，`+4` 是固定流水余量。

| AXI 位宽 | RDATA 每拍 granule | RDATA FIFO 条数/每 RP | RDATA credit/每 RP | 消息容量 | 对应全宽应用数据容量 |
|---:|---:|---:|---:|---:|---:|
| 256 | 8 | 68 | 544 | 2720B | 2176B |
| 512 | 14 | 41 | 574 | 2870B | 2624B |
| 1024 | 27 | 23 | 621 | 3105B | 2944B |

每个 RP 另外有 32 条 WRESP，协议内容为 160B。上表是协议容量，不是 C++ 对象的 `sizeof`；消息对象还包含固定数组、元数据和容器开销。

**判断**：该配置在 `perf-all` 的 40ns 附加往返简化测试中保持吞吐，符合其设计口径；但实际全链路 1024 位读只测得 25.60GB/s。扩大到 96 条后达到 39.38462GB/s，说明默认窗口不足以使该实际负载达到后端服务上限。需要结合真实归还周期、credit 帧调度及后端服务重新评估，不能把简化基线通过当成充分证明。

### 8.2 Target 接收侧

| 资源 | 每 RP 当前容量 | 说明 |
|---|---:|---|
| WREQ | 4 笔，12 credit | 每笔请求头占 3 granule；每槽需要保存整笔突发上下文 |
| RREQ | 4 笔，12 credit | 每笔请求头占 3 granule |
| WDATA 暂存 | 64 credit，即 320B 消息内容 | 与完整写突发缓冲分开 |
| 已提交、响应尚未全部送出 | 全局 8 笔 | 不是每 RP 8 笔，也不是内存并行服务 8 笔 |

64 个 WDATA credit 能一次覆盖的完整消息数：

| AXI 位宽 | 全 strobe 写：每拍 credit / 最多拍数 | 带 strobe 写：每拍 credit / 最多拍数 |
|---:|---|---|
| 256 | 7 / 9 拍 | 8 / 8 拍 |
| 512 | 14 / 4 拍 | 15 / 4 拍 |
| 1024 | 27 / 2 拍 | 30 / 2 拍 |

在 45GB/s 消息区域目标速率下，64 credit 只覆盖：

```text
64 × 5 / 45 ≈ 7.11ns
```

而数据向前传、credit 向后传，仅两次理想单程就约 12ns，尚未加入时钟采样、组装和 credit 编码。因此这个窗口不能维持消息区域满速；1024 位场景只有两拍数据的窗口尤其明显。

**判断**：64 个 credit 足以让长突发通过分批归还完成功能闭环，但不够作为默认满带宽窗口。第 5.3 节的 64→512 对照已验证这一限制。请求的 4 个槽是否需要扩大，要按请求速率、突发长度、内存队列阻塞和全局 8 笔限制另算，不能直接套用数据字节 BDP。

### 8.3 完整突发缓冲不能漏算

WDATA 的 320B 只是待组装消息窗口。归还它之前，数据已经转入写请求的 `write_beats`，这部分也必须有空间。

当前每 RP 最多有 4 个正在组装或等待提交的写请求。虽然有效地址跨度不能跨 4KB，窄访问仍按完整 AXI 总线宽度保存每拍数据和 strobe。1024 位、256 拍窄突发，一个写请求需要：

```text
数据数组 = 256 × 128B = 32KiB
逐字节 strobe 数组 = 256 × 128B = 32KiB
每拍 USER = 256 × 2B = 512B
4 个写请求合计约 258KiB/每 RP，加地址及容器元数据
```

这是当前 C++ 表示的容量量级；真实硬件若压缩 strobe 或只存有效字节，可不同。内存 FIFO、后端正在处理的请求、整笔读响应也可能持有自己的数据副本。不能以“只有 64 credit”推断整个 Target 只需要 320B 存储。

### 8.4 其他队列与物理建模限制

| 队列 | 普通全链路配置 |
|---|---:|
| 桥 TX RREQ/WREQ/WDATA FIFO | 每类、每 RP 各 16 条消息 |
| 桥 credit 更新/归还 FIFO | 各 64 个事件 |
| `soc_tx/soc_rx/mem_tx/mem_rx` | 每条 8 帧；按物理帧折算为每条 2KiB |
| `requests/responses` | 每条 4 笔完整内存事务，容量不能按 4 个 flit 理解 |
| UCIe 每方向 TX→PHY、PHY→RX | 各 4 帧 |
| UCIe 每方向反馈通道 | 各 64 条 ACK/NAK 消息 |
| UCIe 重放缓冲 | 每方向 64 帧 |

压力测试把四条公开帧 FIFO 和两条内存 FIFO 缩为深度 1，用于验证反压恢复，不是推荐性能配置。

`PhyChannel::pending_` 与 `FeedbackPath::pending_` 是没有显式容量上限的 `std::deque`。它们承担在途事件暂存，但长期下游堵塞时不能等价为已经验证过容量的硬件缓冲。因此现模型可以做行为和流控分析，不能直接据此签核两端所有 SRAM 的物理容量。

### 8.5 后续容量应如何定

对每个 RP、每类消息分别计算：

```text
C_required ≥ ceil(message_byte_rate × T_credit_reuse / 5)
             + 最大整消息/流水余量
```

其中 `T_credit_reuse` 从发送端扣除 credit 开始，到同等容量真正可再次使用为止，包括发送排队、正向传输、接收端占用、反向归还排队和解析。应记录高水位与环路分布，并对承诺的最大背压做预算。

若暂沿用本项目 56ns、48GB/s 裸速率和相同 `+1+4` 消息余量，满速全 strobe WDATA 的参考值为：

| 位宽 | WDATA 消息槽数 | 对应 credit |
|---:|---:|---:|
| 256 | 77 | 539 |
| 512 | 41 | 574 |
| 1024 | 23 | 621 |

这说明应评估约 540～620 credit 量级，而非 64。可选便于实现的向上取整值，但**这些只是 56ns 假设下的设计起点，不是已验证的最小值或保证值**；带 strobe 消息、不同速率和实际更长环路应重新计算。计数器当前上限为 4095，也要核对。

对于整事务槽，使用 `请求速率 × 槽占用时间` 估计并发数；对帧 FIFO，根据消费者停顿期间的到达帧数定深度。不能把同一个 BDP 数重复要求到路径中每条 FIFO，也不能因为路径上 FIFO 总字节数很多就认为某个独立消息 credit 窗口足够。

若主机可无限期保持 RREADY/BREADY 为低，任何有限容量都不能保证永不阻塞。正确目标是安全反压、不丢数据，以及在约定的有限停顿后恢复吞吐。

## 9. 如何复核结果

### 9.1 正式测试和波形

项目根目录执行：

```bash
make full-link-all
make perf-all
```

本次两个命令均成功：完整链路 12 种配置，每种 12 组用例，共 144 组；桥性能三种位宽全部通过。全链路功能通过不等于达到某个持续带宽目标。

主要产物：

- `systemc/sim/full_link_<位宽>_rp1.csv`：AXI 实际握手记录。
- `systemc/sim/full_link_<位宽>_rp1.vcd`：AXI、帧接口和链路状态波形。
- `systemc/sim/full_link_<位宽>_rp1.log`：用例结果及 Target/链路计数。
- `systemc/sim/perf_<位宽>.log`：简化链路桥性能；不要误作全链路报告。

CSV 对账方法：同一 ID 的 AR 和 R 按请求先后配对，首 R/最后 R 时间减 AR 时间；AW 与 B 同样按 ID 和顺序配对。W 没有 ID，应按已接受 AW 的顺序、拍数和 WLAST 关联。不能只取“同 ID 的第一个和最后一个记录”，因为同 ID 可以有多笔事务。

波形中以 `VALID && READY` 的时钟沿为准，观察 `axi.ar* / axi.r* / axi.aw* / axi.w* / axi.b*`，再对照 `flit.tx / flit.rx`。原 VCD 没有内存服务和链路内部逐级事件，所以仅凭这个 VCD 不能独立拆出所有 PHY 分项；第 3.4 节结合了源码等待点和临时日志。

### 9.2 补充持续负载的复现方法

这不是新的正式测试目标。原始代码、插桩代码和扩大 credit 的实验都放在 `/tmp/axi2flit-latency-probe`，可能随临时目录清理而消失；下面说明如何重新生成，不依赖这些文件永久存在。

复制 `systemc/tb/tb_full_link.cpp` 到临时目录，保留模块、端口、监视器和 `sc_main()`，只将 `FullLinkTb::stimulus()` 替换为：

```cpp
void stimulus() {
    try {
        rst.write(false); av.write(false); arv.write(false); wv.write(false);
        until([&] { return state.read() == unsigned(LinkState::Active); }, "training");
        cycles(2); rst.write(true); cycles(100);
        for (unsigned phase = 1; phase <= 2; ++phase) {
            testcase.write(phase); tick();
            for (unsigned i = 0; i < 512; ++i) {
                auto a = address(i, (i % 16) * 4096, 16);
                send_address(a, phase == 1);
                if (phase == 2) send_data(a, i);
            }
            drain(); cycles(100);
        }
        std::cout << "STREAM errors=" << failures << "\n";
        done = true; csv.flush(); sc_stop();
    } catch (const std::exception& e) {
        check(false, e.what()); done = true; csv.flush(); sc_stop();
    }
}
```

假设修改后的测试副本为 `/tmp/axi2flit-latency-probe/stream.cpp`，在项目根目录使用以下命令编译，然后从临时目录运行；不加 `--stress/--replay`：

```bash
mkdir -p /tmp/axi2flit-latency-probe/sim
g++ -std=c++17 -O2 -DAXI_DATA_WIDTH_CFG=1024 \
  -I"$HOME/.local/systemc-2.3.4-cxx17/include" \
  -Isystemc/include -Isystemc/integration -Ireference/ucie-model/src \
  systemc/src/flit_packer.cpp systemc/src/flit_unpacker.cpp systemc/src/axi2flit.cpp \
  /tmp/axi2flit-latency-probe/stream.cpp \
  -L"$HOME/.local/systemc-2.3.4-cxx17/lib" \
  -Wl,-rpath,"$HOME/.local/systemc-2.3.4-cxx17/lib" -lsystemc -lpthread \
  -o /tmp/axi2flit-latency-probe/stream
cd /tmp/axi2flit-latency-probe
./stream > stream.log 2>&1
```

对生成的 CSV 按 `case=1, channel=R, last=1` 和 `case=2, channel=B` 各取完成时间数组 `t`：

```python
bandwidth_GBps = 256 * 16 * 128 / (t[383] - t[127])
```

扩大 WDATA 窗口的对照版本只在临时 `aou_target.h` 中把 `WDATA_GRANULES = 64` 改成 `512`，并将该目录放到头文件搜索路径前面。运行前后均应检查 `STREAM errors=0`。不要将这种局部容量实验混入正式默认配置的性能结果。

读窗口对照还需复制 `systemc/include/` 中的头文件到另一临时目录，将副本 `aou_types.h` 中的 `RX_RDATA_FIFO_DEPTH_PER_RP` 定义设为 96，其余保持一致，再把该目录放到搜索路径最前面；必须使所有编译单元使用同一套头文件。三组运行使用独立工作目录及 `sim/`，分别保留 CSV。

## 10. 接入真实主机和存储模型后的关注点

后续应保持上述测量边界，额外记录主机排队、适配器拆分/聚合、内存请求接受和完成时刻。存储模型用自己的周期推进时，需要定义它与 SystemC 时间的换算；不能把一次 `step()` 默认当成当前桥的 2ns。

建议先建立独立的全链路性能用例，分别测试空载单请求、持续读、持续写、双向混合、小包、窄访问及受控背压，并记录每类 credit 的耗尽时间、归还周期与队列高水位。然后依据目标负载调整 Target 窗口、整突发缓冲、SoC 接收窗口和 credit 发送策略。

当前可以确认功能闭环正确、默认时序可追溯；**实际全链路尚不能用桥基线的 42GB/s 作为已达成指标，默认 credit 和缓冲配置也不能宣称对所有后端都足够。**

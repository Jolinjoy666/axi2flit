# RTL 协议桥设计与接口说明

日期：2026-09-22。本文对应 `rtl/` 中的 SystemVerilog 实现；原有 SystemC 行为模型保留，二者使用相同消息字节格式，但不是逐周期等价实现。

## 1. 本次实现的边界

```text
SoC AXI Master
    ⇅ AXI 五通道信号
axi2flit_soc
    ⇅ 250B Flit ready/valid
链路/适配层                         当前 RTL TB：每方向深度 2 的 FIFO
    ⇅ 250B Flit ready/valid
flit2mc_target
    ⇅ 带 tag 的逐拍 MC 请求/完成接口
MC 请求端                         当前 RTL TB：独立字节内存 + 可乱序完成队列
    ⇅ MC 自己生成的 DRAM/DFI 时序     本次未实现、未连接
```

RTL 包含寄存器、固定深度 FIFO、组合逻辑和状态转移；数据通路中没有动态容器、仿真等待或软件内存模型。测试中的 C++ 内存不属于 RTL。

“原子化命令”在本接口指一个 AXI beat 对应的一条 MC 读/写命令，不是 AXI atomic 指令。明确选择 **MC 请求侧边界**，由 MC 负责地址到 bank/row/column 的映射、调度、刷新和 DFI/PHY 时序。因此不能将 `flit2mc_target` 直接命名为已完成的 DFI 控制器。

## 2. 文件与模块划分

| 文件 | 职责及内部边界 |
|---|---|
| [aou_pkg.sv](../rtl/aou_pkg.sv) | 固定类型、协议长度、字段编解码、PH 布局；纯组合函数，无寄存器 |
| [aou_sync_fifo.sv](../rtl/aou_sync_fifo.sv) | 固定存储、读写指针、占用计数；`FWFT=0` 时空队列不旁路，`FWFT=1` 时空队列可同拍直通；满且同拍出队允许入队 |
| [aou_flit_tx.sv](../rtl/aou_flit_tx.sv) | 消息仲裁、整消息扣 credit、跨帧续传、PH 授信；在建帧和输出帧分别保存 |
| [aou_flit_rx.sv](../rtl/aou_flit_rx.sv) | 双槽帧 FIFO、前两帧 MsgStart 扫描与拼接 MUX、完整消息输出寄存器；稳态每拍一条消息 |
| [aou_transport.sv](../rtl/aou_transport.sv) | 组合 TX/RX；每 RP/消息类型接收 FIFO；三套 credit 账本及协议检查 |
| [axi2flit_soc.sv](../rtl/axi2flit_soc.sv) | AXI 从机；AW/W 关联、请求缓冲、ID/RP 在途状态、B/R 返回选择 |
| [flit2mc_target.sv](../rtl/flit2mc_target.sv) | 请求拆拍、MC 发令、固定槽位 ROB、乱序完成收集、按序退休、B 聚合 |

两端分别实例化自己的 `aou_transport`，不是两端共用一套状态。逻辑分层使协议格式、传输流控、主机语义和存储语义可以独立修改。

参考 `reference/tt-oca-harness-aou/RTL/` 的 FIFO 指针管理、仲裁成功才推进、背压保持及跨帧续传思路，未复制其工程顶层或移植整套 RTL。参考工程的 CSR、完整 FDI 状态机、QoS 三模式/超时仲裁不属于本版实现。当前使用公平轮转，在有 credit 的候选间选择；不提供高 QoS 优先级保证。

## 3. 公共时序与链路接口

以下方向均相对一个桥端模块，两个顶层相同。

| 端口 | 方向/位宽 | 契约 |
|---|---|---|
| `clk` | 输入，1 | 所有本端接口在上升沿握手 |
| `rst_n` | 输入，1 | 低有效异步复位；集成时由复位控制器保证同步释放 |
| `link_up` | 输入，1 | 链路可用门控；复位后先置 0，训练完成后置 1 |
| `flit_tx_valid/data` | 输出，1/2000 | 本端发送的一整个 250B 逻辑 Flit |
| `flit_tx_ready` | 输入，1 | 下游可以接受一整帧 |
| `flit_rx_valid/data` | 输入，1/2000 | 对端送来的一整个逻辑 Flit |
| `flit_rx_ready` | 输出，1 | 本端可以接受一整帧 |
| `protocol_error` | 输出，1 | 粘滞错误位，直到联合复位清除 |

正常运行时，`valid && ready` 在上升沿成立才转移一次数据。`valid && !ready` 时发送方保持 valid 和所有载荷，不允许只保持 data 而撤销 valid。valid 为 0 时载荷无意义。

`flit_data[1999:1992]` 对应逻辑 byte0，`[7:0]` 对应 byte249：前 10B 为 AoU PH，后 240B 为消息区。它不是物理 256B 帧，也不是完整原生 FDI 电气/管理接口。FH/CRC、重放、训练、lane/速率适配属于后续链路层。接入 SystemC UCIe 模型时，需要在仿真包装层进行 `2000-bit ↔ 250-byte FIFO item` 转换和时钟同步，不能将 SV 向量直接绑定到 `sc_fifo` 对象。

运行期间不要用 `link_up` 暂停任意在途帧；短暂拥塞使用 ready。掉链/错误恢复要求 SoC 桥、Target、链路队列及 MC 在途状态共同复位或取消。当前没有单端热复位、旧 tag 隔离或事务重试协议；复位会取消未完成事务。

## 4. SoC 侧：`axi2flit_soc` 的完整 AXI 接口

令 `D=DATA_WIDTH`，`W=D/8`。端口名均带 `s_axi_` 前缀，方向相对桥。

| 通道 | 主机 → 桥输入 | 桥 → 主机输出 |
|---|---|---|
| AW | `awvalid`、`awaddr[63:0]`、`awid[9:0]`、`awlen[7:0]`、`awsize[2:0]`、`awburst[1:0]`、`awprot[2:0]`、`awcache[3:0]`、`awqos[3:0]`、`awlock`、`awuser[15:0]` | `awready` |
| W | `wvalid`、`wdata[D-1:0]`、`wstrb[W-1:0]`、`wlast`、`wuser[15:0]` | `wready` |
| AR | `arvalid`、`araddr[63:0]`、`arid[9:0]`、`arlen[7:0]`、`arsize[2:0]`、`arburst[1:0]`、`arprot[2:0]`、`arcache[3:0]`、`arqos[3:0]`、`arlock`、`aruser[15:0]` | `arready` |
| B | `bready` | `bvalid`、`bid[9:0]`、`bresp[1:0]`、`buser[15:0]` |
| R | `rready` | `rvalid`、`rdata[D-1:0]`、`rid[9:0]`、`rresp[1:0]`、`rlast`、`ruser[15:0]` |

支持范围：`AxBURST=INCR(01)`，首地址按 `2^AxSIZE` 对齐，`AxSIZE≤log2(W)`，不跨 4KB。拍数为 `AxLEN+1`，最大 256 拍；支持窄访问、部分和全零 WSTRB。没有 WID、REGION、ATOP 和独占监视器。LOCK 仅透传给 MC，不能据此声称支持独占成功。

AW、AR、W 独立背压。W 按已接受的 AW 顺序关联；W 可以先拉 valid，但桥在收到 AW 前不会握手 W。WLAST 必须和 AWLEN 对应，AW 不需要与首拍 W 同周期到达。非法 BURST/SIZE/对齐/4KB/WLAST 在入口握手时置错且不入发送队列；采用 fail-stop，不承诺给非法请求补造 DECERR。

`RP=AxQOS % RP_COUNT`。RP1 时始终是 RP0，不存在 RP 间竞争，但读/写及不同消息类型仍可能共享打包器、MC 接口而竞争。RP 多于 1 时，同一方向、同 ID 的未完成事务固定在同一 RP；同 ID 新请求改投其他 RP 会背压，直到原事务完成。读写方向的 ID 状态独立。

B/R 输出在背压时锁住所选 RP。返回 ID/RP 必须属于在途请求；错误响应不交付主机。桥没有为每个在途读保存完整 LEN 队列，接收侧不独立检查每笔 RLAST 的位置；合法 RLAST 由本项目 Target 根据 ARLEN 生成，TB 逐拍检查。若未来允许不可信响应端，应增加接收事务上下文检查。

## 5. 存储侧：MC 输入输出契约

MC 应连接 `flit2mc_target` 的以下端口；“输出”均指 Target 输出、MC 输入。

### 5.1 命令通道

| 信号 | 方向/位宽 | 含义 |
|---|---|---|
| `mc_req_valid` / `mc_req_ready` | 输出/输入，各 1 | 命令交付握手；接受不等于操作完成 |
| `mc_req_write` | 输出，1 | 0=读，1=写 |
| `mc_req_tag` | 输出，TAG_WIDTH | 此条命令的唯一在途标签；响应必须原样带回 |
| `mc_req_rp` / `mc_req_id` | 输出，2/10 | 原 RP 和 AXI ID，用于追踪，不替代 tag |
| `mc_req_addr` / `mc_req_size` | 输出，64/3 | 本拍字节地址、访问字节数的 log2 |
| `mc_req_len` / `mc_req_beat` | 输出，各 8 | 原 AxLEN、当前拍序号，从 0 开始 |
| `mc_req_first` / `mc_req_last` | 输出，各 1 | 当前拍是否为原突发首/末拍 |
| `mc_req_prot/cache/qos/lock` | 输出，3/4/4/1 | 原地址属性；MC 决定其处理策略 |
| `mc_req_auser` / `mc_req_wuser` | 输出，各 16 | AW/AR USER、本拍 WUSER；读命令 WUSER=0 |
| `mc_req_wdata` / `mc_req_wstrb` | 输出，D/W | 原 AXI 完整数据 lane 和选通；读命令均为 0 |

```text
N = AxLEN + 1
s = 2^AxSIZE
mc_req_addr(k) = AxADDR + k*s       k=0…N-1
lane(k) = mc_req_addr(k) mod W
```

本拍第 j 个有效字节 `j=0…s-1` 位于 `wdata[8*(lane+j)+:8]`；只在 `wstrb[lane+j]=1` 时更新 `memory[mc_req_addr+j]`。MC 负责拒绝访问范围之外的 WSTRB 或不支持的 LOCK/属性，桥不将越界选通静默截断。读数据按相同 lane 放回，未访问 lane 本接口约定为 0。

例如，D=256、地址 `0x1004`、SIZE=2 的一拍覆盖 `0x1004…0x1007`，有效数据在 lane4…7，即 `[63:32]`，不是统一搬到低 32 位。若 MC 只接收对齐 64B/128B 块，应另加尺寸适配器，拆分/合并并保存 tag、掩码及错误状态。

### 5.2 完成通道

| 信号 | 方向/位宽 | 含义 |
|---|---|---|
| `mc_rsp_valid` / `mc_rsp_ready` | 输入/输出，各 1 | 完成交付握手；等待时 MC 必须保持响应 |
| `mc_rsp_tag` | 输入，TAG_WIDTH | 关联一条已接受、尚未完成的命令 |
| `mc_rsp_rdata` | 输入，D | 读返回数据；写响应不使用，可置 0 |
| `mc_rsp_resp` | 输入，2 | AXI RESP 编码：00 OKAY、01 EXOKAY、10 SLVERR、11 DECERR |

每条命令必须恰好返回一次，包括每拍写、全零选通写和错误命令。最早在命令接受后的下一周期交付响应，不支持同周期零延迟回环。允许不同 tag 乱序完成，不允许未知 tag、重复 tag 或已经退休的旧 tag 返回。

MC 响应“完成”必须符合系统所需的可见性规则，不能仅表示进入了 MC 请求队列。对地址冲突和顺序要求，MC 必须保证正确执行次序；Target 的响应排序不能修复已执行错序的存储副作用。

Target 用固定 `MC_SLOTS` 个 ROB 槽保存 ID、RP、USER、读写/末拍标志、状态和数据，按命令发出顺序退休：读每拍产生 RDATA；写每拍状态聚合，只有原 burst 最后一拍退休才产生一个 WRESP/B。状态取数值最大值，保证 SLVERR/DECERR 不被后续成功覆盖；MC 必须自行保证 EXOKAY/独占语义合法。BUSER/RUSER 返回原 AWUSER/ARUSER。

ROB 为全局按序退休，可能产生队头阻塞；这是本版明确的简化。MC 执行并发不等于 AXI 响应完全自由乱序。下游永久不响应/主机永久不接收时没有有限延迟保证，也没有内部 watchdog 替外设判超时。

## 6. 消息、credit 与容量

线上协议沿用 [wire_contract.md](../systemc/doc/wire_contract.md)：WREQ/RREQ=15B，WRESP=5B；RDATA、WDATA、WDATAFULL 按位宽定长，以 5B granule 计费。消息 byte0 位于向量最高字节，AXI lane0 位于数据向量最低字节，两个约定不要混淆。

TX 每周期最多选择一条新消息，也可同时放入前条消息的跨帧尾片；RX 每周期最多提交一条完整消息。只有新消息设置 MsgStart；续片不重复设置。满帧立即提交，部分帧在没有新消息追加的周期提交，输出背压时保持整帧。

每个 RP/类型分别维护：远端授予的可发 credit、本端待归还 credit、本端已宣布且尚未接收的 credit。每条新消息按完整长度扣一次 credit，跨帧续片不再扣。接收 FIFO 真正被消费者取走才归还 credit：SoC 是 AXI R/B 握手，Target 是 MC 命令握手（请求头在末条子命令发出时释放）。

```text
available_next = available + 收到的授信 - 本周期新消息消耗
pending_next   = pending   + 消费者释放 - 本周期编码授信
promised_next  = promised  + 本周期编码授信 - 本周期接收完整消息
```

本版 FIFO 存整消息，DEPTH 的单位是条数；credit 的单位是 granule，不是 FIFO slot。接收容量保守公布为 `DEPTH × 同类型最短消息 granule数`，特别是 WDATA 与 WDATAFULL 共用一类 credit。例如 D=256、WDATA_DEPTH=32，初始 WDATA credit=32×7=224，而非 32 或 32×8；全掩码消息每条消耗 8，避免更短消息造成条数溢出。

公共 FIFO 的 `FWFT` 参数默认为 0，桥内所有 FIFO 例化均显式选用此模式。设为 1 时，空队列上游 `s_valid` 可组合产生 `m_valid`，`m_data` 同拍取 `s_data`；若下游同时 `m_ready`，该数据直接穿过 FIFO，`level` 与读写指针不变。若下游背压，数据在时钟沿写入存储，之后从队首保持输出。该模式引入从输入到输出的组合路径，集成时需检查 ready/valid 路径和时序。

初始容量及释放量通过 PH 返回，可单独发送无消息的 credit 帧，不依赖反向业务。RX 还识别 Misc/CrdtGrant；TX 当前只生成 PH 授信。不实现 Activation 握手，由顶层 `link_up` 约定双方已就绪；实际链路接入必须核对对端启动协议。

错误检查包括 PH 保留位、未知类型/DLENGTH、消息起点重叠、本地位宽/角色不匹配、请求属性、credit 下溢/超过 12 位范围等。计数越界置错，不做静默饱和。空 granule 的内容可以任意，不要求整帧未标记区域全零；接收端也不对所有消息尾部填充作严格零检查。当前不是面向恶意对端的完整协议防火墙。

## 7. 参数、资源与扩展顺序

| 顶层参数 | 默认/合法范围 | 影响 |
|---|---|---|
| `DATA_WIDTH` | 256；256/512/1024 | AXI/MC 数据与选通宽度，线上 DLENGTH；两端必须一致 |
| `RP_COUNT` | 1；1～4 | RP 队列/credit/仲裁状态；两端应一致 |
| SoC `TX_DEPTH` | 8；正整数 | 每 RP 的 WREQ/RREQ/WDATA 队列；AW/W 路由队列深度=TX_DEPTH×RP_COUNT |
| SoC `RX_DEPTH` | 32；正整数且满足 credit 范围 | 每 RP 的 RDATA/WRESP 接收队列 |
| Target `REQUEST_DEPTH` | 4 | 每 RP 的 WREQ/RREQ 接收队列 |
| Target `WDATA_DEPTH` | 32 | 每 RP 写数据接收队列 |
| Target `RESPONSE_DEPTH` | 8 | 每 RP 的 RDATA/WRESP 发送队列 |
| Target `MC_SLOTS` | 16；1～256 | 同时未退休的 MC 命令上限，包括提前完成但仍等待的命令 |
| Target `TAG_WIDTH` | max(1,ceil(log2(MC_SLOTS))) | 标签位宽，必须容纳 MC_SLOTS |

每类公布容量不得超过 4095 granule。ADDR=64、ID=10、USER=16 是线上协议字段，不应只改端口宽度而不改格式。SoC 每个 ID 的读/写在途计数为 16 位，达到 65535 时背压；实际并发通常先受有限队列、credit 和 ROB 限制。

这版优先实现明确可检查的 RTL 边界：所有消息 FIFO 统一使用最大 1200 位槽位，ID 表使用固定数组，组合编解码和动态切片还未做面积/时序优化。Lint 和时钟仿真不证明 RAM 推断、综合 Fmax、PPA 或 28nm 后仿通过。

后续建议依次进行：

1. 与 MC 开发者确认第 5 节，若 MC 粒度不同，新增独立尺寸/完成适配模块。
2. 用真实 MC 替换 TB 后端，保留 AXI、线上字节和 MC 三层记分板。
3. 包装 250B 接口接入 UCIe 链路，补训练、重放、链路速率与 credit 往返测试。
4. 依据综合与吞吐证据优化 RX 流水、消息槽宽、ROB 退休及缓冲预算，再按需要加入 QoS 模式和超时防饿死。

运行方法、覆盖和本次结果见 [RTL 协议桥验证说明](RTL协议桥验证说明.md)。

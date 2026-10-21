# aou_transport 接口与时序

源文件：`aou_transport.sv`；端口/协议字段沿用 [完整设计说明](../doc/RTL协议桥设计与接口说明.md)。单时钟，`rst_n` 异步低有效；`link_up` 使能收发，`fault` 为锁存错误汇总。

| 接口组 | 方向 | 契约 |
|---|---|---|
| clk、rst_n、link_up | 输入 | 时钟、复位、链路使能 |
| tx_valid、tx_data / tx_ready | 输入 / 输出 | RP × 5 类消息，1200 位消息，实际握手按整条消息扣 credit |
| rx_valid、rx_data / rx_ready | 输出 / 输入 | RP × 5 类 FIFO，实际出队才释放消息 credit |
| flit_tx_valid、flit_tx_data / flit_tx_ready | 输出 / 输入 | 250B 发送帧握手 |
| flit_rx_valid、flit_rx_data / flit_rx_ready | 输入 / 输出 | 250B 接收帧握手 |
| fault | 输出 | 本地合法性/容量错误或 RX 错误，复位清除 |

参数：`DATA_WIDTH` 为 256/512/1024，`RP_COUNT` 为 1～4；`RX_DEPTH0`～`RX_DEPTH4` 分别为 WREQ/RREQ/WDATA/RDATA/WRESP 的消息条数，零表示不接收该类。每类初始容量为 `depth × min_granules`，上限 4095 个 5B 粒度。

本次改变：PH 授信计算从消息路由组合块中分离，消息 `raw_ready` 只依赖消息合法性及目标 FIFO。PH 与 Misc 授信在独立组合块相加；寄存器在下一沿更新，TX 下一周期才能使用新增 credit。避免接收 FIFO 满时同拍出队路径通过 PH 又回到消息 ready。

```text
E0：外部 Flit 握手，产生一次 PH 事件
E0 沿后：available 加上 PH 授信
E1：TX 可以使用新 available；FIFO 内的帧被解析
消息输出后：经 raw_valid && raw_ready 入对应类型 FIFO
业务消费者握手后：pending 增加整条消息粒度数，等待反向授信
```

```json
{"signal":[{"name":"clk","wave":"p...."},{"name":"ph_valid","wave":"010.."},{"name":"available","wave":"=.=..","data":["old","old + grant"]},{"name":"tx_uses_new_credit","wave":"0.10."}]}
```

帧预取不增加公布的消息容量；不能在帧出队时重复处理 PH。每条跨帧消息仍只产生一次消息接收和一次消费者释放。RX 的两个帧槽位及消息 REG 用于流水，不替代消息 FIFO 的 credit 容量。

验证为独立线上 credit 账本、重复授信负向测试、读写闭环、跨帧、停顿恢复及联合复位。WaveJSON 为手工契约描述，自动生成/渲染门禁受当前技能 Python 运行环境阻断。

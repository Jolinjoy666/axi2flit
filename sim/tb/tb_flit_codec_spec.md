# tb_flit_codec 验证契约

单时钟，异步低有效 `rst_n`；`FRAME_DEPTH >= 2`。DUT 为真实 `aou_flit_tx` 和 `aou_flit_rx`，两者由 C++ 分别驱动，没有互连作为唯一期望。

| 端口 | 说明 |
|---|---|
| clk、rst_n | 时钟和联合复位 |
| tx_valid、tx_ready、tx_message | TX 消息输入握手，1200 位 |
| tx_flit_valid、tx_flit_ready、tx_flit | TX 输出握手，2000 位 |
| tx_debit | 8 位本拍整消息 credit 扣减量 |
| rx_flit_valid、rx_flit_ready、rx_flit | RX 输入握手，2000 位 |
| rx_valid、rx_ready、rx_message | RX 输出握手，1200 位 |
| rx_header_valid、rx_header_credit、rx_fault | PH 事件、16 位授信字段、错误 |

每类输入 96 条消息，独立参考程序按 5B 粒度装满 240B 消息区。TX 按整帧字节与参考比较，RX 直接接收参考帧并按整条消息比较。六类为 WREQ、RREQ、WDATAFULL、RDATA、WRESP、掩码 WDATA。

无背压时，TX 首末消息接受区间和 RX 首末消息交付区间必须均为 96 周期；流水线填充时间不计入该稳态区间。背压用例保持全部字节、顺序、PH 次数和整消息 credit 扣减检查。

```json
{"signal":[{"name":"clk","wave":"p....."},{"name":"tx_valid","wave":"01...."},{"name":"tx_ready","wave":"1....."},{"name":"rx_valid","wave":"0..1.."},{"name":"rx_ready","wave":"1....."},{"name":"rx_message","wave":"x..===","data":["M0","M1 spanning","M2"]}]}
```

另测第二帧延迟到达、跨帧起点冲突、半条消息时复位。`make -C sim codec-all` 覆盖 256/512/1024 位及深度 2、1024 位深度 3。该 TB 不证明布局布线频率；WaveJSON 未执行外部渲染。

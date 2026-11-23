# tb_rtl_bridge 验证契约

AXI、HIF 和 Flit 端口语义见设计文档第 2 章（[doc/设计文档](../../doc/设计文档/)）。所有业务端口由同一 `clk` 驱动；`rst_n` 异步低有效。两端 DUT、链路队列、软件内存、期望队列必须联合复位。

| 接口组 | 作用 |
|---|---|
| clk、rst_n、link_up | 时钟、联合复位、链路启用 |
| s_axi_aw*、s_axi_w*、s_axi_ar*、s_axi_b*、s_axi_r* | SoC 的五个 AXI 通道，完整属性/数据保持原接口 |
| mc_req_*、mc_rsp_* | Target 逐拍命令和带 tag 的完成，tag 宽度按 MC_SLOTS 推导 |
| forward_enable、reverse_enable | 允许新帧进入相应链路队列 |
| forward_deliver、reverse_deliver | 队首帧完整传输并到达后允许交付；已接受数据不撤销 |
| fwd_*、rev_*、soc_rx_*、target_rx_* | 两个方向发送/到达观察点，均观察真实握手 |
| inject_valid、inject_soc、inject_data、inject_ready | 异常注入选择 SoC 或 Target 输入 |
| soc_error、target_error | 对应端错误状态 |
| perf_stall[13:0]、perf_rob_level[15:0] | 非侵入观察信号，不参与 DUT 控制 |

参数包含 `DATA_WIDTH`、`RP_COUNT`、`LINK_DEPTH`、`RX_DEPTH`、`REQUEST_DEPTH`、`WDATA_DEPTH`、`RESPONSE_DEPTH`、`MC_SLOTS`、推导的 `TAG_WIDTH`。默认消息容量沿用 RTL，链路队列默认 64 帧以容纳可配物理延迟；可设置 LINK_DEPTH=2 重现原基线。

`baseline/saturated/ideal/physical/backpressure` 由 C++ 选择；MC 延迟与发起间隔分别可配。默认每拍可接收一个请求及返回一个响应，响应最早下一周期。FIFO 和 ROB 的有限容量始终有效。

```json
{"signal":[{"name":"clk","wave":"p......"},{"name":"fwd_fire","wave":"010...."},{"name":"forward_deliver","wave":"0...1.."},{"name":"target_rx_fire","wave":"0...10."},{"name":"mc_req_fire","wave":"0.....1"}]}
```

物理场景的队首交付时间不得早于序列化结束加 PHY/传播/CDC/额外 adapter 延迟；最多提前一个 RTL 周期将帧排入串行器，物理发送时间不早于接收时间。交付取整到 2ns 时钟沿，附加量化延迟小于一周期。该图仅示意顺序，实际延迟由配置与 DUT 周期共同决定，未通过外部波形渲染门禁。

守恒检查覆盖每条 AXI/MC 消息、逐字节数据、独立内存、credit 和排空；SVA 检查输入 AW/W/AR、输出 R/B、Flit、MC 请求的背压稳定性。达到带宽门限通过 `--min-efficiency` 显式启用，失败返回非零。

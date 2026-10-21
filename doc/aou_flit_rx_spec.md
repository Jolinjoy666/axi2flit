# aou_flit_rx 接口与时序

源文件：`aou_flit_rx.sv`。单时钟 SystemVerilog；`rst_n` 异步低有效复位。

| 接口 | 方向/宽度 | 含义 |
|---|---|---|
| clk、rst_n、enable | 输入/各 1 位 | 时钟、复位、解析及输入使能 |
| flit_valid、flit_ready、flit_data | 输入、输出、输入/1、1、2000 位 | 250B PH+消息区输入，valid && ready 接收 |
| msg_valid、msg_ready、msg_data | 输出、输入、输出/1、1、1200 位 | 完整消息输出，未使用尾部置零 |
| header_valid、header_credit | 输出/1、16 位 | 合法 PH 在外部输入握手周期产生一次授信事件 |
| fault | 输出/1 位 | 错误锁存，复位才能清除 |

`FRAME_DEPTH` 默认 2，必须至少为 2，支持非二次幂深度。每帧 48 个 5B 粒度，最大消息 30 个粒度，任何合法消息最多跨两帧。

数据通路：双读视图帧 FIFO → 起点搜索 → 前两帧拼接 MUX → 消息 REG。FIFO 两槽时为乒乓结构；深度增大时按显式指针回绕。存储数据无需复位，指针、计数、cursor、输出 valid、fault 复位清零。

输入第一个帧在 E0 握手，E1 处理完整消息并写输出寄存器，E2 可被下游握手。若所需两帧已经就绪，稳态每周期提取并交付一条消息，跨帧无额外片段周期。只有前半帧到达时保持 cursor 和 FIFO，直到后半帧到齐。

```text
上升沿             E0       E1       E2       E3
输入握手           F0       F1       …        …
解析处理            -       M0       M1跨帧   M2
输出握手            -        -       M0       M1
```

对应 WaveJSON 描述（未通过外部渲染器生成 SVG）：

```json
{"signal":[{"name":"clk","wave":"p...."},{"name":"input_fire","wave":"011.."},{"name":"input_frame","wave":"x==..","data":["F0","F1"]},{"name":"output_valid","wave":"0..1."},{"name":"output_message","wave":"x..==","data":["M0","M1 spanning"]}]}
```

边界契约：

- 满时允许帧末出队与新帧入队同拍发生；读组合逻辑看到旧帧，沿后才覆盖存储。
- 完整消息跨帧时，旧帧出队，cursor 指向新队首内已经消费的位置。
- 输出背压保持 valid 和整条消息；解析暂停，FIFO 剩余槽位仍可收帧。
- 无新消息起点的帧可消耗一个扫描周期；空/部分帧流不承诺每拍一条消息。
- 非法 PH 不进入 FIFO并置错；非法长度、消息内部重复起点（含下一帧第零粒度）不输出错误消息。
- `enable=0` 停止接收和解析。已经提交的消息仍按 ready/valid 完成握手，沿用原契约。
- fault 为 fail-stop；不支持单端复位后继续处理旧事务，系统必须联合取消在途数据。

验证：`make -C sim codec-all` 验证三位宽、六类消息、背压、深度 2/3、跨帧延后到达、重叠起点、半消息复位、PH 只记一次；端到端 `make -C sim check` 验证 credit 与业务语义。优先保证周期吞吐；宽 MUX 的实际时序需要综合确认。

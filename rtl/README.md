# 转接桥 RTL

两个顶层：

- `axi2flit_soc`：SoC 侧，AXI4 从机 ⇄ 250B Flit（接 D2D Adapter 的 FDI）。
- `flit2hif_target`：存储侧，250B Flit ⇄ MC 的 HIF 主机接口（接存储控制器 MC）。

例化层次：

```
axi2flit_soc
└── aou_transport ── aou_flit_tx、aou_flit_rx、aou_sync_fifo / aou_chunk_fifo（接收缓冲）
flit2hif_target
└── aou_target_core ── aou_transport（同上）、aou_sync_fifo（响应发送队列）
aou_pkg：协议常量、消息格式与编解码函数，各模块 import
```

编译顺序：`aou_pkg.sv` → `aou_sync_fifo.sv`、`aou_chunk_fifo.sv`、`aou_flit_tx.sv`、`aou_flit_rx.sv` →
`aou_transport.sv` → `aou_target_core.sv` → `axi2flit_soc.sv`、`flit2hif_target.sv`。文件表维护在 [sim/Makefile](../sim/Makefile) 的 `RTL` 变量。

约定：可配置项（数据位宽、RP 数、各级深度、HIF 控制器配置等）是模块 `parameter`；AoU 线上格式固定的量是
`aou_pkg` 的 `localparam`，两端必须一致。参数越界的 `$fatal` 只用于仿真，综合时定义 `SYNTHESIS`。

设计说明见 [doc/设计文档](../doc/设计文档/)。仿真模型（HIF 控制器模型、满速 MC 模型）在 `sim/model/`，不属于交付 RTL。

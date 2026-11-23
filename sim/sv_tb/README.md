# SV 定向测试平台

激励、检查与用例全部用 SystemVerilog 编写，用 VCS 仿真、Verdi 看波形。用于日常调试与功能演示；
大量配置回归、异常注入与链路消息逐字节对拍仍由 `sim/tb/` 下的 C++ 环境完成（`make -C sim check`）。

```
AXI 主机任务 ──AXI──► axi2flit_soc ──► 链路 FIFO ──► flit2hif_target ──HIF──► hif_mc_model
（axi_tasks.svh）◄─R/B─            ◄── 链路 FIFO ◄──                ◄──     （HIF 控制器模型）
```

## 运行

```bash
make -C sim sv-vcs  WIDTH=256                     # 编译并运行全部用例，结果存入 sim/results/sv_tb_256_all.log
make -C sim sv-vcs  WIDTH=256 TEST=tc_narrow      # 只运行一个用例
make -C sim sv-verdi WIDTH=256                    # 用 Verdi 打开最近一次的波形（源码与波形联动）
make -C sim sv-vcs  WIDTH=1024 HIF_DRAM_W=128     # 其他配置：AXI 位宽、MC 配置（HIF_RATIO / HIF_BL / HIF_LATENCY）
make -C sim sv-vcs  TEST=tc_single SV_ARGS=+CORRUPT   # 记分板自检：故意改错一个期望字节，必须报错
```

检查分三处：每拍 R 数据与 B 响应在线核对；每个用例结束后，用后门把控制器模型的整个存储与参考存储逐字节比对
（`check_mem`，只写不读的用例也会检查数据）；任何时刻两端 `protocol_error` 或控制器模型的 HIF 违规都记为失败。

结束时打印 `SV TB PASS` 即通过；出错时每处打印一行“错误：……”，最后为 `SV TB FAIL  N 处错误`，make 返回非零。

## 文件

| 文件 | 内容 | 什么时候改 |
|---|---|---|
| `tb_top.sv` | 参数、时钟复位、待测设计连线、背压开关、错误监视、用例调度 | 改连线、加观察信号、改地址窗口 |
| `axi_tasks.svh` | AXI 主机任务（`send_aw` / `send_w` / `send_ar` / `axi_write` / `axi_read` / `wait_done`）与记分板（含存储后门检查 `check_mem`） | 改激励方式或检查方法 |
| `tests.svh` | 测试用例，每个一个 task，开头注释写明测什么、怎么测、波形里看什么 | **新增或修改用例** |

## 写一个新用例

1. 在 `tests.svh` 中仿照已有用例写一个 task：

   ```systemverilog
   task automatic tc_my_case();
       txn_t t = make_txn(P(0), 8, 4, 77);    // 地址、拍数、SIZE（每拍 2^SIZE 字节）、ID
       t.strb = STRB_PART;                    // 可选：部分选通（STRB_FULL / STRB_PART / STRB_ZERO）
       axi_write(t);                          // 写并等 B，自动核对 BRESP
       axi_read(t);                           // 读并等 RLAST，每拍数据自动与参考存储比对
   endtask
   ```
2. 把 `"tc_my_case"` 加到 `ALL_TESTS`，并在 `run_case` 的 case 语句中加一行。
3. `make -C sim sv-vcs TEST=tc_my_case`。

常用的开关（在用例里直接赋值）：`r_hold` / `b_hold`（主机不收 R / B）、`rand_ready`（随机背压）、
`link_stop`（链路暂停）、`mc_block`（控制器停顿）、`mc_stress`（控制器乱序、交织返回）。
多笔并发的写法见 `tc_outstanding`：用 `fork ... join` 同时调用 `send_aw`、`send_w`、`send_ar`，再逐笔 `wait_done`。

## 约定与注意

- 地址：每个用例使用自己的 4KB 页 `P(n)`；控制器容量 `MEM_BYTES` 默认 64KB。`[MEM_BYTES, 2×MEM_BYTES)` 由控制器报地址错误，
  `2×MEM_BYTES` 以上在桥的窗口外，两者都期望 DECERR（`make_txn` 按地址自动算出期望响应）。
- 突发必须合法：地址按 2^SIZE 对齐、不跨 4KB、SIZE 不超过总线宽度。
- 链路用两个 FIFO 代替，不限带宽；`tc_throughput` 测到的是桥与 HIF 的上限，含真实链路的带宽见全链路环境（`make -C sim fl`）。
- 并发访问同一地址时参考存储按 W 握手顺序更新，用例应避免读与未完成的写落在同一地址。
- 存储后门检查要求控制器模型的存储与桥地址一一对应（`ADDR_BASE = 0`，地址 a 即 `u_mc.mem[a]`）；改地址窗口时一并修改 `check_mem`。

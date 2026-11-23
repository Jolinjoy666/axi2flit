# HIF 控制器行为模型 `hif_mc_model.sv`

用来在仿真中代替存储控制器（MC），接在桥 `flit2hif_target` 的 HIF 口上。**只用于仿真，不可综合，不属于交付 RTL。**
它只模拟主机能看到的接口行为（命令接收、写指针回送、读数据返回、credit 归还、stall），并在每一拍检查桥是否违反 HIF 约定。
不模拟 DRAM 时序、调度、刷新等控制器内部行为。

三套仿真环境都使用它：`sim/sv_tb/tb_top.sv`（SV 平台）、`sim/tb/tb_rtl_bridge.sv`（C++ 独立环境）、`sim/tb/fl_rtl_top.sv`（全链路）。

## 1. 参数

| 参数 | 默认 | 含义 |
|---|---|---|
| `CORE_DATA_WIDTH` | 256 | HIF 数据宽度（= DRAM 位宽 × 频率比 × 2） |
| `LINE_WORDS` | 2 | 一条命令（一行，即一个 DRAM burst）的数据拍数 |
| `WORD_BYTES` | 4 | `hif_cmd_addr` 的地址单位（DRAM 数据宽度 / 8），字节地址 = addr × WORD_BYTES |
| `LPR_CREDITS` / `HPR_CREDITS` / `WR_CREDITS` | 24 / 8 / 32 | 三个命令队列的深度，即桥侧 credit 初值（两边必须一致） |
| `HIF_CREDIT_BITS` | 1 | lpr/hpr credit 位宽，Inline ECC 时为 2（每拍最多还 2 个） |
| `VPRW_EN` | 0 | 1 时 `hif_cmd_pri == 2'b10` 表示 HPR，否则 `pri[0]` 为 1 表示 HPR |
| `LATENCY` | 8 | 读延迟（周期）；写 credit 在写数据收完后 `LATENCY/2` 周期归还 |
| `MEM_BYTES` | 128KB | 存储容量；超出的行读写都报地址错误 |
| `POISON_LINE` | -1 | 该字节偏移所在的行读出时报不可纠正 ECC 错误；-1 表示不用 |
| 其余位宽 | 同 MC | `CORE_ADDR_WIDTH` 40、`CORE_TAG_WIDTH` 53、`WDATA_PTR_BITS` 19 等，与桥的同名参数一致 |

## 2. 测试平台控制与统计（不属于 HIF）

| 端口 | 作用 |
|---|---|
| `block` | 1：完全停顿，`hif_cmd_stall` / `hif_wdata_stall` 恒为 1，不回送指针、不返回读数据 |
| `stress` | 1：压力模式，见第 4 节 |
| `inject_bad_token` | 1：返回一个非法 token 的读数据，用于检查桥能否发现（负向测试） |
| `model_error` | 发现桥违反 HIF 约定时置 1 并打印 `HIF MODEL ERROR @周期: 原因`，保持到复位 |
| `stat_rd` / `stat_wr` | 已接收的读 / 写命令数 |
| `stat_ooo` | 乱序次数：一条读开始返回时，若还有更早接收的读没开始返回，计 1 次 |
| `stat_interleave` | 交织次数：读数据从一个 token 切到另一个 token、而前一个还没返回完时计 1 次 |
| `stat_stall` | `hif_cmd_valid && hif_cmd_stall` 的周期数 |

## 3. 接口行为（正常模式）

所有输出都在时钟上升沿更新（寄存器输出）。下表中“第 N 个周期”从命令被接收的那个上升沿算起。

| 通道 | 模型行为 |
|---|---|
| 命令 | `valid && !stall` 时接收。读进 LPR 或 HPR 队列，写和 RMW 进写队列（RMW 另占一个 LPR）。`hif_cmd_stall` 只在 `block`（或压力模式随机）时为 1 |
| 写指针 | 按**命令顺序**回送，接收后第 2 个周期起可以回送，每个周期最多一个。`hif_wdata_ptr_addr_err` = 该行超出 `MEM_BYTES` |
| 写数据 | 按**指针回送的顺序**接收，每行 `LINE_WORDS` 拍，末拍 `end=1`。按 `hif_wdata_mask`（1 = 写入）写入存储；有地址错误的行不写入。`hif_wdata_stall` 平时为 0 |
| 读数据 | 先等所有**更早接收的写**的数据都到齐（保证同址先写后读），再过 `LATENCY` 个周期开始返回。正常模式下按接收顺序一次返回一条命令，连续 `LINE_WORDS` 拍，末拍 `end=1`，`token` 为命令带来的值 |
| 读错误 | 超出 `MEM_BYTES` 的行：`hif_rdata_addr_err=1`、数据为 0；`POISON_LINE` 所在行：`hif_rdata_uncorr_ecc_err=1`、数据为 0；`crc_err` 恒为 0 |
| 读 credit | 一条读**开始返回数据**时归还 1 个 LPR 或 HPR，每周期最多还 `HIF_CREDIT_BITS` 个，多的排队 |
| 写 credit | 一行写数据收完后 `LATENCY/2` 个周期归还 1 个 WR，每周期最多 1 个 |
| 不使用的信号 | `hif_cmd_autopre`、`hif_cmd_latency`、`hif_go2critical_*` 忽略；`hif_wrecc_credit` 恒为 0 |

实测例子（256 位 HIF、一行 64B = 2 拍、`LATENCY=8`，周期 2ns，SV 平台 `tc_single`）：

```
写：命令被接收 ── 2 周期 ──► 回送 ptr ── 下一周期 ──► 桥送出 2 拍写数据 ── 约 4 周期 ──► wr_credit 脉冲
读：命令被接收 ── 8 周期 ──► 第 1 拍读数据（同时 lpr_credit 脉冲）──► 第 2 拍（end=1）
```

## 4. 压力模式（`stress = 1`）

| 项目 | 变化 |
|---|---|
| 命令 / 写数据 stall | 每个周期约 1/4 的概率为 1 |
| 写指针 | 再随机推迟 0～15 个周期；约 1/4 的周期不回送（仍按命令顺序） |
| 读数据 | 再随机推迟 0～15 个周期；最多 2 条读同时返回，优先选**最晚**接收的（乱序），在两个 token 之间交替（交织）；约 1/4 的周期不出数据 |
| 写 credit | 再随机推迟 0～15 个周期 |

随机数由固定种子的 xorshift 产生，同一配置每次运行结果相同。

## 5. 对桥的检查（`model_error`）

命令地址不是行首；读命令 `hif_cmd_length != 0`；超过 credit 发命令（LPR / HPR / WR，RMW 另查 LPR）；
token 在上一条读未返回完时重复使用；写指针在该行数据送完前重复使用；保留命令类型（`2'b11`）；
没有回送指针就送写数据；`hif_wdata_end` 不在第 `LINE_WORDS` 拍。

## 6. 与实际 MC 对照时需要注意的简化

模型的时序是“一种合法的 MC 行为”，**不代表对 MC 的要求**。桥能接受的范围更宽，例如指针可以乱序回送、读数据可以更早返回。与实际 MC 对齐时，建议重点核对：

| 项目 | 本模型 | 请对照实际 MC |
|---|---|---|
| stall | 寄存器输出 | 是否为组合输出（桥两种都支持） |
| 写指针回送顺序 | 总是按命令顺序 | 是否会乱序（桥支持，但本模型没有覆盖到） |
| 指针回送时机 | 命令接收后第 2 个周期起 | 桥要求不早于命令被接收后的下一周期 |
| 指针 → 写数据 | 桥在指针后的下一周期送数据，模型对间隔没有要求 | MC 对这段间隔有没有固定值或上限 |
| 读延迟 | 固定 `LATENCY`（压力模式另加随机） | 实际延迟范围；桥只要求读数据不早于命令被接收后的下一周期 |
| 读数据 | 没有反压 | 一致（HIF 读数据没有 ready） |
| credit 归还时机 | 读：开始返回时；写：数据收完后 `LATENCY/2` | 实际归还时机（桥只要求总数不超过初值） |
| HPR | 只区分队列和 credit，不优先调度 | 实际调度策略（不影响桥的正确性） |
| RMW | 当作带掩码的写，不真正读改写 | ECC 打开时的实际行为 |
| 存储 | 字节数组，复位时清零 | — |

如果实际 MC 的行为和上表不同，可以修改本模型（主要改第 3、4 节对应的代码段：写指针回送、读数据返回、credit 脉冲、stall），
再运行 `make -C sim check`、`make -C sim -f Makefile.verilator run` 等回归，确认桥在新行为下仍然正确。

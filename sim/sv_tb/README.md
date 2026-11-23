# SV 定向测试平台

激励、检查与用例全部用 SystemVerilog 编写，**VCS 与 Verilator 都可以运行**，结果一致。

```
AXI 主机（axi_tasks.svh）──AXI──► axi2flit_soc ──► 链路 FIFO ──► flit2hif_target ──HIF──► hif_mc_model
                        ◄─R/B──               ◄── 链路 FIFO ◄──                 ◄──      （HIF 控制器模型）
```

| 文件              | 内容                                                                                  |
| ----------------- | ------------------------------------------------------------------------------------- |
| `tb_top.sv`     | 参数、时钟复位、待测设计连线、停顿开关、错误监视、用例调度、波形输出                  |
| `axi_tasks.svh` | AXI 主机：发送队列与驱动器、`wait_done`、记分板（参考存储、R/B 核对、存储后门检查） |
| `tests.svh`     | 15 个用例，每个一个 task。**新增或修改激励只改这个文件**                        |

## 1. 运行

在工程根目录执行。

| 目的                   | VCS                                                    | Verilator                                                              |
| ---------------------- | ------------------------------------------------------ | ---------------------------------------------------------------------- |
| 运行全部用例           | `make -C sim sv-vcs WIDTH=256`                       | `make -C sim -f Makefile.verilator run WIDTH=256`                    |
| 只运行一个用例         | `make -C sim sv-vcs TEST=tc_narrow`                  | `make -C sim -f Makefile.verilator run TEST=tc_narrow`               |
| 生成波形               | 每次都生成 FSDB                                        | 加 `WAVE=1`，生成 VCD                                                |
| 打开波形               | `make -C sim sv-verdi WIDTH=256`                     | `make -C sim -f Makefile.verilator verdi TEST=tc_single`             |
| 记分板自检（必须报错） | `make -C sim sv-vcs TEST=tc_single SV_ARGS=+CORRUPT` | `make -C sim -f Makefile.verilator run TEST=tc_single ARGS=+CORRUPT` |

两种方式都能在命令行上改配置：`WIDTH`（AXI 位宽 256/512/1024）、`HIF_DRAM_W` / `HIF_RATIO` / `HIF_BL`（控制器配置，决定 HIF 宽度与行大小）、`HIF_LATENCY`（控制器读延迟）、`SEED`（tc_random 的随机种子）。例如：

```bash
make -C sim -f Makefile.verilator run WIDTH=1024 HIF_DRAM_W=128 HIF_LATENCY=20
```

**判定**：末行为 `SV TB PASS` 即通过；出错时每处打印一行“错误：……”，末行为 `SV TB FAIL  N 处错误`，make 返回非零。
日志在 `sim/results/`。Verilator 需要 5.x（已在 5.052 上验证）和支持 C++20 的编译器（GCC 10 或更新）；每种配置首次运行时先编译，需要几十秒到一两分钟。

## 2. 编写激励

### 常用接口（`axi_tasks.svh`）

```systemverilog
txn_t t = make_txn(地址, 拍数, SIZE, ID);  // 一笔突发；期望的 BRESP/RRESP 按地址自动算出
t.strb = STRB_PART;                         // 可选：STRB_FULL 全选通 / STRB_PART 部分 / STRB_ZERO 全零
t.qos  = 3;                                 // 可选
axi_write(t);                               // 写：发 AW 和全部 W，等 B 并核对（阻塞）
axi_read(t);                                // 读：发 AR，等 RLAST；每拍数据自动核对（阻塞）

send_aw(t); send_w(t); send_ar(t);          // 只放入发送队列、立即返回，用于多笔并发
wait_done(t);                               // 等这一笔完成（默认 20000 周期超时）
```

数据与检查都是自动的：写数据由地址和种子生成；W 握手时更新参考存储；每个 R 拍逐字节核对；
每个用例结束后用后门把控制器模型的整个存储与参考存储比对；任何时刻 `protocol_error` 或 HIF 违规即失败。

### 停顿开关（在用例中直接赋值）

`r_hold` / `b_hold`（主机不收 R / B）、`rand_ready`（R、B 随机背压）、`link_stop`（链路暂停）、
`mc_block`（控制器停顿，hif_cmd_stall = 1）、`mc_stress`（控制器乱序、交织返回并随机 stall）。

### 新增一个用例

```systemverilog
// 1. 在 tests.svh 中写一个 task
task automatic tc_my_case();
    txn_t w [4];
    txn_t t = make_txn(P(0), 2, FULL, 77);   // P(n) = 第 n 个 4KB 页；FULL = 全宽 SIZE
    t.strb = STRB_PART;
    axi_write(t);
    mc_block = 1;                             // 控制器停顿 50 拍后恢复
    fork
        axi_read(t);
        begin repeat (50) @(posedge clk); mc_block = 0; end
    join
    for (int i = 0; i < 4; i++) w[i] = make_txn(P(0) + 1024 + i * 512, 4, FULL, 80 + i);
    for (int i = 0; i < 4; i++) begin send_aw(w[i]); send_w(w[i]); end   // 4 笔写并发
    for (int i = 0; i < 4; i++) wait_done(w[i]);
endtask
// 2. 把 "tc_my_case" 加到 ALL_TESTS；3. 在 run_case 中加一行 "tc_my_case": tc_my_case();
```

然后 `make -C sim -f Makefile.verilator run TEST=tc_my_case`（或 `sv-vcs`）单独运行。

### 注意

- 突发必须合法：地址按 2^SIZE 对齐、不跨 4KB、SIZE 不超过总线宽度。拍数尽量用 `FULL`、`BYTES` 表示，三种位宽都能用。
- 地址：控制器容量 64KB（16 页），每个用例用自己的页（P0 目前未使用）；`[64KB, 128KB)` 期望控制器报错、
  `128KB` 以上在桥的窗口外，两者都期望 DECERR，`make_txn` 会自动算出。
- 并发写时 `send_w` 的调用顺序必须与 `send_aw` 一致（AXI 规定写数据按写地址顺序）。
- 不要让读与尚未完成的写落在同一地址（参考存储按 W 握手更新）。

## 3. 查看波形

**VCS + Verdi**（源码与波形联动）：

```bash
make -C sim sv-vcs  WIDTH=256 TEST=tc_single     # 生成 sim/build/sv_w256_.../tb_top.fsdb
make -C sim sv-verdi WIDTH=256                   # 打开 Verdi，信号在 tb_top 下
```

**Verilator**：先加 `WAVE=1` 生成 VCD（`sim/results/sv_verilator_<配置>_<用例>.vcd`），再用 `verdi` 目标打开：

```bash
make -C sim -f Makefile.verilator run   WIDTH=256 TEST=tc_single WAVE=1   # 生成 VCD
make -C sim -f Makefile.verilator verdi WIDTH=256 TEST=tc_single          # 转 FSDB、编译设计库、打开 Verdi
```

`verdi` 目标把 VCD 转成 FSDB，并把同一套源码编译成 Verdi 设计库，因此和 VCS 流程一样可以在层次窗口、源码中选信号
（选中后 `Ctrl+W` 加入波形）。两条命令的配置变量（`WIDTH`、`TEST`、`HIF_*`）须相同。
没有 Verdi 时，VCD 可用其他支持 VCD 的波形工具打开。

注意：Verdi 打开后波形窗口一开始是空的，需要自己添加信号——在层次或源码中选中后按 `Ctrl+W`，
或在波形窗口按 `g`（`Signal → Get Signals`）选择。若直接用 `verdi -ssf xxx.fsdb` 只打开波形文件、不加载设计，
层次窗口为空，只能用 `g` 添加信号。

建议只对单个用例生成波形。常看的信号（都在 `tb_top` 下）：

| 位置     | 信号                                                                                                                                |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| AXI      | `s_axi_aw*`、`s_axi_w*`、`s_axi_ar*`、`s_axi_r*`、`s_axi_b*`                                                              |
| 链路     | `soc_tx_valid`（SoC 发帧）、`tgt_rx_valid`（存储侧收帧）、`tgt_tx_valid`、`soc_rx_valid`                                    |
| HIF 命令 | `hif_cmd_valid`、`hif_cmd_stall`、`hif_cmd_type`（00 写 / 01 读）、`hif_cmd_addr`、`hif_cmd_token`、`hif_cmd_wdata_ptr` |
| HIF 写   | `hif_wdata_ptr_valid`、`hif_wdata_ptr`、`hif_wdata_valid`、`hif_wdata_stall`、`hif_wdata_end`、`hif_wdata_mask`         |
| HIF 读   | `hif_rdata_valid`、`hif_rdata_token`、`hif_rdata_end`、`hif_rdata`                                                          |
| credit   | `hif_lpr_credit`、`hif_hpr_credit`、`hif_wr_credit`                                                                           |

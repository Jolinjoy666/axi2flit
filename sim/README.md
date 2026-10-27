# 仿真

在仓库根目录运行 `make -C sim <目标>`，`make -C sim help` 列出常用命令。

| 目录 | 内容 |
|---|---|
| `tb/` | 测试平台：独立 RTL 环境（`tb_rtl_bridge.*`）、全链路环境（`fl_rtl_top.sv`、`tb_full_link_rtl.cpp`）、单元测试 |
| `model/` | 仿真模型：`hif_mc_model.sv`（HIF 控制器模型）、`flit2mc_target.sv`（满速 MC 模型） |
| `scripts/` | VCS 端口映射生成、接收深度扫描 |
| `build/`、`results/` | 构建目录与日志 / 波形，不提交 |

存储侧由 `MC_IF` 选择：默认 `hif` 为交付设计 `flit2hif_target` 加控制器模型；`ideal` 为满速 MC 模型，
用来测量桥加链路本身的上限。

| 目标 | 内容 |
|---|---|
| `run` / `negative` | 独立环境功能（含短时吞吐）/ 异常注入 |
| `test-all` | 三位宽 × RP1/2/4 的 lint、功能、异常 |
| `hif-cfg-all` | 其他 HIF 控制器配置（DRAM 位宽、频率比、2 位 credit、RMW、极小 credit） |
| `ideal-all` | 满速 MC 模型下的吞吐与 90% 门限 |
| `check` | 以上全部 + FIFO、编解码单元测试 + 记分板自检 |
| `fl` / `fl-all` / `fl-ideal-all` | 全链路（UCIe 链路模型）：延迟分解、功能用例、满载吞吐 |
| `fl-wave`、`fl-vcs`、`fl-verdi` | 波形：Verilator + GTKWave，或 VCS + Verdi |

依赖 Verilator 5、C++17、SystemC 2.3.4（`SYSTEMC_HOME`）；全链路另需 `reference/ucie-model`，VCS 流程需 VCS 与 Verdi。

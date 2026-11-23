# RTL 仿真入口，所有构建/日志/波形放在本目录。
# Verilator 编译可综合 SV，C++ testbench 使用 SystemC 参考编解码函数作字节参考。
# 交付 RTL 在 ../rtl；仿真模型在 model/（HIF 控制器模型、满速 MC 模型），测试平台在 tb/。
VERILATOR ?= verilator
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
SYSTEMC_HOME ?= $(HOME)/.local/systemc-2.3.4-cxx17
WIDTH ?= 256
RP ?= 1
JOBS ?= 2
DEPTH ?= 3
FWFT ?= 1
LINK_DEPTH ?= 64
# 读/写数据接收深度默认随位宽取（推导见设计文档 6.1 节）：256/512 位 32/36，1024 位 24/24。
RDATA_DEPTH ?= $(if $(filter 1024,$(WIDTH)),24,32)
WRESP_DEPTH ?= 24
WDATA_DEPTH ?= $(if $(filter 1024,$(WIDTH)),24,36)
WREQ_DEPTH ?= 24
RREQ_DEPTH ?= 32
RESPONSE_DEPTH ?= 2
MC_RD_SLOTS ?= 16
MC_WR_SLOTS ?= 16
TX_DEPTH ?= 2
WR_ROUTE_DEPTH ?= 8
RD_OUTSTANDING ?= 32
WR_OUTSTANDING ?= 32
SCENARIO ?= saturated
FRAME_DEPTH ?= 2
# 链路：默认 x8 @ 24 GT/s PAM4，原始 48 GB/s，与 1024 位桥的 64 GB/s 匹配。
# LINK_BPS：2 = PAM4，1 = NRZ；LINK_LANES=16 时 PAM4 为 96 GB/s，瓶颈转到桥上。
LINK_BPS ?= 2
LINK_LANES ?= 8
LINK_DEFS := -DAOU_LINK_BITS_PER_SYMBOL=$(LINK_BPS) -DAOU_LINK_LANES=$(LINK_LANES)
ROOT := $(abspath ..)
# 存储侧：hif = flit2hif_target（交付设计，MC 的 HIF 接口，接 model/hif_mc_model.sv 控制器模型）；
#         ideal = model/flit2mc_target.sv（满速逐拍 MC 模型：读写分口、与 AXI 等宽，C++ 字节存储固定延迟响应），用于测量桥 + 链路本身的上限。
MC_IF ?= hif
# HIF 配置：DRAM 数据宽度、控制器频率比、burst 长度决定 HIF 数据宽度（DRAM×比×2）与每条命令字节数（BL×DRAM/8）；
# 读 ROB/写缓冲行数；控制器 LPR/HPR/WR credit 初值；credit 位宽（Inline ECC 为 2）；部分写用 RMW；模型延迟。
HIF_DRAM_W ?= 32
HIF_RATIO ?= 4
HIF_BL ?= 16
HIF_RD_LINES ?= 32
HIF_WR_LINES ?= 16
HIF_LPR ?= 24
HIF_HPR ?= 8
HIF_WR ?= 32
HIF_CREDIT_BITS ?= 1
HIF_ECC_RMW ?= 0
HIF_LATENCY ?= 8
HIF := $(filter hif,$(MC_IF))
ifeq ($(filter hif ideal,$(MC_IF)),)
$(error MC_IF 只能为 hif 或 ideal)
endif
HIF_TAG := _hif_d$(HIF_DRAM_W)r$(HIF_RATIO)b$(HIF_BL)_l$(HIF_RD_LINES)-$(HIF_WR_LINES)_c$(HIF_LPR)-$(HIF_HPR)-$(HIF_WR)x$(HIF_CREDIT_BITS)$(if $(filter 1,$(HIF_ECC_RMW)),_rmw)
HIF_GPARAMS := HIF_DRAM_W=$(HIF_DRAM_W) HIF_RATIO=$(HIF_RATIO) HIF_BL=$(HIF_BL) HIF_RD_LINES=$(HIF_RD_LINES) \
  HIF_WR_LINES=$(HIF_WR_LINES) HIF_LPR=$(HIF_LPR) HIF_HPR=$(HIF_HPR) HIF_WR=$(HIF_WR) \
  HIF_CREDIT_BITS=$(HIF_CREDIT_BITS) HIF_ECC_RMW=$(HIF_ECC_RMW) HIF_LATENCY=$(HIF_LATENCY)
HIF_VFLAGS := +define+TB_MC_HIF $(addprefix -G,$(HIF_GPARAMS))
HIF_CDEFS := -DTB_MC_HIF -DTEST_HIF_LINE_BYTES=$$(( $(HIF_BL)*$(HIF_DRAM_W)/8 )) \
  -DTEST_HIF_CORE_BYTES=$$(( $(HIF_DRAM_W)*$(HIF_RATIO)*2/8 )) -DTEST_HIF_LPR=$(HIF_LPR) -DTEST_HIF_HPR=$(HIF_HPR) -DTEST_HIF_WR=$(HIF_WR)
# 仅供测试平台打印配置用，与 -G 参数保持一致。
TEST_CDEFS := -DTEST_TX_DEPTH=$(TX_DEPTH) -DTEST_WR_ROUTE_DEPTH=$(WR_ROUTE_DEPTH) -DTEST_WRESP_DEPTH=$(WRESP_DEPTH) -DTEST_WREQ_DEPTH=$(WREQ_DEPTH) \
              -DTEST_RREQ_DEPTH=$(RREQ_DEPTH) -DTEST_RESPONSE_DEPTH=$(RESPONSE_DEPTH) \
              -DTEST_MC_RD_SLOTS=$(MC_RD_SLOTS) -DTEST_MC_WR_SLOTS=$(MC_WR_SLOTS) -DTEST_LINK_DEPTH=$(LINK_DEPTH) $(LINK_DEFS)
MC_TAG := $(if $(HIF),$(HIF_TAG),_ideal)
BUILD := $(abspath build/w$(WIDTH)_rp$(RP)$(if $(filter 1,$(LINK_BPS)),_nrz)$(if $(filter-out 8,$(LINK_LANES)),_x$(LINK_LANES))$(MC_TAG))
RUN_TAG := $(if $(HIF),,_ideal)
RTL := $(ROOT)/rtl/aou_pkg.sv $(ROOT)/rtl/aou_sync_fifo.sv $(ROOT)/rtl/aou_chunk_fifo.sv \
       $(ROOT)/rtl/aou_flit_tx.sv $(ROOT)/rtl/aou_flit_rx.sv \
       $(ROOT)/rtl/aou_transport.sv $(ROOT)/rtl/aou_target_core.sv $(ROOT)/rtl/axi2flit_soc.sv \
       $(ROOT)/rtl/flit2hif_target.sv
IDEAL_MODEL := $(ROOT)/sim/model/flit2mc_target.sv
MODEL := $(if $(HIF),$(ROOT)/sim/model/hif_mc_model.sv,$(IDEAL_MODEL))
# 端口/循环中有显式范围检查，宽度转换均显式转换；保留其他 lint 诊断为错误。
VFLAGS := --assert --timescale 1ns/1ps --unroll-count 2048 \
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
.PHONY: lint build run test-all negative perf perf-all mixed checker-negative fifo fifo-all check help hif-cfg-all ideal-all
# 独立环境顶层 tb_rtl_bridge 的参数（Verilator -G 与 Verdi 外层顶层共用）。
SA_GPARAMS := DATA_WIDTH=$(WIDTH) RP_COUNT=$(RP) LINK_DEPTH=$(LINK_DEPTH) RDATA_DEPTH=$(RDATA_DEPTH) \
  WRESP_DEPTH=$(WRESP_DEPTH) WDATA_DEPTH=$(WDATA_DEPTH) WREQ_DEPTH=$(WREQ_DEPTH) RREQ_DEPTH=$(RREQ_DEPTH) \
  RESPONSE_DEPTH=$(RESPONSE_DEPTH) MC_RD_SLOTS=$(MC_RD_SLOTS) MC_WR_SLOTS=$(MC_WR_SLOTS) TX_DEPTH=$(TX_DEPTH) \
  WR_ROUTE_DEPTH=$(WR_ROUTE_DEPTH) RD_OUTSTANDING=$(RD_OUTSTANDING) WR_OUTSTANDING=$(WR_OUTSTANDING)
# 交付的两个顶层，另检查满速 MC 模型（仿真模型）。
lint:
	$(VERILATOR) --lint-only $(VFLAGS) --top-module axi2flit_soc -GDATA_WIDTH=$(WIDTH) -GRP_COUNT=$(RP) $(RTL)
	$(VERILATOR) --lint-only $(VFLAGS) --top-module flit2hif_target -GDATA_WIDTH=$(WIDTH) -GRP_COUNT=$(RP) \
	  -GMEMC_DRAM_DATA_WIDTH=$(HIF_DRAM_W) -GMEMC_FREQ_RATIO=$(HIF_RATIO) -GMEMC_BURST_LENGTH=$(HIF_BL) $(RTL)
	$(VERILATOR) --lint-only $(VFLAGS) --top-module flit2mc_target -GDATA_WIDTH=$(WIDTH) -GRP_COUNT=$(RP) $(RTL) $(IDEAL_MODEL)

build:
	@mkdir -p $(BUILD)
	@echo "编译 tb_rtl_bridge  WIDTH=$(WIDTH) RP=$(RP) MC_IF=$(MC_IF)（日志 $(BUILD)/build.log）"
	@$(VERILATOR) --cc --exe --build -j $(JOBS) --trace $(VFLAGS) $(if $(HIF),$(HIF_VFLAGS)) \
	  --top-module tb_rtl_bridge $(addprefix -G,$(SA_GPARAMS)) \
	  --Mdir $(BUILD) $(RTL) $(MODEL) $(ROOT)/sim/tb/tb_rtl_bridge.sv $(ROOT)/sim/tb/tb_rtl_bridge.cpp \
	  -CFLAGS "-std=c++17 -DAXI_DATA_WIDTH_CFG=$(WIDTH) -DTEST_RP=$(RP) -DTEST_RX_DEPTH=$(RDATA_DEPTH) -DTEST_WDATA_DEPTH=$(WDATA_DEPTH) $(TEST_CDEFS) $(if $(HIF),$(HIF_CDEFS)) -I$(ROOT)/systemc/include -I$(SYSTEMC_HOME)/include" \
	  -LDFLAGS '-L$(SYSTEMC_HOME)/lib -Wl,-rpath,$(SYSTEMC_HOME)/lib -lsystemc' \
	  > $(BUILD)/build.log 2>&1 || { tail -40 $(BUILD)/build.log; exit 1; }

run: build
	@mkdir -p results
	@SYSTEMC_DISABLE_COPYRIGHT_MESSAGE=1 $(BUILD)/Vtb_rtl_bridge $(ARGS) | tee results/rtl_$(WIDTH)_rp$(RP)$(RUN_TAG).log

# 独立环境看波形（Verdi）：Verilator 仿真生成 VCD → vcd2fsdb 转为 FSDB（-inst_array 使生成块名为 g_rp[0] 而非转义名）；vericom 把 RTL 与测试顶层编译成
# Verdi 设计库，外层顶层 TOP 按同一组参数例化 tb_rtl_bridge，使设计层次与 VCD 的 TOP.tb_rtl_bridge.* 一致，
# 从而可以在源码与波形之间跳转、追踪驱动。测试平台的激励是 C++，不在设计库中。
#   make fsdb  WIDTH=256 [MC_IF=..] [ARGS=..]   运行并生成 results/rtl_<位宽>_rp<RP><标记>.fsdb
#   make verdi WIDTH=256 [MC_IF=..]             打开 Verdi（需先 make fsdb，配置变量须一致）
SA_FSDB = $(ROOT)/sim/results/rtl_$(WIDTH)_rp$(RP)$(RUN_TAG).fsdb
SA_VERDI_DIR = $(BUILD)/verdi
.PHONY: fsdb verdi
fsdb: build
	@mkdir -p results $(SA_VERDI_DIR)
	@SYSTEMC_DISABLE_COPYRIGHT_MESSAGE=1 $(BUILD)/Vtb_rtl_bridge --trace $(ARGS) | tee results/rtl_$(WIDTH)_rp$(RP)$(RUN_TAG).log
	@echo "转换 FSDB（日志 $(SA_VERDI_DIR)/vcd2fsdb.log）"
	@cd $(SA_VERDI_DIR) && vcd2fsdb $(ROOT)/sim/results/rtl_$(WIDTH)_rp$(RP).vcd -inst_array -o $(SA_FSDB) > vcd2fsdb.log 2>&1 \
	  || { tail -20 vcd2fsdb.log; exit 1; }
	@echo "波形  $(SA_FSDB)；查看：make verdi WIDTH=$(WIDTH) RP=$(RP) MC_IF=$(MC_IF)"
verdi:
	@test -f $(SA_FSDB) || { echo "没有波形，先运行 make fsdb WIDTH=$(WIDTH) RP=$(RP) MC_IF=$(MC_IF)"; exit 1; }
	@mkdir -p $(SA_VERDI_DIR)
	@python3 $(ROOT)/sim/scripts/gen_verdi_top.py $(SA_VERDI_DIR)/verdi_top.sv $(SA_GPARAMS) $(if $(HIF),$(HIF_GPARAMS))
	@cd $(SA_VERDI_DIR) && bash $(VERDI_HOME)/bin/vericom -sv -2012 $(if $(HIF),+define+TB_MC_HIF) $(RTL) $(MODEL) \
	  $(ROOT)/sim/tb/tb_rtl_bridge.sv verdi_top.sv > vericom.log 2>&1 || { tail -20 vericom.log; exit 1; }
	$(if $(NO_GUI),@echo "设计库就绪：$(SA_VERDI_DIR)/work.lib++",cd $(SA_VERDI_DIR) && verdi -lib work.lib++ -top TOP -ssf $(SA_FSDB) &)

test-all:
	@set -e; for w in 256 512 1024; do for p in 1 2 4; do \
	  $(MAKE) WIDTH=$$w RP=$$p lint run negative; \
	done; done

negative: build
	@mkdir -p results
	$(BUILD)/Vtb_rtl_bridge --negative | tee results/negative_$(WIDTH)_rp$(RP)$(RUN_TAG).log

perf: build
	@mkdir -p results
	$(BUILD)/Vtb_rtl_bridge --perf | tee results/perf_$(WIDTH)_rp$(RP)$(RUN_TAG).log

.PHONY: scenario
scenario: build
	@mkdir -p results
	$(BUILD)/Vtb_rtl_bridge --scenario $(SCENARIO) $(ARGS) | tee results/$(SCENARIO)_$(WIDTH)_rp$(RP)$(RUN_TAG).log

perf-all:
	@for w in 256 512 1024; do $(MAKE) WIDTH=$$w RP=1 perf; done

# 读写同时持续供数；只报告带宽并做数据检查，不设效率门限。
mixed: build
	@mkdir -p results
	$(BUILD)/Vtb_rtl_bridge --scenario saturated --direction mixed $(ARGS) | tee results/mixed_$(WIDTH)_rp$(RP)$(RUN_TAG).log

# 只接受指定的“读数据不一致 + 退出码 1”，工具崩溃或其他故障不算负向控制通过。
checker-negative: build
	@mkdir -p results
	@rc=0; $(BUILD)/Vtb_rtl_bridge --corrupt-read > results/checker_negative.log 2>&1 || rc=$$?; \
	  test $$rc -eq 1; grep -q 'RTL FAIL: checker negative control.*R data mismatch' results/checker_negative.log; \
	  echo 'CHECKER NEGATIVE PASS: expected read mismatch detected'

# 其他控制器配置（1024/256 位、RP2）：16 位 DRAM（1024 位一拍 4 条命令）、64 位 DRAM 1:2（每条命令 128B），
# 2 位 credit（Inline ECC）、部分写用 RMW、极小 credit 与缓冲。
hif-cfg-all:
	@set -e; for cfg in "HIF_DRAM_W=16" "HIF_DRAM_W=64 HIF_RATIO=2" "HIF_CREDIT_BITS=2" "HIF_ECC_RMW=1" \
	  "HIF_LPR=2 HIF_HPR=1 HIF_WR=2 HIF_RD_LINES=4 HIF_WR_LINES=2"; do \
	  for w in 256 1024; do $(MAKE) --no-print-directory MC_IF=hif WIDTH=$$w RP=2 $$cfg run negative; done; done

# 满速 MC 模型：桥 + 链路本身的能力（三位宽吞吐、1024 位满载 90% 门限、读写同时）。
ideal-all:
	$(MAKE) MC_IF=ideal test-all
	$(MAKE) MC_IF=ideal perf-all
	$(MAKE) MC_IF=ideal scenario WIDTH=1024 RP=1 SCENARIO=saturated ARGS='--min-efficiency 0.90'
	$(MAKE) MC_IF=ideal WIDTH=1024 RP=1 mixed

check:
	$(MAKE) fifo-all
	$(MAKE) codec-all
	$(MAKE) test-all
	$(MAKE) hif-cfg-all
	$(MAKE) ideal-all
	$(MAKE) WIDTH=256 RP=1 checker-negative

fifo:
	@mkdir -p build/fifo_$(DEPTH)_fwft$(FWFT) results
	$(VERILATOR) --cc --exe --build -j $(JOBS) $(VFLAGS) --top-module aou_sync_fifo \
	  -GDEPTH=$(DEPTH) -GFWFT=$(FWFT) --Mdir $(ROOT)/sim/build/fifo_$(DEPTH)_fwft$(FWFT) \
	  $(ROOT)/rtl/aou_sync_fifo.sv $(ROOT)/sim/tb/tb_fifo.cpp \
	  -CFLAGS '-DFIFO_DEPTH=$(DEPTH) -DFIFO_FWFT=$(FWFT)'
	$(ROOT)/sim/build/fifo_$(DEPTH)_fwft$(FWFT)/Vaou_sync_fifo | tee results/fifo_$(DEPTH)_fwft$(FWFT).log

fifo-all:
	@for m in 0 1; do for d in 1 2 3 8; do $(MAKE) DEPTH=$$d FWFT=$$m fifo; done; done

# ============================================================
#  RTL 两端桥 + SystemC 全链路（UCIe 适配器、链路训练、PHY、CRC、重放）联合仿真
#  两套工具共用同一份 SystemC 测试平台 tb/tb_full_link_rtl.cpp：
#    Verilator + GTKWave：交付使用。make fl / fl-all / fl-wave
#    VCS + Verdi        ：本地调试。make fl-vcs / fl-verdi
#  FL_ARGS 传给仿真程序，例如 FL_ARGS='--stress --replay'、FL_ARGS='--perf mixed'。
# ============================================================
UCIE_DIR ?= $(ROOT)/reference/ucie-model
FL_MC_SLOTS ?= 16
# 适配器与链路模型之间的 FDI 通道深度（帧），1 表示按链路节奏反压，接近 D2D Adapter 的 pl_trdy。
# 帧周期短于两拍时（如 x16 PAM4，2.67 ns）深度 1 会丢发送机会，需取 2。
FL_FDI_DEPTH ?= 1
FL_ARGS ?=
# 只跑指定用例，例如 TC=13（满载读）、TC=2,13；不设则全部运行。用例表：make fl FL_ARGS=--help
TC ?=
comma := ,
FL_RUN_ARGS = $(FL_ARGS) $(if $(TC),--case $(TC))
FL_TB := $(ROOT)/sim/tb/fl_rtl_top.sv
# 存储侧模型（HIF 控制器模型或满速 MC 模型）与 RTL 一起编译。
FL_MODEL := $(MODEL)
FL_HIF_DEFS := $(if $(HIF),+define+FL_MC_HIF +define+FL_HIF_DRAM_W=$(HIF_DRAM_W) +define+FL_HIF_RATIO=$(HIF_RATIO) \
  +define+FL_HIF_BL=$(HIF_BL) +define+FL_HIF_RD_LINES=$(HIF_RD_LINES) +define+FL_HIF_WR_LINES=$(HIF_WR_LINES) \
  +define+FL_HIF_LPR=$(HIF_LPR) +define+FL_HIF_HPR=$(HIF_HPR) +define+FL_HIF_WR=$(HIF_WR) +define+FL_HIF_LATENCY=$(HIF_LATENCY))
FL_HIF_CDEFS := $(if $(HIF),-DFL_MC_HIF -DFL_HIF_DRAM_W=$(HIF_DRAM_W) -DFL_HIF_RATIO=$(HIF_RATIO) -DFL_HIF_BL=$(HIF_BL) \
  -DFL_HIF_LPR=$(HIF_LPR) -DFL_HIF_HPR=$(HIF_HPR) -DFL_HIF_WR=$(HIF_WR) -DFL_HIF_LATENCY=$(HIF_LATENCY))
FL_DEFS := +define+FL_DATA_WIDTH=$(WIDTH) +define+FL_RP_COUNT=$(RP) +define+FL_MC_SLOTS=$(FL_MC_SLOTS) \
  +define+FL_RDATA_DEPTH=$(RDATA_DEPTH) +define+FL_WRESP_DEPTH=$(WRESP_DEPTH) +define+FL_WREQ_DEPTH=$(WREQ_DEPTH) \
  +define+FL_RREQ_DEPTH=$(RREQ_DEPTH) +define+FL_WDATA_DEPTH=$(WDATA_DEPTH) +define+FL_TX_DEPTH=$(TX_DEPTH) \
  +define+FL_WR_ROUTE_DEPTH=$(WR_ROUTE_DEPTH) +define+FL_RESPONSE_DEPTH=$(RESPONSE_DEPTH) \
  +define+FL_RD_OUTSTANDING=$(RD_OUTSTANDING) +define+FL_WR_OUTSTANDING=$(WR_OUTSTANDING) $(FL_HIF_DEFS)
FL_CDEFS := -DFL_RESULTS_DIR=\"$(ROOT)/sim/results\" -DAXI_DATA_WIDTH_CFG=$(WIDTH) -DFL_DATA_WIDTH=$(WIDTH) -DFL_RP_COUNT=$(RP) -DFL_MC_SLOTS=$(FL_MC_SLOTS) -DFL_FDI_DEPTH=$(FL_FDI_DEPTH) $(LINK_DEFS) \
  -DFL_RDATA_DEPTH=$(RDATA_DEPTH) -DFL_WRESP_DEPTH=$(WRESP_DEPTH) -DFL_WREQ_DEPTH=$(WREQ_DEPTH) \
  -DFL_RREQ_DEPTH=$(RREQ_DEPTH) -DFL_WDATA_DEPTH=$(WDATA_DEPTH) -DFL_TX_DEPTH=$(TX_DEPTH) \
  -DFL_WR_ROUTE_DEPTH=$(WR_ROUTE_DEPTH) -DFL_RESPONSE_DEPTH=$(RESPONSE_DEPTH) $(FL_HIF_CDEFS)
FL_INC := -I$(ROOT)/sim/tb -I$(ROOT)/systemc/include -I$(ROOT)/systemc/integration -I$(UCIE_DIR)/src
FL_CFG_TAG := w$(WIDTH)_rp$(RP)_d$(RDATA_DEPTH)-$(WRESP_DEPTH)-$(WREQ_DEPTH)-$(RREQ_DEPTH)-$(WDATA_DEPTH)-t$(TX_DEPTH)-$(WR_ROUTE_DEPTH)-$(RESPONSE_DEPTH)-o$(RD_OUTSTANDING)-$(WR_OUTSTANDING)-$(FL_MC_SLOTS)-f$(FL_FDI_DEPTH)-m$(LINK_BPS)x$(LINK_LANES)$(MC_TAG)
FL_VL_BUILD := $(abspath build/fl_vl_$(FL_CFG_TAG))
FL_VCS_BUILD := $(abspath build/fl_vcs_w$(WIDTH)_rp$(RP)$(MC_TAG))
FL_NAME = full_link_rtl_$(WIDTH)_rp$(RP)$(RUN_TAG)$(subst /,_,$(subst $(space),,$(subst --,_,$(FL_ARGS))))$(if $(TC),_tc$(subst $(comma),-,$(TC)))
space := $(empty) $(empty)
.PHONY: fl fl-build fl-all fl-ideal-all fl-wave fl-vcs fl-vcs-build fl-verdi

fl-build:
	@mkdir -p $(FL_VL_BUILD)
	@echo "编译全链路（Verilator）WIDTH=$(WIDTH) RP=$(RP) MC_IF=$(MC_IF)（日志 $(FL_VL_BUILD)/build.log）"
	@SYSTEMC_INCLUDE=$(SYSTEMC_HOME)/include SYSTEMC_LIBDIR=$(SYSTEMC_HOME)/lib \
	$(VERILATOR) --sc --pins-bv 2 --exe --build -j $(JOBS) --trace $(VFLAGS) --timescale-override 1ns/1fs \
	  --top-module fl_rtl_top \
	  $(FL_DEFS) --Mdir $(FL_VL_BUILD) $(RTL) $(FL_MODEL) $(FL_TB) $(ROOT)/sim/tb/tb_full_link_rtl.cpp \
	  -CFLAGS '-std=c++17 -DVERILATOR_FLOW $(FL_CDEFS) $(FL_INC)' \
	  -LDFLAGS '-Wl,-rpath,$(SYSTEMC_HOME)/lib' \
	  > $(FL_VL_BUILD)/build.log 2>&1 || { tail -40 $(FL_VL_BUILD)/build.log; exit 1; }

fl: fl-build
	@mkdir -p results
	@cd $(ROOT)/sim && SYSTEMC_DISABLE_COPYRIGHT_MESSAGE=1 $(FL_VL_BUILD)/Vfl_rtl_top $(FL_RUN_ARGS) | tee results/$(FL_NAME).log

# 三位宽 × RP1/2/4（每次含空载延迟、功能用例与满载吞吐），另加 RP2 压力 + CRC 重放。
fl-all:
	@set -e; for w in 256 512 1024; do for p in 1 2 4; do $(MAKE) --no-print-directory WIDTH=$$w RP=$$p fl; done; \
	  $(MAKE) --no-print-directory WIDTH=$$w RP=2 fl FL_ARGS='--stress --replay'; done

# 同上，存储侧换成满速 MC 模型，测量桥 + 链路的上限。
fl-ideal-all:
	$(MAKE) MC_IF=ideal fl-all

# 生成 VCD 并用 GTKWave 打开（波形较大，建议配合较短的用例）。
fl-wave: fl-build
	@mkdir -p results
	cd $(ROOT)/sim && $(FL_VL_BUILD)/Vfl_rtl_top $(FL_RUN_ARGS) --vcd results/$(FL_NAME).vcd | tee results/$(FL_NAME).log
	gtkwave results/$(FL_NAME).vcd &

# VCS：先分析 RTL，再为封装顶层生成 SystemC 接口（端口映射由脚本按配置生成），最后与测试平台链接。
# 链路模型的 UI 约 41.7ps，SystemC 时间精度为 1fs，RTL 按 1ns/1fs 编译以保持一致。
# 本机 g++ 9.4 的 -dumpversion 只输出“9”，VCS 无法识别，需 -sysc=forcegcc9 指定使用 gcc9 版本的 SystemC 库。
# VCS 内部调用 gmake；Ubuntu 只有 make，在构建目录放一个 gmake 链接并加入 PATH。
# Ubuntu 的链接器默认 --as-needed，会丢弃 VCS 运行库依赖的内部库，链接时需 --no-as-needed。
# syscan 声明 #!/bin/sh 却使用 bash 语法，Ubuntu 的 /bin/sh 是 dash，故显式用 bash 调用。
VCS_SYSC := -sysc=234 -sysc=forcegcc9
VCS_ENV := PATH=$(FL_VCS_BUILD)/bin:$$PATH
# 增量构建时 vcs 会报 NTMES（找不到顶层），因此每次清空 VCS 中间文件后完整构建。
VCS_LOG = >> $(FL_VCS_BUILD)/build.log 2>&1 || { tail -40 $(FL_VCS_BUILD)/build.log; exit 1; }
fl-vcs-build:
	@rm -rf $(FL_VCS_BUILD)/csrc $(FL_VCS_BUILD)/AN.DB $(FL_VCS_BUILD)/work.lib++ $(FL_VCS_BUILD)/simv* $(FL_VCS_BUILD)/build.log
	@mkdir -p $(FL_VCS_BUILD)/bin
	@ln -sf $$(command -v make) $(FL_VCS_BUILD)/bin/gmake
	@echo "编译全链路（VCS）WIDTH=$(WIDTH) RP=$(RP) MC_IF=$(MC_IF)（日志 $(FL_VCS_BUILD)/build.log）"
	@cd $(FL_VCS_BUILD) && python3 $(ROOT)/sim/scripts/gen_portmap.py $(FL_TB) $(WIDTH) $(FL_MC_SLOTS) fl_rtl_top.map $(VCS_LOG)
	@cd $(FL_VCS_BUILD) && $(VCS_ENV) vlogan -full64 -sverilog $(VCS_SYSC) -timescale=1ns/1fs $(FL_DEFS) +define+FSDB=\"fl_rtl_top.fsdb\" \
	  $(RTL) $(FL_MODEL) -l vlogan_rtl.log $(VCS_LOG)
	@cd $(FL_VCS_BUILD) && $(VCS_ENV) vlogan -full64 -sverilog $(VCS_SYSC) -timescale=1ns/1fs $(FL_DEFS) +define+FSDB=\"fl_rtl_top.fsdb\" \
	  -sc_model fl_rtl_top -sc_portmap fl_rtl_top.map $(FL_TB) -l vlogan_top.log $(VCS_LOG)
	@cd $(FL_VCS_BUILD) && $(VCS_ENV) bash $(VCS_HOME)/bin/syscan -full64 $(VCS_SYSC) -cflags '-std=c++17 -g $(FL_CDEFS) $(FL_INC)' \
	  $(ROOT)/sim/tb/tb_full_link_rtl.cpp -l syscan.log $(VCS_LOG)
	@cd $(FL_VCS_BUILD) && $(VCS_ENV) vcs -full64 $(VCS_SYSC) -debug_access+all -timescale=1ns/1fs sc_main \
	  -LDFLAGS -Wl,--no-as-needed \
	  -o simv -l vcs.log $(VCS_LOG)

# 运行期 VCS 的版权信息、首次展开过程写入 sim_boot.log，屏幕只保留测试平台输出。
# -no_save 关闭 $save 支持，避免检测到 ASLR 后重新启动一次。
fl-vcs: fl-vcs-build
	@mkdir -p results
	@cd $(FL_VCS_BUILD) && SYSTEMC_DISABLE_COPYRIGHT_MESSAGE=1 ./simv -no_save $(FL_RUN_ARGS) -l sim.log > sim_boot.log 2>&1; rc=$$?; \
	  sed -n '/^=\{10,\} 全链路/,/^用时/p;/^FAIL/p' sim_boot.log | tee $(ROOT)/sim/results/$(FL_NAME)_vcs.log; \
	  grep -h '^\[FAIL\]\|Error' sim_boot.log || true; \
	  grep -q '^FAIL\|^\[FAIL\]' sim_boot.log && rc=1; \
	  echo "波形  make fl-verdi WIDTH=$(WIDTH) RP=$(RP) MC_IF=$(MC_IF)"; exit $$rc

# Verdi：用 vericom 把 RTL 编译成 Verdi 设计库（verdi/work.lib++），再加载设计库与 FSDB。
# 不使用 simv.daidir：它需要 -kdb，而 SystemC 混合仿真的 KDB 要由 Verdi 的 elabcom 补全，
# 该脚本在 Ubuntu（/bin/sh 为 dash）下无法运行。vericom 同样要用 bash 调用，并需要 -2012 才能识别参数列表中的 localparam。
# 波形中 RTL 位于 sc_main.tb.dut 之下，设计库用外层顶层 sc_main.tb.dut 对齐该层次；tb_case 为当前用例编号（20 为空载延迟测量）。
VERDI_DIR = $(FL_VCS_BUILD)/verdi
VERDI_HOME ?= $(abspath $(dir $(shell command -v verdi))/..)
fl-verdi:
	@mkdir -p $(VERDI_DIR)
	@test -f $(FL_VCS_BUILD)/fl_rtl_top.fsdb || { echo "没有波形，先运行 make fl-vcs WIDTH=$(WIDTH) RP=$(RP) MC_IF=$(MC_IF)"; exit 1; }
	@printf '%s\n' '// 自动生成：与 VCS 波形中的层次 sc_main.tb.dut 一致，Verdi 才能把源码信号对应到 FSDB。' \
	  'module sc_main; fl_verdi_tb tb(); endmodule' 'module fl_verdi_tb; fl_rtl_top dut(); endmodule' > $(VERDI_DIR)/verdi_top.sv
	@cd $(VERDI_DIR) && bash $(VERDI_HOME)/bin/vericom -sv -2012 $(FL_DEFS) $(RTL) $(FL_MODEL) $(FL_TB) verdi_top.sv \
	  > vericom.log 2>&1 || { tail -20 vericom.log; exit 1; }
	$(if $(NO_GUI),@echo "设计库就绪：$(VERDI_DIR)/work.lib++",cd $(VERDI_DIR) && verdi -lib work.lib++ -top sc_main -ssf $(FL_VCS_BUILD)/fl_rtl_top.fsdb &)

# ---------------- SV 定向测试平台（VCS + Verdi） ----------------
# 激励、记分板与用例全部为 SystemVerilog，见 sv_tb/：tb_top.sv（连线）、axi_tasks.svh（主机任务与记分板）、
# tests.svh（用例）。TEST=all 运行全部用例，TEST=用例名 只运行一个；SEED 为随机用例的种子；SV_ARGS 为其他运行参数。
#   make sv-vcs WIDTH=256 [TEST=tc_narrow] [SEED=1] [HIF_DRAM_W=..]    make sv-verdi WIDTH=256
TEST ?= all
SEED ?= 1
export PS1 ?= $$     # VCS 脚本以 bash -u 运行，/etc/bash.bashrc 会访问 PS1
SV_TB := $(ROOT)/sim/sv_tb
SV_BUILD = $(abspath build/sv_w$(WIDTH)_d$(HIF_DRAM_W)r$(HIF_RATIO)b$(HIF_BL)_lat$(HIF_LATENCY))
SV_PARAMS = -pvalue+tb_top.DATA_WIDTH=$(WIDTH) -pvalue+tb_top.HIF_DRAM_W=$(HIF_DRAM_W) \
  -pvalue+tb_top.HIF_RATIO=$(HIF_RATIO) -pvalue+tb_top.HIF_BL=$(HIF_BL) -pvalue+tb_top.HIF_LATENCY=$(HIF_LATENCY)
.PHONY: sv-build sv-vcs sv-verdi
sv-build:
	@mkdir -p $(SV_BUILD)
	@echo "编译 SV 测试平台（VCS）WIDTH=$(WIDTH)（日志 $(SV_BUILD)/build.log）"
	@cd $(SV_BUILD) && vcs -full64 -sverilog -timescale=1ns/1ps -debug_access+all -kdb -lca \
	  +define+FSDB=\"tb_top.fsdb\" +incdir+$(SV_TB) $(SV_PARAMS) \
	  $(RTL) $(ROOT)/sim/model/hif_mc_model.sv $(SV_TB)/tb_top.sv -top tb_top -o simv > build.log 2>&1 \
	  || { grep -E "^Error|Error-" -A4 build.log | head -40; exit 1; }
sv-vcs: sv-build
	@mkdir -p results
	@cd $(SV_BUILD) && ./simv +TEST=$(TEST) +SEED=$(SEED) $(SV_ARGS) -no_save > sim.log 2>&1; \
	  sed -n '/^=\{10,\} SV 测试平台/,$$p' sim.log | grep -vE "^(V C S|           |Synopsys|[$$]finish|Time:|CPU Time|Data structure|\*Verdi\*|FSDB Dumper|\(C\) 1996|(Mon|Tue|Wed|Thu|Fri|Sat|Sun) )" \
	  | tee $(ROOT)/sim/results/sv_tb_$(WIDTH)_$(TEST).log; grep -q "^SV TB PASS" sim.log
sv-verdi:
	@test -f $(SV_BUILD)/tb_top.fsdb || { echo "没有波形，先运行 make sv-vcs WIDTH=$(WIDTH)"; exit 1; }
	cd $(SV_BUILD) && verdi -dbdir simv.daidir -ssf tb_top.fsdb &

help:
	@echo '存储侧    ：默认 MC_IF=hif（交付设计）；MC_IF=ideal 为满速 MC 模型，测桥 + 链路上限'
	@echo '独立 RTL  ：make run WIDTH=1024 RP=1 [RDATA_DEPTH=..] [HIF_DRAM_W=32 HIF_RATIO=4 HIF_BL=16 HIF_LPR/HPR/WR=..]'
	@echo '           make negative；make check（全部回归）；波形：make fsdb + make verdi；运行参数：make run ARGS=--help'
	@echo '全链路    ：make fl WIDTH=1024 RP=1 [TC=13] [FL_ARGS=--stress]；make fl-all；make fl-ideal-all'
	@echo '           make fl-wave TC=2（GTKWave）；make fl-vcs TC=2 + make fl-verdi；用例列表：make fl FL_ARGS=--help'
	@echo 'SV 测试平台：make sv-vcs WIDTH=256 [TEST=tc_narrow]（VCS）；make sv-verdi（Verdi）；用例见 sv_tb/tests.svh'
	@echo '单元与其他：make fifo-all / codec-all / lint / hif-cfg-all / ideal-all / perf-all'

.PHONY: codec codec-all
codec:
	@mkdir -p build/codec_$(WIDTH)_d$(FRAME_DEPTH) results
	$(VERILATOR) --cc --exe --build -j $(JOBS) $(VFLAGS) --top-module tb_flit_codec \
	  -GFRAME_DEPTH=$(FRAME_DEPTH) --Mdir $(ROOT)/sim/build/codec_$(WIDTH)_d$(FRAME_DEPTH) \
	  $(RTL) $(ROOT)/sim/tb/tb_flit_codec.sv $(ROOT)/sim/tb/tb_flit_codec.cpp \
	  -CFLAGS '-std=c++17 -DAXI_DATA_WIDTH_CFG=$(WIDTH) -I$(ROOT)/systemc/include -I$(SYSTEMC_HOME)/include' \
	  -LDFLAGS '-L$(SYSTEMC_HOME)/lib -Wl,-rpath,$(SYSTEMC_HOME)/lib -lsystemc'
	$(ROOT)/sim/build/codec_$(WIDTH)_d$(FRAME_DEPTH)/Vtb_flit_codec | tee results/codec_$(WIDTH)_d$(FRAME_DEPTH).log

codec-all:
	@for w in 256 512 1024; do $(MAKE) codec WIDTH=$$w; done
	$(MAKE) codec WIDTH=1024 FRAME_DEPTH=3

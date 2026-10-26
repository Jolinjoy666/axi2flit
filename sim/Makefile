# RTL 仿真独立入口，所有构建/日志/波形放在本目录；不改变 SystemC 工程的 Makefile。
# Verilator 编译可综合 SV，C++ testbench 使用既有 SystemC 纯编解码函数作字节参考。
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
RDATA_DEPTH ?= 24
WRESP_DEPTH ?= 24
WDATA_DEPTH ?= 24
WREQ_DEPTH ?= 24
RREQ_DEPTH ?= 32
RESPONSE_DEPTH ?= 8
MC_RD_SLOTS ?= 16
MC_WR_SLOTS ?= 16
TX_DEPTH ?= 8
SCENARIO ?= saturated
FRAME_DEPTH ?= 2
# 链路：默认 x8 @ 24 GT/s PAM4，原始 48 GB/s，与 1024 位桥的 64 GB/s 匹配。
# LINK_BPS：2 = PAM4，1 = NRZ；LINK_LANES=16 时 PAM4 为 96 GB/s，瓶颈转到桥上。
LINK_BPS ?= 2
LINK_LANES ?= 8
LINK_DEFS := -DAOU_LINK_BITS_PER_SYMBOL=$(LINK_BPS) -DAOU_LINK_LANES=$(LINK_LANES)
ROOT := $(abspath ..)
# 仅供测试平台打印配置用，与 -G 参数保持一致。
TEST_CDEFS := -DTEST_TX_DEPTH=$(TX_DEPTH) -DTEST_WRESP_DEPTH=$(WRESP_DEPTH) -DTEST_WREQ_DEPTH=$(WREQ_DEPTH) \
              -DTEST_RREQ_DEPTH=$(RREQ_DEPTH) -DTEST_RESPONSE_DEPTH=$(RESPONSE_DEPTH) \
              -DTEST_MC_RD_SLOTS=$(MC_RD_SLOTS) -DTEST_MC_WR_SLOTS=$(MC_WR_SLOTS) -DTEST_LINK_DEPTH=$(LINK_DEPTH) $(LINK_DEFS)
BUILD := $(abspath build/w$(WIDTH)_rp$(RP)$(if $(filter 1,$(LINK_BPS)),_nrz)$(if $(filter-out 8,$(LINK_LANES)),_x$(LINK_LANES)))
RTL := $(ROOT)/rtl/aou_pkg.sv $(ROOT)/rtl/aou_sync_fifo.sv $(ROOT)/rtl/aou_chunk_fifo.sv \
       $(ROOT)/rtl/aou_flit_tx.sv $(ROOT)/rtl/aou_flit_rx.sv \
       $(ROOT)/rtl/aou_transport.sv $(ROOT)/rtl/axi2flit_soc.sv $(ROOT)/rtl/flit2mc_target.sv
# 端口/循环中有显式范围检查，宽度转换均显式转换；保留其他 lint 诊断为错误。
VFLAGS := --assert --timescale 1ns/1ps --unroll-count 2048 \
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
.PHONY: lint build run test-all negative perf perf-all mixed checker-negative fifo fifo-all check help
lint:
	$(VERILATOR) --lint-only $(VFLAGS) --top-module axi2flit_soc -GDATA_WIDTH=$(WIDTH) -GRP_COUNT=$(RP) $(RTL)
	$(VERILATOR) --lint-only $(VFLAGS) --top-module flit2mc_target -GDATA_WIDTH=$(WIDTH) -GRP_COUNT=$(RP) $(RTL)

build:
	@mkdir -p $(BUILD)
	@echo "编译 tb_rtl_bridge  WIDTH=$(WIDTH) RP=$(RP)（日志 $(BUILD)/build.log）"
	@$(VERILATOR) --cc --exe --build -j $(JOBS) --trace $(VFLAGS) \
	  --top-module tb_rtl_bridge -GDATA_WIDTH=$(WIDTH) -GRP_COUNT=$(RP) \
	  -GLINK_DEPTH=$(LINK_DEPTH) -GRDATA_DEPTH=$(RDATA_DEPTH) -GWRESP_DEPTH=$(WRESP_DEPTH) -GWDATA_DEPTH=$(WDATA_DEPTH) \
	  -GWREQ_DEPTH=$(WREQ_DEPTH) -GRREQ_DEPTH=$(RREQ_DEPTH) -GRESPONSE_DEPTH=$(RESPONSE_DEPTH) \
	  -GMC_RD_SLOTS=$(MC_RD_SLOTS) -GMC_WR_SLOTS=$(MC_WR_SLOTS) -GTX_DEPTH=$(TX_DEPTH) \
	  --Mdir $(BUILD) $(RTL) $(ROOT)/sim/tb/tb_rtl_bridge.sv $(ROOT)/sim/tb/tb_rtl_bridge.cpp \
	  -CFLAGS '-std=c++17 -DAXI_DATA_WIDTH_CFG=$(WIDTH) -DTEST_RP=$(RP) -DTEST_RX_DEPTH=$(RDATA_DEPTH) -DTEST_WDATA_DEPTH=$(WDATA_DEPTH) $(TEST_CDEFS) -I$(ROOT)/systemc/include -I$(SYSTEMC_HOME)/include' \
	  -LDFLAGS '-L$(SYSTEMC_HOME)/lib -Wl,-rpath,$(SYSTEMC_HOME)/lib -lsystemc' \
	  > $(BUILD)/build.log 2>&1 || { tail -40 $(BUILD)/build.log; exit 1; }

run: build
	@mkdir -p results
	@SYSTEMC_DISABLE_COPYRIGHT_MESSAGE=1 $(BUILD)/Vtb_rtl_bridge $(ARGS) | tee results/rtl_$(WIDTH)_rp$(RP).log

test-all:
	@set -e; for w in 256 512 1024; do for p in 1 2 4; do \
	  $(MAKE) WIDTH=$$w RP=$$p lint run negative; \
	done; done

negative: build
	@mkdir -p results
	$(BUILD)/Vtb_rtl_bridge --negative | tee results/negative_$(WIDTH)_rp$(RP).log

perf: build
	@mkdir -p results
	$(BUILD)/Vtb_rtl_bridge --perf | tee results/perf_$(WIDTH)_rp$(RP).log

.PHONY: scenario
scenario: build
	@mkdir -p results
	$(BUILD)/Vtb_rtl_bridge --scenario $(SCENARIO) $(ARGS) | tee results/$(SCENARIO)_$(WIDTH)_rp$(RP).log

perf-all:
	@for w in 256 512 1024; do $(MAKE) WIDTH=$$w RP=1 perf; done

# 读写同时持续供数；只报告带宽并做数据检查，不设效率门限。
mixed: build
	@mkdir -p results
	$(BUILD)/Vtb_rtl_bridge --scenario saturated --direction mixed $(ARGS) | tee results/mixed_$(WIDTH)_rp$(RP).log

# 只接受指定的“读数据不一致 + 退出码 1”，工具崩溃或其他故障不算负向控制通过。
checker-negative: build
	@mkdir -p results
	@rc=0; $(BUILD)/Vtb_rtl_bridge --corrupt-read > results/checker_negative.log 2>&1 || rc=$$?; \
	  test $$rc -eq 1; grep -q 'RTL FAIL: checker negative control.*R data mismatch' results/checker_negative.log; \
	  echo 'CHECKER NEGATIVE PASS: expected read mismatch detected'

check:
	$(MAKE) fifo-all
	$(MAKE) codec-all
	$(MAKE) test-all
	$(MAKE) perf-all
	$(MAKE) scenario WIDTH=1024 RP=1 SCENARIO=saturated ARGS='--min-efficiency 0.90'
	$(MAKE) WIDTH=1024 RP=1 mixed
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

# SystemC/RTL 交叉仿真：SystemC SoC 模型经链路连接 RTL 存储侧，同时与 RTL SoC 逐拍比对。
XSIM_BUILD := $(abspath build/xsim_w$(WIDTH)_rp$(RP))
XSIM_SRCS := $(ROOT)/systemc/src/flit_packer.cpp $(ROOT)/systemc/src/flit_unpacker.cpp \
             $(ROOT)/systemc/src/aou_transport.cpp $(ROOT)/systemc/src/axi2flit.cpp \
             $(ROOT)/systemc/src/flit2mc_target.cpp
.PHONY: xsim xsim-build xsim-all
xsim-build:
	@mkdir -p $(XSIM_BUILD)
	SYSTEMC_INCLUDE=$(SYSTEMC_HOME)/include SYSTEMC_LIBDIR=$(SYSTEMC_HOME)/lib \
	$(VERILATOR) --sc --exe --build -j $(JOBS) $(VFLAGS) --top-module xsim_rtl \
	  -GDATA_WIDTH=$(WIDTH) -GRP_COUNT=$(RP) --Mdir $(XSIM_BUILD) $(RTL) $(ROOT)/sim/tb/xsim_rtl.sv \
	  $(ROOT)/sim/tb/tb_xsim.cpp $(XSIM_SRCS) \
	  -CFLAGS '-std=c++17 -DAXI_DATA_WIDTH_CFG=$(WIDTH) -DTEST_RP=$(RP) -I$(ROOT)/systemc/include -I$(ROOT)/systemc/tb' \
	  -LDFLAGS '-Wl,-rpath,$(SYSTEMC_HOME)/lib'

xsim: xsim-build
	@mkdir -p results
	$(XSIM_BUILD)/Vxsim_rtl $(ARGS) | tee results/xsim_$(WIDTH)_rp$(RP)$(if $(ARGS),_$(lastword $(ARGS)),).log

# 三位宽 × RP1/2/4 功能互通与逐拍比对；1024 位另跑读、写、读写并发满载。
xsim-all:
	@set -e; for w in 256 512 1024; do for p in 1 2 4; do $(MAKE) WIDTH=$$w RP=$$p xsim; done; done
	@set -e; for d in read write mixed; do $(MAKE) WIDTH=1024 RP=1 xsim ARGS="--perf $$d"; done

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
FL_DEFS := +define+FL_DATA_WIDTH=$(WIDTH) +define+FL_RP_COUNT=$(RP) +define+FL_MC_SLOTS=$(FL_MC_SLOTS) \
  +define+FL_RDATA_DEPTH=$(RDATA_DEPTH) +define+FL_WRESP_DEPTH=$(WRESP_DEPTH) +define+FL_WREQ_DEPTH=$(WREQ_DEPTH) \
  +define+FL_RREQ_DEPTH=$(RREQ_DEPTH) +define+FL_WDATA_DEPTH=$(WDATA_DEPTH)
FL_CDEFS := -DFL_RESULTS_DIR=\"$(ROOT)/sim/results\" -DAXI_DATA_WIDTH_CFG=$(WIDTH) -DFL_DATA_WIDTH=$(WIDTH) -DFL_RP_COUNT=$(RP) -DFL_MC_SLOTS=$(FL_MC_SLOTS) -DFL_FDI_DEPTH=$(FL_FDI_DEPTH) $(LINK_DEFS) \
  -DFL_RDATA_DEPTH=$(RDATA_DEPTH) -DFL_WRESP_DEPTH=$(WRESP_DEPTH) -DFL_WREQ_DEPTH=$(WREQ_DEPTH) \
  -DFL_RREQ_DEPTH=$(RREQ_DEPTH) -DFL_WDATA_DEPTH=$(WDATA_DEPTH)
FL_INC := -I$(ROOT)/sim/tb -I$(ROOT)/systemc/include -I$(ROOT)/systemc/integration -I$(UCIE_DIR)/src
FL_CFG_TAG := w$(WIDTH)_rp$(RP)_d$(RDATA_DEPTH)-$(WRESP_DEPTH)-$(WREQ_DEPTH)-$(RREQ_DEPTH)-$(WDATA_DEPTH)-$(FL_MC_SLOTS)-f$(FL_FDI_DEPTH)-m$(LINK_BPS)x$(LINK_LANES)
FL_VL_BUILD := $(abspath build/fl_vl_$(FL_CFG_TAG))
FL_VCS_BUILD := $(abspath build/fl_vcs_w$(WIDTH)_rp$(RP))
FL_NAME = full_link_rtl_$(WIDTH)_rp$(RP)$(subst /,_,$(subst $(space),,$(subst --,_,$(FL_ARGS))))$(if $(TC),_tc$(subst $(comma),-,$(TC)))
space := $(empty) $(empty)
.PHONY: fl fl-build fl-all fl-wave fl-vcs fl-vcs-build fl-verdi

fl-build:
	@mkdir -p $(FL_VL_BUILD)
	@echo "编译全链路（Verilator）WIDTH=$(WIDTH) RP=$(RP)（日志 $(FL_VL_BUILD)/build.log）"
	@SYSTEMC_INCLUDE=$(SYSTEMC_HOME)/include SYSTEMC_LIBDIR=$(SYSTEMC_HOME)/lib \
	$(VERILATOR) --sc --pins-bv 2 --exe --build -j $(JOBS) --trace $(VFLAGS) --timescale-override 1ns/1fs \
	  --top-module fl_rtl_top \
	  $(FL_DEFS) --Mdir $(FL_VL_BUILD) $(RTL) $(FL_TB) $(ROOT)/sim/tb/tb_full_link_rtl.cpp \
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
	@echo "编译全链路（VCS）WIDTH=$(WIDTH) RP=$(RP)（日志 $(FL_VCS_BUILD)/build.log）"
	@cd $(FL_VCS_BUILD) && python3 $(ROOT)/sim/scripts/gen_portmap.py $(FL_TB) $(WIDTH) $(FL_MC_SLOTS) fl_rtl_top.map $(VCS_LOG)
	@cd $(FL_VCS_BUILD) && $(VCS_ENV) vlogan -full64 -sverilog $(VCS_SYSC) -timescale=1ns/1fs $(FL_DEFS) +define+FSDB=\"fl_rtl_top.fsdb\" \
	  $(RTL) -l vlogan_rtl.log $(VCS_LOG)
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
	  echo "波形  make fl-verdi WIDTH=$(WIDTH) RP=$(RP)"; exit $$rc

# Verdi：用 vericom 把 RTL 编译成 Verdi 设计库（verdi/work.lib++），再加载设计库与 FSDB。
# 不使用 simv.daidir：它需要 -kdb，而 SystemC 混合仿真的 KDB 要由 Verdi 的 elabcom 补全，
# 该脚本在 Ubuntu（/bin/sh 为 dash）下无法运行。vericom 同样要用 bash 调用，并需要 -2012 才能识别参数列表中的 localparam。
# 波形中 RTL 位于 sc_main.tb.dut 之下，tb_case 为当前用例编号（20 为空载延迟测量）。
VERDI_DIR = $(FL_VCS_BUILD)/verdi
VERDI_HOME ?= $(abspath $(dir $(shell command -v verdi))/..)
fl-verdi:
	@mkdir -p $(VERDI_DIR)
	@test -f $(FL_VCS_BUILD)/fl_rtl_top.fsdb || { echo "没有波形，先运行 make fl-vcs WIDTH=$(WIDTH) RP=$(RP)"; exit 1; }
	@cd $(VERDI_DIR) && bash $(VERDI_HOME)/bin/vericom -sv -2012 $(FL_DEFS) $(RTL) $(FL_TB) > vericom.log 2>&1 || { tail -20 vericom.log; exit 1; }
	cd $(VERDI_DIR) && verdi -lib work.lib++ -top fl_rtl_top -ssf $(FL_VCS_BUILD)/fl_rtl_top.fsdb &

help:
	@echo '独立 RTL：make run WIDTH=1024 RP=1 [RDATA_DEPTH=..]；make check（全部回归）；波形：make run ARGS=--trace'
	@echo '全链路  ：make fl WIDTH=1024 RP=1 [TC=13] [FL_ARGS=--stress]；make fl-wave TC=2（GTKWave）；make fl-vcs TC=2 + make fl-verdi'
	@echo '用例列表：make fl FL_ARGS=--help；make lint/negative/perf；make fifo DEPTH=3 FWFT=0；make test-all/perf-all'
	@echo 'make codec-all；make scenario WIDTH=1024 SCENARIO=saturated ARGS="--min-efficiency 0.90"；运行参数：make run ARGS=--help'

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

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
FWFT ?= 0
LINK_DEPTH ?= 64
RX_DEPTH ?= 32
WDATA_DEPTH ?= 32
REQUEST_DEPTH ?= 4
RESPONSE_DEPTH ?= 8
MC_SLOTS ?= 16
SCENARIO ?= saturated
FRAME_DEPTH ?= 2
ROOT := $(abspath ..)
BUILD := $(abspath build/w$(WIDTH)_rp$(RP))
RTL := $(ROOT)/rtl/aou_pkg.sv $(ROOT)/rtl/aou_sync_fifo.sv \
       $(ROOT)/rtl/aou_flit_tx.sv $(ROOT)/rtl/aou_flit_rx.sv \
       $(ROOT)/rtl/aou_transport.sv $(ROOT)/rtl/axi2flit_soc.sv $(ROOT)/rtl/flit2mc_target.sv
# 端口/循环中有显式范围检查，宽度转换均显式转换；保留其他 lint 诊断为错误。
VFLAGS := --assert --timescale 1ns/1ps --unroll-count 2048 \
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
.PHONY: lint build run test-all negative perf perf-all checker-negative fifo fifo-all check help
lint:
	$(VERILATOR) --lint-only $(VFLAGS) --top-module axi2flit_soc -GDATA_WIDTH=$(WIDTH) -GRP_COUNT=$(RP) $(RTL)
	$(VERILATOR) --lint-only $(VFLAGS) --top-module flit2mc_target -GDATA_WIDTH=$(WIDTH) -GRP_COUNT=$(RP) $(RTL)

build:
	@mkdir -p $(BUILD)
	$(VERILATOR) --cc --exe --build -j $(JOBS) --trace $(VFLAGS) \
	  --top-module tb_rtl_bridge -GDATA_WIDTH=$(WIDTH) -GRP_COUNT=$(RP) \
	  -GLINK_DEPTH=$(LINK_DEPTH) -GRX_DEPTH=$(RX_DEPTH) -GWDATA_DEPTH=$(WDATA_DEPTH) \
	  -GREQUEST_DEPTH=$(REQUEST_DEPTH) -GRESPONSE_DEPTH=$(RESPONSE_DEPTH) -GMC_SLOTS=$(MC_SLOTS) \
	  --Mdir $(BUILD) $(RTL) $(ROOT)/sim/tb/tb_rtl_bridge.sv $(ROOT)/sim/tb/tb_rtl_bridge.cpp \
	  -CFLAGS '-std=c++17 -DAXI_DATA_WIDTH_CFG=$(WIDTH) -DTEST_RP=$(RP) -DTEST_RX_DEPTH=$(RX_DEPTH) -DTEST_WDATA_DEPTH=$(WDATA_DEPTH) -I$(ROOT)/systemc/include -I$(SYSTEMC_HOME)/include' \
	  -LDFLAGS '-L$(SYSTEMC_HOME)/lib -Wl,-rpath,$(SYSTEMC_HOME)/lib -lsystemc'

run: build
	@mkdir -p results
	$(BUILD)/Vtb_rtl_bridge $(ARGS) | tee results/rtl_$(WIDTH)_rp$(RP).log

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
	$(MAKE) WIDTH=256 RP=1 checker-negative

fifo:
	@mkdir -p build/fifo_$(DEPTH)_fwft$(FWFT) results
	$(VERILATOR) --cc --exe --build -j $(JOBS) $(VFLAGS) --top-module aou_sync_fifo \
	  -GDEPTH=$(DEPTH) -GFWFT=$(FWFT) --Mdir $(ROOT)/sim/build/fifo_$(DEPTH)_fwft$(FWFT) \
	  $(ROOT)/rtl/aou_sync_fifo.sv $(ROOT)/sim/tb/tb_fifo.cpp \
	  -CFLAGS '-DFIFO_DEPTH=$(DEPTH) -DFIFO_FWFT=$(FWFT)'
	$(ROOT)/sim/build/fifo_$(DEPTH)_fwft$(FWFT)/Vaou_sync_fifo | tee results/fifo_$(DEPTH)_fwft$(FWFT).log

fifo-all:
	@for mode in 0 1; do for d in 1 3 8; do $(MAKE) DEPTH=$$d FWFT=$$mode fifo; done; done

help:
	@echo 'make lint/run/negative/perf WIDTH=256 RP=1；make fifo DEPTH=3 FWFT=1；make test-all/perf-all/check；波形：make run ARGS=--trace'
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

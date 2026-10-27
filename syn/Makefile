# Design Compiler 综合入口。每个配置在 run/<TAG>/ 下独立运行，互不覆盖：
#   run/<TAG>/log/dc.log   完整日志
#   run/<TAG>/rpt/         summary / qor / timing / area / power 等报告
#   run/<TAG>/out/         门级网表 .v、.ddc、.sdc、.svf（WRITE_SDF=1 时另有 .sdf）
#
# 常用：
#   make                                  # 综合 axi2flit_soc，256 位，500 MHz
#   make TOP=flit2hif_target              # 综合存储侧顶层
#   make all                              # 依次综合两个顶层
#   make PERIOD=1.6                       # 改时钟周期（ns）
#   make PARAMS="TX_DEPTH=4" TAG=soc_tx4  # 透传其他顶层参数，需自取 TAG 以免覆盖默认配置
#   make report                           # 不重新综合，只用已有 ddc 重出报告（参数需与综合时一致）
#   make summary                          # 汇总所有已完成配置的结果
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

DC_SHELL   ?= dc_shell
SYN_DIR    := $(abspath .)
PROJ_DIR   := $(abspath ..)

# ---- 设计参数 ----
TOP        ?= axi2flit_soc      # axi2flit_soc | flit2hif_target
WIDTH      ?= 256               # DATA_WIDTH：256 | 512 | 1024
RP         ?= 1                 # RP_COUNT：1～4
PARAMS     ?=                   # 其他顶层参数，逗号分隔的 NAME=VALUE

# ---- 约束与综合选项 ----
PERIOD     ?= 2.0               # 时钟周期 ns（2.0 = 500 MHz）
IO_RATIO   ?= 0.3               # 端口外部延迟占周期的比例
GATE_CLOCK ?= 0                 # 1：compile_ultra -gate_clock
WRITE_SDF  ?= 0                 # 1：额外导出 SDF（门级时序仿真用，文件很大）
CORES      ?= 8

TOP        := $(strip $(TOP))
TAG        ?= $(TOP)_w$(strip $(WIDTH))_rp$(strip $(RP))_p$(strip $(PERIOD))
RUN_DIR    := run/$(strip $(TAG))

DC_VARS := set SYN_DIR $(SYN_DIR); set PROJ_DIR $(PROJ_DIR); \
           set TOP $(TOP); set DATA_WIDTH $(strip $(WIDTH)); set RP_COUNT $(strip $(RP)); \
           set EXTRA_PARAMS \"$(strip $(PARAMS))\"; \
           set CLK_PERIOD $(strip $(PERIOD)); set IO_RATIO $(strip $(IO_RATIO)); \
           set GATE_CLOCK $(strip $(GATE_CLOCK)); set WRITE_SDF $(strip $(WRITE_SDF)); set CORES $(strip $(CORES))

.PHONY: syn report all soc target summary clean help

syn:
	@mkdir -p $(RUN_DIR)/log
	cd $(RUN_DIR) && $(DC_SHELL) -x "$(DC_VARS)" -f $(SYN_DIR)/scripts/dc_run.tcl 2>&1 | tee log/dc.log
	@echo "结果：$(RUN_DIR)/rpt/summary.rpt"

report:
	cd $(RUN_DIR) && $(DC_SHELL) -x "$(DC_VARS)" -f $(SYN_DIR)/scripts/dc_report.tcl 2>&1 | tee log/dc_report.log
	@echo "结果：$(RUN_DIR)/rpt/summary.rpt"

soc:
	$(MAKE) syn TOP=axi2flit_soc

target:
	$(MAKE) syn TOP=flit2hif_target

all: soc target

summary:
	@for f in run/*/rpt/summary.rpt; do echo "== $$(dirname $$(dirname $$f))"; cat $$f; echo; done

clean:
	rm -rf run

help:
	@sed -n '1,/^SHELL/p' Makefile | sed '$$d'

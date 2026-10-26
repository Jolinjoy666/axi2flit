# SystemC 部分只保留协议参考与 UCIe 链路接入：
#   - 消息编解码、帧格式的参考实现（include/），RTL 测试平台用它生成期望字节；
#   - UCIe 链路模型适配器（integration/ucie_aou_adapter.h），供 RTL 全链路联合仿真使用。
# 协议桥本身以 RTL 为准（rtl/），全链路联合仿真入口见 sim/Makefile 的 fl / fl-vcs。
SYSTEMC_HOME ?= $(HOME)/.local/systemc-2.3.4-cxx17

CXX      := g++
CXXFLAGS := -std=c++17 -Wall -g -I$(SYSTEMC_HOME)/include -I./include
CXXFLAGS += $(EXTRA_CXXFLAGS)
LDFLAGS  := -L$(SYSTEMC_HOME)/lib -lsystemc -lpthread -Wl,-rpath,$(SYSTEMC_HOME)/lib

TB_DIR   := tb
SIM_DIR  := sim
WIDTHS   := 256 512 1024

.PHONY: golden-all wire-all adapter ucie-unit config-check reference-check preflight clean

$(SIM_DIR):
	@mkdir -p $(SIM_DIR)

# 三种位宽的消息黄金向量对拍：将消息逐字节与独立固定向量比较，检查位域和数据排列。
golden-all: | $(SIM_DIR)
	@fail=0; \
	for w in $(WIDTHS); do \
	  echo "=============== 消息黄金向量对拍 AXI_DATA_WIDTH=$$w ==============="; \
	  $(CXX) $(CXXFLAGS) -DAXI_DATA_WIDTH_CFG=$$w $(TB_DIR)/tb_golden_vectors.cpp \
	      -o $(SIM_DIR)/golden_$$w $(LDFLAGS) || { fail=1; continue; }; \
	  ./$(SIM_DIR)/golden_$$w || fail=1; \
	done; \
	exit $$fail

# 帧头、字节映射与流解析回归。
wire-all: | $(SIM_DIR)
	@set -e; for w in $(WIDTHS); do \
	  $(CXX) $(CXXFLAGS) -DAXI_DATA_WIDTH_CFG=$$w $(TB_DIR)/tb_aou_wire.cpp \
	    -o $(SIM_DIR)/wire_$$w $(LDFLAGS); \
	  ./$(SIM_DIR)/wire_$$w; \
	done

# 链路模型目录可独立配置；UCIE_DIR 的相对路径以 systemc/ 为基准。
AXI2FLIT_SYSTEMC_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
UCIE_DIR ?= ../reference/ucie-model
UCIE_PATCH := $(AXI2FLIT_SYSTEMC_DIR)/integration/ucie-model-aou.patch
ADAPTER_FLAGS := -I./integration -I"$(UCIE_DIR)/src"

adapter: reference-check | $(SIM_DIR)
	$(CXX) $(CXXFLAGS) $(ADAPTER_FLAGS) $(TB_DIR)/tb_ucie_adapter.cpp -o $(SIM_DIR)/adapter $(LDFLAGS)
	./$(SIM_DIR)/adapter

ucie-unit: reference-check
	$(MAKE) -C "$(UCIE_DIR)" SYSTEMC_HOME="$(SYSTEMC_HOME)" \
	  AOU_INCLUDE="$(AXI2FLIT_SYSTEMC_DIR)/include" all unit-test

# 参数化回归：x8、PAM4、TAT=80ns。不复用默认配置的可执行文件，防止命中旧缓存。
config-check: reference-check | $(SIM_DIR)
	$(CXX) $(CXXFLAGS) $(ADAPTER_FLAGS) -DAOU_LINK_LANES=8 -DAOU_LINK_BITS_PER_SYMBOL=2 \
	  -DAOU_LINK_TAT_NS=80 $(TB_DIR)/tb_ucie_adapter.cpp -o $(SIM_DIR)/adapter_config $(LDFLAGS)
	./$(SIM_DIR)/adapter_config

# reference 不纳入主仓库。反向检查只读确认交付补丁已安装，缺失时给出操作入口。
reference-check:
	@git -C "$(UCIE_DIR)" apply --reverse --check "$(UCIE_PATCH)" || \
	  { echo "UCIe 接入补丁未安装或与本地修改冲突，请按 integration/README.md 检查。"; exit 1; }

preflight: reference-check
	$(MAKE) golden-all
	$(MAKE) wire-all
	$(MAKE) adapter
	$(MAKE) ucie-unit
	$(MAKE) config-check

clean:
	rm -f $(SIM_DIR)/wire_* $(SIM_DIR)/adapter* $(SIM_DIR)/golden_*
	@echo "清理完成"

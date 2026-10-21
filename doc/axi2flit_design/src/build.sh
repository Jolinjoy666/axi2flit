#!/usr/bin/env bash
# 重新生成设计文档：功能仿真 VCD → 波形图；框图；规范截图；docx。
# 用法：在工程根目录执行 doc/axi2flit_design/src/build.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SRC=$ROOT/doc/axi2flit_design/src
FIG=$ROOT/doc/axi2flit_design/figures
mkdir -p "$FIG"
make -C "$ROOT/sim" run WIDTH=1024 RP=1 ARGS=--trace
python3 "$SRC/vcd_extract.py" "$ROOT/sim/results/rtl_1024_rp1.vcd" "$FIG/wave.json" 3200
python3 "$SRC/crop_spec.py" "$ROOT/doc/AXI over UCIe Protocol Specification v0.8.pdf" "$FIG"
(cd "$SRC" && python3 figs_arch.py "$FIG" && python3 figs_mod.py "$FIG" && python3 figs_wave.py "$FIG" "$FIG/wave.json")
python3 "$SRC/build_docx.py" "$FIG" "$FIG" "$ROOT/doc/AXI2FLIT转接桥RTL设计文档.docx"

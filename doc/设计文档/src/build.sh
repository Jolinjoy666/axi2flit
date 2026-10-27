#!/usr/bin/env bash
# 生成 doc/设计文档/AXI2FLIT转接桥RTL设计文档.docx：
#   仿真 VCD → 波形图与延迟分解；框图；规范截图；实测结果汇总；docx。
# 用法（工程根目录）：bash doc/设计文档/src/build.sh
# 全链路部分需要 UCIe 链路模型（reference/ucie-model）。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SRC=$ROOT/doc/设计文档/src
FIG=$ROOT/doc/设计文档/figures
OUT=$ROOT/doc/设计文档/AXI2FLIT转接桥RTL设计文档.docx
LOG=${LOG_DIR:-/tmp/axi2flit_doc_log}
mkdir -p "$FIG" "$LOG"
export AXI_FIG_THEME=doc

# 1. 波形：独立环境功能测试（组帧、解帧、credit、背压）与全链路单拍读写（HIF 存储侧）
make -C "$ROOT/sim" run WIDTH=1024 RP=1 ARGS=--trace JOBS=${JOBS:-4}
make -C "$ROOT/sim" fl WIDTH=1024 RP=1 TC=1 FL_ARGS="--no-perf --vcd results/fl_probe_hif.vcd" JOBS=${JOBS:-4}

# 2. 实测数据：三类日志（check、fl-all、fl-ideal-all）。已存在则复用，避免重复跑回归。
if [ ! -f "$LOG/check.log" ] || [ "${RERUN:-0}" = 1 ]; then
  make -C "$ROOT/sim" check JOBS=${JOBS:-4} > "$LOG/check.log" 2>&1
  make -C "$ROOT/sim" fl-all JOBS=${JOBS:-4} > "$LOG/fl_all.log" 2>&1
  make -C "$ROOT/sim" fl-ideal-all JOBS=${JOBS:-4} > "$LOG/fl_ideal.log" 2>&1
fi

# 3. 图与数据
python3 "$SRC/crop_spec.py" "$ROOT/doc/AXI over UCIe Protocol Specification v0.8.pdf" "$FIG"
(cd "$SRC" && python3 figs_arch.py "$FIG" && python3 figs_mod.py "$FIG" && \
  python3 figs_wave.py "$FIG" "$ROOT/sim/results/rtl_1024_rp1.vcd" "$ROOT/sim/results/fl_probe_hif.vcd" > /dev/null && \
  python3 collect_results.py "$FIG/results.json" "$LOG/check.log" "$LOG/fl_all.log" "$LOG/fl_ideal.log")

# 4. docx
python3 "$SRC/build_docx.py" "$FIG" "$FIG" "$OUT"
echo "生成 $OUT"

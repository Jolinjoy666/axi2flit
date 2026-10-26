#!/usr/bin/env bash
# 扫描某一类接收深度，找出达到链路满载所需的最小值。
# 用法（在 sim 目录）：
#   scripts/credit_sweep.sh <参数名> <方向 read|write> "<深度列表>" [其他 make 变量...] [-- 运行参数]
# 例：scripts/credit_sweep.sh RDATA_DEPTH read "4 8 12 16 20 24" WIDTH=1024
#     scripts/credit_sweep.sh WDATA_DEPTH write "8 16 24" WIDTH=1024 -- --burst 4
# 输出每个深度对应的 credit 粒度数、实测带宽和相对理论上限的百分比；
# 最小满载深度取首个达到上限 99% 的深度。
set -euo pipefail
param=$1; dir=$2; depths=$3; shift 3
make_vars=(); run_args=""
while [ $# -gt 0 ]; do
    if [ "$1" = "--" ]; then shift; run_args="$*"; break; fi
    make_vars+=("$1"); shift
done
width=1024
for v in "${make_vars[@]}"; do case $v in WIDTH=*) width=${v#WIDTH=};; esac; done
# 每条全宽消息的 credit 粒度数（读数据 / 全选通写数据）；请求 3，写响应 1。
case $param in
    RDATA_DEPTH) g=$([ "$width" = 256 ] && echo 8 || ([ "$width" = 512 ] && echo 14 || echo 27));;
    WDATA_DEPTH) g=$([ "$width" = 256 ] && echo 7 || ([ "$width" = 512 ] && echo 14 || echo 27));;
    WREQ_DEPTH|RREQ_DEPTH) g=3;;
    WRESP_DEPTH) g=1;;
    *) echo "unknown parameter $param" >&2; exit 2;;
esac
printf "%-14s %8s %10s %12s %10s\n" "$param" credits GBps upper_GBps percent
min=""
for d in $depths; do
    line=$(make --no-print-directory scenario "${make_vars[@]}" "$param=$d" SCENARIO=saturated \
        ARGS="--direction $dir $run_args" 2>&1 | grep "^PERF $dir" || true)
    if [ -z "$line" ]; then printf "%-14s %8s %10s\n" "$d" "$((d*g))" "FAIL"; continue; fi
    bw=$(sed -E 's/.* GBps=([0-9.]+) .*/\1/' <<<"$line")
    up=$(sed -E 's/.*theoretical_upper_GBps=([0-9.]+).*/\1/' <<<"$line")
    pct=$(awk -v a="$bw" -v b="$up" 'BEGIN{printf "%.1f", a/b*100}')
    printf "%-14s %8s %10s %12s %9s%%\n" "$d" "$((d*g))" "$bw" "$up" "$pct"
    if [ -z "$min" ] && awk -v p="$pct" 'BEGIN{exit !(p>=99)}'; then min=$d; fi
done
echo "MIN_FULL_LOAD $param=${min:-none} (credits=$(( ${min:-0} * g )) granules)"

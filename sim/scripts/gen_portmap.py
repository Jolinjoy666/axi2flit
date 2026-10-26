#!/usr/bin/env python3
"""从 fl_rtl_top.sv 的端口列表生成 VCS -sc_portmap 文件：所有端口给出显式位宽，
1 位为 bool，2～64 位为 sc_bv，宽总线为 sc_bv。
用法：gen_portmap.py <fl_rtl_top.sv> <DATA_WIDTH> <MC_SLOTS> <输出文件>"""
import math
import re
import sys

src, width, slots, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
tw = max(1, math.ceil(math.log2(slots))) if slots > 1 else 1
env = {"DATA_WIDTH": width, "TW": tw, "aou_pkg::FLIT_BITS": 2000}
text = open(src).read()
header = re.sub(r"//[^\n]*", "", text[text.index(") (") + 3:text.index(");\n    import aou_pkg")])
lines = []
for decl in re.finditer(r"(input|output)\s+logic\s*(\[[^\]]+\])?\s*([^;]*?)(?=,\s*(?:input|output)|\s*$)",
                        header.replace("\n", " "), re.S):
    rng, names = decl.group(2), decl.group(3)
    bits = 1
    if rng:
        expr = rng[1:-1].rsplit(":", 1)[0]
        for k, v in sorted(env.items(), key=lambda kv: -len(kv[0])):
            expr = expr.replace(k, str(v))
        bits = int(eval(expr.replace("/", "//"))) + 1
    for name in re.split(r"\s*,\s*", names.strip()):
        name = name.strip()
        if not name:
            continue
        sc = "bool" if bits == 1 else "sc_bv"
        lines.append(f"{name:28s} {bits:5d}  {'bit' if bits == 1 else 'bit_vector':10s} {sc}")
open(out, "w").write("# 端口名 位宽 Verilog 类型 SystemC 类型（由 gen_portmap.py 生成）\n" + "\n".join(lines) + "\n")
print(f"{out}: {len(lines)} ports")

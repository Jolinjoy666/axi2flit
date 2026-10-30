#!/usr/bin/env python3
"""生成 Verdi 用的外层顶层 TOP：例化 tb_rtl_bridge 并传入与 Verilator 编译相同的参数。

Verilator 的 VCD 层次为 TOP.tb_rtl_bridge.*，vericom 编译出同名层次后，Verdi 才能把波形与源码对应起来。
用法：gen_verdi_top.py <输出文件> NAME=VALUE ...
"""
import sys

out, params = sys.argv[1], sys.argv[2:]
overrides = ",\n        ".join(f".{p.split('=', 1)[0]}({p.split('=', 1)[1]})" for p in params)
with open(out, "w") as f:
    f.write("// 自动生成，供 Verdi 加载设计库；端口悬空，波形取自 Verilator 的 VCD。\n")
    f.write("module TOP;\n")
    f.write(f"    tb_rtl_bridge #(\n        {overrides}\n    ) tb_rtl_bridge ();\n")
    f.write("endmodule\n")

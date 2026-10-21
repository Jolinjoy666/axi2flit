"""从功能仿真 VCD 中抽取作图所需信号，输出 JSON（时间单位 ns）。"""
import json, sys

SIGNALS = [
    "clk", "s_axi_awvalid", "s_axi_awready", "s_axi_wvalid", "s_axi_wready", "s_axi_wlast",
    "s_axi_arvalid", "s_axi_arready", "s_axi_bvalid", "s_axi_bready", "s_axi_rvalid",
    "s_axi_rready", "s_axi_rlast", "s_axi_rid", "s_axi_rdata", "mc_req_valid", "mc_req_ready",
    "mc_req_write", "mc_req_tag", "mc_rsp_valid", "mc_rsp_tag",
    "tb_rtl_bridge.fwd_valid", "tb_rtl_bridge.fwd_ready", "tb_rtl_bridge.rev_valid",
    "tb_rtl_bridge.rev_ready",
    "tb_rtl_bridge.soc.u_transport.u_tx.used", "tb_rtl_bridge.soc.u_transport.u_tx.spill_offset",
    "tb_rtl_bridge.soc.u_transport.u_tx.msg_ready[0]",
    "tb_rtl_bridge.soc.u_transport.u_rx.frame_count", "tb_rtl_bridge.soc.u_transport.u_rx.cursor",
    "tb_rtl_bridge.soc.u_transport.u_rx.flit_valid", "tb_rtl_bridge.soc.u_transport.u_rx.flit_ready",
    "tb_rtl_bridge.soc.u_transport.raw_valid", "tb_rtl_bridge.soc.u_transport.raw_ready",
    "tb_rtl_bridge.soc.u_transport.pending[0][3]", "tb_rtl_bridge.soc.u_transport.promised[0][3]",
    "tb_rtl_bridge.soc.u_transport.available[0][1]", "tb_rtl_bridge.soc.u_transport.u_rx.header_valid",
    "tb_rtl_bridge.soc.r_locked", "link_up", "rst_n",
]

def main(vcd, out, t_end_ns):
    path, codes, scale = [], {}, 1
    data = {s: [] for s in SIGNALS}
    with open(vcd) as f:
        for line in f:
            t = line.split()
            if not t:
                continue
            if t[0] == "$timescale":
                scale = {"1ps": 1e-3, "1ns": 1.0}[t[1]]
            elif t[0] == "$scope":
                path.append(t[2])
            elif t[0] == "$upscope":
                path.pop()
            elif t[0] == "$var":
                name = ".".join(path[1:] + [t[4]])
                if name in data:
                    codes.setdefault(t[3], []).append(name)
            elif t[0] == "$enddefinitions":
                break
        now = 0.0
        for line in f:
            c = line[0]
            if c == "#":
                now = int(line[1:]) * scale
                if now > t_end_ns:
                    break
            elif c in "01xz":
                for n in codes.get(line[1:].strip(), []):
                    data[n].append((now, 1 if c == "1" else 0))
            elif c == "b":
                v, code = line[1:].split()
                for n in codes.get(code, []):
                    val = int(v.replace("x", "0").replace("z", "0"), 2)
                    if n.endswith("rdata"):
                        val &= 0xFFFFFFFF
                    data[n].append((now, val))
    json.dump(data, open(out, "w"))

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], float(sys.argv[3]))

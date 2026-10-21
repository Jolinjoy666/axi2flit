"""由 VCD 抽取数据绘制灰度波形图，以及延迟、吞吐图。"""
import json
import sys
from matplotlib.patches import Polygon, Rectangle
from drawkit import Canvas, K, G0, G1, G2, G3, ACC, ERR

OUT = sys.argv[1]
DATA = json.load(open(sys.argv[2]))
T = "tb_rtl_bridge."
SOC = T + "soc.u_transport."


def series(key, t0, t1, fn=None):
    ch = DATA[key]
    v0 = 0
    for t, v in ch:
        if t <= t0:
            v0 = v
    pts = [(t0, v0)] + [(t, v) for t, v in ch if t0 < t < t1]
    if fn:
        pts = [(t, fn(v)) for t, v in pts]
    out = []
    for t, v in pts:
        if out and out[-1][1] == v:
            continue
        out.append((t, v))
    return out


def wave(name, t0, t1, rows, marks=(), width=17.0):
    lab_w, rh = 2.6, 0.62
    h = 0.95 + rh * len(rows) + 0.15
    c = Canvas(width, h)
    x0, x1 = lab_w, width - 0.45
    sx = (x1 - x0) / (t1 - t0)
    X = lambda t: x0 + (t - t0) * sx
    top = h - 0.75
    # 时间轴：偶数 ns 为上升沿
    first = int(t0) + (int(t0) % 2)
    for t in range(first, int(t1) + 1, 2):
        c.ax.plot([X(t)] * 2, [0.1, top], color="#e2e2e2", lw=0.5, zorder=0)
        if (t - first) % 4 == 0:
            c.text(X(t), top + 0.48, str(t), size=6.5, color=G3)
    c.text(x0 - 0.55, top + 0.48, "t / ns", size=6.5, color=G3, ha="right")
    for i, (label, key, kind, fn) in enumerate(rows):
        yc = top - (i + 0.5) * rh
        lo, hi = yc - rh * 0.28, yc + rh * 0.28
        c.text(x0 - 0.15, yc, label, size=7.5, ha="right")
        pts = series(key, t0, t1, fn)
        if kind == "bit":
            xs, ys = [], []
            for j, (t, v) in enumerate(pts):
                te = pts[j + 1][0] if j + 1 < len(pts) else t1
                y = hi if v else lo
                if v:
                    c.ax.add_patch(Rectangle((X(t), lo), X(te) - X(t), hi - lo, fc=G1, ec="none", zorder=1))
                xs += [X(t), X(te)]
                ys += [y, y]
            c.ax.plot(xs, ys, color=K, lw=0.9, zorder=3)
        else:
            d = 0.06
            for j, (t, v) in enumerate(pts):
                te = pts[j + 1][0] if j + 1 < len(pts) else t1
                a, b = X(t), X(te)
                ld = d if j else 0
                rd = d if j + 1 < len(pts) else 0
                poly = [(a, yc), (a + ld, hi), (b - rd, hi), (b, yc), (b - rd, lo), (a + ld, lo)]
                c.ax.add_patch(Polygon(poly, fc=G0, ec=K, lw=0.7, zorder=2))
                txt = v if isinstance(v, str) else (f"{v:x}" if kind == "hex" else str(v))
                if b - a > 0.32 + 0.09 * len(txt):
                    c.text((a + b) / 2, yc, txt, size=6.5, zorder=4)
    for k, (t, s) in enumerate(marks):
        c.ax.plot([X(t)] * 2, [0.1, top], color=ACC, lw=0.8, ls="--", zorder=5)
        c.badge(X(t), top + 0.12, s, r=0.16, size=6.5)
    c.save(f"{OUT}/{name}.png")


B = lambda bit: (lambda v: (v >> bit) & 1)


def all_waves():
    wave("w_read", 172, 214, [
        ("ARVALID", "s_axi_arvalid", "bit", None), ("ARREADY", "s_axi_arready", "bit", None),
        ("SoC flit_tx_valid", T + "fwd_valid", "bit", None),
        ("mc_req_valid", "mc_req_valid", "bit", None), ("mc_rsp_valid", "mc_rsp_valid", "bit", None),
        ("Target flit_tx_valid", T + "rev_valid", "bit", None),
        ("SoC flit_rx_valid", SOC + "u_rx.flit_valid", "bit", None),
        ("RVALID", "s_axi_rvalid", "bit", None), ("RLAST", "s_axi_rlast", "bit", None)],
        marks=[(176, "1"), (182, "2"), (190, "3"), (194, "4"), (204, "5"), (210, "6")])
    wave("w_write", 208, 254, [
        ("AWVALID", "s_axi_awvalid", "bit", None), ("WVALID", "s_axi_wvalid", "bit", None),
        ("WREADY", "s_axi_wready", "bit", None), ("WLAST", "s_axi_wlast", "bit", None),
        ("SoC flit_tx_valid", T + "fwd_valid", "bit", None),
        ("mc_req_valid", "mc_req_valid", "bit", None), ("mc_req_write", "mc_req_write", "bit", None),
        ("mc_rsp_valid", "mc_rsp_valid", "bit", None),
        ("Target flit_tx_valid", T + "rev_valid", "bit", None),
        ("BVALID", "s_axi_bvalid", "bit", None)],
        marks=[(212, "1"), (214, "2"), (220, "3"), (230, "4"), (250, "5")])
    wave("w_tx", 458, 496, [
        ("WVALID", "s_axi_wvalid", "bit", None), ("WREADY", "s_axi_wready", "bit", None),
        ("WDATA 出队", SOC + "u_tx.msg_ready[0]", "bit", B(2)),
        ("used", SOC + "u_tx.used", "dec", None),
        ("spill_offset", SOC + "u_tx.spill_offset", "dec", None),
        ("flit_tx_valid", T + "fwd_valid", "bit", None)],
        marks=[(466, "1"), (468, "2")])
    wave("w_rx", 554, 590, [
        ("flit_rx_valid", SOC + "u_rx.flit_valid", "bit", None),
        ("frame_count", SOC + "u_rx.frame_count", "dec", None),
        ("cursor", SOC + "u_rx.cursor", "dec", None),
        ("msg_valid", SOC + "raw_valid", "bit", None),
        ("RVALID", "s_axi_rvalid", "bit", None)],
        marks=[(560, "1"), (564, "2")])
    wave("w_credit", 6, 46, [
        ("rst_n", "rst_n", "bit", None), ("link_up", "link_up", "bit", None),
        ("flit_tx_valid", T + "fwd_valid", "bit", None),
        ("pending RDATA", SOC + "pending[0][3]", "dec", None),
        ("promised RDATA", SOC + "promised[0][3]", "dec", None),
        ("header_valid", SOC + "u_rx.header_valid", "bit", None),
        ("available RREQ", SOC + "available[0][1]", "dec", None)],
        marks=[(16, "1"), (20, "2")])
    wave("w_stall", 2962, 2998, [
        ("RVALID", "s_axi_rvalid", "bit", None), ("RREADY", "s_axi_rready", "bit", None),
        ("r_locked", T + "soc.r_locked", "bit", None),
        ("RID", "s_axi_rid", "dec", None), ("RDATA[15:0]", "s_axi_rdata", "hex", lambda v: v & 0xFFFF)],
        marks=[(2972, "1"), (2980, "2")])


def fig_latency():
    c = Canvas(16, 3.6)
    segs = [("SoC TX", 6, G1, True), ("链路", 10, "white", False), ("Target 请求", 8, G1, True),
            ("MC", 6, "white", False), ("Target 返回", 8, G1, True), ("链路", 10, "white", False),
            ("SoC RX", 6, G1, True)]
    total = sum(s[1] for s in segs)
    x0, x1 = 0.4, 15.6
    sx = (x1 - x0) / total
    x = x0
    for name, ns, fill, own in segs:
        w = ns * sx
        c.box(x, 1.3, w, 0.9, "", fill=fill, ec=K if own else G3, ls="-" if own else "--",
              lw=1.0 if own else 0.8)
        c.text(x + w / 2, 1.75, name, size=7.5, color=K if own else G3)
        if own:
            c.text(x + w / 2, 0.95, f"{ns} ns", size=7.5, weight="bold")
        x += w
    c.arrow([(x0, 2.75), (x1, 2.75)], lw=0.8)
    c.text(x0, 3.1, "AR", size=7.5, ha="left")
    c.text(x1, 3.1, "R", size=7.5, ha="right")
    c.save(f"{OUT}/f_latency.png")


def fig_throughput():
    import matplotlib.pyplot as plt
    fig = plt.figure(figsize=(15 / 2.54, 7 / 2.54))
    ax = fig.add_axes([0.09, 0.12, 0.89, 0.78])
    cats = ["256 位", "512 位", "1024 位"]
    rd = [16.0, 32.0, 42.6669]
    wr = [15.0588, 30.1176, 42.3731]
    xs = range(3)
    ax.bar([x - 0.18 for x in xs], rd, 0.34, color="#4d4d4d", label="读", zorder=3)
    ax.bar([x + 0.18 for x in xs], wr, 0.34, color="#b3b3b3", label="写", zorder=3)
    ax.axhline(45, color=K, lw=0.8, ls="--")
    ax.axhline(40.5, color=ACC, lw=0.9, ls="--")
    ax.set_xlim(-0.55, 2.95)
    ax.text(2.93, 45.7, "45 GB/s", fontsize=7, color=K, ha="right")
    ax.text(2.93, 38.3, "90%", fontsize=7, color=ACC, ha="right")
    for x, a, b in zip(xs, rd, wr):
        ax.text(x - 0.18, a + 0.8, f"{a:.1f}", fontsize=7, ha="center")
        ax.text(x + 0.18, b + 0.8, f"{b:.1f}", fontsize=7, ha="center")
    ax.set_xticks(list(xs))
    ax.set_xticklabels(cats, fontsize=8)
    ax.set_ylim(0, 50)
    ax.set_ylabel("GB/s", fontsize=8)
    ax.tick_params(labelsize=7.5)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    ax.grid(axis="y", color="#e6e6e6", lw=0.5, zorder=0)
    ax.legend(fontsize=7.5, frameon=False, loc="upper left", ncol=2, bbox_to_anchor=(0.0, 1.08))
    fig.savefig(f"{OUT}/f_throughput.png", dpi=300, facecolor="white")
    plt.close(fig)


if __name__ == "__main__":
    all_waves()
    fig_latency()
    fig_throughput()

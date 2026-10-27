"""波形图（由 VCD 自动定位事件）以及延迟、吞吐、深度扫描图。

用法：python3 figs_wave.py <输出目录> <独立测试 VCD> <全链路 VCD>
同时写出 <输出目录>/wave_marks.json，正文引用的时刻和数值都取自这里，保证图文一致。
"""
import json
import sys
from matplotlib.patches import Polygon, Rectangle
from drawkit import Canvas, K, G0, G1, G2, G3, ACC, ERR, BAR1, BAR2
from vcdlib import read_vcd, value_at

OUT = sys.argv[1]
SA_VCD, FL_VCD = sys.argv[2], sys.argv[3]
MARKS = {}

# 2000 位 PLP 中 MsgStart 所在的位（见 aou_pkg::get_starts），任一位为 1 表示帧内有消息。
_MS = [(1999, 4), (1991, 8), (1983, 4), (1975, 8), (1951, 4), (1943, 8), (1935, 4), (1927, 8)]
MSG_MASK = 0
for hi, n in _MS:
    MSG_MASK |= ((1 << n) - 1) << (hi - n + 1)


def edges(t0, t1):
    t = int(t0) + (int(t0) % 2)
    while t <= t1:
        yield t
        t += 2


def hs_series(v, r, extra=None):
    """valid & ready（可再与 extra 相与）的分段序列，用于画握手脉冲。"""
    ts = sorted({t for t, _ in v} | {t for t, _ in r} | ({t for t, _ in extra} if extra else set()))
    out = []
    for t in ts:
        val = value_at(v, t + 1e-9) and value_at(r, t + 1e-9) and (value_at(extra, t + 1e-9) if extra else 1)
        out.append((t, 1 if val else 0))
    return out


def first_edge(after, cond, limit=100000):
    for t in edges(after + 0.5, after + limit):
        if cond(t):
            return t
    raise RuntimeError("event not found")


def wave(name, t0, t1, rows, marks=(), spans=(), width=17.0):
    """rows: (标签, 序列, 类型, 变换)；序列为 [(t, v)]。"""
    lab_w, rh = 2.9, 0.6
    top_extra = 1.5 if spans else 0.85
    h = top_extra + 0.15 + rh * len(rows)
    c = Canvas(width, h)
    x0, x1 = lab_w, width - 0.4
    sx = (x1 - x0) / (t1 - t0)
    X = lambda t: x0 + (t - t0) * sx
    top = h - top_extra + 0.1
    step = 2 if (t1 - t0) <= 60 else 4
    first = int(t0) + (int(t0) % 2)
    for t in range(first, int(t1) + 1, 2):
        c.ax.plot([X(t)] * 2, [0.1, top], color="#e4e4e4", lw=0.5, zorder=0)
        if (t - first) % (2 * step) == 0:
            c.text(X(t), top + 0.45, str(t), size=6.5, color=G3)
    c.text(x0 - 0.5, top + 0.45, "t / ns", size=6.5, color=G3, ha="right")
    mark_x = [X(t) for t, _ in marks]
    for i, (label, ch, kind, fn) in enumerate(rows):
        yc = top - (i + 0.5) * rh
        lo, hi = yc - rh * 0.28, yc + rh * 0.28
        c.text(x0 - 0.15, yc, label, size=7.5, ha="right")
        v0 = value_at(ch, t0 + 1e-9)
        pts = [(t0, v0)] + [(t, v) for t, v in ch if t0 < t < t1]
        if fn:
            pts = [(t, fn(v)) for t, v in pts]
        seg = []
        for t, v in pts:
            if not seg or seg[-1][1] != v:
                seg.append((t, v))
        if kind == "bit":
            xs, ys = [], []
            for j, (t, v) in enumerate(seg):
                te = seg[j + 1][0] if j + 1 < len(seg) else t1
                y = hi if v else lo
                if v:
                    c.ax.add_patch(Rectangle((X(t), lo), X(te) - X(t), hi - lo, fc=G1, ec="none", zorder=1))
                xs += [X(t), X(te)]
                ys += [y, y]
            c.ax.plot(xs, ys, color=K, lw=0.9, zorder=3)
        else:
            d = 0.06
            for j, (t, v) in enumerate(seg):
                te = seg[j + 1][0] if j + 1 < len(seg) else t1
                a, b = X(t), X(te)
                ld = d if j else 0
                rd = d if j + 1 < len(seg) else 0
                c.ax.add_patch(Polygon([(a, yc), (a + ld, hi), (b - rd, hi), (b, yc), (b - rd, lo), (a + ld, lo)],
                                       fc=G0, ec=K, lw=0.7, zorder=2))
                txt = f"{v:x}" if kind == "hex" else str(v)
                need = 0.3 + 0.09 * len(txt)
                # 数值标签避开标记虚线：放在被虚线分开的最宽一段的中点。
                cuts = [a] + sorted(mx for mx in mark_x if a < mx < b) + [b]
                pa, pb = max(zip(cuts, cuts[1:]), key=lambda p: p[1] - p[0])
                if len(cuts) > 2 and pb - pa < need:
                    pa, pb = a, b
                if b - a > need:
                    c.text((pa + pb) / 2, yc, txt, size=6.5, zorder=4)
    for k, (t, s) in enumerate(marks):
        c.ax.plot([X(t)] * 2, [0.1, top], color=ACC, lw=0.8, ls="--", zorder=5)
        c.badge(X(t), top + 0.12, s, r=0.16, size=6.5)
    for a, b, s in spans:
        y = top + 0.85
        c.arrow([(X(a) + 0.03, y), (X(b) - 0.03, y)], color=ACC, lw=0.7, both=True)
        c.text((X(a) + X(b)) / 2, y + 0.2, s, size=6.5, color=ACC)
    c.save(f"{OUT}/{name}.png")


# ---------------- 全链路：空载单拍读、写（存储侧为 HIF） ----------------
def fulllink():
    F = "fl_rtl_top."
    names = ["tb_case", "s_axi_arvalid", "s_axi_arready", "s_axi_wvalid", "s_axi_wready", "s_axi_wlast",
             "s_axi_rvalid", "s_axi_rready", "s_axi_rlast", "s_axi_bvalid", "s_axi_bready",
             "soc_flit_tx_valid", "soc_flit_tx_ready", "soc_flit_tx_data",
             "tgt_flit_rx_valid", "tgt_flit_rx_ready", "tgt_flit_rx_data",
             "tgt_flit_tx_valid", "tgt_flit_tx_ready", "tgt_flit_tx_data",
             "soc_flit_rx_valid", "soc_flit_rx_ready", "soc_flit_rx_data",
             "hif_cmd_valid", "hif_cmd_stall", "hif_rdata_valid", "hif_rdata_end", "hif_rdata_token",
             "hif_wdata_valid", "hif_wdata_stall", "hif_wdata_end", "hif_wdata_ptr_valid"]
    d = {k[len(F):]: v for k, v in read_vcd(FL_VCD, [F + n for n in names], 2000).items()}
    at = lambda n, t: value_at(d[n], t)
    hs = lambda p, t: at(p + "_valid", t) and at(p + "_ready", t)
    msg = lambda p, t: hs(p, t) and (at(p + "_data", t) & MSG_MASK) != 0
    cmd = lambda t: at("hif_cmd_valid", t) and not at("hif_cmd_stall", t)
    rd_end = lambda t: at("hif_rdata_valid", t) and at("hif_rdata_end", t)
    wd_end = lambda t: at("hif_wdata_valid", t) and not at("hif_wdata_stall", t) and at("hif_wdata_end", t)
    t_probe = next(t for t, v in d["tb_case"] if v == 20)

    def probe(write, start):
        """8 个时刻；第 4 个取送出响应帧之前最后一行数据的末拍（一拍可对应多条 HIF 命令）。"""
        first = (lambda t: at("s_axi_wvalid", t) and at("s_axi_wready", t) and at("s_axi_wlast", t)) if write else \
                (lambda t: at("s_axi_arvalid", t) and at("s_axi_arready", t))
        last = (lambda t: at("s_axi_bvalid", t) and at("s_axi_bready", t)) if write else \
               (lambda t: at("s_axi_rvalid", t) and at("s_axi_rready", t) and at("s_axi_rlast", t))
        ts = [first_edge(start - 1, first)]
        ts.append(first_edge(ts[-1], lambda t: msg("soc_flit_tx", t)))
        ts.append(first_edge(ts[-1], lambda t: msg("tgt_flit_rx", t)))
        ts.append(first_edge(ts[-1], cmd))
        t5 = first_edge(ts[-1], lambda t: msg("tgt_flit_tx", t))
        ends = [t for t in edges(ts[-1] + 0.5, t5 - 0.5) if (wd_end(t) if write else rd_end(t))]
        ts.append(ends[-1])
        ts.append(t5)
        ts.append(first_edge(t5, lambda t: msg("soc_flit_rx", t)))
        ts.append(first_edge(ts[-1], last))
        return ts

    names_seg = ["SoC 发送", "链路", "存储侧请求", "HIF 控制器", "存储侧返回", "链路", "SoC 接收"]
    out = {}
    for write in (False, True):
        ts = probe(write, t_probe if not write else out["read"]["t"][-1])
        segs = [ts[i + 1] - ts[i] for i in range(7)]
        key = "write" if write else "read"
        out[key] = {"t": ts, "seg": segs, "total": ts[-1] - ts[0]}
        hsr = lambda p: hs_series(d[p + "_valid"], d[p + "_ready"])
        cmd_s = hs_series(d["hif_cmd_valid"], [(t, 1 - v) for t, v in d["hif_cmd_stall"]])
        if write:
            rows = [("W 握手（WLAST）", hs_series(d["s_axi_wvalid"], d["s_axi_wready"], d["s_axi_wlast"]), "bit"),
                    ("SoC 发出帧", hsr("soc_flit_tx"), "bit"), ("存储侧收到帧", hsr("tgt_flit_rx"), "bit"),
                    ("HIF 命令", cmd_s, "bit"), ("写指针回送", d["hif_wdata_ptr_valid"], "bit"),
                    ("HIF 写数据", hs_series(d["hif_wdata_valid"], [(t, 1 - v) for t, v in d["hif_wdata_stall"]]), "bit"),
                    ("存储侧发出帧", hsr("tgt_flit_tx"), "bit"), ("SoC 收到帧", hsr("soc_flit_rx"), "bit"),
                    ("B 握手", hs_series(d["s_axi_bvalid"], d["s_axi_bready"]), "bit")]
        else:
            rows = [("AR 握手", hs_series(d["s_axi_arvalid"], d["s_axi_arready"]), "bit"),
                    ("SoC 发出帧", hsr("soc_flit_tx"), "bit"), ("存储侧收到帧", hsr("tgt_flit_rx"), "bit"),
                    ("HIF 命令", cmd_s, "bit"), ("HIF 读数据", d["hif_rdata_valid"], "bit"),
                    ("读数据 token", d["hif_rdata_token"], "dec"),
                    ("存储侧发出帧", hsr("tgt_flit_tx"), "bit"), ("SoC 收到帧", hsr("soc_flit_rx"), "bit"),
                    ("R 握手（RLAST）", hs_series(d["s_axi_rvalid"], d["s_axi_rready"], d["s_axi_rlast"]), "bit")]
        rows = [(lab, ch, kind, None) for lab, ch, kind in rows]
        marks = [(t, str(i + 1)) for i, t in enumerate(ts)]
        spans = [(ts[i], ts[i + 1], f"{segs[i]}") for i in range(7)]
        wave("w_fl_write" if write else "w_fl_read", ts[0] - 6, ts[-1] + 6, rows, marks, spans)
    MARKS["fl"] = out
    MARKS["fl_seg_names"] = names_seg


# ---------------- 独立测试：组帧、解帧、credit 初始化、R 背压 ----------------
def standalone():
    S = "tb_rtl_bridge.soc.u_transport."
    names = ["rst_n", "link_up", "s_axi_awvalid", "s_axi_awready", "s_axi_awlen", "s_axi_wvalid", "s_axi_wready",
             "s_axi_arvalid", "s_axi_arready", "s_axi_arlen", "s_axi_rvalid", "s_axi_rready", "s_axi_rid",
             "s_axi_rdata", "tb_rtl_bridge.fwd_valid", "tb_rtl_bridge.soc.r_locked",
             S + "u_tx.used", S + "u_tx.spill_offset", S + "u_tx.msg_ready[0]",
             S + "u_rx.flit_valid", S + "u_rx.frame_count", S + "u_rx.cursor", S + "raw_valid",
             S + "pending[0][3]", S + "promised[0][3]", S + "available[0][1]", S + "u_rx.header_valid"]
    d = read_vcd(SA_VCD, names, 9000)
    d["s_axi_rdata"] = [(t, v & 0xFFFF) for t, v in d["s_axi_rdata"]]
    at = lambda n, t: value_at(d[n], t)

    # credit 初始化
    t_up = next(t for t, v in d["link_up"] if v == 1)
    t1 = next(t for t, v in d["tb_rtl_bridge.fwd_valid"] if t > t_up and v == 1)   # 第一帧出现在输出端
    t2 = first_edge(t_up, lambda t: at(S + "u_rx.header_valid", t))
    pend = d[S + "pending[0][3]"]
    p0 = max(v for t, v in pend if t < t_up + 40)
    t_zero = next(t for t, v in pend if t > t1 and v == 0)
    av = [v for t, v in d[S + "available[0][1]"] if t < t_up + 60]
    wave("w_credit", 4, t_zero + 10, [
        ("rst_n", d["rst_n"], "bit", None), ("link_up", d["link_up"], "bit", None),
        ("flit_tx_valid", d["tb_rtl_bridge.fwd_valid"], "bit", None),
        ("pending RDATA", pend, "dec", None), ("promised RDATA", d[S + "promised[0][3]"], "dec", None),
        ("header_valid", d[S + "u_rx.header_valid"], "bit", None),
        ("available RREQ", d[S + "available[0][1]"], "dec", None)],
        marks=[(t1, "1"), (t2, "2")])
    MARKS["credit"] = {"link_up": t_up, "t1": t1, "t2": t2, "pending0": p0, "t_zero": t_zero,
                       "rreq_steps": sorted(set(av))}

    # 组帧：第一笔 16 拍写突发中第一次出现跨帧
    t_aw = first_edge(0, lambda t: at("s_axi_awvalid", t) and at("s_axi_awready", t) and at("s_axi_awlen", t) == 15)
    t_sp = next(t for t, v in d[S + "u_tx.spill_offset"] if t > t_aw and v > 0)
    used_before = value_at(d[S + "u_tx.used"], t_sp)
    spill = value_at(d[S + "u_tx.spill_offset"], t_sp + 0.5)
    used_after = value_at(d[S + "u_tx.used"], t_sp + 2.5)
    wave("w_tx", t_sp - 8, t_sp + 30, [
        ("WVALID", d["s_axi_wvalid"], "bit", None), ("WREADY", d["s_axi_wready"], "bit", None),
        ("WDATA 出队", d[S + "u_tx.msg_ready[0]"], "bit", lambda v: (v >> 2) & 1),
        ("used", d[S + "u_tx.used"], "dec", None), ("spill_offset", d[S + "u_tx.spill_offset"], "dec", None),
        ("flit_tx_valid", d["tb_rtl_bridge.fwd_valid"], "bit", None)],
        marks=[(t_sp, "1"), (t_sp + 2, "2")])
    MARKS["tx"] = {"t1": t_sp, "t2": t_sp + 2, "used_before": used_before, "spill": spill, "used_after": used_after}

    # 解帧：第一笔 16 拍读突发的返回
    t_ar = first_edge(0, lambda t: at("s_axi_arvalid", t) and at("s_axi_arready", t) and at("s_axi_arlen", t) == 15)
    cur = d[S + "u_rx.cursor"]
    # 取一次真正的跨帧拼接：cursor 从 27 变为 1～26（新帧中续片占用的粒度数）
    pairs = [(cur[i - 1][0], cur[i][0]) for i in range(1, len(cur))
             if cur[i][0] > t_ar and cur[i - 1][1] == 27 and 0 < cur[i][1] < 27]
    t_c1, t_c2 = pairs[0]
    c2 = value_at(cur, t_c2 + 0.5)
    wave("w_rx", t_c1 - 6, t_c1 + 30, [
        ("flit_rx_valid", d[S + "u_rx.flit_valid"], "bit", None),
        ("frame_count", d[S + "u_rx.frame_count"], "dec", None),
        ("cursor", cur, "dec", None), ("msg_valid", d[S + "raw_valid"], "bit", None),
        ("RVALID", d["s_axi_rvalid"], "bit", None)],
        marks=[(t_c1, "1"), (t_c2, "2")])
    MARKS["rx"] = {"t1": t_c1, "t2": t_c2, "cursor2": c2}

    # R 通道背压
    t_l = next(t for t, v in d["tb_rtl_bridge.soc.r_locked"] if v == 1)
    t_go = first_edge(t_l, lambda t: at("s_axi_rvalid", t) and at("s_axi_rready", t))
    wave("w_stall", t_l - 10, t_go + 18, [
        ("RVALID", d["s_axi_rvalid"], "bit", None), ("RREADY", d["s_axi_rready"], "bit", None),
        ("r_locked", d["tb_rtl_bridge.soc.r_locked"], "bit", None),
        ("RID", d["s_axi_rid"], "dec", None), ("RDATA[15:0]", d["s_axi_rdata"], "hex", None)],
        marks=[(t_l, "1"), (t_go, "2")])
    MARKS["stall"] = {"t1": t_l, "t2": t_go}


# ---------------- 延迟分解、吞吐与深度扫描 ----------------
def fig_latency():
    segs = MARKS["fl"]["read"]["seg"]
    names = ["SoC 发送", "链路", "存储侧请求", "HIF 控制器", "存储侧返回", "链路", "SoC 接收"]
    own = [True, False, True, False, True, False, True]
    c = Canvas(16, 3.7)
    total = sum(segs)
    x0, x1 = 0.4, 15.6
    sx = (x1 - x0) / total
    x = x0
    for name, ns, o in zip(names, segs, own):
        w = ns * sx
        c.box(x, 1.3, w, 0.9, "", fill=G1 if o else "white", ec=K if o else G3, ls="-" if o else "--",
              lw=1.0 if o else 0.8)
        c.text(x + w / 2, 1.75, name, size=7 if w > 1.2 else 6.5, color=K if o else G3)
        c.text(x + w / 2, 0.95, f"{ns} ns", size=7.5, weight="bold" if o else "normal", color=K if o else G3)
        x += w
    c.arrow([(x0, 2.75), (x1, 2.75)], lw=0.8, both=True)
    c.text((x0 + x1) / 2, 3.1, f"AR 握手 → R 握手：{total} ns", size=7.5)
    c.save(f"{OUT}/f_latency.png")


def _axes(w_cm, h_cm):
    import matplotlib.pyplot as plt
    fig = plt.figure(figsize=(w_cm / 2.54, h_cm / 2.54))
    ax = fig.add_axes([0.1, 0.15, 0.87, 0.75])
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    ax.tick_params(labelsize=7.5)
    ax.grid(axis="y", color="#e6e6e6", lw=0.5, zorder=0)
    return plt, fig, ax


def fig_throughput(rows):
    """rows: [(场景, 满速 MC 模型, HIF)]，全链路 1024 位实测。"""
    plt, fig, ax = _axes(15, 7)
    xs = range(len(rows))
    full = [r[1] for r in rows]
    hif = [r[2] for r in rows]
    ax.bar([x - 0.18 for x in xs], full, 0.34, color=BAR1, label="满速 MC 模型（桥 + 链路上限）", zorder=3)
    ax.bar([x + 0.18 for x in xs], hif, 0.34, color=BAR2, label="HIF 256 位单通道", zorder=3)
    # 两条上限线放进图例，避免与柱顶数值重叠。
    ax.axhline(45, color=K, lw=0.8, ls="--", label="链路消息区 45 GB/s")
    ax.axhline(16, color=ACC, lw=0.9, ls="--", label="HIF 数据口 16 GB/s")
    ax.set_xlim(-0.55, len(rows) - 0.45)
    for x, a, b in zip(xs, full, hif):
        ax.text(x - 0.18, a - 3.0, f"{a:.2f}", fontsize=6.5, ha="center", color="white", zorder=4)
        ax.text(x + 0.18, b - 3.0, f"{b:.2f}", fontsize=6.5, ha="center", color=K, zorder=4)
    ax.set_xticks(list(xs))
    ax.set_xticklabels([r[0] for r in rows], fontsize=8)
    ax.set_ylim(0, 58)
    ax.set_yticks(range(0, 51, 10))
    ax.set_ylabel("GB/s", fontsize=8)
    ax.legend(fontsize=7.5, frameon=False, loc="upper left", ncol=2, bbox_to_anchor=(0.0, 1.04))
    fig.savefig(f"{OUT}/f_throughput.png", dpi=300, facecolor="white")
    plt.close(fig)


def fig_sweep(rdata, wdata):
    plt, fig, ax = _axes(15, 6.5)
    ax.plot([d for d, _ in rdata], [g for _, g in rdata], "-o", color=BAR1, ms=3.5, lw=1.1,
            label="读（RDATA_DEPTH）", zorder=3)
    ax.plot([d for d, _ in wdata], [g for _, g in wdata], "--s", color=BAR2, ms=3.5, lw=1.1,
            label="写（WDATA_DEPTH）", zorder=3)
    ax.axhline(42.67, color=K, lw=0.6, ls=":")
    ax.axvline(20, color=ACC, lw=0.9, ls="--")
    ax.text(20.4, 22, "满载最小 20", fontsize=7, color=ACC)
    ax.axvline(24, color=ACC, lw=0.9, ls=":")
    ax.text(24.4, 18.5, "默认 24", fontsize=7, color=ACC)
    ax.set_xlabel("接收深度（条）", fontsize=8)
    ax.set_ylabel("GB/s", fontsize=8)
    ax.set_ylim(15, 46)
    ax.legend(fontsize=7.5, frameon=False, loc="lower right")
    fig.savefig(f"{OUT}/f_sweep.png", dpi=300, facecolor="white")
    plt.close(fig)


if __name__ == "__main__":
    fulllink()
    standalone()
    fig_latency()
    import os
    data = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf_data.json")))
    fig_throughput(data["throughput"])
    fig_sweep(data["sweep_rdata"], data["sweep_wdata"])
    json.dump(MARKS, open(f"{OUT}/wave_marks.json", "w"), ensure_ascii=False, indent=1)
    print(json.dumps(MARKS, ensure_ascii=False))

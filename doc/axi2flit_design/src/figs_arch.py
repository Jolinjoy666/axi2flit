"""系统、模块层次与各模块微架构图。"""
import sys
from drawkit import Canvas, K, G0, G1, G2, G3, ACC, ERR

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
CTL = dict(color=ACC, ls="--", lw=0.9)


def fig_system():
    c = Canvas(17, 3.9)
    y, h = 1.05, 1.35
    blocks = [("SoC\nAXI 主机", 0.25, 1.45, 0), ("axi2flit_soc", 2.3, 2.3, 1),
              ("D2D\n+ PHY", 5.2, 1.2, 0), ("D2D\n+ PHY", 9.0, 1.2, 0),
              ("flit2mc_target", 10.8, 2.5, 1), ("MC", 13.9, 1.1, 0), ("DRAM", 15.6, 1.15, 0)]
    for name, x, w, own in blocks:
        if own:
            c.box(x, y, w, h, name, lw=1.8, weight="bold", size=9)
        else:
            c.box(x, y, w, h, name, fill=G1, ec=G3, color="#444444", size=8.5)
    links = [(1.7, 2.3, "AXI4"), (4.6, 5.2, "Flit"), (6.4, 9.0, "UCIe 链路"),
             (10.2, 10.8, "Flit"), (13.3, 13.9, "MC"), (15.0, 15.6, "DFI")]
    for x0, x1, lab in links:
        c.arrow([(x0 + 0.04, y + h / 2), (x1 - 0.04, y + h / 2)], both=True, lw=1.1)
        c.text((x0 + x1) / 2, y + h / 2 + 0.28, lab, size=7.5, color=G3)
    c.frame(0.1, 0.35, 6.45, 3.3, "SoC Die", ls=(0, (4, 3)))
    c.frame(8.85, 0.35, 8.05, 3.3, "存储 Die", ls=(0, (4, 3)))
    c.save(f"{OUT}/f_system.png")


def fig_hierarchy():
    c = Canvas(15, 8.6)
    col = [0.3, 4.3, 9.4]
    wid = [3.2, 4.3, 4.3]
    rh, h = 0.82, 0.6

    def node(ci, row, inst, mod, bold=False, fill=G0):
        x, y = col[ci], 8.6 - 0.55 - row * rh
        c.box(x, y - h / 2, wid[ci], h, fill=fill, lw=1.6 if bold else 0.9)
        if inst:
            c.text(x + 0.15, y, inst, size=8, color=G3, ha="left")
            c.text(x + wid[ci] - 0.15, y, mod, size=8.5, ha="right")
        else:
            c.text(x + wid[ci] / 2, y, mod, size=9, weight="bold")
        return x, y

    def branch(parent, kids):
        px = parent[0] + 0.45
        top = parent[1] - h / 2
        c.arrow([(px, top), (px, kids[-1][1])], head=False, lw=0.8)
        for k in kids:
            c.arrow([(px, k[1]), (k[0], k[1])], head=False, lw=0.8)

    soc = node(0, 0, "", "axi2flit_soc", bold=True)
    a = node(1, 1, "u_write_route", "aou_sync_fifo")
    b = node(1, 2, "u_fifo ×3·RP", "aou_sync_fifo", fill=G1)
    t1 = node(1, 3, "u_transport", "aou_transport")
    branch(soc, [a, b, t1])
    kids = [node(2, 4, "u_tx", "aou_flit_tx"), node(2, 5, "u_rx", "aou_flit_rx"),
            node(2, 6, "u_fifo ×2·RP", "aou_sync_fifo", fill=G1)]
    branch(t1, kids)
    tgt = node(0, 7, "", "flit2mc_target", bold=True)
    d = node(1, 8, "u_fifo ×2·RP", "aou_sync_fifo", fill=G1)
    t2 = node(1, 9, "u_transport", "aou_transport")
    branch(tgt, [d, t2])
    c.text(col[2] + 0.2, t2[1], "结构同上，接收 FIFO ×3·RP", size=8, color=G3, ha="left")
    c.arrow([(t2[0] + wid[1], t2[1]), (col[2] + 0.1, t2[1])], head=False, lw=0.8, ls=":")
    c.save(f"{OUT}/f_hierarchy.png")


def fig_soc():
    c = Canvas(17, 10.4)
    c.frame(1.25, 0.2, 13.15, 9.95, "axi2flit_soc")
    A, B, C = 1.7, 3.95, 6.35
    rows = {"AW": 8.8, "W": 6.6, "AR": 4.9, "B": 2.6, "R": 1.1}
    for n, ry in rows.items():
        c.text(0.55, ry, n, size=9, weight="bold")
    bh, bw = 0.8, 1.75
    for r, chk, mk, q in [("AW", "合法性检查", "make_req", "WREQ"), ("W", "WLAST 检查", "make_wdata", "WDATA"),
                          ("AR", "合法性检查", "make_req", "RREQ")]:
        ry = rows[r]
        c.box(A, ry - bh / 2, 1.6, bh, chk, size=7.5)
        c.box(B, ry - bh / 2, bw, bh, mk, size=7.5)
        c.fifo(C, ry - bh / 2, 1.75, bh, q, stack=2, size=7.5)
        c.arrow([(0.85, ry), (A, ry)])
        c.arrow([(A + 1.6, ry), (B, ry)])
        c.arrow([(B + bw, ry), (C, ry)])
        c.arrow([(C + 1.75 + 0.18, ry), (11.0, ry)])
    # 写路由 FIFO：AW 写入 RP/LEN，W 按序取出
    c.fifo(A, 7.35, 1.6, 0.65, "路由", slots=3, size=7.5)
    c.arrow([(A + 0.8, rows["AW"] - bh / 2), (A + 0.8, 8.0)])
    c.arrow([(A + 0.8, 7.35), (A + 0.8, rows["W"] + bh / 2)], **CTL)
    # ID 在途表：约束 AW/AR 准入，核对 R/B
    c.reg(A, 3.35, 1.6, 0.7, "ID 在途表", size=7.5)
    c.arrow([(A + 0.8, 4.05), (A + 0.8, rows["AR"] - bh / 2)], **CTL)
    c.arrow([(A + 0.8, 3.35), (A + 0.8, 2.75), (B + 0.62, 2.75)], **CTL)
    # aou_transport
    c.box(8.75, 0.45, 4.35, 9.2, fill="none", lw=1.3)
    c.text(10.9, 9.35, "aou_transport", size=8.5, weight="bold")
    c.box(11.0, 4.45, 1.85, 4.75, "aou_flit_tx", size=8.5)
    c.box(11.0, 0.75, 1.85, 2.6, "aou_flit_rx", size=8.5)
    c.reg(9.05, 3.55, 1.5, 0.7, "credit", size=7.5)
    c.arrow([(11.0, 3.05), (10.8, 3.05), (10.8, 3.9), (10.55, 3.9)], **CTL)
    c.arrow([(9.8, 4.25), (9.8, 4.75), (11.0, 4.75)], **CTL)
    c.fifo(9.05, rows["B"] - 0.35, 1.5, 0.7, "WRESP", stack=2, size=7)
    c.fifo(9.05, rows["R"] - 0.35, 1.5, 0.7, "RDATA", stack=2, size=7)
    c.arrow([(11.0, rows["B"]), (10.55 + 0.2, rows["B"])])
    c.arrow([(11.0, rows["R"]), (10.55 + 0.2, rows["R"])])
    # 响应仲裁与 RP 锁定
    c.mux(B + 0.6, rows["B"] - 0.5, 0.75, 1.0, direction="left")
    c.mux(B + 0.6, rows["R"] - 0.5, 0.75, 1.0, direction="left")
    c.arrow([(9.05, rows["B"]), (B + 1.35, rows["B"])])
    c.arrow([(9.05, rows["R"]), (B + 1.35, rows["R"])])
    c.arrow([(B + 0.6, rows["B"]), (0.85, rows["B"])])
    c.arrow([(B + 0.6, rows["R"]), (0.85, rows["R"])])
    c.reg(A + 0.35, 1.55, 1.25, 0.55, "锁定", size=7)
    c.arrow([(A + 1.6, 1.82), (B + 0.69, 1.82), (B + 0.69, rows["R"] + 0.42)], **CTL)
    # 链路端口
    c.arrow([(12.85, 6.8), (16.9, 6.8)], lw=1.4)
    c.arrow([(16.9, 2.05), (12.85, 2.05)], lw=1.4)
    c.bus(15.0, 6.8, n="2000", below=True)
    c.bus(15.0, 2.05, n="2000", below=True)
    c.text(16.25, 7.15, "flit_tx", size=8.5, weight="bold")
    c.text(16.25, 2.4, "flit_rx", size=8.5, weight="bold")
    c.save(f"{OUT}/f_soc.png")


def fig_target():
    c = Canvas(17, 9.4)
    c.frame(1.75, 0.2, 13.75, 9.0, "flit2mc_target")
    # 链路端口
    c.arrow([(0.1, 7.0), (2.45, 7.0)], lw=1.4)
    c.arrow([(2.45, 2.4), (0.1, 2.4)], lw=1.4)
    c.bus(1.1, 7.0, n="2000", below=True)
    c.bus(1.1, 2.4, n="2000", below=True)
    c.text(0.75, 7.35, "flit_rx", size=8.5, weight="bold")
    c.text(0.75, 2.75, "flit_tx", size=8.5, weight="bold")
    # aou_transport：解帧、接收 FIFO、组帧
    c.box(2.15, 0.5, 4.75, 8.15, fill="none", lw=1.3)
    c.text(4.5, 8.35, "aou_transport", size=8.5, weight="bold")
    c.box(2.45, 5.45, 1.35, 2.6, "flit\nrx", size=8)
    c.box(2.45, 0.9, 1.35, 2.6, "flit\ntx", size=8)
    c.reg(2.45, 4.1, 1.35, 0.65, "credit", size=7)
    rq = {"WREQ": 7.6, "WDATA": 6.6, "RREQ": 5.6}
    for n, ry in rq.items():
        c.fifo(4.55, ry - 0.33, 1.75, 0.66, n, stack=2, size=7)
        c.arrow([(3.8, ry), (4.55, ry)])
    # 请求选择、beat 计数、地址生成
    c.mux(7.5, 5.15, 0.8, 2.95, direction="right")
    for ry in rq.values():
        c.arrow([(6.3 + 0.2, ry), (7.5, ry)])
    c.reg(7.48, 3.95, 0.85, 0.6, "beat", size=7, stack=1)
    c.arrow([(7.9, 4.55), (7.9, 5.25)], **CTL)
    c.box(9.0, 6.15, 1.65, 0.9, "地址生成", size=7.5)
    c.arrow([(8.3, 6.6), (9.0, 6.6)])
    c.arrow([(10.65, 6.6), (16.9, 6.6)], lw=1.4)
    c.text(16.2, 6.95, "mc_req", size=8.5, weight="bold")
    # ROB：按 tag 登记乱序完成，按分配顺序退休
    c.reg(11.6, 1.6, 2.1, 3.6, "", size=8)
    for i in range(1, 6):
        c.ax.plot([11.6, 13.7], [1.6 + i * 0.6] * 2, color=K, lw=0.5, zorder=3)
    c.text(12.65, 4.9, "ROB", size=8.5, weight="bold", zorder=5)
    c.arrow([(12.0, 6.6), (12.0, 5.2)], **CTL)
    c.text(12.15, 5.85, "tag", size=7, color=ACC, ha="left")
    c.arrow([(16.9, 3.7), (13.7, 3.7)], lw=1.4)
    c.text(16.2, 4.05, "mc_rsp", size=8.5, weight="bold")
    c.reg(14.05, 0.75, 1.2, 0.6, "写状态", size=7)
    c.arrow([(13.2, 1.6), (13.2, 1.05), (14.05, 1.05)], **CTL)
    # 响应生成与响应 FIFO（位于 transport 之外）
    c.box(9.2, 2.6, 1.65, 0.8, "make_rdata", size=7)
    c.box(9.2, 1.2, 1.65, 0.8, "make_b", size=7)
    c.arrow([(11.6, 3.0), (10.85, 3.0)])
    c.arrow([(11.6, 1.9), (11.25, 1.9), (11.25, 1.6), (10.85, 1.6)])
    c.fifo(7.2, 2.67, 1.4, 0.66, "RDATA", stack=2, size=6.5)
    c.fifo(7.2, 1.27, 1.4, 0.66, "WRESP", stack=2, size=6.5)
    c.arrow([(9.2, 3.0), (8.6 + 0.2, 3.0)])
    c.arrow([(9.2, 1.6), (8.6 + 0.2, 1.6)])
    c.arrow([(7.2, 3.0), (3.8, 3.0)])
    c.arrow([(7.2, 1.6), (3.8, 1.6)])
    c.save(f"{OUT}/f_target.png")


def fig_transport():
    c = Canvas(17, 8.2)
    c.frame(1.9, 0.2, 12.9, 7.8, "aou_transport")
    c.text(0.9, 6.8, "tx_*", size=8.5, weight="bold")
    c.text(0.9, 1.8, "rx_*", size=8.5, weight="bold")
    c.arrow([(1.4, 6.8), (10.0, 6.8)], lw=1.2)
    c.bus(1.45, 6.8)
    c.text(0.9, 6.4, "RP×5", size=7, color=G3)
    c.box(10.0, 5.6, 2.5, 2.0, "aou_flit_tx", size=9)
    c.arrow([(12.5, 6.6), (16.9, 6.6)], lw=1.4)
    c.text(16.15, 6.95, "flit_tx", size=8.5, weight="bold")
    c.arrow([(16.9, 1.8), (12.5, 1.8)], lw=1.4)
    c.text(16.15, 2.15, "flit_rx", size=8.5, weight="bold")
    c.box(10.0, 0.6, 2.5, 2.4, "aou_flit_rx", size=9)
    c.box(7.0, 1.3, 1.9, 1.0, "类型/RP\n检查", size=7.5)
    c.arrow([(10.0, 1.8), (8.9, 1.8)])
    c.fifo(3.0, 1.4, 2.7, 0.8, "接收 FIFO", stack=3, size=8)
    c.arrow([(7.0, 1.8), (5.7 + 0.3, 1.8)])
    c.arrow([(3.0, 1.8), (1.4, 1.8)], lw=1.2)
    c.bus(1.45, 1.8)
    c.text(0.9, 1.4, "RP×5", size=7, color=G3)
    # credit 表：三组计数器
    c.box(5.4, 3.55, 3.4, 1.8, fill=G1)
    for i, n in enumerate(["available", "pending", "promised"]):
        c.text(7.1, 5.05 - i * 0.6, n, size=8)
    for y in (4.15, 4.75):
        c.ax.plot([5.4, 8.8], [y, y], color=K, lw=0.5, zorder=3)
    # 1 PH 授信入账
    c.arrow([(10.6, 3.0), (10.6, 4.1), (8.8, 4.1)], **CTL)
    # 2 TX 读取可发量/待归还量，回写扣减量与授信量
    c.arrow([(10.6, 5.6), (10.6, 5.0), (8.8, 5.0)], **CTL, both=True)
    # 3 接收消息计入 promised
    c.arrow([(7.95, 2.3), (7.95, 3.55)], **CTL)
    # 4 上层取走消息，释放量计入 pending
    c.arrow([(4.35, 2.2 + 0.27), (4.35, 3.0), (6.2, 3.0), (6.2, 3.55)], **CTL)
    for x, y, s in [(10.95, 3.6, "1"), (10.95, 5.3, "2"), (8.3, 2.9, "3"), (4.0, 3.0, "4")]:
        c.badge(x, y, s)
    c.save(f"{OUT}/f_transport.png")


if __name__ == "__main__":
    for f in sys.argv[2:] or ["fig_system", "fig_hierarchy", "fig_soc", "fig_target", "fig_transport"]:
        globals()[f]()

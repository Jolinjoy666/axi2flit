"""系统、模块层次与各模块微架构图。"""
import sys
from drawkit import Canvas, K, G0, G1, G2, G3, ACC, ERR

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
CTL = dict(color=ACC, ls="--", lw=0.9)


def fig_system():
    c = Canvas(17, 4.2)
    y, h = 1.05, 1.35
    blocks = [("SoC\nAXI 主机", 0.25, 1.3, 0), ("axi2flit_soc", 2.25, 2.1, 1),
              ("D2D\nAdapter\n+ PHY", 5.0, 1.2, 0), ("D2D\nAdapter\n+ PHY", 9.2, 1.2, 0),
              ("flit2hif_target", 11.05, 2.2, 1), ("MC", 13.95, 1.3, 0), ("PHY\n存储", 15.85, 1.0, 0)]
    for name, x, w, own in blocks:
        if own:
            c.box(x, y, w, h, name, lw=1.8, weight="bold", size=8)
        else:
            c.box(x, y, w, h, name, fill=G1, ec=G3, color="#444444", size=8)
    links = [(1.55, 2.25, "AXI4"), (4.35, 5.0, "FDI"), (6.2, 9.2, "UCIe 链路"),
             (10.4, 11.05, "FDI"), (13.25, 13.95, "HIF"), (15.25, 15.85, "")]
    for x0, x1, lab in links:
        c.arrow([(x0 + 0.04, y + h / 2), (x1 - 0.04, y + h / 2)], both=True, lw=1.1)
        c.text((x0 + x1) / 2, y + h / 2 + 0.28, lab, size=7.5, color=G3)
    c.text(7.7, y + h / 2 - 0.3, "x8 · 24 GT/s · PAM4", size=6.5, color=G3)
    c.frame(0.1, 0.35, 6.25, 3.55, "SoC Die", ls=(0, (4, 3)))
    c.frame(9.05, 0.35, 7.9, 3.55, "存储 Die", ls=(0, (4, 3)))
    c.save(f"{OUT}/f_system.png")


def fig_hierarchy():
    """例化层次（缩进树）：两端都有发送队列与接收缓冲，存储侧的放在 aou_target_core 中。"""
    tree = [
        (0, "", "axi2flit_soc", "top"),
        (1, "u_write_route  写路由（W 找到所属 AW）", "aou_sync_fifo", "buf"),
        (1, "发送队列 WREQ / RREQ / WDATA，每个 RP 一组", "aou_sync_fifo", "buf"),
        (1, "u_transport  传输层", "aou_transport", ""),
        (2, "u_tx  组帧", "aou_flit_tx", ""),
        (2, "u_rx  解帧", "aou_flit_rx", ""),
        (2, "接收缓冲 RDATA，每个 RP 一个", "aou_chunk_fifo", "buf"),
        (2, "接收缓冲 WRESP，每个 RP 一个", "aou_sync_fifo", "buf"),
        None,
        (0, "", "flit2hif_target", "top"),
        (1, "u_core  存储侧公共部分", "aou_target_core", ""),
        (2, "发送队列 RDATA / WRESP，每个 RP 一组", "aou_sync_fifo", "buf"),
        (2, "u_transport  传输层", "aou_transport", ""),
        (3, "u_tx  组帧", "aou_flit_tx", ""),
        (3, "u_rx  解帧", "aou_flit_rx", ""),
        (3, "接收缓冲 WREQ / RREQ，每个 RP 一组", "aou_sync_fifo", "buf"),
        (3, "接收缓冲 WDATA，每个 RP 一个", "aou_chunk_fifo", "buf"),
        (1, "HIF 后端：读发起、读 ROB、写组装、写缓冲、命令仲裁、HIF credit", "（本模块内逻辑）", "logic"),
    ]
    rh, h, ind = 0.62, 0.46, 0.9
    W = 16.0
    H = 0.4 + rh * len(tree) + 0.2
    c = Canvas(W, H)
    last = {}
    for i, item in enumerate(tree):
        if item is None:
            last = {}
            continue
        lvl, inst, mod, kind = item
        y = H - 0.5 - i * rh
        x = 0.3 + lvl * ind
        w = W - 0.3 - x
        fill = G1 if kind == "buf" else G0
        c.box(x, y - h / 2, w, h, fill=fill, lw=1.6 if kind == "top" else 0.9,
              ls="--" if kind == "logic" else "-")
        if kind == "top":
            c.text(x + 0.2, y, mod, size=9, weight="bold", ha="left")
        else:
            c.text(x + 0.15, y, inst, size=7.3, color=G3, ha="left")
            c.text(x + w - 0.15, y, mod, size=8.2, ha="right", color=G3 if kind == "logic" else K)
        # 连到父节点
        if lvl > 0 and (lvl - 1) in last:
            px, py = last[lvl - 1]
            vx = px + 0.35
            c.ax.plot([vx, vx], [py - h / 2, y], color=K, lw=0.8)
            c.ax.plot([vx, x], [y, y], color=K, lw=0.8)
        last[lvl] = (x, y)
        for k in list(last):
            if k > lvl:
                del last[k]
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
    # 写路由 FIFO：AW 写入 {RP, LEN, SIZE, 起始通道}，W 按序取出
    c.fifo(A, 7.35, 1.6, 0.65, "路由", slots=3, size=7.5)
    c.arrow([(A + 0.8, rows["AW"] - bh / 2), (A + 0.8, 8.0)])
    c.arrow([(A + 0.8, 7.35), (A + 0.8, rows["W"] + bh / 2)], **CTL)
    c.arrow([(A + 1.6, 7.67), (B + 0.85, 7.67), (B + 0.85, rows["W"] + bh / 2)], **CTL)
    c.text(B + 1.0, 7.9, "RP · SIZE · 通道", size=6.5, color=ACC, ha="left")
    # 在途表（读、写各一张）：约束 AW/AR 准入，核对 B/R
    c.reg(A, 3.3, 1.6, 0.8, "在途表\n读 / 写", size=7)
    c.arrow([(A + 0.8, 4.1), (A + 0.8, rows["AR"] - bh / 2)], **CTL)
    c.arrow([(A - 0.15, 3.7), (A, 3.7)], **CTL, head=False)
    c.arrow([(A - 0.15, 3.7), (A - 0.15, rows["AW"] - 0.2), (A, rows["AW"] - 0.2)], **CTL)
    c.arrow([(A + 0.8, 3.3), (A + 0.8, 2.75), (B + 0.62, 2.75)], **CTL)
    c.arrow([(A + 0.2, 3.3), (A + 0.2, 1.3), (B + 0.62, 1.3)], **CTL)
    # aou_transport
    c.box(8.75, 0.45, 4.35, 9.2, fill="none", lw=1.3)
    c.text(10.9, 9.35, "aou_transport", size=8.5, weight="bold")
    c.box(11.0, 4.45, 1.85, 4.5, "aou_flit_tx", size=8.5)
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
    c.reg(A + 0.45, 1.55, 1.15, 0.55, "锁定", size=7)
    c.arrow([(A + 1.6, 1.82), (B + 0.69, 1.82), (B + 0.69, rows["R"] + 0.42)], **CTL)
    c.arrow([(B + 0.69, 1.82), (B + 0.69, rows["B"] - 0.36)], **CTL)
    c.dot(B + 0.69, 1.82, color=ACC)
    # 链路端口
    c.arrow([(12.85, 6.8), (16.9, 6.8)], lw=1.4)
    c.arrow([(16.9, 2.05), (12.85, 2.05)], lw=1.4)
    c.bus(15.0, 6.8, n="2000", below=True)
    c.bus(15.0, 2.05, n="2000", below=True)
    c.text(16.25, 7.15, "flit_tx", size=8.5, weight="bold")
    c.text(16.25, 2.4, "flit_rx", size=8.5, weight="bold")
    c.save(f"{OUT}/f_soc.png")


def fig_io():
    """两个顶层的接口分组。"""
    c = Canvas(18.4, 9.4)
    # axi2flit_soc
    c.box(3.3, 1.0, 3.0, 7.0, "axi2flit_soc", lw=1.8, weight="bold", size=9)
    for i, (name, d) in enumerate([("AW", "in"), ("W", "in"), ("AR", "in"), ("B", "out"), ("R", "out")]):
        y = 7.1 - i * 1.25
        if d == "in":
            c.arrow([(0.9, y), (3.3, y)], lw=1.2)
        else:
            c.arrow([(3.3, y), (0.9, y)], lw=1.2)
        c.text(0.75, y, name, size=8.5, ha="right", weight="bold")
        c.text(2.1, y + 0.25, "s_axi_" + name.lower() + "*", size=6.5, color=G3)
    c.text(2.1, 0.55, "AXI4 从机", size=8, weight="bold")
    # flit2hif_target
    c.box(10.7, 1.0, 3.0, 7.0, "flit2hif_target", lw=1.8, weight="bold", size=9)
    hif = [("hif_cmd_*", "out", "命令"), ("hif_cmd_stall", "in", ""), ("hif_*_credit", "in", "credit 归还"),
           ("hif_rdata_*", "in", "读数据"), ("hif_wdata_*", "out", "写数据"), ("hif_wdata_stall", "in", ""),
           ("hif_wdata_ptr_*", "in", "写指针回送")]
    for i, (name, d, note) in enumerate(hif):
        y = 7.4 - i * 0.95
        if d == "out":
            c.arrow([(13.7, y), (15.4, y)], lw=1.2)
        else:
            c.arrow([(15.4, y), (13.7, y)], lw=1.2)
        c.text(15.5, y, name, size=7.5, ha="left", weight="bold")
        if note:
            c.text(14.55, y + 0.22, note, size=6, color=G3)
    c.text(15.0, 0.55, "HIF 主机", size=8, weight="bold")
    # Flit 端口与链路
    for x0, x1 in ((6.3, 7.6), (9.4, 10.7)):
        c.arrow([(x0, 5.6), (x1, 5.6)], lw=1.4)
        c.arrow([(x1, 3.4), (x0, 3.4)], lw=1.4)
    c.text(6.95, 5.95, "flit_tx", size=7.5, weight="bold")
    c.text(6.95, 3.75, "flit_rx", size=7.5, weight="bold")
    c.text(10.05, 5.95, "flit_rx", size=7.5, weight="bold")
    c.text(10.05, 3.75, "flit_tx", size=7.5, weight="bold")
    c.bus(6.95, 5.6, n="2000", below=True)
    c.bus(6.95, 3.4, n="2000", below=True)
    c.box(7.6, 2.6, 1.8, 3.8, "D2D\nAdapter\n⇅\nUCIe\n⇅\nD2D\nAdapter", fill=G1, ec=G3, color="#444444", size=7)
    c.text(8.5, 0.55, "FDI（250B PLP）", size=8, weight="bold")
    # 公共信号
    for x in (4.8, 12.2):
        c.arrow([(x, 8.9), (x, 8.0)], lw=0.9)
        c.arrow([(x, 1.0), (x, 0.25)], lw=0.9, color=ERR)
    c.text(4.95, 8.75, "clk · rst_n · link_up", size=7, ha="left")
    c.text(12.35, 8.75, "clk · rst_n · link_up", size=7, ha="left")
    c.text(4.95, 0.45, "protocol_error", size=7, ha="left", color=ERR)
    c.text(12.35, 0.45, "protocol_error", size=7, ha="left", color=ERR)
    c.save(f"{OUT}/f_io.png")


def fig_hif_target():
    """flit2hif_target 微架构。"""
    c = Canvas(17, 11.6)
    c.frame(1.7, 0.2, 12.6, 11.2, "flit2hif_target")
    # 链路端口
    c.arrow([(0.1, 9.0), (2.3, 9.0)], lw=1.4)
    c.arrow([(2.3, 2.2), (0.1, 2.2)], lw=1.4)
    c.bus(1.0, 9.0, n="2000", below=True)
    c.bus(1.0, 2.2, n="2000", below=True)
    c.text(0.75, 9.35, "flit_rx", size=8.5, weight="bold")
    c.text(0.75, 2.55, "flit_tx", size=8.5, weight="bold")
    # aou_target_core
    c.box(2.0, 0.5, 3.9, 10.45, fill="none", lw=1.3)
    c.text(3.95, 10.65, "aou_target_core", size=8.5, weight="bold")
    c.box(2.3, 7.5, 1.0, 2.9, "传输\n层\n接收", size=7)
    c.box(2.3, 0.9, 1.0, 2.9, "传输\n层\n发送", size=7)
    rq = {"RREQ": 9.8, "WREQ": 8.6, "WDATA": 7.55}
    for n, ry in rq.items():
        c.fifo(3.65, ry - 0.3, 1.95, 0.6, n, slots=6 if n == "WDATA" else 4, stack=2, size=6.5)
        c.arrow([(3.3, ry), (3.65, ry)])
    c.fifo(3.65, 2.75, 1.95, 0.6, "WRESP", stack=2, size=6.5)
    c.fifo(3.65, 1.25, 1.95, 0.6, "RDATA", stack=2, size=6.5)
    c.arrow([(3.65, 3.05), (3.3, 3.05)])
    c.arrow([(3.65, 1.55), (3.3, 1.55)])
    # 读发起
    c.box(6.5, 9.4, 2.1, 0.9, "读发起\n按行切分", size=7)
    c.arrow([(5.6 + 0.2, 9.8), (6.5, 9.8)])
    # 写组装、写缓冲
    c.box(6.5, 7.6, 2.1, 1.3, "写组装\n窄拍合并成行", size=7)
    c.arrow([(5.6 + 0.2, 8.6), (6.5, 8.6)])
    c.arrow([(5.6 + 0.2, 7.85), (6.5, 7.85)])
    c.reg(9.1, 7.6, 1.9, 1.3, "写缓冲\nWR_LINES 行", size=7)
    c.arrow([(8.6, 8.25), (9.1, 8.25)])
    # 命令仲裁与 credit
    c.mux(11.7, 8.15, 0.8, 2.15, direction="right")
    c.text(12.1, 10.55, "命令仲裁", size=7, color=G3)
    c.arrow([(8.6, 9.85), (11.7, 9.85)])
    c.arrow([(11.0, 8.55), (11.7, 8.55)], **CTL)
    c.text(10.4, 9.1, "wdata_ptr = 槽号", size=6, color=ACC)
    c.text(10.0, 10.1, "token = ROB 槽号", size=6, color=ACC)
    c.reg(11.2, 6.55, 1.9, 0.9, "credit 计数\nLPR / HPR / WR", size=6.5)
    c.arrow([(12.15, 7.45), (12.15, 8.25)], **CTL)
    c.arrow([(12.5, 9.22), (16.9, 9.22)], lw=1.4)
    c.text(15.6, 9.55, "hif_cmd_*", size=8.5, weight="bold")
    c.arrow([(16.9, 7.0), (13.1, 7.0)], **CTL)
    c.text(15.6, 7.3, "hif_*_credit", size=8, weight="bold")
    c.arrow([(16.9, 10.4), (12.4, 10.4), (12.4, 10.0)], **CTL)
    c.text(15.6, 10.7, "hif_cmd_stall", size=8, weight="bold")
    # 写指针回送与写数据发送
    c.fifo(9.1, 5.3, 1.9, 0.65, "回送指针", slots=3, size=6.5)
    c.arrow([(16.9, 5.62), (11.0, 5.62)], **CTL)
    c.text(15.6, 5.95, "hif_wdata_ptr_*", size=8, weight="bold")
    c.box(6.5, 4.85, 2.1, 0.9, "写数据发送\n逐拍读出整行", size=7)
    c.arrow([(9.1, 5.62), (8.6, 5.62)], **CTL)
    c.arrow([(10.05, 7.6), (10.05, 6.6), (7.55, 6.6), (7.55, 5.75)])
    c.arrow([(7.55, 4.85), (7.55, 4.4), (16.9, 4.4)], lw=1.4)
    c.text(15.6, 4.7, "hif_wdata_*", size=8.5, weight="bold")
    # 写上下文与 B
    c.box(6.5, 2.6, 2.1, 0.9, "写上下文\n全部行交出后回 B", size=6.5)
    c.arrow([(6.5, 3.05), (5.6 + 0.2, 3.05)])
    c.arrow([(7.0, 4.85), (7.0, 3.5)], **CTL)
    # 读 ROB 与退休
    c.reg(9.1, 0.8, 1.9, 1.6, "读 ROB\nRD_LINES 行", size=7)
    c.arrow([(16.9, 1.6), (11.0, 1.6)], lw=1.4)
    c.text(15.6, 1.95, "hif_rdata_*", size=8.5, weight="bold")
    c.text(11.2, 1.25, "按 token 写入（可乱序、交织）", size=6, color=ACC, ha="left")
    c.box(6.5, 1.1, 2.1, 0.9, "读退休\n按 AXI 拍拼接", size=7)
    c.arrow([(9.1, 1.55), (8.6, 1.55)])
    c.arrow([(6.5, 1.55), (5.6 + 0.2, 1.55)])
    c.save(f"{OUT}/f_hif_target.png")


def fig_transport():
    c = Canvas(17, 8.6)
    c.frame(1.9, 0.2, 12.9, 8.2, "aou_transport")
    c.text(0.9, 7.2, "tx_*", size=8.5, weight="bold")
    c.text(0.9, 1.75, "rx_*", size=8.5, weight="bold")
    c.arrow([(1.4, 7.4), (10.0, 7.4)], lw=1.2)
    c.bus(1.45, 7.4)
    c.text(0.9, 6.8, "RP×5", size=7, color=G3)
    c.box(10.0, 6.0, 2.5, 2.0, "aou_flit_tx", size=9)
    c.arrow([(12.5, 7.0), (16.9, 7.0)], lw=1.4)
    c.text(16.15, 7.35, "flit_tx", size=8.5, weight="bold")
    c.arrow([(16.9, 1.6), (12.5, 1.6)], lw=1.4)
    c.text(16.15, 1.95, "flit_rx", size=8.5, weight="bold")
    c.box(10.0, 0.5, 2.5, 2.4, "aou_flit_rx", size=9)
    c.box(7.3, 1.1, 1.9, 1.0, "类型 · RP\ncredit 检查", size=7.5)
    c.arrow([(10.0, 1.6), (9.2, 1.6)])
    # 接收缓冲：请求与写响应为定长 FIFO，数据消息为分块 FIFO
    c.fifo(3.0, 2.15, 3.2, 0.7, "请求 / 写响应", stack=2, size=7)
    c.fifo(3.0, 0.75, 3.2, 0.7, "数据（分块）", slots=6, stack=2, size=7)
    c.arrow([(7.3, 1.6), (6.9, 1.6), (6.9, 2.5), (6.2 + 0.2, 2.5)])
    c.arrow([(6.9, 1.6), (6.9, 1.1), (6.2 + 0.2, 1.1)])
    c.dot(6.9, 1.6)
    c.arrow([(3.0, 2.5), (2.6, 2.5), (2.6, 1.75), (1.4, 1.75)], lw=1.2)
    c.arrow([(3.0, 1.1), (2.6, 1.1), (2.6, 1.75)], lw=1.2, head=False)
    c.bus(1.75, 1.75)
    c.text(0.9, 1.35, "RP×5", size=7, color=G3)
    # credit：两张计数表，待归还量由空闲存储组合算出
    c.reg(7.0, 4.9, 2.0, 0.65, "available", size=8)
    c.reg(7.0, 3.7, 2.0, 0.65, "promised", size=8)
    c.box(3.6, 3.7, 2.4, 0.65, "pending（组合）", size=7.5)
    # 1：PH 授信与 CrdtGrant 计入 available
    c.arrow([(10.4, 2.9), (10.4, 5.22), (9.0, 5.22)], **CTL)
    # 2：组帧器按 available 选发并扣减；按 pending 授信，授出量计入 promised
    c.arrow([(8.0, 5.55), (8.0, 6.4), (10.0, 6.4)], **CTL, both=True)
    c.arrow([(4.8, 4.35), (4.8, 6.9), (10.0, 6.9)], **CTL)
    c.arrow([(11.0, 6.0), (11.0, 4.02), (9.0, 4.02)], **CTL)
    # 3：收到的消息与 promised 比对后扣减
    c.arrow([(8.25, 2.1), (8.25, 3.7)], **CTL)
    # 4：空闲存储减 promised 得到 pending
    c.arrow([(4.6, 2.85), (4.6, 3.7)], **CTL)
    c.arrow([(7.0, 4.02), (6.0, 4.02)], **CTL)
    for x, y, t in [(10.05, 3.5, "1"), (9.3, 6.65, "2"), (8.6, 2.9, "3"), (4.25, 3.25, "4")]:
        c.badge(x, y, t)
    c.save(f"{OUT}/f_transport.png")


def fig_lines():
    """按行切分：一行 64B（默认配置），三种典型突发；每例单独取横向比例。"""
    c = Canvas(17, 10.2)
    x0, span = 2.3, 13.6

    def case(y, title, note, beats, lines, total):
        unit = span / total
        X = lambda b: x0 + b * unit
        c.text(0.2, y + 1.85, title, size=8, weight="bold", ha="left")
        c.text(16.8, y + 1.85, note, size=7.5, color=ACC, ha="right")
        c.text(x0 - 0.2, y + 1.0, "AXI 拍", size=7, ha="right")
        c.text(x0 - 0.2, y + 0.25, "HIF 行", size=7, ha="right")
        for i, (a, n) in enumerate(beats):
            c.box(X(a), y + 0.78, n * unit, 0.42, f"拍{i}" if n * unit > 0.8 else "", fill=G0, lw=0.7, size=6.5)
        for k, (a, m0, m1) in enumerate(lines):
            c.box(X(a), y, 64 * unit, 0.5, "", fill=G1, lw=0.9)
            if m1 - m0 < 64:
                c.box(X(a + m0), y + 0.09, (m1 - m0) * unit, 0.32, "", fill=G2, ec="none", lw=0)
            c.text(X(a) + 32 * unit, y + 0.25, f"命令{k}", size=7, zorder=5)
        for k in range(0, total + 1, 64):
            c.ax.plot([X(k)] * 2, [y - 0.12, y], color=G3, lw=0.6)
            c.text(X(k), y - 0.3, f"{k}B", size=6.5, color=G3)

    case(7.4, "① 1024 位，4 拍 × 128B，起始地址 0", "一拍拆成 2 行，共 8 条命令",
         [(i * 128, 128) for i in range(4)], [(i * 64, 0, 64) for i in range(8)], 512)
    case(4.2, "② 256 位，4 拍 × 32B，起始地址 0", "2 拍合并成 1 行，共 2 条命令",
         [(i * 32, 32) for i in range(4)], [(0, 0, 64), (64, 0, 64)], 128)
    case(1.0, "③ 4 字节窄访问，16 拍，起始地址 4", "深色为掩码有效字节；跨行处分开，共 2 条命令",
         [(4 + i * 4, 4) for i in range(16)], [(0, 4, 64), (64, 0, 4)], 128)
    c.save(f"{OUT}/f_lines.png")


def fig_hif_seq():
    """HIF 读、写一次交互的先后顺序（每条命令一行）。"""
    c = Canvas(17, 9.0, )
    for x0, title in ((0.4, "读一行"), (8.9, "写一行")):
        c.text(x0 + 3.85, 8.6, title, size=9, weight="bold")
        c.box(x0, 7.6, 2.0, 0.65, "桥", fill=G0, size=8.5, weight="bold")
        c.box(x0 + 5.7, 7.6, 2.0, 0.65, "MC", fill=G1, size=8.5, weight="bold")
        for x in (x0 + 1.0, x0 + 6.7):
            c.ax.plot([x, x], [2.6, 7.6], color=G3, lw=0.8, ls="--")
    def msg(x0, y, right, text, note="", ctl=False):
        a, b = (x0 + 1.0, x0 + 6.7) if right else (x0 + 6.7, x0 + 1.0)
        kw = dict(color=ACC, ls="--", lw=0.9) if ctl else dict(lw=1.1)
        c.arrow([(a, y), (b, y)], **kw)
        c.text((a + b) / 2, y + 0.22, text, size=7.3, color=ACC if ctl else K)
        if note:
            c.text((a + b) / 2, y - 0.25, note, size=6.3, color=G3)
    # 读
    x = 0.4
    msg(x, 6.8, True, "hif_cmd：type=01，addr，token=t", "需 LPR / HPR credit ≥ 1；stall 时保持")
    c.text(x + 3.85, 5.9, "…… 控制器调度、访问存储 ……", size=6.8, color=G3)
    msg(x, 5.0, False, "hif_rdata：token=t，第 0 拍")
    msg(x, 4.2, False, "hif_rdata：token=t，第 1 拍，end=1", "不同 token 的拍可以交织")
    msg(x, 3.2, False, "hif_lpr_credit 脉冲", "归还 1 个 credit（时刻由控制器决定）", ctl=True)
    c.text(x + 3.85, 1.7, "桥：数据按 token 写入读 ROB 第 t 行，\n按发出顺序退休成 RDATA", size=7, color=K)
    # 写
    x = 8.9
    msg(x, 6.8, True, "hif_cmd：type=00，addr，wdata_ptr=p", "需 WR credit ≥ 1；数据已在写缓冲第 p 槽")
    msg(x, 5.8, False, "hif_wdata_ptr_valid：ptr=p", "控制器准备好接收这一行的数据", ctl=True)
    msg(x, 4.9, True, "hif_wdata + mask：第 0 拍")
    msg(x, 4.1, True, "hif_wdata + mask：第 1 拍，end=1", "stall 时保持")
    msg(x, 3.2, False, "hif_wr_credit 脉冲", "归还 1 个 credit", ctl=True)
    c.text(x + 3.85, 1.7, "桥：突发的所有行都送完数据后，\n生成 WRESP（HIF 没有写完成信号）", size=7, color=K)
    c.save(f"{OUT}/f_hif_seq.png")


if __name__ == "__main__":
    for f in sys.argv[2:] or ["fig_system", "fig_io", "fig_hierarchy", "fig_soc", "fig_hif_target", "fig_transport", "fig_lines",
                              "fig_hif_seq"]:
        globals()[f]()
